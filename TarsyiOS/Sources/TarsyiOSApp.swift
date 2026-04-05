import SwiftUI
import UserNotifications
import TarsyShared

/// Shared navigation state for deep linking from push notifications
@MainActor
class DeepLinkRouter: ObservableObject {
    @Published var pendingWorkspaceId: UUID?
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self

        // Register for remote notifications if already authorized (returning users)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .authorized {
                DispatchQueue.main.async {
                    application.registerForRemoteNotifications()
                }
            }
        }

        return true
    }

    /// Stored token to save after auth completes
    static var pendingPushToken: String?

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        AppDelegate.pendingPushToken = token
        // Try to save now — will fail silently if not authed yet
        Task { await AppDelegate.savePushTokenIfNeeded() }
    }

    static func savePushTokenIfNeeded() async {
        guard let token = pendingPushToken else { return }
        do {
            let userId = try await supabase.auth.session.user.id.uuidString
            try await supabase
                .from("push_tokens")
                .upsert(
                    [
                        "user_id": userId,
                        "device_token": token
                    ],
                    onConflict: "device_token"
                )
                .execute()
            pendingPushToken = nil
        } catch {
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) { }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .badge, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if let workspaceIdStr = userInfo["workspace_id"] as? String,
           let workspaceId = UUID(uuidString: workspaceIdStr) {
            Task { @MainActor in
                AppDelegate.deepLinkRouter?.pendingWorkspaceId = workspaceId
            }
        }
        completionHandler()
    }

    static weak var deepLinkRouter: DeepLinkRouter?

    /// Background task identifier for keeping WebSocket alive while agents are running
    static var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
}

@main
struct TarsyiOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) var scenePhase
    @StateObject private var authManager = AuthManager()
    @StateObject private var workspaceService = WorkspaceService()
    @StateObject private var machineService = MachineService()
    @StateObject private var connectionManager = ConnectionManager()
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var profileService = ProfileService()
    @StateObject private var deepLinkRouter = DeepLinkRouter()
    @StateObject private var badgeService = NotificationBadgeService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(authManager)
                .environmentObject(workspaceService)
                .environmentObject(machineService)
                .environmentObject(connectionManager)
                .environmentObject(subscriptionManager)
                .environmentObject(profileService)
                .environmentObject(deepLinkRouter)
                .environmentObject(badgeService)
                .onAppear {
                    AppDelegate.deepLinkRouter = deepLinkRouter
                    subscriptionManager.profileService = profileService
                    subscriptionManager.start()
                    // Wire Live Activity widget permission buttons → WebSocket
                    LiveActivityManager.shared.onPermissionResponse = { [weak connectionManager] sessionId, answer, engineType, _, permissionRequestId in
                        var payload: [String: String] = [
                            "sessionId": sessionId,
                            "answer": answer,
                            "engineType": engineType
                        ]
                        if let permId = permissionRequestId, !permId.isEmpty {
                            payload["permissionRequestId"] = permId
                        }
                        connectionManager?.send(WSPacket(
                            action: .engineUserResponse,
                            payload: payload
                        ))
                    }
                    LiveActivityManager.shared.startWidgetResponseObserver()
                }
                .onOpenURL { url in
                    guard url.scheme == "com.tarsy.ios" else { return }
                    if url.host == "login-callback" {
                        Task { await authManager.handleOAuthCallback(url: url) }
                    } else if url.host == "workspace",
                              let idStr = url.pathComponents.dropFirst().first,
                              let workspaceId = UUID(uuidString: idStr) {
                        deepLinkRouter.pendingWorkspaceId = workspaceId
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .background:
                        // Keep WebSocket alive if agents are running, otherwise disconnect
                        if LiveActivityManager.shared.hasActiveActivities {
                            // End any previous background task
                            if AppDelegate.backgroundTaskId != .invalid {
                                UIApplication.shared.endBackgroundTask(AppDelegate.backgroundTaskId)
                            }
                            AppDelegate.backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "TarsyAgentSession") { [weak connectionManager] in
                                // Time expired — clean up and disconnect
                                connectionManager?.disconnect()
                                if AppDelegate.backgroundTaskId != .invalid {
                                    UIApplication.shared.endBackgroundTask(AppDelegate.backgroundTaskId)
                                    AppDelegate.backgroundTaskId = .invalid
                                }
                            }
                        } else {
                            connectionManager.disconnect()
                        }
                    case .active:
                        // End background task if we had one
                        if AppDelegate.backgroundTaskId != .invalid {
                            UIApplication.shared.endBackgroundTask(AppDelegate.backgroundTaskId)
                            AppDelegate.backgroundTaskId = .invalid
                        }
                        badgeService.clearAppIconBadge()
                        if authManager.isAuthenticated {
                            Task { await badgeService.refreshCounts() }
                            Task {
                                if !connectionManager.isConnected {
                                    await connectionManager.reconnectIfNeeded()
                                }
                                // Wait for connection to stabilize before processing widget responses
                                try? await Task.sleep(for: .milliseconds(500))
                                LiveActivityManager.shared.processWidgetResponse()
                            }
                        }
                    default:
                        break
                    }
                }
        }
    }
}
