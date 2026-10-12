-- v0.93a audit fixes, food safety · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh af_test
--   su postgres -c "psql -d af_test -f tools/go-live/drill/prod-test/test_audit_food_safety.sql" | grep -E "PASS|FAIL"
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as
$$ begin execute p_sql; return ''; exception when others then return sqlerrm; end $$;
select id moz from fabula.products where sku = 'MOZ-DOP-KG' \gset
insert into fabula.staff (id, full_name, role, app_role, active, auth_user_id) values
  ('10000000-0000-4000-a000-0000000000f1', 'Banco Audit', 'commesso', 'banco', true, '00000000-0000-4000-a000-0000000000f1'),
  ('10000000-0000-4000-a000-0000000000f2', 'Marketing Audit', 'operaio', 'marketing', true, '00000000-0000-4000-a000-0000000000f2')
on conflict do nothing;
insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, output_kg, finished_at, source)
values (current_date, 'LAF-1', :'moz', 500, 'milk', now(), 150, now(), 'tablet'), (current_date, 'LAF-2', :'moz', 500, 'milk', now(), 150, now(), 'tablet');

-- 1 · D-01: a Banco login records a failed CCP 3 → the lot is really held
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-0000000000f1","role":"authenticated"}', false);
set role authenticated;
select fabula.log_ccp(p_cp_code => 'CCP-STRETCH', p_value => 55, p_staff_id => '10000000-0000-4000-a000-0000000000f1', p_batch_lot => 'LAF-1') r1 \gset
select pg_temp.err($$select fabula.hold_lot('LAF-2', 'prova', null)$$) e_hold_banco \gset
reset role;
select pg_temp.ck('Banco: failed CCP 3 returns lot_on_hold = true', (:'r1'::jsonb->>'lot_on_hold')::boolean, :'r1');
select pg_temp.ck('Banco: the lot is really on hold (was: 0 rows under RLS)', (select food_safety_hold from fabula.production_batches where batch_lot = 'LAF-1'));
select pg_temp.ck('Banco (HACCP level 2) can hold a lot through hold_lot', :'e_hold_banco' = '' and (select food_safety_hold from fabula.production_batches where batch_lot = 'LAF-2'), :'e_hold_banco');

-- a profile without HACCP rights is refused
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-0000000000f2","role":"authenticated"}', false);
set role authenticated;
select pg_temp.err($$select fabula.log_ccp(p_cp_code => 'CCP-STRETCH', p_value => 65, p_batch_lot => 'LAF-1')$$) e_mkt \gset
select pg_temp.err($$select fabula.hold_lot('LAF-1', 'prova', null)$$) e_mkt_hold \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('Marketing (HACCP level 0) cannot record a CCP', :'e_mkt' like 'Permesso negato%', :'e_mkt');
select pg_temp.ck('Marketing cannot hold a lot', :'e_mkt_hold' like 'Permesso negato%', :'e_mkt_hold');
select pg_temp.ck('log_ccp, hold_lot, record_lab_result run as definer, anon cannot execute',
  (select bool_and(prosecdef) from pg_proc where pronamespace = 'fabula'::regnamespace and oid in
     ('fabula.log_ccp(text,numeric,timestamptz,uuid,text,text,text,text,text)'::regprocedure, 'fabula.hold_lot(text,text,uuid)'::regprocedure,
      'fabula.record_lab_result(text,text,numeric,text,text,date,uuid,uuid)'::regprocedure))
  and not has_function_privilege('anon', 'fabula.log_ccp(text,numeric,timestamptz,uuid,text,text,text,text,text)', 'execute'));
select pg_temp.ck('a normal reading by the service role still saves (bots, sensors)',
  fabula.log_ccp(p_cp_code => 'CCP-COLD-1', p_value => 3, p_staff_id => '10000000-0000-4000-a000-0000000000f1')->>'result' = 'ok');

-- 2 · E-02: alerts first
insert into fabula.notices (key, severity, title_it, items, expires_at) values
  ('af_warn', 'warn', 'tecnico', '[]', now() + interval '1 hour'), ('af_info', 'info', 'info', '[]', now() + interval '1 hour'),
  ('af_alert', 'alert', 'Prima di chiudere', '[]', now() + interval '1 hour');
select pg_temp.ck('v_active_notices lists alerts first, then warnings, then info',
  (select string_agg(severity, ',') from (select severity from fabula.v_active_notices where key like 'af_%') x) = 'alert,warn,info',
  (select string_agg(severity, ',') from (select severity from fabula.v_active_notices where key like 'af_%') x));
select pg_temp.ck('v_active_notices keeps security_invoker', (select reloptions::text from pg_class where oid = 'fabula.v_active_notices'::regclass) like '%security_invoker=true%');

-- 3 · B-10 / E-11: a recall assessment does not expire, and the health check reports it
insert into fabula.approvals (kind, requested_by, summary, payload, status, expires_at, requested_at) values
  ('other', 'agent:food_safety', '⚠ Valutare ritiro/richiamo · prova', '{"type":"recall_assessment","lot":"LAF-1","test":"LIST"}', 'pending', now() - interval '1 day', now() - interval '3 days'),
  ('other', 'agent:test', 'altro', '{"type":"other"}', 'pending', now() - interval '1 day', now() - interval '3 days');
select fabula.ops_health_check() h \gset
select pg_temp.ck('recall assessment past its old deadline is still pending',
  (select status from fabula.approvals where summary = '⚠ Valutare ritiro/richiamo · prova') = 'pending');
select pg_temp.ck('other approvals past their deadline still expire', (select status from fabula.approvals where summary = 'altro') = 'expired');
select pg_temp.ck('health check reports the waiting recall decision',
  exists (select 1 from jsonb_array_elements(:'h'::jsonb->'data_quality') x where x->>'key' = 'recall_pending' and x->>'text' like '%LAF-1%'));
select pg_temp.ck('new recall assessments get no deadline', pg_get_functiondef('fabula.record_lab_result(text,text,numeric,text,text,date,uuid,uuid)'::regprocedure) like '%''pending'', null)%');

-- 4 · B-01: critical limits cannot be blanked or inverted
select pg_temp.err($$update fabula.haccp_control_points set min_value = null where code = 'CCP-PAST'$$) e1 \gset
select pg_temp.ck('clearing the CCP 2 minimum is refused', :'e1' like '%limite minimo (72.00) non si può cancellare%', :'e1');
select pg_temp.err($$update fabula.haccp_control_points set min_value = 7 where code = 'CCP-COLD-1'$$) e2 \gset
select pg_temp.ck('minimum above maximum is refused', :'e2' like '%deve essere più basso del massimo%', :'e2');
select pg_temp.err($$update fabula.haccp_control_points set warn_max = 8 where code = 'CCP-COLD-1'$$) e3 \gset
select pg_temp.ck('alert threshold outside the critical limit is refused', :'e3' like '%dentro il limite critico%', :'e3');
select pg_temp.err($$update fabula.haccp_control_points set max_value = 5 where code = 'CCP-COLD-1'$$) e4 \gset
select pg_temp.ck('a normal change still saves', :'e4' = '' and (select max_value from fabula.haccp_control_points where code = 'CCP-COLD-1') = 5, :'e4');
select pg_temp.err($$update fabula.haccp_control_points set min_value = 0.5 where code = 'PRP-WATER-CL'$$) e5 \gset
select pg_temp.ck('non-CCP rows are not constrained', :'e5' = '', :'e5');
