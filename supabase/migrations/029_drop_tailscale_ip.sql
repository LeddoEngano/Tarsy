-- Remove unused tailscale_ip column from machines table
ALTER TABLE machines DROP COLUMN IF EXISTS tailscale_ip;
