-- Multi-machine support: add hardware_uuid to uniquely identify each Mac
ALTER TABLE machines ADD COLUMN IF NOT EXISTS hardware_uuid TEXT;
ALTER TABLE machines ADD COLUMN IF NOT EXISTS display_name TEXT;

-- Create unique constraint per user + hardware so each Mac gets its own row
CREATE UNIQUE INDEX IF NOT EXISTS idx_machines_user_hardware
  ON machines (user_id, hardware_uuid)
  WHERE hardware_uuid IS NOT NULL;

-- Index for fetching all machines for a user
CREATE INDEX IF NOT EXISTS idx_machines_user_status
  ON machines (user_id, status);
