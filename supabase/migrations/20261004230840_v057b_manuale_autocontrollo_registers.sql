-- v0.57b · Manuale di Autocontrollo (04/10/2026) · seconda parte (sezioni 7–8, la prima è 20261004230700_v057a)
-- Ogni registrazione HACCP rimanda al suo modulo MOD-xx, alla sezione del Manuale di Autocontrollo e alla revisione in vigore.
-- Documento: "Manuale di Autocontrollo — Caseificio di Agropoli" (link in food.manuale_url). Sostituisce il vecchio "Piano HACCP".
--  1 settings food.manuale_*, food.responsabile_autocontrollo, food.ce_approval_no, food.records_retention_years
--  2 haccp_forms: i 23 moduli di registrazione del manuale (§11), con sezione, frequenza, chi, dove si compila, stato
--  3 form_code su haccp_control_points e task_schedules · records_it dei punti di controllo con il codice modulo
--  4 nuovi controlli che il manuale richiede: valvola deviatrice (MOD-02), siero-innesto (MOD-03), salamoia (MOD-17)
--    + attività T-VALVE (ogni giorno) e T-BRINE (ogni settimana) · v_tasks_open espone il codice del punto di controllo
--  5 controllo all'arrivo merci (MOD-15): goods_receipts.inspection_* + record_receipt_check() (NC se non conforme)
--  6 haccp_register_reviews + mark_register_reviewed(): la verifica settimanale dei registri (§11, §12)
--  7 manual_ref(), haccp_register(): il registro stampabile di un modulo per periodo, con intestazione del manuale
--  8 haccp_forms_status(): stato dei registri per la console (registrazioni 30 gg, ultima, ultima verifica)
-- Nota connettore: nessun punto e virgola dentro le stringhe.

-- 7 · riferimento al manuale e registro stampabile -----------------------------------------------------------------
create or replace function fabula._it_num(x numeric) returns text language sql immutable as $$
  select case when x is null then '' when x::text like '%.%' then replace(rtrim(rtrim(x::text, '0'), '.'), '.', ',') else x::text end $$;
create or replace function fabula._it_dt(x timestamptz) returns text language sql stable as $$
  select coalesce(to_char(x at time zone 'Europe/Rome', 'DD/MM/YYYY HH24:MI'), '') $$;
create or replace function fabula._it_d(x date) returns text language sql immutable as $$
  select coalesce(to_char(x, 'DD/MM/YYYY'), '') $$;
create or replace function fabula._it_res(x fabula.haccp_result) returns text language sql immutable as $$
  select case x when 'ok' then 'conforme' when 'warning' then 'allerta' when 'non_conformity' then 'NON CONFORME' else '' end $$;
create or replace function fabula._setting(p_key text) returns text language sql stable security definer set search_path = fabula, public as $$
  select nullif(trim(value), '') from fabula.settings where key = p_key $$;

-- 'MOD-05 · Manuale di Autocontrollo rev. 0 del 04/10/2026 · §7.8 · §8.2'
create or replace function fabula.manual_ref(p_form text) returns text language sql stable security definer set search_path = fabula, public as $$
  select f.code || ' · Manuale di Autocontrollo rev. ' || coalesce(fabula._setting('food.manuale_rev'), '?')
         || coalesce(' del ' || to_char(fabula._setting('food.manuale_data')::date, 'DD/MM/YYYY'), '')
         || case when coalesce(fabula._setting('food.manuale_stato'), 'bozza') <> 'firmato' then ' (bozza)' else '' end
         || ' · ' || f.manual_section
  from fabula.haccp_forms f where f.code = upper(p_form) $$;

create or replace function fabula.haccp_register(p_form text, p_from date default null, p_to date default null)
returns jsonb language plpgsql stable security definer set search_path = fabula, public as $$
declare
  f fabula.haccp_forms%rowtype; d0 date; d1 date; cols jsonb; rws jsonb := '[]'::jsonb; hdr jsonb; revs jsonb;
begin
  perform fabula.require_perm('haccp', 1);
  select * into f from fabula.haccp_forms where code = upper(trim(p_form));
  if f.code is null then raise exception 'Modulo sconosciuto: %', p_form; end if;
  d1 := coalesce(p_to, (now() at time zone 'Europe/Rome')::date);
  d0 := coalesce(p_from, d1 - 30);
  if d0 > d1 then raise exception 'Periodo non valido: la data iniziale è dopo quella finale'; end if;
  if d1 - d0 > 400 then raise exception 'Periodo troppo lungo (massimo 400 giorni): stampa un anno alla volta'; end if;

  if f.register_kind = 'milk' then
    cols := '[["quando","Data e ora"],["fornitore","Fornitore"],["lotto","Lotto / cisterna"],["kg","kg"],["temp","Temp. °C"],["esito_temp","CCP 1a"],["abx","CCP 1b antibiotici"],["accettato","Accettato"],["ddt","DDT"],["operatore","Ricevuto da"]]';
    select coalesce(jsonb_agg(jsonb_build_object(
             'quando', fabula._it_d(mi.intake_date) || ' ' || coalesce(left(mi.intake_time::text, 5), ''),
             'fornitore', coalesce(p.legal_name, ''), 'lotto', coalesce(mi.milk_lot, ''), 'kg', fabula._it_num(mi.qty_kg),
             'temp', fabula._it_num(mi.temperature_c), 'esito_temp', coalesce(fabula._it_res(t.result), 'non registrato'),
             'abx', case a.v when 0 then 'negativo' when 1 then 'POSITIVO' else 'non registrato' end,
             'accettato', case when mi.accepted is false then 'NO · ' || coalesce(mi.rejection_reason, '') else 'sì' end,
             'ddt', coalesce(mi.ddt_number, ''), 'operatore', coalesce(mi.received_by, s.full_name, ''),
             '_ko', mi.accepted is false or t.result = 'non_conformity' or a.v = 1 or t.result is null or a.v is null, '_warn', t.result = 'warning')
           order by mi.intake_date, mi.intake_time), '[]'::jsonb) into rws
    from fabula.milk_intake mi
    left join fabula.parties p on p.id = mi.supplier_id
    left join fabula.staff s on s.id = mi.received_by_id
    left join lateral (select l.result from fabula.haccp_log l join fabula.haccp_control_points c on c.id = l.control_point_id
                       where c.code = 'CCP-MILK-TEMP' and l.logged_at between mi.created_at - interval '20 minutes' and mi.created_at + interval '20 minutes'
                       order by abs(extract(epoch from l.logged_at - mi.created_at)) limit 1) t on true
    left join lateral (select l.measured_value v from fabula.haccp_log l join fabula.haccp_control_points c on c.id = l.control_point_id
                       where c.code = 'CCP-MILK-ABX' and l.logged_at between mi.created_at - interval '20 minutes' and mi.created_at + interval '20 minutes'
                       order by abs(extract(epoch from l.logged_at - mi.created_at)) limit 1) a on true
    where mi.intake_date between d0 and d1 and coalesce(mi.source, '') <> 'simulation';

  elsif f.register_kind = 'ccp' then
    cols := '[["quando","Data e ora"],["controllo","Controllo"],["valore","Valore"],["limite","Limite"],["esito","Esito"],["lotto","Lotto"],["operatore","Operatore"],["azione","Azione correttiva / note"]]';
    select coalesce(jsonb_agg(jsonb_build_object(
             'quando', fabula._it_dt(l.logged_at),
             'controllo', concat_ws(' ', nullif(c.ccp_no, 'PRP'), c.name),
             'valore', case when c.unit = 'esito' then case l.measured_value when 0 then 'ok' when 1 then 'NON OK' else '' end
                            when l.measured_value is null then '' else fabula._it_num(l.measured_value) || ' ' || coalesce(c.unit, '') end,
             'limite', case when c.unit = 'esito' then 'esito ok'
                            when c.min_value is not null and c.max_value is not null then fabula._it_num(c.min_value) || '–' || fabula._it_num(c.max_value) || ' ' || coalesce(c.unit, '')
                            when c.min_value is not null then '≥ ' || fabula._it_num(c.min_value) || ' ' || coalesce(c.unit, '')
                            when c.max_value is not null then '≤ ' || fabula._it_num(c.max_value) || ' ' || coalesce(c.unit, '')
                            when c.code = 'PRP-CLEAN' then 'checklist completa' else 'da definire' end,
             'esito', fabula._it_res(l.result), 'lotto', coalesce(b.batch_lot, ''),
             'operatore', coalesce(l.operator, s.full_name, l.source, ''), 'azione', coalesce(l.corrective_action, ''),
             '_ko', l.result = 'non_conformity', '_warn', l.result = 'warning')
           order by l.logged_at), '[]'::jsonb) into rws
    from fabula.haccp_log l
    join fabula.haccp_control_points c on c.id = l.control_point_id
    left join fabula.production_batches b on b.id = l.batch_id
    left join fabula.staff s on s.id = l.operator_id
    where c.form_code = f.code and (l.logged_at at time zone 'Europe/Rome')::date between d0 and d1 and coalesce(l.source, '') <> 'simulation';

  elsif f.register_kind = 'batch' then
    cols := '[["data","Data"],["lotto","Lotto"],["prodotto","Prodotto"],["latte","Latte kg"],["resa_kg","Prodotto kg"],["resa","Resa %"],["innesto","Siero-innesto °SH"],["ph","pH cagliata"],["ccp3","CCP 3 pasta °C"],["esito","Esito CCP 3"],["casaro","Casaro"]]';
    select coalesce(jsonb_agg(jsonb_build_object(
             'data', fabula._it_d(b.batch_date), 'lotto', b.batch_lot, 'prodotto', coalesce(pr.name, ''),
             'latte', fabula._it_num(b.milk_in_kg), 'resa_kg', fabula._it_num(b.output_kg), 'resa', fabula._it_num(round(b.yield_pct, 1)),
             'innesto', fabula._it_num(inn.v), 'ph', fabula._it_num(b.curd_ph), 'ccp3', fabula._it_num(c3.v),
             'esito', case when coalesce(c3.n, 0) = 0 then 'NON REGISTRATO' else fabula._it_res(c3.r) end,
             'casaro', coalesce(b.casaro, s.full_name, ''),
             '_ko', coalesce(c3.n, 0) = 0 or c3.r = 'non_conformity')
           order by b.batch_date, b.batch_lot), '[]'::jsonb) into rws
    from fabula.production_batches b
    left join fabula.products pr on pr.id = b.product_id
    left join fabula.staff s on s.id = b.casaro_id
    left join lateral (select min(l.measured_value) v, (array_agg(l.result order by l.measured_value))[1] r, count(*) n
                       from fabula.haccp_log l join fabula.haccp_control_points c on c.id = l.control_point_id
                       where c.code = 'CCP-STRETCH' and l.batch_id = b.id) c3 on true
    left join lateral (select round(avg(l.measured_value), 1) v from fabula.haccp_log l join fabula.haccp_control_points c on c.id = l.control_point_id
                       where c.code = 'PRP-INNESTO' and (l.logged_at at time zone 'Europe/Rome')::date = b.batch_date) inn on true
    where b.batch_date between d0 and d1 and coalesce(b.input_kind, '') <> 'whey' and coalesce(b.source, '') <> 'simulation';

  elsif f.register_kind = 'pest' then
    cols := '[["data","Data"],["chi","Chi"],["rapporto","Rapporto"],["esito","Esito"],["segnalazioni","Postazioni con segnalazioni"],["prodotti","Prodotti usati"],["azioni","Azioni"],["operatore","Registrato da"]]';
    select coalesce(jsonb_agg(jsonb_build_object(
             'data', fabula._it_d(i.inspected_on),
             'chi', case when i.by_kind = 'ditta' then coalesce(i.company, 'ditta') || coalesce(' · ' || i.technician, '') else 'giro interno' end,
             'rapporto', concat_ws(' ', i.report_no, case when i.document_id is not null then '(PDF)' end),
             'esito', case when i.activity_inside then 'ATTIVITÀ INTERNA' when i.activity_found then 'attività esterna' else 'nessuna attività' end,
             'segnalazioni', coalesce((select string_agg((x ->> 'station') || ' ' || (x ->> 'status'), ', ') from jsonb_array_elements(coalesce(i.findings, '[]'::jsonb)) x where coalesce(x ->> 'status', 'ok') <> 'ok'), ''),
             'prodotti', coalesce(i.products_used, ''), 'azioni', coalesce(i.actions_it, ''), 'operatore', coalesce(s.full_name, ''),
             '_ko', i.activity_inside, '_warn', i.activity_found and not i.activity_inside)
           order by i.inspected_on), '[]'::jsonb) into rws
    from fabula.pest_inspections i left join fabula.staff s on s.id = i.staff_id
    where i.inspected_on between d0 and d1;

  elsif f.register_kind = 'calibration' then
    cols := '[["quando","Data e ora"],["strumento","Strumento"],["tipo","Tipo"],["metodo","Metodo"],["scarto","Scarto max"],["tolleranza","Tolleranza"],["esito","Esito"],["certificato","Centro / certificato"],["operatore","Eseguita da"]]';
    select coalesce(jsonb_agg(jsonb_build_object(
             'quando', fabula._it_dt(k.checked_at), 'strumento', e.code || ' · ' || e.name,
             'tipo', case when k.kind = 'taratura_esterna' then 'taratura esterna' else 'verifica interna' end,
             'metodo', replace(coalesce(k.method, ''), '_', ' '), 'scarto', fabula._it_num(k.max_deviation),
             'tolleranza', case when k.tolerance is null then '' else '± ' || fabula._it_num(k.tolerance) || coalesce(' ' || e.tolerance_unit, '') end,
             'esito', case when k.result = 'ok' then 'conforme' else 'FUORI TOLLERANZA' end,
             'certificato', concat_ws(' · ', k.provider, k.certificate_no), 'operatore', coalesce(s.full_name, ''),
             '_ko', k.result <> 'ok')
           order by k.checked_at), '[]'::jsonb) into rws
    from fabula.calibration_checks k join fabula.equipment e on e.id = k.equipment_id left join fabula.staff s on s.id = k.staff_id
    where (k.checked_at at time zone 'Europe/Rome')::date between d0 and d1;

  elsif f.register_kind = 'training' then
    cols := '[["persona","Persona"],["corso","Corso"],["ente","Ente"],["ore","Ore"],["data","Data attestato"],["scadenza","Scadenza"],["attestato","Attestato in archivio"]]';
    select coalesce(jsonb_agg(jsonb_build_object(
             'persona', coalesce(s.full_name, r.person_name, ''), 'corso', coalesce(c.name_it, r.course_code), 'ente', coalesce(r.provider, ''),
             'ore', fabula._it_num(r.hours), 'data', fabula._it_d(r.completed_on), 'scadenza', fabula._it_d(r.expires_on),
             'attestato', case when r.certificate_document_id is not null then 'sì' else 'NO' end,
             '_ko', r.expires_on < d1 or r.certificate_document_id is null)
           order by coalesce(s.full_name, r.person_name), c.sort), '[]'::jsonb) into rws
    from fabula.training_records r left join fabula.staff s on s.id = r.staff_id left join fabula.training_courses c on c.code = r.course_code
    where r.completed_on <= d1 and (r.expires_on is null or r.expires_on >= d0);

  elsif f.register_kind = 'lab' then
    cols := '[["campione","Campione"],["prelievo","Prelevato il"],["analisi","Analisi"],["lotto","Lotto"],["punto","Punto di prelievo"],["esito","Esito"],["risultato","Risultato"],["referto","Referto"],["operatore","Prelevato da"]]';
    select coalesce(jsonb_agg(jsonb_build_object(
             'campione', sm.sample_code, 'prelievo', fabula._it_d(sm.taken_on), 'analisi', t.code || ' · ' || t.analyte_it,
             'lotto', coalesce(sm.lot_number, ''), 'punto', coalesce(sm.sampling_point, t.sampling_point_it, ''),
             'esito', replace(coalesce(sm.outcome, ''), '_', ' '), 'risultato', coalesce(sm.result_it, fabula._it_num(sm.result_value)),
             'referto', concat_ws(' del ', sm.report_no, nullif(fabula._it_d(sm.report_date), '')), 'operatore', coalesce(s.full_name, ''),
             '_ko', sm.outcome = 'non_conforme', '_warn', sm.outcome = 'attenzione')
           order by sm.taken_on, sm.sample_code), '[]'::jsonb) into rws
    from fabula.lab_samples sm join fabula.lab_tests t on t.id = sm.test_id left join fabula.staff s on s.id = sm.taken_by_id
    where sm.taken_on between d0 and d1;

  elsif f.register_kind = 'nc' then
    cols := '[["aperta","Aperta il"],["gravita","Gravità"],["descrizione","Descrizione"],["lotto","Lotto"],["azione","Azione correttiva"],["causa","Causa"],["preventiva","Azione preventiva"],["stato","Stato"],["chiusa","Chiusa il / da"]]';
    select coalesce(jsonb_agg(jsonb_build_object(
             'aperta', fabula._it_dt(n.opened_at),
             'gravita', case n.severity when 'critical' then 'CRITICA' when 'major' then 'maggiore' else 'minore' end,
             'descrizione', n.description, 'lotto', coalesce(n.lot_number, ''), 'azione', coalesce(n.corrective_action, ''),
             'causa', coalesce(n.root_cause, ''), 'preventiva', coalesce(n.preventive_action, ''),
             'stato', case n.status when 'open' then 'APERTA' when 'investigating' then 'in corso' when 'corrected' then 'corretta' else 'chiusa' end,
             'chiusa', concat_ws(' · ', nullif(fabula._it_dt(n.closed_at), ''), cl.full_name),
             '_ko', n.severity = 'critical' and n.status <> 'closed', '_warn', n.status <> 'closed')
           order by n.opened_at), '[]'::jsonb) into rws
    from fabula.non_conformities n left join fabula.staff cl on cl.id = n.closed_by_id
    where (n.opened_at at time zone 'Europe/Rome')::date between d0 and d1
       or (n.closed_at at time zone 'Europe/Rome')::date between d0 and d1
       or (n.status <> 'closed' and (n.opened_at at time zone 'Europe/Rome')::date < d0);

  elsif f.register_kind = 'hold' then
    cols := '[["lotto","Lotto"],["data_lotto","Prodotto il"],["bloccato","Bloccato il"],["motivo","Motivo"],["stato","Stato"],["sbloccato","Sbloccato il / da"],["motivazione","Motivazione dello sblocco"]]';
    select coalesce(jsonb_agg(jsonb_build_object(
             'lotto', b.batch_lot, 'data_lotto', fabula._it_d(b.batch_date), 'bloccato', fabula._it_dt(b.hold_at), 'motivo', coalesce(b.hold_reason, ''),
             'stato', case when b.food_safety_hold then 'BLOCCATO' else 'sbloccato' end,
             'sbloccato', concat_ws(' · ', nullif(fabula._it_dt(b.hold_released_at), ''), s.full_name),
             'motivazione', coalesce((regexp_match(coalesce(b.notes, ''), '.*sblocco: ([^\n]*)'))[1], ''),
             '_ko', b.food_safety_hold)
           order by b.hold_at), '[]'::jsonb) into rws
    from fabula.production_batches b left join fabula.staff s on s.id = b.hold_released_by_id
    where b.hold_at is not null and coalesce(b.source, '') <> 'simulation'
      and ((b.hold_at at time zone 'Europe/Rome')::date between d0 and d1 or (b.hold_released_at at time zone 'Europe/Rome')::date between d0 and d1 or b.food_safety_hold);

  elsif f.register_kind = 'recall' then
    cols := '[["quando","Data"],["tipo","Tipo"],["lotti","Lotti"],["motivo","Motivo / esito"],["destinazioni","Destinazioni"],["asl","ASL avvisata"],["consorzio","Consorzio avvisato"],["chiuso","Chiuso / tempo"]]';
    select coalesce(jsonb_agg(x.j order by x.ts), '[]'::jsonb) into rws from (
      select r.opened_at as ts, jsonb_build_object('quando', fabula._it_dt(r.opened_at), 'tipo', 'RITIRO / RICHIAMO', 'lotti', array_to_string(r.lot_numbers, ', '),
               'motivo', r.reason, 'destinazioni', '', 'asl', fabula._it_dt(r.asl_notified_at), 'consorzio', fabula._it_dt(r.consorzio_notified_at),
               'chiuso', fabula._it_dt(r.closed_at), '_ko', r.closed_at is null) j
      from fabula.recalls r where (r.opened_at at time zone 'Europe/Rome')::date between d0 and d1 or r.closed_at is null
      union all
      select d.run_at, jsonb_build_object('quando', fabula._it_dt(d.run_at), 'tipo', 'simulazione', 'lotti', coalesce(d.lot_number, ''),
               'motivo', coalesce(d.result, '') || case when coalesce(d.unaccounted_kg, 0) <> 0 then ' · non tracciati ' || fabula._it_num(d.unaccounted_kg) || ' kg' else '' end,
               'destinazioni', coalesce(d.destinations::text, ''), 'asl', '—', 'consorzio', '—',
               'chiuso', case when d.elapsed_ms is null then '' else fabula._it_num(round(d.elapsed_ms / 1000.0, 1)) || ' s' end,
               '_warn', coalesce(d.unaccounted_kg, 0) <> 0) j
      from fabula.recall_drills d where (d.run_at at time zone 'Europe/Rome')::date between d0 and d1) x;

  elsif f.register_kind = 'receipt' then
    cols := '[["quando","Data e ora"],["fornitore","Fornitore"],["ordine","Ordine"],["ddt","DDT"],["merce","Merce, lotto, scadenza"],["controllo","Controllo all''arrivo"],["nota","Nota"],["operatore","Ricevuto da"]]';
    select coalesce(jsonb_agg(jsonb_build_object(
             'quando', fabula._it_dt(g.received_at), 'fornitore', coalesce(p.legal_name, ''), 'ordine', coalesce(po.po_number, ''), 'ddt', coalesce(g.ddt_number, ''),
             'merce', coalesce((select string_agg(pr.name || ' ' || fabula._it_num(gl.qty_received) || coalesce(' · lotto ' || gl.supplier_lot, '') || coalesce(' · scad. ' || fabula._it_d(gl.expiry_date), ''), ' | ')
                                from fabula.goods_receipt_lines gl join fabula.products pr on pr.id = gl.product_id where gl.receipt_id = g.id), ''),
             'controllo', case g.inspection_ok when true then 'conforme' when false then 'NON CONFORME' else 'non registrato' end,
             'nota', coalesce(g.inspection_note, g.notes, ''), 'operatore', coalesce(s.full_name, ''),
             '_ko', g.inspection_ok is false, '_warn', g.inspection_ok is null)
           order by g.received_at), '[]'::jsonb) into rws
    from fabula.goods_receipts g left join fabula.purchase_orders po on po.id = g.purchase_order_id
    left join fabula.parties p on p.id = po.supplier_id left join fabula.staff s on s.id = coalesce(g.inspected_by_id, g.received_by_id)
    where (g.received_at at time zone 'Europe/Rome')::date between d0 and d1;

  elsif f.register_kind = 'effluent' then
    cols := '[["quando","Data e ora"],["tipo","Tipo"],["quantita","Quantità"],["destinazione","Destinazione"],["destinatario","Destinatario"],["documento","Documento"],["operatore","Registrato da"]]';
    select coalesce(jsonb_agg(jsonb_build_object(
             'quando', fabula._it_dt(e.logged_at), 'tipo', replace(coalesce(e.kind, ''), '_', ' '), 'quantita', fabula._it_num(e.qty) || ' ' || coalesce(e.unit, ''),
             'destinazione', coalesce(e.destination, ''), 'destinatario', coalesce(e.recipient, ''), 'documento', coalesce(e.document_ref, ''),
             'operatore', coalesce(s.full_name, e.source, ''), '_warn', e.document_ref is null and e.recipient is not null)
           order by e.logged_at), '[]'::jsonb) into rws
    from fabula.effluent_log e left join fabula.staff s on s.id = e.staff_id
    where e.log_date between d0 and d1;

  elsif f.register_kind = 'maintenance' then
    cols := '[["scadenza","Scadenza"],["attivita","Attività"],["responsabile","Responsabile"],["fatto","Fatto il"],["nota","Nota"],["stato","Stato"]]';
    select coalesce(jsonb_agg(x.j order by x.due nulls last), '[]'::jsonb) into rws from (
      select c.due_on as due, jsonb_build_object('scadenza', fabula._it_d(c.due_on), 'attivita', c.subject_it, 'responsabile', coalesce(c.responsible, ''),
               'fatto', fabula._it_d(c.done_on), 'nota', coalesce(c.done_note, c.notes, ''),
               'stato', case when c.done_on is not null then 'fatto' when c.due_on is null then 'data da impostare' when c.due_on < (now() at time zone 'Europe/Rome')::date then 'SCADUTO' else 'in programma' end,
               '_ko', c.done_on is null and c.due_on < (now() at time zone 'Europe/Rome')::date) j
      from fabula.compliance_deadlines c
      where c.kind <> 'consorzio_fee' and (c.due_on between d0 and d1 or c.done_on between d0 and d1 or (c.done_on is null and (c.due_on is null or c.due_on < d1)))
      union all
      select e.last_maintenance_on + e.maintenance_interval_days, jsonb_build_object('scadenza', fabula._it_d(e.last_maintenance_on + e.maintenance_interval_days),
               'attivita', 'Manutenzione ' || e.code || ' · ' || e.name, 'responsabile', coalesce(e.technician_contact, ''),
               'fatto', fabula._it_d(e.last_maintenance_on), 'nota', '', 'stato', case when e.last_maintenance_on is null then 'mai registrata' else 'registrata' end,
               '_warn', e.last_maintenance_on is null) j
      from fabula.equipment e where e.active and e.maintenance_interval_days is not null) x;

  elsif f.register_kind = 'trace' then
    cols := '[["lotto","Lotto"],["data","Prodotto il"],["prodotto","Prodotto"],["kg","kg prodotti"],["latte","Latte di origine (lotti)"],["padre","Lotto padre"],["venduto","kg usciti"],["clienti","Clienti / canali"]]';
    select coalesce(jsonb_agg(jsonb_build_object(
             'lotto', b.batch_lot, 'data', fabula._it_d(b.batch_date), 'prodotto', coalesce(pr.name, ''), 'kg', fabula._it_num(b.output_kg),
             'latte', coalesce((select string_agg(distinct mi.milk_lot, ', ') from fabula.batch_milk_inputs bm join fabula.milk_intake mi on mi.id = bm.milk_intake_id where bm.batch_id = b.id), ''),
             'padre', coalesce((select pb.batch_lot from fabula.production_batches pb where pb.id = b.parent_batch_id), ''),
             'venduto', fabula._it_num((select abs(sum(m.qty)) from fabula.stock_moves m where m.lot_number = b.batch_lot and m.move_type = 'sale')),
             'clienti', coalesce((select count(distinct coalesce(so.customer_id::text, so.channel::text))::text from fabula.stock_moves m join fabula.sales_orders so on so.id = m.sales_order_id
                                  where m.lot_number = b.batch_lot and m.move_type = 'sale'), '0'),
             '_warn', b.output_kg is null)
           order by b.batch_date, b.batch_lot), '[]'::jsonb) into rws
    from fabula.production_batches b left join fabula.products pr on pr.id = b.product_id
    where b.batch_date between d0 and d1 and coalesce(b.source, '') <> 'simulation';

  elsif f.register_kind = 'review' then
    cols := '[["quando","Verificato il"],["modulo","Registro"],["periodo","Periodo"],["esito","Esito"],["nota","Rilievi"],["chi","Verificato da"],["rev","Rev. manuale"]]';
    select coalesce(jsonb_agg(jsonb_build_object(
             'quando', fabula._it_dt(r.reviewed_at), 'modulo', r.form_code || ' · ' || hf.title_it, 'periodo', fabula._it_d(r.period_from) || ' – ' || fabula._it_d(r.period_to),
             'esito', case when r.outcome = 'ok' then 'ok' else 'CON RILIEVI' end, 'nota', coalesce(r.note, ''), 'chi', coalesce(s.full_name, ''), 'rev', coalesce(r.manual_rev, ''),
             '_warn', r.outcome <> 'ok')
           order by r.reviewed_at), '[]'::jsonb) into rws
    from fabula.haccp_register_reviews r join fabula.haccp_forms hf on hf.code = r.form_code left join fabula.staff s on s.id = r.reviewed_by_id
    where (r.reviewed_at at time zone 'Europe/Rome')::date between d0 and d1;

  elsif f.register_kind = 'suppliers' then
    cols := '[["fornitore","Fornitore"],["piva","P.IVA"],["forniture","Cosa fornisce"],["dop","Latte DOP"],["schede","Schede / certificati in archivio"],["contatto","Contatto"]]';
    select coalesce(jsonb_agg(jsonb_build_object(
             'fornitore', p.legal_name, 'piva', coalesce(p.piva, ''),
             'forniture', case when p.is_milk_supplier then 'latte di bufala' else '' end
                          || coalesce(case when p.is_milk_supplier then ', ' else '' end || (select string_agg(distinct pr.name, ', ') from fabula.supplier_products sp join fabula.products pr on pr.id = sp.product_id where sp.supplier_id = p.id), ''),
             'dop', case when p.is_milk_supplier then case when p.is_dop_certified then 'sì' else 'NO' end else '' end,
             'schede', (select count(*) from fabula.documents d where d.party_id = p.id and d.kind in ('supplier_cert', 'contract'))::text,
             'contatto', concat_ws(' · ', p.phone, p.email),
             '_warn', not exists (select 1 from fabula.documents d where d.party_id = p.id and d.kind in ('supplier_cert', 'contract')))
           order by p.legal_name), '[]'::jsonb) into rws
    from fabula.parties p
    where p.active and (p.type in ('supplier', 'both') or p.is_milk_supplier);

  else  -- modulo cartaceo: solo intestazione e colonne
    cols := case f.code
      when 'MOD-22' then '[["quando","Data e ora"],["nome","Nome e cognome"],["ditta","Ditta / motivo della visita"],["salute","Dichiaro di non avere sintomi di malattie trasmissibili con gli alimenti (firma)"],["dpi","Camice e copricapo"],["accompagnato","Accompagnato da"]]'
      when 'MOD-23' then '[["data","Data"],["prodotto","Prodotto"],["versione","Versione etichetta"],["contenuti","Controllati: DOP, ingredienti, allergeni, peso, lotto, scadenza, conservazione, OSA, bollo CE"],["shelf","Shelf-life e studio di riferimento"],["esito","Esito"],["firma","Firma"]]'
      else '[["data","Data"],["descrizione","Descrizione"],["esito","Esito"],["firma","Firma"]]' end::jsonb;
  end if;

  hdr := jsonb_build_object(
    'company', fabula.company_name(false), 'legal_name', fabula._setting('company.legal_name'), 'address', fabula._setting('company.address'),
    'piva', fabula._setting('company.piva'), 'ce_no', fabula._setting('food.ce_approval_no'), 'responsabile', fabula._setting('food.responsabile_autocontrollo'),
    'manual_rev', fabula._setting('food.manuale_rev'), 'manual_date', fabula._setting('food.manuale_data'), 'manual_status', coalesce(fabula._setting('food.manuale_stato'), 'bozza'),
    'manual_url', fabula._setting('food.manuale_url'), 'retention_years', fabula._setting('food.records_retention_years'));
  select coalesce(jsonb_agg(jsonb_build_object('at', r.reviewed_at, 'from', r.period_from, 'to', r.period_to, 'outcome', r.outcome, 'note', r.note, 'by', s.full_name, 'rev', r.manual_rev) order by r.reviewed_at), '[]'::jsonb)
    into revs
  from fabula.haccp_register_reviews r left join fabula.staff s on s.id = r.reviewed_by_id
  where r.form_code = f.code and r.period_to >= d0 and r.period_from <= d1;

  return jsonb_build_object('form', to_jsonb(f), 'ref', fabula.manual_ref(f.code), 'header', hdr, 'from', d0, 'to', d1,
                            'columns', cols, 'rows', rws, 'reviews', revs, 'printed_at', now());
end $$;
revoke execute on function fabula.haccp_register(text, date, date) from public, anon;
grant execute on function fabula.haccp_register(text, date, date) to authenticated, service_role;
revoke execute on function fabula.manual_ref(text), fabula._setting(text) from public, anon;
grant execute on function fabula.manual_ref(text), fabula._setting(text) to authenticated, service_role;

-- 8 · stato dei registri per la console ----------------------------------------------------------------------------
create or replace function fabula.haccp_forms_status()
returns jsonb language plpgsql stable security definer set search_path = fabula, public as $$
declare d30 date := (now() at time zone 'Europe/Rome')::date - 30; v_out jsonb;
begin
  perform fabula.require_perm('haccp', 1);
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', f.code, 'title_it', f.title_it, 'manual_section', f.manual_section, 'frequency_it', f.frequency_it, 'responsible_it', f.responsible_it,
           'where_it', f.where_it, 'status', f.status, 'register_kind', f.register_kind,
           'records_30d', st.n, 'last_at', st.last_at,
           'last_review_at', rv.reviewed_at, 'last_review_to', rv.period_to, 'last_review_by', rv.full_name, 'last_review_outcome', rv.outcome)
         order by f.sort), '[]'::jsonb) into v_out
  from fabula.haccp_forms f
  cross join lateral (
    select case f.register_kind
      when 'milk' then (select count(*) from fabula.milk_intake where intake_date >= d30 and coalesce(source, '') <> 'simulation')
      when 'ccp' then (select count(*) from fabula.haccp_log l join fabula.haccp_control_points c on c.id = l.control_point_id where c.form_code = f.code and l.logged_at >= d30 and coalesce(l.source, '') <> 'simulation')
      when 'batch' then (select count(*) from fabula.production_batches where batch_date >= d30 and coalesce(input_kind, '') <> 'whey' and coalesce(source, '') <> 'simulation')
      when 'pest' then (select count(*) from fabula.pest_inspections where inspected_on >= d30)
      when 'calibration' then (select count(*) from fabula.calibration_checks where checked_at >= d30)
      when 'training' then (select count(*) from fabula.training_records where created_at >= d30)
      when 'lab' then (select count(*) from fabula.lab_samples where taken_on >= d30)
      when 'nc' then (select count(*) from fabula.non_conformities where opened_at >= d30)
      when 'hold' then (select count(*) from fabula.production_batches where hold_at >= d30)
      when 'recall' then (select count(*) from fabula.recall_drills where run_at >= d30) + (select count(*) from fabula.recalls where opened_at >= d30)
      when 'receipt' then (select count(*) from fabula.goods_receipts where received_at >= d30)
      when 'effluent' then (select count(*) from fabula.effluent_log where log_date >= d30)
      when 'maintenance' then (select count(*) from fabula.compliance_deadlines where done_on >= d30)
      when 'trace' then (select count(*) from fabula.production_batches where batch_date >= d30 and coalesce(source, '') <> 'simulation')
      when 'review' then (select count(*) from fabula.haccp_register_reviews where reviewed_at >= d30)
      when 'suppliers' then (select count(*) from fabula.parties where active and (type in ('supplier', 'both') or is_milk_supplier))
      else null end n,
    case f.register_kind
      when 'milk' then (select max(created_at) from fabula.milk_intake where coalesce(source, '') <> 'simulation')
      when 'ccp' then (select max(l.logged_at) from fabula.haccp_log l join fabula.haccp_control_points c on c.id = l.control_point_id where c.form_code = f.code and coalesce(l.source, '') <> 'simulation')
      when 'batch' then (select max(created_at) from fabula.production_batches where coalesce(input_kind, '') <> 'whey' and coalesce(source, '') <> 'simulation')
      when 'pest' then (select max(created_at) from fabula.pest_inspections)
      when 'calibration' then (select max(checked_at) from fabula.calibration_checks)
      when 'training' then (select max(created_at) from fabula.training_records)
      when 'lab' then (select max(created_at) from fabula.lab_samples)
      when 'nc' then (select max(opened_at) from fabula.non_conformities)
      when 'hold' then (select max(hold_at) from fabula.production_batches)
      when 'recall' then greatest((select max(run_at) from fabula.recall_drills), (select max(opened_at) from fabula.recalls))
      when 'receipt' then (select max(received_at) from fabula.goods_receipts)
      when 'effluent' then (select max(logged_at) from fabula.effluent_log)
      when 'trace' then (select max(created_at) from fabula.production_batches where coalesce(source, '') <> 'simulation')
      when 'review' then (select max(reviewed_at) from fabula.haccp_register_reviews)
      else null end last_at) st
  left join lateral (select r.reviewed_at, r.period_to, r.outcome, s.full_name from fabula.haccp_register_reviews r left join fabula.staff s on s.id = r.reviewed_by_id
                     where r.form_code = f.code order by r.reviewed_at desc limit 1) rv on true;
  return v_out;
end $$;
revoke execute on function fabula.haccp_forms_status() from public, anon;
grant execute on function fabula.haccp_forms_status() to authenticated, service_role;
