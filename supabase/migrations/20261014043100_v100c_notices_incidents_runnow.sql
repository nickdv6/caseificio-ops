-- v1.00c · Audit 12/10/2026, alerts and operations (2/2): notices, bot incidents, «Esegui ora», refused saves.
--   E-03   Each notice has an audience: the floor tablet shows only the floor's (the evening HACCP list, lots shipped beyond the
--          recorded production, a lab result for an unknown lot); git, cron, security, bots, Incassi and trade notices stay in the
--          office (Console → Oggi «Avvisi aperti», Configurazione). The lot-guard items say the lot in Italian and can be scanned
--          (E-14); the trade-applications notice no longer carries the applicants' e-mail addresses.
--   E-33   One missed or failed bot = one incident (bot_alerts): one Telegram message when it opens, one line in the office notice
--          while it is open, closed by itself when the bot runs (or the database stands in, or the run finishes). The detection runs
--          from the database every hour (the old heartbeat now calls the watchdog), so it no longer depends on a Claude task; the
--          heartbeat's own second notice is gone. The evening check knows which missing bots were already reported.
--          A database job whose last run failed is one incident per job and day; an incident that cleared before it was sent is
--          never sent; the failed run's alarm closes with its incident. A closed alarm or notice stops its Telegram reminder, and
--          the reminder keeps the link. The feed keeps one open copy per notice.
--   E-21   «Esegui ora (versione del database)» for the bots the database can stand in for: run_bot_fallback(agent).
--          Autocontrollo lists the saves the database refused (tablet_rejects_list) and closes them with «Segna come rifatta»
--          (HACCP «registra» or Sistema «registra»).

-- ============================================================================================================================
-- 1. E-03 · who sees a notice
-- ============================================================================================================================
alter table fabula.notices add column if not exists audience text not null default 'office';
alter table fabula.notices drop constraint if exists notices_audience_check;
alter table fabula.notices add constraint notices_audience_check check (audience in ('floor', 'office'));
comment on column fabula.notices.audience is 'v1.00c (audit E-03): floor = shown on the floor tablet too; office = Console/Configurazione only';

create or replace function fabula.notice_audience(p_key text) returns text
language sql immutable set search_path = fabula, public as $$
  select case when coalesce(p_key, '') ~ '^(haccp_evening|lot_guard|lab_lot_unknown)' then 'floor' else 'office' end
$$;
create or replace function fabula.trg_notice_audience() returns trigger
language plpgsql set search_path = fabula, public as $$
begin new.audience := fabula.notice_audience(new.key); return new; end $$;
revoke all on function fabula.trg_notice_audience() from public, anon, authenticated;
drop trigger if exists notices_audience on fabula.notices;
create trigger notices_audience before insert or update of key on fabula.notices for each row execute function fabula.trg_notice_audience();
update fabula.notices set audience = fabula.notice_audience(key) where audience is distinct from fabula.notice_audience(key);

create or replace view fabula.v_active_notices with (security_invoker = true) as
select id, key, severity, title_it, items, created_at, expires_at, resolved_at, audience, fabula.notice_link(key) as link
  from fabula.notices
 where resolved_at is null and expires_at > now()
 order by case severity when 'alert' then 0 when 'warn' then 1 else 2 end, created_at desc;
grant select on fabula.v_active_notices to authenticated, service_role;

-- one open copy of a notice in the feed: the newest (a notice whose list changes every hour piled up one alarm per change)
do $mig$
declare d text := pg_get_functiondef('fabula.trg_notice_message'::regproc); n text;
begin
  n := replace(d, $o$  insert into fabula.bot_messages (agent, severity, title, body, source, notice_key)$o$,
                  $n$  update fabula.bot_messages set read_at = now(), resolved_at = case when severity = 'alert' then now() end,
         resolution = case when severity = 'alert' then 'sostituito dall''avviso aggiornato' end
   where notice_key = new.key and read_at is null;   -- v1.00c
  insert into fabula.bot_messages (agent, severity, title, body, source, notice_key)$n$);
  if n = d then raise exception 'v100c: trg_notice_message pattern not found'; end if;
  execute n;
end $mig$;
-- the copies already piled up: keep the newest open one per notice
update fabula.bot_messages b set read_at = now(), resolved_at = case when b.severity = 'alert' then now() end,
       resolution = case when b.severity = 'alert' then 'sostituito dall''avviso aggiornato' end
 where b.read_at is null and b.notice_key is not null
   and exists (select 1 from fabula.bot_messages x where x.notice_key = b.notice_key and x.read_at is null and x.id > b.id);

-- lot guard (E-14): the lot in Italian, and a scan to open it on the tablet
do $mig$
declare d text := pg_get_functiondef('fabula.trg_stock_move_guard'::regproc); n text;
begin
  n := replace(d, $o$jsonb_build_object('lot', v_orig, 'move', new.move_type, 'kg', v_need, 'on_hand', v_bal, 'at', now(), 'kept', true)$o$,
                  $n$jsonb_build_object('lot', v_orig, 'move', new.move_type, 'kg', v_need, 'on_hand', v_bal, 'at', now(), 'kept', true,
                        'label_it', format('Lotto %s: uscito %s kg, in giacenza %s kg: controlla il peso in uscita', v_orig, fabula._it_num(v_need), fabula._it_num(v_bal)),
                        'scan', 'LOT:' || v_orig)$n$);
  n := replace(n, $o$jsonb_build_object('lot', v_orig, 'move', new.move_type, 'kg', -v_orig_qty, 'on_hand', v_bal, 'alloc', v_alloc, 'at', now(), 'kept', false)$o$,
                  $n$jsonb_build_object('lot', v_orig, 'move', new.move_type, 'kg', -v_orig_qty, 'on_hand', v_bal, 'alloc', v_alloc, 'at', now(), 'kept', false,
                        'label_it', format('Lotto %s: richiesti %s kg, in giacenza %s kg: preso da altri lotti', v_orig, fabula._it_num(-v_orig_qty), fabula._it_num(v_bal)),
                        'scan', 'LOT:' || v_orig)$n$);
  if n = d or (length(n) - length(replace(n, '''label_it''', ''))) / length('''label_it''') <> 2 then raise exception 'v100c: lot guard patterns not found'; end if;
  execute n;
end $mig$;
update fabula.notices set items = (
         select jsonb_agg(case when x ? 'label_it' then x
                               else x || jsonb_build_object('label_it', case when (x->>'kept')::boolean is false
                                                                             then format('Lotto %s: richiesti %s kg, in giacenza %s kg: preso da altri lotti',
                                                                                         x->>'lot', fabula._it_num(abs((x->>'kg')::numeric)), fabula._it_num((x->>'on_hand')::numeric))
                                                                             else format('Lotto %s: uscito %s kg, in giacenza %s kg: controlla il peso in uscita',
                                                                                         x->>'lot', fabula._it_num((x->>'kg')::numeric), fabula._it_num((x->>'on_hand')::numeric)) end,
                                                            'scan', 'LOT:' || (x->>'lot')) end)
           from jsonb_array_elements(items) x)
 where key like 'lot_guard:%' and jsonb_typeof(items) = 'array' and jsonb_array_length(items) > 0;

-- trade applications: what to look at, without the applicants' e-mail (every profile can read notices)
create or replace function fabula.trade_notice_refresh() returns void
language plpgsql security definer set search_path = fabula, public as $$
declare it jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'business', business_name, 'type', business_type, 'city', city, 'kg_week', expected_kg_week, 'at', created_at,
                                               'label_it', concat_ws(' · ', business_name, nullif(business_type, ''), nullif(city, ''),
                                                                     case when expected_kg_week is not null then fabula._it_num(expected_kg_week) || ' kg/settimana' end))
                            order by created_at), '[]')
    into it from fabula.trade_applications where status = 'pending';
  insert into fabula.notices (key, severity, title_it, items, expires_at, resolved_at)
  values ('trade_applications', 'info', 'Richieste professionisti da valutare', it, now() + interval '30 days', case when jsonb_array_length(it) = 0 then now() end)
  on conflict (key) do update set items = excluded.items, expires_at = excluded.expires_at, resolved_at = excluded.resolved_at,
    created_at = case when fabula.notices.resolved_at is not null and excluded.resolved_at is null then now() else fabula.notices.created_at end;
end $$;
do $r$ begin perform fabula.trade_notice_refresh(); end $r$;

-- ============================================================================================================================
-- 2. E-33 · one incident per missed or failed bot
-- ============================================================================================================================
alter table fabula.bot_alerts add column if not exists label_it text,
                              add column if not exists last_seen_at timestamptz,
                              add column if not exists notified_at timestamptz,
                              add column if not exists resolved_at timestamptz,
                              add column if not exists resolved_how text;
comment on table fabula.bot_alerts is 'v1.00c (audit E-33): one row = one incident (agent, kind, ref = slot or run): opened once, notified once, closed when it clears';
-- what is already there: the past is closed, so the first run does not re-send yesterday
update fabula.bot_alerts set resolved_at = now(), resolved_how = 'prima della v1.00', notified_at = coalesce(notified_at, alerted_at)
 where resolved_at is null;

create or replace function fabula.bot_watchdog(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare v_ny timestamp := p_now at time zone 'Europe/Rome'; v_day date := (p_now at time zone 'Europe/Rome')::date;
        r record; a jsonb := '[]'::jsonb; v_due timestamptz; v_ref text; v_lbl text; v_last_cron timestamptz; v_open jsonb; n int;
begin
  -- ---- 1. open new incidents (one row per agent + kind + slot/run; the unique key keeps them single; a second pass only refreshes them) ----
  for r in select ar.id, ar.agent, ar.started_at, coalesce(nullif(ar.error, ''), nullif(ar.summary, ''), 'errore senza dettagli') err
             from fabula.agent_runs ar
            where ar.status = 'error' and ar.started_at > p_now - interval '26 hours' order by ar.started_at loop
    insert into fabula.bot_alerts (agent, kind, ref, detail, label_it, alerted_at, last_seen_at)
    values (r.agent, 'error', r.id::text, left(r.err, 300),
            format('%s: errore alle %s — %s', fabula.bot_title(r.agent), to_char(r.started_at at time zone 'Europe/Rome', 'HH24:MI'), left(r.err, 160)), p_now, p_now)
    on conflict (agent, kind, ref) do update set last_seen_at = p_now;
  end loop;
  for r in select bs.*, t.due from fabula.bot_schedule bs cross join unnest(bs.due_times) t(due)
            where bs.active and extract(isodow from v_day) = any (bs.weekdays) and (bs.month_day is null or extract(day from v_day) = bs.month_day)
              and v_day + t.due + make_interval(mins => bs.grace_min
                    + case when bs.agent = any (fabula.bot_fallback_agents()) and fabula.setting_num('bots.db_fallback', 1) = 1 then 20 else 0 end) <= v_ny loop
    v_due := (v_day + r.due) at time zone 'Europe/Rome';
    if not exists (select 1 from fabula.agent_runs ar where ar.agent = r.agent and ar.started_at >= v_due - interval '30 minutes'
                   and (ar.agent <> 'backup_export' or ar.details->>'mode' = 'nightly')) then   -- v0.79
      insert into fabula.bot_alerts (agent, kind, ref, label_it, alerted_at, last_seen_at)
      values (r.agent, 'missed', to_char(v_day + r.due, 'YYYY-MM-DD HH24:MI'),
              format('%s: non è partito (previsto alle %s)', fabula.bot_title(r.agent), to_char(r.due, 'HH24:MI')), p_now, p_now)
      on conflict (agent, kind, ref) do update set last_seen_at = p_now;
    end if;
  end loop;
  for r in select ar.id, ar.agent, ar.started_at from fabula.agent_runs ar
            where ar.finished_at is null and ar.status is distinct from 'error' and ar.started_at between p_now - interval '26 hours' and p_now - interval '30 minutes' loop
    insert into fabula.bot_alerts (agent, kind, ref, label_it, alerted_at, last_seen_at)
    values (r.agent, 'stuck', r.id::text, format('%s: partito alle %s e mai finito', fabula.bot_title(r.agent), to_char(r.started_at at time zone 'Europe/Rome', 'HH24:MI')), p_now, p_now)
    on conflict (agent, kind, ref) do update set last_seen_at = p_now;
  end loop;
  -- v0.74: the database scheduler itself — one incident per stoppage (the ref is the last run seen, the same until it runs again)
  select max(start_time) into v_last_cron from cron.job_run_details;
  if v_last_cron is null or v_last_cron < p_now - interval '20 minutes' then
    insert into fabula.bot_alerts (agent, kind, ref, detail, label_it, alerted_at, last_seen_at)
    values ('pg_cron', 'stuck', 'scheduler ' || coalesce(to_char(v_last_cron at time zone 'Europe/Rome', 'YYYY-MM-DD HH24:MI:SS'), 'mai'), 'pg_cron fermo',
            case when v_last_cron is null then 'Le automazioni del database non risultano mai partite'
                 else 'Le automazioni del database sono ferme dalle ' || to_char(v_last_cron at time zone 'Europe/Rome', 'DD/MM HH24:MI') end
            || ': backup, controlli e bot di riserva non girano. Apri Supabase → Integrations → Cron o scrivi al supporto Supabase.', p_now, p_now)
    on conflict (agent, kind, ref) do update set last_seen_at = p_now;
  end if;
  -- a database job whose LAST run failed: one incident per job and day (a job every minute that keeps failing is one message, not 60
  -- an hour; a failure already followed by a success is not news)
  for r in select distinct on (j.jobname) j.jobname, d.status, d.start_time, left(coalesce(d.return_message, ''), 200) msg
             from cron.job_run_details d join cron.job j on j.jobid = d.jobid
            where d.start_time > p_now - interval '26 hours' and d.start_time <= p_now and d.status in ('failed', 'succeeded')
            order by j.jobname, d.start_time desc loop
    continue when r.status <> 'failed';
    insert into fabula.bot_alerts (agent, kind, ref, detail, label_it, alerted_at, last_seen_at)
    values ('pg_cron', 'error', 'cron ' || r.jobname || ' ' || to_char(r.start_time at time zone 'Europe/Rome', 'YYYY-MM-DD'), r.jobname || ': ' || r.msg,
            format('Automazione del database «%s» non riuscita alle %s — %s', r.jobname, to_char(r.start_time at time zone 'Europe/Rome', 'HH24:MI'), coalesce(nullif(r.msg, ''), 'nessun dettaglio')),
            p_now, p_now)
    on conflict (agent, kind, ref) do update set last_seen_at = p_now, detail = excluded.detail,
      label_it = case when fabula.bot_alerts.notified_at is null then excluded.label_it else fabula.bot_alerts.label_it end,
      resolved_at = null, resolved_how = null;   -- failing again the same day: open again in the notice, no second Telegram
  end loop;

  -- ---- 2. close what has cleared ----
  -- missed: the bot ran after all, or the database stood in
  update fabula.bot_alerts ba set resolved_at = p_now,
         resolved_how = (select case when ar.details->>'via' = 'db_fallback' then 'sostituito dal database alle ' else 'partito alle ' end
                                || to_char(ar.started_at at time zone 'Europe/Rome', 'HH24:MI')
                           from fabula.agent_runs ar where ar.agent = ba.agent and ar.started_at >= ((ba.ref::timestamp) at time zone 'Europe/Rome') - interval '30 minutes'
                            and (ar.agent <> 'backup_export' or ar.details->>'mode' = 'nightly') order by ar.started_at limit 1)
   where ba.kind = 'missed' and ba.resolved_at is null and ba.ref ~ '^\d{4}-\d\d-\d\d \d\d:\d\d$'
     and exists (select 1 from fabula.agent_runs ar where ar.agent = ba.agent and ar.started_at >= ((ba.ref::timestamp) at time zone 'Europe/Rome') - interval '30 minutes'
                  and (ar.agent <> 'backup_export' or ar.details->>'mode' = 'nightly'));
  -- error: a later run of the same bot went well (the bot itself, or the database standing in)
  update fabula.bot_alerts ba set resolved_at = p_now,
         resolved_how = (select case when ok.details->>'via' = 'db_fallback' then 'sostituito dal database alle ' else 'poi riuscito alle ' end
                                || to_char(ok.started_at at time zone 'Europe/Rome', 'DD/MM HH24:MI')
                           from fabula.agent_runs e join fabula.agent_runs ok on ok.agent = e.agent and ok.started_at > e.started_at and ok.status = 'ok'
                          where e.id::text = ba.ref order by ok.started_at limit 1)
   where ba.kind = 'error' and ba.agent <> 'pg_cron' and ba.resolved_at is null
     and exists (select 1 from fabula.agent_runs e join fabula.agent_runs ok on ok.agent = e.agent and ok.started_at > e.started_at and ok.status = 'ok' where e.id::text = ba.ref);
  -- …and the failed run's own alarm in the feed closes with it (it was not closed by anyone: it cleared)
  update fabula.bot_messages m set read_at = p_now, resolved_at = p_now, resolution = 'rientrato da solo: ' || ba.resolved_how
    from fabula.bot_alerts ba
   where ba.kind = 'error' and ba.agent <> 'pg_cron' and ba.resolved_at = p_now and m.run_id::text = ba.ref and m.read_at is null;
  -- stuck: the run finished (or failed, which opens its own incident)
  update fabula.bot_alerts ba set resolved_at = p_now, resolved_how = 'finito'
   where ba.kind = 'stuck' and ba.agent <> 'pg_cron' and ba.resolved_at is null
     and exists (select 1 from fabula.agent_runs ar where ar.id::text = ba.ref and (ar.finished_at is not null or ar.status = 'error'));
  -- the scheduler runs again
  update fabula.bot_alerts set resolved_at = p_now, resolved_how = 'ripartite'
   where agent = 'pg_cron' and kind = 'stuck' and resolved_at is null and v_last_cron is not null and v_last_cron >= p_now - interval '20 minutes';
  -- a failed database job whose last run succeeded
  update fabula.bot_alerts ba set resolved_at = p_now, resolved_how = 'poi riuscita alle ' || to_char(lr.start_time at time zone 'Europe/Rome', 'HH24:MI')
    from (select distinct on (j.jobname) j.jobname, d.status, d.start_time from cron.job_run_details d join cron.job j on j.jobid = d.jobid
           where d.start_time <= p_now and d.status in ('failed', 'succeeded') order by j.jobname, d.start_time desc) lr
   where ba.agent = 'pg_cron' and ba.kind = 'error' and ba.resolved_at is null and lr.jobname = split_part(ba.detail, ':', 1) and lr.status = 'succeeded';
  -- anything older than a day is no longer news (a bot that is still down opens today's incident)
  update fabula.bot_alerts set resolved_at = p_now, resolved_how = 'più vecchio di un giorno'
   where resolved_at is null and alerted_at < p_now - interval '26 hours';

  -- ---- 3. one Telegram message per incident (E-33), with what to do: only what is still open and was never sent ----
  for r in select ba.* from fabula.bot_alerts ba where ba.notified_at is null and ba.resolved_at is null order by ba.alerted_at, ba.id loop
    a := a || jsonb_build_object('id', r.id, 'agent', r.agent,
                                 'name', case when r.agent = 'pg_cron' and r.kind = 'error' then split_part(r.detail, ':', 1)
                                              when r.agent = 'pg_cron' then 'Automazioni del database' else fabula.bot_title(r.agent) end,
                                 'kind', case when r.agent = 'pg_cron' and r.kind = 'stuck' then 'cron_stopped' when r.agent = 'pg_cron' then 'cron_failed' else r.kind end,
                                 'ref', r.ref, 'detail', r.detail, 'label_it', r.label_it);
    begin
      perform fabula.notify_enqueue('infra', left(r.label_it, 200),
        case when r.agent = any (fabula.bot_fallback_agents())
             then 'Il database lo fa da solo poco dopo l''orario; per farlo subito: Configurazione → Bot → «Esegui ora».'
             when r.agent = 'pg_cron' then null
             else 'Si rilancia dalle attività programmate di Claude. Se sono fermi tutti i bot: «Bot fermi: cosa fare» (Configurazione → Bot).' end,
        'Allarme bot', 'bot_alerts', r.id::text, 'inc:' || r.id, null, 'admin.html#bots');
    exception when others then raise warning 'bot_watchdog notify %: %', r.id, sqlerrm;
    end;
    update fabula.bot_alerts set notified_at = p_now where id = r.id;
  end loop;

  -- ---- 4. the office notice lists what is open now; it closes when nothing is ----
  select coalesce(jsonb_agg(jsonb_build_object('agent', agent, 'kind', kind, 'ref', ref, 'label_it', coalesce(label_it, agent || ': ' || kind)) order by alerted_at, id), '[]')
    into v_open from fabula.bot_alerts where resolved_at is null;
  n := jsonb_array_length(v_open);
  if n > 0 then
    insert into fabula.notices (key, severity, title_it, items, expires_at)
    values ('bot_alert', 'alert', case when n = 1 then '1 bot da controllare' else n || ' bot da controllare' end, v_open, p_now + interval '24 hours')
    on conflict (key) do update set severity = 'alert', title_it = excluded.title_it, items = excluded.items, expires_at = excluded.expires_at, resolved_at = null,
      created_at = case when fabula.notices.resolved_at is not null or fabula.notices.expires_at <= p_now then p_now else fabula.notices.created_at end
      where fabula.notices.items is distinct from excluded.items or fabula.notices.resolved_at is not null or fabula.notices.expires_at <= p_now + interval '12 hours';
  else
    update fabula.notices set resolved_at = p_now where key = 'bot_alert' and resolved_at is null;
  end if;
  update fabula.notices set resolved_at = p_now where key = 'bot_heartbeat' and resolved_at is null;   -- v1.00c: no second notice

  return jsonb_build_object('checked_at', p_now, 'alerts', a, 'open', v_open,
    'message_it', case when jsonb_array_length(a) > 0 then
      (select string_agg('• ' || (x->>'label_it'), E'\n') from jsonb_array_elements(a) x)
      || E'\n' || 'Orari italiani. Un bot che non è partito si rilancia dalle attività programmate (i bot di riserva: Configurazione → Bot → «Esegui ora»).' end);
end $$;

-- the hourly database job (pg_cron :25) now runs the full watchdog: detection no longer depends on a Claude task
create or replace function fabula.bot_heartbeat(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare w jsonb;
begin
  w := fabula.bot_watchdog(p_now);
  return jsonb_build_object('checked_at', p_now,
    'missed', coalesce((select jsonb_agg(x) from jsonb_array_elements(w->'open') x where x->>'kind' = 'missed'), '[]'::jsonb), 'watchdog', w);
end $$;

-- the evening check: which missing bots were already reported (the bot says it once, not again)
do $mig$
declare d text := pg_get_functiondef('fabula.ops_health_check'::regproc); n text;
begin
  n := replace(d, $o$'bots_missing', (select coalesce(jsonb_agg(b->>'agent'), '[]') from jsonb_array_elements(coalesce(bots,'[]')) b where not (b->>'ran')::boolean),$o$,
                  $n$'bots_missing', (select coalesce(jsonb_agg(b->>'agent'), '[]') from jsonb_array_elements(coalesce(bots,'[]')) b where not (b->>'ran')::boolean),
    'bots_missing_alerted', (select coalesce(jsonb_agg(distinct ba.agent), '[]') from fabula.bot_alerts ba
                              where ba.kind = 'missed' and ba.notified_at is not null and ba.ref like to_char(p_date, 'YYYY-MM-DD') || ' %'),   -- v1.00c (audit E-33)$n$);
  if n = d then raise exception 'v100c: ops_health_check pattern not found'; end if;
  execute n;
  d := pg_get_functiondef('fabula.bot_fallback_run'::regproc);
  n := replace(d, $o$'Bot non partiti oggi: ' || (select string_agg(fabula.bot_display_name(b #>> '{}'), ', ') from jsonb_array_elements(r->'bots_missing') b)$o$,
                  $n$'Bot non partiti oggi: ' || (select string_agg(fabula.bot_title(b #>> '{}') || case when r->'bots_missing_alerted' ? (b #>> '{}') then ' (già segnalato)' else '' end, ', ')
                                                from jsonb_array_elements(r->'bots_missing') b)$n$);
  if n = d then raise exception 'v100c: bot_fallback_run ops_health pattern not found'; end if;
  execute n;
end $mig$;

-- an alarm that closes (by «Risolto», by itself, when its request is decided, when its notice clears) stops its Telegram reminder:
-- the 30-minute «Nessuno se ne occupa» went out for requests already approved (review 14/10)
create or replace function fabula.trg_bot_message_closed() returns trigger
language plpgsql security definer set search_path = fabula, public as $$
begin
  if old.read_at is null and new.read_at is not null then
    update fabula.notify_outbox set acked_at = now(), acked_by_id = new.resolved_by_id
     where source = 'bot_messages' and source_ref = new.id::text and acked_at is null;
  end if;
  return null;
end $$;
revoke all on function fabula.trg_bot_message_closed() from public, anon, authenticated;
drop trigger if exists bot_messages_closed on fabula.bot_messages;
create trigger bot_messages_closed after update of read_at on fabula.bot_messages for each row execute function fabula.trg_bot_message_closed();
create or replace function fabula.trg_notice_closed() returns trigger
language plpgsql security definer set search_path = fabula, public as $$
begin
  if old.resolved_at is null and new.resolved_at is not null then
    update fabula.notify_outbox set acked_at = now() where source = 'notices' and source_ref = new.key and acked_at is null;
  end if;
  return null;
end $$;
revoke all on function fabula.trg_notice_closed() from public, anon, authenticated;
drop trigger if exists notices_closed on fabula.notices;
create trigger notices_closed after update of resolved_at on fabula.notices for each row execute function fabula.trg_notice_closed();
-- what is already closed and still waiting for its reminder
update fabula.notify_outbox o set acked_at = now()
 where o.acked_at is null and o.escalated_at is null
   and ((o.source = 'bot_messages' and exists (select 1 from fabula.bot_messages m where m.id::text = o.source_ref and m.read_at is not null))
     or (o.source = 'notices' and not exists (select 1 from fabula.notices x where x.key = o.source_ref and x.resolved_at is null)));
-- the reminder keeps the message's link (it opened the topic's page)
do $mig$
declare d text := pg_get_functiondef('fabula.notify_tick'::regproc); n text;
begin
  n := replace(d, $o$o.body, o.sender, o.source, o.source_ref, null, o.id);$o$,
                  $n$o.body, o.sender, o.source, o.source_ref, null, o.id,
                                  case o.source when 'bot_messages' then (select m.action_url from fabula.bot_messages m where m.id::text = o.source_ref)
                                                when 'notices' then fabula.notice_link(o.source_ref) when 'bot_alerts' then 'admin.html#bots' end);   -- v1.00c$n$);
  if n = d then raise exception 'v100c: notify_tick reminder pattern not found'; end if;
  execute n;
end $mig$;

-- ============================================================================================================================
-- 3. E-21 · «Esegui ora (versione del database)»
-- ============================================================================================================================
create or replace function fabula.run_bot_fallback(p_agent text, p_confirm boolean default false) returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare v_day date := (now() at time zone 'Europe/Rome')::date; v_who text; v_due timestamptz; v_last record; o jsonb; v_run uuid; v_msg bigint; v_err text; v_recent timestamptz;
begin
  perform fabula.require_perm('sistema', 2);
  if not (p_agent = any (fabula.bot_fallback_agents())) then
    raise exception using errcode = '22023', message = format('«%s» non ha una versione del database: si rilancia dalle attività programmate di Claude', fabula.bot_title(p_agent));
  end if;
  v_who := coalesce((select full_name from fabula.staff where id = fabula.my_staff_id()), 'sistema');
  -- the latest slot of today that has already come (for the record and so the automatic stand-in does not run it again)
  select (v_day + t.due) at time zone 'Europe/Rome' into v_due from fabula.bot_schedule bs cross join unnest(bs.due_times) t(due)
   where bs.agent = p_agent and bs.active and extract(isodow from v_day) = any (bs.weekdays) and (bs.month_day is null or extract(day from v_day) = bs.month_day)
     and v_day + t.due <= (now() at time zone 'Europe/Rome') order by t.due desc limit 1;
  select ar.started_at, ar.status, coalesce(ar.details->>'via', '') via into v_last from fabula.agent_runs ar
   where ar.agent = p_agent and ar.status = 'ok' and ar.started_at >= coalesce(v_due, (v_day::timestamp) at time zone 'Europe/Rome') - interval '30 minutes'
     and (ar.agent <> 'backup_export' or ar.details->>'mode' = 'nightly')          -- the 2-hourly «latest» backups are not the nightly one
   order by ar.started_at desc limit 1;
  -- started in the last 15 minutes and not logged yet (the backup logs its own run when it finishes): a second click asks too
  select max(ran_at) into v_recent from fabula.bot_fallback_runs where agent = p_agent and ran_at > now() - interval '15 minutes';
  if (v_last.started_at is not null or v_recent is not null) and not coalesce(p_confirm, false) then
    raise exception using errcode = '22023', hint = 'confirm',
      message = case when v_recent is not null and (v_last.started_at is null or v_recent > v_last.started_at)
                     then format('%s è stato avviato alle %s: rifarlo adesso?', fabula.bot_title(p_agent), to_char(v_recent at time zone 'Europe/Rome', 'HH24:MI'))
                     else format('%s ha già girato oggi alle %s%s: rifarlo adesso?', fabula.bot_title(p_agent), to_char(v_last.started_at at time zone 'Europe/Rome', 'HH24:MI'),
                                 case when v_last.via = 'db_fallback' then ' (versione del database)' else '' end) end;
  end if;
  begin
    o := fabula.bot_fallback_run(p_agent, v_day);
  exception when others then
    v_err := sqlerrm;               -- nothing is recorded: the person who pressed the button sees the error now
    raise exception using errcode = '22023', message = format('%s non riuscito: %s', fabula.bot_title(p_agent), left(v_err, 300));
  end;
  if p_agent <> 'backup_export' then        -- the backup logs its own run when it finishes
    insert into fabula.agent_runs (agent, started_at, finished_at, status, summary, details)
    values (p_agent, now(), clock_timestamp(), 'ok', format('Eseguito ora da %s (versione del database): %s', v_who, coalesce(o->>'summary', '')),
            jsonb_build_object('via', 'db_fallback', 'manual', true, 'by', v_who, 'due', v_due, 'result', o->'result'))
    returning id into v_run;
  end if;
  v_msg := fabula.post_bot_message(p_agent, coalesce(o->>'severity', 'info'), left('Eseguito ora · ' || coalesce(o->>'title', fabula.bot_title(p_agent)), 120),
             format(E'Eseguito ora da %s con la versione del database (i numeri del database, senza il commento del bot).\n\n%s', v_who, coalesce(o->>'body', '')), v_run);
  -- the ledger: today's slot (so the automatic stand-in does not run it again) or, before the first slot, this minute
  insert into fabula.bot_fallback_runs (agent, slot, status, summary, result) values (p_agent, coalesce(v_due, date_trunc('minute', now())), 'ok', o->>'summary', o->'result')
  on conflict (agent, slot) do update set status = 'ok', summary = excluded.summary, result = excluded.result, ran_at = now();
  perform fabula.bot_watchdog();            -- the incident (missed/failed) closes now
  return jsonb_build_object('agent', p_agent, 'title', o->>'title', 'summary', o->>'summary', 'severity', o->>'severity', 'message_id', v_msg);
end $$;
revoke all on function fabula.run_bot_fallback(text, boolean) from public, anon;
grant execute on function fabula.run_bot_fallback(text, boolean) to authenticated, service_role;

-- ============================================================================================================================
-- 4. E-21 · the saves the database refused, in Autocontrollo
-- ============================================================================================================================
create or replace function fabula.tablet_reject_what(p_what text) returns text
language sql immutable set search_path = fabula, public as $$
  select case p_what
    when 'log_ccp' then 'Misura CCP' when 'log_milk_check' then 'Controllo del latte' when 'haccp_log' then 'Registro HACCP'
    when 'close_open_task' then 'Attività segnata fatta' when 'milk_intake' then 'Arrivo del latte' when 'record_receipt_check' then 'Controllo merce in arrivo'
    when 'log_batch_step' then 'Passo di lavorazione' when 'effluent_log' then 'Scarichi' when 'meter_readings' then 'Lettura contatore'
    when 'stock_moves' then 'Movimento di magazzino' when 'production_batches' then 'Lotto' when 'batch_milk_inputs' then 'Latte nel lotto'
    when 'labels' then 'Etichetta' when 'shipments' then 'Spedizione' when 'shipment_lines' then 'Riga di spedizione' when 'scan_events' then 'Scansione'
    when 'purchase_orders' then 'Ordine d''acquisto' when 'receive_purchase_order' then 'Ricevimento merce' when 'record_batch_consumable' then 'Dosaggio'
    when 'start_byproduct_batch' then 'Avvio ricotta' when 'correct_batch_milk' then 'Correzione kg di latte'
    else 'Registrazione' end
$$;

-- the main values of a refused save, in one line (the field names the tablet uses, never the whole JSON)
create or replace function fabula.tablet_reject_values(p_ops jsonb) returns text
language sql immutable set search_path = fabula, public as $$
  select left(string_agg(format('%s: %s', regexp_replace(e.key, '^p_', ''), e.value #>> '{}'), ' · ' order by e.key), 240)
    from (select coalesce(o->'args', o->'row') v from jsonb_array_elements(case when jsonb_typeof(p_ops) = 'array' then p_ops else '[]'::jsonb end) o
           where coalesce(o->>'table', '') <> 'scan_events' limit 1) f,
         lateral jsonb_each(case when jsonb_typeof(f.v) = 'object' then f.v else '{}'::jsonb end) e
   where jsonb_typeof(e.value) in ('string', 'number', 'boolean')
     and e.key !~ '(_id$|^id$|staff|device|source|^p_day$|uid|token)'
$$;

create or replace function fabula.tablet_rejects_list(p_days int default 30)
returns table (qid text, what text, values_it text, error text, device text, staff text, failed_at timestamptz, reported_at timestamptz,
               resolved_at timestamptz, resolved_by text, resolution text, haccp boolean)
language plpgsql stable security definer set search_path = fabula, public as $$
begin
  if not (fabula.can('haccp', 1) or fabula.can('sistema', 1)) then
    raise exception using errcode = '42501', message = 'Il tuo profilo non vede le registrazioni rifiutate (serve Autocontrollo o Sistema)';
  end if;
  return query
  select t.qid, fabula.tablet_reject_what(t.what), fabula.tablet_reject_values(t.ops), t.error, t.device_label,
         (select s.full_name from fabula.staff s where s.id = t.staff_id), t.failed_at, t.reported_at, t.resolved_at, t.resolved_by, t.resolution,
         coalesce(t.what, '') ~ '^(log_ccp|log_milk_check|haccp_log|close_open_task|milk_intake|record_receipt_check|log_batch_step|effluent_log)$'
    from fabula.tablet_rejects t
   where t.resolved_at is null or t.resolved_at > now() - make_interval(days => greatest(coalesce(p_days, 30), 1))
   order by (t.resolved_at is null) desc, coalesce(t.failed_at, t.reported_at) desc
   limit 200;
end $$;
revoke all on function fabula.tablet_rejects_list(int) from public, anon;
grant execute on function fabula.tablet_rejects_list(int) to authenticated, service_role;

-- «Segna come rifatta»: the HACCP responsible can do it too, always with what was done
create or replace function fabula.resolve_tablet_reject(p_qid text, p_resolution text default null) returns boolean
language plpgsql security definer set search_path = fabula, public as $$
declare v_dev text;
begin
  if not (fabula.can('haccp', 2) or fabula.can('sistema', 2)) then
    raise exception using errcode = '42501', message = 'Il tuo profilo non può chiudere le registrazioni rifiutate (serve «registra» in Autocontrollo o in Sistema)';
  end if;
  if length(coalesce(trim(p_resolution), '')) < 3 then
    raise exception using errcode = '22023', message = 'Scrivi cosa è stato fatto (es. «rifatta dal tablet alle 10:40», «dato sbagliato, non serve»)';
  end if;
  update fabula.tablet_rejects set resolved_at = now(), resolution = left(trim(p_resolution), 300),
         resolved_by = coalesce((select full_name from fabula.staff where id = fabula.my_staff_id()), 'sistema')
   where qid = p_qid and resolved_at is null
  returning device_label into v_dev;
  if not found then return false; end if;
  -- nothing left to redo for that tablet: its «registrazioni rifiutate» alarm closes too (it kept escalating; review 14/10)
  if not exists (select 1 from fabula.tablet_rejects where resolved_at is null and device_label is not distinct from v_dev) then
    update fabula.bot_messages set read_at = now(), resolved_at = now(), resolved_by_id = fabula.my_staff_id(),
           resolution = 'registrazioni rifiutate rifatte o chiuse in Autocontrollo'
     where read_at is null and notice_key is null and agent in ('sicurezza', 'tablet') and title ~* 'rifiutat'
       and (v_dev is null or position('(' || v_dev || ')' in title) > 0);
  end if;
  return true;
end $$;

-- the refused-saves message names the record in Italian (it listed «haccp_log», «log_ccp»)
do $mig$
declare d text := pg_get_functiondef('fabula.device_checkin'::regproc); n text;
begin
  n := replace(d, $o$string_agg('• ' || (x->>'what') || ': '$o$, $n$string_agg('• ' || fabula.tablet_reject_what(x->>'what') || ': '$n$);
  if n = d then raise exception 'v100c: device_checkin list pattern not found'; end if;
  execute n;
end $mig$;

-- the tablet's waiting-records message printed «delle 00:06 4el 14/10» («d» is the weekday in to_char)
do $mig$
declare d text := pg_get_functiondef('fabula.device_watch'::regproc); n text;
begin
  n := replace(d, $o$'HH24:MI del DD/MM'$o$, $n$'HH24:MI "del" DD/MM'$n$);
  if n = d then raise exception 'v100c: device_watch date pattern not found'; end if;
  execute n;
end $mig$;

-- ============================================================================================================================
-- 5. Security check
-- ============================================================================================================================
insert into fabula.security_accepted (key, reason, accepted_at) values
 ('authenticated_security_definer_function_executable:fabula.run_bot_fallback(p_agent text, p_confirm boolean)',
  'by design (v1.00c, audit E-21): require_perm(sistema, 2) first; only the database stand-ins of bot_fallback_agents(); asks before a second run', now()),
 ('authenticated_security_definer_function_executable:fabula.tablet_rejects_list(p_days integer)',
  'by design (v1.00c, audit E-21): read-only; can(haccp, 1) or can(sistema, 1) first; values summarised, never the whole record', now())
on conflict (key) do update set reason = excluded.reason, accepted_at = excluded.accepted_at;
