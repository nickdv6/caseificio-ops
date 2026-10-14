-- v1.03 secrets hidden (audit C-05), the Masseria's two links (FARM-04), lot labels reprinted from the database (PRINT-08) · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh a_test
--   su postgres -c "psql -d a_test -f tools/go-live/drill/prod-test/test_v103_security_labels.sql" | grep -E "PASS|FAIL"
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as
$$ declare h text; begin execute p_sql; return ''; exception when others then get stacked diagnostics h = pg_exception_hint; return sqlerrm || case when coalesce(h, '') <> '' then ' || hint: ' || h else '' end; end $$;
create or replace function pg_temp.as_user(p_sub text) returns void language sql as
$$ select set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_sub), false) $$;
insert into fabula.staff (id, full_name, role, app_role, active, auth_user_id) values
  ('10000000-0000-4000-a000-000000103a01', 'Titolare V', 'owner', 'titolare', true, '00000000-0000-4000-a000-000000103a01'),
  ('10000000-0000-4000-a000-000000103a02', 'Ufficio V', 'operaio', 'amministrazione', true, '00000000-0000-4000-a000-000000103a02'),
  ('10000000-0000-4000-a000-000000103a03', 'Banco V', 'commesso', 'banco', true, '00000000-0000-4000-a000-000000103a03'),
  ('10000000-0000-4000-a000-000000103a04', 'Casaro V', 'casaro', 'produzione', true, '00000000-0000-4000-a000-000000103a04'),
  ('10000000-0000-4000-a000-000000103a05', 'Marketing V', 'operaio', 'marketing', true, '00000000-0000-4000-a000-000000103a05'),
  ('10000000-0000-4000-a000-000000103a06', 'Resp V', 'casaro', 'resp_produzione', true, '00000000-0000-4000-a000-000000103a06')
on conflict do nothing;
\set tit '00000000-0000-4000-a000-000000103a01'
\set uff '00000000-0000-4000-a000-000000103a02'
\set ban '00000000-0000-4000-a000-000000103a03'
\set cas '00000000-0000-4000-a000-000000103a04'
\set mkt '00000000-0000-4000-a000-000000103a05'
\set rsp '00000000-0000-4000-a000-000000103a06'

-- ============================== C-05 · secret settings ==============================
select pg_temp.ck('C-05 the three secret settings exist and are 32 hex characters',
  (select count(*) from fabula.settings where fabula.secret_setting(key) and value ~ '^[0-9a-f]{32}$') = 3
  and (select value from fabula.settings where key = 'milk.farm_token') <> (select value from fabula.settings where key = 'milk.farm_ship_token'));
select value tok_full from fabula.settings where key = 'milk.farm_token' \gset
select value tok_qr from fabula.settings where key = 'milk.farm_ship_token' \gset

select pg_temp.as_user(:'ban');
set role authenticated;
select count(*) n_ban from fabula.settings where key in ('milk.farm_token', 'milk.farm_ship_token', 'trade.job_secret') \gset
select count(*) n_ban_all from fabula.settings \gset
select coalesce(fabula._setting('milk.farm_token'), 'null') || '/' || coalesce(fabula._setting('trade.job_secret'), 'null') s_ban \gset
select coalesce(fabula._setting('company.name'), 'null') s_ban_ok \gset
select coalesce(fabula.setting_text('milk.farm_token'), 'null') s_ban_txt \gset
reset role;
select pg_temp.ck('C-05 a counter login reads every other setting but none of the secrets (table, _setting, setting_text)',
  :n_ban = 0 and :n_ban_all > 50 and :'s_ban' = 'null/null' and :'s_ban_ok' <> 'null' and :'s_ban_txt' = 'null',
  :n_ban || ' / ' || :n_ban_all || ' / ' || :'s_ban' || ' / ' || :'s_ban_txt');

select pg_temp.as_user(:'tit');
set role authenticated;
select count(*) n_tit from fabula.settings where fabula.secret_setting(key) \gset
select pg_temp.err($q$update fabula.settings set value = 'masseria2027' where key = 'milk.farm_token'$q$) e_up \gset
with u as (update fabula.settings set value = repeat('a', 32) where key = 'milk.farm_token' returning 1) select count(*) n_up from u \gset
select pg_temp.err($q$insert into fabula.settings (key, value, description, data_type) values ('trade.job_secret', repeat('b', 32), 'x', 'text') on conflict (key) do update set value = excluded.value$q$) e_ins \gset
with d as (delete from fabula.settings where key = 'trade.job_secret' returning 1) select count(*) n_del from d \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('C-05 not even the titolare reads, changes, adds or deletes a secret through the API',
  :n_tit = 0 and :'e_up' = '' and :n_up = 0 and :'e_ins' like '%row-level security%' and :n_del = 0
  and (select value from fabula.settings where key = 'milk.farm_token') = :'tok_full'
  and exists (select 1 from fabula.settings where key = 'trade.job_secret'), :'e_ins');

select pg_temp.err($q$update fabula.settings set value = 'masseria2027' where key = 'milk.farm_token'$q$) e_fmt1 \gset
select pg_temp.err(format($q$update fabula.settings set value = %L where key = 'milk.farm_ship_token'$q$, :'tok_full')) e_fmt2 \gset
select pg_temp.ck('C-05 a secret must be 32-64 hex characters, and the two Masseria keys must differ (even from the SQL editor)',
  :'e_fmt1' like 'La chiave «milk.farm_token» deve essere di 32-64 caratteri esadecimali%' and :'e_fmt2' = 'Il link della Masseria e il QR delle spedizioni devono avere chiavi diverse',
  :'e_fmt1' || ' / ' || :'e_fmt2');

update fabula.settings set value = upper(repeat('c', 32)) where key = 'trade.job_secret';
update fabula.settings set value = 'Caseificio V' where key = 'company.name';
select pg_temp.ck('C-05 Registro modifiche: a secret change is recorded without its value; other settings keep theirs',
  (select old_data ->> 'value' = '••••' and new_data ->> 'value' = '••••' and changed = array['value'] from fabula.audit_log
    where table_name = 'settings' and row_key = 'trade.job_secret' order by at desc limit 1)
  and (select value from fabula.settings where key = 'trade.job_secret') = repeat('c', 32)
  and (select new_data ->> 'value' from fabula.audit_log where table_name = 'settings' and row_key = 'company.name' order by at desc limit 1) = 'Caseificio V'
  and not exists (select 1 from fabula.audit_log where table_name = 'settings' and fabula.secret_setting(row_key)
                   and (coalesce(old_data ->> 'value', '••••') <> '••••' or coalesce(new_data ->> 'value', '••••') <> '••••')));
update fabula.settings set value = (select :'tok_full') where key = 'milk.farm_token';

-- ============================== C-05 · wholesale customers' portal keys ==============================
insert into fabula.parties (id, type, legal_name, email, active, trade_status, is_wholesale, portal_token, payment_terms_days)
values ('50000000-0000-4000-a000-000000103b01', 'customer', 'Pizzeria V', 'v@example.com', true, 'approved', true, repeat('d', 32), 30) on conflict do nothing;
select pg_temp.as_user(:'ban');
set role authenticated;
select pg_temp.err($q$select portal_token from fabula.parties limit 1$q$) e_pt1 \gset
select pg_temp.err($q$select * from fabula.parties limit 1$q$) e_pt2 \gset
select count(*) n_pt from fabula.parties where legal_name = 'Pizzeria V' \gset
select pg_temp.err($q$select * from fabula.v_parties_editor limit 1$q$) e_pt3 \gset
select coalesce((select x ->> 'link' from jsonb_array_elements(fabula.trade_customers()) x where x ->> 'name' = 'Pizzeria V'), 'none') l_ban \gset
reset role;
select pg_temp.ck('C-05 a counter login reads customers but not their portal key (the editor view still works)',
  :'e_pt1' like 'permission denied%' and :'e_pt2' like 'permission denied%' and :n_pt = 1 and :'e_pt3' = '' and :'l_ban' = 'none',
  :'e_pt1' || ' / ' || :'e_pt2' || ' / ' || :'e_pt3' || ' / ' || :'l_ban');
select pg_temp.ck('C-05 every other customer column stays readable by logins (a new column must be granted too)',
  not exists (select 1 from information_schema.columns c where c.table_schema = 'fabula' and c.table_name = 'parties' and c.column_name <> 'portal_token'
               and not has_column_privilege('authenticated', 'fabula.parties', c.column_name, 'SELECT'))
  and not has_column_privilege('authenticated', 'fabula.parties', 'portal_token', 'SELECT')
  and not has_table_privilege('anon', 'fabula.parties', 'SELECT'));

select pg_temp.as_user(:'tit');
set role authenticated;
select pg_temp.err($q$update fabula.parties set payment_terms_days = 45 where legal_name = 'Pizzeria V' returning *$q$) e_pt6 \gset
select pg_temp.err($q$update fabula.parties set portal_token = repeat('e', 32) where legal_name = 'Pizzeria V'$q$) e_pt4 \gset
with u as (update fabula.parties set payment_terms_days = 60 where legal_name = 'Pizzeria V' returning id) select count(*) n_pt5 from u \gset
select (fabula.trade_staff_action('50000000-0000-4000-a000-000000103b01', 'new_link', '{}'::jsonb)) ->> 'token' new_tok \gset
select coalesce((select x ->> 'link' from jsonb_array_elements(fabula.trade_customers()) x where x ->> 'name' = 'Pizzeria V'), 'none') l_tit \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('C-05 an update that asks every column back («select=*») is refused: the app asks back only the key it matched (ui.js upd)',
  :'e_pt6' like 'permission denied%', :'e_pt6');
select pg_temp.ck('C-05 the key is changed only by Ingrosso «Nuovo link»; other edits and the manager''s link work as before',
  :'e_pt4' = 'Il link del portale si cambia solo da Ingrosso → scheda del cliente → «Nuovo link»' and :n_pt5 = 1
  and (select portal_token from fabula.parties where legal_name = 'Pizzeria V') = :'new_tok' and :'new_tok' <> repeat('d', 32)
  and :'l_tit' like '%/pages/professionisti?t=' || :'new_tok', :'e_pt4' || ' / ' || :'l_tit');

-- ============================== agent_runs: read by logins, written only by the bots ==============================
select pg_temp.as_user(:'tit');
set role authenticated;
select pg_temp.err($q$insert into fabula.agent_runs (agent, finished_at, status, summary) values ('daily_brief', now(), 'ok', 'finto')$q$) e_ar1 \gset
select pg_temp.err($q$update fabula.agent_runs set status = 'ok'$q$) e_ar2 \gset
select pg_temp.err($q$select count(*) from fabula.agent_runs$q$) e_ar3 \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.err($q$insert into fabula.agent_runs (agent, finished_at, status, summary) values ('daily_brief', now(), 'ok', 'bot vero')$q$) e_ar4 \gset
select pg_temp.ck('agent_runs: a login reads the runs but cannot add or change one; the bots (database role) still can',
  :'e_ar1' like 'permission denied%' and :'e_ar2' like 'permission denied%' and :'e_ar3' = '' and :'e_ar4' = ''
  and not exists (select 1 from fabula.agent_runs where summary = 'finto'), :'e_ar1' || ' / ' || :'e_ar2');

-- ============================== FARM-04 · two links ==============================
select pg_temp.ck('FARM-04 the office is reminded once to print the new poster and change the full link',
  (select count(*) from fabula.bot_messages where agent = 'configurazione' and title = 'Masseria: stampa il nuovo QR e cambia il link') = 1);
update fabula.settings set value = 'Mario, Luca;  mario , Gianni' where key = 'milk.farm_people';
select pg_temp.ck('FARM-04 «Chi spedisce»: the names of the setting, once each, in order',
  (select fabula._farm_people()) = '["Mario", "Luca", "Gianni"]'::jsonb, (select fabula._farm_people())::text);
select fabula.farm_milk_orders(:'tok_full') o_full \gset
select fabula.farm_milk_orders(:'tok_qr') o_qr \gset
select pg_temp.ck('FARM-04 the full link sees orders and history, the QR only today and no orders ahead; a wrong or short key nothing',
  :'o_full'::jsonb ->> 'scope' = 'full' and :'o_full'::jsonb ? 'month' and :'o_full'::jsonb ? 'pending'
  and :'o_qr'::jsonb ->> 'scope' = 'qr' and not (:'o_qr'::jsonb ? 'month') and :'o_qr'::jsonb -> 'pending' = '[]'::jsonb
  and :'o_qr'::jsonb -> 'people' = '["Mario", "Luca", "Gianni"]'::jsonb
  and fabula.farm_milk_orders('masseria2027') is null and fabula.farm_milk_orders(left(:'tok_full', 16)) is null);

select fabula.farm_milk_ship(:'tok_qr', 1040, 4, null, null, true, '  Mario  ') s_qr \gset
select fabula.farm_milk_ship(:'tok_full', 980, 4, null, null, true, 'Luca') s_full \gset
select fabula.farm_milk_ship(:'tok_full', 970, 4, null, null, true) s_old \gset
select pg_temp.ck('FARM-04 each load records who sent it and from which link (an older call without the name still works)',
  (select recorded_by = 'Mario' and source = 'farm_qr' from fabula.milk_shipments where milk_lot = :'s_qr'::jsonb ->> 'milk_lot')
  and (select recorded_by = 'Luca' and source = 'farm_page' from fabula.milk_shipments where milk_lot = :'s_full'::jsonb ->> 'milk_lot')
  and (select recorded_by is null from fabula.milk_shipments where milk_lot = :'s_old'::jsonb ->> 'milk_lot')
  and :'s_qr'::jsonb ->> 'recorded_by' = 'Mario', :'s_qr' || ' / ' || :'s_full');
select fabula.farm_milk_orders(:'tok_qr') o_qr2 \gset
select pg_temp.ck('FARM-04 the QR sees today''s loads with who sent them, and may correct only its own',
  jsonb_array_length(:'o_qr2'::jsonb -> 'shipments') = 3
  and (select bool_and((x ->> 'can_amend')::boolean = (x ->> 'source' = 'farm_qr')) from jsonb_array_elements(:'o_qr2'::jsonb -> 'shipments') x)
  and exists (select 1 from jsonb_array_elements(:'o_qr2'::jsonb -> 'shipments') x where x ->> 'recorded_by' = 'Mario'));

select pg_temp.err(format($q$select fabula.farm_milk_amend(%L, %L, 1000, false, 'peso sbagliato', 'Mario')$q$, :'tok_qr', :'s_full'::jsonb ->> 'milk_lot')) e_am1 \gset
select pg_temp.err(format($q$select fabula.farm_milk_amend(%L, %L, 1050, false, 'peso sbagliato', 'Mario')$q$, :'tok_qr', :'s_qr'::jsonb ->> 'milk_lot')) e_am2 \gset
update fabula.milk_shipments set shipped_at = now() - interval '3 hours' where milk_lot = :'s_qr'::jsonb ->> 'milk_lot';
select pg_temp.err(format($q$select fabula.farm_milk_amend(%L, %L, 1060, false, 'peso sbagliato', 'Mario')$q$, :'tok_qr', :'s_qr'::jsonb ->> 'milk_lot')) e_am3 \gset
select pg_temp.err(format($q$select fabula.farm_milk_amend(%L, %L, 1060, false, 'peso sbagliato', 'Gianni')$q$, :'tok_full', :'s_qr'::jsonb ->> 'milk_lot')) e_am4 \gset
select pg_temp.ck('FARM-04 the QR corrects its own load within 2 hours only; the full link any load in transit; the dairy is told who',
  :'e_am1' like 'Dal QR si corregge solo una spedizione registrata dal QR nelle ultime 2 ore%' and :'e_am2' = '' and :'e_am3' like 'Dal QR si corregge solo%' and :'e_am4' = ''
  and (select kg from fabula.milk_shipments where milk_lot = :'s_qr'::jsonb ->> 'milk_lot') = 1060
  and exists (select 1 from fabula.bot_messages where agent = 'masseria' and body like 'La Masseria (Mario) ha corretto la spedizione%')
  and exists (select 1 from fabula.bot_messages where agent = 'masseria' and body like 'La Masseria (Gianni) ha corretto la spedizione%'),
  :'e_am1' || ' / ' || :'e_am2' || ' / ' || :'e_am3' || ' / ' || :'e_am4');

insert into fabula.milk_plans (plan_date, status, milk_kg) values ((now() at time zone 'Europe/Rome')::date + 1, 'approved', 1100);
select pg_temp.ck('FARM-04 «Visto» on an order: only from the full link',
  fabula.farm_milk_seen(:'tok_qr', (now() at time zone 'Europe/Rome')::date + 1) = false
  and fabula.farm_milk_seen(:'tok_full', (now() at time zone 'Europe/Rome')::date + 1) = true);

select pg_temp.as_user(:'uff');
set role authenticated;
select coalesce(fabula.farm_links()::text, 'null') fl_uff \gset
select coalesce(fabula.farm_order_link(), 'null') fo_uff \gset
select pg_temp.err($q$select fabula.farm_link_rotate('qr')$q$) e_rot_uff \gset
select pg_temp.err($q$select fabula._farm_scope('x')$q$) e_scope \gset
reset role;
select pg_temp.as_user(:'rsp');
set role authenticated;
select coalesce(fabula.farm_order_link(), 'null') fo_rsp \gset
reset role;
select pg_temp.ck('FARM-04 only Sistema = gestisce sees the links (production and office no longer); nobody calls the key check',
  :'fl_uff' = 'null' and :'fo_uff' = 'null' and :'fo_rsp' = 'null' and :'e_rot_uff' like 'Permesso negato%' and :'e_scope' like 'permission denied%',
  :'fl_uff' || ' / ' || :'fo_rsp' || ' / ' || :'e_rot_uff' || ' / ' || :'e_scope');

select pg_temp.as_user(:'tit');
set role authenticated;
select fabula.farm_links() fl_tit \gset
select fabula.farm_link_rotate('qr') fl_rot \gset
reset role;
select set_config('request.jwt.claims', '', false);
select value tok_qr2 from fabula.settings where key = 'milk.farm_ship_token' \gset
select pg_temp.ck('FARM-04 the titolare gets the full link and the poster with the QR key; «Genera nuovo QR» switches the old QR off',
  :'fl_tit'::jsonb ->> 'full' = 'latte.html?t=' || :'tok_full' and :'fl_tit'::jsonb ->> 'poster' = 'latte.html?t=' || :'tok_qr' || '&stampa=1'
  and :'fl_tit'::jsonb ->> 'qr' = 'latte.html?t=' || :'tok_qr' || '&azione=spedizione'
  and :'tok_qr2' <> :'tok_qr' and :'tok_qr2' ~ '^[0-9a-f]{32}$' and :'fl_rot'::jsonb ->> 'poster' = 'latte.html?t=' || :'tok_qr2' || '&stampa=1'
  and fabula.farm_milk_orders(:'tok_qr') is null and fabula.farm_milk_orders(:'tok_qr2') ->> 'scope' = 'qr'
  and fabula.farm_milk_orders(:'tok_full') ->> 'scope' = 'full'
  and exists (select 1 from fabula.bot_messages where agent = 'configurazione' and title = 'Nuovo QR spedizioni della Masseria' and body like 'Titolare V ha generato un nuovo QR%')
  and (select new_data ->> 'value' from fabula.audit_log where row_key = 'milk.farm_ship_token' order by at desc limit 1) = '••••'
  and (select actor from fabula.audit_log where row_key = 'milk.farm_ship_token' order by at desc limit 1) = 'Titolare V');
select pg_temp.as_user(:'tit');
set role authenticated;
select fabula.farm_link_rotate('full') fl_rot2 \gset
with u as (update fabula.settings set value = 'Mario, Luca' where key = 'milk.farm_people' returning key) select count(*) n_people from u \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('FARM-04 «Genera nuovo link» switches the old full link off; the names are a normal setting the titolare edits',
  fabula.farm_milk_orders(:'tok_full') is null and fabula.farm_milk_orders(substring(:'fl_rot2'::jsonb ->> 'full' from 't=([0-9a-f]+)')) ->> 'scope' = 'full'
  and :n_people = 1 and fabula._farm_people() = '["Mario", "Luca"]'::jsonb);

-- ============================== PRINT-08 · lot labels from the database ==============================
select id moz from fabula.products where sku = 'MOZ-DOP-KG' \gset
insert into fabula.parties (id, type, legal_name, is_milk_supplier, active) values ('50000000-0000-4000-a000-000000103f01', 'supplier', 'Masseria V', true, true) on conflict do nothing;
insert into fabula.milk_intake (id, intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source)
values ('70000000-0000-4000-a000-000000103d01', current_date - 1, '06:30', '50000000-0000-4000-a000-000000103f01', 'LV103-M', 900, true, 4, 'tablet');
insert into fabula.production_batches (id, batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, output_kg, finished_at, source) values
  ('80000000-0000-4000-a000-000000103b01', current_date - 2, 'LV103-A', :'moz', 400, 'milk', now() - interval '2 days', 100, now() - interval '2 days' + interval '3 hours', 'tablet'),
  ('80000000-0000-4000-a000-000000103b02', current_date, 'LV103-B', :'moz', 400, 'milk', now() - interval '1 hour', null, null, 'tablet');
insert into fabula.stock_moves (product_id, lot_number, expiry_date, qty, move_type, batch_id, source)
values (:'moz', 'LV103-A', current_date + 3, 100, 'production_out', '80000000-0000-4000-a000-000000103b01', 'tablet');
insert into fabula.labels (kind, code, lot_number, product_id, batch_id, qty_printed) values ('batch_lot', 'LOT:LV103-A', 'LV103-A', :'moz', '80000000-0000-4000-a000-000000103b01', 6);
select name pname from fabula.products where id = :'moz' \gset

select pg_temp.as_user(:'cas');
set role authenticated;
select fabula.lot_label_info(array['LOT:LV103-A', 'lot:lv103-b', 'LOT:LV103-M', 'LOT:LV999-Z', 'EQ:CF-01']) li \gset
select fabula.lot_labels() ll \gset
select fabula.lot_labels('103-a', 60) ll_q \gset
reset role;
select pg_temp.ck('PRINT-08 a closed lot: product and expiry from the database, the copies printed at close',
  :'li'::jsonb -> 'LOT:LV103-A' ->> 'found' = 'true' and :'li'::jsonb -> 'LOT:LV103-A' ->> 'name' = :'pname'
  and :'li'::jsonb -> 'LOT:LV103-A' ->> 'sub' = 'scad. ' || to_char(current_date + 3, 'DD/MM/YYYY')
  and (:'li'::jsonb -> 'LOT:LV103-A' ->> 'copies')::int = 6, :'li');
select pg_temp.ck('PRINT-08 a lot still being worked (any case written), a milk lot, an unknown lot; other codes ignored',
  :'li'::jsonb -> 'lot:lv103-b' ->> 'lot' = 'LV103-B' and :'li'::jsonb -> 'lot:lv103-b' ->> 'name' = :'pname' || ' · in lavorazione'
  and :'li'::jsonb -> 'lot:lv103-b' ->> 'sub' = 'avviato ' || to_char((now() - interval '1 hour') at time zone 'Europe/Rome', 'DD/MM/YYYY') || ' alle ' || to_char((select started_at from fabula.production_batches where batch_lot = 'LV103-B') at time zone 'Europe/Rome', 'HH24:MI')
  and :'li'::jsonb -> 'LOT:LV103-M' ->> 'name' = 'Latte di bufala · Masseria V' and :'li'::jsonb -> 'LOT:LV103-M' ->> 'sub' = 'arrivo ' || to_char(current_date - 1, 'DD/MM/YYYY')
  and :'li'::jsonb -> 'LOT:LV999-Z' = '{"found": false}'::jsonb and not (:'li'::jsonb ? 'EQ:CF-01'), :'li');
select pg_temp.ck('PRINT-08 the reprint list: lots being worked first, then the newest; a search finds by any part of the code',
  (select (x ->> 'lot') from jsonb_array_elements(:'ll'::jsonb) x limit 1) = 'LV103-B'
  and exists (select 1 from jsonb_array_elements(:'ll'::jsonb) x where x ->> 'lot' = 'LV103-A')
  and exists (select 1 from jsonb_array_elements(:'ll'::jsonb) x where x ->> 'lot' = 'LV103-M')
  and jsonb_array_length(:'ll_q'::jsonb) = 1 and :'ll_q'::jsonb -> 0 ->> 'lot' = 'LV103-A', :'ll_q');

select pg_temp.as_user(:'mkt');
set role authenticated;
select pg_temp.err($q$select fabula.lot_label_info(array['LOT:LV103-A'])$q$) e_l1 \gset
select pg_temp.err($q$select fabula.lot_label_reprint('LV103-A', 2)$q$) e_l2 \gset
reset role;
-- 90 closed lots of the last 10 days and the open one: the list keeps 80, the open lot first, then the newest
insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, output_kg, finished_at, source)
select current_date - (g % 10), 'LW103-' || lpad(g::text, 3, '0'), :'moz', 100, 'milk', now() - (g % 10) * interval '1 day' - interval '3 hours', 25, now() - (g % 10) * interval '1 day', 'tablet'
  from generate_series(1, 90) g;
select pg_temp.as_user(:'cas');
set role authenticated;
select fabula.lot_labels() ll90 \gset
reset role;
select pg_temp.ck('PRINT-08 with many lots the list is cut after sorting: 80 lots, the one being worked first, today''s before older ones',
  jsonb_array_length(:'ll90'::jsonb) = 80 and :'ll90'::jsonb -> 0 ->> 'lot' = 'LV103-B'
  and (select count(*) from jsonb_array_elements(:'ll90'::jsonb) x where (x ->> 'date')::date = current_date) >= 9
  and (select bool_and(a.d >= b.d) from (select (x ->> 'date')::date d, n from jsonb_array_elements(:'ll90'::jsonb) with ordinality t(x, n) where n > 1) a
        join (select (x ->> 'date')::date d, n from jsonb_array_elements(:'ll90'::jsonb) with ordinality t(x, n)) b on b.n = a.n + 1));
select pg_temp.ck('PRINT-08 a profile that only views production (marketing) sees the lots but prints no lot label',
  :'e_l1' = '' and :'e_l2' = 'Il tuo profilo non può stampare etichette di lotto', :'e_l1' || ' / ' || :'e_l2');

select pg_temp.as_user(:'cas');
set role authenticated;
select fabula.lot_label_reprint('lv103-a', 3, '10000000-0000-4000-a000-000000103a04') r1 \gset
select fabula.lot_label_reprint('LV103-B', 2) r2 \gset
select fabula.lot_label_reprint('LV103-M', 1) r3 \gset
select pg_temp.err($q$select fabula.lot_label_reprint('LV999-Z', 1)$q$) e_r4 \gset
select (fabula.lot_label_reprint('LV103-A', 500)) ->> 'copies' r5 \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('PRINT-08 a reprint is checked and counted on the lot''s label row (who, when)',
  :'r1'::jsonb ->> 'lot' = 'LV103-A' and (:'r1'::jsonb ->> 'copies')::int = 3
  and (select reprinted_count = 2 and last_reprinted_by_id = '10000000-0000-4000-a000-000000103a04' and qty_printed = 6 from fabula.labels where code = 'LOT:LV103-A')
  and :'e_r4' = 'Lotto sconosciuto: LV999-Z' and :'r5' = '60', :'r1' || ' / ' || :'e_r4' || ' / ' || :'r5');
select pg_temp.ck('PRINT-08 a lot being worked gets no label row (its close creates it) and a milk lot without one gets it now',
  :'r2'::jsonb ->> 'kind' = 'batch_open' and not exists (select 1 from fabula.labels where upper(code) = 'LOT:LV103-B')
  and (select kind::text = 'milk_lot' and reprinted_count = 1 and milk_intake_id = '70000000-0000-4000-a000-000000103d01' from fabula.labels where code = 'LOT:LV103-M')
  and pg_temp.err($q$insert into fabula.labels (kind, code, lot_number, product_id, batch_id, qty_printed) values ('batch_lot', 'LOT:LV103-B', 'LV103-B', (select product_id from fabula.production_batches where batch_lot = 'LV103-B'), '80000000-0000-4000-a000-000000103b02', 4)$q$) = '');
select pg_temp.ck('PRINT-08 the new functions are for logins, the label helpers for nobody outside the database',
  has_function_privilege('authenticated', 'fabula.lot_label_info(text[])', 'execute') and not has_function_privilege('anon', 'fabula.lot_label_info(text[])', 'execute')
  and not has_function_privilege('authenticated', 'fabula._lot_label(text)', 'execute') and not has_function_privilege('authenticated', 'fabula._farm_scope(text)', 'execute')
  and not exists (select 1 from fabula.security_findings() f where not exists (select 1 from fabula.security_accepted a where a.key = f.key)));
