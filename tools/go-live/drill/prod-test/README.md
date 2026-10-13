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
for t in food_safety weighed_sales task_times wholesale farm_shipments; do
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
- `test_audit_farm_shipments.sql` (v0.94a):
  - The farm corrects the kg of a load in transit, with a reason required; the first kg is kept and a Bot feed message is
    posted. A wrong token changes nothing.
  - The farm cancels a load, after which it can't be changed again. The farm page shows the cancellation and the
    correction.
  - The same kg re-entered after a cancel makes a new load.
  - A cancelled load is refused at intake with the reason; a received one is taken at the corrected kg and is locked
    for the farm.
  - The health check reports loads in transit for more than 36 h. Banco can't cancel; the owner must give a reason, then
    cancels and the report clears.
  - Grants.

  12/10/2026: 18/18 PASS; on v0.93 12 fail.
- `test_audit_s_items.sql` (v0.95, audit backlog items under an hour, High/Critical):
  - A-12: a queued check closes its task in the name sent with it.
  - B-02/B-05: lab outcome corrected with a reason (first outcome kept, NC and hold on a correction to NON conforme);
    sample lots upper-cased, unknown lots refused, milk lots (also with a space) accepted.
  - B-03: external calibration needs certificate + deviation or PDF, no future date; without deviation «da verificare», still
    out of service, due date unchanged; the register prints it.
  - B-04: review period cut at today, a future start refused, signed by the logged-in user.
  - D-03: a plain UPDATE lifting a hold is refused (app user and SQL); setting a hold is allowed; the release permission is
    used once and does not leak; hold changes audited.
  - D-09: a delivery cannot be over-drawn (+2 % allowed). D-12: impossible readings, empty CCPs and curd pH 52 refused; a real
    27 °C cold room recorded; sensor rows exempt; a CCP row without value does not count at batch close.
  - FARM-01: needs_confirm against today's order and, with no order, against the usual loads; confirmed loads recorded;
    under 50 kg refused; older callers (no p_confirm) unchanged; grants.
  - C-28, C-04 (time, day lists and ranges, fallback), E-20 (`bots_ok`), PRINT-03 (`company_docs_check`, street addresses).

  12/10/2026: 63/63 PASS on a fresh replay and on the database built by the SQL Editor script.
- `test_audit_critical.sql` (v0.96, the remaining Critical items):
  - A-04: a positive milk retest rejects the delivery and the farm load, writes off the raw milk left, holds the lots and the
    ricotta made from it (and a lot already held for another reason gets the milk reason added); the milk register shows the
    linked test; a delivery refused at arrival raises one alert.
  - A-03: a lot closed without CCP 2/3 is held, with the message saying so.
  - D-02: app users cannot UPDATE/DELETE the record tables; `correct_record` with reason and permission (own record within
    15 min, else level 3); a corrected value out of limit opens the NC and holds (a milk check rejects the delivery); a reading
    moved to another lot holds that lot, moves the NC, and holds the lot left without its CCP; open lots and delivery
    temperatures are not corrected directly; the register prints «CORREZIONE».
  - D-21: a second close refused with time and kg; one production output per lot.
  - A-01: PINs (own or by a manager, easy ones refused, bcrypt only, table unreadable), PIN check with tries left and 15-min
    lock, `floor_operators` without PIN data, badge in/out (a second scan does not clock out, offline time kept), operator +
    logged-in account on the record, the daily `operator_off_shift` check.
  - E-01: link codes (one use), default topics by profile, routing (HACCP responsible always for food safety; decisions wait
    for quiet hours; system at once to the owner), 3-hour dedupe, no push for warnings/simulations, the minute tick, claim
    (no double hand-out, skipped when taken or unlinked, failed after 5 tries), «Me ne occupo io» with edits, the 30-minute
    reminder (once; taking it takes the original), alert notices pushed once, NCs pushed, infra-first topics, blocked bot
    unlinked, settings, overview by permission, test message, `notify_failed`/`notify_stuck`, webhook bootstrap on first link.
  - FARM-02: over 2 % without a reason refused; with it both weights kept and the dairy's counts (stock too); within 2 % the
    farm's counts; the office notice; the farm page and its month total; MOD-01 prints both.

  13/10/2026: 89/89 PASS on a fresh replay and on the database built by the SQL Editor script.

# Audit floor flows (v0.97)
```
tools/go-live/drill/infra-test/replay.sh f_test
su postgres -c "psql -d f_test -f tools/go-live/drill/prod-test/test_audit_floor.sql" | grep -E "PASS|FAIL"
```
Task list (live overdue, today vs earlier, the 3-hour window, «Non fatta», 7-day close), follow-ups (cold room re-check, warm milk,
the 5-minute Telegram push, cleaning not done), offline times through `save_ops(p_client_at)` and the register line, a step without
a measurement keeps the pH, the next free lot letter, Italian errors, stock count against what the system holds at saving, 60 h DOP,
paper milk date, grants. 13/10/2026: 63/63 PASS.

