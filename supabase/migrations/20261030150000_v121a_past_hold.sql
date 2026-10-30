-- v1.21a (30/10/2026) · CCP 2 a tino: the minutes held at ≥ 63 °C are recorded on every vat (≥ 30 min)
-- Nick, 30/10/2026: «change the limit to 63 for 30 minutes for now» (done on live the same morning as a data change: CCP-PAST 72 → 63 °C,
-- texts and the preset step), then «yes» to recording the holding minutes. The Fortino invoices say the vat is a Mod. MCA300, 300 L, a
-- batch pasteuriser; its own rating plate is still to be read (Manuale §13). Batch pasteurisation is legal only as temperature AND time
-- (≥ 63 °C for ≥ 30 min in the whole volume), and until now the system recorded only the temperature.
-- Now:
--   1. CCP-PAST carries the batch limits (min 63, alert below 64) and texts: the same values written on live on 30/10, here so that a
--      replay of the migrations equals live. The preset step «Pastorizzazione del latte (CCP 2)» likewise (63 °C · 30 min).
--   2. New control point CCP-PAST-HOLD «Pastorizzazione: minuti di sosta a ≥ 63 °C»: CCP 2, minutes, critical limit ≥ 30, per batch,
--      MOD-02, critical non-conformity. Below 30 the lot is held (log_ccp, as for every CCP with a lot); it prints on the MOD-02 register
--      next to the temperature (haccp_register reads every control point of the form).
--   3. A preset step «Sosta di pastorizzazione (CCP 2)» right after each pasteurisation step (record_metric duration, ccp_code
--      CCP-PAST-HOLD): the tablet asks the minutes as a critical point (no skip, no «Fatto»), and trg_step_log_ccp writes the register.
--      A preset without that step (or a vat started without a preset) is asked the minutes on the start form; a vat that reaches its
--      close without them is asked there (tablet).
--   4. trg_batch_ccp_check: a milk lot closed without the minutes is held like one closed without CCP 2 or CCP 3 (only while
--      CCP-PAST-HOLD is active: switching it off is how a continuous pasteuriser, 72 °C × 15 s with diversion valve, would go back).
--      The missing list keeps its order (CCP-PAST, CCP-STRETCH, then CCP-PAST-HOLD).
--   5. «Prima di chiudere» (_haccp_evening_items, from v1.20a): a lot of the day without the minutes is listed, as for CCP 2.
-- Not changed: log_ccp, ccp_eval, the trial week check (trial_check counts CCP 2 temperatures), simulate_days (simulated lots are exempt).
-- Rollback: tools/go-live/rollback/20261030150000_v121a_down.sql.

-- ============================================================================================================================
-- 1. CCP 2 a tino (values already live since 30/10/2026 14:09 UTC)
-- ============================================================================================================================
update fabula.haccp_control_points set
  min_value = 63, warn_min = 64,
  critical_limit_it = 'Pastorizzazione a tino (discontinua): ≥ 63 °C per ≥ 30 min in tutto il volume. Impostato il 30/10/2026 in attesa della targa della caldaia (Fortino MCA300 secondo le fatture); se l''impianto risultasse a flusso continuo: ≥ 72 °C per ≥ 15 s con valvola deviatrice (Manuale §13).',
  monitoring_it = 'Ogni ciclo: i 30 minuti si contano da quando tutto il latte ha raggiunto 63 °C; si registra la temperatura più bassa letta sul termometro registratore durante la sosta · confronto registratore/indicatore e prova del timer a inizio giornata.',
  corrective_it = 'Sotto 63 °C o sosta più corta di 30 min: si riporta il latte a 63 °C e si ricomincia il conteggio dei 30 minuti · lotti prodotti fuori limite bloccati · NC critica · tecnico per il pastorizzatore.',
  updated_at = now()
where code = 'CCP-PAST'
  and (min_value is distinct from 63 or warn_min is distinct from 64
       or critical_limit_it not like 'Pastorizzazione a tino (discontinua): ≥ 63 °C per ≥ 30 min%');

update fabula.process_steps set
  target_temp_c = 63, temp_min_c = 63, duration_min = 30, duration_min_min = 30,
  instruction_it = 'Pastorizzazione a tino: latte a ≥ 63 °C per ≥ 30 min in tutto il volume. Conta i 30 minuti da quando tutto il latte è a 63 °C; scrivi qui la temperatura più bassa letta sul termoregistratore durante la sosta e, al passo dopo, i minuti di sosta. Poi raffredda a 36 °C per il siero-innesto.',
  updated_at = now()
where ccp_code = 'CCP-PAST';

-- ============================================================================================================================
-- 2. The holding minutes: a control point of CCP 2
-- ============================================================================================================================
insert into fabula.haccp_control_points (code, name, check_type, frequency, min_value, max_value, warn_min, warn_max, unit, active, equipment_id,
                                         is_ccp, ccp_no, process_step, hazard_it, critical_limit_it, monitoring_it, corrective_it,
                                         verification_it, records_it, applies_when, nc_severity, sort, form_code, plausible_min, plausible_max)
select 'CCP-PAST-HOLD', 'Pastorizzazione: minuti di sosta a ≥ 63 °C', 'other', 'per_batch', 30, null, null, null, 'min', true, null,
       true, 'CCP 2', p.process_step, p.hazard_it,
       'Pastorizzazione a tino: sosta di almeno 30 minuti con tutto il latte a ≥ 63 °C (la temperatura è l''altro valore del CCP 2).',
       'Ogni ciclo: i minuti si contano da quando tutto il latte ha raggiunto 63 °C, con il termoregistratore o il timer della caldaia; si scrive la durata effettiva della sosta.',
       'Sosta più corta di 30 minuti: si riporta il latte a 63 °C e si ricomincia il conteggio dei 30 minuti · se il latte è già andato avanti, lotto bloccato · NC critica.',
       'Confronto con il tracciato del termoregistratore · prova del timer a inizio giornata · fosfatasi alcalina mensile (MILK-ALP).',
       'MOD-02 · tracciato del registratore (foto), haccp_log',
       'latte_pastorizzato', 'critical', 30, 'MOD-02', 0, 240
  from fabula.haccp_control_points p
 where p.code = 'CCP-PAST'
on conflict (code) do nothing;

-- ============================================================================================================================
-- 3. The preset step after each pasteurisation step: the minutes are a critical point on the tablet
-- ============================================================================================================================
insert into fabula.process_steps (preset_id, phase, step_order, name_it, equipment_id, duration_min, duration_min_min, record_metric,
                                  instruction_it, ccp_code, active)
select s.preset_id, s.phase, s.step_order + 1, 'Sosta di pastorizzazione (CCP 2)', s.equipment_id, 30, 30, 'duration',
       'Scrivi i minuti di sosta con tutto il latte a ≥ 63 °C, letti sul termoregistratore o sul timer: almeno 30. Sotto i 30 il lotto si blocca: riporta il latte a 63 °C e ricomincia il conteggio.',
       'CCP-PAST-HOLD', true
  from fabula.process_steps s
 where s.ccp_code = 'CCP-PAST' and s.active
   and not exists (select 1 from fabula.process_steps h where h.preset_id = s.preset_id and h.ccp_code = 'CCP-PAST-HOLD')
   and not exists (select 1 from fabula.process_steps o where o.preset_id = s.preset_id and o.phase = s.phase and o.step_order = s.step_order + 1);

-- ============================================================================================================================
-- 4. A milk lot closed without the minutes is held (as without CCP 2 or CCP 3)
-- ============================================================================================================================
CREATE OR REPLACE FUNCTION fabula.trg_batch_ccp_check()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'fabula', 'public'
AS $function$
declare v_missing text[] := '{}'; v_need text[];
begin
  v_need := case when new.input_kind = 'whey' then array['CCP-RIC'] else array['CCP-PAST', 'CCP-STRETCH'] end;
  -- v1.21a: CCP 2 a tino is temperature and time: the holding minutes too, while that control point is active
  if new.input_kind is distinct from 'whey' and exists (select 1 from fabula.haccp_control_points where code = 'CCP-PAST-HOLD' and active) then
    v_need := array_append(v_need, 'CCP-PAST-HOLD');
  end if;
  select coalesce(array_agg(c order by array_position(v_need, c)), '{}') into v_missing from unnest(v_need) c
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
             array_to_string(array(select case m when 'CCP-PAST' then 'pastorizzazione (CCP 2)' when 'CCP-PAST-HOLD' then 'minuti di sosta della pastorizzazione (CCP 2)'
                                                 when 'CCP-STRETCH' then 'temperatura di filatura (CCP 3)' else 'temperatura di affioramento (CCP 4)' end
                                   from unnest(v_missing) m), ' e ')),
      format(E'Il lotto %s è stato chiuso ma nel registro HACCP manca: %s.\nSe la misura è stata fatta su carta, ricopiala dal tablet (🛡 → Ricopia da foglio di carta) con data e ora del foglio. Il lotto è BLOCCATO: non si confeziona e non si vende finché il responsabile HACCP non lo sblocca (Autocontrollo → Lotti bloccati), dopo aver ricopiato la misura o valutato il lotto.',
             new.batch_lot, array_to_string(v_missing, ', ')));
  end if;
  return null;
end $function$;

-- ============================================================================================================================
-- 5. «Prima di chiudere»: a lot of the day without the minutes (v1.20a's function; only the CCP 2 line changes)
-- ============================================================================================================================
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
      -- v1.21a: CCP 2 a tino is the temperature and the holding minutes
      or (cp.code in ('CCP-PAST', 'CCP-PAST-HOLD') and b.input_kind <> 'whey' and fabula.setting_text('food.milk_process', 'crudo') = 'pastorizzato'))
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


-- (end of v1.21a)
