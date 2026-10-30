-- v1.21 · CCP 2 a tino: the holding minutes (≥ 30 min at ≥ 63 °C) recorded on every vat · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh h_test
--   su postgres -c "psql -d h_test -f tools/go-live/drill/prod-test/test_v121_past_hold.sql" | grep -E "PASS|FAIL"
-- Sections: 1 structure (control points, preset steps, grants) · 2 the minutes through log_ccp (limit, lot hold, possible values) ·
-- 3 the minutes through the preset step (trg_step_log_ccp) · 4 the close (trg_batch_ccp_check: held without them, order of the
-- missing list, ricotta not concerned, the control point switched off) · 5 «Prima di chiudere» · 6 the MOD-02 register.
-- Lots are started and closed as the database owner with source «tablet» (the close check skips «simulation»/«test»); every refusal is
-- caught by pg_temp.err, so the suite prints PASS/FAIL lines only.
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as
$$ begin execute p_sql; return ''; exception when others then return sqlerrm; end $$;
create or replace function pg_temp.today() returns date language sql as $$ select (now() at time zone 'Europe/Rome')::date $$;
create or replace function pg_temp.lot(p_lot text, p_product uuid, p_kind text default 'milk', p_preset uuid default null) returns text language sql as $$
  insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, source, preset_id)
  values (pg_temp.today(), p_lot, p_product, 200, p_kind, now(), 'tablet', p_preset) returning batch_lot $$;
create or replace function pg_temp.close(p_lot text) returns void language sql as $$
  update fabula.production_batches set output_kg = 40, finished_at = now() where batch_lot = p_lot $$;
create or replace function pg_temp.log(p_code text, p_value numeric, p_lot text) returns jsonb language sql as $$
  select fabula.log_ccp(p_cp_code => p_code, p_value => p_value, p_batch_lot => p_lot, p_staff_id => '10000000-0000-4000-a000-000000121a01') $$;
create or replace function pg_temp.held(p_lot text) returns boolean language sql as $$
  select food_safety_hold from fabula.production_batches where batch_lot = p_lot $$;
create or replace function pg_temp.reason(p_lot text) returns text language sql as $$
  select coalesce(hold_reason, '') from fabula.production_batches where batch_lot = p_lot $$;

insert into fabula.staff (id, full_name, role, app_role, active) values ('10000000-0000-4000-a000-000000121a01', 'Casaro V121', 'casaro', 'produzione', true) on conflict do nothing;
update fabula.settings set value = 'pastorizzato' where key = 'food.milk_process';
select id moz from fabula.products where sku = 'MOZ-DOP-KG' \gset
select id ric from fabula.products where sku = 'RIC-BUF-KG' \gset
select s.id step_past, s.preset_id preset, s.step_order past_order from fabula.process_steps s where s.ccp_code = 'CCP-PAST' and s.active order by s.step_order limit 1 \gset
select id step_hold from fabula.process_steps where ccp_code = 'CCP-PAST-HOLD' and preset_id = :'preset' \gset

-- ============================== 1. structure ==============================
select pg_temp.ck('1a CCP-PAST carries the batch limits: critical ≥ 63 °C, alert below 64, texts for a batch vat',
  (select min_value = 63 and warn_min = 64 and max_value is null and is_ccp and critical_limit_it like 'Pastorizzazione a tino (discontinua): ≥ 63 °C per ≥ 30 min%'
          and corrective_it like 'Sotto 63 °C o sosta più corta di 30 min%' from fabula.haccp_control_points where code = 'CCP-PAST'));
select pg_temp.ck('1b CCP-PAST-HOLD: CCP 2, minutes, critical limit ≥ 30, no maximum, per batch, MOD-02, critical, active, possible 0–240',
  (select name = 'Pastorizzazione: minuti di sosta a ≥ 63 °C' and ccp_no = 'CCP 2' and is_ccp and active and unit = 'min' and min_value = 30 and max_value is null
          and warn_min is null and frequency = 'per_batch' and form_code = 'MOD-02' and nc_severity = 'critical' and applies_when = 'latte_pastorizzato'
          and plausible_min = 0 and plausible_max = 240 and sort = 30
     from fabula.haccp_control_points where code = 'CCP-PAST-HOLD'));
select pg_temp.ck('1c the pasteurisation step shows 63 °C · 30 min and points to the minutes step',
  (select target_txt = '63 °C · 30 min' and instruction_it like '%al passo dopo, i minuti di sosta%' from fabula.v_process_steps where step_id = :'step_past'),
  (select target_txt from fabula.v_process_steps where step_id = :'step_past'));
select pg_temp.ck('1d a minutes step right after it, in the same preset and phase: duration, 30 min (min 30), CCP-PAST-HOLD, active',
  (select phase = 'start' and step_order = :past_order + 1 and record_metric = 'duration' and duration_min = 30 and duration_min_min = 30
          and ccp_code = 'CCP-PAST-HOLD' and active and name_it = 'Sosta di pastorizzazione (CCP 2)' from fabula.process_steps where id = :'step_hold'));
select pg_temp.ck('1e exactly one minutes step per preset that pasteurises',
  (select count(*) from fabula.process_steps where ccp_code = 'CCP-PAST-HOLD') = (select count(distinct preset_id) from fabula.process_steps where ccp_code = 'CCP-PAST' and active)
  and not exists (select 1 from fabula.process_steps where ccp_code = 'CCP-PAST-HOLD' group by preset_id having count(*) > 1));
select pg_temp.ck('1f the tablet reads it as a critical step with its target (v_process_steps: ccp_code, 30 min)',
  (select ccp_code = 'CCP-PAST-HOLD' and record_metric = 'duration' and target_txt = '30 min' from fabula.v_process_steps where step_id = :'step_hold'));
select pg_temp.ck('1g the close check is still closed to logins and anon',
  not has_function_privilege('authenticated', 'fabula.trg_batch_ccp_check()', 'EXECUTE') and not has_function_privilege('anon', 'fabula.trg_batch_ccp_check()', 'EXECUTE'));
select pg_temp.ck('1h the CCP limits guard keeps the minutes: a CCP cannot lose its minimum',
  pg_temp.err($q$update fabula.haccp_control_points set min_value = null where code = 'CCP-PAST-HOLD'$q$) like '%non si può cancellare%');

-- ============================== 2. the minutes through log_ccp ==============================
select pg_temp.lot('LH-A', :'moz');
select pg_temp.log('CCP-PAST-HOLD', 45, 'LH-A') r45 \gset
select pg_temp.ck('2a 45 minutes: ok, the lot is not held', :'r45'::jsonb ->> 'result' = 'ok' and not pg_temp.held('LH-A'), :'r45');
select pg_temp.log('CCP-PAST-HOLD', 30, 'LH-A') r30 \gset
select pg_temp.ck('2b 30 minutes (the limit): ok', :'r30'::jsonb ->> 'result' = 'ok' and not pg_temp.held('LH-A'), :'r30');
select pg_temp.lot('LH-B', :'moz');
select pg_temp.log('CCP-PAST-HOLD', 25, 'LH-B') r25 \gset
select pg_temp.ck('2c 25 minutes: critical non-conformity, the lot is held with «CCP 2 fuori limite (25 min)»',
  :'r25'::jsonb ->> 'result' = 'non_conformity' and (:'r25'::jsonb ->> 'lot_on_hold')::boolean and pg_temp.held('LH-B')
  and pg_temp.reason('LH-B') = 'CCP 2 fuori limite (25 min)'
  and exists (select 1 from fabula.non_conformities where lot_number = 'LH-B' and severity = 'critical' and description like 'CCP 2 · Pastorizzazione: minuti di sosta%25 min fuori dal limite critico%'),
  pg_temp.reason('LH-B'));
select pg_temp.ck('2d …and the answer carries what to do (restart the 30 minutes) and the limit',
  :'r25'::jsonb ->> 'corrective_it' like 'Sosta più corta di 30 minuti: si riporta il latte a 63 °C e si ricomincia il conteggio%'
  and :'r25'::jsonb ->> 'limit_it' like 'Pastorizzazione a tino: sosta di almeno 30 minuti%' and :'r25'::jsonb ->> 'ccp' = 'CCP 2');
select pg_temp.lot('LH-C', :'moz');
select pg_temp.ck('2e 300 minutes is not a possible value: refused, nothing written',
  pg_temp.err($q$select pg_temp.log('CCP-PAST-HOLD', 300, 'LH-C')$q$) <> ''
  and not exists (select 1 from fabula.haccp_log l join fabula.production_batches b on b.id = l.batch_id where b.batch_lot = 'LH-C'),
  pg_temp.err($q$select pg_temp.log('CCP-PAST-HOLD', 300, 'LH-C')$q$));
select pg_temp.log('CCP-PAST', 62.5, 'LH-C') r625 \gset
select pg_temp.ck('2f the temperature at 62,5 °C is still a critical non-conformity and holds the lot', :'r625'::jsonb ->> 'result' = 'non_conformity' and pg_temp.held('LH-C'), :'r625');
select pg_temp.lot('LH-D', :'moz');
select pg_temp.log('CCP-PAST', 63.5, 'LH-D') r635 \gset
select pg_temp.log('CCP-PAST', 64, 'LH-D') r64 \gset
select pg_temp.ck('2g 63,5 °C is an alert (within the limit, below 64); 64 °C is ok; neither holds the lot',
  :'r635'::jsonb ->> 'result' = 'warning' and :'r64'::jsonb ->> 'result' = 'ok' and not pg_temp.held('LH-D'), :'r635' || ' / ' || :'r64');

-- ============================== 3. the minutes through the preset step ==============================
select pg_temp.lot('LH-E', :'moz', 'milk', :'preset');
select fabula.log_batch_step('LH-E', :'step_hold', 32, '10000000-0000-4000-a000-000000121a01') s32 \gset
select pg_temp.ck('3a the minutes step writes the register (CCP-PAST-HOLD, source preset, linked to the lot) and 32 min is ok',
  exists (select 1 from fabula.haccp_log l join fabula.haccp_control_points c on c.id = l.control_point_id join fabula.production_batches b on b.id = l.batch_id
           where b.batch_lot = 'LH-E' and c.code = 'CCP-PAST-HOLD' and l.measured_value = 32 and l.result = 'ok' and l.source = 'preset')
  and not pg_temp.held('LH-E'));
select pg_temp.lot('LH-F', :'moz', 'milk', :'preset');
select fabula.log_batch_step('LH-F', :'step_hold', 20, '10000000-0000-4000-a000-000000121a01') s20 \gset
select pg_temp.ck('3b 20 minutes on the step: non-conformity and the lot is held',
  pg_temp.held('LH-F') and exists (select 1 from fabula.non_conformities where lot_number = 'LH-F' and severity = 'critical'), pg_temp.reason('LH-F'));
select pg_temp.ck('3c the step log keeps the minutes against their 30 min target',
  (select metric = 'duration' and target_value = 30 and actual_value = 20 from fabula.batch_step_logs l join fabula.production_batches b on b.id = l.batch_id
    where b.batch_lot = 'LH-F' and l.step_id = :'step_hold'));

-- ============================== 4. the close ==============================
select pg_temp.lot('LH-G', :'moz');
select pg_temp.log('CCP-PAST', 64, 'LH-G') g1 \gset
select pg_temp.log('CCP-STRETCH', 62, 'LH-G') g2 \gset
select pg_temp.close('LH-G');
select pg_temp.ck('4a a milk lot closed with CCP 2 temperature and CCP 3 but no minutes is held: «CCP mancante alla chiusura: CCP-PAST-HOLD»',
  pg_temp.held('LH-G') and pg_temp.reason('LH-G') = 'CCP mancante alla chiusura: CCP-PAST-HOLD', pg_temp.reason('LH-G'));
select pg_temp.ck('4b …and Sicurezza gets the alert naming the minutes',
  exists (select 1 from fabula.bot_messages where agent = 'sicurezza' and severity = 'alert' and title = 'Lotto LH-G chiuso senza minuti di sosta della pastorizzazione (CCP 2)'
          and body like '%manca: CCP-PAST-HOLD.%Il lotto è BLOCCATO%'),
  (select string_agg(title, ' | ') from fabula.bot_messages where title like 'Lotto LH-G%'));
select pg_temp.ck('4c …and «Perché?» keeps the three points of CCP 2/3 with their values (minutes empty)',
  exists (select 1 from fabula.message_basis where agent = 'sicurezza' and call = 'batch_ccp' and data ->> 'lot' = 'LH-G'
           and data -> 'missing' = '["CCP-PAST-HOLD"]'::jsonb
           and jsonb_array_length(data -> 'points') = 3
           and exists (select 1 from jsonb_array_elements(data -> 'points') p where p ->> 'code' = 'CCP-PAST-HOLD' and p ->> 'value' is null and p ->> 'unit' = 'min')),
  (select data::text from fabula.message_basis where call = 'batch_ccp' and data ->> 'lot' = 'LH-G' limit 1));
select pg_temp.lot('LH-H', :'moz');
select pg_temp.log('CCP-PAST', 64, 'LH-H') h1 \gset
select pg_temp.log('CCP-PAST-HOLD', 31, 'LH-H') h2 \gset
select pg_temp.log('CCP-STRETCH', 62, 'LH-H') h3 \gset
select pg_temp.close('LH-H');
select pg_temp.ck('4d with the temperature, the minutes and CCP 3 the lot closes free', not pg_temp.held('LH-H') and pg_temp.reason('LH-H') = '', pg_temp.reason('LH-H'));
select pg_temp.lot('LH-I', :'moz');
select pg_temp.close('LH-I');
select pg_temp.ck('4e closed with nothing: the missing list keeps its order, the minutes last («CCP-PAST, CCP-STRETCH, CCP-PAST-HOLD»)',
  pg_temp.reason('LH-I') = 'CCP mancante alla chiusura: CCP-PAST, CCP-STRETCH, CCP-PAST-HOLD', pg_temp.reason('LH-I'));
select pg_temp.ck('4f …and its alert names all three in plain words',
  exists (select 1 from fabula.bot_messages where title = 'Lotto LH-I chiuso senza pastorizzazione (CCP 2) e temperatura di filatura (CCP 3) e minuti di sosta della pastorizzazione (CCP 2)'),
  (select string_agg(title, ' | ') from fabula.bot_messages where title like 'Lotto LH-I%'));
select pg_temp.lot('RH-A', :'ric', 'whey');
select pg_temp.log('CCP-RIC', 85, 'RH-A') ra \gset
select pg_temp.close('RH-A');
select pg_temp.ck('4g a ricotta lot (whey) is not asked the minutes: CCP 4 alone closes it free', not pg_temp.held('RH-A'), pg_temp.reason('RH-A'));
update fabula.haccp_control_points set active = false where code = 'CCP-PAST-HOLD';
select pg_temp.lot('LH-J', :'moz');
select pg_temp.log('CCP-PAST', 72, 'LH-J') j1 \gset
select pg_temp.log('CCP-STRETCH', 62, 'LH-J') j2 \gset
select pg_temp.close('LH-J');
select pg_temp.ck('4h with CCP-PAST-HOLD switched off (a continuous pasteuriser) the minutes are not required: closes free',
  not pg_temp.held('LH-J'), pg_temp.reason('LH-J'));
select pg_temp.lot('LH-K', :'moz');
select pg_temp.close('LH-K');
select pg_temp.ck('4i …and a lot with nothing is held exactly as before v1.21 («CCP-PAST, CCP-STRETCH»)',
  pg_temp.reason('LH-K') = 'CCP mancante alla chiusura: CCP-PAST, CCP-STRETCH', pg_temp.reason('LH-K'));
update fabula.haccp_control_points set active = true where code = 'CCP-PAST-HOLD';
insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, source) values (pg_temp.today(), 'LH-SIM', :'moz', 200, 'milk', now(), 'simulation');
select pg_temp.close('LH-SIM');
select pg_temp.ck('4j a simulated lot is still exempt', not pg_temp.held('LH-SIM'));

-- ============================== 5. «Prima di chiudere» ==============================
select fabula._haccp_evening_items(pg_temp.today()) ev \gset
select pg_temp.ck('5a LH-A (minutes recorded) is not listed for the minutes',
  not (:'ev'::jsonb @> jsonb_build_array(jsonb_build_object('code', 'ccp:CCP-PAST-HOLD:LH-A'))), :'ev');
select pg_temp.ck('5b LH-G (no minutes) is listed with the scan that opens the minutes form',
  :'ev'::jsonb @> jsonb_build_array(jsonb_build_object('code', 'ccp:CCP-PAST-HOLD:LH-G', 'label_it', 'CCP 2 Pastorizzazione: minuti di sosta a ≥ 63 °C · lotto LH-G', 'scan', 'CCP:CCP-PAST-HOLD:LH-G')),
  :'ev');
select pg_temp.ck('5c LH-H (all recorded) is not listed for CCP 2 at all',
  not exists (select 1 from jsonb_array_elements(:'ev'::jsonb) i where i ->> 'code' in ('ccp:CCP-PAST-HOLD:LH-H', 'ccp:CCP-PAST:LH-H')));
select pg_temp.ck('5d the ricotta lot is not listed for the minutes', not exists (select 1 from jsonb_array_elements(:'ev'::jsonb) i where i ->> 'code' = 'ccp:CCP-PAST-HOLD:RH-A'));
update fabula.settings set value = 'crudo' where key = 'food.milk_process';
select fabula._haccp_evening_items(pg_temp.today()) evr \gset
select pg_temp.ck('5e raw milk (food.milk_process = crudo): neither CCP 2 line is listed',
  not exists (select 1 from jsonb_array_elements(:'evr'::jsonb) i where i ->> 'code' like 'ccp:CCP-PAST%'));
update fabula.settings set value = 'pastorizzato' where key = 'food.milk_process';

-- ============================== 6. the MOD-02 register ==============================
select (fabula.haccp_register('MOD-02', pg_temp.today(), pg_temp.today()) -> 'rows') r02 \gset
select pg_temp.ck('6a MOD-02 prints the minutes next to the temperature: «45 min», limit «≥ 30 min»',
  exists (select 1 from jsonb_array_elements(:'r02'::jsonb) r where r ->> 'controllo' = 'CCP 2 Pastorizzazione: minuti di sosta a ≥ 63 °C' and r ->> 'valore' = '45 min' and r ->> 'limite' = '≥ 30 min'),
  left(:'r02', 600));
select pg_temp.ck('6b …the temperature rows show the new limit «≥ 63 °C»',
  exists (select 1 from jsonb_array_elements(:'r02'::jsonb) r where r ->> 'controllo' like 'CCP 2 Temperatura pastorizzazione%' and r ->> 'limite' = '≥ 63 °C'));
select pg_temp.ck('6c …and a short hold is flagged in red (_ko) on the register',
  exists (select 1 from jsonb_array_elements(:'r02'::jsonb) r where r ->> 'valore' = '25 min' and (r ->> '_ko')::boolean));
