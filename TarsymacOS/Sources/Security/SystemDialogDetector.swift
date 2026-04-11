import AppKit
import ApplicationServices
import Foundation

/// Polls for unexpected system-level modal dialogs (TCC prompts,
/// Automation consent, Keychain auth, admin password sheets, etc.) and
/// surfaces them via callbacks so they can be forwarded to the iOS app
/// for remote approval.
///
/// This is the "safety net" layer of the permission story. Even when
/// onboarding pre-grants every known permission, unexpected prompts
/// can still appear:
///   - A new macOS version introduces a new TCC category.
///   - A project touches a new app via Automation (Safari -> Chrome).
///   - Keychain reauth timer expires.
///   - A CLI tool installs a new helper whose parent process changes.
///
/// The detector catches these by AX-walking the window trees of the
/// system processes that host alert-style prompts, extracting the
/// buttons/body/title, and classifying them as remotely-actionable
/// (NSAlert-style, CGEvent clicks work with Accessibility granted) or
/// not (contains a secure text field, CGEvent keystrokes are dropped
/// by WindowServer).
///
/// Design notes:
///   - Runs on the main thread because AX APIs require it.
///   - Polls at 1 Hz to keep CPU cost negligible.
///   - Uses a stable dialog id (pid + title + button labels joined)
///     to debounce: we only emit `appeared` when a genuinely new
///     dialog shows up, and `dismissed` exactly once when it goes
///     away. This keeps the wire traffic and iOS UI stable across
///     repeated polls of the same dialog.
///   - Does not cache AX element references between scans — by the
///     time we act on a click from iOS, the cached reference would
///     be stale. Each click re-scans to find the live button frame.
@MainActor
final class SystemDialogDetector {

    /// A detected system-level dialog that may be surfaced on iOS.
    struct Dialog: Sendable, Equatable {
        /// Stable id derived from `pid:title:buttonLabelsJoined`. Used
        /// by the iOS side to target approve/deny/click on a specific
        /// dialog, and by the detector to debounce repeated scans of
        /// the same dialog.
        let id: String
        /// Bundle identifier of the process hosting the dialog window.
        let owner: String
        /// Window title (e.g. "Tarsy wants to control Safari").
        let title: String
        /// Concatenated body text from all static-text children.
        let body: String
        /// Buttons with their AX-reported frames in global screen coords.
        let buttons: [Button]
        /// `false` for dialogs backed by a secure text field (admin
        /// password, FileVault, keychain password). On those, synthetic
        /// keystrokes are blocked by WindowServer and CGEvent clicks on
        /// their "OK" button don't help because the password field
        /// stays empty. iOS shows a "handle next time you're at the
        /// Mac" UX for these.
        let remotelyActionable: Bool
    }

    /// A button with its global-screen-coord frame.
    struct Button: Sendable, Equatable, Codable {
        let label: String
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat

        var centerX: CGFloat { x + width / 2 }
        var centerY: CGFloat { y + height / 2 }
    }

    // MARK: - Known owners

    /// Processes that host NSAlert-style TCC / Automation / Keychain
    /// prompts whose buttons accept synthetic CGEvent clicks with
    /// Accessibility granted.
    private static let actionableOwners: Set<String> = [
        "com.apple.UserNotificationCenter",
        "com.apple.coreservices.uiagent",
    ]

    /// Processes that host secure / admin-password dialogs. Detected
    /// and surfaced so iOS can show a "requires your admin password"
    /// message — but NOT clickable remotely, because their password
    /// text field enables Secure Input which drops synthetic keys.
    private static let secureOwners: Set<String> = [
        "com.apple.SecurityAgent",
        "com.apple.security.authtrampoline",
    ]

    // MARK: - State

    private var currentDialogId: String? = nil
    private var pollTask: Task<Void, Never>? = nil

    /// Called on the main actor when a new dialog appears (not
    /// previously reported). Re-emits when a previously-reported
    /// dialog is replaced by a different one.
    var onDialogAppeared: (@MainActor (Dialog) -> Void)? = nil

    /// Called on the main actor when a previously-reported dialog is
    /// no longer visible. Fires exactly once per dialog.
    var onDialogDismissed: (@MainActor (String) -> Void)? = nil

    // MARK: - Lifecycle

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.scanOnce()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        currentDialogId = nil
    }

    // MARK: - Scan

    private func scanOnce() {
        // Accessibility is a hard prerequisite — without it, AX queries
        // return apiDisabled and we can't see any windows at all.
        // Don't even try until the user has granted it.
        guard AXIsProcessTrusted() else { return }

        let candidates = NSWorkspace.shared.runningApplications.filter { app in
            guard let bundleId = app.bundleIdentifier else { return false }
            return Self.actionableOwners.contains(bundleId)
                || Self.secureOwners.contains(bundleId)
        }

        var foundDialog: Dialog? = nil
        for app in candidates {
            if let dialog = findDialog(in: app) {
                foundDialog = dialog
                break
            }
        }

        if let dialog = foundDialog {
            if dialog.id != currentDialogId {
                if let prev = currentDialogId {
                    onDialogDismissed?(prev)
                }
                currentDialogId = dialog.id
                onDialogAppeared?(dialog)
            }
        } else if let prev = currentDialogId {
            currentDialogId = nil
            onDialogDismissed?(prev)
        }
    }

    private func findDialog(in app: NSRunningApplication) -> Dialog? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &windowsValue)
        guard result == .success, let windows = windowsValue as? [AXUIElement] else {
            return nil
        }

        guard let bundleId = app.bundleIdentifier else { return nil }
        let isSecureOwner = Self.secureOwners.contains(bundleId)

        for window in windows {
            // Skip minimized windows — they're not presented to the user.
            var minimized: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(
                window, kAXMinimizedAttribute as CFString, &minimized)
            if let isMin = minimized as? Bool, isMin { continue }

            let title = stringAttr(window, kAXTitleAttribute)
            let body = collectStaticText(window)
            let buttons = collectButtons(window)

            // Ignore noise windows with nothing to show.
            if title.isEmpty && body.isEmpty && buttons.isEmpty { continue }

            // Secure-field probe: even on "actionable" owners, if the
            // window contains a secure text field we cannot help the
            // user remotely.
            let containsSecureField = findSecureField(in: window)

            let id = makeStableId(
                pid: app.processIdentifier, title: title, buttons: buttons)
            return Dialog(
                id: id,
                owner: bundleId,
                title: title,
                body: body,
                buttons: buttons,
                remotelyActionable: !isSecureOwner
                    && !containsSecureField
                    && !buttons.isEmpty
            )
        }
        return nil
    }

    // MARK: - Remote click

    /// Attempt to click a named button in the currently-visible dialog.
    /// Re-scans live because AX element references from the last poll
    /// may be stale by the time the iOS click arrives.
    ///
    /// Returns true if a click was posted, false if no matching button
    /// was found or the dialog is no longer present.
    @discardableResult
    func clickButton(inDialog dialogId: String, label: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let candidates = NSWorkspace.shared.runningApplications.filter { app in
            guard let bundleId = app.bundleIdentifier else { return false }
            return Self.actionableOwners.contains(bundleId)
        }

        for app in candidates {
            guard let dialog = findDialog(in: app), dialog.id == dialogId else {
                continue
            }
            guard dialog.remotelyActionable else { return false }
            guard let button = dialog.buttons.first(where: { $0.label == label }) else {
                return false
            }
            postClick(at: CGPoint(x: button.centerX, y: button.centerY))
            return true
        }
        return false
    }

    /// Post a synthetic left-click at the given global screen coordinate.
    /// Uses CGEvent — requires Accessibility, which is an onboarding
    /// prerequisite. Calls are rejected by WindowServer on secure-input
    /// windows, but we only use this for `remotelyActionable` dialogs
    /// so that is a non-issue here.
    private func postClick(at point: CGPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                           mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                         mouseCursorPosition: point, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: - AX helpers

    private func stringAttr(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element, attribute as CFString, &value)
        guard result == .success else { return "" }
        return value as? String ?? ""
    }

    private func collectStaticText(_ root: AXUIElement) -> String {
        var texts: [String] = []
        walk(root) { element in
            let role = self.stringAttr(element, kAXRoleAttribute)
            if role == kAXStaticTextRole {
                let text = self.stringAttr(element, kAXValueAttribute)
                if !text.isEmpty {
                    texts.append(text)
                }
            }
        }
        return texts.joined(separator: "\n")
    }

    private func collectButtons(_ root: AXUIElement) -> [Button] {
        var buttons: [Button] = []
        walk(root) { element in
            let role = self.stringAttr(element, kAXRoleAttribute)
            guard role == kAXButtonRole else { return }
            let label = self.stringAttr(element, kAXTitleAttribute)
            guard !label.isEmpty else { return }
            guard let frame = self.frame(of: element) else { return }
            buttons.append(Button(
                label: label,
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.size.width,
                height: frame.size.height))
        }
        return buttons
    }

    private func findSecureField(in root: AXUIElement) -> Bool {
        var found = false
        walk(root) { element in
            if found { return }
            let role = self.stringAttr(element, kAXRoleAttribute)
            guard role == kAXTextFieldRole else { return }
            var subrole: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(
                element, kAXSubroleAttribute as CFString, &subrole)
            if let sub = subrole as? String, sub == "AXSecureTextField" {
                found = true
            }
        }
        return found
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(
                element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionRef = positionValue,
              let sizeRef = sizeValue
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        // Force-casting to AXValue is safe: the AX API returns AXValue
        // refs for position and size attributes by contract.
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func walk(_ element: AXUIElement, _ visit: (AXUIElement) -> Void) {
        visit(element)
        var childrenValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &childrenValue)
        if result == .success, let children = childrenValue as? [AXUIElement] {
            for child in children {
                walk(child, visit)
            }
        }
    }

    private func makeStableId(
        pid: pid_t, title: String, buttons: [Button]
    ) -> String {
        let labels = buttons.map(\.label).joined(separator: "|")
        return "\(pid):\(title):\(labels)"
    }
}
