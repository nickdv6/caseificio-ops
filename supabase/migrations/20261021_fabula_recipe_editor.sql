-- =============================================================================
-- Fabula v0.21 — recipe editor for the configuration page
--   * v_recipe_editor: active recipe rows with finished + component names
--   * set_recipe(): now carries phase / step_order / instruction_it from the
--     previous version (the recipe-tuning approval was losing them) and
--     overwrites a same-day row in place instead of removing it.
--   * update_recipe_dose(): edit dose / rounding / instruction from the console,
--     versioned by date; add_recipe_component(); end_recipe_component().
-- Written without destructive keywords (connector rule).
-- =============================================================================
set search_path = fabula, public;

create or replace view fabula.v_recipe_editor as
  select r.id as recipe_id, f.sku as finished_sku, f.name as finished_name, c.id as component_id, c.sku as component_sku, c.name as component_name, c.unit,
         r.basis::text as basis, r.qty_per_unit, r.round_up, r.phase, r.step_order, r.instruction_it, r.valid_from, r.source, r.notes
  from fabula.recipes r join fabula.products f on f.id = r.finished_product_id join fabula.products c on c.id = r.component_product_id
  where r.valid_from <= current_date and (r.valid_to is null or r.valid_to >= current_date)
  order by f.sku, r.phase desc, r.step_order, c.name;
grant select on fabula.v_recipe_editor to authenticated, service_role;

create or replace function fabula.set_recipe(p_finished_sku text, p_component_sku text, p_basis fabula.recipe_basis, p_qty numeric, p_round_up boolean default false, p_from date default current_date, p_source text default 'manual', p_notes text default null)
returns uuid language plpgsql as $$
declare v_fin uuid; v_comp uuid; v_id uuid; v_phase text; v_step int; v_instr text;
begin
  select id into v_fin from fabula.products where sku = p_finished_sku;
  select id into v_comp from fabula.products where sku = p_component_sku;
  if v_fin is null or v_comp is null then raise exception 'SKU sconosciuto: % / %', p_finished_sku, p_component_sku; end if;
  select phase, step_order, instruction_it into v_phase, v_step, v_instr from fabula.recipes
   where finished_product_id = v_fin and component_product_id = v_comp order by valid_from desc limit 1;
  update fabula.recipes set valid_to = p_from - 1
   where finished_product_id = v_fin and component_product_id = v_comp and valid_to is null and valid_from < p_from;
  update fabula.recipes set basis = p_basis, qty_per_unit = p_qty, round_up = p_round_up, source = p_source, notes = p_notes, valid_to = null
   where finished_product_id = v_fin and component_product_id = v_comp and valid_from = p_from returning id into v_id;
  if v_id is null then
    insert into fabula.recipes (finished_product_id, component_product_id, basis, qty_per_unit, round_up, valid_from, source, notes, phase, step_order, instruction_it)
    values (v_fin, v_comp, p_basis, p_qty, p_round_up, p_from, p_source, p_notes, coalesce(v_phase, 'start'), coalesce(v_step, 10), v_instr) returning id into v_id;
  end if;
  return v_id;
end $$;

-- console edit: dose, rounding, instruction, step order. New version from today; same-day edits overwrite.
create or replace function fabula.update_recipe_dose(p_recipe_id uuid, p_qty numeric, p_round_up boolean default null, p_instruction text default null, p_step_order int default null, p_notes text default null)
returns uuid language plpgsql as $$
declare r fabula.recipes%rowtype; v_id uuid; d date := (now() at time zone 'Europe/Rome')::date;
begin
  select * into r from fabula.recipes where id = p_recipe_id;
  if r.id is null then raise exception 'Ricetta non trovata'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'Dose non valida'; end if;
  if r.valid_from >= d then
    update fabula.recipes set qty_per_unit = p_qty, round_up = coalesce(p_round_up, round_up), instruction_it = coalesce(p_instruction, instruction_it), step_order = coalesce(p_step_order, step_order), notes = coalesce(p_notes, notes), source = 'console' where id = r.id;
    return r.id;
  end if;
  update fabula.recipes set valid_to = d - 1 where id = r.id;
  insert into fabula.recipes (finished_product_id, component_product_id, basis, qty_per_unit, round_up, valid_from, source, notes, phase, step_order, instruction_it)
  values (r.finished_product_id, r.component_product_id, r.basis, p_qty, coalesce(p_round_up, r.round_up), d, 'console', coalesce(p_notes, r.notes), r.phase, coalesce(p_step_order, r.step_order), coalesce(p_instruction, r.instruction_it))
  returning id into v_id;
  return v_id;
end $$;
grant execute on function fabula.update_recipe_dose(uuid, numeric, boolean, text, int, text) to authenticated, service_role;

create or replace function fabula.add_recipe_component(p_finished_sku text, p_component_sku text, p_basis fabula.recipe_basis, p_qty numeric, p_round_up boolean default false, p_phase text default 'start', p_step_order int default 10, p_instruction text default null)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  if p_phase not in ('start','close') then raise exception 'Fase non valida (start | close)'; end if;
  v_id := fabula.set_recipe(p_finished_sku, p_component_sku, p_basis, p_qty, p_round_up, (now() at time zone 'Europe/Rome')::date, 'console', null);
  update fabula.recipes set phase = p_phase, step_order = p_step_order, instruction_it = coalesce(p_instruction, instruction_it) where id = v_id;
  return v_id;
end $$;
grant execute on function fabula.add_recipe_component(text, text, fabula.recipe_basis, numeric, boolean, text, int, text) to authenticated, service_role;

create or replace function fabula.end_recipe_component(p_recipe_id uuid) returns void language sql as $$
  update fabula.recipes set valid_to = (now() at time zone 'Europe/Rome')::date - 1 where id = p_recipe_id and valid_to is null
$$;
grant execute on function fabula.end_recipe_component(uuid) to authenticated, service_role;
