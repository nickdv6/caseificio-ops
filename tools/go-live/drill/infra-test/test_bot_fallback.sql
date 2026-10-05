-- v0.69 self-healing bots · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh fb_test
--   su postgres -c "psql -d fb_test -f tools/go-live/drill/infra-test/test_bot_fallback.sql" | grep -E "PASS|FAIL"
-- Drives fabula.bot_fallback() with fixed clock times on Monday 12/10/2026 (Rome) and checks what it does.
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;

-- 1. 19:45 Rome: milk planning (18:52 + 45) and wholesale orders (18:20 + 45) are due; evening HACCP (19:02 + 45) not yet
select fabula.bot_fallback('2026-10-12 19:45:00+02') r1 \gset
select pg_temp.ck('19:45 runs milk planning and wholesale orders only',
  (select array_agg(x->>'agent' order by x->>'agent') from jsonb_array_elements(:'r1'::jsonb->'runs') x) = array['milk_planning', 'wholesale_orders'], :'r1');
select pg_temp.ck('milk plan proposed with an approval',
  exists (select 1 from fabula.milk_plans m join fabula.approvals a on a.id = m.approval_id where m.status = 'proposed' and a.requested_by = 'agent:milk_planning'));
select pg_temp.ck('runs logged in agent_runs as db_fallback',
  (select count(*) from fabula.agent_runs where details->>'via' = 'db_fallback' and status = 'ok' and summary like 'Eseguito dal database%') = 2);
select pg_temp.ck('dashboard messages posted for both bots',
  (select count(*) from fabula.bot_messages where agent in ('milk_planning', 'wholesale_orders') and title like 'Sostituito dal database%' and body like 'Il bot "%non è partito alle%') = 2,
  (select string_agg(title, ' | ') from fabula.bot_messages where title like 'Sostituito%'));

-- 2. 19:50: milk/wholesale are not repeated, the evening HACCP banner is produced now
select fabula.bot_fallback('2026-10-12 19:50:00+02') r2 \gset
select pg_temp.ck('19:50 runs only haccp_nudge (no repeats)',
  (select array_agg(x->>'agent') from jsonb_array_elements(:'r2'::jsonb->'runs') x) = array['haccp_nudge'], :'r2');
select pg_temp.ck('milk plan still one proposal, one approval',
  (select count(*) from fabula.milk_plans where status = 'proposed') = 1 and (select count(*) from fabula.approvals where requested_by = 'agent:milk_planning') = 1);
select pg_temp.ck('ledger has one ok row per bot and slot',
  (select count(*) from fabula.bot_fallback_runs where status = 'ok') = 3 and (select count(distinct (agent, slot)) from fabula.bot_fallback_runs) = 3);

-- 3. a bot that did run is left alone: ops_health ran at 20:37, so nothing at 21:25
insert into fabula.agent_runs (agent, started_at, finished_at, status, summary) values ('ops_health', '2026-10-12 20:37:00+02', '2026-10-12 20:38:00+02', 'ok', 'bot run');
select fabula.bot_fallback('2026-10-12 21:25:00+02') r3 \gset
select pg_temp.ck('a bot that ran is not replaced', not exists (select 1 from jsonb_array_elements(:'r3'::jsonb->'runs') x where x->>'agent' = 'ops_health'), :'r3');

-- 4. morning: procurement (06:20 + 45) and sell-down (07:23 + 45) at 08:10 on Tuesday; the 6-hour windows end at 12:20 and 13:23
select fabula.bot_fallback('2026-10-13 08:10:00+02') r4 \gset
select pg_temp.ck('08:10 runs procurement and sell_down',
  (select array_agg(x->>'agent' order by x->>'agent') from jsonb_array_elements(:'r4'::jsonb->'runs') x) = array['procurement', 'sell_down'], :'r4');
select pg_temp.ck('no fallback after the 6-hour window', (select count(*) from jsonb_array_elements((fabula.bot_fallback('2026-10-14 13:30:00+02'))->'runs') x where x->>'agent' in ('procurement', 'sell_down')) = 0);

-- 5. ops_health stand-in on a day without a bot run (Wednesday 21:25) and backup re-send (21:15 + 45 = 22:00)
select fabula.bot_fallback('2026-10-14 21:25:00+02') r5 \gset
select pg_temp.ck('ops_health stand-in runs and reports', exists (select 1 from jsonb_array_elements(:'r5'::jsonb->'runs') x where x->>'agent' = 'ops_health' and x->>'status' = 'ok'), :'r5');
select fabula.bot_fallback('2026-10-14 22:05:00+02') r6 \gset
select pg_temp.ck('nightly backup re-sent once, not logged as a fake ok run',
  exists (select 1 from jsonb_array_elements(:'r6'::jsonb->'runs') x where x->>'agent' = 'backup_export' and x->>'status' = 'ok')
  and not exists (select 1 from fabula.agent_runs where agent = 'backup_export' and details->>'via' = 'db_fallback'), :'r6');

-- 6. the alarm bot waits 20 more minutes for covered bots, not for the others
select fabula.bot_watchdog('2026-10-15 19:47:00+02') w1 \gset
select pg_temp.ck('watchdog: covered bot not reported at grace + 10 min',
  not exists (select 1 from jsonb_array_elements(:'w1'::jsonb->'alerts') x where x->>'agent' = 'milk_planning'));
select pg_temp.ck('watchdog: non-covered bot reported as before',
  exists (select 1 from jsonb_array_elements(:'w1'::jsonb->'alerts') x where x->>'agent' = 'daily_brief' and x->>'kind' = 'missed'));

-- 7. a failing stand-in is logged as an error (the alarm bot reports it) and the others still run
alter table fabula.milk_plans rename to milk_plans_broken;
select fabula.bot_fallback('2026-10-16 19:45:00+02') r7 \gset
alter table fabula.milk_plans_broken rename to milk_plans;
select pg_temp.ck('failure logged as error, other bots still run',
  exists (select 1 from jsonb_array_elements(:'r7'::jsonb->'runs') x where x->>'agent' = 'milk_planning' and x->>'status' = 'error')
  and exists (select 1 from jsonb_array_elements(:'r7'::jsonb->'runs') x where x->>'agent' = 'wholesale_orders' and x->>'status' = 'ok')
  and exists (select 1 from fabula.agent_runs where agent = 'milk_planning' and status = 'error' and details->>'via' = 'db_fallback'), :'r7');
select pg_temp.ck('watchdog reports the failed stand-in',
  exists (select 1 from jsonb_array_elements((fabula.bot_watchdog('2026-10-16 19:50:00+02'))->'alerts') x where x->>'agent' = 'milk_planning' and x->>'kind' = 'error'));

-- 8. switch: bots.db_fallback = 0 turns it off; watchdog then reports at the normal grace
update fabula.settings set value = '0' where key = 'bots.db_fallback';
select pg_temp.ck('setting 0 switches the fallback off', (fabula.bot_fallback('2026-10-17 19:45:00+02'))->>'enabled' = 'false');
select pg_temp.ck('setting 0: watchdog back to normal grace',
  exists (select 1 from jsonb_array_elements((fabula.bot_watchdog('2026-10-17 19:40:00+02'))->'alerts') x where x->>'agent' = 'milk_planning' and x->>'kind' = 'missed'));
update fabula.settings set value = '1' where key = 'bots.db_fallback';

-- 9. nightly backup at 21:15 Rome all year
-- (the test database has no Vault secret: backup_export_call then logs an error row instead of sending, which also proves it was called)
select count(*) n0 from fabula.agent_runs where agent = 'backup_export' \gset
select pg_temp.ck('backup: 20:15 UTC in October (22:15 Rome) does nothing', fabula.backup_nightly_rome('2026-10-14 20:15:00+00') is null
  and (select count(*) from fabula.agent_runs where agent = 'backup_export') = :n0);
select coalesce(fabula.backup_nightly_rome('2026-11-02 20:15:00+00')::text, 'none') b1 \gset
select pg_temp.ck('backup: 20:15 UTC in November (21:15 Rome) sends it',
  :'b1' <> 'none' or (select count(*) from fabula.agent_runs where agent = 'backup_export') = :n0 + 1, 'request ' || :'b1');
select pg_temp.ck('cron: nightly backup at 19:15 and 20:15 UTC, fallback every 5 min',
  exists (select 1 from cron.job where jobname = 'fabula_backup_nightly' and schedule = '15 19,20 * * *' and command like '%backup_nightly_rome%')
  and exists (select 1 from cron.job where jobname = 'fabula_bot_fallback' and schedule = '*/5 * * * *'));
select pg_temp.ck('signed-in users cannot run the fallback',
  not has_function_privilege('authenticated', 'fabula.bot_fallback(timestamptz)', 'execute') and not has_function_privilege('authenticated', 'fabula.bot_fallback_run(text, date)', 'execute'));
