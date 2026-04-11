import Foundation
import TarsyShared

actor RelayClient {
    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var isConnected = false
    private var reconnectAttempts = 0

    private var onPacketReceived: (@Sendable (WSPacket) -> Void)?
    private var onBinaryReceived: (@Sendable (Data) -> Void)?
    /// Callback: (isConnected, reconnectAttempt) — attempt is 0 when connected
    private var onConnectionStateChanged: (@Sendable (Bool, Int) -> Void)?

    private var authToken: String?
    /// Signed-timestamp machine auth identity. When set, connect() will
    /// populate `machine_id`, `timestamp`, `signature`, and `machinePublicKey`
    /// in the auth payload. The relay verifies the signature against the
    /// stored public key in machine_tokens.public_key.
    private var machineIdentity: MachineAuthIdentity?
    private var isReconnecting = false
    private var pingTask: Task<Void, Never>?
    private var isIntentionalDisconnect = false
    private var reconnectGeneration = 0

    func setHandlers(
        onPacket: @escaping @Sendable (WSPacket) -> Void,
        onBinary: @escaping @Sendable (Data) -> Void = { _ in },
        onConnectionStateChanged: @escaping @Sendable (Bool, Int) -> Void = { _, _ in }
    ) {
        self.onPacketReceived = onPacket
        self.onBinaryReceived = onBinary
        self.onConnectionStateChanged = onConnectionStateChanged
    }

    var connected: Bool { isConnected }

    func connect(
        token: String,
        machineIdentity: MachineAuthIdentity? = nil
    ) async {
        self.authToken = token
        if let machineIdentity { self.machineIdentity = machineIdentity }
        isIntentionalDisconnect = false
        // Only reset reconnect attempts on explicit connect (not reconnect)
        if !isReconnecting {
            reconnectAttempts = 0
        }
        isReconnecting = false

        await performConnect(token: token)
    }

    private func performConnect(token: String) async {
        let baseURL = TarsyConfig.relayURL

        guard let url = URL(string: baseURL) else { return }

        // Bump generation so any in-flight receive callbacks from the old socket are ignored
        reconnectGeneration += 1
        let currentGen = reconnectGeneration

        // Cancel any existing connection and ping task
        stopPing()
        webSocket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()

        let newSession = URLSession(configuration: .default)
        session = newSession
        let ws = newSession.webSocketTask(with: url)
        ws.maximumMessageSize = 4 * 1024 * 1024 // 4MB
        self.webSocket = ws
        ws.resume()

        // Build signed-timestamp auth payload. The relay expects:
        // machine_id, timestamp, signature, machinePublicKey. If we don't
        // have a machineIdentity we still attempt to connect (the relay will
        // reject with "Machine credentials required") — this lets the daemon
        // log a clean error during an initial bootstrap failure instead of
        // silently refusing to touch the WebSocket.
        var auth: [String: Any] = ["action": "auth", "token": token, "role": "machine"]
        if let identity = machineIdentity {
            // Fresh timestamp on every (re)connect — freshness window is ±60s
            // on the relay side. Milliseconds to match Date.now() in JS.
            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            let canonical = "\(identity.machineId):\(timestamp):\(identity.userId)"
            if let canonicalData = canonical.data(using: .utf8) {
                do {
                    let signature = try await identity.signer(canonicalData)
                    auth["machine_id"] = identity.machineId
                    auth["timestamp"] = timestamp
                    auth["signature"] = signature.base64EncodedString()
                    auth["machinePublicKey"] = identity.publicKeyDER.base64EncodedString()
                } catch {
                    #if DEBUG
                    print("[RelayClient] signing failed: \(error) — falling back to legacy secret only")
                    #endif
                }
            }
        }

        if let data = try? JSONSerialization.data(withJSONObject: auth),
           let str = String(data: data, encoding: .utf8) {
            ws.send(.string(str)) { _ in }
        }

        receiveLoop(generation: currentGen)
    }

    func disconnect() {
        isIntentionalDisconnect = true
        stopPing()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        session?.invalidateAndCancel()
        session = nil
        let wasConnected = isConnected
        isConnected = false
        reconnectAttempts = 0
        isReconnecting = false
        if wasConnected {
            onConnectionStateChanged?(false, 0)
        }
    }

    /// Update the auth token without reconnecting (used for periodic token refresh)
    func updateToken(_ token: String) {
        self.authToken = token
    }

    func send(packet: WSPacket) {
        guard let ws = webSocket else { return }
        do {
            let data = try packet.encode()
            guard let str = String(data: data, encoding: .utf8) else { return }
            let message = URLSessionWebSocketTask.Message.string(str)
            ws.send(message) { _ in }
        } catch { }
    }

    func sendBinary(_ data: Data) {
        guard let ws = webSocket else { return }
        let message = URLSessionWebSocketTask.Message.data(data)
        ws.send(message) { _ in }
    }

    func sendBinary(_ data: Data, completion: @escaping @Sendable () -> Void) {
        guard let ws = webSocket else { completion(); return }
        let message = URLSessionWebSocketTask.Message.data(data)
        ws.send(message) { _ in completion() }
    }

    // MARK: - Ping/Pong Keep-Alive

    private func startPing() {
        stopPing()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000) // 30 seconds
                guard !Task.isCancelled else { break }
                guard let self else { break }
                await self.sendPing()
            }
        }
    }

    private func stopPing() {
        pingTask?.cancel()
        pingTask = nil
    }

    private func sendPing() {
        guard let ws = webSocket else { return }
        ws.sendPing { [weak self] error in
            if error != nil {
                // Connection is dead — trigger reconnection
                Task { await self?.handleDeadConnection() }
            }
        }
    }

    private func handleDeadConnection() {
        guard isConnected else { return } // Already handling reconnection
        isConnected = false
        stopPing()
        onConnectionStateChanged?(false, reconnectAttempts)
        scheduleReconnect()
    }

    // MARK: - Receive Loop

    private func receiveLoop(generation: Int) {
        guard let ws = webSocket, generation == reconnectGeneration else { return }

        ws.receive { [weak self] result in
            Task { await self?.handleReceive(result, generation: generation) }
        }
    }

    private func handleReceive(_ result: Result<URLSessionWebSocketTask.Message, Error>, generation: Int) {
        // Ignore callbacks from superseded connections
        guard generation == reconnectGeneration else { return }

        switch result {
        case .success(let message):
            if !isConnected {
                isConnected = true
                reconnectAttempts = 0
                startPing()
                onConnectionStateChanged?(true, 0)
            }
            switch message {
            case .string(let text):
                if let data = text.data(using: .utf8),
                   let packet = try? WSPacket.decode(from: data) {
                    onPacketReceived?(packet)
                }
            case .data(let data):
                onBinaryReceived?(data)
            @unknown default:
                break
            }
            receiveLoop(generation: generation) // Continue listening

        case .failure(let error):
            #if DEBUG
            print("[RelayClient] Receive failed: \(error.localizedDescription)")
            #endif
            let wasConnected = isConnected
            isConnected = false
            stopPing()
            if wasConnected {
                onConnectionStateChanged?(false, reconnectAttempts)
            }
            if !isIntentionalDisconnect {
                scheduleReconnect()
            }
        }
    }

    // MARK: - Reconnect (infinite with exponential backoff + jitter)

    private func scheduleReconnect() {
        guard !isIntentionalDisconnect else { return }

        reconnectAttempts += 1
        let gen = reconnectGeneration

        // Exponential backoff: 2, 4, 8, 16, 32, 60, 60, 60...
        // With jitter to avoid thundering herd
        let baseDelay = min(pow(2.0, Double(reconnectAttempts)), 60.0)
        let jitter = Double.random(in: 0...min(baseDelay * 0.3, 10.0))
        let delay = baseDelay + jitter

        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)

            guard !isIntentionalDisconnect else { return }
            guard reconnectGeneration == gen else { return } // Superseded by forceReconnect

            // Force token refresh before reconnecting
            do {
                let refreshed = try await supabase.auth.refreshSession()
                let token = refreshed.accessToken
                self.authToken = token
                self.isReconnecting = true
                await self.performConnect(token: token)
            } catch {
                // Token refresh failed — retry with existing token if we have one
                if let existingToken = self.authToken {
                    self.isReconnecting = true
                    await self.performConnect(token: existingToken)
                } else {
                    // No token at all — keep trying
                    scheduleReconnect()
                }
            }
        }
    }

    /// Force an immediate reconnection (e.g., after wake from sleep or token refresh)
    func forceReconnect() async {
        guard !isIntentionalDisconnect else { return }
        reconnectGeneration += 1 // Invalidate any pending scheduleReconnect
        reconnectAttempts = 0
        stopPing()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        isConnected = false
        isReconnecting = false

        // Get fresh token and reconnect
        do {
            let refreshed = try await supabase.auth.refreshSession()
            let token = refreshed.accessToken
            self.authToken = token
            await performConnect(token: token)
        } catch {
            if let token = authToken {
                await performConnect(token: token)
                return
            }
            scheduleReconnect()
        }
    }
}
