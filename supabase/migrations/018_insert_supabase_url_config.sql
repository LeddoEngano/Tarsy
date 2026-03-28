-- Insert the Supabase project URL into private_config for use by trigger functions.
-- This replaces the previously hardcoded URL in notify_welcome_email().

insert into private_config (key, value)
values ('supabase_url', 'https://xtblbghhlkroskzljqcl.supabase.co')
on conflict (key) do update set value = excluded.value;
