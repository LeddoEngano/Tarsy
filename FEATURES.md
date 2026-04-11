# Tarsy Feature Registry

> **Auto-generated** by `scripts/generate-features.sh`
> **Purpose:** Source of truth for feature parity across all platforms.
> **Do not edit manually** — re-run the script to update.

## Platform Tags

| Tag | Meaning |
|-----|---------|
| `[macOS]` | Implemented in TarsymacOS (companion) |
| `[iOS]` | Implemented in TarsyiOS (client) |
| `[shared]` | Implemented in TarsyShared |
| `[windows]` | Planned: Windows companion (C#) |
| `[web]` | Planned: Web client (Next.js) |

---

## 1. Shared Protocol (TarsyShared)

Cross-platform foundation. Any new platform must implement these.

### WSProtocol Actions

```

agentSettings
agentSettingsUpdate
agentsDetected
auth
authFail
authSuccess
browserBack
browserDesktopViewport
browserForward
browserMobileViewport
browserOpenUrl
browserRefresh
browserTabClose
browserTabList
browserTabListResult
browserTabSwitch
claudeAskUser
claudeClose
claudeComplete
claudeCreate
claudeMessage
claudeOutput
claudeUserResponse
devServerStart
devServerStatus
devServerStop
e2eEncrypted
e2eKeyExchange
e2eKeyExchangeResponse
engineAskUser
engineClose
engineComplete
engineCreate
engineError
engineInterrupt
engineMessage
engineOutput
engineStatus
engineUserResponse
error
fileRead
fileReadResult
fileTree
fileTreeResult
gitBranches
gitBranchesResult
gitCheckout
gitCheckoutResult
gitCheckpoint
gitCheckpointResult
gitDiff
gitDiffResult
gitDiscard
gitDiscardResult
gitFileDiff
gitFileDiffResult
gitHistory
gitHistoryResult
gitPull
gitPullResult
gitRollback
gitRollbackResult
gitStage
gitStageResult
httpRequest
httpResponse
mcpHealthCheck
mcpHealthResult
mcpList
mcpListResult
openclawComplete
openclawMessage
openclawOutput
openclawStatus
payloadTooLarge
permissionsStatus
permissionsStatusRequest
ping
pong
portsList
portsListResult
processKill
processKillResult
processList
processListResult
proxyDetectPorts
proxyDetectPortsResult
proxyRequest
proxyResponse
relayMachineOffline
relayMachineOnline
relayNoClients
relayStreamFrame
remoteButton
remoteDoubleTap
remoteDrag
remoteKeyboard
remoteLongPress
remotePinch
remotePinchEnd
remotePinchStart
remoteScroll
remoteScrollEnd
remoteScrollStart
remoteTap
repoAnalysis
repoAnalyze
screenshotRequest
screenshotResult
securityFingerprintUpdate
securityRotateResult
securityRotateSecret
slashCommandsDetected
slashCommandsRequest
streamFrame
streamStart
streamStop
sudoRequest
sudoResponse
sudoResult
systemDialogClickButton
systemDialogDetected
systemDialogDismissed
systemResources
systemResourcesResult
terminalClose
terminalComplete
terminalCompleteResult
terminalCreate
terminalInput
terminalInterrupt
terminalList
terminalOutput
terminalPromptReady
ultracontextStatus
wizardExecute
wizardGhDetected
wizardResponse
wizardResult
wizardStart
workspaceCreate
workspaceList
workspaceScanRepos
workspaceScanResult
workspaceStart
workspaceStatus
workspaceStop
workspaceUpdate
```

**Total: 149 actions**

### Data Models

- `AgentPermissionConfig` `[shared]`
- `AgentTask` `[shared]`
- `ChatMessage` `[shared]`
- `Machine` `[shared]`
- `Profile` `[shared]`
- `ProjectWizardConfig` `[shared]`
- `Workspace` `[shared]`
- `AIEngineType` `[shared]`
- `AgentToolType` `[shared]`
- `MachineStatus` `[shared]`
- `MessageRole` `[shared]`
- `PermissionMode` `[shared]`
- `TaskStatus` `[shared]`
- `WorkspaceStack` `[shared]`
- `WorkspaceStatus` `[shared]`
- `WorkspaceType` `[shared]`

### AI Engine Types

- `aider` `[shared]`
- `amp` `[shared]`
- `claude` `[shared]`
- `cline` `[shared]`
- `codex` `[shared]`
- `copilot` `[shared]`
- `cursor` `[shared]`
- `custom` `[shared]`
- `gemini` `[shared]`
- `windsurf` `[shared]`

### Shared Services

- `AgentTaskService` `[shared]`
- `AuthManager` `[shared]`
- `ChatService` `[shared]`
- `ConnectionManager` `[shared]`
- `MachineService` `[shared]`
- `NotificationBadgeService` `[shared]`
- `PairingService` `[shared]`
- `ProfileService` `[shared]`
- `UltraContextClient` `[shared]`
- `WorkspaceService` `[shared]`

---

## 2. Companion App Features (macOS → Windows)

Features running on the controlled machine. The Windows companion must reimplement these.

### 2.1 Screen Capture & Encoding

- Screen/window capture \`[macOS]\` \`[windows]\`
- Window enumeration and filtering \`[macOS]\` \`[windows]\`
- Screenshot capture (JPEG) \`[macOS]\` \`[windows]\`
- Capture permission management \`[macOS]\` \`[windows]\`
- H.264/HEVC hardware encoding \`[macOS]\` \`[windows]\`
- Adaptive bitrate (300kbps–6Mbps) \`[macOS]\` \`[windows]\`
- Dynamic FPS adjustment \`[macOS]\` \`[windows]\`
- Keyframe generation \`[macOS]\` \`[windows]\`
- Network backpressure handling \`[macOS]\` \`[windows]\`

### 2.2 Remote Input

- Mouse tap/double-tap/long-press \`[macOS]\` \`[windows]\`
- Scroll gestures \`[macOS]\` \`[windows]\`
- Drag operations \`[macOS]\` \`[windows]\`
- Keyboard/text input \`[macOS]\` \`[windows]\`
- Pinch/zoom gestures \`[macOS]\` \`[windows]\`
- Device buttons (home, lock, rotate) \`[macOS]\`
- iOS Simulator support (simctl) \`[macOS]\`
- Coordinate mapping \`[macOS]\` \`[windows]\`

### 2.3 Terminal & Process Management

- PTY session creation/management \`[macOS]\` \`[windows]\`
- Multi-session support \`[macOS]\` \`[windows]\`
- Shell PATH enrichment (nvm, fnm, asdf, cargo) \`[macOS]\` \`[windows]\`
- Process lifecycle (interrupt, terminate) \`[macOS]\` \`[windows]\`

### 2.4 AI Engine Orchestration

- AIEngineProtocol (start, sendMessage, respondToQuestion, interrupt, terminate) \`[macOS]\` \`[windows]\`
- ClaudeCodeSession (dedicated subprocess, token tracking, permission protocol) \`[macOS]\` \`[windows]\`
- CodexSession (GitHub Copilot) \`[macOS]\` \`[windows]\`
- GeminiSession (Google Gemini, image support) \`[macOS]\` \`[windows]\`
- GenericCLIEngine (wrap any CLI tool) \`[macOS]\` \`[windows]\`
- AgentDetector (scan installed AI binaries) \`[macOS]\` \`[windows]\`

### 2.5 Networking (Companion Side)

- LAN WebSocket server (port 8642, TLS 1.3) \`[macOS]\` \`[windows]\`
- Self-signed certificate generation \`[macOS]\` \`[windows]\`
- Client auth + rate limiting (120 msg/sec) \`[macOS]\` \`[windows]\`
- Relay client (wss://tarsy-relay.fly.dev/ws) \`[macOS]\` \`[windows]\`
- Exponential backoff reconnection \`[macOS]\` \`[windows]\`
- Token refresh on reconnect \`[macOS]\` \`[windows]\`
- E2E encryption (ECDH + AES-GCM) \`[shared]\`

### 2.6 Workspace Orchestration

- Git clone + project setup \`[macOS]\` \`[windows]\`
- Stack detection (web, mobile, backend) \`[macOS]\` \`[windows]\`
- Dependency installation detection \`[macOS]\` \`[windows]\`
- Dev server command extraction \`[macOS]\` \`[windows]\`
- Repository scanning (~10 standard directories) \`[macOS]\` \`[windows]\`

### 2.7 Privilege Escalation

- Sudo password caching (60s TTL) \`[macOS]\`
- Command whitelist (word-boundary matching) \`[macOS]\`
- Dangerous pattern detection \`[macOS]\`
- SUDO_ASKPASS wrapper \`[macOS]\`
- UAC elevation equivalent \`[windows]\`

### 2.8 Port & Dev Server Monitoring

- Dev server process monitoring \`[macOS]\` \`[windows]\`
- Port detection and conflict resolution \`[macOS]\` \`[windows]\`
- Ready signal detection \`[macOS]\` \`[windows]\`
- Process group termination \`[macOS]\` \`[windows]\`

### 2.9 Git Operations (Server Side)

- git checkpoint (commit) \`[macOS]\` \`[windows]\`
- git diff (working dir + file-level) \`[macOS]\` \`[windows]\`
- git rollback (reset --hard) \`[macOS]\` \`[windows]\`
- git history (log) \`[macOS]\` \`[windows]\`
- git branches (list + checkout) \`[macOS]\` \`[windows]\`
- git pull \`[macOS]\` \`[windows]\`
- git stage / discard \`[macOS]\` \`[windows]\`

### 2.10 File Operations (Server Side)

- File tree enumeration \`[macOS]\` \`[windows]\`
- File read \`[macOS]\` \`[windows]\`

### 2.11 System Integration

- Sleep prevention (IOKit / SetThreadExecutionState) \`[macOS]\` \`[windows]\`
- Machine heartbeat (30s status update) \`[macOS]\` \`[windows]\`
- Hardware UUID detection \`[macOS]\` \`[windows]\`
- Menu bar / system tray app \`[macOS]\` \`[windows]\`
- Onboarding window \`[macOS]\` \`[windows]\`

### 2.12 Auxiliary Services

- OpenClaw local LLM gateway (port 18789, SSE) \`[macOS]\` \`[windows]\`
- UltraContext daemon (session sync, output buffering) \`[macOS]\` \`[windows]\`
- Push notification dispatch (local + remote) \`[macOS]\` \`[windows]\`
- Session file watcher (Claude Code .jsonl) \`[macOS]\` \`[windows]\`
- MCP health check \`[macOS]\` \`[windows]\`

---

## 3. Client App Features (iOS → Web)

Features used to control the companion. The web client must reimplement these.

### 3.1 Authentication

- Sign In with Apple \`[iOS]\` \`[web]\`
- Sign In with GitHub (OAuth) \`[iOS]\` \`[web]\`
- Email/Password auth \`[iOS]\` \`[web]\`
- Session persistence \`[iOS]\` \`[web]\`

### 3.2 Dashboard

- Machine list (online/offline status) \`[iOS]\` \`[web]\`
- Machine picker (multi-Mac support) \`[iOS]\` \`[web]\`
- Workspace cards (branch, stack, unread count) \`[iOS]\` \`[web]\`
- Active tasks display \`[iOS]\` \`[web]\`
- Quick Dispatch button \`[iOS]\` \`[web]\`
- Active Sessions button \`[iOS]\` \`[web]\`
- New Workspace button \`[iOS]\` \`[web]\`

### 3.3 Stream Viewer

- H.264 video player (hardware decode / WebCodecs) \`[iOS]\` \`[web]\`
- FPS monitoring \`[iOS]\` \`[web]\`
- Fullscreen mode \`[iOS]\` \`[web]\`
- Auto-start on workspace entry \`[iOS]\` \`[web]\`

### 3.4 Remote Input (Client Side)

- Touch/click input overlay \`[iOS]\` \`[web]\`
- Keyboard capture \`[iOS]\` \`[web]\`
- Scroll gesture forwarding \`[iOS]\` \`[web]\`
- Pinch/zoom gesture forwarding \`[iOS]\`
- Drag gesture forwarding \`[iOS]\` \`[web]\`

### 3.5 AI Chat & Interaction

- Multi-tab workspace (per-engine chat) \`[iOS]\` \`[web]\`
- Message input with send \`[iOS]\` \`[web]\`
- Thinking indicator (animated) \`[iOS]\` \`[web]\`
- Tool use activity display \`[iOS]\` \`[web]\`
- Context window usage (%) \`[iOS]\` \`[web]\`
- Engine model display \`[iOS]\` \`[web]\`
- Interactive options (clickable buttons) \`[iOS]\` \`[web]\`
- Interactive questions (multi-select cards) \`[iOS]\` \`[web]\`
- Chat history pagination (load older) \`[iOS]\` \`[web]\`
- Session persistence (UltraContext) \`[iOS]\` \`[web]\`
- Import/resume previous sessions \`[iOS]\` \`[web]\`
- Sudo password prompt \`[iOS]\` \`[web]\`

### 3.6 Voice Input

- Speech-to-text transcription \`[iOS]\` \`[web]\`
- Multi-language support (9 languages) \`[iOS]\` \`[web]\`
- Live transcription overlay \`[iOS]\` \`[web]\`
- Voice to-do tracking \`[iOS]\` \`[web]\`

### 3.7 Workspace Management

- Create workspace (manual + scanned repos) \`[iOS]\` \`[web]\`
- Workspace settings (name, path, stack, dev cmd) \`[iOS]\` \`[web]\`
- AI context editor (system prompt templates) \`[iOS]\` \`[web]\`
- QR code pairing \`[iOS]\` \`[web]\`
- Manual code pairing \`[iOS]\` \`[web]\`

### 3.8 Git Safety Net

- Changes tab (modified/added/deleted files) \`[iOS]\` \`[web]\`
- File diff viewer \`[iOS]\` \`[web]\`
- Discard changes \`[iOS]\` \`[web]\`
- History tab (commit log) \`[iOS]\` \`[web]\`
- Rollback to previous commits \`[iOS]\` \`[web]\`
- Branches tab (list + switch) \`[iOS]\` \`[web]\`
- Git checkpoint creation \`[iOS]\` \`[web]\`

### 3.9 File Explorer

- Tree view with expandable directories \`[iOS]\` \`[web]\`
- File search \`[iOS]\` \`[web]\`
- File preview \`[iOS]\` \`[web]\`
- @ mention autocomplete (file paths) \`[iOS]\` \`[web]\`

### 3.10 Web Browser / Dev Server

- Embedded web browser (WKWebView / iframe) \`[iOS]\` \`[web]\`
- Dev server auto-detection \`[iOS]\` \`[web]\`
- Port picker \`[iOS]\` \`[web]\`
- Dev server start/stop \`[iOS]\` \`[web]\`
- Proxy scheme handler (tarsy-http://) \`[iOS]\` \`[web]\`
- Fullscreen browser \`[iOS]\` \`[web]\`

### 3.11 Subscription & Monetization

- Pro monthly ($14.99/month) \`[iOS]\` \`[web]\`
- Pro annual ($119.99/year) \`[iOS]\` \`[web]\`
- Paywall view \`[iOS]\` \`[web]\`
- Free tier (1 workspace limit) \`[iOS]\` \`[web]\`
- Restore purchases (StoreKit) \`[iOS]\`
- Stripe checkout \`[web]\`

### 3.12 MCP Store

- Browse MCP integrations \`[iOS]\` \`[web]\`
- Install/uninstall MCPs \`[iOS]\` \`[web]\`
- Health indicators \`[iOS]\` \`[web]\`

### 3.13 Notifications

- Push notifications (APNs) \`[iOS]\`
- Web push notifications \`[web]\`
- Live Activities (Lock Screen + Dynamic Island) \`[iOS]\`
- Unread badge counts \`[iOS]\` \`[web]\`
- In-app notification banners \`[web]\`

### 3.14 Profile & Settings

- Profile view (name, avatar, email) \`[iOS]\` \`[web]\`
- API key management (encrypted) \`[iOS]\` \`[web]\`
- Voice language picker \`[iOS]\` \`[web]\`
- Agent permission config (safe/dangerous per engine) \`[iOS]\` \`[web]\`
- Account deletion \`[iOS]\` \`[web]\`

### 3.15 Developer Tools

- API client (HTTP requests) \`[iOS]\` \`[web]\`
- Process/port viewer \`[iOS]\` \`[web]\`
- Resource monitor (CPU, memory, disk) \`[iOS]\` \`[web]\`
- Text tools (encode/decode) \`[iOS]\` \`[web]\`

### 3.16 Feedback

- Bug/feature/general feedback form \`[iOS]\` \`[web]\`
- Screenshot attachment \`[iOS]\` \`[web]\`

### 3.17 AI Project Wizard

- Multi-step project generator \`[iOS]\` \`[web]\`
- Stack selection \`[iOS]\` \`[web]\`
- GitHub repo creation \`[iOS]\` \`[web]\`

### 3.18 UI & Design System

- TarsyTheme (monochrome dark, monospaced fonts) \`[iOS]\` \`[web]\`
- Status banner (connection state) \`[iOS]\` \`[web]\`
- Agent icons (per engine type) \`[iOS]\` \`[web]\`
- Haptic feedback \`[iOS]\`
- Tarsy Eyes mascot \`[iOS]\` \`[web]\`

---

## 4. Auto-Detected Metrics

| Metric | Count |
|--------|-------|
| WSProtocol actions | 149 |
| macOS source files | 37 |
| iOS source files | 54 |
| Shared source files | 24 |
| Windows companion | 0 (planned) |
| Web client | 0 (planned) |

---

## 5. Platform Technology Map

| Capability | macOS (Swift) | Windows (C#) | iOS (Swift) | Web (Next.js) |
|-----------|--------------|-------------|------------|--------------|
| Screen capture | ScreenCaptureKit | DXGI / Windows.Graphics.Capture | — | — |
| Video encoding | VideoToolbox | Media Foundation / NVENC | — | — |
| Video decoding | — | — | VideoToolbox | WebCodecs API |
| Remote input injection | CGEvent | SendInput (Win32) | — | — |
| Input capture | — | — | UITextField hidden | DOM events |
| Terminal/PTY | posix_openpt | ConPTY (Windows Pseudo Console) | — | — |
| System tray | NSStatusItem (menu bar) | NotifyIcon (system tray) | — | — |
| Sleep prevention | IOKit assertions | SetThreadExecutionState | — | — |
| Privilege escalation | sudo + ASKPASS | UAC elevation | — | — |
| WebSocket server | Network.framework | System.Net.WebSockets | — | — |
| WebSocket client | URLSession / NWConnection | System.Net.WebSockets | URLSession / NWConnection | native WebSocket |
| TLS certificates | Security.framework | System.Security.Cryptography | — | — |
| Crypto (E2E) | CryptoKit | System.Security.Cryptography | CryptoKit | Web Crypto API |
| Push notifications | UNUserNotificationCenter | Windows.UI.Notifications | APNs | Web Push API |
| Auth (OAuth) | ASWebAuthenticationSession | WebView2 | ASWebAuthenticationSession | next-auth / Supabase Auth |
| Keychain | Security.framework | DPAPI / Credential Manager | Security.framework | HttpOnly cookies |
| Speech recognition | — | — | SFSpeechRecognizer | Web Speech API |
| Subscriptions | — | — | StoreKit 2 | Stripe |
| Live Activities | — | — | ActivityKit | — |
| File watcher | DispatchSource | FileSystemWatcher | — | — |


*Generated on 2026-04-11 13:05:44 by `scripts/generate-features.sh`*
