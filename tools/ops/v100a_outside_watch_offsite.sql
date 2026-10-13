-- v1.00a · Ops batch (audit E-22, E-24, E-25). Doc: claude/ops-batch-v100-2026-10-13.md
-- The outside watcher (GitHub, scheduled every 30 min) and the nightly off-site backup copy (GitHub, encrypted artifact, 90 days)
-- report here with the backup token. The database raises the alarm when either goes quiet, so each side watches the other:
--   GitHub down or the schedule switched off  → «outside_watch» (pg_cron, hourly) alerts on Telegram;
--   Supabase down                             → the watcher alerts the partners' Telegram group directly.
-- Board: «Outside watcher» becomes automatic, new check «Off-site backup copy»; the monthly restore drill on GitHub
-- records itself, so «Backup restore tested» stays green without a hand-written row.

-- 1. reports from GitHub. Token = the Vault secret backup_export_token (the GitHub jobs hold it as BACKUP_EXPORT_TOKEN).
create or replace function public.fabula_outside_report(p_token text, p_kind text, p_detail jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, fabula, public
as $$
declare
  v_ok boolean;
  v_key text;
  v_detail jsonb := case when jsonb_typeof(p_detail) = 'object' then p_detail else '{}'::jsonb end;
begin
  if not coalesce(fabula.backup_check_token(p_token), false) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_kind is null or p_kind not in ('watcher', 'offsite_backup', 'restore_drill') then
    raise exception 'kind non valido: %', p_kind using errcode = '22023';
  end if;
  if length(v_detail::text) > 8000 then
    v_detail := jsonb_strip_nulls(jsonb_build_object('ok', v_detail->'ok', 'stale', v_detail->'stale', 'summary', left(v_detail->>'summary', 300),
                  'error', left(v_detail->>'error', 300), 'run_url', left(v_detail->>'run_url', 200), 'truncated', true));
  end if;
  -- only an explicit {"ok": true} counts as success (audit review: a report without «ok» must not turn the board green)
  v_ok := coalesce(v_detail->'ok' = 'true'::jsonb, false);

  if p_kind = 'restore_drill' then
    insert into fabula.agent_runs (agent, status, started_at, finished_at, summary, error, details)
    values ('restore_drill', case when v_ok then 'ok' else 'error' end, now(), now(),
            left(coalesce(v_detail->>'summary', 'Prova di ripristino su GitHub'), 500),
            case when v_ok then null else left(coalesce(v_detail->>'error', v_detail->>'summary', 'non riuscita'), 500) end,
            v_detail || jsonb_build_object('via', 'github'));
    return jsonb_build_object('ok', true);
  end if;

  v_key := case p_kind when 'watcher' then 'outside_watcher' else 'offsite_backup' end;
  insert into fabula.infra_status (key, ok, detail, data, checked_at, last_ok_at, fail_streak)
  values (v_key, v_ok, left(coalesce(v_detail->>'summary', case when v_ok then 'OK' else 'problema' end), 300), v_detail,
          now(), case when v_ok then now() end, case when v_ok then 0 else 1 end)
  on conflict (key) do update set
    ok = excluded.ok, detail = excluded.detail, data = excluded.data, checked_at = now(),
    last_ok_at = case when excluded.ok then now() else infra_status.last_ok_at end,
    fail_streak = case when excluded.ok then 0 else infra_status.fail_streak + 1 end;
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.fabula_outside_report(text, text, jsonb) from public;
revoke all on function public.fabula_outside_report(text, text, jsonb) from anon, authenticated;
grant execute on function public.fabula_outside_report(text, text, jsonb) to anon, service_role;

insert into fabula.security_accepted (key, reason, accepted_at) values
  ('anon_security_definer_function_executable:public.fabula_outside_report(p_token text, p_kind text, p_detail jsonb)',
   'by design (v1.00a, audit E-22/E-24): GitHub reports the outside watcher, the off-site copy and the restore drill with the publishable key; refused unless the backup token matches (backup_check_token), writes one status row or one drill row', now())
on conflict (key) do nothing;

-- 2. health for the watcher: the nightly backup counts on its own (audit E-22: the 2-hourly «latest» hid a broken nightly)
create or replace function public.fabula_health()
returns jsonb
language sql
stable security definer
set search_path to 'pg_catalog', 'fabula', 'public'
as $function$
  -- v1.00a: a bot counts as stopped until it runs again (its latest due slot in the last 26 h has no run since), so
  -- the watcher no longer says «tornato tutto OK» when a missed slot simply falls out of a 4-hour window.
  with d as (select day from (values ((now() at time zone 'Europe/Rome')::date), ((now() at time zone 'Europe/Rome')::date - 1)) v(day)),
  slots as (
    select bs.agent, (d.day + t.due) at time zone 'Europe/Rome' as due_at, bs.grace_min
      from fabula.bot_schedule bs cross join d cross join unnest(bs.due_times) t(due)
     where bs.active and bs.agent <> 'backup_export' and extract(isodow from d.day) = any (bs.weekdays)
       and (bs.month_day is null or extract(day from d.day) = bs.month_day)),
  latest as (
    select distinct on (s.agent) s.agent, s.due_at from slots s
     where s.due_at + make_interval(mins => s.grace_min + 20) <= now() and s.due_at > now() - interval '26 hours'
     order by s.agent, s.due_at desc),
  missed as (
    select l.agent from latest l
     where not exists (select 1 from fabula.agent_runs ar where ar.agent = l.agent and ar.started_at >= l.due_at - interval '30 minutes'
                         and coalesce(ar.details->>'via', '') <> 'db_fallback'))
  select jsonb_build_object(
    'db', true,
    'cron_ok', coalesce((select start_time from cron.job_run_details where start_time is not null order by runid desc limit 1) > now() - interval '20 minutes', false),
    'backup_ok', exists (select 1 from fabula.agent_runs where agent = 'backup_export' and status = 'ok' and started_at > now() - interval '26 hours'),
    'backup_nightly_ok', exists (select 1 from fabula.agent_runs where agent = 'backup_export' and status = 'ok'
                                   and details->>'mode' = 'nightly' and started_at > now() - interval '26 hours'),
    'bots_ok', not exists (select 1 from missed),
    'bots_missed', (select count(*) from missed),
    'at', now())
$function$;

-- 3. the database watches GitHub: hourly, a notice and one Telegram message (topic «infra») per incident when
--    the outside watcher has been silent for 24 h (GitHub's scheduler skips runs — gaps of ~10 h were seen — and switches
--    schedules off in a public repo after 60 days without commits), or no off-site copy succeeded for 50 h (two nights,
--    three tries each; a copy that never succeeded counts as overdue). Nothing is raised before the first report: until
--    the GitHub secrets are set, the board says what is missing.
create or replace function fabula.outside_watch(p_now timestamptz default now())
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, fabula, public
as $$
declare
  w fabula.infra_status;
  o fabula.infra_status;
  v_raised text[] := '{}';
  v_title text;
  v_body text;
  r record;
begin
  select * into w from fabula.infra_status where key = 'outside_watcher';
  select * into o from fabula.infra_status where key = 'offsite_backup';

  for r in
    select 'outside_watcher_silent' as k,
           w.key is not null and w.checked_at < p_now - interval '24 hours' as bad,
           'Il controllo esterno su GitHub non gira da ' || floor(extract(epoch from p_now - w.checked_at) / 3600)::int || ' ore' as title,
           'Ultimo giro ' || to_char(w.checked_at at time zone 'Europe/Rome', 'DD/MM HH24:MI') || ' (ora italiana). '
             || 'Se Supabase si ferma adesso, nessuno lo segnala. Apri GitHub → Actions → «Outside watcher»: se è disattivato, «Enable workflow», poi «Run workflow».' as body
    union all
    select 'offsite_backup_stale',
           o.key is not null and coalesce(o.last_ok_at < p_now - interval '50 hours', true),
           case when o.last_ok_at is null then 'Copia del backup fuori da Supabase: non è mai riuscita'
                else 'Copia del backup fuori da Supabase ferma da ' || floor(extract(epoch from p_now - o.last_ok_at) / 3600)::int || ' ore' end,
           'Ultima copia riuscita: ' || coalesce(to_char(o.last_ok_at at time zone 'Europe/Rome', 'DD/MM HH24:MI'), 'nessuna')
             || coalesce(' · ultimo esito: ' || o.detail, '') || '. Apri GitHub → Actions → «Off-site backup» e guarda l''ultimo giro.'
  loop
    if r.bad then
      if not exists (select 1 from fabula.notices where key = r.k and resolved_at is null) then
        perform fabula.notify_enqueue('infra', r.title, r.body, 'Controllo sistema', 'outside_watch', r.k, r.k || ':' || to_char(p_now, 'YYYYMMDDHH24'));
      end if;
      insert into fabula.notices (key, severity, title_it, items, expires_at)
      values (r.k, 'warn', r.title, jsonb_build_array(jsonb_build_object('code', r.k, 'label_it', r.body)), p_now + interval '2 hours')
      on conflict (key) do update set severity = 'warn', title_it = excluded.title_it, items = excluded.items, expires_at = excluded.expires_at,
        resolved_at = null, created_at = case when notices.resolved_at is null then notices.created_at else now() end;
      v_raised := v_raised || r.k;
    else
      update fabula.notices set resolved_at = p_now where key = r.k and resolved_at is null;
    end if;
  end loop;
  return jsonb_build_object('raised', to_jsonb(v_raised), 'watcher_at', w.checked_at, 'offsite_ok_at', o.last_ok_at);
end $$;

revoke all on function fabula.outside_watch(timestamptz) from public;
revoke all on function fabula.outside_watch(timestamptz) from anon, authenticated;

do $$
begin
  perform cron.schedule('fabula_outside_watch', '50 * * * *', 'select fabula.outside_watch()');
end $$;

-- 4. board: «Outside watcher» becomes automatic, new «Off-site backup copy». infra_checks() is patched in place from its
--    live definition (the anchor must match once).
do $mig$
declare
  d text := pg_get_functiondef('fabula.infra_checks()'::regprocedure);
  a text := $a$  return v_out;
end $a$;
  r text := $r$  -- v1.00a (audit E-22/E-24): reports from GitHub (public.fabula_outside_report)
  v_out := v_out || jsonb_build_object(
    'outside_watcher', (select jsonb_build_object(
        'done', coalesce(x.checked_at > now() - interval '24 hours', false),
        'detail', case when x.key is null then 'Not reporting yet: add the GitHub secret BACKUP_EXPORT_TOKEN (claude/ops-batch-v100-2026-10-13.md)'
                       when x.checked_at <= now() - interval '24 hours' then 'Silent since ' || to_char(x.checked_at at time zone 'Europe/Rome', 'DD/MM HH24:MI')
                            || ': GitHub → Actions → «Outside watcher» → enable it and «Run workflow»'
                       else 'Last run ' || to_char(x.checked_at at time zone 'Europe/Rome', 'DD/MM HH24:MI')
                            || case when x.ok then ' · all OK' else ' · found: ' || coalesce(x.detail, '?') end
                            || ' · alerts go to the Telegram group' end)
      from (select 1) one left join fabula.infra_status x on x.key = 'outside_watcher'),
    'offsite_backup', (select jsonb_build_object(
        'done', coalesce(x.ok and x.last_ok_at > now() - interval '50 hours', false),
        'detail', case when x.key is null then 'No off-site copy yet: add the GitHub secrets BACKUP_EXPORT_TOKEN and BACKUP_PASSPHRASE (claude/ops-batch-v100-2026-10-13.md)'
                       when not x.ok then 'Last attempt failed ' || to_char(x.checked_at at time zone 'Europe/Rome', 'DD/MM HH24:MI') || ': ' || coalesce(x.detail, '?')
                       when x.last_ok_at <= now() - interval '50 hours' then 'Last copy ' || to_char(x.last_ok_at at time zone 'Europe/Rome', 'DD/MM HH24:MI') || ': overdue (nightly)'
                       else coalesce(x.detail, 'OK') end)
      from (select 1) one left join fabula.infra_status x on x.key = 'offsite_backup'));
  return v_out;
end $r$;
begin
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then
    raise exception 'infra_checks patch: anchor not found exactly once';
  end if;
  execute replace(d, a, r);
end $mig$;

insert into fabula.dash_checks (key, sort, label, kind, done, note, updated_at) values
  ('outside_watcher', 42, 'Outside watcher running and reporting (GitHub, last run < 24 h)', 'auto', false, null, now()),
  ('offsite_backup', 43, 'Off-site backup copy in the last 2 nights (encrypted, GitHub)', 'auto', false, null, now())
on conflict (key) do update set label = excluded.label, sort = excluded.sort, kind = excluded.kind, updated_at = excluded.updated_at;
