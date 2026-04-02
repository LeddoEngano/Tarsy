import Foundation
import Security
import CryptoKit

/// Manages a persistent self-signed TLS identity for the LAN WebSocket server and E2E key signing.
///
/// Key material is stored as files in Application Support (no Keychain prompts).
/// The Keychain is only used for NWListener's SecIdentity (data protection keychain, no prompt).
/// If the Keychain identity fails (e.g., missing entitlement), NWListener falls back to no-TLS
/// while E2E signing still works via file-based keys.
final class TLSCertificateManager {
    static let shared = TLSCertificateManager()

    private let keychainLabel = "com.tarsy.macos.tls"
    private let keychainTag = "com.tarsy.macos.tls.key".data(using: .utf8)!

    /// Cached in-memory private key (loaded from file, never from Keychain)
    private var cachedPrivateKey: SecKey?
    /// Cached certificate DER data (loaded from file)
    private var cachedCertDER: Data?

    private init() {}

    // MARK: - File Paths

    private var tlsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Tarsy/tls", isDirectory: true)
    }

    private var privateKeyFile: URL { tlsDirectory.appendingPathComponent("private-key.dat") }
    private var certificateFile: URL { tlsDirectory.appendingPathComponent("certificate.der") }

    // MARK: - Public API

    /// Returns a SecIdentity for NWListener TLS (LAN only).
    /// Uses the data protection keychain. Returns nil if keychain access fails —
    /// the WebSocket server will fall back to non-TLS (E2E encryption still protects data).
    func getOrCreateIdentity() -> SecIdentity? {
        // First ensure file-based key material exists
        ensureKeyMaterial()

        // Try loading identity from data protection keychain
        if let existing = loadIdentityFromKeychain() {
            return existing
        }

        // Try creating identity in data protection keychain from our file-based key material
        return importIdentityToKeychain()
    }

    /// Returns the SHA-256 fingerprint of the certificate for TOFU pinning.
    func certificateFingerprint() -> String? {
        guard let certData = loadCertificateDER() else { return nil }
        return sha256Hex(certData)
    }

    /// Signs data with the TLS private key (RSA-PSS SHA256).
    /// Uses file-based key — never touches the Keychain, never prompts.
    func sign(_ data: Data) -> Data? {
        guard let privateKey = loadPrivateKey() else { return nil }

        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePSSSHA256,
            data as CFData,
            &error
        ) else {
            return nil
        }

        return signature as Data
    }

    /// Returns the DER-encoded certificate data for verification on the iOS side.
    func certificateDER() -> Data? {
        return loadCertificateDER()
    }

    // MARK: - File-Based Key Material

    /// Ensures key material files exist. Generates new key + cert on first launch.
    private func ensureKeyMaterial() {
        if FileManager.default.fileExists(atPath: privateKeyFile.path),
           FileManager.default.fileExists(atPath: certificateFile.path) {
            return
        }
        generateAndSaveKeyMaterial()
    }

    /// Loads the private key from file into an in-memory SecKey.
    private func loadPrivateKey() -> SecKey? {
        if let cached = cachedPrivateKey { return cached }

        ensureKeyMaterial()

        guard let keyData = try? Data(contentsOf: privateKeyFile) else { return nil }

        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2048
        ]

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(keyData as CFData, attrs as CFDictionary, &error) else {
            #if DEBUG
            print("[TLS] Failed to create SecKey from file: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
            #endif
            return nil
        }

        cachedPrivateKey = key
        return key
    }

    /// Loads the certificate DER from file.
    private func loadCertificateDER() -> Data? {
        if let cached = cachedCertDER { return cached }

        ensureKeyMaterial()

        guard let data = try? Data(contentsOf: certificateFile), !data.isEmpty else { return nil }
        cachedCertDER = data
        return data
    }

    /// Generates a new RSA key pair and self-signed certificate, saves to files.
    private func generateAndSaveKeyMaterial() {
        // Create directory
        try? FileManager.default.createDirectory(at: tlsDirectory, withIntermediateDirectories: true)

        // 1. Generate RSA key pair in memory (NOT in Keychain)
        let keyPairAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyPairAttrs as CFDictionary, &error) else {
            #if DEBUG
            print("[TLS] Failed to generate RSA key pair: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
            #endif
            return
        }

        // 2. Export private key raw data and save to file
        guard let keyData = SecKeyCopyExternalRepresentation(privateKey, nil) as Data? else {
            #if DEBUG
            print("[TLS] Failed to export private key")
            #endif
            return
        }

        // Set restrictive permissions (owner read/write only)
        FileManager.default.createFile(atPath: privateKeyFile.path, contents: keyData, attributes: [
            .posixPermissions: 0o600
        ])

        // 3. Create self-signed certificate via openssl
        let pemKey = "-----BEGIN RSA PRIVATE KEY-----\n" +
            keyData.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed]) +
            "\n-----END RSA PRIVATE KEY-----\n"

        guard let pemKeyData = pemKey.data(using: .utf8) else { return }

        let rawHostname = Host.current().localizedName ?? "tarsy-mac"
        let hostname = rawHostname.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        let subject = "/CN=\(hostname)/O=Tarsy/OU=LAN"

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
            keyInputPipe.fileHandleForWriting.write(pemKeyData)
            keyInputPipe.fileHandleForWriting.closeFile()
            genCert.waitUntilExit()

            guard genCert.terminationStatus == 0 else {
                #if DEBUG
                print("[TLS] openssl cert generation failed with status \(genCert.terminationStatus)")
                #endif
                return
            }
        } catch {
            #if DEBUG
            print("[TLS] openssl process failed: \(error)")
            #endif
            return
        }

        let certDER = certOutputPipe.fileHandleForReading.readDataToEndOfFile()
        guard !certDER.isEmpty else {
            #if DEBUG
            print("[TLS] Empty DER data from openssl")
            #endif
            return
        }

        // 4. Save certificate DER to file
        try? certDER.write(to: certificateFile)

        // Cache in memory
        cachedPrivateKey = privateKey
        cachedCertDER = certDER

        #if DEBUG
        print("[TLS] Key material generated and saved to Application Support")
        #endif
    }

    // MARK: - Keychain (for NWListener SecIdentity only)

    private func loadIdentityFromKeychain() -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: keychainLabel,
            kSecReturnRef as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let identity = result else {
            return nil
        }

        return (identity as! SecIdentity)
    }

    /// Imports our file-based key+cert into the data protection keychain to create a SecIdentity.
    /// This is only needed for NWListener TLS. If it fails, NWListener runs without TLS.
    private func importIdentityToKeychain() -> SecIdentity? {
        guard let keyData = try? Data(contentsOf: privateKeyFile),
              let certData = try? Data(contentsOf: certificateFile) else {
            return nil
        }

        // Store private key in data protection keychain
        let addKeyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2048,
            kSecValueData as String: keyData,
            kSecAttrLabel as String: keychainLabel,
            kSecAttrApplicationTag as String: keychainTag,
            kSecAttrIsPermanent as String: true,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let keyStatus = SecItemAdd(addKeyQuery as CFDictionary, nil)
        guard keyStatus == errSecSuccess || keyStatus == errSecDuplicateItem else {
            #if DEBUG
            print("[TLS] Failed to import key to keychain: \(keyStatus)")
            #endif
            return nil
        }

        // Store certificate in data protection keychain
        guard let certificate = SecCertificateCreateWithData(nil, certData as CFData) else {
            return nil
        }

        let addCertQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: keychainLabel,
            kSecUseDataProtectionKeychain as String: true
        ]

        let certStatus = SecItemAdd(addCertQuery as CFDictionary, nil)
        guard certStatus == errSecSuccess || certStatus == errSecDuplicateItem else {
            #if DEBUG
            print("[TLS] Failed to import cert to keychain: \(certStatus)")
            #endif
            return nil
        }

        return loadIdentityFromKeychain()
    }

    // MARK: - Utilities

    private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// Deletes stored key material (files + keychain).
    func deleteIdentity() {
        // Delete files
        try? FileManager.default.removeItem(at: privateKeyFile)
        try? FileManager.default.removeItem(at: certificateFile)
        cachedPrivateKey = nil
        cachedCertDER = nil

        // Delete from keychain
        let queries: [[String: Any]] = [
            [kSecClass as String: kSecClassIdentity, kSecAttrLabel as String: keychainLabel, kSecUseDataProtectionKeychain as String: true],
            [kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: keychainLabel, kSecUseDataProtectionKeychain as String: true],
            [kSecClass as String: kSecClassKey, kSecAttrLabel as String: keychainLabel, kSecUseDataProtectionKeychain as String: true]
        ]
        for query in queries {
            SecItemDelete(query as CFDictionary)
        }

        // Also clean up any leftover items in login keychain (from previous versions)
        let loginQueries: [[String: Any]] = [
            [kSecClass as String: kSecClassIdentity, kSecAttrLabel as String: keychainLabel],
            [kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: keychainLabel],
            [kSecClass as String: kSecClassKey, kSecAttrLabel as String: keychainLabel]
        ]
        for query in loginQueries {
            SecItemDelete(query as CFDictionary)
        }

        #if DEBUG
        print("[TLS] Identity deleted (files + keychain)")
        #endif
    }
}
