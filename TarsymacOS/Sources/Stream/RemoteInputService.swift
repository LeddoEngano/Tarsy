import Foundation
import CoreGraphics
import AppKit

class RemoteInputService {
    private var windowId: CGWindowID = 0
    private var ownerPid: pid_t = 0
    private var isMobileSimulator = false
    private let titleBarHeight: CGFloat = 28

    // Stateful drag/pinch
    private var isDragging = false
    private var currentDragPoint: CGPoint = .zero
    private var isPinching = false
    private var pinchCenter: CGPoint = .zero

    private let inputQueue = DispatchQueue(label: "com.tarsy.remoteInput", qos: .userInteractive)
    private let eventSource = CGEventSource(stateID: .privateState)
    private var windowFocused = false

    func setTargetWindow(frame: CGRect, windowId: CGWindowID, pid: pid_t, isSimulator: Bool, appName: String = "") {
        self.windowId = windowId
        self.ownerPid = pid
        self.isMobileSimulator = isSimulator
        self.windowFocused = false
        print("[RemoteInput] Target set: wid=\(windowId), pid=\(pid), sim=\(isSimulator)")
    }

    // MARK: - Input Actions

    func tap(relativeX: CGFloat, relativeY: CGFloat) {
        inputQueue.async { [self] in
            guard let point = currentAbsolutePoint(relativeX: relativeX, relativeY: relativeY) else { return }
            ensureWindowFocused()

            // Move cursor first, then click
            let move = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
            move?.post(tap: .cghidEventTap)
            usleep(10_000)

            let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
            down?.post(tap: .cghidEventTap)
            usleep(30_000)
            let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
            up?.post(tap: .cghidEventTap)
        }
    }

    func doubleTap(relativeX: CGFloat, relativeY: CGFloat) {
        inputQueue.async { [self] in
            guard let point = currentAbsolutePoint(relativeX: relativeX, relativeY: relativeY) else { return }
            ensureWindowFocused()

            let move = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
            move?.post(tap: .cghidEventTap)
            usleep(10_000)

            for clickState in [1, 2] as [Int64] {
                let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
                down?.setIntegerValueField(.mouseEventClickState, value: clickState)
                down?.post(tap: .cghidEventTap)
                usleep(20_000)
                let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
                up?.setIntegerValueField(.mouseEventClickState, value: clickState)
                up?.post(tap: .cghidEventTap)
                usleep(20_000)
            }
        }
    }

    func longPress(relativeX: CGFloat, relativeY: CGFloat) {
        inputQueue.async { [self] in
            guard let point = currentAbsolutePoint(relativeX: relativeX, relativeY: relativeY) else { return }
            ensureWindowFocused()

            if isMobileSimulator {
                let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
                down?.post(tap: .cghidEventTap)
                usleep(800_000)
                let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
                up?.post(tap: .cghidEventTap)
            } else {
                let down = CGEvent(mouseEventSource: eventSource, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right)
                down?.post(tap: .cghidEventTap)
                usleep(30_000)
                let up = CGEvent(mouseEventSource: eventSource, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right)
                up?.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - Stateful Scroll/Swipe

    func scrollStart(relativeX: CGFloat, relativeY: CGFloat) {
        inputQueue.async { [self] in
            guard let point = currentAbsolutePoint(relativeX: relativeX, relativeY: relativeY) else { return }
            ensureWindowFocused()

            if isMobileSimulator {
                let move = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
                move?.post(tap: .cghidEventTap)
                usleep(10_000)
                let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
                down?.post(tap: .cghidEventTap)
                isDragging = true
                currentDragPoint = point
            }
        }
    }

    func scroll(relativeX: CGFloat, relativeY: CGFloat, deltaX: CGFloat, deltaY: CGFloat) {
        inputQueue.async { [self] in
            if isMobileSimulator && isDragging {
                currentDragPoint.x += deltaX
                currentDragPoint.y += deltaY
                let drag = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDragged, mouseCursorPosition: currentDragPoint, mouseButton: .left)
                drag?.post(tap: .cghidEventTap)
            } else if !isMobileSimulator {
                guard let point = currentAbsolutePoint(relativeX: relativeX, relativeY: relativeY) else { return }
                let move = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
                move?.post(tap: .cghidEventTap)
                if let scroll = CGEvent(scrollWheelEvent2Source: eventSource, units: .pixel, wheelCount: 2, wheel1: Int32(deltaY), wheel2: Int32(deltaX), wheel3: 0) {
                    scroll.post(tap: .cghidEventTap)
                }
            }
        }
    }

    func scrollEnd() {
        inputQueue.async { [self] in
            if isMobileSimulator && isDragging {
                let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: currentDragPoint, mouseButton: .left)
                up?.post(tap: .cghidEventTap)
                isDragging = false
            }
        }
    }

    // MARK: - Stateful Pinch

    func pinchStart(relativeX: CGFloat, relativeY: CGFloat) {
        inputQueue.async { [self] in
            guard isMobileSimulator else { return }
            guard let point = currentAbsolutePoint(relativeX: relativeX, relativeY: relativeY) else { return }
            ensureWindowFocused()

            pinchCenter = point
            isPinching = true

            let move = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
            move?.post(tap: .cghidEventTap)
            usleep(30_000)

            // Option key = two-finger mode in Simulator
            let optDown = CGEvent(keyboardEventSource: eventSource, virtualKey: 0x3A, keyDown: true)
            optDown?.post(tap: .cghidEventTap)
            usleep(30_000)

            let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
            down?.post(tap: .cghidEventTap)
        }
    }

    func pinchUpdate(scale: CGFloat) {
        inputQueue.async { [self] in
            guard isMobileSimulator, isPinching else { return }
            let delta = -(scale - 1.0) * 50
            let newPoint = CGPoint(x: pinchCenter.x, y: pinchCenter.y + delta)
            let drag = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDragged, mouseCursorPosition: newPoint, mouseButton: .left)
            drag?.post(tap: .cghidEventTap)
        }
    }

    func pinchEnd() {
        inputQueue.async { [self] in
            guard isMobileSimulator, isPinching else { return }
            let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: pinchCenter, mouseButton: .left)
            up?.post(tap: .cghidEventTap)
            usleep(20_000)
            let optUp = CGEvent(keyboardEventSource: eventSource, virtualKey: 0x3A, keyDown: false)
            optUp?.post(tap: .cghidEventTap)
            isPinching = false
        }
    }

    // MARK: - Drag

    func drag(fromX: CGFloat, fromY: CGFloat, toX: CGFloat, toY: CGFloat) {
        inputQueue.async { [self] in
            guard let from = currentAbsolutePoint(relativeX: fromX, relativeY: fromY),
                  let to = currentAbsolutePoint(relativeX: toX, relativeY: toY) else { return }
            ensureWindowFocused()

            let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left)
            down?.post(tap: .cghidEventTap)
            let steps = 10
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
                let d = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)
                d?.post(tap: .cghidEventTap)
                usleep(10_000)
            }
            let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)
            up?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Keyboard

    func typeText(_ text: String) {
        inputQueue.async { [self] in
            ensureWindowFocused()
            for char in text {
                let str = String(char)
                let event = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true)
                let chars = Array(str.utf16)
                event?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
                event?.post(tap: .cghidEventTap)
                let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false)
                up?.post(tap: .cghidEventTap)
                usleep(3_000)
            }
        }
    }

    // MARK: - Private

    private func getCurrentWindowFrame() -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowId) as? [[String: Any]],
              let windowInfo = info.first,
              let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
              let x = boundsDict["X"] as? CGFloat,
              let y = boundsDict["Y"] as? CGFloat,
              let w = boundsDict["Width"] as? CGFloat,
              let h = boundsDict["Height"] as? CGFloat else {
            return nil
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func currentAbsolutePoint(relativeX: CGFloat, relativeY: CGFloat) -> CGPoint? {
        guard let frame = getCurrentWindowFrame() else {
            print("[RemoteInput] Window \(windowId) not found")
            return nil
        }

        if isMobileSimulator {
            let contentY = frame.origin.y + titleBarHeight
            let contentHeight = frame.height - titleBarHeight
            return CGPoint(
                x: frame.origin.x + frame.width * relativeX,
                y: contentY + contentHeight * relativeY
            )
        } else {
            return CGPoint(
                x: frame.origin.x + frame.width * relativeX,
                y: frame.origin.y + frame.height * relativeY
            )
        }
    }

    /// Focus the target window — called once, then cached
    private func ensureWindowFocused() {
        guard !windowFocused else { return }

        // Activate the app
        if let app = NSRunningApplication(processIdentifier: ownerPid) {
            app.activate()
        }

        // Raise the specific window via Accessibility API
        let appElement = AXUIElementCreateApplication(ownerPid)
        var windowsRef: CFTypeRef?
        AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        if let windows = windowsRef as? [AXUIElement] {
            for window in windows {
                var wid: CGWindowID = 0
                _ = _AXUIElementGetWindow(window, &wid)
                if wid == windowId {
                    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                    break
                }
            }
        }

        usleep(100_000) // Wait for window to come to front
        windowFocused = true
    }
}

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError
