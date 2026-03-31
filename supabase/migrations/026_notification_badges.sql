-- Add read_at column for tracking which notifications have been seen
ALTER TABLE push_notifications ADD COLUMN IF NOT EXISTS read_at timestamptz;

-- Partial index for fast unread-per-workspace queries
CREATE INDEX IF NOT EXISTS idx_push_notifications_unread_per_workspace
  ON push_notifications (user_id, workspace_id)
  WHERE read_at IS NULL;

-- Allow users to mark their own notifications as read
DROP POLICY IF EXISTS "Users can update own notifications" ON push_notifications;
CREATE POLICY "Users can update own notifications"
  ON push_notifications FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- Returns unread count grouped by workspace (for iOS dashboard badges)
CREATE OR REPLACE FUNCTION get_unread_counts()
RETURNS TABLE(workspace_id uuid, unread_count bigint) AS $$
  SELECT pn.workspace_id, count(*)
  FROM push_notifications pn
  WHERE pn.user_id = auth.uid()
    AND pn.read_at IS NULL
    AND pn.sent = true
    AND pn.workspace_id IS NOT NULL
  GROUP BY pn.workspace_id;
$$ LANGUAGE sql SECURITY INVOKER STABLE;

-- Returns total unread count for a user (for APNs badge number)
-- SECURITY INVOKER: RLS applies, so authenticated users can only count their own rows.
-- The edge function uses service_role which bypasses RLS, so the p_user_id filter still works.
CREATE OR REPLACE FUNCTION get_total_unread_count(p_user_id uuid)
RETURNS integer AS $$
  SELECT coalesce(count(*), 0)::integer
  FROM push_notifications
  WHERE user_id = p_user_id
    AND read_at IS NULL
    AND sent = true;
$$ LANGUAGE sql SECURITY INVOKER STABLE;
