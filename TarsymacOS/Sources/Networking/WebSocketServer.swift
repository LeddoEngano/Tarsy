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

    /// The machineId this server belongs to — used to validate auth packets
    var machineId: UUID?

    /// Auth failure rate limiting by IP: tracks failure count and optional ban expiry
    private var authFailures: [String: (count: Int, firstFailure: Date, bannedUntil: Date?)] = [:]
    /// Called on successful auth with the auth packet. Returns extra fields to include in authSuccess.
    private var onAuthSuccess: (@Sendable (WSPacket) async -> [String: String])?

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
        onDisconnect: @escaping @Sendable (String) -> Void,
        onAuthSuccess: @escaping @Sendable (WSPacket) async -> [String: String] = { _ in [:] }
    ) {
        self.onPacketReceived = onPacket
        self.onClientConnected = onConnect
        self.onClientDisconnected = onDisconnect
        self.onAuthSuccess = onAuthSuccess
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
                .TLSv13
            )

            let tcpOptions = NWProtocolTCP.Options()
            parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)

            certificateFingerprint = TLSCertificateManager.shared.certificateFingerprint()
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
                    continuation.resume()
                case .failed(let error):
                    resumed = true
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
    }

    func send(_ packet: WSPacket, to clientId: String) {
        guard let connection = connections[clientId],
              let data = try? packet.encode() else { return }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "ws", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    func broadcast(_ packet: WSPacket) {
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

    /// Checks if a remote endpoint is from a local/private network (RFC 1918, loopback, Tailscale).
    /// Rejects connections from public IPs to prevent exposure if the Mac lacks a firewall.
    private nonisolated func isLocalNetwork(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return true }
        let hostStr = "\(host)"

        // Loopback
        if hostStr == "127.0.0.1" || hostStr == "::1" || hostStr.hasPrefix("127.") { return true }
        // RFC 1918
        if hostStr.hasPrefix("10.") { return true }
        if hostStr.hasPrefix("192.168.") { return true }
        if hostStr.hasPrefix("172.") {
            let parts = hostStr.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) { return true }
        }
        // Link-local
        if hostStr.hasPrefix("169.254.") { return true }
        if hostStr.hasPrefix("fe80:") { return true }
        // Tailscale CGNAT range (100.64.0.0/10)
        if hostStr.hasPrefix("100.") {
            let parts = hostStr.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (64...127).contains(second) { return true }
        }
        return false
    }

    /// Extract IP string from a connection's remote endpoint
    private nonisolated func extractIP(from endpoint: NWEndpoint?) -> String {
        guard case let .hostPort(host, _) = endpoint else { return "unknown" }
        return "\(host)"
    }

    /// Check if an IP is currently banned due to auth failure rate limiting
    private func isIPBanned(_ ip: String) -> Bool {
        guard let entry = authFailures[ip] else { return false }
        if let bannedUntil = entry.bannedUntil {
            if Date() < bannedUntil { return true }
            // Ban expired, clear entry
            authFailures.removeValue(forKey: ip)
        }
        return false
    }

    /// Record an auth failure for rate limiting. Returns true if the IP is now banned.
    private func recordAuthFailure(ip: String) -> Bool {
        let now = Date()
        var entry = authFailures[ip] ?? (count: 0, firstFailure: now, bannedUntil: nil)

        // Reset counter if the window (60s) has passed
        if now.timeIntervalSince(entry.firstFailure) > 60 {
            entry = (count: 0, firstFailure: now, bannedUntil: nil)
        }

        entry.count += 1

        if entry.count >= 3 {
            // Ban for 5 minutes
            entry.bannedUntil = now.addingTimeInterval(300)
            authFailures[ip] = entry
            // IP banned for 5 minutes after repeated auth failures
            return true
        }

        authFailures[ip] = entry
        return false
    }

    private func handleNewConnection(_ connection: NWConnection) {
        // Reject connections from public IPs
        if let remote = connection.currentPath?.remoteEndpoint, !isLocalNetwork(remote) {
            connection.cancel()
            return
        }

        // Check if IP is banned due to auth failure rate limiting
        let ip = extractIP(from: connection.currentPath?.remoteEndpoint)
        if isIPBanned(ip) {
            connection.cancel()
            return
        }

        let clientId = UUID().uuidString
        connections[clientId] = connection

        connection.start(queue: .global(qos: .userInitiated))
        receiveLoop(connection: connection, clientId: clientId, authenticated: false, clientIP: ip)

        // Auth timeout: disconnect if not authenticated within 3 seconds
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard await self.connections[clientId] != nil else { return }
            guard await !self.authenticatedClients.contains(clientId) else { return }
            await self.send(WSPacket(action: .authFail, payload: ["reason": "auth timeout"]), to: clientId)
            await self.removeConnection(clientId)
        }

    }

    private func receiveLoop(connection: NWConnection, clientId: String, authenticated: Bool, clientIP: String = "unknown") {
        connection.receiveMessage { [weak self] content, context, _, error in
            Task {
                guard let self else { return }

                if error != nil {
                    await self.removeConnection(clientId)
                    return
                }

                guard let data = content else {
                    // No data but no error — continue listening
                    await self.receiveLoop(connection: connection, clientId: clientId, authenticated: authenticated, clientIP: clientIP)
                    return
                }

                guard let packet = try? WSPacket.decode(from: data) else {
                    await self.receiveLoop(connection: connection, clientId: clientId, authenticated: authenticated, clientIP: clientIP)
                    return
                }

                if !authenticated {
                    if packet.action == .auth, let token = packet.payload?["token"] {
                        // Validate machineId if set on this server
                        if let expectedMachineId = await self.machineId {
                            let packetMachineId = packet.payload?["machineId"]
                            if packetMachineId != expectedMachineId.uuidString {
                                let _ = await self.recordAuthFailure(ip: clientIP)
                                await self.send(WSPacket(action: .authFail, payload: ["reason": "invalid machineId"]), to: clientId)
                                await self.removeConnection(clientId)
                                return
                            }
                        }

                        let valid = await self.validateToken(token)
                        if valid {
                            await self.markAuthenticated(clientId)
                            var authPayload: [String: String] = [:]
                            if let fp = await self.certificateFingerprint {
                                authPayload["fingerprint"] = fp
                            }
                            // Let DaemonManager handle E2E key exchange and add extra fields
                            let extraFields = await self.onAuthSuccess?(packet) ?? [:]
                            authPayload.merge(extraFields) { _, new in new }
                            await self.send(WSPacket(action: .authSuccess, payload: authPayload.isEmpty ? nil : authPayload), to: clientId)
                            await self.onClientConnected?(clientId)
                            await self.receiveLoop(connection: connection, clientId: clientId, authenticated: true, clientIP: clientIP)
                        } else {
                            let banned = await self.recordAuthFailure(ip: clientIP)
                            await self.send(WSPacket(action: .authFail), to: clientId)
                            await self.removeConnection(clientId)
                        }
                    } else {
                        await self.send(WSPacket(action: .authFail, payload: ["reason": "not authenticated"]), to: clientId)
                        await self.removeConnection(clientId)
                    }
                    return
                }

                if packet.action == .ping {
                    await self.send(WSPacket(action: .pong, id: packet.id), to: clientId)
                    await self.receiveLoop(connection: connection, clientId: clientId, authenticated: true, clientIP: clientIP)
                    return
                }

                // Fire-and-forget: don't block the receive loop waiting for packet handling.
                // This allows new messages (like sudoResponse) to arrive while a handler is suspended.
                let handler = await self.getPacketHandler()
                if let handler {
                    Task { await handler(clientId, packet) }
                }
                await self.receiveLoop(connection: connection, clientId: clientId, authenticated: true, clientIP: clientIP)
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
