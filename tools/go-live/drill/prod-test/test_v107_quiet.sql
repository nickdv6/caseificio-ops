-- v1.07 «Prima dell'avvio» · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh q_test
--   su postgres -c "psql -d q_test -f tools/go-live/drill/prod-test/test_v107_quiet.sql" | grep -E "PASS|FAIL"
-- The tasks start 10 days from today (prod.tasks_from), so today and the next days are quiet.
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
insert into fabula.staff (id, full_name, role, app_role, active, auth_user_id) values
  ('10000000-0000-4000-a000-000000107a01', 'Titolare Q', 'owner', 'titolare', true, '00000000-0000-4000-a000-000000107a01')
on conflict do nothing;
\set tit_staff '10000000-0000-4000-a000-000000107a01'
select (now() at time zone 'Europe/Rome')::date d \gset
select (now() at time zone 'Europe/Rome')::date - 1 y \gset
-- the day the automatic plan works on: tomorrow, Monday when tomorrow is Sunday
select case when extract(isodow from :'d'::date + 1) = 7 then :'d'::date + 2 else :'d'::date + 1 end pd \gset
-- the next Monday (2..7 days ahead) and a Mon–Sat day for the evening check
select :'d'::date + (8 - extract(isodow from :'d'::date)::int) mon \gset
select case when extract(isodow from :'d'::date) = 7 then :'d'::date + 1 else :'d'::date end wd \gset
update fabula.settings set value = (:'d'::date + 10)::text where key = 'prod.tasks_from';
insert into fabula.parties (type, legal_name, is_milk_supplier) values ('supplier', 'Masseria Q', true) returning id sup \gset

-- ============================== the switch ==============================
select pg_temp.ck('setting prod.quiet_before_start exists as a Sì/No flag, on by default, in «Produzione e latte»',
  (select value = '1' and kind = 'flag' and data_type = 'number' from fabula.settings where key = 'prod.quiet_before_start'));
select pg_temp.ck('quiet_day: today and the day before the start are quiet; the start day is not',
  fabula.quiet_day(:'d'::date) and fabula.quiet_day(:'d'::date + 9) and not fabula.quiet_day(:'d'::date + 10));
update fabula.settings set value = '0' where key = 'prod.quiet_before_start';
select pg_temp.ck('quiet_day: «No» turns it off', not fabula.quiet_day(:'d'::date));
update fabula.settings set value = '1' where key = 'prod.quiet_before_start';
select pg_temp.ck('quiet_day: a null day is never quiet', not coalesce(fabula.quiet_day(null), false));
select pg_temp.ck('quiet_day can be run by logins; the digest helper cannot',
  has_function_privilege('authenticated', 'fabula.quiet_day(date)', 'execute')
  and not has_function_privilege('authenticated', 'fabula._digest_golive(date)', 'execute')
  and not has_function_privilege('anon', 'fabula.quiet_day(date)', 'execute'));

-- ============================== the milk plan ==============================
select count(*) plans0 from fabula.milk_plans \gset
select count(*) appr0 from fabula.approvals \gset
select fabula.plan_milk()::text pm1 \gset
select pg_temp.ck('automatic plan on a quiet day: skipped «pre_opening», with the start date and a message',
  (:'pm1'::jsonb ->> 'skipped') = 'pre_opening' and (:'pm1'::jsonb ->> 'tasks_start')::date = :'d'::date + 10
  and (:'pm1'::jsonb ->> 'date')::date = :'pd'::date
  and (:'pm1'::jsonb ->> 'message_it') like 'Nessun piano latte prima dell''avvio: le proposte ripartono per ' || fabula.it_day(:'d'::date + 10) || '%', :'pm1');
select pg_temp.ck('…and creates no plan and no approval (nothing to decide, nothing on Telegram, nothing on the farm page)',
  (select count(*) from fabula.milk_plans) = :plans0 and (select count(*) from fabula.approvals) = :appr0);
select fabula.plan_milk(:'d'::date + 3)::text pm2 \gset
select pg_temp.ck('a plan asked for a given day is still made (Console «Ordina di nuovo»)',
  (:'pm2'::jsonb ->> 'approval_id') is not null and not (:'pm2'::jsonb ? 'skipped'), :'pm2');
update fabula.settings set value = :'pd' where key = 'prod.tasks_from';
select fabula.plan_milk()::text pm3 \gset
select pg_temp.ck('the evening before the first day with the tasks, the automatic plan proposes again',
  (:'pm3'::jsonb ->> 'approval_id') is not null and (:'pm3'::jsonb ->> 'date')::date = :'pd'::date, :'pm3');
update fabula.settings set value = (:'d'::date + 10)::text where key = 'prod.tasks_from';
delete from fabula.milk_plans where id = (:'pm3'::jsonb ->> 'plan_id')::uuid;
delete from fabula.approvals where id = (:'pm3'::jsonb ->> 'approval_id')::uuid;

select fabula.bot_fallback_run('milk_planning', :'d'::date)::text fb \gset
select pg_temp.ck('the database''s stand-in (and «Esegui ora») says the same, as information',
  (:'fb'::jsonb ->> 'severity') = 'info' and (:'fb'::jsonb ->> 'title') = 'Nessun piano latte prima dell''avvio'
  and (:'fb'::jsonb ->> 'body') like 'Nessun piano latte prima dell''avvio: le proposte ripartono per %' and (:'fb'::jsonb ->> 'summary') = 'prima dell''avvio: nessun piano', :'fb');
select fabula._why_explain('plan_milk', :'pm1'::jsonb, null)::text why \gset
select pg_temp.ck('«Perché?» of that message: no plan, the day and the first day with the tasks',
  (:'why'::jsonb ->> 'title') = 'Nessun piano latte prima dell''avvio' and :'why' like '%Primo giorno con le attività%' and :'why' like '%Silenzio prima dell''avvio%', :'why');
select fabula._why_explain('plan_milk', '{"date":"2026-11-02","skipped":"plan_exists","plan":{"milk_kg":900,"status":"proposed","planned_output_kg":270}}'::jsonb, null)::text why2 \gset
select pg_temp.ck('«Perché?» of an existing plan is unchanged', (:'why2'::jsonb ->> 'title') like 'Piano latte per % già pronto', :'why2');

-- ============================== the evening check ==============================
select fabula.ops_health_check(:'wd'::date)::text oh1 \gset
select pg_temp.ck('evening check on a quiet working day: no «tablet silenzioso», no «conta di magazzino»',
  not exists (select 1 from jsonb_array_elements(:'oh1'::jsonb -> 'data_quality') x where x->>'key' in ('tablet_silent', 'stock_count_never', 'stock_count_overdue')), :'oh1');
update fabula.settings set value = '0' where key = 'prod.quiet_before_start';
select fabula.ops_health_check(:'wd'::date)::text oh2 \gset
select pg_temp.ck('…with «Silenzio prima dell''avvio» off both come back (as at work)',
  exists (select 1 from jsonb_array_elements(:'oh2'::jsonb -> 'data_quality') x where x->>'key' = 'tablet_silent')
  and exists (select 1 from jsonb_array_elements(:'oh2'::jsonb -> 'data_quality') x where x->>'key' = 'stock_count_never'), :'oh2');
update fabula.settings set value = '1' where key = 'prod.quiet_before_start';

-- ============================== the briefs ==============================
select fabula.daily_brief(:'y'::date)::text db1 \gset
select pg_temp.ck('morning brief on a quiet day: no HACCP checks and no overdue tasks asked, pre_opening with the start',
  jsonb_array_length(:'db1'::jsonb #> '{haccp,missing_daily_checks}') = 0 and jsonb_array_length(:'db1'::jsonb #> '{haccp,evening_cold_checks_missing}') = 0
  and jsonb_array_length(:'db1'::jsonb #> '{tasks,overdue}') = 0 and (:'db1'::jsonb #>> '{pre_opening,tasks_start}')::date = :'d'::date + 10
  and (:'db1'::jsonb ? 'changes'), left(:'db1', 300));
update fabula.settings set value = '0' where key = 'prod.quiet_before_start';
select fabula.daily_brief(:'y'::date)::text db2 \gset
select pg_temp.ck('…with the switch off, the missing HACCP checks are asked again (and no pre_opening)',
  jsonb_array_length(:'db2'::jsonb #> '{haccp,missing_daily_checks}') > 0 and not (:'db2'::jsonb ? 'pre_opening'));
update fabula.settings set value = '1' where key = 'prod.quiet_before_start';
insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source)
values (:'y'::date, '07:00', :'sup', 'MQ107-Y', 300, true, 4, 'tablet');
select fabula.daily_brief(:'y'::date)::text db3 \gset
select pg_temp.ck('food safety first: real milk on a quiet day brings the HACCP checks back',
  jsonb_array_length(:'db3'::jsonb #> '{haccp,missing_daily_checks}') > 0 and not (:'db3'::jsonb ? 'pre_opening'));
delete from fabula.milk_intake where milk_lot = 'MQ107-Y';

select fabula.weekly_brief()::text wb1 \gset
select pg_temp.ck('weekly brief of a quiet week: missing HACCP checks 0 in both weeks, pre_opening, changes still computed',
  (:'wb1'::jsonb #>> '{this_week,compliance,missing_checks}')::int = 0 and (:'wb1'::jsonb #>> '{previous_week,compliance,missing_checks}')::int = 0
  and (:'wb1'::jsonb ? 'pre_opening') and (:'wb1'::jsonb ? 'changes'), left(:'wb1', 300));
update fabula.settings set value = '0' where key = 'prod.quiet_before_start';
select fabula.weekly_brief()::text wb2 \gset
select pg_temp.ck('…with the switch off, the week''s missing checks are counted again',
  (:'wb2'::jsonb #>> '{this_week,compliance,missing_checks}')::int > 0 and not (:'wb2'::jsonb ? 'pre_opening'));
update fabula.settings set value = '1' where key = 'prod.quiet_before_start';

-- ============================== an expiry is not a decision ==============================
update fabula.approvals set expires_at = now() - interval '1 minute' where id = (:'pm2'::jsonb ->> 'approval_id')::uuid;
select fabula.expire_approvals() nexp \gset
select pg_temp.ck('an expired milk plan still reaches Telegram once…',
  :nexp >= 1 and exists (select 1 from fabula.notify_outbox where dedupe_key = 'exp:' || (:'pm2'::jsonb ->> 'approval_id') and topic = 'decisions'));
select pg_temp.ck('…without the «Nessuno se ne occupa» reminder 30 minutes later',
  (select escalate_at from fabula.notify_outbox where dedupe_key = 'exp:' || (:'pm2'::jsonb ->> 'approval_id')) is null);
select fabula.notify_enqueue('decisions', 'Decisione di prova Q', 'x', 'Prova') dq \gset
select pg_temp.ck('a decision still waiting keeps its 30-minute reminder', (select escalate_at from fabula.notify_outbox where id = :'dq') is not null);
delete from fabula.notify_outbox where id = :'dq';

-- ============================== «Verso l'apertura» on Monday ==============================
select fabula.notify_digest_text(:'tit_staff', now() - interval '1 day', ((:'mon'::date + time '07:30') at time zone 'Europe/Rome')) dg1 \gset
select pg_temp.ck('Monday''s summary while quiet: «Verso l''apertura» with done / total, from when it starts and the next items',
  :'dg1' like '%<b>Verso l''apertura</b> % di % fatti · si parte ' || fabula.it_day(:'d'::date + 10) || ' (tra %% giorni)%' and :'dg1' like '%' || E'\n' || '• %', :'dg1');
select pg_temp.ck('…the block comes before the Console link',
  position('Verso l''apertura' in :'dg1') > 0 and (position('Apri la Console' in :'dg1') = 0 or position('Verso l''apertura' in :'dg1') < position('Apri la Console' in :'dg1')));
select fabula.notify_digest_text(:'tit_staff', now() - interval '1 day', ((:'mon'::date + 1 + time '07:30') at time zone 'Europe/Rome')) dg2 \gset
select pg_temp.ck('Tuesday''s summary: no block', :'dg2' not like '%Verso l''apertura%', :'dg2');
update fabula.settings set value = (:'d'::date - 1)::text where key = 'prod.tasks_from';
select fabula.notify_digest_text(:'tit_staff', now() - interval '1 day', ((:'mon'::date + time '07:30') at time zone 'Europe/Rome')) dg3 \gset
select pg_temp.ck('after the start: no block on Monday either', :'dg3' not like '%Verso l''apertura%', :'dg3');
update fabula.settings set value = (:'d'::date + 10)::text where key = 'prod.tasks_from';
insert into fabula.staff (id, full_name, role, app_role, active) values ('10000000-0000-4000-a000-000000107a02', 'Casaro Q', 'casaro', 'produzione', true) on conflict do nothing;
select fabula.notify_digest_text('10000000-0000-4000-a000-000000107a02', now() - interval '1 day', ((:'mon'::date + time '07:30') at time zone 'Europe/Rome')) dg4 \gset
select pg_temp.ck('a profile that does not see Sistema gets no block', :'dg4' not like '%Verso l''apertura%', :'dg4');

-- ============================== Shopify stock: selling at zero is the decision ==============================
\set inv '{"ok":true,"push":0,"setting":2,"counted":false,"available_kg":0,"variants":[{"variant_id":"q1","label":"Q-Mozzarella · 250 g","available_units":0,"shopify_qty":0,"tracked":true,"policy":"DENY","split_basis":"parti_uguali","set":false},{"variant_id":"q2","label":"Q-Mozzarella · 500 g","available_units":0,"shopify_qty":0,"tracked":true,"policy":"CONTINUE","split_basis":"parti_uguali","set":false},{"variant_id":"q3","label":"Q-Treccia · 1 kg","available_units":0,"shopify_qty":0,"tracked":false,"policy":"DENY","split_basis":"parti_uguali","set":false}],"untracked":["Q-Treccia · 1 kg"],"selling_at_zero":["Q-Mozzarella · 500 g"],"not_found":[],"errors":[]}'
update fabula.agent_runs set status = 'ok', finished_at = coalesce(finished_at, now()) where agent = 'shopify_inventory' and status = 'running';
select fabula.shopify_sync_start('shopify_inventory') r1 \gset
select fabula.shopify_sync_finish(:'r1', :'inv') f1 \gset
select body sb1 from fabula.bot_messages where run_id = :'r1' \gset
select pg_temp.ck('stock check: no request to turn off «Continua a vendere quando esaurito» (selling at zero is the decision)',
  :'sb1' not like '%togli «Continua a vendere quando esaurito»%', :'sb1');
select pg_temp.ck('…it names the tracked product that stops at zero instead (not the untracked one)',
  :'sb1' like '%1 prodotto si ferma a scorte zero: in Shopify attiva «Continua a vendere quando esaurito» (Q-Mozzarella · 250 g)%'
  and :'sb1' not like '%attiva «Continua a vendere quando esaurito» (%Q-Treccia%', :'sb1');
update fabula.settings set value = '0' where key = 'shopify.sell_at_zero';
update fabula.agent_runs set status = 'ok', finished_at = coalesce(finished_at, now()) where agent = 'shopify_inventory' and status = 'running';
select fabula.shopify_sync_start('shopify_inventory') r2 \gset
select fabula.shopify_sync_finish(:'r2', :'inv') f2 \gset
select body sb2 from fabula.bot_messages where run_id = :'r2' \gset
select pg_temp.ck('with «No» it asks to turn it off, as before',
  :'sb2' like '%1 prodotto si vende anche a scorte zero: in Shopify togli «Continua a vendere quando esaurito» (Q-Mozzarella · 500 g)%', :'sb2');
update fabula.settings set value = '1' where key = 'shopify.sell_at_zero';
select pg_temp.ck('setting shopify.sell_at_zero exists as a Sì/No flag, on (the 02/10 decision)',
  (select value = '1' and kind = 'flag' from fabula.settings where key = 'shopify.sell_at_zero'));

-- ============================== the prompt ==============================
select pg_temp.ck('the milk planning prompt''s new version is expected', (select version from fabula.bot_prompt_versions where agent = 'milk_planning') = '7ab9d0a933');
