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
    private var registeredWorkspacePaths: Set<String> = []
    private var connectedClients = 0
    @Published var machineId: UUID?
    @Published var lastError: String?
    private var ownerUserId: UUID?
    @Published var debugLog: String = ""

    private var wsServer: WebSocketServer?
    private let terminalManager = TerminalSessionManager()
    private var orchestrator: WorkspaceOrchestrator?
    private let screenCapture = ScreenCaptureService()
    private var h264Encoder: H264Encoder?
    private let openClaw = OpenClawService()
    private let remoteInput = RemoteInputService()
    private let relayClient = RelayClient()
    private var heartbeatTimer: Timer?
    private var tokenRefreshTimer: Timer?
    private var tokenRetryTask: Task<Void, Never>?
    private var sleepObserver: Any?
    private var wakeObserver: Any?
    private var isReconnectingRelay = false
    private var portMonitor: PortMonitorService!
    private var displaySleepAssertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var systemSleepAssertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var lastActiveClientId: String = "relay"
    private var cachedAuthToken: String?
    private var detectedAgents: [AIEngineType] = []
    private var detectedSlashCommands: [[String: String]] = []
    private let e2e = E2ECrypto()       // LAN E2E
    private let relayE2E = E2ECrypto() // Relay E2E (separate key pair)
    /// Safety net: detects unexpected system-level modal dialogs
    /// (TCC / Automation / Keychain) and surfaces them on iOS so the
    /// remote user can approve them without being at the Mac.
    private let systemDialogDetector = SystemDialogDetector()
    /// The most recent dialog we've emitted `systemDialogDetected` for.
    /// Used so that a freshly-connected iOS client can be brought up to
    /// speed with an in-flight dialog on (re)connect.
    private var lastSystemDialog: SystemDialogDetector.Dialog?
    /// Live permission state watchdog. Surfaces revocations as push
    /// notifications and broadcasts transitions to connected clients
    /// so the iOS Permission Doctor UI stays in sync with reality.
    private let permissionMonitor = PermissionMonitor()

    private let agentTaskService = AgentTaskService()
    private var sessionTaskMap: [String: UUID] = [:] // sessionId -> agentTask.id
    /// Last terminal-state packet per session (engineComplete, engineAskUser).
    /// Re-sent to clients on reconnect so they can sync missed state transitions.
    private var sessionLastEvent: [String: WSPacket] = [:]
    /// Codex approval type cache: "sessionId:requestId" -> approvalType
    private var codexApprovalTypeCache: [String: String] = [:]
    /// Tracks last client activity (ping/packet) to detect dead connections and stop streaming
    private var lastClientActivity: Date?
    private var clientActivityTimer: Timer?

    // MARK: - Live Activity Push State
    private var lastLAPushTime: [String: Date] = [:]          // sessionId -> last push sent time
    private var previousCPUTicks: (user: Double, system: Double, idle: Double, nice: Double)?
    private var sessionStartTimes: [String: Double] = [:]     // sessionId -> Unix timestamp
    private var sessionContextPercent: [String: Double] = [:]  // sessionId -> context %
    private var sessionWorkspaceId: [String: String] = [:]     // sessionId -> workspaceId string
    private let laPushThrottle: TimeInterval = 4.0             // max 1 push per 4 seconds

    let profileService = ProfileService()
    private var machineSecret: String?
    /// Phase 3: P-256 keypair identity for signed-timestamp relay auth.
    /// Created lazily on first relay connect; key material lives in Secure
    /// Enclave (or Keychain fallback). Never logged.
    private var machineKeyStore: MachineKeyStore?

    // MARK: - Machine Secret Keychain

    private static let machineSecretService = "com.tarsy.macos.machine-secret"

    private func loadMachineSecret() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.machineSecretService,
            kSecAttrAccount as String: "machine-secret",
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func saveMachineSecret(_ secret: String) {
        guard let data = secret.data(using: .utf8) else { return }
        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.machineSecretService,
            kSecAttrAccount as String: "machine-secret"
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        // Add new
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.machineSecretService,
            kSecAttrAccount as String: "machine-secret",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private var isStarting = false

    func start() async {
        guard !isStarting && !isRunning else { return }
        isStarting = true
        defer { isStarting = false }

        // 0. Init orchestrator
        orchestrator = WorkspaceOrchestrator(terminalManager: terminalManager)

        // 0b. Init port monitor
        portMonitor = PortMonitorService(
            terminalManager: terminalManager,
            sendPacket: { [weak self] packet, clientId in
                guard let self else { return }
                await self.sendToClientOrRelay(packet, to: clientId)
            },
            log: { [weak self] msg in
                Task { @MainActor in self?.log(msg) }
            },
            detectSudoPrompt: { [weak self] output, sessionId in
                guard let self else { return }
                await MainActor.run { self.detectSudoPromptInOutput(output, sessionId: sessionId) }
            },
            rewriteSudoCommand: { command, workingDirectory in
                await SudoPasswordManager.shared.rewriteCommandIfSudo(command, workingDirectory: workingDirectory)
            }
        )

        // Wire up sudo password manager to send requests to iOS
        await SudoPasswordManager.shared.setSendPacket { [weak self] packet in
            guard let self else { return }
            await self.sendToClientOrRelay(packet, to: self.lastActiveClientId)
        }

        // 1. Start WebSocket server
        await startWSServer()

        // 2. Register machine in Supabase
        await registerMachine()

        // Cache auth token for sync shutdown
        if let token = try? await supabase.auth.session.accessToken {
            cachedAuthToken = token
        }

        // 3. Connect to relay for remote access
        await connectRelay()

        // 4. Start heartbeat + token refresh + sleep/wake monitoring
        startHeartbeat()
        startTokenRefresh()
        observeSleepWake()

        preventSleep()

        // 6. Load user profile
        await profileService.loadProfile()
        log("Profile loaded: \(profileService.profile?.nameOrEmail ?? "none")")

        // 7. Detect installed AI agents
        detectedAgents = AgentDetector.detectInstalledAgents()
        log("Detected agents: \(detectedAgents.map(\.rawValue))")

        // Broadcast to any clients that connected before detection finished
        let agentsPacket = WSPacket(
            action: .agentsDetected,
            payload: ["agents": detectedAgents.map(\.rawValue).joined(separator: ",")]
        )
        await wsServer?.broadcast(agentsPacket)
        await relayClient.send(packet: agentsPacket)

        // 7b. Slash commands are scanned and sent per-workspace in handleEngineCreate

        // 8. UltraContext — watch Claude Code session files + sync via proxy
        Task { await SessionFileWatcher.shared.start() }
        log("UltraContext session watcher started")

        // 9. System dialog safety net — AX-polls for unexpected TCC /
        // Automation / Keychain prompts and forwards them to iOS so the
        // user can approve them remotely.
        systemDialogDetector.onDialogAppeared = { [weak self] dialog in
            guard let self else { return }
            self.lastSystemDialog = dialog
            Task { await self.broadcastSystemDialogAppeared(dialog) }
        }
        systemDialogDetector.onDialogDismissed = { [weak self] dialogId in
            guard let self else { return }
            if self.lastSystemDialog?.id == dialogId {
                self.lastSystemDialog = nil
            }
            Task { await self.broadcastSystemDialogDismissed(dialogId) }
        }
        systemDialogDetector.start()
        log("System dialog detector started")

        // 10. Permission doctor watchdog — detects silent revocation
        // of Screen Recording / Accessibility / Automation / FDA
        // (e.g., after a macOS update or user mistake) and surfaces
        // it as a push notification + iOS banner before the user
        // discovers something is broken.
        permissionMonitor.onChange = { [weak self] previous, current in
            guard let self else { return }
            Task { await self.broadcastPermissionsStatus(current) }
            if let prev = previous {
                self.handlePermissionTransition(from: prev, to: current)
            }
        }
        permissionMonitor.start()
        log("Permission monitor started")

        isRunning = true
    }

    // MARK: - Permission doctor broadcast / handling

    private func broadcastPermissionsStatus(_ perms: TarsyPermissions) async {
        let packet = WSPacket(action: .permissionsStatus, payload: perms.payload)
        await wsServer?.broadcast(packet)
        await relayClient.send(packet: packet)
    }

    /// Compare previous vs. current permission state and surface a
    /// push notification when any permission flipped green → red.
    /// Multiple simultaneous revocations are merged into a single
    /// notification so we don't spam the user's lock screen.
    private func handlePermissionTransition(
        from prev: TarsyPermissions, to curr: TarsyPermissions
    ) {
        var lost: [String] = []
        if prev.screenRecording && !curr.screenRecording {
            lost.append("Screen Recording")
        }
        if prev.accessibility && !curr.accessibility {
            lost.append("Accessibility")
        }
        if prev.automation && !curr.automation {
            lost.append("Automation")
        }
        if prev.fullDiskAccess && !curr.fullDiskAccess {
            lost.append("Full Disk Access")
        }
        guard !lost.isEmpty else { return }
        let list = lost.joined(separator: ", ")
        log("Permission revoked: \(list)")
        PushNotificationService.shared.sendLocalNotification(
            title: "Tarsy permission revoked",
            body: "\(list) was disabled. Tarsy can't function remotely without it — re-enable in System Settings."
        )
        // Also fire the APNs path for a truly-suspended iOS app.
        Task { @MainActor in
            PushNotificationService.shared.notifySystemDialog(
                title: "\(list) was disabled",
                owner: "com.tarsy.macos"
            )
        }
    }

    // MARK: - System dialog broadcast / handling

    /// Broadcast a newly-detected dialog to every connected iOS client
    /// (LAN + relay). Payload is JSON-encoded because `WSPacket.payload`
    /// is a flat `[String: String]` — we stuff the button array into a
    /// single key as an encoded JSON string.
    private func broadcastSystemDialogAppeared(_ dialog: SystemDialogDetector.Dialog) async {
        var payload: [String: String] = [
            "id": dialog.id,
            "owner": dialog.owner,
            "title": dialog.title,
            "body": dialog.body,
            "remotelyActionable": dialog.remotelyActionable ? "true" : "false",
        ]
        if let buttonsData = try? JSONEncoder().encode(dialog.buttons),
           let buttonsJSON = String(data: buttonsData, encoding: .utf8) {
            payload["buttons"] = buttonsJSON
        }
        let packet = WSPacket(action: .systemDialogDetected, payload: payload)
        await wsServer?.broadcast(packet)
        await relayClient.send(packet: packet)
        // Also fire an APNs push so a truly-suspended iOS app wakes
        // up and nudges the user. The foreground/recent-background
        // cases are handled on the iOS side by the websocket packet
        // handler's local-notification fallback.
        PushNotificationService.shared.notifySystemDialog(
            title: dialog.title, owner: dialog.owner)
    }

    private func broadcastSystemDialogDismissed(_ dialogId: String) async {
        let packet = WSPacket(
            action: .systemDialogDismissed, payload: ["id": dialogId])
        await wsServer?.broadcast(packet)
        await relayClient.send(packet: packet)
    }

    /// Handle an iOS-initiated click on a remotely-actionable dialog.
    /// The detector re-scans live before clicking so stale AX refs
    /// can't misfire.
    private func handleSystemDialogClick(_ packet: WSPacket) async {
        guard let id = packet.payload?["id"],
              let label = packet.payload?["label"] else {
            return
        }
        let didClick = systemDialogDetector.clickButton(inDialog: id, label: label)
        if didClick {
            log("system dialog: clicked '\(label)' on dialog \(id)")
        } else {
            log("system dialog: click '\(label)' on \(id) — dialog not found or not actionable")
        }
    }

    func stop() {
        allowSleep()
        removeSleepWakeObservers()
        systemDialogDetector.stop()
        permissionMonitor.stop()
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        tokenRefreshTimer?.invalidate()
        tokenRefreshTimer = nil
        tokenRetryTask?.cancel()
        tokenRetryTask = nil
        Task {
            await portMonitor?.shutdownAll()
            await updateMachineStatus("offline")
            await relayClient.disconnect()
            await wsServer?.stop()
        }
        isRunning = false
    }

    /// Synchronous offline update for app termination — runs on a background queue
    /// to avoid deadlocking the main thread with a semaphore.
    nonisolated func markOfflineSync() {
        // Capture values we need off the main actor
        let id: UUID?
        let token: String?
        if Thread.isMainThread {
            id = MainActor.assumeIsolated { self.machineId }
            token = MainActor.assumeIsolated { self.cachedAuthToken }
        } else {
            // Fallback — should not happen in normal flow
            return
        }

        guard let id, let token else { return }

        let baseURL = TarsyConfig.supabaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(baseURL)/rest/v1/machines?id=eq.\(id.uuidString)") else { return }

        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(TarsyConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let body: [String: String] = [
            "status": "offline",
            "last_seen_at": ISO8601DateFormatter().string(from: Date())
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        // Use a dedicated session with delegateQueue on a background queue
        // to avoid deadlocking the main thread
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        let bgQueue = OperationQueue()
        bgQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: nil, delegateQueue: bgQueue)

        let semaphore = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { _, _, _ in
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 3)
        session.invalidateAndCancel()
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
                    self?.lastActiveClientId = clientId
                    // Send detected agents to the newly connected client
                    let agents = self?.detectedAgents ?? []
                    let packet = WSPacket(
                        action: .agentsDetected,
                        payload: ["agents": agents.map(\.rawValue).joined(separator: ",")]
                    )
                    await self?.sendToClientOrRelay(packet, to: clientId)
                    // Send OpenClaw availability
                    let openclawInstalled = await self?.openClaw.isInstalled() ?? false
                    await self?.sendToClientOrRelay(
                        WSPacket(action: .openclawStatus, payload: [
                            "installed": openclawInstalled ? "true" : "false",
                            "running": "false"
                        ]),
                        to: clientId
                    )
                }
            },
            onDisconnect: { [weak self] clientId in
                Task { @MainActor in
                    self?.connectedClients = max(0, (self?.connectedClients ?? 1) - 1)
                    if self?.lastActiveClientId == clientId {
                        self?.lastActiveClientId = "relay"
                    }
                    // Stop stream when last LAN client disconnects
                    if (self?.connectedClients ?? 0) == 0 && self?.h264Encoder != nil {
                        self?.log("Last LAN client disconnected — stopping stream")
                        await self?.stopStreamCleanup()
                    }
                }
            },
            onAuthSuccess: { [weak self] authPacket in
                // E2E key exchange: extract client's public key and return ours
                var extra: [String: String] = [:]
                if let clientKey = authPacket.payload?["e2ePublicKey"], !clientKey.isEmpty {
                    if self?.e2e.completeKeyExchange(remotePublicKeyBase64: clientKey) == true {
                        let ourKey = self?.e2e.publicKeyBase64 ?? ""
                        extra["e2ePublicKey"] = ourKey

                        // Sign our E2E public key with the TLS private key to bind it to our identity.
                        // iOS can verify this signature against the pinned TLS certificate fingerprint,
                        // preventing a compromised relay from performing a MITM on the key exchange.
                        if let keyData = ourKey.data(using: .utf8),
                           let signature = TLSCertificateManager.shared.sign(keyData) {
                            extra["e2eKeySignature"] = signature.base64EncodedString()
                            // Also send the cert so iOS can extract the public key for verification
                            if let certDER = TLSCertificateManager.shared.certificateDER() {
                                extra["tlsCertificate"] = certDER.base64EncodedString()
                            }
                        }

                    }
                }
                return extra
            },
            onActivity: { [weak self] in
                Task { @MainActor in
                    self?.lastClientActivity = Date()
                }
            }
        )

        do {
            try await wsServer?.start()
        } catch {
            log("Failed to start WS server: \(error.localizedDescription)")
        }
    }

    private func validateAuthToken(_ token: String) async -> Bool {
        do {
            let user = try await supabase.auth.user(jwt: token)
            // Verify the connecting user owns this machine
            guard let ownerId = ownerUserId else {
                return false
            }
            guard user.id == ownerId else {
                return false
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Relay

    private func connectRelay() async {
        // Get auth token for relay connection
        guard let session = try? await supabase.auth.session else {
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
            },
            onConnectionStateChanged: { [weak self] connected, attempt in
                Task { @MainActor in
                    if connected {
                        self?.log("Relay connected")
                        // Send detected agents to relay clients (mirrors LAN onConnect behavior)
                        let agents = self?.detectedAgents ?? []
                        let agentPacket = WSPacket(
                            action: .agentsDetected,
                            payload: ["agents": agents.map(\.rawValue).joined(separator: ",")]
                        )
                        await self?.sendToClientOrRelay(agentPacket, to: "relay")
                        // Send OpenClaw availability
                        let openclawInstalled = await self?.openClaw.isInstalled() ?? false
                        await self?.sendToClientOrRelay(
                            WSPacket(action: .openclawStatus, payload: [
                                "installed": openclawInstalled ? "true" : "false",
                                "running": "false"
                            ]),
                            to: "relay"
                        )
                    } else if attempt > 0 {
                        self?.log("Relay disconnected — reconnecting (attempt \(attempt))")
                    } else {
                        self?.log("Relay disconnected — reconnecting automatically")
                    }
                }
            }
        )

        // Phase 3: build the keypair-based identity (signed timestamp) if we
        // have one. The relay supports both this and the legacy machineSecret
        // at the same time; both are sent and the relay picks the signature
        // path when `signature` is present.
        let identity: MachineAuthIdentity?
        if let store = machineKeyStore, let mId = machineId {
            let pub = store.publicKeyDER
            identity = MachineAuthIdentity(
                machineId: mId.uuidString.lowercased(),
                userId: session.user.id.uuidString.lowercased(),
                publicKeyDER: pub,
                signer: { [weak store] message in
                    guard let store else {
                        throw NSError(domain: "DaemonManager", code: -1,
                                      userInfo: [NSLocalizedDescriptionKey: "key store deallocated"])
                    }
                    return try await store.sign(message: message)
                }
            )
        } else {
            identity = nil
        }

        await relayClient.connect(
            token: session.accessToken,
            machineSecret: machineSecret,
            machineIdentity: identity
        )
        log("Connected to relay for remote access (identity: \(identity == nil ? "legacy-only" : "signed"))")
    }

    // Forward response to relay when clientId is "relay"
    func sendToClientOrRelay(_ packet: WSPacket, to clientId: String) async {
        if clientId == "relay" {
            // Encrypt text packets for relay transit (E2E — relay can't read)
            if relayE2E.isReady {
                do {
                    let jsonData = try packet.encode()
                    if let encrypted = relayE2E.encryptBinary(jsonData) {
                        let envelope = WSPacket(
                            action: .e2eEncrypted,
                            payload: ["data": encrypted.base64EncodedString()],
                            id: packet.id
                        )
                        await relayClient.send(packet: envelope)
                        return
                    }
                } catch {}
            }
            await relayClient.send(packet: packet)
        } else {
            // LAN: TLS protects the channel, no E2E needed for text
            await wsServer?.send(packet, to: clientId)
        }
    }

    // MARK: - Live Activity Push

    /// Send a throttled Live Activity push update via APNs (max 1 per laPushThrottle seconds).
    /// Bypasses throttle for "end" and "waiting" events.
    private func sendLAPush(
        sessionId: String,
        status: String,
        toolName: String,
        toolIcon: String,
        message: String? = nil,
        event: String = "update",
        alert: [String: String]? = nil
    ) {
        // Capture all state values NOW before any cleanup can delete them
        guard let wsId = sessionWorkspaceId[sessionId] else { return }
        let startedAt = sessionStartTimes[sessionId] ?? Date().timeIntervalSince1970
        let contextPct = sessionContextPercent[sessionId] ?? 0

        let now = Date()
        if event == "update", status != "waiting",
           let last = lastLAPushTime[sessionId],
           now.timeIntervalSince(last) < laPushThrottle {
            return
        }
        lastLAPushTime[sessionId] = now

        var contentState: [String: Any] = [
            "status": status,
            "currentTool": toolName,
            "currentToolIcon": toolIcon,
            "startedAt": startedAt,
            "contextPercent": contextPct
        ]
        if let message { contentState["message"] = message }

        // For "end" events, clean up state AFTER push is sent (not before)
        let shouldCleanup = (event == "end")

        Task {
            await PushNotificationService.shared.sendLiveActivityUpdate(
                workspaceId: wsId,
                contentState: contentState,
                event: event,
                alert: alert
            )
            if shouldCleanup {
                await MainActor.run { self.cleanupLAState(sessionId: sessionId) }
            }
        }
    }

    /// Clean up all Live Activity push state for a session
    private func cleanupLAState(sessionId: String) {
        lastLAPushTime.removeValue(forKey: sessionId)
        sessionStartTimes.removeValue(forKey: sessionId)
        sessionContextPercent.removeValue(forKey: sessionId)
        sessionWorkspaceId.removeValue(forKey: sessionId)
    }

    // MARK: - Packet Handling

    private func handlePacket(clientId: String, packet: WSPacket) async {
        lastActiveClientId = clientId
        lastClientActivity = Date()
        switch packet.action {
        // E2E encrypted envelope — unwrap and re-dispatch
        case .e2eEncrypted:
            let crypto = clientId == "relay" ? relayE2E : e2e
            guard let dataB64 = packet.payload?["data"],
                  let ciphertext = Data(base64Encoded: dataB64),
                  let decryptedData = crypto.decryptBinary(ciphertext),
                  let innerPacket = try? WSPacket.decode(from: decryptedData) else {
                log("e2eEncrypted: failed to decrypt packet from \(clientId)")
                return
            }
            await handlePacket(clientId: clientId, packet: innerPacket)
            return
        // E2E key exchange via relay — iOS sends its public key
        case .e2eKeyExchange:
            if let clientKey = packet.payload?["e2ePublicKey"], !clientKey.isEmpty {
                relayE2E.reset()
                if relayE2E.completeKeyExchange(remotePublicKeyBase64: clientKey) {
                    log("e2eKeyExchange: relay E2E established")
                    var payload: [String: String] = ["e2ePublicKey": relayE2E.publicKeyBase64]
                    // Sign our E2E public key with the TLS private key (same as LAN path)
                    if let keyData = relayE2E.publicKeyBase64.data(using: .utf8),
                       let signature = TLSCertificateManager.shared.sign(keyData) {
                        payload["e2eKeySignature"] = signature.base64EncodedString()
                        if let certDER = TLSCertificateManager.shared.certificateDER() {
                            payload["tlsCertificate"] = certDER.base64EncodedString()
                        }
                    }
                    // Send response directly (not via sendToClientOrRelay which would try to encrypt)
                    await relayClient.send(packet: WSPacket(
                        action: .e2eKeyExchangeResponse,
                        payload: payload,
                        id: packet.id
                    ))
                    // Now that E2E is ready, send initial state that the iOS client needs.
                    // These were sent on relay connect but got lost (no client yet / no E2E).
                    let agents = detectedAgents
                    await sendToClientOrRelay(
                        WSPacket(action: .agentsDetected, payload: ["agents": agents.map(\.rawValue).joined(separator: ",")]),
                        to: "relay"
                    )
                    let openclawInstalled = await openClaw.isInstalled()
                    await sendToClientOrRelay(
                        WSPacket(action: .openclawStatus, payload: [
                            "installed": openclawInstalled ? "true" : "false",
                            "running": "false"
                        ]),
                        to: "relay"
                    )
                } else {
                    log("e2eKeyExchange: ECDH failed")
                }
            }
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
        case .terminalComplete:
            await handleTerminalComplete(clientId: clientId, packet: packet)
        case .terminalInterrupt:
            if let sessionId = packet.payload?["sessionId"] {
                await terminalManager.interruptSession(sessionId)
            }
        case .engineInterrupt:
            if let sessionId = packet.payload?["sessionId"] {
                await terminalManager.interruptEngineSession(sessionId)
            }
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
            guard let path = packet.payload?["path"],
                  let command = packet.payload?["command"], !command.isEmpty else {
                await sendToClientOrRelay(
                    WSPacket(action: .error, payload: ["message": "Missing path or command for dev server"], id: packet.id),
                    to: clientId
                )
                break
            }
            await portMonitor.startDevServer(
                clientId: clientId,
                packetId: packet.id,
                workspacePath: (path as NSString).expandingTildeInPath,
                command: command,
                streamUrl: packet.payload?["streamUrl"]
            )
        case .devServerStop:
            guard let path = packet.payload?["path"] else { break }
            await portMonitor.stopDevServer(
                clientId: clientId,
                packetId: packet.id,
                workspacePath: (path as NSString).expandingTildeInPath
            )
        case .devServerStatus:
            guard let path = packet.payload?["path"] else { break }
            await portMonitor.devServerStatus(
                clientId: clientId,
                packetId: packet.id,
                workspacePath: (path as NSString).expandingTildeInPath,
                streamUrl: packet.payload?["streamUrl"]
            )
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
        case .gitStage:
            await handleGitStage(clientId: clientId, packet: packet)
        case .gitDiscard:
            await handleGitDiscard(clientId: clientId, packet: packet)
        // HTTP Proxy
        case .proxyDetectPorts:
            guard let path = packet.payload?["path"] else { break }
            await portMonitor.detectPorts(
                clientId: clientId,
                packetId: packet.id,
                workspacePath: (path as NSString).expandingTildeInPath
            )
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
        // System Dialog Safety Net
        case .systemDialogClickButton:
            await handleSystemDialogClick(packet)
        case .systemDialogDetected, .systemDialogDismissed:
            break // Emitted by the macOS side; ignored if received here.
        // Permission Doctor
        case .permissionsStatusRequest:
            let perms = permissionMonitor.current()
            await sendToClientOrRelay(
                WSPacket(action: .permissionsStatus,
                         payload: perms.payload,
                         id: packet.id),
                to: clientId
            )
        case .permissionsStatus:
            break // Emitted by the macOS side; ignored if received here.
        // Sudo
        case .sudoRequest:
            await handleSudoRequest(clientId: clientId, packet: packet)
        case .sudoResponse:
            // Only accept E2E-encrypted passwords — never plaintext
            guard let encrypted = packet.payload?["encryptedPassword"], !encrypted.isEmpty else {
                // Empty payload = user cancelled, or unencrypted fallback (rejected)
                if packet.payload?.isEmpty != false {
                    // Cancellation — forward as empty response
                    await SudoPasswordManager.shared.handlePasswordResponse(packet: packet)
                }
                break
            }
            guard let plaintext = e2e.decrypt(encrypted) else {
                break
            }
            let decryptedPacket = WSPacket(action: .sudoResponse, payload: ["password": plaintext], id: packet.id)
            await SudoPasswordManager.shared.handlePasswordResponse(packet: decryptedPacket)
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
        // Security
        case .securityRotateSecret:
            await rotateMachineSecret()
            await sendToClientOrRelay(
                WSPacket(action: .securityRotateResult, payload: ["status": "ok"], id: packet.id),
                to: clientId
            )
        case .securityRotateResult, .securityFingerprintUpdate:
            break // Handled on iOS side
        case .slashCommandsRequest:
            let workspacePath = packet.payload?["path"]
            var paths = Array(registeredWorkspacePaths)
            if let wp = workspacePath {
                let expanded = (wp as NSString).expandingTildeInPath
                let resolved = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
                if !paths.contains(resolved) { paths.append(resolved) }
            }
            let cmds = scanSlashCommands(workspacePaths: paths)
            detectedSlashCommands = cmds
            await broadcastSlashCommands(to: clientId)
        // DevTools
        case .processList:
            await handleProcessList(clientId: clientId, packet: packet)
        case .processKill:
            await handleProcessKill(clientId: clientId, packet: packet)
        case .portsList:
            await handlePortsList(clientId: clientId, packet: packet)
        case .httpRequest:
            await handleHTTPRequest(clientId: clientId, packet: packet)
        case .systemResources:
            await handleSystemResources(clientId: clientId, packet: packet)
        case .relayNoClients:
            log("Relay reports no clients connected — stopping stream")
            await stopStreamCleanup()
        case .ping:
            await sendToClientOrRelay(WSPacket(action: .pong, id: packet.id), to: clientId)
        case .pong:
            break
        default:
            await sendToClientOrRelay(
                WSPacket(action: .error, payload: ["message": "Unknown action: \(packet.action.rawValue)"]),
                to: clientId
            )
        }
    }

    private func handleScanRepos(clientId: String, packet: WSPacket) async {
        log("scanRepos: starting scan for client \(clientId)")
        var scanner = RepoScanner()
        let repos = await scanner.scan()
        let gitInstalled = scanner.gitAvailable
        log("scanRepos: found \(repos.count) repos, git installed: \(gitInstalled)")

        do {
            let data = try JSONEncoder().encode(repos)
            guard let json = String(data: data, encoding: .utf8) else {
                log("scanRepos: failed to convert encoded data to UTF-8 string")
                await sendToClientOrRelay(
                    WSPacket(action: .workspaceScanResult, payload: ["error": "Failed to encode repos"], id: packet.id),
                    to: clientId
                )
                return
            }
            var payload = ["repos": json]
            if !gitInstalled {
                payload["git_missing"] = "true"
            }
            await sendToClientOrRelay(
                WSPacket(action: .workspaceScanResult, payload: payload, id: packet.id),
                to: clientId
            )
        } catch {
            log("scanRepos: encoding error: \(error.localizedDescription)")
            await sendToClientOrRelay(
                WSPacket(action: .workspaceScanResult, payload: ["error": "Encoding error: \(error.localizedDescription)"], id: packet.id),
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

        // Replay missed session events (complete/askUser) so reconnecting clients sync state.
        // workspaceList is always requested on reconnect, making this a reliable sync point.
        if !sessionLastEvent.isEmpty {
            log("Replaying \(sessionLastEvent.count) missed session events to \(clientId)")
            for (_, eventPacket) in sessionLastEvent {
                await sendToClientOrRelay(eventPacket, to: clientId)
            }
        }
    }

    private func handleWorkspaceStart(clientId: String, packet: WSPacket) async {
        guard let path = packet.payload?["path"] else { return }
        var devCmd = packet.payload?["devCommand"]

        // If dev command needs sudo, ask for password before starting
        let expandedPath = (path as NSString).expandingTildeInPath
        registeredWorkspacePaths.insert(URL(fileURLWithPath: expandedPath).resolvingSymlinksInPath().path)
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
                    guard let self else { return }
                    await self.detectSudoPromptInOutput(output, sessionId: sessionId)
                    await self.sendToClientOrRelay(
                        WSPacket(action: .terminalOutput, payload: ["sessionId": sessionId, "output": output]),
                        to: self.lastActiveClientId
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
                    guard let self else { return }
                    // Detect sudo password prompts in terminal output
                    await self.detectSudoPromptInOutput(output, sessionId: sessionId)
                    await self.sendToClientOrRelay(
                        WSPacket(action: .terminalOutput, payload: ["sessionId": sessionId, "output": output]),
                        to: self.lastActiveClientId
                    )
                }
            }
            await terminalManager.setPromptReadyHandler(for: sessionId) { [weak self] in
                Task {
                    guard let self else { return }
                    await self.sendToClientOrRelay(
                        WSPacket(action: .terminalPromptReady, payload: ["sessionId": sessionId]),
                        to: self.lastActiveClientId
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

    // MARK: - Terminal Completion

    private func handleTerminalComplete(clientId: String, packet: WSPacket) async {
        guard let partial = packet.payload?["partial"],
              let path = packet.payload?["path"] else {
            await sendToClientOrRelay(
                WSPacket(action: .terminalCompleteResult, payload: ["completions": "[]"], id: packet.id),
                to: clientId
            )
            return
        }

        let expandedPath = (path as NSString).expandingTildeInPath

        // Use compgen (bash builtin) to get command + file completions
        // Pass user input via env vars to prevent shell injection
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/bash")
                task.arguments = ["-c", """
                    cd "$TARSY_CWD" 2>/dev/null
                    # File completions (relative to cwd)
                    files=$(compgen -f -- "$TARSY_PARTIAL" 2>/dev/null)
                    # Command completions (only if partial has no path separator)
                    cmds=""
                    if [[ "$TARSY_PARTIAL" != */* ]]; then
                        cmds=$(compgen -c -- "$TARSY_PARTIAL" 2>/dev/null)
                    fi
                    # Combine, deduplicate, limit to 30
                    printf '%s\\n%s' "$files" "$cmds" | sort -u | head -30
                    """]
                var env = ProcessInfo.processInfo.environment
                env["TARSY_PARTIAL"] = partial
                env["TARSY_CWD"] = expandedPath
                task.environment = env
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = Pipe()

                // Timeout
                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now() + 3)
                timer.setEventHandler { if task.isRunning { task.terminate() } }
                timer.resume()

                guard (try? task.run()) != nil else {
                    timer.cancel()
                    continuation.resume(returning: [])
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                timer.cancel()

                guard let output = String(data: data, encoding: .utf8) else {
                    continuation.resume(returning: [])
                    return
                }

                let completions = output.components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                continuation.resume(returning: completions)
            }
        }

        // Tag each completion with its type (dir, file, or cmd)
        // Filter out completions that resolve outside the workspace (path traversal)
        let tagged: [[String: String]] = result.compactMap { item in
            let fullPath = item.hasPrefix("/") ? item : "\(expandedPath)/\(item)"
            // Resolve symlinks and .. to get canonical path
            let resolved = (fullPath as NSString).standardizingPath
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir)

            // For file/dir completions, ensure they stay within workspace
            if exists {
                let workspacePrefix = (expandedPath as NSString).standardizingPath
                guard resolved.hasPrefix(workspacePrefix) else { return nil }
            }

            let type: String
            if exists && isDir.boolValue {
                type = "dir"
            } else if exists {
                type = "file"
            } else {
                type = "cmd"
            }
            return ["name": item, "type": type]
        }

        // Encode as JSON string
        let json = (try? JSONSerialization.data(withJSONObject: tagged))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        await sendToClientOrRelay(
            WSPacket(action: .terminalCompleteResult, payload: ["completions": json], id: packet.id),
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
                        guard let self else { return }
                        await self.sendToClientOrRelay(
                            WSPacket(action: .claudeOutput, payload: ["sessionId": sid, "output": output]),
                            to: self.lastActiveClientId
                        )
                    }
                },
                onComplete: { [weak self] (message: String) in
                    Task { @MainActor in
                        guard let self else { return }
                        let packet = WSPacket(action: .claudeComplete, payload: ["sessionId": sid, "message": message])
                        self.sessionLastEvent[sid] = packet
                        await self.sendToClientOrRelay(packet, to: self.lastActiveClientId)
                        PushNotificationService.shared.notifyTaskComplete(
                            workspace: workspaceName,
                            summary: message,
                            workspaceId: wsIdStr
                        )
                    }
                },
                onAskUser: { [weak self] (questionsJson: String, _: [String]) in
                    Task { @MainActor in
                        guard let self else { return }
                        let packet = WSPacket(action: .claudeAskUser, payload: [
                            "sessionId": sid,
                            "questions": questionsJson
                        ])
                        self.sessionLastEvent[sid] = packet
                        // questionsJson is already a JSON string of the full questions array
                        await self.sendToClientOrRelay(packet, to: self.lastActiveClientId)
                        PushNotificationService.shared.notifyAgentQuestion(
                            workspace: workspaceName,
                            question: questionsJson,
                            workspaceId: wsIdStr
                        )
                    }
                }
            )

            log("claudeCreate: session created, sending response")

            // Set permission handler for safe mode (control_request → iOS approval)
            await terminalManager.setClaudePermissionHandler(sessionId: sid) { [weak self] requestId, toolName, toolInput in
                Task { @MainActor in
                    guard let self else { return }
                    let description = self.formatPermissionDescription(toolName, toolInput)
                    let questionsPayload: [[String: Any]] = [[
                        "question": description,
                        "header": "Permission",
                        "options": ["Allow", "Always Allow \(toolName)", "Deny"],
                        "multiSelect": false
                    ]]
                    if let jsonData = try? JSONSerialization.data(withJSONObject: questionsPayload),
                       let jsonStr = String(data: jsonData, encoding: .utf8) {
                        let packet = WSPacket(action: .claudeAskUser, payload: [
                            "sessionId": sid,
                            "questions": jsonStr,
                            "permissionRequestId": requestId,
                            "isPermission": "true"
                        ])
                        self.sessionLastEvent[sid] = packet
                        await self.sendToClientOrRelay(packet, to: self.lastActiveClientId)
                        PushNotificationService.shared.notifyAgentQuestion(
                            workspace: workspaceName,
                            question: description,
                            workspaceId: wsIdStr
                        )
                    }
                }
            }

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
        sessionLastEvent.removeValue(forKey: sessionId)

        // Check if this is a permission response (has permissionRequestId)
        if let requestId = packet.payload?["permissionRequestId"] {
            let choice: String
            if answer.contains("Deny") { choice = "Deny" }
            else if answer.contains("Always") { choice = "Always" }
            else { choice = "Allow" }
            await terminalManager.respondToClaudePermission(requestId, answer: choice, sessionId: sessionId)
        } else {
            await terminalManager.respondToClaudeQuestion(answer, sessionId: sessionId)
        }
    }

    private func formatPermissionDescription(_ toolName: String, _ input: [String: Any]) -> String {
        var parts: [String] = ["🔧 \(toolName)"]
        if let cmd = input["command"] as? String {
            parts.append("\n\(cmd)")
        } else if let path = input["file_path"] as? String {
            parts.append("\n\(path)")
        } else if let query = input["query"] as? String {
            parts.append("\n\(query)")
        }
        if let reason = input["_decision_reason"] as? String, !reason.isEmpty {
            parts.append("\n\(reason)")
        }
        return parts.joined()
    }

    private func handleClaudeMessage(clientId: String, packet: WSPacket) async {
        guard let sessionId = packet.payload?["sessionId"],
              let message = packet.payload?["message"] else { return }
        let imagesJson = packet.payload?["images"]
        await terminalManager.sendClaudeMessage(message, images: imagesJson, to: sessionId)
    }

    private func handleClaudeClose(clientId: String, packet: WSPacket) async {
        guard let sessionId = packet.payload?["sessionId"] else { return }
        sessionLastEvent.removeValue(forKey: sessionId)
        await terminalManager.closeClaudeSession(sessionId)
        await sendToClientOrRelay(
            WSPacket(action: .claudeClose, payload: ["sessionId": sessionId], id: packet.id),
            to: clientId
        )
    }

    // MARK: - OpenClaw

    private func handleOpenClawStatus(clientId: String, packet: WSPacket) async {
        let installed = await openClaw.isInstalled()
        let running = installed ? await openClaw.checkGateway() : false
        await sendToClientOrRelay(
            WSPacket(action: .openclawStatus, payload: [
                "installed": installed ? "true" : "false",
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
                    guard let self else { return }
                    await self.sendToClientOrRelay(
                        WSPacket(action: .openclawOutput, payload: ["output": chunk]),
                        to: self.lastActiveClientId
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

    // MARK: - Browser

    private func openBrowserToUrl(_ urlString: String) async {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            log("openBrowserToUrl: blocked non-http URL '\(urlString)'")
            return
        }
        log("openBrowserToUrl: opening \(urlString)")
        NSWorkspace.shared.open(url)
    }

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

    // MARK: - Remote Input

    /// Clamp a coordinate to valid range, rejecting NaN and Infinity
    private func clampCoordinate(_ value: Double, fallback: Double = 0.5) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, 0.0), 1.0)
    }

    private func handleRemoteInput(packet: WSPacket) {
        let rawX = Double(packet.payload?["x"] ?? "0.5") ?? 0.5
        let rawY = Double(packet.payload?["y"] ?? "0.5") ?? 0.5
        let x = clampCoordinate(rawX)
        let y = clampCoordinate(rawY)
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
            guard dx.isFinite, dy.isFinite else { return }
            remoteInput.scroll(relativeX: x, relativeY: y, deltaX: dx, deltaY: dy)
        case .remoteScrollEnd:
            remoteInput.scrollEnd()
        case .remoteDrag:
            let toX = clampCoordinate(Double(packet.payload?["toX"] ?? "0") ?? 0, fallback: 0)
            let toY = clampCoordinate(Double(packet.payload?["toY"] ?? "0") ?? 0, fallback: 0)
            remoteInput.drag(fromX: x, fromY: y, toX: toX, toY: toY)
        case .remotePinchStart:
            remoteInput.pinchStart(relativeX: x, relativeY: y)
        case .remotePinch:
            let scale = Double(packet.payload?["scale"] ?? "1") ?? 1
            guard scale.isFinite, scale > 0 else { return }
            remoteInput.pinchUpdate(scale: scale)
        case .remotePinchEnd:
            remoteInput.pinchEnd()
        case .remoteKeyboard:
            if let text = packet.payload?["text"] {
                // Limit keyboard input to 10KB to prevent memory abuse
                let safeText = text.count > 10_240 ? String(text.prefix(10_240)) : text
                remoteInput.typeText(safeText)
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
        let isRelay = clientId == "relay"
        let quality: CGFloat = isRelay ? 0.5 : 0.7

        // Primary: capture from the active stream (works for ALL stacks)
        if screenCapture.isCapturing, let jpegData = screenCapture.captureScreenshot(quality: quality) {
            let sizeKB = jpegData.count / 1024
            log("screenshot: captured \(sizeKB)KB JPEG from stream")

            let base64 = jpegData.base64EncodedString()
            await sendToClientOrRelay(
                WSPacket(action: .screenshotResult, payload: [
                    "data": base64,
                    "size": "\(sizeKB)"
                ], id: packet.id),
                to: clientId
            )
            return
        }

        // Fallback: CGWindowListCreateImage from selectedWindow
        if let window = screenCapture.selectedWindow {
            let image = CGWindowListCreateImage(
                window.frame,
                .optionIncludingWindow,
                window.windowID,
                [.boundsIgnoreFraming, .bestResolution]
            )
            if let image {
                let bitmap = NSBitmapImageRep(cgImage: image)
                if let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality as NSNumber]) {
                    let sizeKB = jpegData.count / 1024
                    log("screenshot: captured \(sizeKB)KB JPEG from window")

                    let base64 = jpegData.base64EncodedString()
                    await sendToClientOrRelay(
                        WSPacket(action: .screenshotResult, payload: [
                            "data": base64,
                            "size": "\(sizeKB)"
                        ], id: packet.id),
                        to: clientId
                    )
                    return
                }
            }
        }

        log("screenshot: no active stream or window available")
        await sendToClientOrRelay(
            WSPacket(action: .screenshotResult, payload: [
                "error": "No active stream to capture screenshot"
            ], id: packet.id),
            to: clientId
        )
    }

    // MARK: - Stream

    private func handleStreamStart(clientId: String, packet: WSPacket) async {
        let stack = packet.payload?["stack"] ?? "web"
        // Stream URL only applies to web/fullstack workspaces. Mobile streams
        // the iOS Simulator window directly; backend has no UI. Ignore any
        // stray streamUrl for those stacks to avoid accidentally opening a
        // browser when the user expects to see the simulator.
        let streamUrl: String? = {
            guard stack == "web" || stack == "fullstack" else { return nil }
            return packet.payload?["streamUrl"]
        }()
        let quality = packet.payload?["quality"]
        let isOpenClaw = packet.payload?["workspaceType"] == "openclaw"

        // Handle quality change for existing stream (H.264: force keyframe on quality change)
        if quality != nil, screenCapture.isCapturing {
            h264Encoder?.forceKeyframe()
            log("streamStart: quality change — forced keyframe")
            return
        }

        log("streamStart: stack=\(stack), openClaw=\(isOpenClaw), streamUrl=\(streamUrl ?? "nil"), permission=\(CGPreflightScreenCaptureAccess()), capturing=\(screenCapture.isCapturing)")

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
            fps = 24
            scale = 0.85
            bitrate = 3_000_000
        }

        do {
            // OpenClaw: capture entire display
            if isOpenClaw {
                await screenCapture.requestPermission()

                // Get display dimensions for encoder
                let displayWidth = Int(CGFloat(NSScreen.main?.frame.width ?? 1920) * scale)
                let displayHeight = Int(CGFloat(NSScreen.main?.frame.height ?? 1080) * scale)

                let encoder = H264Encoder()
                encoder.configure(width: displayWidth, height: displayHeight, fps: fps, bitrate: bitrate, isRelay: isRelay)
                self.h264Encoder = encoder

                setupEncoderFrameRelay(encoder: encoder, isRelay: isRelay, clientId: clientId)

    
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

                // Simulator boot can take several seconds — poll up to 8s
                let maxAttempts = stack == "mobile" ? 4 : 1
                for attempt in 1...maxAttempts {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    window = await screenCapture.findWindow(forStack: stack)
                    if window != nil {
                        log("streamStart: window found on attempt \(attempt)")
                        break
                    }
                    if attempt < maxAttempts {
                        log("streamStart: waiting for simulator window (attempt \(attempt)/\(maxAttempts))...")
                    }
                }
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
            encoder.configure(width: captureWidth, height: captureHeight, fps: fps, bitrate: bitrate, isRelay: isRelay)
            self.h264Encoder = encoder

            setupEncoderFrameRelay(encoder: encoder, isRelay: isRelay, clientId: clientId)


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
        startClientActivityMonitor()
        let relay = self.relayClient
        let wsServer = self.wsServer
        let e2eRef = isRelay ? self.relayE2E : self.e2e
        let sendInFlight = OSAllocatedUnfairLock(initialState: false)
        encoder.onEncodedFrame = { [weak encoder] encodedData in
            let framePayload: Data
            // Only E2E-encrypt on relay (LAN is already TLS-protected, skip for lower latency)
            if isRelay, e2eRef.isReady, let encrypted = e2eRef.encryptBinary(encodedData) {
                framePayload = encrypted
            } else {
                framePayload = encodedData
            }

            var prefixedData = Data("H264".utf8)
            prefixedData.append(framePayload)

            let alreadyInFlight = sendInFlight.withLock { val -> Bool in
                if val { return true }
                val = true
                return false
            }
            guard !alreadyInFlight else {
                encoder?.reportFrameDropped()
                return
            }

            if isRelay {
                Task { [weak encoder] in
                    let enc = encoder
                    await relay.sendBinary(prefixedData) {
                        sendInFlight.withLock { $0 = false }
                        enc?.reportFrameDelivered()
                    }
                }
            } else {
                Task { [weak encoder] in
                    let enc = encoder
                    await wsServer?.broadcastBinary(prefixedData)
                    sendInFlight.withLock { $0 = false }
                    enc?.reportFrameDelivered()
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
            await bootSimulatorIfNeeded()
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

    /// Boots an iOS Simulator if none is currently running.
    /// Picks the first available iPhone device found via `simctl list devices available`.
    private func bootSimulatorIfNeeded() async {
        // Check if any simulator is already booted
        let bootedCheck = Process()
        bootedCheck.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        bootedCheck.arguments = ["simctl", "list", "devices", "booted", "-j"]
        let bootedPipe = Pipe()
        bootedCheck.standardOutput = bootedPipe
        bootedCheck.standardError = Pipe()

        do {
            try bootedCheck.run()
            bootedCheck.waitUntilExit()
            let data = bootedPipe.fileHandleForReading.readDataToEndOfFile()
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let devices = json["devices"] as? [String: [[String: Any]]] {
                for (_, deviceList) in devices {
                    for device in deviceList {
                        if let state = device["state"] as? String, state == "Booted" {
                            log("streamStart: simulator already booted")
                            return
                        }
                    }
                }
            }
        } catch {
            log("streamStart: failed to check booted simulators: \(error)")
        }

        // No simulator booted — find an available iPhone to boot
        log("streamStart: no simulator booted, looking for available device...")
        let listAll = Process()
        listAll.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        listAll.arguments = ["simctl", "list", "devices", "available", "-j"]
        let listPipe = Pipe()
        listAll.standardOutput = listPipe
        listAll.standardError = Pipe()

        do {
            try listAll.run()
            listAll.waitUntilExit()
            let data = listPipe.fileHandleForReading.readDataToEndOfFile()
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let devices = json["devices"] as? [String: [[String: Any]]] else { return }

            // Find the first available iPhone (prefer latest iOS runtime)
            var bestUDID: String?
            let sortedRuntimes = devices.keys.sorted().reversed() // Latest runtimes first
            for runtime in sortedRuntimes {
                guard runtime.contains("iOS") else { continue }
                if let deviceList = devices[runtime] {
                    for device in deviceList {
                        if let name = device["name"] as? String,
                           let udid = device["udid"] as? String,
                           let isAvailable = device["isAvailable"] as? Bool,
                           isAvailable,
                           name.contains("iPhone") {
                            bestUDID = udid
                            log("streamStart: booting simulator '\(name)' (\(udid))")
                            break
                        }
                    }
                }
                if bestUDID != nil { break }
            }

            guard let udid = bestUDID else {
                log("streamStart: no available iPhone simulator found")
                return
            }

            let boot = Process()
            boot.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            boot.arguments = ["simctl", "boot", udid]
            boot.standardOutput = Pipe()
            boot.standardError = Pipe()
            try boot.run()
            boot.waitUntilExit()
            log("streamStart: simulator booted (exit code \(boot.terminationStatus))")
        } catch {
            log("streamStart: failed to boot simulator: \(error)")
        }
    }

    private func handleStreamStop(clientId: String, packet: WSPacket) async {
        await stopStreamCleanup()

        await sendToClientOrRelay(
            WSPacket(action: .streamStop, id: packet.id),
            to: clientId
        )
    }

    /// Stops screen capture and H.264 encoding. Safe to call even if no stream is active.
    private func stopStreamCleanup() async {
        guard h264Encoder != nil else { return }
        await screenCapture.stopCapture()
        screenCapture.onPixelBuffer = nil
        h264Encoder?.stop()
        h264Encoder = nil
        clientActivityTimer?.invalidate()
        clientActivityTimer = nil
        lastClientActivity = nil
        log("Stream stopped")
    }

    /// Starts monitoring client activity. If no packets are received for the timeout
    /// while a stream is active, assumes the client disconnected and stops the stream.
    /// Uses 120s to tolerate network hiccups, brief backgrounding, and reconnections.
    /// The stream should primarily be stopped via explicit signals (streamStop, relayNoClients,
    /// LAN disconnect) — this monitor is a last-resort safety net for truly dead connections.
    private func startClientActivityMonitor() {
        clientActivityTimer?.invalidate()
        lastClientActivity = Date()
        clientActivityTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, self.h264Encoder != nil else {
                    timer.invalidate() // No encoder — stop polling
                    return
                }
                guard let lastActivity = self.lastClientActivity else { return }
                if Date().timeIntervalSince(lastActivity) > 120 {
                    self.log("No client activity for 120s — stopping stream")
                    await self.stopStreamCleanup()
                }
            }
        }
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

    private static let maxDebugLogLength = 50_000 // ~500 lines

    private func log(_ msg: String) {
        let entry = "[\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))] \(msg)"
        #if DEBUG
        print(entry)
        #endif
        debugLog += entry + "\n"
        // Trim to prevent unbounded memory growth in long-running sessions
        if debugLog.count > Self.maxDebugLogLength {
            let trimPoint = debugLog.index(debugLog.endIndex, offsetBy: -Self.maxDebugLogLength / 2)
            // Find next newline to keep clean line boundaries
            if let newlineIdx = debugLog[trimPoint...].firstIndex(of: "\n") {
                debugLog = "... (log trimmed) ...\n" + String(debugLog[debugLog.index(after: newlineIdx)...])
            }
        }
    }

    private func registerMachine() async {
        let hostname = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let localIp = getLocalIP()
        let hwUuid = getHardwareUUID()

        log("registerMachine: starting")

        guard localIp != nil else {
            log("registerMachine: skipped — no local IP available")
            lastError = "No local IP available to register"
            return
        }

        do {
            let session = try await supabase.auth.session
            ownerUserId = session.user.id
            log("registerMachine: authenticated")

            // Fetch all machines for this user
            let existing: [Machine] = try await supabase
                .from("machines")
                .select()
                .eq("user_id", value: session.user.id.uuidString)
                .execute()
                .value


            var updateData: [String: String] = [
                "hostname": hostname,
                "status": "online",
                "last_seen_at": ISO8601DateFormatter().string(from: Date())
            ]
            if let lip = localIp { updateData["local_ip"] = lip }
            if let hw = hwUuid { updateData["hardware_uuid"] = hw }
            if let model = getModelIdentifier() { updateData["model_identifier"] = model }

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
                log("registerMachine: updated")
            } else {
                updateData["user_id"] = session.user.id.uuidString
                log("registerMachine: creating new")
                let result: Machine = try await supabase
                    .from("machines")
                    .insert(updateData)
                    .select()
                    .single()
                    .execute()
                    .value
                machineId = result.id
                log("registerMachine: created")
            }
            lastError = nil

            // Ensure machine has a relay secret (for role verification).
            // Legacy flow — still required during the Phase 3 transition until
            // migration 036 drops the column.
            await ensureMachineSecret(userId: session.user.id, machineId: machineId!)
            // Phase 3 — also ensure a P-256 keypair exists and its public key
            // is registered in machine_tokens. The relay prefers this flow
            // over the legacy secret when both are available.
            await ensureMachinePublicKey(userId: session.user.id, machineId: machineId!)
        } catch {
            log("registerMachine: FAILED — \(error)")
            lastError = "Register failed: \(error.localizedDescription)"
        }
    }

    /// Creates (or loads) the Secure Enclave / Keychain P-256 key for this
    /// machine and uploads the public key to machine_tokens via the
    /// register_machine_public_key RPC. Idempotent: if the public key in the
    /// DB already matches the local key, this is a no-op.
    private func ensureMachinePublicKey(userId: UUID, machineId: UUID) async {
        do {
            let store: MachineKeyStore
            if let existing = self.machineKeyStore {
                store = existing
            } else {
                store = try MachineKeyStore()
                self.machineKeyStore = store
                log("ensureMachinePublicKey: created MachineKeyStore (backend=\(store.backend))")
            }

            let localPub = store.publicKeyDER
            // PostgREST represents bytea as a PostgreSQL escape string:
            // "\x<hex>". Build the same format for both comparison and upload
            // so we can avoid a round-trip through Data.
            let localPubHex = "\\x" + localPub.map { String(format: "%02x", $0) }.joined()

            // Compare against what's in the DB (if any) — we only upload when
            // different, so reboots don't bump `rotated_at` needlessly.
            struct MachineTokenRow: Decodable {
                let public_key: String?
            }
            let existing: [MachineTokenRow] = try await supabase
                .from("machine_tokens")
                .select("public_key")
                .eq("machine_id", value: machineId.uuidString)
                .execute()
                .value

            if let dbPubHex = existing.first?.public_key,
               dbPubHex.caseInsensitiveCompare(localPubHex) == .orderedSame {
                log("ensureMachinePublicKey: already up-to-date")
                return
            }

            // Upload via RPC — SECURITY DEFINER validates ownership and
            // enforces length bounds. PostgREST decodes "\x<hex>" to bytea.
            try await supabase
                .rpc("register_machine_public_key", params: [
                    "p_machine_id": machineId.uuidString,
                    "p_public_key": localPubHex
                ])
                .execute()
            log("ensureMachinePublicKey: uploaded public key (\(localPub.count) bytes) to Supabase")
        } catch {
            log("ensureMachinePublicKey: FAILED — \(error)")
        }
    }

    private func ensureMachineSecret(userId: UUID, machineId: UUID) async {
        // Try loading from Keychain first
        if let existing = loadMachineSecret() {
            self.machineSecret = existing
            log("ensureMachineSecret: loaded from Keychain")

            // Ensure it exists in Supabase too (idempotent upsert)
            do {
                try await supabase
                    .from("machine_tokens")
                    .upsert([
                        "user_id": userId.uuidString,
                        "machine_id": machineId.uuidString,
                        "machine_secret": existing
                    ], onConflict: "machine_id")
                    .execute()
            } catch {
                log("ensureMachineSecret: Supabase sync failed — \(error)")
            }
            return
        }

        // Generate new secret
        let secret = UUID().uuidString
        saveMachineSecret(secret)
        self.machineSecret = secret
        log("ensureMachineSecret: generated new secret")

        do {
            try await supabase
                .from("machine_tokens")
                .insert([
                    "user_id": userId.uuidString,
                    "machine_id": machineId.uuidString,
                    "machine_secret": secret
                ])
                .execute()
            log("ensureMachineSecret: saved to Supabase")
        } catch {
            log("ensureMachineSecret: Supabase insert failed — \(error)")
        }
    }

    func rotateMachineSecret() async {
        guard let userId = ownerUserId, let mId = machineId else { return }
        let newSecret = UUID().uuidString
        saveMachineSecret(newSecret)
        self.machineSecret = newSecret

        do {
            try await supabase
                .from("machine_tokens")
                .update(["machine_secret": newSecret, "rotated_at": ISO8601DateFormatter().string(from: Date())])
                .eq("machine_id", value: mId.uuidString)
                .eq("user_id", value: userId.uuidString)
                .execute()
            log("rotateMachineSecret: rotated successfully")

            // Reconnect relay with new secret
            if let token = try? await supabase.auth.session.accessToken {
                await relayClient.connect(token: token, machineSecret: newSecret)
            }
        } catch {
            log("rotateMachineSecret: failed — \(error)")
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

    /// Returns the Mac model identifier (e.g. "MacBookAir10,1", "Mac14,3") via sysctl
    private func getModelIdentifier() -> String? {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let identifier = String(cString: model)

        // Also get the human-readable model name (e.g. "MacBook Air")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        proc.arguments = ["SPHardwareDataType"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8),
               let range = output.range(of: "Model Name: ") {
                let modelName = output[range.upperBound...].prefix(while: { $0 != "\n" })
                return "\(modelName) (\(identifier))"
            }
        } catch {}

        return identifier
    }

    private func updateMachineStatus(_ status: String) async {
        guard let id = machineId else { return }
        // Cache the auth token for use during synchronous shutdown
        if let token = try? await supabase.auth.session.accessToken {
            cachedAuthToken = token
        }
        do {
            try await supabase
                .from("machines")
                .update(["status": status, "last_seen_at": ISO8601DateFormatter().string(from: Date())])
                .eq("id", value: id.uuidString)
                .execute()
        } catch {
            log("Heartbeat failed: \(error.localizedDescription)")
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
        sessionStartTimes[sid] = Date().timeIntervalSince1970
        if let wsIdStr { sessionWorkspaceId[sid] = wsIdStr }
        let expandedEnginePath = (path as NSString).expandingTildeInPath
        registeredWorkspacePaths.insert(URL(fileURLWithPath: expandedEnginePath).resolvingSymlinksInPath().path)

        // Rescan slash commands with this workspace's project-level commands
        let paths = Array(registeredWorkspacePaths)
        log("slashCommands: scanning paths \(paths)")
        let newCommands = await Task.detached { self.scanSlashCommands(workspacePaths: paths) }.value
        detectedSlashCommands = newCommands
        log("slashCommands: found \(newCommands.count) commands, sending to \(clientId)")
        // Always send to ensure client has the full list (including project-level commands)
        await broadcastSlashCommands(to: clientId)

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
                            guard let self else { return }
                            await self.sendToClientOrRelay(
                                WSPacket(action: .engineOutput, payload: ["sessionId": sid, "output": output, "engineType": "claude"]),
                                to: self.lastActiveClientId
                            )
                            await UltraContextSync.shared.agentOutput(sessionId: sid, content: output)
                            // Push Live Activity tool update (throttled)
                            if let tool = AgentToolType.parse(from: output) {
                                await self.sendLAPush(sessionId: sid, status: "running", toolName: tool.displayName, toolIcon: tool.iconName)
                            }
                        }
                    },
                    onComplete: { [weak self] (message: String) in
                        Task { @MainActor in
                            guard let self else { return }
                            var payload = ["sessionId": sid, "message": message, "engineType": "claude"]
                            if let wsIdStr { payload["workspaceId"] = wsIdStr }
                            let packet = WSPacket(action: .engineComplete, payload: payload)
                            self.sessionLastEvent[sid] = packet
                            await self.sendToClientOrRelay(packet, to: self.lastActiveClientId)
                            // Push Live Activity end (cleanup happens inside sendLAPush after push completes)
                            self.sendLAPush(sessionId: sid, status: "completed", toolName: "Done", toolIcon: "checkmark.circle", event: "end", alert: ["title": "Tarsy", "body": "Agent task completed"])
                            PushNotificationService.shared.notifyTaskComplete(
                                workspace: workspaceName,
                                summary: String(message.prefix(200)),
                                workspaceId: wsIdStr
                            )
                            if let taskId = self.sessionTaskMap[sid] {
                                await self.agentTaskService.updateStatus(taskId, status: .completed)
                            }
                            await UltraContextSync.shared.engineCompleted(sessionId: sid, summary: message)
                        }
                    },
                    onAskUser: { [weak self] questionsJson, _ in
                        Task { @MainActor in
                            guard let self else { return }
                            let packet = WSPacket(action: .engineAskUser, payload: ["sessionId": sid, "questions": questionsJson, "engineType": "claude"])
                            self.sessionLastEvent[sid] = packet
                            await self.sendToClientOrRelay(packet, to: self.lastActiveClientId)
                            // Push Live Activity waiting status (bypasses throttle)
                            self.sendLAPush(sessionId: sid, status: "waiting", toolName: "Needs input", toolIcon: "questionmark.circle", message: String(questionsJson.prefix(100)), alert: ["title": "Tarsy", "body": "Your agent needs input"])
                            PushNotificationService.shared.notifyAgentQuestion(
                                workspace: workspaceName,
                                question: questionsJson,
                                workspaceId: wsIdStr
                            )
                            if let taskId = self.sessionTaskMap[sid] {
                                await self.agentTaskService.updateStatus(taskId, status: .waiting)
                            }
                        }
                    }
                )

                // Set status handler for model/usage info
                await terminalManager.setClaudeStatusHandler(sessionId: sid) { [weak self] model, inputTokens, outputTokens, contextWindow in
                    Task {
                        guard let self else { return }
                        var payload = [
                            "sessionId": sid,
                            "model": model,
                            "inputTokens": "\(inputTokens)",
                            "outputTokens": "\(outputTokens)"
                        ]
                        if contextWindow > 0 { payload["contextWindow"] = "\(contextWindow)" }
                        await self.sendToClientOrRelay(
                            WSPacket(action: .engineStatus, payload: payload),
                            to: self.lastActiveClientId
                        )
                        // Track context percent for Live Activity push updates
                        let total = inputTokens + outputTokens
                        let windowSize = contextWindow > 0 ? contextWindow : (model.contains("opus") ? 1_000_000 : 200_000)
                        await MainActor.run {
                            self.sessionContextPercent[sid] = Double(total) / Double(windowSize) * 100
                        }
                    }
                }

                // Set permission handler for safe mode (control_request → iOS approval)
                await terminalManager.setClaudePermissionHandler(sessionId: sid) { [weak self] requestId, toolName, toolInput in
                    Task { @MainActor in
                        guard let self else { return }
                        let description = self.formatPermissionDescription(toolName, toolInput)
                        let questionsPayload: [[String: Any]] = [[
                            "question": description,
                            "header": "Permission",
                            "options": ["Allow", "Always Allow \(toolName)", "Deny"],
                            "multiSelect": false
                        ]]
                        if let jsonData = try? JSONSerialization.data(withJSONObject: questionsPayload),
                           let jsonStr = String(data: jsonData, encoding: .utf8) {
                            let packet = WSPacket(action: .engineAskUser, payload: [
                                "sessionId": sid,
                                "questions": jsonStr,
                                "engineType": "claude",
                                "permissionRequestId": requestId,
                                "isPermission": "true"
                            ])
                            self.sessionLastEvent[sid] = packet
                            await self.sendToClientOrRelay(packet, to: self.lastActiveClientId)
                            self.sendLAPush(sessionId: sid, status: "waiting", toolName: "Permission", toolIcon: "lock.shield", message: description, alert: ["title": "Tarsy", "body": "Agent needs permission"])
                            PushNotificationService.shared.notifyAgentQuestion(
                                workspace: workspaceName,
                                question: description,
                                workspaceId: wsIdStr
                            )
                            if let taskId = self.sessionTaskMap[sid] {
                                await self.agentTaskService.updateStatus(taskId, status: .waiting)
                            }
                        }
                    }
                }

                await sendToClientOrRelay(
                    WSPacket(action: .engineCreate, payload: ["sessionId": sid, "engineType": "claude"], id: packet.id),
                    to: clientId
                )

                await UltraContextSync.shared.engineStarted(sessionId: sid, engineType: "claude", workspacePath: path, workspaceId: wsIdStr)

                // Mark Claude's internal session as managed to avoid duplicate UltraContext entries
                await terminalManager.setClaudeSessionIdHandler(sessionId: sid) { claudeSessionId in
                    Task { await SessionFileWatcher.shared.markSessionManaged(claudeSessionId) }
                }

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
                        guard let self else { return }
                        await self.sendToClientOrRelay(
                            WSPacket(action: .engineOutput, payload: ["sessionId": sid, "output": output, "engineType": engineTypeRaw]),
                            to: self.lastActiveClientId
                        )
                        await UltraContextSync.shared.agentOutput(sessionId: sid, content: output)
                        if let tool = AgentToolType.parse(from: output) {
                            await self.sendLAPush(sessionId: sid, status: "running", toolName: tool.displayName, toolIcon: tool.iconName)
                        }
                    }
                },
                onComplete: { [weak self] (message: String) in
                    Task { @MainActor in
                        guard let self else { return }
                        var genPayload = ["sessionId": sid, "message": message, "engineType": engineTypeRaw]
                        if let wsIdStr { genPayload["workspaceId"] = wsIdStr }
                        let packet = WSPacket(action: .engineComplete, payload: genPayload)
                        self.sessionLastEvent[sid] = packet
                        await self.sendToClientOrRelay(packet, to: self.lastActiveClientId)
                        self.sendLAPush(sessionId: sid, status: "completed", toolName: "Done", toolIcon: "checkmark.circle", event: "end", alert: ["title": "Tarsy", "body": "Agent task completed"])
                        await UltraContextSync.shared.engineCompleted(sessionId: sid, summary: message)
                    }
                },
                onAskUser: { [weak self] questionsJson, _ in
                    Task { @MainActor in
                        guard let self else { return }
                        var payload = ["sessionId": sid, "questions": questionsJson, "engineType": engineTypeRaw]

                        // Detect Codex approval metadata embedded in questions JSON
                        if engineTypeRaw == "codex",
                           let data = questionsJson.data(using: .utf8),
                           let questions = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                           let first = questions.first,
                           let approvalId = first["_approvalId"] {
                            payload["isPermission"] = "true"
                            payload["permissionRequestId"] = "\(approvalId)"
                            // Cache approval type per requestId so concurrent approvals don't conflict
                            if let approvalType = first["_approvalType"] as? String {
                                self.codexApprovalTypeCache["\(sid):\(approvalId)"] = approvalType
                            }
                            if let questionId = first["_questionId"] as? String {
                                payload["questionId"] = questionId
                            }
                        }

                        // Detect Gemini ACP permission metadata
                        if engineTypeRaw == "gemini",
                           let data = questionsJson.data(using: .utf8),
                           let questions = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                           let first = questions.first,
                           let rpcId = first["_permissionRpcId"] as? Int {
                            payload["isPermission"] = "true"
                            payload["permissionRequestId"] = "\(rpcId)"
                        }

                        let packet = WSPacket(action: .engineAskUser, payload: payload)
                        self.sessionLastEvent[sid] = packet
                        await self.sendToClientOrRelay(packet, to: self.lastActiveClientId)
                        self.sendLAPush(sessionId: sid, status: "waiting", toolName: "Needs input", toolIcon: "questionmark.circle", message: String(questionsJson.prefix(100)), alert: ["title": "Tarsy", "body": "Your agent needs input"])
                    }
                }
            )

            // Wire status handler for token tracking (Codex, Gemini)
            await terminalManager.setEngineStatusHandler(sessionId: sid) { [weak self] model, inputTokens, outputTokens, contextWindow in
                Task {
                    guard let self else { return }
                    var payload = [
                        "sessionId": sid, "model": model,
                        "inputTokens": "\(inputTokens)", "outputTokens": "\(outputTokens)"
                    ]
                    if contextWindow > 0 { payload["contextWindow"] = "\(contextWindow)" }
                    await self.sendToClientOrRelay(
                        WSPacket(action: .engineStatus, payload: payload),
                        to: self.lastActiveClientId
                    )
                }
            }

            await UltraContextSync.shared.engineStarted(sessionId: sid, engineType: engineTypeRaw, workspacePath: path, workspaceId: wsIdStr)

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
            // Check if this is a permission response
            if let requestId = packet.payload?["permissionRequestId"] {
                let choice: String
                if answer.contains("Deny") { choice = "Deny" }
                else if answer.contains("Always") { choice = "Always" }
                else { choice = "Allow" }
                await terminalManager.respondToClaudePermission(requestId, answer: choice, sessionId: sessionId)
            } else {
                await terminalManager.respondToClaudeQuestion(answer, sessionId: sessionId)
            }
        } else if engineType == "codex" {
            if let requestId = packet.payload?["permissionRequestId"] {
                // Build structured response with approval metadata
                let cacheKey = "\(sessionId):\(requestId)"
                let approvalType = codexApprovalTypeCache.removeValue(forKey: cacheKey) ?? "command"
                let questionId = packet.payload?["questionId"]
                var responseJson: [String: Any] = [
                    "_approvalId": Int(requestId) ?? 0,
                    "_approvalType": approvalType,
                    "answer": answer
                ]
                if let qId = questionId { responseJson["_questionId"] = qId }
                if let data = try? JSONSerialization.data(withJSONObject: responseJson),
                   let jsonStr = String(data: data, encoding: .utf8) {
                    await terminalManager.respondToCodexApproval(jsonStr, sessionId: sessionId)
                }
            } else {
                await terminalManager.respondToEngineQuestion(answer, sessionId: sessionId)
            }
        } else if engineType == "gemini" {
            if let requestId = packet.payload?["permissionRequestId"],
               let rpcId = Int(requestId) {
                // Route to GeminiSession with the RPC ID for permission response
                await terminalManager.respondToGeminiPermission(answer, rpcId: rpcId, sessionId: sessionId)
            } else {
                await terminalManager.respondToEngineQuestion(answer, sessionId: sessionId)
            }
        } else {
            await terminalManager.respondToEngineQuestion(answer, sessionId: sessionId)
        }

        // User responded — session is running again, clear last event
        sessionLastEvent.removeValue(forKey: sessionId)

        // Update task status back to running
        if let taskId = sessionTaskMap[sessionId] {
            await agentTaskService.updateStatus(taskId, status: .running)
        }
    }

    private func handleEngineClose(clientId: String, packet: WSPacket) async {
        guard let sessionId = packet.payload?["sessionId"] else { return }
        let engineType = packet.payload?["engineType"] ?? ""

        // Clean up session state tracking
        sessionLastEvent.removeValue(forKey: sessionId)
        sessionTaskMap.removeValue(forKey: sessionId)

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
                            guard let self else { return }
                            await self.sendToClientOrRelay(
                                WSPacket(action: .wizardResponse, payload: ["response": fullResponse], id: packet.id),
                                to: self.lastActiveClientId
                            )
                            await self.terminalManager.closeClaudeSession(sid)
                        }
                    },
                    onAskUser: { [weak self] _, _ in
                        // If agent asks a question during wizard, just send what we have
                        Task {
                            guard let self else { return }
                            await self.sendToClientOrRelay(
                                WSPacket(action: .wizardResponse, payload: ["response": fullResponse], id: packet.id),
                                to: self.lastActiveClientId
                            )
                            await self.terminalManager.closeClaudeSession(sid)
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
                            guard let self else { return }
                            await self.sendToClientOrRelay(
                                WSPacket(action: .wizardResponse, payload: ["response": fullResponse], id: packet.id),
                                to: self.lastActiveClientId
                            )
                            await self.terminalManager.closeEngineSession(sid)
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

            // Validate path is within the user's home directory
            let homePath = NSHomeDirectory()
            let resolvedPath = URL(fileURLWithPath: expandedPath).resolvingSymlinksInPath().path
            guard resolvedPath.hasPrefix(homePath + "/") else {
                log("wizardExecute: blocked path outside home dir: \(expandedPath)")
                await sendToClientOrRelay(
                    WSPacket(action: .wizardResult, payload: ["success": "false", "error": "Project path must be within your home directory"], id: packet.id),
                    to: clientId
                )
                return
            }

            log("wizardExecute: creating project '\(config.projectName)' at \(expandedPath)")

            // 1. Create directory
            try FileManager.default.createDirectory(atPath: expandedPath, withIntermediateDirectories: true)

            // 2. git init
            let gitInit = await runProcess("/usr/bin/git", arguments: ["init"], at: expandedPath)
            log("wizardExecute: git init: \(gitInit.success ? "ok" : gitInit.output)")

            // 3. GitHub repo (optional)
            if createGitHub && detectGhCLI() {
                let ghCreate = await runProcess("/usr/local/bin/gh", arguments: ["repo", "create", config.projectName, "--private", "--source=.", "--remote=origin"], at: expandedPath)
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
                            guard let self else { return }
                            await self.sendToClientOrRelay(
                                WSPacket(action: .engineOutput, payload: ["sessionId": sid, "output": output, "engineType": "claude"]),
                                to: self.lastActiveClientId
                            )
                        }
                    },
                    onComplete: { [weak self] message in
                        Task { @MainActor in
                            guard let self else { return }
                            let packet = WSPacket(action: .engineComplete, payload: ["sessionId": sid, "message": message, "engineType": "claude"])
                            self.sessionLastEvent[sid] = packet
                            await self.sendToClientOrRelay(packet, to: self.lastActiveClientId)
                            PushNotificationService.shared.notifyTaskComplete(
                                workspace: workspaceName,
                                summary: String(message.prefix(200)),
                                workspaceId: workspace.id.uuidString
                            )
                            if let taskId = self.sessionTaskMap[sid] {
                                await self.agentTaskService.updateStatus(taskId, status: .completed)
                            }
                        }
                    },
                    onAskUser: { [weak self] questionsJson, _ in
                        Task { @MainActor in
                            guard let self else { return }
                            let packet = WSPacket(action: .engineAskUser, payload: ["sessionId": sid, "questions": questionsJson, "engineType": "claude"])
                            self.sessionLastEvent[sid] = packet
                            await self.sendToClientOrRelay(packet, to: self.lastActiveClientId)
                            PushNotificationService.shared.notifyAgentQuestion(
                                workspace: workspaceName,
                                question: questionsJson,
                                workspaceId: workspace.id.uuidString
                            )
                            if let taskId = self.sessionTaskMap[sid] {
                                await self.agentTaskService.updateStatus(taskId, status: .waiting)
                            }
                        }
                    }
                )

                await terminalManager.setClaudeStatusHandler(sessionId: sid) { [weak self] model, inputTokens, outputTokens, contextWindow in
                    Task {
                        guard let self else { return }
                        var payload = [
                            "sessionId": sid, "model": model,
                            "inputTokens": "\(inputTokens)", "outputTokens": "\(outputTokens)"
                        ]
                        if contextWindow > 0 { payload["contextWindow"] = "\(contextWindow)" }
                        await self.sendToClientOrRelay(
                            WSPacket(action: .engineStatus, payload: payload),
                            to: self.lastActiveClientId
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
                            guard let self else { return }
                            await self.sendToClientOrRelay(
                                WSPacket(action: .engineOutput, payload: ["sessionId": sid, "output": output, "engineType": engineTypeRaw]),
                                to: self.lastActiveClientId
                            )
                        }
                    },
                    onComplete: { [weak self] message in
                        Task { @MainActor in
                            guard let self else { return }
                            let packet = WSPacket(action: .engineComplete, payload: ["sessionId": sid, "message": message, "engineType": engineTypeRaw])
                            self.sessionLastEvent[sid] = packet
                            await self.sendToClientOrRelay(packet, to: self.lastActiveClientId)
                        }
                    }
                )

                // Wire status handler for token tracking (Codex, Gemini)
                await terminalManager.setEngineStatusHandler(sessionId: sid) { [weak self] model, inputTokens, outputTokens, contextWindow in
                    Task {
                        guard let self else { return }
                        var payload = [
                            "sessionId": sid, "model": model,
                            "inputTokens": "\(inputTokens)", "outputTokens": "\(outputTokens)"
                        ]
                        if contextWindow > 0 { payload["contextWindow"] = "\(contextWindow)" }
                        await self.sendToClientOrRelay(
                            WSPacket(action: .engineStatus, payload: payload),
                            to: self.lastActiveClientId
                        )
                    }
                }

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

    private func runProcess(_ executable: String, arguments: [String], at directory: String) async -> (success: Bool, output: String) {
        // Check common paths for the executable
        let paths = [executable, "/opt/homebrew/bin/\(URL(fileURLWithPath: executable).lastPathComponent)", "/usr/bin/\(URL(fileURLWithPath: executable).lastPathComponent)"]
        let resolvedPath = paths.first { FileManager.default.fileExists(atPath: $0) } ?? executable

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: resolvedPath)
        process.arguments = arguments
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

    /// Extracts and validates a path from a git packet payload, ensuring it's in a registered workspace.
    private func validatedGitPath(from packet: WSPacket, clientId: String, action: WSAction) async -> String? {
        guard let path = packet.payload?["path"] else { return nil }
        let expandedPath = (path as NSString).expandingTildeInPath
        guard isPathInRegisteredWorkspace(expandedPath) else {
            log("git: path not in workspace — rejected: \(expandedPath)")
            await sendToClientOrRelay(
                WSPacket(action: action, payload: ["success": "false", "error": "Path not in workspace"], id: packet.id),
                to: clientId
            )
            return nil
        }
        return expandedPath
    }

    private func handleGitCheckpoint(clientId: String, packet: WSPacket) async {
        guard let expandedPath = await validatedGitPath(from: packet, clientId: clientId, action: .gitCheckpointResult) else { return }
        let message = packet.payload?["message"] ?? "checkpoint"

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
        guard let expandedPath = await validatedGitPath(from: packet, clientId: clientId, action: .gitDiffResult) else { return }

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
        guard let expandedPath = await validatedGitPath(from: packet, clientId: clientId, action: .gitRollbackResult) else { return }
        let target = packet.payload?["target"] ?? "HEAD~1"

        // Validate target is a commit hash or HEAD~N pattern
        let isValidTarget = target.range(of: #"^(HEAD(~\d+)?|[0-9a-fA-F]{7,40})$"#, options: .regularExpression) != nil
        guard isValidTarget else {
            await sendGitResult(action: .gitRollbackResult, clientId: clientId, packetId: packet.id,
                               success: false, error: "Invalid rollback target")
            return
        }

        let result = await runGitCommand(["reset", "--hard", target], at: expandedPath)

        await sendGitResult(action: .gitRollbackResult, clientId: clientId, packetId: packet.id,
                           success: result.success, error: result.success ? nil : result.output)
    }

    private func handleGitHistory(clientId: String, packet: WSPacket) async {
        guard let expandedPath = await validatedGitPath(from: packet, clientId: clientId, action: .gitHistoryResult) else { return }
        let limit = min(Int(packet.payload?["limit"] ?? "20") ?? 20, 500)

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
        guard let file = packet.payload?["file"] else { return }
        guard let expandedPath = await validatedGitPath(from: packet, clientId: clientId, action: .gitFileDiffResult) else { return }

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
        guard let fullPath = sanitizedPath(base: expandedPath, relative: file) else {
            await sendToClientOrRelay(
                WSPacket(action: .gitFileDiffResult, payload: [
                    "file": file, "diff": "", "success": "false", "error": "Invalid path"
                ], id: packet.id), to: clientId)
            return
        }
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
        guard let expandedPath = await validatedGitPath(from: packet, clientId: clientId, action: .gitBranchesResult) else { return }

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
        guard let branch = packet.payload?["branch"] else { return }
        guard let expandedPath = await validatedGitPath(from: packet, clientId: clientId, action: .gitCheckoutResult) else { return }

        guard !branch.hasPrefix("-") else {
            await sendToClientOrRelay(
                WSPacket(action: .gitCheckoutResult, payload: ["success": "false", "error": "Invalid branch name"], id: packet.id),
                to: clientId
            )
            return
        }
        let result = await runGitCommand(["checkout", branch], at: expandedPath)

        await sendGitResult(action: .gitCheckoutResult, clientId: clientId, packetId: packet.id,
                           success: result.success,
                           data: ["branch": branch],
                           error: result.success ? nil : result.output)
    }

    private func handleGitPull(clientId: String, packet: WSPacket) async {
        guard let expandedPath = await validatedGitPath(from: packet, clientId: clientId, action: .gitPullResult) else { return }

        let result = await runGitCommand(["pull"], at: expandedPath)

        await sendGitResult(action: .gitPullResult, clientId: clientId, packetId: packet.id,
                           success: result.success,
                           data: ["output": result.output],
                           error: result.success ? nil : result.output)
    }

    private func handleGitStage(clientId: String, packet: WSPacket) async {
        guard let expandedPath = await validatedGitPath(from: packet, clientId: clientId, action: .gitStageResult) else { return }

        let files = packet.payload?["files"] // comma-separated, or nil for all
        let args: [String]
        if let files = files, !files.isEmpty {
            args = ["add", "--"] + files.components(separatedBy: ",")
        } else {
            args = ["add", "-A"]
        }

        let result = await runGitCommand(args, at: expandedPath)
        await sendGitResult(action: .gitStageResult, clientId: clientId, packetId: packet.id,
                           success: result.success, error: result.success ? nil : result.output)
    }

    private func handleGitDiscard(clientId: String, packet: WSPacket) async {
        guard let expandedPath = await validatedGitPath(from: packet, clientId: clientId, action: .gitDiscardResult) else { return }

        let files = packet.payload?["files"] // comma-separated, or nil for all
        let staged = packet.payload?["staged"] == "true"

        if let files = files, !files.isEmpty {
            let fileList = files.components(separatedBy: ",")
            if staged {
                // Unstage: move from index back to working tree
                let result = await runGitCommand(["reset", "HEAD", "--"] + fileList, at: expandedPath)
                await sendGitResult(action: .gitDiscardResult, clientId: clientId, packetId: packet.id,
                                   success: result.success, error: result.success ? nil : result.output)
            } else {
                // Discard working tree changes for tracked files
                var success = true
                var errorMsg: String?
                for file in fileList {
                    // Check if file is untracked
                    let lsResult = await runGitCommand(["ls-files", "--error-unmatch", file], at: expandedPath)
                    if lsResult.success {
                        // Tracked file — restore
                        let r = await runGitCommand(["checkout", "--", file], at: expandedPath)
                        if !r.success { success = false; errorMsg = r.output }
                    } else {
                        // Untracked file — remove
                        let r = await runGitCommand(["clean", "-fd", "--", file], at: expandedPath)
                        if !r.success { success = false; errorMsg = r.output }
                    }
                }
                await sendGitResult(action: .gitDiscardResult, clientId: clientId, packetId: packet.id,
                                   success: success, error: errorMsg)
            }
        } else {
            // Discard all
            if staged {
                let result = await runGitCommand(["reset", "HEAD"], at: expandedPath)
                await sendGitResult(action: .gitDiscardResult, clientId: clientId, packetId: packet.id,
                                   success: result.success, error: result.success ? nil : result.output)
            } else {
                // Restore tracked files
                let r1 = await runGitCommand(["checkout", "--", "."], at: expandedPath)
                // Only clean untracked files if explicitly requested
                var success = r1.success
                var errorOutput = r1.success ? "" : r1.output
                if packet.payload?["includeUntracked"] == "true" {
                    let r2 = await runGitCommand(["clean", "-fd", "--", "."], at: expandedPath)
                    success = success && r2.success
                    if !r2.success { errorOutput += r2.output }
                }
                await sendGitResult(action: .gitDiscardResult, clientId: clientId, packetId: packet.id,
                                   success: success, error: success ? nil : errorOutput)
            }
        }
    }

    // MARK: - File Explorer

    private func handleFileTree(clientId: String, packet: WSPacket) async {
        guard let path = packet.payload?["path"] else {
            log("fileTree: missing path")
            return
        }
        let expandedPath = (path as NSString).expandingTildeInPath

        guard isPathInRegisteredWorkspace(expandedPath) else {
            log("fileTree: path not in workspace — rejected: \(expandedPath)")
            await sendToClientOrRelay(
                WSPacket(action: .fileTreeResult, payload: ["error": "Path not in workspace", "tree": "[]"], id: packet.id),
                to: clientId
            )
            return
        }

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

        // Restrict file reads to registered workspaces only
        guard isPathInRegisteredWorkspace(expandedBase) else {
            await sendToClientOrRelay(
                WSPacket(action: .fileReadResult, payload: ["success": "false", "error": "Path not in a registered workspace"], id: packet.id),
                to: clientId
            )
            return
        }

        guard let fullPath = sanitizedPath(base: expandedBase, relative: filePath) else {
            await sendToClientOrRelay(
                WSPacket(action: .fileReadResult, payload: ["success": "false", "error": "Invalid path"], id: packet.id),
                to: clientId
            )
            return
        }

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

    /// Validates that a path is within a registered workspace directory.
    /// Prevents access to arbitrary filesystem locations (e.g., ~/.ssh, /etc).
    private func isPathInRegisteredWorkspace(_ path: String) -> Bool {
        let expandedPath = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath().path
        // Check registered paths from engineCreate/workspaceStart
        for workspacePath in registeredWorkspacePaths {
            if expandedPath == workspacePath || expandedPath.hasPrefix(workspacePath + "/") {
                return true
            }
        }
        // Fallback: check activeWorkspaces
        for workspace in activeWorkspaces {
            let localPath = workspace.localPath
            let workspacePath = URL(fileURLWithPath: (localPath as NSString).expandingTildeInPath)
                .resolvingSymlinksInPath().path
            if expandedPath == workspacePath || expandedPath.hasPrefix(workspacePath + "/") {
                return true
            }
        }
        return false
    }

    /// Validates that a resolved file path stays within the expected base directory.
    /// Prevents path traversal attacks (e.g., "../../etc/passwd") and symlink escapes.
    private func sanitizedPath(base: String, relative: String) -> String? {
        let baseURL = URL(fileURLWithPath: base).resolvingSymlinksInPath()
        let fullURL = URL(fileURLWithPath: relative, relativeTo: baseURL).resolvingSymlinksInPath()
        let basePath = baseURL.path
        guard fullURL.path == basePath || fullURL.path.hasPrefix(basePath + "/") else { return nil }
        return fullURL.path
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

        // SSRF protection: only allow requests to loopback addresses
        let allowedHosts: Set<String> = ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"]
        guard let host = url.host, allowedHosts.contains(host) else {
            log("proxyRequest: blocked non-loopback host '\(url.host ?? "nil")'")
            await sendToClientOrRelay(
                WSPacket(action: .proxyResponse, payload: [
                    "requestId": requestId, "status": "0", "error": "Proxy only allows localhost requests"
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
            // Use session with redirect protection to prevent SSRF via server-side redirects
            let session = URLSession(configuration: .default, delegate: LoopbackRedirectGuard(), delegateQueue: nil)
            let (data, response) = try await session.data(for: request)
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
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                    .replacingOccurrences(of: "/Library/Containers/com.tarsy.macos/Data", with: "")
                var mcpEntries: [[String: String]] = []

                // 1. Claude Code — ~/.claude.json
                self?.readMCPsFromJSON(
                    path: "\(home)/.claude.json",
                    engine: "claude",
                    mcpKey: "mcpServers",
                    workspacePath: workspacePath,
                    projectsKey: "projects",
                    into: &mcpEntries
                )

                // 2. Gemini CLI — ~/.gemini/settings.json
                self?.readMCPsFromJSON(
                    path: "\(home)/.gemini/settings.json",
                    engine: "gemini",
                    mcpKey: "mcpServers",
                    into: &mcpEntries
                )

                // 3. Cursor — ~/.cursor/mcp.json
                self?.readMCPsFromJSON(
                    path: "\(home)/.cursor/mcp.json",
                    engine: "cursor",
                    mcpKey: "mcpServers",
                    into: &mcpEntries
                )

                // 4. Windsurf — ~/.codeium/windsurf/mcp_config.json
                self?.readMCPsFromJSON(
                    path: "\(home)/.codeium/windsurf/mcp_config.json",
                    engine: "windsurf",
                    mcpKey: "mcpServers",
                    into: &mcpEntries
                )

                // 5. Amp — ~/.config/amp/settings.json (mcpServers or amp.mcpServers)
                self?.readMCPsFromJSON(
                    path: "\(home)/.config/amp/settings.json",
                    engine: "amp",
                    mcpKey: "mcpServers",
                    fallbackKey: "amp.mcpServers",
                    into: &mcpEntries
                )

                // 6. Cline — VS Code globalStorage
                self?.readMCPsFromJSON(
                    path: "\(home)/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json",
                    engine: "cline",
                    mcpKey: "mcpServers",
                    into: &mcpEntries
                )

                // 7. Copilot — VS Code mcp.json
                let vscodeMcpPath = "\(home)/Library/Application Support/Code/User/mcp.json"
                if let data = FileManager.default.contents(atPath: vscodeMcpPath),
                   let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // VS Code mcp.json uses "servers" or "mcpServers"
                    let servers = (config["servers"] as? [String: Any]) ?? (config["mcpServers"] as? [String: Any]) ?? [:]
                    for (name, mcpConfig) in servers {
                        let type = self?.mcpType(from: mcpConfig) ?? "unknown"
                        let command = self?.mcpCommand(from: mcpConfig) ?? ""
                        mcpEntries.append([
                            "name": name, "engine": "copilot", "scope": "global",
                            "type": type, "command": command
                        ])
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

    /// Reads MCPs from a JSON config file with standard mcpServers structure.
    private nonisolated func readMCPsFromJSON(
        path: String,
        engine: String,
        mcpKey: String,
        fallbackKey: String? = nil,
        workspacePath: String? = nil,
        projectsKey: String? = nil,
        into entries: inout [[String: String]]
    ) {
        guard let data = FileManager.default.contents(atPath: path),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let mcps = (config[mcpKey] as? [String: Any])
            ?? (fallbackKey.flatMap { config[$0] as? [String: Any] })
            ?? [:]

        for (name, mcpConfig) in mcps {
            entries.append([
                "name": name, "engine": engine, "scope": "global",
                "type": mcpType(from: mcpConfig), "command": mcpCommand(from: mcpConfig)
            ])
        }

        // Project-specific MCPs (Claude Code style)
        if let projectsKey, let wsPath = workspacePath,
           let projects = config[projectsKey] as? [String: Any] {
            let expanded = (wsPath as NSString).expandingTildeInPath
            if let projConfig = projects[expanded] as? [String: Any],
               let projMcps = projConfig[mcpKey] as? [String: Any] {
                for (name, mcpConfig) in projMcps {
                    if entries.contains(where: { $0["name"] == name && $0["engine"] == engine }) { continue }
                    entries.append([
                        "name": name, "engine": engine, "scope": "project",
                        "type": mcpType(from: mcpConfig), "command": mcpCommand(from: mcpConfig)
                    ])
                }
            }
        }
    }

    private func handleMCPHealthCheck(clientId: String, packet: WSPacket) async {
        guard let name = packet.payload?["name"],
              let type = packet.payload?["type"] else { return }

        var status = "unknown"

        if type == "http", let urlStr = packet.payload?["command"] {
            // HTTP MCP — try to reach it (loopback only to prevent SSRF)
            let allowedHosts: Set<String> = ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"]
            if let url = URL(string: urlStr), let host = url.host, allowedHosts.contains(host) {
                let request = URLRequest(url: url, timeoutInterval: 5)
                let session = URLSession(configuration: .default, delegate: LoopbackRedirectGuard(), delegateQueue: nil)
                do {
                    let (_, response) = try await session.data(for: request)
                    if let http = response as? HTTPURLResponse, (200...499).contains(http.statusCode) {
                        status = "healthy"
                    } else {
                        status = "unreachable"
                    }
                } catch {
                    status = "unreachable"
                }
            } else {
                log("mcpHealthCheck: blocked non-loopback URL '\(urlStr)'")
                status = "blocked"
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
                await self?.heartbeatTick()
            }
        }
    }

    private func heartbeatTick() async {
        // 1. Update machine status in Supabase
        await updateMachineStatus("online")

        // 2. Check relay connection health — force reconnect if dead
        let relayConnected = await relayClient.connected
        if !relayConnected && !isReconnectingRelay {
            isReconnectingRelay = true
            log("Heartbeat: relay is disconnected, forcing reconnect")
            await relayClient.forceReconnect()
            isReconnectingRelay = false
        }
    }

    // MARK: - Periodic Token Refresh

    private func startTokenRefresh() {
        // Refresh auth token every 45 minutes (tokens expire after ~1 hour)
        tokenRefreshTimer = Timer.scheduledTimer(withTimeInterval: 45 * 60, repeats: true) { [weak self] _ in
            Task {
                await self?.refreshAuthToken()
            }
        }
    }

    private func refreshAuthToken() async {
        do {
            let refreshed = try await supabase.auth.refreshSession()
            cachedAuthToken = refreshed.accessToken
            // Update relay client's token so it uses the fresh one
            await relayClient.updateToken(refreshed.accessToken)
            tokenRetryTask = nil
            log("Auth token refreshed successfully")
        } catch {
            log("Auth token refresh failed: \(error.localizedDescription)")
            // Retry once in 5 minutes (e.g., network not ready after wake)
            tokenRetryTask?.cancel()
            tokenRetryTask = Task {
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self.refreshAuthToken()
            }
        }
    }

    // MARK: - Sleep/Wake Monitoring

    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter

        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.log("System going to sleep")
        }

        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.log("System woke from sleep — re-establishing connections")
            Task { @MainActor in
                // Re-acquire sleep prevention (may have been revoked)
                self.preventSleep()

                // Immediately update heartbeat
                await self.updateMachineStatus("online")

                // Force relay reconnection with fresh token
                await self.refreshAuthToken()
                await self.relayClient.forceReconnect()
            }
        }
    }

    private func removeSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        if let sleepObserver { center.removeObserver(sleepObserver) }
        if let wakeObserver { center.removeObserver(wakeObserver) }
        sleepObserver = nil
        wakeObserver = nil
    }

    // MARK: - Slash Command Detection

    /// Scans ~/.claude/commands/, ~/.claude/skills/, and project-level equivalents.
    private nonisolated func scanSlashCommands(workspacePaths: [String]) -> [[String: String]] {
        let fm = FileManager.default
        let home = AgentDetector.realHome
        var commands: [[String: String]] = []
        var seen: Set<String> = []

        // 1. Scan commands (.md files)
        var commandDirs: [String] = ["\(home)/.claude/commands"]
        for path in workspacePaths {
            commandDirs.append("\(path)/.claude/commands")
        }

        for dir in commandDirs {
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in files.sorted() {
                let fullPath = "\(dir)/\(file)"
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                    guard let subfiles = try? fm.contentsOfDirectory(atPath: fullPath) else { continue }
                    let namespace = file
                    for subfile in subfiles.sorted() where subfile.hasSuffix(".md") {
                        let subPath = "\(fullPath)/\(subfile)"
                        let baseName = String(subfile.dropLast(3))
                        let cmdName = "/\(namespace):\(baseName)"
                        guard !seen.contains(cmdName) else { continue }
                        seen.insert(cmdName)
                        let (name, desc) = parseCommandFile(at: subPath, fallbackName: cmdName)
                        commands.append(["name": name, "description": desc])
                    }
                    continue
                }

                guard file.hasSuffix(".md") else { continue }
                let baseName = String(file.dropLast(3))
                let cmdName = "/\(baseName)"
                guard !seen.contains(cmdName) else { continue }
                seen.insert(cmdName)
                let (name, desc) = parseCommandFile(at: fullPath, fallbackName: cmdName)
                commands.append(["name": name, "description": desc])
            }
        }

        // 2. Scan skills (directories with SKILL.md)
        var skillDirs: [String] = ["\(home)/.claude/skills"]
        for path in workspacePaths {
            skillDirs.append("\(path)/.claude/skills")
        }

        for dir in skillDirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries.sorted() {
                let entryPath = "\(dir)/\(entry)"
                // Resolve symlinks (skills are often symlinked)
                let resolved = URL(fileURLWithPath: entryPath).resolvingSymlinksInPath().path
                let skillFile = "\(resolved)/SKILL.md"
                guard fm.fileExists(atPath: skillFile) else { continue }
                let cmdName = "/\(entry)"
                guard !seen.contains(cmdName) else { continue }
                seen.insert(cmdName)
                let (name, desc) = parseCommandFile(at: skillFile, fallbackName: cmdName)
                commands.append(["name": name, "description": desc])
            }
        }

        return commands
    }

    /// Parses a command .md file for YAML frontmatter (name, description).
    private nonisolated func parseCommandFile(at path: String, fallbackName: String) -> (name: String, description: String) {
        // Read only the first 2KB — enough for frontmatter + first content line
        guard let handle = FileHandle(forReadingAtPath: path),
              let data = try? handle.read(upToCount: 2048),
              let content = String(data: data, encoding: .utf8) else {
            return (fallbackName, "")
        }

        var name = fallbackName
        var description = ""

        if content.hasPrefix("---") {
            let lines = content.components(separatedBy: "\n")
            var closedFrontmatter = false
            for i in 1..<lines.count {
                let line = lines[i].trimmingCharacters(in: .whitespaces)
                if line == "---" { closedFrontmatter = true; break }
                if line.hasPrefix("name:") {
                    let val = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if !val.isEmpty { name = "/\(val)" }
                } else if line.hasPrefix("description:") {
                    description = String(line.dropFirst(12).trimmingCharacters(in: .whitespaces).prefix(80))
                }
            }
            // If frontmatter was never closed, discard parsed values as unreliable
            if !closedFrontmatter {
                name = fallbackName
                description = ""
            }
        }

        if description.isEmpty {
            let lines = content.components(separatedBy: "\n")
            var pastFrontmatter = !content.hasPrefix("---")
            var closedFrontmatter = false
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !pastFrontmatter {
                    if trimmed == "---" {
                        if closedFrontmatter { pastFrontmatter = true }
                        else { closedFrontmatter = true }
                    }
                    continue
                }
                if trimmed.isEmpty { continue }
                description = String(trimmed
                    .replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
                    .prefix(80))
                break
            }
        }

        return (name, description)
    }

    /// Broadcasts detected slash commands to all clients or a specific client.
    private func broadcastSlashCommands(to clientId: String? = nil) async {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: detectedSlashCommands),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return }
        let packet = WSPacket(action: .slashCommandsDetected, payload: ["commands": jsonStr])
        if let clientId {
            await sendToClientOrRelay(packet, to: clientId)
        } else {
            await wsServer?.broadcast(packet)
            await relayClient.send(packet: packet)
        }
    }
    // MARK: - DevTools Handlers

    private func handleSystemResources(clientId: String, packet: WSPacket) async {
        var payload: [String: String] = [:]

        // CPU usage via host_statistics (delta between snapshots)
        let host = mach_host_self()
        var loadInfo = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let cpuResult = withUnsafeMutablePointer(to: &loadInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        if cpuResult == KERN_SUCCESS {
            let user = Double(loadInfo.cpu_ticks.0)
            let system = Double(loadInfo.cpu_ticks.1)
            let idle = Double(loadInfo.cpu_ticks.2)
            let nice = Double(loadInfo.cpu_ticks.3)

            if let prev = previousCPUTicks {
                let dUser = user - prev.user
                let dSystem = system - prev.system
                let dIdle = idle - prev.idle
                let dNice = nice - prev.nice
                let dTotal = dUser + dSystem + dIdle + dNice
                let dUsed = dUser + dSystem + dNice
                let cpuPercent = dTotal > 0 ? (dUsed / dTotal) * 100.0 : 0
                payload["cpu_percent"] = String(format: "%.1f", cpuPercent)
            } else {
                // First reading — return 0, next poll will have a delta
                payload["cpu_percent"] = "0"
            }
            previousCPUTicks = (user, system, idle, nice)
        } else {
            payload["cpu_percent"] = "0"
        }
        mach_port_deallocate(mach_task_self_, host)

        // Memory usage via host_statistics64
        var vmInfo = vm_statistics64_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let memResult = withUnsafeMutablePointer(to: &vmInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &vmCount)
            }
        }
        let pageSize = UInt64(vm_kernel_page_size)
        if memResult == KERN_SUCCESS {
            let active = UInt64(vmInfo.active_count) * pageSize
            let wired = UInt64(vmInfo.wire_count) * pageSize
            let compressed = UInt64(vmInfo.compressor_page_count) * pageSize
            let used = active + wired + compressed
            payload["memory_used_bytes"] = String(used)
        } else {
            payload["memory_used_bytes"] = "0"
        }
        let totalMem = ProcessInfo.processInfo.physicalMemory
        payload["memory_total_bytes"] = String(totalMem)

        // Disk usage via FileManager
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/") {
            let totalDisk = (attrs[.systemSize] as? UInt64) ?? 0
            let freeDisk = (attrs[.systemFreeSize] as? UInt64) ?? 0
            payload["disk_total_bytes"] = String(totalDisk)
            payload["disk_used_bytes"] = String(totalDisk - freeDisk)
        } else {
            payload["disk_total_bytes"] = "0"
            payload["disk_used_bytes"] = "0"
        }

        await sendToClientOrRelay(
            WSPacket(action: .systemResourcesResult, payload: payload, id: packet.id),
            to: clientId
        )
    }

    /// Returns PIDs that have open files under the given directory path.
    /// Uses non-recursive `+d` to avoid slow scans on large trees (e.g. node_modules).
    private func pidsForWorkspace(path: String) async -> Set<String> {
        // Race lsof against a 5-second timeout to avoid blocking on large directories
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
                task.arguments = ["-t", "+d", (path as NSString).expandingTildeInPath]
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = Pipe()
                guard (try? task.run()) != nil else {
                    continuation.resume(returning: [])
                    return
                }

                // Timeout: kill lsof if it takes too long
                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now() + 5)
                timer.setEventHandler {
                    if task.isRunning { task.terminate() }
                }
                timer.resume()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                timer.cancel()

                guard task.terminationStatus == 0,
                      let output = String(data: data, encoding: .utf8) else {
                    continuation.resume(returning: [])
                    return
                }
                let pids = Set(output.components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty })
                continuation.resume(returning: pids)
            }
        }
    }

    private func handleProcessList(clientId: String, packet: WSPacket) async {
        let workspacePath = packet.payload?["path"]
        let workspacePids: Set<String>?
        if let wp = workspacePath {
            workspacePids = await pidsForWorkspace(path: wp)
        } else {
            workspacePids = nil
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["aux"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            // Read before waiting to avoid pipe buffer deadlock
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else {
                await sendToClientOrRelay(
                    WSPacket(action: .processListResult, payload: ["error": "Failed to read process list"], id: packet.id),
                    to: clientId
                )
                return
            }

            let lines = output.components(separatedBy: "\n").dropFirst() // Skip header
            var processes: [[String: String]] = []
            for line in lines {
                let cols = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: true)
                guard cols.count >= 11 else { continue }
                let pid = String(cols[1])

                // If workspace filter is active, skip PIDs not in workspace
                if let allowedPids = workspacePids, !allowedPids.contains(pid) { continue }

                let cpu = String(cols[2])
                // VSZ is cols[4] in KB, RSS is cols[5] in KB — use RSS for actual memory
                let rssKB = Double(String(cols[5])) ?? 0
                let memMB = String(format: "%.1f", rssKB / 1024.0)
                let name = String(cols[10]).components(separatedBy: "/").last ?? String(cols[10])
                processes.append([
                    "name": name,
                    "pid": pid,
                    "cpu": cpu,
                    "memory_mb": memMB,
                ])
            }

            if let jsonData = try? JSONSerialization.data(withJSONObject: processes),
               let json = String(data: jsonData, encoding: .utf8) {
                await sendToClientOrRelay(
                    WSPacket(action: .processListResult, payload: ["processes": json], id: packet.id),
                    to: clientId
                )
            }
        } catch {
            await sendToClientOrRelay(
                WSPacket(action: .processListResult, payload: ["error": error.localizedDescription], id: packet.id),
                to: clientId
            )
        }
    }

    private func handleProcessKill(clientId: String, packet: WSPacket) async {
        guard let pidStr = packet.payload?["pid"], let pid = Int32(pidStr), pid > 1 else {
            await sendToClientOrRelay(
                WSPacket(action: .processKillResult, payload: ["success": "false", "error": "Invalid or protected PID"], id: packet.id),
                to: clientId
            )
            return
        }

        // Don't allow killing our own process
        if pid == ProcessInfo.processInfo.processIdentifier {
            await sendToClientOrRelay(
                WSPacket(action: .processKillResult, payload: ["success": "false", "error": "Cannot kill Tarsy daemon"], id: packet.id),
                to: clientId
            )
            return
        }

        let result = kill(pid, SIGTERM)
        if result == 0 {
            // Wait briefly, then check if still alive and send SIGKILL
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let stillAlive = kill(pid, 0) == 0
            if stillAlive {
                kill(pid, SIGKILL)
            }
            await sendToClientOrRelay(
                WSPacket(action: .processKillResult, payload: ["success": "true", "pid": pidStr], id: packet.id),
                to: clientId
            )
        } else {
            let errorMsg = String(cString: strerror(errno))
            await sendToClientOrRelay(
                WSPacket(action: .processKillResult, payload: ["success": "false", "pid": pidStr, "error": errorMsg], id: packet.id),
                to: clientId
            )
        }
    }

    private func handlePortsList(clientId: String, packet: WSPacket) async {
        let workspacePath = packet.payload?["path"]
        let workspacePids: Set<String>?
        if let wp = workspacePath {
            workspacePids = await pidsForWorkspace(path: wp)
        } else {
            workspacePids = nil
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-i", "-P", "-n", "-sTCP:LISTEN"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            // Read before waiting to avoid pipe buffer deadlock
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else {
                await sendToClientOrRelay(
                    WSPacket(action: .portsListResult, payload: ["error": "Failed to read ports"], id: packet.id),
                    to: clientId
                )
                return
            }

            let lines = output.components(separatedBy: "\n").dropFirst() // Skip header
            var ports: [[String: String]] = []
            var seenPorts = Set<String>()
            for line in lines {
                let cols = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
                guard cols.count >= 9 else { continue }
                let name = String(cols[0])
                let pid = String(cols[1])

                // If workspace filter is active, skip PIDs not in workspace
                if let allowedPids = workspacePids, !allowedPids.contains(pid) { continue }

                let address = String(cols[8])
                // Parse port from address like "*:3000" or "127.0.0.1:8080"
                if let portStr = address.split(separator: ":").last {
                    let port = String(portStr)
                    let key = "\(port)-\(pid)"
                    if !seenPorts.contains(key) {
                        seenPorts.insert(key)
                        ports.append([
                            "port": port,
                            "process_name": name,
                            "pid": pid,
                        ])
                    }
                }
            }

            if let jsonData = try? JSONSerialization.data(withJSONObject: ports),
               let json = String(data: jsonData, encoding: .utf8) {
                await sendToClientOrRelay(
                    WSPacket(action: .portsListResult, payload: ["ports": json], id: packet.id),
                    to: clientId
                )
            }
        } catch {
            await sendToClientOrRelay(
                WSPacket(action: .portsListResult, payload: ["error": error.localizedDescription], id: packet.id),
                to: clientId
            )
        }
    }

    private func handleHTTPRequest(clientId: String, packet: WSPacket) async {
        guard let urlStr = packet.payload?["url"],
              let url = URL(string: urlStr) else {
            await sendToClientOrRelay(
                WSPacket(action: .httpResponse, payload: ["error": "Invalid URL"], id: packet.id),
                to: clientId
            )
            return
        }

        // Only allow loopback hosts for security
        let allowedHosts: Set<String> = ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"]
        guard let host = url.host, allowedHosts.contains(host) else {
            await sendToClientOrRelay(
                WSPacket(action: .httpResponse, payload: ["error": "Only localhost requests are allowed"], id: packet.id),
                to: clientId
            )
            return
        }

        let method = packet.payload?["method"]?.uppercased() ?? "GET"
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30

        // Parse headers
        if let headersJson = packet.payload?["headers"],
           let headersData = headersJson.data(using: .utf8),
           let headers = try? JSONSerialization.jsonObject(with: headersData) as? [String: String] {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        // Body for POST
        if method == "POST", let body = packet.payload?["body"] {
            request.httpBody = body.data(using: .utf8)
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        let session = URLSession(configuration: .ephemeral, delegate: LoopbackRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        do {
            let (data, response) = try await session.data(for: request)
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            guard let httpResponse = response as? HTTPURLResponse else {
                await sendToClientOrRelay(
                    WSPacket(action: .httpResponse, payload: ["error": "Not an HTTP response"], id: packet.id),
                    to: clientId
                )
                return
            }

            let bodyStr = String(data: data, encoding: .utf8) ?? "(binary data, \(data.count) bytes)"
            var responseHeaders: [String: String] = [:]
            for (key, value) in httpResponse.allHeaderFields {
                responseHeaders[String(describing: key)] = String(describing: value)
            }
            let headersJson = (try? JSONSerialization.data(withJSONObject: responseHeaders)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

            await sendToClientOrRelay(
                WSPacket(action: .httpResponse, payload: [
                    "status_code": String(httpResponse.statusCode),
                    "headers": headersJson,
                    "body": bodyStr,
                    "duration_ms": String(elapsed),
                ], id: packet.id),
                to: clientId
            )
        } catch {
            await sendToClientOrRelay(
                WSPacket(action: .httpResponse, payload: ["error": error.localizedDescription], id: packet.id),
                to: clientId
            )
        }
    }
}

// MARK: - SSRF Redirect Guard

/// URLSession delegate that blocks redirects to non-loopback hosts.
private class LoopbackRedirectGuard: NSObject, URLSessionTaskDelegate {
    private let allowedHosts: Set<String> = ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"]

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let host = request.url?.host, allowedHosts.contains(host) {
            completionHandler(request)
        } else {
            // Block redirect to non-loopback host
            completionHandler(nil)
        }
    }
}
