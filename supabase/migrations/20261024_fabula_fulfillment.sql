-- =============================================================================
-- Fabula v0.24 — order fulfilment with minimal typing
--   Tablet "🚚 Da spedire": one list of paid Shopify orders + confirmed wholesale
--   orders; per line the FEFO lot is suggested, the operator scans the lot label
--   (or accepts the suggestion), weighs on a connected scale, confirms. pack_order()
--   books stock from the real lots with the real weights, writes the shipment and
--   lines, closes wholesale orders; Shopify orders are fulfilled in Shopify by the
--   Ordini Shopify bot (v_shipments_to_fulfill → fulfillmentCreate → mark_shopify_fulfilled).
--   spedizione.html prints the DDT / packing list with lot numbers.
-- Written without destructive keywords (connector rule).
-- =============================================================================
set search_path = fabula, public;

alter table fabula.shipments add column if not exists carrier text;
alter table fabula.shipments add column if not exists tracking_number text;
alter table fabula.shipments add column if not exists gross_weight_kg numeric(10,3);
alter table fabula.shipments add column if not exists packed_by_id uuid references fabula.staff(id);
alter table fabula.shipments add column if not exists packed_at timestamptz;
alter table fabula.shipments add column if not exists shopify_fulfillment_id text;
alter table fabula.shipments add column if not exists shopify_fulfilled_at timestamptz;
alter table fabula.shipments add column if not exists weight_variance_pct numeric(6,2);
alter table fabula.shipment_lines add column if not exists ordered_qty numeric(12,3);
alter table fabula.shipment_lines add column if not exists weighed boolean not null default false;

insert into fabula.settings (key, value, description, data_type, sort) values
  ('ship.tolerance_pct', '5', 'Scostamento ammesso tra kg ordinati e kg pesati prima di chiedere una seconda conferma (%)', 'number', 70),
  ('ship.default_carrier', 'BRT', 'Vettore predefinito per le spedizioni online', 'text', 71),
  ('ship.wholesale_carrier', 'Consegna diretta', 'Vettore predefinito per le consegne ingrosso', 'text', 72),
  ('scale.ble_service', 'weight_scale', 'Servizio Bluetooth della bilancia (weight_scale = standard GATT 0x181D)', 'text', 75)
on conflict (key) do update set description = excluded.description, data_type = excluded.data_type, sort = excluded.sort;

-- orders waiting to be packed, with FEFO lot suggestions per line
create or replace view fabula.v_orders_to_ship as
  select o.id as order_id, o.order_number, o.channel::text as channel, o.order_date, o.status::text as status, o.total_eur, o.ship_city,
         p.legal_name as customer, p.phone, o.shopify_order_id, o.shopify_payload->'shipping_address' as ship_address,
         (select coalesce(jsonb_agg(jsonb_build_object(
              'product_id', l.product_id, 'sku', pr.sku, 'name', pr.name, 'unit', pr.unit, 'qty', l.qty,
              'suggested', (select coalesce(jsonb_agg(jsonb_build_object('lot', s.lot_number, 'expiry', s.expiry_date, 'on_hand', round(s.qty_on_hand, 2)) order by (s.expiry_date is not null and s.expiry_date < current_date), s.expiry_date nulls last, s.lot_number), '[]')
                            from (select * from fabula.v_stock_on_hand s where s.product_id = l.product_id and s.qty_on_hand > 0 order by (s.expiry_date is not null and s.expiry_date < current_date), s.expiry_date nulls last, s.lot_number limit 3) s)
            ) order by pr.name), '[]')
          from fabula.sales_order_lines l join fabula.products pr on pr.id = l.product_id where l.sales_order_id = o.id and l.qty > 0) as lines,
         (select count(*) from fabula.shopify_unmapped_lines u where u.sales_order_id = o.id) as unmapped,
         o.order_date as due_date
  from fabula.sales_orders o left join fabula.parties p on p.id = o.customer_id
  where o.status = 'confirmed' and o.channel in ('shopify', 'wholesale')
    and not exists (select 1 from fabula.shipments sh where sh.sales_order_id = o.id and sh.status in ('picked','in_transit','delivered'))
    and (o.channel = 'shopify' or o.order_date <= (now() at time zone 'Europe/Rome')::date + 1)
  order by o.channel desc, o.order_date, o.order_number;
grant select on fabula.v_orders_to_ship to authenticated, service_role;

-- pack: lines = [{product_id, lot_number, qty}] (qty in product unit, kg). Returns shipment summary; raises on bad lot.
create or replace function fabula.pack_order(p_order_id uuid, p_lines jsonb, p_staff_id uuid, p_gross_kg numeric default null, p_carrier text default null, p_tracking text default null, p_notes text default null, p_force boolean default false)
returns jsonb language plpgsql as $$
declare o fabula.sales_orders%rowtype; l jsonb; v_ship uuid; v_ddt text; v_on_hand numeric; v_ordered numeric; v_packed numeric := 0; v_tol numeric; v_var numeric; v_carrier text; n int := 0; v_exp date; v_order_total_kg numeric;
begin
  select * into o from fabula.sales_orders where id = p_order_id;
  if o.id is null then raise exception 'Ordine non trovato'; end if;
  if o.status <> 'confirmed' then raise exception 'Ordine % non in stato confermato (%)', o.order_number, o.status; end if;
  if exists (select 1 from fabula.shipments where sales_order_id = p_order_id and status in ('picked','in_transit','delivered')) then raise exception 'Ordine % già preparato', o.order_number; end if;
  if jsonb_array_length(coalesce(p_lines, '[]'::jsonb)) = 0 then raise exception 'Nessuna riga'; end if;
  -- validate lots and weights
  select coalesce(sum(qty), 0) into v_order_total_kg from fabula.sales_order_lines where sales_order_id = p_order_id and qty > 0;
  for l in select * from jsonb_array_elements(p_lines) loop
    if coalesce((l->>'qty')::numeric, 0) <= 0 then raise exception 'Quantità non valida per il lotto %', l->>'lot_number'; end if;
    select qty_on_hand, expiry_date into v_on_hand, v_exp from fabula.v_stock_on_hand where product_id = (l->>'product_id')::uuid and lot_number = l->>'lot_number';
    if v_on_hand is null then raise exception 'Lotto % non in giacenza per questo prodotto', l->>'lot_number'; end if;
    if v_on_hand + 0.0005 < (l->>'qty')::numeric and not p_force then raise exception 'Lotto %: in giacenza % kg, richiesti %', l->>'lot_number', round(v_on_hand, 2), l->>'qty'; end if;
    v_packed := v_packed + (l->>'qty')::numeric;
  end loop;
  v_tol := fabula.setting_num('ship.tolerance_pct', 5);
  v_var := case when v_order_total_kg > 0 then round((v_packed - v_order_total_kg) / v_order_total_kg * 100, 2) else 0 end;
  if abs(v_var) > v_tol and not p_force then
    return jsonb_build_object('ok', false, 'needs_confirm', true, 'ordered_kg', v_order_total_kg, 'packed_kg', v_packed, 'variance_pct', v_var, 'tolerance_pct', v_tol);
  end if;
  v_carrier := coalesce(nullif(p_carrier, ''), case when o.channel = 'wholesale' then fabula.setting_text('ship.wholesale_carrier', 'Consegna diretta') else fabula.setting_text('ship.default_carrier', 'BRT') end);
  v_ddt := 'DDT-' || to_char((now() at time zone 'Europe/Rome')::date, 'YYYYMMDD') || '-' || lpad(((select count(*) from fabula.shipments where ship_date = (now() at time zone 'Europe/Rome')::date) + 1)::text, 2, '0');
  insert into fabula.shipments (ddt_number, customer_id, sales_order_id, status, ship_date, driver_id, notes, carrier, tracking_number, gross_weight_kg, packed_by_id, packed_at, weight_variance_pct)
  values (v_ddt, o.customer_id, o.id, 'picked', (now() at time zone 'Europe/Rome')::date, p_staff_id, p_notes, v_carrier, nullif(p_tracking, ''), p_gross_kg, p_staff_id, now(), v_var)
  returning id into v_ship;
  for l in select * from jsonb_array_elements(p_lines) loop
    select sum(qty) into v_ordered from fabula.sales_order_lines where sales_order_id = p_order_id and product_id = (l->>'product_id')::uuid;
    select expiry_date into v_exp from fabula.v_stock_on_hand where product_id = (l->>'product_id')::uuid and lot_number = l->>'lot_number';
    insert into fabula.shipment_lines (shipment_id, product_id, lot_number, qty, ordered_qty, weighed) values (v_ship, (l->>'product_id')::uuid, l->>'lot_number', (l->>'qty')::numeric, v_ordered, coalesce((l->>'weighed')::boolean, false));
    insert into fabula.stock_moves (product_id, lot_number, expiry_date, qty, move_type, sales_order_id, reason, source)
    values ((l->>'product_id')::uuid, l->>'lot_number', v_exp, -(l->>'qty')::numeric, 'sale', o.id, 'Spedizione ' || v_ddt || ' · ' || o.order_number, 'tablet');
    update fabula.sales_order_lines set lot_number = coalesce(lot_number, l->>'lot_number') where sales_order_id = o.id and product_id = (l->>'product_id')::uuid;
    n := n + 1;
  end loop;
  -- wholesale closes here; Shopify closes when the bot fulfils it in Shopify
  if o.channel = 'wholesale' then update fabula.sales_orders set status = 'fulfilled', updated_at = now() where id = o.id; end if;
  return jsonb_build_object('ok', true, 'shipment_id', v_ship, 'ddt_number', v_ddt, 'order_number', o.order_number, 'channel', o.channel, 'lines', n, 'packed_kg', v_packed, 'ordered_kg', v_order_total_kg, 'variance_pct', v_var, 'carrier', v_carrier,
                            'needs_shopify_fulfilment', o.channel = 'shopify');
end $$;
grant execute on function fabula.pack_order(uuid, jsonb, uuid, numeric, text, text, text, boolean) to authenticated, service_role;

-- Shopify side: picked shipments of Shopify orders not yet fulfilled in Shopify
create or replace view fabula.v_shipments_to_fulfill as
  select sh.id as shipment_id, o.shopify_order_id, o.order_number, sh.carrier, sh.tracking_number, sh.packed_at, sh.gross_weight_kg
  from fabula.shipments sh join fabula.sales_orders o on o.id = sh.sales_order_id
  where o.channel = 'shopify' and sh.status = 'picked' and sh.shopify_fulfilled_at is null and o.shopify_order_id is not null
  order by sh.packed_at;
grant select on fabula.v_shipments_to_fulfill to authenticated, service_role;
create or replace function fabula.mark_shopify_fulfilled(p_shipment_id uuid, p_fulfillment_gid text default null)
returns text language plpgsql as $$
declare v_order uuid;
begin
  update fabula.shipments set shopify_fulfillment_id = p_fulfillment_gid, shopify_fulfilled_at = now(), status = 'in_transit', updated_at = now() where id = p_shipment_id returning sales_order_id into v_order;
  if v_order is null then raise exception 'Spedizione non trovata'; end if;
  update fabula.sales_orders set status = 'fulfilled', updated_at = now() where id = v_order;
  return 'fulfilled';
end $$;
grant execute on function fabula.mark_shopify_fulfilled(uuid, text) to authenticated, service_role;

-- printable DDT / packing list
create or replace view fabula.v_shipment_doc as
  select sh.id as shipment_id, sh.ddt_number, sh.ship_date, sh.status::text as status, sh.carrier, sh.tracking_number, sh.gross_weight_kg, sh.notes, sh.packed_at,
         o.order_number, o.channel::text as channel, o.order_date, o.total_eur, o.ship_city, o.shopify_payload->'shipping_address' as ship_address, o.shopify_payload->>'email' as order_email,
         p.legal_name as customer, p.address as customer_address, p.city as customer_city, p.province as customer_province, p.postcode as customer_postcode, p.piva as customer_piva, p.phone as customer_phone, p.email as customer_email,
         st.full_name as packed_by,
         (select coalesce(jsonb_agg(jsonb_build_object('name', pr.name, 'sku', pr.sku, 'unit', pr.unit, 'lot', sl.lot_number, 'qty', sl.qty, 'ordered', sl.ordered_qty, 'expiry', s.expiry_date, 'weighed', sl.weighed) order by pr.name, sl.lot_number), '[]')
          from fabula.shipment_lines sl join fabula.products pr on pr.id = sl.product_id
          left join lateral (select max(expiry_date) expiry_date from fabula.stock_moves m where m.product_id = sl.product_id and m.lot_number = sl.lot_number) s on true
          where sl.shipment_id = sh.id) as lines
  from fabula.shipments sh left join fabula.sales_orders o on o.id = sh.sales_order_id left join fabula.parties p on p.id = sh.customer_id left join fabula.staff st on st.id = sh.packed_by_id;
grant select on fabula.v_shipment_doc to authenticated, service_role;

-- evening nudge: paid orders still not packed at end of day
create or replace view fabula.v_ship_backlog as
  select count(*) filter (where channel = 'shopify') as shopify_waiting, count(*) filter (where channel = 'wholesale') as wholesale_waiting,
         min(order_date) as oldest from fabula.v_orders_to_ship;
grant select on fabula.v_ship_backlog to authenticated, service_role;

-- evening nudge: paid online orders not yet packed → one tappable line (SHIP:) on the tablet banner
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
    if not exists (select 1 from fabula.pos_daily_closings where closing_date = p_date) then
      items := items || jsonb_build_object('code', 'z', 'label_it', 'Chiusura cassa (scontrino Z)', 'scan', 'EQ:RT-01'); end if;
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
