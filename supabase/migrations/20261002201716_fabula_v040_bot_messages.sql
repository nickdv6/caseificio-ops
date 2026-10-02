-- v0.40 · Bot dashboard: every bot notification lands in fabula.bot_messages and shows in Configurazione → Bot.
-- Sources: bots post their full report with post_bot_message() (last step of every prompt), every agent_runs row creates an 'auto'
-- message (replaced by the bot's report), console notices are mirrored. Read state via mark_bot_messages_read(). Sistema ≥ 1 reads the feed.

create or replace function fabula.bot_display_name(p_agent text) returns text language sql stable security definer set search_path = fabula, public as $$
  select coalesce((select name_it from fabula.bot_schedule where agent = p_agent),
    case p_agent when 'bot_watchdog' then 'Allarme bot' when 'bot_heartbeat' then 'Battito bot' when 'avvisi' then 'Avvisi console' else initcap(replace(p_agent, '_', ' ')) end)
$$;

-- the bots' last step: full report text into the dashboard (replaces the 'auto' message of the same run)
create or replace function fabula.post_bot_message(p_agent text, p_severity text, p_title text, p_body text, p_run_id uuid default null)
returns bigint language plpgsql security definer set search_path = fabula, public as $$
declare v_id bigint; v_sev text := case when p_severity in ('info','warn','alert') then p_severity else 'info' end;
begin
  select id into v_id from fabula.bot_messages
   where agent = p_agent and source = 'auto' and created_at > now() - interval '90 minutes'
   order by created_at desc limit 1;
  if v_id is not null then
    update fabula.bot_messages set severity = v_sev, title = coalesce(nullif(p_title, ''), title), body = p_body, source = 'bot',
           run_id = coalesce(p_run_id, run_id), read_at = null, read_by = null, created_at = now()
     where id = v_id;
  else
    insert into fabula.bot_messages (agent, run_id, severity, title, body, source)
    values (p_agent, p_run_id, v_sev, coalesce(nullif(p_title, ''), fabula.bot_display_name(p_agent)), p_body, 'bot')
    returning id into v_id;
  end if;
  return v_id;
end $$;

-- every run logged → an 'auto' message (unless the bot already posted its report in the last 15 min)
create or replace function fabula.trg_agent_run_message() returns trigger language plpgsql security definer set search_path = fabula, public as $$
declare v_id bigint;
begin
  select id into v_id from fabula.bot_messages where agent = new.agent and source = 'bot' and created_at > now() - interval '15 minutes'
   order by created_at desc limit 1;
  if v_id is not null then
    update fabula.bot_messages set run_id = coalesce(run_id, new.id),
           severity = case when new.status = 'error' then 'alert' else severity end where id = v_id;
  else
    insert into fabula.bot_messages (agent, run_id, severity, title, body, source)
    values (new.agent, new.id, case when new.status = 'error' then 'alert' else 'info' end,
            fabula.bot_display_name(new.agent) || case when new.status = 'error' then ' · errore' else '' end,
            coalesce(nullif(new.summary, ''), nullif(new.error, ''), 'Eseguito'), 'auto');
  end if;
  return new;
end $$;
do $$ begin if not exists (select 1 from pg_trigger where tgname = 'agent_runs_message') then
  create trigger agent_runs_message after insert on fabula.agent_runs for each row execute function fabula.trg_agent_run_message(); end if; end $$;

-- console notices (bot alerts, heartbeat, evening banner, lot-guard notices…) mirrored as messages
create or replace function fabula.trg_notice_message() returns trigger language plpgsql security definer set search_path = fabula, public as $$
declare v_body text; v_agent text;
begin
  if tg_op = 'UPDATE' and new.items is not distinct from old.items and new.title_it is not distinct from old.title_it then return new; end if;
  select string_agg('• ' || coalesce(x->>'label_it', x->>'text', x->>'title', x->>'name' || coalesce(' · ' || (x->>'detail'), ''), x #>> '{}'), E'\n')
    into v_body from jsonb_array_elements(case when jsonb_typeof(new.items) = 'array' then new.items else '[]'::jsonb end) x;
  v_agent := case when new.key = 'bot_alert' then 'bot_watchdog' when new.key = 'bot_heartbeat' then 'bot_heartbeat'
                  when new.key like 'haccp_evening%' then 'haccp_nudge' else 'avvisi' end;
  insert into fabula.bot_messages (agent, severity, title, body, source, notice_key)
  values (v_agent, case when new.severity in ('info','warn','alert') then new.severity else 'warn' end, new.title_it, v_body, 'notice', new.key);
  return new;
end $$;
do $$ begin if not exists (select 1 from pg_trigger where tgname = 'notices_message') then
  create trigger notices_message after insert or update on fabula.notices for each row execute function fabula.trg_notice_message(); end if; end $$;

create or replace function fabula.mark_bot_messages_read(p_ids bigint[] default null) returns int language plpgsql security definer set search_path = fabula, public as $$
declare n int;
begin
  perform fabula.require_perm('sistema', 1);
  update fabula.bot_messages set read_at = now(), read_by = fabula.my_staff_id()
   where read_at is null and (p_ids is null or id = any (p_ids));
  get diagnostics n = row_count; return n;
end $$;

-- one card per bot: schedule (Rome), last run, unread messages, last message
create or replace view fabula.v_bot_dashboard with (security_invoker = true) as
select b.agent, b.name_it, b.active, b.due_times, b.weekdays, b.month_day,
       lr.status as last_status, lr.started_at as last_run_at, lr.summary as last_summary,
       (select count(*) from fabula.bot_messages m where m.agent = b.agent and m.read_at is null) as unread,
       (select count(*) from fabula.bot_messages m where m.agent = b.agent and m.read_at is null and m.severity = 'alert') as unread_alerts,
       lm.title as last_title, lm.severity as last_severity, lm.created_at as last_message_at
from fabula.bot_schedule b
left join lateral (select status, started_at, summary from fabula.agent_runs r where r.agent = b.agent order by started_at desc limit 1) lr on true
left join lateral (select title, severity, created_at from fabula.bot_messages m where m.agent = b.agent order by created_at desc limit 1) lm on true;
grant select on fabula.v_bot_dashboard to authenticated, service_role;

revoke execute on function fabula.post_bot_message(text, text, text, text, uuid), fabula.trg_agent_run_message(), fabula.trg_notice_message() from public, anon, authenticated;
grant execute on function fabula.post_bot_message(text, text, text, text, uuid) to service_role;
revoke execute on function fabula.mark_bot_messages_read(bigint[]) from public, anon;
grant execute on function fabula.mark_bot_messages_read(bigint[]), fabula.bot_display_name(text) to authenticated, service_role;

-- backfill: today's runs and open notices
insert into fabula.bot_messages (agent, run_id, created_at, severity, title, body, source)
select r.agent, r.id, r.started_at, case when r.status = 'error' then 'alert' else 'info' end,
       fabula.bot_display_name(r.agent) || case when r.status = 'error' then ' · errore' else '' end, coalesce(r.summary, r.error, 'Eseguito'), 'auto'
from fabula.agent_runs r
where r.started_at > now() - interval '3 days' and not exists (select 1 from fabula.bot_messages m where m.run_id = r.id);
