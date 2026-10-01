-- =============================================================================
-- v0.4: reporting function for the daily brief bot.
--   select fabula.daily_brief();                 -- yesterday (Europe/Rome)
--   select fabula.daily_brief(date '2026-09-29');
-- Returns one jsonb document: production, sales, stock, compliance, energy,
-- procurement signals, open approvals. The bot narrates; it never computes.
-- =============================================================================
set search_path = fabula, public;

create or replace function fabula.daily_brief(p_date date default (now() at time zone 'Europe/Rome')::date - 1)
returns jsonb language sql stable as $$
with
prod as (
  select coalesce(jsonb_agg(jsonb_build_object('product', product, 'batches', batches, 'milk_in_kg', milk_in_kg, 'output_kg', output_kg, 'yield_pct', yield_pct)), '[]') j
  from fabula.v_daily_production where batch_date = p_date),
yield_trend as (
  select jsonb_build_object(
    'yesterday', (select yield_pct from fabula.v_daily_production where batch_date = p_date and product like 'Mozzarella%'),
    'avg_7d', (select round(avg(yield_pct),2) from fabula.v_daily_production where batch_date between p_date-6 and p_date and product like 'Mozzarella%'),
    'avg_30d', (select round(avg(yield_pct),2) from fabula.v_daily_production where batch_date between p_date-29 and p_date and product like 'Mozzarella%')) j),
milk as (
  select coalesce(jsonb_agg(jsonb_build_object('lot', milk_lot, 'kg', qty_kg, 'temp_c', temperature_c, 'accepted', accepted, 'reason', rejection_reason)), '[]') j
  from fabula.milk_intake where intake_date = p_date),
sales as (
  select coalesce(jsonb_agg(jsonb_build_object('channel', channel, 'orders', orders, 'revenue_eur', revenue_eur)), '[]') j
  from fabula.v_daily_sales where order_date = p_date),
sales_trend as (
  select jsonb_build_object(
    'yesterday_eur', (select coalesce(sum(revenue_eur),0) from fabula.v_daily_sales where order_date = p_date),
    'same_weekday_avg_4w_eur', (select round(coalesce(avg(t),0),2) from (select sum(revenue_eur) t from fabula.v_daily_sales where order_date in (p_date-7, p_date-14, p_date-21, p_date-28) group by order_date) x),
    'week_to_date_eur', (select coalesce(sum(revenue_eur),0) from fabula.v_daily_sales where order_date between date_trunc('week', p_date)::date and p_date)) j),
pos_close as (
  select coalesce(jsonb_build_object('rt_total_eur', rt_total_eur, 'recorded_eur', recorded_total_eur, 'variance_eur', variance_eur), '{"missing": true}')
  j from fabula.pos_daily_closings where closing_date = p_date),
stock as (
  select coalesce(jsonb_agg(jsonb_build_object('sku', sku, 'lot', lot_number, 'kg', qty_on_hand, 'expires', expiry_date) order by expiry_date), '[]') j
  from fabula.v_stock_on_hand where kind = 'finished_good' and qty_on_hand > 0),
waste as (
  select jsonb_build_object(
    'yesterday_kg', (select coalesce(sum(qty),0) from fabula.waste_log where wasted_at::date = p_date),
    'last_7d_kg', (select coalesce(sum(qty),0) from fabula.waste_log where wasted_at::date between p_date-6 and p_date),
    'last_7d_pct_of_output', (select round(100 * coalesce(sum(w.qty),0) / nullif((select sum(output_kg) from fabula.production_batches where batch_date between p_date-6 and p_date),0), 1) from fabula.waste_log w where w.wasted_at::date between p_date-6 and p_date)) j),
haccp as (
  select jsonb_build_object(
    'checks_logged', (select count(*) from fabula.haccp_log where logged_at::date = p_date),
    'non_conformities', (select coalesce(jsonb_agg(jsonb_build_object('point', cp.code, 'value', l.measured_value, 'action', l.corrective_action)), '[]') from fabula.haccp_log l join fabula.haccp_control_points cp on cp.id = l.control_point_id where l.logged_at::date = p_date and l.result = 'non_conformity'),
    'missing_daily_checks', (select coalesce(jsonb_agg(cp.code), '[]') from fabula.haccp_control_points cp where cp.active and cp.frequency in ('daily','twice_daily') and not exists (select 1 from fabula.haccp_log l where l.control_point_id = cp.id and l.logged_at::date = p_date)),
    'evening_cold_checks_missing', (select coalesce(jsonb_agg(cp.code), '[]') from fabula.haccp_control_points cp where cp.active and cp.frequency = 'twice_daily' and not exists (select 1 from fabula.haccp_log l where l.control_point_id = cp.id and l.logged_at::date = p_date and l.logged_at::time >= time '15:00'))) j),
tasks as (
  select jsonb_build_object(
    'overdue', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'title', title_it, 'due', due_at)), '[]') from fabula.v_tasks_open where status = 'overdue'),
    'open_non_conformities', (select count(*) from fabula.non_conformities where status in ('open','investigating')),
    'calibration_due', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'due', next_calibration_on)), '[]') from fabula.equipment where active and next_calibration_on <= p_date + 14),
    'training_expiring', (select coalesce(jsonb_agg(jsonb_build_object('name', full_name, 'expires', haccp_training_expires)), '[]') from fabula.staff where active and haccp_training_expires <= p_date + 30)) j),
energy as (
  select jsonb_build_object(
    'yesterday_kwh', (select consumed from fabula.v_energy_per_kg where production_date = p_date and meter = 'elec_main'),
    'yesterday_kwh_per_kg', (select per_kg_output from fabula.v_energy_per_kg where production_date = p_date and meter = 'elec_main'),
    'avg_30d_kwh_per_kg', (select round(avg(per_kg_output),3) from fabula.v_energy_per_kg where production_date between p_date-29 and p_date and meter = 'elec_main' and per_kg_output is not null)) j),
procurement as (
  select coalesce(jsonb_agg(jsonb_build_object('sku', s.sku, 'name', s.name, 'on_hand', s.qty_on_hand, 'reorder_point', s.reorder_point,
           'daily_use', u.daily_use, 'days_cover', case when u.daily_use > 0 then round(s.qty_on_hand / u.daily_use, 1) end, 'reorder_qty', p.reorder_qty, 'supplier', sp.legal_name)), '[]') j
  from (select product_id, sku, name, sum(qty_on_hand) qty_on_hand, max(reorder_point) reorder_point from fabula.v_stock_on_hand where kind in ('consumable','packaging') group by product_id, sku, name) s
  join fabula.products p on p.id = s.product_id
  left join fabula.parties sp on sp.id = p.preferred_supplier_id
  left join lateral (select round(coalesce(-sum(qty),0) / 14.0, 3) daily_use from fabula.stock_moves where product_id = s.product_id and qty < 0 and moved_at::date between p_date-13 and p_date) u on true
  where s.reorder_point is not null and (s.qty_on_hand <= s.reorder_point or (u.daily_use > 0 and s.qty_on_hand / u.daily_use < 10))),
approvals as (
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'summary', summary, 'amount_eur', amount_eur, 'requested_by', requested_by, 'age_days', (p_date - requested_at::date))), '[]') j
  from fabula.approvals where status = 'pending')
select jsonb_build_object(
  'date', p_date,
  'weekday', to_char(p_date, 'Day'),
  'is_simulation', exists (select 1 from fabula.simulation_runs where p_date between from_date and to_date),
  'production', (select j from prod),
  'yield', (select j from yield_trend),
  'milk', (select j from milk),
  'sales', (select j from sales),
  'sales_trend', (select j from sales_trend),
  'pos_close', (select j from pos_close),
  'stock_finished', (select j from stock),
  'waste', (select j from waste),
  'haccp', (select j from haccp),
  'tasks', (select j from tasks),
  'energy', (select j from energy),
  'procurement_signals', (select j from procurement),
  'pending_approvals', (select j from approvals));
$$;

grant execute on function fabula.daily_brief(date) to authenticated, service_role;
