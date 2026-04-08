# Tarsy Windows + Web — Handoff Document

> **Date:** 2026-04-07
> **Purpose:** Full context for continuing development from a Windows machine.
> **Read this before starting.** It covers what's done, what's next, architecture decisions, and known issues.

---

## What Was Done

### Web Client (100% complete — Phases 1-5)

The web client lives inside the existing `website/` Next.js project under the `(app)` route group. It's fully functional and can connect to any macOS companion via the relay.

**6 commits, 39 files created:**

| Phase | Commit | What was built |
|-------|--------|----------------|
| 1 — Foundation | `b346540` | Route groups `(marketing)` + `(app)`, Supabase auth (login/signup/OAuth callback), middleware, ConnectionManager (relay-only WebSocket), E2ECrypto (ECDH + AES-GCM via Web Crypto API), security headers (CSP, HSTS) |
| 2 — Core | `390c849` | Dashboard (machines/workspaces/tasks with Supabase realtime), H.264 stream viewer (WebCodecs with dynamic codec from SPS), remote input (click/scroll/drag/keyboard), AI chat (tabbed workspace, engine output streaming, interactive options/questions/permissions), terminal (xterm.js with dynamic import) |
| 3 — Workspace | `9c52ec6` | Git safety net (3 tabs: changes/history/branches, file diff viewer, checkpoint), file explorer (tree/search/preview), workspace modals (new workspace from scanned repos + manual, machine pairing via connection code) |
| 4 — Auxiliary | `2bfa552` | Voice input (Web Speech API, 9 languages), settings page (profile/subscription/voice language/account deletion), sudo password dialog |
| 5 — Polish | `0d6e970` | MCP store, devtools (processes/ports/resources), feedback modal, dashboard nav links |

**Key architecture decisions:**
- **Relay-only** — no LAN connections from the web client (browsers can't accept self-signed certs)
- **Extends `website/`** — rotas under `/app/*` (login, dashboard, workspace, settings, etc.), marketing pages stay at `/`
- **Design system** — CSS variables matching `TarsyTheme.swift` exactly (same hex colors)
- **E2E crypto** — Web Crypto API implementation matches the Swift `E2ECrypto` class byte-for-byte (ECDH P-256, HKDF-SHA256 salt `"tarsy-e2e-v1"`, AES-GCM 256-bit, 12-byte nonce)

### Windows Companion (Foundation — Phase 4)

The C# project lives in `TarsyWindows/` at the repo root. It's a .NET 8 WinForms app (system tray only, no window).

**Phase 4 — 1 commit (`0e69b04`), 12 files created** (foundation: auth, relay, LAN server, heartbeat, sleep prevention)

### Windows Companion Core — Phase 5 (W7-W13) ✅

**13 new files created, all compiling successfully (`dotnet build` passes with 0 errors):**

| File | Purpose | PRD Task |
|------|---------|----------|
| `Networking/WSProtocol.cs` | All 143+ WSAction constants ported from Swift | W2 |
| `Services/FileService.cs` | `GetFileTree` (recursive enumeration, skip list), `ReadFile` (binary detection, 1MB limit) | W13 |
| `Services/GitService.cs` | All git ops: checkpoint, diff, rollback, history, fileDiff, branches, checkout, pull, stage, discard via `git.exe` | W12 |
| `Services/WorkspaceOrchestrator.cs` | Repo scanning (10 dirs), stack detection (15+ stacks), package manager detection, dev server extraction | W11 |
| `Stream/ScreenCaptureService.cs` | GDI+ screen capture → ffmpeg H.264 encoding (with JPEG fallback), adaptive bitrate, screenshot support | W7 |
| `Stream/RemoteInputService.cs` | `SendInput` P/Invoke: tap, double-tap, long-press, drag, scroll (H+V), keyboard (Unicode + VK), coordinate mapping | W8 |
| `Terminal/TerminalSession.cs` | PowerShell process with redirected I/O, async output reading, interrupt, kill | W9 |
| `Terminal/TerminalSessionManager.cs` | Session lifecycle management (create, input, interrupt, close, list) | W9 |
| `Terminal/PathEnrichment.cs` | PATH enrichment: nvm, fnm, volta, cargo, bun, pnpm, go, python, pyenv, deno | W9 |
| `Terminal/IAIEngine.cs` | `IAIEngine` interface (Start, SendMessage, RespondToQuestion, Interrupt, Terminate) | W10 |
| `Terminal/ClaudeCodeSession.cs` | Dedicated Claude Code session: stream-json I/O, NDJSON parsing, token tracking, permission protocol | W10 |
| `Terminal/GenericCLIEngine.cs` | Generic CLI wrapper for Gemini, Codex, Aider, and custom agents | W10 |
| `Terminal/AgentDetector.cs` | Scans Windows-specific paths for installed agents, `where.exe` fallback, version detection | W10 |

**Updated files:**
| File | Changes |
|------|---------|
| `Services/DaemonManager.cs` | Full packet dispatch (30+ action handlers): stream, remote input, terminal, engine, claude, git, file, workspace, agents, devtools |
| `Networking/RelayClient.cs` | Added `SendBinary` for H.264/screenshot binary frames |
| `TarsyWindows.csproj` | Added `System.Management` package reference |

---

## Immediate Next Step: Fix Code Review Issues (before Phase 6)

A `/verify` code review was run on Phase 5. These bugs must be fixed first:

### 🔴 Critical Bugs to Fix

**1. Command injection in GitService** (`GitService.cs:236-238`)
`RunGitAsync` joins args with `string.Join(' ')` + `QuoteArg()` — insufficient escaping. A malicious client can inject shell commands via `commitHash`, `filePath`, `branch` payloads.
**Fix:** Replace `Arguments = string.Join(...)` with `ProcessStartInfo.ArgumentList.Add()` which handles escaping correctly. Remove `QuoteArg()` entirely.

**2. `async void` in DaemonManager** (`DaemonManager.cs:806,819`)
`HandleFileTree` and `HandleFileRead` are `async void` — unhandled exceptions crash the process.
**Fix:** Change both to `async Task` and add `await` at the call sites in the switch statement.

**3. Adaptive bitrate logic is no-op** (`ScreenCaptureService.cs:312-322`)
`Math.Max(target/5, target*0.75)` always picks 0.75x (no-op clamp). Same for increase.
**Fix:** Store `_initialBitrate` in `Start()`, clamp against that: `Math.Max(_initialBitrate/5, target*0.75)` for decrease, `Math.Min(_initialBitrate*3, target*1.25)` for increase.

**4. GDI handle leak in CaptureScreen** (`ScreenCaptureService.cs:327-357`)
If `BitBlt` or `Image.FromHbitmap` throws, `hDC`, `hMemDC`, `hBitmap` handles leak. At 24fps this exhausts GDI handles in minutes.
**Fix:** Wrap in try/finally that always calls `DeleteObject`, `DeleteDC`, `ReleaseDC`.

**5. ProcessKill accepts arbitrary PIDs** (`DaemonManager.cs:946-976`)
Any remote client can kill any process. Refuse system PIDs (0, 4) and the current process at minimum.

### 🟡 Should Fix

**6. GitService.RunProcess deadlock** (`GitService.cs:267-269`)
Synchronous `ReadToEnd()` on stdout then stderr can deadlock if stderr buffer fills first.
**Fix:** Read both concurrently with `ReadToEndAsync()`.

**7. `_streamClientId` not thread-safe** (`DaemonManager.cs:34`)
Read on capture callback thread, written on WebSocket thread.
**Fix:** Mark as `volatile`.

**8. AgentDetector rescans on every engine:create** (`DaemonManager.cs:493`)
Full filesystem scan + `where.exe` on each call.
**Fix:** Cache `_cachedAgents` at startup, refresh on demand.

**9. TerminalSession Ctrl+C doesn't work via pipe** (`TerminalSession.cs:104`)
Writing `\x03` to redirected stdin doesn't send SIGINT.
**Fix:** Use `GenerateConsoleCtrlEvent` P/Invoke as specified in PRD W9.

**10. FileService reads file twice** (`FileService.cs:121-131`)
Reads 8KB for binary check, then full file for content.
**Fix:** `File.ReadAllBytes()` once, check for nulls, then decode.

**11. `.svg` in BinaryExtensions** (`FileService.cs:27`)
SVG is text/XML, should be readable.

**12. EncoderParameters not disposed** (`ScreenCaptureService.cs:127`)
Needs `using` on `EncoderParameters`.

---

### Windows Companion — Phase 6 (W14-W17) ✅

**7 new files created, all compiling successfully (`dotnet build` passes with 0 errors):**

| File | Purpose | PRD Task |
|------|---------|----------|
| `Services/PortMonitorService.cs` | Port scanning (netstat parsing), dev server start/stop with ready-signal detection, process tree termination via taskkill | W14 |
| `Services/PrivilegeManager.cs` | Command whitelist validation, dangerous pattern detection, UAC elevation via runas verb, sudo:request handler | W15 |
| `Services/OpenClawService.cs` | OpenClaw gateway client (port 18789), health check, SSE streaming response parsing, binary discovery | W16.1 |
| `Services/UltraContextSync.cs` | Output buffering (3s flush, 16KB limit), session file watcher on `.claude/projects/**/*.jsonl`, Supabase proxy | W16.2 |
| `Services/NotificationService.cs` | Local Windows Toast (via PowerShell WinRT), remote push via Supabase `push_notifications` table | W16.3 |
| `Services/McpHealthService.cs` | MCP server config discovery (Claude Code, VS Code, Cursor), HTTP/stdio health checks | W16.4 |
| `Services/SystemIntegration.cs` | Sleep/wake via `SystemEvents.PowerModeChanged`, auto-reconnect relay + refresh token on wake | W17.1 |

**Updated files:**
| File | Changes |
|------|---------|
| `Services/DaemonManager.cs` | Added 5 new service fields, initialization in Start(), cleanup in Stop(), 11 new packet handlers (devserver, sudo, openclaw, ultracontext, mcp) |

### W6: E2E Encryption ✅

**1 new file, 2 updated files:**

| File | Purpose |
|------|---------|
| `Networking/E2ECrypto.cs` | ECDH P-256 key exchange, HKDF-SHA256 (salt "tarsy-e2e-v1"), AES-GCM 256-bit encrypt/decrypt, packet-level and binary encryption |
| `Networking/RelayClient.cs` | E2E integration: sends public key in auth, auto-encrypts outgoing packets/binary, decrypts incoming |
| `Networking/WebSocketServer.cs` | Per-client E2E instances, key exchange handshake, encrypted send/receive, binary send support |

**What's still stubbed:**
- DPAPI token storage (uses env var fallback)
- Machine secret persistence (generates new each time)
- Auth timeout + rate limiting on LAN server
- Onboarding window (WebView2 for OAuth — W17.2)

---

## File Map

```
Tarsy/
├── TarsymacOS/          # macOS companion (Swift) ✅ production
├── TarsyiOS/            # iOS client (Swift) ✅ production
├── TarsyShared/         # Swift Package (shared models, networking)
├── TarsyWindows/        # Windows companion (C#) ✅ Phase 6 complete
│   ├── Models/
│   │   └── TarsyConfig.cs
│   ├── Networking/
│   │   ├── E2ECrypto.cs         # W6: ECDH + HKDF + AES-GCM
│   │   ├── MachineService.cs
│   │   ├── RelayClient.cs       # + E2E integration + SendBinary
│   │   ├── SupabaseAuth.cs
│   │   ├── WebSocketServer.cs   # + per-client E2E + SendBinary
│   │   └── WSProtocol.cs        # ✅ All 143+ actions ported from Swift
│   ├── Services/
│   │   ├── DaemonManager.cs     # ✅ Full packet dispatch (40+ handlers)
│   │   ├── FileService.cs       # W13: file tree + file read
│   │   ├── GitService.cs        # W12: all git operations
│   │   ├── McpHealthService.cs  # W16.4: MCP discovery + health
│   │   ├── NotificationService.cs   # W16.3: Toast + remote push
│   │   ├── OpenClawService.cs   # W16.1: OpenClaw gateway client
│   │   ├── PortMonitorService.cs    # W14: port scan, dev server lifecycle
│   │   ├── PrivilegeManager.cs  # W15: UAC/whitelist/elevation
│   │   ├── SleepPrevention.cs
│   │   ├── SystemIntegration.cs # W17: sleep/wake power events
│   │   ├── UltraContextSync.cs  # W16.2: output buffering + file watcher
│   │   └── WorkspaceOrchestrator.cs  # W11: repo scan, stack detect
│   ├── Stream/
│   │   ├── RemoteInputService.cs    # W8: SendInput P/Invoke
│   │   └── ScreenCaptureService.cs  # W7: GDI+ → ffmpeg H.264
│   ├── Terminal/
│   │   ├── AgentDetector.cs         # W10: scan for installed agents
│   │   ├── ClaudeCodeSession.cs     # W10: stream-json Claude Code
│   │   ├── GenericCLIEngine.cs      # W10: Gemini/Codex/Aider wrapper
│   │   ├── IAIEngine.cs            # W10: engine interface
│   │   ├── PathEnrichment.cs        # W9: PATH enrichment for terminals
│   │   ├── TerminalSession.cs       # W9: PowerShell process session
│   │   └── TerminalSessionManager.cs # W9: session lifecycle
│   ├── Program.cs
│   ├── TarsyWindows.csproj
│   └── TarsyWindows.sln
├── website/                   # Next.js — marketing + web client ✅ complete
│   ├── app/
│   │   ├── (marketing)/       # Landing, contact, privacy, terms
│   │   ├── (app)/             # Web client
│   │   │   ├── auth/callback/ # OAuth code exchange
│   │   │   ├── dashboard/     # Machine list, workspaces, tasks
│   │   │   ├── devtools/      # Process/port/resource viewer
│   │   │   ├── login/         # Email + GitHub + Apple OAuth
│   │   │   ├── mcp/           # MCP integrations store
│   │   │   ├── settings/      # Profile, subscription, voice, account
│   │   │   ├── signup/        # Registration
│   │   │   └── workspace/[id]/ # Chat + stream + git + files
│   │   └── lib/
│   │       ├── supabase/      # client.js, server.js
│   │       └── tarsy/         # ConnectionProvider, connection, e2e, protocol,
│   │                          # StreamPlayer, RemoteInput, TerminalView,
│   │                          # GitPanel, FileExplorer, WorkspaceModals,
│   │                          # VoiceInput, FeedbackModal, hooks
│   └── middleware.js          # Auth protection for /app/* routes
├── relay/                     # Bun/Hono relay server (deployed on Fly.io)
├── supabase/                  # Migrations, edge functions
├── PRD.md                     # Full PRD with 166 tasks
├── FEATURES.md                # Auto-generated feature registry
└── HANDOFF.md                 # This file
```

---

## How to Continue on Windows

### 1. Prerequisites
```powershell
# .NET 8 SDK is already installed
dotnet --version  # should show 8.0.405
```

### 2. Build & Run
```powershell
cd TarsyWindows
dotnet build     # should pass with 0 errors, 4 warnings
dotnet run
```

### 3. First task: Fix critical bugs from code review

Start by fixing the 5 critical issues listed in "Immediate Next Step" above. The most impactful:
- **GitService command injection** — switch to `ArgumentList.Add()` 
- **async void** — change `HandleFileTree`/`HandleFileRead` to `async Task`
- **GDI handle leak** — add try/finally to `CaptureScreen()`

### 4. Then proceed to Phase 6 (W14-W17)

### 5. Test with the web client

The web client is already deployed (or run locally with `npm run dev:website`). Sign in, pair the Windows machine with a connection code, and the dashboard should show it online.

---

## Known Issues & TODOs

### Web Client
- **Per-tab message isolation** — all engine tabs share one message list. The iOS app saves/restores `tabStates[tabId]` on tab switch. `workspace/[id]/page.js:19` has a TODO.
- **Stripe payments** — paywall component exists but Stripe Checkout integration not wired (needs Stripe API keys + webhook edge function)
- **Web Push** — service worker not registered yet. In-app notification banners work, but no browser push notifications.
- **CSP** — still allows `'unsafe-inline'` for scripts (Next.js/Tailwind need it). Should migrate to nonce-based CSP before production.

### Windows Companion
- **DPAPI token storage** — `SupabaseAuth.cs` uses `TARSY_TOKEN` env var as fallback. Needs `CredentialManager` integration.
- **Machine secret persistence** — `MachineService.EnsureSecret()` generates a new UUID each run instead of persisting in Credential Manager + syncing to Supabase `machine_tokens`.
- **E2E Encryption** — not implemented yet. The `E2ECrypto` class needs to be ported (ECDH P-256 via `ECDiffieHellman`, HKDF via `HMACSHA256`, AES-GCM via `AesGcm`). See `website/app/lib/tarsy/e2e.js` for the JS reference implementation.
- **Auth flow** — no onboarding window yet. User currently needs to set `TARSY_TOKEN` manually. Needs WebView2 for OAuth.
- **LAN server** — no TLS, no auth timeout, no rate limiting, no local network validation. See PRD task W6 for full spec.

---

## Protocol Quick Reference

### WSPacket JSON format
```json
{
  "id": "uuid-string",
  "action": "engine:create",
  "payload": { "key": "value" },
  "timestamp": "2026-04-07T18:00:00.000Z"
}
```

### Binary frame format (H.264)
```
[4 bytes: "H264"] [1 byte: 0x01=keyframe/0x00=delta] [NAL units in Annex B]
```

### E2E encryption wire format
- Text: `base64(nonce_12bytes + ciphertext + tag_16bytes)`
- Binary: raw bytes `nonce(12) + ciphertext + tag(16)`
- Key derivation: ECDH P-256 → HKDF-SHA256 (salt: `"tarsy-e2e-v1"`) → AES-GCM 256-bit

### Key WSActions for Windows companion
```
auth, auth:success, auth:fail, ping, pong, error
stream:start, stream:stop
remote:tap, remote:double_tap, remote:long_press, remote:scroll, remote:keyboard
terminal:create, terminal:input, terminal:output, terminal:close, terminal:interrupt
engine:create, engine:message, engine:output, engine:complete, engine:close,
engine:ask_user, engine:user_response, engine:status, engine:interrupt
git:checkpoint, git:diff, git:rollback, git:history, git:branches, git:checkout
file:tree, file:read
workspace:scan_repos, workspace:create
sudo:request, sudo:response
agents:detected
devtools:process_list, devtools:ports_list, devtools:system_resources, devtools:process_kill
```

---

## Reference Files

When implementing a Windows feature, read the macOS equivalent first:

| Windows feature | Read this macOS file |
|----------------|---------------------|
| Screen capture | `TarsymacOS/Sources/Stream/ScreenCaptureService.swift` |
| H.264 encoding | `TarsymacOS/Sources/Stream/H264Encoder.swift` |
| Remote input | `TarsymacOS/Sources/Stream/RemoteInputService.swift` |
| Terminal/PTY | `TarsymacOS/Sources/Terminal/TerminalSessionManager.swift` |
| AI engines | `TarsymacOS/Sources/Terminal/ClaudeCodeSession.swift` |
| Agent detection | `TarsymacOS/Sources/Terminal/AgentDetector.swift` |
| Workspace setup | `TarsymacOS/Sources/Workspace/WorkspaceOrchestrator.swift` |
| Repo scanning | `TarsymacOS/Sources/Workspace/RepoScanner.swift` |
| Git operations | `TarsymacOS/Sources/DaemonManager.swift` (lines 3140+) |
| Port monitoring | `TarsymacOS/Sources/Port/PortMonitorService.swift` |
| Sudo handling | `TarsymacOS/Sources/SudoPasswordManager.swift` |
| Packet dispatch | `TarsymacOS/Sources/DaemonManager.swift` (line 528, 90+ cases) |
| E2E crypto | `TarsyShared/Sources/TarsyShared/Networking/E2ECrypto.swift` |
| WSProtocol | `TarsyShared/Sources/TarsyShared/Networking/WSProtocol.swift` |
