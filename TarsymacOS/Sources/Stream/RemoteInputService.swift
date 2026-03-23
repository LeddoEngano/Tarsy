import Foundation
import CoreGraphics
import AppKit

class RemoteInputService {
    private var windowId: CGWindowID = 0
    private var ownerPid: pid_t = 0
    private var isMobileSimulator = false
    private let titleBarHeight: CGFloat = 28 // Simulator title bar

    // Stateful drag/pinch
    private var isDragging = false
    private var currentDragPoint: CGPoint = .zero
    private var isPinching = false
    private var pinchCenter: CGPoint = .zero

    // Serial queue for all input — prevents race conditions
    private let inputQueue = DispatchQueue(label: "com.tarsy.remoteInput", qos: .userInteractive)
    private let eventSource = CGEventSource(stateID: .privateState)

    func setTargetWindow(frame: CGRect, windowId: CGWindowID, pid: pid_t, isSimulator: Bool, appName: String = "") {
        self.windowId = windowId
        self.ownerPid = pid
        self.isMobileSimulator = isSimulator

        // One-time focus on setup
        focusWindowOnce()

        print("[RemoteInput] Target set: wid=\(windowId), pid=\(pid), sim=\(isSimulator)")
    }

    // MARK: - Input Actions

    func tap(relativeX: CGFloat, relativeY: CGFloat) {
        inputQueue.async { [self] in
            guard let point = currentAbsolutePoint(relativeX: relativeX, relativeY: relativeY) else { return }
            postMouseClick(at: point)
        }
    }

    func doubleTap(relativeX: CGFloat, relativeY: CGFloat) {
        inputQueue.async { [self] in
            guard let point = currentAbsolutePoint(relativeX: relativeX, relativeY: relativeY) else { return }
            for clickState in [1, 2] as [Int64] {
                let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
                down?.setIntegerValueField(.mouseEventClickState, value: clickState)
                postEvent(down)
                let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
                up?.setIntegerValueField(.mouseEventClickState, value: clickState)
                postEvent(up)
                usleep(10_000)
            }
        }
    }

    func longPress(relativeX: CGFloat, relativeY: CGFloat) {
        inputQueue.async { [self] in
            guard let point = currentAbsolutePoint(relativeX: relativeX, relativeY: relativeY) else { return }
            if isMobileSimulator {
                let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
                postEvent(down)
                usleep(800_000)
                let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
                postEvent(up)
            } else {
                let down = CGEvent(mouseEventSource: eventSource, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right)
                postEvent(down)
                usleep(50)
                let up = CGEvent(mouseEventSource: eventSource, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right)
                postEvent(up)
            }
        }
    }

    // MARK: - Stateful Scroll/Swipe

    func scrollStart(relativeX: CGFloat, relativeY: CGFloat) {
        inputQueue.async { [self] in
            guard let point = currentAbsolutePoint(relativeX: relativeX, relativeY: relativeY) else { return }

            if isMobileSimulator {
                // Start a continuous drag for simulator swipe
                let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
                postEvent(down)
                isDragging = true
                currentDragPoint = point
            }
        }
    }

    func scroll(relativeX: CGFloat, relativeY: CGFloat, deltaX: CGFloat, deltaY: CGFloat) {
        inputQueue.async { [self] in
            if isMobileSimulator && isDragging {
                // Continue the drag — move by incremental delta
                currentDragPoint.x += deltaX
                currentDragPoint.y += deltaY
                let drag = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDragged, mouseCursorPosition: currentDragPoint, mouseButton: .left)
                postEvent(drag)
            } else if !isMobileSimulator {
                // Browser: scroll wheel
                guard let point = currentAbsolutePoint(relativeX: relativeX, relativeY: relativeY) else { return }
                let move = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
                postEvent(move)
                if let scroll = CGEvent(scrollWheelEvent2Source: eventSource, units: .pixel, wheelCount: 2, wheel1: Int32(deltaY), wheel2: Int32(deltaX), wheel3: 0) {
                    postEvent(scroll)
                }
            }
        }
    }

    func scrollEnd() {
        inputQueue.async { [self] in
            if isMobileSimulator && isDragging {
                let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: currentDragPoint, mouseButton: .left)
                postEvent(up)
                isDragging = false
            }
        }
    }

    // MARK: - Stateful Pinch (Simulator only)

    func pinchStart(relativeX: CGFloat, relativeY: CGFloat) {
        inputQueue.async { [self] in
            guard isMobileSimulator else { return }
            guard let point = currentAbsolutePoint(relativeX: relativeX, relativeY: relativeY) else { return }

            pinchCenter = point
            isPinching = true

            // Move mouse to pinch center
            let move = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
            postEvent(move)
            usleep(30_000)

            // Press Option key (activates two-finger mode in Simulator)
            let optDown = CGEvent(keyboardEventSource: eventSource, virtualKey: 0x3A, keyDown: true)
            postEvent(optDown)
            usleep(30_000)

            // Mouse down
            let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
            postEvent(down)
        }
    }

    func pinchUpdate(scale: CGFloat) {
        inputQueue.async { [self] in
            guard isMobileSimulator, isPinching else { return }
            // Scale > 1 = zoom in = drag up (negative Y), Scale < 1 = zoom out = drag down
            let delta = -(scale - 1.0) * 50
            let newPoint = CGPoint(x: pinchCenter.x, y: pinchCenter.y + delta)
            let drag = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDragged, mouseCursorPosition: newPoint, mouseButton: .left)
            postEvent(drag)
        }
    }

    func pinchEnd() {
        inputQueue.async { [self] in
            guard isMobileSimulator, isPinching else { return }

            // Release mouse
            let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: pinchCenter, mouseButton: .left)
            postEvent(up)
            usleep(20_000)

            // Release Option key
            let optUp = CGEvent(keyboardEventSource: eventSource, virtualKey: 0x3A, keyDown: false)
            postEvent(optUp)

            isPinching = false
        }
    }

    // MARK: - Drag

    func drag(fromX: CGFloat, fromY: CGFloat, toX: CGFloat, toY: CGFloat) {
        inputQueue.async { [self] in
            guard let from = currentAbsolutePoint(relativeX: fromX, relativeY: fromY),
                  let to = currentAbsolutePoint(relativeX: toX, relativeY: toY) else { return }

            let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left)
            postEvent(down)

            let steps = 10
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
                let drag = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)
                postEvent(drag)
                usleep(10_000)
            }

            let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)
            postEvent(up)
        }
    }

    // MARK: - Keyboard

    func typeText(_ text: String) {
        inputQueue.async { [self] in
            for char in text {
                let str = String(char)
                let event = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true)
                let chars = Array(str.utf16)
                event?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
                postEvent(event)
                let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false)
                postEvent(up)
                usleep(3_000)
            }
        }
    }

    // MARK: - Private

    /// Get current window frame from system (always fresh, handles window moves)
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

    /// Convert relative coords (0-1) to absolute screen coords, refreshing window frame
    private func currentAbsolutePoint(relativeX: CGFloat, relativeY: CGFloat) -> CGPoint? {
        guard let frame = getCurrentWindowFrame() else {
            print("[RemoteInput] Could not get window frame for \(windowId)")
            return nil
        }

        if isMobileSimulator {
            // Exclude title bar — map only to simulator content area
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

    /// Post event directly to target process (works even when window is behind others)
    private func postEvent(_ event: CGEvent?) {
        guard let event else { return }
        event.postToPid(ownerPid)
    }

    /// Post a simple click
    private func postMouseClick(at point: CGPoint) {
        let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        postEvent(down)
        usleep(50)
        let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        postEvent(up)
    }

    /// Focus the target window once during setup
    private func focusWindowOnce() {
        inputQueue.async { [self] in
            if let app = NSRunningApplication(processIdentifier: ownerPid) {
                app.activate()
            }

            let appElement = AXUIElementCreateApplication(ownerPid)
            var windowsRef: CFTypeRef?
            AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
            if let windows = windowsRef as? [AXUIElement] {
                for window in windows {
                    var wid: CGWindowID = 0
                    _AXUIElementGetWindow(window, &wid)
                    if wid == windowId {
                        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                        return
                    }
                }
                if let first = windows.first {
                    AXUIElementPerformAction(first, kAXRaiseAction as CFString)
                }
            }
        }
    }
}

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError
