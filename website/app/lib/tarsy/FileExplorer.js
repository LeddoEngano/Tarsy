"use client";

import { useState, useEffect, useCallback } from "react";
import { useConnection } from "./ConnectionProvider";

const FILE_ICONS = {
  js: "#e0a86a", jsx: "#e0a86a", ts: "#71717a", tsx: "#71717a",
  py: "#6bc77b", rs: "#e5716a", go: "#6bc77b", swift: "#e5716a",
  json: "#e0a86a", md: "#71717a", css: "#71717a", html: "#e5716a",
};

export function FileExplorer({ workspacePath }) {
  const { send, addListener, removeListener } = useConnection();
  const [tree, setTree] = useState([]);
  const [expanded, setExpanded] = useState(new Set());
  const [search, setSearch] = useState("");
  const [preview, setPreview] = useState(null);
  const [loading, setLoading] = useState(true);

  // Listen for file results
  useEffect(() => {
    const lid = "file-explorer";
    addListener(lid, (packet) => {
      if (packet.action === "file:tree_result" && packet.payload?.tree) {
        try {
          setTree(JSON.parse(packet.payload.tree));
          setLoading(false);
        } catch { /* malformed */ }
      }
      if (packet.action === "file:read_result" && packet.payload?.content) {
        setPreview({
          file: packet.payload.file,
          content: packet.payload.content,
          language: packet.payload.language || "",
        });
      }
    });
    return () => removeListener(lid);
  }, [addListener, removeListener]);

  // Load tree
  useEffect(() => {
    if (workspacePath) {
      send("file:tree", { path: workspacePath });
    }
  }, [workspacePath, send]);

  const toggleDir = useCallback((path) => {
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(path)) {
        next.delete(path);
      } else {
        next.add(path);
      }
      return next;
    });
  }, []);

  const openFile = useCallback((filePath) => {
    send("file:read", { path: workspacePath, file: filePath });
  }, [workspacePath, send]);

  // Filter by search
  const filteredTree = search
    ? tree.filter((f) => f.type === "file" && f.name.toLowerCase().includes(search.toLowerCase()))
    : tree;

  // Visible items (respect expansion state)
  const visibleItems = search
    ? filteredTree
    : filteredTree.filter((item) => {
        if (item.depth === 0) return true;
        // Check if all parent dirs are expanded
        const parts = item.path.split("/");
        for (let i = 1; i < parts.length; i++) {
          const parentPath = parts.slice(0, i).join("/");
          if (!expanded.has(parentPath)) return false;
        }
        return true;
      });

  return (
    <div className="fe-panel">
      {/* Search */}
      <div className="fe-search-bar">
        <input
          className="fe-search"
          type="text"
          placeholder="Search files..."
          value={search}
          onChange={(e) => setSearch(e.target.value)}
        />
      </div>

      {/* Preview Overlay */}
      {preview && (
        <div className="fe-preview">
          <div className="fe-preview-header">
            <span>{preview.file}</span>
            <button className="fe-preview-close" onClick={() => setPreview(null)}>Close</button>
          </div>
          <pre className="fe-preview-content">{preview.content}</pre>
        </div>
      )}

      {/* Tree */}
      {!preview && (
        <div className="fe-tree">
          {loading ? (
            <p className="fe-empty">Loading...</p>
          ) : visibleItems.length === 0 ? (
            <p className="fe-empty">{search ? "No matches" : "Empty"}</p>
          ) : (
            visibleItems.map((item) => (
              <button
                key={item.path}
                className="fe-item"
                style={{ paddingLeft: `${(item.depth || 0) * 16 + 8}px` }}
                onClick={() => item.type === "dir" ? toggleDir(item.path) : openFile(item.path)}
              >
                <span className="fe-icon" style={{
                  color: item.type === "dir"
                    ? "var(--app-text-secondary)"
                    : FILE_ICONS[item.ext] || "var(--app-text-secondary)",
                }}>
                  {item.type === "dir" ? (expanded.has(item.path) ? "v" : ">") : " "}
                </span>
                <span className="fe-name">{item.name}</span>
                {search && item.path && (
                  <span className="fe-path">{item.path}</span>
                )}
              </button>
            ))
          )}
        </div>
      )}
    </div>
  );
}
