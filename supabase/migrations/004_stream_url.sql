-- Add stream_url column to workspaces table
ALTER TABLE workspaces ADD COLUMN IF NOT EXISTS stream_url TEXT;
