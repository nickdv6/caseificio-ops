-- =============================================================================
-- v0.6: recipes (bill of materials) + automatic consumable deduction at batch close
--   * fabula.recipes: how much of each consumable a finished product uses,
--     per kg of milk in the vat, per kg of output, or per batch. Dated, so a
--     ratio change never rewrites history.
--   * When a batch is closed (output_kg goes from empty to a value) the trigger
--     writes batch_consumables + negative stock_moves from the active recipe.
--     The procurement bot then sees real consumption.
--   * fabula.correct_batch_consumable(): record what was actually used when it
--     differs from the recipe; posts the difference as an adjustment.
--   * fabula.v_recipe_variance: standard vs actual per batch, to tune ratios.
-- Ratios seeded here are PLACEHOLDERS (source = 'placeholder') — replace with
-- the Fabula team's real doses via fabula.set_recipe().
-- =============================================================================
set search_path = fabula, public;

do $$ begin
  create type fabula.recipe_basis as enum ('per_kg_milk','per_kg_output','per_batch');
exception when duplicate_object then null; end $$;

create table if not exists fabula.recipes (
  id                   uuid primary key default gen_random_uuid(),
  finished_product_id  uuid not null references fabula.products(id),
  component_product_id uuid not null references fabula.products(id),
  basis                fabula.recipe_basis not null,
  qty_per_unit         numeric(12,6) not null check (qty_per_unit >= 0),  -- in the component's unit
  round_up             boolean not null default false,                    -- true for countable items (bags, tubs)
  valid_from           date not null default current_date,
  valid_to             date,                                              -- null = still in force
  source               text not null default 'manual',                    -- placeholder | manual | measured
  notes                text,
  created_at           timestamptz not null default now(),
  unique (finished_product_id, component_product_id, valid_from)
);
create index if not exists recipes_active_idx on fabula.recipes (finished_product_id) where valid_to is null;

alter table fabula.batch_consumables
  add column if not exists recipe_id    uuid references fabula.recipes(id),
  add column if not exists qty_standard numeric(10,3),           -- what the recipe said
  add column if not exists entry        text not null default 'manual';  -- recipe | manual | corrected

-- Set or change a ratio: closes the current line and opens a new one from p_from
create or replace function fabula.set_recipe(p_finished_sku text, p_component_sku text, p_basis fabula.recipe_basis,
  p_qty numeric, p_round_up boolean default false, p_from date default current_date, p_source text default 'manual', p_notes text default null)
returns uuid language plpgsql as $$
declare v_fin uuid; v_comp uuid; v_id uuid;
begin
  select id into v_fin from fabula.products where sku = p_finished_sku;
  select id into v_comp from fabula.products where sku = p_component_sku;
  if v_fin is null or v_comp is null then raise exception 'SKU sconosciuto: % / %', p_finished_sku, p_component_sku; end if;
  update fabula.recipes set valid_to = p_from - 1
   where finished_product_id = v_fin and component_product_id = v_comp and valid_to is null and valid_from < p_from;
  delete from fabula.recipes where finished_product_id = v_fin and component_product_id = v_comp and valid_from = p_from;
  insert into fabula.recipes (finished_product_id, component_product_id, basis, qty_per_unit, round_up, valid_from, source, notes)
  values (v_fin, v_comp, p_basis, p_qty, p_round_up, p_from, p_source, p_notes) returning id into v_id;
  return v_id;
end $$;

-- Core: write consumption for one batch from its recipe (idempotent)
create or replace function fabula.apply_batch_recipe(p_batch_id uuid) returns int language plpgsql as $$
declare b record; r record; v_qty numeric; v_n int := 0; v_at timestamptz;
begin
  select * into b from fabula.production_batches where id = p_batch_id;
  if b is null or b.output_kg is null then return 0; end if;
  if exists (select 1 from fabula.batch_consumables where batch_id = p_batch_id) then return 0; end if;
  v_at := coalesce(b.finished_at, now());
  for r in
    select rc.*, p.unit, p.sku from fabula.recipes rc join fabula.products p on p.id = rc.component_product_id
    where rc.finished_product_id = b.product_id
      and rc.valid_from <= b.batch_date and (rc.valid_to is null or rc.valid_to >= b.batch_date)
  loop
    v_qty := r.qty_per_unit * case r.basis when 'per_kg_milk' then b.milk_in_kg when 'per_kg_output' then b.output_kg else 1 end;
    v_qty := case when r.round_up then ceil(v_qty) else round(v_qty, 3) end;
    continue when v_qty <= 0;
    insert into fabula.batch_consumables (batch_id, product_id, qty, recipe_id, qty_standard, entry)
    values (p_batch_id, r.component_product_id, v_qty, r.id, v_qty, 'recipe');
    insert into fabula.stock_moves (moved_at, product_id, qty, move_type, batch_id, source, reason)
    values (v_at, r.component_product_id, -v_qty, 'production_in', p_batch_id, 'recipe',
            format('Lotto %s: %s %s × %s %s', b.batch_lot, r.qty_per_unit, r.unit,
                   case r.basis when 'per_kg_milk' then b.milk_in_kg || ' kg latte' when 'per_kg_output' then b.output_kg || ' kg prodotto' else '1 lotto' end,
                   case when r.source = 'placeholder' then '(ricetta provvisoria)' else '' end));
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

create or replace function fabula.trg_batch_close_recipe() returns trigger language plpgsql as $$
begin
  if new.output_kg is not null and (tg_op = 'INSERT' or old.output_kg is null) and new.source <> 'simulation' then
    perform fabula.apply_batch_recipe(new.id);
  end if;
  return new;
end $$;
drop trigger if exists batch_close_recipe on fabula.production_batches;
create trigger batch_close_recipe after insert or update of output_kg on fabula.production_batches
  for each row execute function fabula.trg_batch_close_recipe();

-- Record actual use when it differs from the recipe; the delta goes to the ledger
create or replace function fabula.correct_batch_consumable(p_batch_lot text, p_component_sku text, p_actual_qty numeric, p_note text default null)
returns numeric language plpgsql as $$
declare v_batch uuid; v_comp uuid; v_cur numeric; v_delta numeric;
begin
  select id into v_batch from fabula.production_batches where batch_lot = p_batch_lot;
  select id into v_comp from fabula.products where sku = p_component_sku;
  if v_batch is null or v_comp is null then raise exception 'Lotto o SKU sconosciuto: % / %', p_batch_lot, p_component_sku; end if;
  select coalesce(sum(qty),0) into v_cur from fabula.batch_consumables where batch_id = v_batch and product_id = v_comp;
  v_delta := p_actual_qty - v_cur;
  if v_delta = 0 then return 0; end if;
  if exists (select 1 from fabula.batch_consumables where batch_id = v_batch and product_id = v_comp) then
    update fabula.batch_consumables set qty = p_actual_qty, entry = 'corrected' where id =
      (select id from fabula.batch_consumables where batch_id = v_batch and product_id = v_comp limit 1);
    delete from fabula.batch_consumables where batch_id = v_batch and product_id = v_comp and entry <> 'corrected';
  else
    insert into fabula.batch_consumables (batch_id, product_id, qty, entry) values (v_batch, v_comp, p_actual_qty, 'manual');
  end if;
  insert into fabula.stock_moves (product_id, qty, move_type, batch_id, source, reason)
  values (v_comp, -v_delta, 'adjustment', v_batch, 'correction',
          format('Lotto %s: consumo effettivo %s (ricetta %s)%s', p_batch_lot, p_actual_qty, v_cur, coalesce(' — ' || p_note, '')));
  return v_delta;
end $$;

-- Standard vs actual, per batch and component
create or replace view fabula.v_recipe_variance as
select b.batch_date, b.batch_lot, fp.sku as product_sku, cp.sku as component_sku, cp.unit,
       b.milk_in_kg, b.output_kg, bc.qty_standard, bc.qty as qty_actual,
       bc.qty - bc.qty_standard as variance,
       round((bc.qty - bc.qty_standard) / nullif(bc.qty_standard,0) * 100, 1) as variance_pct, bc.entry
from fabula.batch_consumables bc
join fabula.production_batches b on b.id = bc.batch_id
join fabula.products fp on fp.id = b.product_id
join fabula.products cp on cp.id = bc.product_id;

grant select, insert, update on fabula.recipes to authenticated;
grant select, insert, update, delete on fabula.recipes to service_role;
grant select on fabula.v_recipe_variance to authenticated, service_role;
grant execute on function fabula.set_recipe(text,text,fabula.recipe_basis,numeric,boolean,date,text,text),
                          fabula.apply_batch_recipe(uuid),
                          fabula.correct_batch_consumable(text,text,numeric,text) to authenticated, service_role;
alter table fabula.recipes enable row level security;
drop policy if exists recipes_staff on fabula.recipes;
create policy recipes_staff on fabula.recipes for all to authenticated using (true) with check (true);

-- Placeholder ratios for mozzarella (same as the simulation) — REPLACE with real doses
select fabula.set_recipe('MOZ-DOP-KG','CON-SALT',   'per_kg_milk',   0.0028,  false, date '2026-01-01', 'placeholder', '2,8 g/kg latte — da confermare (salamoia o sale a secco?)');
select fabula.set_recipe('MOZ-DOP-KG','CON-RENNET', 'per_kg_milk',   0.00025, false, date '2026-01-01', 'placeholder', '25 ml/100 kg latte — dipende dal titolo del caglio');
select fabula.set_recipe('MOZ-DOP-KG','PKG-BAG-500','per_kg_output', 1.2,     true,  date '2026-01-01', 'placeholder', 'mix formati da confermare (busta 500 g = 2/kg)');
