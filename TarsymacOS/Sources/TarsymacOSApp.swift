import SwiftUI
import TarsyShared
import AppKit

@main
struct TarsymacOSApp: App {
    @NSApplicationDelegateAdaptor(TarsyAppDelegate.self) var appDelegate
    @StateObject private var authManager = AuthManager()
    @StateObject private var daemonManager = DaemonManager()
    @StateObject private var updateChecker = UpdateChecker()

    init() {
        // Ignore SIGPIPE globally so writing to a closed pipe (e.g., terminated
        // AI engine process) doesn't crash the entire app.
        signal(SIGPIPE, SIG_IGN)
    }
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some Scene {
        // Onboarding / Main window
        Window("Tarsy Setup", id: "onboarding") {
            OnboardingWindow()
                .environmentObject(authManager)
                .environmentObject(daemonManager)
                .onDisappear {
                    if authManager.isAuthenticated {
                        hasCompletedOnboarding = true
                    }
                }
                .onOpenURL { url in
                    Task {
                        await authManager.handleOAuthCallback(url: url)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // Menu bar
        MenuBarExtra {
            MenuBarView()
                .environmentObject(authManager)
                .environmentObject(daemonManager)
                .environmentObject(updateChecker)
                .onAppear {
                    updateChecker.startPeriodicChecks()
                    appDelegate.daemonManager = daemonManager
                }
        } label: {
            Image(systemName: updateChecker.shouldShowBanner
                  ? "arrow.down.circle.fill"
                  : daemonManager.isRunning ? "eye.circle.fill" : "eye.circle")
        }
        .menuBarExtraStyle(.window)

        // Settings
        Settings {
            SettingsView()
                .environmentObject(authManager)
                .environmentObject(daemonManager)
        }
    }
}

class TarsyAppDelegate: NSObject, NSApplicationDelegate {
    var daemonManager: DaemonManager?

    func applicationWillTerminate(_ notification: Notification) {
        daemonManager?.markOfflineSync()
    }
}
