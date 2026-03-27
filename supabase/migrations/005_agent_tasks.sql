-- Agent tasks: persistent task tracking across app sessions
create table agent_tasks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade not null default auth.uid(),
  workspace_id uuid references workspaces(id) on delete cascade not null,
  tab_id text not null,
  description text not null,
  status text not null default 'running' check (status in ('running', 'waiting', 'completed', 'error')),
  session_id text,
  engine_type text,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table agent_tasks enable row level security;

create policy "Users can view own tasks"
  on agent_tasks for select using (auth.uid() = user_id);
create policy "Users can insert own tasks"
  on agent_tasks for insert with check (auth.uid() = user_id);
create policy "Users can update own tasks"
  on agent_tasks for update using (auth.uid() = user_id);
create policy "Users can delete own tasks"
  on agent_tasks for delete using (auth.uid() = user_id);

create index idx_agent_tasks_user_id on agent_tasks(user_id);
create index idx_agent_tasks_workspace_id on agent_tasks(workspace_id);
create index idx_agent_tasks_status on agent_tasks(user_id, status) where status in ('running', 'waiting');

create trigger agent_tasks_updated_at
  before update on agent_tasks
  for each row execute function update_updated_at();
