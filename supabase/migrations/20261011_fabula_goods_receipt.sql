-- =============================================================================
-- v0.11: goods receipt — an approved purchase order arrives, stock goes UP.
--   Tablet: "Arrivo merce" lists open POs (or scan PO:<number>) → one line per
--   item: qty received, supplier lot, expiry, unit price if the DDT differs.
--   fabula.receive_purchase_order(po_number, lines jsonb, staff, ddt, notes)
--     → goods_receipts + lines, stock_moves (+qty, purchase_receipt, lot, expiry,
--       unit cost), purchase_order_lines.qty_received, PO status
--       partially_received / received, supplier_prices row when the DDT price differs.
--   Procurement bot now treats partially_received POs as still open.
-- Written without destructive keywords (connector rule).
-- =============================================================================
set search_path = fabula, public;

alter type fabula.scan_action add value if not exists 'goods_receive';

create table if not exists fabula.goods_receipts (
  id                 uuid primary key default gen_random_uuid(),
  purchase_order_id  uuid not null references fabula.purchase_orders(id),
  received_at        timestamptz not null default now(),
  ddt_number         text,
  received_by_id     uuid references fabula.staff(id),
  notes              text,
  source             text not null default 'tablet'
);
create table if not exists fabula.goods_receipt_lines (
  id                 uuid primary key default gen_random_uuid(),
  receipt_id         uuid not null references fabula.goods_receipts(id),
  po_line_id         uuid references fabula.purchase_order_lines(id),
  product_id         uuid not null references fabula.products(id),
  qty_received       numeric(10,3) not null check (qty_received > 0),
  supplier_lot       text,
  expiry_date        date,
  unit_price_eur     numeric(12,4),
  stock_move_id      uuid references fabula.stock_moves(id)
);
create index if not exists goods_receipts_po_idx on fabula.goods_receipts (purchase_order_id);
grant all on fabula.goods_receipts, fabula.goods_receipt_lines to authenticated, service_role;
alter table fabula.goods_receipts enable row level security;
alter table fabula.goods_receipt_lines enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='fabula' and tablename='goods_receipts' and policyname='goods_receipts_authenticated_all') then
    create policy goods_receipts_authenticated_all on fabula.goods_receipts for all to authenticated using (true) with check (true);
  end if;
  if not exists (select 1 from pg_policies where schemaname='fabula' and tablename='goods_receipt_lines' and policyname='goods_receipt_lines_authenticated_all') then
    create policy goods_receipt_lines_authenticated_all on fabula.goods_receipt_lines for all to authenticated using (true) with check (true);
  end if;
end $$;

-- What the tablet lists under "Arrivo merce"
create or replace view fabula.v_open_purchase_orders as
select po.id, po.po_number, po.status, po.order_date, po.expected_date, sp.legal_name as supplier, po.subtotal_eur,
       jsonb_agg(jsonb_build_object('line_id', l.id, 'sku', p.sku, 'name', p.name, 'unit', p.unit,
                                    'qty_ordered', l.qty_ordered, 'qty_received', l.qty_received,
                                    'remaining', greatest(0, l.qty_ordered - l.qty_received), 'unit_price_eur', l.unit_price_eur,
                                    'shelf_life_days', p.shelf_life_days) order by p.name) as lines
from fabula.purchase_orders po
join fabula.parties sp on sp.id = po.supplier_id
join fabula.purchase_order_lines l on l.purchase_order_id = po.id
join fabula.products p on p.id = l.product_id
where po.status in ('approved','sent','partially_received')
group by po.id, sp.legal_name
order by po.expected_date nulls last, po.order_date;
grant select on fabula.v_open_purchase_orders to authenticated, service_role;

-- lines: [{"sku":"CON-SALT","qty":100,"lot":"S2026-41","expiry":"2028-01-01","unit_price":0.41}, …]
create or replace function fabula.receive_purchase_order(p_po_number text, p_lines jsonb, p_staff_id uuid default null, p_ddt text default null, p_notes text default null)
returns jsonb language plpgsql as $$
declare po record; l jsonb; pl record; v_rcpt uuid; v_move uuid; v_price numeric; v_list numeric; v_qty numeric;
        n int := 0; over jsonb := '[]'; price_changes jsonb := '[]'; v_status fabula.po_status; v_received numeric := 0;
begin
  select * into po from fabula.purchase_orders where po_number = p_po_number;
  if po is null then raise exception 'Ordine sconosciuto: %', p_po_number; end if;
  if po.status not in ('approved','sent','partially_received') then raise exception 'Ordine % in stato %: non ricevibile', p_po_number, po.status; end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Nessuna riga ricevuta'; end if;

  insert into fabula.goods_receipts (purchase_order_id, ddt_number, received_by_id, notes) values (po.id, p_ddt, p_staff_id, p_notes) returning id into v_rcpt;

  for l in select * from jsonb_array_elements(p_lines) loop
    v_qty := (l->>'qty')::numeric;
    continue when v_qty is null or v_qty <= 0;
    select pol.*, p.sku, p.unit into pl from fabula.purchase_order_lines pol join fabula.products p on p.id = pol.product_id
     where pol.purchase_order_id = po.id and p.sku = l->>'sku' limit 1;
    if pl is null then raise exception 'Riga % non presente nell''ordine %', l->>'sku', p_po_number; end if;

    v_price := coalesce(nullif(l->>'unit_price','')::numeric, pl.unit_price_eur);
    insert into fabula.stock_moves (product_id, lot_number, expiry_date, qty, move_type, purchase_order_id, unit_cost_eur, source, reason)
    values (pl.product_id, nullif(l->>'lot',''), nullif(l->>'expiry','')::date, v_qty, 'purchase_receipt', po.id, v_price, 'tablet',
            format('Ricevuto %s %s su ordine %s%s', v_qty, pl.unit, p_po_number, case when p_ddt is not null then ' · DDT ' || p_ddt else '' end))
    returning id into v_move;
    insert into fabula.goods_receipt_lines (receipt_id, po_line_id, product_id, qty_received, supplier_lot, expiry_date, unit_price_eur, stock_move_id)
    values (v_rcpt, pl.id, pl.product_id, v_qty, nullif(l->>'lot',''), nullif(l->>'expiry','')::date, v_price, v_move);
    update fabula.purchase_order_lines set qty_received = qty_received + v_qty where id = pl.id;

    if pl.qty_received + v_qty > pl.qty_ordered * 1.02 then
      over := over || jsonb_build_object('sku', pl.sku, 'ordered', pl.qty_ordered, 'received_total', pl.qty_received + v_qty);
    end if;
    -- DDT price differs from the latest list price → record it so procurement uses the real one
    if nullif(l->>'unit_price','') is not null then
      select price_eur into v_list from fabula.supplier_prices where supplier_id = po.supplier_id and product_id = pl.product_id order by valid_from desc limit 1;
      if v_list is distinct from v_price then
        insert into fabula.supplier_prices (supplier_id, product_id, price_eur, valid_from, source) values (po.supplier_id, pl.product_id, v_price, current_date, 'ddt');
        price_changes := price_changes || jsonb_build_object('sku', pl.sku, 'from', v_list, 'to', v_price);
      end if;
    end if;
    n := n + 1; v_received := v_received + v_qty * v_price;
  end loop;
  if n = 0 then raise exception 'Nessuna quantità ricevuta'; end if;

  select case when bool_and(qty_received >= qty_ordered) then 'received'::fabula.po_status else 'partially_received'::fabula.po_status end
    into v_status from fabula.purchase_order_lines where purchase_order_id = po.id;
  update fabula.purchase_orders set status = v_status where id = po.id;

  return jsonb_build_object('receipt_id', v_rcpt, 'po_number', p_po_number, 'lines', n, 'value_eur', round(v_received, 2),
                            'po_status', v_status, 'over_delivered', over, 'price_changes', price_changes);
end $$;
grant execute on function fabula.receive_purchase_order(text, jsonb, uuid, text, text) to authenticated, service_role;

-- Procurement: a partially received PO is still open
create or replace function fabula.propose_purchase_orders(p_date date default (now() at time zone 'Europe/Rome')::date)
returns jsonb language plpgsql as $$
declare
  sig record; v_po uuid; v_price numeric; v_total numeric; v_n int := 0; v_seq int;
  created jsonb := '[]'::jsonb; skipped jsonb := '[]'::jsonb; v_po_number text;
begin
  for sig in
    with s as (
      select product_id, sku, name, sum(qty_on_hand) qty_on_hand, max(reorder_point) reorder_point
      from fabula.v_stock_on_hand where kind in ('consumable','packaging') group by product_id, sku, name),
    u as (
      select product_id, round(coalesce(-sum(qty),0) / 14.0, 3) daily_use
      from fabula.stock_moves where qty < 0 and moved_at::date between p_date-13 and p_date group by product_id)
    select s.*, p.reorder_qty, p.unit, p.iva_rate, p.preferred_supplier_id, sp.legal_name as supplier, sp.email as supplier_email,
           coalesce(u.daily_use,0) daily_use,
           case when coalesce(u.daily_use,0) > 0 then round(s.qty_on_hand / u.daily_use, 1) end days_cover
    from s join fabula.products p on p.id = s.product_id
    left join fabula.parties sp on sp.id = p.preferred_supplier_id
    left join u on u.product_id = s.product_id
    where s.reorder_point is not null
      and (s.qty_on_hand <= s.reorder_point or (coalesce(u.daily_use,0) > 0 and s.qty_on_hand / u.daily_use < 10))
  loop
    if exists (select 1 from fabula.purchase_order_lines l join fabula.purchase_orders po on po.id = l.purchase_order_id
               where l.product_id = sig.product_id and po.status in ('draft','pending_approval','approved','sent','partially_received')) then
      skipped := skipped || jsonb_build_object('sku', sig.sku, 'reason', 'open_po_exists'); continue;
    end if;
    if sig.preferred_supplier_id is null then
      skipped := skipped || jsonb_build_object('sku', sig.sku, 'reason', 'no_preferred_supplier', 'on_hand', sig.qty_on_hand, 'days_cover', sig.days_cover); continue;
    end if;
    select price_eur into v_price from fabula.supplier_prices
      where supplier_id = sig.preferred_supplier_id and product_id = sig.product_id and valid_from <= p_date
      order by valid_from desc limit 1;
    v_price := coalesce(v_price, 0);
    v_total := round(coalesce(sig.reorder_qty, sig.reorder_point * 2) * v_price, 2);

    select count(*) + 1 into v_seq from fabula.purchase_orders where order_date = p_date;
    v_po_number := 'PO-' || to_char(p_date, 'YYYYMMDD') || '-' || lpad(v_seq::text, 2, '0');

    insert into fabula.purchase_orders (po_number, supplier_id, status, order_date, expected_date, subtotal_eur, iva_eur, total_eur, drafted_by, rationale, source)
    values (v_po_number, sig.preferred_supplier_id, 'pending_approval', p_date, p_date + 5, v_total, round(v_total * coalesce(sig.iva_rate,22) / 100, 2),
            round(v_total * (1 + coalesce(sig.iva_rate,22) / 100), 2), 'agent',
            format('%s: giacenza %s %s, consumo %s %s/giorno, copertura %s giorni (soglia %s). Prezzo %s da listino fornitore.',
                   sig.name, sig.qty_on_hand, sig.unit, sig.daily_use, sig.unit, coalesce(sig.days_cover::text,'n/d'), sig.reorder_point,
                   case when v_price = 0 then 'NON DISPONIBILE' else v_price::text end),
            'agent:procurement')
    returning id into v_po;
    insert into fabula.purchase_order_lines (purchase_order_id, product_id, qty_ordered, unit_price_eur, iva_rate)
    values (v_po, sig.product_id, coalesce(sig.reorder_qty, sig.reorder_point * 2), v_price, coalesce(sig.iva_rate,22));

    insert into fabula.approvals (kind, requested_by, summary, payload, related_table, related_id, amount_eur, expires_at)
    values ('purchase_order', 'agent:procurement',
            format('Ordine %s: %s × %s %s a %s — copertura %s giorni%s', v_po_number, coalesce(sig.reorder_qty, sig.reorder_point*2), sig.unit, sig.name, sig.supplier,
                   coalesce(sig.days_cover::text,'n/d'), case when v_price = 0 then ' · PREZZO MANCANTE' else '' end),
            jsonb_build_object('po_number', v_po_number, 'supplier', sig.supplier, 'supplier_email', sig.supplier_email, 'sku', sig.sku,
                               'qty', coalesce(sig.reorder_qty, sig.reorder_point*2), 'unit', sig.unit, 'unit_price_eur', v_price, 'total_eur', v_total,
                               'on_hand', sig.qty_on_hand, 'daily_use', sig.daily_use, 'days_cover', sig.days_cover),
            'purchase_orders', v_po, v_total, p_date + 7);
    v_n := v_n + 1;
    created := created || jsonb_build_object('po_number', v_po_number, 'sku', sig.sku, 'name', sig.name, 'qty', coalesce(sig.reorder_qty, sig.reorder_point*2), 'unit', sig.unit,
                                             'supplier', sig.supplier, 'total_eur', v_total, 'days_cover', sig.days_cover, 'price_missing', v_price = 0);
  end loop;
  return jsonb_build_object('date', p_date, 'created', created, 'skipped', skipped, 'count', v_n);
end $$;
