-- v0.59 · the two pg_cron jobs that were scheduled by hand at setup (README step 7) and so were missing from the repo.
-- cron.schedule() with an existing job name updates it in place, so this is a no-op on the live database.
-- (The other three jobs — fabula_bot_heartbeat, fabula_backup_latest, fabula_backup_nightly — are in v039e and v043.)
select cron.schedule('fabula_daily_tasks', '0 4 * * *', $$select fabula.generate_daily_tasks()$$);
select cron.schedule('fabula_sensor_rollup', '0 */12 * * *', $$select fabula.rollup_sensor_haccp()$$);
