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

If GitHub asks about two releases, approve the older one first, or reject it: the newer one contains everything in it. Only one
release runs at a time, so the newer one waits and is asked after.

### If a release stops
- **The database is never half-changed.** All the release's migrations go in one transaction: either all of them or none.
- **Server functions deployed before the stop stay deployed.** They are always written to work with the database as it was before.
- Tell Claude. The fix comes as a new merge, so you approve the new run it creates.
- **Re-run all jobs** on the stopped run only when the cause was outside the code: an expired token (after replacing the secret) or Supabase or GitHub not answering. A re-run deploys the same commit again.
- A release can also stop before you are asked (the plan or the rehearsal found a problem). The Bot feed then says «Rilascio … bloccato prima dell'approvazione»: nothing changed.
- If the message says **«Da verificare»**, Supabase's answer got lost and it is not known whether a part went in. Tell Claude: the next release checks the database and does only what is missing.
- **v1.08 itself is the exception:** the database does not yet have the release messages when it starts. If v1.08 stops, only GitHub's e-mail tells you.

### One-time setup (before the first automatic release, v1.08)
Do these in order (about 15 minutes):

1. **Supabase token for GitHub.** Supabase → Account → **Access Tokens** (https://supabase.com/dashboard/account/tokens):
   1. Create a **scoped** token (not «Create legacy token»), named «GitHub release».
   2. **Resources:** only the Caseificio project.
   3. **Permissions**, nothing else:
      - **Database: Read-write**. The release runs the migrations and records the result through the Management API's «Run a query».
      - **Edge Functions: Read-write**. It deploys the server functions and checks them afterwards.
   4. **Expiry:** about a year (the longest offered). Put a reminder in your calendar a week before.
   5. Copy it (it is shown once).
   - GitHub keeps it encrypted and gives it only to the release steps you approve.
   - If a permission is missing, the first release stops before changing anything, and the error lists the missing permission: make a new token with it and replace the secret in step 2.
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
5. **Recommended: verify bubalina.it on GitHub**, so no other GitHub account can ever publish on a bubalina.it address.
   1. GitHub → your avatar → **Settings** → **Pages** → **Add a domain** → `bubalina.it`.
   2. Add the TXT record it shows in GoDaddy.
   3. Back on GitHub, **Verify**.
6. Tell Claude the setup is done. Claude merges v1.08, and step 2 of «Each release» follows: approve it.

Nothing else is needed: the report of a blocked release uses `BACKUP_EXPORT_TOKEN`, the repository secret the outside watcher
already has since v1.00.

After v1.08:
- the app answers on https://app.bubalina.it as well as on the old Netlify address;
- v1.08b moves everyone over, through the pipeline, once you have opened the new address and signed in once.

### Before approving v1.08b (once, 2 minutes) — done 19/10
Supabase must accept sign-in links for the new address, or the invitation and «password dimenticata» e-mails would open the old one.
Supabase → project Caseificio → **Authentication** → **URL Configuration**:
1. **Site URL**: `https://app.bubalina.it` → **Save**.
2. **Redirect URLs** → **Add URL**: `https://app.bubalina.it/**` → **Save**. Leave the Netlify one in the list.

After v1.08b:
- every link the system builds (Telegram, invites, the Masseria and trade links, QR codes printed from now on) uses app.bubalina.it;
- the old Netlify address forwards every page to the same page on app.bubalina.it, but only once app.bubalina.it serves v1.08b
  (that is, after your approval: merging alone moves nobody), only when the page starts, and only when that device has nothing left
  to send. A tablet left open with records, refused saves or photos still waiting shows a blue bar with what is waiting; once it is
  all sent, «Passa al nuovo indirizzo» turns on (or it moves by itself the next time it opens). QR codes already printed keep working;
- each address has its own sign-in: everyone signs in once on the new one, and re-adds the app to the Home screen if it was there;
- reprint the barn's QR poster from the new address (Configurazione → Utenti e accessi → Link della Masseria);
- Netlify builds only when `fabula-tablet/config.js` changes, so releases spend no Netlify credits. The outside watcher checks that
  the old address still forwards («old_site»); when nobody uses it any more, set `OLD_SITE=` in `tools/watch/check.sh`.

## For Claude: preparing a release
- **Branch** `vNNN-name` from `main`.
- **Database:** new files in `supabase/migrations/<14-digit version>_<name>.sql`, newer than the live history.
  - The release wraps them all in one transaction, sent as ONE query through the Supabase API. A file must not contain `begin;`/`commit;` (or `end`, `abort`, `savepoint`…), `concurrently`, psql backslash commands or psql variables (`:name`). The plan refuses them before anyone is asked.
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
- **What will deploy:** `python3 tools/release/release.py plan --sha HEAD --live <live commit>` lists it against the live commit.
  - The live commit is the last «ok» row of `fabula.releases`, read with `release.py live --source public`, or with the Supabase connector.
- **Ship:** push the branch. When Nick says go: `git checkout main && git merge --ff-only <branch> && git push origin main`. Then watch the run.
- **Without the pipeline** (GitHub down, the token revoked):
  - Database: `python3 tools/release/release.py editor-script --live-last <the live history's last version>` writes the SQL Editor script, as before v1.08.
  - Functions: `npx -y supabase@2.118.0 functions deploy <name> --project-ref ojkquhzaeypsphncjqwy [--no-verify-jwt]` with a temporary token.
  - App: re-run the Release workflow.

## How it works
`.github/workflows/release.yml` runs `tools/release/release.py` after CI passes on `main`:

| Job / step | What it does | Secrets |
|---|---|---|
| plan | The commit must be on `main`. The live commit and the live migration history come from the database (`public.fabula_live_release()`, read with the publishable key), or `tools/release/baseline.txt` before the first release. It lists what changed since then; the migrations are exactly those the live history lacks. A STOP makes it red and nobody is asked: a migration that cannot run in one transaction or uses psql-only syntax, a live migration GitHub lacks, a new file older than the live history, a badly named file, a rewritten history. | none |
| plan · rehearsal | Only when the database changes. A scratch Postgres is built like the live one (the live history's versions, from the live commit's files, `replay.sh` with `MIGRATIONS_DIR`). The release script must apply on it and a second run must be refused. | none |
| plan · GitHub facts (v1.18) | Tells the database what `origin/main` holds (commit, migration versions, app version: `release.py github`), because the database's hourly check no longer reads GitHub. Runs whenever the plan runs (after CI passes on main), also for «Nothing to deploy»; it never fails the job, and a report about an older commit than the stored one is ignored. | `BACKUP_EXPORT_TOKEN`, that step only |
| plan · blocked | When the plan or the rehearsal fails, the Bot feed and Telegram say «bloccato prima dell'approvazione». It goes through `public.fabula_outside_report(…, 'release', …)`, the outside watcher's channel. | `BACKUP_EXPORT_TOKEN`, that step only |
| apply | Waits for Nick's approval of the `live` environment. The environment only allows `main`. | `SUPABASE_ACCESS_TOKEN` on the steps that call Supabase |
| apply · live, check | Reads the live commit again through the Management API. A newer release finished meanwhile → nothing to do. A rewritten history → STOP, recorded. | yes |
| apply · CLI | Supabase CLI 2.118.0 from its GitHub release, checked against a pinned sha256, installed in a step with no secret. | — |
| apply · deploy | 1. Reads the live migration history first: every live version must exist on GitHub, otherwise STOP before anything changes. 2. Functions (`supabase functions deploy --use-api`, checked on Supabase afterwards). 3. Database in `release.json`'s order. | yes |
| apply · deploy (database) | One transaction through the Management API (the SQL Editor's path), with the same guard as the old scripts. Each file starts from the default search_path, as in CI. A marker made at the start (a temporary table holding the transaction's id) must still be there at the end, so a file that ends the transaction itself fails the release and its rehearsal. A lost answer (a timeout, a gateway 5xx, a cut connection): the script is looked for in `pg_stat_activity` by its tag until it ends (up to 15 minutes), then the history decides; if that cannot be known, the step is «da verificare». It stops at the first failure. | yes |
| apply · site | `fabula-tablet/` is published on GitHub Pages, and `sw.js` must answer with the new version. If it does not yet, that is a warning: DNS and HTTPS can lag. | — |
| apply · record | `fabula.release_record()`: a row in `fabula.releases`, a message in the Bot feed, the line «Rilasci automatici» in Panoramica → Sistema. An «ok» row is what makes the commit live: no git tag, nothing written to the repo. A stopped release lists what is already live (functions deployed before the stop) and what is to be checked. If the result cannot be written, a last step reports «esito non registrato» through the watcher's channel. | yes |
| apply · GitHub facts (v1.18) | The same report as in the plan, once more after the release, so the board compares the new database with main straight away. Never fails the job. | `BACKUP_EXPORT_TOKEN`, that step only |

The `github-pages` environment that GitHub creates for Pages is not used by this workflow. Only people with write access to the
repository (Nick, Claude) could publish through it, from a workflow of their own.

Tests: `tools/release/test_release.py` (in CI) covers:
- small git repos;
- the script on a scratch history;
- the rehearsal;
- deploy and record against a fake Management API and a fake CLI.

`tools/go-live/drill/prod-test/test_v108_release.sql` covers the database side.
