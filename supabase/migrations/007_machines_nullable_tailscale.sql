-- Make tailscale_ip nullable since Tailscale is optional (relay mode works without it)
ALTER TABLE machines ALTER COLUMN tailscale_ip DROP NOT NULL;
ALTER TABLE machines ALTER COLUMN tailscale_ip SET DEFAULT '';
