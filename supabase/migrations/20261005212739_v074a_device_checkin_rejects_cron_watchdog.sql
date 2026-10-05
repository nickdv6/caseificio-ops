-- v0.74a (05/10/2026) · Reliability: tablets check in, refused saves reach the office, the database scheduler is watched.
-- 1. fabula.device_checkin(): every few minutes (and after each send) a tablet reports its app version, the records still
--    waiting in its queue (and since when) and the saves the database refused. Devices are listed in fabula.devices;
--    refused saves are kept in fabula.tablet_rejects (full content, error, who, when) and each new one is posted to the bell
--    (Configurazione → Bot · "Zio Tonino · Tablet") — before, they lived only on the tablet and could be deleted unseen.
--    The answer tells the tablet the live app version, so it can offer a one-tap update.
-- 2. fabula.device_watch() (pg_cron every 15 min): a tablet with records waiting for more than 2 hours, or still on an old
--    app version a day after a release, gets one warning (repeated at most once a day).
-- 3. bot_watchdog() — run hourly by the alarm bot, which lives outside the database — now also reports when the database
--    scheduler (pg_cron) has run nothing for 20 minutes, and every scheduled job that failed. The database watches the bots
--    (heartbeat, stand-ins); now the bots watch the database too.

create table if not exists fabula.devices (
  device_uid text primary key,
  label text,
  staff_id uuid references fabula.staff(id),
  app_version text,
  queue_len int not null default 0,
  oldest_queued_at timestamptz,
  failed_len int not null default 0,
  user_agent text,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  warned jsonb not null default '{}'
);
comment on table fabula.devices is 'v0.74: tablets and browsers that check in (app version, offline queue, refused saves).';

create table if not exists fabula.tablet_rejects (
  qid text primary key,
  device_uid text,
  device_label text,
  staff_id uuid references fabula.staff(id),
  what text,
  ops jsonb not null,
  error text,
  code text,
  failed_at timestamptz,
  reported_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by text,
  resolution text
);
comment on table fabula.tablet_rejects is 'v0.74: saves the database refused when a tablet sent its offline queue — kept so nothing is lost.';

do $$ declare t text; begin
  foreach t in array array['devices', 'tablet_rejects'] loop
    execute format('alter table fabula.%I enable row level security', t);
    execute format('grant select on fabula.%I to authenticated', t);
    execute format('grant all on fabula.%I to service_role', t);
    insert into fabula.table_areas(table_name, area, read_open, write_level) values (t, 'sistema', false, 3) on conflict (table_name) do nothing;
    if not exists (select 1 from pg_policy where polrelid = ('fabula.' || t)::regclass and polname = t || '_authenticated_all') then
      execute format('create policy %I on fabula.%I for select to authenticated using (true)', t || '_authenticated_all', t);
      execute format('create policy %I on fabula.%I as restrictive for select to authenticated using ((select fabula.can_table(%L, false)))', t || '_role_select', t, t);
    end if;
  end loop;
end $$;

insert into fabula.bot_nicknames (agent, nickname, title_it, sort, updated_at)
values ('tablet', 'Zio Tonino', 'Tablet e registrazioni rifiutate', coalesce((select max(sort) + 1 from fabula.bot_nicknames), 50), now())
on conflict (agent) do nothing;

create or replace function fabula.live_app_version() returns text
language sql stable security definer set search_path = fabula, public as $$
  select coalesce((select data->>'sw' from fabula.infra_status where key = 'site' and ok and data ? 'sw'),
                  (select data->>'sw' from fabula.infra_status where key = 'github_sw' and ok))
$$;
revoke all on function fabula.live_app_version() from public, anon;
grant execute on function fabula.live_app_version() to authenticated, service_role;

-- a tablet checks in (any signed-in staff member; the device reports for whoever is logged in)
create or replace function fabula.device_checkin(p_device_uid text, p_label text, p_version text, p_queue_len int, p_oldest timestamptz,
                                                 p_failed jsonb default '[]', p_user_agent text default null) returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare v_staff uuid := fabula.my_staff_id(); f jsonb; n int := 0; v_new jsonb := '[]'; v_what text;
begin
  if v_staff is null then raise exception 'Solo il personale può registrare un dispositivo' using errcode = '42501'; end if;
  if coalesce(p_device_uid, '') !~ '^[A-Za-z0-9_-]{6,64}$' then raise exception 'Identificativo dispositivo non valido'; end if;
  insert into fabula.devices (device_uid, label, staff_id, app_version, queue_len, oldest_queued_at, failed_len, user_agent, last_seen_at)
  values (p_device_uid, left(p_label, 40), v_staff, left(p_version, 20), greatest(coalesce(p_queue_len, 0), 0), p_oldest,
          jsonb_array_length(coalesce(p_failed, '[]')), left(p_user_agent, 200), now())
  on conflict (device_uid) do update set label = excluded.label, staff_id = excluded.staff_id, app_version = excluded.app_version,
         queue_len = excluded.queue_len, oldest_queued_at = excluded.oldest_queued_at, failed_len = excluded.failed_len,
         user_agent = coalesce(excluded.user_agent, devices.user_agent), last_seen_at = now(),
         warned = case when excluded.queue_len = 0 then devices.warned - 'queue' else devices.warned end;
  for f in select * from jsonb_array_elements(coalesce(p_failed, '[]')) limit 50 loop
    continue when coalesce(f->>'qid', '') = '' or length(f::text) > 100000;
    v_what := coalesce((select o->>'table' from jsonb_array_elements(coalesce(f->'ops', '[]')) o where o ? 'table' limit 1),
                       (select o->>'rpc' from jsonb_array_elements(coalesce(f->'ops', '[]')) o where o ? 'rpc' limit 1), '?');
    insert into fabula.tablet_rejects (qid, device_uid, device_label, staff_id, what, ops, error, code, failed_at)
    values (f->>'qid', p_device_uid, left(p_label, 40), v_staff, v_what, coalesce(f->'ops', '[]'), left(f->>'error', 500), left(f->>'code', 20),
            case when f->>'failed_at' ~ '^\d+$' then to_timestamp((f->>'failed_at')::bigint / 1000.0) else now() end)
    on conflict (qid) do nothing;
    get diagnostics n = row_count;
    if n > 0 then v_new := v_new || jsonb_build_object('what', v_what, 'error', left(f->>'error', 200)); end if;
  end loop;
  if jsonb_array_length(v_new) > 0 then
    perform fabula.post_bot_message('tablet', 'alert',
      format('%s registrazion%s rifiutat%s dal database (%s)', jsonb_array_length(v_new), case when jsonb_array_length(v_new) = 1 then 'e' else 'i' end,
             case when jsonb_array_length(v_new) = 1 then 'a' else 'e' end, coalesce(left(p_label, 40), 'tablet')),
      format(E'Il tablet "%s" (%s) ha inviato registrazioni fatte senza rete che il database non ha accettato:\n%s\n\nSono salvate per intero in fabula.tablet_rejects: vanno rifatte a mano o corrette (chiedi a chi le ha registrate). Se è una registrazione HACCP (CCP, temperature, pulizie) va rifatta oggi.',
             coalesce(p_label, 'tablet'), (select full_name from fabula.staff where id = v_staff),
             (select string_agg('• ' || (x->>'what') || ': ' || coalesce(x->>'error', 'errore'), E'\n') from jsonb_array_elements(v_new) x)));
  end if;
  return jsonb_build_object('ok', true, 'reported', jsonb_array_length(v_new), 'live_version', fabula.live_app_version());
end $$;
revoke all on function fabula.device_checkin(text, text, text, int, timestamptz, jsonb, text) from public, anon;
grant execute on function fabula.device_checkin(text, text, text, int, timestamptz, jsonb, text) to authenticated, service_role;

-- every 15 minutes: tablets with records stuck or an old app
create or replace function fabula.device_watch(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare d record; v_live text := fabula.live_app_version(); v_rel timestamptz; out jsonb := '[]';
begin
  select coalesce(last_ok_at, checked_at) into v_rel from fabula.infra_status where key = 'github_sw';
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
end $$;
revoke all on function fabula.device_watch(timestamptz) from public, anon, authenticated;

-- mark a refused save as dealt with (console / SQL)
create or replace function fabula.resolve_tablet_reject(p_qid text, p_resolution text default null) returns boolean
language plpgsql security definer set search_path = fabula, public as $$
begin
  perform fabula.require_perm('sistema', 2);
  update fabula.tablet_rejects set resolved_at = now(), resolution = left(p_resolution, 300),
         resolved_by = coalesce((select full_name from fabula.staff where id = fabula.my_staff_id()), 'sistema')
   where qid = p_qid and resolved_at is null;
  return found;
end $$;
revoke all on function fabula.resolve_tablet_reject(text, text) from public, anon;
grant execute on function fabula.resolve_tablet_reject(text, text) to authenticated, service_role;

-- the alarm bot (outside the database) also watches the database scheduler
create or replace function fabula.bot_watchdog(p_now timestamp with time zone DEFAULT now()) returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
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
    if not exists (select 1 from fabula.agent_runs ar where ar.agent = r.agent and ar.started_at >= v_due - interval '30 minutes') then
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
end $$;

select cron.schedule('fabula_device_watch', '*/15 * * * *', $c$select fabula.device_watch()$c$);

insert into fabula.security_accepted (key, reason, accepted_at) values
 ('authenticated_security_definer_function_executable:fabula.device_checkin(p_device_uid text, p_label text, p_version text, p_queue_len integer, p_oldest timestamp with time zone, p_failed jsonb, p_user_agent text)',
  'by design: tablet check-in (v0.74); staff only (my_staff_id), writes only its own device row and refused saves', now()),
 ('authenticated_security_definer_function_executable:fabula.resolve_tablet_reject(p_qid text, p_resolution text)',
  'by design: console (v0.74); require_perm(sistema, 2) inside', now()),
 ('authenticated_security_definer_function_executable:fabula.live_app_version()',
  'by design: returns the public app version string only', now())
on conflict (key) do nothing;
