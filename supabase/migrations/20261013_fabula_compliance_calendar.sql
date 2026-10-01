-- =============================================================================
-- v0.13: maintenance, calibration & compliance calendar.
--   fabula.compliance_deadlines: the non-equipment obligations (HACCP plan review,
--     water analysis, pest-control contract, extinguishers, Consorzio fee, …).
--     Equipment calibration/maintenance and staff HACCP training stay where they
--     are (equipment.*, staff.haccp_training_expires); the function reads all three.
--   select fabula.compliance_calendar();   → overdue / due_30 / due_60 / unknown_dates
--     / training, plus a ready-to-forward Italian message per technician item.
--   fabula.mark_calibrated(code, on, note) · mark_maintained(code, on, note)
--   fabula.complete_deadline(id, on, note) → closes it and opens the next one if it repeats.
-- Written without destructive keywords (connector rule).
-- =============================================================================
set search_path = fabula, public;

create table if not exists fabula.compliance_deadlines (
  id              uuid primary key default gen_random_uuid(),
  kind            text not null,                 -- haccp_plan_review | water_analysis | pest_control | extinguishers | consorzio_fee | electrical_check | other
  subject_it      text not null,
  due_on          date,                          -- null = date still to be set
  interval_days   int,                           -- null = one-off
  responsible     text,                          -- 'partner', 'casaro', 'Nick', provider name
  contact         text,                          -- technician / provider, phone or email
  notes           text,
  done_on         date,
  done_note       text,
  created_at      timestamptz not null default now()
);
create index if not exists compliance_deadlines_open_idx on fabula.compliance_deadlines (due_on) where done_on is null;
grant all on fabula.compliance_deadlines to authenticated, service_role;
alter table fabula.compliance_deadlines enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='fabula' and tablename='compliance_deadlines' and policyname='compliance_deadlines_authenticated_all') then
    create policy compliance_deadlines_authenticated_all on fabula.compliance_deadlines for all to authenticated using (true) with check (true);
  end if;
end $$;

alter table fabula.equipment add column if not exists technician_contact text;   -- who to call for this machine

-- Sensible intervals for a micro-dairy (edit freely); dates stay null until the partners confirm
update fabula.equipment set maintenance_interval_days = 180 where code in ('CF-01','CF-02','FIL-01') and maintenance_interval_days is null;
update fabula.equipment set maintenance_interval_days = 365 where code = 'PAST-01' and maintenance_interval_days is null;
update fabula.equipment set calibration_interval_days = 365 where code = 'PAST-01' and calibration_interval_days is null;   -- thermometer/recorder check

insert into fabula.compliance_deadlines (kind, subject_it, interval_days, responsible, notes)
select * from (values
  ('haccp_plan_review', 'Riesame annuale piano HACCP',                      365, 'partner', 'con il consulente HACCP; verbale in documents'),
  ('water_analysis',    'Analisi acqua potabile (laboratorio)',             365, 'partner', 'referto in documents (supplier_cert)'),
  ('pest_control',      'Contratto disinfestazione: visita periodica',      90,  'partner', 'rapporto di intervento in documents'),
  ('extinguishers',     'Revisione estintori',                              180, 'partner', 'cartellino aggiornato'),
  ('consorzio_fee',     'Quota annuale Consorzio Tutela Mozzarella di Bufala Campana DOP', 365, 'Nick', 'vedi dop-fees'),
  ('electrical_check',  'Verifica impianto elettrico / messa a terra',      730, 'partner', 'DPR 462/01 — verifica periodica')
) v(kind, subject_it, interval_days, responsible, notes)
where not exists (select 1 from fabula.compliance_deadlines d where d.kind = v.kind and d.done_on is null);

create or replace function fabula.compliance_calendar(p_date date default (now() at time zone 'Europe/Rome')::date)
returns jsonb language sql stable as $$
with items as (
  -- equipment calibration
  select 'calibration' as kind, e.code as ref, e.name as subject, e.next_calibration_on as due_on, e.last_calibrated_on as last_done,
         e.calibration_interval_days as interval_days, e.technician_contact as contact, null::text as responsible, e.id as equipment_id, null::uuid as deadline_id
  from fabula.equipment e where e.active and e.calibration_interval_days is not null
  union all
  -- equipment maintenance
  select 'maintenance', e.code, e.name, case when e.last_maintenance_on is not null then e.last_maintenance_on + e.maintenance_interval_days end,
         e.last_maintenance_on, e.maintenance_interval_days, e.technician_contact, null, e.id, null
  from fabula.equipment e where e.active and e.maintenance_interval_days is not null
  union all
  -- staff HACCP training
  select 'training', s.badge_code, s.full_name || ' · formazione HACCP', s.haccp_training_expires, null, null, null, s.full_name, null, null
  from fabula.staff s where s.active
  union all
  -- general deadlines
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
  from tagged where kind in ('calibration','maintenance') and bucket in ('overdue','due_30'))
select jsonb_build_object(
  'date', p_date,
  'overdue',       coalesce((select items from j where bucket = 'overdue'), '[]'),
  'due_30',        coalesce((select items from j where bucket = 'due_30'), '[]'),
  'due_60',        coalesce((select items from j where bucket = 'due_60'), '[]'),
  'unknown_dates', coalesce((select items from j where bucket = 'unknown'), '[]'),
  'technician_drafts', (select d from drafts),
  'counts', jsonb_build_object('overdue', (select count(*) from tagged where bucket='overdue'), 'due_30', (select count(*) from tagged where bucket='due_30'),
                               'due_60', (select count(*) from tagged where bucket='due_60'), 'unknown', (select count(*) from tagged where bucket='unknown')));
$$;
grant execute on function fabula.compliance_calendar(date) to authenticated, service_role;

create or replace function fabula.mark_calibrated(p_code text, p_on date default (now() at time zone 'Europe/Rome')::date, p_note text default null)
returns date language plpgsql as $$
declare v_next date;
begin
  update fabula.equipment set last_calibrated_on = p_on where code = p_code returning next_calibration_on into v_next;
  if not found then raise exception 'Macchina sconosciuta: %', p_code; end if;
  if p_note is not null then insert into fabula.documents (kind, storage_path, related_table, document_date, ocr_text) values ('supplier_cert', 'note/' || p_code || '/' || p_on, 'equipment', p_on, p_note); end if;
  return v_next;
end $$;
create or replace function fabula.mark_maintained(p_code text, p_on date default (now() at time zone 'Europe/Rome')::date, p_note text default null)
returns date language plpgsql as $$
declare v_next date;
begin
  update fabula.equipment set last_maintenance_on = p_on where code = p_code returning last_maintenance_on + maintenance_interval_days into v_next;
  if not found then raise exception 'Macchina sconosciuta: %', p_code; end if;
  if p_note is not null then insert into fabula.documents (kind, storage_path, related_table, document_date, ocr_text) values ('other', 'note/' || p_code || '/' || p_on, 'equipment', p_on, p_note); end if;
  return v_next;
end $$;
create or replace function fabula.complete_deadline(p_id uuid, p_on date default (now() at time zone 'Europe/Rome')::date, p_note text default null)
returns uuid language plpgsql as $$
declare d record; v_new uuid;
begin
  update fabula.compliance_deadlines set done_on = p_on, done_note = p_note where id = p_id and done_on is null returning * into d;
  if d is null then raise exception 'Scadenza non trovata o già chiusa: %', p_id; end if;
  if d.interval_days is not null then
    insert into fabula.compliance_deadlines (kind, subject_it, due_on, interval_days, responsible, contact, notes)
    values (d.kind, d.subject_it, p_on + d.interval_days, d.interval_days, d.responsible, d.contact, d.notes) returning id into v_new;
  end if;
  return v_new;
end $$;
grant execute on function fabula.mark_calibrated(text, date, text), fabula.mark_maintained(text, date, text), fabula.complete_deadline(uuid, date, text) to authenticated, service_role;
