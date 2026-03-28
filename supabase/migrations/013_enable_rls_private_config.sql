-- Enable RLS on private_config as defense-in-depth.
-- Access is already denied via REVOKE, but RLS with zero policies
-- ensures all rows are denied even if grants are accidentally restored.
ALTER TABLE private_config ENABLE ROW LEVEL SECURITY;
