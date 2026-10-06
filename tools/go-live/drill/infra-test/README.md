# Infra autopilot test (v0.68)
```
tools/go-live/drill/infra-test/replay.sh infra_test          # scratch DB from every migration (local Postgres 16, as root)
su postgres -c "psql -d infra_test -f tools/go-live/drill/infra-test/test_infra.sql" | grep -E "PASS|FAIL"
```
Run the test once per fresh replay (it leaves a failed drill row behind on purpose). It drives the probes with fake
pg_net answers (`drill/bootstrap.sql` now records requests in `net.http_request_queue` and reads `net._http_response`):
healthy → all six infra checks green; Netlify behind, a function returning 503 twice, GitHub rate limit, a live migration
missing from GitHub → the right checks red, `infra_uptime` alert, list kept on rate limit; drift notice after 6 h;
advisor counts accepted / unknown lint flagged; a new definer view raises and resolves `infra_security`; grants;
restore drill green/red; backup extras (logins without passwords, file list without `backups/`). 05/10/2026: 9/9 PASS.

## Self-healing bots (v0.69)
```
tools/go-live/drill/infra-test/replay.sh fb_test
su postgres -c "psql -d fb_test -f tools/go-live/drill/infra-test/test_bot_fallback.sql" | grep -E "PASS|FAIL"
```
Drives `fabula.bot_fallback()` at fixed Rome times: the right bots stood in for (and only once), a bot that ran left alone,
the 6-hour window, the backup re-sent without a fake ok run, the alarm bot's extra 20 minutes, a failing stand-in logged as an
error while the others still run, the on/off setting, the nightly backup at 21:15 Rome in summer and winter, grants.
05/10/2026: 22/22 PASS. Also dry-run on the live database (rolled back): all six stand-ins run on real data.

## Tablet check-in and pg_cron watch (v0.74)
```
tools/go-live/drill/infra-test/replay.sh dv_test
su postgres -c "psql -d dv_test -f tools/go-live/drill/infra-test/test_devices_watchdog.sql" | grep -E "PASS|FAIL"
```
Check-in by staff only (a non-staff login is refused), device row upsert, refused saves stored once (dedupe by qid) with one bell
alert, queue > 2 h and old app warned once a day, `resolve_tablet_reject`, `bot_watchdog` raising "pg_cron
stopped" and failed-job alerts once each. 05/10/2026: 13/13 PASS; `test_bot_fallback.sql` still 22/22 with the new watchdog.

## Incassi: Shopify payments and bank statements (v0.82)
```
tools/go-live/drill/infra-test/replay.sh rc_test
su postgres -c "psql -d rc_test -f tools/go-live/drill/infra-test/test_recon.sql" | grep -E "PASS|FAIL"
node tools/go-live/drill/recon-test/test_recon_csv.js
```
Database: payments file with a payout line and a test-mode row, payouts rebuilt from their rows, re-import moves the status
without duplicates; bank file with two identical rows kept and an overlapping export skipped; matching payout ↔ credit
(named Shopify), two equal candidates left alone, invoice by number, wholesale order by customer name, fee/cash/stamp rules;
the "da controllare" list (card order missing from the payments file, cash order ignored, 15 € charged on 16 €, refund not a
mismatch, unknown order, payout not in the bank, unknown credits, debits as info), notice without amounts, manual match,
clear and re-match, ack with a note and undo, status numbers, a production login sees nothing and a consultant only reads,
anon cannot call. 06/10/2026: 32/32 PASS, and the security scan finds nothing new. File reader: Italian bank exports with
a preamble, Dare/Avere, quoted commas, 1.234,56, Shopify payments CSV in English and Italian: 16/16 PASS.
(The replay needs `encrypted_password`, `recovery_sent_at`, `confirmation_sent_at` on the stub `auth.users` — added to
`bootstrap.sql` in v0.82, the v0.81 login migration failed without them.)
