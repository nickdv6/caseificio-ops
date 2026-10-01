-- =============================================================================
-- Latteria Fabula — data backbone (v0.1)
-- Supabase / Postgres migration
--
-- Design notes
--  * One schema `fabula`, so it can coexist with anything else in the project.
--  * Every table has created_at/updated_at + a `source` column ("tablet",
--    "shopify", "agent:procurement", "sdi", ...) so you always know whether a
--    human or a bot wrote the row.
--  * Agents never commit money or legal paperwork directly: anything of that
--    kind lands in `approvals` first (status 'pending') and a human flips it.
--  * Amounts in EUR numeric(12,2); weights in kg numeric(10,3); IVA tracked
--    separately on invoices because the agricultural regime matters for you.
--  * Lot numbers follow the DOP traceability need: milk lot -> batch lot ->
--    finished-goods lot, all linkable.
-- =============================================================================

create extension if not exists "pgcrypto";

create schema if not exists fabula;
set search_path = fabula, public;

-- -----------------------------------------------------------------------------
-- Shared helpers
-- -----------------------------------------------------------------------------
create or replace function fabula.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

-- -----------------------------------------------------------------------------
-- Enums
-- -----------------------------------------------------------------------------
create type fabula.party_type       as enum ('supplier','customer','both');
create type fabula.product_kind     as enum ('finished_good','consumable','raw_material','packaging','service');
create type fabula.stock_move_type  as enum ('milk_intake','production_in','production_out','sale','purchase_receipt','waste','adjustment','sample','return');
create type fabula.sales_channel    as enum ('store_pos','shopify','wholesale','market','other');
create type fabula.order_status     as enum ('draft','confirmed','fulfilled','cancelled','refunded');
create type fabula.po_status        as enum ('draft','pending_approval','approved','sent','partially_received','received','cancelled');
create type fabula.invoice_direction as enum ('in','out');            -- in = supplier invoice (passiva), out = ours (attiva)
create type fabula.invoice_status   as enum ('received','coded','matched','approved','paid','disputed','void');
create type fabula.haccp_check_type as enum ('temperature','cleaning','pest','receiving','delivery','training','calibration','other');
create type fabula.haccp_result     as enum ('ok','warning','non_conformity');
create type fabula.approval_kind    as enum ('purchase_order','payment','invoice_coding','price_change','shopify_publish','outreach_email','dop_declaration','other');
create type fabula.approval_status  as enum ('pending','approved','rejected','expired');
create type fabula.actor_type       as enum ('human','agent');

-- -----------------------------------------------------------------------------
-- 1. Parties: suppliers, customers (B2B), the farm itself
-- -----------------------------------------------------------------------------
create table fabula.parties (
  id               uuid primary key default gen_random_uuid(),
  type             fabula.party_type not null,
  legal_name       text not null,
  trade_name       text,
  piva             text,                               -- Partita IVA (11 digits)
  codice_fiscale   text,
  sdi_code         text,                               -- codice destinatario for e-invoicing (7 chars) or PEC
  pec_email        text,
  email            text,
  phone            text,
  address          text,
  city             text,
  province         text,                               -- 'SA'
  postcode         text,
  country          text not null default 'IT',
  payment_terms_days int,
  is_milk_supplier boolean not null default false,
  is_dop_certified boolean not null default false,     -- supplier inside the DOP production area / registered with the Consorzio
  notes            text,
  active           boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create unique index parties_piva_uq on fabula.parties (piva) where piva is not null;

-- -----------------------------------------------------------------------------
-- 2. Products: finished goods AND consumables live here; `kind` splits them
-- -----------------------------------------------------------------------------
create table fabula.products (
  id               uuid primary key default gen_random_uuid(),
  sku              text not null unique,
  name             text not null,
  kind             fabula.product_kind not null,
  unit             text not null default 'kg',         -- kg | pz | l
  is_dop           boolean not null default false,     -- Mozzarella di Bufala Campana DOP
  shelf_life_days  int,                                -- for finished goods
  default_sale_price_eur numeric(12,2),                -- e.g. 14.00 /kg retail
  iva_rate         numeric(5,2),                       -- 4.00 for mozzarella, 22.00 most consumables
  reorder_point    numeric(10,3),                      -- consumables: trigger for the procurement agent
  reorder_qty      numeric(10,3),
  preferred_supplier_id uuid references fabula.parties(id),
  shopify_product_id text,
  shopify_variant_id text,
  active           boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- 3. Milk intake — one row per delivery (DOP traceability starts here)
-- -----------------------------------------------------------------------------
create table fabula.milk_intake (
  id               uuid primary key default gen_random_uuid(),
  intake_date      date not null,
  intake_time      time,
  supplier_id      uuid not null references fabula.parties(id),
  milk_lot         text not null,                      -- supplier's lot / tank id
  qty_kg           numeric(10,3) not null check (qty_kg > 0),
  temperature_c    numeric(4,1),                       -- at receipt, must be <= 4°C typically
  fat_pct          numeric(5,2),
  protein_pct      numeric(5,2),
  ph               numeric(4,2),
  scc_cells_ml     int,                                -- somatic cell count, if supplier provides
  price_eur_per_kg numeric(8,4),                       -- 1.30 benchmark
  accepted         boolean not null default true,
  rejection_reason text,
  ddt_number       text,                               -- documento di trasporto
  received_by      text,
  notes            text,
  source           text not null default 'tablet',
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index milk_intake_date_idx on fabula.milk_intake (intake_date desc);

-- -----------------------------------------------------------------------------
-- 4. Production batches — the daily "prova resa"
-- -----------------------------------------------------------------------------
create table fabula.production_batches (
  id               uuid primary key default gen_random_uuid(),
  batch_date       date not null,
  batch_lot        text not null unique,               -- printed on labels, e.g. L20261001-A
  product_id       uuid not null references fabula.products(id),   -- what was made (mozzarella, ricotta, ...)
  milk_in_kg       numeric(10,3) not null check (milk_in_kg > 0),
  output_kg        numeric(10,3) check (output_kg >= 0),
  yield_pct        numeric(5,2) generated always as
                     (case when milk_in_kg > 0 and output_kg is not null
                           then round(output_kg / milk_in_kg * 100, 2) end) stored,
  whey_kg          numeric(10,3),                      -- for ricotta planning
  started_at       timestamptz,
  finished_at      timestamptz,
  curd_ph          numeric(4,2),
  stretch_temp_c   numeric(4,1),
  salt_pct         numeric(5,2),
  casaro           text,                               -- cheesemaker on shift
  notes            text,
  source           text not null default 'tablet',
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index production_batches_date_idx on fabula.production_batches (batch_date desc);

-- Which milk went into which batch (many-to-many, for DOP traceability)
create table fabula.batch_milk_inputs (
  batch_id         uuid not null references fabula.production_batches(id) on delete cascade,
  milk_intake_id   uuid not null references fabula.milk_intake(id),
  qty_kg           numeric(10,3) not null check (qty_kg > 0),
  primary key (batch_id, milk_intake_id)
);

-- Consumables used in a batch (rennet, salt, cultures, packaging)
create table fabula.batch_consumables (
  id               uuid primary key default gen_random_uuid(),
  batch_id         uuid not null references fabula.production_batches(id) on delete cascade,
  product_id       uuid not null references fabula.products(id),
  qty              numeric(10,3) not null,
  lot_number       text
);

-- -----------------------------------------------------------------------------
-- 5. Inventory — append-only ledger of stock movements; stock on hand is a view
-- -----------------------------------------------------------------------------
create table fabula.stock_moves (
  id               uuid primary key default gen_random_uuid(),
  moved_at         timestamptz not null default now(),
  product_id       uuid not null references fabula.products(id),
  lot_number       text,
  expiry_date      date,
  qty              numeric(10,3) not null,             -- positive = in, negative = out
  move_type        fabula.stock_move_type not null,
  batch_id         uuid references fabula.production_batches(id),
  sales_order_id   uuid,                               -- FK added after sales_orders exists
  purchase_order_id uuid,                              -- FK added after purchase_orders exists
  unit_cost_eur    numeric(12,4),
  reason           text,
  source           text not null default 'tablet',
  created_at       timestamptz not null default now()
);
create index stock_moves_product_idx on fabula.stock_moves (product_id, moved_at desc);
create index stock_moves_lot_idx on fabula.stock_moves (lot_number);

create or replace view fabula.v_stock_on_hand as
select p.id as product_id, p.sku, p.name, p.kind, p.unit,
       sm.lot_number,
       max(sm.expiry_date) as expiry_date,          -- only the inbound move carries it
       sum(sm.qty) as qty_on_hand,
       p.reorder_point,
       (p.kind <> 'finished_good' and p.reorder_point is not null
          and sum(sm.qty) <= p.reorder_point) as below_reorder_point
from fabula.products p
join fabula.stock_moves sm on sm.product_id = p.id
group by p.id, sm.lot_number
having sum(sm.qty) <> 0;

-- -----------------------------------------------------------------------------
-- 6. Sales — orders + lines, every channel
-- -----------------------------------------------------------------------------
create table fabula.sales_orders (
  id               uuid primary key default gen_random_uuid(),
  order_number     text not null unique,
  channel          fabula.sales_channel not null,
  order_date       date not null,
  customer_id      uuid references fabula.parties(id),   -- null for anonymous store sales
  status           fabula.order_status not null default 'confirmed',
  subtotal_eur     numeric(12,2) not null default 0,
  iva_eur          numeric(12,2) not null default 0,
  total_eur        numeric(12,2) not null default 0,
  payment_method   text,                                 -- cash, card, satispay, bank_transfer
  shopify_order_id text,
  pos_receipt_number text,                               -- corrispettivo / scontrino reference
  invoice_id       uuid,                                 -- FK added after invoices
  notes            text,
  source           text not null default 'pos',
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index sales_orders_date_idx on fabula.sales_orders (order_date desc, channel);

create table fabula.sales_order_lines (
  id               uuid primary key default gen_random_uuid(),
  sales_order_id   uuid not null references fabula.sales_orders(id) on delete cascade,
  product_id       uuid not null references fabula.products(id),
  lot_number       text,
  qty              numeric(10,3) not null check (qty > 0),
  unit_price_eur   numeric(12,4) not null,
  discount_eur     numeric(12,2) not null default 0,
  iva_rate         numeric(5,2) not null,
  line_total_eur   numeric(12,2) generated always as
                     (round(qty * unit_price_eur - discount_eur, 2)) stored
);

alter table fabula.stock_moves
  add constraint stock_moves_sales_order_fk
  foreign key (sales_order_id) references fabula.sales_orders(id);

-- -----------------------------------------------------------------------------
-- 7. Procurement — purchase orders (agent drafts, human approves)
-- -----------------------------------------------------------------------------
create table fabula.purchase_orders (
  id               uuid primary key default gen_random_uuid(),
  po_number        text not null unique,
  supplier_id      uuid not null references fabula.parties(id),
  status           fabula.po_status not null default 'draft',
  order_date       date not null default current_date,
  expected_date    date,
  subtotal_eur     numeric(12,2) not null default 0,
  iva_eur          numeric(12,2) not null default 0,
  total_eur        numeric(12,2) not null default 0,
  drafted_by       fabula.actor_type not null default 'human',
  rationale        text,                                 -- agent's explanation ("salt below reorder point, 9 days cover left")
  notes            text,
  source           text not null default 'manual',
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create table fabula.purchase_order_lines (
  id               uuid primary key default gen_random_uuid(),
  purchase_order_id uuid not null references fabula.purchase_orders(id) on delete cascade,
  product_id       uuid not null references fabula.products(id),
  qty_ordered      numeric(10,3) not null check (qty_ordered > 0),
  qty_received     numeric(10,3) not null default 0,
  unit_price_eur   numeric(12,4) not null,
  iva_rate         numeric(5,2) not null
);

alter table fabula.stock_moves
  add constraint stock_moves_purchase_order_fk
  foreign key (purchase_order_id) references fabula.purchase_orders(id);

-- Supplier price history — lets the agent spot price creep
create table fabula.supplier_prices (
  id               uuid primary key default gen_random_uuid(),
  supplier_id      uuid not null references fabula.parties(id),
  product_id       uuid not null references fabula.products(id),
  price_eur        numeric(12,4) not null,
  valid_from       date not null default current_date,
  source           text not null default 'invoice',
  created_at       timestamptz not null default now()
);
create index supplier_prices_lookup_idx on fabula.supplier_prices (product_id, supplier_id, valid_from desc);

-- -----------------------------------------------------------------------------
-- 8. Invoices — both directions, mirrors what passes through SDI
-- -----------------------------------------------------------------------------
create table fabula.chart_of_accounts (
  code             text primary key,                    -- e.g. '60.01' Acquisti latte
  name             text not null,
  category         text not null,                       -- revenue | cogs | opex | asset | liability
  benchmark_bucket text                                 -- labor | utilities | consumables | marketing | lease (ties to your OpEx model)
);

create table fabula.invoices (
  id               uuid primary key default gen_random_uuid(),
  direction        fabula.invoice_direction not null,
  party_id         uuid not null references fabula.parties(id),
  invoice_number   text not null,
  invoice_date     date not null,
  due_date         date,
  sdi_id           text,                                -- identificativo SDI
  xml_storage_path text,                                -- FatturaPA XML in Supabase Storage
  pdf_storage_path text,
  taxable_eur      numeric(12,2) not null,
  iva_eur          numeric(12,2) not null,
  total_eur        numeric(12,2) not null,
  status           fabula.invoice_status not null default 'received',
  purchase_order_id uuid references fabula.purchase_orders(id),  -- 3-way match target
  paid_at          date,
  payment_ref      text,
  anomaly_flags    jsonb not null default '[]'::jsonb,  -- ["duplicate_suspect","price_above_po","no_po"]
  source           text not null default 'sdi',
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (direction, party_id, invoice_number, invoice_date)
);
create index invoices_status_idx on fabula.invoices (direction, status, due_date);

create table fabula.invoice_lines (
  id               uuid primary key default gen_random_uuid(),
  invoice_id       uuid not null references fabula.invoices(id) on delete cascade,
  description      text not null,
  product_id       uuid references fabula.products(id),
  qty              numeric(10,3),
  unit_price_eur   numeric(12,4),
  taxable_eur      numeric(12,2) not null,
  iva_rate         numeric(5,2) not null,
  account_code     text references fabula.chart_of_accounts(code),  -- coded by agent, confirmed by human
  coded_by         fabula.actor_type
);

alter table fabula.sales_orders
  add constraint sales_orders_invoice_fk
  foreign key (invoice_id) references fabula.invoices(id);

-- Bank feed for reconciliation
create table fabula.bank_transactions (
  id               uuid primary key default gen_random_uuid(),
  bank_account     text not null,
  value_date       date not null,
  amount_eur       numeric(12,2) not null,              -- signed
  description      text,
  counterparty     text,
  external_id      text unique,                         -- from the bank/PSD2 feed
  matched_invoice_id uuid references fabula.invoices(id),
  matched_order_id uuid references fabula.sales_orders(id),
  reconciled       boolean not null default false,
  source           text not null default 'bank_feed',
  created_at       timestamptz not null default now()
);
create index bank_tx_unreconciled_idx on fabula.bank_transactions (reconciled, value_date desc);

-- -----------------------------------------------------------------------------
-- 9. HACCP log
-- -----------------------------------------------------------------------------
create table fabula.haccp_control_points (
  id               uuid primary key default gen_random_uuid(),
  code             text not null unique,                -- CCP1, CCP2, PRP-CLEAN-01
  name             text not null,
  check_type       fabula.haccp_check_type not null,
  frequency        text not null,                       -- 'daily', 'per_batch', 'weekly', 'twice_daily'
  min_value        numeric(10,2),
  max_value        numeric(10,2),
  unit             text,
  active           boolean not null default true
);

create table fabula.haccp_log (
  id               uuid primary key default gen_random_uuid(),
  control_point_id uuid not null references fabula.haccp_control_points(id),
  logged_at        timestamptz not null default now(),
  measured_value   numeric(10,2),
  result           fabula.haccp_result not null,
  batch_id         uuid references fabula.production_batches(id),
  equipment        text,                                -- 'cella frigo 1', 'pasteurizer'
  operator         text not null,
  corrective_action text,
  verified_by      text,
  photo_storage_path text,
  source           text not null default 'tablet',
  created_at       timestamptz not null default now()
);
create index haccp_log_cp_idx on fabula.haccp_log (control_point_id, logged_at desc);

-- -----------------------------------------------------------------------------
-- 10. Approvals — the human gate every agent must pass through
-- -----------------------------------------------------------------------------
create table fabula.approvals (
  id               uuid primary key default gen_random_uuid(),
  kind             fabula.approval_kind not null,
  status           fabula.approval_status not null default 'pending',
  requested_by     text not null,                       -- 'agent:procurement', 'agent:accounting'
  summary          text not null,                       -- one line, human readable, IT + EN ok
  payload          jsonb not null,                      -- what will happen if approved
  related_table    text,
  related_id       uuid,
  amount_eur       numeric(12,2),
  requested_at     timestamptz not null default now(),
  decided_by       text,
  decided_at       timestamptz,
  decision_note    text,
  expires_at       timestamptz
);
create index approvals_pending_idx on fabula.approvals (status, requested_at) where status = 'pending';

-- Agent run log — what each bot did and when
create table fabula.agent_runs (
  id               uuid primary key default gen_random_uuid(),
  agent            text not null,                       -- 'accounting', 'procurement', 'marketing', 'daily_brief'
  started_at       timestamptz not null default now(),
  finished_at      timestamptz,
  status           text not null default 'running',     -- running | ok | error
  summary          text,
  details          jsonb,
  error            text
);

-- -----------------------------------------------------------------------------
-- 11. Reporting views the daily brief reads from
-- -----------------------------------------------------------------------------
create or replace view fabula.v_daily_production as
select b.batch_date,
       p.name as product,
       count(*)              as batches,
       sum(b.milk_in_kg)     as milk_in_kg,
       sum(b.output_kg)      as output_kg,
       round(sum(b.output_kg) / nullif(sum(b.milk_in_kg),0) * 100, 2) as yield_pct
from fabula.production_batches b
join fabula.products p on p.id = b.product_id
group by b.batch_date, p.name;

create or replace view fabula.v_daily_sales as
select order_date, channel,
       count(*) as orders,
       sum(total_eur) as revenue_eur
from fabula.sales_orders
where status in ('confirmed','fulfilled')
group by order_date, channel;

create or replace view fabula.v_haccp_missing_today as
select cp.code, cp.name, cp.frequency
from fabula.haccp_control_points cp
where cp.active
  and cp.frequency in ('daily','twice_daily')
  and not exists (
    select 1 from fabula.haccp_log l
    where l.control_point_id = cp.id
      and l.logged_at::date = current_date);

create or replace view fabula.v_expiring_stock as
select * from fabula.v_stock_on_hand
where kind = 'finished_good'
  and expiry_date is not null
  and expiry_date <= current_date + 2;

-- -----------------------------------------------------------------------------
-- updated_at triggers
-- -----------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['parties','products','milk_intake','production_batches',
                           'sales_orders','purchase_orders','invoices']
  loop
    execute format('create trigger %I_updated_at before update on fabula.%I
                    for each row execute function fabula.set_updated_at()', t, t);
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- Row Level Security — enabled everywhere; policies are deliberately minimal
-- until you decide roles (owner / partner / agent service key).
-- Agents should use the service role; tablet users use authenticated role.
-- -----------------------------------------------------------------------------
do $$
declare t text;
begin
  for t in select table_name from information_schema.tables
           where table_schema = 'fabula' and table_type = 'BASE TABLE'
  loop
    execute format('alter table fabula.%I enable row level security', t);
    execute format('create policy %I_authenticated_all on fabula.%I
                    for all to authenticated using (true) with check (true)', t, t);
  end loop;
end $$;

grant usage on schema fabula to authenticated, service_role;
grant all on all tables in schema fabula to authenticated, service_role;
grant all on all sequences in schema fabula to authenticated, service_role;
alter default privileges in schema fabula grant all on tables to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Seed: minimal reference data
-- -----------------------------------------------------------------------------
insert into fabula.chart_of_accounts (code, name, category, benchmark_bucket) values
  ('40.01','Vendite mozzarella DOP',        'revenue', null),
  ('40.02','Vendite altri latticini',       'revenue', null),
  ('40.03','Vendite cosmetici',             'revenue', null),
  ('60.01','Acquisti latte di bufala',      'cogs',    null),
  ('60.02','Caglio, sale, fermenti',        'cogs',    'consumables'),
  ('60.03','Imballaggi',                    'cogs',    'consumables'),
  ('61.01','Energia elettrica',             'opex',    'utilities'),
  ('61.02','Gas / acqua',                   'opex',    'utilities'),
  ('62.01','Salari e stipendi',             'opex',    'labor'),
  ('62.02','Contributi',                    'opex',    'labor'),
  ('63.01','Affitto locali',                'opex',    'lease'),
  ('64.01','Marketing e pubblicità',        'opex',    'marketing'),
  ('65.01','Consorzio DOP / certificazione','opex',    null),
  ('66.01','Commercialista / consulenti',   'opex',    null);

insert into fabula.haccp_control_points (code, name, check_type, frequency, min_value, max_value, unit) values
  ('CCP-MILK-TEMP','Temperatura latte in ricezione','temperature','per_batch', null, 4.0, '°C'),
  ('CCP-PAST',     'Temperatura pastorizzazione',   'temperature','per_batch', 72.0, null, '°C'),
  ('CCP-COLD-1',   'Cella frigo 1',                 'temperature','twice_daily', 0.0, 4.0, '°C'),
  ('CCP-COLD-2',   'Cella frigo 2',                 'temperature','twice_daily', 0.0, 4.0, '°C'),
  ('PRP-CLEAN',    'Sanificazione fine turno',      'cleaning',   'daily', null, null, null),
  ('PRP-PEST',     'Controllo infestanti',          'pest',       'weekly', null, null, null);

insert into fabula.products (sku, name, kind, unit, is_dop, shelf_life_days, default_sale_price_eur, iva_rate) values
  ('MOZ-DOP-KG', 'Mozzarella di Bufala Campana DOP', 'finished_good', 'kg', true, 5, 14.00, 4.00),
  ('RIC-BUF-KG', 'Ricotta di bufala',                'finished_good', 'kg', false, 4, 9.00, 4.00),
  ('RAW-MILK',   'Latte di bufala crudo',            'raw_material',  'kg', false, null, null, 4.00),
  ('CON-SALT',   'Sale marino',                      'consumable',    'kg', false, null, null, 22.00),
  ('CON-RENNET', 'Caglio',                           'consumable',    'l',  false, null, null, 22.00),
  ('PKG-BAG-500','Busta 500 g',                      'packaging',     'pz', false, null, null, 22.00);
