-- =============================================================================
-- Fabula v0.25 — Shopify POS is the till
--   * Shopify orders with sourceName = 'pos' land as channel store_pos; the sync
--     writes pos_daily_closings for each POS day (total, receipts) so the brief,
--     weekly P&L and console keep working without anyone typing a Z total.
--   * Task T-Z (chiusura cassa) retired; evening nudge no longer asks for it.
--   * v_shopify_inventory_push: per mapped variant, how many pieces Shopify may
--     sell = in-date kg on hand minus kg reserved by unshipped orders, ÷ kg/piece.
--     Pushed by the "Giacenze Shopify" bot (inventorySetQuantities, available).
-- Written without destructive keywords (connector rule).
-- =============================================================================
set search_path = fabula, public;

insert into fabula.settings (key, value, description, data_type, sort) values
  ('shopify.push_inventory', '1', 'Aggiorna le giacenze su Shopify dal magazzino (1 = sì, 0 = no)', 'number', 52),
  ('shopify.reserve_kg', '0', 'Kg di mozzarella da non offrire online (riserva per il banco)', 'number', 53)
on conflict (key) do update set description = excluded.description, data_type = excluded.data_type, sort = excluded.sort;
alter table fabula.pos_daily_closings add column if not exists source text not null default 'manual';

-- retire the manual Z task
update fabula.task_schedules set active = false where code = 'T-Z';
update fabula.task_instances set status = 'skipped', skip_reason = 'Chiusura cassa su Shopify POS' where status in ('due','overdue') and schedule_id in (select id from fabula.task_schedules where code = 'T-Z');

create or replace function fabula.upsert_shopify_orders(p_rows jsonb)
returns jsonb language plpgsql as $$
declare r jsonb; l jsonb; v_id uuid; v_cust uuid; v_status fabula.order_status; n_new int := 0; n_upd int := 0; n_moves int := 0; n_unm int := 0; n_pos int := 0;
        v_map fabula.shopify_variant_map%rowtype; v_kg numeric; v_prod uuid; v_subtotal numeric; v_tax numeric; v_total numeric; v_date date; fin text; ful text;
        v_qty numeric; v_left numeric; lot record; v_line_kg numeric; v_price_kg numeric; v_iva numeric; first_lot text; v_moz uuid; agg jsonb; k text; v_channel fabula.sales_channel; pos_days date[] := '{}';
begin
  select id into v_moz from fabula.products where sku = 'MOZ-DOP-KG';
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    fin := upper(coalesce(r->>'financial_status', '')); ful := upper(coalesce(r->>'fulfillment_status', ''));
    v_channel := case when lower(coalesce(r->>'source_name', '')) = 'pos' then 'store_pos' else 'shopify' end;
    v_status := case when nullif(r->>'cancelled_at', '') is not null then 'cancelled'
                     when fin in ('REFUNDED') then 'refunded'
                     when ful = 'FULFILLED' then 'fulfilled'
                     when fin in ('PAID','PARTIALLY_REFUNDED','PARTIALLY_PAID') then 'confirmed'
                     else 'draft' end;
    if v_channel = 'store_pos' and v_status = 'confirmed' then v_status := 'fulfilled'; end if;   -- a till sale is handed over on the spot
    v_date := ((r->>'created_at')::timestamptz at time zone 'Europe/Rome')::date;
    if v_channel = 'store_pos' and v_status <> 'cancelled' then pos_days := array_append(pos_days, v_date); end if;
    select id into v_cust from fabula.parties where shopify_customer_id = r->>'customer_id';
    v_subtotal := coalesce((r->>'subtotal')::numeric, 0); v_tax := coalesce((r->>'tax')::numeric, 0); v_total := coalesce((r->>'total')::numeric, 0);
    select id into v_id from fabula.sales_orders where shopify_order_id = r->>'id';
    if v_id is null then
      insert into fabula.sales_orders (order_number, channel, order_date, customer_id, status, subtotal_eur, iva_eur, total_eur, payment_method, shopify_order_id, notes, source, shopify_payload, shopify_updated_at, ship_city)
      values (coalesce(r->>'name', 'SHOP-' || (r->>'id')), v_channel, v_date, v_cust, v_status, v_subtotal, v_tax, v_total, case when v_channel = 'store_pos' then 'shopify_pos' else 'shopify' end, r->>'id',
              nullif(concat_ws(' · ', nullif(r->>'tags', ''), nullif(r->>'email', '')), ''), 'shopify', r, (r->>'updated_at')::timestamptz, r->>'ship_city')
      returning id into v_id; n_new := n_new + 1;
    else
      update fabula.sales_orders set status = v_status, channel = v_channel, customer_id = coalesce(v_cust, customer_id), subtotal_eur = v_subtotal, iva_eur = v_tax, total_eur = v_total,
             shopify_payload = r, shopify_updated_at = (r->>'updated_at')::timestamptz, ship_city = coalesce(r->>'ship_city', ship_city), updated_at = now()
       where id = v_id; n_upd := n_upd + 1;
    end if;
    if not exists (select 1 from fabula.stock_moves where sales_order_id = v_id and move_type = 'sale') then
      agg := '{}'::jsonb;
      for l in select * from jsonb_array_elements(coalesce(r->'line_items', '[]'::jsonb)) loop
        select * into v_map from fabula.shopify_variant_map where variant_id = l->>'variant_id';
        if v_map.variant_id is null then
          v_kg := fabula.shopify_title_kg(coalesce(l->>'variant_title', ''));
          if v_kg is not null and (coalesce(l->>'product_type', '') ilike '%mozzarella%' or coalesce(l->>'title', '') ilike '%bufala%') then
            insert into fabula.shopify_variant_map (variant_id, product_id, kg_per_unit, label, product_type, auto_mapped)
            values (l->>'variant_id', v_moz, v_kg, (l->>'title') || ' · ' || coalesce(l->>'variant_title', ''), l->>'product_type', true)
            on conflict (variant_id) do nothing;
            select * into v_map from fabula.shopify_variant_map where variant_id = l->>'variant_id';
          else
            insert into fabula.shopify_variant_map (variant_id, product_id, kg_per_unit, label, product_type, auto_mapped)
            values (l->>'variant_id', null, null, (l->>'title') || ' · ' || coalesce(l->>'variant_title', ''), l->>'product_type', false)
            on conflict (variant_id) do nothing;
          end if;
        end if;
        if v_map.product_id is null or v_map.kg_per_unit is null then
          insert into fabula.shopify_unmapped_lines (sales_order_id, variant_id, title, variant_title, qty, unit_price_eur)
          values (v_id, l->>'variant_id', l->>'title', l->>'variant_title', (l->>'quantity')::numeric, (l->>'price')::numeric)
          on conflict (sales_order_id, variant_id, title) do update set qty = excluded.qty, seen_at = now();
          n_unm := n_unm + 1; continue;
        end if;
        v_line_kg := (l->>'quantity')::numeric * v_map.kg_per_unit;
        agg := jsonb_set(agg, array[v_map.product_id::text], jsonb_build_object(
          'kg',  coalesce((agg->v_map.product_id::text->>'kg')::numeric, 0) + v_line_kg,
          'eur', coalesce((agg->v_map.product_id::text->>'eur')::numeric, 0) + (l->>'quantity')::numeric * (l->>'price')::numeric,
          'iva', coalesce((l->>'tax_rate')::numeric, 4)));
      end loop;
      for k in select * from jsonb_object_keys(agg) loop
        v_line_kg := (agg->k->>'kg')::numeric; v_price_kg := case when v_line_kg > 0 then round((agg->k->>'eur')::numeric / v_line_kg, 4) else 0 end; v_iva := (agg->k->>'iva')::numeric;
        if v_line_kg <= 0 then continue; end if;
        update fabula.sales_order_lines set qty = v_line_kg, unit_price_eur = v_price_kg, iva_rate = v_iva where sales_order_id = v_id and product_id = k::uuid;
        if not found then
          insert into fabula.sales_order_lines (sales_order_id, product_id, qty, unit_price_eur, iva_rate) values (v_id, k::uuid, v_line_kg, v_price_kg, v_iva);
        end if;
      end loop;
    end if;
    if v_status = 'fulfilled' and not exists (select 1 from fabula.stock_moves where sales_order_id = v_id and move_type = 'sale') then
      for v_prod, v_qty in select product_id, sum(qty) from fabula.sales_order_lines where sales_order_id = v_id and qty > 0 group by product_id loop
        v_left := v_qty; first_lot := null;
        for lot in select lot_number, expiry_date, qty_on_hand from fabula.v_stock_on_hand where product_id = v_prod and qty_on_hand > 0
                   order by (expiry_date is not null and expiry_date < current_date), expiry_date nulls last, lot_number loop
          exit when v_left <= 0;
          insert into fabula.stock_moves (product_id, lot_number, expiry_date, qty, move_type, sales_order_id, reason, source)
          values (v_prod, lot.lot_number, lot.expiry_date, -least(v_left, lot.qty_on_hand), 'sale', v_id, (case when v_channel = 'store_pos' then 'POS ' else 'Shopify ' end) || coalesce(r->>'name', ''), 'shopify');
          first_lot := coalesce(first_lot, lot.lot_number); v_left := v_left - least(v_left, lot.qty_on_hand); n_moves := n_moves + 1;
        end loop;
        if v_left > 0 then
          insert into fabula.stock_moves (product_id, lot_number, qty, move_type, sales_order_id, reason, source)
          values (v_prod, null, -v_left, 'sale', v_id, (case when v_channel = 'store_pos' then 'POS ' else 'Shopify ' end) || coalesce(r->>'name', '') || ' · giacenza insufficiente', 'shopify'); n_moves := n_moves + 1;
        end if;
        update fabula.sales_order_lines set lot_number = first_lot where sales_order_id = v_id and product_id = v_prod and lot_number is null;
      end loop;
    end if;
  end loop;
  -- daily till close from POS orders (replaces the typed Z total)
  for v_date in select distinct d from unnest(pos_days) d loop
    insert into fabula.pos_daily_closings (closing_date, rt_total_eur, rt_receipts, recorded_total_eur, notes, source)   -- variance_eur is generated
    select v_date, coalesce(sum(total_eur), 0), count(*), coalesce(sum(total_eur), 0), 'Shopify POS', 'shopify_pos'
      from fabula.sales_orders where channel = 'store_pos' and order_date = v_date and status <> 'cancelled' and source = 'shopify'
    on conflict (closing_date) do update set rt_total_eur = excluded.rt_total_eur, rt_receipts = excluded.rt_receipts, recorded_total_eur = excluded.recorded_total_eur, source = 'shopify_pos'
      where fabula.pos_daily_closings.source in ('shopify_pos', 'manual') and fabula.pos_daily_closings.closed_by_id is null;
    n_pos := n_pos + 1;
  end loop;
  return jsonb_build_object('received', jsonb_array_length(coalesce(p_rows, '[]'::jsonb)), 'created', n_new, 'updated', n_upd, 'stock_moves', n_moves, 'unmapped_lines', n_unm, 'pos_days_closed', n_pos,
    'unmapped_variants', (select coalesce(jsonb_agg(jsonb_build_object('variant_id', variant_id, 'label', label, 'type', product_type) order by label), '[]') from fabula.shopify_variant_map where product_id is null or kg_per_unit is null),
    'last_order', (select max(order_date) from fabula.sales_orders where channel in ('shopify','store_pos')));
end $$;

-- what Shopify may sell, per variant
create or replace view fabula.v_shopify_inventory_push as
  with avail as (
    select p.id as product_id,
           greatest(0, coalesce((select sum(qty_on_hand) from fabula.v_stock_on_hand s where s.product_id = p.id and (s.expiry_date is null or s.expiry_date >= (now() at time zone 'Europe/Rome')::date)), 0)
                     - coalesce((select sum(l.qty) from fabula.sales_order_lines l join fabula.sales_orders o on o.id = l.sales_order_id where l.product_id = p.id and o.status = 'confirmed' and o.channel in ('shopify','wholesale')
                                   and not exists (select 1 from fabula.stock_moves m where m.sales_order_id = o.id and m.move_type = 'sale')), 0)
                     - case when p.sku = 'MOZ-DOP-KG' then fabula.setting_num('shopify.reserve_kg', 0) else 0 end) as available_kg
    from fabula.products p where p.kind = 'finished_good')
  select m.variant_id, m.label, p.sku, a.available_kg, m.kg_per_unit, floor(a.available_kg / m.kg_per_unit)::int as available_units
  from fabula.shopify_variant_map m join fabula.products p on p.id = m.product_id join avail a on a.product_id = p.id
  where m.kg_per_unit > 0
  order by m.label;
grant select on fabula.v_shopify_inventory_push to authenticated, service_role;

create or replace function fabula.expected_bots(p_date date)
returns table(agent text) language sql immutable as $$
  select a from unnest(array['daily_brief','procurement','wholesale_orders','milk_planning','sell_down','haccp_nudge','shopify_customers','shopify_orders','shopify_inventory']) a where extract(isodow from p_date) between 1 and 6
  union all select 'weekly_brief' where extract(isodow from p_date) = 1
  union all select 'compliance_calendar' where extract(isodow from p_date) = 2
  union all select 'monthly_review' where extract(day from p_date) = 1
$$;

-- evening nudge without the Z line (till closes in Shopify POS)
create or replace function fabula.haccp_evening_status(p_date date default (now() at time zone 'Europe/Rome')::date)
returns jsonb language plpgsql as $$
declare items jsonb := '[]'; v_key text := 'haccp_evening:' || p_date; n int; n_ship int;
begin
  select coalesce(jsonb_agg(jsonb_build_object('code', 'cold:' || cp.code, 'label_it', 'Temperatura serale ' || coalesce(e.code, cp.name), 'scan', 'EQ:' || e.code) order by cp.code), '[]') into items
  from fabula.haccp_control_points cp left join fabula.equipment e on e.id = cp.equipment_id
  where cp.active and cp.frequency = 'twice_daily'
    and not exists (select 1 from fabula.haccp_log l where l.control_point_id = cp.id and l.logged_at::date = p_date and (l.logged_at at time zone 'Europe/Rome')::time >= time '15:00');
  if not exists (select 1 from fabula.haccp_log l join fabula.haccp_control_points cp on cp.id = l.control_point_id where cp.code = 'PRP-CLEAN' and l.logged_at::date = p_date) then
    items := items || jsonb_build_object('code', 'clean', 'label_it', 'Sanificazione fine turno', 'scan', 'CLEAN:');
  end if;
  if exists (select 1 from fabula.production_batches where batch_date = p_date) or exists (select 1 from fabula.sales_orders where order_date = p_date) then
    if not exists (select 1 from fabula.meter_readings where meter = 'elec_main' and read_at::date = p_date) then
      items := items || jsonb_build_object('code', 'kwh', 'label_it', 'Lettura contatore', 'scan', 'METER:elec_main'); end if;
  end if;
  if exists (select 1 from fabula.production_batches where batch_date = p_date and source <> 'simulation')
     and not exists (select 1 from fabula.effluent_log where log_date = p_date) then
    items := items || jsonb_build_object('code', 'effluent', 'label_it', 'Reflui del giorno (scotta, acque di lavaggio)', 'scan', 'EFFL:');
  end if;
  select count(*) into n_ship from fabula.v_orders_to_ship where channel = 'shopify';
  if n_ship > 0 then
    items := items || jsonb_build_object('code', 'ship', 'label_it', n_ship || ' ordini online pagati da spedire', 'scan', 'SHIP:');
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
