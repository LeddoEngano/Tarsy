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
///   3 - 2026-04: automation step now pre-warms the Google Chrome
///       Apple Events consent prompt in addition to System Events. macOS
///       scopes automation per target app, so granting System Events
///       alone did not cover Chrome — users hit a surprise prompt the
///       first time they used the browser tab switcher. Existing installs
///       must re-run onboarding so the Chrome pre-warm actually executes.
///   4 - 2026-04: automation detection now requires Chrome in addition
///       to System Events (the v3 bump didn't re-surface the automation
///       sub-step for users who already had System Events granted, so
///       the Chrome pre-warm was still being skipped). This bump forces
///       re-onboarding, the MenuBarExtra label auto-opens the window at
///       launch, and the automation sub-step now stays visible until
///       Chrome is actually pre-warmed.
///   5 - 2026-04: the v4 logic verified the Chrome grant directly,
///       which left users stuck on the automation step if Chrome denied
///       the prompt, failed to launch, or returned an AppleScript error.
///       Rewrote automation detection to be best-effort for Chrome —
///       the sub-step is now gated on System Events grant + a version-
///       scoped "pre-warm consumed" flag written when the user clicks
///       Grant, regardless of Chrome outcome. Clicking Grant always
///       advances the step; Chrome is never a blocker.
///   6 - 2026-04: the v5 Chrome pre-warm relied on `NSAppleScript` auto-
///       launching Chrome via Apple Events, which errored silently when
///       Chrome wasn't running — TCC never got a chance to show its
///       prompt and users were hit with it mid-session from their iPhone.
///       The fix now explicitly launches Chrome via `NSWorkspace.open-
///       Application` (hidden, non-activating), polls until its process
///       and Apple Events handler are ready, re-activates Tarsy so the
///       TCC dialog attaches to our window, and only THEN sends the
///       Apple Event. Requires re-onboarding so existing installs
///       execute the new launch sequence.
let kRequiredOnboardingVersion: Int = 6

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
            // The label closure is the only View in the whole Scene tree
            // that renders at launch under `LSUIElement: true` (there's no
            // dock icon, and the onboarding Window doesn't auto-open).
            // Piggyback on its `.onAppear` to run the version-bump check
            // and programmatically open the onboarding window when the
            // stored `onboardingVersion` is below the current required
            // version. Without this, a version bump silently does nothing
            // for existing installs because the check inside
            // OnboardingWindow.onAppear is unreachable until the window is
            // already open.
            MenuBarBootstrapLabel(updateChecker: updateChecker, daemonManager: daemonManager)
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

/// Menu bar icon label that doubles as the launch bootstrapper for the
/// onboarding window. See the comment on its use site in
/// `TarsymacOSApp.body` for the rationale.
private struct MenuBarBootstrapLabel: View {
    @ObservedObject var updateChecker: UpdateChecker
    @ObservedObject var daemonManager: DaemonManager
    @Environment(\.openWindow) private var openWindow
    @AppStorage("onboardingVersion") private var onboardingVersion: Int = 0
    @State private var didBootstrap = false

    var body: some View {
        Group {
            if updateChecker.shouldShowBanner {
                Image(systemName: "arrow.down.circle.fill")
            } else {
                Image("MenuBarIcon")
                    .renderingMode(.original)
                    .opacity(daemonManager.isRunning ? 1.0 : 0.5)
            }
        }
        .onAppear {
            // MenuBarExtra reconstructs its label as state changes
            // (`daemonManager.isRunning` flips, updates become available),
            // which fires .onAppear multiple times over the app's
            // lifetime. Gate on a one-shot @State flag so we only ever
            // open the onboarding window once per process launch.
            guard !didBootstrap else { return }
            didBootstrap = true

            guard onboardingVersion < kRequiredOnboardingVersion else { return }

            // Delay briefly so SwiftUI has registered the "onboarding"
            // Window scene before we try to open it. Without the delay,
            // `openWindow(id:)` can no-op silently on the first run of a
            // fresh launch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                openWindow(id: "onboarding")
                NSApp.activate(ignoringOtherApps: true)
            }
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
