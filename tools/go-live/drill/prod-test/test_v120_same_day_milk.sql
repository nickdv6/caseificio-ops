-- v1.20 · MILK-1 · the house rule «latte del giorno»: every kg delivered goes into a vat on the day it arrives, for every product made
-- from milk · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh m_test
--   su postgres -c "psql -d m_test -f tools/go-live/drill/prod-test/test_v120_same_day_milk.sql" | grep -E "PASS|FAIL"
-- Sections: 1 structure · 2 the vat-day rule (owner and the tablet's login path) · 3 production plan · 4 «Prima di chiudere» ·
-- 5 the 19:xx watch, its non-conformity and «Perché?» · 6 the monthly declaration · 7 raw-milk expiry and the setting.
-- Times are relative to «today» in Rome, so the suite gives the same result at any hour (the 15:00 rule is checked against the clock).
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as
$$ begin execute p_sql; return ''; exception when others then return sqlerrm; end $$;
create or replace function pg_temp.at(p_day date, p_time time) returns timestamptz language sql as $$ select (p_day + p_time) at time zone 'Europe/Rome' $$;
create or replace function pg_temp.lot(p_lot text, p_product uuid, p_day date, p_start timestamptz, p_source text default 'tablet') returns uuid language sql as $$
  insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, source)
  values (p_day, p_lot, p_product, 200, 'milk', p_start, p_source) returning id $$;
-- a save as the login, the way the tablet sends it: returns the result, or the refusal's message
create or replace function pg_temp.save(p_ops jsonb) returns text language plpgsql as
$$ begin return fabula.save_ops(p_ops, gen_random_uuid())::text; exception when others then return 'ERR: ' || sqlerrm; end $$;
create or replace function pg_temp.milk(p_lot text, p_day date, p_kg numeric, p_time time default '07:00', p_ship uuid default null) returns uuid language sql as $$
  insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, temperature_c, accepted, source, shipment_id)
  values (p_day, p_time, (select id from fabula.parties where legal_name = 'Masseria M120'), p_lot, p_kg, 4, true, 'tablet', p_ship) returning id $$;

select (now() at time zone 'Europe/Rome')::date d \gset
select (:'d'::date - 1) y \gset
insert into fabula.parties (type, legal_name, is_milk_supplier, is_dop_certified) values ('supplier', 'Masseria M120', true, true) returning id sup \gset
select id moz from fabula.products where sku = 'MOZ-DOP-KG' \gset
insert into fabula.products (sku, name, kind, unit, iva_rate, shelf_life_days, is_dop)
values ('T120-SCA', 'Scamorza di bufala (test M120)', 'finished_good', 'kg', 4, 10, false) returning id sca \gset
insert into auth.users (id, email) values ('00000000-0000-4000-a000-0000000a1201', 'tit@m120.it'), ('00000000-0000-4000-a000-0000000a1203', 'prod@m120.it');
insert into fabula.staff (id, full_name, auth_user_id, app_role, role, active) values
  ('10000000-0000-4000-a000-0000000a1201', 'Titolare M120', '00000000-0000-4000-a000-0000000a1201', 'titolare', 'owner', true),
  ('10000000-0000-4000-a000-0000000a1203', 'Produzione M120', '00000000-0000-4000-a000-0000000a1203', 'produzione', 'casaro', true);
\set TIT 'select set_config(''request.jwt.claims'', ''{"sub":"00000000-0000-4000-a000-0000000a1201","role":"authenticated"}'', false); set role authenticated;'
\set PROD 'select set_config(''request.jwt.claims'', ''{"sub":"00000000-0000-4000-a000-0000000a1203","role":"authenticated"}'', false); set role authenticated;'
\set OWNER 'reset role; select set_config(''request.jwt.claims'', '''', false);'

-- deliveries: today 600 kg, yesterday 300 kg, 3 days ago 300 kg (a paper day), 62 h ago 400 kg (DOP limit)
select pg_temp.milk('M120-T', :'d', 600) mt \gset
select pg_temp.milk('M120-Y', :'y', 300) my \gset
select pg_temp.milk('M120-P', :'d'::date - 3, 300) mp \gset
select pg_temp.milk('M120-OLD', ((now() - interval '62 hours') at time zone 'Europe/Rome')::date, 400, ((now() - interval '62 hours') at time zone 'Europe/Rome')::time) mo \gset

-- ============================== 1. structure ==============================
select pg_temp.ck('1a batch_milk_same_day is a BEFORE INSERT OR UPDATE (milk_intake_id, batch_id) trigger on batch_milk_inputs',
  exists (select 1 from pg_trigger t where t.tgname = 'batch_milk_same_day' and t.tgrelid = 'fabula.batch_milk_inputs'::regclass and not t.tgisinternal
            and pg_get_triggerdef(t.oid) like '%BEFORE INSERT OR UPDATE OF milk_intake_id, batch_id%'));
select pg_temp.ck('1b it fires after the DOP 60 h guard (name order), so a DOP lot hears the legal limit first',
  'batch_milk_dop_age' < 'batch_milk_same_day' and exists (select 1 from pg_trigger where tgname = 'batch_milk_dop_age'));
select pg_temp.ck('1c logins and anon cannot call the trigger function',
  not has_function_privilege('authenticated', 'fabula.trg_batch_milk_same_day()', 'EXECUTE') and not has_function_privilege('anon', 'fabula.trg_batch_milk_same_day()', 'EXECUTE'));

-- ============================== 2. the vat is filled on the day the milk arrives ==============================
select pg_temp.lot('L120-A', :'moz', :'d', now()) la \gset
select pg_temp.ck('2a today''s milk into today''s DOP vat: accepted',
  pg_temp.err(format('insert into fabula.batch_milk_inputs values (%L, %L, 200)', :'la', :'mt')) = '');
select pg_temp.lot('L120-B', :'moz', :'d', now()) lb \gset
select pg_temp.err(format('insert into fabula.batch_milk_inputs values (%L, %L, 200)', :'lb', :'my')) e_b \gset
select pg_temp.ck('2b yesterday''s milk into today''s DOP vat: refused, with the lot, the day and the rule',
  :'e_b' = format('Il latte M120-Y è arrivato il %s: si lavora solo il giorno in cui arriva (regola del caseificio: tutto il latte consegnato va in caldaia lo stesso giorno). Chiama il responsabile.', fabula._it_d(:'y')), :'e_b');
select pg_temp.lot('L120-C', :'sca', :'d', now()) lc \gset
select pg_temp.ck('2c …and into a product that is not DOP: refused too (the rule covers every product made from milk)',
  pg_temp.err(format('insert into fabula.batch_milk_inputs values (%L, %L, 200)', :'lc', :'my')) like 'Il latte M120-Y è arrivato il %regola del caseificio%');
select pg_temp.lot('L120-D', :'moz', :'y', pg_temp.at(:'y', '10:00')) ld \gset
select pg_temp.ck('2d a vat started yesterday at 10:00 from yesterday''s milk and sent today (offline): accepted, its own start time counts',
  pg_temp.err(format('insert into fabula.batch_milk_inputs values (%L, %L, 200)', :'ld', :'my')) = '');
select pg_temp.lot('L120-E', :'moz', :'d'::date - 3, pg_temp.at(:'d'::date - 3, '09:00'), 'paper') le \gset
select pg_temp.ck('2e a start copied from paper 3 days later, from that day''s milk: accepted',
  pg_temp.err(format('insert into fabula.batch_milk_inputs values (%L, %L, 200)', :'le', :'mp')) = '');
insert into fabula.milk_shipments (id, shipped_at, ship_date, supplier_id, kg, milk_lot, status) values
  ('60000000-0000-4000-a000-0000000a1201', pg_temp.at(:'y', '23:40'), :'y', :'sup', 300, 'M120-S1', 'shipped'),
  ('60000000-0000-4000-a000-0000000a1202', pg_temp.at(:'d', '06:00'), :'d', :'sup', 300, 'M120-S2', 'shipped');
select pg_temp.milk('M120-S1', :'d', 300, '06:30', '60000000-0000-4000-a000-0000000a1201') ms1 \gset
select pg_temp.milk('M120-S2', :'d', 300, '06:30', '60000000-0000-4000-a000-0000000a1202') ms2 \gset
select pg_temp.lot('L120-F', :'moz', :'d', now()) lf \gset
-- the farm's departure is not checked (review 29/10): a load the farm records the evening before and that arrives this morning is the
-- morning delivery; refusing it would block every vat of the day with no way to correct the time. The milkings come with release B.
select pg_temp.ck('2f a load recorded by the farm yesterday at 23:40 and arrived this morning: accepted (the arrival day decides)',
  pg_temp.err(format('insert into fabula.batch_milk_inputs values (%L, %L, 100)', :'lf', :'ms1')) = '');
select pg_temp.ck('2g a load that left this morning: accepted',
  pg_temp.err(format('insert into fabula.batch_milk_inputs values (%L, %L, 100)', :'lf', :'ms2')) = '');
select pg_temp.ck('2h pointing an input at older milk afterwards (UPDATE): refused',
  pg_temp.err(format('update fabula.batch_milk_inputs set milk_intake_id = %L, qty_kg = 50 where batch_id = %L', :'my', :'la')) like 'Il latte M120-Y è arrivato il %');   -- 50 kg: within what is left, so the over-draw guard lets it through
select pg_temp.ck('2i …and moving yesterday''s input to today''s vat (UPDATE batch_id): refused',
  pg_temp.err(format('update fabula.batch_milk_inputs set batch_id = %L where batch_id = %L', :'lb', :'ld')) like 'Il latte M120-Y è arrivato il %');
select pg_temp.lot('L120-G', :'moz', :'d', now()) lg \gset
select pg_temp.ck('2j milk 62 hours old into a DOP vat: the 60-hour DOP message comes first (legal backstop kept)',
  pg_temp.err(format('insert into fabula.batch_milk_inputs values (%L, %L, 200)', :'lg', :'mo')) like 'Il latte M120-OLD ha già 62 ore: oltre le 60 ore non si può fare%');
select pg_temp.ck('2k …into a product that is not DOP: refused by the house rule (it was accepted before v1.20)',
  pg_temp.err(format('insert into fabula.batch_milk_inputs values (%L, %L, 200)', :'lc', :'mo')) like 'Il latte M120-OLD è arrivato il %regola del caseificio%');
insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, input_kind, source) values (:'d', 'L120-H', :'moz', 100, 'milk', 'tablet'), (:'y', 'L120-I', :'moz', 100, 'milk', 'tablet');
select pg_temp.ck('2l a lot with no start time counts by its day: today''s lot takes today''s milk, yesterday''s lot does not',
  pg_temp.err(format('insert into fabula.batch_milk_inputs values ((select id from fabula.production_batches where batch_lot = %L), %L, 50)', 'L120-H', :'mt')) = ''
  and pg_temp.err(format('insert into fabula.batch_milk_inputs values ((select id from fabula.production_batches where batch_lot = %L), %L, 50)', 'L120-I', :'mt')) like 'Il latte M120-T è arrivato il %');
-- the tablet's path: the produzione login through save_ops, the batch and its milk in one save
:PROD
select pg_temp.save(jsonb_build_array(
  jsonb_build_object('table', 'production_batches', 'row', jsonb_build_object('batch_date', :'d', 'batch_lot', 'L120-J', 'product_id', :'sca', 'milk_in_kg', 100, 'started_at', now(), 'source', 'tablet', 'casaro_id', '10000000-0000-4000-a000-0000000a1203')),
  jsonb_build_object('table', 'batch_milk_inputs', 'row', jsonb_build_object('batch_id', '$0.id', 'milk_intake_id', :'my', 'qty_kg', 100)))) s_bad \gset
select pg_temp.save(jsonb_build_array(
  jsonb_build_object('table', 'production_batches', 'row', jsonb_build_object('batch_date', :'d', 'batch_lot', 'L120-K', 'product_id', :'sca', 'milk_in_kg', 100, 'started_at', now(), 'source', 'tablet', 'casaro_id', '10000000-0000-4000-a000-0000000a1203')),
  jsonb_build_object('table', 'batch_milk_inputs', 'row', jsonb_build_object('batch_id', '$0.id', 'milk_intake_id', :'mt', 'qty_kg', 100)))) s_ok \gset
:OWNER
select pg_temp.ck('2m the tablet''s save (produzione login) with yesterday''s milk: the whole save is refused, with the house-rule message, and no lot is left behind',
  :'s_bad' like 'ERR: %regola del caseificio%' and not exists (select 1 from fabula.production_batches where batch_lot = 'L120-J'), left(:'s_bad', 300));
select pg_temp.ck('2n …with today''s milk: saved as before',
  exists (select 1 from fabula.batch_milk_inputs bmi join fabula.production_batches b on b.id = bmi.batch_id where b.batch_lot = 'L120-K' and bmi.milk_intake_id = :'mt'), left(:'s_ok', 300));

-- ============================== 3. production plan ==============================
select pg_temp.milk('M120-SMALL', :'d', 250, '07:10') msmall \gset
select fabula.production_plan(:'d') p \gset
select pg_temp.ck('3a only today''s deliveries are proposed (yesterday''s milk with kg left is not)',
  not exists (select 1 from jsonb_array_elements(:'p'::jsonb->'milk') x where (x->>'intake_date')::date <> :'d'::date)
  and not exists (select 1 from jsonb_array_elements(:'p'::jsonb->'proposals') x where x->>'milk_lot' in ('M120-Y', 'M120-P', 'M120-OLD'))
  and exists (select 1 from jsonb_array_elements(:'p'::jsonb->'proposals') x where x->>'milk_lot' = 'M120-T'),
  (select string_agg(x->>'milk_lot', ',') from jsonb_array_elements(:'p'::jsonb->'proposals') x));
select pg_temp.ck('3b yesterday''s milk with kg left is listed apart («stale») with what is left, never proposed',
  (select (x->>'left_kg')::numeric = 100 from jsonb_array_elements(:'p'::jsonb->'stale') x where x->>'milk_lot' = 'M120-Y')
  and (:'p'::jsonb->>'same_day')::boolean, (:'p'::jsonb->'stale')::text);
select pg_temp.ck('3c a small delivery of today (250 kg, under the minimum run) is still proposed in full, flagged «small»',
  (select (x->>'milk_kg')::numeric = 250 and (x->>'small')::boolean from jsonb_array_elements(:'p'::jsonb->'proposals') x where x->>'milk_lot' = 'M120-SMALL'));
select pg_temp.ck('3d the 60 h DOP deadline is still in the payload (the tablet reads the age from it)',
  (select x ? 'use_by' from jsonb_array_elements(:'p'::jsonb->'milk') x where x->>'milk_lot' = 'M120-T'));

-- the weighing tolerance (milk.weight_tolerance_pct, 2 %): 15 kg left of 1,000 is a delivery worked in full; 30 kg left is not
select pg_temp.milk('M120-TOL', :'d', 1000, '07:30') mtol \gset
select pg_temp.milk('M120-OVER', :'d', 1000, '07:40') mover \gset
select pg_temp.lot('L120-T1', :'moz', :'d', now()) lt1 \gset
select pg_temp.lot('L120-T2', :'moz', :'d', now()) lt2 \gset
insert into fabula.batch_milk_inputs values (:'lt1', :'mtol', 985), (:'lt2', :'mover', 970);
select pg_temp.ck('3e the tolerance: 15 kg left of 1.000 kg (1,5 %) counts as worked in full; 30 kg (3 %) does not; never less than 1 kg',
  not fabula.milk_left_over(1000, 15) and fabula.milk_left_over(1000, 30) and fabula.milk_left_over(40, 1.5) and not fabula.milk_left_over(40, 1));

-- ============================== 4. «Prima di chiudere» ==============================
select fabula._haccp_evening_items(:'y')::text ey \gset
select pg_temp.ck('4a yesterday: the delivery with kg left is on the list, as not worked on its day, and opens the milk',
  exists (select 1 from jsonb_array_elements(:'ey'::jsonb) x where x->>'code' = 'milkleft:M120-Y' and x->>'scan' = 'LOT:M120-Y'
            and x->>'label_it' = 'Latte M120-Y: 100 kg non lavorati il giorno di arrivo (regola del caseificio): chiama il responsabile'), :'ey');
select fabula._haccp_evening_items(:'d')::text ed \gset
select pg_temp.ck('4b today: the delivery with kg left is on the list from 15:00 Rome, not before',
  exists (select 1 from jsonb_array_elements(:'ed'::jsonb) x where x->>'code' = 'milkleft:M120-T' and x->>'label_it' like 'Latte M120-T: % kg non ancora in caldaia: va lavorato oggi')
  = ((now() at time zone 'Europe/Rome')::time >= time '15:00'), :'ed');
select pg_temp.ck('4b2 …within the weighing tolerance it is not (15 kg of 1.000); over it, it is (30 kg), from 15:00',
  not (:'ed' like '%M120-TOL%')
  and (:'ed' like '%milkleft:M120-OVER%') = ((now() at time zone 'Europe/Rome')::time >= time '15:00'), :'ed');
select pg_temp.milk('M120-FULL', :'y', 200, '07:20') mfull \gset
select pg_temp.lot('L120-L', :'moz', :'y', pg_temp.at(:'y', '11:00')) ll \gset
insert into fabula.batch_milk_inputs values (:'ll', :'mfull', 200);
select pg_temp.ck('4c a delivery that went into vats in full is not on the list',
  not (fabula._haccp_evening_items(:'y')::text like '%M120-FULL%'));

-- ============================== 5. the 19:xx watch ==============================
select fabula.prod_watch(pg_temp.at(:'d', '18:30'))->>'skipped' w0 \gset
select pg_temp.ck('5a not at 18:xx Rome', :'w0' = 'not 19:xx in Rome');
select fabula.prod_watch(pg_temp.at(:'d', '19:30')) w1 \gset
select id m1 from fabula.bot_messages where agent = 'sicurezza' and title like 'Produzione %consegne di latte non lavorate in giornata' order by id desc limit 1 \gset
select pg_temp.ck('5b an alarm for food safety: «Regola del caseificio», each delivery with its kg left (today''s and the earlier ones), and what happens next',
  (select severity = 'alert' and body like '%Regola del caseificio: tutto il latte consegnato va in caldaia il giorno in cui arriva.%'
          and body like '%M120-Y: 100 kg, arrivato%' and body like '%M120-T: % kg, arrivato%' and body like '%Non può andare in caldaia nei giorni seguenti.%'
          and body not like '%M120-FULL%' and body not like '%M120-TOL%' and body like '%M120-OVER: 30 kg, arrivato%' from fabula.bot_messages where id = :'m1'), :'w1');
select pg_temp.ck('5c one non-conformity per delivery not worked in full (as many as the alarm lists), severity minor, with the milk lot; none within the tolerance',
  (select count(*) from fabula.non_conformities where description like 'Regola del caseificio:%') = (:'w1'::jsonb->>'nc_opened')::int
  and (:'w1'::jsonb->>'nc_opened')::int = (:'w1'::jsonb->>'old_milk')::int and (:'w1'::jsonb->>'nc_opened')::int >= 2
  and not exists (select 1 from fabula.non_conformities where lot_number = 'M120-TOL')
  and exists (select 1 from fabula.non_conformities where lot_number = 'M120-Y' and severity = 'minor' and status = 'open'
                and description = format('Regola del caseificio: latte M120-Y arrivato il %s, 100 kg non lavorati il giorno di arrivo. Non va in caldaia nei giorni seguenti: decidi cosa farne e scrivi cosa è stato fatto.', fabula._it_d(:'y'))),
  :'w1');
select fabula.prod_watch(pg_temp.at(:'d', '19:40')) w2 \gset
select pg_temp.ck('5d the same evening again: not posted twice, no second non-conformity',
  :'w2'::jsonb->>'skipped' = 'already posted' and (:'w2'::jsonb->>'nc_opened')::int = 0, :'w2');
-- between two runs of the same evening: a new delivery not in a vat, and the same lot as yesterday's on a new day (a lot written by hand)
select pg_temp.milk('M120-NEW2', :'d', 200, '08:10') mnew2 \gset
select pg_temp.milk('M120-Y', :'d', 120, '08:20') my2 \gset
select fabula.prod_watch(pg_temp.at(:'d', '19:45')) w2b \gset
select pg_temp.ck('5d2 a later run the same evening with new milk not in a vat: posted (never only a non-conformity), just the new deliveries, the same lot on a new day included',
  :'w2b'::jsonb->>'skipped' is null and (:'w2b'::jsonb->>'old_milk')::int = 2 and (:'w2b'::jsonb->>'nc_opened')::int = 2
  and (select body like '%M120-NEW2: 200 kg%' and body like '%M120-Y: 120 kg%' and body not like '%M120-T:%' from fabula.bot_messages
        where agent = 'sicurezza' and title like 'Produzione %' order by id desc limit 1)
  and (select count(*) from fabula.non_conformities where lot_number = 'M120-Y') = 2, :'w2b');
select fabula.prod_watch(pg_temp.at(:'d'::date + 1, '19:30')) w3 \gset
select pg_temp.ck('5e the next evening: no alarm again for milk already reported (its non-conformity is open), no second non-conformity',
  (:'w3'::jsonb->>'old_milk')::int = 0 and (:'w3'::jsonb->>'nc_opened')::int = 0 and :'w3'::jsonb->>'skipped' is null
  and (select count(*) from fabula.non_conformities where lot_number = 'M120-Y') = 2
  and not exists (select 1 from fabula.bot_messages where agent = 'sicurezza' and title like format('Produzione %s:%%latte%%', to_char(:'d'::date + 1, 'DD/MM'))), :'w3');
select pg_temp.ck('5f the rule that makes it an alarm is «latte_non_lavorato» (was «latte_60_ore»)',
  exists (select 1 from fabula.message_rules where kind = 'latte_non_lavorato' and severity = 'alert' and topic = 'food_safety' and title_regex = 'latte non lavorat')
  and not exists (select 1 from fabula.message_rules where kind = 'latte_60_ore'));
select fabula.message_why(:'m1')::text why \gset
select pg_temp.ck('5g «Perché?»: the lot, the kg not worked, when it arrived, and the house rule next to the DOP limit',
  :'why' like '%M120-Y%' and :'why' like '%100 kg non lavorati%' and :'why' like '%Regola del caseificio%' and :'why' like '%60 ore dalla mungitura%', left(:'why', 500));
select id nc from fabula.non_conformities where lot_number = 'M120-Y' and description like format('Regola del caseificio: latte M120-Y arrivato il %s,%%', fabula._it_d(:'y')) \gset
:TIT
select pg_temp.err(format('update fabula.non_conformities set status = ''closed'' where id = %L', :'nc')) e_close \gset
select pg_temp.err(format('update fabula.non_conformities set status = ''closed'', corrective_action = %L where id = %L', 'Latte rimasto per guasto del pastorizzatore: restituito alla Masseria e venduto da lì', :'nc')) e_close2 \gset
:OWNER
select pg_temp.ck('5h the non-conformity is closed only with the corrective action (titolare, HACCP level 3)',
  :'e_close' like 'Scrivi l''azione correttiva%' and :'e_close2' = '' and (select status = 'closed' from fabula.non_conformities where id = :'nc'), :'e_close' || ' | ' || :'e_close2');
select fabula.production_plan(:'d') p2 \gset
select pg_temp.ck('5j once its non-conformity is closed, yesterday''s milk leaves the plan''s list and the evening list; an open one stays',
  not exists (select 1 from jsonb_array_elements(:'p2'::jsonb->'stale') x where x->>'milk_lot' = 'M120-Y')
  and exists (select 1 from jsonb_array_elements(:'p2'::jsonb->'stale') x where x->>'milk_lot' = 'M120-P' and x->>'nc_status' = 'open')
  and not (fabula._haccp_evening_items(:'y')::text like '%M120-Y%'), (:'p2'::jsonb->'stale')::text);
select fabula._why_prod_watch('{"warn_hours": 48, "dop_limit_hours": 60, "open_batches": [], "old_milk": [{"lot": "MX-OLD", "left_kg": 5, "arrived": "2026-10-20T06:00:00+00:00", "hours": 50}]}'::jsonb)::text wold \gset
insert into fabula.bot_messages (agent, severity, title, body, source, created_at)
values ('produzione', 'warn', format('Produzione %s: 1 lotto aperto', to_char(:'d'::date + 2, 'DD/MM')), 'x', 'bot', now() - interval '1 year');
select pg_temp.ck('5j2 an evening message of the same date a year ago does not silence this evening',
  fabula.prod_watch(pg_temp.at(:'d'::date + 2, '19:30'))->>'skipped' is null);
select pg_temp.ck('5k «Perché?» of a message posted before v1.20 (no «rule» in its data) keeps its own 48/60 h explanation',
  :'wold' like '%"t": "Latte vicino alle 60 ore"%' and :'wold' like '%5 kg da lavorare%' and :'wold' like '%l''avviso parte a 48 ore dall''arrivo%'
  and :'wold' not like '%Regola del caseificio%', :'wold');
select pg_temp.ck('5i the scheduled job keeps its slot; its description says what it now watches',
  exists (select 1 from fabula.cron_jobs_expected where jobname = 'fabula_prod_watch' and purpose_it = 'Lotti aperti e latte non lavorato in giornata (sera)'));

-- ============================== 6. monthly declaration ==============================
-- a lot made from another day's milk can only exist from before v1.20: made here with the trigger off, as old data would be
alter table fabula.batch_milk_inputs disable trigger batch_milk_same_day;
select pg_temp.lot('L120-X', :'sca', :'d', now()) lx \gset
insert into fabula.batch_milk_inputs values (:'lx', :'mp', 50);
alter table fabula.batch_milk_inputs enable trigger batch_milk_same_day;
select fabula.consorzio_declaration(date_trunc('month', :'d'::date)::date) j \gset
select pg_temp.ck('6a check «latte_altro_giorno»: the lot made from milk of another day, for a product that is not DOP too',
  exists (select 1 from jsonb_array_elements(:'j'::jsonb->'issues') i, jsonb_array_elements(i->'detail') x
           where i->>'check' = 'latte_altro_giorno' and x->>'lot' = 'L120-X' and x->>'milk_lot' = 'M120-P'),
  (select string_agg(i->>'check', ',') from jsonb_array_elements(:'j'::jsonb->'issues') i));
-- a delivery of today: 200 kg in a vat today, 100 kg in a vat tomorrow (only possible as old data: trigger off)
select pg_temp.milk('M120-LATE', :'d', 300, '07:50') mlate \gset
select pg_temp.lot('L120-LT1', :'sca', :'d', now()) llt1 \gset
insert into fabula.batch_milk_inputs values (:'llt1', :'mlate', 200);
alter table fabula.batch_milk_inputs disable trigger batch_milk_same_day;
select pg_temp.lot('L120-LT2', :'sca', :'d'::date + 1, pg_temp.at(:'d'::date + 1, '09:00')) llt2 \gset
insert into fabula.batch_milk_inputs values (:'llt2', :'mlate', 100);
alter table fabula.batch_milk_inputs enable trigger batch_milk_same_day;
select fabula.consorzio_declaration(date_trunc('month', :'d'::date)::date) jd \gset
select pg_temp.ck('6b check «latte_non_lavorato»: a delivery with 100 kg not worked on its day (the kg of the late lot do not count), with its non-conformity''s status; a delivery within the tolerance is not listed',
  exists (select 1 from jsonb_array_elements(:'jd'::jsonb->'issues') i, jsonb_array_elements(i->'detail') x
           where i->>'check' = 'latte_non_lavorato' and x->>'milk_lot' = 'M120-LATE' and (x->>'kg_left')::numeric = 100)
  and exists (select 1 from jsonb_array_elements(:'jd'::jsonb->'issues') i, jsonb_array_elements(i->'detail') x
           where i->>'check' = 'latte_non_lavorato' and x->>'milk_lot' = 'M120-T' and x->>'nc_status' = 'open')
  and not exists (select 1 from jsonb_array_elements(:'jd'::jsonb->'issues') i, jsonb_array_elements(i->'detail') x
           where i->>'check' = 'latte_non_lavorato' and x->>'milk_lot' = 'M120-TOL'), (:'jd'::jsonb->'issues')::text);
-- before 29/10/2026 the rule did not exist (the plan itself proposed the day before's milk): a lot of 21/10 from milk of 20/10 is not listed
alter table fabula.batch_milk_inputs disable trigger batch_milk_same_day;
select pg_temp.milk('M120-PRE', date '2026-10-20', 300, '07:00') mpre \gset
select pg_temp.lot('L120-PRE', :'sca', date '2026-10-21', pg_temp.at(date '2026-10-21', '09:00')) lpre \gset
insert into fabula.batch_milk_inputs values (:'lpre', :'mpre', 200);
alter table fabula.batch_milk_inputs enable trigger batch_milk_same_day;
select fabula.consorzio_declaration(date '2026-10-01') jo \gset
select pg_temp.ck('6d the checks start on 29/10/2026: October''s lots and deliveries before it are not listed',
  not exists (select 1 from jsonb_array_elements(:'jo'::jsonb->'issues') i, jsonb_array_elements(i->'detail') x
               where x->>'lot' = 'L120-PRE' or x->>'milk_lot' = 'M120-PRE'), (:'jo'::jsonb->'issues')::text);
select pg_temp.ck('6c the month''s longest time from arrival to vat is in the figures',
  (:'j'::jsonb->>'arrival_to_vat_max_h') is not null and (:'j'::jsonb->>'arrival_to_vat_max_h')::numeric >= 0, :'j'::jsonb->>'arrival_to_vat_max_h');

-- ============================== 7. raw-milk expiry and the setting ==============================
select pg_temp.ck('7a milk.raw_shelf_days is 0 (the day of arrival), minimum 0',
  exists (select 1 from fabula.settings where key = 'milk.raw_shelf_days' and value = '0' and min_value = 0));
select pg_temp.ck('7b a delivery''s raw-milk lot expires the day it arrives',
  (select expiry_date from fabula.stock_moves sm join fabula.products p on p.id = sm.product_id
    where p.sku = 'RAW-MILK' and sm.lot_number = 'M120-T' and sm.move_type = 'milk_intake') = :'d'::date);
select pg_temp.ck('7c a negative value is refused by the setting''s limits',
  pg_temp.err('update fabula.settings set value = ''-1'' where key = ''milk.raw_shelf_days''') <> '');
