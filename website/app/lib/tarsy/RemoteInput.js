"use client";

import { useRef, useEffect, useCallback } from "react";

/**
 * RemoteInput — captures mouse/keyboard events on a canvas overlay
 * and sends them as WSPackets to the companion.
 *
 * All coordinates are relative (0-1) to the canvas dimensions.
 */

const SCROLL_THROTTLE_MS = 33; // ~30Hz

/**
 * Hook to attach remote input handlers to a container element.
 * @param {function} send — ConnectionManager.send
 * @param {boolean} enabled — whether input capture is active
 * @returns {{ containerProps, inputRef }}
 */
export function useRemoteInput(send, enabled) {
  const inputRef = useRef(null);
  const lastScrollTime = useRef(0);
  const dragState = useRef(null);

  // Calculate relative position from mouse event
  const getRelativePos = useCallback((e, element) => {
    const rect = element.getBoundingClientRect();
    return {
      x: String(Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width))),
      y: String(Math.max(0, Math.min(1, (e.clientY - rect.top) / rect.height))),
    };
  }, []);

  // Tap (click) — skip if drag was just sent
  const handleClick = useCallback((e) => {
    if (!enabled) return;
    if (dragState.current === "sent") {
      dragState.current = null;
      return;
    }
    const pos = getRelativePos(e, e.currentTarget);
    send("remote:tap", pos);
    inputRef.current?.focus();
  }, [send, enabled, getRelativePos]);

  // Double-tap
  const handleDblClick = useCallback((e) => {
    if (!enabled) return;
    e.preventDefault();
    const pos = getRelativePos(e, e.currentTarget);
    send("remote:double_tap", pos);
  }, [send, enabled, getRelativePos]);

  // Long-press (right-click)
  const handleContextMenu = useCallback((e) => {
    if (!enabled) return;
    e.preventDefault();
    const pos = getRelativePos(e, e.currentTarget);
    send("remote:long_press", pos);
  }, [send, enabled, getRelativePos]);

  // Scroll (wheel)
  const handleWheel = useCallback((e) => {
    if (!enabled) return;
    e.preventDefault();

    const now = Date.now();
    if (now - lastScrollTime.current < SCROLL_THROTTLE_MS) return;
    lastScrollTime.current = now;

    const rect = e.currentTarget.getBoundingClientRect();
    const pos = getRelativePos(e, e.currentTarget);
    send("remote:scroll", {
      ...pos,
      deltaX: String(e.deltaX / rect.width),
      deltaY: String(e.deltaY / rect.height),
    });
  }, [send, enabled, getRelativePos]);

  // Drag
  const handleMouseDown = useCallback((e) => {
    if (!enabled || e.button !== 0) return;
    const pos = getRelativePos(e, e.currentTarget);
    dragState.current = { fromX: pos.x, fromY: pos.y, element: e.currentTarget };
  }, [enabled, getRelativePos]);

  const handleMouseUp = useCallback((e) => {
    if (!dragState.current) return;
    const { fromX, fromY, element } = dragState.current;
    const to = getRelativePos(e, element);

    // Only send drag if moved significantly
    const dx = Math.abs(parseFloat(to.x) - parseFloat(fromX));
    const dy = Math.abs(parseFloat(to.y) - parseFloat(fromY));
    if (dx > 0.02 || dy > 0.02) {
      send("remote:drag", { fromX, fromY, toX: to.x, toY: to.y });
      dragState.current = "sent"; // Flag so click handler skips tap
    } else {
      dragState.current = null;
    }
  }, [send, getRelativePos]);

  // Keyboard (hidden input)
  const handleInput = useCallback((e) => {
    if (!enabled) return;
    const text = e.target.value;
    if (text) {
      send("remote:keyboard", { text });
      e.target.value = "";
    }
  }, [send, enabled]);

  const handleKeyDown = useCallback((e) => {
    if (!enabled) return;

    // Special keys
    if (e.key === "Backspace") {
      e.preventDefault();
      send("remote:keyboard", { text: "\u0008" });
    } else if (e.key === "Enter") {
      e.preventDefault();
      send("remote:keyboard", { text: "\n" });
    } else if (e.key === "Tab") {
      e.preventDefault();
      send("remote:keyboard", { text: "\t" });
    } else if (e.key === "Escape") {
      e.preventDefault();
      send("remote:keyboard", { text: "\u001b" });
    }
    // Arrow keys
    else if (e.key === "ArrowUp") {
      e.preventDefault();
      send("remote:keyboard", { text: "\u001b[A" });
    } else if (e.key === "ArrowDown") {
      e.preventDefault();
      send("remote:keyboard", { text: "\u001b[B" });
    } else if (e.key === "ArrowRight") {
      e.preventDefault();
      send("remote:keyboard", { text: "\u001b[C" });
    } else if (e.key === "ArrowLeft") {
      e.preventDefault();
      send("remote:keyboard", { text: "\u001b[D" });
    }
  }, [send, enabled]);

  // Attach wheel listener with { passive: false } for preventDefault
  const containerRef = useRef(null);
  useEffect(() => {
    const el = containerRef.current;
    if (!el || !enabled) return;
    el.addEventListener("wheel", handleWheel, { passive: false });
    return () => el.removeEventListener("wheel", handleWheel);
  }, [handleWheel, enabled]);

  const containerProps = {
    ref: containerRef,
    onClick: handleClick,
    onDoubleClick: handleDblClick,
    onContextMenu: handleContextMenu,
    onMouseDown: handleMouseDown,
    onMouseUp: handleMouseUp,
    style: { cursor: enabled ? "crosshair" : "default" },
  };

  return { containerProps, inputRef, handleInput, handleKeyDown };
}
