-- v1.15a (21/10/2026) · «Annulla DDT» (backlog from v1.04, «Fulfilment & shipping» on the go-live board).
-- A wrongly packed order was a dead end: from v1.04 a numbered DDT can't be deleted or changed from a login (the yearly series must
-- stay gap-free), and nothing could undo the packing. Now:
--   * fabula.cancel_shipment(id, reason) (Spedizioni = gestisce: titolare, socio, spedizioni) annuls a DDT packed TODAY whose goods have
--     not left (not in transit, delivered or fulfilled on Shopify). Wholesale and direct DDTs have no «partito» step, so «today» is
--     what stops a DDT delivered days ago from being annulled into stock that no longer exists. The number stays in the register as
--     «annullato», with when, who and why.
--   * The stock that comes back is exactly what the DDT took: the «sale» moves linked to it (new stock_moves.shipment_id, set by
--     pack_order and, for the tablet's direct shipment, by a trigger matching the DDT's lines written in the same save), reversed with
--     the same date, so the day's sales net out. Not the DDT's lines, which a login could have changed.
--   * A wholesale order goes back to «confirmed», so it is in «Da spedire» again; the lot written on the order lines by the packing is
--     cleared. «Stock already booked for this order» is now the net of its sale moves (Shopify stock push, the Shopify order sync, the
--     console), so an annulled order is reserved again and is deducted when Shopify fulfils it.
--   * Guards for logins: no annulment by hand (insert or update), no change to an annulled DDT; a DDT's lines are written only with the
--     DDT itself and never changed or deleted afterwards.
--   * An annulled DDT no longer counts as a shipment: lot distribution (recalls), recall drills, the go-live «Primo ordine vero
--     preparato», the trial's day 3, the auto-cancelling of placeholder orders, the «sold on a held lot» check.
--   * Shopify: if the sync fulfils an order on Shopify just as its DDT is annulled, the DDT stays annulled and the office is told.
-- The new enum value is used only as text in this migration (one transaction: a new enum value can't be used before it commits).

alter type fabula.shipment_status add value if not exists 'cancelled';
alter table fabula.shipments add column if not exists cancelled_at timestamptz;
alter table fabula.shipments add column if not exists cancelled_by_id uuid references fabula.staff(id);
alter table fabula.shipments add column if not exists cancel_reason text;
comment on column fabula.shipments.cancelled_at is 'v1.15: when the DDT was annulled (fabula.cancel_shipment). The number stays in the yearly series as «annullato».';
comment on column fabula.shipments.cancel_reason is 'v1.15: why the DDT was annulled (required).';
alter table fabula.stock_moves add column if not exists shipment_id uuid references fabula.shipments(id);
create index if not exists stock_moves_shipment_idx on fabula.stock_moves (shipment_id) where shipment_id is not null;
comment on column fabula.stock_moves.shipment_id is 'v1.15: the DDT a «sale» move belongs to (pack_order; the tablet''s direct shipment by trigger stock_moves_ship_link). «Annulla DDT» reverses exactly these moves.';

-- the tablet's direct shipment writes the DDT, its line and the stock move in one save (save_ops, one transaction): the move is linked
-- to the line of a DDT written in the same transaction with the same product, lot and kg (older tablets included, nothing to change there)
create or replace function fabula.trg_stock_moves_ship_link() returns trigger
language plpgsql set search_path = fabula, public as $$
begin
  if new.shipment_id is null and new.move_type = 'sale' and new.qty < 0 then
    select sl.shipment_id into new.shipment_id
      from fabula.shipment_lines sl join fabula.shipments sh on sh.id = sl.shipment_id
     where sh.created_at = now() and sl.product_id = new.product_id and sl.lot_number is not distinct from new.lot_number and sl.qty = -new.qty
       and not exists (select 1 from fabula.stock_moves m where m.shipment_id = sl.shipment_id and m.product_id = sl.product_id
                         and m.lot_number is not distinct from sl.lot_number and m.qty = -sl.qty)
     order by sh.created_at desc limit 1;
  end if;
  return new;
end $$;
drop trigger if exists stock_moves_ship_link on fabula.stock_moves;
create trigger stock_moves_ship_link before insert on fabula.stock_moves for each row execute function fabula.trg_stock_moves_ship_link();

-- DDTs packed before v1.15: pack_order wrote «Spedizione <DDT> · <order>» on its moves
update fabula.stock_moves m set shipment_id = sh.id
  from fabula.shipments sh
 where m.shipment_id is null and m.move_type = 'sale' and m.sales_order_id = sh.sales_order_id and m.reason like 'Spedizione ' || sh.ddt_number || ' · %';

-- ============================== a login never annuls by hand, nor changes an annulled DDT ==============================
create or replace function fabula.trg_shipments_ddt_guard()
 returns trigger
 language plpgsql
 set search_path to 'fabula', 'public'
as $function$
begin
  if current_user not in ('authenticated', 'anon') then return case when tg_op = 'DELETE' then old else new end; end if;
  if tg_op = 'INSERT' then                     -- v1.15: a DDT is never written already annulled
    if new.status::text = 'cancelled' or new.cancelled_at is not null or new.cancelled_by_id is not null or new.cancel_reason is not null then
      raise exception using errcode = '42501', message = 'Un DDT si annulla solo con «Annulla DDT», dopo averlo emesso';
    end if;
    return new;
  end if;
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
create trigger shipments_ddt_guard before insert or delete or update on fabula.shipments for each row execute function fabula.trg_shipments_ddt_guard();

-- v1.15: a DDT's lines are its content: a login writes them only together with the DDT (same save) and never changes or deletes them
create or replace function fabula.trg_shipment_lines_guard() returns trigger
language plpgsql set search_path = fabula, public as $$
declare v_ddt text; v_new boolean; v_cancelled boolean;
begin
  if current_user not in ('authenticated', 'anon') then return case when tg_op = 'DELETE' then old else new end; end if;
  select ddt_number, created_at = now(), status::text = 'cancelled' into v_ddt, v_new, v_cancelled
    from fabula.shipments where id = case when tg_op = 'DELETE' then old.shipment_id else new.shipment_id end;
  if tg_op = 'INSERT' and coalesce(v_new, false) and not coalesce(v_cancelled, false) then return new; end if;
  raise exception using errcode = '42501', message = format('Le righe del DDT %s non si cambiano dopo l''emissione: se è sbagliato, annullalo (Console → Operazioni → Spedizioni e DDT) e preparalo di nuovo', coalesce(v_ddt, '?'));
end $$;
drop trigger if exists shipment_lines_guard on fabula.shipment_lines;
create trigger shipment_lines_guard before insert or update or delete on fabula.shipment_lines for each row execute function fabula.trg_shipment_lines_guard();

-- pack_order links its moves to the DDT
do $mig$
declare d text := pg_get_functiondef('fabula.pack_order(uuid,jsonb,uuid,numeric,text,text,text,boolean)'::regprocedure);
        a text := $a$    insert into fabula.stock_moves (product_id, lot_number, expiry_date, qty, move_type, sales_order_id, reason, source)
    values ((l->>'product_id')::uuid, l->>'lot_number', v_exp, -(l->>'qty')::numeric, 'sale', o.id, 'Spedizione ' || v_ddt || ' · ' || o.order_number, 'tablet');$a$;
        r text := $r$    insert into fabula.stock_moves (product_id, lot_number, expiry_date, qty, move_type, sales_order_id, reason, source, shipment_id)   -- v1.15: shipment_id
    values ((l->>'product_id')::uuid, l->>'lot_number', v_exp, -(l->>'qty')::numeric, 'sale', o.id, 'Spedizione ' || v_ddt || ' · ' || o.order_number, 'tablet', v_ship);$r$;
begin
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'v115a: pack_order stock move anchor not found exactly once'; end if;
  execute replace(d, a, r);
end $mig$;

-- ============================== «Annulla DDT» ==============================
create or replace function fabula.cancel_shipment(p_shipment_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare s fabula.shipments; o fabula.sales_orders; m record; v_reason text := nullif(regexp_replace(btrim(coalesce(p_reason, '')), '\s+', ' ', 'g'), '');
        v_sid uuid := fabula.my_staff_id(); v_who text; n int := 0; v_kg numeric := 0; v_back boolean := false; v_other boolean;
        v_today date := (now() at time zone 'Europe/Rome')::date; v_day date;
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
  -- the ingrosso and direct DDTs have no «partito» step: only a DDT packed today can still be in the cold room
  v_day := (coalesce(s.packed_at, s.created_at) at time zone 'Europe/Rome')::date;
  if v_day <> v_today then
    raise exception using errcode = '22023', message = format('Il DDT %s è del %s: si annulla solo il giorno in cui è stato preparato, prima che la merce parta. Se la merce è tornata indietro, è un reso.',
      s.ddt_number, to_char(v_day, 'DD/MM'));
  end if;
  v_who := coalesce((select full_name from fabula.staff where id = v_sid), case when auth.uid() is null then 'bot/service' else 'utente' end);
  if s.sales_order_id is not null then select * into o from fabula.sales_orders where id = s.sales_order_id for update; end if;

  -- back to stock exactly what the DDT took: its own «sale» moves, reversed with the same date (the day's sales net out)
  for m in select sm.product_id, sm.lot_number, sm.expiry_date, sm.moved_at, sum(sm.qty) as q
             from fabula.stock_moves sm where sm.shipment_id = s.id and sm.move_type = 'sale'
            group by 1, 2, 3, 4 having sum(sm.qty) < 0 loop
    insert into fabula.stock_moves (moved_at, product_id, lot_number, expiry_date, qty, move_type, sales_order_id, shipment_id, reason, source)
    values (m.moved_at, m.product_id, m.lot_number, m.expiry_date, -m.q, 'sale', s.sales_order_id, s.id,
            left(format('Annullato %s%s: %s', s.ddt_number, coalesce(' · ' || o.order_number, ''), v_reason), 300), 'ddt_annullato');
    n := n + 1; v_kg := v_kg - m.q;
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
          jsonb_build_object('summary', s.ddt_number, 'status', 'cancelled', 'cancel_reason', v_reason, 'order', o.order_number, 'moves_back', n, 'kg_back', v_kg),
          v_sid, v_who);

  return jsonb_build_object('ok', true, 'ddt_number', s.ddt_number, 'order_number', o.order_number, 'lines_back', n, 'kg_back', v_kg,
                            'order_to_ship', v_back, 'channel', o.channel::text);
end $$;
revoke all on function fabula.cancel_shipment(uuid, text) from public, anon;
grant execute on function fabula.cancel_shipment(uuid, text) to authenticated, service_role;
comment on function fabula.cancel_shipment(uuid, text) is 'v1.15 «Annulla DDT»: a DDT packed today whose goods have not left. Number kept as «annullato», its own sale moves reversed (same date), a wholesale order back to «confirmed». Spedizioni = gestisce; reason required; audit_log.';

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

-- ============================== «stock booked for this order» = the net of its sale moves ==============================
-- (an annulled DDT leaves the order's sale moves at 0: the order is reserved again, and deducted when Shopify fulfils it)
create or replace view fabula.v_shopify_inventory_push with (security_invoker = true) as
with avail as (
  select p_1.id as product_id,
         greatest(0::numeric,
           coalesce((select sum(s.qty_on_hand) from fabula.v_stock_on_hand s
                      where s.product_id = p_1.id and (s.expiry_date is null or s.expiry_date >= (now() at time zone 'Europe/Rome')::date)), 0)
         - coalesce((select sum(l.qty) from fabula.sales_order_lines l join fabula.sales_orders o on o.id = l.sales_order_id
                      where l.product_id = p_1.id and o.status = 'confirmed' and o.channel in ('shopify', 'wholesale')
                        and coalesce((select sum(m_1.qty) from fabula.stock_moves m_1 where m_1.sales_order_id = o.id and m_1.move_type = 'sale'), 0) >= 0), 0)   -- v1.15: net
         - case when p_1.sku = 'MOZ-DOP-KG' then fabula.setting_num('shopify.reserve_kg', 0) else 0 end) as available_kg
    from fabula.products p_1
   where p_1.kind = 'finished_good'
), sold as (                                   -- kg sold per variant in the last 28 days (web + POS)
  select l->>'variant_id' as variant_id, sum((l->>'quantity')::numeric * mm.kg_per_unit) as kg
    from fabula.sales_orders o
    cross join lateral jsonb_array_elements(coalesce(o.shopify_payload->'line_items', '[]'::jsonb)) l
    join fabula.shopify_variant_map mm on mm.variant_id = l->>'variant_id' and mm.kg_per_unit > 0
   where o.channel in ('shopify', 'store_pos') and o.status in ('confirmed', 'fulfilled')
     and o.order_date >= (now() at time zone 'Europe/Rome')::date - 28
   group by 1
), v as (
  select m.variant_id, m.label, p.sku, a.available_kg, m.kg_per_unit, coalesce(x.kg, 0) as sold_kg,
         count(*) over (partition by p.id) as n, sum(coalesce(x.kg, 0)) over (partition by p.id) as tot,
         least(1, greatest(0, fabula.setting_num('shopify.mix_weight', 0.8))) as w
    from fabula.shopify_variant_map m
    join fabula.products p on p.id = m.product_id
    join avail a on a.product_id = p.id
    left join sold x on x.variant_id = m.variant_id
   where m.kg_per_unit > 0
), s as (
  select v.*, case when tot > 0 then w * sold_kg / tot + (1 - w) / n else 1.0 / n end as share from v
)
select variant_id, label, sku, available_kg, kg_per_unit,
       floor(available_kg * share / kg_per_unit)::integer as available_units,
       round(share * 100, 1) as share_pct,
       round(available_kg * share, 3) as allocated_kg,
       round(sold_kg, 3) as sold_kg_28d,
       case when tot > 0 then 'vendite_28gg' else 'parti_uguali' end as split_basis
  from s
 order by label;

create or replace view fabula.v_shopify_orders_recent with (security_invoker = true) as
  select o.order_number, o.order_date, o.status::text as status, o.total_eur, o.ship_city, p.legal_name as customer,
         (select string_agg(trim_scale(l.qty) || ' kg ' || pr.name, ', ') from fabula.sales_order_lines l join fabula.products pr on pr.id = l.product_id where l.sales_order_id = o.id and l.qty > 0) as lines_txt,
         (select count(*) from fabula.shopify_unmapped_lines u where u.sales_order_id = o.id) as unmapped,
         coalesce((select sum(m.qty) from fabula.stock_moves m where m.sales_order_id = o.id and m.move_type = 'sale'), 0) < 0 as stock_booked   -- v1.15: net
  from fabula.sales_orders o left join fabula.parties p on p.id = o.customer_id
  where o.channel = 'shopify' and o.order_date >= (now() at time zone 'Europe/Rome')::date - 14
  order by o.order_date desc, o.order_number desc;

do $mig$
declare d text; a text; r text;
begin
  -- the Shopify order sync deducts stock for an order fulfilled on Shopify when none is booked (net), not when no move exists
  d := pg_get_functiondef('fabula.upsert_shopify_orders(jsonb)'::regprocedure);
  a := $a$not exists (select 1 from fabula.stock_moves where sales_order_id = v_id and move_type = 'sale')$a$;
  r := $r$coalesce((select sum(qty) from fabula.stock_moves where sales_order_id = v_id and move_type = 'sale'), 0) >= 0$r$;
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 2 then raise exception 'v115a: upsert_shopify_orders anchors not found exactly twice'; end if;
  execute replace(d, a, r);

  -- «sold on a held lot»: a reversal (positive) is not a sale
  d := pg_get_functiondef('fabula.ops_health_check(date)'::regprocedure);
  a := $a$where sm.move_type = 'sale' and sm.moved_at > greatest(coalesce(b.hold_at, now()), now() - interval '7 days')$a$;
  r := $r$where sm.move_type = 'sale' and sm.qty < 0 and sm.moved_at > greatest(coalesce(b.hold_at, now()), now() - interval '7 days')$r$;
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'v115a: ops_health_check held-lot anchor not found exactly once'; end if;
  execute replace(d, a, r);

  -- placeholder orders: an annulled DDT does not keep the order alive
  d := pg_get_functiondef('fabula.cancel_placeholder_orders()'::regprocedure);
  a := $a$and not exists (select 1 from fabula.shipments sh where sh.sales_order_id = o.id)$a$;
  r := $r$and not exists (select 1 from fabula.shipments sh where sh.sales_order_id = o.id and sh.status::text <> 'cancelled')$r$;
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'v115a: cancel_placeholder_orders anchor not found exactly once'; end if;
  execute replace(d, a, r);

  -- recall drill: a lot counts as sold when its sales are net negative (an annulled DDT gave it all back)
  d := pg_get_functiondef('fabula.recall_drill(text)'::regprocedure);
  a := $a$exists (select 1 from fabula.stock_moves sm where sm.lot_number = pb.batch_lot and sm.move_type = 'sale')$a$;
  r := $r$coalesce((select sum(sm.qty) from fabula.stock_moves sm where sm.lot_number = pb.batch_lot and sm.move_type = 'sale'), 0) < 0$r$;
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'v115a: recall_drill anchor not found exactly once'; end if;
  execute replace(d, a, r);
end $mig$;

insert into fabula.security_accepted (key, reason) values
  ('authenticated_security_definer_function_executable:fabula.cancel_shipment(p_shipment_id uuid, p_reason text)',
   'by design (v1.15): «Annulla DDT» for goods that have not left; Spedizioni = gestisce, reason required, written to audit_log')
on conflict (key) do nothing;
