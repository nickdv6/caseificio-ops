-- =============================================================================
-- v0.8: by-product sequence — mozzarella whey → ricotta
--   * products.byproduct_product_id: what a product's whey becomes (MOZ → RIC).
--   * production_batches.parent_batch_id + input_kind ('milk' | 'whey'):
--     a ricotta batch points at the mozzarella batch whose whey it used, and its
--     milk_in_kg holds the kg of whey in the vat (recipe basis per_kg_milk = per
--     kg of whatever went in the vat).
--   * start_byproduct_batch(parent_lot, whey_kg, staff): creates the ricotta
--     batch (lot R + parent lot suffix, e.g. L20261002-A → R20261002-A),
--     records whey on the parent, prints the lot label. Idempotent.
--   * Ricotta recipe + two new items (acido citrico, fuscella 250 g) — PLACEHOLDERS.
-- =============================================================================
set search_path = fabula, public;

alter table fabula.products add column if not exists byproduct_product_id uuid references fabula.products(id);
alter table fabula.production_batches
  add column if not exists parent_batch_id uuid references fabula.production_batches(id),
  add column if not exists input_kind text not null default 'milk' check (input_kind in ('milk','whey'));
create index if not exists production_batches_parent_idx on fabula.production_batches (parent_batch_id);

update fabula.products set byproduct_product_id = (select id from fabula.products where sku = 'RIC-BUF-KG') where sku = 'MOZ-DOP-KG';

insert into fabula.products (sku, name, kind, unit, is_dop, iva_rate)
select * from (values ('CON-CITRIC', 'Acido citrico', 'consumable'::fabula.product_kind, 'kg', false, 22.00::numeric),
                      ('PKG-FUSC-250', 'Fuscella ricotta 250 g', 'packaging'::fabula.product_kind, 'pz', false, 22.00::numeric)) v(sku, name, kind, unit, is_dop, iva_rate)
where not exists (select 1 from fabula.products p where p.sku = v.sku);

create or replace function fabula.start_byproduct_batch(p_parent_lot text, p_whey_kg numeric, p_staff_id uuid default null)
returns text language plpgsql as $$
declare par record; v_prod uuid; v_lot text; v_id uuid; v_name text;
begin
  select * into par from fabula.production_batches where batch_lot = p_parent_lot;
  if par is null then raise exception 'Lotto sconosciuto: %', p_parent_lot; end if;
  select byproduct_product_id into v_prod from fabula.products where id = par.product_id;
  if v_prod is null then raise exception 'Nessun sottoprodotto definito per il lotto %', p_parent_lot; end if;
  v_lot := 'R' || substr(p_parent_lot, 2);
  if exists (select 1 from fabula.production_batches where batch_lot = v_lot) then return v_lot; end if;
  select full_name into v_name from fabula.staff where id = p_staff_id;
  update fabula.production_batches set whey_kg = p_whey_kg where id = par.id;
  insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, input_kind, parent_batch_id, started_at, casaro, casaro_id, source)
  values (par.batch_date, v_lot, v_prod, p_whey_kg, 'whey', par.id, now(), v_name, p_staff_id, 'tablet') returning id into v_id;
  insert into fabula.labels (kind, code, lot_number, product_id, batch_id, qty_printed, printed_by_id)
  values ('batch_lot', 'LOT:' || v_lot, v_lot, v_prod, v_id, 1, p_staff_id);
  return v_lot;
end $$;
grant execute on function fabula.start_byproduct_batch(text, numeric, uuid) to authenticated, service_role;

-- Ricotta placeholder recipe (per kg of whey in the vat / per kg ricotta out)
select fabula.set_recipe('RIC-BUF-KG','CON-CITRIC',  'per_kg_milk',   0.0005, false, date '2026-01-01', 'placeholder', '0,5 g/kg siero — da confermare (acido citrico o siero acido/agra?)');
select fabula.set_recipe('RIC-BUF-KG','CON-SALT',    'per_kg_milk',   0.002,  false, date '2026-01-01', 'placeholder', '2 g/kg siero — da confermare');
select fabula.set_recipe('RIC-BUF-KG','PKG-FUSC-250','per_kg_output', 4,      true,  date '2026-01-01', 'placeholder', '4 fuscelle da 250 g per kg — da confermare formati');
update fabula.recipes r set phase = 'start', step_order = 10, instruction_it = 'Quando il siero è in temperatura, aggiungi l''acido citrico.'
  from fabula.products p where p.id = r.component_product_id and p.sku = 'CON-CITRIC' and r.finished_product_id = (select id from fabula.products where sku = 'RIC-BUF-KG');
update fabula.recipes r set phase = 'start', step_order = 20, instruction_it = 'Pesa il sale e aggiungilo al siero.'
  from fabula.products p where p.id = r.component_product_id and p.sku = 'CON-SALT' and r.finished_product_id = (select id from fabula.products where sku = 'RIC-BUF-KG');
update fabula.recipes r set phase = 'close', step_order = 10, instruction_it = 'Prepara le fuscelle per la ricotta.'
  from fabula.products p where p.id = r.component_product_id and p.sku = 'PKG-FUSC-250' and r.finished_product_id = (select id from fabula.products where sku = 'RIC-BUF-KG');
