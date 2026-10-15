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
