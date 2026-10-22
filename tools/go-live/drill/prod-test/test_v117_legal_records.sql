-- v1.17 (audit D-1) · rows a login writes itself into the legal registers are checked by the database · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh a_test
--   su postgres -c "psql -d a_test -f tools/go-live/drill/prod-test/test_v117_legal_records.sql" | grep -E "PASS|FAIL"
-- Sections: 1 structure · 2 the audit's forged writes, as produzione · 3 what the tablet and the login-run functions still write ·
-- 4 role matrix (positive and negative) · 5 the database's own writers are not touched · 6 a refused step leaves the whole save unwritten ·
-- 7 milk intake · 8 delayed entries and corrections keep their controlled routes (paper copy within 7 days, correct_record).
-- Every login attempt goes through pg_temp.try, which records its SQLSTATE, so the suite prints PASS/FAIL lines only.
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
create temp table d1_try (tag text primary key, state text, msg text, out jsonb);
grant all on d1_try to authenticated, service_role;
create or replace function pg_temp.try(p_tag text, p_sql text) returns text language plpgsql as $$
declare v jsonb;
begin
  begin
    execute p_sql into v;
    insert into d1_try values (p_tag, '00000', 'ok', v) on conflict (tag) do update set state = excluded.state, msg = excluded.msg, out = excluded.out;
  exception when others then
    insert into d1_try values (p_tag, sqlstate, sqlerrm, null) on conflict (tag) do update set state = excluded.state, msg = excluded.msg, out = null;
  end;
  return p_tag;
end $$;
-- what an attempt ended with: '00000' saved, otherwise the SQLSTATE
create or replace function pg_temp.st(p_tag text) returns text language sql as $$ select coalesce((select state from d1_try where tag = p_tag), 'not run') $$;
create or replace function pg_temp.msg(p_tag text) returns text language sql as $$ select coalesce((select left(msg, 150) from d1_try where tag = p_tag), '') $$;

select (now() at time zone 'Europe/Rome')::date d \gset
select to_char(:'d'::date, 'YYYYMMDD') ymd \gset

-- ============================== logins: one per role, plus a login with no staff row ==============================
insert into auth.users (id, email) values
  ('00000000-0000-4000-a000-00000000d101', 'tit@d1.it'), ('00000000-0000-4000-a000-00000000d102', 'soc@d1.it'),
  ('00000000-0000-4000-a000-00000000d103', 'prod@d1.it'), ('00000000-0000-4000-a000-00000000d104', 'banco@d1.it'),
  ('00000000-0000-4000-a000-00000000d105', 'sped@d1.it'), ('00000000-0000-4000-a000-00000000d106', 'cons@d1.it'),
  ('00000000-0000-4000-a000-00000000d107', 'qual@d1.it'), ('00000000-0000-4000-a000-00000000d108', 'resp@d1.it'),
  ('00000000-0000-4000-a000-00000000d109', 'amm@d1.it'), ('00000000-0000-4000-a000-00000000d110', 'mkt@d1.it'),
  ('00000000-0000-4000-a000-00000000d111', 'nostaff@d1.it');
insert into fabula.staff (id, full_name, auth_user_id, app_role, role, active) values
  ('10000000-0000-4000-a000-00000000d101', 'Titolare D1', '00000000-0000-4000-a000-00000000d101', 'titolare', 'owner', true),
  ('10000000-0000-4000-a000-00000000d102', 'Socio D1', '00000000-0000-4000-a000-00000000d102', 'socio', 'partner', true),
  ('10000000-0000-4000-a000-00000000d103', 'Produzione D1', '00000000-0000-4000-a000-00000000d103', 'produzione', 'casaro', true),
  ('10000000-0000-4000-a000-00000000d104', 'Banco D1', '00000000-0000-4000-a000-00000000d104', 'banco', 'commesso', true),
  ('10000000-0000-4000-a000-00000000d105', 'Spedizioni D1', '00000000-0000-4000-a000-00000000d105', 'spedizioni', 'operaio', true),
  ('10000000-0000-4000-a000-00000000d106', 'Consulente D1', '00000000-0000-4000-a000-00000000d106', 'consulente', 'consulente', true),
  ('10000000-0000-4000-a000-00000000d107', 'Qualita D1', '00000000-0000-4000-a000-00000000d107', 'qualita', 'operaio', true),
  ('10000000-0000-4000-a000-00000000d108', 'Resp Produzione D1', '00000000-0000-4000-a000-00000000d108', 'resp_produzione', 'casaro', true),
  ('10000000-0000-4000-a000-00000000d109', 'Amministrazione D1', '00000000-0000-4000-a000-00000000d109', 'amministrazione', 'operaio', true),
  ('10000000-0000-4000-a000-00000000d110', 'Marketing D1', '00000000-0000-4000-a000-00000000d110', 'marketing', 'operaio', true);
insert into fabula.staff (id, full_name, role, active) values ('10000000-0000-4000-a000-00000000d1ff', 'Ex Dipendente D1', 'operaio', false);
\set TIT 'select set_config(''request.jwt.claims'', ''{"sub":"00000000-0000-4000-a000-00000000d101","role":"authenticated"}'', false); set role authenticated;'
\set PROD 'select set_config(''request.jwt.claims'', ''{"sub":"00000000-0000-4000-a000-00000000d103","role":"authenticated"}'', false); set role authenticated;'
\set BANCO 'select set_config(''request.jwt.claims'', ''{"sub":"00000000-0000-4000-a000-00000000d104","role":"authenticated"}'', false); set role authenticated;'
\set SPED 'select set_config(''request.jwt.claims'', ''{"sub":"00000000-0000-4000-a000-00000000d105","role":"authenticated"}'', false); set role authenticated;'

-- ============================== fixtures (as the database owner) ==============================
insert into fabula.parties (type, legal_name, is_milk_supplier) values ('supplier', 'Masseria D1', true) returning id sup \gset
insert into fabula.parties (type, legal_name, active) values ('customer', 'Cliente D1', true) returning id cust \gset
select id moz from fabula.products where sku = 'MOZ-DOP-KG' \gset
select id raw from fabula.products where sku = 'RAW-MILK' \gset
select id salt from fabula.products where sku = 'CON-SALT' \gset
select id cp_past from fabula.haccp_control_points where code = 'CCP-PAST' \gset
select id cp_cold from fabula.haccp_control_points where code = 'CCP-COLD-1' \gset
select id cp_clean from fabula.haccp_control_points where code = 'PRP-CLEAN' \gset
select id cp_water from fabula.haccp_control_points where code = 'PRP-WATER-CL' \gset
select id lt from fabula.lab_tests where code = 'MOZ-LM' \gset
insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, temperature_c, accepted, source)
values (:'d', (now() at time zone 'Europe/Rome')::time, :'sup', 'LM-D1-01', 600, 4, true, 'tablet') returning id mi \gset
select set_config('d1.moz', :'moz', false), set_config('d1.raw', :'raw', false), set_config('d1.salt', :'salt', false), set_config('d1.cust', :'cust', false),
       set_config('d1.cp_past', :'cp_past', false), set_config('d1.cp_cold', :'cp_cold', false), set_config('d1.cp_clean', :'cp_clean', false),
       set_config('d1.cp_water', :'cp_water', false), set_config('d1.lt', :'lt', false), set_config('d1.mi', :'mi', false), set_config('d1.d', :'d', false), set_config('d1.sup', :'sup', false);

-- ============================== 1. structure ==============================
select pg_temp.ck('1a the guard is on all five registers, BEFORE the other triggers (haccp_log, production_batches insert+update, stock_moves, lab_samples, milk_intake)',
  (select count(*) from pg_trigger t where t.tgfoid = to_regprocedure('fabula.trg_login_record_guard()') and not t.tgisinternal) = 5
  and exists (select 1 from pg_trigger where tgname = 'batch_a0_login_guard' and tgrelid = 'fabula.production_batches'::regclass and pg_get_triggerdef(oid) like '%BEFORE INSERT OR UPDATE%'));
select pg_temp.ck('1b the guard function is SECURITY INVOKER (it must see who writes) with a fixed search_path',
  (select not prosecdef and proconfig::text like '%search_path=%' from pg_proc where oid = to_regprocedure('fabula.trg_login_record_guard()')));
select pg_temp.ck('1c grants and policies are untouched: logins keep INSERT on the five tables, 5 policies each',
  (select bool_and(has_table_privilege('authenticated', ('fabula.' || t)::regclass, 'INSERT')) from unnest(array['haccp_log','production_batches','stock_moves','lab_samples','milk_intake']) t)
  and (select count(*) from pg_policies where schemaname = 'fabula' and tablename in ('haccp_log','production_batches','stock_moves','lab_samples','milk_intake')) = 25);

-- ============================== 2. the audit's forged writes, as produzione ==============================
:PROD
-- A1: the audit's reproduction: CCP-PAST 60 °C «ok», signed and entered as the titolare, 30 days back, source sensor
select pg_temp.try('a1', format($q$insert into fabula.haccp_log (control_point_id, logged_at, measured_value, result, operator, operator_id, entered_by_id, source)
  values (%L, now() - interval '30 days', 60, 'ok', 'Titolare D1', '10000000-0000-4000-a000-00000000d101', '10000000-0000-4000-a000-00000000d101', 'sensor') returning to_jsonb(haccp_log)$q$, current_setting('d1.cp_past')));
-- A2: a CCP reading written straight into the register, today, from the tablet: it must go through log_ccp (result, NC, hold)
select pg_temp.try('a2', format($q$insert into fabula.haccp_log (control_point_id, measured_value, result, operator, source) values (%L, 74, 'ok', 'Produzione D1', 'tablet') returning to_jsonb(haccp_log)$q$, current_setting('d1.cp_past')));
-- A3/A4: the cleaning round (still allowed) dated 30 days back, or with source sensor
select pg_temp.try('a3', format($q$insert into fabula.haccp_log (control_point_id, logged_at, result, operator, source) values (%L, now() - interval '30 days', 'ok', 'Produzione D1', 'tablet') returning to_jsonb(haccp_log)$q$, current_setting('d1.cp_clean')));
select pg_temp.try('a4', format($q$insert into fabula.haccp_log (control_point_id, result, operator, source) values (%L, 'ok', 'Produzione D1', 'sensor') returning to_jsonb(haccp_log)$q$, current_setting('d1.cp_clean')));
-- A5: a cleaning round «entered by» the titolare
select pg_temp.try('a5', format($q$insert into fabula.haccp_log (control_point_id, result, operator, operator_id, entered_by_id, source) values (%L, 'ok', 'Produzione D1', '10000000-0000-4000-a000-00000000d103', '10000000-0000-4000-a000-00000000d101', 'tablet') returning to_jsonb(haccp_log)$q$, current_setting('d1.cp_clean')));
-- A6: a non-critical point with limits (water chlorine 0.05–0.50 mg/l): 0.9 sent as «ok»
select pg_temp.try('a6', format($q$insert into fabula.haccp_log (control_point_id, measured_value, result, operator, source) values (%L, 0.9, 'ok', 'Produzione D1', 'tablet') returning to_jsonb(haccp_log)$q$, current_setting('d1.cp_water')));
-- A7/A8: a lot with source test; a lot inserted already closed (the close-time CCP check never runs)
select pg_temp.try('a7', format($q$insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, started_at, source) values (%L, 'LD1A7', %L, 100, now(), 'test') returning to_jsonb(production_batches)$q$, current_setting('d1.d'), current_setting('d1.moz')));
select pg_temp.try('a8', format($q$insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, output_kg, started_at, finished_at, source) values (%L, 'LD1A8', %L, 100, 20, now() - interval '3 hours', now(), 'tablet') returning to_jsonb(production_batches)$q$, current_setting('d1.d'), current_setting('d1.moz')));
-- A9: a normal lot, then its source switched to test before the close
select pg_temp.try('a9_ins', format($q$insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, started_at, source, entered_by_id) values (%L, 'LD1A9', %L, 100, now(), 'tablet', '10000000-0000-4000-a000-00000000d101') returning to_jsonb(production_batches)$q$, current_setting('d1.d'), current_setting('d1.moz')));
select pg_temp.try('a9_upd', $q$update fabula.production_batches set source = 'test' where batch_lot = 'LD1A9' returning to_jsonb(production_batches)$q$);
select pg_temp.try('a9_eb', $q$update fabula.production_batches set entered_by_id = '10000000-0000-4000-a000-00000000d101', notes = 'x' where batch_lot = 'LD1A9' returning to_jsonb(production_batches)$q$);
-- A7s/A9s: the same two lot-lifecycle bypasses with «simulation» (trg_batch_ccp_check skips both simulation and test)
select pg_temp.try('a7s', format($q$insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, started_at, source) values (%L, 'LD1A7S', %L, 100, now(), 'simulation') returning to_jsonb(production_batches)$q$, current_setting('d1.d'), current_setting('d1.moz')));
select pg_temp.try('a9s_ins', format($q$insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, started_at, source) values (%L, 'LD1A9S', %L, 100, now(), 'tablet') returning to_jsonb(production_batches)$q$, current_setting('d1.d'), current_setting('d1.moz')));
select pg_temp.try('a9s_upd', $q$update fabula.production_batches set source = 'simulation' where batch_lot = 'LD1A9S' returning to_jsonb(production_batches)$q$);
-- A20: every movement type that is NOT on the login allowlist, in both directions (+1 and −1 kg)
select pg_temp.try('a20_' || t || '_' || sg, format($q$insert into fabula.stock_moves (product_id, lot_number, qty, move_type, batch_id, source) values (%L, 'LD1A9', %s, %L, (select id from fabula.production_batches where batch_lot = 'LD1A9'), 'tablet') returning to_jsonb(stock_moves)$q$,
       current_setting('d1.moz'), sg, t))
  from unnest(array['milk_intake','purchase_receipt','waste','sample','return']) t, unnest(array['1','-1']) sg;
-- A11–A16: stock written by hand
select pg_temp.try('a11', format($q$insert into fabula.stock_moves (product_id, lot_number, qty, move_type, source) values (%L, 'LD1A9', 1000, 'adjustment', 'console') returning to_jsonb(stock_moves)$q$, current_setting('d1.moz')));
select pg_temp.try('a12', format($q$insert into fabula.stock_moves (product_id, lot_number, qty, move_type, source) values (%L, 'LD1A9', 1000, 'sale', 'tablet') returning to_jsonb(stock_moves)$q$, current_setting('d1.moz')));
select pg_temp.try('a13', format($q$insert into fabula.stock_moves (product_id, lot_number, qty, move_type, source) values (%L, 'LD1A9', 1000, 'production_out', 'tablet') returning to_jsonb(stock_moves)$q$, current_setting('d1.moz')));
select pg_temp.try('a15', format($q$insert into fabula.stock_moves (product_id, lot_number, qty, move_type, source) values (%L, 'LM-D1-01', 1000, 'production_in', 'tablet') returning to_jsonb(stock_moves)$q$, current_setting('d1.raw')));
select pg_temp.try('a16', format($q$insert into fabula.stock_moves (product_id, lot_number, qty, move_type, source) values (%L, 'LD1A9', 1000, 'purchase_receipt', 'console') returning to_jsonb(stock_moves)$q$, current_setting('d1.moz')));
select pg_temp.try('a19', format($q$insert into fabula.stock_moves (product_id, lot_number, qty, move_type, batch_id, source) values (%L, 'LD1A9', -10, 'production_in', (select id from fabula.production_batches where batch_lot = 'LD1A9'), 'tablet') returning to_jsonb(stock_moves)$q$, current_setting('d1.moz')));
-- A17: the consumable correction function, called by the login with a finished product: 1000 kg of mozzarella «used» by the lot,
-- i.e. −1000 kg of finished goods removed from stock by an adjustment (a negative quantity is already refused by batch_consumables)
select pg_temp.try('a17', $q$select to_jsonb(fabula.correct_batch_consumable('LD1A9', 'MOZ-DOP-KG', 1000, 'test'))$q$);
-- A18: a lab result written straight into the register
select pg_temp.try('a18', format($q$insert into fabula.lab_samples (test_id, sample_code, outcome, result_it, report_no, report_date) values (%L, 'CD1-A18', 'conforme', 'assente', 'R-1', current_date) returning to_jsonb(lab_samples)$q$, current_setting('d1.lt')));
reset role;

select pg_temp.ck('2a (audit) CCP-PAST 60 °C «ok», signed as the titolare, 30 days back, source sensor: refused, and nothing reached the register (no row, no NC)',
  pg_temp.st('a1') = '42501' and not exists (select 1 from fabula.haccp_log where measured_value = 60), pg_temp.st('a1') || ' ' || pg_temp.msg('a1'));
select pg_temp.ck('2b a CCP reading written straight into the register is refused (it goes through log_ccp: result, NC and hold)',
  pg_temp.st('a2') = '42501' and not exists (select 1 from fabula.haccp_log where measured_value = 74 and control_point_id = :'cp_past'), pg_temp.st('a2') || ' ' || pg_temp.msg('a2'));
select pg_temp.ck('2c the cleaning round dated 30 days back is refused (only the last 7 days, never the future)', pg_temp.st('a3') = '22023', pg_temp.st('a3') || ' ' || pg_temp.msg('a3'));
select pg_temp.ck('2d the cleaning round with source «sensor» is refused', pg_temp.st('a4') = '42501', pg_temp.st('a4') || ' ' || pg_temp.msg('a4'));
select pg_temp.ck('2e a row «entered by» the titolare is saved with the login''s own staff id (Produzione D1)',
  pg_temp.st('a5') = '00000' and (select out->>'entered_by_id' from d1_try where tag = 'a5') = '10000000-0000-4000-a000-00000000d103',
  pg_temp.st('a5') || ' entered_by ' || coalesce((select out->>'entered_by_id' from d1_try where tag = 'a5'), '-'));
select pg_temp.ck('2f water chlorine 0.9 mg/l sent as «ok» is saved as non_conformity (the result comes from the limits)',
  pg_temp.st('a6') = '00000' and (select out->>'result' from d1_try where tag = 'a6') = 'non_conformity',
  pg_temp.st('a6') || ' result ' || coalesce((select out->>'result' from d1_try where tag = 'a6'), '-'));
select pg_temp.ck('2g (audit) a lot with source «test» is refused', pg_temp.st('a7') = '42501' and not exists (select 1 from fabula.production_batches where batch_lot = 'LD1A7'), pg_temp.st('a7') || ' ' || pg_temp.msg('a7'));
select pg_temp.ck('2h (audit) a lot inserted already closed is refused (the close-time CCP check and hold would never run)',
  pg_temp.st('a8') = '42501' and not exists (select 1 from fabula.production_batches where batch_lot = 'LD1A8'), pg_temp.st('a8') || ' ' || pg_temp.msg('a8'));
select pg_temp.ck('2i a normal lot can still be started; its «entered by» is the login, not the titolare it claimed',
  pg_temp.st('a9_ins') = '00000' and (select entered_by_id from fabula.production_batches where batch_lot = 'LD1A9') = '10000000-0000-4000-a000-00000000d103',
  pg_temp.st('a9_ins') || ' entered_by ' || coalesce((select entered_by_id::text from fabula.production_batches where batch_lot = 'LD1A9'), '-'));
select pg_temp.ck('2j switching an open lot''s source to «test» before the close is refused', pg_temp.st('a9_upd') = '42501'
  and (select source from fabula.production_batches where batch_lot = 'LD1A9') = 'tablet', pg_temp.st('a9_upd') || ' ' || pg_temp.msg('a9_upd'));
select pg_temp.ck('2g2 a lot with source «simulation» is refused', pg_temp.st('a7s') = '42501' and not exists (select 1 from fabula.production_batches where batch_lot = 'LD1A7S'), pg_temp.st('a7s') || ' ' || pg_temp.msg('a7s'));
select pg_temp.ck('2j2 switching an open lot''s source to «simulation» before the close is refused', pg_temp.st('a9s_ins') = '00000' and pg_temp.st('a9s_upd') = '42501'
  and (select source from fabula.production_batches where batch_lot = 'LD1A9S') = 'tablet', pg_temp.st('a9s_ins') || '/' || pg_temp.st('a9s_upd') || ' ' || pg_temp.msg('a9s_upd'));
select pg_temp.ck('2u every movement type outside the login allowlist (milk_intake, purchase_receipt, waste, sample, return) is refused, +1 and −1 kg',
  (select bool_and(state = '42501') and count(*) = 10 from d1_try where tag like 'a20\_%'), (select string_agg(tag || ':' || state, ' ' order by tag) from d1_try where tag like 'a20\_%'));
select pg_temp.ck('2k an update cannot move a lot''s «entered by» (the rest of the update is saved)', pg_temp.st('a9_eb') = '00000'
  and (select entered_by_id from fabula.production_batches where batch_lot = 'LD1A9') = '10000000-0000-4000-a000-00000000d103'
  and (select notes from fabula.production_batches where batch_lot = 'LD1A9') = 'x', pg_temp.st('a9_eb'));
select pg_temp.ck('2l (audit) +1000 kg of mozzarella by stock adjustment is refused', pg_temp.st('a11') = '42501', pg_temp.st('a11') || ' ' || pg_temp.msg('a11'));
select pg_temp.ck('2m +1000 kg as a «sale» with a positive quantity is refused', pg_temp.st('a12') = '42501', pg_temp.st('a12') || ' ' || pg_temp.msg('a12'));
select pg_temp.ck('2n +1000 kg as production output with no closed lot behind it is refused', pg_temp.st('a13') = '42501', pg_temp.st('a13') || ' ' || pg_temp.msg('a13'));
select pg_temp.ck('2o +1000 kg of raw milk as a «production_in» with a positive quantity is refused', pg_temp.st('a15') = '42501', pg_temp.st('a15') || ' ' || pg_temp.msg('a15'));
select pg_temp.ck('2p +1000 kg as a purchase receipt written by hand is refused (receipts go through receive_purchase_order)', pg_temp.st('a16') = '42501', pg_temp.st('a16') || ' ' || pg_temp.msg('a16'));
select pg_temp.ck('2q a finished product cannot be «consumed» into a lot by hand (−10 kg mozzarella as production_in)', pg_temp.st('a19') = '42501', pg_temp.st('a19') || ' ' || pg_temp.msg('a19'));
select pg_temp.ck('2r the consumable correction called by the login with a finished product (−1000 kg of mozzarella by adjustment) is refused, and nothing of it is kept',
  pg_temp.st('a17') = '42501' and not exists (select 1 from fabula.stock_moves where product_id = :'moz' and move_type = 'adjustment')
  and not exists (select 1 from fabula.batch_consumables bc join fabula.production_batches b on b.id = bc.batch_id where b.batch_lot = 'LD1A9' and bc.product_id = :'moz'),
  pg_temp.st('a17') || ' ' || pg_temp.msg('a17'));
select pg_temp.ck('2s a lab result written straight into the register («conforme», with a report) is refused', pg_temp.st('a18') = '42501'
  and not exists (select 1 from fabula.lab_samples where sample_code = 'CD1-A18'), pg_temp.st('a18') || ' ' || pg_temp.msg('a18'));
select pg_temp.ck('2t no stock at all was added for mozzarella by any of the attempts above (on-hand stays 0)',
  (select coalesce(sum(qty), 0) from fabula.stock_moves where product_id = :'moz') = 0, (select coalesce(sum(qty), 0)::text from fabula.stock_moves where product_id = :'moz'));

-- ============================== 3. what the tablet and the login-run functions still write ==============================
:PROD
-- P1: the end-of-shift cleaning round, as the tablet sends it (save_ops)
select pg_temp.try('p1', format($q$select fabula.save_ops(jsonb_build_array(jsonb_build_object('table', 'haccp_log', 'row', jsonb_build_object('control_point_id', %L, 'result', 'ok', 'corrective_action', null, 'operator', 'Produzione D1', 'operator_id', '10000000-0000-4000-a000-00000000d103', 'source', 'tablet'))), gen_random_uuid())$q$, current_setting('d1.cp_clean')));
-- P2: the same, saved offline yesterday and sent now (save_ops keeps the time it was made)
select pg_temp.try('p2', format($q$select fabula.save_ops(jsonb_build_array(jsonb_build_object('table', 'haccp_log', 'row', jsonb_build_object('control_point_id', %L, 'result', 'warning', 'corrective_action', 'Non fatto: pavimento', 'operator', 'Produzione D1', 'operator_id', '10000000-0000-4000-a000-00000000d103', 'source', 'tablet'))), gen_random_uuid(), now() - interval '1 day', now())$q$, current_setting('d1.cp_clean')));
-- P3: batch start as the tablet sends it: the lot, the milk into the vat, the raw milk out of stock, CCP 2 through log_ccp
select pg_temp.try('p3', format($q$select fabula.save_ops(jsonb_build_array(
   jsonb_build_object('table', 'production_batches', 'row', jsonb_build_object('batch_date', %L, 'batch_lot', 'L%s-D', 'product_id', %L, 'milk_in_kg', 100, 'started_at', now(), 'casaro', 'Produzione D1', 'casaro_id', '10000000-0000-4000-a000-00000000d103', 'source', 'tablet')),
   jsonb_build_object('table', 'batch_milk_inputs', 'row', jsonb_build_object('batch_id', '$0.id', 'milk_intake_id', %L, 'qty_kg', 100)),
   jsonb_build_object('table', 'stock_moves', 'row', jsonb_build_object('product_id', %L, 'lot_number', 'LM-D1-01', 'qty', -100, 'move_type', 'production_in', 'batch_id', '$0.id', 'source', 'tablet')),
   jsonb_build_object('rpc', 'log_ccp', 'args', jsonb_build_object('p_cp_code', 'CCP-PAST', 'p_value', 74, 'p_staff_id', '10000000-0000-4000-a000-00000000d103', 'p_batch_lot', '$0.batch_lot', 'p_source', 'tablet', 'p_equipment_code', 'TERM-02'))), gen_random_uuid())$q$,
   current_setting('d1.d'), :'ymd', current_setting('d1.moz'), current_setting('d1.mi'), current_setting('d1.raw')));
select (select out->0->>'batch_lot' from d1_try where tag = 'p3') lot \gset
select set_config('d1.lot', coalesce(:'lot', 'none'), false);
-- P4: dosing a consumable, then re-confirming it with another quantity (record_batch_consumable → correct_batch_consumable: an adjustment)
select pg_temp.try('p4a', format($q$select to_jsonb(fabula.record_batch_consumable(%L, 'CON-SALT', 1.0, 1.0, '10000000-0000-4000-a000-00000000d103', null, true))$q$, current_setting('d1.lot')));
select pg_temp.try('p4b', format($q$select to_jsonb(fabula.record_batch_consumable(%L, 'CON-SALT', 1.5, 1.0, '10000000-0000-4000-a000-00000000d103', null, true))$q$, current_setting('d1.lot')));
-- P5: CCP 3 through log_ccp, then the close as the tablet sends it (the lot update and the production output)
select pg_temp.try('p5a', format($q$select fabula.log_ccp(p_cp_code => 'CCP-STRETCH', p_value => 62, p_logged_at => null, p_staff_id => '10000000-0000-4000-a000-00000000d103', p_batch_lot => %L, p_source => 'tablet')$q$, current_setting('d1.lot')));
select pg_temp.try('p5b', format($q$select fabula.save_ops(jsonb_build_array(
   jsonb_build_object('table', 'production_batches', 'update', jsonb_build_object('batch_lot', %L), 'row', jsonb_build_object('output_kg', 21, 'finished_at', now())),
   jsonb_build_object('table', 'stock_moves', 'row', jsonb_build_object('product_id', %L, 'lot_number', %L, 'expiry_date', current_date + 5, 'qty', 21, 'move_type', 'production_out', 'batch_id', (select id from fabula.production_batches where batch_lot = %L), 'source', 'tablet'))), gen_random_uuid())$q$,
   current_setting('d1.lot'), current_setting('d1.moz'), current_setting('d1.lot'), current_setting('d1.lot')));
-- P6: a second production output for the same lot beyond the 21 kg the close recorded
select pg_temp.try('p6', format($q$insert into fabula.stock_moves (product_id, lot_number, qty, move_type, batch_id, source) values (%L, %L, 1, 'production_out', (select id from fabula.production_batches where batch_lot = %L), 'tablet') returning to_jsonb(stock_moves)$q$, current_setting('d1.moz'), current_setting('d1.lot'), current_setting('d1.lot')));
-- P7: the pest round and a lab sample taken (functions that run as the login)
select pg_temp.try('p7a', $q$select fabula.record_pest_inspection('interno', '[{"station":"ESC-01","status":"ok"}]', '10000000-0000-4000-a000-00000000d103')$q$);
select pg_temp.try('p7b', format($q$select fabula.record_sample_taken('MOZ-LM', %L, null, '10000000-0000-4000-a000-00000000d103')$q$, current_setting('d1.lot')));
select pg_temp.try('p7c', format($q$select to_jsonb(outcome) from fabula.lab_samples where sample_code = %L$q$, (select out->>'sample_code' from d1_try where tag = 'p7b')));
-- P8: the ricotta lot from the whey (start_byproduct_batch runs as the login)
select pg_temp.try('p8', format($q$select to_jsonb(fabula.start_byproduct_batch(%L, 40, '10000000-0000-4000-a000-00000000d103'))$q$, current_setting('d1.lot')));
reset role;
-- P9: the direct shipment (DDT, line and sale), as spedizioni
:SPED
select pg_temp.try('p9', format($q$select fabula.save_ops(jsonb_build_array(
   jsonb_build_object('table', 'shipments', 'row', jsonb_build_object('customer_id', %L, 'status', 'picked', 'driver_id', '10000000-0000-4000-a000-00000000d105')),
   jsonb_build_object('table', 'shipment_lines', 'row', jsonb_build_object('shipment_id', '$0.id', 'product_id', %L, 'lot_number', %L, 'qty', 5)),
   jsonb_build_object('table', 'stock_moves', 'row', jsonb_build_object('product_id', %L, 'lot_number', %L, 'qty', -5, 'move_type', 'sale', 'source', 'tablet'))), gen_random_uuid())$q$,
   current_setting('d1.cust'), current_setting('d1.moz'), current_setting('d1.lot'), current_setting('d1.moz'), current_setting('d1.lot')));
reset role;
-- P10: the lab result, through record_lab_result (titolare), on the sample taken in P7
:TIT
select pg_temp.try('p10', format($q$select fabula.record_lab_result(%L, 'conforme', null, 'assente in 25 g', 'RDP-D1', current_date, null, '10000000-0000-4000-a000-00000000d101')$q$,
   (select out->>'sample_code' from d1_try where tag = 'p7b')));
reset role;

select pg_temp.ck('3a the cleaning round as the tablet saves it (save_ops) is saved, «entered by» the login',
  pg_temp.st('p1') = '00000' and exists (select 1 from fabula.haccp_log where control_point_id = :'cp_clean' and corrective_action is null and result = 'ok'
                                         and entered_by_id = '10000000-0000-4000-a000-00000000d103' and logged_at > now() - interval '1 minute'), pg_temp.st('p1') || ' ' || pg_temp.msg('p1'));
select pg_temp.ck('3b a cleaning round saved offline yesterday keeps yesterday''s time (inside the 7 days)', pg_temp.st('p2') = '00000'
  and exists (select 1 from fabula.haccp_log where corrective_action = 'Non fatto: pavimento' and logged_at between now() - interval '25 hours' and now() - interval '23 hours'),
  pg_temp.st('p2') || ' ' || pg_temp.msg('p2'));
select pg_temp.ck('3c the batch start (lot, milk in the vat, raw milk out of stock, CCP 2 via log_ccp) is saved in one go',
  pg_temp.st('p3') = '00000' and :'lot' <> '' and exists (select 1 from fabula.production_batches where batch_lot = :'lot' and entered_by_id = '10000000-0000-4000-a000-00000000d103')
  and exists (select 1 from fabula.stock_moves where product_id = :'raw' and move_type = 'production_in' and qty = -100)
  and exists (select 1 from fabula.haccp_log l join fabula.production_batches b on b.id = l.batch_id where b.batch_lot = :'lot' and l.control_point_id = :'cp_past' and l.result = 'ok'),
  pg_temp.st('p3') || ' ' || pg_temp.msg('p3'));
select pg_temp.ck('3d dosing salt and re-confirming another quantity still work (the consumable correction is an allowed adjustment)',
  pg_temp.st('p4a') = '00000' and pg_temp.st('p4b') = '00000'
  and exists (select 1 from fabula.stock_moves where product_id = :'salt' and move_type = 'adjustment' and source = 'correction'),
  pg_temp.st('p4a') || '/' || pg_temp.st('p4b') || ' ' || pg_temp.msg('p4b'));
select pg_temp.ck('3e the close (lot update + production output) is saved, the recipe''s consumables are booked, and the lot with both CCPs is NOT held',
  pg_temp.st('p5a') = '00000' and pg_temp.st('p5b') = '00000'
  and (select output_kg = 21 and not food_safety_hold from fabula.production_batches where batch_lot = :'lot')
  and exists (select 1 from fabula.stock_moves where product_id = :'moz' and move_type = 'production_out' and qty = 21),
  pg_temp.st('p5a') || '/' || pg_temp.st('p5b') || ' ' || pg_temp.msg('p5b'));
select pg_temp.ck('3e2 the close booked the recipe''s ingredients and packaging (apply_batch_recipe, run as the login by the close trigger)',
  exists (select 1 from fabula.stock_moves m join fabula.production_batches b on b.id = m.batch_id where b.batch_lot = :'lot' and m.move_type = 'production_in' and m.source = 'recipe' and m.qty < 0));
select pg_temp.ck('3f a second production output beyond the kg recorded at the close is refused', pg_temp.st('p6') = '42501', pg_temp.st('p6') || ' ' || pg_temp.msg('p6'));
select pg_temp.ck('3g the pest round (record_pest_inspection) writes its register row, «entered by» the login',
  pg_temp.st('p7a') = '00000' and exists (select 1 from fabula.haccp_log l join fabula.haccp_control_points c on c.id = l.control_point_id
                                          where c.code = 'PRP-PEST' and l.entered_by_id = '10000000-0000-4000-a000-00000000d103'), pg_temp.st('p7a') || ' ' || pg_temp.msg('p7a'));
select pg_temp.ck('3h a lab sample taken (record_sample_taken) is saved «in attesa»', pg_temp.st('p7b') = '00000'
  and (select out #>> '{}' from d1_try where tag = 'p7c') = 'in_attesa',
  pg_temp.st('p7b') || ' ' || pg_temp.msg('p7b'));
select pg_temp.ck('3i the ricotta lot from the whey (start_byproduct_batch) is started, «entered by» the login',
  pg_temp.st('p8') = '00000' and exists (select 1 from fabula.production_batches where input_kind = 'whey' and entered_by_id = '10000000-0000-4000-a000-00000000d103'),
  pg_temp.st('p8') || ' ' || pg_temp.msg('p8'));
select pg_temp.ck('3j the direct shipment (DDT, line, sale −5 kg) is saved, as spedizioni', pg_temp.st('p9') = '00000'
  and exists (select 1 from fabula.stock_moves where product_id = :'moz' and move_type = 'sale' and qty = -5), pg_temp.st('p9') || ' ' || pg_temp.msg('p9'));
select pg_temp.ck('3k the lab result through record_lab_result is recorded (the database''s own function is not touched)', pg_temp.st('p10') = '00000'
  and exists (select 1 from fabula.lab_samples where sample_code = (select out->>'sample_code' from d1_try where tag = 'p7b') and outcome = 'conforme'),
  pg_temp.st('p10') || ' ' || pg_temp.msg('p10'));

-- ============================== 4. role matrix: every login, the same five writes ==============================
-- per role: m_ccp a CCP reading written directly (forged) · m_clean the cleaning round · m_adj +1000 kg adjustment · m_test a lot with source test
-- · m_start a normal lot started directly (the tablet's batch start) · m_milk a milk delivery (no receiver named, nothing forged)
create temp table d1_roles (n int primary key, role text, uid text, haccp_w boolean, prod_w boolean);
grant select on d1_roles to authenticated;
insert into d1_roles values
  (101, 'titolare', '00000000-0000-4000-a000-00000000d101', true, true), (102, 'socio', '00000000-0000-4000-a000-00000000d102', true, true),
  (103, 'produzione', '00000000-0000-4000-a000-00000000d103', true, true), (104, 'banco', '00000000-0000-4000-a000-00000000d104', true, false),
  (105, 'spedizioni', '00000000-0000-4000-a000-00000000d105', true, false), (106, 'consulente', '00000000-0000-4000-a000-00000000d106', false, false),
  (107, 'qualita', '00000000-0000-4000-a000-00000000d107', true, true), (108, 'resp_produzione', '00000000-0000-4000-a000-00000000d108', true, true),
  (109, 'amministrazione', '00000000-0000-4000-a000-00000000d109', false, false), (110, 'marketing', '00000000-0000-4000-a000-00000000d110', false, false),
  (111, 'senza staff', '00000000-0000-4000-a000-00000000d111', false, false);
\set MATRIX 'select pg_temp.try(''m_ccp_'' || current_setting(''d1.n''), format($q$insert into fabula.haccp_log (control_point_id, measured_value, result, operator, source) values (%L, 3, ''ok'', ''x'', ''tablet'') returning to_jsonb(haccp_log)$q$, current_setting(''d1.cp_cold''))), pg_temp.try(''m_clean_'' || current_setting(''d1.n''), format($q$insert into fabula.haccp_log (control_point_id, result, operator, source) values (%L, ''ok'', ''x'', ''tablet'') returning to_jsonb(haccp_log)$q$, current_setting(''d1.cp_clean''))), pg_temp.try(''m_adj_'' || current_setting(''d1.n''), format($q$insert into fabula.stock_moves (product_id, qty, move_type, source) values (%L, 1000, ''adjustment'', ''console'') returning to_jsonb(stock_moves)$q$, current_setting(''d1.moz''))), pg_temp.try(''m_test_'' || current_setting(''d1.n''), format($q$insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, started_at, source) values (%L, ''LD1T'' || %s, %L, 100, now(), ''test'') returning to_jsonb(production_batches)$q$, current_setting(''d1.d''), current_setting(''d1.n''), current_setting(''d1.moz''))), pg_temp.try(''m_start_'' || current_setting(''d1.n''), format($q$insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, started_at, source) values (%L, ''LD1S'' || %s, %L, 100, now(), ''tablet'') returning to_jsonb(production_batches)$q$, current_setting(''d1.d''), current_setting(''d1.n''), current_setting(''d1.moz''))), pg_temp.try(''m_milk_'' || current_setting(''d1.n''), format($q$insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, temperature_c, accepted, source) values (%L, (now() at time zone ''Europe/Rome'')::time, %L, ''LM-D1-X'' || %s, 100, 4, true, ''tablet'') returning to_jsonb(milk_intake)$q$, current_setting(''d1.d''), current_setting(''d1.sup''), current_setting(''d1.n'')));'
select set_config('d1.n', '101', false), set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-00000000d101","role":"authenticated"}', false); set role authenticated; :MATRIX reset role;
select set_config('d1.n', '102', false), set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-00000000d102","role":"authenticated"}', false); set role authenticated; :MATRIX reset role;
select set_config('d1.n', '103', false), set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-00000000d103","role":"authenticated"}', false); set role authenticated; :MATRIX reset role;
select set_config('d1.n', '104', false), set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-00000000d104","role":"authenticated"}', false); set role authenticated; :MATRIX reset role;
select set_config('d1.n', '105', false), set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-00000000d105","role":"authenticated"}', false); set role authenticated; :MATRIX reset role;
select set_config('d1.n', '106', false), set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-00000000d106","role":"authenticated"}', false); set role authenticated; :MATRIX reset role;
select set_config('d1.n', '107', false), set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-00000000d107","role":"authenticated"}', false); set role authenticated; :MATRIX reset role;
select set_config('d1.n', '108', false), set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-00000000d108","role":"authenticated"}', false); set role authenticated; :MATRIX reset role;
select set_config('d1.n', '109', false), set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-00000000d109","role":"authenticated"}', false); set role authenticated; :MATRIX reset role;
select set_config('d1.n', '110', false), set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-00000000d110","role":"authenticated"}', false); set role authenticated; :MATRIX reset role;
select set_config('d1.n', '111', false), set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-00000000d111","role":"authenticated"}', false); set role authenticated; :MATRIX reset role;
select set_config('request.jwt.claims', '', false);

select pg_temp.ck('4a NEGATIVE: no login of any role can write a CCP reading straight into the register (11 roles)',
  (select bool_and(pg_temp.st('m_ccp_' || n) = '42501') from d1_roles), (select string_agg(role || ':' || pg_temp.st('m_ccp_' || n), ' ') from d1_roles));
select pg_temp.ck('4b NEGATIVE: no login of any role can add +1000 kg by stock adjustment (11 roles)',
  (select bool_and(pg_temp.st('m_adj_' || n) = '42501') from d1_roles), (select string_agg(role || ':' || pg_temp.st('m_adj_' || n), ' ') from d1_roles));
select pg_temp.ck('4c NEGATIVE: no login of any role can start a lot with source «test» (11 roles)',
  (select bool_and(pg_temp.st('m_test_' || n) = '42501') from d1_roles), (select string_agg(role || ':' || pg_temp.st('m_test_' || n), ' ') from d1_roles));
select pg_temp.ck('4d POSITIVE: the cleaning round is saved for every role with HACCP level 2+ (titolare, socio, produzione, banco, spedizioni, qualita, resp_produzione)',
  (select bool_and(pg_temp.st('m_clean_' || n) = '00000') from d1_roles where haccp_w), (select string_agg(role || ':' || pg_temp.st('m_clean_' || n), ' ') from d1_roles where haccp_w));
select pg_temp.ck('4e NEGATIVE (unchanged): consulente, amministrazione, marketing and a login with no staff row still cannot write the register',
  (select bool_and(pg_temp.st('m_clean_' || n) = '42501') from d1_roles where not haccp_w), (select string_agg(role || ':' || pg_temp.st('m_clean_' || n), ' ') from d1_roles where not haccp_w));
select pg_temp.ck('4f POSITIVE: a normal lot is started for every role with production level 2+ (titolare, socio, produzione, qualita, resp_produzione)',
  (select bool_and(pg_temp.st('m_start_' || n) = '00000') from d1_roles where prod_w), (select string_agg(role || ':' || pg_temp.st('m_start_' || n), ' ') from d1_roles where prod_w));
select pg_temp.ck('4g NEGATIVE (unchanged): banco, spedizioni, consulente, amministrazione, marketing and no-staff still cannot start a lot',
  (select bool_and(pg_temp.st('m_start_' || n) = '42501') from d1_roles where not prod_w), (select string_agg(role || ':' || pg_temp.st('m_start_' || n), ' ') from d1_roles where not prod_w));
select pg_temp.ck('4i POSITIVE: a milk delivery is saved for every role with production level 2+ (titolare, socio, produzione, qualita, resp_produzione)',
  (select bool_and(pg_temp.st('m_milk_' || n) = '00000') from d1_roles where prod_w), (select string_agg(role || ':' || pg_temp.st('m_milk_' || n), ' ') from d1_roles where prod_w));
select pg_temp.ck('4j NEGATIVE (unchanged): banco, spedizioni, consulente, amministrazione, marketing and no-staff still cannot record a delivery',
  (select bool_and(pg_temp.st('m_milk_' || n) = '42501') from d1_roles where not prod_w), (select string_agg(role || ':' || pg_temp.st('m_milk_' || n), ' ') from d1_roles where not prod_w));
select pg_temp.ck('4h every cleaning row a login saved in the matrix is «entered by» that login''s own staff id (7 roles)',
  (select bool_and((select out->>'entered_by_id' from d1_try where tag = 'm_clean_' || n) = '10000000-0000-4000-a000-00000000d' || n) from d1_roles where haccp_w),
  (select string_agg(role || ':' || coalesce((select right(out->>'entered_by_id', 4) from d1_try where tag = 'm_clean_' || n), '-'), ' ') from d1_roles where haccp_w));

-- ============================== 5. the database's own writers are not touched ==============================
-- as the owner (cron, the bots' stand-ins, log_ccp/receive/post_stock_count all write this way) and as the service role (edge functions)
select pg_temp.try('o1', format($q$insert into fabula.haccp_log (control_point_id, measured_value, result, operator, source) values (%L, 3, 'ok', 'sensor', 'sensor') returning to_jsonb(haccp_log)$q$, :'cp_cold'));
select pg_temp.try('o2', format($q$insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, started_at, source) values (%L, 'LD1SIM', %L, 100, now(), 'simulation') returning to_jsonb(production_batches)$q$, :'d', :'moz'));
select pg_temp.try('o3', format($q$insert into fabula.stock_moves (product_id, lot_number, qty, move_type, source, reason) values (%L, %L, -1, 'adjustment', 'inventario', 'conta') returning to_jsonb(stock_moves)$q$, :'moz', :'lot'));
select pg_temp.try('o4', $q$select to_jsonb(fabula.rollup_sensor_haccp())$q$);
set role service_role;
select pg_temp.try('s1', format($q$insert into fabula.stock_moves (product_id, lot_number, qty, move_type, source, reason) values (%L, %L, -1, 'adjustment', 'shopify', 'test') returning to_jsonb(stock_moves)$q$, :'moz', :'lot'));
reset role;
select pg_temp.ck('5a the owner writes sensor readings, simulated lots and stock adjustments exactly as before (rollup_sensor_haccp too)',
  pg_temp.st('o1') = '00000' and pg_temp.st('o2') = '00000' and pg_temp.st('o3') = '00000' and pg_temp.st('o4') = '00000',
  pg_temp.st('o1') || '/' || pg_temp.st('o2') || '/' || pg_temp.st('o3') || '/' || pg_temp.st('o4'));
select pg_temp.ck('5b the service role (edge functions) writes a stock adjustment exactly as before', pg_temp.st('s1') = '00000', pg_temp.st('s1') || ' ' || pg_temp.msg('s1'));
select pg_temp.ck('5c an owner row keeps the entered_by it was given (the guard only normalises logins)',
  (select out->>'entered_by_id' from d1_try where tag = 'o1') is null);

-- ============================== 6. a refused step leaves the whole save unwritten ==============================
:PROD
select pg_temp.try('x1', format($q$select fabula.save_ops(jsonb_build_array(
   jsonb_build_object('table', 'haccp_log', 'row', jsonb_build_object('control_point_id', %L, 'result', 'ok', 'corrective_action', 'atomic-d1', 'operator', 'Produzione D1', 'source', 'tablet')),
   jsonb_build_object('table', 'stock_moves', 'row', jsonb_build_object('product_id', %L, 'qty', 1000, 'move_type', 'adjustment', 'source', 'tablet'))), gen_random_uuid())$q$,
   current_setting('d1.cp_clean'), current_setting('d1.moz')));
reset role;
select pg_temp.ck('6a a save whose second step is refused writes nothing (the cleaning row of step 1 is not kept) and says which step, in Italian',
  pg_temp.st('x1') = '42501' and not exists (select 1 from fabula.haccp_log where corrective_action = 'atomic-d1') and pg_temp.msg('x1') like 'Passo 2 di 2 (magazzino)%',
  pg_temp.st('x1') || ' ' || pg_temp.msg('x1'));

-- ============================== 7. milk intake ==============================
-- the tablet's delivery as it sends it (save_ops: the delivery, then its two CCP 1 checks through log_milk_check), and the forged variants
\set MILK 'jsonb_build_object(''table'', ''milk_intake'', ''row'', jsonb_build_object(''intake_date'', current_setting(''d1.d''), ''intake_time'', to_char(now() at time zone ''Europe/Rome'', ''HH24:MI:SS''), ''supplier_id'', current_setting(''d1.sup''), ''qty_kg'', 300, ''temperature_c'', 4, ''accepted'', true, ''source'', ''tablet'', ''received_by'', ''Produzione D1'', ''received_by_id'', ''10000000-0000-4000-a000-00000000d103''))'
:PROD
-- MI1: the normal delivery with its two checks (temperature and antibiotics), in one save
select pg_temp.try('mi1', format($q$select fabula.save_ops(jsonb_build_array(
   jsonb_set(%s, '{row,milk_lot}', '"LM-D1-M1"'),
   jsonb_build_object('rpc', 'log_milk_check', 'args', jsonb_build_object('p_milk_intake_id', '$0.id', 'p_cp_code', 'CCP-MILK-TEMP', 'p_value', 4, 'p_staff_id', '10000000-0000-4000-a000-00000000d103', 'p_source', 'tablet', 'p_equipment_code', 'TERM-01')),
   jsonb_build_object('rpc', 'log_milk_check', 'args', jsonb_build_object('p_milk_intake_id', '$0.id', 'p_cp_code', 'CCP-MILK-ABX', 'p_value', 0, 'p_staff_id', '10000000-0000-4000-a000-00000000d103', 'p_source', 'tablet'))), gen_random_uuid())$q$, :'MILK'));
-- MI2: the shared floor tablet: received by another person on the list (Resp Produzione D1), saved by the produzione login
select pg_temp.try('mi2', format($q$select fabula.save_ops(jsonb_build_array(jsonb_set(jsonb_set(jsonb_set(%s, '{row,milk_lot}', '"LM-D1-M2"'), '{row,received_by}', '"Resp Produzione D1"'), '{row,received_by_id}', '"10000000-0000-4000-a000-00000000d108"')), gen_random_uuid())$q$, :'MILK'));
-- MI2b: received by a person on the list given by id only (no name): nothing is forged, it is saved
select pg_temp.try('mi2b', format($q$select fabula.save_ops(jsonb_build_array(jsonb_set(jsonb_set(%s, '{row,milk_lot}', '"LM-D1-M2B"'), '{row,received_by}', 'null')), gen_random_uuid())$q$, :'MILK'));
-- MI3: a delivery copied from the paper sheet 3 days later, signature unreadable (the paper option «firma non leggibile»)
select pg_temp.try('mi3', format($q$select fabula.save_ops(jsonb_build_array(jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(%s, '{row,milk_lot}', '"LM-D1-M3"'),
   '{row,source}', '"paper"'), '{row,intake_date}', to_jsonb((current_setting('d1.d')::date - 3)::text)), '{row,intake_time}', '"06:30:00"'), '{row,received_by}', '"firma non leggibile"'), '{row,received_by_id}', 'null')), gen_random_uuid())$q$, :'MILK'));
-- MI4–MI14 go through save_ops as one step each (the tablet's own path; a direct API insert meets the same trigger)
-- MI4: «entered by» the titolare
select pg_temp.try('mi4', format($q$select fabula.save_ops(jsonb_build_array(jsonb_set(jsonb_set(%s, '{row,milk_lot}', '"LM-D1-M4"'), '{row,entered_by_id}', '"10000000-0000-4000-a000-00000000d101"')), gen_random_uuid())$q$, :'MILK'));
-- MI5–MI7: who received it: the titolare's id with another name; a person no longer active; a free-text name with no person
select pg_temp.try('mi5', format($q$select fabula.save_ops(jsonb_build_array(jsonb_set(jsonb_set(jsonb_set(%s, '{row,milk_lot}', '"LM-D1-M5"'), '{row,received_by_id}', '"10000000-0000-4000-a000-00000000d101"'), '{row,received_by}', '"Mario Rossi"')), gen_random_uuid())$q$, :'MILK'));
select pg_temp.try('mi6', format($q$select fabula.save_ops(jsonb_build_array(jsonb_set(jsonb_set(jsonb_set(%s, '{row,milk_lot}', '"LM-D1-M6"'), '{row,received_by_id}', '"10000000-0000-4000-a000-00000000d1ff"'), '{row,received_by}', '"Ex Dipendente D1"')), gen_random_uuid())$q$, :'MILK'));
select pg_temp.try('mi7', format($q$select fabula.save_ops(jsonb_build_array(jsonb_set(jsonb_set(jsonb_set(%s, '{row,milk_lot}', '"LM-D1-M7"'), '{row,received_by_id}', 'null'), '{row,received_by}', '"Mario Rossi"')), gen_random_uuid())$q$, :'MILK'));
-- MI8–MI10: dates: 30 days back from the tablet; tomorrow; a paper copy 8 days back
select pg_temp.try('mi8', format($q$select fabula.save_ops(jsonb_build_array(jsonb_set(jsonb_set(%s, '{row,milk_lot}', '"LM-D1-M8"'), '{row,intake_date}', to_jsonb((current_setting('d1.d')::date - 30)::text))), gen_random_uuid())$q$, :'MILK'));
select pg_temp.try('mi9', format($q$select fabula.save_ops(jsonb_build_array(jsonb_set(jsonb_set(%s, '{row,milk_lot}', '"LM-D1-M9"'), '{row,intake_date}', to_jsonb((current_setting('d1.d')::date + 1)::text))), gen_random_uuid())$q$, :'MILK'));
select pg_temp.try('mi10', format($q$select fabula.save_ops(jsonb_build_array(jsonb_set(jsonb_set(jsonb_set(%s, '{row,milk_lot}', '"LM-D1-M10"'), '{row,source}', '"paper"'), '{row,intake_date}', to_jsonb((current_setting('d1.d')::date - 8)::text))), gen_random_uuid())$q$, :'MILK'));
-- MI9b–MI9f: the device-clock tolerance (a live «tablet» entry may be up to 15 minutes ahead; any other source 5) and the 7-day window
select pg_temp.try('mi9b', format($q$select fabula.save_ops(jsonb_build_array(jsonb_set(jsonb_set(jsonb_set(%s, '{row,milk_lot}', '"LM-D1-M9B"'),
   '{row,intake_date}', to_jsonb(((now() at time zone 'Europe/Rome') + interval '14 minutes')::date::text)), '{row,intake_time}', to_jsonb(to_char((now() at time zone 'Europe/Rome') + interval '14 minutes', 'HH24:MI:SS')))), gen_random_uuid())$q$, :'MILK'));
select pg_temp.try('mi9c', format($q$select fabula.save_ops(jsonb_build_array(jsonb_set(jsonb_set(jsonb_set(%s, '{row,milk_lot}', '"LM-D1-M9C"'),
   '{row,intake_date}', to_jsonb(((now() at time zone 'Europe/Rome') + interval '16 minutes')::date::text)), '{row,intake_time}', to_jsonb(to_char((now() at time zone 'Europe/Rome') + interval '16 minutes', 'HH24:MI:SS')))), gen_random_uuid())$q$, :'MILK'));
select pg_temp.try('mi9d', format($q$select fabula.save_ops(jsonb_build_array(jsonb_set(jsonb_set(jsonb_set(jsonb_set(%s, '{row,milk_lot}', '"LM-D1-M9D"'),
   '{row,intake_date}', to_jsonb(((now() at time zone 'Europe/Rome') + interval '8 minutes')::date::text)), '{row,intake_time}', to_jsonb(to_char((now() at time zone 'Europe/Rome') + interval '8 minutes', 'HH24:MI:SS'))), '{row,source}', '"paper"')), gen_random_uuid())$q$, :'MILK'));
select pg_temp.try('mi9e', format($q$select fabula.save_ops(jsonb_build_array(jsonb_set(jsonb_set(%s, '{row,milk_lot}', '"LM-D1-M9E"'), '{row,intake_date}', to_jsonb((current_setting('d1.d')::date - 8)::text))), gen_random_uuid())$q$, :'MILK'));
select pg_temp.try('mi9f', format($q$select fabula.save_ops(jsonb_build_array(jsonb_set(jsonb_set(%s, '{row,milk_lot}', '"LM-D1-M9F"'), '{row,intake_date}', to_jsonb((current_setting('d1.d')::date - 7)::text))), gen_random_uuid())$q$, :'MILK'));
-- MI11–MI13: source test / simulation; no temperature (the CCP 1a acceptance rule would never run)
select pg_temp.try('mi11', format($q$select fabula.save_ops(jsonb_build_array(jsonb_set(jsonb_set(%s, '{row,milk_lot}', '"LM-D1-M11"'), '{row,source}', '"test"')), gen_random_uuid())$q$, :'MILK'));
select pg_temp.try('mi12', format($q$select fabula.save_ops(jsonb_build_array(jsonb_set(jsonb_set(%s, '{row,milk_lot}', '"LM-D1-M12"'), '{row,source}', '"simulation"')), gen_random_uuid())$q$, :'MILK'));
select pg_temp.try('mi13', format($q$select fabula.save_ops(jsonb_build_array(jsonb_set(jsonb_set(%s, '{row,milk_lot}', '"LM-D1-M13"'), '{row,temperature_c}', 'null')), gen_random_uuid())$q$, :'MILK'));
-- MI14: 9 °C sent as accepted: the CCP 1a rule (trg_milk_accept_decide) still rejects it
select pg_temp.try('mi14', format($q$select fabula.save_ops(jsonb_build_array(jsonb_set(jsonb_set(%s, '{row,milk_lot}', '"LM-D1-M14"'), '{row,temperature_c}', '9')), gen_random_uuid())$q$, :'MILK'));
reset role;

select pg_temp.ck('7a the delivery as the tablet saves it (with its two CCP 1 checks) is saved, accepted, «entered by» the login',
  pg_temp.st('mi1') = '00000' and exists (select 1 from fabula.milk_intake where milk_lot = 'LM-D1-M1' and accepted and entered_by_id = '10000000-0000-4000-a000-00000000d103')
  and (select count(*) from fabula.haccp_log h join fabula.milk_intake m on m.id = h.milk_intake_id where m.milk_lot = 'LM-D1-M1') = 2, pg_temp.st('mi1') || ' ' || pg_temp.msg('mi1'));
select pg_temp.ck('7b the shared floor tablet still works: received by another person on the list, «entered by» the login',
  pg_temp.st('mi2') = '00000' and exists (select 1 from fabula.milk_intake where milk_lot = 'LM-D1-M2' and received_by_id = '10000000-0000-4000-a000-00000000d108'
                                          and received_by = 'Resp Produzione D1' and entered_by_id = '10000000-0000-4000-a000-00000000d103'), pg_temp.st('mi2') || ' ' || pg_temp.msg('mi2'));
select pg_temp.ck('7b2 received by a person on the list given by id only (no name) is saved', pg_temp.st('mi2b') = '00000', pg_temp.st('mi2b') || ' ' || pg_temp.msg('mi2b'));
select pg_temp.ck('7c a delivery copied from paper 3 days later keeps its own date, with «firma non leggibile»',
  pg_temp.st('mi3') = '00000' and exists (select 1 from fabula.milk_intake where milk_lot = 'LM-D1-M3' and intake_date = :'d'::date - 3 and source = 'paper' and received_by = 'firma non leggibile'),
  pg_temp.st('mi3') || ' ' || pg_temp.msg('mi3'));
select pg_temp.ck('7d a delivery «entered by» the titolare is saved with the login''s own staff id',
  pg_temp.st('mi4') = '00000' and (select out->0->>'entered_by_id' from d1_try where tag = 'mi4') = '10000000-0000-4000-a000-00000000d103',
  pg_temp.st('mi4') || ' entered_by ' || coalesce((select out->0->>'entered_by_id' from d1_try where tag = 'mi4'), '-'));
select pg_temp.ck('7e received by the titolare''s id under another name («Mario Rossi») is refused', pg_temp.st('mi5') = '42501'
  and not exists (select 1 from fabula.milk_intake where milk_lot = 'LM-D1-M5'), pg_temp.st('mi5') || ' ' || pg_temp.msg('mi5'));
select pg_temp.ck('7f received by a person no longer active is refused', pg_temp.st('mi6') = '42501', pg_temp.st('mi6') || ' ' || pg_temp.msg('mi6'));
select pg_temp.ck('7g received by a free-text name that is no one on the list is refused', pg_temp.st('mi7') = '42501', pg_temp.st('mi7') || ' ' || pg_temp.msg('mi7'));
select pg_temp.ck('7h a delivery dated 30 days back from the tablet is refused (not moved)', pg_temp.st('mi8') = '22023'
  and not exists (select 1 from fabula.milk_intake where milk_lot = 'LM-D1-M8'), pg_temp.st('mi8') || ' ' || pg_temp.msg('mi8'));
select pg_temp.ck('7i a delivery dated tomorrow is refused', pg_temp.st('mi9') = '22023', pg_temp.st('mi9') || ' ' || pg_temp.msg('mi9'));
select pg_temp.ck('7i2 a live tablet entry 14 minutes ahead (tablet clock a little fast) is saved', pg_temp.st('mi9b') = '00000', pg_temp.st('mi9b') || ' ' || pg_temp.msg('mi9b'));
select pg_temp.ck('7i3 a live tablet entry 16 minutes ahead is refused (the tolerance is 15 minutes)', pg_temp.st('mi9c') = '22023', pg_temp.st('mi9c') || ' ' || pg_temp.msg('mi9c'));
select pg_temp.ck('7i4 a paper copy dated 8 minutes ahead is refused (paper keeps 5 minutes)', pg_temp.st('mi9d') = '22023', pg_temp.st('mi9d') || ' ' || pg_temp.msg('mi9d'));
select pg_temp.ck('7i5 a live tablet entry dated 8 days back (more than 7) is refused', pg_temp.st('mi9e') = '22023', pg_temp.st('mi9e') || ' ' || pg_temp.msg('mi9e'));
select pg_temp.ck('7i6 a live tablet entry dated exactly 7 days back is still inside the window (boundary)', pg_temp.st('mi9f') = '00000', pg_temp.st('mi9f') || ' ' || pg_temp.msg('mi9f'));
select pg_temp.ck('7j (unchanged) a paper copy 8 days back is refused', pg_temp.st('mi10') = '22023', pg_temp.st('mi10') || ' ' || pg_temp.msg('mi10'));
select pg_temp.ck('7k a delivery with source «test» or «simulation» is refused', pg_temp.st('mi11') = '42501' and pg_temp.st('mi12') = '42501',
  pg_temp.st('mi11') || '/' || pg_temp.st('mi12') || ' ' || pg_temp.msg('mi11'));
select pg_temp.ck('7l a delivery «accepted» with no temperature is refused (the CCP 1a rule needs it)', pg_temp.st('mi13') = '23502'
  and not exists (select 1 from fabula.milk_intake where milk_lot = 'LM-D1-M13'), pg_temp.st('mi13') || ' ' || pg_temp.msg('mi13'));
select pg_temp.ck('7m (unchanged) 9 °C sent as accepted is saved REJECTED by the CCP 1a rule', pg_temp.st('mi14') = '00000'
  and (select not accepted from fabula.milk_intake where milk_lot = 'LM-D1-M14'), pg_temp.st('mi14') || ' ' || pg_temp.msg('mi14'));

-- ============================== 8. delayed entries and corrections keep their controlled routes ==============================
:PROD
-- C1/C2: the paper copy of a reading (log_ccp, SECURITY DEFINER): 3 days back is accepted, 8 days back is refused for everyone
select pg_temp.try('c1', $q$select fabula.log_ccp(p_cp_code => 'CCP-COLD-1', p_value => 3, p_logged_at => now() - interval '3 days', p_staff_id => '10000000-0000-4000-a000-00000000d103', p_source => 'paper', p_written_by => 'Produzione D1')$q$);
select pg_temp.try('c2', $q$select fabula.log_ccp(p_cp_code => 'CCP-COLD-1', p_value => 3, p_logged_at => now() - interval '8 days', p_staff_id => '10000000-0000-4000-a000-00000000d103', p_source => 'paper', p_written_by => 'Produzione D1')$q$);
reset role;
:BANCO
-- C3: an ordinary login (banco, HACCP 2) cannot correct someone else's reading
select pg_temp.try('c3', format($q$select fabula.correct_record('haccp_log', %L, '{"measured_value": 3.4}', 'prova banco', '10000000-0000-4000-a000-00000000d104')$q$, (select out->>'haccp_log_id' from d1_try where tag = 'c1')));
reset role;
:TIT
-- C4: the HACCP manager corrects it, with a reason (the original is kept); C5: no route rewrites a timestamp, not even for the manager
select pg_temp.try('c4', format($q$select fabula.correct_record('haccp_log', %L, '{"measured_value": 3.5}', 'errore di battitura', '10000000-0000-4000-a000-00000000d101')$q$, (select out->>'haccp_log_id' from d1_try where tag = 'c1')));
select pg_temp.try('c5', format($q$select fabula.correct_record('haccp_log', %L, jsonb_build_object('logged_at', now() - interval '20 days'), 'sposto la data', '10000000-0000-4000-a000-00000000d101')$q$, (select out->>'haccp_log_id' from d1_try where tag = 'c1')));
-- C6: the manager corrects a delivery's kg: the stock follows through correct_record's own adjustment (the stock guard does not touch it)
select pg_temp.try('c6', format($q$select fabula.correct_record('milk_intake', %L, '{"qty_kg": 290}', 'pesata rifatta', '10000000-0000-4000-a000-00000000d101')$q$, (select id from fabula.milk_intake where milk_lot = 'LM-D1-M1')));
reset role;
select pg_temp.ck('8a a reading copied from paper 3 days later is saved through log_ccp, with the sheet''s time', pg_temp.st('c1') = '00000'
  and exists (select 1 from fabula.haccp_log where id = ((select out->>'haccp_log_id' from d1_try where tag = 'c1'))::uuid and source = 'paper' and logged_at < now() - interval '71 hours'),
  pg_temp.st('c1') || ' ' || pg_temp.msg('c1'));
select pg_temp.ck('8b (unchanged) a paper copy 8 days back is refused, for everyone', pg_temp.st('c2') = '22023', pg_temp.st('c2') || ' ' || pg_temp.msg('c2'));
select pg_temp.ck('8c an ordinary login (banco) cannot correct someone else''s reading', pg_temp.st('c3') = '42501', pg_temp.st('c3') || ' ' || pg_temp.msg('c3'));
select pg_temp.ck('8d the HACCP manager''s correction with a reason still works (correct_record)', pg_temp.st('c4') = '00000'
  and (select measured_value from fabula.haccp_log where id = ((select out->>'haccp_log_id' from d1_try where tag = 'c1'))::uuid) = 3.5, pg_temp.st('c4') || ' ' || pg_temp.msg('c4'));
select pg_temp.ck('8e no route rewrites a timestamp, not even the manager''s correction', pg_temp.st('c5') = '22023', pg_temp.st('c5') || ' ' || pg_temp.msg('c5'));
select pg_temp.ck('8f the manager''s correction of a delivery''s kg works, and its stock adjustment is written', pg_temp.st('c6') = '00000'
  and exists (select 1 from fabula.stock_moves where product_id = :'raw' and lot_number = 'LM-D1-M1' and move_type = 'adjustment' and qty = -10),
  pg_temp.st('c6') || ' ' || pg_temp.msg('c6'));
