-- v0.71 packing on autopilot · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh pack_test
--   su postgres -c "psql -d pack_test -f tools/go-live/drill/prod-test/test_packing.sql" | grep -E "PASS|FAIL"
-- Stock: A expires tomorrow (5 kg), B in 4 days (8 kg), C on food-safety hold (10 kg), X expired yesterday (3 kg).
-- Orders: S1 online, due yesterday (late), 5 kg · W1 wholesale today 6 kg · W2 wholesale tomorrow 4 kg.
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;

select (now() at time zone 'Europe/Rome')::date d \gset
select id moz from fabula.products where sku = 'MOZ-DOP-KG' \gset
insert into fabula.parties (type, legal_name) values ('customer', 'Pizzeria Test') returning id cust \gset
insert into fabula.stock_moves (product_id, lot_number, expiry_date, qty, move_type, source) values
 (:'moz', 'LT-A', :'d'::date + 1, 5, 'production_out', 'test'),
 (:'moz', 'LT-B', :'d'::date + 4, 8, 'production_out', 'test'),
 (:'moz', 'LT-C', :'d'::date + 5, 10, 'production_out', 'test'),
 (:'moz', 'LT-X', :'d'::date - 1, 3, 'production_out', 'test');
insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, output_kg, food_safety_hold, hold_reason, source)
values (:'d', 'LT-C', :'moz', 30, 10, true, 'esito laboratorio in attesa', 'test');
insert into fabula.sales_orders (order_number, channel, order_date, customer_id, status, source) values
 ('S1-TEST', 'shopify', :'d'::date - 1, null, 'confirmed', 'test'),
 ('W1-TEST', 'wholesale', :'d', :'cust', 'confirmed', 'test'),
 ('W2-TEST', 'wholesale', :'d'::date + 1, :'cust', 'confirmed', 'test');
insert into fabula.sales_order_lines (sales_order_id, product_id, qty, unit_price_eur, iva_rate)
select id, :'moz', case order_number when 'S1-TEST' then 5 when 'W1-TEST' then 6 else 4 end, 12, 4 from fabula.sales_orders where order_number like '%-TEST';

-- 1. the plan
select fabula.packing_plan() p \gset
create temp table pl as select x.value o, ord from jsonb_array_elements(:'p'::jsonb->'orders') with ordinality x(value, ord) where x.value->>'order_number' like '%-TEST';
select pg_temp.ck('order: late online first, then today''s wholesale, then tomorrow''s',
  (select array_agg(o->>'order_number' order by ord) from pl) = array['S1-TEST', 'W1-TEST', 'W2-TEST'], (select string_agg(o->>'order_number' || ' late ' || (o->>'late_days'), ', ' order by ord) from pl));
select pg_temp.ck('S1 online: A skipped (expires tomorrow, online needs 2 days) → 5 kg from B',
  (select o#>'{lines,0,alloc}' from pl where o->>'order_number' = 'S1-TEST') = jsonb_build_array(jsonb_build_object('lot', 'LT-B', 'qty', 5, 'expiry', :'d'::date + 4, 'on_hand', 8))
  and (select (o->>'late_days')::int = 1 from pl where o->>'order_number' = 'S1-TEST'),
  (select (o#>'{lines,0,alloc}')::text from pl where o->>'order_number' = 'S1-TEST'));
select pg_temp.ck('W1 wholesale: oldest lot first, split A 5 + B 1',
  (select array_agg((a->>'lot') || '=' || trim_scale((a->>'qty')::numeric)) from pl, jsonb_array_elements(o#>'{lines,0,alloc}') a where o->>'order_number' = 'W1-TEST') = array['LT-A=5', 'LT-B=1'],
  (select (o#>'{lines,0,alloc}')::text from pl where o->>'order_number' = 'W1-TEST'));
select pg_temp.ck('W2: only 2 kg left on B after the earlier orders → 2 kg short (no double promise)',
  (select (o#>>'{lines,0,short_kg}')::numeric = 2 and (o->>'short_kg')::numeric = 2 from pl where o->>'order_number' = 'W2-TEST'),
  (select (o#>'{lines,0}')::text from pl where o->>'order_number' = 'W2-TEST'));
select pg_temp.ck('held C and expired X never allocated, listed as blocked with the reason',
  (select jsonb_agg(b->>'lot' || ':' || (b->>'reason') order by b->>'lot') from pl, jsonb_array_elements(o#>'{lines,0,blocked}') b where o->>'order_number' = 'W1-TEST') = '["LT-C:held", "LT-X:expired"]'::jsonb
  and not exists (select 1 from pl, jsonb_array_elements(o#>'{lines,0,alloc}') a where a->>'lot' in ('LT-C', 'LT-X')));
select pg_temp.ck('pick list for the cold room: A 5 kg (W1), B 8 kg (S1, W1, W2)',
  (select jsonb_agg((x->>'lot') || '=' || trim_scale((x->>'kg')::numeric) || ':' || (x->'orders')::text order by x->>'lot') from jsonb_array_elements(:'p'::jsonb->'pick') x where x->>'lot' like 'LT-%')
   = '["LT-A=5:[\"W1-TEST\"]", "LT-B=8:[\"S1-TEST\", \"W1-TEST\", \"W2-TEST\"]"]'::jsonb,
  (select string_agg((x->>'lot') || '=' || (x->>'kg') || (x->'orders')::text, ' ') from jsonb_array_elements(:'p'::jsonb->'pick') x));

-- 2. pack_order guards
select id w1 from fabula.sales_orders where order_number = 'W1-TEST' \gset
select id s1 from fabula.sales_orders where order_number = 'S1-TEST' \gset
do $$ begin perform fabula.pack_order((select id from fabula.sales_orders where order_number = 'W1-TEST'),
  jsonb_build_array(jsonb_build_object('product_id', (select id from fabula.products where sku = 'MOZ-DOP-KG'), 'lot_number', 'LT-C', 'qty', 6)), null, null, null, null, null, true);
  raise notice 'RESULT held: shipped'; exception when others then raise notice 'RESULT held: %', sqlerrm; end $$;
select pg_temp.ck('held lot refused even with confirm', not exists (select 1 from fabula.shipments where sales_order_id = :'w1'));
do $$ begin perform fabula.pack_order((select id from fabula.sales_orders where order_number = 'W1-TEST'),
  jsonb_build_array(jsonb_build_object('product_id', (select id from fabula.products where sku = 'MOZ-DOP-KG'), 'lot_number', 'LT-X', 'qty', 3)), null, null, null, null, null, true);
  exception when others then null; end $$;
select pg_temp.ck('expired lot refused even with confirm', not exists (select 1 from fabula.shipments where sales_order_id = :'w1'));
select fabula.pack_order(:'s1', jsonb_build_array(jsonb_build_object('product_id', :'moz', 'lot_number', 'LT-A', 'qty', 5)), null) r1 \gset
select pg_temp.ck('online order on a lot expiring tomorrow: asks to confirm with the reason', (:'r1'::jsonb->>'needs_confirm')::boolean and :'r1'::jsonb->>'reasons' like '%LT-A scade il%minimo 2 giorni%', :'r1'::jsonb->>'reasons');
select fabula.pack_order(:'s1', jsonb_build_array(jsonb_build_object('product_id', :'moz', 'lot_number', 'LT-B', 'qty', 9)), null) r2 \gset
select pg_temp.ck('more than the lot holds + weight off: two reasons, nothing saved',
  (:'r2'::jsonb->>'needs_confirm')::boolean and jsonb_array_length(:'r2'::jsonb->'reasons') = 2 and not exists (select 1 from fabula.shipments where sales_order_id = :'s1'), :'r2'::jsonb->>'reasons');
select fabula.pack_order(:'w1', jsonb_build_array(jsonb_build_object('product_id', :'moz', 'lot_number', 'LT-A', 'qty', 5), jsonb_build_object('product_id', :'moz', 'lot_number', 'LT-B', 'qty', 1.05)), null) r3 \gset
select pg_temp.ck('W1 packed from the plan (A 5 + B 1.05): DDT, two lines, stock moved, order fulfilled',
  (:'r3'::jsonb->>'ok')::boolean and (select count(*) from fabula.shipment_lines sl join fabula.shipments s on s.id = sl.shipment_id where s.sales_order_id = :'w1') = 2
  and (select qty_on_hand from fabula.v_stock_on_hand where lot_number = 'LT-A') is null
  and (select status::text from fabula.sales_orders where id = :'w1') = 'fulfilled', :'r3');
select fabula.pack_order(:'s1', jsonb_build_array(jsonb_build_object('product_id', :'moz', 'lot_number', 'LT-B', 'qty', 9)), null, null, null, null, null, true) r4 \gset
select pg_temp.ck('second Salva (confirm) saves and records what was confirmed on the shipment; guest order gets a consignee',
  (:'r4'::jsonb->>'ok')::boolean and (select p.legal_name from fabula.sales_orders so join fabula.parties p on p.id = so.customer_id where so.id = :'s1') = 'Cliente online S1-TEST' and (select notes from fabula.shipments where sales_order_id = :'s1') like 'Confermato:%giacenza%', (select notes from fabula.shipments where sales_order_id = :'s1'));

-- 3. after packing the plan moves on
select pg_temp.ck('packed orders leave the plan; W2 now short of 4 kg (B is used up)',
  (select count(*) from jsonb_array_elements(fabula.packing_plan()->'orders') x where x->>'order_number' like '%-TEST') = 1
  and (select (x->>'short_kg')::numeric from jsonb_array_elements(fabula.packing_plan()->'orders') x where x->>'order_number' = 'W2-TEST') = 4);
select pg_temp.ck('grants: signed-in users can read the plan, anonymous cannot',
  has_function_privilege('authenticated', 'fabula.packing_plan(date)', 'execute') and not has_function_privilege('anon', 'fabula.packing_plan(date)', 'execute'));
