# Production autopilot test (v0.70)
```
tools/go-live/drill/infra-test/replay.sh prod_test
su postgres -c "psql -d prod_test -f tools/go-live/drill/prod-test/test_production_plan.sql" | grep -E "PASS|FAIL"
```
Run once per fresh replay. Checks `fabula.production_plan()`: only accepted milk with kg left, oldest first; equal vat loads
(1,150 kg → 2 × 575, 1,700 kg → 3 loads); product, default preset, 30 % default yield, recipe doses, whey/ricotta, 60 h
DOP deadline, milk-plan target, open batches, today's output; a started batch takes its milk out of the plan. Yield check
at close: expected yield stored, low/high flag and one message (not repeated on edits, cleared when corrected), simulation
batches skipped; expected yield learns from the preset's batches; ricotta default; grants. 05/10/2026: 19/19 PASS.
The tablet side is `tablet-test/prod_e2e.py`.

# Packing on autopilot test (v0.71)
```
tools/go-live/drill/infra-test/replay.sh pack_test
su postgres -c "psql -d pack_test -f tools/go-live/drill/prod-test/test_packing.sql" | grep -E "PASS|FAIL"
```
Stock A (expires tomorrow), B (in 4 days), C (on hold), X (expired); orders S1 online late, W1 wholesale today, W2 tomorrow.
Checks packing order, FEFO allocation with the online shelf-life minimum, split over lots, no double promise (W2 short),
blocked lots with reasons, the pick list; pack_order refuses held/expired even with confirm, asks to confirm short life /
short stock / weight with reasons, saves on confirm and notes it, gives a guest order a consignee. 05/10/2026: 14/14 PASS.

# Production guard rails test (v0.80)
```
tools/go-live/drill/infra-test/replay.sh guard_test
su postgres -c "psql -d guard_test -f tools/go-live/drill/prod-test/test_prod_guards.sql" | grep -E "PASS|FAIL"
```
`v_process_steps.ccp_code`; a batch closed without CCP 2/3 (mozzarella) or CCP 4 (ricotta) alerts once, a CCP logged in the
same transaction as the close counts, simulation batches skipped; `prod_watch` only at 19:xx Rome, open batches and milk
48 h old, one post a day; not callable by app users. 06/10/2026: 10/10 PASS.

# Audit fixes, phase 0 (v0.93)
```
tools/go-live/drill/infra-test/replay.sh audit_test     # one fresh replay per file: they add test rows
for t in food_safety weighed_sales task_times wholesale; do
  su postgres -c "psql -d audit_test -f tools/go-live/drill/prod-test/test_audit_$t.sql" | grep -E "PASS|FAIL"
done
```
- `test_audit_food_safety.sql`:
  - A CCP out of limit holds the lot for Banco/Spedizioni too; `log_ccp` is refused without haccp level 2.
  - A recall assessment stays pending (no expiry) and `ops_health_check` reports `recall_pending`.
  - Alerts sort first.
  - The CCP limit guard refuses a blank limit, min ≥ max, and alert thresholds outside the limits.
- `test_audit_weighed_sales.sql`:
  - A POS line with no variant but `sku` + `peso_kg` reduces stock by kg × quantity.
  - An unknown free sale goes to `shopify_unmapped_lines` and the rest of the order still syncs.
- `test_audit_task_times.sql`: daily task due times in Agropoli time in winter (CET) and summer (CEST); the default day is today in Agropoli.
- `test_audit_wholesale.sql`:
  - A change under the minimum order is refused with the reason.
  - Cut-off messages have no stray `s`.
  - «Salta» on a booked day cancels the order and its Shopify queue entry; another change there is refused.
  - A day under the minimum at booking is logged for the customer and posted to the Bot feed once.
  - `v_shipment_doc` has the delivery fields and keeps `security_invoker`.

12/10/2026: 18/18, 6/6, 4/4, 16/16 PASS. Before the fixes, 12 food-safety and 12 wholesale checks failed, the weighed sale
broke the sync and task times came out at 07:45/08:45 instead of 06:45.
