import Foundation
import Network
import CryptoKit
import Security

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
    @Published public var detectedAgents: [AIEngineType] = []
    @Published public var openclawAvailable = false

    // LAN connection (Network.framework)
    private var connection: NWConnection?

    // Relay connection (URLSession WebSocket)
    private var relayTask: URLSessionWebSocketTask?
    private var relaySession: URLSession?

    private var pingTimer: Timer?
    private var reconnectTimer: Timer?
    private var lastPingTime: Date?
    private var lastPongTime: Date?
    private var authToken: String?
    private var host: String?
    private var port: UInt16?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = Int.max

    public var onPacketReceived: ((WSPacket) -> Void)?
    public var onStreamFrameReceived: ((Data) -> Void)?
    public var onScreenshotReceived: ((Data) -> Void)? // Binary screenshot from relay (prefixed with "SCRN")
    /// Called when a sudoRequest arrives. Set this to show a password prompt and call the completion with the password.
    public var onSudoRequest: ((WSPacket) -> Void)?
    /// Called after a successful reconnection (not on first connect).
    public var onReconnected: (() -> Void)?
    private var packetListeners: [String: (WSPacket) -> Void] = [:]

    /// Stored TLS fingerprint for the current host (TOFU pinning)
    private var pinnedFingerprint: String?
    private static let fingerprintKeychainService = "com.tarsy.ios.tls-pins"

    /// E2E encryption for sensitive payloads (sudo password, API keys)
    public let e2e = E2ECrypto()

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
            performLANConnectWithRelayFallback()
        } else {
            performRelayConnect()
        }
    }

    /// Re-establish connection using stored parameters. Uses smart connect (LAN first if host known).
    /// Refreshes auth token before connecting. Safe to call when already connected (no-op).
    public func reconnectIfNeeded() async {
        guard !isConnected else { return }

        // Refresh token
        if let session = try? await supabase.auth.session {
            authToken = session.accessToken
        }

        guard authToken != nil, let port else { return }

        // Mark as reconnecting so authSuccess fires onReconnected
        isReconnecting = true
        reconnectAttempts = 0
        errorMessage = nil

        if let host {
            performLANConnectWithRelayFallback()
        } else {
            performRelayConnect()
        }
    }

    /// Intentional disconnect — does NOT trigger reconnection.
    public func disconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        pingTimer?.invalidate()
        pingTimer = nil
        lastPingTime = nil
        lastPongTime = nil
        connection?.cancel()
        connection = nil
        relayTask?.cancel(with: .goingAway, reason: nil)
        relayTask = nil
        isConnected = false
        isReconnecting = false
        connectionMode = .disconnected
        e2e.reset()
    }

    public func send(_ packet: WSPacket) {
        guard let data = try? packet.encode() else { return }

        if connectionMode == .relay {
            // Encrypt text packets for relay transit (E2E — relay can't read)
            if e2e.isReady, packet.action != .auth, packet.action != .e2eEncrypted,
               let encrypted = e2e.encryptBinary(data) {
                let envelope = WSPacket(
                    action: .e2eEncrypted,
                    payload: ["data": encrypted.base64EncodedString()],
                    id: packet.id
                )
                if let envelopeData = try? envelope.encode() {
                    sendViaRelay(envelopeData)
                    return
                }
            }
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
            if error != nil {
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

        let parameters = createLANTLSParameters()
        let conn = NWConnection(to: .url(url), using: parameters)

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.connectionMode = .lan
                    if let token = self?.authToken {
                        self?.send(WSPacket(action: .auth, payload: ["token": token, "e2ePublicKey": self?.e2e.publicKeyBase64 ?? ""]))
                    }
                    self?.receiveLANLoop()
                    self?.startPing()
                case .failed:
                    self?.handleDisconnect()
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

    private func performLANConnectWithRelayFallback() {
        guard let host, let port else { return }
        guard let url = URL(string: "ws://\(host):\(port)/") else {
            errorMessage = "Invalid WebSocket URL"
            return
        }

        // Race TLS and non-TLS connections — use whichever connects first.
        // This handles both cases: server with TLS (normal) and without (Keychain failure).
        var lanConnected = false

        let tlsConn = NWConnection(to: .url(url), using: createLANTLSParameters())

        let plainParams = NWParameters.tcp
        let wsOpts = NWProtocolWebSocket.Options()
        wsOpts.autoReplyPing = true
        plainParams.defaultProtocolStack.applicationProtocols.insert(wsOpts, at: 0)
        let plainConn = NWConnection(to: .url(url), using: plainParams)

        // Timeout: if neither connects in 3 seconds, try relay
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !lanConnected && !self.isConnected {
                tlsConn.cancel()
                plainConn.cancel()
                self.connection = nil
                self.performRelayConnect()
            }
        }

        // Handler called when either connection reaches .ready
        let onReady: @MainActor (NWConnection, NWConnection) -> Void = { [weak self] winner, loser in
            guard !lanConnected else { return } // Only first wins
            lanConnected = true
            timeoutTask.cancel()
            loser.cancel()
            // If relay already connected while we were waiting, tear it down
            if self?.relayTask != nil {
                self?.relayTask?.cancel(with: .goingAway, reason: nil)
                self?.relayTask = nil
                self?.relaySession = nil
                self?.pingTimer?.invalidate()
                self?.pingTimer = nil
            }
            self?.connection = winner
            self?.isConnected = true
            self?.reconnectAttempts = 0
            self?.errorMessage = nil
            self?.connectionMode = .lan
            if let token = self?.authToken {
                self?.send(WSPacket(action: .auth, payload: ["token": token, "e2ePublicKey": self?.e2e.publicKeyBase64 ?? ""]))
            }
            self?.receiveLANLoop()
            self?.startPing()
        }

        var tlsFailed = false
        var plainFailed = false

        tlsConn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    onReady(tlsConn, plainConn)
                case .failed:
                    tlsFailed = true
                    if plainFailed && !lanConnected && self?.isConnected != true {
                        timeoutTask.cancel()
                        self?.connection = nil
                        self?.performRelayConnect()
                    }
                default: break
                }
            }
        }

        plainConn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    onReady(plainConn, tlsConn)
                case .failed:
                    plainFailed = true
                    if tlsFailed && !lanConnected && self?.isConnected != true {
                        timeoutTask.cancel()
                        self?.connection = nil
                        self?.performRelayConnect()
                    }
                default: break
                }
            }
        }

        tlsConn.start(queue: .global(qos: .userInitiated))
        plainConn.start(queue: .global(qos: .userInitiated))
    }

    private func receiveLANLoop() {
        connection?.receiveMessage { [weak self] content, context, isComplete, error in
            Task { @MainActor in
                if error != nil {
                    self?.handleDisconnect()
                    return
                }

                if let data = content {
                    // Enforce message size limit on LAN (relay has 4MB WebSocket limit)
                    guard data.count <= 4 * 1024 * 1024 else {
                        self?.receiveLANLoop()
                        return
                    }

                    // Check for binary stream data (H.264 or screenshot)
                    let prefix = data.prefix(4)
                    let prefixStr = prefix.count == 4 ? String(data: prefix, encoding: .utf8) : nil

                    if prefixStr == "H264" {
                        // Try E2E decryption, fall back to unencrypted (LAN with TLS)
                        let payload = Data(data.dropFirst(4))
                        if self?.e2e.isReady == true, let decrypted = self?.e2e.decryptBinary(payload) {
                            var frameData = Data("H264".utf8)
                            frameData.append(decrypted)
                            self?.onStreamFrameReceived?(frameData)
                        } else {
                            self?.onStreamFrameReceived?(data)
                        }
                    } else if prefixStr == "SCRN" {
                        let payload = Data(data.dropFirst(4))
                        if self?.e2e.isReady == true, let decrypted = self?.e2e.decryptBinary(payload) {
                            self?.onScreenshotReceived?(decrypted)
                        } else {
                            self?.onScreenshotReceived?(payload)
                        }
                    } else if let packet = try? WSPacket.decode(from: data) {
                        self?.handlePacket(packet)
                    }
                }

                self?.receiveLANLoop()
            }
        }
    }

    // MARK: - Relay Transport

    private var relaySendCount = 0

    private func sendViaRelay(_ data: Data) {
        guard let relayTask else {
            print("[Relay:TX] sendViaRelay: relayTask is nil!")
            return
        }
        guard let str = String(data: data, encoding: .utf8) else {
            print("[Relay:TX] sendViaRelay: failed to convert \(data.count)B to string")
            return
        }
        relaySendCount += 1
        if relaySendCount <= 10 || relaySendCount % 50 == 0 {
            // Parse action for logging
            let action = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["action"] as? String ?? "?"
            print("[Relay:TX] send #\(relaySendCount): action=\(action), \(data.count)B")
        }
        relayTask.send(.string(str)) { [weak self] error in
            if let error {
                print("[Relay:TX] send error: \(error)")
                Task { @MainActor in self?.handleDisconnect() }
            }
        }
    }

    private func performRelayConnect() {
        guard let token = authToken else { return }

        let baseURL = TarsyConfig.relayURL

        guard let url = URL(string: baseURL) else {
            errorMessage = "Invalid relay URL"
            return
        }

        relaySession = URLSession(configuration: .default)
        let task = relaySession!.webSocketTask(with: url)
        task.maximumMessageSize = 4 * 1024 * 1024 // 4MB
        self.relayTask = task
        task.resume()

        // Send auth as first message (token not in URL for security)
        let auth: [String: String] = ["action": "auth", "token": token, "role": "client"]
        if let data = try? JSONSerialization.data(withJSONObject: auth),
           let str = String(data: data, encoding: .utf8) {
            task.send(.string(str)) { _ in }
        }

        connectionMode = .relay
        receiveRelayLoop()

        // Relay doesn't have an explicit "ready" — it's ready as soon as task resumes
        // We consider ourselves connected when we get the first message or after a short delay
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !self.isConnected {
                // Fallback: consider relay connected after 500ms if no authSuccess yet.
                // Don't reset isReconnecting — let authSuccess handle it for onReconnected.
                self.isConnected = true
                self.reconnectAttempts = 0
                self.errorMessage = nil
                self.startPing()
            }
        }
    }

    private var relayMsgCount = 0
    private var relayBinaryCount = 0
    private var relayTextCount = 0

    private func receiveRelayLoop() {
        guard let relayTask else {
            print("[Relay:RX] receiveRelayLoop: relayTask is nil, stopping")
            return
        }

        relayTask.receive { [weak self] result in
            Task { @MainActor in
                guard let self else {
                    print("[Relay:RX] self is nil in receive callback")
                    return
                }
                self.relayMsgCount += 1

                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.relayTextCount += 1
                        if let data = text.data(using: .utf8),
                           let packet = try? WSPacket.decode(from: data) {
                            if self.relayTextCount <= 10 || self.relayTextCount % 50 == 0 {
                                print("[Relay:RX] text #\(self.relayTextCount): action=\(packet.action.rawValue)")
                            }
                            self.handlePacket(packet)
                        } else {
                            print("[Relay:RX] text #\(self.relayTextCount): failed to decode, len=\(text.count), preview=\(String(text.prefix(80)))")
                        }
                    case .data(let data):
                        self.relayBinaryCount += 1
                        let prefix = data.prefix(4)
                        let prefixStr = prefix.count == 4 ? String(data: prefix, encoding: .utf8) : nil

                        if self.relayBinaryCount <= 5 || self.relayBinaryCount % 100 == 0 {
                            print("[Relay:RX] binary #\(self.relayBinaryCount): \(data.count)B, prefix=\(prefixStr ?? "nil"), hasStreamHandler=\(self.onStreamFrameReceived != nil)")
                        }

                        if prefixStr == "H264" {
                            let payload = Data(data.dropFirst(4))
                            if let decrypted = self.e2e.decryptBinary(payload) {
                                var frameData = Data("H264".utf8)
                                frameData.append(decrypted)
                                self.onStreamFrameReceived?(frameData)
                            } else {
                                self.onStreamFrameReceived?(data)
                            }
                        } else if prefixStr == "SCRN" {
                            let payload = Data(data.dropFirst(4))
                            if let decrypted = self.e2e.decryptBinary(payload) {
                                self.onScreenshotReceived?(decrypted)
                            } else {
                                self.onScreenshotReceived?(payload)
                            }
                        } else {
                            print("[Relay:RX] binary unknown prefix: \(prefixStr ?? "nil"), \(data.count)B")
                            self.onStreamFrameReceived?(data)
                        }
                    @unknown default:
                        print("[Relay:RX] unknown message type")
                        break
                    }
                    self.receiveRelayLoop()

                case .failure(let error):
                    print("[Relay:RX] receive FAILED after \(self.relayMsgCount) msgs (\(self.relayTextCount) text, \(self.relayBinaryCount) binary): \(error)")
                    self.handleDisconnect()
                }
            }
        }
    }

    // MARK: - Common

    private func handlePacket(_ packet: WSPacket) {
        switch packet.action {
        case .authSuccess:
            let wasReconnecting = isReconnecting
            isConnected = true
            isReconnecting = false
            reconnectAttempts = 0
            errorMessage = nil
            lastPongTime = Date() // Baseline for ping timeout detection
            // Save TLS fingerprint from server for TOFU pinning.
            // Only save on first use (no existing pin) or on LAN connections (trusted channel).
            // Never allow a relay-delivered authSuccess to overwrite an existing pin.
            if let fp = packet.payload?["fingerprint"], let h = host {
                let existingPin = loadPinnedFingerprint(forHost: h)
                if existingPin == nil {
                    // True first use — save the fingerprint
                    savePinnedFingerprint(fp, forHost: h)
                } else if connectionMode == .lan {
                    // LAN is direct (TLS protected), safe to update
                    savePinnedFingerprint(fp, forHost: h)
                } else if existingPin == fp {
                    // Same fingerprint — no-op
                }
                // If relay + different fingerprint → ignore (prevents relay MITM overwrite)
            }
            // Complete E2E key exchange with TLS binding verification
            if let remoteKey = packet.payload?["e2ePublicKey"], e2e.completeKeyExchange(remotePublicKeyBase64: remoteKey) {
                // Verify E2E key is signed by the TLS certificate (prevents relay MITM)
                if let sigB64 = packet.payload?["e2eKeySignature"],
                   let certB64 = packet.payload?["tlsCertificate"],
                   let h = host {
                    let verified = verifyE2EKeyBinding(
                        e2ePublicKey: remoteKey,
                        signatureBase64: sigB64,
                        certificateBase64: certB64,
                        forHost: h
                    )
                    if !verified {
                        // Still connected but E2E may be compromised — reset and rely on TLS only
                        e2e.reset()
                    }
                }
            }
            // Notify listeners that we successfully reconnected
            if wasReconnecting {
                onReconnected?()
            }
        case .authFail:
            isConnected = false
            errorMessage = "authentication failed"
            disconnect()
        case .relayMachineOnline:
            isConnected = true
            // Don't reset isReconnecting here — let authSuccess handle it
            // so onReconnected fires correctly
            lastPongTime = Date()
        case .auth, .pong:
            lastPongTime = Date()
            if let pingTime = lastPingTime {
                latency = Date().timeIntervalSince(pingTime)
            }
        case .agentsDetected:
            if let csv = packet.payload?["agents"] {
                detectedAgents = csv.split(separator: ",").compactMap { AIEngineType(rawValue: String($0)) }
            }
            notifyListeners(packet)
        case .openclawStatus:
            if let installed = packet.payload?["installed"] {
                openclawAvailable = installed == "true"
            }
            notifyListeners(packet)
        case .sudoRequest:
            onSudoRequest?(packet)
            notifyListeners(packet)
        case .e2eEncrypted:
            // Unwrap E2E-encrypted text packet envelope
            if let dataB64 = packet.payload?["data"],
               let ciphertext = Data(base64Encoded: dataB64),
               let decryptedData = e2e.decryptBinary(ciphertext),
               let innerPacket = try? WSPacket.decode(from: decryptedData) {
                handlePacket(innerPacket)
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
        let delay = min(Double(reconnectAttempts) * 2, 60)

        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                // Refresh token before reconnecting (old token may have expired)
                if let session = try? await supabase.auth.session {
                    self?.authToken = session.accessToken
                }

                // Always try LAN first if host is known (smart reconnect)
                if self?.host != nil {
                    self?.performLANConnectWithRelayFallback()
                } else {
                    self?.performRelayConnect()
                }
            }
        }
    }

    private func startPing() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                // Detect zombie connections: if last ping was sent but pong never arrived
                if let lastPing = self?.lastPingTime {
                    let lastPong = self?.lastPongTime
                    let pongMissing = (lastPong == nil) || (lastPong! < lastPing)
                    if pongMissing && Date().timeIntervalSince(lastPing) > 15 {
                        self?.handleDisconnect()
                        return
                    }
                }
                self?.lastPingTime = Date()
                self?.send(WSPacket(action: .ping))
            }
        }
    }

    // MARK: - TLS (TOFU Pinning)

    /// Creates NWParameters with TLS configured for trust-on-first-use.
    /// Accepts any self-signed certificate on first connect, validates fingerprint on subsequent connects.
    func createLANTLSParameters() -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()

        // Load pinned fingerprint for this host
        let savedFingerprint = host.flatMap { loadPinnedFingerprint(forHost: $0) }

        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { (metadata, trust, completion) in
            let serverTrust = sec_trust_copy_ref(trust).takeRetainedValue()

            // Extract server certificate
            guard let certChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
                  let serverCert = certChain.first else {
                completion(false)
                return
            }

            let certData = SecCertificateCopyData(serverCert) as Data
            let fingerprint = SHA256.hash(data: certData).map { String(format: "%02x", $0) }.joined(separator: ":")

            if let pinned = savedFingerprint {
                // Validate against pinned fingerprint
                if fingerprint == pinned {
                    completion(true)
                } else {
                    completion(false)
                }
            } else {
                completion(true)
            }
        }, .global(qos: .userInitiated))

        let tcpOptions = NWProtocolTCP.Options()
        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)

        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        return parameters
    }

    // MARK: - E2E Key Binding Verification

    /// Verifies that the remote E2E public key was signed by the TLS certificate we trust.
    /// This prevents a compromised relay from performing a MITM on the key exchange.
    private func verifyE2EKeyBinding(e2ePublicKey: String, signatureBase64: String, certificateBase64: String, forHost host: String) -> Bool {
        guard let signatureData = Data(base64Encoded: signatureBase64),
              let certData = Data(base64Encoded: certificateBase64),
              let keyData = e2ePublicKey.data(using: .utf8) else {
            return false
        }

        // Verify the certificate fingerprint matches our pinned one
        let certFingerprint = SHA256.hash(data: certData).map { String(format: "%02x", $0) }.joined(separator: ":")
        let pinnedFP = loadPinnedFingerprint(forHost: host)

        if let pinned = pinnedFP, pinned != certFingerprint {
            return false
        }

        // Create SecCertificate and extract public key
        guard let certificate = SecCertificateCreateWithData(nil, certData as CFData) else {
            return false
        }

        var trust: SecTrust?
        let policy = SecPolicyCreateBasicX509()
        guard SecTrustCreateWithCertificates(certificate, policy, &trust) == errSecSuccess,
              let trustRef = trust else {
            return false
        }

        guard let publicKey = SecTrustCopyKey(trustRef) else {
            return false
        }

        // Verify the signature (RSA-PSS SHA256)
        var error: Unmanaged<CFError>?
        let verified = SecKeyVerifySignature(
            publicKey,
            .rsaSignatureMessagePSSSHA256,
            keyData as CFData,
            signatureData as CFData,
            &error
        )

        return verified
    }

    // MARK: - Fingerprint Keychain Storage

    private func savePinnedFingerprint(_ fingerprint: String, forHost host: String) {
        pinnedFingerprint = fingerprint
        let key = "tls-pin-\(host)"
        guard let data = fingerprint.data(using: .utf8) else { return }

        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.fingerprintKeychainService,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.fingerprintKeychainService,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func loadPinnedFingerprint(forHost host: String) -> String? {
        let key = "tls-pin-\(host)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.fingerprintKeychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
