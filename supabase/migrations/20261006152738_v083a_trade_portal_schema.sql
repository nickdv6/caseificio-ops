-- =============================================================================
-- Fabula v0.83 — "Per i professionisti" (To the Trade): Shopify B2B + recurring deliveries
--   Native Shopify (Basic plan, verified 06/10/2026): companies, company locations, Net 30 terms,
--   B2B market "Ho.Re.Ca. Italia" + catalog "Listino Ho.Re.Ca." (price list, quantity rules, price breaks).
--   This migration adds what Shopify does not do: the application queue, the weekly delivery plan with
--   per-day quantities/windows, exceptions (skip, closure, temporary quantities, pause), the pricing engine
--   for the non-native parts (recurring discount, weekly-basis tiers, combine rule), the booking of next-day
--   deliveries into sales_orders + a queue that the edge function `trade-portal` turns into Shopify B2B orders.
--   Written without destructive keywords (connector rule). Part 1 of 3: schema, settings, pricing, effective lines.
-- =============================================================================
set search_path = fabula, public, extensions;

-- ---------- settings (all configurable from Configurazione → Parametri; prefix "trade.") ----------
insert into fabula.settings (key, value, description, data_type, sort) values
 ('trade.enabled', '1', 'Sezione professionisti (ristoranti, pizzerie, hotel) attiva: 1 = sì, 0 = no', 'number', 120),
 ('trade.min_order_kg', '3', 'Ordine minimo per consegna (kg). Sotto, il portale non accetta il piano / la modifica', 'number', 121),
 ('trade.cutoff_time', '18:00', 'Ora limite (Rome) del giorno prima per modificare o saltare una consegna; dopo, la consegna è confermata', 'text', 122),
 ('trade.delivery_days', '1,2,3,4,5,6', 'Giorni di consegna (1 = lunedì … 7 = domenica), separati da virgola', 'text', 123),
 ('trade.windows', '07:00-09:00,09:00-11:00', 'Fasce orarie di consegna offerte (hh:mm-hh:mm, separate da virgola)', 'text', 124),
 ('trade.default_window', '07:00-09:00', 'Fascia oraria proposta quando il cliente non ne sceglie una', 'text', 125),
 ('trade.recurring_discount_pct', '0', 'Sconto % sulle righe generate da un piano consegne attivo (0 = nessuno). Non si applica agli ordini extra fuori piano', 'number', 126),
 ('trade.discounts_combine', '1', 'Sconto ricorrente + scaglione quantità: 1 = si sommano (scaglione, poi sconto), 0 = si applica solo il migliore dei due', 'number', 127),
 ('trade.tier_basis', 'delivery', 'Base degli scaglioni quantità: delivery = kg della singola consegna (nativo Shopify), week = kg settimanali del piano', 'text', 128),
 ('trade.horizon_days', '28', 'Giorni futuri mostrati nel portale e nel calendario consegne', 'number', 129),
 ('trade.payment_terms_days', '30', 'Giorni di pagamento proposti alle aziende nuove (il modello Shopify "Net N" corrispondente)', 'number', 130),
 ('trade.allow_link_access', '0', 'Portale apribile anche dal link personale senza login Shopify (come la pagina della Masseria): 1 = sì, 0 = solo clienti collegati', 'number', 131),
 ('trade.shopify_market_id', 'gid://shopify/Market/58544980043', 'ID del mercato B2B Shopify "Ho.Re.Ca. Italia"', 'text', 132),
 ('trade.shopify_catalog_id', 'gid://shopify/MarketCatalog/125531652171', 'ID del catalogo B2B Shopify "Listino Ho.Re.Ca."', 'text', 133),
 ('trade.shopify_price_list_id', 'gid://shopify/PriceList/29986226251', 'ID del listino prezzi del catalogo B2B', 'text', 134),
 ('trade.edge_url', 'https://ojkquhzaeypsphncjqwy.supabase.co/functions/v1/trade-portal', 'Indirizzo della funzione trade-portal (portale, approvazioni, ordini Shopify)', 'text', 135),
 ('trade.job_secret', encode(extensions.gen_random_bytes(16), 'hex'), 'Chiave con cui il database chiama la funzione trade-portal per creare gli ordini Shopify (cambiarla = disattiva la vecchia)', 'text', 136),
 ('trade.store_url', 'https://www.perladelcilento.it', 'Indirizzo del sito Shopify (link nei messaggi ai clienti)', 'text', 137)
on conflict (key) do nothing;

-- ---------- parties: link to Shopify B2B objects + portal token ----------
alter table fabula.parties add column if not exists portal_token text;
alter table fabula.parties add column if not exists trade_status text not null default 'none';
alter table fabula.parties add column if not exists shopify_company_id text;
alter table fabula.parties add column if not exists shopify_location_id text;
alter table fabula.parties add column if not exists shopify_contact_id text;
alter table fabula.parties add column if not exists delivery_address text;
alter table fabula.parties add column if not exists delivery_instructions text;
alter table fabula.parties add column if not exists business_type text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'parties_trade_status_chk') then
    alter table fabula.parties add constraint parties_trade_status_chk check (trade_status in ('none','pending','approved','suspended'));
  end if;
end $$;
create unique index if not exists parties_portal_token_uq on fabula.parties (portal_token) where portal_token is not null;

-- ---------- sales orders: delivery details for the driver ----------
alter table fabula.sales_orders add column if not exists delivery_window text;
alter table fabula.sales_orders add column if not exists delivery_address text;
alter table fabula.sales_orders add column if not exists delivery_instructions text;
alter table fabula.sales_orders add column if not exists po_number text;

-- ---------- applications ----------
create table if not exists fabula.trade_applications (
  id uuid primary key default gen_random_uuid(),
  business_name text not null,
  business_type text not null default 'altro',
  piva text, codice_fiscale text, sdi_code text, pec_email text,
  contact_name text not null, email text not null, phone text,
  address text, city text, province text, postcode text,
  expected_kg_week numeric, preferred_days text, notes text,
  shopify_customer_id text,
  source text not null default 'web',
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  party_id uuid references fabula.parties(id),
  shopify_company_id text, shopify_location_id text, shopify_contact_id text,
  decided_by text, decided_at timestamptz, decision_note text,
  created_at timestamptz not null default now()
);
create index if not exists trade_applications_status_idx on fabula.trade_applications (status, created_at desc);

-- ---------- trade catalogue mirror (one row per Shopify variant sold to the trade) ----------
create table if not exists fabula.trade_products (
  variant_id text primary key,
  shopify_product_id text,
  product_id uuid references fabula.products(id),      -- ops product (kg bookkeeping, milk plan)
  title text not null,
  variant_title text,
  kg_per_unit numeric not null default 1,
  unit_label text not null default 'kg',
  base_price_eur numeric,                                -- Shopify base (retail) price of the variant
  trade_price_eur numeric,                               -- catalog price (null = not orderable by the trade yet)
  min_qty numeric not null default 1,
  step_qty numeric not null default 1,
  sort int not null default 100,
  active boolean not null default true,
  synced_at timestamptz,
  updated_at timestamptz not null default now()
);

-- ---------- quantity tiers (price breaks). variant_id null = every trade product ----------
create table if not exists fabula.trade_price_tiers (
  id uuid primary key default gen_random_uuid(),
  variant_id text references fabula.trade_products(variant_id) on delete cascade,
  min_qty numeric not null check (min_qty > 0),
  price_eur numeric check (price_eur is null or price_eur >= 0),
  discount_pct numeric check (discount_pct is null or (discount_pct >= 0 and discount_pct < 100)),
  active boolean not null default true,
  note text,
  check (price_eur is not null or discount_pct is not null)
);

-- ---------- the weekly plan ----------
create table if not exists fabula.trade_schedules (
  customer_id uuid primary key references fabula.parties(id),
  status text not null default 'active' check (status in ('active','paused','cancelled')),
  start_date date not null default current_date,
  end_date date,
  paused_from date, paused_until date,
  delivery_address text, delivery_instructions text,
  window_code text,
  po_number text,
  updated_at timestamptz not null default now(),
  updated_by text
);
create table if not exists fabula.trade_schedule_days (
  customer_id uuid not null references fabula.parties(id),
  weekday int not null check (weekday between 1 and 7),
  window_code text,
  primary key (customer_id, weekday)
);
create table if not exists fabula.trade_schedule_lines (
  customer_id uuid not null references fabula.parties(id),
  weekday int not null check (weekday between 1 and 7),
  variant_id text not null references fabula.trade_products(variant_id),
  qty numeric not null check (qty >= 0),
  primary key (customer_id, weekday, variant_id)
);

-- ---------- exceptions: skip a date/range, temporary quantity, temporary window. They expire by themselves ----------
create table if not exists fabula.trade_exceptions (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references fabula.parties(id),
  kind text not null check (kind in ('skip','override','window')),
  date_from date not null,
  date_to date not null,
  variant_id text references fabula.trade_products(variant_id),
  qty numeric check (qty is null or qty >= 0),
  window_code text,
  note text,
  created_by text not null default 'customer',
  created_at timestamptz not null default now(),
  cancelled_at timestamptz,
  check (date_to >= date_from),
  check (kind <> 'override' or (variant_id is not null and qty is not null)),
  check (kind <> 'window' or window_code is not null)
);
create index if not exists trade_exceptions_cust_idx on fabula.trade_exceptions (customer_id, date_from, date_to) where cancelled_at is null;

-- ---------- the dairy's own closures (no deliveries) ----------
create table if not exists fabula.trade_closures (
  id uuid primary key default gen_random_uuid(),
  date_from date not null, date_to date not null, note text,
  check (date_to >= date_from)
);

-- ---------- confirmations shown to the customer ----------
create table if not exists fabula.trade_change_log (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references fabula.parties(id),
  at timestamptz not null default now(),
  actor text not null default 'customer',
  action text not null,
  details jsonb not null default '{}'::jsonb,
  message_it text not null
);
create index if not exists trade_change_log_cust_idx on fabula.trade_change_log (customer_id, at desc);

-- ---------- queue: booked deliveries waiting to become Shopify B2B orders ----------
create table if not exists fabula.trade_order_queue (
  id uuid primary key default gen_random_uuid(),
  sales_order_id uuid not null references fabula.sales_orders(id),
  customer_id uuid not null references fabula.parties(id),
  delivery_date date not null,
  payload jsonb not null,
  status text not null default 'pending' check (status in ('pending','created','failed','skipped')),
  shopify_draft_id text, shopify_order_id text, shopify_order_name text,
  error text, attempts int not null default 0,
  created_at timestamptz not null default now(), done_at timestamptz
);
create unique index if not exists trade_order_queue_order_uq on fabula.trade_order_queue (sales_order_id);

-- ---------- helpers ----------
create or replace function fabula.trade_now_rome() returns timestamp language sql stable as $$ select now() at time zone 'Europe/Rome' $$;

create or replace function fabula.trade_settings() returns jsonb language sql stable set search_path = fabula, public as $$
  select jsonb_build_object(
    'enabled', fabula.setting_num('trade.enabled', 1) = 1,
    'min_order_kg', fabula.setting_num('trade.min_order_kg', 3),
    'cutoff_time', fabula.setting_text('trade.cutoff_time', '18:00'),
    'delivery_days', (select coalesce(array_agg(x::int order by x::int), '{}') from unnest(string_to_array(fabula.setting_text('trade.delivery_days', '1,2,3,4,5,6'), ',')) x where trim(x) ~ '^[1-7]$'),
    'windows', (select coalesce(array_agg(trim(w)), '{}') from unnest(string_to_array(fabula.setting_text('trade.windows', '07:00-09:00'), ',')) w where trim(w) <> ''),
    'default_window', fabula.setting_text('trade.default_window', '07:00-09:00'),
    'recurring_discount_pct', fabula.setting_num('trade.recurring_discount_pct', 0),
    'discounts_combine', fabula.setting_num('trade.discounts_combine', 1) = 1,
    'tier_basis', coalesce(fabula.setting_text('trade.tier_basis', 'delivery'), 'delivery'),
    'horizon_days', fabula.setting_num('trade.horizon_days', 28)::int,
    'payment_terms_days', fabula.setting_num('trade.payment_terms_days', 30)::int,
    'allow_link_access', fabula.setting_num('trade.allow_link_access', 0) = 1,
    'company_name', fabula.company_name(),
    'store_url', fabula.setting_text('trade.store_url', 'https://www.perladelcilento.it'),
    'cutoff_rule_it', format('Modifiche e salti entro le %s del giorno prima della consegna', fabula.setting_text('trade.cutoff_time', '18:00')))
$$;

-- changes for delivery date d are allowed until cutoff_time (Rome) of the day before
create or replace function fabula.trade_cutoff_at(p_date date) returns timestamp language sql stable set search_path = fabula, public as $$
  select (p_date - 1)::timestamp + coalesce(fabula.setting_text('trade.cutoff_time', '18:00'), '18:00')::time
$$;
create or replace function fabula.trade_can_change(p_date date) returns boolean language sql stable set search_path = fabula, public as $$
  select fabula.trade_now_rome() < fabula.trade_cutoff_at(p_date)
$$;

create or replace function fabula.trade_is_closed(p_date date) returns boolean language sql stable set search_path = fabula, public as $$
  select exists (select 1 from fabula.trade_closures c where p_date between c.date_from and c.date_to)
$$;
create or replace function fabula.trade_is_delivery_day(p_date date) returns boolean language sql stable set search_path = fabula, public as $$
  select extract(isodow from p_date)::int in (select v::int from jsonb_array_elements_text(fabula.trade_settings()->'delivery_days') as x(v))
         and not fabula.trade_is_closed(p_date)
$$;

create or replace function fabula.trade_party_by_token(p_token text) returns uuid language sql stable security definer set search_path = fabula, public as $$
  select id from fabula.parties where portal_token is not null and length(p_token) >= 16 and portal_token = p_token and trade_status = 'approved' and active
$$;

-- weekly kg of the base plan for a variant (tier basis "week"); variant null = whole plan
create or replace function fabula.trade_week_qty(p_customer uuid, p_variant text) returns numeric language sql stable set search_path = fabula, public as $$
  select coalesce(sum(l.qty * tp.kg_per_unit), 0) from fabula.trade_schedule_lines l join fabula.trade_products tp on tp.variant_id = l.variant_id
  where l.customer_id = p_customer and (p_variant is null or l.variant_id = p_variant)
$$;

-- ---------- pricing engine ----------
-- list price = trade catalog price; tier = best active tier whose minimum is reached on the configured basis
-- (variant-specific tiers win over "all products" tiers); recurring discount only for plan lines; combine rule from settings.
create or replace function fabula.trade_price(p_customer uuid, p_variant text, p_qty numeric, p_recurring boolean default true)
returns jsonb language plpgsql stable set search_path = fabula, public as $$
declare s jsonb := fabula.trade_settings(); tp fabula.trade_products%rowtype; v_list numeric; v_basis numeric; t record; v_tier numeric; v_tier_min numeric; v_tier_src text;
        v_rec numeric := 0; v_final numeric; v_combine boolean := (s->>'discounts_combine')::boolean;
begin
  select * into tp from fabula.trade_products where variant_id = p_variant;
  if tp.variant_id is null or tp.trade_price_eur is null then return jsonb_build_object('error', 'prodotto non in listino'); end if;
  v_list := tp.trade_price_eur;
  v_basis := case when s->>'tier_basis' = 'week' then fabula.trade_week_qty(p_customer, p_variant) else coalesce(p_qty, 0) * tp.kg_per_unit end;
  -- units: tiers are in the product's unit (kg): qty * kg_per_unit
  v_tier := v_list;
  for t in select * from fabula.trade_price_tiers where active and (variant_id = p_variant or variant_id is null) and min_qty <= v_basis
           order by (variant_id is not null) desc, min_qty desc loop
    v_tier := case when t.price_eur is not null then t.price_eur else round(v_list * (1 - t.discount_pct / 100), 2) end;
    v_tier_min := t.min_qty; v_tier_src := case when t.variant_id is null then 'tutti i prodotti' else 'prodotto' end;
    exit;
  end loop;
  if p_recurring then v_rec := coalesce((s->>'recurring_discount_pct')::numeric, 0); end if;
  if v_combine then v_final := round(v_tier * (1 - v_rec / 100), 2);
  else v_final := least(v_tier, round(v_list * (1 - v_rec / 100), 2)); end if;
  return jsonb_build_object('variant_id', p_variant, 'unit', tp.unit_label, 'list_price', v_list, 'tier_price', v_tier, 'tier_min_qty', v_tier_min, 'tier_source', v_tier_src,
                            'recurring_pct', v_rec, 'combine', v_combine, 'basis', s->>'tier_basis', 'basis_qty', v_basis,
                            'final_price', v_final, 'saving_eur', round(v_list - v_final, 2),
                            'saving_pct', case when v_list > 0 then round((v_list - v_final) / v_list * 100, 1) else 0 end,
                            'line_total', round(v_final * coalesce(p_qty, 0), 2));
end $$;

-- ---------- effective lines for a date (plan + exceptions + closures) ----------
create or replace function fabula.trade_effective_lines(p_date date)
returns table (customer_id uuid, variant_id text, product_id uuid, qty numeric, kg numeric, recurring boolean, window_code text,
               delivery_address text, delivery_instructions text, po_number text, source text)
language sql stable set search_path = fabula, public as $$
  with s as (select fabula.trade_settings() j),
  wd as (select extract(isodow from p_date)::int d),
  ok_day as (select fabula.trade_is_delivery_day(p_date) ok),
  cust as (  -- customers with an active plan on that date
    select ts.customer_id, ts.window_code sched_window, ts.delivery_address, ts.delivery_instructions, ts.po_number,
           (ts.status = 'active' and ts.start_date <= p_date and (ts.end_date is null or ts.end_date >= p_date)) as plan_on,
           (ts.status <> 'cancelled') as plan_exists
    from fabula.trade_schedules ts join fabula.parties p on p.id = ts.customer_id
    where p.active and p.trade_status = 'approved' and not fabula.is_placeholder_party(p.id)),
  skip as (select e.customer_id from fabula.trade_exceptions e where e.kind = 'skip' and e.cancelled_at is null and p_date between e.date_from and e.date_to),
  base as (
    select c.customer_id, l.variant_id, l.qty, true as recurring, 'piano' as source
    from cust c join wd on true join ok_day on true
    join fabula.trade_schedule_days d on d.customer_id = c.customer_id and d.weekday = wd.d
    join fabula.trade_schedule_lines l on l.customer_id = c.customer_id and l.weekday = wd.d
    where c.plan_on and ok_day.ok and c.customer_id not in (select customer_id from skip) and l.qty > 0),
  ov as (  -- temporary quantities for that date (replace the base line; 0 removes it; a new product adds a line)
    select e.customer_id, e.variant_id, e.qty,
           exists (select 1 from base b where b.customer_id = e.customer_id) as recurring, 'modifica' as source
    from fabula.trade_exceptions e join cust c on c.customer_id = e.customer_id join ok_day on true
    where e.kind = 'override' and e.cancelled_at is null and p_date between e.date_from and e.date_to and ok_day.ok
      and c.plan_exists and e.customer_id not in (select customer_id from skip)),
  merged as (
    select * from ov
    union all
    select b.* from base b where not exists (select 1 from ov where ov.customer_id = b.customer_id and ov.variant_id = b.variant_id)),
  win as (select e.customer_id, e.window_code from fabula.trade_exceptions e where e.kind = 'window' and e.cancelled_at is null and p_date between e.date_from and e.date_to)
  select m.customer_id, m.variant_id, tp.product_id, m.qty, round(m.qty * tp.kg_per_unit, 3) as kg, m.recurring,
         coalesce((select w.window_code from win w where w.customer_id = m.customer_id limit 1),
                  (select d.window_code from fabula.trade_schedule_days d where d.customer_id = m.customer_id and d.weekday = (select d from wd)),
                  c.sched_window, (select j->>'default_window' from s)) as window_code,
         coalesce(c.delivery_address, p.delivery_address, concat_ws(', ', p.address, p.postcode, p.city)) as delivery_address,
         coalesce(c.delivery_instructions, p.delivery_instructions) as delivery_instructions,
         c.po_number, m.source
  from merged m join cust c on c.customer_id = m.customer_id join fabula.parties p on p.id = m.customer_id
  join fabula.trade_products tp on tp.variant_id = m.variant_id
  where m.qty > 0 and tp.active and tp.trade_price_eur is not null
$$;

-- upcoming deliveries (portal + console), one row per customer per date, lines priced
create or replace function fabula.trade_upcoming(p_from date default null, p_days int default null, p_customer uuid default null)
returns jsonb language plpgsql stable set search_path = fabula, public as $$
declare d0 date := coalesce(p_from, fabula.trade_now_rome()::date); n int := coalesce(p_days, (fabula.trade_settings()->>'horizon_days')::int); res jsonb := '[]'; d date; r record; lines jsonb; tot numeric; kg numeric; booked record;
begin
  for d in select d0 + g from generate_series(0, n - 1) g loop
    for r in select customer_id, max(window_code) window_code, max(delivery_address) delivery_address, max(delivery_instructions) delivery_instructions, max(po_number) po_number, bool_or(recurring) recurring
             from fabula.trade_effective_lines(d) where p_customer is null or customer_id = p_customer group by customer_id loop
      select coalesce(jsonb_agg(jsonb_build_object('variant_id', l.variant_id, 'title', tp.title, 'variant_title', tp.variant_title, 'qty', l.qty, 'kg', l.kg, 'unit', tp.unit_label,
                                                   'source', l.source, 'price', fabula.trade_price(l.customer_id, l.variant_id, l.qty, l.recurring)) order by tp.sort, tp.title), '[]'),
             coalesce(sum((fabula.trade_price(l.customer_id, l.variant_id, l.qty, l.recurring)->>'line_total')::numeric), 0), coalesce(sum(l.kg), 0)
        into lines, tot, kg
      from fabula.trade_effective_lines(d) l join fabula.trade_products tp on tp.variant_id = l.variant_id where l.customer_id = r.customer_id;
      select o.order_number, o.status::text status, q.shopify_order_name, q.status qstatus into booked
        from fabula.sales_orders o left join fabula.trade_order_queue q on q.sales_order_id = o.id
       where o.customer_id = r.customer_id and o.order_date = d and o.channel = 'wholesale' and o.source = 'standing_order' and o.status <> 'cancelled' limit 1;
      res := res || jsonb_build_object('date', d, 'weekday', extract(isodow from d)::int, 'customer_id', r.customer_id,
        'customer', (select legal_name from fabula.parties where id = r.customer_id),
        'window', r.window_code, 'address', r.delivery_address, 'instructions', r.delivery_instructions, 'po_number', r.po_number,
        'recurring', r.recurring, 'lines', lines, 'kg', kg, 'total_eur', tot,
        'min_ok', kg >= (fabula.trade_settings()->>'min_order_kg')::numeric,
        'can_change', fabula.trade_can_change(d), 'cutoff_at', fabula.trade_cutoff_at(d),
        'booked', booked.order_number is not null, 'order_number', booked.order_number, 'order_status', booked.status, 'shopify_order', booked.shopify_order_name);
    end loop;
  end loop;
  return res;
end $$;

-- daily product totals (console export): kg per product per date, customers count
create or replace function fabula.trade_daily_totals(p_from date default null, p_days int default null)
returns table (delivery_date date, variant_id text, title text, variant_title text, qty numeric, kg numeric, customers int)
language sql stable set search_path = fabula, public as $$
  select g.d::date, l.variant_id, tp.title, tp.variant_title, sum(l.qty), sum(l.kg), count(distinct l.customer_id)::int
  from generate_series(coalesce(p_from, fabula.trade_now_rome()::date)::timestamp, (coalesce(p_from, fabula.trade_now_rome()::date) + coalesce(p_days, (fabula.trade_settings()->>'horizon_days')::int) - 1)::timestamp, interval '1 day') as g(d)
  cross join lateral fabula.trade_effective_lines(g.d::date) l join fabula.trade_products tp on tp.variant_id = l.variant_id
  group by g.d, l.variant_id, tp.title, tp.variant_title, tp.sort order by g.d, tp.sort, tp.title
$$;
