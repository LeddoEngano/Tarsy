-- Final cleanup of the Phase 3 machine-auth migration (035).
--
-- Migration 035 introduced machine_tokens.public_key + the
-- register_machine_public_key RPC, and the relay gained a dual-auth path
-- that accepted both the new signed-timestamp flow and the legacy
-- machine_secret. Migration 035 also made machine_secret nullable so
-- this drop would be possible later.
--
-- With no users in production and the macOS + Windows daemons already
-- uploading public keys and authenticating via signatures, the legacy
-- path is dead code. This migration removes the column entirely. The
-- matching relay change — dropping the machineSecret branch from the
-- auth handler — must be deployed BEFORE this migration runs so the
-- relay doesn't try to SELECT a column that has just been dropped.
--
-- If a future machine somehow arrives with an old build that sends
-- machineSecret, the relay will reject it with "Machine credentials
-- required" (the fallthrough in the new-only code path).

alter table public.machine_tokens drop column if exists machine_secret;
