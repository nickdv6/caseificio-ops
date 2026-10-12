-- v0.93c · Audit 12/10/2026, phase 0 — bug 10 (A-05 / D-16): daily task times are Agropoli times.
-- Before: (p_date + due_time)::timestamptz used the database time zone, which is UTC on Supabase (checked live 12/10/2026),
-- so the pasteuriser start-of-day check due 06:45 showed at 07:45 in winter and 08:45 in summer, the twice-daily cold-room checks
-- at 09:00/19:00 or 10:00/20:00, and the day itself was the UTC day. Now every due time is read as Europe/Rome local time
-- (DST included) and the default day is today in Agropoli.
create or replace function fabula.generate_daily_tasks(p_date date default (now() at time zone 'Europe/Rome')::date)
 returns integer
 language plpgsql
 set search_path to 'fabula', 'public', 'extensions'
as $function$
declare n int := 0;
begin
  insert into fabula.task_instances (schedule_id, due_at)
  select s.id, (p_date + coalesce(s.due_time, time '12:00')) at time zone 'Europe/Rome'
  from fabula.task_schedules s
  where s.active and s.frequency in ('daily','per_shift')
  union all
  select s.id, (p_date + time '08:00') at time zone 'Europe/Rome' from fabula.task_schedules s
  where s.active and s.frequency = 'twice_daily'
  union all
  select s.id, (p_date + time '18:00') at time zone 'Europe/Rome' from fabula.task_schedules s
  where s.active and s.frequency = 'twice_daily'
  union all
  select s.id, (p_date + coalesce(s.due_time, time '12:00')) at time zone 'Europe/Rome' from fabula.task_schedules s
  where s.active and s.frequency = 'weekly' and extract(isodow from p_date) = 1
  union all
  select s.id, (p_date + coalesce(s.due_time, time '12:00')) at time zone 'Europe/Rome' from fabula.task_schedules s
  where s.active and s.frequency = 'monthly' and extract(day from p_date) = 1
  on conflict do nothing;
  get diagnostics n = row_count;
  -- mark yesterday's leftovers overdue
  update fabula.task_instances set status = 'overdue'
  where status = 'due' and due_at + make_interval(mins => 120) < now();
  return n;
end $function$;
