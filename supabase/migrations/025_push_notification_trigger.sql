-- Replace the Supabase Dashboard webhook with a pg_net database trigger.
-- This is more reliable and version-controlled. The Dashboard webhook
-- was returning 401 because it wasn't sending the correct Authorization header.

-- Create trigger function that calls the send-push edge function via pg_net
create or replace function public.notify_push_notification()
returns trigger as $$
declare
  _base_url text;
  _url text;
  _service_key text;
begin
  -- Only fire for new, unsent notifications
  if new.sent = true then
    return new;
  end if;

  -- Read Supabase base URL from private config
  select value into _base_url from private_config where key = 'supabase_url';

  if _base_url is null or _base_url = '' then
    raise warning 'Push notification skipped for %: supabase_url not configured', new.id;
    return new;
  end if;

  -- Get service role key from Supabase runtime setting
  _service_key := current_setting('supabase.service_role_key', true);

  if _service_key is null or _service_key = '' then
    raise warning 'Push notification skipped for %: service_role_key not available', new.id;
    return new;
  end if;

  _url := rtrim(_base_url, '/') || '/functions/v1/send-push';

  -- Call the edge function via pg_net
  perform net.http_post(
    url := _url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || _service_key
    ),
    body := jsonb_build_object(
      'record', jsonb_build_object(
        'id', new.id,
        'user_id', new.user_id,
        'title', new.title,
        'body', new.body,
        'sent', new.sent,
        'workspace_id', new.workspace_id
      )
    )
  );

  return new;
exception
  when others then
    raise warning 'Push notification trigger error for %: %', new.id, sqlerrm;
    return new;
end;
$$ language plpgsql security definer;

-- Create the trigger on push_notifications table
drop trigger if exists on_push_notification_insert on push_notifications;
create trigger on_push_notification_insert
  after insert on push_notifications
  for each row
  execute function notify_push_notification();
