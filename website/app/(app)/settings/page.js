"use client";

import { useState, useEffect } from "react";
import { createClient } from "../../lib/supabase/client";
import { useVoiceInput } from "../../lib/tarsy/VoiceInput";
import { useSignOut } from "../../lib/tarsy/hooks";

export default function SettingsPage() {
  const [profile, setProfile] = useState(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [displayName, setDisplayName] = useState("");
  const [deleteConfirm, setDeleteConfirm] = useState(false);
  const signOut = useSignOut();
  const { language, languages, changeLanguage, supported: voiceSupported } = useVoiceInput();

  // Load profile
  useEffect(() => {
    async function load() {
      const supabase = createClient();
      const { data: { user } } = await supabase.auth.getUser();
      if (!user) return;

      const { data } = await supabase
        .from("profiles")
        .select("*")
        .eq("id", user.id)
        .single();

      if (data) {
        setProfile(data);
        setDisplayName(data.display_name || "");
      }
      setLoading(false);
    }
    load();
  }, []);

  async function handleSaveName() {
    if (!profile) return;
    setSaving(true);
    const supabase = createClient();
    await supabase
      .from("profiles")
      .update({ display_name: displayName })
      .eq("id", profile.id);
    setSaving(false);
  }

  async function handleDeleteAccount() {
    if (!deleteConfirm) {
      setDeleteConfirm(true);
      return;
    }
    const supabase = createClient();
    const { error } = await supabase.functions.invoke("delete-account");
    if (error) {
      setDeleteConfirm(false);
      return;
    }
    await supabase.auth.signOut();
    window.location.href = "/login";
  }

  if (loading) {
    return (
      <main className="app-container">
        <p className="app-subtitle">Loading...</p>
      </main>
    );
  }

  return (
    <main className="app-container">
      <div className="settings-header">
        <h1 className="app-title">Settings</h1>
        <a href="/dashboard" className="ws-back">Dashboard</a>
      </div>

      {/* Profile */}
      <section className="settings-section">
        <h2 className="settings-section-title">Profile</h2>
        <div className="settings-field">
          <label className="auth-label">
            Email
            <input className="auth-input" value={profile?.email || ""} disabled />
          </label>
        </div>
        <div className="settings-field">
          <label className="auth-label">
            Display Name
            <input
              className="auth-input"
              value={displayName}
              onChange={(e) => setDisplayName(e.target.value)}
            />
          </label>
          <button className="settings-save" onClick={handleSaveName} disabled={saving}>
            {saving ? "Saving..." : "Save"}
          </button>
        </div>
      </section>

      {/* Subscription */}
      <section className="settings-section">
        <h2 className="settings-section-title">Subscription</h2>
        <p className="settings-value">
          {profile?.is_pro ? "Pro" : "Free"}
          {profile?.subscription_status && ` (${profile.subscription_status})`}
        </p>
        {!profile?.is_pro && (
          <a href="/pricing" className="settings-upgrade">Upgrade to Pro</a>
        )}
      </section>

      {/* Voice Language */}
      <section className="settings-section">
        <h2 className="settings-section-title">Voice Language</h2>
        {voiceSupported ? (
          <select
            className="dash-select"
            value={language}
            onChange={(e) => changeLanguage(e.target.value)}
          >
            {languages.map((l) => (
              <option key={l.code} value={l.code}>{l.name}</option>
            ))}
          </select>
        ) : (
          <p className="settings-note">Voice input requires Chrome or Edge.</p>
        )}
      </section>

      {/* Account */}
      <section className="settings-section">
        <h2 className="settings-section-title">Account</h2>
        <button className="settings-signout" onClick={signOut}>Sign Out</button>
        <button
          className="settings-delete"
          onClick={handleDeleteAccount}
        >
          {deleteConfirm ? "Confirm Delete — this is irreversible" : "Delete Account"}
        </button>
      </section>
    </main>
  );
}
