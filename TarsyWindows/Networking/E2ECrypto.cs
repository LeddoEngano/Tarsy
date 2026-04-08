using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace TarsyWindows.Networking;

/// <summary>
/// End-to-end encryption — mirrors TarsyShared/Networking/E2ECrypto.swift.
///
/// Protocol:
/// - ECDH P-256 key exchange (ECDiffieHellman)
/// - HKDF-SHA256 with salt "tarsy-e2e-v1" → 256-bit AES-GCM key
/// - AES-GCM: 12-byte random nonce, 16-byte auth tag
///
/// Text format:  base64(nonce_12 + ciphertext + tag_16)
/// Binary format: raw bytes nonce(12) + ciphertext + tag(16)
/// </summary>
public class E2ECrypto : IDisposable
{
    private static readonly byte[] HkdfSalt = Encoding.UTF8.GetBytes("tarsy-e2e-v1");
    private const int NonceSize = 12;
    private const int TagSize = 16;
    private const int KeySize = 32; // 256-bit

    private ECDiffieHellman _ecdh;
    private byte[]? _sharedKey;

    /// <summary>
    /// Our raw public key (65 bytes uncompressed P-256) for sending to the remote side.
    /// </summary>
    public byte[] PublicKeyData { get; private set; }

    /// <summary>
    /// Base64-encoded public key for embedding in WSPacket payloads.
    /// </summary>
    public string PublicKeyBase64 => Convert.ToBase64String(PublicKeyData);

    /// <summary>
    /// Whether key exchange is complete and encryption is available.
    /// </summary>
    public bool IsReady => _sharedKey != null;

    public E2ECrypto()
    {
        _ecdh = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
        PublicKeyData = ExportRawPublicKey(_ecdh);
    }

    /// <summary>
    /// Complete key exchange with the remote side's public key.
    /// </summary>
    public bool CompleteKeyExchange(string remotePublicKeyBase64)
    {
        try
        {
            var remoteKeyData = Convert.FromBase64String(remotePublicKeyBase64);
            return CompleteKeyExchange(remoteKeyData);
        }
        catch
        {
            _sharedKey = null;
            return false;
        }
    }

    /// <summary>
    /// Complete key exchange with the remote side's raw public key bytes.
    /// </summary>
    public bool CompleteKeyExchange(byte[] remotePublicKeyData)
    {
        try
        {
            using var remoteEcdh = ECDiffieHellman.Create();
            remoteEcdh.ImportSubjectPublicKeyInfo(
                ConvertRawToSpki(remotePublicKeyData), out _);

            // Derive raw shared secret via ECDH
            var sharedSecret = _ecdh.DeriveRawSecretAgreement(remoteEcdh.PublicKey);

            // Derive AES key via HKDF-SHA256
            _sharedKey = HKDF.DeriveKey(
                HashAlgorithmName.SHA256,
                sharedSecret,
                KeySize,
                salt: HkdfSalt,
                info: Array.Empty<byte>()
            );

            // Zero out the raw shared secret
            CryptographicOperations.ZeroMemory(sharedSecret);

            return true;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[E2E] Key exchange failed: {ex.Message}");
            _sharedKey = null;
            return false;
        }
    }

    // ════════════════════════════════════════════════
    // ── Text Encryption (base64 format) ──
    // ════════════════════════════════════════════════

    /// <summary>
    /// Encrypt a plaintext string → base64(nonce + ciphertext + tag).
    /// </summary>
    public string? Encrypt(string plaintext)
    {
        if (_sharedKey == null) return null;

        try
        {
            var data = Encoding.UTF8.GetBytes(plaintext);
            var encrypted = EncryptBinary(data);
            return encrypted != null ? Convert.ToBase64String(encrypted) : null;
        }
        catch
        {
            return null;
        }
    }

    /// <summary>
    /// Decrypt a base64-encoded ciphertext → plaintext string.
    /// </summary>
    public string? Decrypt(string ciphertextBase64)
    {
        if (_sharedKey == null) return null;

        try
        {
            var combined = Convert.FromBase64String(ciphertextBase64);
            var decrypted = DecryptBinary(combined);
            return decrypted != null ? Encoding.UTF8.GetString(decrypted) : null;
        }
        catch
        {
            return null;
        }
    }

    // ════════════════════════════════════════════════
    // ── Binary Encryption (raw bytes) ──
    // ════════════════════════════════════════════════

    /// <summary>
    /// Encrypt raw binary data → nonce(12) + ciphertext + tag(16).
    /// </summary>
    public byte[]? EncryptBinary(byte[] plaintext)
    {
        if (_sharedKey == null) return null;

        try
        {
            var nonce = new byte[NonceSize];
            RandomNumberGenerator.Fill(nonce);

            var ciphertext = new byte[plaintext.Length];
            var tag = new byte[TagSize];

            using var aes = new AesGcm(_sharedKey, TagSize);
            aes.Encrypt(nonce, plaintext, ciphertext, tag);

            // Combine: nonce(12) + ciphertext + tag(16)
            var combined = new byte[NonceSize + ciphertext.Length + TagSize];
            Buffer.BlockCopy(nonce, 0, combined, 0, NonceSize);
            Buffer.BlockCopy(ciphertext, 0, combined, NonceSize, ciphertext.Length);
            Buffer.BlockCopy(tag, 0, combined, NonceSize + ciphertext.Length, TagSize);

            return combined;
        }
        catch
        {
            return null;
        }
    }

    /// <summary>
    /// Decrypt raw binary data: nonce(12) + ciphertext + tag(16) → plaintext.
    /// </summary>
    public byte[]? DecryptBinary(byte[] combined)
    {
        if (_sharedKey == null) return null;
        if (combined.Length < NonceSize + TagSize) return null;

        try
        {
            var nonce = new byte[NonceSize];
            var ciphertextLength = combined.Length - NonceSize - TagSize;
            var ciphertext = new byte[ciphertextLength];
            var tag = new byte[TagSize];

            Buffer.BlockCopy(combined, 0, nonce, 0, NonceSize);
            Buffer.BlockCopy(combined, NonceSize, ciphertext, 0, ciphertextLength);
            Buffer.BlockCopy(combined, NonceSize + ciphertextLength, tag, 0, TagSize);

            var plaintext = new byte[ciphertextLength];

            using var aes = new AesGcm(_sharedKey, TagSize);
            aes.Decrypt(nonce, ciphertext, tag, plaintext);

            return plaintext;
        }
        catch
        {
            return null;
        }
    }

    // ════════════════════════════════════════════════
    // ── Packet-Level Encryption ──
    // ════════════════════════════════════════════════

    /// <summary>
    /// Encrypt a WSPacket → e2e:encrypted envelope.
    /// </summary>
    public WSPacket? EncryptPacket(WSPacket packet)
    {
        var json = packet.Encode();
        var encrypted = Encrypt(json);
        if (encrypted == null) return null;

        return WSPacket.Create(WSAction.E2eEncrypted, new()
        {
            ["data"] = encrypted,
        });
    }

    /// <summary>
    /// Decrypt an e2e:encrypted envelope → inner WSPacket.
    /// </summary>
    public WSPacket? DecryptPacket(WSPacket envelope)
    {
        var encrypted = envelope.Payload?.GetValueOrDefault("data");
        if (string.IsNullOrEmpty(encrypted)) return null;

        var json = Decrypt(encrypted);
        if (json == null) return null;

        try
        {
            return WSPacket.Decode(json);
        }
        catch
        {
            return null;
        }
    }

    /// <summary>
    /// Reset keys. Generates a new ephemeral key pair.
    /// </summary>
    public void Reset()
    {
        _ecdh.Dispose();
        _ecdh = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
        PublicKeyData = ExportRawPublicKey(_ecdh);

        if (_sharedKey != null)
        {
            CryptographicOperations.ZeroMemory(_sharedKey);
            _sharedKey = null;
        }
    }

    public void Dispose()
    {
        _ecdh.Dispose();
        if (_sharedKey != null)
        {
            CryptographicOperations.ZeroMemory(_sharedKey);
            _sharedKey = null;
        }
    }

    // ════════════════════════════════════════════════
    // ── Key Format Helpers ──
    // ════════════════════════════════════════════════

    /// <summary>
    /// Export the raw uncompressed public key (65 bytes: 0x04 + X + Y).
    /// This matches the format used by CryptoKit and Web Crypto API.
    /// </summary>
    private static byte[] ExportRawPublicKey(ECDiffieHellman ecdh)
    {
        var parameters = ecdh.ExportParameters(false);
        var raw = new byte[1 + 32 + 32]; // 0x04 prefix + X(32) + Y(32)
        raw[0] = 0x04; // uncompressed point
        Buffer.BlockCopy(parameters.Q.X!, 0, raw, 1, 32);
        Buffer.BlockCopy(parameters.Q.Y!, 0, raw, 33, 32);
        return raw;
    }

    /// <summary>
    /// Convert a raw uncompressed public key (65 bytes) to SPKI DER format
    /// for importing via ImportSubjectPublicKeyInfo.
    /// </summary>
    private static byte[] ConvertRawToSpki(byte[] rawKey)
    {
        // DER-encoded SubjectPublicKeyInfo for P-256
        // SEQUENCE { SEQUENCE { OID ecPublicKey, OID prime256v1 }, BIT STRING { rawKey } }
        byte[] spkiPrefix = new byte[]
        {
            0x30, 0x59,             // SEQUENCE, length 89
            0x30, 0x13,             // SEQUENCE, length 19
            0x06, 0x07,             // OID, length 7
            0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01, // OID 1.2.840.10045.2.1 (ecPublicKey)
            0x06, 0x08,             // OID, length 8
            0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, // OID 1.2.840.10045.3.1.7 (prime256v1)
            0x03, 0x42,             // BIT STRING, length 66
            0x00,                   // no unused bits
        };

        var spki = new byte[spkiPrefix.Length + rawKey.Length];
        Buffer.BlockCopy(spkiPrefix, 0, spki, 0, spkiPrefix.Length);
        Buffer.BlockCopy(rawKey, 0, spki, spkiPrefix.Length, rawKey.Length);
        return spki;
    }
}
