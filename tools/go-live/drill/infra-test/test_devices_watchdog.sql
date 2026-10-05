-- v0.74 device check-in, refused saves, scheduler watchdog · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh dv_test
--   su postgres -c "psql -d dv_test -f tools/go-live/drill/infra-test/test_devices_watchdog.sql" | grep -E "PASS|FAIL"
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
insert into fabula.staff(id, full_name, auth_user_id, app_role, role, active) values ('10000000-0000-4000-a000-000000000077', 'Casaro Test', '00000000-0000-4000-a000-000000000077', 'produzione', 'casaro', true);
insert into fabula.infra_status (key, ok, detail, data, checked_at, last_ok_at) values ('github_sw', true, 'perla-v50', '{"sw":"perla-v50"}', now() - interval '2 days', now() - interval '2 days')
on conflict (key) do update set ok = true, data = excluded.data, checked_at = excluded.checked_at, last_ok_at = excluded.last_ok_at;

-- 1. check-in as a signed-in staff member (JWT claims)
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-000000000077","role":"authenticated"}', false);
select fabula.device_checkin('dev-abc123', 'tablet-1', 'perla-v49', 3, now() - interval '3 hours',
  '[{"qid":"q-1","ops":[{"table":"haccp_log","row":{"x":1}}],"error":"new row violates check constraint","code":"23514","failed_at":1759700000000}]', 'Mozilla') r1 \gset
select pg_temp.ck('check-in saves the device and answers with the live version',
  (:'r1'::jsonb->>'live_version') = 'perla-v50' and (select app_version || '|' || queue_len || '|' || failed_len || '|' || label from fabula.devices where device_uid = 'dev-abc123') = 'perla-v49|3|1|tablet-1', :'r1');
select pg_temp.ck('refused save stored in full and posted to the bell as an alert',
  (select what || '|' || code from fabula.tablet_rejects where qid = 'q-1') = 'haccp_log|23514'
  and exists (select 1 from fabula.bot_messages where agent = 'tablet' and severity = 'alert' and title like '1 registrazione rifiutata%' and body like '%haccp_log: new row violates%'));
select fabula.device_checkin('dev-abc123', 'tablet-1', 'perla-v49', 3, now() - interval '3 hours', '[{"qid":"q-1","ops":[],"error":"x"}]') r2 \gset
select pg_temp.ck('the same refused save sent again is not stored or posted twice',
  (:'r2'::jsonb->>'reported')::int = 0 and (select count(*) from fabula.tablet_rejects) = 1 and (select count(*) from fabula.bot_messages where agent = 'tablet') = 1);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-0000000000ff","role":"authenticated"}', false);
do $$ begin perform fabula.device_checkin('dev-xyz999', 'x', 'v', 0, null); raise notice 'R accepted'; exception when others then raise notice 'R refused'; end $$;
select pg_temp.ck('a login that is not staff cannot check in', not exists (select 1 from fabula.devices where device_uid = 'dev-xyz999'));
select set_config('request.jwt.claims', '', false);

-- 2. device_watch
select fabula.device_watch() w1 \gset
select pg_temp.ck('records waiting > 2 h and old app a day after release: one warning each',
  (select count(*) from jsonb_array_elements(:'w1'::jsonb->'warnings')) = 2
  and exists (select 1 from fabula.bot_messages where agent = 'tablet' and title like 'tablet-1: 3 registrazioni in attesa%')
  and exists (select 1 from fabula.bot_messages where agent = 'tablet' and title like 'tablet-1 usa ancora la versione perla-v49%'), :'w1');
select pg_temp.ck('not repeated within a day', jsonb_array_length(fabula.device_watch()->'warnings') = 0);
update fabula.devices set queue_len = 0, oldest_queued_at = null, app_version = 'perla-v50' where device_uid = 'dev-abc123';
select pg_temp.ck('queue sent and app updated: nothing to warn', jsonb_array_length(fabula.device_watch(now() + interval '2 days')->'warnings') = 0);

-- 3. resolve
select fabula.resolve_tablet_reject('q-1', 'rifatta a mano') rs \gset
select pg_temp.ck('a refused save can be marked as dealt with', :'rs'::boolean and (select resolution from fabula.tablet_rejects where qid = 'q-1') = 'rifatta a mano');

-- 4. scheduler watchdog
insert into cron.job_run_details (jobid, status, return_message, start_time, end_time) values
 ((select jobid from cron.job where jobname = 'fabula_bot_fallback'), 'failed', 'ERROR: something broke', now() - interval '2 hours', now() - interval '2 hours'),
 ((select jobid from cron.job where jobname = 'fabula_bot_fallback'), 'succeeded', '', now() - interval '1 hour', now() - interval '1 hour');
select fabula.bot_watchdog() b1 \gset
select pg_temp.ck('a failed scheduled job is reported, with the job name', exists (select 1 from jsonb_array_elements(:'b1'::jsonb->'alerts') x where x->>'kind' = 'cron_failed' and x->>'name' = 'fabula_bot_fallback')
  and :'b1'::jsonb->>'message_it' like '%Automazione del database "fabula_bot_fallback" fallita%', :'b1'::jsonb->>'message_it');
select pg_temp.ck('scheduler silent for an hour: reported as stopped', exists (select 1 from jsonb_array_elements(:'b1'::jsonb->'alerts') x where x->>'kind' = 'cron_stopped')
  and :'b1'::jsonb->>'message_it' like '%automazioni del database (pg_cron) sono ferme%');
select pg_temp.ck('reported once, not every hour', not exists (select 1 from jsonb_array_elements((fabula.bot_watchdog())->'alerts') x where x->>'kind' in ('cron_failed', 'cron_stopped')));
insert into cron.job_run_details (jobid, status, start_time, end_time) values ((select jobid from cron.job where jobname = 'fabula_bot_fallback'), 'succeeded', now() + interval '58 minutes', now() + interval '58 minutes');
select pg_temp.ck('scheduler running: no stopped alert', not exists (select 1 from jsonb_array_elements((fabula.bot_watchdog(now() + interval '1 hour'))->'alerts') x where x->>'kind' = 'cron_stopped'));
select pg_temp.ck('jobs and grants', exists (select 1 from cron.job where jobname = 'fabula_device_watch')
  and has_function_privilege('authenticated', 'fabula.device_checkin(text, text, text, int, timestamptz, jsonb, text)', 'execute')
  and not has_function_privilege('anon', 'fabula.device_checkin(text, text, text, int, timestamptz, jsonb, text)', 'execute')
  and not has_function_privilege('authenticated', 'fabula.device_watch(timestamptz)', 'execute'));
