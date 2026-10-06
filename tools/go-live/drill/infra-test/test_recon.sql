-- v0.82 incassi: Shopify payments + bank statement matched against orders · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh rc_test
--   su postgres -c "psql -d rc_test -f tools/go-live/drill/infra-test/test_recon.sql" | grep -E "PASS|FAIL"
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
create or replace function pg_temp.d(n int) returns date language sql as $$ select (now() at time zone 'Europe/Rome')::date - 30 + n $$;

-- people: the owner (finanza 3), a production login (finanza 0), the consultant (finanza 1)
insert into auth.users (id, email) values ('00000000-0000-4000-a000-0000000000a1', 'owner@x.it'), ('00000000-0000-4000-a000-0000000000a2', 'casaro@x.it'), ('00000000-0000-4000-a000-0000000000a3', 'cons@x.it');
insert into fabula.staff (id, full_name, auth_user_id, app_role, role, active) values
  ('10000000-0000-4000-a000-0000000000a1', 'Owner Test', '00000000-0000-4000-a000-0000000000a1', 'titolare', 'owner', true),
  ('10000000-0000-4000-a000-0000000000a2', 'Casaro Test', '00000000-0000-4000-a000-0000000000a2', 'produzione', 'casaro', true),
  ('10000000-0000-4000-a000-0000000000a3', 'Consulente Test', '00000000-0000-4000-a000-0000000000a3', 'consulente', 'consulente', true);

-- customers, orders, one sales invoice
insert into fabula.parties (id, type, legal_name, trade_name, active, source) values
  ('20000000-0000-4000-a000-000000000001', 'customer', 'Gino Ristorazione Srl', 'Pizzeria Da Gino', true, 'test'),
  ('20000000-0000-4000-a000-000000000002', 'customer', 'Hotel Mare Srl', 'Hotel Mare', true, 'test');
insert into fabula.sales_orders (id, order_number, channel, order_date, status, subtotal_eur, iva_eur, total_eur, payment_method, shopify_order_id, source, shopify_payload, customer_id) values
  ('30000000-0000-4000-a000-000000001001', '#1001', 'shopify', pg_temp.d(1), 'fulfilled', 28.85, 1.15, 30.00, 'shopify', 'gid://shopify/Order/5001', 'shopify', '{"payment_gateways":["shopify_payments"]}', null),
  ('30000000-0000-4000-a000-000000001002', '#1002', 'shopify', pg_temp.d(1), 'fulfilled', 19.23, 0.77, 20.00, 'shopify', 'gid://shopify/Order/5002', 'shopify', '{"payment_gateways":["shopify_payments"]}', null),
  ('30000000-0000-4000-a000-000000001003', '#1003', 'store_pos', pg_temp.d(2), 'fulfilled', 11.54, 0.46, 12.00, 'shopify_pos', 'gid://shopify/Order/5003', 'shopify', '{"payment_gateways":["cash"]}', null),
  ('30000000-0000-4000-a000-000000001004', '#1004', 'store_pos', pg_temp.d(2), 'fulfilled', 15.38, 0.62, 16.00, 'shopify_pos', 'gid://shopify/Order/5004', 'shopify', '{"payment_gateways":["shopify_payments"]}', null),
  ('30000000-0000-4000-a000-000000001005', '#1005', 'shopify', pg_temp.d(3), 'confirmed', 38.46, 1.54, 40.00, 'shopify', 'gid://shopify/Order/5005', 'shopify', '{"payment_gateways":["shopify_payments"]}', null),
  ('30000000-0000-4000-a000-000000002001', 'WS-260901-01', 'wholesale', pg_temp.d(1), 'fulfilled', 115.38, 4.62, 120.00, 'bonifico', null, 'test', null, '20000000-0000-4000-a000-000000000001');
insert into fabula.invoices (id, direction, party_id, invoice_number, invoice_date, taxable_eur, iva_eur, total_eur, status, source) values
  ('40000000-0000-4000-a000-000000000007', 'out', '20000000-0000-4000-a000-000000000002', 'FT-7', pg_temp.d(0), 234.62, 9.38, 244.00, 'approved', 'test');

-- 1. Shopify payments file, as the owner
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-0000000000a1","role":"authenticated"}', false);
select fabula.payments_import('shopify_payments', jsonb_build_array(
  jsonb_build_object('date', pg_temp.d(1) || ' 10:00:00 +0200', 'type', 'charge', 'order', '#1001', 'payout_id', 'P1', 'payout_date', pg_temp.d(3), 'payout_status', 'in_transit', 'amount', 30.00, 'fee', 0.75, 'net', 29.25),
  jsonb_build_object('date', pg_temp.d(1) || ' 11:00:00 +0200', 'type', 'charge', 'order', '#1002', 'payout_id', 'P1', 'payout_date', pg_temp.d(3), 'payout_status', 'in_transit', 'amount', 20.00, 'fee', 0.55, 'net', 19.45),
  jsonb_build_object('date', pg_temp.d(2) || ' 12:00:00 +0200', 'type', 'charge', 'order', '#1004', 'payout_id', 'P2', 'payout_date', pg_temp.d(5), 'payout_status', 'paid', 'amount', 15.00, 'fee', 0.40, 'net', 14.60),
  jsonb_build_object('date', pg_temp.d(4) || ' 09:00:00 +0200', 'type', 'refund', 'order', '#1001', 'payout_id', 'P2', 'payout_date', pg_temp.d(5), 'payout_status', 'paid', 'amount', -5.00, 'fee', 0, 'net', -5.00),
  jsonb_build_object('date', pg_temp.d(4) || ' 10:00:00 +0200', 'type', 'charge', 'order', '#9999', 'payout_id', 'P2', 'payout_date', pg_temp.d(5), 'payout_status', 'paid', 'amount', 10.00, 'fee', 0.30, 'net', 9.70),
  jsonb_build_object('date', pg_temp.d(5) || ' 08:00:00 +0200', 'type', 'payout', 'amount', -48.70, 'net', -48.70),
  jsonb_build_object('date', pg_temp.d(6) || ' 10:00:00 +0200', 'type', 'charge', 'order', '#1002', 'amount', 1.00, 'fee', 0.10, 'net', 0.90, 'test', true)
)) r1 \gset
select pg_temp.ck('payments file: 6 rows kept, the payout line skipped, 2 payouts built',
  (:'r1'::jsonb->>'inserted')::int = 6 and (:'r1'::jsonb->>'skipped')::int = 1 and (:'r1'::jsonb->>'payouts')::int = 2, :'r1');
select pg_temp.ck('payout totals rebuilt from their rows (P1 48.70, P2 19.30 with refund and fees)',
  (select net_eur from fabula.payment_payouts where id = 'P1') = 48.70 and (select net_eur || '|' || fee_eur || '|' || gross_eur from fabula.payment_payouts where id = 'P2') = '19.30|0.70|20.00');
-- same file again with P1 now paid: nothing duplicated, status follows
select fabula.payments_import('shopify_payments', jsonb_build_array(
  jsonb_build_object('date', pg_temp.d(1) || ' 10:00:00 +0200', 'type', 'charge', 'order', '#1001', 'payout_id', 'P1', 'payout_date', pg_temp.d(3), 'payout_status', 'paid', 'amount', 30.00, 'fee', 0.75, 'net', 29.25),
  jsonb_build_object('date', pg_temp.d(1) || ' 11:00:00 +0200', 'type', 'charge', 'order', '#1002', 'payout_id', 'P1', 'payout_date', pg_temp.d(3), 'payout_status', 'paid', 'amount', 20.00, 'fee', 0.55, 'net', 19.45)
)) r2 \gset
select pg_temp.ck('re-import: 0 new rows, payout status moves to paid',
  (:'r2'::jsonb->>'inserted')::int = 0 and (:'r2'::jsonb->>'updated')::int = 2 and (select status from fabula.payment_payouts where id = 'P1') = 'paid'
  and (select count(*) from fabula.payment_transactions) = 6, :'r2');
select fabula.payouts_import('shopify_payments', jsonb_build_array(jsonb_build_object('id', 'P3', 'date', pg_temp.d(8), 'status', 'paid', 'net', 50.00))) r3 \gset
select pg_temp.ck('payout-level row accepted', (select net_eur from fabula.payment_payouts where id = 'P3') = 50.00, :'r3');

-- 2. bank statement
select fabula.bank_import('BCC Test 1234', jsonb_build_array(
  jsonb_build_object('date', pg_temp.d(4), 'value_date', pg_temp.d(4), 'amount', 48.70, 'description', 'BONIFICO A VOSTRO FAVORE SHOPIFY INTERNATIONAL LTD'),
  jsonb_build_object('date', pg_temp.d(5), 'amount', 120.00, 'description', 'BONIFICO DA PIZZERIA DA GINO SALDO FORNITURA'),
  jsonb_build_object('date', pg_temp.d(6), 'amount', 244.00, 'description', 'BONIFICO HOTEL MARE SRL SALDO FT 7'),
  jsonb_build_object('date', pg_temp.d(6), 'amount', 500.00, 'description', 'VERSAMENTO CONTANTI SPORTELLO'),
  jsonb_build_object('date', pg_temp.d(6), 'amount', -2.50, 'description', 'COMMISSIONI BONIFICO'),
  jsonb_build_object('date', pg_temp.d(6), 'amount', -2.50, 'description', 'COMMISSIONI BONIFICO'),
  jsonb_build_object('date', pg_temp.d(7), 'amount', -300.00, 'description', 'SDD ENEL ENERGIA'),
  jsonb_build_object('date', pg_temp.d(7), 'amount', 77.77, 'description', 'BONIFICO DA MARIO ROSSI'),
  jsonb_build_object('date', pg_temp.d(9), 'amount', 50.00, 'description', 'BONIFICO DA ROSSI'),
  jsonb_build_object('date', pg_temp.d(9), 'amount', 50.00, 'description', 'BONIFICO DA BIANCHI'),
  jsonb_build_object('date', pg_temp.d(25), 'amount', -1.00, 'description', 'IMPOSTA DI BOLLO', 'balance', 1234.56)
)) b1 \gset
select pg_temp.ck('bank file: 11 rows in, two identical fee rows both kept', (:'b1'::jsonb->>'inserted')::int = 11 and (select count(*) from fabula.bank_transactions where description = 'COMMISSIONI BONIFICO') = 2, :'b1');
select fabula.bank_import('BCC Test 1234', jsonb_build_array(
  jsonb_build_object('date', pg_temp.d(6), 'amount', -2.50, 'description', 'COMMISSIONI BONIFICO'),
  jsonb_build_object('date', pg_temp.d(6), 'amount', -2.50, 'description', 'COMMISSIONI BONIFICO'),
  jsonb_build_object('date', pg_temp.d(26), 'amount', 10.00, 'description', 'NUOVO')
)) b2 \gset
select pg_temp.ck('overlapping export: only the new row goes in', (:'b2'::jsonb->>'inserted')::int = 1 and (:'b2'::jsonb->>'skipped')::int = 2, :'b2');
do $$ begin perform fabula.bank_import('BCC Test 1234', '[{"date":"2026-13-40","amount":"x"}]'); raise notice 'R1 accepted'; exception when others then raise notice 'R1 refused: %', sqlerrm; end $$;

-- 3. matching
select fabula.recon_run() m1 \gset
select pg_temp.ck('orders linked from the payments file (#1001 ×2, #1002, #1004)', (select count(*) from fabula.payment_transactions where sales_order_id is not null) = 4, :'m1');
select pg_temp.ck('P1 matched to the Shopify credit of the same amount',
  (select b.description from fabula.payment_payouts p join fabula.bank_transactions b on b.id = p.bank_tx_id where p.id = 'P1') like '%SHOPIFY%'
  and (select match_kind || '|' || matched_payout_id from fabula.bank_transactions where amount_eur = 48.70) = 'payout|P1');
select pg_temp.ck('P3: two equal credits, neither named Shopify → left for a person', (select bank_tx_id from fabula.payment_payouts where id = 'P3') is null and (:'m1'::jsonb->>'ambiguous')::int = 1);
select pg_temp.ck('sales invoice paid by number in the text', (select status || '|' || paid_at from fabula.invoices where invoice_number = 'FT-7') = 'paid|' || pg_temp.d(6)
  and (select match_kind from fabula.bank_transactions where amount_eur = 244) = 'invoice');
select pg_temp.ck('wholesale order matched by the customer named in the text', (select match_kind || '|' || matched_order_id from fabula.bank_transactions where amount_eur = 120) = 'order|30000000-0000-4000-a000-000000002001');
select pg_temp.ck('rules: cash deposit tagged (still open for the cash check), fees and stamp duty closed',
  (select match_kind || '|' || reconciled from fabula.bank_transactions where amount_eur = 500) = 'cash_deposit|false'
  and (select count(*) from fabula.bank_transactions where match_kind = 'bank_fee' and reconciled) = 3);

-- 4. what a person sees
create temp table ex as select * from fabula.v_recon_exceptions;
select pg_temp.ck('paid card order missing from the payments file is flagged (#1005), cash order #1003 is not',
  exists (select 1 from ex where kind = 'order_no_payment' and ref = '30000000-0000-4000-a000-000000001005')
  and not exists (select 1 from ex where ref = '30000000-0000-4000-a000-000000001003'), (select string_agg(kind || ':' || label_it, ' / ') from ex));
select pg_temp.ck('charged 15.00 on a 16.00 order is flagged', exists (select 1 from ex where kind = 'charge_mismatch' and ref = '30000000-0000-4000-a000-000000001004' and amount_eur = 1.00));
select pg_temp.ck('#1001 charged 30 then refunded 5 is not a mismatch', not exists (select 1 from ex where kind = 'charge_mismatch' and ref = '30000000-0000-4000-a000-000000001001'));
select pg_temp.ck('charge for an order not in the system flagged (#9999)', exists (select 1 from ex where kind = 'tx_no_order' and label_it like '%#9999%'));
select pg_temp.ck('P2 not in the bank flagged as alert (statement runs 20 days past it)', exists (select 1 from ex where kind = 'payout_not_in_bank' and ref = 'P2' and severity = 'alert'));
select pg_temp.ck('unknown credits flagged, unclassified debit listed as info only',
  (select count(*) from ex where kind = 'bank_credit') = 4 and exists (select 1 from ex where kind = 'bank_debit' and severity = 'info' and label_it like '%ENEL%'));
select pg_temp.ck('test-mode rows kept but never linked, matched or counted', (select count(*) from fabula.payment_transactions where test) = 1
  and (select sales_order_id from fabula.payment_transactions where test) is null and not exists (select 1 from ex where ref = (select id from fabula.payment_transactions where test)));
select pg_temp.ck('console notice raised without amounts',
  (select title_it from fabula.notices where key = 'recon' and resolved_at is null) ~ '^Incassi: \d+ da controllare' and (select title_it from fabula.notices where key = 'recon') !~ '€');

-- 5. by hand
select id as rossi from fabula.bank_transactions where description = 'BONIFICO DA ROSSI' \gset
select fabula.recon_candidates(:'rossi') c1 \gset
select pg_temp.ck('candidates for a 50.00 credit include payout P3', (:'c1'::jsonb->'payouts'->0->>'id') = 'P3', :'c1');
select fabula.recon_set_bank(:'rossi', 'payout', 'P3', 'Shopify con descrizione strana') s1 \gset
select pg_temp.ck('manual match: P3 ↔ the Rossi credit, the other 50.00 still open',
  (select bank_tx_id from fabula.payment_payouts where id = 'P3') = :'rossi'::uuid and exists (select 1 from fabula.v_recon_exceptions where kind = 'bank_credit' and label_it like '%BIANCHI%'));
do $$ begin perform fabula.recon_set_bank((select id from fabula.bank_transactions where description = 'BONIFICO DA BIANCHI'), 'payout', 'P3'); raise notice 'R2 accepted'; exception when others then raise notice 'R2 refused: %', sqlerrm; end $$;
do $$ begin perform fabula.recon_set_bank((select id from fabula.bank_transactions where description = 'BONIFICO DA BIANCHI'), 'ignore'); raise notice 'R3 accepted'; exception when others then raise notice 'R3 refused: %', sqlerrm; end $$;
select id as inv_tx from fabula.bank_transactions where amount_eur = 244 \gset
select fabula.recon_set_bank(:'inv_tx', 'clear') s2 \gset
select pg_temp.ck('clear: the invoice goes back to open and the credit to unmatched',
  (select status::text || '|' || coalesce(paid_at::text, '-') from fabula.invoices where invoice_number = 'FT-7') = 'approved|-' and (select match_kind from fabula.bank_transactions where id = :'inv_tx') is null);
select fabula.recon_run() m2 \gset
select pg_temp.ck('next run matches it again; P3 manual match kept', (select status from fabula.invoices where invoice_number = 'FT-7') = 'paid' and (select bank_tx_id from fabula.payment_payouts where id = 'P3') = :'rossi'::uuid, :'m2');
do $$ begin perform fabula.recon_ack('bank_credit:' || (select id from fabula.bank_transactions where description = 'BONIFICO DA MARIO ROSSI'), ''); raise notice 'R4 accepted'; exception when others then raise notice 'R4 refused: %', sqlerrm; end $$;
select fabula.recon_ack('bank_credit:' || (select id from fabula.bank_transactions where description = 'BONIFICO DA MARIO ROSSI'), 'Rimborso cauzione') a1 \gset
select pg_temp.ck('ack with a note hides the item', not exists (select 1 from fabula.v_recon_exceptions where label_it like '%MARIO ROSSI%'));
select fabula.recon_ack('bank_credit:' || (select id from fabula.bank_transactions where description = 'BONIFICO DA MARIO ROSSI'), null, false) a2 \gset
select pg_temp.ck('ack can be undone', exists (select 1 from fabula.v_recon_exceptions where label_it like '%MARIO ROSSI%'));

-- 6. status numbers
select fabula.recon_status(pg_temp.d(0), pg_temp.d(30)) st \gset
select pg_temp.ck('status: charges 75.00 · refunds −5.00 · fees 2.00 · P1 + P3 in bank, P2 waiting',
  (:'st'::jsonb#>>'{payments,charges_eur}')::numeric = 75.00 and (:'st'::jsonb#>>'{payments,refunds_eur}')::numeric = -5.00
  and (:'st'::jsonb#>>'{payments,fees_eur}')::numeric = 2.00 and (:'st'::jsonb#>>'{payouts,in_bank_n}')::int = 2 and (:'st'::jsonb#>>'{payouts,waiting_n}')::int = 1
  and (:'st'::jsonb#>>'{cash,pos_cash_eur}')::numeric = 12.00 and (:'st'::jsonb#>>'{cash,deposited_eur}')::numeric = 500.00
  and (:'st'::jsonb#>'{bank,accounts}'->0->>'balance')::numeric = 1234.56, left(:'st', 600));

-- 7. who may do what (RLS + function checks)
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-0000000000a2","role":"authenticated"}', false);
set role authenticated;
do $$ begin perform fabula.bank_import('X', '[{"date":"2026-10-01","amount":1}]'); raise notice 'R5 accepted'; exception when others then raise notice 'R5 refused: %', sqlerrm; end $$;
select pg_temp.ck('production login sees no bank rows or payouts', (select count(*) from fabula.bank_transactions) = 0 and (select count(*) from fabula.payment_payouts) = 0);
reset role;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-0000000000a3","role":"authenticated"}', false);
set role authenticated;
select pg_temp.ck('consultant (finanza: vede) reads the bank rows', (select count(*) from fabula.bank_transactions) = 12);
do $$ begin perform fabula.recon_run(); raise notice 'R6 accepted'; exception when others then raise notice 'R6 refused: %', sqlerrm; end $$;
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('anon cannot call the import', not has_function_privilege('anon', 'fabula.bank_import(text, jsonb)', 'execute'));
select pg_temp.ck('views run with the caller''s rights', (select reloptions::text from pg_class where oid = 'fabula.v_recon_exceptions'::regclass) like '%security_invoker=true%');
select pg_temp.ck('nightly job scheduled', exists (select 1 from cron.job where jobname = 'fabula_recon' and command like '%recon_run%'));
