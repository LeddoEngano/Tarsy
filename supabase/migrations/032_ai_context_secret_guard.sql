-- Defense-in-depth CHECK constraint blocking known credential patterns from
-- workspaces.ai_context. The iOS client (AIContextEditorView) performs the
-- same validation before saving; this constraint is the last line of defense
-- against alternative clients, debug builds, or direct REST access with a
-- leaked JWT.
--
-- A read-only diagnostic sweep of production (2026-04-10) confirmed zero
-- existing rows match any of these patterns, so the constraint is applied as
-- a full (not NOT VALID) constraint — no risk of breaking updates on legacy
-- rows, which would happen if an old row had a secret and any subsequent
-- UPDATE on any column re-checked the constraint.
--
-- Patterns are tuned to avoid false positives on ordinary code snippets:
--   * sk- patterns require 40+ continuous token chars (no whitespace breaks)
--   * github tokens require the full prefix + 30+ chars
--   * aws access keys use the canonical 16-char suffix

alter table workspaces add constraint workspaces_ai_context_no_secrets
  check (
    ai_context is null
    or (
      ai_context !~ 'sk-ant-[a-zA-Z0-9_-]{20,}'
      and ai_context !~ 'sk-[a-zA-Z0-9_-]{40,}'
      and ai_context !~ 'gh[oprsu]_[a-zA-Z0-9]{30,}'
      and ai_context !~ 'xox[a-z]-[0-9a-zA-Z-]{20,}'
      and ai_context !~ 'AKIA[0-9A-Z]{16}'
      and ai_context !~ 'AIza[a-zA-Z0-9_-]{35}'
      and ai_context !~ '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    )
  );

comment on constraint workspaces_ai_context_no_secrets on workspaces is
  'Blocks known API key / token patterns in ai_context. Client-side validation in AIContextEditorView catches these first; this is the DB-level defense in depth.';
