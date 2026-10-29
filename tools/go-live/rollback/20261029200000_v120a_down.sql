-- Rollback of v1.20a (MILK-1, the house rule «latte del giorno»): puts back exactly what was live before it.
-- v1.20a added one trigger function and one trigger, replaced five functions (prod_watch, _why_prod_watch, production_plan,
-- _haccp_evening_items, consorzio_declaration) and changed three data rows (the milk.raw_shelf_days setting, the message rule, the
-- scheduled-job description). The functions below are the text that was live (captured from a replay of main 7e8f879, identical to
-- production by md5 of the body on 29/10/2026). Non-conformities already opened by the evening watch are records and stay.
-- To use it, copy it into supabase/migrations under a new, later version and release it through the pipeline like any other release.

drop trigger if exists batch_milk_same_day on fabula.batch_milk_inputs;
drop function if exists fabula.trg_batch_milk_same_day();

update fabula.settings set min_value = 1, value = '2', description = 'Giorni entro cui il latte conferito va lavorato' where key = 'milk.raw_shelf_days';
update fabula.message_rules
   set kind = 'latte_60_ore', title_regex = 'latte vicino alle 60 ore',
       meaning_it = 'Latte accettato e non lavorato da 48 ore o più: oltre le 60 ore non si fa DOP. Va lavorato domattina per primo.'
 where kind = 'latte_non_lavorato';
update fabula.cron_jobs_expected set purpose_it = 'Lotti aperti e latte vicino alle 60 ore (sera)' where jobname = 'fabula_prod_watch';

CREATE OR REPLACE FUNCTION fabula.prod_watch(p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'fabula', 'public'
AS $function$
declare v_day date := (p_now at time zone 'Europe/Rome')::date; v_open text; v_milk text; n_open int; n_milk int; v_title text;
begin
  if extract(hour from p_now at time zone 'Europe/Rome') <> 19 then return jsonb_build_object('skipped', 'not 19:xx in Rome'); end if;
  select count(*), string_agg(batch_lot || ' (' || to_char(coalesce(started_at, batch_date::timestamptz) at time zone 'Europe/Rome', 'DD/MM HH24:MI') || ')', ', ' order by batch_lot)
    into n_open, v_open
    from fabula.production_batches where output_kg is null and batch_date <= v_day and coalesce(source, '') not in ('simulation', 'test');
  select count(*), string_agg(format('%s: %s kg, arrivato %s', m.milk_lot, trim_scale(m.left_kg), to_char(m.arrived at time zone 'Europe/Rome', 'DD/MM HH24:MI')), E'\n• ' order by m.arrived)
    into n_milk, v_milk
    from (select mi.milk_lot, ((mi.intake_date + coalesce(mi.intake_time, time '07:00')) at time zone 'Europe/Rome') arrived,
                 mi.qty_kg - coalesce((select sum(bmi.qty_kg) from fabula.batch_milk_inputs bmi where bmi.milk_intake_id = mi.id), 0) left_kg
            from fabula.milk_intake mi where mi.accepted and coalesce(mi.source, '') <> 'simulation' and mi.intake_date >= v_day - 5) m
   where m.left_kg > 1 and m.arrived <= p_now - interval '48 hours';
  if n_open = 0 and n_milk = 0 then return jsonb_build_object('open_batches', 0, 'old_milk', 0); end if;
  v_title := format('Produzione %s: %s', to_char(v_day, 'DD/MM'), concat_ws(' · ', case when n_open > 0 then n_open || ' lott' || case when n_open = 1 then 'o aperto' else 'i aperti' end end,
                                                                     case when n_milk > 0 then n_milk || ' latte vicino alle 60 ore' end));
  if exists (select 1 from fabula.bot_messages where agent in ('produzione', 'sicurezza') and title = v_title) then return jsonb_build_object('skipped', 'already posted'); end if;
  perform fabula.keep_basis(case when n_milk > 0 then 'sicurezza' else 'produzione' end, 'prod_watch', jsonb_build_object('date', v_day, 'checked_at', p_now,
      'warn_hours', 48, 'dop_limit_hours', 60,
      'open_batches', (select coalesce(jsonb_agg(jsonb_build_object('lot', batch_lot, 'started', coalesce(started_at, batch_date::timestamptz)) order by batch_lot), '[]'::jsonb)
                         from fabula.production_batches where output_kg is null and batch_date <= v_day and coalesce(source, '') not in ('simulation', 'test')),
      'old_milk', (select coalesce(jsonb_agg(jsonb_build_object('lot', m.milk_lot, 'left_kg', m.left_kg, 'arrived', m.arrived,
                                                               'hours', round(extract(epoch from p_now - m.arrived) / 3600)) order by m.arrived), '[]'::jsonb)
                     from (select mi.milk_lot, ((mi.intake_date + coalesce(mi.intake_time, time '07:00')) at time zone 'Europe/Rome') arrived,
                                  mi.qty_kg - coalesce((select sum(bmi.qty_kg) from fabula.batch_milk_inputs bmi where bmi.milk_intake_id = mi.id), 0) left_kg
                             from fabula.milk_intake mi where mi.accepted and coalesce(mi.source, '') <> 'simulation' and mi.intake_date >= v_day - 5) m
                    where m.left_kg > 1 and m.arrived <= p_now - interval '48 hours')), 'database');   -- v1.06 («Perché?»)
  perform fabula.post_bot_message(case when n_milk > 0 then 'sicurezza' else 'produzione' end, 'warn', v_title,
    concat_ws(E'\n\n',
      case when n_open > 0 then format(E'Lotti avviati e non chiusi:\n• %s\nSe sono finiti, scansiona l''etichetta sul tank e chiudili con i kg; se sono stati scartati, registra lo scarto.', replace(v_open, ', ', E'\n• ')) end,
      case when n_milk > 0 then format(E'Latte accettato e non ancora lavorato da 48 ore o più (il disciplinare DOP consente 60 ore dalla mungitura):\n• %s\nLavoralo domattina per primo o non usarlo per la DOP.', v_milk) end));
  return jsonb_build_object('open_batches', n_open, 'old_milk', n_milk);
end $function$;

CREATE OR REPLACE FUNCTION fabula._why_prod_watch(d jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'fabula', 'public'
AS $function$
declare r jsonb[] := '{}'; m jsonb[] := '{}'; x jsonb;
begin
  for x in select y from jsonb_array_elements(coalesce(d->'open_batches', '[]'::jsonb)) y loop
    r := r || fabula._wr('Lotto ' || coalesce(x->>'lot', ''), 'avviato ' || fabula._wd(x->'started') || coalesce(' ore ' || fabula._wt(x->'started'), ''),
                         'non ancora chiuso: se è finito si chiude con i kg, se è stato scartato si registra lo scarto');
  end loop;
  for x in select y from jsonb_array_elements(coalesce(d->'old_milk', '[]'::jsonb)) y loop
    m := m || fabula._wr('Latte ' || coalesce(x->>'lot', ''), fabula._wq(x->'left_kg') || ' da lavorare',
                         format('arrivato %s ore %s: %s fa', fabula._wd(x->'arrived'), coalesce(fabula._wt(x->'arrived'), 'n/d'),
                                case when fabula._wn(x->'hours') is not null then fabula.it_n(fabula._wn(x->'hours'), 'ora', 'ore') else 'n/d ore' end), 'ko');
  end loop;
  return fabula._wout('Perché questo avviso della sera', array[
    fabula._wsec('Lotti aperti', r),
    fabula._wsec('Latte vicino alle 60 ore', m, case when cardinality(m) > 0 then
      format('Il disciplinare DOP consente %s ore dalla mungitura; l''avviso parte a %s ore dall''arrivo (dalla mungitura sono di più). Lavoralo domattina per primo o non usarlo per la DOP.',
             coalesce(d->>'dop_limit_hours', '60'), coalesce(d->>'warn_hours', '48')) end)]);
end $function$;

CREATE OR REPLACE FUNCTION fabula.production_plan(p_date date DEFAULT ((now() AT TIME ZONE 'Europe/Rome'::text))::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'fabula', 'public'
AS $function$
declare v_vat numeric := greatest(fabula.setting_num('prod.vat_kg', 800), 50); v_min numeric := fabula.setting_num('milk.min_run_kg', 300);
        v_shelf int := fabula.setting_num('milk.raw_shelf_days', 2)::int; v_whey_pct numeric := fabula.setting_num('effluent.whey_pct_of_milk', 62);
        v_prod record; v_preset record; v_y jsonb; v_ric jsonb; m record; v_n int; v_kg numeric; v_rest numeric; v_seq int := 0;
        milk jsonb := '[]'; props jsonb := '[]'; v_doses jsonb; i int;
begin
  perform fabula.require_perm('produzione', 1);
  -- main product: the active finished good that is not a by-product (mozzarella), with its default preset
  select p.id, p.name, p.byproduct_product_id into v_prod from fabula.products p
   where p.kind = 'finished_good' and p.active and not exists (select 1 from fabula.products q where q.byproduct_product_id = p.id)
   order by (p.sku = 'MOZ-DOP-KG') desc, p.name limit 1;
  select pp.id, pp.name into v_preset from fabula.process_presets pp where pp.product_id = v_prod.id and pp.active order by pp.is_default desc, pp.created_at limit 1;
  v_y := fabula.expected_yield(v_prod.id, v_preset.id);
  if v_prod.byproduct_product_id is not null then v_ric := fabula.expected_yield(v_prod.byproduct_product_id); end if;

  for m in
    select mi.id, mi.milk_lot, mi.qty_kg, mi.intake_date, mi.intake_time, pa.legal_name supplier,
           least(coalesce(s.shipped_at, 'infinity'::timestamptz), (mi.intake_date + coalesce(mi.intake_time, '06:00')) at time zone 'Europe/Rome') + interval '60 hours' use_by,
           coalesce((select sum(bm.qty_kg) from fabula.batch_milk_inputs bm where bm.milk_intake_id = mi.id), 0) used
      from fabula.milk_intake mi
      left join fabula.parties pa on pa.id = mi.supplier_id
      left join fabula.milk_shipments s on s.id = mi.shipment_id
     where mi.accepted is not false and mi.intake_date between p_date - (v_shelf + 1) and p_date and coalesce(mi.source, '') <> 'simulation'
     order by mi.intake_date, mi.intake_time nulls first, mi.created_at
  loop
    v_rest := round(m.qty_kg - m.used, 1);
    continue when v_rest < 1;
    milk := milk || jsonb_build_object('milk_intake_id', m.id, 'milk_lot', m.milk_lot, 'supplier', m.supplier, 'intake_date', m.intake_date,
              'kg', m.qty_kg, 'used_kg', m.used, 'left_kg', v_rest, 'use_by', m.use_by,
              'hours_left', round(extract(epoch from (m.use_by - now())) / 3600, 1));
    -- equal vat loads: 1,150 kg with an 800 kg vat → 2 × 575 kg
    v_n := ceil(v_rest / v_vat)::int;
    for i in 1..v_n loop
      v_kg := case when i < v_n then round(v_rest / v_n, 1) else v_rest - round(v_rest / v_n, 1) * (v_n - 1) end;
      v_seq := v_seq + 1;
      select coalesce(jsonb_agg(jsonb_build_object('sku', r.sku, 'name', r.name, 'unit', r.unit,
                       'qty', case when r.round_up then ceil(r.qty_per_unit * v_kg) else round(r.qty_per_unit * v_kg, 3) end) order by r.step_order), '[]')
        into v_doses from fabula.v_recipe_active r where r.finished_product_id = v_prod.id and r.phase = 'start' and r.basis = 'per_kg_milk';
      props := props || jsonb_build_object('seq', v_seq, 'milk_intake_id', m.id, 'milk_lot', m.milk_lot, 'left_kg', v_rest, 'milk_kg', v_kg,
                 'product_id', v_prod.id, 'product', v_prod.name, 'preset_id', v_preset.id, 'preset', v_preset.name,
                 'yield_pct', v_y->'pct', 'yield_source', v_y->'source', 'expected_kg', round(v_kg * (v_y->>'pct')::numeric / 100, 1),
                 'whey_kg', round(v_kg * v_whey_pct / 100, 0),
                 'ricotta_kg', case when v_ric is not null then round(v_kg * v_whey_pct / 100 * (v_ric->>'pct')::numeric / 100, 1) end,
                 'doses', v_doses, 'use_by', m.use_by, 'small', v_rest < v_min);
    end loop;
  end loop;

  return jsonb_build_object(
    'date', p_date, 'vat_kg', v_vat, 'min_run_kg', v_min, 'tolerance_pts', v_y->'tolerance_pts',
    'yield', v_y, 'product', v_prod.name,
    'target', (select jsonb_build_object('milk_kg', mp.milk_kg, 'planned_output_kg', mp.planned_output_kg, 'status', mp.status)
                 from fabula.milk_plans mp where mp.plan_date = p_date and mp.status in ('approved', 'proposed') order by (mp.status = 'approved') desc limit 1),
    'milk', milk, 'proposals', props,
    'open', (select coalesce(jsonb_agg(jsonb_build_object('batch_id', b.id, 'batch_lot', b.batch_lot, 'product', p.name, 'input_kind', b.input_kind,
                       'milk_in_kg', b.milk_in_kg, 'started_at', b.started_at, 'batch_date', b.batch_date,
                       'expected_kg', round(b.milk_in_kg * (fabula.expected_yield(b.product_id, b.preset_id)->>'pct')::numeric / 100, 1)) order by b.started_at), '[]')
               from fabula.production_batches b join fabula.products p on p.id = b.product_id
              where b.output_kg is null and b.batch_date >= p_date - 3 and b.source is distinct from 'simulation'),
    'done', (select jsonb_build_object('batches', count(*), 'output_kg', coalesce(sum(b.output_kg), 0), 'milk_kg', coalesce(sum(b.milk_in_kg), 0),
                       'yield_pct', case when sum(b.milk_in_kg) > 0 then round(sum(b.output_kg) / sum(b.milk_in_kg) * 100, 1) end,
                       'flags', count(*) filter (where b.yield_flag is not null))
               from fabula.production_batches b
              where b.batch_date = p_date and b.output_kg is not null and b.product_id = v_prod.id and b.source is distinct from 'simulation'),
    'expected_kg', (select coalesce(sum((x->>'expected_kg')::numeric), 0) from jsonb_array_elements(props) x));
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

CREATE OR REPLACE FUNCTION fabula.consorzio_declaration(p_month date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'fabula', 'public', 'extensions'
AS $function$
declare m0 date; m1 date; j jsonb; v_appr uuid; v_kg numeric; v_issues jsonb; v_batches int; v_code text;
begin
  m0 := date_trunc('month', coalesce(p_month, (date_trunc('month', (now() at time zone 'Europe/Rome')::date) - interval '1 month')::date))::date;
  m1 := (m0 + interval '1 month')::date - 1;
  v_code := fabula.setting_text('dop.rina_code');
  select coalesce(sum(b.output_kg), 0), count(*) into v_kg, v_batches
    from fabula.production_batches b join fabula.products p on p.id = b.product_id
   where p.is_dop and b.batch_date between m0 and m1 and b.output_kg is not null;

  -- disciplinare checks (each item: what, how many, detail)
  select coalesce(jsonb_agg(i) filter (where (i->>'n')::int > 0), '[]') into v_issues from (
    select jsonb_build_object('check', 'codice_rina', 'it', 'Lotti DOP senza il codice RINA del caseificio: prima del codice non si possono vendere né dichiarare come DOP (Configurazione → Sicurezza alimentare e DOP)',
             'n', case when v_code is null then v_batches else 0 end, 'detail', '[]'::jsonb) i
    union all
    select jsonb_build_object('check', 'latte_60h', 'it', 'Latte lavorato oltre 60 h dall''arrivo (limite: 60 h dalla prima mungitura)',
             'n', count(*), 'detail', coalesce(jsonb_agg(jsonb_build_object('lot', x.batch_lot, 'milk_lot', x.milk_lot, 'hours', round(x.h, 1))), '[]'))
      from (select b.batch_lot, mi.milk_lot,
                   extract(epoch from (b.started_at - ((mi.intake_date + coalesce(mi.intake_time, '06:00')) at time zone 'Europe/Rome'))) / 3600 h
              from fabula.production_batches b join fabula.products p on p.id = b.product_id
              join fabula.batch_milk_inputs bmi on bmi.batch_id = b.id join fabula.milk_intake mi on mi.id = bmi.milk_intake_id
             where p.is_dop and b.batch_date between m0 and m1 and b.started_at is not null) x
     where x.h > 60
    union all
    select jsonb_build_object('check', 'grasso_proteine', 'it', 'Consegne sotto grasso 7,23 % o proteine 4,2 % (art. 3 disciplinare)',
             'n', count(*), 'detail', coalesce(jsonb_agg(jsonb_build_object('milk_lot', milk_lot, 'date', intake_date, 'fat_pct', fat_pct, 'protein_pct', protein_pct)), '[]'))
      from fabula.milk_intake where accepted and intake_date between m0 and m1 and (fat_pct < 7.23 or protein_pct < 4.2)
    union all
    select jsonb_build_object('check', 'fornitori_non_dop', 'it', 'Latte da fornitori non segnati come iscritti DOP (anagrafica)',
             'n', count(distinct mi.supplier_id), 'detail', coalesce(jsonb_agg(distinct p.legal_name), '[]'))
      from fabula.milk_intake mi join fabula.parties p on p.id = mi.supplier_id
     where mi.accepted and mi.intake_date between m0 and m1 and not p.is_dop_certified
    union all
    select jsonb_build_object('check', 'lotti_senza_latte', 'it', 'Lotti DOP senza latte collegato (tracciabilità)',
             'n', count(*), 'detail', coalesce(jsonb_agg(b.batch_lot), '[]'))
      from fabula.production_batches b join fabula.products p on p.id = b.product_id
     where p.is_dop and b.batch_date between m0 and m1 and b.output_kg is not null and coalesce(b.input_kind, 'milk') <> 'whey'
       and not exists (select 1 from fabula.batch_milk_inputs bmi where bmi.batch_id = b.id)
  ) s;

  select jsonb_build_object('month', to_char(m0, 'YYYY-MM'), 'from', m0, 'to', m1,
    'milk_in_kg', (select coalesce(sum(qty_kg), 0) from fabula.milk_intake where accepted and intake_date between m0 and m1),
    'milk_rejected_kg', (select coalesce(sum(qty_kg), 0) from fabula.milk_intake where accepted = false and intake_date between m0 and m1),
    'milk_suppliers', (select coalesce(jsonb_agg(jsonb_build_object('supplier', p.legal_name, 'kg', kg, 'dop_certified', p.is_dop_certified)), '[]')
                       from (select supplier_id, round(sum(qty_kg), 1) kg from fabula.milk_intake where accepted and intake_date between m0 and m1 group by supplier_id) x join fabula.parties p on p.id = x.supplier_id),
    'milk_processed_kg', (select coalesce(sum(b.milk_in_kg), 0) from fabula.production_batches b join fabula.products p on p.id = b.product_id where p.is_dop and b.batch_date between m0 and m1 and b.output_kg is not null),
    'mozzarella_dop_kg', v_kg,
    'by_product', (select coalesce(jsonb_agg(jsonb_build_object('product', name, 'kg', kg, 'batches', n)), '[]')
                     from (select p.name, sum(b.output_kg) kg, count(*) n from fabula.production_batches b join fabula.products p on p.id = b.product_id
                            where p.is_dop and b.batch_date between m0 and m1 and b.output_kg is not null group by p.name) y),
    'batches', v_batches,
    'labels_printed', (select coalesce(sum(qty_printed), 0) from fabula.labels l where l.kind in ('batch_lot','retail_pack','wholesale_case') and (l.printed_at at time zone 'Europe/Rome')::date between m0 and m1),
    'lots', (select coalesce(jsonb_agg(b.batch_lot order by b.batch_date, b.batch_lot), '[]') from fabula.production_batches b join fabula.products p on p.id = b.product_id where p.is_dop and b.batch_date between m0 and m1 and b.output_kg is not null),
    'sold_kg', (select coalesce(-sum(sm.qty), 0) from fabula.stock_moves sm join fabula.products p on p.id = sm.product_id where p.is_dop and sm.move_type = 'sale' and (sm.moved_at at time zone 'Europe/Rome')::date between m0 and m1),
    'fees_estimate_eur', jsonb_build_object(
        'consorzio', round(v_kg * fabula.setting_num('dop.consorzio_eur_kg', 0.044), 2),
        'rina_variable', round(v_kg * fabula.setting_num('dop.rina_eur_kg', 0.002), 2),
        'note', 'Contributo Consorzio stimato: confermare la tariffa €/kg con il Consorzio'),
    'issues', v_issues,
    'rina_code', v_code,
    'consorzio', jsonb_build_object('name', 'Consorzio per la Tutela del Formaggio Mozzarella di Bufala Campana', 'address', 'Via Gasparri 1, 81100 Caserta',
                                    'cf', '03497570634', 'piva', '02236840613', 'sdi', 'USAL8PV'),
    'company', fabula.company_name(),
    'note', 'Preparata in automatico dai dati di produzione. Invio al Consorzio a mano finché non c''è il modulo/portale ufficiale.') into j;

  -- R-01: not under DOP control yet and nothing DOP made this month → nothing to declare, nothing to decide
  if v_code is null and v_batches = 0 then
    return j || jsonb_build_object('approval_created', false, 'skipped', true,
      'skip_it', format('Nessuna dichiarazione per %s: il caseificio non ha ancora il codice RINA (dop.rina_code) e nel mese non ci sono lotti DOP', to_char(m0, 'MM/YYYY')));
  end if;

  if not exists (select 1 from fabula.approvals where kind = 'dop_declaration' and payload->>'month' = to_char(m0, 'YYYY-MM') and status in ('pending','approved')) then
    insert into fabula.approvals (kind, requested_by, summary, payload, related_table)
    values ('dop_declaration', 'agent:monthly_review',
            format('Dichiarazione Consorzio %s: latte %s kg → mozzarella DOP %s kg in %s lotti, %s etichette%s', to_char(m0, 'MM/YYYY'),
                   round((j->>'milk_processed_kg')::numeric), round(v_kg), j->>'batches', j->>'labels_printed',
                   case when jsonb_array_length(v_issues) > 0 then format(' · %s controlli da vedere', jsonb_array_length(v_issues)) else '' end),
            j, 'consorzio') returning id into v_appr;
    j := j || jsonb_build_object('approval_id', v_appr, 'approval_created', true);
  else
    j := j || jsonb_build_object('approval_created', false);
  end if;
  return j;
end $function$;
