# Bug report: La Perla ops system (4 Oct 2026)

**Scope:** the tablet PWA, console, Configurazione, HACCP, marketing and sales pages, the print pages, 4 edge functions, and all 65 migrations.

**How it was tested:**
- **Database replay.** All migrations were applied in order to a clean Postgres 16 with Supabase-style auth and roles. 30 days of data were generated with `simulate_days()`. Then every view and every function without required arguments was run as three profiles: titolare, produzione and marketing.
- **Front-end checks.** Every table, view and RPC the front end calls was matched against the schema. Every page was loaded in headless Chromium and checked for console errors.
- **Code review.** All JS and SQL were reviewed line by line.

**Live check.** After the Supabase connector was moved to "AG AI", the live Caseificio project was checked read-only. Nothing was changed. The checks were: security and performance advisors, the last 24 h of logs, storage policies, the migration history, and the live function and view definitions compared with the repo. Logged-in browser flows were not run. Items marked ✅ were reproduced locally; 🔴 marks items confirmed on the live database; the rest were confirmed by reading the code.

## Fixed (4 Oct, v0.54 + v0.55, verified on live)

| Item | Fix |
|---|---|
| L1 · backups readable by every user | `documents` bucket: `backups/` reachable only by the backup job; read/upload need an active staff profile; overwrite only by the uploader or HACCP managers (v054) |
| 1 · blocked/expired lots sold via Shopify/POS | `upsert_shopify_orders` skips held and expired lots; uncovered qty booked without a lot (v055) |
| 3 · NON CONFORME result lost on unknown lot | result, NC and recall card always saved; known lot held; unknown lot → console alert to block by hand; `lot_on_hold` now accurate (v055) |
| 4 · failed calibration left instrument in service | `record_calibration_check` runs as definer with `require_perm('haccp', 2)`; out-of-service instrument readings become warnings with a "repeat with a verified instrument" note (v055) |
| 5 · rejected milk could start a batch | DB trigger on `batch_milk_inputs` refuses rejected milk; tablet stops at the scan with "Latte respinto" (v055 + app.js) |
| 2 · offline queue lost records saved during a flush | queued items carry an id; a flush now keeps whatever was queued while it was sending (browser-tested: old code lost the record, new code keeps it and sends it on the next flush) (app.js) — **needs redeploy** |
| 7 · "Salvato" when the database refused the change | every page's updates now ask for the changed rows back; 0 rows → "Non salvato: il tuo profilo non può modificare questi dati…" (perm.js `PERM.changed`, ui.js, admin, console, HACCP, marketing, vendite) — **needs redeploy**. Note: the Marketing profile still can't change `mkt.*` settings (sistema level 0) — it now sees the error instead of a false "Salvato"; grant it in the DB if Marketing should own those settings |
| 10 (tablet) · resume uses wrong preset | `preset_id` added to the resume query (app.js) — **needs a redeploy of `fabula-tablet`** |

## Fixed (5 Oct, v0.59)

| Item | Fix |
|---|---|
| 6 · stored XSS in 3 places | Tablet "Da spedire" (Shopify customer name, address, lines) and the other tablet lists now escape every database value; console approval cards escape `payload.from/to/batches/promo_pct` and dates (`fmtD` escapes); Vendite escapes `fit_note`/`size_hint` and only links `http(s)` URLs (`javascript:`/`data:` dropped) — **needs redeploy** |
| 9 · offline start locked the user out | `perm.js` keeps the last profile per user on the device and uses it when the database can't be reached; startup calls time out after a few seconds (offline, supabase-js retried an expired login for ~50 s and every query waited behind it); a stored login counts as signed in when offline. Tested in Chromium: offline with saved profile → home in 0.8 s (8 s when Wi-Fi is up but the internet is down); first login offline → clear message; logged out → login screen — **needs redeploy** |
| 8 / L2 / L3 / L5 · migrations didn't match live | v044c/d files renamed to their live versions; v044/v044b recorded as applied; new `20261001033000_v000_platform_extensions` (pg_cron, pg_net, pgcrypto, uuid-ossp), `20261002201700_v040a_bot_messages_table` (table, indexes, RLS + 5 policies from live), `demand_7d()` + `v_demand_7d` restored into their file, the 2 hand-scheduled pg_cron jobs in `v059a`. Repo 76 files = live 76 versions. Replay of all migrations on clean Postgres 16 matches live on functions, views, tables, constraints, indexes, policies, triggers, enums, cron jobs and buckets; the 26 function bodies that differ do so only in comments |
| monthly review closed the running month | `monthly_review()` falls back to the previous month when given a date in the current or a future month (v059b) |

## Fixed (5 Oct, v0.60 — app sw perla-v34, DB v060a/v060b, edge functions predis v2, invite-user v2, backup-export v2)

All items below are deployed. Tested: clean replay of all migrations + v060 on Postgres 16 (role checks run as a Produzione user), every page loaded in headless Chromium with no errors, the tablet driven offline (meter with Enter, temperature from cached machine data), and a live backup run with the new ordering (93 tables, 1,015 rows).

| Item | Fix |
|---|---|
| 10 · forms refuse values / Enter reloads | number fields no longer validate a step (96.64 kg saves); Enter on a one-field screen saves instead of reloading |
| 11 · pack always says SIMULAZIONE | `[hidden]` now wins over `.badge`; default month computed from the Agropoli date (31st bug gone); "11/2026" accepted |
| Tablet · reused tank id breaks intake | a lot id already used gets the date (T1 → T1-0510, then -2…) and the tablet says so; a real duplicate now gives a clear "già registrato" message |
| Tablet · re-sends duplicate or fail | each queued record keeps which steps already went through, so a re-send never repeats an RPC (receive, CCP) or re-inserts batch milk inputs; `shipment_lines` gets a tablet id |
| Tablet · multi-step saves not atomic (partly) | a refused step now says "Salvato solo in parte (N di M passi)"; a re-send continues from the failed step. Full atomicity needs server-side RPCs (still open) |
| Tablet · no permission check | each scan checks the profile first (HACCP / produzione / magazzino / spedizioni ≥ registra) and says why it can't continue |
| Tablet · notices without scan | shown as text, no more "undefined ›" button |
| Tablet · "In turno" empty for floor profiles | new `floor_open_shifts()` (names + hours only) |
| Tablet · forms don't work offline | machines, control points, milk suppliers and pest stations are kept on the device (refreshed after each login): temperature, milk intake, cleaning, CCP and pest forms open offline; tasks are closed by a queued `close_open_task()` for the Agropoli day; lot screens say clearly that they need the network |
| Tablet · HACCP saves fail silently | network errors queue the record; any other error is always shown |
| Tablet · cancelled scan hijacks the next | Annulla clears the pending lot scan and returns to the form |
| Tablet · codes upper-cased | only the prefix is upper-cased; lot look-ups ignore case |
| Tablet · logout loses the queue | the queue waits for the next login (nothing is sent without a session) and the tablet says how many records are waiting |
| Tablet · last dosing step freezes | a failed close stays on screen with "Riprova a chiudere" |
| Tablet · UTC dates | dates, lot codes and expiry use the Agropoli date |
| Tablet · "$5" treated as a reference | only "$<n>.<field>" is a reference |
| Tablet · batch letter from a count | next free letter among today's L-lots, re-read just before saving |
| Tablet · weight confirmation stays on | any change after a "check and press Salva again" warning asks again |
| Console · saving a row wipes other edits | the list reloads only after the last edited row is saved (`UI.after`) |
| Console · preset step edits not guarded | both lines of a step are one unsaved-change scope |
| Console · sell-down / scorte off by one | days counted from today in Agropoli |
| Config · titolare can demote himself | DB guard: there must always be one active person who manages users |
| Config · "1.300" saves as 1.3; invalid numbers save as NULL/0 | Italian number parsing; invalid numbers stop the save with a message (standing orders no longer switch a day off) |
| Console · fast ◀ on the rota | only the latest requested week renders |
| Config · #bots / #account links | hash changes switch the tab |
| Console · yield chart drops to 0 % | open batches left out |
| Recipes · instruction can't be cleared; old dose after midnight | empty instruction clears it; recipe editor uses the Agropoli date |
| Console · "lunì" | accented weekday names abbreviated correctly |
| Console / Vendite · WhatsApp prefix | one rule everywhere: +39/0039 kept once, local mobiles (incl. 390–393…) and landlines get 39 |
| Console · "Nessuna vendita POS ieri" never shows | shown when the brief has no POS day |
| Config · cancelling Disattiva clears the unsaved mark | only Salva clears it |
| Config · month typed as 11/2026 | saved as 2026-11-01 |
| Config / console · browser time | audit log and last-sync time in Agropoli time |
| HACCP · pest visit fails for level 2 | `complete_deadline()` runs as definer with HACCP ≥ 2 |
| HACCP · release lot / close NC only restricted in the UI | DB: release needs HACCP 3 and is signed by the logged-in person; closing or reopening an NC needs HACCP 3 (trigger) |
| Marketing · edited approved post stays approved | goes back to review when the new text fails the claims check or the editor can't approve |
| Marketing · Marketing profile can't save mkt.* | mkt.* settings writable with Marketing ≥ 2 |
| Marketing · preorders double-counted | orders counted once |
| Marketing · calendar window in UTC | starts at midnight in Agropoli |
| Marketing · draft media duplicated | `mkt_ai_complete()` is idempotent |
| Sales · new leads always "nuovo" | the chosen stage is kept |
| predis · any staff can spend credits; stuck in "generating" | needs Marketing ≥ 2; network errors/timeouts put the post back to "idea" |
| backup-export · pagination without ORDER BY | pages ordered by primary key (or all columns) |
| invite-user · ilike e-mail match | exact match |
| Advisors · mutable search_path (5) | pinned |

**Still open:** multi-step tablet saves are not fully atomic (needs a server-side RPC per flow); batch start/close and lot scans still need the network.

## Live database (Caseificio, eu-central-1)

| # | Finding |
|---|---------|
| L1 🔴 **Critical** | **Any signed-in user can read every file in the `documents` bucket, including the full database backups.** The storage policies "fabula staff read documents" and "fabula staff update documents" only check `bucket_id = 'documents'`. `backups/latest.json.gz` and `backups/daily/*.json.gz` (every table, staff e-mails, finance) are therefore readable by every profile. The update policy also lets any profile overwrite any file, including backups, lab certificates and DDT photos, which matters for HACCP evidence. Fix: keep `backups/` for `service_role` only, and limit update to the uploader or to managers. |
| L2 🔴 | **The migration history doesn't match the repo.** v044 and v044b were run in the dashboard SQL editor and are not recorded in `schema_migrations`. v044c and v044d are recorded as `20261003214312` and `20261003214340`, but the files are `…214500` and `…215000`. `supabase db push` would try to run v044, v044b, v044c and v044d again. v044 would bring back the old `sales_status()` that v044c fixed. Fix: rename the files to the live versions and mark 210000/210100 as applied with `supabase migration repair`. |
| L3 🔴 | **Objects that exist live but have no migration.** `fabula.bot_messages` (with RLS and 5 policies), `demand_7d()` and `v_demand_7d` all exist live, but nothing in the repo creates them. The `documents` bucket and its policies, and the 5 pg_cron jobs, are also missing from the repo. A fresh build from the repo fails (item 8 below). Fix: dump these into a new migration file. |
| L4 🔴 | **Two "Fix first" items confirmed on live.** `upsert_shopify_orders` assigns lots with no hold filter (item 1), and `record_calibration_check` runs with the caller's rights (item 4). The live `trg_stock_move_guard` does skip held and expired lots, but only when it has to re-allocate because the chosen lot is short of stock. |
| L5 🔴 | **Function bodies differ from the repo.** 25 function bodies differ between live and the repo. The one I spot-checked (`trg_stock_move_guard`) differs only in stripped comments; the other 24 were not compared in detail. Compare the rest before trusting the repo as the source of truth. |
| L6 | **Advisors.** `trg_staff_default_role` has a mutable search_path; add `set search_path = fabula, public`. `company_name()` is callable by anon, which is intentional for the login page. There are 125 unindexed foreign keys; this is not urgent at this data size. |
| L7 | **Logs (last 24 h) are clean.** The only errors were 9 failed staff saves on 3 Oct at 21:50 (`staff_app_role_fkey`), which v045 already fixed, and one deliberate watchdog dry run. |
| L8 | **Why these bugs haven't shown up yet.** Live today has 0 production batches and 3 staff, all titolare or socio, i.e. full access. The role-based bugs (items 4, 7, the pest visit, the Marketing settings) and the food-safety paths haven't been hit yet. They will be as soon as floor staff get accounts and production starts, so fix them before go-live. |

Correction to the local results: `v_preorder_demand` **is** `security_invoker` on live. It's only missing from the repo, which is another case of L3.

---

## Fix first

| # | Area | Bug | Where |
|---|------|-----|-------|
| 1 | Food safety | **Blocked lots can still be sold online and at the till.** `trg_block_held_lot_sale` only checks moves with `source='tablet'`. `upsert_shopify_orders` assigns lots from `v_stock_on_hand` with no hold filter and books them as `source='shopify'`. It also falls back to expired lots once fresh stock runs out. | `…130100_fabula_food_safety.sql:223`, `…002500_fabula_shopify_pos.sql:96` |
| 2 | Tablet | **The offline queue loses records.** `flush()` reads the queue once and finishes with `setQueue(left)`. Anything `save()` queues while a flush is running gets overwritten: the operator sees "messo in coda", but the record is gone. | `app.js:45-50, 70-81` |
| 3 | Food safety | **A NON CONFORME lab result can't be saved when the sample's lot isn't a production batch** (a typo at "Prelevato", or a milk lot). `record_lab_result` → `hold_lot` raises "Lotto sconosciuto", and the whole result rolls back: no non-conformity, no hold, no recall card. | `…130100_fabula_food_safety.sql:248, 386, 417` |
| 4 | Food safety ✅ | **A failed calibration doesn't take the instrument out of service for level-2 users.** `record_calibration_check` runs with the caller's rights, and the `equipment` update needs HACCP level 3. Reproduced: as Produzione, TERM-01 failed and the non-conformity opened, but `out_of_service` stayed false and `last_checked_on` stayed empty. As titolare it worked. Separately, `log_ccp` accepts readings from an out-of-service instrument. | `…130100_fabula_food_safety.sql:181, 666` |
| 5 | Tablet | **Rejected milk can start a batch.** `stepLot` looks up `milk_intake` without `accepted = true`, and the database doesn't block it either. A lot refused for a positive antibiotic test still opens "Inizio lotto". | `app.js:343` |
| 6 | Security ✅ | **Stored XSS in 3 places.** (a) Shopify customer name and address on the tablet's "Da spedire" list; the injected script could read the session token. (b) Approval card payload fields in the console. Reproduced: a Produzione user can insert an approval with HTML in `payload.from`, and it then runs in the owner's session. (c) A lead's `fit_note`/`size_hint` in Vendite, plus `javascript:` links in `website`/`source_url`. | `app.js:547`, `console.js:131,136,154`, `vendite.js:106` |
| 7 | All pages ✅ | **"Salvato" shows when nothing was saved.** `UI.upd` and the marketing settings save don't check rows affected, so an update blocked by RLS returns success with 0 rows. Reproduced: the Marketing profile can see 8 `mkt.*` settings, but its update changes 0 rows. Its Predis brand id and pickup rules are never stored. | `ui.js:24`, `marketing.js:111` |
| 8 | Database ✅🔴 | **The migrations can't rebuild the database** (the objects do exist live; see L2 and L3). `fabula.bot_messages` is never created, so v040 fails, followed by v041b, v046, v046b, v047 and v047b. `…130400_fabula_demand_7d.sql` contains only comments, so `v_demand_7d` / `demand_7d()` are missing and the console's Operazioni → Latte card fails. No migration creates the `documents` storage bucket or its policies, and backups are written to that bucket. A disaster restore from the repo would fail. | `supabase/migrations/` |
| 9 | Tablet | **Opening the app offline locks the user out.** With no network, `PERM.load` returns null and `init()` shows "account non collegato a nessuna persona attiva". This contradicts the README's "starts with no internet". | `app.js:102`, `perm.js:7-9` |
| 10 | Tablet | **Some forms can't be saved, and others lose data on Enter.** The stock count fills in quantities like 96.64 into fields with `step 0.1`, so `reportValidity()` refuses the save. The same happens with effluent (`step 10`), meter (`step 1`), and possibly pack and receive. Separately, `<form id="form">` has no submit handler: on single-field screens (meter, temperature, chlorine) Enter reloads the page to Home, so it looks saved but nothing was. | `app.js:290, 489, 511`, `index.html:100` |
| 11 | Print ✅ | **The monthly accountant pack always says "SIMULAZIONE".** The page's `.badge{display:inline-block}` overrides the `hidden` attribute (pacchetto.html doesn't load `ui.css`). Seen in the browser test. | `pacchetto.html:20,33` |

---

## Tablet app (index.html / app.js)

- **Duplicate milk lot breaks intake (high).** `labels.code` is unique, so reusing a lot/tank id such as `T1` throws 23505. `run()` then treats it as "already saved", the id lookup fails with a cryptic message, the CCP 1a/1b logs never run, and pressing Salva again inserts a second `milk_intake`. `app.js:61, 329`
- **Re-sends can duplicate or fail.** RPC steps have no idempotency, so `receive_purchase_order` and `log_ccp` run twice. `shipment_lines` is missing from `UUID_TABLES`. `batch_milk_inputs` has no `id` column, so on re-send its 23505 is rethrown and the item goes to "rifiutate". `app.js:31, 61`
- **Multi-step saves aren't atomic.** If a later step fails, earlier rows are already written. Example: a pick on a held lot leaves a "picked" shipment with no stock move. The tablet also never checks `PERM.can`, so Banco and Qualità users start actions they can't finish. `app.js:439`
- **Resume from the milk-lot label uses the default preset.** The select omits `preset_id`. `app.js:347`
- **Notices without `scan`/`label_it`** (lot guard, heartbeat, watchdog) render an "undefined ›" button that throws when tapped. `app.js:138, 213`
- **"In turno" is always empty** for the Produzione, Spedizioni and Banco profiles, because they have personale level 0 and `v_open_shifts` runs with their rights. A second badge scan then clocks them out. `app.js:144`
- **Most forms don't work offline** because they read the database first. EQ shows "Macchina sconosciuta", DDT throws on `null.map`, and CLEAN fails silently. Tasks done offline never get closed after the flush. `app.js:261, 298, 310`
- **HACCP saves can fail silently.** If `rpcNow` fails while `navigator.onLine` is true, the user gets no toast and nothing is queued. `app.js:724`
- **A cancelled scan hijacks the next one.** `scanTarget` isn't cleared on Annulla. `app.js:205, 567`
- **Typed codes are uppercased.** `METER:elec_main` becomes `ELEC_MAIN`, and lowercase milk lots can't be found. `app.js:206, 223, 292`
- **Logout leaves the queue flushing without a session**, so every queued record is moved to "rifiutate". `app.js:40, 88, 114`
- **A failed final dosing step freezes the screen.** The next ✓ throws on `steps[k]` undefined. `app.js:692`
- **Dates use UTC.** Between 00:00 and 02:00 Rome, `intake_date`, `batch_date`, the `L<yyyymmdd>` lot code and expiry dates fall on the previous day. `app.js:14, 328, 366, 394, 459`
- **Strings starting with `$` are treated as step references.** A note like "$5" becomes undefined or throws. `app.js:57`
- **Batch letter comes from a count** that includes ricotta and simulation batches, so two tablets can get the same letter. `app.js:365`
- **One weight confirmation stays on.** `current.force` stays true, so later saves skip both the variance and stock checks. `app.js:584`
- **Pacchetto default month is wrong.** On the 31st, `setMonth(-1)` rolls over to the current month. `pacchetto.html:49`

## Console and Configurazione

- **Saving one row wipes unsaved edits in other rows.** The whole list re-renders without checking the guard (parties, terms, standing orders, presets, recipes, machines and deadlines).
- **Preset step edits are invisible to the unsaved-change guard.** Salva is in the second `tr`, so the fields never turn orange, Enter doesn't save, and leaving gives no warning. `console.js:615-643`, `ui.js:28`
- **Sell-down and "Scorte in scadenza" are off by one day.** They use `b.date`, which is yesterday's brief date. `console.js:28, 127`
- **The only titolare can demote himself** to Socio, which locks out user management. `admin.js:343`
- **`1.300` in Parametri saves as 1.3.** The Italian thousands separator is parsed as a decimal. `admin.js:71, 93`
- **Invalid numbers save as NULL**, and in the standing-orders grid as 0, which turns that day's order off. `ui.js:18`, `console.js:548`
- **Fast ◀ clicks on the rota can write over the wrong week.** `console.js:350`
- **`#bots` / `#account` links on admin.html don't switch tab**; there is no `hashchange` handler. `ui.js:126`
- **The yield chart drops to 0 %** on days with open batches. `console.js:733`
- **A recipe instruction can't be cleared**, because of `coalesce(p_instruction, …)`. `console.js:681`
- **Recipes show the old dose after a save just after midnight**, because `v_recipe_editor` uses UTC `current_date`.
- **Weekday labels show "lunì", "marì"**: `\w` doesn't match accented letters. `console.js:459`
- **WhatsApp links for local numbers have no `39`**, so they open French numbers. `console.js:431`
- **The "Nessuna vendita POS ieri" line never appears**, because `pos_close` is NULL rather than `{missing:true}`. `console.js:43`
- **Cancelling "Disattiva" still clears the unsaved mark.** `admin.js:342`
- **Month settings typed as "11/2026"** (Firefox/Safari) save as "11/2026-01" and break `sales_plan_start()`.
- **The audit log and last-sync time show browser time**, not Rome time. `admin.js:406`, `console.js:475`

## HACCP, marketing and sales

- **Pest-control visit fails for HACCP level-2 users.** `complete_deadline` updates 0 rows under RLS, raises "Scadenza non trovata", and the visit rolls back. `…130100:509`
- **Releasing a lot or closing a non-conformity is restricted only in the UI.** Any Produzione user can do both through the API, and `p_staff_id` can be spoofed. `…130100:235`
- **Editing an approved post keeps it approved**, even when the new text now fails the claims check (e.g. "Cilento DOP"). `marketing.js:195`
- **New leads always start as "nuovo".** `sales_add_lead` ignores `stage`. `v044_sales_module.sql:252`
- **WhatsApp prefix regex.** Mobiles starting 390–393 get no `39`, and `0039…` becomes `390039…`. `vendite.js:77, 131`
- **"Preordini domani" double-counts multi-product orders.** `mkt_weekly_status`
- **The calendar window uses UTC midnight.** `marketing.js:125`
- **Draft media can be duplicated** when "Recupera bozze" runs and the webhook also arrives. `mkt_ai_complete`

## Edge functions and database security

- **`predis`: any staff member can generate content and spend credits.** It only checks that a staff row exists, then uses the service-role key. `predis/index.ts:28`
- **`predis`: a network error leaves the post stuck in "generating"** forever. There is no try/catch around the fetch. `predis/index.ts:58`
- **`backup-export`: full DB dumps go to the `documents` bucket**, which HACCP users also upload to. On live, every profile can read and overwrite `backups/` (see L1). `backup-export/index.ts:14, 73`
- **`backup-export`: pagination has no ORDER BY**, so rows can be missed or duplicated on large tables. `:50`
- **`invite-user`: emails are matched with `ilike`**, so `_` and `%` act as wildcards and the wrong staff row can be overwritten. `:174`
- **The `documents` bucket policy exposes the backups** to every signed-in user. See L1.

## Checked and fine

- All JS and inline scripts parse.
- Every element id in the JS exists in its HTML.
- Every table, view and RPC the front end calls exists, apart from `v_demand_7d`, and the RPC parameter names match the latest signatures.
- All 59 views run without error for titolare, produzione and marketing on 30 days of simulated data.
- RLS: the role policies are RESTRICTIVE, so the old `*_authenticated_all` policies don't weaken them.
- Anon can only execute `company_name()`.
- The CCP limit comparisons are correct.
- The CORS, webhook-secret and Vault-token checks in the edge functions are correct.
