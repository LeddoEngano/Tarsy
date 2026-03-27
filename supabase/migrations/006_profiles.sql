-- Profiles table: single source of truth for user data and preferences
create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  display_name text,
  avatar_url text,

  -- Preferences (synced across devices)
  voice_language text default 'en',
  agent_permissions jsonb default '{"claude":"dangerous","codex":"dangerous","gemini":"dangerous","aider":"dangerous"}'::jsonb,

  -- Subscription
  is_pro boolean not null default false,
  subscription_status text not null default 'inactive' check (subscription_status in ('inactive', 'trial', 'active', 'cancelled')),
  subscription_end_date timestamptz,

  -- Onboarding
  onboarded boolean not null default false,

  -- Timestamps
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table profiles enable row level security;

-- Indexes
create index idx_profiles_email on profiles(email);

-- RLS
create policy "Users can view own profile"
  on profiles for select using (auth.uid() = id);
create policy "Users can update own profile"
  on profiles for update using (auth.uid() = id);
-- Insert is handled by the trigger (SECURITY DEFINER), not by the user directly
-- But allow insert for edge cases (manual profile creation)
create policy "Users can insert own profile"
  on profiles for insert with check (auth.uid() = id);

-- Auto-create profile on signup
create or replace function public.handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (
    id, email, display_name, avatar_url, created_at, updated_at
  )
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', ''),
    coalesce(new.raw_user_meta_data->>'avatar_url', ''),
    now(),
    now()
  )
  on conflict (id) do nothing;
  return new;
exception
  when others then
    raise warning 'Error creating profile for %: %', new.id, sqlerrm;
    return new;
end;
$$ language plpgsql security definer;

create trigger on_auth_user_created
  after insert on auth.users
  for each row
  execute function public.handle_new_user();

-- Updated_at trigger (reuse existing function if available, otherwise create)
do $$
begin
  if not exists (select 1 from pg_proc where proname = 'update_updated_at') then
    create function update_updated_at() returns trigger as $fn$
    begin
      new.updated_at = now();
      return new;
    end;
    $fn$ language plpgsql;
  end if;
end $$;

create trigger profiles_updated_at
  before update on profiles
  for each row execute function update_updated_at();

-- Enable realtime
alter publication supabase_realtime add table profiles;

-- Backfill profiles for existing users
insert into profiles (id, email, display_name, avatar_url, created_at, updated_at)
select
  id,
  coalesce(email, ''),
  coalesce(raw_user_meta_data->>'full_name', ''),
  coalesce(raw_user_meta_data->>'avatar_url', ''),
  created_at,
  now()
from auth.users
where not exists (select 1 from profiles where profiles.id = auth.users.id)
on conflict (id) do nothing;
