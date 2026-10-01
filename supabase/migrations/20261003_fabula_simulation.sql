-- =============================================================================
-- v0.3: simulation layer — generate realistic operating data for bot testing,
-- and purge it cleanly before real operations start.
--
--   select fabula.simulate_days(date '2026-09-01', 30);   -- 30 days of ops
--   select fabula.purge_simulation();                      -- remove all of it
--
-- Every simulated row carries source = 'simulation' where the table has a
-- source column; the rest are tied to simulated batches/orders and removed
-- through those links. A simulation_runs row records each range generated.
-- =============================================================================
set search_path = fabula, public;

create table if not exists fabula.simulation_runs (
  id          uuid primary key default gen_random_uuid(),
  from_date   date not null,
  to_date     date not null,
  created_at  timestamptz not null default now()
);
alter table fabula.simulation_runs enable row level security;
grant all on fabula.simulation_runs to authenticated, service_role;

-- deterministic-ish random helpers
create or replace function fabula._rnd(lo numeric, hi numeric) returns numeric
language sql volatile as $$ select round((lo + random() * (hi - lo))::numeric, 2) $$;

create or replace function fabula.simulate_days(p_from date, p_days int default 30)
returns table (day date, milk_kg numeric, output_kg numeric, yield_pct numeric, revenue_eur numeric)
language plpgsql as $$
declare
  d date; i int;
  v_supplier uuid; v_moz uuid; v_ric uuid; v_raw uuid; v_salt uuid; v_rennet uuid; v_bag uuid;
  v_cf1 uuid; v_cf2 uuid; v_past uuid; v_term uuid;
  cp_cf1 uuid; cp_cf2 uuid; cp_past uuid; cp_milk uuid; cp_clean uuid;
  v_staff uuid; v_cust1 uuid; v_cust2 uuid;
  milk numeric; out_kg numeric; y numeric; lot text; batch uuid; intake uuid;
  sold numeric; price numeric; o uuid; n int; kwh numeric := 48210; dow int; r numeric;
  pos_total numeric; whole_kg numeric; miss_cold boolean;
begin
  select id into v_supplier from fabula.parties where is_milk_supplier limit 1;
  if v_supplier is null then raise exception 'no milk supplier in parties'; end if;
  select id into v_moz from fabula.products where sku='MOZ-DOP-KG';
  select id into v_ric from fabula.products where sku='RIC-BUF-KG';
  select id into v_raw from fabula.products where sku='RAW-MILK';
  select id into v_salt from fabula.products where sku='CON-SALT';
  select id into v_rennet from fabula.products where sku='CON-RENNET';
  select id into v_bag from fabula.products where sku='PKG-BAG-500';
  select id into v_cf1 from fabula.equipment where code='CF-01';
  select id into v_cf2 from fabula.equipment where code='CF-02';
  select id into v_past from fabula.equipment where code='PAST-01';
  select id into v_term from fabula.equipment where code='TERM-01';
  select id into cp_cf1 from fabula.haccp_control_points where code='CCP-COLD-1';
  select id into cp_cf2 from fabula.haccp_control_points where code='CCP-COLD-2';
  select id into cp_past from fabula.haccp_control_points where code='CCP-PAST';
  select id into cp_milk from fabula.haccp_control_points where code='CCP-MILK-TEMP';
  select id into cp_clean from fabula.haccp_control_points where code='PRP-CLEAN';
  select id into v_staff from fabula.staff order by created_at limit 1;

  -- two wholesale customers if none exist
  select id into v_cust1 from fabula.parties where legal_name='Ristorante Il Ceppo (SIM)';
  if v_cust1 is null then
    insert into fabula.parties (type, legal_name, city, province, payment_terms_days, notes) values ('customer','Ristorante Il Ceppo (SIM)','Agropoli','SA',30,'simulation') returning id into v_cust1;
    insert into fabula.parties (type, legal_name, city, province, payment_terms_days, notes) values ('customer','Hotel Serenella (SIM)','Castellabate','SA',30,'simulation') returning id into v_cust2;
  else
    select id into v_cust2 from fabula.parties where legal_name='Hotel Serenella (SIM)';
  end if;

  -- opening consumable stock so reorder logic has something to drain
  if not exists (select 1 from fabula.stock_moves where product_id = v_salt and source='simulation') then
    insert into fabula.stock_moves (moved_at, product_id, qty, move_type, source, reason) values
      (p_from - 1, v_salt, 120, 'purchase_receipt', 'simulation', 'opening stock'),
      (p_from - 1, v_rennet, 12, 'purchase_receipt', 'simulation', 'opening stock'),
      (p_from - 1, v_bag, 12000, 'purchase_receipt', 'simulation', 'opening stock');
    update fabula.products set reorder_point = 30, reorder_qty = 100 where id = v_salt;
    update fabula.products set reorder_point = 2, reorder_qty = 5 where id = v_rennet;
    update fabula.products set reorder_point = 3000, reorder_qty = 15000 where id = v_bag;
  end if;

  insert into fabula.simulation_runs (from_date, to_date) values (p_from, p_from + p_days - 1);

  for i in 0 .. p_days - 1 loop
    d := p_from + i; dow := extract(isodow from d);
    if dow = 7 then continue; end if;                       -- closed Sundays

    -- milk intake
    milk := fabula._rnd(1050, 1300);
    r := fabula._rnd(2.8, 4.4);                               -- rarely over 4.3 °C
    insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, temperature_c, fat_pct, protein_pct, price_eur_per_kg,
                                    accepted, rejection_reason, ddt_number, received_by, received_by_id, source)
    values (d, time '06:30', v_supplier, 'MC-'||to_char(d,'YYMMDD'), milk, r, fabula._rnd(7.6,8.6), fabula._rnd(4.3,4.9), 1.30,
            r <= 4.3, case when r > 4.3 then 'temperatura' end, 'DDT-'||to_char(d,'YYMMDD'), 'Giuseppe', v_staff, 'simulation')
    returning id into intake;
    insert into fabula.haccp_log (control_point_id, equipment_id, logged_at, measured_value, result, operator, operator_id, source)
    values (cp_milk, v_term, d + time '06:35', r, (case when r > 4.0 then 'warning' else 'ok' end)::fabula.haccp_result, 'Giuseppe', v_staff, 'simulation');
    insert into fabula.stock_moves (moved_at, product_id, lot_number, qty, move_type, source) values (d + time '06:30', v_raw, 'MC-'||to_char(d,'YYMMDD'), milk, 'milk_intake', 'simulation');
    if r > 4.3 then continue; end if;                         -- rejected milk: no production that day

    -- production: yield drifts slowly, 28–32 %
    y := (30 + sin(i / 6.0) * 1.5)::numeric + fabula._rnd(-0.6, 0.6);
    out_kg := round(milk * y / 100, 1);
    lot := 'L' || to_char(d,'YYYYMMDD') || '-A';
    insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, output_kg, whey_kg, started_at, finished_at, curd_ph, stretch_temp_c, casaro, casaro_id, source)
    values (d, lot, v_moz, milk, out_kg, round(milk * 0.62,1), d + time '07:00', d + time '11:30', fabula._rnd(4.9,5.2), fabula._rnd(88,94), 'Giuseppe', v_staff, 'simulation')
    returning id into batch;
    insert into fabula.batch_milk_inputs values (batch, intake, milk);
    insert into fabula.batch_consumables (batch_id, product_id, qty) values (batch, v_salt, round(milk*0.0028,2)), (batch, v_rennet, round(milk*0.00025,3)), (batch, v_bag, ceil(out_kg*1.2));
    insert into fabula.stock_moves (moved_at, product_id, lot_number, qty, move_type, batch_id, source) values
      (d + time '07:00', v_raw, 'MC-'||to_char(d,'YYMMDD'), -milk, 'production_in', batch, 'simulation'),
      (d + time '11:30', v_moz, lot, out_kg, 'production_out', batch, 'simulation'),
      (d + time '07:00', v_salt, null, -round(milk*0.0028,2), 'production_in', batch, 'simulation'),
      (d + time '07:00', v_rennet, null, -round(milk*0.00025,3), 'production_in', batch, 'simulation'),
      (d + time '11:30', v_bag, null, -ceil(out_kg*1.2), 'production_in', batch, 'simulation');
    update fabula.stock_moves set expiry_date = d + 5 where batch_id = batch and move_type = 'production_out';
    insert into fabula.haccp_log (control_point_id, equipment_id, logged_at, measured_value, result, operator, operator_id, batch_id, source)
    values (cp_past, v_past, d + time '08:10', fabula._rnd(72.5, 75), 'ok', 'Giuseppe', v_staff, batch, 'simulation');

    -- ricotta from whey, small
    insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, output_kg, casaro, casaro_id, source)
    values (d, 'R' || to_char(d,'YYYYMMDD'), v_ric, round(milk*0.62,1), round(milk*0.62*0.07,1), 'Giuseppe', v_staff, 'simulation');
    insert into fabula.stock_moves (moved_at, product_id, lot_number, expiry_date, qty, move_type, source) values (d + time '12:00', v_ric, 'R'||to_char(d,'YYYYMMDD'), d + 4, round(milk*0.62*0.07,1), 'production_out', 'simulation');

    -- cold rooms: morning + evening; ~6 % of evening checks forgotten, occasional excursion
    miss_cold := random() < 0.06;
    insert into fabula.haccp_log (control_point_id, equipment_id, logged_at, measured_value, result, operator, operator_id, source) values
      (cp_cf1, v_cf1, d + time '06:40', fabula._rnd(2.2,3.8), 'ok', 'Giuseppe', v_staff, 'simulation'),
      (cp_cf2, v_cf2, d + time '06:42', fabula._rnd(2.2,3.8), 'ok', 'Giuseppe', v_staff, 'simulation');
    if not miss_cold then
      r := case when random() < 0.04 then fabula._rnd(4.3,5.6) else fabula._rnd(2.2,3.9) end;
      insert into fabula.haccp_log (control_point_id, equipment_id, logged_at, measured_value, result, operator, operator_id, corrective_action, source) values
        (cp_cf1, v_cf1, d + time '18:20', r, (case when r > 4 then 'non_conformity' else 'ok' end)::fabula.haccp_result, 'Maria', v_staff, case when r > 4 then 'prodotto spostato in CF-02, chiamato tecnico' end, 'simulation'),
        (cp_cf2, v_cf2, d + time '18:22', fabula._rnd(2.2,3.9), 'ok', 'Maria', v_staff, null, 'simulation');
      if r > 4 then
        insert into fabula.non_conformities (opened_at, severity, status, description, equipment_id, corrective_action, opened_by_id)
        values (d + time '18:25', 'major', 'corrected', 'CF-01 a '||r||' °C alla chiusura', v_cf1, 'prodotto spostato in CF-02, chiamato tecnico', v_staff);
      end if;
    end if;
    if random() > 0.05 then
      insert into fabula.haccp_log (control_point_id, logged_at, result, operator, operator_id, source) values (cp_clean, d + time '18:45', 'ok', 'Maria', v_staff, 'simulation');
    end if;

    -- sales: shop counter (Sat busiest), wholesale Tue/Fri, shopify trickle
    price := 14.00;
    sold := round(out_kg * (case when dow = 6 then 0.9 else 0.62 end) * fabula._rnd(0.85,1.15), 2);
    pos_total := 0; n := greatest(8, round(sold / 0.9)::int);
    insert into fabula.sales_orders (order_number, channel, order_date, status, subtotal_eur, total_eur, payment_method, source)
    values ('POS-'||to_char(d,'YYMMDD')||'-1', 'store_pos', d, 'fulfilled', round(sold*price,2), round(sold*price,2), 'misto', 'simulation') returning id into o;
    insert into fabula.sales_order_lines (sales_order_id, product_id, lot_number, qty, unit_price_eur, iva_rate) values (o, v_moz, lot, sold, price, 4);
    insert into fabula.stock_moves (moved_at, product_id, lot_number, qty, move_type, sales_order_id, source) values (d + time '13:00', v_moz, lot, -sold, 'sale', o, 'simulation');
    pos_total := round(sold*price,2);
    -- ricotta at the counter
    insert into fabula.sales_orders (order_number, channel, order_date, status, subtotal_eur, total_eur, source)
    values ('POS-'||to_char(d,'YYMMDD')||'-2', 'store_pos', d, 'fulfilled', round(milk*0.62*0.07*0.6*9,2), round(milk*0.62*0.07*0.6*9,2), 'simulation') returning id into o;
    insert into fabula.sales_order_lines (sales_order_id, product_id, lot_number, qty, unit_price_eur, iva_rate) values (o, v_ric, 'R'||to_char(d,'YYYYMMDD'), round(milk*0.62*0.07*0.6,2), 9, 4);
    insert into fabula.stock_moves (moved_at, product_id, lot_number, qty, move_type, sales_order_id, source) values (d + time '13:00', v_ric, 'R'||to_char(d,'YYYYMMDD'), -round(milk*0.62*0.07*0.6,2), 'sale', o, 'simulation');
    pos_total := pos_total + round(milk*0.62*0.07*0.6*9,2);

    if dow in (2,5) then
      whole_kg := round(out_kg * 0.45, 1);
      insert into fabula.sales_orders (order_number, channel, order_date, customer_id, status, subtotal_eur, total_eur, source)
      values ('WS-'||to_char(d,'YYMMDD'), 'wholesale', d, case when dow=2 then v_cust1 else v_cust2 end, 'fulfilled', round(whole_kg*11.5,2), round(whole_kg*11.5,2), 'simulation') returning id into o;
      insert into fabula.sales_order_lines (sales_order_id, product_id, lot_number, qty, unit_price_eur, iva_rate) values (o, v_moz, lot, whole_kg, 11.5, 4);
      insert into fabula.stock_moves (moved_at, product_id, lot_number, qty, move_type, sales_order_id, source) values (d + time '14:00', v_moz, lot, -whole_kg, 'sale', o, 'simulation');
      insert into fabula.shipments (ddt_number, customer_id, sales_order_id, status, ship_date, driver_id, temp_at_departure_c, delivered_at)
      values ('DDT-OUT-'||to_char(d,'YYMMDD'), case when dow=2 then v_cust1 else v_cust2 end, o, 'delivered', d, v_staff, fabula._rnd(2.5,3.8), d + time '15:30');
      insert into fabula.shipment_lines (shipment_id, product_id, lot_number, qty) select id, v_moz, lot, whole_kg from fabula.shipments where ddt_number='DDT-OUT-'||to_char(d,'YYMMDD');
    end if;

    -- waste: whatever is left of the lot from 5 days ago
    insert into fabula.waste_log (wasted_at, product_id, lot_number, qty, reason, logged_by_id, notes)
    select d + time '18:00', product_id, lot_number, qty_on_hand, 'scaduto', v_staff, 'simulation'
    from fabula.v_stock_on_hand where kind='finished_good' and expiry_date <= d and qty_on_hand > 0;
    insert into fabula.stock_moves (moved_at, product_id, lot_number, qty, move_type, source, reason)
    select d + time '18:00', product_id, lot_number, -qty_on_hand, 'waste', 'simulation', 'scaduto'
    from fabula.v_stock_on_hand where kind='finished_good' and expiry_date <= d and qty_on_hand > 0;

    -- POS close with a small variance now and then
    insert into fabula.pos_daily_closings (closing_date, rt_total_eur, rt_receipts, cash_counted_eur, card_eur, recorded_total_eur, closed_by_id, notes)
    values (d, pos_total + (case when random() < 0.15 then fabula._rnd(-12, 12) else 0 end), n, round(pos_total*0.45,2), round(pos_total*0.55,2), pos_total, v_staff, 'simulation')
    on conflict (closing_date) do nothing;

    -- electricity: ~0.9 kWh per kg of output + base load
    kwh := kwh + round(110 + out_kg * fabula._rnd(0.8, 1.0), 0);
    insert into fabula.meter_readings (meter, read_at, reading, unit, read_by_id, source) values ('elec_main', d + time '19:30', kwh, 'kWh', v_staff, 'simulation');

    day := d; milk_kg := milk; output_kg := out_kg; yield_pct := round(y,2); revenue_eur := pos_total; return next;
  end loop;
end $$;

create or replace function fabula.purge_simulation() returns table (table_name text, deleted bigint)
language plpgsql as $$
declare n bigint;
begin
  delete from fabula.task_instances where scan_event_id is null and completed_at is null and due_at::date in (select generate_series(from_date, to_date, '1 day')::date from fabula.simulation_runs);
  delete from fabula.shipment_lines sl using fabula.shipments s, fabula.sales_orders o where sl.shipment_id = s.id and s.sales_order_id = o.id and o.source='simulation';
  delete from fabula.shipments s using fabula.sales_orders o where s.sales_order_id = o.id and o.source='simulation'; get diagnostics n = row_count; table_name:='shipments'; deleted:=n; return next;
  delete from fabula.non_conformities where description like 'CF-0% alla chiusura' and haccp_log_id is null; get diagnostics n = row_count; table_name:='non_conformities'; deleted:=n; return next;
  delete from fabula.waste_log where notes='simulation'; get diagnostics n = row_count; table_name:='waste_log'; deleted:=n; return next;
  delete from fabula.pos_daily_closings where notes='simulation'; get diagnostics n = row_count; table_name:='pos_daily_closings'; deleted:=n; return next;
  delete from fabula.meter_readings where source='simulation'; get diagnostics n = row_count; table_name:='meter_readings'; deleted:=n; return next;
  delete from fabula.stock_moves where source='simulation'; get diagnostics n = row_count; table_name:='stock_moves'; deleted:=n; return next;
  delete from fabula.sales_orders where source='simulation'; get diagnostics n = row_count; table_name:='sales_orders'; deleted:=n; return next;  -- lines cascade
  delete from fabula.haccp_log where source='simulation'; get diagnostics n = row_count; table_name:='haccp_log'; deleted:=n; return next;
  delete from fabula.production_batches where source='simulation'; get diagnostics n = row_count; table_name:='production_batches'; deleted:=n; return next;  -- inputs/consumables cascade
  delete from fabula.milk_intake where source='simulation'; get diagnostics n = row_count; table_name:='milk_intake'; deleted:=n; return next;
  delete from fabula.parties where notes='simulation'; get diagnostics n = row_count; table_name:='parties'; deleted:=n; return next;
  delete from fabula.simulation_runs; get diagnostics n = row_count; table_name:='simulation_runs'; deleted:=n; return next;
end $$;

-- Fix: one cumulative reading per day → consumption is the delta from the previous reading
create or replace view fabula.v_energy_per_kg as
with r as (
  select meter, unit, read_at::date as d, reading,
         reading - lag(reading) over (partition by meter order by read_at) as consumed
  from fabula.meter_readings
)
select r.d as production_date, r.meter, r.consumed, r.unit, p.output_kg,
       round(r.consumed / nullif(p.output_kg,0), 3) as per_kg_output
from r
left join (select batch_date, sum(output_kg) output_kg from fabula.production_batches group by batch_date) p on p.batch_date = r.d
where r.consumed is not null;
