import Foundation
import TarsyShared
import AppKit

// MARK: - State Types

enum DevServerState: Sendable {
    case starting
    case ready(port: Int)
    case failed(error: String)
}

struct DevServerEntry {
    let workspacePath: String
    let sessionId: String
    let startedAt: Date
    var detectedPort: Int?
    var processGroupId: pid_t?
    var state: DevServerState
    var readyDetector: ReadySignalDetector = ReadySignalDetector()
    var conflictDetector: ConflictDetector = ConflictDetector()
}

struct PortStateDiff: Sendable {
    let workspacePath: String
    let previousPort: Int?
    let currentPort: Int?
    let isRunning: Bool
}

// MARK: - PortMonitorService

actor PortMonitorService {

    // MARK: - Dependencies

    private let terminalManager: TerminalSessionManager
    private let sendPacket: @Sendable (WSPacket, String) async -> Void
    private let logMessage: @Sendable (String) -> Void
    private let detectSudoPrompt: @Sendable (String, String) async -> Void
    private let rewriteSudoCommand: @Sendable (String, String) async -> String?

    // MARK: - State (all actor-isolated — fixes Bug #1)

    private var entries: [String: DevServerEntry] = [:]
    private var operationLocks: Set<String> = []
    private var watchTask: Task<Void, Never>?

    // MARK: - Configuration

    static let allowedRunners: Set<String> = [
        "npm", "pnpm", "yarn", "bun", "npx", "node", "deno",
        "python", "python3", "ruby", "cargo", "go", "make",
        "docker", "gradle", "gradlew", "mvn", "dotnet",
        "php", "artisan", "mix", "elixir", "flask", "uvicorn", "gunicorn",
    ]

    // MARK: - Init

    init(
        terminalManager: TerminalSessionManager,
        sendPacket: @escaping @Sendable (WSPacket, String) async -> Void,
        log: @escaping @Sendable (String) -> Void,
        detectSudoPrompt: @escaping @Sendable (String, String) async -> Void,
        rewriteSudoCommand: @escaping @Sendable (String, String) async -> String?
    ) {
        self.terminalManager = terminalManager
        self.sendPacket = sendPacket
        self.logMessage = log
        self.detectSudoPrompt = detectSudoPrompt
        self.rewriteSudoCommand = rewriteSudoCommand
    }

    // MARK: - Dev Server Start

    func startDevServer(
        clientId: String,
        packetId: String,
        workspacePath: String,
        command: String,
        streamUrl: String?
    ) async {
        // Bug #2: Per-workspace serialization — prevent concurrent starts
        guard acquireLock(for: workspacePath) else {
            if let existing = entries[workspacePath] {
                await sendPacket(
                    WSPacket(action: .devServerStart, payload: [
                        "status": "running",
                        "sessionId": existing.sessionId,
                    ], id: packetId),
                    clientId
                )
            }
            return
        }
        defer { releaseLock(for: workspacePath) }

        // Check existing entry — if running and port alive, return immediately
        if let existing = entries[workspacePath] {
            let alive = await terminalManager.isSessionAlive(existing.sessionId)
            let portUp = existing.detectedPort.map { PortScanner.isPortListening(port: UInt16($0)) } ?? false

            if alive && (portUp || existing.detectedPort == nil) {
                let targetPort = PortExtractor.portFromUrl(streamUrl).map { Int($0) }
                let portToReport = existing.detectedPort ?? targetPort
                var payload: [String: String] = ["status": "running", "sessionId": existing.sessionId]
                if let p = portToReport { payload["port"] = "\(p)" }
                await sendPacket(WSPacket(action: .devServerStart, payload: payload, id: packetId), clientId)
                return
            }

            // Stale entry — clean up old session (Bug #5: close PTY before restarting)
            await terminalManager.closeSession(existing.sessionId)
            entries.removeValue(forKey: workspacePath)
            log("devServerStart: cleaned stale entry for \(workspacePath)")
        }

        // Validate command against allowlist (Bug #10: expanded)
        let cmdName = command.components(separatedBy: " ").first ?? command
        let baseCmdName = (cmdName as NSString).lastPathComponent
        guard Self.allowedRunners.contains(baseCmdName) else {
            log("devServerStart: blocked disallowed command '\(baseCmdName)'")
            await sendPacket(
                WSPacket(action: .devServerStart, payload: ["status": "error", "error": "Command not allowed: \(baseCmdName)"], id: packetId),
                clientId
            )
            return
        }

        // Handle sudo rewriting
        guard let rewrittenCmd = await rewriteSudoCommand(command, workspacePath) else {
            log("devServerStart: sudo password cancelled")
            await sendPacket(
                WSPacket(action: .sudoResult, payload: ["status": "cancelled"], id: packetId),
                clientId
            )
            return
        }
        let needsSudo = (rewrittenCmd != command)

        // Create terminal session
        let sessionId: String
        do {
            sessionId = try await terminalManager.createSession(workingDirectory: workspacePath)
        } catch {
            await sendPacket(
                WSPacket(action: .error, payload: ["message": "Dev server failed: \(error.localizedDescription)"], id: packetId),
                clientId
            )
            return
        }

        // Initialize entry
        entries[workspacePath] = DevServerEntry(
            workspacePath: workspacePath,
            sessionId: sessionId,
            startedAt: Date(),
            detectedPort: nil,
            processGroupId: nil,
            state: .starting
        )

        // Monitor output — detectors stored in entry, mutated via actor isolation
        await terminalManager.setOutputHandler(for: sessionId) { [weak self] output in
            guard let self else { return }
            Task {
                await self.handleDevServerOutput(output, workspacePath: workspacePath, sessionId: sessionId)
            }
        }

        // Source shell config
        let nvmSetup = "export NVM_DIR=\"$HOME/.nvm\"; [ -s \"$NVM_DIR/nvm.sh\" ] && . \"$NVM_DIR/nvm.sh\""
        await terminalManager.sendInput(nvmSetup, to: sessionId)

        // Run command
        await terminalManager.sendInput(rewrittenCmd, to: sessionId)
        log("devServerStart: running '\(command)' in \(workspacePath)\(needsSudo ? " (with sudo)" : "")")

        // Wait for ready signal or port to open
        let targetPort = PortExtractor.portFromUrl(streamUrl)
        let timeout: Int = needsSudo ? 45 : 30
        let confirmed = await waitForReady(
            workspacePath: workspacePath,
            port: targetPort,
            timeout: timeout
        )

        if confirmed {
            // Bug #3: Poll stability instead of blind 2s sleep
            let stable = await verifyStability(sessionId: sessionId, workspacePath: workspacePath)

            if stable, let port = entries[workspacePath]?.detectedPort {
                updatePort(workspacePath: workspacePath, port: port)
                log("devServerStart: confirmed running on port \(port)")

                await sendPacket(
                    WSPacket(action: .devServerStart, payload: [
                        "status": "ready",
                        "port": "\(port)",
                        "sessionId": sessionId,
                    ], id: packetId),
                    clientId
                )

                if let url = streamUrl, !url.isEmpty {
                    await openBrowserToUrl(url)
                }
                return
            }

            // Process died — handle conflict or scan for existing server
            let conflictPID = entries[workspacePath]?.conflictDetector.conflictPID
            log("devServerStart: process died after startup (conflictPID=\(conflictPID?.description ?? "none"))")

            // Bug #5: Clean up the failed session's PTY before any retry
            await terminalManager.closeSession(sessionId)
            entries.removeValue(forKey: workspacePath)

            if let pid = conflictPID {
                log("devServerStart: killing conflicting process PID \(pid)")
                await ProcessGroupKiller.killProcess(pid: pid, gracePeriod: 1.0)
                log("devServerStart: retrying after killing conflicting process")
                await startDevServer(clientId: clientId, packetId: packetId, workspacePath: workspacePath, command: command, streamUrl: streamUrl)
                return
            }

            // No conflict — try to find an existing server via batched scan
            await handleFallbackPortScan(
                workspacePath: workspacePath,
                sessionId: sessionId,
                clientId: clientId,
                packetId: packetId,
                errorMessage: "Dev server exited unexpectedly"
            )
        } else {
            // Timeout — scan for server on common ports
            log("devServerStart: timeout, scanning common ports")

            if let tp = targetPort, PortScanner.isPortListening(port: tp) {
                updatePort(workspacePath: workspacePath, port: Int(tp))
                await sendPacket(
                    WSPacket(action: .devServerStart, payload: [
                        "status": "ready",
                        "port": "\(tp)",
                        "sessionId": sessionId,
                    ], id: packetId),
                    clientId
                )
            } else {
                await handleFallbackPortScan(
                    workspacePath: workspacePath,
                    sessionId: sessionId,
                    clientId: clientId,
                    packetId: packetId,
                    errorMessage: nil
                )
            }
        }
    }

    // MARK: - Dev Server Stop

    func stopDevServer(
        clientId: String,
        packetId: String,
        workspacePath: String
    ) async {
        var portFreed = true

        if let entry = entries[workspacePath] {
            // Send Ctrl+C first
            await terminalManager.sendInput("\u{03}", to: entry.sessionId)
            try? await Task.sleep(nanoseconds: 500_000_000)

            // Bug #8: Kill entire process group, not just the shell
            if let pgid = entry.processGroupId {
                await ProcessGroupKiller.killProcessGroup(pid: pgid, gracePeriod: 1.5)
            }

            await terminalManager.closeSession(entry.sessionId)

            // Bug #9: Verify port is actually freed
            if let port = entry.detectedPort {
                portFreed = await PortScanner.waitForPortFreed(port: UInt16(port), timeout: 5.0)
                if !portFreed {
                    log("devServerStop: port \(port) still occupied after kill")
                }
            }

            entries.removeValue(forKey: workspacePath)
            log("devServerStop: stopped for \(workspacePath)")
        }

        await sendPacket(
            WSPacket(action: .devServerStop, payload: [
                "status": "stopped",
                "portFreed": portFreed ? "true" : "false",
            ], id: packetId),
            clientId
        )
    }

    // MARK: - Dev Server Status

    func devServerStatus(
        clientId: String,
        packetId: String,
        workspacePath: String,
        streamUrl: String?
    ) async {
        var running = false

        if let entry = entries[workspacePath] {
            let shellAlive = await terminalManager.isSessionAlive(entry.sessionId)
            if !shellAlive {
                entries.removeValue(forKey: workspacePath)
            } else if let port = PortExtractor.portFromUrl(streamUrl) {
                running = PortScanner.isPortListening(port: port)
                if !running {
                    log("devServerStatus: shell alive but port \(port) closed")
                }
            } else if let port = entry.detectedPort {
                running = PortScanner.isPortListening(port: UInt16(port))
            } else {
                running = true
            }
        }

        var payload: [String: String] = ["running": running ? "true" : "false"]
        if running {
            if let port = PortExtractor.portFromUrl(streamUrl) {
                payload["port"] = "\(port)"
            } else if let port = entries[workspacePath]?.detectedPort {
                payload["port"] = "\(port)"
            }
        }

        await sendPacket(
            WSPacket(action: .devServerStatus, payload: payload, id: packetId),
            clientId
        )
    }

    // MARK: - Port Detection (Batched)

    func detectPorts(
        clientId: String,
        packetId: String,
        workspacePath: String
    ) async {
        log("detectPorts: scanning for \(workspacePath)")

        // Bug #7: Single batched scan instead of N sequential lsof calls
        let allPorts = await PortScanner.scanAllListeningPorts()
        let matched = PortScanner.portsForWorkspace(workspacePath, from: allPorts)

        let results: [[String: String]] = matched.map { port in
            [
                "port": "\(port.port)",
                "process": port.processName,
                "pid": "\(port.pid)",
                "match": port.workingDirectory?.hasPrefix(workspacePath) == true ? "workspace" : "global",
            ]
        }

        let json = (try? JSONSerialization.data(withJSONObject: results))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        log("detectPorts: found \(results.count) ports")

        await sendPacket(
            WSPacket(action: .proxyDetectPortsResult, payload: ["ports": json, "success": "true"], id: packetId),
            clientId
        )
    }

    // MARK: - Orphan Detection

    func detectOrphans() async -> [ScannedPort] {
        let allPorts = await PortScanner.scanAllListeningPorts()
        let trackedPorts = Set(entries.compactMap { $0.value.detectedPort })

        return allPorts.filter { port in
            PortScanner.isDevServerProcess(port.processName) && !trackedPorts.contains(port.port)
        }
    }

    // MARK: - Watch Mode

    func startWatching(interval: TimeInterval = 5.0, onChange: @escaping @Sendable (PortStateDiff) async -> Void) {
        stopWatching()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !Task.isCancelled else { break }
                await self.checkWatchState(onChange: onChange)
            }
        }
    }

    func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
    }

    private func checkWatchState(onChange: @escaping @Sendable (PortStateDiff) async -> Void) async {
        for (path, entry) in entries {
            let alive = await terminalManager.isSessionAlive(entry.sessionId)
            let portUp = entry.detectedPort.map { PortScanner.isPortListening(port: UInt16($0)) } ?? false

            if !alive || (!portUp && entry.detectedPort != nil) {
                let diff = PortStateDiff(
                    workspacePath: path,
                    previousPort: entry.detectedPort,
                    currentPort: nil,
                    isRunning: false
                )
                entries.removeValue(forKey: path)
                await onChange(diff)
                log("watch: dev server died for \(path)")
            }
        }
    }

    // MARK: - Shutdown

    func shutdownAll() async {
        stopWatching()
        for (_, entry) in entries {
            await terminalManager.sendInput("\u{03}", to: entry.sessionId)
            if let pgid = entry.processGroupId {
                await ProcessGroupKiller.killProcessGroup(pid: pgid, gracePeriod: 1.0)
            }
            await terminalManager.closeSession(entry.sessionId)
        }
        entries.removeAll()
        log("shutdownAll: all dev servers stopped")
    }

    // MARK: - Private Helpers

    private func acquireLock(for path: String) -> Bool {
        guard !operationLocks.contains(path) else { return false }
        operationLocks.insert(path)
        return true
    }

    private func releaseLock(for path: String) {
        operationLocks.remove(path)
    }

    private func log(_ message: String) {
        logMessage(message)
    }

    private func updatePort(workspacePath: String, port: Int) {
        if var entry = entries[workspacePath] {
            entry.detectedPort = port
            entry.state = .ready(port: port)
            entries[workspacePath] = entry
        }
    }

    /// Handle output from a dev server terminal session.
    /// Called via the output handler closure, executed within actor isolation.
    private func handleDevServerOutput(
        _ output: String,
        workspacePath: String,
        sessionId: String
    ) async {
        guard var entry = entries[workspacePath] else { return }

        let wasReady = entry.readyDetector.isReady
        entry.readyDetector.check(output)
        entry.conflictDetector.check(output)
        entries[workspacePath] = entry

        await detectSudoPrompt(output, sessionId)
        log("devServer[\(sessionId.prefix(8))]: \(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))")

        // Bug #11: extractPort uses last match for "port X in use, trying Y"
        if !wasReady, entry.readyDetector.isReady {
            if let port = PortExtractor.extractPort(from: entry.readyDetector.accumulatedOutput) {
                updatePort(workspacePath: workspacePath, port: port)
            }
        }
    }

    /// Wait for dev server ready signal or port to start listening.
    private func waitForReady(workspacePath: String, port: UInt16?, timeout: Int) async -> Bool {
        for _ in 0..<(timeout * 2) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if entries[workspacePath]?.readyDetector.isReady == true { return true }
            if let port, PortScanner.isPortListening(port: port) { return true }
        }
        return false
    }

    /// Bug #3: Verify process stability with polling instead of blind sleep.
    /// Checks session alive + port listening every 250ms for 2 seconds.
    private func verifyStability(sessionId: String, workspacePath: String) async -> Bool {
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 250_000_000)

            let alive = await terminalManager.isSessionAlive(sessionId)
            let port = entries[workspacePath]?.detectedPort

            if !alive {
                return false // Process died during stability check
            }

            if let port, PortScanner.isPortListening(port: UInt16(port)) {
                // Also try to capture the process group ID for later killing
                await captureProcessGroupId(for: workspacePath, sessionId: sessionId)
                return true
            }
        }

        // After 2 seconds, check one final time
        let alive = await terminalManager.isSessionAlive(sessionId)
        if let port = entries[workspacePath]?.detectedPort, alive {
            await captureProcessGroupId(for: workspacePath, sessionId: sessionId)
            return PortScanner.isPortListening(port: UInt16(port))
        }
        return alive && entries[workspacePath]?.detectedPort != nil
    }

    /// Capture the process group ID of the terminal session's child process
    private func captureProcessGroupId(for workspacePath: String, sessionId: String) async {
        // The terminal session runs /bin/zsh — we need the pgid of the dev server child
        // We can get it from the detected port's PID via lsof
        if let port = entries[workspacePath]?.detectedPort {
            let allPorts = await PortScanner.scanAllListeningPorts()
            if let match = allPorts.first(where: { $0.port == port }) {
                let pgid = ProcessGroupKiller.getProcessGroupId(for: pid_t(match.pid))
                if var entry = entries[workspacePath] {
                    entry.processGroupId = pgid ?? pid_t(match.pid)
                    entries[workspacePath] = entry
                }
            }
        }
    }

    /// Fallback port scanning when startup fails or times out
    private func handleFallbackPortScan(
        workspacePath: String,
        sessionId: String,
        clientId: String,
        packetId: String,
        errorMessage: String?
    ) async {
        let allPorts = await PortScanner.scanAllListeningPorts()
        let devPorts = allPorts.filter {
            PortScanner.commonDevPorts.contains($0.port) && PortScanner.isDevServerProcess($0.processName)
        }

        // Check if any responds to HTTP
        for port in devPorts {
            if await PortScanner.isHTTPResponding(port: UInt16(port.port)) {
                log("devServerStart: found existing server on port \(port.port)")
                updatePort(workspacePath: workspacePath, port: port.port)
                await sendPacket(
                    WSPacket(action: .devServerStart, payload: [
                        "status": "ready",
                        "port": "\(port.port)",
                        "sessionId": sessionId,
                    ], id: packetId),
                    clientId
                )
                return
            }
        }

        // Nothing found
        if let error = errorMessage {
            entries.removeValue(forKey: workspacePath)
            await sendPacket(
                WSPacket(action: .devServerStart, payload: ["status": "error", "error": error], id: packetId),
                clientId
            )
        } else {
            // Timeout with no confirmation — report as unconfirmed
            await sendPacket(
                WSPacket(action: .devServerStart, payload: ["status": "started_unconfirmed", "sessionId": sessionId], id: packetId),
                clientId
            )
        }
    }

    private func openBrowserToUrl(_ urlString: String) async {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            log("openBrowserToUrl: blocked non-http URL '\(urlString)'")
            return
        }
        await MainActor.run {
            NSWorkspace.shared.open(url)
        }
    }
}
