-- v0.71a (05/10/2026) · Packing on autopilot.
-- fabula.packing_plan(date): the day's orders to ship in packing order (late first, then by due date, wholesale before
-- online on the same day) with the lots already allocated: oldest in-date lot first (FEFO), a line split over two lots when
-- one is not enough, allocated across the whole list so two orders are never promised the same kg. Lots on food-safety
-- hold, expired, or with less shelf life left than the channel needs (ship.min_days_left_online 2 days, _wholesale 1) are
-- never allocated and are listed as blocked with the reason. Also the pick list for the cold room (product · lot · kg ·
-- orders) and, per order, the kg short and the days late.
-- pack_order (same signature): a held or expired lot is refused outright (no override); short stock, short shelf life and
-- a weight outside the tolerance come back as needs_confirm with the reasons, and are saved only on the second "Salva".
-- Before, the weight confirmation also skipped the stock check, and held/expired lots were not checked at all.
-- An online order with no customer (guest checkout) no longer fails at packing: the consignee is created from the
-- Shopify shipping name and linked to the order.

insert into fabula.settings(key, value, description, data_type, sort) values
 ('ship.min_days_left_online', '2', 'Giorni minimi di vita residua del lotto per gli ordini online (corriere): sotto, il lotto non viene proposto e il tablet chiede conferma', 'number', 71),
 ('ship.min_days_left_wholesale', '1', 'Giorni minimi di vita residua del lotto per gli ordini ingrosso (consegna diretta)', 'number', 72)
on conflict (key) do nothing;

create or replace function fabula.ship_min_days(p_channel text) returns int
language sql stable set search_path = fabula, public as $$
  select case when p_channel = 'wholesale' then fabula.setting_num('ship.min_days_left_wholesale', 1)
              else fabula.setting_num('ship.min_days_left_online', 2) end::int
$$;

-- the day's packing list with FEFO lot allocation (read-only)
create or replace function fabula.packing_plan(p_date date default ((now() at time zone 'Europe/Rome')::date)) returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare o record; l jsonb; s record; rem jsonb := '{}'; v_key text; v_left numeric; v_need numeric; v_take numeric; v_min int;
        orders jsonb := '[]'; lines jsonb; allocs jsonb; blocked jsonb; elig jsonb; v_short numeric; v_order_short numeric; pick jsonb := '{}';
begin
  perform fabula.require_perm('spedizioni', 1);
  -- stock per lot (finished goods with stock), with hold flag
  for s in select st.product_id, st.lot_number, st.expiry_date, st.qty_on_hand from fabula.v_stock_on_hand st where st.qty_on_hand > 0 and st.kind = 'finished_good' loop
    rem := rem || jsonb_build_object(s.product_id || '|' || s.lot_number, s.qty_on_hand);
  end loop;

  for o in
    select v.*, greatest(p_date - v.due_date, 0) late_days from fabula.v_orders_to_ship v
     order by (v.due_date < p_date) desc, v.due_date, (v.channel = 'wholesale') desc, v.order_number
  loop
    v_min := fabula.ship_min_days(o.channel); lines := '[]'; v_order_short := 0;
    for l in select * from jsonb_array_elements(coalesce(o.lines, '[]')) loop
      v_need := (l->>'qty')::numeric; allocs := '[]'; blocked := '[]'; elig := '[]';
      for s in
        select st.lot_number, st.expiry_date, st.qty_on_hand,
               coalesce((select b.food_safety_hold from fabula.production_batches b where b.batch_lot = st.lot_number), false) held,
               (select b.hold_reason from fabula.production_batches b where b.batch_lot = st.lot_number) hold_reason
          from fabula.v_stock_on_hand st
         where st.product_id = (l->>'product_id')::uuid and st.qty_on_hand > 0
         order by st.expiry_date nulls last, st.lot_number
      loop
        if s.held then
          blocked := blocked || jsonb_build_object('lot', s.lot_number, 'expiry', s.expiry_date, 'on_hand', round(s.qty_on_hand, 2), 'reason', 'held', 'detail', coalesce(s.hold_reason, 'bloccato'));
          continue;
        elsif s.expiry_date is not null and s.expiry_date < p_date then
          blocked := blocked || jsonb_build_object('lot', s.lot_number, 'expiry', s.expiry_date, 'on_hand', round(s.qty_on_hand, 2), 'reason', 'expired');
          continue;
        elsif s.expiry_date is not null and s.expiry_date < p_date + v_min then
          blocked := blocked || jsonb_build_object('lot', s.lot_number, 'expiry', s.expiry_date, 'on_hand', round(s.qty_on_hand, 2), 'reason', 'short_life', 'min_days', v_min);
          continue;
        end if;
        v_key := (l->>'product_id') || '|' || s.lot_number;
        v_left := coalesce((rem->>v_key)::numeric, 0);
        elig := elig || jsonb_build_object('lot', s.lot_number, 'expiry', s.expiry_date, 'on_hand', round(s.qty_on_hand, 2), 'free', round(v_left, 2));
        if v_need > 0 and v_left > 0 then
          v_take := least(v_need, v_left);
          allocs := allocs || jsonb_build_object('lot', s.lot_number, 'expiry', s.expiry_date, 'qty', round(v_take, 2), 'on_hand', round(s.qty_on_hand, 2));
          rem := rem || jsonb_build_object(v_key, v_left - v_take);
          v_need := v_need - v_take;
          pick := jsonb_set(pick, array[v_key], jsonb_build_object('product', l->>'name', 'unit', l->>'unit', 'lot', s.lot_number, 'expiry', s.expiry_date,
                    'kg', round(coalesce((pick #>> array[v_key, 'kg'])::numeric, 0) + v_take, 2),
                    'orders', coalesce(pick #> array[v_key, 'orders'], '[]') || to_jsonb(o.order_number)));
        end if;
      end loop;
      v_short := round(greatest(v_need, 0), 2); v_order_short := v_order_short + v_short;
      lines := lines || jsonb_build_array((l - 'suggested') || jsonb_build_object('alloc', allocs, 'short_kg', v_short, 'blocked', blocked, 'eligible', elig, 'min_days', v_min));
    end loop;
    orders := orders || jsonb_build_object('order_id', o.order_id, 'order_number', o.order_number, 'channel', o.channel, 'customer', o.customer, 'phone', o.phone,
                'ship_address', o.ship_address, 'ship_city', o.ship_city, 'due_date', o.due_date, 'late_days', o.late_days, 'unmapped', o.unmapped,
                'total_eur', o.total_eur, 'lines', lines, 'short_kg', v_order_short);
  end loop;

  return jsonb_build_object('date', p_date, 'orders', orders,
    'pick', (select coalesce(jsonb_agg(x.value order by x.value->>'product', x.value->>'expiry', x.value->>'lot'), '[]') from jsonb_each(pick) x),
    'totals', jsonb_build_object('orders', jsonb_array_length(orders),
       'late', (select count(*) from jsonb_array_elements(orders) x where (x->>'late_days')::int > 0),
       'short', (select count(*) from jsonb_array_elements(orders) x where (x->>'short_kg')::numeric > 0),
       'kg', (select coalesce(sum((a->>'qty')::numeric), 0) from jsonb_array_elements(orders) x, jsonb_array_elements(x->'lines') li, jsonb_array_elements(li->'alloc') a)));
end $$;
revoke all on function fabula.packing_plan(date) from public, anon;
grant execute on function fabula.packing_plan(date) to authenticated, service_role;

-- pack_order: same signature; held/expired lots refused, other problems confirmed with reasons
create or replace function fabula.pack_order(p_order_id uuid, p_lines jsonb, p_staff_id uuid, p_gross_kg numeric DEFAULT NULL::numeric, p_carrier text DEFAULT NULL::text, p_tracking text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_force boolean DEFAULT false)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare o fabula.sales_orders%rowtype; l jsonb; v_ship uuid; v_ddt text; v_on_hand numeric; v_ordered numeric; v_packed numeric := 0; v_tol numeric; v_var numeric; v_carrier text; n int := 0; v_exp date; v_order_total_kg numeric;
        v_today date := (now() at time zone 'Europe/Rome')::date; v_min int; v_reasons jsonb := '[]'; v_held boolean; v_lot_need jsonb := '{}'; v_k text;
begin
  perform fabula.require_perm('spedizioni', 2);
  select * into o from fabula.sales_orders where id = p_order_id;
  if o.id is null then raise exception 'Ordine non trovato'; end if;
  if o.status <> 'confirmed' then raise exception 'Ordine % non in stato confermato (%)', o.order_number, o.status; end if;
  if exists (select 1 from fabula.shipments where sales_order_id = p_order_id and status in ('picked','in_transit','delivered')) then raise exception 'Ordine % già preparato', o.order_number; end if;
  if jsonb_array_length(coalesce(p_lines, '[]'::jsonb)) = 0 then raise exception 'Nessuna riga'; end if;
  v_min := fabula.ship_min_days(o.channel::text);
  select coalesce(sum(qty), 0) into v_order_total_kg from fabula.sales_order_lines where sales_order_id = p_order_id and qty > 0;
  for l in select * from jsonb_array_elements(p_lines) loop
    if coalesce((l->>'qty')::numeric, 0) <= 0 then raise exception 'Quantità non valida per il lotto %', l->>'lot_number'; end if;
    select qty_on_hand, expiry_date into v_on_hand, v_exp from fabula.v_stock_on_hand where product_id = (l->>'product_id')::uuid and lot_number = l->>'lot_number';
    if v_on_hand is null then raise exception 'Lotto % non in giacenza per questo prodotto', l->>'lot_number'; end if;
    select food_safety_hold into v_held from fabula.production_batches where batch_lot = l->>'lot_number';
    if coalesce(v_held, false) then raise exception 'Lotto % bloccato per sicurezza alimentare: non si può spedire', l->>'lot_number' using errcode = '23514'; end if;
    if v_exp is not null and v_exp < v_today then raise exception 'Lotto % scaduto il %: non si può spedire', l->>'lot_number', to_char(v_exp, 'DD/MM/YYYY') using errcode = '23514'; end if;
    if v_exp is not null and v_exp < v_today + v_min then
      v_reasons := v_reasons || to_jsonb(format('il lotto %s scade il %s (minimo %s giorni per %s)', l->>'lot_number', to_char(v_exp, 'DD/MM'), v_min, case when o.channel = 'wholesale' then 'l''ingrosso' else 'gli ordini online' end));
    end if;
    -- the same lot on two rows counts once against its stock
    v_k := (l->>'product_id') || '|' || (l->>'lot_number');
    v_lot_need := v_lot_need || jsonb_build_object(v_k, coalesce((v_lot_need->>v_k)::numeric, 0) + (l->>'qty')::numeric);
    if v_on_hand + 0.0005 < (v_lot_need->>v_k)::numeric then
      v_reasons := v_reasons || to_jsonb(format('il lotto %s ha %s kg in giacenza, ne prepari %s', l->>'lot_number', round(v_on_hand, 2), round((v_lot_need->>v_k)::numeric, 2)));
    end if;
    v_packed := v_packed + (l->>'qty')::numeric;
  end loop;
  v_tol := fabula.setting_num('ship.tolerance_pct', 5);
  v_var := case when v_order_total_kg > 0 then round((v_packed - v_order_total_kg) / v_order_total_kg * 100, 2) else 0 end;
  if abs(v_var) > v_tol then
    v_reasons := v_reasons || to_jsonb(format('pesati %s kg contro %s ordinati (%s%s%%)', round(v_packed, 2), round(v_order_total_kg, 2), case when v_var > 0 then '+' else '' end, v_var));
  end if;
  if jsonb_array_length(v_reasons) > 0 and not p_force then
    return jsonb_build_object('ok', false, 'needs_confirm', true, 'reasons', v_reasons, 'ordered_kg', v_order_total_kg, 'packed_kg', v_packed, 'variance_pct', v_var, 'tolerance_pct', v_tol);
  end if;
  -- an online order with no customer (guest checkout, customer not synced yet): the consignee comes from the Shopify
  -- shipping name, so the shipment and its DDT/packing list always have one
  if o.customer_id is null then
    insert into fabula.parties (type, legal_name, notes)
    values ('customer', coalesce(nullif(trim(o.shopify_payload #>> '{shipping_address,name}'), ''), 'Cliente online ' || o.order_number),
            'Creato alla spedizione di ' || o.order_number || ' (ordine senza cliente)')
    returning id into o.customer_id;
    update fabula.sales_orders set customer_id = o.customer_id, updated_at = now() where id = o.id;
  end if;
  v_carrier := coalesce(nullif(p_carrier, ''), case when o.channel = 'wholesale' then fabula.setting_text('ship.wholesale_carrier', 'Consegna diretta') else fabula.setting_text('ship.default_carrier', 'BRT') end);
  v_ddt := 'DDT-' || to_char(v_today, 'YYYYMMDD') || '-' || lpad(((select count(*) from fabula.shipments where ship_date = v_today) + 1)::text, 2, '0');
  insert into fabula.shipments (ddt_number, customer_id, sales_order_id, status, ship_date, driver_id, notes, carrier, tracking_number, gross_weight_kg, packed_by_id, packed_at, weight_variance_pct)
  values (v_ddt, o.customer_id, o.id, 'picked', v_today, p_staff_id, nullif(concat_ws(' · ', nullif(p_notes, ''), case when jsonb_array_length(v_reasons) > 0 then 'Confermato: ' || (select string_agg(r #>> '{}', '; ') from jsonb_array_elements(v_reasons) r) end), ''),
          v_carrier, nullif(p_tracking, ''), p_gross_kg, p_staff_id, now(), v_var)
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
  if o.channel = 'wholesale' then update fabula.sales_orders set status = 'fulfilled', updated_at = now() where id = o.id; end if;
  return jsonb_build_object('ok', true, 'shipment_id', v_ship, 'ddt_number', v_ddt, 'order_number', o.order_number, 'channel', o.channel, 'lines', n, 'packed_kg', v_packed, 'ordered_kg', v_order_total_kg, 'variance_pct', v_var, 'carrier', v_carrier,
                            'needs_shopify_fulfilment', o.channel = 'shopify', 'confirmed', v_reasons);
end $$;

insert into fabula.security_accepted (key, reason, accepted_at) values
 ('authenticated_security_definer_function_executable:fabula.packing_plan(p_date date)',
  'by design: tablet Da spedire (v0.71); checks require_perm(spedizioni, 1) inside; read-only', now())
on conflict (key) do nothing;
