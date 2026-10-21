-- v1.12 · the database stands in for every bot (R-02) · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh s_test
--   su postgres -c "psql -d s_test -f tools/go-live/drill/prod-test/test_v112_standins.sql" | grep -E "PASS|FAIL"
-- 1. the list, the timing of the automatic stand-in (fixed clock times, as test_bot_fallback) and «Esegui ora»;
-- 2. each stand-in on the real data functions (the replay: before the opening, seeded leads and campaign);
-- 3. the brief, sales and monthly messages on full data: the data functions are replaced in this test database by fixed JSON, so every
--    line of the message is checked (the real functions are tested in their own suites).
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
create or replace function pg_temp.as_user(p_sub text) returns void language sql as
$$ select set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_sub), false) $$;
insert into fabula.staff (id, full_name, role, app_role, active, auth_user_id) values
  ('10000000-0000-4000-a000-000000112a01', 'Titolare S', 'owner', 'titolare', true, '00000000-0000-4000-a000-000000112a01')
on conflict do nothing;
select (now() at time zone 'Europe/Rome')::date today \gset

-- ============================== 1. the list and the timing ==============================
select pg_temp.ck('every Claude bot has a database version (the 6 + backup of before, and the 5 that had none)',
  fabula.bot_fallback_agents() @> array['milk_planning', 'procurement', 'wholesale_orders', 'haccp_nudge', 'ops_health', 'sell_down', 'backup_export',
                                         'daily_brief', 'sales', 'marketing', 'compliance_calendar', 'monthly_review']
  and not exists (select 1 from fabula.bot_schedule where active and runner = 'claude' and not (agent = any (fabula.bot_fallback_agents()))),
  array_to_string(fabula.bot_fallback_agents(), ','));
-- The days go in calendar order, as in real life: a stand-in counts any later run of its bot as done.
-- Monday 19/10: brief 06:47, procurement 06:20, sell-down 07:23, marketing 07:53, sales 08:04 (+ 45 minutes each)
select fabula.bot_fallback('2026-10-19 08:55:00+02') r3 \gset
select pg_temp.ck('Mon 08:55: brief, procurement, sell-down, marketing (07:53 + 45) and sales (08:04 + 45)',
  (select array_agg(x->>'agent' order by x->>'agent') from jsonb_array_elements(:'r3'::jsonb->'runs') x) = array['daily_brief', 'marketing', 'procurement', 'sales', 'sell_down']
  and not exists (select 1 from jsonb_array_elements(:'r3'::jsonb->'runs') x where x->>'status' <> 'ok'), :'r3');
select pg_temp.ck('Monday''s brief carries the week (and keeps the weekly read too)',
  exists (select 1 from fabula.agent_runs where agent = 'daily_brief' and started_at = '2026-10-19 08:55:00+02' and summary like '%lun+sett: Sabato 17/10%')
  and exists (select 1 from fabula.message_basis where agent = 'daily_brief' and call = 'weekly_brief' and kept_by = 'database'),
  (select string_agg(summary, ' | ') from fabula.agent_runs where agent = 'daily_brief'));
-- Tuesday 20/10: brief 06:47, procurement 06:20, compliance calendar 07:17, sell-down 07:23
select fabula.bot_fallback('2026-10-20 07:40:00+02') r1 \gset
select pg_temp.ck('Tue 07:40: the brief (06:47 + 45) and procurement stand in; the calendar (07:17 + 45) not yet',
  (select array_agg(x->>'agent' order by x->>'agent') from jsonb_array_elements(:'r1'::jsonb->'runs') x) = array['daily_brief', 'procurement']
  and not exists (select 1 from jsonb_array_elements(:'r1'::jsonb->'runs') x where x->>'status' <> 'ok'), :'r1');
select pg_temp.ck('the brief''s stand-in: a run «Eseguito dal database» and its message «Sostituito dal database»',
  exists (select 1 from fabula.agent_runs ar join fabula.bot_messages bm on bm.run_id = ar.id
           where ar.agent = 'daily_brief' and ar.started_at = '2026-10-20 07:40:00+02' and ar.details->>'via' = 'db_fallback' and ar.status = 'ok'
             and ar.summary = 'Eseguito dal database (bot non partito): Ieri tutto in ordine'
             and bm.title = 'Sostituito dal database · Ieri tutto in ordine' and bm.body like 'Il bot "% delle 06:47 non ha fatto il suo lavoro%'),
  (select string_agg(title, ' | ') from fabula.bot_messages where agent = 'daily_brief'));
select pg_temp.ck('its reads are kept for «Perché?», by the database (no number check on its words)',
  exists (select 1 from fabula.message_basis mb join fabula.bot_messages bm on bm.id = mb.message_id
           where bm.agent = 'daily_brief' and mb.call = 'daily_brief' and mb.kept_by = 'database')
  and (select bool_and(basis_check is null) from fabula.bot_messages where agent = 'daily_brief'));
select fabula.bot_fallback('2026-10-20 08:10:00+02') r2 \gset
select pg_temp.ck('Tue 08:10: the calendar and sell-down; the brief is not repeated',
  (select array_agg(x->>'agent' order by x->>'agent') from jsonb_array_elements(:'r2'::jsonb->'runs') x) = array['compliance_calendar', 'sell_down'], :'r2');
-- Sunday 01/11: only the monthly review (every day of the week, on the 1st)
select count(*) drills0 from fabula.recall_drills \gset
select fabula.bot_fallback('2026-11-01 08:30:00+01') r4 \gset
select pg_temp.ck('Sun 01/11 08:30: the monthly review (07:41 + 45) and nothing else',
  (select array_agg(x->>'agent') from jsonb_array_elements(:'r4'::jsonb->'runs') x) = array['monthly_review'], :'r4');
select pg_temp.ck('the monthly stand-in runs the month''s review (no lot sold in the replay: the drill says so, nothing recorded)',
  exists (select 1 from fabula.agent_runs where agent = 'monthly_review' and details->>'via' = 'db_fallback' and summary like '%: richiamo no_lots, NC critiche 0, 0 proposte ricetta, costo n/d')
  and (select count(*) from fabula.recall_drills) = :drills0,
  (select string_agg(summary, ' | ') from fabula.agent_runs where agent = 'monthly_review'));
select pg_temp.ck('the alarm waits 20 more minutes for a covered bot: brief due 06:47 not reported at 07:45 on a day with no run',
  not exists (select 1 from jsonb_array_elements((fabula.bot_watchdog('2026-10-22 07:45:00+02'))->'alerts') x where x->>'agent' = 'daily_brief'));
select pg_temp.ck('…and reported at 07:55 if the stand-in did not run either',
  exists (select 1 from jsonb_array_elements((fabula.bot_watchdog('2026-10-22 07:55:00+02'))->'alerts') x where x->>'agent' = 'daily_brief' and x->>'kind' = 'missed'));
-- «Esegui ora (versione del database)»
select pg_temp.as_user('00000000-0000-4000-a000-000000112a01');
set role authenticated;
select fabula.run_bot_fallback('compliance_calendar') x1 \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('«Esegui ora» works for the calendar: a manual run by the titolare, one message «Eseguito ora»',
  exists (select 1 from fabula.agent_runs where agent = 'compliance_calendar' and details->>'manual' = 'true' and details->>'by' = 'Titolare S')
  and exists (select 1 from fabula.bot_messages where id = (:'x1'::jsonb->>'message_id')::bigint and title like 'Eseguito ora · %'), :'x1');

-- ============================== 2. on the real data functions ==============================
select fabula.bot_fallback_run('daily_brief', '2026-10-20') b0 \gset
select pg_temp.ck('brief before the start: «Ieri tutto in ordine», info, says nothing was made or sold and why no HACCP asks',
  :'b0'::jsonb->>'title' = 'Ieri tutto in ordine' and :'b0'::jsonb->>'severity' = 'info'
  and :'b0'::jsonb->>'body' like E'In breve:\n• Ieri nessuna produzione né vendita · Prima dell''avvio (%) i controlli HACCP del giorno non sono richiesti', :'b0'::jsonb->>'body');
select fabula.bot_fallback_run('sales', :'today') s0 \gset
select pg_temp.ck('sales: the overdue contacts (first 6, with phone and delay), the plan line, the pipeline; warn',
  :'s0'::jsonb->>'title' like '15 locali da contattare (15 in ritardo)' and :'s0'::jsonb->>'severity' = 'warn'
  and :'s0'::jsonb->>'body' like E'Da contattare (i primi 6 di 15):\n• GM Pizzeria di Gianfranco Marotta (pizzeria, Agropoli, +39 0974 826380) · Primo contatto%di ritardo\n%'
  and :'s0'::jsonb->>'body' like '%• Obiettivi dal lun 01/02 · vendite del mese € 0%• Locali aperti: 45 (nuovo 45)%Senza il bot mancano i messaggi pronti da mandare e la ricerca di nuovi locali.',
  :'s0'::jsonb->>'title');
select pg_temp.ck('sales writes nothing (the leads are not linked or changed)', (select count(*) from fabula.sales_leads where stage <> 'nuovo') = 0);
update fabula.mkt_local_items set status = 'preventivo', quote_eur = 380, vendor = 'Grafiche Test' where code = 'SIG-02';
select count(*) appr0 from fabula.approvals \gset
select fabula.bot_fallback_run('marketing', :'today') k0 \gset
select pg_temp.ck('marketing does the bot''s one write: the quote in hand goes to the console (one approval) and the title says so',
  (select status from fabula.mkt_local_items where code = 'SIG-02') = 'in_approvazione' and (select count(*) from fabula.approvals) = :appr0 + 1
  and :'k0'::jsonb->>'title' = '1 preventivo arrivato da decidere' and :'k0'::jsonb->>'severity' = 'warn'
  and :'k0'::jsonb->>'body' like '%• Decidi i preventivi arrivati (Console → Da approvare): Vetrofanie%(€ 380)%'
  and :'k0'::jsonb->>'body' not like '%In attesa di decisione%', :'k0'::jsonb->>'body');
select fabula.bot_fallback_run('marketing', :'today') k1 \gset
select pg_temp.ck('next time it waits in «In attesa di decisione» and nothing more is moved',
  :'k1'::jsonb->>'body' like '%• In attesa di decisione: 1, € 380 (Console → Da approvare)%' and (select count(*) from fabula.approvals) = :appr0 + 1
  and :'k1'::jsonb->>'body' like '%• Permessi da chiedere: 6, il primo serve entro ven 01/01%• Apertura lun 15/02, tra %• Budget della campagna € %Senza il bot mancano le richieste di preventivo%',
  :'k1'::jsonb->>'body');
update fabula.equipment set last_calibrated_on = :'today'::date - 375, technician_contact = 'Tecnico Test 333 1234567' where code = 'PAST-01';
update fabula.equipment set last_calibrated_on = :'today'::date - 1075 where code = 'BIL-01';
select fabula.bot_fallback_run('compliance_calendar', :'today') c0 \gset
select pg_temp.ck('calendar: the overdue calibration with its contact, the one within 30 days, the missing dates by kind, the technician message',
  :'c0'::jsonb->>'title' = 'Scadenza superata: Pastorizzatore' and :'c0'::jsonb->>'severity' = 'warn'
  and :'c0'::jsonb->>'body' like E'Da fare:\nScadute:\n• Taratura Pastorizzatore (PAST-01) · era il %, 10 giorni fa · Tecnico Test 333 1234567%'
  and :'c0'::jsonb->>'body' like E'%Entro 30 giorni:\n• Taratura Bilancia ricezione (BIL-01) · entro il % (tra 20 giorni)%'
  and :'c0'::jsonb->>'body' like '%• Senza data: % tarature, % manutenzioni, % verifiche%. Il calendario non può avvisare finché mancano%'
  and :'c0'::jsonb->>'body' like E'%Messaggi pronti:\nPer Pastorizzatore (PAST-01), Tecnico Test 333 1234567:\n> Buongiorno, per % dovremmo programmare la taratura di Pastorizzatore%',
  :'c0'::jsonb->>'body');
update fabula.equipment set out_of_service = true where code = 'BIL-02';
select pg_temp.ck('an instrument out of service comes first, as an alert',
  (select o->>'title' = '⚠ Strumenti fuori servizio: 1' and o->>'severity' = 'alert' and o->>'body' like E'Da fare:\n⚠ Strumenti fuori servizio, non usarli: % (BIL-02)%'
     from (select fabula.bot_fallback_run('compliance_calendar', :'today') o) q));
update fabula.equipment set out_of_service = false where code = 'BIL-02';
select fabula.bot_fallback_run('monthly_review', :'today') m0 \gset
select pg_temp.ck('monthly review on an empty month: «<Mese> chiuso», one line instead of zeros, the drill verdict, the package step',
  :'m0'::jsonb->>'title' like '% chiuso' and :'m0'::jsonb->>'title' not like '%September%' and :'m0'::jsonb->>'severity' = 'info'
  and :'m0'::jsonb->>'body' like E'Da fare:\n• Pacchetto per il commercialista: Console → Pacchetto mensile → Stampa/PDF\n\nIn breve:\n• Mese senza produzione, consegne né vendite\n• Prova di richiamo: nessun lotto venduto, prova non eseguita\n• Sicurezza alimentare: %'
  and :'m0'::jsonb->>'body' not like '%Pacchetto: ricavi%', :'m0'::jsonb->>'body');

-- ============================== 3. full data (fixed JSON in place of the data functions) ==============================
create or replace function fabula.daily_brief(p_date date default null) returns jsonb language sql stable as $f$
  select b || case when current_setting('t112.v', true) in ('nonc', 'checks', 'calm')
                   then jsonb_build_object('haccp', (b->'haccp') || '{"non_conformities": []}'::jsonb) else '{}'::jsonb end
           || case when current_setting('t112.v', true) in ('checks', 'calm') then '{"pending_approvals": []}'::jsonb else '{}'::jsonb end
           || case when current_setting('t112.v', true) = 'calm'
                   then '{"haccp": {"missing_daily_checks": [], "evening_cold_checks_missing": [], "non_conformities": []}, "stock_finished": []}'::jsonb else '{}'::jsonb end
  from (select jsonb_build_object('date', p_date,
    'production', '[{"product": "Mozzarella di Bufala Campana DOP", "batches": 2, "milk_in_kg": 620, "output_kg": 152.5, "yield_pct": 24.6}]'::jsonb,
    'milk', '[{"lot": "M1", "kg": 620, "accepted": true}, {"lot": "M2", "kg": 300, "accepted": false}]'::jsonb,
    'sales_trend', '{"yesterday_eur": 2040, "same_weekday_avg_4w_eur": 1800, "week_to_date_eur": 2040}'::jsonb,
    'changes', '{"sales_vs_same_weekday_pct": 13, "yield_vs_30d_points": -2.1, "energy_kwh_per_kg_vs_30d_pct": 22}'::jsonb,
    'energy', '{"yesterday_kwh_per_kg": 1.25}'::jsonb, 'waste', '{"last_7d_kg": 30, "last_7d_pct_of_output": 12.5}'::jsonb,
    'pos_close', '{"variance_eur": -3.5}'::jsonb,
    'haccp', '{"missing_daily_checks": ["CCP-COLD-1", "PRP-CLEAN"], "evening_cold_checks_missing": ["CCP-COLD-1", "CCP-COLD-2"],
               "non_conformities": [{"point": "CCP-STRETCH", "value": 55, "action": "lotto bloccato"}]}'::jsonb,
    'stock_finished', jsonb_build_array(jsonb_build_object('sku', 'MOZ-DOP-KG', 'lot', 'L1', 'kg', 12.5, 'expires', p_date + 2),
                                        jsonb_build_object('sku', 'MOZ-DOP-KG', 'lot', 'L2', 'kg', 40, 'expires', p_date + 10)),
    'procurement_signals', '[{"sku": "X"}]'::jsonb,
    'tasks', '{"overdue": [{"code": "T1"}, {"code": "T2"}], "calibration_due": [{"code": "TERM-01"}], "training_expiring": []}'::jsonb,
    'pending_approvals', '[{"summary": "Ordine PO-1 € 120", "requested_by": "agent:procurement", "age_days": 4},
                           {"summary": "Piano latte mer 21/10: 1.200 kg", "requested_by": "agent:milk_planning", "age_days": 0},
                           {"summary": "A", "requested_by": "x", "age_days": 1}, {"summary": "B", "requested_by": null, "age_days": 2}]'::jsonb) b) q
$f$;
create or replace function fabula.weekly_brief(p_week_end date default null) returns jsonb language sql stable as $f$
  select '{"week_start": "2026-10-12", "week_end": "2026-10-17",
           "this_week": {"production": {"batches": 8, "milk_processed_kg": 2480, "mozzarella_kg": 600, "ricotta_kg": 40, "yield_pct": 24.2},
                         "sales": {"revenue_eur": 1200, "mozzarella_sold_kg": 80}, "waste": {"mozzarella_kg": 66, "pct_of_mozzarella_output": 11}},
           "changes": {"sales": {"revenue_eur": -8}},
           "pnl_estimate": {"operating_result_eur": 216, "revenue_eur": 1200, "benchmark_weekly_profit_eur": 2890.38, "margin_pct": 18}}'::jsonb
$f$;
select set_config('t112.v', 'full', false);
select fabula.bot_fallback_run('daily_brief', '2026-10-20') f1 \gset
select pg_temp.ck('brief, full day: the non-conformity first, as an alert, in plain words',
  :'f1'::jsonb->>'title' = '⚠ Non conformità HACCP di ieri: vedi Autocontrollo' and :'f1'::jsonb->>'severity' = 'alert'
  and :'f1'::jsonb->>'body' like E'⚠ Non conformità Filatura: temperatura della pasta di ieri: 55 · lotto bloccato\n\nDa fare:\n%', :'f1'::jsonb->>'body');
select pg_temp.ck('brief: requests waiting, the milk plan first, three then «e altre», where to click',
  :'f1'::jsonb->>'body' like E'%Da fare:\n• Decidi: Piano latte mer 21/10: 1.200 kg\n• Decidi: Ordine PO-1 € 120 (in attesa da 4 giorni)\n• Decidi: B (in attesa da 2 giorni)\n• … e altre 1\n  Dove: Console → Da approvare\n%');
select pg_temp.ck('brief: the missing records by name, the evening reading only where the day''s one exists, expiring stock, low stock',
  :'f1'::jsonb->>'body' like E'%• Registra sul tablet i controlli di ieri che mancano: Cella frigo 1, Sanificazione fine turno\n• Manca la lettura serale di ieri: Cella frigo 2\n• Spingi al banco: Mozzarella di Bufala Campana DOP lotto L1, 12,5 kg (scade mer 21/10)\n• Scorte: 1 materiale sotto la soglia%');
select pg_temp.ck('brief: production with yield and milk, sales vs 4 weeks, till difference, waste, energy, tasks, calibrations',
  :'f1'::jsonb->>'body' like E'%In breve:\n• Produzione di ieri: Mozzarella di Bufala Campana DOP 152,5 kg (resa 24,6 %) · latte ricevuto 620 kg, 1 consegna rifiutata · resa sotto la media di 30 giorni di 2,1 punti\n• Vendite di ieri € 2.040 (+13 % sullo stesso giorno delle 4 settimane prima) · settimana € 2.040\n• Chiusura di cassa: differenza di € -3,50\n• Scarti degli ultimi 7 giorni: 30 kg, 12,5 % della produzione\n• Energia: 1,25 kWh per kg, 22 % sopra la media di 30 giorni\n• 2 attività scadute · elenco sul tablet\n• Tarature entro 14 giorni: 1 (Autocontrollo → Strumenti)'
  and :'f1'::jsonb->>'body' not like '%nessuna produzione%', :'f1'::jsonb->>'body');
select set_config('t112.v', 'nonc', false);
select pg_temp.ck('brief: without the NC the milk plan leads (alert)',
  (select o->>'title' = 'Approva il piano latte (Console → Da approvare)' and o->>'severity' = 'alert' from (select fabula.bot_fallback_run('daily_brief', '2026-10-20') o) q));
select set_config('t112.v', 'checks', false);
select pg_temp.ck('brief: then the missing records (alert on a production day)',
  (select o->>'title' = 'Registra i controlli HACCP di ieri (3 mancanti)' and o->>'severity' = 'alert' from (select fabula.bot_fallback_run('daily_brief', '2026-10-20') o) q));
select set_config('t112.v', 'calm', false);
select pg_temp.ck('brief: nothing to decide → «Ieri tutto in ordine», info',
  (select o->>'title' = 'Ieri tutto in ordine' and o->>'severity' = 'info' from (select fabula.bot_fallback_run('daily_brief', '2026-10-20') o) q));
select fabula.bot_fallback_run('daily_brief', '2026-10-19') f2 \gset
select pg_temp.ck('Monday: Saturday by date, and «La settimana» with result, sales vs the week before, production, waste',
  :'f2'::jsonb->>'title' = 'Sabato 17/10 tutto in ordine' and :'f2'::jsonb->>'summary' = 'lun+sett: Sabato 17/10 tutto in ordine'
  and :'f2'::jsonb->>'body' like E'%Produzione di sabato 17/10: %\n\nLa settimana (lun 12/10 – sab 17/10):\n• Risultato stimato € 216 su € 1.200 di ricavi; settimana di riferimento € 2.890, margine 18 % (stima: latte e ricavi reali, altri costi da benchmark)\n• Vendite € 1.200 (-8 % sulla settimana prima) · mozzarella venduta 80 kg\n• Produzione: latte 2.480 kg, mozzarella 600 kg, ricotta 40 kg, resa 24,2 %\n• Scarti 66 kg, 11,0 % della mozzarella',
  :'f2'::jsonb->>'body');

create or replace function fabula.sales_status(p_date date default null) returns jsonb language sql stable as $f$
  select '{"plan_missing": false, "plan_start": "2026-02-01",
           "totals": {"mtd_kg_day": 101.5, "target_kg_day": 120, "mtd_revenue_eur": 31000, "month_target_eur": 45000},
           "actions_due": [{"name": "Pizzeria Uno", "segment": "pizzeria", "town": "Agropoli", "phone": null, "next_action": "Degustazione", "overdue_days": 0}],
           "pipeline": {"active_n": 12, "by_stage": [{"stage": "contattato", "n": 7}, {"stage": "degustazione", "n": 5}]},
           "stale": [{"name": "Hotel Due", "days_since_contact": 21}], "accounts": {"lapsed": [{"customer": "Lido Tre", "phone": "0974 1", "last_order": "2026-09-30"}]},
           "tastings_next_7d": [{"name": "Pizzeria Uno", "town": "Agropoli", "date": "2026-10-23"}], "won_this_month": [{"name": "Bar Quattro"}]}'::jsonb
$f$;
select fabula.bot_fallback_run('sales', '2026-10-21') f3 \gset
select pg_temp.ck('sales, plan running: the total against the target, stale venues, customers to win back (warn), tastings, won',
  :'f3'::jsonb->>'title' = '1 locale da contattare' and :'f3'::jsonb->>'severity' = 'warn'
  and :'f3'::jsonb->>'body' like E'Da contattare:\n• Pizzeria Uno (pizzeria, Agropoli) · Degustazione\n\nIn breve:\n• Totale del mese: 101,5 kg al giorno, obiettivo 120,0 · € 31.000 su € 45.000\n• Locali aperti: 12 (contattato 7, degustazione 5)\n• Fermi da riprendere: Hotel Due (21 giorni)\n• Clienti da recuperare: Lido Tre (ultimo ordine mer 30/09, 0974 1)\n• Degustazioni nei prossimi 7 giorni: Pizzeria Uno, Agropoli (ven 23/10)\n• Vinti questo mese: Bar Quattro\n\n%',
  :'f3'::jsonb->>'body');

create or replace function fabula.monthly_review(p_month date default null) returns jsonb language sql as $f$
  select '{"month": "2027-03", "month_label": "March 2027",
           "recall_drill": {"result": "kg_non_giustificati", "lot": "L0301-A", "unaccounted_kg": 4.5},
           "food_safety": {"headline_it": "CCP fuori limite: 1 · NC critiche aperte: 1", "non_conformities": {"critical_open": 1}, "lots_on_hold": [],
                           "instruments": {"out_of_service": []}},
           "recipe_tuning": {"created": 2, "proposals": [{"component_sku": "CAGLIO", "from": 30, "to": 27, "unit": "ml"}, {"component_sku": "SALE", "from": 1.2, "to": 1.1, "unit": ""}]},
           "milk_quality": {"deliveries": 26, "rejected": 1, "fat_pct": 8.12, "fat_pct_prev": 8.3, "protein_pct": 4.61, "protein_pct_prev": 4.58},
           "unit_cost": {"mozzarella_kg": 5200, "cost_eur_per_kg": 9.84, "milk_share_pct": 71, "labor_source": "actual"},
           "package_headline": {"revenue_eur": "88000", "corrispettivi_eur": "41000", "purchases_eur": "9100", "milk_eur": "49000", "inventory_eur": "3200", "waste_kg": "140"}}'::jsonb
$f$;
select fabula.bot_fallback_run('monthly_review', '2027-04-01') f4 \gset
select pg_temp.ck('monthly, full month: the critical NC first (alert), recipe proposals to decide, the package step',
  :'f4'::jsonb->>'title' = '⚠ Marzo 2027: chiudi le non conformità critiche (1)' and :'f4'::jsonb->>'severity' = 'alert'
  and :'f4'::jsonb->>'body' like E'Da fare:\n⚠ Chiudi le non conformità critiche aperte: 1 (Autocontrollo)\n• Decidi 2 proposte di ricetta (Console → Da approvare)\n• Pacchetto per il commercialista: Console → Pacchetto mensile → Stampa/PDF\n\n%',
  :'f4'::jsonb->>'body');
select pg_temp.ck('monthly: the drill verdict with kg, recipes, milk vs the month before, unit cost, the package, in Italian numbers',
  :'f4'::jsonb->>'body' like E'%In breve:\n• Prova di richiamo sul lotto L0301-A: 4,5 kg non giustificati, controllare i movimenti di magazzino\n• Sicurezza alimentare: CCP fuori limite: 1 · NC critiche aperte: 1\n• Ricette: CAGLIO da 30 a 27 ml; SALE da 1,2 a 1,1\n• Latte: 26 consegne, 1 rifiutata; grasso 8,12 % (mese prima 8,30), proteine 4,61 % (mese prima 4,58)\n• Costo pieno € 9,84 al kg (latte 71 %, lavoro dalle ore timbrate)\n• Pacchetto: ricavi € 88.000, corrispettivi € 41.000, acquisti € 9.100, latte € 49.000, magazzino € 3.200, scarti 140 kg'
  and :'f4'::jsonb->>'summary' = 'Marzo 2027: richiamo kg_non_giustificati, NC critiche 1, 2 proposte ricetta, costo € 9,84/kg', :'f4'::jsonb->>'body');

select pg_temp.ck('who may run the stand-ins is unchanged: not logins directly, «Esegui ora» through run_bot_fallback only',
  not has_function_privilege('authenticated', 'fabula.bot_fallback_run(text, date)', 'execute')
  and not has_function_privilege('authenticated', 'fabula.bot_fallback(timestamptz)', 'execute')
  and has_function_privilege('authenticated', 'fabula.run_bot_fallback(text, boolean)', 'execute'));
select pg_temp.ck('«Perché?» names the new reads in Italian', fabula._basis_call_it('sales_status') = 'i numeri delle vendite'
  and fabula._basis_call_it('mkt_status') = 'la campagna locale e i contenuti');
