import AppKit
import ApplicationServices
import Foundation
import ScreenCaptureKit

/// Live status of the permissions Tarsy requires to function remotely.
/// Used by the Permission Doctor feature on iOS (Settings → Permission
/// Doctor) and by the revocation watchdog that surfaces a push
/// notification when the user accidentally revokes one.
struct TarsyPermissions: Equatable, Sendable {
    var screenRecording: Bool
    var accessibility: Bool
    var automation: Bool
    var fullDiskAccess: Bool

    var allGranted: Bool {
        screenRecording && accessibility && automation && fullDiskAccess
    }

    /// `[String: String]` payload shape for `permissions:status` WSPacket.
    /// Keys intentionally match the iOS decoder.
    var payload: [String: String] {
        [
            "screen_recording": screenRecording ? "true" : "false",
            "accessibility": accessibility ? "true" : "false",
            "automation": automation ? "true" : "false",
            "full_disk_access": fullDiskAccess ? "true" : "false",
        ]
    }
}

/// Polls the current state of every permission Tarsy depends on,
/// emits events on transition, and lets callers query on demand.
///
/// Lives on the main actor because all AX APIs and ScreenCaptureKit
/// helpers require the main thread.
///
/// Two responsibilities:
///   1. Handle explicit `permissions:status_request` packets from iOS
///      (synchronous `current()` call → reply).
///   2. Periodically poll in the background and fire callbacks when
///      any permission transitions. A green → red transition is
///      surfaced as a push notification ("You revoked Screen
///      Recording — Tarsy can no longer stream until you re-enable
///      it"). A red → green transition is just broadcast so the iOS
///      doctor UI updates live.
@MainActor
final class PermissionMonitor {

    private var lastKnown: TarsyPermissions? = nil
    private var pollTask: Task<Void, Never>? = nil

    /// Fired whenever any permission state changes (in either
    /// direction). Callback receives `(previous, current)`. `previous`
    /// is nil on the very first poll.
    var onChange: (@MainActor (TarsyPermissions?, TarsyPermissions) -> Void)? = nil

    /// Snapshot the current state synchronously. Safe to call from
    /// the packet handler on the main actor.
    func current() -> TarsyPermissions {
        TarsyPermissions(
            screenRecording: checkScreenRecording(),
            accessibility: checkAccessibility(),
            automation: checkAutomation(),
            fullDiskAccess: checkFullDiskAccess()
        )
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                // 10s is frequent enough to catch accidental
                // revocation within a reasonable window without
                // burning CPU. AX/TCC queries are cheap but not free.
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func tick() {
        let next = current()
        if lastKnown != next {
            let prev = lastKnown
            lastKnown = next
            onChange?(prev, next)
        }
    }

    // MARK: - Individual checks

    /// Screen Recording: CGPreflightScreenCaptureAccess is the
    /// canonical, non-prompting preflight. Note that on macOS 15+ this
    /// caches per-process at launch for some categories, but SR
    /// specifically still returns live state.
    private func checkScreenRecording() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Accessibility: use a live AX probe against another process
    /// rather than `AXIsProcessTrusted()`, which caches on macOS 15+.
    /// See `OnboardingWindow.checkAccessibilityPermission` for the
    /// rationale — we copy the same approach here.
    private func checkAccessibility() -> Bool {
        let ourPid = getpid()
        let probeTarget = NSWorkspace.shared.runningApplications.first { app in
            app.processIdentifier != ourPid
                && app.activationPolicy == .regular
                && app.processIdentifier > 0
        }
        guard let target = probeTarget else {
            return AXIsProcessTrusted()
        }
        let appElement = AXUIElementCreateApplication(target.processIdentifier)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement, kAXRoleAttribute as CFString, &value)
        return result != .apiDisabled
    }

    /// Automation (Apple Events): ask TCC about our permission to
    /// drive System Events. `AEDeterminePermissionToAutomateTarget`
    /// with `askUserIfNeeded: false` is a pure query, never prompts.
    private func checkAutomation() -> Bool {
        let target = NSAppleEventDescriptor(
            bundleIdentifier: "com.apple.systemevents")
        guard let aeDesc = target.aeDesc else { return false }
        let status = AEDeterminePermissionToAutomateTarget(
            aeDesc, typeWildCard, typeWildCard, false)
        return status == noErr
    }

    /// Full Disk Access: read-probe `/Library/Application Support/com.apple.TCC/TCC.db`,
    /// which exists on every Mac and is FDA-gated. `FileHandle` throws
    /// on EPERM. See `OnboardingWindow.checkFullDiskAccess` for the
    /// fallback rationale.
    private func checkFullDiskAccess() -> Bool {
        let tccDB = URL(fileURLWithPath:
            "/Library/Application Support/com.apple.TCC/TCC.db")
        if let handle = try? FileHandle(forReadingFrom: tccDB) {
            defer { try? handle.close() }
            if (try? handle.read(upToCount: 1)) != nil {
                return true
            }
        }
        let safari = NSHomeDirectory() + "/Library/Safari"
        if FileManager.default.fileExists(atPath: safari) {
            if (try? FileManager.default.contentsOfDirectory(atPath: safari)) != nil {
                return true
            }
        }
        return false
    }
}
