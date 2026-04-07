"use client";

import { useRef, useEffect, useState } from "react";
import { useConnection } from "./ConnectionProvider";

/**
 * TerminalView — xterm.js terminal connected to companion via WebSocket.
 *
 * Uses dynamic import to avoid SSR issues with xterm.js (requires DOM).
 */
export function TerminalView({ workspacePath }) {
  const termRef = useRef(null);
  const xtermRef = useRef(null);
  const fitAddonRef = useRef(null);
  const sessionIdRef = useRef(null);
  const [ready, setReady] = useState(false);
  const { send, addListener, removeListener, isConnected } = useConnection();

  // Initialize xterm.js (dynamic import for SSR safety)
  useEffect(() => {
    let disposed = false;

    async function init() {
      const { Terminal } = await import("@xterm/xterm");
      const { FitAddon } = await import("@xterm/addon-fit");

      // Import CSS
      await import("@xterm/xterm/css/xterm.css");

      if (disposed || !termRef.current) return;

      const fitAddon = new FitAddon();
      const terminal = new Terminal({
        fontFamily: "'JetBrains Mono', monospace",
        fontSize: 13,
        lineHeight: 1.4,
        cursorBlink: true,
        cursorStyle: "bar",
        theme: {
          background: "#131316",
          foreground: "#e4e4e7",
          cursor: "#e4e4e7",
          selectionBackground: "#2a2a30",
          black: "#131316",
          red: "#e5716a",
          green: "#6bc77b",
          yellow: "#e0a86a",
          blue: "#71717a",
          magenta: "#e5716a",
          cyan: "#6bc77b",
          white: "#e4e4e7",
          brightBlack: "#52525b",
          brightRed: "#e5716a",
          brightGreen: "#6bc77b",
          brightYellow: "#e0a86a",
          brightBlue: "#71717a",
          brightMagenta: "#e5716a",
          brightCyan: "#6bc77b",
          brightWhite: "#ffffff",
        },
      });

      terminal.loadAddon(fitAddon);
      terminal.open(termRef.current);
      fitAddon.fit();

      xtermRef.current = terminal;
      fitAddonRef.current = fitAddon;
      setReady(true);

      // Handle user input → send to companion
      terminal.onData((data) => {
        send("terminal:input", {
          sessionId: sessionIdRef.current,
          data,
        });
      });
    }

    init();

    return () => {
      disposed = true;
      xtermRef.current?.dispose();
      xtermRef.current = null;
      fitAddonRef.current = null;
      setReady(false);
    };
  }, [send]);

  // Create terminal session on companion
  useEffect(() => {
    if (!isConnected || !workspacePath || !ready) return;

    const packetId = send("terminal:create", {
      path: workspacePath,
    });

    if (packetId) {
      sessionIdRef.current = packetId;
    }

    return () => {
      if (sessionIdRef.current) {
        send("terminal:close", { sessionId: sessionIdRef.current });
        sessionIdRef.current = null;
      }
    };
  }, [isConnected, workspacePath, ready, send]);

  // Listen for terminal output
  useEffect(() => {
    if (!ready) return;

    const sid = sessionIdRef.current;
    const listenerId = `terminal-output-${sid}`;
    addListener(listenerId, (packet) => {
      if (
        packet.action === "terminal:output" &&
        packet.payload?.data &&
        packet.payload?.sessionId === sid
      ) {
        xtermRef.current?.write(packet.payload.data);
      }
    });

    return () => removeListener(listenerId);
  }, [ready, addListener, removeListener]);

  // Handle resize
  useEffect(() => {
    if (!ready) return;

    function handleResize() {
      fitAddonRef.current?.fit();
    }

    window.addEventListener("resize", handleResize);
    return () => window.removeEventListener("resize", handleResize);
  }, [ready]);

  // Ctrl+C → interrupt
  useEffect(() => {
    if (!ready) return;

    const terminal = xtermRef.current;
    if (!terminal) return;

    const disposable = terminal.onKey(({ domEvent }) => {
      if (domEvent.ctrlKey && domEvent.key === "c") {
        send("terminal:interrupt", {
          sessionId: sessionIdRef.current,
        });
      }
    });

    return () => disposable.dispose();
  }, [ready, send]);

  return (
    <div className="term-container">
      <div ref={termRef} className="term-element" />
    </div>
  );
}
