-- v1.02b · Audit 12/10/2026, E-07: one morning summary on Telegram; at night only food safety and «system down» wake anyone.
--   * Each person linked to Telegram can choose a time for the daily summary («Riepilogo», Configurazione → Utenti → Avvisi
--     Telegram), in their own time zone: decisions waiting (with when they approve by themselves), open alarms, what is new since
--     the last summary, what was approved automatically, the morning brief. Nick: 07:30 New York time (13:30 in Agropoli), with
--     quiet hours 22:00–07:30 New York — set here only if his settings are still the defaults.
--   * System alarms (a bot that did not start, a backup, a database job) now wait for the end of the quiet hours like the
--     decisions; only «system down» (the site or the server not answering, the database scheduler stopped) is sent at once.
--     Food safety: unchanged, any hour, also to the HACCP responsible and whoever is clocked in.
--   * The routine decisions with a deadline the same day — milk plan, promo, wholesale forwarding (setting notify.decision_agents)
--     — reach Telegram as «Da decidere» even when they are not alarms (until now only alarms left the app), without the
--     30-minute reminder, and say when they approve by themselves (E-10). The bots stop pushing through the Claude app (prompts).

alter table fabula.notify_targets add column if not exists digest_at time;
alter table fabula.notify_targets add column if not exists digest_last date;
alter table fabula.notify_outbox add column if not exists urgent boolean not null default false;
alter table fabula.notify_outbox drop constraint if exists notify_outbox_topic_check;
alter table fabula.notify_outbox add constraint notify_outbox_topic_check check (topic in ('food_safety', 'infra', 'decisions', 'test', 'digest'));

insert into fabula.settings (key, value, description, data_type, sort) values
  ('notify.decision_agents', 'milk_planning,sell_down,wholesale_orders',
   'Bot i cui avvisi (non solo gli allarmi) arrivano su Telegram come «Da decidere»: decisioni con scadenza in giornata', 'text', 100)
on conflict (key) do nothing;

-- Nick reads from North Carolina: silence 22:00–07:30 New York time (only if nobody changed the defaults), and in any case the
-- summary at 07:30 his time — the bots no longer push through the Claude app, the summary is how routine news reaches him
update fabula.notify_targets t set tz = 'America/New_York', quiet_from = '22:00', quiet_to = '07:30', updated_at = now()
  from fabula.staff s
 where s.id = t.staff_id and s.app_role = 'titolare' and t.tz = 'Europe/Rome' and t.quiet_from = '22:00' and t.quiet_to = '07:00';
update fabula.notify_targets t set digest_at = '07:30', updated_at = now()
  from fabula.staff s
 where s.id = t.staff_id and s.app_role = 'titolare' and t.digest_at is null;

-- ============================================================================================================================
-- 1. Urgent or not: food safety always; «system down» (site/server not answering, database scheduler stopped) for the system
-- ============================================================================================================================
drop function if exists fabula.notify_enqueue(text, text, text, text, text, text, text, uuid, text);
create function fabula.notify_enqueue(p_topic text, p_title text, p_body text, p_sender text, p_source text default null, p_ref text default null,
                                      p_dedupe text default null, p_parent uuid default null, p_link text default null, p_urgent boolean default null) returns uuid
language plpgsql security definer set search_path = fabula, public as $$
declare v_id uuid; v_min int := greatest(coalesce(fabula.setting_num('notify.escalate_min', 30), 30)::int, 5);
        v_urgent boolean := coalesce(p_urgent, p_topic = 'food_safety' or (p_topic = 'infra' and coalesce(p_ref, '') ~ '^infra_uptime'));
begin
  if p_dedupe is not null and exists (select 1 from fabula.notify_outbox where dedupe_key = p_dedupe and created_at > now() - interval '3 hours') then
    return null;
  end if;
  insert into fabula.notify_outbox (topic, title, body, sender, source, source_ref, dedupe_key, text_html, parent_id, escalate_at, urgent)
  values (p_topic, left(coalesce(nullif(p_title, ''), 'Avviso'), 200), p_body, p_sender, p_source, p_ref, p_dedupe,
          fabula.notify_html(p_topic, coalesce(nullif(p_title, ''), 'Avviso'), p_body, p_sender, now(), p_link), p_parent,
          case when p_parent is null and p_topic in ('food_safety', 'decisions') then now() + make_interval(mins => v_min) end,
          coalesce((select o.urgent from fabula.notify_outbox o where o.id = p_parent), v_urgent))
  returning id into v_id;
  perform fabula.notify_route(v_id, p_parent is not null);
  return v_id;
end $$;
revoke all on function fabula.notify_enqueue(text, text, text, text, text, text, text, uuid, text, boolean) from public, anon, authenticated;
grant execute on function fabula.notify_enqueue(text, text, text, text, text, text, text, uuid, text, boolean) to service_role;

create or replace function fabula.notify_route(p_outbox uuid, p_wide boolean default false)
returns int language plpgsql security definer set search_path = fabula, public as $$
declare o fabula.notify_outbox%rowtype; v_resp text := fabula.setting_text('food.responsabile_autocontrollo'); n int;
begin
  select * into o from fabula.notify_outbox where id = p_outbox;
  if o.id is null or o.topic in ('test', 'digest') then return 0; end if;
  insert into fabula.notify_deliveries (outbox_id, staff_id, chat_id, due_at)
  select o.id, t.staff_id, t.chat_id,
         -- v1.02b (E-07): only what is urgent goes out during the quiet hours; the rest waits for their end
         case when o.urgent then now() else fabula.notify_due(t.tz, t.quiet_from, t.quiet_to) end
    from fabula.notify_targets t join fabula.staff s on s.id = t.staff_id
   where t.active and s.active and t.chat_id is not null
     and (o.topic = any (t.topics)
          or (o.topic = 'food_safety' and (s.full_name = v_resp
                                           or exists (select 1 from fabula.shifts sh where sh.staff_id = s.id and sh.clock_out is null)))
          or (p_wide and o.topic in ('food_safety', 'decisions') and (s.app_role in ('titolare', 'socio') or s.full_name = v_resp)))
  on conflict (outbox_id, staff_id) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- the database scheduler stopped is «system down»: it wakes Nick (a bot that did not start waits for the morning)
do $mig$
declare d text := pg_get_functiondef('fabula.bot_watchdog'::regproc); n text;
begin
  n := replace(d, $o$'Allarme bot', 'bot_alerts', r.id::text, 'inc:' || r.id, null, 'admin.html#bots');$o$,
                  $n$'Allarme bot', 'bot_alerts', r.id::text, 'inc:' || r.id, null, 'admin.html#bots', r.agent = 'pg_cron' and r.kind = 'stuck');$n$);
  if n = d then raise exception 'v102b: bot_watchdog notify pattern not found'; end if;
  execute n;
end $mig$;

-- an incident that cleared while its Telegram waited for the end of the silence is not sent late (notify_claim skips what is acked)
create or replace function fabula.trg_bot_alert_closed() returns trigger
language plpgsql security definer set search_path = fabula, public as $$
begin
  if new.resolved_at is not null and old.resolved_at is null then
    update fabula.notify_outbox set acked_at = now() where source = 'bot_alerts' and source_ref = new.id::text and acked_at is null;
  end if;
  return null;
end $$;
revoke all on function fabula.trg_bot_alert_closed() from public, anon, authenticated;
drop trigger if exists bot_alerts_closed on fabula.bot_alerts;
create trigger bot_alerts_closed after update of resolved_at on fabula.bot_alerts for each row execute function fabula.trg_bot_alert_closed();

-- ============================================================================================================================
-- 2. Which feed messages reach Telegram: alarms (as before) and the routine decisions due the same day (E-07, E-10)
-- ============================================================================================================================
create or replace function fabula.trg_notify_bot_message() returns trigger
language plpgsql security definer set search_path = fabula, public as $$
declare v_dec boolean; v_topic text; v_body text; v_auto text; v_id uuid;
begin
  if new.title like 'SIMULAZIONE%' or new.notice_key is not null or new.read_at is not null then return null; end if;   -- a notice's copy: sent by notices_notify
  v_dec := new.severity = 'warn'
           and new.agent = any (string_to_array(replace(coalesce(fabula.setting_text('notify.decision_agents'), ''), ' ', ''), ','));
  if new.severity <> 'alert' and not v_dec then return null; end if;
  if tg_op = 'UPDATE' and old.severity = new.severity and old.title is not distinct from new.title and old.body is not distinct from new.body then return null; end if;
  -- a failed bot run: the watchdog sends one Telegram per incident (E-33), not this alarm as well
  if new.run_id is not null and exists (select 1 from fabula.agent_runs ar where ar.id = new.run_id and ar.status = 'error') then return null; end if;
  begin
    v_topic := case when new.severity = 'alert' then fabula.notify_topic_for(new.agent, new.title || ' ' || coalesce(new.body, '')) else 'decisions' end;
    -- E-10: say when the request approves itself if nobody decides
    select 'Se nessuno decide, si approva da sola alle ' || to_char(a.auto_approve_at at time zone 'Europe/Rome', 'HH24:MI') || ' (ora italiana).'
      into v_auto from fabula.approvals a where a.id = new.approval_id and a.status = 'pending' and a.auto_approve_at > now()
       and coalesce(new.title, '') || ' ' || coalesce(new.body, '') !~* 'si approva da sol';   -- the bot already said it
    v_body := concat_ws(E'\n\n', nullif(new.body, ''), v_auto);
    v_id := fabula.notify_enqueue(v_topic, new.title, v_body, fabula.bot_display_name(new.agent), 'bot_messages', new.id::text,
                                  'bm:' || new.agent || ':' || md5(new.title), null, new.action_url);
    if v_dec and new.severity <> 'alert' and v_id is not null then
      update fabula.notify_outbox set escalate_at = null where id = v_id;   -- a routine decision: no «nessuno se ne occupa» reminder
    end if;
  exception when others then raise warning 'notify (bot_messages %): %', new.id, sqlerrm;
  end;
  return null;
end $$;

-- ============================================================================================================================
-- 3. The daily summary
-- ============================================================================================================================
create or replace function fabula.tg_esc(p text) returns text
language sql immutable set search_path = fabula, public as $$
  select replace(replace(replace(coalesce(p, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;')
$$;

-- a person's level in an area (the same table the app's rules use), for jobs that run without a login
create or replace function fabula.staff_level(p_staff uuid, p_area text) returns int
language sql stable security definer set search_path = fabula, public as $$
  select coalesce((select rp.level from fabula.staff s join fabula.role_permissions rp on rp.role_code = s.app_role and rp.area = p_area
                    where s.id = p_staff and s.active limit 1), 0)
$$;
revoke all on function fabula.staff_level(uuid, text) from public, anon, authenticated;

create or replace function fabula.notify_digest_text(p_staff uuid, p_since timestamptz, p_now timestamptz default now()) returns text
language plpgsql stable security definer set search_path = fabula, public as $$
declare v_site text := rtrim(coalesce(nullif(fabula.setting_text('infra.site_url'), ''), ''), '/');
        v_tz text := coalesce((select tz from fabula.notify_targets where staff_id = p_staff), 'Europe/Rome');
        t text[] := '{}'; n int; x record; v_any boolean := false;
        v_sys int := fabula.staff_level(p_staff, 'sistema');   -- approvals: «gestisce» in Sistema (3); messages and bots: «vede» (1), as in the app
begin
  t := t || ('📋 <b>Riepilogo</b> · ' || fabula.it_day((p_now at time zone v_tz)::date)
             || case when v_tz <> 'Europe/Rome' then ' · orari di ' || replace(split_part(v_tz, '/', 2), '_', ' ') else '' end);
  -- decisions waiting, the most urgent first
  select count(*) into n from fabula.approvals where status = 'pending' and v_sys >= 3;
  if n > 0 then
    v_any := true;
    t := t || ''::text || ('<b>Da decidere</b> (' || n || ')');
    for x in select a.summary, a.expires_at, a.auto_approve_at from fabula.approvals a where a.status = 'pending'
              order by coalesce(a.auto_approve_at, a.expires_at, a.requested_at + interval '30 days'), a.requested_at limit 4 loop
      t := t || ('• ' || fabula.tg_esc(left(x.summary, 110))
                 || case when x.auto_approve_at > p_now then ' · si approva da sola alle ' || to_char(x.auto_approve_at at time zone v_tz, 'HH24:MI')
                         when x.expires_at is not null then ' · entro ' || to_char(x.expires_at at time zone v_tz, 'DD/MM HH24:MI') else '' end);
    end loop;
    if n > 4 then t := t || ('… e altre ' || (n - 4)); end if;
  end if;
  -- alarms still open (they close when someone marks them «Risolto» or by themselves)
  select count(*) into n from fabula.bot_messages m where m.severity = 'alert' and m.read_at is null and m.title not like 'SIMULAZIONE%'
     and coalesce(m.notice_key, '') <> 'bot_alert' and v_sys >= 1;                       -- the bots that stopped have their own line below
  if n > 0 then
    v_any := true;
    t := t || ''::text || ('<b>Allarmi aperti</b> (' || n || ')');
    for x in select m.title from fabula.bot_messages m where m.severity = 'alert' and m.read_at is null and m.title not like 'SIMULAZIONE%'
                and coalesce(m.notice_key, '') <> 'bot_alert'
              order by m.created_at desc limit 3 loop
      t := t || ('• ' || fabula.tg_esc(left(x.title, 110)));
    end loop;
    if n > 3 then t := t || ('… e altri ' || (n - 3)); end if;
  end if;
  -- new since the last summary: warnings still open
  select count(distinct m.title) into n from fabula.bot_messages m
   where m.severity = 'warn' and m.read_at is null and m.created_at >= p_since and m.title not like 'SIMULAZIONE%' and v_sys >= 1
     and not (v_sys >= 3 and exists (select 1 from fabula.approvals a where a.id = m.approval_id and a.status = 'pending'));   -- already under «Da decidere»
  if n > 0 then
    v_any := true;
    t := t || ''::text || ('<b>Da sapere</b> (' || n || ')');
    for x in select m.title, max(m.created_at) as last_at from fabula.bot_messages m
              where m.severity = 'warn' and m.read_at is null and m.created_at >= p_since and m.title not like 'SIMULAZIONE%'
                and not (v_sys >= 3 and exists (select 1 from fabula.approvals a where a.id = m.approval_id and a.status = 'pending'))
              group by m.title order by max(m.created_at) desc limit 5 loop
      t := t || ('• ' || fabula.tg_esc(left(x.title, 110)));
    end loop;
    if n > 5 then t := t || ('… e altri ' || (n - 5)); end if;
  end if;
  -- approved by the rules while nobody decided
  select count(*) into n from fabula.approvals a where a.status = 'approved' and a.decided_by = 'Approvazione automatica' and a.decided_at >= p_since and v_sys >= 3;
  if n > 0 then
    v_any := true;
    t := t || ''::text || ('<b>Approvato da solo</b> (' || n || ')');
    for x in select a.summary from fabula.approvals a where a.status = 'approved' and a.decided_by = 'Approvazione automatica' and a.decided_at >= p_since
              order by a.decided_at desc limit 3 loop
      t := t || ('• ' || fabula.tg_esc(left(x.summary, 110)));
    end loop;
  end if;
  -- bots that stopped and are still open (their Telegrams held for the silence are folded in here: notify_digest_tick)
  select count(*) into n from fabula.bot_alerts where resolved_at is null and v_sys >= 1;
  if n > 0 then
    v_any := true;
    t := t || ''::text || ('<b>Bot da controllare</b> (' || n || ')');
    for x in select ba.label_it from fabula.bot_alerts ba where ba.resolved_at is null order by ba.alerted_at desc limit 3 loop
      t := t || ('• ' || fabula.tg_esc(left(coalesce(x.label_it, ''), 110)));
    end loop;
    if n > 3 then t := t || ('… e altri ' || (n - 3) || ' (Configurazione → Bot)'); end if;
  end if;
  -- the morning brief, if it came since
  for x in select m.title from fabula.bot_messages m where m.agent = 'daily_brief' and m.created_at >= p_since and v_sys >= 1 order by m.created_at desc limit 1 loop
    t := t || ''::text || ('<b>Brief</b> ' || fabula.tg_esc(left(x.title, 140)));
  end loop;
  if not v_any then
    t := t || ''::text || 'Niente da segnalare: nessuna decisione in attesa, nessun allarme aperto.'::text;
  end if;
  if v_site <> '' then t := t || ''::text || ('<a href="' || v_site || '/console.html#oggi">Apri la Console</a>'); end if;
  return left(array_to_string(t, E'\n'), 3900);
end $$;
revoke all on function fabula.notify_digest_text(uuid, timestamptz, timestamptz) from public, anon, authenticated;

-- every minute (from notify_tick): whoever's summary time has come today and has not had it yet
create or replace function fabula.notify_digest_tick(p_now timestamptz default now()) returns int
language plpgsql security definer set search_path = fabula, public as $$
declare t record; v_local timestamp; v_secs int; v_day date; v_since timestamptz; v_id uuid; n int := 0;
begin
  for t in select nt.* from fabula.notify_targets nt join fabula.staff s on s.id = nt.staff_id
            where nt.active and s.active and nt.chat_id is not null and nt.digest_at is not null and fabula.staff_level(s.id, 'sistema') >= 1
            for update of nt skip locked loop
    v_local := p_now at time zone coalesce(t.tz, 'Europe/Rome');
    v_secs := (extract(epoch from (v_local::time - t.digest_at))::int + 86400) % 86400;   -- seconds since the summary time (across midnight too)
    continue when v_secs >= 3 * 3600;                                                     -- more than 3 hours late: skip that day
    v_day := (v_local - make_interval(secs => v_secs))::date;                              -- the day the summary is for
    continue when t.digest_last is not null and t.digest_last >= v_day;
    select max(o.created_at) into v_since from fabula.notify_outbox o join fabula.notify_deliveries d on d.outbox_id = o.id
     where o.topic = 'digest' and d.staff_id = t.staff_id;
    insert into fabula.notify_outbox (topic, title, sender, source, source_ref, text_html)
    values ('digest', 'Riepilogo ' || fabula.it_day(v_day), 'Riepilogo', 'digest', t.staff_id::text,
            fabula.notify_digest_text(t.staff_id, greatest(coalesce(v_since, p_now - interval '24 hours'), p_now - interval '3 days'), p_now))
    returning id into v_id;
    insert into fabula.notify_deliveries (outbox_id, staff_id, chat_id, due_at) values (v_id, t.staff_id, t.chat_id, p_now);
    -- the system alarms that waited for the end of the silence and are due now: already in the summary («Bot da controllare»)
    update fabula.notify_deliveries d set status = 'skipped', error = 'nel riepilogo'
      from fabula.notify_outbox o
     where o.id = d.outbox_id and d.staff_id = t.staff_id and d.status = 'queued' and o.topic = 'infra' and not o.urgent and o.source = 'bot_alerts'
       and d.due_at <= p_now + interval '5 minutes';
    update fabula.notify_targets set digest_last = v_day where staff_id = t.staff_id;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function fabula.notify_digest_tick(timestamptz) from public, anon, authenticated;

do $mig$
declare d text := pg_get_functiondef('fabula.notify_tick'::regproc); n text;
begin
  n := replace(d, $o$  select count(*) into v_due from fabula.notify_deliveries$o$,
                  $n$  begin perform fabula.notify_digest_tick(); exception when others then raise warning 'notify_digest_tick: %', sqlerrm; end;   -- v1.02b
  select count(*) into v_due from fabula.notify_deliveries$n$);
  if n = d then raise exception 'v102b: notify_tick pattern not found'; end if;
  execute n;
end $mig$;

-- the summary has no «Ho visto / Me ne occupo io» buttons
do $mig$
declare d text := pg_get_functiondef('fabula.notify_claim'::regproc); n text;
begin
  n := replace(d, $o$'buttons', o.topic <> 'test'$o$, $n$'buttons', o.topic not in ('test', 'digest')$n$);
  if n = d then raise exception 'v102b: notify_claim buttons pattern not found'; end if;
  execute n;
end $mig$;

-- ============================================================================================================================
-- 4. Configurazione → Utenti → Avvisi Telegram: the summary time
-- ============================================================================================================================
delete from fabula.security_accepted
 where key = 'authenticated_security_definer_function_executable:fabula.notify_set_prefs(p_topics text[], p_quiet_from time without time zone, p_quiet_to time without time zone, p_tz text, p_staff_id uuid)';
drop function if exists fabula.notify_set_prefs(text[], time, time, text, uuid);
-- p_digest_at: null = unchanged, '' = no summary, 'HH:MM' = that time in the person's time zone
create function fabula.notify_set_prefs(p_topics text[], p_quiet_from time, p_quiet_to time, p_tz text, p_staff_id uuid default null, p_digest_at text default null)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare v_me uuid := fabula.my_staff_id(); v_id uuid := coalesce(p_staff_id, fabula.my_staff_id()); v_dig time;
begin
  if v_id is null then raise exception 'Persona non trovata' using errcode = 'P0002'; end if;
  if v_me is null or v_id <> v_me then perform fabula.require_perm('personale', 3); end if;
  if not (coalesce(p_topics, '{}') <@ array['food_safety', 'infra', 'decisions']::text[]) then raise exception 'Argomento sconosciuto' using errcode = '22023'; end if;
  if p_tz is not null and not exists (select 1 from pg_timezone_names where name = p_tz) then raise exception 'Fuso orario sconosciuto: %', p_tz using errcode = '22023'; end if;
  if nullif(trim(p_digest_at), '') is not null then
    begin v_dig := trim(p_digest_at)::time; exception when others then raise exception 'Ora del riepilogo non valida: %', p_digest_at using errcode = '22023'; end;
    if fabula.staff_level(v_id, 'sistema') < 1 then
      raise exception 'Il riepilogo riassume gli avvisi di Configurazione → Bot: serve almeno «vede» in Sistema' using errcode = '22023';
    end if;
  end if;
  update fabula.notify_targets set topics = coalesce(p_topics, '{}'), quiet_from = coalesce(p_quiet_from, quiet_from), quiet_to = coalesce(p_quiet_to, quiet_to),
         tz = coalesce(p_tz, tz), digest_at = case when p_digest_at is null then digest_at else v_dig end,
         digest_last = case when p_digest_at is not null and v_dig is distinct from digest_at then null else digest_last end, updated_at = now()
   where staff_id = v_id;
  if not found then raise exception 'Prima collega Telegram' using errcode = 'P0002'; end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function fabula.notify_set_prefs(text[], time, time, text, uuid, text) from public, anon;
grant execute on function fabula.notify_set_prefs(text[], time, time, text, uuid, text) to authenticated, service_role;
insert into fabula.security_accepted (key, reason) values
  ('authenticated_security_definer_function_executable:fabula.notify_set_prefs(p_topics text[], p_quiet_from time without time zone, p_quiet_to time without time zone, p_tz text, p_staff_id uuid, p_digest_at text)',
   'by design (v0.96c, audit E-01; v1.02b summary time): own settings, or require_perm(personale, 3)')
on conflict (key) do nothing;

do $mig$
declare d text := pg_get_functiondef('fabula.notify_overview'::regproc); n text;
begin
  n := replace(d, $o$'quiet_to', to_char(t.quiet_to, 'HH24:MI'), 'tz', t.tz,$o$,
                  $n$'quiet_to', to_char(t.quiet_to, 'HH24:MI'), 'tz', t.tz, 'digest_at', to_char(t.digest_at, 'HH24:MI'),$n$);
  if n = d then raise exception 'v102b: notify_overview «me» pattern not found'; end if;
  d := n;
  n := replace(d, $o$'linked', t.chat_id is not null, 'topics', t.topics, 'tz', t.tz,$o$,
                  $n$'linked', t.chat_id is not null, 'topics', t.topics, 'tz', t.tz, 'digest_at', to_char(t.digest_at, 'HH24:MI'),$n$);
  if n = d then raise exception 'v102b: notify_overview «people» pattern not found'; end if;
  d := n;
  n := replace(d, $o$where o.topic <> 'test' order by o.created_at desc limit 15$o$, $n$where o.topic not in ('test', 'digest') order by o.created_at desc limit 15$n$);
  if n = d then raise exception 'v102b: notify_overview «recent» pattern not found'; end if;
  execute n;
end $mig$;
