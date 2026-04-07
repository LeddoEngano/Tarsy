"use client";

import { useConnection } from "../../lib/tarsy/ConnectionProvider";

export default function DashboardPage() {
  const { isConnected, isReconnecting, latency } = useConnection();

  return (
    <main className="app-container">
      <h1 className="app-title">Dashboard</h1>
      <p className="app-subtitle">Select a machine to get started.</p>

      <div style={{ marginTop: "1.5rem", fontSize: "0.75rem", color: "var(--app-text-secondary)" }}>
        <span style={{
          display: "inline-block",
          width: 8,
          height: 8,
          borderRadius: "50%",
          backgroundColor: isConnected ? "var(--app-status-running)" : isReconnecting ? "var(--app-status-starting)" : "var(--app-status-idle)",
          marginRight: 6,
        }} />
        {isConnected ? `Connected (${latency}ms)` : isReconnecting ? "Reconnecting..." : "Disconnected"}
      </div>
    </main>
  );
}
