-- Add workspace_type column to workspaces table
ALTER TABLE workspaces ADD COLUMN IF NOT EXISTS workspace_type TEXT NOT NULL DEFAULT 'standard';
