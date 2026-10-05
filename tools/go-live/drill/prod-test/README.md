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
