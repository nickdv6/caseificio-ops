-- v0.78a (05/10/2026) · Health check for the outside watcher. A GitHub Actions job (.github/workflows/watch.yml) calls
-- public.fabula_health() every 30 minutes with the public (publishable) key. It runs on GitHub, so it still works when
-- Supabase, the bots or Claude are down, and GitHub e-mails the repo owner when it fails twice in a row.
-- Returns booleans and a timestamp only: database up, pg_cron ran in the last 20 minutes, nightly backup in the last 26 h.
create or replace function public.fabula_health() returns jsonb
language sql stable security definer set search_path = fabula, public, pg_catalog as $$
  select jsonb_build_object(
    'db', true,
    'cron_ok', coalesce((select start_time from cron.job_run_details order by runid desc limit 1) > now() - interval '20 minutes', false),
    'backup_ok', exists (select 1 from fabula.agent_runs where agent = 'backup_export' and status = 'ok' and started_at > now() - interval '26 hours'),
    'at', now())
$$;
revoke all on function public.fabula_health() from public;
grant execute on function public.fabula_health() to anon, authenticated, service_role;
comment on function public.fabula_health() is 'v0.78: outside watcher (GitHub Actions) — booleans only, no business data';

insert into fabula.security_accepted (key, reason, accepted_at) values
 ('anon_security_definer_function_executable:public.fabula_health()', 'by design: outside watcher health check (v0.78); returns three booleans and now(), no data', now()),
 ('authenticated_security_definer_function_executable:public.fabula_health()', 'by design: outside watcher health check (v0.78); returns three booleans and now(), no data', now())
on conflict (key) do nothing;
