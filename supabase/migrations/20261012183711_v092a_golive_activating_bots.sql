-- v0.92a: go-live checklist item "Activating Bots" (manual), just before the dry run.
-- The nightly daily-task generator (pg_cron job fabula_daily_tasks) was paused 12/10/2026
-- because nobody is in the building yet; switch it and the in-building bots back on at possession.
insert into fabula.dash_checks (key, sort, label, kind, done, note, updated_at) values
 ('bots_activated', 19, 'Activating Bots', 'manual', false,
  'Do this the day you take possession of the building. Switch the nightly daily-task job back on (pg_cron fabula_daily_tasks, paused 12/10/2026 and cleared of 102 unattended tasks), then check the in-building bots (Chiusura serata, Piano latte, Ordini ingrosso, Sell-down, Brief del mattino) are on in Configurazione → Bot. The first fresh task list appears at 04:00 the next morning.',
  now())
on conflict (key) do nothing;
