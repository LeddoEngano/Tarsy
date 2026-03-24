import Foundation
import TarsyShared
import Supabase
import AppKit

@MainActor
class DaemonManager: ObservableObject {
    @Published var isRunning = false
    @Published var activeWorkspaces: [Workspace] = []
    @Published var connectedClients = 0
    @Published var tailscaleStatus: String = "checking..."
    @Published var tailscaleIP: String?
    @Published var machineId: UUID?
    @Published var lastError: String?
    @Published var debugLog: String = ""

    private var wsServer: WebSocketServer?
    let tailscale = TailscaleManager()
    private let terminalManager = TerminalSessionManager()
    private var orchestrator: WorkspaceOrchestrator?
    private let screenCapture = ScreenCaptureService()
    private var mjpegServer: MJPEGStreamServer?
    private let openClaw = OpenClawService()
    private let remoteInput = RemoteInputService()
    private let relayClient = RelayClient()
    private var heartbeatTimer: Timer?
    private var devServerSessions: [String: String] = [:] // workspacePath -> terminalSessionId

    func start() async {
        // 0. Init orchestrator
        orchestrator = WorkspaceOrchestrator(terminalManager: terminalManager)

        // 1. Check/install Tailscale
        await setupTailscale()

        // 2. Start WebSocket server
        await startWSServer()

        // 3. Register machine in Supabase
        await registerMachine()

        // 4. Connect to relay for remote access
        await connectRelay()

        // 5. Start heartbeat
        startHeartbeat()

        isRunning = true
    }

    func stop() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        Task {
            await wsServer?.stop()
            await updateMachineStatus("offline")
        }
        isRunning = false
    }

    // MARK: - Tailscale

    func setupTailscale() async {
        let status = await tailscale.checkStatus()
        switch status {
        case .notInstalled:
            tailscaleStatus = "not installed"
        case .installed:
            tailscaleStatus = "installed - open Tailscale app and sign in"
        case .running(let ip):
            tailscaleIP = ip
            tailscaleStatus = "connected (\(ip))"
        case .error(let msg):
            tailscaleStatus = "error: \(msg)"
        }
    }

    func installTailscale() async {
        tailscaleStatus = "installing..."
        do {
            try await tailscale.install { [weak self] output in
                Task { @MainActor in
                    self?.tailscaleStatus = "installing..."
                }
            }
            tailscaleStatus = "installed - open Tailscale app and sign in"
            // Re-check after install and register if IP available
            await setupTailscale()
            if tailscaleIP != nil && machineId == nil {
                await registerMachine()
                if !isRunning {
                    await startWSServer()
                    startHeartbeat()
                    isRunning = true
                }
            }
        } catch {
            tailscaleStatus = error.localizedDescription
        }
    }

    func refreshTailscale() async {
        await setupTailscale()
        // If we now have an IP, register the machine
        if tailscaleIP != nil && machineId == nil {
            await registerMachine()
            if !isRunning {
                await startWSServer()
                startHeartbeat()
                isRunning = true
            }
        }
    }

    // MARK: - WebSocket Server

    private func startWSServer() async {
        wsServer = WebSocketServer(validateToken: { [weak self] token in
            await self?.validateAuthToken(token) ?? false
        })

        await wsServer?.setHandlers(
            onPacket: { [weak self] clientId, packet in
                await self?.handlePacket(clientId: clientId, packet: packet)
            },
            onConnect: { [weak self] _ in
                Task { @MainActor in
                    self?.connectedClients += 1
                }
            },
            onDisconnect: { [weak self] _ in
                Task { @MainActor in
                    self?.connectedClients = max(0, (self?.connectedClients ?? 1) - 1)
                }
            }
        )

        do {
            try await wsServer?.start()
        } catch {
            print("[Daemon] Failed to start WS server: \(error)")
        }
    }

    private func validateAuthToken(_ token: String) async -> Bool {
        do {
            let user = try await supabase.auth.user(jwt: token)
            return user.id != nil
        } catch {
            return false
        }
    }

    // MARK: - Relay

    private func connectRelay() async {
        // Get auth token for relay connection
        guard let session = try? await supabase.auth.session else {
            log("Cannot connect to relay — no auth session")
            return
        }

        // Setup relay handlers — relay packets go to same handler as local WS
        await relayClient.setHandlers(
            onPacket: { [weak self] packet in
                Task { @MainActor in
                    // Handle relay packets like local WebSocket packets
                    // Use "relay" as clientId so responses go back through relay
                    await self?.handlePacket(clientId: "relay", packet: packet)
                }
            }
        )

        await relayClient.connect(token: session.accessToken)
        log("Connected to relay for remote access")
    }

    // Forward response to relay when clientId is "relay"
    func sendToClientOrRelay(_ packet: WSPacket, to clientId: String) async {
        if clientId == "relay" {
            await relayClient.send(packet: packet)
        } else {
            await wsServer?.send(packet, to: clientId)
        }
    }

    // MARK: - Packet Handling

    private func handlePacket(clientId: String, packet: WSPacket) async {
        switch packet.action {
        case .workspaceList:
            await handleWorkspaceList(clientId: clientId, packet: packet)
        case .workspaceScanRepos:
            await handleScanRepos(clientId: clientId, packet: packet)
        case .workspaceCreate:
            await handleWorkspaceCreate(clientId: clientId, packet: packet)
        case .workspaceStart:
            await handleWorkspaceStart(clientId: clientId, packet: packet)
        case .workspaceStop:
            await handleWorkspaceStop(clientId: clientId, packet: packet)
        case .terminalCreate:
            await handleTerminalCreate(clientId: clientId, packet: packet)
        case .terminalInput:
            await handleTerminalInput(clientId: clientId, packet: packet)
        case .terminalClose:
            await handleTerminalClose(clientId: clientId, packet: packet)
        case .claudeCreate:
            await handleClaudeCreate(clientId: clientId, packet: packet)
        case .claudeUserResponse:
            await handleClaudeUserResponse(clientId: clientId, packet: packet)
        case .claudeMessage:
            await handleClaudeMessage(clientId: clientId, packet: packet)
        case .claudeClose:
            await handleClaudeClose(clientId: clientId, packet: packet)
        case .openclawStatus:
            await handleOpenClawStatus(clientId: clientId, packet: packet)
        case .openclawMessage:
            await handleOpenClawMessage(clientId: clientId, packet: packet)
        case .devServerStart:
            await handleDevServerStart(clientId: clientId, packet: packet)
        case .devServerStop:
            await handleDevServerStop(clientId: clientId, packet: packet)
        case .devServerStatus:
            await handleDevServerStatus(clientId: clientId, packet: packet)
        case .browserOpenUrl:
            await handleBrowserOpenUrl(clientId: clientId, packet: packet)
        case .streamStart:
            await handleStreamStart(clientId: clientId, packet: packet)
        case .streamStop:
            await handleStreamStop(clientId: clientId, packet: packet)
        case .remoteTap, .remoteDoubleTap, .remoteLongPress, .remoteScroll, .remoteScrollStart, .remoteScrollEnd, .remoteDrag, .remotePinch, .remotePinchStart, .remotePinchEnd, .remoteKeyboard, .remoteButton:
            handleRemoteInput(packet: packet)
        case .screenshotRequest:
            await handleScreenshotRequest(clientId: clientId, packet: packet)
        // Multi-Provider Engine
        case .engineCreate:
            await handleEngineCreate(clientId: clientId, packet: packet)
        case .engineMessage:
            await handleEngineMessage(clientId: clientId, packet: packet)
        case .engineUserResponse:
            await handleEngineUserResponse(clientId: clientId, packet: packet)
        case .engineClose:
            await handleEngineClose(clientId: clientId, packet: packet)
        // Git Safety Net
        case .gitCheckpoint:
            await handleGitCheckpoint(clientId: clientId, packet: packet)
        case .gitDiff:
            await handleGitDiff(clientId: clientId, packet: packet)
        case .gitRollback:
            await handleGitRollback(clientId: clientId, packet: packet)
        case .gitHistory:
            await handleGitHistory(clientId: clientId, packet: packet)
        case .gitFileDiff:
            await handleGitFileDiff(clientId: clientId, packet: packet)
        case .gitBranches:
            await handleGitBranches(clientId: clientId, packet: packet)
        case .gitCheckout:
            await handleGitCheckout(clientId: clientId, packet: packet)
        case .gitPull:
            await handleGitPull(clientId: clientId, packet: packet)
        // File Explorer
        case .fileTree:
            await handleFileTree(clientId: clientId, packet: packet)
        case .fileRead:
            await handleFileRead(clientId: clientId, packet: packet)
        default:
            await sendToClientOrRelay(
                WSPacket(action: .error, payload: ["message": "Unknown action: \(packet.action.rawValue)"]),
                to: clientId
            )
        }
    }

    private func handleScanRepos(clientId: String, packet: WSPacket) async {
        let scanner = RepoScanner()
        let repos = await scanner.scan()

        // Encode repos as JSON string in payload
        if let data = try? JSONEncoder().encode(repos),
           let json = String(data: data, encoding: .utf8) {
            await sendToClientOrRelay(
                WSPacket(action: .workspaceScanResult, payload: ["repos": json], id: packet.id),
                to: clientId
            )
        }
    }

    private func handleWorkspaceCreate(clientId: String, packet: WSPacket) async {
        guard let name = packet.payload?["name"],
              let localPath = packet.payload?["path"] else { return }

        let repoUrl = packet.payload?["repoUrl"]

        do {
            let result = try await orchestrator?.setupWorkspace(repoUrl: repoUrl, localPath: localPath, name: name)
            await sendToClientOrRelay(
                WSPacket(action: .workspaceCreate, payload: [
                    "sessionId": result?.sessionId ?? "",
                    "stack": result?.detectedStack ?? "unknown",
                    "devCommand": result?.detectedDevCommand ?? "",
                    "status": "ready"
                ], id: packet.id),
                to: clientId
            )
        } catch {
            await sendToClientOrRelay(
                WSPacket(action: .error, payload: ["message": error.localizedDescription], id: packet.id),
                to: clientId
            )
        }
    }

    private func handleWorkspaceList(clientId: String, packet: WSPacket) async {
        let sessions = await terminalManager.listSessions()
        await sendToClientOrRelay(
            WSPacket(action: .workspaceList, payload: ["sessions": sessions.joined(separator: ",")], id: packet.id),
            to: clientId
        )
    }

    private func handleWorkspaceStart(clientId: String, packet: WSPacket) async {
        guard let path = packet.payload?["path"] else { return }
        let devCmd = packet.payload?["devCommand"]

        do {
            let sessionId = try await orchestrator?.coldStart(localPath: path, devServerCommand: devCmd) ?? ""
            await terminalManager.setOutputHandler(for: sessionId) { [weak self] output in
                Task {
                    await self?.wsServer?.send(
                        WSPacket(action: .terminalOutput, payload: ["sessionId": sessionId, "output": output]),
                        to: clientId
                    )
                }
            }

            await sendToClientOrRelay(
                WSPacket(action: .workspaceStart, payload: ["sessionId": sessionId, "status": "running"], id: packet.id),
                to: clientId
            )
        } catch {
            await sendToClientOrRelay(
                WSPacket(action: .error, payload: ["message": error.localizedDescription], id: packet.id),
                to: clientId
            )
        }
    }

    private func handleWorkspaceStop(clientId: String, packet: WSPacket) async {
        guard let sessionId = packet.payload?["sessionId"] else { return }
        await terminalManager.closeSession(sessionId)
        await sendToClientOrRelay(
            WSPacket(action: .workspaceStop, payload: ["sessionId": sessionId, "status": "idle"], id: packet.id),
            to: clientId
        )
    }

    private func handleTerminalCreate(clientId: String, packet: WSPacket) async {
        let path = packet.payload?["path"]
        do {
            let sessionId = try await terminalManager.createSession(workingDirectory: path)
            await terminalManager.setOutputHandler(for: sessionId) { [weak self] output in
                Task {
                    await self?.wsServer?.send(
                        WSPacket(action: .terminalOutput, payload: ["sessionId": sessionId, "output": output]),
                        to: clientId
                    )
                }
            }
            await sendToClientOrRelay(
                WSPacket(action: .terminalCreate, payload: ["sessionId": sessionId], id: packet.id),
                to: clientId
            )
        } catch {
            await sendToClientOrRelay(
                WSPacket(action: .error, payload: ["message": error.localizedDescription], id: packet.id),
                to: clientId
            )
        }
    }

    private func handleTerminalInput(clientId: String, packet: WSPacket) async {
        guard let sessionId = packet.payload?["sessionId"],
              let input = packet.payload?["input"] else { return }
        await terminalManager.sendInput(input, to: sessionId)
    }

    private func handleTerminalClose(clientId: String, packet: WSPacket) async {
        guard let sessionId = packet.payload?["sessionId"] else { return }
        await terminalManager.closeSession(sessionId)
        await sendToClientOrRelay(
            WSPacket(action: .terminalClose, payload: ["sessionId": sessionId], id: packet.id),
            to: clientId
        )
    }

    // MARK: - Claude Code

    private func handleClaudeCreate(clientId: String, packet: WSPacket) async {
        guard let path = packet.payload?["path"] else {
            log("claudeCreate: missing path")
            return
        }
        let aiContext = packet.payload?["aiContext"]
        let initialMessage = packet.payload?["message"]
        let sid = UUID().uuidString
        let workspaceName = path.components(separatedBy: "/").last ?? "workspace"

        log("claudeCreate: path=\(path), sid=\(sid), hasMessage=\(initialMessage != nil)")

        do {
            let _ = try await terminalManager.createClaudeSession(
                id: sid,
                workspacePath: path,
                aiContext: aiContext,
                onOutput: { [weak self] output in
                    Task {
                        await self?.wsServer?.send(
                            WSPacket(action: .claudeOutput, payload: ["sessionId": sid, "output": output]),
                            to: clientId
                        )
                    }
                },
                onComplete: { [weak self] (message: String) in
                    Task {
                        await self?.wsServer?.send(
                            WSPacket(action: .claudeComplete, payload: ["sessionId": sid, "message": message]),
                            to: clientId
                        )
                        PushNotificationService.shared.notifyTaskComplete(
                            workspace: workspaceName,
                            summary: message
                        )
                    }
                },
                onAskUser: { [weak self] (questionsJson: String, _: [String]) in
                    Task {
                        // questionsJson is already a JSON string of the full questions array
                        await self?.wsServer?.send(
                            WSPacket(action: .claudeAskUser, payload: [
                                "sessionId": sid,
                                "questions": questionsJson
                            ]),
                            to: clientId
                        )
                    }
                }
            )

            log("claudeCreate: session created, sending response")

            await sendToClientOrRelay(
                WSPacket(action: .claudeCreate, payload: ["sessionId": sid], id: packet.id),
                to: clientId
            )

            // Send the initial message if provided
            if let msg = initialMessage, !msg.isEmpty {
                log("claudeCreate: sending initial message: \(msg)")
                // Wait a moment for Claude CLI to initialize
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await terminalManager.sendClaudeMessage(msg, to: sid)
            }
        } catch {
            log("claudeCreate: FAILED — \(error)")
            await sendToClientOrRelay(
                WSPacket(action: .error, payload: ["message": "Claude Code error: \(error.localizedDescription)"], id: packet.id),
                to: clientId
            )
        }
    }

    private func handleClaudeUserResponse(clientId: String, packet: WSPacket) async {
        guard let sessionId = packet.payload?["sessionId"],
              let answer = packet.payload?["answer"] else { return }
        log("claudeUserResponse: \(answer) for session \(sessionId)")
        await terminalManager.respondToClaudeQuestion(answer, sessionId: sessionId)
    }

    private func handleClaudeMessage(clientId: String, packet: WSPacket) async {
        guard let sessionId = packet.payload?["sessionId"],
              let message = packet.payload?["message"] else { return }
        let imagesJson = packet.payload?["images"]
        await terminalManager.sendClaudeMessage(message, images: imagesJson, to: sessionId)
    }

    private func handleClaudeClose(clientId: String, packet: WSPacket) async {
        guard let sessionId = packet.payload?["sessionId"] else { return }
        await terminalManager.closeClaudeSession(sessionId)
        await sendToClientOrRelay(
            WSPacket(action: .claudeClose, payload: ["sessionId": sessionId], id: packet.id),
            to: clientId
        )
    }

    // MARK: - OpenClaw

    private func handleOpenClawStatus(clientId: String, packet: WSPacket) async {
        let running = await openClaw.checkGateway()
        await sendToClientOrRelay(
            WSPacket(action: .openclawStatus, payload: [
                "running": running ? "true" : "false",
                "port": "18789"
            ], id: packet.id),
            to: clientId
        )
    }

    private func handleOpenClawMessage(clientId: String, packet: WSPacket) async {
        guard let message = packet.payload?["message"] else { return }
        let agentId = packet.payload?["agentId"] ?? "openclaw:main"

        // Check if gateway is running, start if needed
        let running = await openClaw.checkGateway()
        if !running {
            do {
                try await openClaw.startGateway()
            } catch {
                await sendToClientOrRelay(
                    WSPacket(action: .error, payload: ["message": "OpenClaw gateway not running: \(error.localizedDescription)"], id: packet.id),
                    to: clientId
                )
                return
            }
        }

        do {
            var fullResponse = ""
            try await openClaw.sendMessage(message, agentId: agentId) { [weak self] chunk in
                fullResponse += chunk
                Task {
                    await self?.wsServer?.send(
                        WSPacket(action: .openclawOutput, payload: ["output": chunk]),
                        to: clientId
                    )
                }
            }
            await sendToClientOrRelay(
                WSPacket(action: .openclawComplete, payload: ["message": fullResponse], id: packet.id),
                to: clientId
            )
        } catch {
            await sendToClientOrRelay(
                WSPacket(action: .error, payload: ["message": "OpenClaw error: \(error.localizedDescription)"], id: packet.id),
                to: clientId
            )
        }
    }

    // MARK: - Dev Server

    private func handleDevServerStart(clientId: String, packet: WSPacket) async {
        guard let path = packet.payload?["path"],
              let command = packet.payload?["command"], !command.isEmpty else {
            await sendToClientOrRelay(
                WSPacket(action: .error, payload: ["message": "Missing path or command for dev server"], id: packet.id),
                to: clientId
            )
            return
        }

        let expandedPath = (path as NSString).expandingTildeInPath
        let streamUrl = packet.payload?["streamUrl"]

        // Already running? Check with a real port probe instead of just checking the shell
        if let existingId = devServerSessions[expandedPath],
           await terminalManager.isSessionAlive(existingId) {
            let actuallyServing = portFromUrl(streamUrl).map { isPortListening(port: $0) } ?? true
            if actuallyServing {
                await sendToClientOrRelay(
                    WSPacket(action: .devServerStart, payload: ["status": "running", "sessionId": existingId], id: packet.id),
                    to: clientId
                )
                return
            } else {
                // Shell alive but server died inside it — kill and restart
                await terminalManager.closeSession(existingId)
                devServerSessions.removeValue(forKey: expandedPath)
                log("devServerStart: old session alive but port closed, restarting")
            }
        }

        do {
            let sessionId = try await terminalManager.createSession(workingDirectory: expandedPath)
            devServerSessions[expandedPath] = sessionId

            // Monitor terminal output for server-ready signals
            let serverReady = DevServerReadySignal()
            await terminalManager.setOutputHandler(for: sessionId) { [weak self] output in
                Task {
                    await serverReady.check(output)
                    await MainActor.run { self?.log("devServer[\(sessionId.prefix(8))]: \(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))") }
                }
            }

            // Source shell config first to ensure PATH has npm/node/pnpm/etc.
            let fullCommand = "source ~/.zshrc 2>/dev/null; source ~/.zprofile 2>/dev/null; \(command)"
            await terminalManager.sendInput(fullCommand, to: sessionId)
            log("devServerStart: running '\(command)' in \(expandedPath)")

            // Wait for actual confirmation: either output-based or port-based
            let targetPort = portFromUrl(streamUrl)
            let confirmed = await waitForDevServer(signal: serverReady, port: targetPort, timeout: 15)

            if confirmed {
                log("devServerStart: confirmed running")
                await sendToClientOrRelay(
                    WSPacket(action: .devServerStart, payload: ["status": "running", "sessionId": sessionId], id: packet.id),
                    to: clientId
                )
                // Open browser to streamUrl
                if let url = streamUrl, !url.isEmpty {
                    await openBrowserToUrl(url)
                }
            } else {
                log("devServerStart: could not confirm, assuming started")
                await sendToClientOrRelay(
                    WSPacket(action: .devServerStart, payload: ["status": "started_unconfirmed", "sessionId": sessionId], id: packet.id),
                    to: clientId
                )
            }
        } catch {
            await sendToClientOrRelay(
                WSPacket(action: .error, payload: ["message": "Dev server failed: \(error.localizedDescription)"], id: packet.id),
                to: clientId
            )
        }
    }

    private func handleDevServerStop(clientId: String, packet: WSPacket) async {
        guard let path = packet.payload?["path"] else { return }
        let expandedPath = (path as NSString).expandingTildeInPath

        if let sessionId = devServerSessions[expandedPath] {
            // Send Ctrl+C first to gracefully stop the dev server, then close session
            await terminalManager.sendInput("\u{03}", to: sessionId)
            try? await Task.sleep(nanoseconds: 500_000_000)
            await terminalManager.closeSession(sessionId)
            devServerSessions.removeValue(forKey: expandedPath)
            log("devServerStop: stopped for \(expandedPath)")
        }

        await sendToClientOrRelay(
            WSPacket(action: .devServerStop, payload: ["status": "stopped"], id: packet.id),
            to: clientId
        )
    }

    private func handleDevServerStatus(clientId: String, packet: WSPacket) async {
        guard let path = packet.payload?["path"] else { return }
        let expandedPath = (path as NSString).expandingTildeInPath
        let streamUrl = packet.payload?["streamUrl"]

        var running = false

        if let sessionId = devServerSessions[expandedPath] {
            let shellAlive = await terminalManager.isSessionAlive(sessionId)
            if !shellAlive {
                devServerSessions.removeValue(forKey: expandedPath)
            } else if let port = portFromUrl(streamUrl) {
                // Real check: is the port actually open?
                running = isPortListening(port: port)
                if !running {
                    log("devServerStatus: shell alive but port \(port) closed")
                }
            } else {
                // No port to check, trust the shell
                running = true
            }
        }

        await sendToClientOrRelay(
            WSPacket(action: .devServerStatus, payload: ["running": running ? "true" : "false"], id: packet.id),
            to: clientId
        )
    }

    // MARK: - Browser

    private func handleBrowserOpenUrl(clientId: String, packet: WSPacket) async {
        guard let urlString = packet.payload?["url"], !urlString.isEmpty else {
            await sendToClientOrRelay(
                WSPacket(action: .error, payload: ["message": "Missing url"], id: packet.id),
                to: clientId
            )
            return
        }
        await openBrowserToUrl(urlString)
        log("browserOpenUrl: \(urlString)")
        await sendToClientOrRelay(
            WSPacket(action: .browserOpenUrl, payload: ["status": "opened", "url": urlString], id: packet.id),
            to: clientId
        )
    }

    // MARK: - Dev Server Helpers

    private func openBrowserToUrl(_ urlString: String) async {
        guard let url = URL(string: urlString) else { return }
        log("openBrowserToUrl: opening \(urlString)")
        NSWorkspace.shared.open(url)
    }

    private func portFromUrl(_ urlString: String?) -> UInt16? {
        guard let urlString, let url = URL(string: urlString) else { return nil }
        if let port = url.port { return UInt16(port) }
        // Default ports
        if url.scheme == "https" { return 443 }
        return 80
    }

    private nonisolated func waitForDevServer(signal: DevServerReadySignal, port: UInt16?, timeout: Int) async -> Bool {
        for _ in 0..<(timeout * 2) {
            try? await Task.sleep(nanoseconds: 500_000_000)

            // Check if output contained ready signals
            if await signal.isReady { return true }

            // Check if port is open (runs on calling thread, not main)
            if let port, isPortListening(port: port) { return true }
        }
        return false
    }

    private nonisolated func isPortListening(port: UInt16, host: String = "127.0.0.1") -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { Darwin.close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(host)

        let flags = fcntl(sock, F_GETFL, 0)
        fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if result == 0 { return true }

        var pollFd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        let pollResult = poll(&pollFd, 1, 200)
        return pollResult > 0 && (pollFd.revents & Int16(POLLOUT)) != 0
    }

    // MARK: - Remote Input

    private func handleRemoteInput(packet: WSPacket) {
        let x = Double(packet.payload?["x"] ?? "0.5") ?? 0.5
        let y = Double(packet.payload?["y"] ?? "0.5") ?? 0.5
        log("remoteInput: \(packet.action.rawValue) x=\(String(format: "%.3f", x)) y=\(String(format: "%.3f", y))")

        switch packet.action {
        case .remoteTap:
            remoteInput.tap(relativeX: x, relativeY: y)
        case .remoteDoubleTap:
            remoteInput.doubleTap(relativeX: x, relativeY: y)
        case .remoteLongPress:
            remoteInput.longPress(relativeX: x, relativeY: y)
        case .remoteScrollStart:
            remoteInput.scrollStart(relativeX: x, relativeY: y)
        case .remoteScroll:
            let dx = Double(packet.payload?["dx"] ?? "0") ?? 0
            let dy = Double(packet.payload?["dy"] ?? "0") ?? 0
            remoteInput.scroll(relativeX: x, relativeY: y, deltaX: dx, deltaY: dy)
        case .remoteScrollEnd:
            remoteInput.scrollEnd()
        case .remoteDrag:
            let toX = Double(packet.payload?["toX"] ?? "0") ?? 0
            let toY = Double(packet.payload?["toY"] ?? "0") ?? 0
            remoteInput.drag(fromX: x, fromY: y, toX: toX, toY: toY)
        case .remotePinchStart:
            remoteInput.pinchStart(relativeX: x, relativeY: y)
        case .remotePinch:
            let scale = Double(packet.payload?["scale"] ?? "1") ?? 1
            remoteInput.pinchUpdate(scale: scale)
        case .remotePinchEnd:
            remoteInput.pinchEnd()
        case .remoteKeyboard:
            if let text = packet.payload?["text"] {
                remoteInput.typeText(text)
            }
        case .remoteButton:
            if let button = packet.payload?["button"] {
                remoteInput.pressButton(button)
            }
        default:
            break
        }
    }

    // MARK: - Screenshot Transfer

    private func handleScreenshotRequest(clientId: String, packet: WSPacket) async {
        let udid = packet.payload?["udid"] ?? "booted"
        let tmpPath = NSTemporaryDirectory() + "tarsy_screenshot_\(UUID().uuidString).png"

        log("screenshot: capturing simulator \(udid)")

        // Take native screenshot via simctl
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "io", udid, "screenshot", tmpPath]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0,
                  let imageData = try? Data(contentsOf: URL(fileURLWithPath: tmpPath)),
                  let nsImage = NSImage(data: imageData) else {
                await sendToClientOrRelay(
                    WSPacket(action: .error, payload: ["message": "Screenshot failed"], id: packet.id),
                    to: clientId
                )
                return
            }

            // Convert to JPEG for smaller transfer
            guard let tiffData = nsImage.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
                return
            }

            // Send as base64
            let base64 = jpegData.base64EncodedString()
            let sizeKB = jpegData.count / 1024
            log("screenshot: captured \(sizeKB)KB JPEG, sending to iOS")

            await sendToClientOrRelay(
                WSPacket(action: .screenshotResult, payload: [
                    "data": base64,
                    "size": "\(sizeKB)"
                ], id: packet.id),
                to: clientId
            )

            // Cleanup
            try? FileManager.default.removeItem(atPath: tmpPath)

        } catch {
            log("screenshot: FAILED — \(error)")
            await sendToClientOrRelay(
                WSPacket(action: .error, payload: ["message": "Screenshot error: \(error.localizedDescription)"], id: packet.id),
                to: clientId
            )
        }
    }

    // MARK: - Stream

    private func handleStreamStart(clientId: String, packet: WSPacket) async {
        let stack = packet.payload?["stack"] ?? "web"
        let streamUrl = packet.payload?["streamUrl"]
        let quality = packet.payload?["quality"]

        // Handle quality change for existing stream
        if let quality, screenCapture.isCapturing {
            if quality == "high" {
                await mjpegServer?.setQuality(jpegQuality: 0.8, maxFrameSize: 1_000_000)
                log("streamStart: quality boosted to HIGH (fullscreen)")
            } else {
                let isRelay = clientId == "relay"
                let isLocal = !isRelay && !(packet.payload?["ip"]?.hasPrefix("100.") ?? true)
                await mjpegServer?.setQuality(
                    jpegQuality: isLocal ? 0.65 : 0.55,
                    maxFrameSize: isLocal ? 500_000 : 300_000
                )
                log("streamStart: quality restored to \(isLocal ? "LAN" : "relay")")
            }
            return
        }

        log("streamStart: looking for window with stack=\(stack), streamUrl=\(streamUrl ?? "nil")")

        // If a streamUrl is provided, open the browser to that URL first
        if let urlString = streamUrl, !urlString.isEmpty {
            await openBrowserToUrl(urlString)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }

        // Find the right window for this stack
        var window = await screenCapture.findWindow(forStack: stack)

        // If no window found, open the default app for this stack and retry
        if window == nil {
            log("streamStart: no window found, opening app for stack \(stack)")
            if let urlString = streamUrl, !urlString.isEmpty {
                await openBrowserToUrl(urlString)
            } else {
                await openAppForStack(stack)
            }
            // Wait for app to launch
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            window = await screenCapture.findWindow(forStack: stack)
        }

        guard let window else {
            log("streamStart: still no window found after opening app")
            await sendToClientOrRelay(
                WSPacket(action: .error, payload: ["message": "No window found for stack: \(stack). Could not open app automatically."], id: packet.id),
                to: clientId
            )
            return
        }

        log("streamStart: found window '\(window.title ?? "?")' from \(window.owningApplication?.applicationName ?? "?")")

        do {
            // Start MJPEG server if not running
            if mjpegServer == nil {
                mjpegServer = MJPEGStreamServer()
                try await mjpegServer?.start()
                log("streamStart: MJPEG server started on port 8643")
            }

            // Detect connection type and set quality accordingly
            let ipPayload = packet.payload?["ip"] ?? ""
            let isLocalConnection = !ipPayload.isEmpty && !ipPayload.hasPrefix("100.")
            let isRelay = clientId == "relay"
            let fps: Int
            let scale: CGFloat
            if isLocalConnection && !isRelay {
                // Local WiFi — best quality
                fps = 15
                scale = 1.0
                await mjpegServer?.setQuality(jpegQuality: 0.85, maxFrameSize: 1_500_000)
                log("streamStart: LAN — high quality (15fps, 1.0x, q0.85)")
            } else {
                // Relay / remote — prioritize quality over fps
                fps = 8
                scale = 0.85
                await mjpegServer?.setQuality(jpegQuality: 0.75, maxFrameSize: 800_000)
                log("streamStart: relay — quality priority (8fps, 0.85x, q0.75)")
            }

            // Wire screen capture to MJPEG (local + relay)
            screenCapture.onFrame = { [weak self] cgImage in
                Task {
                    await self?.mjpegServer?.sendFrame(cgImage)

                    // Also send frame via relay for remote clients
                    if let jpegData = await self?.mjpegServer?.encodeFrame(cgImage) {
                        await self?.relayClient.sendBinary(jpegData)
                    }
                }
            }

            let ownerApp = window.owningApplication?.applicationName ?? ""
            let isSimulator = ownerApp == "Simulator"

            try await screenCapture.startCapture(window: window, fps: fps, scale: scale, cropTitleBar: isSimulator)
            let pid = window.owningApplication?.processID ?? 0
            remoteInput.setTargetWindow(
                frame: window.frame,
                windowId: CGWindowID(window.windowID),
                pid: pid_t(pid),
                isSimulator: isSimulator,
                appName: ownerApp
            )

            log("streamStart: capture started")

            let streamPort: UInt16 = 8643
            await sendToClientOrRelay(
                WSPacket(action: .streamStart, payload: [
                    "port": "\(streamPort)",
                    "window": window.title ?? "unknown",
                    "width": "\(Int(window.frame.width))",
                    "height": "\(Int(window.frame.height))"
                ], id: packet.id),
                to: clientId
            )
            log("streamStart: response sent to client")
        } catch {
            log("streamStart: FAILED — \(error)")
            await sendToClientOrRelay(
                WSPacket(action: .error, payload: ["message": "Stream failed: \(error.localizedDescription)"], id: packet.id),
                to: clientId
            )
        }
    }

    private func openAppForStack(_ stack: String) async {
        let bundleId: String
        switch stack {
        case "web":
            // Try Chrome first, then Safari
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") != nil {
                bundleId = "com.google.Chrome"
            } else {
                bundleId = "com.apple.Safari"
            }
        case "mobile":
            bundleId = "com.apple.iphonesimulator"
        case "backend":
            bundleId = "com.apple.Terminal"
        default:
            bundleId = "com.apple.Safari"
        }

        log("streamStart: opening \(bundleId)")
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func handleStreamStop(clientId: String, packet: WSPacket) async {
        await screenCapture.stopCapture()
        await mjpegServer?.stop()
        mjpegServer = nil

        await sendToClientOrRelay(
            WSPacket(action: .streamStop, id: packet.id),
            to: clientId
        )
    }

    // MARK: - Machine Registration

    private func getLocalIP() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" { // WiFi interfaces
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    address = String(cString: hostname)
                }
            }
        }
        return address
    }

    private func log(_ msg: String) {
        let entry = "[\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))] \(msg)"
        print(entry)
        debugLog += entry + "\n"
    }

    private func registerMachine() async {
        let hostname = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let localIp = getLocalIP()

        log("registerMachine: tailscaleIP=\(tailscaleIP ?? "nil"), localIP=\(localIp ?? "nil")")

        guard tailscaleIP != nil || localIp != nil else {
            log("registerMachine: skipped — no IPs available")
            lastError = "No IPs available to register"
            return
        }

        do {
            let session = try await supabase.auth.session
            log("registerMachine: got session for user \(session.user.id)")

            let existing: [Machine] = try await supabase
                .from("machines")
                .select()
                .eq("user_id", value: session.user.id.uuidString)
                .execute()
                .value

            log("registerMachine: found \(existing.count) existing machines")

            var updateData: [String: String] = [
                "hostname": hostname,
                "status": "online",
                "last_seen_at": ISO8601DateFormatter().string(from: Date())
            ]
            if let ip = tailscaleIP { updateData["tailscale_ip"] = ip }
            if let lip = localIp { updateData["local_ip"] = lip }

            if let machine = existing.first {
                machineId = machine.id
                try await supabase
                    .from("machines")
                    .update(updateData)
                    .eq("id", value: machine.id.uuidString)
                    .execute()
                log("registerMachine: updated machine \(machine.id)")
            } else {
                updateData["user_id"] = session.user.id.uuidString
                log("registerMachine: inserting new machine with data: \(updateData)")
                let result: Machine = try await supabase
                    .from("machines")
                    .insert(updateData)
                    .select()
                    .single()
                    .execute()
                    .value
                machineId = result.id
                log("registerMachine: created machine \(result.id)")
            }
            lastError = nil
        } catch {
            log("registerMachine: FAILED — \(error)")
            lastError = "Register failed: \(error.localizedDescription)"
        }
    }

    private func updateMachineStatus(_ status: String) async {
        guard let id = machineId else { return }
        do {
            try await supabase
                .from("machines")
                .update(["status": status, "last_seen_at": ISO8601DateFormatter().string(from: Date())])
                .eq("id", value: id.uuidString)
                .execute()
        } catch {
            print("[Daemon] Failed to update status: \(error)")
        }
    }

    // MARK: - Multi-Provider Engine

    private func handleEngineCreate(clientId: String, packet: WSPacket) async {
        guard let path = packet.payload?["path"],
              let engineTypeRaw = packet.payload?["engineType"],
              let engineType = AIEngineType(rawValue: engineTypeRaw) else {
            log("engineCreate: missing path or engineType")
            return
        }

        let apiKey = packet.payload?["apiKey"]
        let command = packet.payload?["command"]
        let aiContext = packet.payload?["aiContext"]
        let initialMessage = packet.payload?["message"]
        let sid = UUID().uuidString

        log("engineCreate: type=\(engineType.displayName), path=\(path), sid=\(sid)")

        // For Claude, use the existing rich session
        if engineType == .claude {
            do {
                let _ = try await terminalManager.createClaudeSession(
                    id: sid,
                    workspacePath: path,
                    aiContext: aiContext,
                    onOutput: { [weak self] output in
                        Task {
                            await self?.wsServer?.send(
                                WSPacket(action: .engineOutput, payload: ["sessionId": sid, "output": output, "engineType": "claude"]),
                                to: clientId
                            )
                        }
                    },
                    onComplete: { [weak self] (message: String) in
                        Task {
                            await self?.wsServer?.send(
                                WSPacket(action: .engineComplete, payload: ["sessionId": sid, "message": message, "engineType": "claude"]),
                                to: clientId
                            )
                        }
                    },
                    onAskUser: { [weak self] questionsJson, _ in
                        Task {
                            await self?.wsServer?.send(
                                WSPacket(action: .engineAskUser, payload: ["sessionId": sid, "questions": questionsJson, "engineType": "claude"]),
                                to: clientId
                            )
                        }
                    }
                )

                // Set status handler for model/usage info
                await terminalManager.setClaudeStatusHandler(sessionId: sid) { [weak self] model, inputTokens, outputTokens in
                    Task {
                        await self?.sendToClientOrRelay(
                            WSPacket(action: .engineStatus, payload: [
                                "sessionId": sid,
                                "model": model,
                                "inputTokens": "\(inputTokens)",
                                "outputTokens": "\(outputTokens)"
                            ]),
                            to: clientId
                        )
                    }
                }

                await sendToClientOrRelay(
                    WSPacket(action: .engineCreate, payload: ["sessionId": sid, "engineType": "claude"], id: packet.id),
                    to: clientId
                )

                if let msg = initialMessage, !msg.isEmpty {
                    let imagesJson = packet.payload?["images"]
                    await terminalManager.sendClaudeMessage(msg, images: imagesJson, to: sid)
                }
            } catch {
                log("engineCreate error: \(error)")
            }
            return
        }

        // Generic engine (Gemini, Codex, Aider, Custom)
        do {
            let _ = try await terminalManager.createEngineSession(
                id: sid,
                engineType: engineType,
                workspacePath: path,
                command: command,
                apiKey: apiKey,
                onOutput: { [weak self] output in
                    Task {
                        await self?.wsServer?.send(
                            WSPacket(action: .engineOutput, payload: ["sessionId": sid, "output": output, "engineType": engineTypeRaw]),
                            to: clientId
                        )
                    }
                },
                onComplete: { [weak self] (message: String) in
                    Task {
                        await self?.wsServer?.send(
                            WSPacket(action: .engineComplete, payload: ["sessionId": sid, "message": message, "engineType": engineTypeRaw]),
                            to: clientId
                        )
                    }
                }
            )

            await sendToClientOrRelay(
                WSPacket(action: .engineCreate, payload: ["sessionId": sid, "engineType": engineTypeRaw], id: packet.id),
                to: clientId
            )

            if let msg = initialMessage, !msg.isEmpty {
                await terminalManager.sendEngineMessage(msg, to: sid)
            }
        } catch {
            log("engineCreate error: \(error)")
        }
    }

    private func handleEngineMessage(clientId: String, packet: WSPacket) async {
        guard let sessionId = packet.payload?["sessionId"],
              let message = packet.payload?["message"] else { return }
        let engineType = packet.payload?["engineType"] ?? ""
        let imagesJson = packet.payload?["images"]

        if engineType == "claude" {
            await terminalManager.sendClaudeMessage(message, images: imagesJson, to: sessionId)
        } else {
            await terminalManager.sendEngineMessage(message, to: sessionId)
        }
    }

    private func handleEngineUserResponse(clientId: String, packet: WSPacket) async {
        guard let sessionId = packet.payload?["sessionId"],
              let answer = packet.payload?["answer"] else { return }
        let engineType = packet.payload?["engineType"] ?? ""

        if engineType == "claude" {
            await terminalManager.respondToClaudeQuestion(answer, sessionId: sessionId)
        } else {
            await terminalManager.respondToEngineQuestion(answer, sessionId: sessionId)
        }
    }

    private func handleEngineClose(clientId: String, packet: WSPacket) async {
        guard let sessionId = packet.payload?["sessionId"] else { return }
        let engineType = packet.payload?["engineType"] ?? ""

        if engineType == "claude" {
            await terminalManager.closeClaudeSession(sessionId)
        } else {
            await terminalManager.closeEngineSession(sessionId)
        }
        await sendToClientOrRelay(
            WSPacket(action: .engineClose, payload: ["sessionId": sessionId], id: packet.id),
            to: clientId
        )
    }

    // MARK: - Git Safety Net

    private func handleGitCheckpoint(clientId: String, packet: WSPacket) async {
        guard let path = packet.payload?["path"] else { return }
        let message = packet.payload?["message"] ?? "checkpoint"
        let expandedPath = (path as NSString).expandingTildeInPath

        let result = await runGitCommand(["add", "-A"], at: expandedPath)
        guard result.success else {
            await sendGitResult(action: .gitCheckpointResult, clientId: clientId, packetId: packet.id, success: false, error: result.output)
            return
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let commitMsg = "checkpoint: \(message) [\(timestamp)]"
        let commitResult = await runGitCommand(["commit", "-m", commitMsg, "--allow-empty"], at: expandedPath)

        // Get files changed count
        let diffStat = await runGitCommand(["diff", "--stat", "HEAD~1..HEAD"], at: expandedPath)
        let filesCount = diffStat.output.components(separatedBy: "\n").count - 1

        await sendGitResult(action: .gitCheckpointResult, clientId: clientId, packetId: packet.id,
                           success: commitResult.success,
                           data: ["message": commitMsg, "filesChanged": "\(max(0, filesCount))"],
                           error: commitResult.success ? nil : commitResult.output)
    }

    private func handleGitDiff(clientId: String, packet: WSPacket) async {
        guard let path = packet.payload?["path"] else { return }
        let expandedPath = (path as NSString).expandingTildeInPath

        // Get list of changed files with stats
        let statusResult = await runGitCommand(["status", "--porcelain"], at: expandedPath)
        let diffResult = await runGitCommand(["diff", "--stat"], at: expandedPath)
        let diffFull = await runGitCommand(["diff"], at: expandedPath)

        await sendToClientOrRelay(
            WSPacket(action: .gitDiffResult, payload: [
                "status": statusResult.output,
                "stat": diffResult.output,
                "diff": String(diffFull.output.prefix(50000)), // Limit size
                "success": "true"
            ], id: packet.id),
            to: clientId
        )
    }

    private func handleGitRollback(clientId: String, packet: WSPacket) async {
        guard let path = packet.payload?["path"] else { return }
        let expandedPath = (path as NSString).expandingTildeInPath
        let target = packet.payload?["target"] ?? "HEAD~1"

        let result = await runGitCommand(["reset", "--hard", target], at: expandedPath)

        await sendGitResult(action: .gitRollbackResult, clientId: clientId, packetId: packet.id,
                           success: result.success, error: result.success ? nil : result.output)
    }

    private func handleGitHistory(clientId: String, packet: WSPacket) async {
        guard let path = packet.payload?["path"] else { return }
        let expandedPath = (path as NSString).expandingTildeInPath
        let limit = packet.payload?["limit"] ?? "20"

        let result = await runGitCommand([
            "log", "--oneline", "--format=%H|||%s|||%ai|||%an", "-\(limit)"
        ], at: expandedPath)

        // Parse into structured data
        var commits: [[String: String]] = []
        for line in result.output.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "|||")
            guard parts.count >= 3 else { continue }
            commits.append([
                "hash": parts[0],
                "message": parts[1],
                "date": parts[2],
                "author": parts.count > 3 ? parts[3] : ""
            ])
        }

        let json = (try? JSONSerialization.data(withJSONObject: commits))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        await sendToClientOrRelay(
            WSPacket(action: .gitHistoryResult, payload: ["commits": json, "success": "true"], id: packet.id),
            to: clientId
        )
    }

    private func runGitCommand(_ args: [String], at path: String) async -> (success: Bool, output: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = args
                process.currentDirectoryURL = URL(fileURLWithPath: path)

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(returning: (process.terminationStatus == 0, output))
                } catch {
                    continuation.resume(returning: (false, error.localizedDescription))
                }
            }
        }
    }

    private func sendGitResult(action: WSAction, clientId: String, packetId: String, success: Bool, data: [String: String]? = nil, error: String? = nil) async {
        var payload = data ?? [:]
        payload["success"] = success ? "true" : "false"
        if let err = error { payload["error"] = err }
        await sendToClientOrRelay(WSPacket(action: action, payload: payload, id: packetId), to: clientId)
    }

    private func handleGitFileDiff(clientId: String, packet: WSPacket) async {
        guard let path = packet.payload?["path"],
              let file = packet.payload?["file"] else { return }
        let expandedPath = (path as NSString).expandingTildeInPath

        // Try unstaged diff first
        let result = await runGitCommand(["diff", "-U3", "--", file], at: expandedPath)
        if !result.output.isEmpty {
            await sendToClientOrRelay(
                WSPacket(action: .gitFileDiffResult, payload: [
                    "file": file, "diff": String(result.output.prefix(100000)), "success": "true"
                ], id: packet.id), to: clientId)
            return
        }

        // Try staged diff
        let staged = await runGitCommand(["diff", "--cached", "-U3", "--", file], at: expandedPath)
        if !staged.output.isEmpty {
            await sendToClientOrRelay(
                WSPacket(action: .gitFileDiffResult, payload: [
                    "file": file, "diff": String(staged.output.prefix(100000)), "success": "true"
                ], id: packet.id), to: clientId)
            return
        }

        // Untracked or new file — show entire content as added
        let fullPath = "\(expandedPath)/\(file)"
        if let content = try? String(contentsOfFile: fullPath, encoding: .utf8) {
            let lines = content.components(separatedBy: "\n")
            let fakeDiff = lines.map { "+\($0)" }.joined(separator: "\n")
            await sendToClientOrRelay(
                WSPacket(action: .gitFileDiffResult, payload: [
                    "file": file,
                    "diff": "@@ -0,0 +1,\(lines.count) @@\n\(String(fakeDiff.prefix(100000)))",
                    "success": "true"
                ], id: packet.id), to: clientId)
        } else {
            // Binary or unreadable
            await sendToClientOrRelay(
                WSPacket(action: .gitFileDiffResult, payload: [
                    "file": file, "diff": "@@ Binary file @@", "success": "true"
                ], id: packet.id), to: clientId)
        }
    }

    private func handleGitBranches(clientId: String, packet: WSPacket) async {
        guard let path = packet.payload?["path"] else { return }
        let expandedPath = (path as NSString).expandingTildeInPath

        let current = await runGitCommand(["rev-parse", "--abbrev-ref", "HEAD"], at: expandedPath)
        let local = await runGitCommand(["branch", "--format=%(refname:short)"], at: expandedPath)
        let remote = await runGitCommand(["branch", "-r", "--format=%(refname:short)"], at: expandedPath)

        let localBranches = local.output.components(separatedBy: "\n").filter { !$0.isEmpty }
        let remoteBranches = remote.output.components(separatedBy: "\n")
            .filter { !$0.isEmpty && !$0.contains("HEAD") }
            .map { $0.replacingOccurrences(of: "origin/", with: "") }

        // Deduplicate
        var allBranches = localBranches
        for rb in remoteBranches {
            if !allBranches.contains(rb) { allBranches.append(rb) }
        }

        let json = (try? JSONSerialization.data(withJSONObject: allBranches))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        await sendToClientOrRelay(
            WSPacket(action: .gitBranchesResult, payload: [
                "current": current.output,
                "branches": json,
                "success": "true"
            ], id: packet.id),
            to: clientId
        )
    }

    private func handleGitCheckout(clientId: String, packet: WSPacket) async {
        guard let path = packet.payload?["path"],
              let branch = packet.payload?["branch"] else { return }
        let expandedPath = (path as NSString).expandingTildeInPath

        let result = await runGitCommand(["checkout", branch], at: expandedPath)

        await sendGitResult(action: .gitCheckoutResult, clientId: clientId, packetId: packet.id,
                           success: result.success,
                           data: ["branch": branch],
                           error: result.success ? nil : result.output)
    }

    private func handleGitPull(clientId: String, packet: WSPacket) async {
        guard let path = packet.payload?["path"] else { return }
        let expandedPath = (path as NSString).expandingTildeInPath

        let result = await runGitCommand(["pull"], at: expandedPath)

        await sendGitResult(action: .gitPullResult, clientId: clientId, packetId: packet.id,
                           success: result.success,
                           data: ["output": result.output],
                           error: result.success ? nil : result.output)
    }

    // MARK: - File Explorer

    private func handleFileTree(clientId: String, packet: WSPacket) async {
        guard let path = packet.payload?["path"] else {
            log("fileTree: missing path")
            return
        }
        let expandedPath = (path as NSString).expandingTildeInPath
        log("fileTree: scanning \(expandedPath)")

        // Scan using FileManager (no external process, no sandbox issues)
        let allFiles: [String] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                let ignoredDirs: Set<String> = [".git", "node_modules", ".next", "build", ".build",
                                                 ".expo", "__pycache__", ".swiftpm", "DerivedData",
                                                 ".cache", "dist", "Pods", ".gradle", "venv", ".venv"]
                var files: [String] = []
                let baseURL = URL(fileURLWithPath: expandedPath)

                guard let enumerator = fm.enumerator(
                    at: baseURL,
                    includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                    options: []
                ) else {
                    continuation.resume(returning: [])
                    return
                }

                for case let url as URL in enumerator {
                    let name = url.lastPathComponent
                    if ignoredDirs.contains(name) {
                        enumerator.skipDescendants()
                        continue
                    }
                    let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if !isDir {
                        let relativePath = url.path.replacingOccurrences(of: expandedPath + "/", with: "")
                        files.append(relativePath)
                    }
                }
                continuation.resume(returning: files.sorted())
            }
        }

        log("fileTree: found \(allFiles.count) files")

        // Build tree structure
        var tree: [[String: Any]] = []
        var dirs = Set<String>()

        for file in allFiles {
            let components = file.components(separatedBy: "/")
            // Add directory entries
            var dirPath = ""
            for i in 0..<(components.count - 1) {
                dirPath += (dirPath.isEmpty ? "" : "/") + components[i]
                if !dirs.contains(dirPath) {
                    dirs.insert(dirPath)
                    tree.append([
                        "name": components[i],
                        "path": dirPath,
                        "type": "dir",
                        "depth": i
                    ])
                }
            }
            // Add file entry
            let ext = (file as NSString).pathExtension
            tree.append([
                "name": components.last ?? file,
                "path": file,
                "type": "file",
                "ext": ext,
                "depth": components.count - 1
            ])
        }

        let json = (try? JSONSerialization.data(withJSONObject: tree))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        log("fileTree: found \(tree.count) entries, json size=\(json.count) bytes")

        await sendToClientOrRelay(
            WSPacket(action: .fileTreeResult, payload: [
                "tree": json,
                "success": "true"
            ], id: packet.id),
            to: clientId
        )
    }

    private func handleFileRead(clientId: String, packet: WSPacket) async {
        guard let basePath = packet.payload?["path"],
              let filePath = packet.payload?["file"] else { return }
        let expandedBase = (basePath as NSString).expandingTildeInPath
        let fullPath = "\(expandedBase)/\(filePath)"

        guard FileManager.default.fileExists(atPath: fullPath) else {
            await sendToClientOrRelay(
                WSPacket(action: .fileReadResult, payload: ["success": "false", "error": "File not found"], id: packet.id),
                to: clientId
            )
            return
        }

        do {
            let content = try String(contentsOfFile: fullPath, encoding: .utf8)
            let ext = (filePath as NSString).pathExtension
            let lang = languageFromExtension(ext)

            await sendToClientOrRelay(
                WSPacket(action: .fileReadResult, payload: [
                    "content": String(content.prefix(500000)),
                    "language": lang,
                    "file": filePath,
                    "success": "true"
                ], id: packet.id),
                to: clientId
            )
        } catch {
            await sendToClientOrRelay(
                WSPacket(action: .fileReadResult, payload: ["success": "false", "error": "Binary or unreadable file"], id: packet.id),
                to: clientId
            )
        }
    }

    private func languageFromExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "swift": return "swift"
        case "js", "jsx": return "javascript"
        case "ts", "tsx": return "typescript"
        case "py": return "python"
        case "rb": return "ruby"
        case "go": return "go"
        case "rs": return "rust"
        case "java": return "java"
        case "kt": return "kotlin"
        case "c", "h": return "c"
        case "cpp", "cc", "cxx", "hpp": return "cpp"
        case "cs": return "csharp"
        case "json": return "json"
        case "yaml", "yml": return "yaml"
        case "toml": return "toml"
        case "xml", "plist": return "xml"
        case "html", "htm": return "html"
        case "css": return "css"
        case "scss", "sass": return "scss"
        case "md", "markdown": return "markdown"
        case "sh", "bash", "zsh": return "bash"
        case "sql": return "sql"
        case "dockerfile": return "dockerfile"
        case "graphql", "gql": return "graphql"
        default: return "text"
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task {
                await self?.updateMachineStatus("online")
            }
        }
    }
}

// MARK: - Dev Server Ready Detection

actor DevServerReadySignal {
    private(set) var isReady = false

    private static let readyPatterns: [String] = [
        "ready on",
        "ready in",
        "started server on",
        "listening on",
        "localhost:",
        "127.0.0.1:",
        "compiled successfully",
        "compiled client and server",
        "webpack compiled",
        "vite",
        "Local:",
        "Network:",
        "➜",
        "started at",
        "running at",
    ]

    func check(_ output: String) {
        guard !isReady else { return }
        let lower = output.lowercased()
        for pattern in Self.readyPatterns {
            if lower.contains(pattern.lowercased()) {
                isReady = true
                return
            }
        }
    }
}
