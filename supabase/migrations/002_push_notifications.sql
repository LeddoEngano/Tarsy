-- Push notifications queue (triggers Edge Function to send APNs)
create table push_notifications (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid references auth.users(id) on delete cascade not null default auth.uid(),
  title text not null,
  body text not null,
  sent boolean not null default false,
  created_at timestamptz not null default now()
);

alter table push_notifications enable row level security;

create policy "Users can insert own notifications"
  on push_notifications for insert with check (auth.uid() = user_id);

create policy "Users can view own notifications"
  on push_notifications for select using (auth.uid() = user_id);

create index idx_push_notifications_user_id on push_notifications(user_id);
create index idx_push_notifications_unsent on push_notifications(sent) where sent = false;
