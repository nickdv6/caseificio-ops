-- v0.31 · 7-day demand view for the milk planner.
-- demand_7d(from = tomorrow Rome, days = 7): one row per production day (Sundays skipped) with the same logic as plan_milk():
-- retail = avg same-weekday sales last 4 weeks minus wholesale share (fallback: any-day 28 d), pickup preorders + walk-in share,
-- wholesale = confirmed orders > standing-order grid > history, safety %, fresh carry only on the first day,
-- output ÷ 30-day yield → milk rounded to milk.round_kg, min run, capped at capacity (capacity_hit), vs farm_kg_available() (farm_gap_kg),
-- milk cost at the 30-day price, and any existing proposed/approved milk plan for that date. Read-only.
-- v_demand_7d = demand_7d() for the console card "Domanda e latte · prossimi 7 giorni" (Operazioni).
-- v0.59: body restored from the live database (the original file held only this header).

CREATE OR REPLACE FUNCTION fabula.demand_7d(p_from date DEFAULT NULL::date, p_days integer DEFAULT 7)
 RETURNS TABLE(plan_date date, weekday text, retail_kg numeric, wholesale_kg numeric, wholesale_source text, preorder_kg numeric, safety_kg numeric, carry_kg numeric, output_kg numeric, yield_pct numeric, milk_kg numeric, capacity_hit boolean, farm_kg numeric, farm_gap_kg numeric, est_cost_eur numeric, history_days integer, plan_status text, plan_milk_kg numeric)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'fabula', 'public'
AS $function$
declare d date; d0 date; v_moz uuid; v_yield numeric; v_price numeric; v_cap numeric; v_round numeric; v_safety_pct numeric; v_min numeric;
  v_carry_pct numeric; v_walk_pct numeric; v_tot numeric; v_wh numeric; v_n int; v_conf numeric; v_stand numeric; v_pre numeric; v_ret numeric; v_milk numeric;
  wd constant text[] := array['lunedì','martedì','mercoledì','giovedì','venerdì','sabato','domenica'];
begin
  d0 := coalesce(p_from, (now() at time zone 'Europe/Rome')::date + 1);
  select id into v_moz from fabula.products where sku = 'MOZ-DOP-KG';
  v_cap := fabula.setting_num('milk.capacity_kg', 1200); v_round := fabula.setting_num('milk.round_kg', 25);
  v_safety_pct := fabula.setting_num('milk.safety_pct', 10); v_min := fabula.setting_num('milk.min_run_kg', 300);
  v_carry_pct := fabula.setting_num('milk.carry_pct', 50); v_walk_pct := fabula.setting_num('pickup.walkin_share_pct', 70);
  select round(avg(pb.yield_pct), 2) into v_yield from fabula.production_batches pb where pb.product_id = v_moz and pb.output_kg is not null and pb.batch_date between d0 - 31 and d0 - 1;
  if v_yield is null or v_yield <= 0 then v_yield := 30; end if;
  select coalesce(round(avg(mi.price_eur_per_kg), 4), fabula.setting_num('milk.price_eur_kg', 1.70)) into v_price from fabula.milk_intake mi where mi.intake_date between d0 - 31 and d0 - 1 and mi.price_eur_per_kg is not null;
  for i in 0 .. greatest(p_days, 1) - 1 loop
    d := d0 + i;
    continue when extract(isodow from d) = 7;
    plan_date := d; weekday := wd[extract(isodow from d)];
    -- same weekday, last 4 weeks (total and wholesale share)
    select count(*), coalesce(avg(total), 0), coalesce(avg(whole), 0) into v_n, v_tot, v_wh from (
      select sum(-sm.qty) total, sum(case when so.channel = 'wholesale' then -sm.qty else 0 end) whole
      from fabula.stock_moves sm left join fabula.sales_orders so on so.id = sm.sales_order_id
      where sm.product_id = v_moz and sm.move_type = 'sale' and sm.moved_at::date in (d - 7, d - 14, d - 21, d - 28)
      group by sm.moved_at::date) x;
    if v_n = 0 then
      select count(*), coalesce(avg(total), 0) into v_n, v_tot from (
        select sum(-sm.qty) total from fabula.stock_moves sm
        where sm.product_id = v_moz and sm.move_type = 'sale' and sm.moved_at::date between d0 - 28 and d0 - 1 group by sm.moved_at::date) x;
      v_wh := 0;
    end if;
    history_days := v_n;
    -- wholesale: confirmed orders win, then the standing-order grid, then history
    select coalesce(sum(l.qty), 0) into v_conf from fabula.sales_order_lines l join fabula.sales_orders o on o.id = l.sales_order_id
      where l.product_id = v_moz and o.channel = 'wholesale' and o.order_date = d and o.status = 'confirmed';
    select coalesce(sum(so.qty_kg), 0) into v_stand from fabula.standing_orders so where so.active and so.product_id = v_moz and so.weekday = extract(isodow from d);
    wholesale_kg := round(case when v_conf > 0 then v_conf when v_stand > 0 then v_stand else v_wh end, 1);
    wholesale_source := case when v_conf > 0 then 'ordini confermati' when v_stand > 0 then 'ordini fissi' when v_wh > 0 then 'storico' else 'nessuno' end;
    v_ret := round(v_tot - v_wh, 1);
    select coalesce(sum(kg), 0) into v_pre from fabula.v_preorder_demand where pickup_date = d and product_id = v_moz;
    preorder_kg := v_pre;
    if v_pre > 0 then v_ret := greatest(v_ret, v_pre + round(v_ret * v_walk_pct / 100, 1)); end if;
    retail_kg := v_ret;
    safety_kg := round((retail_kg + wholesale_kg) * v_safety_pct / 100, 1);
    -- fresh stock only helps the first production day
    if i = 0 or d = (select min(x) from generate_series(d0, d0 + 1, interval '1 day') x where extract(isodow from x) <> 7) then
      select round(coalesce(sum(qty_on_hand), 0) * v_carry_pct / 100, 1) into carry_kg from fabula.v_stock_on_hand where product_id = v_moz and expiry_date >= d + 3;
    else carry_kg := 0; end if;
    output_kg := greatest(0, round(retail_kg + wholesale_kg + safety_kg - carry_kg, 1));
    yield_pct := v_yield;
    v_milk := ceil(output_kg / v_yield * 100 / v_round) * v_round;
    if v_milk > 0 and v_milk < v_min then v_milk := v_min; end if;
    capacity_hit := v_milk > v_cap; milk_kg := least(v_milk, v_cap);
    farm_kg := fabula.farm_kg_available(d); farm_gap_kg := farm_kg - milk_kg;
    est_cost_eur := round(milk_kg * v_price, 2);
    select mp.status::text, mp.milk_kg into plan_status, plan_milk_kg from fabula.milk_plans mp where mp.plan_date = d and mp.status in ('proposed','approved') order by mp.created_at desc limit 1;
    if not found then plan_status := null; plan_milk_kg := null; end if;
    return next;
  end loop;
end $function$;

create or replace view fabula.v_demand_7d with (security_invoker = true) as
 SELECT plan_date,
    weekday,
    retail_kg,
    wholesale_kg,
    wholesale_source,
    preorder_kg,
    safety_kg,
    carry_kg,
    output_kg,
    yield_pct,
    milk_kg,
    capacity_hit,
    farm_kg,
    farm_gap_kg,
    est_cost_eur,
    history_days,
    plan_status,
    plan_milk_kg
   FROM fabula.demand_7d() demand_7d(plan_date, weekday, retail_kg, wholesale_kg, wholesale_source, preorder_kg, safety_kg, carry_kg, output_kg, yield_pct, milk_kg, capacity_hit, farm_kg, farm_gap_kg, est_cost_eur, history_days, plan_status, plan_milk_kg);

grant execute on function fabula.demand_7d(date, integer) to authenticated, service_role;
revoke execute on function fabula.demand_7d(date, integer) from public, anon;
grant select on fabula.v_demand_7d to authenticated, service_role;
