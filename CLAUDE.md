# Tarsy

Tarsy is a remote desktop + AI coding agent platform for the Apple ecosystem. It lets developers control their Mac and run AI coding agents (Claude Code, Gemini CLI, Codex CLI, Aider) remotely from their iPhone. The core value proposition: you can monitor, interact with, and steer AI agents working on your codebase from anywhere.

**Status:** MVP / private beta.

## Architecture

The project is a monorepo with three main components:

### TarsyShared (Swift Package)

Shared library consumed by both apps. Contains:

- **AuthManager** — unified auth (Apple, GitHub OAuth, email/password)
- **Networking** — `ConnectionManager` (WebSocket client), `WSProtocol` (packet definitions)
- **SupabaseClient** — Supabase integration for auth and data
- **Models** — `Workspace`, `Machine`, `ChatMessage`, `AIEngineType`
- **Services** — `WorkspaceService`, `MachineService`, `ChatService`

### TarsymacOS (XcodeGen project)

Menu bar app (LSUIElement) that runs on the Mac being controlled. Responsibilities:

- **Screen capture** — `ScreenCaptureService` captures the screen, `MJPEGStreamServer` streams it
- **Remote input** — `RemoteInputService` receives touch/keyboard events from iOS and injects them
- **AI engines** — `TerminalSessionManager` + `ClaudeCodeSession` + `GenericCLIEngine` run AI agents as child processes
- **Workspace orchestration** — `WorkspaceOrchestrator` manages workspace lifecycle, `RepoScanner` discovers git repos
- **Networking** — `RelayClient` connects to the relay server, `WebSocketServer` for LAN, `TailscaleManager` for Tailscale discovery
- **Other** — `DaemonManager`, `OpenClawService`, `PushNotificationService`

### TarsyiOS (XcodeGen project)

iPhone/iPad app that connects to the Mac. Responsibilities:

- **Stream player** — `StreamPlayerView` + `InteractiveStreamView` display the Mac screen with touch interaction
- **AI chat** — `WorkspaceView` is the main workspace UI with chat, terminal output, and interactive options
- **Dashboard** — `DashboardView` lists machines and workspaces
- **Workspace management** — `NewWorkspaceView`, `WorkspaceSettingsView`, `AIContextEditorView`
- **MCP integrations** — `MCPStoreView` lists MCP servers configured on the Mac with health status
- **Web browser** — `WebBrowserView` + `TarsyProxySchemeHandler` for in-app browsing
- **Subscription** — `SubscriptionManager` + `PaywallView` (StoreKit)
- **Other** — `FileExplorerView`, `GitSafetyNetView`, `VoiceInputManager`, `SplashView`, `LoginView`

### Website (Next.js)

Landing page and marketing site at `website/`. Not part of the app build pipeline.

## Connectivity

The iOS app connects to the macOS app via two methods:

1. **Relay server** — default method, works over the internet (relay hosted on Fly.io)
2. **LAN direct** — optional, connects directly when both devices are on the same network

Communication uses WebSocket with a custom packet protocol (`WSProtocol`).

## AI Engines

Tarsy supports multiple AI coding agents, each running as a CLI process on the Mac:

- **Claude Code** (primary, with dedicated `ClaudeCodeSession`)
- **Gemini CLI**
- **Codex CLI**
- **Aider**
- **Custom** (any CLI tool)

The user picks the engine per workspace. All engines implement `AIEngineProtocol` or use `GenericCLIEngine`.

## Monetization

Freemium model via StoreKit subscription:
- **Free:** 1 workspace with all features
- **Pro ($9/month):** unlimited workspaces

## Build System

Both apps use **XcodeGen** (`project.yml` files). To regenerate Xcode projects:

```
cd TarsyiOS && xcodegen generate
cd TarsymacOS && xcodegen generate
```

TarsyShared is a standard Swift Package (SPM). Main external dependency: `supabase-swift`.

Deployment targets: iOS 17.0, macOS 14.0. Swift 5.9.

## Design System

Tarsy uses a **warm, earthy, retro-70s aesthetic** — inspired by the Anthropic/Claude design language. Dark backgrounds with terracotta, amber, and moss green accents. All UI uses monospaced fonts.

The theme is defined in `TarsyiOS/Sources/Theme/TarsyTheme.swift`:

- **Backgrounds:** `#1a1a1a`, `#2a2a2a`, `#3a3a3a`
- **Text:** warm beige `#e8e0d4` (primary), `#a89e91` (secondary)
- **Accents:** amber `#d4a574`, terracotta `#c4704b`, moss `#7a8b6f`
- **Fonts:** monospaced throughout (`Font.system(.body, design: .monospaced)`)

When building new UI, always use `TarsyTheme` colors and fonts. Never use system defaults or blue tints. The feel should be warm, close, and inviting — not cold or corporate.

## Rules

### Auth — Unified Ecosystem

Auth MUST be identical across iOS and macOS. Both platforms share `AuthManager` in TarsyShared. All three login methods must work on both platforms:

1. **Sign In with Apple**
2. **Sign In with GitHub (OAuth)**
3. **Email/Password**

When changing auth logic, always update BOTH platforms. Never add a login method to one side without the other. The user should be able to sign in on any device with the same account and method.

### General

- When modifying shared networking or models, test the impact on both platforms.
- Prefer the existing `WSProtocol` packet system for new iOS<->macOS communication. Don't introduce alternative channels.
- Keep the design consistent — use `TarsyTheme` colors, monospaced fonts, and the warm earthy palette.
