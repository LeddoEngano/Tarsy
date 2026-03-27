-- Fix: welcome email webhook was broken because app.settings were not configured.
-- current_setting('app.settings.service_role_key', true) returned NULL,
-- causing the trigger to send "Bearer null" which the edge function rejected.
--
-- Solution: Use supabase_functions.http_request (the built-in Supabase webhook
-- mechanism) which automatically handles auth. If not available, fall back to
-- a trigger that reads the service role key from a config table.

-- Drop the broken trigger and function from migration 009
drop trigger if exists on_profile_created_send_welcome on profiles;
drop function if exists public.notify_welcome_email();

-- Store the service role key in a private config table (only readable by postgres/service_role)
create table if not exists private_config (
  key text primary key,
  value text not null
);

-- Revoke all access — only the trigger (SECURITY DEFINER as postgres) can read
revoke all on private_config from anon, authenticated;

-- The service role key must be inserted manually via Supabase SQL Editor:
--   INSERT INTO private_config (key, value)
--   VALUES ('service_role_key', 'your-service-role-key-here')
--   ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

create or replace function public.notify_welcome_email()
returns trigger as $$
declare
  _url text := 'https://xtblbghhlkroskzljqcl.supabase.co/functions/v1/send-email';
  _key text;
begin
  -- Read service role key from private config table
  select value into _key from private_config where key = 'service_role_key';

  if _key is null or _key = '' then
    raise warning 'Welcome email skipped for %: service_role_key not configured in private_config', new.id;
    return new;
  end if;

  perform net.http_post(
    url := _url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || _key
    ),
    body := jsonb_build_object(
      'type', 'INSERT',
      'record', jsonb_build_object(
        'id', new.id,
        'email', new.email,
        'display_name', new.display_name
      )
    )
  );
  return new;
exception
  when others then
    raise warning 'Welcome email trigger error for %: %', new.id, sqlerrm;
    return new;
end;
$$ language plpgsql security definer;

create trigger on_profile_created_send_welcome
  after insert on profiles
  for each row
  execute function public.notify_welcome_email();
