# PRD: QR Code Machine Pairing

## Problem

Apple rejected the iOS app (Guideline 4.2.3 — Minimum Functionality) because it requires installing a macOS companion app before it can be used. The reviewer opens the app, logs in, and lands on an empty dashboard that says "download tarsy for mac" — the app does nothing standalone.

## Solution

Add QR code-based machine pairing. The macOS app displays a QR code, the iOS app scans it to bind the machine to the user's account. This gives the iOS app visible functionality on launch (a QR scanner) and replaces the passive "download mac app" empty state with an active pairing flow.

## Goals

1. **Pass Apple review** — iOS app has functional UI on launch (QR scanner)
2. **Simplify pairing UX** — visual QR scan replaces implicit same-account discovery
3. **Permanent binding** — one QR scan per machine, persists across logout/login
4. **Security** — pairing tokens are single-use with 5-minute TTL

## Non-Goals

- Removing login from iOS or macOS (both keep existing auth)
- Replacing the relay/WebSocket connection mechanism
- Adding standalone iOS features (AI chat without Mac, etc.)
- Changing the subscription model

---

## Architecture

### Pairing Flow

```
macOS App                          Supabase                         iOS App
    |                                  |                                |
    |  1. Generate pairing_token       |                                |
    |  (random 32-byte, hex-encoded)   |                                |
    |                                  |                                |
    |  2. INSERT INTO machine_pairings |                                |
    |  (machine_id, pairing_token,     |                                |
    |   expires_at = now() + 5min)     |                                |
    |--------------------------------->|                                |
    |                                  |                                |
    |  3. Display QR code              |                                |
    |  containing:                     |                                |
    |  tarsy://pair?m=<machine_id>     |                                |
    |  &t=<pairing_token>              |                                |
    |                                  |                                |
    |                                  |   4. User scans QR code        |
    |                                  |<-------------------------------|
    |                                  |                                |
    |                                  |   5. iOS calls claim_machine() |
    |                                  |   edge function with:          |
    |                                  |   - machine_id                 |
    |                                  |   - pairing_token              |
    |                                  |   - user JWT                   |
    |                                  |<-------------------------------|
    |                                  |                                |
    |  6. Supabase validates:          |                                |
    |  - token exists & not expired    |                                |
    |  - token is unused               |                                |
    |  - machine_id matches            |                                |
    |                                  |                                |
    |  7. UPDATE machines              |                                |
    |  SET user_id = <ios_user_id>     |                                |
    |  WHERE id = <machine_id>         |                                |
    |                                  |                                |
    |  8. DELETE pairing token         |                                |
    |  (single-use, consumed)          |                                |
    |                                  |                                |
    |                                  |   9. Return success +          |
    |                                  |   machine details              |
    |                                  |------------------------------->|
    |                                  |                                |
    | 10. Machine detects user_id      |                                |
    | changed via realtime sub         |                                |
    | → updates relay connection       |                                |
    |                                  |                                |
    | 11. iOS auto-connects to         |                                |
    | machine via smart connect        |                                |
    |<-----------------------------------------------------------------|
```

### QR Code Payload

URL format: `tarsy://pair?m={machine_id}&t={pairing_token}`

- `machine_id`: UUID of the machine (from `machines` table)
- `pairing_token`: 32-byte random hex string, single-use, 5-minute TTL

Using a deep link URL (`tarsy://`) means scanning with the system camera also works — it opens the Tarsy app directly.

### Database: `machine_pairings` Table

New table for pairing tokens. Migration `028_machine_pairings.sql`.

```sql
CREATE TABLE machine_pairings (
    id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
    machine_id uuid NOT NULL REFERENCES machines(id) ON DELETE CASCADE,
    pairing_token text NOT NULL,
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT unique_active_pairing UNIQUE (machine_id, pairing_token)
);

-- Index for token lookup during claim
CREATE INDEX idx_machine_pairings_token ON machine_pairings(pairing_token);

-- Auto-cleanup expired tokens
CREATE INDEX idx_machine_pairings_expires ON machine_pairings(expires_at);

-- RLS: machines table already allows machine owner to read
-- Pairing tokens are validated via edge function, not direct client access
ALTER TABLE machine_pairings ENABLE ROW LEVEL SECURITY;

-- Only the machine owner (current user_id on machines) can create pairing tokens
CREATE POLICY "Machine owner can manage pairings"
    ON machine_pairings FOR ALL
    USING (
        machine_id IN (SELECT id FROM machines WHERE user_id = auth.uid())
    );
```

### Edge Function: `claim-machine`

New Supabase edge function. Validates the pairing token and transfers machine ownership.

```
POST /functions/v1/claim-machine
Authorization: Bearer <ios_user_jwt>
Body: { "machine_id": "uuid", "pairing_token": "hex-string" }
```

Logic:
1. Validate JWT (extract `user_id`)
2. Look up `machine_pairings` where `pairing_token` matches AND `machine_id` matches AND `expires_at > now()`
3. If not found → 400 "Invalid or expired pairing code"
4. Update `machines` SET `user_id = auth_user_id` WHERE `id = machine_id`
5. Delete the consumed pairing token
6. Delete any other active pairings for this machine
7. Return machine details (hostname, model_identifier, status)

Why an edge function instead of direct RLS:
- The iOS user doesn't own the machine yet (different `user_id`), so RLS would block the UPDATE
- Edge function uses service role to bypass RLS for the ownership transfer
- Validates the pairing token server-side (can't be spoofed)

### Changes to `machines` Table

The `user_id` column currently has a NOT NULL constraint. Two options:

**Option A (recommended):** Keep NOT NULL. The Mac still logs in and registers with its own `user_id`. When iOS claims the machine, `user_id` is updated to the iOS user's `user_id`.

This means:
- Mac initially owns the machine (can generate pairing tokens via RLS)
- After claim, iOS user owns it
- Mac detects the ownership change via Supabase realtime subscription on `machines`
- Mac re-authenticates relay with awareness that it's now serving a different user

**Option B:** Make `user_id` nullable. Machine exists without an owner until claimed. Simpler conceptually but requires handling null user_id everywhere.

We go with **Option A**.

---

## macOS Changes

### Onboarding: Step 4 (Ready) — Add QR Code

Current Step 4 shows:
- "signed in as [email]"
- "relay connected"
- "encrypted on port 8642"
- "H.264 streaming ready"
- Button: "minimize to menu bar"

**New Step 4** adds a QR code section:

```
┌─────────────────────────────────────┐
│                                     │
│   ✓ signed in as user@email.com     │
│   ✓ relay connected                 │
│   ✓ encrypted on port 8642          │
│   ✓ H.264 streaming ready           │
│                                     │
│   ─────────────────────────────     │
│                                     │
│   pair your iphone                  │
│                                     │
│        ┌──────────────┐             │
│        │              │             │
│        │   QR CODE    │             │
│        │              │             │
│        └──────────────┘             │
│                                     │
│        A3F7-B2C1-D9E4              │
│                                     │
│   scan this code with Tarsy iOS     │
│   to connect this mac to your       │
│   account                           │
│                                     │
│   ○○○○○ 4:32 remaining             │
│                                     │
│   [ minimize to menu bar ]          │
│                                     │
└─────────────────────────────────────┘
```

- QR auto-regenerates when token expires (every 5 min)
- Countdown timer shows remaining validity
- After successful pairing, shows "paired with [user name]" confirmation

### Menu Bar: "Show QR Code" Option

Add menu item to the existing menu bar dropdown:

```
┌─────────────────────────┐
│  Tarsy                  │
│  ─────────────────────  │
│  Status: Online         │
│  Connected: 1 client    │
│  ─────────────────────  │
│  Show Pairing QR Code   │  ← NEW
│  ─────────────────────  │
│  Open Onboarding...     │
│  Check for Updates...   │
│  ─────────────────────  │
│  Quit Tarsy             │
│  ─────────────────────  │
└─────────────────────────┘
```

Clicking "Show Pairing QR Code" opens a small floating window (280x420pt) with:
- QR code (200x200pt)
- Human-readable connection code below QR (e.g., `A3F7-B2C1-D9E4`)
- "scan with Tarsy iOS" label
- Countdown timer
- Close button

The connection code is a 12-character hex string derived from the pairing token, formatted as `XXXX-XXXX-XXXX` for readability. It serves as a manual fallback for users who can't use the camera.

### QR Generation Flow (macOS)

1. `DaemonManager` gets a new method: `generatePairingToken() async -> (token: String, expiresAt: Date)`
2. Generates 32-byte random data → hex-encoded string
3. Inserts into `machine_pairings` table via Supabase
4. Returns token + expiry
5. QR is generated using `CoreImage.CIFilter.qrCodeGenerator()` with the URL `tarsy://pair?m={machine_id}&t={token}`
6. Auto-refresh: timer regenerates token + QR when TTL expires
7. On successful pair (detected via realtime sub on `machines`): dismiss QR, show confirmation

### Realtime Subscription

The Mac subscribes to changes on its own `machines` row:

```swift
supabase.realtime.channel("machine-pairing")
    .on("postgres_changes", filter: .eq("id", machineId), event: .update) { change in
        if change.new["user_id"] != change.old["user_id"] {
            // Machine was claimed by iOS user
            // Update local state, refresh relay auth
        }
    }
```

---

## iOS Changes

### New: QR Scanner Empty State (Dashboard)

Replace the current "connect your mac" 4-step guide with a Lunel-style pairing screen.

**When `machineService.machines.isEmpty && hasFetchedMachines`:**

```
┌─────────────────────────────────────┐
│                                     │
│                                     │
│                                     │
│         ┌──────────────┐            │
│         │   Tarsy      │            │
│         │   eyes logo  │            │
│         └──────────────┘            │
│                                     │
│           tarsy                     │
│     remote agent controller         │
│                                     │
│                                     │
│   ┌─────────────────────────────┐   │
│   │  ⎡⎤  Scan to Connect Mac   │   │
│   └─────────────────────────────┘   │
│                                     │
│                                     │
│                                     │
│                                     │
│                                     │
│   By continuing, you agree to our   │
│   Terms of Service and Privacy      │
│   Policy.                           │
│                                     │
└─────────────────────────────────────┘
```

- Monochrome design following TarsyTheme
- Logo + app name + tagline centered
- Large "Scan to Connect Mac" button opens camera
- Terms/Privacy links at bottom
- Button uses `TarsyTheme.text` on `TarsyTheme.surface` (white on #222)

### New: QRScannerView

Full-screen camera view for scanning QR codes, with help and manual code entry fallbacks.

```
┌─────────────────────────────────────┐
│  ✕                                  │
│                                     │
│                                     │
│       ┌───────────────────┐         │
│       │                   │         │
│       │                   │         │
│       │    camera feed    │         │
│       │    with QR        │         │
│       │    viewfinder     │         │
│       │                   │         │
│       │                   │         │
│       └───────────────────┘         │
│                                     │
│   point your camera at the QR       │
│   code on your mac                  │
│                                     │
│   Learn how to connect              │  ← text button, opens help modal
│                                     │
│   Enter connection code             │  ← text button, opens code input
│                                     │
└─────────────────────────────────────┘
```

**Camera scanner:**
- Uses `AVCaptureSession` with `AVCaptureMetadataOutput` for `.qr` type
- Parses `tarsy://pair?m=...&t=...` URL from QR data
- On valid QR detected:
  1. Haptic feedback (success)
  2. Calls `claim-machine` edge function
  3. Shows loading state
  4. On success: dismisses scanner, machine appears in dashboard, auto-connects
  5. On error: shows inline error ("expired code — ask your Mac to generate a new one")

**"Learn how to connect" button:**

Opens a modal/sheet with step-by-step instructions:

```
┌─────────────────────────────────────┐
│                                     │
│   how to connect your mac           │
│                                     │
│   1. download tarsy for mac         │
│      from tarsy.dev                 │
│                                     │
│   2. install and open the app       │
│                                     │
│   3. sign in and grant              │
│      permissions                    │
│                                     │
│   4. a QR code will appear —        │
│      scan it with this camera       │
│                                     │
│                                     │
│   [ Download for Mac ↗ ]            │  ← opens tarsy.dev in Safari
│                                     │
│   [ Done ]                          │
│                                     │
└─────────────────────────────────────┘
```

- Links to `https://tarsy.dev` for the macOS download
- Dismisses back to the scanner view

**"Enter connection code" button:**

Opens a sheet with a text field for manual code entry. This is the fallback for users with camera issues.

```
┌─────────────────────────────────────┐
│                                     │
│   enter connection code             │
│                                     │
│   open tarsy on your mac and        │
│   find the connection code below    │
│   the QR code                       │
│                                     │
│   ┌─────────────────────────────┐   │
│   │  XXXX-XXXX-XXXX            │   │
│   └─────────────────────────────┘   │
│                                     │
│   [ Connect ]                       │
│                                     │
└─────────────────────────────────────┘
```

- The macOS QR view also displays a human-readable code below the QR (e.g., `A3F7-B2C1-D9E4`)
- This code maps to the same `machine_id + pairing_token` payload
- Monospaced text field, auto-uppercased, formatted with dashes
- On submit: same `claim-machine` flow as QR scan

### Machine Picker: "Add Mac" Option

The machine selector dropdown is always visible in the dashboard header, even with a single machine. It shows all paired machines plus an "Add Mac" action at the bottom:

```
┌─────────────────────────────┐
│  ● MacBook Pro de Felipe    │  ← current, online
│  ○ Mac Mini do Escritório   │  ← offline
│  ───────────────────────    │
│  ⎡⎤ Add Mac...              │  ← opens QRScannerView
└─────────────────────────────┘
```

- Machine picker is always shown (not hidden when only 1 machine)
- Each machine shows online/offline indicator
- "Add Mac..." at the bottom opens `QRScannerView`
- Selecting a machine switches the active connection and filters workspaces

### Deep Link Handler

Update `DeepLinkRouter` to handle `tarsy://pair` URLs:

```swift
case let url where url.scheme == "tarsy" && url.host == "pair":
    let machineId = url.queryParam("m")
    let token = url.queryParam("t")
    // Trigger pairing flow
```

This allows scanning the QR with the native iOS Camera app (outside Tarsy) to also work — it opens Tarsy and starts pairing automatically.

### Info.plist

Register `tarsy` as a URL scheme (if not already):

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>tarsy</string>
        </array>
    </dict>
</array>
```

---

## Security Considerations

1. **Token is single-use** — consumed immediately on successful claim. Cannot be replayed.
2. **Token TTL is 5 minutes** — limits exposure window if QR is photographed.
3. **Token is 32 bytes of randomness** — 256 bits of entropy, not guessable.
4. **Edge function validates server-side** — iOS can't directly modify `machines.user_id`.
5. **Machine ownership transfer** — when iOS claims a machine, the old owner (Mac's login account) loses access to that machine row via RLS. Mac detects this via realtime and can re-authenticate.
6. **Expired token cleanup** — a cron job or edge function periodically deletes rows where `expires_at < now()`. Alternatively, rely on the expiry check in `claim-machine` and clean up lazily.

### Edge Case: Machine Already Owned by Another User

If the machine is already bound to a different iOS user and someone scans the QR:
- The `claim-machine` edge function updates `user_id` to the new user
- This is intentional — the person with physical access to the Mac (who can see the QR) should be able to rebind it
- The old iOS user loses access (machine disappears from their dashboard via realtime)

### Edge Case: Mac's Own Auth After Claim

After iOS claims the machine, the Mac's `user_id` in Supabase differs from the Mac's JWT `user_id`. This means:
- Mac's RLS queries for its own machine row may fail
- **Solution:** The Mac detects the ownership change via realtime. It re-registers: creates a new machine record with its own `user_id`, OR it accepts the new owner and continues operating. 

**Recommended approach:** The Mac doesn't care about `machines.user_id` for its own operation. It keeps its own JWT for relay auth. The `machines.user_id` field determines which iOS user can see and connect to this machine. The relay validates that the Mac's `machine_secret` (from `machine_tokens` table) is valid, regardless of `user_id` changes.

This requires a small relay change: relay validates machine identity via `machine_secret` (already exists), not via `user_id` matching between machine JWT and iOS JWT.

---

## Migration Plan

### Database Migration: `028_machine_pairings.sql`

Creates the `machine_pairings` table as described above.

### Edge Function: `claim-machine`

New Deno function in `supabase/functions/claim-machine/`.

### Relay Change

Ensure relay validates machines by `machine_secret` from `machine_tokens` table, not by matching `user_id` between machine and client JWTs. (Verify current behavior — this may already work.)

---

## Implementation Order

1. **Database migration** — `machine_pairings` table
2. **Edge function** — `claim-machine`
3. **macOS: QR generation** — `DaemonManager` pairing token generation + QR display in onboarding Step 4
4. **macOS: Menu bar QR** — floating window with QR code
5. **macOS: Realtime subscription** — detect ownership change
6. **iOS: QRScannerView** — camera-based QR scanner
7. **iOS: Empty state redesign** — Lunel-style pairing screen
8. **iOS: Claim flow** — call edge function, handle success/error
9. **iOS: Dashboard "Add Mac"** — button to open scanner for additional machines
10. **iOS: Deep link handler** — `tarsy://pair` URL scheme support
11. **Relay: Verify machine auth** — ensure machine_secret validation works independently of user_id
12. **Testing** — end-to-end pairing flow, token expiry, edge cases

---

## Apple Review Notes

For the App Store review submission, include in the review notes:

> The app connects to a companion Mac application via QR code scanning. On first launch after login, users are presented with a QR code scanner to pair their Mac. The macOS companion generates the QR code during its setup process. Without a paired Mac, the app displays the pairing interface.

This positions the QR scanner as the app's entry-point functionality, satisfying Guideline 4.2.3's requirement that "apps should be able to run on launch."

---

## Metrics

- **Pairing success rate** — successful claims / QR scans attempted
- **Time to pair** — from QR display to successful claim
- **Token expiry rate** — how often users see expired tokens (indicates if 5 min is enough)
- **Re-pairing frequency** — how often the same machine is re-paired (indicates issues)
