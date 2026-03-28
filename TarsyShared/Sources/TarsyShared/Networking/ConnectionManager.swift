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
            print("[WS] Trying LAN connection to \(host):\(port)...")
            performLANConnectWithRelayFallback()
        } else {
            print("[WS] No LAN host available, connecting via relay...")
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
            print("[WS] Reconnecting with smart connect to \(host):\(port)...")
            performLANConnectWithRelayFallback()
        } else {
            print("[WS] Reconnecting via relay...")
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
        guard let data = try? packet.encode() else {
            print("[WS] Encode failed for \(packet.action.rawValue)")
            return
        }
        print("[WS] Sending: \(packet.action.rawValue)")

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

        let parameters = createLANTLSParameters()
        let conn = NWConnection(to: .url(url), using: parameters)

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    print("[WS] LAN connected to \(host):\(port)")
                    self?.connectionMode = .lan
                    if let token = self?.authToken {
                        self?.send(WSPacket(action: .auth, payload: ["token": token, "e2ePublicKey": self?.e2e.publicKeyBase64 ?? ""]))
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
            errorMessage = "Invalid WebSocket URL"
            return
        }

        let parameters = createLANTLSParameters()
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
                    // If relay already connected while we were waiting, tear it down
                    if self?.relayTask != nil {
                        print("[WS] LAN ready — cancelling relay in favor of LAN")
                        self?.relayTask?.cancel(with: .goingAway, reason: nil)
                        self?.relayTask = nil
                        self?.relaySession = nil
                        self?.pingTimer?.invalidate()
                        self?.pingTimer = nil
                    }
                    print("[WS] LAN connected to \(host):\(port)")
                    self?.isConnected = true
                    // Don't reset isReconnecting here — let authSuccess handle it
                    // so onReconnected fires correctly on lifecycle reconnections
                    self?.reconnectAttempts = 0
                    self?.errorMessage = nil
                    self?.connectionMode = .lan
                    if let token = self?.authToken {
                        self?.send(WSPacket(action: .auth, payload: ["token": token, "e2ePublicKey": self?.e2e.publicKeyBase64 ?? ""]))
                    }
                    self?.receiveLANLoop()
                    self?.startPing()
                case .failed:
                    lanConnected = false
                    timeoutTask.cancel()
                    // Only fall back to relay if relay isn't already connected
                    if self?.isConnected != true {
                        print("[WS] LAN failed, switching to relay...")
                        self?.connection = nil
                        self?.performRelayConnect()
                    }
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

                if let data = content {
                    // Enforce message size limit on LAN (relay has 4MB WebSocket limit)
                    guard data.count <= 4 * 1024 * 1024 else {
                        print("[WS] LAN message too large: \(data.count) bytes, dropping")
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

    private func sendViaRelay(_ data: Data) {
        guard let relayTask, let str = String(data: data, encoding: .utf8) else { return }
        relayTask.send(.string(str)) { [weak self] error in
            if let error {
                print("[WS] Relay send error: \(error)")
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

        print("[WS] Connecting to relay...")

        relaySession = URLSession(configuration: .default)
        let task = relaySession!.webSocketTask(with: url)
        task.maximumMessageSize = 4 * 1024 * 1024 // 4MB
        self.relayTask = task
        task.resume()

        // Send auth as first message (token not in URL for security)
        let auth: [String: String] = ["action": "auth", "token": token, "role": "client"]
        if let data = try? JSONSerialization.data(withJSONObject: auth),
           let str = String(data: data, encoding: .utf8) {
            task.send(.string(str)) { error in
                if let error { print("[WS] Auth send error: \(error)") }
            }
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
                print("[WS] Relay connected (fallback)")
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
                        let prefix = data.prefix(4)
                        let prefixStr = prefix.count == 4 ? String(data: prefix, encoding: .utf8) : nil

                        if prefixStr == "H264" {
                            // Decrypt E2E-encrypted video frame (binary AES-GCM)
                            let payload = Data(data.dropFirst(4))
                            if let decrypted = self?.e2e.decryptBinary(payload) {
                                var frameData = Data("H264".utf8)
                                frameData.append(decrypted)
                                self?.onStreamFrameReceived?(frameData)
                            } else {
                                // Fallback: try as unencrypted
                                self?.onStreamFrameReceived?(data)
                            }
                        } else if prefixStr == "SCRN" {
                            let payload = Data(data.dropFirst(4))
                            if let decrypted = self?.e2e.decryptBinary(payload) {
                                self?.onScreenshotReceived?(decrypted)
                            } else {
                                self?.onScreenshotReceived?(payload)
                            }
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
                    if verified {
                        print("[WS] Authenticated (E2E ready, TLS-bound key verified)")
                    } else {
                        print("[WS] WARNING: E2E key signature verification failed — possible MITM")
                        // Still connected but E2E may be compromised — reset and rely on TLS only
                        e2e.reset()
                    }
                } else {
                    // LAN connection (no signature needed — TLS protects directly)
                    print("[WS] Authenticated (E2E ready, LAN/TLS)")
                }
            } else {
                print("[WS] Authenticated (no E2E)")
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
            print("[WS] Mac is online via relay")
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
            } else {
                print("[WS] Failed to decrypt E2E text packet")
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
                        print("[WS] Ping timeout — no pong in 15s, treating as disconnected")
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
                    // Fingerprint changed — reject connection to prevent potential MITM.
                    // Smart connect will automatically fall back to relay.
                    print("[WS] TLS fingerprint changed — rejecting LAN connection, will fall back to relay")
                    completion(false)
                }
            } else {
                // First connect (TOFU) — accept and pin later via authSuccess payload
                print("[WS] TLS first connect — trusting certificate")
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
            print("[WS] E2E binding failed: certificate fingerprint doesn't match pinned TLS cert")
            return false
        }

        // Create SecCertificate and extract public key
        guard let certificate = SecCertificateCreateWithData(nil, certData as CFData) else {
            print("[WS] E2E binding failed: invalid certificate data")
            return false
        }

        var trust: SecTrust?
        let policy = SecPolicyCreateBasicX509()
        guard SecTrustCreateWithCertificates(certificate, policy, &trust) == errSecSuccess,
              let trustRef = trust else {
            return false
        }

        guard let publicKey = SecTrustCopyKey(trustRef) else {
            print("[WS] E2E binding failed: could not extract public key from certificate")
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

        if !verified {
            print("[WS] E2E binding failed: signature verification error: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        }

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
