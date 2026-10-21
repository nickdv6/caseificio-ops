-- v1.13 (21/10/2026) · the number check without false alarms (re-audit 19/10, R-03)
--   «Perché?» compares each number and date a bot writes with the data it read (v1.06). In 7 days it flagged 2 messages, both wrongly:
--   * Controllo sistema 19/10: «nomi provvisori: invariati dal 16/10» (the note outside brackets: only «(invariato …)» was left out)
--     and «(erano 3 il 17/10)», a comparison with its previous message (rule 5, REPEATS);
--   * Manutenzioni e scadenze 20/10: «4 tarature, 11 manutenzioni, 6 attestati», right, but counted by the bot: the data had only the
--     total 28 and the lists.
--   Now:
--   * _basis_tokens leaves out «invariat[oaie] dal/da/al dd/mm» anywhere, «(era|erano …)» in brackets and «era/erano N il dd/mm»;
--   * compliance_calendar() returns counts.by_kind (overdue, due_30, due_60, unknown → calibration, maintenance, verifica, training, …);
--   * the messages of the last 7 days that were flagged are checked again with the new rule.

create or replace function fabula._basis_tokens(p_text text, p_message boolean default true)
returns table (tok text, kind text, vals numeric[], decs integer[], pct boolean, signed boolean)
language plpgsql immutable set search_path = fabula, public as $$
declare t text := coalesce(p_text, ''); m text[]; s text; v numeric[]; d int[]; g numeric;
begin
  if p_message then
    t := regexp_replace(t, '^[ \t]*EN[ \t]*[—–-].*$', '', 'gn');
    t := regexp_replace(t, '^[ \t]*>.*$', '', 'gn');
    t := regexp_replace(t, '\(invariat[oaie][^)]*\)', ' ', 'gi');
    -- v1.13 (R-03): the same note outside brackets («nomi provvisori: invariati dal 16/10») and a comparison with the previous message
    -- («(erano 3 il 17/10)», «era 1 il 16/10»): rule 5 (REPEATS) of the bots' messages; those numbers belong to a message already checked
    t := regexp_replace(t, '\minvariat[oaie][ \t]+(dal|dall''|da|al)[ \t]*[0-9]{1,2}/[0-9]{1,2}(/[0-9]{2,4})?', ' ', 'gi');
    t := regexp_replace(t, '\((era|erano)\M[^)]*\)', ' ', 'gi');
    t := regexp_replace(t, '\m(era|erano)[ \t]+[^ \t,.;:()]+[ \t]+(il|al|dal)[ \t]+[0-9]{1,2}/[0-9]{1,2}(/[0-9]{2,4})?', ' ', 'gi');
    t := regexp_replace(t, '^([ \t]*)[0-9]{1,2}[.)]([ \t])', '\1\2', 'gn');
    t := regexp_replace(t, '(\+39[ \t]?)?(3[0-9]{2}|0[0-9]{1,3})[ \t]?[0-9]{3}[ \t]?[0-9]{3,4}', ' ', 'g');   -- Italian phone numbers
  end if;
  t := regexp_replace(t, '\mCCP[ \t]*[0-9]+[ \t]*[a-z]?\M', ' ', 'gi');                     -- «CCP 3», «CCP 1b»
  t := regexp_replace(t, '\m(cella frigo|cella|frigo)[ \t]+[0-9]{1,2}(?![0-9]|[.,][0-9])', ' ', 'gi');   -- the glossary's «cella frigo 1»
  -- codes and lots (CF-01, L20261015-A, PO-20261015-01, perla-v72, 48h): a word with both letters and digits is not a number
  t := regexp_replace(t, '[[:alnum:]_.-]*([[:alpha:]][[:alnum:]_-]*[[:digit:]]|[[:digit:]][[:alnum:]_-]*[[:alpha:]])[[:alnum:]_.-]*', ' ', 'g');
  t := regexp_replace(t, '\m[0-9]{1,2}:[0-9]{2}\M', ' ', 'g');                             -- times («ore 06:00»)
  t := regexp_replace(t, '\m(ore|alle|dalle|entro le)[ \t]+[0-9]{1,2}\M', ' ', 'gi');      -- «alle 6»
  -- lengths of time («4 settimane», «30 giorni», «60 ore»): the bot's own instructions, not data
  t := regexp_replace(t, '\m[0-9]+[ \t]+(settimane|settimana|giorni|giorno|mesi|mese|ore|ora|minuti|minuto|anni|anno)\M', ' ', 'gi');
  for m in select regexp_matches(t, '\m([0-9]{1,2})/([0-9]{1,2})(/[0-9]{2,4})?\M', 'g') loop
    if m[1]::int between 1 and 31 and m[2]::int between 1 and 12 then
      tok := m[1]::int || '/' || m[2]::int; kind := 'date'; vals := null; decs := null; pct := false; signed := false; return next;
    end if;
  end loop;
  t := regexp_replace(t, '\m[0-9]{1,2}/[0-9]{1,2}(/[0-9]{2,4})?\M', ' ', 'g');
  t := regexp_replace(t, '(^|[^0-9.,])20[2-3][0-9](?![0-9]|[.,][0-9])', '\1 ', 'g');               -- years (not «2040,00»)
  for m in select regexp_matches(t, '(^|[^[:alnum:]])([+−-]?)([0-9][0-9.,]*[0-9]|[0-9])([ \t]*%)?', 'g') loop
    s := m[3]; v := '{}'; d := '{}'; g := case when m[2] in ('−', '-') then -1 else 1 end;
    if s ~ '^[0-9]{1,3}(\.[0-9]{3})+(,[0-9]+)?$' then                                    -- Italian thousands «1.200», «1.440,50»
      v := v || g * replace(replace(s, '.', ''), ',', '.')::numeric; d := d || coalesce(length(substring(s from ',([0-9]+)$')), 0);
    end if;
    if s ~ '^[0-9]+,[0-9]+$' then                                                         -- Italian decimal «20,5»
      v := v || g * replace(s, ',', '.')::numeric; d := d || length(substring(s from ',([0-9]+)$'));
    end if;
    if s ~ '^[0-9]{1,3}(,[0-9]{3})+(\.[0-9]+)?$' then                                    -- English thousands «1,200»
      v := v || g * replace(s, ',', '')::numeric; d := d || coalesce(length(substring(s from '\.([0-9]+)$')), 0);
    end if;
    if s ~ '^[0-9]+\.[0-9]+$' then                                                        -- the database's own «1530.40», or «1.2»
      v := v || g * s::numeric; d := d || length(substring(s from '\.([0-9]+)$'));
    end if;
    if s ~ '^[0-9]+$' then v := v || g * s::numeric; d := d || 0; end if;
    continue when cardinality(v) = 0;                                                    -- «1.2.3»: not a number
    tok := m[2] || s || case when m[4] is not null then ' %' else '' end; kind := 'num'; vals := v; decs := d;
    pct := m[4] is not null; signed := m[2] <> '';
    return next;
  end loop;
end $$;
revoke all on function fabula._basis_tokens(text, boolean) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION fabula.compliance_calendar(p_date date DEFAULT ((now() AT TIME ZONE 'Europe/Rome'::text))::date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'fabula', 'public', 'extensions'
AS $function$
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
           'message_it', format('Buongiorno, per ' || fabula.company_name(true) || ' (Agropoli) dovremmo programmare %s di %s (%s)%s. Quando potete passare? Grazie.',
                                case kind when 'calibration' then 'la taratura' else 'la manutenzione periodica' end, subject, ref,
                                case when bucket = 'overdue' then format(' — scaduta il %s', to_char(due_on,'DD/MM/YYYY')) else format(' entro il %s', to_char(due_on,'DD/MM/YYYY')) end))
           order by due_on), '[]') d
  from tagged where kind in ('calibration','maintenance') and bucket in ('overdue','due_30')),
lab_due as (
  select l.* from fabula.v_lab_plan_status l where l.plan_active and l.next_due <= p_date + 14),
lab_draft as (
  select case when count(*) = 0 then null else jsonb_build_object(
           'to', nullif(fabula.setting_text('food.lab_email', ''), ''), 'lab', nullif(fabula.setting_text('food.lab_name', ''), ''),
           'subject_it', 'Richiesta campionamenti — ' || fabula.company_name() || ', Agropoli',
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
                               'due_60', (select count(*) from tagged where bucket='due_60'), 'unknown', (select count(*) from tagged where bucket='unknown'),
                               -- v1.13 (R-03): the counts by kind the message gives («4 tarature, 11 manutenzioni…»), so the bot never counts and the
                               -- number check finds them in the data
                               'by_kind', (select coalesce(jsonb_object_agg(bucket, k), '{}'::jsonb)
                                             from (select bucket, jsonb_object_agg(kind, n) k from (select bucket, kind, count(*) n from tagged group by 1, 2) x1 group by bucket) x2)));
$function$;

-- the flagged messages of the last 7 days, checked again (a message whose data lacks a number stays flagged)
do $$
declare m record; v jsonb;
begin
  for m in select id, title, body from fabula.bot_messages
            where created_at > now() - interval '7 days' and jsonb_array_length(coalesce(basis_check->'missing', '[]'::jsonb)) > 0 loop
    v := fabula._basis_check(coalesce(m.title, '') || E'\n' || coalesce(m.body, ''), m.id);
    if v is not null then update fabula.bot_messages set basis_check = v where id = m.id; end if;
  end loop;
end $$;
