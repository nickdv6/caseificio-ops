-- v0.32 · Supplier terms per supplier–product + price history from goods receipts.
-- supplier_products: lead_time_days, min_order_qty, order_multiple, supplier_sku, payment_terms, notes (one row per supplier × product).
-- v_supplier_price_history: every price point — list prices (supplier_prices) and actual DDT prices from goods receipts — with change vs the previous point.
-- v_supplier_terms: per supplier × product — terms, current list price, last receipt price/date, 90-day avg paid, change vs 90 days ago, receipts count.
-- propose_purchase_orders(): uses lead time (expected_date, cover threshold = max(10, lead + purchasing.cover_buffer_days)),
-- rounds the quantity up to min order and order multiple, falls back to the last receipt price when no list price exists.

create table if not exists fabula.supplier_products (
  supplier_id     uuid not null references fabula.parties(id),
  product_id      uuid not null references fabula.products(id),
  lead_time_days  int check (lead_time_days is null or lead_time_days between 0 and 120),
  min_order_qty   numeric check (min_order_qty is null or min_order_qty >= 0),
  order_multiple  numeric check (order_multiple is null or order_multiple > 0),
  supplier_sku    text,
  payment_terms   text,
  notes           text,
  active          boolean not null default true,
  updated_at      timestamptz not null default now(),
  primary key (supplier_id, product_id));
alter table fabula.supplier_products enable row level security;
do $$ begin if not exists (select 1 from pg_policies where schemaname = 'fabula' and tablename = 'supplier_products' and policyname = 'supplier_products_authenticated_all') then
  create policy supplier_products_authenticated_all on fabula.supplier_products for all to authenticated using (true) with check (true); end if; end $$;
grant all on fabula.supplier_products to authenticated, service_role;

-- seed one row per known supplier × product pair (preferred supplier or any list price), terms left empty
insert into fabula.supplier_products (supplier_id, product_id)
select distinct supplier_id, product_id from (
  select preferred_supplier_id supplier_id, id product_id from fabula.products where preferred_supplier_id is not null
  union select supplier_id, product_id from fabula.supplier_prices) x
on conflict do nothing;

insert into fabula.settings (key, value, description, data_type)
select 'purchasing.default_lead_days', '5', 'Giorni di consegna se il fornitore non ha un tempo impostato', 'number'
where not exists (select 1 from fabula.settings where key = 'purchasing.default_lead_days');
insert into fabula.settings (key, value, description, data_type)
select 'purchasing.cover_buffer_days', '5', 'Giorni di scorta oltre il tempo di consegna prima di proporre un ordine', 'number'
where not exists (select 1 from fabula.settings where key = 'purchasing.cover_buffer_days');

create or replace view fabula.v_supplier_price_history with (security_invoker = true) as
with pts as (
  select sp.supplier_id, sp.product_id, sp.valid_from as price_date, sp.price_eur, 'listino'::text as source, null::text as ref, null::numeric as qty
  from fabula.supplier_prices sp
  union all
  select po.supplier_id, grl.product_id, (gr.received_at at time zone 'Europe/Rome')::date, grl.unit_price_eur, 'DDT', coalesce(gr.ddt_number, po.po_number), grl.qty_received
  from fabula.goods_receipt_lines grl join fabula.goods_receipts gr on gr.id = grl.receipt_id
  join fabula.purchase_orders po on po.id = gr.purchase_order_id
  where grl.unit_price_eur is not null)
select p.supplier_id, s.legal_name as supplier, p.product_id, pr.sku, pr.name as product, pr.unit, p.price_date, p.source, p.ref, p.qty, p.price_eur,
       lag(p.price_eur) over w as prev_price_eur,
       case when lag(p.price_eur) over w > 0 then round((p.price_eur / lag(p.price_eur) over w - 1) * 100, 1) end as change_pct
from pts p join fabula.parties s on s.id = p.supplier_id join fabula.products pr on pr.id = p.product_id
window w as (partition by p.supplier_id, p.product_id order by p.price_date, p.source desc);
grant select on fabula.v_supplier_price_history to authenticated, service_role;

create or replace view fabula.v_supplier_terms with (security_invoker = true) as
select t.supplier_id, s.legal_name as supplier, t.product_id, pr.sku, pr.name as product, pr.unit,
       t.lead_time_days, t.min_order_qty, t.order_multiple, t.supplier_sku, t.payment_terms, t.notes, t.active,
       (pr.preferred_supplier_id = t.supplier_id) as preferred,
       lp.price_eur as list_price_eur, lp.valid_from as list_price_from,
       lr.price_eur as last_paid_eur, lr.price_date as last_paid_on,
       (select round(sum(h.qty * h.price_eur) / nullif(sum(h.qty), 0), 4) from fabula.v_supplier_price_history h
         where h.supplier_id = t.supplier_id and h.product_id = t.product_id and h.source = 'DDT' and h.price_date >= current_date - 90) as avg_paid_90d_eur,
       (select h.price_eur from fabula.v_supplier_price_history h where h.supplier_id = t.supplier_id and h.product_id = t.product_id
         and h.price_date <= current_date - 90 order by h.price_date desc limit 1) as price_90d_ago_eur,
       (select count(*) from fabula.v_supplier_price_history h where h.supplier_id = t.supplier_id and h.product_id = t.product_id and h.source = 'DDT') as receipts
from fabula.supplier_products t
join fabula.parties s on s.id = t.supplier_id join fabula.products pr on pr.id = t.product_id
left join lateral (select price_eur, valid_from from fabula.supplier_prices x where x.supplier_id = t.supplier_id and x.product_id = t.product_id and x.valid_from <= current_date order by valid_from desc limit 1) lp on true
left join lateral (select price_eur, price_date from fabula.v_supplier_price_history h where h.supplier_id = t.supplier_id and h.product_id = t.product_id and h.source = 'DDT' order by price_date desc limit 1) lr on true;
grant select on fabula.v_supplier_terms to authenticated, service_role;

create or replace function fabula.propose_purchase_orders(p_date date default ((now() at time zone 'Europe/Rome'))::date)
returns jsonb language plpgsql as $function$
declare
  sig record; v_po uuid; v_price numeric; v_price_src text; v_total numeric; v_n int := 0; v_seq int; v_qty numeric; v_base numeric; v_adj text;
  created jsonb := '[]'::jsonb; skipped jsonb := '[]'::jsonb; v_po_number text;
  v_def_lead int := fabula.setting_num('purchasing.default_lead_days', 5)::int; v_buf int := fabula.setting_num('purchasing.cover_buffer_days', 5)::int;
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
           case when coalesce(u.daily_use,0) > 0 then round(s.qty_on_hand / u.daily_use, 1) end days_cover,
           t.lead_time_days, t.min_order_qty, t.order_multiple,
           coalesce(t.lead_time_days, v_def_lead) lead
    from s join fabula.products p on p.id = s.product_id
    left join fabula.parties sp on sp.id = p.preferred_supplier_id
    left join fabula.supplier_products t on t.supplier_id = p.preferred_supplier_id and t.product_id = p.id and t.active
    left join u on u.product_id = s.product_id
    where s.reorder_point is not null
      and (s.qty_on_hand <= s.reorder_point
           or (coalesce(u.daily_use,0) > 0 and s.qty_on_hand / u.daily_use < greatest(10, coalesce(t.lead_time_days, v_def_lead) + v_buf)))
  loop
    if exists (select 1 from fabula.purchase_order_lines l join fabula.purchase_orders po on po.id = l.purchase_order_id
               where l.product_id = sig.product_id and po.status in ('draft','pending_approval','approved','sent','partially_received')) then
      skipped := skipped || jsonb_build_object('sku', sig.sku, 'reason', 'open_po_exists'); continue;
    end if;
    if sig.preferred_supplier_id is null then
      skipped := skipped || jsonb_build_object('sku', sig.sku, 'reason', 'no_preferred_supplier', 'on_hand', sig.qty_on_hand, 'days_cover', sig.days_cover); continue;
    end if;
    v_price := null; v_price_src := 'listino';
    select price_eur into v_price from fabula.supplier_prices
      where supplier_id = sig.preferred_supplier_id and product_id = sig.product_id and valid_from <= p_date order by valid_from desc limit 1;
    if v_price is null then
      select price_eur into v_price from fabula.v_supplier_price_history
        where supplier_id = sig.preferred_supplier_id and product_id = sig.product_id and source = 'DDT' order by price_date desc limit 1;
      v_price_src := case when v_price is not null then 'ultimo DDT' end;
    end if;
    v_price := coalesce(v_price, 0);
    v_base := coalesce(sig.reorder_qty, sig.reorder_point * 2); v_qty := v_base; v_adj := '';
    if sig.min_order_qty is not null and v_qty < sig.min_order_qty then v_qty := sig.min_order_qty; v_adj := format(' Portato al minimo d''ordine %s.', trim_scale(sig.min_order_qty)); end if;
    if sig.order_multiple is not null and mod(v_qty, sig.order_multiple) <> 0 then
      v_qty := ceil(v_qty / sig.order_multiple) * sig.order_multiple; v_adj := v_adj || format(' Arrotondato a multipli di %s.', trim_scale(sig.order_multiple)); end if;
    v_total := round(v_qty * v_price, 2);

    select count(*) + 1 into v_seq from fabula.purchase_orders where order_date = p_date;
    v_po_number := 'PO-' || to_char(p_date, 'YYYYMMDD') || '-' || lpad(v_seq::text, 2, '0');

    insert into fabula.purchase_orders (po_number, supplier_id, status, order_date, expected_date, subtotal_eur, iva_eur, total_eur, drafted_by, rationale, source)
    values (v_po_number, sig.preferred_supplier_id, 'pending_approval', p_date, p_date + sig.lead, v_total, round(v_total * coalesce(sig.iva_rate,22) / 100, 2),
            round(v_total * (1 + coalesce(sig.iva_rate,22) / 100), 2), 'agent',
            format('%s: giacenza %s %s, consumo %s %s/giorno, copertura %s giorni (soglia %s; consegna in %s giorni%s). Prezzo %s.%s',
                   sig.name, sig.qty_on_hand, sig.unit, sig.daily_use, sig.unit, coalesce(sig.days_cover::text,'n/d'), sig.reorder_point,
                   sig.lead, case when sig.lead_time_days is null then ', valore predefinito' else '' end,
                   case when v_price = 0 then 'NON DISPONIBILE' else format('%s (%s)', v_price, v_price_src) end, v_adj),
            'agent:procurement')
    returning id into v_po;
    insert into fabula.purchase_order_lines (purchase_order_id, product_id, qty_ordered, unit_price_eur, iva_rate)
    values (v_po, sig.product_id, v_qty, v_price, coalesce(sig.iva_rate,22));

    insert into fabula.approvals (kind, requested_by, summary, payload, related_table, related_id, amount_eur, expires_at)
    values ('purchase_order', 'agent:procurement',
            format('Ordine %s: %s × %s %s a %s — copertura %s giorni, consegna in %s gg%s', v_po_number, trim_scale(v_qty), sig.unit, sig.name, sig.supplier,
                   coalesce(sig.days_cover::text,'n/d'), sig.lead, case when v_price = 0 then ' · PREZZO MANCANTE' else '' end),
            jsonb_build_object('po_number', v_po_number, 'supplier', sig.supplier, 'supplier_email', sig.supplier_email, 'sku', sig.sku,
                               'qty', v_qty, 'qty_before_terms', v_base, 'unit', sig.unit, 'unit_price_eur', v_price, 'price_source', v_price_src, 'total_eur', v_total,
                               'on_hand', sig.qty_on_hand, 'daily_use', sig.daily_use, 'days_cover', sig.days_cover, 'lead_time_days', sig.lead,
                               'min_order_qty', sig.min_order_qty, 'order_multiple', sig.order_multiple, 'expected_date', p_date + sig.lead),
            'purchase_orders', v_po, v_total, p_date + 7);
    v_n := v_n + 1;
    created := created || jsonb_build_object('po_number', v_po_number, 'sku', sig.sku, 'name', sig.name, 'qty', v_qty, 'unit', sig.unit,
                                             'supplier', sig.supplier, 'total_eur', v_total, 'days_cover', sig.days_cover, 'lead_time_days', sig.lead,
                                             'expected_date', p_date + sig.lead, 'price_missing', v_price = 0, 'adjusted', v_adj <> '');
  end loop;
  return jsonb_build_object('date', p_date, 'created', created, 'skipped', skipped, 'count', v_n);
end $function$;

-- new pairs: whenever a list price or a preferred supplier appears, make sure a terms row exists
create or replace function fabula._ensure_supplier_product() returns trigger language plpgsql security definer set search_path = fabula, public as $$
begin
  if tg_table_name = 'supplier_prices' then
    insert into fabula.supplier_products (supplier_id, product_id) values (new.supplier_id, new.product_id) on conflict do nothing;
  elsif new.preferred_supplier_id is not null then
    insert into fabula.supplier_products (supplier_id, product_id) values (new.preferred_supplier_id, new.id) on conflict do nothing;
  end if;
  return new;
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'supplier_prices_ensure_terms') then
    create trigger supplier_prices_ensure_terms after insert on fabula.supplier_prices for each row execute function fabula._ensure_supplier_product(); end if;
  if not exists (select 1 from pg_trigger where tgname = 'products_ensure_terms') then
    create trigger products_ensure_terms after insert or update of preferred_supplier_id on fabula.products for each row execute function fabula._ensure_supplier_product(); end if;
end $$;
