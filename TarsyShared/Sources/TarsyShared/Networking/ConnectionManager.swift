import Foundation
import Network

@MainActor
public class ConnectionManager: ObservableObject {
    @Published public var isConnected = false
    @Published public var isReconnecting = false
    @Published public var latency: TimeInterval = 0
    @Published public var errorMessage: String?

    private var connection: NWConnection?
    private var pingTimer: Timer?
    private var reconnectTimer: Timer?
    private var lastPingTime: Date?
    private var authToken: String?
    private var host: String?
    private var port: UInt16?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 10

    public var onPacketReceived: ((WSPacket) -> Void)?
    private var packetListeners: [String: (WSPacket) -> Void] = [:]

    public init() {}

    /// Add a named listener for packets. Multiple listeners can coexist.
    public func addListener(_ id: String, handler: @escaping (WSPacket) -> Void) {
        packetListeners[id] = handler
    }

    public func removeListener(_ id: String) {
        packetListeners.removeValue(forKey: id)
    }

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
        connection?.cancel()
        connection = nil
        isConnected = false
        isReconnecting = false
    }

    public func send(_ packet: WSPacket) {
        guard let connection,
              let data = try? packet.encode() else { return }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])

        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            if let error {
                print("[WS] Send error: \(error)")
                Task { @MainActor in
                    self?.handleDisconnect()
                }
            }
        })
    }

    // MARK: - Private

    private func performConnect() {
        guard let host, let port else { return }

        // Create WebSocket connection using Network.framework (bypasses ATS)
        // Must use URL endpoint so WebSocket has a path for the HTTP upgrade
        guard let url = URL(string: "ws://\(host):\(port)/") else {
            errorMessage = "Invalid WebSocket URL"
            return
        }

        let parameters = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let conn = NWConnection(to: .url(url), using: parameters)

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    print("[WS] Connected to \(host):\(port)")
                    // Send auth
                    if let token = self?.authToken {
                        self?.send(WSPacket(action: .auth, payload: ["token": token]))
                    }
                    self?.receiveLoop()
                    self?.startPing()
                case .failed(let error):
                    print("[WS] Connection failed: \(error)")
                    self?.handleDisconnect()
                case .waiting(let error):
                    print("[WS] Waiting: \(error)")
                default:
                    break
                }
            }
        }

        conn.start(queue: .global(qos: .userInitiated))
        self.connection = conn
    }

    private func receiveLoop() {
        connection?.receiveMessage { [weak self] content, context, isComplete, error in
            Task { @MainActor in
                if let error {
                    print("[WS] Receive error: \(error)")
                    self?.handleDisconnect()
                    return
                }

                if let data = content, let packet = try? WSPacket.decode(from: data) {
                    self?.handlePacket(packet)
                }

                // Continue receiving
                self?.receiveLoop()
            }
        }
    }

    private func handlePacket(_ packet: WSPacket) {
        switch packet.action {
        case .authSuccess:
            isConnected = true
            isReconnecting = false
            reconnectAttempts = 0
            errorMessage = nil
            print("[WS] Authenticated successfully")
        case .authFail:
            isConnected = false
            errorMessage = "authentication failed"
            disconnect()
        case .auth, .pong:
            if let pingTime = lastPingTime {
                latency = Date().timeIntervalSince(pingTime)
            }
        case .error:
            let msg = packet.payload?["message"] ?? ""
            if !msg.contains("Unknown action") {
                errorMessage = msg
            }
            notifyListeners(packet)
        default:
            notifyListeners(packet)
        }
    }

    private func notifyListeners(_ packet: WSPacket) {
        onPacketReceived?(packet)
        for (_, listener) in packetListeners {
            listener(packet)
        }
    }

    private func handleDisconnect() {
        guard isConnected || reconnectAttempts == 0 else { return }
        isConnected = false
        connection?.cancel()
        connection = nil
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
        let delay = min(Double(reconnectAttempts) * 2, 30)

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
