-- =============================================================================
-- v0.10: weekly brief — one JSON document for the Monday bot.
--   select fabula.weekly_brief();                    -- last completed Mon–Sat week (Europe/Rome)
--   select fabula.weekly_brief(date '2026-09-26');   -- week ending that Saturday
-- Compares the week with the previous one: production & yield, sales by channel,
-- waste, compliance, energy, procurement, milk-plan accuracy, and an ESTIMATED
-- weekly P&L: real revenue and milk cost, consumables at supplier list price,
-- labor/utilities/marketing/lease at 1/52 of the OpEx benchmarks in fabula.settings.
-- Read-only. The bot narrates; it never computes.
-- =============================================================================
set search_path = fabula, public;

-- OpEx benchmarks (annual €) from the feasibility model, editable
insert into fabula.settings (key, value, description) values
  ('opex.labor_eur_year',     '68205', 'Benchmark annuo lavoro (modello di fattibilità)'),
  ('opex.utilities_eur_year', '27660', 'Benchmark annuo utenze'),
  ('opex.marketing_eur_year', '15900', 'Benchmark annuo marketing'),
  ('opex.lease_eur_year',     '14400', 'Affitto annuo (€1.200/mese)'),
  ('opex.consumables_eur_year','27978','Benchmark annuo consumabili e imballi (usato solo se mancano i listini)')
on conflict (key) do nothing;

-- simulated ricotta batches hold whey in milk_in_kg: flag them so milk totals stay honest
update fabula.production_batches b set input_kind = 'whey'
 from fabula.products p where p.id = b.product_id and p.sku = 'RIC-BUF-KG' and b.input_kind = 'milk' and b.source = 'simulation';

create or replace function fabula.weekly_brief(p_week_end date default null)
returns jsonb language plpgsql stable as $$
declare
  we date; ws date; pwe date; pws date; v_moz uuid; v_ric uuid;
  cur jsonb; prev jsonb; pl jsonb;
begin
  -- default: the Saturday that closed the last full week (Monday run → two days earlier)
  we := coalesce(p_week_end, (date_trunc('week', (now() at time zone 'Europe/Rome')::date)::date - 2));
  ws := we - 5; pwe := we - 7; pws := ws - 7;
  select id into v_moz from fabula.products where sku = 'MOZ-DOP-KG';
  select id into v_ric from fabula.products where sku = 'RIC-BUF-KG';

  -- one block computed for a date range, used for both weeks
  cur  := fabula._week_block(ws, we, v_moz, v_ric);
  prev := fabula._week_block(pws, pwe, v_moz, v_ric);

  -- estimated P&L for the week
  pl := jsonb_build_object(
    'revenue_eur',            (cur->'sales'->>'revenue_eur')::numeric,
    'milk_cost_eur',          (cur->'production'->>'milk_cost_eur')::numeric,
    'consumables_cost_eur',   (cur->'procurement'->>'consumables_used_eur')::numeric,
    'labor_eur',     round(fabula.setting_num('opex.labor_eur_year', 68205) / 52, 2),
    'utilities_eur', round(fabula.setting_num('opex.utilities_eur_year', 27660) / 52, 2),
    'marketing_eur', round(fabula.setting_num('opex.marketing_eur_year', 15900) / 52, 2),
    'lease_eur',     round(fabula.setting_num('opex.lease_eur_year', 14400) / 52, 2),
    'basis', 'revenue and milk real; consumables at supplier list price (benchmark/52 if no list); labor, utilities, marketing, lease = annual benchmark / 52');
  pl := pl || jsonb_build_object('operating_result_eur',
          round((pl->>'revenue_eur')::numeric - (pl->>'milk_cost_eur')::numeric - (pl->>'consumables_cost_eur')::numeric
                - (pl->>'labor_eur')::numeric - (pl->>'utilities_eur')::numeric - (pl->>'marketing_eur')::numeric - (pl->>'lease_eur')::numeric, 2));
  pl := pl || jsonb_build_object('margin_pct', case when (pl->>'revenue_eur')::numeric > 0 then round((pl->>'operating_result_eur')::numeric / (pl->>'revenue_eur')::numeric * 100, 1) end,
          'benchmark_weekly_profit_eur', round(220787.0 / 52, 2));

  return jsonb_build_object(
    'week_start', ws, 'week_end', we, 'week_number', extract(week from we),
    'is_simulation', exists (select 1 from fabula.simulation_runs where ws between from_date and to_date or we between from_date and to_date),
    'this_week', cur, 'previous_week', prev, 'pnl_estimate', pl,
    'milk_plan_accuracy', (select coalesce(jsonb_agg(jsonb_build_object('date', plan_date, 'planned_milk_kg', planned_milk_kg, 'actual_milk_kg', actual_milk_kg, 'forecast_demand_kg', forecast_demand_kg, 'actual_sales_kg', actual_sales_kg, 'waste_kg', waste_kg) order by plan_date), '[]')
                            from fabula.v_milk_plan_accuracy where plan_date between ws and we and status = 'approved'),
    'open_items', jsonb_build_object(
      'pending_approvals', (select count(*) from fabula.approvals where status = 'pending'),
      'oldest_pending_days', (select max(greatest(0, (now() at time zone 'Europe/Rome')::date - requested_at::date)) from fabula.approvals where status = 'pending'),
      'open_non_conformities', (select count(*) from fabula.non_conformities where status in ('open','investigating')),
      'calibration_due_30d', (select coalesce(jsonb_agg(code), '[]') from fabula.equipment where active and next_calibration_on <= we + 30),
      'training_expiring_60d', (select coalesce(jsonb_agg(full_name), '[]') from fabula.staff where active and haccp_training_expires <= we + 60),
      'bot_errors', (select count(*) from fabula.agent_runs where status = 'error' and started_at::date between ws and we)));
end $$;

create or replace function fabula._week_block(ws date, we date, v_moz uuid, v_ric uuid)
returns jsonb language sql stable as $$
with
prod as (
  select coalesce(sum(b.milk_in_kg) filter (where b.input_kind = 'milk'), 0) milk_kg,
         coalesce(sum(b.output_kg) filter (where b.product_id = v_moz), 0) moz_kg,
         coalesce(sum(b.output_kg) filter (where b.product_id = v_ric), 0) ric_kg,
         count(*) filter (where b.product_id = v_moz) moz_batches,
         count(distinct b.batch_date) days_produced,
         round(sum(b.output_kg) filter (where b.product_id = v_moz) / nullif(sum(b.milk_in_kg) filter (where b.product_id = v_moz), 0) * 100, 2) yield_pct,
         (select round(avg(yield_pct), 2) from fabula.production_batches where product_id = v_moz and output_kg is not null and batch_date between we - 29 and we) yield_30d
  from fabula.production_batches b where b.batch_date between ws and we and b.output_kg is not null),
milk as (
  select coalesce(sum(qty_kg) filter (where accepted), 0) received_kg, count(*) filter (where not accepted) rejected,
         coalesce(sum(qty_kg * coalesce(price_eur_per_kg, 1.30)) filter (where accepted), 0) cost_eur
  from fabula.milk_intake where intake_date between ws and we),
sales as (
  select coalesce(sum(revenue_eur), 0) revenue_eur, coalesce(sum(orders), 0) orders,
         coalesce(jsonb_object_agg(channel, rev) filter (where channel is not null), '{}') by_channel
  from (select channel, sum(revenue_eur) rev, sum(orders) orders, sum(revenue_eur) revenue_eur from fabula.v_daily_sales where order_date between ws and we group by channel) x),
kg as (
  select coalesce(-sum(sm.qty) filter (where sm.product_id = v_moz), 0) moz_sold_kg,
         coalesce(-sum(sm.qty) filter (where sm.product_id = v_ric), 0) ric_sold_kg
  from fabula.stock_moves sm where sm.move_type = 'sale' and sm.moved_at::date between ws and we),
waste as (
  select coalesce(sum(qty) filter (where product_id = v_moz), 0) moz_kg, coalesce(sum(qty), 0) total_kg
  from fabula.waste_log where wasted_at::date between ws and we),
haccp as (
  select count(*) checks, count(*) filter (where result = 'non_conformity') ncs,
         (select count(*) from fabula.non_conformities where opened_at::date between ws and we) nc_opened,
         (select count(*) from generate_series(ws, we, '1 day') d cross join fabula.haccp_control_points cp
            where cp.active and cp.frequency in ('daily','twice_daily') and extract(isodow from d) <> 7
              and not exists (select 1 from fabula.haccp_log l where l.control_point_id = cp.id and l.logged_at::date = d)) missing_checks
  from fabula.haccp_log where logged_at::date between ws and we),
pos as (
  select count(*) closes, coalesce(sum(abs(variance_eur)), 0) abs_variance_eur, count(*) filter (where variance_eur <> 0) with_variance
  from fabula.pos_daily_closings where closing_date between ws and we),
energy as (
  select coalesce(sum(consumed), 0) kwh, round(sum(consumed) / nullif(sum(output_kg), 0), 3) kwh_per_kg
  from fabula.v_energy_per_kg where meter = 'elec_main' and production_date between ws and we),
proc as (
  select (select count(*) from fabula.purchase_orders where order_date between ws and we and source = 'agent:procurement') pos_proposed,
         (select count(*) from fabula.purchase_orders where order_date between ws and we and status in ('approved','sent','received','partially_received')) pos_approved,
         (select coalesce(sum(subtotal_eur), 0) from fabula.purchase_orders where order_date between ws and we and status in ('approved','sent','received','partially_received')) approved_eur,
         -- consumables actually used this week, valued at the latest supplier list price (fallback: benchmark/52)
         coalesce((select sum(-sm.qty * sp.price_eur) from fabula.stock_moves sm join fabula.products p on p.id = sm.product_id
                   left join lateral (select price_eur from fabula.supplier_prices where product_id = sm.product_id and valid_from <= we order by valid_from desc limit 1) sp on true
                   where p.kind in ('consumable','packaging') and sm.qty < 0 and sm.move_type in ('production_in','adjustment') and sm.moved_at::date between ws and we),
                  round(fabula.setting_num('opex.consumables_eur_year', 27978) / 52, 2)) consumables_used_eur,
         (select coalesce(jsonb_agg(sku), '[]') from (select p.sku from fabula.stock_moves sm join fabula.products p on p.id = sm.product_id
             where p.kind in ('consumable','packaging') and sm.qty < 0 and sm.moved_at::date between ws and we
               and not exists (select 1 from fabula.supplier_prices where product_id = sm.product_id) group by p.sku) u) unpriced_skus),
plan as (
  select count(*) plans, count(*) filter (where status = 'approved') approved, count(*) filter (where status = 'rejected') rejected
  from fabula.milk_plans where plan_date between ws and we)
select jsonb_build_object(
  'production', jsonb_build_object('milk_received_kg', milk.received_kg, 'milk_rejected_deliveries', milk.rejected, 'milk_cost_eur', round(milk.cost_eur, 2),
                                   'milk_processed_kg', prod.milk_kg, 'mozzarella_kg', prod.moz_kg, 'ricotta_kg', prod.ric_kg, 'batches', prod.moz_batches, 'days_produced', prod.days_produced,
                                   'yield_pct', prod.yield_pct, 'yield_30d_pct', prod.yield_30d),
  'sales', jsonb_build_object('revenue_eur', round(sales.revenue_eur, 2), 'orders', sales.orders, 'by_channel_eur', sales.by_channel,
                              'mozzarella_sold_kg', kg.moz_sold_kg, 'ricotta_sold_kg', kg.ric_sold_kg,
                              'avg_price_moz_eur_kg', case when kg.moz_sold_kg > 0 then round((select coalesce(sum(l.qty * l.unit_price_eur), 0) from fabula.sales_order_lines l join fabula.sales_orders o on o.id = l.sales_order_id where l.product_id = v_moz and o.order_date between ws and we and o.status in ('confirmed','fulfilled')) / nullif((select sum(l.qty) from fabula.sales_order_lines l join fabula.sales_orders o on o.id = l.sales_order_id where l.product_id = v_moz and o.order_date between ws and we and o.status in ('confirmed','fulfilled')), 0), 2) end,
                              'sell_through_pct', case when prod.moz_kg > 0 then round(kg.moz_sold_kg / prod.moz_kg * 100, 1) end),
  'waste', jsonb_build_object('mozzarella_kg', waste.moz_kg, 'total_kg', waste.total_kg, 'pct_of_mozzarella_output', case when prod.moz_kg > 0 then round(waste.moz_kg / prod.moz_kg * 100, 1) end,
                              'value_at_milk_cost_eur', case when prod.yield_pct > 0 then round(waste.moz_kg / prod.yield_pct * 100 * 1.30, 2) end),
  'compliance', jsonb_build_object('checks_logged', haccp.checks, 'missing_checks', haccp.missing_checks, 'non_conformities', haccp.nc_opened,
                                   'pos_closes', pos.closes, 'pos_closes_with_variance', pos.with_variance, 'pos_abs_variance_eur', pos.abs_variance_eur),
  'energy', jsonb_build_object('kwh', energy.kwh, 'kwh_per_kg', energy.kwh_per_kg),
  'procurement', jsonb_build_object('pos_proposed', proc.pos_proposed, 'pos_approved', proc.pos_approved, 'approved_eur', proc.approved_eur,
                                    'consumables_used_eur', round(proc.consumables_used_eur, 2), 'unpriced_skus', proc.unpriced_skus),
  'milk_plans', jsonb_build_object('proposed', plan.plans, 'approved', plan.approved, 'rejected', plan.rejected))
from prod, milk, sales, kg, waste, haccp, pos, energy, proc, plan;
$$;

grant execute on function fabula.weekly_brief(date), fabula._week_block(date, date, uuid, uuid) to authenticated, service_role;
