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

    private func handleScanRepos(clientId: String, packet: WSPacket) async {
        let scanner = RepoScanner()
        let repos = await scanner.scan()

        // Encode repos as JSON string in payload
        if let data = try? JSONEncoder().encode(repos),
           let json = String(data: data, encoding: .utf8) {
            await wsServer?.send(
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
                onAskUser: { [weak self] (question: String, options: [String]) in
                    Task {
                        let optionsJson = (try? JSONSerialization.data(withJSONObject: options))
                            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                        await self?.wsServer?.send(
                            WSPacket(action: .claudeAskUser, payload: [
                                "sessionId": sid,
                                "question": question,
                                "options": optionsJson
                            ]),
                            to: clientId
                        )
                    }
                }
            )

            log("claudeCreate: session created, sending response")

            await wsServer?.send(
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
            await wsServer?.send(
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

    // MARK: - OpenClaw

    private func handleOpenClawStatus(clientId: String, packet: WSPacket) async {
        let running = await openClaw.checkGateway()
        await wsServer?.send(
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
                await wsServer?.send(
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
            await wsServer?.send(
                WSPacket(action: .openclawComplete, payload: ["message": fullResponse], id: packet.id),
                to: clientId
            )
        } catch {
            await wsServer?.send(
                WSPacket(action: .error, payload: ["message": "OpenClaw error: \(error.localizedDescription)"], id: packet.id),
                to: clientId
            )
        }
    }

    // MARK: - Stream

    private func handleStreamStart(clientId: String, packet: WSPacket) async {
        let stack = packet.payload?["stack"] ?? "web"
        log("streamStart: looking for window with stack=\(stack)")

        // Find the right window for this stack
        var window = await screenCapture.findWindow(forStack: stack)

        // If no window found, open the default app for this stack and retry
        if window == nil {
            log("streamStart: no window found, opening app for stack \(stack)")
            await openAppForStack(stack)
            // Wait for app to launch
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            window = await screenCapture.findWindow(forStack: stack)
        }

        guard let window else {
            log("streamStart: still no window found after opening app")
            await wsServer?.send(
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

            // Wire screen capture to MJPEG
            screenCapture.onFrame = { [weak self] cgImage in
                Task {
                    await self?.mjpegServer?.sendFrame(cgImage)
                }
            }

            try await screenCapture.startCapture(window: window, fps: 3, scale: 0.35)
            log("streamStart: capture started")

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
            log("streamStart: response sent to client")
        } catch {
            log("streamStart: FAILED — \(error)")
            await wsServer?.send(
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

        await wsServer?.send(
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

    private func startHeartbeat() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task {
                await self?.updateMachineStatus("online")
            }
        }
    }
}
