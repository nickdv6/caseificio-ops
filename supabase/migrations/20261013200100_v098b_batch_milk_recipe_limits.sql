-- v0.98b · Audit 12/10/2026, numbers and limits: production, milk, recipes, dosing, goods receipt, farm page.
--   D-06   A batch's yield must be possible (mozzarella 10–45 %, ricotta 2–25 %, settings prod.*yield_min/max_pct). Above the
--          maximum it is refused («Resa 200 %: impossibile… controlla i kg»); below the minimum it needs the reason of the loss.
--          The milk in a vat is at most the vat (prod.vat_kg) + 10 %; the whey for ricotta at most 95 % of the vat it came from
--          (D-30). correct_batch_milk() fixes the milk kg of a lot (with a reason), the milk it took and the raw-milk stock, so a
--          wrong start is not a dead end at the close.
--   D-07   Milk arrival: the database rejects milk over the CCP 1a limit itself (the tablet only shows it); temperature, kg, fat,
--          protein, pH and cells have physical limits, with Italian messages on the tablet.
--   D-27 / B-14  A recipe dose changed more than 2 times up or down needs an explicit confirmation and a reason; 0 is refused.
--          A same-day change keeps the previous value in the notes.
--   D-20   Units are written one way (kg, g, l, ml, pz or the name of the pack); an item in a recipe cannot change unit, be
--          archived or stop being counted until the recipe stops using it.
--   D-19   Dosing: a negative dose is refused; more than 3 times or under a third of the recipe needs a confirmation; the lot of
--          the pack used (rennet, cultures, salt) is kept; a closed batch takes no more doses.
--   D-18   Goods receipt: expired goods are refused; more than 3 times what is still to arrive, or a DDT price outside ±50 % of the
--          list, needs a confirmation.
--   FARM-07 The farm page gets the CCP 1a limits (alert and rejection) to warn before shipping.
-- Every «needs a confirmation» is an error with HINT 'confirm': the tablet and the console ask, then send p_confirm = true.

-- ============================================================================================================================
-- 1. D-06 / D-30 · bounds on a batch
-- ============================================================================================================================
alter table fabula.production_batches add column if not exists yield_note text;
comment on column fabula.production_batches.yield_note is 'v0.98 (audit D-06): why a yield is below prod.yield_min_pct (part of the batch lost)';

create or replace function fabula.trg_batch_bounds() returns trigger language plpgsql set search_path = fabula, public as $$
declare v_whey boolean := new.input_kind = 'whey'; v_vat numeric; v_par record; v_y numeric; v_lo numeric; v_hi numeric; v_what text;
begin
  if coalesce(new.source, '') in ('simulation', 'test') then return new; end if;
  if tg_op = 'INSERT' or new.milk_in_kg is distinct from old.milk_in_kg then
    if not v_whey then
      v_vat := fabula.setting_num('prod.vat_kg', null);
      if v_vat is not null and new.milk_in_kg > v_vat * 1.1 then
        raise exception using errcode = '23514', message = format(
          'Latte in caldaia %s kg: una caldaia ne tiene al massimo %s kg (Latte per lotto %s kg, +10 %%). Controlla i kg (senza punto: 310, non 3.100).',
          fabula._it_num(new.milk_in_kg), fabula._it_num(round(v_vat * 1.1)), fabula._it_num(v_vat));
      end if;
    elsif new.parent_batch_id is not null then
      select batch_lot, milk_in_kg into v_par from fabula.production_batches where id = new.parent_batch_id;
      if v_par.milk_in_kg is not null and new.milk_in_kg > v_par.milk_in_kg * 0.95 then
        raise exception using errcode = '23514', message = format('Siero per la ricotta %s kg: non può superare il latte della caldaia %s (%s kg). Controlla i kg.',
          fabula._it_num(new.milk_in_kg), v_par.batch_lot, fabula._it_num(v_par.milk_in_kg));
      end if;
    end if;
  end if;
  if new.output_kg is not null and new.milk_in_kg > 0
     and (tg_op = 'INSERT' or new.output_kg is distinct from old.output_kg or new.milk_in_kg is distinct from old.milk_in_kg) then
    v_y := round(new.output_kg / new.milk_in_kg * 100, 1);
    if v_whey then v_lo := fabula.setting_num('prod.ricotta_yield_min_pct', 2); v_hi := fabula.setting_num('prod.ricotta_yield_max_pct', 25); v_what := 'siero';
    else v_lo := fabula.setting_num('prod.yield_min_pct', 10); v_hi := fabula.setting_num('prod.yield_max_pct', 45); v_what := 'latte'; end if;
    if v_y > v_hi then
      raise exception using errcode = '23514', message = format(
        'Resa %s %%: impossibile (al massimo %s %%). Controlla i kg di %s (%s) e i kg prodotti (%s).',
        fabula._it_num(v_y), fabula._it_num(v_hi), v_what, fabula._it_num(new.milk_in_kg), fabula._it_num(new.output_kg));
    end if;
    if v_y < v_lo and length(trim(coalesce(new.yield_note, ''))) < 3 then
      raise exception using errcode = '23514', message = format(
        'Resa %s %%: troppo bassa per un lotto normale (di solito almeno %s %%). Controlla i kg di %s (%s) e i kg prodotti (%s); se una parte è andata persa, scrivi cosa è successo.',
        fabula._it_num(v_y), fabula._it_num(v_lo), v_what, fabula._it_num(new.milk_in_kg), fabula._it_num(new.output_kg));
    end if;
  end if;
  return new;
end $$;
revoke all on function fabula.trg_batch_bounds() from public, anon, authenticated;
drop trigger if exists batch_yield_bounds on fabula.production_batches;
create trigger batch_yield_bounds before insert or update of milk_in_kg, output_kg, yield_note on fabula.production_batches
  for each row execute function fabula.trg_batch_bounds();

-- the yield note can be written at the close like the other close fields (the closed-lot guard of v0.96 lists what may change)
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.trg_batch_closed_guard()'::regprocedure);
  n := replace(d, $s$'hold_released_by_id','hold_at','yield_expected_pct','yield_flag',$s$, $s$'hold_released_by_id','hold_at','yield_expected_pct','yield_flag','yield_note',$s$);
  if n = d then raise exception 'v098b: trg_batch_closed_guard free list not found'; end if;
  execute n;
end $mig$;

-- the milk of a lot was typed wrong (31 for 310): fixed with a reason, together with the milk it took and the raw-milk stock
create or replace function fabula.correct_batch_milk(p_batch_lot text, p_milk_kg numeric, p_reason text, p_staff_id uuid default null, p_yield_note text default null)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
-- the person who corrects is the operator the tablet sends (the shared login is the device's: audit A-01), if active
declare b fabula.production_batches%rowtype; v_name text; v_when text; v_own boolean; n int; i record; v_lot text; v_raw uuid;
        v_by uuid := coalesce((select id from fabula.staff where id = p_staff_id and active), fabula.my_staff_id());
begin
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Scrivi il motivo della correzione (es. errore di battitura)' using errcode = '22023'; end if;
  if p_milk_kg is null or p_milk_kg <= 0 then raise exception 'Scrivi i kg giusti' using errcode = '22023'; end if;
  select * into b from fabula.production_batches where batch_lot = upper(trim(p_batch_lot)) for update;
  if b.id is null then raise exception 'Lotto sconosciuto: %', p_batch_lot using errcode = '22023'; end if;
  -- an open lot: whoever produces (it is being closed); a closed one: its casaro within 15 minutes, else the production manager
  v_own := b.output_kg is null or (b.casaro_id = v_by and coalesce(b.finished_at, b.created_at) > now() - interval '15 minutes');
  perform fabula.require_perm('produzione', case when v_own then 2 else 3 end);
  if p_milk_kg = b.milk_in_kg then return jsonb_build_object('ok', true, 'batch_lot', b.batch_lot, 'milk_in_kg', b.milk_in_kg, 'unchanged', true); end if;
  select full_name into v_name from fabula.staff where id = v_by;
  v_when := to_char(now() at time zone 'Europe/Rome', 'DD/MM HH24:MI');
  perform set_config('fabula.correct_ctx', 'on', true);
  if b.input_kind = 'milk' then
    select count(*) into n from fabula.batch_milk_inputs where batch_id = b.id;
    if n > 1 then raise exception 'Il lotto % usa il latte di % consegne: per correggere i kg chiama il responsabile produzione', b.batch_lot, n using errcode = '22023'; end if;
    if n = 1 then
      select * into i from fabula.batch_milk_inputs where batch_id = b.id;
      update fabula.batch_milk_inputs set qty_kg = p_milk_kg where batch_id = b.id and milk_intake_id = i.milk_intake_id;   -- batch_milk_left checks what is left
      select milk_lot into v_lot from fabula.milk_intake where id = i.milk_intake_id;
      select id into v_raw from fabula.products where sku = 'RAW-MILK';
      if v_raw is not null then
        insert into fabula.stock_moves (product_id, lot_number, qty, move_type, reason, source)
        values (v_raw, v_lot, i.qty_kg - p_milk_kg, 'adjustment', format('Correzione kg in caldaia lotto %s: %s', b.batch_lot, trim(p_reason)), 'tablet');
      end if;
    end if;
  end if;
  update fabula.production_batches
     set milk_in_kg = p_milk_kg, yield_note = coalesce(nullif(trim(p_yield_note), ''), yield_note),
         notes = concat_ws(E'\n', notes, format('[%s] %s in caldaia corretto da %s: %s → %s kg (%s)', v_when, case when b.input_kind = 'whey' then 'siero' else 'latte' end,
                                                coalesce(v_name, 'utente'), fabula._it_num(b.milk_in_kg), fabula._it_num(p_milk_kg), trim(p_reason)))
   where id = b.id;
  perform set_config('fabula.correct_ctx', '', true);
  insert into fabula.record_corrections (table_name, row_id, changes, reason, corrected_by_id, corrected_by)
  values ('production_batches', b.id, jsonb_build_object('milk_in_kg', jsonb_build_array(b.milk_in_kg, p_milk_kg)), trim(p_reason), v_by, v_name);
  return jsonb_build_object('ok', true, 'batch_lot', b.batch_lot, 'milk_in_kg', p_milk_kg, 'was_kg', b.milk_in_kg);
end $$;
revoke all on function fabula.correct_batch_milk(text, numeric, text, uuid, text) from public, anon;
grant execute on function fabula.correct_batch_milk(text, numeric, text, uuid, text) to authenticated, service_role;

-- a closed lot corrected to a low yield («Correggi» in Autocontrollo) can say what was lost
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.correct_record(text,uuid,jsonb,text,uuid)'::regprocedure);
  n := replace(d, $s$when 'production_batches' then array['output_kg','curd_ph','whey_kg']$s$,
                  $s$when 'production_batches' then array['output_kg','curd_ph','whey_kg','yield_note']$s$);
  n := replace(n, $s$           whey_kg = case when p_changes ? 'whey_kg' then (p_changes ->> 'whey_kg')::numeric else whey_kg end,$s$,
                  $s$           whey_kg = case when p_changes ? 'whey_kg' then (p_changes ->> 'whey_kg')::numeric else whey_kg end,
           yield_note = case when p_changes ? 'yield_note' then nullif(trim(p_changes ->> 'yield_note'), '') else yield_note end,   -- v0.98 (D-06)$s$);
  if position('''yield_note'']' in n) = 0 or position('yield_note = case when p_changes' in n) = 0 then raise exception 'v098b: correct_record patterns not found'; end if;
  execute n;
end $mig$;

-- the tablet sends it in the same atomic save as the close (offline too)
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.save_ops(jsonb,uuid,timestamptz,timestamptz)'::regprocedure);
  n := replace(d, $s$'log_batch_step','record_batch_consumable','log_milk_check','badge_in','badge_out'];$s$,
                  $s$'log_batch_step','record_batch_consumable','log_milk_check','badge_in','badge_out','correct_batch_milk'];$s$);
  n := replace(n, $s$when 'badge_out' then 'fine turno' else v_label end;$s$,
                  $s$when 'badge_out' then 'fine turno' when 'correct_batch_milk' then 'correzione dei kg in caldaia' else v_label end;$s$);
  if position('''correct_batch_milk''];' in n) = 0 or position('correzione dei kg in caldaia' in n) = 0 then raise exception 'v098b: save_ops patterns not found'; end if;
  execute n;
end $mig$;

-- ============================================================================================================================
-- 2. D-07 · milk arrival: the database decides the rejection, and readings have physical limits
-- ============================================================================================================================
create or replace function fabula.trg_milk_accept_decide() returns trigger language plpgsql set search_path = fabula, public as $$
declare v_max numeric;
begin
  if new.accepted is false or new.temperature_c is null then return new; end if;
  select max_value into v_max from fabula.haccp_control_points where code = 'CCP-MILK-TEMP' and active;
  if v_max is not null and new.temperature_c > v_max then
    new.accepted := false;
    new.rejection_reason := concat_ws(' · ', nullif(new.rejection_reason, ''),
      format('temperatura %s °C oltre il limite di %s °C', fabula._it_num(new.temperature_c), fabula._it_num(v_max)));
  end if;
  return new;
end $$;
revoke all on function fabula.trg_milk_accept_decide() from public, anon, authenticated;
drop trigger if exists milk_intake_accept_decide on fabula.milk_intake;
create trigger milk_intake_accept_decide before insert on fabula.milk_intake for each row execute function fabula.trg_milk_accept_decide();

do $mig$
declare c record;
begin
  for c in select * from (values
      ('milk_intake_temperature_range', 'temperature_c is null or temperature_c between -2 and 45', 'Temperatura del latte impossibile: si legge tra −2 e 45 °C. Controlla la virgola (4,5 non 45).'),
      ('milk_intake_qty_max', 'qty_kg <= 5000', 'Più di 5.000 kg di latte in una consegna: controlla i kg (scrivili senza punto: 1200).'),
      ('milk_intake_fat_range', 'fat_pct is null or fat_pct between 3 and 15', 'Grasso del latte impossibile: tra il 3 e il 15 %. Controlla la virgola.'),
      ('milk_intake_protein_range', 'protein_pct is null or protein_pct between 2 and 8', 'Proteine del latte impossibili: tra il 2 e l''8 %. Controlla la virgola.'),
      ('milk_intake_ph_range', 'ph is null or ph between 5.5 and 7.5', 'pH del latte impossibile: tra 5,5 e 7,5. Controlla la virgola.'),
      ('milk_intake_scc_range', 'scc_cells_ml is null or scc_cells_ml between 0 and 10000000', 'Cellule somatiche impossibili: tra 0 e 10.000.000 per ml.')
    ) v(name, expr, msg) loop
    if not exists (select 1 from pg_constraint where conname = c.name and conrelid = 'fabula.milk_intake'::regclass) then
      execute format('alter table fabula.milk_intake add constraint %I check (%s) not valid', c.name, c.expr);
      begin
        execute format('alter table fabula.milk_intake validate constraint %I', c.name);
      exception when check_violation then
        raise notice 'v098b: some milk deliveries are outside «%»: new ones are checked, old ones stay as they are', c.name;
      end;
    end if;
    execute format('comment on constraint %I on fabula.milk_intake is %L', c.name, c.msg);
  end loop;
end $mig$;

-- ============================================================================================================================
-- 3. D-27 / B-14 · recipe doses
-- ============================================================================================================================
drop function if exists fabula.update_recipe_dose(uuid, numeric, boolean, text, integer, text);
create or replace function fabula.update_recipe_dose(p_recipe_id uuid, p_qty numeric, p_round_up boolean default null, p_instruction text default null,
                                                     p_step_order integer default null, p_notes text default null, p_confirm boolean default false)
returns uuid language plpgsql set search_path = fabula, public, extensions as $$
declare r fabula.recipes%rowtype; v_id uuid; d date := (now() at time zone 'Europe/Rome')::date; v_ratio numeric; v_comp text; v_unit text; v_log text;
begin
  select * into r from fabula.recipes where id = p_recipe_id;
  if r.id is null then raise exception 'Ricetta non trovata' using errcode = '22023'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'Dose non valida: scrivi una quantità maggiore di zero (per togliere il componente usa «Togli»)' using errcode = '22023'; end if;
  select name, unit into v_comp, v_unit from fabula.products where id = r.component_product_id;
  -- v0.98 (audit D-27/B-14): 2 times up or down is almost always a comma or a zero too many: it needs a confirmation and a reason
  if r.qty_per_unit > 0 and p_qty <> r.qty_per_unit then
    v_ratio := p_qty / r.qty_per_unit;
    if (v_ratio > 2 or v_ratio < 0.5) and not coalesce(p_confirm, false) then
      raise exception using errcode = '22023', hint = 'confirm', message = format(
        '%s: la dose passa da %s a %s %s, %s volte %s. Controlla la virgola; se è giusto conferma e scrivi il motivo.', v_comp,
        fabula._it_num(r.qty_per_unit), fabula._it_num(p_qty), v_unit, fabula._it_num(round(case when v_ratio >= 1 then v_ratio else 1 / v_ratio end, 1)),
        case when v_ratio >= 1 then 'di più' else 'di meno' end);
    end if;
    if (v_ratio > 2 or v_ratio < 0.5) and length(trim(coalesce(p_notes, ''))) < 3 then
      raise exception 'Scrivi il motivo di una dose cambiata così tanto (%)', v_comp using errcode = '22023';
    end if;
  end if;
  v_log := case when p_qty <> r.qty_per_unit then format('[%s] dose %s → %s%s', to_char(now() at time zone 'Europe/Rome', 'DD/MM HH24:MI'),
                fabula._it_num(r.qty_per_unit), fabula._it_num(p_qty), coalesce(': ' || nullif(trim(p_notes), ''), '')) end;
  if r.valid_from >= d then
    -- a change on the same day overwrites the row: the previous dose stays in the notes (and in the Registro modifiche)
    update fabula.recipes set qty_per_unit = p_qty, round_up = coalesce(p_round_up, round_up),
           instruction_it = case when p_instruction is null then instruction_it else nullif(btrim(p_instruction), '') end,
           step_order = coalesce(p_step_order, step_order), notes = concat_ws(E'\n', nullif(notes, ''), v_log), source = 'console'
     where id = r.id;
    return r.id;
  end if;
  update fabula.recipes set valid_to = d - 1 where id = r.id;
  insert into fabula.recipes (finished_product_id, component_product_id, basis, qty_per_unit, round_up, valid_from, source, notes, phase, step_order, instruction_it)
  values (r.finished_product_id, r.component_product_id, r.basis, p_qty, coalesce(p_round_up, r.round_up), d, 'console', concat_ws(E'\n', nullif(r.notes, ''), v_log),
          r.phase, coalesce(p_step_order, r.step_order), case when p_instruction is null then r.instruction_it else nullif(btrim(p_instruction), '') end)
  returning id into v_id;
  return v_id;
end $$;
revoke all on function fabula.update_recipe_dose(uuid, numeric, boolean, text, integer, text, boolean) from public, anon;
grant execute on function fabula.update_recipe_dose(uuid, numeric, boolean, text, integer, text, boolean) to authenticated, service_role;

do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.add_recipe_component(text,text,fabula.recipe_basis,numeric,boolean,text,integer,text)'::regprocedure);
  n := replace(d, $s$  if p_phase not in ('start','close') then raise exception 'Fase non valida (start | close)'; end if;$s$,
                  $s$  if p_phase not in ('start','close') then raise exception 'Fase non valida (start | close)'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'Scrivi la dose: una quantità maggiore di zero' using errcode = '22023'; end if;   -- v0.98 (audit D-27)$s$);
  if n = d then raise exception 'v098b: add_recipe_component pattern not found'; end if;
  execute n;
end $mig$;

-- ============================================================================================================================
-- 4. D-20 · units written one way; an item in a recipe keeps its unit and stays active and counted
-- ============================================================================================================================
create or replace function fabula._unit_norm(p text) returns text language sql immutable set search_path = fabula, public as $$
  select case lower(trim(coalesce(p, '')))
           when 'litri' then 'l' when 'litro' then 'l' when 'lt' then 'l' when 'lt.' then 'l' when 'l.' then 'l'
           when 'millilitri' then 'ml' when 'ml.' then 'ml'
           when 'grammi' then 'g' when 'gr' then 'g' when 'gr.' then 'g' when 'g.' then 'g'
           when 'chili' then 'kg' when 'chilo' then 'kg' when 'kilo' then 'kg' when 'kg.' then 'kg'
           when 'pezzi' then 'pz' when 'pezzo' then 'pz' when 'pz.' then 'pz' when 'pc' then 'pz'
           else lower(trim(coalesce(p, ''))) end $$;
create or replace function fabula.trg_products_guard() returns trigger language plpgsql set search_path = fabula, public as $$
declare v_rec text;
begin
  -- a new item, or a unit that really changes: written one way; an old item keeps its unit as it is when only other fields change
  if tg_op = 'INSERT' or fabula._unit_norm(new.unit) is distinct from fabula._unit_norm(old.unit) then
    new.unit := fabula._unit_norm(new.unit);
    if new.unit !~ '^[a-zàèéìòù]{1,12}$' then
      raise exception 'Unità non valida «%»: usa kg, g, l, ml, pz o il nome della confezione (conf, rotolo, scatola…)', new.unit using errcode = '22023';
    end if;
  else
    new.unit := old.unit;
  end if;
  if tg_op = 'UPDATE' and (fabula._unit_norm(new.unit) is distinct from fabula._unit_norm(old.unit) or (old.active and not new.active) or (old.track_stock and not new.track_stock)) then
    select string_agg(distinct f.name, ', ') into v_rec from fabula.recipes r join fabula.products f on f.id = r.finished_product_id
     where r.component_product_id = new.id and (r.valid_to is null or r.valid_to >= (now() at time zone 'Europe/Rome')::date);
    if v_rec is not null then
      raise exception '«%» è nella ricetta di %: prima toglilo dalla ricetta o cambia le dosi in Console → Ricette (le dosi sono in %)', new.name, v_rec, old.unit using errcode = '23514';
    end if;
  end if;
  return new;
end $$;
revoke all on function fabula.trg_products_guard() from public, anon, authenticated;
update fabula.products set unit = fabula._unit_norm(unit) where unit is distinct from fabula._unit_norm(unit) and fabula._unit_norm(unit) ~ '^[a-zàèéìòù]{1,12}$';
do $mig$ declare r record; begin
  for r in select sku, unit from fabula.products where fabula._unit_norm(unit) !~ '^[a-zàèéìòù]{1,12}$' loop
    raise notice 'v098b: % has the unit «%»: it stays, a new unit for it must be a word (kg, l, pz, conf…)', r.sku, r.unit;
  end loop; end $mig$;
drop trigger if exists products_guard on fabula.products;
create trigger products_guard before insert or update of unit, active, track_stock on fabula.products for each row execute function fabula.trg_products_guard();

-- ============================================================================================================================
-- 5. D-19 · dosing
-- ============================================================================================================================
do $mig$ begin
  if not exists (select 1 from pg_constraint where conname = 'batch_consumables_qty_nonneg') then
    alter table fabula.batch_consumables add constraint batch_consumables_qty_nonneg check (qty >= 0) not valid;
    begin alter table fabula.batch_consumables validate constraint batch_consumables_qty_nonneg;
    exception when check_violation then raise notice 'v098b: some old doses are negative: new ones are checked'; end;
  end if;
end $mig$;
comment on constraint batch_consumables_qty_nonneg on fabula.batch_consumables is 'Quantità dosata negativa: scrivi la quantità usata (0 se non l''hai messo)';

drop function if exists fabula.record_batch_consumable(text, text, numeric, numeric, uuid);
create or replace function fabula.record_batch_consumable(p_batch_lot text, p_sku text, p_qty numeric, p_qty_standard numeric, p_staff_id uuid default null,
                                                          p_lot text default null, p_confirm boolean default false)
returns text language plpgsql set search_path = fabula, public, extensions as $$
declare b record; v_comp uuid; v_name text; v_unit text; v_rec uuid; v_lot text := nullif(upper(trim(coalesce(p_lot, ''))), '');
begin
  select * into b from fabula.production_batches where batch_lot = p_batch_lot;
  select id, name, unit into v_comp, v_name, v_unit from fabula.products where sku = p_sku;
  if b is null or v_comp is null then raise exception 'Lotto o SKU sconosciuto: % / %', p_batch_lot, p_sku using errcode = '22023'; end if;
  -- v0.98 (audit D-19)
  if b.output_kg is not null then
    raise exception 'Il lotto % è già chiuso: i dosaggi si registrano prima della chiusura', p_batch_lot using errcode = '22023';
  end if;
  if p_qty is null or p_qty < 0 then raise exception 'Quantità di % non valida: scrivi la quantità usata (0 se non l''hai messo)', v_name using errcode = '22023'; end if;
  if coalesce(p_qty_standard, 0) > 0 and not coalesce(p_confirm, false) and (p_qty > p_qty_standard * 3 or p_qty < p_qty_standard / 3) then
    raise exception using errcode = '22023', hint = 'confirm', message = format('%s: %s %s contro %s previsti dalla ricetta. Controlla la virgola; se è giusto conferma.',
      v_name, fabula._it_num(round(p_qty, 4)), v_unit, fabula._it_num(round(p_qty_standard, 4)));
  end if;
  if exists (select 1 from fabula.batch_consumables where batch_id = b.id and product_id = v_comp) then
    perform fabula.correct_batch_consumable(p_batch_lot, p_sku, p_qty, 'riconferma da tablet');
    update fabula.batch_consumables set confirmed_at = now(), confirmed_by_id = coalesce(p_staff_id, confirmed_by_id),
           qty_standard = coalesce(qty_standard, p_qty_standard), lot_number = coalesce(v_lot, lot_number)
     where batch_id = b.id and product_id = v_comp;
    return 'corrected';
  end if;
  select id into v_rec from fabula.recipes
   where finished_product_id = b.product_id and component_product_id = v_comp
     and valid_from <= b.batch_date and (valid_to is null or valid_to >= b.batch_date)
   order by valid_from desc limit 1;
  insert into fabula.batch_consumables (batch_id, product_id, qty, recipe_id, qty_standard, entry, confirmed_at, confirmed_by_id, lot_number)
  values (b.id, v_comp, p_qty, v_rec, p_qty_standard, case when p_qty = p_qty_standard then 'confirmed' else 'corrected' end, now(), p_staff_id, v_lot);
  insert into fabula.stock_moves (product_id, lot_number, qty, move_type, batch_id, source, reason)
  values (v_comp, v_lot, -p_qty, 'production_in', b.id, 'tablet',
          format('Lotto %s: dosato e confermato %s (ricetta %s)', p_batch_lot, p_qty, p_qty_standard));
  return 'recorded';
end $$;
revoke all on function fabula.record_batch_consumable(text, text, numeric, numeric, uuid, text, boolean) from public, anon;
grant execute on function fabula.record_batch_consumable(text, text, numeric, numeric, uuid, text, boolean) to authenticated, service_role;

-- ============================================================================================================================
-- 6. D-18 · goods receipt
-- ============================================================================================================================
drop function if exists fabula.receive_purchase_order(text, jsonb, uuid, text, text);
create or replace function fabula.receive_purchase_order(p_po_number text, p_lines jsonb, p_staff_id uuid default null, p_ddt text default null,
                                                         p_notes text default null, p_confirm boolean default false)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare po record; l jsonb; pl record; v_rcpt uuid; v_move uuid; v_price numeric; v_list numeric; v_qty numeric; v_exp date; v_left numeric;
        n int := 0; over jsonb := '[]'; price_changes jsonb := '[]'; v_status fabula.po_status; v_received numeric := 0;
        v_today date := (now() at time zone 'Europe/Rome')::date;
begin
  perform fabula.require_perm('magazzino', 2);
  select * into po from fabula.purchase_orders where po_number = p_po_number;
  if po is null then raise exception 'Ordine sconosciuto: %', p_po_number using errcode = '22023'; end if;
  if po.status not in ('approved','sent','partially_received') then raise exception 'Ordine % in stato %: non ricevibile', p_po_number, po.status using errcode = '22023'; end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Nessuna riga ricevuta' using errcode = '22023'; end if;

  insert into fabula.goods_receipts (purchase_order_id, ddt_number, received_by_id, notes) values (po.id, p_ddt, p_staff_id, p_notes) returning id into v_rcpt;

  for l in select * from jsonb_array_elements(p_lines) loop
    v_qty := (l->>'qty')::numeric;
    continue when v_qty is null or v_qty <= 0;
    select pol.*, p.sku, p.unit, p.name into pl from fabula.purchase_order_lines pol join fabula.products p on p.id = pol.product_id
     where pol.purchase_order_id = po.id and p.sku = l->>'sku' limit 1;
    if pl is null then raise exception 'Riga % non presente nell''ordine %', l->>'sku', p_po_number using errcode = '22023'; end if;
    -- v0.98 (audit D-18): expired goods are not received; ten times the order or a price ten times the list is a typing slip
    v_exp := nullif(l->>'expiry', '')::date;
    if v_exp is not null and v_exp < v_today then
      raise exception '% scaduto il %: non riceverlo, apri una non conformità per il fornitore', pl.name, to_char(v_exp, 'DD/MM/YYYY') using errcode = '22023';
    end if;
    v_left := greatest(pl.qty_ordered - pl.qty_received, 0);
    if v_qty > v_left * 3 and not coalesce(p_confirm, false) then
      raise exception using errcode = '22023', hint = 'confirm', message = format('%s: ricevuti %s %s, ne mancavano %s (ordinati %s). Controlla la quantità; se è giusto conferma.',
        pl.name, fabula._it_num(v_qty), pl.unit, fabula._it_num(v_left), fabula._it_num(pl.qty_ordered));
    end if;
    v_price := coalesce(nullif(l->>'unit_price','')::numeric, pl.unit_price_eur);
    if v_price is not null and v_price < 0 then raise exception 'Prezzo negativo per %', pl.name using errcode = '22023'; end if;
    select price_eur into v_list from fabula.supplier_prices where supplier_id = po.supplier_id and product_id = pl.product_id order by valid_from desc limit 1;
    -- compared with the order's price (what the tablet shows as «listino»), else the supplier's latest price
    if nullif(l->>'unit_price','') is not null and coalesce(nullif(pl.unit_price_eur, 0), v_list) > 0 and not coalesce(p_confirm, false)
       and (v_price > coalesce(nullif(pl.unit_price_eur, 0), v_list) * 1.5 or v_price < coalesce(nullif(pl.unit_price_eur, 0), v_list) * 0.5) then
      raise exception using errcode = '22023', hint = 'confirm', message = format('%s: prezzo sul DDT %s €/%s contro %s €/%s in listino. Controlla la virgola; se è giusto conferma.',
        pl.name, fabula._it_num(v_price), pl.unit, fabula._it_num(coalesce(nullif(pl.unit_price_eur, 0), v_list)), pl.unit);
    end if;
    insert into fabula.stock_moves (product_id, lot_number, expiry_date, qty, move_type, purchase_order_id, unit_cost_eur, source, reason)
    values (pl.product_id, nullif(l->>'lot',''), v_exp, v_qty, 'purchase_receipt', po.id, v_price, 'tablet',
            format('Ricevuto %s %s su ordine %s%s', v_qty, pl.unit, p_po_number, case when p_ddt is not null then ' · DDT ' || p_ddt else '' end))
    returning id into v_move;
    insert into fabula.goods_receipt_lines (receipt_id, po_line_id, product_id, qty_received, supplier_lot, expiry_date, unit_price_eur, stock_move_id)
    values (v_rcpt, pl.id, pl.product_id, v_qty, nullif(l->>'lot',''), v_exp, v_price, v_move);
    update fabula.purchase_order_lines set qty_received = qty_received + v_qty where id = pl.id;

    if pl.qty_received + v_qty > pl.qty_ordered * 1.02 then
      over := over || jsonb_build_object('sku', pl.sku, 'ordered', pl.qty_ordered, 'received_total', pl.qty_received + v_qty);
    end if;
    -- DDT price differs from the latest list price → record it so procurement uses the real one
    if nullif(l->>'unit_price','') is not null and v_list is distinct from v_price then
      insert into fabula.supplier_prices (supplier_id, product_id, price_eur, valid_from, source) values (po.supplier_id, pl.product_id, v_price, v_today, 'ddt');
      price_changes := price_changes || jsonb_build_object('sku', pl.sku, 'from', v_list, 'to', v_price);
    end if;
    n := n + 1; v_received := v_received + v_qty * coalesce(v_price, 0);
  end loop;
  if n = 0 then raise exception 'Nessuna quantità ricevuta' using errcode = '22023'; end if;

  select case when bool_and(qty_received >= qty_ordered) then 'received'::fabula.po_status else 'partially_received'::fabula.po_status end
    into v_status from fabula.purchase_order_lines where purchase_order_id = po.id;
  update fabula.purchase_orders set status = v_status where id = po.id;

  return jsonb_build_object('receipt_id', v_rcpt, 'po_number', p_po_number, 'lines', n, 'value_eur', round(v_received, 2),
                            'po_status', v_status, 'over_delivered', over, 'price_changes', price_changes);
end $$;
revoke all on function fabula.receive_purchase_order(text, jsonb, uuid, text, text, boolean) from public, anon;
grant execute on function fabula.receive_purchase_order(text, jsonb, uuid, text, text, boolean) to authenticated, service_role;

-- ============================================================================================================================
-- 7. FARM-07 · the farm page warns before shipping warm milk
-- ============================================================================================================================
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.farm_milk_orders(text)'::regprocedure);
  n := replace(d, $s$    'orders', (select coalesce(jsonb_agg(jsonb_build_object('plan_date', plan_date, 'milk_kg', milk_kg, 'seen_at', farm_seen_at) order by plan_date), '[]')$s$,
                  $s$    'milk_temp', (select jsonb_build_object('warn_max', warn_max, 'max', max_value) from fabula.haccp_control_points where code = 'CCP-MILK-TEMP' and active limit 1),   -- v0.98 (FARM-07)
    'orders', (select coalesce(jsonb_agg(jsonb_build_object('plan_date', plan_date, 'milk_kg', milk_kg, 'seen_at', farm_seen_at) order by plan_date), '[]')$s$);
  if n = d then raise exception 'v098b: farm_milk_orders pattern not found'; end if;
  execute n;
end $mig$;

-- ============================================================================================================================
-- 8. The definer functions check the caller inside: accepted in the evening security check
-- ============================================================================================================================
insert into fabula.security_accepted (key, reason, accepted_at) values
 ('authenticated_security_definer_function_executable:fabula.correct_batch_milk(p_batch_lot text, p_milk_kg numeric, p_reason text, p_staff_id uuid, p_yield_note text)',
  'by design (v0.98b, audit D-06): require_perm(produzione, 2 on an open lot / 3 on a closed one); reason required; one milk input only', now()),
 ('authenticated_security_definer_function_executable:fabula.receive_purchase_order(p_po_number text, p_lines jsonb, p_staff_id uuid, p_ddt text, p_notes text, p_confirm boolean)',
  'by design (v0.98b, audit D-18): same as before plus p_confirm; require_perm(magazzino, 2) first', now())
on conflict (key) do update set reason = excluded.reason, accepted_at = excluded.accepted_at;
delete from fabula.security_accepted
 where key = 'authenticated_security_definer_function_executable:fabula.receive_purchase_order(p_po_number text, p_lines jsonb, p_staff_id uuid, p_ddt text, p_notes text)';
