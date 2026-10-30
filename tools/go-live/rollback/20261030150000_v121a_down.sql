-- Rollback of v1.21a (CCP 2 a tino: the holding minutes): puts back what was live before it.
-- v1.21a added one control point (CCP-PAST-HOLD), one preset step per pasteurisation step and a trigger (haccp_cp_active_steps), and
-- replaced three functions (trg_batch_ccp_check, trg_step_log_ccp, _haccp_evening_items). The texts below are the ones live before
-- v1.21a: trg_batch_ccp_check and trg_step_log_ccp as read from production on 30/10/2026, _haccp_evening_items as v1.20a wrote it. Records already written (haccp_log rows, non-conformities, step
-- logs) stay: the control point and the steps are switched off, not deleted, so the registers keep pointing at them.
-- CCP-PAST stays at 63 °C (set on live on 30/10/2026 before v1.21a; v1.21a only wrote the same values into the migrations).
-- To use it, copy it into supabase/migrations under a new, later version and release it through the pipeline like any other release.

drop trigger if exists haccp_cp_active_steps on fabula.haccp_control_points;
drop function if exists fabula.trg_cp_active_steps();
update fabula.process_steps set active = false, updated_at = now() where ccp_code = 'CCP-PAST-HOLD';
update fabula.haccp_control_points set active = false, updated_at = now() where code = 'CCP-PAST-HOLD';
update fabula.process_steps set
  instruction_it = 'Pastorizzazione a tino: latte a ≥ 63 °C per ≥ 30 min in tutto il volume. Conta i 30 minuti da quando tutto il latte è a 63 °C; registra la temperatura più bassa letta sul termoregistratore durante la sosta, poi raffredda a 36 °C per il siero-innesto.',
  updated_at = now()
where ccp_code = 'CCP-PAST';

CREATE OR REPLACE FUNCTION fabula.trg_batch_ccp_check()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'fabula', 'public'
AS $function$
declare v_missing text[] := '{}'; v_need text[];
begin
  v_need := case when new.input_kind = 'whey' then array['CCP-RIC'] else array['CCP-PAST', 'CCP-STRETCH'] end;
  select coalesce(array_agg(c order by c), '{}') into v_missing from unnest(v_need) c
   where not exists (select 1 from fabula.haccp_log l join fabula.haccp_control_points cp on cp.id = l.control_point_id
                      where l.batch_id = new.id and cp.code = c and l.measured_value is not null);   -- v0.95a (audit D-12)
  if cardinality(v_missing) > 0 and coalesce(new.source, '') not in ('simulation', 'test') then
    -- v0.96a (audit A-03): the lot is held until the HACCP manager releases it (Autocontrollo → Lotti bloccati)
    perform set_config('fabula.hold_ctx', 'on', true);
    update fabula.production_batches set food_safety_hold = true, hold_at = now(), hold_released_at = null, hold_released_by_id = null,
           hold_reason = 'CCP mancante alla chiusura: ' || array_to_string(v_missing, ', ')
     where id = new.id and not food_safety_hold;
    perform set_config('fabula.hold_ctx', '', true);
    perform fabula.keep_basis('sicurezza', 'batch_ccp', jsonb_build_object('lot', new.batch_lot, 'input_kind', new.input_kind, 'closed_at', now(),
      'missing', to_jsonb(v_missing), 'held', true,
      'points', (select coalesce(jsonb_agg(jsonb_build_object('code', cp.code, 'ccp_no', cp.ccp_no, 'name', cp.name, 'limit_it', cp.critical_limit_it,
                                                             'min', cp.min_value, 'max', cp.max_value, 'unit', cp.unit,
                                                             'value', lv.measured_value, 'logged_at', lv.logged_at) order by cp.sort, cp.code), '[]'::jsonb)
                   from fabula.haccp_control_points cp
                   left join lateral (select l.measured_value, l.logged_at from fabula.haccp_log l
                                       where l.batch_id = new.id and l.control_point_id = cp.id and l.measured_value is not null
                                       order by l.logged_at desc limit 1) lv on true
                  where cp.code = any (v_need))), 'database');   -- v1.06 («Perché?»)
    perform fabula.post_bot_message('sicurezza', 'alert',
      format('Lotto %s chiuso senza %s', new.batch_lot,
             array_to_string(array(select case m when 'CCP-PAST' then 'pastorizzazione (CCP 2)' when 'CCP-STRETCH' then 'temperatura di filatura (CCP 3)' else 'temperatura di affioramento (CCP 4)' end from unnest(v_missing) m), ' e ')),
      format(E'Il lotto %s è stato chiuso ma nel registro HACCP manca: %s.\nSe la misura è stata fatta su carta, ricopiala dal tablet (🛡 → Ricopia da foglio di carta) con data e ora del foglio. Il lotto è BLOCCATO: non si confeziona e non si vende finché il responsabile HACCP non lo sblocca (Autocontrollo → Lotti bloccati), dopo aver ricopiato la misura o valutato il lotto.',
             new.batch_lot, array_to_string(v_missing, ', ')));
  end if;
  return null;
end $function$;

CREATE OR REPLACE FUNCTION fabula._haccp_evening_items(p_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'fabula', 'public', 'extensions'
AS $function$
declare items jsonb := '[]'; n_ship int; n_milk int; n_abx int; v_real_prod boolean; v_start date := fabula.tasks_start_date();
begin
  v_real_prod := exists (select 1 from fabula.production_batches where batch_date = p_date and source <> 'simulation');
  -- v1.05 (audit E-32): nothing is asked before the tasks start, unless milk or a lot was really worked that day (food safety first)
  if v_start is not null and p_date < v_start and not v_real_prod
     and not fabula._real_activity(p_date) then   -- v1.07: nor real product in stock or worked in the last days
    return items;
  end if;
  -- the Rome day (v1.05: logged_at::date was the UTC date)
  select coalesce(jsonb_agg(jsonb_build_object('code', 'cold:' || cp.code, 'label_it', 'Temperatura serale ' || coalesce(e.code, cp.name), 'scan', 'EQ:' || e.code) order by cp.code), '[]') into items
  from fabula.haccp_control_points cp left join fabula.equipment e on e.id = cp.equipment_id
  where cp.active and cp.frequency = 'twice_daily'
    and not exists (select 1 from fabula.haccp_log l where l.control_point_id = cp.id and (l.logged_at at time zone 'Europe/Rome')::date = p_date
                                                         and (l.logged_at at time zone 'Europe/Rome')::time >= time '15:00');
  -- the end-of-shift cleaning, not on a closed day with no production (only the cold rooms are checked then)
  if not (fabula.is_closed_day(p_date) and not v_real_prod)
     and not exists (select 1 from fabula.haccp_log l join fabula.haccp_control_points cp on cp.id = l.control_point_id
                  where cp.code = 'PRP-CLEAN' and (l.logged_at at time zone 'Europe/Rome')::date = p_date) then
    items := items || jsonb_build_object('code', 'clean', 'label_it', 'Sanificazione fine turno', 'scan', 'CLEAN:');
  end if;
  if exists (select 1 from fabula.production_batches where batch_date = p_date) or exists (select 1 from fabula.sales_orders where order_date = p_date) then
    if not exists (select 1 from fabula.meter_readings where meter = 'elec_main' and (read_at at time zone 'Europe/Rome')::date = p_date) then
      items := items || jsonb_build_object('code', 'kwh', 'label_it', 'Lettura contatore', 'scan', 'METER:elec_main'); end if;
  end if;
  if v_real_prod and not exists (select 1 from fabula.effluent_log where log_date = p_date) then
    items := items || jsonb_build_object('code', 'effluent', 'label_it', 'Reflui del giorno (scotta, acque di lavaggio)', 'scan', 'EFFL:');
  end if;
  -- food safety: CCP per real batch (filatura for mozzarella, affioramento for ricotta, pasteurisation when the milk is pasteurised)
  select items || coalesce(jsonb_agg(jsonb_build_object('code', 'ccp:' || cp.code || ':' || b.batch_lot,
                                                        'label_it', cp.ccp_no || ' ' || cp.name || ' · lotto ' || b.batch_lot,
                                                        'scan', 'CCP:' || cp.code || ':' || b.batch_lot) order by b.batch_lot, cp.sort), '[]') into items
  from fabula.production_batches b
  join fabula.haccp_control_points cp on cp.active and (
         cp.code = case when b.input_kind = 'whey' then 'CCP-RIC' else 'CCP-STRETCH' end
      or (cp.code = 'CCP-PAST' and b.input_kind <> 'whey' and fabula.setting_text('food.milk_process', 'crudo') = 'pastorizzato'))
  where b.batch_date = p_date and b.source <> 'simulation'
    and not exists (select 1 from fabula.haccp_log l where l.batch_id = b.id and l.control_point_id = cp.id);
  select count(*) into n_milk from fabula.milk_intake where intake_date = p_date and source <> 'simulation';
  select count(*) into n_abx from fabula.haccp_log l join fabula.haccp_control_points cp on cp.id = l.control_point_id
   where cp.code = 'CCP-MILK-ABX' and (l.logged_at at time zone 'Europe/Rome')::date = p_date;
  if n_milk > n_abx then
    items := items || jsonb_build_object('code', 'abx', 'label_it', format('CCP 1b test antibiotici: %s conferimenti di latte senza esito', n_milk - n_abx), 'scan', 'CCP:CCP-MILK-ABX');
  end if;
  -- v1.20 (MILK-1, house rule): every kg delivered goes into a vat on the day it arrives. From 15:00 Rome (any time, for an earlier
  -- day: until its non-conformity is closed) a delivery of the day not yet all in a vat (more than the weighing tolerance left) is on
  -- the list; its label opens the milk (batch start).
  if p_date < (now() at time zone 'Europe/Rome')::date or (now() at time zone 'Europe/Rome')::time >= time '15:00' then
    select items || coalesce(jsonb_agg(jsonb_build_object('code', 'milkleft:' || x.milk_lot,
             'label_it', case when p_date < (now() at time zone 'Europe/Rome')::date
                              then format('Latte %s: %s kg non lavorati il giorno di arrivo (regola del caseificio): chiama il responsabile', x.milk_lot, fabula._it_num(x.left_kg))
                              else format('Latte %s: %s kg non ancora in caldaia: va lavorato oggi', x.milk_lot, fabula._it_num(x.left_kg)) end,
             'scan', 'LOT:' || x.milk_lot) order by x.milk_lot), '[]') into items
      from (select mi.milk_lot, mi.qty_kg, mi.qty_kg - coalesce((select sum(bm.qty_kg) from fabula.batch_milk_inputs bm where bm.milk_intake_id = mi.id), 0) left_kg
              from fabula.milk_intake mi where mi.intake_date = p_date and mi.accepted and coalesce(mi.source, '') <> 'simulation') x
     where fabula.milk_left_over(x.qty_kg, x.left_kg)
       and (p_date >= (now() at time zone 'Europe/Rome')::date or coalesce(fabula.milk_rule_nc_status(x.milk_lot, p_date), '') <> 'closed');
  end if;
  if v_real_prod and not exists (select 1 from fabula.calibration_checks c join fabula.equipment e on e.id = c.equipment_id
                                 where e.code = 'PH-01' and (c.checked_at at time zone 'Europe/Rome')::date = p_date) then
    items := items || jsonb_build_object('code', 'ph', 'label_it', 'Calibrazione pH-metro (tamponi 4 e 7)', 'scan', 'CAL:PH-01');
  end if;
  select count(*) into n_ship from fabula.v_orders_to_ship where channel = 'shopify';
  if n_ship > 0 then
    items := items || jsonb_build_object('code', 'ship', 'label_it', n_ship || ' ordini online pagati da spedire', 'scan', 'SHIP:');
  end if;
  select items || coalesce(jsonb_agg(jsonb_build_object('code', 'batch:' || batch_lot, 'label_it', 'Lotto ' || batch_lot || ' non chiuso (kg prodotto)', 'scan', 'LOT:' || batch_lot)), '[]') into items
  from fabula.production_batches where batch_date = p_date and output_kg is null and source <> 'simulation';
  select items || coalesce(jsonb_agg(jsonb_build_object('code', 'shift:' || st.badge_code, 'label_it', st.full_name || ': badge di uscita non passato', 'scan', st.badge_code)), '[]') into items
  from fabula.shifts s join fabula.staff st on st.id = s.staff_id where s.clock_out is null and (s.clock_in at time zone 'Europe/Rome')::date = p_date;
  return items;
end $function$;

CREATE OR REPLACE FUNCTION fabula.trg_step_log_ccp()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'fabula', 'public', 'extensions'
AS $function$
declare v_ccp text; v_lot text;
begin
  select ccp_code into v_ccp from fabula.process_steps where id = new.step_id;
  if v_ccp is null or new.actual_value is null then return new; end if;
  if tg_op = 'UPDATE' and old.actual_value is not distinct from new.actual_value then return new; end if;
  select batch_lot into v_lot from fabula.production_batches where id = new.batch_id;
  perform fabula.log_ccp(p_cp_code => v_ccp, p_value => new.actual_value, p_logged_at => new.logged_at, p_staff_id => new.staff_id,
                         p_batch_lot => v_lot, p_action => new.note, p_source => 'preset');
  return new;
end $function$;

-- (end of the v1.21a rollback)
