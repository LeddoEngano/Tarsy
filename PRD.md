# Tarsy Windows + Web PRD

> **Purpose:** Complete implementation spec for Windows companion (C#) and Web client (Next.js).
> **Source of truth:** Generated from deep analysis of TarsymacOS, TarsyiOS, and TarsyShared codebases.
> **Status:** Each task has a checkbox. Check off as implemented.

## What Tarsy Is

Tarsy is a remote desktop + AI coding agent platform. It lets developers control their computer and run AI coding agents (Claude Code, Gemini CLI, Codex CLI, Aider, etc.) remotely. The core value: you can monitor, interact with, and steer AI agents working on your codebase from anywhere.

**Current state:** macOS companion + iOS client (production).
**This PRD:** Expand to Windows companion + Web client, making Tarsy truly cross-platform.

## Architecture Overview

```
                    ┌─────────────────────┐
                    │   Supabase Backend  │
                    │  (auth, DB, edge fn)│
                    └────────┬────────────┘
                             │
                    ┌────────▼────────┐
                    │  Relay Server   │
                    │  (Bun/Hono)     │
                    │  wss://fly.dev  │
                    └───┬─────────┬───┘
                        │         │
          ┌─────────────▼──┐  ┌───▼──────────────┐
          │ Companion Apps │  │  Client Apps      │
          │ (controlled    │  │  (controller)     │
          │  machine)      │  │                   │
          │                │  │  iOS (Swift) ✅    │
          │ macOS (Swift)✅│◄►│  Web (Next.js) 🔲 │
          │ Win (C#)    🔲 │  │                   │
          └────────────────┘  └───────────────────┘
```

**Target user:** Dev que só tem Windows e quer rodar AI agents no PC. Não tem iPhone/Mac. O web client é o único ponto de acesso dele ao Tarsy.

**Coexistence:** O iOS app continua como client principal para users Mac. O web client coexiste — serve Windows users e qualquer um que prefira browser. Ambos evoluem, mas não precisam ter paridade de features nativas (Live Activities, haptics, etc. ficam exclusivas do iOS).

**Two new projects:**
1. **TarsyWindows** — C# / WinUI 3 system tray app (companion on controlled PC)
2. **TarsyWeb** — Rotas dentro do `website/` existente (ex: `tarsy.co/app/dashboard`). Mesmo deploy, mesmo domínio, compartilha TarsyTheme CSS e Next.js config

## Critical Design Decisions

### Web client: Relay-only (no LAN)
The iOS app uses `Network.framework` for direct LAN connections with TOFU-pinned self-signed TLS certificates. **Browsers cannot accept self-signed certificates without user intervention.** The web client will connect **exclusively via relay** (`wss://tarsy-relay.fly.dev/ws`). This simplifies the client significantly. E2E encryption ensures the relay cannot read traffic.

### UAC on Windows: no remote prompt
On macOS, `SUDO_ASKPASS` redirects sudo prompts to the iOS app. Windows UAC **cannot be programmatically intercepted** — it's a secure desktop prompt. The Windows companion will handle elevation differently:
- Commands that need elevation are pre-validated against the whitelist
- The companion runs an optional elevated helper service (installed during onboarding)
- The client can request elevation, but the prompt appears on the Windows machine itself (user must have physical or RDP access for initial setup)
- For most dev tasks (npm, git, python, etc.), elevation is not needed

### Subscription sync: StoreKit ↔ Stripe
Users may subscribe on iOS (StoreKit) or Web (Stripe). Both update the same `profiles` table in Supabase. The source of truth is `profiles.is_pro` / `profiles.subscription_status`. StoreKit webhook and Stripe webhook both write to this table. The client reads from it — no platform-specific logic needed.

### Security hardening for web client
- Content Security Policy (CSP): strict, no inline scripts
- HSTS headers
- HttpOnly + Secure + SameSite=Strict cookies for auth
- Rate limiting on auth endpoints
- Input sanitization for all user-submitted content
- No localStorage for tokens (HttpOnly cookies only)

### Browser compatibility for voice (Web Speech API)
Web Speech API only works in Chrome and Edge. Firefox and Safari do not support it. The voice feature will show a "Chrome/Edge required" notice on unsupported browsers.

---

# PART 1: WINDOWS COMPANION (C#)

## W1. Project Setup & Architecture

- [ ] **W1.1** Create C# solution `TarsyWindows` (.NET 8, WinUI 3)
- [ ] **W1.2** System tray icon (NotifyIcon) with context menu (Start/Stop/Settings/Quit)
- [ ] **W1.3** Single-instance enforcement (named mutex)
- [ ] **W1.4** Startup on boot (registry: `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`)
- [ ] **W1.5** Auto-updater (check GitHub releases or custom endpoint)
- [ ] **W1.6** Installer (MSIX or Inno Setup)

## W2. Authentication & Machine Registration

- [ ] **W2.1** Supabase auth client (supabase-csharp or raw REST)
  - Email/password sign-in
  - GitHub OAuth (via WebView2 popup)
  - Apple Sign-In (via WebView2 popup)
  - Session persistence (token storage in DPAPI)
- [ ] **W2.2** Machine registration on startup
  - Hardware UUID: `WMIC csproduct get UUID` or `System.Management`
  - Hostname: `Environment.MachineName`
  - Local IP: `NetworkInterface.GetAllNetworkInterfaces()`
  - Model identifier: `Win32_ComputerSystem.Model`
  - Upsert to Supabase `machines` table (match by `hardware_uuid`)
- [ ] **W2.3** Machine secret management
  - Generate UUID secret on first run
  - Store in Windows Credential Manager (DPAPI)
  - Sync to Supabase `machine_tokens` table
- [ ] **W2.4** Heartbeat timer (30s interval)
  - Update `machines.status = "online"`, `last_seen_at = now()`
  - Check relay connection health, force reconnect if dead

## W3. WSProtocol Implementation

- [ ] **W3.1** `WSPacket` model
  ```csharp
  public record WSPacket {
      public string Id { get; init; } = Guid.NewGuid().ToString();
      public string Action { get; init; }
      public Dictionary<string, string>? Payload { get; init; }
      public DateTime Timestamp { get; init; } = DateTime.UtcNow;
  }
  ```
  - JSON serialization with ISO 8601 dates
  - Max packet size validation: 1 MB
- [ ] **W3.2** `WSAction` enum — all 143 action cases (copy from `WSProtocol.swift`)
- [ ] **W3.3** Packet dispatcher (`HandlePacket` switch on action → handler methods)
  - Mirror DaemonManager's 90+ case dispatch
  - Default case: send `.error` response

## W4. Networking — WebSocket Server (LAN)

- [ ] **W4.1** WebSocket server on port 8642
  - `System.Net.WebSockets` + `HttpListener` or Kestrel minimal API
  - Bind to all local interfaces
- [ ] **W4.2** TLS 1.3 with self-signed certificate
  - Generate RSA 2048-bit self-signed cert (`System.Security.Cryptography.X509Certificates`)
  - Store cert + private key in `%APPDATA%\Tarsy\tls\`
  - File permissions: ACL restrict to current user only
  - SHA256 fingerprint for TOFU pinning
- [ ] **W4.3** Authentication flow
  - 3-second auth timeout after connect
  - Client sends `auth` packet with `token` + `machineId`
  - Validate token via Supabase JWT verification
- [ ] **W4.4** Rate limiting
  - Auth failures: 3 per IP per 60s → 5-min ban
  - Message rate: 120 msg/sec per client (drop excess silently)
- [ ] **W4.5** Local network validation
  - Only accept connections from RFC 1918, loopback, CGNAT ranges
  - Reject public IPs

## W5. Networking — Relay Client

- [ ] **W5.1** WebSocket client to `wss://tarsy-relay.fly.dev/ws`
  - `ClientWebSocket` from `System.Net.WebSockets`
  - Auth: send `{"action":"auth","token":"...","role":"machine","machineSecret":"..."}`
  - 4 MB max message size
- [ ] **W5.2** Heartbeat ping every 30s
  - WebSocket native ping/pong
  - If no pong within 15s → reconnect
- [ ] **W5.3** Exponential backoff reconnection
  - Delay: `min(2^attempt, 60)` + random jitter `(0 ... min(delay*0.3, 10))`
  - Refresh Supabase token before each reconnect attempt
  - Reset counter on successful auth
- [ ] **W5.4** Message routing
  - Relay packets: encrypt with relay E2E key, wrap in `.e2eEncrypted` envelope
  - LAN packets: send plaintext (TLS protects channel)

## W6. E2E Encryption

- [ ] **W6.1** ECDH P256 key pair generation (`ECDiffieHellman` in .NET)
- [ ] **W6.2** Key exchange protocol
  - Send public key (base64) in auth packet
  - Receive remote public key + RSA-PSS SHA256 signature + TLS cert
  - Verify signature against cert public key
  - TOFU: save cert fingerprint (SHA256) on first connect
- [ ] **W6.3** Shared secret derivation
  - ECDH key agreement → raw shared secret
  - HKDF-SHA256 with salt `"tarsy-e2e-v1"`, output 32 bytes
- [ ] **W6.4** AES-GCM encrypt/decrypt
  - 256-bit key, 12-byte random nonce, 16-byte auth tag
  - Text: `encrypt(plaintext) → base64(nonce + ciphertext + tag)`
  - Binary: `encryptBinary(data) → nonce(12) + ciphertext + tag(16)`
- [ ] **W6.5** Separate E2E instances for LAN and Relay (two key pairs)

## W7. Screen Capture & Encoding

- [ ] **W7.1** Screen/window capture via `Windows.Graphics.Capture` API
  - `GraphicsCaptureItem` from window handle (HWND) or display
  - `Direct3D11CaptureFramePool` for frame delivery
  - Window enumeration: `EnumWindows` + `GetWindowText`
  - Permission: system picker dialog or programmatic (Windows 11+)
- [ ] **W7.2** H.264 hardware encoding via Media Foundation
  - `MFTEnumEx` to find H.264 encoder (prefer hardware: NVENC, AMD AMF, Intel QSV)
  - Fallback: software H.264 encoder (`MFT_CATEGORY_VIDEO_ENCODER`)
  - Profile: Main, real-time mode, no B-frames, no frame reordering
- [ ] **W7.3** Adaptive bitrate
  - Config: target bitrate from caller, min = target/5, max = target*3
  - Ramp up: after 10 successful frames + 2s cooldown → +25%
  - Ramp down: after 2 dropped frames + 2s cooldown → -25%
  - Relay mode: 1s adjust interval. LAN: 2s interval
- [ ] **W7.4** Encoding parameters by connection type
  - LAN: 30 FPS, scale 1.0, 6 Mbps
  - Relay: 24 FPS, scale 0.85, 3 Mbps
  - Keyframe interval: relay = fps*2 (2s), LAN = fps*3 (3s)
- [ ] **W7.5** Binary frame format (Annex B)
  - Byte 0: `0x01` (keyframe) or `0x00` (delta)
  - Keyframes: prepend SPS + PPS with `00 00 00 01` start codes
  - All NALs: convert AVCC (4-byte length) → Annex B (`00 00 00 01`)
  - WebSocket binary: `"H264"` prefix (4 bytes) + frame data
- [ ] **W7.6** Screenshot capture (JPEG)
  - Capture single frame → encode JPEG (quality 0.7)
  - Send as binary with `"SCRN"` prefix
- [ ] **W7.7** Client activity monitor
  - 120s inactivity timeout → auto-stop stream
  - Check every 10s

## W8. Remote Input Injection

- [ ] **W8.1** Mouse input via `SendInput` (Win32 API)
  - Tap: `MOUSEEVENTF_MOVE` → 10ms → `LEFTDOWN` → 30ms → `LEFTUP`
  - Double-tap: two click sequences with clickState tracking (20ms between)
  - Long-press: `RIGHTDOWN` → 30ms → `RIGHTUP` (context menu)
  - Drag: `LEFTDOWN` → 10 interpolated `MOVE` steps (10ms each) → `LEFTUP`
- [ ] **W8.2** Scroll input
  - Vertical: `MOUSEEVENTF_WHEEL` with delta = `-deltaY * 3 * WHEEL_DELTA`
  - Horizontal: `MOUSEEVENTF_HWHEEL` with delta = `-deltaX * 3 * WHEEL_DELTA`
- [ ] **W8.3** Keyboard input via `SendInput`
  - Regular chars: `KEYEVENTF_UNICODE` with UTF-16 code unit
  - Backspace: VK_BACK (0x08)
  - Enter: VK_RETURN (0x0D)
  - 3ms delay between characters
- [ ] **W8.4** Coordinate mapping
  - Relative (0-1) → absolute screen coordinates
  - `absoluteX = windowRect.Left + (windowRect.Width * relativeX)`
  - `absoluteY = windowRect.Top + (windowRect.Height * relativeY)`
  - Use `GetWindowRect` for window bounds
- [ ] **W8.5** Window focus management
  - `SetForegroundWindow(hwnd)` before input injection
  - Track focused state to avoid redundant calls

## W9. Terminal & Process Management

- [ ] **W9.1** ConPTY (Windows Pseudo Console) integration
  - `CreatePseudoConsole()` via P/Invoke to `kernel32.dll`
  - Create stdin/stdout pipes with `CreatePipe()`
  - Spawn `powershell.exe` or `cmd.exe` with `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`
  - Async read via `ReadFileEx()` or `Task.Run` + `ReadFile()`
- [ ] **W9.2** Multi-session support
  - Dictionary of `sessionId → ConPTYSession`
  - Each session: independent process + pipes + output handler
- [ ] **W9.3** PATH enrichment for Windows
  - Prepend to PATH (`;` separator):
    - `%USERPROFILE%\.local\bin`
    - `%USERPROFILE%\.bun\bin`
    - `%USERPROFILE%\.cargo\bin`
    - `%APPDATA%\nvm\*` (nvm-windows versions)
    - `%LOCALAPPDATA%\fnm\node-versions\*\installation`
    - `%USERPROFILE%\.volta\bin`
    - `%USERPROFILE%\go\bin`
    - `%APPDATA%\pnpm`
    - `%LOCALAPPDATA%\Programs\Python\*`
    - `%USERPROFILE%\miniconda3\Scripts`, `%USERPROFILE%\anaconda3\Scripts`
    - `%USERPROFILE%\.pyenv\pyenv-win\shims`
    - `%USERPROFILE%\.asdf\shims`
    - `%USERPROFILE%\.proto\shims`
    - `%LOCALAPPDATA%\mise\shims`
- [ ] **W9.4** Process signals
  - Interrupt (Ctrl+C): `GenerateConsoleCtrlEvent(CTRL_C_EVENT, processGroupId)`
  - Terminate: `TerminateProcess(handle, exitCode)`
  - Graceful shutdown: close stdin → wait 3s → force kill

## W10. AI Engine Orchestration

- [ ] **W10.1** `IAIEngine` interface (equivalent to AIEngineProtocol)
  ```csharp
  public interface IAIEngine {
      string Id { get; }
      AIEngineType EngineType { get; }
      string WorkspacePath { get; }
      event Action<string> OnOutput;
      event Action<string> OnComplete;
      event Action<string, string[]> OnAskUser;
      event Action<string, string, Dictionary<string, object>> OnPermissionRequest;
      Task Start();
      Task SendMessage(string message);
      Task RespondToQuestion(string answer);
      Task Interrupt();
      Task Terminate();
  }
  ```
- [ ] **W10.2** ClaudeCodeSession (C# implementation)
  - Find binary: check `%USERPROFILE%\.claude\bin\claude.exe`, `%APPDATA%\npm\claude.cmd`, `%LOCALAPPDATA%\Programs\claude\claude.exe`
  - Launch args: `["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]`
  - Optional: `--dangerously-skip-permissions` or `--permission-prompt-tool stdio`
  - Parse newline-delimited JSON from stdout
  - Token tracking: `input_tokens`, `output_tokens`, `contextWindow` from `result` events
  - Permission protocol: `control_request` → `control_response` JSON over stdin/stdout
  - AskUserQuestion: parse `questions` array, serialize, forward to client
- [ ] **W10.3** CodexSession
  - Find: `codex.exe` in PATH or `%LOCALAPPDATA%\Programs\Codex\`
  - Similar stdin/stdout JSON protocol
- [ ] **W10.4** GeminiSession
  - Find: `gemini.exe` in PATH
  - Image support: base64 encode images in message content
- [ ] **W10.5** GenericCLIEngine
  - Wrap any CLI tool with stdin/stdout pipes
  - Configurable command and args
- [ ] **W10.6** AgentDetector
  - Scan candidate paths for each engine type (Windows-specific paths):
    - Claude: `%USERPROFILE%\.claude\bin\`, `%APPDATA%\npm\`, `%LOCALAPPDATA%\Programs\`
    - Codex: `%LOCALAPPDATA%\Programs\Codex\`, `%APPDATA%\npm\`
    - Gemini: `%APPDATA%\npm\`, PATH lookup
    - Aider: `%USERPROFILE%\.local\bin\`, pip install location
    - Copilot: check `gh.exe` in PATH, verify `gh extension list` contains "copilot"
  - Fallback: `where.exe <binary>` (equivalent of `which`)
  - Version detection: run `<agent> --version` with 5s timeout
  - Broadcast `.agentsDetected` to clients on startup

## W11. Workspace Orchestration

- [ ] **W11.1** Git clone + setup
  - Execute `git.exe clone <url> <path>` (find git in PATH or `%ProgramFiles%\Git\bin\`)
  - Check for existing content before clone
- [ ] **W11.2** Stack detection (same logic, Windows paths)
  - Web: `package.json` + (`next.config.*` or `vite.config.*`)
  - Mobile: `package.json` + (`ios/` or `app.json`)
  - Backend: `requirements.txt`, `go.mod`, `Cargo.toml`
- [ ] **W11.3** Package manager detection
  - Lock file priority: `package-lock.json` → npm, `yarn.lock` → yarn, `pnpm-lock.yaml` → pnpm, `bun.lockb` → bun
  - Python: `requirements.txt` → pip, `Gemfile` → bundle
- [ ] **W11.4** Dev server command extraction from `package.json`
  - Parse `scripts.dev` or `scripts.start`
- [ ] **W11.5** Repository scanning
  - Scan directories: `%USERPROFILE%\Desktop`, `Documents`, `Projects`, `Developer`, `Code`, `repos`, `dev`, `work`, `src`
  - Skip: `node_modules`, `AppData`, `$Recycle.Bin`
  - Check for `.git\` directory (backslash on Windows)
  - Concurrent git metadata fetch (remote URL, current branch)

## W12. Git Operations

All operations execute `git.exe` with array-based arguments (no shell interpolation).

- [ ] **W12.1** `gitCheckpoint`: `git add -A` → `git commit -m "checkpoint: <msg> [ISO8601]" --allow-empty`
- [ ] **W12.2** `gitDiff`: `git status --porcelain` + `git diff --stat` + `git diff` (cap 50KB)
- [ ] **W12.3** `gitRollback`: validate target regex `^(HEAD(~\d+)?|[0-9a-fA-F]{7,40})$`, then `git reset --hard <target>`
- [ ] **W12.4** `gitHistory`: `git log --oneline --format=%H|||%s|||%ai|||%an -<limit>` (max 500)
- [ ] **W12.5** `gitFileDiff`: `git diff -U3 -- <file>`, fallback to `git diff --cached`, fallback to fake diff for new files (cap 100KB)
- [ ] **W12.6** `gitBranches`: current branch + `git branch --format=%(refname:short)` + remote branches
- [ ] **W12.7** `gitCheckout`: validate branch name (no `-` prefix), `git checkout <branch>`
- [ ] **W12.8** `gitPull`: `git pull`
- [ ] **W12.9** `gitStage`: `git add -- <files>` or `git add -A`
- [ ] **W12.10** `gitDiscard`: tracked → `git checkout -- <file>`, untracked → `git clean -fd -- <file>`, staged → `git reset HEAD -- <file>`

## W13. File Operations

- [ ] **W13.1** `fileTree`: recursive directory listing with depth tracking
  - `Directory.EnumerateFileSystemEntries()`
  - Skip: `.git`, `node_modules`, `.next`, `__pycache__`, `bin`, `obj`
  - Return: `{name, path, type, ext, depth}` as JSON array
- [ ] **W13.2** `fileRead`: read file contents with encoding detection (UTF-8 default)
  - Binary detection: check for null bytes
  - Return: `{success, file, content, language}`

## W14. Port & Dev Server Monitoring

- [ ] **W14.1** Port scanning
  - `Get-NetTCPConnection` via PowerShell or `netstat -ano` parsing
  - Map PID → process name via `Process.GetProcessById()`
  - Map PID → working directory via WMI `Win32_Process.CommandLine`
- [ ] **W14.2** Dev server start/stop
  - Allowed runners whitelist: `npm, pnpm, yarn, bun, npx, node, deno, python, python3, ruby, cargo, go, make, docker, gradle, dotnet, php, uvicorn, gunicorn`
  - Start: create ConPTY session, send command, watch for ready signals
  - Ready patterns: `ready on`, `listening on`, `localhost:`, `compiled successfully`, `vite`, `Local:`, `Network:`
  - Port extraction from output (regex, use last match)
  - Stop: send Ctrl+C → wait 500ms → terminate process tree
- [ ] **W14.3** Process tree termination
  - `taskkill /F /T /PID <pid>` or use Job Objects for process group management

## W15. Privilege Escalation (UAC)

> **Note:** Unlike macOS where `SUDO_ASKPASS` redirects prompts remotely, Windows UAC runs on a secure desktop and cannot be intercepted. Most dev commands (npm, git, pip, cargo) don't need elevation. For those that do, the companion uses a pre-installed elevated helper.

- [ ] **W15.1** Elevated helper service (installed during onboarding)
  - Windows Service running as SYSTEM or admin
  - Companion communicates via named pipe (authenticated, local only)
  - Only executes commands from the whitelist
  - User grants UAC consent ONCE during install (not remotely per-command)
- [ ] **W15.2** Command whitelist adaptation
  - Same categories: package managers, file permissions, process control, dev tools
  - Windows equivalents: `npm`, `pip`, `choco`, `scoop`, `winget`, `icacls`, `takeown`, `taskkill`
- [ ] **W15.3** Dangerous pattern detection (same: `;`, `&&`, `||`, `|`, `$(`, `` ` ``, `${`)
- [ ] **W15.4** Fallback: commands outside whitelist that need elevation are rejected with a message to the client explaining why

## W16. Auxiliary Services

- [ ] **W16.1** OpenClaw gateway (HTTP client to `localhost:18789`)
  - **Depends on:** OpenClaw binary being available for Windows (currently macOS-only)
  - If not available: report `openclawAvailable = false` to client, client hides OpenClaw tab
  - Health check endpoint
  - SSE streaming response parsing
- [ ] **W16.2** UltraContext sync
  - Output buffering: 3s inactivity flush, 16KB size limit
  - Session file watcher: `FileSystemWatcher` on `%USERPROFILE%\.claude\projects\**\*.jsonl`
- [ ] **W16.3** Push notification dispatch
  - Local: Windows Toast Notifications (`Windows.UI.Notifications.ToastNotification`)
  - Remote: insert into Supabase `push_notifications` table
- [ ] **W16.4** MCP health check
  - Scan for MCP server configs in agent directories
  - HTTP health check to each server
- [ ] **W16.5** Sleep prevention
  - `SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED)`
  - Release on shutdown

## W17. System Integration

- [ ] **W17.1** Sleep/wake detection
  - `SystemEvents.PowerModeChanged` event
  - On wake: re-acquire sleep prevention, update machine status, refresh token, reconnect relay
- [ ] **W17.2** Onboarding window (WinUI 3)
  - Step 1: Sign in (WebView2 for OAuth)
  - Step 2: Grant screen capture permission
  - Step 3: Pairing (show QR code / connection code)
- [ ] **W17.3** Token refresh timer (45 min interval)
  - Refresh Supabase auth token
  - Update relay client with new token

---

# PART 2: WEB CLIENT (Next.js)

## WB1. Project Setup

- [ ] **WB1.1** Extend existing `website/` project
  - Add `/app` route group for the web client (e.g., `website/app/(app)/dashboard/page.tsx`)
  - Landing page stays at `/`, web client lives under `/app/*`
  - Share existing TarsyTheme CSS, Next.js 16 config, and deploy pipeline
  - Add `@supabase/supabase-js` + `@supabase/ssr` dependencies
- [ ] **WB1.2** Auth pages
  - `/login` — Email/password, GitHub OAuth, Apple Sign-In (via Supabase Auth)
  - `/signup` — Registration
  - Session persistence: HttpOnly cookies (Supabase SSR helpers)
  - Middleware: protect `/app/*` routes; landing pages (`/`, `/privacy`, `/terms`, `/contact`) remain public
- [ ] **WB1.3** Design system (CSS variables matching TarsyTheme)
  ```css
  :root {
    --bg-primary: #0a0a0a;
    --bg-secondary: #111111;
    --bg-tertiary: #222222;
    --text-primary: #ededed;
    --text-secondary: #666666;
    --accent: #ffffff;
    --accent-medium: #888888;
    --accent-light: #b0b0b0;
    --status-running: #b0b0b0;
    --status-starting: #ffffff;
    --status-idle: #555555;
    --status-error: #888888;
    --font-mono: 'JetBrains Mono', 'SF Mono', monospace;
  }
  ```
- [ ] **WB1.4** Responsive layout (desktop-first, works on tablet)

## WB2. WebSocket Connection Manager

- [ ] **WB2.1** `ConnectionManager` class (TypeScript)
  - Relay-only: connect to `wss://tarsy-relay.fly.dev/ws` (no LAN — browsers can't accept self-signed certs)
  - Auth: send `{"action":"auth","token":"...","role":"client"}` as first message
  - Max message size: 4 MB
- [ ] **WB2.2** Packet send/receive
  - `sendPacket(packet: WSPacket)`: JSON serialize, E2E encrypt if ready
  - `onPacket(action, handler)`: listener registration system
  - Handle `.e2eEncrypted` envelope: decrypt, dispatch inner packet
- [ ] **WB2.3** Ping/pong keepalive (10s interval, 15s zombie timeout)
- [ ] **WB2.4** Auto-reconnect with exponential backoff
  - Refresh Supabase token before each attempt
- [ ] **WB2.5** Connection state (React context)
  - `isConnected`, `connectionMode` (lan/relay/disconnected), `latency`, `isReconnecting`

## WB3. E2E Encryption (Web Crypto API)

- [ ] **WB3.1** ECDH P256 key pair generation
  ```typescript
  const keyPair = await crypto.subtle.generateKey(
    { name: 'ECDH', namedCurve: 'P-256' },
    true, ['deriveKey', 'deriveBits']
  );
  ```
- [ ] **WB3.2** Key exchange: export public key (base64), import remote key
- [ ] **WB3.3** Shared secret derivation
  - `deriveBits` → HKDF-SHA256 with salt `"tarsy-e2e-v1"` → 256-bit AES-GCM key
- [ ] **WB3.4** AES-GCM encrypt/decrypt
  - 12-byte random IV, 16-byte tag
  - Text: `base64(iv + ciphertext + tag)`
  - Binary: `Uint8Array(iv + ciphertext + tag)`

## WB4. Dashboard

- [ ] **WB4.1** `/dashboard` page
  - Machine list with online/offline indicators
  - Machine picker dropdown (multi-machine support)
  - Supabase realtime subscription on `machines` table for live status
- [ ] **WB4.2** Workspace cards
  - Show: name, current branch, stack badge, unread count
  - Status-colored border (running/idle/error)
  - Click → navigate to `/workspace/[id]`
- [ ] **WB4.3** Active tasks panel
  - Supabase realtime on `agent_tasks` table
  - Status badges: running, waiting, completed, error
- [ ] **WB4.4** Action buttons
  - Quick Dispatch: modal to send task to engine
  - New Workspace: modal form
  - Active Sessions: list past sessions from UltraContext

## WB5. Stream Viewer (WebCodecs)

- [ ] **WB5.1** H.264 decoder via WebCodecs API
  ```typescript
  const decoder = new VideoDecoder({
    output: (frame: VideoFrame) => renderFrame(frame),
    error: (e) => console.error(e),
  });
  decoder.configure({
    codec: 'avc1.42E01E', // H.264 Main profile
    optimizeForLatency: true,
  });
  ```
- [ ] **WB5.2** Binary frame parser
  - Strip `"H264"` prefix (4 bytes)
  - Read frame type byte: `0x01` = key, `0x00` = delta
  - Parse NAL units (find `00 00 00 01` start codes)
  - Extract SPS/PPS from keyframes for decoder config
- [ ] **WB5.3** Canvas renderer
  - `<canvas>` element with `drawImage(videoFrame)` or `OffscreenCanvas` for perf
  - FPS counter overlay (optional)
- [ ] **WB5.4** Fullscreen toggle
- [ ] **WB5.5** Stream start on workspace entry
  - Send `.streamStart` packet with quality params
  - Stop on navigate away: `.streamStop`

## WB6. Remote Input (DOM Events → WSPackets)

- [ ] **WB6.1** Click handler on canvas
  - `mousedown` → calculate relative position (0-1 range) → send `.remoteTap`
  - Double-click: `dblclick` → `.remoteDoubleTap`
  - Right-click: `contextmenu` (prevent default) → `.remoteLongPress`
- [ ] **WB6.2** Scroll handler
  - `wheel` event → `.remoteScroll` with `deltaX`, `deltaY` (divide by canvas dimensions for relative)
  - Throttle to 30Hz max
- [ ] **WB6.3** Drag handler
  - `mousedown` → `mousemove` (with button held) → `mouseup`
  - Send `.remoteDrag` with `fromX, fromY, toX, toY`
- [ ] **WB6.4** Keyboard capture
  - Focus invisible `<input>` on canvas click
  - `input` event → `.remoteKeyboard` with text
  - `keydown` for special keys: Backspace (`\u0008`), Enter (`\n`), arrow keys
  - Prevent browser shortcuts from interfering (but allow Ctrl+C/V for clipboard)

## WB7. AI Chat Interface

- [ ] **WB7.1** `/workspace/[id]` page — tabbed layout
  - Tab bar: one tab per AI engine + terminal + OpenClaw (if available)
  - Tab state isolation: per-tab `isThinking`, `activity`, `activityLines`, `options`, `questions`, `engineModel`, `contextPercent`
- [ ] **WB7.2** Chat message list
  - Virtual scrolling for performance (react-virtuoso or similar)
  - User messages (right-aligned, dark bg)
  - Assistant messages (left-aligned, lighter bg) with markdown rendering
  - Thinking indicator (animated dots)
  - Tool use activity line (current tool name + description)
- [ ] **WB7.3** Message input
  - Textarea with auto-resize
  - Send on Enter (Shift+Enter for newline)
  - Send `.engineMessage` packet with message content
  - @ mention autocomplete for file paths (request `.fileTree`, cache results)
- [ ] **WB7.4** Chat history pagination
  - Load last 50 messages from UltraContext on mount
  - "Load older" button → paginate via UltraContext API
- [ ] **WB7.5** Interactive options
  - Render clickable buttons when `options` array received
  - Numbered list style
  - On click → send `.engineUserResponse`
- [ ] **WB7.6** Interactive questions (paginated)
  - Multi-step question cards (1 of N pagination)
  - Single-select: numbered radio-style options
  - Multi-select: checkbox-style options
  - Custom text input field below options
  - Submit → serialize answers → `.engineUserResponse`
- [ ] **WB7.7** Permission prompts
  - Modal dialog: "Allow [tool_name]?" with tool details
  - Allow / Deny buttons
  - "Always allow this tool" checkbox
  - Send `.engineUserResponse` with behavior: allow/deny
- [ ] **WB7.8** Context & model display
  - Show engine model name in tab header
  - Context usage progress bar (% filled)
  - Token counts (input/output) in status bar
- [ ] **WB7.9** Session management
  - Create engine session: `.engineCreate`
  - Close session: `.engineClose`
  - Resume session: load from UltraContext by session ID

## WB8. Terminal View

- [ ] **WB8.1** Terminal emulator component
  - Use xterm.js for full terminal rendering
  - Connect to ConPTY/PTY via `.terminalCreate` → `.terminalOutput` → `.terminalInput`
- [ ] **WB8.2** Terminal input
  - xterm.js `onData` → `.terminalInput` packet
  - Ctrl+C → `.terminalInterrupt`
- [ ] **WB8.3** Multi-terminal tabs

## WB9. Git Safety Net

- [ ] **WB9.1** `/workspace/[id]/git` panel (3 tabs)
- [ ] **WB9.2** Changes tab
  - Request `.gitDiff` → parse porcelain status
  - File list with status badges (M/A/D)
  - Stage/unstage/discard buttons per file
  - "Stage All" / "Discard All" bulk actions
- [ ] **WB9.3** History tab
  - Request `.gitHistory` → commit list
  - Click commit → view diff
  - Rollback button with confirmation dialog
- [ ] **WB9.4** Branches tab
  - Request `.gitBranches` → branch list with current highlighted
  - Click branch → `.gitCheckout` with confirmation
- [ ] **WB9.5** Checkpoint button (git commit)
  - Auto-generated message: `"checkpoint: <msg> [ISO8601]"`
- [ ] **WB9.6** File diff viewer
  - Request `.gitFileDiff` → render unified diff
  - Syntax-highlighted diff component (react-diff-viewer or custom)

## WB10. File Explorer

- [ ] **WB10.1** Tree view sidebar
  - Request `.fileTree` → render expandable tree
  - Directory expand/collapse (track in `Set<string>`)
  - File icons by extension (color-coded)
  - Indentation by depth
- [ ] **WB10.2** File search (filter by name)
- [ ] **WB10.3** File preview
  - Click file → `.fileRead` → show content in modal/panel
  - Syntax highlighting (Prism.js or highlight.js)

## WB11. Web Browser / Dev Server

- [ ] **WB11.1** Embedded iframe (for dev server preview)
  - Proxy approach: requests go through relay via `.proxyRequest` / `.proxyResponse`
  - Or: Service Worker that intercepts fetch and routes through WebSocket
- [ ] **WB11.2** Port detection
  - Request `.proxyDetectPorts` → show port picker dropdown
- [ ] **WB11.3** Dev server start/stop
  - `.devServerStart` with command + path
  - `.devServerStop`
  - Status indicator (starting/running/stopped)
- [ ] **WB11.4** URL bar for navigation

## WB12. Workspace Management

- [ ] **WB12.1** New workspace modal
  - Scan repos: `.workspaceScanRepos` → show suggestions
  - Manual: name, path, repo URL, stack selection
  - Create: Supabase insert + `.workspaceCreate`
- [ ] **WB12.2** Workspace settings modal
  - Edit: name, path, stack, dev server command
  - Delete workspace
- [ ] **WB12.3** AI Context editor
  - Textarea for system prompt
  - Save: `.workspaceUpdate` with `aiContext`
- [ ] **WB12.4** Machine pairing
  - Primary flow: manual code pairing (XXXX-XXXX-XXXX) — user copies code from Windows companion onboarding screen
  - The Windows companion shows the pairing code in its tray/onboarding window; the web client has an input field to enter it
  - QR code scanning is deprioritized (target user is Windows-only, unlikely to have a phone to scan)
  - Claim via PairingService (`claimMachineWithCode`)

## WB13. Voice Input (Web Speech API)

> **Browser support:** Chrome and Edge only. Firefox and Safari do not support Web Speech API. Show "Requires Chrome or Edge" on unsupported browsers.

- [ ] **WB13.1** `SpeechRecognition` or `webkitSpeechRecognition`
  - `continuous = true`, `interimResults = true`
  - Language selection (9 languages: en-US, pt-BR, es-ES, fr-FR, de-DE, it-IT, ja-JP, ko-KR, zh-CN)
  - Feature detection: `if (!('SpeechRecognition' in window || 'webkitSpeechRecognition' in window))` → show notice
- [ ] **WB13.2** Microphone button in chat input
  - Toggle recording on/off
  - Live transcription overlay
- [ ] **WB13.3** Voice to-do tracking (same as iOS)

## WB14. Subscription & Payments

- [ ] **WB14.1** Stripe integration (web payments)
  - Stripe Checkout for Pro Monthly ($14.99) and Pro Annual ($119.99)
  - Webhook handler (Supabase edge function): update `profiles.is_pro`, `subscription_status`, `subscription_end_date`
  - Customer portal for management/cancellation
- [ ] **WB14.2** Cross-platform subscription sync
  - Source of truth: `profiles` table in Supabase
  - StoreKit webhook (iOS) writes to `profiles` → web reads from it
  - Stripe webhook (web) writes to `profiles` → iOS reads from it
  - User who subscribes on iOS sees Pro status on web, and vice-versa
  - Edge case: if user has BOTH StoreKit and Stripe active, prefer the one with later `subscription_end_date`
- [ ] **WB14.3** Paywall component
  - Feature comparison (Free vs Pro)
  - CTA buttons linking to Stripe Checkout
  - If user already has active StoreKit subscription: show "You're already Pro (subscribed via iOS)"
- [ ] **WB14.4** Pro feature gating
  - OpenClaw tab: show paywall if not Pro
  - Workspace limit: 1 for free, unlimited for Pro

## WB15. Notifications

- [ ] **WB15.1** Web Push notifications
  - Service Worker registration
  - `Notification.requestPermission()`
  - Subscribe: save push subscription to Supabase `push_tokens`
  - Display: task completion, agent questions, PR creation
- [ ] **WB15.2** In-app notification banners
  - Toast notifications for events while app is open
  - Unread badge count per workspace

## WB16. Profile & Settings

- [ ] **WB16.1** `/settings` page
  - Profile: name, email, avatar
  - API key management (encrypted, stored in Supabase)
  - Voice language picker
  - Agent permission config (safe/dangerous per engine)
- [ ] **WB16.2** Account deletion (with confirmation)
- [ ] **WB16.3** Sudo password dialog
  - Modal: secure password input
  - Send `.sudoResponse` with E2E-encrypted password

## WB17. MCP Store

- [ ] **WB17.1** `/mcp` page
  - Request `.mcpList` → render MCP cards
  - Health indicators (green/red dot)
  - Install/uninstall actions
  - Group by supported engine

## WB18. Developer Tools

- [ ] **WB18.1** `/devtools` panel
  - API client: HTTP request builder (method, URL, headers, body)
  - Process/port viewer: `.processList`, `.portsList`
  - Resource monitor: `.systemResources` → CPU, memory, disk charts
  - Text tools: base64 encode/decode, URL encode/decode, JSON format

## WB19. Feedback

- [ ] **WB19.1** Feedback form modal
  - Type selector: Bug, Feature Request, General
  - Description textarea
  - Screenshot attachment (file input)
  - Submit to backend

## WB20. Security Hardening

- [ ] **WB20.1** Content Security Policy (CSP)
  - `default-src 'self'`; `connect-src 'self' wss://tarsy-relay.fly.dev https://*.supabase.co`
  - No `unsafe-inline`, no `unsafe-eval`
  - Nonce-based script loading if needed
- [ ] **WB20.2** Auth security
  - HttpOnly + Secure + SameSite=Strict cookies
  - CSRF token on all mutations
  - Rate limiting on login endpoint (5 attempts per IP per minute)
  - Account lockout after 10 failed attempts
- [ ] **WB20.3** HSTS + security headers
  - `Strict-Transport-Security: max-age=31536000; includeSubDomains`
  - `X-Content-Type-Options: nosniff`
  - `X-Frame-Options: DENY`
  - `Referrer-Policy: strict-origin-when-cross-origin`
- [ ] **WB20.4** Input sanitization
  - Sanitize all user input before rendering (DOMPurify for markdown)
  - Validate WSPacket payloads on receive (reject malformed)
- [ ] **WB20.5** WebSocket connection security
  - Verify origin header on relay connection
  - Token expiry check before each reconnect
  - Clear all crypto keys on logout / tab close

---

# PART 3: SHARED / INFRASTRUCTURE

## S1. Relay Server Updates

- [ ] **S1.1** Verify relay handles Windows companion connections (role: "machine")
  - Same auth flow, same action allowlists
  - Windows `machineSecret` validation
- [ ] **S1.2** Verify binary frame forwarding works for Windows H.264 frames

## S2. Supabase Updates

- [ ] **S2.1** `machines` table: verify `model_identifier` works for Windows device names
- [ ] **S2.2** `push_tokens` table: add `platform` column if not exists (`ios`, `web`, `windows`)
- [ ] **S2.3** Stripe webhook edge function for web payments
- [ ] **S2.4** Web push edge function (Web Push API via `web-push` npm package)

## S3. Website Updates

- [ ] **S3.1** Landing page: add "Available on macOS, Windows, and Web" messaging
- [ ] **S3.2** Download page: macOS DMG + Windows installer links
- [ ] **S3.3** "Open Web App" button linking to webapp

---

# Priority Order

> **Strategy:** Web client first (can test against existing macOS companion immediately), Windows companion in parallel. The web client unblocks Windows users via their browser while the companion is being built.

**Phase 1 — Web Client Foundation**
WB1, WB2, WB3, WB20, S2
- Auth, relay connection, E2E crypto, security hardening, Supabase schema updates
- **Testable with:** existing macOS companion + relay

**Phase 2 — Web Client Core**
WB4, WB5, WB6, WB7, WB8
- Dashboard, stream viewer (WebCodecs), remote input, AI chat, terminal (xterm.js)
- **Testable with:** existing macOS companion — full workflow end-to-end

**Phase 3 — Web Client Complete**
WB9, WB10, WB11, WB12, WB13, WB14, WB15, WB16
- Git, file explorer, dev server browser, workspace management, voice, payments, notifications, settings
- **Milestone:** Web client is feature-complete against macOS companion

**Phase 4 — Windows Companion Foundation**
W1, W2, W3, W4, W5, W6
- Project setup, auth, WSProtocol, networking (LAN server + relay client), E2E crypto
- **Testable with:** web client connects to Windows companion via relay

**Phase 5 — Windows Companion Core**
W7, W8, W9, W10, W11, W12, W13
- Screen capture, remote input, ConPTY terminals, AI engines, workspace, git, files
- **Milestone:** Core remote desktop + AI agent loop works on Windows

**Phase 6 — Windows Companion Complete**
W14, W15, W16, W17
- Port monitoring, UAC elevation, auxiliary services, system integration

**Phase 7 — Polish & Ship**
WB17, WB18, WB19, S1, S3
- MCP store, devtools, feedback, relay verification, website updates

---

*Generated on 2026-04-07 from deep analysis of TarsymacOS (34 files), TarsyiOS (51 files), TarsyShared (23 files), 143 WSActions. 166 tasks total.*
