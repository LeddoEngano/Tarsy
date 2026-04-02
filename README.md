<p align="center">
  <img src="logos/white-tarsy-logo.svg" alt="Tarsy" width="200" />
</p>

<h3 align="center">Control your Mac. Steer your AI agents. From your iPhone.</h3>

<p align="center">
  Tarsy is a remote desktop and AI coding agent platform for the Apple ecosystem.<br/>
  Monitor, interact with, and steer AI agents working on your codebase — from anywhere.
</p>

<p align="center">
  <a href="https://tarsy.dev">Website</a> &nbsp;·&nbsp;
  <a href="#getting-started">Getting Started</a> &nbsp;·&nbsp;
  <a href="#architecture">Architecture</a> &nbsp;·&nbsp;
  <a href="#features">Features</a>
</p>

---

## Why Tarsy?

You kick off an AI coding agent on your Mac, close the lid, and walk away. From your iPhone, you can see exactly what it's doing — approve file changes, answer permission prompts, watch the screen in real-time, and course-correct when it goes off track.

No VNC. No SSH. No browser tab left open. Just your phone.

## Features

- **Remote Desktop Streaming** — Hardware-accelerated H.264 video from your Mac to your iPhone, over LAN or relay
- **AI Agent Control** — Run and interact with Claude Code, Gemini CLI, Codex CLI, Aider, or any custom CLI agent
- **End-to-End Encrypted** — All packets and video frames encrypted with TOFU key pinning
- **Smart Connect** — Automatic LAN detection with seamless relay fallback
- **Git Safety Net** — View diffs, browse history, rollback to checkpoints — all from your phone
- **Live Activities** — Real-time agent status on your Lock Screen and Dynamic Island
- **Voice Input** — Dictate messages to your agents in 9 languages
- **Dev Server Preview** — Browse your running app through a proxied in-app browser
- **File Explorer** — Browse your project tree and read files remotely
- **MCP Store** — Detect and monitor MCP integrations across all installed agents

## Architecture

Tarsy is a monorepo with five components:

<p align="center">
  <img src="docs/architecture_diagram.png" alt="Tarsy Architecture Diagram" width="800" />
</p>

| Component | Tech | Role |
|-----------|------|------|
| **TarsyShared** | Swift Package | Shared auth, networking, models, E2E crypto |
| **TarsymacOS** | Swift, ScreenCaptureKit, VideoToolbox | Menu bar daemon — capture, input, AI engines |
| **TarsyiOS** | SwiftUI, AVFoundation, StoreKit 2 | iPhone app — stream, chat, manage |
| **Relay** | Bun, Hono, TypeScript | WebSocket bridge on Fly.io |
| **Supabase** | PostgreSQL, Edge Functions | Auth, database, push notifications |

## Getting Started

### Prerequisites

- macOS 14.0+, iOS 17.0+, Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- [Bun](https://bun.sh) — for the relay server
- [Supabase CLI](https://supabase.com/docs/guides/cli) — for local backend

### Setup

```bash
# Clone the repo
git clone https://github.com/anthropics/tarsy.git
cd tarsy

# Generate Xcode projects
cd TarsyiOS && xcodegen generate && cd ..
cd TarsymacOS && xcodegen generate && cd ..

# Install relay dependencies
npm install

# Start the relay dev server
npm run dev:relay

# Start the website dev server
npm run dev:website
```

Open `TarsymacOS/TarsymacOS.xcodeproj` and `TarsyiOS/TarsyiOS.xcodeproj` in Xcode, then build and run.

### Environment

Create `.env` files with your Supabase credentials and other secrets. See the Supabase and relay directories for required variables. Never commit secrets.

## AI Engines

Tarsy supports multiple AI coding agents running as CLI processes on your Mac:

| Engine | Integration | Notes |
|--------|------------|-------|
| Claude Code | Dedicated session | Token tracking, interactive prompts |
| Gemini CLI | Generic engine | Full chat support |
| Codex CLI | Generic engine | Full chat support |
| Aider | Generic engine | Full chat support |
| Custom | Generic engine | Any CLI tool |

All engines conform to `AIEngineProtocol`. The macOS app auto-detects installed agents on startup via `AgentDetector`.

## Networking

Communication uses WebSocket with a custom binary packet protocol (`WSProtocol`, 60+ action types):

- **LAN mode** — Direct connection via `Network.framework` on port 8642
- **Relay mode** — Through `wss://tarsy-relay.fly.dev/ws` with JWT auth
- **Smart Connect** — Tries LAN first (3s timeout), falls back to relay

All traffic is end-to-end encrypted. Video frames use binary WebSocket messages with a 4-byte `H264` prefix.

## Pricing

| | Free | Pro |
|---|---|---|
| Workspaces | 1 | Unlimited |
| Remote Desktop | Yes | Yes |
| AI Agent Control | Yes | Yes |
| E2E Encryption | Yes | Yes |
| OpenClaw (Local LLM) | — | Yes |
| **Price** | $0 | $14.99/mo or $119.99/yr |

## Building for Distribution

```bash
# Build signed and notarized DMG
./scripts/build-dmg.sh
```

Requires a Developer ID Application certificate and notarization credentials stored in Keychain as `tarsy-notarize`.

## Project Structure

<details>
<summary>Expand full directory map</summary>

```
tarsy/
├── TarsyShared/           # Swift Package — shared code
│   └── Sources/
│       ├── Auth/          # AuthManager (Apple, GitHub, email)
│       ├── Networking/    # ConnectionManager, WSProtocol, E2ECrypto
│       ├── Models/        # Workspace, Machine, ChatMessage, etc.
│       └── Services/      # Workspace, Machine, Chat, Profile services
├── TarsymacOS/            # macOS menu bar app
│   └── Sources/
│       ├── DaemonManager  # Central orchestrator
│       ├── Capture/       # ScreenCaptureKit, H264 encoder
│       ├── Input/         # Remote input dispatch
│       ├── AI/            # Engine sessions, agent detection
│       └── Networking/    # Relay client, local WebSocket server
├── TarsyiOS/              # iOS app
│   └── Sources/
│       ├── Stream/        # H264 decoder, player, interactive view
│       ├── Chat/          # AI chat interface
│       ├── Dashboard/     # Machine & workspace management
│       ├── Git/           # Safety net, diff viewer
│       └── Theme/         # TarsyTheme design system
├── relay/                 # Bun + Hono WebSocket relay
├── supabase/              # Migrations, edge functions
├── website/               # Next.js landing page
└── scripts/               # Build & deployment scripts
```

</details>

## License

Proprietary. All rights reserved.

---

<p align="center">
  Built for developers who let AI agents do the heavy lifting — and want to stay in control.
</p>
