-- Live Activity push tokens for APNs-based Live Activity updates.
-- Each running Live Activity gets a unique push token from ActivityKit.
-- The macOS daemon sends updates via the update-live-activity edge function,
-- which looks up tokens here and pushes content-state to APNs.

create table live_activity_tokens (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid references auth.users(id) on delete cascade not null,
  workspace_id uuid references workspaces(id) on delete cascade not null,
  activity_token text not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_live_activity_tokens_user_workspace
  on live_activity_tokens(user_id, workspace_id);

alter table live_activity_tokens enable row level security;

create policy "Users can read own live activity tokens"
  on live_activity_tokens for select using (auth.uid() = user_id);
create policy "Users can insert own live activity tokens"
  on live_activity_tokens for insert with check (auth.uid() = user_id);
create policy "Users can update own live activity tokens"
  on live_activity_tokens for update using (auth.uid() = user_id);
create policy "Users can delete own live activity tokens"
  on live_activity_tokens for delete using (auth.uid() = user_id);
