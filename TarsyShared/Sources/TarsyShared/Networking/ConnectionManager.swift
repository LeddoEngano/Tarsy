import Foundation

@MainActor
public class ConnectionManager: ObservableObject {
    @Published public var isConnected = false
    @Published public var latency: TimeInterval = 0

    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pingTimer: Timer?
    private var lastPingTime: Date?
    private var authToken: String?

    public var onPacketReceived: ((WSPacket) -> Void)?

    public init() {}

    public func connect(to host: String, port: UInt16, token: String) {
        authToken = token
        let url = URL(string: "ws://\(host):\(port)")!
        session = URLSession(configuration: .default)
        webSocket = session?.webSocketTask(with: url)
        webSocket?.resume()

        // Authenticate
        let authPacket = WSPacket(action: .auth, payload: ["token": token])
        send(authPacket)

        receiveLoop()
        startPing()
    }

    public func disconnect() {
        pingTimer?.invalidate()
        pingTimer = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        isConnected = false
    }

    public func send(_ packet: WSPacket) {
        guard let data = try? packet.encode(),
              let text = String(data: data, encoding: .utf8) else { return }

        webSocket?.send(.string(text)) { error in
            if let error {
                print("[WS] Send error: \(error)")
            }
        }
    }

    private func receiveLoop() {
        webSocket?.receive { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let message):
                    self?.handleMessage(message)
                    self?.receiveLoop()
                case .failure(let error):
                    print("[WS] Receive error: \(error)")
                    self?.isConnected = false
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text):
            guard let d = text.data(using: .utf8) else { return }
            data = d
        case .data(let d):
            data = d
        @unknown default:
            return
        }

        guard let packet = try? WSPacket.decode(from: data) else { return }

        switch packet.action {
        case .authSuccess:
            isConnected = true
        case .authFail:
            isConnected = false
            disconnect()
        case .pong:
            if let pingTime = lastPingTime {
                latency = Date().timeIntervalSince(pingTime)
            }
        default:
            onPacketReceived?(packet)
        }
    }

    private func startPing() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.lastPingTime = Date()
                self?.send(WSPacket(action: .ping))
            }
        }
    }
}
