-- Phase 2 of the DB security hardening: eliminate plaintext storage of
-- APNs tokens (device_token, activity_token) and pairing tokens.
--
-- APNs tokens must be recoverable (APNs HTTP API needs the plaintext), so
-- they are encrypted with pgp_sym_encrypt using an AES passphrase kept in
-- vault.secrets. Pairing tokens are looked up by equality, so they use
-- HMAC-SHA256 with a server-side pepper — deterministic lookup, irreversible
-- on DB leak.
--
-- All crypto lives in SECURITY DEFINER SQL functions that read the key/pepper
-- from vault.decrypted_secrets. Apps and edge functions call public RPCs:
--
--   Client → public.register_push_token(p_token)
--   Client → public.register_live_activity_token(p_workspace_id, p_token)
--   Client → public.create_machine_pairing(p_machine_id) → {pairing_token, connection_code, expires_at}
--   service_role → public.get_decrypted_push_tokens(p_user_id)
--   service_role → public.get_decrypted_live_activity_tokens(p_user_id, p_workspace_id)
--   service_role → public.claim_pairing_by_token(p_machine_id, p_token) → machine_pairings.id
--   service_role → public.claim_pairing_by_code(p_code) → machine_pairings.id
--
-- BEFORE INSERT triggers cover the legacy code path: old clients still
-- writing plaintext get their values encrypted/hashed in the trigger and
-- the plaintext columns are set to NULL so the raw secret never persists.
-- The old unique constraints on plaintext columns are kept (nullable) so
-- legacy upsert clauses (onConflict: device_token / activity_token) still
-- parse, even though the conflict check is effectively neutralised by the
-- NULL values. A subsequent migration 034 will drop those columns entirely
-- once iOS/macOS releases have adopted the new RPCs.

-- ─────────────────────────────────────────────────────────────
-- 1. Schema changes
-- ─────────────────────────────────────────────────────────────

alter table public.push_tokens
  alter column device_token drop not null,
  add column device_token_enc bytea;

alter table public.live_activity_tokens
  alter column activity_token drop not null,
  add column activity_token_enc bytea;

alter table public.machine_pairings
  alter column pairing_token drop not null,
  alter column connection_code drop not null,
  add column pairing_token_hmac bytea,
  add column connection_code_hmac bytea;

-- New unique keys for RPC dedup (1 APNs device per user; 1 LA token per user+workspace).
-- Old unique on plaintext columns is intentionally KEPT to avoid breaking PostgREST
-- onConflict validation for legacy clients during the transition window.
alter table public.push_tokens
  add constraint push_tokens_user_id_key unique (user_id);

alter table public.live_activity_tokens
  add constraint live_activity_tokens_user_workspace_key unique (user_id, workspace_id);

-- Indexes for HMAC lookup
create index idx_machine_pairings_token_hmac
  on public.machine_pairings(pairing_token_hmac);
create index idx_machine_pairings_code_hmac
  on public.machine_pairings(connection_code_hmac);

-- ─────────────────────────────────────────────────────────────
-- 2. Vault secrets (generated at migration time, unique per env)
-- ─────────────────────────────────────────────────────────────

do $$
declare
  v_enc_key text := encode(extensions.gen_random_bytes(32), 'base64');
  v_pepper text := encode(extensions.gen_random_bytes(32), 'base64');
begin
  perform vault.create_secret(
    v_enc_key,
    'apns_token_enc_key',
    'AES passphrase for pgp_sym_encrypt of APNs device/activity tokens. Rotating this requires re-encrypting all rows.'
  );
  perform vault.create_secret(
    v_pepper,
    'pairing_hmac_pepper',
    'HMAC-SHA256 pepper for machine_pairings tokens/codes. Rotating this invalidates all active pairings.'
  );
end $$;

-- ─────────────────────────────────────────────────────────────
-- 3. Helper functions — read secrets from vault
-- ─────────────────────────────────────────────────────────────
-- SECURITY DEFINER so they run as postgres (owner of vault.decrypted_secrets).
-- REVOKEd from public; only other SECURITY DEFINER functions reach them.

create or replace function public._apns_enc_key()
returns text
language sql
security definer
stable
set search_path = vault, public
as $$
  select decrypted_secret::text
  from vault.decrypted_secrets
  where name = 'apns_token_enc_key'
  limit 1
$$;

revoke all on function public._apns_enc_key() from public;

-- Pepper is stored as a base64 text string in vault. Keeping it as text here
-- lets us call the text-text-text overload of extensions.hmac directly.
-- (pgcrypto only provides hmac(text,text,text) and hmac(bytea,bytea,text);
-- there is no mixed text/bytea signature.)
create or replace function public._pairing_pepper()
returns text
language sql
security definer
stable
set search_path = vault, public
as $$
  select decrypted_secret::text
  from vault.decrypted_secrets
  where name = 'pairing_hmac_pepper'
  limit 1
$$;

revoke all on function public._pairing_pepper() from public;

-- ─────────────────────────────────────────────────────────────
-- 4. BEFORE INSERT/UPDATE triggers (legacy-client compat)
-- ─────────────────────────────────────────────────────────────

create or replace function public._push_tokens_encrypt_trigger()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if new.device_token is not null and new.device_token_enc is null then
    new.device_token_enc := extensions.pgp_sym_encrypt(new.device_token, public._apns_enc_key());
  end if;
  -- plaintext never persists
  new.device_token := null;
  return new;
end
$$;

drop trigger if exists push_tokens_encrypt_before_write on public.push_tokens;
create trigger push_tokens_encrypt_before_write
  before insert or update on public.push_tokens
  for each row execute function public._push_tokens_encrypt_trigger();

create or replace function public._live_activity_tokens_encrypt_trigger()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if new.activity_token is not null and new.activity_token_enc is null then
    new.activity_token_enc := extensions.pgp_sym_encrypt(new.activity_token, public._apns_enc_key());
  end if;
  new.activity_token := null;
  return new;
end
$$;

drop trigger if exists live_activity_tokens_encrypt_before_write on public.live_activity_tokens;
create trigger live_activity_tokens_encrypt_before_write
  before insert or update on public.live_activity_tokens
  for each row execute function public._live_activity_tokens_encrypt_trigger();

create or replace function public._machine_pairings_hash_trigger()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_pepper text := public._pairing_pepper();
begin
  if new.pairing_token is not null and new.pairing_token_hmac is null then
    new.pairing_token_hmac := extensions.hmac(new.pairing_token, v_pepper, 'sha256');
  end if;
  if new.connection_code is not null and new.connection_code_hmac is null then
    new.connection_code_hmac := extensions.hmac(
      upper(regexp_replace(new.connection_code, '-', '', 'g')),
      v_pepper,
      'sha256'
    );
  end if;
  new.pairing_token := null;
  new.connection_code := null;
  return new;
end
$$;

drop trigger if exists machine_pairings_hash_before_write on public.machine_pairings;
create trigger machine_pairings_hash_before_write
  before insert or update on public.machine_pairings
  for each row execute function public._machine_pairings_hash_trigger();

-- ─────────────────────────────────────────────────────────────
-- 5. Backfill existing rows (encrypt / hash in place)
-- ─────────────────────────────────────────────────────────────

-- push_tokens: encrypt existing plaintext (there are ~10 rows in prod)
update public.push_tokens
   set device_token_enc = extensions.pgp_sym_encrypt(device_token, public._apns_enc_key()),
       device_token = null
 where device_token_enc is null
   and device_token is not null;

-- live_activity_tokens: 0 rows in prod today, but handle defensively
update public.live_activity_tokens
   set activity_token_enc = extensions.pgp_sym_encrypt(activity_token, public._apns_enc_key()),
       activity_token = null
 where activity_token_enc is null
   and activity_token is not null;

-- machine_pairings: drop anything already expired (TTL is 5 min anyway)
delete from public.machine_pairings where expires_at < now();

update public.machine_pairings
   set pairing_token_hmac = extensions.hmac(pairing_token, public._pairing_pepper(), 'sha256'),
       connection_code_hmac = extensions.hmac(
         upper(regexp_replace(connection_code, '-', '', 'g')),
         public._pairing_pepper(),
         'sha256'
       ),
       pairing_token = null,
       connection_code = null
 where pairing_token_hmac is null
   and pairing_token is not null;

-- ─────────────────────────────────────────────────────────────
-- 6. Public RPCs — called by authenticated clients (iOS/macOS/Windows)
-- ─────────────────────────────────────────────────────────────

create or replace function public.register_push_token(p_token text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'unauthenticated';
  end if;
  if p_token is null or length(p_token) < 10 then
    raise exception 'invalid token';
  end if;
  insert into public.push_tokens (user_id, device_token_enc)
  values (v_uid, extensions.pgp_sym_encrypt(p_token, public._apns_enc_key()))
  on conflict (user_id) do update
     set device_token_enc = excluded.device_token_enc;
end
$$;

revoke all on function public.register_push_token(text) from public;
grant execute on function public.register_push_token(text) to authenticated;

create or replace function public.register_live_activity_token(p_workspace_id uuid, p_token text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'unauthenticated';
  end if;
  if p_token is null or length(p_token) < 10 then
    raise exception 'invalid token';
  end if;
  if not exists (
    select 1 from public.workspaces
    where id = p_workspace_id and user_id = v_uid
  ) then
    raise exception 'forbidden';
  end if;
  insert into public.live_activity_tokens (user_id, workspace_id, activity_token_enc, updated_at)
  values (v_uid, p_workspace_id, extensions.pgp_sym_encrypt(p_token, public._apns_enc_key()), now())
  on conflict (user_id, workspace_id) do update
     set activity_token_enc = excluded.activity_token_enc,
         updated_at = excluded.updated_at;
end
$$;

revoke all on function public.register_live_activity_token(uuid, text) from public;
grant execute on function public.register_live_activity_token(uuid, text) to authenticated;

create or replace function public.create_machine_pairing(p_machine_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
  v_token text := encode(extensions.gen_random_bytes(32), 'hex');
  v_code text := upper(encode(extensions.gen_random_bytes(6), 'hex'));
  v_expiry timestamptz := now() + interval '5 minutes';
  v_pepper text := public._pairing_pepper();
begin
  if v_uid is null then
    raise exception 'unauthenticated';
  end if;
  if not exists (
    select 1 from public.machines
    where id = p_machine_id and user_id = v_uid
  ) then
    raise exception 'forbidden';
  end if;
  -- clear any previous pairing for this machine (one-at-a-time semantics)
  delete from public.machine_pairings where machine_id = p_machine_id;
  insert into public.machine_pairings (machine_id, pairing_token_hmac, connection_code_hmac, expires_at)
  values (
    p_machine_id,
    extensions.hmac(v_token, v_pepper, 'sha256'),
    extensions.hmac(v_code, v_pepper, 'sha256'),
    v_expiry
  );
  return jsonb_build_object(
    'pairing_token', v_token,
    'connection_code', v_code,
    'expires_at', v_expiry
  );
end
$$;

revoke all on function public.create_machine_pairing(uuid) from public;
grant execute on function public.create_machine_pairing(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- 7. Service-role RPCs — called by edge functions only
-- ─────────────────────────────────────────────────────────────

create or replace function public.get_decrypted_push_tokens(p_user_id uuid)
returns table(device_token text)
language plpgsql
security definer
stable
set search_path = public, extensions
as $$
begin
  return query
    select extensions.pgp_sym_decrypt(pt.device_token_enc, public._apns_enc_key())
    from public.push_tokens pt
    where pt.user_id = p_user_id
      and pt.device_token_enc is not null;
end
$$;

revoke all on function public.get_decrypted_push_tokens(uuid) from public;
grant execute on function public.get_decrypted_push_tokens(uuid) to service_role;

create or replace function public.get_decrypted_live_activity_tokens(p_user_id uuid, p_workspace_id uuid)
returns table(activity_token text)
language plpgsql
security definer
stable
set search_path = public, extensions
as $$
begin
  return query
    select extensions.pgp_sym_decrypt(lat.activity_token_enc, public._apns_enc_key())
    from public.live_activity_tokens lat
    where lat.user_id = p_user_id
      and lat.workspace_id = p_workspace_id
      and lat.activity_token_enc is not null;
end
$$;

revoke all on function public.get_decrypted_live_activity_tokens(uuid, uuid) from public;
grant execute on function public.get_decrypted_live_activity_tokens(uuid, uuid) to service_role;

create or replace function public.claim_pairing_by_token(p_machine_id uuid, p_token text)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hmac bytea := extensions.hmac(p_token, public._pairing_pepper(), 'sha256');
  v_id uuid;
begin
  -- (pepper is text; hmac returns bytea)
  select id into v_id
  from public.machine_pairings
  where machine_id = p_machine_id
    and pairing_token_hmac = v_hmac
    and expires_at > now()
  limit 1;
  return v_id;
end
$$;

revoke all on function public.claim_pairing_by_token(uuid, text) from public;
grant execute on function public.claim_pairing_by_token(uuid, text) to service_role;

create or replace function public.claim_pairing_by_code(p_code text)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_normalized text := upper(regexp_replace(coalesce(p_code, ''), '-', '', 'g'));
  v_hmac bytea;
  v_id uuid;
begin
  if length(v_normalized) = 0 then
    return null;
  end if;
  v_hmac := extensions.hmac(v_normalized, public._pairing_pepper(), 'sha256');
  select id into v_id
  from public.machine_pairings
  where connection_code_hmac = v_hmac
    and expires_at > now()
  limit 1;
  return v_id;
end
$$;

revoke all on function public.claim_pairing_by_code(text) from public;
grant execute on function public.claim_pairing_by_code(text) to service_role;
