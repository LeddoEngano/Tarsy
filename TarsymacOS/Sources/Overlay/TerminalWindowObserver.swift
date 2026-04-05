import AppKit
import Combine

/// Observes frontmost app and tracks terminal window frame using Accessibility API.
/// Used to position the floating UltraContext overlay button.
@MainActor
final class TerminalWindowObserver: ObservableObject {
    @Published var isTerminalFocused = false
    @Published var terminalWindowFrame: CGRect = .zero
    @Published var terminalAppName = ""

    private var workspaceObservers: [NSObjectProtocol] = []
    private var pollingTimer: Timer?
    private var currentPID: pid_t = 0

    /// Bundle IDs recognized as terminal/IDE apps
    private nonisolated static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "com.mitchellh.ghostty",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "dev.zed.Zed",
        "com.jetbrains.intellij",
        "com.jetbrains.pycharm",
        "com.jetbrains.WebStorm",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "net.kovidgoyal.kitty",
        "com.brave.Browser", // Dev tools terminal
    ]

    func startObserving() {
        let nc = NSWorkspace.shared.notificationCenter

        let activateObs = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notif in
            guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }
            if TerminalWindowObserver.terminalBundleIDs.contains(bundleID) {
                Task { @MainActor in
                    guard let self else { return }
                    self.currentPID = app.processIdentifier
                    self.terminalAppName = app.localizedName ?? bundleID
                    self.isTerminalFocused = true
                    self.startPolling()
                }
            }
        }

        let deactivateObs = nc.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notif in
            guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }
            if TerminalWindowObserver.terminalBundleIDs.contains(bundleID) {
                Task { @MainActor in
                    guard let self else { return }
                    self.isTerminalFocused = false
                    self.stopPolling()
                }
            }
        }

        workspaceObservers = [activateObs, deactivateObs]

        // Check if a terminal is already focused on start
        if let front = NSWorkspace.shared.frontmostApplication,
           let bundleID = front.bundleIdentifier,
           Self.terminalBundleIDs.contains(bundleID) {
            currentPID = front.processIdentifier
            terminalAppName = front.localizedName ?? bundleID
            isTerminalFocused = true
            startPolling()
        }
    }

    func stopObserving() {
        let nc = NSWorkspace.shared.notificationCenter
        for obs in workspaceObservers {
            nc.removeObserver(obs)
        }
        workspaceObservers = []
        stopPolling()
        isTerminalFocused = false
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        updateWindowFrame()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateWindowFrame()
            }
        }
    }

    private func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    private func updateWindowFrame() {
        guard currentPID != 0 else { return }

        let appElement = AXUIElementCreateApplication(currentPID)

        var focusedWindow: CFTypeRef?
        let windowResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        guard windowResult == .success, let window = focusedWindow else { return }

        let axWindow = window as! AXUIElement

        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionValue)
        AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeValue)

        guard let positionValue, let sizeValue else { return }

        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

        let newFrame = CGRect(origin: position, size: size)
        if newFrame != terminalWindowFrame {
            terminalWindowFrame = newFrame
        }
    }
}
