-- Remove workspaces and profiles from the supabase_realtime publication.
--
-- Rationale:
-- A full search across TarsyShared, TarsymacOS, and TarsyiOS for .channel(,
-- postgres_changes, RealtimeClientV2, PostgresChangesAction, and related
-- patterns returned zero matches. The apps do not subscribe to realtime for
-- these tables — they use REST via .from().select().
--
-- Meanwhile, publishing these tables exposes sensitive columns to the realtime
-- stream (constrained by RLS, but still streamed to any client holding a valid
-- session token):
--   * workspaces.ai_context  — free-text where users may paste API keys
--   * workspaces.config      — opaque jsonb with uncontrolled contents
--   * profiles.email         — PII
--   * profiles.subscription_status / subscription_end_date — billing state
--
-- Dropping dead-code publications eliminates the exposure with zero functional
-- impact. machines is intentionally KEPT in the publication (lower-risk data
-- and may be used for live status updates in the future).

alter publication supabase_realtime drop table workspaces;
alter publication supabase_realtime drop table profiles;
