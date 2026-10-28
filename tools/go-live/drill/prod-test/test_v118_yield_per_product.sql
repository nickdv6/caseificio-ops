-- v1.18 · yield per product (stracciatella counts its cream; scamorza runs ~25 %) · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh y_test
--   su postgres -c "psql -d y_test -f tools/go-live/drill/prod-test/test_v118_yield_per_product.sql" | grep -E "PASS|FAIL"
-- Sections: 1 structure and grants · 2 the checks on the three columns · 3 the batch limits per product (milk and whey) ·
-- 4 a product with no values behaves exactly as before · 5 expected_yield (product, then its own lots, then the preset).
-- Lots are started and closed as the database owner with source «tablet» (the limits skip «simulation»/«test»); every refusal is
-- caught by pg_temp.err, so the suite prints PASS/FAIL lines only.
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as
$$ begin execute p_sql; return ''; exception when others then return sqlerrm; end $$;
create or replace function pg_temp.st(p_sql text) returns text language plpgsql as
$$ begin execute p_sql; return '00000'; exception when others then return sqlstate; end $$;
create or replace function pg_temp.today() returns date language sql as $$ select (now() at time zone 'Europe/Rome')::date $$;
-- start a lot of p_milk kg (milk or whey) and return its lot number; closing is a separate update so the refusal can be read
create or replace function pg_temp.lot(p_lot text, p_product uuid, p_milk numeric, p_kind text default 'milk', p_preset uuid default null) returns text language sql as $$
  insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, source, preset_id)
  values (pg_temp.today(), p_lot, p_product, p_milk, p_kind, now(), 'tablet', p_preset) returning batch_lot $$;
create or replace function pg_temp.close_sql(p_lot text, p_out numeric, p_note text default null) returns text language sql as $$
  select format('update fabula.production_batches set output_kg = %s, finished_at = now(), yield_note = %L where batch_lot = %L', p_out, p_note, p_lot) $$;

update fabula.settings set value = '310' where key = 'prod.vat_kg';
select id moz from fabula.products where sku = 'MOZ-DOP-KG' \gset
select id ric from fabula.products where sku = 'RIC-BUF-KG' \gset
insert into fabula.products (sku, name, kind, unit, iva_rate, shelf_life_days, yield_expected_pct, yield_min_pct, yield_max_pct)
values ('T118-STR', 'Stracciatella di bufala (test)', 'finished_good', 'kg', 4, 4, 50, 35, 70) returning id str \gset
insert into fabula.products (sku, name, kind, unit, iva_rate, shelf_life_days, yield_expected_pct)
values ('T118-SCA', 'Scamorza di bufala (test)', 'finished_good', 'kg', 4, 10, 25) returning id sca \gset
insert into fabula.products (sku, name, kind, unit, iva_rate, shelf_life_days)
values ('T118-PLAIN', 'Formaggio senza rese proprie (test)', 'finished_good', 'kg', 4, 5) returning id plain \gset

-- ============================== 1. structure and grants ==============================
select pg_temp.ck('1a products has yield_expected_pct, yield_min_pct and yield_max_pct, numeric and nullable',
  (select count(*) from information_schema.columns where table_schema = 'fabula' and table_name = 'products'
     and column_name in ('yield_expected_pct', 'yield_min_pct', 'yield_max_pct') and data_type = 'numeric' and is_nullable = 'YES') = 3);
select pg_temp.ck('1b existing products keep empty values (MOZ-DOP-KG, RIC-BUF-KG): the settings still decide for them',
  (select bool_and(yield_expected_pct is null and yield_min_pct is null and yield_max_pct is null) from fabula.products where sku in ('MOZ-DOP-KG', 'RIC-BUF-KG')));
select pg_temp.ck('1c the trigger function is still closed to logins and anon; expected_yield keeps its grants (logins yes, anon no)',
  not has_function_privilege('authenticated', 'fabula.trg_batch_bounds()', 'EXECUTE') and not has_function_privilege('anon', 'fabula.trg_batch_bounds()', 'EXECUTE')
  and has_function_privilege('authenticated', 'fabula.expected_yield(uuid, uuid, uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'fabula.expected_yield(uuid, uuid, uuid)', 'EXECUTE'));
select pg_temp.ck('1d the limits trigger is still BEFORE INSERT OR UPDATE of milk_in_kg, output_kg, yield_note',
  (select pg_get_triggerdef(oid) from pg_trigger where tgrelid = 'fabula.production_batches'::regclass and tgname = 'batch_yield_bounds')
    like '%BEFORE INSERT OR UPDATE OF milk_in_kg, output_kg, yield_note%trg_batch_bounds()%');
select pg_temp.ck('1e the data lines of v1.18a touch no row on a fresh replay (the live rows STR-BUF-KG / SCA-BUF-KG are not seeded)',
  not exists (select 1 from fabula.products where sku in ('STR-BUF-KG', 'SCA-BUF-KG', 'SCA-BUF-AFF-KG')));

-- ============================== 2. the checks on the three columns ==============================
select pg_temp.st(format('update fabula.products set yield_min_pct = 70, yield_max_pct = 35 where id = %L', :'str')) c1 \gset
select pg_temp.st(format('update fabula.products set yield_min_pct = 50, yield_max_pct = 50, yield_expected_pct = 50 where id = %L', :'str')) c2 \gset
select pg_temp.st(format('update fabula.products set yield_expected_pct = 80 where id = %L', :'str')) c3 \gset
select pg_temp.st(format('update fabula.products set yield_expected_pct = 30 where id = %L', :'str')) c4 \gset
select pg_temp.st(format('update fabula.products set yield_max_pct = 101 where id = %L', :'plain')) c5 \gset
select pg_temp.st(format('update fabula.products set yield_min_pct = 0 where id = %L', :'plain')) c6 \gset
select pg_temp.st(format('update fabula.products set yield_expected_pct = -5 where id = %L', :'plain')) c7 \gset
select pg_temp.ck('2a minimum above the maximum is refused (check violation)', :'c1' = '23514', :'c1');
select pg_temp.ck('2b minimum equal to the maximum is refused', :'c2' = '23514', :'c2');
select pg_temp.ck('2c an expected yield above the maximum is refused', :'c3' = '23514', :'c3');
select pg_temp.ck('2d an expected yield below the minimum is refused', :'c4' = '23514', :'c4');
select pg_temp.ck('2e 101 %, 0 % and a negative value are refused', :'c5' = '23514' and :'c6' = '23514' and :'c7' = '23514', :'c5' || '/' || :'c6' || '/' || :'c7');
select pg_temp.ck('2f …and the stracciatella values are unchanged after the refusals (50 / 35 / 70)',
  (select (yield_expected_pct, yield_min_pct, yield_max_pct) = (50::numeric, 35::numeric, 70::numeric) from fabula.products where id = :'str'));
select pg_temp.st(format('update fabula.products set yield_expected_pct = 25 where id = %L', :'plain')) c8 \gset
select pg_temp.st(format('update fabula.products set yield_expected_pct = null where id = %L', :'plain')) c9 \gset
select pg_temp.ck('2g an expected yield alone (no limits) is accepted, and can be emptied again', :'c8' = '00000' and :'c9' = '00000', :'c8' || '/' || :'c9');

-- ============================== 3. the batch limits per product ==============================
select pg_temp.lot('L20990118-A', :'str', 300);
select pg_temp.err(pg_temp.close_sql('L20990118-A', 150)) e_a \gset
select pg_temp.ck('3a stracciatella: 150 kg from 300 kg of milk (50 %, cream included) closes', :'e_a' = '' and
  (select output_kg from fabula.production_batches where batch_lot = 'L20990118-A') = 150, :'e_a');
select pg_temp.lot('L20990118-B', :'str', 300);
select pg_temp.err(pg_temp.close_sql('L20990118-B', 225)) e_b \gset
select pg_temp.ck('3b stracciatella: 75 % is refused with its own maximum (70 %)', :'e_b' = 'Resa 75 %: impossibile (al massimo 70 %). Controlla i kg di latte (300) e i kg prodotti (225).', :'e_b');
select pg_temp.err(pg_temp.close_sql('L20990118-B', 90)) e_c \gset
select pg_temp.ck('3c stracciatella: 30 % is below its own minimum (35 %): the reason of the loss is asked', :'e_c' like 'Resa 30 %: troppo bassa per un lotto normale (di solito almeno 35 %)%', :'e_c');
select pg_temp.err(pg_temp.close_sql('L20990118-B', 90, 'panna finita a metà lotto')) e_d \gset
select pg_temp.ck('3d …with the reason it closes', :'e_d' = '' and (select output_kg from fabula.production_batches where batch_lot = 'L20990118-B') = 90, :'e_d');
select pg_temp.lot('L20990118-C', :'moz', 300);
select pg_temp.err(pg_temp.close_sql('L20990118-C', 150)) e_e \gset
select pg_temp.ck('3e mozzarella: the same 50 % is still refused at the setting (45 %)', :'e_e' = 'Resa 50 %: impossibile (al massimo 45 %). Controlla i kg di latte (300) e i kg prodotti (150).', :'e_e');
select pg_temp.err(pg_temp.close_sql('L20990118-C', 90)) e_f \gset
select pg_temp.ck('3f mozzarella: a normal 30 % closes', :'e_f' = '', :'e_f');
-- a product minimum alone overrides the setting's minimum (10 %), the maximum stays the setting's
update fabula.products set yield_min_pct = 20 where id = :'sca';
select pg_temp.lot('L20990118-D', :'sca', 300);
select pg_temp.err(pg_temp.close_sql('L20990118-D', 45)) e_g \gset
select pg_temp.ck('3g scamorza with its own minimum 20 %: 15 % asks for the reason (the setting alone would let it through)', :'e_g' like 'Resa 15 %: troppo bassa per un lotto normale (di solito almeno 20 %)%', :'e_g');
select pg_temp.err(pg_temp.close_sql('L20990118-D', 150)) e_h \gset
select pg_temp.ck('3h …and with no maximum of its own, 50 % is refused at the setting (45 %)', :'e_h' like 'Resa 50 %: impossibile (al massimo 45 %)%', :'e_h');
select pg_temp.err(pg_temp.close_sql('L20990118-D', 75)) e_i \gset
select pg_temp.ck('3i …a normal 25 % closes', :'e_i' = '', :'e_i');
update fabula.products set yield_min_pct = null where id = :'sca';
-- whey: ricotta with no values keeps the ricotta settings; a value on the product takes over
select pg_temp.lot('R20990118-A', :'ric', 250, 'whey');
select pg_temp.err(pg_temp.close_sql('R20990118-A', 70)) e_j \gset
select pg_temp.ck('3j ricotta with no values: 28 % of the whey is refused at prod.ricotta_yield_max_pct (25 %), naming the whey',
  :'e_j' = 'Resa 28 %: impossibile (al massimo 25 %). Controlla i kg di siero (250) e i kg prodotti (70).', :'e_j');
update fabula.products set yield_max_pct = 30 where id = :'ric';
select pg_temp.err(pg_temp.close_sql('R20990118-A', 70)) e_k \gset
select pg_temp.ck('3k …with its own maximum 30 % the same 28 % closes', :'e_k' = '', :'e_k');
update fabula.products set yield_max_pct = null where id = :'ric';
select pg_temp.lot('R20990118-B', :'ric', 250, 'whey');
select pg_temp.err(pg_temp.close_sql('R20990118-B', 4)) e_l \gset
select pg_temp.ck('3l ricotta back to no values: 1,6 % is below prod.ricotta_yield_min_pct (2 %) as before', :'e_l' like 'Resa 1,6 %: troppo bassa%siero%', :'e_l');
-- a setting changed by a manager still moves the products that have no value of their own, and only those
update fabula.settings set value = '50' where key = 'prod.yield_max_pct';
select pg_temp.lot('L20990118-E', :'moz', 300);
select pg_temp.lot('L20990118-F', :'str', 300);
select pg_temp.err(pg_temp.close_sql('L20990118-E', 147)) e_m \gset
select pg_temp.err(pg_temp.close_sql('L20990118-F', 216)) e_n \gset
select pg_temp.ck('3m prod.yield_max_pct raised to 50 %: mozzarella 49 % closes', :'e_m' = '', :'e_m');
select pg_temp.ck('3n …stracciatella keeps its own 70 %: 72 % is still refused', :'e_n' like 'Resa 72 %: impossibile (al massimo 70 %)%', :'e_n');
update fabula.settings set value = '45' where key = 'prod.yield_max_pct';

-- ============================== 4. a product with no values behaves exactly as before ==============================
select pg_temp.lot('L20990118-G', :'plain', 300);
select pg_temp.err(pg_temp.close_sql('L20990118-G', 150)) e_o \gset
select pg_temp.err(pg_temp.close_sql('L20990118-G', 15)) e_p \gset
select pg_temp.err(pg_temp.close_sql('L20990118-G', 90)) e_q \gset
select pg_temp.ck('4a no values: 50 % refused at 45 %, 5 % asks the reason at 10 %, 30 % closes (the v0.98 behaviour)',
  :'e_o' like 'Resa 50 %: impossibile (al massimo 45 %)%' and :'e_p' like 'Resa 5 %: troppo bassa%(di solito almeno 10 %)%' and :'e_q' = '',
  :'e_o' || ' | ' || :'e_p' || ' | ' || :'e_q');
select pg_temp.err($q$select pg_temp.lot('L20990118-H', (select id from fabula.products where sku = 'T118-STR'), 3100)$q$) e_r \gset
select pg_temp.ck('4b the vat limit is untouched and applies to every product (3100 kg refused, stracciatella too)',
  :'e_r' like 'Latte in caldaia 3100 kg: una caldaia ne tiene al massimo 341 kg%' and not exists (select 1 from fabula.production_batches where batch_lot = 'L20990118-H'), :'e_r');
select pg_temp.ck('4c the closed stracciatella lot is flagged against its own expected 50 % (no «bassa» or «alta» at 50 %)',
  (select yield_expected_pct = 50 and yield_flag is null from fabula.production_batches where batch_lot = 'L20990118-A'));
select pg_temp.ck('4d the plain product''s lot is flagged against the default 30 % as before (30 % closes with no flag)',
  (select yield_expected_pct = fabula.setting_num('sales.yield_pct', 30) and yield_flag is null from fabula.production_batches where batch_lot = 'L20990118-G'));

-- ============================== 5. expected_yield ==============================
select fabula.expected_yield(:'plain') ey_plain \gset
select fabula.expected_yield(:'sca') ey_sca \gset
select fabula.expected_yield(:'ric') ey_ric \gset
select pg_temp.ck('5a a product with its own value and fewer than 3 lots: that value, source «default_product» (the tablet shows «stimata»)',
  (:'ey_sca'::jsonb ->> 'pct')::numeric = 25 and :'ey_sca'::jsonb ->> 'source' = 'default_product' and (:'ey_sca'::jsonb ->> 'n')::int = 1, :'ey_sca');
select pg_temp.ck('5b a product with no value: the default as before (sales.yield_pct, source «default»)',
  (:'ey_plain'::jsonb ->> 'pct')::numeric = fabula.setting_num('sales.yield_pct', 30) and :'ey_plain'::jsonb ->> 'source' = 'default', :'ey_plain');
select pg_temp.ck('5c ricotta (a by-product) with no value: prod.ricotta_yield_pct, source «default_byproduct» as before',
  (:'ey_ric'::jsonb ->> 'pct')::numeric = fabula.setting_num('prod.ricotta_yield_pct', 10) and :'ey_ric'::jsonb ->> 'source' = 'default_byproduct', :'ey_ric');
update fabula.products set yield_expected_pct = 12 where id = :'ric';
select fabula.expected_yield(:'ric') ey_ric2 \gset
select pg_temp.ck('5d a by-product with its own value: the product value wins over prod.ricotta_yield_pct', (:'ey_ric2'::jsonb ->> 'pct')::numeric = 12 and :'ey_ric2'::jsonb ->> 'source' = 'default_product', :'ey_ric2');
update fabula.products set yield_expected_pct = null where id = :'ric';
-- stracciatella has 2 closed lots (A 50 %, B 30 %; F was refused and stays open): a third one makes its own average take over
select pg_temp.lot('L20990118-J', :'str', 300);
select pg_temp.err(pg_temp.close_sql('L20990118-J', 138)) e_s \gset
select fabula.expected_yield(:'str') ey_str \gset
select pg_temp.ck('5e with 3 lots of its own in 30 days the product''s average wins over its value (source «avg_30d», (50+30+46)/3 = 42)',
  :'e_s' = '' and :'ey_str'::jsonb ->> 'source' = 'avg_30d' and (:'ey_str'::jsonb ->> 'pct')::numeric = 42 and (:'ey_str'::jsonb ->> 'n')::int = 3, :'ey_str');
select fabula.expected_yield(:'str', null, (select id from fabula.production_batches where batch_lot = 'L20990118-J')) ey_str_x \gset
select pg_temp.ck('5f …excluding one of the 3 (the lot being closed) falls back to the product value again',
  :'ey_str_x'::jsonb ->> 'source' = 'default_product' and (:'ey_str_x'::jsonb ->> 'pct')::numeric = 50, :'ey_str_x');
-- a preset with 3 lots of its own wins over everything
insert into fabula.process_presets (product_id, name) values (:'sca', 'Scamorza T118 affumicata') returning id preset \gset
select pg_temp.lot('L20990118-K', :'sca', 300, 'milk', :'preset');
select pg_temp.lot('L20990118-L', :'sca', 300, 'milk', :'preset');
select pg_temp.lot('L20990118-M', :'sca', 300, 'milk', :'preset');
select pg_temp.err(pg_temp.close_sql('L20990118-K', 66)) e_t1 \gset
select pg_temp.err(pg_temp.close_sql('L20990118-L', 66)) e_t2 \gset
select pg_temp.err(pg_temp.close_sql('L20990118-M', 66)) e_t3 \gset
select fabula.expected_yield(:'sca', :'preset') ey_pre \gset
select pg_temp.ck('5g a preset with 3 lots wins over the product value (source «preset», 22 %)',
  :'e_t1' || :'e_t2' || :'e_t3' = '' and :'ey_pre'::jsonb ->> 'source' = 'preset' and (:'ey_pre'::jsonb ->> 'pct')::numeric = 22, :'ey_pre');
select pg_temp.ck('5h the tolerance is the setting''s, whatever the source', (:'ey_pre'::jsonb ->> 'tolerance_pts')::numeric = fabula.setting_num('prod.yield_tolerance_pts', 4)
  and (:'ey_sca'::jsonb ->> 'tolerance_pts')::numeric = fabula.setting_num('prod.yield_tolerance_pts', 4));
