"use client";

import { useState, useEffect, useCallback, useRef } from "react";
import { useConnection } from "./ConnectionProvider";

export function GitPanel({ workspacePath }) {
  const { send, addListener, removeListener } = useConnection();
  const [tab, setTab] = useState("changes");

  // Changes
  const [files, setFiles] = useState([]);
  const [diffStat, setDiffStat] = useState("");

  // History
  const [commits, setCommits] = useState([]);

  // Branches
  const [branches, setBranches] = useState([]);
  const [currentBranch, setCurrentBranch] = useState("");

  // Diff viewer
  const [selectedDiff, setSelectedDiff] = useState(null);

  // Loading
  const [loading, setLoading] = useState(false);
  const refreshTabRef = useRef(null);

  // Listen for git results
  useEffect(() => {
    const lid = "git-panel";
    addListener(lid, (packet) => {
      const { action, payload } = packet;

      switch (action) {
        case "git:diff_result":
          if (payload?.status) {
            const lines = payload.status.split("\n").filter(Boolean);
            setFiles(lines.map((l) => ({
              status: l.substring(0, 2).trim(),
              path: l.substring(3),
            })));
          }
          if (payload?.stat) setDiffStat(payload.stat);
          setLoading(false);
          break;

        case "git:history_result":
          if (payload?.commits) {
            try {
              const parsed = payload.commits.split("\n").filter(Boolean).map((line) => {
                const [hash, message, date, author] = line.split("|||");
                return { hash, message, date, author };
              });
              setCommits(parsed);
            } catch { /* malformed */ }
          }
          setLoading(false);
          break;

        case "git:branches_result":
          if (payload?.current) setCurrentBranch(payload.current);
          if (payload?.branches) {
            try {
              setBranches(JSON.parse(payload.branches));
            } catch { /* malformed */ }
          }
          setLoading(false);
          break;

        case "git:file_diff_result":
          if (payload?.diff) {
            setSelectedDiff({ file: payload.file, diff: payload.diff });
          }
          break;

        case "git:checkpoint_result":
        case "git:stage_result":
        case "git:discard_result":
        case "git:checkout_result":
        case "git:rollback_result":
          // Refresh after mutation
          refreshTabRef.current?.();
          break;

        default:
          break;
      }
    });

    return () => removeListener(lid);
  }, [addListener, removeListener]); // eslint-disable-line react-hooks/exhaustive-deps

  const refreshTab = useCallback(() => {
    setLoading(true);
    if (tab === "changes") {
      send("git:diff", { path: workspacePath });
    } else if (tab === "history") {
      send("git:history", { path: workspacePath, limit: "50" });
    } else if (tab === "branches") {
      send("git:branches", { path: workspacePath });
    }
  }, [tab, workspacePath, send]);

  // Keep ref in sync so listener closure always calls latest
  useEffect(() => { refreshTabRef.current = refreshTab; }, [refreshTab]);

  // Load data on tab change
  useEffect(() => {
    refreshTab();
  }, [refreshTab]);

  const handleStage = (filePath) => send("git:stage", { path: workspacePath, files: filePath });
  const handleDiscard = (filePath) => send("git:discard", { path: workspacePath, files: filePath });
  const handleCheckpoint = () => send("git:checkpoint", { path: workspacePath, message: "checkpoint" });
  const handleCheckout = (branch) => send("git:checkout", { path: workspacePath, branch });
  const handleRollback = (hash) => {
    if (confirm(`Rollback to ${hash.substring(0, 7)}? This will discard all changes since.`)) {
      send("git:rollback", { path: workspacePath, target: hash });
    }
  };
  const handleViewDiff = (filePath) => send("git:file_diff", { path: workspacePath, file: filePath });

  return (
    <div className="git-panel">
      {/* Tabs */}
      <div className="git-tabs">
        {["changes", "history", "branches"].map((t) => (
          <button
            key={t}
            className={`git-tab ${tab === t ? "git-tab--active" : ""}`}
            onClick={() => { setTab(t); setSelectedDiff(null); }}
          >
            {t.charAt(0).toUpperCase() + t.slice(1)}
          </button>
        ))}
        <button className="git-checkpoint-btn" onClick={handleCheckpoint}>
          Checkpoint
        </button>
      </div>

      {/* Diff Viewer Overlay */}
      {selectedDiff && (
        <div className="git-diff-overlay">
          <div className="git-diff-header">
            <span>{selectedDiff.file}</span>
            <button className="git-diff-close" onClick={() => setSelectedDiff(null)}>Close</button>
          </div>
          <pre className="git-diff-content">{selectedDiff.diff}</pre>
        </div>
      )}

      {/* Changes Tab */}
      {tab === "changes" && !selectedDiff && (
        <div className="git-content">
          {loading ? (
            <p className="git-empty">Loading...</p>
          ) : files.length === 0 ? (
            <p className="git-empty">No changes</p>
          ) : (
            <div className="git-files">
              {files.map((f, i) => (
                <div key={i} className="git-file">
                  <span className={`git-file-status git-file-status--${f.status}`}>{f.status}</span>
                  <button className="git-file-name" onClick={() => handleViewDiff(f.path)}>
                    {f.path}
                  </button>
                  <div className="git-file-actions">
                    <button className="git-action-btn" onClick={() => handleStage(f.path)}>Stage</button>
                    <button className="git-action-btn git-action-btn--danger" onClick={() => handleDiscard(f.path)}>Discard</button>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      )}

      {/* History Tab */}
      {tab === "history" && !selectedDiff && (
        <div className="git-content">
          {loading ? (
            <p className="git-empty">Loading...</p>
          ) : commits.length === 0 ? (
            <p className="git-empty">No commits</p>
          ) : (
            <div className="git-commits">
              {commits.map((c) => (
                <div key={c.hash} className="git-commit">
                  <div className="git-commit-info">
                    <span className="git-commit-hash">{c.hash?.substring(0, 7)}</span>
                    <span className="git-commit-msg">{c.message}</span>
                  </div>
                  <div className="git-commit-meta">
                    <span>{c.author}</span>
                    <button className="git-action-btn git-action-btn--danger" onClick={() => handleRollback(c.hash)}>
                      Rollback
                    </button>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      )}

      {/* Branches Tab */}
      {tab === "branches" && !selectedDiff && (
        <div className="git-content">
          {loading ? (
            <p className="git-empty">Loading...</p>
          ) : branches.length === 0 ? (
            <p className="git-empty">No branches</p>
          ) : (
            <div className="git-branches">
              {branches.map((b) => (
                <div key={b} className={`git-branch ${b === currentBranch ? "git-branch--current" : ""}`}>
                  <span>{b}</span>
                  {b !== currentBranch && (
                    <button className="git-action-btn" onClick={() => handleCheckout(b)}>
                      Checkout
                    </button>
                  )}
                  {b === currentBranch && <span className="git-branch-badge">current</span>}
                </div>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
