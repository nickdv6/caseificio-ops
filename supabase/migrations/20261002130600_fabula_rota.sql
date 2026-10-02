-- v0.33 · Weekly rota in the console + overtime from clock data.
-- rota_entries: one row per person per day — kind lavoro (start/end/break, area) or ferie | permesso | malattia | riposo.
-- staff.contract_hours_week (null → labor.contract_hours_week, default 40).
-- v_hours_weekly: per person per ISO week — planned h (rota), worked h (badge shifts), contract h, overtime h
--   (weekly hours above contract; plus daily hours above labor.overtime_daily_hours when that setting is > 0, whichever is larger),
--   Sunday hours, overtime € at hourly cost × (1 + labor.overtime_premium_pct), days planned without clock-in, days clocked without rota.
-- rota_week(week_start) → grid for the console; copy_rota_week(from, to) copies a week as the next one's template (skips existing cells).

alter table fabula.staff add column if not exists contract_hours_week numeric(4,1);

create table if not exists fabula.rota_entries (
  id          uuid primary key default gen_random_uuid(),
  staff_id    uuid not null references fabula.staff(id),
  work_date   date not null,
  kind        text not null default 'lavoro' check (kind in ('lavoro','ferie','permesso','malattia','riposo')),
  start_time  time,
  end_time    time,
  break_min   int not null default 0 check (break_min between 0 and 240),
  area        text,
  notes       text,
  created_by  uuid references fabula.staff(id),
  updated_at  timestamptz not null default now(),
  unique (staff_id, work_date),
  check (kind <> 'lavoro' or (start_time is not null and end_time is not null)));
alter table fabula.rota_entries enable row level security;
do $$ begin if not exists (select 1 from pg_policies where schemaname = 'fabula' and tablename = 'rota_entries' and policyname = 'rota_entries_authenticated_all') then
  create policy rota_entries_authenticated_all on fabula.rota_entries for all to authenticated using (true) with check (true); end if; end $$;
grant all on fabula.rota_entries to authenticated, service_role;

insert into fabula.settings (key, value, description, data_type)
select k, v, d, 'number' from (values
  ('labor.contract_hours_week', '40', 'Ore settimanali da contratto (se la persona non ne ha di proprie)'),
  ('labor.overtime_daily_hours', '0', 'Straordinario anche oltre queste ore al giorno (0 = solo settimanale)'),
  ('labor.overtime_premium_pct', '25', 'Maggiorazione straordinario % (da confermare con il consulente del lavoro)')) x(k, v, d)
where not exists (select 1 from fabula.settings s where s.key = x.k);

create or replace function fabula.rota_hours(p_start time, p_end time, p_break int) returns numeric language sql immutable as $$
  select case when p_start is null or p_end is null then 0
    else round(greatest(0, extract(epoch from (case when p_end <= p_start then p_end::interval + interval '24 hours' else p_end::interval end) - p_start::interval) / 3600 - coalesce(p_break, 0) / 60.0), 2) end
$$;

create or replace view fabula.v_hours_daily with (security_invoker = true) as
with w as (
  select staff_id, (clock_in at time zone 'Europe/Rome')::date work_date, sum(coalesce(hours, 0)) worked_h, count(*) shifts,
         min((clock_in at time zone 'Europe/Rome')::time) first_in, max((clock_out at time zone 'Europe/Rome')::time) last_out
  from fabula.shifts where clock_out is not null group by 1, 2),
r as (
  select staff_id, work_date, kind, start_time, end_time, area, fabula.rota_hours(start_time, end_time, break_min) planned_h
  from fabula.rota_entries)
select coalesce(r.staff_id, w.staff_id) staff_id, coalesce(r.work_date, w.work_date) work_date, r.kind, r.start_time, r.end_time, r.area,
       coalesce(r.planned_h, 0) planned_h, round(coalesce(w.worked_h, 0), 2) worked_h, coalesce(w.shifts, 0) shifts, w.first_in, w.last_out,
       (r.kind = 'lavoro' and w.staff_id is null and coalesce(r.work_date, w.work_date) < (now() at time zone 'Europe/Rome')::date) planned_no_clock,
       (w.staff_id is not null and (r.staff_id is null or r.kind <> 'lavoro')) clock_no_rota,
       greatest(0, round(coalesce(w.worked_h, 0) - nullif(fabula.setting_num('labor.overtime_daily_hours', 0), 0), 2)) daily_over_h
from r full join w on w.staff_id = r.staff_id and w.work_date = r.work_date;
grant select on fabula.v_hours_daily to authenticated, service_role;

create or replace view fabula.v_hours_weekly with (security_invoker = true) as
select date_trunc('week', d.work_date)::date week_start, d.staff_id, s.full_name,
       coalesce(s.contract_hours_week, fabula.setting_num('labor.contract_hours_week', 40)) contract_h,
       round(sum(d.planned_h), 1) planned_h, round(sum(d.worked_h), 1) worked_h,
       round(greatest(sum(d.worked_h) - coalesce(s.contract_hours_week, fabula.setting_num('labor.contract_hours_week', 40)), coalesce(sum(d.daily_over_h), 0), 0), 1) overtime_h,
       round(sum(d.worked_h) filter (where extract(isodow from d.work_date) = 7), 1) sunday_h,
       count(*) filter (where d.kind in ('ferie','permesso','malattia')) absence_days,
       count(*) filter (where d.planned_no_clock) planned_no_clock_days,
       count(*) filter (where d.clock_no_rota) clock_no_rota_days,
       round(greatest(sum(d.worked_h) - coalesce(s.contract_hours_week, fabula.setting_num('labor.contract_hours_week', 40)), coalesce(sum(d.daily_over_h), 0), 0)
             * fabula.setting_num('labor.hourly_cost_eur', 14.5) * (1 + fabula.setting_num('labor.overtime_premium_pct', 25) / 100), 2) overtime_eur
from fabula.v_hours_daily d join fabula.staff s on s.id = d.staff_id
group by 1, 2, 3, s.contract_hours_week;
grant select on fabula.v_hours_weekly to authenticated, service_role;

create or replace function fabula.copy_rota_week(p_from date, p_to date default null) returns int language plpgsql as $$
declare f date := date_trunc('week', p_from)::date; t date := date_trunc('week', coalesce(p_to, p_from + 7))::date; n int;
begin
  insert into fabula.rota_entries (staff_id, work_date, kind, start_time, end_time, break_min, area, notes)
  select e.staff_id, e.work_date + (t - f), e.kind, e.start_time, e.end_time, e.break_min, e.area, null
  from fabula.rota_entries e join fabula.staff s on s.id = e.staff_id and s.active
  where e.work_date between f and f + 6 and e.kind in ('lavoro','riposo')
  on conflict (staff_id, work_date) do nothing;
  get diagnostics n = row_count; return n;
end $$;
grant execute on function fabula.copy_rota_week(date, date) to authenticated, service_role;
