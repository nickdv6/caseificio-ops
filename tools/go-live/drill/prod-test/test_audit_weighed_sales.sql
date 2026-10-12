-- v0.93b audit fix POS-06 · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh ws_test
--   su postgres -c "psql -d ws_test -f tools/go-live/drill/prod-test/test_audit_weighed_sales.sql" | grep -E "PASS|FAIL"
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
select id moz from fabula.products where sku = 'MOZ-DOP-KG' \gset
insert into fabula.stock_moves (product_id, lot_number, expiry_date, qty, move_type, source)
values (:'moz', 'LWS-1', current_date + 5, 10, 'production_out', 'test');

-- a till sale as the Ordini Shopify bot passes it: one weighed line (custom sale, no variant, properties from the Pesa tile)
-- and one custom sale with nothing to map it by
select fabula.upsert_shopify_orders(jsonb_build_array(jsonb_build_object(
  'id', 'gid://shopify/Order/9001', 'name', '#9001', 'source_name', 'pos', 'financial_status', 'PAID', 'fulfillment_status', 'UNFULFILLED',
  'created_at', now()::text, 'updated_at', now()::text, 'subtotal', 6.85, 'tax', 0.27, 'total', 7.12,
  'line_items', jsonb_build_array(
    jsonb_build_object('variant_id', null, 'title', 'Mozzarella di Bufala Campana DOP — 0,350 kg × 16,80 €/kg', 'quantity', 1, 'price', 5.88, 'tax_rate', 4,
                       'properties', jsonb_build_object('peso_kg', '0.350', 'prezzo_kg', '16.80', 'sku', 'MOZ-DOP-KG', 'iva', '4')),
    jsonb_build_object('variant_id', null, 'title', 'Vendita varia', 'quantity', 1, 'price', 1.24, 'tax_rate', 22))))) r \gset

select pg_temp.ck('the sync does not fail on a line without variant', (:'r'::jsonb->>'created')::int = 1, :'r');
select pg_temp.ck('the weighed line is booked as 0,350 kg of mozzarella at 16,80 €/kg',
  exists (select 1 from fabula.sales_order_lines l join fabula.sales_orders o on o.id = l.sales_order_id
          where o.shopify_order_id = 'gid://shopify/Order/9001' and l.product_id = :'moz' and l.qty = 0.350 and l.unit_price_eur = 16.8),
  (select string_agg(qty || ' @ ' || unit_price_eur, ', ') from fabula.sales_order_lines l join fabula.sales_orders o on o.id = l.sales_order_id where o.shopify_order_id = 'gid://shopify/Order/9001'));
select pg_temp.ck('stock and lot are reduced by 0,350 kg (FEFO lot LWS-1)',
  exists (select 1 from fabula.stock_moves where move_type = 'sale' and lot_number = 'LWS-1' and qty = -0.350));
select pg_temp.ck('the line with nothing to map it by is listed as «vendita libera», no variant row with a NULL key',
  exists (select 1 from fabula.shopify_unmapped_lines where variant_id = 'vendita libera' and title = 'Vendita varia')
  and not exists (select 1 from fabula.shopify_variant_map where variant_id is null));
select pg_temp.ck('the till day is closed from the POS order', exists (select 1 from fabula.pos_daily_closings where closing_date = (now() at time zone 'Europe/Rome')::date));

-- the same order synced again (bot window is 3 days): nothing doubled
select fabula.upsert_shopify_orders(jsonb_build_array(jsonb_build_object(
  'id', 'gid://shopify/Order/9001', 'name', '#9001', 'source_name', 'pos', 'financial_status', 'PAID', 'fulfillment_status', 'UNFULFILLED',
  'created_at', now()::text, 'updated_at', now()::text, 'subtotal', 6.85, 'tax', 0.27, 'total', 7.12,
  'line_items', jsonb_build_array(
    jsonb_build_object('variant_id', null, 'title', 'Mozzarella di Bufala Campana DOP — 0,350 kg × 16,80 €/kg', 'quantity', 1, 'price', 5.88, 'tax_rate', 4,
                       'properties', jsonb_build_object('peso_kg', '0.350', 'sku', 'MOZ-DOP-KG')),
    jsonb_build_object('variant_id', null, 'title', 'Vendita varia', 'quantity', 1, 'price', 1.24, 'tax_rate', 22))))) r2 \gset
select pg_temp.ck('re-sync: one sale move, one unmapped row',
  (select count(*) from fabula.stock_moves where move_type = 'sale' and lot_number = 'LWS-1') = 1
  and (select count(*) from fabula.shopify_unmapped_lines where variant_id = 'vendita libera') = 1, :'r2');
