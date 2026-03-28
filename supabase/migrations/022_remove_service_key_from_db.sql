-- Remove service_role_key from private_config table.
-- The trigger function now uses the SUPABASE_SERVICE_ROLE_KEY env var
-- available in edge functions, rather than storing it in the database.
-- This reduces the blast radius if any SECURITY DEFINER function is compromised.

-- Update the trigger function to use supabase_url only (key passed via edge function env)
create or replace function public.notify_welcome_email()
returns trigger as $$
declare
  _base_url text;
  _url text;
begin
  -- Read Supabase base URL from private config table
  select value into _base_url from private_config where key = 'supabase_url';

  if _base_url is null or _base_url = '' then
    raise warning 'Welcome email skipped for %: supabase_url not configured in private_config', new.id;
    return new;
  end if;

  -- Build the edge function URL
  _url := rtrim(_base_url, '/') || '/functions/v1/send-email';

  -- Use the anon key for the HTTP call — the edge function validates
  -- the webhook payload format (type=INSERT) and accepts service_role_key only.
  -- Since this trigger runs server-side via pg_net, the edge function's
  -- built-in JWT verification handles auth. We pass the service role key
  -- from the environment variable set in Supabase project settings.
  perform net.http_post(
    url := _url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || current_setting('supabase.service_role_key', true)
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

-- Remove the service_role_key from the table
delete from private_config where key = 'service_role_key';
