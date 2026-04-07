-- Enable explicit RLS on private_config for defense-in-depth.
-- Access was already revoked via REVOKE ALL in migration 010,
-- but explicit RLS ensures protection even if grants change.
ALTER TABLE IF EXISTS private_config ENABLE ROW LEVEL SECURITY;

-- Deny all access by default (no policies = no access with RLS enabled)
-- The table is only accessed by service_role which bypasses RLS.
