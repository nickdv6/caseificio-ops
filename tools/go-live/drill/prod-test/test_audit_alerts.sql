-- v1.00 audit alerts and operations (E-03, E-04/C-12, E-05, E-08, E-13, E-14, E-21, E-33) · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh a_test
--   su postgres -c "psql -d a_test -f tools/go-live/drill/prod-test/test_audit_alerts.sql" | grep -E "PASS|FAIL"
-- The incident checks drive bot_watchdog() with fixed clock times on Tuesday 20/10/2026 (Rome).
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as
$$ declare h text; begin execute p_sql; return ''; exception when others then get stacked diagnostics h = pg_exception_hint; return sqlerrm || case when coalesce(h, '') <> '' then ' || hint: ' || h else '' end; end $$;
create or replace function pg_temp.st(p_sql text) returns text language plpgsql as
$$ begin execute p_sql; return ''; exception when others then return sqlstate; end $$;
create or replace function pg_temp.as_user(p_sub text) returns void language sql as
$$ select set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_sub), false) $$;
create or replace function pg_temp.rome() returns date language sql as $$ select (now() at time zone 'Europe/Rome')::date $$;
create or replace function pg_temp.wday(n int) returns date language sql as
$$ select g::date from generate_series(pg_temp.rome() + 1, pg_temp.rome() + 30, interval '1 day') g where extract(isodow from g) <> 7 order by g offset n - 1 limit 1 $$;
insert into fabula.staff (id, full_name, role, app_role, active, auth_user_id) values
  ('10000000-0000-4000-a000-000000100a01', 'Titolare A', 'owner', 'titolare', true, '00000000-0000-4000-a000-000000100a01'),
  ('10000000-0000-4000-a000-000000100a02', 'Ufficio A', 'operaio', 'amministrazione', true, '00000000-0000-4000-a000-000000100a02'),
  ('10000000-0000-4000-a000-000000100a03', 'Casaro A', 'casaro', 'produzione', true, '00000000-0000-4000-a000-000000100a03'),
  ('10000000-0000-4000-a000-000000100a04', 'Marketing A', 'operaio', 'marketing', true, '00000000-0000-4000-a000-000000100a04'),
  ('10000000-0000-4000-a000-000000100a05', 'Consulente A', 'operaio', 'consulente', true, '00000000-0000-4000-a000-000000100a05')
on conflict do nothing;
\set tit '00000000-0000-4000-a000-000000100a01'
\set uff '00000000-0000-4000-a000-000000100a02'
\set cas '00000000-0000-4000-a000-000000100a03'
\set mkt '00000000-0000-4000-a000-000000100a04'
\set con '00000000-0000-4000-a000-000000100a05'

-- ============================== E-13 · names say what the bot does ==============================
select pg_temp.ck('E-13 a bot is named by what it does first, then its nickname',
  fabula.bot_display_name('milk_planning') = 'Piano latte · Zio Gennaro' and fabula.bot_title('milk_planning') = 'Piano latte'
  and fabula.bot_display_name('produzione') = 'Resa e lotti aperti · Zio Ciro', fabula.bot_display_name('milk_planning'));
select pg_temp.ck('E-13 what the database writes by itself has no nickname',
  fabula.bot_display_name('sicurezza') = 'Sicurezza alimentare' and fabula.bot_display_name('turni') = 'Turni'
  and fabula.bot_display_name('bot_heartbeat') = 'Battito bot' and fabula.bot_display_name('prova') = 'Settimana di prova');

-- ============================== E-08 · links stay inside the app ==============================
select pg_temp.ck('E-08 links: pages of the app (with a tab) only',
  fabula.safe_link('console.html#oggi&appr=8c1d0f2e-22aa-4b1c-9d3e-0123456789ab') = 'console.html#oggi&appr=8c1d0f2e-22aa-4b1c-9d3e-0123456789ab'
  and fabula.safe_link('haccp.html') = 'haccp.html' and fabula.safe_link('admin.html#bots') = 'admin.html#bots'
  and fabula.safe_link('https://evil.example/console.html') is null and fabula.safe_link('javascript:alert(1)') is null
  and fabula.safe_link('//evil.example/console.html') is null and fabula.safe_link('console.html#oggi"><img src=x>') is null
  and fabula.safe_link('shop.html') is null and fabula.safe_link('../console.html') is null);
select set_config('request.jwt.claims', '', false);
set role service_role;
select fabula.post_bot_message('procurement', 'warn', 'T-link esterno', 'x', null, 'https://evil.example/console.html') m_ext \gset
select fabula.post_bot_message('wholesale_orders', 'info', 'T-link proprio', 'x', null, 'ingrosso.html#consegne', 'Inoltra stasera') m_own \gset
select fabula.post_bot_message('sales', 'info', 'T-senza link', 'x') m_def \gset
reset role;
select pg_temp.ck('E-08 a link outside the app is replaced by the bot''s own page',
  (select action_url || '|' || action_label from fabula.bot_messages where id = :m_ext) = 'console.html#oggi|Apri la Console',
  (select action_url || '|' || action_label from fabula.bot_messages where id = :m_ext));
select pg_temp.ck('E-08 the bot''s own link and button label are kept',
  (select action_url || '|' || action_label from fabula.bot_messages where id = :m_own) = 'ingrosso.html#consegne|Inoltra stasera');
select pg_temp.ck('E-08 no link given: the bot''s page', (select action_url from fabula.bot_messages where id = :m_def) = 'vendite.html#oggi');
insert into fabula.bot_messages (agent, severity, title, body, source) values ('tablet', 'warn', 'T-tablet usa ancora la versione', 'x', 'auto'),
                                                                               ('tablet', 'alert', 'T-1 registrazione rifiutata dal database', 'x', 'auto');
select pg_temp.ck('E-08 the tablet''s version message has no link (it is fixed on the tablet); its refused saves open Autocontrollo',
  (select action_url from fabula.bot_messages where title = 'T-tablet usa ancora la versione') is null
  and (select action_url || '|' || action_label from fabula.bot_messages where title = 'T-1 registrazione rifiutata dal database') = 'haccp.html#registri|Apri Autocontrollo');
select pg_temp.ck('E-08 a non-staff browser cannot post messages', not has_function_privilege('authenticated', 'fabula.post_bot_message(text, text, text, text, uuid, text, text, text)', 'execute'));

-- a milk plan message opens its own request and closes when the request is decided (E-05)
update fabula.settings set value = '1200' where key = 'milk.capacity_kg';
delete from fabula.milk_plans where plan_date between pg_temp.rome() and pg_temp.rome() + 30;
select (fabula.plan_milk(pg_temp.wday(2))) ->> 'approval_id' a1 \gset
set role service_role;
select fabula.post_bot_message('milk_planning', 'alert', 'T-Approva il piano latte', 'x') m_milk \gset
reset role;
select pg_temp.ck('E-08 the milk plan message opens its request in the Console',
  (select action_url || '|' || action_label || '|' || approval_id from fabula.bot_messages where id = :m_milk)
    = 'console.html#oggi&appr=' || :'a1' || '|Apri la richiesta|' || :'a1',
  (select action_url || '|' || action_label || '|' || coalesce(approval_id::text, '-') from fabula.bot_messages where id = :m_milk));
set role service_role;
update fabula.approvals set status = 'approved', decided_by = 'Titolare A', decided_at = now() where id = :'a1';
reset role;
select pg_temp.ck('E-05 the decision closes its message at once, saying how',
  (select read_at is not null and resolved_at is not null and resolution = 'richiesta approvata da Titolare A' from fabula.bot_messages where id = :m_milk),
  (select coalesce(resolution, '-') from fabula.bot_messages where id = :m_milk));
select pg_temp.ck('E-05 …and its Telegram no longer reminds anyone 30 minutes later (review 14/10)',
  (select count(*) >= 1 and bool_and(acked_at is not null) from fabula.notify_outbox where source = 'bot_messages' and source_ref = :'m_milk'),
  (select string_agg(coalesce(acked_at::text, 'not acked'), ', ') from fabula.notify_outbox where source = 'bot_messages' and source_ref = :'m_milk'));
-- the 30-minute reminder keeps the message's link
set role service_role;
select fabula.post_bot_message('sales', 'alert', 'T-promemoria con link', 'x', null, 'vendite.html#pipeline') m_rem \gset
reset role;
update fabula.notify_outbox set escalate_at = now() - interval '1 minute' where source = 'bot_messages' and source_ref = :'m_rem';
select fabula.notify_tick() tick \gset
select pg_temp.ck('the reminder («Nessuno se ne occupa») opens the same page as the message',
  exists (select 1 from fabula.notify_outbox r join fabula.notify_outbox o on o.id = r.parent_id
          where o.source = 'bot_messages' and o.source_ref = :'m_rem' and r.title like '⏰ Nessuno se ne occupa%' and r.text_html like '%vendite.html#pipeline%'),
  (select string_agg(left(r.text_html, 120), ' | ') from fabula.notify_outbox r join fabula.notify_outbox o on o.id = r.parent_id where o.source_ref = :'m_rem'));

-- ============================== E-04 / C-12 · read per person, «Risolto» with a note ==============================
set role service_role;
select fabula.post_bot_message('sales', 'warn', 'T-warn per persona', 'x') m_w \gset
select fabula.post_bot_message('compliance_calendar', 'alert', 'T-allarme per persona', 'x') m_a \gset
reset role;
select pg_temp.ck('E-01 the alarm goes to Telegram with its own page', exists (select 1 from fabula.notify_outbox
  where source = 'bot_messages' and source_ref = :'m_a' and text_html like '%admin.html#maint%'),
  (select left(text_html, 200) from fabula.notify_outbox where source = 'bot_messages' and source_ref = :'m_a'));
select pg_temp.as_user(:'tit');
set role authenticated;
select fabula.bot_bell() bell0 \gset
select fabula.mark_bot_messages_read(null) n_all \gset
select fabula.bot_bell() bell1 \gset
select read_by_me::text || '|' || for_me::text f_tw from fabula.v_bot_feed where id = :m_w \gset
select read_by_me::text || '|' || for_me::text f_ta from fabula.v_bot_feed where id = :m_a \gset
reset role;
select pg_temp.ck('E-04 «Segna tutto» reads the routine messages for me, never the alarms',
  :'f_tw' = 'true|false' and :'f_ta' = 'false|true' and (:'bell1'::jsonb->>'unread')::int = 0 and (:'bell1'::jsonb->>'alerts')::int = (:'bell0'::jsonb->>'alerts')::int,
  :'f_tw' || ' ' || :'f_ta' || ' ' || :'bell0' || ' → ' || :'bell1');
select pg_temp.ck('E-04 …and only for me: the message is still open for everyone', (select read_at is null from fabula.bot_messages where id = :m_w));
select pg_temp.as_user(:'uff');
set role authenticated;
select read_by_me::text || '|' || for_me::text || '|' || coalesce(seen_by, '-') f_uw from fabula.v_bot_feed where id = :m_w \gset
select pg_temp.err(format('select fabula.resolve_bot_messages(array[%s]::bigint[], %L)', :m_a, 'fatto')) e_r1 \gset
select pg_temp.err(format('insert into fabula.bot_message_reads (message_id, staff_id) values (%s, %L)', :m_a, '10000000-0000-4000-a000-000000100a02')) e_r2 \gset
select pg_temp.st(format('update fabula.bot_messages set read_at = now() where id = %s', :m_a)) s_r3 \gset
reset role;
select pg_temp.ck('E-04 another person still has it to read, and sees who read it', :'f_uw' like 'false|true|Titolare A __/__ __:__', :'f_uw');
select pg_temp.ck('C-12 «Risolto» needs «gestisce» in Sistema', :'e_r1' like 'Permesso negato: serve il livello 3%', :'e_r1');
select pg_temp.ck('E-04 nobody writes the read list or closes a message by hand',
  :'e_r2' like 'permission denied%' and (select read_at is null from fabula.bot_messages where id = :m_a), :'e_r2' || ' / ' || :'s_r3');
insert into fabula.notices (key, severity, title_it, items, expires_at) values ('T-avviso2', 'alert', 'T-avviso da non chiudere a mano', '[]', now() + interval '1 day');
select id m_nc from fabula.bot_messages where notice_key = 'T-avviso2' \gset
select pg_temp.as_user(:'tit');
set role authenticated;
select pg_temp.err(format('update fabula.bot_messages set read_at = now(), resolved_by_id = %L where id = %s', '10000000-0000-4000-a000-000000100a02', :m_a)) e_r5 \gset
select pg_temp.err(format('select fabula.resolve_bot_messages(array[%s]::bigint[], %L)', :m_nc, 'chiuso a mano')) e_r6 \gset
select pg_temp.err(format('select fabula.resolve_bot_messages(array[%s]::bigint[], %L)', :m_a, 'ok')) e_r4 \gset
select fabula.bot_bell() bell1b \gset
select fabula.resolve_bot_messages(array[:m_a]::bigint[], 'Taratura fatta, certificato in archivio') n_res \gset
select resolved_by || '|' || resolution || '|' || for_me::text f_res from fabula.v_bot_feed where id = :m_a \gset
select fabula.bot_bell() bell2 \gset
reset role;
select pg_temp.ck('C-12 «Risolto» asks what was done', :'e_r4' like 'Scrivi cosa è stato fatto%', :'e_r4');
select pg_temp.ck('C-12 even «gestisce» cannot close a message by hand and sign as someone else (review 14/10)', :'e_r5' like 'permission denied for table bot_messages%', :'e_r5');
select pg_temp.ck('C-12 a notice''s copy is not «Risolto»: the notice closes by itself', :'e_r6' like 'Questo avviso si chiude da solo%'
  and (select read_at is null from fabula.bot_messages where id = :m_nc), :'e_r6');
update fabula.notices set resolved_at = now() where key = 'T-avviso2';
select pg_temp.ck('C-12 «Risolto» closes the alarm for everyone, with who and what',
  :n_res = 1 and :'f_res' = 'Titolare A|Taratura fatta, certificato in archivio|false' and (select read_at is not null from fabula.bot_messages where id = :m_a)
  and (:'bell2'::jsonb->>'alerts')::int = (:'bell1b'::jsonb->>'alerts')::int - 1, :'f_res' || ' ' || :'bell1b' || ' → ' || :'bell2');
select pg_temp.ck('C-12 …and its Telegram message counts as taken in charge (no 30-minute reminder)',
  (select bool_and(acked_at is not null) from fabula.notify_outbox where source = 'bot_messages' and source_ref = :'m_a'));

-- a notice's copy in the feed closes when the notice does; a routine warn is superseded, an alarm is not (E-05)
insert into fabula.notices (key, severity, title_it, items, expires_at) values ('T-avviso', 'alert', 'T-avviso di prova', '[]', now() + interval '1 day');
update fabula.notices set resolved_at = now() where key = 'T-avviso';
select fabula.bot_messages_autoread() n_ar \gset
select pg_temp.ck('E-05 the notice''s Telegram counts as dealt with when the notice clears (no reminder)',
  (select count(*) >= 1 and bool_and(acked_at is not null) from fabula.notify_outbox where source = 'notices' and source_ref = 'T-avviso'));
select pg_temp.ck('E-05 the notice''s alarm copy closes by itself when the notice clears',
  (select bool_and(read_at is not null and resolution = 'rientrato da solo (avviso chiuso)') and count(*) = 1 from fabula.bot_messages where notice_key = 'T-avviso'),
  (select string_agg(agent || ':' || coalesce(resolution, '-'), ', ') from fabula.bot_messages where notice_key = 'T-avviso'));

-- a failed run: what happens next and where to look (E-21)
insert into fabula.agent_runs (agent, started_at, finished_at, status, error) values ('shopify_orders', now(), now(), 'error', 'T-connector scaduto');
insert into fabula.agent_runs (agent, started_at, finished_at, status, error) values ('haccp_nudge', now(), now(), 'error', 'T-connector scaduto');
select pg_temp.ck('E-21 a failed bot says what happens next and links to the bots',
  (select action_url = 'admin.html#bots' and title = 'Ordini Shopify: non riuscito' and body like '%«Bot fermi: cosa fare»%' from fabula.bot_messages where agent = 'shopify_orders' and body like '%T-connector%')
  and (select body like '%il database fa il suo lavoro da solo%«Esegui ora»%' from fabula.bot_messages where agent = 'haccp_nudge' and body like '%T-connector%'),
  (select string_agg(title || ': ' || replace(body, E'\n', ' '), ' | ') from fabula.bot_messages where body like '%T-connector%'));
select pg_temp.ck('E-33 …and is not sent to Telegram itself: the watchdog sends one message per incident (it went out twice)',
  not exists (select 1 from fabula.notify_outbox o join fabula.bot_messages m on o.source = 'bot_messages' and o.source_ref = m.id::text where m.body like '%T-connector%'));

-- ============================== E-03 · who sees a notice ==============================
insert into fabula.notices (key, severity, title_it, items, expires_at) values ('haccp_evening', 'warn', 'T-serata', '[]', now() + interval '1 day')
on conflict (key) do update set title_it = excluded.title_it, resolved_at = null, expires_at = excluded.expires_at;
insert into fabula.notices (key, severity, title_it, items, expires_at) values ('infra_git', 'warn', 'T-git', '[]', now() + interval '1 day')
on conflict (key) do update set title_it = excluded.title_it, resolved_at = null, expires_at = excluded.expires_at;
select pg_temp.ck('E-03 the evening HACCP list, the lot guard and unknown lab lots are for the floor; the rest stays in the office',
  fabula.notice_audience('haccp_evening') = 'floor' and fabula.notice_audience('lot_guard:2026-10-20') = 'floor' and fabula.notice_audience('lab_lot_unknown:X') = 'floor'
  and fabula.notice_audience('infra_git') = 'office' and fabula.notice_audience('recon') = 'office' and fabula.notice_audience('bot_alert') = 'office'
  and (select audience from fabula.notices where key = 'haccp_evening') = 'floor' and (select audience from fabula.notices where key = 'infra_git') = 'office');
select pg_temp.ck('E-03 the active notices carry who they are for and where to go',
  (select audience || '|' || link from fabula.v_active_notices where key = 'haccp_evening') = 'floor|haccp.html#registri'
  and (select audience || '|' || link from fabula.v_active_notices where key = 'infra_git') = 'office|admin.html#panoramica');
-- the lot guard says the lot in Italian and can be scanned (E-14)
select id moz from fabula.products where sku = 'MOZ-DOP-KG' \gset
insert into fabula.stock_moves (product_id, lot_number, qty, move_type, source) values (:'moz', 'LG-T1', -5, 'sale', 'tablet');
select items -> -1 lg from fabula.notices where key like 'lot_guard:%' order by created_at desc limit 1 \gset
select pg_temp.ck('E-14 a lot shipped beyond its production: an Italian line and a scan to open the lot',
  :'lg'::jsonb->>'label_it' = 'Lotto LG-T1: uscito 5 kg, in giacenza 0 kg: controlla il peso in uscita' and :'lg'::jsonb->>'scan' = 'LOT:LG-T1'
  and (select audience from fabula.notices where key like 'lot_guard:%' order by created_at desc limit 1) = 'floor', :'lg');
-- the trade applications notice: what to look at, without e-mail addresses (every profile reads notices)
insert into fabula.trade_applications (business_name, contact_name, email, business_type, city, expected_kg_week)
values ('T-Pizzeria Sole', 'Mario', 'mario@example.com', 'pizzeria', 'Salerno', 25);
select fabula.trade_notice_refresh();
select pg_temp.ck('E-14 trade applications: business, type, town and kg — no e-mail',
  exists (select 1 from fabula.notices n, jsonb_array_elements(n.items) x where n.key = 'trade_applications'
          and x->>'label_it' = 'T-Pizzeria Sole · pizzeria · Salerno · 25 kg/settimana')
  and not exists (select 1 from fabula.notices n, jsonb_array_elements(n.items) x where n.key = 'trade_applications' and (x ? 'email' or x::text like '%@%')),
  (select items::text from fabula.notices where key = 'trade_applications'));

-- ============================== E-33 · one incident per missed or failed bot ==============================
delete from cron.job_run_details;
insert into fabula.notices (key, severity, title_it, items, expires_at) values ('bot_heartbeat', 'alert', 'T-vecchio battito', '[]', '2026-10-21 12:00+02')
on conflict (key) do update set resolved_at = null, expires_at = excluded.expires_at;
select count(*) ob0 from fabula.notify_outbox \gset
select fabula.bot_watchdog('2026-10-20 12:00+02') w1 \gset
select id inc_db from fabula.bot_alerts where agent = 'daily_brief' and kind = 'missed' and ref = '2026-10-20 06:47' \gset
select id inc_pr from fabula.bot_alerts where agent = 'procurement' and kind = 'missed' and ref = '2026-10-20 06:20' \gset
select pg_temp.ck('E-33 a missed bot opens one incident, in Italian, with the time it was due',
  exists (select 1 from jsonb_array_elements(:'w1'::jsonb->'alerts') x where x->>'agent' = 'daily_brief' and x->>'kind' = 'missed'
          and x->>'label_it' = 'Brief del mattino e settimanale: non è partito (previsto alle 06:47)')
  and (select notified_at is not null and resolved_at is null from fabula.bot_alerts where id = :inc_db), :'w1');
select pg_temp.ck('E-33 …one Telegram message per incident, to the system topic, opening the bots',
  (select count(*) from fabula.notify_outbox where dedupe_key = 'inc:' || :inc_db) = 1
  and (select topic = 'infra' and text_html like '%admin.html#bots%' from fabula.notify_outbox where dedupe_key = 'inc:' || :inc_db)
  and (select count(*) from fabula.notify_outbox where dedupe_key like 'inc:%') = (select count(*) from fabula.bot_alerts where notified_at is not null and resolved_at is null),
  (select string_agg(dedupe_key || ' ' || title, ' | ') from fabula.notify_outbox where dedupe_key like 'inc:%'));
select pg_temp.ck('E-21 …a bot the database stands in for says «Esegui ora» (since v1.12 every bot, the brief too)',
  (select body like '%Configurazione → Bot → «Esegui ora»%' from fabula.notify_outbox where dedupe_key = 'inc:' || :inc_pr)
  and (select body like '%Configurazione → Bot → «Esegui ora»%' from fabula.notify_outbox where dedupe_key = 'inc:' || :inc_db));
select pg_temp.ck('E-33 the database scheduler that never ran is one incident too',
  (select count(*) from fabula.bot_alerts where agent = 'pg_cron' and kind = 'stuck' and resolved_at is null) = 1
  and (select label_it like 'Le automazioni del database non risultano mai partite:%' from fabula.bot_alerts where agent = 'pg_cron' and kind = 'stuck' and resolved_at is null));
select pg_temp.ck('E-33 one office notice lists what is open; the old heartbeat notice is gone',
  (select audience = 'office' and severity = 'alert' and resolved_at is null and title_it like '% bot da controllare'
          and jsonb_array_length(items) = (select count(*) from fabula.bot_alerts where resolved_at is null) from fabula.notices where key = 'bot_alert')
  and (select resolved_at is not null from fabula.notices where key = 'bot_heartbeat'),
  (select title_it || ' ' || jsonb_array_length(items) from fabula.notices where key = 'bot_alert'));
select pg_temp.ck('E-33 the notice is not pushed again (its incidents were)', not exists (select 1 from fabula.notify_outbox where source = 'notices' and source_ref like 'bot_%')
  and not exists (select 1 from fabula.notify_outbox where title like '% bot da controllare'));
select fabula.bot_watchdog('2026-10-20 13:30+02') w2 \gset
select pg_temp.ck('E-33 the next hourly check repeats nothing (same incidents, no new message)',
  not exists (select 1 from jsonb_array_elements(:'w2'::jsonb->'alerts') x where x->>'agent' in ('daily_brief', 'pg_cron', 'procurement'))
  and (select count(*) from fabula.bot_alerts where agent = 'daily_brief' and kind = 'missed') = 1
  and (select count(*) from fabula.bot_alerts where agent = 'pg_cron' and kind = 'stuck' and resolved_at is null) = 1
  and (select count(*) from fabula.notify_outbox where dedupe_key = 'inc:' || :inc_db) = 1, :'w2');
-- the bot runs late, the database stood in for another, the scheduler runs again
insert into fabula.agent_runs (agent, started_at, finished_at, status, summary) values ('daily_brief', '2026-10-20 13:40+02', '2026-10-20 13:41+02', 'ok', 'T-run');
insert into fabula.agent_runs (agent, started_at, finished_at, status, summary, details) values ('procurement', '2026-10-20 07:25+02', '2026-10-20 07:25+02', 'ok', 'T-run', '{"via":"db_fallback"}');
insert into cron.job_run_details (runid, jobid, status, return_message, start_time, end_time) values (1, 1, 'succeeded', '', '2026-10-20 13:55+02', '2026-10-20 13:55+02');
select fabula.bot_watchdog('2026-10-20 14:00+02') w3 \gset
select pg_temp.ck('E-33 incidents close by themselves, saying how',
  (select resolved_how from fabula.bot_alerts where id = :inc_db) = 'partito alle 13:40'
  and (select resolved_how from fabula.bot_alerts where id = :inc_pr) = 'sostituito dal database alle 07:25'
  and (select resolved_how from fabula.bot_alerts where agent = 'pg_cron' and kind = 'stuck' order by id desc limit 1) = 'ripartite'
  and not exists (select 1 from fabula.notices n, jsonb_array_elements(n.items) x where n.key = 'bot_alert' and x->>'agent' in ('daily_brief', 'procurement', 'pg_cron')),
  (select string_agg(agent || ':' || coalesce(resolved_how, 'open'), ', ') from fabula.bot_alerts where agent in ('daily_brief', 'procurement', 'pg_cron')));
select pg_temp.ck('E-33 the feed keeps one open copy of the bots notice, the newest (it piled up one alarm per change)',
  (select count(*) from fabula.bot_messages where notice_key = 'bot_alert' and read_at is null) = 1
  and (select count(*) from fabula.bot_messages where notice_key = 'bot_alert') >= 2
  and (select title from fabula.bot_messages where notice_key = 'bot_alert' and read_at is null) = (select title_it from fabula.notices where key = 'bot_alert'),
  (select string_agg(title || ':' || coalesce(resolution, 'open'), ', ' order by id) from fabula.bot_messages where notice_key = 'bot_alert'));
-- a failed run, then a good one
insert into fabula.agent_runs (agent, started_at, finished_at, status, error) values ('shopify_customers', '2026-10-20 14:10+02', '2026-10-20 14:10+02', 'error', 'token scaduto');
insert into cron.job_run_details (runid, jobid, status, return_message, start_time, end_time) values (2, 1, 'succeeded', '', '2026-10-20 14:25+02', '2026-10-20 14:25+02');
select fabula.bot_watchdog('2026-10-20 14:30+02') w4 \gset
select pg_temp.ck('E-33 a failed run is one incident with the error',
  exists (select 1 from jsonb_array_elements(:'w4'::jsonb->'alerts') x where x->>'agent' = 'shopify_customers' and x->>'kind' = 'error'
          and x->>'label_it' = 'Clienti Shopify: errore alle 14:10 — token scaduto'), :'w4');
insert into fabula.agent_runs (agent, started_at, finished_at, status, summary) values ('shopify_customers', '2026-10-20 14:50+02', '2026-10-20 14:51+02', 'ok', 'T-run');
insert into fabula.agent_runs (id, agent, started_at, status, summary) values ('70000000-0000-4000-a000-000000100a01', 'sales', '2026-10-20 14:00+02', 'running', 'T-run');
insert into cron.job_run_details (runid, jobid, status, return_message, start_time, end_time) values (3, 1, 'succeeded', '', '2026-10-20 14:55+02', '2026-10-20 14:55+02');
select fabula.bot_watchdog('2026-10-20 15:00+02') w5 \gset
select pg_temp.ck('E-33 …it closes when the bot works again',
  (select resolved_how from fabula.bot_alerts where agent = 'shopify_customers' and kind = 'error' order by id desc limit 1) = 'poi riuscito alle 20/10 14:50');
select pg_temp.ck('E-33 a run that never finishes is an incident',
  exists (select 1 from jsonb_array_elements(:'w5'::jsonb->'alerts') x where x->>'agent' = 'sales' and x->>'kind' = 'stuck' and x->>'label_it' = 'Vendite: partito alle 14:00 e mai finito'), :'w5');
update fabula.agent_runs set finished_at = '2026-10-20 15:05+02', status = 'ok' where id = '70000000-0000-4000-a000-000000100a01';
insert into cron.job_run_details (runid, jobid, status, return_message, start_time, end_time) values (4, 1, 'succeeded', '', '2026-10-20 15:08+02', '2026-10-20 15:08+02');
select fabula.bot_watchdog('2026-10-20 15:10+02') w6 \gset
select pg_temp.ck('E-33 …and closes when it does', (select resolved_how from fabula.bot_alerts where agent = 'sales' and kind = 'stuck' order by id desc limit 1) = 'finito');
-- a database job every minute that keeps failing: one incident and one Telegram per job and day (it was one per failed run:
-- 12 Telegrams an hour for a 5-minute job; review 14/10); a job that failed once and then worked is not news
insert into cron.job (jobid, jobname, schedule, command) values (900, 'fabula_t_job', '* * * * *', 'select 1'), (901, 'fabula_t_blip', '* * * * *', 'select 1') on conflict do nothing;
insert into cron.job_run_details (runid, jobid, status, return_message, start_time, end_time)
select 100 + g, 900, 'failed', 'ERROR: T-boom', '2026-10-20 15:00+02'::timestamptz + make_interval(mins => g), '2026-10-20 15:00+02'::timestamptz + make_interval(mins => g) from generate_series(0, 11) g;
insert into cron.job_run_details (runid, jobid, status, return_message, start_time, end_time) values
  (200, 901, 'failed', 'ERROR: T-blip', '2026-10-20 15:05+02', '2026-10-20 15:05+02'), (201, 901, 'succeeded', '', '2026-10-20 15:06+02', '2026-10-20 15:06+02');
select fabula.bot_watchdog('2026-10-20 15:12:30+02') w7 \gset
insert into cron.job_run_details (runid, jobid, status, return_message, start_time, end_time)
select 120 + g, 900, 'failed', 'ERROR: T-boom', '2026-10-20 15:12+02'::timestamptz + make_interval(mins => g), '2026-10-20 15:12+02'::timestamptz + make_interval(mins => g) from generate_series(0, 2) g;
select fabula.bot_watchdog('2026-10-20 15:15+02') w7b \gset
select pg_temp.ck('E-33 a database job that keeps failing: one incident, one Telegram, with the last error',
  (select count(*) from fabula.bot_alerts where agent = 'pg_cron' and kind = 'error' and ref like 'cron fabula_t_job %') = 1
  and (select count(*) from fabula.notify_outbox where dedupe_key like 'inc:%' and title like '%fabula_t_job%') = 1
  and exists (select 1 from jsonb_array_elements(:'w7'::jsonb->'alerts') x where x->>'kind' = 'cron_failed' and x->>'label_it' = 'Automazione del database «fabula_t_job» non riuscita alle 15:11 — ERROR: T-boom')
  and not exists (select 1 from jsonb_array_elements(:'w7b'::jsonb->'alerts') x where x->>'kind' = 'cron_failed'),
  (select string_agg(ref || ' ' || coalesce(label_it, ''), ' | ') from fabula.bot_alerts where agent = 'pg_cron' and kind = 'error'));
select pg_temp.ck('E-33 a job that failed once and then worked is not an incident', not exists (select 1 from fabula.bot_alerts where ref like 'cron fabula_t_blip %'));
insert into cron.job_run_details (runid, jobid, status, return_message, start_time, end_time) values (6, 900, 'succeeded', '', '2026-10-20 15:16+02', '2026-10-20 15:16+02');
select fabula.bot_watchdog('2026-10-20 15:20+02') w8 \gset
select pg_temp.ck('E-33 …closed when its last run succeeds',
  (select resolved_how from fabula.bot_alerts where agent = 'pg_cron' and kind = 'error' and ref = 'cron fabula_t_job 2026-10-20') = 'poi riuscita alle 15:16', :'w8');
insert into cron.job_run_details (runid, jobid, status, return_message, start_time, end_time) values (7, 900, 'failed', 'ERROR: T-boom', '2026-10-20 15:30+02', '2026-10-20 15:30+02');
select fabula.bot_watchdog('2026-10-20 15:35+02') w8b \gset
select pg_temp.ck('E-33 …failing again the same day: open again in the notice, no second Telegram',
  (select resolved_at is null from fabula.bot_alerts where ref = 'cron fabula_t_job 2026-10-20')
  and (select count(*) from fabula.notify_outbox where dedupe_key like 'inc:%' and title like '%fabula_t_job%') = 1
  and exists (select 1 from fabula.notices n, jsonb_array_elements(n.items) x where n.key = 'bot_alert' and x->>'ref' = 'cron fabula_t_job 2026-10-20'));
insert into cron.job_run_details (runid, jobid, status, return_message, start_time, end_time) values (8, 900, 'succeeded', '', '2026-10-20 15:40+02', '2026-10-20 15:40+02');
-- an incident that clears before anyone was told is never sent (it came back in every pass for a day; review 14/10)
insert into fabula.agent_runs (agent, started_at, finished_at, status, error) values ('sales', '2026-10-20 15:41+02', '2026-10-20 15:41+02', 'error', 'T-subito');
insert into fabula.agent_runs (agent, started_at, finished_at, status, summary) values ('sales', '2026-10-20 15:42+02', '2026-10-20 15:43+02', 'ok', 'T-run');
select fabula.bot_watchdog('2026-10-20 15:45+02') w8c \gset
select fabula.bot_watchdog('2026-10-20 15:50+02') w8d \gset
select pg_temp.ck('E-33 an incident that cleared before it was sent is never sent, now or later',
  not exists (select 1 from jsonb_array_elements(:'w8c'::jsonb->'alerts') x where x->>'agent' = 'sales')
  and not exists (select 1 from jsonb_array_elements(:'w8d'::jsonb->'alerts') x where x->>'agent' = 'sales')
  and (select resolved_at is not null and notified_at is null from fabula.bot_alerts where agent = 'sales' and kind = 'error' and detail = 'T-subito'),
  :'w8c');
-- the next day: what is older than a day is no longer news; nothing open → the notice closes
insert into cron.job_run_details (runid, jobid, status, return_message, start_time, end_time) values (307, 1, 'succeeded', '', '2026-10-22 02:55+02', '2026-10-22 02:55+02');
select fabula.bot_watchdog('2026-10-22 03:00+02') w9 \gset
select pg_temp.ck('E-33 a day later everything old is closed and the notice clears',
  not exists (select 1 from fabula.bot_alerts where resolved_at is null)
  and (select resolved_at is not null from fabula.notices where key = 'bot_alert')
  and exists (select 1 from fabula.bot_alerts where resolved_how = 'più vecchio di un giorno'),
  (select string_agg(agent || ':' || kind, ', ') from fabula.bot_alerts where resolved_at is null) || ' / ' || :'w9');
-- the hourly database job runs the watchdog (no Claude task needed)
select fabula.bot_heartbeat('2026-10-23 12:00+02') hb \gset
select pg_temp.ck('E-20 the hourly database job runs the watchdog and lists who is missing',
  exists (select 1 from jsonb_array_elements(:'hb'::jsonb->'missed') x where x->>'agent' = 'daily_brief') and :'hb'::jsonb ? 'watchdog'
  and exists (select 1 from fabula.bot_alerts where agent = 'daily_brief' and ref = '2026-10-23 06:47' and notified_at is not null)
  and exists (select 1 from cron.job where jobname = 'fabula_bot_heartbeat' and schedule = '25 * * * *'), left(:'hb', 300));
select pg_temp.ck('E-33 the evening check knows which missing bots were already reported',
  fabula.ops_health_check('2026-10-23')->'bots_missing_alerted' ? 'daily_brief' and not (fabula.ops_health_check('2026-10-24')->'bots_missing_alerted' ? 'daily_brief'));
select pg_temp.ck('E-33 …and its stand-in says so instead of reporting them again',
  (fabula.bot_fallback_run('ops_health', '2026-10-23')->>'body') like '%Brief del mattino e settimanale (già segnalato)%',
  left(fabula.bot_fallback_run('ops_health', '2026-10-23')->>'body', 400));
select pg_temp.ck('E-33 signed-in users cannot run the watchdog or the heartbeat',
  not has_function_privilege('authenticated', 'fabula.bot_watchdog(timestamptz)', 'execute') and not has_function_privilege('authenticated', 'fabula.bot_heartbeat(timestamptz)', 'execute'));

-- a bot that started and failed is stood in for by the database (its error row counted as «ran», so nothing ran; review 14/10);
-- the incident then closes before anyone is told, and the failed run's alarm closes with it
insert into cron.job_run_details (runid, jobid, status, return_message, start_time, end_time) values (9, 1, 'succeeded', '', '2026-10-27 08:05+01', '2026-10-27 08:05+01');
insert into fabula.agent_runs (agent, started_at, finished_at, status, error) values ('sell_down', '2026-10-27 07:24+01', '2026-10-27 07:24+01', 'error', 'T-connettore Supabase scaduto');
select id m_fail from fabula.bot_messages where agent = 'sell_down' and body like '%T-connettore Supabase scaduto%' \gset
select fabula.bot_fallback('2026-10-27 08:10+01') fb \gset
select fabula.bot_watchdog('2026-10-27 08:15+01') w10 \gset
select pg_temp.ck('E-21 a bot that failed is stood in for by the database, as its message promises',
  exists (select 1 from jsonb_array_elements(:'fb'::jsonb->'runs') x where x->>'agent' = 'sell_down' and x->>'status' = 'ok'), :'fb');
select pg_temp.ck('E-33 …its incident closes as «sostituito dal database», without a Telegram',
  (select resolved_how like 'sostituito dal database alle 27/10 08:1_' and notified_at is null from fabula.bot_alerts where agent = 'sell_down' and kind = 'error' and detail like 'T-connettore%')
  and not exists (select 1 from jsonb_array_elements(:'w10'::jsonb->'alerts') x where x->>'agent' = 'sell_down'),
  (select resolved_how || ' / notified ' || coalesce(notified_at::text, '-') from fabula.bot_alerts where agent = 'sell_down' and kind = 'error' and detail like 'T-connettore%'));
select pg_temp.ck('E-33 …and the failed run''s alarm closes by itself, saying how',
  (select read_at is not null and resolution like 'rientrato da solo: sostituito dal database alle %' and resolved_by_id is null from fabula.bot_messages where id = :m_fail),
  (select coalesce(resolution, 'open') from fabula.bot_messages where id = :m_fail));

-- ============================== E-21 · «Esegui ora (versione del database)» ==============================
select pg_temp.as_user(:'uff');
set role authenticated;
select pg_temp.err($q$select fabula.run_bot_fallback('wholesale_orders')$q$) e_x1 \gset
select pg_temp.as_user(:'tit');
select pg_temp.err($q$select fabula.run_bot_fallback('bot_inesistente')$q$) e_x2 \gset
select fabula.run_bot_fallback('wholesale_orders') x3 \gset
select pg_temp.err($q$select fabula.run_bot_fallback('wholesale_orders')$q$) e_x4 \gset
select fabula.run_bot_fallback('wholesale_orders', true) x5 \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('E-21 «Esegui ora» needs «registra» in Sistema', :'e_x1' like 'Permesso negato: serve il livello 2%', :'e_x1');
select pg_temp.ck('E-21 only the bots the database can stand in for (since v1.12 every scheduled bot; an unknown name is refused)', :'e_x2' like '%non ha una versione del database%', :'e_x2');
select pg_temp.ck('E-21 run now: recorded as a manual database run, by whom, with one message',
  (select count(*) from fabula.agent_runs where agent = 'wholesale_orders' and details->>'via' = 'db_fallback' and details->>'manual' = 'true' and details->>'by' = 'Titolare A'
          and summary like 'Eseguito ora da Titolare A (versione del database)%') = 2
  and exists (select 1 from fabula.bot_messages where id = (:'x3'::jsonb->>'message_id')::bigint and agent = 'wholesale_orders' and title like 'Eseguito ora · %'
              and body like 'Eseguito ora da Titolare A con la versione del database%' and run_id is not null), :'x3');
select pg_temp.ck('E-21 a second run the same day asks first', :'e_x4' like 'Ordini ingrosso ha già girato oggi alle __:__ (versione del database): rifarlo adesso?%|| hint: confirm', :'e_x4');
select pg_temp.ck('E-21 …and goes ahead once confirmed', (:'x5'::jsonb->>'agent') = 'wholesale_orders', :'x5');

-- ============================== E-21 · the saves the database refused, in Autocontrollo ==============================
insert into fabula.tablet_rejects (qid, device_uid, device_label, staff_id, what, ops, error, code, failed_at, reported_at) values
 ('T-q1', 'dev-t', 'tablet-1', '10000000-0000-4000-a000-000000100a03', 'log_ccp',
  '[{"rpc":"log_ccp","args":{"p_ccp_code":"CCP-3","p_value":61.5,"p_batch_lot":"LT-1","p_staff_id":"10000000-0000-4000-a000-000000100a03"}}]',
  'valore fuori limite', '23514', now() - interval '1 hour', now()),
 ('T-q2', 'dev-t', 'tablet-1', '10000000-0000-4000-a000-000000100a03', 'stock_moves',
  '[{"table":"stock_moves","row":{"id":"70000000-0000-4000-a000-000000100b01","product_id":"70000000-0000-4000-a000-000000100b02","qty":-3,"lot_number":"LT-2","move_type":"waste"}}]',
  'lotto inesistente', 'P0001', now() - interval '2 hours', now());
insert into fabula.bot_messages (agent, severity, title, body, source) values ('sicurezza', 'alert', '2 registrazioni rifiutate dal database (tablet-1)', 'x', 'auto');
select id m_rej from fabula.bot_messages where title = '2 registrazioni rifiutate dal database (tablet-1)' \gset
select pg_temp.as_user(:'mkt');
set role authenticated;
select pg_temp.st('select * from fabula.tablet_rejects_list()') s_t1 \gset
select pg_temp.as_user(:'con');
select string_agg(qid || '|' || what || '|' || coalesce(values_it, '-') || '|' || coalesce(staff, '-') || '|' || haccp::text, ' ## ' order by qid) l_con from fabula.tablet_rejects_list() where qid like 'T-%' \gset
select pg_temp.st($q$select fabula.resolve_tablet_reject('T-q1', 'rifatta')$q$) s_t2 \gset
select pg_temp.as_user(:'cas');
select pg_temp.err($q$select fabula.resolve_tablet_reject('T-q1', ' ')$q$) e_t3 \gset
select fabula.resolve_tablet_reject('T-q1', 'rifatta dal tablet alle 10:40') b_t4 \gset
select fabula.resolve_tablet_reject('T-q1', 'di nuovo') b_t5 \gset
select resolved_by || '|' || resolution l_res from fabula.tablet_rejects_list() where qid = 'T-q1' \gset
reset role;
select (select read_at is null from fabula.bot_messages where id = :m_rej) rej_open1 \gset
set role authenticated;
select fabula.resolve_tablet_reject('T-q2', 'dato sbagliato, non serve') b_t6 \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('E-21 the «registrazioni rifiutate» alarm closes when nothing is left to redo on that tablet (not before)',
  :'rej_open1' = 't' and (select read_at is not null and resolution = 'registrazioni rifiutate rifatte o chiuse in Autocontrollo'
                           and (select full_name from fabula.staff where id = resolved_by_id) = 'Casaro A' from fabula.bot_messages where id = :m_rej),
  (select coalesce(resolution, 'open') from fabula.bot_messages where id = :m_rej));
select pg_temp.ck('E-21 refused saves: not for a profile without Autocontrollo or Sistema', :'s_t1' = '42501', :'s_t1');
select pg_temp.ck('E-21 refused saves: what, the values in one line (no ids), who, and whether it is HACCP',
  :'l_con' = 'T-q1|Misura CCP|batch_lot: LT-1 · ccp_code: CCP-3 · value: 61.5|Casaro A|true ## T-q2|Movimento di magazzino|lot_number: LT-2 · move_type: waste · qty: -3|Casaro A|false', :'l_con');
select pg_temp.ck('E-21 «Segna come rifatta» needs «registra» and a note', :'s_t2' = '42501' and :'e_t3' like 'Scrivi cosa è stato fatto%', :'s_t2' || ' ' || :'e_t3');
select pg_temp.ck('E-21 …then it is closed once, with who and what', :'b_t4' = 't' and :'b_t5' = 'f' and :'l_res' = 'Casaro A|rifatta dal tablet alle 10:40', :'l_res');
update fabula.tablet_rejects set resolved_at = now() - interval '40 days' where qid = 'T-q1';
select pg_temp.as_user(:'con');
set role authenticated;
select count(*) n_old from fabula.tablet_rejects_list(30) where qid = 'T-q1' \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('E-21 closed more than 30 days ago: no longer listed', :n_old = 0);

-- ============================== small fix · the tablet's waiting-records date ==============================
select pg_temp.as_user(:'cas');
select fabula.device_checkin('dev-dw', 'tablet-dw', 'perla-v1', 3, '2026-10-13 06:06+02') dc \gset
select set_config('request.jwt.claims', '', false);
select fabula.device_watch('2026-10-13 12:00+02') dw \gset
select pg_temp.ck('the waiting-records message prints its date («delle 06:06 del 13/10», not «4el»)',
  exists (select 1 from fabula.bot_messages where agent = 'tablet' and body like '%(la più vecchia delle 06:06 del 13/10)%'),
  (select string_agg(body, ' | ') from fabula.bot_messages where agent = 'tablet' and body like '%più vecchia%'));

-- ============================== grants ==============================
select pg_temp.ck('grants: the new functions are not open to anonymous visitors',
  not has_function_privilege('anon', 'fabula.run_bot_fallback(text, boolean)', 'execute') and not has_function_privilege('anon', 'fabula.tablet_rejects_list(integer)', 'execute')
  and not has_function_privilege('anon', 'fabula.resolve_bot_messages(bigint[], text)', 'execute') and not has_function_privilege('anon', 'fabula.mark_bot_messages_read(bigint[])', 'execute'));
select pg_temp.ck('security: every definer function open to the browsers is reviewed',
  not exists (select 1 from fabula.security_findings() f where f.key not in (select key from fabula.security_accepted)),
  (select string_agg(f.key, ', ') from fabula.security_findings() f where f.key not in (select key from fabula.security_accepted)));
