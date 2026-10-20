-- v1.10a (20/10/2026) · one index too many on the Bot feed (Supabase performance advisor «Duplicate Index»)
--   v1.00b (14/10) added bot_messages_open, the same index as bot_messages_unread from v0.40a (02/10): (created_at desc) where
--   read_at is null. Every new or closed Bot message updated both, and the planner used either. The original stays; the copy goes.
--   No code names either index ('bot_messages_unread' in ops_dashboard and the backup is a count's name, not the index).
--   Not «concurrently»: a release runs in one transaction, and the table is small (16 kB on 20/10).
do $mig$
begin
  -- a database where only the copy exists (never seen, but cheap to cover) keeps it under the original's name
  if to_regclass('fabula.bot_messages_unread') is null and to_regclass('fabula.bot_messages_open') is not null then
    alter index fabula.bot_messages_open rename to bot_messages_unread;
  end if;
end $mig$;

drop index if exists fabula.bot_messages_open;
