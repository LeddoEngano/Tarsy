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
                .onAppear {
                    appDelegate.authManager = authManager
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
                    appDelegate.authManager = authManager
                }
        } label: {
            if updateChecker.shouldShowBanner {
                Image(systemName: "arrow.down.circle.fill")
            } else {
                Image("MenuBarIcon")
                    .renderingMode(.original)
                    .opacity(daemonManager.isRunning ? 1.0 : 0.5)
            }
        }
        .menuBarExtraStyle(.window)

        // Pairing QR Code window
        Window("Pair iPhone", id: "pairing-qr") {
            PairingQRWindow()
                .environmentObject(daemonManager)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

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
    var authManager: AuthManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        checkIfRunningFromDMG()
    }

    func applicationWillTerminate(_ notification: Notification) {
        daemonManager?.markOfflineSync()
    }

    /// Handle deep-link URLs (OAuth callbacks) that arrive via the system
    /// rather than through ASWebAuthenticationSession's own callback.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "com.tarsy.macos",
                  url.host == "login-callback" else { continue }
            Task { @MainActor in
                await authManager?.handleOAuthCallback(url: url)
            }
        }
    }

    private func checkIfRunningFromDMG() {
        let appPath = Bundle.main.bundlePath
        let isFromVolume = appPath.hasPrefix("/Volumes/")
        let isFromDownloads = appPath.contains("/Downloads/")

        guard isFromVolume || isFromDownloads else { return }

        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Tarsy"
        let dest = "/Applications/\(appName).app"

        let alert = NSAlert()
        alert.messageText = "Move to Applications?"
        alert.informativeText = "\(appName) needs to be in your Applications folder to work properly. Move it now and relaunch?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Move & Launch")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            moveToApplicationsAndRelaunch(from: appPath, to: dest)
        } else {
            NSApp.terminate(nil)
        }
    }

    private func moveToApplicationsAndRelaunch(from source: String, to dest: String) {
        let fm = FileManager.default

        // Remove existing version if present
        if fm.fileExists(atPath: dest) {
            try? fm.removeItem(atPath: dest)
        }

        do {
            try fm.copyItem(atPath: source, toPath: dest)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not move to Applications"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        // Relaunch from /Applications
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", dest]
        try? task.run()

        NSApp.terminate(nil)
    }
}
