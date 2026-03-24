import Foundation
import Network

public enum ConnectionMode: String {
    case lan = "LAN"
    case relay = "Relay"
    case disconnected = "Disconnected"
}

@MainActor
public class ConnectionManager: ObservableObject {
    @Published public var isConnected = false
    @Published public var isReconnecting = false
    @Published public var latency: TimeInterval = 0
    @Published public var errorMessage: String?
    @Published public var connectionMode: ConnectionMode = .disconnected

    // LAN connection (Network.framework)
    private var connection: NWConnection?

    // Relay connection (URLSession WebSocket)
    private var relayTask: URLSessionWebSocketTask?
    private var relaySession: URLSession?

    private var pingTimer: Timer?
    private var reconnectTimer: Timer?
    private var lastPingTime: Date?
    private var authToken: String?
    private var host: String?
    private var port: UInt16?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 10

    public var onPacketReceived: ((WSPacket) -> Void)?
    public var onStreamFrameReceived: ((Data) -> Void)? // Binary MJPEG frames from relay
    public var onScreenshotReceived: ((Data) -> Void)? // Binary screenshot from relay (prefixed with "SCRN")
    private var packetListeners: [String: (WSPacket) -> Void] = [:]

    public init() {}

    /// Add a named listener for packets. Multiple listeners can coexist.
    public func addListener(_ id: String, handler: @escaping (WSPacket) -> Void) {
        packetListeners[id] = handler
    }

    public func removeListener(_ id: String) {
        packetListeners.removeValue(forKey: id)
    }

    // MARK: - LAN Connection (existing behavior)

    public func connect(to host: String, port: UInt16, token: String) {
        self.host = host
        self.port = port
        self.authToken = token
        reconnectAttempts = 0
        errorMessage = nil

        performLANConnect()
    }

    // MARK: - Relay Connection

    public func connectViaRelay(token: String) {
        self.authToken = token
        reconnectAttempts = 0
        errorMessage = nil

        performRelayConnect()
    }

    // MARK: - Smart Connect (try LAN first, fallback to relay)

    public func smartConnect(lanHost: String?, port: UInt16, token: String) {
        self.authToken = token
        self.port = port
        reconnectAttempts = 0
        errorMessage = nil

        if let host = lanHost {
            self.host = host
            print("[WS] Trying LAN connection to \(host):\(port)...")
            performLANConnectWithRelayFallback()
        } else {
            print("[WS] No LAN host available, connecting via relay...")
            performRelayConnect()
        }
    }

    public func disconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        pingTimer?.invalidate()
        pingTimer = nil
        connection?.cancel()
        connection = nil
        relayTask?.cancel(with: .goingAway, reason: nil)
        relayTask = nil
        isConnected = false
        isReconnecting = false
        connectionMode = .disconnected
    }

    public func send(_ packet: WSPacket) {
        guard let data = try? packet.encode() else {
            print("[WS] Encode failed for \(packet.action.rawValue)")
            return
        }
        print("[WS] Sending: \(packet.action.rawValue)")

        if connectionMode == .relay {
            sendViaRelay(data)
        } else {
            sendViaLAN(data)
        }
    }

    // MARK: - LAN Transport

    private func sendViaLAN(_ data: Data) {
        guard let connection else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])

        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            if let error {
                print("[WS] LAN send error: \(error)")
                Task { @MainActor in self?.handleDisconnect() }
            }
        })
    }

    private func performLANConnect() {
        guard let host, let port else { return }

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
                    print("[WS] LAN connected to \(host):\(port)")
                    self?.connectionMode = .lan
                    if let token = self?.authToken {
                        self?.send(WSPacket(action: .auth, payload: ["token": token]))
                    }
                    self?.receiveLANLoop()
                    self?.startPing()
                case .failed(let error):
                    print("[WS] LAN connection failed: \(error)")
                    self?.handleDisconnect()
                case .waiting(let error):
                    print("[WS] LAN waiting: \(error)")
                default:
                    break
                }
            }
        }

        conn.start(queue: .global(qos: .userInitiated))
        self.connection = conn
    }

    private func performLANConnectWithRelayFallback() {
        guard let host, let port else { return }

        guard let url = URL(string: "ws://\(host):\(port)/") else {
            performRelayConnect()
            return
        }

        let parameters = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let conn = NWConnection(to: .url(url), using: parameters)

        // Timeout: if LAN doesn't connect in 3 seconds, try relay
        var lanConnected = false
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !lanConnected && !self.isConnected {
                print("[WS] LAN timeout, falling back to relay...")
                conn.cancel()
                self.connection = nil
                self.performRelayConnect()
            }
        }

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    lanConnected = true
                    timeoutTask.cancel()
                    print("[WS] LAN connected to \(host):\(port)")
                    self?.connectionMode = .lan
                    if let token = self?.authToken {
                        self?.send(WSPacket(action: .auth, payload: ["token": token]))
                    }
                    self?.receiveLANLoop()
                    self?.startPing()
                case .failed:
                    lanConnected = false
                    timeoutTask.cancel()
                    print("[WS] LAN failed, switching to relay...")
                    self?.connection = nil
                    self?.performRelayConnect()
                case .waiting:
                    break
                default:
                    break
                }
            }
        }

        conn.start(queue: .global(qos: .userInitiated))
        self.connection = conn
    }

    private func receiveLANLoop() {
        connection?.receiveMessage { [weak self] content, context, isComplete, error in
            Task { @MainActor in
                if let error {
                    print("[WS] LAN receive error: \(error)")
                    self?.handleDisconnect()
                    return
                }

                if let data = content, let packet = try? WSPacket.decode(from: data) {
                    self?.handlePacket(packet)
                }

                self?.receiveLANLoop()
            }
        }
    }

    // MARK: - Relay Transport

    private func sendViaRelay(_ data: Data) {
        guard let relayTask else { return }
        let message = URLSessionWebSocketTask.Message.string(String(data: data, encoding: .utf8)!)
        relayTask.send(message) { error in
            if let error {
                print("[WS] Relay send error: \(error)")
            }
        }
    }

    private func performRelayConnect() {
        guard let token = authToken else { return }

        let baseURL = TarsyConfig.relayURL

        guard let url = URL(string: "\(baseURL)?token=\(token)&role=client") else {
            errorMessage = "Invalid relay URL"
            return
        }

        print("[WS] Connecting to relay...")

        relaySession = URLSession(configuration: .default)
        let task = relaySession!.webSocketTask(with: url)
        self.relayTask = task
        task.resume()

        connectionMode = .relay
        receiveRelayLoop()

        // Relay doesn't have an explicit "ready" — it's ready as soon as task resumes
        // We consider ourselves connected when we get the first message or after a short delay
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !self.isConnected {
                // Check if relay responded with machine_online
                self.isConnected = true
                self.isReconnecting = false
                self.reconnectAttempts = 0
                self.errorMessage = nil
                self.startPing()
                print("[WS] Relay connected")
            }
        }
    }

    private func receiveRelayLoop() {
        guard let relayTask else { return }

        relayTask.receive { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        if let data = text.data(using: .utf8),
                           let packet = try? WSPacket.decode(from: data) {
                            self?.handlePacket(packet)
                        }
                    case .data(let data):
                        // Check for "SCRN" prefix = screenshot, otherwise = stream frame
                        let prefix = data.prefix(4)
                        if prefix.count == 4 && String(data: prefix, encoding: .utf8) == "SCRN" {
                            let jpegData = data.dropFirst(4)
                            self?.onScreenshotReceived?(Data(jpegData))
                        } else {
                            self?.onStreamFrameReceived?(data)
                        }
                    @unknown default:
                        break
                    }
                    self?.receiveRelayLoop()

                case .failure(let error):
                    print("[WS] Relay receive error: \(error)")
                    self?.handleDisconnect()
                }
            }
        }
    }

    // MARK: - Common

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
        case .relayMachineOnline:
            print("[WS] Mac is online via relay")
            isConnected = true
            isReconnecting = false
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
        relayTask?.cancel(with: .goingAway, reason: nil)
        relayTask = nil
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
                // Reconnect using the same mode
                if self?.connectionMode == .relay || self?.host == nil {
                    self?.performRelayConnect()
                } else {
                    self?.performLANConnectWithRelayFallback()
                }
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
