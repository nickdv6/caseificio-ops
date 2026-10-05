\set ON_ERROR_STOP 0
-- fixtures (as postgres)
insert into auth.users(id, email) values ('00000000-0000-4000-a000-000000000001', 'casaro@test.it'), ('00000000-0000-4000-a000-000000000002', 'banco@test.it') on conflict do nothing;
insert into fabula.staff(id, full_name, auth_user_id, app_role, role, active) values
 ('10000000-0000-4000-a000-000000000001', 'Test Casaro', '00000000-0000-4000-a000-000000000001', 'produzione', 'casaro', true),
 ('10000000-0000-4000-a000-000000000002', 'Test Banco',  '00000000-0000-4000-a000-000000000002', 'banco', 'commesso', true) on conflict do nothing;
select id as sup from fabula.parties where is_milk_supplier limit 1 \gset
\echo supplier :sup
-- as the casaro
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-a000-000000000001', false), set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-000000000001","role":"authenticated"}', false);
select fabula.my_staff_id() as me;

\echo == T1 milk intake (5 steps incl. 2 RPCs), qid Q1
select jsonb_array_length(fabula.save_ops(jsonb_build_array(
  jsonb_build_object('table','scan_events','row',jsonb_build_object('id','20000000-0000-4000-a000-000000000001','code','DDT:TEST1','action','milk_receive','staff_id','10000000-0000-4000-a000-000000000001')),
  jsonb_build_object('table','milk_intake','row',jsonb_build_object('id','20000000-0000-4000-a000-000000000002','intake_date',current_date,'supplier_id',:'sup','milk_lot','TT1','qty_kg',500,'temperature_c',4,'accepted',true,'ddt_number','TEST1','received_by_id','10000000-0000-4000-a000-000000000001','source','tablet')),
  jsonb_build_object('table','labels','row',jsonb_build_object('id','20000000-0000-4000-a000-000000000003','kind','milk_lot','code','LOT:TT1','lot_number','TT1','milk_intake_id','$1.id','printed_by_id','10000000-0000-4000-a000-000000000001')),
  jsonb_build_object('rpc','log_ccp','args',jsonb_build_object('p_cp_code','CCP-MILK-TEMP','p_value',4,'p_staff_id','10000000-0000-4000-a000-000000000001','p_source','tablet','p_equipment_code','TERM-01')),
  jsonb_build_object('rpc','log_ccp','args',jsonb_build_object('p_cp_code','CCP-MILK-ABX','p_value',0,'p_staff_id','10000000-0000-4000-a000-000000000001','p_source','tablet'))
), '30000000-0000-4000-a000-000000000001')) as steps_done;
select (select count(*) from fabula.milk_intake where milk_lot='TT1') mi, (select count(*) from fabula.labels where code='LOT:TT1' and milk_intake_id='20000000-0000-4000-a000-000000000002') lab_linked,
       (select count(*) from fabula.haccp_log where logged_at > now() - interval '1 minute') ccp;

\echo == T2 same qid re-sent: nothing new
select jsonb_array_length(fabula.save_ops('[{"table":"scan_events","row":{"code":"X","action":"milk_receive"}}]'::jsonb, '30000000-0000-4000-a000-000000000001')) as returned_steps_from_ledger;
select (select count(*) from fabula.milk_intake where milk_lot='TT1') mi, (select count(*) from fabula.haccp_log where logged_at > now() - interval '1 minute') ccp, (select count(*) from fabula.scan_events where code='X') x_events;

\echo == T3 batch start, last step fails (bad move type) -> nothing written
select fabula.save_ops(jsonb_build_array(
  jsonb_build_object('table','scan_events','row',jsonb_build_object('code','LOT:TT1','action','batch_start','staff_id','10000000-0000-4000-a000-000000000001')),
  jsonb_build_object('table','production_batches','row',jsonb_build_object('id','20000000-0000-4000-a000-000000000010','batch_date',current_date,'batch_lot','LTEST-A','product_id','daaa337d-4ed4-48a6-9260-565f06df73c3','milk_in_kg',400,'casaro_id','10000000-0000-4000-a000-000000000001','source','tablet')),
  jsonb_build_object('table','batch_milk_inputs','row',jsonb_build_object('batch_id','$1.id','milk_intake_id','20000000-0000-4000-a000-000000000002','qty_kg',400)),
  jsonb_build_object('table','stock_moves','row',jsonb_build_object('product_id','df0a9035-b8d8-4b00-bad7-e626e2d95b22','lot_number','TT1','qty',-400,'move_type','NOT_A_TYPE','batch_id','$1.id','source','tablet'))
), '30000000-0000-4000-a000-000000000002');
select (select count(*) from fabula.production_batches where batch_lot='LTEST-A') batches, (select count(*) from fabula.scan_events where action='batch_start' and code='LOT:TT1') events;

\echo == T4 batch start ok
select jsonb_array_length(fabula.save_ops(jsonb_build_array(
  jsonb_build_object('table','scan_events','row',jsonb_build_object('code','LOT:TT1','action','batch_start','staff_id','10000000-0000-4000-a000-000000000001')),
  jsonb_build_object('table','production_batches','row',jsonb_build_object('id','20000000-0000-4000-a000-000000000010','batch_date',current_date,'batch_lot','LTEST-A','product_id','daaa337d-4ed4-48a6-9260-565f06df73c3','milk_in_kg',400,'casaro_id','10000000-0000-4000-a000-000000000001','source','tablet')),
  jsonb_build_object('table','batch_milk_inputs','row',jsonb_build_object('batch_id','$1.id','milk_intake_id','20000000-0000-4000-a000-000000000002','qty_kg',400)),
  jsonb_build_object('table','stock_moves','row',jsonb_build_object('product_id','df0a9035-b8d8-4b00-bad7-e626e2d95b22','lot_number','TT1','qty',-400,'move_type','production_in','batch_id','$1.id','source','tablet'))
), '30000000-0000-4000-a000-000000000003')) steps;
select (select count(*) from fabula.production_batches where batch_lot='LTEST-A') batches, (select count(*) from fabula.batch_milk_inputs where batch_id='20000000-0000-4000-a000-000000000010') inputs, (select count(*) from fabula.stock_moves where batch_id='20000000-0000-4000-a000-000000000010') moves;

\echo == T5 batch close (update by id + stock + label)
select jsonb_array_length(fabula.save_ops(jsonb_build_array(
  jsonb_build_object('table','scan_events','row',jsonb_build_object('code','LOT:TT1','action','batch_end','staff_id','10000000-0000-4000-a000-000000000001')),
  jsonb_build_object('table','production_batches','update',jsonb_build_object('id','20000000-0000-4000-a000-000000000010'),'row',jsonb_build_object('output_kg',80,'curd_ph',5.2,'finished_at',now())),
  jsonb_build_object('table','stock_moves','row',jsonb_build_object('product_id','daaa337d-4ed4-48a6-9260-565f06df73c3','lot_number','LTEST-A','expiry_date',current_date+5,'qty',80,'move_type','production_out','batch_id','20000000-0000-4000-a000-000000000010','source','tablet'))
), '30000000-0000-4000-a000-000000000004')) steps;
select batch_lot, output_kg, yield_pct, finished_at is not null closed from fabula.production_batches where batch_lot='LTEST-A';

\echo == T6 update matching nothing -> refused, nothing written
select fabula.save_ops(jsonb_build_array(
  jsonb_build_object('table','scan_events','row',jsonb_build_object('code','LOT:NONE','action','batch_end','staff_id','10000000-0000-4000-a000-000000000001')),
  jsonb_build_object('table','production_batches','update',jsonb_build_object('id','29999999-0000-4000-a000-000000000010'),'row',jsonb_build_object('output_kg',1))), null);
select count(*) as none_events from fabula.scan_events where code='LOT:NONE';

\echo == T7 not-allowed table / rpc
select fabula.save_ops('[{"table":"staff","row":{"full_name":"x"}}]', null);
select fabula.save_ops('[{"rpc":"backup_fetch_call","args":{}}]', null);

\echo == T8 as the banco user: production insert refused by role policy, nothing written
reset role; set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-a000-000000000002', false), set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-000000000002","role":"authenticated"}', false);
select fabula.save_ops(jsonb_build_array(
  jsonb_build_object('table','scan_events','row',jsonb_build_object('code','LOT:BANCO','action','batch_start','staff_id','10000000-0000-4000-a000-000000000002')),
  jsonb_build_object('table','production_batches','row',jsonb_build_object('batch_date',current_date,'batch_lot','LTEST-B','product_id','daaa337d-4ed4-48a6-9260-565f06df73c3','milk_in_kg',1))), null);
reset role;
select (select count(*) from fabula.scan_events where code='LOT:BANCO') banco_events, (select count(*) from fabula.production_batches where batch_lot='LTEST-B') banco_batches;
select count(*) ledger_rows from fabula.save_ledger;
