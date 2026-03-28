-- Machine authentication tokens for relay role verification.
-- Each machine gets a unique secret generated during onboarding,
-- which must be presented when connecting to the relay as role "machine".
-- This prevents machine impersonation even with a stolen JWT.

create table if not exists machine_tokens (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,
    machine_id uuid not null references machines(id) on delete cascade,
    machine_secret text not null,
    created_at timestamptz not null default now(),
    rotated_at timestamptz,
    unique (machine_id)
);

-- RLS: users can only access their own machine tokens
alter table machine_tokens enable row level security;

create policy "Users can read own machine tokens"
    on machine_tokens for select
    using (auth.uid() = user_id);

create policy "Users can insert own machine tokens"
    on machine_tokens for insert
    with check (auth.uid() = user_id);

create policy "Users can update own machine tokens"
    on machine_tokens for update
    using (auth.uid() = user_id);
