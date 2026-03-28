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
    private var simulatorWindowWidth: CGFloat = 0
    private var simulatorWindowHeight: CGFloat = 0

    private let simulatorCropHeight: CGFloat = 52 // Must match ScreenCaptureService

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
            self.simulatorWindowWidth = frame.width
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

    func pinchStart(relativeX: CGFloat, relativeY: CGFloat) {}
    func pinchUpdate(scale: CGFloat) {}
    func pinchEnd() {}

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
            rotateSimulator(direction: "left")
        case "rotate_right":
            rotateSimulator(direction: "right")
        case "screenshot":
            break
        default:
            print("[RemoteInput] Unknown button: \(button)")
        }
    }

    private func rotateSimulator(direction: String) {
        idbQueue.async {
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
                    print("[RemoteInput] Rotate failed: \(errStr)")
                }
            } catch {
                print("[RemoteInput] Rotate error: \(error)")
            }
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
            if text == "\u{8}" {
                idbKeyPress(keycode: 42) // HID backspace
            } else if text == "\n" {
                idbKeyPress(keycode: 40) // HID return
            } else {
                idbTypeText(text)
            }
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
    private func streamToDeviceCoords(relativeX: CGFloat, relativeY: CGFloat) -> (x: Int, y: Int) {
        let rx = max(0, min(1, relativeX))
        let ry = max(0, min(1, relativeY))

        let imageWidth = simulatorWindowWidth
        let imageHeight = simulatorWindowHeight - simulatorCropHeight

        guard imageWidth > 0, imageHeight > 0 else {
            return (Int(rx * simulatorScreenWidth), Int(ry * simulatorScreenHeight))
        }

        let screenW = simulatorScreenWidth
        let screenH = simulatorScreenHeight

        let screenLeft: CGFloat
        let screenTop: CGFloat
        let zoom: CGFloat

        if imageWidth >= screenW {
            let bezelH = (imageWidth - screenW) / 2
            let totalVBezel = imageHeight - screenH
            let bezelTop_ = totalVBezel * 0.57
            screenLeft = bezelH
            screenTop = bezelTop_
            zoom = 1.0
        } else {
            let artWidth = screenW * 1.04
            let artHeight = screenH * 1.066

            let artZoom = min(imageWidth / artWidth, imageHeight / artHeight)

            let artRenderW = artWidth * artZoom
            let artRenderH = artHeight * artZoom
            let artOffsetX = (imageWidth - artRenderW) / 2
            let artOffsetY = (imageHeight - artRenderH) / 2

            let bezelH_1x = screenW * 0.02
            let bezelTop_1x = screenH * 0.05

            screenLeft = artOffsetX + bezelH_1x * artZoom
            screenTop = artOffsetY + bezelTop_1x * artZoom
            zoom = artZoom
        }

        let deviceX = (rx * imageWidth - screenLeft) / zoom
        let deviceY = (ry * imageHeight - screenTop) / zoom

        return (
            max(0, min(Int(screenW) - 1, Int(deviceX))),
            max(0, min(Int(screenH) - 1, Int(deviceY)))
        )
    }

    private func idbTap(relativeX: CGFloat, relativeY: CGFloat, duration: Double = 0.0) {
        let coords = streamToDeviceCoords(relativeX: relativeX, relativeY: relativeY)
        let x = coords.x
        let y = coords.y
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

    private func idbKeyPress(keycode: Int) {
        var args = ["ui", "key", "\(keycode)"]
        if let udid = simulatorUDID {
            args.append(contentsOf: ["--udid", udid])
        }
        runIdb(args)
    }

    private let idbQueue = DispatchQueue(label: "com.tarsy.idb", qos: .userInteractive)

    private var idbPath: String?

    /// Remove stale idb lockfile that prevents commands from running.
    /// idb uses /tmp/idb/state.lock with O_CREAT|O_EXCL — if a previous
    /// process crashed without cleaning up, the lock stays forever.
    private func cleanStaleLockfile() {
        let lockPath = "/tmp/idb/state.lock"
        if FileManager.default.fileExists(atPath: lockPath) {
            try? FileManager.default.removeItem(atPath: lockPath)
        }
    }

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

            // Shell-escape each argument with single quotes (prevents all injection)
            let escaped = argsCopy.map { a in
                "'" + a.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }.joined(separator: " ")
            let fullCommand = "rm -f /tmp/idb/state.lock && \(idb) \(escaped)"

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", fullCommand]

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
                    print("[RemoteInput] idb FAIL (\(process.terminationStatus)): \(escaped) — \(errStr.prefix(300))")
                }
            } catch {
                print("[RemoteInput] idb ERROR: \(error) — cmd: \(escaped)")
            }
        }
    }

    private func detectSimulatorInfo() {
        // Run on a separate queue so it doesn't block idbQueue
        // (idb connect takes ~1.2s and would delay input commands)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // Get booted simulator UDID and screen size via simctl (no idb needed)
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
                                fetchScreenDimensions(udid: udid)

                                // Connect idb in background via login shell
                                idbQueue.async { [self] in
                                    let idb = findIdb()
                                    let connect = Process()
                                    connect.executableURL = URL(fileURLWithPath: "/bin/zsh")
                                    connect.arguments = ["-l", "-c", "rm -f /tmp/idb/state.lock && \(idb) connect \(udid)"]
                                    connect.standardOutput = Pipe()
                                    connect.standardError = Pipe()
                                    try? connect.run()
                                    connect.waitUntilExit()
                                }
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

    /// Get screen dimensions via simctl (no idb dependency, no lockfile)
    private func fetchScreenDimensions(udid: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "-j"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()

            // Get device type from simctl, then look up screen size
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let devices = json["devices"] as? [String: [[String: Any]]] {
                for (_, deviceList) in devices {
                    for device in deviceList {
                        if device["udid"] as? String == udid,
                           let deviceType = device["deviceTypeIdentifier"] as? String {
                            // Extract screen size from device type name
                            let screenSize = screenSizeForDeviceType(deviceType)
                            simulatorScreenWidth = screenSize.width
                            simulatorScreenHeight = screenSize.height
                            print("[RemoteInput] Simulator screen: \(screenSize.width)x\(screenSize.height) points (from \(deviceType))")
                            return
                        }
                    }
                }
            }
        } catch {
            print("[RemoteInput] Failed to get screen dimensions: \(error)")
        }
    }

    private func screenSizeForDeviceType(_ deviceType: String) -> CGSize {
        // Common iPhone device types → screen sizes in points
        let lowered = deviceType.lowercased()
        if lowered.contains("iphone-16-pro-max") || lowered.contains("iphone-15-pro-max") {
            return CGSize(width: 430, height: 932)
        } else if lowered.contains("iphone-16-pro") || lowered.contains("iphone-15-pro") {
            return CGSize(width: 402, height: 874)
        } else if lowered.contains("iphone-16-plus") || lowered.contains("iphone-15-plus")
                    || lowered.contains("iphone-16e") {
            return CGSize(width: 430, height: 932)
        } else if lowered.contains("iphone-16") || lowered.contains("iphone-15") {
            return CGSize(width: 393, height: 852)
        } else if lowered.contains("iphone-14-pro-max") {
            return CGSize(width: 430, height: 932)
        } else if lowered.contains("iphone-14-pro") {
            return CGSize(width: 393, height: 852)
        } else if lowered.contains("iphone-se") {
            return CGSize(width: 375, height: 667)
        }
        // Default: iPhone 16 Pro
        return CGSize(width: 402, height: 874)
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
