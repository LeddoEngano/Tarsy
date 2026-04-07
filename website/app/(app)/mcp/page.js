"use client";

import { useState, useEffect } from "react";
import { useConnection } from "../../lib/tarsy/ConnectionProvider";

export default function MCPPage() {
  const { send, addListener, removeListener, isConnected } = useConnection();
  const [mcps, setMcps] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const lid = "mcp-store";
    addListener(lid, (packet) => {
      if (packet.action === "mcp:list_result" && packet.payload?.mcps) {
        try {
          setMcps(JSON.parse(packet.payload.mcps));
        } catch { /* malformed */ }
        setLoading(false);
      }
      if (packet.action === "mcp:health_result" && packet.payload?.id) {
        setMcps((prev) =>
          prev.map((m) =>
            m.id === packet.payload.id
              ? { ...m, healthy: packet.payload.healthy === "true" }
              : m
          )
        );
      }
    });
    return () => removeListener(lid);
  }, [addListener, removeListener]);

  useEffect(() => {
    if (isConnected) {
      send("mcp:list");
    }
  }, [isConnected, send]);

  function checkHealth(mcpId) {
    send("mcp:health_check", { id: mcpId });
  }

  return (
    <main className="app-container">
      <div className="settings-header">
        <h1 className="app-title">MCP Integrations</h1>
        <a href="/dashboard" className="ws-back">Dashboard</a>
      </div>

      {loading ? (
        <p className="app-subtitle">Loading integrations...</p>
      ) : mcps.length === 0 ? (
        <p className="app-subtitle">No MCP servers detected on your machine.</p>
      ) : (
        <div className="mcp-grid">
          {mcps.map((mcp) => (
            <div key={mcp.id || mcp.name} className="mcp-card">
              <div className="mcp-card-header">
                <span className="mcp-card-name">{mcp.name}</span>
                <span className={`mcp-health ${mcp.healthy === true ? "mcp-health--ok" : mcp.healthy === false ? "mcp-health--bad" : ""}`}>
                  {mcp.healthy === true ? "Healthy" : mcp.healthy === false ? "Down" : "Unknown"}
                </span>
              </div>
              {mcp.description && <p className="mcp-card-desc">{mcp.description}</p>}
              {mcp.engine && <span className="mcp-card-engine">{mcp.engine}</span>}
              <button className="git-action-btn" onClick={() => checkHealth(mcp.id || mcp.name)}>
                Check Health
              </button>
            </div>
          ))}
        </div>
      )}
    </main>
  );
}
