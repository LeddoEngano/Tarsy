-- Add workspace_id to push_notifications for deep linking
alter table push_notifications add column workspace_id uuid references workspaces(id) on delete set null;
