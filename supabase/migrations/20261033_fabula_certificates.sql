-- v0.34 · Training & certificate expiry, completed on top of the v0.28 training register.
-- v0.28 already has training_courses / training_records (expiry = completed + validity, attestato PDF upload in haccp.html,
-- v_training_matrix by job role, compliance_calendar + daily brief reminders). This adds:
--  · staff.designations[] (primo_soccorso, antincendio, preposto, rls) — courses that apply because of a designation, not the job role;
--  · training_courses.designation + three new entries: PREPOSTO, RLS and the medical-fitness visit (only the date and expiry are kept — no outcome or health detail);
--  · v_training_matrix now matches by role OR designation (same columns + 'reason');
--  · v_safety_cover: per rota day, who is on shift with a valid first-aid / fire-warden certificate → days with nobody covered;
--  · v_certificates_expiring: one list (90 days) for the console and the compliance bot.

alter table fabula.staff add column if not exists designations text[] not null default '{}';
alter table fabula.training_courses add column if not exists designation text;
update fabula.training_courses set designation = 'primo_soccorso' where code = 'PRIMO-SOCC' and designation is null;
update fabula.training_courses set designation = 'antincendio' where code = 'ANTINC' and designation is null;

insert into fabula.training_courses (code, name_it, category, hours_first, hours_refresh, validity_days, roles, legal_ref, notes, sort, designation)
select * from (values
  ('PREPOSTO', 'Preposto alla sicurezza (capoturno / casaro responsabile)', 'sicurezza_lavoro', 12::numeric, 6::numeric, 730, '{}'::fabula.staff_role[],
   'D.Lgs. 81/2008 art. 37 c. 7 (agg. L. 215/2021)', 'Aggiornamento biennale di 6 h.', 23, 'preposto'),
  ('RLS', 'Rappresentante dei lavoratori per la sicurezza', 'sicurezza_lavoro', 32::numeric, 4::numeric, 365, '{}'::fabula.staff_role[],
   'D.Lgs. 81/2008 art. 37 c. 10-11', 'Aggiornamento annuale (4 h sotto i 50 dipendenti). In alternativa RLST territoriale.', 24, 'rls'),
  ('VISITA-MED', 'Visita di idoneità alla mansione (medico competente)', 'sicurezza_lavoro', null::numeric, null::numeric, 730, '{casaro,operaio,commesso}'::fabula.staff_role[],
   'D.Lgs. 81/2008 art. 41', 'Si registra solo data e scadenza; la periodicità la decide il medico competente (impostare la scadenza dal certificato).', 30, null)) x
where not exists (select 1 from fabula.training_courses c where c.code = x.column1);

create or replace view fabula.v_training_matrix with (security_invoker = true) as
select s.id as staff_id, s.full_name, s.badge_code, s.role, c.code as course_code, c.name_it as course_name, c.category, c.validity_days, c.sort,
       r.completed_on, r.expires_on, r.provider, r.certificate_document_id,
       case when r.expires_on is null and r.completed_on is null then 'mancante'
            when r.expires_on < (now() at time zone 'Europe/Rome')::date then 'scaduto'
            when r.expires_on <= (now() at time zone 'Europe/Rome')::date + 60 then 'in_scadenza'
            else 'valido' end as status,
       case when s.role = any (c.roles) then 'mansione' else 'nomina: ' || replace(c.designation, '_', ' ') end as reason
from fabula.staff s
join fabula.training_courses c on s.role = any (c.roles) or (c.designation is not null and c.designation = any (s.designations))
left join lateral (select r1.* from fabula.training_records r1 where r1.staff_id = s.id and r1.course_code = c.code order by r1.completed_on desc limit 1) r on true
where s.active
order by s.full_name, c.sort;
grant select on fabula.v_training_matrix to authenticated, service_role;

create or replace view fabula.v_certificates_expiring with (security_invoker = true) as
select staff_id, full_name, course_code, course_name, category, reason, expires_on, status,
       expires_on - (now() at time zone 'Europe/Rome')::date as days_left
from fabula.v_training_matrix
where status in ('mancante','scaduto') or expires_on <= (now() at time zone 'Europe/Rome')::date + 90
order by case status when 'scaduto' then 0 when 'mancante' then 1 else 2 end, expires_on nulls first, full_name;
grant select on fabula.v_certificates_expiring to authenticated, service_role;

create or replace view fabula.v_safety_cover with (security_invoker = true) as
with valid as (
  select r.staff_id, c.designation, max(r.expires_on) expires_on
  from fabula.training_records r join fabula.training_courses c on c.code = r.course_code
  where c.designation in ('primo_soccorso','antincendio') group by 1, 2)
select e.work_date,
       count(distinct e.staff_id) as on_shift,
       count(distinct e.staff_id) filter (where fa.staff_id is not null) as first_aid,
       count(distinct e.staff_id) filter (where fw.staff_id is not null) as fire_warden,
       string_agg(distinct s.full_name, ', ') filter (where fa.staff_id is not null) as first_aid_names,
       string_agg(distinct s.full_name, ', ') filter (where fw.staff_id is not null) as fire_warden_names
from fabula.rota_entries e join fabula.staff s on s.id = e.staff_id and s.active
left join valid fa on fa.staff_id = e.staff_id and fa.designation = 'primo_soccorso' and fa.expires_on >= e.work_date
left join valid fw on fw.staff_id = e.staff_id and fw.designation = 'antincendio' and fw.expires_on >= e.work_date
where e.kind = 'lavoro'
group by e.work_date;
grant select on fabula.v_safety_cover to authenticated, service_role;
