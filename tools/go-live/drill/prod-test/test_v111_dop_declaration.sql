-- v1.11 · no Consorzio declaration before the caseificio is under DOP control (R-01) · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh d_test
--   su postgres -c "psql -d d_test -f tools/go-live/drill/prod-test/test_v111_dop_declaration.sql" | grep -E "PASS|FAIL"
-- The replay has no lots, milk or approvals. Months used: last month (the cron's default), 03/2025 (an empty month) and this month
-- (one DOP lot made today, so no back-dating guard is involved).
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
select (now() at time zone 'Europe/Rome')::date d \gset
select to_char(date_trunc('month', :'d'::date) - interval '1 month', 'YYYY-MM') prev_m \gset
select to_char(:'d'::date, 'YYYY-MM') cur_m \gset
select id moz from fabula.products where sku = 'MOZ-DOP-KG' \gset
create temp table r (k text primary key, j jsonb);

-- ============================== the setting ==============================
select pg_temp.ck('setting dop.rina_code: empty text, in the DOP section before the two DOP fees, explained',
  (select value = '' and data_type = 'text' and sort < (select min(sort) from fabula.settings where key in ('dop.consorzio_eur_kg', 'dop.rina_eur_kg'))
          and description ilike '%RINA%' and description ilike '%dichiarazione%'
     from fabula.settings where key = 'dop.rina_code'));
select pg_temp.ck('a socio may fill it in (not a protected setting)', not fabula.setting_protected('dop.rina_code'));

-- ============================== before the code: nothing proposed ==============================
insert into r select 'cron', fabula.consorzio_declaration();
select pg_temp.ck('the cron call (last month, no code, no lot): skipped, no approval',
  (select (j->>'skipped')::boolean and not (j->>'approval_created')::boolean and j->>'month' = :'prev_m' from r where k = 'cron')
  and not exists (select 1 from fabula.approvals where kind = 'dop_declaration'),
  (select j->>'skip_it' from r where k = 'cron'));
select pg_temp.ck('it still returns the month''s figures (0 kg, 0 lots) and says why in Italian',
  (select (j->>'mozzarella_dop_kg')::numeric = 0 and (j->>'batches')::int = 0 and j ? 'issues' and j ? 'consorzio'
          and j->>'skip_it' like 'Nessuna dichiarazione per ' || to_char(date_trunc('month', :'d'::date) - interval '1 month', 'MM/YYYY') || '%RINA%'
     from r where k = 'cron'));
select pg_temp.ck('an empty month asked for by hand: skipped too', (fabula.consorzio_declaration('2025-03-15')->>'skipped')::boolean
  and not exists (select 1 from fabula.approvals where kind = 'dop_declaration'));
update fabula.settings set value = '   ' where key = 'dop.rina_code';
select pg_temp.ck('blanks count as empty', (fabula.consorzio_declaration('2025-03-01')->>'skipped')::boolean);

-- ============================== with the code: every month, 0 kg included ==============================
update fabula.settings set value = 'RINA-T-11535' where key = 'dop.rina_code';
insert into r select 'coded', fabula.consorzio_declaration('2025-03-01');
select pg_temp.ck('code set: the empty month is proposed (0 kg), as a dairy under control declares every month',
  (select (j->>'approval_created')::boolean and not j ? 'skipped' and j->>'rina_code' = 'RINA-T-11535' from r where k = 'coded')
  and (select count(*) = 1 and bool_and(status = 'pending' and summary like 'Dichiarazione Consorzio 03/2025:%mozzarella DOP 0 kg in 0 lotti%'
                                          and summary not like '%controlli da vedere%' and payload->>'rina_code' = 'RINA-T-11535')
         from fabula.approvals where kind = 'dop_declaration'),
  (select string_agg(summary, ' | ') from fabula.approvals where kind = 'dop_declaration'));
select pg_temp.ck('a second call for the same month proposes nothing more',
  not (fabula.consorzio_declaration('2025-03-01')->>'approval_created')::boolean
  and (select count(*) from fabula.approvals where kind = 'dop_declaration') = 1);

-- ============================== a DOP lot without the code (e.g. the trial week) ==============================
update fabula.settings set value = '' where key = 'dop.rina_code';
insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, output_kg, input_kind, started_at, finished_at, source)
values (:'d', 'LD111-A', :'moz', 300, 60, 'milk', now() - interval '3 hours', now() - interval '1 hour', 'test');
insert into r select 'lot', fabula.consorzio_declaration(:'d'::date);
select pg_temp.ck('a DOP lot in the month without the code: proposed, with the check «codice_rina» (1 lot)',
  (select (j->>'approval_created')::boolean and (j->>'batches')::int = 1 and (j->>'mozzarella_dop_kg')::numeric = 60 and j->'rina_code' = 'null'::jsonb
          and exists (select 1 from jsonb_array_elements(j->'issues') i where i->>'check' = 'codice_rina' and (i->>'n')::int = 1)
     from r where k = 'lot')
  and exists (select 1 from fabula.approvals where kind = 'dop_declaration' and payload->>'month' = :'cur_m' and summary like '%controlli da vedere%'),
  (select j->>'issues' from r where k = 'lot'));
update fabula.settings set value = 'RINA-T-11535' where key = 'dop.rina_code';
select pg_temp.ck('the same month once the code is in: no «codice_rina» check',
  not exists (select 1 from jsonb_array_elements(fabula.consorzio_declaration(:'d'::date)->'issues') i where i->>'check' = 'codice_rina'));
select pg_temp.ck('the other checks are unchanged (the lot has no milk linked → «lotti_senza_latte»)',
  exists (select 1 from jsonb_array_elements((select j->'issues' from r where k = 'lot')) i where i->>'check' = 'lotti_senza_latte' and (i->>'n')::int = 1));

-- ============================== unchanged around it ==============================
select pg_temp.ck('who may run it is unchanged: logins and the service role, not anon',
  has_function_privilege('authenticated', 'fabula.consorzio_declaration(date)', 'execute')
  and has_function_privilege('service_role', 'fabula.consorzio_declaration(date)', 'execute')
  and not has_function_privilege('anon', 'fabula.consorzio_declaration(date)', 'execute'));
select pg_temp.ck('still not a security definer function', not (select prosecdef from pg_proc where oid = 'fabula.consorzio_declaration(date)'::regprocedure));
select pg_temp.ck('the monthly job is still expected on the 1st at 05:30 UTC',
  exists (select 1 from fabula.cron_jobs_expected where jobname = 'fabula_consorzio_declaration' and schedule = '30 5 1 * *' and active));
