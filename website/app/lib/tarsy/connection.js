/**
 * ConnectionManager — relay-only WebSocket connection to Tarsy companion.
 *
 * Connects to wss://tarsy-relay.fly.dev/ws, authenticates with Supabase JWT,
 * handles ping/pong keepalive, auto-reconnect with exponential backoff,
 * and dispatches packets to registered listeners.
 */

import { createPacket, encodePacket, decodePacket, isH264Frame, isScreenshot } from "./protocol";
import { E2ECrypto } from "./e2e";

const RELAY_URL = "wss://tarsy-relay.fly.dev/ws";
const PING_INTERVAL = 10_000;
const ZOMBIE_TIMEOUT = 15_000;
const MAX_RECONNECT_DELAY = 60;

export class ConnectionManager {
  /** @type {WebSocket | null} */
  #ws = null;
  /** @type {Map<string, function>} */
  #listeners = new Map();
  /** @type {function | null} */
  #onStreamFrame = null;
  /** @type {function | null} */
  #onScreenshot = null;
  /** @type {number | null} */
  #pingTimer = null;
  /** @type {number | null} */
  #zombieTimer = null;
  /** @type {number} */
  #reconnectAttempts = 0;
  /** @type {number | null} */
  #reconnectTimer = null;
  /** @type {boolean} */
  #intentionalDisconnect = false;
  /** @type {string | null} */
  #token = null;
  /** @type {function | null} */
  #tokenRefresher = null;
  /** @type {function | null} */
  #onStateChange = null;

  /** @type {E2ECrypto} */
  #e2e = new E2ECrypto();

  // Observable state
  isConnected = false;
  isReconnecting = false;
  latency = 0;

  /** @type {number} */
  #lastPingTime = 0;

  /**
   * @param {object} options
   * @param {function} options.onStateChange — called when isConnected/isReconnecting/latency changes
   * @param {function} options.tokenRefresher — async function that returns a fresh Supabase JWT
   */
  constructor({ onStateChange, tokenRefresher }) {
    this.#onStateChange = onStateChange;
    this.#tokenRefresher = tokenRefresher;
  }

  /**
   * Connect to relay.
   * @param {string} token — Supabase access token
   */
  async connect(token) {
    this.#token = token;
    this.#intentionalDisconnect = false;
    await this.#e2e.initialize();
    this.#openWebSocket();
  }

  /** Disconnect intentionally (no auto-reconnect). */
  disconnect() {
    this.#intentionalDisconnect = true;
    this.#cleanup();
    this.#updateState(false, false);
  }

  /**
   * Send a packet to the companion.
   * @param {string} action
   * @param {Record<string, string>} [payload]
   * @returns {string} packet ID
   */
  send(action, payload) {
    if (this.#ws?.readyState !== WebSocket.OPEN) {
      return null;
    }
    const packet = createPacket(action, payload);
    this.#ws.send(encodePacket(packet));
    return packet.id;
  }

  /**
   * Send a raw packet object (for E2E encrypted envelopes).
   * @param {object} packet
   */
  sendRaw(packet) {
    if (this.#ws?.readyState === WebSocket.OPEN) {
      this.#ws.send(encodePacket(packet));
    }
  }

  /**
   * Register a listener for a specific action.
   * @param {string} id — unique listener ID
   * @param {function} handler — called with (packet)
   */
  addListener(id, handler) {
    this.#listeners.set(id, handler);
  }

  /** Remove a listener by ID. */
  removeListener(id) {
    this.#listeners.delete(id);
  }

  /** Register binary stream frame handler. */
  onStreamFrame(handler) {
    this.#onStreamFrame = handler;
  }

  /** Register screenshot handler. */
  onScreenshot(handler) {
    this.#onScreenshot = handler;
  }

  // ── Private ──

  #openWebSocket() {
    this.#cleanup();

    const ws = new WebSocket(RELAY_URL);
    ws.binaryType = "arraybuffer";
    this.#ws = ws;

    ws.onopen = () => {
      const authPacket = createPacket("auth", {
        token: this.#token,
        role: "client",
        e2ePublicKey: this.#e2e.publicKeyBase64,
      });
      ws.send(encodePacket(authPacket));
    };

    ws.onmessage = (event) => {
      if (event.data instanceof ArrayBuffer) {
        this.#handleBinary(event.data);
        return;
      }

      try {
        const packet = decodePacket(event.data);
        this.#handlePacket(packet);
      } catch {
        // Malformed packet — ignore
      }
    };

    ws.onclose = () => {
      this.#cleanup();
      this.#updateState(false, false);
      if (!this.#intentionalDisconnect) {
        this.#scheduleReconnect();
      }
    };

    ws.onerror = () => {
      // onclose will fire after onerror
    };
  }

  async #handlePacket(packet) {
    const { action } = packet;

    switch (action) {
      case "auth:success":
        this.#reconnectAttempts = 0;
        this.#updateState(true, false);
        this.#startPing();
        // Complete E2E key exchange if companion sent its public key
        if (packet.payload?.e2ePublicKey) {
          await this.#e2e.completeKeyExchange(packet.payload.e2ePublicKey);
        }
        break;

      case "auth:fail":
        this.#intentionalDisconnect = true;
        this.#ws?.close();
        break;

      case "pong":
        this.latency = Date.now() - this.#lastPingTime;
        this.#clearZombieTimer();
        this.#notifyStateChange();
        break;

      case "e2e:key_exchange_response":
        // Companion sent its public key via relay
        if (packet.payload?.e2ePublicKey) {
          await this.#e2e.completeKeyExchange(packet.payload.e2ePublicKey);
        }
        break;

      case "e2e:encrypted": {
        // Decrypt and re-dispatch the inner packet
        const inner = await this.#e2e.decryptPacket(packet);
        if (inner) {
          await this.#handlePacket(inner);
        }
        return; // Don't dispatch the envelope to listeners
      }

      default:
        break;
    }

    // Dispatch to all listeners
    for (const handler of this.#listeners.values()) {
      try {
        handler(packet);
      } catch {
        // Listener error — don't break dispatch
      }
    }
  }

  async #handleBinary(data) {
    let decrypted = data;

    // On relay, binary frames are E2E encrypted
    if (this.#e2e.isReady) {
      const plain = await this.#e2e.decryptBinary(new Uint8Array(data));
      if (plain) {
        decrypted = plain.buffer;
      }
    }

    if (isH264Frame(decrypted)) {
      const frameData = decrypted.slice(4);
      this.#onStreamFrame?.(frameData);
    } else if (isScreenshot(decrypted)) {
      const imageData = decrypted.slice(4);
      this.#onScreenshot?.(imageData);
    }
  }

  #startPing() {
    this.#stopPing();
    this.#pingTimer = setInterval(() => {
      if (this.#ws?.readyState === WebSocket.OPEN) {
        this.#lastPingTime = Date.now();
        this.send("ping");
        this.#startZombieTimer();
      }
    }, PING_INTERVAL);
  }

  #stopPing() {
    if (this.#pingTimer) {
      clearInterval(this.#pingTimer);
      this.#pingTimer = null;
    }
    this.#clearZombieTimer();
  }

  #startZombieTimer() {
    this.#clearZombieTimer();
    this.#zombieTimer = setTimeout(() => {
      // No pong received — connection is dead
      this.#ws?.close();
    }, ZOMBIE_TIMEOUT);
  }

  #clearZombieTimer() {
    if (this.#zombieTimer) {
      clearTimeout(this.#zombieTimer);
      this.#zombieTimer = null;
    }
  }

  async #scheduleReconnect() {
    this.#reconnectAttempts++;
    const baseDelay = Math.min(Math.pow(2, this.#reconnectAttempts), MAX_RECONNECT_DELAY);
    const jitter = Math.random() * Math.min(baseDelay * 0.3, 10);
    const delay = (baseDelay + jitter) * 1000;

    this.#updateState(false, true);

    this.#reconnectTimer = setTimeout(async () => {
      // Refresh token before reconnecting
      if (this.#tokenRefresher) {
        try {
          this.#token = await this.#tokenRefresher();
        } catch {
          // Use existing token as fallback
        }
      }
      // Fresh ephemeral key pair — companion generates new keys per connection
      await this.#e2e.initialize();
      this.#openWebSocket();
    }, delay);
  }

  #cleanup() {
    this.#stopPing();
    this.#e2e.reset();
    if (this.#reconnectTimer) {
      clearTimeout(this.#reconnectTimer);
      this.#reconnectTimer = null;
    }
    if (this.#ws) {
      this.#ws.onopen = null;
      this.#ws.onmessage = null;
      this.#ws.onclose = null;
      this.#ws.onerror = null;
      if (this.#ws.readyState === WebSocket.OPEN || this.#ws.readyState === WebSocket.CONNECTING) {
        this.#ws.close();
      }
      this.#ws = null;
    }
  }

  #updateState(connected, reconnecting) {
    this.isConnected = connected;
    this.isReconnecting = reconnecting;
    this.#notifyStateChange();
  }

  #notifyStateChange() {
    this.#onStateChange?.({
      isConnected: this.isConnected,
      isReconnecting: this.isReconnecting,
      latency: this.latency,
    });
  }
}
