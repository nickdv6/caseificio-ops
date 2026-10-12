-- v0.89a (12/10/2026): supply catalogue — what we buy, by category, from which supplier, at what price;
-- manual multi-line purchase orders from Console → Anagrafiche → Fornitori → "Articoli che compriamo".
-- New: supply_categories (editable), products.category / spec_it / track_stock, 23 starter items (no supplier/price),
-- v_supply_catalog, add_supply_item(), link_supplier_item(), unlink_supplier_item(), create_manual_po().
-- Changed: start_stock_count() skips order-only items; v_parties_editor counts every linked item per supplier.
-- Run once in the Supabase SQL editor (project Caseificio). Safe to re-run.

begin;


create table if not exists fabula.supply_categories (
  code text primary key,
  name_it text not null,
  hint_it text,
  sku_prefix text not null,
  kind fabula.product_kind not null default 'consumable',
  track_stock_default boolean not null default true,
  sort int not null default 100,
  active boolean not null default true
);
alter table fabula.supply_categories enable row level security;
grant select, insert, update, delete on fabula.supply_categories to authenticated;
insert into fabula.table_areas (table_name, area, write_level, read_open) values ('supply_categories', 'acquisti', 3, true) on conflict (table_name) do nothing;
drop policy if exists supply_categories_select on fabula.supply_categories;
drop policy if exists supply_categories_write on fabula.supply_categories;
create policy supply_categories_select on fabula.supply_categories for select to authenticated using ((select fabula.can_table('supply_categories', false)));
create policy supply_categories_write on fabula.supply_categories for all to authenticated using ((select fabula.can_table('supply_categories', true))) with check ((select fabula.can_table('supply_categories', true)));

insert into fabula.supply_categories (code, name_it, hint_it, sku_prefix, kind, track_stock_default, sort) values
  ('caseificazione', 'Caseificazione',          'caglio, sale, acido citrico per la ricotta', 'CON', 'consumable', true,  10),
  ('imballaggio',    'Imballaggi ed etichette', 'buste, vaschette, fuscelle, etichette, box spedizione', 'PKG', 'packaging', true, 20),
  ('pulizia',        'Pulizia e igiene',        'detergenti, sanificanti, carta, sacchi', 'CLN', 'consumable', false, 30),
  ('dpi',            'Abbigliamento e DPI',     'guanti, cuffie, grembiuli, mascherine', 'DPI', 'consumable', false, 40),
  ('laboratorio',    'Laboratorio e analisi',   'soluzioni pH, soda per acidità, tamponi superfici', 'LAB', 'consumable', false, 50),
  ('ufficio',        'Ufficio e cassa',         'rotoli cassa, carta, toner, cancelleria', 'OFF', 'consumable', false, 60),
  ('altro',          'Altro',                   null, 'ALT', 'consumable', false, 90)
on conflict (code) do nothing;

alter table fabula.products
  add column if not exists category text references fabula.supply_categories(code) on update cascade,
  add column if not exists spec_it text,
  add column if not exists track_stock boolean not null default true;

update fabula.products set category = 'caseificazione' where category is null and sku like 'CON-%';
update fabula.products set category = 'imballaggio'    where category is null and kind = 'packaging';
update fabula.products set category = 'altro'          where category is null and kind = 'consumable';

-- starter list (no supplier, no price): rename, archive or link a supplier from the console
insert into fabula.products (sku, name, kind, unit, iva_rate, category, track_stock, spec_it)
select v.sku, v.name, c.kind, v.unit, 22, v.cat, c.track_stock_default, 'elenco di partenza'
from (values
  ('PKG-TUB-250',  'Vaschetta 250 g',                     'pz',      'imballaggio'),
  ('PKG-WAAGE',    'Rotoli etichette bilancia',           'rotolo',  'imballaggio'),
  ('PKG-BOX-ISO',  'Box isotermico spedizione',           'pz',      'imballaggio'),
  ('PKG-GEL',      'Siberini / gel refrigeranti',         'pz',      'imballaggio'),
  ('PKG-SHOP',     'Buste shopper negozio',               'pz',      'imballaggio'),
  ('CLN-ALK',      'Detergente alcalino cloroattivo',     'l',       'pulizia'),
  ('CLN-ACID',     'Detergente acido',                    'l',       'pulizia'),
  ('CLN-SAN',      'Sanificante superfici alimentari',    'l',       'pulizia'),
  ('CLN-HAND',     'Sapone mani',                         'l',       'pulizia'),
  ('CLN-PAPER',    'Bobine carta asciugamani',            'rotolo',  'pulizia'),
  ('CLN-BAG',      'Sacchi spazzatura',                   'rotolo',  'pulizia'),
  ('CLN-SPONGE',   'Spugne e panni',                      'pz',      'pulizia'),
  ('DPI-GLOVE',    'Guanti nitrile',                      'scatola', 'dpi'),
  ('DPI-CAP',      'Cuffie monouso',                      'conf',    'dpi'),
  ('DPI-APRON',    'Grembiuli monouso',                   'conf',    'dpi'),
  ('DPI-MASK',     'Mascherine',                          'conf',    'dpi'),
  ('LAB-PH',       'Soluzioni tampone pH 4 e 7',          'flacone', 'laboratorio'),
  ('LAB-SH',       'Soluzione soda per acidità (°SH)',    'l',       'laboratorio'),
  ('LAB-SWAB',     'Tamponi test superfici',              'conf',    'laboratorio'),
  ('OFF-TILL',     'Rotoli carta registratore di cassa',  'rotolo',  'ufficio'),
  ('OFF-A4',       'Carta A4',                            'risma',   'ufficio'),
  ('OFF-TONER',    'Toner stampante',                     'pz',      'ufficio'),
  ('OFF-PEN',      'Penne e pennarelli',                  'conf',    'ufficio')
) v(sku, name, unit, cat) join fabula.supply_categories c on c.code = v.cat
on conflict (sku) do nothing;

-- stock count only lists items we keep in stock
create or replace function fabula.start_stock_count(p_staff_id uuid default null)
 returns jsonb language plpgsql security definer set search_path to 'fabula', 'public'
as $function$
declare v_id uuid;
begin
  perform fabula.require_perm('magazzino', 2);
  select id into v_id from fabula.stock_counts where status = 'open' and counted_at::date = (now() at time zone 'Europe/Rome')::date limit 1;
  if v_id is null then
    insert into fabula.stock_counts (counted_by_id) values (p_staff_id) returning id into v_id;
    insert into fabula.stock_count_lines (count_id, product_id, lot_number, system_qty, unit_cost_eur)
    select v_id, p.id, null, coalesce(sum(s.qty_on_hand), 0), fabula.unit_cost_estimate(p.id)
    from fabula.products p left join fabula.v_stock_on_hand s on s.product_id = p.id
    where p.kind in ('consumable','packaging') and p.active and p.track_stock group by p.id
    union all
    select v_id, s.product_id, s.lot_number, s.qty_on_hand, fabula.unit_cost_estimate(s.product_id)
    from fabula.v_stock_on_hand s where s.kind = 'finished_good' and s.qty_on_hand > 0;
  end if;
  return jsonb_build_object('count_id', v_id,
    'lines', (select jsonb_agg(jsonb_build_object('line_id', l.id, 'sku', p.sku, 'name', p.name, 'unit', p.unit, 'kind', p.kind, 'lot', l.lot_number, 'system_qty', l.system_qty, 'counted_qty', l.counted_qty)
                               order by case p.kind when 'finished_good' then 0 else 1 end, p.name, l.lot_number)
              from fabula.stock_count_lines l join fabula.products p on p.id = l.product_id where l.count_id = v_id));
end $function$;

-- the catalogue the console shows: one row per item, suppliers as a list (preferred first)
create or replace view fabula.v_supply_catalog with (security_invoker = true) as
select p.id, p.sku, p.name, p.unit, p.kind::text as kind, coalesce(p.category, 'altro') as category, c.name_it as category_name, c.sort as category_sort,
       p.spec_it, p.iva_rate, p.reorder_point, p.reorder_qty, p.track_stock, p.active, p.preferred_supplier_id,
       (select coalesce(sum(s.qty_on_hand), 0) from fabula.v_stock_on_hand s where s.product_id = p.id) as on_hand,
       (select jsonb_agg(jsonb_build_object('supplier_id', t.supplier_id, 'supplier', t.supplier, 'preferred', t.preferred,
                                            'price_eur', coalesce(t.list_price_eur, t.last_paid_eur), 'price_src', case when t.list_price_eur is not null then 'listino' when t.last_paid_eur is not null then 'ultimo DDT' end,
                                            'supplier_sku', t.supplier_sku, 'min_order_qty', t.min_order_qty, 'order_multiple', t.order_multiple, 'lead_time_days', t.lead_time_days)
                         order by t.preferred desc, t.supplier)
          from fabula.v_supplier_terms t join fabula.parties sp on sp.id = t.supplier_id
          where t.product_id = p.id and t.active and sp.active) as suppliers,
       (select max(po.order_date) from fabula.purchase_order_lines l join fabula.purchase_orders po on po.id = l.purchase_order_id
          where l.product_id = p.id and po.status <> 'cancelled') as last_ordered_on,
       exists (select 1 from fabula.purchase_order_lines l join fabula.purchase_orders po on po.id = l.purchase_order_id
          where l.product_id = p.id and po.status in ('draft','pending_approval','approved','sent','partially_received')) as open_po
from fabula.products p left join fabula.supply_categories c on c.code = coalesce(p.category, 'altro')
where p.kind in ('consumable','packaging');
grant select on fabula.v_supply_catalog to authenticated;

-- "Articoli" on the supplier list = items actually linked to that supplier (it counted only preferred ones)
create or replace view fabula.v_parties_editor with (security_invoker = true) as
 select id, (type)::text as type, legal_name, email, phone, payment_terms_days, is_milk_supplier, is_dop_certified, notes, active,
    ((source = 'placeholder'::text) or (notes = 'placeholder'::text)) as is_placeholder,
    (select count(*) from fabula.supplier_products sp join fabula.products pr on pr.id = sp.product_id where sp.supplier_id = p.id and sp.active and pr.active) as products_supplied,
    (select count(*) from fabula.standing_orders s where s.customer_id = p.id and s.active) as standing_orders,
    city, source, shopify_customer_id, tags, is_wholesale, last_synced_at, orders_count, total_spent_eur
   from fabula.parties p
  where active
  order by (type)::text, is_wholesale desc, legal_name;

-- add an item: SKU from the category prefix; optional first supplier + price (becomes preferred)
create or replace function fabula.add_supply_item(p_name text, p_category text, p_unit text, p_supplier_id uuid default null, p_price_eur numeric default null, p_spec text default null)
 returns uuid language plpgsql security definer set search_path to 'fabula', 'public'
as $function$
declare c record; v_sku text; v_n int; v_id uuid;
begin
  perform fabula.require_perm('acquisti', 3);
  if coalesce(trim(p_name), '') = '' then raise exception 'Scrivi il nome dell''articolo'; end if;
  if exists (select 1 from fabula.products where lower(name) = lower(trim(p_name)) and active and kind in ('consumable','packaging')) then
    raise exception 'C''è già un articolo "%"', trim(p_name); end if;
  select * into c from fabula.supply_categories where code = p_category;
  if not found then raise exception 'Categoria sconosciuta: %', p_category; end if;
  select count(*) + 1 into v_n from fabula.products where sku like c.sku_prefix || '-%';
  loop
    v_sku := c.sku_prefix || '-' || lpad(v_n::text, 3, '0');
    exit when not exists (select 1 from fabula.products where sku = v_sku);
    v_n := v_n + 1;
  end loop;
  insert into fabula.products (sku, name, kind, unit, iva_rate, category, track_stock, spec_it, preferred_supplier_id)
  values (v_sku, trim(p_name), c.kind, coalesce(nullif(trim(p_unit), ''), 'pz'), 22, c.code, c.track_stock_default, nullif(trim(p_spec), ''), p_supplier_id)
  returning id into v_id;
  if p_supplier_id is not null then
    insert into fabula.supplier_products (supplier_id, product_id) values (p_supplier_id, v_id) on conflict do nothing;
    if p_price_eur is not null and p_price_eur > 0 then
      insert into fabula.supplier_prices (supplier_id, product_id, price_eur, valid_from, source) values (p_supplier_id, v_id, p_price_eur, current_date, 'console');
    end if;
  end if;
  return v_id;
end $function$;

-- link / re-link a supplier to an item with an optional list price
create or replace function fabula.link_supplier_item(p_product_id uuid, p_supplier_id uuid, p_price_eur numeric default null, p_make_preferred boolean default false)
 returns void language plpgsql security definer set search_path to 'fabula', 'public'
as $function$
begin
  perform fabula.require_perm('acquisti', 3);
  insert into fabula.supplier_products (supplier_id, product_id, active) values (p_supplier_id, p_product_id, true)
    on conflict (supplier_id, product_id) do update set active = true, updated_at = now();
  if p_price_eur is not null and p_price_eur > 0 and p_price_eur is distinct from
     (select price_eur from fabula.supplier_prices where supplier_id = p_supplier_id and product_id = p_product_id and valid_from <= current_date order by valid_from desc, created_at desc limit 1) then
    insert into fabula.supplier_prices (supplier_id, product_id, price_eur, valid_from, source) values (p_supplier_id, p_product_id, p_price_eur, current_date, 'console');
  end if;
  if p_make_preferred or (select preferred_supplier_id is null from fabula.products where id = p_product_id) then
    update fabula.products set preferred_supplier_id = p_supplier_id, updated_at = now() where id = p_product_id;
  end if;
end $function$;

create or replace function fabula.unlink_supplier_item(p_product_id uuid, p_supplier_id uuid)
 returns void language plpgsql security definer set search_path to 'fabula', 'public'
as $function$
declare v_next uuid;
begin
  perform fabula.require_perm('acquisti', 3);
  update fabula.supplier_products set active = false, updated_at = now() where supplier_id = p_supplier_id and product_id = p_product_id;
  if (select preferred_supplier_id from fabula.products where id = p_product_id) = p_supplier_id then
    select supplier_id into v_next from fabula.supplier_products where product_id = p_product_id and active order by updated_at desc limit 1;
    update fabula.products set preferred_supplier_id = v_next, updated_at = now() where id = p_product_id;
  end if;
end $function$;

-- manual order from the catalogue: one PO per supplier, owner-created so it goes straight to "Ordini da inviare"
-- p_lines: [{product_id, qty, price_eur?}]
create or replace function fabula.create_manual_po(p_supplier_id uuid, p_lines jsonb, p_notes text default null)
 returns jsonb language plpgsql security definer set search_path to 'fabula', 'public', 'extensions'
as $function$
declare v_date date := (now() at time zone 'Europe/Rome')::date; v_po uuid; v_no text; v_seq int; v_lead int; l jsonb;
        v_price numeric; v_iva numeric; v_sub numeric := 0; v_ivat numeric := 0; v_n int := 0; v_sup text; v_missing int := 0;
begin
  perform fabula.require_perm('acquisti', 2);
  select legal_name into v_sup from fabula.parties where id = p_supplier_id and active;
  if v_sup is null then raise exception 'Fornitore non trovato'; end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Nessuna riga da ordinare'; end if;
  select coalesce(max(t.lead_time_days), fabula.setting_num('purchasing.default_lead_days', 5)::int) into v_lead
    from fabula.supplier_products t where t.supplier_id = p_supplier_id and t.product_id in (select (x->>'product_id')::uuid from jsonb_array_elements(p_lines) x);
  select count(*) + 1 into v_seq from fabula.purchase_orders where order_date = v_date;
  loop
    v_no := 'PO-' || to_char(v_date, 'YYYYMMDD') || '-' || lpad(v_seq::text, 2, '0');
    exit when not exists (select 1 from fabula.purchase_orders where po_number = v_no);
    v_seq := v_seq + 1;
  end loop;
  insert into fabula.purchase_orders (po_number, supplier_id, status, order_date, expected_date, drafted_by, rationale, notes, source)
  values (v_no, p_supplier_id, 'approved', v_date, v_date + v_lead, 'human', 'Ordine manuale dal catalogo forniture', nullif(trim(p_notes), ''), 'console:catalogo')
  returning id into v_po;
  for l in select * from jsonb_array_elements(p_lines) loop
    if coalesce((l->>'qty')::numeric, 0) <= 0 then continue; end if;
    v_price := nullif(l->>'price_eur', '')::numeric;
    if v_price is null then
      select price_eur into v_price from fabula.supplier_prices where supplier_id = p_supplier_id and product_id = (l->>'product_id')::uuid and valid_from <= v_date order by valid_from desc, created_at desc limit 1;
    end if;
    if v_price is null then
      select price_eur into v_price from fabula.v_supplier_price_history where supplier_id = p_supplier_id and product_id = (l->>'product_id')::uuid and source = 'DDT' order by price_date desc limit 1;
    end if;
    if v_price is null then v_missing := v_missing + 1; end if;
    select coalesce(iva_rate, 22) into v_iva from fabula.products where id = (l->>'product_id')::uuid;
    insert into fabula.purchase_order_lines (purchase_order_id, product_id, qty_ordered, unit_price_eur, iva_rate)
    values (v_po, (l->>'product_id')::uuid, (l->>'qty')::numeric, coalesce(v_price, 0), v_iva);
    insert into fabula.supplier_products (supplier_id, product_id) values (p_supplier_id, (l->>'product_id')::uuid) on conflict do nothing;
    v_sub := v_sub + round((l->>'qty')::numeric * coalesce(v_price, 0), 2);
    v_ivat := v_ivat + round((l->>'qty')::numeric * coalesce(v_price, 0) * v_iva / 100, 2);
    v_n := v_n + 1;
  end loop;
  if v_n = 0 then raise exception 'Nessuna quantità maggiore di zero'; end if;
  update fabula.purchase_orders set subtotal_eur = v_sub, iva_eur = v_ivat, total_eur = v_sub + v_ivat where id = v_po;
  return jsonb_build_object('po_number', v_no, 'supplier', v_sup, 'lines', v_n, 'subtotal_eur', v_sub, 'expected_date', v_date + v_lead, 'price_missing', v_missing);
end $function$;

revoke execute on function fabula.add_supply_item(text, text, text, uuid, numeric, text) from public, anon;
revoke execute on function fabula.link_supplier_item(uuid, uuid, numeric, boolean) from public, anon;
revoke execute on function fabula.unlink_supplier_item(uuid, uuid) from public, anon;
revoke execute on function fabula.create_manual_po(uuid, jsonb, text) from public, anon;
grant execute on function fabula.add_supply_item(text, text, text, uuid, numeric, text) to authenticated;
grant execute on function fabula.link_supplier_item(uuid, uuid, numeric, boolean) to authenticated;
grant execute on function fabula.unlink_supplier_item(uuid, uuid) to authenticated;
grant execute on function fabula.create_manual_po(uuid, jsonb, text) to authenticated;

insert into supabase_migrations.schema_migrations (version, name) values ('20261012140000', 'v089a_supply_catalog') on conflict (version) do nothing;

commit;

-- check: expect 7 categories and 29 purchasable items (6 existing + 23 starter)
select (select count(*) from fabula.supply_categories) categories, (select count(*) from fabula.v_supply_catalog) items;
