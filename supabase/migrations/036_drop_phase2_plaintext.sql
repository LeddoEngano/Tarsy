-- Final cleanup of the Phase 2 encryption migration (033).
--
-- The plaintext columns and the "write-and-encrypt" triggers were kept as
-- a transition bridge so that clients using the old direct-INSERT path
-- kept working while the app releases rolled out. Since we have no users
-- in production yet, there is no transition to protect — the iOS, macOS,
-- and Windows clients already write via the Phase 2 RPCs
-- (register_push_token, register_live_activity_token, create_machine_pairing),
-- and the edge functions read via the service-role RPCs
-- (get_decrypted_push_tokens, get_decrypted_live_activity_tokens,
-- claim_pairing_by_token, claim_pairing_by_code).
--
-- This migration tears down every remaining reference to plaintext:
--   * drops the 3 BEFORE INSERT triggers that encrypted/hashed on write
--   * drops the 3 trigger functions they used
--   * drops the 4 plaintext columns
--   * drops the 2 unique constraints that were anchored on plaintext
--     columns (push_tokens_device_token_key, live_activity_tokens_activity_token_key)
--
-- The helper functions _apns_enc_key() and _pairing_pepper() remain —
-- they are called by the public RPCs that are still live.

-- ─── 1. Drop BEFORE INSERT triggers ───
drop trigger if exists push_tokens_encrypt_before_write         on public.push_tokens;
drop trigger if exists live_activity_tokens_encrypt_before_write on public.live_activity_tokens;
drop trigger if exists machine_pairings_hash_before_write        on public.machine_pairings;

-- ─── 2. Drop trigger functions (now orphaned) ───
drop function if exists public._push_tokens_encrypt_trigger();
drop function if exists public._live_activity_tokens_encrypt_trigger();
drop function if exists public._machine_pairings_hash_trigger();

-- ─── 3. Drop legacy unique constraints anchored on plaintext columns ───
alter table public.push_tokens           drop constraint if exists push_tokens_device_token_key;
alter table public.live_activity_tokens  drop constraint if exists live_activity_tokens_activity_token_key;

-- ─── 4. Drop the plaintext columns ───
alter table public.push_tokens           drop column if exists device_token;
alter table public.live_activity_tokens  drop column if exists activity_token;
alter table public.machine_pairings      drop column if exists pairing_token;
alter table public.machine_pairings      drop column if exists connection_code;
