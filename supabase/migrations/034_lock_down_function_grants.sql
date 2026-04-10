-- Fix a critical Supabase-specific gotcha from migration 033.
--
-- Supabase installs default ACLs (see pg_default_acl) that auto-grant
-- EXECUTE on every new function in the public schema to anon, authenticated,
-- and service_role. Migration 033 used `revoke all on function ... from public`,
-- which only targets the PUBLIC pseudo-role — it does NOT remove the explicit
-- per-role grants injected by the default ACL. The net result was that any
-- authenticated user (not just service_role) could call
-- get_decrypted_push_tokens(other_user_id) and exfiltrate another user's
-- APNs token plaintext.
--
-- This migration explicitly revokes the unintended grants and re-applies the
-- intended ones. Every future migration that creates functions in public must
-- follow the same pattern.
--
-- Verified via has_function_privilege() after applying.

-- ─── Helpers — no role should be able to call these directly ───
revoke all on function public._apns_enc_key()   from anon, authenticated, service_role;
revoke all on function public._pairing_pepper() from anon, authenticated, service_role;

-- ─── Service-role-only decrypt / claim functions ───
revoke all on function public.get_decrypted_push_tokens(uuid)                from anon, authenticated;
revoke all on function public.get_decrypted_live_activity_tokens(uuid, uuid) from anon, authenticated;
revoke all on function public.claim_pairing_by_token(uuid, text)             from anon, authenticated;
revoke all on function public.claim_pairing_by_code(text)                    from anon, authenticated;

-- service_role grants are preserved from 033; re-affirm for clarity
grant execute on function public.get_decrypted_push_tokens(uuid)                to service_role;
grant execute on function public.get_decrypted_live_activity_tokens(uuid, uuid) to service_role;
grant execute on function public.claim_pairing_by_token(uuid, text)             to service_role;
grant execute on function public.claim_pairing_by_code(text)                    to service_role;

-- ─── User-facing register / create functions ───
-- anon has no legitimate reason to call these; only signed-in users should.
revoke all on function public.register_push_token(text)                      from anon;
revoke all on function public.register_live_activity_token(uuid, text)       from anon;
revoke all on function public.create_machine_pairing(uuid)                   from anon;

-- service_role can't usefully call these (auth.uid() is null → 'unauthenticated'),
-- but keeping the grant is harmless and avoids surprise if an edge function
-- ever needs to invoke them on behalf of a user through a different path.
-- authenticated grant is preserved from 033.
