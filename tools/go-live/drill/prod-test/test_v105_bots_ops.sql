-- v1.05 bots, alerts and operations (audit E-06, E-09, E-14, E-16, E-17, E-19, E-27, E-28, E-30, E-31, E-32) · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh a_test
--   su postgres -c "psql -d a_test -f tools/go-live/drill/prod-test/test_v105_bots_ops.sql" | grep -E "PASS|FAIL"
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as
$$ declare h text; begin execute p_sql; return ''; exception when others then get stacked diagnostics h = pg_exception_hint; return sqlerrm || case when coalesce(h, '') <> '' then ' || hint: ' || h else '' end; end $$;
create or replace function pg_temp.as_user(p_sub text) returns void language sql as
$$ select set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_sub), false) $$;
insert into fabula.staff (id, full_name, role, app_role, active, auth_user_id) values
  ('10000000-0000-4000-a000-000000105a01', 'Titolare V', 'owner', 'titolare', true, '00000000-0000-4000-a000-000000105a01'),
  ('10000000-0000-4000-a000-000000105a02', 'Ufficio V', 'operaio', 'amministrazione', true, '00000000-0000-4000-a000-000000105a02'),
  ('10000000-0000-4000-a000-000000105a03', 'Marketing V', 'operaio', 'marketing', true, '00000000-0000-4000-a000-000000105a03'),
  ('10000000-0000-4000-a000-000000105a04', 'Casaro V', 'casaro', 'produzione', true, '00000000-0000-4000-a000-000000105a04')
on conflict do nothing;
\set tit '00000000-0000-4000-a000-000000105a01'
\set uff '00000000-0000-4000-a000-000000105a02'
\set mkt '00000000-0000-4000-a000-000000105a03'
\set cas '00000000-0000-4000-a000-000000105a04'
select (now() at time zone 'Europe/Rome')::date d \gset
select (now() at time zone 'Europe/Rome')::date - 1 y \gset
select id moz from fabula.products where sku = 'MOZ-DOP-KG' \gset
insert into fabula.parties (type, legal_name, is_milk_supplier) values ('supplier', 'Masseria V', true) returning id sup \gset

-- ============================== E-06 · one rule for each database message ==============================
insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source)
values (:'d'::date - 3, '07:00', :'sup', 'MV105-OLD', 500, true, 4, 'tablet');
select fabula.prod_watch(((:'d'::date + time '19:10') at time zone 'Europe/Rome'))::text pw \gset
-- v1.20 (MILK-1): the evening watch's milk message is now «… latte non lavorat… in giornata» (rule «latte_non_lavorato», was «latte_60_ore»)
select severity sev60, title t60 from fabula.bot_messages where agent = 'sicurezza' and title like '%latte non lavorat% in giornata' order by id desc limit 1 \gset
select pg_temp.ck('E-06 milk not worked on its day is an alarm (the function still posts «warn»; the rule decides)', :'sev60' = 'alert', :'pw' || ' / ' || :'sev60');
select pg_temp.ck('E-06 …and goes to the food-safety topic', fabula.notify_topic_for('sicurezza', :'t60') = 'food_safety');
select fabula.post_bot_message('tablet', 'info', '3 registrazioni rifiutate dal database (tablet T1)', 'x') tid \gset
select fabula.post_bot_message('sales', 'warn', 'Tre nuovi contatti', 'x') sid \gset
select fabula.post_bot_message('rota_x', 'alert', 'Qualcosa', 'x') xid \gset
select pg_temp.ck('E-06 a ruled database message takes the rule''s severity; a bot''s own message (no rule) keeps its own',
  (select severity from fabula.bot_messages where id = :tid) = 'alert' and (select severity from fabula.bot_messages where id = :sid) = 'warn'
  and (select severity from fabula.bot_messages where id = :xid) = 'alert');
select fabula.post_bot_message('auto_approve', 'warn', 'Approvato da solo: piano latte di domani', 'x') aid \gset
select pg_temp.ck('E-06 a rule without a severity leaves it to the function (approved by itself: «warn» when it commits milk or money)',
  (select severity from fabula.bot_messages where id = :aid) = 'warn');
update fabula.bot_messages set severity = 'info' where id = :tid;
select pg_temp.ck('E-06 …and a later change cannot lower a ruled message', (select severity from fabula.bot_messages where id = :tid) = 'alert');
insert into fabula.notices (key, severity, title_it, items, expires_at) values ('bot_alert:v105', 'warn', 'Bot fermo', '[]', now() + interval '1 day');
insert into fabula.notices (key, severity, title_it, items, expires_at) values ('recon:v105', 'alert', 'Incassi', '[]', now() + interval '1 day');
select pg_temp.ck('E-06 notices too: bot down = alarm, takings to check = warning',
  (select severity from fabula.notices where key = 'bot_alert:v105') = 'alert' and (select severity from fabula.notices where key = 'recon:v105') = 'warn');
select pg_temp.ck('E-06 the Telegram topic comes from the same rule (notices and messages), the old words-based guess only without a rule',
  fabula.notify_topic_for('notice', 'Incassi', 'recon:v105') = 'decisions' and fabula.notify_topic_for('notice', 'x', 'haccp_evening:2026-10-15') = 'food_safety'
  and fabula.notify_topic_for('tablet', 'Il tablet T1 usa ancora la versione perla-v70') = 'infra'
  and fabula.notify_topic_for('sales', 'Cliente con lotto non conforme') = 'food_safety' and fabula.notify_topic_for('sales', 'Tre nuovi contatti') = 'decisions');
select pg_temp.ck('E-06 the rules table: every rule has a meaning in Italian, a topic and an area',
  (select count(*) from fabula.message_rules) >= 30 and not exists (select 1 from fabula.message_rules where coalesce(meaning_it, '') = '' or area is null));
select pg_temp.as_user(:'mkt');
set role authenticated;
select count(*) mr_mkt from fabula.message_rules \gset
reset role;
select pg_temp.as_user(:'uff');
set role authenticated;
select count(*) mr_uff from fabula.message_rules \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('E-06 every active staff member reads what the messages mean (the notices'' areas come from it); nobody signed out',
  :mr_mkt >= 30 and :mr_uff >= 30 and not has_table_privilege('anon', 'fabula.message_rules', 'SELECT'), :mr_mkt || ' / ' || :mr_uff);
select pg_temp.ck('E-06 the Telegram topic of a «non partita» sync alarm is the system''s, though the topic is looked up on title and body',
  fabula.notify_topic_for('shopify_orders', 'Sincronizzazione ordini non partita Il server non ha risposto alle 06:11') = 'infra');

-- ============================== E-09 · alarms for every office profile ==============================
update fabula.bot_messages set read_at = now() where read_at is null;
select fabula.post_bot_message('sales', 'alert', 'Cliente perso: Pizzeria V', 'x') a_sales \gset
select fabula.post_bot_message('sicurezza', 'alert', 'Lotto LV1 chiuso senza filatura', 'x') a_haccp \gset
select fabula.post_bot_message('ops_health', 'alert', 'Backup fermo da 2 giorni', 'x') a_tab \gset
select fabula.post_bot_message('marketing', 'warn', 'Post della settimana', 'x') a_warn \gset
select pg_temp.as_user(:'mkt');
select fabula.my_alarms()::text al_mkt \gset
select fabula.bot_bell()::text bell_mkt \gset
select pg_temp.as_user(:'uff');
select fabula.my_alarms()::text al_uff \gset
select fabula.bot_bell()::text bell_uff \gset
select pg_temp.as_user(:'cas');
select fabula.my_alarms()::text al_cas \gset
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('E-09 a marketing profile (no Sistema) sees the open alarms of its areas: the sales one, not food safety nor the tablet',
  :'al_mkt'::jsonb @> format('[{"id":%s,"area":"vendite"}]', :a_sales)::jsonb and not :'al_mkt'::jsonb @> format('[{"id":%s}]', :a_haccp)::jsonb
  and not :'al_mkt'::jsonb @> format('[{"id":%s}]', :a_tab)::jsonb and not :'al_mkt'::jsonb @> format('[{"id":%s}]', :a_warn)::jsonb, :'al_mkt');
select pg_temp.ck('E-09 …and its bell counts them (scope «aree», it opens Console → Oggi)', (:'bell_mkt'::jsonb ->> 'alerts')::int = jsonb_array_length(:'al_mkt'::jsonb)
  and :'bell_mkt'::jsonb ->> 'scope' = 'aree' and jsonb_array_length(:'al_mkt'::jsonb) >= 1, :'bell_mkt');
select pg_temp.ck('E-09 the office (Sistema «vede») sees every alarm; its bell counts them all',
  :'al_uff'::jsonb @> format('[{"id":%s},{"id":%s},{"id":%s}]', :a_sales, :a_haccp, :a_tab)::jsonb and :'bell_uff'::jsonb ->> 'scope' = 'tutti', :'bell_uff');
select pg_temp.ck('E-09 the casaro sees the food-safety alarm (HACCP area)', :'al_cas'::jsonb @> format('[{"id":%s,"area":"haccp"}]', :a_haccp)::jsonb, :'al_cas');
update fabula.bot_messages set read_at = now() where id = :a_sales;
select pg_temp.as_user(:'mkt');
select jsonb_array_length(fabula.my_alarms()) al_mkt2 \gset
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('E-09 a handled alarm leaves the list', :al_mkt2 = jsonb_array_length(:'al_mkt'::jsonb) - 1, :al_mkt2::text);
select pg_temp.ck('E-09 nobody signed out reads the alarms', not has_function_privilege('anon', 'fabula.my_alarms()', 'EXECUTE') and jsonb_array_length(fabula.my_alarms()) = 0);
insert into fabula.notices (key, severity, title_it, items, expires_at) values ('lab_lot_unknown:v105', 'warn', 'Analisi non conforme su un lotto sconosciuto', '[]', now() + interval '1 day');
select pg_temp.as_user(:'cas');
select fabula.bot_bell()::text bell_cas \gset
select jsonb_array_length(fabula.my_alarms()) ma_cas \gset
select area na_cas from fabula.v_active_notices where key = 'lab_lot_unknown:v105' \gset
select pg_temp.as_user(:'mkt');
select fabula.bot_bell()::text bell_mkt2 \gset
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('E-09 an alarm notice counts in the bell of the profiles of its area (food safety: the casaro, not marketing)',
  :'na_cas' = 'haccp' and (:'bell_cas'::jsonb ->> 'alerts')::int = :ma_cas + 1 and (:'bell_mkt2'::jsonb ->> 'alerts')::int = :al_mkt2,
  :'bell_cas' || ' / ' || :'bell_mkt2');
update fabula.notices set resolved_at = now() where key = 'lab_lot_unknown:v105';

-- ============================== E-14 / E-27 / E-28 · system checks in Italian ==============================
insert into fabula.infra_status (key, ok, detail, data, checked_at, last_ok_at)
select 'github_tree', true, 'x', jsonb_build_object('versions', jsonb_agg(version) || '["29990101000000"]'::jsonb), now(), now() from supabase_migrations.schema_migrations
on conflict (key) do update set data = excluded.data, ok = true, checked_at = now(), last_ok_at = now();
select fabula.infra_checks()::text ic1 \gset
-- v1.08: the release pipeline applies migrations; the texts say to approve the release (was «applica lo script SQL Editor» / «git push» dal Mac)
select pg_temp.ck('E-27 a migration on GitHub but not applied live: the release waits for the approval on GitHub, no push',
  :'ic1'::jsonb #>> '{repo_sync,detail}' = '1 su GitHub ma non applicate sul database (29990101000000): il rilascio aspetta l''approvazione su GitHub (Actions → Release → «Review deployments»)'
  and (:'ic1'::jsonb #>> '{code_pushed,done}')::boolean, :'ic1'::jsonb #>> '{repo_sync,detail}');
update fabula.infra_status set data = jsonb_build_object('versions', (select jsonb_agg(version) from supabase_migrations.schema_migrations
                                                                       where version < (select max(version) from supabase_migrations.schema_migrations)))
 where key = 'github_tree';
select fabula.infra_checks()::text ic2 \gset
select pg_temp.ck('E-27 a migration live but not on GitHub: applied outside the release, its file goes on main',
  :'ic2'::jsonb #>> '{code_pushed,detail}' like '1 migrazione applicata sul database ma non su GitHub: %. Applicate fuori dal rilascio automatico: il file va salvato su GitHub main'
  and :'ic2'::jsonb #>> '{repo_sync,detail}' = '1 sul database ma non su GitHub: il file va salvato su GitHub main', :'ic2'::jsonb #>> '{code_pushed,detail}');
insert into fabula.infra_status (key, ok, detail, checked_at, last_ok_at) values
  ('site', false, 'timeout', now(), now() - interval '2 hours'), ('fn_farm_order', true, '403', now(), now()), ('fn_backup_export', true, '403', now(), now())
on conflict (key) do update set ok = excluded.ok, detail = excluded.detail, checked_at = excluded.checked_at;
insert into fabula.agent_runs (agent, status, summary, error) values ('restore_drill', 'error', 'x', '3 tabelle diverse');
select fabula.infra_checks()::text ic3 \gset
select pg_temp.ck('E-14 every system check detail is Italian (down item named, failed drill)',
  :'ic3'::jsonb #>> '{uptime,detail}' = 'Non risponde o non controllato: sito del tablet (tempo scaduto)'
  and :'ic3'::jsonb #>> '{restore_tested,detail}' like 'Ultima prova FALLITA il %: 3 tabelle diverse'
  and :'ic3' !~ '(Waiting|from the Mac|not on GitHub|has not deployed|Last drill|No drill|answered at|not answering|Not reporting|Silent since|No off-site)', :'ic3');
select pg_temp.err($q$insert into fabula.notices (key, severity, title_it, items, expires_at) values ('lot_guard:v105', 'warn', 'x', '[{"code":"a"},{"lot":"L9"},{"code":"b","label_it":"Già scritto"}]', now() + interval '1 day')$q$) ni \gset
insert into fabula.notices (key, severity, title_it, items, expires_at) values ('infra_drift', 'warn', 'GitHub, sito del tablet e database non allineati da più di 6 ore: cosa fare è scritto qui sotto',
  '[{"code":"repo_sync","label_it":"1 su GitHub ma non applicate sul database (29990101000000): il rilascio aspetta l''approvazione su GitHub (Actions → Release → «Review deployments»)"}]', now() + interval '2 hours')
on conflict (key) do update set items = excluded.items, title_it = excluded.title_it, resolved_at = null, expires_at = excluded.expires_at;
select body drift_body from fabula.bot_messages where notice_key = 'infra_drift' order by id desc limit 1 \gset
select pg_temp.ck('E-27 the drift notice''s copy in the bots'' feed says the same way to fix it (no «git push» when the migration is not applied live)',
  :'drift_body' like '%il rilascio aspetta l''approvazione su GitHub%' and :'drift_body' not like '%git push%', :'drift_body');
select pg_temp.ck('E-14 a notice item without a label gets one (no raw data on a screen)', :'ni' = ''
  and (select items from fabula.notices where key = 'lot_guard:v105') = '[{"code":"a","label_it":"Dettaglio non disponibile"},{"lot":"L9","label_it":"Lotto L9"},{"code":"b","label_it":"Già scritto"}]'::jsonb,
  (select items::text from fabula.notices where key = 'lot_guard:v105'));
select fabula.cron_jobs_check()::text cj1 \gset
select pg_temp.ck('E-28 every expected database job is there and on (the save-ledger trim now made by the migration; daily tasks back on)',
  (:'cj1'::jsonb ->> 'done')::boolean and exists (select 1 from cron.job where jobname = 'fabula_save_ledger_trim')
  and exists (select 1 from cron.job where jobname = 'fabula_daily_tasks' and active), :'cj1');
update cron.job set active = false where jobname = 'fabula_recon';
delete from cron.job where jobname = 'fabula_trial_report';
select fabula.cron_jobs_check()::text cj2 \gset
select pg_temp.ck('E-28 a missing or switched-off job is named, with what to do',
  not (:'cj2'::jsonb ->> 'done')::boolean and :'cj2'::jsonb ->> 'detail' like 'mancano: fabula_trial_report · spente: fabula_recon. Si rimettono%', :'cj2');
select fabula.vault_secret_check()::text vs \gset
select pg_temp.ck('E-28 the backup secret is checked (Italian, a yes/no)', jsonb_typeof(:'vs'::jsonb -> 'done') = 'boolean' and :'vs'::jsonb ->> 'detail' ~ '(Vault|segreto|Segreto)', :'vs');
select pg_temp.as_user(:'uff');
select fabula.system_checks()::text sc_uff \gset
select pg_temp.as_user(:'mkt');
select pg_temp.err('select fabula.system_checks()') sc_mkt \gset
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('E-28 Configurazione → Panoramica → Sistema: 12 checks in Italian (v1.06: «Numeri dei messaggi», v1.08: «Rilasci automatici»), the missing job and the bots'' instructions among them',
  jsonb_array_length(:'sc_uff'::jsonb) = 12 and :'sc_uff'::jsonb @> '[{"key":"cron_jobs","label_it":"Attività programmate del database","done":false},{"key":"bot_prompts"},{"key":"vault_secret"}]'::jsonb,
  :'sc_uff');
select pg_temp.ck('E-28 …only with Sistema', :'sc_mkt' = 'Il tuo profilo non vede lo stato del sistema', :'sc_mkt');
update cron.job set active = true where jobname = 'fabula_recon';
select pg_temp.ck('E-27 the fingerprint: every function twice (as is, and without comments), every view; Claude only',
  (select count(*) from jsonb_object_keys(fabula.schema_fingerprint() -> 'functions')) > 300
  and fabula.schema_fingerprint() -> 'functions' -> 'pct_change(numeric,numeric)' ->> 1 = md5(fabula._strip_sql_comments(pg_get_functiondef('fabula.pct_change(numeric,numeric)'::regprocedure)))
  and fabula._strip_sql_comments(E'select 1 -- uno\n   + 2') = fabula._strip_sql_comments('select 1 + 2')
  and not has_function_privilege('authenticated', 'fabula.schema_fingerprint()', 'EXECUTE'));

-- ============================== E-16 · placeholder names, one next step ==============================
select fabula.placeholder_status()::text ph \gset
select pg_temp.ck('E-16 the placeholder names have one next step each, in Italian, with where to go (never Shopify for a customer)',
  (:'ph'::jsonb ->> 'count')::int >= 1 and :'ph'::jsonb ->> 'line_it' ~ '^[0-9]+ nom[ei] provvisor[io] da sostituire: «'
  and :'ph'::jsonb ->> 'line_it' like '%Console → Anagrafiche%Non crearli su Shopify.'
  and not exists (select 1 from jsonb_array_elements(:'ph'::jsonb -> 'items') i where i ->> 'link' <> 'console.html#anag' or coalesce(i ->> 'next_step_it', '') = '')
  and not exists (select 1 from jsonb_array_elements(:'ph'::jsonb -> 'items') i where i ->> 'kind' = 'cliente' and i ->> 'next_step_it' not like '%Non crearlo su Shopify%'), :'ph');
select pg_temp.ck('E-16 the evening system check quotes the same line', (fabula.ops_health_check(:'d') -> 'data_quality') @> jsonb_build_array(jsonb_build_object('key', 'placeholder_parties', 'text', :'ph'::jsonb ->> 'line_it')));
select pg_temp.ck('E-16 …and the wholesale/milk-plan bot gets it with the standing orders', fabula.confirm_standing_orders(:'d'::date + 1) -> 'placeholders' = :'ph'::jsonb);

-- ============================== E-17 · prompt versions ==============================
select fabula.post_bot_message('compliance_calendar', 'info', 'Scadenze', 'x', null, null, null) pos7 \gset
select fabula.post_bot_message('sales', 'info', 'Contatti', 'x', p_prompt => (select version from fabula.bot_prompt_versions where agent = 'sales')) pv1 \gset
select fabula.post_bot_message('marketing', 'info', 'Post', 'x', p_prompt => 'vecchia0000') pv2 \gset
select fabula.post_bot_message('procurement', 'info', 'SIMULAZIONE ordini', 'x') pv3 \gset
select fabula.post_bot_message('wholesale_orders', 'info', 'Ordini di domani', 'x', p_prompt => (select version from fabula.bot_prompt_versions where agent = 'wholesale_orders')) pv4 \gset
select fabula.post_bot_message('wholesale_orders', 'warn', 'Consegna di lunedì 19/10 NON prenotata: Pizzeria V', 'x') pv5 \gset
select pg_temp.ck('E-17 the old 7-argument call still works; the version is stored with the message',
  :pos7 > 0 and (select prompt_version from fabula.bot_messages where id = :pv2) = 'vecchia0000');
select fabula.prompt_drift()::text pd \gset
select pg_temp.ck('E-17 the drift lists the bots running an older prompt (or none), not the up-to-date one, a simulation, nor the database''s own message under a bot''s name',
  :'pd'::jsonb -> 'items' @> '[{"agent":"marketing","running":"vecchia0000"},{"agent":"compliance_calendar","running":"senza versione"}]'::jsonb
  and not :'pd'::jsonb -> 'items' @> '[{"agent":"sales"}]'::jsonb and not :'pd'::jsonb -> 'items' @> '[{"agent":"procurement"}]'::jsonb
  and not :'pd'::jsonb -> 'items' @> '[{"agent":"wholesale_orders"}]'::jsonb
  and :'pd'::jsonb ->> 'line_it' like 'Bot con istruzioni non aggiornate: %. Le attività programmate vanno aggiornate dal repo: chiedi a Claude.', :'pd');
select pg_temp.ck('E-17 the evening system check and Panoramica → Sistema report it',
  (fabula.ops_health_check(:'d') -> 'data_quality') @> '[{"key":"bot_prompts_old"}]'::jsonb
  and (select (e ->> 'done')::boolean = false from jsonb_array_elements(:'sc_uff'::jsonb) e where e ->> 'key' = 'bot_prompts') is not false);
select pg_temp.ck('E-17 11 prompt versions (not the 3 retired Shopify prompts: the database posts under their names); the bots'' call is for the service role only',
  (select count(*) from fabula.bot_prompt_versions) = 11 and not exists (select 1 from fabula.bot_prompt_versions where agent like 'shopify%') and has_function_privilege('service_role', 'fabula.post_bot_message(text,text,text,text,uuid,text,text,text)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'fabula.post_bot_message(text,text,text,text,uuid,text,text,text)', 'EXECUTE')
  and to_regprocedure('fabula.post_bot_message(text,text,text,text,uuid,text,text)') is null);

-- ============================== E-19 · numbers from the data only ==============================
select pg_temp.ck('E-19 percentages computed by the database (none when the base is 0 or missing)',
  fabula.pct_change(110, 100) = 10 and fabula.pct_change(90, 120) = -25 and fabula.pct_change(5, 0) is null and fabula.pct_change(null, 3) is null);
select pg_temp.ck('E-19 the morning brief carries its changes; the weekly one compares every number with the week before',
  fabula.daily_brief(:'y') -> 'changes' ?& array['sales_vs_same_weekday_pct', 'yield_vs_30d_points', 'energy_kwh_per_kg_vs_30d_pct']
  and jsonb_typeof(fabula.weekly_brief() -> 'changes') = 'object'
  and fabula._pct_changes('{"a":110,"b":{"c":50},"t":"x"}', '{"a":100,"b":{"c":100},"t":"y"}') = '{"a":10,"b":{"c":-50}}'::jsonb);
select pg_temp.as_user(:'tit');
select fabula.sales_add_lead('{"name":"Pizzeria Web V","town":"Agropoli","source":"bot vendite","notes":"forno a legna"}')::text l1 \gset
select fabula.sales_add_lead('{"name":"Bar Manuale V","town":"Agropoli","notes":"amico"}')::text l2 \gset
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('E-19 a lead found on the web by the bot is «Da verificare»; one typed in by a person is not',
  (select notes from fabula.sales_leads where name = 'Pizzeria Web V') = 'Da verificare: trovato sul web dal bot, telefono e indirizzo non ancora confermati · forno a legna'
  and (select notes from fabula.sales_leads where name = 'Bar Manuale V') = 'amico');

-- ============================== E-32 · no tasks before the start, only the cold rooms on closed days ==============================
select pg_temp.ck('E-32 before the start (opening 15/02/2027 in the replay, no trial week) the nightly job creates nothing',
  fabula.tasks_start_date() > :'d'::date and fabula.generate_daily_tasks(:'d') = 0);
update fabula.settings set value = (:'d'::date - 30)::text where key = 'prod.tasks_from';
select :'d'::date + 14 - extract(isodow from :'d'::date)::int sun \gset
select :'sun'::date + 1 mon \gset
select :'sun'::date + 3 wed \gset
insert into fabula.trade_closures (date_from, date_to, note) values (:'wed', :'wed', 'Ferie V');
select fabula.generate_daily_tasks(:'sun') n_sun \gset
select fabula.generate_daily_tasks(:'mon') n_mon \gset
select fabula.generate_daily_tasks(:'wed') n_wed \gset
select (select count(*) * 2 from fabula.task_schedules where active and frequency = 'twice_daily') n_cold \gset
select pg_temp.ck('E-32 Sunday and a closure day: only the cold-room checks; a working Monday: everything',
  :n_sun = :n_cold and :n_wed = :n_cold and :n_mon > :n_cold
  and not exists (select 1 from fabula.task_instances ti join fabula.task_schedules s on s.id = ti.schedule_id
                   where (ti.due_at at time zone 'Europe/Rome')::date = :'sun' and s.frequency <> 'twice_daily'),
  :n_sun || ' / ' || :n_mon || ' / ' || :n_wed || ' (cold ' || :n_cold || ')');
update fabula.settings set value = '' where key = 'prod.closed_weekdays';
select pg_temp.ck('E-32 with no closing weekday Sunday is a normal day', not fabula.is_closed_day(:'sun') and fabula.is_closed_day(:'wed'));
update fabula.settings set value = '7' where key = 'prod.closed_weekdays';
-- a month that starts on a Sunday: its monthly tasks go to Monday the 2nd; a week whose Monday is closed: its weekly tasks go to Tuesday
select g::date first_sun from generate_series(:'d'::date + 20, :'d'::date + 1200, interval '1 day') g where extract(day from g) = 1 and extract(isodow from g) = 7 limit 1 \gset
select fabula.generate_daily_tasks(:'first_sun') is not null x1 \gset
select (select count(*) from fabula.task_instances ti join fabula.task_schedules s on s.id = ti.schedule_id
         where s.frequency = 'monthly' and date_trunc('month', ti.due_at at time zone 'Europe/Rome') = date_trunc('month', :'first_sun'::timestamp)) m_sun \gset
select fabula.generate_daily_tasks(:'first_sun'::date + 1) is not null x2 \gset
select fabula.generate_daily_tasks(:'first_sun'::date + 2) is not null x3 \gset
select (select count(*) from fabula.task_instances ti join fabula.task_schedules s on s.id = ti.schedule_id
         where s.frequency = 'monthly' and (ti.due_at at time zone 'Europe/Rome')::date = :'first_sun'::date + 1) m_mon,
       (select count(*) from fabula.task_instances ti join fabula.task_schedules s on s.id = ti.schedule_id
         where s.frequency = 'monthly' and date_trunc('month', ti.due_at at time zone 'Europe/Rome') = date_trunc('month', :'first_sun'::timestamp)) m_all,
       (select count(*) from fabula.task_schedules where active and frequency = 'monthly') m_n \gset
select pg_temp.ck('E-32 the 1st of the month is a Sunday: the monthly tasks come on Monday the 2nd, once',
  :m_sun = 0 and :m_mon = :m_n and :m_all = :m_n and :m_n > 0, :'first_sun' || ': ' || :m_sun || ' / ' || :m_mon || ' / ' || :m_all || ' of ' || :m_n);
select :'d'::date + 42 - extract(isodow from :'d'::date)::int + 1 cmon \gset
insert into fabula.trade_closures (date_from, date_to, note) values (:'cmon', :'cmon', 'Lunedì chiuso V');
select fabula.generate_daily_tasks(:'cmon') + fabula.generate_daily_tasks(:'cmon'::date + 1) + fabula.generate_daily_tasks(:'cmon'::date + 2) x4 \gset
select (select count(*) from fabula.task_instances ti join fabula.task_schedules s on s.id = ti.schedule_id
         where s.frequency = 'weekly' and (ti.due_at at time zone 'Europe/Rome')::date between :'cmon' and :'cmon'::date + 6) w_week,
       (select count(*) from fabula.task_instances ti join fabula.task_schedules s on s.id = ti.schedule_id
         where s.frequency = 'weekly' and (ti.due_at at time zone 'Europe/Rome')::date = :'cmon'::date + 1) w_tue,
       (select count(*) from fabula.task_schedules where active and frequency = 'weekly') w_n \gset
select pg_temp.ck('E-32 a closed Monday: the weekly tasks come on Tuesday, once for the week', :w_tue = :w_n and :w_week = :w_n and :w_n > 0,
  :w_tue || ' / ' || :w_week || ' of ' || :w_n);
select pg_temp.ck('E-32 a closed day without production asks only the cold rooms in the evening (no cleaning)',
  (select coalesce(bool_and(i ->> 'code' like 'cold:%'), false) and count(*) = 2 from jsonb_array_elements(fabula._haccp_evening_items(:'sun')) i),
  fabula._haccp_evening_items(:'sun')::text);

-- ============================== E-31 · the evening list, live, and yesterday's gaps ==============================
insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, output_kg, input_kind, started_at, finished_at, source)
values (:'y', 'LV105-Y', :'moz', 300, 60, 'milk', (:'y'::date + time '08:00') at time zone 'Europe/Rome', (:'y'::date + time '12:00') at time zone 'Europe/Rome', 'tablet');
insert into fabula.haccp_log (control_point_id, logged_at, measured_value, result, source, operator)
select id, (:'y'::date + time '20:00') at time zone 'Europe/Rome', 3, 'ok', 'tablet', 'Casaro V' from fabula.haccp_control_points where code = 'CCP-COLD-1';
insert into fabula.haccp_log (control_point_id, logged_at, measured_value, result, source, operator)
select id, (:'d'::date + time '00:30') at time zone 'Europe/Rome', 3, 'ok', 'tablet', 'Casaro V' from fabula.haccp_control_points where code = 'CCP-COLD-2';
insert into fabula.staff (full_name, role, app_role, active) values ('Aiuto V105', 'commesso', 'banco', true) returning badge_code aiuto_badge \gset
select fabula.badge_in(:'aiuto_badge') is not null bi \gset
select pg_temp.as_user(:'cas');
select fabula.haccp_open_list()::text hl \gset
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('E-31 yesterday''s food-safety gaps, each opening the paper copy on yesterday''s date (with the lot for a CCP)',
  :'hl'::jsonb #> '{yesterday,items}' @> jsonb_build_array(jsonb_build_object('scan', 'PAPER:CCP-STRETCH@' || :'y' || '@LV105-Y'),
                                                          jsonb_build_object('scan', 'PAPER:CCP-COLD-2@' || :'y'), jsonb_build_object('scan', 'PAPER:PRP-CLEAN@' || :'y'))
  and (:'hl'::jsonb #>> '{yesterday,date}')::date = :'y', :'hl'::jsonb #>> '{yesterday,items}');
select pg_temp.ck('E-31 the Rome day: yesterday''s 20:00 reading closes yesterday''s evening check; today''s 00:30 does not (it was the UTC date)',
  not :'hl'::jsonb #> '{yesterday,items}' @> jsonb_build_array(jsonb_build_object('scan', 'PAPER:CCP-COLD-1@' || :'y')));
select pg_temp.ck('E-31 yesterday''s box only has food safety (no meter, no shipping, no badge)',
  not exists (select 1 from jsonb_array_elements(:'hl'::jsonb #> '{yesterday,items}') i where i ->> 'code' !~ '^(cold:|ccp:|clean$|abx$)'));
select pg_temp.ck('E-31 today''s list is live (the two cold rooms at least, counted as food safety)',
  (:'hl'::jsonb ->> 'count')::int >= 2 and (:'hl'::jsonb ->> 'food_safety')::int >= 2 and :'hl'::jsonb -> 'items' @> '[{"code":"cold:CCP-COLD-1"},{"code":"cold:CCP-COLD-2"}]'::jsonb, :'hl');
select pg_temp.ck('E-31 a badge not passed is listed from 19:00, not while the person is still at work',
  case when extract(hour from now() at time zone 'Europe/Rome') < 19 then not exists (select 1 from jsonb_array_elements(:'hl'::jsonb -> 'items') i where i ->> 'code' like 'shift:%')
       else :'hl'::jsonb -> 'items' @> jsonb_build_array(jsonb_build_object('code', 'shift:' || :'aiuto_badge')) end,
  (select string_agg(i ->> 'code', ', ') from jsonb_array_elements(:'hl'::jsonb -> 'items') i));
select pg_temp.ck('E-31 …the 19:02 notice does list it (after 19:00)', fabula._haccp_evening_items(:'d') @> jsonb_build_array(jsonb_build_object('code', 'shift:' || :'aiuto_badge')));
select fabula.haccp_evening_status(:'y')::text hes \gset
select pg_temp.ck('E-31 the 19:02 notice keeps working with the same items', (:'hes'::jsonb ->> 'count')::int >= 3
  and exists (select 1 from fabula.notices where key = 'haccp_evening:' || :'y' and severity = 'alert'), :'hes');
update fabula.settings set value = (:'d'::date + 1)::text where key = 'prod.tasks_from';
select pg_temp.as_user(:'cas');
select fabula.haccp_open_list()::text hl2 \gset
select set_config('request.jwt.claims', '', false);
-- v1.07: a lot really made yesterday is product in the cold room: before the tasks start, today's cold rooms are asked too (food
-- safety first; with nothing real going on the list stays empty: test_v107_quiet.sql)
select pg_temp.ck('E-31 before the tasks start: yesterday''s real lot keeps its CCP and (v1.07) today''s cold rooms are asked',
  :'hl2'::jsonb #> '{yesterday,items}' @> jsonb_build_array(jsonb_build_object('scan', 'PAPER:CCP-STRETCH@' || :'y' || '@LV105-Y'))
  and :'hl2'::jsonb -> 'items' @> '[{"code": "cold:CCP-COLD-1"}]'::jsonb, :'hl2');
update fabula.settings set value = (:'d'::date - 30)::text where key = 'prod.tasks_from';
select pg_temp.ck('E-31 the list is for signed-in staff only', not has_function_privilege('anon', 'fabula.haccp_open_list()', 'EXECUTE'));

-- ============================== E-30 · the go-live list in Italian, signed ==============================
select pg_temp.as_user(:'uff');
select fabula.golive_checklist()::text gl \gset
select pg_temp.err($q$select fabula.dash_set_check('deal_signed', true, 'firmato dal notaio')$q$) g1 \gset
select pg_temp.as_user(:'tit');
select pg_temp.err($q$select fabula.dash_set_check('deal_signed', true, '')$q$) g2 \gset
select pg_temp.err($q$select fabula.dash_set_check('deal_signed', true, 'Atto notaio Rossi, rep. 123, in Drive/Acquisto')$q$) g3 \gset
select done_at is not null and done_by_id = '10000000-0000-4000-a000-000000105a01' g3_who from fabula.dash_checks where key = 'deal_signed' \gset
select pg_temp.err($q$select fabula.dash_set_check('ce_approval', true, 'fatto')$q$) g4 \gset
select fabula.golive_checklist()::text gl2 \gset
set role authenticated;
select pg_temp.err($q$update fabula.dash_checks set done = true where key = 'labels'$q$) g5 \gset
select pg_temp.err($q$insert into fabula.dash_checks (key, sort, label, kind, done) values ('mio', 99, 'mio', 'manual', true)$q$) g6 \gset
reset role;
select pg_temp.err($q$select fabula.dash_set_check('deal_signed', false, null)$q$) g7 \gset
select pg_temp.err($q$select fabula.dash_set_check('deal_signed', false, 'firmato per sbaglio')$q$) g8 \gset
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('E-30 the list in Italian: every item with its label and how it closes, not the board''s working notes; the office sees it but cannot sign',
  jsonb_array_length(:'gl'::jsonb -> 'items') = (select count(*) from fabula.dash_checks) and not (:'gl'::jsonb ->> 'can_sign')::boolean
  and :'gl'::jsonb -> 'items' @> '[{"key":"deal_signed","label":"Atto di acquisto firmato dopo la due diligence","kind":"manual"}]'::jsonb
  and not exists (select 1 from jsonb_array_elements(:'gl'::jsonb -> 'items') i where coalesce(i ->> 'hint', '') = '')
  and not exists (select 1 from jsonb_array_elements(:'gl'::jsonb -> 'items') i where i ->> 'note' is not null), left(:'gl', 300));
select pg_temp.ck('E-30 only the titolare/soci sign; a note is required', :'g1' like '%' and :'g1' <> '' and :'g2' = 'Scrivi una nota: cosa è stato fatto e dove sta il documento', :'g1' || ' / ' || :'g2');
select pg_temp.ck('E-30 signed with a note: who and when are kept and shown', :'g3' = ''
  and :'gl2'::jsonb -> 'items' @> '[{"key":"deal_signed","done":true,"done_by":"Titolare V","note":"Atto notaio Rossi, rep. 123, in Drive/Acquisto"}]'::jsonb
  and :'g3_who'::boolean and (:'gl2'::jsonb ->> 'can_sign')::boolean, :'g3');
select pg_temp.ck('E-30 an item that closes from the data cannot be ticked', :'g4' = '«ce_approval» non si segna a mano: si aggiorna da solo dai dati', :'g4');
select pg_temp.ck('E-30 a login cannot change or add items directly', :'g5' like 'La lista per l''apertura si segna da Configurazione%' and :'g6' like 'La lista per l''apertura si segna da Configurazione%'
  and not (select done from fabula.dash_checks where key = 'labels'), :'g5' || ' / ' || :'g6');
select pg_temp.ck('E-30 undoing needs a reason too, and clears who/when', :'g7' = 'Scrivi perché si annulla' and :'g8' = ''
  and (select not done and done_by_id is null and done_at is null and sign_note = 'firmato per sbaglio' and note like 'Handshake%' from fabula.dash_checks where key = 'deal_signed'), :'g7' || ' / ' || :'g8');
select pg_temp.ck('E-30 every change is in the Registro, with who', (select count(*) from fabula.audit_log where table_name = 'dash_checks' and row_key = 'deal_signed' and actor = 'Titolare V') = 2);
select pg_temp.err($q$select fabula.dash_set_check('labels', true)$q$) g9 \gset
select pg_temp.ck('E-30 Nick''s board (SQL, no login) still ticks without a note; the list says it came from there', :'g9' = ''
  and (select done and sign_note = 'Segnato dalla lavagna tecnica di Nick' and note like 'Brand settled%' from fabula.dash_checks where key = 'labels'), :'g9');

-- ============================== scan ==============================
select pg_temp.ck('security scan: nothing new without a reason', not exists (select 1 from fabula.security_findings() f where not exists (select 1 from fabula.security_accepted a where a.key = f.key)),
  (select string_agg(f.key, ', ') from fabula.security_findings() f where not exists (select 1 from fabula.security_accepted a where a.key = f.key)));
