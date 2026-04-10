# Tarsy Security Roadmap

Canonical status of the DB / secrets hardening work that started from the
April 2026 audit. Covers what's shipped, what's in flight, and what's
deferred. Keep this file up to date as phases land.

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

## In flight

### Phase 3 — `machine_secret` → public-key crypto + Secure Enclave / TPM

Current state: each machine generates a `UUID()` as its `machine_secret`,
stores it in Keychain (macOS) / Credential Manager (Windows), upserts
plaintext into `machine_tokens`, and the relay verifies equality with
`crypto.timingSafeEqual`. A DB leak lets the attacker impersonate any
machine as its legitimate owner (full access to remote control, agent
dispatch, etc.).

Target: asymmetric challenge-response auth. Private key lives in the
hardware root of trust (Apple Secure Enclave on macOS, Windows TPM via
Microsoft Platform Crypto Provider on Windows), non-exportable by
design. Supabase stores only the public key. Relay verifies a signature
over a signed timestamp on each connect — no shared secret ever travels.

Detailed plan lives in `.claude/plans/<phase3-plan>.md` while in progress.
Summary of the target flow:

1. On first run after upgrade, machine generates a **P-256 ECDSA** keypair
   (the only algorithm supported by Secure Enclave) in the secure store,
   uploads public key to `machine_tokens.public_key`. Old
   `machine_secret` kept populated for transition fallback.
2. On relay connect, machine sends
   `{action: "auth", token, role: "machine", machine_id, timestamp, signature}`
   where `signature = sign(timestamp || machine_id || jwt_sub, private_key)`.
3. Relay fetches public key for the machine, verifies signature, accepts
   if timestamp is within ±60s of server clock.
4. Relay keeps dual-auth (old `machineSecret` path + new signature path)
   during rollout. Legacy clients still work. New clients prefer the
   signature path.
5. After adoption, Migration 036 drops `machine_secret`; relay drops
   dual-auth.

Platform-specific key storage:
- **macOS ≥14 (Apple Silicon or Intel+T2)**: `SecKeyCreateRandomKey` with
  `kSecAttrTokenIDSecureEnclave` + `kSecAccessControlPrivateKeyUsage`.
  **No** `userPresence` flag → silent signing, no password/biometric
  prompt (honours the no-prompts-on-remote-mac rule from project
  feedback).
- **macOS Intel without T2 (rare on macOS 14+)**: Keychain-only fallback
  with `kSecAttrIsPermanent=true` + `kSecAttrAccessibleAfterFirstUnlock`.
  Not hardware-backed, but still non-exportable from the keychain.
- **Windows with TPM 2.0**: `CngKey.Create(CngAlgorithm.ECDsaP256, ...,
  Provider = MicrosoftPlatformCryptoProvider)` — hardware-backed via TPM.
- **Windows without TPM**: `MicrosoftSoftwareKeyStorageProvider` +
  `CngExportPolicies.None` + DPAPI persistence. Non-exportable from the
  process, encrypted at rest for the current Windows user.

## Deferred — follow-up work

### Migration 035 — drop plaintext columns from Phase 2

After iOS and macOS releases using the Phase 2 RPCs have adopted in
production (verified by watching `push_tokens.device_token` stay null
for N days), drop:

- `push_tokens.device_token` column + `push_tokens_device_token_key`
  unique index.
- `live_activity_tokens.activity_token` column +
  `live_activity_tokens_activity_token_key` unique index.
- `machine_pairings.pairing_token` and `machine_pairings.connection_code`
  columns.
- BEFORE INSERT triggers:
  `_push_tokens_encrypt_trigger`,
  `_live_activity_tokens_encrypt_trigger`,
  `_machine_pairings_hash_trigger` (and their attached triggers).

Low complication — the encrypted/HMAC columns are already fully
populated. Main gate is app release adoption.

### Migration 036 — drop `machine_tokens.machine_secret`

Parallel to 035 but for Phase 3. Gated on full adoption of the new
public-key auth across both macOS and Windows.

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
- Current migrations: `001` … `034` in `supabase/migrations/`
- Relay source: `relay/src/index.ts`
- Key Swift entry points:
  - macOS daemon: `TarsymacOS/Sources/DaemonManager.swift`
    (`ensureMachineSecret` at L2206, `rotateMachineSecret` at L2249)
  - iOS push registration: `TarsyiOS/Sources/TarsyiOSApp.swift:45`
  - Live activity: `TarsyiOS/Sources/LiveActivity/LiveActivityManager.swift:313`
  - Pairing: `TarsyShared/Sources/TarsyShared/Networking/PairingService.swift:32`
- Windows equivalents:
  - `TarsyWindows/Services/DaemonManager.cs` (machine registration)
  - `TarsyWindows/Networking/RelayClient.cs` (auth payload)
  - `TarsyWindows/Services/NotificationService.cs` (push)
