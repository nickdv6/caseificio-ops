-- v1.07 «Prima dell'avvio» · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh q_test
--   su postgres -c "psql -d q_test -f tools/go-live/drill/prod-test/test_v107_quiet.sql" | grep -E "PASS|FAIL"
-- «Primo giorno con le attività» is 10 days from today and the trial week 12 days from today: the floor checks wake up on day 10,
-- the milk plan on day 12. Nothing real exists at the start (the replay has no milk, lots, records or stock).
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
insert into fabula.staff (id, full_name, role, app_role, active, auth_user_id) values
  ('10000000-0000-4000-a000-000000107a01', 'Titolare Q', 'owner', 'titolare', true, '00000000-0000-4000-a000-000000107a01'),
  ('10000000-0000-4000-a000-000000107a03', 'Socio NY Q', 'owner', 'socio', true, '00000000-0000-4000-a000-000000107a03')
on conflict do nothing;
\set tit_staff '10000000-0000-4000-a000-000000107a01'
\set ny_staff '10000000-0000-4000-a000-000000107a03'
insert into fabula.notify_targets (staff_id, topics, tz) values (:'ny_staff', array['decisions'], 'America/New_York') on conflict (staff_id) do update set tz = excluded.tz;
select (now() at time zone 'Europe/Rome')::date d \gset
select (now() at time zone 'Europe/Rome')::date - 1 y \gset
-- the day the automatic plan works on: tomorrow, Monday when tomorrow is Sunday
select case when extract(isodow from :'d'::date + 1) = 7 then :'d'::date + 2 else :'d'::date + 1 end pd \gset
-- the next Monday (1..7 days ahead) and a Mon–Sat day for the evening check
select :'d'::date + (8 - extract(isodow from :'d'::date)::int) mon \gset
select case when extract(isodow from :'d'::date) = 7 then :'d'::date + 1 else :'d'::date end wd \gset
update fabula.settings set value = (:'d'::date + 10)::text where key = 'prod.tasks_from';
insert into fabula.settings (key, value) values ('trial.start', (:'d'::date + 12)::text) on conflict (key) do update set value = excluded.value;
select id moz from fabula.products where sku = 'MOZ-DOP-KG' \gset
insert into fabula.parties (type, legal_name, is_milk_supplier) values ('supplier', 'Masseria Q', true) returning id sup \gset

-- ============================== the switch and the dates ==============================
select pg_temp.ck('setting prod.quiet_before_start: a Sì/No flag, on by default, sorted after «Primo giorno con le attività»',
  (select value = '1' and kind = 'flag' and data_type = 'number' and sort > (select sort from fabula.settings where key = 'prod.tasks_from')
     from fabula.settings where key = 'prod.quiet_before_start'));
select pg_temp.ck('quiet_until = the first of tasks, trial, opening (day 10); milk_start = the trial week ahead (day 12)',
  fabula.quiet_until() = :'d'::date + 10 and fabula.milk_start(:'d'::date) = :'d'::date + 12, fabula.quiet_until() || ' / ' || fabula.milk_start(:'d'::date));
select pg_temp.ck('quiet_day: today and day 9 are quiet; day 10 is not',
  fabula.quiet_day(:'d'::date) and fabula.quiet_day(:'d'::date + 9) and not fabula.quiet_day(:'d'::date + 10));
select pg_temp.ck('quiet_milk_day: day 11 is still quiet for the milk plan (cold-room tasks started early do not bring the plans back); day 12 is not',
  fabula.quiet_milk_day(:'d'::date + 11) and not fabula.quiet_milk_day(:'d'::date + 12));
update fabula.settings set value = '0' where key = 'prod.quiet_before_start';
select pg_temp.ck('«No» turns both off', not fabula.quiet_day(:'d'::date) and not fabula.quiet_milk_day(:'d'::date));
update fabula.settings set value = '1' where key = 'prod.quiet_before_start';
select pg_temp.ck('a null day is never quiet (false, not null)', fabula.quiet_day(null) is false and fabula.quiet_milk_day(null) is false);
-- a trial week already over does not bring back the milk proposals (production waits for the opening); a running one does
update fabula.settings set value = (:'d'::date - 30)::text where key = 'trial.start';
select pg_temp.ck('trial week over 25 days ago: the milk plan waits for the opening, quiet', fabula.milk_start(:'pd'::date) = fabula._setting_date('mkt.store_opening_date')
  and fabula.quiet_milk_day(:'pd'::date), fabula.milk_start(:'pd'::date)::text);
update fabula.settings set value = (:'d'::date - 2)::text where key = 'trial.start';
select pg_temp.ck('trial week running (started 2 days ago, 5 days): the milk plan proposes', not fabula.quiet_milk_day(:'d'::date) and not fabula.quiet_day(:'d'::date));
update fabula.settings set value = (:'d'::date + 12)::text where key = 'trial.start';
-- HACCP records alone are not production: a cold-room reading (a tablet test, or readings started early) changes nothing
insert into fabula.haccp_log (control_point_id, logged_at, measured_value, result, source, operator)
select id, now() - interval '1 day', 4, 'ok', 'tablet', 'Prova Q' from fabula.haccp_control_points where code = 'CCP-COLD-1' returning id hq \gset
select pg_temp.ck('a real cold-room reading yesterday: still quiet for the floor and for the milk plan',
  :'hq' <> '' and fabula.quiet_day(:'d'::date) and fabula.quiet_milk_day(:'pd'::date));
delete from fabula.haccp_log where id = :'hq';
select pg_temp.ck('the helpers can be run by logins (not anon); the digest helper only by the database',
  has_function_privilege('authenticated', 'fabula.quiet_day(date)', 'execute') and has_function_privilege('authenticated', 'fabula.quiet_milk_day(date)', 'execute')
  and not has_function_privilege('anon', 'fabula.quiet_day(date)', 'execute') and not has_function_privilege('anon', 'fabula._real_activity(date)', 'execute')
  and not has_function_privilege('authenticated', 'fabula._digest_golive(date)', 'execute'));

-- ============================== the milk plan ==============================
select count(*) plans0 from fabula.milk_plans \gset
select count(*) appr0 from fabula.approvals \gset
select fabula.plan_milk()::text pm1 \gset
select pg_temp.ck('automatic plan on a quiet day: skipped «pre_opening», with the production start and a message',
  (:'pm1'::jsonb ->> 'skipped') = 'pre_opening' and (:'pm1'::jsonb ->> 'tasks_start')::date = :'d'::date + 12
  and (:'pm1'::jsonb ->> 'date')::date = :'pd'::date
  and (:'pm1'::jsonb ->> 'message_it') like 'Nessun piano latte prima dell''avvio: il primo sarà per ' || fabula.it_day((:'pm1'::jsonb ->> 'first_plan_day')::date) || '. %', :'pm1');
select pg_temp.ck('…the first plan day is the start, or the Monday after when the start is a Sunday',
  (:'pm1'::jsonb ->> 'first_plan_day')::date = case when extract(isodow from :'d'::date + 12) = 7 then :'d'::date + 13 else :'d'::date + 12 end);
select pg_temp.ck('…and creates no plan and no approval (nothing to decide, nothing on Telegram, nothing on the farm page)',
  (select count(*) from fabula.milk_plans) = :plans0 and (select count(*) from fabula.approvals) = :appr0);
select fabula.plan_milk(:'d'::date + 3)::text pm2 \gset
select pg_temp.ck('a plan asked for a given day is still made', (:'pm2'::jsonb ->> 'approval_id') is not null and not (:'pm2'::jsonb ? 'skipped'), :'pm2');
select fabula.plan_milk(:'pd'::date)::text pmx \gset
select fabula.plan_milk()::text pm4 \gset
select pg_temp.ck('a plan that already exists for the planned day is reported as such, not as «prima dell''avvio»',
  (:'pm4'::jsonb ->> 'skipped') = 'plan_exists', :'pm4');
delete from fabula.milk_plans where id = (:'pmx'::jsonb ->> 'plan_id')::uuid;
delete from fabula.approvals where id = (:'pmx'::jsonb ->> 'approval_id')::uuid;
update fabula.settings set value = :'pd' where key = 'trial.start';
select fabula.plan_milk()::text pm3 \gset
select pg_temp.ck('the evening before the trial week, the automatic plan proposes again',
  (:'pm3'::jsonb ->> 'approval_id') is not null and (:'pm3'::jsonb ->> 'date')::date = :'pd'::date, :'pm3');
update fabula.settings set value = (:'d'::date + 12)::text where key = 'trial.start';
delete from fabula.milk_plans where id = (:'pm3'::jsonb ->> 'plan_id')::uuid;
delete from fabula.approvals where id = (:'pm3'::jsonb ->> 'approval_id')::uuid;

select fabula.bot_fallback_run('milk_planning', :'d'::date)::text fb \gset
select pg_temp.ck('the database''s stand-in (and «Esegui ora») says the same, as information',
  (:'fb'::jsonb ->> 'severity') = 'info' and (:'fb'::jsonb ->> 'title') = 'Nessun piano latte prima dell''avvio'
  and (:'fb'::jsonb ->> 'body') like 'Nessun piano latte prima dell''avvio: il primo sarà per %' and (:'fb'::jsonb ->> 'summary') = 'nessun piano prima dell''avvio', :'fb');
select fabula._why_explain('plan_milk', :'pm1'::jsonb, null)::text why \gset
select pg_temp.ck('«Perché?» of that message: no plan, the day, the first plan and what would bring it back',
  (:'why'::jsonb ->> 'title') = 'Nessun piano latte prima dell''avvio' and :'why' like '%Primo piano%' and :'why' like '%Latte, lotti o prodotto veri%'
  and :'why' like '%Silenzio prima dell''avvio%', :'why');
select fabula._why_explain('plan_milk', '{"date":"2026-11-02","skipped":"plan_exists","plan":{"milk_kg":900,"status":"proposed","planned_output_kg":270}}'::jsonb, null)::text why2 \gset
select pg_temp.ck('«Perché?» of an existing plan is unchanged', (:'why2'::jsonb ->> 'title') like 'Piano latte per % già pronto', :'why2');

-- real milk before the start: the plan comes back by itself (food safety and production first)
insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source)
values (:'d'::date - 2, '07:00', :'sup', 'MQ107-A', 800, true, 4, 'tablet');
select pg_temp.ck('real milk in the last 7 days: no day is quiet any more (floor or milk)',
  fabula._real_activity(:'d'::date) and not fabula.quiet_day(:'d'::date) and not fabula.quiet_milk_day(:'pd'::date));
select fabula.plan_milk()::text pm5 \gset
select pg_temp.ck('…and the automatic plan is made again', (:'pm5'::jsonb ->> 'approval_id') is not null, left(:'pm5', 200));
delete from fabula.milk_plans where id = (:'pm5'::jsonb ->> 'plan_id')::uuid;
delete from fabula.approvals where id = (:'pm5'::jsonb ->> 'approval_id')::uuid;
delete from fabula.milk_intake where milk_lot = 'MQ107-A';
insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source)
values (:'d'::date - 2, '07:00', :'sup', 'MQ107-SIM', 800, true, 4, 'simulation');
select pg_temp.ck('a simulated delivery does not count as real',
  (select count(*) from fabula.milk_intake where milk_lot = 'MQ107-SIM') = 1 and not fabula._real_activity(:'d'::date) and fabula.quiet_milk_day(:'pd'::date));
delete from fabula.milk_intake where milk_lot = 'MQ107-SIM';
-- a plan proposed by hand from the Console is marked, so the closing of automatic plans never touches it
select case when extract(isodow from :'d'::date + 8) = 7 then :'d'::date + 9 else :'d'::date + 8 end md \gset
select fabula.milk_order_again(:'md'::date)::text moa \gset
select pg_temp.ck('Console «Proponi di nuovo» (milk_order_again): the plan is made on a quiet day and marked «manual»',
  (select coalesce((payload->>'manual')::boolean, false) from fabula.approvals where id = (:'moa'::jsonb ->> 'approval_id')::uuid), :'moa');
delete from fabula.milk_plans where approval_id = (:'moa'::jsonb ->> 'approval_id')::uuid;
delete from fabula.approvals where id = (:'moa'::jsonb ->> 'approval_id')::uuid;

-- ============================== the evening check ==============================
select fabula.ops_health_check(:'wd'::date)::text oh1 \gset
select pg_temp.ck('evening check on a quiet working day: no «tablet silenzioso», no «conta di magazzino»',
  not exists (select 1 from jsonb_array_elements(:'oh1'::jsonb -> 'data_quality') x where x->>'key' in ('tablet_silent', 'stock_count_never', 'stock_count_overdue')), :'oh1');
update fabula.settings set value = '0' where key = 'prod.quiet_before_start';
select fabula.ops_health_check(:'wd'::date)::text oh2 \gset
select pg_temp.ck('…with «Silenzio prima dell''avvio» off both come back (as at work)',
  exists (select 1 from jsonb_array_elements(:'oh2'::jsonb -> 'data_quality') x where x->>'key' = 'tablet_silent')
  and exists (select 1 from jsonb_array_elements(:'oh2'::jsonb -> 'data_quality') x where x->>'key' = 'stock_count_never'), :'oh2');
update fabula.settings set value = '1' where key = 'prod.quiet_before_start';

-- ============================== the briefs ==============================
select fabula.daily_brief(:'y'::date)::text db1 \gset
select pg_temp.ck('morning brief on a quiet day: no HACCP checks and no overdue tasks asked, pre_opening with the start',
  jsonb_array_length(:'db1'::jsonb #> '{haccp,missing_daily_checks}') = 0 and jsonb_array_length(:'db1'::jsonb #> '{haccp,evening_cold_checks_missing}') = 0
  and jsonb_array_length(:'db1'::jsonb #> '{tasks,overdue}') = 0 and (:'db1'::jsonb #>> '{pre_opening,tasks_start}')::date = :'d'::date + 10
  and (:'db1'::jsonb ? 'changes'), left(:'db1', 300));
select fabula._why_explain('daily_brief', :'db1'::jsonb, null)::text whyd \gset
select pg_temp.ck('…its «Perché?» says the day''s checks are not asked before the start (it does not read as «all done»)',
  :'whyd' like '%Prima dell''avvio%controlli del giorno non richiesti%', left(:'whyd', 400));
update fabula.settings set value = '0' where key = 'prod.quiet_before_start';
select fabula.daily_brief(:'y'::date)::text db2 \gset
select pg_temp.ck('…with the switch off, the missing HACCP checks are asked again (and no pre_opening)',
  jsonb_array_length(:'db2'::jsonb #> '{haccp,missing_daily_checks}') > 0 and not (:'db2'::jsonb ? 'pre_opening'));
update fabula.settings set value = '1' where key = 'prod.quiet_before_start';
insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source)
values (:'y'::date, '07:00', :'sup', 'MQ107-Y', 300, true, 4, 'tablet');
select fabula.daily_brief(:'y'::date)::text db3 \gset
select pg_temp.ck('food safety first: real milk on a quiet day brings the HACCP checks back',
  jsonb_array_length(:'db3'::jsonb #> '{haccp,missing_daily_checks}') > 0 and not (:'db3'::jsonb ? 'pre_opening'));
select fabula.weekly_brief(:'y'::date + (6 - extract(isodow from :'y'::date)::int + 7) % 7)::text wbm \gset
select pg_temp.ck('…and in the weekly brief of that week (real milk, no lot): the missing checks are counted',
  not (:'wbm'::jsonb ? 'pre_opening'), left(:'wbm', 200));
delete from fabula.milk_intake where milk_lot = 'MQ107-Y';
-- product kept in the cold room from an earlier day (nothing worked yesterday)
insert into fabula.stock_moves (moved_at, product_id, lot_number, expiry_date, qty, move_type, reason, source)
values (now() - interval '3 days', :'moz', 'LQ107-S1', :'d'::date + 3, 60, 'adjustment', 'test v1.07', 'tablet');
select fabula.daily_brief(:'y'::date)::text db4 \gset
select pg_temp.ck('food safety first: real product in stock brings the cold-room checks back even with nothing worked that day',
  (select count(*) from fabula.stock_moves where lot_number = 'LQ107-S1') = 1
  and jsonb_array_length(:'db4'::jsonb #> '{haccp,missing_daily_checks}') > 0 and not (:'db4'::jsonb ? 'pre_opening'), left(:'db4', 200));
select fabula._haccp_evening_items(:'d'::date)::text ev1 \gset
select pg_temp.ck('…and the tablet''s evening list asks for the cold rooms before the tasks start',
  :'ev1' like '%cold:%', :'ev1');
insert into fabula.stock_moves (moved_at, product_id, lot_number, qty, move_type, reason, source)
values (now() - interval '20 days', :'moz', null, -80, 'adjustment', 'test v1.07 vendita senza lotto', 'tablet');
select pg_temp.ck('stock is counted per lot: a sale without a lot does not hide the 60 kg of lot LQ107-S1', fabula._real_activity(:'y'::date));
delete from fabula.stock_moves where reason in ('test v1.07', 'test v1.07 vendita senza lotto');
select fabula._haccp_evening_items(:'d'::date)::text ev2 \gset
select pg_temp.ck('with nothing real, the evening list stays empty before the tasks start (as v1.05)', :'ev2' = '[]', :'ev2');

select fabula.weekly_brief()::text wb1 \gset
select pg_temp.ck('weekly brief of a quiet week: missing HACCP checks 0 in both weeks, pre_opening, changes still computed',
  (:'wb1'::jsonb #>> '{this_week,compliance,missing_checks}')::int = 0 and (:'wb1'::jsonb #>> '{previous_week,compliance,missing_checks}')::int = 0
  and (:'wb1'::jsonb ? 'pre_opening') and (:'wb1'::jsonb ? 'changes'), left(:'wb1', 300));
select fabula._why_explain('weekly_brief', :'wb1'::jsonb, null)::text whyw \gset
select pg_temp.ck('…its «Perché?» says the missing checks are not counted before the start', :'whyw' like '%prima dell''avvio (% non si contano%', left(:'whyw', 300));
update fabula.settings set value = '0' where key = 'prod.quiet_before_start';
select fabula.weekly_brief()::text wb2 \gset
select pg_temp.ck('…with the switch off, the week''s missing checks are counted again',
  (:'wb2'::jsonb #>> '{this_week,compliance,missing_checks}')::int > 0 and not (:'wb2'::jsonb ? 'pre_opening'));
update fabula.settings set value = '1' where key = 'prod.quiet_before_start';
-- the first week after the start: this week is counted, the previous one (still quiet) is not compared against phantom misses
update fabula.settings set value = :'wb1'::jsonb ->> 'week_start' where key = 'prod.tasks_from';
select fabula.weekly_brief()::text wb3 \gset
select pg_temp.ck('first week after the start: this week''s missing checks counted, the previous (quiet) week 0, no pre_opening',
  (:'wb3'::jsonb #>> '{this_week,compliance,missing_checks}')::int > 0 and (:'wb3'::jsonb #>> '{previous_week,compliance,missing_checks}')::int = 0
  and not (:'wb3'::jsonb ? 'pre_opening'), left(:'wb3', 200));
update fabula.settings set value = (:'d'::date + 10)::text where key = 'prod.tasks_from';

-- ============================== an expiry is not a decision ==============================
update fabula.approvals set expires_at = now() - interval '1 minute' where id = (:'pm2'::jsonb ->> 'approval_id')::uuid;
select fabula.expire_approvals() nexp \gset
select pg_temp.ck('an expired milk plan still reaches Telegram once…',
  :nexp >= 1 and exists (select 1 from fabula.notify_outbox where dedupe_key = 'exp:' || (:'pm2'::jsonb ->> 'approval_id') and topic = 'decisions'));
select pg_temp.ck('…without the «Nessuno se ne occupa» reminder 30 minutes later',
  (select escalate_at from fabula.notify_outbox where dedupe_key = 'exp:' || (:'pm2'::jsonb ->> 'approval_id')) is null);
select fabula.notify_enqueue('decisions', 'Decisione di prova Q', 'x', 'Prova') dq \gset
select pg_temp.ck('a decision still waiting keeps its 30-minute reminder', (select escalate_at from fabula.notify_outbox where id = :'dq') is not null);
delete from fabula.notify_outbox where id = :'dq';

-- ============================== «Verso l'apertura» on Monday ==============================
select fabula.notify_digest_text(:'tit_staff', now() - interval '1 day', ((:'mon'::date + time '07:30') at time zone 'Europe/Rome')) dg1 \gset
select pg_temp.ck('Monday''s summary while quiet: «Verso l''apertura» with done / total, from when it starts and the next items',
  :'dg1' like '%<b>Verso l''apertura</b> % di % fatti · si parte ' || fabula.it_day(:'d'::date + 10) || ' (tra % giorni)%' and :'dg1' like '%' || E'\n' || '• %', :'dg1');
select pg_temp.ck('…the block comes before the Console link',
  position('Verso l''apertura' in :'dg1') > 0 and (position('Apri la Console' in :'dg1') = 0 or position('Verso l''apertura' in :'dg1') < position('Apri la Console' in :'dg1')));
select fabula.notify_digest_text(:'tit_staff', now() - interval '1 day', ((:'mon'::date + 1 + time '07:30') at time zone 'Europe/Rome')) dg2 \gset
select pg_temp.ck('Tuesday''s summary: no block', :'dg2' not like '%Verso l''apertura%', :'dg2');
select fabula.notify_digest_text(:'ny_staff', now() - interval '1 day', ((:'mon'::date + time '07:30') at time zone 'America/New_York')) dg5 \gset
select pg_temp.ck('a reader in New York gets it on his Monday morning', :'dg5' like '%Verso l''apertura%', :'dg5');
update fabula.settings set value = (:'mon'::date + 1)::text where key = 'prod.tasks_from';
select fabula.notify_digest_text(:'tit_staff', now() - interval '1 day', ((:'mon'::date + time '07:30') at time zone 'Europe/Rome')) dg6 \gset
select pg_temp.ck('the day before the start it says «domani», never «tra 1 giorni»', :'dg6' like '%si parte % (domani)%' and :'dg6' not like '%tra 1 giorni%', :'dg6');
update fabula.settings set value = (:'d'::date - 1)::text where key = 'prod.tasks_from';
select fabula.notify_digest_text(:'tit_staff', now() - interval '1 day', ((:'mon'::date + time '07:30') at time zone 'Europe/Rome')) dg3 \gset
select pg_temp.ck('after the start: no block on Monday either', :'dg3' not like '%Verso l''apertura%', :'dg3');
update fabula.settings set value = (:'d'::date + 10)::text where key = 'prod.tasks_from';
insert into fabula.staff (id, full_name, role, app_role, active) values ('10000000-0000-4000-a000-000000107a02', 'Casaro Q', 'casaro', 'produzione', true) on conflict do nothing;
select fabula.notify_digest_text('10000000-0000-4000-a000-000000107a02', now() - interval '1 day', ((:'mon'::date + time '07:30') at time zone 'Europe/Rome')) dg4 \gset
select pg_temp.ck('a profile that does not see Sistema gets no block', :'dg4' not like '%Verso l''apertura%', :'dg4');

-- ============================== Shopify stock: selling at zero is the decision ==============================
\set inv '{"ok":true,"push":0,"setting":2,"counted":false,"available_kg":0,"variants":[{"variant_id":"q1","label":"Q-Mozzarella · 250 g","available_units":0,"shopify_qty":0,"tracked":true,"policy":"DENY","split_basis":"parti_uguali","set":false},{"variant_id":"q2","label":"Q-Mozzarella · 500 g","available_units":0,"shopify_qty":0,"tracked":true,"policy":"CONTINUE","split_basis":"parti_uguali","set":false},{"variant_id":"q3","label":"Q-Treccia · 1 kg","available_units":0,"shopify_qty":0,"tracked":false,"policy":"DENY","split_basis":"parti_uguali","set":false}],"untracked":["Q-Treccia · 1 kg"],"selling_at_zero":["Q-Mozzarella · 500 g"],"not_found":[],"errors":[]}'
update fabula.agent_runs set status = 'ok', finished_at = coalesce(finished_at, now()) where agent = 'shopify_inventory' and status = 'running';
select fabula.shopify_sync_start('shopify_inventory') r1 \gset
select fabula.shopify_sync_finish(:'r1', :'inv') f1 \gset
select body sb1 from fabula.bot_messages where run_id = :'r1' \gset
select pg_temp.ck('stock check: no request to turn off «Continua a vendere quando esaurito» (selling at zero is the decision)',
  :'sb1' not like '%togli «Continua a vendere quando esaurito»%', :'sb1');
select pg_temp.ck('…it names the tracked product that stops at zero instead (not the untracked one)',
  :'sb1' like '%1 prodotto si ferma a scorte zero: in Shopify attiva «Continua a vendere quando esaurito» (Q-Mozzarella · 250 g)%'
  and :'sb1' not like '%attiva «Continua a vendere quando esaurito» (%Q-Treccia%', :'sb1');
update fabula.settings set value = '0' where key = 'shopify.sell_at_zero';
update fabula.agent_runs set status = 'ok', finished_at = coalesce(finished_at, now()) where agent = 'shopify_inventory' and status = 'running';
select fabula.shopify_sync_start('shopify_inventory') r2 \gset
select fabula.shopify_sync_finish(:'r2', :'inv') f2 \gset
select body sb2 from fabula.bot_messages where run_id = :'r2' \gset
select pg_temp.ck('with «No» it asks to turn it off, as before (the changed decision gives a full message, not «invariato»)',
  :'sb2' like '%1 prodotto si vende anche a scorte zero: in Shopify togli «Continua a vendere quando esaurito» (Q-Mozzarella · 500 g)%', :'sb2');
update fabula.settings set value = '1' where key = 'shopify.sell_at_zero';
select pg_temp.ck('setting shopify.sell_at_zero exists as a Sì/No flag, on (the 02/10 decision)',
  (select value = '1' and kind = 'flag' from fabula.settings where key = 'shopify.sell_at_zero'));

-- ============================== the prompt ==============================
select pg_temp.ck('the milk planning prompt''s new version is expected', (select version from fabula.bot_prompt_versions where agent = 'milk_planning') = '581ad88a3f');
