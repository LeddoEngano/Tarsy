"use client";

import { useState, useEffect } from "react";
import { useConnection } from "./ConnectionProvider";
import { createClient } from "../supabase/client";

/**
 * NewWorkspaceModal — create workspace from scanned repos or manual entry.
 */
export function NewWorkspaceModal({ machineId, onClose, onCreated }) {
  const { send, addListener, removeListener } = useConnection();
  const [scannedRepos, setScannedRepos] = useState([]);
  const [scanning, setScanning] = useState(false);
  const [mode, setMode] = useState("scan"); // scan | manual
  const [name, setName] = useState("");
  const [path, setPath] = useState("");
  const [stack, setStack] = useState("web");
  const [creating, setCreating] = useState(false);
  const [error, setError] = useState(null);

  // Listen for scan results
  useEffect(() => {
    const lid = "ws-scan";
    addListener(lid, (packet) => {
      if (packet.action === "workspace:scan_result" && packet.payload?.repos) {
        try {
          setScannedRepos(JSON.parse(packet.payload.repos));
        } catch { /* malformed */ }
        setScanning(false);
      }
    });
    return () => removeListener(lid);
  }, [addListener, removeListener]);

  // Scan repos on mount
  useEffect(() => {
    setScanning(true);
    send("workspace:scan_repos");
  }, [send]);

  async function handleCreate(repoPath, repoName) {
    setCreating(true);
    setError(null);

    const wsName = repoName || name;
    const wsPath = repoPath || path;

    if (!wsName || !wsPath) {
      setError("Name and path are required");
      setCreating(false);
      return;
    }

    try {
      const supabase = createClient();
      const { data: { user } } = await supabase.auth.getUser();
      if (!user) throw new Error("Not authenticated");

      const { data, error: dbError } = await supabase
        .from("workspaces")
        .insert({
          user_id: user.id,
          machine_id: machineId,
          name: wsName,
          local_path: wsPath,
          stack,
        })
        .select()
        .single();

      if (dbError) throw dbError;

      send("workspace:create", {
        id: data.id,
        path: wsPath,
        name: wsName,
        stack,
      });

      onCreated?.(data);
      onClose();
    } catch (e) {
      setError(e.message);
      setCreating(false);
    }
  }

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-header">
          <h2 className="modal-title">New Workspace</h2>
          <button className="modal-close" onClick={onClose}>Close</button>
        </div>

        {/* Mode Toggle */}
        <div className="modal-modes">
          <button
            className={`modal-mode ${mode === "scan" ? "modal-mode--active" : ""}`}
            onClick={() => setMode("scan")}
          >
            From Repos
          </button>
          <button
            className={`modal-mode ${mode === "manual" ? "modal-mode--active" : ""}`}
            onClick={() => setMode("manual")}
          >
            Manual
          </button>
        </div>

        {/* Scan Mode */}
        {mode === "scan" && (
          <div className="modal-body">
            {scanning ? (
              <p className="modal-empty">Scanning repositories...</p>
            ) : scannedRepos.length === 0 ? (
              <p className="modal-empty">No repositories found.</p>
            ) : (
              <div className="modal-repo-list">
                {scannedRepos.map((repo, i) => (
                  <button
                    key={i}
                    className="modal-repo"
                    onClick={() => handleCreate(repo.path, repo.name)}
                    disabled={creating}
                  >
                    <span className="modal-repo-name">{repo.name}</span>
                    <span className="modal-repo-path">{repo.path}</span>
                    {repo.branch && <span className="modal-repo-branch">{repo.branch}</span>}
                  </button>
                ))}
              </div>
            )}
          </div>
        )}

        {/* Manual Mode */}
        {mode === "manual" && (
          <div className="modal-body">
            <label className="auth-label">
              Name
              <input className="auth-input" value={name} onChange={(e) => setName(e.target.value)} />
            </label>
            <label className="auth-label">
              Path
              <input className="auth-input" value={path} onChange={(e) => setPath(e.target.value)} placeholder="/Users/you/project" />
            </label>
            <label className="auth-label">
              Stack
              <select className="dash-select" value={stack} onChange={(e) => setStack(e.target.value)}>
                <option value="web">Web</option>
                <option value="mobile">Mobile</option>
                <option value="backend">Backend</option>
                <option value="fullstack">Fullstack</option>
              </select>
            </label>
            {error && <p className="auth-error">{error}</p>}
            <button className="auth-submit" onClick={() => handleCreate()} disabled={creating}>
              {creating ? "Creating..." : "Create Workspace"}
            </button>
          </div>
        )}
      </div>
    </div>
  );
}

/**
 * PairingModal — enter connection code to pair a machine.
 */
export function PairingModal({ onClose, onPaired }) {
  const [code, setCode] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);

  async function handlePair() {
    if (!code.trim()) return;
    setLoading(true);
    setError(null);

    try {
      const supabase = createClient();
      const { data: { user } } = await supabase.auth.getUser();
      if (!user) throw new Error("Not authenticated");

      const { data, error: fnError } = await supabase.functions.invoke("claim-machine", {
        body: { code: code.trim(), userId: user.id },
      });

      if (fnError) throw fnError;
      onPaired?.(data);
      onClose();
    } catch (e) {
      setError(e.message || "Pairing failed");
      setLoading(false);
    }
  }

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-header">
          <h2 className="modal-title">Pair Machine</h2>
          <button className="modal-close" onClick={onClose}>Close</button>
        </div>
        <div className="modal-body">
          <p className="modal-desc">
            Enter the connection code shown on your Mac or PC.
          </p>
          <label className="auth-label">
            Connection Code
            <input
              className="auth-input"
              value={code}
              onChange={(e) => setCode(e.target.value)}
              placeholder="XXXX-XXXX-XXXX"
              style={{ textTransform: "uppercase", letterSpacing: "0.1em" }}
            />
          </label>
          {error && <p className="auth-error">{error}</p>}
          <button className="auth-submit" onClick={handlePair} disabled={loading || !code.trim()}>
            {loading ? "Pairing..." : "Pair"}
          </button>
        </div>
      </div>
    </div>
  );
}
