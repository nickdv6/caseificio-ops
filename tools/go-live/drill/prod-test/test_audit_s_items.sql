-- v0.95 audit backlog, items under an hour with severity High/Critical (A-12, B-02, B-03, B-04, B-05, C-04, C-28, D-03, D-09, D-12,
-- E-20, FARM-01, PRINT-03) · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh s_test
--   su postgres -c "psql -d s_test -f tools/go-live/drill/prod-test/test_audit_s_items.sql" | grep -E "PASS|FAIL"
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as
$$ begin execute p_sql; return ''; exception when others then return sqlerrm; end $$;
create or replace function pg_temp.as_user(p_sub text) returns void language sql as
$$ select set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_sub), false) $$;
select id moz from fabula.products where sku = 'MOZ-DOP-KG' \gset
select (now() at time zone 'Europe/Rome')::date today \gset
insert into fabula.staff (id, full_name, role, app_role, active, auth_user_id) values
  ('10000000-0000-4000-a000-0000000095a1', 'Titolare S', 'owner', 'titolare', true, '00000000-0000-4000-a000-0000000095a1'),
  ('10000000-0000-4000-a000-0000000095a2', 'Casaro S', 'casaro', 'produzione', true, '00000000-0000-4000-a000-0000000095a2'),
  ('10000000-0000-4000-a000-0000000095a3', 'Banco S', 'commesso', 'banco', true, '00000000-0000-4000-a000-0000000095a3')
on conflict do nothing;
insert into fabula.parties (id, type, legal_name, is_milk_supplier, active) values ('50000000-0000-4000-a000-0000000095f1', 'supplier', 'Masseria S', true, true) on conflict do nothing;
insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, output_kg, finished_at, source) values
  (current_date, 'L95-A', :'moz', 500, 'milk', now(), 150, now(), 'tablet'), (current_date, 'L95-B', :'moz', 500, 'milk', now(), 150, now(), 'tablet'),
  (current_date, 'L95-C', :'moz', 500, 'milk', now(), 150, now(), 'tablet'), (current_date, 'L95-D', :'moz', 500, 'milk', now(), null, null, 'tablet'),
  (current_date, 'L95-E', :'moz', 500, 'milk', now(), null, null, 'tablet');
insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source)
values (current_date, '07:00', '50000000-0000-4000-a000-0000000095f1', 'M95-1', 1000, true, 4, 'tablet');

-- v1.05 (audit E-32): the daily tasks start from prod.tasks_from (the replay's opening date is in 2027) and Sunday is closed: the test
-- generates tasks for today and the days before, whatever the weekday
update fabula.settings set value = '2026-01-01' where key = 'prod.tasks_from';
update fabula.settings set value = '' where key = 'prod.closed_weekdays';

-- A-12 · a queued check closes its task in the name of who did it, even when another login sends it
select fabula.generate_daily_tasks(:'today') g \gset
select pg_temp.as_user('00000000-0000-4000-a000-0000000095a1');
set role authenticated;
select fabula.close_open_task(:'today', 'T-KWH', null, null, '10000000-0000-4000-a000-0000000095a2', null) t1 \gset
reset role;
select pg_temp.ck('A-12 close_open_task signs with the staff id sent with the record, not the session user',
  (select completed_by_id = '10000000-0000-4000-a000-0000000095a2' from fabula.task_instances where id = nullif(:'t1', '')::uuid), :'t1');

-- B-05 · a sample's lot is upper-cased and must exist
select pg_temp.as_user('00000000-0000-4000-a000-0000000095a1');
set role authenticated;
select fabula.record_sample_taken('MOZ-LM', ' l95-a ') s1 \gset
select pg_temp.err($q$select fabula.record_sample_taken('MOZ-LM', 'L2026012-A')$q$) e_lot \gset
select pg_temp.err($q$select fabula.record_sample_taken('MOZ-ENT', 'm95-1')$q$) e_milklot \gset
select pg_temp.err($q$select fabula.record_sample_taken('MOZ-ENT', '')$q$) e_nolot \gset
reset role;
insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source)
values (current_date, '07:10', '50000000-0000-4000-a000-0000000095f1', 'CS 95/2', 10, true, 4, 'tablet');
select pg_temp.as_user('00000000-0000-4000-a000-0000000095a1');
set role authenticated;
select pg_temp.err($q$select fabula.record_sample_taken('LAT-CBT', 'cs 95/2')$q$) e_space \gset
reset role;
select pg_temp.ck('B-05 a lot typed in lower case with spaces is stored upper-case and linked to its batch',
  (select lot_number = 'L95-A' and batch_id is not null from fabula.lab_samples where sample_code = :'s1'::jsonb->>'sample_code'), :'s1');
select pg_temp.ck('B-05 an unknown lot is refused with a sentence', :'e_lot' like 'Lotto L2026012-A non trovato%', :'e_lot');
select pg_temp.ck('B-05 a milk lot and an empty lot are accepted', :'e_milklot' = '' and :'e_nolot' = '', :'e_milklot' || :'e_nolot');
select pg_temp.ck('B-05 a supplier milk lot with a space in it is found', :'e_space' = '', :'e_space');

-- B-02 · a lab outcome can be corrected with a reason; the first outcome is kept
select :'s1'::jsonb->>'sample_code' sc \gset
select pg_temp.as_user('00000000-0000-4000-a000-0000000095a1');
set role authenticated;
select fabula.record_lab_result(:'sc', 'conforme', null, 'assente in 25 g', 'R-1') r0 \gset
select pg_temp.err(format($q$select fabula.correct_lab_result(%L, 'non_conforme', '')$q$, :'sc')) e_noreason \gset
select pg_temp.err(format($q$select fabula.correct_lab_result(%L, 'conforme', 'stesso')$q$, :'sc')) e_same \gset
select fabula.correct_lab_result(:'sc', 'non_conforme', 'esito letto male dal referto', 'presente in 25 g') rc \gset
reset role;
select pg_temp.ck('B-02 a correction needs a reason', :'e_noreason' like 'Scrivi il motivo%', :'e_noreason');
select pg_temp.ck('B-02 correcting to the same outcome is refused', :'e_same' like 'L''esito è già%', :'e_same');
select pg_temp.ck('B-02 conforme → NON conforme: NC opened and the lot held (same rules as a first result)',
  (:'rc'::jsonb->>'nc_id') is not null and (select food_safety_hold from fabula.production_batches where batch_lot = 'L95-A'), :'rc');
select pg_temp.ck('B-02 the first outcome and the reason stay on the sample',
  (select outcome = 'non_conforme' and notes like '%esito corretto da Titolare S: conforme → NON conforme (prima: assente in 25 g, referto R-1). Motivo: esito letto male dal referto%' from fabula.lab_samples where sample_code = :'sc'));
select pg_temp.ck('B-02 the change is in the audit log', exists (select 1 from fabula.audit_log where table_name = 'lab_samples' and row_key = (select id::text from fabula.lab_samples where sample_code = :'sc')));

-- B-03 · external calibration: certificate + deviation or PDF; no deviation = "da verificare", no return to service
select pg_temp.as_user('00000000-0000-4000-a000-0000000095a1');
set role authenticated;
select fabula.record_calibration_check('TERM-01', 'verifica_interna', 'ghiaccio_fondente', '[{"ref":0,"reading":2}]') k0 \gset
select pg_temp.err($q$select fabula.record_calibration_check('TERM-01', 'taratura_esterna', 'certificato_lab', '[]', null, 'Rossi')$q$) e_cert \gset
select pg_temp.err($q$select fabula.record_calibration_check('TERM-01', 'taratura_esterna', 'certificato_lab', '[]', null, 'Rossi', 'C-77')$q$) e_dev \gset
select pg_temp.err(format($q$select fabula.record_calibration_check('TERM-01', 'taratura_esterna', 'certificato_lab', '[{"ref":0,"reading":0.1}]', null, 'Rossi', 'C-77', null, null, false, %L::date + 3)$q$, :'today')) e_future \gset
reset role;
insert into fabula.documents (id, kind, storage_path) values ('d0000000-0000-4000-a000-0000000095d1', 'calibration_cert', 'tarature/test.pdf');
select pg_temp.as_user('00000000-0000-4000-a000-0000000095a1');
set role authenticated;
select fabula.record_calibration_check('TERM-01', 'taratura_esterna', 'certificato_lab', '[]', null, 'Rossi', 'C-77', 'd0000000-0000-4000-a000-0000000095d1') k1 \gset
reset role;
select out_of_service oos1, coalesce(last_calibrated_on::text, 'null') lc1, coalesce(calibration_cert_ref, '') cr1 from fabula.equipment where code = 'TERM-01' \gset
select pg_temp.as_user('00000000-0000-4000-a000-0000000095a1');
set role authenticated;
select fabula.record_calibration_check('TERM-01', 'taratura_esterna', 'certificato_lab', '[{"ref":0,"reading":0.2}]', null, 'Rossi', 'C-78') k2 \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('B-03 setup: the failed internal check put TERM-01 out of service', :'k0'::jsonb->>'result' = 'ko', :'k0');
select pg_temp.ck('B-03 an external calibration without certificate number is refused', :'e_cert' like 'Scrivi il numero del certificato%', :'e_cert');
select pg_temp.ck('B-03 …and without deviation or PDF', :'e_dev' like 'Scrivi lo scarto massimo%', :'e_dev');
select pg_temp.ck('B-03 a calibration dated in the future is refused', :'e_future' like '%nel futuro%', :'e_future');
select pg_temp.ck('B-03 certificate + PDF but no deviation: "da verificare" and the instrument stays out of service',
  :'k1'::jsonb->>'result' = 'da_verificare' and :'oos1'::boolean and (:'k1'::jsonb->>'out_of_service')::boolean, :'k1');
select pg_temp.ck('B-03 …and its due date does not move until the deviation is written (the certificate number is kept)', :'lc1' <> :'today' and :'cr1' = 'C-77', :'lc1' || ' ' || :'cr1');
select pg_temp.ck('B-03 with a deviation inside tolerance it is back in service', :'k2'::jsonb->>'result' = 'ok' and not (select out_of_service from fabula.equipment where code = 'TERM-01'), :'k2');
select pg_temp.ck('B-03 the calibration register prints "da verificare", not "FUORI TOLLERANZA"',
  exists (select 1 from jsonb_array_elements(fabula.haccp_register('MOD-09', :'today'::date - 1, :'today'::date)->'rows') r where r->>'esito' like 'da verificare%' and (r->>'_warn')::boolean));

-- B-04 · a register review covers past days only and is signed by the logged-in user
select pg_temp.as_user('00000000-0000-4000-a000-0000000095a1');
set role authenticated;
select fabula.mark_register_reviewed('MOD-05', :'today'::date - 3, :'today'::date + 30, '10000000-0000-4000-a000-0000000095a3') rv \gset
select pg_temp.err(format($q$select fabula.mark_register_reviewed('MOD-05', %L::date + 2, %L::date + 30)$q$, :'today', :'today')) e_rv \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('B-04 a period ending in the future is cut at today',
  (select period_to = :'today'::date from fabula.haccp_register_reviews where id = :'rv'::uuid));
select pg_temp.ck('B-04 a period starting in the future is refused', :'e_rv' like 'Periodo non valido%', :'e_rv');
select pg_temp.ck('B-04 the review is signed by whoever is logged in, not the id sent',
  (select reviewed_by_id = '10000000-0000-4000-a000-0000000095a1' from fabula.haccp_register_reviews where id = :'rv'::uuid));

-- D-03 · a hold is lifted only through release_lot_hold
select pg_temp.as_user('00000000-0000-4000-a000-0000000095a2');
set role authenticated;
select pg_temp.err($q$update fabula.production_batches set food_safety_hold = false where batch_lot = 'L95-A'$q$) e_rel \gset
select pg_temp.err($q$update fabula.production_batches set food_safety_hold = true, hold_reason = 'controllo visivo', hold_at = now() where batch_lot = 'L95-B'$q$) e_set \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.err($q$update fabula.production_batches set hold_released_at = now(), food_safety_hold = false where batch_lot = 'L95-A'$q$) e_rel_sql \gset
select pg_temp.err($q$do $d$ begin perform fabula.release_lot_hold('L95-B', null, 'controllo ok'); update fabula.production_batches set food_safety_hold = false where batch_lot = 'L95-A'; end $d$$q$) e_twice \gset
select pg_temp.ck('D-03 a plain UPDATE that lifts a hold is refused (Produzione login)', :'e_rel' like 'Lotto L95-A bloccato per sicurezza alimentare%', :'e_rel');
select pg_temp.ck('D-03 …and from SQL too', :'e_rel_sql' like 'Lotto L95-A bloccato%', :'e_rel_sql');
select pg_temp.ck('D-03 putting a lot on hold directly is still allowed', :'e_set' = '' and (select food_safety_hold from fabula.production_batches where batch_lot = 'L95-B'), :'e_set');
select pg_temp.ck('D-03 the release permission is used once: a second plain update in the same transaction is refused', :'e_twice' like 'Lotto L95-A bloccato%'
  and (select food_safety_hold from fabula.production_batches where batch_lot = 'L95-B'), :'e_twice');
select pg_temp.err($q$do $d$ begin perform fabula.hold_lot('L95-B', 'controllo visivo'); perform fabula.hold_lot('L95-B', 'controllo visivo'); update fabula.production_batches set food_safety_hold = false where batch_lot = 'L95-A'; end $d$$q$) e_leak \gset
select pg_temp.ck('D-03 a hold call that changes nothing does not leave the permission open', :'e_leak' like 'Lotto L95-A bloccato%', :'e_leak');
select pg_temp.as_user('00000000-0000-4000-a000-0000000095a1');
set role authenticated;
select pg_temp.err($q$select fabula.release_lot_hold('L95-A', null, 'esito rianalisi conforme')$q$) e_recall \gset
-- v0.99 (audit B-06): the recall assessment opened by the positive analysis is decided first
reset role;
update fabula.approvals set status = 'rejected', decided_by = 'test', decision_note = 'rianalisi conforme: ritiro non necessario'
 where status = 'pending' and payload->>'type' = 'recall_assessment' and payload->>'lot' = 'L95-A';
set role authenticated;
select pg_temp.err($q$select fabula.release_lot_hold('L95-A', null, 'esito rianalisi conforme')$q$) e_ok \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('B-06 (v0.99) not released while its recall assessment is undecided', :'e_recall' like 'Prima decidi la valutazione di ritiro/richiamo del lotto L95-A%', :'e_recall');
select pg_temp.ck('D-03 release_lot_hold (HACCP manager) still works', :'e_ok' = '' and not (select food_safety_hold from fabula.production_batches where batch_lot = 'L95-A'), :'e_ok');
select pg_temp.ck('D-03 hold changes are in the audit log',
  (select count(*) >= 2 from fabula.audit_log where table_name = 'production_batches' and 'food_safety_hold' = any (changed)));

-- D-09 · a delivery cannot go into the vats for more than it weighed (+2 %)
select id mi from fabula.milk_intake where milk_lot = 'M95-1' \gset
select pg_temp.err(format($q$insert into fabula.batch_milk_inputs (batch_id, milk_intake_id, qty_kg) values ((select id from fabula.production_batches where batch_lot = 'L95-D'), %L, 600)$q$, :'mi')) e_m1 \gset
select pg_temp.err(format($q$insert into fabula.batch_milk_inputs (batch_id, milk_intake_id, qty_kg) values ((select id from fabula.production_batches where batch_lot = 'L95-E'), %L, 500)$q$, :'mi')) e_m2 \gset
select pg_temp.err(format($q$insert into fabula.batch_milk_inputs (batch_id, milk_intake_id, qty_kg) values ((select id from fabula.production_batches where batch_lot = 'L95-E'), %L, 420)$q$, :'mi')) e_m3 \gset
select pg_temp.ck('D-09 the first vat takes 600 of 1.000 kg', :'e_m1' = '', :'e_m1');
select pg_temp.ck('D-09 a second vat of 500 kg is refused and says what is left',
  :'e_m2' = 'Sul latte M95-1 restano 400 kg (ricevuti 1.000, già in caldaia 600): hai scritto 500 kg. Controlla il lotto sull''etichetta e i kg', :'e_m2');
select pg_temp.ck('D-09 up to +2 % for the scale is accepted (600 + 420 = 1.020)', :'e_m3' = '', :'e_m3');

-- D-12 · impossible readings are refused, a CCP is never empty, curd pH is a pH
select count(*) n0 from fabula.haccp_log \gset
select pg_temp.as_user('00000000-0000-4000-a000-0000000095a2');
set role authenticated;
select pg_temp.err($q$select fabula.log_ccp(p_cp_code => 'CCP-STRETCH', p_value => 520, p_staff_id => '10000000-0000-4000-a000-0000000095a2', p_batch_lot => 'L95-C')$q$) e_520 \gset
select pg_temp.err($q$select fabula.log_ccp(p_cp_code => 'CCP-STRETCH', p_value => null, p_staff_id => '10000000-0000-4000-a000-0000000095a2', p_batch_lot => 'L95-C')$q$) e_null \gset
select pg_temp.err($q$select fabula.log_ccp(p_cp_code => 'CCP-MILK-ABX', p_value => 5, p_staff_id => '10000000-0000-4000-a000-0000000095a2')$q$) e_abx \gset
select pg_temp.err($q$select fabula.log_ccp(p_cp_code => 'CCP-COLD-1', p_value => 3.5, p_staff_id => '10000000-0000-4000-a000-0000000095a2')$q$) e_cold \gset
select pg_temp.err($q$select fabula.log_ccp(p_cp_code => 'CCP-COLD-2', p_value => 27, p_staff_id => '10000000-0000-4000-a000-0000000095a2')$q$) e_hot \gset
select pg_temp.err($q$update fabula.production_batches set curd_ph = 52 where batch_lot = 'L95-E'$q$) e_ph \gset
select pg_temp.err($q$update fabula.production_batches set curd_ph = 5.2 where batch_lot = 'L95-E'$q$) e_ph2 \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('D-12 stretching 520 °C is refused with a sentence', :'e_520' = 'Valore impossibile: 520 °C per «Filatura: temperatura della pasta» (possibili 10–99). Controlla la virgola e riscrivi.', :'e_520');
select pg_temp.ck('D-12 a real cold-room failure (27 °C) is recorded, not refused', :'e_hot' = '', :'e_hot');
select pg_temp.ck('D-12 …nothing saved, no NC, lot not held', (select count(*) from fabula.haccp_log) = :n0 + 2
  and not (select food_safety_hold from fabula.production_batches where batch_lot = 'L95-C'), 'two rows = the cold-room readings');
select pg_temp.ck('D-12 an empty CCP is refused', :'e_null' like '%è un punto critico, scrivi il valore misurato%', :'e_null');
select pg_temp.ck('D-12 an antibiotic test is 0 or 1', :'e_abx' like 'Valore impossibile: 5 per%', :'e_abx');
select pg_temp.ck('D-12 a normal reading goes through', :'e_cold' = '', :'e_cold');
select pg_temp.ck('D-12 curd pH 52 is refused, 5,2 accepted', :'e_ph' like 'pH della cagliata impossibile: 52%' and :'e_ph2' = '', :'e_ph' || ' / ' || :'e_ph2');
select pg_temp.err($q$insert into fabula.haccp_log (control_point_id, logged_at, measured_value, result, operator, source) select id, now(), 31, 'non_conformity', 'sensor', 'sensor' from fabula.haccp_control_points where code = 'CCP-COLD-1'$q$) e_sensor \gset
select pg_temp.ck('D-12 sensor roll-ups are not blocked (a sensor glitch must not stop the others)', :'e_sensor' = '', :'e_sensor');
insert into fabula.haccp_log (control_point_id, logged_at, measured_value, result, operator, source, batch_id)
select cp.id, now(), null, 'warning', 'sim', 'simulation', (select id from fabula.production_batches where batch_lot = 'L95-D') from fabula.haccp_control_points cp where cp.code in ('CCP-PAST', 'CCP-STRETCH');
update fabula.production_batches set output_kg = 150, finished_at = now() where batch_lot = 'L95-D';
select pg_temp.ck('D-12 a CCP row without a value does not count as recorded at batch close',
  exists (select 1 from fabula.bot_messages where title like 'Lotto L95-D chiuso senza pastorizzazione (CCP 2) e temperatura di filatura (CCP 3)%'));

-- FARM-01 · a weight far from the order is confirmed by the farm first
update fabula.settings set value = '0123456789abcdef0123456789abcdef' where key = 'milk.farm_token';
insert into fabula.settings (key, value, description, data_type) select 'milk.farm_token', '0123456789abcdef0123456789abcdef', 'test', 'text'
 where not exists (select 1 from fabula.settings where key = 'milk.farm_token');
\set tok '0123456789abcdef0123456789abcdef'
update fabula.milk_shipments set status = 'cancelled' where ship_date = :'today' and status <> 'cancelled';
insert into fabula.milk_plans (plan_date, milk_kg, status) values (:'today', 1050, 'approved');
select count(*) ns0 from fabula.milk_shipments \gset
select fabula.farm_milk_ship(:'tok', 105, null, null, null, false) f1 \gset
select pg_temp.ck('FARM-01 105 kg against an order of 1.050 kg asks for confirmation and records nothing',
  (:'f1'::jsonb->>'needs_confirm')::boolean and :'f1'::jsonb->>'message_it' = 'Hai scritto 105 kg ma l''ordine di oggi è 1.050 kg. È giusto?'
  and (select count(*) from fabula.milk_shipments) = :ns0, :'f1');
select fabula.farm_milk_ship(:'tok', 105, null, null, null, true) f2 \gset
select pg_temp.ck('FARM-01 confirmed, it is recorded', (:'f2'::jsonb->>'milk_lot') is not null and (:'f2'::jsonb->>'kg')::numeric = 105, :'f2');
select fabula.farm_milk_ship(:'tok', 940, null, null, null, false) f3 \gset
select pg_temp.ck('FARM-01 a weight close to what is still missing of the order goes straight through', (:'f3'::jsonb->>'milk_lot') is not null, :'f3');
select pg_temp.err($q$select fabula.farm_milk_ship('0123456789abcdef0123456789abcdef', 30)$q$) e_small \gset
select pg_temp.ck('FARM-01 under 50 kg is refused', :'e_small' like 'Peso troppo basso: 30%', :'e_small');
select fabula.farm_milk_ship(:'tok', 107) f4 \gset
update fabula.milk_plans set status = 'superseded' where plan_date = :'today';
update fabula.milk_shipments set status = 'cancelled' where ship_date = :'today';
insert into fabula.milk_shipments (shipped_at, ship_date, kg, milk_lot, status) values
  (now() - interval '3 days', current_date - 3, 1100, 'M95U-1', 'received'), (now() - interval '2 days', current_date - 2, 1100, 'M95U-2', 'received'), (now() - interval '1 day', current_date - 1, 1100, 'M95U-3', 'received');
select count(*) ns1 from fabula.milk_shipments \gset
select fabula.farm_milk_ship(:'tok', 105, null, null, null, false) f5 \gset
select pg_temp.ck('FARM-01 with no order today, 105 kg against usual loads of 1.100 kg asks for confirmation',
  (:'f5'::jsonb->>'needs_confirm')::boolean and :'f5'::jsonb->>'message_it' = 'Hai scritto 105 kg: di solito una spedizione è di circa 1.100 kg. È giusto?'
  and (select count(*) from fabula.milk_shipments) = :ns1, :'f5');
select pg_temp.ck('FARM-01 an older farm-order function (no p_confirm) keeps working', (:'f4'::jsonb->>'milk_lot') is not null, :'f4');
select pg_temp.ck('FARM-01 farm_milk_ship stays out of reach of app users',
  -- v1.03b: one version only (with p_by), never callable by app users
  not exists (select 1 from pg_proc where proname = 'farm_milk_ship' and pronamespace = 'fabula'::regnamespace
               and (has_function_privilege('authenticated', oid, 'execute') or has_function_privilege('anon', oid, 'execute')))
  and (select count(*) from pg_proc where proname = 'farm_milk_ship' and pronamespace = 'fabula'::regnamespace) = 1
  and to_regprocedure('fabula.farm_milk_ship(text,numeric,numeric,text,text)') is null);

-- C-28 · kg per Shopify piece
insert into fabula.shopify_variant_map (variant_id, label) values ('gid://shopify/ProductVariant/95', 'Bocconcini 250 g');
select pg_temp.err($q$update fabula.shopify_variant_map set product_id = (select id from fabula.products where sku = 'MOZ-DOP-KG'), kg_per_unit = 250 where variant_id = 'gid://shopify/ProductVariant/95'$q$) e_g \gset
select pg_temp.err($q$update fabula.shopify_variant_map set product_id = (select id from fabula.products where sku = 'MOZ-DOP-KG'), kg_per_unit = 0.25 where variant_id = 'gid://shopify/ProductVariant/95'$q$) e_kg \gset
select pg_temp.ck('C-28 250 kg per piece is refused, 0,25 accepted', :'e_g' like '%shopify_variant_map_kg_per_unit_check%' and :'e_kg' = '', :'e_g' || ' / ' || :'e_kg');
select pg_temp.err($q$select fabula.upsert_shopify_orders('[{"id":"gid://shopify/Order/9501","name":"#9501","source_name":"web","financial_status":"PAID","created_at":"2026-10-12T10:00:00Z","updated_at":"2026-10-12T10:00:00Z","subtotal":"300","tax":"12","total":"312","line_items":[{"variant_id":"gid://shopify/ProductVariant/9502","title":"Mozzarella di bufala catering","variant_title":"30 kg","product_type":"Mozzarella","quantity":1,"price":"300","tax_rate":4}]}]'::jsonb)$q$) e_auto \gset
select pg_temp.ck('C-28 a "30 kg" title is left for a person to map instead of failing the import',
  :'e_auto' = '' and (select product_id is null from fabula.shopify_variant_map where variant_id = 'gid://shopify/ProductVariant/9502'), :'e_auto');

-- C-04 · B2B cut-off and delivery days written the Italian way
update fabula.settings set value = '18.00' where key = 'trade.cutoff_time';
select value c1 from fabula.settings where key = 'trade.cutoff_time' \gset
update fabula.settings set value = 'ore 7' where key = 'trade.cutoff_time';
select value c2 from fabula.settings where key = 'trade.cutoff_time' \gset
select pg_temp.err($q$update fabula.settings set value = 'boh' where key = 'trade.cutoff_time'$q$) e_c \gset
update fabula.settings set value = 'lun, mar,mer' where key = 'trade.delivery_days';
select value d1 from fabula.settings where key = 'trade.delivery_days' \gset
update fabula.settings set value = '1 - 6' where key = 'trade.delivery_days';
select value d2 from fabula.settings where key = 'trade.delivery_days' \gset
update fabula.settings set value = 'lun-sab' where key = 'trade.delivery_days';
select value d3 from fabula.settings where key = 'trade.delivery_days' \gset
select pg_temp.err($q$update fabula.settings set value = 'tutti' where key = 'trade.delivery_days'$q$) e_d \gset
select pg_temp.ck('C-04 "18.00" and "ore 7" become 18:00 and 07:00', :'c1' = '18:00' and :'c2' = '07:00', :'c1' || ' ' || :'c2');
select pg_temp.ck('C-04 an unreadable time is refused with a sentence', :'e_c' like 'Orario limite non valido%', :'e_c');
select pg_temp.ck('C-04 "lun, mar,mer" and "1 - 6" become day numbers', :'d1' = '1,2,3' and :'d2' = '1,2,3,4,5,6', :'d1' || ' / ' || :'d2');
select pg_temp.ck('C-04 an unknown day is refused', :'e_d' like 'Giorno di consegna non riconosciuto%', :'e_d');
select pg_temp.ck('C-04 "lun-sab" becomes Monday to Saturday', :'d3' = '1,2,3,4,5,6', :'d3');
alter table fabula.settings disable trigger settings_format;
update fabula.settings set value = '18.00' where key = 'trade.cutoff_time';
alter table fabula.settings enable trigger settings_format;
select pg_temp.ck('C-04 an unreadable stored cut-off falls back to 18:00 instead of an error', fabula.trade_cutoff_at('2026-11-10') = '2026-11-09 18:00');
update fabula.settings set value = '18:00' where key = 'trade.cutoff_time';
select pg_temp.ck('C-04 Configurazione gets a time field and weekday boxes',
  (select kind from fabula.settings where key = 'trade.cutoff_time') = 'time' and (select kind from fabula.settings where key = 'trade.delivery_days') = 'weekdays');

-- E-20 · the outside watcher sees bots that stopped
update fabula.bot_schedule set active = false;
select (extract(hour from (now() at time zone 'Europe/Rome')) * 60 + extract(minute from (now() at time zone 'Europe/Rome'))) >= 100 room \gset
insert into fabula.bot_schedule (agent, name_it, due_times, weekdays, grace_min)
values ('test_bot', 'Bot di prova', array[((now() at time zone 'Europe/Rome') - interval '90 minutes')::time], '{1,2,3,4,5,6,7}', 45);
select public.fabula_health() h1 \gset
insert into fabula.agent_runs (agent, started_at, finished_at, status, details) values ('test_bot', now() - interval '80 minutes', now(), 'ok', '{"via":"db_fallback"}');
select public.fabula_health() h2 \gset
insert into fabula.agent_runs (agent, started_at, finished_at, status) values ('test_bot', now() - interval '85 minutes', now(), 'ok');
select public.fabula_health() h3 \gset
select pg_temp.ck('E-20 a bot slot with no run fails the health check (count only)',
  not :'room'::boolean or (not (:'h1'::jsonb->>'bots_ok')::boolean and (:'h1'::jsonb->>'bots_missed')::int = 1), :'h1');
select pg_temp.ck('E-20 the database stand-in does not count as the bot', not :'room'::boolean or not (:'h2'::jsonb->>'bots_ok')::boolean, :'h2');
select pg_temp.ck('E-20 the bot''s own run clears it', (:'h3'::jsonb->>'bots_ok')::boolean, :'h3');
update fabula.bot_schedule set active = true where agent <> 'test_bot';
delete from fabula.bot_schedule where agent = 'test_bot';

-- PRINT-03 · go-live board checks the company data printed on DDTs
update fabula.settings set value = '' where key = 'company.piva';
update fabula.settings set value = 'Agropoli (SA)' where key = 'company.address';
select fabula.company_docs_check() p1 \gset
update fabula.settings set value = 'Soc. Agricola Prova S.S.' where key = 'company.legal_name';
update fabula.settings set value = '05541290655' where key = 'company.piva';
update fabula.settings set value = 'Via Salvo D''Acquisto 17, 84043 Agropoli (SA)' where key = 'company.address';
select fabula.company_docs_check() p2 \gset
select pg_temp.ck('PRINT-03 missing P.IVA and street are reported', not (:'p1'::jsonb->>'done')::boolean and :'p1'::jsonb->>'detail' like '%P.IVA, indirizzo (via e numero)%', :'p1');
select pg_temp.ck('PRINT-03 complete data passes', (:'p2'::jsonb->>'done')::boolean, :'p2');
select pg_temp.ck('PRINT-03 street addresses are recognised (via, lungomare, SS18, house number), a town or CAP alone is not',
  fabula.is_street_address('Via Salvo D''Acquisto 17, 84043 Agropoli (SA)') and fabula.is_street_address('Lungomare San Marco 12') and fabula.is_street_address('SS18 km 90')
  and fabula.is_street_address('Contrada Foce Sele snc') and not fabula.is_street_address('Agropoli (SA)') and not fabula.is_street_address('84043 Agropoli (SA)'));
select pg_temp.ck('PRINT-03 the check is on the go-live board', exists (select 1 from fabula.dash_checks where key = 'company_docs' and kind = 'auto')
  and fabula.ops_dashboard()::text like '%Legal name, P.IVA and street address set%');
