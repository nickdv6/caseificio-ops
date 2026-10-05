-- v0.59 (05/10/2026) · three data fixes from the 05/10 go-live re-audit
-- 1. monthly_review(): never closes the month in progress (1 Oct it closed October instead of September)
-- 2. benchmark.annual_profit_eur 155,500 → 149,200 (investment brief v48, after Shopify card fees): weekly brief ≈ €2,869/week
-- 3. milk.price_eur_kg back to 1.70 (Nick, 05/10: 1.70 is the agreed farm price; it had been edited to 1.6 on 03/10)
-- Settings are upserted (insert … on conflict) so the audit log records the change.

CREATE OR REPLACE FUNCTION fabula.monthly_review(p_month date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'fabula', 'public', 'extensions'
AS $function$
declare m0 date; m1 date; pm0 date; v_moz uuid; drill jsonb; rec jsonb; milkq jsonb; cost jsonb; pkg jsonb;
        v_out numeric; v_milk_eur numeric; v_cons_eur numeric; v_energy_eur numeric; v_labor_eur numeric; v_hours numeric; v_kwh numeric; v_cost_kg numeric;
begin
  -- default: the previous calendar month, whatever day it runs
  m0 := date_trunc('month', coalesce(p_month, (date_trunc('month', (now() at time zone 'Europe/Rome')::date) - interval '1 month')::date))::date;
  -- v0.59: a month still in progress is never closed. A date in the current (or a future) Rome month falls back to the
  -- previous month (the 1 Oct 2026 run closed October instead of September).
  if m0 >= date_trunc('month', (now() at time zone 'Europe/Rome')::date)::date then
    m0 := (date_trunc('month', (now() at time zone 'Europe/Rome')::date) - interval '1 month')::date;
  end if;
  m1 := (m0 + interval '1 month')::date - 1; pm0 := (m0 - interval '1 month')::date;
  select id into v_moz from fabula.products where sku = 'MOZ-DOP-KG';
  drill := fabula.recall_drill();
  rec := fabula.recipe_tuning_proposals();
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
  select coalesce(sum(output_kg), 0) into v_out from fabula.production_batches where product_id = v_moz and batch_date between m0 and m1 and output_kg is not null;
  select coalesce(sum(qty_kg * coalesce(price_eur_per_kg, fabula.setting_num('milk.price_eur_kg', 1.70))), 0) into v_milk_eur from fabula.milk_intake where accepted and intake_date between m0 and m1;
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
    'recall_drill', drill, 'food_safety', fabula.food_safety_summary(m0), 'recipe_tuning', rec, 'milk_quality', milkq, 'supplier_quality', fabula.supplier_quality_trend(m0), 'unit_cost', cost,
    'package_headline', jsonb_build_object('revenue_eur', pkg->'sales'->>'revenue_eur', 'corrispettivi_eur', pkg->'sales'->>'pos_receipts_eur', 'purchases_eur', pkg->'purchases'->>'received_eur',
                                           'milk_eur', pkg->'milk'->>'cost_eur', 'inventory_eur', pkg->'inventory'->>'value_eur', 'waste_kg', pkg->'production'->>'waste_kg'));
end $function$;

insert into fabula.settings (key, value, description, data_type, sort)
select key, '149200', 'Utile operativo annuo di piano (investment brief v48, dopo le commissioni carte Shopify) — riferimento del brief settimanale (≈ € 2.869/settimana)', data_type, sort
  from fabula.settings where key = 'benchmark.annual_profit_eur'
on conflict (key) do update set value = excluded.value, description = excluded.description, updated_at = now();

insert into fabula.settings (key, value, description, data_type, sort)
select key, '1.70', description, data_type, sort
  from fabula.settings where key = 'milk.price_eur_kg'
on conflict (key) do update set value = excluded.value, updated_at = now();
