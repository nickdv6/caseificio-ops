-- v1.04 database guard rails (audit D-17 rest, D-22 + PRINT-04, D-26 rest, D-28, D-31, D-33) · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh a_test
--   su postgres -c "psql -d a_test -f tools/go-live/drill/prod-test/test_v104_db_guards.sql" | grep -E "PASS|FAIL"
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as
$$ declare h text; begin execute p_sql; return ''; exception when others then get stacked diagnostics h = pg_exception_hint; return sqlerrm || case when coalesce(h, '') <> '' then ' || hint: ' || h else '' end; end $$;
create or replace function pg_temp.as_user(p_sub text) returns void language sql as
$$ select set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_sub), false) $$;
insert into fabula.staff (id, full_name, role, app_role, active, auth_user_id) values
  ('10000000-0000-4000-a000-000000104a01', 'Titolare W', 'owner', 'titolare', true, '00000000-0000-4000-a000-000000104a01'),
  ('10000000-0000-4000-a000-000000104a02', 'Ufficio W', 'operaio', 'amministrazione', true, '00000000-0000-4000-a000-000000104a02'),
  ('10000000-0000-4000-a000-000000104a04', 'Casaro W', 'casaro', 'produzione', true, '00000000-0000-4000-a000-000000104a04'),
  ('10000000-0000-4000-a000-000000104a06', 'Resp W', 'casaro', 'resp_produzione', true, '00000000-0000-4000-a000-000000104a06')
on conflict do nothing;
\set tit '00000000-0000-4000-a000-000000104a01'
\set uff '00000000-0000-4000-a000-000000104a02'
\set cas '00000000-0000-4000-a000-000000104a04'
\set rsp '00000000-0000-4000-a000-000000104a06'
\set cas_s '10000000-0000-4000-a000-000000104a04'
select (now() at time zone 'Europe/Rome')::date d \gset
select id moz from fabula.products where sku = 'MOZ-DOP-KG' \gset
select id ric from fabula.products where sku = 'RIC-BUF-KG' \gset
select id rennet from fabula.products where sku = 'CON-RENNET' \gset
insert into fabula.parties (type, legal_name, is_milk_supplier) values ('supplier', 'Masseria W', true) returning id sup \gset
insert into fabula.parties (type, legal_name) values ('customer', 'Pizzeria W') returning id cust \gset

-- ============================== D-17 · paper copies ==============================
select pg_temp.as_user(:'cas');
select pg_temp.err(format($q$select fabula.log_ccp('CCP-COLD-1', 4.0, now() - interval '3 hours', %L, null, null, 'paper', null, 'Casaro W')$q$, :'cas_s')) e1 \gset
select pg_temp.err(format($q$select fabula.log_ccp('CCP-COLD-1', 4.0, now() - interval '3 hours' + interval '1 minute', %L, null, null, 'paper', null, 'Casaro W')$q$, :'cas_s')) e2 \gset
select pg_temp.ck('D-17 a sheet line copied once is saved', :'e1' = '', :'e1');
select pg_temp.ck('D-17 …the same line copied again (one minute off) is refused, saying when and how it was recorded',
  :'e2' like 'Questa riga del foglio è già nel registro: CCP 5 Cella frigo 1, 4 °C alle %(già ricopiata da Casaro W). Passa alla riga successiva.', :'e2');
select pg_temp.err(format($q$select fabula.log_ccp('CCP-COLD-1', 4.5, now() - interval '3 hours', %L, null, null, 'paper', null, 'Casaro W')$q$, :'cas_s')) e3 \gset
select pg_temp.err(format($q$select fabula.log_ccp('CCP-COLD-1', 4.0, now() - interval '2 hours', %L, null, null, 'paper', null, 'Casaro W')$q$, :'cas_s')) e4 \gset
select pg_temp.ck('D-17 …a different value at the same time, or the same value an hour later, is another reading', :'e3' = '' and :'e4' = '', :'e3' || ' / ' || :'e4');
select pg_temp.err(format($q$select fabula.log_ccp('CCP-COLD-2'::text, 3.0::numeric, %L::uuid, null::text, null::text, 'tablet'::text, null::text)$q$, :'cas_s')) e5 \gset
select pg_temp.err(format($q$select fabula.log_ccp('CCP-COLD-2', 3.0, now() - interval '1 minute', %L, null, null, 'paper', null, 'Casaro W')$q$, :'cas_s')) e6 \gset
select pg_temp.ck('D-17 a reading made on the tablet and then copied from the sheet too is refused («registrata sul tablet»)', :'e5' = '' and :'e6' like '%già nel registro%registrata sul tablet%', :'e5' || ' / ' || :'e6');
select set_config('request.jwt.claims', '', false);

insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, output_kg, input_kind, started_at, finished_at, source)
values (((now() - interval '26 hours') at time zone 'Europe/Rome')::date, 'LW104-A', :'moz', 300, 60, 'milk', now() - interval '26 hours', now() - interval '20 hours', 'test');
select pg_temp.as_user(:'cas');
select pg_temp.err(format($q$select fabula.log_ccp('CCP-STRETCH', 62, now() - interval '80 hours', %L, 'LW104-A', null, 'paper', null, 'Casaro W')$q$, :'cas_s')) e7 \gset
select pg_temp.err(format($q$select fabula.log_ccp('CCP-STRETCH', 62, now() - interval '25 hours', %L, 'LW104-A', null, 'paper', null, 'Casaro W')$q$, :'cas_s')) e8 \gset
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('D-17 a lot''s check copied with the day before the lot''s day is refused, with the lot''s times',
  :'e7' like 'Il foglio dice %, ma il lotto LW104-A è stato avviato il % e chiuso il %controlla la data e l''ora sul foglio, o il lotto.', :'e7');
select pg_temp.ck('D-17 …within the lot''s working time it is saved', :'e8' = '', :'e8');
-- review: a ricotta lot typed in on the tablet after the fact (started «now») keeps its sheet lines from the parent vat's time
insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, parent_batch_id, source)
select :'d', 'RW104-A', :'ric', 250, 'whey', now(), id, 'test' from fabula.production_batches where batch_lot = 'LW104-A';
update fabula.production_batches set batch_date = ((now() - interval '26 hours') at time zone 'Europe/Rome')::date where batch_lot = 'RW104-A';
select pg_temp.as_user(:'cas');
select pg_temp.err(format($q$select fabula.log_ccp('CCP-RIC', 85, now() - interval '19 hours', %L, 'RW104-A', null, 'paper', null, 'Casaro W')$q$, :'cas_s')) e8b \gset
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('D-17 a ricotta lot started on the tablet after the fact keeps its sheet line from the vat''s working time', :'e8b' = '', :'e8b');

insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source)
values (:'d', '07:00', :'sup', 'MW104-1', 800, true, 4, 'tablet') returning id mi \gset
select pg_temp.as_user(:'cas');
select pg_temp.err(format($q$select fabula.log_milk_check(%L, 'CCP-MILK-TEMP', 4.2, %L, null, 'paper', now() - interval '30 minutes', 'Casaro W')$q$, :'mi', :'cas_s')) e9 \gset
select pg_temp.err(format($q$select fabula.log_milk_check(%L, 'CCP-MILK-TEMP', 4.2, %L, null, 'paper', now() - interval '29 minutes', 'Casaro W')$q$, :'mi', :'cas_s')) e10 \gset
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('D-17 milk: the same delivery''s sheet line copied twice is refused (by delivery)', :'e9' = '' and :'e10' like 'Questa riga del foglio è già nel registro: latte MW104-1, 4,2 °C alle %', :'e9' || ' / ' || :'e10');

-- ============================== D-22 · packing per product, DDT numbers ==============================
insert into fabula.stock_moves (product_id, lot_number, expiry_date, qty, move_type, source) values
 (:'moz', 'LW-M1', :'d'::date + 5, 40, 'production_out', 'test'),
 (:'ric', 'LW-R1', :'d'::date + 5, 10, 'production_out', 'test');
insert into fabula.sales_orders (order_number, channel, order_date, customer_id, status, source) values
 ('WA-104', 'wholesale', :'d', :'cust', 'confirmed', 'test'), ('WB-104', 'wholesale', :'d', :'cust', 'confirmed', 'test');
insert into fabula.sales_order_lines (sales_order_id, product_id, qty, unit_price_eur, iva_rate)
select id, :'moz', case order_number when 'WA-104' then 2 else 5 end, 12, 4 from fabula.sales_orders where order_number in ('WA-104', 'WB-104');
insert into fabula.sales_order_lines (sales_order_id, product_id, qty, unit_price_eur, iva_rate)
select id, :'ric', 1, 9, 4 from fabula.sales_orders where order_number = 'WA-104';
select id wa from fabula.sales_orders where order_number = 'WA-104' \gset
select id wb from fabula.sales_orders where order_number = 'WB-104' \gset
select pg_temp.as_user(:'cas');
select pg_temp.err(format($q$select fabula.pack_order(%L, jsonb_build_array(jsonb_build_object('product_id', %L, 'lot_number', 'LW-M1', 'qty', 50)), %L, null, null, null, null, true)$q$, :'wb', :'moz', :'cas_s')) p1 \gset
select pg_temp.ck('D-22 50 kg weighed for 5 ordered: refused even when confirmed, and says why',
  :'p1' like 'Mozzarella di Bufala Campana DOP: pesati 50 kg contro 5 ordinati (+900 %). Oltre il +30 % non si spedisce, nemmeno confermando:% || hint: weight', :'p1');
select pg_temp.err(format($q$select fabula.pack_order(%L, jsonb_build_array(jsonb_build_object('product_id', %L, 'lot_number', 'LW-M1', 'qty', 3)), %L, null, null, null, null, true)$q$, :'wa', :'moz', :'cas_s')) p2 \gset
select pg_temp.ck('D-22 2 kg mozzarella + 1 kg ricotta packed as 3 kg mozzarella is no longer «0 %»: refused (+50 % mozzarella)', :'p2' like 'Mozzarella%pesati 3 kg contro 2 ordinati (+50 %)%', :'p2');
select pg_temp.err(format($q$select fabula.pack_order(%L, jsonb_build_array(jsonb_build_object('product_id', %L, 'lot_number', 'LW-R1', 'qty', 5)), %L, null, null, null, null, true)$q$, :'wb', :'ric', :'cas_s')) p3 \gset
select pg_temp.ck('D-22 a product that is not in the order is refused', :'p3' like '«Ricotta di bufala» non è in questo ordine (WB-104)%', :'p3');
select fabula.pack_order(:'wa', jsonb_build_array(jsonb_build_object('product_id', :'moz', 'lot_number', 'LW-M1', 'qty', 2.3)), :'cas_s') r4 \gset
select pg_temp.ck('D-22 ricotta left out and mozzarella +15 %: asked, with one reason per product (partial shipment possible)',
  (:'r4'::jsonb->>'needs_confirm')::boolean and :'r4'::jsonb->'reasons' = '["Mozzarella di Bufala Campana DOP: pesati 2,3 kg contro 2 ordinati (+15 %)", "Ricotta di bufala non preparato: 0 di 1 kg ordinati (spedizione parziale)"]'::jsonb,
  :'r4'::jsonb->>'reasons');
select fabula.pack_order(:'wa', jsonb_build_array(jsonb_build_object('product_id', :'moz', 'lot_number', 'LW-M1', 'qty', 2.05), jsonb_build_object('product_id', :'ric', 'lot_number', 'LW-R1', 'qty', 0.98)), :'cas_s') r5 \gset
select set_config('request.jwt.claims', '', false);
select (regexp_match(:'r5'::jsonb->>'ddt_number', '^DDT-(\d{4})-(\d{4})$'))[2]::int n1 \gset
select pg_temp.ck('D-22 within tolerance: packed, with a DDT number of the yearly series (DDT-<year>-NNNN)',
  (:'r5'::jsonb->>'ok')::boolean and :'r5'::jsonb->>'ddt_number' ~ ('^DDT-' || extract(year from :'d'::date) || '-[0-9]{4}$'), :'r5'::jsonb->>'ddt_number');
select pg_temp.ck('D-22 the same order again: «già preparato»', pg_temp.err(format($q$select fabula.pack_order(%L, jsonb_build_array(jsonb_build_object('product_id', %L, 'lot_number', 'LW-M1', 'qty', 2)), null)$q$, :'wa', :'moz')) like 'Ordine WA-104 già preparato%');

-- the direct shipment from a lot (tablet, through save_ops) and an older tablet that still sends «DDT-<date>-<4 digits>»
select pg_temp.as_user(:'cas');
set role authenticated;
select fabula.save_ops(jsonb_build_array(
  jsonb_build_object('table', 'shipments', 'row', jsonb_build_object('customer_id', :'cust', 'status', 'picked')),
  jsonb_build_object('table', 'shipment_lines', 'row', jsonb_build_object('shipment_id', '$0.id', 'product_id', :'moz', 'lot_number', 'LW-M1', 'qty', 1)),
  jsonb_build_object('table', 'stock_moves', 'row', jsonb_build_object('product_id', :'moz', 'lot_number', 'LW-M1', 'qty', -1, 'move_type', 'sale', 'source', 'tablet'))), gen_random_uuid()) s1 \gset
select fabula.save_ops(jsonb_build_array(
  jsonb_build_object('table', 'shipments', 'row', jsonb_build_object('ddt_number', 'DDT-' || to_char(now(), 'YYYYMMDD') || '-4821', 'customer_id', :'cust', 'status', 'picked'))), gen_random_uuid()) s2 \gset
reset role;
select set_config('request.jwt.claims', '', false);
select (:'s1'::jsonb->0->>'ddt_number') ddt2, (:'s2'::jsonb->0->>'ddt_number') ddt3 \gset
select pg_temp.ck('D-22 the direct shipment from a lot gets the next number, and an older tablet''s «DDT-<date>-4821» is replaced by the one after',
  :'ddt2' = format('DDT-%s-%s', extract(year from :'d'::date), lpad((:n1 + 1)::text, 4, '0')) and :'ddt3' = format('DDT-%s-%s', extract(year from :'d'::date), lpad((:n1 + 2)::text, 4, '0')),
  :'ddt2' || ' / ' || :'ddt3' || ' / ' || left(:'s1', 120));
insert into fabula.shipments (ddt_number, customer_id, status) values ('DDT-T104', :'cust', 'planned');
select pg_temp.ck('D-22 a number written by the database''s own jobs or tests (no login) is kept', exists (select 1 from fabula.shipments where ddt_number = 'DDT-T104'));
select pg_temp.ck('D-22 a new year starts again from 0001', fabula.next_ddt_number(make_date(extract(year from :'d'::date)::int + 1, 1, 2)) = format('DDT-%s-0001', extract(year from :'d'::date)::int + 1));
select pg_temp.as_user(:'tit');
set role authenticated;
select pg_temp.err(format($q$update fabula.shipments set ddt_number = 'DDT-X' where ddt_number = %L$q$, :'ddt2')) u1 \gset
select pg_temp.err(format($q$delete from fabula.shipments where ddt_number = %L$q$, :'ddt3')) u2 \gset
select pg_temp.err($q$select fabula.next_ddt_number(null)$q$) u3 \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('D-22 a login cannot renumber a DDT, delete a shipment, or take a number', :'u1' like 'Il numero del DDT (DDT-%) lo dà il database e non si cambia' and :'u2' like 'Il DDT DDT-% è già numerato e non si cancella%' and :'u3' like 'permission denied%', :'u1' || ' / ' || :'u2' || ' / ' || :'u3');
select pg_temp.as_user(:'cas');
set role authenticated;
select fabula.save_ops(jsonb_build_array(jsonb_build_object('table', 'shipments', 'row', jsonb_build_object('customer_id', :'cust', 'status', 'picked', 'ship_date', '2025-12-31'))), gen_random_uuid()) s4 \gset
select pg_temp.err(format($q$update fabula.shipments set ship_date = '2024-01-01' where ddt_number = %L$q$, :'s4'::jsonb->0->>'ddt_number')) u4 \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('D-22 a login''s shipment is dated today whatever it sends (the year of the series), and the date cannot be changed later',
  :'s4'::jsonb->0->>'ship_date' = :'d' and :'s4'::jsonb->0->>'ddt_number' like format('DDT-%s-%%', extract(year from :'d'::date)) and :'u4' like 'Data, cliente e ordine del DDT % non si cambiano dopo l''emissione',
  (:'s4'::jsonb->0->>'ship_date') || ' ' || (:'s4'::jsonb->0->>'ddt_number') || ' / ' || :'u4');
select pg_temp.ck('D-22 the shipment date defaults to the Rome date', (select column_default from information_schema.columns where table_schema = 'fabula' and table_name = 'shipments' and column_name = 'ship_date') like '%Europe/Rome%');

-- ============================== D-26 · non-conformities and arrival checks ==============================
insert into fabula.non_conformities (severity, description, corrective_action, opened_by_id) values ('critical', 'NC W prova', null, :'cas_s') returning id nc \gset
select pg_temp.as_user(:'cas');
set role authenticated;
select pg_temp.err(format($q$update fabula.non_conformities set severity = 'minor' where id = %L$q$, :'nc')) n1 \gset
select pg_temp.err(format($q$update fabula.non_conformities set description = 'niente' where id = %L$q$, :'nc')) n2 \gset
select pg_temp.err(format($q$update fabula.non_conformities set corrective_action = 'lotto isolato', root_cause = 'sonda', lot_number = 'LW104-A' where id = %L$q$, :'nc')) n3 \gset
select pg_temp.err(format($q$update fabula.non_conformities set lot_number = 'LW104-Z' where id = %L$q$, :'nc')) n4 \gset
select pg_temp.err(format($q$update fabula.non_conformities set opened_at = now() - interval '9 days' where id = %L$q$, :'nc')) n5 \gset
reset role;
select pg_temp.ck('D-26 a floor profile cannot lower the severity or rewrite the description', :'n1' like 'Gravità e descrizione di una non conformità le cambia solo il responsabile HACCP%' and :'n2' like 'Gravità e descrizione%', :'n1' || ' / ' || :'n2');
select pg_temp.ck('D-26 …it adds cause and corrective action, and a missing lot', :'n3' = '' and (select corrective_action || '|' || lot_number from fabula.non_conformities where id = :'nc') = 'lotto isolato|LW104-A', :'n3');
select pg_temp.ck('D-26 …but cannot change the lot once set, nor when the NC was opened', :'n4' like 'Il lotto o la macchina di una non conformità li cambia solo il responsabile HACCP%' and :'n5' like 'Quando e da chi è stata aperta%', :'n4' || ' / ' || :'n5');
select pg_temp.as_user(:'rsp');
set role authenticated;
select pg_temp.err(format($q$update fabula.non_conformities set severity = 'major' where id = %L$q$, :'nc')) n6 \gset
select pg_temp.err(format($q$update fabula.non_conformities set status = 'closed' where id = %L$q$, :'nc')) n7 \gset
select pg_temp.err(format($q$update fabula.non_conformities set root_cause = 'riscritta dopo' where id = %L$q$, :'nc')) n8 \gset
select pg_temp.err(format($q$update fabula.non_conformities set status = 'investigating' where id = %L$q$, :'nc')) n9 \gset
select pg_temp.err(format($q$update fabula.non_conformities set root_cause = 'sonda starata' where id = %L$q$, :'nc')) n10 \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('D-26 the HACCP manager changes the severity (in the Registro) and closes it', :'n6' = '' and :'n7' = ''
  and exists (select 1 from fabula.audit_log where table_name = 'non_conformities' and row_key = :'nc' and old_data->>'severity' = 'critical' and new_data->>'severity' = 'major'), :'n6' || ' / ' || :'n7');
select pg_temp.ck('D-26 a closed NC is frozen, even for the HACCP manager, until reopened; reopened, it can be completed',
  :'n8' like 'La non conformità è chiusa (%): per cambiarla il responsabile HACCP la riapre%' and :'n9' = '' and :'n10' = '', :'n8' || ' / ' || :'n9' || ' / ' || :'n10');
update fabula.non_conformities set status = 'closed', corrective_action = coalesce(corrective_action, 'fatto') where id = :'nc';
select pg_temp.as_user(:'cas');
set role authenticated;
select pg_temp.err(format($q$update fabula.non_conformities set closed_at = now() - interval '30 days' where id = %L$q$, :'nc')) n11 \gset
select pg_temp.err(format($q$insert into fabula.non_conformities (severity, description, opened_at, status, closed_at) values ('minor', 'NC W retrodatata', now() - interval '40 days', 'closed', now() - interval '39 days')$q$)) n12 \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('D-26 the closing date of a closed NC cannot be backdated', :'n11' like 'La non conformità è chiusa%', :'n11');
select pg_temp.ck('D-26 a login''s new NC is opened now and open, whatever it sends', :'n12' = '' and (select opened_at > now() - interval '1 minute' and status::text = 'open' and closed_at is null from fabula.non_conformities where description = 'NC W retrodatata'), :'n12');

-- arrival check: «NON conforme», then the goods are isolated for dosing while the NC is open
insert into fabula.purchase_orders (po_number, supplier_id, status, order_date) values ('PO-W104-1', :'sup', 'approved', :'d') returning id po1 \gset
insert into fabula.goods_receipts (purchase_order_id, ddt_number, received_by_id) values (:'po1', 'D-W1', :'cas_s') returning id gr1 \gset
insert into fabula.goods_receipt_lines (receipt_id, product_id, qty_received, supplier_lot) values (:'gr1', :'rennet', 2, 'CAG-1');
select pg_temp.as_user(:'tit');
select fabula.record_receipt_check('PO-W104-1', false, 'temperatura 12 °C', :'cas_s') rc1 \gset
select pg_temp.err($q$select fabula.record_receipt_check('PO-W104-1', true, null)$q$) rc2 \gset
select fabula.record_receipt_check('PO-W104-1', false, 'ancora calda', :'cas_s') rc3 \gset
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('D-26 a «NON conforme» arrival opens its NC, linked to the receipt',
  (select inspection_ok is false and inspection_nc_id = (:'rc1'::jsonb->>'nc_id')::uuid and inspected_at is not null from fabula.goods_receipts where id = :'gr1'), :'rc1');
select pg_temp.ck('D-26 …it cannot be re-checked «conforme»; the same «non conforme» again opens nothing new',
  :'rc2' like 'Il ricevimento di PO-W104-1 è già registrato NON conforme il %: «temperatura 12 °C». Non si rifà il controllo%' and (:'rc3'::jsonb->>'already')::boolean
  and (select count(*) from fabula.non_conformities where description like '%PO-W104-1%') = 1, :'rc2');
insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, source) values (:'d', 'LW104-B', :'moz', 300, 'milk', now(), 'test');
select pg_temp.as_user(:'cas');
set role authenticated;
select pg_temp.err($q$select fabula.record_batch_consumable('LW104-B', 'CON-RENNET', 0.25, 0.25, null, 'cag-1')$q$) q1 \gset
select pg_temp.err($q$select fabula.record_batch_consumable('LW104-B', 'CON-RENNET', 0.25, 0.25, null, null)$q$) q2 \gset
select pg_temp.err($q$select fabula.record_batch_consumable('LW104-B', 'CON-RENNET', 0.25, 0.25, null, 'CAG-2')$q$) q3 \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('D-26 dosing with the isolated lot is refused', :'q1' like 'Caglio, lotto CAG-1, ordine PO-W104-1: temperatura 12 °C: merce NON conforme all''arrivo, è isolata.%', :'q1');
select pg_temp.ck('D-26 …without a lot it asks for the lot; with another lot it is recorded', :'q2' like 'Caglio: c''è merce NON conforme all''arrivo e isolata (lotto CAG-1%). Scrivi il lotto della confezione che usi.' and :'q3' = '', :'q2' || ' / ' || :'q3');
update fabula.non_conformities set status = 'closed', corrective_action = 'reso al fornitore' where id = (:'rc1'::jsonb->>'nc_id')::uuid;
select pg_temp.ck('D-26 the NC closed (goods returned), the lot is no longer isolated', fabula._lot_quarantine(:'rennet', 'CAG-1') is null);
insert into fabula.purchase_orders (po_number, supplier_id, status, order_date) values ('PO-W104-2', :'sup', 'approved', :'d') returning id po2 \gset
insert into fabula.goods_receipts (purchase_order_id, ddt_number, received_by_id) values (:'po2', 'D-W2', :'cas_s');
select pg_temp.as_user(:'tit');
select fabula.record_receipt_check('PO-W104-2', true, null, :'cas_s') rc4 \gset
select fabula.record_receipt_check('PO-W104-2', false, 'muffa trovata all''apertura', :'cas_s') rc5 \gset
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('D-26 a «conforme» delivery found non-conforming later: new NC, the earlier check in the Registro',
  :'rc5'::jsonb->>'nc_id' is not null and exists (select 1 from fabula.audit_log where table_name = 'goods_receipts' and new_data->>'inspection_ok' = 'false' and old_data->>'inspection_ok' = 'true'), :'rc5');

-- ============================== D-28 · bank matching ==============================
insert into fabula.invoices (direction, party_id, invoice_number, invoice_date, taxable_eur, iva_eur, total_eur, status) values
  ('out', :'cust', 'FT-W12', :'d', 413.46, 16.54, 430, 'approved'), ('in', :'sup', 'FP-W7', :'d', 163.93, 36.07, 200, 'approved'), ('out', :'cust', 'FT-W13', :'d', 48.08, 1.92, 50, 'paid');
select id i12 from fabula.invoices where invoice_number = 'FT-W12' \gset
select id i7 from fabula.invoices where invoice_number = 'FP-W7' \gset
select id i13 from fabula.invoices where invoice_number = 'FT-W13' \gset
update fabula.invoices set paid_at = :'d', payment_ref = 'contanti' where id = :'i13';
insert into fabula.bank_transactions (bank_account, value_date, amount_eur, description, external_id) values
  ('IT-W', :'d', -430, 'bonifico a fornitore', 'BX-1'), ('IT-W', :'d', 430, 'bonifico da Pizzeria', 'BX-2'), ('IT-W', :'d', 430, 'altro bonifico', 'BX-3'),
  ('IT-W', :'d', 95, 'bonifico ordine', 'BX-4'), ('IT-W', :'d', 100, 'secondo bonifico ordine', 'BX-5'), ('IT-W', :'d', -100, 'uscita', 'BX-6');
select id b1 from fabula.bank_transactions where external_id = 'BX-1' \gset
select id b2 from fabula.bank_transactions where external_id = 'BX-2' \gset
select id b3 from fabula.bank_transactions where external_id = 'BX-3' \gset
select id b4 from fabula.bank_transactions where external_id = 'BX-4' \gset
select id b5 from fabula.bank_transactions where external_id = 'BX-5' \gset
select id b6 from fabula.bank_transactions where external_id = 'BX-6' \gset
insert into fabula.sales_orders (order_number, channel, order_date, customer_id, status, source, total_eur) values ('WC-104', 'wholesale', :'d', :'cust', 'confirmed', 'test', 100) returning id so \gset
select pg_temp.as_user(:'uff');
select pg_temp.err(format($q$select fabula.recon_set_bank(%L, 'invoice', %L)$q$, :'b1', :'i12')) k1 \gset
select pg_temp.err(format($q$select fabula.recon_set_bank(%L, 'invoice', %L)$q$, :'b2', :'i12')) k2 \gset
select pg_temp.err(format($q$select fabula.recon_set_bank(%L, 'invoice', %L)$q$, :'b3', :'i12')) k3 \gset
select pg_temp.err(format($q$select fabula.recon_set_bank(%L, 'invoice', %L)$q$, :'b3', :'i7')) k4 \gset
select pg_temp.err(format($q$select fabula.recon_set_bank(%L, 'invoice', %L)$q$, :'b3', :'i13')) k5 \gset
select pg_temp.err(format($q$select fabula.recon_set_bank(%L, 'order', %L)$q$, :'b4', :'so')) k6 \gset
select pg_temp.err(format($q$select fabula.recon_set_bank(%L, 'order', %L)$q$, :'b5', :'so')) k7 \gset
select pg_temp.err(format($q$select fabula.recon_set_bank(%L, 'order', %L)$q$, :'b6', :'so')) k8 \gset
select pg_temp.err(format($q$select fabula.recon_set_bank(%L, 'clear')$q$, :'b2')) k9 \gset
select pg_temp.err(format($q$select fabula.recon_set_bank(%L, 'invoice', %L)$q$, :'b3', :'i12')) k10 \gset
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('D-28 an outgoing payment cannot settle a customer invoice', :'k1' like 'Un''uscita (-430 €) non può incassare la fattura cliente FT-W12%', :'k1');
select pg_temp.ck('D-28 an incoming payment settles it; a second one is refused with where it is', :'k2' = '' and :'k3' like 'La fattura FT-W12 è già abbinata al movimento del % (430 €): togli prima quell''abbinamento. Se è una rata, classifica questo movimento come «Altro» con una nota.', :'k2' || ' / ' || :'k3');
select pg_temp.ck('D-28 an incoming payment cannot pay a supplier invoice; an invoice already paid otherwise is refused',
  :'k4' like 'Un''entrata (430 €) non paga la fattura fornitore FP-W7%' and :'k5' like 'La fattura FT-W13 risulta già pagata il % (contanti).', :'k4' || ' / ' || :'k5');
select pg_temp.ck('D-28 an order matched by hand with a different amount gets the note; a second credit or a debit is refused',
  :'k6' = '' and (select match_note from fabula.bank_transactions where id = :'b4') = 'Abbinato a mano: importi diversi (ordine 100 €, movimento 95 €)'
  and :'k7' like 'L''ordine WC-104 è già abbinato al movimento del % (95 €)%' and :'k8' like 'Un''uscita (-100 €) non può incassare l''ordine WC-104%', :'k6' || ' / ' || :'k7' || ' / ' || :'k8');
select pg_temp.ck('D-28 after «Togli l''abbinamento» the invoice can be matched to another movement', :'k9' = '' and :'k10' = '' and (select status::text from fabula.invoices where id = :'i12') = 'paid', :'k9' || ' / ' || :'k10');
insert into fabula.payment_payouts (id, provider, payout_date, net_eur) values ('po_w104', 'shopify', :'d', 120);
insert into fabula.bank_transactions (bank_account, value_date, amount_eur, description, external_id) values ('IT-W', :'d', -120, 'uscita', 'BX-7'), ('IT-W', :'d', 90, 'acconto', 'BX-8');
insert into fabula.sales_orders (order_number, channel, order_date, customer_id, status, source, total_eur) values ('WD-104', 'wholesale', :'d', :'cust', 'confirmed', 'test', 100) returning id so2 \gset
select pg_temp.as_user(:'uff');
select pg_temp.err(format($q$select fabula.recon_set_bank(id, 'payout', 'po_w104') from fabula.bank_transactions where external_id = 'BX-7'$q$)) k11 \gset
select pg_temp.err(format($q$select fabula.recon_set_bank(id, 'order', %L, 'acconto') from fabula.bank_transactions where external_id = 'BX-8'$q$, :'so2')) k12 \gset
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('D-28 an outgoing movement cannot be a Shopify payout', :'k11' like 'Un''uscita (-120 €) non può essere il versamento Shopify del %', :'k11');
select pg_temp.ck('D-28 a note typed by hand keeps the «importi diversi» note after it', :'k12' = '' and (select match_note from fabula.bank_transactions where external_id = 'BX-8') = 'acconto · Abbinato a mano: importi diversi (ordine 100 €, movimento 90 €)', :'k12');

-- ============================== D-31 · a task needs its record ==============================
select (:'d'::date - 1) y \gset
-- v1.05 (audit E-32): the daily tasks start from prod.tasks_from (the replay's opening date is in 2027) and Sunday is closed: the test
-- generates tasks for today and the days before, whatever the weekday
update fabula.settings set value = '2026-01-01' where key = 'prod.tasks_from';
update fabula.settings set value = '' where key = 'prod.closed_weekdays';
select fabula.generate_daily_tasks(:'y'::date) is not null g \gset
select min(ti.due_at) m_due, max(ti.due_at) e_due from fabula.task_instances ti join fabula.task_schedules ts on ts.id = ti.schedule_id
 where ts.code = 'T-CF1' and ti.followup_kind is null and ti.due_at >= (:'y'::date)::timestamp at time zone 'Europe/Rome' and ti.due_at < (:'y'::date + 1)::timestamp at time zone 'Europe/Rome' \gset
select id cf1 from fabula.equipment where code = 'CF-01' \gset
select id cp_cold1 from fabula.haccp_control_points where code = 'CCP-COLD-1' \gset
select id cp_valve from fabula.haccp_control_points where code = 'PRP-PAST-VALVE' \gset
delete from fabula.haccp_log where control_point_id in (:'cp_cold1', :'cp_valve') and logged_at >= (:'y'::date)::timestamp at time zone 'Europe/Rome' and logged_at < (:'y'::date + 1)::timestamp at time zone 'Europe/Rome';
update fabula.task_instances ti set status = 'due', completed_at = null from fabula.task_schedules ts where ts.id = ti.schedule_id and ts.code in ('T-CF1', 'T-VALVE', 'T-KWH')
   and ti.due_at >= (:'y'::date)::timestamp at time zone 'Europe/Rome' and ti.due_at < (:'y'::date + 1)::timestamp at time zone 'Europe/Rome';
select coalesce(fabula.close_open_task(:'y'::date, null, :'cf1', null, null, null, (:'m_due'::timestamptz + interval '30 minutes'))::text, 'none') t1 \gset
select pg_temp.ck('D-31 a calibration of cold room 1 (closes by machine) without a reading does not tick «Temperatura cella 1»', :'t1' = 'none' and :'m_due' <> :'e_due', :'t1' || ' ' || :'m_due' || ' ' || :'e_due');
insert into fabula.haccp_log (control_point_id, logged_at, measured_value, result, source, operator) values (:'cp_cold1', :'m_due'::timestamptz + interval '20 minutes', 3.5, 'ok', 'tablet', 'Casaro W');
select coalesce(fabula.close_open_task(:'y'::date, null, :'cf1', null, null, null, (:'m_due'::timestamptz + interval '30 minutes'))::text, 'none') t2 \gset
select pg_temp.ck('D-31 …with the morning reading it closes the morning task', :'t2' <> 'none' and (select due_at = :'m_due'::timestamptz from fabula.task_instances where id::text = :'t2'), :'t2');
select coalesce(fabula.close_open_task(:'y'::date, null, :'cf1', null, null, null, (:'e_due'::timestamptz - interval '2 hours'))::text, 'none') t3 \gset
select pg_temp.ck('D-31 …the morning reading does not count for the evening task', :'t3' = 'none', :'t3');
insert into fabula.haccp_log (control_point_id, logged_at, measured_value, result, source, operator)
values (:'cp_valve', (:'y'::date + time '05:00') at time zone 'Europe/Rome', 0, 'ok', 'paper', 'Casaro W');
select coalesce(fabula.close_open_task(:'y'::date, null, null, :'cp_valve', null, null, (:'y'::date + time '05:05') at time zone 'Europe/Rome')::text, 'none') t4 \gset
select coalesce(fabula.close_open_task(:'y'::date, 'T-KWH', null, null, null, null, (:'y'::date + time '20:00') at time zone 'Europe/Rome')::text, 'none') t5 \gset
select pg_temp.ck('D-31 the only valve check of the day counts from midnight; a task with no control point (meter) closes as before', :'t4' <> 'none' and :'t5' <> 'none', :'t4' || ' / ' || :'t5');

-- ============================== D-33 · permission levels ==============================
select pg_temp.as_user(:'uff');
set role authenticated;
select pg_temp.err($q$insert into fabula.approvals (kind, requested_by, summary, payload, status) values ('purchase_order', 'W', 'già approvata', '{}', 'approved')$q$) a1 \gset
select pg_temp.err($q$insert into fabula.approvals (kind, requested_by, summary, payload, auto_approve_at, auto_rule) values ('purchase_order', 'W', 'si approva da sola', '{}', now(), 'mio')$q$) a2 \gset
select pg_temp.err(format($q$insert into fabula.purchase_orders (po_number, supplier_id, status, order_date) values ('PO-W104-3', %L, 'approved', %L)$q$, :'sup', :'d')) a3 \gset
select pg_temp.err(format($q$insert into fabula.purchase_orders (po_number, supplier_id, status, order_date) values ('PO-W104-4', %L, 'draft', %L)$q$, :'sup', :'d')) a4 \gset
select pg_temp.err($q$update fabula.purchase_orders set status = 'approved' where po_number = 'PO-W104-4'$q$) a5 \gset
select pg_temp.err($q$update fabula.purchase_orders set status = 'cancelled' where po_number = 'PO-W104-4'$q$) a6 \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('D-33 a login cannot write an approval already approved', :'a1' like 'Una richiesta di approvazione nasce «in attesa»%', :'a1');
select pg_temp.ck('D-33 …nor one set to approve itself (the window is set by the database)', :'a2' = '' and not exists (select 1 from fabula.approvals where summary = 'si approva da sola' and auto_rule = 'mio'), :'a2');
select pg_temp.ck('D-33 a purchase order from a login starts as draft; «approvato» only through the approval (cancelling is still possible)',
  :'a3' like 'Un ordine d''acquisto nasce in bozza o in attesa di approvazione%' and :'a4' = '' and :'a5' like 'L''ordine PO-W104-4 diventa «approvato» solo dalla sua approvazione%' and :'a6' = '', :'a3' || ' / ' || :'a5' || ' / ' || :'a6');
select pg_temp.ck('D-33 the database''s own jobs still write approved orders', pg_temp.err(format($q$insert into fabula.purchase_orders (po_number, supplier_id, status, order_date) values ('PO-W104-5', %L, 'approved', %L)$q$, :'sup', :'d')) = '');
select pg_temp.ck('D-33 a purchase order line cannot have a negative price',
  pg_temp.err(format($q$insert into fabula.purchase_order_lines (purchase_order_id, product_id, qty_ordered, unit_price_eur, iva_rate) values (%L, %L, 1, -5, 22)$q$, :'po1', :'rennet')) like '%purchase_order_lines_unit_price_check%');

-- ============================== scan ==============================
select pg_temp.ck('security scan: nothing new without a reason', not exists (select 1 from fabula.security_findings() f where not exists (select 1 from fabula.security_accepted a where a.key = f.key)),
  (select string_agg(f.key, ', ') from fabula.security_findings() f where not exists (select 1 from fabula.security_accepted a where a.key = f.key)));
