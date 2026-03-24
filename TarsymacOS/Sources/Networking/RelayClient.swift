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

    func setHandlers(
        onPacket: @escaping @Sendable (WSPacket) -> Void,
        onBinary: @escaping @Sendable (Data) -> Void = { _ in }
    ) {
        self.onPacketReceived = onPacket
        self.onBinaryReceived = onBinary
    }

    func connect(token: String) async {
        self.authToken = token

        // Use dev URL for local testing, prod for release
        let baseURL = TarsyConfig.relayURL

        guard let url = URL(string: "\(baseURL)?token=\(token)&role=machine") else {
            print("[Relay] Invalid URL")
            return
        }

        print("[Relay] Connecting to \(baseURL)...")

        session = URLSession(configuration: .default)
        let ws = session!.webSocketTask(with: url)
        self.webSocket = ws
        ws.resume()

        isConnected = true
        reconnectAttempts = 0
        print("[Relay] Connected as machine")

        receiveLoop()
    }

    func disconnect() {
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        isConnected = false
        print("[Relay] Disconnected")
    }

    func send(packet: WSPacket) {
        guard let ws = webSocket else { return }
        do {
            let data = try packet.encode()
            let message = URLSessionWebSocketTask.Message.string(String(data: data, encoding: .utf8)!)
            ws.send(message) { error in
                if let error {
                    print("[Relay] Send error: \(error)")
                }
            }
        } catch {
            print("[Relay] Encode error: \(error)")
        }
    }

    func sendBinary(_ data: Data) {
        guard let ws = webSocket else { return }
        let message = URLSessionWebSocketTask.Message.data(data)
        ws.send(message) { error in
            if let error {
                print("[Relay] Binary send error: \(error)")
            }
        }
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

        case .failure(let error):
            print("[Relay] Receive error: \(error)")
            isConnected = false
            scheduleReconnect()
        }
    }

    // MARK: - Reconnect

    private func scheduleReconnect() {
        guard reconnectAttempts < maxReconnectAttempts, let token = authToken else {
            print("[Relay] Max reconnect attempts reached")
            return
        }

        reconnectAttempts += 1
        let delay = min(reconnectAttempts * 2, 30)
        print("[Relay] Reconnecting in \(delay)s (attempt \(reconnectAttempts))")

        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            await connect(token: token)
        }
    }
}
