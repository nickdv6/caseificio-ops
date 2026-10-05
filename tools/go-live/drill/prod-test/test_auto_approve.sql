-- v0.73 auto-approval rules + rota autocopy · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh aa_test
--   su postgres -c "psql -d aa_test -f tools/go-live/drill/prod-test/test_auto_approve.sql" | grep -E "PASS|FAIL"
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
select (now() at time zone 'Europe/Rome')::date d \gset

-- milk plans: normal, capacity hit, 30 % off, no history
insert into fabula.milk_plans (plan_date, milk_kg, planned_output_kg, details) values
 (:'d'::date + 10, 800, 240, '{"history_source":"same_weekday_4w","history_days":4,"last_4w_same_weekday_milk_kg":760,"capacity_hit":false,"min_run_applied":false,"exceeds_farm_supply":false,"is_simulation":false}'),
 (:'d'::date + 11, 1200, 360, '{"history_source":"same_weekday_4w","history_days":4,"last_4w_same_weekday_milk_kg":1150,"capacity_hit":true}'),
 (:'d'::date + 12, 1000, 300, '{"history_source":"same_weekday_4w","history_days":4,"last_4w_same_weekday_milk_kg":760}'),
 (:'d'::date + 13, 1200, 360, '{"history_source":"none","history_days":0}');
insert into fabula.approvals (kind, requested_by, summary, payload, related_table, related_id, amount_eur, expires_at)
select 'other', 'agent:milk_planning', 'Latte T' || (plan_date - :'d'::date), jsonb_build_object('type', 'milk_plan', 'plan_date', plan_date, 'milk_kg', milk_kg), 'milk_plans', id, 100, now() + interval '1 day'
from fabula.milk_plans where plan_date between :'d'::date + 10 and :'d'::date + 13;
select pg_temp.ck('milk plan within ±15 % of the last 4 same weekdays gets a timer (~60 min) and the reason',
  (select auto_approve_at between now() + interval '59 minutes' and now() + interval '61 minutes' and auto_rule like 'piano latte nella norma: 800 kg contro 760 kg%' from fabula.approvals where summary = 'Latte T10'),
  (select auto_rule from fabula.approvals where summary = 'Latte T10'));
select pg_temp.ck('capacity hit, 30 % off and no sales history wait for a person',
  (select count(*) from fabula.approvals where summary in ('Latte T11', 'Latte T12', 'Latte T13') and auto_approve_at is null) = 3);

-- purchase orders
insert into fabula.parties (type, legal_name) values ('supplier', 'Sale Cilento Srl') returning id sup \gset
select id ph_sup from fabula.parties where legal_name like 'Fornitore 2%' \gset
select id salt from fabula.products where sku = 'CON-SALT' \gset
insert into fabula.purchase_orders (po_number, supplier_id, status, order_date) values ('PO-OLD', :'sup', 'received', :'d'::date - 20) returning id po_old \gset
insert into fabula.purchase_order_lines (purchase_order_id, product_id, qty_ordered, unit_price_eur, iva_rate) values (:'po_old', :'salt', 100, 0.50, 22);
insert into fabula.purchase_orders (po_number, supplier_id, status, order_date) values
 ('PO-OK', :'sup', 'pending_approval', :'d'), ('PO-BIG', :'sup', 'pending_approval', :'d'), ('PO-JUMP', :'sup', 'pending_approval', :'d'), ('PO-PH', :'ph_sup', 'pending_approval', :'d');
insert into fabula.approvals (kind, requested_by, summary, payload, related_table, related_id, amount_eur, expires_at)
select 'purchase_order', 'agent:procurement', po.po_number, jsonb_build_object('sku', 'CON-SALT', 'unit_price_eur', x.price), 'purchase_orders', po.id, x.amount, now() + interval '7 days'
from fabula.purchase_orders po join (values ('PO-OK', 0.52, 52), ('PO-BIG', 0.50, 400), ('PO-JUMP', 0.60, 60), ('PO-PH', 0.50, 50)) x(num, price, amount) on x.num = po.po_number;
select pg_temp.ck('routine purchase order (€ 52, known supplier, price +4 %) gets a timer',
  (select auto_approve_at is not null and auto_rule like 'ordine di routine: € 52.00%' from fabula.approvals where summary = 'PO-OK'), (select auto_rule from fabula.approvals where summary = 'PO-OK'));
select pg_temp.ck('over € 150, price +20 % and placeholder supplier wait for a person',
  (select count(*) from fabula.approvals where summary in ('PO-BIG', 'PO-JUMP', 'PO-PH') and auto_approve_at is null) = 3);

-- promos
insert into fabula.approvals (kind, requested_by, summary, payload, expires_at) values
 ('price_change', 'agent:sell_down', 'Promo T-OK', '{"type":"sell_down","action":"promo_banco","promo_pct":30,"at_risk_kg":12,"lot":"L1"}', now() + interval '8 hours'),
 ('price_change', 'agent:sell_down', 'Promo T-BIG', '{"type":"sell_down","action":"promo_banco","promo_pct":30,"at_risk_kg":25,"lot":"L2"}', now() + interval '8 hours'),
 ('price_change', 'agent:sell_down', 'Promo T-WS', '{"type":"sell_down","action":"offerta_ingrosso_e_promo","promo_pct":30,"at_risk_kg":15,"lot":"L3"}', now() + interval '8 hours'),
 ('price_change', 'agent:sell_down', 'Promo T-SOON', '{"type":"sell_down","action":"promo_banco","promo_pct":30,"at_risk_kg":5,"lot":"L4"}', now() + interval '30 minutes'),
 ('dop_declaration', 'agent:monthly_review', 'DOP T', '{}', now() + interval '10 days');
select pg_temp.ck('standard counter promo ≤ 20 kg gets a timer; 25 kg, wholesale offer and DOP declaration do not',
  (select auto_approve_at is not null from fabula.approvals where summary = 'Promo T-OK')
  and (select count(*) from fabula.approvals where summary in ('Promo T-BIG', 'Promo T-WS', 'DOP T') and auto_approve_at is null) = 3);
select pg_temp.ck('a promo expiring in 30 min approves 15 min before it expires, not after',
  (select auto_approve_at between expires_at - interval '16 minutes' and expires_at - interval '14 minutes' from fabula.approvals where summary = 'Promo T-SOON'));

-- a person decides first; a rule switched off before the time
update fabula.approvals set status = 'rejected', decided_by = 'Nick', decided_at = now() where summary = 'Promo T-SOON';
update fabula.settings set value = '0' where key = 'approve.auto_po_max_eur';
select fabula.auto_approve_due(now() + interval '61 minutes') r \gset
select pg_temp.ck('at its time: milk plan and promo approved by the rule, milk plan synced to approved',
  (select status::text || '|' || decided_by from fabula.approvals where summary = 'Latte T10') = 'approved|Approvazione automatica'
  and (select status from fabula.milk_plans where plan_date = :'d'::date + 10) = 'approved'
  and (select status::text from fabula.approvals where summary = 'Promo T-OK') = 'approved'
  and (select decision_note from fabula.approvals where summary = 'Latte T10') like 'Regola: piano latte nella norma%', :'r');
select pg_temp.ck('rejected by a person before: left rejected', (select status::text from fabula.approvals where summary = 'Promo T-SOON') = 'rejected');
select pg_temp.ck('rule switched off before the time: not approved, timer removed, a person decides',
  (select status::text = 'pending' and auto_approve_at is null and auto_rule like 'non più di routine%' from fabula.approvals where summary = 'PO-OK')
  and (select status::text from fabula.purchase_orders where po_number = 'PO-OK') = 'pending_approval');
select pg_temp.ck('one message per automatic approval from Zia Rosa',
  (select count(*) from fabula.bot_messages where agent = 'auto_approve' and title like 'Approvato da solo%') = 2
  and fabula.bot_display_name('auto_approve') = 'Zia Rosa · Approvazioni automatiche');
select pg_temp.ck('nothing pending is approved before its time', (fabula.auto_approve_due(now())->'results') = '[]'::jsonb);

-- rota
insert into fabula.staff (full_name, role, app_role, active) values ('Operaio Test', 'casaro', 'produzione', true) returning id st \gset
insert into fabula.rota_entries (staff_id, work_date, kind, start_time, end_time, break_min)
select :'st', date_trunc('week', :'d'::date)::date + g, case when g < 5 then 'lavoro' else 'riposo' end, case when g < 5 then '06:00'::time end, case when g < 5 then '14:00'::time end, 30
from generate_series(0, 6) g;
select fabula.rota_autocopy(:'d') rr \gset
select pg_temp.ck('Saturday: next week empty → this week copied (7 entries) and noted',
  (:'rr'::jsonb->>'copied')::int = 7 and (select count(*) from fabula.rota_entries where work_date >= date_trunc('week', :'d'::date)::date + 7) = 7
  and exists (select 1 from fabula.bot_messages where agent = 'auto_approve' and title like 'Turni della settimana%'), :'rr');
select pg_temp.ck('next week already has a rota → nothing copied', (fabula.rota_autocopy(:'d')->>'copied')::int = 0);
select pg_temp.ck('jobs scheduled; signed-in users cannot run the approver',
  exists (select 1 from cron.job where jobname = 'fabula_auto_approve' and schedule = '*/10 * * * *') and exists (select 1 from cron.job where jobname = 'fabula_rota_autocopy')
  and not has_function_privilege('authenticated', 'fabula.auto_approve_due(timestamptz)', 'execute'));
