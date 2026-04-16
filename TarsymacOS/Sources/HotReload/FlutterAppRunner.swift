import Foundation
import TarsyShared

/// Runs a Flutter project on the iOS Simulator via `flutter run`.
/// Flutter's CLI keeps a Dart VM daemon alive for the lifetime of the
/// process and handles its own hot reload (`r`) / hot restart (`R`) over
/// stdin, so this runner is essentially process management + log
/// streaming. Tarsy doesn't manage reloads on its side — saving a `.dart`
/// file does NOT automatically push a reload through this runner; that's
/// up to the user (or a future "tap to hot-reload" iOS button that writes
/// `r\n` to our stdin).
///
/// Lifecycle: spawn `flutter run -d <udid>` → parse output → emit
/// buildComplete when "Flutter run key commands" prints → stay alive
/// until `stop()` writes `q\n` for a clean shutdown (or SIGKILL after 3s).
actor FlutterAppRunner {

    private let sendPacket: @Sendable (WSPacket, String) async -> Void
    private let logMessage: @Sendable (String) -> Void

    private var process: Process?
    private var inputPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var clientId: String?
    private var didSignalComplete = false

    init(
        sendPacket: @escaping @Sendable (WSPacket, String) async -> Void,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.sendPacket = sendPacket
        self.logMessage = log
    }

    func run(
        clientId: String,
        packetId: String,
        workspacePath: String,
        simulatorUDID: String
    ) async {
        log("Flutter run: path=\(workspacePath), sim=\(simulatorUDID)")

        await stop()

        let resolvedUDID = await resolveSimulator(requested: simulatorUDID, clientId: clientId, packetId: packetId)
        guard let resolvedUDID else { return }

        await sendProgress(clientId: clientId, output: "Starting Flutter run on \(resolvedUDID)...", phase: "preparing", percent: 5)

        self.clientId = clientId
        self.didSignalComplete = false

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // -i to load .zshrc (flutter is typically installed via fvm or
        // straight on PATH via brew, both touch .zshrc).
        proc.arguments = [
            "-i", "-c",
            "flutter run -d \(shellEscape(resolvedUDID))"
        ]
        proc.currentDirectoryURL = URL(fileURLWithPath: workspacePath)
        proc.environment = enrichedEnvironment()

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        self.process = proc
        self.inputPipe = inPipe
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe

        attachReader(pipe: outPipe, source: "stdout", clientId: clientId, packetId: packetId)
        attachReader(pipe: errPipe, source: "stderr", clientId: clientId, packetId: packetId)

        do {
            try proc.run()
        } catch {
            await sendError(clientId: clientId, packetId: packetId, message: "Failed to launch `flutter run`: \(error.localizedDescription). Is `flutter` on PATH?")
            return
        }

        proc.terminationHandler = { [weak self] term in
            Task { await self?.handleTermination(packetId: packetId, exitCode: term.terminationStatus) }
        }
    }

    func stop() async {
        guard let proc = self.process, proc.isRunning else {
            self.process = nil
            return
        }
        // Write `q\n` first — Flutter's run command treats it as a clean
        // exit and tears down the simulator daemon properly. SIGTERM works
        // too, but `q` lets it finish in-flight observatory shutdown.
        if let inPipe = self.inputPipe {
            let q = "q\n".data(using: .utf8)!
            try? inPipe.fileHandleForWriting.write(contentsOf: q)
        }

        for _ in 0..<30 {
            if !proc.isRunning { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if proc.isRunning {
            log("Flutter process didn't exit on `q`, sending SIGTERM")
            proc.terminate()
            for _ in 0..<10 {
                if !proc.isRunning { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if proc.isRunning {
                log("Flutter still alive, sending SIGKILL")
                kill(proc.processIdentifier, SIGKILL)
            }
        }
        self.process = nil
        self.inputPipe = nil
        self.stdoutPipe = nil
        self.stderrPipe = nil
    }

    // MARK: - Output parsing

    private func attachReader(pipe: Pipe, source: String, clientId: String, packetId: String) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            Task { [weak self] in
                await self?.processOutputChunk(text, clientId: clientId)
            }
        }
    }

    private func processOutputChunk(_ chunk: String, clientId: String) async {
        for raw in chunk.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let (phase, percent) = classifyFlutterLine(line)
            await sendProgress(clientId: clientId, output: line, phase: phase, percent: percent)

            if !didSignalComplete && isFlutterReadyMarker(line) {
                didSignalComplete = true
                await sendPacket(
                    WSPacket(action: .buildComplete, payload: ["appBundleId": "", "simulatorUDID": ""]),
                    clientId
                )
            }
        }
    }

    private func classifyFlutterLine(_ line: String) -> (phase: String, percent: Int) {
        let lower = line.lowercased()
        if lower.contains("launching lib/") || lower.contains("launching ") && lower.contains(".dart") {
            return ("preparing", 10)
        }
        if lower.contains("running pod install") || lower.contains("pod install") {
            return ("preparing", 15)
        }
        if lower.contains("running xcode build") || lower.contains("compiling") || lower.contains("compileswift") {
            return ("compiling", 50)
        }
        if lower.contains("xcode build done") {
            return ("installing", 85)
        }
        if lower.contains("installing and launching") || lower.contains("syncing files") {
            return ("installing", 90)
        }
        if isFlutterReadyMarker(line) {
            return ("complete", 100)
        }
        return ("preparing", 5)
    }

    private func isFlutterReadyMarker(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("flutter run key commands")
            || lower.contains("a dart vm service")
            || lower.contains("an observatory debugger")
    }

    private func handleTermination(packetId: String, exitCode: Int32) async {
        let clientId = self.clientId ?? ""
        if !didSignalComplete {
            let msg = exitCode == 0
                ? "flutter run exited before the app was ready (exit \(exitCode))."
                : "flutter run failed with exit code \(exitCode). Check the log above for details."
            await sendError(clientId: clientId, packetId: packetId, message: msg)
        }
        self.process = nil
    }

    // MARK: - Helpers

    private func resolveSimulator(requested: String, clientId: String, packetId: String) async -> String? {
        if !requested.isEmpty { return requested }
        if let booted = await SimulatorController.bootedDeviceUDID() { return booted }
        let devices = await SimulatorController.listDevices()
        guard let first = devices.first else {
            await sendError(clientId: clientId, packetId: packetId, message: "No iOS Simulator available")
            return nil
        }
        do {
            try await SimulatorController.boot(udid: first.udid)
            return first.udid
        } catch {
            await sendError(clientId: clientId, packetId: packetId, message: "Failed to boot simulator: \(error.localizedDescription)")
            return nil
        }
    }

    private func enrichedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
            .replacingOccurrences(of: "/Library/Containers/com.tarsy.macos/Data", with: "")
        let home = realHome.isEmpty ? (env["HOME"] ?? NSHomeDirectory()) : realHome
        env["HOME"] = home

        // Common Flutter install locations + dart/pub bins so `flutter` is
        // resolvable even before .zshrc executes.
        let extras = [
            "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/development/flutter/bin",
            "\(home)/flutter/bin",
            "\(home)/fvm/default/bin",
            "\(home)/.pub-cache/bin",
        ]
        let existing = extras.filter { FileManager.default.fileExists(atPath: $0) }
        let prefix = existing.joined(separator: ":")
        env["PATH"] = "\(prefix):\(env["PATH"] ?? "/usr/bin:/bin")"
        return env
    }

    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func sendProgress(clientId: String, output: String, phase: String, percent: Int) async {
        await sendPacket(
            WSPacket(action: .buildProgress, payload: ["output": output, "phase": phase, "percent": "\(percent)"]),
            clientId
        )
    }

    private func sendError(clientId: String, packetId: String, message: String) async {
        log("Error: \(message)")
        await sendPacket(
            WSPacket(action: .buildError, payload: ["message": message], id: packetId),
            clientId
        )
    }

    private func log(_ message: String) {
        logMessage("[FlutterRunner] \(message)")
    }
}
