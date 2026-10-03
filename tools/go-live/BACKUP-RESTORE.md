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

## Restore a table (or a few rows)
1. Storage → `documents` → `backups/…` → download the file; `gunzip` it.
2. Look at the rows: `jq '.counts' file.json`, `jq '.tables.haccp_log' file.json`.
3. Re-insert what is missing — in the SQL editor, with the JSON pasted as a literal:
   ```sql
   insert into fabula.haccp_log
   select * from jsonb_populate_recordset(null::fabula.haccp_log, '<paste the JSON array>'::jsonb)
   on conflict (id) do nothing;
   ```
   Insert parents before children (e.g. `production_batches` before `haccp_log`, `sales_orders` before `sales_order_lines`).
4. Test a restore once before go-live on a scratch Supabase branch or project, not on production.
