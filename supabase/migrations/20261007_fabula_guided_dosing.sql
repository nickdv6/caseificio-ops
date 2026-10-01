-- =============================================================================
-- v0.7: guided dosing on the tablet
--   * recipes get a phase (start = at the vat, close = at packing), a step order
--     and an instruction line shown to the casaro.
--   * v_recipe_active: what the tablet reads to compute each dose.
--   * record_batch_consumable(): one call per confirmed step — stores the actual
--     and the standard dose, who confirmed, when, and posts the stock move.
--     Calling it again for the same step corrects instead of double counting.
--   * apply_batch_recipe() now fills only the steps NOT confirmed on the tablet
--     (fallback at batch close), so stock stays right even if a step is skipped;
--     those show up as unconfirmed in v_recipe_variance.
-- =============================================================================
set search_path = fabula, public;

alter table fabula.recipes
  add column if not exists phase          text not null default 'start' check (phase in ('start','close')),
  add column if not exists step_order     int  not null default 10,
  add column if not exists instruction_it text;

alter table fabula.batch_consumables
  add column if not exists confirmed_at    timestamptz,
  add column if not exists confirmed_by_id uuid references fabula.staff(id);

update fabula.recipes r set phase = 'start', step_order = 10, instruction_it = 'Pesa il caglio e aggiungilo al latte in caldaia, mescola bene.'
  from fabula.products p where p.id = r.component_product_id and p.sku = 'CON-RENNET' and r.instruction_it is null;
update fabula.recipes r set phase = 'start', step_order = 20, instruction_it = 'Pesa il sale e tienilo pronto per la filatura / salamoia.'
  from fabula.products p where p.id = r.component_product_id and p.sku = 'CON-SALT' and r.instruction_it is null;
update fabula.recipes r set phase = 'close', step_order = 10, instruction_it = 'Prepara le buste per il confezionamento.'
  from fabula.products p where p.id = r.component_product_id and p.sku = 'PKG-BAG-500' and r.instruction_it is null;

create or replace view fabula.v_recipe_active as
select r.id as recipe_id, r.finished_product_id, p.sku, p.name, p.unit, r.basis, r.qty_per_unit, r.round_up,
       r.phase, r.step_order, r.instruction_it, r.source
from fabula.recipes r join fabula.products p on p.id = r.component_product_id
where r.valid_from <= current_date and (r.valid_to is null or r.valid_to >= current_date);
grant select on fabula.v_recipe_active to authenticated, service_role;

create or replace function fabula.record_batch_consumable(p_batch_lot text, p_sku text, p_qty numeric, p_qty_standard numeric, p_staff_id uuid default null)
returns text language plpgsql as $$
declare b record; v_comp uuid; v_rec uuid;
begin
  select * into b from fabula.production_batches where batch_lot = p_batch_lot;
  select id into v_comp from fabula.products where sku = p_sku;
  if b is null or v_comp is null then raise exception 'Lotto o SKU sconosciuto: % / %', p_batch_lot, p_sku; end if;
  if exists (select 1 from fabula.batch_consumables where batch_id = b.id and product_id = v_comp) then
    perform fabula.correct_batch_consumable(p_batch_lot, p_sku, p_qty, 'riconferma da tablet');
    update fabula.batch_consumables set confirmed_at = now(), confirmed_by_id = coalesce(p_staff_id, confirmed_by_id),
           qty_standard = coalesce(qty_standard, p_qty_standard)
     where batch_id = b.id and product_id = v_comp;
    return 'corrected';
  end if;
  select id into v_rec from fabula.recipes
   where finished_product_id = b.product_id and component_product_id = v_comp
     and valid_from <= b.batch_date and (valid_to is null or valid_to >= b.batch_date)
   order by valid_from desc limit 1;
  insert into fabula.batch_consumables (batch_id, product_id, qty, recipe_id, qty_standard, entry, confirmed_at, confirmed_by_id)
  values (b.id, v_comp, p_qty, v_rec, p_qty_standard, case when p_qty = p_qty_standard then 'confirmed' else 'corrected' end, now(), p_staff_id);
  insert into fabula.stock_moves (product_id, qty, move_type, batch_id, source, reason)
  values (v_comp, -p_qty, 'production_in', b.id, 'tablet',
          format('Lotto %s: dosato e confermato %s (ricetta %s)', p_batch_lot, p_qty, p_qty_standard));
  return 'recorded';
end $$;
grant execute on function fabula.record_batch_consumable(text,text,numeric,numeric,uuid) to authenticated, service_role;

-- Fallback at close: only components not already confirmed
create or replace function fabula.apply_batch_recipe(p_batch_id uuid) returns int language plpgsql as $$
declare b record; r record; v_qty numeric; v_n int := 0; v_at timestamptz;
begin
  select * into b from fabula.production_batches where id = p_batch_id;
  if b is null or b.output_kg is null then return 0; end if;
  v_at := coalesce(b.finished_at, now());
  for r in
    select rc.*, p.unit, p.sku from fabula.recipes rc join fabula.products p on p.id = rc.component_product_id
    where rc.finished_product_id = b.product_id
      and rc.valid_from <= b.batch_date and (rc.valid_to is null or rc.valid_to >= b.batch_date)
      and not exists (select 1 from fabula.batch_consumables bc where bc.batch_id = p_batch_id and bc.product_id = rc.component_product_id)
  loop
    v_qty := r.qty_per_unit * case r.basis when 'per_kg_milk' then b.milk_in_kg when 'per_kg_output' then b.output_kg else 1 end;
    v_qty := case when r.round_up then ceil(v_qty) else round(v_qty, 3) end;
    continue when v_qty <= 0;
    insert into fabula.batch_consumables (batch_id, product_id, qty, recipe_id, qty_standard, entry)
    values (p_batch_id, r.component_product_id, v_qty, r.id, v_qty, 'recipe');
    insert into fabula.stock_moves (moved_at, product_id, qty, move_type, batch_id, source, reason)
    values (v_at, r.component_product_id, -v_qty, 'production_in', p_batch_id, 'recipe',
            format('Lotto %s: NON confermato su tablet, scaricato da ricetta %s %s × %s %s', b.batch_lot, r.qty_per_unit, r.unit,
                   case r.basis when 'per_kg_milk' then b.milk_in_kg || ' kg latte' when 'per_kg_output' then b.output_kg || ' kg prodotto' else '1 lotto' end,
                   case when r.source = 'placeholder' then '(ricetta provvisoria)' else '' end));
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

create or replace view fabula.v_recipe_variance as
select b.batch_date, b.batch_lot, fp.sku as product_sku, cp.sku as component_sku, cp.unit,
       b.milk_in_kg, b.output_kg, bc.qty_standard, bc.qty as qty_actual,
       bc.qty - bc.qty_standard as variance,
       round((bc.qty - bc.qty_standard) / nullif(bc.qty_standard,0) * 100, 1) as variance_pct, bc.entry,
       bc.confirmed_at, s.full_name as confirmed_by
from fabula.batch_consumables bc
join fabula.production_batches b on b.id = bc.batch_id
join fabula.products fp on fp.id = b.product_id
join fabula.products cp on cp.id = bc.product_id
left join fabula.staff s on s.id = bc.confirmed_by_id;
grant select on fabula.v_recipe_variance to authenticated, service_role;
