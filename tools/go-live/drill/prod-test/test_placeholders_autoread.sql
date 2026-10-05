-- v0.72 · run on a fresh replay: tools/go-live/drill/infra-test/replay.sh ph_test
--   su postgres -c "psql -d ph_test -f tools/go-live/drill/prod-test/test_placeholders_autoread.sql" | grep -E "PASS|FAIL"
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
select (now() at time zone 'Europe/Rome')::date d \gset
select id c1 from fabula.parties where legal_name = 'Cliente 1' \gset
select id c2 from fabula.parties where legal_name = 'Cliente 2' \gset
-- two placeholder orders already booked: one not shipped, one shipped
insert into fabula.sales_orders (order_number, channel, order_date, customer_id, status, source) values
 ('WS-OLD-1', 'wholesale', :'d'::date - 2, :'c1', 'confirmed', 'standing_order'),
 ('WS-OLD-2', 'wholesale', :'d'::date - 2, :'c2', 'confirmed', 'standing_order');
insert into fabula.shipments (ddt_number, customer_id, sales_order_id, status, ship_date) select 'DDT-T', :'c2', id, 'picked', :'d' from fabula.sales_orders where order_number = 'WS-OLD-2';

select fabula.confirm_standing_orders(:'d'::date + 1) r1 \gset
select pg_temp.ck('placeholder customers: nothing booked, both listed as skipped', (:'r1'::jsonb->>'booked')::int = 0
  and :'r1'::jsonb->'skipped_placeholder' @> '["Cliente 1", "Cliente 2"]' and (:'r1'::jsonb->>'is_placeholder')::boolean, :'r1');
select pg_temp.ck('their unshipped order is cancelled, the shipped one is left alone',
  (select status::text from fabula.sales_orders where order_number = 'WS-OLD-1') = 'cancelled' and (select status::text from fabula.sales_orders where order_number = 'WS-OLD-2') = 'confirmed'
  and :'r1'::jsonb->'cancelled_placeholder' = '["WS-OLD-1"]', :'r1'::jsonb->>'cancelled_placeholder');
select pg_temp.ck('no confirmed wholesale demand left for the milk plan', (:'r1'::jsonb->>'total_kg')::numeric = 0);
-- renamed in the console (notes/source cleared) → booking resumes
update fabula.parties set legal_name = 'Pizzeria Da Tonino', notes = null, source = 'manual' where id = :'c1';
select fabula.confirm_standing_orders(:'d'::date + 1) r2 \gset
select pg_temp.ck('after renaming Cliente 1: its order is booked, Cliente 2 still skipped', (:'r2'::jsonb->>'booked')::int = 1
  and :'r2'::jsonb#>>'{customers,0,customer}' = 'Pizzeria Da Tonino' and :'r2'::jsonb->'skipped_placeholder' = '["Cliente 2"]', :'r2');
select pg_temp.ck('running again does not book twice', (fabula.confirm_standing_orders(:'d'::date + 1)->>'booked')::int = 0
  and (select count(*) from fabula.sales_orders where customer_id = :'c1' and order_date = :'d'::date + 1 and status = 'confirmed') = 1);
-- autoread
insert into fabula.bot_messages (agent, severity, title, body, created_at) values
 ('daily_brief', 'info', 'T-old-info', 'x', now() - interval '2 days'), ('daily_brief', 'warn', 'T-old-warn', 'x', now() - interval '2 days'),
 ('daily_brief', 'alert', 'T-old-alert', 'x', now() - interval '3 days'), ('daily_brief', 'info', 'T-new-info', 'x', now() - interval '1 hour');
select fabula.bot_messages_autoread() n \gset
select pg_temp.ck('only info messages older than 24 h are marked read', (select string_agg(title, ',' order by title) from fabula.bot_messages where title like 'T-%' and read_at is null) = 'T-new-info,T-old-alert,T-old-warn', 'marked ' || :'n');
select pg_temp.ck('hourly job scheduled; signed-in users cannot run the cleanups', exists (select 1 from cron.job where jobname = 'fabula_bot_messages_autoread' and schedule = '17 * * * *')
  and not has_function_privilege('authenticated', 'fabula.cancel_placeholder_orders()', 'execute') and not has_function_privilege('authenticated', 'fabula.bot_messages_autoread(timestamptz)', 'execute'));
