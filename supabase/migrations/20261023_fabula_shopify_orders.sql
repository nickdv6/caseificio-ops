-- =============================================================================
-- Fabula v0.23 — Shopify orders → sales_orders (channel shopify)
--   * shopify_variant_map: Shopify variant id → fabula product + kg per unit.
--     Mozzarella-type variants are auto-mapped from the weight in the variant
--     title ("500g", "1 kg", "250 / 500g" → last number); subscriptions, B2B
--     "Fornitura" bundles and olive oil stay unmapped until mapped in the console.
--   * upsert_shopify_orders(jsonb): upserts orders + lines by Shopify order id,
--     links the customer by shopify_customer_id, maps status
--     (paid → confirmed, fulfilled → fulfilled, cancelled / refunded), keeps the
--     raw payload. When an order becomes fulfilled it books 'sale' stock moves
--     FEFO from the lots on hand (source shopify) exactly once, so stock, waste
--     risk and traceability see online sales without a tablet scan.
--   * shopify_unmapped_lines: lines whose variant has no map; the bot reports
--     them, the console maps them, next sync re-reads the order.
-- Written without destructive keywords (connector rule).
-- =============================================================================
set search_path = fabula, public;

alter table fabula.sales_orders add column if not exists shopify_payload jsonb;
alter table fabula.sales_orders add column if not exists shopify_updated_at timestamptz;
alter table fabula.sales_orders add column if not exists ship_city text;
create unique index if not exists sales_orders_shopify_order_id_uq on fabula.sales_orders (shopify_order_id) where shopify_order_id is not null;

create table if not exists fabula.shopify_variant_map (
  variant_id   text primary key,                      -- gid://shopify/ProductVariant/…
  product_id   uuid references fabula.products(id),   -- null = not sold from stock (subscription, service)
  kg_per_unit  numeric(10,3),                         -- finished-good kg per Shopify unit
  label        text,                                  -- "La Perla Classica · 500g"
  product_type text,
  auto_mapped  boolean not null default false,
  updated_at   timestamptz not null default now()
);
grant all on fabula.shopify_variant_map to authenticated, service_role;
alter table fabula.shopify_variant_map enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='fabula' and tablename='shopify_variant_map' and policyname='shopify_variant_map_authenticated_all') then
    create policy shopify_variant_map_authenticated_all on fabula.shopify_variant_map for all to authenticated using (true) with check (true);
  end if;
end $$;

create table if not exists fabula.shopify_unmapped_lines (
  id uuid primary key default gen_random_uuid(),
  sales_order_id uuid references fabula.sales_orders(id),
  variant_id text, title text, variant_title text, qty numeric, unit_price_eur numeric, seen_at timestamptz not null default now(),
  unique (sales_order_id, variant_id, title)
);
grant all on fabula.shopify_unmapped_lines to authenticated, service_role;
alter table fabula.shopify_unmapped_lines enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='fabula' and tablename='shopify_unmapped_lines' and policyname='shopify_unmapped_authenticated_all') then
    create policy shopify_unmapped_authenticated_all on fabula.shopify_unmapped_lines for all to authenticated using (true) with check (true);
  end if;
end $$;

-- weight parser: "500g" → 0.5, "1 kg" → 1, "250 / 800g" → 0.8, "Default Title" → null
create or replace function fabula.shopify_title_kg(p text) returns numeric language sql immutable as $$
  select case
    when p ~* '(\d+[.,]?\d*)\s*kg\s*$' then replace((regexp_match(p, '(\d+[.,]?\d*)\s*kg\s*$', 'i'))[1], ',', '.')::numeric
    when p ~* '(\d+)\s*g\s*$'          then (regexp_match(p, '(\d+)\s*g\s*$', 'i'))[1]::numeric / 1000
    else null end
$$;

create or replace function fabula.upsert_shopify_orders(p_rows jsonb)
returns jsonb language plpgsql as $$
declare r jsonb; l jsonb; v_id uuid; v_cust uuid; v_status fabula.order_status; n_new int := 0; n_upd int := 0; n_moves int := 0; n_unm int := 0;
        v_map fabula.shopify_variant_map%rowtype; v_kg numeric; v_prod uuid; v_subtotal numeric; v_tax numeric; v_total numeric; v_date date; fin text; ful text;
        v_qty numeric; v_left numeric; lot record; v_line_kg numeric; v_price_kg numeric; v_iva numeric; first_lot text; v_moz uuid; agg jsonb; k text;
begin
  select id into v_moz from fabula.products where sku = 'MOZ-DOP-KG';
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    fin := upper(coalesce(r->>'financial_status', '')); ful := upper(coalesce(r->>'fulfillment_status', ''));
    v_status := case when nullif(r->>'cancelled_at', '') is not null then 'cancelled'
                     when fin in ('REFUNDED') then 'refunded'
                     when ful = 'FULFILLED' then 'fulfilled'
                     when fin in ('PAID','PARTIALLY_REFUNDED','PARTIALLY_PAID') then 'confirmed'
                     else 'draft' end;
    v_date := ((r->>'created_at')::timestamptz at time zone 'Europe/Rome')::date;
    select id into v_cust from fabula.parties where shopify_customer_id = r->>'customer_id';
    v_subtotal := coalesce((r->>'subtotal')::numeric, 0); v_tax := coalesce((r->>'tax')::numeric, 0); v_total := coalesce((r->>'total')::numeric, 0);
    select id into v_id from fabula.sales_orders where shopify_order_id = r->>'id';
    if v_id is null then
      insert into fabula.sales_orders (order_number, channel, order_date, customer_id, status, subtotal_eur, iva_eur, total_eur, payment_method, shopify_order_id, notes, source, shopify_payload, shopify_updated_at, ship_city)
      values (coalesce(r->>'name', 'SHOP-' || (r->>'id')), 'shopify', v_date, v_cust, v_status, v_subtotal, v_tax, v_total, 'shopify', r->>'id',
              nullif(concat_ws(' · ', nullif(r->>'tags', ''), nullif(r->>'email', '')), ''), 'shopify', r, (r->>'updated_at')::timestamptz, r->>'ship_city')
      returning id into v_id; n_new := n_new + 1;
    else
      update fabula.sales_orders set status = v_status, customer_id = coalesce(v_cust, customer_id), subtotal_eur = v_subtotal, iva_eur = v_tax, total_eur = v_total,
             shopify_payload = r, shopify_updated_at = (r->>'updated_at')::timestamptz, ship_city = coalesce(r->>'ship_city', ship_city), updated_at = now()
       where id = v_id; n_upd := n_upd + 1;
    end if;
    -- lines: aggregated per fabula product (several Shopify variants map to the same cheese); refreshed while no stock is booked,
    -- updated in place by product (a line can never be removed here: qty must stay > 0 and the connector forbids removals)
    if not exists (select 1 from fabula.stock_moves where sales_order_id = v_id and move_type = 'sale') then
      agg := '{}'::jsonb;
      for l in select * from jsonb_array_elements(coalesce(r->'line_items', '[]'::jsonb)) loop
        select * into v_map from fabula.shopify_variant_map where variant_id = l->>'variant_id';
        if v_map.variant_id is null then
          -- auto-map mozzarella-type variants by weight in the title
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
    -- fulfilled → book the stock once, oldest expiry first
    if v_status = 'fulfilled' and not exists (select 1 from fabula.stock_moves where sales_order_id = v_id and move_type = 'sale') then
      for v_prod, v_qty in select product_id, sum(qty) from fabula.sales_order_lines where sales_order_id = v_id and qty > 0 group by product_id loop
        v_left := v_qty; first_lot := null;
        for lot in select lot_number, expiry_date, qty_on_hand from fabula.v_stock_on_hand where product_id = v_prod and qty_on_hand > 0
                   order by (expiry_date is not null and expiry_date < current_date), expiry_date nulls last, lot_number loop   -- FEFO among lots still in date; expired lots last
          exit when v_left <= 0;
          insert into fabula.stock_moves (product_id, lot_number, expiry_date, qty, move_type, sales_order_id, reason, source)
          values (v_prod, lot.lot_number, lot.expiry_date, -least(v_left, lot.qty_on_hand), 'sale', v_id, 'Shopify ' || coalesce(r->>'name', ''), 'shopify');
          first_lot := coalesce(first_lot, lot.lot_number); v_left := v_left - least(v_left, lot.qty_on_hand); n_moves := n_moves + 1;
        end loop;
        if v_left > 0 then   -- nothing (or not enough) on hand: book against no lot so the sale still counts; health check will show negative stock
          insert into fabula.stock_moves (product_id, lot_number, qty, move_type, sales_order_id, reason, source)
          values (v_prod, null, -v_left, 'sale', v_id, 'Shopify ' || coalesce(r->>'name', '') || ' · giacenza insufficiente', 'shopify'); n_moves := n_moves + 1;
        end if;
        update fabula.sales_order_lines set lot_number = first_lot where sales_order_id = v_id and product_id = v_prod and lot_number is null;
      end loop;
    end if;
  end loop;
  return jsonb_build_object('received', jsonb_array_length(coalesce(p_rows, '[]'::jsonb)), 'created', n_new, 'updated', n_upd, 'stock_moves', n_moves, 'unmapped_lines', n_unm,
    'unmapped_variants', (select coalesce(jsonb_agg(jsonb_build_object('variant_id', variant_id, 'label', label, 'type', product_type) order by label), '[]') from fabula.shopify_variant_map where product_id is null or kg_per_unit is null),
    'last_order', (select max(order_date) from fabula.sales_orders where channel = 'shopify'));
end $$;
grant execute on function fabula.upsert_shopify_orders(jsonb) to authenticated, service_role;

-- console: online orders of the last days, and the variant map editor
create or replace view fabula.v_shopify_orders_recent as
  select o.order_number, o.order_date, o.status::text as status, o.total_eur, o.ship_city, p.legal_name as customer,
         (select string_agg(trim_scale(l.qty) || ' kg ' || pr.name, ', ') from fabula.sales_order_lines l join fabula.products pr on pr.id = l.product_id where l.sales_order_id = o.id and l.qty > 0) as lines_txt,
         (select count(*) from fabula.shopify_unmapped_lines u where u.sales_order_id = o.id) as unmapped,
         exists (select 1 from fabula.stock_moves m where m.sales_order_id = o.id and m.move_type = 'sale') as stock_booked
  from fabula.sales_orders o left join fabula.parties p on p.id = o.customer_id
  where o.channel = 'shopify' and o.order_date >= (now() at time zone 'Europe/Rome')::date - 14
  order by o.order_date desc, o.order_number desc;
grant select on fabula.v_shopify_orders_recent to authenticated, service_role;
create or replace view fabula.v_shopify_variant_map as
  select m.variant_id, m.label, m.product_type, m.kg_per_unit, m.auto_mapped, m.updated_at, p.sku as product_sku, p.name as product_name,
         (select count(*) from fabula.shopify_unmapped_lines u where u.variant_id = m.variant_id) as unmapped_lines
  from fabula.shopify_variant_map m left join fabula.products p on p.id = m.product_id
  order by (m.product_id is null) desc, m.product_type, m.label;
grant select on fabula.v_shopify_variant_map to authenticated, service_role;

create or replace function fabula.expected_bots(p_date date)
returns table(agent text) language sql immutable as $$
  select a from unnest(array['daily_brief','procurement','wholesale_orders','milk_planning','sell_down','haccp_nudge','shopify_customers','shopify_orders']) a where extract(isodow from p_date) between 1 and 6
  union all select 'weekly_brief' where extract(isodow from p_date) = 1
  union all select 'compliance_calendar' where extract(isodow from p_date) = 2
  union all select 'monthly_review' where extract(day from p_date) = 1
$$;
