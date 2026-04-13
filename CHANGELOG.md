# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.1.0] - 2026-04-11

### Added
- Hot Reload for SwiftUI apps: push changes to the iOS Simulator without rebuilding
- Build & Run tab with build progress, hot reload status, and simulator controls
- Browser tab switcher with Chrome automation onboarding
- Adaptive theme system with accent color, font, and appearance customization
- Voice recorder with HUD and slide-to-cancel (WhatsApp-style)
- Simulator rotate button with dynamic stream aspect ratio
- Asymmetric pill shape for workspace cards
- Default paywall plan to monthly

### Fixed
- Video stream recovery after WebSocket reconnect
- Virtual key codes for remote keyboard input
- Terminal stays alive on Ctrl+C with SIGINT trap

### Security
- Keypair rotation via `securityRotateSecret`
- Dropped legacy plaintext columns and dual-auth (hard cutover to encrypted paths)

## [1.0.1] - 2026-03-28

### Added
- Push notifications for agent status changes
- Persistent agent tasks with lifecycle tracking (running, waiting, completed, error)
- Agent detection and permission configuration
- Live Activities on Lock Screen and Dynamic Island
- MCP Store for detecting and monitoring MCP integrations
- Quick Dispatch for rapid task dispatch from dashboard
- Active Sessions view with UltraContext session management

### Fixed
- Various relay connection stability improvements

## [1.0.0] - 2026-03-15

### Added
- Remote desktop streaming (H.264 over WebSocket, LAN and relay)
- AI agent control (Claude Code, Gemini CLI, Codex CLI, Aider, custom)
- End-to-end encryption with TOFU key pinning
- Smart Connect (auto LAN detection with relay fallback)
- Git Safety Net (diffs, history, rollback from iPhone)
- Voice input in 9 languages
- Dev server preview with proxied in-app browser
- File explorer with tree view and search
- WebSocket relay server on Fly.io
- Supabase backend with auth, database, and edge functions
