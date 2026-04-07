"use client";

import { useState, useEffect, useRef, useCallback } from "react";
import { useParams } from "next/navigation";
import { useConnection } from "../../../lib/tarsy/ConnectionProvider";
import { createClient } from "../../../lib/supabase/client";
import { StreamPlayer } from "../../../lib/tarsy/StreamPlayer";
import { useRemoteInput } from "../../../lib/tarsy/RemoteInput";
import { GitPanel } from "../../../lib/tarsy/GitPanel";
import { FileExplorer } from "../../../lib/tarsy/FileExplorer";

export default function WorkspacePage() {
  const { id } = useParams();
  const { send, addListener, removeListener, isConnected } = useConnection();
  const [workspace, setWorkspace] = useState(null);

  // Tab state
  const [tabs, setTabs] = useState([]);
  const [activeTab, setActiveTab] = useState(null);
  // TODO: Per-tab message isolation — currently all tabs share one message list.
  // Implement save/restore of tabStates[tabId] on tab switch when multi-engine is needed.
  const [tabStates, setTabStates] = useState({}); // eslint-disable-line no-unused-vars

  // Chat state for active tab
  const [messages, setMessages] = useState([]);
  const [input, setInput] = useState("");
  const [isThinking, setIsThinking] = useState(false);
  const [activity, setActivity] = useState(null);
  const [contextPercent, setContextPercent] = useState(0);
  const [engineModel, setEngineModel] = useState("");

  // Interactive state
  const [options, setOptions] = useState(null);
  const [questions, setQuestions] = useState(null);
  const [permissionRequest, setPermissionRequest] = useState(null);

  // View mode: "chat" | "stream" | "git" | "files"
  const [viewMode, setViewMode] = useState("chat");
  const messagesEndRef = useRef(null);

  // Remote input for stream
  const { containerProps, inputRef, handleInput, handleKeyDown } = useRemoteInput(send, viewMode === "stream");

  // Load workspace info
  useEffect(() => {
    async function load() {
      const supabase = createClient();
      const { data } = await supabase
        .from("workspaces")
        .select("*")
        .eq("id", id)
        .single();
      if (data) setWorkspace(data);
    }
    load();
  }, [id]);

  // Initialize tabs from detected agents
  useEffect(() => {
    const listenerId = `workspace-${id}-agents`;
    addListener(listenerId, (packet) => {
      if (packet.action === "agents:detected" && packet.payload?.agents) {
        try {
          const agents = JSON.parse(packet.payload.agents);
          const newTabs = agents.map((a) => ({
            id: `engine-${a}`,
            engineType: a,
            label: a.charAt(0).toUpperCase() + a.slice(1),
            sessionId: null,
          }));
          if (newTabs.length > 0) {
            setTabs(newTabs);
            setActiveTab(newTabs[0].id);
          }
        } catch { /* malformed */ }
      }
    });
    return () => removeListener(listenerId);
  }, [id, addListener, removeListener]);

  // Listen for engine packets
  useEffect(() => {
    const listenerId = `workspace-${id}-engine`;

    addListener(listenerId, (packet) => {
      const { action, payload } = packet;

      switch (action) {
        case "engine:output":
          if (payload?.text) {
            setMessages((prev) => {
              const last = prev[prev.length - 1];
              if (last?.role === "assistant" && !last.complete) {
                return [...prev.slice(0, -1), { ...last, content: last.content + payload.text }];
              }
              return [...prev, { id: packet.id, role: "assistant", content: payload.text, complete: false }];
            });
            setIsThinking(false);
          }
          if (payload?.activity) {
            setActivity(payload.activity);
          }
          break;

        case "engine:complete":
          setMessages((prev) =>
            prev.map((m) => (m.role === "assistant" && !m.complete ? { ...m, complete: true } : m))
          );
          setIsThinking(false);
          setActivity(null);
          break;

        case "engine:ask_user":
          setIsThinking(false);
          if (payload?.isPermission === "true") {
            setPermissionRequest({
              requestId: payload.requestId,
              toolName: payload.toolName,
              input: payload.input,
            });
          } else if (payload?.questions) {
            try {
              setQuestions(JSON.parse(payload.questions));
            } catch { /* malformed */ }
          } else if (payload?.options) {
            try {
              setOptions(JSON.parse(payload.options));
            } catch { /* malformed */ }
          }
          break;

        case "engine:status":
          if (payload?.model) setEngineModel(payload.model);
          if (payload?.contextPercent) setContextPercent(parseFloat(payload.contextPercent) || 0);
          break;

        case "engine:error":
          setMessages((prev) => [
            ...prev,
            { id: packet.id, role: "system", content: payload?.message || "Engine error", complete: true },
          ]);
          setIsThinking(false);
          break;

        default:
          break;
      }
    });

    return () => removeListener(listenerId);
  }, [id, addListener, removeListener]);

  // Auto-scroll on new messages
  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  // Send message
  const handleSend = useCallback(() => {
    const text = input.trim();
    if (!text || !activeTab) return;

    const tab = tabs.find((t) => t.id === activeTab);
    if (!tab) return;

    // Create session if needed
    if (!tab.sessionId && workspace) {
      const createId = send("engine:create", {
        path: workspace.local_path,
        engineType: tab.engineType,
        workspaceId: id,
      });
      if (createId) {
        setTabs((prev) =>
          prev.map((t) => (t.id === activeTab ? { ...t, sessionId: createId } : t))
        );
      }
    }

    setMessages((prev) => [...prev, { id: crypto.randomUUID(), role: "user", content: text, complete: true }]);
    send("engine:message", { message: text, engineType: tab.engineType });
    setInput("");
    setIsThinking(true);
  }, [input, activeTab, tabs, workspace, id, send]);

  // Respond to question/option
  const handleResponse = useCallback((answer) => {
    send("engine:user_response", { response: answer });
    setOptions(null);
    setQuestions(null);
    setIsThinking(true);
  }, [send]);

  // Respond to permission
  const handlePermission = useCallback((allow) => {
    send("engine:user_response", {
      requestId: permissionRequest?.requestId,
      behavior: allow ? "allow" : "deny",
    });
    setPermissionRequest(null);
    setIsThinking(true);
  }, [send, permissionRequest]);

  if (!workspace) {
    return (
      <main className="app-container">
        <p className="app-subtitle">Loading workspace...</p>
      </main>
    );
  }

  return (
    <main className="ws-page">
      {/* Header */}
      <div className="ws-header">
        <div>
          <h1 className="ws-name">{workspace.name}</h1>
          <div className="ws-meta">
            {workspace.current_branch && <span>{workspace.current_branch}</span>}
            {engineModel && <span>{engineModel}</span>}
            {contextPercent > 0 && <span>{Math.round(contextPercent)}% context</span>}
          </div>
        </div>
        <div className="ws-header-actions">
          {["chat", "stream", "git", "files"].map((mode) => (
            <button
              key={mode}
              className={`ws-view-btn ${viewMode === mode ? "ws-view-btn--active" : ""}`}
              onClick={() => setViewMode(mode)}
            >
              {mode.charAt(0).toUpperCase() + mode.slice(1)}
            </button>
          ))}
          <a href="/dashboard" className="ws-back">Dashboard</a>
        </div>
      </div>

      {/* Tabs */}
      {tabs.length > 0 && (
        <div className="ws-tabs">
          {tabs.map((tab) => (
            <button
              key={tab.id}
              className={`ws-tab ${tab.id === activeTab ? "ws-tab--active" : ""}`}
              onClick={() => setActiveTab(tab.id)}
            >
              {tab.label}
            </button>
          ))}
        </div>
      )}

      {/* Stream View */}
      {viewMode === "stream" && (
        <div {...containerProps} className="ws-stream-wrap">
          <StreamPlayer workspacePath={workspace.local_path} stack={workspace.stack} />
          <input
            ref={inputRef}
            className="ws-hidden-input"
            onInput={handleInput}
            onKeyDown={handleKeyDown}
            autoComplete="off"
          />
        </div>
      )}

      {/* Git View */}
      {viewMode === "git" && (
        <GitPanel workspacePath={workspace.local_path} />
      )}

      {/* Files View */}
      {viewMode === "files" && (
        <FileExplorer workspacePath={workspace.local_path} />
      )}

      {/* Chat View */}
      {viewMode === "chat" && (
        <>
          <div className="ws-messages">
            {messages.map((msg) => (
              <div key={msg.id} className={`ws-msg ws-msg--${msg.role}`}>
                <div className="ws-msg-content">{msg.content}</div>
              </div>
            ))}

            {isThinking && (
              <div className="ws-msg ws-msg--assistant">
                <div className="ws-thinking">Thinking...</div>
              </div>
            )}

            {activity && (
              <div className="ws-activity">{activity}</div>
            )}

            {/* Interactive Options */}
            {options && (
              <div className="ws-options">
                {options.map((opt, i) => (
                  <button
                    key={i}
                    className="ws-option-btn"
                    onClick={() => handleResponse(opt.value || opt)}
                  >
                    {i + 1}. {opt.label || opt}
                  </button>
                ))}
              </div>
            )}

            {/* Interactive Questions */}
            {questions && (
              <div className="ws-questions">
                {questions.map((q, i) => (
                  <div key={i} className="ws-question">
                    <p className="ws-question-text">{q.question}</p>
                    <div className="ws-question-options">
                      {q.options?.map((opt, j) => (
                        <button
                          key={j}
                          className="ws-option-btn"
                          onClick={() => handleResponse(opt)}
                        >
                          {opt}
                        </button>
                      ))}
                    </div>
                  </div>
                ))}
              </div>
            )}

            {/* Permission Request */}
            {permissionRequest && (
              <div className="ws-permission">
                <p className="ws-permission-title">Permission Required</p>
                <p className="ws-permission-tool">{permissionRequest.toolName}</p>
                <div className="ws-permission-actions">
                  <button className="ws-perm-allow" onClick={() => handlePermission(true)}>
                    Allow
                  </button>
                  <button className="ws-perm-deny" onClick={() => handlePermission(false)}>
                    Deny
                  </button>
                </div>
              </div>
            )}

            <div ref={messagesEndRef} />
          </div>

          {/* Input */}
          <div className="ws-input-bar">
            <textarea
              className="ws-input"
              value={input}
              onChange={(e) => setInput(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter" && !e.shiftKey) {
                  e.preventDefault();
                  handleSend();
                }
              }}
              placeholder="Send a message..."
              rows={1}
            />
            <button className="ws-send" onClick={handleSend} disabled={!input.trim()}>
              Send
            </button>
          </div>
        </>
      )}
    </main>
  );
}
