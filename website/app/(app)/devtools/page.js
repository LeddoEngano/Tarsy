"use client";

import { useState, useEffect } from "react";
import { useConnection } from "../../lib/tarsy/ConnectionProvider";

export default function DevToolsPage() {
  const { send, addListener, removeListener, isConnected } = useConnection();
  const [activeTab, setActiveTab] = useState("processes");

  // Processes
  const [processes, setProcesses] = useState([]);
  // Ports
  const [ports, setPorts] = useState([]);
  // Resources
  const [resources, setResources] = useState(null);

  useEffect(() => {
    const lid = "devtools";
    addListener(lid, (packet) => {
      const { action, payload } = packet;
      switch (action) {
        case "devtools:process_list_result":
          if (payload?.processes) {
            try { setProcesses(JSON.parse(payload.processes)); } catch { /* */ }
          }
          break;
        case "devtools:ports_list_result":
          if (payload?.ports) {
            try { setPorts(JSON.parse(payload.ports)); } catch { /* */ }
          }
          break;
        case "devtools:system_resources_result":
          if (payload) setResources(payload);
          break;
        default:
          break;
      }
    });
    return () => removeListener(lid);
  }, [addListener, removeListener]);

  function refresh() {
    if (activeTab === "processes") send("devtools:process_list");
    else if (activeTab === "ports") send("devtools:ports_list");
    else if (activeTab === "resources") send("devtools:system_resources");
  }

  useEffect(() => {
    if (isConnected) refresh();
  }, [isConnected, activeTab]); // eslint-disable-line react-hooks/exhaustive-deps

  return (
    <main className="app-container">
      <div className="settings-header">
        <h1 className="app-title">Developer Tools</h1>
        <a href="/dashboard" className="ws-back">Dashboard</a>
      </div>

      <div className="ws-tabs">
        {["processes", "ports", "resources"].map((t) => (
          <button
            key={t}
            className={`ws-tab ${activeTab === t ? "ws-tab--active" : ""}`}
            onClick={() => setActiveTab(t)}
          >
            {t.charAt(0).toUpperCase() + t.slice(1)}
          </button>
        ))}
        <button className="git-checkpoint-btn" onClick={refresh}>Refresh</button>
      </div>

      <div style={{ marginTop: "0.75rem" }}>
        {activeTab === "processes" && (
          <div className="dt-list">
            {processes.length === 0 ? (
              <p className="git-empty">No processes</p>
            ) : (
              processes.slice(0, 50).map((p, i) => (
                <div key={i} className="dt-row">
                  <span className="dt-pid">{p.pid}</span>
                  <span className="dt-name">{p.name || p.command}</span>
                  {p.cpu && <span className="dt-meta">{p.cpu}% CPU</span>}
                  {p.memory && <span className="dt-meta">{p.memory}MB</span>}
                </div>
              ))
            )}
          </div>
        )}

        {activeTab === "ports" && (
          <div className="dt-list">
            {ports.length === 0 ? (
              <p className="git-empty">No listening ports</p>
            ) : (
              ports.map((p, i) => (
                <div key={i} className="dt-row">
                  <span className="dt-port">{p.port}</span>
                  <span className="dt-name">{p.process || p.name}</span>
                  {p.pid && <span className="dt-meta">PID {p.pid}</span>}
                </div>
              ))
            )}
          </div>
        )}

        {activeTab === "resources" && (
          <div className="dt-resources">
            {!resources ? (
              <p className="git-empty">Loading...</p>
            ) : (
              <>
                <div className="dt-resource">
                  <span className="dt-resource-label">CPU</span>
                  <div className="dt-bar">
                    <div className="dt-bar-fill" style={{ width: `${resources.cpu || 0}%` }} />
                  </div>
                  <span className="dt-resource-value">{resources.cpu || 0}%</span>
                </div>
                <div className="dt-resource">
                  <span className="dt-resource-label">Memory</span>
                  <div className="dt-bar">
                    <div className="dt-bar-fill" style={{ width: `${resources.memoryPercent || 0}%` }} />
                  </div>
                  <span className="dt-resource-value">{resources.memoryUsed || "?"} / {resources.memoryTotal || "?"}</span>
                </div>
                {resources.disk && (
                  <div className="dt-resource">
                    <span className="dt-resource-label">Disk</span>
                    <div className="dt-bar">
                      <div className="dt-bar-fill" style={{ width: `${resources.diskPercent || 0}%` }} />
                    </div>
                    <span className="dt-resource-value">{resources.diskUsed || "?"} / {resources.diskTotal || "?"}</span>
                  </div>
                )}
              </>
            )}
          </div>
        )}
      </div>
    </main>
  );
}
