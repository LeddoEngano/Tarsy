import Foundation
import Network
import TarsyShared

actor WebSocketServer {
    private var listener: NWListener?
    private var connections: [String: NWConnection] = [:]
    private let port: UInt16
    private let validateToken: @Sendable (String) async -> Bool
    private let tlsEnabled: Bool

    private var authenticatedClients: Set<String> = []
    private var onPacketReceived: (@Sendable (String, WSPacket) async -> Void)?
    private var onClientConnected: (@Sendable (String) -> Void)?
    private var onClientDisconnected: (@Sendable (String) -> Void)?

    /// The SHA-256 fingerprint of the TLS certificate (available after start if TLS is enabled)
    private(set) var certificateFingerprint: String?

    init(port: UInt16 = TarsyConfig.websocketPort, tlsEnabled: Bool = true, validateToken: @escaping @Sendable (String) async -> Bool) {
        self.port = port
        self.tlsEnabled = tlsEnabled
        self.validateToken = validateToken
    }

    func getPacketHandler() -> (@Sendable (String, WSPacket) async -> Void)? {
        return onPacketReceived
    }

    func setHandlers(
        onPacket: @escaping @Sendable (String, WSPacket) async -> Void,
        onConnect: @escaping @Sendable (String) -> Void,
        onDisconnect: @escaping @Sendable (String) -> Void
    ) {
        self.onPacketReceived = onPacket
        self.onClientConnected = onConnect
        self.onClientDisconnected = onDisconnect
    }

    func start() async throws {
        // Kill any lingering process on our port before binding
        killProcessOnPort(port)

        let parameters: NWParameters

        if tlsEnabled, let identity = TLSCertificateManager.shared.getOrCreateIdentity() {
            // Configure TLS with self-signed certificate
            let tlsOptions = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(
                tlsOptions.securityProtocolOptions,
                sec_identity_create(identity)!
            )
            sec_protocol_options_set_min_tls_protocol_version(
                tlsOptions.securityProtocolOptions,
                .TLSv12
            )

            let tcpOptions = NWProtocolTCP.Options()
            parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)

            certificateFingerprint = TLSCertificateManager.shared.certificateFingerprint()
            print("[WSServer] TLS enabled, fingerprint: \(certificateFingerprint ?? "unknown")")
        } else if tlsEnabled {
            throw NWError.posix(.ENOTSUP)
        } else {
            parameters = NWParameters.tcp
        }

        let wsOptions = NWProtocolWebSocket.Options()
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let newListener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)

        // Use a continuation to wait for the listener to actually start or fail
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false

            newListener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    print("[WSServer] Listening on port \(self.port)")
                    continuation.resume()
                case .failed(let error):
                    resumed = true
                    print("[WSServer] Failed to start on port \(self.port): \(error)")
                    continuation.resume(throwing: error)
                case .cancelled:
                    resumed = true
                    continuation.resume(throwing: NWError.posix(.ECANCELED))
                default:
                    break
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                Task {
                    await self?.handleNewConnection(connection)
                }
            }

            newListener.start(queue: .global(qos: .userInitiated))
        }

        self.listener = newListener
    }

    func stop() {
        listener?.cancel()
        for (_, connection) in connections {
            connection.cancel()
        }
        connections.removeAll()
        authenticatedClients.removeAll()
        print("[WSServer] Stopped")
    }

    func send(_ packet: WSPacket, to clientId: String) {
        guard let connection = connections[clientId],
              let data = try? packet.encode() else { return }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "ws", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    func broadcast(_ packet: WSPacket) {
        print("[WSServer] Broadcasting \(packet.action.rawValue) to \(connections.count) clients: \(Array(connections.keys))")
        for clientId in connections.keys {
            send(packet, to: clientId)
        }
    }

    /// Send raw binary data to a specific client (for H.264 frames)
    func sendBinary(_ data: Data, to clientId: String) {
        guard let connection = connections[clientId] else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "ws-binary", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    /// Send raw binary data to all connected clients
    func broadcastBinary(_ data: Data) {
        for clientId in connections.keys {
            sendBinary(data, to: clientId)
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        let clientId = UUID().uuidString
        connections[clientId] = connection

        connection.start(queue: .global(qos: .userInitiated))
        receiveLoop(connection: connection, clientId: clientId, authenticated: false)

        // Auth timeout: disconnect if not authenticated within 5 seconds
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            // If the client is still connected but never authenticated,
            // the receive loop will still have authenticated: false.
            // We check if the connection is still in our map — if so and
            // the connection state isn't ready (already removed), skip.
            guard await self.connections[clientId] != nil else { return }
            // We can't track auth state externally from the receive loop,
            // so we use a dedicated set.
            guard await !self.authenticatedClients.contains(clientId) else { return }
            print("[WSServer] Client \(clientId) auth timeout (5s), disconnecting")
            await self.send(WSPacket(action: .authFail, payload: ["reason": "auth timeout"]), to: clientId)
            await self.removeConnection(clientId)
        }

        print("[WSServer] Client connected: \(clientId)")
    }

    private func receiveLoop(connection: NWConnection, clientId: String, authenticated: Bool) {
        connection.receiveMessage { [weak self] content, context, _, error in
            Task {
                guard let self else { return }

                if let error {
                    print("[WSServer] Receive error: \(error)")
                    await self.removeConnection(clientId)
                    return
                }

                guard let data = content else {
                    // No data but no error — continue listening
                    await self.receiveLoop(connection: connection, clientId: clientId, authenticated: authenticated)
                    return
                }

                guard let packet = try? WSPacket.decode(from: data) else {
                    // Log the raw data for debugging unknown actions
                    let raw = String(data: data, encoding: .utf8) ?? "<binary \(data.count) bytes>"
                    print("[WSServer] Failed to decode packet from \(clientId): \(raw.prefix(300))")
                    await self.receiveLoop(connection: connection, clientId: clientId, authenticated: authenticated)
                    return
                }

                if !authenticated {
                    if packet.action == .auth, let token = packet.payload?["token"] {
                        let valid = await self.validateToken(token)
                        if valid {
                            await self.markAuthenticated(clientId)
                            print("[WSServer] Client \(clientId) authenticated")
                            var authPayload: [String: String] = [:]
                            if let fp = await self.certificateFingerprint {
                                authPayload["fingerprint"] = fp
                            }
                            await self.send(WSPacket(action: .authSuccess, payload: authPayload.isEmpty ? nil : authPayload), to: clientId)
                            await self.onClientConnected?(clientId)
                            await self.receiveLoop(connection: connection, clientId: clientId, authenticated: true)
                        } else {
                            print("[WSServer] Client \(clientId) auth failed")
                            await self.send(WSPacket(action: .authFail), to: clientId)
                            await self.removeConnection(clientId)
                        }
                    } else {
                        print("[WSServer] Client \(clientId) sent non-auth packet while unauthenticated, disconnecting")
                        await self.send(WSPacket(action: .authFail, payload: ["reason": "not authenticated"]), to: clientId)
                        await self.removeConnection(clientId)
                    }
                    return
                }

                if packet.action == .ping {
                    await self.send(WSPacket(action: .pong, id: packet.id), to: clientId)
                    await self.receiveLoop(connection: connection, clientId: clientId, authenticated: true)
                    return
                }

                print("[WSServer] Received: \(packet.action.rawValue) from \(clientId)")
                // Fire-and-forget: don't block the receive loop waiting for packet handling.
                // This allows new messages (like sudoResponse) to arrive while a handler is suspended.
                let handler = await self.getPacketHandler()
                if let handler {
                    Task { await handler(clientId, packet) }
                }
                await self.receiveLoop(connection: connection, clientId: clientId, authenticated: true)
            }
        }
    }

    private func markAuthenticated(_ clientId: String) {
        authenticatedClients.insert(clientId)
    }

    private func removeConnection(_ clientId: String) {
        connections[clientId]?.cancel()
        connections.removeValue(forKey: clientId)
        authenticatedClients.remove(clientId)
        onClientDisconnected?(clientId)
        print("[WSServer] Client disconnected: \(clientId)")
    }

    // MARK: - Port Cleanup

    /// Kills any process currently listening on the given port so we can bind to it.
    private nonisolated func killProcessOnPort(_ port: UInt16) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-ti", "tcp:\(port)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else { return }
            // Kill each PID found (except our own)
            let myPid = ProcessInfo.processInfo.processIdentifier
            for pidStr in output.components(separatedBy: "\n") {
                if let pid = Int32(pidStr.trimmingCharacters(in: .whitespaces)), pid != myPid {
                    print("[WSServer] Killing stale process \(pid) on port \(port)")
                    kill(pid, SIGTERM)
                }
            }
            // Give it a moment to release the port
            Thread.sleep(forTimeInterval: 0.3)
        } catch {
            // Silently ignore — lsof may not find anything
        }
    }
}
