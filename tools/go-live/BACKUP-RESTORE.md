# La Perla — backups and restore

Decided 03/10/2026: free off-database export instead of the Supabase PITR add-on.

## What runs
| Layer | What | Where | Kept |
|---|---|---|---|
| Supabase Pro | daily database backup | Supabase (Database → Backups) | 7 days |
| `backup-export` (v0.43) | gzipped JSON of **every** `fabula` table | Storage → `documents` (private) → `backups/latest.json.gz` | overwritten every 2 h, Mon–Sat 07:05–21:05 Rome (summer) |
| `backup-export` nightly | same, dated | `documents/backups/daily/YYYY-MM-DD.json.gz` | 90 days |

Worst case after losing the database: restore Supabase's daily backup, then replay anything newer from `latest.json.gz` (at most ~2 h of HACCP, lots, sales lost during working hours).

Scheduling: pg_cron jobs `fabula_backup_latest` (`5 5-19/2 * * 1-6` UTC) and `fabula_backup_nightly` (`15 19 * * *` UTC) call `fabula.backup_export_call(mode)`, which POSTs to the edge function with the token from Vault secret **`backup_export_token`**. Every run is an `agent_runs` row (`agent = 'backup_export'`); the bot heartbeat flags a missed nightly run, and the go-live board shows "Off-database backup in the last 26 h".

## One-time setup (Nick)
Supabase → Project Settings → **Vault** → *Add new secret* — name `backup_export_token`, value: any long random string (e.g. 40+ characters from a password manager). Nobody needs to know it afterwards; the database reads it and sends it to the function.

## File format
```json
{ "format": "la-perla-backup/1", "project": "ojkquhzaeypsphncjqwy", "schema": "fabula",
  "mode": "latest|nightly", "exported_at": "ISO time", "rome_day": "YYYY-MM-DD",
  "counts": { "<table>": n, ... },
  "tables": { "<table>": [ {row}, ... ], ... } }
```

## Restore drill — tested 05/10/2026 ✅
The real `backups/latest.json.gz` (taken 02:27 UTC, 79,722 bytes, 93 tables, 1,017 rows) was restored into a scratch
Postgres built only from `supabase/migrations/` (81 files) and compared with the live database taken one minute later.

| Check | Result |
|---|---|
| File integrity | SHA-256 from the edge function = SHA-256 of the received file |
| Tables / rows | 93 / 1,017 in the backup, in live and in the restored database |
| Content (md5 per table, rows in primary-key order) | 87 tables byte-identical; 6 differ in representation only — see below |
| Values, row by row, for those 6 tables | identical, except the backup's own `agent_runs` row (captured mid-run as "running") |
| Foreign keys | 154 checked, 0 orphan rows |
| Sequences | reset past the highest id (e.g. bot_messages 54 = max id) |
| App functions on the restored copy | `ops_dashboard()` runs and returns the same scores |
| Partial restore (one table) | 5 deleted leads put back, a row edited after the backup left as it is |
| Time | under 1 second for the whole load |

**Representation-only difference:** the backup passes through JavaScript JSON, so a number written with trailing zeros
inside a json/jsonb field or a numeric column without fixed decimals comes back without them (2040.00 → 2040, 1.0 → 1).
The value is the same; columns with fixed decimals (numeric(10,2)) keep their format. Numbers with more than 15
significant digits would be rounded — none exist in the data today.

**Not in the backup — restore these separately after a disaster:**
- Supabase Auth users (logins). `staff.auth_user_id` points to them: re-invite people from Configurazione → Utenti e accessi
  (or restore Supabase's own daily backup, which includes auth).
- Storage files: DDT photos, lab certificates, marketing media and the backups themselves (`documents`, `marketing` buckets).
- Vault secret `backup_export_token`, edge-function secrets (Predis key), Netlify site — set them up again.
- The schema itself is not in the file: build it from `supabase/migrations/` (`supabase db push`), then load the data.

## How to restore
1. **Get the file.** Supabase → Storage → `documents` → `backups/` → download (dashboard, logged in as owner).
   Without dashboard access the database can fetch it: `select fabula.backup_fetch_call('backups/latest.json.gz');`
   (or `backups/daily/AAAA-MM-GG.json.gz`), then read the answer with
   `select content from net._http_response where id = <the number returned>;` → JSON with `b64` (base64 of the .gz) and `sha256`.
2. **Full restore into an empty project** (schema from the migrations first):
   `python3 tools/go-live/restore_backup.py load latest.json.gz --db "<connection string>"` — one transaction:
   triggers off (`session_replication_role = replica`, which Supabase's own data-import guide uses), every table emptied
   and refilled, sequences reset; it then prints whether every table's row count matches the backup.
   Or write the SQL and run it yourself: `python3 tools/go-live/restore_backup.py sql latest.json.gz > restore.sql`.
3. **Put back a table or a few lost rows** in the live database:
   `python3 tools/go-live/restore_backup.py sql latest.json.gz --tables haccp_log,non_conformities > partial.sql` —
   inserts only the rows whose id is missing and never deletes or overwrites anything.
4. **Check:** `python3 tools/go-live/restore_backup.py verify latest.json.gz --db "…"` (row counts vs the backup; per-table
   checksums written to `restored_checksums.json`).
5. Re-invite users, re-upload any needed files, re-add the Vault secret, run `select fabula.backup_export_call('latest');`
   and confirm a new `backup_export` run with status ok.

The drill was run against a local Postgres 16 built from the migrations (the same check can be repeated on a Supabase branch).
Repeat it after big schema changes, and at least every 3 months.
