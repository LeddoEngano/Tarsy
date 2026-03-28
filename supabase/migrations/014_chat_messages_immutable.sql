-- =============================================================================
-- Migration 014: Document chat_messages immutability
-- =============================================================================
--
-- The chat_messages table is intentionally IMMUTABLE (append-only log).
--
-- By design, there are NO UPDATE or DELETE RLS policies on this table.
-- Messages cannot be edited or deleted once inserted. This ensures:
--
--   1. Audit integrity — the full conversation history is always preserved
--   2. Consistency — both iOS and macOS apps can trust that messages never
--      change or disappear after being received
--   3. Simplicity — no conflict resolution needed for concurrent edits
--
-- If you need to "correct" a message, insert a new one. Do not add UPDATE
-- or DELETE policies without careful consideration of the above guarantees.
-- =============================================================================

COMMENT ON TABLE public.chat_messages IS
  'Append-only immutable log. No UPDATE/DELETE policies by design — messages cannot be edited or removed once created.';
