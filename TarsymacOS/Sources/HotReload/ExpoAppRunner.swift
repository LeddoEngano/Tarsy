import Foundation
import TarsyShared

/// Runs an Expo / React Native project on the iOS Simulator via a single
/// `npx expo run:ios` invocation. The CLI handles the full pipeline —
/// pod install, xcodebuild, simulator install, launch, Metro startup,
/// and (crucially) writing the Metro packager host into the installed
/// app so `RCTBundleURLProvider` can resolve the JS bundle URL at
/// runtime. Tarsy's only job is process supervision + log streaming.
///
/// The tricky bit is preventing Expo from spawning Metro in a separate
/// Terminal.app window via AppleScript. By default, `@expo/cli` detects
/// an interactive parent shell and opens a new Terminal for Metro so the
/// user can see packager logs. Under Tarsy's sandboxed/detached spawn
/// that AppleScript path silently no-ops — we get a built+installed app
/// but no Metro, hence the infamous
///   "No script URL provided. unsanitizedScriptURLString = (null)"
/// error. Setting `CI=1` switches Expo into non-interactive mode: Metro
/// runs inline in the same process tree, no new Terminal window, and
/// the `run:ios` command keeps the child Metro alive until the parent
/// process exits.
///
/// An earlier iteration of this runner used a two-phase design —
/// spawn `expo start` separately, then `expo run:ios --no-bundler` —
/// which seemed cleaner but missed the fact that `--no-bundler` skips
/// the packager-host-handshake step. That's why that iteration
/// reproduced the null-URL error: xcodebuild succeeded, app launched,
/// app had no idea where Metro was listening.
///
/// Lifecycle: spawn `expo run:ios` → parse output → emit buildComplete
/// when "Opening on iOS" prints → keep process alive until `stop()`
/// sends SIGTERM to the process group (which tears down Metro too).
actor ExpoAppRunner {

    private let sendPacket: @Sendable (WSPacket, String) async -> Void
    private let logMessage: @Sendable (String) -> Void

    private var process: Process?
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
        log("Expo run: path=\(workspacePath), sim=\(simulatorUDID)")

        await stop()

        self.clientId = clientId
        self.didSignalComplete = false

        // Surface the cwd up-front so the user can verify the runner
        // landed in the right directory — a sub-path misconfiguration
        // is a common source of "bundle not found" errors in Expo
        // monorepos and without this line it's invisible.
        await sendProgress(clientId: clientId, output: "Working directory: \(workspacePath)", phase: "preparing", percent: 2)

        // Validate the cwd actually looks like an Expo/RN project before
        // burning time on xcodebuild.
        if let validationError = validateExpoWorkspace(at: workspacePath) {
            await sendError(clientId: clientId, packetId: packetId, message: validationError)
            return
        }

        let resolvedUDID = await resolveSimulator(requested: simulatorUDID, clientId: clientId, packetId: packetId)
        guard let resolvedUDID else { return }

        await sendProgress(clientId: clientId, output: "Starting Expo build + Metro (inline, CI=1)...", phase: "preparing", percent: 5)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // `expo run:ios` with a resolved `--device` UDID does the full
        // flow AND starts Metro inline (because CI=1 is in the env).
        // We deliberately do NOT pass `--no-bundler` — that flag skips
        // the packager-host handshake that tells the installed app
        // where to find Metro, which is exactly what breaks
        // `RCTBundleURLProvider` at runtime.
        //
        // -i loads .zshrc for nvm/fnm/asdf PATH so npx resolves.
        proc.arguments = [
            "-i", "-c",
            "npx expo run:ios --device \(shellEscape(resolvedUDID))"
        ]
        proc.currentDirectoryURL = URL(fileURLWithPath: workspacePath)
        proc.environment = enrichedEnvironment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        // Null stdin — Expo's interactive prompts (install deps, pick
        // device) don't have a UI on our end. With CI=1 there shouldn't
        // be any prompts anyway, but nullDevice is belt-and-suspenders.
        proc.standardInput = FileHandle.nullDevice

        self.process = proc

        attachReader(pipe: outPipe, clientId: clientId)
        attachReader(pipe: errPipe, clientId: clientId)

        do {
            try proc.run()
        } catch {
            await sendError(clientId: clientId, packetId: packetId, message: "Failed to launch `npx expo run:ios`: \(error.localizedDescription). Is `npx` on PATH?")
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
        // SIGTERM tears down the whole process group cleanly — Metro is
        // a child of `expo run:ios`, and zsh is the parent of both, so
        // signaling the zsh pid propagates and everything exits.
        proc.terminate()
        for _ in 0..<30 {
            if !proc.isRunning { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if proc.isRunning {
            log("Process didn't exit on SIGTERM, sending SIGKILL")
            kill(proc.processIdentifier, SIGKILL)
        }
        self.process = nil
    }

    // MARK: - Output parsing

    private func attachReader(pipe: Pipe, clientId: String) {
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

            let (phase, percent) = classifyLine(line)
            await sendProgress(clientId: clientId, output: line, phase: phase, percent: percent)

            if !didSignalComplete && isReadyMarker(line) {
                didSignalComplete = true
                await sendPacket(
                    WSPacket(action: .buildComplete, payload: ["appBundleId": "", "simulatorUDID": ""]),
                    clientId
                )
            }
        }
    }

    /// Heuristic phase/percent mapping based on substrings Expo prints
    /// during `run:ios`. Markers are stable across @expo/cli releases
    /// going back several SDK versions; new markers can be appended
    /// without breaking older ones.
    private func classifyLine(_ line: String) -> (phase: String, percent: Int) {
        let lower = line.lowercased()
        if lower.contains("pod install") || lower.contains("installing pods") || lower.contains("cocoapods") {
            return ("preparing", 15)
        }
        if lower.contains("starting metro") || lower.contains("metro waiting") {
            return ("starting metro", 20)
        }
        if lower.contains("compiling") || lower.contains("compileswift") || lower.contains("swiftcompile") {
            return ("compiling", 50)
        }
        if lower.contains("ld ") || lower.contains("linking") {
            return ("linking", 75)
        }
        if lower.contains("codesign") || lower.contains("signing") {
            return ("signing", 85)
        }
        if lower.contains("install") && (lower.contains(".app") || lower.contains("on simulator") || lower.contains("installing ")) {
            return ("installing", 92)
        }
        if lower.contains("launching") || lower.contains("opening on ios") {
            return ("launching", 97)
        }
        if isReadyMarker(line) {
            return ("complete", 100)
        }
        return ("compiling", 40)
    }

    private func isReadyMarker(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("opening on ios")
            || lower.contains("successfully launched")
            || lower.contains("logs for your project will appear below")
    }

    // MARK: - Termination

    private func handleTermination(packetId: String, exitCode: Int32) async {
        let clientId = self.clientId ?? ""
        // Process exiting before buildComplete = fatal. After
        // buildComplete, it means we or the user stopped it — clean
        // shutdown, no error.
        if !didSignalComplete {
            let msg = exitCode == 0
                ? "Expo run exited before the app was ready (exit \(exitCode)). Check the log above for the final error — common causes: pod install failed, xcodebuild error, or Metro port :8081 already in use."
                : "Expo run failed with exit code \(exitCode). Check the log above for details."
            await sendError(clientId: clientId, packetId: packetId, message: msg)
        }
        self.process = nil
    }

    // MARK: - Validation

    /// Fast structural check on the cwd. Returns nil if the directory
    /// looks like an Expo/RN project, or an error message explaining
    /// what's missing.
    private func validateExpoWorkspace(at path: String) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            return "Workspace path does not exist: \(path)"
        }
        let pkgPath = path + "/package.json"
        guard let data = fm.contents(atPath: pkgPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "No package.json at \(path). For monorepos, make sure your workspace's sub-path points at the app folder (e.g. `apps/mobile`), not the repo root."
        }
        let depSections: [String] = ["dependencies", "devDependencies", "peerDependencies"]
        var hasMobileRuntime = false
        for section in depSections {
            guard let deps = json[section] as? [String: Any] else { continue }
            if deps["expo"] != nil || deps["react-native"] != nil {
                hasMobileRuntime = true
                break
            }
        }
        if !hasMobileRuntime {
            return "package.json at \(path) doesn't reference `expo` or `react-native`. This doesn't look like an Expo/RN app — check the workspace sub-path."
        }
        return nil
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

        // CRITICAL. CI=1 is the canonical marker `@expo/cli` reads to
        // switch to non-interactive mode: Metro starts inline (in the
        // same process tree as run:ios) instead of via AppleScript
        // spawning a new Terminal.app window. Without this, Metro
        // effectively never starts in Tarsy's sandboxed spawn context
        // and the installed app can't find its JS bundle at runtime.
        env["CI"] = "1"
        env["EXPO_NO_TELEMETRY"] = "1"
        env["EXPO_NO_CAPABILITY_SYNC"] = "1"
        // Ensures `expo run:ios` uses dev-client mode when the project
        // has a bare workflow (has ios/ folder), matching what
        // xcodebuild produces.
        env["EXPO_USE_DEV_SERVER"] = "true"

        let extras = [
            "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/.bun/bin", "\(home)/.local/share/pnpm",
        ]
        let nvmBins = scanNodeManagerBins(home: home)
        let prefix = (extras + nvmBins).joined(separator: ":")
        env["PATH"] = "\(prefix):\(env["PATH"] ?? "/usr/bin:/bin")"
        return env
    }

    private func scanNodeManagerBins(home: String) -> [String] {
        let fm = FileManager.default
        let dirs = [
            "\(home)/.nvm/versions/node",
            "\(home)/.fnm/node-versions",
            "\(home)/.local/share/fnm/node-versions",
        ]
        var out: [String] = []
        for dir in dirs where fm.fileExists(atPath: dir) {
            guard let versions = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for v in versions {
                let bin = "\(dir)/\(v)/bin"
                if fm.fileExists(atPath: bin) { out.append(bin) }
            }
        }
        return out
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
        logMessage("[ExpoRunner] \(message)")
    }
}
