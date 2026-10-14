-- v1.00b · Audit 12/10/2026, alerts and operations (1/2): the bot feed.
--   E-04 / C-12  Read state is per person (bot_message_reads): «Segna come letta» and «Segna tutto come letto» mark it for me only,
--                and «Segna tutto» never touches an alarm. An alarm closes for everyone only with «Risolto» + a note (Sistema = gestisce),
--                or by itself when its condition clears; the message shows who saw it and who resolved it, and the Telegram reminders
--                for it stop. The bell counts open alarms first, then what I have not read.
--   E-05         Routine messages stop piling up: a scheduled bot's info/warn is closed by its next message, and a milk-plan or promo
--                message closes when its request is decided. Browsers no longer write bot_messages at all (only the functions do).
--   E-21         A bot that started and failed is stood in for by the database too (its error row counted as «ran»), and its
--                failed-run alarm is not pushed to Telegram: the watchdog sends one message per incident (v1.00c).
--   E-08         Every message carries a link to the page that deals with it (action_url/action_label; post_bot_message p_link, only
--                relative links to the app's pages); a milk plan or a promo links to its own card (console.html#oggi&appr=<id>). Telegram
--                uses the same link.
--   E-13         The function comes first, the persona second: «Piano latte · Zio Gennaro». Food-safety alerts are posted by
--                «Sicurezza alimentare» (no longer «Resa produzione» or «Tablet»), rota copies by «Turni»; the confusable pairs
--                (Zio Nino / Zio Tonino, Zio Carmelo / Zia Carmela) lose a nickname.
--   E-20 / E-21  Wording: a failed bot says what happens next and where «Esegui ora» is; a database stand-in no longer says the bot's
--                notifications were lost (they reach Telegram since v0.96).

-- ============================================================================================================================
-- 1. Columns and the per-person read table
-- ============================================================================================================================
alter table fabula.bot_messages add column if not exists resolved_at timestamptz,
                                add column if not exists resolved_by_id uuid references fabula.staff(id),
                                add column if not exists resolution text,
                                add column if not exists action_url text,
                                add column if not exists action_label text,
                                add column if not exists approval_id uuid;
comment on column fabula.bot_messages.read_at is 'Closed for everyone (auto-read, or resolved). Per-person reading is in bot_message_reads (v1.00b)';
comment on column fabula.bot_messages.resolved_at is 'v1.00b (audit E-04): alarm closed, by a person (resolved_by_id + resolution) or by itself when its condition cleared';
comment on column fabula.bot_messages.action_url is 'v1.00b (audit E-08): relative link to the page that deals with the message, e.g. console.html#oggi&appr=<id>';
create index if not exists bot_messages_open on fabula.bot_messages (created_at desc) where read_at is null;
create index if not exists bot_messages_approval on fabula.bot_messages (approval_id) where approval_id is not null and read_at is null;

create table if not exists fabula.bot_message_reads (
  message_id bigint not null references fabula.bot_messages(id) on delete cascade,
  staff_id   uuid   not null references fabula.staff(id) on delete cascade,
  read_at    timestamptz not null default now(),
  primary key (message_id, staff_id)
);
create index if not exists bot_message_reads_staff on fabula.bot_message_reads (staff_id, message_id);
comment on table fabula.bot_message_reads is 'v1.00b (audit E-04/C-12): who has read which bot message. Written only through mark_bot_messages_read / resolve_bot_messages';
alter table fabula.bot_message_reads enable row level security;
drop policy if exists bot_message_reads_select on fabula.bot_message_reads;
create policy bot_message_reads_select on fabula.bot_message_reads for select to authenticated using ((select fabula.can('sistema', 1)));
revoke insert, update, delete, truncate on fabula.bot_message_reads from anon, authenticated;
-- the messages themselves are written only by the database functions (post_bot_message, mark/resolve, triggers): a browser could
-- otherwise PATCH read_at / resolved_by_id and skip the note or sign as someone else (review 14/10)
revoke insert, update, delete, truncate on fabula.bot_messages from anon, authenticated;
grant select on fabula.bot_message_reads to authenticated;
grant all on fabula.bot_message_reads to service_role;

-- ============================================================================================================================
-- 2. Names: the function first (E-13)
-- ============================================================================================================================
alter table fabula.bot_nicknames alter column nickname drop not null;
update fabula.bot_nicknames set nickname = null, updated_at = now() where agent in ('bot_heartbeat', 'prova');   -- Zio Nino ≈ Zio Tonino, Zia Carmela ≈ Zio Carmelo
insert into fabula.bot_nicknames (agent, nickname, title_it, sort) values
  ('sicurezza', null, 'Sicurezza alimentare', 5),
  ('turni', null, 'Turni', 90),
  ('avvisi', null, 'Avvisi della console', 95),
  ('masseria', null, 'Masseria', 96),
  ('configurazione', null, 'Configurazione', 97)
on conflict (agent) do update set title_it = excluded.title_it, updated_at = now();
update fabula.bot_nicknames set title_it = 'Resa e lotti aperti', updated_at = now() where agent = 'produzione';
update fabula.bot_nicknames set title_it = 'Tablet', updated_at = now() where agent = 'tablet';

-- what the bot does, in the floor's words (no persona)
create or replace function fabula.bot_title(p_agent text) returns text
language sql stable security definer set search_path = fabula, public as $$
  select coalesce((select name_it from fabula.bot_schedule where agent = p_agent),
                  (select title_it from fabula.bot_nicknames where agent = p_agent),
                  case p_agent when 'bot_watchdog' then 'Allarme bot' when 'bot_heartbeat' then 'Battito bot' when 'avvisi' then 'Avvisi della console'
                               else initcap(replace(p_agent, '_', ' ')) end)
$$;
revoke all on function fabula.bot_title(text) from public, anon;
grant execute on function fabula.bot_title(text) to authenticated, service_role;

-- «Piano latte · Zio Gennaro»: the function first, the nickname (when there is one) after
create or replace function fabula.bot_display_name(p_agent text) returns text
language sql stable security definer set search_path = fabula, public as $$
  select fabula.bot_title(p_agent) || coalesce(' · ' || (select nickname from fabula.bot_nicknames where agent = p_agent and nickname is not null), '')
$$;

-- ============================================================================================================================
-- 3. Links (E-08): only the app's own pages, never an address written by a bot
-- ============================================================================================================================
create or replace function fabula.safe_link(p text) returns text
language sql immutable set search_path = fabula, public as $$
  select case when p ~ '^(index|console|haccp|admin|ingrosso|vendite|marketing|latte|consorzio|labels|registro)\.html(#[A-Za-z0-9=&:._-]{0,120})?$' then p end
$$;

create or replace function fabula.bot_default_link(p_agent text) returns text
language sql immutable set search_path = fabula, public as $$
  select case
    when p_agent in ('milk_planning', 'procurement', 'sell_down', 'auto_approve', 'daily_brief', 'masseria') then 'console.html#oggi'
    when p_agent = 'wholesale_orders' then 'ingrosso.html#consegne'
    when p_agent in ('haccp_nudge', 'sicurezza', 'monthly_review') then 'haccp.html#registri'
    when p_agent = 'produzione' then 'console.html#ops'
    when p_agent = 'compliance_calendar' then 'admin.html#maint'
    when p_agent in ('ops_health', 'bot_watchdog', 'bot_heartbeat', 'backup_export', 'avvisi') then 'admin.html#bots'
    when p_agent = 'shopify_customers' then 'console.html#anag'
    when p_agent in ('shopify_orders', 'shopify_inventory') then 'console.html#ops'
    when p_agent = 'sales' then 'vendite.html#oggi'
    when p_agent in ('marketing', 'predis') then 'marketing.html#oggi'
    when p_agent = 'turni' then 'console.html#personale'
    when p_agent = 'configurazione' then 'admin.html#parametri'
    when p_agent = 'invite_user' then 'admin.html#utenti'
    when p_agent = 'prova' then 'admin.html#panoramica'
  end
$$;

create or replace function fabula.link_label(p_link text) returns text
language sql immutable set search_path = fabula, public as $$
  select case
    when p_link ~ '#oggi&appr=' then 'Apri la richiesta'
    when p_link like 'console.html%' then 'Apri la Console'
    when p_link like 'haccp.html%' then 'Apri Autocontrollo'
    when p_link like 'admin.html#bots%' then 'Apri i bot'
    when p_link like 'admin.html%' then 'Apri Configurazione'
    when p_link like 'ingrosso.html%' then 'Apri Ingrosso'
    when p_link like 'vendite.html%' then 'Apri Vendite'
    when p_link like 'marketing.html%' then 'Apri Marketing'
    when p_link like 'index.html%' then 'Apri il tablet'
    else 'Apri' end
$$;

-- where a notice is dealt with (office side)
create or replace function fabula.notice_link(p_key text) returns text
language sql immutable set search_path = fabula, public as $$
  select case
    when p_key like 'haccp_evening%' or p_key like 'lot_guard%' then 'haccp.html#registri'
    when p_key like 'lab_lot_unknown%' then 'haccp.html#analisi'
    when p_key in ('bot_alert', 'bot_heartbeat') then 'admin.html#bots'
    when p_key ~ '^(infra_|outside_watcher|offsite_backup)' then 'admin.html#panoramica'
    when p_key = 'recon' then 'console.html#incassi'
    when p_key = 'trade_applications' then 'ingrosso.html#richieste'
    when p_key like 'milk_weight%' then 'console.html#ops'
  end
$$;
revoke all on function fabula.safe_link(text), fabula.bot_default_link(text), fabula.link_label(text), fabula.notice_link(text) from public, anon;
grant execute on function fabula.safe_link(text), fabula.bot_default_link(text), fabula.link_label(text), fabula.notice_link(text) to authenticated, service_role;

-- the bots' one call: same five arguments as before, plus an optional link (a page of the app) and its label
drop function if exists fabula.post_bot_message(text, text, text, text, uuid);
create function fabula.post_bot_message(p_agent text, p_severity text, p_title text, p_body text, p_run_id uuid default null,
                                        p_link text default null, p_link_label text default null) returns bigint
language plpgsql security definer set search_path = fabula, public as $$
declare v_id bigint; v_sev text := case when p_severity in ('info','warn','alert') then p_severity else 'info' end;
        v_link text := fabula.safe_link(nullif(trim(p_link), '')); v_appr uuid;
begin
  -- a milk plan or a promo links to its own card, and the message closes when that request is decided (E-05)
  if p_agent in ('milk_planning', 'sell_down') then
    select a.id into v_appr from fabula.approvals a
     where a.status = 'pending' and a.requested_at > now() - interval '3 hours'
       and fabula.approval_type(a.kind, a.payload) = case p_agent when 'milk_planning' then 'milk_plan' else 'sell_down' end
     order by a.requested_at desc limit 1;
    if v_appr is not null and v_link is null then v_link := 'console.html#oggi&appr=' || v_appr; end if;
  end if;
  v_link := coalesce(v_link, fabula.bot_default_link(p_agent));
  select id into v_id from fabula.bot_messages
   where agent = p_agent and source = 'auto' and created_at > now() - interval '90 minutes'
   order by created_at desc limit 1;
  if v_id is not null then
    update fabula.bot_messages set severity = v_sev, title = coalesce(nullif(p_title, ''), title), body = p_body, source = 'bot',
           run_id = coalesce(p_run_id, run_id), read_at = null, read_by = null, created_at = now(),
           resolved_at = null, resolved_by_id = null, resolution = null,
           action_url = v_link, action_label = coalesce(nullif(trim(p_link_label), ''), fabula.link_label(v_link)), approval_id = coalesce(v_appr, approval_id)
     where id = v_id;
    delete from fabula.bot_message_reads where message_id = v_id;       -- new content: unread again for everyone
  else
    insert into fabula.bot_messages (agent, run_id, severity, title, body, source, action_url, action_label, approval_id)
    values (p_agent, p_run_id, v_sev, coalesce(nullif(p_title, ''), fabula.bot_display_name(p_agent)), p_body, 'bot',
            v_link, coalesce(nullif(trim(p_link_label), ''), fabula.link_label(v_link)), v_appr)
    returning id into v_id;
  end if;
  return v_id;
end $$;
revoke all on function fabula.post_bot_message(text, text, text, text, uuid, text, text) from public, anon, authenticated;
grant execute on function fabula.post_bot_message(text, text, text, text, uuid, text, text) to service_role;

-- every message written by the database itself gets the default link of its agent (or of its notice)
create or replace function fabula.trg_bot_message_link() returns trigger
language plpgsql set search_path = fabula, public as $$
begin
  if new.action_url is null then
    new.action_url := coalesce(case when new.notice_key is not null then fabula.notice_link(new.notice_key) end,
                               -- the tablet's refused saves are listed in Autocontrollo; its version and queue messages are fixed on the tablet itself
                               case when new.agent = 'tablet' and new.title ~* 'rifiutat' then 'haccp.html#registri' end,
                               fabula.bot_default_link(new.agent));
  else
    new.action_url := fabula.safe_link(new.action_url);
  end if;
  if new.action_url is not null and new.action_label is null then new.action_label := fabula.link_label(new.action_url); end if;
  return new;
end $$;
revoke all on function fabula.trg_bot_message_link() from public, anon, authenticated;
drop trigger if exists bot_messages_link on fabula.bot_messages;
create trigger bot_messages_link before insert or update of action_url on fabula.bot_messages for each row execute function fabula.trg_bot_message_link();
update fabula.bot_messages set action_url = null where read_at is null and action_url is null;   -- fills the links of the open messages (trigger)

-- ============================================================================================================================
-- 4. Telegram: the message's own link instead of the topic's page; the topic of food-safety senders (E-13)
-- ============================================================================================================================
drop function if exists fabula.notify_html(text, text, text, text, timestamptz);
create function fabula.notify_html(p_topic text, p_title text, p_body text, p_sender text, p_at timestamptz, p_link text default null) returns text
language plpgsql stable set search_path = fabula, public as $$
declare v_site text := rtrim(coalesce(nullif(fabula.setting_text('infra.site_url'), ''), ''), '/'); v_b text; v_page text;
begin
  v_b := replace(replace(replace(coalesce(p_body, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
  v_b := regexp_replace(v_b, '\*\*([^*\n]+)\*\*', '<b>\1</b>', 'g');
  if length(v_b) > 3000 then v_b := left(v_b, 3000) || ' …'; end if;
  v_page := coalesce('/' || fabula.safe_link(p_link), case p_topic when 'food_safety' then '/haccp.html' when 'infra' then '/admin.html' else '/console.html' end);
  return concat_ws(E'\n',
    case p_topic when 'food_safety' then '⚠ <b>SICUREZZA ALIMENTARE</b>' when 'infra' then '🔧 <b>Sistema</b>' when 'decisions' then '📌 <b>Da decidere</b>' else '🔔 <b>Prova</b>' end,
    '<b>' || replace(replace(replace(p_title, '&', '&amp;'), '<', '&lt;'), '>', '&gt;') || '</b>',
    nullif(v_b, ''),
    '',
    '<i>' || replace(replace(replace(coalesce(p_sender, 'Caseificio'), '&', '&amp;'), '<', '&lt;'), '>', '&gt;') || ' · ' || to_char(p_at at time zone 'Europe/Rome', 'DD/MM HH24:MI') || '</i>'
      || case when v_site <> '' then ' · <a href="' || v_site || replace(v_page, '"', '') || '">apri</a>' else '' end);
end $$;
revoke all on function fabula.notify_html(text, text, text, text, timestamptz, text) from public, anon, authenticated;

drop function if exists fabula.notify_enqueue(text, text, text, text, text, text, text, uuid);
create function fabula.notify_enqueue(p_topic text, p_title text, p_body text, p_sender text, p_source text default null, p_ref text default null,
                                      p_dedupe text default null, p_parent uuid default null, p_link text default null) returns uuid
language plpgsql security definer set search_path = fabula, public as $$
declare v_id uuid; v_min int := greatest(coalesce(fabula.setting_num('notify.escalate_min', 30), 30)::int, 5);
begin
  if p_dedupe is not null and exists (select 1 from fabula.notify_outbox where dedupe_key = p_dedupe and created_at > now() - interval '3 hours') then
    return null;
  end if;
  insert into fabula.notify_outbox (topic, title, body, sender, source, source_ref, dedupe_key, text_html, parent_id, escalate_at)
  values (p_topic, left(coalesce(nullif(p_title, ''), 'Avviso'), 200), p_body, p_sender, p_source, p_ref, p_dedupe,
          fabula.notify_html(p_topic, coalesce(nullif(p_title, ''), 'Avviso'), p_body, p_sender, now(), p_link), p_parent,
          case when p_parent is null and p_topic in ('food_safety', 'decisions') then now() + make_interval(mins => v_min) end)
  returning id into v_id;
  perform fabula.notify_route(v_id, p_parent is not null);
  return v_id;
end $$;
revoke all on function fabula.notify_enqueue(text, text, text, text, text, text, text, uuid, text) from public, anon, authenticated;
grant execute on function fabula.notify_enqueue(text, text, text, text, text, text, text, uuid, text) to service_role;

create or replace function fabula.notify_topic_for(p_agent text, p_text text, p_key text default null) returns text
language sql immutable set search_path = fabula, public as $$
  select case
    -- v1.00b: who speaks for food safety is food safety, whatever the words (and the evening HACCP list is never held for quiet hours)
    when p_agent in ('sicurezza', 'haccp_nudge', 'nc') or coalesce(p_key, '') ~ '^(haccp_evening|lot_guard|lab_lot_unknown)' then 'food_safety'
    -- the evening check can carry food-safety lines (marked ⚠ by the message rules) among system ones
    when p_agent = 'ops_health' and coalesce(p_text, '') ~ '⚠' then 'food_safety'
    when p_agent = 'tablet' and coalesce(p_text, '') ~* 'rifiutat' then 'food_safety'   -- records lost on the floor: to redo today
    -- infrastructure: «haccp_nudge non è partito» or «backup bloccato» are about the system, not the food
    when coalesce(p_key, '') ~ '^(bot_|infra_|outside_watcher|offsite_backup)'
      or p_agent in ('ops_health', 'bot_watchdog', 'bot_heartbeat', 'backup_export', 'restore_drill', 'invite_user', 'predis', 'infra', 'tablet', 'configurazione') then 'infra'
    when coalesce(p_text, '') ~* '(⚠|\mCCP|HACCP|respint|lott[oi]\s+(\S+\s+)?bloccat|non conform|richiam|ritiro|antibiotic|fuori limite|sicurezza alimentare|cella frigo|pastorizz|filatura)'
      then 'food_safety'
    else 'decisions' end
$$;

create or replace function fabula.trg_notify_bot_message() returns trigger
language plpgsql security definer set search_path = fabula, public as $$
begin
  if new.severity <> 'alert' or new.title like 'SIMULAZIONE%' or new.notice_key is not null or new.read_at is not null then return null; end if;
  if tg_op = 'UPDATE' and old.severity = 'alert' and old.title is not distinct from new.title and old.body is not distinct from new.body then return null; end if;
  -- a failed bot run: the watchdog sends one Telegram per incident (E-33), not this alarm as well
  if new.run_id is not null and exists (select 1 from fabula.agent_runs ar where ar.id = new.run_id and ar.status = 'error') then return null; end if;
  begin
    perform fabula.notify_enqueue(fabula.notify_topic_for(new.agent, new.title || ' ' || coalesce(new.body, '')), new.title, new.body,
                                  fabula.bot_display_name(new.agent), 'bot_messages', new.id::text, 'bm:' || new.agent || ':' || md5(new.title),
                                  null, new.action_url);
  exception when others then raise warning 'notify (bot_messages %): %', new.id, sqlerrm;
  end;
  return null;
end $$;

create or replace function fabula.trg_notify_notice() returns trigger
language plpgsql security definer set search_path = fabula, public as $$
declare v_body text;
begin
  if new.severity <> 'alert' or new.resolved_at is not null then return null; end if;
  if new.key in ('bot_alert', 'bot_heartbeat') then return null; end if;   -- v1.00c: one Telegram per bot incident, sent by the watchdog
  if tg_op = 'UPDATE' and old.severity = 'alert' and old.resolved_at is null and old.title_it is not distinct from new.title_it then return null; end if;
  begin
    select string_agg('- ' || coalesce(i ->> 'label_it', i ->> 'text', i::text), E'\n') into v_body
      from jsonb_array_elements(case when jsonb_typeof(new.items) = 'array' then new.items else '[]'::jsonb end) i;
    perform fabula.notify_enqueue(fabula.notify_topic_for('notice', new.title_it || ' ' || coalesce(v_body, ''), new.key),
                                  new.title_it, v_body, 'Avviso', 'notices', new.key, 'nt:' || new.key || ':' || md5(new.title_it),
                                  null, fabula.notice_link(new.key));
  exception when others then raise warning 'notify (notices %): %', new.key, sqlerrm;
  end;
  return null;
end $$;

-- ============================================================================================================================
-- 5. Reading, resolving, the bell (E-04 / C-12)
-- ============================================================================================================================
-- «Segna come letta»: for me only. Without ids («Segna tutto come letto») it never touches an alarm.
create or replace function fabula.mark_bot_messages_read(p_ids bigint[] default null) returns integer
language plpgsql security definer set search_path = fabula, public as $$
declare n int; v_me uuid := fabula.my_staff_id();
begin
  perform fabula.require_perm('sistema', 1);
  if v_me is null then return 0; end if;
  insert into fabula.bot_message_reads (message_id, staff_id)
  select m.id, v_me from fabula.bot_messages m
   where m.read_at is null
     and (case when p_ids is null then m.severity <> 'alert' else m.id = any (p_ids) end)
  on conflict do nothing;
  get diagnostics n = row_count; return n;
end $$;

-- «Risolto»: closes an alarm (or any message) for everyone, with what was done; the Telegram reminders for it stop
create or replace function fabula.resolve_bot_messages(p_ids bigint[], p_note text) returns integer
language plpgsql security definer set search_path = fabula, public as $$
declare n int; v_me uuid := fabula.my_staff_id();
begin
  perform fabula.require_perm('sistema', 3);
  if length(coalesce(trim(p_note), '')) < 3 then
    raise exception using errcode = '22023', message = 'Scrivi cosa è stato fatto (es. «ricopiato da carta», «lotto valutato con il consulente»)';
  end if;
  if coalesce(cardinality(p_ids), 0) = 0 then raise exception using errcode = '22023', message = 'Nessun messaggio scelto'; end if;
  -- a notice's copy is not closed here: the notice closes by itself when what it lists is fixed (and a copy closed alone came back)
  if not exists (select 1 from fabula.bot_messages where id = any (p_ids) and notice_key is null) then
    raise exception using errcode = '22023', message = 'Questo avviso si chiude da solo quando è sistemato quello che elenca';
  end if;
  update fabula.bot_messages set resolved_at = now(), resolved_by_id = v_me, resolution = left(trim(p_note), 300), read_at = coalesce(read_at, now()), read_by = coalesce(read_by, v_me)
   where id = any (p_ids) and resolved_at is null and notice_key is null;
  get diagnostics n = row_count;
  if v_me is not null then
    insert into fabula.bot_message_reads (message_id, staff_id) select x, v_me from unnest(p_ids) x
     where exists (select 1 from fabula.bot_messages m where m.id = x) on conflict do nothing;
  end if;
  update fabula.notify_outbox set acked_at = now(), acked_by_id = v_me
   where source = 'bot_messages' and source_ref in (select x::text from unnest(p_ids) x) and acked_at is null;
  return n;
end $$;
revoke all on function fabula.resolve_bot_messages(bigint[], text) from public, anon;
grant execute on function fabula.resolve_bot_messages(bigint[], text) to authenticated, service_role;

-- the feed as I see it: read by me?, who saw it, who resolved it
create or replace view fabula.v_bot_feed with (security_invoker = true) as
select m.id, m.agent, m.run_id, m.created_at, m.severity, m.title, m.body, m.source, m.notice_key, m.read_at,
       m.resolved_at, m.resolution, m.action_url, m.action_label, m.approval_id,
       fabula.bot_title(m.agent) as agent_title,
       (select nickname from fabula.bot_nicknames n where n.agent = m.agent) as agent_nickname,
       (select full_name from fabula.staff s where s.id = m.resolved_by_id) as resolved_by,
       exists (select 1 from fabula.bot_message_reads r where r.message_id = m.id and r.staff_id = fabula.my_staff_id()) as read_by_me,
       (select string_agg(s.full_name || ' ' || to_char(r.read_at at time zone 'Europe/Rome', 'DD/MM HH24:MI'), ' · ' order by r.read_at)
          from fabula.bot_message_reads r join fabula.staff s on s.id = r.staff_id where r.message_id = m.id) as seen_by,
       (m.read_at is null and (m.severity = 'alert' or not exists (select 1 from fabula.bot_message_reads r where r.message_id = m.id and r.staff_id = fabula.my_staff_id()))) as for_me
  from fabula.bot_messages m;
grant select on fabula.v_bot_feed to authenticated, service_role;

-- the bot cards (Configurazione → Bot): «nuove» = open alarms + what I have not read
create or replace view fabula.v_bot_dashboard with (security_invoker = true) as
 SELECT b.agent, b.name_it, b.active, b.due_times, b.weekdays, b.month_day,
    lr.status AS last_status, lr.started_at AS last_run_at, lr.summary AS last_summary,
    ( SELECT count(*) FROM fabula.bot_messages m
       WHERE m.agent = b.agent AND m.read_at IS NULL
         AND (m.severity = 'alert' OR NOT EXISTS (SELECT 1 FROM fabula.bot_message_reads r WHERE r.message_id = m.id AND r.staff_id = fabula.my_staff_id()))) AS unread,
    ( SELECT count(*) FROM fabula.bot_messages m WHERE m.agent = b.agent AND m.read_at IS NULL AND m.severity = 'alert') AS unread_alerts,
    lm.title AS last_title, lm.severity AS last_severity, lm.created_at AS last_message_at,
    nk.nickname,
    fabula.bot_display_name(b.agent) AS display_name
   FROM fabula.bot_schedule b
     LEFT JOIN fabula.bot_nicknames nk ON nk.agent = b.agent
     LEFT JOIN LATERAL ( SELECT r.status, r.started_at, r.summary FROM fabula.agent_runs r WHERE r.agent = b.agent ORDER BY r.started_at DESC LIMIT 1) lr ON true
     LEFT JOIN LATERAL ( SELECT m.title, m.severity, m.created_at FROM fabula.bot_messages m WHERE m.agent = b.agent ORDER BY m.created_at DESC LIMIT 1) lm ON true;

-- the bell: open alarms first, then what I have not read
create or replace function fabula.bot_bell() returns jsonb
language sql stable security invoker set search_path = fabula, public as $$
  select jsonb_build_object(
    'alerts', (select count(*) from fabula.bot_messages m where m.read_at is null and m.severity = 'alert'),
    'unread', (select count(*) from fabula.bot_messages m where m.read_at is null and m.severity <> 'alert'
                 and not exists (select 1 from fabula.bot_message_reads r where r.message_id = m.id and r.staff_id = fabula.my_staff_id())))
$$;
revoke all on function fabula.bot_bell() from public, anon;
grant execute on function fabula.bot_bell() to authenticated, service_role;

-- ============================================================================================================================
-- 6. Closing by itself (E-05, E-04): superseded, decided, condition cleared
-- ============================================================================================================================
create or replace function fabula.bot_messages_autoread(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = fabula, public as $$
declare n int; m int; k int; j int;
begin
  update fabula.bot_messages set read_at = p_now
   where read_at is null and severity = 'info' and created_at < p_now - interval '24 hours';
  get diagnostics n = row_count;
  -- v0.87: a banner that has expired or been resolved is no longer news (v1.00b: an alarm copy says it cleared by itself)
  update fabula.bot_messages b set read_at = p_now,
         resolved_at = case when b.severity = 'alert' then p_now end, resolution = case when b.severity = 'alert' then 'rientrato da solo (avviso chiuso)' end
   where b.read_at is null and b.source = 'notice' and b.notice_key is not null
     and not exists (select 1 from fabula.notices x where x.key = b.notice_key and x.resolved_at is null and (x.expires_at is null or x.expires_at > p_now));
  get diagnostics m = row_count;
  -- v1.00b (E-05): a scheduled bot's routine message (info/warn) is closed by its next message (each run says the whole situation
  -- again); an alarm stays until someone marks it «Risolto» or what it was about clears by itself
  update fabula.bot_messages b set read_at = p_now
   where b.read_at is null and b.source in ('bot', 'auto') and b.severity in ('info', 'warn')
     and b.agent in (select agent from fabula.bot_schedule)
     and exists (select 1 from fabula.bot_messages x
                  where x.agent = b.agent and x.source in ('bot', 'auto') and x.created_at > b.created_at + interval '30 minutes');
  get diagnostics k = row_count;
  -- v1.00b (E-05): a milk plan or promo message closes once its request is decided or expired
  update fabula.bot_messages b set read_at = p_now,
         resolved_at = case when b.severity = 'alert' then p_now end,
         resolution = case when b.severity = 'alert' then 'richiesta ' || case a.status when 'approved' then 'approvata' when 'rejected' then 'rifiutata' else 'scaduta' end end
    from fabula.approvals a
   where b.read_at is null and b.approval_id = a.id and a.status <> 'pending';
  get diagnostics j = row_count;
  return n + m + k + j;
end $$;

-- the decision closes its message at once, not at the next hourly pass
create or replace function fabula.trg_approval_close_messages() returns trigger
language plpgsql security definer set search_path = fabula, public as $$
begin
  if new.status is distinct from old.status and new.status <> 'pending' then
    update fabula.bot_messages set read_at = now(),
           resolved_at = case when severity = 'alert' then now() end,
           resolution = case when severity = 'alert' then 'richiesta ' || case new.status when 'approved' then 'approvata' when 'rejected' then 'rifiutata' else 'scaduta' end
                                                       || coalesce(' da ' || new.decided_by, '') end
     where approval_id = new.id and read_at is null;
  end if;
  return null;
end $$;
revoke all on function fabula.trg_approval_close_messages() from public, anon, authenticated;
drop trigger if exists approvals_close_messages on fabula.approvals;
create trigger approvals_close_messages after update of status on fabula.approvals for each row execute function fabula.trg_approval_close_messages();

-- ============================================================================================================================
-- 7. Who speaks (E-13): food safety, rota; failure and stand-in wording (E-20/E-21)
-- ============================================================================================================================
do $mig$
declare d text; n text;
begin
  -- lot closed without its CCP: «Sicurezza alimentare», not «Resa produzione»
  d := pg_get_functiondef('fabula.trg_batch_ccp_check'::regproc);
  n := replace(d, $o$perform fabula.post_bot_message('produzione', 'alert',$o$, $n$perform fabula.post_bot_message('sicurezza', 'alert',$n$);
  if n = d then raise exception 'v100b: trg_batch_ccp_check pattern not found'; end if;
  execute n;

  -- milk rejected, lots held
  d := pg_get_functiondef('fabula.milk_reject(uuid, text, uuid, uuid, text)'::regprocedure);
  n := replace(d, $o$perform fabula.post_bot_message('produzione', 'alert',$o$, $n$perform fabula.post_bot_message('sicurezza', 'alert',$n$);
  if n = d then raise exception 'v100b: milk_reject pattern not found'; end if;
  execute n;

  -- milk close to the 60 h DOP limit: food safety; open lots alone stay with production
  d := pg_get_functiondef('fabula.prod_watch'::regproc);
  n := replace(d, $o$if exists (select 1 from fabula.bot_messages where agent = 'produzione' and title = v_title)$o$,
                  $n$if exists (select 1 from fabula.bot_messages where agent in ('produzione', 'sicurezza') and title = v_title)$n$);
  n := replace(n, $o$perform fabula.post_bot_message('produzione', 'warn', v_title,$o$,
                  $n$perform fabula.post_bot_message(case when n_milk > 0 then 'sicurezza' else 'produzione' end, 'warn', v_title,$n$);
  if n = d or n !~ 'sicurezza' then raise exception 'v100b: prod_watch patterns not found'; end if;
  execute n;

  -- refused tablet saves: HACCP ones are food safety; no table names in the text; where to find them
  d := pg_get_functiondef('fabula.device_checkin'::regproc);
  n := replace(d, $o$perform fabula.post_bot_message('tablet', 'alert',$o$,
                  $n$perform fabula.post_bot_message(case when exists (select 1 from jsonb_array_elements(v_new) x
                                                         where x->>'what' ~ '^(log_ccp|log_milk_check|haccp_log|close_open_task|milk_intake|record_receipt_check|log_batch_step|effluent_log)$')
                                                    then 'sicurezza' else 'tablet' end, 'alert',$n$);
  n := replace(n, $o$Sono salvate per intero in fabula.tablet_rejects: vanno rifatte a mano o corrette (chiedi a chi le ha registrate). Se è una registrazione HACCP (CCP, temperature, pulizie) va rifatta oggi.$o$,
                  $n$Le trovi in Autocontrollo → Registri → «Registrazioni rifiutate»: vanno rifatte (dal tablet, 🛡 → Ricopia da foglio di carta, con l''ora vera) o corrette, poi «Segna come rifatta». Se è una registrazione HACCP (CCP, temperature, pulizie) va rifatta oggi.$n$);
  if n = d or n !~ 'sicurezza' or n ~ 'fabula\.tablet_rejects:' then raise exception 'v100b: device_checkin patterns not found'; end if;
  execute n;

  -- rota copies: «Turni», not «Approvazioni automatiche»
  d := pg_get_functiondef('fabula.rota_autocopy'::regproc);
  n := replace(d, $o$perform fabula.post_bot_message('auto_approve', 'info',$o$, $n$perform fabula.post_bot_message('turni', 'info',$n$);
  if n = d then raise exception 'v100b: rota_autocopy pattern not found'; end if;
  execute n;

  -- a database stand-in: the alerts do reach Telegram now; say what was done
  d := pg_get_functiondef('fabula.bot_fallback'::regproc);
  n := replace(d, $o$Il bot "%s" non è partito alle %s: il database ha fatto il suo lavoro. Le notifiche del bot non sono partite: è tutto qui sotto.\n\n%s$o$,
                  $n$Il bot "%s" delle %s non ha fatto il suo lavoro (non è partito o ha dato errore): il database l''ha fatto al suo posto, con i numeri e senza il commento del bot. Gli allarmi arrivano comunque su Telegram.\n\n%s$n$);
  -- …and a bot that started but failed is stood in for too (its error row used to count as «ran», so nothing ran; review 14/10)
  n := replace(n, $o$continue when exists (select 1 from fabula.agent_runs ar where ar.agent = r.agent and ar.started_at >= v_due - interval '30 minutes'$o$,
                  $n$continue when exists (select 1 from fabula.agent_runs ar where ar.agent = r.agent and ar.started_at >= v_due - interval '30 minutes' and ar.status is distinct from 'error'$n$);
  if n = d or n !~ 'ar.status is distinct from ''error''' then raise exception 'v100b: bot_fallback patterns not found'; end if;
  execute n;
end $mig$;

-- a failed run says what happens next (E-21) and links to the bots
create or replace function fabula.trg_agent_run_message() returns trigger
language plpgsql security definer set search_path = fabula, public as $$
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
    if new.status = 'error' then
      update fabula.bot_messages set severity = 'alert', read_at = null, read_by = null, resolved_at = null, resolved_by_id = null, resolution = null where id = v_id;
    end if;
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
    v_title := fabula.bot_title(new.agent) || ': non riuscito';
    v_body  := 'Errore: ' || left(v_err, 400) || E'\n'
      || case when new.agent = any (fabula.bot_fallback_agents()) and coalesce(new.details->>'via', '') <> 'db_fallback'
              then 'Se il bot non riparte, il database fa il suo lavoro da solo poco dopo l''orario. Per farlo subito: Configurazione → Bot → «Esegui ora».'
              when coalesce(new.details->>'via', '') = 'db_fallback'
              then 'Anche il database non ci è riuscito: riprova da Configurazione → Bot → «Esegui ora»; se l''errore resta, chiama chi gestisce il sistema.'
              else 'Il bot riprova al prossimo orario. Se tutti i bot si fermano: vedi «Bot fermi: cosa fare» (Configurazione → Bot).' end;
  elsif new.agent = 'backup_export' then
    v_title := 'Backup di stanotte fatto';
    v_body  := 'Copia completa del database salvata'
               || coalesce(' (' || substring(new.summary from '(\d+ tabelle, \d+ righe)') || ')', '') || '.';
  else
    v_title := fabula.bot_title(new.agent);
    v_body  := coalesce(nullif(new.summary, ''), 'Eseguito');
  end if;

  insert into fabula.bot_messages (agent, run_id, severity, title, body, source, action_url)
  values (new.agent, new.id, case when new.status = 'error' then 'alert' else 'info' end, v_title, v_body, 'auto',
          case when new.status = 'error' then 'admin.html#bots' end);
  return new;
end $$;

-- ============================================================================================================================
-- 8. Security check: the new definer functions check the caller inside
-- ============================================================================================================================
insert into fabula.security_accepted (key, reason, accepted_at) values
 ('authenticated_security_definer_function_executable:fabula.resolve_bot_messages(p_ids bigint[], p_note text)',
  'by design (v1.00b, audit E-04/C-12): require_perm(sistema, 3) first; a note is required; signer from the login', now()),
 ('authenticated_security_definer_function_executable:fabula.bot_title(p_agent text)',
  'by design (v1.00b): read-only, returns a bot''s title (same as bot_display_name)', now())
on conflict (key) do update set reason = excluded.reason, accepted_at = excluded.accepted_at;
