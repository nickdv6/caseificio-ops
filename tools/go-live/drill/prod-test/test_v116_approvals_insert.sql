-- v1.16 (audit D-2) · approval requests are created only by the database's own functions, never by a login · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh a_test
--   su postgres -c "psql -d a_test -f tools/go-live/drill/prod-test/test_v116_approvals_insert.sql" | grep -E "PASS|FAIL"
-- Sections: 1 grants · 2 direct inserts per role · 3 the five proposal functions called by a login · 4 rejected milk plans
-- · 5 sell-down codes · 6 what must keep working (bots, stand-ins, local campaign, decide, undo, auto-approve, expiry, sell-down).
-- Every login attempt runs inside a DO block that catches its own error, so the suite prints PASS/FAIL lines only.
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
select (now() at time zone 'Europe/Rome')::date d \gset
-- the next working days (not Sunday) for milk plans
select min(x)::date d_plan from generate_series(:'d'::date + 20, :'d'::date + 26, interval '1 day') x where extract(isodow from x) between 1 and 6 \gset
select min(x)::date d_again from generate_series(:'d'::date + 5, :'d'::date + 11, interval '1 day') x where extract(isodow from x) between 1 and 6 \gset
select min(x)::date d_plan2 from generate_series(:'d'::date + 50, :'d'::date + 56, interval '1 day') x where extract(isodow from x) between 1 and 6 \gset
select set_config('d2.again', :'d_again', false);

-- ============================== test logins: one per role, plus a login with no staff row ==============================
insert into auth.users (id, email) values
  ('00000000-0000-4000-a000-00000000d201', 'tit@d2.it'), ('00000000-0000-4000-a000-00000000d202', 'soc@d2.it'),
  ('00000000-0000-4000-a000-00000000d203', 'prod@d2.it'), ('00000000-0000-4000-a000-00000000d204', 'banco@d2.it'),
  ('00000000-0000-4000-a000-00000000d205', 'sped@d2.it'), ('00000000-0000-4000-a000-00000000d206', 'cons@d2.it'),
  ('00000000-0000-4000-a000-00000000d207', 'nostaff@d2.it');
insert into fabula.staff (id, full_name, auth_user_id, app_role, role, active) values
  ('10000000-0000-4000-a000-00000000d201', 'Titolare D2', '00000000-0000-4000-a000-00000000d201', 'titolare', 'owner', true),
  ('10000000-0000-4000-a000-00000000d202', 'Socio D2', '00000000-0000-4000-a000-00000000d202', 'socio', 'partner', true),
  ('10000000-0000-4000-a000-00000000d203', 'Produzione D2', '00000000-0000-4000-a000-00000000d203', 'produzione', 'casaro', true),
  ('10000000-0000-4000-a000-00000000d204', 'Banco D2', '00000000-0000-4000-a000-00000000d204', 'banco', 'commesso', true),
  ('10000000-0000-4000-a000-00000000d205', 'Spedizioni D2', '00000000-0000-4000-a000-00000000d205', 'spedizioni', 'operaio', true),
  ('10000000-0000-4000-a000-00000000d206', 'Consulente D2', '00000000-0000-4000-a000-00000000d206', 'consulente', 'consulente', true);

-- fixtures: a REJECTED milk plan that looks «normal» (so the auto rule would fire), one per revival attempt
insert into fabula.milk_plans (plan_date, milk_kg, planned_output_kg, status, details) values
 (:'d'::date + 30, 800, 240, 'rejected', '{"history_source":"same_weekday_4w","history_days":4,"last_4w_same_weekday_milk_kg":760,"capacity_hit":false,"min_run_applied":false,"exceeds_farm_supply":false,"is_simulation":false}'),
 (:'d'::date + 31, 800, 240, 'rejected', '{"history_source":"same_weekday_4w","history_days":4,"last_4w_same_weekday_milk_kg":760,"capacity_hit":false,"min_run_applied":false,"exceeds_farm_supply":false,"is_simulation":false}');
select id rej_login from fabula.milk_plans where plan_date = :'d'::date + 30 \gset
select id rej_bot from fabula.milk_plans where plan_date = :'d'::date + 31 \gset

-- ============================== 1. grants ==============================
select pg_temp.ck('1a logins (authenticated) can no longer INSERT into approvals',
  not has_table_privilege('authenticated', 'fabula.approvals', 'INSERT'));
select pg_temp.ck('1b anon still cannot INSERT, SELECT or UPDATE approvals',
  not has_table_privilege('anon', 'fabula.approvals', 'INSERT') and not has_table_privilege('anon', 'fabula.approvals', 'SELECT')
  and not has_table_privilege('anon', 'fabula.approvals', 'UPDATE'));
select pg_temp.ck('1c logins keep SELECT and DELETE exactly as before; UPDATE stays closed (decisions go through the functions)',
  has_table_privilege('authenticated', 'fabula.approvals', 'SELECT') and has_table_privilege('authenticated', 'fabula.approvals', 'DELETE')
  and not has_table_privilege('authenticated', 'fabula.approvals', 'UPDATE'));
select pg_temp.ck('1d the database owner and the service role keep INSERT (bots, cron, stand-ins, edge functions)',
  has_table_privilege('postgres', 'fabula.approvals', 'INSERT') and has_table_privilege('service_role', 'fabula.approvals', 'INSERT'));
select pg_temp.ck('1e the 5 approval policies are untouched (no policy change in this release)',
  (select count(*) from pg_policies where schemaname = 'fabula' and tablename = 'approvals') = 5);
select pg_temp.ck('1f sync_po_from_approval and sell_down_codes_needed stay SECURITY DEFINER with a fixed search_path, not callable by logins or anon',
  (select bool_and(prosecdef and proconfig::text like '%search_path=%'
                   and not has_function_privilege('authenticated', oid, 'EXECUTE') and not has_function_privilege('anon', oid, 'EXECUTE'))
     from pg_proc where oid in ('fabula.sync_po_from_approval()'::regprocedure, 'fabula.sell_down_codes_needed()'::regprocedure)));
select pg_temp.ck('1g mkt_local_before is unchanged: still SECURITY INVOKER (a login can no longer create an approval through it)',
  not (select prosecdef from pg_proc where oid = 'fabula.mkt_local_before()'::regprocedure));

-- ============================== 2. a direct INSERT by every login is refused ==============================
-- Each login tries four requests: milk plan (produzione), sell-down promo (vendite), DOP declaration (haccp), purchase order (acquisti).
-- The milk-plan attempt points at the rejected plan :rej_login (the revival attack).
select set_config('d2.rej', :'rej_login', false);
create temp table d2_attempts (who text primary key, res jsonb);
grant all on d2_attempts to authenticated;
\set ATTEMPT 'do $$ declare r jsonb := ''{}''; tag text := current_setting(''d2.who''); begin begin insert into fabula.approvals (kind, requested_by, summary, payload, related_table, related_id, amount_eur, expires_at) values (''other'', ''agent:milk_planning'', ''D2-ATTACK milk '' || tag, ''{"type":"milk_plan"}'', ''milk_plans'', current_setting(''d2.rej'')::uuid, 100, now() + interval ''1 day''); r := r || ''{"milk":"inserted"}''; exception when others then r := r || jsonb_build_object(''milk'', sqlstate); end; begin insert into fabula.approvals (kind, requested_by, summary, payload, expires_at) values (''price_change'', ''agent:sell_down'', ''D2-ATTACK promo '' || tag, ''{"type":"sell_down","action":"promo_banco","promo_pct":100,"at_risk_kg":5,"lot":"LX","sku":"MOZ-DOP-KG"}'', null); r := r || ''{"promo":"inserted"}''; exception when others then r := r || jsonb_build_object(''promo'', sqlstate); end; begin insert into fabula.approvals (kind, requested_by, summary, payload, expires_at) values (''dop_declaration'', ''agent:monthly_review'', ''D2-ATTACK dop '' || tag, ''{}'', now() + interval ''1 day''); r := r || ''{"dop":"inserted"}''; exception when others then r := r || jsonb_build_object(''dop'', sqlstate); end; begin insert into fabula.approvals (kind, requested_by, summary, payload, amount_eur, expires_at) values (''purchase_order'', ''agent:procurement'', ''D2-ATTACK po '' || tag, ''{"sku":"CON-SALT","unit_price_eur":0.5}'', 50, now() + interval ''1 day''); r := r || ''{"po":"inserted"}''; exception when others then r := r || jsonb_build_object(''po'', sqlstate); end; insert into d2_attempts values (tag, r); end $$;'

select set_config('d2.who', 'titolare', false), set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-00000000d201","role":"authenticated"}', false);
set role authenticated;
:ATTEMPT
reset role;
select set_config('d2.who', 'socio', false), set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-00000000d202","role":"authenticated"}', false);
set role authenticated;
:ATTEMPT
reset role;
select set_config('d2.who', 'produzione', false), set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-00000000d203","role":"authenticated"}', false);
set role authenticated;
:ATTEMPT
reset role;
select set_config('d2.who', 'banco', false), set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-00000000d204","role":"authenticated"}', false);
set role authenticated;
:ATTEMPT
reset role;
select set_config('d2.who', 'spedizioni', false), set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-00000000d205","role":"authenticated"}', false);
set role authenticated;
:ATTEMPT
reset role;
select set_config('d2.who', 'consulente', false), set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-00000000d206","role":"authenticated"}', false);
set role authenticated;
:ATTEMPT
reset role;
select set_config('d2.who', 'senza_staff', false), set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-00000000d207","role":"authenticated"}', false);
set role authenticated;
:ATTEMPT
reset role;
select set_config('request.jwt.claims', '', false);

select pg_temp.ck('2a titolare: all four direct inserts refused (42501)',
  (select res from d2_attempts where who = 'titolare') = '{"milk":"42501","promo":"42501","dop":"42501","po":"42501"}'::jsonb, (select res::text from d2_attempts where who = 'titolare'));
select pg_temp.ck('2b socio: all four direct inserts refused (42501)',
  (select res from d2_attempts where who = 'socio') = '{"milk":"42501","promo":"42501","dop":"42501","po":"42501"}'::jsonb, (select res::text from d2_attempts where who = 'socio'));
select pg_temp.ck('2c produzione: all four direct inserts refused (42501), the milk-plan revival included',
  (select res from d2_attempts where who = 'produzione') = '{"milk":"42501","promo":"42501","dop":"42501","po":"42501"}'::jsonb, (select res::text from d2_attempts where who = 'produzione'));
select pg_temp.ck('2d banco: all four direct inserts refused (42501)',
  (select res from d2_attempts where who = 'banco') = '{"milk":"42501","promo":"42501","dop":"42501","po":"42501"}'::jsonb, (select res::text from d2_attempts where who = 'banco'));
select pg_temp.ck('2e spedizioni: all four direct inserts refused (42501), the 100 % promo included',
  (select res from d2_attempts where who = 'spedizioni') = '{"milk":"42501","promo":"42501","dop":"42501","po":"42501"}'::jsonb, (select res::text from d2_attempts where who = 'spedizioni'));
select pg_temp.ck('2f consulente: all four refused (42501), as before',
  (select res from d2_attempts where who = 'consulente') = '{"milk":"42501","promo":"42501","dop":"42501","po":"42501"}'::jsonb, (select res::text from d2_attempts where who = 'consulente'));
select pg_temp.ck('2g a login with no staff row: all four refused (42501), as before',
  (select res from d2_attempts where who = 'senza_staff') = '{"milk":"42501","promo":"42501","dop":"42501","po":"42501"}'::jsonb, (select res::text from d2_attempts where who = 'senza_staff'));
select pg_temp.ck('2h no approval row was created by any login attempt',
  not exists (select 1 from fabula.approvals where summary like 'D2-ATTACK%'),
  (select string_agg(summary, ', ') from fabula.approvals where summary like 'D2-ATTACK%'));
select pg_temp.ck('2i no login-created approval carries an auto-approval timer',
  not exists (select 1 from fabula.approvals where summary like 'D2-ATTACK%' and auto_approve_at is not null),
  (select string_agg(summary || ' → ' || auto_approve_at::text, ', ') from fabula.approvals where summary like 'D2-ATTACK%' and auto_approve_at is not null));

-- ============================== 3. the proposal functions, called directly by a login ==============================
-- fixtures that make each function want to create an approval
update fabula.settings set value = 'RINA-T-D2' where key = 'dop.rina_code';
insert into fabula.stock_moves (product_id, lot_number, move_type, qty, expiry_date, moved_at, source)
select id, 'LD2-SD', 'production_out', 15, :'d'::date + 2, now(), 'test' from fabula.products where sku = 'MOZ-DOP-KG';
insert into fabula.parties (type, legal_name) values ('supplier', 'Sale D2 Srl');
update fabula.products set reorder_point = 50, preferred_supplier_id = (select id from fabula.parties where legal_name = 'Sale D2 Srl') where sku = 'CON-SALT';
insert into fabula.stock_moves (product_id, move_type, qty, moved_at, source) select id, 'adjustment', 5, now(), 'test' from fabula.products where sku = 'CON-SALT';
insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, output_kg, input_kind, started_at, finished_at, source)
select :'d', 'LD2-RT', finished_product_id, 300, 60, 'milk', now() - interval '3 hours', now() - interval '1 hour', 'test'
from fabula.recipes where valid_to is null order by id limit 1;
insert into fabula.batch_consumables (batch_id, product_id, qty, recipe_id, qty_standard, entry)
select b.id, r.component_product_id, 2.0, r.id, 1.0, 'confirmed'
from fabula.production_batches b, (select * from fabula.recipes where valid_to is null order by id limit 1) r where b.batch_lot = 'LD2-RT';
select set_config('d2.dp', :'d_plan', false), set_config('d2.dsd', (:'d'::date + 1)::text, false);

-- positive control: as the database owner (the bots' and cron's role) each function DOES create an approval (then rolled back)
create temp table d2_ctl (fn text primary key, created int);
do $$ declare n0 int; n1 int; f text; begin
  foreach f in array array['plan_milk', 'propose_purchase_orders', 'recipe_tuning_proposals', 'sell_down_signals', 'consorzio_declaration'] loop
    begin
      select count(*) into n0 from fabula.approvals;
      case f
        when 'plan_milk' then perform fabula.plan_milk(current_setting('d2.dp')::date);
        when 'propose_purchase_orders' then perform fabula.propose_purchase_orders();
        when 'recipe_tuning_proposals' then perform fabula.recipe_tuning_proposals(1, 10);
        when 'sell_down_signals' then perform fabula.sell_down_signals(current_setting('d2.dsd')::date);
        when 'consorzio_declaration' then perform fabula.consorzio_declaration('2025-03-01');
      end case;
      select count(*) into n1 from fabula.approvals;
      raise exception using errcode = 'P0001', message = 'd2_rollback';
    exception when raise_exception then null;
    end;
    insert into d2_ctl values (f, n1 - n0);
  end loop;
end $$;
select pg_temp.ck('3a positive control: as the owner, each of the five functions creates at least one approval with these fixtures',
  (select count(*) from d2_ctl where created >= 1) = 5, (select string_agg(fn || '=' || created, ', ' order by fn) from d2_ctl));

-- the same five calls by the most privileged login (titolare) and by a production login
create temp table d2_fn (who text, fn text, res text, primary key (who, fn));
grant all on d2_fn to authenticated;
\set CALLS 'do $$ declare f text; n0 int; n1 int; r text; tag text := current_setting(''d2.who''); begin foreach f in array array[''plan_milk'', ''propose_purchase_orders'', ''recipe_tuning_proposals'', ''sell_down_signals'', ''consorzio_declaration''] loop r := null; begin case f when ''plan_milk'' then perform fabula.plan_milk(current_setting(''d2.dp'')::date); when ''propose_purchase_orders'' then perform fabula.propose_purchase_orders(); when ''recipe_tuning_proposals'' then perform fabula.recipe_tuning_proposals(1, 10); when ''sell_down_signals'' then perform fabula.sell_down_signals(current_setting(''d2.dsd'')::date); when ''consorzio_declaration'' then perform fabula.consorzio_declaration(''2025-03-01''); end case; r := ''ran''; exception when others then r := sqlstate; end; insert into d2_fn values (tag, f, r); end loop; end $$;'
select count(*) appr_before_calls from fabula.approvals \gset
select set_config('d2.who', 'titolare', false), set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-00000000d201","role":"authenticated"}', false);
set role authenticated;
:CALLS
reset role;
select set_config('d2.who', 'produzione', false), set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-00000000d203","role":"authenticated"}', false);
set role authenticated;
:CALLS
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('3b titolare login: all five proposal functions refused with 42501 (they reach the approvals insert as the login)',
  (select count(*) from d2_fn where who = 'titolare' and res = '42501') = 5, (select string_agg(fn || '=' || res, ', ' order by fn) from d2_fn where who = 'titolare'));
select pg_temp.ck('3c produzione login: all five proposal functions refused with 42501',
  (select count(*) from d2_fn where who = 'produzione' and res = '42501') = 5, (select string_agg(fn || '=' || res, ', ' order by fn) from d2_fn where who = 'produzione'));
select pg_temp.ck('3d no approval was created by those ten calls', (select count(*) from fabula.approvals) = :appr_before_calls,
  (select count(*) - :appr_before_calls || ' new' from fabula.approvals));
select pg_temp.ck('3e EXECUTE on the five functions is unchanged (still granted to logins: the INSERT grant is what stops them)',
  (select bool_and(has_function_privilege('authenticated', p.oid, 'EXECUTE') and not p.prosecdef) from pg_proc p
    where p.pronamespace = 'fabula'::regnamespace and p.proname in ('plan_milk', 'propose_purchase_orders', 'recipe_tuning_proposals', 'sell_down_signals', 'consorzio_declaration')));

-- ============================== 4. rejected milk plans stay rejected ==============================
select fabula.auto_approve_due(now() + interval '2 hours') aa1 \gset
select pg_temp.ck('4a the plan targeted by the login attempts is still rejected after the auto-approval run',
  (select status from fabula.milk_plans where id = :'rej_login') = 'rejected', (select status from fabula.milk_plans where id = :'rej_login'));
-- defence in depth: even an approval created at owner level (e.g. a misbehaving bot) pointing at a rejected plan cannot revive it
insert into fabula.approvals (kind, requested_by, summary, payload, related_table, related_id, amount_eur, expires_at)
values ('other', 'agent:milk_planning', 'D2-OWNER revive', jsonb_build_object('type', 'milk_plan', 'plan_date', :'d'::date + 31), 'milk_plans', :'rej_bot', 100, now() + interval '1 day');
select pg_temp.ck('4b an owner-level row behaves as before: it gets its auto-approval timer from the rule',
  (select auto_approve_at is not null and auto_rule like 'piano latte nella norma%' from fabula.approvals where summary = 'D2-OWNER revive'));
select fabula.auto_approve_due(now() + interval '2 hours') aa2 \gset
select pg_temp.ck('4c …and the rule approves the request, but the rejected plan is NOT moved to approved (the farm never sees it)',
  (select status::text from fabula.approvals where summary = 'D2-OWNER revive') = 'approved'
  and (select status from fabula.milk_plans where id = :'rej_bot') = 'rejected',
  (select status from fabula.milk_plans where id = :'rej_bot'));

-- ============================== 5. sell-down codes: only bot promos within the standard discount and a real end ==============================
insert into fabula.approvals (kind, requested_by, summary, payload, expires_at) values
 ('price_change', 'agent:sell_down', 'D2 promo ok',      '{"type":"sell_down","action":"promo_banco","promo_pct":30,"at_risk_kg":12,"lot":"LP1","sku":"MOZ-DOP-KG"}', now() + interval '8 hours'),
 ('price_change', 'agent:sell_down', 'D2 promo 100',     '{"type":"sell_down","action":"promo_banco","promo_pct":100,"at_risk_kg":12,"lot":"LP2","sku":"MOZ-DOP-KG"}', now() + interval '8 hours'),
 ('price_change', 'agent:sell_down', 'D2 promo 40',      '{"type":"sell_down","action":"promo_banco","promo_pct":40,"at_risk_kg":12,"lot":"LP3","sku":"MOZ-DOP-KG"}', now() + interval '8 hours'),
 ('price_change', 'agent:sell_down', 'D2 promo 0',       '{"type":"sell_down","action":"promo_banco","promo_pct":0,"at_risk_kg":12,"lot":"LP4","sku":"MOZ-DOP-KG"}', now() + interval '8 hours'),
 ('price_change', 'agent:sell_down', 'D2 promo noend',   '{"type":"sell_down","action":"promo_banco","promo_pct":30,"at_risk_kg":12,"lot":"LP6","sku":"MOZ-DOP-KG"}', null),
 ('price_change', 'agent:sell_down', 'D2 promo 30days',  '{"type":"sell_down","action":"promo_banco","promo_pct":30,"at_risk_kg":12,"lot":"LP7","sku":"MOZ-DOP-KG"}', now() + interval '30 days'),
 ('price_change', 'agent:sell_down', 'D2 promo past',    '{"type":"sell_down","action":"promo_banco","promo_pct":30,"at_risk_kg":12,"lot":"LP8","sku":"MOZ-DOP-KG"}', now() - interval '1 hour'),
 ('price_change', 'agent:marketing', 'D2 promo other',   '{"type":"sell_down","action":"promo_banco","promo_pct":30,"at_risk_kg":12,"lot":"LP9","sku":"MOZ-DOP-KG"}', now() + interval '8 hours');
select fabula.sell_down_codes_needed() codes \gset
create temp table d2_codes as select e->>'lot' lot, e from jsonb_array_elements(:'codes'::jsonb) e;
select pg_temp.ck('5a a 100 % promo is not surfaced for a Shopify code', not exists (select 1 from d2_codes where lot = 'LP2'));
select pg_temp.ck('5b a promo above the standard discount (sell.promo_pct = 30) is not surfaced', not exists (select 1 from d2_codes where lot = 'LP3'));
select pg_temp.ck('5c a 0 % promo is not surfaced', not exists (select 1 from d2_codes where lot = 'LP4'));
select pg_temp.ck('5d a promo with no end is not surfaced', not exists (select 1 from d2_codes where lot = 'LP6'));
select pg_temp.ck('5e a promo ending more than 48 hours ahead is not surfaced', not exists (select 1 from d2_codes where lot = 'LP7'));
select pg_temp.ck('5f an expired promo is not surfaced (as before)', not exists (select 1 from d2_codes where lot = 'LP8'));
select pg_temp.ck('5g a promo not requested by the sell-down bot is not surfaced', not exists (select 1 from d2_codes where lot = 'LP9'));
select pg_temp.ck('5h the standard bot promo (30 %, ends in 8 h) IS surfaced, with its end date and 0.30',
  (select (e->>'percentage')::numeric = 0.30 and (e->>'ends_at') is not null and e->>'title' like 'Promo scorte lotto LP1 (-30%)' and e->>'code' ~ '^SC[0-9A-F]{8}$'
     from d2_codes where lot = 'LP1'), (select e::text from d2_codes where lot = 'LP1'));

-- 5i a malformed promo row (non-numeric discount) must not break the whole list for the bot. Such a row can only exist while
-- automatic promo approval is switched off (with it on, the auto rule's own cast refuses the insert), so the check switches it off.
update fabula.settings set value = '0' where key = 'approve.auto_promo';
insert into fabula.approvals (kind, requested_by, summary, payload, expires_at) values
 ('price_change', 'agent:sell_down', 'D2 promo text', '{"type":"sell_down","action":"promo_banco","promo_pct":"tutto","at_risk_kg":12,"lot":"LP5","sku":"MOZ-DOP-KG"}', now() + interval '8 hours');
update fabula.settings set value = '1' where key = 'approve.auto_promo';
create temp table d2_txt (res text);
do $$ declare r jsonb; begin
  r := fabula.sell_down_codes_needed();
  insert into d2_txt values (case when exists (select 1 from jsonb_array_elements(r) e where e->>'lot' = 'LP5') then 'listed' else 'ok' end);
exception when others then insert into d2_txt values ('ERR ' || sqlstate || ' ' || sqlerrm);
end $$;
select pg_temp.ck('5i a promo with a non-numeric discount is skipped and the list still works for the others',
  (select res from d2_txt) = 'ok', (select res from d2_txt));
delete from fabula.approvals where summary = 'D2 promo text';   -- keep the rest of the suite independent of 5i

-- ============================== 6. what must keep working ==============================
-- 6a bots / cron: the real sell-down function (owner) creates its promo, and it is surfaced for the code
select fabula.sell_down_signals(:'d'::date + 1) sds \gset
select pg_temp.ck('6a the sell-down bot''s own function creates its promo (owner), and the promo is surfaced for a code',
  exists (select 1 from fabula.approvals where requested_by = 'agent:sell_down' and payload->>'lot' = 'LD2-SD')
  and exists (select 1 from jsonb_array_elements(fabula.sell_down_codes_needed()) e where e->>'lot' = 'LD2-SD'),
  :'sds');
select id sd_appr from fabula.approvals where requested_by = 'agent:sell_down' and payload->>'lot' = 'LD2-SD' order by requested_at desc limit 1 \gset
select fabula.promo_set_code(:'sd_appr', 'SCD2TEST1', 'gid://shopify/DiscountCodeNode/1') psc \gset
select pg_temp.ck('6b recording the code (promo_set_code) still works, and the promo leaves the list',
  (select payload->>'shopify_code' from fabula.approvals where id = :'sd_appr') = 'SCD2TEST1'
  and not exists (select 1 from jsonb_array_elements(fabula.sell_down_codes_needed()) e where e->>'approval_id' = :'sd_appr'));
-- 6c (the five proposal functions run by the owner are proven by 3a, which runs before any login attempt)
select fabula.plan_milk(:'d_plan2'::date) pm \gset
select :'pm'::jsonb->>'approval_id' pm_appr \gset
select related_id pm_plan from fabula.approvals where id = :'pm_appr' \gset
select pg_temp.ck('6c the milk-planning function (owner) still creates its plan and request for the decide/undo checks',
  :'pm_appr' <> '' and :'pm_plan' <> '', :'pm');
-- 6d the local-campaign request made by the marketing bot (owner) still creates its approval through mkt_local_before
update fabula.mkt_local_items set quote_eur = 300, vendor = 'Tipografia D2', status = 'in_approvazione' where code = 'SIG-02';
select pg_temp.ck('6d local campaign: the marketing bot''s «in_approvazione» still creates its spend request (agent:marketing)',
  exists (select 1 from fabula.approvals a join fabula.mkt_local_items i on i.approval_id = a.id
           where i.code = 'SIG-02' and a.requested_by = 'agent:marketing' and a.payload->>'type' = 'local_spend' and a.status = 'pending'));
-- 6e the same transition done by a login through the API is now refused (no app page does this; only the bot)
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-00000000d201","role":"authenticated"}', false);
create temp table d2_mli (res text); grant all on d2_mli to authenticated;
set role authenticated;
do $$ begin
  update fabula.mkt_local_items set quote_eur = 120, status = 'in_approvazione' where code = 'SIG-04';
  insert into d2_mli values ('ok');
exception when others then insert into d2_mli values (sqlstate);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('6e a login setting a campaign item to «in_approvazione» directly is refused (42501) and creates nothing',
  (select res from d2_mli) = '42501' and (select approval_id is null and status <> 'in_approvazione' from fabula.mkt_local_items where code = 'SIG-04'),
  (select res from d2_mli));
-- 6f decide, undo, decide again, as the titolare login: rejected → (undo) → proposed → approved
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-00000000d201","role":"authenticated"}', false);
set role authenticated;
select fabula.decide_approval(:'pm_appr', 'rejected', 'test D2', null, true) dec1 \gset
reset role;
select status pl1 from fabula.milk_plans where id = :'pm_plan' \gset
set role authenticated;
select fabula.revoke_approval(:'pm_appr', 'test D2 undo') rev1 \gset
reset role;
select status pl2 from fabula.milk_plans where id = :'pm_plan' \gset
set role authenticated;
select fabula.decide_approval(:'pm_appr', 'approved', 'test D2', null, true) dec2 \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('6f decide_approval: a person''s rejection still rejects the plan',
  :'pl1' = 'rejected', :'dec1');
select pg_temp.ck('6g revoke_approval: undoing the rejection puts the request back to pending and the plan back to proposed',
  (:'rev1'::jsonb->>'status') = 'pending' and :'pl2' = 'proposed', :'rev1');
select pg_temp.ck('6h decide_approval after the undo: approved, and the plan is approved (proposed → approved is unaffected)',
  (select status::text from fabula.approvals where id = :'pm_appr') = 'approved'
  and (select status from fabula.milk_plans where id = :'pm_plan') = 'approved', :'dec2');
-- 6i automatic approval of a normal bot plan, and expiry of another
insert into fabula.milk_plans (plan_date, milk_kg, planned_output_kg, details) values
 (:'d'::date + 40, 800, 240, '{"history_source":"same_weekday_4w","history_days":4,"last_4w_same_weekday_milk_kg":760,"capacity_hit":false,"min_run_applied":false,"exceeds_farm_supply":false,"is_simulation":false}'),
 (:'d'::date + 41, 1200, 360, '{"history_source":"none","history_days":0}');
insert into fabula.approvals (kind, requested_by, summary, payload, related_table, related_id, amount_eur, expires_at)
select 'other', 'agent:milk_planning', 'D2 auto ' || (plan_date - :'d'::date), jsonb_build_object('type', 'milk_plan', 'plan_date', plan_date, 'milk_kg', milk_kg), 'milk_plans', id, 100,
       case when plan_date = :'d'::date + 40 then now() + interval '1 day' else now() + interval '1 minute' end
from fabula.milk_plans where plan_date in (:'d'::date + 40, :'d'::date + 41);
select pg_temp.ck('6i a normal bot milk plan still gets its auto-approval timer; the unusual one does not',
  (select auto_approve_at is not null from fabula.approvals where summary = 'D2 auto 40')
  and (select auto_approve_at is null from fabula.approvals where summary = 'D2 auto 41'));
select fabula.auto_approve_due(now() + interval '2 hours') aa3 \gset
select pg_temp.ck('6j auto_approve_due still approves it and the plan becomes approved',
  (select status::text from fabula.approvals where summary = 'D2 auto 40') = 'approved'
  and (select status from fabula.milk_plans where plan_date = :'d'::date + 40) = 'approved', :'aa3');
select pg_temp.ck('6k expiry still works: the request past its time is expired and its plan rejected',
  (select status::text from fabula.approvals where summary = 'D2 auto 41') = 'expired'
  and (select status from fabula.milk_plans where plan_date = :'d'::date + 41) = 'rejected',
  (select status::text from fabula.approvals where summary = 'D2 auto 41'));
-- 6l a login's legitimate «order milk again» from the Console (definer path) still creates and approves its plan
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-00000000d201","role":"authenticated"}', false);
create temp table d2_moa (res text); grant all on d2_moa to authenticated;
set role authenticated;
do $$ declare r jsonb; begin
  r := fabula.milk_order_again(current_setting('d2.again')::date, 1200, 'test D2', true);   -- the Console sends the kg the person chose
  insert into d2_moa values (r::text);
exception when others then insert into d2_moa values ('ERR ' || sqlstate || ' ' || sqlerrm);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('6l Console «Ordina di nuovo» (milk_order_again, titolare login): plan created and approved, no permission error',
  (select res not like 'ERR%' from d2_moa)
  and exists (select 1 from fabula.milk_plans where plan_date = :'d_again'::date and status = 'approved'),
  (select left(res, 200) from d2_moa));
-- 6m Console «Esegui ora» on a bot stand-in (run_bot_fallback, titolare login) still creates its request
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-00000000d201","role":"authenticated"}', false);
create temp table d2_rbf (res text); grant all on d2_rbf to authenticated;
set role authenticated;
do $$ declare r jsonb; begin
  r := fabula.run_bot_fallback('procurement', true);
  insert into d2_rbf values (r::text);
exception when others then insert into d2_rbf values ('ERR ' || sqlstate || ' ' || sqlerrm);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('6m Console «Esegui ora» (run_bot_fallback procurement, titolare login): runs as the database, no permission error',
  (select res not like 'ERR%' from d2_rbf), (select left(res, 300) from d2_rbf));
