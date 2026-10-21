-- v1.15a (21/10/2026) · «Annulla DDT» (backlog from v1.04, «Fulfilment & shipping» on the go-live board).
-- A wrongly packed order was a dead end: from v1.04 a numbered DDT can't be deleted or changed from a login (the yearly series must
-- stay gap-free), and nothing could undo the packing. Now:
--   * fabula.cancel_shipment(id, reason) (Spedizioni = gestisce: titolare, socio, spedizioni) annuls a DDT whose goods have not left
--     (status «picked», not fulfilled on Shopify). The number stays in the register as «annullato», with when, who and why; every line
--     goes back to stock on its own lot (a «sale» move with the opposite sign, so sales totals net out); a wholesale order goes back to
--     «confirmed», so it is in «Da spedire» again; the lot written on the order lines by the packing is cleared.
--   * A DDT whose goods have left (in transit, delivered, fulfilled on Shopify) is not annulled: that is a return.
--   * A login can't set or clear the annulment by hand, nor change an annulled DDT (trigger shipments_ddt_guard).
--   * An annulled DDT no longer counts as a shipment: lot distribution (recalls), the go-live «Primo ordine vero preparato» and the trial's
--     day 3. The print page shows it as ANNULLATO.
--   * Shopify: if the sync fulfils an order on Shopify just as its DDT is annulled, the DDT stays annulled and the office is told to
--     cancel the fulfilment on Shopify.
-- The new enum value is used only as text in this migration (one transaction: a new enum value can't be used before it commits).

alter type fabula.shipment_status add value if not exists 'cancelled';
alter table fabula.shipments add column if not exists cancelled_at timestamptz;
alter table fabula.shipments add column if not exists cancelled_by_id uuid references fabula.staff(id);
alter table fabula.shipments add column if not exists cancel_reason text;
comment on column fabula.shipments.cancelled_at is 'v1.15: when the DDT was annulled (fabula.cancel_shipment). The number stays in the yearly series as «annullato».';
comment on column fabula.shipments.cancel_reason is 'v1.15: why the DDT was annulled (required).';

-- ============================== a login never annuls by hand, nor changes an annulled DDT ==============================
create or replace function fabula.trg_shipments_ddt_guard()
 returns trigger
 language plpgsql
 set search_path to 'fabula', 'public'
as $function$
begin
  if current_user not in ('authenticated', 'anon') then return case when tg_op = 'DELETE' then old else new end; end if;
  if tg_op = 'DELETE' then
    raise exception using errcode = '42501', message = format('Il DDT %s è già numerato e non si cancella: il numero progressivo resterebbe con un buco. Se è sbagliato, annullalo: Console → Operazioni → Spedizioni e DDT → «Annulla DDT».', old.ddt_number);
  end if;
  -- v1.15: the annulment goes only through cancel_shipment (stock back, order back, reason); an annulled DDT stays as it is
  if old.status::text = 'cancelled' then
    raise exception using errcode = '42501', message = format('Il DDT %s è annullato: non si modifica', old.ddt_number);
  end if;
  if new.status::text = 'cancelled' or (new.cancelled_at, new.cancelled_by_id, new.cancel_reason) is distinct from (old.cancelled_at, old.cancelled_by_id, old.cancel_reason) then
    raise exception using errcode = '42501', message = format('Il DDT %s si annulla solo con «Annulla DDT», con il motivo: così la merce torna in giacenza e l''ordine torna da spedire', old.ddt_number);
  end if;
  if new.ddt_number is distinct from old.ddt_number then
    raise exception using errcode = '42501', message = format('Il numero del DDT (%s) lo dà il database e non si cambia', old.ddt_number);
  end if;
  if (new.ship_date, new.customer_id, new.sales_order_id) is distinct from (old.ship_date, old.customer_id, old.sales_order_id) then
    raise exception using errcode = '42501', message = format('Data, cliente e ordine del DDT %s non si cambiano dopo l''emissione', old.ddt_number);
  end if;
  return new;
end $function$;
drop trigger if exists shipments_ddt_guard on fabula.shipments;
create trigger shipments_ddt_guard before delete or update on fabula.shipments for each row execute function fabula.trg_shipments_ddt_guard();

-- ============================== «Annulla DDT» ==============================
create or replace function fabula.cancel_shipment(p_shipment_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare s fabula.shipments; o fabula.sales_orders; l record; v_reason text := nullif(regexp_replace(btrim(coalesce(p_reason, '')), '\s+', ' ', 'g'), '');
        v_sid uuid := fabula.my_staff_id(); v_who text; n int := 0; v_kg numeric := 0; v_exp date; v_back boolean := false; v_other boolean;
begin
  if auth.uid() is not null then perform fabula.require_perm('spedizioni', 3); end if;
  if v_reason is null or length(v_reason) < 5 then
    raise exception using errcode = '22023', message = 'Scrivi il motivo (es. «lotto sbagliato», «cliente sbagliato», «ordine annullato dal cliente»): resta nel registro dei DDT';
  end if;
  select * into s from fabula.shipments where id = p_shipment_id for update;
  if s.id is null then raise exception using errcode = 'P0002', message = 'Spedizione non trovata: ricarica la pagina'; end if;
  if s.status::text = 'cancelled' then
    raise exception using errcode = '22023', message = format('Il DDT %s è già annullato (%s, %s)', s.ddt_number,
      to_char(s.cancelled_at at time zone 'Europe/Rome', 'DD/MM HH24:MI'), coalesce(s.cancel_reason, 'senza motivo'));
  end if;
  if s.status::text not in ('planned', 'picked') or s.shopify_fulfilled_at is not null then
    raise exception using errcode = '22023', message = format('La merce del DDT %s risulta già partita (%s): un DDT di merce partita non si annulla. Se torna indietro, è un reso.',
      s.ddt_number, case when s.shopify_fulfilled_at is not null then 'evaso su Shopify il ' || to_char(s.shopify_fulfilled_at at time zone 'Europe/Rome', 'DD/MM HH24:MI')
                         when s.status::text = 'delivered' then 'consegnata' when s.status::text = 'returned' then 'resa' else 'in viaggio' end);
  end if;
  v_who := coalesce((select full_name from fabula.staff where id = v_sid), case when auth.uid() is null then 'bot/service' else 'utente' end);
  if s.sales_order_id is not null then select * into o from fabula.sales_orders where id = s.sales_order_id for update; end if;

  -- every line back to stock, on its own lot: a «sale» move with the opposite sign, so the day's sales net out
  for l in select sl.product_id, sl.lot_number, sl.qty from fabula.shipment_lines sl where sl.shipment_id = s.id and sl.qty > 0 loop
    select max(m.expiry_date) into v_exp from fabula.stock_moves m where m.product_id = l.product_id and m.lot_number is not distinct from l.lot_number;
    insert into fabula.stock_moves (product_id, lot_number, expiry_date, qty, move_type, sales_order_id, reason, source)
    values (l.product_id, l.lot_number, v_exp, l.qty, 'sale', s.sales_order_id,
            left(format('Annullato %s%s: %s', s.ddt_number, coalesce(' · ' || o.order_number, ''), v_reason), 300), 'ddt_annullato');
    n := n + 1; v_kg := v_kg + l.qty;
  end loop;

  update fabula.shipments set status = 'cancelled', cancelled_at = now(), cancelled_by_id = v_sid, cancel_reason = left(v_reason, 300),
         notes = concat_ws(' · ', nullif(notes, ''), 'Annullato: ' || left(v_reason, 300))
   where id = s.id;

  if o.id is not null then
    v_other := exists (select 1 from fabula.shipments x where x.sales_order_id = o.id and x.id <> s.id and x.status::text in ('picked', 'in_transit', 'delivered'));
    if not v_other then
      -- the lot the packing wrote on the order lines (only where it is one of this DDT's lots)
      update fabula.sales_order_lines ol set lot_number = null
       where ol.sales_order_id = o.id and ol.lot_number is not null
         and exists (select 1 from fabula.shipment_lines sl where sl.shipment_id = s.id and sl.product_id = ol.product_id and sl.lot_number = ol.lot_number);
      -- a wholesale order was closed by the packing: it is to ship again (an online order stayed «confirmed»)
      if o.channel::text = 'wholesale' and o.status::text = 'fulfilled' then
        update fabula.sales_orders set status = 'confirmed', updated_at = now() where id = o.id;
        v_back := true;
      end if;
      v_back := v_back or o.status::text = 'confirmed';
    end if;
  end if;

  insert into fabula.audit_log (table_name, row_key, action, changed, old_data, new_data, actor_staff_id, actor)
  values ('shipments', s.id::text, 'update', array['status', 'cancel_reason'],
          jsonb_build_object('summary', s.ddt_number, 'status', s.status::text, 'cancel_reason', null),
          jsonb_build_object('summary', s.ddt_number, 'status', 'cancelled', 'cancel_reason', v_reason, 'order', o.order_number, 'lines_back', n, 'kg_back', v_kg),
          v_sid, v_who);

  return jsonb_build_object('ok', true, 'ddt_number', s.ddt_number, 'order_number', o.order_number, 'lines_back', n, 'kg_back', v_kg,
                            'order_to_ship', v_back, 'channel', o.channel::text);
end $$;
revoke all on function fabula.cancel_shipment(uuid, text) from public, anon;
grant execute on function fabula.cancel_shipment(uuid, text) to authenticated, service_role;
comment on function fabula.cancel_shipment(uuid, text) is 'v1.15 «Annulla DDT»: a DDT whose goods have not left. Number kept as «annullato», lines back to stock on their lots, a wholesale order back to «confirmed». Spedizioni = gestisce; reason required; audit_log.';

-- ============================== Shopify: an annulled DDT stays annulled ==============================
create or replace function fabula.mark_shopify_fulfilled(p_shipment_id uuid, p_fulfillment_gid text default null::text)
 returns text
 language plpgsql
 set search_path to 'fabula', 'public', 'extensions'
as $function$
declare v_order uuid; v_status text; v_ddt text; v_num text;
begin
  select sales_order_id, status::text, ddt_number into v_order, v_status, v_ddt from fabula.shipments where id = p_shipment_id for update;
  if not found then raise exception 'Spedizione non trovata'; end if;
  -- v1.15: annulled while the sync was fulfilling it on Shopify: the DDT stays annulled, the office cancels the fulfilment on Shopify
  if v_status = 'cancelled' then
    update fabula.shipments set shopify_fulfillment_id = p_fulfillment_gid, shopify_fulfilled_at = now(), updated_at = now() where id = p_shipment_id;
    select order_number into v_num from fabula.sales_orders where id = v_order;
    perform fabula.post_bot_message('shopify_orders', 'alert', format('Ordine %s evaso su Shopify, ma il suo DDT %s è annullato', v_num, v_ddt),
      format(E'**Da fare**\n1. Su Shopify apri l''ordine %s e annulla l''evasione: il cliente ha ricevuto la mail di spedizione.\n2. Prepara di nuovo l''ordine dal tablet (🚚 Da spedire).\n\n**In breve**\n- Il DDT %s è stato annullato mentre la sincronizzazione evadeva l''ordine su Shopify.\n\nEN — Order %s was fulfilled on Shopify while its DDT %s was being annulled: cancel the fulfilment on Shopify and pack the order again.',
             v_num, v_ddt, v_num, v_ddt), null, 'console.html#ops', 'Spedizioni e DDT');
    return 'cancelled';
  end if;
  update fabula.shipments set shopify_fulfillment_id = p_fulfillment_gid, shopify_fulfilled_at = now(), status = 'in_transit', updated_at = now() where id = p_shipment_id;
  update fabula.sales_orders set status = 'fulfilled', updated_at = now() where id = v_order;
  return 'fulfilled';
end $function$;

-- ============================== the print page and the register: who annulled, when, why ==============================
create or replace view fabula.v_shipment_doc with (security_invoker = true) as
  select sh.id as shipment_id, sh.ddt_number, sh.ship_date, sh.status::text as status, sh.carrier, sh.tracking_number, sh.gross_weight_kg, sh.notes, sh.packed_at,
         o.order_number, o.channel::text as channel, o.order_date, o.total_eur, o.ship_city, o.shopify_payload->'shipping_address' as ship_address, o.shopify_payload->>'email' as order_email,
         p.legal_name as customer, p.address as customer_address, p.city as customer_city, p.province as customer_province, p.postcode as customer_postcode, p.piva as customer_piva, p.phone as customer_phone, p.email as customer_email,
         st.full_name as packed_by,
         (select coalesce(jsonb_agg(jsonb_build_object('name', pr.name, 'sku', pr.sku, 'unit', pr.unit, 'lot', sl.lot_number, 'qty', sl.qty, 'ordered', sl.ordered_qty, 'expiry', s.expiry_date, 'weighed', sl.weighed) order by pr.name, sl.lot_number), '[]')
          from fabula.shipment_lines sl join fabula.products pr on pr.id = sl.product_id
          left join lateral (select max(expiry_date) expiry_date from fabula.stock_moves m where m.product_id = sl.product_id and m.lot_number = sl.lot_number) s on true
          where sl.shipment_id = sh.id) as lines,
         o.delivery_address, o.delivery_window, o.delivery_instructions, o.po_number,
         sh.cancelled_at, sh.cancel_reason, cb.full_name as cancelled_by, sh.shopify_fulfilled_at, sh.delivered_at   -- v1.15
  from fabula.shipments sh left join fabula.sales_orders o on o.id = sh.sales_order_id left join fabula.parties p on p.id = sh.customer_id
  left join fabula.staff st on st.id = sh.packed_by_id left join fabula.staff cb on cb.id = sh.cancelled_by_id;

-- an annulled DDT's goods never left: not in the lot's distribution (recalls, lot trace)
create or replace view fabula.v_lot_distribution with (security_invoker = true) as
select sl.lot_number, 'wholesale' as channel, p.legal_name as customer, sh.ddt_number as ref, sh.ship_date as on_date, sl.qty
from fabula.shipment_lines sl
join fabula.shipments sh on sh.id = sl.shipment_id
join fabula.parties p on p.id = sh.customer_id
where sh.status::text <> 'cancelled'
union all
select sol.lot_number, so.channel::text, coalesce(p.legal_name,'anonimo'), so.order_number, so.order_date, sol.qty
from fabula.sales_order_lines sol
join fabula.sales_orders so on so.id = sol.sales_order_id
left join fabula.parties p on p.id = so.customer_id
where sol.lot_number is not null;

-- ============================== the go-live «first shipment» and the trial's day 3 ==============================
do $mig$
declare d text; a text; r text;
begin
  d := pg_get_functiondef('fabula.ops_dashboard()'::regprocedure);
  a := 'from fabula.shipments sh where sh.packed_at is not null';
  r := 'from fabula.shipments sh where sh.packed_at is not null and sh.status::text <> ''cancelled''';   -- v1.15: an annulled DDT is not a shipment
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'v115a: ops_dashboard first_shipment anchor not found exactly once'; end if;
  execute replace(d, a, r);

  d := pg_get_functiondef('fabula.trial_check(date)'::regprocedure);
  a := 'from fabula.shipments where packed_at >= v_from and packed_at < v_to;';
  r := 'from fabula.shipments where packed_at >= v_from and packed_at < v_to and status::text <> ''cancelled'';';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'v115a: trial_check day-3 anchor not found exactly once'; end if;
  execute replace(d, a, r);
end $mig$;

insert into fabula.security_accepted (key, reason) values
  ('authenticated_security_definer_function_executable:fabula.cancel_shipment(p_shipment_id uuid, p_reason text)',
   'by design (v1.15): «Annulla DDT» for goods that have not left; Spedizioni = gestisce, reason required, written to audit_log')
on conflict (key) do nothing;
