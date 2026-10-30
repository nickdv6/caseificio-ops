-- v0.96 audit Critical items (A-04, A-03, D-02, D-21; A-01, E-01 and FARM-02 further down) · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh c_test
--   su postgres -c "psql -d c_test -f tools/go-live/drill/prod-test/test_audit_critical.sql" | grep -E "PASS|FAIL"
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as
$$ begin execute p_sql; return ''; exception when others then return sqlerrm; end $$;
create or replace function pg_temp.as_user(p_sub text) returns void language sql as
$$ select set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_sub), false) $$;
select id moz from fabula.products where sku = 'MOZ-DOP-KG' \gset
select id raw from fabula.products where sku = 'RAW-MILK' \gset
insert into fabula.staff (id, full_name, role, app_role, active, auth_user_id, badge_code) values
  ('10000000-0000-4000-a000-0000000096a1', 'Titolare C', 'owner', 'titolare', true, '00000000-0000-4000-a000-0000000096a1', 'STAFF:TTTTTTTTT2'),
  ('10000000-0000-4000-a000-0000000096a2', 'Casaro C', 'casaro', 'produzione', true, '00000000-0000-4000-a000-0000000096a2', 'STAFF:CCCCCCCCC2'),
  ('10000000-0000-4000-a000-0000000096a3', 'Banco C', 'commesso', 'banco', true, '00000000-0000-4000-a000-0000000096a3', 'STAFF:BBBBBBBBB2')
on conflict do nothing;
insert into fabula.parties (id, type, legal_name, is_milk_supplier, active) values ('50000000-0000-4000-a000-0000000096f1', 'supplier', 'Masseria C', true, true) on conflict do nothing;
update fabula.settings set value = '0123456789abcdef0123456789abcdef' where key = 'milk.farm_token';
insert into fabula.milk_shipments (id, shipped_at, ship_date, kg, milk_lot, status) values ('60000000-0000-4000-a000-0000000096c1', now() - interval '2 hours', current_date, 1000, 'MC96-1', 'shipped');
insert into fabula.milk_intake (id, intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source, shipment_id)
-- v1.20 (MILK-1): deliveries that go into a vat are dated with the Rome day, as the tablet does (current_date is the server's UTC day:
-- between 22:00/23:00 and 24:00 UTC it is the day before Rome's, and the vat started now() would be on another day than its milk)
values ('70000000-0000-4000-a000-0000000096d1', (now() at time zone 'Europe/Rome')::date, '06:30', '50000000-0000-4000-a000-0000000096f1', 'x', 1, true, 4, 'tablet', '60000000-0000-4000-a000-0000000096c1');
insert into fabula.production_batches (id, batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, output_kg, finished_at, source) values
  ('80000000-0000-4000-a000-0000000096b1', current_date, 'LC96-A', :'moz', 400, 'milk',
   greatest(now() - interval '1 hour', ((now() at time zone 'Europe/Rome')::date)::timestamp at time zone 'Europe/Rome'), 120, now(), 'tablet');   -- v1.20: an hour ago, but on MC96-1's (Rome) day
insert into fabula.batch_milk_inputs (batch_id, milk_intake_id, qty_kg) values ('80000000-0000-4000-a000-0000000096b1', '70000000-0000-4000-a000-0000000096d1', 400);
insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, input_kind, parent_batch_id, started_at, source)
select current_date, 'RC96-A', byproduct_product_id, 300, 'whey', '80000000-0000-4000-a000-0000000096b1', now(), 'tablet' from fabula.products where id = :'moz';

-- A-04 · a positive antibiotic test from the 🛡 menu rejects THAT delivery and holds what was made from it
select pg_temp.as_user('00000000-0000-4000-a000-0000000096a3');
set role authenticated;
select fabula.log_milk_check('70000000-0000-4000-a000-0000000096d1', 'CCP-MILK-ABX', 1, '10000000-0000-4000-a000-0000000096a3') a1 \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('A-04 Banco records a positive retest: the delivery is rejected with the reason',
  (select accepted is false and rejection_reason like '%test antibiotici POSITIVO (ricontrollo)%' from fabula.milk_intake where id = '70000000-0000-4000-a000-0000000096d1'), :'a1');
select pg_temp.ck('A-04 …the farm load shows rejected', (select status = 'rejected' from fabula.milk_shipments where id = '60000000-0000-4000-a000-0000000096c1'));
select pg_temp.ck('A-04 …the mozzarella and the ricotta made from it are held',
  (select bool_and(food_safety_hold) and count(*) = 2 from fabula.production_batches where batch_lot in ('LC96-A', 'RC96-A'))
  and (:'a1'::jsonb -> 'lots_held') @> '["LC96-A","RC96-A"]', :'a1');
select pg_temp.ck('A-04 …the raw milk left is written off', (select coalesce(sum(qty), 0) from fabula.stock_moves where product_id = :'raw' and lot_number = 'MC96-1') = 0,
  (select string_agg(move_type || ' ' || qty, ', ') from fabula.stock_moves where product_id = :'raw' and lot_number = 'MC96-1'));
select pg_temp.ck('A-04 …the check is linked to the delivery and the office gets an alert',
  exists (select 1 from fabula.haccp_log where milk_intake_id = '70000000-0000-4000-a000-0000000096d1' and measured_value = 1)
  and exists (select 1 from fabula.bot_messages where agent = 'sicurezza' and severity = 'alert' and title like 'Latte MC96-1 respinto%' and body like '%LC96-A, RC96-A%'));   -- v1.00: «Sicurezza alimentare»
select pg_temp.err($q$insert into fabula.production_batches (id, batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, source) values ('80000000-0000-4000-a000-0000000096b9', current_date, 'LC96-Z', (select id from fabula.products where sku = 'MOZ-DOP-KG'), 100, 'milk', now(), 'tablet');
  insert into fabula.batch_milk_inputs (batch_id, milk_intake_id, qty_kg) values ('80000000-0000-4000-a000-0000000096b9', '70000000-0000-4000-a000-0000000096d1', 100)$q$) e_vat \gset
select pg_temp.ck('A-04 …and the rejected milk cannot start a new vat', :'e_vat' <> '', :'e_vat');
-- v1.20: the Rome day of MC96-1 (a comment after \gset would be read as its prefix)
select (fabula.haccp_register('MOD-01', (now() at time zone 'Europe/Rome')::date, (now() at time zone 'Europe/Rome')::date) -> 'rows') mr \gset
select pg_temp.ck('A-04 the milk register shows the positive linked test', exists (select 1 from jsonb_array_elements(:'mr'::jsonb) r where r ->> 'lotto' = 'MC96-1' and r ->> 'abx' = 'POSITIVO' and r ->> 'accettato' like 'NO%'), :'mr');
select pg_temp.err($q$select fabula.log_milk_check('70000000-0000-4000-a000-0000000096d1', 'CCP-STRETCH', 60)$q$) e_wrong \gset
select pg_temp.ck('A-04 only milk checks go through it', :'e_wrong' like 'Questo controllo non è del latte%', :'e_wrong');
select pg_temp.ck('A-04 the offline queue may call it', pg_get_functiondef((select p.oid from pg_proc p where p.proname = 'save_ops' and p.pronamespace = 'fabula'::regnamespace order by p.pronargs desc limit 1)) like '%''log_milk_check''%');

-- A-03 · a lot closed without its CCPs is held, not just reported
insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, source) values (current_date, 'LC96-B', :'moz', 200, 'milk', now(), 'tablet');
update fabula.production_batches set output_kg = 60, finished_at = now() where batch_lot = 'LC96-B';
-- v1.21: CCP 2 a tino also needs its holding minutes, listed last (classification A, approval pending)
select pg_temp.ck('A-03 closing without CCP 2 and CCP 3 holds the lot', (select food_safety_hold and hold_reason like 'CCP mancante alla chiusura: CCP-PAST, CCP-STRETCH, CCP-PAST-HOLD' from fabula.production_batches where batch_lot = 'LC96-B'),
  (select hold_reason from fabula.production_batches where batch_lot = 'LC96-B'));
select pg_temp.ck('A-03 …and the message says it is blocked', exists (select 1 from fabula.bot_messages where title like 'Lotto LC96-B chiuso senza%' and body like '%Il lotto è BLOCCATO%'));

-- D-02 · records are not edited or deleted from the app
insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, source) values (current_date, 'LC96-C', :'moz', 200, 'milk', now(), 'tablet');
select pg_temp.as_user('00000000-0000-4000-a000-0000000096a2');
set role authenticated;
select (fabula.log_ccp(p_cp_code => 'CCP-STRETCH', p_value => 25, p_batch_lot => 'LC96-C', p_staff_id => '10000000-0000-4000-a000-0000000096a2')) ->> 'haccp_log_id' lg \gset
select pg_temp.err(format($q$update fabula.haccp_log set measured_value = 62 where id = %L$q$, :'lg')) e_upd \gset
select pg_temp.err(format($q$delete from fabula.haccp_log where id = %L$q$, :'lg')) e_del \gset
select pg_temp.err($q$update fabula.milk_intake set accepted = true where id = '70000000-0000-4000-a000-0000000096d1'$q$) e_mi \gset
select pg_temp.err($q$delete from fabula.stock_moves where lot_number = 'MC96-1'$q$) e_sm \gset
select pg_temp.err($q$select fabula.save_ops('[{"table":"haccp_log","update":{"id":"00000000-0000-0000-0000-000000000000"},"row":{"measured_value":1}}]'::jsonb)$q$) e_so \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('D-02 a CCP reading cannot be edited from the app', :'e_upd' like 'Le registrazioni HACCP e di tracciabilità non si modificano%', :'e_upd');
select pg_temp.ck('D-02 …nor deleted', :'e_del' like 'Le registrazioni HACCP e di tracciabilità non si cancellano%', :'e_del');
select pg_temp.ck('D-02 a rejected delivery cannot be turned back to accepted (antibiotic-positive milk stays out)', :'e_mi' like 'Le registrazioni%', :'e_mi');
select pg_temp.ck('D-02 stock moves cannot be deleted', :'e_sm' like 'Le registrazioni%', :'e_sm');
select pg_temp.ck('D-02 the tablet''s save cannot update a record table', :'e_so' like '%non si modificano: usa «Correggi»%', :'e_so');
-- the casaro typed 25 for 52 (digits swapped) and corrects his own typo within 15 minutes; the original stays, the NC/hold rules follow the corrected value
select (select count(*) from fabula.non_conformities where haccp_log_id = :'lg'::uuid) nc0 \gset
select pg_temp.as_user('00000000-0000-4000-a000-0000000096a2');
set role authenticated;
select pg_temp.err(format($q$select fabula.correct_record('haccp_log', %L, '{"measured_value": 62}', '')$q$, :'lg')) e_nor \gset
select fabula.correct_record('haccp_log', :'lg', '{"measured_value": 62}', 'errore di battitura', '10000000-0000-4000-a000-0000000096a2') c1 \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('D-02 a correction needs a reason', :'e_nor' like 'Scrivi il motivo%', :'e_nor');
select pg_temp.ck('D-02 own correction within 15 min: value and result updated, original kept in the note',
  (select measured_value = 62 and result = 'ok' and correction_note like 'corretto il % da Casaro C (prima 25): errore di battitura' from fabula.haccp_log where id = :'lg'::uuid), :'c1');
select pg_temp.ck('D-02 …the NC opened by 25 °C stays open with a note to evaluate it',
  (select count(*) = :nc0 and bool_and(corrective_action like '%valore corretto da 25 a 62%valutare la chiusura%') from fabula.non_conformities where haccp_log_id = :'lg'::uuid and status = 'open'));
select pg_temp.ck('D-02 …the correction is logged with old and new value',
  exists (select 1 from fabula.record_corrections where table_name = 'haccp_log' and row_id = :'lg'::uuid and changes -> 'measured_value' = '[25.00, 62]'::jsonb and corrected_by = 'Casaro C')
  and exists (select 1 from fabula.audit_log where table_name = 'haccp_log' and row_key = :'lg'));
select (fabula.haccp_register((select form_code from fabula.haccp_control_points where code = 'CCP-STRETCH'), current_date, current_date) -> 'rows') cr \gset
select pg_temp.ck('D-02 …and the batch register prints it next to CCP 3', exists (select 1 from jsonb_array_elements(:'cr'::jsonb) r where r ->> 'lotto' = 'LC96-C' and r ->> 'ccp3' like '62 · CORREZIONE: corretto il%errore di battitura%'), left(:'cr', 300));
-- someone else's record, or later than 15 minutes: only the HACCP manager
select pg_temp.as_user('00000000-0000-4000-a000-0000000096a3');
set role authenticated;
select pg_temp.err(format($q$select fabula.correct_record('haccp_log', %L, '{"measured_value": 63}', 'prova', '10000000-0000-4000-a000-0000000096a3')$q$, :'lg')) e_other \gset
reset role;
select pg_temp.as_user('00000000-0000-4000-a000-0000000096a1');
set role authenticated;
select pg_temp.err(format($q$select fabula.correct_record('haccp_log', %L, '{"measured_value": 50}', 'letto male sul termometro')$q$, :'lg')) e_mgr \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('D-02 Banco cannot correct the casaro''s reading', :'e_other' like 'Permesso negato%', :'e_other');
select pg_temp.ck('D-02 the manager can; a corrected value now out of limit opens the NC and holds the lot',
  :'e_mgr' = '' and (select result = 'non_conformity' from fabula.haccp_log where id = :'lg'::uuid)
  and (select food_safety_hold from fabula.production_batches where batch_lot = 'LC96-C'), :'e_mgr');
-- D-21 · a closed batch is not closed twice
select pg_temp.as_user('00000000-0000-4000-a000-0000000096a2');
set role authenticated;
select pg_temp.err($q$update fabula.production_batches set output_kg = 999 where batch_lot = 'LC96-A'$q$) e_twice \gset
select pg_temp.err($q$update fabula.production_batches set whey_kg = 300 where batch_lot = 'LC96-A'$q$) e_whey \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('D-21 a second close of a lot is refused with when and how many kg', :'e_twice' like 'Il lotto LC96-A è già stato chiuso alle % con 120 kg%', :'e_twice');
select pg_temp.ck('D-21 …but the whey for a ricotta started later can still be recorded', :'e_whey' = '', :'e_whey');
select pg_temp.err($q$insert into fabula.stock_moves (product_id, lot_number, qty, move_type, batch_id, source) values ((select id from fabula.products where sku = 'MOZ-DOP-KG'), 'LC96-A', 5, 'production_out', '80000000-0000-4000-a000-0000000096b1', 'tablet');
  insert into fabula.stock_moves (product_id, lot_number, qty, move_type, batch_id, source) values ((select id from fabula.products where sku = 'MOZ-DOP-KG'), 'LC96-A', 5, 'production_out', '80000000-0000-4000-a000-0000000096b1', 'tablet')$q$) e_out \gset
select pg_temp.ck('D-21 one production output per batch', :'e_out' like '%stock_moves_one_production_out%', :'e_out');
-- a closed batch's kg corrected by the manager: stock follows with an adjustment
select pg_temp.as_user('00000000-0000-4000-a000-0000000096a1');
set role authenticated;
select pg_temp.err($q$select fabula.correct_record('production_batches', '80000000-0000-4000-a000-0000000096b1', '{"output_kg": 125}', 'pesata di nuovo')$q$) e_bk \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('D-02 a closed batch''s kg is corrected through correct_record, with a stock adjustment and a note',
  :'e_bk' = '' and (select output_kg = 125 and notes like '%corretto da Titolare C (output_kg 120% → 125): pesata di nuovo%' from fabula.production_batches where batch_lot = 'LC96-A')
  and exists (select 1 from fabula.stock_moves where lot_number = 'LC96-A' and move_type = 'adjustment' and qty = 5), :'e_bk');
select pg_temp.ck('D-02 SQL editor / service changes still possible, and logged',
  pg_temp.err($q$update fabula.labels set qty_printed = qty_printed where false$q$) = '');

-- A-01 · who is recording: PIN (bcrypt, lockout), badge in/out without toggling, both identities on the record, daily check
select pg_temp.as_user('00000000-0000-4000-a000-0000000096a2');
set role authenticated;
select pg_temp.err($q$select fabula.staff_set_pin('10000000-0000-4000-a000-0000000096a3', '4826')$q$) e_pin_other \gset
select pg_temp.err($q$select fabula.staff_set_pin('10000000-0000-4000-a000-0000000096a2', '1234')$q$) e_pin_easy \gset
select pg_temp.err($q$select fabula.staff_set_pin('10000000-0000-4000-a000-0000000096a2', '7777')$q$) e_pin_same \gset
select pg_temp.err($q$select fabula.staff_set_pin('10000000-0000-4000-a000-0000000096a2', '48a6')$q$) e_pin_digits \gset
select fabula.staff_set_pin('10000000-0000-4000-a000-0000000096a2', '4826') pin_own \gset
select pg_temp.err($q$select * from fabula.staff_pins$q$) e_pin_read \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('A-01 a casaro cannot set someone else''s PIN', :'e_pin_other' like 'Permesso negato%', :'e_pin_other');
select pg_temp.ck('A-01 easy PINs are refused (in a row, all the same, not digits)',
  :'e_pin_easy' like 'PIN troppo facile%' and :'e_pin_same' like 'PIN troppo facile%' and :'e_pin_digits' like 'Il PIN è di 4 cifre%', :'e_pin_easy' || ' / ' || :'e_pin_same');
select pg_temp.ck('A-01 own PIN is stored only as a bcrypt hash, and the apps cannot read the table',
  (:'pin_own'::jsonb ->> 'ok')::boolean and (select pin_hash like '$2a$08$%' and pin_hash not like '%4826%' from fabula.staff_pins where staff_id = '10000000-0000-4000-a000-0000000096a2')
  and :'e_pin_read' like 'permission denied%', :'e_pin_read');
select pg_temp.as_user('00000000-0000-4000-a000-0000000096a1');
set role authenticated;
select fabula.staff_set_pin('10000000-0000-4000-a000-0000000096a3', '5093') pin_mgr \gset
reset role;
select pg_temp.as_user('00000000-0000-4000-a000-0000000096a3');   -- the tablet logged in as Banco C
set role authenticated;
select fabula.operator_pin_check('10000000-0000-4000-a000-0000000096a2', '4826') pc_ok \gset
select fabula.operator_pin_check('10000000-0000-4000-a000-0000000096a2', '0000') pc_w1 \gset
select fabula.operator_pin_check('10000000-0000-4000-a000-0000000096a2', '0000') pc_w2 \gset
select fabula.operator_pin_check('10000000-0000-4000-a000-0000000096a2', '0000') pc_w3 \gset
select fabula.operator_pin_check('10000000-0000-4000-a000-0000000096a2', '0000') pc_w4 \gset
select fabula.operator_pin_check('10000000-0000-4000-a000-0000000096a2', '0000') pc_w5 \gset
select fabula.operator_pin_check('10000000-0000-4000-a000-0000000096a2', '4826') pc_locked \gset
select fabula.operator_pin_check('10000000-0000-4000-a000-0000000096a1', '1111') pc_nopin \gset
select json_agg(o) ops from fabula.floor_operators() o where o.id::text like '10000000-0000-4000-a000-0000000096a%' \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('A-01 a manager sets a PIN for someone else', (:'pin_mgr'::jsonb ->> 'ok')::boolean, :'pin_mgr');
select pg_temp.ck('A-01 the right PIN is accepted from the floor tablet', (:'pc_ok'::jsonb ->> 'ok')::boolean and :'pc_ok'::jsonb ->> 'full_name' = 'Casaro C', :'pc_ok');
select pg_temp.ck('A-01 a wrong PIN says how many tries are left (the count is kept)', :'pc_w1'::jsonb ->> 'why' = 'wrong' and :'pc_w1'::jsonb ->> 'left' = '4' and :'pc_w4'::jsonb ->> 'left' = '1', :'pc_w4');
select pg_temp.ck('A-01 five wrong PINs lock it for 15 minutes, even with the right one', :'pc_w5'::jsonb ->> 'why' = 'locked' and :'pc_locked'::jsonb ->> 'why' = 'locked', :'pc_locked');
select pg_temp.ck('A-01 no PIN set: told so', :'pc_nopin'::jsonb ->> 'why' = 'no_pin', :'pc_nopin');
select pg_temp.ck('A-01 the floor list says who has a PIN, with no PIN data in it',
  (select bool_and((o ->> 'has_pin')::boolean = (o ->> 'full_name' <> 'Titolare C')) and count(*) = 3 from json_array_elements(:'ops'::json) o)
  and :'ops' not like '%pin_hash%' and :'ops' not like '%$2a$%', :'ops');
update fabula.staff_pins set locked_until = null where staff_id = '10000000-0000-4000-a000-0000000096a2';

-- badge: first scan clocks in, a second scan does NOT clock out; badge-out is explicit; a late offline scan keeps its time
select pg_temp.as_user('00000000-0000-4000-a000-0000000096a3');
set role authenticated;
select fabula.badge_in('STAFF:CCCCCCCCC2', null, now() - interval '40 minutes') b1 \gset
select fabula.badge_in('STAFF:CCCCCCCCC2') b2 \gset
select fabula.badge_in(null, '10000000-0000-4000-a000-0000000096a1') b3 \gset
select pg_temp.err($q$select fabula.badge_in('NOPE')$q$) e_badge \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('A-01 a badge scan clocks in at the tablet''s time', :'b1'::jsonb ->> 'action' = 'in'
  and (select abs(extract(epoch from clock_in - (now() - interval '40 minutes'))) < 5 from fabula.shifts where staff_id = '10000000-0000-4000-a000-0000000096a2' and clock_out is null), :'b1');
select pg_temp.ck('A-25 scanning again does not clock out', :'b2'::jsonb ->> 'action' = 'already'
  and (select count(*) = 1 from fabula.shifts where staff_id = '10000000-0000-4000-a000-0000000096a2' and clock_out is null), :'b2');
select pg_temp.ck('A-01 name + PIN can clock in too (by id)', :'b3'::jsonb ->> 'action' = 'in', :'b3');
select pg_temp.ck('A-01 an unknown badge is refused in Italian', :'e_badge' like 'Badge sconosciuto%', :'e_badge');

-- the record: operator = Casaro C (on shift), sent from the tablet logged in as Banco C → both kept; Banco C (A-04 retest + this one) is not on shift
select pg_temp.as_user('00000000-0000-4000-a000-0000000096a3');
set role authenticated;
select fabula.log_ccp(p_cp_code => 'CCP-COLD-1', p_value => 3, p_staff_id => '10000000-0000-4000-a000-0000000096a2') l_on \gset
select fabula.log_ccp(p_cp_code => 'CCP-COLD-1', p_value => 3, p_staff_id => '10000000-0000-4000-a000-0000000096a3') l_off \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('A-01 a record keeps who did it AND the account logged in on the tablet',
  (select operator = 'Casaro C' and operator_id = '10000000-0000-4000-a000-0000000096a2' and entered_by_id = '10000000-0000-4000-a000-0000000096a3'
     from fabula.haccp_log where id = (:'l_on'::jsonb ->> 'haccp_log_id')::uuid),
  (select operator || ' / ' || coalesce(entered_by_id::text, 'null') from fabula.haccp_log where id = (:'l_on'::jsonb ->> 'haccp_log_id')::uuid));
select fabula.ops_health_check() hc \gset
select pg_temp.ck('A-01 the daily check lists checks signed by someone not clocked in (Banco C), not those on shift',
  exists (select 1 from jsonb_array_elements(:'hc'::jsonb -> 'data_quality') i where i ->> 'key' = 'operator_off_shift' and i ->> 'text' like '%: Banco C 2 %' and i ->> 'text' not like '%Casaro C%'),
  (select string_agg(i ->> 'text', ' | ') from jsonb_array_elements(:'hc'::jsonb -> 'data_quality') i where i ->> 'key' = 'operator_off_shift'));

select pg_temp.as_user('00000000-0000-4000-a000-0000000096a3');
set role authenticated;
select fabula.badge_out('STAFF:CCCCCCCCC2') o1 \gset
select fabula.badge_out('STAFF:CCCCCCCCC2') o2 \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('A-01 badge-out closes the shift with its hours; a second one changes nothing',
  :'o1'::jsonb ->> 'action' = 'out' and (:'o1'::jsonb ->> 'hours')::numeric between 0.6 and 0.75 and :'o2'::jsonb ->> 'action' = 'none', :'o1');
select pg_temp.ck('A-01 the offline queue may send badge scans', pg_get_functiondef((select p.oid from pg_proc p where p.proname = 'save_ops' and p.pronamespace = 'fabula'::regnamespace order by p.pronargs desc limit 1)) like '%''badge_in'',''badge_out''%');

-- E-01 · alerts leave the building (Telegram): link, route by topic, quiet hours, «Me ne occupo io», reminder after 30 min
update fabula.settings set value = 'Banco C' where key = 'food.responsabile_autocontrollo';
delete from net.http_request_queue;
select pg_temp.as_user('00000000-0000-4000-a000-0000000096a1');
set role authenticated;
select fabula.notify_link_code() lc_tit \gset
select fabula.notify_link_code('10000000-0000-4000-a000-0000000096a2') lc_cas \gset
select fabula.notify_link_code('10000000-0000-4000-a000-0000000096a3') lc_ban \gset
reset role;
select pg_temp.as_user('00000000-0000-4000-a000-0000000096a2');
set role authenticated;
select pg_temp.err($q$select fabula.notify_link_code('10000000-0000-4000-a000-0000000096a3')$q$) e_lc \gset
select pg_temp.err($q$select * from fabula.notify_targets$q$) e_nt \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('E-01 a link is a one-time t.me link to the bot', :'lc_tit'::jsonb ->> 'url' like 'https://t.me/bubalina_avvisi_bot?start=%', :'lc_tit');
select pg_temp.ck('E-01 a casaro cannot make someone else''s link, nor read the table', :'e_lc' like 'Permesso negato%' and :'e_nt' like 'permission denied%', :'e_lc');
select fabula.notify_link(:'lc_tit'::jsonb ->> 'code', 9001, 'nick') l1 \gset
select fabula.notify_link(:'lc_cas'::jsonb ->> 'code', 9002, 'casaro') l2 \gset
select fabula.notify_link(:'lc_ban'::jsonb ->> 'code', 9003, 'banco') l3 \gset
select fabula.notify_link(:'lc_ban'::jsonb ->> 'code', 9004, 'other') l4 \gset
select pg_temp.ck('E-01 /start <code> links the chat; the code works once', (:'l1'::jsonb ->> 'ok')::boolean and (:'l3'::jsonb ->> 'ok')::boolean and not (:'l4'::jsonb ->> 'ok')::boolean, :'l1');
select pg_temp.ck('E-01 default topics by profile (owner: all; casaro: food safety)',
  (select topics = '{food_safety,infra,decisions}' from fabula.notify_targets where staff_id = '10000000-0000-4000-a000-0000000096a1')
  and (select topics = '{food_safety}' from fabula.notify_targets where staff_id = '10000000-0000-4000-a000-0000000096a2'));
update fabula.notify_targets set topics = '{decisions}', quiet_from = ((now() at time zone 'Europe/Rome') + interval '2 hours')::time, quiet_to = ((now() at time zone 'Europe/Rome') + interval '3 hours')::time
 where staff_id = '10000000-0000-4000-a000-0000000096a3';   -- the HACCP responsible gets food safety anyway; not in quiet hours now
update fabula.notify_targets set quiet_from = ((now() at time zone 'Europe/Rome') + interval '2 hours')::time, quiet_to = ((now() at time zone 'Europe/Rome') + interval '3 hours')::time
 where staff_id = '10000000-0000-4000-a000-0000000096a2';
-- owner in quiet hours right now (Rome): decisions wait, food safety does not
update fabula.notify_targets set quiet_from = ((now() at time zone 'Europe/Rome') - interval '1 hour')::time, quiet_to = ((now() at time zone 'Europe/Rome') + interval '1 hour')::time
 where staff_id = '10000000-0000-4000-a000-0000000096a1';

select fabula.post_bot_message('produzione', 'alert', 'Lotto LX chiuso senza CCP 3 <filatura>', E'**Da fare**\n1. Ricopia la misura') bm1 \gset
select id fs1 from fabula.notify_outbox where source = 'bot_messages' and source_ref = :'bm1' \gset
select pg_temp.ck('E-01 a food-safety alert reaches the subscribed, the HACCP responsible (any topic) — not waiting for quiet hours',
  (select topic = 'food_safety' from fabula.notify_outbox where id = :'fs1')
  and (select count(*) = 3 and bool_and(due_at <= now()) from fabula.notify_deliveries where outbox_id = :'fs1'),
  (select string_agg(chat_id || '@' || to_char(due_at, 'HH24:MI'), ', ') from fabula.notify_deliveries where outbox_id = :'fs1'));
select fabula.post_bot_message('produzione', 'alert', 'Lotto LX chiuso senza CCP 3 <filatura>', 'di nuovo') bm1b \gset
select pg_temp.ck('E-01 the same alert again within 3 hours is not sent twice', (select count(*) = 1 from fabula.notify_outbox where title like 'Lotto LX chiuso%'));
select fabula.post_bot_message('milk_planning', 'alert', 'Approva il latte di domani: 1.200 kg', 'Console → Da approvare') bm2 \gset
select id dc1 from fabula.notify_outbox where source_ref = :'bm2' \gset
select pg_temp.ck('E-01 a decision goes to who subscribed, after their quiet hours',
  (select topic = 'decisions' from fabula.notify_outbox where id = :'dc1')
  and (select count(*) = 2 from fabula.notify_deliveries where outbox_id = :'dc1')
  and (select due_at between now() + interval '50 minutes' and now() + interval '70 minutes' from fabula.notify_deliveries where outbox_id = :'dc1' and chat_id = 9001)
  and (select due_at <= now() from fabula.notify_deliveries where outbox_id = :'dc1' and chat_id = 9003),
  (select string_agg(chat_id || '@' || to_char(due_at at time zone 'Europe/Rome', 'HH24:MI'), ', ') from fabula.notify_deliveries where outbox_id = :'dc1'));
select fabula.post_bot_message('ops_health', 'alert', 'Backup notturno non riuscito', null) bm3 \gset
-- v1.02b (E-07): a system alarm that is not «system down» waits for the end of the owner's quiet hours, like a decision
select pg_temp.ck('E-01 an infrastructure alert goes to the owner only, with no reminder; in his quiet hours it waits (v1.02b)',
  (select topic = 'infra' and escalate_at is null and not urgent from fabula.notify_outbox where source_ref = :'bm3')
  and (select string_agg(chat_id::text, ',') = '9001' and bool_and(due_at > now() + interval '30 minutes') from fabula.notify_deliveries d join fabula.notify_outbox o on o.id = d.outbox_id where o.source_ref = :'bm3'));
select fabula.post_bot_message('produzione', 'warn', 'Resa bassa sul lotto LY', null) bm4 \gset
select fabula.post_bot_message('produzione', 'alert', 'SIMULAZIONE · Lotto LZ senza CCP', null) bm5 \gset
select pg_temp.ck('E-01 warnings and simulations are not pushed', not exists (select 1 from fabula.notify_outbox where source_ref in (:'bm4', :'bm5')));

select fabula.notify_tick() t1 \gset
select pg_temp.ck('E-01 the minute tick wakes the sender when something is due',
  (:'t1'::jsonb ->> 'due')::int = 4 and exists (select 1 from net.http_request_queue where url like '%/functions/v1/notify' and body ->> 'op' = 'dispatch'), :'t1');
select fabula.notify_claim(25) cl \gset
select pg_temp.ck('E-01 the sender gets the due messages only (decision for the owner waits), as Telegram HTML with buttons',
  jsonb_array_length(:'cl'::jsonb) = 4
  and exists (select 1 from jsonb_array_elements(:'cl'::jsonb) x where x ->> 'text' like E'⚠ <b>SICUREZZA ALIMENTARE</b>\n<b>Lotto LX chiuso senza CCP 3 &lt;filatura&gt;</b>\n<b>Da fare</b>%Zio Ciro%' and (x ->> 'buttons')::boolean)
  and not exists (select 1 from jsonb_array_elements(:'cl'::jsonb) x where (x ->> 'chat_id')::bigint = 9001 and x ->> 'outbox_id' = :'dc1'),
  left(:'cl', 400));
select fabula.notify_claim(25) cl2 \gset
select pg_temp.ck('E-01 a message being sent is not handed out twice', jsonb_array_length(:'cl2'::jsonb) = 0, :'cl2');
select fabula.notify_mark((x ->> 'id')::uuid, true, 500 + row_number() over ()) from jsonb_array_elements(:'cl'::jsonb) x;

select fabula.notify_ack(9003, :'fs1', 'take') ak \gset
select fabula.notify_ack(9002, :'fs1', 'take') ak2 \gset
select fabula.notify_ack(9002, :'fs1', 'seen') ak3 \gset
select pg_temp.ck('E-01 «Me ne occupo io» stops the reminder and updates everyone''s message',
  (select acked_by_id = '10000000-0000-4000-a000-0000000096a3' from fabula.notify_outbox where id = :'fs1')
  and jsonb_array_length(:'ak'::jsonb -> 'edits') = 3 and :'ak'::jsonb -> 'edits' -> 0 ->> 'text' like '%✋ <b>Se ne occupa Banco C</b>%', left(:'ak', 300));
select pg_temp.ck('E-01 …a second person is told who already took it; «Ho visto» is recorded',
  :'ak2'::jsonb ->> 'toast' = 'Se ne occupa già Banco C' and (select seen_at is not null from fabula.notify_deliveries where outbox_id = :'fs1' and chat_id = 9002), :'ak2');

-- a food-safety alert nobody takes: after 30 minutes a reminder also reaches owner, partners and the HACCP responsible
select fabula.post_bot_message('haccp_nudge', 'alert', 'Cella frigo 1 a 9 °C', null) bm6 \gset
select id fs2 from fabula.notify_outbox where source_ref = :'bm6' \gset
update fabula.notify_outbox set escalate_at = now() - interval '1 minute', created_at = now() - interval '31 minutes' where id = :'fs2';
select fabula.notify_tick() t2 \gset
select id rem from fabula.notify_outbox where parent_id = :'fs2' \gset
select pg_temp.ck('E-01 nobody took it in 30 minutes → a reminder to everyone concerned',
  (select title like '⏰ Nessuno se ne occupa da 3_ min: Cella frigo 1 a 9 °C' from fabula.notify_outbox where id = :'rem')
  and (select count(*) = 3 from fabula.notify_deliveries where outbox_id = :'rem') and (:'t2'::jsonb ->> 'reminders')::int = 1, :'t2');
select fabula.notify_tick() t3 \gset
select pg_temp.ck('E-01 …only once', (:'t3'::jsonb ->> 'reminders')::int = 0 and (select count(*) = 1 from fabula.notify_outbox where parent_id = :'fs2'));
select fabula.notify_ack(9001, :'fs2', 'take') ak4 \gset
select pg_temp.ck('E-01 taking the reminder takes the original too', (select bool_and(acked_by_id = '10000000-0000-4000-a000-0000000096a1') and count(*) = 2 from fabula.notify_outbox where id = :'fs2' or parent_id = :'fs2'));

-- the decision held overnight was taken by someone else: it is not sent late
select fabula.notify_ack(9003, :'dc1', 'take') ak5 \gset
update fabula.notify_deliveries set due_at = now() - interval '1 minute' where outbox_id = :'dc1' and chat_id = 9001;
select fabula.notify_claim(25) cl3 \gset
select pg_temp.ck('E-01 a held message already taken by someone else is skipped, not sent late',
  (select status = 'skipped' from fabula.notify_deliveries where outbox_id = :'dc1' and chat_id = 9001)
  and not exists (select 1 from jsonb_array_elements(:'cl3'::jsonb) x where x ->> 'outbox_id' = :'dc1'));

-- a notice (tablet/office) with severity alert is pushed as well
insert into fabula.notices (key, severity, title_it, items, expires_at) values ('lab_lot_unknown:S96', 'alert', 'Analisi LIST NON CONFORME: lotto L9 non trovato', '[{"label_it": "Campione S96 · lotto L9"}]', now() + interval '1 day');
select pg_temp.ck('E-01 an alert notice is pushed too, with its lines', exists (select 1 from fabula.notify_outbox where source = 'notices' and source_ref = 'lab_lot_unknown:S96' and topic = 'food_safety' and body = '- Campione S96 · lotto L9'));

-- the person blocked the bot: delivery failed, chat unlinked, the daily check says so
select fabula.notify_claim(25) cl4 \gset
select fabula.notify_mark((x ->> 'id')::uuid, false, null, 'Forbidden: bot was blocked by the user') from jsonb_array_elements(:'cl4'::jsonb) x where (x ->> 'chat_id')::bigint = 9002;
select pg_temp.ck('E-01 a blocked bot: delivery failed and the chat unlinked',
  (select chat_id is null from fabula.notify_targets where staff_id = '10000000-0000-4000-a000-0000000096a2')
  and exists (select 1 from fabula.notify_deliveries where chat_id = 9002 and status = 'failed'));
select fabula.ops_health_check() hc2 \gset
select pg_temp.ck('E-01 the daily check lists undelivered alerts', exists (select 1 from jsonb_array_elements(:'hc2'::jsonb -> 'data_quality') i where i ->> 'key' = 'notify_failed'));

-- settings from Configurazione
select pg_temp.as_user('00000000-0000-4000-a000-0000000096a1');
set role authenticated;
select pg_temp.err($q$select fabula.notify_set_prefs('{food_safety,gossip}', null, null, null)$q$) e_tp \gset
select pg_temp.err($q$select fabula.notify_set_prefs('{food_safety,infra}', '23:00', '06:30', 'America/New_York')$q$) e_ok \gset
select fabula.notify_overview() ov \gset
select fabula.notify_test() nt \gset
reset role;
select pg_temp.as_user('00000000-0000-4000-a000-0000000096a2');
set role authenticated;
select fabula.notify_overview() ov2 \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('E-01 own settings: unknown topics refused, US time zone accepted', :'e_tp' like 'Argomento sconosciuto%' and :'e_ok' = ''
  and (select tz = 'America/New_York' and quiet_to = '06:30' from fabula.notify_targets where staff_id = '10000000-0000-4000-a000-0000000096a1'), :'e_tp');
select pg_temp.ck('E-01 the owner sees everyone and the last alerts; a casaro only himself',
  jsonb_array_length(:'ov'::jsonb -> 'recent') >= 5 and (:'ov'::jsonb -> 'me' ->> 'linked')::boolean
  and :'ov2'::jsonb -> 'people' = 'null'::jsonb and not (:'ov2'::jsonb -> 'me' ->> 'linked')::boolean, left(:'ov2', 200));
select pg_temp.ck('E-01 a test message goes out at once', exists (select 1 from fabula.notify_deliveries d join fabula.notify_outbox o on o.id = d.outbox_id where o.topic = 'test' and d.chat_id = 9001 and d.status = 'queued'));

-- FARM-02 · the dairy's scale weight is kept; over 2 % (with a reason) it is what entered, the office and the farm are told
insert into fabula.milk_shipments (id, shipped_at, ship_date, kg, milk_lot, status) values
  ('60000000-0000-4000-a000-0000000096c2', now() - interval '1 hour', current_date, 1100, 'MC96-2', 'shipped'),
  ('60000000-0000-4000-a000-0000000096c3', now() - interval '1 hour', current_date, 1000, 'MC96-3', 'shipped'),
  ('60000000-0000-4000-a000-0000000096c4', now() - interval '1 hour', current_date, 105, 'MC96-4', 'shipped');
select pg_temp.as_user('00000000-0000-4000-a000-0000000096a2');   -- the casaro receives the milk
-- v1.17 (audit D-1): times relative to now, in the past (they were fixed at 07:00–07:20 today, which is in the future when the suite
-- runs before 07:00 Rome; a delivery can no longer be dated in the future)
set role authenticated;
select pg_temp.err($q$insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source, shipment_id, dairy_kg)
  values (current_date, ((now() at time zone 'Europe/Rome') - interval '40 minutes')::time, '50000000-0000-4000-a000-0000000096f1', 'x', 1, true, 4, 'tablet', '60000000-0000-4000-a000-0000000096c2', 1050)$q$) e_nowhy \gset
select pg_temp.err($q$insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source, shipment_id, dairy_kg, weight_note)
  values (current_date, ((now() at time zone 'Europe/Rome') - interval '40 minutes')::time, '50000000-0000-4000-a000-0000000096f1', 'x', 1, true, 4, 'tablet', '60000000-0000-4000-a000-0000000096c2', 1050, 'latte rimasto nella cisterna')$q$) e_why \gset
select pg_temp.err($q$insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source, shipment_id, dairy_kg)
  values (current_date, ((now() at time zone 'Europe/Rome') - interval '30 minutes')::time, '50000000-0000-4000-a000-0000000096f1', 'x', 1, true, 4, 'tablet', '60000000-0000-4000-a000-0000000096c3', 1012)$q$) e_small \gset
select pg_temp.err($q$insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source, shipment_id, dairy_kg, weight_note)
  values (current_date, ((now() at time zone 'Europe/Rome') - interval '20 minutes')::time, '50000000-0000-4000-a000-0000000096f1', 'x', 1, true, 4, 'tablet', '60000000-0000-4000-a000-0000000096c4', 1050, 'la Masseria ha scritto 105 invece di 1050')$q$) e_typo \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('FARM-02 over 2 % without a reason is refused, with both weights', :'e_nowhy' = 'Pesato qui 1050,0 kg, la Masseria ha scritto 1100,0 kg (-4,5 %): scrivi il motivo della differenza', :'e_nowhy');
select pg_temp.ck('FARM-02 with the reason: both weights kept, the dairy''s is what entered (stock too)', :'e_why' = ''
  and (select farm_kg = 1100 and dairy_kg = 1050 and qty_kg = 1050 and weight_note = 'latte rimasto nella cisterna' from fabula.milk_intake where milk_lot = 'MC96-2')
  and (select sum(qty) = 1050 from fabula.stock_moves where lot_number = 'MC96-2' and move_type = 'milk_intake'), :'e_why');
select pg_temp.ck('FARM-02 within 2 %: the farm''s weight stays, the scale reading is recorded', :'e_small' = ''
  and (select farm_kg = 1000 and dairy_kg = 1012 and qty_kg = 1000 from fabula.milk_intake where milk_lot = 'MC96-3'), :'e_small');
select pg_temp.ck('FARM-02 a farm typo (105 for 1,050) is fixed at arrival: 1,050 entered', :'e_typo' = '' and (select qty_kg = 1050 from fabula.milk_intake where milk_lot = 'MC96-4'), :'e_typo');
select pg_temp.ck('FARM-02 the office gets a notice with the reason', exists (select 1 from fabula.notices where key = 'milk_weight:MC96-2' and title_it like 'Latte MC96-2: pesato qui 1050,0 kg, la Masseria ha scritto 1100,0 kg (-4,5 %%)%' and items::text like '%latte rimasto nella cisterna%')
  and not exists (select 1 from fabula.notices where key = 'milk_weight:MC96-3'),
  (select title_it from fabula.notices where key = 'milk_weight:MC96-2'));
select fabula.farm_milk_orders('0123456789abcdef0123456789abcdef') fo \gset
select pg_temp.ck('FARM-02 the farm page shows the weighed kg and the reason; its month total counts what entered',
  exists (select 1 from jsonb_array_elements(:'fo'::jsonb -> 'shipments') x where x ->> 'milk_lot' = 'MC96-2' and (x ->> 'entered_kg')::numeric = 1050 and x ->> 'weight_note' = 'latte rimasto nella cisterna')
  and exists (select 1 from jsonb_array_elements(:'fo'::jsonb -> 'shipments') x where x ->> 'milk_lot' = 'MC96-3' and x ->> 'weight_note' is null)
  and (:'fo'::jsonb -> 'month' ->> 'received_kg')::numeric = (select sum(coalesce(mi.qty_kg, s.kg)) from fabula.milk_shipments s left join fabula.milk_intake mi on mi.id = s.milk_intake_id
                                                                where s.status = 'received' and s.ship_date >= date_trunc('month', current_date)::date), left(:'fo', 300));
select (fabula.haccp_register('MOD-01', current_date, current_date) -> 'rows') mr2 \gset
select pg_temp.ck('FARM-02 the milk register prints both weights when they differ', exists (select 1 from jsonb_array_elements(:'mr2'::jsonb) r where r ->> 'lotto' = 'MC96-2' and r ->> 'kg' = '1050 (pesati qui; Masseria 1100: latte rimasto nella cisterna)'),
  (select r ->> 'kg' from jsonb_array_elements(:'mr2'::jsonb) r where r ->> 'lotto' = 'MC96-2'));

-- ===== review fixes (13/10/2026) =====
-- R1 · a lot already held for another reason gets the milk reason too (it cannot be released for the first reason alone)
insert into fabula.milk_intake (id, intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source)
values ('70000000-0000-4000-a000-0000000096d5', (now() at time zone 'Europe/Rome')::date, '06:40',   -- v1.20: the Rome day (see MC96-1)
        '50000000-0000-4000-a000-0000000096f1', 'MC96-5', 500, true, 4, 'tablet');
insert into fabula.batch_milk_inputs (batch_id, milk_intake_id, qty_kg) select id, '70000000-0000-4000-a000-0000000096d5', 200 from fabula.production_batches where batch_lot = 'LC96-B';
select pg_temp.as_user('00000000-0000-4000-a000-0000000096a2');
set role authenticated;
select fabula.log_milk_check('70000000-0000-4000-a000-0000000096d5', 'CCP-MILK-ABX', 1, '10000000-0000-4000-a000-0000000096a2') r1 \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('R1 a lot already held (CCP missing) is listed and gets the milk reason added',
  (:'r1'::jsonb -> 'lots_held') @> '["LC96-B"]'
  and (select hold_reason like 'CCP mancante alla chiusura%Latte MC96-5: test antibiotici POSITIVO (ricontrollo)' and hold_nc_id is not null from fabula.production_batches where batch_lot = 'LC96-B')
  and exists (select 1 from fabula.bot_messages where title like 'Latte MC96-5 respinto%' and body like '%BLOCCATI: LC96-B%'),
  (select hold_reason from fabula.production_batches where batch_lot = 'LC96-B'));

-- R4 · milk rejected AT ARRIVAL also raises the alert (Telegram), once; a cold-room NC is pushed by itself
-- v1.17 (audit D-1): the delivery's time is relative to now, in the past (it was fixed at 07:30 today: in the future before 07:30 Rome)
select pg_temp.as_user('00000000-0000-4000-a000-0000000096a2');
set role authenticated;
select fabula.save_ops(jsonb_build_array(
  jsonb_build_object('table', 'milk_intake', 'row', jsonb_build_object('id', '70000000-0000-4000-a000-0000000096d6', 'intake_date', current_date, 'intake_time', to_char((now() at time zone 'Europe/Rome') - interval '10 minutes', 'HH24:MI'), 'supplier_id', '50000000-0000-4000-a000-0000000096f1',
                     'milk_lot', 'MC96-6', 'qty_kg', 900, 'temperature_c', 4, 'accepted', false, 'rejection_reason', 'test antibiotici positivo', 'source', 'tablet')),
  jsonb_build_object('rpc', 'log_milk_check', 'args', jsonb_build_object('p_milk_intake_id', '$0.id', 'p_cp_code', 'CCP-MILK-ABX', 'p_value', 1, 'p_staff_id', '10000000-0000-4000-a000-0000000096a2'))), gen_random_uuid()) so6 \gset
select fabula.log_ccp(p_cp_code => 'CCP-COLD-2', p_value => 11, p_staff_id => '10000000-0000-4000-a000-0000000096a2') cold \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('R4 a delivery rejected at arrival raises one alert (all''arrivo), not also a bare NC push',
  (select count(*) = 1 from fabula.notify_outbox where title like 'Latte MC96-6 respinto: test antibiotici POSITIVO (all''arrivo)')
  and not exists (select 1 from fabula.notify_outbox o join fabula.non_conformities n on o.source_ref = n.id::text join fabula.haccp_log l on l.id = n.haccp_log_id where l.milk_intake_id = '70000000-0000-4000-a000-0000000096d6'),
  (select string_agg(title, ' | ') from fabula.notify_outbox where title like '%MC96-6%'));
select pg_temp.ck('R4 an out-of-limit cold room (NC) is pushed as food safety', exists (select 1 from fabula.notify_outbox where source = 'non_conformities' and source_ref = (:'cold'::jsonb ->> 'nc_id') and topic = 'food_safety' and title like 'Non conformità · CCP 5 · Cella frigo 2: 11 °C fuori dal limite critico'),
  (select title from fabula.notify_outbox where source = 'non_conformities' and source_ref = (:'cold'::jsonb ->> 'nc_id')));

-- R2 · corrections: a milk temperature corrected out of limit rejects the delivery and holds its lots; a reading moved to another lot
insert into fabula.milk_intake (id, intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source, received_by_id)
values ('70000000-0000-4000-a000-0000000096d7', (now() at time zone 'Europe/Rome')::date, '06:50',   -- v1.20: the Rome day (see MC96-1)
        '50000000-0000-4000-a000-0000000096f1', 'MC96-7', 600, true, 4, 'tablet', '10000000-0000-4000-a000-0000000096a2');
insert into fabula.production_batches (id, batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, source) values ('80000000-0000-4000-a000-0000000096b7', current_date, 'LC96-G', :'moz', 300, 'milk', now(), 'tablet');
insert into fabula.batch_milk_inputs (batch_id, milk_intake_id, qty_kg) values ('80000000-0000-4000-a000-0000000096b7', '70000000-0000-4000-a000-0000000096d7', 300);
select pg_temp.as_user('00000000-0000-4000-a000-0000000096a2');
set role authenticated;
select fabula.log_milk_check('70000000-0000-4000-a000-0000000096d7', 'CCP-MILK-TEMP', 4, '10000000-0000-4000-a000-0000000096a2') t7 \gset
reset role;
select pg_temp.as_user('00000000-0000-4000-a000-0000000096a1');
set role authenticated;
select pg_temp.err(format($q$select fabula.correct_record('haccp_log', %L, '{"measured_value": 14}', 'letto male dallo strumento')$q$, :'t7'::jsonb ->> 'haccp_log_id')) e_t7 \gset
select pg_temp.err($q$select fabula.correct_record('milk_intake', '70000000-0000-4000-a000-0000000096d7', '{"temperature_c": 3}', 'errore')$q$) e_mt \gset
select pg_temp.err($q$select fabula.correct_record('production_batches', '80000000-0000-4000-a000-0000000096b7', '{"output_kg": 90}', 'errore di battitura')$q$) e_open \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('R2 milk temperature corrected to 14 °C: delivery rejected, its lot held, MOD-01 shows 14',
  :'e_t7' = '' and (select accepted is false and temperature_c = 14 and correction_note like '%temperatura corretta%' from fabula.milk_intake where milk_lot = 'MC96-7')
  and (select food_safety_hold and hold_reason like 'Latte MC96-7: temperatura 14 °C oltre il limite (corretto)%' from fabula.production_batches where batch_lot = 'LC96-G'), :'e_t7');
select pg_temp.ck('R2 a delivery temperature is not corrected directly (only through its CCP 1a record)', :'e_mt' like 'Campo non correggibile: temperature_c%', :'e_mt');
select pg_temp.ck('R2 an open lot cannot be "closed" by a correction', :'e_open' like 'Il lotto LC96-G è ancora aperto%', :'e_open');
-- a stretching reading logged on the wrong lot: moved, the lot it left (closed, now without CCP 3) is held; an NC moves with its lot
insert into fabula.production_batches (id, batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, source) values
  ('80000000-0000-4000-a000-0000000096b8', current_date, 'LC96-H', :'moz', 200, 'milk', now(), 'tablet'),
  ('80000000-0000-4000-a000-0000000096b9', current_date, 'LC96-I', :'moz', 200, 'milk', now(), 'tablet');
select fabula.log_ccp(p_cp_code => 'CCP-PAST', p_value => 72, p_batch_lot => 'LC96-H', p_staff_id => '10000000-0000-4000-a000-0000000096a2') ph \gset
select fabula.log_ccp(p_cp_code => 'CCP-STRETCH', p_value => 64, p_batch_lot => 'LC96-H', p_staff_id => '10000000-0000-4000-a000-0000000096a2') sh \gset
update fabula.production_batches set output_kg = 60, finished_at = now() where batch_lot = 'LC96-H';
select fabula.log_ccp(p_cp_code => 'CCP-STRETCH', p_value => 40, p_batch_lot => 'LC96-H', p_staff_id => '10000000-0000-4000-a000-0000000096a2') sn \gset
select pg_temp.as_user('00000000-0000-4000-a000-0000000096a1');
set role authenticated;
select pg_temp.err(format($q$select fabula.correct_record('haccp_log', %L, '{"batch_lot": "LC96-I"}', 'lotto sbagliato')$q$, :'sn'::jsonb ->> 'haccp_log_id')) e_mv1 \gset
select pg_temp.err(format($q$select fabula.correct_record('haccp_log', %L, '{"batch_lot": "LC96-I"}', 'lotto sbagliato')$q$, :'sh'::jsonb ->> 'haccp_log_id')) e_mv2 \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('R2 an out-of-limit reading moved to its real lot: that lot is held and the NC follows',
  :'e_mv1' = '' and (select food_safety_hold and hold_reason like '%lotto corretto da LC96-H%' from fabula.production_batches where batch_lot = 'LC96-I')
  and (select batch_id = '80000000-0000-4000-a000-0000000096b9' and lot_number = 'LC96-I' from fabula.non_conformities where id = (:'sn'::jsonb ->> 'nc_id')::uuid), :'e_mv1');
select pg_temp.ck('R2 …the closed lot that lost its only stretching reading is held as missing CCP',
  :'e_mv2' = '' and (select food_safety_hold and hold_reason like '%CCP mancante: la misura CCP 3 è stata spostata sul lotto LC96-I%' from fabula.production_batches where batch_lot = 'LC96-H'),
  (select hold_reason from fabula.production_batches where batch_lot = 'LC96-H'));

-- R5 · an alert notice is pushed once (not again through its bot-message copy); infrastructure first in the topics
-- v1.05 (audit E-06): the notice's severity comes from its rule; lab_lot_unknown is an alarm (lot_guard is a warning)
delete from fabula.notify_outbox where source_ref like 'R5%';
insert into fabula.notices (key, severity, title_it, items, expires_at) values ('lab_lot_unknown:R5', 'alert', 'Lotto scaduto in vendita: R5', '[]', now() + interval '1 day');
select pg_temp.ck('R5 one alert notice = one push', (select count(*) from fabula.notify_outbox where title = 'Lotto scaduto in vendita: R5') = 1,
  (select string_agg(source || ':' || coalesce(source_ref, ''), ', ') from fabula.notify_outbox where title = 'Lotto scaduto in vendita: R5'));
select pg_temp.ck('R5 topics: «haccp_nudge non è partito» and «backup bloccato» are infrastructure; tablet records refused are for the floor',
  fabula.notify_topic_for('bot_watchdog', 'Zia Filomena (haccp_nudge) non è partita alle 19:00') = 'infra'
  and fabula.notify_topic_for('ops_health', 'Backup bloccato da 2 giorni') = 'infra'
  and fabula.notify_topic_for('notice', 'Sito non raggiungibile', 'infra_uptime') = 'infra'
  and fabula.notify_topic_for('tablet', '2 registrazioni rifiutate dal database') = 'food_safety'
  and fabula.notify_topic_for('procurement', 'Ordine fornitore bloccato in attesa di approvazione') = 'decisions'
  and fabula.notify_topic_for('produzione', 'Lotto L1 bloccato: CCP mancante') = 'food_safety'
  and fabula.notify_topic_for('sicurezza', 'Riepilogo del giorno') = 'food_safety'          -- v1.00: who speaks for food safety, whatever the words
  and fabula.notify_topic_for('ops_health', '⚠ 2 registrazioni HACCP mancanti') = 'food_safety'
  and fabula.notify_topic_for('configurazione', 'Impostazione cambiata') = 'infra');

-- R3/R10 · the first link wakes the sender (webhook registration); recipients rechecked at send time; stuck messages flagged
delete from fabula.settings where key = 'notify.webhook_url';
delete from net.http_request_queue;
select pg_temp.as_user('00000000-0000-4000-a000-0000000096a1');
set role authenticated;
select fabula.notify_link_code('10000000-0000-4000-a000-0000000096a2') lc_r3 \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('R3 creating a link with no webhook yet calls the sender at once (it registers the webhook)', exists (select 1 from net.http_request_queue where url like '%/functions/v1/notify'));
update fabula.notify_targets set chat_id = 9101, active = true where staff_id = '10000000-0000-4000-a000-0000000096a2';
select fabula.post_bot_message('haccp_nudge', 'alert', 'R10 cella frigo 2 a 12 °C', null) r10 \gset
select id r10o from fabula.notify_outbox where source_ref = :'r10' \gset
update fabula.notify_targets set chat_id = null where staff_id = '10000000-0000-4000-a000-0000000096a2';   -- /stop before it went out
select fabula.notify_claim(50) r10c \gset
select pg_temp.ck('R10 a message for someone who unlinked meanwhile is skipped, not sent', (select status = 'skipped' from fabula.notify_deliveries where outbox_id = :'r10o' and chat_id = 9101)
  and not exists (select 1 from jsonb_array_elements(:'r10c'::jsonb) x where (x ->> 'chat_id')::bigint = 9101));
update fabula.notify_deliveries set status = 'sending', attempts = 5, claimed_at = now() - interval '10 minutes' where outbox_id = :'r10o' and chat_id = 9001;
insert into fabula.notify_deliveries (outbox_id, staff_id, chat_id, due_at) values (:'r10o', '10000000-0000-4000-a000-0000000096a3', 9003, now() - interval '20 minutes') on conflict (outbox_id, staff_id) do update set status = 'queued', due_at = now() - interval '20 minutes';
select fabula.ops_health_check() hc3 \gset
select fabula.notify_claim(0) r10d \gset
select pg_temp.ck('R10 messages stuck 15 minutes are flagged; a message tried 5 times is given up as failed',
  exists (select 1 from jsonb_array_elements(:'hc3'::jsonb -> 'data_quality') i where i ->> 'key' = 'notify_stuck')
  and (select status = 'failed' from fabula.notify_deliveries where outbox_id = :'r10o' and chat_id = 9001));
