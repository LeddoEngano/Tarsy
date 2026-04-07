/**
 * E2ECrypto — End-to-end encryption matching TarsyShared/Networking/E2ECrypto.swift.
 *
 * Protocol:
 * - ECDH P-256 key exchange
 * - HKDF-SHA256 with salt "tarsy-e2e-v1" → 256-bit AES-GCM key
 * - AES-GCM: 12-byte nonce, 16-byte tag
 *
 * Text format: base64(nonce + ciphertext + tag)
 * Binary format: Uint8Array(nonce + ciphertext + tag)
 */

const HKDF_SALT = new TextEncoder().encode("tarsy-e2e-v1");

export class E2ECrypto {
  /** @type {CryptoKeyPair | null} */
  #keyPair = null;
  /** @type {CryptoKey | null} */
  #sharedKey = null;
  /** @type {string | null} */
  #publicKeyBase64 = null;

  /** Whether key exchange is complete and encryption is ready. */
  get isReady() {
    return this.#sharedKey !== null;
  }

  /** Base64-encoded public key to send to the companion. */
  get publicKeyBase64() {
    return this.#publicKeyBase64;
  }

  /** Generate a fresh ephemeral key pair. */
  async initialize() {
    this.#keyPair = await crypto.subtle.generateKey(
      { name: "ECDH", namedCurve: "P-256" },
      true,
      ["deriveBits"]
    );

    const rawPublicKey = await crypto.subtle.exportKey("raw", this.#keyPair.publicKey);
    this.#publicKeyBase64 = arrayBufferToBase64(rawPublicKey);
    this.#sharedKey = null;
  }

  /**
   * Complete key exchange with the remote public key.
   * @param {string} remotePublicKeyBase64 — base64-encoded raw public key from companion
   * @returns {boolean} true if key exchange succeeded
   */
  async completeKeyExchange(remotePublicKeyBase64) {
    try {
      const remoteKeyData = base64ToArrayBuffer(remotePublicKeyBase64);
      const remotePublicKey = await crypto.subtle.importKey(
        "raw",
        remoteKeyData,
        { name: "ECDH", namedCurve: "P-256" },
        false,
        []
      );

      // Derive raw shared secret via ECDH
      const sharedBits = await crypto.subtle.deriveBits(
        { name: "ECDH", public: remotePublicKey },
        this.#keyPair.privateKey,
        256
      );

      // Import shared bits as HKDF key material
      const hkdfKey = await crypto.subtle.importKey(
        "raw",
        sharedBits,
        "HKDF",
        false,
        ["deriveKey"]
      );

      // Derive AES-GCM key via HKDF-SHA256
      this.#sharedKey = await crypto.subtle.deriveKey(
        {
          name: "HKDF",
          hash: "SHA-256",
          salt: HKDF_SALT,
          info: new Uint8Array(0),
        },
        hkdfKey,
        { name: "AES-GCM", length: 256 },
        false,
        ["encrypt", "decrypt"]
      );

      return true;
    } catch {
      this.#sharedKey = null;
      return false;
    }
  }

  /**
   * Encrypt a plaintext string → base64 ciphertext.
   * @param {string} plaintext
   * @returns {string | null} base64(nonce + ciphertext + tag)
   */
  async encrypt(plaintext) {
    if (!this.#sharedKey) return null;

    try {
      const data = new TextEncoder().encode(plaintext);
      const nonce = crypto.getRandomValues(new Uint8Array(12));

      const ciphertext = await crypto.subtle.encrypt(
        { name: "AES-GCM", iv: nonce },
        this.#sharedKey,
        data
      );

      // Combine: nonce (12) + ciphertext + tag (appended by AES-GCM)
      const combined = new Uint8Array(12 + ciphertext.byteLength);
      combined.set(nonce, 0);
      combined.set(new Uint8Array(ciphertext), 12);

      return arrayBufferToBase64(combined.buffer);
    } catch {
      return null;
    }
  }

  /**
   * Decrypt a base64 ciphertext → plaintext string.
   * @param {string} ciphertextBase64
   * @returns {string | null}
   */
  async decrypt(ciphertextBase64) {
    if (!this.#sharedKey) return null;

    try {
      const combined = new Uint8Array(base64ToArrayBuffer(ciphertextBase64));
      const nonce = combined.slice(0, 12);
      const ciphertext = combined.slice(12);

      const plaintext = await crypto.subtle.decrypt(
        { name: "AES-GCM", iv: nonce },
        this.#sharedKey,
        ciphertext
      );

      return new TextDecoder().decode(plaintext);
    } catch {
      return null;
    }
  }

  /**
   * Encrypt binary data → Uint8Array(nonce + ciphertext + tag).
   * @param {Uint8Array} data
   * @returns {Uint8Array | null}
   */
  async encryptBinary(data) {
    if (!this.#sharedKey) return null;

    try {
      const nonce = crypto.getRandomValues(new Uint8Array(12));

      const ciphertext = await crypto.subtle.encrypt(
        { name: "AES-GCM", iv: nonce },
        this.#sharedKey,
        data
      );

      const combined = new Uint8Array(12 + ciphertext.byteLength);
      combined.set(nonce, 0);
      combined.set(new Uint8Array(ciphertext), 12);

      return combined;
    } catch {
      return null;
    }
  }

  /**
   * Decrypt binary data → Uint8Array.
   * @param {Uint8Array} combined — nonce(12) + ciphertext + tag(16)
   * @returns {Uint8Array | null}
   */
  async decryptBinary(combined) {
    if (!this.#sharedKey) return null;

    try {
      const nonce = combined.slice(0, 12);
      const ciphertext = combined.slice(12);

      const plaintext = await crypto.subtle.decrypt(
        { name: "AES-GCM", iv: nonce },
        this.#sharedKey,
        ciphertext
      );

      return new Uint8Array(plaintext);
    } catch {
      return null;
    }
  }

  /**
   * Encrypt a WSPacket → e2e:encrypted envelope.
   * @param {object} packet
   * @returns {object | null} — wrapped packet with action "e2e:encrypted"
   */
  async encryptPacket(packet) {
    const json = JSON.stringify(packet);
    const encrypted = await this.encrypt(json);
    if (!encrypted) return null;

    return {
      id: crypto.randomUUID(),
      action: "e2e:encrypted",
      payload: { data: encrypted },
      timestamp: new Date().toISOString(),
    };
  }

  /**
   * Decrypt an e2e:encrypted envelope → inner WSPacket.
   * @param {object} envelope — packet with action "e2e:encrypted"
   * @returns {object | null}
   */
  async decryptPacket(envelope) {
    const encrypted = envelope.payload?.data;
    if (!encrypted) return null;

    const json = await this.decrypt(encrypted);
    if (!json) return null;

    try {
      return JSON.parse(json);
    } catch {
      return null;
    }
  }

  /** Reset crypto state (new key pair needed). */
  reset() {
    this.#keyPair = null;
    this.#sharedKey = null;
    this.#publicKeyBase64 = null;
  }
}

// ── Helpers ──

function arrayBufferToBase64(buffer) {
  const bytes = new Uint8Array(buffer);
  let binary = "";
  for (let i = 0; i < bytes.byteLength; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary);
}

function base64ToArrayBuffer(base64) {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes.buffer;
}
