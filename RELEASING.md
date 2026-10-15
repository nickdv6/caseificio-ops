# Releases (from v1.08)

Merging a version into `main` is the release. GitHub waits for CI, shows what will change, rehearses the database part, asks Nick
**once** to approve, then does everything else: server functions, database, the app on app.bubalina.it. The result lands in the Bot
feed («Rilasci»), and on Telegram when a release stops.

Until v1.07 each release was a list of steps for Nick (a temporary Supabase token and a CLI deploy from the Mac, a paste in the SQL
Editor, a git merge and push, a Netlify deploy). None of them is needed any more.

## For Nick

### Each release
1. Claude says the version is ready and merges it into `main` when you say go.
2. About 5–10 minutes later GitHub asks you (app notification and e-mail): **Review pending deployments → live**.
   - Open it. The run's page starts with «Release plan»: what changes (database, server functions, app) and what is left by hand.
   - Tap **Review deployments**, tick **live**, then **Approve and deploy**.
3. A few minutes later the Bot feed says «Rilascio v1.xx fatto», with anything left to do by hand under «Da fare».
   - If it stops, the message says at which step, on Telegram too.

Nothing is asked when a merge changes only documents, tests or tools.

### If a release stops
- **The database is never half-changed.** All the release's migrations go in one transaction: either all of them or none.
- **Server functions deployed before the stop stay deployed.** They are always written to work with the database as it was before.
- Tell Claude. After the fix: GitHub → Actions → Release → the run → **Re-run all jobs**, or the next merge carries it.

### One-time setup (before the first automatic release, v1.08)
Do these in order (about 15 minutes):

1. **Supabase token for GitHub.** Supabase → Account → **Access Tokens** (https://supabase.com/dashboard/account/tokens):
   1. **Generate new token**, named «GitHub release», with the longest expiry offered.
   2. Copy it (it is shown once).
   - When it expires, a release stops with «token non valido o scaduto»: make a new one and replace the secret in step 2.
2. **GitHub environment «live»**, the approval step. Repo nickdv6/caseificio-ops → **Settings** → **Environments** → **New environment**:
   1. Name: `live` → **Configure environment**.
   2. **Required reviewers**: tick it, add `nickdv6`, **Save protection rules**.
   3. **Deployment branches and tags**: **Selected branches and tags** → **Add deployment branch or tag rule** → `main`.
   4. **Environment secrets** → **Add environment secret**: name `SUPABASE_ACCESS_TOKEN`, value: the token from step 1.
3. **GitHub Pages**, where the app lives from now on. Repo **Settings** → **Pages**:
   1. **Source**: GitHub Actions.
   2. **Custom domain**: `app.bubalina.it` → **Save**.
   3. **Enforce HTTPS** can be ticked once GitHub has the certificate (minutes to an hour after step 4).
4. **DNS for app.bubalina.it**, where bubalina.it's DNS is managed (GoDaddy) → **DNS** → **Add record**:
   - type `CNAME`, name `app`, value `nickdv6.github.io`, TTL 1 hour.
   - This only adds an address. The shop on www.bubalina.it does not change.
5. Tell Claude the setup is done. Claude merges v1.08, and step 2 of «Each release» follows: approve it.

After v1.08:
- the app answers on https://app.bubalina.it as well as on the old Netlify address;
- v1.08b moves everyone over, through the pipeline, once you have opened the new address and signed in once.

## For Claude: preparing a release
- **Branch** `vNNN-name` from `main`.
- **Database:** new files in `supabase/migrations/<14-digit version>_<name>.sql`, newer than the live history.
  - The release wraps them all in one transaction. A file must not contain `begin;`/`commit;`, `concurrently` or psql backslash commands. The plan refuses them before anyone is asked.
- **Server functions:** in `supabase/functions/<name>/`. Only those changed since the live commit are deployed (all of them when `_shared/` changes), with `verify_jwt` from `supabase/config.toml`.
- **App:** in `fabula-tablet/`. Bump `CACHE` in `sw.js`.
- **`tools/release/release.json`**, one per version:
  - `version`, `title_it`;
  - `order`: whether functions or database go first (default: functions first, written to work with the old database);
  - `after_it`: steps left for people, shown in the Bot feed;
  - `force`: parts to deploy even if git shows no change, honoured only by the release that edits the file.
- **Bot prompts:** edit `tools/bots/prompts/*.txt`, run `tools/bots/sync_rules.py`, and add the `--versions` output in a migration.
  - After the release, update the scheduled tasks in the session (update_trigger). The release message reminds Nick which bots changed.
- **Tests:**
  - `sudo python3 tools/ci/run_sql_ci.py`: every SQL suite and `tools/release/test_release.py`;
  - the browser suites in `tools/go-live/drill/tablet-test`.
- **What will deploy:** `git fetch --tags && python3 tools/release/release.py plan --sha HEAD` lists it against the live commit.
- **Ship:** push the branch. When Nick says go: `git checkout main && git merge --ff-only <branch> && git push origin main`. Then watch the run.
- **Without the pipeline** (GitHub down, the token revoked):
  - Database: `python3 tools/release/release.py editor-script --live-last <the live history's last version>` writes the SQL Editor script, as before v1.08.
  - Functions: `npx -y supabase@2.118.0 functions deploy <name> --project-ref ojkquhzaeypsphncjqwy [--no-verify-jwt]` with a temporary token.
  - App: re-run the Release workflow.

## How it works
`.github/workflows/release.yml` runs `tools/release/release.py` after CI passes on `main`:

| Job / step | What it does | Secrets |
|---|---|---|
| plan | The commit must be on `main`. It lists what changed since the live commit: the git tag `live`, or `tools/release/baseline.txt` before the first release. A STOP (a migration that cannot run in one transaction, a rewritten history) makes it red and nobody is asked. | none |
| plan · rehearsal | Only when the database changes. A scratch Postgres is built from the live commit's migrations (`replay.sh` with `MIGRATIONS_DIR`). The release script must apply on it and a second run must be refused. | none |
| apply | Waits for Nick's approval of the `live` environment. The environment only allows `main`. | `SUPABASE_ACCESS_TOKEN`, on two steps |
| apply · check | Reads the tag again. A newer release finished meanwhile → nothing to do. | — |
| apply · deploy | 1. Reads the live migration history first: every live version must exist on GitHub, otherwise STOP before anything changes. 2. Functions (`supabase functions deploy --use-api`, checked on Supabase afterwards). 3. Database in `release.json`'s order: one transaction through the Management API (the SQL Editor's path) with the same guard as the old scripts, then the history is read again. It stops at the first failure. | yes |
| apply · site | `fabula-tablet/` is published on GitHub Pages, and `sw.js` must answer with the new version. If it does not yet, that is a warning: DNS and HTTPS can lag. | — |
| apply · record | `fabula.release_record()`: a row in `fabula.releases`, a message in the Bot feed, the line «Rilasci automatici» in Panoramica → Sistema. | yes |
| apply · tag | The tag `live` moves to the released commit, only when every step worked. | GitHub token |

Tests: `tools/release/test_release.py` (in CI) covers:
- small git repos;
- the script on a scratch history;
- the rehearsal;
- deploy and record against a fake Management API and a fake CLI.

`tools/go-live/drill/prod-test/test_v108_release.sql` covers the database side.
