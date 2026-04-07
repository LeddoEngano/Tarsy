"use client";

import { createContext, useContext, useEffect, useRef, useState, useCallback, useMemo } from "react";
import { ConnectionManager } from "./connection";
import { createClient } from "../supabase/client";

const ConnectionContext = createContext(null);

export function ConnectionProvider({ children }) {
  const managerRef = useRef(null);
  const [state, setState] = useState({
    isConnected: false,
    isReconnecting: false,
    latency: 0,
  });

  const tokenRefresher = useCallback(async () => {
    const supabase = createClient();
    const { data } = await supabase.auth.refreshSession();
    return data?.session?.access_token;
  }, []);

  useEffect(() => {
    let cancelled = false;
    const manager = new ConnectionManager({
      onStateChange: setState,
      tokenRefresher,
    });
    managerRef.current = manager;

    (async () => {
      const supabase = createClient();
      const { data } = await supabase.auth.getSession();
      const token = data?.session?.access_token;
      if (token && !cancelled) {
        manager.connect(token);
      }
    })();

    return () => {
      cancelled = true;
      manager.disconnect();
      managerRef.current = null;
    };
  }, [tokenRefresher]);

  const value = useMemo(() => ({
    ...state,
    send: (action, payload) => managerRef.current?.send(action, payload),
    sendRaw: (packet) => managerRef.current?.sendRaw(packet),
    addListener: (id, handler) => managerRef.current?.addListener(id, handler),
    removeListener: (id) => managerRef.current?.removeListener(id),
    onStreamFrame: (handler) => managerRef.current?.onStreamFrame(handler),
    onScreenshot: (handler) => managerRef.current?.onScreenshot(handler),
    disconnect: () => managerRef.current?.disconnect(),
  }), [state]);

  return (
    <ConnectionContext.Provider value={value}>
      {children}
    </ConnectionContext.Provider>
  );
}

/**
 * Hook to access the ConnectionManager context.
 * @returns {{ isConnected: boolean, isReconnecting: boolean, latency: number, send: function, addListener: function, removeListener: function, onStreamFrame: function, onScreenshot: function, disconnect: function }}
 */
export function useConnection() {
  const ctx = useContext(ConnectionContext);
  if (!ctx) throw new Error("useConnection must be used within ConnectionProvider");
  return ctx;
}
