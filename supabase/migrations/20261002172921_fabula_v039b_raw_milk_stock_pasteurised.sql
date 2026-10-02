-- v0.39 · 2026-10-02 · accepted milk intakes book raw-milk stock with a processing deadline; milk is pasteurised (CCP 2 active)
-- (part of the v0.39 integrity pass; see 20261002172859 for the overview)

-- ---------------------------------------------------------------- 2. raw-milk stock from accepted intakes
create or replace function fabula.trg_milk_intake_stock() returns trigger
language plpgsql security definer set search_path = fabula, public as $$
declare v_raw uuid;
begin
  if new.source = 'simulation' or not coalesce(new.accepted, true) then return new; end if;
  select id into v_raw from fabula.products where sku = 'RAW-MILK';
  if v_raw is null then return new; end if;
  if exists (select 1 from fabula.stock_moves where product_id = v_raw and move_type = 'milk_intake' and lot_number = new.milk_lot
             and moved_at::date = new.intake_date) then return new; end if;   -- idempotent on re-sent tablet rows
  insert into fabula.stock_moves (product_id, lot_number, expiry_date, qty, move_type, unit_cost_eur, reason, source)
  values (v_raw, new.milk_lot, new.intake_date + fabula.setting_num('milk.raw_shelf_days', 2)::int, new.qty_kg, 'milk_intake',
          new.price_eur_per_kg, 'Conferimento DDT ' || coalesce(new.ddt_number, '—'), coalesce(new.source, 'tablet'));
  return new;
end $$;
create or replace trigger milk_intake_stock after insert on fabula.milk_intake
  for each row execute function fabula.trg_milk_intake_stock();

update fabula.stock_moves m set expiry_date = m.moved_at::date + 2
  from fabula.products p where p.id = m.product_id and p.sku = 'RAW-MILK' and m.move_type = 'milk_intake' and m.expiry_date is null;

-- ---------------------------------------------------------------- 3. pasteurised milk
update fabula.settings set value = 'pastorizzato',
  description = 'Latte lavorato: pastorizzato (deciso 02/10/2026) — il CCP 2 pastorizzazione è richiesto a ogni lotto di mozzarella'
  where key = 'food.milk_process';

insert into fabula.process_steps (preset_id, phase, step_order, name_it, equipment_id, target_temp_c, temp_min_c, record_metric, ccp_code, instruction_it, active)
select pp.id, 'start', 2, 'Pastorizzazione del latte (CCP 2)', (select id from fabula.equipment where code = 'PAST-01'), 72, 72, 'temp', 'CCP-PAST',
       'Latte a ≥ 72 °C per ≥ 15 s (HTST) e valvola deviatrice funzionante. Registra la temperatura letta sul termoregistratore, poi raffreddare a 36 °C per il siero-innesto.', true
from fabula.process_presets pp
where pp.name = 'Base · prova 29/09'
  and not exists (select 1 from fabula.process_steps s where s.preset_id = pp.id and s.ccp_code = 'CCP-PAST');

alter table fabula.lab_tests drop constraint if exists lab_tests_matrix_check;
alter table fabula.lab_tests add constraint lab_tests_matrix_check
  check (matrix = any (array['mozzarella', 'ricotta', 'latte_crudo', 'latte_pastorizzato', 'acqua', 'ambiente', 'salamoia_governo']));

insert into fabula.lab_tests (code, matrix, kind, analyte_it, criterion_ref, n, c, unit, limit_it, stage_it, sampling_point_it, method_it, frequency_days, responsible, active, sort, notes)
select 'MILK-ALP', 'latte_pastorizzato', 'igiene_processo', 'Fosfatasi alcalina (verifica pastorizzazione)', 'Reg. CE 853/2004 All. III Sez. IX · Reg. CE 1664/2006', 1, 0, 'mU/l',
       'Negativa (< 350 mU/l)', 'Latte subito dopo la pastorizzazione', 'Uscita pastorizzatore', 'ISO 11816-1', 30, 'partner', true, 5,
       'Verifica mensile del CCP 2 (latte pastorizzato dal 02/10/2026).'
where not exists (select 1 from fabula.lab_tests where code = 'MILK-ALP');

update fabula.lab_tests set m_limit = 10, big_m_limit = 100,
  limit_it = 'Latte pastorizzato: m 10 – M 100 ufc/g a fine produzione (Reg. 2073/2005 2.2.4). Oltre 10⁵ → ricerca enterotossine sul lotto',
  criterion_ref = 'Reg. CE 2073/2005 2.2.4 (formaggi da latte pastorizzato)'
  where code = 'MOZ-CPS';
update fabula.lab_tests set frequency_days = 180,
  notes = 'Con latte pastorizzato il criterio 1.11 non è obbligatorio: mantenuto come verifica semestrale.'
  where code = 'MOZ-SAL';
