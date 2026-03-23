import Foundation
import TarsyShared
import Supabase

@MainActor
class DaemonManager: ObservableObject {
    @Published var isRunning = false
    @Published var activeWorkspaces: [Workspace] = []
    @Published var connectedClients = 0
    @Published var tailscaleStatus: String = "checking..."
    @Published var tailscaleIP: String?
    @Published var machineId: UUID?

    private var wsServer: WebSocketServer?
    private let tailscale = TailscaleManager()
    private let terminalManager = TerminalSessionManager()
    private var orchestrator: WorkspaceOrchestrator?
    private let screenCapture = ScreenCaptureService()
    private var mjpegServer: MJPEGStreamServer?
    private var heartbeatTimer: Timer?

    func start() async {
        // 0. Init orchestrator
        orchestrator = WorkspaceOrchestrator(terminalManager: terminalManager)

        // 1. Check/install Tailscale
        await setupTailscale()

        // 2. Start WebSocket server
        await startWSServer()

        // 3. Register machine in Supabase
        await registerMachine()

        // 4. Start heartbeat
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

    private func setupTailscale() async {
        let status = await tailscale.checkStatus()
        switch status {
        case .notInstalled:
            tailscaleStatus = "installing..."
            do {
                try await tailscale.install()
                tailscaleStatus = "installed - please open Tailscale app and sign in"
            } catch {
                tailscaleStatus = "install failed: \(error.localizedDescription)"
            }
        case .installed:
            tailscaleStatus = "installed - not running"
        case .running(let ip):
            tailscaleIP = ip
            tailscaleStatus = "connected (\(ip))"
        case .error(let msg):
            tailscaleStatus = "error: \(msg)"
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

    // MARK: - Packet Handling

    private func handlePacket(clientId: String, packet: WSPacket) async {
        switch packet.action {
        case .workspaceList:
            await handleWorkspaceList(clientId: clientId, packet: packet)
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
        case .claudeMessage:
            await handleClaudeMessage(clientId: clientId, packet: packet)
        case .claudeClose:
            await handleClaudeClose(clientId: clientId, packet: packet)
        case .streamStart:
            await handleStreamStart(clientId: clientId, packet: packet)
        case .streamStop:
            await handleStreamStop(clientId: clientId, packet: packet)
        default:
            await wsServer?.send(
                WSPacket(action: .error, payload: ["message": "Unknown action: \(packet.action.rawValue)"]),
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
            await wsServer?.send(
                WSPacket(action: .workspaceCreate, payload: [
                    "sessionId": result?.sessionId ?? "",
                    "stack": result?.detectedStack ?? "unknown",
                    "devCommand": result?.detectedDevCommand ?? "",
                    "status": "ready"
                ], id: packet.id),
                to: clientId
            )
        } catch {
            await wsServer?.send(
                WSPacket(action: .error, payload: ["message": error.localizedDescription], id: packet.id),
                to: clientId
            )
        }
    }

    private func handleWorkspaceList(clientId: String, packet: WSPacket) async {
        let sessions = await terminalManager.listSessions()
        await wsServer?.send(
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

            await wsServer?.send(
                WSPacket(action: .workspaceStart, payload: ["sessionId": sessionId, "status": "running"], id: packet.id),
                to: clientId
            )
        } catch {
            await wsServer?.send(
                WSPacket(action: .error, payload: ["message": error.localizedDescription], id: packet.id),
                to: clientId
            )
        }
    }

    private func handleWorkspaceStop(clientId: String, packet: WSPacket) async {
        guard let sessionId = packet.payload?["sessionId"] else { return }
        await terminalManager.closeSession(sessionId)
        await wsServer?.send(
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
            await wsServer?.send(
                WSPacket(action: .terminalCreate, payload: ["sessionId": sessionId], id: packet.id),
                to: clientId
            )
        } catch {
            await wsServer?.send(
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
        await wsServer?.send(
            WSPacket(action: .terminalClose, payload: ["sessionId": sessionId], id: packet.id),
            to: clientId
        )
    }

    // MARK: - Claude Code

    private func handleClaudeCreate(clientId: String, packet: WSPacket) async {
        guard let path = packet.payload?["path"] else { return }
        let aiContext = packet.payload?["aiContext"]
        let sid = UUID().uuidString
        let workspaceName = path.components(separatedBy: "/").last ?? "workspace"

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
                }
            )

            await wsServer?.send(
                WSPacket(action: .claudeCreate, payload: ["sessionId": sid], id: packet.id),
                to: clientId
            )
        } catch {
            await wsServer?.send(
                WSPacket(action: .error, payload: ["message": error.localizedDescription], id: packet.id),
                to: clientId
            )
        }
    }

    private func handleClaudeMessage(clientId: String, packet: WSPacket) async {
        guard let sessionId = packet.payload?["sessionId"],
              let message = packet.payload?["message"] else { return }
        await terminalManager.sendClaudeMessage(message, to: sessionId)
    }

    private func handleClaudeClose(clientId: String, packet: WSPacket) async {
        guard let sessionId = packet.payload?["sessionId"] else { return }
        await terminalManager.closeClaudeSession(sessionId)
        await wsServer?.send(
            WSPacket(action: .claudeClose, payload: ["sessionId": sessionId], id: packet.id),
            to: clientId
        )
    }

    // MARK: - Stream

    private func handleStreamStart(clientId: String, packet: WSPacket) async {
        let stack = packet.payload?["stack"] ?? "web"

        // Find the right window for this stack
        guard let window = await screenCapture.findWindow(forStack: stack) else {
            await wsServer?.send(
                WSPacket(action: .error, payload: ["message": "No matching window found for stack: \(stack)"], id: packet.id),
                to: clientId
            )
            return
        }

        do {
            // Start MJPEG server if not running
            if mjpegServer == nil {
                mjpegServer = MJPEGStreamServer()
                try await mjpegServer?.start()
            }

            // Wire screen capture to MJPEG
            screenCapture.onFrame = { [weak self] cgImage in
                Task {
                    await self?.mjpegServer?.sendFrame(cgImage)
                }
            }

            try await screenCapture.startCapture(window: window, fps: 10, scale: 0.5)

            let streamPort: UInt16 = 8643
            await wsServer?.send(
                WSPacket(action: .streamStart, payload: [
                    "port": "\(streamPort)",
                    "window": window.title ?? "unknown",
                    "width": "\(Int(window.frame.width))",
                    "height": "\(Int(window.frame.height))"
                ], id: packet.id),
                to: clientId
            )
        } catch {
            await wsServer?.send(
                WSPacket(action: .error, payload: ["message": "Stream failed: \(error.localizedDescription)"], id: packet.id),
                to: clientId
            )
        }
    }

    private func handleStreamStop(clientId: String, packet: WSPacket) async {
        await screenCapture.stopCapture()
        await mjpegServer?.stop()
        mjpegServer = nil

        await wsServer?.send(
            WSPacket(action: .streamStop, id: packet.id),
            to: clientId
        )
    }

    // MARK: - Machine Registration

    private func registerMachine() async {
        guard let ip = tailscaleIP else { return }
        let hostname = Host.current().localizedName ?? ProcessInfo.processInfo.hostName

        do {
            let session = try await supabase.auth.session

            // Check if machine already registered
            let existing: [Machine] = try await supabase
                .from("machines")
                .select()
                .eq("user_id", value: session.user.id.uuidString)
                .execute()
                .value

            if let machine = existing.first {
                // Update existing
                machineId = machine.id
                try await supabase
                    .from("machines")
                    .update(["tailscale_ip": ip, "hostname": hostname, "status": "online", "last_seen_at": ISO8601DateFormatter().string(from: Date())])
                    .eq("id", value: machine.id.uuidString)
                    .execute()
            } else {
                // Create new
                let result: Machine = try await supabase
                    .from("machines")
                    .insert(["user_id": session.user.id.uuidString, "hostname": hostname, "tailscale_ip": ip, "status": "online"])
                    .select()
                    .single()
                    .execute()
                    .value
                machineId = result.id
            }
        } catch {
            print("[Daemon] Failed to register machine: \(error)")
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

    private func startHeartbeat() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task {
                await self?.updateMachineStatus("online")
            }
        }
    }
}
