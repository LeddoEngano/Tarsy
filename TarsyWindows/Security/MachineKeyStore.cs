using System;
using System.Security.Cryptography;

namespace TarsyWindows.Security;

/// <summary>
/// Stores the machine's P-256 ECDSA identity key used to authenticate with
/// the Tarsy relay. Mirrors the macOS MachineKeyStore (which uses Apple's
/// Secure Enclave).
///
/// Tries to create the key in the TPM-backed Microsoft Platform Crypto
/// Provider first (hardware-backed, like Secure Enclave). Falls back to the
/// software provider (Microsoft Software Key Storage Provider) for systems
/// without TPM 2.0. In both cases the key is marked non-exportable
/// (CngExportPolicies.None) so it can't be extracted from the process.
///
/// The private key never leaves the process. Signing is silent — no Windows
/// Hello prompt, no password. Same design constraint as macOS.
/// </summary>
public sealed class MachineKeyStore : IDisposable
{
    private const string KeyName = "tarsy.machine.p256.v1";

    private readonly CngKey _key;
    private readonly ECDsaCng _ecdsa;

    /// <summary>
    /// DER-encoded SubjectPublicKeyInfo (SPKI) — ~91 bytes for P-256.
    /// Same format as macOS CryptoKit <c>.derRepresentation</c> and what the
    /// relay stores in <c>machine_tokens.public_key</c>.
    /// </summary>
    public byte[] PublicKeyDer { get; }

    /// <summary>
    /// Human-readable name of the backend that ended up holding the key —
    /// "tpm" when the TPM-backed provider succeeds, "software" otherwise.
    /// Useful for logging / diagnostics only.
    /// </summary>
    public string Backend { get; }

    private MachineKeyStore(CngKey key, string backend)
    {
        _key = key;
        _ecdsa = new ECDsaCng(key);
        Backend = backend;
        PublicKeyDer = _ecdsa.ExportSubjectPublicKeyInfo();
    }

    /// <summary>
    /// Load the existing machine key, or create one the first time this is
    /// called. Key material is persisted by CNG tied to the current Windows
    /// user profile.
    /// </summary>
    public static MachineKeyStore LoadOrCreate()
    {
        // 1. TPM-backed provider (hardware root of trust, Win 10+ with TPM 2.0)
        var tpmProvider = CngProvider.MicrosoftPlatformCryptoProvider;
        if (CngKey.Exists(KeyName, tpmProvider))
        {
            return new MachineKeyStore(CngKey.Open(KeyName, tpmProvider), "tpm");
        }
        try
        {
            var tpmParams = new CngKeyCreationParameters
            {
                Provider = tpmProvider,
                KeyCreationOptions = CngKeyCreationOptions.None, // CurrentUser
                ExportPolicy = CngExportPolicies.None,           // non-exportable
                KeyUsage = CngKeyUsages.Signing,
            };
            var tpmKey = CngKey.Create(CngAlgorithm.ECDsaP256, KeyName, tpmParams);
            return new MachineKeyStore(tpmKey, "tpm");
        }
        catch (CryptographicException)
        {
            // TPM unavailable or busy — fall through to software provider.
        }

        // 2. Software fallback (Microsoft Software Key Storage Provider,
        // DPAPI-backed on disk, still non-exportable from the process).
        var swProvider = CngProvider.MicrosoftSoftwareKeyStorageProvider;
        if (CngKey.Exists(KeyName, swProvider))
        {
            return new MachineKeyStore(CngKey.Open(KeyName, swProvider), "software");
        }
        var swParams = new CngKeyCreationParameters
        {
            Provider = swProvider,
            KeyCreationOptions = CngKeyCreationOptions.None,
            ExportPolicy = CngExportPolicies.None,
            KeyUsage = CngKeyUsages.Signing,
        };
        var swKey = CngKey.Create(CngAlgorithm.ECDsaP256, KeyName, swParams);
        return new MachineKeyStore(swKey, "software");
    }

    /// <summary>
    /// Signs an arbitrary message (typically the canonical auth string
    /// <c>machine_id:timestamp_ms:user_id</c>). Returns a DER-encoded ECDSA
    /// signature. Matches the relay's <c>crypto.verify(..., { dsaEncoding:
    /// 'der' })</c>.
    /// </summary>
    public byte[] Sign(byte[] message)
    {
        return _ecdsa.SignData(
            message,
            HashAlgorithmName.SHA256,
            DSASignatureFormat.Rfc3279DerSequence
        );
    }

    public void Dispose()
    {
        _ecdsa.Dispose();
        _key.Dispose();
    }
}
