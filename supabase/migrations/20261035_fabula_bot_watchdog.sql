-- v0.36 · Bot failure alerting within the hour, instead of waiting for the 14:36 ET health check.
-- bot_schedule: when each scheduled bot is due (New York time, as the scheduled tasks are set), weekdays, grace minutes.
-- bot_watchdog(): finds (a) agent_runs with status error not yet alerted, (b) bots past due + grace with no run today,
-- (c) runs stuck without finished_at for > 30 min. Each problem is alerted once (bot_alerts), and a 'bot_alert' notice is written for the console.
-- Returns {alerts:[...], message_it} — the hourly "Allarme bot" scheduled task pushes message_it only when alerts is not empty.

create table if not exists fabula.bot_schedule (
  agent       text primary key,
  name_it     text not null,
  due_times   time[] not null,                 -- America/New_York
  weekdays    int[] not null default '{1,2,3,4,5,6}',   -- ISO 1 = lunedì
  month_day   int,                             -- only on this day of the month (monthly review)
  grace_min   int not null default 45,
  active      boolean not null default true);
alter table fabula.bot_schedule enable row level security;
do $$ begin if not exists (select 1 from pg_policies where schemaname = 'fabula' and tablename = 'bot_schedule' and policyname = 'bot_schedule_read') then
  create policy bot_schedule_read on fabula.bot_schedule for select to authenticated using (true); end if; end $$;
grant select on fabula.bot_schedule to authenticated; grant all on fabula.bot_schedule to service_role;

insert into fabula.bot_schedule (agent, name_it, due_times, weekdays, month_day) values
  ('shopify_customers', 'Clienti Shopify', '{06:05}', '{1,2,3,4,5,6}', null),
  ('shopify_orders', 'Ordini Shopify', '{06:11}', '{1,2,3,4,5,6}', null),
  ('procurement', 'Acquisti', '{06:20}', '{1,2,3,4,5,6}', null),
  ('daily_brief', 'Brief del mattino', '{06:47}', '{1,2,3,4,5,6}', null),
  ('weekly_brief', 'Brief settimanale', '{07:08}', '{1}', null),
  ('compliance_calendar', 'Manutenzioni e scadenze', '{07:17}', '{2}', null),
  ('sell_down', 'Da vendere prima', '{07:23}', '{1,2,3,4,5,6}', null),
  ('shopify_inventory', 'Giacenze Shopify', '{07:32,13:32}', '{1,2,3,4,5,6}', null),
  ('monthly_review', 'Revisione mensile', '{07:41}', '{1,2,3,4,5,6,7}', 1),
  ('wholesale_orders', 'Ordini ingrosso', '{12:20}', '{1,2,3,4,5,6}', null),
  ('milk_planning', 'Piano latte', '{12:52}', '{1,2,3,4,5,6}', null),
  ('haccp_nudge', 'Chiusura serata', '{13:02}', '{1,2,3,4,5,6}', null),
  ('ops_health', 'Controllo sistema', '{14:36}', '{1,2,3,4,5,6}', null)
on conflict (agent) do nothing;

create table if not exists fabula.bot_alerts (
  id         bigserial primary key,
  agent      text not null,
  kind       text not null check (kind in ('error','missed','stuck')),
  ref        text not null,                    -- run id, or 'YYYY-MM-DD HH:MM' due slot
  detail     text,
  alerted_at timestamptz not null default now(),
  unique (agent, kind, ref));
alter table fabula.bot_alerts enable row level security;
do $$ begin if not exists (select 1 from pg_policies where schemaname = 'fabula' and tablename = 'bot_alerts' and policyname = 'bot_alerts_read') then
  create policy bot_alerts_read on fabula.bot_alerts for select to authenticated using (true); end if; end $$;
grant select on fabula.bot_alerts to authenticated; grant all on fabula.bot_alerts to service_role;
grant usage on sequence fabula.bot_alerts_id_seq to service_role;

create or replace function fabula.bot_watchdog(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare v_ny timestamp := p_now at time zone 'America/New_York'; v_day date := (p_now at time zone 'America/New_York')::date;
        r record; a jsonb := '[]'::jsonb; v_due timestamptz; v_ref text; n int; v_msg text;
begin
  -- (a) errors in the last 26 h
  for r in select ar.id, ar.agent, ar.started_at, coalesce(nullif(ar.error, ''), nullif(ar.summary, ''), 'errore senza dettagli') err, coalesce(bs.name_it, ar.agent) nm
           from fabula.agent_runs ar left join fabula.bot_schedule bs on bs.agent = ar.agent
           where ar.status = 'error' and ar.started_at > p_now - interval '26 hours' order by ar.started_at loop
    insert into fabula.bot_alerts (agent, kind, ref, detail) values (r.agent, 'error', r.id::text, left(r.err, 300)) on conflict do nothing;
    get diagnostics n = row_count;
    if n > 0 then a := a || jsonb_build_object('agent', r.agent, 'name', r.nm, 'kind', 'error', 'at', r.started_at, 'detail', left(r.err, 200)); end if;
  end loop;
  -- (b) missed: due slot + grace passed today, no run started since 30 min before the slot
  for r in select bs.*, t.due from fabula.bot_schedule bs cross join unnest(bs.due_times) t(due)
           where bs.active and extract(isodow from v_day) = any (bs.weekdays) and (bs.month_day is null or extract(day from v_day) = bs.month_day)
             and v_day + t.due + make_interval(mins => bs.grace_min) <= v_ny loop
    v_due := (v_day + r.due) at time zone 'America/New_York';
    if not exists (select 1 from fabula.agent_runs ar where ar.agent = r.agent and ar.started_at >= v_due - interval '30 minutes') then
      v_ref := to_char(v_day + r.due, 'YYYY-MM-DD HH24:MI');
      insert into fabula.bot_alerts (agent, kind, ref, detail) values (r.agent, 'missed', v_ref, null) on conflict do nothing;
      get diagnostics n = row_count;
      if n > 0 then a := a || jsonb_build_object('agent', r.agent, 'name', r.name_it, 'kind', 'missed', 'due_ny', to_char(r.due, 'HH24:MI'),
                                                 'due_rome', to_char(v_due at time zone 'Europe/Rome', 'HH24:MI')); end if;
    end if;
  end loop;
  -- (c) stuck: started > 30 min ago, never finished
  for r in select ar.id, ar.agent, ar.started_at, coalesce(bs.name_it, ar.agent) nm from fabula.agent_runs ar left join fabula.bot_schedule bs on bs.agent = ar.agent
           where ar.finished_at is null and ar.status is distinct from 'error' and ar.started_at between p_now - interval '26 hours' and p_now - interval '30 minutes' loop
    insert into fabula.bot_alerts (agent, kind, ref) values (r.agent, 'stuck', r.id::text) on conflict do nothing;
    get diagnostics n = row_count;
    if n > 0 then a := a || jsonb_build_object('agent', r.agent, 'name', r.nm, 'kind', 'stuck', 'at', r.started_at); end if;
  end loop;

  if jsonb_array_length(a) > 0 then
    select string_agg(case x->>'kind'
             when 'error' then format('❌ %s: errore alle %s (it.) — %s', x->>'name', to_char((x->>'at')::timestamptz at time zone 'Europe/Rome', 'HH24:MI'), x->>'detail')
             when 'missed' then format('⏰ %s: non è partito (previsto %s it. / %s NY)', x->>'name', x->>'due_rome', x->>'due_ny')
             else format('⏳ %s: avviato alle %s (it.) e mai finito', x->>'name', to_char((x->>'at')::timestamptz at time zone 'Europe/Rome', 'HH24:MI')) end, E'\n')
      into v_msg from jsonb_array_elements(a) x;
    v_msg := 'Problemi con i bot:' || E'\n' || v_msg || E'\n' || 'Dettagli: Configurazione → Bot. Un bot fermo si rilancia dalle attività programmate.';
    insert into fabula.notices (key, severity, title_it, items, expires_at)
    values ('bot_alert', 'alert', format('%s problemi con i bot', jsonb_array_length(a)), a, p_now + interval '24 hours')
    on conflict (key) do update set severity = 'alert', title_it = excluded.title_it, items = excluded.items, created_at = p_now, expires_at = excluded.expires_at, resolved_at = null;
  end if;
  return jsonb_build_object('checked_at', p_now, 'alerts', a, 'message_it', v_msg);
end $$;
grant execute on function fabula.bot_watchdog(timestamptz) to service_role;
