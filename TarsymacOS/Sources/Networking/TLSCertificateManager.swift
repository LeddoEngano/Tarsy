import Foundation
import Security
import CryptoKit

/// Manages a persistent self-signed TLS identity (private key + certificate) for the LAN WebSocket server.
/// The identity is generated on first launch and stored in the Keychain for reuse across app sessions.
/// The SHA-256 fingerprint can be shared with iOS clients for trust-on-first-use (TOFU) pinning.
final class TLSCertificateManager {
    static let shared = TLSCertificateManager()

    private let keychainLabel = "com.tarsy.macos.tls"
    private let keychainTag = "com.tarsy.macos.tls.key".data(using: .utf8)!

    private init() {}

    // MARK: - Public API

    /// Returns the SecIdentity for use in NWListener TLS configuration.
    /// Generates a new identity on first call if none exists in Keychain.
    func getOrCreateIdentity() -> SecIdentity? {
        if let existing = loadIdentityFromKeychain() {
            print("[TLS] Loaded existing identity from Keychain")
            return existing
        }

        print("[TLS] No existing identity found, generating new self-signed certificate...")
        guard let identity = generateSelfSignedIdentity() else {
            print("[TLS] Failed to generate self-signed identity")
            return nil
        }

        print("[TLS] Self-signed identity generated and stored in Keychain")
        return identity
    }

    /// Returns the SHA-256 fingerprint of the certificate for TOFU pinning.
    func certificateFingerprint() -> String? {
        guard let identity = getOrCreateIdentity() else { return nil }
        var certRef: SecCertificate?
        let status = SecIdentityCopyCertificate(identity, &certRef)
        guard status == errSecSuccess, let cert = certRef else { return nil }

        let certData = SecCertificateCopyData(cert) as Data
        return sha256Hex(certData)
    }

    // MARK: - Keychain Operations

    private func loadIdentityFromKeychain() -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: keychainLabel,
            kSecReturnRef as String: true
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let identity = result else {
            return nil
        }

        return (identity as! SecIdentity)
    }

    // MARK: - Self-Signed Certificate Generation

    private func generateSelfSignedIdentity() -> SecIdentity? {
        // 1. Generate RSA key pair
        let keyPairAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecAttrLabel as String: keychainLabel,
            kSecAttrApplicationTag as String: keychainTag,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrLabel as String: keychainLabel,
                kSecAttrApplicationTag as String: keychainTag
            ] as [String: Any]
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyPairAttrs as CFDictionary, &error) else {
            print("[TLS] Key generation failed: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
            return nil
        }

        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            print("[TLS] Failed to extract public key")
            return nil
        }

        // 2. Create self-signed certificate using the system's certificate creation
        guard let certData = createSelfSignedCertificateData(publicKey: publicKey, privateKey: privateKey) else {
            print("[TLS] Failed to create certificate data")
            return nil
        }

        guard let certificate = SecCertificateCreateWithData(nil, certData as CFData) else {
            print("[TLS] Failed to create SecCertificate from data")
            return nil
        }

        // 3. Store certificate in Keychain
        let addCertQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: keychainLabel
        ]

        let addStatus = SecItemAdd(addCertQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            print("[TLS] Failed to store certificate in Keychain: \(addStatus)")
            return nil
        }

        // 4. Load the identity (key + cert pair) from Keychain
        return loadIdentityFromKeychain()
    }

    /// Creates a DER-encoded self-signed X.509 certificate.
    /// Uses Security.framework's SecCertificateCreateWithData after building the ASN.1 structure.
    private func createSelfSignedCertificateData(publicKey: SecKey, privateKey: SecKey) -> Data? {
        // Use macOS 10.15+ approach: create certificate via command-line openssl
        // This is the most reliable way to create a self-signed cert on macOS
        // Export private key to PEM (in memory only — never written to disk)
        guard let keyData = SecKeyCopyExternalRepresentation(privateKey, nil) as Data? else {
            print("[TLS] Failed to export private key")
            return nil
        }

        let pemKey = "-----BEGIN RSA PRIVATE KEY-----\n" +
            keyData.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed]) +
            "\n-----END RSA PRIVATE KEY-----\n"

        guard let pemKeyData = pemKey.data(using: .utf8) else { return nil }

        // Sanitize hostname for use in subject DN
        let rawHostname = Host.current().localizedName ?? "tarsy-mac"
        let hostname = rawHostname.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        let subject = "/CN=\(hostname)/O=Tarsy/OU=LAN"

        // Generate self-signed certificate — key material piped via stdin (never touches disk)
        let genCert = Process()
        let keyInputPipe = Pipe()
        let certOutputPipe = Pipe()
        genCert.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        genCert.arguments = [
            "req", "-new", "-x509",
            "-key", "/dev/stdin",
            "-days", "3650",
            "-subj", subject,
            "-addext", "subjectAltName=DNS:\(hostname),DNS:localhost,IP:127.0.0.1",
            "-sha256",
            "-outform", "DER"
        ]
        genCert.standardInput = keyInputPipe
        genCert.standardOutput = certOutputPipe
        genCert.standardError = FileHandle.nullDevice

        do {
            try genCert.run()
            // Write key to stdin and close to signal EOF
            keyInputPipe.fileHandleForWriting.write(pemKeyData)
            keyInputPipe.fileHandleForWriting.closeFile()
            genCert.waitUntilExit()

            guard genCert.terminationStatus == 0 else {
                print("[TLS] openssl cert generation failed with status \(genCert.terminationStatus)")
                return nil
            }
        } catch {
            print("[TLS] openssl process failed: \(error)")
            return nil
        }

        let derData = certOutputPipe.fileHandleForReading.readDataToEndOfFile()
        guard !derData.isEmpty else {
            print("[TLS] Empty DER data from openssl")
            return nil
        }

        return derData
    }

    // MARK: - Utilities

    private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// Deletes the stored identity from Keychain (for testing/reset).
    func deleteIdentity() {
        let queries: [[String: Any]] = [
            [kSecClass as String: kSecClassIdentity, kSecAttrLabel as String: keychainLabel],
            [kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: keychainLabel],
            [kSecClass as String: kSecClassKey, kSecAttrLabel as String: keychainLabel]
        ]
        for query in queries {
            SecItemDelete(query as CFDictionary)
        }
        print("[TLS] Identity deleted from Keychain")
    }
}
