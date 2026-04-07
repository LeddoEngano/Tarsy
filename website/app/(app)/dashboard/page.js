"use client";

import { useConnection } from "../../lib/tarsy/ConnectionProvider";
import { useMachines, useWorkspaces, useActiveTasks, useSignOut } from "../../lib/tarsy/hooks";
import { useRouter } from "next/navigation";
import { useState } from "react";
import { NewWorkspaceModal, PairingModal } from "../../lib/tarsy/WorkspaceModals";
import { FeedbackModal } from "../../lib/tarsy/FeedbackModal";

const STACK_LABELS = {
  web: "Web",
  mobile: "Mobile",
  backend: "Backend",
  fullstack: "Fullstack",
};

const STATUS_COLORS = {
  running: "var(--app-status-running)",
  starting: "var(--app-status-starting)",
  idle: "var(--app-status-idle)",
  error: "var(--app-status-error)",
};

export default function DashboardPage() {
  const router = useRouter();
  const { isConnected, isReconnecting, latency } = useConnection();
  const { machines, selectedMachine, selectMachine, loading: machinesLoading } = useMachines();
  const { workspaces, loading: workspacesLoading } = useWorkspaces(selectedMachine?.id);
  const tasks = useActiveTasks();
  const signOut = useSignOut();
  const [showNewWorkspace, setShowNewWorkspace] = useState(false);
  const [showPairing, setShowPairing] = useState(false);
  const [showFeedback, setShowFeedback] = useState(false);

  return (
    <main className="app-container">
      {/* Header */}
      <div className="dash-header">
        <div>
          <h1 className="app-title">Dashboard</h1>
          <div className="dash-status">
            <span className="dash-dot" style={{
              backgroundColor: isConnected
                ? "var(--app-status-running)"
                : isReconnecting
                  ? "var(--app-status-starting)"
                  : "var(--app-status-idle)",
            }} />
            {isConnected ? `Connected (${latency}ms)` : isReconnecting ? "Reconnecting..." : "Disconnected"}
          </div>
        </div>
        <button className="dash-signout" onClick={signOut}>Sign out</button>
      </div>

      {/* No machines */}
      {!machinesLoading && machines.length === 0 && (
        <div className="dash-section">
          <p className="app-subtitle">No machines paired yet. Install Tarsy on your Mac or PC, then pair it using the connection code.</p>
        </div>
      )}

      {/* Machine Picker */}
      {machines.length > 1 && (
        <div className="dash-section">
          <select
            className="dash-select"
            value={selectedMachine?.id || ""}
            onChange={(e) => selectMachine(e.target.value)}
          >
            {machines.map((m) => (
              <option key={m.id} value={m.id}>
                {m.display_name || m.hostname} {m.status === "online" ? "" : "(offline)"}
              </option>
            ))}
          </select>
        </div>
      )}

      {/* Machine Status */}
      {selectedMachine && (
        <div className="dash-machine">
          <span className="dash-dot" style={{
            backgroundColor: selectedMachine.status === "online" ? "var(--app-status-running)" : "var(--app-status-idle)",
          }} />
          <span>{selectedMachine.display_name || selectedMachine.hostname}</span>
          <span className="dash-machine-meta">
            {selectedMachine.status === "online" ? "Online" : "Offline"}
          </span>
        </div>
      )}

      {/* Active Tasks */}
      {tasks.length > 0 && (
        <div className="dash-section">
          <h2 className="dash-section-title">Active Tasks</h2>
          <div className="dash-tasks">
            {tasks.map((task) => (
              <div key={task.id} className="dash-task">
                <span className="dash-dot" style={{
                  backgroundColor: task.status === "running"
                    ? "var(--app-status-running)"
                    : "var(--app-status-starting)",
                }} />
                <span className="dash-task-desc">{task.description}</span>
                <span className="dash-task-status">{task.status}</span>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Workspaces */}
      <div className="dash-section">
        <h2 className="dash-section-title">Workspaces</h2>
        {workspacesLoading || machinesLoading ? (
          <p className="app-subtitle">Loading...</p>
        ) : workspaces.length === 0 ? (
          <p className="app-subtitle">No workspaces yet.</p>
        ) : (
          <div className="dash-grid">
            {workspaces.map((ws) => (
              <button
                key={ws.id}
                className="dash-card"
                onClick={() => router.push(`/workspace/${ws.id}`)}
              >
                <div className="dash-card-header">
                  <span className="dash-card-name">{ws.name}</span>
                  <span className="dash-card-stack">{STACK_LABELS[ws.stack] || ws.stack}</span>
                </div>
                {ws.current_branch && (
                  <div className="dash-card-branch">{ws.current_branch}</div>
                )}
                <div className="dash-card-status">
                  <span className="dash-dot" style={{
                    backgroundColor: STATUS_COLORS[ws.status] || STATUS_COLORS.idle,
                  }} />
                  {ws.status}
                </div>
              </button>
            ))}
          </div>
        )}
      </div>

      {/* Action Buttons */}
      <div className="dash-actions">
        {selectedMachine && (
          <button className="dash-action-btn" onClick={() => setShowNewWorkspace(true)}>
            New Workspace
          </button>
        )}
        <button className="dash-action-btn" onClick={() => setShowPairing(true)}>
          Pair Machine
        </button>
      </div>

      {/* Nav Links */}
      <div className="dash-nav">
        <a href="/mcp" className="dash-nav-link">MCP Store</a>
        <a href="/devtools" className="dash-nav-link">Dev Tools</a>
        <a href="/settings" className="dash-nav-link">Settings</a>
        <button className="dash-nav-link" onClick={() => setShowFeedback(true)}>Feedback</button>
      </div>

      {/* Modals */}
      {showNewWorkspace && selectedMachine && (
        <NewWorkspaceModal
          machineId={selectedMachine.id}
          onClose={() => setShowNewWorkspace(false)}
          onCreated={(ws) => router.push(`/workspace/${ws.id}`)}
        />
      )}
      {showPairing && (
        <PairingModal
          onClose={() => setShowPairing(false)}
          onPaired={() => window.location.reload()}
        />
      )}
      {showFeedback && (
        <FeedbackModal onClose={() => setShowFeedback(false)} />
      )}
    </main>
  );
}
