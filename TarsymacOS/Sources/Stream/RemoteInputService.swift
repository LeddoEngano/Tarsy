import Foundation
import CoreGraphics
import AppKit

class RemoteInputService {
    private var windowFrame: CGRect = .zero
    private var windowId: CGWindowID = 0

    /// Set the target window for input events
    func setTargetWindow(frame: CGRect, windowId: CGWindowID) {
        self.windowFrame = frame
        self.windowId = windowId
        print("[RemoteInput] Target window set: \(frame), id: \(windowId)")
    }

    /// Tap at relative position (0.0-1.0)
    func tap(relativeX: CGFloat, relativeY: CGFloat) {
        let point = absolutePoint(relativeX: relativeX, relativeY: relativeY)
        print("[RemoteInput] Tap at \(point)")

        // Bring window to front
        bringWindowToFront()

        // Small delay to ensure window is focused
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Move mouse and click
            let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
            moveEvent?.post(tap: .cghidEventTap)

            let downEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
            downEvent?.post(tap: .cghidEventTap)

            let upEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
            upEvent?.post(tap: .cghidEventTap)
        }
    }

    /// Double tap at relative position
    func doubleTap(relativeX: CGFloat, relativeY: CGFloat) {
        let point = absolutePoint(relativeX: relativeX, relativeY: relativeY)
        print("[RemoteInput] Double tap at \(point)")

        bringWindowToFront()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let downEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
            downEvent?.setIntegerValueField(.mouseEventClickState, value: 2)
            downEvent?.post(tap: .cghidEventTap)

            let upEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
            upEvent?.setIntegerValueField(.mouseEventClickState, value: 2)
            upEvent?.post(tap: .cghidEventTap)
        }
    }

    /// Long press (right click) at relative position
    func longPress(relativeX: CGFloat, relativeY: CGFloat) {
        let point = absolutePoint(relativeX: relativeX, relativeY: relativeY)
        print("[RemoteInput] Right click at \(point)")

        bringWindowToFront()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let downEvent = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right)
            downEvent?.post(tap: .cghidEventTap)

            let upEvent = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right)
            upEvent?.post(tap: .cghidEventTap)
        }
    }

    /// Scroll at relative position
    func scroll(relativeX: CGFloat, relativeY: CGFloat, deltaX: CGFloat, deltaY: CGFloat) {
        let point = absolutePoint(relativeX: relativeX, relativeY: relativeY)

        // Move mouse to position first
        let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        moveEvent?.post(tap: .cghidEventTap)

        // Send scroll event
        if let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(deltaY * 3), wheel2: Int32(deltaX * 3), wheel3: 0) {
            scrollEvent.post(tap: .cghidEventTap)
        }
    }

    /// Drag from one point to another
    func drag(fromX: CGFloat, fromY: CGFloat, toX: CGFloat, toY: CGFloat) {
        let from = absolutePoint(relativeX: fromX, relativeY: fromY)
        let to = absolutePoint(relativeX: toX, relativeY: toY)

        bringWindowToFront()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let downEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left)
            downEvent?.post(tap: .cghidEventTap)

            // Drag in steps for smoothness
            let steps = 10
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let x = from.x + (to.x - from.x) * t
                let y = from.y + (to.y - from.y) * t
                let dragEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)
                dragEvent?.post(tap: .cghidEventTap)
            }

            let upEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)
            upEvent?.post(tap: .cghidEventTap)
        }
    }

    /// Type text
    func typeText(_ text: String) {
        for char in text {
            let str = String(char)
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            let chars = Array(str.utf16)
            event?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
            event?.post(tap: .cghidEventTap)

            let upEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            upEvent?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Private

    private func absolutePoint(relativeX: CGFloat, relativeY: CGFloat) -> CGPoint {
        CGPoint(
            x: windowFrame.origin.x + windowFrame.width * relativeX,
            y: windowFrame.origin.y + windowFrame.height * relativeY
        )
    }

    private func bringWindowToFront() {
        // Use AppleScript to bring the window's app to front
        if let app = NSWorkspace.shared.runningApplications.first(where: { app in
            guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return false }
            return windows.contains { ($0[kCGWindowNumber as String] as? CGWindowID) == windowId && ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier }
        }) {
            app.activate()
        }
    }
}
