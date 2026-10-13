-- v0.98 audit numbers and limits (C-02, C-03, D-13, D-06, D-30, D-07, D-27/B-14, D-20, D-19, D-18, FARM-07, TRADE-01, D-23) · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh n_test
--   su postgres -c "psql -d n_test -f tools/go-live/drill/prod-test/test_audit_numbers.sql" | grep -E "PASS|FAIL"
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
-- the error text, and its hint after « || hint: » when there is one
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as
$$ declare h text; begin execute p_sql; return ''; exception when others then get stacked diagnostics h = pg_exception_hint; return sqlerrm || case when coalesce(h, '') <> '' then ' || hint: ' || h else '' end; end $$;
create or replace function pg_temp.st(p_sql text) returns text language plpgsql as
$$ begin execute p_sql; return ''; exception when others then return sqlstate; end $$;
create or replace function pg_temp.as_user(p_sub text) returns void language sql as
$$ select set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_sub), false) $$;
create or replace function pg_temp.today() returns date language sql as $$ select (now() at time zone 'Europe/Rome')::date $$;
select id moz from fabula.products where sku = 'MOZ-DOP-KG' \gset
select id ric from fabula.products where sku = 'RIC-BUF-KG' \gset
select id rennet from fabula.products where sku = 'CON-RENNET' \gset
select id rawmilk from fabula.products where sku = 'RAW-MILK' \gset
insert into fabula.staff (id, full_name, role, app_role, active, auth_user_id) values
  ('10000000-0000-4000-a000-0000000098a1', 'Titolare N', 'owner', 'titolare', true, '00000000-0000-4000-a000-0000000098a1'),
  ('10000000-0000-4000-a000-0000000098a2', 'Casaro N', 'casaro', 'produzione', true, '00000000-0000-4000-a000-0000000098a2'),
  ('10000000-0000-4000-a000-0000000098a3', 'Banco N', 'commesso', 'banco', true, '00000000-0000-4000-a000-0000000098a3')
on conflict do nothing;
insert into fabula.parties (id, type, legal_name, is_milk_supplier, active) values ('50000000-0000-4000-a000-0000000098f1', 'supplier', 'Masseria N', true, true) on conflict do nothing;
\set CAS '''10000000-0000-4000-a000-0000000098a2'''
update fabula.settings set value = '310' where key = 'prod.vat_kg';

-- ============================== C-02 / C-03 / D-13 settings ==============================
select pg_temp.as_user('00000000-0000-4000-a000-0000000098a1');
set role authenticated;
select pg_temp.err($q$update fabula.settings set value = '1,80' where key = 'milk.price_eur_kg'$q$) e_c1 \gset
select value v_price from fabula.settings where key = 'milk.price_eur_kg' \gset
select pg_temp.err($q$update fabula.settings set value = '17' where key = 'milk.price_eur_kg'$q$) e_c2 \gset
select pg_temp.err($q$update fabula.settings set value = '3100' where key = 'prod.vat_kg'$q$) e_c3 \gset
select pg_temp.err($q$update fabula.settings set value = '' where key = 'ship.tolerance_pct'$q$) e_c4 \gset
select pg_temp.err($q$update fabula.settings set value = '-5' where key = 'ship.tolerance_pct'$q$) e_c5 \gset
select pg_temp.err($q$update fabula.settings set value = '120' where key = 'trade.recurring_discount_pct'$q$) e_c6 \gset
select pg_temp.err($q$update fabula.settings set value = '0' where key = 'milk.round_kg'$q$) e_c7 \gset
select pg_temp.err($q$update fabula.settings set value = '0' where key = 'approve.auto_delay_min'$q$) e_c8 \gset
select pg_temp.err($q$update fabula.settings set value = 'Firmato' where key = 'food.manuale_stato'$q$) e_c9 \gset
select value v_man from fabula.settings where key = 'food.manuale_stato' \gset
select pg_temp.err($q$update fabula.settings set value = 'firmata' where key = 'food.manuale_stato'$q$) e_c10 \gset
select pg_temp.err($q$update fabula.settings set value = 'PASTORIZZATO ' where key = 'food.milk_process'$q$) e_c11 \gset
select pg_temp.err($q$update fabula.settings set value = 'kg settimanali del piano' where key = 'trade.tier_basis'$q$) e_c12 \gset
select pg_temp.err($q$update fabula.settings set value = '7' where key = 'shopify.push_inventory'$q$) e_c13 \gset
select pg_temp.err($q$update fabula.settings set value = 'sì' where key = 'milk.cap_to_farm'$q$) e_c14 \gset
select pg_temp.err($q$update fabula.settings set value = 'forse' where key = 'milk.cap_to_farm'$q$) e_c15 \gset
select pg_temp.err($q$update fabula.settings set value = '25/01/2027' where key = 'trial.start'$q$) e_c16 \gset
select pg_temp.err($q$update fabula.settings set value = '31/02/2027' where key = 'trial.start'$q$) e_c17 \gset
select pg_temp.err($q$update fabula.settings set value = '' where key = 'food.sampling_start'$q$) e_c18 \gset
select pg_temp.err($q$update fabula.settings set value = '03/2027' where key = 'sales.plan_start'$q$) e_c19 \gset
select pg_temp.err($q$update fabula.settings set value = '30' where key = 'prod.yield_max_pct'$q$) e_c20a \gset
select pg_temp.err($q$update fabula.settings set value = '35' where key = 'prod.yield_min_pct'$q$) e_c20 \gset
select pg_temp.err($q$update fabula.settings set value = '45' where key = 'prod.yield_max_pct'$q$) e_c20b \gset
select pg_temp.err($q$update fabula.settings set value = '18.30' where key = 'trade.cutoff_time'$q$) e_c21 \gset
reset role;
select pg_temp.ck('C-02/D-13 «1,80» is accepted and stored as 1.80', :'e_c1' = '' and :'v_price' = '1.80', :'v_price' || ' ' || :'e_c1');
select pg_temp.ck('C-02 milk price 17 €/kg is refused, naming the setting and the range', :'e_c2' like '«Prezzo del latte di bufala%17 €/kg non è possibile: scrivi un valore tra 0,5 e 5 €/kg%', :'e_c2');
select pg_temp.ck('C-02 vat 3100 kg (meant 310) is refused', :'e_c3' like '%3100 kg non è possibile%tra 50 e 3000 kg%', :'e_c3');
select pg_temp.ck('D-13 an empty number is refused', :'e_c4' like '%scrivi un numero%', :'e_c4');
select pg_temp.ck('D-13 a negative weight tolerance is refused', :'e_c5' like '%-5 % non è possibile%', :'e_c5');
select pg_temp.ck('D-13 a 120 % recurring discount is refused', :'e_c6' like '%120 % non è possibile%tra 0 e 50 %', :'e_c6');
select pg_temp.ck('D-13 milk rounding 0 (division by zero in the plan) is refused', :'e_c7' like '%non è possibile%', :'e_c7');
select pg_temp.ck('D-13 auto-approval after 0 minutes is refused', :'e_c8' like '%0 min non è possibile%tra 5 e 1440 min%', :'e_c8');
select pg_temp.ck('C-03 «Firmato» (iPad capital letter) is stored as firmato', :'e_c9' = '' and :'v_man' = 'firmato', :'v_man' || ' ' || :'e_c9');
select pg_temp.ck('C-03 a value not on the list is refused, with the list', :'e_c10' like '%scegli uno dei valori dell''elenco (Bozza, Firmato)%', :'e_c10');
select pg_temp.ck('C-03 «PASTORIZZATO » and a label («kg settimanali del piano») are stored as their values',
  :'e_c11' = '' and :'e_c12' = '' and (select value from fabula.settings where key = 'food.milk_process') = 'pastorizzato'
  and (select value from fabula.settings where key = 'trade.tier_basis') = 'week', :'e_c11' || :'e_c12');
select pg_temp.ck('C-03 Shopify stock push 7 (only 0/1/2 exist) is refused', :'e_c13' like '%scegli uno dei valori%', :'e_c13');
select pg_temp.ck('D-13 a flag takes «sì» (stored 1) and refuses anything else',
  :'e_c14' = '' and (select value from fabula.settings where key = 'milk.cap_to_farm') = '1' and :'e_c15' like '%scegli Sì o No%', :'e_c15');
select pg_temp.ck('D-13 a date written 25/01/2027 is stored 2027-01-25; 31/02 is refused',
  :'e_c16' = '' and (select value from fabula.settings where key = 'trial.start') = '2027-01-25' and :'e_c17' like '%data non valida%', :'e_c17');
select pg_temp.ck('D-13 a date documented as «Vuoto = …» can be emptied', :'e_c18' = '', :'e_c18');
select pg_temp.ck('D-13 a month written 03/2027 is stored 2027-03-01', :'e_c19' = '' and (select value from fabula.settings where key = 'sales.plan_start') = '2027-03-01', :'e_c19');
select pg_temp.ck('C-02 the minimum yield cannot go above the maximum (max 30, min 35 refused)', :'e_c20a' = '' and :'e_c20b' = '' and :'e_c20' like '%35 % deve essere più basso del massimo (30 %)%', :'e_c20');
select pg_temp.ck('C-04 still works: the B2B cut-off «18.30» is normalised to 18:30', :'e_c21' = '' and (select value from fabula.settings where key = 'trade.cutoff_time') = '18:30', :'e_c21');
select pg_temp.ck('C-02 a high-impact change (milk price) is posted to the bell with who did it and the old and new value',
  exists (select 1 from fabula.bot_messages where agent = 'configurazione' and severity = 'warn' and title like 'Parametro cambiato: Prezzo del latte%'
          and body like 'Titolare N ha cambiato%1,7 €/kg → 1,8 €/kg%Cambia il costo%'), (select body from fabula.bot_messages where agent = 'configurazione' order by created_at desc limit 1));
select pg_temp.ck('C-02 …a low-impact change (cut-off, tolerance) posts nothing; the refused ones post nothing either',
  not exists (select 1 from fabula.bot_messages where agent = 'configurazione' and (title like '%Ora limite%' or title like '%Arrotondamento%' or body like '%17 €/kg%' or body like '%3100%')),
  (select string_agg(title, ' | ') from fabula.bot_messages where agent = 'configurazione'));
-- an unreadable stored value (written around the check) no longer breaks the callers
alter table fabula.settings disable trigger settings_validate;
update fabula.settings set value = '1,7x' where key = 'milk.round_kg';
alter table fabula.settings enable trigger settings_validate;
select pg_temp.ck('D-13 setting_num falls back to its default on an unreadable value (no cast error)', fabula.setting_num('milk.round_kg', 25) = 25);
update fabula.settings set value = '25' where key = 'milk.round_kg';
select pg_temp.ck('C-02 every number setting the functions use has limits and a unit',
  not exists (select 1 from fabula.settings where key in ('milk.price_eur_kg', 'prod.vat_kg', 'approve.auto_po_max_eur', 'approve.auto_delay_min', 'ship.tolerance_pct',
              'trade.recurring_discount_pct', 'milk.round_kg', 'prod.yield_tolerance_pts', 'approve.milk_tolerance_pct') and (min_value is null or max_value is null or unit is null)));

-- ============================== D-06 / D-30 batch bounds ==============================
insert into fabula.milk_intake (id, intake_date, intake_time, supplier_id, milk_lot, qty_kg, temperature_c, accepted)
values ('70000000-0000-4000-a000-0000000098b1', pg_temp.today(), '06:30', '50000000-0000-4000-a000-0000000098f1', 'MN-1', 1000, 4, true);
select pg_temp.err(format($q$insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, started_at, source) values (%L, 'L20990101-A', %L, 3100, now(), 'tablet')$q$, pg_temp.today(), :'moz')) e_b1 \gset
select pg_temp.ck('D-06 a vat of 3100 kg (vat 310 kg) is refused, with the reason', :'e_b1' like 'Latte in caldaia 3100 kg: una caldaia ne tiene al massimo 341 kg%', :'e_b1');
insert into fabula.production_batches (id, batch_date, batch_lot, product_id, milk_in_kg, started_at, source, casaro_id)
values ('80000000-0000-4000-a000-0000000098b1', pg_temp.today(), 'L20990101-B', :'moz', 31, now(), 'tablet', :CAS);
insert into fabula.batch_milk_inputs (batch_id, milk_intake_id, qty_kg) values ('80000000-0000-4000-a000-0000000098b1', '70000000-0000-4000-a000-0000000098b1', 31);
insert into fabula.stock_moves (product_id, lot_number, qty, move_type, batch_id, source) values (:'rawmilk', 'MN-1', -31, 'production_in', '80000000-0000-4000-a000-0000000098b1', 'tablet');
select pg_temp.err($q$update fabula.production_batches set output_kg = 62, finished_at = now() where batch_lot = 'L20990101-B'$q$) e_b2 \gset
select pg_temp.ck('D-06 closing 62 kg from 31 kg of milk (200 %) is refused, naming both numbers', :'e_b2' = 'Resa 200 %: impossibile (al massimo 45 %). Controlla i kg di latte (31) e i kg prodotti (62).', :'e_b2');
select pg_temp.err($q$update fabula.production_batches set output_kg = 3100, finished_at = now() where batch_lot = 'L20990101-B'$q$) e_b3 \gset
select pg_temp.ck('D-06 10000 % (the old English overflow) is refused with the same Italian sentence', :'e_b3' like 'Resa 10000 %: impossibile%', :'e_b3');
-- the casaro fixes the milk kg with a reason (as the tablet does at the close), then closes
select pg_temp.as_user('00000000-0000-4000-a000-0000000098a2');
set role authenticated;
select pg_temp.err($q$select fabula.correct_batch_milk('L20990101-B', 310, '')$q$) e_b4 \gset
select pg_temp.err($q$select fabula.save_ops('[{"rpc":"correct_batch_milk","args":{"p_batch_lot":"L20990101-B","p_milk_kg":310,"p_reason":"scritto 31 invece di 310"}}]'::jsonb)$q$) e_b5 \gset
reset role;
select pg_temp.ck('D-06 correct_batch_milk needs a reason', :'e_b4' like 'Scrivi il motivo%', :'e_b4');
select pg_temp.ck('D-06 …the tablet can send it (save_ops) and the lot, its milk input and the raw-milk stock follow',
  :'e_b5' = '' and (select milk_in_kg from fabula.production_batches where batch_lot = 'L20990101-B') = 310
  and (select qty_kg from fabula.batch_milk_inputs where batch_id = '80000000-0000-4000-a000-0000000098b1') = 310
  and (select sum(qty) from fabula.stock_moves where product_id = :'rawmilk' and lot_number = 'MN-1' and move_type <> 'milk_intake') = -310, :'e_b5');
select pg_temp.ck('D-06 …with a correction record and a line in the lot notes',
  exists (select 1 from fabula.record_corrections where row_id = '80000000-0000-4000-a000-0000000098b1' and changes -> 'milk_in_kg' = '[31, 310]'::jsonb and corrected_by = 'Casaro N')
  and (select notes from fabula.production_batches where batch_lot = 'L20990101-B') like '%latte in caldaia corretto da Casaro N: 31 → 310 kg (scritto 31 invece di 310)%');
select pg_temp.err($q$update fabula.production_batches set output_kg = 15, finished_at = now() where batch_lot = 'L20990101-B'$q$) e_b6 \gset
select pg_temp.ck('D-06 a yield under the minimum (4,8 %) needs the reason of the loss', :'e_b6' like 'Resa 4,8 %: troppo bassa%se una parte è andata persa, scrivi cosa è successo.', :'e_b6');
select pg_temp.err($q$update fabula.production_batches set output_kg = 15, yield_note = 'metà cagliata persa: caldaia scesa di temperatura', finished_at = now() where batch_lot = 'L20990101-B'$q$) e_b7 \gset
select pg_temp.ck('D-06 …with the reason it closes', :'e_b7' = '' and (select output_kg from fabula.production_batches where batch_lot = 'L20990101-B') = 15, :'e_b7');
insert into fabula.production_batches (id, batch_date, batch_lot, product_id, milk_in_kg, started_at, source) values ('80000000-0000-4000-a000-0000000098b2', pg_temp.today(), 'L20990101-C', :'moz', 300, now(), 'tablet');
select pg_temp.err($q$update fabula.production_batches set output_kg = 75, finished_at = now() where batch_lot = 'L20990101-C'$q$) e_b8 \gset
select pg_temp.ck('D-06 a normal close (25 %) goes through', :'e_b8' = '', :'e_b8');
select pg_temp.err($q$select fabula.start_byproduct_batch('L20990101-C', 2000)$q$) e_b9 \gset
select pg_temp.ck('D-30 ricotta with 2000 kg of whey from a 300 kg vat is refused', :'e_b9' like 'Siero per la ricotta 2000 kg: non può superare il latte della caldaia L20990101-C (300 kg)%', :'e_b9');
select pg_temp.ck('D-30 …and nothing of it was written (no R-lot, whey not set)', not exists (select 1 from fabula.production_batches where batch_lot = 'R20990101-C')
  and (select whey_kg from fabula.production_batches where batch_lot = 'L20990101-C') is null);
select pg_temp.err($q$select fabula.start_byproduct_batch('L20990101-C', 200)$q$) e_b10 \gset
select pg_temp.err($q$update fabula.production_batches set output_kg = 40, finished_at = now() where batch_lot = 'R20990101-C'$q$) e_b11 \gset
select pg_temp.ck('D-06 ricotta: 40 kg from 200 kg of whey (20 %) is a normal close… ', :'e_b10' = '' and :'e_b11' = '', :'e_b10' || :'e_b11');
select pg_temp.as_user('00000000-0000-4000-a000-0000000098a3');
set role authenticated;
select pg_temp.err($q$select fabula.correct_batch_milk('L20990101-C', 290, 'prova del banco')$q$) e_b12 \gset
reset role;
select pg_temp.ck('D-06 a closed lot''s milk is not corrected by a counter profile', :'e_b12' like '%Permesso negato%' or :'e_b12' like '%serve%', :'e_b12');
set role anon;
select pg_temp.err($q$select fabula.correct_batch_milk('L20990101-C', 290, 'prova anonima')$q$) e_b13 \gset
reset role;
select pg_temp.ck('D-06 correct_batch_milk is not open to anonymous calls', :'e_b13' <> '', :'e_b13');

-- ============================== D-07 milk arrival ==============================
insert into fabula.milk_intake (id, intake_date, intake_time, supplier_id, milk_lot, qty_kg, temperature_c, accepted)
values ('70000000-0000-4000-a000-0000000098b2', pg_temp.today(), '07:00', '50000000-0000-4000-a000-0000000098f1', 'MN-2', 900, 10, true);
select pg_temp.ck('D-07 milk at 10 °C sent as «accepted» is rejected by the database, with the reason',
  (select not accepted and rejection_reason = 'temperatura 10 °C oltre il limite di 8 °C' from fabula.milk_intake where id = '70000000-0000-4000-a000-0000000098b2'),
  (select accepted || ' ' || coalesce(rejection_reason, '') from fabula.milk_intake where id = '70000000-0000-4000-a000-0000000098b2'));
select pg_temp.ck('D-07 …so it gives no raw-milk stock', not exists (select 1 from fabula.stock_moves where lot_number = 'MN-2' and qty > 0));
select pg_temp.as_user('00000000-0000-4000-a000-0000000098a2');
set role authenticated;
select pg_temp.err(format($q$select fabula.save_ops('[{"table":"milk_intake","row":{"intake_date":"%s","supplier_id":"50000000-0000-4000-a000-0000000098f1","milk_lot":"MN-3","qty_kg":900,"temperature_c":45.5}}]'::jsonb)$q$, pg_temp.today())) e_m1 \gset
select pg_temp.err(format($q$select fabula.save_ops('[{"table":"milk_intake","row":{"intake_date":"%s","supplier_id":"50000000-0000-4000-a000-0000000098f1","milk_lot":"MN-4","qty_kg":12000,"temperature_c":4}}]'::jsonb)$q$, pg_temp.today())) e_m2 \gset
select pg_temp.err(format($q$select fabula.save_ops('[{"table":"milk_intake","row":{"intake_date":"%s","supplier_id":"50000000-0000-4000-a000-0000000098f1","milk_lot":"MN-5","qty_kg":900,"temperature_c":4,"fat_pct":75}}]'::jsonb)$q$, pg_temp.today())) e_m3 \gset
reset role;
select pg_temp.ck('D-07 a milk temperature of 45,5 °C is refused on the tablet in Italian', :'e_m1' like 'Passo 1 di 1 (arrivo latte): Temperatura del latte impossibile%', :'e_m1');
select pg_temp.ck('D-07 12000 kg in one delivery is refused', :'e_m2' like '%Più di 5.000 kg di latte in una consegna%', :'e_m2');
select pg_temp.ck('D-07 fat 75 % (meant 7,5) is refused', :'e_m3' like '%Grasso del latte impossibile%', :'e_m3');

-- ============================== D-27 / B-14 recipe doses ==============================
select r.id rec_rennet from fabula.recipes r where r.finished_product_id = :'moz' and r.component_product_id = :'rennet' and r.valid_to is null \gset
select pg_temp.as_user('00000000-0000-4000-a000-0000000098a1');
set role authenticated;
select pg_temp.err(format($q$select fabula.update_recipe_dose(%L, 0.0025)$q$, :'rec_rennet')) e_r1 \gset
select pg_temp.err(format($q$select fabula.update_recipe_dose(%L, 0.0025, p_confirm => true)$q$, :'rec_rennet')) e_r2 \gset
select pg_temp.err(format($q$select fabula.update_recipe_dose(%L, 0.0003)$q$, :'rec_rennet')) e_r3 \gset
select pg_temp.err(format($q$select fabula.update_recipe_dose(%L, 0)$q$, :'rec_rennet')) e_r4 \gset
select pg_temp.err($q$select fabula.add_recipe_component('MOZ-DOP-KG', 'CON-CITRIC', 'per_kg_milk', 0)$q$) e_r5 \gset
select r.id rec_now from fabula.recipes r where r.finished_product_id = :'moz' and r.component_product_id = :'rennet' and r.valid_to is null \gset
select pg_temp.err(format($q$select fabula.update_recipe_dose(%L, 0.003, p_confirm => true, p_notes => 'caglio nuovo, più debole')$q$, :'rec_now')) e_r6 \gset
reset role;
select pg_temp.ck('D-27 a dose ×10 (0,00025 → 0,0025) asks for a confirmation (HINT confirm), with old and new',
  :'e_r1' like 'Caglio: la dose passa da 0,00025 a 0,0025 l, 10 volte di più. Controlla la virgola%|| hint: confirm', :'e_r1');
select pg_temp.ck('D-27 …confirmed but with no reason it is still refused', :'e_r2' like 'Scrivi il motivo%', :'e_r2');
select pg_temp.ck('D-27 a change within ×2 (0,00025 → 0,0003) needs no confirmation', :'e_r3' = '', :'e_r3');
select pg_temp.ck('D-27 a dose of 0 is refused (update and new component)', :'e_r4' like 'Dose non valida%' and :'e_r5' like 'Scrivi la dose%', :'e_r4' || ' / ' || :'e_r5');
select pg_temp.ck('D-27 …confirmed with a reason it saves, and the previous dose stays in the notes',
  :'e_r6' = '' and (select qty_per_unit = 0.003 and notes like '%0,0003 → 0,003: caglio nuovo, più debole%' from fabula.recipes where finished_product_id = :'moz' and component_product_id = :'rennet' and valid_to is null), :'e_r6');

-- ============================== D-20 units and recipe items ==============================
insert into fabula.products (sku, name, unit, kind) values ('CON-TEST-L', 'Prova litri', ' Litri ', 'consumable');
select pg_temp.ck('D-20 a unit written « Litri » is stored as l', (select unit from fabula.products where sku = 'CON-TEST-L') = 'l');
select pg_temp.err($q$insert into fabula.products (sku, name, unit, kind) values ('CON-TEST-X', 'Prova', '0,5 kg', 'consumable')$q$) e_u1 \gset
select pg_temp.err($q$update fabula.products set unit = 'ml' where sku = 'CON-RENNET'$q$) e_u2 \gset
select pg_temp.err($q$update fabula.products set active = false where sku = 'CON-RENNET'$q$) e_u3 \gset
select pg_temp.err($q$update fabula.products set track_stock = false where sku = 'CON-SALT'$q$) e_u4 \gset
select pg_temp.err($q$update fabula.products set unit = 'L' where sku = 'CON-RENNET'$q$) e_u5 \gset
select pg_temp.ck('D-20 a unit that is not a word is refused', :'e_u1' like 'Unità non valida%', :'e_u1');
select pg_temp.ck('D-20 the rennet in the Mozzarella recipe cannot change unit (l → ml), with the reason', :'e_u2' like '«Caglio» è nella ricetta di Mozzarella%', :'e_u2');
select pg_temp.ck('D-20 …nor be archived, nor stop being counted (salt)', :'e_u3' like '«Caglio» è nella ricetta%' and :'e_u4' like '«Sale marino» è nella ricetta%', :'e_u3' || ' / ' || :'e_u4');
select pg_temp.ck('D-20 «L» for an item in litres is the same unit: accepted', :'e_u5' = '' and (select unit from fabula.products where sku = 'CON-RENNET') = 'l', :'e_u5');

-- ============================== D-19 dosing ==============================
insert into fabula.production_batches (id, batch_date, batch_lot, product_id, milk_in_kg, started_at, source) values ('80000000-0000-4000-a000-0000000098b3', pg_temp.today(), 'L20990101-D', :'moz', 300, now(), 'tablet');
select pg_temp.err($q$select fabula.record_batch_consumable('L20990101-D', 'CON-RENNET', -0.09, 0.09)$q$) e_d1 \gset
select pg_temp.err($q$select fabula.record_batch_consumable('L20990101-D', 'CON-RENNET', 0.9, 0.09)$q$) e_d2 \gset
select pg_temp.err($q$select fabula.record_batch_consumable('L20990101-D', 'CON-RENNET', 0.9, 0.09, null, ' cg-2611 ', true)$q$) e_d3 \gset
select pg_temp.err($q$select fabula.record_batch_consumable('L20990101-D', 'CON-SALT', 0.8, 0.84, null, 'S-77')$q$) e_d4 \gset
select pg_temp.ck('D-19 a negative dose is refused', :'e_d1' like 'Quantità di Caglio non valida%', :'e_d1');
select pg_temp.ck('D-19 10 times the recipe asks for a confirmation (HINT confirm)', :'e_d2' like 'Caglio: 0,9 l contro 0,09 previsti dalla ricetta%|| hint: confirm', :'e_d2');
select pg_temp.ck('D-19 …confirmed it is recorded, with the lot of the pack (upper-case)',
  :'e_d3' = '' and (select lot_number from fabula.batch_consumables where batch_id = '80000000-0000-4000-a000-0000000098b3' and product_id = :'rennet') = 'CG-2611'
  and exists (select 1 from fabula.stock_moves where batch_id = '80000000-0000-4000-a000-0000000098b3' and product_id = :'rennet' and lot_number = 'CG-2611' and qty = -0.9), :'e_d3');
select pg_temp.ck('D-19 a normal dose needs nothing more', :'e_d4' = '', :'e_d4');
update fabula.production_batches set output_kg = 75, finished_at = now() where batch_lot = 'L20990101-D';
select pg_temp.err($q$select fabula.record_batch_consumable('L20990101-D', 'CON-CITRIC', 0.1, 0.1)$q$) e_d5 \gset
select pg_temp.ck('D-19 a closed lot takes no more doses', :'e_d5' like 'Il lotto L20990101-D è già chiuso%', :'e_d5');

-- ============================== D-18 goods receipt ==============================
insert into fabula.parties (id, type, legal_name, active) values ('50000000-0000-4000-a000-0000000098f2', 'supplier', 'Fornitore N', true) on conflict do nothing;
insert into fabula.purchase_orders (id, po_number, supplier_id, status) values ('90000000-0000-4000-a000-0000000098c1', 'PO-N-1', '50000000-0000-4000-a000-0000000098f2', 'sent');
insert into fabula.purchase_order_lines (purchase_order_id, product_id, qty_ordered, unit_price_eur, iva_rate) values ('90000000-0000-4000-a000-0000000098c1', :'rennet', 10, 4.10, 22);
insert into fabula.supplier_prices (supplier_id, product_id, price_eur, valid_from, source) values ('50000000-0000-4000-a000-0000000098f2', :'rennet', 4.10, pg_temp.today() - 30, 'listino');
select pg_temp.as_user('00000000-0000-4000-a000-0000000098a1');
set role authenticated;
select pg_temp.err(format($q$select fabula.receive_purchase_order('PO-N-1', '[{"sku":"CON-RENNET","qty":5,"expiry":"%s"}]'::jsonb)$q$, pg_temp.today() - 1)) e_g1 \gset
select pg_temp.err($q$select fabula.receive_purchase_order('PO-N-1', '[{"sku":"CON-RENNET","qty":100}]'::jsonb)$q$) e_g2 \gset
select pg_temp.err($q$select fabula.receive_purchase_order('PO-N-1', '[{"sku":"CON-RENNET","qty":10,"unit_price":410}]'::jsonb)$q$) e_g3 \gset
select pg_temp.err($q$select fabula.receive_purchase_order('PO-N-1', '[{"sku":"CON-RENNET","qty":10,"unit_price":4.30}]'::jsonb)$q$) e_g4 \gset
reset role;
select pg_temp.ck('D-18 expired goods are refused', :'e_g1' like 'Caglio scaduto il%apri una non conformità%', :'e_g1');
select pg_temp.ck('D-18 100 received on an order of 10 asks for a confirmation', :'e_g2' like 'Caglio: ricevuti 100 l, ne mancavano 10 (ordinati 10)%|| hint: confirm', :'e_g2');
select pg_temp.ck('D-18 a DDT price of 410 €/l (list 4,10) asks for a confirmation', :'e_g3' like 'Caglio: prezzo sul DDT 410 €/l contro 4,1 €/l in listino%|| hint: confirm', :'e_g3');
select pg_temp.ck('D-18 …nothing was received meanwhile; a normal receipt (4,30) goes through and records the new price',
  :'e_g4' = '' and (select qty_received from fabula.purchase_order_lines where purchase_order_id = '90000000-0000-4000-a000-0000000098c1') = 10
  and exists (select 1 from fabula.supplier_prices where supplier_id = '50000000-0000-4000-a000-0000000098f2' and price_eur = 4.30 and source = 'ddt'), :'e_g4');

-- ============================== FARM-07 ==============================
select fabula.setting_text('milk.farm_token') ftok \gset
update fabula.settings set value = 'abcdef0123456789abcdef0123456789' where key = 'milk.farm_token' and coalesce(value, '') = '';
select pg_temp.ck('FARM-07 the farm page gets the CCP 1a limits (alert 6, rejection 8 °C)',
  (select (x -> 'milk_temp' ->> 'warn_max')::numeric = 6 and (x -> 'milk_temp' ->> 'max')::numeric = 8 from fabula.farm_milk_orders(fabula.setting_text('milk.farm_token')) x),
  (select (fabula.farm_milk_orders(fabula.setting_text('milk.farm_token')) -> 'milk_temp')::text));

-- ============================== D-23 trade prices ==============================
insert into fabula.trade_products (variant_id, product_id, title, variant_title, kg_per_unit, unit_label, base_price_eur, trade_price_eur, min_qty, step_qty)
values ('gid://numbers/1', :'moz', 'Mozzarella', 'N', 1, 'kg', 14, 11.5, 1, 1);
select pg_temp.err($q$update fabula.trade_products set trade_price_eur = 1150 where variant_id = 'gid://numbers/1'$q$) e_t1 \gset
select pg_temp.err($q$update fabula.trade_products set trade_price_eur = 0 where variant_id = 'gid://numbers/1'$q$) e_t2 \gset
select pg_temp.err($q$update fabula.trade_products set step_qty = 0.5 where variant_id = 'gid://numbers/1'$q$) e_t3 \gset
select pg_temp.err($q$update fabula.trade_products set base_price_eur = 10 where variant_id = 'gid://numbers/1'$q$) e_t4 \gset
update fabula.trade_products set base_price_eur = 14 where variant_id = 'gid://numbers/1';
select pg_temp.err($q$insert into fabula.trade_price_tiers (variant_id, min_qty, price_eur) values ('gid://numbers/1', 20, 0)$q$) e_t5 \gset
select pg_temp.err($q$insert into fabula.trade_price_tiers (variant_id, min_qty, price_eur) values ('gid://numbers/1', 20, 115)$q$) e_t6 \gset
select pg_temp.err($q$insert into fabula.trade_price_tiers (variant_id, min_qty, discount_pct) values ('gid://numbers/1', 20, 60)$q$) e_t7 \gset
select pg_temp.ck('D-23 a reserved price of 1150 € (meant 11,50) is refused', :'e_t1' like 'Prezzo riservato di Mozzarella N a 1150 €: è più alto del prezzo base (14 €)%', :'e_t1');
select pg_temp.ck('D-23 …and 0 €', :'e_t2' like '%scrivi un prezzo maggiore di zero%', :'e_t2');
select pg_temp.ck('D-23 a step of 0,5 is refused: Shopify sells whole pieces', :'e_t3' like 'Minimo e passo di Mozzarella N vanno in unità intere%', :'e_t3');
select pg_temp.ck('D-23 the Shopify sync changing only the base price is never stopped', :'e_t4' = '', :'e_t4');
select pg_temp.ck('D-23 tiers: 0 €, a price above the reserved one and 60 % are refused',
  :'e_t5' like '%maggiore di zero%' and :'e_t6' like 'Prezzo dello scaglione 115 €%' and :'e_t7' like 'Sconto dello scaglione 60 %%', :'e_t5' || ' / ' || :'e_t6' || ' / ' || :'e_t7');

-- ============================== TRADE-01 quantities ==============================
create or replace function pg_temp.dday(n int) returns date language sql as
$$ select g::date from generate_series(fabula.trade_now_rome()::date + 3, fabula.trade_now_rome()::date + 20, interval '1 day') g
   where fabula.trade_is_delivery_day(g::date) order by g offset n - 1 limit 1 $$;
insert into fabula.parties (id, type, legal_name, active, trade_status) values ('50000000-0000-4000-a000-0000000098e1', 'customer', 'Pizzeria N', true, 'approved');
select pg_temp.dday(1) d1, extract(isodow from pg_temp.dday(1))::int w1 \gset
select pg_temp.err(format($q$select fabula.trade_save_schedule('50000000-0000-4000-a000-0000000098e1', '{"days":{"%s":{"lines":{"gid://numbers/1":2.5}}}}'::jsonb)$q$, :'w1')) e_q1 \gset
select pg_temp.ck('TRADE-01 2,5 kg is refused: a whole number of pieces (it was rounded to 3 on the Shopify invoice)', :'e_q1' like 'La quantità di Mozzarella N va a multipli di 1 kg (hai scritto 2,5)%', :'e_q1');
select pg_temp.err(format($q$select fabula.trade_save_schedule('50000000-0000-4000-a000-0000000098e1', '{"days":{"%s":{"lines":{"gid://numbers/1":200}}}}'::jsonb)$q$, :'w1')) e_q2 \gset
select pg_temp.ck('TRADE-01 200 kg in one delivery is refused: over 150 kg the customer calls', :'e_q2' like '%: 200 kg. Dal portale si arriva a 150 kg per consegna%', :'e_q2');
select pg_temp.err(format($q$select fabula.trade_save_schedule('50000000-0000-4000-a000-0000000098e1', '{"days":{"%s":{"lines":{"gid://numbers/1":5}}}}'::jsonb)$q$, :'w1')) e_q3 \gset
select pg_temp.ck('TRADE-01 a first plan of 5 kg saves with no question', :'e_q3' = '', :'e_q3');
select pg_temp.st(format($q$select fabula.trade_save_schedule('50000000-0000-4000-a000-0000000098e1', '{"can_confirm":true,"days":{"%s":{"lines":{"gid://numbers/1":50}}}}'::jsonb)$q$, :'w1')) s_q4 \gset
select pg_temp.err(format($q$select fabula.trade_save_schedule('50000000-0000-4000-a000-0000000098e1', '{"can_confirm":true,"days":{"%s":{"lines":{"gid://numbers/1":50}}}}'::jsonb)$q$, :'w1')) e_q4 \gset
select pg_temp.ck('TRADE-01 50 kg where the usual is 5 asks «Confermi?» (P0001, which the portal function relays)',
  :'s_q4' = 'P0001' and :'e_q4' like '%: 50 kg, più di 3 volte il solito (5 kg). Confermi? || hint: confirm', :'s_q4' || ' ' || :'e_q4');
select pg_temp.ck('TRADE-01 …and the plan was not changed', (select qty from fabula.trade_schedule_lines where customer_id = '50000000-0000-4000-a000-0000000098e1' and weekday = :w1) = 5);
select pg_temp.err(format($q$select fabula.trade_save_schedule('50000000-0000-4000-a000-0000000098e1', '{"can_confirm":true,"confirm":true,"days":{"%s":{"lines":{"gid://numbers/1":50}}}}'::jsonb)$q$, :'w1')) e_q5 \gset
select pg_temp.ck('TRADE-01 …confirmed it saves', :'e_q5' = '' and (select qty from fabula.trade_schedule_lines where customer_id = '50000000-0000-4000-a000-0000000098e1' and weekday = :w1) = 50, :'e_q5');
select pg_temp.err(format($q$select fabula.trade_save_schedule('50000000-0000-4000-a000-0000000098e1', '{"days":{"%s":{"lines":{"gid://numbers/1":20}}}}'::jsonb)$q$, :'w1')) e_q6 \gset
select pg_temp.ck('TRADE-01 20 kg (under the 25 kg threshold) for a usual of 50 needs nothing', :'e_q6' = '', :'e_q6');
-- one-day change on the plan of 20 kg
select pg_temp.err(format($q$select fabula.trade_add_exception('50000000-0000-4000-a000-0000000098e1', '{"kind":"override","date_from":"%s","variant_id":"gid://numbers/1","qty":7.5}'::jsonb)$q$, :'d1')) e_q7 \gset
select pg_temp.err(format($q$select fabula.trade_add_exception('50000000-0000-4000-a000-0000000098e1', '{"kind":"override","date_from":"%s","variant_id":"gid://numbers/1","qty":90,"can_confirm":true}'::jsonb)$q$, :'d1')) e_q8 \gset
select pg_temp.err(format($q$select fabula.trade_add_exception('50000000-0000-4000-a000-0000000098e1', '{"kind":"override","date_from":"%s","variant_id":"gid://numbers/1","qty":90,"confirm":true,"can_confirm":true}'::jsonb)$q$, :'d1')) e_q9 \gset
select pg_temp.ck('TRADE-01 a one-day change of 7,5 kg is refused (step)', :'e_q7' like 'La quantità di Mozzarella N va a multipli di 1 kg%', :'e_q7');
select pg_temp.ck('TRADE-01 a one-day change to 90 kg (usual 20) asks «Confermi?» naming the date',
  :'e_q8' like format('Consegna del %s: 90 kg, più di 3 volte il solito (20 kg). Confermi?%%', to_char(:'d1'::date, 'DD/MM')), :'e_q8');
select pg_temp.ck('TRADE-01 …confirmed it saves', :'e_q9' = '' and exists (select 1 from fabula.trade_exceptions where customer_id = '50000000-0000-4000-a000-0000000098e1' and kind = 'override' and qty = 90 and cancelled_at is null), :'e_q9');
-- D-23: the price never goes above the list or below zero
insert into fabula.trade_price_tiers (variant_id, min_qty, price_eur) values ('gid://numbers/1', 10, 11);
alter table fabula.trade_price_tiers disable trigger trade_price_tiers_guard;
update fabula.trade_price_tiers set price_eur = 50 where variant_id = 'gid://numbers/1' and min_qty = 10;
alter table fabula.trade_price_tiers enable trigger trade_price_tiers_guard;
select pg_temp.ck('D-23 a tier written above the list (around the check) is never charged above the list',
  (select (x ->> 'final_price')::numeric <= 11.5 from fabula.trade_price('50000000-0000-4000-a000-0000000098e1', 'gid://numbers/1', 20) x),
  (select fabula.trade_price('50000000-0000-4000-a000-0000000098e1', 'gid://numbers/1', 20)::text));

-- ============================== review 13/10: who is held to what ==============================
-- an older portal page (no can_confirm) is never stuck on a question it cannot answer; the maximum still holds
insert into fabula.parties (id, type, legal_name, active, trade_status) values ('50000000-0000-4000-a000-0000000098e2', 'customer', 'Hotel N', true, 'approved');
select pg_temp.err(format($q$select fabula.trade_save_schedule('50000000-0000-4000-a000-0000000098e2', '{"days":{"%s":{"lines":{"gid://numbers/1":60}}}}'::jsonb)$q$, :'w1')) e_r1 \gset
select pg_temp.err(format($q$select fabula.trade_save_schedule('50000000-0000-4000-a000-0000000098e2', '{"days":{"%s":{"lines":{"gid://numbers/1":160}}}}'::jsonb)$q$, :'w1')) e_r2 \gset
select pg_temp.ck('TRADE-01 a page that cannot answer «Confermi?» (older portal) is not asked: 60 kg saves', :'e_r1' = '', :'e_r1');
select pg_temp.ck('TRADE-01 …but 160 kg is still refused for a customer', :'e_r2' like '%160 kg. Dal portale si arriva a 150 kg%', :'e_r2');
-- the dairy's staff are not held to the portal maximum; a plan above it can then be edited on other days and lowered
select pg_temp.err(format($q$select fabula.trade_save_schedule('50000000-0000-4000-a000-0000000098e2', '{"can_confirm":true,"confirm":true,"days":{"%s":{"lines":{"gid://numbers/1":200}}}}'::jsonb, 'staff')$q$, :'w1')) e_r3 \gset
select pg_temp.ck('TRADE-01 staff (Console → Ingrosso) can book 200 kg, after confirming', :'e_r3' = '', :'e_r3');
select case when :w1 = 6 then 5 else :w1 + 1 end w2 \gset
select pg_temp.err(format($q$select fabula.trade_save_schedule('50000000-0000-4000-a000-0000000098e2', '{"can_confirm":true,"days":{"%s":{"lines":{"gid://numbers/1":200}},"%s":{"lines":{"gid://numbers/1":10}}}}'::jsonb)$q$, :'w1', :'w2')) e_r4 \gset
select pg_temp.ck('TRADE-01 the customer can then add another day without the 200 kg day (unchanged) being refused', :'e_r4' = '', :'e_r4');
select pg_temp.err(format($q$select fabula.trade_add_exception('50000000-0000-4000-a000-0000000098e2', '{"kind":"override","date_from":"%s","variant_id":"gid://numbers/1","qty":180,"can_confirm":true}'::jsonb)$q$, :'d1')) e_r5 \gset
select pg_temp.ck('TRADE-01 …and lower it for one day (180 kg) with no question and no refusal', :'e_r5' = '', :'e_r5');
-- the operator, not the shared login, signs a milk correction (audit A-01)
insert into fabula.production_batches (id, batch_date, batch_lot, product_id, milk_in_kg, started_at, source, casaro_id) values ('80000000-0000-4000-a000-0000000098b4', pg_temp.today(), 'L20990101-E', :'moz', 30, now(), 'tablet', :CAS);
insert into fabula.batch_milk_inputs (batch_id, milk_intake_id, qty_kg) values ('80000000-0000-4000-a000-0000000098b4', '70000000-0000-4000-a000-0000000098b1', 30);
select pg_temp.as_user('00000000-0000-4000-a000-0000000098a1');
set role authenticated;
select pg_temp.err(format($q$select fabula.correct_batch_milk('L20990101-E', 300, 'zero mancante', %L)$q$, :CAS)) e_r6 \gset
reset role;
select pg_temp.ck('D-06 on a shared login the correction is signed by the operator the tablet sends',
  :'e_r6' = '' and (select corrected_by from fabula.record_corrections where row_id = '80000000-0000-4000-a000-0000000098b4') = 'Casaro N', :'e_r6');
-- a closed lot corrected to a low yield can say what was lost
select pg_temp.as_user('00000000-0000-4000-a000-0000000098a1');
set role authenticated;
select pg_temp.err($q$select fabula.correct_record('production_batches', '80000000-0000-4000-a000-0000000098b2', '{"output_kg": 20}'::jsonb, 'pesato male')$q$) e_r7 \gset
select pg_temp.err($q$select fabula.correct_record('production_batches', '80000000-0000-4000-a000-0000000098b2', '{"output_kg": 20, "yield_note": "cagliata persa in filatura"}'::jsonb, 'pesato male')$q$) e_r8 \gset
reset role;
select pg_temp.ck('D-06 Correggi on a closed lot to 6,7 % asks what was lost…', :'e_r7' like 'Resa 6,7 %: troppo bassa%', :'e_r7');
select pg_temp.ck('D-06 …and takes it (yield_note)', :'e_r8' = '' and (select yield_note from fabula.production_batches where id = '80000000-0000-4000-a000-0000000098b2') = 'cagliata persa in filatura', :'e_r8');
-- goods receipt: the price is compared with the order's (what the tablet shows), not an older list
insert into fabula.purchase_orders (id, po_number, supplier_id, status) values ('90000000-0000-4000-a000-0000000098c2', 'PO-N-2', '50000000-0000-4000-a000-0000000098f2', 'sent');
insert into fabula.purchase_order_lines (purchase_order_id, product_id, qty_ordered, unit_price_eur, iva_rate) values ('90000000-0000-4000-a000-0000000098c2', :'rennet', 10, 8, 22);
select pg_temp.as_user('00000000-0000-4000-a000-0000000098a1');
set role authenticated;
select pg_temp.err($q$select fabula.receive_purchase_order('PO-N-2', '[{"sku":"CON-RENNET","qty":10,"unit_price":8}]'::jsonb)$q$) e_r9 \gset
reset role;
select pg_temp.ck('D-18 a DDT price equal to the order (8 €, list 4,30) needs no confirmation', :'e_r9' = '', :'e_r9');
-- seeds and legacy data
select pg_temp.err($q$insert into fabula.settings (key, value) values ('milk.price_eur_kg', '17') on conflict (key) do nothing$q$) e_r10 \gset
select pg_temp.ck('C-02 a seed «on conflict do nothing» on an existing key never aborts (the row stays as it is)', :'e_r10' = '' and (select value from fabula.settings where key = 'milk.price_eur_kg') = '1.80', :'e_r10');
alter table fabula.products disable trigger products_guard;
insert into fabula.products (sku, name, unit, kind) values ('CON-LEGACY', 'Prova vecchia unità', 'conf. 100', 'consumable');
alter table fabula.products enable trigger products_guard;
select pg_temp.err($q$update fabula.products set unit = 'conf. 100', active = false where sku = 'CON-LEGACY'$q$) e_r11 \gset
select pg_temp.ck('D-20 an old item with an odd unit can still be edited and archived (the unit stays)', :'e_r11' = '' and (select unit || '|' || active from fabula.products where sku = 'CON-LEGACY') = 'conf. 100|false', :'e_r11');
-- a bot (API, service role) changing a high-impact setting reaches the bell
select set_config('request.jwt.claims', '{"role":"service_role"}', false);
update fabula.settings set value = '1.75' where key = 'milk.price_eur_kg';
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('C-02 a bot changing the milk price is reported as «Un bot o il sistema»',
  exists (select 1 from fabula.bot_messages where agent = 'configurazione' and body like 'Un bot o il sistema ha cambiato «Prezzo del latte%1,8 €/kg → 1,75 €/kg%'));
