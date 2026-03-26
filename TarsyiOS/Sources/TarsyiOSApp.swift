import SwiftUI
import TarsyShared

class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }
}

@main
struct TarsyiOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var authManager = AuthManager()
    @StateObject private var workspaceService = WorkspaceService()
    @StateObject private var machineService = MachineService()
    @StateObject private var connectionManager = ConnectionManager()
    @StateObject private var subscriptionManager = SubscriptionManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(authManager)
                .environmentObject(workspaceService)
                .environmentObject(machineService)
                .environmentObject(connectionManager)
                .environmentObject(subscriptionManager)
                .onAppear {
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
