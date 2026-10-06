-- v0.80 production guard rails · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh pg_test
--   su postgres -c "psql -d pg_test -f tools/go-live/drill/prod-test/test_prod_guards.sql" | grep -E "PASS|FAIL"
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
select id moz from fabula.products where sku = 'MOZ-DOP-KG' \gset
select id ric from fabula.products where sku = 'RIC-BUF-KG' \gset
insert into fabula.staff (id, full_name, role, app_role, active) values ('10000000-0000-4000-a000-0000000000b1', 'Casaro Guard', 'casaro', 'produzione', true) on conflict do nothing;
insert into fabula.parties (id, type, legal_name, is_milk_supplier) values ('10000000-0000-4000-a000-0000000000b9', 'supplier', 'Masseria Guard', true) on conflict do nothing;

select pg_temp.ck('v_process_steps returns ccp_code (pasteurisation and stretching marked)',
  (select count(*) from fabula.v_process_steps where ccp_code in ('CCP-PAST', 'CCP-STRETCH', 'CCP-RIC')) >= 3);

-- a mozzarella batch closed with no CCP records
insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, source) values (current_date, 'LG-1', :'moz', 500, 'milk', now(), 'tablet');
update fabula.production_batches set output_kg = 150, finished_at = now() where batch_lot = 'LG-1';
select pg_temp.ck('closed without CCP 2 and CCP 3: alert from Zio Ciro naming both',
  exists (select 1 from fabula.bot_messages where agent = 'produzione' and severity = 'alert' and title = 'Lotto LG-1 chiuso senza pastorizzazione (CCP 2) e temperatura di filatura (CCP 3)'),
  (select string_agg(title, ' | ') from fabula.bot_messages where agent = 'produzione'));

-- a batch with both records, closed in the same transaction as the stretching record (deferred check)
insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, source) values (current_date, 'LG-2', :'moz', 500, 'milk', now(), 'tablet');
select fabula.log_ccp(p_cp_code => 'CCP-PAST', p_value => 72.5, p_staff_id => '10000000-0000-4000-a000-0000000000b1', p_batch_lot => 'LG-2') \gset
begin;
update fabula.production_batches set output_kg = 150, finished_at = now() where batch_lot = 'LG-2';
select fabula.log_ccp(p_cp_code => 'CCP-STRETCH', p_value => 65, p_staff_id => '10000000-0000-4000-a000-0000000000b1', p_batch_lot => 'LG-2') \gset
commit;
select pg_temp.ck('records present (stretching logged after the close, same save): no alert',
  not exists (select 1 from fabula.bot_messages where agent = 'produzione' and title like 'Lotto LG-2 %'));

-- ricotta without CCP 4
insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, source) values (current_date, 'RG-1', :'ric', 300, 'whey', now(), 'tablet');
update fabula.production_batches set output_kg = 20, finished_at = now() where batch_lot = 'RG-1';
select pg_temp.ck('ricotta closed without CCP 4: alert', exists (select 1 from fabula.bot_messages where agent = 'produzione' and title = 'Lotto RG-1 chiuso senza temperatura di affioramento (CCP 4)'));
select pg_temp.ck('editing a closed batch again does not re-alert',
  (select count(*) from fabula.bot_messages where title like 'Lotto LG-1 %') = 1);
update fabula.production_batches set output_kg = 151 where batch_lot = 'LG-1';
select pg_temp.ck('(after an edit of output_kg)', (select count(*) from fabula.bot_messages where title like 'Lotto LG-1 %') = 1);

-- evening watch: an open batch and milk 50 h old with kg left
insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, source) values (current_date, 'LG-3', :'moz', 400, 'milk', now(), 'tablet');
insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source)
values (((now() - interval '50 hours') at time zone 'Europe/Rome')::date, ((now() - interval '50 hours') at time zone 'Europe/Rome')::time, '10000000-0000-4000-a000-0000000000b9', 'MG-OLD', 300, true, 4, 'tablet');
select fabula.prod_watch((current_date + time '19:45') at time zone 'Europe/Rome') w1 \gset
select pg_temp.ck('19:45 Rome: open batch and old milk reported once',
  (:'w1'::jsonb->>'open_batches')::int >= 1 and (:'w1'::jsonb->>'old_milk')::int = 1
  and exists (select 1 from fabula.bot_messages where agent = 'produzione' and severity = 'warn' and body like '%LG-3%' and body like '%MG-OLD: 300 kg%'), :'w1');
select pg_temp.ck('same evening: not posted twice', fabula.prod_watch((current_date + time '19:50') at time zone 'Europe/Rome')->>'skipped' = 'already posted');
select pg_temp.ck('other DST slot (18:45 Rome) skips', fabula.prod_watch((current_date + time '18:45') at time zone 'Europe/Rome')->>'skipped' = 'not 19:xx in Rome');
select pg_temp.ck('job scheduled; app users cannot run it',
  exists (select 1 from cron.job where jobname = 'fabula_prod_watch' and schedule = '45 17,18 * * *')
  and not has_function_privilege('authenticated', 'fabula.prod_watch(timestamptz)', 'execute'));
