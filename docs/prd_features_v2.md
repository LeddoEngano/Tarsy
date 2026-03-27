# Tarsy — PRD: Platform Evolution & AI-First Features

> Date: 2026-03-27

## Context

With the orchestration layer complete (push notifications, persistent tasks, quick dispatch, UltraContext, agent detection, permission modes, profiles, chat improvements), Tarsy is ready for the next evolution: making the platform smarter, more flexible, and truly AI-first.

This PRD focuses on 5 features that expand Tarsy from a single-machine agent companion into a multi-machine, AI-powered development platform.

### Key themes
- **AI-first workflows** — let AI handle project setup, not just coding
- **Multi-device support** — manage agents across multiple Macs
- **Native OS integration** — Live Activities for real-time visibility
- **OpenClaw support** — first-class workspace type for full-screen agent observation

---

## Feature 1: AI Project Creation (Wizard)

**Priority:** Highest — feature differentiator, wow factor

**Concept:** User describes a project idea in natural language. Tarsy guides them through a multi-step wizard powered by AI, refining the idea into a fully configured workspace with an agent already working.

### Flow

```
1. User taps "Create with AI" on Dashboard
2. Prompt step: user describes the project ("a Next.js dashboard for tracking crypto prices")
3. AI refinement: agent on Mac processes the prompt and returns structured suggestions
4. Stack selection: UI presents stack choices based on AI response (language, framework, tools)
5. Confirmation: user reviews summary (project name, path, stack, initial prompt)
6. Execution:
   a. git init locally on Mac
   b. If gh CLI or GitHub MCP detected → offer "Create on GitHub too?"
   c. Create workspace with pre-filled configs
   d. Dispatch agent with initial prompt to scaffold the project
7. User lands in the workspace with agent already coding
```

### AI Integration

- Uses the agent running on the Mac (via relay) — no separate API key needed
- Prompt injection prepares the agent to return structured/formatted responses
- iOS parses structured responses to build native UI (stack picker, config cards)
- Agent handles both the refinement conversation AND the actual project creation

### Technical Details

**iOS:**
- `AIProjectWizardView` — multi-step wizard (SwiftUI)
  - Step 1: `ProjectIdeaStep` — text input for project description
  - Step 2: `StackSelectionStep` — cards/chips for language, framework, tooling (populated from AI response)
  - Step 3: `ProjectSummaryStep` — review & confirm (name, path, stack, initial prompt)
- Wizard sends structured prompts to Mac agent via `engineCreate` with formatted system prompt
- Parse agent responses (JSON or structured text) to populate UI steps

**macOS:**
- `DaemonManager` handles `engineCreate` with a `wizardMode` flag
- Agent receives injected system prompt: "You are helping set up a new project. Respond with JSON containing: suggested_name, language, framework, dependencies, initial_commands, scaffold_prompt"
- After confirmation: run git init, create directories, optionally `gh repo create`
- Detect `gh` CLI presence via `which gh` or check for GitHub MCP

**TarsyShared:**
- New WSProtocol actions: `wizard:start`, `wizard:response`, `wizard:execute`
- New model: `ProjectWizardConfig` (name, path, stack, framework, dependencies, githubRepo?)

### GitHub Integration
- macOS checks if `gh` CLI is installed or GitHub MCP is available
- If detected: after local repo creation, offer "Create on GitHub too?"
- Uses `gh repo create` with appropriate flags
- If not detected: skip GitHub option silently

---

## Feature 2: Multi-Machine Support

**Priority:** High — infrastructure expansion

**Concept:** Users with multiple Macs (e.g., personal MacBook + Mac Mini running OpenClaw) can manage all machines from a single iOS app. Workspaces are scoped to their respective machines.

### UX

- Dashboard header has a **machine picker** (dropdown/segmented control)
- Default: "All Machines" shows workspaces from every connected machine
- Selecting a specific machine filters to its workspaces only
- Machine status indicator (online/offline) next to each machine name

### Technical Details

**Supabase:**
- `machines` table already exists — ensure it has: `id`, `user_id`, `name`, `hostname`, `os_version`, `is_online`, `last_seen_at`
- Workspaces already have `machine_id` — use this for filtering
- RLS: user can only see their own machines

**macOS:**
- On boot, `ConnectionManager` registers/updates machine record in Supabase
- Heartbeat updates `last_seen_at` periodically
- Machine `name` defaults to hostname, user can customize in macOS menu bar settings

**iOS:**
- `DashboardView`: machine picker at top (Picker or Menu style)
- `MachineService` in TarsyShared: CRUD for machines, observe online status
- When creating a workspace: auto-select current machine, or let user pick if multiple online
- Quick Dispatch: show machine selector when multiple machines are online

**TarsyShared:**
- `Machine` model update: ensure `name`, `isOnline`, `lastSeenAt` fields
- `MachineService`: `loadMachines()`, `observeOnlineStatus()`, `updateMachineName()`

### Connection Management
- Each machine maintains its own relay connection
- iOS `ConnectionManager` can connect to multiple machines simultaneously (or switch between them)
- Workspace operations route to the correct machine's relay connection

---

## Feature 3: Auto-detect Start Command

**Priority:** Medium — quick win, improves onboarding UX

**Concept:** When creating a workspace, Tarsy analyzes the selected repo and auto-fills the start command for the chosen AI engine. User can always override.

### Repo Analysis

macOS scans the workspace directory for:
- `package.json` → detect scripts (`dev`, `start`, `build`), framework (Next.js, Vite, etc.)
- `Makefile` / `Justfile` → detect common targets
- `Cargo.toml` → Rust project, suggest `cargo run`
- `pyproject.toml` / `requirements.txt` → Python project
- `Package.swift` → Swift package
- `CLAUDE.md` → existing agent config, extract model preferences or flags
- `.cursorrules`, `.github/copilot-instructions.md` → other agent configs
- Git remotes → project context

### What gets auto-filled
- **Engine start command**: e.g., `claude` → `claude --model opus` if CLAUDE.md suggests it
- **Working directory**: repo root path
- **Project name suggestion**: based on directory name or package.json name

### Technical Details

**macOS:**
- `RepoAnalyzer` (new): scans repo directory, returns `RepoAnalysis` (language, framework, scripts, agent configs)
- `DaemonManager` runs analysis when workspace is created or repo path changes
- Sends result via WSPacket `repo:analysis`

**iOS:**
- `NewWorkspaceView` / `WorkspaceSettingsView`: auto-populate fields from `RepoAnalysis`
- Show suggestion with "Auto-detected" badge, user can edit
- If analysis returns nothing specific, fall back to engine defaults

**TarsyShared:**
- New model: `RepoAnalysis` (language, framework, scripts, suggestedCommand, projectName)
- New WSProtocol action: `repo:analysis`, `repo:analyze_request`

---

## Feature 4: OpenClaw Workspace Type

**Priority:** Medium — expands use case to full-screen agent observation

**Concept:** A workspace type specifically for OpenClaw that streams the entire screen instead of a single terminal window. Designed for watching an autonomous agent (OpenClaw) work across the full desktop.

### Differences from normal workspace
- **Screen capture**: captures the full screen, not a specific window
- **Stream view**: `InteractiveStreamView` is the primary view (not the chat)
- **No terminal**: no embedded terminal output — the stream IS the content
- Chat sidebar available for sending commands/questions, but minimized by default

### Technical Details

**macOS:**
- `ScreenCaptureService` already supports full-screen capture — ensure it's selectable per workspace
- Workspace config includes `workspaceType: .openClaw` which triggers full-screen capture mode
- `MJPEGStreamServer` streams the full desktop instead of a window crop

**iOS:**
- `WorkspaceView` detects `workspaceType == .openClaw` and shows stream-first layout
- Stream takes full screen, chat is a collapsible overlay/sheet
- Touch input maps to full screen coordinates (already supported via `RemoteInputService`)

**TarsyShared:**
- `Workspace` model: add `workspaceType` enum (`.standard`, `.openClaw`)
- `WSProtocol`: workspace creation includes `workspaceType` field

**Supabase:**
- `workspaces` table: add `workspace_type` column (text, default 'standard')

---

## Feature 5: Live Activities

**Priority:** Lower — native OS integration, polish feature

**Concept:** Each workspace with an active agent gets a Live Activity showing real-time status on the Lock Screen and Dynamic Island. One Live Activity per workspace (up to 5 simultaneous per iOS limits).

### What's displayed

**Compact (Dynamic Island):**
- Agent engine icon (Claude, Gemini, etc.)
- Current status indicator (running/waiting)

**Expanded (Dynamic Island):**
- Agent engine icon + name
- Current tool being used (Read, Edit, Bash, etc.)
- Elapsed time since task started
- Workspace name

**Lock Screen:**
- Workspace name + agent engine
- Current tool icon + label
- Status (running / waiting for input / completed / error)
- Elapsed time
- Tap to open workspace in app

### Lifecycle
- **Start**: when agent begins working (`engineCreate` or resumed task)
- **Update**: on every tool change, status change, or periodically (every 30s for timer)
- **End**: when agent completes, errors, or user stops the task

### Technical Details

**iOS:**
- `TarsyWidgetExtension` (new target): contains `ActivityAttributes` and Live Activity views
- `LiveActivityManager` (new): `startActivity(workspace:)`, `updateActivity(workspace:tool:status:)`, `endActivity(workspace:)`
- `WorkspaceView` / `DaemonManager` calls `LiveActivityManager` on state changes
- Uses `ActivityKit` framework

**Data flow:**
- macOS sends `engineOutput` packets with tool info → iOS parses current tool
- iOS `LiveActivityManager` updates the Live Activity with new tool/status
- Timer runs client-side (started when activity begins)

**TarsyShared:**
- `AgentToolType` enum: `.read`, `.edit`, `.bash`, `.grep`, `.glob`, `.write`, `.thinking`, `.unknown`
- Parse tool type from `engineOutput` content (match patterns like "Read(", "Edit(", "Bash(")

---

## Implementation Order

| # | Feature | Priority | Complexity |
|---|---------|----------|------------|
| 1 | AI Project Creation (Wizard) | Highest | High |
| 2 | Multi-Machine Support | High | Medium-High |
| 3 | Auto-detect Start Command | Medium | Low |
| 4 | OpenClaw Workspace Type | Medium | Low-Medium |
| 5 | Live Activities | Lower | Medium |

---

## Dependencies & Notes

- **Feature 1 → Feature 3**: AI Project Creation benefits from repo analysis (Feature 3) for auto-filling wizard fields
- **Feature 2 → Feature 4**: Multi-machine is needed for the OpenClaw use case (separate Mac running OpenClaw)
- **Feature 5**: Independent, can be built in parallel with others
- All features use the existing relay infrastructure and WSProtocol
- All UI follows TarsyTheme (warm earthy palette, monospaced fonts)

---

## Nice-to-have (future)

- iOS Widgets (Home Screen) showing task status — complements Live Activities
- Apple Watch companion for notifications and quick replies
- Siri Shortcuts for dispatching tasks by voice
- Template gallery for AI Project Creation (curated starter templates)
- Worktrees for isolated agent work (deferred from previous PRD)
- Task decomposition (auto-split complex tasks across agents)
