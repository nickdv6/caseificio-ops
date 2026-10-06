-- v0.79a (06/10/2026) · Fixes from the independent review of v0.69–v0.78:
-- 1. bot_fallback / bot_watchdog: only a run with details.mode = 'nightly' counts as the nightly backup. In summer the
--    2-hourly "latest" backup at 21:05 Rome hid a missing nightly (no stand-in re-send, no "missed" alert).
-- 2. device_watch: the "old app version" warning compared against the last successful check (moved every hour, so it never
--    fired). It now keeps when the live version last changed in setting infra.sw_seen.
-- 3. public.fabula_health: cron_ok reads the latest run that has a start time (a run row can exist before start_time is set).

create or replace function fabula.bot_fallback(p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'fabula', 'public'
AS $function$
declare v_day date := (p_now at time zone 'Europe/Rome')::date; r record; v_due timestamptz; v_claimed int; o jsonb; v_run uuid;
        done jsonb := '[]'::jsonb; v_err text;
begin
  if fabula.setting_num('bots.db_fallback', 1) <> 1 then return jsonb_build_object('enabled', false); end if;
  for r in select bs.agent, bs.grace_min, t.due from fabula.bot_schedule bs cross join unnest(bs.due_times) t(due)
           where bs.active and bs.agent = any (fabula.bot_fallback_agents())
             and extract(isodow from v_day) = any (bs.weekdays) and (bs.month_day is null or extract(day from v_day) = bs.month_day)
           order by t.due loop
    v_due := (v_day + r.due) at time zone 'Europe/Rome';
    continue when p_now < v_due + make_interval(mins => r.grace_min) or p_now >= v_due + interval '6 hours';
    continue when exists (select 1 from fabula.agent_runs ar where ar.agent = r.agent and ar.started_at >= v_due - interval '30 minutes'
                         and (ar.agent <> 'backup_export' or ar.details->>'mode' = 'nightly'));   -- v0.79: a 2-hourly "latest" backup is not the nightly
    insert into fabula.bot_fallback_runs (agent, slot, ran_at) values (r.agent, v_due, p_now) on conflict do nothing;
    get diagnostics v_claimed = row_count;
    continue when v_claimed = 0;
    begin
      o := fabula.bot_fallback_run(r.agent, v_day);
      v_run := null;
      if r.agent <> 'backup_export' then        -- the backup logs its own run when it finishes
        insert into fabula.agent_runs (agent, started_at, finished_at, status, summary, details)
        values (r.agent, p_now, clock_timestamp(), 'ok', 'Eseguito dal database (bot non partito): ' || coalesce(o->>'summary', ''),
                jsonb_build_object('via', 'db_fallback', 'due', v_due, 'result', o->'result'))
        returning id into v_run;
      end if;
      perform fabula.post_bot_message(r.agent, o->>'severity', 'Sostituito dal database · ' || coalesce(o->>'title', ''),
                format(E'Il bot "%s" non è partito alle %s: il database ha fatto il suo lavoro. Le notifiche del bot non sono partite: è tutto qui sotto.\n\n%s',
                       fabula.bot_display_name(r.agent), to_char(r.due, 'HH24:MI'), coalesce(o->>'body', '')), v_run);
      update fabula.bot_fallback_runs set status = 'ok', summary = o->>'summary', result = o->'result' where agent = r.agent and slot = v_due;
      done := done || jsonb_build_object('agent', r.agent, 'due', to_char(r.due, 'HH24:MI'), 'status', 'ok', 'summary', o->>'summary');
    exception when others then
      v_err := sqlerrm;
      insert into fabula.agent_runs (agent, started_at, finished_at, status, summary, error, details)
      values (r.agent, p_now, clock_timestamp(), 'error', 'Ripiego del database non riuscito', left(v_err, 500), jsonb_build_object('via', 'db_fallback', 'due', v_due));
      update fabula.bot_fallback_runs set status = 'error', summary = left(v_err, 300) where agent = r.agent and slot = v_due;
      done := done || jsonb_build_object('agent', r.agent, 'due', to_char(r.due, 'HH24:MI'), 'status', 'error', 'error', left(v_err, 200));
    end;
  end loop;
  return jsonb_build_object('enabled', true, 'checked_at', p_now, 'runs', done);
end $function$;

create or replace function fabula.bot_watchdog(p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'fabula', 'public'
AS $function$
declare v_ny timestamp := p_now at time zone 'Europe/Rome'; v_day date := (p_now at time zone 'Europe/Rome')::date;
        r record; a jsonb := '[]'::jsonb; v_due timestamptz; v_ref text; n int; v_msg text; v_last_cron timestamptz;
begin
  for r in select ar.id, ar.agent, ar.started_at, coalesce(nullif(ar.error, ''), nullif(ar.summary, ''), 'errore senza dettagli') err, fabula.bot_display_name(ar.agent) nm
           from fabula.agent_runs ar left join fabula.bot_schedule bs on bs.agent = ar.agent
           where ar.status = 'error' and ar.started_at > p_now - interval '26 hours' order by ar.started_at loop
    insert into fabula.bot_alerts (agent, kind, ref, detail) values (r.agent, 'error', r.id::text, left(r.err, 300)) on conflict do nothing;
    get diagnostics n = row_count;
    if n > 0 then a := a || jsonb_build_object('agent', r.agent, 'name', r.nm, 'kind', 'error', 'at', r.started_at, 'detail', left(r.err, 200)); end if;
  end loop;
  for r in select bs.*, t.due from fabula.bot_schedule bs cross join unnest(bs.due_times) t(due)
           where bs.active and extract(isodow from v_day) = any (bs.weekdays) and (bs.month_day is null or extract(day from v_day) = bs.month_day)
             and v_day + t.due + make_interval(mins => bs.grace_min
                   + case when bs.agent = any (fabula.bot_fallback_agents()) and fabula.setting_num('bots.db_fallback', 1) = 1 then 20 else 0 end) <= v_ny loop
    v_due := (v_day + r.due) at time zone 'Europe/Rome';
    if not exists (select 1 from fabula.agent_runs ar where ar.agent = r.agent and ar.started_at >= v_due - interval '30 minutes'
                   and (ar.agent <> 'backup_export' or ar.details->>'mode' = 'nightly')) then   -- v0.79
      v_ref := to_char(v_day + r.due, 'YYYY-MM-DD HH24:MI');
      insert into fabula.bot_alerts (agent, kind, ref, detail) values (r.agent, 'missed', v_ref, null) on conflict do nothing;
      get diagnostics n = row_count;
      if n > 0 then a := a || jsonb_build_object('agent', r.agent, 'name', fabula.bot_display_name(r.agent), 'kind', 'missed', 'due_ny', to_char(r.due, 'HH24:MI'),
                                                 'due_rome', to_char(v_due at time zone 'Europe/Rome', 'HH24:MI')); end if;
    end if;
  end loop;
  for r in select ar.id, ar.agent, ar.started_at, fabula.bot_display_name(ar.agent) nm from fabula.agent_runs ar left join fabula.bot_schedule bs on bs.agent = ar.agent
           where ar.finished_at is null and ar.status is distinct from 'error' and ar.started_at between p_now - interval '26 hours' and p_now - interval '30 minutes' loop
    insert into fabula.bot_alerts (agent, kind, ref) values (r.agent, 'stuck', r.id::text) on conflict do nothing;
    get diagnostics n = row_count;
    if n > 0 then a := a || jsonb_build_object('agent', r.agent, 'name', r.nm, 'kind', 'stuck', 'at', r.started_at); end if;
  end loop;
  -- v0.74: the database scheduler itself
  select max(start_time) into v_last_cron from cron.job_run_details;
  if v_last_cron is null or v_last_cron < p_now - interval '20 minutes' then
    insert into fabula.bot_alerts (agent, kind, ref, detail) values ('pg_cron', 'stuck', 'scheduler ' || to_char(p_now at time zone 'Europe/Rome', 'YYYY-MM-DD HH24'), 'pg_cron fermo') on conflict do nothing;   -- (kind check: error/missed/stuck)
    get diagnostics n = row_count;
    if n > 0 then a := a || jsonb_build_object('agent', 'pg_cron', 'name', 'Automazioni del database', 'kind', 'cron_stopped', 'at', v_last_cron); end if;
  end if;
  for r in select d.runid, j.jobname, d.start_time, left(coalesce(d.return_message, ''), 200) msg
             from cron.job_run_details d join cron.job j on j.jobid = d.jobid
            where d.status = 'failed' and d.start_time > p_now - interval '26 hours' order by d.start_time loop
    insert into fabula.bot_alerts (agent, kind, ref, detail) values ('pg_cron', 'error', 'cron run ' || r.runid, r.jobname || ': ' || r.msg) on conflict do nothing;
    get diagnostics n = row_count;
    if n > 0 then a := a || jsonb_build_object('agent', 'pg_cron', 'name', r.jobname, 'kind', 'cron_failed', 'at', r.start_time, 'detail', r.msg); end if;
  end loop;

  if jsonb_array_length(a) > 0 then
    select string_agg(case x->>'kind'
             when 'error' then format('❌ %s: errore alle %s (it.) — %s', x->>'name', to_char((x->>'at')::timestamptz at time zone 'Europe/Rome', 'HH24:MI'), x->>'detail')
             when 'missed' then format('⏰ %s: non è partito (previsto alle %s, ora di Agropoli)', x->>'name', x->>'due_rome')
             when 'cron_stopped' then format('🛑 Le automazioni del database (pg_cron) sono ferme: ultima esecuzione %s. Backup, controlli e sostituti dei bot non girano — aprire Supabase → Integrations → Cron, o scrivere al supporto Supabase.',
                                             coalesce(to_char((x->>'at')::timestamptz at time zone 'Europe/Rome', 'DD/MM HH24:MI'), 'mai'))
             when 'cron_failed' then format('❌ Automazione del database "%s" fallita alle %s — %s', x->>'name', to_char((x->>'at')::timestamptz at time zone 'Europe/Rome', 'HH24:MI'), coalesce(nullif(x->>'detail', ''), 'nessun dettaglio'))
             else format('⏳ %s: avviato alle %s (it.) e mai finito', x->>'name', to_char((x->>'at')::timestamptz at time zone 'Europe/Rome', 'HH24:MI')) end, E'\n')
      into v_msg from jsonb_array_elements(a) x;
    v_msg := 'Problemi con i bot:' || E'\n' || v_msg || E'\n' || 'Dettagli: Configurazione → Bot. Un bot fermo si rilancia dalle attività programmate.';
    insert into fabula.notices (key, severity, title_it, items, expires_at)
    values ('bot_alert', 'alert', format('%s problemi con i bot', jsonb_array_length(a)), a, p_now + interval '24 hours')
    on conflict (key) do update set severity = 'alert', title_it = excluded.title_it, items = excluded.items, created_at = p_now, expires_at = excluded.expires_at, resolved_at = null;
  end if;
  return jsonb_build_object('checked_at', p_now, 'alerts', a, 'message_it', v_msg);
end $function$;

create or replace function fabula.device_watch(p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'fabula', 'public'
AS $function$
declare d record; v_live text := fabula.live_app_version(); v_rel timestamptz; out jsonb := '[]';
begin
  -- v0.79: the release time is when the live version last changed (kept in infra.sw_seen = '<version>|<time>'),
  -- not the last successful check (that moved every hour, so the old-app warning never fired)
  if v_live is not null and split_part(coalesce((select value from fabula.settings where key = 'infra.sw_seen'), ''), '|', 1) is distinct from v_live then
    insert into fabula.settings (key, value, description, data_type, sort, updated_at)
    values ('infra.sw_seen', v_live || '|' || p_now::text, 'Versione dell''app in linea e da quando (aggiornato da device_watch)', 'text', 99, now())
    on conflict (key) do update set value = excluded.value, updated_at = now();
  end if;
  v_rel := nullif(split_part(coalesce((select value from fabula.settings where key = 'infra.sw_seen'), ''), '|', 2), '')::timestamptz;
  for d in select * from fabula.devices where last_seen_at > p_now - interval '14 days' loop
    -- records waiting more than 2 h (from the last check-in; a tablet that stopped checking in keeps its last report)
    if d.queue_len > 0 and d.oldest_queued_at < p_now - interval '2 hours'
       and coalesce((d.warned->>'queue')::timestamptz, '-infinity') < p_now - interval '1 day' then
      perform fabula.post_bot_message('tablet', 'warn', format('%s: %s registrazioni in attesa da %s', coalesce(d.label, d.device_uid), d.queue_len,
                to_char(d.oldest_queued_at at time zone 'Europe/Rome', 'DD/MM HH24:MI')),
        format(E'Il tablet "%s" ha %s registrazioni salvate senza rete e non ancora arrivate al database (la più vecchia delle %s). Ultimo contatto: %s.\nControllare che il tablet sia acceso e connesso al Wi-Fi e aprire l''app: partono da sole.',
               coalesce(d.label, d.device_uid), d.queue_len, to_char(d.oldest_queued_at at time zone 'Europe/Rome', 'HH24:MI del DD/MM'),
               to_char(d.last_seen_at at time zone 'Europe/Rome', 'DD/MM HH24:MI')));
      update fabula.devices set warned = warned || jsonb_build_object('queue', p_now) where device_uid = d.device_uid;
      out := out || jsonb_build_object('device', d.label, 'kind', 'queue');
    end if;
    -- old app a day after the release
    if v_live is not null and d.app_version is not null and d.app_version <> v_live and v_rel < p_now - interval '1 day'
       and d.last_seen_at > p_now - interval '1 day'
       and coalesce((d.warned->>'version')::timestamptz, '-infinity') < p_now - interval '1 day' then
      perform fabula.post_bot_message('tablet', 'warn', format('%s usa ancora la versione %s (attuale %s)', coalesce(d.label, d.device_uid), d.app_version, v_live),
        format('Il tablet "%s" non ha caricato l''ultima versione dell''app. Sul tablet compare "Aggiorna": toccalo, oppure chiudi e riapri l''app con la rete.', coalesce(d.label, d.device_uid)));
      update fabula.devices set warned = warned || jsonb_build_object('version', p_now) where device_uid = d.device_uid;
      out := out || jsonb_build_object('device', d.label, 'kind', 'version');
    end if;
  end loop;
  return jsonb_build_object('checked_at', p_now, 'warnings', out);
end $function$;

create or replace function public.fabula_health() returns jsonb
language sql stable security definer set search_path = fabula, public, pg_catalog as $$
  select jsonb_build_object(
    'db', true,
    'cron_ok', coalesce((select start_time from cron.job_run_details where start_time is not null order by runid desc limit 1) > now() - interval '20 minutes', false),
    'backup_ok', exists (select 1 from fabula.agent_runs where agent = 'backup_export' and status = 'ok' and started_at > now() - interval '26 hours'),
    'at', now())
$$;
