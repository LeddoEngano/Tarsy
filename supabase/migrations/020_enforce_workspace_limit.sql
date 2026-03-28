CREATE OR REPLACE FUNCTION check_workspace_limit()
RETURNS TRIGGER AS $$
DECLARE
  workspace_count INTEGER;
  user_is_pro BOOLEAN;
BEGIN
  SELECT COALESCE(is_pro, false) INTO user_is_pro
  FROM profiles WHERE id = auth.uid();

  IF NOT user_is_pro THEN
    SELECT COUNT(*) INTO workspace_count
    FROM workspaces WHERE user_id = auth.uid();

    IF workspace_count >= 1 THEN
      RAISE EXCEPTION 'Free plan limited to 1 workspace. Upgrade to Pro for unlimited workspaces.';
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER enforce_workspace_limit
  BEFORE INSERT ON workspaces
  FOR EACH ROW EXECUTE FUNCTION check_workspace_limit();
