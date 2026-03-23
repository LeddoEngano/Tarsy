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

    // Browser/desktop state
    private var windowFocused = false
    private let titleBarHeight: CGFloat = 28

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

            // Convert relative coords to simulator screen points
            let startX = Int(start.x * simulatorScreenWidth)
            let startY = Int(start.y * simulatorScreenHeight)
            let endX = Int(end.x * simulatorScreenWidth)
            let endY = Int(end.y * simulatorScreenHeight)

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

    private func idbTap(relativeX: CGFloat, relativeY: CGFloat, duration: Double = 0.0) {
        let x = Int(relativeX * simulatorScreenWidth)
        let y = Int(relativeY * simulatorScreenHeight)
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

    private func runIdb(_ args: [String]) {
        inputQueue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/Library/Frameworks/Python.framework/Versions/3.13/bin/idb")
            process.arguments = args
            process.standardOutput = Pipe()
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                print("[RemoteInput] idb error: \(error)")
            }
        }
    }

    private func detectSimulatorInfo() {
        inputQueue.async { [self] in
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
                    print("[RemoteInput] Simulator screen: \(w)x\(h) points")
                }
            }
        } catch {
            print("[RemoteInput] Failed to get screen dimensions: \(error)")
        }
    }

    // MARK: - Browser/Desktop Helpers

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
