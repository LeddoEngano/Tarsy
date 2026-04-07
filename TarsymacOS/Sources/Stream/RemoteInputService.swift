import Foundation
import CoreGraphics
import AppKit

class RemoteInputService {
    private var windowId: CGWindowID = 0
    private var ownerPid: pid_t = 0
    private var isMobileSimulator = false

    // Simulator device info
    private var simulatorUDID: String?

    private let simulatorCropHeight: CGFloat = 52 // Must match ScreenCaptureService

    // Window state
    private var windowFocused = false

    private let inputQueue = DispatchQueue(label: "com.tarsy.remoteInput", qos: .userInteractive)
    private let eventSource = CGEventSource(stateID: .privateState)

    func setTargetWindow(frame: CGRect, windowId: CGWindowID, pid: pid_t, isSimulator: Bool, appName: String = "") {
        self.windowId = windowId
        self.ownerPid = pid
        self.isMobileSimulator = isSimulator
        self.windowFocused = false

        if isSimulator {
            detectSimulatorInfo()
        }

    }

    // MARK: - Tap

    func tap(relativeX: CGFloat, relativeY: CGFloat) {
        inputQueue.async { [self] in
            guard let point = absolutePoint(relativeX: relativeX, relativeY: relativeY) else { return }
            ensureWindowFocused()
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

    // MARK: - Double Tap

    func doubleTap(relativeX: CGFloat, relativeY: CGFloat) {
        inputQueue.async { [self] in
            guard let point = absolutePoint(relativeX: relativeX, relativeY: relativeY) else { return }
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

    // MARK: - Long Press

    func longPress(relativeX: CGFloat, relativeY: CGFloat) {
        inputQueue.async { [self] in
            guard let point = absolutePoint(relativeX: relativeX, relativeY: relativeY) else { return }
            ensureWindowFocused()
            if isMobileSimulator {
                // Simulator: hold left-click for ~1s to trigger iOS long press
                let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
                down?.post(tap: .cghidEventTap)
                usleep(1_000_000) // 1 second hold
                let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
                up?.post(tap: .cghidEventTap)
            } else {
                // Browser/desktop: right-click
                let down = CGEvent(mouseEventSource: eventSource, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right)
                down?.post(tap: .cghidEventTap)
                usleep(30_000)
                let up = CGEvent(mouseEventSource: eventSource, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right)
                up?.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - Scroll/Swipe

    // Simulator scroll state — scroll is simulated as a mouse drag (finger swipe)
    private var simDragActive = false
    private var simDragPoint: CGPoint = .zero

    func scrollStart(relativeX: CGFloat, relativeY: CGFloat) {
        if isMobileSimulator {
            inputQueue.async { [self] in
                guard let point = absolutePoint(relativeX: relativeX, relativeY: relativeY) else { return }
                ensureWindowFocused()
                // Start a mouse drag to simulate finger swipe in Simulator
                let move = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
                move?.post(tap: .cghidEventTap)
                usleep(5_000)
                let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
                down?.post(tap: .cghidEventTap)
                simDragPoint = point
                simDragActive = true
            }
        }
    }

    func scroll(relativeX: CGFloat, relativeY: CGFloat, deltaX: CGFloat, deltaY: CGFloat) {
        inputQueue.async { [self] in
            if isMobileSimulator {
                guard simDragActive else { return }
                // Continue the drag — move by delta pixels
                simDragPoint.x += deltaX
                simDragPoint.y += deltaY
                let drag = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDragged, mouseCursorPosition: simDragPoint, mouseButton: .left)
                drag?.post(tap: .cghidEventTap)
            } else {
                guard let point = absolutePoint(relativeX: relativeX, relativeY: relativeY) else { return }
                let move = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
                move?.post(tap: .cghidEventTap)
                if let scroll = CGEvent(scrollWheelEvent2Source: eventSource, units: .pixel, wheelCount: 2, wheel1: Int32(-deltaY * 3), wheel2: Int32(-deltaX * 3), wheel3: 0) {
                    scroll.post(tap: .cghidEventTap)
                }
            }
        }
    }

    func scrollEnd() {
        if isMobileSimulator {
            inputQueue.async { [self] in
                guard simDragActive else { return }
                let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: simDragPoint, mouseButton: .left)
                up?.post(tap: .cghidEventTap)
                simDragActive = false
            }
        }
    }

    // MARK: - Pinch (Simulator only — browser uses Cmd+/-)

    func pinchStart(relativeX: CGFloat, relativeY: CGFloat) {}
    func pinchUpdate(scale: CGFloat) {}
    func pinchEnd() {}

    // MARK: - Drag

    func drag(fromX: CGFloat, fromY: CGFloat, toX: CGFloat, toY: CGFloat) {
        inputQueue.async { [self] in
            guard let from = absolutePoint(relativeX: fromX, relativeY: fromY),
                  let to = absolutePoint(relativeX: toX, relativeY: toY) else { return }
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

    // MARK: - Device Buttons

    func pressButton(_ button: String) {
        guard isMobileSimulator else { return }

        switch button {
        case "home":
            // Cmd+Shift+H = Simulator Home
            sendSimulatorShortcut(virtualKey: 4, flags: [.maskCommand, .maskShift])
        case "lock":
            // Cmd+L = Simulator Lock
            sendSimulatorShortcut(virtualKey: 37, flags: .maskCommand)
        case "siri":
            // Long press on lock = Siri (Cmd+L held)
            sendSimulatorShortcut(virtualKey: 37, flags: .maskCommand, hold: true)
        case "rotate_left":
            // Cmd+Left Arrow = Rotate Left
            sendSimulatorShortcut(virtualKey: 123, flags: .maskCommand)
        case "rotate_right":
            // Cmd+Right Arrow = Rotate Right
            sendSimulatorShortcut(virtualKey: 124, flags: .maskCommand)
        case "screenshot":
            break
        default:
            #if DEBUG
            print("[RemoteInput] Unknown button: \(button)")
            #endif
        }
    }

    private func sendSimulatorShortcut(virtualKey: CGKeyCode, flags: CGEventFlags, hold: Bool = false) {
        inputQueue.async { [self] in
            ensureWindowFocused()
            let down = CGEvent(keyboardEventSource: eventSource, virtualKey: virtualKey, keyDown: true)
            down?.flags = flags
            down?.post(tap: .cghidEventTap)
            if hold {
                usleep(2_000_000) // 2s hold for Siri
            }
            let up = CGEvent(keyboardEventSource: eventSource, virtualKey: virtualKey, keyDown: false)
            up?.flags = flags
            up?.post(tap: .cghidEventTap)
        }
    }

    private func rotateSimulator(direction: String) {
        simctlQueue.async {
            let menuItem = direction == "left" ? "Rotate Left" : "Rotate Right"
            let script = "tell application \"System Events\" to tell process \"Simulator\" to click menu item \"\(menuItem)\" of menu \"Device\" of menu bar 1"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let errData = (process.standardError as? Pipe)?.fileHandleForReading.readDataToEndOfFile()
                    let errStr = errData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    #if DEBUG
                    print("[RemoteInput] Rotate failed: \(errStr)")
                    #endif
                }
            } catch {
                #if DEBUG
                print("[RemoteInput] Rotate error: \(error)")
                #endif
            }
        }
    }

    // MARK: - Keyboard

    func typeText(_ text: String) {
        inputQueue.async { [self] in
            ensureWindowFocused()
            if text == "\u{8}" {
                // Backspace — virtual key 51
                let down = CGEvent(keyboardEventSource: eventSource, virtualKey: 51, keyDown: true)
                down?.post(tap: .cghidEventTap)
                let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 51, keyDown: false)
                up?.post(tap: .cghidEventTap)
            } else if text == "\n" {
                // Return — virtual key 36
                let down = CGEvent(keyboardEventSource: eventSource, virtualKey: 36, keyDown: true)
                down?.post(tap: .cghidEventTap)
                let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 36, keyDown: false)
                up?.post(tap: .cghidEventTap)
            } else {
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
    }

    // MARK: - simctl Commands (Simulator buttons only)

    private let simctlQueue = DispatchQueue(label: "com.tarsy.simctl", qos: .userInteractive)

    private func runSimctl(_ args: [String]) {
        let argsCopy = args
        simctlQueue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl"] + argsCopy
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                #if DEBUG
                if process.terminationStatus != 0 {
                    let errData = (process.standardError as? Pipe)?.fileHandleForReading.readDataToEndOfFile()
                    let errStr = errData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    print("[RemoteInput] simctl FAIL: \(argsCopy) — \(errStr.prefix(300))")
                }
                #endif
            } catch {
                #if DEBUG
                print("[RemoteInput] simctl ERROR: \(error)")
                #endif
            }
        }
    }

    private func detectSimulatorInfo() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let simctl = Process()
            simctl.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            simctl.arguments = ["simctl", "list", "devices", "booted", "-j"]
            let pipe = Pipe()
            simctl.standardOutput = pipe
            simctl.standardError = Pipe()

            do {
                try simctl.run()
                simctl.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let devices = json["devices"] as? [String: [[String: Any]]] {
                    for (_, deviceList) in devices {
                        for device in deviceList {
                            if let state = device["state"] as? String, state == "Booted",
                               let udid = device["udid"] as? String {
                                simulatorUDID = udid
                                return
                            }
                        }
                    }
                }
            } catch {
                #if DEBUG
                print("[RemoteInput] Failed to detect simulator: \(error)")
                #endif
            }
        }
    }

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

    // MARK: - Coordinate Mapping

    /// Maps stream-relative coords (0-1) to absolute screen coords.
    /// For simulator: accounts for the cropped titlebar (stream doesn't include it, but the window does).
    /// For browser/desktop: direct mapping to window frame.
    private func absolutePoint(relativeX: CGFloat, relativeY: CGFloat) -> CGPoint? {
        guard let frame = getCurrentWindowFrame() else { return nil }
        if isMobileSimulator {
            return CGPoint(
                x: frame.origin.x + frame.width * relativeX,
                y: frame.origin.y + simulatorCropHeight + relativeY * (frame.height - simulatorCropHeight)
            )
        } else {
            return CGPoint(
                x: frame.origin.x + frame.width * relativeX,
                y: frame.origin.y + frame.height * relativeY
            )
        }
    }

    private func ensureWindowFocused() {
        guard !windowFocused else { return }
        if let app = NSRunningApplication(processIdentifier: ownerPid) {
            app.activate()
        }
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
        usleep(100_000)
        windowFocused = true
    }
}

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError
