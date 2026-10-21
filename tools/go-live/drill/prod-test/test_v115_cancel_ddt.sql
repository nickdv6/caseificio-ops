-- v1.15 · «Annulla DDT» · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh c_test
--   su postgres -c "psql -d c_test -f tools/go-live/drill/prod-test/test_v115_cancel_ddt.sql" | grep -E "PASS|FAIL"
-- A wholesale order packed from the wrong lot is annulled and packed again; an online order already fulfilled on Shopify is not;
-- the Shopify race; a direct shipment; what a login may not do by hand; the go-live and trial checks.
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as
$$ begin execute p_sql; return ''; exception when others then return sqlstate || ' ' || sqlerrm; end $$;
create or replace function pg_temp.as_user(p_sub text) returns void language sql as
$$ select set_config('request.jwt.claims', case when p_sub is null then '' else format('{"sub":"%s","role":"authenticated"}', p_sub) end, false) $$;
create or replace function pg_temp.lot(p_lot text) returns numeric language sql as
$$ select coalesce(sum(qty), 0) from fabula.stock_moves where lot_number = p_lot $$;

select (now() at time zone 'Europe/Rome')::date d \gset
select id moz from fabula.products where sku = 'MOZ-DOP-KG' \gset
insert into fabula.staff (id, full_name, role, app_role, active, auth_user_id) values
  ('10000000-0000-4000-a000-000000115a01', 'Titolare Annulla', 'owner', 'titolare', true, '00000000-0000-4000-a000-000000115a01'),
  ('10000000-0000-4000-a000-000000115a02', 'Casaro Annulla', 'casaro', 'produzione', true, '00000000-0000-4000-a000-000000115a02');
insert into fabula.parties (type, legal_name) values ('customer', 'Ristorante Annulla') returning id cust \gset
insert into fabula.stock_moves (product_id, lot_number, expiry_date, qty, move_type, source) values
 (:'moz', 'LV-A', :'d'::date + 6, 5, 'production_out', 'test'),
 (:'moz', 'LV-B', :'d'::date + 8, 20, 'production_out', 'test');
insert into fabula.sales_orders (order_number, channel, order_date, customer_id, status, source, shopify_order_id) values
 ('W-ANN', 'wholesale', :'d', :'cust', 'confirmed', 'test', null),
 ('S-ANN1', 'shopify', :'d', :'cust', 'confirmed', 'test', 'gid://shopify/Order/9001'),
 ('S-ANN2', 'shopify', :'d', :'cust', 'confirmed', 'test', 'gid://shopify/Order/9002');
insert into fabula.sales_order_lines (sales_order_id, product_id, qty, unit_price_eur, iva_rate)
select id, :'moz', case order_number when 'W-ANN' then 6 else 2 end, 12, 4 from fabula.sales_orders where order_number in ('W-ANN', 'S-ANN1', 'S-ANN2');
select id w from fabula.sales_orders where order_number = 'W-ANN' \gset
select id s1 from fabula.sales_orders where order_number = 'S-ANN1' \gset
select id s2 from fabula.sales_orders where order_number = 'S-ANN2' \gset

-- ============================== a wholesale order packed from the wrong lot ==============================
select fabula.pack_order(:'w', jsonb_build_array(jsonb_build_object('product_id', :'moz', 'lot_number', 'LV-A', 'qty', 5), jsonb_build_object('product_id', :'moz', 'lot_number', 'LV-B', 'qty', 1)),
  '10000000-0000-4000-a000-000000115a02', null, null, null, null, true) p1 \gset
select :'p1'::jsonb ->> 'shipment_id' sh1, :'p1'::jsonb ->> 'ddt_number' ddt1 \gset
select pg_temp.ck('packed: DDT numbered, stock down, order closed, lot on the order line',
  :'ddt1' like 'DDT-____-____' and pg_temp.lot('LV-A') = 0 and pg_temp.lot('LV-B') = 19
  and (select status::text from fabula.sales_orders where id = :'w') = 'fulfilled' and (select lot_number from fabula.sales_order_lines where sales_order_id = :'w') = 'LV-A'
  and (select (c ->> 'done')::boolean from jsonb_array_elements(fabula.ops_dashboard() -> 'checks') c where c ->> 'key' = 'first_shipment'), :'p1');

select pg_temp.ck('pack_order links its stock moves to the DDT (stock_moves.shipment_id)',
  (select count(*) from fabula.stock_moves where shipment_id = :'sh1' and move_type = 'sale' and qty < 0) = 2);

select pg_temp.as_user('00000000-0000-4000-a000-000000115a02');
set role authenticated;
select pg_temp.ck('a login can''t change, add or delete the lines of an issued DDT (review of v1.15: 4 kg became 40 and came back as stock)',
  pg_temp.err(format($$update fabula.shipment_lines set qty = 40 where shipment_id = %L$$, :'sh1')) like '42501%non si cambiano dopo l''emissione%'
  and pg_temp.err(format($$insert into fabula.shipment_lines (shipment_id, product_id, lot_number, qty) values (%L, %L, 'LV-B', 9)$$, :'sh1', :'moz')) like '42501%'
  and pg_temp.err(format($$delete from fabula.shipment_lines where shipment_id = %L$$, :'sh1')) like '42501%');
select pg_temp.ck('…nor write a DDT already annulled (in someone else''s name)',
  pg_temp.err(format($$insert into fabula.shipments (customer_id, status, cancelled_by_id, cancel_reason) values (%L, 'cancelled', '10000000-0000-4000-a000-000000115a01', 'finto')$$, :'cust')) like '42501%');
select pg_temp.ck('a production login (Spedizioni = registra) cannot annul a DDT',
  pg_temp.err(format($$select fabula.cancel_shipment(%L, 'lotto sbagliato')$$, :'sh1')) like '42501%', pg_temp.err(format($$select fabula.cancel_shipment(%L, 'lotto sbagliato')$$, :'sh1')));
select pg_temp.ck('…nor delete it: the message says where it is annulled',
  pg_temp.err(format($$delete from fabula.shipments where id = %L$$, :'sh1')) like '42501%Annulla DDT%');
select pg_temp.ck('…nor set it «cancelled» by hand (the goods would not go back to stock)',
  pg_temp.err(format($$update fabula.shipments set status = 'cancelled' where id = %L$$, :'sh1')) like '42501%si annulla solo con «Annulla DDT»%'
  and pg_temp.err(format($$update fabula.shipments set cancel_reason = 'x', cancelled_at = now() where id = %L$$, :'sh1')) like '42501%');
reset role;

-- even lines changed behind the app's back (here as the database owner) do not create stock: what comes back is what the DDT's moves took
update fabula.shipment_lines set qty = 40 where shipment_id = :'sh1' and lot_number = 'LV-A';
select pg_temp.as_user('00000000-0000-4000-a000-000000115a01');
set role authenticated;
select pg_temp.ck('a reason is required (at least 5 characters)',
  pg_temp.err(format($$select fabula.cancel_shipment(%L, ' no ')$$, :'sh1')) like '22023%Scrivi il motivo%');
select fabula.cancel_shipment(:'sh1', '  lotto   sbagliato: andava tutto dal LV-B ') c1 \gset
reset role;
select pg_temp.as_user(null);
select pg_temp.ck('the titolare annuls it: 6 kg back (what the DDT took, not the 40 kg a changed line says), the order is to ship again',
  (:'c1'::jsonb ->> 'ok')::boolean and (:'c1'::jsonb ->> 'lines_back')::int = 2 and (:'c1'::jsonb ->> 'kg_back')::numeric = 6
  and (:'c1'::jsonb ->> 'order_to_ship')::boolean and :'c1'::jsonb ->> 'ddt_number' = :'ddt1', :'c1');
select pg_temp.ck('the DDT keeps its number, «cancelled», with when, who and why (spaces tidied)',
  (select ddt_number = :'ddt1' and status::text = 'cancelled' and cancelled_at is not null and cancelled_by_id = '10000000-0000-4000-a000-000000115a01'
          and cancel_reason = 'lotto sbagliato: andava tutto dal LV-B' from fabula.shipments where id = :'sh1'));
select pg_temp.ck('stock back on its own lots: LV-A 5, LV-B 20, by «sale» moves with the opposite sign',
  pg_temp.lot('LV-A') = 5 and pg_temp.lot('LV-B') = 20
  and (select count(*) from fabula.stock_moves where source = 'ddt_annullato' and move_type = 'sale' and qty > 0 and sales_order_id = :'w' and reason like 'Annullato ' || :'ddt1' || ' · W-ANN: lotto sbagliato%') = 2);
select pg_temp.ck('the day''s sales net out (0 kg sold today), so the milk plan and the DOP declaration see no sale',
  (select -coalesce(sum(qty), 0) from fabula.stock_moves where move_type = 'sale' and product_id = :'moz' and (moved_at at time zone 'Europe/Rome')::date = :'d'::date) = 0);
select pg_temp.ck('the order is «confirmed» again, its line has no lot, and it is in «Da spedire» (v_orders_to_ship)',
  (select status::text from fabula.sales_orders where id = :'w') = 'confirmed' and (select lot_number from fabula.sales_order_lines where sales_order_id = :'w') is null
  and exists (select 1 from fabula.v_orders_to_ship where order_id = :'w'));
select pg_temp.ck('the annulled DDT is not in the lot distribution (recalls) and is not the «first real shipment»',
  not exists (select 1 from fabula.v_lot_distribution where ref = :'ddt1')
  and not (select (c ->> 'done')::boolean from jsonb_array_elements(fabula.ops_dashboard() -> 'checks') c where c ->> 'key' = 'first_shipment'));
select pg_temp.ck('the print page reads it as annulled, by whom and why',
  (select status = 'cancelled' and cancelled_by = 'Titolare Annulla' and cancel_reason like 'lotto sbagliato%' from fabula.v_shipment_doc where shipment_id = :'sh1'));
select pg_temp.ck('«Registro modifiche» has it (Spedizioni, by name)',
  exists (select 1 from fabula.audit_log where table_name = 'shipments' and row_key = :'sh1' and actor = 'Titolare Annulla' and new_data ->> 'status' = 'cancelled' and (new_data ->> 'kg_back')::numeric = 6));
select pg_temp.ck('annulling twice says when and why it already was',
  pg_temp.err(format($$select fabula.cancel_shipment(%L, 'di nuovo')$$, :'sh1')) like '22023%già annullato%lotto sbagliato%');

select pg_temp.as_user('00000000-0000-4000-a000-000000115a02');
set role authenticated;
select pg_temp.ck('an annulled DDT can''t be changed from a login (notes, tracking…)',
  pg_temp.err(format($$update fabula.shipments set notes = 'x' where id = %L$$, :'sh1')) like '42501%è annullato%');
reset role;
select pg_temp.as_user(null);

-- packed again, right: a new number, the old one not reused
select fabula.pack_order(:'w', jsonb_build_array(jsonb_build_object('product_id', :'moz', 'lot_number', 'LV-B', 'qty', 6)), '10000000-0000-4000-a000-000000115a02', null, null, null, null, true) p2 \gset
select pg_temp.ck('packed again: the next number in the series (the annulled one stays, not reused), one live DDT for the order',
  (:'p2'::jsonb ->> 'ok')::boolean and :'p2'::jsonb ->> 'ddt_number' > :'ddt1'
  and (select count(*) from fabula.shipments where sales_order_id = :'w') = 2 and (select count(*) from fabula.shipments where sales_order_id = :'w' and status::text = 'picked') = 1
  and pg_temp.lot('LV-A') = 5 and pg_temp.lot('LV-B') = 14, :'p2');
select pg_temp.ck('…and now the first real shipment is ticked, the distribution shows only the new DDT',
  (select (c ->> 'done')::boolean from jsonb_array_elements(fabula.ops_dashboard() -> 'checks') c where c ->> 'key' = 'first_shipment')
  and (select string_agg(ref, ',') from fabula.v_lot_distribution where ref like 'DDT-%') = :'p2'::jsonb ->> 'ddt_number');
insert into fabula.settings (key, value, data_type) values ('trial.start', to_char(:'d'::date - 2, 'YYYY-MM-DD'), 'text') on conflict (key) do update set value = excluded.value;
select pg_temp.ck('the trial''s day 3 counts only the live DDT',
  (select s ->> 'detail' from jsonb_array_elements(fabula.trial_check(:'d'::date) -> 'steps') s where s ->> 'step' like 'Giorno 3 · ordine preparato%') = '1 · DDT ' || (:'p2'::jsonb ->> 'ddt_number'),
  (select s::text from jsonb_array_elements(fabula.trial_check(:'d'::date) -> 'steps') s where s ->> 'step' like 'Giorno 3 · ordine preparato%'));

-- ============================== a DDT of another day: not annulled (wholesale and direct DDTs have no «partito» step) ==============================
select id sh_w2 from fabula.shipments where sales_order_id = :'w' and status::text = 'picked' \gset
update fabula.shipments set packed_at = packed_at - interval '1 day', created_at = created_at - interval '1 day' where id = :'sh_w2';
update fabula.stock_moves set moved_at = moved_at - interval '1 day' where shipment_id = :'sh_w2';
select pg_temp.ck('a DDT packed yesterday is not annulled: it may have been delivered (review of v1.15)',
  pg_temp.err(format($$select fabula.cancel_shipment(%L, 'consegnato male')$$, :'sh_w2')) like '22023%si annulla solo il giorno in cui è stato preparato%');
update fabula.shipments set packed_at = packed_at + interval '1 day', created_at = created_at + interval '1 day' where id = :'sh_w2';
update fabula.stock_moves set moved_at = moved_at + interval '1 day' where shipment_id = :'sh_w2';
-- a login can't bring an old DDT back to «today, not left»; and the day comes from the DDT's own stock moves anyway
select pg_temp.as_user('00000000-0000-4000-a000-000000115a02');
set role authenticated;
select pg_temp.ck('a login can''t move a DDT''s packing time, Shopify fulfilment or status back (second review: a delivered DDT revived and annulled)',
  pg_temp.err(format($$update fabula.shipments set packed_at = now() where id = %L$$, :'sh_w2')) like '42501%non tornano indietro%'
  and pg_temp.err(format($$update fabula.shipments set status = 'planned' where id = %L$$, :'sh_w2')) like '42501%'
  and pg_temp.err(format($$update fabula.shipments set shopify_fulfilled_at = now() - interval '1 day' where id = %L$$, :'sh_w2')) like '42501%');
reset role;
select pg_temp.as_user(null);
update fabula.stock_moves set moved_at = moved_at - interval '1 day' where shipment_id = :'sh_w2';
select pg_temp.ck('…and a DDT whose stock left yesterday is refused even with its packing time set to now (by the database owner)',
  pg_temp.err(format($$select fabula.cancel_shipment(%L, 'riprovo')$$, :'sh_w2')) like '22023%si annulla solo il giorno%');
update fabula.stock_moves set moved_at = moved_at + interval '1 day' where shipment_id = :'sh_w2';
-- a DDT with lines and no linked stock move (e.g. written before v1.15): not annulled, it can't say what to give back
insert into fabula.shipments (customer_id, status) values (:'cust', 'planned') returning id sh_p \gset
insert into fabula.shipment_lines (shipment_id, product_id, lot_number, qty) values (:'sh_p', :'moz', 'LV-B', 25);
select pg_temp.ck('a DDT with lines but no linked stock move is refused (it used to give back its 25 kg of lines, then nothing silently)',
  pg_temp.err(format($$select fabula.cancel_shipment(%L, 'creato per errore')$$, :'sh_p')) like '22023%non ha movimenti di magazzino collegati%');
insert into fabula.shipments (customer_id, status) values (:'cust', 'planned') returning id sh_e \gset
select fabula.cancel_shipment(:'sh_e', 'creato per errore') ce \gset
select pg_temp.ck('…an empty DDT (no lines, no stock) is annulled with nothing to give back', (:'ce'::jsonb ->> 'kg_back')::numeric = 0, :'ce');

-- ============================== goods that have left: not annulled ==============================
select fabula.pack_order(:'s1', jsonb_build_array(jsonb_build_object('product_id', :'moz', 'lot_number', 'LV-B', 'qty', 2)), null, null, null, null, null, true) ->> 'shipment_id' sh_s1 \gset
select fabula.mark_shopify_fulfilled(:'sh_s1', 'gid://shopify/Fulfillment/1') m1 \gset
select pg_temp.ck('an online order fulfilled on Shopify (in transit) is not annulled: it is a return',
  pg_temp.err(format($$select fabula.cancel_shipment(%L, 'cliente sbagliato')$$, :'sh_s1')) like '22023%già partita (evaso su Shopify il%è un reso%'
  and (select status::text from fabula.shipments where id = :'sh_s1') = 'in_transit');
update fabula.shipments set status = 'delivered', delivered_at = now() where id = (select id from fabula.shipments where sales_order_id = :'w' and status::text = 'picked');
select pg_temp.ck('a delivered DDT is not annulled either',
  pg_temp.err(format($$select fabula.cancel_shipment(%L, 'cliente sbagliato')$$, (select id from fabula.shipments where sales_order_id = :'w' and status::text = 'delivered'))) like '22023%già partita (consegnata)%');

-- ============================== the Shopify race ==============================
select fabula.pack_order(:'s2', jsonb_build_array(jsonb_build_object('product_id', :'moz', 'lot_number', 'LV-B', 'qty', 2)), null, null, null, null, null, true) ->> 'shipment_id' sh_s2 \gset
select fabula.cancel_shipment(:'sh_s2', 'il cliente ha annullato') c2 \gset
select pg_temp.ck('an online order annulled before the sync: still «confirmed» (online orders stay so until Shopify fulfils them), to ship again',
  (:'c2'::jsonb ->> 'order_to_ship')::boolean and (select status::text from fabula.sales_orders where id = :'s2') = 'confirmed'
  and not exists (select 1 from fabula.v_shipments_to_fulfill where shipment_id = :'sh_s2'::uuid), :'c2');
select fabula.mark_shopify_fulfilled(:'sh_s2', 'gid://shopify/Fulfillment/2') m2 \gset
select pg_temp.ck('if the sync fulfils it on Shopify just then: the DDT stays annulled, the order is not closed, and the office is told',
  :'m2' = 'cancelled' and (select status::text from fabula.shipments where id = :'sh_s2') = 'cancelled'
  and (select status::text from fabula.sales_orders where id = :'s2') = 'confirmed'
  and exists (select 1 from fabula.bot_messages where agent = 'shopify_orders' and severity = 'alert' and title = 'Ordine S-ANN2 evaso su Shopify, ma il suo DDT ' || (select ddt_number from fabula.shipments where id = :'sh_s2') || ' è annullato'));

-- ============================== a direct shipment from a lot (no order) ==============================
-- as the tablet's save does it: the DDT, its line and the stock move in one transaction, from a login
select pg_temp.as_user('00000000-0000-4000-a000-000000115a02');
begin;
set local role authenticated;
insert into fabula.shipments (customer_id, status, driver_id) values (:'cust', 'picked', '10000000-0000-4000-a000-000000115a02') returning id sh_d, ddt_number ddt_d \gset
insert into fabula.shipment_lines (shipment_id, product_id, lot_number, qty) values (:'sh_d', :'moz', 'LV-B', 3);
insert into fabula.stock_moves (product_id, lot_number, qty, move_type, source) values (:'moz', 'LV-B', -3, 'sale', 'tablet');
commit;
select pg_temp.as_user(null);
select pg_temp.ck('the direct shipment''s stock move is linked to its DDT by the database (same save, same product, lot and kg)',
  (select count(*) from fabula.stock_moves where shipment_id = :'sh_d' and qty = -3) = 1);
insert into fabula.stock_moves (product_id, lot_number, qty, move_type, source) values (:'moz', 'LV-B', -3, 'sale', 'tablet');
select pg_temp.ck('…a sale of the same kg in another save is not', (select count(*) from fabula.stock_moves where shipment_id = :'sh_d') = 1);
insert into fabula.stock_moves (product_id, lot_number, qty, move_type, source) values (:'moz', 'LV-B', 3, 'adjustment', 'test');
select pg_temp.lot('LV-B') before_d \gset
select fabula.cancel_shipment(:'sh_d', 'cliente sbagliato, era per un altro') c3 \gset
select pg_temp.ck('a direct shipment is annulled too: its 3 kg back on LV-B, no order to ship',
  pg_temp.lot('LV-B') = :'before_d'::numeric + 3 and (:'c3'::jsonb ->> 'order_number') is null and not (:'c3'::jsonb ->> 'order_to_ship')::boolean, :'c3');

-- ============================== the lot guard's split keeps the link ==============================
insert into fabula.stock_moves (product_id, lot_number, expiry_date, qty, move_type, source) values (:'moz', 'LV-S', :'d'::date + 3, 3, 'production_out', 'test');
begin;
insert into fabula.shipments (customer_id, status) values (:'cust', 'picked') returning id sh_s \gset
insert into fabula.shipment_lines (shipment_id, product_id, lot_number, qty) values (:'sh_s', :'moz', 'LV-S', 5);
insert into fabula.stock_moves (product_id, lot_number, qty, move_type, source) values (:'moz', 'LV-S', -5, 'sale', 'office');
commit;
select pg_temp.ck('a linked move split by the lot guard (3 kg on LV-S, 2 kg FEFO from another lot) keeps the link on both parts',
  (select count(*) from fabula.stock_moves where shipment_id = :'sh_s') = 2 and (select sum(qty) from fabula.stock_moves where shipment_id = :'sh_s') = -5,
  (select string_agg(lot_number || ' ' || qty, ', ') from fabula.stock_moves where shipment_id = :'sh_s'));
select fabula.cancel_shipment(:'sh_s', 'cliente sbagliato') cs \gset
select pg_temp.ck('…and annulling gives back all 5 kg, each part to its own lot', (:'cs'::jsonb ->> 'kg_back')::numeric = 5 and pg_temp.lot('LV-S') = 3, :'cs');

-- ============================== Shopify: an annulled online order is reserved again, and deducted when Shopify fulfils it ==============================
insert into fabula.shopify_variant_map (variant_id, product_id, kg_per_unit, label) values ('gid://shopify/ProductVariant/115', :'moz', 0.5, 'Mozzarella 500 g (test)')
on conflict (variant_id) do nothing;
select fabula.upsert_shopify_orders(jsonb_build_array(jsonb_build_object(
  'id', 'gid://shopify/Order/9115', 'name', '#9115', 'source_name', 'web', 'financial_status', 'PAID', 'fulfillment_status', 'UNFULFILLED',
  'created_at', now()::text, 'updated_at', now()::text, 'subtotal', 24, 'tax', 1, 'total', 25,
  'line_items', jsonb_build_array(jsonb_build_object('variant_id', 'gid://shopify/ProductVariant/115', 'title', 'Mozzarella 500 g', 'quantity', 4, 'price', 6, 'tax_rate', 4))))) u1 \gset
select id s9 from fabula.sales_orders where shopify_order_id = 'gid://shopify/Order/9115' \gset
select fabula.pack_order(:'s9', jsonb_build_array(jsonb_build_object('product_id', :'moz', 'lot_number', 'LV-B', 'qty', 2)), null, null, null, null, null, true) ->> 'shipment_id' sh9 \gset
select pg_temp.ck('packed: the console shows the stock as booked for the order', (select stock_booked from fabula.v_shopify_orders_recent where order_number = '#9115'));
select fabula.cancel_shipment(:'sh9', 'lotto sbagliato') is not null c9 \gset
select pg_temp.ck('annulled: no longer booked (its sale moves net to 0), so the online stock reserves it again',
  not (select stock_booked from fabula.v_shopify_orders_recent where order_number = '#9115'));
select coalesce(sum(qty), 0) before9 from fabula.stock_moves where product_id = :'moz' \gset
select fabula.upsert_shopify_orders(jsonb_build_array(jsonb_build_object(
  'id', 'gid://shopify/Order/9115', 'name', '#9115', 'source_name', 'web', 'financial_status', 'PAID', 'fulfillment_status', 'FULFILLED',
  'created_at', now()::text, 'updated_at', (now() + interval '1 minute')::text, 'subtotal', 24, 'tax', 1, 'total', 25,
  'line_items', jsonb_build_array(jsonb_build_object('variant_id', 'gid://shopify/ProductVariant/115', 'title', 'Mozzarella 500 g', 'quantity', 4, 'price', 6, 'tax_rate', 4))))) u2 \gset
select pg_temp.ck('if the office then fulfils it on Shopify by hand, the sync deducts its 2 kg (before: nothing, the old moves counted as booked)',
  (select status::text from fabula.sales_orders where id = :'s9') = 'fulfilled' and (select sum(qty) from fabula.stock_moves where product_id = :'moz') = :'before9'::numeric - 2
  and (select coalesce(sum(qty), 0) from fabula.stock_moves where sales_order_id = :'s9' and move_type = 'sale') = -2,
  (select string_agg(qty || ' ' || coalesce(source, ''), ', ') from fabula.stock_moves where sales_order_id = :'s9'));

-- ============================== «sold on a held lot»: the give-back is not a sale ==============================
insert into fabula.stock_moves (product_id, lot_number, expiry_date, qty, move_type, source) values (:'moz', 'LV-H', :'d'::date + 6, 4, 'production_out', 'test');
insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, output_kg, source) values (:'d', 'LV-H', :'moz', 20, 4, 'test');
insert into fabula.sales_orders (order_number, channel, order_date, customer_id, status, source) values ('W-HOLD', 'wholesale', :'d', :'cust', 'confirmed', 'test') returning id wh \gset
insert into fabula.sales_order_lines (sales_order_id, product_id, qty, unit_price_eur, iva_rate) values (:'wh', :'moz', 4, 12, 4);
select fabula.pack_order(:'wh', jsonb_build_array(jsonb_build_object('product_id', :'moz', 'lot_number', 'LV-H', 'qty', 4)), null, null, null, null, null, true) ->> 'shipment_id' shh \gset
update fabula.production_batches set food_safety_hold = true, hold_reason = 'esito laboratorio', hold_at = now() where batch_lot = 'LV-H';
select fabula.cancel_shipment(:'shh', 'lotto bloccato dopo la preparazione') is not null ch \gset
select pg_temp.ck('a DDT annulled because its lot was put on hold: the lot is back in stock, and the evening check does not call the give-back a sale on a held lot',
  pg_temp.lot('LV-H') = 4
  and not exists (select 1 from jsonb_each(fabula.ops_health_check(:'d'::date)) j(k, x), jsonb_array_elements(case when jsonb_typeof(x) = 'array' then x else '[]'::jsonb end) e
                   where e ->> 'text' like 'Vendite%bloccati%LV-H%'));

-- ============================== grants ==============================
select pg_temp.ck('grants: logins (the function checks Spedizioni = gestisce), never anon; accepted by the security scan',
  has_function_privilege('authenticated', 'fabula.cancel_shipment(uuid, text)', 'execute') and not has_function_privilege('anon', 'fabula.cancel_shipment(uuid, text)', 'execute')
  and exists (select 1 from fabula.security_accepted where key = 'authenticated_security_definer_function_executable:fabula.cancel_shipment(p_shipment_id uuid, p_reason text)'));
