-- Migration 023: Drop chat_messages table
-- Chat history is now served by UltraContext. No app code references this table.

drop policy if exists "Users can read own chat messages" on chat_messages;
drop policy if exists "Users can insert own chat messages" on chat_messages;
drop table if exists chat_messages;
