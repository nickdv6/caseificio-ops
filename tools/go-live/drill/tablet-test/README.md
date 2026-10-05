# Tablet reliability tests (v0.62)

Runs the real tablet app (fabula-tablet) in headless Chromium against a local copy of the database with the real role
policies, so atomic saves, exactly-once re-sends and the offline flows can be checked without touching the live system.

1. `../run_drill.sh latest.json.gz` — builds `restore_drill` from every migration and loads a backup.
2. `su postgres -c "psql -d restore_drill -f setup.sql"` — test login (Test Casaro, role produzione) and auth stubs.
3. PostgREST 12 (static binary from github.com/PostgREST/postgrest/releases): `postgrest pgrst.conf` (port 3000).
4. `su postgres -c "psql -d restore_drill -f test_save_ops.sql"` — SQL tests: one transaction, re-send with the same id,
   a failing step leaves nothing, update must match one row, whitelist, role policy refusal (a Banco user).
5. `python3 e2e.py` (Playwright) — expect `FAILURES: none`.

Last run 05/10/2026: all SQL tests as expected, e2e 21/21 passed.
