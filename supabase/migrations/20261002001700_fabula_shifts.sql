-- =============================================================================
-- v0.17: shift hours → real labor cost.
--   Scanning your own STAFF badge on the tablet clocks you in; scanning it again
--   clocks you out. One tap, nothing to type. fabula.shifts keeps the hours;
--   weekly_brief() uses actual hours × labor.hourly_cost_eur when hours exist
--   (labor_source = 'actual'), else the OpEx benchmark as before.
-- Written without destructive keywords (connector rule).
-- =============================================================================
set search_path = fabula, public;

create table if not exists fabula.shifts (
  id          uuid primary key default gen_random_uuid(),
  staff_id    uuid not null references fabula.staff(id),
  clock_in    timestamptz not null default now(),
  clock_out   timestamptz,
  hours       numeric(6,2) generated always as (case when clock_out is not null then round(extract(epoch from (clock_out - clock_in)) / 3600.0, 2) end) stored,
  source      text not null default 'tablet',
  notes       text
);
create index if not exists shifts_open_idx on fabula.shifts (staff_id) where clock_out is null;
create index if not exists shifts_day_idx on fabula.shifts (clock_in);
grant all on fabula.shifts to authenticated, service_role;
alter table fabula.shifts enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='fabula' and tablename='shifts' and policyname='shifts_authenticated_all') then
    create policy shifts_authenticated_all on fabula.shifts for all to authenticated using (true) with check (true);
  end if;
end $$;

insert into fabula.settings (key, value, description) values
  ('labor.hourly_cost_eur', '14.50', 'Costo orario aziendale medio (lordo + contributi) usato per il costo del lavoro reale'),
  ('labor.max_shift_hours', '12',    'Oltre queste ore un turno aperto si chiude da solo (badge dimenticato)')
on conflict (key) do nothing;

-- One call per badge scan: opens a shift if none is open, otherwise closes it.
create or replace function fabula.toggle_shift(p_badge text, p_staff_id uuid default null)
returns jsonb language plpgsql as $$
declare v_staff record; v_open record; v_max numeric := fabula.setting_num('labor.max_shift_hours', 12);
begin
  select * into v_staff from fabula.staff where (badge_code = p_badge or id = p_staff_id) and active limit 1;
  if v_staff is null then raise exception 'Badge sconosciuto: %', p_badge; end if;
  -- forgotten badge-out: auto-close anything older than max hours before deciding
  update fabula.shifts set clock_out = clock_in + make_interval(hours => v_max::int), notes = coalesce(notes || ' · ', '') || 'chiuso automaticamente (badge dimenticato)'
   where staff_id = v_staff.id and clock_out is null and clock_in < now() - make_interval(hours => v_max::int);
  select * into v_open from fabula.shifts where staff_id = v_staff.id and clock_out is null order by clock_in desc limit 1;
  if v_open is null then
    insert into fabula.shifts (staff_id) values (v_staff.id) returning * into v_open;
    return jsonb_build_object('action', 'in', 'staff', v_staff.full_name, 'at', v_open.clock_in);
  else
    update fabula.shifts set clock_out = now() where id = v_open.id returning * into v_open;
    return jsonb_build_object('action', 'out', 'staff', v_staff.full_name, 'at', v_open.clock_out, 'hours', v_open.hours);
  end if;
end $$;
grant execute on function fabula.toggle_shift(text, uuid) to authenticated, service_role;

create or replace view fabula.v_open_shifts as
select s.id, s.staff_id, st.full_name, s.clock_in, round(extract(epoch from (now() - s.clock_in)) / 3600.0, 1) as hours_so_far
from fabula.shifts s join fabula.staff st on st.id = s.staff_id where s.clock_out is null order by s.clock_in;
grant select on fabula.v_open_shifts to authenticated, service_role;

create or replace view fabula.v_labor_weekly as
select date_trunc('week', (clock_in at time zone 'Europe/Rome'))::date as week_start,
       count(distinct staff_id) as people, count(*) as shifts, round(sum(hours), 1) as hours,
       round(sum(hours) * fabula.setting_num('labor.hourly_cost_eur', 14.5), 2) as labor_eur
from fabula.shifts where clock_out is not null group by 1 order by 1 desc;
grant select on fabula.v_labor_weekly to authenticated, service_role;

-- weekly_brief: labor from actual hours when available; stock count & shrink block
create or replace function fabula.weekly_brief(p_week_end date default null)
returns jsonb language plpgsql stable as $$
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
    'lease_eur',     round(fabula.setting_num('opex.lease_eur_year', 14400) / 52, 2),
    'basis', case when v_labor_src = 'actual' then 'revenue, milk and labor (badge hours × hourly cost) real; consumables at list price; utilities, marketing, lease = benchmark/52'
                  else 'revenue and milk real; consumables at list price; labor, utilities, marketing, lease = benchmark/52 (no badge hours this week)' end);
  pl := pl || jsonb_build_object('operating_result_eur',
          round((pl->>'revenue_eur')::numeric - (pl->>'milk_cost_eur')::numeric - (pl->>'consumables_cost_eur')::numeric
                - (pl->>'labor_eur')::numeric - (pl->>'utilities_eur')::numeric - (pl->>'marketing_eur')::numeric - (pl->>'lease_eur')::numeric, 2));
  pl := pl || jsonb_build_object('margin_pct', case when (pl->>'revenue_eur')::numeric > 0 then round((pl->>'operating_result_eur')::numeric / (pl->>'revenue_eur')::numeric * 100, 1) end,
          'benchmark_weekly_profit_eur', round(220787.0 / 52, 2),
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
end $$;

-- the evening nudge also flags badges still open at 19:00
create or replace function fabula.haccp_evening_status(p_date date default (now() at time zone 'Europe/Rome')::date)
returns jsonb language plpgsql as $$
declare items jsonb := '[]'; v_key text := 'haccp_evening:' || p_date; n int;
begin
  select coalesce(jsonb_agg(jsonb_build_object('code', 'cold:' || cp.code, 'label_it', 'Temperatura serale ' || coalesce(e.code, cp.name), 'scan', 'EQ:' || e.code) order by cp.code), '[]') into items
  from fabula.haccp_control_points cp left join fabula.equipment e on e.id = cp.equipment_id
  where cp.active and cp.frequency = 'twice_daily'
    and not exists (select 1 from fabula.haccp_log l where l.control_point_id = cp.id and l.logged_at::date = p_date and (l.logged_at at time zone 'Europe/Rome')::time >= time '15:00');
  if not exists (select 1 from fabula.haccp_log l join fabula.haccp_control_points cp on cp.id = l.control_point_id where cp.code = 'PRP-CLEAN' and l.logged_at::date = p_date) then
    items := items || jsonb_build_object('code', 'clean', 'label_it', 'Sanificazione fine turno', 'scan', 'CLEAN:');
  end if;
  if exists (select 1 from fabula.production_batches where batch_date = p_date) or exists (select 1 from fabula.sales_orders where order_date = p_date) then
    if not exists (select 1 from fabula.pos_daily_closings where closing_date = p_date) then
      items := items || jsonb_build_object('code', 'z', 'label_it', 'Chiusura cassa (scontrino Z)', 'scan', 'EQ:RT-01'); end if;
    if not exists (select 1 from fabula.meter_readings where meter = 'elec_main' and read_at::date = p_date) then
      items := items || jsonb_build_object('code', 'kwh', 'label_it', 'Lettura contatore', 'scan', 'METER:elec_main'); end if;
  end if;
  select items || coalesce(jsonb_agg(jsonb_build_object('code', 'batch:' || batch_lot, 'label_it', 'Lotto ' || batch_lot || ' non chiuso (kg prodotto)', 'scan', 'LOT:' || batch_lot)), '[]') into items
  from fabula.production_batches where batch_date = p_date and output_kg is null and source <> 'simulation';
  select items || coalesce(jsonb_agg(jsonb_build_object('code', 'shift:' || st.badge_code, 'label_it', st.full_name || ': badge di uscita non passato', 'scan', st.badge_code)), '[]') into items
  from fabula.shifts s join fabula.staff st on st.id = s.staff_id where s.clock_out is null and (s.clock_in at time zone 'Europe/Rome')::date = p_date;
  n := jsonb_array_length(items);
  if n > 0 then
    insert into fabula.notices (key, severity, title_it, items, expires_at)
    values (v_key, 'alert', format('Prima di chiudere: %s cose da registrare', n), items, ((p_date + 1)::timestamp + time '05:00') at time zone 'Europe/Rome')
    on conflict (key) do update set items = excluded.items, title_it = excluded.title_it, resolved_at = null;
  else
    update fabula.notices set resolved_at = now() where key = v_key and resolved_at is null;
  end if;
  return jsonb_build_object('date', p_date, 'missing', items, 'count', n,
    'is_simulation', exists (select 1 from fabula.simulation_runs where p_date between from_date and to_date),
    'closed_day', not (exists (select 1 from fabula.production_batches where batch_date = p_date) or exists (select 1 from fabula.sales_orders where order_date = p_date)));
end $$;
