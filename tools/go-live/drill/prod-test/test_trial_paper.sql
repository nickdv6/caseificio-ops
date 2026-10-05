-- v0.77 trial-week check + paper back-entry · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh tr_test
--   su postgres -c "psql -d tr_test -f tools/go-live/drill/prod-test/test_trial_paper.sql" | grep -E "PASS|FAIL"
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
select pg_temp.ck('no trial set: report skips', fabula.trial_report('2026-10-12 18:35+00')->>'skipped' = 'no trial today');
insert into fabula.settings (key, value) values ('trial.start', '2026-10-12') on conflict (key) do update set value = excluded.value;
select pg_temp.ck('empty day 1: 14 steps (12 daily + 2 day-1)', (fabula.trial_check('2026-10-12')->>'total')::int = 14, fabula.trial_check('2026-10-12')->>'ok');
select pg_temp.ck('day 4 has the paper and lab steps', fabula.trial_check('2026-10-15')::text like '%Giorno 4 · registrazione da foglio%' and fabula.trial_check('2026-10-15')::text like '%MOZ-DOP%');
insert into fabula.haccp_log (control_point_id, operator, measured_value, result, logged_at, source) select id, 'Test', 0, 'ok', '2026-10-12 08:00+02', 'tablet' from fabula.haccp_control_points where code in ('CCP-MILK-ABX', 'PRP-PAST-VALVE', 'PRP-CLEAN');
insert into fabula.haccp_log (control_point_id, operator, measured_value, result, logged_at, source) select id, 'Test', 3, 'ok', t, 'tablet' from fabula.haccp_control_points, unnest(array['2026-10-12 08:00+02'::timestamptz, '2026-10-12 17:00+02']) t where code in ('CCP-COLD-1', 'CCP-COLD-2');
insert into fabula.haccp_log (control_point_id, operator, measured_value, result, logged_at, source) select id, 'Test', 9, 'non_conformity', '2026-10-12 12:00+02', 'tablet' from fabula.haccp_control_points where code = 'CCP-COLD-1';
select fabula.trial_check('2026-10-12') r \gset
select pg_temp.ck('records counted: antibiotics, valve, cold rooms (2+2), cleaning', (select count(*) from jsonb_array_elements(:'r'::jsonb->'steps') x where (x->>'ok')::boolean and x->>'step' similar to '(Test antibiotici|Pastorizzatore|Temperature celle|Sanificazione)%') = 4);
select pg_temp.ck('out-of-limit without action flagged', (select not (x->>'ok')::boolean and x->>'detail' = '1 fuori limite · 1 senza azione' from jsonb_array_elements(:'r'::jsonb->'steps') x where x->>'step' like 'Ogni valore%'));
insert into fabula.haccp_log (control_point_id, operator, measured_value, result, logged_at, source) select id, 'Test', 72, 'ok', '2026-10-13 00:30+02', 'tablet' from fabula.haccp_control_points where code = 'CCP-PAST';
select pg_temp.ck('a record at 00:30 Rome on the 13th (22:30 UTC on the 12th) counts for the 13th',
  (select x->>'detail' from jsonb_array_elements(fabula.trial_check('2026-10-12')->'steps') x where x->>'step' like 'Pastorizzazione%') = '0 registrazioni'
  and (select x->>'detail' from jsonb_array_elements(fabula.trial_check('2026-10-13')->'steps') x where x->>'step' like 'Pastorizzazione%') = '1 registrazioni');
select fabula.trial_report('2026-10-12 18:35+00') r1 \gset
select fabula.trial_report('2026-10-12 18:36+00') r2 \gset
select pg_temp.ck('report at 20:35 Rome posts once as Zia Carmela', (:'r1'::jsonb->>'total')::int = 14 and :'r2'::jsonb->>'skipped' = 'already posted'
   and (select count(*) from fabula.bot_messages where agent = 'prova') = 1 and fabula.bot_display_name('prova') = 'Zia Carmela · Settimana di prova');
select pg_temp.ck('19:35 Rome (other DST slot) skips', fabula.trial_report('2026-10-12 17:35+00')->>'skipped' = 'not 20:xx in Rome');
select pg_temp.ck('after the 5 days: skips', fabula.trial_report('2026-10-17 18:35+00')->>'skipped' = 'no trial today');
select pg_temp.ck('job scheduled; signed-in users can read the check but not post', exists (select 1 from cron.job where jobname = 'fabula_trial_report')
   and has_function_privilege('authenticated', 'fabula.trial_check(date)', 'execute') and not has_function_privilege('authenticated', 'fabula.trial_report(timestamptz)', 'execute')
   and not has_function_privilege('anon', 'fabula.trial_check(date)', 'execute'));
insert into fabula.staff (id, full_name, role, app_role, active) values ('10000000-0000-4000-a000-0000000000a1', 'Casaro Prova', 'casaro', 'produzione', true), ('10000000-0000-4000-a000-0000000000a2', 'Aiuto Prova', 'casaro', 'produzione', true) on conflict do nothing;
select fabula.log_ccp(p_cp_code => 'PRP-PAST-VALVE', p_value => 0, p_staff_id => '10000000-0000-4000-a000-0000000000a1') r1 \gset
select pg_temp.ck('old call unchanged: logged now, source tablet, operator = staff', (select abs(extract(epoch from logged_at - now())) < 5 and source = 'tablet' and operator = 'Casaro Prova' and corrective_action is null from fabula.haccp_log where id = (:'r1'::jsonb->>'haccp_log_id')::uuid));
select fabula.log_ccp(p_cp_code => 'PRP-PAST-VALVE', p_value => 0, p_staff_id => '10000000-0000-4000-a000-0000000000a1', p_source => 'paper') r1b \gset
select pg_temp.ck('old call cannot pass itself off as paper', (select source = 'tablet' from fabula.haccp_log where id = (:'r1b'::jsonb->>'haccp_log_id')::uuid));
select fabula.log_ccp(p_cp_code => 'CCP-COLD-1', p_value => 3.5, p_logged_at => now() - interval '1 day 2 hours', p_staff_id => '10000000-0000-4000-a000-0000000000a1', p_source => 'paper', p_written_by => 'Aiuto Prova') r2 \gset
select pg_temp.ck('paper: keeps the sheet time, source paper, operator = who wrote it, note says who copied',
  (select abs(extract(epoch from logged_at - (now() - interval '1 day 2 hours'))) < 5 and source = 'paper' and operator = 'Aiuto Prova' and operator_id = '10000000-0000-4000-a000-0000000000a2'
     and corrective_action like 'Ricopiata dal foglio cartaceo da Casaro Prova il %' from fabula.haccp_log where id = (:'r2'::jsonb->>'haccp_log_id')::uuid), :'r2');
select fabula.log_ccp(p_cp_code => 'CCP-COLD-1', p_value => 9, p_logged_at => now() - interval '3 hours', p_staff_id => '10000000-0000-4000-a000-0000000000a1', p_source => 'paper', p_action => 'spostato in cella 2') r3 \gset
select pg_temp.ck('paper out of limit: same non-conformity as live, action kept + note', :'r3'::jsonb->>'result' = 'non_conformity' and (:'r3'::jsonb->>'nc_id') is not null
  and (select corrective_action like 'spostato in cella 2 · Ricopiata%' from fabula.haccp_log where id = (:'r3'::jsonb->>'haccp_log_id')::uuid));
do $$ begin perform fabula.log_ccp(p_cp_code => 'CCP-COLD-1', p_value => 3, p_logged_at => now() - interval '8 days', p_source => 'paper', p_staff_id => '10000000-0000-4000-a000-0000000000a1'); raise notice 'NOFAIL'; exception when others then raise notice 'REFUSED %', sqlerrm; end $$;
do $$ begin perform fabula.log_ccp(p_cp_code => 'CCP-COLD-1', p_value => 3, p_logged_at => now() + interval '1 hour', p_source => 'paper', p_staff_id => '10000000-0000-4000-a000-0000000000a1'); raise notice 'NOFAIL'; exception when others then raise notice 'REFUSED %', sqlerrm; end $$;
select fabula.log_ccp(p_cp_code => 'CCP-COLD-2', p_value => 3, p_logged_at => now() - interval '10 days', p_staff_id => '10000000-0000-4000-a000-0000000000a1', p_source => 'tablet') r4 \gset
select pg_temp.ck('a non-paper call with p_logged_at still records now', (select abs(extract(epoch from logged_at - now())) < 5 from fabula.haccp_log where id = (:'r4'::jsonb->>'haccp_log_id')::uuid));
select pg_temp.ck('grants: signed-in yes, anon no', has_function_privilege('authenticated', 'fabula.log_ccp(text, numeric, timestamptz, uuid, text, text, text, text, text)', 'execute') and not has_function_privilege('anon', 'fabula.log_ccp(text, numeric, timestamptz, uuid, text, text, text, text, text)', 'execute'));
