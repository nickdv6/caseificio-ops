-- One-time paste for Nick: Supabase → SQL Editor → paste → Run (05/10/2026, v0.68).
-- The Supabase connector Claude uses refuses any statement with a delete, so this one job has to be created by hand.
-- It trims fabula.save_ledger (the tablet's exactly-once save receipts, ids only) every Sunday at 03:30 UTC,
-- keeping 30 days — far longer than any tablet stays offline. Safe to run twice (same job name = replaced).
select cron.schedule(
  'fabula_save_ledger_trim',
  '30 3 * * 0',
  $c$delete from fabula.save_ledger where created_at < now() - interval '30 days'$c$
);
-- check: select jobname, schedule, active from cron.job where jobname = 'fabula_save_ledger_trim';
