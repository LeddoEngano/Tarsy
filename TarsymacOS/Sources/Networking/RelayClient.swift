import Foundation
import TarsyShared

actor RelayClient {
    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var isConnected = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 20

    private var onPacketReceived: (@Sendable (WSPacket) -> Void)?
    private var onBinaryReceived: (@Sendable (Data) -> Void)?

    private var authToken: String?
    private var machineSecret: String?
    private var isReconnecting = false

    func setHandlers(
        onPacket: @escaping @Sendable (WSPacket) -> Void,
        onBinary: @escaping @Sendable (Data) -> Void = { _ in }
    ) {
        self.onPacketReceived = onPacket
        self.onBinaryReceived = onBinary
    }

    func connect(token: String, machineSecret: String? = nil) async {
        self.authToken = token
        if let machineSecret { self.machineSecret = machineSecret }
        // Only reset reconnect attempts on explicit connect (not reconnect)
        if !isReconnecting {
            reconnectAttempts = 0
        }
        isReconnecting = false

        performConnect(token: token)
    }

    private func performConnect(token: String) {
        let baseURL = TarsyConfig.relayURL

        guard let url = URL(string: baseURL) else { return }

        // Cancel any existing connection
        webSocket?.cancel(with: .goingAway, reason: nil)

        let newSession = URLSession(configuration: .default)
        session = newSession
        let ws = newSession.webSocketTask(with: url)
        ws.maximumMessageSize = 4 * 1024 * 1024 // 4MB
        self.webSocket = ws
        ws.resume()

        // Send auth as first message (token not in URL, machineSecret for role verification)
        var auth: [String: String] = ["action": "auth", "token": token, "role": "machine"]
        if let secret = machineSecret { auth["machineSecret"] = secret }
        if let data = try? JSONSerialization.data(withJSONObject: auth),
           let str = String(data: data, encoding: .utf8) {
            ws.send(.string(str)) { _ in }
        }

        receiveLoop()
    }

    func disconnect() {
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        isConnected = false
        reconnectAttempts = 0
        isReconnecting = false
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

    // MARK: - Receive Loop

    private func receiveLoop() {
        guard let ws = webSocket else { return }

        ws.receive { [weak self] result in
            Task { await self?.handleReceive(result) }
        }
    }

    private func handleReceive(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        switch result {
        case .success(let message):
            if !isConnected {
                isConnected = true
                reconnectAttempts = 0
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
            receiveLoop() // Continue listening

        case .failure:
            isConnected = false
            scheduleReconnect()
        }
    }

    // MARK: - Reconnect

    private func scheduleReconnect() {
        guard reconnectAttempts < maxReconnectAttempts else { return }

        reconnectAttempts += 1
        let delay = min(reconnectAttempts * 2, 30)

        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)

            // Force token refresh before reconnecting
            do {
                let refreshed = try await supabase.auth.refreshSession()
                let token = refreshed.accessToken
                self.authToken = token
                self.isReconnecting = true
                self.performConnect(token: token)
            } catch {
                if reconnectAttempts < maxReconnectAttempts {
                    scheduleReconnect()
                }
            }
        }
    }
}
