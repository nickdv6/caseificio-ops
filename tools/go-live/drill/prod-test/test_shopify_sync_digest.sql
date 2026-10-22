-- v1.02 Shopify sync in the database (audit E-18) and the morning summary / quiet nights (E-07) · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh a_test
--   su postgres -c "psql -d a_test -f tools/go-live/drill/prod-test/test_shopify_sync_digest.sql" | grep -E "PASS|FAIL"
-- The clock checks use Tuesday 20/10/2026 (Rome, UTC+2) and the morning of Thursday 15/10/2026 in New York (UTC−4).
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as
$$ declare h text; begin execute p_sql; return ''; exception when others then get stacked diagnostics h = pg_exception_hint; return sqlerrm || case when coalesce(h, '') <> '' then ' || hint: ' || h else '' end; end $$;
create or replace function pg_temp.as_user(p_sub text) returns void language sql as
$$ select set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_sub), false) $$;
insert into fabula.staff (id, full_name, role, app_role, active, auth_user_id) values
  ('10000000-0000-4000-a000-000000102a01', 'Titolare S', 'owner', 'titolare', true, '00000000-0000-4000-a000-000000102a01'),
  ('10000000-0000-4000-a000-000000102a02', 'Ufficio S', 'operaio', 'amministrazione', true, '00000000-0000-4000-a000-000000102a02'),
  ('10000000-0000-4000-a000-000000102a03', 'Socio S', 'owner', 'socio', true, '00000000-0000-4000-a000-000000102a03')
on conflict do nothing;
\set tit '00000000-0000-4000-a000-000000102a01'
\set uff '00000000-0000-4000-a000-000000102a02'
\set tit_staff '10000000-0000-4000-a000-000000102a01'
\set soc_staff '10000000-0000-4000-a000-000000102a03'

-- ============================== E-18 · customers: the whole list or nothing ==============================
insert into fabula.parties (type, legal_name, source, shopify_customer_id, active)
select 'customer', 'T-Cliente ' || lpad(g::text, 2, '0'), 'shopify', 'gid://shopify/Customer/9' || g, true from generate_series(1, 40) g;
select pg_temp.err($q$select fabula.upsert_shopify_customers((select jsonb_agg(jsonb_build_object('id', 'gid://shopify/Customer/9' || g, 'name', 'X')) from generate_series(1, 39) g), 40)$q$) e_c1 \gset
select pg_temp.ck('E-18 a customer list shorter than Shopify''s count changes nothing',
  :'e_c1' = 'Shopify ha 40 clienti ma ne sono arrivati 39: nessuna modifica'
  and (select count(*) from fabula.parties where legal_name = 'X') = 0 and (select count(*) from fabula.parties where legal_name like 'T-Cliente%' and active) = 40, :'e_c1');
select pg_temp.err($q$select fabula.upsert_shopify_customers('[{"id":"gid://shopify/Customer/91"},{"id":"gid://shopify/Customer/91"}]'::jsonb)$q$) e_c2 \gset
select pg_temp.ck('E-18 the same customer twice in the list: refused', :'e_c2' like 'Lo stesso cliente compare due volte%', :'e_c2');
-- 30 of 40 come back: 10 gone > 5 % of 40 → nobody deactivated, the first names listed
select fabula.upsert_shopify_customers((select jsonb_agg(jsonb_build_object('id', 'gid://shopify/Customer/9' || g, 'name', 'T-Cliente ' || lpad(g::text, 2, '0'))) from generate_series(1, 30) g), 30) c3 \gset
select pg_temp.ck('E-18 a mass disappearance deactivates nobody and lists who is missing',
  (:'c3'::jsonb->>'deactivated')::int = 0 and (:'c3'::jsonb->>'deactivation_blocked')::int = 10 and (:'c3'::jsonb->>'deactivation_cap')::int = 2
  and :'c3'::jsonb->'gone_names'->>0 = 'T-Cliente 31' and (select count(*) from fabula.parties where legal_name like 'T-Cliente%' and active) = 40, :'c3');
-- 38 of 40: 2 gone = within the cap (5 % of 40 = 2) → deactivated
select fabula.upsert_shopify_customers((select jsonb_agg(jsonb_build_object('id', 'gid://shopify/Customer/9' || g, 'name', 'T-Cliente ' || lpad(g::text, 2, '0'))) from generate_series(1, 38) g)) c4 \gset
select pg_temp.ck('E-18 a few customers gone (within 5 %) are deactivated; the old one-argument call still works',
  (:'c4'::jsonb->>'deactivated')::int = 2 and (:'c4'::jsonb->>'deactivation_blocked')::int = 0
  and (select count(*) from fabula.parties where legal_name like 'T-Cliente%' and not active) = 2, :'c4');
select pg_temp.as_user(:'tit');
set role authenticated;
select pg_temp.err($q$select fabula.upsert_shopify_customers('[]'::jsonb)$q$) e_c5 \gset
select pg_temp.err($q$select value from fabula.job_secrets$q$) e_c6 \gset
select pg_temp.err($q$select fabula.shopify_sync_call('shopify_orders')$q$) e_c7 \gset
select pg_temp.err($q$select fabula.shopify_sync_start('shopify_orders')$q$) e_c8 \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('E-18 a browser cannot run the customer copy, read the function key or call the sync directly',
  :'e_c5' like 'permission denied%' and :'e_c6' like 'permission denied%' and :'e_c7' like 'permission denied%' and :'e_c8' like 'permission denied%',
  :'e_c5' || ' / ' || :'e_c6' || ' / ' || :'e_c7' || ' / ' || :'e_c8');

-- ============================== E-18 · orders: checked against Shopify before anything is written ==============================
\set ord '[{"id":"gid://shopify/Order/701","name":"#T701","source_name":"web","financial_status":"PAID","created_at":"2026-10-19T08:00:00Z","updated_at":"2026-10-19T08:00:00Z","subtotal":"10.00","tax":"0.40","total":"10.40","line_items":[]},{"id":"gid://shopify/Order/702","name":"#T702","source_name":"pos","financial_status":"PAID","created_at":"2026-10-19T09:00:00Z","updated_at":"2026-10-19T09:00:00Z","subtotal":"5.00","tax":"0.20","total":"5.20","line_items":[]}]'
select pg_temp.err(format($q$select fabula.upsert_shopify_orders(%L::jsonb, '{"count":3,"total":15.6}'::jsonb)$q$, :'ord')) e_o1 \gset
select pg_temp.err(format($q$select fabula.upsert_shopify_orders(%L::jsonb, '{"count":2,"total":15.7}'::jsonb)$q$, :'ord')) e_o2 \gset
select pg_temp.err($q$select fabula.upsert_shopify_orders('[{"id":"gid://shopify/Order/703","total":"1"},{"id":"gid://shopify/Order/703","total":"1"}]'::jsonb, '{"count":2}'::jsonb)$q$) e_o3 \gset
select pg_temp.ck('E-18 orders: a count or total that differs from Shopify, or an order twice, writes nothing',
  :'e_o1' = 'Shopify ha 3 ordini nel periodo ma ne sono arrivati 2: nessuna modifica'
  and :'e_o2' = 'Il totale degli ordini letti (€ 15,60) non è quello di Shopify (€ 15,70): nessuna modifica'
  and :'e_o3' like '1 ordini compaiono due volte%'
  and not exists (select 1 from fabula.sales_orders where order_number like '#T70%'), :'e_o1' || ' / ' || :'e_o2' || ' / ' || :'e_o3');
select fabula.upsert_shopify_orders(:'ord'::jsonb, '{"count":2,"total":15.6}'::jsonb) o4 \gset
select pg_temp.ck('E-18 orders that agree are written as before (the POS one closes its day)',
  (:'o4'::jsonb->>'created')::int = 2 and :'o4'::jsonb#>>'{checked,count}' = '2'
  and (select channel::text from fabula.sales_orders where order_number = '#T702') = 'store_pos'
  and exists (select 1 from fabula.pos_daily_closings where closing_date = '2026-10-19' and source = 'shopify_pos'), :'o4');

-- ============================== E-18 · the clock: slots of bot_schedule, run by the database ==============================
select pg_temp.ck('E-18 the Shopify jobs and the backup are database jobs, the others Claude tasks',
  (select string_agg(agent, ',' order by agent) from fabula.bot_schedule where runner = 'db') = 'backup_export,shopify_customers,shopify_inventory,shopify_orders'
  and (select runner from fabula.bot_schedule where agent = 'milk_planning') = 'claude');
select fabula.shopify_sync_tick('2026-10-20 06:06:00+02') t1 \gset
select pg_temp.ck('E-18 at 06:06 Rome: the 06:05 customer sync is called with the function''s key, nothing else yet',
  (select string_agg(x->>'agent', ',') from jsonb_array_elements(:'t1'::jsonb->'calls') x) = 'shopify_customers'
  and exists (select 1 from net.http_request_queue q where q.url like '%/functions/v1/shopify-sync' and q.body->>'agent' = 'shopify_customers'
              and q.headers->>'x-sync-secret' = (select value from fabula.job_secrets where name = 'shopify_sync') and q.body->>'slot' is not null)
  and (select attempt from fabula.db_job_calls where agent = 'shopify_customers' and slot = '2026-10-20 06:05:00+02') = 1, :'t1');
select fabula.shopify_sync_tick('2026-10-20 06:12:00+02') t2 \gset
select pg_temp.ck('E-18 at 06:12: orders called; customers not again (called 7 minutes ago)',
  (select string_agg(x->>'agent', ',') from jsonb_array_elements(:'t2'::jsonb->'calls') x) = 'shopify_orders', :'t2');
-- the customer sync never started; the order sync ran and failed
insert into fabula.agent_runs (agent, started_at, finished_at, status, error, details) values ('shopify_orders', '2026-10-20 06:12:30+02', '2026-10-20 06:12:40+02', 'error', 'T-Shopify 502', '{"via":"db"}');
select fabula.shopify_sync_tick('2026-10-20 06:26:00+02') t3 \gset
select fabula.shopify_sync_tick('2026-10-20 06:33:00+02') t4 \gset
select fabula.shopify_sync_tick('2026-10-20 07:10:00+02') t5 \gset
select pg_temp.ck('E-18 a call that never started is repeated once after 20 minutes, a failed run once too; then no more',
  (select string_agg((x->>'agent') || '#' || (x->>'attempt'), ',') from jsonb_array_elements(:'t3'::jsonb->'calls') x) = 'shopify_customers#2'
  and (select string_agg((x->>'agent') || '#' || (x->>'attempt'), ',') from jsonb_array_elements(:'t4'::jsonb->'calls') x) = 'shopify_orders#2'
  and jsonb_array_length(:'t5'::jsonb->'calls') = 0, :'t3' || ' / ' || :'t4' || ' / ' || :'t5');
insert into fabula.agent_runs (agent, started_at, status, details) values ('shopify_inventory', '2026-10-20 07:32:30+02', 'running', '{"via":"db"}');
select fabula.shopify_sync_tick('2026-10-20 07:40:00+02') t6 \gset
select fabula.shopify_sync_tick('2026-10-25 07:40:00+01') t7 \gset
update fabula.settings set value = '0' where key = 'shopify.sync_enabled';
select fabula.shopify_sync_tick('2026-10-21 06:06:00+02') t8 \gset
update fabula.settings set value = '1' where key = 'shopify.sync_enabled';
select pg_temp.ck('E-18 a run in progress is left alone; nothing on Sunday; nothing when switched off',
  jsonb_array_length(:'t6'::jsonb->'calls') = 0 and jsonb_array_length(:'t7'::jsonb->'calls') = 0 and :'t8'::jsonb->>'enabled' = 'false', :'t6' || ' / ' || :'t7' || ' / ' || :'t8');

-- ============================== E-18 · a run: start, finish, the message written by the database ==============================
select fabula.shopify_sync_start('shopify_customers', null, '2026-10-20 06:05:00+02') r1 \gset
select pg_temp.err($q$select fabula.shopify_sync_start('shopify_customers')$q$) e_r2 \gset
select pg_temp.ck('E-18 one run at a time', :'e_r2' = 'Sincronizzazione già in corso', :'e_r2');
select fabula.shopify_sync_finish(:'r1', '{"ok":true,"shopify":{"count":12},"upsert":{"received":12,"created":3,"updated":9,"deactivated":0,"deactivation_blocked":0,"placeholders_left":0,"wholesale":2}}') f1 \gset
select pg_temp.ck('E-07/E-18 new customers are news, not a warning: info, with the counts',
  (select severity || '|' || title || '|' || body from fabula.bot_messages where run_id = :'r1') =
  E'info|3 nuovi clienti da Shopify|**In breve**\n- 12 clienti su Shopify · 3 nuovi · 9 aggiornati · 0 disattivati · 2 all''ingrosso'
  and (select status || '|' || summary from fabula.agent_runs where id = :'r1') = 'ok|12 letti, 3 nuovi, 9 aggiornati, 0 disattivati',
  (select severity || '|' || title || '|' || body from fabula.bot_messages where run_id = :'r1'));
select fabula.shopify_sync_start('shopify_orders') r3 \gset
select fabula.shopify_sync_finish(:'r3', '{"ok":false,"error":"Shopify ha 4 ordini nel periodo ma ne sono arrivati 3: nessuna modifica"}') f3 \gset
select pg_temp.ck('E-18 a refused order copy: the run is an error, the alarm says why and that nothing was written; no second Telegram (the incident sends it)',
  (select status from fabula.agent_runs where id = :'r3') = 'error'
  and (select severity || '|' || title from fabula.bot_messages where run_id = :'r3') = 'alert|Ordini Shopify non copiati'
  and (select body from fabula.bot_messages where run_id = :'r3') like '%Causa: Shopify ha 4 ordini nel periodo ma ne sono arrivati 3: nessuna modifica%Nessun ordine è stato scritto%'
  and not exists (select 1 from fabula.notify_outbox where source = 'bot_messages' and source_ref = (select id::text from fabula.bot_messages where run_id = :'r3')),
  (select body from fabula.bot_messages where run_id = :'r3'));
-- products sold that are not linked to the stock: a warning the first time, «(invariato)» the next
select fabula.shopify_sync_start('shopify_orders') r4 \gset
select fabula.shopify_sync_finish(:'r4', '{"ok":true,"window":{"days":3},"shopify":{"count":2,"pos":1},"upsert":{"created":0,"updated":2,"unmapped_lines":1,"unmapped_variants":[{"variant_id":"gid://v/1","label":"T-Ricotta · 250 g"}]},"pos_days":["2026-10-19"],"fulfil":{"pending":0,"done":0,"failed":[]}}') f4 \gset
select fabula.shopify_sync_start('shopify_orders') r5 \gset
select fabula.shopify_sync_finish(:'r5', '{"ok":true,"window":{"days":3},"shopify":{"count":2,"pos":1},"upsert":{"created":0,"updated":2,"unmapped_lines":0,"unmapped_variants":[{"variant_id":"gid://v/1","label":"T-Ricotta · 250 g"}]},"pos_days":[],"fulfil":{"pending":0,"done":0,"failed":[]}}') f5 \gset
select pg_temp.ck('E-18 a new unlinked product: warning, «Collega al magazzino», the products page; the POS day with its total',
  (select severity || '|' || title || '|' || action_url from fabula.bot_messages where run_id = :'r4') = 'warn|Collega al magazzino: T-Ricotta · 250 g|admin.html#prodotti'
  and (select body from fabula.bot_messages where run_id = :'r4') like '%1. Collega al magazzino: T-Ricotta · 250 g (Configurazione → Prodotti Shopify)%'
  and (select body from fabula.bot_messages where run_id = :'r4') like '%Cassa di lun 19/10: € 5,20, 1 scontrini (da Shopify POS)%',
  (select body from fabula.bot_messages where run_id = :'r4'));
select pg_temp.ck('E-18 …the same list next time: info, one line «(invariato)»',
  (select severity from fabula.bot_messages where run_id = :'r5') = 'info'
  and (select body from fabula.bot_messages where run_id = :'r5') like '%1 prodotto Shopify non collegato al magazzino (invariato)%'
  and (select body from fabula.bot_messages where run_id = :'r5') not like '%Da fare%',
  (select severity || '|' || body from fabula.bot_messages where run_id = :'r5'));
-- shipments: refused by Shopify, and no permission yet
select fabula.shopify_sync_start('shopify_orders') r6 \gset
select fabula.shopify_sync_finish(:'r6', '{"ok":true,"window":{"days":3},"shopify":{"count":0},"upsert":{"created":0,"updated":0,"unmapped_variants":[]},"fulfil":{"pending":2,"done":0,"failed":[{"order":"#1005","error":"Fulfillment order is on hold"}],"blocked":null}}') f6 \gset
select pg_temp.ck('E-18 a shipment Shopify refused: alarm, confirm it by hand with Shopify''s reason',
  (select severity || '|' || title from fabula.bot_messages where run_id = :'r6') = 'alert|Spedizione #1005 non confermata su Shopify'
  and (select body from fabula.bot_messages where run_id = :'r6') like '%Conferma a mano su Shopify la spedizione #1005 (Shopify risponde: Fulfillment order is on hold)%',
  (select body from fabula.bot_messages where run_id = :'r6'));
-- stock: report only, then the same numbers again
\set inv '{"ok":true,"push":0,"setting":2,"counted":false,"available_kg":0,"variants":[{"variant_id":"v1","label":"T-Mozzarella · 250 g","available_units":0,"shopify_qty":100,"tracked":true,"policy":"DENY","split_basis":"parti_uguali","set":false},{"variant_id":"v2","label":"T-Mozzarella · 500 g","available_units":0,"shopify_qty":0,"tracked":false,"policy":"DENY","split_basis":"parti_uguali","set":false}],"untracked":["T-Mozzarella · 500 g"],"selling_at_zero":[],"not_found":[],"errors":[]}'
update fabula.agent_runs set status = 'ok', finished_at = started_at where agent = 'shopify_inventory' and status = 'running';
select fabula.shopify_sync_start('shopify_inventory') r7 \gset
select fabula.shopify_sync_finish(:'r7', :'inv') f7 \gset
update fabula.agent_runs set finished_at = coalesce(finished_at, now()), status = case when status = 'running' then 'ok' else status end where agent = 'shopify_inventory' and id <> :'r7';
select fabula.shopify_sync_start('shopify_inventory') r8 \gset
select fabula.shopify_sync_finish(:'r8', :'inv') f8 \gset
select pg_temp.ck('E-18 stock, report only: what to fix in Shopify and the difference, in plain words',
  (select severity || '|' || title from fabula.bot_messages where run_id = :'r7') = 'warn|Shopify non aggiornato: in attesa della conta di apertura'
  and (select body from fabula.bot_messages where run_id = :'r7') like '%Attiva «Monitora quantità» su 1 prodotto in Shopify (prodotto → variante): T-Mozzarella · 500 g%'
  and (select body from fabula.bot_messages where run_id = :'r7') like '%T-Mozzarella · 250 g: magazzino 0 · Shopify 100%'
  and (select body from fabula.bot_messages where run_id = :'r7') like '%Si aggiornerà da solo dopo la conta di apertura%',
  (select body from fabula.bot_messages where run_id = :'r7'));
select pg_temp.ck('E-18 …the 13:32 run with the same numbers: info, «(invariato)», no «Da fare»',
  (select severity || '|' || title from fabula.bot_messages where run_id = :'r8') = 'info|Shopify non aggiornato: in attesa della conta di apertura (invariato)'
  and (select body from fabula.bot_messages where run_id = :'r8') not like '%Da fare%',
  (select severity || '|' || title from fabula.bot_messages where run_id = :'r8'));
select fabula.shopify_sync_start('shopify_inventory') r9 \gset
select fabula.shopify_sync_finish(:'r9', '{"ok":true,"push":1,"blocked":"scope","missing":"read_locations, write_inventory"}') f9 \gset
select pg_temp.ck('E-18 stock without the Shopify permission: says which, changes nothing',
  (select severity || '|' || title from fabula.bot_messages where run_id = :'r9') = 'warn|Giacenze non confrontate con Shopify: manca un permesso'
  and (select body from fabula.bot_messages where run_id = :'r9') like '%read_locations, write_inventory%', (select body from fabula.bot_messages where run_id = :'r9'));

-- ============================== E-21 · «Esegui ora» for the database jobs ==============================
delete from fabula.db_job_calls where requested_at > now();   -- the clock checks above used next week's times
select pg_temp.as_user(:'uff');
set role authenticated;
select pg_temp.err($q$select fabula.run_bot_fallback('shopify_customers')$q$) e_n1 \gset
select pg_temp.as_user(:'tit');
select pg_temp.err($q$select fabula.run_bot_fallback('shopify_customers')$q$) e_n2 \gset
reset role;
update fabula.agent_runs set status = 'ok', finished_at = now() where status = 'running' and agent like 'shopify_%';
select pg_temp.as_user(:'tit');
set role authenticated;
select pg_temp.err($q$select fabula.run_bot_fallback('shopify_customers')$q$) e_n3 \gset
select fabula.run_bot_fallback('shopify_customers', true) n4 \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('E-21 «Esegui ora» on a Shopify job: needs «registra» in Sistema; asks when it already ran today; then calls the function with the name',
  :'e_n1' like 'Permesso negato: serve il livello 2%' and :'e_n3' like 'Clienti Shopify ha già girato oggi alle __:__: rifarlo adesso?%|| hint: confirm'
  and :'n4'::jsonb->>'started' = 'true'
  and exists (select 1 from fabula.db_job_calls where agent = 'shopify_customers' and by_name = 'Titolare S' and slot is null)
  and exists (select 1 from net.http_request_queue where body->>'agent' = 'shopify_customers' and body->>'by' = 'Titolare S'),
  :'e_n1' || ' / ' || :'e_n2' || ' / ' || :'e_n3' || ' / ' || :'n4');
select pg_temp.as_user(:'tit');
set role authenticated;
select pg_temp.err($q$select fabula.run_bot_fallback('shopify_customers')$q$) e_n5 \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('E-21 …pressed again within minutes: says it was just started', :'e_n5' like 'Clienti Shopify è stato avviato alle __:__: rifarlo adesso?%|| hint: confirm', :'e_n5');

-- ============================== E-33 · the hourly check: a Shopify job that did not start ==============================
-- v1.10: a day ahead of the real one (it was the fixed 20/10/2026: on that very day the runs made above counted as done and the check failed)
select ((select d from generate_series((now() at time zone 'Europe/Rome')::date + 3, (now() at time zone 'Europe/Rome')::date + 5, interval '1 day') d
          where extract(isodow from d) between 1 and 6 order by d limit 1) + time '08:30') at time zone 'Europe/Rome' w_at \gset
select fabula.bot_watchdog(:'w_at'::timestamptz) w1 \gset
select pg_temp.ck('E-33 a Shopify job that did not start: its incident tells to use «Esegui ora» (the database does it, not a Claude task)',
  exists (select 1 from fabula.notify_outbox where source = 'bot_alerts' and title like 'Clienti Shopify: non è partito%' and body like 'La sincronizzazione con Shopify la fa il database. Per riprovare: Configurazione → Bot → «Esegui ora»%'),
  (select string_agg(title || ' :: ' || coalesce(body, ''), ' || ') from fabula.notify_outbox where source = 'bot_alerts'));

-- ============================== review fixes: runs cut short, calls that never arrived, the same alarm again ==============================
-- a working day after the E-33 day above (it was the fixed 22/10/2026: from that morning the runs made above at the real time counted as done for the slot and the check failed)
select (select d from generate_series((now() at time zone 'Europe/Rome')::date + 6, (now() at time zone 'Europe/Rome')::date + 12, interval '1 day') d
         where extract(isodow from d) between 1 and 6 order by d limit 1)::date k_day \gset
insert into fabula.agent_runs (agent, started_at, status, details) values ('shopify_inventory', (:'k_day'::date + time '07:32:10') at time zone 'Europe/Rome', 'running', '{"via":"db"}');
select fabula.shopify_sync_tick((:'k_day'::date + time '07:50') at time zone 'Europe/Rome') k1 \gset
select pg_temp.ck('a run cut short (still «running» after 15 minutes) is marked failed, and the slot is called again',
  (select status || '|' || error from fabula.agent_runs where agent = 'shopify_inventory' and started_at = (:'k_day'::date + time '07:32:10') at time zone 'Europe/Rome') like 'error|Interrotta%'
  and (:'k1'::jsonb->>'stale')::int = 1 and exists (select 1 from jsonb_array_elements(:'k1'::jsonb->'calls') x where x->>'agent' = 'shopify_inventory'), :'k1');
-- a call that never reached the function: the stub answer 404
select request_id rq from fabula.db_job_calls where agent = 'shopify_inventory' order by id desc limit 1 \gset
insert into net._http_response (id, status_code, content) values (:rq, 404, '{"error":"not found"}');
update fabula.db_job_calls set requested_at = (:'k_day'::date + time '07:50') at time zone 'Europe/Rome' where request_id = :rq;
select fabula.shopify_sync_tick((:'k_day'::date + time '07:56') at time zone 'Europe/Rome') k2 \gset
select pg_temp.ck('a call that never reached the function (not published): a failed run and an alarm saying why, in plain words',
  (:'k2'::jsonb->>'not_started')::int = 1
  and (select status || '|' || error from fabula.agent_runs where agent = 'shopify_inventory' and summary = 'non partita' order by started_at desc limit 1)
      = 'error|la funzione shopify-sync non è pubblicata su Supabase (Edge Functions)'
  and exists (select 1 from fabula.bot_messages where agent = 'shopify_inventory' and title = 'Giacenze Shopify non partita' and body like '%Avvisa Nick: la funzione shopify-sync non è pubblicata%')
  and (select http_status from fabula.db_job_calls where request_id = :rq) = 404, :'k2');
-- the same refused shipment two days in a row: one alarm, then «(invariato)» while it is open
select fabula.shopify_sync_start('shopify_orders') r10 \gset
select fabula.shopify_sync_finish(:'r10', '{"ok":true,"window":{"days":3},"shopify":{"count":0},"upsert":{"unmapped_variants":[]},"fulfil":{"pending":1,"done":0,"failed":[{"order":"#2001","error":"ordine annullato su Shopify: non spedirlo"}]}}') f10 \gset
select fabula.shopify_sync_start('shopify_orders') r11 \gset
select fabula.shopify_sync_finish(:'r11', '{"ok":true,"window":{"days":3},"shopify":{"count":0},"upsert":{"unmapped_variants":[]},"fulfil":{"pending":1,"done":0,"failed":[{"order":"#2001","error":"ordine annullato su Shopify: non spedirlo"}]}}') f11 \gset
select pg_temp.ck('the same alarm while the first is open: no second alarm, no second Telegram, «(invariato)»',
  (select severity from fabula.bot_messages where run_id = :'r10') = 'alert'
  and (select severity || '|' || title from fabula.bot_messages where run_id = :'r11') = 'info|Spedizione #2001 non confermata su Shopify (invariato)'
  and (select count(*) from fabula.notify_outbox where source = 'bot_messages' and title like 'Spedizione #2001%') = 1,
  (select severity || '|' || title from fabula.bot_messages where run_id = :'r11'));
select fabula.shopify_sync_start('shopify_inventory') r12 \gset
update fabula.settings set value = '1' where key = 'shopify.push_inventory';
select fabula.shopify_sync_finish(:'r12', '{"ok":false,"error":"Shopify 502"}') f12 \gset
update fabula.settings set value = '2' where key = 'shopify.push_inventory';
select pg_temp.ck('a stock failure while the push is on is an alarm (the stock on Shopify may be wrong)', (select severity from fabula.bot_messages where run_id = :'r12') = 'alert');
select pg_temp.ck('the backups never carry the function key nor the call log',
  not ('job_secrets' = any (fabula.backup_table_list())) and not ('db_job_calls' = any (fabula.backup_table_list())) and 'bot_alerts' = any (fabula.backup_table_list()));

-- ============================== E-07 · what reaches Telegram, and when ==============================
insert into fabula.notify_targets (staff_id, chat_id, topics, tz, quiet_from, quiet_to)
values (:'tit_staff', 777001, '{food_safety,infra,decisions}', 'America/New_York',
        ((now() at time zone 'America/New_York')::time - interval '1 hour')::time, ((now() at time zone 'America/New_York')::time + interval '1 hour')::time),
       (:'soc_staff', 777002, '{decisions}', 'Europe/Rome', '03:00', '03:01')
on conflict (staff_id) do update set chat_id = excluded.chat_id, topics = excluded.topics, tz = excluded.tz, quiet_from = excluded.quiet_from, quiet_to = excluded.quiet_to;
select fabula.notify_enqueue('infra', 'T-bot non partito', 'x', 'Allarme bot', 'bot_alerts', 'T1', null) i1 \gset
insert into fabula.notices (key, severity, title_it, items, expires_at) values ('infra_uptime', 'alert', 'T-Sistema non raggiungibile', '[]', now() + interval '1 hour')
on conflict (key) do update set severity = 'alert', title_it = excluded.title_it, resolved_at = null, expires_at = excluded.expires_at;
select fabula.notify_enqueue('food_safety', 'T-CCP fuori limite', 'x', 'Sicurezza alimentare') i3 \gset
select pg_temp.ck('E-07 during the quiet hours: a bot that did not start waits for the morning; «system down» and food safety go now',
  (select due_at > now() + interval '30 minutes' from fabula.notify_deliveries where outbox_id = :'i1' and staff_id = :'tit_staff')
  and (select o.urgent and d.due_at <= now() from fabula.notify_outbox o join fabula.notify_deliveries d on d.outbox_id = o.id
        where o.source = 'notices' and o.title = 'T-Sistema non raggiungibile' and d.staff_id = :'tit_staff')
  and (select due_at <= now() from fabula.notify_deliveries where outbox_id = :'i3' and staff_id = :'tit_staff'),
  (select string_agg(o.title || '→' || to_char(d.due_at - now(), 'HH24:MI'), ', ') from fabula.notify_outbox o join fabula.notify_deliveries d on d.outbox_id = o.id where d.staff_id = :'tit_staff'));
select fabula.notify_enqueue('infra', 'T-pg_cron fermo', 'x', 'Allarme bot', 'bot_alerts', 'T2', null, null, null, true) i4 \gset
select pg_temp.ck('E-07 the database scheduler stopped is «system down»; its reminder keeps the urgency',
  (select due_at <= now() from fabula.notify_deliveries where outbox_id = :'i4' and staff_id = :'tit_staff')
  and position('r.agent = ''pg_cron'' and r.kind = ''stuck''' in pg_get_functiondef('fabula.bot_watchdog'::regproc)) > 0);
-- routine decisions due today: Telegram «Da decidere», no 30-minute reminder; other warnings stay in the app
select fabula.post_bot_message('wholesale_orders', 'warn', 'T-Inoltra 2 conferme WhatsApp · 12 kg per mer 21/10', 'corpo') d1 \gset
select fabula.post_bot_message('procurement', 'warn', 'T-Approva 1 ordine d''acquisto (€ 120)', 'corpo') d2 \gset
select pg_temp.ck('E-07 a routine decision due today reaches Telegram as «Da decidere», without the reminder; another warning does not',
  (select topic || '|' || (escalate_at is null)::text from fabula.notify_outbox where source = 'bot_messages' and source_ref = :'d1') = 'decisions|true'
  and not exists (select 1 from fabula.notify_outbox where source = 'bot_messages' and source_ref = :'d2')
  and (select due_at <= now() from fabula.notify_deliveries d join fabula.notify_outbox o on o.id = d.outbox_id where o.source_ref = :'d1' and d.staff_id = :'soc_staff'),
  (select string_agg(topic || ':' || title, ', ') from fabula.notify_outbox where source = 'bot_messages'));
insert into fabula.approvals (kind, requested_by, summary, payload, requested_at, auto_approve_at, auto_rule)
values ('other', 'milk_planning', 'T-Piano latte mer 21/10: 900 kg', '{"type":"milk_plan"}', now(), now() + interval '60 minutes', 'T-regola');
select fabula.post_bot_message('milk_planning', 'warn', 'T-Approva il latte di mer 21/10: 900 kg', 'corpo') d3 \gset
select pg_temp.ck('E-10 the decision says when it approves itself if nobody decides (Italian time)',
  (select body from fabula.notify_outbox where source = 'bot_messages' and source_ref = :'d3') like E'corpo\n\nSe nessuno decide, si approva da sola alle __:__ (ora italiana).',
  (select coalesce(body, '-') from fabula.notify_outbox where source = 'bot_messages' and source_ref = :'d3'));

-- ============================== E-07 · the morning summary ==============================
-- the summary time is set one minute before «in 10 minutes» (New York time), so the checks do not depend on when the suite runs
select now() + interval '10 minutes' t_dig \gset
update fabula.notify_targets set quiet_from = '22:00', quiet_to = '07:30', digest_last = null,
       digest_at = ((:'t_dig'::timestamptz at time zone 'America/New_York') - interval '1 minute')::time where staff_id = :'tit_staff';
insert into fabula.bot_messages (agent, severity, title, body, source, created_at) values
  ('daily_brief', 'info', 'T-Ieri tutto in ordine', 'x', 'bot', now() - interval '2 hours'),
  ('sicurezza', 'alert', 'T-Lotto chiuso senza CCP 3', 'x', 'auto', now() + interval '1 minute');
insert into fabula.approvals (kind, requested_by, summary, payload, status, decided_by, decided_at)
values ('purchase_order', 'procurement', 'T-PO-0001 fermenti € 80', '{}', 'approved', 'Approvazione automatica', now() - interval '1 hour');
select fabula.notify_digest_tick(:'t_dig'::timestamptz - interval '3 minutes') g0 \gset
select fabula.notify_digest_tick(:'t_dig'::timestamptz) g1 \gset
select fabula.notify_digest_tick(:'t_dig'::timestamptz + interval '30 minutes') g2 \gset
select o.text_html dig from fabula.notify_outbox o where o.topic = 'digest' order by created_at desc limit 1 \gset
select pg_temp.ck('E-07 one summary a day at the person''s own time (none before, none twice)',
  :g0 = 0 and :g1 = 1 and :g2 = 0
  and (select count(*) from fabula.notify_deliveries d join fabula.notify_outbox o on o.id = d.outbox_id where o.topic = 'digest') = 1
  and (select staff_id from fabula.notify_deliveries d join fabula.notify_outbox o on o.id = d.outbox_id where o.topic = 'digest') = :'tit_staff',
  :g0 || '/' || :g1 || '/' || :g2);
select pg_temp.ck('E-07 the summary: decisions with when they approve themselves, open alarms, news, automatic approvals, the brief, the Console',
  :'dig' like '📋 <b>Riepilogo</b> · ___ __/__ · orari di New York%'
  and :'dig' like '%<b>Da decidere</b> (%)%T-Piano latte mer 21/10: 900 kg · si approva da sola alle __:__%'
  and :'dig' like '%<b>Allarmi aperti</b>%T-Lotto chiuso senza CCP 3%'
  and :'dig' like '%<b>Da sapere</b>%T-Inoltra 2 conferme WhatsApp%'
  and :'dig' not like '%<b>Da sapere</b>%T-Approva il latte di mer 21/10%'      -- already under «Da decidere»
  and :'dig' not like '%<b>Allarmi aperti</b>%bot da controllare%<b>Bot da controllare</b>%'
  and :'dig' like '%<b>Approvato da solo</b> (1)%T-PO-0001 fermenti € 80%'
  and :'dig' like '%<b>Brief</b> T-Ieri tutto in ordine%'
  and :'dig' like '%console.html#oggi">Apri la Console</a>', :'dig');
update fabula.notify_deliveries d set due_at = now() from fabula.notify_outbox o where o.id = d.outbox_id and o.topic = 'digest';
select pg_temp.ck('E-07 the summary has no «Me ne occupo io» buttons and is not listed among the alarms',
  (select bool_and(not (x->>'buttons')::boolean) from jsonb_array_elements(fabula.notify_claim(100)) x where x->>'text' like '📋%')
  and not exists (select 1 from jsonb_array_elements(fabula.notify_overview()->'recent') r where r->>'title' like 'Riepilogo%'));
update fabula.notify_targets set digest_at = '23:50', digest_last = null where staff_id = :'tit_staff';
select fabula.notify_digest_tick(((current_date + 2)::timestamp + interval '00:10') at time zone 'America/New_York') g3 \gset
select pg_temp.ck('E-07 a summary time just before midnight still goes out after midnight, for the day before',
  :g3 = 1 and (select digest_last from fabula.notify_targets where staff_id = :'tit_staff') = current_date + 1);
-- nothing to say
delete from fabula.approvals where status = 'pending';
update fabula.bot_messages set read_at = now() where read_at is null;
delete from fabula.bot_alerts;
select fabula.notify_digest_text(:'tit_staff', now(), now()) dig2 \gset
select pg_temp.ck('E-07 a quiet day: one line «Niente da segnalare»', :'dig2' like '%Niente da segnalare: nessuna decisione in attesa, nessun allarme aperto.%', :'dig2');

-- what a person may not see in the app is not in their summary; a profile without «vede» in Sistema cannot ask for one
insert into fabula.staff (id, full_name, role, app_role, active, auth_user_id) values
  ('10000000-0000-4000-a000-000000102a04', 'Casaro S', 'casaro', 'produzione', true, '00000000-0000-4000-a000-000000102a04') on conflict do nothing;
insert into fabula.approvals (kind, requested_by, summary, payload) values ('other', 'test', 'T-Segreto da approvare', '{}');
insert into fabula.bot_messages (agent, severity, title, body, source) values ('sales', 'warn', 'T-Cliente non paga da 60 giorni', 'x', 'bot');
select fabula.notify_digest_text('10000000-0000-4000-a000-000000102a04', now() - interval '1 day', now()) dig3 \gset
select fabula.notify_digest_text(:'tit_staff', now() - interval '1 day', now()) dig4 \gset
select pg_temp.as_user('00000000-0000-4000-a000-000000102a04');
set role authenticated;
select pg_temp.err($q$select fabula.notify_set_prefs('{food_safety}', null, null, null, null, '07:00')$q$) e_dg \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('the summary follows the app''s rules: a casaro sees no approvals or office messages, the owner does; a casaro cannot ask for one',
  :'dig3' not like '%T-Segreto da approvare%' and :'dig3' not like '%T-Cliente non paga%' and :'dig4' like '%T-Segreto da approvare%' and :'dig4' like '%T-Cliente non paga%'
  and :'e_dg' like 'Il riepilogo riassume gli avvisi%', :'e_dg');
-- a bot incident held for the silence: cleared before the morning → not sent; still open at the summary time → folded into it
update fabula.notify_targets set quiet_from = ((now() at time zone 'America/New_York') - interval '1 hour')::time,
       quiet_to = ((now() at time zone 'America/New_York') + interval '1 hour')::time, digest_last = null,
       digest_at = ((now() at time zone 'America/New_York') + interval '1 hour')::time where staff_id = :'tit_staff';
insert into fabula.bot_alerts (agent, kind, ref, label_it, alerted_at, last_seen_at) values
  ('marketing', 'missed', 'T-held-1', 'T-Marketing: non è partito', now(), now()), ('sales', 'missed', 'T-held-2', 'T-Vendite: non è partito', now(), now());
select fabula.notify_enqueue('infra', 'T-Marketing: non è partito', 'x', 'Allarme bot', 'bot_alerts', (select id::text from fabula.bot_alerts where ref = 'T-held-1'), null, null, 'admin.html#bots') h1 \gset
select fabula.notify_enqueue('infra', 'T-Vendite: non è partito', 'x', 'Allarme bot', 'bot_alerts', (select id::text from fabula.bot_alerts where ref = 'T-held-2'), null, null, 'admin.html#bots') h2 \gset
update fabula.bot_alerts set resolved_at = now(), resolved_how = 'partito' where ref = 'T-held-1';
update fabula.notify_deliveries set due_at = now() where outbox_id in (:'h1', :'h2');
select fabula.notify_claim(100) cl3 \gset
select pg_temp.ck('an incident that cleared while its Telegram waited is not sent late',
  (select status || '|' || coalesce(error, '') from fabula.notify_deliveries where outbox_id = :'h1' and staff_id = :'tit_staff') = 'skipped|già preso in carico', :'cl3');
update fabula.notify_deliveries set status = 'queued', due_at = now() + interval '1 hour' where outbox_id = :'h2' and staff_id = :'tit_staff';
select fabula.notify_digest_tick(now() + interval '1 hour 1 minute') g4 \gset
select pg_temp.ck('…one still open at the summary time is folded into it («Bot da controllare» lists it)',
  :g4 = 1 and (select status || '|' || error from fabula.notify_deliveries where outbox_id = :'h2' and staff_id = :'tit_staff') = 'skipped|nel riepilogo'
  and (select text_html from fabula.notify_outbox where topic = 'digest' order by created_at desc limit 1) like '%<b>Bot da controllare</b>%T-Vendite: non è partito%',
  (select status || '|' || coalesce(error, '') from fabula.notify_deliveries where outbox_id = :'h2' and staff_id = :'tit_staff'));

-- ============================== E-07 · the summary time in Configurazione ==============================
select pg_temp.as_user(:'tit');
set role authenticated;
select fabula.notify_set_prefs('{food_safety,decisions}', '22:00', '07:30', 'America/New_York', null, '07:15') p1 \gset
select fabula.notify_overview()->'me'->>'digest_at' p1d \gset
select pg_temp.err($q$select fabula.notify_set_prefs('{food_safety}', null, null, null, null, '25:99')$q$) e_p2 \gset
select fabula.notify_set_prefs('{food_safety}', null, null, null, null, null) p3 \gset
select fabula.notify_overview()->'me'->>'digest_at' p3d \gset
select fabula.notify_set_prefs('{food_safety}', null, null, null, null, '') p4 \gset
select coalesce(fabula.notify_overview()->'me'->>'digest_at', 'none') p4d \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('E-07 the summary time: set, kept when not given, switched off with an empty time; a wrong time is refused',
  :'p1d' = '07:15' and :'p3d' = '07:15' and :'p4d' = 'none' and :'e_p2' like 'Ora del riepilogo non valida%', :'p1d' || '/' || :'p3d' || '/' || :'p4d' || '/' || :'e_p2');

-- ============================== security ==============================
select pg_temp.ck('no new security findings', not exists (select 1 from fabula.security_findings() f where not exists (select 1 from fabula.security_accepted a where a.key = f.key)),
  (select string_agg(f.key, ', ') from fabula.security_findings() f where not exists (select 1 from fabula.security_accepted a where a.key = f.key)));
