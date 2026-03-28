import Foundation
import os
import TarsyShared
import Supabase
import AppKit
import IOKit.pwr_mgt

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
    private var h264Encoder: H264Encoder?
    private let openClaw = OpenClawService()
    private let remoteInput = RemoteInputService()
    private let relayClient = RelayClient()
    private var heartbeatTimer: Timer?
    private var devServerSessions: [String: String] = [:] // workspacePath -> terminalSessionId
    private var devServerDetectedPorts: [String: Int] = [:] // workspacePath -> detected port
    private var displaySleepAssertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var systemSleepAssertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var lastActiveClientId: String = "relay"
    private var detectedAgents: [AIEngineType] = []
    private let agentTaskService = AgentTaskService()
    private var sessionTaskMap: [String: UUID] = [:] // sessionId -> agentTask.id
    let profileService = ProfileService()

    func start() async {
        // 0. Init orchestrator
        orchestrator = WorkspaceOrchestrator(terminalManager: terminalManager)

        // Wire up sudo password manager to send requests to iOS
        SudoPasswordManager.shared.sendPacket = { [weak self] packet in
            guard let self else { return }
            await self.sendToClientOrRelay(packet, to: self.lastActiveClientId)
        }

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

        preventSleep()

        // 6. Load user profile
        await profileService.loadProfile()
        log("Profile loaded: \(profileService.profile?.nameOrEmail ?? "none")")

        // 7. Detect installed AI agents
        detectedAgents = AgentDetector.detectInstalledAgents()
        log("Detected agents: \(detectedAgents.map(\.rawValue))")

        // Broadcast to any clients that connected before detection finished
        if !detectedAgents.isEmpty {
            log("Broadcasting agentsDetected to all clients: \(detectedAgents.map(\.rawValue))")
            let agentsPacket = WSPacket(
                action: .agentsDetected,
                payload: ["agents": detectedAgents.map(\.rawValue).joined(separator: ",")]
            )
            await wsServer?.broadcast(agentsPacket)
            await relayClient.send(packet: agentsPacket)
        } else {
            log("No agents detected, nothing to broadcast")
        }

        // 8. UltraContext — watch Claude Code session files + sync via proxy
        Task { await SessionFileWatcher.shared.start() }
        log("UltraContext session watcher started")

        isRunning = true
    }

    func stop() {
        allowSleep()
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        Task {
            await wsServer?.stop()
            await updateMachineStatus("offline")
        }
        isRunning = false
    }

    // MARK: - Sleep Prevention

    private func preventSleep() {
        let reason = "Tarsy is streaming the screen to remote clients" as CFString

        // Prevent display from sleeping on idle
        let displayResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &displaySleepAssertionID
        )

        // Prevent system sleep even with lid closed (requires power adapter)
        let systemResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &systemSleepAssertionID
        )

        if displayResult == kIOReturnSuccess && systemResult == kIOReturnSuccess {
            log("Sleep prevention enabled (display + system/lid-close)")
        } else {
            log("Sleep prevention partial — display: \(displayResult), system: \(systemResult)")
        }
    }

    private func allowSleep() {
        if displaySleepAssertionID != 0 {
            IOPMAssertionRelease(displaySleepAssertionID)
            displaySleepAssertionID = IOPMAssertionID(0)
        }
        if systemSleepAssertionID != 0 {
            IOPMAssertionRelease(systemSleepAssertionID)
            systemSleepAssertionID = IOPMAssertionID(0)
        }
        log("Sleep prevention disabled")
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
            onConnect: { [weak self] clientId in
                Task { @MainActor in
                    self?.connectedClients += 1
                    // Send detected agents to the newly connected client
                    let agents = self?.detectedAgents ?? []
                    print("[Daemon] onConnect \(clientId): detectedAgents=\(agents.map(\.rawValue))")
                    if !agents.isEmpty {
                        let packet = WSPacket(
                            action: .agentsDetected,
                            payload: ["agents": agents.map(\.rawValue).joined(separator: ",")]
                        )
                        await self?.sendToClientOrRelay(packet, to: clientId)
                        print("[Daemon] Sent agentsDetected to \(clientId)")
                    } else {
                        print("[Daemon] No agents detected yet, skipping send to \(clientId)")
                    }
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
            _ = try await supabase.auth.user(jwt: token)
            return true
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
        lastActiveClientId = clientId
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
        case .browserBack:
            await sendBrowserShortcut(key: "[", modifiers: .maskCommand)
        case .browserForward:
            await sendBrowserShortcut(key: "]", modifiers: .maskCommand)
        case .browserRefresh:
            await sendBrowserShortcut(key: "r", modifiers: .maskCommand)
        case .browserMobileViewport:
            await handleBrowserMobileViewport(clientId: clientId, packet: packet)
        case .browserDesktopViewport:
            await handleBrowserDesktopViewport(clientId: clientId, packet: packet)
        case .browserTabList:
            await handleBrowserTabList(clientId: clientId, packet: packet)
        case .browserTabSwitch:
            await handleBrowserTabSwitch(clientId: clientId, packet: packet)
        case .browserTabClose:
            await handleBrowserTabClose(clientId: clientId, packet: packet)
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
        // HTTP Proxy
        case .proxyDetectPorts:
            await handleProxyDetectPorts(clientId: clientId, packet: packet)
        case .proxyRequest:
            await handleProxyRequest(clientId: clientId, packet: packet)
        // File Explorer
        case .fileTree:
            await handleFileTree(clientId: clientId, packet: packet)
        case .fileRead:
            await handleFileRead(clientId: clientId, packet: packet)
        // MCP Store
        case .mcpList:
            await handleMCPList(clientId: clientId, packet: packet)
        case .mcpHealthCheck:
            await handleMCPHealthCheck(clientId: clientId, packet: packet)
        // Sudo
        case .sudoRequest:
            await handleSudoRequest(clientId: clientId, packet: packet)
        case .sudoResponse:
            SudoPasswordManager.shared.handlePasswordResponse(packet: packet)
        // Repo Analysis
        case .repoAnalyze:
            await handleRepoAnalyze(clientId: clientId, packet: packet)
        // AI Project Wizard
        case .wizardStart:
            await handleWizardStart(clientId: clientId, packet: packet)
        case .wizardExecute:
            await handleWizardExecute(clientId: clientId, packet: packet)
        // UltraContext
        case .ultracontextStatus:
            await sendToClientOrRelay(
                WSPacket(action: .ultracontextStatus, payload: [
                    "installed": "true",
                    "status": "active"
                ], id: packet.id),
                to: clientId
            )
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
        var devCmd = packet.payload?["devCommand"]

        // If dev command needs sudo, ask for password before starting
        let expandedPath = (path as NSString).expandingTildeInPath
        if let cmd = devCmd {
            guard let rewritten = await SudoPasswordManager.shared.rewriteCommandIfSudo(cmd, workingDirectory: expandedPath) else {
                log("workspaceStart: sudo password cancelled")
                await sendToClientOrRelay(
                    WSPacket(action: .sudoResult, payload: ["status": "cancelled"], id: packet.id),
                    to: clientId
                )
                return
            }
            devCmd = rewritten
        }

        do {
            let sessionId = try await orchestrator?.coldStart(localPath: path, devServerCommand: devCmd) ?? ""
            await terminalManager.setOutputHandler(for: sessionId) { [weak self] output in
                Task {
                    await self?.detectSudoPromptInOutput(output, sessionId: sessionId)
                    await self?.sendToClientOrRelay(
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
                    // Detect sudo password prompts in terminal output
                    await self?.detectSudoPromptInOutput(output, sessionId: sessionId)
                    await self?.sendToClientOrRelay(
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

        // Intercept commands containing sudo — ask for password and rewrite with sudo -S
        guard let rewritten = await SudoPasswordManager.shared.rewriteCommandIfSudo(input) else {
            log("terminalInput: sudo password cancelled")
            await sendToClientOrRelay(
                WSPacket(action: .sudoResult, payload: ["sessionId": sessionId, "status": "cancelled"], id: packet.id),
                to: clientId
            )
            return
        }

        await terminalManager.sendInput(rewritten, to: sessionId)
    }

    private func handleTerminalClose(clientId: String, packet: WSPacket) async {
        guard let sessionId = packet.payload?["sessionId"] else { return }
        await terminalManager.closeSession(sessionId)
        await sendToClientOrRelay(
            WSPacket(action: .terminalClose, payload: ["sessionId": sessionId], id: packet.id),
            to: clientId
        )
    }

    // MARK: - Sudo

    private func handleSudoRequest(clientId: String, packet: WSPacket) async {
        guard let command = packet.payload?["command"] else {
            await sendToClientOrRelay(
                WSPacket(action: .error, payload: ["message": "Missing command for sudo"], id: packet.id),
                to: clientId
            )
            return
        }

        let reason = packet.payload?["reason"] ?? "Un comando requiere permisos de administrador:\nsudo \(command)"

        do {
            let (output, exitCode) = try await SudoPasswordManager.shared.runWithSudo(command, reason: reason)
            await sendToClientOrRelay(
                WSPacket(action: .sudoResult, payload: [
                    "output": String(output.prefix(4000)),
                    "exitCode": "\(exitCode)",
                    "status": exitCode == 0 ? "success" : "failed"
                ], id: packet.id),
                to: clientId
            )
        } catch SudoPasswordManager.SudoError.cancelled {
            await sendToClientOrRelay(
                WSPacket(action: .sudoResult, payload: ["status": "cancelled"], id: packet.id),
                to: clientId
            )
        } catch {
            await sendToClientOrRelay(
                WSPacket(action: .error, payload: ["message": "Sudo failed: \(error.localizedDescription)"], id: packet.id),
                to: clientId
            )
        }
    }

    /// Detects sudo password prompts in terminal output and shows the native dialog.
    func detectSudoPromptInOutput(_ output: String, sessionId: String) {
        Task { @MainActor in
            await SudoPasswordManager.shared.handleSudoPromptIfNeeded(
                output: output,
                sessionId: sessionId,
                sendInput: { [weak self] password in
                    await self?.terminalManager.sendInput(password, to: sessionId)
                }
            )
        }
    }

    // MARK: - Claude Code

    private func handleClaudeCreate(clientId: String, packet: WSPacket) async {
        guard let path = packet.payload?["path"] else {
            log("claudeCreate: missing path")
            return
        }
        let aiContext = packet.payload?["aiContext"]
        let initialMessage = packet.payload?["message"]
        let wsIdStr = packet.payload?["workspaceId"]
        let permissionMode: AgentPermissionConfig.PermissionMode = {
            if let raw = packet.payload?["permissionMode"],
               let mode = AgentPermissionConfig.PermissionMode(rawValue: raw) {
                return mode
            }
            if let profile = profileService.profile {
                return profile.permissionMode(for: .claude)
            }
            return .dangerous
        }()
        let sid = UUID().uuidString
        let workspaceName = path.components(separatedBy: "/").last ?? "workspace"

        log("claudeCreate: path=\(path), sid=\(sid), hasMessage=\(initialMessage != nil), permissionMode=\(permissionMode.rawValue)")

        do {
            let _ = try await terminalManager.createClaudeSession(
                id: sid,
                workspacePath: path,
                aiContext: aiContext,
                permissionMode: permissionMode,
                onOutput: { [weak self] output in
                    Task {
                        await self?.sendToClientOrRelay(
                            WSPacket(action: .claudeOutput, payload: ["sessionId": sid, "output": output]),
                            to: clientId
                        )
                    }
                },
                onComplete: { [weak self] (message: String) in
                    Task {
                        await self?.sendToClientOrRelay(
                            WSPacket(action: .claudeComplete, payload: ["sessionId": sid, "message": message]),
                            to: clientId
                        )
                        PushNotificationService.shared.notifyTaskComplete(
                            workspace: workspaceName,
                            summary: message,
                            workspaceId: wsIdStr
                        )
                    }
                },
                onAskUser: { [weak self] (questionsJson: String, _: [String]) in
                    Task {
                        // questionsJson is already a JSON string of the full questions array
                        await self?.sendToClientOrRelay(
                            WSPacket(action: .claudeAskUser, payload: [
                                "sessionId": sid,
                                "questions": questionsJson
                            ]),
                            to: clientId
                        )
                        PushNotificationService.shared.notifyAgentQuestion(
                            workspace: workspaceName,
                            question: questionsJson,
                            workspaceId: wsIdStr
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
            let responseAccumulator = OSAllocatedUnfairLock(initialState: "")
            try await openClaw.sendMessage(message, agentId: agentId) { [weak self] chunk in
                responseAccumulator.withLock { $0 += chunk }
                Task {
                    await self?.sendToClientOrRelay(
                        WSPacket(action: .openclawOutput, payload: ["output": chunk]),
                        to: clientId
                    )
                }
            }
            let fullResponse = responseAccumulator.withLock { $0 }
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

            // Monitor terminal output for server-ready signals and port detection
            let serverReady = DevServerReadySignal()
            await terminalManager.setOutputHandler(for: sessionId) { [weak self] output in
                guard let strongSelf = self else { return }
                Task {
                    let wasReady = await serverReady.isReady
                    await serverReady.check(output)
                    await strongSelf.detectSudoPromptInOutput(output, sessionId: sessionId)
                    await MainActor.run { strongSelf.log("devServer[\(sessionId.prefix(8))]: \(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))") }

                    // Detect port from output and notify iOS
                    if !wasReady, await serverReady.isReady {
                        let detectedPort = strongSelf.extractPort(from: output)
                        if let port = detectedPort {
                            await MainActor.run { strongSelf.devServerDetectedPorts[expandedPath] = port }
                            await strongSelf.sendToClientOrRelay(
                                WSPacket(action: .devServerStart, payload: [
                                    "status": "ready",
                                    "port": "\(port)",
                                    "sessionId": sessionId
                                ]),
                                to: clientId
                            )
                        }
                    }
                }
            }

            // If command needs sudo (check package.json scripts too), ask for password before sending
            var needsSudo = false
            guard let rewrittenCmd = await SudoPasswordManager.shared.rewriteCommandIfSudo(command, workingDirectory: expandedPath) else {
                log("devServerStart: sudo password cancelled")
                await sendToClientOrRelay(
                    WSPacket(action: .sudoResult, payload: ["status": "cancelled"], id: packet.id),
                    to: clientId
                )
                return
            }
            needsSudo = (rewrittenCmd != command)

            // Source shell config + common version managers to ensure PATH has npm/node/pnpm/etc.
            let cmdName = command.components(separatedBy: " ").first ?? command
            let fullCommand = "echo \"[DEBUG] HOME=$HOME\"; echo \"[DEBUG] PATH=$PATH\"; ls -la $HOME/.nvm/nvm.sh 2>&1; export NVM_DIR=\"$HOME/.nvm\"; [ -s \"$NVM_DIR/nvm.sh\" ] && . \"$NVM_DIR/nvm.sh\" && echo \"[DEBUG] nvm loaded\" || echo \"[DEBUG] nvm.sh not found or failed\"; echo \"[DEBUG] PATH after nvm=$PATH\"; which \(cmdName) 2>&1; \(rewrittenCmd)"

            await terminalManager.sendInput(fullCommand, to: sessionId)
            log("devServerStart: running '\(command)' in \(expandedPath)\(needsSudo ? " (with sudo)" : "")")

            // Wait for actual confirmation: either output-based or port-based
            // Give more time if sudo is involved (user might need to enter password via fallback)
            let targetPort = portFromUrl(streamUrl)
            let timeout: Int = needsSudo ? 30 : 15
            let confirmed = await waitForDevServer(signal: serverReady, port: targetPort, timeout: timeout)

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
            devServerDetectedPorts.removeValue(forKey: expandedPath)
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

        var statusPayload: [String: String] = ["running": running ? "true" : "false"]
        // Include the port so the iOS client can auto-connect when switching modes
        if running, let port = portFromUrl(streamUrl) {
            statusPayload["port"] = "\(port)"
        } else if running, let _ = devServerSessions[expandedPath] {
            // Try to find the port from detected dev server output
            if let detected = devServerDetectedPorts[expandedPath] {
                statusPayload["port"] = "\(detected)"
            }
        }

        await sendToClientOrRelay(
            WSPacket(action: .devServerStatus, payload: statusPayload, id: packet.id),
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

    private func sendBrowserShortcut(key: String, modifiers: CGEventFlags) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                // Get the key code
                let keyCode: UInt16
                switch key {
                case "[": keyCode = 0x21
                case "]": keyCode = 0x1E
                case "r": keyCode = 0x0F
                default: keyCode = 0x00
                }

                if let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
                   let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
                    keyDown.flags = modifiers
                    keyUp.flags = modifiers
                    keyDown.post(tap: .cghidEventTap)
                    keyUp.post(tap: .cghidEventTap)
                }
                continuation.resume()
            }
        }
    }

    private var mobileViewportWindow: NSRunningApplication?
    private var originalWindowId: CGWindowID?

    private var savedDesktopWindowId: CGWindowID?

    private func handleBrowserMobileViewport(clientId: String, packet: WSPacket) async {
        log("browserMobileViewport: opening mobile window")

        // Save current window for later restoration
        savedDesktopWindowId = screenCapture.selectedWindow?.windowID

        // Open a new Chrome window with mobile size using CLI (no AppleScript permissions needed)
        let mobileWidth = 430
        let mobileHeight = 932
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                proc.arguments = ["-na", "Google Chrome", "--args",
                                  "--new-window",
                                  "--window-size=\(mobileWidth),\(mobileHeight)",
                                  "--window-position=50,50",
                                  "about:blank"]
                proc.standardOutput = Pipe()
                proc.standardError = Pipe()
                try? proc.run()
                proc.waitUntilExit()
                continuation.resume()
            }
        }

        // Wait for window to open
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        // Capture the smallest Chrome window (the new mobile one)
        if let window = await screenCapture.findWindow(appName: "Google Chrome", preferSmall: true) {
            await screenCapture.startCapturing(window: window, fps: 15, scale: 1.0)
            log("browserMobileViewport: capturing mobile window (\(Int(window.frame.width))x\(Int(window.frame.height)))")
        } else {
            log("browserMobileViewport: could not find mobile window")
        }

        await sendToClientOrRelay(
            WSPacket(action: .browserMobileViewport, payload: ["status": "opened"], id: packet.id),
            to: clientId
        )
    }

    private func handleBrowserDesktopViewport(clientId: String, packet: WSPacket) async {
        log("browserDesktopViewport: restoring desktop window")

        // Find and close the small mobile window using CGWindowList
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                // Use keyboard shortcut Cmd+W to close current (mobile) window
                if let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x0D, keyDown: true),
                   let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x0D, keyDown: false) {
                    keyDown.flags = .maskCommand
                    keyUp.flags = .maskCommand
                    keyDown.post(tap: .cghidEventTap)
                    keyUp.post(tap: .cghidEventTap)
                }
                continuation.resume()
            }
        }

        try? await Task.sleep(nanoseconds: 500_000_000)

        // Re-capture the main (large) desktop window
        if let window = await screenCapture.findWindow(appName: "Google Chrome", preferSmall: false) {
            await screenCapture.startCapturing(window: window, fps: 15, scale: 1.0)
            log("browserDesktopViewport: capturing desktop window (\(Int(window.frame.width))x\(Int(window.frame.height)))")
        } else {
            log("browserDesktopViewport: could not find desktop window")
        }

        await sendToClientOrRelay(
            WSPacket(action: .browserDesktopViewport, payload: ["status": "restored"], id: packet.id),
            to: clientId
        )
    }

    private func handleBrowserTabList(clientId: String, packet: WSPacket) async {
        // Get tab count
        let countScript = """
        tell application "Google Chrome"
            return (count of tabs of front window) as text
        end tell
        """
        let countStr = await runAppleScript(countScript)
        let tabCount = Int(countStr.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        log("browserTabList: \(tabCount) tabs")

        guard tabCount > 0 else {
            await sendToClientOrRelay(
                WSPacket(action: .browserTabListResult, payload: ["tabs": ""], id: packet.id),
                to: clientId
            )
            return
        }

        // Get each tab individually to avoid concatenation issues
        var entries: [String] = []
        for i in 1...tabCount {
            let titleScript = """
            tell application "Google Chrome"
                return title of tab \(i) of front window
            end tell
            """
            let urlScript = """
            tell application "Google Chrome"
                return URL of tab \(i) of front window
            end tell
            """
            let title = await runAppleScript(titleScript)
            let url = await runAppleScript(urlScript)
            let host = URL(string: url)?.host ?? ""
            let favicon = host.isEmpty ? "" : "https://www.google.com/s2/favicons?sz=32&domain=\(host)"
            entries.append("\(i)||\(title)||\(url)||\(favicon)")
        }

        let tabsPayload = entries.joined(separator: "\n")
        log("browserTabList: payload \(tabsPayload.prefix(200))")
        await sendToClientOrRelay(
            WSPacket(action: .browserTabListResult, payload: ["tabs": tabsPayload], id: packet.id),
            to: clientId
        )
    }

    private func handleBrowserTabSwitch(clientId: String, packet: WSPacket) async {
        guard let indexStr = packet.payload?["index"], let index = Int(indexStr) else { return }
        let script = """
        tell application "Google Chrome"
            set active tab index of front window to \(index)
        end tell
        """
        await runAppleScript(script)
        // Re-capture the window after tab switch
        try? await Task.sleep(nanoseconds: 300_000_000)
        if let window = await screenCapture.findWindow(appName: "Google Chrome", preferSmall: false) {
            await screenCapture.startCapturing(window: window, fps: 15, scale: 1.0)
        }
    }

    private func handleBrowserTabClose(clientId: String, packet: WSPacket) async {
        guard let indexStr = packet.payload?["index"], let index = Int(indexStr) else { return }
        let script = """
        tell application "Google Chrome"
            close tab \(index) of front window
        end tell
        """
        await runAppleScript(script)
    }

    @discardableResult
    private func runAppleScript(_ source: String) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var error: NSDictionary?
                let script = NSAppleScript(source: source)
                let result = script?.executeAndReturnError(&error)
                if let error {
                    Task { @MainActor in
                        self?.log("AppleScript error: \(error)")
                    }
                }
                continuation.resume(returning: result?.stringValue ?? "")
            }
        }
    }

    // MARK: - Dev Server Helpers

    private func openBrowserToUrl(_ urlString: String) async {
        guard let url = URL(string: urlString) else { return }
        log("openBrowserToUrl: opening \(urlString)")
        NSWorkspace.shared.open(url)
    }

    private nonisolated func extractPort(from output: String) -> Int? {
        // Match patterns like "localhost:3000", "127.0.0.1:5173", ":8080", "port 3000"
        let patterns = [
            "localhost:(\\d{4,5})",
            "127\\.0\\.0\\.1:(\\d{4,5})",
            "0\\.0\\.0\\.0:(\\d{4,5})",
            "\\[::\\]:(\\d{4,5})",
            "port\\s+(\\d{4,5})",
            ":(\\d{4,5})"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
               let range = Range(match.range(at: 1), in: output) {
                return Int(output[range])
            }
        }
        return nil
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
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

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
        let stack = packet.payload?["stack"] ?? "mobile"

        // For web/fullstack: capture from current stream frame
        if stack == "web" || stack == "fullstack" {
            log("screenshot: capturing browser window")
            if let window = screenCapture.selectedWindow {
                let image = CGWindowListCreateImage(
                    window.frame,
                    .optionIncludingWindow,
                    window.windowID,
                    [.boundsIgnoreFraming, .bestResolution]
                )
                if let image {
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    let isRelay = clientId == "relay"
                    let quality: NSNumber = isRelay ? 0.5 : 0.7
                    if let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]) {
                        let sizeKB = jpegData.count / 1024
                        log("screenshot: captured \(sizeKB)KB JPEG from browser")

                        if isRelay {
                            var binaryData = Data("SCRN".utf8)
                            binaryData.append(jpegData)
                            await relayClient.sendBinary(binaryData)
                        } else {
                            let base64 = jpegData.base64EncodedString()
                            await sendToClientOrRelay(
                                WSPacket(action: .screenshotResult, payload: ["data": base64, "size": "\(sizeKB)"], id: packet.id),
                                to: clientId
                            )
                        }
                        return
                    }
                }
            }
            log("screenshot: browser capture failed, falling back to simctl")
        }

        // Mobile: use simctl
        let udid = packet.payload?["udid"] ?? "booted"
        let tmpPath = NSTemporaryDirectory() + "tarsy_screenshot_\(UUID().uuidString).png"

        log("screenshot: capturing simulator \(udid)")

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
        let isOpenClaw = packet.payload?["workspaceType"] == "openclaw"

        // Handle quality change for existing stream (H.264: force keyframe on quality change)
        if quality != nil, screenCapture.isCapturing {
            h264Encoder?.forceKeyframe()
            log("streamStart: quality change — forced keyframe")
            return
        }

        log("streamStart: stack=\(stack), openClaw=\(isOpenClaw), streamUrl=\(streamUrl ?? "nil")")

        // H.264 hardware encoding for ALL connections (LAN + relay)
        let ipPayload = packet.payload?["ip"] ?? ""
        let isLocalConnection = !ipPayload.isEmpty && !ipPayload.hasPrefix("100.")
        let isRelay = clientId == "relay"

        let fps: Int
        let scale: CGFloat
        let bitrate: Int

        if isLocalConnection && !isRelay {
            fps = 30
            scale = 1.0
            bitrate = 6_000_000
        } else {
            fps = 20
            scale = 0.75
            bitrate = 2_000_000
        }

        do {
            // Start MJPEG server if not running
            if mjpegServer == nil {
                mjpegServer = MJPEGStreamServer()
                try await mjpegServer?.start()
                log("streamStart: MJPEG server started on port 8643")
            }

            // OpenClaw: capture entire display
            if isOpenClaw {
                await screenCapture.requestPermission()

                // Get display dimensions for encoder
                let displayWidth = Int(CGFloat(NSScreen.main?.frame.width ?? 1920) * scale)
                let displayHeight = Int(CGFloat(NSScreen.main?.frame.height ?? 1080) * scale)

                let encoder = H264Encoder()
                encoder.configure(width: displayWidth, height: displayHeight, fps: fps, bitrate: bitrate)
                self.h264Encoder = encoder

                setupEncoderFrameRelay(encoder: encoder, isRelay: isRelay, clientId: clientId)

                screenCapture.onFrame = nil
                screenCapture.onPixelBuffer = { [weak encoder] pixelBuffer in
                    encoder?.encode(pixelBuffer)
                }

                log("streamStart: OpenClaw full-display (\(fps)fps, \(displayWidth)x\(displayHeight), \(bitrate/1000)kbps)")

                try await screenCapture.startDisplayCapture(fps: fps, scale: scale)

                // For full-display, remote input targets the entire screen
                let mainScreen = NSScreen.main
                remoteInput.setTargetWindow(
                    frame: mainScreen?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080),
                    windowId: 0,
                    pid: 0,
                    isSimulator: false,
                    appName: "Desktop"
                )

                await sendToClientOrRelay(
                    WSPacket(action: .streamStart, payload: [
                        "window": "Full Desktop",
                        "width": "\(Int(mainScreen?.frame.width ?? 1920))",
                        "height": "\(Int(mainScreen?.frame.height ?? 1080))",
                        "codec": "h264",
                        "fullscreen": "true"
                    ], id: packet.id),
                    to: clientId
                )
                log("streamStart: OpenClaw full-display capture started")
                return
            }

            // Standard workspace: window capture
            // If a streamUrl is provided, open the browser to that URL first
            if let urlString = streamUrl, !urlString.isEmpty {
                await openBrowserToUrl(urlString)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }

            var window = await screenCapture.findWindow(forStack: stack)

            if window == nil {
                log("streamStart: no window found, opening app for stack \(stack)")
                if let urlString = streamUrl, !urlString.isEmpty {
                    await openBrowserToUrl(urlString)
                } else {
                    await openAppForStack(stack)
                }
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

            let captureWidth = Int(window.frame.width * scale)
            let captureHeight = Int(window.frame.height * scale)
            let encoder = H264Encoder()
            encoder.configure(width: captureWidth, height: captureHeight, fps: fps, bitrate: bitrate)
            self.h264Encoder = encoder

            setupEncoderFrameRelay(encoder: encoder, isRelay: isRelay, clientId: clientId)

            screenCapture.onFrame = nil
            screenCapture.onPixelBuffer = { [weak encoder] pixelBuffer in
                encoder?.encode(pixelBuffer)
            }

            log("streamStart: \(isRelay ? "relay" : "LAN") (\(fps)fps, \(captureWidth)x\(captureHeight), \(bitrate/1000)kbps)")

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

            await sendToClientOrRelay(
                WSPacket(action: .streamStart, payload: [
                    "window": window.title ?? "unknown",
                    "width": "\(Int(window.frame.width))",
                    "height": "\(Int(window.frame.height))",
                    "codec": "h264"
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

    /// Shared helper to wire H.264 encoder frame delivery to relay/LAN
    private func setupEncoderFrameRelay(encoder: H264Encoder, isRelay: Bool, clientId: String) {
        let relay = self.relayClient
        let wsServer = self.wsServer
        let sendInFlight = OSAllocatedUnfairLock(initialState: false)
        encoder.onEncodedFrame = { [weak encoder] encodedData in
            var prefixedData = Data("H264".utf8)
            prefixedData.append(encodedData)

            if isRelay {
                let alreadyInFlight = sendInFlight.withLock { val -> Bool in
                    if val { return true }
                    val = true
                    return false
                }
                guard !alreadyInFlight else {
                    encoder?.reportFrameDropped()
                    return
                }
                Task { [weak encoder] in
                    let enc = encoder
                    await relay.sendBinary(prefixedData) {
                        sendInFlight.withLock { $0 = false }
                        enc?.reportFrameDelivered()
                    }
                }
            } else {
                encoder?.reportFrameDelivered()
                Task {
                    await wsServer?.broadcastBinary(prefixedData)
                }
            }
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
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func handleStreamStop(clientId: String, packet: WSPacket) async {
        await screenCapture.stopCapture()
        screenCapture.onPixelBuffer = nil
        await mjpegServer?.stop()
        mjpegServer = nil
        h264Encoder?.stop()
        h264Encoder = nil

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
        let hwUuid = getHardwareUUID()

        log("registerMachine: tailscaleIP=\(tailscaleIP ?? "nil"), localIP=\(localIp ?? "nil"), hwUuid=\(hwUuid ?? "nil")")

        guard tailscaleIP != nil || localIp != nil else {
            log("registerMachine: skipped — no IPs available")
            lastError = "No IPs available to register"
            return
        }

        do {
            let session = try await supabase.auth.session
            log("registerMachine: got session for user \(session.user.id)")

            // Fetch all machines for this user
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
            if let hw = hwUuid { updateData["hardware_uuid"] = hw }

            // Match by hardware_uuid first (unique per Mac), then fall back to first machine
            let matched = existing.first(where: { $0.hardwareUuid == hwUuid && hwUuid != nil })
                ?? (existing.count == 1 ? existing.first : nil)

            if let machine = matched {
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

    /// Returns the Mac's unique hardware UUID from IOKit
    private func getHardwareUUID() -> String? {
        let platformExpert = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard platformExpert != 0 else { return nil }
        defer { IOObjectRelease(platformExpert) }

        let uuidCF = IORegistryEntryCreateCFProperty(platformExpert, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)
        return uuidCF?.takeRetainedValue() as? String
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
        let wsIdStr = packet.payload?["workspaceId"]
        let permissionMode: AgentPermissionConfig.PermissionMode = {
            if let raw = packet.payload?["permissionMode"],
               let mode = AgentPermissionConfig.PermissionMode(rawValue: raw) {
                return mode
            }
            // Fallback to profile permissions
            if let profile = profileService.profile {
                return profile.permissionMode(for: engineType)
            }
            return .dangerous
        }()
        let sid = UUID().uuidString
        let workspaceName = path.components(separatedBy: "/").last ?? "workspace"

        log("engineCreate: type=\(engineType.displayName), path=\(path), sid=\(sid), permissionMode=\(permissionMode.rawValue)")

        // For Claude, use the existing rich session
        if engineType == .claude {
            do {
                let _ = try await terminalManager.createClaudeSession(
                    id: sid,
                    workspacePath: path,
                    aiContext: aiContext,
                    permissionMode: permissionMode,
                    onOutput: { [weak self] output in
                        Task {
                            await self?.sendToClientOrRelay(
                                WSPacket(action: .engineOutput, payload: ["sessionId": sid, "output": output, "engineType": "claude"]),
                                to: clientId
                            )
                            await UltraContextSync.shared.agentOutput(sessionId: sid, content: output)
                        }
                    },
                    onComplete: { [weak self] (message: String) in
                        Task {
                            await self?.sendToClientOrRelay(
                                WSPacket(action: .engineComplete, payload: ["sessionId": sid, "message": message, "engineType": "claude"]),
                                to: clientId
                            )
                            PushNotificationService.shared.notifyTaskComplete(
                                workspace: workspaceName,
                                summary: String(message.prefix(200)),
                                workspaceId: wsIdStr
                            )
                            if let taskId = await self?.sessionTaskMap[sid] {
                                await self?.agentTaskService.updateStatus(taskId, status: .completed)
                            }
                            await UltraContextSync.shared.engineCompleted(sessionId: sid, summary: message)
                        }
                    },
                    onAskUser: { [weak self] questionsJson, _ in
                        Task {
                            await self?.sendToClientOrRelay(
                                WSPacket(action: .engineAskUser, payload: ["sessionId": sid, "questions": questionsJson, "engineType": "claude"]),
                                to: clientId
                            )
                            PushNotificationService.shared.notifyAgentQuestion(
                                workspace: workspaceName,
                                question: questionsJson,
                                workspaceId: wsIdStr
                            )
                            if let taskId = await self?.sessionTaskMap[sid] {
                                await self?.agentTaskService.updateStatus(taskId, status: .waiting)
                            }
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

                await UltraContextSync.shared.engineStarted(sessionId: sid, engineType: "claude", workspacePath: path)

                if let msg = initialMessage, !msg.isEmpty {
                    let imagesJson = packet.payload?["images"]
                    await terminalManager.sendClaudeMessage(msg, images: imagesJson, to: sid)
                    await UltraContextSync.shared.userMessage(sessionId: sid, content: msg)

                    // Create persistent task
                    if let wsIdStr = packet.payload?["workspaceId"], let wsId = UUID(uuidString: wsIdStr) {
                        if let task = await agentTaskService.createTask(
                            workspaceId: wsId, tabId: packet.payload?["tabId"] ?? sid,
                            description: String(msg.prefix(200)), sessionId: sid, engineType: "claude"
                        ) {
                            sessionTaskMap[sid] = task.id
                        }
                    }
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
                permissionMode: permissionMode,
                onOutput: { [weak self] output in
                    Task {
                        await self?.sendToClientOrRelay(
                            WSPacket(action: .engineOutput, payload: ["sessionId": sid, "output": output, "engineType": engineTypeRaw]),
                            to: clientId
                        )
                        await UltraContextSync.shared.agentOutput(sessionId: sid, content: output)
                    }
                },
                onComplete: { [weak self] (message: String) in
                    Task {
                        await self?.sendToClientOrRelay(
                            WSPacket(action: .engineComplete, payload: ["sessionId": sid, "message": message, "engineType": engineTypeRaw]),
                            to: clientId
                        )
                        await UltraContextSync.shared.engineCompleted(sessionId: sid, summary: message)
                    }
                },
                onAskUser: { [weak self] questionsJson, _ in
                    Task {
                        await self?.sendToClientOrRelay(
                            WSPacket(action: .engineAskUser, payload: ["sessionId": sid, "questions": questionsJson, "engineType": engineTypeRaw]),
                            to: clientId
                        )
                    }
                }
            )

            await UltraContextSync.shared.engineStarted(sessionId: sid, engineType: engineTypeRaw, workspacePath: path)

            await sendToClientOrRelay(
                WSPacket(action: .engineCreate, payload: ["sessionId": sid, "engineType": engineTypeRaw], id: packet.id),
                to: clientId
            )

            if let msg = initialMessage, !msg.isEmpty {
                await terminalManager.sendEngineMessage(msg, to: sid)
                await UltraContextSync.shared.userMessage(sessionId: sid, content: msg)

                // Create persistent task for generic engines
                if let wsIdStr = packet.payload?["workspaceId"], let wsId = UUID(uuidString: wsIdStr) {
                    if let task = await agentTaskService.createTask(
                        workspaceId: wsId, tabId: packet.payload?["tabId"] ?? sid,
                        description: String(msg.prefix(200)), sessionId: sid, engineType: engineTypeRaw
                    ) {
                        sessionTaskMap[sid] = task.id
                    }
                }
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
        await UltraContextSync.shared.userMessage(sessionId: sessionId, content: message)
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

        // Update task status back to running
        if let taskId = sessionTaskMap[sessionId] {
            await agentTaskService.updateStatus(taskId, status: .running)
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

    // MARK: - Repo Analysis

    private func handleRepoAnalyze(clientId: String, packet: WSPacket) async {
        guard let path = packet.payload?["path"] else {
            log("repoAnalyze: missing path")
            return
        }

        let analyzer = RepoAnalyzer()
        let analysis = analyzer.analyze(at: path)

        if let json = try? analysis.encode() {
            await sendToClientOrRelay(
                WSPacket(action: .repoAnalysis, payload: ["analysis": json], id: packet.id),
                to: clientId
            )
        }
        log("repoAnalyze: \(path) → lang=\(analysis.language ?? "?"), fw=\(analysis.framework ?? "?"), cmd=\(analysis.suggestedCommand ?? "?")")
    }

    // MARK: - AI Project Wizard

    private func handleWizardStart(clientId: String, packet: WSPacket) async {
        guard let idea = packet.payload?["idea"],
              let systemPrompt = packet.payload?["systemPrompt"],
              let engineTypeRaw = packet.payload?["engineType"],
              let engineType = AIEngineType(rawValue: engineTypeRaw) else {
            log("wizardStart: missing required fields")
            return
        }

        log("wizardStart: engine=\(engineType.displayName), idea=\(idea.prefix(80))")

        // Detect gh CLI availability and notify iOS
        let ghAvailable = detectGhCLI()
        await sendToClientOrRelay(
            WSPacket(action: .wizardGhDetected, payload: ["available": ghAvailable ? "true" : "false"]),
            to: clientId
        )

        // Create a temporary session to get AI analysis
        let sid = "wizard-\(UUID().uuidString.prefix(8))"
        var fullResponse = ""

        let permissionMode: AgentPermissionConfig.PermissionMode = {
            if let profile = profileService.profile {
                return profile.permissionMode(for: engineType)
            }
            return .dangerous
        }()

        if engineType == .claude {
            do {
                let _ = try await terminalManager.createClaudeSession(
                    id: sid,
                    workspacePath: NSHomeDirectory(),
                    aiContext: systemPrompt,
                    permissionMode: permissionMode,
                    onOutput: { output in
                        fullResponse += output
                    },
                    onComplete: { [weak self] _ in
                        Task {
                            await self?.sendToClientOrRelay(
                                WSPacket(action: .wizardResponse, payload: ["response": fullResponse], id: packet.id),
                                to: clientId
                            )
                            await self?.terminalManager.closeClaudeSession(sid)
                        }
                    },
                    onAskUser: { [weak self] _, _ in
                        // If agent asks a question during wizard, just send what we have
                        Task {
                            await self?.sendToClientOrRelay(
                                WSPacket(action: .wizardResponse, payload: ["response": fullResponse], id: packet.id),
                                to: clientId
                            )
                            await self?.terminalManager.closeClaudeSession(sid)
                        }
                    }
                )

                await terminalManager.sendClaudeMessage(idea, images: nil, to: sid)
            } catch {
                log("wizardStart error: \(error)")
                await sendToClientOrRelay(
                    WSPacket(action: .wizardResponse, payload: ["response": "", "error": error.localizedDescription], id: packet.id),
                    to: clientId
                )
            }
        } else {
            // Generic engine
            do {
                let _ = try await terminalManager.createEngineSession(
                    id: sid,
                    engineType: engineType,
                    workspacePath: NSHomeDirectory(),
                    permissionMode: permissionMode,
                    onOutput: { output in
                        fullResponse += output
                    },
                    onComplete: { [weak self] _ in
                        Task {
                            await self?.sendToClientOrRelay(
                                WSPacket(action: .wizardResponse, payload: ["response": fullResponse], id: packet.id),
                                to: clientId
                            )
                            await self?.terminalManager.closeEngineSession(sid)
                        }
                    }
                )

                await terminalManager.sendEngineMessage(idea, to: sid)
            } catch {
                log("wizardStart error: \(error)")
                await sendToClientOrRelay(
                    WSPacket(action: .wizardResponse, payload: ["response": "", "error": error.localizedDescription], id: packet.id),
                    to: clientId
                )
            }
        }
    }

    private func handleWizardExecute(clientId: String, packet: WSPacket) async {
        guard let configJson = packet.payload?["config"],
              let engineTypeRaw = packet.payload?["engineType"],
              let machineIdStr = packet.payload?["machineId"] else {
            log("wizardExecute: missing required fields")
            await sendToClientOrRelay(
                WSPacket(action: .wizardResult, payload: ["success": "false", "error": "missing required fields"], id: packet.id),
                to: clientId
            )
            return
        }

        let createGitHub = packet.payload?["createGitHub"] == "true"
        let idea = packet.payload?["idea"] ?? ""

        do {
            let config = try ProjectWizardConfig.decode(from: configJson)
            let expandedPath = (config.suggestedPath as NSString).expandingTildeInPath

            log("wizardExecute: creating project '\(config.projectName)' at \(expandedPath)")

            // 1. Create directory
            try FileManager.default.createDirectory(atPath: expandedPath, withIntermediateDirectories: true)

            // 2. git init
            let gitInit = await runShellCommand("git init", at: expandedPath)
            log("wizardExecute: git init: \(gitInit.success ? "ok" : gitInit.output)")

            // 3. GitHub repo (optional)
            if createGitHub && detectGhCLI() {
                let ghCreate = await runShellCommand("gh repo create \(config.projectName) --private --source=. --remote=origin", at: expandedPath)
                log("wizardExecute: gh repo create: \(ghCreate.success ? "ok" : ghCreate.output)")
            }

            // 4. Create workspace in Supabase
            guard let session = try? await supabase.auth.session else {
                throw NSError(domain: "Tarsy", code: 1, userInfo: [NSLocalizedDescriptionKey: "No auth session"])
            }

            let workspace: Workspace = try await supabase
                .from("workspaces")
                .insert([
                    "user_id": session.user.id.uuidString,
                    "machine_id": machineIdStr,
                    "name": config.projectName,
                    "local_path": config.suggestedPath,
                    "stack": config.stack,
                    "ai_context": config.initialPrompt.isEmpty ? nil : config.initialPrompt
                ] as [String: String?])
                .select()
                .single()
                .execute()
                .value

            log("wizardExecute: workspace created: \(workspace.id)")

            // 5. Dispatch agent with initial prompt
            let scaffoldPrompt = config.initialPrompt.isEmpty
                ? "Create a \(config.framework) project with \(config.language). Project: \(config.projectDescription). Dependencies: \(config.dependencies.joined(separator: ", ")). Set up the project structure, install dependencies, and create initial files."
                : config.initialPrompt

            let engineType = AIEngineType(rawValue: engineTypeRaw) ?? .claude
            let sid = UUID().uuidString
            let workspaceName = config.projectName

            let permissionMode: AgentPermissionConfig.PermissionMode = {
                if let profile = profileService.profile {
                    return profile.permissionMode(for: engineType)
                }
                return .dangerous
            }()

            if engineType == .claude {
                let _ = try await terminalManager.createClaudeSession(
                    id: sid,
                    workspacePath: expandedPath,
                    aiContext: config.initialPrompt.isEmpty ? nil : config.initialPrompt,
                    permissionMode: permissionMode,
                    onOutput: { [weak self] output in
                        Task {
                            await self?.sendToClientOrRelay(
                                WSPacket(action: .engineOutput, payload: ["sessionId": sid, "output": output, "engineType": "claude"]),
                                to: clientId
                            )
                        }
                    },
                    onComplete: { [weak self] message in
                        Task {
                            await self?.sendToClientOrRelay(
                                WSPacket(action: .engineComplete, payload: ["sessionId": sid, "message": message, "engineType": "claude"]),
                                to: clientId
                            )
                            PushNotificationService.shared.notifyTaskComplete(
                                workspace: workspaceName,
                                summary: String(message.prefix(200)),
                                workspaceId: workspace.id.uuidString
                            )
                            if let taskId = await self?.sessionTaskMap[sid] {
                                await self?.agentTaskService.updateStatus(taskId, status: .completed)
                            }
                        }
                    },
                    onAskUser: { [weak self] questionsJson, _ in
                        Task {
                            await self?.sendToClientOrRelay(
                                WSPacket(action: .engineAskUser, payload: ["sessionId": sid, "questions": questionsJson, "engineType": "claude"]),
                                to: clientId
                            )
                            PushNotificationService.shared.notifyAgentQuestion(
                                workspace: workspaceName,
                                question: questionsJson,
                                workspaceId: workspace.id.uuidString
                            )
                            if let taskId = await self?.sessionTaskMap[sid] {
                                await self?.agentTaskService.updateStatus(taskId, status: .waiting)
                            }
                        }
                    }
                )

                await terminalManager.setClaudeStatusHandler(sessionId: sid) { [weak self] model, inputTokens, outputTokens in
                    Task {
                        await self?.sendToClientOrRelay(
                            WSPacket(action: .engineStatus, payload: [
                                "sessionId": sid, "model": model,
                                "inputTokens": "\(inputTokens)", "outputTokens": "\(outputTokens)"
                            ]),
                            to: clientId
                        )
                    }
                }

                // Send the scaffold prompt
                await terminalManager.sendClaudeMessage(scaffoldPrompt, images: nil, to: sid)

                // Create persistent task
                if let task = await agentTaskService.createTask(
                    workspaceId: workspace.id, tabId: "wizard-\(sid.prefix(8))",
                    description: String(scaffoldPrompt.prefix(200)), sessionId: sid, engineType: "claude"
                ) {
                    sessionTaskMap[sid] = task.id
                }
            } else {
                let _ = try await terminalManager.createEngineSession(
                    id: sid,
                    engineType: engineType,
                    workspacePath: expandedPath,
                    permissionMode: permissionMode,
                    onOutput: { [weak self] output in
                        Task {
                            await self?.sendToClientOrRelay(
                                WSPacket(action: .engineOutput, payload: ["sessionId": sid, "output": output, "engineType": engineTypeRaw]),
                                to: clientId
                            )
                        }
                    },
                    onComplete: { [weak self] message in
                        Task {
                            await self?.sendToClientOrRelay(
                                WSPacket(action: .engineComplete, payload: ["sessionId": sid, "message": message, "engineType": engineTypeRaw]),
                                to: clientId
                            )
                        }
                    }
                )

                await terminalManager.sendEngineMessage(scaffoldPrompt, to: sid)

                if let task = await agentTaskService.createTask(
                    workspaceId: workspace.id, tabId: "wizard-\(sid.prefix(8))",
                    description: String(scaffoldPrompt.prefix(200)), sessionId: sid, engineType: engineTypeRaw
                ) {
                    sessionTaskMap[sid] = task.id
                }
            }

            // Send the engine session info so iOS can track it
            await sendToClientOrRelay(
                WSPacket(action: .engineCreate, payload: [
                    "sessionId": sid,
                    "engineType": engineTypeRaw,
                    "workspaceId": workspace.id.uuidString
                ]),
                to: clientId
            )

            // Notify iOS of success
            await sendToClientOrRelay(
                WSPacket(action: .wizardResult, payload: ["success": "true", "workspaceId": workspace.id.uuidString], id: packet.id),
                to: clientId
            )

        } catch {
            log("wizardExecute error: \(error)")
            await sendToClientOrRelay(
                WSPacket(action: .wizardResult, payload: ["success": "false", "error": error.localizedDescription], id: packet.id),
                to: clientId
            )
        }
    }

    private func detectGhCLI() -> Bool {
        let paths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "\(NSHomeDirectory())/.local/bin/gh"]
        return paths.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func runShellCommand(_ command: String, at directory: String) async -> (success: Bool, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardOutput = pipe
        process.standardError = pipe
        process.environment = ProcessInfo.processInfo.environment

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus == 0, output)
        } catch {
            return (false, error.localizedDescription)
        }
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

    // MARK: - HTTP Proxy (WKWebView tunnel)

    private func handleProxyDetectPorts(clientId: String, packet: WSPacket) async {
        guard let path = packet.payload?["path"] else { return }
        let expandedPath = (path as NSString).expandingTildeInPath
        log("proxyDetectPorts: scanning for \(expandedPath)")

        let ports = await withCheckedContinuation { (continuation: CheckedContinuation<[[String: String]], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                // Get all listening TCP ports
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
                proc.arguments = ["-iTCP", "-sTCP:LISTEN", "-P", "-n", "-F", "pcn"]
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = Pipe()

                do {
                    try proc.run()
                    proc.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""

                    var results: [[String: String]] = []
                    var currentPid = ""
                    var currentName = ""

                    for line in output.components(separatedBy: "\n") {
                        if line.hasPrefix("p") {
                            currentPid = String(line.dropFirst())
                        } else if line.hasPrefix("c") {
                            currentName = String(line.dropFirst())
                        } else if line.hasPrefix("n") {
                            let addr = String(line.dropFirst())
                            // Extract port from addresses like *:3000 or 127.0.0.1:3000
                            if let colonIdx = addr.lastIndex(of: ":") {
                                let portStr = String(addr[addr.index(after: colonIdx)...])
                                if let port = Int(portStr), port >= 1024 && port < 65535 {
                                    // Check if process cwd matches workspace
                                    let cwdProc = Process()
                                    cwdProc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
                                    cwdProc.arguments = ["-p", currentPid, "-d", "cwd", "-F", "n"]
                                    let cwdPipe = Pipe()
                                    cwdProc.standardOutput = cwdPipe
                                    cwdProc.standardError = Pipe()
                                    try? cwdProc.run()
                                    cwdProc.waitUntilExit()
                                    let cwdData = cwdPipe.fileHandleForReading.readDataToEndOfFile()
                                    let cwdOutput = String(data: cwdData, encoding: .utf8) ?? ""

                                    let matchesWorkspace = cwdOutput.contains(expandedPath)
                                    let isDevServer = ["node", "next-server", "vite", "bun", "deno", "python", "ruby", "php"].contains(where: { currentName.lowercased().contains($0) })

                                    if matchesWorkspace && isDevServer {
                                        results.append([
                                            "port": "\(port)",
                                            "process": currentName,
                                            "pid": currentPid,
                                            "match": "workspace"
                                        ])
                                    }
                                }
                            }
                        }
                    }

                    // If no workspace matches, fallback: show dev servers on common ports
                    if results.isEmpty {
                        let commonPorts: Set<Int> = [3000, 3001, 4000, 4200, 5000, 5173, 5174, 8000, 8080, 8888]
                        // Re-scan but only for common dev ports
                        var currentPid2 = ""
                        var currentName2 = ""
                        for line in output.components(separatedBy: "\n") {
                            if line.hasPrefix("p") { currentPid2 = String(line.dropFirst()) }
                            else if line.hasPrefix("c") { currentName2 = String(line.dropFirst()) }
                            else if line.hasPrefix("n") {
                                let addr = String(line.dropFirst())
                                if let colonIdx = addr.lastIndex(of: ":") {
                                    let portStr = String(addr[addr.index(after: colonIdx)...])
                                    if let port = Int(portStr), commonPorts.contains(port) {
                                        let isDevServer = ["node", "next-server", "vite", "bun", "deno", "python", "ruby", "php"].contains(where: { currentName2.lowercased().contains($0) })
                                        if isDevServer {
                                            results.append([
                                                "port": "\(port)",
                                                "process": currentName2,
                                                "pid": currentPid2,
                                                "match": "global"
                                            ])
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Deduplicate by port
                    var seen = Set<String>()
                    let unique = results.filter { seen.insert($0["port"] ?? "").inserted }

                    let sorted = unique.sorted { a, b in
                        (Int(a["port"] ?? "0") ?? 0) < (Int(b["port"] ?? "0") ?? 0)
                    }

                    continuation.resume(returning: sorted)
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }

        let json = (try? JSONSerialization.data(withJSONObject: ports))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        log("proxyDetectPorts: found \(ports.count) ports")

        await sendToClientOrRelay(
            WSPacket(action: .proxyDetectPortsResult, payload: ["ports": json, "success": "true"], id: packet.id),
            to: clientId
        )
    }

    private func handleProxyRequest(clientId: String, packet: WSPacket) async {
        guard let urlString = packet.payload?["url"],
              let method = packet.payload?["method"],
              let requestId = packet.payload?["requestId"] else {
            log("proxyRequest: missing fields")
            return
        }
        log("proxyRequest: \(method) \(urlString)")

        guard let url = URL(string: urlString) else {
            await sendToClientOrRelay(
                WSPacket(action: .proxyResponse, payload: [
                    "requestId": requestId, "status": "0", "error": "Invalid URL"
                ], id: packet.id),
                to: clientId
            )
            return
        }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method

        // Forward headers
        if let headersJson = packet.payload?["headers"],
           let headersData = headersJson.data(using: .utf8),
           let headers = try? JSONSerialization.jsonObject(with: headersData) as? [String: String] {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        // Forward body
        if let body = packet.payload?["body"], !body.isEmpty {
            request.httpBody = Data(base64Encoded: body)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse

            // Get response headers
            var responseHeaders: [String: String] = [:]
            httpResponse?.allHeaderFields.forEach { key, value in
                responseHeaders["\(key)"] = "\(value)"
            }

            let headersJson = (try? JSONSerialization.data(withJSONObject: responseHeaders))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

            let bodyBase64 = data.base64EncodedString()
            log("proxyRequest: response \(httpResponse?.statusCode ?? 0), body \(data.count / 1024)KB")

            await sendToClientOrRelay(
                WSPacket(action: .proxyResponse, payload: [
                    "requestId": requestId,
                    "status": "\(httpResponse?.statusCode ?? 0)",
                    "headers": headersJson,
                    "body": bodyBase64
                ], id: packet.id),
                to: clientId
            )
        } catch {
            await sendToClientOrRelay(
                WSPacket(action: .proxyResponse, payload: [
                    "requestId": requestId, "status": "0", "error": error.localizedDescription
                ], id: packet.id),
                to: clientId
            )
        }
    }

    // MARK: - MCP Store

    private func handleMCPList(clientId: String, packet: WSPacket) async {
        let workspacePath = packet.payload?["path"]

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let claudeConfigPath = NSHomeDirectory() + "/.claude.json"
                guard let data = FileManager.default.contents(atPath: claudeConfigPath),
                      let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    Task {
                        await self?.sendToClientOrRelay(
                            WSPacket(action: .mcpListResult, payload: ["mcps": "[]", "success": "true"], id: packet.id),
                            to: clientId
                        )
                    }
                    continuation.resume()
                    return
                }

                var mcpEntries: [[String: String]] = []

                // Global MCPs
                if let globalMcps = config["mcpServers"] as? [String: Any] {
                    for (name, mcpConfig) in globalMcps {
                        let type = self?.mcpType(from: mcpConfig) ?? "unknown"
                        let command = self?.mcpCommand(from: mcpConfig) ?? ""
                        mcpEntries.append([
                            "name": name,
                            "scope": "global",
                            "type": type,
                            "command": command
                        ])
                    }
                }

                // Project-specific MCPs
                if let path = workspacePath,
                   let projects = config["projects"] as? [String: Any] {
                    let expandedPath = (path as NSString).expandingTildeInPath
                    if let projectConfig = projects[expandedPath] as? [String: Any],
                       let projectMcps = projectConfig["mcpServers"] as? [String: Any] {
                        for (name, mcpConfig) in projectMcps {
                            // Skip if already in global
                            if mcpEntries.contains(where: { $0["name"] == name }) { continue }
                            let type = self?.mcpType(from: mcpConfig) ?? "unknown"
                            let command = self?.mcpCommand(from: mcpConfig) ?? ""
                            mcpEntries.append([
                                "name": name,
                                "scope": "project",
                                "type": type,
                                "command": command
                            ])
                        }
                    }
                }

                let json = (try? JSONSerialization.data(withJSONObject: mcpEntries))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

                Task {
                    await self?.sendToClientOrRelay(
                        WSPacket(action: .mcpListResult, payload: ["mcps": json, "success": "true"], id: packet.id),
                        to: clientId
                    )
                }
                continuation.resume()
            }
        }
    }

    private func handleMCPHealthCheck(clientId: String, packet: WSPacket) async {
        guard let name = packet.payload?["name"],
              let type = packet.payload?["type"] else { return }

        var status = "unknown"

        if type == "http", let url = packet.payload?["command"] {
            // HTTP MCP — try to reach it
            if let url = URL(string: url) {
                let request = URLRequest(url: url, timeoutInterval: 5)
                do {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    if let http = response as? HTTPURLResponse, (200...499).contains(http.statusCode) {
                        status = "healthy"
                    } else {
                        status = "unreachable"
                    }
                } catch {
                    status = "unreachable"
                }
            }
        } else if type == "stdio" || type == "command" {
            // Stdio/command MCP — check if binary exists
            let command = packet.payload?["command"] ?? ""
            let binaryName = command.components(separatedBy: "/").last ?? command
            _ = await runGitCommand(["which", binaryName], at: NSHomeDirectory())
            // runGitCommand uses /usr/bin/git but we need /usr/bin/which — hack: use command directly
            let exists = FileManager.default.fileExists(atPath: command) ||
                         FileManager.default.fileExists(atPath: "/opt/homebrew/bin/\(binaryName)") ||
                         FileManager.default.fileExists(atPath: "/usr/local/bin/\(binaryName)") ||
                         binaryName == "npx" || binaryName == "docker" || binaryName == "node"
            status = exists ? "healthy" : "not_found"
        } else {
            status = "healthy" // Assume OK for unknown types
        }

        await sendToClientOrRelay(
            WSPacket(action: .mcpHealthResult, payload: [
                "name": name,
                "status": status,
                "success": "true"
            ], id: packet.id),
            to: clientId
        )
    }

    private nonisolated func mcpType(from config: Any) -> String {
        guard let dict = config as? [String: Any] else { return "unknown" }
        if let type = dict["type"] as? String { return type }
        if dict["command"] != nil { return "command" }
        if dict["url"] != nil { return "http" }
        return "unknown"
    }

    private nonisolated func mcpCommand(from config: Any) -> String {
        guard let dict = config as? [String: Any] else { return "" }
        if let url = dict["url"] as? String { return url }
        if let cmd = dict["command"] as? String {
            let args = (dict["args"] as? [String]) ?? []
            return ([cmd] + args).joined(separator: " ")
        }
        return ""
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
