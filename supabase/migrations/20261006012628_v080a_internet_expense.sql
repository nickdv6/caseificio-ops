-- v0.80a (06/10/2026) · Internet service added to the expenses: €50/month = €600/yr (assumption, Nick 05/10).
-- New setting opex.internet_eur_year (Configurazione → Parametri, opex group). The weekly brief P&L gets an internet_eur
-- line (= setting/52 ≈ €11.54/week) and subtracts it from the operating result.
-- Plan benchmark: €150,900 − €600 = €150,300/yr in year 1 (≈ €2,890/week); ≈ €149,700 from 2028 with the €1,100 rent.

insert into fabula.settings (key, value, description, data_type, sort, updated_at) values
 ('opex.internet_eur_year', '600', 'Connessione internet del negozio/laboratorio: € 50/mese IVA esclusa (ipotesi, da sostituire con il contratto)', 'number', 93, now()),
 ('benchmark.annual_profit_eur', '150300', 'Utile operativo annuo di piano, primo anno (investment brief v49 + affitto concordato € 1.050/mese − internet € 600) — riferimento del brief settimanale (≈ € 2.890/settimana)', 'number', 7, now())
on conflict (key) do update set value = excluded.value, description = excluded.description, data_type = excluded.data_type, sort = excluded.sort, updated_at = excluded.updated_at;

create or replace function fabula.weekly_brief(p_week_end date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'fabula', 'public', 'extensions'
AS $function$
declare
  we date; ws date; pwe date; pws date; v_moz uuid; v_ric uuid;
  cur jsonb; prev jsonb; pl jsonb; v_hours numeric; v_rate numeric; v_labor numeric; v_labor_src text; v_prev_hours numeric;
begin
  we := coalesce(p_week_end, (date_trunc('week', (now() at time zone 'Europe/Rome')::date)::date - 2));
  ws := we - 5; pwe := we - 7; pws := ws - 7;
  select id into v_moz from fabula.products where sku = 'MOZ-DOP-KG';
  select id into v_ric from fabula.products where sku = 'RIC-BUF-KG';
  cur  := fabula._week_block(ws, we, v_moz, v_ric);
  prev := fabula._week_block(pws, pwe, v_moz, v_ric);

  v_rate := fabula.setting_num('labor.hourly_cost_eur', 14.5);
  select round(coalesce(sum(hours), 0), 1) into v_hours from fabula.shifts where clock_out is not null and (clock_in at time zone 'Europe/Rome')::date between ws and we;
  select round(coalesce(sum(hours), 0), 1) into v_prev_hours from fabula.shifts where clock_out is not null and (clock_in at time zone 'Europe/Rome')::date between pws and pwe;
  if v_hours > 0 then v_labor := round(v_hours * v_rate, 2); v_labor_src := 'actual';
  else v_labor := round(fabula.setting_num('opex.labor_eur_year', 68205) / 52, 2); v_labor_src := 'benchmark'; end if;

  pl := jsonb_build_object(
    'revenue_eur',          (cur->'sales'->>'revenue_eur')::numeric,
    'milk_cost_eur',        (cur->'production'->>'milk_cost_eur')::numeric,
    'consumables_cost_eur', (cur->'procurement'->>'consumables_used_eur')::numeric,
    'labor_eur', v_labor, 'labor_source', v_labor_src, 'labor_hours', v_hours, 'labor_hours_prev', v_prev_hours, 'labor_rate_eur_h', v_rate,
    'utilities_eur', round(fabula.setting_num('opex.utilities_eur_year', 27660) / 52, 2),
    'marketing_eur', round(fabula.setting_num('opex.marketing_eur_year', 15900) / 52, 2),
    'lease_eur',     round(fabula.lease_eur_year(we) / 52, 2),
    'internet_eur',  round(fabula.setting_num('opex.internet_eur_year', 600) / 52, 2),
    'basis', case when v_labor_src = 'actual' then 'revenue, milk and labor (badge hours × hourly cost) real; consumables at list price; utilities, marketing, lease, internet = benchmark/52'
                  else 'revenue and milk real; consumables at list price; labor, utilities, marketing, lease, internet = benchmark/52 (no badge hours this week)' end);
  pl := pl || jsonb_build_object('operating_result_eur',
          round((pl->>'revenue_eur')::numeric - (pl->>'milk_cost_eur')::numeric - (pl->>'consumables_cost_eur')::numeric
                - (pl->>'labor_eur')::numeric - (pl->>'utilities_eur')::numeric - (pl->>'marketing_eur')::numeric - (pl->>'lease_eur')::numeric
                - (pl->>'internet_eur')::numeric, 2));
  pl := pl || jsonb_build_object('margin_pct', case when (pl->>'revenue_eur')::numeric > 0 then round((pl->>'operating_result_eur')::numeric / (pl->>'revenue_eur')::numeric * 100, 1) end,
          'benchmark_weekly_profit_eur', round(fabula.setting_num('benchmark.annual_profit_eur', 155500) / 52, 2),
          'labor_eur_per_kg', case when (cur->'production'->>'mozzarella_kg')::numeric > 0 and v_hours > 0 then round(v_labor / (cur->'production'->>'mozzarella_kg')::numeric, 2) end);

  return jsonb_build_object(
    'week_start', ws, 'week_end', we, 'week_number', extract(week from we),
    'is_simulation', exists (select 1 from fabula.simulation_runs where ws between from_date and to_date or we between from_date and to_date),
    'this_week', cur, 'previous_week', prev, 'pnl_estimate', pl,
    'stock_count', (select coalesce(jsonb_agg(jsonb_build_object('date', counted_at::date, 'lines', lines_total, 'changed', lines_changed, 'shrink_eur', shrink_eur) order by counted_at), '[]')
                    from fabula.stock_counts where status = 'posted' and (counted_at at time zone 'Europe/Rome')::date between ws and we),
    'milk_plan_accuracy', (select coalesce(jsonb_agg(jsonb_build_object('date', plan_date, 'planned_milk_kg', planned_milk_kg, 'actual_milk_kg', actual_milk_kg, 'forecast_demand_kg', forecast_demand_kg, 'actual_sales_kg', actual_sales_kg, 'waste_kg', waste_kg) order by plan_date), '[]')
                            from fabula.v_milk_plan_accuracy where plan_date between ws and we and status = 'approved'),
    'open_items', jsonb_build_object(
      'pending_approvals', (select count(*) from fabula.approvals where status = 'pending'),
      'oldest_pending_days', (select max(greatest(0, (now() at time zone 'Europe/Rome')::date - requested_at::date)) from fabula.approvals where status = 'pending'),
      'open_non_conformities', (select count(*) from fabula.non_conformities where status in ('open','investigating')),
      'calibration_due_30d', (select coalesce(jsonb_agg(code), '[]') from fabula.equipment where active and next_calibration_on <= we + 30),
      'training_expiring_60d', (select coalesce(jsonb_agg(full_name), '[]') from fabula.staff where active and haccp_training_expires <= we + 60),
      'bot_errors', (select count(*) from fabula.agent_runs where status = 'error' and started_at::date between ws and we),
      'open_shifts_now', (select count(*) from fabula.shifts where clock_out is null)));
end $function$;
