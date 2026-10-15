-- v1.06 «Perché?»: the data behind every bot message · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh a_test
--   su postgres -c "psql -d a_test -f tools/go-live/drill/prod-test/test_v106_perche.sql" | grep -E "PASS|FAIL"
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as
$$ begin execute p_sql; return ''; exception when others then return sqlerrm; end $$;
create or replace function pg_temp.as_user(p_sub text) returns void language sql as
$$ select set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_sub), false) $$;
-- every text an explanation shows (labels, values, notes, titles)
create or replace function pg_temp.texts(p jsonb) returns text language sql as
$$ select coalesce(string_agg(x #>> '{}', ' ¦ '), '') from jsonb_path_query(p, 'lax $.**') x where jsonb_typeof(x) = 'string' $$;
insert into fabula.staff (id, full_name, role, app_role, active, auth_user_id) values
  ('10000000-0000-4000-a000-000000106a01', 'Titolare P', 'owner', 'titolare', true, '00000000-0000-4000-a000-000000106a01'),
  ('10000000-0000-4000-a000-000000106a02', 'Ufficio P', 'operaio', 'amministrazione', true, '00000000-0000-4000-a000-000000106a02'),
  ('10000000-0000-4000-a000-000000106a03', 'Marketing P', 'operaio', 'marketing', true, '00000000-0000-4000-a000-000000106a03'),
  ('10000000-0000-4000-a000-000000106a04', 'Casaro P', 'casaro', 'produzione', true, '00000000-0000-4000-a000-000000106a04')
on conflict do nothing;
\set tit '00000000-0000-4000-a000-000000106a01'
\set uff '00000000-0000-4000-a000-000000106a02'
\set mkt '00000000-0000-4000-a000-000000106a03'
\set cas '00000000-0000-4000-a000-000000106a04'
select (now() at time zone 'Europe/Rome')::date d \gset
select id moz from fabula.products where sku = 'MOZ-DOP-KG' \gset
update fabula.settings set value = 'https://app.example.it' where key = 'infra.site_url';
insert into fabula.settings (key, value) values ('infra.site_url', 'https://app.example.it') on conflict (key) do update set value = excluded.value;

-- ============================== keep_basis ==============================
select fabula.keep_basis('milk_planning', 'plan_milk', '{"date":"2026-10-16","milk_kg":900}'::jsonb)::text kb \gset
select pg_temp.ck('keep_basis returns exactly the JSON it was given', :'kb'::jsonb = '{"date":"2026-10-16","milk_kg":900}'::jsonb, :'kb');
select pg_temp.ck('…and keeps one row, not yet linked to a message',
  (select count(*) from fabula.message_basis where agent = 'milk_planning' and call = 'plan_milk' and message_id is null and kept_by = 'bot') = 1);
select fabula.keep_basis('Milk Planning!', 'plan_milk', '{"a":1}'::jsonb)::text kb2 \gset
select pg_temp.ck('a wrong name keeps nothing but still hands the data back', :'kb2' = '{"a": 1}' and not exists (select 1 from fabula.message_basis where agent like 'Milk%'));
select pg_temp.as_user(:'tit');
set role authenticated;
select pg_temp.err($$select fabula.keep_basis('milk_planning', 'plan_milk', '{}'::jsonb)$$) kb_login \gset
select pg_temp.err($$select count(*) from fabula.message_basis$$) mb_login \gset
reset role;
select pg_temp.ck('a login cannot keep data nor read the table, not even the owner', :'kb_login' like 'permission denied%' and :'mb_login' like 'permission denied%', :'kb_login' || ' / ' || :'mb_login');

-- ============================== post_bot_message links it ==============================
select fabula.keep_basis('sales', 'x_other', '{"count":2}'::jsonb) is not null o1 \gset
insert into fabula.message_basis (agent, call, data, kept_at) values ('milk_planning', 'plan_milk', '{"old":true}', now() - interval '61 minutes');
select fabula.post_bot_message('milk_planning', 'warn', 'Approva il latte di ven 16/10: 900 kg (€ 1.440)',
  E'**Da fare**\n1. Approva entro ore 06:00\n\n**In breve**\n- 950 kg di domanda\n\nEN — approve') m1 \gset
select pg_temp.ck('the message gets this agent''s fresh read: its basis_at is set and v_bot_feed says has_basis',
  (select message_id from fabula.message_basis where agent = 'milk_planning' and data = '{"date":"2026-10-16","milk_kg":900}') = :m1
  and (select basis_at is not null from fabula.bot_messages where id = :m1) and (select has_basis from fabula.v_bot_feed where id = :m1));
select pg_temp.ck('…never another bot''s read, nor one older than an hour',
  (select message_id is null from fabula.message_basis where agent = 'sales') and (select message_id is null from fabula.message_basis where data = '{"old":true}'));
select fabula.post_bot_message('milk_planning', 'info', 'Piano già creato', 'x') m2 \gset
select pg_temp.ck('a read is used once: the next message of the same bot has none', (select basis_at is null from fabula.bot_messages where id = :m2)
  and (select count(*) from fabula.message_basis where message_id = :m1) = 1);
select fabula.post_bot_message('procurement', 'info', 'Nessun ordine', 'x') m3 \gset
select pg_temp.ck('a bot on the old prompt (no keep_basis) posts as before, without «Perché?»',
  (select basis_at is null and basis_check is null from fabula.bot_messages where id = :m3) and not (select has_basis from fabula.v_bot_feed where id = :m3));

-- ============================== the number check ==============================
select basis_check::text c1 from fabula.bot_messages where id = :m1 \gset
select pg_temp.ck('number check: «900 kg», «€ 1.440» (the data''s 900 and nothing for 1440 here) — the invented «950» is reported, the EN line, «ore 06:00» and the list number are not',
  (:'c1'::jsonb -> 'missing') @> '["950"]' and (:'c1'::jsonb -> 'missing') @> '["1.440"]' and not ((:'c1'::jsonb -> 'missing') @> '["1"]')
  and not ((:'c1'::jsonb -> 'missing') @> '["06"]') and (:'c1'::jsonb ->> 'dates_found')::int = 1, :'c1');
select pg_temp.ck('reading Italian and database numbers: «1.200» = 1200 or 1,2 · «€ 2040.00» · «20,5 %» · «1,200» · years, times, codes and «CCP 3» left out',
  (select array_agg(tok order by tok) from fabula._basis_tokens(E'1.200 kg · € 2040.00 · 20,5 % · 1,200 · ore 06:00 · gio 15/10 · 2026 · L20261015-A · CF-01 · CCP 3 · CCP 1b · 4 settimane · (invariato dal 12/10)\nEN — 777\n> bozza 888'))
  = array['1,200', '1.200', '15/10', '20,5 %', '2040.00'],
  (select string_agg(tok, ' | ') from fabula._basis_tokens(E'1.200 kg · € 2040.00 · 20,5 % · 1,200 · ore 06:00 · gio 15/10 · 2026 · L20261015-A · CF-01 · CCP 3 · CCP 1b · 4 settimane · (invariato dal 12/10)\nEN — 777\n> bozza 888')));
select fabula.keep_basis('sell_down', 'sell_down_signals', '{"date":"2026-10-15","lots":[{"lot":"L1","at_risk_kg":12.4,"on_hand_kg":30,"expiry":"2026-10-16"}],"totals":{"at_risk_kg":12.4,"proposals_created":1,"value_retail_eur":186.0},"promo_pct":30,"notes":"giacenza 2.500 kg in cella"}'::jsonb) is not null o2 \gset
select fabula.post_bot_message('sell_down', 'warn', 'Approva la promo: 12 kg del lotto L1',
  E'**In breve**\n- A rischio ≈ 12,4 kg (€ 186), scade ven 16/10\n- Sconto 30 %\n- In cella 2.500 kg\n\nEN — approve the promo') m4 \gset
select basis_check::text c4 from fabula.bot_messages where id = :m4 \gset
select pg_temp.ck('a message whose numbers are all in the data (also rounded «12 kg», and the «2.500» written inside a text of the data) has nothing missing',
  (:'c4'::jsonb -> 'missing') = '[]'::jsonb and (:'c4'::jsonb ->> 'numbers')::int >= 4, :'c4');

-- ============================== the number check on normal bot sentences ==============================
select fabula.keep_basis('haccp_nudge', 'haccp_evening_status', '{"date":"2026-10-15","count":3,"missing":[{"code":"cold:CCP-COLD-1","label_it":"Temperatura serale CF-01"},{"code":"clean"},{"code":"kwh"}],"changes":{"sales_pct":-12},"kg":12.4}'::jsonb) is not null o4 \gset
select fabula.post_bot_message('haccp_nudge', 'warn', 'Prima di chiudere: 3 cose da registrare',
  E'**Da fare**\n1. Registra la temperatura della cella frigo 1 (CF-01) alle 6\n\n**In breve**\n- Vendite −12 %\n- Giacenza 12 kg\n\nEN — 3 records') m4b \gset
select pg_temp.ck('normal sentences: «cella frigo 1 (CF-01)», «alle 6», a count of the list («3 cose») and a signed «−12 %» are not reported',
  (select basis_check -> 'missing' from fabula.bot_messages where id = :m4b) = '[]'::jsonb, (select basis_check::text from fabula.bot_messages where id = :m4b));
select fabula.keep_basis('haccp_nudge', 'haccp_evening_status', '{"date":"2026-10-15","changes":{"sales_pct":-12},"kg":7.4}'::jsonb) is not null o5 \gset
select fabula.post_bot_message('haccp_nudge', 'warn', 'Prova', E'- Vendite +12 %\n- Giacenza 8 kg') m4c \gset
select pg_temp.ck('…but a wrong sign («+12 %» for −12) and a wrong rounding («8 kg» for 7,4) are',
  (select basis_check -> 'missing' from fabula.bot_messages where id = :m4c) = '["+12 %", "8"]'::jsonb, (select basis_check::text from fabula.bot_messages where id = :m4c));

-- ============================== the stand-in, «Esegui ora», a run that stopped ==============================
insert into fabula.parties (type, legal_name, is_milk_supplier) values ('supplier', 'Masseria P', true) returning id sup \gset
-- a bot run that read and stopped before writing: the database's stand-in does not take that read
select fabula.keep_basis('milk_planning', 'plan_milk', '{"date":"2026-10-16","milk_kg":777}'::jsonb) is not null stale \gset
select pg_temp.as_user(:'tit');
select fabula.run_bot_fallback('milk_planning', true)::text rn \gset
select set_config('request.jwt.claims', '', false) is not null nojwt \gset
select (:'rn'::jsonb ->> 'message_id')::bigint m5 \gset
select pg_temp.ck('«Esegui ora» (the database''s stand-in): its message has only the plan the database computed, not the read of the bot run that stopped',
  (select count(*) from fabula.message_basis where message_id = :m5 and call = 'plan_milk' and kept_by = 'database' and data ? 'milk_kg') = 1
  and not exists (select 1 from fabula.message_basis where message_id = :m5 and kept_by = 'bot'), :'rn');
select pg_temp.ck('…and no number check (the database''s own text)', (select basis_check is null from fabula.bot_messages where id = :m5));
select fabula.post_bot_message('milk_planning', 'info', 'Piano già creato', 'x') m5b \gset
select pg_temp.ck('…and the old read is not taken by the bot''s next message either (it is older than the last message)',
  (select basis_at is null from fabula.bot_messages where id = :m5b) and (select message_id is null from fabula.message_basis where data = '{"date":"2026-10-16","milk_kg":777}'));
-- a normal bot run: the read, the run logged (the database writes a short message), then the bot's message replaces it, with the data
select fabula.keep_basis('compliance_calendar', 'compliance_calendar', '{"date":"2026-10-15","counts":{"overdue":0,"due_30":0}}'::jsonb) is not null o6 \gset
insert into fabula.agent_runs (agent, finished_at, status, summary) values ('compliance_calendar', now(), 'ok', 'nessuna scadenza');
select coalesce((select id from fabula.bot_messages where agent = 'compliance_calendar' and source = 'auto' order by id desc limit 1), -1) m6a \gset
select fabula.post_bot_message('compliance_calendar', 'info', 'Nessuna scadenza', 'Niente in scadenza') m6 \gset
select pg_temp.ck('a normal run: the bot''s message replaces the run''s short message and carries the read',
  :m6 = :m6a and (select source = 'bot' and basis_at is not null from fabula.bot_messages where id = :m6)
  and exists (select 1 from fabula.message_basis where message_id = :m6 and call = 'compliance_calendar'), format('%s / %s', :'m6a', :'m6'));
-- phones and e-mails are never kept
select fabula.keep_basis('wholesale_orders', 'confirm_standing_orders', '{"customers":[{"customer":"Pizzeria P","phone":"+39 333 1234567","email":"p@x.it"}],"lab_request_draft":{"to":"lab@x.it","lab":"Lab"}}'::jsonb)::text kw \gset
select pg_temp.ck('the bot still gets the phone, but the copy kept has no phone and no e-mail',
  :'kw' like '%333 1234567%' and (select data::text from fabula.message_basis where agent = 'wholesale_orders' order by id desc limit 1) !~ '333|@',
  (select data::text from fabula.message_basis where agent = 'wholesale_orders' order by id desc limit 1));

-- ============================== the database's own messages ==============================
-- a lot closed without its CCP: which points, which value, the limit
insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, source) values (current_date, 'LP-1', :'moz', 500, 'milk', now(), 'tablet');
select fabula.log_ccp(p_cp_code => 'CCP-PAST', p_value => 72.5, p_staff_id => '10000000-0000-4000-a000-000000106a04', p_batch_lot => 'LP-1') is not null lc \gset
update fabula.production_batches set output_kg = 150, finished_at = now() where batch_lot = 'LP-1';
select id m7 from fabula.bot_messages where agent = 'sicurezza' and title like 'Lotto LP-1 chiuso senza%' order by id desc limit 1 \gset
select fabula.message_why(:m7)::text w7 \gset
select pg_temp.ck('a lot closed without CCP 3: «Perché?» lists both points, the value recorded for CCP 2 and «mancante» for CCP 3, and the lot held',
  :'w7'::jsonb #>> '{parts,0,title}' = 'Perché il lotto LP-1 è bloccato' and pg_temp.texts(:'w7'::jsonb) like '%72,5%' and pg_temp.texts(:'w7'::jsonb) like '%⚠ mancante%'
  and pg_temp.texts(:'w7'::jsonb) like '%bloccato%', left(pg_temp.texts(:'w7'::jsonb), 400));
-- milk not worked for 48 hours (the evening watch)
insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source)
values (:'d'::date - 3, '07:00', :'sup', 'MP106-OLD', 500, true, 4, 'tablet');
select fabula.prod_watch(((:'d'::date + time '19:10') at time zone 'Europe/Rome')) is not null pw \gset
select id m8 from fabula.bot_messages where agent = 'sicurezza' and title like '%latte vicino alle 60 ore' order by id desc limit 1 \gset
select fabula.message_why(:m8)::text w8 \gset
select pg_temp.ck('milk close to 60 hours: the lot, the kg left, how many hours ago, and the DOP rule',
  pg_temp.texts(:'w8'::jsonb) like '%MP106-OLD%' and pg_temp.texts(:'w8'::jsonb) like '%500 kg da lavorare%' and pg_temp.texts(:'w8'::jsonb) like '%60 ore dalla mungitura%',
  left(pg_temp.texts(:'w8'::jsonb), 400));
-- milk rejected
select id mi from fabula.milk_intake where milk_lot = 'MP106-OLD' \gset
select fabula.milk_reject(:'mi', 'antibiotici positivi') is not null mr \gset
select id m9 from fabula.bot_messages where agent = 'sicurezza' and title like 'Latte MP106-OLD respinto%' order by id desc limit 1 \gset
select fabula.message_why(:m9)::text w9 \gset
select pg_temp.ck('milk rejected: the reason, the kg, the delivery', pg_temp.texts(:'w9'::jsonb) like '%antibiotici positivi%' and pg_temp.texts(:'w9'::jsonb) like '%500 kg%', left(pg_temp.texts(:'w9'::jsonb), 300));
-- an auto-approval: the rule
insert into fabula.approvals (kind, requested_by, summary, payload, expires_at) values
 ('price_change', 'agent:sell_down', 'Promo P-OK', '{"type":"sell_down","action":"promo_banco","promo_pct":30,"at_risk_kg":12,"lot":"LP-9","promo_price_eur_kg":10.5}', now() + interval '8 hours');
select fabula.auto_approve_due(now() + interval '61 minutes') is not null aa \gset
select id m10 from fabula.bot_messages where agent = 'auto_approve' and title like '%Promo P-OK%' order by id desc limit 1 \gset
select fabula.message_why(:m10)::text w10 \gset
select pg_temp.ck('approved by itself: the rule, the request and the promo''s numbers',
  :'w10'::jsonb #>> '{parts,0,title}' = 'Perché si è approvato da solo' and pg_temp.texts(:'w10'::jsonb) like '%promo standard al banco%'
  and pg_temp.texts(:'w10'::jsonb) like '%LP-9%' and pg_temp.texts(:'w10'::jsonb) like '%€ 10,50 al kg%', left(pg_temp.texts(:'w10'::jsonb), 400));

-- ============================== Telegram ==============================
select pg_temp.ck('Telegram: the alarm with data carries «perché» next to «apri», to the Console',
  exists (select 1 from fabula.notify_outbox where source = 'bot_messages' and source_ref = :'m7' and text_html like '%/console.html#oggi&perche=' || :m7 || '">perché</a>'),
  (select right(text_html, 160) from fabula.notify_outbox where source = 'bot_messages' and source_ref = :'m7' limit 1));
select fabula.post_bot_message('ops_health', 'alert', 'Backup non riuscito', 'x') m11 \gset
select pg_temp.ck('…an alarm without data has no «perché»',
  not exists (select 1 from fabula.notify_outbox where source = 'bot_messages' and source_ref = :'m11' and text_html like '%perche=%'));

-- ============================== who sees what ==============================
select pg_temp.as_user(:'mkt');
set role authenticated;
select pg_temp.err(format('select fabula.message_why(%s)', :m7)) why_mkt \gset
select pg_temp.err(format('select fabula.message_why(%s)', :m4)) why_mkt4 \gset
reset role;
select pg_temp.ck('a marketing profile cannot open a food-safety message''s «Perché?» (no HACCP), but opens the promo''s (sales, its area)',
  :'why_mkt' = 'Il tuo profilo non vede questo messaggio' and :'why_mkt4' = '', :'why_mkt' || ' / ' || :'why_mkt4');
select fabula.keep_basis('daily_brief', 'daily_brief', '{"date":"2026-10-14","sales_trend":{"yesterday_eur":540}}'::jsonb) is not null o7 \gset
select fabula.post_bot_message('daily_brief', 'info', 'Ieri € 540', 'x') m13 \gset
select pg_temp.as_user(:'mkt');
set role authenticated;
select pg_temp.err(format('select fabula.message_why(%s)', :m13)) why_brief \gset
reset role;
select pg_temp.ck('the briefs (area «comune», which every login has) open only for the feed''s readers: sales and costs stay in the office',
  :'why_brief' = 'Il tuo profilo non vede questo messaggio', :'why_brief');
select pg_temp.as_user(:'cas');
set role authenticated;
select fabula.message_why(:m7)::text w7c \gset
select fabula.my_alarms()::text al_cas \gset
reset role;
select pg_temp.ck('the cheesemaker (production / HACCP) opens it, without raw data and without the number check',
  (:'w7c'::jsonb -> 'parts' -> 0 ->> 'title') = 'Perché il lotto LP-1 è bloccato' and (:'w7c'::jsonb ->> 'raw') is null and (:'w7c'::jsonb ->> 'check') is null, left(:'w7c', 200));
select pg_temp.ck('my_alarms says which alarms have a «Perché?»', :'al_cas'::jsonb @> jsonb_build_array(jsonb_build_object('id', :m7, 'has_basis', true)), left(:'al_cas', 300));
select pg_temp.as_user(:'tit');
set role authenticated;
select fabula.message_why(:m1)::text w1t \gset
select fabula.message_why(:m3)::text w3t \gset
reset role;
select pg_temp.ck('the owner (Sistema «gestisce») sees the raw data and the number check, with the invented number',
  (:'w1t'::jsonb -> 'raw' -> 0 ->> 'call') = 'plan_milk' and (:'w1t'::jsonb #>> '{check,line_it}') like '⚠ Nel messaggio ci sono numeri che non si trovano nei dati letti: %950%', :'w1t'::jsonb #>> '{check,line_it}');
select pg_temp.ck('a message without data says why there is none', (:'w3t'::jsonb ->> 'none_it') like 'Questo messaggio non ha i dati salvati%');
update fabula.settings set value = '1' where key = 'bots.number_check_all';
select pg_temp.as_user(:'cas');
set role authenticated;
select fabula.message_why(:m1)::text w1c \gset
reset role;
update fabula.settings set value = '0' where key = 'bots.number_check_all';
select pg_temp.ck('with «Mostra a tutti il controllo dei numeri» = Sì, the cheesemaker sees the check too (milk plan = production area), still no raw data',
  (:'w1c'::jsonb #>> '{check,line_it}') like '⚠%950%' and (:'w1c'::jsonb ->> 'raw') is null, coalesce(:'w1c'::jsonb #>> '{check,line_it}', left(:'w1c', 200)));

-- ============================== every explainer on what the functions really return ==============================
select set_config('request.jwt.claims', '', false) is not null nojwt \gset
create temp table why_runs as
select call, fabula._why_explain(call, data, fabula._basis_extra(call, data)) w from (values
  ('plan_milk', fabula.plan_milk(:'d'::date + 5)),
  ('propose_purchase_orders', fabula.propose_purchase_orders()),
  ('sell_down_signals', fabula.sell_down_signals()),
  ('confirm_standing_orders', fabula.confirm_standing_orders()),
  ('haccp_evening_status', fabula.haccp_evening_status()),
  ('daily_brief', fabula.daily_brief()),
  ('weekly_brief', fabula.weekly_brief()),
  ('ops_health_check', fabula.ops_health_check()),
  ('infra_checks', fabula.infra_checks()),
  ('compliance_calendar', fabula.compliance_calendar()),
  ('monthly_review', fabula.monthly_review())) v(call, data);
select pg_temp.ck('every explainer runs on its function''s real result: a title, sections, nothing broken',
  (select count(*) from why_runs where w ->> 'title' is not null and jsonb_typeof(w -> 'sections') = 'array' and not (w ? 'broken')) = 11,
  (select string_agg(call || ': ' || coalesce(w ->> 'title', 'NO TITLE') || case when w ? 'broken' then ' BROKEN' else '' end, ' | ') from why_runs));
select pg_temp.ck('no explanation shows a raw key (snake_case), JSON or SQL (the system checks quote their own Italian details)',
  not exists (select 1 from why_runs where call not in ('infra_checks', 'ops_health_check') and (pg_temp.texts(w) ~ '\m[a-z]+_[a-z_]+\M' or pg_temp.texts(w) ~ '[{}]')),
  (select string_agg(call || ': ' || substring(pg_temp.texts(w) from '\m[a-z]+_[a-z_]+\M'), ' | ') from why_runs where pg_temp.texts(w) ~ '\m[a-z]+_[a-z_]+\M'));
-- the milk plan step by step (a plan with the farm short of milk and the minimum run)
select fabula._why_explain('plan_milk', '{"date":"2026-10-16","weekday":"venerdì","demand":{"retail_kg":112,"wholesale_kg":40,"wholesale_confirmed_kg":40,"preorder_kg":0,"history_source":"same_weekday_4w","history_days":4},
  "carry_kg":18,"carry_raw_kg":36,"carry_pct":50,"safety_kg":15,"planned_output_kg":149,"yield_pct":20.5,"yield_source":"avg_30d","milk_kg":900,"milk_unrounded_kg":727,
  "capacity_kg":1200,"capacity_hit":false,"min_kg":900,"min_run_applied":true,"farm":{"kg_available":1100,"exceeds_farm_supply":false,"shortfall_kg":0,"surplus_kg":200,"capped_to_farm":false},
  "price_eur_per_kg":1.6,"est_cost_eur":1440,"last_4w_same_weekday":{"milk_kg":880,"waste_kg":4},"est_whey_kg":558,"est_ricotta_kg":39,"auto_approve_at":"19:52","auto_rule":"piano latte nella norma"}'::jsonb, null)::text wm \gset
select pg_temp.ck('milk plan: «Perché 900 kg di latte per ven 16/10», the steps in order, the minimum run flagged, the cost and when it approves itself',
  :'wm'::jsonb ->> 'title' = 'Perché 900 kg di latte per ven 16/10'
  and (select array_agg(r ->> 'l') from jsonb_array_elements(:'wm'::jsonb #> '{sections,0,rows}') r)
      = array['Vendite al banco e online', 'Ingrosso', 'Giacenza fresca', 'Margine di sicurezza', 'Mozzarella da fare', 'Resa', 'Latte necessario', 'Lotto minimo', 'Masseria', 'Latte proposto', 'Costo stimato']
  and pg_temp.texts(:'wm'::jsonb) like '%900 kg × € 1,60/kg = € 1.440%' and pg_temp.texts(:'wm'::jsonb) like '%− 18 kg%'
  and (select r ->> 'f' from jsonb_array_elements(:'wm'::jsonb #> '{sections,0,rows}') r where r ->> 'l' = 'Lotto minimo') = 'ko'
  and pg_temp.texts(:'wm'::jsonb) like '%alle 19:52%', left(pg_temp.texts(:'wm'::jsonb), 600));
select pg_temp.ck('evening check: it never lists itself among the bots that did not start',
  pg_temp.texts(fabula._why_explain('ops_health_check', '{"bots":[{"agent":"ops_health","ran":false,"errors":0},{"agent":"milk_planning","ran":false,"errors":0},{"agent":"procurement","ran":true,"errors":0}],"bots_missing":["ops_health","milk_planning"],"bots_errors":0,"issues":0,"data_quality":[]}'::jsonb, null))
  ~ 'Perché una cosa da controllare ¦ Bot di oggi ¦ ko ¦ Piano latte ¦ non partito ¦ Bot regolari ¦ 1$',
  pg_temp.texts(fabula._why_explain('ops_health_check', '{"bots":[{"agent":"ops_health","ran":false,"errors":0},{"agent":"milk_planning","ran":false,"errors":0},{"agent":"procurement","ran":true,"errors":0}],"bots_missing":["ops_health","milk_planning"],"bots_errors":0,"issues":0,"data_quality":[]}'::jsonb, null)));
select pg_temp.ck('wholesale: never a customer''s phone',
  pg_temp.texts(fabula._why_explain('confirm_standing_orders', '{"date":"2026-10-16","booked":1,"total_kg":12,"customers":[{"customer":"Pizzeria P","phone":"+39 333 1234567","order_number":"WS-261016-01","lines":2,"total_eur":96,"message_it":"Buongiorno, chiamare 333 1234567"}],"under_minimum":[{"customer":"Bar Q","kg":2,"phone":"+39 333 7654321"}]}'::jsonb, null))
  !~ '333' , pg_temp.texts(fabula._why_explain('confirm_standing_orders', '{"customers":[{"customer":"Pizzeria P","phone":"+39 333 1234567"}]}'::jsonb, null)));
select pg_temp.ck('an unknown read shows only its labelled values, and says the rest is technical',
  pg_temp.texts(fabula._why_explain('x_unknown', '{"count":3,"secret_key":"abc","date":"2026-10-15"}'::jsonb, null)) like '%Quanti ¦ 3%'
  and pg_temp.texts(fabula._why_explain('x_unknown', '{"count":3,"secret_key":"abc","date":"2026-10-15"}'::jsonb, null)) not like '%abc%'
  and pg_temp.texts(fabula._why_explain('x_unknown', '{"count":3,"secret_key":"abc","date":"2026-10-15"}'::jsonb, null)) like '%tecnici%',
  pg_temp.texts(fabula._why_explain('x_unknown', '{"count":3,"secret_key":"abc","date":"2026-10-15"}'::jsonb, null)));
select pg_temp.ck('a broken read never breaks «Perché?» (an explainer that fails falls back to the labelled values)',
  (fabula._why_explain('plan_milk', '"not an object"'::jsonb, null)) is not null and (fabula._why_explain('daily_brief', '[1,2]'::jsonb, null)) is not null);

-- ============================== size, clean-up, Sistema ==============================
update fabula.settings set value = '16' where key = 'bots.basis_max_kb';
select fabula.keep_basis('monthly_review', 'monthly_review', jsonb_build_object('blob', repeat('x', 20000))) is not null big \gset
update fabula.settings set value = '256' where key = 'bots.basis_max_kb';
select fabula.post_bot_message('monthly_review', 'info', 'Il mese', 'x') m12 \gset
select pg_temp.ck('a read over the limit keeps only that it was too big, and «Perché?» says so',
  (select too_big and data is null from fabula.message_basis where message_id = :m12) and pg_temp.texts(fabula.message_why(:m12)) like '%troppo grandi%');
insert into fabula.message_basis (agent, call, data, kept_at) values ('procurement', 'propose_purchase_orders', '{}', now() - interval '2 days');
update fabula.message_basis set kept_at = now() - interval '91 days' where message_id = :m12;
select fabula.basis_trim() trimmed \gset
select pg_temp.ck('clean-up: unused reads after a day, the others after «Giorni di conservazione» (90)', :trimmed = 2
  and not exists (select 1 from fabula.message_basis where message_id = :m12) and pg_temp.texts(fabula.message_why(:m12)) like '%non ci sono più%', :'trimmed');
select pg_temp.ck('the clean-up is one of the expected database jobs (24)',
  (select count(*) from fabula.cron_jobs_expected) = 24 and exists (select 1 from fabula.cron_jobs_expected where jobname = 'fabula_basis_trim'));
select pg_temp.as_user(:'tit');
set role authenticated;
select fabula.system_checks()::text sc \gset
reset role;
select pg_temp.ck('Configurazione → Panoramica → Sistema: «Numeri dei messaggi» counts the messages with numbers not in the data',
  (select x ->> 'detail' from jsonb_array_elements(:'sc'::jsonb) x where x ->> 'key' = 'number_check') ~ '^Ultimi 7 giorni: [0-9]+ su [0-9]+ messaggi dei bot hanno numeri che non sono nei dati letti \(.*Piano latte.*\)'
  and (select not (x ->> 'done')::boolean from jsonb_array_elements(:'sc'::jsonb) x where x ->> 'key' = 'number_check'),
  (select x ->> 'detail' from jsonb_array_elements(:'sc'::jsonb) x where x ->> 'key' = 'number_check'));
select pg_temp.ck('the expected prompt versions are the repo''s (the 9 prompts that keep their reads)',
  (select count(*) from fabula.bot_prompt_versions where agent in ('compliance_calendar', 'daily_brief', 'haccp_nudge', 'milk_planning', 'monthly_review', 'ops_health', 'procurement', 'sell_down', 'wholesale_orders')) = 9);
