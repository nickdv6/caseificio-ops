# La Perla — backups and restore (developer runbook)

> **Partners and floor staff: this page is not for you.** When the tablet, the console or the internet stop, follow the
> one-page Italian card [`sop/sistema_giu.html`](../../sop/sistema_giu.html) (PDF next to it): switch to paper, call the HACCP
> responsible and Nick, and **never restore a backup or paste SQL** (v0.96, audit E-23).

Decided 03/10/2026: free off-database export instead of the Supabase PITR add-on.

## What runs
| Layer | What | Where | Kept |
|---|---|---|---|
| Supabase Pro | daily database backup | Supabase (Database → Backups) | 7 days |
| `backup-export` (v0.43) | gzipped JSON of **every** `fabula` table | Storage → `documents` (private) → `backups/latest.json.gz` | overwritten every 2 h, Mon–Sat 07:05–21:05 Rome (summer) |
| `backup-export` nightly | same, dated | `documents/backups/daily/YYYY-MM-DD.json.gz` | 90 days |
| Off-site copy (v1.00, audit E-24) | the nightly file, **encrypted** (AES-256) | GitHub → Actions → «Off-site backup» → run → artifact `caseificio-backup-YYYY-MM-DD` | 90 days |

Worst case after losing the database: restore Supabase's daily backup, then replay anything newer from `latest.json.gz` (at most ~2 h of HACCP, lots, sales lost during working hours).
Worst case after losing the **whole Supabase project** (account, billing, region): the off-site copy on GitHub — usually one
day lost, two if GitHub skipped a whole night (three tries each night make that rare).

Scheduling: pg_cron jobs `fabula_backup_latest` (`5 5-19/2 * * 1-6` UTC) and `fabula_backup_nightly` (`15 19,20 * * *` UTC → `fabula.backup_nightly_rome()`, which runs only at 21:15 Rome) call `fabula.backup_export_call(mode)`, which POSTs to the edge function with the token from Vault secret **`backup_export_token`**. Every run is an `agent_runs` row (`agent = 'backup_export'`); the bot heartbeat flags a missed nightly run, and the go-live board shows "Off-database backup in the last 26 h".

## One-time setup (Nick)
Supabase → Project Settings → **Vault** → *Add new secret* — name `backup_export_token`, value: any long random string (e.g. 40+ characters from a password manager). Nobody needs to know it afterwards; the database reads it and sends it to the function.

v1.00 — GitHub → the repo → Settings → Secrets and variables → **Actions** → *New repository secret*, four times:

| Secret | Value | Used by |
|---|---|---|
| `BACKUP_EXPORT_TOKEN` | the same value as the Vault secret `backup_export_token` | off-site copy (fetch) · both workflows (report to the board) |
| `BACKUP_PASSPHRASE` | a **new** passphrase, 20+ characters, saved in the password manager as «Caseificio backup off-site» | off-site copy (encryption) |
| `TELEGRAM_BOT_TOKEN` | the dairy bot's token (the same as the Supabase function secret used by `notify`) | alerts |
| `TELEGRAM_ALERT_CHAT_ID` | the partners' group id (create the group, add the bot, open it on web.telegram.org: the number after `#` in the address, e.g. `-1001234567890`) | alerts |

Without `BACKUP_PASSPHRASE` the copy is not made (never unencrypted: the repo is public). **Losing the passphrase makes
every copy unreadable** — it is not stored anywhere else. Changing it only affects the copies made afterwards.

## File format
```json
{ "format": "la-perla-backup/1", "project": "ojkquhzaeypsphncjqwy", "schema": "fabula",
  "mode": "latest|nightly", "exported_at": "ISO time", "rome_day": "YYYY-MM-DD",
  "counts": { "<table>": n, ... },
  "tables": { "<table>": [ {row}, ... ], ... },
  "auth_users": [ {id, email, created_at, last_sign_in_at, …, staff: {id, full_name, app_role, active}} ],   // v0.68, no passwords
  "storage_manifest": [ {bucket, name, size, mimetype, etag, updated_at} ] }                                   // v0.68, files listed, not copied
```
`python3 tools/go-live/restore_backup.py logins latest.json.gz` and `… files latest.json.gz` print the two lists
(who to re-invite; which Storage files existed). Backups taken before v0.68 don't have them.

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

## Off-site copy on GitHub (v1.00, audit E-24)
`.github/workflows/offsite-backup.yml` is scheduled three times a night (21:40, 00:40, 03:40 UTC), because GitHub skips
scheduled runs of public repos; the nightly export is at 21:15 Rome. `tools/offsite/offsite_backup.sh` picks tonight's
`backups/daily/` file (after 21:30 Rome today's, before that yesterday's) and stops if GitHub already keeps a copy of it.
Otherwise it fetches it (yesterday's if tonight's is missing and not yet copied — marked «stale»), checks its SHA-256
against the server's, gzip, JSON and age (≤ 30 h), encrypts it, decrypts it again to prove the copy opens to the same
bytes, and keeps `caseificio-backup-<day>.json.gz.enc` + `manifest.json` (sizes, row counts, both SHA-256s) as the run's
artifact for 90 days. The plain file is deleted at the end of the run.

Each copy is reported to the database (`fabula.infra_status`, key `offsite_backup`) → board check «Off-site backup copy in
the last 2 nights». The database raises a notice and a Telegram message (topic `infra`, via `notify`) when no copy has
succeeded for 50 h, or none ever did. A copy still failing at the night's last slot (03:40 UTC) also goes straight to the
partners' Telegram group from GitHub; earlier slots only record it and let the next slot retry.

**Open a copy** (needs OpenSSL 1.1.1 or newer — on a Mac check `openssl version`: an old «LibreSSL 2.x» doesn't know
`-pbkdf2`; then `brew install openssl@3` and use `$(brew --prefix openssl@3)/bin/openssl`):
1. GitHub → Actions → «Off-site backup» → the night you want → *Artifacts* → download, unzip.
2. `openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 -in caseificio-backup-YYYY-MM-DD.json.gz.enc -out backup.json.gz`
   (asks for the passphrase from the password manager).
3. `shasum -a 256 backup.json.gz` must equal `sha256_plain_gz` in `manifest.json`; then continue from «How to restore» step 2.

## How to restore
1. **Get the file.** Supabase → Storage → `documents` → `backups/` → download (dashboard, logged in as owner).
   If Supabase itself is gone: the off-site copy above.
   Without dashboard access the database can fetch it: `select fabula.backup_fetch_call('backups/latest.json.gz');`
   (or `backups/daily/AAAA-MM-GG.json.gz`), then read the answer with
   `select content from net._http_response where id = <the number returned>;` → JSON with `b64` (base64 of the .gz) and `sha256`.
   `python3 tools/go-live/restore_backup.py when latest.json.gz` prints when it was taken (UTC and Agropoli time).
2. **Put back lost rows in the live database — the default (v0.96):**
   `python3 tools/go-live/restore_backup.py sql latest.json.gz [--tables haccp_log,non_conformities] > partial.sql` —
   inserts only the rows whose id is missing (all tables, or the ones listed) and never deletes or overwrites anything.
3. **Full restore into an EMPTY project only** (schema from the migrations first) — must be asked for explicitly:
   `python3 tools/go-live/restore_backup.py load latest.json.gz --wipe-all --target <project-ref> --confirm <exported_at> --db "<connection string>"`
   (the `--db` must contain the `--target` ref) — one transaction: triggers off (`session_replication_role = replica`, which
   Supabase's own data-import guide uses), every table emptied and refilled, sequences reset; it then prints whether every
   table's row count matches the backup. Or write the SQL and run it yourself:
   `python3 tools/go-live/restore_backup.py sql latest.json.gz --wipe-all --target <project-ref> > restore.sql`.
   The full restore **refuses to run** on a database that holds HACCP records newer than the backup.

   **Safety stop (every generated SQL, v0.96 audit E-23):** the script starts with a block that raises
   «FERMO: ripristino non confermato…» unless `set restore.confirm = '<exported_at>';` was run first in the same session;
   the message names the backup time and the exact line to add. `--confirm <exported_at>` writes that line for you (needed
   for `load`). `tools/go-live/drill/restore_guard_test.py` checks all of this on a local copy.
4. **Check:** `python3 tools/go-live/restore_backup.py verify latest.json.gz --db "…"` (row counts vs the backup; per-table
   checksums written to `restored_checksums.json`).
5. Re-invite users (`restore_backup.py logins` lists who had a login and their staff row; after they accept, `staff.auth_user_id`
   is re-linked by email), re-upload the files listed by `restore_backup.py files`, re-add the Vault secret, run `select fabula.backup_export_call('latest');`
   and confirm a new `backup_export` run with status ok.

## Repeating the drill — automatic every month since v1.00 (audit E-25)
Once a month the off-site workflow also restores the copy it just made into an empty Postgres 16 built from every
migration (`run_drill.sh`): the first copy of a month for which GitHub keeps no `caseificio-drill-YYYY-MM` artifact. It
records the result as `agent_runs` `restore_drill` (`details.via = 'github'`), so board check «Backup restore tested»
stays green without anyone doing it. A failed drill becomes a bot message (topic `infra`) from the database; GitHub
writes to the partners' group only if the database can't be reached. The run log shows only the step lines: the full
log can contain rows of the backup (a failed INSERT prints them), so it is kept only encrypted, as the artifact
`caseificio-drill-YYYY-MM` (opens like the copies). Run it by hand any time: GitHub → Actions → «Off-site backup» →
*Run workflow* → tick «Also run the restore drill». It checks row counts against the backup, foreign keys and
`ops_dashboard()`; it does not compare with live checksums — do the manual drill below for that, after big schema changes.
Known limit: a check constraint added `NOT VALID` and never validated would make the full restore refuse old rows that
break it (none today: all `fabula` constraints are validated, 13/10/2026).

Manual drill — everything needed is in `tools/go-live/drill/`:
1. Fetch the latest backup as in step 1 above (`backup_fetch_call` → `net._http_response`), decode `b64` to
   `latest.json.gz` and check its SHA-256.
2. Run the `CHECKSUM_SQL` from `restore_backup.py` on the live database right after, and save the result as `live_checksums.json`.
3. `tools/go-live/drill/run_drill.sh latest.json.gz live_checksums.json` (local Postgres 16, run as root). It builds an
   empty database from every migration (stubbed Supabase platform: `drill/bootstrap.sql`), restores the backup, checks row
   counts and checksums against live, checks every foreign key for orphan rows and runs `ops_dashboard()` on the copy.
   Expected: 0 migration failures, row counts equal, a handful of tables differing only as explained above, 0 orphans.
4. Record the result as one `agent_runs` row with `agent = 'restore_drill'` (status ok/error, summary, details) — since v0.68 the
   go-live board check `restore_tested` reads it: green for 100 days after a passing drill, red after a failed one.
   Update the "Restore drill" table above too when you can push to the repo.

Repeat it also after big schema changes. The same check can be run on a Supabase branch instead of a local Postgres.
