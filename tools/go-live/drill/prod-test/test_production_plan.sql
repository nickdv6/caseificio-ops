-- v0.70 production autopilot · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh prod_test
--   su postgres -c "psql -d prod_test -f tools/go-live/drill/prod-test/test_production_plan.sql" | grep -E "PASS|FAIL"
-- Runs as the database owner (no signed-in user = full access), so it tests the logic; grants are checked at the end.
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;

select (now() at time zone 'Europe/Rome')::date d \gset
insert into fabula.parties (type, legal_name, is_milk_supplier) values ('supplier', 'Masseria Test', true) returning id sup \gset
-- milk on hand: 250 kg yesterday (small), 1,150 kg today, one rejected delivery, one delivery already used up
insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, source) values
 (:'d'::date - 1, '07:00', :'sup', 'MT-OLD', 250, true, 'test'),
 (:'d'::date,     '06:30', :'sup', 'MT-NEW', 1150, true, 'test'),
 (:'d'::date,     '06:40', :'sup', 'MT-BAD', 300, false, 'test'),
 (:'d'::date - 1, '06:00', :'sup', 'MT-USED', 400, true, 'test');
insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, output_kg, started_at, finished_at, source)
values (:'d'::date - 1, 'LTEST-USED', (select id from fabula.products where sku = 'MOZ-DOP-KG'), 400, null, now() - interval '20 hours', null, 'test') returning id used_b \gset
insert into fabula.batch_milk_inputs (batch_id, milk_intake_id, qty_kg) values (:'used_b', (select id from fabula.milk_intake where milk_lot = 'MT-USED'), 400);
insert into fabula.milk_plans (plan_date, milk_kg, planned_output_kg, status) values (:'d', 1400, 420, 'approved');

-- 1. the plan
select fabula.production_plan() p1 \gset
select pg_temp.ck('milk on hand: only accepted lots with kg left, oldest first',
  (select array_agg(x->>'milk_lot' order by ord) from jsonb_array_elements(:'p1'::jsonb->'milk') with ordinality t(x, ord)) = array['MT-OLD', 'MT-NEW'],
  (select string_agg(x->>'milk_lot' || ' ' || (x->>'left_kg'), ', ') from jsonb_array_elements(:'p1'::jsonb->'milk') x));
select pg_temp.ck('proposals: 250 kg (small) then 1,150 kg split in two equal vat loads',
  (select array_agg((x->>'milk_kg')::numeric order by (x->>'seq')::int) from jsonb_array_elements(:'p1'::jsonb->'proposals') x) = array[250, 575, 575]::numeric[]
  and (select (x->>'small')::boolean from jsonb_array_elements(:'p1'::jsonb->'proposals') x where (x->>'seq')::int = 1)
  and not (select (x->>'small')::boolean from jsonb_array_elements(:'p1'::jsonb->'proposals') x where (x->>'seq')::int = 2));
select pg_temp.ck('mozzarella with its default preset and 30 % default yield → 172.5 kg from 575 kg',
  (select x->>'product' like 'Mozzarella%' and x->>'preset' = 'Base · prova 29/09' and (x->>'yield_pct')::numeric = 30 and x->>'yield_source' = 'default'
          and (x->>'expected_kg')::numeric = 172.5 from jsonb_array_elements(:'p1'::jsonb->'proposals') x where (x->>'seq')::int = 2));
select pg_temp.ck('start doses from the recipe for 575 kg (rennet 0.144, salt 1.61)',
  (select jsonb_agg(d->>'sku' || '=' || (d->>'qty')::numeric order by d->>'sku') from jsonb_array_elements(:'p1'::jsonb->'proposals') x, jsonb_array_elements(x->'doses') d
    where (x->>'seq')::int = 2) = '["CON-RENNET=0.144", "CON-SALT=1.610"]'::jsonb,
  (select (x->'doses')::text from jsonb_array_elements(:'p1'::jsonb->'proposals') x where (x->>'seq')::int = 2));
select pg_temp.ck('whey and ricotta expected (62 % whey, 10 % ricotta)',
  (select (x->>'whey_kg')::numeric = 357 and (x->>'ricotta_kg')::numeric = 35.7 from jsonb_array_elements(:'p1'::jsonb->'proposals') x where (x->>'seq')::int = 2));
select pg_temp.ck('60 h DOP deadline from arrival (06:30 + 60 h)',
  (select (x->>'use_by')::timestamptz = ((:'d'::date + time '06:30') at time zone 'Europe/Rome') + interval '60 hours' from jsonb_array_elements(:'p1'::jsonb->'milk') x where x->>'milk_lot' = 'MT-NEW'));
select pg_temp.ck('target from the approved milk plan; open batch listed with its expected kg; total expected',
  (:'p1'::jsonb#>>'{target,planned_output_kg}')::numeric = 420
  and (select (x->>'expected_kg')::numeric = 120 from jsonb_array_elements(:'p1'::jsonb->'open') x where x->>'batch_lot' = 'LTEST-USED')
  and (:'p1'::jsonb->>'expected_kg')::numeric = 420, :'p1'::jsonb->>'expected_kg');

-- 2. a batch started from a proposal takes its milk out of the plan
insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, preset_id, started_at, source)
values (:'d', 'LTEST-A', (select id from fabula.products where sku = 'MOZ-DOP-KG'), 575, (select id from fabula.process_presets where name = 'Base · prova 29/09'), now(), 'tablet') returning id ba \gset
insert into fabula.batch_milk_inputs (batch_id, milk_intake_id, qty_kg) values (:'ba', (select id from fabula.milk_intake where milk_lot = 'MT-NEW'), 575);
select fabula.production_plan() p2 \gset
select pg_temp.ck('after one start: 575 kg left on MT-NEW → one proposal of 575, batch open',
  (select array_agg((x->>'milk_kg')::numeric order by (x->>'seq')::int) from jsonb_array_elements(:'p2'::jsonb->'proposals') x) = array[250, 575]::numeric[]
  and exists (select 1 from jsonb_array_elements(:'p2'::jsonb->'open') x where x->>'batch_lot' = 'LTEST-A'));

-- 3. yield check at close
update fabula.production_batches set output_kg = 172, finished_at = now() where id = :'ba';
select pg_temp.ck('normal yield (29.9 %): expected 30 stored, no flag, no message',
  (select yield_expected_pct = 30 and yield_flag is null from fabula.production_batches where id = :'ba')
  and not exists (select 1 from fabula.bot_messages where agent = 'produzione'));
insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, preset_id, started_at, source)
values (:'d', 'LTEST-B', (select id from fabula.products where sku = 'MOZ-DOP-KG'), 575, (select id from fabula.process_presets where name = 'Base · prova 29/09'), now(), 'tablet') returning id bb \gset
update fabula.production_batches set output_kg = 120, finished_at = now() where id = :'bb';
select pg_temp.ck('low yield (20.9 %): flagged bassa and one message from Zio Ciro',
  (select yield_flag = 'bassa' from fabula.production_batches where id = :'bb')
  and (select count(*) from fabula.bot_messages where agent = 'produzione' and title like 'Resa bassa lotto LTEST-B: 20.9% (attesa 30%)') = 1,
  (select string_agg(title, ' | ') from fabula.bot_messages where agent = 'produzione'));
update fabula.production_batches set notes = 'x' where id = :'bb';
update fabula.production_batches set output_kg = 120 where id = :'bb';
select pg_temp.ck('editing the batch again does not repeat the message', (select count(*) from fabula.bot_messages where agent = 'produzione') = 1);
update fabula.production_batches set output_kg = 210 where id = :'bb';
select pg_temp.ck('corrected kg (36.5 %): flag becomes alta, new message', (select yield_flag from fabula.production_batches where id = :'bb') = 'alta'
  and (select count(*) from fabula.bot_messages where agent = 'produzione') = 2);
update fabula.production_batches set output_kg = 171 where id = :'bb';
select pg_temp.ck('corrected again into range: flag cleared', (select yield_flag is null from fabula.production_batches where id = :'bb'));
insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, output_kg, source)
values (:'d', 'LTEST-SIM', (select id from fabula.products where sku = 'MOZ-DOP-KG'), 100, 5, 'simulation');
select pg_temp.ck('simulation batches are not checked',
  (select yield_flag is null and yield_expected_pct is null from fabula.production_batches where batch_lot = 'LTEST-SIM'));

-- 4. expected yield learns from real batches
insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, output_kg, preset_id, started_at, finished_at, source)
select :'d', 'LTEST-H' || g, (select id from fabula.products where sku = 'MOZ-DOP-KG'), 500, 160, (select id from fabula.process_presets where name = 'Base · prova 29/09'), now(), now() + g * interval '1 minute', 'tablet'
from generate_series(1, 3) g;
select fabula.expected_yield((select id from fabula.products where sku = 'MOZ-DOP-KG'), (select id from fabula.process_presets where name = 'Base · prova 29/09')) ey \gset
select pg_temp.ck('with 3+ batches on the preset: average of its last 10 (preset)', :'ey'::jsonb->>'source' = 'preset' and (:'ey'::jsonb->>'n')::int = 5, :'ey');
select pg_temp.ck('ricotta default 10 % (by-product)', (fabula.expected_yield((select id from fabula.products where sku = 'RIC-BUF-KG'))->>'pct')::numeric = 10
  and fabula.expected_yield((select id from fabula.products where sku = 'RIC-BUF-KG'))->>'source' = 'default_byproduct');
select pg_temp.ck('done today summed for the main product',
  (select (x->>'batches')::int = 5 and (x->>'flags')::int = 0 from (select fabula.production_plan()->'done' x) y), (fabula.production_plan()->'done')::text);

-- 5. big delivery: 1,700 kg → 3 loads, exact total
insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, source) values (:'d', '08:00', :'sup', 'MT-BIG', 1700, true, 'test');
select pg_temp.ck('1,700 kg with an 800 kg vat → 3 loads summing to 1,700',
  (select count(*) = 3 and sum((x->>'milk_kg')::numeric) = 1700 and max((x->>'milk_kg')::numeric) <= 800 from jsonb_array_elements(fabula.production_plan()->'proposals') x where x->>'milk_lot' = 'MT-BIG'));

-- 6. grants
select pg_temp.ck('signed-in users can read the plan and the expected yield; anonymous cannot',
  has_function_privilege('authenticated', 'fabula.production_plan(date)', 'execute') and has_function_privilege('authenticated', 'fabula.expected_yield(uuid, uuid, uuid)', 'execute')
  and not has_function_privilege('anon', 'fabula.production_plan(date)', 'execute') and not has_function_privilege('anon', 'fabula.expected_yield(uuid, uuid, uuid)', 'execute')
  and not has_function_privilege('authenticated', 'fabula.trg_batch_yield_check()', 'execute'));
