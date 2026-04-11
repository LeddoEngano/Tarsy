# Tarsy Security Roadmap

Canonical status of the DB / secrets hardening work that started from the
April 2026 audit. Covers what's shipped and what's still deferred. Keep
this file up to date as phases land.

All three initial phases (realtime leak fix, APNs + pairing encryption,
machine keypair auth) plus the post-cleanup migrations 036 / 037 are
deployed to production. The legacy plaintext columns and the dual-auth
relay branch are gone. The system runs only on the new RPC + signature
paths now. macOS keypair rotation is wired up. Remaining work is
nice-to-haves (vault secret rotation, multi-device push, audit cadence,
Windows keypair rotation parity).

## Completed

### Phase 1 — Realtime leak + `ai_context` secrets — commit `27c2b15`

- **Migration 031** — dropped `workspaces` and `profiles` from the
  `supabase_realtime` publication. They were dead code in realtime land
  (zero client subscriptions, verified via grep across Swift) but were
  broadcasting `ai_context`, `config jsonb`, `email`, and
  `subscription_status` to any subscribed client. `machines` intentionally
  kept in the publication.
- **Migration 032** — `workspaces_ai_context_no_secrets` CHECK constraint
  blocking Anthropic / OpenAI / GitHub / Slack / AWS / Google / PEM
  private-key patterns from being stored in `workspaces.ai_context`.
  Applied as a full (not `NOT VALID`) constraint after a read-only
  diagnostic in prod confirmed zero existing matches.
- **iOS client-side detection** — `AIContextSecretScanner` in TarsyShared
  (single source of truth, mirrors the SQL regex). Warning banner in
  `AIContextEditorView`; Save button disabled while a secret is detected.

### Phase 2 — APNs token encryption + pairing HMAC — commit `ccf132f`

- **Migration 033** — encryption / HMAC infrastructure.
  - New columns: `push_tokens.device_token_enc`,
    `live_activity_tokens.activity_token_enc`,
    `machine_pairings.pairing_token_hmac`,
    `machine_pairings.connection_code_hmac`.
  - `vault.secrets` entries: `apns_token_enc_key` (AES passphrase),
    `pairing_hmac_pepper` (HMAC-SHA256 pepper).
  - SECURITY DEFINER helpers (`_apns_enc_key`, `_pairing_pepper`) +
    public RPCs (`register_push_token`, `register_live_activity_token`,
    `create_machine_pairing`) and service-role RPCs
    (`get_decrypted_push_tokens`, `get_decrypted_live_activity_tokens`,
    `claim_pairing_by_token`, `claim_pairing_by_code`).
  - BEFORE INSERT triggers on all three tables encrypt/hash any plaintext
    that legacy clients still write and null the plaintext column in the
    same transaction — the plaintext never persists.
  - Backfilled 10 existing `push_tokens` rows.
- **Migration 034** — locked down function grants. Supabase's
  `pg_default_acl` silently grants `EXECUTE` on every new public-schema
  function to `anon`, `authenticated`, and `service_role`. A naive
  `REVOKE ALL ... FROM public` only targets the `PUBLIC` pseudo-role and
  leaves those per-role grants in place. Before 034, any authenticated
  user could call `get_decrypted_push_tokens(other_user_id)` and
  exfiltrate another user's APNs token plaintext. 034 does explicit
  `REVOKE ... FROM anon, authenticated` on the sensitive functions.
  Verified via `has_function_privilege()`.
- **Edge functions** — `send-push`, `update-live-activity`, `claim-machine`
  updated to call the new RPCs instead of `.from().select()` / `.eq()`
  on the tables. Deployed via `supabase functions deploy --use-api` (no
  Docker dependency).
- **Swift clients** updated to call the RPCs
  (`TarsyiOSApp.swift:45` register_push_token, `LiveActivityManager.swift:313`
  register_live_activity_token, `PairingService.swift:32` create_machine_pairing).
  Old direct-insert paths still handled by the triggers, so **the app
  release is not blocking**.
- **Server-side secret generation** — `PairingService.generatePairingToken`
  no longer produces token/code in Swift via `SecRandomCopyBytes`. All
  pairing secret material now originates in Postgres via
  `gen_random_bytes`, so the client never touches a plaintext that isn't
  already HMACed.

### Phase 3 — `machine_secret` → public-key crypto + Secure Enclave / TPM — commit `542297c`

- **Migration 035** — added `machine_tokens.public_key bytea` and
  `key_algorithm text default 'p256-ecdsa'`; made
  `machine_tokens.machine_secret` nullable; created
  `register_machine_public_key(p_machine_id, p_public_key)` SECURITY
  DEFINER RPC. Grants locked down explicitly (`REVOKE ... FROM anon,
  service_role` after creation) following the Phase 2 / 034 lesson.
- **Relay dual-auth** — `relay/src/index.ts` accepts both the legacy
  `machineSecret` path and the new signed-timestamp flow (`machine_id`,
  `timestamp`, `signature`, `machinePublicKey`). Prefers the signature
  path when both are present. Verifies DER ECDSA via `node:crypto`
  `createPublicKey` + `verify({dsaEncoding: 'der'})`, with a ±60s
  freshness window and optional client-presented public key
  cross-check against the DB.
- **Bugfix in the same deploy** — the `fetch` handler in
  `relay/src/index.ts:270` used `await` without being declared `async`.
  Older Bun runtimes were lenient; Bun 1.3.12 on Fly.io is not, so the
  fly image crashed at startup until this was fixed. Unrelated to
  Phase 3 but blocking the deploy.
- **Naming disambiguation** — the machine identity public key is
  `machinePublicKey` in the auth payload (not `publicKey`), because
  `publicKey` was already in use by Windows for an E2E encryption key
  and the iOS `ConnectionManager` uses `e2ePublicKey`. Consistent naming
  avoids collisions during the rollout window.
- **macOS key storage** — `TarsymacOS/Sources/Security/MachineKeyStore.swift`
  is an actor backed by CryptoKit's
  `SecureEnclave.P256.Signing.PrivateKey` when available, falling back
  to `P256.Signing.PrivateKey` stored in Keychain for Intel Macs
  without Secure Enclave. Access control is
  `kSecAccessControlPrivateKeyUsage` **without** `userPresence`, so
  signing is silent (no password / biometric prompt — honours the
  headless-remote-Mac rule from project feedback).
- **Windows key storage** — `TarsyWindows/Security/MachineKeyStore.cs`
  uses `CngKey.Create(CngAlgorithm.ECDsaP256, ...)` with
  `MicrosoftPlatformCryptoProvider` (TPM 2.0) when available, falling
  back to `MicrosoftSoftwareKeyStorageProvider` with
  `CngExportPolicies.None`. Signs with
  `DSASignatureFormat.Rfc3279DerSequence` to match the DER output of
  macOS CryptoKit. **Also replaced the `EnsureSecret` TODO stub** that
  generated a fresh Guid on every launch and never persisted it — as a
  result, Windows can now authenticate with the relay for the first
  time.
- **macOS daemon wiring** — `DaemonManager.swift` has a new
  `ensureMachinePublicKey(userId:machineId:)` that creates (or loads)
  the keypair, compares against what's in the DB, and only uploads via
  RPC when the DER bytes differ (avoids a noisy `rotated_at` bump on
  every reboot). `RelayClient.swift` accepts a new
  `machineIdentity: MachineAuthIdentity?` parameter and builds the
  signed-timestamp auth payload in `performConnect`.
- **Windows daemon wiring** — `MachineService.cs` calls
  `MachineKeyStore.LoadOrCreate()` during `Register()` and uploads via
  REST RPC. `RelayClient.cs` was rewritten to take the key store,
  machine id, and user id (instead of a dead `machineSecret`) and to
  build the same signed-timestamp payload as the macOS client.

### Cleanup — migrations 036 + 037 — same commit cycle as Phase 3

With zero production users, there was no transition to protect. The
post-cleanup migrations were applied immediately after Phase 3 rather
than gated on app adoption. The system now runs **only** on the new
RPC + signature paths.

- **Migration 036** — dropped the Phase 2 plaintext columns that were
  kept as a transition bridge:
  - `push_tokens.device_token`
  - `live_activity_tokens.activity_token`
  - `machine_pairings.pairing_token`, `machine_pairings.connection_code`
  - The 3 BEFORE INSERT triggers
    (`push_tokens_encrypt_before_write`,
    `live_activity_tokens_encrypt_before_write`,
    `machine_pairings_hash_before_write`) and their trigger functions.
  - The 2 plaintext-column unique constraints
    (`push_tokens_device_token_key`,
    `live_activity_tokens_activity_token_key`).
  - Helper functions `_apns_enc_key()` / `_pairing_pepper()` were
    intentionally kept — they are still called by the public RPCs.
- **Migration 037** — dropped `machine_tokens.machine_secret` entirely.
- **Relay** — `relay/src/index.ts` had the legacy `else` branch
  (`auth.machineSecret` path) removed. The signature flow is now the
  only accepted machine auth. Redeployed via `fly deploy --remote-only`.
- **TarsymacOS Swift** — deleted `machineSecret` property,
  `machineSecretService` keychain identifier, `loadMachineSecret`,
  `saveMachineSecret`, `ensureMachineSecret`, `rotateMachineSecret`,
  and the call site in `registerMachine`. `RelayClient.swift`'s
  `connect()` no longer takes a `machineSecret` parameter. The
  `securityRotateSecret` WSAction handler is now a logged no-op
  pending the keypair rotation follow-up.
- **TarsyWindows** had nothing to remove — Phase 3 already replaced
  the broken `EnsureSecret` stub with `EnsureMachineKey`, so cleanup
  was just a stale comment.
- **Verification in prod** — 9-group post-cleanup script: plaintext
  columns dropped, encrypted/hmac/public_key columns intact, helpers
  preserved, all 8 RPCs preserved, legacy unique constraints gone,
  new unique constraints intact, machine_tokens row count sanity.

### Machine keypair rotation — macOS done, Windows pending

**macOS** — wired. The `security:rotate_machine_secret` WSAction
handler in `DaemonManager.swift` calls `rotateMachineKeypair()`, which:
1. Wipes both Keychain accounts (`p256-se-v1` and `p256-sw-v1`) via
   `MachineKeyStore.rotate()` and creates a fresh keypair in Secure
   Enclave (or the software fallback).
2. Calls `ensureMachinePublicKey` which writes the new public key
   through the `register_machine_public_key` RPC. The RPC's `ON
   CONFLICT (machine_id) DO UPDATE` bumps `rotated_at` to `now()`.
3. Rebuilds the `MachineAuthIdentity` from the new store and calls
   `relayClient.connect(token:machineIdentity:)`, which reconnects the
   WebSocket and sends a fresh signed timestamp signed by the new
   private key.
4. Acks the iOS button with `securityRotateResult` carrying
   `status: ok` (or `error` if any step failed).

The old SE key handle is removed from Keychain; the actual SE key
material becomes orphaned and is GC'd by the OS over time. SE has
plenty of slot capacity for the realistic rotation cadence (a handful
of times per machine lifetime, typically only on a compromise
incident).

**Windows** — `MachineKeyStore.cs` does NOT yet have a `Rotate()`
method, and `TarsyWindows/Services/DaemonManager.cs` has no packet
dispatcher case for `SecurityRotateSecret`. Adding it would mirror the
macOS work:
1. `MachineKeyStore.cs.Rotate()` — open + `Delete()` the existing
   `CngKey` for both providers, then call `LoadOrCreate()`.
2. New `RotateMachineKeypair()` in `MachineService.cs` (or wherever
   the daemon dispatches WSAction packets) that wipes, uploads via
   the same REST RPC the original `EnsureMachineKey` uses, and
   reconnects the relay.

Low priority — only matters if a Windows user wants to rotate from
the iOS UI. Macros the macOS implementation is the one that mattered
because that's the platform with the no-op handler that the iOS UI
already targets.

## Deferred — follow-up work

### Vault secret rotation

There's still no first-class story for rotating
`apns_token_enc_key` or `pairing_hmac_pepper` in
`vault.secrets`. Currently they are immutable for the life of the
project. Plan documented earlier (versioned secret names,
multi-version decrypt fallback, batched re-encrypt). Only relevant on
a compromise incident or regulatory requirement.

### Key rotation infrastructure

Currently no way to rotate `apns_token_enc_key`, `pairing_hmac_pepper`,
or (after Phase 3) per-machine keypairs without data loss. Plan:

- Store as versioned names: `apns_token_enc_key_v1`, `_v2`, etc.
- `_apns_enc_key(version int default current)` helper returns the
  requested version.
- Decrypt wrapper tries `v_current`, falls back to `v_prev` for rows
  encrypted before rotation.
- Background job re-encrypts rows batch-by-batch (`where version = prev
  limit 100`).
- Same pattern for HMAC pepper. Rotation invalidates all active
  pairings, which is fine given the 5-minute TTL.

Low urgency — only needed on compromise incident or regulatory
requirement. Ticket-sized work, not research.

### Multi-device / multi-platform push tokens

Current `push_tokens` schema is `unique(user_id)` → 1 iOS device per
user. iPhone + iPad of the same user: only the most recently registered
device receives push. If we ever want real multi-device push (iOS,
Windows companion, Android, …) the right move is a new
`push_subscribers(user_id, platform, device_identifier, token_enc)`
table. **Not** a retrofit of `push_tokens`. Revisit when product signal
justifies it. TarsyWindows `NotificationService.cs` only inserts into
`push_notifications` today — it does not register for push itself, so
this is purely forward-looking.

### Windows PushNotification registration (if/when we want it)

TarsyWindows currently only emits local toast notifications via
`Windows.UI.Notifications` and sends remote push by inserting into
`push_notifications` (which triggers `send-push` → APNs → iOS device).
If we want Windows users to receive push on the Windows desktop, we'd
implement the WNS (Windows Notification Service) flow and register via
the new `push_subscribers` table above.

### Audit cadence

Re-run the security audit across the Supabase schema and edge functions
after every milestone. The Phase 1 audit caught 7 distinct issues; the
Phase 2 work caught an 8th (the `pg_default_acl` footgun) during
verification. Assume future migrations will introduce new issues too.

## References

- Phase 1 commit: `27c2b15` — security: drop dead realtime pubs and block secrets in ai_context
- Phase 2 commit: `ccf132f` — security: encrypt APNs tokens at rest, HMAC pairing tokens
- Phase 3 commit: `542297c` — security: machine auth via P-256 keypair in Secure Enclave / TPM
- Cleanup commit: see `git log -- supabase/migrations/036_*.sql` — drops legacy plaintext + dual-auth
- Current migrations: `001` … `037` in `supabase/migrations/`
- Relay source: `relay/src/index.ts`
- Key Swift entry points:
  - macOS key store: `TarsymacOS/Sources/Security/MachineKeyStore.swift`
  - macOS daemon: `TarsymacOS/Sources/DaemonManager.swift`
    (`ensureMachinePublicKey`)
  - macOS relay client: `TarsymacOS/Sources/Networking/RelayClient.swift`
    (`connect(token:machineIdentity:)`)
  - iOS push registration: `TarsyiOS/Sources/TarsyiOSApp.swift` (`savePushTokenIfNeeded`)
  - Live activity: `TarsyiOS/Sources/LiveActivity/LiveActivityManager.swift` (`storeLiveActivityToken`)
  - Pairing: `TarsyShared/Sources/TarsyShared/Networking/PairingService.swift` (`generatePairingToken`)
- Windows equivalents:
  - Windows key store: `TarsyWindows/Security/MachineKeyStore.cs`
  - Machine registration: `TarsyWindows/Networking/MachineService.cs` (`EnsureMachineKey`)
  - Relay client: `TarsyWindows/Networking/RelayClient.cs` (signed-timestamp auth payload)
  - Daemon wiring: `TarsyWindows/Services/DaemonManager.cs`
  - Local + remote notifications: `TarsyWindows/Services/NotificationService.cs`
