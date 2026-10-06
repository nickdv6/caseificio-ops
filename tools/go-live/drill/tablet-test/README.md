# Tablet reliability tests (v0.62)

Runs the real tablet app (fabula-tablet) in headless Chromium against a local copy of the database with the real role
policies, so atomic saves, exactly-once re-sends and the offline flows can be checked without touching the live system.

1. `../run_drill.sh latest.json.gz` — builds `restore_drill` from every migration and loads a backup.
2. `su postgres -c "psql -d restore_drill -f setup.sql"` — test login (Test Casaro, role produzione) and auth stubs.
3. PostgREST 12 (static binary from github.com/PostgREST/postgrest/releases): `postgrest pgrst.conf` (port 3000).
4. `su postgres -c "psql -d restore_drill -f test_save_ops.sql"` — SQL tests: one transaction, re-send with the same id,
   a failing step leaves nothing, update must match one row, whitelist, role policy refusal (a Banco user).
5. `python3 e2e.py` (Playwright) — expect `FAILURES: none`.

6. `python3 prod_e2e.py` (v0.70) — production card on Home: two 575 kg loads from a 1,150 kg delivery, one tap fills the batch
   start, more milk than is left asks to confirm, the second load starts offline from the kept plan, both reach the database,
   closing shows the expected kg and a normal yield saves at once. Expect `FAILURES: none`.

If the backup is older than the latest tables, the restore step of `run_drill.sh` stops after building the database from
every migration: the tests still run, after adding one milk supplier
(`insert into fabula.parties (type, legal_name, is_milk_supplier) values ('supplier', 'Masseria (test)', true)`).

7. `python3 pack_e2e.py` (v0.71) — Da spedire: pick list, packing order, late/short flags; the pack form opens with the lots
   allocated (two rows for a split line); scanning a held lot is refused; a short order asks to confirm with the reason.

   Run it on a fresh database (or first): stock left by e2e/prod_e2e changes its allocations.

8. `python3 device_e2e.py` (v0.74) — the tablet checks in with its label and app version, a refused offline save reaches
   `fabula.tablet_rejects` and the bell once, the pending line says it was reported, an older app shows "Aggiorna ora".

9. `python3 paper_e2e.py` (v0.77) — 🛡 → Ricopia da foglio di carta: sheet time kept (Agropoli), source paper, who wrote it;
   offline it queues and keeps the sheet time; out of limit opens the NC; older than 7 days refused.

10. `python3 offline_e2e.py` (v0.78) — batch started and closed with no network, both arrive in order; task list shown
    offline; direct shipment offline with the kept customers; a held lot refused.

11. `python3 guard_e2e.py` (v0.80) — **run last** (it moves today's valve checks back a day): CCP step asks for the value
    and refuses "Salta"; first batch asks for the valve check, a failed valve stops the batch; CCP 2 on start and CCP 3/4
    on close when missing; a batch closed with a skipped CCP raises the Zio Ciro alert.

Last run 06/10/2026 (v0.80), fresh DB in this order: pack_e2e 16/16, e2e 23/23, prod_e2e 13/13, device_e2e 8/8,
paper_e2e 9/9, offline_e2e 11/11, guard_e2e 15/15.
