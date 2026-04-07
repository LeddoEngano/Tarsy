"use client";

import { useState } from "react";
import { createClient } from "../supabase/client";

export function FeedbackModal({ onClose }) {
  const [type, setType] = useState("bug");
  const [description, setDescription] = useState("");
  const [sending, setSending] = useState(false);
  const [sent, setSent] = useState(false);
  const [error, setError] = useState(null);

  async function handleSubmit() {
    if (!description.trim()) return;
    setSending(true);
    setError(null);

    try {
      const supabase = createClient();
      const { data: { user } } = await supabase.auth.getUser();

      const response = await fetch("/api/contact", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          name: user?.email || "Web User",
          email: user?.email || "",
          type,
          message: description,
        }),
      });

      if (!response.ok) throw new Error("Failed to send");
      setSent(true);
    } catch (e) {
      setError(e.message);
      setSending(false);
    }
  }

  if (sent) {
    return (
      <div className="modal-backdrop" onClick={onClose}>
        <div className="modal" onClick={(e) => e.stopPropagation()}>
          <div className="modal-header">
            <h2 className="modal-title">Thanks!</h2>
            <button className="modal-close" onClick={onClose}>Close</button>
          </div>
          <div className="modal-body">
            <p className="modal-desc">Your feedback has been submitted.</p>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-header">
          <h2 className="modal-title">Send Feedback</h2>
          <button className="modal-close" onClick={onClose}>Close</button>
        </div>
        <div className="modal-body">
          <label className="auth-label">
            Type
            <select className="dash-select" value={type} onChange={(e) => setType(e.target.value)}>
              <option value="bug">Bug Report</option>
              <option value="feature">Feature Request</option>
              <option value="general">General</option>
            </select>
          </label>
          <label className="auth-label">
            Description
            <textarea
              className="ws-input"
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              rows={5}
              placeholder="Describe the issue or suggestion..."
              style={{ minHeight: "100px" }}
            />
          </label>
          {error && <p className="auth-error">{error}</p>}
          <button className="auth-submit" onClick={handleSubmit} disabled={sending || !description.trim()}>
            {sending ? "Sending..." : "Submit"}
          </button>
        </div>
      </div>
    </div>
  );
}
