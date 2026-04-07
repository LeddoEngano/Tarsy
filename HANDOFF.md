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

**1 commit (`0e69b04`), 12 files created:**

| File | Purpose |
|------|---------|
| `TarsyWindows.sln` | Solution file |
| `TarsyWindows.csproj` | .NET 8, `net8.0-windows`, WinForms, single-file publish |
| `Program.cs` | Entry point: single-instance mutex, NotifyIcon system tray, starts DaemonManager |
| `Services/DaemonManager.cs` | Central orchestrator: auth → register machine → start LAN server → connect relay → heartbeat → token refresh → sleep prevention |
| `Services/SleepPrevention.cs` | `SetThreadExecutionState` P/Invoke |
| `Networking/WSProtocol.cs` | `WSPacket` record + `WSAction` constants (stub: only 6 actions, needs all 143) |
| `Networking/SupabaseAuth.cs` | Email/password sign-in via Supabase REST API, token refresh |
| `Networking/MachineService.cs` | Hardware UUID (WMI), hostname, local IP, machine registration, heartbeat |
| `Networking/RelayClient.cs` | `ClientWebSocket` to `wss://tarsy-relay.fly.dev/ws`, auth, receive loop, exponential backoff reconnect |
| `Networking/WebSocketServer.cs` | `HttpListener` on port 8642, `ConcurrentDictionary` of connected clients |
| `Models/TarsyConfig.cs` | Constants: Supabase URL, anon key, relay URL, port |
| `.gitignore` | bin/, obj/, .vs/ |

**What works:** The project structure compiles and runs on Windows with `dotnet run`. It will:
1. Sign in with a Supabase token (from env var `TARSY_TOKEN` or manual sign-in)
2. Register the machine in Supabase
3. Start a LAN WebSocket server on port 8642
4. Connect to the relay as role `"machine"`
5. Respond to ping/pong
6. Send heartbeat every 30s
7. Prevent sleep

**What's stubbed (marked with TODO):**
- DPAPI token storage (uses env var fallback)
- Machine secret persistence (generates new each time)
- Full WSAction enum (only 6 of 143 actions)
- Auth timeout + rate limiting on LAN server
- E2E encryption integration
- Onboarding window (WebView2 for OAuth)
- All packet handlers beyond ping/pong

---

## What's Next — Phases 5-6

### Phase 5: Windows Companion Core (PRD tasks W7-W13)

These need Win32 APIs and should be built/tested on Windows.

#### W7. Screen Capture & Encoding
- **Capture:** `Windows.Graphics.Capture` API (`GraphicsCaptureItem` from HWND)
- **Encode:** Media Foundation H.264 encoder (prefer hardware: NVENC/AMF/QSV, fallback software)
- **Frame format:** Must match macOS exactly — byte 0 = keyframe flag (0x01/0x00), then Annex B NAL units with `00 00 00 01` start codes. SPS/PPS prepended on keyframes
- **Adaptive bitrate:** min=target/5, max=target*3, ramp up +25% after 10 frames, ramp down -25% after 2 drops
- **Params:** LAN: 30fps/6Mbps/scale 1.0. Relay: 24fps/3Mbps/scale 0.85
- **Binary frame prefix:** `"H264"` (4 bytes) + frame data → sent as WebSocket binary message
- **Screenshot:** capture single frame → JPEG quality 0.7 → `"SCRN"` prefix

#### W8. Remote Input Injection
- **Mouse:** `SendInput` with `MOUSEEVENTF_*` flags
  - Tap: MOVE → 10ms → LEFTDOWN → 30ms → LEFTUP
  - Double-tap: two clicks with 20ms between
  - Long-press: RIGHTDOWN → 30ms → RIGHTUP
  - Drag: LEFTDOWN → 10 interpolated MOVE steps (10ms each) → LEFTUP
  - Scroll: `MOUSEEVENTF_WHEEL` (vertical) + `MOUSEEVENTF_HWHEEL` (horizontal), multiplied by 3
- **Keyboard:** `KEYEVENTF_UNICODE` with UTF-16 code unit, 3ms between chars. Backspace=VK_BACK, Enter=VK_RETURN
- **Coordinates:** relative (0-1) → absolute: `x = windowRect.Left + (width * relX)`
- **Focus:** `SetForegroundWindow(hwnd)` before input

#### W9. Terminal & Process Management
- **ConPTY:** `CreatePseudoConsole()` via P/Invoke to `kernel32.dll`
  - Create stdin/stdout pipes with `CreatePipe()`
  - Spawn `powershell.exe` with `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`
  - Async read with `Task.Run` + `ReadFile()`
- **PATH enrichment** (prepend with `;` separator):
  - `%USERPROFILE%\.local\bin`, `%USERPROFILE%\.bun\bin`, `%USERPROFILE%\.cargo\bin`
  - `%APPDATA%\nvm\*`, `%LOCALAPPDATA%\fnm\node-versions\*\installation`
  - `%USERPROFILE%\.volta\bin`, `%USERPROFILE%\go\bin`, `%APPDATA%\pnpm`
  - `%LOCALAPPDATA%\Programs\Python\*`, `%USERPROFILE%\.pyenv\pyenv-win\shims`
- **Signals:** Ctrl+C = `GenerateConsoleCtrlEvent(CTRL_C_EVENT)`, kill = `TerminateProcess()`

#### W10. AI Engine Orchestration
- **Interface:** `IAIEngine` (Start, SendMessage, RespondToQuestion, Interrupt, Terminate)
- **ClaudeCodeSession:** find `claude.exe` in `%USERPROFILE%\.claude\bin\`, `%APPDATA%\npm\`, etc. Launch with `["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]`. Parse NDJSON from stdout. Token tracking. Permission protocol (`control_request`/`control_response` over stdin).
- **AgentDetector:** scan Windows-specific paths for each engine. Fallback: `where.exe <binary>`. Version: `<agent> --version` with 5s timeout.
- **Engines:** CodexSession, GeminiSession, GenericCLIEngine — same patterns.

#### W11. Workspace Orchestration
- Git clone, stack detection (same file markers), package manager detection (same lock files), dev server command extraction from `package.json`
- **Repo scanning:** `%USERPROFILE%\Desktop`, `Documents`, `Projects`, `Developer`, `Code`, `repos`, `dev`, `work`, `src`

#### W12. Git Operations
- All execute `git.exe` with array-based arguments (find via PATH or `%ProgramFiles%\Git\bin\`)
- Same commands as macOS: checkpoint, diff, rollback, history, fileDiff, branches, checkout, pull, stage, discard

#### W13. File Operations
- `fileTree`: `Directory.EnumerateFileSystemEntries()`, skip `.git`, `node_modules`, etc.
- `fileRead`: UTF-8 read with binary detection (null bytes)

### Phase 6: Windows Companion Complete (PRD tasks W14-W17)

#### W14. Port & Dev Server Monitoring
- Port scanning: `netstat -ano` or `Get-NetTCPConnection`, map PID → process
- Dev server start/stop with ConPTY, ready signal detection, port extraction
- Process tree termination: `taskkill /F /T /PID`

#### W15. Privilege Escalation (UAC)
- Elevated helper service installed during onboarding
- Named pipe communication (authenticated, local only)
- Command whitelist: `npm`, `pip`, `choco`, `scoop`, `winget`, `icacls`, `taskkill`

#### W16. Auxiliary Services
- OpenClaw gateway client (port 18789)
- UltraContext sync (output buffering, session file watcher on `%USERPROFILE%\.claude\projects\**\*.jsonl`)
- Windows Toast Notifications
- MCP health check

#### W17. System Integration
- Sleep/wake: `SystemEvents.PowerModeChanged`
- Onboarding window: WebView2 for OAuth sign-in + QR/code display
- Token refresh timer (45 min)

---

## File Map

```
Tarsy/
├── TarsymacOS/          # macOS companion (Swift) ✅ production
├── TarsyiOS/            # iOS client (Swift) ✅ production
├── TarsyShared/         # Swift Package (shared models, networking)
├── TarsyWindows/        # Windows companion (C#) 🔲 Phase 4 done
│   ├── Models/
│   │   └── TarsyConfig.cs
│   ├── Networking/
│   │   ├── MachineService.cs
│   │   ├── RelayClient.cs
│   │   ├── SupabaseAuth.cs
│   │   ├── WebSocketServer.cs
│   │   └── WSProtocol.cs      # ⚠️ Only 6 of 143 actions — needs full enum
│   ├── Services/
│   │   ├── DaemonManager.cs   # Central orchestrator — add handlers here
│   │   └── SleepPrevention.cs
│   ├── Stream/                # Empty — W7 screen capture goes here
│   ├── Terminal/              # Empty — W9 ConPTY goes here
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
# Install .NET 8 SDK
winget install Microsoft.DotNet.SDK.8

# Verify
dotnet --version
```

### 2. Build & Run
```powershell
cd TarsyWindows
dotnet build
dotnet run
```

### 3. First task: Complete WSProtocol.cs

The WSAction class only has 6 constants. Copy all 143 from `TarsyShared/Sources/TarsyShared/Networking/WSProtocol.swift` — each `case foo = "bar:baz"` becomes `public const string Foo = "bar:baz";`.

### 4. Add packet handlers to DaemonManager.cs

The `HandlePacket` method has a TODO list of all actions to implement. Start with terminal (W9) since it's the simplest to test end-to-end with the web client:

```csharp
case WSAction.TerminalCreate:
    // Create ConPTY session, return sessionId
    break;
case WSAction.TerminalInput:
    // Write to ConPTY stdin
    break;
```

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
