-- Enable UUID extension
create extension if not exists "uuid-ossp";

-- Machines table
create table machines (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid references auth.users(id) on delete cascade not null,
  hostname text not null,
  tailscale_ip text not null,
  status text not null default 'offline' check (status in ('online', 'offline')),
  last_seen_at timestamptz,
  created_at timestamptz not null default now()
);

-- Workspaces table
create table workspaces (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid references auth.users(id) on delete cascade not null,
  machine_id uuid references machines(id) on delete cascade not null,
  name text not null,
  repo_url text,
  local_path text not null,
  stack text not null default 'web' check (stack in ('web', 'mobile', 'backend', 'fullstack')),
  status text not null default 'idle' check (status in ('idle', 'starting', 'running', 'error')),
  current_branch text,
  dev_server_command text,
  ai_context text,
  config jsonb default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Chat messages table
create table chat_messages (
  id uuid primary key default uuid_generate_v4(),
  workspace_id uuid references workspaces(id) on delete cascade not null,
  tab_id text not null,
  role text not null check (role in ('user', 'assistant')),
  content text not null,
  created_at timestamptz not null default now()
);

-- Push notification tokens
create table push_tokens (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid references auth.users(id) on delete cascade not null,
  device_token text not null unique,
  created_at timestamptz not null default now()
);

-- Indexes
create index idx_machines_user_id on machines(user_id);
create index idx_workspaces_user_id on workspaces(user_id);
create index idx_workspaces_machine_id on workspaces(machine_id);
create index idx_chat_messages_workspace_id on chat_messages(workspace_id);
create index idx_chat_messages_tab_id on chat_messages(workspace_id, tab_id);
create index idx_push_tokens_user_id on push_tokens(user_id);

-- Row Level Security
alter table machines enable row level security;
alter table workspaces enable row level security;
alter table chat_messages enable row level security;
alter table push_tokens enable row level security;

-- Machines policies
create policy "Users can view own machines"
  on machines for select using (auth.uid() = user_id);
create policy "Users can insert own machines"
  on machines for insert with check (auth.uid() = user_id);
create policy "Users can update own machines"
  on machines for update using (auth.uid() = user_id);
create policy "Users can delete own machines"
  on machines for delete using (auth.uid() = user_id);

-- Workspaces policies
create policy "Users can view own workspaces"
  on workspaces for select using (auth.uid() = user_id);
create policy "Users can insert own workspaces"
  on workspaces for insert with check (auth.uid() = user_id);
create policy "Users can update own workspaces"
  on workspaces for update using (auth.uid() = user_id);
create policy "Users can delete own workspaces"
  on workspaces for delete using (auth.uid() = user_id);

-- Chat messages policies (via workspace ownership)
create policy "Users can view own chat messages"
  on chat_messages for select using (
    exists (select 1 from workspaces where workspaces.id = chat_messages.workspace_id and workspaces.user_id = auth.uid())
  );
create policy "Users can insert own chat messages"
  on chat_messages for insert with check (
    exists (select 1 from workspaces where workspaces.id = chat_messages.workspace_id and workspaces.user_id = auth.uid())
  );

-- Push tokens policies
create policy "Users can view own push tokens"
  on push_tokens for select using (auth.uid() = user_id);
create policy "Users can insert own push tokens"
  on push_tokens for insert with check (auth.uid() = user_id);
create policy "Users can delete own push tokens"
  on push_tokens for delete using (auth.uid() = user_id);

-- Enable realtime for status updates
alter publication supabase_realtime add table machines;
alter publication supabase_realtime add table workspaces;

-- Updated_at trigger
create or replace function update_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

create trigger workspaces_updated_at
  before update on workspaces
  for each row execute function update_updated_at();
