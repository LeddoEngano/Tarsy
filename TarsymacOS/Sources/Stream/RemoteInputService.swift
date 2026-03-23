import Foundation
import CoreGraphics
import AppKit

class RemoteInputService {
    private var windowFrame: CGRect = .zero
    private var windowId: CGWindowID = 0
    private var ownerPid: pid_t = 0
    private var appName: String = ""
    private var isMobileSimulator = false

    func setTargetWindow(frame: CGRect, windowId: CGWindowID, pid: pid_t, isSimulator: Bool, appName: String = "") {
        self.windowFrame = frame
        self.windowId = windowId
        self.ownerPid = pid
        self.isMobileSimulator = isSimulator
        self.appName = appName
        print("[RemoteInput] Target: frame=\(frame), id=\(windowId), pid=\(pid), sim=\(isSimulator), app=\(appName)")
    }

    func tap(relativeX: CGFloat, relativeY: CGFloat) {
        let point = absolutePoint(relativeX: relativeX, relativeY: relativeY)
        focusTargetWindow {
            let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
            down?.post(tap: .cghidEventTap)
            usleep(20_000)
            let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
            up?.post(tap: .cghidEventTap)
        }
    }

    func doubleTap(relativeX: CGFloat, relativeY: CGFloat) {
        let point = absolutePoint(relativeX: relativeX, relativeY: relativeY)
        focusTargetWindow {
            for clickNum in [1, 2] as [Int64] {
                let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
                down?.setIntegerValueField(.mouseEventClickState, value: clickNum)
                down?.post(tap: .cghidEventTap)
                let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
                up?.setIntegerValueField(.mouseEventClickState, value: clickNum)
                up?.post(tap: .cghidEventTap)
                usleep(10_000)
            }
        }
    }

    func longPress(relativeX: CGFloat, relativeY: CGFloat) {
        let point = absolutePoint(relativeX: relativeX, relativeY: relativeY)
        focusTargetWindow {
            if self.isMobileSimulator {
                // Simulator: long press = hold mouse down
                let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
                down?.post(tap: .cghidEventTap)
                usleep(800_000) // hold 0.8s
                let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
                up?.post(tap: .cghidEventTap)
            } else {
                let down = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right)
                down?.post(tap: .cghidEventTap)
                usleep(20_000)
                let up = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right)
                up?.post(tap: .cghidEventTap)
            }
        }
    }

    func scroll(relativeX: CGFloat, relativeY: CGFloat, deltaX: CGFloat, deltaY: CGFloat) {
        let point = absolutePoint(relativeX: relativeX, relativeY: relativeY)

        if isMobileSimulator {
            // Simulator: drag = touch swipe
            performDrag(from: point, deltaX: deltaX * 8, deltaY: deltaY * 8)
        } else {
            // Browser/desktop: scroll wheel
            let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
            move?.post(tap: .cghidEventTap)

            if let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(deltaY * 5), wheel2: Int32(deltaX * 5), wheel3: 0) {
                scroll.post(tap: .cghidEventTap)
            }
        }
    }

    /// Pinch gesture for simulator — uses Option key + drag
    func pinch(relativeX: CGFloat, relativeY: CGFloat, scale: CGFloat) {
        guard isMobileSimulator else { return }
        let point = absolutePoint(relativeX: relativeX, relativeY: relativeY)

        // Move mouse to center point
        let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        move?.post(tap: .cghidEventTap)
        usleep(50_000)

        // Hold Option key (simulates pinch in iOS Simulator)
        let optionDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x3A, keyDown: true) // 0x3A = Option
        optionDown?.post(tap: .cghidEventTap)
        usleep(50_000)

        // Drag up or down based on scale
        let dragDistance: CGFloat = scale > 1.0 ? -30 : 30 // negative = zoom in, positive = zoom out
        let steps = 8

        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        down?.post(tap: .cghidEventTap)

        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: point.x, y: point.y + dragDistance * t)
            let drag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)
            drag?.post(tap: .cghidEventTap)
            usleep(20_000)
        }

        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: point.x, y: point.y + dragDistance), mouseButton: .left)
        up?.post(tap: .cghidEventTap)

        // Release Option
        let optionUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x3A, keyDown: false)
        optionUp?.post(tap: .cghidEventTap)
    }

    func drag(fromX: CGFloat, fromY: CGFloat, toX: CGFloat, toY: CGFloat) {
        let from = absolutePoint(relativeX: fromX, relativeY: fromY)
        let to = absolutePoint(relativeX: toX, relativeY: toY)
        focusTargetWindow {
            self.performDragAbsolute(from: from, to: to)
        }
    }

    func typeText(_ text: String) {
        focusTargetWindow {
            for char in text {
                let str = String(char)
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
                let chars = Array(str.utf16)
                event?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
                event?.post(tap: .cghidEventTap)
                let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
                up?.post(tap: .cghidEventTap)
                usleep(5_000)
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

    private func performDrag(from point: CGPoint, deltaX: CGFloat, deltaY: CGFloat) {
        let endPoint = CGPoint(x: point.x + deltaX, y: point.y + deltaY)
        performDragAbsolute(from: point, to: endPoint)
    }

    private func performDragAbsolute(from: CGPoint, to: CGPoint) {
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left)
        down?.post(tap: .cghidEventTap)

        let steps = 10
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            let drag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)
            drag?.post(tap: .cghidEventTap)
            usleep(15_000)
        }

        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)
        up?.post(tap: .cghidEventTap)
    }

    private func focusTargetWindow(then action: @escaping () -> Void) {
        // Use AppleScript to bring the specific app window to front
        DispatchQueue.global(qos: .userInteractive).async { [self] in
            // First: activate the app
            if let app = NSRunningApplication(processIdentifier: ownerPid) {
                app.activate(options: [.activateIgnoringOtherApps])
            }

            // Second: use AppleScript to raise the specific window
            if !appName.isEmpty {
                let script = """
                tell application "\(appName)"
                    activate
                end tell
                """
                if let appleScript = NSAppleScript(source: script) {
                    var error: NSDictionary?
                    appleScript.executeAndReturnError(&error)
                }
            }

            // Wait for window to come to front
            usleep(150_000)

            // Now perform the action
            action()
        }
    }
}
