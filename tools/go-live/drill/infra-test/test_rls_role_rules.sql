-- v1.01a RLS role rules: the delete hole on five tables, the base rules no longer `true`, and the scan checks · fresh replay:
--   tools/go-live/drill/infra-test/replay.sh rls_test
--   su postgres -c "psql -d rls_test -f tools/go-live/drill/infra-test/test_rls_role_rules.sql" | grep -E "PASS|FAIL"
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;

-- ---------------------------------------------------------------- 1. the rules
select pg_temp.ck('no write rule reads `true` any more',
  not exists (select 1 from pg_policies where schemaname in ('fabula', 'public') and permissive = 'PERMISSIVE' and cmd <> 'SELECT'
                 and (coalesce(qual, '') = 'true' or coalesce(with_check, '') = 'true')));
select pg_temp.ck('the five tables have a RESTRICTIVE delete rule',
  (select count(*) from pg_policies where schemaname = 'fabula' and permissive = 'RESTRICTIVE' and cmd = 'DELETE'
      and tablename in ('bank_rules', 'milk_shipments', 'payment_payouts', 'payment_transactions', 'recon_acks')
      and policyname = tablename || '_role_delete' and qual like '%can_table(%, true)%') = 5);
select pg_temp.ck('base rules read «signed in» on both sides (ALL, UPDATE with its WITH CHECK, INSERT)',
  (select qual = '(( SELECT auth.uid() AS uid) IS NOT NULL)' and with_check = qual from pg_policies where policyname = 'bank_rules_authenticated_all')
  and (select qual = '(( SELECT auth.uid() AS uid) IS NOT NULL)' and with_check = qual from pg_policies where policyname = 'dash_checks_update')
  and (select with_check = '(( SELECT auth.uid() AS uid) IS NOT NULL)' from pg_policies where policyname = 'haccp_forms_insert'));
select pg_temp.ck('read rules `using (true)` left as they were (the dashboard does not flag them)',
  (select qual from pg_policies where schemaname = 'fabula' and policyname = 'audit_log_read') = 'true');

-- ---------------------------------------------------------------- 2. the scan on the migrated schema
select fabula.security_scan() s0 \gset
select pg_temp.ck('scan: nothing new after the migration', (:'s0'::jsonb->'new') = '[]'::jsonb, left(:'s0', 300));
select pg_temp.ck('scan: no open write without a role rule, no always-true rule',
  not exists (select 1 from fabula.security_findings() where lint = 'permissive_rls_policy' or (lint = 'rls_open_without_role_rule' and level = 'ERROR')));
select pg_temp.ck('scan: the open reads are exactly the four permission tables and record_corrections, all accepted',
  (select string_agg(f.object, ',' order by f.object) from fabula.security_findings() f join fabula.security_accepted a using (key)
    where f.lint = 'rls_open_without_role_rule')
  = 'fabula.app_areas (SELECT),fabula.app_roles (SELECT),fabula.record_corrections (SELECT),fabula.role_permissions (SELECT),fabula.table_areas (SELECT)');
select pg_temp.ck('scan functions still closed to app logins and anon',
  not has_function_privilege('authenticated', 'fabula.security_findings()', 'execute')
  and not has_function_privilege('anon', 'fabula.security_findings()', 'execute')
  and not has_function_privilege('authenticated', 'fabula.infra_record_advisors(jsonb)', 'execute')
  and has_function_privilege('service_role', 'fabula.security_findings()', 'execute'));

-- ---------------------------------------------------------------- 3. who may delete
insert into auth.users (id, email) values
  ('00000000-0000-4000-a000-0000000000c1', 'casaro@x.it'), ('00000000-0000-4000-a000-0000000000c2', 'cons@x.it'),
  ('00000000-0000-4000-a000-0000000000c3', 'mkt@x.it'), ('00000000-0000-4000-a000-0000000000c4', 'own@x.it');
insert into fabula.staff (id, full_name, auth_user_id, app_role, role, active) values
  ('10000000-0000-4000-a000-0000000000c1', 'Casaro RLS', '00000000-0000-4000-a000-0000000000c1', 'produzione', 'casaro', true),
  ('10000000-0000-4000-a000-0000000000c2', 'Consulente RLS', '00000000-0000-4000-a000-0000000000c2', 'consulente', 'consulente', true),
  ('10000000-0000-4000-a000-0000000000c3', 'Marketing RLS', '00000000-0000-4000-a000-0000000000c3', 'marketing', 'commesso', true),
  ('10000000-0000-4000-a000-0000000000c4', 'Owner RLS', '00000000-0000-4000-a000-0000000000c4', 'titolare', 'owner', true);
insert into fabula.bank_rules (pattern, match_kind) values ('ZZRLS', 'contains');
insert into fabula.recon_acks (key) values ('zz:rls');
insert into fabula.payment_payouts (id, payout_date, net_eur) values ('ZZRLS', current_date, 10);
insert into fabula.payment_transactions (id, tx_at, tx_type, amount_eur, net_eur) values ('ZZRLS', now(), 'charge', 10, 9.7);
insert into fabula.milk_shipments (milk_lot, kg) values ('ZZRLS', 100);
create or replace function pg_temp.left_rows() returns text language sql as $$
  select concat_ws(',', (select count(*) from fabula.bank_rules where pattern = 'ZZRLS'), (select count(*) from fabula.recon_acks where key = 'zz:rls'),
                   (select count(*) from fabula.payment_payouts where id = 'ZZRLS'), (select count(*) from fabula.payment_transactions where id = 'ZZRLS'),
                   (select count(*) from fabula.milk_shipments where milk_lot = 'ZZRLS')) $$;

-- production login (finanza: nessuno): a plain DELETE with no filter used to empty these tables without seeing them
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-0000000000c1","role":"authenticated"}', false);
set role authenticated;
delete from fabula.bank_rules; delete from fabula.recon_acks; delete from fabula.payment_payouts; delete from fabula.payment_transactions;
reset role;
select pg_temp.ck('production login: an unfiltered DELETE removes nothing from the four finance tables', pg_temp.left_rows() = '1,1,1,1,1', pg_temp.left_rows());

-- consultant (finanza: vede) sees the finance rows but may not delete them
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-0000000000c2","role":"authenticated"}', false);
set role authenticated;
select pg_temp.ck('consultant still reads the finance rows', (select count(*) from fabula.bank_rules where pattern = 'ZZRLS') = 1);
delete from fabula.bank_rules where pattern = 'ZZRLS'; delete from fabula.payment_transactions where id = 'ZZRLS';
reset role;
select pg_temp.ck('consultant (vede): DELETE refused on finance rows it can see', pg_temp.left_rows() = '1,1,1,1,1', pg_temp.left_rows());

-- marketing (produzione: vede) sees milk shipments but may not delete or add them
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-0000000000c3","role":"authenticated"}', false);
set role authenticated;
select pg_temp.ck('marketing still reads milk shipments', (select count(*) from fabula.milk_shipments where milk_lot = 'ZZRLS') = 1);
delete from fabula.milk_shipments where milk_lot = 'ZZRLS';
do $$ begin insert into fabula.milk_shipments (milk_lot, kg) values ('ZZRLS-M', 50); raise notice 'M accepted'; exception when others then raise notice 'M refused'; end $$;
reset role;
select pg_temp.ck('marketing (vede): DELETE refused on milk shipments, insert still refused',
  pg_temp.left_rows() = '1,1,1,1,1' and not exists (select 1 from fabula.milk_shipments where milk_lot = 'ZZRLS-M'), pg_temp.left_rows());

-- the base rules still let a signed-in user write where the role allows it
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-0000000000c1","role":"authenticated"}', false);
set role authenticated;
do $$ begin insert into fabula.milk_shipments (milk_lot, kg) values ('ZZRLS-P', 80); exception when others then raise notice 'P refused: %', sqlerrm; end $$;
reset role;
select pg_temp.ck('production login still records a milk shipment (produzione: registra)', exists (select 1 from fabula.milk_shipments where milk_lot = 'ZZRLS-P'));

-- a token with the authenticated role but no user id writes nothing (as before: the role rules need a person)
select set_config('request.jwt.claims', '{"role":"authenticated"}', false);
set role authenticated;
do $$ begin insert into fabula.milk_shipments (milk_lot, kg) values ('ZZRLS-N', 70); exception when others then null; end $$;
delete from fabula.milk_shipments where milk_lot = 'ZZRLS';
reset role;
select pg_temp.ck('no user id: insert and delete refused',
  not exists (select 1 from fabula.milk_shipments where milk_lot = 'ZZRLS-N') and pg_temp.left_rows() = '1,1,1,1,1');

-- the owner keeps every right
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-0000000000c4","role":"authenticated"}', false);
set role authenticated;
delete from fabula.bank_rules where pattern = 'ZZRLS'; delete from fabula.recon_acks where key = 'zz:rls';
delete from fabula.payment_payouts where id = 'ZZRLS'; delete from fabula.payment_transactions where id = 'ZZRLS';
delete from fabula.milk_shipments where milk_lot = 'ZZRLS';
reset role;
select pg_temp.ck('owner (gestisce) still deletes in all five tables', pg_temp.left_rows() = '0,0,0,0,0', pg_temp.left_rows());
select set_config('request.jwt.claims', '', false);

-- ---------------------------------------------------------------- 4. the scan catches the same mistake on a new table
create table fabula.zz_probe (id int primary key, note text);
alter table fabula.zz_probe enable row level security;
grant select, insert, update, delete on fabula.zz_probe to authenticated;
create policy zz_probe_authenticated_all on fabula.zz_probe for all to authenticated using (true) with check (true);
create policy zz_probe_role_select on fabula.zz_probe as restrictive for select to authenticated using ((select fabula.can_table('zz_probe', false)));
create policy zz_probe_role_insert on fabula.zz_probe as restrictive for insert to authenticated with check ((select fabula.can_table('zz_probe', true)));
create policy zz_probe_role_update on fabula.zz_probe as restrictive for update to authenticated using ((select fabula.can_table('zz_probe', true)));
create policy zz_probe_manager_update on fabula.zz_probe for update to authenticated using (fabula.is_manager());
create table fabula.zz_open_read (id int primary key);
alter table fabula.zz_open_read enable row level security;
create policy zz_open_read_read on fabula.zz_open_read for select to authenticated using (true);

select pg_temp.ck('old pattern without a delete rule: ERROR «open delete», WARN always-true and missing WITH CHECK',
  (select string_agg(key || '/' || level, ' ' order by key) from fabula.security_findings() where object like 'fabula.zz_probe%')
  = 'permissive_rls_policy:fabula.zz_probe (zz_probe_authenticated_all)/WARN permissive_rls_policy:fabula.zz_probe (zz_probe_manager_update)/WARN rls_open_without_role_rule:fabula.zz_probe (DELETE)/ERROR',
  (select string_agg(key || '/' || level, ' ' order by key) from fabula.security_findings() where object like 'fabula.zz_probe%'));
select pg_temp.ck('an open read with no role rule is a WARN',
  (select string_agg(key || '/' || level, ' ') from fabula.security_findings() where object like 'fabula.zz_open_read%')
  = 'rls_open_without_role_rule:fabula.zz_open_read (SELECT)/WARN');
select fabula.security_scan() s1 \gset
select pg_temp.ck('board: the scan turns red with an alert notice in the Console',
  jsonb_array_length(:'s1'::jsonb->'new') = 4 and not (select ok from fabula.infra_status where key = 'security_scan')
  and (select severity = 'alert' and resolved_at is null from fabula.notices where key = 'infra_security'), left(:'s1', 300));

alter policy zz_probe_authenticated_all on fabula.zz_probe using ((select auth.uid()) is not null) with check ((select auth.uid()) is not null);
alter policy zz_probe_manager_update on fabula.zz_probe using (fabula.is_manager()) with check (fabula.is_manager());
create policy zz_probe_role_delete on fabula.zz_probe as restrictive for delete to authenticated using ((select fabula.can_table('zz_probe', true)));
select pg_temp.ck('new pattern (signed in + four role rules): no finding left on the table',
  not exists (select 1 from fabula.security_findings() where object like 'fabula.zz_probe%'));
create policy zz_probe_bad_role_delete on fabula.zz_probe as restrictive for delete to authenticated using (true);
drop policy zz_probe_role_delete on fabula.zz_probe;
select pg_temp.ck('a RESTRICTIVE rule that is itself `true` does not count as a role rule',
  exists (select 1 from fabula.security_findings() where key = 'rls_open_without_role_rule:fabula.zz_probe (DELETE)'));

drop table fabula.zz_probe; drop table fabula.zz_open_read;
select fabula.security_scan() s2 \gset
select pg_temp.ck('tables gone: scan clean again, Console notice resolved',
  (:'s2'::jsonb->'new') = '[]'::jsonb and (select ok from fabula.infra_status where key = 'security_scan')
  and (select resolved_at is not null from fabula.notices where key = 'infra_security'), left(:'s2', 200));

-- ---------------------------------------------------------------- 5. advisor cross-check knows the new lint
select fabula.infra_record_advisors('[{"name":"permissive_rls_policy","level":"WARN","count":0}]'::jsonb) a1 \gset
select pg_temp.ck('advisor reporting permissive_rls_policy = 0 matches the scan', (:'a1'::jsonb->'unknown') = '[]'::jsonb, :'a1');
select fabula.infra_record_advisors('[{"name":"permissive_rls_policy","level":"WARN","count":102}]'::jsonb) a2 \gset
select pg_temp.ck('advisor reporting 102 is flagged against the scan''s 0',
  (:'a2'::jsonb->'unknown'->0->>'why') = 'advisor 102, SQL scan 0' and not (select ok from fabula.infra_status where key = 'advisors'), :'a2');
select fabula.infra_record_advisors('[]'::jsonb) a3 \gset
