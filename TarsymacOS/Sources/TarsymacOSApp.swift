import SwiftUI
import TarsyShared
import AppKit

/// Bump this whenever onboarding adds a new required step. Users whose
/// stored `onboardingVersion` is below this value will be forced back
/// into onboarding on next launch, even if `hasCompletedOnboarding` is
/// true. Version history:
///   1 - initial release (screen recording, accessibility, files and folders, automation)
///   2 - 2026-04: replaced files-and-folders with full disk access,
///       fixed false-positive detection. All pre-existing installs must
///       re-verify because their previous "granted" state was unreliable.
let kRequiredOnboardingVersion: Int = 2

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
    /// Set to `kRequiredOnboardingVersion` only when onboarding completes
    /// with every required permission actually verified. If this is below
    /// the required version at launch, onboarding re-runs.
    @AppStorage("onboardingVersion") private var onboardingVersion: Int = 0
    /// Set by `OnboardingWindow` when every required permission has been
    /// verified as granted. Used by the hard-gate on window close.
    @AppStorage("permissionsVerified") private var permissionsVerified: Bool = false

    var body: some Scene {
        // Onboarding / Main window
        Window("Tarsy Setup", id: "onboarding") {
            OnboardingWindow()
                .environmentObject(authManager)
                .environmentObject(daemonManager)
                .onDisappear {
                    // If this window is closing because of an intentional
                    // mid-onboarding relaunch (e.g. Screen Recording grant
                    // requires a fresh process), skip the hard-gate entirely
                    // and clear the flag. The relaunched process will see
                    // onboarding as still incomplete and pick up where the
                    // user left off.
                    if UserDefaults.standard.bool(forKey: "isRelaunchingForPermissions") {
                        UserDefaults.standard.set(false, forKey: "isRelaunchingForPermissions")
                        return
                    }
                    // Hard-gate: only mark onboarding complete if the user
                    // is authenticated AND every required permission has
                    // been verified as granted in this session. If the
                    // user tries to close the onboarding window without
                    // completing permissions, terminate the app — Tarsy
                    // cannot function remotely without them.
                    if authManager.isAuthenticated && permissionsVerified {
                        hasCompletedOnboarding = true
                        onboardingVersion = kRequiredOnboardingVersion
                    } else if authManager.isAuthenticated && !permissionsVerified {
                        let alert = NSAlert()
                        alert.messageText = "Tarsy can't run without these permissions"
                        alert.informativeText = "Tarsy is a remote control tool. Without Screen Recording, Accessibility, Automation, and Full Disk Access, it cannot function while you're away from your Mac. Please reopen Tarsy and complete setup."
                        alert.alertStyle = .critical
                        alert.addButton(withTitle: "Quit Tarsy")
                        alert.runModal()
                        NSApp.terminate(nil)
                    }
                }
                .onOpenURL { url in
                    Task {
                        await authManager.handleOAuthCallback(url: url)
                    }
                }
                .onAppear {
                    appDelegate.authManager = authManager
                    // Force re-onboarding if the stored version is below the
                    // current required version — even if the user previously
                    // saw "setup complete" under an older, buggier onboarding.
                    if onboardingVersion < kRequiredOnboardingVersion {
                        hasCompletedOnboarding = false
                        permissionsVerified = false
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
