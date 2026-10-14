-- v0.94a audit fixes, farm loads (A-10 / FARM-03 / FARM-02b) · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh fs_test
--   su postgres -c "psql -d fs_test -f tools/go-live/drill/prod-test/test_audit_farm_shipments.sql" | grep -E "PASS|FAIL"
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as
$$ begin execute p_sql; return ''; exception when others then return sqlerrm; end $$;
update fabula.settings set value = '0123456789abcdef0123456789abcdef' where key = 'milk.farm_token';
insert into fabula.settings (key, value, description, data_type) select 'milk.farm_token', '0123456789abcdef0123456789abcdef', 'test', 'text'
 where not exists (select 1 from fabula.settings where key = 'milk.farm_token');
\set tok '0123456789abcdef0123456789abcdef'
insert into fabula.staff (id, full_name, role, app_role, active, auth_user_id) values
  ('10000000-0000-4000-a000-0000000000e1', 'Titolare Audit', 'owner', 'titolare', true, '00000000-0000-4000-a000-0000000000e1'),
  ('10000000-0000-4000-a000-0000000000e2', 'Banco Audit 2', 'commesso', 'banco', true, '00000000-0000-4000-a000-0000000000e2')
on conflict do nothing;
update fabula.milk_shipments set status = 'received' where status = 'shipped';   -- only this test's loads in transit
select (fabula.farm_milk_ship(:'tok', 1050, null, 'DDT-A1', null))->>'milk_lot' l1 \gset
select (fabula.farm_milk_ship(:'tok', 980, null, null, null))->>'milk_lot' l2 \gset
insert into fabula.milk_shipments (shipped_at, ship_date, kg, milk_lot, status) values (now() - interval '40 hours', current_date - 2, 1111, 'MAUD-OLD', 'shipped');

-- the farm corrects a weight
select pg_temp.err(format($q$select fabula.farm_milk_amend(%L, %L, 1040, false, null)$q$, :'tok', :'l1')) e1 \gset
select pg_temp.ck('a correction without a reason is refused', :'e1' like 'Scrivi il motivo%', :'e1');
select fabula.farm_milk_amend(:'tok', :'l1', 1040, false, 'peso sbagliato') r1 \gset
select pg_temp.ck('the farm corrects the kg of a load in transit; the first kg is kept',
  (select kg = 1040 and original_kg = 1050 and correction_reason = 'peso sbagliato' and corrected_at is not null from fabula.milk_shipments where milk_lot = :'l1'), :'r1');
select pg_temp.ck('…the office gets a message in the Bot feed',
  exists (select 1 from fabula.bot_messages where agent = 'masseria' and title = 'Masseria: peso corretto su ' || :'l1' and body like '%1040,0 kg (prima 1050,0 kg)%'));
select pg_temp.ck('a wrong token changes nothing', fabula.farm_milk_amend('ffffffffffffffffffffffffffffffff', :'l1', 900, false, 'xxx') is null
  and (select kg from fabula.milk_shipments where milk_lot = :'l1') = 1040);

-- the farm cancels a load registered twice
select fabula.farm_milk_amend(:'tok', :'l2', null, true, 'registrata due volte') r2 \gset
select pg_temp.ck('the farm cancels a load in transit, with who and why',
  (select status = 'cancelled' and cancelled_by = 'Masseria' and cancel_reason = 'registrata due volte' and cancelled_at is not null from fabula.milk_shipments where milk_lot = :'l2'), :'r2');
select pg_temp.ck('…a warning in the Bot feed', exists (select 1 from fabula.bot_messages where agent = 'masseria' and severity = 'warn' and title = 'Masseria: spedizione ' || :'l2' || ' annullata'));
select pg_temp.err(format($q$select fabula.farm_milk_amend(%L, %L, 900, false, 'ancora')$q$, :'tok', :'l2')) e3 \gset
select pg_temp.ck('a cancelled load cannot be changed again', :'e3' like '%già stata annullata%', :'e3');
select pg_temp.ck('the farm page lists it as cancelled with the reason, and the corrected one with its first kg',
  (select bool_or(x->>'status' = 'cancelled' and x->>'cancel_reason' = 'registrata due volte') and bool_or(x->>'milk_lot' = :'l1' and (x->>'original_kg')::numeric = 1050)
     from jsonb_array_elements(fabula.farm_milk_orders(:'tok')->'shipments') x));
select (fabula.farm_milk_ship(:'tok', 980, null, null, null)) r4 \gset
select pg_temp.ck('re-entering the same kg right after a cancel is a new load, not a double tap',
  (:'r4'::jsonb->>'duplicate') is null and (:'r4'::jsonb->>'milk_lot') <> :'l2', :'r4');

-- the dairy can no longer receive a cancelled load
insert into fabula.parties (id, type, legal_name, is_milk_supplier, active) values ('50000000-0000-4000-a000-0000000000e9', 'supplier', 'Masseria Audit', true, true) on conflict do nothing;
select pg_temp.err(format($q$insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source, shipment_id)
  values (current_date, '07:00', '50000000-0000-4000-a000-0000000000e9', 'x', 1, true, 4, 'tablet', (select id from fabula.milk_shipments where milk_lot = %L))$q$, :'l2')) e5 \gset
select pg_temp.ck('a cancelled load is refused at intake and says why', :'e5' like '%già stata annullata (registrata due volte)%', :'e5');

-- once received, the farm cannot change it
select pg_temp.err(format($q$insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source, shipment_id)
  values (current_date, '07:00', '50000000-0000-4000-a000-0000000000e9', 'x', 1, true, 4, 'tablet', (select id from fabula.milk_shipments where milk_lot = %L))$q$, :'l1')) e6 \gset
select pg_temp.err(format($q$select fabula.farm_milk_amend(%L, %L, 1000, false, 'dopo')$q$, :'tok', :'l1')) e7 \gset
select pg_temp.ck('a received load is taken at the corrected kg', :'e6' = '' and (select qty_kg from fabula.milk_intake where shipment_id = (select id from fabula.milk_shipments where milk_lot = :'l1')) = 1040, :'e6');
select pg_temp.ck('…and the farm can no longer change it', :'e7' like '%già stata ricevuta dal caseificio%', :'e7');

-- stale loads are reported every evening; the office cancels them from the console
select fabula.ops_health_check() h \gset
select pg_temp.ck('the health check reports a load in transit for more than 36 h',
  exists (select 1 from jsonb_array_elements(:'h'::jsonb->'data_quality') x where x->>'key' = 'milk_shipments_stale' and x->>'text' like '%MAUD-OLD · 1111,0 kg%' and (x->>'count')::int = 1), :'h');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-0000000000e2","role":"authenticated"}', false);
set role authenticated;
select pg_temp.err($q$select fabula.milk_shipment_cancel((select id from fabula.milk_shipments where milk_lot = 'MAUD-OLD'), 'vecchia')$q$) e8 \gset
reset role;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-0000000000e1","role":"authenticated"}', false);
set role authenticated;
select pg_temp.err($q$select fabula.milk_shipment_cancel((select id from fabula.milk_shipments where milk_lot = 'MAUD-OLD'), '')$q$) e9 \gset
select pg_temp.err($q$select fabula.milk_shipment_cancel((select id from fabula.milk_shipments where milk_lot = 'MAUD-OLD'), 'mai arrivata, registrata per errore')$q$) e10 \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('Banco (produzione level 1) cannot cancel a load', :'e8' like 'Permesso negato%', :'e8');
select pg_temp.ck('the owner must give a reason', :'e9' like 'Scrivi il motivo%', :'e9');
select pg_temp.ck('the owner cancels it, with name and reason',
  :'e10' = '' and (select status = 'cancelled' and cancelled_by = 'Titolare Audit' and cancel_reason = 'mai arrivata, registrata per errore' from fabula.milk_shipments where milk_lot = 'MAUD-OLD'), :'e10');
select fabula.ops_health_check() h2 \gset
select pg_temp.ck('…and the health check no longer reports it', not exists (select 1 from jsonb_array_elements(:'h2'::jsonb->'data_quality') x where x->>'key' = 'milk_shipments_stale'));
-- v1.03b: farm_milk_amend has p_by (who at the farm); every version of it stays out of reach of app users
select pg_temp.ck('farm_milk_amend is not callable by app users', not exists (select 1 from pg_proc where proname = 'farm_milk_amend' and pronamespace = 'fabula'::regnamespace
                    and (has_function_privilege('authenticated', oid, 'execute') or has_function_privilege('anon', oid, 'execute')))
  and (select count(*) from pg_proc where proname = 'farm_milk_amend' and pronamespace = 'fabula'::regnamespace) = 1
  and not has_function_privilege('anon', 'fabula.milk_shipment_cancel(uuid,text)', 'execute'));
