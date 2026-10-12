-- v0.87a — bot notifications readable at a glance (12/10/2026)
-- 1. Run messages are written when a run FINISHES (not when it starts): no more "backup latest in corso" x9/day.
--    Routine 2-hourly backups stay silent; the nightly backup posts one plain line; failures stay alerts.
-- 2. Infrastructure drift notices in Italian with the action, instead of raw English check details.
-- 3. Watchdog / heartbeat wording: correct plurals, "ora italiana" instead of "(it.)", one action line.
-- 4. Auto-read: notice messages whose banner has expired or been resolved no longer count as unread.
-- 5. One-off clean-up: the old "in corso" backup messages and the expired banners are marked read.

-- 1 ------------------------------------------------------------------------------------------
create or replace function fabula.trg_agent_run_message()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'fabula', 'public'
as $function$
declare v_id bigint; v_title text; v_body text; v_err text;
begin
  -- only finished runs and errors make a message (v0.87)
  if new.finished_at is null and new.status is distinct from 'error' then return new; end if;
  if tg_op = 'UPDATE' and old.finished_at is not null and old.status is not distinct from new.status then return new; end if;
  -- routine daytime backups ('latest' every 2 h) are not news; the nightly one and any failure are
  if new.agent = 'backup_export' and new.status = 'ok' and coalesce(new.details->>'mode', '') <> 'nightly' then return new; end if;

  v_err := coalesce(nullif(new.error, ''), nullif(new.summary, ''), 'errore senza dettagli');

  -- already linked to a message (e.g. started earlier, or the bot posted already): only escalate on error
  select id into v_id from fabula.bot_messages where run_id = new.id order by created_at desc limit 1;
  if v_id is not null then
    if new.status = 'error' then update fabula.bot_messages set severity = 'alert', read_at = null, read_by = null where id = v_id; end if;
    return new;
  end if;

  select id into v_id from fabula.bot_messages where agent = new.agent and source = 'bot' and created_at > now() - interval '15 minutes'
   order by created_at desc limit 1;
  if v_id is not null then
    update fabula.bot_messages set run_id = coalesce(run_id, new.id),
           severity = case when new.status = 'error' then 'alert' else severity end where id = v_id;
    return new;
  end if;

  if new.status = 'error' then
    v_title := fabula.bot_display_name(new.agent) || ': non riuscito';
    v_body  := 'Errore: ' || left(v_err, 400) || E'\n' || 'Il bot riproverà al prossimo orario. Dettagli: Configurazione → Bot.';
  elsif new.agent = 'backup_export' then
    v_title := 'Backup di stanotte fatto';
    v_body  := 'Copia completa del database salvata'
               || coalesce(' (' || substring(new.summary from '(\d+ tabelle, \d+ righe)') || ')', '') || '.';
  else
    v_title := fabula.bot_display_name(new.agent);
    v_body  := coalesce(nullif(new.summary, ''), 'Eseguito');
  end if;

  insert into fabula.bot_messages (agent, run_id, severity, title, body, source)
  values (new.agent, new.id, case when new.status = 'error' then 'alert' else 'info' end, v_title, v_body, 'auto');
  return new;
end $function$;

drop trigger if exists agent_runs_message on fabula.agent_runs;
create trigger agent_runs_message after insert or update of finished_at, status on fabula.agent_runs
  for each row execute function fabula.trg_agent_run_message();

-- 2 ------------------------------------------------------------------------------------------
create or replace function fabula.trg_notice_message()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'fabula', 'public'
as $function$
declare v_body text; v_agent text; v_title text := new.title_it;
begin
  if tg_op = 'UPDATE' and new.items is not distinct from old.items and new.title_it is not distinct from old.title_it then return new; end if;
  if new.key = 'infra_drift' then
    -- v0.87: say what to do, in Italian, instead of the raw English check detail
    v_title := 'Modifiche da salvare su GitHub o da pubblicare (da più di 6 ore)';
    select string_agg(distinct '• ' || case x->>'code'
             when 'code_pushed'  then 'Modifiche al database non ancora salvate su GitHub: fai «git push» dal Mac'
             when 'repo_sync'    then 'GitHub e database non coincidono: fai «git push» dal Mac'
             when 'app_deployed' then 'Il tablet non ha l''ultima versione dell''app: controlla il deploy su Netlify'
             else coalesce(x->>'label_it', x->>'code') end, E'\n')
      into v_body from jsonb_array_elements(case when jsonb_typeof(new.items) = 'array' then new.items else '[]'::jsonb end) x;
  else
    select string_agg('• ' || coalesce(x->>'label_it', x->>'text', x->>'title', x->>'name' || coalesce(' · ' || (x->>'detail'), ''), x #>> '{}'), E'\n')
      into v_body from jsonb_array_elements(case when jsonb_typeof(new.items) = 'array' then new.items else '[]'::jsonb end) x;
  end if;
  v_agent := case when new.key = 'bot_alert' then 'bot_watchdog' when new.key = 'bot_heartbeat' then 'bot_heartbeat'
                  when new.key like 'haccp_evening%' then 'haccp_nudge' else 'avvisi' end;
  insert into fabula.bot_messages (agent, severity, title, body, source, notice_key)
  values (v_agent, case when new.severity in ('info','warn','alert') then new.severity else 'warn' end, v_title, v_body, 'notice', new.key);
  return new;
end $function$;

-- 3 ------------------------------------------------------------------------------------------
create or replace function fabula.bot_heartbeat(p_now timestamp with time zone default now())
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'fabula', 'public'
as $function$
declare v_local timestamp := p_now at time zone 'Europe/Rome'; v_day date := (p_now at time zone 'Europe/Rome')::date; r record; a jsonb := '[]'::jsonb; n int;
begin
  for r in select bs.agent, bs.name_it, t.due from fabula.bot_schedule bs cross join unnest(bs.due_times) t(due)
           where bs.active and extract(isodow from v_day) = any (bs.weekdays) and (bs.month_day is null or extract(day from v_day) = bs.month_day)
             and v_day + t.due + make_interval(mins => bs.grace_min + 60) <= v_local loop
    if not exists (select 1 from fabula.agent_runs ar where ar.agent = r.agent
                   and ar.started_at >= ((v_day + r.due) at time zone 'Europe/Rome') - interval '30 minutes') then
      a := a || jsonb_build_object('agent', r.agent, 'name', fabula.bot_display_name(r.agent), 'due', to_char(r.due, 'HH24:MI'),
                                   'label_it', fabula.bot_display_name(r.agent) || ': non è partito (previsto alle ' || to_char(r.due, 'HH24:MI') || ')');
    end if;
  end loop;
  n := jsonb_array_length(a);
  if n > 0 then
    insert into fabula.notices (key, severity, title_it, items, expires_at)
    values ('bot_heartbeat', 'alert',
            case when n = 1 then '1 bot non è partito oggi' else n || ' bot non sono partiti oggi' end
              || ': controlla le attività programmate e i collegamenti a Supabase/Shopify', a, p_now + interval '12 hours')
    on conflict (key) do update set severity = 'alert', title_it = excluded.title_it, items = excluded.items, created_at = p_now, expires_at = excluded.expires_at, resolved_at = null;
  else
    update fabula.notices set resolved_at = p_now where key = 'bot_heartbeat' and resolved_at is null;
  end if;
  return jsonb_build_object('checked_at', p_now, 'missed', a);
end $function$;

create or replace function fabula.bot_watchdog(p_now timestamp with time zone default now())
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'fabula', 'public'
as $function$
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
    insert into fabula.bot_alerts (agent, kind, ref, detail) values ('pg_cron', 'stuck', 'scheduler ' || to_char(p_now at time zone 'Europe/Rome', 'YYYY-MM-DD HH24'), 'pg_cron fermo') on conflict do nothing;
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
    -- v0.87: plain wording, Italian time said once, every item carries label_it for the dashboard
    select jsonb_agg(x || jsonb_build_object('label_it', case x->>'kind'
             when 'error' then format('%s: errore alle %s — %s', x->>'name', to_char((x->>'at')::timestamptz at time zone 'Europe/Rome', 'HH24:MI'), x->>'detail')
             when 'missed' then format('%s: non è partito (previsto alle %s)', x->>'name', x->>'due_rome')
             when 'cron_stopped' then format('Le automazioni del database sono ferme dalle %s: backup, controlli e bot di riserva non girano. Apri Supabase → Integrations → Cron o scrivi al supporto Supabase.',
                                             coalesce(to_char((x->>'at')::timestamptz at time zone 'Europe/Rome', 'DD/MM HH24:MI'), 'sempre'))
             when 'cron_failed' then format('Automazione del database «%s» non riuscita alle %s — %s', x->>'name', to_char((x->>'at')::timestamptz at time zone 'Europe/Rome', 'HH24:MI'), coalesce(nullif(x->>'detail', ''), 'nessun dettaglio'))
             else format('%s: partito alle %s e mai finito', x->>'name', to_char((x->>'at')::timestamptz at time zone 'Europe/Rome', 'HH24:MI')) end))
      into a from jsonb_array_elements(a) x;
    select string_agg('• ' || (x->>'label_it'), E'\n') into v_msg from jsonb_array_elements(a) x;
    v_msg := v_msg || E'\n' || 'Orari italiani. Un bot che non è partito si rilancia dalle attività programmate; dettagli in Configurazione → Bot.';
    insert into fabula.notices (key, severity, title_it, items, expires_at)
    values ('bot_alert', 'alert',
            case when jsonb_array_length(a) = 1 then '1 bot da controllare' else jsonb_array_length(a) || ' bot da controllare' end,
            a, p_now + interval '24 hours')
    on conflict (key) do update set severity = 'alert', title_it = excluded.title_it, items = excluded.items, created_at = p_now, expires_at = excluded.expires_at, resolved_at = null;
  end if;
  return jsonb_build_object('checked_at', p_now, 'alerts', a, 'message_it', v_msg);
end $function$;

-- 4 ------------------------------------------------------------------------------------------
create or replace function fabula.bot_messages_autoread(p_now timestamp with time zone default now())
 returns integer
 language plpgsql
 security definer
 set search_path to 'fabula', 'public'
as $function$
declare n int; m int;
begin
  update fabula.bot_messages set read_at = p_now
   where read_at is null and severity = 'info' and created_at < p_now - interval '24 hours';
  get diagnostics n = row_count;
  -- v0.87: a banner that has expired or been resolved is no longer news
  update fabula.bot_messages b set read_at = p_now
   where b.read_at is null and b.source = 'notice' and b.notice_key is not null
     and not exists (select 1 from fabula.notices x where x.key = b.notice_key and x.resolved_at is null and (x.expires_at is null or x.expires_at > p_now));
  get diagnostics m = row_count;
  return n + m;
end $function$;

-- 5 ------------------------------------------------------------------------------------------
update fabula.bot_messages set read_at = now()
 where read_at is null and agent = 'backup_export' and source = 'auto' and body ~ '^backup (latest|nightly) in corso$';
select fabula.bot_messages_autoread();
