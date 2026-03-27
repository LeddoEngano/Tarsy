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

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if let error = error {
                print("[Push] Authorization error: \(error.localizedDescription)")
                return
            }
            if granted {
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
        print("[Push] Device token: \(token)")
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
            print("[Push] Token saved to Supabase")
            pendingPushToken = nil
        } catch {
            print("[Push] Token save deferred (not authed yet)")
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[Push] Failed to register: \(error.localizedDescription)")
    }

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
}

@main
struct TarsyiOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var authManager = AuthManager()
    @StateObject private var workspaceService = WorkspaceService()
    @StateObject private var machineService = MachineService()
    @StateObject private var connectionManager = ConnectionManager()
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var profileService = ProfileService()
    @StateObject private var deepLinkRouter = DeepLinkRouter()

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
                .onAppear {
                    AppDelegate.deepLinkRouter = deepLinkRouter
                    subscriptionManager.profileService = profileService
                    subscriptionManager.start()
                }
                .onOpenURL { url in
                    Task {
                        await authManager.handleOAuthCallback(url: url)
                    }
                }
        }
    }
}
