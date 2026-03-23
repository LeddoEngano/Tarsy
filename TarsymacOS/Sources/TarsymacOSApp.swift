import SwiftUI
import TarsyShared

@main
struct TarsymacOSApp: App {
    @StateObject private var authManager = AuthManager()
    @StateObject private var daemonManager = DaemonManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(authManager)
                .environmentObject(daemonManager)
        } label: {
            Image(systemName: "eye.circle.fill")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(authManager)
        }
    }
}
