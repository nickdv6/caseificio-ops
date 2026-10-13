-- v0.98c · Audit 12/10/2026, numbers and limits: wholesale (B2B portal and Console → Ingrosso).
--   TRADE-01  A quantity must be a multiple of the product's step (a whole number of Shopify units: 2,5 kg used to be invoiced as
--             3 on Shopify). A delivery that goes up past trade.max_kg_per_delivery is refused for customers («chiama il
--             caseificio»; the dairy's staff are not held to it); one over 3 times the customer's usual for that day (and over
--             trade.confirm_kg_per_delivery) needs a confirmation: the error ends with «Confermi?» (code P0001, relayed by the
--             trade-portal function) and the page sends the same save with confirm = true. Only pages that can answer ask
--             (payload can_confirm: the portal and Console → Ingrosso from v0.98), so an older portal page is never stuck on it.
--   D-23      Reserved prices: above zero and not above the base price («11,50» typed as 1150); minimum and step are whole units
--             (Shopify sells whole pieces); kg per piece 0–25. Tiers: a price above zero and not above the product's reserved
--             price, discounts up to 50 %. trade_price() never returns a price above the list or below zero (D-13).

-- ============================================================================================================================
-- 1. Helpers
-- ============================================================================================================================
-- one line: in the list, at least the minimum, a multiple of the step; returns its kg
create or replace function fabula.trade_qty_check(p_variant text, p_qty numeric) returns numeric
language plpgsql stable set search_path = fabula, public as $$
declare tp fabula.trade_products%rowtype; v_name text;
begin
  select * into tp from fabula.trade_products where variant_id = p_variant and active and trade_price_eur is not null;
  if tp.variant_id is null then raise exception 'Prodotto non in listino: %', p_variant using errcode = '22023'; end if;
  v_name := tp.title || coalesce(' ' || nullif(tp.variant_title, ''), '');
  if p_qty < tp.min_qty then
    raise exception 'Quantità sotto il minimo per %: almeno % %', v_name, fabula._it_num(tp.min_qty), tp.unit_label using errcode = '22023';
  end if;
  if tp.step_qty > 0 and mod(p_qty, tp.step_qty) <> 0 then
    raise exception 'La quantità di % va a multipli di % % (hai scritto %)', v_name, fabula._it_num(tp.step_qty), tp.unit_label, fabula._it_num(p_qty) using errcode = '22023';
  end if;
  return p_qty * tp.kg_per_unit;
end $$;
revoke all on function fabula.trade_qty_check(text, numeric) from public, anon;
grant execute on function fabula.trade_qty_check(text, numeric) to authenticated, service_role;

-- what the current plan delivers on a weekday (kg; 0 = nothing that day)
create or replace function fabula.trade_plan_day_kg(p_customer uuid, p_weekday int) returns numeric
language sql stable set search_path = fabula, public as $$
  select coalesce(sum(l.qty * tp.kg_per_unit), 0)
    from fabula.trade_schedule_lines l
    join fabula.trade_products tp on tp.variant_id = l.variant_id
    join fabula.trade_schedule_days sd on sd.customer_id = l.customer_id and sd.weekday = l.weekday and sd.active
   where l.customer_id = p_customer and l.weekday = p_weekday and l.qty > 0 $$;
revoke all on function fabula.trade_plan_day_kg(uuid, int) from public, anon;
grant execute on function fabula.trade_plan_day_kg(uuid, int) to authenticated, service_role;

-- the customer's usual kg for a weekday: what the current plan has that day, else the plan's average delivery (null = no plan yet)
create or replace function fabula.trade_usual_kg(p_customer uuid, p_weekday int) returns numeric
language sql stable set search_path = fabula, public as $$
  with d as (
    select l.weekday, sum(l.qty * tp.kg_per_unit) kg
      from fabula.trade_schedule_lines l
      join fabula.trade_products tp on tp.variant_id = l.variant_id
      join fabula.trade_schedule_days sd on sd.customer_id = l.customer_id and sd.weekday = l.weekday and sd.active
     where l.customer_id = p_customer and l.qty > 0
     group by l.weekday)
  select coalesce((select kg from d where weekday = p_weekday), (select avg(kg) from d)) $$;
revoke all on function fabula.trade_usual_kg(uuid, int) from public, anon;
grant execute on function fabula.trade_usual_kg(uuid, int) to authenticated, service_role;

-- one delivery that goes up: refused over the maximum (p_max: customers, not the dairy's staff); over 3 times the usual (and over
-- the confirm threshold) it needs confirm = true. p_label names the delivery in the message («Sabato», «Consegna del 14/02»).
create or replace function fabula.trade_day_kg_check(p_label text, p_kg numeric, p_usual numeric, p_confirm boolean, p_max boolean default true) returns void
language plpgsql stable set search_path = fabula, public as $$
declare v_max numeric := fabula.setting_num('trade.max_kg_per_delivery', 150); v_conf numeric := fabula.setting_num('trade.confirm_kg_per_delivery', 25);
begin
  if p_kg is null or p_kg <= 0 then return; end if;
  if coalesce(p_max, true) and p_kg > v_max then
    raise exception '%: % kg. Dal portale si arriva a % kg per consegna: per quantità più grandi chiama il caseificio.',
      p_label, fabula._it_num(round(p_kg, 2)), fabula._it_num(v_max) using errcode = '22023';
  end if;
  if coalesce(p_confirm, false) or p_kg <= greatest(v_conf, coalesce(p_usual, 0) * 3) then return; end if;
  if p_usual > 0 then
    raise exception '%: % kg, più di 3 volte il solito (% kg). Confermi?', p_label, fabula._it_num(round(p_kg, 2)), fabula._it_num(round(p_usual, 2))
      using errcode = 'P0001', hint = 'confirm';
  end if;
  raise exception '%: % kg, è tanto per una consegna. Confermi?', p_label, fabula._it_num(round(p_kg, 2)) using errcode = 'P0001', hint = 'confirm';
end $$;
revoke all on function fabula.trade_day_kg_check(text, numeric, numeric, boolean, boolean) from public, anon;
grant execute on function fabula.trade_day_kg_check(text, numeric, numeric, boolean, boolean) to authenticated, service_role;

-- ============================================================================================================================
-- 2. The weekly plan: every line and every day checked before anything is written
-- ============================================================================================================================
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.trade_save_schedule(uuid,jsonb,text)'::regprocedure);
  n := replace(d, $s$  existed := exists (select 1 from fabula.trade_schedules where customer_id = p_customer);
$s$, $s$  existed := exists (select 1 from fabula.trade_schedules where customer_id = p_customer);
  -- v0.98 (audit TRADE-01): every line a multiple of its step; a day that goes up compared with the plan as it is now is checked
  -- against the maximum (customers only) and the usual («Confermi?» only to a page that can answer it: can_confirm)
  for d, kgd in select dk, (select coalesce(sum(fabula.trade_qty_check(k, (p_payload->'days'->dk->'lines'->>k)::numeric)), 0)
                              from jsonb_object_keys(coalesce(p_payload->'days'->dk->'lines', '{}'::jsonb)) k
                             where coalesce((p_payload->'days'->dk->'lines'->>k)::numeric, 0) > 0)
                  from jsonb_object_keys(coalesce(p_payload->'days', '{}'::jsonb)) dk where dk ~ '^[1-7]$' loop
    if kgd > fabula.trade_plan_day_kg(p_customer, d::int) then
      perform fabula.trade_day_kg_check(initcap(fabula.trade_wd_it(d::int)), kgd, fabula.trade_usual_kg(p_customer, d::int),
                                        coalesce((p_payload->>'confirm')::boolean, false) or not coalesce((p_payload->>'can_confirm')::boolean, false),
                                        p_actor = 'customer');
    end if;
  end loop;
$s$);
  if n = d then raise exception 'v098c: trade_save_schedule pattern not found'; end if;
  execute n;
end $mig$;

-- ============================================================================================================================
-- 3. A one-day change (override): the same checks on the delivery as it would become
-- ============================================================================================================================
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.trade_add_exception(uuid,jsonb,text,boolean)'::regprocedure);
  n := replace(d, $s$    if (p_payload->>'qty')::numeric > 0 and (p_payload->>'qty')::numeric < tp.min_qty then raise exception 'Quantità sotto il minimo (%)', trim_scale(tp.min_qty) using errcode = '22023'; end if;
$s$, $s$    if (p_payload->>'qty')::numeric > 0 and (p_payload->>'qty')::numeric < tp.min_qty then raise exception 'Quantità sotto il minimo (%)', trim_scale(tp.min_qty) using errcode = '22023'; end if;
    -- v0.98 (audit TRADE-01): a multiple of the step, and the day's delivery as it would become within the limits
    if coalesce((p_payload->>'qty')::numeric, 0) < 0 then raise exception 'Quantità non valida' using errcode = '22023'; end if;
    if (p_payload->>'qty')::numeric > 0 then perform fabula.trade_qty_check(tp.variant_id, (p_payload->>'qty')::numeric); end if;
    for dd in select g::date from generate_series(d1, least(d2, d1 + 62), interval '1 day') g loop
      continue when not fabula.trade_is_delivery_day(dd);
      select coalesce(sum(e.kg), 0) into v_kg from fabula.trade_effective_lines(dd) e where e.customer_id = p_customer and e.variant_id <> tp.variant_id;
      v_kg := v_kg + coalesce((p_payload->>'qty')::numeric, 0) * tp.kg_per_unit;
      continue when v_kg <= (select coalesce(sum(e.kg), 0) from fabula.trade_effective_lines(dd) e where e.customer_id = p_customer);   -- only a delivery that goes up
      perform fabula.trade_day_kg_check('Consegna del ' || to_char(dd, 'DD/MM'), v_kg, fabula.trade_usual_kg(p_customer, extract(isodow from dd)::int),
                                        coalesce((p_payload->>'confirm')::boolean, false) or not coalesce((p_payload->>'can_confirm')::boolean, false),
                                        p_actor = 'customer');
    end loop;
$s$);
  if n = d then raise exception 'v098c: trade_add_exception pattern not found'; end if;
  execute n;
end $mig$;

-- ============================================================================================================================
-- 4. D-23 · reserved prices, minimum and step; tiers
-- ============================================================================================================================
create or replace function fabula.trg_trade_product_guard() returns trigger language plpgsql set search_path = fabula, public as $$
declare v_name text := new.title || coalesce(' ' || nullif(new.variant_title, ''), '');
begin
  -- the price only when it is the one changing: the nightly Shopify sync updates the base price and must not be stopped by it
  if new.trade_price_eur is not null and (tg_op = 'INSERT' or new.trade_price_eur is distinct from old.trade_price_eur) then
    if new.trade_price_eur <= 0 then raise exception 'Prezzo riservato di %: scrivi un prezzo maggiore di zero', v_name using errcode = '23514'; end if;
    if new.base_price_eur is not null and new.trade_price_eur > new.base_price_eur then
      raise exception 'Prezzo riservato di % a % €: è più alto del prezzo base (% €). Controlla la virgola (11,50 non 1150).',
        v_name, fabula._it_num(new.trade_price_eur), fabula._it_num(new.base_price_eur) using errcode = '23514';
    end if;
  end if;
  if tg_op = 'INSERT' or new.min_qty is distinct from old.min_qty or new.step_qty is distinct from old.step_qty then
    if new.min_qty <= 0 or new.step_qty <= 0 or new.min_qty <> trunc(new.min_qty) or new.step_qty <> trunc(new.step_qty) then
      raise exception 'Minimo e passo di % vanno in unità intere maggiori di zero: Shopify vende pezzi interi da % kg', v_name, fabula._it_num(new.kg_per_unit) using errcode = '23514';
    end if;
  end if;
  if new.kg_per_unit <= 0 or new.kg_per_unit > 25 then
    raise exception 'kg per pezzo di % impossibili: % (tra 0 e 25; 250 g = 0,25)', v_name, fabula._it_num(new.kg_per_unit) using errcode = '23514';
  end if;
  return new;
end $$;
revoke all on function fabula.trg_trade_product_guard() from public, anon, authenticated;
drop trigger if exists trade_products_guard on fabula.trade_products;
create trigger trade_products_guard before insert or update on fabula.trade_products for each row execute function fabula.trg_trade_product_guard();

create or replace function fabula.trg_trade_tier_guard() returns trigger language plpgsql set search_path = fabula, public as $$
declare v_list numeric;
begin
  if new.price_eur is not null then
    if new.price_eur <= 0 then raise exception 'Prezzo dello scaglione: scrivi un prezzo maggiore di zero' using errcode = '23514'; end if;
    select max(trade_price_eur) into v_list from fabula.trade_products where active and (variant_id = new.variant_id or new.variant_id is null);
    if v_list is not null and new.price_eur > v_list then
      raise exception 'Prezzo dello scaglione % €: è più alto del prezzo riservato (% €), non sarebbe uno sconto. Controlla la virgola.',
        fabula._it_num(new.price_eur), fabula._it_num(v_list) using errcode = '23514';
    end if;
  end if;
  if new.discount_pct is not null and new.discount_pct > 50 then
    raise exception 'Sconto dello scaglione % %%: al massimo il 50 %%. Controlla.', fabula._it_num(new.discount_pct) using errcode = '23514';
  end if;
  return new;
end $$;
revoke all on function fabula.trg_trade_tier_guard() from public, anon, authenticated;
drop trigger if exists trade_price_tiers_guard on fabula.trade_price_tiers;
create trigger trade_price_tiers_guard before insert or update of price_eur, discount_pct, variant_id on fabula.trade_price_tiers
  for each row execute function fabula.trg_trade_tier_guard();

-- trade_price: a tier never costs more than the list, and the final price stays between 0 and the list
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.trade_price(uuid,text,numeric,boolean)'::regprocedure);
  n := replace(d, $s$    v_tier := case when t.price_eur is not null then t.price_eur else round(v_list * (1 - t.discount_pct / 100), 2) end;$s$,
                  $s$    v_tier := least(v_list, case when t.price_eur is not null then t.price_eur else round(v_list * (1 - t.discount_pct / 100), 2) end);   -- v0.98 (D-23)$s$);
  n := replace(n, $s$  else v_final := least(v_tier, round(v_list * (1 - v_rec / 100), 2)); end if;$s$,
                  $s$  else v_final := least(v_tier, round(v_list * (1 - v_rec / 100), 2)); end if;
  v_final := greatest(0, least(v_final, v_list));                             -- v0.98 (D-13/D-23): never above the list, never below zero$s$);
  if position('least(v_list, case when t.price_eur' in n) = 0 or position('greatest(0, least(v_final, v_list))' in n) = 0 then
    raise exception 'v098c: trade_price patterns not found';
  end if;
  execute n;
end $mig$;
