import Foundation

@MainActor
public class ConnectionManager: ObservableObject {
    @Published public var isConnected = false
    @Published public var isReconnecting = false
    @Published public var latency: TimeInterval = 0
    @Published public var errorMessage: String?

    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pingTimer: Timer?
    private var reconnectTimer: Timer?
    private var lastPingTime: Date?
    private var authToken: String?
    private var host: String?
    private var port: UInt16?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 10

    public var onPacketReceived: ((WSPacket) -> Void)?

    public init() {}

    public func connect(to host: String, port: UInt16, token: String) {
        self.host = host
        self.port = port
        self.authToken = token
        reconnectAttempts = 0
        errorMessage = nil

        performConnect()
    }

    public func disconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        pingTimer?.invalidate()
        pingTimer = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        isConnected = false
        isReconnecting = false
    }

    public func send(_ packet: WSPacket) {
        guard let data = try? packet.encode(),
              let text = String(data: data, encoding: .utf8) else { return }

        webSocket?.send(.string(text)) { [weak self] error in
            if let error {
                print("[WS] Send error: \(error)")
                Task { @MainActor in
                    self?.handleDisconnect()
                }
            }
        }
    }

    // MARK: - Private

    private func performConnect() {
        guard let host, let port, let token = authToken else { return }

        let url = URL(string: "ws://\(host):\(port)")!
        session = URLSession(configuration: .default)
        webSocket = session?.webSocketTask(with: url)
        webSocket?.resume()

        let authPacket = WSPacket(action: .auth, payload: ["token": token])
        send(authPacket)

        receiveLoop()
        startPing()
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
                    self?.handleDisconnect()
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
            isReconnecting = false
            reconnectAttempts = 0
            errorMessage = nil
        case .authFail:
            isConnected = false
            errorMessage = "authentication failed"
            disconnect()
        case .pong:
            if let pingTime = lastPingTime {
                latency = Date().timeIntervalSince(pingTime)
            }
        case .error:
            errorMessage = packet.payload?["message"]
            onPacketReceived?(packet)
        default:
            onPacketReceived?(packet)
        }
    }

    private func handleDisconnect() {
        isConnected = false
        webSocket?.cancel(with: .abnormalClosure, reason: nil)
        webSocket = nil
        pingTimer?.invalidate()
        pingTimer = nil

        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard reconnectAttempts < maxReconnectAttempts else {
            errorMessage = "connection lost after \(maxReconnectAttempts) attempts"
            isReconnecting = false
            return
        }

        isReconnecting = true
        reconnectAttempts += 1
        let delay = min(Double(reconnectAttempts) * 2, 30) // Exponential backoff, max 30s

        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.performConnect()
            }
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
