-- v0.97 audit floor flows (A-05, A-15, D-04, D-15, A-08/D-29, A-22, D-05, A-14/D-08, A-20, A-23) · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh f_test
--   su postgres -c "psql -d f_test -f tools/go-live/drill/prod-test/test_audit_floor.sql" | grep -E "PASS|FAIL"
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as
$$ begin execute p_sql; return ''; exception when others then return sqlerrm || coalesce(' || ' || nullif(pg_temp.detail(), ''), ''); end $$;
create or replace function pg_temp.detail() returns text language sql as $$ select '' $$;
create or replace function pg_temp.as_user(p_sub text) returns void language sql as
$$ select set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_sub), false) $$;
create or replace function pg_temp.rome(p_day date, p_t time) returns timestamptz language sql as $$ select (p_day + p_t) at time zone 'Europe/Rome' $$;
create or replace function pg_temp.today() returns date language sql as $$ select (now() at time zone 'Europe/Rome')::date $$;
select id moz from fabula.products where sku = 'MOZ-DOP-KG' \gset
select id ric from fabula.products where sku = 'RIC-BUF-KG' \gset
select id cf1 from fabula.equipment where code = 'CF-01' \gset
select id cpclean from fabula.haccp_control_points where code = 'PRP-CLEAN' \gset
-- process steps by what they are (their ids differ between replays)
select s.id step_past, s.preset_id preset_past from fabula.process_steps s where s.ccp_code = 'CCP-PAST' order by s.step_order limit 1 \gset
select s.id step_ph from fabula.process_steps s where s.record_metric = 'ph' and s.phase = 'make' and s.preset_id = :'preset_past' limit 1 \gset
insert into fabula.staff (id, full_name, role, app_role, active, auth_user_id) values
  ('10000000-0000-4000-a000-0000000097a2', 'Casaro F', 'casaro', 'produzione', true, '00000000-0000-4000-a000-0000000097a2'),
  ('10000000-0000-4000-a000-0000000097a3', 'Banco F', 'commesso', 'banco', true, '00000000-0000-4000-a000-0000000097a3')
on conflict do nothing;
insert into fabula.parties (id, type, legal_name, is_milk_supplier, active) values ('50000000-0000-4000-a000-0000000097f1', 'supplier', 'Masseria F', true, true) on conflict do nothing;
\set CAS '''10000000-0000-4000-a000-0000000097a2'''

-- ============================== A-05 task list ==============================
delete from fabula.task_instances;
select fabula.generate_daily_tasks(pg_temp.today()) n_today, fabula.generate_daily_tasks(pg_temp.today() - 1) n_y, fabula.generate_daily_tasks(pg_temp.today() - 2) n_y2 \gset
select pg_temp.ck('A-05 the daily list is still generated once per schedule and time (generating again adds nothing)',
  :n_today > 0 and fabula.generate_daily_tasks(pg_temp.today()) = 0, :n_today || ' then again');
-- overdue the same day: a task 3 hours past its time, still «due» in the table, is red in the view
insert into fabula.task_instances (schedule_id, due_at) select id, now() - interval '3 hours' from fabula.task_schedules where code = 'T-KWH';
select pg_temp.ck('A-05 a task past its time + grace shows as overdue the same day (computed in the view)',
  exists (select 1 from fabula.v_tasks_open where code = 'T-KWH' and due_at < now() - interval '2 hours 30 minutes' and status = 'overdue')
  and exists (select 1 from fabula.task_instances ti join fabula.task_schedules s on s.id = ti.schedule_id where s.code = 'T-KWH' and ti.due_at < now() - interval '2 hours 30 minutes' and ti.status = 'due'));
select pg_temp.ck('A-05 the view says which tasks are today and which are from earlier days',
  (select bool_and(is_today = (due_day = pg_temp.today())) and bool_or(is_today) and bool_or(not is_today) from fabula.v_tasks_open));
-- twice-daily cold room: a re-check at 10:00 must not close the evening task
select fabula.close_open_task(pg_temp.today() - 1, null, :'cf1', null, :CAS, null, pg_temp.rome(pg_temp.today() - 1, '07:30')) c1 \gset
select coalesce(fabula.close_open_task(pg_temp.today() - 1, null, :'cf1', null, :CAS, null, pg_temp.rome(pg_temp.today() - 1, '10:00'))::text, '') c2 \gset
select pg_temp.ck('A-05 cold room 07:30 closes the 08:00 task, with the time of the check',
  (select ti.due_at = pg_temp.rome(pg_temp.today() - 1, '08:00') and ti.status = 'done' and ti.completed_at = pg_temp.rome(pg_temp.today() - 1, '07:30') from fabula.task_instances ti where ti.id = :'c1'));
select pg_temp.ck('A-05 …a re-check at 10:00 closes nothing: the 18:00 task stays open', :'c2' = '' and exists (
  select 1 from fabula.task_instances ti join fabula.task_schedules s on s.id = ti.schedule_id where s.code = 'T-CF1' and ti.due_at = pg_temp.rome(pg_temp.today() - 1, '18:00') and ti.status in ('due', 'overdue')));
select fabula.close_open_task(pg_temp.today() - 1, null, :'cf1', null, :CAS, null, pg_temp.rome(pg_temp.today() - 1, '18:40')) c3 \gset
select pg_temp.ck('A-05 …the evening reading closes the 18:00 task', (select due_at = pg_temp.rome(pg_temp.today() - 1, '18:00') from fabula.task_instances where id = :'c3'));
-- two days ago: morning forgotten; a reading at 14:30 closes the morning one, one at 19:00 the evening one (not the old morning)
select fabula.close_open_task(pg_temp.today() - 2, null, :'cf1', null, :CAS, null, pg_temp.rome(pg_temp.today() - 2, '19:00')) c4 \gset
select pg_temp.ck('A-05 with both open, a reading at 19:00 closes the evening task and leaves the missed morning one',
  (select due_at = pg_temp.rome(pg_temp.today() - 2, '18:00') from fabula.task_instances where id = :'c4')
  and exists (select 1 from fabula.task_instances ti join fabula.task_schedules s on s.id = ti.schedule_id where s.code = 'T-CF1' and ti.due_at = pg_temp.rome(pg_temp.today() - 2, '08:00') and ti.status in ('due', 'overdue')));
select fabula.close_open_task(pg_temp.today() - 2, null, :'cf1', null, :CAS, null, pg_temp.rome(pg_temp.today() - 2, '14:30')) c5 \gset
select pg_temp.ck('A-05 a late morning reading (14:30) still closes the missed morning task', (select due_at = pg_temp.rome(pg_temp.today() - 2, '08:00') from fabula.task_instances where id = :'c5'));
select fabula.close_open_task(pg_temp.today() - 1, null, null, :'cpclean', :CAS, null, pg_temp.rome(pg_temp.today() - 1, '15:00')) c6 \gset
select pg_temp.ck('A-05 a once-a-day task (cleaning 18:30) closes at any time of its day (15:00)', :'c6' <> '');
-- «Non fatta» with a reason
select ti.id skip1 from fabula.task_instances ti join fabula.task_schedules s on s.id = ti.schedule_id where s.code = 'T-PH' and ti.due_at = pg_temp.rome(pg_temp.today() - 1, '07:00') \gset
select pg_temp.as_user('00000000-0000-4000-a000-0000000097a3');
set role authenticated;
select pg_temp.err(format($q$select fabula.skip_task(%L, 'x')$q$, :'skip1')) e_skip0 \gset
select fabula.skip_task(:'skip1', 'pH-metro in riparazione', '10000000-0000-4000-a000-0000000097a3') s1 \gset
select pg_temp.err(format($q$select fabula.skip_task(%L, 'di nuovo')$q$, :'skip1')) e_skip2 \gset
reset role;
select pg_temp.ck('A-05 «Non fatta» needs a reason', :'e_skip0' like 'Scrivi perché%', :'e_skip0');
select pg_temp.ck('A-05 …with the reason the task is closed as skipped, by who said it', (select status = 'skipped' and skip_reason = 'pH-metro in riparazione' and completed_by_id = '10000000-0000-4000-a000-0000000097a3' from fabula.task_instances where id = :'skip1'), :'s1');
select pg_temp.ck('A-05 …and a closed task cannot be skipped again', :'e_skip2' like '%già chiusa%', :'e_skip2');
select set_config('request.jwt.claims', '', false);
select ti.id any_open from fabula.task_instances ti where status = 'due' limit 1 \gset
set role anon;
select pg_temp.err(format($q$select fabula.skip_task(%L, 'prova anonima')$q$, :'any_open')) e_anon \gset
reset role;
select pg_temp.ck('A-05 skip_task is not open to anonymous calls', :'e_anon' <> '', :'e_anon');
-- older than 7 days → closed as not done
insert into fabula.task_instances (schedule_id, due_at) select id, now() - interval '8 days' from fabula.task_schedules where code = 'T-KWH' returning id old8 \gset
select fabula.generate_daily_tasks(pg_temp.today()) \gset
select pg_temp.ck('A-05 a task open for more than 7 days is closed as not done, with the reason', (select status = 'skipped' and skip_reason like 'Non registrata entro 7 giorni%' from fabula.task_instances where id = :'old8'));

-- ============================== A-15 follow-ups ==============================
select pg_temp.as_user('00000000-0000-4000-a000-0000000097a2');
set role authenticated;
select fabula.log_ccp(p_cp_code => 'CCP-COLD-1', p_value => 5, p_staff_id => :CAS, p_source => 'tablet', p_equipment_code => 'CF-01') w1 \gset
reset role;
select ti.id fu1, ti.scan fu1_scan, ti.title_it fu1_title, ti.due_at - l.logged_at fu1_gap from fabula.task_instances ti join fabula.haccp_log l on l.id = ti.source_log_id where ti.followup_kind = 'recheck' and ti.status = 'due' order by ti.due_at desc limit 1 \gset
select pg_temp.ck('A-15 a cold room at 5 °C (alert band) creates «ricontrolla entro 1 ora», tapping it opens the cold room',
  :'fu1_scan' = 'EQ:CF-01' and :'fu1_gap' = '01:00:00' and :'fu1_title' like 'Ricontrolla Cella frigo 1 entro le %(era 5 °C)', :'fu1_title' || ' · ' || :'fu1_scan');
select pg_temp.ck('A-15 …it is on the open list with the cold room code', exists (select 1 from fabula.v_tasks_open where id = :'fu1' and followup_kind = 'recheck' and equipment_code = 'CF-01' and control_point_code = 'CCP-COLD-1'));
select pg_temp.as_user('00000000-0000-4000-a000-0000000097a2');
set role authenticated;
select fabula.log_ccp(p_cp_code => 'CCP-COLD-1', p_value => 3, p_staff_id => :CAS, p_source => 'tablet', p_equipment_code => 'CF-01') w2 \gset
reset role;
select pg_temp.ck('A-15 the next reading (3 °C) closes the re-check, linked to that reading',
  (select ti.status = 'done' and ti.haccp_log_id = (:'w2'::jsonb ->> 'haccp_log_id')::uuid from fabula.task_instances ti where ti.id = :'fu1')
  and not exists (select 1 from fabula.task_instances where followup_kind = 'recheck' and status = 'due'));
select pg_temp.as_user('00000000-0000-4000-a000-0000000097a2');
set role authenticated;
select fabula.log_ccp(p_cp_code => 'CCP-COLD-2', p_value => 9, p_staff_id => :CAS, p_action => 'porta aperta', p_source => 'tablet', p_equipment_code => 'CF-02') w3 \gset
reset role;
select ti.id fu2 from fabula.task_instances ti where ti.followup_kind = 'recheck' and ti.status = 'due' and ti.scan = 'EQ:CF-02' \gset
select pg_temp.ck('A-15 a cold room over its limit (9 °C, NC) also gets a re-check', :'fu2' <> '');
select pg_temp.as_user('00000000-0000-4000-a000-0000000097a2');
set role authenticated;
select fabula.log_ccp(p_cp_code => 'CCP-COLD-1', p_value => 4.5, p_staff_id => :CAS, p_source => 'tablet', p_equipment_code => 'CF-01') ->> 'haccp_log_id' w4 \gset
reset role;
select fabula.correct_record('haccp_log', :'w4', '{"measured_value": 3.5}', 'errore di battitura', :CAS) \gset
select pg_temp.ck('A-15 a reading corrected back into range («Correggi») closes its re-check as not needed (no false Telegram alert)',
  (select status = 'skipped' and skip_reason like 'Valore corretto%' from fabula.task_instances where source_log_id = :'w4'));
update fabula.task_instances set due_at = now() - interval '5 minutes' where id = :'fu2';
select fabula.followup_tick() t1 \gset
select fabula.followup_tick() t2 \gset
select pg_temp.ck('A-15 a re-check past its time goes to Telegram (food safety) once',
  :t1 >= 1 and :t2 = 0 and (select count(*) = 1 from fabula.notify_outbox where dedupe_key = 'fu:' || :'fu2' and topic = 'food_safety' and title like 'Non fatto in tempo: Ricontrolla Cella frigo 2%')
  and (select alerted_at is not null from fabula.task_instances where id = :'fu2'), :t1 || '/' || :t2);
select pg_temp.ck('A-15 …and shows as overdue on the list (no grace for follow-ups)', exists (select 1 from fabula.v_tasks_open where id = :'fu2' and status = 'overdue'));
select pg_temp.ck('A-15 a re-check is not closed by the daily task logic (close_open_task leaves follow-ups alone)',
  fabula.close_open_task(pg_temp.today(), null, (select id from fabula.equipment where code = 'CF-02'), null, :CAS) is distinct from :'fu2'::uuid);
-- warm milk: into the vat within 2 hours
insert into fabula.milk_intake (id, intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source)
values ('70000000-0000-4000-a000-0000000097d1', pg_temp.today(), (now() at time zone 'Europe/Rome')::time, '50000000-0000-4000-a000-0000000097f1', 'MF97-1', 800, true, 7.2, 'tablet');
select ti.id fum, ti.scan fum_scan, ti.title_it fum_title from fabula.task_instances ti where ti.followup_kind = 'milk_start' and ti.milk_intake_id = '70000000-0000-4000-a000-0000000097d1' \gset
select pg_temp.ck('A-15 milk accepted at 7,2 °C (over the 6 °C alert) creates «in caldaia entro 2 ore», tapping it opens the milk lot',
  :'fum_scan' = 'LOT:MF97-1' and :'fum_title' like 'Metti in caldaia il latte MF97-1 entro le % (arrivato a 7,2 °C)', :'fum_title');
insert into fabula.production_batches (id, batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, casaro_id, source)
values ('80000000-0000-4000-a000-0000000097b1', current_date, 'LF97-A', :'moz', 400, 'milk', now(), :CAS, 'tablet');
insert into fabula.batch_milk_inputs (batch_id, milk_intake_id, qty_kg) values ('80000000-0000-4000-a000-0000000097b1', '70000000-0000-4000-a000-0000000097d1', 400);
select pg_temp.ck('A-15 …the first vat started with that milk closes it, signed by the casaro', (select status = 'done' and completed_by_id = :CAS from fabula.task_instances where id = :'fum'));
insert into fabula.milk_intake (id, intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source)
values ('70000000-0000-4000-a000-0000000097d2', pg_temp.today(), (now() at time zone 'Europe/Rome')::time, '50000000-0000-4000-a000-0000000097f1', 'MF97-2', 500, true, 6.5, 'tablet');
select fabula.milk_reject('70000000-0000-4000-a000-0000000097d2', 'test antibiotici POSITIVO (ricontrollo)', :CAS, null, 'tablet') \gset
insert into fabula.milk_intake (id, intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source)
values ('70000000-0000-4000-a000-0000000097d5', pg_temp.today(), (now() at time zone 'Europe/Rome')::time, '50000000-0000-4000-a000-0000000097f1', 'MF97-5', 500, true, 6.8, 'tablet');
select set_config('fabula.correct_ctx', 'on', false) \gset
update fabula.milk_intake set temperature_c = 5.8 where id = '70000000-0000-4000-a000-0000000097d5';
select set_config('fabula.correct_ctx', '', false) \gset
select pg_temp.ck('A-15 a milk temperature corrected below the alert closes «in caldaia entro 2 ore»',
  (select status = 'skipped' and skip_reason like 'Temperatura corretta%' from fabula.task_instances where milk_intake_id = '70000000-0000-4000-a000-0000000097d5'));
select pg_temp.ck('A-15 milk rejected afterwards: its «in caldaia» follow-up is closed as not needed',
  (select status = 'skipped' and skip_reason = 'Latte respinto' from fabula.task_instances where milk_intake_id = '70000000-0000-4000-a000-0000000097d2'));
insert into fabula.milk_intake (id, intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source)
values ('70000000-0000-4000-a000-0000000097d3', pg_temp.today() - 2, '06:30', '50000000-0000-4000-a000-0000000097f1', 'MF97-3', 500, true, 7, 'paper');
insert into fabula.milk_intake (id, intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source)
values ('70000000-0000-4000-a000-0000000097d4', pg_temp.today(), (now() at time zone 'Europe/Rome')::time, '50000000-0000-4000-a000-0000000097f1', 'MF97-4', 500, true, 4, 'tablet');
select pg_temp.ck('A-15 no follow-up for a paper sheet copied days later, nor for milk at 4 °C',
  not exists (select 1 from fabula.task_instances where milk_intake_id in ('70000000-0000-4000-a000-0000000097d3', '70000000-0000-4000-a000-0000000097d4')));
-- A-23 cleaning with items not done
insert into fabula.haccp_log (control_point_id, result, operator, operator_id, corrective_action, source)
values (:'cpclean', 'warning', 'Casaro F', :CAS, 'Non fatto: Filatrice (pezzo rotto)', 'tablet') returning id cl1 \gset
select pg_temp.ck('A-23 a cleaning round with items not done is pushed to food safety with the reason',
  exists (select 1 from fabula.notify_outbox where dedupe_key = 'clean:' || :'cl1' and topic = 'food_safety' and body like '%Filatrice (pezzo rotto)%'));

-- ============================== D-04 offline times ==============================
select pg_temp.as_user('00000000-0000-4000-a000-0000000097a2');
set role authenticated;
select fabula.save_ops(jsonb_build_array(jsonb_build_object('rpc', 'log_ccp', 'args', jsonb_build_object('p_cp_code', 'CCP-COLD-2', 'p_value', 2.5, 'p_staff_id', :CAS, 'p_source', 'tablet', 'p_equipment_code', 'CF-02'))),
  '30000000-0000-4000-a000-0000000097e1', now() - interval '40 minutes') o1 \gset
select fabula.save_ops(jsonb_build_array(jsonb_build_object('rpc', 'log_ccp', 'args', jsonb_build_object('p_cp_code', 'CCP-COLD-2', 'p_value', 2.6, 'p_staff_id', :CAS, 'p_source', 'tablet', 'p_equipment_code', 'CF-02'))),
  '30000000-0000-4000-a000-0000000097e2', now() - interval '30 seconds') o2 \gset
select fabula.save_ops(jsonb_build_array(jsonb_build_object('rpc', 'log_ccp', 'args', jsonb_build_object('p_cp_code', 'CCP-COLD-2', 'p_value', 2.7, 'p_staff_id', :CAS, 'p_source', 'tablet', 'p_equipment_code', 'CF-02'))),
  '30000000-0000-4000-a000-0000000097e3', now() - interval '10 days') o3 \gset
select fabula.save_ops(jsonb_build_array(jsonb_build_object('rpc', 'log_ccp', 'args', jsonb_build_object('p_cp_code', 'CCP-COLD-2', 'p_value', 2.8, 'p_staff_id', :CAS, 'p_source', 'tablet', 'p_equipment_code', 'CF-02'))),
  '30000000-0000-4000-a000-0000000097e4', now() + interval '3 hours') o4 \gset
-- the tablet's clock is 3 hours behind: queued «40 minutes ago» by its clock, sent «now» by its clock
select fabula.save_ops(jsonb_build_array(jsonb_build_object('rpc', 'log_ccp', 'args', jsonb_build_object('p_cp_code', 'CCP-COLD-2', 'p_value', 2.4, 'p_staff_id', :CAS, 'p_source', 'tablet', 'p_equipment_code', 'CF-02'))),
  '30000000-0000-4000-a000-0000000097e9', now() - interval '3 hours 40 minutes', now() - interval '3 hours') o9 \gset
-- a save made just now on a tablet whose clock is 3 hours behind: the database time
select fabula.save_ops(jsonb_build_array(jsonb_build_object('rpc', 'log_ccp', 'args', jsonb_build_object('p_cp_code', 'CCP-COLD-2', 'p_value', 2.3, 'p_staff_id', :CAS, 'p_source', 'tablet', 'p_equipment_code', 'CF-02'))),
  '30000000-0000-4000-a000-0000000097ea', now() - interval '3 hours', now() - interval '3 hours') o10 \gset
reset role;
select pg_temp.ck('D-04 a check queued offline 40 minutes ago keeps that time; created_at is when it arrived',
  (select abs(extract(epoch from (logged_at - (now() - interval '40 minutes')))) < 5 and created_at > now() - interval '1 minute' from fabula.haccp_log where measured_value = 2.5 and source = 'tablet'));
select pg_temp.ck('D-04 …a save made seconds ago, one 10 days old and one «from the future» (wrong clock) get the time it arrived',
  (select bool_and(logged_at > now() - interval '1 minute') and count(*) = 3 from fabula.haccp_log where measured_value in (2.6, 2.7, 2.8)));
select pg_temp.ck('D-04 with the tablet clock 3 hours behind, only the age counts: queued 40 minutes ago → 40 minutes ago; just made → now',
  (select abs(extract(epoch from (logged_at - (now() - interval '40 minutes')))) < 5 from fabula.haccp_log where measured_value = 2.4)
  and (select logged_at > now() - interval '1 minute' from fabula.haccp_log where measured_value = 2.3));
select (fabula.haccp_register('MOD-05', pg_temp.today() - 1, pg_temp.today()) -> 'rows') r05 \gset
select pg_temp.ck('D-04 the register prints «inserito nel sistema alle …» on the offline checks only',
  (select count(*) = 2 from jsonb_array_elements(:'r05'::jsonb) r where r::text like '%inserito nel sistema alle%'), left(:'r05', 300));
-- cleaning (direct insert), task closing and a process step, all queued offline 25 minutes ago
select ti.id tclean from fabula.task_instances ti join fabula.task_schedules s on s.id = ti.schedule_id where s.code = 'T-CLEAN' and ti.due_at = pg_temp.rome(pg_temp.today(), '18:30') \gset
insert into fabula.production_batches (id, batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, source, preset_id)
select '80000000-0000-4000-a000-0000000097b2', current_date, 'LF97-B', :'moz', 300, 'milk', now() - interval '1 hour', 'tablet', :'preset_past';
select pg_temp.as_user('00000000-0000-4000-a000-0000000097a2');
set role authenticated;
select fabula.save_ops(jsonb_build_array(
  jsonb_build_object('table', 'haccp_log', 'row', jsonb_build_object('control_point_id', :'cpclean', 'result', 'ok', 'operator', 'Casaro F', 'operator_id', :CAS, 'source', 'tablet')),
  jsonb_build_object('rpc', 'close_open_task', 'args', jsonb_build_object('p_day', pg_temp.today(), 'p_control_point_id', :'cpclean', 'p_staff_id', :CAS)),
  jsonb_build_object('rpc', 'log_batch_step', 'args', jsonb_build_object('p_batch_lot', 'LF97-B', 'p_step_id', :'step_past', 'p_actual', 74, 'p_staff_id', :CAS))),
  '30000000-0000-4000-a000-0000000097e5', now() - interval '25 minutes') o5 \gset
reset role;
select pg_temp.ck('D-04 offline cleaning record keeps the time it was done',
  (select abs(extract(epoch from (logged_at - (now() - interval '25 minutes')))) < 5 from fabula.haccp_log where control_point_id = :'cpclean' and result = 'ok' order by created_at desc limit 1));
select pg_temp.ck('D-04 …the task it closes is marked done at that time', (select status = 'done' and abs(extract(epoch from (completed_at - (now() - interval '25 minutes')))) < 5 from fabula.task_instances where id = :'tclean'));
select pg_temp.ck('D-04 …a CCP recorded as a process step (pasteurisation) keeps the step time in the HACCP register',
  (select abs(extract(epoch from (l.logged_at - (now() - interval '25 minutes')))) < 5 and l.source = 'preset' from fabula.haccp_log l join fabula.production_batches b on b.id = l.batch_id where b.batch_lot = 'LF97-B' and l.measured_value = 74)
  and (select abs(extract(epoch from (logged_at - (now() - interval '25 minutes')))) < 5 from fabula.batch_step_logs where batch_id = '80000000-0000-4000-a000-0000000097b2'));

-- ============================== A-22 a step confirmed without measuring ==============================
select pg_temp.as_user('00000000-0000-4000-a000-0000000097a2');
set role authenticated;
select fabula.log_batch_step('LF97-B', :'step_ph', 5.05, :CAS) \gset
reset role;
update fabula.batch_step_logs set logged_at = now() - interval '20 minutes' where batch_id = '80000000-0000-4000-a000-0000000097b2' and step_id = :'step_ph';
select pg_temp.as_user('00000000-0000-4000-a000-0000000097a2');
set role authenticated;
select fabula.log_batch_step('LF97-B', :'step_ph', null, '10000000-0000-4000-a000-0000000097a3') \gset
reset role;
select pg_temp.ck('A-22 …and the time and person of the measurement', (select logged_at < now() - interval '19 minutes' and staff_id = :CAS from fabula.batch_step_logs
  where batch_id = '80000000-0000-4000-a000-0000000097b2' and step_id = :'step_ph'));
select pg_temp.ck('A-22 «Fatto (non misurato)» after a measured curd pH keeps the measured pH on the batch and the step',
  (select curd_ph = 5.05 from fabula.production_batches where batch_lot = 'LF97-B')
  and (select actual_value = 5.05 from fabula.batch_step_logs where batch_id = '80000000-0000-4000-a000-0000000097b2' and step_id = :'step_ph'));
insert into fabula.production_batches (id, batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, source)
values ('80000000-0000-4000-a000-0000000097b3', current_date, 'LF97-C', :'moz', 300, 'milk', now(), 'tablet');
select fabula.log_batch_step('LF97-C', :'step_ph', null, :CAS) \gset
select pg_temp.ck('A-22 …and on a batch never measured it writes no pH (the target is no longer stored as measured)',
  (select curd_ph is null from fabula.production_batches where batch_lot = 'LF97-C'));

-- ============================== A-08 / D-29 two tablets, same letter ==============================
select 'L' || to_char(pg_temp.today(), 'YYYYMMDD') || '-' pre \gset
insert into fabula.production_batches (id, batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, source)
values ('80000000-0000-4000-a000-0000000097c1', pg_temp.today(), :'pre' || 'A', :'moz', 300, 'milk', now() - interval '3 hours', 'tablet');
select pg_temp.as_user('00000000-0000-4000-a000-0000000097a2');
set role authenticated;
select fabula.save_ops(jsonb_build_array(
  jsonb_build_object('table', 'production_batches', 'row', jsonb_build_object('id', '80000000-0000-4000-a000-0000000097c2', 'batch_date', pg_temp.today(), 'batch_lot', :'pre' || 'A',
                     'product_id', :'moz', 'milk_in_kg', 250, 'started_at', now() - interval '2 hours', 'source', 'tablet'))),
  '30000000-0000-4000-a000-0000000097e6', now() - interval '2 hours') -> 0 ->> 'batch_lot' rl \gset
select pg_temp.err(format($q$select fabula.save_ops(jsonb_build_array(jsonb_build_object('table', 'production_batches', 'row', jsonb_build_object('id', '80000000-0000-4000-a000-0000000097c2', 'batch_date', %L, 'batch_lot', %L, 'product_id', %L, 'milk_in_kg', 250, 'source', 'tablet'))), null)$q$,
  pg_temp.today(), :'pre' || 'A', :'moz')) e_dupid \gset
reset role;
select pg_temp.ck('A-08 the second tablet''s «-A» becomes the next free letter, the saved row says so and the save returns it',
  :'rl' = :'pre' || 'B' and (select notes like '%Avviato sul tablet come ' || :'pre' || 'A, lettera già usata da un altro lotto: diventato ' || :'pre' || 'B%' from fabula.production_batches where id = '80000000-0000-4000-a000-0000000097c2')
  and (select batch_lot = :'pre' || 'A' from fabula.production_batches where id = '80000000-0000-4000-a000-0000000097c1'), :'rl');
select pg_temp.ck('A-08 the same row sent again is not renamed: it is refused as already saved, in Italian (D-15)',
  :'e_dupid' like 'Passo 1 di 1 (lotto di produzione): Questa registrazione è già nel database (inviata due volte)%', :'e_dupid');
select pg_temp.ck('A-08 other lot shapes (ricotta, test lots) are left alone', pg_temp.err($q$insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, input_kind, source) values (current_date, 'LF97-A', (select id from fabula.products where sku = 'MOZ-DOP-KG'), 1, 'milk', 'tablet')$q$) like '%duplicate key%');

-- ============================== D-15 Italian errors ==============================
select pg_temp.as_user('00000000-0000-4000-a000-0000000097a3');
set role authenticated;
select pg_temp.err(format($q$select fabula.save_ops(jsonb_build_array(jsonb_build_object('table', 'scan_events', 'row', jsonb_build_object('code', 'LOT:X', 'action', 'batch_start')),
  jsonb_build_object('table', 'production_batches', 'row', jsonb_build_object('batch_date', current_date, 'batch_lot', 'LF97-Q', 'product_id', %L, 'milk_in_kg', 10, 'source', 'tablet'))), null)$q$, :'moz')) e_rls \gset
reset role;
select pg_temp.ck('D-15 a profile without the right (Banco starting a batch) reads it in Italian, with the step named', :'e_rls' like 'Passo 2 di 2 (lotto di produzione): Il tuo profilo non può registrare questo (lotto di produzione): chiedi al responsabile%', :'e_rls');
select pg_temp.as_user('00000000-0000-4000-a000-0000000097a2');
set role authenticated;
select pg_temp.err($q$select fabula.save_ops(jsonb_build_array(jsonb_build_object('table', 'production_batches', 'update', jsonb_build_object('batch_lot', 'LF97-NONE'), 'row', jsonb_build_object('output_kg', 5))), null)$q$) e_none \gset
select pg_temp.err($q$select fabula.save_ops(jsonb_build_array(jsonb_build_object('table', 'stock_count_lines', 'row', jsonb_build_object('x', 1))), null)$q$) e_tab \gset
reset role;
select pg_temp.ck('D-15 closing a lot that never reached the database says so (start refused?) and to tell the office', :'e_none' like 'Passo 1 di 1 (lotto di produzione): Il lotto non è nel database (forse il suo avvio era stato rifiutato): avvisa l''ufficio%', :'e_none');
select pg_temp.ck('D-15 messages that are already Italian are kept', :'e_tab' like 'Passo 1 di 1 (stock_count_lines): tabella non ammessa%', :'e_tab');
select pg_temp.as_user('00000000-0000-4000-a000-0000000097a2');
set role authenticated;
select pg_temp.err(format($q$select fabula.save_ops(jsonb_build_array(jsonb_build_object('rpc', 'log_ccp', 'args', jsonb_build_object('p_cp_code', 'CCP-COLD-1', 'p_value', 60, 'p_staff_id', %L, 'p_source', 'tablet'))), null)$q$, :CAS)) e_imp \gset
reset role;
select pg_temp.ck('D-15 a guard''s own Italian message is kept (impossible value), not replaced by a generic one', :'e_imp' like 'Passo 1 di 1 (controllo HACCP): Valore impossibile: 60 %', :'e_imp');
select pg_temp.ck('D-15 the Italian guard messages of the triggers come through as they are (over-drawn milk)',
  pg_temp.err(format($q$select fabula.save_ops(jsonb_build_array(jsonb_build_object('table', 'batch_milk_inputs', 'row', jsonb_build_object('batch_id', '80000000-0000-4000-a000-0000000097b3', 'milk_intake_id', '70000000-0000-4000-a000-0000000097d4', 'qty_kg', 9999))), null)$q$)) like 'Passo 1 di 1 (latte messo in caldaia): Sul latte MF97-4 restano 500 kg%');

-- ============================== D-05 stock count ==============================
insert into fabula.stock_moves (product_id, lot_number, qty, move_type, batch_id, source) values (:'moz', 'LF97-A', 50, 'production_out', '80000000-0000-4000-a000-0000000097b1', 'tablet');
select pg_temp.as_user('00000000-0000-4000-a000-0000000097a2');
set role authenticated;
select fabula.start_stock_count(:CAS) sc \gset
reset role;
select (:'sc'::jsonb ->> 'count_id') cid, (select l ->> 'line_id' from jsonb_array_elements(:'sc'::jsonb -> 'lines') l where l ->> 'lot' = 'LF97-A') lid,
       (select l ->> 'line_id' from jsonb_array_elements(:'sc'::jsonb -> 'lines') l where l ->> 'lot' is null limit 1) lid_cons \gset
-- 30 kg sold after the sheet was opened; the count finds the 20 kg really there
insert into fabula.stock_moves (product_id, lot_number, qty, move_type, source, reason) values (:'moz', 'LF97-A', -30, 'adjustment', 'test', 'vendita dopo l''apertura del foglio');
select pg_temp.as_user('00000000-0000-4000-a000-0000000097a2');
set role authenticated;
select pg_temp.err(format($q$select fabula.post_stock_count(%L, jsonb_build_array(jsonb_build_object('line_id', %L, 'counted_qty', -1)))$q$, :'cid', :'lid')) e_neg \gset
select fabula.post_stock_count(:'cid', jsonb_build_array(jsonb_build_object('line_id', :'lid', 'counted_qty', 20)), :CAS) pc \gset
reset role;
select pg_temp.ck('D-05 a negative count is refused in Italian', :'e_neg' like 'Quantità contata negativa per %', :'e_neg');
select pg_temp.ck('D-05 20 kg counted after 30 kg were sold from the 50 on the sheet: no adjustment (it used to book −30)',
  (select coalesce(sum(qty), 0) = 20 from fabula.stock_moves where product_id = :'moz' and lot_number = 'LF97-A')
  and (select delta = 0 and system_qty_post = 20 and system_qty = 50 from fabula.stock_count_lines where id = :'lid'), :'pc');
select pg_temp.ck('D-05 lines nobody counted stay «not counted» (no fake «same as system»), and the result says how many',
  (select counted_qty is null and delta is null from fabula.stock_count_lines where id = :'lid_cons')
  and (:'pc'::jsonb ->> 'lines_counted')::int = 1 and (:'pc'::jsonb ->> 'lines_not_counted')::int = (:'pc'::jsonb ->> 'lines_total')::int - 1, :'pc');
-- «✓ Ci sono» on a line that moved since the sheet was opened: the system's quantity is right, nothing is adjusted
insert into fabula.stock_moves (product_id, lot_number, qty, move_type, batch_id, source) values (:'moz', 'LF97-C', 10, 'production_out', '80000000-0000-4000-a000-0000000097b3', 'tablet');
update fabula.stock_counts set status = 'abandoned' where status = 'open';
select pg_temp.as_user('00000000-0000-4000-a000-0000000097a2');
set role authenticated;
select fabula.start_stock_count(:CAS) sc4 \gset
reset role;
select (:'sc4'::jsonb ->> 'count_id') cid4, (select l ->> 'line_id' from jsonb_array_elements(:'sc4'::jsonb -> 'lines') l where l ->> 'lot' = 'LF97-C') lid4 \gset
insert into fabula.stock_moves (product_id, lot_number, qty, move_type, source, reason) values (:'moz', 'LF97-C', -2, 'adjustment', 'test', 'venduti durante la conta');
select pg_temp.as_user('00000000-0000-4000-a000-0000000097a2');
set role authenticated;
select fabula.post_stock_count(:'cid4', jsonb_build_array(jsonb_build_object('line_id', :'lid4', 'confirm', true)), :CAS) pc4 \gset
reset role;
select pg_temp.ck('D-05 «✓ Ci sono» while 2 kg were sold during the count: no adjustment (it used to put the 2 kg back)',
  (select coalesce(sum(qty), 0) = 8 from fabula.stock_moves where product_id = :'moz' and lot_number = 'LF97-C')
  and (select counted_qty = 8 and delta = 0 from fabula.stock_count_lines where id = :'lid4'), :'pc4');
select pg_temp.as_user('00000000-0000-4000-a000-0000000097a2');
set role authenticated;
select fabula.start_stock_count(:CAS) ->> 'count_id' cid2 \gset
reset role;
update fabula.stock_counts set counted_at = now() - interval '4 hours' where id = :'cid2';
select pg_temp.as_user('00000000-0000-4000-a000-0000000097a2');
set role authenticated;
select fabula.start_stock_count(:CAS) ->> 'count_id' cid3 \gset
select pg_temp.err(format($q$select fabula.post_stock_count(%L, '[]'::jsonb)$q$, :'cid2')) e_old \gset
reset role;
select pg_temp.ck('D-05 a sheet opened more than 3 hours ago is replaced by a fresh one; the old one can no longer be saved',
  :'cid3' <> :'cid2' and (select status = 'abandoned' from fabula.stock_counts where id = :'cid2') and :'e_old' like 'Questo foglio di conta non è più aperto%', :'e_old');

-- ============================== A-14 / D-08 60 hours ==============================
insert into fabula.milk_shipments (id, shipped_at, ship_date, kg, milk_lot, status, supplier_id) values ('60000000-0000-4000-a000-0000000097c1', now() - interval '62 hours', current_date - 3, 900, 'MF97-OLD', 'shipped', '50000000-0000-4000-a000-0000000097f1');
insert into fabula.milk_intake (id, intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source, shipment_id)
values ('70000000-0000-4000-a000-0000000097d9', pg_temp.today() - 2, '09:00', '50000000-0000-4000-a000-0000000097f1', 'MF97-OLD', 900, true, 4, 'tablet', '60000000-0000-4000-a000-0000000097c1');
select pg_temp.ck('A-14 milk_age_hours counts from the farm''s departure', fabula.milk_age_hours('70000000-0000-4000-a000-0000000097d9') between 61.9 and 62.1, fabula.milk_age_hours('70000000-0000-4000-a000-0000000097d9')::text);
insert into fabula.production_batches (id, batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, source)
values ('80000000-0000-4000-a000-0000000097b8', current_date, 'LF97-D', :'moz', 300, 'milk', now(), 'tablet'),
       ('80000000-0000-4000-a000-0000000097b9', current_date, 'LF97-E', :'ric', 300, 'milk', now(), 'tablet');
select pg_temp.err($q$insert into fabula.batch_milk_inputs (batch_id, milk_intake_id, qty_kg) values ('80000000-0000-4000-a000-0000000097b8', '70000000-0000-4000-a000-0000000097d9', 300)$q$) e_dop \gset
select pg_temp.ck('A-14 milk 62 hours old cannot go into a DOP batch, with the reason', :'e_dop' like 'Il latte MF97-OLD ha già 62 ore: oltre le 60 ore non si può fare Mozzarella di Bufala Campana DOP.%', :'e_dop');
select pg_temp.ck('A-14 …a product that is not DOP can still use it', pg_temp.err($q$insert into fabula.batch_milk_inputs (batch_id, milk_intake_id, qty_kg) values ('80000000-0000-4000-a000-0000000097b9', '70000000-0000-4000-a000-0000000097d9', 300)$q$) = '');
select pg_temp.ck('A-14 …and fresh milk goes into DOP as before', exists (select 1 from fabula.batch_milk_inputs where batch_id = '80000000-0000-4000-a000-0000000097b1'));
select pg_temp.ck('A-14 the start time of an offline batch is what counts (a vat started at 58 h, sent later, is fine)', pg_temp.err($q$
  insert into fabula.production_batches (id, batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, source)
  values ('80000000-0000-4000-a000-0000000097ba', current_date, 'LF97-F', (select id from fabula.products where sku = 'MOZ-DOP-KG'), 300, 'milk', now() - interval '4 hours', 'tablet');
  insert into fabula.batch_milk_inputs (batch_id, milk_intake_id, qty_kg) values ('80000000-0000-4000-a000-0000000097ba', '70000000-0000-4000-a000-0000000097d9', 200)$q$) = '');
select pg_temp.ck('A-14 the tablet may ask the age', has_function_privilege('authenticated', 'fabula.milk_age_hours(uuid, timestamptz)', 'execute'));

-- ============================== A-20 milk arrival from the paper sheet ==============================
select pg_temp.ck('A-20 a paper arrival 9 days old is refused', pg_temp.err($q$insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source) values ((now() at time zone 'Europe/Rome')::date - 9, '06:00', '50000000-0000-4000-a000-0000000097f1', 'MF97-P9', 100, true, 4, 'paper')$q$) like 'Data e ora del foglio non valide%');
select pg_temp.ck('A-20 …one in the future too', pg_temp.err($q$insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source) values ((now() at time zone 'Europe/Rome')::date + 1, '06:00', '50000000-0000-4000-a000-0000000097f1', 'MF97-PF', 100, true, 4, 'paper')$q$) like 'Data e ora del foglio non valide%');
select pg_temp.err($q$insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source) values ((now() at time zone 'Europe/Rome')::date - 2, '06:00', '50000000-0000-4000-a000-0000000097f1', 'MF97-P2', 100, true, 4, 'paper')$q$) e_p2 \gset
select pg_temp.ck('A-20 …one from 2 days ago keeps its date and time', :'e_p2' = '' and exists (select 1 from fabula.milk_intake where milk_lot = 'MF97-P2' and intake_time = '06:00'), :'e_p2');

-- ============================== grants ==============================
select pg_temp.ck('grants: save_ops, close_open_task, log_batch_step, skip_task for the app; follow-up and lot triggers not callable',
  has_function_privilege('authenticated', 'fabula.save_ops(jsonb, uuid, timestamptz, timestamptz)', 'execute')
  and has_function_privilege('authenticated', 'fabula.close_open_task(date, text, uuid, uuid, uuid, uuid, timestamptz)', 'execute')
  and has_function_privilege('authenticated', 'fabula.log_batch_step(text, uuid, numeric, uuid, text, timestamptz)', 'execute')
  and has_function_privilege('authenticated', 'fabula.skip_task(uuid, text, uuid)', 'execute')
  and not has_function_privilege('anon', 'fabula.save_ops(jsonb, uuid, timestamptz, timestamptz)', 'execute')
  and not has_function_privilege('anon', 'fabula.skip_task(uuid, text, uuid)', 'execute')
  and not has_function_privilege('authenticated', 'fabula.followup_tick()', 'execute')
  and not has_function_privilege('authenticated', 'fabula.trg_batch_lot_free()', 'execute'));
select pg_temp.ck('the old save_ops(jsonb, uuid) is gone (one function: a 2-argument call still works through the default)',
  (select count(*) = 1 from pg_proc where proname = 'save_ops' and pronamespace = 'fabula'::regnamespace));
select pg_temp.ck('skip_task is accepted in the evening security check', exists (select 1 from fabula.security_accepted where key like '%fabula.skip_task(%'));
