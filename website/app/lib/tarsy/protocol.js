/**
 * WSProtocol — matches TarsyShared/Networking/WSProtocol.swift exactly.
 * All action string values must match the Swift enum raw values.
 */

/** Max JSON packet size (1 MB). Binary frames bypass this. */
export const MAX_PACKET_SIZE = 1_048_576;

/** 4-byte binary frame prefixes */
export const FRAME_PREFIX_H264 = "H264";
export const FRAME_PREFIX_SCREENSHOT = "SCRN";

/**
 * Create a WSPacket ready to serialize.
 * @param {string} action — WSAction string (e.g., "engine:create")
 * @param {Record<string, string>} [payload]
 * @returns {object}
 */
export function createPacket(action, payload = null) {
  return {
    id: crypto.randomUUID(),
    action,
    payload,
    timestamp: new Date().toISOString(),
  };
}

/**
 * Serialize a packet to JSON string.
 * @param {object} packet
 * @returns {string}
 */
export function encodePacket(packet) {
  const json = JSON.stringify(packet);
  if (json.length > MAX_PACKET_SIZE) {
    throw new Error(`WSPacket too large: ${json.length} bytes (max ${MAX_PACKET_SIZE})`);
  }
  return json;
}

/**
 * Deserialize a JSON string to a packet.
 * @param {string} json
 * @returns {object}
 */
export function decodePacket(json) {
  if (json.length > MAX_PACKET_SIZE) {
    throw new Error(`WSPacket too large: ${json.length} bytes (max ${MAX_PACKET_SIZE})`);
  }
  return JSON.parse(json);
}

/**
 * Check if a binary message is an H.264 frame.
 * @param {ArrayBuffer} data
 * @returns {boolean}
 */
export function isH264Frame(data) {
  if (data.byteLength < 4) return false;
  const prefix = new TextDecoder().decode(new Uint8Array(data, 0, 4));
  return prefix === FRAME_PREFIX_H264;
}

/**
 * Check if a binary message is a screenshot.
 * @param {ArrayBuffer} data
 * @returns {boolean}
 */
export function isScreenshot(data) {
  if (data.byteLength < 4) return false;
  const prefix = new TextDecoder().decode(new Uint8Array(data, 0, 4));
  return prefix === FRAME_PREFIX_SCREENSHOT;
}
