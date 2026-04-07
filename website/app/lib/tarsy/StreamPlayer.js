"use client";

import { useRef, useEffect, useState, useCallback } from "react";
import { useConnection } from "./ConnectionProvider";

/**
 * H.264 stream player using WebCodecs API.
 *
 * Binary frame format from companion:
 * - Byte 0: 0x01 (keyframe) or 0x00 (delta)
 * - Keyframes: SPS + PPS NAL units (00 00 00 01 prefix) + slice
 * - Delta: slice NAL units (00 00 00 01 prefix)
 */

/** Find all NAL unit boundaries (00 00 00 01 start codes). */
function findNalUnits(data) {
  const units = [];
  let i = 0;
  while (i < data.length - 3) {
    if (data[i] === 0 && data[i + 1] === 0 && data[i + 2] === 0 && data[i + 3] === 1) {
      if (units.length > 0) {
        units[units.length - 1].end = i;
      }
      units.push({ start: i + 4, end: data.length });
      i += 4;
    } else {
      i++;
    }
  }
  return units;
}

/** Extract SPS and PPS from NAL units for decoder config. */
function extractParameterSets(data, nalUnits) {
  let sps = null;
  let pps = null;
  for (const nal of nalUnits) {
    const nalType = data[nal.start] & 0x1f;
    if (nalType === 7) sps = data.slice(nal.start, nal.end); // SPS
    if (nalType === 8) pps = data.slice(nal.start, nal.end); // PPS
  }
  return { sps, pps };
}

export function StreamPlayer({ workspacePath, stack, onFullscreenChange }) {
  const canvasRef = useRef(null);
  const decoderRef = useRef(null);
  const fpsCounterRef = useRef({ frames: 0, lastTime: 0 });
  const [fps, setFps] = useState(0);
  const [isStreaming, setIsStreaming] = useState(false);
  const [isFullscreen, setIsFullscreen] = useState(false);
  const { send, onStreamFrame, isConnected } = useConnection();
  const configuredRef = useRef(false);
  const [supported, setSupported] = useState(true);

  // Check WebCodecs support (client-side only, avoids SSR crash)
  useEffect(() => {
    if (!("VideoDecoder" in window)) {
      setSupported(false);
    }
  }, []);

  // FPS counter
  const countFrame = useCallback(() => {
    const counter = fpsCounterRef.current;
    counter.frames++;
    const now = performance.now();
    if (now - counter.lastTime >= 1000) {
      setFps(counter.frames);
      counter.frames = 0;
      counter.lastTime = now;
    }
  }, []);

  // Initialize decoder
  useEffect(() => {
    if (!supported) return;

    const canvas = canvasRef.current;
    if (!canvas) return;

    const ctx = canvas.getContext("2d");
    configuredRef.current = false;

    const decoder = new VideoDecoder({
      output: (frame) => {
        // Resize canvas to match frame
        if (canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight) {
          canvas.width = frame.displayWidth;
          canvas.height = frame.displayHeight;
        }
        ctx.drawImage(frame, 0, 0);
        frame.close();
        countFrame();
      },
      error: () => {
        configuredRef.current = false;
      },
    });

    decoderRef.current = decoder;

    return () => {
      if (decoder.state !== "closed") {
        decoder.close();
      }
      decoderRef.current = null;
    };
  }, [countFrame]);

  // Handle stream frames
  useEffect(() => {
    if (!decoderRef.current) return;

    onStreamFrame((frameData) => {
      const decoder = decoderRef.current;
      if (!decoder || decoder.state === "closed") return;

      const data = new Uint8Array(frameData);
      if (data.length < 5) return;

      const isKeyframe = data[0] === 0x01;
      const nalData = data.slice(1); // Skip frame type byte
      const nalUnits = findNalUnits(nalData);

      // Configure decoder on first keyframe
      if (isKeyframe && !configuredRef.current) {
        const { sps, pps } = extractParameterSets(nalData, nalUnits);
        if (sps && pps) {
          const description = buildAvcCDescription(sps, pps);
          // Derive codec string from SPS profile/compat/level bytes
          const profile = sps[1].toString(16).padStart(2, "0");
          const compat = sps[2].toString(16).padStart(2, "0");
          const level = sps[3].toString(16).padStart(2, "0");
          const codec = `avc1.${profile}${compat}${level}`;
          try {
            decoder.configure({
              codec,
              optimizeForLatency: true,
              description,
            });
            configuredRef.current = true;
          } catch {
            return;
          }
        }
      }

      if (!configuredRef.current) return;

      // Convert Annex B to length-prefixed for WebCodecs
      const avccData = annexBToAvcc(nalData, nalUnits);
      if (avccData.length === 0) return;

      try {
        const chunk = new EncodedVideoChunk({
          type: isKeyframe ? "key" : "delta",
          timestamp: performance.now() * 1000, // microseconds
          data: avccData,
        });
        decoder.decode(chunk);
      } catch {
        // Decode error — wait for next keyframe
        if (!isKeyframe) configuredRef.current = false;
      }
    });
  }, [onStreamFrame]);

  // Start/stop stream
  useEffect(() => {
    if (isConnected && workspacePath) {
      send("stream:start", {
        path: workspacePath,
        stack: stack || "web",
      });
      setIsStreaming(true);

      return () => {
        send("stream:stop");
        setIsStreaming(false);
        configuredRef.current = false;
      };
    }
  }, [isConnected, workspacePath, stack, send]);

  // Fullscreen
  const toggleFullscreen = useCallback(() => {
    const container = canvasRef.current?.parentElement;
    if (!container) return;
    if (document.fullscreenElement) {
      document.exitFullscreen();
    } else {
      container.requestFullscreen();
    }
  }, []);

  useEffect(() => {
    function onFsChange() {
      const fs = !!document.fullscreenElement;
      setIsFullscreen(fs);
      onFullscreenChange?.(fs);
    }
    document.addEventListener("fullscreenchange", onFsChange);
    return () => document.removeEventListener("fullscreenchange", onFsChange);
  }, [onFullscreenChange]);

  if (!supported) {
    return (
      <div className="stream-unsupported">
        WebCodecs not supported. Use Chrome or Edge.
      </div>
    );
  }

  return (
    <div className={`stream-container ${isFullscreen ? "stream-fullscreen" : ""}`}>
      <canvas ref={canvasRef} className="stream-canvas" />
      <div className="stream-overlay">
        <span className="stream-fps">{fps} FPS</span>
        <button className="stream-fs-btn" onClick={toggleFullscreen}>
          {isFullscreen ? "Exit" : "Fullscreen"}
        </button>
      </div>
    </div>
  );
}

/**
 * Build avcC (ISO 14496-15) decoder description from SPS + PPS.
 * Required by WebCodecs for H.264 decoder configuration.
 */
function buildAvcCDescription(sps, pps) {
  const length = 11 + sps.length + pps.length;
  const buf = new Uint8Array(length);
  let offset = 0;

  buf[offset++] = 1; // configurationVersion
  buf[offset++] = sps[1]; // AVCProfileIndication
  buf[offset++] = sps[2]; // profile_compatibility
  buf[offset++] = sps[3]; // AVCLevelIndication
  buf[offset++] = 0xff; // lengthSizeMinusOne = 3 (4-byte NAL length)

  // SPS
  buf[offset++] = 0xe1; // numOfSequenceParameterSets = 1
  buf[offset++] = (sps.length >> 8) & 0xff;
  buf[offset++] = sps.length & 0xff;
  buf.set(sps, offset);
  offset += sps.length;

  // PPS
  buf[offset++] = 1; // numOfPictureParameterSets = 1
  buf[offset++] = (pps.length >> 8) & 0xff;
  buf[offset++] = pps.length & 0xff;
  buf.set(pps, offset);

  return buf.buffer;
}

/**
 * Convert Annex B (00 00 00 01 start codes) to AVCC (4-byte length prefix).
 * Skips SPS/PPS NAL units (already in description).
 */
function annexBToAvcc(data, nalUnits) {
  // Filter out SPS (7) and PPS (8) — they're in the description
  const sliceNals = nalUnits.filter((nal) => {
    const nalType = data[nal.start] & 0x1f;
    return nalType !== 7 && nalType !== 8;
  });

  if (sliceNals.length === 0) return new Uint8Array(0);

  // Calculate total size
  let totalSize = 0;
  for (const nal of sliceNals) {
    totalSize += 4 + (nal.end - nal.start);
  }

  const result = new Uint8Array(totalSize);
  let offset = 0;

  for (const nal of sliceNals) {
    const nalLen = nal.end - nal.start;
    // 4-byte big-endian length
    result[offset++] = (nalLen >> 24) & 0xff;
    result[offset++] = (nalLen >> 16) & 0xff;
    result[offset++] = (nalLen >> 8) & 0xff;
    result[offset++] = nalLen & 0xff;
    result.set(data.slice(nal.start, nal.end), offset);
    offset += nalLen;
  }

  return result;
}
