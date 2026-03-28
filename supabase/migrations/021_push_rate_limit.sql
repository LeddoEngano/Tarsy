-- Rate limit push notification inserts to 10 per minute per user
CREATE OR REPLACE FUNCTION check_push_rate_limit()
RETURNS TRIGGER AS $$
DECLARE
  recent_count INTEGER;
BEGIN
  SELECT COUNT(*) INTO recent_count
  FROM push_notifications
  WHERE user_id = auth.uid()
    AND created_at > NOW() - INTERVAL '1 minute';

  IF recent_count >= 10 THEN
    RAISE EXCEPTION 'Push notification rate limit exceeded (max 10 per minute)';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER push_rate_limit
  BEFORE INSERT ON push_notifications
  FOR EACH ROW EXECUTE FUNCTION check_push_rate_limit();
