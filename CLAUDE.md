# Tarsy

Tarsy is a remote desktop + AI coding agent platform for the Apple ecosystem. It lets developers control their Mac and run AI coding agents (Claude Code, Gemini CLI, Codex CLI, Aider) remotely from their iPhone. The core value proposition: you can monitor, interact with, and steer AI agents working on your codebase from anywhere.

**Status:** Production. All decisions should be made with production-grade quality, security, and reliability in mind. No shortcuts, no "good enough for now" — treat every change as shipping to paying users.

## Architecture

The project is a monorepo with five main components:

### TarsyShared (Swift Package)

Shared library consumed by both apps. `supabase-swift` (>= 2.0) is the only external dependency.

- **AuthManager** — unified auth (Apple, GitHub OAuth, email/password) with platform-specific redirect schemes (`com.tarsy.ios://` and `com.tarsy.macos://`)
- **Networking** — `ConnectionManager` (dual-mode WebSocket: LAN via `Network.framework`, relay via `URLSessionWebSocketTask`), `WSProtocol` (60+ action types), `E2ECrypto` (end-to-end encryption with TOFU key pinning for all packets and binary frames), `UltraContextClient` (context API with Keychain storage)
- **SupabaseClient** — global singleton for auth and data
- **Models** — `Workspace`, `Machine`, `ChatMessage`, `AIEngineType`, `Profile`, `AgentTask`, `AgentPermissionConfig`
- **Services** — `WorkspaceService`, `MachineService`, `ChatService` (paginated, 50/page), `ProfileService` (preferences, subscription sync, billing emails), `AgentTaskService` (task lifecycle: running → waiting → completed/error)

### TarsymacOS (XcodeGen project)

Menu bar app (LSUIElement) that runs on the Mac being controlled. `DaemonManager` is the central orchestrator (~2600 lines) that wires all services together.

- **Screen capture** — `ScreenCaptureService` (ScreenCaptureKit) → `H264Encoder` (VideoToolbox, adaptive bitrate: 6Mbps/30fps LAN, 2Mbps/20fps relay) → WebSocket binary frames (authenticated, port 8642).
- **Remote input** — `RemoteInputService` dispatches tap/scroll/keyboard/drag/pinch to browser (CGEvent) or iOS Simulator (idb) with coordinate mapping.
- **AI engines** — `TerminalSessionManager` (zsh sessions with rich PATH enrichment: nvm, fnm, asdf, cargo, etc.) + `ClaudeCodeSession` (dedicated Claude Code subprocess with token tracking) + `GenericCLIEngine` (wraps any CLI agent). All conform to `AIEngineProtocol` (actor protocol). `AgentDetector` scans standard paths for installed AI binaries.
- **Workspace orchestration** — `WorkspaceOrchestrator` (git clone, stack detection, dependency install, dev server start), `RepoScanner` (async scan of ~10 standard directories)
- **Networking** — `RelayClient` (machine-to-cloud WebSocket with exponential backoff, token refresh), `WebSocketServer` (local LAN server on port 8642), `TailscaleManager` (VPN discovery)
- **Sudo handling** — `SudoPasswordManager` (actor) bridges sudo requests to iOS via WebSocket, caches password (60s TTL), rewrites commands with SUDO_ASKPASS wrapper. Hardened with command whitelist (word-boundary matching), no-shell execution, and printf wrapper.
- **Background services** — `UltraContextDaemon` (CLI daemon lifecycle), `OpenClawService` (local LLM gateway on port 18789 with SSE streaming), `PushNotificationService` (local + remote via Supabase)
- **System** — Sleep prevention (IOKit assertions), heartbeat (30s machine status update), onboarding window (3-step setup)

### TarsyiOS (XcodeGen project)

iPhone/iPad app. Entry point: `ContentView` manages auth state (splash → login → dashboard) with environment objects: `AuthManager`, `ConnectionManager`, `WorkspaceService`, `MachineService`, `SubscriptionManager`, `ProfileService`, `DeepLinkRouter`.

- **Stream player** — `StreamPlayerView` + `StreamViewModel` + `H264Decoder` (hardware-accelerated, supports H.264 and HEVC with auto-detection) + `H264PlayerView` (AVSampleBufferDisplayLayer) + `InteractiveStreamView` (touch/keyboard/scroll/pinch input with hidden UITextField for keyboard capture). All streaming uses H.264 via authenticated WebSocket (both LAN and relay).
- **AI chat** — `WorkspaceView` with tab system (per-tab state isolation: thinking, activity, options, questions, model, contextPercent), voice input, attachments, interactive options/questions (PaginatedQuestionCard with pagination, multi-select), VoiceTodoManager/VoiceTodoOverlay for task tracking
- **Dashboard** — `DashboardView` lists machines (online/offline indicator), workspaces (status-colored), active tasks, action buttons (Quick Dispatch, Active Sessions, New Workspace, Settings)
- **Workspace management** — `NewWorkspaceView` (scanned repos + manual creation), `WorkspaceSettingsView`, `AIContextEditorView` (templates for project overview, coding style, testing rules)
- **MCP integrations** — `MCPStoreView` detects MCPs from all installed agents (not just Claude Code) with health indicators
- **Web browser** — `WebBrowserView` (dev server management, port detection, WKWebView) + `TarsyProxySchemeHandler` (custom `tarsy-http://` scheme that proxies requests through WebSocket)
- **Subscription** — `SubscriptionManager` (StoreKit 2, product: `tarsy_pro_monthly`) + `PaywallView`. Free: 1 workspace. Pro ($9/month): unlimited workspaces + OpenClaw access.
- **Git** — `GitSafetyNetView` (3 tabs: Changes, History, Branches; diff viewer, rollback with checkpoints)
- **Live Activities** — `LiveActivityManager` shows real-time agent status on the Lock Screen and Dynamic Island during active AI sessions
- **Other** — `FileExplorerView` (tree view with search), `VoiceInputManager` (SFSpeechRecognizer, 9 languages, on-device when available), `PermissionOnboardingView` (auto/safe mode per engine), `ActiveSessionsView` (UltraContext session list with continue-session), `QuickDispatchView` (rapid task dispatch from dashboard), `SplashView`, `LoginView`, `StatusBanner` (reconnecting/error/relay indicators), `Haptics`

### Relay Server (Bun + Hono)

WebSocket relay at `relay/`. Bridges iOS clients with macOS machines over the internet.

- **Tech:** Bun runtime, Hono.js framework, TypeScript
- **Auth:** JWT validation via Supabase + machine secret verification
- **Features:** Connection tracking (machines + clients per user), message forwarding, action allowlists (machines vs clients), rate limiting (120 msg/sec per connection, max 5 clients per user), health endpoint (`/health`)
- **Deployment:** Fly.io, app `tarsy-relay`, region `gru` (São Paulo), 1 shared CPU, 1GB RAM, forced HTTPS
- **URL:** `wss://tarsy-relay.fly.dev/ws`

### Supabase (Backend)

Auth, database, edge functions, and realtime at `supabase/`.

**Tables:** `machines` (includes `model_identifier` for device-specific icons), `workspaces`, `push_tokens`, `push_notifications`, `agent_tasks`, `profiles`

**Edge Functions:**
- `send-push` — APNs delivery triggered by webhook on `push_notifications` INSERT. Requires: `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_PRIVATE_KEY`, `APNS_BUNDLE_ID`
- `send-email` — Transactional emails via Resend API triggered by webhook on `profiles` INSERT (welcome) or direct invocation (billing). Requires: `RESEND_API_KEY`, `RESEND_FROM_EMAIL`

**Security:** RLS on all tables (users access only their own data). Auto-profile creation trigger on `auth.users` INSERT. Edge functions hardened with JWS verification and error sanitization.

**Realtime:** Enabled on `machines`, `workspaces`, `profiles`.

**Migrations:** 24 sequential files in `supabase/migrations/` — always add new migrations sequentially (e.g., `025_*.sql`).

### Website (Next.js)

Landing page at `website/`. Next.js 16 with CSS Modules. Pages: home (hero, features, pricing), contact, privacy, terms. Matches TarsyTheme dark aesthetic with monospace fonts.

## Connectivity

The iOS app connects to the macOS app via:

1. **Smart connect** (default) — tries LAN first (3s timeout), falls back to relay automatically
2. **Relay** — pure relay via `wss://tarsy-relay.fly.dev/ws`
3. **LAN direct** — connects directly when both devices are on the same network

Communication uses WebSocket with a custom binary packet protocol (`WSProtocol`). All packets and binary frames are end-to-end encrypted (`E2ECrypto` with TLS-bound key exchange and TOFU pinning). Video frames are sent as binary WebSocket messages with a 4-byte `H264` prefix.

## WSProtocol Actions

The protocol covers 60+ actions organized by domain:

- **Workspace** — create, start, stop, status, scan_repos
- **Stream** — start, stop, frame
- **Remote input** — tap, double_tap, long_press, scroll, drag, pinch, keyboard, button
- **Screenshot** — request, result
- **Terminal** — create, input, output, close, list
- **Claude Code** — create, message, output, complete, close, ask_user, user_response
- **Generic engine** — create, message, output, complete, close, ask_user, user_response
- **OpenClaw** — status, message, output, complete
- **Git** — checkpoint, diff, rollback, history, file_diff, branches, checkout, pull
- **File** — tree, read (with result variants)
- **Browser** — open_url, back, forward, refresh, viewport, tab management
- **HTTP proxy** — port detection, request/response forwarding
- **Dev server** — start, stop, status
- **MCP** — list, health_check (with result variants)
- **Engine status** — model, tokens, context monitoring
- **Sudo** — request, response, result
- **Agents** — detected, settings
- **UltraContext** — status, config
- **Relay** — machine_online, machine_offline, stream_frame
- **System** — auth, ping, pong, error

When adding new iOS↔macOS communication, always add a new `WSAction` case and handle it in both `DaemonManager` (macOS) and `ConnectionManager` listeners (iOS).

## AI Engines

Tarsy supports multiple AI coding agents, each running as a CLI process on the Mac:

- **Claude Code** (primary, dedicated `ClaudeCodeSession` with token tracking and interactive prompts)
- **Gemini CLI**
- **Codex CLI**
- **Aider**
- **Custom** (any CLI tool)

The user picks the engine per workspace. All engines conform to `AIEngineProtocol` (actor protocol with `start`, `sendMessage`, `respondToQuestion`, `terminate`). `AgentDetector` scans standard paths on startup to report available engines.

## Monetization

Freemium model via StoreKit 2 subscription (product ID: `tarsy_pro_monthly`):
- **Free:** 1 workspace, OpenClaw tab visible but Pro-gated (shows paywall)
- **Pro ($9/month):** unlimited workspaces, full OpenClaw access

Subscription status syncs between StoreKit and Supabase `profiles` table. Billing emails sent via `send-email` edge function on subscription state transitions.

## Build System

Both apps use **XcodeGen** (`project.yml` files). To regenerate Xcode projects:

```
cd TarsyiOS && xcodegen generate
cd TarsymacOS && xcodegen generate
```

TarsyShared is a standard Swift Package (SPM). Main external dependency: `supabase-swift` (>= 2.0).

Root `package.json` uses npm workspaces for `relay/` and `website/`:
```
npm run dev:relay    # Start relay dev server
npm run dev:website  # Start website dev server
```

Deployment targets: iOS 17.0, macOS 14.0. Swift 5.9.

## Design System

Tarsy uses a **warm, earthy, retro-70s aesthetic** — inspired by the Anthropic/Claude design language. Dark backgrounds with terracotta, amber, and moss green accents. All UI uses monospaced fonts.

The theme is defined in `TarsyiOS/Sources/Theme/TarsyTheme.swift`:

- **Backgrounds:** `#1a1a1a`, `#2a2a2a`, `#3a3a3a`
- **Text:** warm beige `#e8e0d4` (primary), `#a89e91` (secondary)
- **Accents:** amber `#d4a574`, terracotta `#c4704b`, moss `#7a8b6f`
- **Status:** running = moss, starting = amber, idle = gray, error = terracotta
- **Fonts:** monospaced throughout (`Font.system(.body, design: .monospaced)`)

When building new UI, always use `TarsyTheme` colors and fonts. Never use system defaults or blue tints. The feel should be warm, close, and inviting — not cold or corporate. The website and email templates also follow this palette.

## Rules

### Auth — Unified Ecosystem

Auth MUST be identical across iOS and macOS. Both platforms share `AuthManager` in TarsyShared. All three login methods must work on both platforms:

1. **Sign In with Apple**
2. **Sign In with GitHub (OAuth)**
3. **Email/Password**

When changing auth logic, always update BOTH platforms. Never add a login method to one side without the other. The user should be able to sign in on any device with the same account and method.

### Networking

- Prefer the existing `WSProtocol` packet system for new iOS↔macOS communication. Don't introduce alternative channels.
- When adding a new packet action, add the `WSAction` case, handle it in `DaemonManager` (macOS side), and add the appropriate listener in the iOS view/service that needs it.
- Binary data (video, screenshots) uses WebSocket binary frames, not text packets.
- The relay server forwards packets with minimal logic (auth, rate limiting, action allowlists). Business logic lives in the apps.

### Database

- Always use sequential migration files (`supabase/migrations/NNN_*.sql`).
- All tables must have RLS enabled with user-scoped policies (`user_id = auth.uid()`).
- When adding a new table, enable realtime if the iOS app needs live updates.

### General

- When modifying shared networking or models, test the impact on both platforms.
- Keep the design consistent — use `TarsyTheme` colors, monospaced fonts, and the warm earthy palette.
- `DaemonManager` is the macOS nerve center — any new macOS feature likely needs wiring there.
- `ConnectionManager` is the iOS nerve center for all WebSocket communication.
- Environment variables and secrets go in `.env` files (gitignored). Never commit API keys or credentials.
