# Contributing to Tarsy

Thanks for your interest in contributing to Tarsy! This guide will help you get set up and productive.

## Prerequisites

- macOS 14.0+ with Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- [Bun](https://bun.sh) — for the relay server
- [Supabase CLI](https://supabase.com/docs/guides/cli) — for local backend
- An Apple Developer account (free or paid)

## Setup

### 1. Clone the repo

```bash
git clone https://github.com/LeddoEngano/Tarsy.git
cd Tarsy
```

### 2. Configure secrets

```bash
cp Tarsy.xcconfig.template Tarsy.xcconfig
```

Open `Tarsy.xcconfig` and fill in your values:

| Variable | Where to get it |
|----------|----------------|
| `TARSY_SUPABASE_URL` | Your [Supabase project](https://supabase.com/dashboard) → Settings → API |
| `TARSY_SUPABASE_ANON_KEY` | Same page — the `anon` / `public` key |
| `TARSY_RELAY_URL` | Deploy your own relay (see below) or use `ws://localhost:8080/ws` for local dev |
| `DEVELOPMENT_TEAM` | [developer.apple.com](https://developer.apple.com) → Account → Membership → Team ID |
| `ULTRACONTEXT_API_KEY` | Optional — leave as placeholder if not using UltraContext |

### 3. Set up the database

```bash
# Start a local Supabase instance
supabase start

# This runs all migrations and sets up the schema
```

Use the local Supabase URL and anon key from `supabase start` output in your `Tarsy.xcconfig`.

### 4. Generate Xcode projects

```bash
cd TarsyiOS && xcodegen generate && cd ..
cd TarsymacOS && xcodegen generate && cd ..
```

### 5. Build and run

Open `TarsymacOS/TarsymacOS.xcodeproj` and `TarsyiOS/TarsyiOS.xcodeproj` in Xcode, then build and run.

### 6. Run the relay locally (optional)

```bash
npm install
npm run dev:relay
```

The relay starts on `ws://localhost:8080/ws`. Set `TARSY_RELAY_URL` to this in your `Tarsy.xcconfig` for local development.

## Validate your setup

```bash
./scripts/setup-check.sh
```

This checks that all prerequisites are installed and your config is filled in.

## Project structure

| Directory | What it is |
|-----------|-----------|
| `TarsyShared/` | Swift Package — shared auth, networking, models, E2E crypto |
| `TarsymacOS/` | macOS menu bar app (the "server" side) |
| `TarsyiOS/` | iOS app (the "client" side) |
| `TarsyWindows/` | Windows client (C#) |
| `relay/` | Bun + Hono WebSocket relay server |
| `website/` | Next.js landing page |
| `supabase/` | Database migrations and edge functions |
| `scripts/` | Build and deployment scripts |

## Key files

- **`DaemonManager.swift`** — macOS central orchestrator. Most new macOS features wire through here.
- **`ConnectionManager.swift`** — iOS WebSocket connection manager.
- **`WSProtocol.swift`** — WebSocket protocol definition (60+ action types).
- **`Config.swift`** — Runtime configuration (reads from xcconfig via Info.plist).

## Making changes

### Adding new iOS-macOS communication

1. Add a new `WSAction` case in `WSProtocol.swift`
2. Handle it in `DaemonManager.swift` (macOS side)
3. Add the listener in the appropriate iOS view or service

### Code style

- Use `TarsyTheme` colors and monospaced fonts for all UI
- Follow the existing SwiftUI patterns (`@Observable`, `@State`, `@Environment`)
- Keep the dark, minimal aesthetic — no blue tints or colorful defaults

### Database changes

- Add new migrations sequentially in `supabase/migrations/` (e.g., `040_description.sql`)
- All tables must have RLS enabled with user-scoped policies

## Pull requests

- Keep PRs focused — one feature or fix per PR
- Include a clear description of what changed and why
- Test on both iOS and macOS when touching shared code or networking
- Run `xcodegen generate` in both app directories if you changed `project.yml`

## Known areas for contribution

These are tracked as issues but always welcome:

- **Test coverage** — Currently minimal. Tests for `WSProtocol`, `E2ECrypto`, and `ConnectionManager` would be high-impact.
- **DaemonManager refactor** — At ~4,800 lines, this file should be split into focused modules.
- **Doc comments** — Public APIs in `TarsyShared` need documentation.

## Questions?

Open an issue on GitHub. We're happy to help contributors get started.
