-- v0.93c audit fix A-05 / D-16 · run on a fresh replay (the database runs in UTC, as Supabase does):
--   tools/go-live/drill/infra-test/replay.sh tt_test
--   su postgres -c "psql -d tt_test -f tools/go-live/drill/prod-test/test_audit_task_times.sql" | grep -E "PASS|FAIL"
\set ON_ERROR_STOP 0
set timezone = 'UTC';
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
create or replace function pg_temp.rome(p_code text, p_day date) returns text language sql as
$$ select string_agg(to_char(ti.due_at at time zone 'Europe/Rome', 'HH24:MI'), ',' order by ti.due_at)
     from fabula.task_instances ti join fabula.task_schedules s on s.id = ti.schedule_id
    where s.code = p_code and (ti.due_at at time zone 'Europe/Rome')::date = p_day $$;
select fabula.generate_daily_tasks('2027-02-15') w, fabula.generate_daily_tasks('2027-07-15') s \gset
select pg_temp.ck('winter (CET): pasteuriser check due 06:45 in Agropoli', pg_temp.rome('T-VALVE', '2027-02-15') = '06:45', pg_temp.rome('T-VALVE', '2027-02-15'));
select pg_temp.ck('summer (CEST): pasteuriser check due 06:45 in Agropoli', pg_temp.rome('T-VALVE', '2027-07-15') = '06:45', pg_temp.rome('T-VALVE', '2027-07-15'));
select pg_temp.ck('twice-daily checks at 08:00 and 18:00 Agropoli time',
  (select pg_temp.rome(s.code, '2027-07-15') from fabula.task_schedules s where s.frequency = 'twice_daily' and s.active limit 1) = '08:00,18:00',
  (select s.code || ' ' || pg_temp.rome(s.code, '2027-07-15') from fabula.task_schedules s where s.frequency = 'twice_daily' and s.active limit 1));
select pg_temp.ck('the default day is today in Agropoli',
  pg_get_function_arguments('fabula.generate_daily_tasks(date)'::regprocedure) like '%Europe/Rome%');
