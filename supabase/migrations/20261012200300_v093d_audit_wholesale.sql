-- v0.93d · Audit 12/10/2026, phase 0 — wholesale fixes (bugs 14, 15, 16, 17).
--  14 (TRADE-02 / E-15) A one-day change can no longer drop a delivery under the minimum order: the change is refused with the reason,
--     as the setting trade.min_order_kg always promised. A delivery that is still under the minimum at booking time (18:20) is no longer
--     dropped in silence: the customer reads it in the portal log and the office gets a warning in the Bot feed.
--  15 (D-14 / TRADE-04) "La consegna del 13/10s … le 18:00s": PL/pgSQL placeholders are %, not %s.
--  16 (B-20 / D-10) A change forced by staff after the 18:20 booking used to be logged ("Saltata la consegna") while the booked order
--     still shipped and was invoiced. Now «Salta» on a booked day also cancels that order (and its Shopify queue entry if not sent yet,
--     otherwise the message says to cancel the Shopify order too); any other change to a booked day is refused with what to do instead.
--  17 (PRINT-01) The DDT shows the delivery address, time window, driver instructions and the customer's PO number of the order.

create or replace function fabula.trade_add_exception(p_customer uuid, p_payload jsonb, p_actor text default 'customer'::text, p_force boolean default false)
 returns jsonb
 language plpgsql
 set search_path to 'fabula', 'public'
as $function$
declare k text := p_payload->>'kind'; d1 date := (p_payload->>'date_from')::date; d2 date := coalesce(nullif(p_payload->>'date_to', '')::date, (p_payload->>'date_from')::date); v_id uuid; msg text; s jsonb := fabula.trade_settings(); tp fabula.trade_products%rowtype;
        o record; v_booked text := ''; v_shop text := ''; dd date; v_kg numeric; v_min numeric := nullif(fabula.trade_settings()->>'min_order_kg', '')::numeric;
begin
  if k not in ('skip','override','window') then raise exception 'Tipo di modifica non valido' using errcode = '22023'; end if;
  if d2 < d1 then raise exception 'Date non valide' using errcode = '22023'; end if;
  if not p_force and not fabula.trade_can_change(d1) then
    raise exception 'La consegna del % è già confermata (modifiche entro le % del giorno prima)', to_char(d1, 'DD/MM'), s->>'cutoff_time' using errcode = '22023';
  end if;
  -- v0.93d (audit B-20/D-10): a day already booked as an order. «Salta» cancels the order; other changes would not reach it → refused.
  for o in select so.id, so.order_number, so.order_date, so.status::text as status, q.status as qstatus, q.shopify_order_name
             from fabula.sales_orders so left join fabula.trade_order_queue q on q.sales_order_id = so.id
            where so.customer_id = p_customer and so.channel = 'wholesale' and so.source = 'standing_order' and so.status <> 'cancelled'
              and so.order_date between d1 and d2 order by so.order_date loop
    if o.status = 'fulfilled' then
      raise exception 'La consegna del % è già partita (ordine %): non si può più cambiare.', to_char(o.order_date, 'DD/MM'), o.order_number using errcode = '22023';
    end if;
    if k <> 'skip' then
      raise exception 'La consegna del % è già prenotata (ordine %): questa modifica non la cambierebbe. Per non consegnare usa «Salta» per quel giorno; per altre quantità salta e prepara un ordine a parte.', to_char(o.order_date, 'DD/MM'), o.order_number using errcode = '22023';
    end if;
    update fabula.sales_orders set status = 'cancelled', notes = concat_ws(' · ', notes, 'annullato: consegna saltata dopo la prenotazione (' || p_actor || ')'), updated_at = now() where id = o.id;
    update fabula.trade_order_queue set status = 'skipped', error = 'consegna saltata dopo la prenotazione' where sales_order_id = o.id and status in ('pending', 'failed');
    v_booked := v_booked || case when v_booked = '' then '' else ', ' end || o.order_number;
    if o.qstatus = 'created' then v_shop := v_shop || case when v_shop = '' then '' else ', ' end || coalesce(o.shopify_order_name, o.order_number); end if;
  end loop;
  if k = 'override' then
    select * into tp from fabula.trade_products where variant_id = p_payload->>'variant_id' and active and trade_price_eur is not null;
    if tp.variant_id is null then raise exception 'Prodotto non in listino' using errcode = '22023'; end if;
    if (p_payload->>'qty')::numeric > 0 and (p_payload->>'qty')::numeric < tp.min_qty then raise exception 'Quantità sotto il minimo (%)', trim_scale(tp.min_qty) using errcode = '22023'; end if;
    -- one override per product per range: the newest replaces the older one on overlapping dates
    update fabula.trade_exceptions set cancelled_at = now() where customer_id = p_customer and kind = 'override' and variant_id = tp.variant_id and cancelled_at is null and date_from <= d2 and date_to >= d1;
  elsif k = 'window' then
    if not ((p_payload->>'window') in (select ww.val from jsonb_array_elements_text(s->'windows') as ww(val))) then raise exception 'Fascia oraria non disponibile' using errcode = '22023'; end if;
    update fabula.trade_exceptions set cancelled_at = now() where customer_id = p_customer and kind = 'window' and cancelled_at is null and date_from <= d2 and date_to >= d1;
  end if;
  insert into fabula.trade_exceptions (customer_id, kind, date_from, date_to, variant_id, qty, window_code, note, created_by)
  values (p_customer, k, d1, d2, case when k = 'override' then tp.variant_id end, case when k = 'override' then (p_payload->>'qty')::numeric end,
          case when k = 'window' then p_payload->>'window' end, nullif(p_payload->>'note', ''), p_actor) returning id into v_id;
  -- v0.93d (audit TRADE-02): a change that leaves a delivery under the minimum order is refused (it used to be accepted and the
  -- delivery then silently not booked). Checked on the plan as it is after this change, for every delivery day in the range.
  if k = 'override' and v_min is not null then
    for dd in select g::date from generate_series(d1, least(d2, d1 + 62), interval '1 day') g loop
      continue when not fabula.trade_is_delivery_day(dd);
      select coalesce(sum(e.kg), 0) into v_kg from fabula.trade_effective_lines(dd) e where e.customer_id = p_customer;
      if v_kg > 0 and v_kg < v_min then
        raise exception 'Con questa modifica la consegna del % scende a % kg, sotto il minimo d''ordine di % kg: aumenta la quantità oppure salta la consegna di quel giorno.',
          to_char(dd, 'DD/MM'), replace(trim_scale(round(v_kg, 2))::text, '.', ','), replace(trim_scale(v_min)::text, '.', ',') using errcode = '22023';
      end if;
    end loop;
  end if;
  msg := case k
    when 'skip' then case when d1 = d2 then format('Saltata la consegna del %s.', to_char(d1, 'DD/MM/YYYY')) else format('Chiusura dal %s al %s: nessuna consegna in quei giorni.', to_char(d1, 'DD/MM/YYYY'), to_char(d2, 'DD/MM/YYYY')) end
    when 'override' then format('%s: %s → %s %s %s. Dopo si torna al piano normale.', case when d1 = d2 then 'Il ' || to_char(d1, 'DD/MM/YYYY') else 'Dal ' || to_char(d1, 'DD/MM/YYYY') || ' al ' || to_char(d2, 'DD/MM/YYYY') end,
                                tp.title || coalesce(' ' || tp.variant_title, ''), trim_scale((p_payload->>'qty')::numeric), tp.unit_label, case when (p_payload->>'qty')::numeric = 0 then '(tolto)' else '' end)
    else format('%s: consegna nella fascia %s. Dopo si torna alla fascia abituale.', case when d1 = d2 then 'Il ' || to_char(d1, 'DD/MM/YYYY') else 'Dal ' || to_char(d1, 'DD/MM/YYYY') || ' al ' || to_char(d2, 'DD/MM/YYYY') end, p_payload->>'window') end;
  if v_booked <> '' then msg := msg || ' Ordine già prenotato ' || v_booked || ' annullato.'; end if;
  perform fabula.trade_log(p_customer, p_actor, 'exception_' || k, p_payload || jsonb_build_object('id', v_id, 'cancelled_orders', v_booked), msg);
  return jsonb_build_object('ok', true, 'id', v_id, 'message_it',
    msg || case when v_shop <> '' then ' ATTENZIONE: era già su Shopify (' || v_shop || '): annullalo anche su Shopify.' else '' end,
    'cancelled_orders', nullif(v_booked, ''), 'cancel_on_shopify', nullif(v_shop, ''));
end $function$;

-- 15 · the other "%s" message
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.trade_cancel_exception(uuid,uuid,text,boolean)'::regprocedure);
  n := replace(d, $s$raise exception 'La consegna del %s è già confermata', $s$, $s$raise exception 'La consegna del % è già confermata', $s$);
  if n = d then raise exception 'v093d: message not found in trade_cancel_exception'; end if;
  execute n;
end $mig$;

-- 14 (booking) · under the minimum at 18:20: the customer is told in the portal and the office gets a warning, once per customer and day
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.confirm_standing_orders(date)'::regprocedure);
  n := replace(d, $s$    if c.kg < v_min then under := under || jsonb_build_object('customer', c.legal_name, 'kg', c.kg); continue; end if;$s$,
$s$    if c.kg < v_min then
      under := under || jsonb_build_object('customer', c.legal_name, 'kg', c.kg, 'phone', c.phone);
      -- v0.93d (audit E-15): no longer silent — portal log for the customer, Bot feed warning for the office (once per customer and day)
      if not exists (select 1 from fabula.trade_change_log x where x.customer_id = c.customer_id and x.action = 'under_minimum' and x.details->>'date' = d::text) then
        perform fabula.trade_log(c.customer_id, 'sistema', 'under_minimum', jsonb_build_object('date', d, 'kg', c.kg, 'min_kg', v_min),
          format('Consegna di %s %s NON prenotata: %s kg sono sotto il minimo d''ordine di %s kg. Se ti serve comunque, chiamaci.',
                 fabula.trade_wd_it(extract(isodow from d)::int), to_char(d, 'DD/MM'), replace(trim_scale(round(c.kg, 2))::text, '.', ','), replace(trim_scale(v_min)::text, '.', ',')));
        perform fabula.post_bot_message('wholesale_orders', 'warn',
          format('Consegna di %s %s NON prenotata: %s', fabula.trade_wd_it(extract(isodow from d)::int), to_char(d, 'DD/MM'), c.legal_name),
          format(E'**Da fare**\n1. Chiama %s%s: %s kg sono sotto il minimo d''ordine di %s kg, quindi la consegna non parte. Se va consegnata comunque, prepara un ordine a parte.\n\nEN — %s will not get a delivery on %s: below the minimum order.',
                 c.legal_name, coalesce(' (' || c.phone || ')', ''), replace(trim_scale(round(c.kg, 2))::text, '.', ','), replace(trim_scale(v_min)::text, '.', ','), c.legal_name, to_char(d, 'DD/MM')));
      end if;
      continue;
    end if;$s$);
  if n = d then raise exception 'v093d: under-minimum line not found in confirm_standing_orders'; end if;
  execute n;
end $mig$;

-- 17 · DDT: where the goods go, when, how, and the customer's reference (columns appended; security_invoker kept)
create or replace view fabula.v_shipment_doc with (security_invoker = true) as
  select sh.id as shipment_id, sh.ddt_number, sh.ship_date, sh.status::text as status, sh.carrier, sh.tracking_number, sh.gross_weight_kg, sh.notes, sh.packed_at,
         o.order_number, o.channel::text as channel, o.order_date, o.total_eur, o.ship_city, o.shopify_payload->'shipping_address' as ship_address, o.shopify_payload->>'email' as order_email,
         p.legal_name as customer, p.address as customer_address, p.city as customer_city, p.province as customer_province, p.postcode as customer_postcode, p.piva as customer_piva, p.phone as customer_phone, p.email as customer_email,
         st.full_name as packed_by,
         (select coalesce(jsonb_agg(jsonb_build_object('name', pr.name, 'sku', pr.sku, 'unit', pr.unit, 'lot', sl.lot_number, 'qty', sl.qty, 'ordered', sl.ordered_qty, 'expiry', s.expiry_date, 'weighed', sl.weighed) order by pr.name, sl.lot_number), '[]')
          from fabula.shipment_lines sl join fabula.products pr on pr.id = sl.product_id
          left join lateral (select max(expiry_date) expiry_date from fabula.stock_moves m where m.product_id = sl.product_id and m.lot_number = sl.lot_number) s on true
          where sl.shipment_id = sh.id) as lines,
         o.delivery_address, o.delivery_window, o.delivery_instructions, o.po_number
  from fabula.shipments sh left join fabula.sales_orders o on o.id = sh.sales_order_id left join fabula.parties p on p.id = sh.customer_id left join fabula.staff st on st.id = sh.packed_by_id;
grant select on fabula.v_shipment_doc to authenticated, service_role;
