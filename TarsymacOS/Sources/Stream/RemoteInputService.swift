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
            rotateSimulator(direction: "Rotate Left")
        case "rotate_right":
            rotateSimulator(direction: "Rotate Right")
        case "app_switcher":
            // Double Cmd+Shift+H = App Switcher
            inputQueue.async { [self] in
                ensureWindowFocused()
                let flags: CGEventFlags = [.maskCommand, .maskShift]
                for _ in 0..<2 {
                    let down = CGEvent(keyboardEventSource: eventSource, virtualKey: 4, keyDown: true)
                    down?.flags = flags
                    down?.post(tap: .cghidEventTap)
                    let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 4, keyDown: false)
                    up?.flags = flags
                    up?.post(tap: .cghidEventTap)
                    usleep(100_000)
                }
            }
        case "screenshot":
            break
        default:
            #if DEBUG
            print("[RemoteInput] Unknown button: \(button)")
            #endif
        }
    }

    var onRotate: (() -> Void)?

    private func rotateSimulator(direction: String) {
        inputQueue.async { [self] in
            ensureWindowFocused()
            let key: CGKeyCode = direction == "Rotate Left" ? 123 : 124
            let down = CGEvent(keyboardEventSource: eventSource, virtualKey: key, keyDown: true)
            down?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(keyboardEventSource: eventSource, virtualKey: key, keyDown: false)
            up?.flags = .maskCommand
            up?.post(tap: .cghidEventTap)
            // Give the Simulator time to resize its window, then restart capture
            usleep(500_000)
            DispatchQueue.main.async { [self] in
                onRotate?()
            }
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

    // MARK: - Keyboard

    // macOS virtual key code map (US keyboard layout)
    private static let keyCodeMap: [Character: (keyCode: CGKeyCode, shift: Bool)] = [
        "a": (0x00, false), "s": (0x01, false), "d": (0x02, false), "f": (0x03, false),
        "h": (0x04, false), "g": (0x05, false), "z": (0x06, false), "x": (0x07, false),
        "c": (0x08, false), "v": (0x09, false), "b": (0x0B, false), "q": (0x0C, false),
        "w": (0x0D, false), "e": (0x0E, false), "r": (0x0F, false), "y": (0x10, false),
        "t": (0x11, false), "1": (0x12, false), "2": (0x13, false), "3": (0x14, false),
        "4": (0x15, false), "6": (0x16, false), "5": (0x17, false), "=": (0x18, false),
        "9": (0x19, false), "7": (0x1A, false), "-": (0x1B, false), "8": (0x1C, false),
        "0": (0x1D, false), "]": (0x1E, false), "o": (0x1F, false), "u": (0x20, false),
        "[": (0x21, false), "i": (0x22, false), "p": (0x23, false), "l": (0x25, false),
        "j": (0x26, false), "'": (0x27, false), "k": (0x28, false), ";": (0x29, false),
        "\\": (0x2A, false), ",": (0x2B, false), "/": (0x2C, false), "n": (0x2D, false),
        "m": (0x2E, false), ".": (0x2F, false), " ": (0x31, false), "`": (0x32, false),
        // Shifted variants
        "A": (0x00, true), "S": (0x01, true), "D": (0x02, true), "F": (0x03, true),
        "H": (0x04, true), "G": (0x05, true), "Z": (0x06, true), "X": (0x07, true),
        "C": (0x08, true), "V": (0x09, true), "B": (0x0B, true), "Q": (0x0C, true),
        "W": (0x0D, true), "E": (0x0E, true), "R": (0x0F, true), "Y": (0x10, true),
        "T": (0x11, true), "!": (0x12, true), "@": (0x13, true), "#": (0x14, true),
        "$": (0x15, true), "^": (0x16, true), "%": (0x17, true), "+": (0x18, true),
        "(": (0x19, true), "&": (0x1A, true), "_": (0x1B, true), "*": (0x1C, true),
        ")": (0x1D, true), "}": (0x1E, true), "O": (0x1F, true), "U": (0x20, true),
        "{": (0x21, true), "I": (0x22, true), "P": (0x23, true), "L": (0x25, true),
        "J": (0x26, true), "\"": (0x27, true), "K": (0x28, true), ":": (0x29, true),
        "|": (0x2A, true), "<": (0x2B, true), "?": (0x2C, true), "N": (0x2D, true),
        "M": (0x2E, true), ">": (0x2F, true), "~": (0x32, true),
    ]

    func typeText(_ text: String) {
        inputQueue.async { [self] in
            ensureWindowFocused()
            if text == "\u{8}" {
                postKey(code: 51)
            } else if text == "\n" {
                postKey(code: 36)
            } else if text == "\t" {
                postKey(code: 48)
            } else {
                for char in text {
                    if let mapping = Self.keyCodeMap[char] {
                        postKey(code: mapping.keyCode, shift: mapping.shift, char: char)
                    } else {
                        // Fallback for unmapped characters: use unicode string with keyCode 0
                        let str = String(char)
                        let chars = Array(str.utf16)
                        let down = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true)
                        down?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
                        down?.post(tap: .cghidEventTap)
                        let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false)
                        up?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
                        up?.post(tap: .cghidEventTap)
                    }
                    usleep(3_000)
                }
            }
        }
    }

    private func postKey(code: CGKeyCode, shift: Bool = false, char: Character? = nil) {
        // For shifted characters, physically press and release the Shift key (keyCode 56)
        if shift {
            let shiftDown = CGEvent(keyboardEventSource: eventSource, virtualKey: 56, keyDown: true)
            shiftDown?.flags = .maskShift
            shiftDown?.post(tap: .cghidEventTap)
        }

        let down = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: true)
        if shift { down?.flags = .maskShift }
        if let char = char {
            let chars = Array(String(char).utf16)
            down?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
        }
        down?.post(tap: .cghidEventTap)

        let up = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: false)
        if shift { up?.flags = .maskShift }
        if let char = char {
            let chars = Array(String(char).utf16)
            up?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
        }
        up?.post(tap: .cghidEventTap)

        if shift {
            let shiftUp = CGEvent(keyboardEventSource: eventSource, virtualKey: 56, keyDown: false)
            shiftUp?.post(tap: .cghidEventTap)
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
