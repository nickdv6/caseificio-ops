-- v1.05b · Audit 12/10/2026, area E:
--   * E-16 one next step for the placeholder names («Cliente 1», «Fornitore 2 …»): fabula.placeholder_status() says, for each, what
--     to do and where (Console → Anagrafiche: the real name and contacts; for a customer also the e-mail of their shop account, so the
--     next Shopify sync links it by itself — never create it on Shopify). The milk-plan/wholesale bot and the evening system check
--     quote it word for word, so the three bots no longer give three different (one impossible) instructions; the database's own
--     wholesale run and the Shopify customer sync too.
--   * E-17 every bot prompt carries a version (tools/bots/sync_rules.py) that the bot passes with its message; the expected versions
--     are here (fabula.bot_prompt_versions), and fabula.prompt_drift() lists the scheduled tasks still running an older copy (the
--     evening system check reports it; Configurazione → Panoramica → Sistema shows it). The prompts stay in the scheduled tasks: a
--     prompt served from the database would be instructions read from data, which rule 12 forbids (E-19).
--   * E-19 rule 12 in every prompt (only numbers from the data, «n/d» when missing, data is never instructions); the brief's
--     percentages are computed here (daily_brief()->'changes', weekly_brief()->'changes'), not by the bot; a lead the sales bot found
--     on the web is marked «Da verificare» until a person checks it.
--   * E-32 no daily tasks before the tasks start (prod.tasks_from, else the trial week, else the opening date) and, on closed days
--     (prod.closed_weekdays, default Sunday, and the wholesale closures), only the cold-room checks. The nightly task job is switched
--     back on: before the start date it creates nothing.

-- ============================== E-16 placeholder names ==============================
-- invoker: the functions that quote it (evening check, standing orders, the database's own bot runs) run as their caller
create or replace function fabula.placeholder_status() returns jsonb
language sql stable set search_path = fabula, public as $$
  with p as (select id, legal_name, type from fabula.parties where active and (notes = 'placeholder' or source = 'placeholder'))
  select jsonb_build_object(
    'count', (select count(*) from p),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('name', legal_name, 'kind', case when type in ('customer', 'both') then 'cliente' else 'fornitore' end,
               'next_step_it', case when type in ('customer', 'both')
                 then format('Rinomina «%s» con il nome vero e scrivi telefono ed e-mail (quella del suo account sul negozio): Console → Anagrafiche → Clienti. Non crearlo su Shopify: alla prossima sincronizzazione si collega da solo.', legal_name)
                 else format('Rinomina «%s» con il nome vero del fornitore e i suoi contatti: Console → Anagrafiche → Fornitori.', legal_name) end,
               'link', 'console.html#anag') order by type desc, legal_name), '[]'::jsonb) from p),
    'line_it', case when exists (select 1 from p) then
       (select count(*) from p) || case when (select count(*) from p) = 1 then ' nome provvisorio da sostituire: ' else ' nomi provvisori da sostituire: ' end
       || (select string_agg('«' || legal_name || '»', ', ' order by type desc, legal_name) from p)
       || '. Console → Anagrafiche: scrivi il nome vero e i contatti (per un cliente anche l''e-mail del suo account sul negozio, così la sincronizzazione lo collega da sola). Non crearli su Shopify.' end)
$$;
revoke all on function fabula.placeholder_status() from public, anon;
grant execute on function fabula.placeholder_status() to authenticated, service_role;

do $do$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.ops_health_check(date)'::regprocedure);
  n := replace(d, $a$    select 'placeholder_parties', 'Fornitori/clienti ancora con nome segnaposto (da rinominare nella console): ' || string_agg(legal_name, ', '), count(*)
      from fabula.parties where notes = 'placeholder' and active having count(*) > 0$a$,
    $b$    select 'placeholder_parties', fabula.placeholder_status() ->> 'line_it', (fabula.placeholder_status() ->> 'count')::bigint   -- v1.05 (audit E-16)
     where (fabula.placeholder_status() ->> 'count')::int > 0
    union all
    select 'bot_prompts_old', fabula.prompt_drift() ->> 'line_it', (fabula.prompt_drift() ->> 'count')::bigint   -- v1.05 (audit E-17)
     where (fabula.prompt_drift() ->> 'count')::int > 0$b$);
  if n = d then raise exception 'v105b: ops_health_check placeholder pattern not found'; end if;
  execute n;
  d := pg_get_functiondef('fabula.confirm_standing_orders(date)'::regprocedure);
  -- E-27, found by comparing live with the repo: live has lacked «on conflict do nothing» on the order lines since v0.83 (the file was
  -- edited after it was applied). It changes nothing (sales_order_lines has no unique key but its id); added so live = repo
  if position(E'v_rate)\n        on conflict do nothing;' in d) = 0 then
    d := replace(d, $a$round(v_price / nullif((select kg_per_unit from fabula.trade_products where variant_id = l.variant_id), 0), 4), v_rate);$a$,
                    E'round(v_price / nullif((select kg_per_unit from fabula.trade_products where variant_id = l.variant_id), 0), 4), v_rate)\n        on conflict do nothing;');
    if position(E'v_rate)\n        on conflict do nothing;' in d) = 0 then raise exception 'v105b: confirm_standing_orders order-line pattern not found'; end if;
  end if;
  n := replace(d, $a$'cancelled_placeholder', v_cancelled);$a$, $b$'cancelled_placeholder', v_cancelled, 'placeholders', fabula.placeholder_status());$b$);
  if n = d then raise exception 'v105b: confirm_standing_orders return pattern not found'; end if;
  execute n;
end $do$;

-- ============================== E-17 prompt versions ==============================
create table if not exists fabula.bot_prompt_versions (
  agent      text primary key,
  version    text not null,
  updated_at timestamptz not null default now()
);
comment on table fabula.bot_prompt_versions is 'v1.05 (audit E-17): the version of each bot prompt in the repo (tools/bots/sync_rules.py --versions; the retired Shopify prompts have none, the database posts under their names). The bot passes the version of the prompt it runs with its message (bot_messages.prompt_version); fabula.prompt_drift() compares.';
alter table fabula.bot_prompt_versions enable row level security;
revoke all on fabula.bot_prompt_versions from public, anon, authenticated;
drop policy if exists bot_prompt_versions_read on fabula.bot_prompt_versions;
create policy bot_prompt_versions_read on fabula.bot_prompt_versions for select to authenticated using (fabula.can('sistema', 1));
grant select on fabula.bot_prompt_versions to authenticated;
insert into fabula.bot_prompt_versions (agent, version) values
  ('compliance_calendar', 'a93100192e'),
  ('daily_brief', 'ac91c1a4de'),
  ('haccp_nudge', '7b577cdac5'),
  ('marketing', '1751f41d47'),
  ('milk_planning', 'f728a1a02b'),
  ('monthly_review', '7aca4d86b3'),
  ('ops_health', '42a9f947c3'),
  ('procurement', '31675fd3a4'),
  ('sales', '41fca7c65b'),
  ('sell_down', '1100f04b29'),
  ('wholesale_orders', '10b17d9b6b')
on conflict (agent) do update set version = excluded.version, updated_at = now();

alter table fabula.bot_messages add column if not exists prompt_version text;
comment on column fabula.bot_messages.prompt_version is 'v1.05 (audit E-17): the version of the prompt the bot ran (p_prompt of post_bot_message); null for the database''s own messages.';

drop function if exists fabula.post_bot_message(text, text, text, text, uuid, text, text);
create or replace function fabula.post_bot_message(p_agent text, p_severity text, p_title text, p_body text, p_run_id uuid default null::uuid,
                                                   p_link text default null::text, p_link_label text default null::text, p_prompt text default null::text)
 returns bigint
 language plpgsql
 security definer
 set search_path to 'fabula', 'public'
as $function$
declare v_id bigint; v_sev text := case when p_severity in ('info','warn','alert') then p_severity else 'info' end;
        v_link text := fabula.safe_link(nullif(trim(p_link), '')); v_appr uuid; v_prompt text := nullif(left(btrim(coalesce(p_prompt, '')), 40), '');
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
           action_url = v_link, action_label = coalesce(nullif(trim(p_link_label), ''), fabula.link_label(v_link)), approval_id = coalesce(v_appr, approval_id),
           prompt_version = v_prompt
     where id = v_id;
    delete from fabula.bot_message_reads where message_id = v_id;       -- new content: unread again for everyone
  else
    insert into fabula.bot_messages (agent, run_id, severity, title, body, source, action_url, action_label, approval_id, prompt_version)
    values (p_agent, p_run_id, v_sev, coalesce(nullif(p_title, ''), fabula.bot_display_name(p_agent)), p_body, 'bot',
            v_link, coalesce(nullif(trim(p_link_label), ''), fabula.link_label(v_link)), v_appr, v_prompt)
    returning id into v_id;
  end if;
  return v_id;
end $function$;
revoke all on function fabula.post_bot_message(text, text, text, text, uuid, text, text, text) from public, anon, authenticated;
grant execute on function fabula.post_bot_message(text, text, text, text, uuid, text, text, text) to service_role;

-- the bots whose last message (8 days) came from a different prompt than the repo's: their scheduled task needs the new prompt
-- invoker: a login without Sistema reads no versions (RLS) and so sees no drift; system_checks() (definer) and the bots see it all
create or replace function fabula.prompt_drift() returns jsonb
language sql stable set search_path = fabula, public as $$
  with last as (
    select distinct on (m.agent) m.agent, m.prompt_version, m.created_at from fabula.bot_messages m
     where m.source = 'bot' and m.created_at > now() - interval '8 days' and m.agent in (select agent from fabula.bot_prompt_versions)
       and m.title not like 'Sostituito dal database%' and m.title not like 'Eseguito ora%' and m.title not like 'SIMULAZIONE%'
       and fabula.message_rule('messaggio', m.agent, null, m.title) is null   -- the database's own messages under a bot's name (E-06 rules)
     order by m.agent, m.created_at desc),
  bad as (select l.agent, l.prompt_version, v.version, l.created_at from last l join fabula.bot_prompt_versions v using (agent)
           where l.prompt_version is distinct from v.version)
  select jsonb_build_object('count', (select count(*) from bad),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('agent', agent, 'title', fabula.bot_title(agent), 'running', coalesce(prompt_version, 'senza versione'),
                                                           'expected', version, 'seen_at', created_at) order by agent), '[]'::jsonb) from bad),
    'line_it', case when exists (select 1 from bad) then
      'Bot con istruzioni non aggiornate: ' || (select string_agg(fabula.bot_title(agent), ', ' order by agent) from bad)
      || '. Le attività programmate vanno aggiornate dal repo: chiedi a Claude.' end)
$$;
revoke all on function fabula.prompt_drift() from public, anon;
grant execute on function fabula.prompt_drift() to authenticated, service_role;

-- Configurazione → Panoramica → Sistema: also the bots' instructions
create or replace function fabula.system_checks() returns jsonb
language plpgsql stable security definer set search_path = fabula, public as $$
declare c jsonb; pd jsonb;
begin
  if not fabula.can('sistema', 1) then raise exception 'Il tuo profilo non vede lo stato del sistema' using errcode = '42501'; end if;
  c := fabula.infra_checks(); pd := fabula.prompt_drift();
  c := c || jsonb_build_object('bot_prompts', jsonb_build_object('done', (pd ->> 'count')::int = 0,
            'detail', coalesce(pd ->> 'line_it', 'I bot girano con le istruzioni aggiornate del repo')));
  return (select jsonb_agg(jsonb_build_object('key', k, 'label_it', l, 'done', coalesce((c -> k ->> 'done')::boolean, false), 'detail', c -> k ->> 'detail') order by o)
            from (values (1, 'uptime', 'Sito e funzioni del server'), (2, 'cron_jobs', 'Attività programmate del database'), (3, 'vault_secret', 'Segreto del backup'),
                         (4, 'offsite_backup', 'Copia del backup fuori sede'), (5, 'outside_watcher', 'Monitor esterno (GitHub)'), (6, 'restore_tested', 'Prova di ripristino'),
                         (7, 'bot_prompts', 'Istruzioni dei bot'), (8, 'repo_sync', 'Migrazioni: GitHub e database'), (9, 'app_deployed', 'App del tablet pubblicata'),
                         (10, 'advisors_clean', 'Sicurezza del database')) v(o, k, l));
end $$;

-- ============================== E-19 the brief's changes computed here ==============================
create or replace function fabula.pct_change(p_now numeric, p_before numeric) returns numeric
language sql immutable set search_path = fabula, public as $$
  select case when p_now is null or p_before is null or p_before = 0 then null else round((p_now - p_before) / abs(p_before) * 100) end
$$;
-- the same shape as the first object, each number = % change against the second (objects compared key by key)
create or replace function fabula._pct_changes(p_now jsonb, p_before jsonb) returns jsonb
language plpgsql immutable set search_path = fabula, public as $$
declare k text; v jsonb; out jsonb := '{}'::jsonb;
begin
  if jsonb_typeof(p_now) <> 'object' or jsonb_typeof(p_before) <> 'object' then return null; end if;
  for k, v in select * from jsonb_each(p_now) loop
    if jsonb_typeof(v) = 'number' and jsonb_typeof(p_before -> k) = 'number' then
      out := out || jsonb_build_object(k, fabula.pct_change((v #>> '{}')::numeric, (p_before ->> k)::numeric));
    elsif jsonb_typeof(v) = 'object' and jsonb_typeof(p_before -> k) = 'object' then
      out := out || jsonb_build_object(k, fabula._pct_changes(v, p_before -> k));
    end if;
  end loop;
  return out;
end $$;

do $do$ begin
  if to_regprocedure('fabula._daily_brief_base(date)') is null then alter function fabula.daily_brief(date) rename to _daily_brief_base; end if;
  if to_regprocedure('fabula._weekly_brief_base(date)') is null then alter function fabula.weekly_brief(date) rename to _weekly_brief_base; end if;
end $do$;
create or replace function fabula.daily_brief(p_date date default (((now() at time zone 'Europe/Rome'::text))::date - 1))
 returns jsonb language sql stable set search_path to 'fabula', 'public', 'extensions' as $$
  -- v1.05 (audit E-19): the changes the brief talks about, computed here so the bot never does arithmetic
  select b || jsonb_build_object('changes', jsonb_build_object(
    'sales_vs_same_weekday_pct', fabula.pct_change((b #>> '{sales_trend,yesterday_eur}')::numeric, (b #>> '{sales_trend,same_weekday_avg_4w_eur}')::numeric),
    'yield_vs_30d_points', round((b #>> '{yield,yesterday}')::numeric - (b #>> '{yield,avg_30d}')::numeric, 1),
    'energy_kwh_per_kg_vs_30d_pct', fabula.pct_change((b #>> '{energy,yesterday_kwh_per_kg}')::numeric, (b #>> '{energy,avg_30d_kwh_per_kg}')::numeric)))
    from (select fabula._daily_brief_base(p_date) b) x
$$;
create or replace function fabula.weekly_brief(p_week_end date default null::date)
 returns jsonb language sql stable set search_path to 'fabula', 'public', 'extensions' as $$
  -- v1.05 (audit E-19): this week against the previous one, every number as a % change
  select b || jsonb_build_object('changes', fabula._pct_changes(b -> 'this_week', b -> 'previous_week'))
    from (select fabula._weekly_brief_base(p_week_end) b) x
$$;
revoke all on function fabula.daily_brief(date) from public, anon;
revoke all on function fabula.weekly_brief(date) from public, anon;
grant execute on function fabula.daily_brief(date) to authenticated, service_role;
grant execute on function fabula.weekly_brief(date) to authenticated, service_role;
revoke all on function fabula.pct_change(numeric, numeric) from public, anon;
revoke all on function fabula._pct_changes(jsonb, jsonb) from public, anon;
grant execute on function fabula.pct_change(numeric, numeric) to authenticated, service_role;
grant execute on function fabula._pct_changes(jsonb, jsonb) to authenticated, service_role;

-- the database's own wholesale run (when the bot did not start) and the Shopify customer sync give the same next step (E-16)
do $do$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.bot_fallback_run(text,date)'::regprocedure);
  n := replace(d, $a$case when (r->>'is_placeholder')::boolean then E'\n(Clienti di prova: sostituirli in Vendite.)' else '' end$a$,
                  $b$case when coalesce((r #>> '{placeholders,count}')::int, 0) > 0 then E'\n' || (r #>> '{placeholders,line_it}') else '' end$b$);
  if n = d then raise exception 'v105b: bot_fallback_run placeholder pattern not found'; end if;
  execute n;
  d := pg_get_functiondef('fabula.shopify_sync_finish(uuid,jsonb)'::regprocedure);
  n := replace(d, $a$facts := facts || format('%s ancora un nome provvisorio («Cliente 1»…): rinominali col nome vero in Console → Anagrafiche → Clienti', fabula.it_n((u->>'placeholders_left')::int, 'cliente ha', 'clienti hanno'));$a$,
                  $b$facts := facts || coalesce(fabula.placeholder_status() ->> 'line_it', format('%s ancora un nome provvisorio («Cliente 1»…): rinominali col nome vero in Console → Anagrafiche → Clienti', fabula.it_n((u->>'placeholders_left')::int, 'cliente ha', 'clienti hanno')));$b$);
  if n = d then raise exception 'v105b: shopify_sync_finish placeholder pattern not found'; end if;
  execute n;
end $do$;

-- a lead the sales bot found on the web is «Da verificare» until a person checks phone and address
do $do$
declare d text := pg_get_functiondef('fabula.sales_add_lead(jsonb)'::regprocedure); n text;
begin
  n := replace(d, $a$coalesce(nullif(p->>'next_action_date', '')::date, (now() at time zone 'Europe/Rome')::date + 2), nullif(p->>'notes', ''),$a$,
    $b$coalesce(nullif(p->>'next_action_date', '')::date, (now() at time zone 'Europe/Rome')::date + 2),
          case when coalesce(p->>'source', '') ilike 'bot%' then concat_ws(' · ', 'Da verificare: trovato sul web dal bot, telefono e indirizzo non ancora confermati', nullif(p->>'notes', ''))
               else nullif(p->>'notes', '') end,   -- v1.05 (audit E-19)$b$);
  if n = d then raise exception 'v105b: sales_add_lead pattern not found'; end if;
  execute n;
end $do$;

-- ============================== E-32 no tasks on days nobody works ==============================
insert into fabula.settings (key, value, description, data_type, kind, sort, impact_it) values
  ('prod.tasks_from', '', 'Primo giorno con le attività del giorno sul tablet (celle, sanificazione, contatore…). Vuoto = dal primo giorno della settimana di prova, o dalla data di apertura.',
   'text', 'date', 40, 'Prima di questa data il tablet non crea attività: niente liste di «scadute» mentre nessuno lavora.'),
  ('prod.closed_weekdays', '7', 'Giorni di chiusura: 1 = lunedì … 7 = domenica, separati da virgola. In quei giorni (e nelle chiusure dell''ingrosso) restano solo i controlli delle celle frigo.',
   'text', 'weekdays', 41, 'Nei giorni di chiusura il tablet chiede solo le temperature delle celle (il prodotto è dentro); le altre attività non si creano.')
on conflict (key) do nothing;

create or replace function fabula._setting_date(p_key text) returns date
language sql stable set search_path = fabula, public as $$
  select case when v ~ '^\d{4}-\d{2}-\d{2}$' then v::date end from (select btrim(coalesce(fabula.setting_text(p_key), '')) v) x
$$;
create or replace function fabula.tasks_start_date() returns date
language sql stable set search_path = fabula, public as $$
  select coalesce(fabula._setting_date('prod.tasks_from'), fabula._setting_date('trial.start'), fabula._setting_date('mkt.store_opening_date'))
$$;
create or replace function fabula.is_closed_day(p_date date) returns boolean
language sql stable set search_path = fabula, public as $$
  select extract(isodow from p_date)::int = any (array(select nullif(btrim(x), '')::int from unnest(string_to_array(coalesce(fabula.setting_text('prod.closed_weekdays'), ''), ',')) x
                                                        where btrim(x) ~ '^[1-7]$'))
      or exists (select 1 from fabula.trade_closures c where p_date between c.date_from and c.date_to)
$$;
revoke all on function fabula._setting_date(text) from public, anon;
revoke all on function fabula.tasks_start_date() from public, anon;
revoke all on function fabula.is_closed_day(date) from public, anon;
grant execute on function fabula._setting_date(text) to authenticated, service_role;
grant execute on function fabula.tasks_start_date() to authenticated, service_role;
grant execute on function fabula.is_closed_day(date) to authenticated, service_role;

create or replace function fabula.generate_daily_tasks(p_date date default ((now() at time zone 'Europe/Rome'::text))::date)
 returns integer
 language plpgsql
 set search_path to 'fabula', 'public', 'extensions'
as $function$
declare n int := 0; v_start date := fabula.tasks_start_date(); v_closed boolean := fabula.is_closed_day(p_date);
begin
  -- v1.05 (audit E-32): nothing before the tasks start; on a closed day only the cold rooms (the product is still inside). A weekly
  -- or monthly task goes to the first open day of its week or month that does not have it yet (Monday or the 1st when open)
  if v_start is null or p_date >= v_start then
    insert into fabula.task_instances (schedule_id, due_at)
    select s.id, (p_date + coalesce(s.due_time, time '12:00')) at time zone 'Europe/Rome'
    from fabula.task_schedules s
    where s.active and s.frequency in ('daily','per_shift') and not v_closed
    union all
    select s.id, (p_date + time '08:00') at time zone 'Europe/Rome' from fabula.task_schedules s
    where s.active and s.frequency = 'twice_daily'
    union all
    select s.id, (p_date + time '18:00') at time zone 'Europe/Rome' from fabula.task_schedules s
    where s.active and s.frequency = 'twice_daily'
    union all
    select s.id, (p_date + coalesce(s.due_time, time '12:00')) at time zone 'Europe/Rome' from fabula.task_schedules s
    where s.active and s.frequency = 'weekly' and not v_closed
      and not exists (select 1 from fabula.task_instances ti where ti.schedule_id = s.id
                       and (ti.due_at at time zone 'Europe/Rome')::date between p_date - (extract(isodow from p_date)::int - 1) and p_date + (7 - extract(isodow from p_date)::int))
    union all
    select s.id, (p_date + coalesce(s.due_time, time '12:00')) at time zone 'Europe/Rome' from fabula.task_schedules s
    where s.active and s.frequency = 'monthly' and not v_closed
      and not exists (select 1 from fabula.task_instances ti where ti.schedule_id = s.id
                       and date_trunc('month', ti.due_at at time zone 'Europe/Rome') = date_trunc('month', p_date::timestamp))
    on conflict do nothing;
    get diagnostics n = row_count;
  end if;
  -- mark yesterday's leftovers overdue
  update fabula.task_instances set status = 'overdue'
  where status = 'due' and due_at + make_interval(mins => 120) < now();
  -- v0.97 (audit A-05): a task still open after 7 days is closed as not done, with the reason
  update fabula.task_instances set status = 'skipped', skip_reason = 'Non registrata entro 7 giorni: chiusa in automatico', completed_at = now()
   where status in ('due', 'overdue') and due_at < now() - interval '7 days';
  return n;
end $function$;

-- the nightly job back on (paused 12/10 because nobody was in the building): before the start date it now creates nothing
do $do$ begin
  if exists (select 1 from cron.job where jobname = 'fabula_daily_tasks' and not active) then
    if to_regprocedure('cron.alter_job(bigint,text,text,text,text,boolean)') is not null then
      execute 'select cron.alter_job($1, active := true)' using (select jobid from cron.job where jobname = 'fabula_daily_tasks');
    else
      update cron.job set active = true where jobname = 'fabula_daily_tasks';   -- the test replay's stand-in for pg_cron
    end if;
  end if;
end $do$;
update fabula.dash_checks set note = 'Il giorno in cui si entra nel caseificio: controlla che i bot del caseificio (Chiusura serata, Piano latte, Ordini ingrosso, Da vendere prima, Brief del mattino) siano accesi in Configurazione → Bot. Le attività del giorno sul tablet partono da sole dalla data in Configurazione → Produzione «Primo giorno con le attività» (o dalla settimana di prova).'
 where key = 'bots_activated';
