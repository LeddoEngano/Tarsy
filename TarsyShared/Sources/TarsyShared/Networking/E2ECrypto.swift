import Foundation
import CryptoKit

/// End-to-end encryption for sensitive payloads (sudo passwords, API keys).
/// Uses ECDH key exchange + AES-GCM so the relay server never sees plaintext.
///
/// Flow:
/// 1. Both sides generate ephemeral P256 key pairs
/// 2. Public keys are exchanged via authSuccess/auth packets
/// 3. Shared secret is derived via ECDH
/// 4. Sensitive payloads are encrypted with AES-GCM using the shared secret
public final class E2ECrypto {
    private var privateKey: P256.KeyAgreement.PrivateKey
    private var sharedSecret: SymmetricKey?

    /// Our public key to send to the other side
    public var publicKeyData: Data {
        privateKey.publicKey.rawRepresentation
    }

    /// Base64-encoded public key for embedding in WSPacket payloads
    public var publicKeyBase64: String {
        publicKeyData.base64EncodedString()
    }

    /// Whether the key exchange is complete and encryption is available
    public var isReady: Bool {
        sharedSecret != nil
    }

    public init() {
        self.privateKey = P256.KeyAgreement.PrivateKey()
    }

    /// Complete the key exchange with the remote side's public key.
    /// Call this when receiving the other side's public key from authSuccess/auth.
    public func completeKeyExchange(remotePublicKeyBase64: String) -> Bool {
        guard let remoteKeyData = Data(base64Encoded: remotePublicKeyBase64),
              let remotePublicKey = try? P256.KeyAgreement.PublicKey(rawRepresentation: remoteKeyData) else {
            return false
        }

        guard let shared = try? privateKey.sharedSecretFromKeyAgreement(with: remotePublicKey) else {
            return false
        }

        // Derive a symmetric key using HKDF
        sharedSecret = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: "tarsy-e2e-v1".data(using: .utf8)!,
            sharedInfo: Data(),
            outputByteCount: 32
        )

        return true
    }

    /// Encrypt a string payload. Returns base64-encoded ciphertext (nonce + ciphertext + tag).
    public func encrypt(_ plaintext: String) -> String? {
        guard let key = sharedSecret,
              let data = plaintext.data(using: .utf8) else { return nil }

        guard let sealedBox = try? AES.GCM.seal(data, using: key) else { return nil }
        return sealedBox.combined?.base64EncodedString()
    }

    /// Decrypt a base64-encoded ciphertext. Returns plaintext string.
    public func decrypt(_ ciphertext: String) -> String? {
        guard let key = sharedSecret,
              let combined = Data(base64Encoded: ciphertext) else { return nil }

        guard let sealedBox = try? AES.GCM.SealedBox(combined: combined),
              let data = try? AES.GCM.open(sealedBox, using: key) else { return nil }

        return String(data: data, encoding: .utf8)
    }

    // MARK: - Binary encryption (for video frames, screenshots — no base64 overhead)

    /// Encrypt raw binary data. Returns nonce (12) + ciphertext + tag (16).
    /// Uses hardware-accelerated AES-GCM via CryptoKit. Overhead: 28 bytes per frame.
    public func encryptBinary(_ plaintext: Data) -> Data? {
        guard let key = sharedSecret else { return nil }
        guard let sealedBox = try? AES.GCM.seal(plaintext, using: key) else { return nil }
        return sealedBox.combined
    }

    /// Decrypt raw binary data (nonce + ciphertext + tag). Returns plaintext data.
    public func decryptBinary(_ ciphertext: Data) -> Data? {
        guard let key = sharedSecret else { return nil }
        guard let sealedBox = try? AES.GCM.SealedBox(combined: ciphertext),
              let data = try? AES.GCM.open(sealedBox, using: key) else { return nil }
        return data
    }

    // MARK: - Text packet encryption (wraps entire WSPacket JSON)

    /// Encrypt a WSPacket's JSON data for transit. Returns encrypted Data.
    public func encryptPacket(_ packetData: Data) -> Data? {
        encryptBinary(packetData)
    }

    /// Decrypt an encrypted WSPacket. Returns the original JSON Data.
    public func decryptPacket(_ ciphertext: Data) -> Data? {
        decryptBinary(ciphertext)
    }

    /// Reset keys (e.g., on disconnect). Generates a new ephemeral key pair.
    public func reset() {
        privateKey = P256.KeyAgreement.PrivateKey()
        sharedSecret = nil
    }
}
