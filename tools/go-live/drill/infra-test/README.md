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
