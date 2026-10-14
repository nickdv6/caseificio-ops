-- v1.00a ops batch (audit E-22, E-24, E-25) · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh ow_test
--   su postgres -c "psql -d ow_test -f tools/go-live/drill/infra-test/test_outside_watch.sql" | grep -E "PASS|FAIL"   (CI runs it on every push)
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as
$$ begin execute p_sql; return ''; exception when others then return sqlstate || ' ' || sqlerrm; end $$;
create or replace function pg_temp.chk(p_key text) returns jsonb language sql as
$$ select c from jsonb_array_elements(fabula.ops_dashboard()->'checks') c where c->>'key' = p_key $$;

select vault.create_secret('test-backup-token-123', 'backup_export_token') is not null as secret_set \gset

-- 1. board before any report: both checks red and say what to set up
select pg_temp.ck('before any report: outside watcher red, asks for the GitHub secret',
  not (pg_temp.chk('outside_watcher')->>'done')::boolean and pg_temp.chk('outside_watcher')->>'kind' = 'auto'
  and pg_temp.chk('outside_watcher')->>'detail' like 'Not reporting yet%BACKUP_EXPORT_TOKEN%', pg_temp.chk('outside_watcher')->>'detail');
select pg_temp.ck('before any report: off-site copy red, asks for both secrets',
  not (pg_temp.chk('offsite_backup')->>'done')::boolean and pg_temp.chk('offsite_backup')->>'detail' like '%BACKUP_PASSPHRASE%');
select pg_temp.ck('before any report: the hourly watch raises nothing', jsonb_array_length(fabula.outside_watch()->'raised') = 0);

-- 2. the report function: token and kind checked, anonymous callers only with the token
set role anon;
select pg_temp.ck('anon with a wrong token is refused', pg_temp.err($$select public.fabula_outside_report('wrong', 'watcher', '{}')$$) like '42501%');
select pg_temp.ck('anon with an unknown kind is refused', pg_temp.err($$select public.fabula_outside_report('test-backup-token-123', 'other', '{}')$$) like '22023%');
select pg_temp.ck('anon with the token: watcher report accepted',
  pg_temp.err($$select public.fabula_outside_report('test-backup-token-123', 'watcher', '{"ok": true, "summary": "tutto OK"}')$$) = '');
select pg_temp.ck('anon cannot run the hourly watch', pg_temp.err($$select fabula.outside_watch()$$) like '42501%');
reset role;
set role authenticated;
select pg_temp.ck('a signed-in app user cannot call the report function', pg_temp.err($$select public.fabula_outside_report('test-backup-token-123', 'watcher', '{}')$$) like '42501%');
reset role;

select pg_temp.ck('watcher report stored and the board check is green',
  (select ok and detail = 'tutto OK' and last_ok_at > now() - interval '1 minute' from fabula.infra_status where key = 'outside_watcher')
  and (pg_temp.chk('outside_watcher')->>'done')::boolean and pg_temp.chk('outside_watcher')->>'detail' like 'Last run %all OK%', pg_temp.chk('outside_watcher')->>'detail');
select public.fabula_outside_report('test-backup-token-123', 'watcher', '{"ok": false, "summary": "database non risponde"}') \gset
select pg_temp.ck('a watcher report with a problem: still running (green), the problem shown',
  (pg_temp.chk('outside_watcher')->>'done')::boolean and pg_temp.chk('outside_watcher')->>'detail' like '%found: database non risponde%'
  and (select fail_streak = 1 and last_ok_at is not null from fabula.infra_status where key = 'outside_watcher'));

select public.fabula_outside_report('test-backup-token-123', 'offsite_backup', '{"ok": false, "summary": "manca il segreto BACKUP_PASSPHRASE"}') \gset
select fabula.outside_watch() w0 \gset
select pg_temp.ck('an off-site copy that never succeeded is overdue at once (notice «non è mai riuscita»)',
  :'w0'::jsonb->'raised' ? 'offsite_backup_stale'
  and exists (select 1 from fabula.notices where key = 'offsite_backup_stale' and resolved_at is null and title_it like '%non è mai riuscita'), :'w0');
select public.fabula_outside_report('test-backup-token-123', 'watcher', '{"summary": "senza esito"}') \gset
select pg_temp.ck('a report without «ok» counts as a problem, not as success',
  (select not ok and last_ok_at is not null and fail_streak = 2 from fabula.infra_status where key = 'outside_watcher'));
select pg_temp.err($$select public.fabula_outside_report('test-backup-token-123', 'watcher', '"testo"'::jsonb)$$) e_str \gset
select pg_temp.ck('a detail that is not an object is accepted as a problem, not an error',
  :'e_str' = '' and (select not ok from fabula.infra_status where key = 'outside_watcher'), :'e_str');
select public.fabula_outside_report('test-backup-token-123', 'watcher', '{"ok": "true", "summary": "stringa"}') \gset
select pg_temp.ck('«ok» must be the boolean true', (select not ok from fabula.infra_status where key = 'outside_watcher'));
select public.fabula_outside_report('test-backup-token-123', 'watcher', '{"ok": true, "summary": "tutto OK"}') \gset
select public.fabula_outside_report('test-backup-token-123', 'offsite_backup', '{"ok": true, "summary": "backup 13/10 · 412 KB · copia cifrata su GitHub (90 giorni)", "date": "2026-10-13"}') \gset
select pg_temp.ck('off-site report stored: board green with the summary',
  (pg_temp.chk('offsite_backup')->>'done')::boolean and pg_temp.chk('offsite_backup')->>'detail' like 'backup 13/10%');
select public.fabula_outside_report('test-backup-token-123', 'offsite_backup', '{"ok": false, "summary": "file del 13/10 non trovato"}') \gset
select pg_temp.ck('a failed off-site copy turns the board red with the reason',
  not (pg_temp.chk('offsite_backup')->>'done')::boolean and pg_temp.chk('offsite_backup')->>'detail' like 'Last attempt failed%non trovato%');
select pg_temp.err(format($$select public.fabula_outside_report('test-backup-token-123', 'offsite_backup', %L::jsonb)$$,
    jsonb_build_object('ok', true, 'summary', 'grande', 'blob', repeat('x', 20000))::text)) big_err \gset
select pg_temp.ck('an oversized detail is cut, not refused',
  :'big_err' = '' and (select data ? 'truncated' and detail = 'grande' from fabula.infra_status where key = 'offsite_backup'), :'big_err');

-- 3. restore drill from GitHub feeds «Backup restore tested»
select public.fabula_outside_report('test-backup-token-123', 'restore_drill', '{"ok": true, "summary": "Prova di ripristino 13/10 su GitHub: 120 tabelle, righe uguali al backup, 0 orfani"}') \gset
select pg_temp.ck('a drill from GitHub is recorded and the board check is green',
  (select status = 'ok' and details->>'via' = 'github' from fabula.agent_runs where agent = 'restore_drill' order by started_at desc limit 1)
  and (pg_temp.chk('restore_tested')->>'done')::boolean, pg_temp.chk('restore_tested')->>'detail');
select public.fabula_outside_report('test-backup-token-123', 'restore_drill', '{"ok": false, "summary": "Prova di ripristino 13/10", "error": "3 tabelle con righe diverse"}') \gset
select pg_temp.err(format($$select public.fabula_outside_report('test-backup-token-123', 'restore_drill', %L::jsonb)$$,
    jsonb_build_object('ok', false, 'summary', 'Prova grande', 'error', 'migrazioni non riuscite', 'blob', repeat('x', 20000))::text)) big_drill \gset
select pg_temp.ck('an oversized drill report keeps its error',
  :'big_drill' = '' and (select status = 'error' and error = 'migrazioni non riuscite' from fabula.agent_runs where agent = 'restore_drill' order by started_at desc, id desc limit 1), :'big_drill');
select public.fabula_outside_report('test-backup-token-123', 'restore_drill', '{"ok": false, "summary": "Prova di ripristino 13/10", "error": "3 tabelle con righe diverse"}') \gset
select pg_temp.ck('a failed drill turns the board red with the error',
  not (pg_temp.chk('restore_tested')->>'done')::boolean and pg_temp.chk('restore_tested')->>'detail' like '%FAILED%righe diverse%', pg_temp.chk('restore_tested')->>'detail');

-- 4. the hourly dead-man's switch
select public.fabula_outside_report('test-backup-token-123', 'offsite_backup', '{"ok": true, "summary": "backup 13/10"}') \gset
select count(*) n0 from fabula.notify_outbox where source = 'outside_watch' \gset
select fabula.outside_watch(now() + interval '23 hours') w0b \gset
select pg_temp.ck('watcher silent 23 h: not yet (GitHub skips runs for hours)', not (:'w0b'::jsonb->'raised' ? 'outside_watcher_silent'), :'w0b');
select fabula.outside_watch(now() + interval '25 hours') w1 \gset
select pg_temp.ck('watcher silent 25 h: notice and one Telegram message (topic infra)',
  :'w1'::jsonb->'raised' ? 'outside_watcher_silent'
  and exists (select 1 from fabula.notices where key = 'outside_watcher_silent' and resolved_at is null and title_it like 'Il controllo esterno su GitHub non gira da 25 ore')
  and (select count(*) from fabula.notify_outbox where source = 'outside_watch' and topic = 'infra') = :n0 + 1, :'w1');
select fabula.outside_watch(now() + interval '26 hours') w2 \gset
select pg_temp.ck('an hour later: still raised, no second message',
  :'w2'::jsonb->'raised' ? 'outside_watcher_silent' and (select count(*) from fabula.notify_outbox where source = 'outside_watch') = :n0 + 1);
select pg_temp.ck('off-site copy 26 h old (one night missed): not yet stale', not (:'w2'::jsonb->'raised' ? 'offsite_backup_stale'));
select fabula.outside_watch(now() + interval '51 hours') w3 \gset
select pg_temp.ck('off-site copy 51 h old (two nights): notice and a message',
  :'w3'::jsonb->'raised' ? 'offsite_backup_stale' and exists (select 1 from fabula.notices where key = 'offsite_backup_stale' and resolved_at is null)
  and (select count(*) from fabula.notify_outbox where source = 'outside_watch') = :n0 + 2, :'w3');
select public.fabula_outside_report('test-backup-token-123', 'watcher', '{"ok": true, "summary": "tutto OK"}') \gset
select public.fabula_outside_report('test-backup-token-123', 'offsite_backup', '{"ok": true, "summary": "backup 14/10"}') \gset
select fabula.outside_watch() w4 \gset
select pg_temp.ck('both report again: notices resolved, nothing raised',
  jsonb_array_length(:'w4'::jsonb->'raised') = 0
  and not exists (select 1 from fabula.notices where key in ('outside_watcher_silent', 'offsite_backup_stale') and resolved_at is null));

-- 5. health for the watcher, schedule, security
update fabula.agent_runs set started_at = now() - interval '30 hours' where agent = 'backup_export';
insert into fabula.agent_runs (agent, status, started_at, finished_at, summary, details)
values ('backup_export', 'ok', now() - interval '1 hour', now() - interval '1 hour', 'backup latest', '{"mode": "latest"}');
select pg_temp.ck('health: a 2-hourly «latest» alone keeps backup_ok but not backup_nightly_ok',
  (public.fabula_health()->>'backup_ok')::boolean and not (public.fabula_health()->>'backup_nightly_ok')::boolean);
insert into fabula.agent_runs (agent, status, started_at, finished_at, summary, details)
values ('backup_export', 'ok', now() - interval '20 hours', now() - interval '20 hours', 'backup nightly', '{"mode": "nightly"}');
select pg_temp.ck('health: a nightly in the last 26 h → backup_nightly_ok', (public.fabula_health()->>'backup_nightly_ok')::boolean);
-- v1.00a: a bot stays «stopped» until it runs again, not only for 4 hours
update fabula.bot_schedule set active = false;
insert into fabula.bot_schedule (agent, name_it, due_times, weekdays, grace_min)
values ('test_bot_ow', 'Bot di prova', array[((now() at time zone 'Europe/Rome') - interval '6 hours')::time], '{1,2,3,4,5,6,7}', 45);
select pg_temp.ck('health: a slot missed 6 h ago still counts (the bot has not run since)',
  not (public.fabula_health()->>'bots_ok')::boolean and (public.fabula_health()->>'bots_missed')::int = 1, public.fabula_health()::text);
insert into fabula.agent_runs (agent, started_at, finished_at, status) values ('test_bot_ow', now() - interval '10 minutes', now(), 'ok');
select pg_temp.ck('health: the bot''s next run clears it', (public.fabula_health()->>'bots_ok')::boolean, public.fabula_health()::text);
update fabula.bot_schedule set active = true where agent <> 'test_bot_ow';
select pg_temp.ck('hourly job scheduled at :50', exists (select 1 from cron.job where jobname = 'fabula_outside_watch' and schedule = '50 * * * *'));
select pg_temp.ck('board: the off-site check is new, the watcher check is now automatic',
  jsonb_array_length(fabula.ops_dashboard()->'checks') >= 42 and pg_temp.chk('outside_watcher')->>'kind' = 'auto' and pg_temp.chk('offsite_backup') is not null, jsonb_array_length(fabula.ops_dashboard()->'checks')::text);
-- 6. recipes in force «today» = the Rome date, whatever the session clock says
select pg_temp.ck('v_recipe_active uses the Rome date, not current_date',
  pg_get_viewdef('fabula.v_recipe_active'::regclass) not ilike '%current_date%' and pg_get_viewdef('fabula.v_recipe_active'::regclass) ilike '%Europe/Rome%'
  and (select reloptions from pg_class where oid = 'fabula.v_recipe_active'::regclass) @> array['security_invoker=true']);
set session_replication_role = replica;
-- a recipe line whose product/component pair has no other version starting today (ids are random: picking «the first»
-- could hit the one-version-per-day key, as on GitHub's CI #4)
update fabula.recipes set valid_from = (now() at time zone 'Europe/Rome')::date, valid_to = (now() at time zone 'Europe/Rome')::date
 where id = (select r.id from fabula.recipes r
              where not exists (select 1 from fabula.recipes o where o.finished_product_id = r.finished_product_id
                                  and o.component_product_id = r.component_product_id and o.id <> r.id
                                  and o.valid_from = (now() at time zone 'Europe/Rome')::date)
              order by r.id limit 1)
 returning id as rcp_today \gset
set session_replication_role = origin;
set timezone = 'Pacific/Pago_Pago';   -- UTC-11: current_date here is the Rome date minus one for most of the day
select pg_temp.ck('a component valid only on Rome''s today is in force even when the session date differs',
  exists (select 1 from fabula.v_recipe_active where recipe_id = :'rcp_today'), current_date::text || ' vs Rome ' || (now() at time zone 'Europe/Rome')::date::text);
reset timezone;
select pg_temp.ck('security scan: nothing new',
  not exists (select 1 from fabula.security_findings() f where not exists (select 1 from fabula.security_accepted a where a.key = f.key)),
  (select string_agg(f.key, ', ') from fabula.security_findings() f where not exists (select 1 from fabula.security_accepted a where a.key = f.key)));
