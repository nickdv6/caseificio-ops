-- La Perla del Cilento · go-live: purge the simulated September 2026 data
-- Paste the whole file into Supabase → SQL editor (project "Caseificio") and Run.
-- The editor will warn about a destructive operation: confirm.
-- Runs as one transaction: if any statement fails, nothing is removed.
--
-- Removes: simulated batches, lots, stock moves, milk intakes, HACCP rows, sales,
-- shipments, waste, POS closings, meter readings, the 4 "(SIM)" parties, the
-- simulated PO + milk plan + sell-down approvals, and the recall drill on a sim lot.
-- Keeps: recipes, settings, products, presets, real parties (Masseria, placeholders
-- Fornitore 1-3 / Cliente 1-2), standing orders and their confirmed orders
-- WS-261003-01/02, compliance deadlines, staff, roles, audit log, bot run history.

begin;

-- 1. Rows the original purge_simulation() (v0.3) does not know about
delete from fabula.supplier_products
 where supplier_id in (select id from fabula.parties where notes = 'simulation');

delete from fabula.milk_plans
 where (details->>'is_simulation')::boolean;          -- before its approval (FK)

delete from fabula.approvals
 where requested_by in ('agent:milk_planning', 'agent:sell_down');

delete from fabula.recall_drills
 where lot_number in (select lot_number from fabula.production_batches where source = 'simulation');

-- 2. The standard purge
select * from fabula.purge_simulation();
select fabula.purge_milk_plan_simulation();

commit;

-- 3. Check: every line should read 0 except sales_orders (2 real standing-order confirmations)
select 'stock_moves' t, count(*) from fabula.stock_moves
union all select 'production_batches', count(*) from fabula.production_batches
union all select 'milk_intake', count(*) from fabula.milk_intake
union all select 'haccp_log', count(*) from fabula.haccp_log
union all select 'sales_orders', count(*) from fabula.sales_orders
union all select 'shipments', count(*) from fabula.shipments
union all select 'waste_log', count(*) from fabula.waste_log
union all select 'pos_daily_closings', count(*) from fabula.pos_daily_closings
union all select 'meter_readings', count(*) from fabula.meter_readings
union all select 'approvals', count(*) from fabula.approvals
union all select 'purchase_orders', count(*) from fabula.purchase_orders
union all select 'parties (SIM)', count(*) from fabula.parties where notes = 'simulation'
union all select 'simulation_runs', count(*) from fabula.simulation_runs;
