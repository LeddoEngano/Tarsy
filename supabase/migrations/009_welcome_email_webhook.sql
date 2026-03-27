-- Database webhook: trigger send-email edge function on new profile creation (welcome email)
-- The webhook is created via Supabase Dashboard > Database > Webhooks, not via SQL.
-- This migration documents the required configuration:
--
-- Webhook name:    send-welcome-email
-- Table:           profiles
-- Events:          INSERT
-- Type:            Supabase Edge Function
-- Function:        send-email
-- HTTP method:     POST
-- Headers:         Authorization: Bearer <SUPABASE_SERVICE_ROLE_KEY>
--                  Content-Type: application/json
--
-- Required Supabase secrets (set via CLI or Dashboard):
--   RESEND_API_KEY     - Resend API key
--   RESEND_FROM_EMAIL  - Sender address (e.g., "Tarsy <hello@tarsy.dev>")
--
-- To set secrets via CLI:
--   supabase secrets set RESEND_API_KEY=re_xxxxx
--   supabase secrets set RESEND_FROM_EMAIL="Tarsy <hello@tarsy.dev>"

-- Create the webhook via pg_net (same pattern as push notifications)
-- Note: Supabase database webhooks use pg_net under the hood.
-- If your project supports supabase_functions.http_request, use the trigger approach below.
-- Otherwise, create the webhook manually in the Supabase Dashboard.

create or replace function public.notify_welcome_email()
returns trigger as $$
declare
  edge_function_url text;
  service_role_key text;
begin
  edge_function_url := current_setting('app.settings.supabase_url', true) || '/functions/v1/send-email';
  service_role_key := current_setting('app.settings.service_role_key', true);

  -- Use pg_net to call the edge function asynchronously
  perform net.http_post(
    url := edge_function_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || service_role_key
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
