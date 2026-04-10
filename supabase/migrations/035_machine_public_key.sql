-- Phase 3: add per-machine asymmetric-key authentication alongside the
-- legacy shared-secret flow. Each machine generates a P-256 ECDSA keypair
-- in its hardware root of trust (Secure Enclave on macOS, TPM on Windows),
-- uploads the public key via register_machine_public_key(), and from then
-- on proves its identity by signing a timestamp+machine_id+userId tuple
-- that the relay verifies.
--
-- The old machine_secret column stays populated during the transition so
-- existing DMG installs keep working. Migration 036 (follow-up, after app
-- adoption) drops it.
--
-- Naming / grant pattern mirrors the Phase 2 migrations (033/034), in
-- particular with explicit REVOKE from anon/authenticated because the
-- Supabase pg_default_acl auto-grants EXECUTE to every role in that set.

-- ─────────────────────────────────────────────────────────────
-- 1. Schema changes
-- ─────────────────────────────────────────────────────────────

alter table public.machine_tokens
  add column public_key bytea,
  add column key_algorithm text not null default 'p256-ecdsa',
  alter column machine_secret drop not null;

-- Fast lookup for relay: (user_id, machine_id) → public_key
create index if not exists idx_machine_tokens_user_machine
  on public.machine_tokens(user_id, machine_id)
  where public_key is not null;

comment on column public.machine_tokens.public_key is
  'DER-encoded SubjectPublicKeyInfo (SPKI) for P-256 ECDSA (~91 bytes). The corresponding private key lives in Secure Enclave (macOS) or TPM/DPAPI (Windows) on the machine and is never transmitted.';
comment on column public.machine_tokens.key_algorithm is
  'Currently always p256-ecdsa; reserved for future curves.';
comment on column public.machine_tokens.machine_secret is
  'Legacy shared secret, kept nullable during the public-key migration. Will be dropped in migration 036 once all clients have uploaded a public_key.';

-- ─────────────────────────────────────────────────────────────
-- 2. RPC for the machine daemon to upload its public key
-- ─────────────────────────────────────────────────────────────

create or replace function public.register_machine_public_key(
  p_machine_id uuid,
  p_public_key bytea
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'unauthenticated';
  end if;
  -- SPKI for P-256 ECDSA is ~91 bytes; accept a small range to allow for
  -- future curves or encoding variance without rewriting this function.
  if p_public_key is null
     or octet_length(p_public_key) < 50
     or octet_length(p_public_key) > 200 then
    raise exception 'invalid public key length';
  end if;
  -- Caller must own the machine
  if not exists (
    select 1 from public.machines
    where id = p_machine_id and user_id = v_uid
  ) then
    raise exception 'forbidden';
  end if;
  insert into public.machine_tokens (user_id, machine_id, public_key, key_algorithm)
  values (v_uid, p_machine_id, p_public_key, 'p256-ecdsa')
  on conflict (machine_id) do update
    set public_key = excluded.public_key,
        key_algorithm = excluded.key_algorithm,
        rotated_at = now()
    where public.machine_tokens.user_id = v_uid;
end
$$;

-- Lock down grants explicitly — the pg_default_acl trick from Phase 2 /
-- migration 034 silently grants EXECUTE to anon/authenticated/service_role
-- on every new public-schema function. REVOKE FROM public only targets the
-- PUBLIC pseudo-role, not those per-role grants. Redo them here.
revoke all on function public.register_machine_public_key(uuid, bytea) from public, anon, service_role;
grant execute on function public.register_machine_public_key(uuid, bytea) to authenticated;
