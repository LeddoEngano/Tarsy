import Foundation
import CoreGraphics
import AppKit

class RemoteInputService {
    private var windowId: CGWindowID = 0
    private var ownerPid: pid_t = 0
    private var isMobileSimulator = false

    // Simulator device info (from idb)
    private var simulatorUDID: String?
    private var simulatorScreenWidth: CGFloat = 402  // iPhone 16 Pro default
    private var simulatorScreenHeight: CGFloat = 874
    private var simulatorWindowHeight: CGFloat = 0

    // Browser/desktop state
    private var windowFocused = false

    // Stateful drag for browser
    private var isDragging = false
    private var currentDragPoint: CGPoint = .zero

    private let inputQueue = DispatchQueue(label: "com.tarsy.remoteInput", qos: .userInteractive)
    private let eventSource = CGEventSource(stateID: .privateState)

    func setTargetWindow(frame: CGRect, windowId: CGWindowID, pid: pid_t, isSimulator: Bool, appName: String = "") {
        self.windowId = windowId
        self.ownerPid = pid
        self.isMobileSimulator = isSimulator
        self.windowFocused = false

        if isSimulator {
            self.simulatorWindowHeight = frame.height
            detectSimulatorInfo()
        }

        print("[RemoteInput] Target set: wid=\(windowId), pid=\(pid), sim=\(isSimulator)")
    }

    // MARK: - Tap

    func tap(relativeX: CGFloat, relativeY: CGFloat) {
        if isMobileSimulator {
            idbTap(relativeX: relativeX, relativeY: relativeY)
        } else {
            inputQueue.async { [self] in
                guard let point = browserAbsolutePoint(relativeX: relativeX, relativeY: relativeY) else { return }
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
    }

    // MARK: - Double Tap

    func doubleTap(relativeX: CGFloat, relativeY: CGFloat) {
        if isMobileSimulator {
            // idb: two quick taps
            idbTap(relativeX: relativeX, relativeY: relativeY)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
                idbTap(relativeX: relativeX, relativeY: relativeY)
            }
        } else {
            inputQueue.async { [self] in
                guard let point = browserAbsolutePoint(relativeX: relativeX, relativeY: relativeY) else { return }
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
    }

    // MARK: - Long Press

    func longPress(relativeX: CGFloat, relativeY: CGFloat) {
        if isMobileSimulator {
            idbTap(relativeX: relativeX, relativeY: relativeY, duration: 1.0)
        } else {
            inputQueue.async { [self] in
                guard let point = browserAbsolutePoint(relativeX: relativeX, relativeY: relativeY) else { return }
                ensureWindowFocused()
                let down = CGEvent(mouseEventSource: eventSource, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right)
                down?.post(tap: .cghidEventTap)
                usleep(30_000)
                let up = CGEvent(mouseEventSource: eventSource, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right)
                up?.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - Scroll/Swipe Start

    func scrollStart(relativeX: CGFloat, relativeY: CGFloat) {
        if !isMobileSimulator {
            // Browser: no-op for start, we handle per-scroll
        }
        // Simulator: we accumulate and send swipe on scrollEnd
    }

    // Track accumulated swipe for simulator
    private var swipeStartRel: CGPoint?
    private var swipeCurrentRel: CGPoint?

    func scroll(relativeX: CGFloat, relativeY: CGFloat, deltaX: CGFloat, deltaY: CGFloat) {
        if isMobileSimulator {
            // Accumulate swipe deltas — will send as one idb swipe on scrollEnd
            if swipeStartRel == nil {
                swipeStartRel = CGPoint(x: relativeX, y: relativeY)
                swipeCurrentRel = CGPoint(x: relativeX, y: relativeY)
            }
            // Accumulate delta (in iOS points relative to screen)
            let dxPoints = deltaX / simulatorScreenWidth
            let dyPoints = deltaY / simulatorScreenHeight
            swipeCurrentRel?.x += dxPoints
            swipeCurrentRel?.y += dyPoints
        } else {
            // Browser: scroll wheel per event
            inputQueue.async { [self] in
                guard let point = browserAbsolutePoint(relativeX: relativeX, relativeY: relativeY) else { return }
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
            guard let start = swipeStartRel, let end = swipeCurrentRel else {
                swipeStartRel = nil
                swipeCurrentRel = nil
                return
            }

            // Convert stream-relative coords to device screen points
            let startCoords = streamToDeviceCoords(relativeX: start.x, relativeY: start.y)
            let endCoords = streamToDeviceCoords(relativeX: end.x, relativeY: end.y)
            let startX = startCoords.x
            let startY = startCoords.y
            let endX = endCoords.x
            let endY = endCoords.y

            // Only send if there's meaningful movement
            let dist = sqrt(pow(Double(endX - startX), 2) + pow(Double(endY - startY), 2))
            if dist > 5 {
                idbSwipe(fromX: startX, fromY: startY, toX: endX, toY: endY, duration: 0.3)
            }

            swipeStartRel = nil
            swipeCurrentRel = nil
        }
    }

    // MARK: - Pinch (Simulator only — browser uses Cmd+/-)

    func pinchStart(relativeX: CGFloat, relativeY: CGFloat) {
        // idb doesn't have native pinch — we'd need FBSimulatorControl for that
        // For now, use keyboard shortcut in browser or skip for simulator
    }

    func pinchUpdate(scale: CGFloat) {
        // Not supported via idb
    }

    func pinchEnd() {
        // Not supported via idb
    }

    // MARK: - Drag

    func drag(fromX: CGFloat, fromY: CGFloat, toX: CGFloat, toY: CGFloat) {
        if isMobileSimulator {
            let sx = Int(fromX * simulatorScreenWidth)
            let sy = Int(fromY * simulatorScreenHeight)
            let ex = Int(toX * simulatorScreenWidth)
            let ey = Int(toY * simulatorScreenHeight)
            idbSwipe(fromX: sx, fromY: sy, toX: ex, toY: ey, duration: 0.5)
        } else {
            inputQueue.async { [self] in
                guard let from = browserAbsolutePoint(relativeX: fromX, relativeY: fromY),
                      let to = browserAbsolutePoint(relativeX: toX, relativeY: toY) else { return }
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
    }

    // MARK: - Device Buttons

    func pressButton(_ button: String) {
        guard isMobileSimulator else { return }

        switch button {
        case "home":
            runIdb(["ui", "button", "HOME"])
        case "lock":
            runIdb(["ui", "button", "LOCK"])
        case "siri":
            runIdb(["ui", "button", "SIRI"])
        case "rotate_left":
            // Send Cmd+Left to Simulator app
            sendSimulatorShortcut(keyCode: 0x7B, modifiers: .maskCommand) // Left arrow
        case "rotate_right":
            // Send Cmd+Right to Simulator app
            sendSimulatorShortcut(keyCode: 0x7C, modifiers: .maskCommand) // Right arrow
        case "screenshot":
            takeSimulatorScreenshot()
        default:
            print("[RemoteInput] Unknown button: \(button)")
        }
    }

    private func sendSimulatorShortcut(keyCode: CGKeyCode, modifiers: CGEventFlags) {
        inputQueue.async { [self] in
            // Focus Simulator first
            if let app = NSRunningApplication(processIdentifier: ownerPid) {
                app.activate()
            }
            usleep(100_000)

            let down = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: true)
            down?.flags = modifiers
            down?.post(tap: .cghidEventTap)
            usleep(30_000)
            let up = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: false)
            up?.flags = modifiers
            up?.post(tap: .cghidEventTap)
        }
    }

    private func takeSimulatorScreenshot() {
        idbQueue.async { [self] in
            guard let udid = simulatorUDID else { return }
            let path = NSHomeDirectory() + "/Desktop/simulator_screenshot_\(Int(Date().timeIntervalSince1970)).png"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl", "io", udid, "screenshot", path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
            print("[RemoteInput] Screenshot saved: \(path)")
        }
    }

    // MARK: - Keyboard

    func typeText(_ text: String) {
        if isMobileSimulator {
            idbTypeText(text)
        } else {
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
    }

    // MARK: - idb Commands (Simulator)

    /// Convert stream-relative coords (0-1) to device screen coords (points) for idb.
    /// The stream captures the full Simulator window which includes a ~28pt title bar.
    /// We need to subtract the title bar portion from Y before mapping to device coords.
    private func streamToDeviceCoords(relativeX: CGFloat, relativeY: CGFloat) -> (x: Int, y: Int) {
        let rx = max(0, min(1, relativeX))

        // Get current window height to calculate title bar ratio
        let titleBarRatio: CGFloat
        if let frame = getCurrentWindowFrame(), frame.height > 0 {
            // Title bar is ~28pt on macOS
            titleBarRatio = 28.0 / frame.height
        } else {
            titleBarRatio = 0.0375 // fallback: 28/746
        }

        // Adjust Y: remove title bar portion, remap to device screen
        let adjustedY = max(0, min(1, (relativeY - titleBarRatio) / (1.0 - titleBarRatio)))

        let x = Int(rx * simulatorScreenWidth)
        let y = Int(adjustedY * simulatorScreenHeight)
        return (x, y)
    }

    private func idbTap(relativeX: CGFloat, relativeY: CGFloat, duration: Double = 0.0) {
        let coords = streamToDeviceCoords(relativeX: relativeX, relativeY: relativeY)
        let x = coords.x
        let y = coords.y
        print("[RemoteInput] idbTap: rel(\(String(format: "%.3f", relativeX)),\(String(format: "%.3f", relativeY))) → device(\(x),\(y))")
        var args = ["ui", "tap", "\(x)", "\(y)"]
        if let udid = simulatorUDID {
            args.append(contentsOf: ["--udid", udid])
        }
        if duration > 0 {
            args.append(contentsOf: ["--duration", String(format: "%.1f", duration)])
        }
        runIdb(args)
    }

    private func idbSwipe(fromX: Int, fromY: Int, toX: Int, toY: Int, duration: Double = 0.3) {
        var args = ["ui", "swipe", "\(fromX)", "\(fromY)", "\(toX)", "\(toY)"]
        if let udid = simulatorUDID {
            args.append(contentsOf: ["--udid", udid])
        }
        args.append(contentsOf: ["--duration", String(format: "%.1f", duration)])
        runIdb(args)
    }

    private func idbTypeText(_ text: String) {
        var args = ["ui", "text", text]
        if let udid = simulatorUDID {
            args.append(contentsOf: ["--udid", udid])
        }
        runIdb(args)
    }

    private let idbQueue = DispatchQueue(label: "com.tarsy.idb", qos: .userInteractive)

    private var idbPath: String?

    private func findIdb() -> String {
        if let cached = idbPath { return cached }
        let candidates = [
            "/Library/Frameworks/Python.framework/Versions/3.13/bin/idb",
            "/opt/homebrew/bin/idb",
            "/usr/local/bin/idb",
            NSHomeDirectory() + "/.local/bin/idb",
            NSHomeDirectory() + "/Library/Python/3.13/bin/idb",
            NSHomeDirectory() + "/Library/Python/3.12/bin/idb",
            NSHomeDirectory() + "/Library/Python/3.11/bin/idb"
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                idbPath = path
                print("[RemoteInput] Found idb at: \(path)")
                return path
            }
        }
        idbPath = "/Library/Frameworks/Python.framework/Versions/3.13/bin/idb"
        return idbPath!
    }

    private func runIdb(_ args: [String]) {
        let argsCopy = args
        idbQueue.async { [self] in
            let idb = findIdb()

            // Run via /bin/sh to ensure proper env setup
            let fullCommand = "\(idb) \(argsCopy.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " "))"

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", fullCommand]
            process.environment = ProcessInfo.processInfo.environment

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errStr = String(data: errData, encoding: .utf8) ?? ""
                    print("[RemoteInput] idb FAIL (\(process.terminationStatus)): \(fullCommand) — \(errStr.prefix(300))")
                }
            } catch {
                print("[RemoteInput] idb ERROR: \(error) — cmd: \(fullCommand)")
            }
        }
    }

    private func detectSimulatorInfo() {
        idbQueue.async { [self] in
            // Get booted simulator UDID
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
                                print("[RemoteInput] Simulator UDID: \(udid)")

                                // Connect idb
                                let connect = Process()
                                connect.executableURL = URL(fileURLWithPath: "/Library/Frameworks/Python.framework/Versions/3.13/bin/idb")
                                connect.arguments = ["connect", udid]
                                connect.standardOutput = Pipe()
                                connect.standardError = Pipe()
                                try? connect.run()
                                connect.waitUntilExit()

                                // Get screen dimensions
                                fetchScreenDimensions(udid: udid)
                                return
                            }
                        }
                    }
                }
            } catch {
                print("[RemoteInput] Failed to detect simulator: \(error)")
            }
        }
    }

    private func fetchScreenDimensions(udid: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/Library/Frameworks/Python.framework/Versions/3.13/bin/idb")
        process.arguments = ["describe", "--udid", udid]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            // Parse "width_points=402, height_points=874" from output
            if let widthMatch = output.range(of: #"width_points=(\d+)"#, options: .regularExpression),
               let heightMatch = output.range(of: #"height_points=(\d+)"#, options: .regularExpression) {
                let widthStr = String(output[widthMatch]).components(separatedBy: "=").last ?? ""
                let heightStr = String(output[heightMatch]).components(separatedBy: "=").last ?? ""
                if let w = CGFloat(exactly: Int(widthStr) ?? 402),
                   let h = CGFloat(exactly: Int(heightStr) ?? 874) {
                    simulatorScreenWidth = w
                    simulatorScreenHeight = h

                    // Calculate title bar ratio
                    // The stream captures the full window. The title bar takes
                    // some portion at the top. We need to know what fraction
                    // of the window height is title bar vs device screen.
                    print("[RemoteInput] Simulator screen: \(w)x\(h) points")
                }
            }
        } catch {
            print("[RemoteInput] Failed to get screen dimensions: \(error)")
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

    // MARK: - Browser/Desktop Helpers

    private func browserAbsolutePoint(relativeX: CGFloat, relativeY: CGFloat) -> CGPoint? {
        guard let frame = getCurrentWindowFrame() else { return nil }
        return CGPoint(
            x: frame.origin.x + frame.width * relativeX,
            y: frame.origin.y + frame.height * relativeY
        )
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
