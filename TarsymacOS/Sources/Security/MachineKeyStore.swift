import Foundation
import CryptoKit

/// Stores the machine's P-256 ECDSA identity key used to authenticate with
/// the relay. Uses Secure Enclave when available (Apple Silicon, Intel+T2),
/// falls back to a software key persisted in Keychain for Intel Macs that
/// don't have a Secure Enclave (rare on macOS 14+).
///
/// The private key never leaves the process. Signing is silent — no user
/// presence, biometry, or password prompt — because the daemon runs headless
/// and the Mac is often remote. This is enforced by omitting
/// `userPresence`/`biometry*` flags from the `SecAccessControl` we use.
///
/// Used by `DaemonManager` during relay handshake: the relay stores the
/// corresponding public key in `machine_tokens.public_key`, generates a
/// challenge nonce (server timestamp + machine_id + user_id), the client
/// signs it with `sign(message:)`, and the relay verifies against the stored
/// public key. No shared secret ever transits.
public actor MachineKeyStore {
    public enum Error: Swift.Error, LocalizedError {
        case accessControlFailed
        case keychainStoreFailed(OSStatus)
        case secureEnclaveUnavailable

        public var errorDescription: String? {
            switch self {
            case .accessControlFailed: return "Failed to create Secure Enclave access control"
            case .keychainStoreFailed(let s): return "Keychain store failed (OSStatus \(s))"
            case .secureEnclaveUnavailable: return "Secure Enclave unavailable and software fallback failed"
            }
        }
    }

    private enum Storage {
        case secureEnclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)
    }

    // Keychain slots. v1 tag lets us add a v2 (new algorithm) later without
    // overwriting the existing handle.
    private static let keychainService = "com.tarsy.macos.machine-key"
    private static let keychainAccountSE = "p256-se-v1"
    private static let keychainAccountSW = "p256-sw-v1"

    private let storage: Storage

    /// DER-encoded SubjectPublicKeyInfo (SPKI) — ~91 bytes for P-256.
    /// This is what the relay stores in `machine_tokens.public_key` and what
    /// `Node crypto.createPublicKey({format: 'der', type: 'spki'})` accepts.
    public nonisolated let publicKeyDER: Data

    /// Which storage backend is actually holding the private key — useful for
    /// logging / telemetry, does not leak the key itself.
    public nonisolated let backend: String

    public init() throws {
        let (storage, publicKey, backend) = try Self.loadOrCreate()
        self.storage = storage
        self.publicKeyDER = publicKey
        self.backend = backend
    }

    /// Sign an arbitrary message (typically the canonical auth string
    /// "machine_id:timestamp_ms:user_id"). Returns a DER-encoded ECDSA
    /// signature that matches what Node's `crypto.verify` with
    /// `dsaEncoding: 'der'` expects.
    public func sign(message: Data) throws -> Data {
        switch storage {
        case .secureEnclave(let key):
            return try key.signature(for: message).derRepresentation
        case .software(let key):
            return try key.signature(for: message).derRepresentation
        }
    }

    // MARK: - Load / create

    private static func loadOrCreate() throws -> (Storage, Data, String) {
        if SecureEnclave.isAvailable {
            // Try to load the existing Secure Enclave handle.
            if let handle = keychainLoad(account: keychainAccountSE),
               let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: handle) {
                return (.secureEnclave(key), key.publicKey.derRepresentation, "secure-enclave")
            }
            // Create a fresh Secure Enclave key. `.privateKeyUsage` alone =
            // silent signing (no biometry, no passcode prompt).
            var cfError: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                kCFAllocatorDefault,
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                .privateKeyUsage,
                &cfError
            ) else {
                throw Error.accessControlFailed
            }
            do {
                let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
                try keychainStore(data: key.dataRepresentation, account: keychainAccountSE)
                return (.secureEnclave(key), key.publicKey.derRepresentation, "secure-enclave")
            } catch {
                // Fall through to software — SE can fail on broken hardware or
                // revoked entitlements; we prefer "works, but less secure"
                // over "headless daemon unable to auth".
            }
        }

        // Software fallback (Intel Macs without T2, or SE creation failure).
        if let raw = keychainLoad(account: keychainAccountSW),
           let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) {
            return (.software(key), key.publicKey.derRepresentation, "software-keychain")
        }
        let key = P256.Signing.PrivateKey()
        try keychainStore(data: key.rawRepresentation, account: keychainAccountSW)
        return (.software(key), key.publicKey.derRepresentation, "software-keychain")
    }

    // MARK: - Keychain helpers

    private static func keychainLoad(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func keychainStore(data: Data, account: String) throws {
        // Idempotent: delete any existing entry then add fresh
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw Error.keychainStoreFailed(status)
        }
    }
}

/// Immutable bundle handed to `RelayClient.connect` so it can produce a fresh
/// signed-timestamp auth payload on every (re)connect without knowing the key
/// storage details. All members are `Sendable` so it crosses actor boundaries
/// safely.
public struct MachineAuthIdentity: Sendable {
    public let machineId: String
    public let userId: String
    public let publicKeyDER: Data
    public let signer: @Sendable (Data) async throws -> Data

    public init(
        machineId: String,
        userId: String,
        publicKeyDER: Data,
        signer: @escaping @Sendable (Data) async throws -> Data
    ) {
        self.machineId = machineId
        self.userId = userId
        self.publicKeyDER = publicKeyDER
        self.signer = signer
    }
}
