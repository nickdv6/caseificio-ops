-- v0.00 · platform extensions the schema relies on. On the live project they were switched on from the Supabase dashboard,
-- so a fresh build from the repo (supabase db reset / db push on a new project) needs them first. Added in v0.59; no-op on live.
create extension if not exists pgcrypto with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;
create extension if not exists pg_cron;                       -- bot heartbeat, backups, daily tasks, sensor roll-up
create extension if not exists pg_net with schema extensions; -- backup-export calls from pg_cron
-- also needed (dashboard settings, not SQL): Data API → Exposed schemas → add "fabula"; Vault secret backup_export_token (see tools/go-live/BACKUP-RESTORE.md)
