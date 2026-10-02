-- =============================================================================
-- v0.18: monthly review + commercialista package.
--   monthly_review(month): recall drill (one real lot, full distribution list,
--     timed), recipe tuning proposals (→ approvals; approving applies set_recipe
--     via trigger), milk quality trend (fat/protein/SCC vs yield), unit cost &
--     margin by channel, and the package headline. Runs on the 1st.
--   monthly_package(month): everything the commercialista asks for each month,
--     as one JSON the console renders as a printable page (Pacchetto mensile).
--   recall_drills: history of drills for audits.
-- Written without destructive keywords (connector rule).
-- =============================================================================
set search_path = fabula, public;

create table if not exists fabula.recall_drills (
  id          uuid primary key default gen_random_uuid(),
  run_at      timestamptz not null default now(),
  lot_number  text not null,
  product_sku text,
  produced_kg numeric(10,2), sold_kg numeric(10,2), wasted_kg numeric(10,2), on_hand_kg numeric(10,2), unaccounted_kg numeric(10,2),
  destinations int, wholesale_customers jsonb, milk_lots jsonb, consumables jsonb,
  elapsed_ms int, result text
);
grant all on fabula.recall_drills to authenticated, service_role;
alter table fabula.recall_drills enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='fabula' and tablename='recall_drills' and policyname='recall_drills_authenticated_all') then
    create policy recall_drills_authenticated_all on fabula.recall_drills for all to authenticated using (true) with check (true);
  end if;
end $$;

-- 1. Recall drill: pick a lot (default: a random lot sold in the last 30 days), trace it both ways, time it
create or replace function fabula.recall_drill(p_lot text default null)
returns jsonb language plpgsql as $$
declare t0 timestamptz := clock_timestamp(); bt record; v_lot text; dist jsonb; milk jsonb; cons jsonb; v_prod numeric; v_sold numeric; v_waste numeric; v_oh numeric; v_unacc numeric; v_id uuid; v_res text; v_ws jsonb; v_src uuid; v_parent text;
begin
  v_lot := p_lot;
  if v_lot is null then
    select pb.batch_lot into v_lot from fabula.production_batches pb
     where pb.output_kg is not null and exists (select 1 from fabula.stock_moves sm where sm.lot_number = pb.batch_lot and sm.move_type = 'sale')
       and pb.batch_date >= (now() at time zone 'Europe/Rome')::date - 30 order by random() limit 1;
  end if;
  if v_lot is null then return jsonb_build_object('result', 'no_lots', 'note', 'nessun lotto venduto negli ultimi 30 giorni'); end if;
  select pb.*, p.sku into bt from fabula.production_batches pb join fabula.products p on p.id = pb.product_id where pb.batch_lot = v_lot;
  if bt is null then raise exception 'Lotto sconosciuto: %', v_lot; end if;
  -- whey batches (ricotta) trace their milk through the parent mozzarella batch
  v_src := case when bt.input_kind = 'whey' and bt.parent_batch_id is not null then bt.parent_batch_id else bt.id end;
  select batch_lot into v_parent from fabula.production_batches where id = v_src and id <> bt.id;
  select coalesce(jsonb_agg(jsonb_build_object('channel', channel, 'customer', customer, 'ref', ref, 'date', on_date, 'kg', qty) order by on_date), '[]') into dist from fabula.v_lot_distribution where lot_number = v_lot;
  select coalesce(jsonb_agg(distinct customer), '[]') into v_ws from fabula.v_lot_distribution where lot_number = v_lot and channel = 'wholesale';
  select coalesce(jsonb_agg(jsonb_build_object('milk_lot', mi.milk_lot, 'supplier', sp.legal_name, 'kg', bmi.qty_kg, 'date', mi.intake_date, 'ddt', mi.ddt_number)), '[]') into milk
  from fabula.batch_milk_inputs bmi join fabula.milk_intake mi on mi.id = bmi.milk_intake_id left join fabula.parties sp on sp.id = mi.supplier_id where bmi.batch_id = v_src;
  select coalesce(jsonb_agg(jsonb_build_object('sku', p.sku, 'qty', bc.qty, 'lot', bc.lot_number)), '[]') into cons
  from fabula.batch_consumables bc join fabula.products p on p.id = bc.product_id where bc.batch_id = bt.id;
  v_prod := bt.output_kg;
  select coalesce(-sum(qty) filter (where move_type = 'sale'), 0), coalesce(-sum(qty) filter (where move_type = 'waste'), 0), coalesce(sum(qty), 0)
    into v_sold, v_waste, v_oh from fabula.stock_moves where lot_number = v_lot and product_id = bt.product_id;
  v_unacc := round(v_prod - v_sold - v_waste - v_oh, 2);
  v_res := case when abs(v_unacc) <= greatest(0.5, v_prod * 0.02) and jsonb_array_length(milk) > 0 then 'ok'
                when jsonb_array_length(milk) = 0 then 'manca_latte_a_monte' else 'kg_non_giustificati' end;
  insert into fabula.recall_drills (lot_number, product_sku, produced_kg, sold_kg, wasted_kg, on_hand_kg, unaccounted_kg, destinations, wholesale_customers, milk_lots, consumables, elapsed_ms, result)
  values (v_lot, bt.sku, v_prod, v_sold, v_waste, v_oh, v_unacc, jsonb_array_length(dist), v_ws, milk, cons, (extract(epoch from clock_timestamp() - t0) * 1000)::int, v_res) returning id into v_id;
  return jsonb_build_object('drill_id', v_id, 'lot', v_lot, 'sku', bt.sku, 'batch_date', bt.batch_date, 'casaro', bt.casaro, 'parent_lot', v_parent,
    'produced_kg', v_prod, 'sold_kg', v_sold, 'wasted_kg', v_waste, 'on_hand_kg', v_oh, 'unaccounted_kg', v_unacc,
    'destinations', dist, 'wholesale_customers', v_ws, 'milk_lots', milk, 'consumables', cons,
    'elapsed_ms', (extract(epoch from clock_timestamp() - t0) * 1000)::int, 'result', v_res);
end $$;
grant execute on function fabula.recall_drill(text) to authenticated, service_role;

-- 2. Recipe tuning: 30-day actual vs standard per recipe line → approvals (kind other, type recipe_update)
create or replace function fabula.recipe_tuning_proposals(p_min_batches int default 10, p_min_dev_pct numeric default 5)
returns jsonb language plpgsql as $$
declare r record; out jsonb := '[]'; n int := 0; v_new numeric;
begin
  for r in
    select rc.id recipe_id, fp.sku finished_sku, cp.sku component_sku, cp.unit, rc.basis, rc.qty_per_unit,
           count(*) batches, round(avg(bc.qty / nullif(bc.qty_standard, 0)), 4) ratio
    from fabula.batch_consumables bc
    join fabula.recipes rc on rc.id = bc.recipe_id
    join fabula.products fp on fp.id = rc.finished_product_id join fabula.products cp on cp.id = rc.component_product_id
    join fabula.production_batches b on b.id = bc.batch_id
    where rc.valid_to is null and bc.qty_standard > 0 and bc.entry in ('confirmed','corrected') and b.batch_date >= current_date - 30 and b.source <> 'simulation'
    group by rc.id, fp.sku, cp.sku, cp.unit, rc.basis, rc.qty_per_unit
    having count(*) >= p_min_batches and abs(avg(bc.qty / nullif(bc.qty_standard, 0)) - 1) * 100 >= p_min_dev_pct
  loop
    v_new := round(r.qty_per_unit * r.ratio, 6);
    if not exists (select 1 from fabula.approvals where status = 'pending' and payload->>'type' = 'recipe_update' and payload->>'recipe_id' = r.recipe_id::text) then
      insert into fabula.approvals (kind, requested_by, summary, payload, related_table, related_id)
      values ('other', 'agent:monthly_review',
              format('Ricetta %s · %s: dose reale %s%% rispetto allo standard su %s lotti → aggiornare da %s a %s %s per %s',
                     r.finished_sku, r.component_sku, round((r.ratio - 1) * 100, 1), r.batches, r.qty_per_unit, v_new, r.unit,
                     case r.basis when 'per_kg_milk' then 'kg in caldaia' when 'per_kg_output' then 'kg prodotto' else 'lotto' end),
              jsonb_build_object('type', 'recipe_update', 'recipe_id', r.recipe_id, 'finished_sku', r.finished_sku, 'component_sku', r.component_sku, 'basis', r.basis,
                                 'from_qty', r.qty_per_unit, 'to_qty', v_new, 'ratio', r.ratio, 'batches', r.batches),
              'recipes', r.recipe_id);
      n := n + 1;
    end if;
    out := out || jsonb_build_object('finished_sku', r.finished_sku, 'component_sku', r.component_sku, 'batches', r.batches, 'deviation_pct', round((r.ratio - 1) * 100, 1), 'from', r.qty_per_unit, 'to', v_new, 'unit', r.unit);
  end loop;
  return jsonb_build_object('proposals', out, 'created', n);
end $$;
grant execute on function fabula.recipe_tuning_proposals(int, numeric) to authenticated, service_role;

-- approving a recipe_update applies it (set_recipe closes the old line, opens the new one from today)
create or replace function fabula.sync_po_from_approval() returns trigger language plpgsql as $$
declare pl jsonb;
begin
  if new.status is distinct from old.status then
    if new.related_table = 'purchase_orders' and new.related_id is not null then
      update fabula.purchase_orders set status = case new.status when 'approved' then 'approved'::fabula.po_status when 'rejected' then 'cancelled'::fabula.po_status else status end
      where id = new.related_id;
    elsif new.related_table = 'milk_plans' and new.related_id is not null then
      update fabula.milk_plans set status = case new.status when 'approved' then 'approved' when 'rejected' then 'rejected' when 'expired' then 'rejected' else status end
      where id = new.related_id;
    elsif new.related_table = 'recipes' and new.status = 'approved' and new.payload->>'type' = 'recipe_update' then
      pl := new.payload;
      perform fabula.set_recipe(pl->>'finished_sku', pl->>'component_sku', (pl->>'basis')::fabula.recipe_basis, (pl->>'to_qty')::numeric,
                                (select round_up from fabula.recipes where id = (pl->>'recipe_id')::uuid),
                                (now() at time zone 'Europe/Rome')::date, 'measured', format('aggiornata da %s su %s lotti (approvazione %s)', pl->>'from_qty', pl->>'batches', new.id));
    end if;
  end if;
  return new;
end $$;

-- 3. Milk quality trend + 4. unit cost & margin, inside the monthly review
create or replace function fabula.monthly_review(p_month date default null)
returns jsonb language plpgsql as $$
declare m0 date; m1 date; pm0 date; v_moz uuid; drill jsonb; rec jsonb; milkq jsonb; cost jsonb; pkg jsonb;
        v_out numeric; v_milk_eur numeric; v_cons_eur numeric; v_energy_eur numeric; v_labor_eur numeric; v_hours numeric; v_kwh numeric; v_cost_kg numeric;
begin
  -- default: the previous calendar month, whatever day it runs
  m0 := date_trunc('month', coalesce(p_month, (date_trunc('month', (now() at time zone 'Europe/Rome')::date) - interval '1 month')::date))::date;
  m1 := (m0 + interval '1 month')::date - 1; pm0 := (m0 - interval '1 month')::date;
  select id into v_moz from fabula.products where sku = 'MOZ-DOP-KG';

  drill := fabula.recall_drill();
  rec := fabula.recipe_tuning_proposals();

  -- milk quality: this month vs previous, and yield by fat tercile (does richer milk pay?)
  with d as (
    select mi.intake_date, mi.fat_pct, mi.protein_pct, mi.scc_cells_ml, mi.temperature_c, mi.accepted,
           (select round(avg(b.yield_pct), 2) from fabula.production_batches b join fabula.batch_milk_inputs bmi on bmi.batch_id = b.id where bmi.milk_intake_id = mi.id and b.output_kg is not null) yield_pct
    from fabula.milk_intake mi where mi.intake_date between pm0 and m1),
  cur as (select * from d where intake_date >= m0), prv as (select * from d where intake_date < m0)
  select jsonb_build_object(
    'deliveries', (select count(*) from cur), 'rejected', (select count(*) from cur where not accepted),
    'fat_pct', (select round(avg(fat_pct), 2) from cur), 'fat_pct_prev', (select round(avg(fat_pct), 2) from prv),
    'protein_pct', (select round(avg(protein_pct), 2) from cur), 'protein_pct_prev', (select round(avg(protein_pct), 2) from prv),
    'scc_avg', (select round(avg(scc_cells_ml)) from cur), 'scc_over_400k', (select count(*) from cur where scc_cells_ml > 400000),
    'temp_over_4c', (select count(*) from cur where temperature_c > 4),
    'yield_by_fat', (select coalesce(jsonb_agg(jsonb_build_object('fat_band', band, 'n', n, 'yield_pct', y) order by band), '[]')
                     from (select case when fat_pct < 7.5 then '< 7.5 %' when fat_pct < 8.5 then '7.5–8.5 %' else '> 8.5 %' end band, count(*) n, round(avg(yield_pct), 2) y
                           from cur where yield_pct is not null and fat_pct is not null group by 1) t),
    'note', 'SCC (cellule somatiche) e pH arrivano solo se il fornitore li comunica: se sono vuoti chiederli alla Masseria') into milkq;

  -- unit cost & margin for the month (mozzarella)
  select coalesce(sum(output_kg), 0) into v_out from fabula.production_batches where product_id = v_moz and batch_date between m0 and m1 and output_kg is not null;
  select coalesce(sum(qty_kg * coalesce(price_eur_per_kg, 1.30)), 0) into v_milk_eur from fabula.milk_intake where accepted and intake_date between m0 and m1;
  select coalesce(sum(-sm.qty * coalesce(sp.price_eur, 0)), 0) into v_cons_eur
    from fabula.stock_moves sm join fabula.products p on p.id = sm.product_id
    left join lateral (select price_eur from fabula.supplier_prices where product_id = sm.product_id and valid_from <= m1 order by valid_from desc limit 1) sp on true
    where p.kind in ('consumable','packaging') and sm.qty < 0 and sm.move_type = 'production_in' and sm.moved_at::date between m0 and m1;
  select coalesce(sum(consumed), 0) into v_kwh from fabula.v_energy_per_kg where meter = 'elec_main' and production_date between m0 and m1;
  v_energy_eur := round(v_kwh * fabula.setting_num('energy.eur_per_kwh', 0.28), 2);
  select coalesce(sum(hours), 0) into v_hours from fabula.shifts where clock_out is not null and (clock_in at time zone 'Europe/Rome')::date between m0 and m1;
  v_labor_eur := case when v_hours > 0 then round(v_hours * fabula.setting_num('labor.hourly_cost_eur', 14.5), 2) else round(fabula.setting_num('opex.labor_eur_year', 68205) / 12, 2) end;
  v_cost_kg := case when v_out > 0 then round((v_milk_eur + v_cons_eur + v_energy_eur + v_labor_eur) / v_out, 2) end;
  select jsonb_build_object('mozzarella_kg', v_out, 'milk_eur', round(v_milk_eur, 2), 'consumables_eur', round(v_cons_eur, 2), 'energy_eur', v_energy_eur, 'energy_kwh', v_kwh,
    'labor_eur', v_labor_eur, 'labor_source', case when v_hours > 0 then 'actual' else 'benchmark' end, 'labor_hours', v_hours,
    'cost_eur_per_kg', v_cost_kg, 'milk_share_pct', case when v_cost_kg > 0 and v_out > 0 then round(v_milk_eur / v_out / v_cost_kg * 100, 0) end,
    'price_by_channel', (select coalesce(jsonb_agg(jsonb_build_object('channel', channel, 'kg', kg, 'avg_price_eur_kg', price, 'margin_eur_kg', case when v_cost_kg is not null then round(price - v_cost_kg, 2) end) order by kg desc), '[]')
                         from (select o.channel::text channel, round(sum(l.qty), 1) kg, round(sum(l.qty * l.unit_price_eur) / nullif(sum(l.qty), 0), 2) price
                               from fabula.sales_order_lines l join fabula.sales_orders o on o.id = l.sales_order_id
                               where l.product_id = v_moz and o.order_date between m0 and m1 and o.status in ('confirmed','fulfilled') group by o.channel) x),
    'wholesale_floor_eur_kg', case when v_cost_kg is not null then round(v_cost_kg * 1.15, 2) end,
    'note', 'costo pieno = latte + consumabili + energia (kWh × tariffa in settings) + lavoro; utenze diverse, affitto e marketing esclusi') into cost;

  pkg := fabula.monthly_package(m0);

  return jsonb_build_object('month', to_char(m0, 'YYYY-MM'), 'month_label', to_char(m0, 'TMMonth YYYY'),
    'is_simulation', exists (select 1 from fabula.simulation_runs where m0 between from_date and to_date or m1 between from_date and to_date),
    'recall_drill', drill, 'recipe_tuning', rec, 'milk_quality', milkq, 'unit_cost', cost,
    'package_headline', jsonb_build_object('revenue_eur', pkg->'sales'->>'revenue_eur', 'corrispettivi_eur', pkg->'sales'->>'pos_receipts_eur', 'purchases_eur', pkg->'purchases'->>'received_eur',
                                           'milk_eur', pkg->'milk'->>'cost_eur', 'inventory_eur', pkg->'inventory'->>'value_eur', 'waste_kg', pkg->'production'->>'waste_kg'));
end $$;
grant execute on function fabula.monthly_review(date) to authenticated, service_role;

insert into fabula.settings (key, value, description) values ('energy.eur_per_kwh', '0.28', 'Tariffa elettrica media €/kWh (per il costo pieno al kg)') on conflict (key) do nothing;

-- 5. Commercialista package: one JSON per month, rendered by the console as a printable page
create or replace function fabula.monthly_package(p_month date default null)
returns jsonb language sql stable as $$
with b as (select date_trunc('month', coalesce(p_month, (date_trunc('month', (now() at time zone 'Europe/Rome')::date) - interval '1 month')::date))::date m0),
r as (select m0, (m0 + interval '1 month')::date - 1 m1 from b)
select jsonb_build_object(
  'month', to_char(r.m0, 'YYYY-MM'), 'from', r.m0, 'to', r.m1,
  'company', jsonb_build_object('name', 'La Perla del Cilento', 'place', 'Agropoli (SA)', 'note', 'dati gestionali dal sistema operativo; non sostituiscono i documenti fiscali'),
  'sales', jsonb_build_object(
     'revenue_eur', (select coalesce(sum(total_eur), 0) from fabula.sales_orders where order_date between r.m0 and r.m1 and status in ('confirmed','fulfilled')),
     'by_channel', (select coalesce(jsonb_agg(jsonb_build_object('channel', channel, 'orders', n, 'eur', eur) order by eur desc), '[]') from (select channel::text channel, count(*) n, round(sum(total_eur), 2) eur from fabula.sales_orders where order_date between r.m0 and r.m1 and status in ('confirmed','fulfilled') group by channel) x),
     'pos_receipts_eur', (select coalesce(sum(rt_total_eur), 0) from fabula.pos_daily_closings where closing_date between r.m0 and r.m1),
     'pos_days_closed', (select count(*) from fabula.pos_daily_closings where closing_date between r.m0 and r.m1),
     'pos_variance_eur', (select coalesce(sum(variance_eur), 0) from fabula.pos_daily_closings where closing_date between r.m0 and r.m1),
     'by_iva_rate', (select coalesce(jsonb_agg(jsonb_build_object('iva_rate', iva_rate, 'imponibile_eur', net) order by iva_rate), '[]') from (select l.iva_rate, round(sum(l.qty * l.unit_price_eur), 2) net from fabula.sales_order_lines l join fabula.sales_orders o on o.id = l.sales_order_id where o.order_date between r.m0 and r.m1 and o.status in ('confirmed','fulfilled') group by l.iva_rate) x),
     'wholesale_customers', (select coalesce(jsonb_agg(jsonb_build_object('customer', legal_name, 'eur', eur, 'kg', kg) order by eur desc), '[]') from (select p.legal_name, round(sum(o.total_eur), 2) eur, round(sum(l.qty), 1) kg from fabula.sales_orders o join fabula.parties p on p.id = o.customer_id join fabula.sales_order_lines l on l.sales_order_id = o.id where o.channel = 'wholesale' and o.order_date between r.m0 and r.m1 and o.status in ('confirmed','fulfilled') group by p.legal_name) x)),
  'milk', jsonb_build_object(
     'deliveries', (select count(*) from fabula.milk_intake where intake_date between r.m0 and r.m1 and accepted),
     'kg', (select coalesce(sum(qty_kg), 0) from fabula.milk_intake where intake_date between r.m0 and r.m1 and accepted),
     'cost_eur', (select coalesce(round(sum(qty_kg * coalesce(price_eur_per_kg, 1.30)), 2), 0) from fabula.milk_intake where intake_date between r.m0 and r.m1 and accepted),
     'by_supplier', (select coalesce(jsonb_agg(jsonb_build_object('supplier', legal_name, 'kg', kg, 'eur', eur)), '[]') from (select p.legal_name, round(sum(mi.qty_kg), 1) kg, round(sum(mi.qty_kg * coalesce(mi.price_eur_per_kg, 1.30)), 2) eur from fabula.milk_intake mi join fabula.parties p on p.id = mi.supplier_id where mi.intake_date between r.m0 and r.m1 and mi.accepted group by p.legal_name) x)),
  'purchases', jsonb_build_object(
     'orders_received', (select count(distinct gr.purchase_order_id) from fabula.goods_receipts gr where gr.received_at::date between r.m0 and r.m1),
     'received_eur', (select coalesce(round(sum(grl.qty_received * coalesce(grl.unit_price_eur, 0)), 2), 0) from fabula.goods_receipt_lines grl join fabula.goods_receipts gr on gr.id = grl.receipt_id where gr.received_at::date between r.m0 and r.m1),
     'by_supplier', (select coalesce(jsonb_agg(jsonb_build_object('supplier', legal_name, 'eur', eur, 'ddt', ddts)), '[]') from (select p.legal_name, round(sum(grl.qty_received * coalesce(grl.unit_price_eur, 0)), 2) eur, string_agg(distinct gr.ddt_number, ', ') ddts from fabula.goods_receipts gr join fabula.purchase_orders po on po.id = gr.purchase_order_id join fabula.parties p on p.id = po.supplier_id join fabula.goods_receipt_lines grl on grl.receipt_id = gr.id where gr.received_at::date between r.m0 and r.m1 group by p.legal_name) x),
     'open_orders_eur', (select coalesce(sum(subtotal_eur), 0) from fabula.purchase_orders where status in ('approved','sent','partially_received'))),
  'production', jsonb_build_object(
     'milk_processed_kg', (select coalesce(sum(milk_in_kg), 0) from fabula.production_batches where batch_date between r.m0 and r.m1 and input_kind = 'milk' and output_kg is not null),
     'mozzarella_kg', (select coalesce(sum(b.output_kg), 0) from fabula.production_batches b join fabula.products p on p.id = b.product_id where p.sku = 'MOZ-DOP-KG' and b.batch_date between r.m0 and r.m1),
     'ricotta_kg', (select coalesce(sum(b.output_kg), 0) from fabula.production_batches b join fabula.products p on p.id = b.product_id where p.sku = 'RIC-BUF-KG' and b.batch_date between r.m0 and r.m1),
     'yield_pct', (select round(sum(b.output_kg) / nullif(sum(b.milk_in_kg), 0) * 100, 2) from fabula.production_batches b join fabula.products p on p.id = b.product_id where p.sku = 'MOZ-DOP-KG' and b.batch_date between r.m0 and r.m1 and b.output_kg is not null),
     'waste_kg', (select coalesce(sum(qty), 0) from fabula.waste_log where wasted_at::date between r.m0 and r.m1),
     'batches', (select count(*) from fabula.production_batches where batch_date between r.m0 and r.m1 and output_kg is not null)),
  'inventory', jsonb_build_object(
     'as_of', r.m1,
     'value_eur', (select coalesce(round(sum(x.qty * fabula.unit_cost_estimate(x.product_id)), 2), 0) from (select product_id, sum(qty) qty from fabula.stock_moves where moved_at::date <= r.m1 group by product_id having sum(qty) > 0) x),
     'lines', (select coalesce(jsonb_agg(jsonb_build_object('sku', p.sku, 'name', p.name, 'qty', x.qty, 'unit', p.unit, 'unit_cost_eur', fabula.unit_cost_estimate(p.id), 'value_eur', round(x.qty * fabula.unit_cost_estimate(p.id), 2)) order by p.kind, p.sku), '[]')
               from (select product_id, round(sum(qty), 2) qty from fabula.stock_moves where moved_at::date <= r.m1 group by product_id having sum(qty) > 0.001) x join fabula.products p on p.id = x.product_id)),
  'labor', jsonb_build_object(
     'hours', (select coalesce(sum(hours), 0) from fabula.shifts where clock_out is not null and (clock_in at time zone 'Europe/Rome')::date between r.m0 and r.m1),
     'people', (select count(distinct staff_id) from fabula.shifts where clock_out is not null and (clock_in at time zone 'Europe/Rome')::date between r.m0 and r.m1),
     'by_person', (select coalesce(jsonb_agg(jsonb_build_object('name', full_name, 'hours', h, 'shifts', n) order by h desc), '[]') from (select st.full_name, round(sum(s.hours), 1) h, count(*) n from fabula.shifts s join fabula.staff st on st.id = s.staff_id where s.clock_out is not null and (s.clock_in at time zone 'Europe/Rome')::date between r.m0 and r.m1 group by st.full_name) x)),
  'energy', jsonb_build_object('kwh', (select coalesce(sum(consumed), 0) from fabula.v_energy_per_kg where meter = 'elec_main' and production_date between r.m0 and r.m1),
                               'kwh_per_kg', (select round(sum(consumed) / nullif(sum(output_kg), 0), 3) from fabula.v_energy_per_kg where meter = 'elec_main' and production_date between r.m0 and r.m1)),
  'compliance', jsonb_build_object(
     'haccp_checks', (select count(*) from fabula.haccp_log where logged_at::date between r.m0 and r.m1),
     'non_conformities', (select count(*) from fabula.non_conformities where opened_at::date between r.m0 and r.m1),
     'recall_drills', (select coalesce(jsonb_agg(jsonb_build_object('lot', lot_number, 'result', result, 'ms', elapsed_ms)), '[]') from fabula.recall_drills where run_at::date between r.m0 and r.m1)),
  'documents', jsonb_build_object('ddt_in_photos', (select count(*) from fabula.documents where kind = 'ddt_in' and document_date between r.m0 and r.m1),
                                  'missing_ddt_photos', (select count(*) from fabula.milk_intake mi where mi.intake_date between r.m0 and r.m1 and mi.source <> 'simulation' and not exists (select 1 from fabula.documents d where d.kind = 'ddt_in' and d.document_date = mi.intake_date))),
  'is_simulation', exists (select 1 from fabula.simulation_runs where r.m0 between from_date and to_date or r.m1 between from_date and to_date))
from r;
$$;
grant execute on function fabula.monthly_package(date) to authenticated, service_role;
