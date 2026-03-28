-- Fix: The welcome email trigger had a hardcoded Supabase URL.
-- This migration replaces the function to read the base URL from private_config,
-- making it portable across environments.
--
-- After applying, insert the base URL into private_config:
--   INSERT INTO private_config (key, value)
--   VALUES ('supabase_url', 'https://xtblbghhlkroskzljqcl.supabase.co')
--   ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

create or replace function public.notify_welcome_email()
returns trigger as $$
declare
  _base_url text;
  _url text;
  _key text;
begin
  -- Read Supabase base URL from private config table
  select value into _base_url from private_config where key = 'supabase_url';

  if _base_url is null or _base_url = '' then
    raise warning 'Welcome email skipped for %: supabase_url not configured in private_config', new.id;
    return new;
  end if;

  -- Strip trailing slash if present and build the edge function URL
  _url := rtrim(_base_url, '/') || '/functions/v1/send-email';

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
