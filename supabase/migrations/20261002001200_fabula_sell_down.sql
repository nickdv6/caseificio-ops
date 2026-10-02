-- =============================================================================
-- v0.12: expiry & sell-down — finished lots about to expire become an action,
--        not waste.
--   select fabula.sell_down_signals();          -- today (Europe/Rome)
--   Lots expiring within sell.horizon_days get expected sales allocated oldest-
--   first from the 14-day rate of sales from lots ≥ 2 days old (fresh cheese
--   sells from today's lot, so total sales would overstate it); the rest is "at risk".
--   Action per lot: ritirare (expired) · promo banco (today) · offerta ingrosso +
--   promo (1–2 days, big quantity). At-risk lots ≥ sell.min_kg_for_promo get an
--   approvals row (kind price_change) — Nick approves the discount on the console.
--   v_sell_down_today feeds the tablet "Da vendere prima" card.
-- Written without destructive keywords (connector rule).
-- =============================================================================
set search_path = fabula, public;

insert into fabula.settings (key, value, description) values
  ('sell.horizon_days',     '2',  'Giorni di anticipo con cui segnalare i lotti in scadenza'),
  ('sell.promo_pct',        '30', 'Sconto proposto al banco sui lotti a rischio (%)'),
  ('sell.min_kg_for_promo', '10', 'Sotto questi kg a rischio non si propone nessuna promo'),
  ('sell.wholesale_min_kg', '40', 'Da questi kg a rischio in su si suggerisce anche un''offerta ingrosso')
on conflict (key) do nothing;

create or replace function fabula.sell_down_signals(p_date date default (now() at time zone 'Europe/Rome')::date)
returns jsonb language plpgsql as $$
declare
  horizon int := fabula.setting_num('sell.horizon_days', 2)::int;
  promo numeric := fabula.setting_num('sell.promo_pct', 30);
  min_kg numeric := fabula.setting_num('sell.min_kg_for_promo', 10);
  ws_kg numeric := fabula.setting_num('sell.wholesale_min_kg', 40);
  lot record; rate numeric; cap numeric; alloc numeric; at_risk numeric; action text; lots jsonb := '[]'; cur_prod uuid; prev_cap numeric;
  tot_risk numeric := 0; tot_retail numeric := 0; tot_milk numeric := 0; n_prop int := 0; v_price numeric; v_yield numeric; days_left int;
begin
  select round(avg(yield_pct), 2) into v_yield from fabula.production_batches b join fabula.products p on p.id = b.product_id
   where p.sku = 'MOZ-DOP-KG' and output_kg is not null and batch_date between p_date - 30 and p_date; v_yield := coalesce(v_yield, 30);

  for lot in
    select s.product_id, s.sku, s.name, s.lot_number, s.qty_on_hand, s.expiry_date, p.default_sale_price_eur,
           coalesce(r.rate_old, 0) rate, coalesce(r.rate_all, 0) rate_all
    from fabula.v_stock_on_hand s join fabula.products p on p.id = s.product_id
    -- fresh cheese sells from today's lot; what matters is how much actually sells from lots ≥ 2 days old (14-day average)
    left join lateral (
      with born as (select lot_number, min(moved_at::date) born from fabula.stock_moves where product_id = s.product_id and move_type = 'production_out' group by lot_number)
      select round(coalesce(sum(-sm.qty) filter (where sm.moved_at::date - bn.born >= 2), 0) / 14, 2) rate_old,
             round(coalesce(sum(-sm.qty), 0) / 14, 2) rate_all
      from fabula.stock_moves sm left join born bn on bn.lot_number = sm.lot_number
      where sm.product_id = s.product_id and sm.move_type = 'sale' and sm.moved_at::date between p_date - 14 and p_date - 1) r on true
    where s.kind = 'finished_good' and s.qty_on_hand > 0 and s.expiry_date is not null
    order by s.product_id, s.expiry_date, s.lot_number
  loop
    -- FEFO: expected sales up to this lot's expiry, minus what older lots of the same product already absorb
    if cur_prod is distinct from lot.product_id then cur_prod := lot.product_id; prev_cap := 0; end if;
    days_left := lot.expiry_date - p_date;
    cap := case when days_left < 0 then 0 else lot.rate * (days_left + 1) end;      -- expiry day still sells
    alloc := greatest(0, least(lot.qty_on_hand, cap - prev_cap));
    prev_cap := prev_cap + alloc;
    at_risk := round(lot.qty_on_hand - alloc, 1);
    continue when days_left > horizon;                                               -- outside the window: nothing to say yet
    v_price := coalesce(lot.default_sale_price_eur, 0);
    action := case
      when days_left < 0 then 'ritirare'
      when at_risk <= 0 then 'ok'
      when at_risk >= ws_kg and days_left >= 1 then 'offerta_ingrosso_e_promo'
      when at_risk >= min_kg then 'promo_banco'
      else 'spingere_al_banco' end;
    if action in ('promo_banco', 'offerta_ingrosso_e_promo')
       and not exists (select 1 from fabula.approvals where requested_by = 'agent:sell_down' and payload->>'lot' = lot.lot_number and requested_at::date = p_date) then
      insert into fabula.approvals (kind, requested_by, summary, payload, related_table, amount_eur, expires_at)
      values ('price_change', 'agent:sell_down',
              format('Promo -%s%% su %s lotto %s: %s kg a rischio, scade %s%s', promo, lot.name, lot.lot_number, at_risk, to_char(lot.expiry_date, 'DD/MM'),
                     case when action = 'offerta_ingrosso_e_promo' then ' · proporre anche ai clienti ingrosso' else '' end),
              jsonb_build_object('type', 'sell_down', 'sku', lot.sku, 'lot', lot.lot_number, 'at_risk_kg', at_risk, 'on_hand_kg', lot.qty_on_hand,
                                 'expiry', lot.expiry_date, 'promo_pct', promo, 'list_price_eur_kg', v_price, 'promo_price_eur_kg', round(v_price * (1 - promo / 100), 2),
                                 'action', action),
              'stock_moves', round(at_risk * v_price * promo / 100, 2), ((p_date::timestamp + time '20:00') at time zone 'Europe/Rome'));
      n_prop := n_prop + 1;
    end if;
    lots := lots || jsonb_build_object('sku', lot.sku, 'name', lot.name, 'lot', lot.lot_number, 'on_hand_kg', lot.qty_on_hand, 'expiry', lot.expiry_date,
                                       'days_left', days_left, 'old_lot_sales_rate_kg', lot.rate, 'total_sales_rate_kg', lot.rate_all, 'expected_to_sell_kg', round(alloc, 1), 'at_risk_kg', at_risk,
                                       'value_retail_eur', round(at_risk * v_price, 2),
                                       'value_milk_eur', case when lot.sku = 'MOZ-DOP-KG' then round(at_risk / v_yield * 100 * 1.30, 2) end,
                                       'action', action, 'promo_price_eur_kg', case when action in ('promo_banco','offerta_ingrosso_e_promo') then round(v_price * (1 - promo / 100), 2) end);
    if at_risk > 0 then tot_risk := tot_risk + at_risk; tot_retail := tot_retail + at_risk * v_price;
      if lot.sku = 'MOZ-DOP-KG' then tot_milk := tot_milk + at_risk / v_yield * 100 * 1.30; end if; end if;
  end loop;

  return jsonb_build_object('date', p_date, 'horizon_days', horizon, 'promo_pct', promo,
    'is_simulation', exists (select 1 from fabula.simulation_runs where p_date - 1 between from_date and to_date),
    'lots', lots,
    'totals', jsonb_build_object('at_risk_kg', round(tot_risk, 1), 'value_retail_eur', round(tot_retail, 2), 'value_milk_eur', round(tot_milk, 2),
                                 'expired_lots', (select count(*) from jsonb_array_elements(lots) e where e->>'action' = 'ritirare'),
                                 'proposals_created', n_prop),
    'waste_last_7d_kg', (select coalesce(sum(qty), 0) from fabula.waste_log where wasted_at::date between p_date - 7 and p_date - 1));
end $$;
grant execute on function fabula.sell_down_signals(date) to authenticated, service_role;

-- Tablet card: what to sell first today (and what to pull)
create or replace view fabula.v_sell_down_today as
select s.sku, s.name, s.lot_number, round(s.qty_on_hand, 1) as kg, s.expiry_date,
       s.expiry_date - (now() at time zone 'Europe/Rome')::date as days_left,
       a.status as promo_status, (a.payload->>'promo_pct')::numeric as promo_pct, (a.payload->>'promo_price_eur_kg')::numeric as promo_price_eur_kg
from fabula.v_stock_on_hand s
left join lateral (select status, payload from fabula.approvals where requested_by = 'agent:sell_down' and payload->>'lot' = s.lot_number
                   and requested_at::date = (now() at time zone 'Europe/Rome')::date order by requested_at desc limit 1) a on true
where s.kind = 'finished_good' and s.qty_on_hand > 0 and s.expiry_date <= (now() at time zone 'Europe/Rome')::date + 1
order by s.expiry_date, s.sku;
grant select on fabula.v_sell_down_today to authenticated, service_role;
