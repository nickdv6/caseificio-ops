-- v1.05a–c for the Supabase dashboard SQL Editor (15/10/2026): bots, alerts and operations from the 12/10 audit (area E).
--   v1.05a  E-06 one table of rules for the database's own messages (severity, Telegram topic, area): milk not worked for 48 h is
--           now a food-safety alarm; E-09 the open alarms and notices for every office profile, by area (Console → Oggi and the
--           bell); E-14 the system checks in Italian; E-27 the drift warning says which way to fix it, and schema_fingerprint()
--           lets Claude compare live with the repo; E-28 the database jobs and the backup secret are checked (the save-ledger
--           trim job is now made by the migration)
--   v1.05b  E-16 one next step for the placeholder names; E-17 prompt versions and drift; E-19 the briefs' changes computed by
--           the database, web-found leads «Da verificare»; E-32 no daily tasks before the tasks start, only cold rooms on closed
--           days (the nightly task job is switched back on: before the start it creates nothing)
--   v1.05c  E-31 the evening HACCP list live on the tablet from 14:00, yesterday's gaps in the morning; E-30 the go-live list in
--           Italian in Configurazione → Panoramica, signed with a note
-- Same files as supabase/migrations/20261015090000_* … 20261015090200_* (built by make_v105_script.py).
-- One transaction: if any step fails nothing changes. It records the three versions in the migration history and refuses a second run.
-- Paste everything, Run, and check the last result shows 20261015090200, 20261015090100 and 20261015090000 at the top.
-- AFTER this: push the site (perla-v72, README «v1.05»), then the bots' scheduled tasks get the new prompts.
begin;
do $chk$ begin
  if exists (select 1 from supabase_migrations.schema_migrations where version in ('20261015090000', '20261015090100', '20261015090200')) then
    raise exception 'STOP: v1.05 is already in the migration history — nothing to do';
  end if;
  if (select max(version) from supabase_migrations.schema_migrations) <> '20261014230200' then
    raise exception 'STOP: the live history does not end at 20261014230200 (v104c_bank_tasks_perms) — tell Claude before applying';
  end if;
end $chk$;

-- ======================= v105a =======================
-- v1.05a · Audit 12/10/2026, area E (bots, alerts, operations), Medium items:
--   * E-06 one table of rules for the messages the database writes by itself (fabula.message_rules): which kind, how severe, which
--     Telegram topic, which area sees it, what it means. The functions keep posting as before; a trigger takes the severity from the
--     rule, and the notification topic comes from the same rule. Changed by it: milk accepted and not worked for 48 hours (the DOP
--     limit is 60) is now an alarm for food safety, no longer a quiet warning.
--   * E-09 the open alarms are shown to every office profile for its own areas (Console → Oggi and the bell), not only to who can
--     open Configurazione; the office notices too, by the area of their rule (v_active_notices.area).
--   * E-14 the system checks speak Italian (they were English: «push from the Mac», «Netlify has not deployed yet»…); a notice item
--     without a label gets one, so no raw data reaches a screen.
--   * E-27 the drift warning says which way to fix it: a migration live but not on GitHub → «git push» dal Mac; on GitHub but not
--     applied live → the version's SQL Editor script (a push changes nothing), in the notice, its feed copy and the evening check. fabula.schema_fingerprint() lets Claude compare every
--     live function and view with the repo (tools/ci/compare_live.py), comments apart.
--   * E-28 the one-time set-ups are checked: the scheduled database jobs against the expected list (fabula.cron_jobs_expected,
--     the save-ledger trim job now made here instead of pasted by hand) and the backup secret in the Vault; both in Configurazione →
--     Panoramica → Sistema (fabula.system_checks()).

-- ============================== E-06 the message rules ==============================
create table if not exists fabula.message_rules (
  kind        text primary key,
  applies_to  text not null check (applies_to in ('messaggio', 'avviso')),
  agent       text,                          -- messaggio: bot_messages.agent
  key_prefix  text,                          -- avviso: notices.key starts with it
  title_regex text,                          -- optional, case-insensitive, on the title
  severity    text check (severity in ('alert', 'warn', 'info')),   -- null = set by the function (written in meaning_it)
  topic       text not null check (topic in ('food_safety', 'decisions', 'infra')),
  area        text not null,                 -- who sees it among the alarms (permission area, level «vede»)
  meaning_it  text not null,
  sort        int not null default 100,
  check ((applies_to = 'messaggio' and agent is not null) or (applies_to = 'avviso' and key_prefix is not null))
);
comment on table fabula.message_rules is 'v1.05 (audit E-06): one place for the severity, Telegram topic and area of every message the database writes by itself. Triggers bot_messages_rule / notices_rule apply it; notify_topic_for reads the topic. Bot (LLM) messages follow tools/bots/MESSAGE-RULES.md.';
alter table fabula.message_rules enable row level security;
revoke all on fabula.message_rules from public, anon, authenticated;
drop policy if exists message_rules_read on fabula.message_rules;
create policy message_rules_read on fabula.message_rules for select to authenticated using (fabula.can('comune', 1));   -- what each message means: any active staff
grant select on fabula.message_rules to authenticated;

insert into fabula.message_rules (kind, applies_to, agent, key_prefix, title_regex, severity, topic, area, meaning_it, sort) values
  ('ccp_mancante',        'messaggio', 'sicurezza', null, '^Lotto .+ chiuso senza ', 'alert', 'food_safety', 'haccp', 'Un lotto è stato chiuso senza la registrazione di un CCP: va ricopiata oggi.', 10),
  ('latte_respinto',      'messaggio', 'sicurezza', null, '^Latte .+ respinto', 'alert', 'food_safety', 'haccp', 'Latte respinto all''arrivo (temperatura o antibiotici): va isolato.', 11),
  ('latte_60_ore',        'messaggio', 'sicurezza', null, 'latte vicino alle 60 ore', 'alert', 'food_safety', 'produzione', 'Latte accettato e non lavorato da 48 ore o più: oltre le 60 ore non si fa DOP. Va lavorato domattina per primo.', 12),
  ('haccp_rifiutate',     'messaggio', 'sicurezza', null, '^[0-9]+ registrazion. rifiutat', 'alert', 'food_safety', 'haccp', 'Registrazioni HACCP fatte senza rete e rifiutate dal database: vanno rifatte oggi.', 13),
  ('lotti_aperti',        'messaggio', 'produzione', null, '^Produzione [0-9]', 'warn', 'decisions', 'produzione', 'Lotti avviati e non chiusi a fine giornata.', 20),
  ('resa_fuori_norma',    'messaggio', 'produzione', null, '^Resa ', 'warn', 'decisions', 'produzione', 'Resa del lotto fuori dalla tolleranza: controllare i kg.', 21),
  ('tablet_rifiutate',    'messaggio', 'tablet', null, '^[0-9]+ registrazion. rifiutat', 'alert', 'food_safety', 'produzione', 'Registrazioni del tablet rifiutate dal database: vanno rifatte oggi.', 22),
  ('tablet_versione',     'messaggio', 'tablet', null, ' usa ancora la versione ', 'warn', 'infra', 'sistema', 'Un tablet non ha caricato l''ultima versione dell''app.', 23),
  ('tablet_in_attesa',    'messaggio', 'tablet', null, ' registrazioni in attesa da ', 'warn', 'infra', 'sistema', 'Un tablet ha registrazioni ferme senza rete da tempo.', 24),
  ('approvato_da_solo',   'messaggio', 'auto_approve', null, '^Approvato da solo', null, 'decisions', 'acquisti', 'Richiesta approvata dalla regola automatica. Gravità decisa dalla funzione: «warn» quando impegna latte o soldi (piano latte, ordine, promo), altrimenti «info».', 30),
  ('scaduta',             'messaggio', 'auto_approve', null, '^Scaduta senza decisione', 'warn', 'decisions', 'acquisti', 'Una richiesta è scaduta senza che nessuno decidesse.', 31),
  ('consegna_non_prenotata', 'messaggio', 'wholesale_orders', null, '^Consegna di .+ NON prenotata', 'warn', 'decisions', 'vendite', 'Consegna ingrosso non prenotata (sotto il minimo o altro motivo): avvisare il cliente.', 40),
  ('portale_cliente',     'messaggio', 'wholesale_orders', null, ' dal portale', 'warn', 'decisions', 'vendite', 'Un cliente ha cambiato il suo piano dal portale.', 41),
  ('ordine_shopify_non_creato', 'messaggio', 'wholesale_orders', null, '^Ordine Shopify non creato', 'alert', 'decisions', 'vendite', 'Un ordine ingrosso non è arrivato su Shopify dopo i tentativi: va creato a mano.', 42),
  ('masseria_correzione', 'messaggio', 'masseria', null, '^Masseria: peso corretto', 'info', 'decisions', 'produzione', 'La Masseria ha corretto il peso di una spedizione.', 50),
  ('masseria_annullata',  'messaggio', 'masseria', null, '^Masseria: spedizione .+ annullata', 'warn', 'decisions', 'produzione', 'La Masseria ha annullato una spedizione in viaggio.', 51),
  ('masseria_link',       'messaggio', 'configurazione', null, '^(Nuovo link della Masseria|Nuovo QR spedizioni)', 'info', 'infra', 'sistema', 'Un link della Masseria è stato cambiato.', 52),
  ('masseria_poster',     'messaggio', 'configurazione', null, '^Masseria: stampa il nuovo QR', 'warn', 'infra', 'sistema', 'Promemoria: stampare il nuovo poster e mandare il nuovo link.', 53),
  ('parametro_cambiato',  'messaggio', 'configurazione', null, '^Parametro cambiato', 'warn', 'infra', 'sistema', 'Un parametro che cambia il comportamento del sistema è stato modificato.', 54),
  ('turni_copiati',       'messaggio', 'turni', null, null, 'info', 'decisions', 'personale', 'Turni della settimana copiati in automatico.', 60),
  ('prova_giorno',        'messaggio', 'prova', null, '^Prova giorno', null, 'decisions', 'produzione', 'Esito di un giorno della settimana di prova. Gravità decisa dalla funzione: «info» se tutti i passaggi sono ok, altrimenti «warn».', 61),
  ('shopify_clienti_ferma', 'messaggio', 'shopify_customers', null, ' non partita( |$)', 'alert', 'infra', 'sistema', 'La sincronizzazione dei clienti con Shopify non è partita.', 70),
  ('shopify_ordini_ferma',  'messaggio', 'shopify_orders', null, ' non partita( |$)', 'alert', 'infra', 'sistema', 'La sincronizzazione degli ordini con Shopify non è partita.', 71),
  ('haccp_serale',        'avviso', null, 'haccp_evening', null, 'alert', 'food_safety', 'haccp', 'Cose da registrare prima di chiudere (lista rossa del tablet).', 100),
  ('analisi_lotto_ignoto', 'avviso', null, 'lab_lot_unknown', null, 'alert', 'food_safety', 'haccp', 'Analisi non conforme su un lotto che il sistema non conosce: bloccare a mano.', 101),
  ('lotto_oltre_produzione', 'avviso', null, 'lot_guard', null, 'warn', 'food_safety', 'magazzino', 'Un lotto è uscito oltre la produzione registrata: controllare il peso.', 102),
  ('peso_latte',          'avviso', null, 'milk_weight', null, 'warn', 'decisions', 'produzione', 'Il peso del latte al caseificio è diverso da quello scritto dalla Masseria.', 103),
  ('bot_da_controllare',  'avviso', null, 'bot_alert', null, 'alert', 'infra', 'sistema', 'Un bot non è partito o è andato in errore.', 110),
  ('battito_bot',         'avviso', null, 'bot_heartbeat', null, 'alert', 'infra', 'sistema', 'I bot non danno segni di vita.', 111),
  ('sistema_giu',         'avviso', null, 'infra_uptime', null, 'alert', 'infra', 'sistema', 'Il sito del tablet o le funzioni del server non rispondono.', 112),
  ('disallineamento',     'avviso', null, 'infra_drift', null, 'warn', 'infra', 'sistema', 'GitHub, sito e database non allineati da più di 6 ore.', 113),
  ('advisor_supabase',    'avviso', null, 'infra_advisors', null, 'warn', 'infra', 'sistema', 'Segnalazioni di sicurezza di Supabase da verificare.', 114),
  ('sicurezza_database',  'avviso', null, 'infra_security', null, null, 'infra', 'sistema', 'Nuove segnalazioni della scansione di sicurezza. Gravità decisa dalla funzione: «alert» se ci sono errori, altrimenti «warn».', 115),
  ('controllo_esterno',   'avviso', null, 'outside_watcher', null, 'warn', 'infra', 'sistema', 'Il controllo esterno (GitHub) non riferisce.', 116),
  ('copia_fuori_sede',    'avviso', null, 'offsite_backup', null, 'warn', 'infra', 'sistema', 'La copia del backup fuori sede è in ritardo.', 117),
  ('incassi',             'avviso', null, 'recon', null, 'warn', 'decisions', 'finanza', 'Incassi da controllare nella riconciliazione.', 120),
  ('richieste_professionisti', 'avviso', null, 'trade_applications', null, 'info', 'decisions', 'vendite', 'Richieste di accesso al portale da valutare.', 121)
on conflict (kind) do nothing;

-- the rule of a message (on its title; the Telegram topic is looked up on title + body, hence «( |$)» rather than «$» in the rules).
-- Invoker: the triggers and functions that use it are definers; a login reads the rules through RLS (v_active_notices.area)
create or replace function fabula.message_rule(p_applies text, p_agent text, p_key text, p_title text) returns fabula.message_rules
language sql stable set search_path = fabula, public as $$
  select r.* from fabula.message_rules r
   where r.applies_to = p_applies
     and (p_applies <> 'messaggio' or r.agent = p_agent)
     and (p_applies <> 'avviso' or coalesce(p_key, '') like r.key_prefix || '%')
     and (r.title_regex is null or coalesce(p_title, '') ~* r.title_regex)
   order by r.sort, r.kind limit 1
$$;
revoke all on function fabula.message_rule(text, text, text, text) from public, anon;
grant execute on function fabula.message_rule(text, text, text, text) to authenticated, service_role;

create or replace function fabula.trg_bot_message_rule() returns trigger
language plpgsql security definer set search_path = fabula, public as $$
declare r fabula.message_rules;
begin
  r := fabula.message_rule('messaggio', new.agent, null, new.title);
  if r.kind is not null and r.severity is not null then new.severity := r.severity; end if;
  return new;
end $$;
revoke all on function fabula.trg_bot_message_rule() from public, anon, authenticated;
drop trigger if exists bot_messages_rule on fabula.bot_messages;
create trigger bot_messages_rule before insert or update of severity, title, agent on fabula.bot_messages
  for each row execute function fabula.trg_bot_message_rule();

create or replace function fabula.trg_notice_rule() returns trigger
language plpgsql security definer set search_path = fabula, public as $$
declare r fabula.message_rules;
begin
  r := fabula.message_rule('avviso', null, new.key, new.title_it);
  if r.kind is not null and r.severity is not null then new.severity := r.severity; end if;
  return new;
end $$;
revoke all on function fabula.trg_notice_rule() from public, anon, authenticated;
drop trigger if exists notices_rule on fabula.notices;
create trigger notices_rule before insert or update of severity, title_it, key on fabula.notices
  for each row execute function fabula.trg_notice_rule();

-- the Telegram topic: the rule's when there is one, otherwise as before (bots: by agent and words)
create or replace function fabula.notify_topic_for(p_agent text, p_text text, p_key text default null::text)
 returns text
 language plpgsql
 stable security definer
 set search_path to 'fabula', 'public'
as $function$
declare r fabula.message_rules;
begin
  r := case when p_agent = 'notice' then fabula.message_rule('avviso', null, p_key, p_text) else fabula.message_rule('messaggio', p_agent, null, p_text) end;
  if r.kind is not null then return r.topic; end if;
  return case
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
    else 'decisions' end;
end $function$;
revoke all on function fabula.notify_topic_for(text, text, text) from public, anon, authenticated;

-- ============================== E-09 alarms for every office profile, by area ==============================
alter table fabula.bot_nicknames add column if not exists area text;
comment on column fabula.bot_nicknames.area is 'v1.05 (audit E-09): the permission area whose people see this bot''s alarms in Console → Oggi and in the bell (sistema sees all).';
update fabula.bot_nicknames n set area = v.area from (values
  ('auto_approve', 'acquisti'), ('avvisi', 'sistema'), ('backup_export', 'sistema'), ('bot_heartbeat', 'sistema'), ('bot_watchdog', 'sistema'),
  ('compliance_calendar', 'haccp'), ('configurazione', 'sistema'), ('daily_brief', 'comune'), ('haccp_nudge', 'haccp'), ('invite_user', 'sistema'),
  ('marketing', 'marketing'), ('masseria', 'produzione'), ('milk_planning', 'produzione'), ('monthly_review', 'finanza'), ('ops_health', 'sistema'),
  ('predis', 'marketing'), ('procurement', 'acquisti'), ('produzione', 'produzione'), ('prova', 'produzione'), ('sales', 'vendite'),
  ('sell_down', 'vendite'), ('shopify_customers', 'vendite'), ('shopify_inventory', 'magazzino'), ('shopify_orders', 'vendite'),
  ('sicurezza', 'haccp'), ('tablet', 'sistema'), ('turni', 'personale'), ('wholesale_orders', 'vendite')) v(agent, area)
 where n.agent = v.agent and n.area is null;

create or replace function fabula.message_area(p_agent text, p_title text) returns text
language sql stable security definer set search_path = fabula, public as $$
  select coalesce((fabula.message_rule('messaggio', p_agent, null, p_title)).area,
                  (select area from fabula.bot_nicknames where agent = p_agent), 'sistema')
$$;
revoke all on function fabula.message_area(text, text) from public, anon, authenticated;

-- the open alarms this login may see: all of them with Sistema, otherwise those of its areas
create or replace function fabula.my_alarms() returns jsonb
language sql stable security definer set search_path = fabula, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'agent', x.agent, 'agent_title', fabula.bot_display_name(x.agent), 'created_at', x.created_at,
                                               'title', x.title, 'action_url', x.action_url, 'action_label', x.action_label, 'area', x.area)
                            order by x.created_at desc), '[]'::jsonb)
    from (select m.*, fabula.message_area(m.agent, m.title) as area from fabula.bot_messages m
           where m.severity = 'alert' and m.read_at is null and m.notice_key is null and m.created_at > now() - interval '30 days'
           order by m.created_at desc limit 200) x
   where auth.uid() is not null and (fabula.can('sistema', 1) or fabula.can(x.area, 1))
$$;
revoke all on function fabula.my_alarms() from public, anon;
grant execute on function fabula.my_alarms() to authenticated;

-- the active notices with the area of their rule: Console → Oggi «Avvisi aperti» shows a profile without Sistema the notices of its
-- areas (the tablet keeps its floor filter); a notice without a rule is the system's
create or replace view fabula.v_active_notices with (security_invoker = true) as
 select id, key, severity, title_it, items, created_at, expires_at, resolved_at, audience, fabula.notice_link(key) as link,
        coalesce((fabula.message_rule('avviso', null, key, title_it)).area, 'sistema') as area
   from fabula.notices
  where resolved_at is null and expires_at > now()
  order by case severity when 'alert' then 0 when 'warn' then 1 else 2 end, created_at desc;

create or replace function fabula.bot_bell() returns jsonb
language sql stable set search_path = fabula, public as $$
  -- v1.05 (audit E-09): a profile without Sistema counts the open alarms of its own areas, bot alarms and alarm notices (its bell
  -- opens Console → Oggi, where both are listed)
  select case when fabula.can('sistema', 1) then jsonb_build_object(
    'alerts', (select count(*) from fabula.bot_messages m where m.read_at is null and m.severity = 'alert'),
    'unread', (select count(*) from fabula.bot_messages m where m.read_at is null and m.severity <> 'alert'
                 and not exists (select 1 from fabula.bot_message_reads r where r.message_id = m.id and r.staff_id = fabula.my_staff_id())),
    'scope', 'tutti')
  else jsonb_build_object('alerts', jsonb_array_length(fabula.my_alarms())
                                    + (select count(*) from fabula.v_active_notices n where n.severity = 'alert' and fabula.can(n.area, 1)),
                          'unread', 0, 'scope', 'aree') end
$$;

-- ============================== E-14 plain Italian in the system checks ==============================
create or replace function fabula._it_infra_detail(p text) returns text
language sql immutable set search_path = fabula, public as $$
  select case when p is null then null else
    regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
      p, '^no answer$', 'nessuna risposta'),
         '^timeout$', 'tempo scaduto'),
         'GitHub API limit \(HTTP ([0-9]+)\): previous list kept', 'limite di GitHub (HTTP \1): tenuto l''elenco precedente'),
         'GitHub HTTP ([0-9]+): previous commit kept', 'GitHub (HTTP \1): tenuto il commit precedente'),
         ', sw\.js without version', ', sw.js senza versione'),
         ' migration files on GitHub main', ' migrazioni su GitHub (main)'),
         ' findings, all accepted', ' segnalazioni, tutte accettate'),
         '^([0-9]+) new: ', '\1 nuove: '),
         ' lint types, all known', ' tipi di segnalazione, tutti noti'),
         '^([0-9]+) to check: ', '\1 da verificare: ') end
$$;

create or replace function fabula._infra_name(p_key text) returns text
language sql immutable set search_path = fabula, public as $$
  select case p_key when 'site' then 'sito del tablet' when 'fn_farm_order' then 'pagina della Masseria (funzione farm-order)'
                    when 'fn_backup_export' then 'backup (funzione backup-export)' else p_key end
$$;

-- E-28: the scheduled database jobs that must exist (and be on), so a restore or a missed paste is seen
create table if not exists fabula.cron_jobs_expected (
  jobname    text primary key,
  schedule   text not null,
  active     boolean not null default true,
  purpose_it text not null
);
comment on table fabula.cron_jobs_expected is 'v1.05 (audit E-28): the pg_cron jobs the migrations create. infra_checks() / system_checks() compare cron.job with it.';
alter table fabula.cron_jobs_expected enable row level security;
revoke all on fabula.cron_jobs_expected from public, anon, authenticated;
drop policy if exists cron_jobs_expected_read on fabula.cron_jobs_expected;
create policy cron_jobs_expected_read on fabula.cron_jobs_expected for select to authenticated using (fabula.can('sistema', 1));
grant select on fabula.cron_jobs_expected to authenticated;
insert into fabula.cron_jobs_expected (jobname, schedule, purpose_it) values
  ('fabula_auto_approve', '*/10 * * * *', 'Approvazioni automatiche e scadenze delle richieste'),
  ('fabula_backup_latest', '5 5-19/2 * * 1-6', 'Backup ogni 2 ore nei giorni di lavoro'),
  ('fabula_backup_nightly', '15 19,20 * * *', 'Backup notturno'),
  ('fabula_bot_fallback', '*/5 * * * *', 'Il database fa il lavoro dei bot che non sono partiti'),
  ('fabula_bot_heartbeat', '25 * * * *', 'Segni di vita dei bot'),
  ('fabula_bot_messages_autoread', '17 * * * *', 'Chiude i messaggi superati'),
  ('fabula_consorzio_declaration', '30 5 1 * *', 'Dichiarazione mensile al Consorzio'),
  ('fabula_daily_tasks', '0 4 * * *', 'Attività del giorno sul tablet'),
  ('fabula_device_watch', '*/15 * * * *', 'Controllo dei tablet'),
  ('fabula_followup_tick', '*/5 * * * *', 'Ricontrolli dopo un valore fuori norma'),
  ('fabula_infra_collect', '43 * * * *', 'Controllo di sito, GitHub e funzioni'),
  ('fabula_infra_probe', '40 * * * *', 'Richieste del controllo di sistema'),
  ('fabula_notify_tick', '* * * * *', 'Invio degli avvisi Telegram'),
  ('fabula_outside_watch', '50 * * * *', 'Controllo del monitor esterno e della copia fuori sede'),
  ('fabula_prod_watch', '45 17,18 * * *', 'Lotti aperti e latte vicino alle 60 ore (sera)'),
  ('fabula_recon', '40 4 * * *', 'Riconciliazione degli incassi'),
  ('fabula_rota_autocopy', '5 9 * * 6', 'Copia dei turni della settimana'),
  ('fabula_save_ledger_trim', '30 3 * * 0', 'Pulizia delle ricevute dei salvataggi del tablet (30 giorni)'),
  ('fabula_sensor_rollup', '0 */12 * * *', 'Riepilogo dei sensori'),
  ('fabula_shopify_sync', '*/5 * * * *', 'Sincronizzazione con Shopify'),
  ('fabula_trade_push', '25 16,17 * * 1-6', 'Ordini ingrosso verso Shopify'),
  ('fabula_trade_push_retry', '50 * * * *', 'Riprova degli ordini ingrosso verso Shopify'),
  ('fabula_trial_report', '35 18,19 * * *', 'Esito dei giorni della settimana di prova')
on conflict (jobname) do nothing;

-- the save-ledger trim, made here (it was a one-time paste, tools/go-live/sql-editor/save_ledger_trim.sql)
create or replace function fabula.save_ledger_trim() returns integer
language plpgsql security definer set search_path = fabula, public as $$
declare n int;
begin
  delete from fabula.save_ledger where created_at < now() - interval '30 days';
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function fabula.save_ledger_trim() from public, anon, authenticated;
select cron.schedule('fabula_save_ledger_trim', '30 3 * * 0', $c$select fabula.save_ledger_trim()$c$);

create or replace function fabula.cron_jobs_check() returns jsonb
language plpgsql stable security definer set search_path = fabula, public, extensions as $$
declare v_missing text[]; v_off text[]; v_sched text[];
begin
  select array_agg(e.jobname order by e.jobname) filter (where j.jobid is null),
         array_agg(e.jobname order by e.jobname) filter (where j.jobid is not null and j.active is distinct from e.active),
         array_agg(e.jobname order by e.jobname) filter (where j.jobid is not null and j.schedule is distinct from e.schedule)
    into v_missing, v_off, v_sched
    from fabula.cron_jobs_expected e left join cron.job j on j.jobname = e.jobname;
  return jsonb_build_object('done', coalesce(cardinality(v_missing), 0) + coalesce(cardinality(v_off), 0) + coalesce(cardinality(v_sched), 0) = 0,
    'missing', to_jsonb(coalesce(v_missing, '{}')), 'off', to_jsonb(coalesce(v_off, '{}')), 'schedule', to_jsonb(coalesce(v_sched, '{}')),
    'detail', case when coalesce(cardinality(v_missing), 0) + coalesce(cardinality(v_off), 0) + coalesce(cardinality(v_sched), 0) = 0
                   then (select count(*) from fabula.cron_jobs_expected) || ' attività programmate del database presenti e accese'
                   else concat_ws(' · ',
                     case when cardinality(v_missing) > 0 then 'mancano: ' || array_to_string(v_missing, ', ') end,
                     case when cardinality(v_off) > 0 then 'spente: ' || array_to_string(v_off, ', ') end,
                     case when cardinality(v_sched) > 0 then 'orario diverso: ' || array_to_string(v_sched, ', ') end)
                        || '. Si rimettono con l''ultima migrazione: chiedi a Claude (dopo un ripristino, rilancia le migrazioni)' end);
end $$;
revoke all on function fabula.cron_jobs_check() from public, anon, authenticated;

create or replace function fabula.vault_secret_check() returns jsonb
language plpgsql stable security definer set search_path = fabula, public as $$
declare v boolean;
begin
  if to_regclass('vault.secrets') is null then
    return jsonb_build_object('done', false, 'detail', 'Vault non disponibile su questo database');
  end if;
  execute 'select exists (select 1 from vault.secrets where name = $1)' into v using 'backup_export_token';
  return jsonb_build_object('done', v, 'detail', case when v then 'Segreto del backup presente nel Vault'
    else 'Manca il segreto «backup_export_token» nel Vault: senza, il backup non parte (tools/go-live/BACKUP-RESTORE.md, chiedi a Claude)' end);
end $$;
revoke all on function fabula.vault_secret_check() from public, anon, authenticated;

create or replace function fabula.infra_checks()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'fabula', 'public', 'extensions'
as $function$
declare
  t fabula.infra_status; h fabula.infra_status; g fabula.infra_status; s fabula.infra_status;
  sc fabula.infra_status; adv fabula.infra_status;
  v_live text[] := array(select version from supabase_migrations.schema_migrations order by 1);
  v_gh text[]; v_missing text[]; v_extra text[]; v_fresh boolean; v_head text;
  d record; v_down text; v_stale boolean;
  v_out jsonb;
begin
  -- v1.05 (audit E-14, E-27, E-28): every detail in Italian; the drift says which way to fix it; database jobs and the backup secret
  select * into t from fabula.infra_status where key = 'github_tree';
  select * into h from fabula.infra_status where key = 'github_head';
  select * into g from fabula.infra_status where key = 'github_sw';
  select * into s from fabula.infra_status where key = 'site';
  select * into sc from fabula.infra_status where key = 'security_scan';
  select * into adv from fabula.infra_status where key = 'advisors';

  v_gh := array(select jsonb_array_elements_text(coalesce(t.data->'versions', '[]'::jsonb)) order by 1);
  v_fresh := coalesce(t.last_ok_at > now() - interval '26 hours', false);
  v_missing := array(select unnest(v_live) except select unnest(v_gh) order by 1);
  v_extra := array(select unnest(v_gh) except select unnest(v_live) order by 1);
  v_head := case when h.data ? 'sha' then 'main ' || left(h.data->>'sha', 7) || ' · ' || left(h.data->>'title', 60)
                   || ' · ' || to_char((h.data->>'updated')::timestamptz at time zone 'Europe/Rome', 'DD/MM HH24:MI') end;

  v_out := jsonb_build_object(
    'code_pushed', jsonb_build_object(
      'done', v_fresh and cardinality(v_missing) = 0,
      'detail', case when t.last_ok_at is null then 'In attesa del primo controllo di GitHub (ogni ora, ai :43)'
                     when not v_fresh then 'GitHub non letto dal ' || to_char(t.last_ok_at at time zone 'Europe/Rome', 'DD/MM HH24:MI')
                     when cardinality(v_missing) > 0 then cardinality(v_missing) || case when cardinality(v_missing) = 1 then ' migrazione applicata sul database ma non su GitHub: '
                                                                                         else ' migrazioni applicate sul database ma non su GitHub: ' end
                          || array_to_string(v_missing[1:3], ', ') || '. Fai «git push» dal Mac'
                     else coalesce(v_head, 'GitHub ha tutte le migrazioni del database') end),
    'repo_sync', jsonb_build_object(
      'done', v_fresh and cardinality(v_missing) = 0 and cardinality(v_extra) = 0,
      'detail', case when not v_fresh then 'In attesa di un controllo di GitHub'
                     when cardinality(v_missing) + cardinality(v_extra) = 0 then cardinality(v_gh) || ' file su GitHub = ' || cardinality(v_live) || ' versioni sul database'
                     else concat_ws(' · ',
                            case when cardinality(v_missing) > 0 then cardinality(v_missing) || ' sul database ma non su GitHub: fai «git push» dal Mac' end,
                            case when cardinality(v_extra) > 0 then cardinality(v_extra) || ' su GitHub ma non applicate sul database (' || array_to_string(v_extra[1:3], ', ')
                                 || '): applica lo script SQL Editor della versione (tools/go-live/live-apply); un push non serve' end) end),
    'app_deployed', jsonb_build_object(
      'done', coalesce(g.data->>'sw' = s.data->>'sw' and g.last_ok_at > now() - interval '26 hours' and s.last_ok_at > now() - interval '3 hours', false),
      'detail', case when s.last_ok_at is null or g.last_ok_at is null then 'In attesa del primo controllo del sito'
                     when s.last_ok_at <= now() - interval '3 hours' then 'Il sito del tablet non risponde dal ' || to_char(s.last_ok_at at time zone 'Europe/Rome', 'DD/MM HH24:MI')
                     when g.data->>'sw' = s.data->>'sw' then 'Sito ' || (s.data->>'sw') || ' = GitHub main'
                     else 'Sito ' || coalesce(s.data->>'sw', '?') || ', GitHub ' || coalesce(g.data->>'sw', '?') || ': Netlify non ha ancora pubblicato (guarda il deploy su Netlify)' end)
  );

  select * into d from fabula.agent_runs where agent = 'restore_drill' and status <> 'running' order by started_at desc limit 1;
  v_out := v_out || jsonb_build_object('restore_tested', jsonb_build_object(
    'done', coalesce(d.status = 'ok' and d.started_at > now() - interval '100 days', false),
    'detail', case when d.id is null then 'Nessuna prova di ripristino registrata'
                   when d.status <> 'ok' then 'Ultima prova FALLITA il ' || to_char(d.started_at at time zone 'Europe/Rome', 'DD/MM/YYYY') || ': ' || coalesce(d.error, d.summary)
                   when d.started_at <= now() - interval '100 days' then 'Ultima prova il ' || to_char(d.started_at at time zone 'Europe/Rome', 'DD/MM/YYYY') || ': in ritardo (ogni 3 mesi)'
                   else 'Prova di ripristino del ' || to_char(d.started_at at time zone 'Europe/Rome', 'DD/MM/YYYY') || ' superata' end));

  v_stale := coalesce(sc.checked_at <= now() - interval '26 hours', true);
  v_out := v_out || jsonb_build_object('advisors_clean', jsonb_build_object(
    'done', not v_stale and coalesce(sc.ok, false) and coalesce(adv.ok or adv.checked_at <= now() - interval '50 hours', true),
    'detail', case when sc.checked_at is null then 'In attesa della prima scansione di sicurezza'
                   when v_stale then 'Scansione di sicurezza non eseguita dal ' || to_char(sc.checked_at at time zone 'Europe/Rome', 'DD/MM HH24:MI')
                   else 'Scansione SQL: ' || fabula._it_infra_detail(sc.detail)
                        || ' · Supabase Advisor: ' || coalesce(case when adv.checked_at > now() - interval '50 hours' then fabula._it_infra_detail(adv.detail) end, 'in attesa del bot Controllo sistema') end));

  select string_agg(fabula._infra_name(key) || ' (' || coalesce(fabula._it_infra_detail(detail), '?') || ')', ', ' order by key) into v_down
    from fabula.infra_status
   where key in ('site', 'fn_farm_order', 'fn_backup_export') and (ok is distinct from true or checked_at <= now() - interval '3 hours');
  v_out := v_out || jsonb_build_object('uptime', jsonb_build_object(
    'done', v_down is null and (select count(*) from fabula.infra_status where key in ('site', 'fn_farm_order', 'fn_backup_export')) = 3,
    'detail', case when (select count(*) from fabula.infra_status where key in ('site', 'fn_farm_order', 'fn_backup_export') and checked_at is not null) < 3
                     then 'In attesa del primo controllo orario'
                   when v_down is null then 'Sito del tablet, pagina della Masseria e backup hanno risposto alle '
                        || (select to_char(min(checked_at) at time zone 'Europe/Rome', 'HH24:MI') from fabula.infra_status where key = 'site')
                   else 'Non risponde o non controllato: ' || v_down end));
  -- v1.00a (audit E-22/E-24): reports from GitHub (public.fabula_outside_report)
  v_out := v_out || jsonb_build_object(
    'outside_watcher', (select jsonb_build_object(
        'done', coalesce(x.checked_at > now() - interval '24 hours', false),
        'detail', case when x.key is null then 'Non ancora attivo: aggiungi il segreto GitHub BACKUP_EXPORT_TOKEN (claude/ops-batch-v100-2026-10-13.md)'
                       when x.checked_at <= now() - interval '24 hours' then 'Silenzioso dal ' || to_char(x.checked_at at time zone 'Europe/Rome', 'DD/MM HH24:MI')
                            || ': GitHub → Actions → «Outside watcher» → abilitalo e «Run workflow»'
                       else 'Ultimo giro ' || to_char(x.checked_at at time zone 'Europe/Rome', 'DD/MM HH24:MI')
                            || case when x.ok then ' · tutto ok' else ' · trovato: ' || coalesce(fabula._it_infra_detail(x.detail), '?') end
                            || ' · gli allarmi vanno al gruppo Telegram' end)
      from (select 1) one left join fabula.infra_status x on x.key = 'outside_watcher'),
    'offsite_backup', (select jsonb_build_object(
        'done', coalesce(x.ok and x.last_ok_at > now() - interval '50 hours', false),
        'detail', case when x.key is null then 'Nessuna copia fuori sede: aggiungi i segreti GitHub BACKUP_EXPORT_TOKEN e BACKUP_PASSPHRASE (claude/ops-batch-v100-2026-10-13.md)'
                       when not x.ok then 'Ultimo tentativo fallito il ' || to_char(x.checked_at at time zone 'Europe/Rome', 'DD/MM HH24:MI') || ': ' || coalesce(fabula._it_infra_detail(x.detail), '?')
                       when x.last_ok_at <= now() - interval '50 hours' then 'Ultima copia ' || to_char(x.last_ok_at at time zone 'Europe/Rome', 'DD/MM HH24:MI') || ': in ritardo (ogni notte)'
                       else coalesce(fabula._it_infra_detail(x.detail), 'Copia fuori sede ok') end)
      from (select 1) one left join fabula.infra_status x on x.key = 'offsite_backup'),
    'cron_jobs', fabula.cron_jobs_check() - 'missing' - 'off' - 'schedule',
    'vault_secret', fabula.vault_secret_check());
  return v_out;
end $function$;

-- infra_collect: the «down» items and the drift title in plain Italian (the drift items are infra_checks' details, Italian above)
do $do$
declare d text := pg_get_functiondef('fabula.infra_collect()'::regprocedure); n text;
begin
  n := replace(d, $a$jsonb_build_object('code', key, 'label_it', coalesce(detail, 'nessuna risposta'))$a$,
                  $b$jsonb_build_object('code', key, 'label_it', fabula._infra_name(key) || ': ' || coalesce(fabula._it_infra_detail(detail), 'nessuna risposta'))$b$);
  n := replace(n, $a$'GitHub, sito del tablet e database non allineati da più di 6 ore (push dal Mac / deploy Netlify)'$a$,
                  $b$'GitHub, sito del tablet e database non allineati da più di 6 ore: cosa fare è scritto qui sotto'$b$);
  n := replace(n, $a$jsonb_array_length(v_drift) || ' out of step > 6 h'$a$, $b$jsonb_array_length(v_drift) || ' non allineati da più di 6 ore'$b$);
  -- a drift notice already open takes the new title too
  n := replace(n, $a$on conflict (key) do update set items = excluded.items, expires_at = excluded.expires_at, resolved_at = null;$a$,
                  $b$on conflict (key) do update set items = excluded.items, title_it = excluded.title_it, expires_at = excluded.expires_at, resolved_at = null;$b$);
  if n = d or position('fabula._infra_name(key)' in n) = 0 or position('cosa fare è scritto qui sotto' in n) = 0
     or position('non allineati da più di 6 ore''' in n) = 0 or position('title_it = excluded.title_it, expires_at' in n) = 0 then
    raise exception 'v105a: infra_collect patterns not found';
  end if;
  execute n;
end $do$;

-- the drift notice's copy in the bots' feed (and the morning summary) says which way to fix it, as the notice does: its items carry
-- infra_checks' Italian detail («fai «git push» dal Mac» or «applica lo script SQL Editor della versione»)
do $do$
declare d text := pg_get_functiondef('fabula.trg_notice_message()'::regprocedure); n text;
begin
  n := replace(d, $a$when 'code_pushed'  then 'Modifiche al database non ancora salvate su GitHub: fai «git push» dal Mac'$a$,
                  $b$when 'code_pushed'  then coalesce(nullif(x->>'label_it', ''), 'Modifiche al database non ancora salvate su GitHub: fai «git push» dal Mac')$b$);
  n := replace(n, $a$when 'repo_sync'    then 'GitHub e database non coincidono: fai «git push» dal Mac'$a$,
                  $b$when 'repo_sync'    then coalesce(nullif(x->>'label_it', ''), 'GitHub e database non coincidono: guarda Configurazione → Panoramica → Sistema')$b$);
  if position('coalesce(nullif(x->>''label_it'', ''''), ''Modifiche al database' in n) = 0 or position('guarda Configurazione → Panoramica → Sistema' in n) = 0 then
    raise exception 'v105a: trg_notice_message patterns not found';
  end if;
  execute n;
end $do$;

-- a notice item without a label gets one, so no raw data reaches the tablet, the Console or Telegram (E-14)
create or replace function fabula.trg_notice_items_label() returns trigger
language plpgsql set search_path = fabula, public as $$
begin
  if jsonb_typeof(new.items) = 'array' then
    new.items := (select coalesce(jsonb_agg(case when jsonb_typeof(i) = 'object' and coalesce(i ->> 'label_it', '') = '' then
                         i || jsonb_build_object('label_it', coalesce(nullif(i ->> 'label', ''), nullif(i ->> 'text', ''), nullif(i ->> 'title_it', ''),
                                                                      nullif(i ->> 'name', ''), case when i ? 'lot' then 'Lotto ' || (i ->> 'lot') end, 'Dettaglio non disponibile'))
                       else i end order by o), '[]'::jsonb)
                    from jsonb_array_elements(new.items) with ordinality x(i, o));
  end if;
  return new;
end $$;
drop trigger if exists notices_items on fabula.notices;
create trigger notices_items before insert or update of items on fabula.notices for each row execute function fabula.trg_notice_items_label();

-- Configurazione → Panoramica → Sistema: the checks a partner can read and act on (E-28), in Italian
create or replace function fabula.system_checks() returns jsonb
language plpgsql stable security definer set search_path = fabula, public as $$
declare c jsonb;
begin
  if not fabula.can('sistema', 1) then raise exception 'Il tuo profilo non vede lo stato del sistema' using errcode = '42501'; end if;
  c := fabula.infra_checks();
  return (select jsonb_agg(jsonb_build_object('key', k, 'label_it', l, 'done', coalesce((c -> k ->> 'done')::boolean, false), 'detail', c -> k ->> 'detail') order by o)
            from (values (1, 'uptime', 'Sito e funzioni del server'), (2, 'cron_jobs', 'Attività programmate del database'), (3, 'vault_secret', 'Segreto del backup'),
                         (4, 'offsite_backup', 'Copia del backup fuori sede'), (5, 'outside_watcher', 'Monitor esterno (GitHub)'), (6, 'restore_tested', 'Prova di ripristino'),
                         (7, 'repo_sync', 'Migrazioni: GitHub e database'), (8, 'app_deployed', 'App del tablet pubblicata'), (9, 'advisors_clean', 'Sicurezza del database')) v(o, k, l));
end $$;
revoke all on function fabula.system_checks() from public, anon;
grant execute on function fabula.system_checks() to authenticated;

-- ============================== E-27 compare live with the repo ==============================
create or replace function fabula._strip_sql_comments(p text) returns text
language sql immutable set search_path = fabula, public as $$
  select btrim(regexp_replace(regexp_replace(p, '--[^\n]*', '', 'g'), '\s+', ' ', 'g'))
$$;
-- every fabula function and view as an md5 (raw, and without comments and spacing): tools/ci/compare_live.py compares live with a
-- fresh replay of the repo, so a function pasted by hand or changed outside a migration is found (comment-only differences apart)
create or replace function fabula.schema_fingerprint() returns jsonb
language sql stable security definer set search_path = fabula, public as $$
  select jsonb_build_object(
    'functions', (select jsonb_object_agg(p.oid::regprocedure::text, jsonb_build_array(md5(pg_get_functiondef(p.oid)), md5(fabula._strip_sql_comments(pg_get_functiondef(p.oid)))))
                    from pg_proc p where p.pronamespace = 'fabula'::regnamespace and p.prokind in ('f', 'p')),
    'views', (select jsonb_object_agg(c.relname, md5(pg_get_viewdef(c.oid))) from pg_class c where c.relnamespace = 'fabula'::regnamespace and c.relkind in ('v', 'm')),
    'migrations', (select count(*) from supabase_migrations.schema_migrations),
    'last_migration', (select max(version) from supabase_migrations.schema_migrations))
$$;
revoke all on function fabula.schema_fingerprint() from public, anon, authenticated;

insert into fabula.security_accepted (key, reason) values
  ('authenticated_security_definer_function_executable:fabula.my_alarms()', 'by design (v1.05a, audit E-09): the open alarms of the caller''s own areas (all with Sistema) for Console → Oggi and the bell'),
  ('authenticated_security_definer_function_executable:fabula.system_checks()', 'by design (v1.05a, audit E-28): the system checks in Italian for Configurazione → Panoramica; Sistema ≥ vede')
on conflict (key) do nothing;

-- ======================= v105b =======================
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

-- ======================= v105c =======================
-- v1.05c · Audit 12/10/2026, area E:
--   * E-31 (Medium) the evening HACCP list is live on the tablet from 14:00 (not only from the 19:02 bot to 05:00): what is still to
--     record today, item by item. In the morning the tablet shows «Ieri non registrato» with yesterday's food-safety gaps, each
--     opening «Ricopia da foglio di carta» on yesterday's date. Badge-out after 14:00 asks first when food-safety items remain.
--     fabula.haccp_open_list() reads it without posting anything; haccp_evening_status() keeps the 19:02 notice and now counts the
--     Rome day (it used the UTC date: a reading at 00:30 counted for the day before). With E-32: nothing is asked before the tasks
--     start (unless milk or a lot was really worked), a closed day asks only the cold rooms, and a badge not passed is listed from
--     19:00 (before, it is someone still at work).
--   * E-30 (Low) the go-live checklist in Italian in Configurazione → Panoramica («Verso l'apertura»), for the titolare and the soci
--     (no longer only Nick's English board): each item with how it closes. A gate ticked by hand needs a note (what was done, where
--     the document is) and a confirmation, and records who and when; undoing it needs a note too. Every change is in the Registro.
--     That note is kept apart (sign_note): the working notes of Nick's board (note, English, with deal details) are not shown there.

-- ============================== E-31 the evening list, live ==============================
create or replace function fabula._haccp_evening_items(p_date date) returns jsonb
language plpgsql stable set search_path = fabula, public, extensions as $$
declare items jsonb := '[]'; n_ship int; n_milk int; n_abx int; v_real_prod boolean; v_start date := fabula.tasks_start_date();
begin
  v_real_prod := exists (select 1 from fabula.production_batches where batch_date = p_date and source <> 'simulation');
  -- v1.05 (audit E-32): nothing is asked before the tasks start, unless milk or a lot was really worked that day (food safety first)
  if v_start is not null and p_date < v_start and not v_real_prod
     and not exists (select 1 from fabula.milk_intake where intake_date = p_date and source <> 'simulation') then
    return items;
  end if;
  -- the Rome day (v1.05: logged_at::date was the UTC date)
  select coalesce(jsonb_agg(jsonb_build_object('code', 'cold:' || cp.code, 'label_it', 'Temperatura serale ' || coalesce(e.code, cp.name), 'scan', 'EQ:' || e.code) order by cp.code), '[]') into items
  from fabula.haccp_control_points cp left join fabula.equipment e on e.id = cp.equipment_id
  where cp.active and cp.frequency = 'twice_daily'
    and not exists (select 1 from fabula.haccp_log l where l.control_point_id = cp.id and (l.logged_at at time zone 'Europe/Rome')::date = p_date
                                                         and (l.logged_at at time zone 'Europe/Rome')::time >= time '15:00');
  -- the end-of-shift cleaning, not on a closed day with no production (only the cold rooms are checked then)
  if not (fabula.is_closed_day(p_date) and not v_real_prod)
     and not exists (select 1 from fabula.haccp_log l join fabula.haccp_control_points cp on cp.id = l.control_point_id
                  where cp.code = 'PRP-CLEAN' and (l.logged_at at time zone 'Europe/Rome')::date = p_date) then
    items := items || jsonb_build_object('code', 'clean', 'label_it', 'Sanificazione fine turno', 'scan', 'CLEAN:');
  end if;
  if exists (select 1 from fabula.production_batches where batch_date = p_date) or exists (select 1 from fabula.sales_orders where order_date = p_date) then
    if not exists (select 1 from fabula.meter_readings where meter = 'elec_main' and (read_at at time zone 'Europe/Rome')::date = p_date) then
      items := items || jsonb_build_object('code', 'kwh', 'label_it', 'Lettura contatore', 'scan', 'METER:elec_main'); end if;
  end if;
  if v_real_prod and not exists (select 1 from fabula.effluent_log where log_date = p_date) then
    items := items || jsonb_build_object('code', 'effluent', 'label_it', 'Reflui del giorno (scotta, acque di lavaggio)', 'scan', 'EFFL:');
  end if;
  -- food safety: CCP per real batch (filatura for mozzarella, affioramento for ricotta, pasteurisation when the milk is pasteurised)
  select items || coalesce(jsonb_agg(jsonb_build_object('code', 'ccp:' || cp.code || ':' || b.batch_lot,
                                                        'label_it', cp.ccp_no || ' ' || cp.name || ' · lotto ' || b.batch_lot,
                                                        'scan', 'CCP:' || cp.code || ':' || b.batch_lot) order by b.batch_lot, cp.sort), '[]') into items
  from fabula.production_batches b
  join fabula.haccp_control_points cp on cp.active and (
         cp.code = case when b.input_kind = 'whey' then 'CCP-RIC' else 'CCP-STRETCH' end
      or (cp.code = 'CCP-PAST' and b.input_kind <> 'whey' and fabula.setting_text('food.milk_process', 'crudo') = 'pastorizzato'))
  where b.batch_date = p_date and b.source <> 'simulation'
    and not exists (select 1 from fabula.haccp_log l where l.batch_id = b.id and l.control_point_id = cp.id);
  select count(*) into n_milk from fabula.milk_intake where intake_date = p_date and source <> 'simulation';
  select count(*) into n_abx from fabula.haccp_log l join fabula.haccp_control_points cp on cp.id = l.control_point_id
   where cp.code = 'CCP-MILK-ABX' and (l.logged_at at time zone 'Europe/Rome')::date = p_date;
  if n_milk > n_abx then
    items := items || jsonb_build_object('code', 'abx', 'label_it', format('CCP 1b test antibiotici: %s conferimenti di latte senza esito', n_milk - n_abx), 'scan', 'CCP:CCP-MILK-ABX');
  end if;
  if v_real_prod and not exists (select 1 from fabula.calibration_checks c join fabula.equipment e on e.id = c.equipment_id
                                 where e.code = 'PH-01' and (c.checked_at at time zone 'Europe/Rome')::date = p_date) then
    items := items || jsonb_build_object('code', 'ph', 'label_it', 'Calibrazione pH-metro (tamponi 4 e 7)', 'scan', 'CAL:PH-01');
  end if;
  select count(*) into n_ship from fabula.v_orders_to_ship where channel = 'shopify';
  if n_ship > 0 then
    items := items || jsonb_build_object('code', 'ship', 'label_it', n_ship || ' ordini online pagati da spedire', 'scan', 'SHIP:');
  end if;
  select items || coalesce(jsonb_agg(jsonb_build_object('code', 'batch:' || batch_lot, 'label_it', 'Lotto ' || batch_lot || ' non chiuso (kg prodotto)', 'scan', 'LOT:' || batch_lot)), '[]') into items
  from fabula.production_batches where batch_date = p_date and output_kg is null and source <> 'simulation';
  select items || coalesce(jsonb_agg(jsonb_build_object('code', 'shift:' || st.badge_code, 'label_it', st.full_name || ': badge di uscita non passato', 'scan', st.badge_code)), '[]') into items
  from fabula.shifts s join fabula.staff st on st.id = s.staff_id where s.clock_out is null and (s.clock_in at time zone 'Europe/Rome')::date = p_date;
  return items;
end $$;
revoke all on function fabula._haccp_evening_items(date) from public, anon;
grant execute on function fabula._haccp_evening_items(date) to authenticated, service_role;   -- invoker: haccp_evening_status runs as its caller

create or replace function fabula.haccp_evening_status(p_date date default ((now() at time zone 'Europe/Rome'::text))::date)
 returns jsonb
 language plpgsql
 set search_path to 'fabula', 'public', 'extensions'
as $function$
declare items jsonb := fabula._haccp_evening_items(p_date); v_key text := 'haccp_evening:' || p_date; n int;
begin
  n := jsonb_array_length(items);
  if n > 0 then
    insert into fabula.notices (key, severity, title_it, items, expires_at)
    values (v_key, 'alert', format('Prima di chiudere: %s cose da registrare', n), items, ((p_date + 1)::timestamp + time '05:00') at time zone 'Europe/Rome')
    on conflict (key) do update set items = excluded.items, title_it = excluded.title_it, resolved_at = null;
  else
    update fabula.notices set resolved_at = now() where key = v_key and resolved_at is null;
  end if;
  return jsonb_build_object('date', p_date, 'missing', items, 'count', n,
    'lots_on_hold', (select coalesce(jsonb_agg(batch_lot), '[]') from fabula.v_lots_on_hold),
    'is_simulation', exists (select 1 from fabula.simulation_runs where p_date between from_date and to_date),
    'closed_day', not (exists (select 1 from fabula.production_batches where batch_date = p_date) or exists (select 1 from fabula.sales_orders where order_date = p_date)));
end $function$;

-- the tablet's live list: today's (from the tasks start) and yesterday's food-safety gaps, which open the paper copy on yesterday's date
create or replace function fabula.haccp_open_list() returns jsonb
language plpgsql stable security definer set search_path = fabula, public as $$
declare v_today date := (now() at time zone 'Europe/Rome')::date; t jsonb; y jsonb := '[]';
begin
  if greatest(fabula.perm_level('haccp'), fabula.perm_level('produzione')) < 1 then
    raise exception 'Il tuo profilo non vede le registrazioni HACCP' using errcode = '42501';
  end if;
  -- before the tasks start the items are empty (unless something was really produced); a badge not passed is asked from 19:00, not
  -- while the person is still working
  select coalesce(jsonb_agg(i order by o), '[]'::jsonb) into t
    from jsonb_array_elements(fabula._haccp_evening_items(v_today)) with ordinality x(i, o)
   where not (i ->> 'code' like 'shift:%' and extract(hour from now() at time zone 'Europe/Rome') < 19);
  -- yesterday's food-safety gaps, each opening the paper copy on yesterday's date
  select coalesce(jsonb_agg(i || jsonb_build_object('scan', 'PAPER:' || case
             when i ->> 'code' like 'cold:%' then substr(i ->> 'code', 6)
             when i ->> 'code' = 'clean' then 'PRP-CLEAN'
             when i ->> 'code' = 'abx' then 'CCP-MILK-ABX'
             else split_part(i ->> 'code', ':', 2) end
           || '@' || (v_today - 1)::text
           || case when i ->> 'code' like 'ccp:%' then '@' || split_part(i ->> 'code', ':', 3) else '' end) order by o), '[]'::jsonb)
    into y
    from jsonb_array_elements(fabula._haccp_evening_items(v_today - 1)) with ordinality x(i, o)
   where i ->> 'code' ~ '^(cold:|ccp:|clean$|abx$)';
  return jsonb_build_object('date', v_today, 'items', t, 'count', jsonb_array_length(t),
    'food_safety', (select count(*) from jsonb_array_elements(t) i where i ->> 'code' ~ '^(cold:|ccp:|clean$|abx$)'),
    'yesterday', jsonb_build_object('date', v_today - 1, 'items', y, 'count', jsonb_array_length(y)));
end $$;
revoke all on function fabula.haccp_open_list() from public, anon;
grant execute on function fabula.haccp_open_list() to authenticated;

-- ============================== E-30 the go-live checklist in Italian, signed ==============================
alter table fabula.dash_checks add column if not exists label_it text;
alter table fabula.dash_checks add column if not exists hint_it text;
alter table fabula.dash_checks add column if not exists done_by_id uuid references fabula.staff(id);
alter table fabula.dash_checks add column if not exists done_at timestamptz;
alter table fabula.dash_checks add column if not exists sign_note text;
comment on column fabula.dash_checks.sign_note is 'v1.05 (audit E-30): the note written when the item was ticked or unticked in Configurazione → Panoramica «Verso l''apertura» (what was done, where the document is / why undone). note stays the working note of tools/go-live/golive-board.html.';
update fabula.dash_checks c set label_it = v.l, hint_it = v.h from (values
  ('deal_signed', 'Atto di acquisto firmato dopo la due diligence', 'Si segna a mano a atto firmato, con il riferimento nella nota.'),
  ('lease_signed', 'Contratto d''affitto firmato e registrato a nome della Masseria', 'Si segna a mano a contratto registrato.'),
  ('ce_approval', 'Attività alimentare a nome della Masseria (riconoscimento CE, SCIA)', 'Si chiude da solo quando il numero di riconoscimento è in Configurazione → Sicurezza alimentare.'),
  ('dop_control', 'DOP: inseriti nel controllo RINA, marchi del Consorzio ordinati', 'Si segna a mano.'),
  ('haccp_training', 'Formazione HACCP valida per tutti quelli in produzione', 'Si chiude da solo quando ogni persona attiva ha l''attestato valido (Console → Personale).'),
  ('manuale_signed', 'Manuale di Autocontrollo firmato', 'Si chiude da solo quando la versione del manuale non è più «bozza» (Configurazione → Sicurezza alimentare).'),
  ('einvoicing', 'Fatturazione elettronica pronta (Fatture in Cloud, PEC, codice SDI)', 'Si segna a mano.'),
  ('rt_printer', 'Registratore telematico installato', 'Si segna a mano.'),
  ('company_docs', 'Dati della società su DDT e ordini (ragione sociale, P.IVA, indirizzo)', 'Si chiude da solo con ragione sociale, P.IVA e via in Configurazione → Azienda.'),
  ('opening_date', 'Data di apertura impostata', 'Si chiude da solo con la data in Configurazione → Marketing.'),
  ('stock_count', 'Conta di magazzino di apertura registrata', 'Si chiude da solo dopo la prima conta registrata dal tablet.'),
  ('placeholders', 'Nomi veri di fornitori e clienti (niente nomi provvisori o clienti di prova)', 'Si chiude da solo quando non restano nomi provvisori: Console → Anagrafiche.'),
  ('recipes', 'Dosi delle ricette confermate dal casaro', 'Si chiude da solo quando nessuna dose è più provvisoria: Console → Ricette.'),
  ('vat_capacity', 'Capacità della caldaia Fortino confermata', 'Si segna a mano dopo averla misurata (Configurazione → Produzione).'),
  ('compliance_dates', 'Ogni scadenza ha una data', 'Si chiude da solo quando tutte le scadenze hanno una data: Configurazione → Scadenze.'),
  ('equipment_dates', 'Data di taratura su ogni macchina', 'Si chiude da solo quando ogni macchina ha la data: Configurazione → Macchine.'),
  ('shopify_catalog', 'Decisioni sul catalogo Shopify prese', 'Si segna a mano.'),
  ('labels', 'Etichette di vendita approvate (marchio, logo DOP, scadenza)', 'Si segna a mano.'),
  ('bots_activated', 'Bot del caseificio accesi', 'Si segna a mano il giorno in cui si entra nel caseificio, dopo aver controllato i bot in Configurazione → Bot.'),
  ('tablet_checkin', 'Tablet di produzione aggiornato all''ultima app', 'Si chiude da solo quando il tablet si collega con l''ultima versione.'),
  ('first_milk', 'Primo latte vero ricevuto', 'Si chiude da solo al primo arrivo di latte registrato.'),
  ('first_batch', 'Primo lotto vero registrato', 'Si chiude da solo al primo lotto registrato.'),
  ('moisture_test', 'Analisi DOP superata (umidità ≤ 65 %)', 'Si chiude da solo con un esito conforme in Autocontrollo → Laboratorio.'),
  ('first_shipment', 'Primo ordine vero preparato con il suo DDT', 'Si chiude da solo alla prima spedizione vera.'),
  ('paper_fallback', 'Fogli di carta pronti per quando il tablet o il Wi-Fi non vanno', 'Si segna a mano dopo averli stampati (Autocontrollo → Registri → foglio vuoto).'),
  ('trial_start', 'Data della settimana di prova impostata', 'Si chiude da solo con la data in Configurazione → Settimana di prova.'),
  ('alerts_linked', 'Gli avvisi di sicurezza alimentare arrivano a ogni socio su Telegram', 'Si chiude da solo quando ogni socio ha collegato Telegram (Configurazione → Utenti e accessi).'),
  ('badges_printed', 'Badge stampati e passati una volta sul tablet', 'Si chiude da solo quando ogni persona ha passato il badge.'),
  ('sim_purged', 'Dati della simulazione cancellati', 'Si chiude da solo quando non restano dati simulati.'),
  ('code_pushed', 'Ultimo codice su GitHub', 'Si chiude da solo (controllo orario).'),
  ('app_deployed', 'App del tablet pubblicata = ultima su GitHub', 'Si chiude da solo (controllo orario).'),
  ('repo_sync', 'Migrazioni del repo uguali al database', 'Si chiude da solo (controllo orario).'),
  ('leaked_pw', 'Protezione delle password già trapelate attiva', 'Si segna a mano dopo averla attivata su Supabase → Authentication.'),
  ('fix_first', 'Correzioni urgenti dell''audit chiuse (fase 0 e critiche)', 'Si segna a mano.'),
  ('second_login', 'Una seconda persona riesce ad accedere', 'Si chiude da solo quando due persone hanno fatto l''accesso.'),
  ('pitr', 'Backup fuori dal database nelle ultime 26 ore', 'Si chiude da solo.'),
  ('restore_tested', 'Ripristino del backup provato (ultimi 100 giorni)', 'Si chiude da solo con la prova mensile automatica.'),
  ('bots_clean', 'Nessun errore dei bot nelle ultime 24 ore', 'Si chiude da solo.'),
  ('advisors_clean', 'Nessuna nuova segnalazione di sicurezza del database', 'Si chiude da solo.'),
  ('uptime', 'Sito del tablet e funzioni del server attivi', 'Si chiude da solo (controllo orario).'),
  ('outside_watcher', 'Monitor esterno attivo (GitHub, ultimo giro < 24 h)', 'Si chiude da solo.'),
  ('offsite_backup', 'Copia del backup fuori sede nelle ultime 2 notti', 'Si chiude da solo.')) v(k, l, h)
 where c.key = v.k;

-- a manual gate is ticked (or unticked) only with a note, by the titolare or a socio, and says who and when
create or replace function fabula.dash_set_check(p_key text, p_done boolean, p_note text default null::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'fabula', 'public', 'extensions'
as $function$
declare r fabula.dash_checks; v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if auth.uid() is not null then
    perform fabula.require_perm('sistema', 3);
    if v_note is null or length(v_note) < 3 then
      raise exception using errcode = '22023', message = case when p_done then 'Scrivi una nota: cosa è stato fatto e dove sta il documento'
                                                              else 'Scrivi perché si annulla' end;
    end if;
  end if;
  -- a login writes the signing note; Nick's board (SQL, no login) keeps writing its working note as before, and its tick says so
  update fabula.dash_checks
     set done = p_done, updated_at = now(),
         note = case when auth.uid() is null then coalesce(v_note, note) else note end,
         sign_note = case when auth.uid() is not null then v_note when p_done then 'Segnato dalla lavagna tecnica di Nick' end,
         done_by_id = case when p_done then fabula.my_staff_id() end, done_at = case when p_done then now() end
   where key = p_key and kind = 'manual'
  returning * into r;
  if r.key is null then
    raise exception using errcode = '22023', message = format('«%s» non si segna a mano: si aggiorna da solo dai dati', p_key);
  end if;
  return to_jsonb(r);
end $function$;
revoke all on function fabula.dash_set_check(text, boolean, text) from public, anon;
grant execute on function fabula.dash_set_check(text, boolean, text) to authenticated;

-- a login changes the list only through dash_set_check (a definer function: there current_user is the owner, not «authenticated»)
create or replace function fabula.trg_dash_checks_guard() returns trigger
language plpgsql set search_path = fabula, public as $$
begin
  if current_user not in ('authenticated', 'anon') then return coalesce(new, old); end if;
  if tg_op = 'UPDATE' and (to_jsonb(new) - 'updated_at') = (to_jsonb(old) - 'updated_at') then return new; end if;
  raise exception using errcode = '42501', message = 'La lista per l''apertura si segna da Configurazione → Panoramica → Verso l''apertura, con una nota';
end $$;
drop trigger if exists dash_checks_guard on fabula.dash_checks;
create trigger dash_checks_guard before insert or update or delete on fabula.dash_checks for each row execute function fabula.trg_dash_checks_guard();
drop trigger if exists dash_checks_audit on fabula.dash_checks;
create trigger dash_checks_audit after update or delete on fabula.dash_checks for each row execute function fabula.trg_audit();

create or replace function fabula.golive_checklist() returns jsonb
language plpgsql stable security definer set search_path = fabula, public as $$
declare d jsonb;
begin
  if not fabula.can('sistema', 1) then raise exception 'Il tuo profilo non vede la lista per l''apertura' using errcode = '42501'; end if;
  d := coalesce(fabula.ops_dashboard() -> 'checks', '[]'::jsonb);
  return jsonb_build_object('can_sign', fabula.can('sistema', 3), 'items',
    (select coalesce(jsonb_agg(jsonb_build_object('key', c.key, 'label', coalesce(c.label_it, c.label), 'kind', c.kind,
              'done', coalesce((x ->> 'done')::boolean, c.done), 'hint', c.hint_it, 'note', case when c.kind = 'manual' then c.sign_note end,
              'done_at', c.done_at, 'done_by', s.full_name) order by c.sort), '[]'::jsonb)
       from fabula.dash_checks c
       left join lateral (select e as x from jsonb_array_elements(d) e where e ->> 'key' = c.key limit 1) dd on true
       left join fabula.staff s on s.id = c.done_by_id));
end $$;
revoke all on function fabula.golive_checklist() from public, anon;
grant execute on function fabula.golive_checklist() to authenticated;

insert into fabula.security_accepted (key, reason) values
  ('authenticated_security_definer_function_executable:fabula.haccp_open_list()', 'by design (v1.05c, audit E-31): the tablet''s live evening list and yesterday''s food-safety gaps; haccp or produzione ≥ vede'),
  ('authenticated_security_definer_function_executable:fabula.dash_set_check(p_key text, p_done boolean, p_note text)', 'by design (v1.05c, audit E-30): a go-live gate ticked with a note; Sistema = gestisce'),
  ('authenticated_security_definer_function_executable:fabula.golive_checklist()', 'by design (v1.05c, audit E-30): the go-live list in Italian for Panoramica; Sistema ≥ vede')
on conflict (key) do nothing;

insert into supabase_migrations.schema_migrations (version, name) values
  ('20261015090000', 'v105a_messages_checks'),
  ('20261015090100', 'v105b_prompts_tasks'),
  ('20261015090200', 'v105c_evening_golive');
commit;

select version, name from supabase_migrations.schema_migrations order by version desc limit 5;
