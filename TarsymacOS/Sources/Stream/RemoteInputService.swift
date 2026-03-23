import Foundation
import CoreGraphics
import AppKit

class RemoteInputService {
    private var windowFrame: CGRect = .zero
    private var windowId: CGWindowID = 0
    private var ownerPid: pid_t = 0
    private var isMobileSimulator = false

    /// Set the target window for input events
    func setTargetWindow(frame: CGRect, windowId: CGWindowID, pid: pid_t, isSimulator: Bool) {
        self.windowFrame = frame
        self.windowId = windowId
        self.ownerPid = pid
        self.isMobileSimulator = isSimulator
        print("[RemoteInput] Target: frame=\(frame), id=\(windowId), pid=\(pid), simulator=\(isSimulator)")
    }

    /// Tap at relative position (0.0-1.0)
    func tap(relativeX: CGFloat, relativeY: CGFloat) {
        let point = absolutePoint(relativeX: relativeX, relativeY: relativeY)
        focusTargetWindow()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
            down?.post(tap: .cghidEventTap)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
                up?.post(tap: .cghidEventTap)
            }
        }
    }

    /// Double tap at relative position
    func doubleTap(relativeX: CGFloat, relativeY: CGFloat) {
        let point = absolutePoint(relativeX: relativeX, relativeY: relativeY)
        focusTargetWindow()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            for clickNum in [1, 2] as [Int64] {
                let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
                down?.setIntegerValueField(.mouseEventClickState, value: clickNum)
                down?.post(tap: .cghidEventTap)

                let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
                up?.setIntegerValueField(.mouseEventClickState, value: clickNum)
                up?.post(tap: .cghidEventTap)
            }
        }
    }

    /// Long press (right click) at relative position
    func longPress(relativeX: CGFloat, relativeY: CGFloat) {
        let point = absolutePoint(relativeX: relativeX, relativeY: relativeY)
        focusTargetWindow()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let down = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right)
            down?.post(tap: .cghidEventTap)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                let up = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right)
                up?.post(tap: .cghidEventTap)
            }
        }
    }

    /// Swipe/scroll — on simulator does a drag, on browser does scroll wheel
    func scroll(relativeX: CGFloat, relativeY: CGFloat, deltaX: CGFloat, deltaY: CGFloat) {
        if isMobileSimulator {
            // Simulator: drag gesture (touch simulation)
            let point = absolutePoint(relativeX: relativeX, relativeY: relativeY)
            let endPoint = CGPoint(x: point.x + deltaX * 5, y: point.y + deltaY * 5)

            let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
            down?.post(tap: .cghidEventTap)

            // Smooth drag
            let steps = 8
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let p = CGPoint(x: point.x + (endPoint.x - point.x) * t, y: point.y + (endPoint.y - point.y) * t)
                let drag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)
                drag?.post(tap: .cghidEventTap)
            }

            let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: endPoint, mouseButton: .left)
            up?.post(tap: .cghidEventTap)
        } else {
            // Browser/desktop: scroll wheel
            let point = absolutePoint(relativeX: relativeX, relativeY: relativeY)

            let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
            move?.post(tap: .cghidEventTap)

            if let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(deltaY * 5), wheel2: Int32(deltaX * 5), wheel3: 0) {
                scroll.post(tap: .cghidEventTap)
            }
        }
    }

    /// Drag from one point to another
    func drag(fromX: CGFloat, fromY: CGFloat, toX: CGFloat, toY: CGFloat) {
        let from = absolutePoint(relativeX: fromX, relativeY: fromY)
        let to = absolutePoint(relativeX: toX, relativeY: toY)
        focusTargetWindow()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left)
            down?.post(tap: .cghidEventTap)

            let steps = 10
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
                let drag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)
                drag?.post(tap: .cghidEventTap)
            }

            let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)
            up?.post(tap: .cghidEventTap)
        }
    }

    /// Type text
    func typeText(_ text: String) {
        focusTargetWindow()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            for char in text {
                let str = String(char)
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
                let chars = Array(str.utf16)
                event?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
                event?.post(tap: .cghidEventTap)

                let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
                up?.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - Private

    private func absolutePoint(relativeX: CGFloat, relativeY: CGFloat) -> CGPoint {
        CGPoint(
            x: windowFrame.origin.x + windowFrame.width * relativeX,
            y: windowFrame.origin.y + windowFrame.height * relativeY
        )
    }

    private func focusTargetWindow() {
        // Activate the owning app
        if let app = NSRunningApplication(processIdentifier: ownerPid) {
            app.activate()
        }

        // Use Accessibility API to raise the specific window
        let appElement = AXUIElementCreateApplication(ownerPid)
        var windowsRef: CFTypeRef?
        AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)

        if let windows = windowsRef as? [AXUIElement] {
            for window in windows {
                var windowIdRef: CFTypeRef?
                // Try to match by window ID via _AXUIElementGetWindow
                var wid: CGWindowID = 0
                _AXUIElementGetWindow(window, &wid)
                if wid == windowId {
                    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                    return
                }
            }
            // Fallback: raise first window
            if let first = windows.first {
                AXUIElementPerformAction(first, kAXRaiseAction as CFString)
            }
        }
    }
}

// Private API to get window ID from AXUIElement
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError
