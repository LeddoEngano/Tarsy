# PRD: DevTools

## Overview

DevTools is a new feature group in Tarsy that gives developers a suite of remote development utilities accessible from their iPhone. It lives as a dedicated section within the Workspace view, grouping four tools under a unified "DevTools" tab.

**Goal:** Reduce context-switching by letting developers inspect processes, test APIs, manage ports, monitor resources, and use text utilities — all without leaving Tarsy or opening their Mac.

---

## Features

### 1. Process & Ports Manager

Unified view with two tabs for managing processes and network ports on the remote Mac.

#### Tab: Processes

| Element | Detail |
|---------|--------|
| List columns | Process name, PID, Memory (MB), CPU % |
| Sorting | Tap column header to sort (name, memory, CPU) |
| Search | Filter by process name |
| Actions | Kill process (with confirmation alert) |
| Scope | All system processes (not filtered to user) |
| Refresh | Polling every 5 seconds while view is visible |

#### Tab: Ports

| Element | Detail |
|---------|--------|
| List columns | Port number, Process name, PID |
| Actions | Kill process occupying the port (with confirmation) |
| Visual | Highlight common dev ports (3000, 8080, 5432, 4200, 8000, 5173) with a subtle badge |
| Refresh | Polling every 5 seconds while view is visible |

#### WSProtocol Actions

| Action | Direction | Payload |
|--------|-----------|---------|
| `process_list` | iOS -> macOS | — |
| `process_list_result` | macOS -> iOS | `[{ name, pid, memory_mb, cpu_percent }]` |
| `process_kill` | iOS -> macOS | `{ pid: Int }` |
| `process_kill_result` | macOS -> iOS | `{ pid: Int, success: Bool, error: String? }` |
| `ports_list` | iOS -> macOS | — |
| `ports_list_result` | macOS -> iOS | `[{ port, process_name, pid }]` |

#### macOS Implementation

- **Processes:** Use `ps aux` (or `sysctl` with `KERN_PROC`) to enumerate all processes. Parse into structured data. CPU % from snapshot delta.
- **Ports:** Use `lsof -i -P -n` to list listening ports and their owning processes.
- **Kill:** `kill(pid, SIGTERM)` with fallback to `SIGKILL` if process doesn't terminate within 3s. Requires no special permissions for user-owned processes; system processes will return an error.

---

### 2. API Testing Client

Simple HTTP client that sends requests from the Mac, useful for testing localhost endpoints and internal APIs that aren't reachable from the phone.

#### UI

| Element | Detail |
|---------|--------|
| Method picker | Segmented control: GET, POST |
| URL field | Text input with placeholder `http://localhost:3000/api/...` |
| Headers | Key-value list with add/remove. Pre-filled with `Content-Type: application/json` for POST |
| Body | Raw JSON text editor (visible only for POST) |
| Send button | Triggers request via WebSocket to Mac |
| Response view | Status code (color-coded: 2xx green, 4xx yellow, 5xx red), response headers (collapsible), response body with JSON syntax highlighting |
| History | List of recent requests (method + URL + status), persisted locally for 24 hours, tap to reload into editor |

#### WSProtocol Actions

| Action | Direction | Payload |
|--------|-----------|---------|
| `http_request` | iOS -> macOS | `{ method, url, headers: {}, body: String? }` |
| `http_response` | macOS -> iOS | `{ status_code, headers: {}, body: String, duration_ms: Int }` |

#### macOS Implementation

- Execute request using `URLSession.shared` on the Mac.
- Timeout: 30 seconds.
- Return raw response body as string, headers as dictionary, status code, and elapsed time.
- No redirects followed automatically (so user sees the actual response).

#### iOS Implementation

- History stored in `UserDefaults` as JSON array with TTL field. On app launch, prune entries older than 24h.
- JSON syntax highlighting using `AttributedString` with `TarsyTheme` colors.

---

### 3. Text Based Tools

Client-side utility toolkit for common encoding, decoding, hashing, and formatting operations. Runs entirely on iOS — no WebSocket communication needed.

#### Tabs

**Base64**
- Two-way: encode and decode
- Input text field + output (read-only, copyable)
- Toggle switch: Encode / Decode
- Auto-updates output as user types

**JWT**
- Paste a JWT token
- Decoded view: Header (JSON), Payload (JSON), each in a collapsible section
- Expiration: show `exp` claim as human-readable date with "expired" / "valid for X hours" badge
- Does NOT verify signature (no secret input)

**SHA256**
- Input text field
- Output: hex-encoded SHA256 hash (read-only, copyable)
- Auto-updates as user types

**JSON**
- Input: raw JSON text
- Actions: Format (pretty-print) / Minify toggle
- Output with syntax highlighting
- Error indicator if JSON is invalid (red badge + error message)

#### iOS Implementation

- **Base64:** `Data(base64Encoded:)` / `.base64EncodedString()`
- **JWT:** Split on `.`, Base64URL-decode each segment, parse as JSON
- **SHA256:** `CryptoKit.SHA256.hash(data:)`
- **JSON:** `JSONSerialization` with `.prettyPrinted` / `.fragmentsAllowed`

---

### 4. Resource Monitor

Real-time system resource monitoring for the remote Mac. Accessible as a view within the workspace.

#### UI

| Resource | Display |
|----------|---------|
| CPU | Percentage bar + label (e.g., "CPU 20%") |
| Memory | Percentage bar + label (e.g., "Memory 8.2 / 16 GB — 51%") |
| Disk | Percentage bar + label (e.g., "Disk 234 / 500 GB — 47%") |

- Progress bars styled with `TarsyTheme` — monochrome fills on dark background.
- Polling: fixed interval every 3 seconds while view is visible.
- No historical charts in v1 — just live snapshot.

#### WSProtocol Actions

| Action | Direction | Payload |
|--------|-----------|---------|
| `system_resources` | iOS -> macOS | — |
| `system_resources_result` | macOS -> iOS | `{ cpu_percent, memory_used_bytes, memory_total_bytes, disk_used_bytes, disk_total_bytes }` |

#### macOS Implementation

- **CPU:** `host_statistics(host_port, HOST_CPU_LOAD_INFO)` — compute delta between two snapshots.
- **Memory:** `host_statistics64(host_port, HOST_VM_INFO64)` — calculate used from `active + wired + compressed`.
- **Disk:** `FileManager.default.attributesOfFileSystem(forPath: "/")` — `systemSize` and `systemFreeSize`.

---

## Navigation & Information Architecture

```
WorkspaceView
  |-- Chat (existing)
  |-- Stream (existing)
  |-- Browser (existing)
  |-- Git (existing)
  |-- Files (existing)
  |-- DevTools (NEW)
        |-- Process & Ports (default)
        |     |-- Tab: Processes
        |     |-- Tab: Ports
        |-- API Client
        |-- Text Tools
        |     |-- Tab: Base64
        |     |-- Tab: JWT
        |     |-- Tab: SHA256
        |     |-- Tab: JSON
        |-- Resources
```

DevTools appears as a new tab in the WorkspaceView tab bar. Inside, a secondary navigation (segmented control or horizontal scroll) switches between the four tools.

---

## Design Guidelines

- Follow `TarsyTheme` strictly: dark backgrounds (`#0a0a0a`, `#111111`), monospaced fonts, gray/white text
- No color accents except for status indicators (status codes, port highlights)
- Tables should use compact rows — these are data-dense views
- Kill/destructive actions always require confirmation (alert with process name + PID)
- Copy-to-clipboard on long-press for any data cell (PID, port, hash output, response body)

---

## Scope & Constraints

| Item | Decision |
|------|----------|
| Process scope | All system processes |
| API methods | GET, POST only (v1) |
| Text Tools execution | 100% client-side iOS |
| Resource Monitor polling | Fixed 3s interval |
| Process/Ports polling | Fixed 5s interval |
| API history retention | 24 hours, local persistence |
| Resource Monitor history/charts | Not in v1 |
| API collections/environments | Not in v1 |

---

## Implementation Order (suggested)

1. **Resource Monitor** — smallest scope, one WSAction pair, good warm-up for the pattern
2. **Process & Ports Manager** — builds on same polling pattern, adds kill actions
3. **Text Based Tools** — no backend work, pure iOS, can be developed in parallel
4. **API Testing Client** — most complex UI (request builder + response viewer + history)

---

## Future Considerations (out of scope for v1)

- PUT, PATCH, DELETE methods for API Client
- API collections and environment variables
- Resource Monitor historical charts (sparklines)
- Process Manager: restart process, view stdout/stderr
- Ports Manager: port forwarding configuration
- Network traffic inspector (like Charles Proxy)
- Docker container management
- SSH tunnel management
