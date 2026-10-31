-- v0.93d audit fixes, wholesale (TRADE-02/E-15, D-14, B-20/D-10, PRINT-01) · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh tw_test
--   su postgres -c "psql -d tw_test -f tools/go-live/drill/prod-test/test_audit_wholesale.sql" | grep -E "PASS|FAIL"
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as
$$ begin execute p_sql; return ''; exception when others then return sqlerrm; end $$;
-- the n-th delivery day at least 3 days ahead, so customers can still change it, and one of the audit customer's own days
-- (Mon–Sat, below). v1.22a: since Sunday is a delivery day too, a delivery day alone could be a Sunday the customer has no plan for.
create or replace function pg_temp.dday(n int) returns date language sql as
$$ select g::date from generate_series(fabula.trade_now_rome()::date + 3, fabula.trade_now_rome()::date + 20, interval '1 day') g
   where fabula.trade_is_delivery_day(g::date)
     and exists (select 1 from fabula.trade_schedule_days d where d.customer_id = '50000000-0000-4000-a000-000000000001'
                 and d.active and d.weekday = extract(isodow from g)::int)
   order by g offset n - 1 limit 1 $$;
select id moz from fabula.products where sku = 'MOZ-DOP-KG' \gset
insert into fabula.parties (id, type, legal_name, phone, active, trade_status) values ('50000000-0000-4000-a000-000000000001', 'customer', 'Pizzeria Audit', '+39 333 0000000', true, 'approved');
insert into fabula.trade_products (variant_id, product_id, title, variant_title, kg_per_unit, unit_label, trade_price_eur, min_qty, step_qty)
values ('gid://audit/1', :'moz', 'Mozzarella', 'ristorazione', 1, 'kg', 11.5, 1, 1);
insert into fabula.trade_schedules (customer_id, status, start_date) values ('50000000-0000-4000-a000-000000000001', 'active', current_date - 7);
insert into fabula.trade_schedule_days (customer_id, weekday, active) select '50000000-0000-4000-a000-000000000001', w, true from generate_series(1, 6) w;
insert into fabula.trade_schedule_lines (customer_id, weekday, variant_id, qty) select '50000000-0000-4000-a000-000000000001', w, 'gid://audit/1', 4 from generate_series(1, 6) w;
select pg_temp.dday(1) d1, pg_temp.dday(2) d2, pg_temp.dday(3) d3 \gset

-- 14 · a one-day change under the minimum (3 kg) is refused, with the reason; at the minimum it saves
select pg_temp.err(format($q$select fabula.trade_add_exception('50000000-0000-4000-a000-000000000001', '{"kind":"override","date_from":"%s","variant_id":"gid://audit/1","qty":2}'::jsonb)$q$, :'d1')) e1 \gset
select pg_temp.ck('override to 2 kg (minimum 3 kg) is refused and says why', :'e1' like '%scende a 2 kg, sotto il minimo d''ordine di 3 kg%', :'e1');
select pg_temp.ck('…and nothing was saved', not exists (select 1 from fabula.trade_exceptions where customer_id = '50000000-0000-4000-a000-000000000001' and kind = 'override' and cancelled_at is null));
select pg_temp.err(format($q$select fabula.trade_add_exception('50000000-0000-4000-a000-000000000001', '{"kind":"override","date_from":"%s","variant_id":"gid://audit/1","qty":3}'::jsonb)$q$, :'d1')) e2 \gset
select pg_temp.ck('override to 3 kg saves', :'e2' = '', :'e2');
select pg_temp.err(format($q$select fabula.trade_add_exception('50000000-0000-4000-a000-000000000001', '{"kind":"override","date_from":"%s","variant_id":"gid://audit/1","qty":0}'::jsonb)$q$, :'d1')) e3 \gset
select pg_temp.ck('removing the only product (0 kg = no delivery) is still allowed', :'e3' = '', :'e3');

-- 15 · cut-off messages read correctly
select pg_temp.err($q$select fabula.trade_add_exception('50000000-0000-4000-a000-000000000001', jsonb_build_object('kind','skip','date_from', fabula.trade_now_rome()::date))$q$) e4 \gset
select pg_temp.ck('cut-off message has no stray "s"', :'e4' = format('La consegna del %s è già confermata (modifiche entro le 18:00 del giorno prima)', to_char(fabula.trade_now_rome()::date, 'DD/MM')), :'e4');
select (fabula.trade_add_exception('50000000-0000-4000-a000-000000000001', jsonb_build_object('kind','window','date_from', fabula.trade_now_rome()::date, 'window', '09:00-11:00'), 'staff', true)->>'id') wid \gset
select pg_temp.err(format($q$select fabula.trade_cancel_exception('50000000-0000-4000-a000-000000000001', '%s')$q$, :'wid')) e5 \gset
select pg_temp.ck('cancel message has no stray "s"', :'e5' = format('La consegna del %s è già confermata', to_char(fabula.trade_now_rome()::date, 'DD/MM')), :'e5');

-- 16 · a booked day: «Salta» by staff cancels the order and its Shopify queue entry; another change is refused
select fabula.confirm_standing_orders(:'d2'::date) b1 \gset
select order_number booked from fabula.sales_orders where customer_id = '50000000-0000-4000-a000-000000000001' and order_date = :'d2'::date and status = 'confirmed' \gset
select pg_temp.ck('setup: the day is booked as an order with a pending Shopify entry',
  :'booked' like 'WS-%' and exists (select 1 from fabula.trade_order_queue q join fabula.sales_orders o on o.id = q.sales_order_id where o.order_number = :'booked' and q.status = 'pending'), :'b1');
select pg_temp.err(format($q$select fabula.trade_add_exception('50000000-0000-4000-a000-000000000001', '{"kind":"override","date_from":"%s","variant_id":"gid://audit/1","qty":6}'::jsonb, 'staff', true)$q$, :'d2')) e6 \gset
select pg_temp.ck('a quantity change on a booked day is refused and says what to do', :'e6' like '%già prenotata (ordine WS-%«Salta»%', :'e6');
select fabula.trade_add_exception('50000000-0000-4000-a000-000000000001', jsonb_build_object('kind','skip','date_from', :'d2'::date), 'staff', true) r7 \gset
select pg_temp.ck('«Salta» on a booked day cancels the order', (select status::text from fabula.sales_orders where order_number = :'booked') = 'cancelled', :'r7');
select pg_temp.ck('…and its Shopify queue entry', (select q.status from fabula.trade_order_queue q join fabula.sales_orders o on o.id = q.sales_order_id where o.order_number = :'booked') = 'skipped');
select pg_temp.ck('…and the customer log names the cancelled order',
  exists (select 1 from fabula.trade_change_log where customer_id = '50000000-0000-4000-a000-000000000001' and message_it like '%Ordine già prenotato ' || :'booked' || ' annullato.%'));

-- 14 (booking) · a day still under the minimum at 18:20 is not booked, and both the customer and the office are told, once
update fabula.trade_schedule_lines set qty = 2 where customer_id = '50000000-0000-4000-a000-000000000001' and weekday = extract(isodow from :'d3'::date);
select fabula.confirm_standing_orders(:'d3'::date) b2 \gset
select fabula.confirm_standing_orders(:'d3'::date) b3 \gset
select pg_temp.ck('under the minimum: not booked, reported with the phone', jsonb_array_length(:'b2'::jsonb->'under_minimum') = 1 and (:'b2'::jsonb->'under_minimum'->0->>'phone') is not null, :'b2');
select pg_temp.ck('…the customer reads it in the portal log (once)',
  (select count(*) from fabula.trade_change_log where customer_id = '50000000-0000-4000-a000-000000000001' and action = 'under_minimum' and details->>'date' = :'d3') = 1);
select pg_temp.ck('…the office gets a warning in the Bot feed',
  exists (select 1 from fabula.bot_messages where agent = 'wholesale_orders' and severity = 'warn' and title like '%NON prenotata: Pizzeria Audit'));

-- 17 · the DDT view carries the delivery fields of the order
select pg_temp.err($q$select delivery_address, delivery_window, delivery_instructions, po_number from fabula.v_shipment_doc limit 1$q$) e8 \gset
select pg_temp.ck('v_shipment_doc has delivery address, window, instructions and PO number', :'e8' = '', :'e8');
select pg_temp.ck('v_shipment_doc keeps security_invoker', (select reloptions::text from pg_class where oid = 'fabula.v_shipment_doc'::regclass) like '%security_invoker=true%');
