-- v0.46 Bot nicknames — display only.
-- Agent keys (agent_runs.agent, bot_schedule.agent, expected_bots, bot_alerts, prompts) are NOT changed.
-- Nicknames live in their own table; bot_schedule.name_it stays the official Italian title.
-- Display everywhere = "<nickname> · <official title>" via fabula.bot_display_name(agent).

create table if not exists fabula.bot_nicknames (
  agent      text primary key,          -- same key the bot logs with; never renamed
  nickname   text not null,
  title_it   text not null,             -- official title (used only when the agent has no bot_schedule row)
  sort       int  not null default 100,
  updated_at timestamptz not null default now()
);
comment on table fabula.bot_nicknames is 'Display-only nicknames for bots (Zio/Zia). Never used for matching; agent keys stay unchanged.';

alter table fabula.bot_nicknames enable row level security;
insert into fabula.table_areas(table_name, area, write_level, read_open)
values ('bot_nicknames', 'sistema', 3, true)
on conflict (table_name) do nothing;

do $$
declare t text := 'bot_nicknames';
begin
  if not exists (select 1 from pg_policies where schemaname='fabula' and tablename=t and policyname=t||'_read') then
    execute format('create policy %I on fabula.%I for select to authenticated using (true)', t||'_read', t);
    execute format('create policy %I on fabula.%I for insert to authenticated with check (true)', t||'_insert', t);
    execute format('create policy %I on fabula.%I for update to authenticated using (true)', t||'_update', t);
    execute format('create policy %I on fabula.%I as restrictive for select to authenticated using ((select fabula.can_table(%L, false)))', t||'_role_select', t, t);
    execute format('create policy %I on fabula.%I as restrictive for insert to authenticated with check ((select fabula.can_table(%L, true)))', t||'_role_insert', t, t);
    execute format('create policy %I on fabula.%I as restrictive for update to authenticated using ((select fabula.can_table(%L, true)))', t||'_role_update', t, t);
  end if;
end $$;

insert into fabula.bot_nicknames(agent, nickname, title_it, sort) values
  ('daily_brief',        'Zio Orazio',     'Brief del mattino',        10),
  ('weekly_brief',       'Zio Arturo',     'Brief settimanale',        20),
  ('monthly_review',     'Zio Pasquale',   'Revisione mensile',        30),
  ('milk_planning',      'Zio Gennaro',    'Piano latte',              40),
  ('procurement',        'Zio Gaetano',    'Acquisti',                 50),
  ('sell_down',          'Zio Carmelo',    'Da vendere prima',         60),
  ('haccp_nudge',        'Zia Filomena',   'Chiusura serata',          70),
  ('compliance_calendar','Zia Barbara',    'Manutenzioni e scadenze',  80),
  ('ops_health',         'Zio Giorgio',    'Controllo sistema',        90),
  ('bot_watchdog',       'Zio Vito',       'Allarme bot',             100),
  ('bot_heartbeat',      'Zio Nino',       'Battito bot',             110),
  ('backup_export',      'Zio Fonso',      'Backup notturno',         120),
  ('shopify_customers',  'Zio Luigi',      'Clienti Shopify',         130),
  ('shopify_orders',     'Zio Checco',     'Ordini Shopify',          140),
  ('wholesale_orders',   'Zio Peppo',      'Ordini ingrosso',         150),
  ('sales',              'Zio Tano',       'Vendite',                 160),
  ('marketing',          'Zio Arsenio',    'Marketing',               170),
  ('predis',             'Zia Gelsomina',  'Contenuti social (Predis)',180),
  ('invite_user',        'Zia Assunta',    'Inviti utenti',           190),
  ('shopify_inventory',  'Zio Fausto',     'Giacenze Shopify',        200)
on conflict (agent) do update set nickname = excluded.nickname, title_it = excluded.title_it, sort = excluded.sort, updated_at = now();

-- Display name: "Zio Gennaro · Piano latte". Falls back to the old behaviour when no nickname exists.
create or replace function fabula.bot_display_name(p_agent text)
 returns text
 language sql
 stable security definer
 set search_path to 'fabula', 'public'
as $function$
  select coalesce((select nickname || ' · ' from fabula.bot_nicknames where agent = p_agent), '') ||
    coalesce((select name_it from fabula.bot_schedule where agent = p_agent),
             (select title_it from fabula.bot_nicknames where agent = p_agent),
    case p_agent when 'bot_watchdog' then 'Allarme bot' when 'bot_heartbeat' then 'Battito bot' when 'avvisi' then 'Avvisi console' else initcap(replace(p_agent, '_', ' ')) end)
$function$;

-- Bot dashboard view: same columns as before + nickname, display_name at the end.
create or replace view fabula.v_bot_dashboard with (security_invoker = true) as
 SELECT b.agent,
    b.name_it,
    b.active,
    b.due_times,
    b.weekdays,
    b.month_day,
    lr.status AS last_status,
    lr.started_at AS last_run_at,
    lr.summary AS last_summary,
    ( SELECT count(*) AS count
           FROM fabula.bot_messages m
          WHERE m.agent = b.agent AND m.read_at IS NULL) AS unread,
    ( SELECT count(*) AS count
           FROM fabula.bot_messages m
          WHERE m.agent = b.agent AND m.read_at IS NULL AND m.severity = 'alert'::text) AS unread_alerts,
    lm.title AS last_title,
    lm.severity AS last_severity,
    lm.created_at AS last_message_at,
    nk.nickname,
    fabula.bot_display_name(b.agent) AS display_name
   FROM fabula.bot_schedule b
     LEFT JOIN fabula.bot_nicknames nk ON nk.agent = b.agent
     LEFT JOIN LATERAL ( SELECT r.status,
            r.started_at,
            r.summary
           FROM fabula.agent_runs r
          WHERE r.agent = b.agent
          ORDER BY r.started_at DESC
         LIMIT 1) lr ON true
     LEFT JOIN LATERAL ( SELECT m.title,
            m.severity,
            m.created_at
           FROM fabula.bot_messages m
          WHERE m.agent = b.agent
          ORDER BY m.created_at DESC
         LIMIT 1) lm ON true;

-- Watchdog, heartbeat and go-live dashboard: only the human-readable 'name' text changes.
-- Matching/dedup stays on agent (bot_alerts key = agent, kind, ref). Each replacement is checked.
do $$
declare
  v_def text; v_new text;
  r record;
begin
  for r in select * from (values
      ('fabula.bot_watchdog(timestamp with time zone)', 'coalesce(bs.name_it, ar.agent) nm', 'fabula.bot_display_name(ar.agent) nm', 2),
      ('fabula.bot_watchdog(timestamp with time zone)', '''name'', r.name_it', '''name'', fabula.bot_display_name(r.agent)', 1),
      ('fabula.bot_heartbeat(timestamp with time zone)', '''name'', r.name_it', '''name'', fabula.bot_display_name(r.agent)', 1),
      ('fabula.ops_dashboard()', '''name'', s.name_it', '''name'', fabula.bot_display_name(s.agent)', 1)
    ) x(fn, old, new, expected)
  loop
    v_def := pg_get_functiondef(r.fn::regprocedure);
    if (length(v_def) - length(replace(v_def, r.old, ''))) / length(r.old) <> r.expected then
      raise exception 'v046: % — expected % occurrence(s) of [%], found %', r.fn, r.expected, r.old,
        (length(v_def) - length(replace(v_def, r.old, ''))) / length(r.old);
    end if;
    v_new := replace(v_def, r.old, r.new);
    execute v_new;
  end loop;
end $$;

-- Zio Giorgio (ops_health, Mon–Sat 20:36) joins expected_bots so the 7-day bot health counts him.
create or replace function fabula.expected_bots(p_date date) returns table(agent text) language sql immutable set search_path = fabula, public, extensions as $function$
  select a from unnest(array['daily_brief','procurement','wholesale_orders','milk_planning','sell_down','haccp_nudge','ops_health','shopify_customers','shopify_orders','shopify_inventory']) a where extract(isodow from p_date) between 1 and 6
  union all select 'weekly_brief' where extract(isodow from p_date) = 1
  union all select 'compliance_calendar' where extract(isodow from p_date) = 2
  union all select 'marketing' where extract(isodow from p_date) in (1, 4)
  union all select 'sales' where extract(isodow from p_date) in (1, 3, 5)
  union all select 'monthly_review' where extract(day from p_date) = 1
  union all select 'backup_export'
$function$;
