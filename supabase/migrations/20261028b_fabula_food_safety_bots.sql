-- v0.28b · Sicurezza alimentare nei bot: compliance_calendar (Scadenze, martedì), haccp_evening_status (Promemoria serale),
-- ops_health_check (Salute sistema), monthly_review → food_safety_summary (Revisione mensile).
-- Nota connettore: niente punto e virgola dentro le stringhe SQL (il connettore annulla la chiamata).

-- ============ 1. Monthly food-safety summary ============
create or replace function fabula.food_safety_summary(p_month date default null) returns jsonb language plpgsql stable as $$
declare m0 date; m1 date; v_today date := (now() at time zone 'Europe/Rome')::date;
        v_ccp jsonb; v_missing jsonb; v_nc jsonb; v_lab jsonb; v_pest jsonb; v_tr jsonb; v_cal jsonb; v_hold jsonb; v_ccp_nc int; v_open_crit int;
begin
  m0 := date_trunc('month', coalesce(p_month, (date_trunc('month', v_today) - interval '1 month')::date))::date;
  m1 := (m0 + interval '1 month')::date - 1;

  select coalesce(jsonb_agg(jsonb_build_object('ccp', coalesce(cp.ccp_no, cp.code), 'code', cp.code, 'name', cp.name, 'logs', x.n, 'ok', x.ok, 'warning', x.w, 'nc', x.nc,
                                               'min', x.mn, 'max', x.mx, 'unit', cp.unit) order by cp.sort), '[]'),
         coalesce(sum(x.nc), 0)
    into v_ccp, v_ccp_nc
  from fabula.haccp_control_points cp
  join lateral (select count(*) n, count(*) filter (where result = 'ok') ok, count(*) filter (where result = 'warning') w,
                       count(*) filter (where result = 'non_conformity') nc, min(measured_value) mn, max(measured_value) mx
                from fabula.haccp_log l where l.control_point_id = cp.id and (l.logged_at at time zone 'Europe/Rome')::date between m0 and m1) x on true
  where cp.active;

  select coalesce(jsonb_agg(b.batch_lot order by b.batch_lot), '[]') into v_missing
  from fabula.production_batches b
  where b.batch_date between m0 and m1 and b.source <> 'simulation'
    and not exists (select 1 from fabula.haccp_log l join fabula.haccp_control_points cp on cp.id = l.control_point_id
                    where l.batch_id = b.id and cp.code = case when b.input_kind = 'whey' then 'CCP-RIC' else 'CCP-STRETCH' end);

  select count(*) into v_open_crit from fabula.non_conformities where severity = 'critical' and status in ('open','investigating');
  select jsonb_build_object(
      'opened', (select count(*) from fabula.non_conformities where (opened_at at time zone 'Europe/Rome')::date between m0 and m1),
      'by_severity', (select coalesce(jsonb_object_agg(sev, n), '{}') from (select severity::text sev, count(*) n from fabula.non_conformities
                       where (opened_at at time zone 'Europe/Rome')::date between m0 and m1 group by 1) s),
      'still_open', (select count(*) from fabula.non_conformities where status in ('open','investigating')),
      'critical_open', v_open_crit,
      'open_list', (select coalesce(jsonb_agg(jsonb_build_object('opened', to_char(opened_at at time zone 'Europe/Rome', 'DD/MM'), 'severity', severity, 'description', description) order by opened_at desc), '[]')
                    from (select * from fabula.non_conformities where status in ('open','investigating') order by opened_at desc limit 10) z))
    into v_nc;

  select jsonb_build_object(
      'plan_active', exists (select 1 from fabula.v_lab_plan_status where plan_active),
      'taken', (select count(*) from fabula.lab_samples where taken_on between m0 and m1),
      'by_outcome', (select coalesce(jsonb_object_agg(outcome, n), '{}') from (select outcome, count(*) n from fabula.lab_samples where taken_on between m0 and m1 group by 1) s),
      'non_conformi', (select coalesce(jsonb_agg(jsonb_build_object('sample', sample_code, 'test', test_code, 'analyte', analyte_it, 'lot', lot_number, 'result', result_it)), '[]')
                       from fabula.v_lab_samples_recent where outcome = 'non_conforme' and taken_on between m0 and m1),
      'pending_over_14d', (select coalesce(jsonb_agg(sample_code), '[]') from fabula.lab_samples where outcome = 'in_attesa' and taken_on < v_today - 14),
      'overdue', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'analyte', analyte_it, 'due', next_due) order by next_due), '[]')
                  from fabula.v_lab_plan_status where plan_active and next_due < v_today))
    into v_lab;

  select jsonb_build_object(
      'inspections_internal', count(*) filter (where by_kind = 'interno'),
      'visits_company', count(*) filter (where by_kind = 'ditta'),
      'with_activity', count(*) filter (where activity_found),
      'activity_inside', count(*) filter (where activity_inside),
      'last_company_visit', (select max(inspected_on) from fabula.pest_inspections where by_kind = 'ditta'))
    into v_pest
  from fabula.pest_inspections where inspected_on between m0 and m1;

  select jsonb_build_object(
      'by_status', (select coalesce(jsonb_object_agg(status, n), '{}') from (select status, count(*) n from fabula.v_training_matrix group by 1) s),
      'gaps', (select coalesce(jsonb_agg(jsonb_build_object('person', full_name, 'course', course_name, 'status', status, 'expires_on', expires_on) order by full_name, sort), '[]')
               from fabula.v_training_matrix where status <> 'valido'))
    into v_tr;

  select jsonb_build_object(
      'checks', (select count(*) from fabula.calibration_checks where (checked_at at time zone 'Europe/Rome')::date between m0 and m1),
      'ko', (select count(*) from fabula.calibration_checks where result = 'ko' and (checked_at at time zone 'Europe/Rome')::date between m0 and m1),
      'out_of_service', (select coalesce(jsonb_agg(code), '[]') from fabula.equipment where out_of_service and active),
      'checks_overdue', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'due', next_check_on) order by next_check_on), '[]')
                         from fabula.v_instruments where next_check_on < v_today and coalesce(check_interval_days, 0) >= 7),
      'never_checked', (select coalesce(jsonb_agg(code), '[]') from fabula.v_instruments where last_checked_on is null and last_calibrated_on is null))
    into v_cal;

  select coalesce(jsonb_agg(jsonb_build_object('lot', batch_lot, 'product', product, 'reason', hold_reason, 'kg_on_hand', round(kg_on_hand, 1), 'kg_sold', round(kg_sold, 1))), '[]')
    into v_hold from fabula.v_lots_on_hold;

  return jsonb_build_object(
    'month', to_char(m0, 'YYYY-MM'),
    'ccp', v_ccp, 'batches_without_ccp', v_missing, 'non_conformities', v_nc, 'lab', v_lab, 'pest', v_pest,
    'training', v_tr, 'instruments', v_cal, 'lots_on_hold', v_hold,
    'headline_it', format('CCP fuori limite: %s · lotti senza CCP: %s · NC critiche aperte: %s · campioni: %s · lotti bloccati: %s · strumenti fuori servizio: %s',
                          v_ccp_nc, jsonb_array_length(v_missing), v_open_crit, v_lab->>'taken', jsonb_array_length(v_hold), jsonb_array_length(v_cal->'out_of_service')));
end $$;

-- ============ 2. Compliance calendar (weekly bot) ============
create or replace function fabula.compliance_calendar(p_date date default ((now() at time zone 'Europe/Rome'::text))::date)
returns jsonb language sql stable as $function$
with items as (
  select 'calibration' as kind, e.code as ref, e.name as subject, e.next_calibration_on as due_on, e.last_calibrated_on as last_done,
         e.calibration_interval_days as interval_days, e.technician_contact as contact, null::text as responsible, e.id as equipment_id, null::uuid as deadline_id
  from fabula.equipment e where e.active and e.calibration_interval_days is not null
  union all
  select 'verifica', e.code, e.name || ' · verifica interna', case when e.last_checked_on is not null then e.last_checked_on + e.check_interval_days end,
         e.last_checked_on, e.check_interval_days, null, 'casaro', e.id, null
  from fabula.equipment e where e.active and e.check_interval_days >= 7
  union all
  select 'maintenance', e.code, e.name, case when e.last_maintenance_on is not null then e.last_maintenance_on + e.maintenance_interval_days end,
         e.last_maintenance_on, e.maintenance_interval_days, e.technician_contact, null, e.id, null
  from fabula.equipment e where e.active and e.maintenance_interval_days is not null
  union all
  select 'training', t.badge_code, t.full_name || ' · ' || t.course_name, t.expires_on, t.completed_on, t.validity_days, t.provider, t.full_name, null, null
  from fabula.v_training_matrix t
  union all
  select 'campionamento', l.code, l.analyte_it || ' (' || l.matrix || ')', l.next_due, l.last_taken, l.frequency_days, l.lab, l.responsible, null, null
  from fabula.v_lab_plan_status l where l.plan_active
  union all
  select d.kind, null, d.subject_it, d.due_on, null, d.interval_days, d.contact, d.responsible, null, d.id
  from fabula.compliance_deadlines d where d.done_on is null),
tagged as (
  select i.*, case when due_on is null then 'unknown' when due_on < p_date then 'overdue' when due_on <= p_date + 30 then 'due_30' when due_on <= p_date + 60 then 'due_60' else 'later' end as bucket,
         case when due_on is not null then due_on - p_date end as days
  from items i),
j as (
  select bucket, jsonb_agg(jsonb_build_object('kind', kind, 'ref', ref, 'subject', subject, 'due_on', due_on, 'days', days, 'last_done', last_done,
                                               'interval_days', interval_days, 'contact', contact, 'responsible', responsible, 'deadline_id', deadline_id) order by due_on nulls last, kind) items
  from tagged group by bucket),
drafts as (
  select coalesce(jsonb_agg(jsonb_build_object('ref', ref, 'kind', kind, 'contact', contact,
           'message_it', format('Buongiorno, per La Perla del Cilento (Agropoli) dovremmo programmare %s di %s (%s)%s. Quando potete passare? Grazie.',
                                case kind when 'calibration' then 'la taratura' else 'la manutenzione periodica' end, subject, ref,
                                case when bucket = 'overdue' then format(' — scaduta il %s', to_char(due_on,'DD/MM/YYYY')) else format(' entro il %s', to_char(due_on,'DD/MM/YYYY')) end))
           order by due_on), '[]') d
  from tagged where kind in ('calibration','maintenance') and bucket in ('overdue','due_30')),
lab_due as (
  select l.* from fabula.v_lab_plan_status l where l.plan_active and l.next_due <= p_date + 14),
lab_draft as (
  select case when count(*) = 0 then null else jsonb_build_object(
           'to', nullif(fabula.setting_text('food.lab_email', ''), ''), 'lab', nullif(fabula.setting_text('food.lab_name', ''), ''),
           'subject_it', 'Richiesta campionamenti — La Perla del Cilento, Agropoli',
           'message_it', format('Buongiorno, per il nostro piano di autocontrollo vorremmo programmare entro il %s le seguenti analisi: %s. Potete indicarci giorno per la consegna o il ritiro dei campioni, contenitori/tamponi necessari e preventivo? Grazie.',
                                to_char(p_date + 14, 'DD/MM/YYYY'), string_agg(analyte_it || ' su ' || matrix || coalesce(' (' || sampling_point_it || ')', ''), ' — ' order by sort)),
           'tests', jsonb_agg(code order by sort)) end d
  from lab_due)
select jsonb_build_object(
  'date', p_date,
  'overdue',       coalesce((select items from j where bucket = 'overdue'), '[]'),
  'due_30',        coalesce((select items from j where bucket = 'due_30'), '[]'),
  'due_60',        coalesce((select items from j where bucket = 'due_60'), '[]'),
  'unknown_dates', coalesce((select items from j where bucket = 'unknown'), '[]'),
  'technician_drafts', (select d from drafts),
  'lab_request_draft', (select d from lab_draft),
  'food_safety', jsonb_build_object(
      'sampling_plan_active', exists (select 1 from fabula.v_lab_plan_status where plan_active),
      'lab_results_pending', (select coalesce(jsonb_agg(jsonb_build_object('sample', sample_code, 'analyte', analyte_it, 'taken_on', taken_on, 'days', days_waiting) order by taken_on), '[]')
                              from fabula.v_lab_samples_recent where outcome = 'in_attesa'),
      'instruments_out_of_service', (select coalesce(jsonb_agg(code), '[]') from fabula.equipment where out_of_service and active),
      'lots_on_hold', (select coalesce(jsonb_agg(batch_lot), '[]') from fabula.v_lots_on_hold),
      'nc_open', (select count(*) from fabula.non_conformities where status in ('open','investigating')),
      'nc_critical_open', (select count(*) from fabula.non_conformities where status in ('open','investigating') and severity = 'critical'),
      'pest_last_internal', (select max(inspected_on) from fabula.pest_inspections where by_kind = 'interno'),
      'pest_last_company', (select max(inspected_on) from fabula.pest_inspections where by_kind = 'ditta')),
  'counts', jsonb_build_object('overdue', (select count(*) from tagged where bucket='overdue'), 'due_30', (select count(*) from tagged where bucket='due_30'),
                               'due_60', (select count(*) from tagged where bucket='due_60'), 'unknown', (select count(*) from tagged where bucket='unknown')));
$function$;

-- ============ 3. Evening nudge ============
create or replace function fabula.haccp_evening_status(p_date date default ((now() at time zone 'Europe/Rome'::text))::date)
returns jsonb language plpgsql as $function$
declare items jsonb := '[]'; v_key text := 'haccp_evening:' || p_date; n int; n_ship int; n_milk int; n_abx int; v_real_prod boolean;
begin
  select coalesce(jsonb_agg(jsonb_build_object('code', 'cold:' || cp.code, 'label_it', 'Temperatura serale ' || coalesce(e.code, cp.name), 'scan', 'EQ:' || e.code) order by cp.code), '[]') into items
  from fabula.haccp_control_points cp left join fabula.equipment e on e.id = cp.equipment_id
  where cp.active and cp.frequency = 'twice_daily'
    and not exists (select 1 from fabula.haccp_log l where l.control_point_id = cp.id and l.logged_at::date = p_date and (l.logged_at at time zone 'Europe/Rome')::time >= time '15:00');
  if not exists (select 1 from fabula.haccp_log l join fabula.haccp_control_points cp on cp.id = l.control_point_id where cp.code = 'PRP-CLEAN' and l.logged_at::date = p_date) then
    items := items || jsonb_build_object('code', 'clean', 'label_it', 'Sanificazione fine turno', 'scan', 'CLEAN:');
  end if;
  if exists (select 1 from fabula.production_batches where batch_date = p_date) or exists (select 1 from fabula.sales_orders where order_date = p_date) then
    if not exists (select 1 from fabula.meter_readings where meter = 'elec_main' and read_at::date = p_date) then
      items := items || jsonb_build_object('code', 'kwh', 'label_it', 'Lettura contatore', 'scan', 'METER:elec_main'); end if;
  end if;
  v_real_prod := exists (select 1 from fabula.production_batches where batch_date = p_date and source <> 'simulation');
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
  n := jsonb_array_length(items);
  if n > 0 then
    insert into fabula.notices (key, severity, title_it, items, expires_at)
    values (v_key, 'alert', format('Prima di chiudere: %s cose da registrare', n), items, ((p_date + 1)::timestamp + time '05:00') at time zone 'Europe/Rome')
    on conflict (key) do update set items = excluded.items, title_it = excluded.title_it, resolved_at = null;
  else
    update fabula.notices set resolved_at = now() where key = v_key and resolved_at is null;
  end if;
  return jsonb_build_object('date', p_date, 'missing', items, 'count', n,
    'lots_on_hold', (select coalesce(jsonb_agg(batch_lot), '[]') from fabula.v_lots_on_hold),
    'is_simulation', exists (select 1 from fabula.simulation_runs where p_date between from_date and to_date),
    'closed_day', not (exists (select 1 from fabula.production_batches where batch_date = p_date) or exists (select 1 from fabula.sales_orders where order_date = p_date)));
end $function$;

-- ============ 4. System health ============
create or replace function fabula.ops_health_check(p_date date default ((now() at time zone 'Europe/Rome'::text))::date)
returns jsonb language plpgsql as $function$
declare bots jsonb; dq jsonb := '[]'; n_exp int;
begin
  select jsonb_agg(jsonb_build_object('agent', e.agent, 'ran', r.n > 0, 'runs', coalesce(r.n, 0), 'errors', coalesce(r.err, 0), 'last_error', r.last_error) order by e.agent) into bots
  from fabula.expected_bots(p_date) e
  left join lateral (select count(*) n, count(*) filter (where status = 'error') err, max(error) filter (where status = 'error') last_error
                     from fabula.agent_runs ar where ar.agent = e.agent and (ar.started_at at time zone 'Europe/Rome')::date = p_date) r on true;
  update fabula.approvals set status = 'expired' where status = 'pending' and expires_at < now();
  with issues as (
    select 'open_batches' k, 'Lotti aperti da più di un giorno: ' || string_agg(batch_lot, ', ') t, count(*) c
      from fabula.production_batches where output_kg is null and batch_date < p_date and source <> 'simulation' having count(*) > 0
    union all
    select 'negative_stock', 'Giacenza negativa: ' || string_agg(sku || ' ' || round(qty_on_hand,1), ', '), count(*)
      from (select sku, sum(qty_on_hand) qty_on_hand from fabula.v_stock_on_hand group by sku having sum(qty_on_hand) < -0.01) x having count(*) > 0
    union all
    select 'unlabelled_lots', 'Lotti chiusi senza etichetta stampata: ' || string_agg(b.batch_lot, ', '), count(*)
      from fabula.production_batches b where b.output_kg is not null and b.batch_date between p_date - 7 and p_date and b.source <> 'simulation'
       and not exists (select 1 from fabula.labels l where l.batch_id = b.id) having count(*) > 0
    union all
    select 'milk_no_ddt_photo', 'Arrivi latte senza foto DDT (7 gg): ' || count(*), count(*)
      from fabula.milk_intake m where m.intake_date between p_date - 7 and p_date and m.source <> 'simulation'
       and not exists (select 1 from fabula.documents d where d.kind = 'ddt_in' and d.document_date = m.intake_date) having count(*) > 0
    union all
    select 'unknown_lot_sales', 'Vendite su lotti sconosciuti (7 gg): ' || string_agg(distinct sm.lot_number, ', '), count(*)
      from fabula.stock_moves sm where sm.move_type = 'sale' and sm.moved_at::date between p_date - 7 and p_date and sm.source <> 'simulation'
       and sm.lot_number is not null and not exists (select 1 from fabula.production_batches b where b.batch_lot = sm.lot_number) having count(*) > 0
    union all
    select 'stock_count_overdue', 'Conta magazzino non fatta da ' || (p_date - max(counted_at::date)) || ' giorni', 1
      from fabula.stock_counts where status = 'posted' having max(counted_at::date) < p_date - 9
    union all
    select 'stock_count_never', 'Nessuna conta magazzino registrata', 1 where not exists (select 1 from fabula.stock_counts where status = 'posted')
    union all
    select 'approvals_stale', 'Approvazioni in attesa da oltre 3 giorni: ' || count(*), count(*)
      from fabula.approvals where status = 'pending' and requested_at < now() - interval '3 days' having count(*) > 0
    union all
    select 'po_not_sent', 'Ordini approvati ma non ancora inviati al fornitore: ' || string_agg(po_number, ', '), count(*)
      from fabula.purchase_orders where status = 'approved' and updated_at < now() - interval '1 day' having count(*) > 0
    union all
    select 'placeholder_parties', 'Fornitori/clienti ancora con nome segnaposto (da rinominare nella console): ' || string_agg(legal_name, ', '), count(*)
      from fabula.parties where notes = 'placeholder' and active having count(*) > 0
    union all
    select 'tablet_silent', 'Nessuna scansione dal tablet oggi (giorno lavorativo)', 1
      where extract(isodow from p_date) between 1 and 6 and not exists (select 1 from fabula.scan_events where scanned_at::date = p_date)
        and not exists (select 1 from fabula.simulation_runs where p_date between from_date and to_date)
    -- food safety (v0.28)
    union all
    select 'nc_critical_open', 'Non conformità CRITICHE aperte: ' || count(*), count(*)
      from fabula.non_conformities where severity = 'critical' and status in ('open','investigating') having count(*) > 0
    union all
    select 'lots_on_hold', 'Lotti bloccati per sicurezza alimentare: ' || string_agg(batch_lot, ', '), count(*)
      from fabula.production_batches where food_safety_hold having count(*) > 0
    union all
    select 'held_lot_sold', 'Vendite registrate su lotti bloccati (7 gg): ' || string_agg(distinct sm.lot_number, ', '), count(*)
      from fabula.stock_moves sm join fabula.production_batches b on b.batch_lot = sm.lot_number and b.food_safety_hold
      where sm.move_type = 'sale' and sm.moved_at > greatest(coalesce(b.hold_at, now()), now() - interval '7 days') having count(*) > 0
    union all
    select 'ccp_missing', 'Lotti degli ultimi 3 giorni senza registrazione CCP (filatura/ricotta): ' || string_agg(b.batch_lot, ', '), count(*)
      from fabula.production_batches b where b.batch_date between p_date - 3 and p_date - 1 and b.source <> 'simulation'
       and not exists (select 1 from fabula.haccp_log l join fabula.haccp_control_points cp on cp.id = l.control_point_id
                       where l.batch_id = b.id and cp.code = case when b.input_kind = 'whey' then 'CCP-RIC' else 'CCP-STRETCH' end) having count(*) > 0
    union all
    select 'lab_pending', 'Referti di laboratorio attesi da oltre 14 giorni: ' || string_agg(sample_code, ', '), count(*)
      from fabula.lab_samples where outcome = 'in_attesa' and taken_on < p_date - 14 having count(*) > 0
    union all
    select 'instrument_out_of_service', 'Strumenti fuori servizio (fuori tolleranza): ' || string_agg(code, ', '), count(*)
      from fabula.equipment where out_of_service and active having count(*) > 0
    union all
    select 'pest_inside_7d', 'Infestanti trovati all''interno negli ultimi 7 giorni', count(*)
      from fabula.pest_inspections where activity_inside and inspected_on >= p_date - 7 having count(*) > 0
  )
  select coalesce(jsonb_agg(jsonb_build_object('key', k, 'text', t, 'count', c)), '[]') into dq from issues;
  return jsonb_build_object('date', p_date, 'bots', coalesce(bots, '[]'),
    'bots_missing', (select coalesce(jsonb_agg(b->>'agent'), '[]') from jsonb_array_elements(coalesce(bots,'[]')) b where not (b->>'ran')::boolean),
    'bots_errors', (select coalesce(sum((b->>'errors')::int), 0) from jsonb_array_elements(coalesce(bots,'[]')) b),
    'data_quality', dq, 'issues', jsonb_array_length(dq),
    'is_simulation', exists (select 1 from fabula.simulation_runs where p_date - 1 between from_date and to_date));
end $function$;

-- ============ 5. Monthly review gets the food-safety section ============
do $$ declare d text; begin
  d := pg_get_functiondef('fabula.monthly_review(date)'::regprocedure);
  if position('food_safety' in d) = 0 then
    d := replace(d, '''recall_drill'', drill,', '''recall_drill'', drill, ''food_safety'', fabula.food_safety_summary(m0),');
    execute d;
  end if;
end $$;
