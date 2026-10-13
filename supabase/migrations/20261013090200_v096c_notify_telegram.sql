-- v0.96c · Audit 12/10/2026, Critical item E-01: food-safety alerts leave the building.
-- Every 'alert' (bot dashboard message or tablet/office notice) becomes one outbox row with a topic:
--   food_safety → whoever subscribed + the HACCP responsible (setting food.responsabile_autocontrollo) + whoever is clocked in,
--                 any hour (no quiet hours);
--   infra       → whoever subscribed (Nick by default), any hour;
--   decisions   → whoever subscribed (owner and partners by default), held until the end of their quiet hours.
-- Telegram (@bubalina_avvisi_bot) delivers it with two buttons: «👀 Ho visto» and «✋ Me ne occupo io». Nobody taking charge within
-- 30 minutes (food safety and decisions) sends a reminder to the owner, the partners and the HACCP responsible too.
-- pg_cron (every minute) escalates and, when something is due, calls the edge function `notify`, which sends and receives the
-- Telegram updates (linking with /start <code>, the buttons). The bot token lives only in the function's secrets.

insert into fabula.settings (key, value, description, data_type) values
  ('notify.telegram_bot', 'bubalina_avvisi_bot', 'Bot Telegram degli avvisi (nome utente, senza @): si aggiorna da solo al primo invio', 'text'),
  ('notify.function_url', 'https://ojkquhzaeypsphncjqwy.supabase.co/functions/v1/notify', 'Indirizzo della funzione che invia gli avvisi Telegram', 'text'),
  ('notify.escalate_min', '30', 'Avvisi Telegram: minuti senza «Me ne occupo io» prima di avvisare anche titolare, soci e responsabile HACCP', 'number')
on conflict (key) do nothing;

-- ============================================================================================================================
-- 1. Tables (no direct access from the apps: only through the functions below)
-- ============================================================================================================================
create table if not exists fabula.notify_targets (
  staff_id     uuid primary key references fabula.staff(id) on delete cascade,
  chat_id      bigint unique,
  tg_name      text,
  topics       text[] not null default '{food_safety}',
  quiet_from   time not null default '22:00',
  quiet_to     time not null default '07:00',
  tz           text not null default 'Europe/Rome',
  link_code    text unique,
  link_expires timestamptz,
  linked_at    timestamptz,
  active       boolean not null default true,
  updated_at   timestamptz not null default now(),
  constraint notify_targets_topics check (topics <@ array['food_safety', 'infra', 'decisions']::text[])
);
create table if not exists fabula.notify_outbox (
  id           uuid primary key default gen_random_uuid(),
  created_at   timestamptz not null default now(),
  topic        text not null check (topic in ('food_safety', 'infra', 'decisions', 'test')),
  title        text not null,
  body         text,
  sender       text,
  source       text,
  source_ref   text,
  dedupe_key   text,
  text_html    text not null,
  parent_id    uuid references fabula.notify_outbox(id) on delete cascade,
  escalate_at  timestamptz,
  escalated_at timestamptz,
  acked_at     timestamptz,
  acked_by_id  uuid references fabula.staff(id)
);
create index if not exists notify_outbox_dedupe on fabula.notify_outbox (dedupe_key, created_at desc);
create index if not exists notify_outbox_escalate on fabula.notify_outbox (escalate_at) where acked_at is null and escalated_at is null;
create table if not exists fabula.notify_deliveries (
  id          uuid primary key default gen_random_uuid(),
  outbox_id   uuid not null references fabula.notify_outbox(id) on delete cascade,
  staff_id    uuid not null references fabula.staff(id) on delete cascade,
  chat_id     bigint not null,
  due_at      timestamptz not null default now(),
  status      text not null default 'queued' check (status in ('queued', 'sending', 'sent', 'failed', 'skipped')),
  attempts    int not null default 0,
  claimed_at  timestamptz,
  sent_at     timestamptz,
  message_id  bigint,
  error       text,
  seen_at     timestamptz,
  unique (outbox_id, staff_id)
);
create index if not exists notify_deliveries_due on fabula.notify_deliveries (due_at) where status in ('queued', 'sending');
alter table fabula.notify_targets enable row level security;
alter table fabula.notify_outbox enable row level security;
alter table fabula.notify_deliveries enable row level security;
revoke all on fabula.notify_targets, fabula.notify_outbox, fabula.notify_deliveries from anon, authenticated;
grant all on fabula.notify_targets, fabula.notify_outbox, fabula.notify_deliveries to service_role;

-- ============================================================================================================================
-- 2. Topic, text, routing
-- ============================================================================================================================
drop function if exists fabula.notify_topic_for(text, text);   -- an earlier draft had two arguments (a call would be ambiguous)
create or replace function fabula.notify_topic_for(p_agent text, p_text text, p_key text default null)
returns text language sql immutable as $$
  select case
    -- infrastructure first: «haccp_nudge non è partito» or «backup bloccato» are about the system, not the food
    when coalesce(p_key, '') ~ '^(bot_|infra_)'
      or p_agent in ('ops_health', 'bot_watchdog', 'bot_heartbeat', 'backup_export', 'restore_drill', 'invite_user', 'predis', 'infra') then 'infra'
    when p_agent = 'tablet' and coalesce(p_text, '') ~* 'rifiutat' then 'food_safety'   -- records lost on the floor: to redo today
    when p_agent = 'tablet' then 'infra'
    when coalesce(p_key, '') ~ '^(lot_guard|lab_lot_unknown)' or p_agent in ('haccp_nudge', 'nc')
      or coalesce(p_text, '') ~* '(⚠|\mCCP|HACCP|respint|lott[oi]\s+(\S+\s+)?bloccat|non conform|richiam|ritiro|antibiotic|fuori limite|sicurezza alimentare|cella frigo|pastorizz|filatura)'
      then 'food_safety'
    else 'decisions' end
$$;

-- Telegram HTML: escape, keep **bold**, cap the length, sender + time + a link to the right page
create or replace function fabula.notify_html(p_topic text, p_title text, p_body text, p_sender text, p_at timestamptz)
returns text language plpgsql stable set search_path = fabula, public as $$
declare v_site text := rtrim(coalesce(nullif(fabula.setting_text('infra.site_url'), ''), ''), '/'); v_b text; v_page text;
begin
  v_b := replace(replace(replace(coalesce(p_body, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
  v_b := regexp_replace(v_b, '\*\*([^*\n]+)\*\*', '<b>\1</b>', 'g');
  if length(v_b) > 3000 then v_b := left(v_b, 3000) || ' …'; end if;
  v_page := case p_topic when 'food_safety' then '/haccp.html' when 'infra' then '/admin.html' else '/console.html' end;
  return concat_ws(E'\n',
    case p_topic when 'food_safety' then '⚠ <b>SICUREZZA ALIMENTARE</b>' when 'infra' then '🔧 <b>Sistema</b>' when 'decisions' then '📌 <b>Da decidere</b>' else '🔔 <b>Prova</b>' end,
    '<b>' || replace(replace(replace(p_title, '&', '&amp;'), '<', '&lt;'), '>', '&gt;') || '</b>',
    nullif(v_b, ''),
    '',
    '<i>' || replace(replace(replace(coalesce(p_sender, 'Caseificio'), '&', '&amp;'), '<', '&lt;'), '>', '&gt;') || ' · ' || to_char(p_at at time zone 'Europe/Rome', 'DD/MM HH24:MI') || '</i>'
      || case when v_site <> '' then ' · <a href="' || v_site || v_page || '">apri</a>' else '' end);
end $$;

-- the end of a recipient's quiet hours (now, when outside them)
create or replace function fabula.notify_due(p_tz text, p_from time, p_to time)
returns timestamptz language plpgsql stable as $$
declare v_local timestamp := now() at time zone coalesce(p_tz, 'Europe/Rome'); v_t time := v_local::time; v_end timestamptz; v_quiet boolean;
begin
  if p_from is null or p_to is null or p_from = p_to then return now(); end if;
  v_quiet := case when p_from < p_to then v_t >= p_from and v_t < p_to else v_t >= p_from or v_t < p_to end;
  if not v_quiet then return now(); end if;
  v_end := (v_local::date + p_to) at time zone coalesce(p_tz, 'Europe/Rome');
  if v_end <= now() then v_end := ((v_local::date + 1) + p_to) at time zone coalesce(p_tz, 'Europe/Rome'); end if;
  return v_end;
end $$;

-- who gets an outbox row. p_wide = the reminder: also owner, partners and the HACCP responsible, whatever they subscribed to
create or replace function fabula.notify_route(p_outbox uuid, p_wide boolean default false)
returns int language plpgsql security definer set search_path = fabula, public as $$
declare o fabula.notify_outbox%rowtype; v_resp text := fabula.setting_text('food.responsabile_autocontrollo'); n int;
begin
  select * into o from fabula.notify_outbox where id = p_outbox;
  if o.id is null or o.topic = 'test' then return 0; end if;
  insert into fabula.notify_deliveries (outbox_id, staff_id, chat_id, due_at)
  select o.id, t.staff_id, t.chat_id,
         case when o.topic in ('food_safety', 'infra') then now() else fabula.notify_due(t.tz, t.quiet_from, t.quiet_to) end   -- only decisions wait (audit E-07)
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

-- one alert in: deduplicated (same key within 3 hours = already sent), routed, escalation set
create or replace function fabula.notify_enqueue(p_topic text, p_title text, p_body text, p_sender text, p_source text default null,
  p_ref text default null, p_dedupe text default null, p_parent uuid default null)
returns uuid language plpgsql security definer set search_path = fabula, public as $$
declare v_id uuid; v_min int := greatest(coalesce(fabula.setting_num('notify.escalate_min', 30), 30)::int, 5);
begin
  if p_dedupe is not null and exists (select 1 from fabula.notify_outbox where dedupe_key = p_dedupe and created_at > now() - interval '3 hours') then
    return null;
  end if;
  insert into fabula.notify_outbox (topic, title, body, sender, source, source_ref, dedupe_key, text_html, parent_id, escalate_at)
  values (p_topic, left(coalesce(nullif(p_title, ''), 'Avviso'), 200), p_body, p_sender, p_source, p_ref, p_dedupe,
          fabula.notify_html(p_topic, coalesce(nullif(p_title, ''), 'Avviso'), p_body, p_sender, now()), p_parent,
          case when p_parent is null and p_topic in ('food_safety', 'decisions') then now() + make_interval(mins => v_min) end)
  returning id into v_id;
  perform fabula.notify_route(v_id, p_parent is not null);
  return v_id;
end $$;

-- ============================================================================================================================
-- 3. Sources: bot dashboard messages and notices with severity 'alert'. A failure here never blocks the original write.
-- ============================================================================================================================
create or replace function fabula.trg_notify_bot_message()
returns trigger language plpgsql security definer set search_path = fabula, public as $$
begin
  if new.severity <> 'alert' or new.title like 'SIMULAZIONE%' or new.notice_key is not null then return null; end if;   -- a notice's copy: sent by notices_notify
  if tg_op = 'UPDATE' and old.severity = 'alert' and old.title is not distinct from new.title and old.body is not distinct from new.body then return null; end if;
  begin
    perform fabula.notify_enqueue(fabula.notify_topic_for(new.agent, new.title || ' ' || coalesce(new.body, '')), new.title, new.body,
                                  fabula.bot_display_name(new.agent), 'bot_messages', new.id::text, 'bm:' || new.agent || ':' || md5(new.title));
  exception when others then raise warning 'notify (bot_messages %): %', new.id, sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists bot_messages_notify on fabula.bot_messages;
create trigger bot_messages_notify after insert or update of severity, title, body on fabula.bot_messages
  for each row execute function fabula.trg_notify_bot_message();

create or replace function fabula.trg_notify_notice()
returns trigger language plpgsql security definer set search_path = fabula, public as $$
declare v_body text;
begin
  if new.severity <> 'alert' or new.resolved_at is not null then return null; end if;
  if tg_op = 'UPDATE' and old.severity = 'alert' and old.resolved_at is null and old.title_it is not distinct from new.title_it then return null; end if;
  begin
    select string_agg('- ' || coalesce(i ->> 'label_it', i ->> 'text', i::text), E'\n') into v_body
      from jsonb_array_elements(case when jsonb_typeof(new.items) = 'array' then new.items else '[]'::jsonb end) i;
    perform fabula.notify_enqueue(fabula.notify_topic_for('notice', new.title_it || ' ' || coalesce(v_body, ''), new.key),
                                  new.title_it, v_body, 'Avviso', 'notices', new.key, 'nt:' || new.key || ':' || md5(new.title_it));
  exception when others then raise warning 'notify (notices %): %', new.key, sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists notices_notify on fabula.notices;
create trigger notices_notify after insert or update of severity, title_it, resolved_at on fabula.notices
  for each row execute function fabula.trg_notify_notice();

-- every non-conformity opened (a CCP out of its critical limit, a lab result, a corrected value) is pushed at once.
-- An NC on a milk check linked to its delivery is left to milk_reject (v0.96a), whose alert («Latte … respinto», with the lots
-- held) says more.
create or replace function fabula.trg_notify_nc()
returns trigger language plpgsql security definer set search_path = fabula, public as $$
declare v_lot text; v_held boolean;
begin
  if exists (select 1 from fabula.haccp_log l join fabula.haccp_control_points c on c.id = l.control_point_id
              where l.id = new.haccp_log_id and l.milk_intake_id is not null and c.code in ('CCP-MILK-ABX', 'CCP-MILK-TEMP')) then return null; end if;
  begin
    select batch_lot, food_safety_hold into v_lot, v_held from fabula.production_batches where id = new.batch_id;
    v_lot := coalesce(v_lot, new.lot_number);
    perform fabula.notify_enqueue('food_safety',
      left('Non conformità · ' || case when v_lot is not null then 'lotto ' || v_lot || case when v_held then ' BLOCCATO' else '' end || ' · ' else '' end
           || split_part(coalesce(new.description, ''), '. Limite', 1), 160),
      concat_ws(E'\n', new.description, case when nullif(new.corrective_action, '') is not null then '**Azione** ' || new.corrective_action end,
                case when v_held then 'Il lotto è bloccato: non si vende finché il responsabile HACCP non lo sblocca.' end,
                'Autocontrollo → Non conformità'),
      'Autocontrollo', 'non_conformities', new.id::text, 'nc:' || new.id);
  exception when others then raise warning 'notify (non_conformities %): %', new.id, sqlerrm;
  end;
  return null;
end $$;
revoke all on function fabula.trg_notify_nc() from public, anon, authenticated;
drop trigger if exists non_conformities_notify on fabula.non_conformities;
-- deferred to the end of the transaction, so the lot hold set right after the NC (same save) is in the message
create constraint trigger non_conformities_notify after insert on fabula.non_conformities deferrable initially deferred
  for each row execute function fabula.trg_notify_nc();

-- ============================================================================================================================
-- 4. Every minute: reminders for alerts nobody took, then wake the sender if something is due
-- ============================================================================================================================
create or replace function fabula.notify_tick()
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare o record; v_rem int := 0; v_due int; v_req bigint;
begin
  for o in select * from fabula.notify_outbox where acked_at is null and escalated_at is null and escalate_at <= now() order by created_at for update skip locked loop
    update fabula.notify_outbox set escalated_at = now() where id = o.id;
    perform fabula.notify_enqueue(o.topic, '⏰ Nessuno se ne occupa da ' || extract(epoch from now() - o.created_at)::int / 60 || ' min: ' || o.title,
                                  o.body, o.sender, o.source, o.source_ref, null, o.id);
    v_rem := v_rem + 1;
  end loop;
  select count(*) into v_due from fabula.notify_deliveries
   where (status = 'queued' and due_at <= now()) or (status = 'sending' and claimed_at < now() - interval '5 minutes' and attempts < 5);
  if v_due > 0 or (coalesce(fabula.setting_text('notify.webhook_url'), '') = '' and extract(minute from now())::int % 10 = 0) then
    select net.http_post(url := fabula.setting_text('notify.function_url'), body := jsonb_build_object('op', 'dispatch'),
                         headers := jsonb_build_object('Content-Type', 'application/json'), timeout_milliseconds := 30000) into v_req;
  end if;
  return jsonb_build_object('reminders', v_rem, 'due', v_due, 'request', v_req);
end $$;

-- ============================================================================================================================
-- 5. Called by the edge function (service role only)
-- ============================================================================================================================
create or replace function fabula.notify_claim(p_limit int default 25)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare r jsonb;
begin
  -- an alert someone already took in the meantime is not sent late (e.g. a decision held overnight)
  update fabula.notify_deliveries d set status = 'skipped', error = 'già preso in carico'
    from fabula.notify_outbox o
   where o.id = d.outbox_id and d.status = 'queued' and d.due_at <= now() and o.topic <> 'test'
     and coalesce(o.acked_at, (select p.acked_at from fabula.notify_outbox p where p.id = o.parent_id)) is not null;
  -- the person unlinked (/stop), changed Telegram, was switched off or deactivated while it waited: not sent
  update fabula.notify_deliveries d set status = 'skipped', error = 'destinatario non più collegato'
   where d.status = 'queued' and d.due_at <= now()
     and not exists (select 1 from fabula.notify_targets t join fabula.staff s on s.id = t.staff_id
                      where t.staff_id = d.staff_id and t.chat_id = d.chat_id and t.active and s.active);
  -- sent 5 times without an answer from the sender: given up, shown as failed (the daily check lists it)
  update fabula.notify_deliveries set status = 'failed', error = coalesce(error, 'nessuna risposta dalla funzione di invio')
   where status = 'sending' and attempts >= 5 and claimed_at < now() - interval '5 minutes';
  with c as (
    select d.id from fabula.notify_deliveries d
     where (d.status = 'queued' and d.due_at <= now()) or (d.status = 'sending' and d.claimed_at < now() - interval '5 minutes' and d.attempts < 5)
     order by d.due_at limit greatest(1, least(p_limit, 100)) for update skip locked),
  u as (update fabula.notify_deliveries d set status = 'sending', claimed_at = now(), attempts = d.attempts + 1 from c where d.id = c.id
        returning d.id, d.chat_id, d.outbox_id)
  select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'chat_id', u.chat_id, 'outbox_id', coalesce(o.parent_id, o.id), 'text', o.text_html,
                                               'buttons', o.topic <> 'test')), '[]')
    into r from u join fabula.notify_outbox o on o.id = u.outbox_id;
  return r;
end $$;

create or replace function fabula.notify_mark(p_id uuid, p_ok boolean, p_message_id bigint default null, p_error text default null)
returns void language plpgsql security definer set search_path = fabula, public as $$
begin
  if p_ok then
    update fabula.notify_deliveries set status = 'sent', sent_at = now(), message_id = p_message_id, error = null where id = p_id;
  else
    update fabula.notify_deliveries
       set status = case when attempts >= 5 or coalesce(p_error, '') ~* '(blocked|chat not found|deactivated|forbidden)' then 'failed' else 'queued' end,
           due_at = now() + make_interval(mins => 2 * attempts), error = left(p_error, 500)
     where id = p_id;
    -- the person blocked the bot or deleted the chat: stop trying, the console shows it as not linked
    update fabula.notify_targets t set chat_id = null, linked_at = null, updated_at = now()
      from fabula.notify_deliveries d where d.id = p_id and t.staff_id = d.staff_id and coalesce(p_error, '') ~* '(blocked|chat not found|deactivated)';
  end if;
end $$;

-- /start <code> in the bot links that Telegram chat to the person who created the code
create or replace function fabula.notify_link(p_code text, p_chat_id bigint, p_tg_name text default null)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare t fabula.notify_targets%rowtype; v_name text;
begin
  select * into t from fabula.notify_targets where link_code = p_code and link_expires > now() for update;
  if t.staff_id is null then return jsonb_build_object('ok', false); end if;
  update fabula.notify_targets set chat_id = null, linked_at = null where chat_id = p_chat_id and staff_id <> t.staff_id;
  update fabula.notify_targets set chat_id = p_chat_id, tg_name = left(p_tg_name, 80), linked_at = now(), link_code = null, link_expires = null,
         active = true, updated_at = now() where staff_id = t.staff_id;
  select full_name into v_name from fabula.staff where id = t.staff_id;
  return jsonb_build_object('ok', true, 'full_name', v_name, 'topics', t.topics, 'quiet_from', to_char(t.quiet_from, 'HH24:MI'), 'quiet_to', to_char(t.quiet_to, 'HH24:MI'));
end $$;

create or replace function fabula.notify_unlink_chat(p_chat_id bigint)
returns boolean language sql security definer set search_path = fabula, public as $$
  with u as (update fabula.notify_targets set chat_id = null, linked_at = null, updated_at = now() where chat_id = p_chat_id returning 1)
  select exists (select 1 from u)
$$;

-- the buttons. «Me ne occupo io» stops the reminder and tells everyone who got the alert (the function edits their messages)
create or replace function fabula.notify_ack(p_chat_id bigint, p_outbox uuid, p_kind text)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare v_staff uuid; v_name text; v_root uuid; r fabula.notify_outbox%rowtype; v_by text; v_edits jsonb;
begin
  select t.staff_id, s.full_name into v_staff, v_name from fabula.notify_targets t join fabula.staff s on s.id = t.staff_id where t.chat_id = p_chat_id;
  if v_staff is null then return jsonb_build_object('ok', false, 'toast', 'Questo Telegram non è più collegato'); end if;
  select coalesce(parent_id, id) into v_root from fabula.notify_outbox where id = p_outbox;
  if v_root is null then return jsonb_build_object('ok', false, 'toast', 'Avviso non trovato'); end if;
  update fabula.notify_deliveries set seen_at = coalesce(seen_at, now())
   where staff_id = v_staff and outbox_id in (select id from fabula.notify_outbox where id = v_root or parent_id = v_root);
  select * into r from fabula.notify_outbox where id = v_root for update;
  if p_kind <> 'take' then return jsonb_build_object('ok', true, 'toast', 'Segnato come visto'); end if;
  if r.acked_at is not null then
    select full_name into v_by from fabula.staff where id = r.acked_by_id;
    return jsonb_build_object('ok', true, 'toast', case when r.acked_by_id = v_staff then 'Te ne occupi già tu' else 'Se ne occupa già ' || coalesce(v_by, '?') end);
  end if;
  update fabula.notify_outbox set acked_at = now(), acked_by_id = v_staff where id = v_root or parent_id = v_root;
  select coalesce(jsonb_agg(jsonb_build_object('chat_id', d.chat_id, 'message_id', d.message_id,
           'text', o.text_html || E'\n\n✋ <b>Se ne occupa ' || replace(replace(v_name, '<', '&lt;'), '>', '&gt;') || '</b> (dalle ' || to_char(now() at time zone 'Europe/Rome', 'HH24:MI') || ')')), '[]')
    into v_edits
    from fabula.notify_deliveries d join fabula.notify_outbox o on o.id = d.outbox_id
   where (o.id = v_root or o.parent_id = v_root) and d.status = 'sent' and d.message_id is not null;
  return jsonb_build_object('ok', true, 'toast', 'Ok: te ne occupi tu. Gli altri lo vedono.', 'edits', v_edits);
end $$;

-- ============================================================================================================================
-- 6. Called from Configurazione → Utenti (logged-in people)
-- ============================================================================================================================
-- a one-time link (24 h) for yourself, or (personale 3) for someone else to open on their phone
create or replace function fabula.notify_link_code(p_staff_id uuid default null)
returns jsonb language plpgsql security definer set search_path = fabula, public, extensions as $$
declare v_me uuid := fabula.my_staff_id(); v_id uuid := coalesce(p_staff_id, fabula.my_staff_id()); v_code text; s record;
begin
  if v_id is null then raise exception 'Persona non trovata' using errcode = 'P0002'; end if;
  if v_me is null or v_id <> v_me then perform fabula.require_perm('personale', 3); end if;
  select id, full_name, app_role, active into s from fabula.staff where id = v_id;
  if not coalesce(s.active, false) then raise exception 'Persona non attiva' using errcode = 'P0002'; end if;
  v_code := encode(extensions.gen_random_bytes(9), 'hex');
  insert into fabula.notify_targets (staff_id, topics, link_code, link_expires)
  values (v_id, case s.app_role when 'titolare' then '{food_safety,infra,decisions}'::text[] when 'socio' then '{food_safety,decisions}'::text[] else '{food_safety}'::text[] end,
          v_code, now() + interval '24 hours')
  on conflict (staff_id) do update set link_code = excluded.link_code, link_expires = excluded.link_expires, updated_at = now();
  if coalesce(fabula.setting_text('notify.webhook_url'), '') = '' then   -- first link ever: let the function register itself with Telegram now
    perform net.http_post(url := fabula.setting_text('notify.function_url'), body := jsonb_build_object('op', 'dispatch'),
                          headers := jsonb_build_object('Content-Type', 'application/json'), timeout_milliseconds := 30000);
  end if;
  return jsonb_build_object('code', v_code, 'url', 'https://t.me/' || fabula.setting_text('notify.telegram_bot') || '?start=' || v_code,
                            'expires', now() + interval '24 hours', 'staff', s.full_name);
end $$;

create or replace function fabula.notify_set_prefs(p_topics text[], p_quiet_from time, p_quiet_to time, p_tz text, p_staff_id uuid default null)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare v_me uuid := fabula.my_staff_id(); v_id uuid := coalesce(p_staff_id, fabula.my_staff_id());
begin
  if v_id is null then raise exception 'Persona non trovata' using errcode = 'P0002'; end if;
  if v_me is null or v_id <> v_me then perform fabula.require_perm('personale', 3); end if;
  if not (coalesce(p_topics, '{}') <@ array['food_safety', 'infra', 'decisions']::text[]) then raise exception 'Argomento sconosciuto' using errcode = '22023'; end if;
  if p_tz is not null and not exists (select 1 from pg_timezone_names where name = p_tz) then raise exception 'Fuso orario sconosciuto: %', p_tz using errcode = '22023'; end if;
  update fabula.notify_targets set topics = coalesce(p_topics, '{}'), quiet_from = coalesce(p_quiet_from, quiet_from), quiet_to = coalesce(p_quiet_to, quiet_to),
         tz = coalesce(p_tz, tz), updated_at = now() where staff_id = v_id;
  if not found then raise exception 'Prima collega Telegram' using errcode = 'P0002'; end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function fabula.notify_unlink(p_staff_id uuid default null)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare v_me uuid := fabula.my_staff_id(); v_id uuid := coalesce(p_staff_id, fabula.my_staff_id());
begin
  if v_me is null or v_id is distinct from v_me then perform fabula.require_perm('personale', 3); end if;
  update fabula.notify_targets set chat_id = null, linked_at = null, tg_name = null, link_code = null, link_expires = null, updated_at = now() where staff_id = v_id;
  return jsonb_build_object('ok', true);
end $$;

-- a test message to yourself (or, personale 3, to someone else) right away
create or replace function fabula.notify_test(p_staff_id uuid default null)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare v_me uuid := fabula.my_staff_id(); v_id uuid := coalesce(p_staff_id, fabula.my_staff_id()); t fabula.notify_targets%rowtype; v_o uuid; v_name text;
begin
  if v_me is null or v_id is distinct from v_me then perform fabula.require_perm('personale', 3); end if;
  select * into t from fabula.notify_targets where staff_id = v_id;
  if t.chat_id is null then raise exception 'Telegram non ancora collegato' using errcode = 'P0002'; end if;
  select full_name into v_name from fabula.staff where id = v_id;
  insert into fabula.notify_outbox (topic, title, body, sender, source, text_html)
  values ('test', 'Messaggio di prova', 'Se lo leggi, gli avvisi arrivano qui.', 'Configurazione',
          'test', fabula.notify_html('test', 'Messaggio di prova per ' || v_name, 'Se lo leggi, gli avvisi del caseificio arrivano qui.', 'Configurazione', now()))
  returning id into v_o;
  insert into fabula.notify_deliveries (outbox_id, staff_id, chat_id) values (v_o, v_id, t.chat_id);
  perform fabula.notify_tick();
  return jsonb_build_object('ok', true);
end $$;

-- own state (anyone logged in) + everybody's state and the last alerts (owner/partners: personale 3)
create or replace function fabula.notify_overview()
returns jsonb language plpgsql stable security definer set search_path = fabula, public as $$
declare v_me uuid := fabula.my_staff_id(); v_all boolean := fabula.can('personale', 3); r jsonb;
begin
  select jsonb_build_object(
    'bot', fabula.setting_text('notify.telegram_bot'),
    'me', (select jsonb_build_object('linked', t.chat_id is not null, 'tg_name', t.tg_name, 'linked_at', t.linked_at, 'topics', t.topics,
                                     'quiet_from', to_char(t.quiet_from, 'HH24:MI'), 'quiet_to', to_char(t.quiet_to, 'HH24:MI'), 'tz', t.tz,
                                     'link_pending', t.link_expires > now())
             from fabula.notify_targets t where t.staff_id = v_me),
    'people', case when v_all then (select coalesce(jsonb_agg(jsonb_build_object('staff_id', s.id, 'full_name', s.full_name, 'app_role', s.app_role,
                 'linked', t.chat_id is not null, 'topics', t.topics, 'tz', t.tz,
                 'haccp_resp', s.full_name = fabula.setting_text('food.responsabile_autocontrollo'),
                 'last_sent', (select max(d.sent_at) from fabula.notify_deliveries d where d.staff_id = s.id),
                 'failed_24h', (select count(*) from fabula.notify_deliveries d where d.staff_id = s.id and d.status = 'failed' and d.due_at > now() - interval '24 hours'))
               order by s.full_name), '[]')
             from fabula.staff s left join fabula.notify_targets t on t.staff_id = s.id where s.active) end,
    'webhook_ok', coalesce(fabula.setting_text('notify.webhook_url'), '') <> '',
    'recent', case when v_all then (select coalesce(jsonb_agg(x order by x.created_at desc), '[]') from (
                 select o.created_at, o.topic, o.title, (select full_name from fabula.staff where id = o.acked_by_id) taken_by, o.acked_at,
                        (select count(*) from fabula.notify_deliveries d where d.outbox_id = o.id and d.status = 'sent') sent,
                        (select count(*) from fabula.notify_deliveries d where d.outbox_id = o.id and d.status in ('queued', 'sending')) waiting,
                        (select count(*) from fabula.notify_deliveries d where d.outbox_id = o.id and d.status = 'failed') failed
                   from fabula.notify_outbox o where o.topic <> 'test' order by o.created_at desc limit 15) x) end)
  into r;
  return r;
end $$;

-- ============================================================================================================================
-- 7. Grants, schedule, daily check, security acceptances
-- ============================================================================================================================
revoke all on function fabula.notify_route(uuid, boolean) from public, anon, authenticated;
revoke all on function fabula.notify_enqueue(text, text, text, text, text, text, text, uuid) from public, anon, authenticated;
revoke all on function fabula.notify_tick() from public, anon, authenticated;
revoke all on function fabula.notify_claim(int) from public, anon, authenticated;
revoke all on function fabula.notify_mark(uuid, boolean, bigint, text) from public, anon, authenticated;
revoke all on function fabula.notify_link(text, bigint, text) from public, anon, authenticated;
revoke all on function fabula.notify_unlink_chat(bigint) from public, anon, authenticated;
revoke all on function fabula.notify_ack(bigint, uuid, text) from public, anon, authenticated;
grant execute on function fabula.notify_route(uuid, boolean), fabula.notify_enqueue(text, text, text, text, text, text, text, uuid), fabula.notify_tick(),
  fabula.notify_claim(int), fabula.notify_mark(uuid, boolean, bigint, text), fabula.notify_link(text, bigint, text), fabula.notify_unlink_chat(bigint),
  fabula.notify_ack(bigint, uuid, text) to service_role;
revoke all on function fabula.notify_link_code(uuid), fabula.notify_set_prefs(text[], time, time, text, uuid), fabula.notify_unlink(uuid),
  fabula.notify_test(uuid), fabula.notify_overview() from public, anon;
grant execute on function fabula.notify_link_code(uuid), fabula.notify_set_prefs(text[], time, time, text, uuid), fabula.notify_unlink(uuid),
  fabula.notify_test(uuid), fabula.notify_overview() to authenticated, service_role;
revoke all on function fabula.trg_notify_bot_message(), fabula.trg_notify_notice() from public, anon, authenticated;

do $mig$ begin
  if exists (select 1 from cron.job where jobname = 'fabula_notify_tick') then perform cron.unschedule('fabula_notify_tick'); end if;
  perform cron.schedule('fabula_notify_tick', '* * * * *', $c$select fabula.notify_tick()$c$);
end $mig$;

-- daily check: alerts that could not be delivered, and nobody linked for food safety
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.ops_health_check(date)'::regprocedure);
  n := replace(d, $s$    select 'approvals_stale', $s$,
$s$    select 'notify_failed', 'Avvisi Telegram non consegnati nelle ultime 24 ore: ' || count(*) || ' · Configurazione → Utenti → Avvisi Telegram', count(*)
      from fabula.notify_deliveries where status = 'failed' and due_at > now() - interval '24 hours' having count(*) > 0
    union all
    select 'notify_stuck', 'Avvisi Telegram fermi da oltre 15 minuti: ' || count(*) || ' · la funzione notify non risponde (secrets? deploy con --no-verify-jwt?)', count(*)
      from fabula.notify_deliveries where status in ('queued', 'sending') and due_at < now() - interval '15 minutes' having count(*) > 0
    union all
    select 'notify_nobody', 'Avvisi di sicurezza alimentare: nessuno ha collegato Telegram (Configurazione → Utenti → Avvisi Telegram)', 1
      where not exists (select 1 from fabula.notify_targets where chat_id is not null and active)
    union all
    select 'approvals_stale', $s$);
  if n = d then raise exception 'v096c: ops_health_check anchor not found'; end if;
  execute n;
end $mig$;

insert into fabula.security_accepted (key, reason, accepted_at) values
 ('rls_enabled_no_policy:fabula.notify_targets', 'by design (v0.96c, audit E-01): reached only through the notify_* functions', now()),
 ('rls_enabled_no_policy:fabula.notify_outbox', 'by design (v0.96c, audit E-01): reached only through the notify_* functions', now()),
 ('rls_enabled_no_policy:fabula.notify_deliveries', 'by design (v0.96c, audit E-01): reached only through the notify_* functions', now()),
 ('authenticated_security_definer_function_executable:fabula.notify_link_code(p_staff_id uuid)',
  'by design (v0.96c, audit E-01): own link, or require_perm(personale, 3) for someone else', now()),
 ('authenticated_security_definer_function_executable:fabula.notify_set_prefs(p_topics text[], p_quiet_from time without time zone, p_quiet_to time without time zone, p_tz text, p_staff_id uuid)',
  'by design (v0.96c, audit E-01): own settings, or require_perm(personale, 3)', now()),
 ('authenticated_security_definer_function_executable:fabula.notify_unlink(p_staff_id uuid)',
  'by design (v0.96c, audit E-01): own link, or require_perm(personale, 3)', now()),
 ('authenticated_security_definer_function_executable:fabula.notify_test(p_staff_id uuid)',
  'by design (v0.96c, audit E-01): a test message to own Telegram, or require_perm(personale, 3)', now()),
 ('authenticated_security_definer_function_executable:fabula.notify_overview()',
  'by design (v0.96c, audit E-01): own state for everyone; people and recent alerts only with personale 3', now())
on conflict (key) do nothing;
