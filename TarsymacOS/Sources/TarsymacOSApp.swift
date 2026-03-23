import SwiftUI
import TarsyShared

@main
struct TarsymacOSApp: App {
    @StateObject private var authManager = AuthManager()
    @StateObject private var daemonManager = DaemonManager()
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
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // Menu bar
        MenuBarExtra {
            MenuBarView()
                .environmentObject(authManager)
                .environmentObject(daemonManager)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: daemonManager.isRunning ? "eye.circle.fill" : "eye.circle")
            }
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
