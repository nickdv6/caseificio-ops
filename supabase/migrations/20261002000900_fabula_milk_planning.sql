-- =============================================================================
-- v0.9: milk planning — how much milk to take tomorrow.
--   select fabula.plan_milk();                 -- plans the next production day (Europe/Rome; Sunday → Monday)
--   select fabula.plan_milk(date '2026-10-06');
-- Demand = same-weekday sales over the last 4 weeks (+ confirmed wholesale orders for the day),
-- minus fresh stock that will still be sellable, plus a safety margin; converted to milk with the
-- 30-day yield; rounded up to 25 kg; capped at vat capacity. Writes fabula.milk_plans (proposed)
-- + one approvals row. Approving on the console flips the plan via the approvals trigger.
-- The bot narrates the JSON; it never computes. Nothing is ordered from the farm here.
-- =============================================================================
set search_path = fabula, public;

create table if not exists fabula.milk_plans (
  id                  uuid primary key default gen_random_uuid(),
  plan_date           date not null,
  created_at          timestamptz not null default now(),
  proposed_by         text not null default 'agent:milk_planning',
  status              text not null default 'proposed' check (status in ('proposed','approved','rejected','superseded')),
  demand_retail_kg    numeric(10,2),
  demand_wholesale_kg numeric(10,2),
  carry_kg            numeric(10,2),          -- fresh mozzarella already on the shelf, counted against demand
  safety_kg           numeric(10,2),
  planned_output_kg   numeric(10,2),
  yield_pct_used      numeric(5,2),
  milk_kg             numeric(10,1),
  est_cost_eur        numeric(10,2),
  rationale           text,
  details             jsonb,
  approval_id         uuid references fabula.approvals(id)
);
create unique index if not exists milk_plans_active_idx on fabula.milk_plans (plan_date) where status in ('proposed','approved');
grant select on fabula.milk_plans to authenticated;
grant select, insert, update, delete on fabula.milk_plans to service_role;
alter table fabula.milk_plans enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='fabula' and tablename='milk_plans' and policyname='milk_plans_read') then
    create policy milk_plans_read on fabula.milk_plans for select to authenticated using (true);
  end if;
end $$;

-- approvals → purchase_orders AND milk_plans
create or replace function fabula.sync_po_from_approval() returns trigger language plpgsql as $$
begin
  if new.status is distinct from old.status and new.related_id is not null then
    if new.related_table = 'purchase_orders' then
      update fabula.purchase_orders set status = case new.status when 'approved' then 'approved'::fabula.po_status when 'rejected' then 'cancelled'::fabula.po_status else status end
      where id = new.related_id;
    elsif new.related_table = 'milk_plans' then
      update fabula.milk_plans set status = case new.status when 'approved' then 'approved' when 'rejected' then 'rejected' when 'expired' then 'rejected' else status end
      where id = new.related_id;
    end if;
  end if;
  return new;
end $$;

-- Tunables the owner can change without a redeploy (console later)
create table if not exists fabula.settings (
  key text primary key, value text not null, description text, updated_at timestamptz not null default now());
insert into fabula.settings (key, value, description) values
  ('milk.capacity_kg', '1200', 'Capacità caldaia: kg latte lavorabili al giorno'),
  ('milk.round_kg',    '25',   'Arrotondamento del piano latte (kg)'),
  ('milk.safety_pct',  '10',   'Margine di sicurezza sulla domanda prevista (%)'),
  ('milk.carry_pct',   '50',   'Quanto conta la mozzarella fresca già in giacenza contro la domanda (%)'),
  ('milk.min_run_kg',  '300',  'Lotto minimo di latte che vale la pena avviare (kg)')
on conflict (key) do nothing;
grant select on fabula.settings to authenticated;
grant select, insert, update, delete on fabula.settings to service_role;
alter table fabula.settings enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='fabula' and tablename='settings' and policyname='settings_read') then
    create policy settings_read on fabula.settings for select to authenticated using (true);
  end if;
end $$;
create or replace function fabula.setting_num(p_key text, p_default numeric) returns numeric language sql stable as $$
  select coalesce((select value::numeric from fabula.settings where key = p_key), p_default) $$;
grant execute on function fabula.setting_num(text, numeric) to authenticated, service_role;

create or replace function fabula.plan_milk(p_date date default null, p_capacity_kg numeric default null, p_round_kg numeric default null, p_safety_pct numeric default null)
returns jsonb language plpgsql as $$
declare
  d date; v_moz uuid; v_n int; v_total numeric; v_whole_hist numeric; v_whole_conf numeric; v_retail numeric; v_whole numeric;
  v_carry numeric; v_safety numeric; v_out numeric; v_yield numeric; v_yield_src text; v_milk numeric; v_milk_r numeric; v_cap boolean := false;
  v_price numeric; v_cost numeric; v_last_milk numeric; v_waste numeric; v_hist_src text; v_id uuid; v_appr uuid; v_rat text; v_sim boolean;
  v_dates date[]; v_carry_raw numeric; v_min boolean := false; v_wd text;
  wd constant text[] := array['lunedì','martedì','mercoledì','giovedì','venerdì','sabato','domenica'];
  p_carry_pct numeric; p_min_kg numeric;
begin
  -- tunables: argument wins, else fabula.settings, else default
  p_capacity_kg := coalesce(p_capacity_kg, fabula.setting_num('milk.capacity_kg', 1200));
  p_round_kg    := coalesce(p_round_kg,    fabula.setting_num('milk.round_kg', 25));
  p_safety_pct  := coalesce(p_safety_pct,  fabula.setting_num('milk.safety_pct', 10));
  p_carry_pct   := fabula.setting_num('milk.carry_pct', 50);
  p_min_kg      := fabula.setting_num('milk.min_run_kg', 300);
  d := coalesce(p_date, (now() at time zone 'Europe/Rome')::date + 1);
  if extract(isodow from d) = 7 then d := d + 1; end if;                     -- closed Sundays
  v_dates := array[d-7, d-14, d-21, d-28]; v_wd := wd[extract(isodow from d)];
  select id into v_moz from fabula.products where sku = 'MOZ-DOP-KG';

  if exists (select 1 from fabula.milk_plans where plan_date = d and status in ('proposed','approved')) then
    return jsonb_build_object('date', d, 'skipped', 'plan_exists',
      'plan', (select jsonb_build_object('milk_kg', milk_kg, 'status', status, 'planned_output_kg', planned_output_kg) from fabula.milk_plans where plan_date = d and status in ('proposed','approved')));
  end if;

  -- demand history: same weekday, last 4 weeks (all channels; wholesale separated when the order is known)
  select count(*), coalesce(avg(total),0), coalesce(avg(whole),0) into v_n, v_total, v_whole_hist from (
    select sm.moved_at::date sd, sum(-sm.qty) total, sum(case when so.channel = 'wholesale' then -sm.qty else 0 end) whole
    from fabula.stock_moves sm left join fabula.sales_orders so on so.id = sm.sales_order_id
    where sm.product_id = v_moz and sm.move_type = 'sale' and sm.moved_at::date = any(v_dates)
    group by sm.moved_at::date) x;
  v_hist_src := 'same_weekday_4w';
  if v_n = 0 then                                                            -- fallback: any day, last 28 days
    select count(*), coalesce(avg(total),0) into v_n, v_total from (
      select sm.moved_at::date sd, sum(-sm.qty) total from fabula.stock_moves sm
      where sm.product_id = v_moz and sm.move_type = 'sale' and sm.moved_at::date between d-28 and d-1 group by sm.moved_at::date) x;
    v_whole_hist := 0; v_hist_src := case when v_n > 0 then 'any_day_28d' else 'none' end;
  end if;
  -- confirmed wholesale orders already booked for the day replace the historical wholesale share
  select coalesce(sum(l.qty),0) into v_whole_conf from fabula.sales_order_lines l join fabula.sales_orders o on o.id = l.sales_order_id
   where l.product_id = v_moz and o.channel = 'wholesale' and o.order_date = d and o.status = 'confirmed';
  v_retail := round(v_total - v_whole_hist, 1);
  v_whole  := round(case when v_whole_conf > 0 then v_whole_conf else v_whole_hist end, 1);

  -- fresh stock (≤ 2 days old on the plan date), counted at p_carry_pct: older mozzarella does not sell like fresh
  select coalesce(sum(qty_on_hand),0) into v_carry_raw from fabula.v_stock_on_hand where product_id = v_moz and expiry_date >= d + 3;
  v_carry := round(v_carry_raw * p_carry_pct / 100, 1);

  v_safety := round((v_retail + v_whole) * p_safety_pct / 100, 1);
  v_out := greatest(0, round(v_retail + v_whole + v_safety - v_carry, 1));

  select round(avg(yield_pct),2) into v_yield from fabula.production_batches where product_id = v_moz and output_kg is not null and batch_date between d-30 and d-1;
  v_yield_src := 'avg_30d'; if v_yield is null or v_yield <= 0 then v_yield := 30; v_yield_src := 'assumption'; end if;

  if v_hist_src = 'none' then                                                -- no sales history: repeat recent intake, else capacity
    select round(avg(qty_kg),1) into v_milk from fabula.milk_intake where accepted and intake_date between d-28 and d-1;
    v_milk := coalesce(v_milk, p_capacity_kg); v_out := round(v_milk * v_yield / 100, 1);
  else
    v_milk := round(v_out / v_yield * 100, 1);
  end if;
  v_milk_r := ceil(v_milk / p_round_kg) * p_round_kg;
  if v_milk_r < p_min_kg then v_milk_r := p_min_kg; v_min := true; end if;        -- below this a vat run is not worth starting
  if v_milk_r > p_capacity_kg then v_milk_r := p_capacity_kg; v_cap := true; end if;

  select coalesce(round(avg(price_eur_per_kg),4), 1.30) into v_price from fabula.milk_intake where intake_date between d-30 and d-1 and price_eur_per_kg is not null;
  v_cost := round(v_milk_r * v_price, 2);
  select round(avg(t),0) into v_last_milk from (select sum(qty_kg) t from fabula.milk_intake where accepted and intake_date = any(v_dates) group by intake_date) x;
  select round(coalesce(avg(t),0),0) into v_waste from (select sum(qty) t from fabula.waste_log where product_id = v_moz and wasted_at::date = any(v_dates) group by wasted_at::date) x;
  v_sim := exists (select 1 from fabula.simulation_runs where d-28 between from_date and to_date or d-7 between from_date and to_date);

  v_rat := format('Piano latte %s (%s): vendite medie stesso giorno ultime 4 sett. %s kg%s, giacenza fresca %s kg, margine %s%% → produzione %s kg; resa %s%% → latte %s kg%s. Ultime 4 sett. stesso giorno: latte %s kg, scarti %s kg. Costo stimato € %s.',
    to_char(d, 'DD/MM'), v_wd, round(v_retail + v_whole_hist, 0),
    case when v_whole_conf > 0 then format(' + ordini ingrosso confermati %s kg', v_whole_conf) when v_whole_hist > 0 then format(' (ingrosso %s kg)', round(v_whole_hist,0)) else '' end,
    round(v_carry,0), p_safety_pct, v_out, v_yield, v_milk_r, case when v_cap then ' (CAPACITÀ MASSIMA)' when v_min then ' (LOTTO MINIMO)' else '' end,
    coalesce(v_last_milk::text, 'n/d'), v_waste, v_cost);

  insert into fabula.milk_plans (plan_date, demand_retail_kg, demand_wholesale_kg, carry_kg, safety_kg, planned_output_kg, yield_pct_used, milk_kg, est_cost_eur, rationale, details)
  values (d, v_retail, v_whole, v_carry, v_safety, v_out, v_yield, v_milk_r, v_cost, v_rat,
          jsonb_build_object('history_source', v_hist_src, 'history_days', v_n, 'yield_source', v_yield_src, 'milk_unrounded_kg', v_milk, 'capacity_hit', v_cap, 'min_run_applied', v_min, 'carry_raw_kg', v_carry_raw, 'carry_pct', p_carry_pct,
                             'price_eur_per_kg', v_price, 'last_4w_same_weekday_milk_kg', v_last_milk, 'last_4w_same_weekday_waste_kg', v_waste,
                             'wholesale_confirmed_kg', v_whole_conf, 'est_whey_kg', round(v_milk_r * 0.62, 0), 'est_ricotta_kg', round(v_milk_r * 0.62 * 0.07, 0), 'is_simulation', v_sim))
  returning id into v_id;

  insert into fabula.approvals (kind, requested_by, summary, payload, related_table, related_id, amount_eur, expires_at)
  values ('other', 'agent:milk_planning',
          format('Latte per %s %s: %s kg (≈ %s kg mozzarella, € %s)%s', v_wd, to_char(d,'DD/MM'), v_milk_r, v_out, v_cost, case when v_cap then ' · capacità massima' when v_min then ' · lotto minimo' else '' end),
          jsonb_build_object('type', 'milk_plan', 'plan_date', d, 'milk_kg', v_milk_r, 'planned_output_kg', v_out, 'est_cost_eur', v_cost, 'rationale', v_rat),
          'milk_plans', v_id, v_cost, ((d::timestamp + time '06:00') at time zone 'Europe/Rome'))
  returning id into v_appr;
  update fabula.milk_plans set approval_id = v_appr where id = v_id;

  return jsonb_build_object('date', d, 'weekday', v_wd, 'is_simulation', v_sim,
    'demand', jsonb_build_object('retail_kg', v_retail, 'wholesale_kg', v_whole, 'wholesale_confirmed_kg', v_whole_conf, 'history_source', v_hist_src, 'history_days', v_n),
    'carry_kg', v_carry, 'carry_raw_kg', v_carry_raw, 'carry_pct', p_carry_pct, 'safety_kg', v_safety, 'planned_output_kg', v_out,
    'yield_pct', v_yield, 'yield_source', v_yield_src,
    'milk_kg', v_milk_r, 'milk_unrounded_kg', v_milk, 'capacity_kg', p_capacity_kg, 'capacity_hit', v_cap, 'min_kg', p_min_kg, 'min_run_applied', v_min,
    'price_eur_per_kg', v_price, 'est_cost_eur', v_cost,
    'last_4w_same_weekday', jsonb_build_object('milk_kg', v_last_milk, 'waste_kg', v_waste),
    'est_whey_kg', round(v_milk_r * 0.62, 0), 'est_ricotta_kg', round(v_milk_r * 0.62 * 0.07, 0),
    'rationale', v_rat, 'plan_id', v_id, 'approval_id', v_appr);
end $$;
grant execute on function fabula.plan_milk(date, numeric, numeric, numeric) to authenticated, service_role;

-- Plan vs what actually happened, for tuning the safety margin
create or replace view fabula.v_milk_plan_accuracy as
select m.plan_date, m.status, m.milk_kg as planned_milk_kg, m.planned_output_kg,
       (select sum(qty_kg) from fabula.milk_intake i where i.intake_date = m.plan_date and i.accepted) as actual_milk_kg,
       (select sum(output_kg) from fabula.production_batches b where b.batch_date = m.plan_date and b.product_id = p.id) as actual_output_kg,
       (select -sum(qty) from fabula.stock_moves s where s.product_id = p.id and s.move_type = 'sale' and s.moved_at::date = m.plan_date) as actual_sales_kg,
       (select sum(qty) from fabula.waste_log w where w.product_id = p.id and w.wasted_at::date = m.plan_date) as waste_kg,
       m.demand_retail_kg + m.demand_wholesale_kg as forecast_demand_kg
from fabula.milk_plans m cross join (select id from fabula.products where sku = 'MOZ-DOP-KG') p
where m.status in ('approved','proposed');
grant select on fabula.v_milk_plan_accuracy to authenticated, service_role;

-- purge: plans built on simulated history go too
create or replace function fabula.purge_milk_plan_simulation() returns bigint language plpgsql as $$
declare n bigint;
begin
  delete from fabula.approvals where related_table = 'milk_plans' and related_id in (select id from fabula.milk_plans where (details->>'is_simulation')::boolean);
  delete from fabula.milk_plans where (details->>'is_simulation')::boolean; get diagnostics n = row_count; return n;
end $$;
