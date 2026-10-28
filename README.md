# caseificio-ops — La Perla del Cilento

Operations system for the Agropoli micro-dairy (ex Latteria Fabula).

- `supabase/migrations/` — database schema. File names are `<14-digit version>_<name>.sql` and match
  `supabase_migrations.schema_migrations` on the live project (history repaired in v0.39 and again in v0.59: 76 files =
  76 live versions), so `supabase db push` / `supabase migration list` work. v0.59 also checked that the repo rebuilds the
  live schema: all migrations replayed on a clean Postgres give the same functions, views, tables, constraints, indexes,
  RLS policies, triggers, enums, pg_cron jobs and storage buckets as live (26 function bodies differ only in comments).
  Never run SQL on live outside a migration file (that is how v044/v044b, bot_messages and demand_7d went missing).
  New changes: always as a new migration file
  (or via the Supabase MCP `apply_migration`, then save the same SQL here with the version it got).
- `fabula-tablet/` — floor PWA, console, HACCP and marketing pages (see its README). Libraries are vendored in
  `fabula-tablet/vendor/` so the tablet starts without internet.
- `sop/` — printable floor procedure sheet, the «Sistema giù: cosa fare» card for partners (v0.96; both updated for v0.97, the daily sheet again for v0.98: commas, impossible yield, and for v0.99: the lot label at the start), and «Bot fermi: cosa fare» (v1.00; rev. 2 in v1.02: the Shopify syncs run in the database).
- `tools/legacy-patches/` — one-off scripts used to patch the app in v0.25–v0.29 (kept for history, not needed).

Releases (v1.08): merging into `main` is the release, after one approval on GitHub — see `RELEASING.md`. The app is published from
`fabula-tablet/` on GitHub Pages (app.bubalina.it); the database and the server functions by the same workflow.

## The database no longer reads GitHub: GitHub reports what main holds (v1.18)
Audit S-1, step 2 of 4 towards a private repo (`claude/s1-pre-change-review-2026-10-28.md`). The hourly infra probe read three public
GitHub URLs without a token (the migration tree, `fabula-tablet/sw.js`, the commit feed) for «Ultimo codice su GitHub», «Migrazioni del
repo uguali al database» and «App del tablet pubblicata»; on a private repo all three answer 404. Migration `v118a`, database only, plus
the two workflows and `release.py`:
- **`release.py github --ref R --source release|watcher`** reads the commit, its date and title, the migration versions the pipeline
  replays (`migrations_at`) and the app version from its own checkout and sends them through `public.fabula_outside_report`, kind
  «github», with the backup token the watcher and the «blocked» step already use. It never fails a job: a report that does not arrive
  only ages the checks (after 26 h they say «GitHub non letto»).
- **Who reports:** the release workflow at every push to main (plan job, `origin/main`, also for «Nothing to deploy») and again at the
  end of an apply; the outside watcher at every run (main only). After a release both lists agree at once, so the code checks no
  longer stay red until the next hourly probe (the false «fuori dal rilascio automatico» of 21–22/10).
- **`fabula.github_report(detail)`** (INVOKER, only through the report function) checks the report (40-hex commit, a real date not in
  the future, at most 5,000 14-digit versions; the title cut at 200) and writes the same `infra_status` rows and data the probe wrote
  (`github_tree`, `github_head`, `github_sw`), with no pending request, so `infra_checks()`, the board, the drift notice and
  `live_app_version()` are unchanged. A missing or odd app version marks `github_sw` red and keeps the last good one. A refused report
  changes nothing. «github» reports are handled before the 8,000-character cut that would drop the version list.
- **`fabula.infra_probe()`** asks only the tablet site and the two server functions; `infra_collect()` is unchanged (its GitHub branches
  are no longer reached).
- **Tests:** `test_v118_github_report.sql` (48 checks: grants, the probe, the token, a good report and the board, drift both ways, 26 h
  without a report, every refused report, the app version, a late answer to an old request, the other report kinds);
  `test_infra.sql` now gets its GitHub facts from a report (a refused report keeps the list, instead of a rate limit);
  `test_release.py` + 10 checks for `release.py github`, including the real database function accepting what it sends.
- **Rollback:** `tools/go-live/rollback/20261028200000_v118a_down.sql` puts back both definitions exactly as captured on 28/10 and drops
  `github_report` (proven to restore main's schema line for line). The probe then reads GitHub again, which works only while the repo
  is public. Copy it into `supabase/migrations/` under a later version and release it like any other version.
- Next steps (S-1): the release applies only when Nick starts it by hand (private repos lose the «live» required reviewer), then the
  repo goes private on GitHub Pro.

## The legal registers check what a login writes itself (v1.17)
Audit D-1 (`claude/production-readiness-audit-2026-10-22.md`). A login with level 2 in an area could INSERT straight into `haccp_log`,
`production_batches`, `stock_moves`, `lab_samples` and `milk_intake` — reproduced as produzione: a CCP-PAST of 60 °C saved «ok», signed by the titolare,
30 days back, source «sensor», with no NC and no hold; a lot with source «test» closed without CCPs and not held; +1000 kg of finished
goods by a stock adjustment. Migration `v117a`, database only: one guard, `fabula.trg_login_record_guard()` (SECURITY INVOKER), BEFORE
each row a login writes itself (`current_user` authenticated/anon, as `trg_record_lock`). The database's own functions (`log_ccp`,
`log_milk_check`, `record_lab_result`, `pack_order`, `post_stock_count`, `receive_purchase_order`, `correct_record`, …), cron, the bots,
their stand-ins and the service role are not touched. What a login can write is what the tablet and the login-run functions write today:
- **`haccp_log`:** only non-critical points (end-of-shift cleaning, pest round); a CCP reading goes through `log_ccp`, which computes the
  result and places the hold. The result is recomputed from the limits when there is a value; the time is within the last 7 days (an
  offline save keeps its time); no «sensor», «simulation» or «test»; `entered_by_id` is the login's own staff id.
- **`production_batches`:** a lot is started, never inserted already closed (the close is what runs the CCP check and the hold); no
  «sensor», «simulation» or «test» source, and the source of a lot does not change; `entered_by_id` is the login and stays.
- **`stock_moves`:** consumption into a lot (raw milk, consumables, packaging, out of stock), sales (out of stock), the production output
  of a closed lot (its product and lot, up to the kg recorded at the close), and the consumable/packaging correction of a lot. Anything
  else, or the wrong sign, is refused: stock is corrected with the count or by the system.
- **`lab_samples`:** a sample is created «in attesa»; the result comes only from `record_lab_result`.
- **`milk_intake`** (same gap, added with Nick's approval): no «sensor», «simulation» or «test»; the delivery's date and time within the
  last 7 days and not in the future for every source (before, only «paper» was bounded). A live «tablet» entry may be up to 15 minutes
  ahead and any other source 5 (paper as before): the 15 minutes are a device-clock tolerance only, because a live delivery carries the
  tablet's own clock — not a rule for dating deliveries. The longer-term fix is server time / clock-skew validation (audit R-11),
  not trusting the tablet clock; it is not part of v1.17. The temperature is required, so the CCP 1a
  acceptance rule always runs; who received it is a person on the tablet's list (`floor_operators`) under that person's own name, or
  «firma non leggibile» on a paper copy; `entered_by_id` is the login. The shared floor tablet (received by the operator on duty,
  saved by the tablet's login) works as before.
- **Delayed entries and corrections** keep their controlled routes, untouched: the paper copy up to 7 days back (`log_ccp`,
  `log_milk_check`, the milk and lot paper forms) and `correct_record` (a reason, the original kept; after 15 minutes only the HACCP or
  production manager; no timestamp is ever rewritten). Nothing older than 7 days can be entered by anyone, as before.
- **Tests:** `test_v117_legal_records.sql` (77 checks: the audit's forged writes, both lot-lifecycle bypasses with «test» and
  «simulation», every movement type outside the allowlist, what the tablet and the login-run functions still write, an 11-login role
  matrix, the owner and service role untouched, a refused step leaving the whole save unwritten, the milk intake, the delayed-entry and
  correction routes, the device-clock tolerance and the 7-day window); the tablet browser suites on a fresh replay.
  `test_audit_critical.sql` (approved by Nick): the five FARM-02/R4 deliveries are timed «now − 40/40/30/20/10 minutes» instead of
  07:00–07:30 today (same order and spacing, no assertion changed), so they no longer fail when CI runs before 07:30 Rome.
- **Rollback:** `tools/go-live/rollback/20261022220000_v117a_down.sql` drops the five triggers and the function (v1.17a adds objects
  only). Copy it into `supabase/migrations/` under a later version and release it like any other version.
- Left as they were: who performed a reading on `haccp_log`/`production_batches` (`operator`, `casaro`: D-3); a milk delivery saved
  without its two CCP 1 checks in the same save is not refused, and batch start refuses only milk already marked rejected (a check
  across rows: separate P1 follow-up after D-1).

## Approval requests come only from the system (v1.16)
Audit D-2 (`claude/production-readiness-audit-2026-10-22.md`). Any login with level 2 in an area could INSERT straight into
`fabula.approvals`, and the auto-approval trigger trusted the row: a request pointing at a **rejected** milk plan got a timer, approved
itself, and `sync_po_from_approval` moved the plan back to «approved» for the farm; a 100 % promo with no end was listed for the
sell-down bot to turn into a Shopify code. Migration `v116a`, database only (no app or function change):
- **Logins lose INSERT on `approvals`.** Every real request is created by the database's own functions and triggers, run by the bots,
  cron, the stand-ins and «Esegui ora», «Ordina di nuovo», manual orders, lab results and the marketing steps; no page and no edge function
  inserts one. SELECT, DELETE, the five policies, deciding, «Annulla», auto-approval and expiry are unchanged. The five proposal functions
  (`plan_milk`, `propose_purchase_orders`, `recipe_tuning_proposals`, `sell_down_signals`, `consorzio_declaration`) keep their EXECUTE
  grant: called by a login they stop at the insert and roll back. `mkt_local_before` stays SECURITY INVOKER on purpose.
- **`sync_po_from_approval`** never moves a rejected milk plan to approved; «Annulla» on a rejection (back to pending / proposed) still works.
- **`sell_down_codes_needed`** lists only the sell-down bot's own promos (`requested_by = 'agent:sell_down'`) with a discount above 0 and
  at most `sell.promo_pct`, and a real end within 48 hours; a non-numeric discount is skipped instead of breaking the list.
- **Tests:** `test_v116_approvals_insert.sql` (46 checks: grants, direct inserts per role, the five functions as a login, rejected plans,
  sell-down codes, and what must keep working); the two D-33 checks in `test_v104_db_guards.sql` now expect the refusal.
- **Rollback:** `tools/go-live/rollback/20261022180000_v116a_down.sql` puts back the grant and both definitions exactly as captured live
  on 22/10. Copy it into `supabase/migrations/` under a later version and release it like any other version.
- Left as they were (recorded in the audit): `auto_approve_rule` does not look at the plan's status or the requester (no longer reachable
  by a login); logins keep Supabase's default TRUNCATE privilege on the table (not reachable through the Data API).

## «Annulla DDT» (v1.15)
Backlog from v1.04 (Fulfilment on the go-live board): a wrongly packed order was a dead end. A numbered DDT can't be deleted or changed
from a login (the yearly series must stay gap-free), and nothing undid the packing. Migration `v115a`, app `perla-v81`.
- **`cancel_shipment(id, reason)`** (Spedizioni = gestisce: titolare, socio, spedizioni; reason of 5+ characters) annuls a DDT **packed
  today** whose goods have not left: status `cancelled` (new value), with `cancelled_at`, `cancelled_by_id`, `cancel_reason`. The number
  stays in the series as «annullato». Ingrosso and direct DDTs have no «partito» step, so «today» is what stops a DDT delivered days ago
  from being annulled into stock that no longer exists; «today» is the day of the DDT's own stock moves, which a login can't change. In
  transit, delivered or fulfilled on Shopify are refused too (a return), and so is a DDT with lines but no linked stock move.
- **What comes back is what the DDT took:** its own `sale` moves (`stock_moves.shipment_id`, set by `pack_order`; for the tablet's direct
  shipment by the trigger `stock_moves_a_ship_link`, which links a move to the line of a DDT written in the same save; the lot guard
  carries the link into the rows it splits off), reversed with the same date and source `ddt_annullato`, so the day's sales net out.
  Not the DDT's lines.
- **The order:** a wholesale order goes back to `confirmed`, so it is in «Da spedire» again (an online order stayed `confirmed`); the lot
  the packing wrote on the order lines is cleared. «Stock already booked for this order» is now the net of its sale moves
  (`v_shopify_inventory_push`, `v_shopify_orders_recent`, `upsert_shopify_orders`): an annulled online order is reserved again and is
  deducted if Shopify then reports it fulfilled.
- **Guards for logins:** no annulment by hand (insert or update), no change to an annulled DDT; packing time, Shopify fulfilment and
  status never move back; a DDT's lines are written only with the DDT itself (same save) and never changed or deleted afterwards
  (`shipment_lines_guard`). The delete refusal points to «Annulla DDT». The tablet never sends a DDT step by step.
- **An annulled DDT is not a shipment:** `v_lot_distribution` (recalls), `recall_drill` (net sales of a lot), the go-live «Primo ordine
  vero preparato», the trial's day 3, `cancel_placeholder_orders`, and the evening check's «sold on a held lot» (positive moves are not
  sales). `v_shipment_doc` gives who annulled, when and why. If the Shopify sync fulfils an order just as its DDT is annulled,
  `mark_shopify_fulfilled` keeps the DDT annulled and posts an alert to cancel the fulfilment on Shopify.
- **Where:** Console → Operazioni → **Spedizioni e DDT · 30 giorni** (the register, annulled DDTs included; «Annulla DDT» on today's DDTs),
  and the DDT page (`spedizione.html`): «Annulla questo DDT» for who manages shipments, on a DDT packed today; an annulled DDT shows
  ANNULLATO (banner, red badge, watermark on every printed page). The tablet's «🖨 Stampa DDT» after packing opens that page.
- One `audit_log` row per annulment («Registro modifiche» → Spedizioni (DDT)). The new enum value is used only as text inside the
  migration: the release is one transaction, and a new enum value can't be used before it commits.
- **Known limit:** a direct shipment saved offline gets its stock move when the tablet sends it (save_ops does not backdate table rows),
  so one saved offline late in the evening and sent the next morning can still be annulled that morning.
- **Tests:** `prod-test/test_v115_cancel_ddt.sql` 40/40; browser `tablet-test/v115_e2e.py` 16/16. Two independent reviews (2 High,
  2 Medium and the Lows fixed before release).

## Only the floor tablet counts; every device has a name (v1.14)
Re-audit of 19/10, item R-04 (and audit A-35). The go-live check «Tablet di produzione aggiornato» ticked for any device on the latest
app: a socio's iPhone turned it green on 19/10. Every device was «tablet-1», so nobody could tell the floor tablet from a phone.
Migration `v114a`, app `perla-v80`.
- **`devices.floor`, `named_at`, `named_by`.** Configurazione → Utenti e accessi → **Dispositivi** (`device_list()`, Sistema ≥ vede)
  lists every device: name, what it is (from the browser; an iPad on Safari reads «Mac o iPad»), who used it last, app (aggiornata /
  vecchia), records waiting, and a code. The titolare or a socio (Sistema = gestisce, `set_device()`) names it and ticks «Tablet del
  caseificio». Names are unique (also a unique index) and 2–40 characters; each change goes to «Registro modifiche» (Dispositivi).
- **The code** (first 4 characters of the device id) is also on the tablet's Home, at the bottom: «Tablet «…» · codice …». An app
  installed on the home screen keeps its own storage, so the code is how the tablet is found in the list.
- **A named device keeps its name.** `device_checkin` no longer overwrites it with the tablet's `?device=` label and returns it; the
  tablet adopts it. Messages, refused saves and their alarm call a device by that name; an unnamed one by what it is and who used it
  («iPhone di Nick»): a label the tablet sends itself is never trusted as a name.
- **Only floor tablets count** for `ops_dashboard()` «tablet_checkin» (seen within 2 days, latest app) and the trial's «Giorno 1 ·
  tablet di produzione collegato»; the detail names the tablet or says how to mark one (or that the app in line is unknown when the
  site check is down). `device_watch` warns about an old app only on floor tablets, and reports a floor tablet that has not checked in
  for 2 days (every 3 days; e.g. its storage was cleared and it came back as a new device); records waiting too long are still warned
  on every device.
- **«Latest app» = that version or newer** (`_app_ver_num`): the hourly site check can lag a release by up to an hour. The tablet's
  «Aggiorna» banner now shows only when the app in line is newer than its own (before, an up-to-date tablet was told to update
  during that hour).
- **Tests:** `prod-test/test_v114_floor_tablet.sql` 32/32; `infra-test/test_devices_watchdog.sql` marks its tablet as floor;
  browser `tablet-test/v114_e2e.py` 16/16 (check-in, the card on a phone, naming, the tablet adopting the name, the banner).

## The number check without false alarms (v1.13)
Re-audit of 19/10, item R-03. «Perché?» (v1.06) compares each number and date a bot writes with the data it read. In its first week it
flagged 2 messages, both wrongly: Controllo sistema 19/10 («nomi provvisori: invariati dal 16/10» outside brackets, «(erano 3 il
17/10)») and Manutenzioni e scadenze 20/10 («4 tarature, 11 manutenzioni, 6 attestati», counted by the bot: the data had only the total).
Migration `v113a`.
- **`_basis_tokens`** (message side only) also leaves out «invariat[oaie] dal/dall'/da/al dd/mm» anywhere, «(era|erano …)» in brackets and
  «era/erano N il dd/mm»: rule 5 (REPEATS) notes about the previous message, whose numbers were checked then. A date or number next to
  them is still checked; «erano» without a date is data.
- **`compliance_calendar()`** returns `counts.by_kind` (bucket → kind → n), so the breakdown is in the data.
- The flagged messages of the last 7 days are checked again with the new rule (a message whose data lacks a number stays flagged).
- **Tests:** `prod-test/test_v113_number_check.sql` 14/14 (on the v1.12 code 8 fail).

## The database stands in for every bot (v1.12)
Re-audit of 19/10, item R-02 (project doc `claude/golive-rescore-2026-10-19.md`). From 15/10 about 18:30 to 17/10 morning no Claude bot
started (Nick's Claude usage ran out during a build session): the database stood in for 6 bots, but the morning brief, sales,
marketing, the compliance calendar and the monthly review had none, so 16/10 had no brief and no Friday sales run. Migration `v112a`.
- **`bot_fallback_agents()`** lists every Claude bot. `bot_fallback` (every 5 minutes) writes a missed bot's message ~45 minutes after
  its time, «Esegui ora (versione del database)» works for all of them, and the watchdog waits its 20 extra minutes for them too.
- **`bot_fallback_run`**, five new branches, each from the same data function the bot reads, with the bot's Italian shape (title,
  «Da fare», «In breve») and without its comment:
  - `daily_brief`: `daily_brief(yesterday)`; on Monday Saturday plus `weekly_brief()` («La settimana»). Read-only.
  - `sales`: `sales_status()`: the contacts due (first 6), the plan, the pipeline, stale venues, customers to win back. Read-only:
    the ready messages and the search for new venues stay with the bot.
  - `marketing`: the bot's one write (quotes in hand → `in_approvazione`, a trigger makes the console approvals), then
    `mkt_local_status()` + `mkt_weekly_status()`. The quote requests to suppliers stay with the bot.
  - `compliance_calendar`: `compliance_calendar()` with its ready messages for technicians and the lab. Read-only.
  - `monthly_review`: `monthly_review()`, which records the recall drill and the recipe proposals, as the bot's own call does.
  Every read is kept for «Perché?» (by the database: not number-checked). New variables are `v_`-prefixed (the older branches alias
  columns `k`, `m`, `v`).
- **The marketing slot** (Monday and Thursday 07:53) was on live but in no migration: `v112a` adds it where missing.
- **App** (sw `perla-v79`): Configurazione → Bot says what «Esegui ora» does for the five; «Bot fermi: cosa fare» (in the app and
  SOP-14 rev. 3, `sop/bot_fermi.html/.pdf`) says every bot has a stand-in and only the bot's comment and ready texts wait.
- **Review (independent agent, 1 High, 5 Medium, small ones), fixed before release:** the brief offered expired and held lots at the
  counter (now: expired ones «⚠ da ritirare», held ones never; still-open NCs count too); the monthly review printed held lots as JSON
  and called a month with CCP gaps «chiuso» (info); «Esegui ora» on the monthly review mid-month re-ran it without asking
  (`run_bot_fallback` now looks back to the month's slot); marketing said «Niente da fare» with a decision waiting; sales counted at
  most 15 contacts and listed closed stages as open. Also: units and Italian numbers in the NC line, approval ages from today,
  «e un'altra», «scadenza 11/10», «Apertura oggi / Aperto dal», B&B, product names in recipe lines, «SIMULAZIONE ·» titles.
  Left as they are: a late Claude bot after a monthly stand-in records a second recall drill; «Esegui ora» (Sistema 2) can move
  quotes to approval and create recipe approvals without marketing or HACCP rights (they still need approving).
- **Tests:** `prod-test/test_v112_standins.sql` 38/38 (timing on fixed days, «Esegui ora», each stand-in on the real data functions
  and on full data, the review's cases). Updated: `test_bot_fallback.sql` (Tuesday 08:10 now also runs the brief and the calendar) and
  `test_audit_alerts.sql` (the brief's alarm says «Esegui ora»; an unknown bot is still refused).

## No Consorzio declaration before the DOP control (v1.11)
Re-audit of 19/10, item R-01 (project doc `claude/golive-rescore-2026-10-19.md`). On 05/10 `consorzio_declaration()` proposed
«Dichiarazione Consorzio 09/2026: 0 kg» for a dairy that is not ours yet; it stayed in «Da decidere» in every morning summary until it
was rejected on 20/10, and the 1st-of-the-month job would have made a 0 kg October one on 01/11. Migration `v111a`.
- **Setting `dop.rina_code`** (Configurazione → Sicurezza alimentare e DOP): the caseificio's RINA operator code for the DOP control,
  empty until RINA's initial inspection. Not a protected setting.
- **`consorzio_declaration(month)`:** with the code empty and no DOP lot in the month it proposes nothing and returns the month's
  figures with `skipped: true` and `skip_it` (why, in Italian). With the code set, every month is proposed as before, 0 kg included.
  DOP lots in a month without the code (the trial week) are proposed with one more check to see, `codice_rina`. The payload carries
  `rina_code`. The pg_cron job, the approval, «Segna inviata» and the T-DOP task are unchanged.
- **Tests:** `prod-test/test_v111_dop_declaration.sql` 14/14 (on the v1.10a code 8 fail: the cron call makes the 0 kg approval).

## Sicurezza e salvataggi: the fixes of the quality test of 20/10 (v1.10)
A full test of v1.09 (project doc `claude/quality-test-2026-10-20.md`: every suite green, live = repo) and three independent reviews
found no Critical issue but two ways for a socio profile to become Titolare, a tablet save path that could write a HACCP record twice,
and smaller issues. Migrations `v110a` (security, people) and `v110b` (saves, wholesale, farm, Telegram); project doc
`claude/audit-fixes-v110-2026-10-20.md`.
- **Item 1 · protected settings:** `fabula.setting_protected(key)` = `infra.*`, `auth.*`, every `*_url` except `mkt.*`,
  `notify.telegram_bot`. Trigger `settings_guard` refuses a write of those straight through the API (role authenticated/anon) by
  anyone who does not manage users; the database's own functions (they run as their owner) are not checked. A socio could point
  `infra.site_url` at another site (the next access link carried a password token there) or `trade.edge_url` / `shopify.sync_url`
  at a host that would receive the job keys. Configurazione shows them as text to whoever is not titolare. `invite-user` builds
  access links only on app.bubalina.it (or `SITE_URL` / `SITE_HOSTS`), whatever the setting says.
- **Item 2:** `staff_insert_guard` (not security definer, so it sees who writes): a staff row added through the API by someone who
  does not manage users has no login, no e-mail (a sign-up with it would have been claimed by `claim_staff_profile`) and no profile
  that manages users. **Telegram:** someone else's chat that already works is replaced only by who manages users.
- **Item 3 · one record per check:** the tablet's `rpcNow` goes through `save()`, so the first attempt already carries the save id:
  a reply lost after the database wrote a CCP reading, milk check, valve check, calibration, pest round or lab sample no longer
  writes it twice (the re-send gets the first answer from `save_ops`). `record_calibration_check`, `record_pest_inspection`,
  `record_sample_taken` (and the badge scans) are in `ONCE_RPCS` and the `save_ops` list. `flush()` is taken before its first wait.
  **Item 12:** with the tablet's storage full an offline save says «Memoria del tablet piena … NON è salvata» instead of «Salvato
  offline». **Item 11:** product and preset names are escaped on the tablet.
- **Item 4:** one reader of Italian numbers for every page (`PERM.parseIt`; `UI.parseIt` uses it): Autocontrollo → «Correggi» read
  «1.050» kg as 1,05 kg and moved the milk stock; Marketing's settings too.
- **Wholesale (items 5–7):** `trade_approve` matches an existing customer by e-mail only and never overwrites name, P.IVA, SDI, PEC,
  phone or address: blanks are filled and the differences are listed (Console → Ingrosso and the request's note); the Shopify id
  of the public form is not taken. The Shopify order queue is claimed by one run (`trade_queue_claim`, 10 minutes) and each draft
  carries the tag `fq-<queue id>`: a run that finds it completes it or reports the order it became (`trade-portal/queue.ts`).
  A customer's new plan cannot change a delivery already confirmed; delivery windows only from `trade.windows`.
- **People (items 8–10):** a badge scan sent late (queued on a tablet) keeps its time up to `labor.max_shift_hours` + 12 hours, in and
  out alike (older: nothing changes and the office is told in the Bot feed, «Badge di … arrivato troppo tardi»). A late badge-out belongs to
  the shift that was running then: if the database closed that one by itself, its real end is written; otherwise nothing changes, and
  the open shift is never closed at a time before it started (it was closed at 0 h). The badge scans go through `save_ops`: sent at
  once they take the database's time, queued the measured time of the scan, so a tablet clock that is off no longer moves them.
  A shift open longer than the maximum hours (a forgotten badge-out) is not «in turno» on the tablet any more, so the next scan clocks
  in and closes the old one at the maximum; a badge-out on it closes it at the maximum too (it took the whole night). The tablet says
  «non risultavi in turno» when a badge-out closed nothing.
  The other open access links stop when the password is saved (`access_link_done`, called by `welcome`); «Cambia email» to the
  address already on the row moves a login left on the old one.
- **Smaller (items 13–16):** the farm's 8 loads a day count only loads that stand; the backup reads a one-column key page after page
  from the last key; «&» escaped in Telegram's «Se ne occupa»; webhook and job secrets compared in constant time; the PO and
  Consorzio prints show the Rome date; a marketing post link must be http(s); the release STOPs when the app changes without a new
  `sw.js` version; `welcome` says which characters a password needs; the welcome page opened with no link says where links come
  from. sw `perla-v77`.
- **Review (1 High, 2 Medium, 4 Low, all fixed):** the late badge-out could stretch an old automatic close to days (119 h) and still
  closed a split shift's afternoon at 0 h; `release.json` named v1.09; a paused plan was refused after the cut-off; the Shopify company
  of an existing customer came from the request; the Manuale link (`food.manuale_url`) stays editable; `access_link_done` is retried.
  **Second check (on the fixes), 2 Medium + small, all fixed:** a badge-in older than 12 h still became «now» and a badge-out older
  than 24 h closed today's shift (now one window for both, «troppo tardi» beyond it); a forgotten badge-out kept showing «in turno»
  the next morning; a day the customer skips no longer refuses a new plan; the approved card loses its buttons and an already approved
  customer's Shopify company also comes from the register. Left as is: an app still on perla-v76 between the database and the site
  release calls badge_out with its own clock (minutes); a pause/resume after the cut-off (trade_set_status) is unchanged.
- **Tests:** `prod-test/test_v110_security_saves.sql` 61/61; `tablet-test/v110_e2e.py` 13/13 (v1.10a: 63 and 14; the old app fails its lost-reply,
  storage and escaping checks); `supabase/functions/trade-portal/queue_test.ts` 4/4; `tools/release/test_release.py` 118.
  `v109_e2e.py` (C-19) reads the stored expiry instead of «now + 7 days» (it failed in the week before a change of time) and
  `test_shopify_sync_digest.sql` (E-33) checks a day ahead of the real one (it failed on 20/10 itself).
- Release order: database first, then the server functions (`welcome` calls `access_link_done`; `trade-portal` calls
  `trade_queue_claim`).
- **v1.10a (touch-ups, 20/10):** the welcome page says how long a new link lasts from the settings (`auth.link_hours` by e-mail,
  `auth.link_days` by WhatsApp, read through `welcome` `{action:"config"}`; nothing shown if it cannot read them) instead of a fixed
  «24 ore»; the duplicate index `bot_messages_open` (a copy of `bot_messages_unread`, Supabase advisor «Duplicate Index») is dropped
  (`v110c`). sw `perla-v78`. Tests: `test_v110_security_saves.sql` 63/63 (no two identical indexes in `fabula`), `v110_e2e.py` 14/14.

## Persone: access links for a week, one card per person, a real switch-off, the rota by taps (v1.09)
Staff onboarding, the next improvement after the release pipeline (re-score 15/10, «Staff & rota»; project doc
`claude/audit-fixes-v109-2026-10-19.md`). Emilio's two 24-hour invites lapsed unused; nobody had used the rota.
- **Personal access links** (migration `v109a`, server functions `welcome` (new, no login) and `invite-user`): Configurazione → Utenti e
  accessi makes `benvenuto.html#invito=<token>`, valid `auth.link_days` (7) days, until a newer one is made, used up only when the
  password is saved (a WhatsApp preview or a mail scanner cannot spend it). Only its sha256 is stored (`fabula.staff_access_links`,
  service role only). Nick sends it by WhatsApp or from his own mail app, with the message ready: no Supabase e-mail, so neither the 24 h
  limit nor the hourly e-mail limit applies. `welcome` creates the login the first time (or sets the password of the one already
  linked, or of one with that e-mail), then the page signs in, offers «Collega Telegram» and opens the profile's page.
  Supabase's own e-mails («Password dimenticata?») still work as before (24 h).
- **One card per person** (audit C-33): checklist Accesso · Telegram · PIN · Formazione, the profile and job role, the e-mail, and the
  action for what is missing («Link di accesso», «Link per nuova password», «Link Telegram», PIN, Badge, Disattiva/Riattiva).
  «Aggiungi una persona» with an e-mail shows the link at once; without one, the person uses the tablet with badge and PIN.
- **C-13**: «Cambia email» changes the login e-mail too (`update_email`); a plain edit of the e-mail of someone with a login is refused
  by `trg_staff_guard`. **C-15**: adding the e-mail of someone switched off says «usa Riattiva». **C-17**: the job role follows the
  profile; giving or removing Titolare asks first. **C-18**: `auth.link_hours` is 24 in the migrations too. **C-19**: the message and
  the welcome page use the company's name and the profile's page, not «La Perla» and the office Console.
- **C-14 switch-off**: «Disattiva» lists what will happen (`staff_offboard_preview`), then `staff_offboard` in one transaction closes the
  open shift, removes the future rota (today is kept), cancels links, Telegram and PIN, and lists the settings and open deadlines that
  still name the person; `invite-user` then blocks the login. Shifts open past `labor.max_shift_hours` close by themselves, at that
  length, 12 hours later (`close_stale_shifts`, job `fabula_close_stale_shifts` at :07: a badge-out queued offline is accepted up to
  12 hours late with its own time and must still find the shift open); the tablet's «In turno» lists active people only.
- **Review (one High fixed):** the link's login is chosen and bound to the person (`access_link_bind`, errcode P0409 for a login that
  belongs to someone else) BEFORE its password is written; `add`, `access_link` and `update_email` (and the old `invite`, `link`,
  `resend`, still there for app copies cached on devices) refuse an e-mail that is someone else's login. A second check confirmed the
  fixes (the takeover script now gets «conflict» and the password stays). A dead link tells only why; the link leaves the address bar at once; a failed save never reopens a replaced link; a
  blocked login is unblocked when the active person sets the password; the mentions use plain text matching.
- **Telegram links** for someone's phone last `auth.link_days` too (they lasted 24 h).
- **C-23** «Cambia password» (current, new, repeat) is in the user menu of every page that uses the shared shell; **C-20** «Esci» asks
  first when something is unsaved.
- **B-26 rota**: a cell is tapped, not typed: the shifts used in the last 8 weeks, start and end with time pickers, break, area,
  riposo/ferie/permesso/malattia, «Anche questi giorni»; an end before the start is a night shift only when ticked; changed cells are
  orange until «Salva settimana»; the week says «questa settimana» / «settimana prossima»; database errors in Italian. sw `perla-v76`.
- Release order: database first, then the server functions (they call the new database functions).
- Tests: `prod-test/test_v109_people.sql` 51/51; `tablet-test/v109_e2e.py` 43/43 (the real `invite-user` and `welcome` under Deno with
  a fake Supabase auth); `operator_e2e.py` follows the cards; `test_v106_perche.sql` no longer pins the number of database jobs.

## The app moves to https://app.bubalina.it (v1.08b)
Second automatic release (project doc `claude/audit-fixes-v108-2026-10-15.md`, «v1.08b»). Since v1.08 every release publishes
`fabula-tablet/` on GitHub Pages at app.bubalina.it; Netlify kept serving the same app at its old address.
- **Migration `v108b`:** `infra.site_url` = https://app.bubalina.it, so every link the database builds (Telegram «apri», the morning
  summary, the hourly site check) uses it, and the drift texts say «approva il rilascio su GitHub» (v1.08a made them follow the
  setting). The drift notice and the uptime alert no longer say Netlify. `ops_health` prompt version `2422561503` (its sentences for
  uptime and app_deployed name GitHub, not Netlify).
- **`fabula-tablet/config.js`** (loaded first by every page): on `*.netlify.app` a page goes to the same page on app.bubalina.it,
  path, ?query and #hash kept (the Masseria's QR and the trade links keep working), only when all of these hold:
  - app.bubalina.it answers with `perla-v75` or later in its `sw.js` (so nothing moves before the release is approved, or offline);
  - the page has just started (never in the middle of someone's work);
  - nothing is waiting on that device: `fabula_queue`, every refused save in `fabula_failed` (reported or not: they can only be
    redone or discarded there), photos in IndexedDB (3 s timeout: a database that does not answer counts as waiting).
  The tablet (`index.html`) left open shows a bar saying what is waiting, nudges the app's own sending, and turns on «Passa al nuovo
  indirizzo» when nothing is left; other pages with something waiting simply stay. Moving clears the old address's service worker
  and caches and carries `?device=` and `?device_uid=`; the new URL is built on app.bubalina.it and checked to stay there. On the new
  address the id is taken when none is there or nothing is waiting there, and removed from the address bar. Sign-ins are per address:
  everyone signs in once. sw `perla-v75`.
- **Netlify** (`netlify.toml`, both copies): builds only when `fabula-tablet/config.js` changes, so this release deploys the forwarding
  there once and later releases spend no Netlify credits.
- **`invite-user`** and **`tools/watch/check.sh`**: the fallback and the outside watcher's site are app.bubalina.it; the watcher also
  checks that the old address still forwards (`old_site`: its `config.js` names `FABULA_HOME`), until `OLD_SITE=` is emptied.
- **Before approving:** Supabase → Authentication → URL Configuration: Site URL `https://app.bubalina.it`, Redirect URLs
  `https://app.bubalina.it/**` (`RELEASING.md`; done 19/10). After: reprint the barn's QR poster from the new address.
- Tests: `prod-test/test_v108b_move.sql` 10/10; `tablet-test/v108b_e2e.py` 18/18; `infra-test/test_infra.sql` and `test_v108_release.sql`
  updated for the new address.

## Releases apply themselves after one approval (v1.08)
Project doc `claude/audit-fixes-v108-2026-10-15.md`; how to use it: `RELEASING.md`. Until v1.07 each release was a list of manual
steps for Nick (temporary Supabase token and CLI deploy from the Mac, SQL Editor paste, git merge and push, Netlify deploy at 15 of
the free plan's 300 monthly credits, the whole site paused at zero as on 14/10).
- **Workflow** `.github/workflows/release.yml`, after CI passes on `main` (pushes of this repo only). Job `plan` (no Supabase secret)
  reads the live commit from the database (`public.fabula_live_release()` with the publishable key; `tools/release/baseline.txt` =
  298e2f4, v1.07, before the first run), lists what changed since then and rehearses the database part on a scratch Postgres built at
  the live commit (`replay.sh` takes `MIGRATIONS_DIR`); nothing to deploy → nobody is asked; a STOP or a failed rehearsal → red and
  «bloccato prima dell'approvazione» in the Bot feed (through `fabula_outside_report`, kind `release`, with `BACKUP_EXPORT_TOKEN`).
  Job `apply` waits for the approval of the environment `live` (Nick, `main` only, secret `SUPABASE_ACCESS_TOKEN`), reads the live
  commit again through the Management API, installs Supabase CLI 2.118.0 from a sha256-checked download in a step with no secret, then
  `tools/release/release.py` deploys the changed server functions (`functions deploy --use-api`, `verify_jwt` from `config.toml`,
  checked on Supabase) and the new migrations, in `release.json`'s order; publishes `fabula-tablet/` on GitHub Pages (app.bubalina.it)
  and checks `sw.js`; records the result (`fabula.release_record`). An «ok» row is what makes the commit live: no git tag, nothing
  written to the repo. A result that cannot be recorded is reported as «esito non registrato».
- **The database step** keeps the SQL Editor scripts' rules: the live history is read first (a live version GitHub lacks stops the
  release); every new file goes in ONE transaction through the Management API with a guard that refuses a changed history or a second
  run; each file starts from the default `search_path` (as in CI, one session per file); a marker set after `begin` must still be set
  before the history rows (a temporary table holding the transaction's id), so a file that ends the transaction itself fails the
  release and its rehearsal; the plan refuses `begin`, `commit`, `end`, `abort`, `savepoint`, `vacuum`, `concurrently`, psql backslash
  commands and variables and the like before anyone is asked (comments, strings, E-strings, `$tag$` and `begin atomic` bodies are
  skipped). A lost answer (timeout, gateway 5xx, cut connection): the script is found in `pg_stat_activity` by its tag and waited for,
  then the history decides; unknown → «da verificare». The plan job also reads the live migration history, so the plan and its
  rehearsal match what apply will run (also after a release that stopped halfway).
- **`tools/release/release.json`** per version: `version`, `title_it`, `order` (functions/database), `after_it` (steps for people,
  in the message), `force` (parts to deploy without a git change, kept until a release that carries it goes live: v1.08 = the first
  Pages publish). `release.py editor-script --live-last <v>` still writes a SQL Editor script when the pipeline is not available.
- **Migration `v108a`:** `fabula.releases` (read: Sistema «vede»); `release_record(jsonb)` (database role only) writes the row and a
  message in the Bot feed «Rilasci» (agent `rilascio`, area sistema, opens Panoramica): «Rilascio v… fatto» (info; warn with «Da fare»
  for `after_it`, bot prompts to update, an app that still answers with the old version) or «Rilascio v… fermato al passo …» (alert →
  Telegram `infra`, with the error, what already changed and the run; the fix comes as a new release). `release_blocked(jsonb)`:
  «bloccato prima dell'approvazione», «fermato prima di cambiare qualcosa», «esito non registrato». `public.fabula_live_release()`
  (anon: the last ok release's commit, version and date only). Panoramica → Sistema «Rilasci automatici» (`infra_checks` key
  `release`). The drift texts follow the pipeline: a migration on GitHub but not live = a release waiting for the approval; an app not
  yet published = approve the release; a migration live but not on GitHub = applied outside the release, its file goes on main.
- **Function `invite-user`:** the invite and WhatsApp links use `infra.site_url` from the database (the same address as every other
  link), so moving the app is one setting (v1.08b).
- Tests: `prod-test/test_v108_release.sql` 42/42; `tools/release/test_release.py` (116 checks, in CI): plans on small git repos (also
  `_shared` and root files, `verify_jwt`, `force` across releases, superseded/diverged, removed or badly named migrations), the lint
  (14 ways to end the transaction, psql-only syntax, E-strings, `begin atomic`, no false STOP on the real migrations), the script on a scratch history (second run refused, an error leaves nothing, a changed history
  stops it, the marker, `search_path` per file), the rehearsal, deploy and record against a fake Management API and CLI (order,
  `--no-verify-jwt`, a failing function or migration, a live version GitHub lacks, a wrong or missing token, a superseded commit, a
  late or lost answer, a gateway 504 while the script runs, Supabase down afterwards, functions deployed before a stop), the live
  commit and history read both ways, the blocked and unrecorded reports, the site check. `test_v105_bots_ops.sql`
  and `infra-test/test_infra.sql` updated for the new texts.

## «Prima dell'avvio»: quiet bots before the dairy works (v1.07)
Found live on 15/10/2026 (project docs `claude/golive-rescore-2026-10-15.md`, `claude/audit-fixes-v107-2026-10-15.md`): every day the
milk plan proposed 1.200 kg for a dairy with no building (four Telegrams each: decision, reminder, expiry, reminder of the expiry), the
brief asked for HACCP records nobody could write, the evening check said the tablet was silent, and the stock check asked to stop selling
at zero stock against the 02/10 decision. Migrations `v107a` (quiet mode) and `v107b` (stock message, prompt version); live apply:
`tools/go-live/live-apply/2026-10-15_v107_sql-editor.sql` (built by `make_v107_script.py`); tablet sw `perla-v74` (one Console line).
- **Quiet = before the start AND nothing real:** `fabula.quiet_day(day)` (floor checks, briefs) and `fabula.quiet_milk_day(day)` (the
  automatic milk plan), both off with `prod.quiet_before_start` = No. Starts: `quiet_until()` = the first of `prod.tasks_from`,
  `trial.start`, `mkt.store_opening_date`; `milk_start(day)` = the trial week while it is ahead or running (`trial.days`), else the
  opening (cold-room tasks started early, or a trial week already over, do not bring back daily proposals). `_real_activity(day)`: a
  non-simulation lot in the last 14 days, milk in the last 7, or a lot of finished product still in stock (per lot). HACCP records
  alone do not count (on live the only ones, 13/10, are tablet tests).
- **Milk plan:** `plan_milk()` without a date returns `skipped = pre_opening` (`tasks_start`, `first_plan_day`, `message_it`) after the
  `plan_exists` check and creates nothing; with a date it plans as before. `bot_fallback_run` and `_why_plan_milk` say the same; the
  milk planning prompt handles it (version `581ad88a3f`). `milk_order_again` marks its plan `payload.manual`. The migration closes the
  automatic plans already waiting for a quiet day, without a message (expired «Prima dell'avvio»).
- **Evening check / briefs / evening list:** `ops_health_check` skips `tablet_silent` and `stock_count_*` on a quiet day;
  `daily_brief` empties the day's HACCP checks and overdue tasks and adds `pre_opening` (shown in the Console's «Conformità ieri» and in
  «Perché?»); `weekly_brief` zeroes each week's missing checks only when that week is quiet; `_haccp_evening_items` (v1.05) now stays
  quiet before the tasks start only when nothing real is going on (product in the cold room brings the evening checks back).
- **Telegram:** `expire_approvals` clears `escalate_at` on the expiry it enqueues (no «Nessuno se ne occupa» on an expiry, also after
  the opening). `notify_digest_text`: on Monday (the reader's day), while quiet, «Verso l'apertura» (`_digest_golive`: done / total,
  «si parte …», the next three items).
- **Shopify stock:** `shopify.sell_at_zero` (Sì): the message lists the tracked products that stop at zero instead of asking to turn off
  «Continua a vendere quando esaurito»; the setting is part of the message's fingerprint.

## «Perché?»: the data behind every bot message (v1.06)
Spec and notes: project docs `claude/perche-spec-v106-2026-10-15.md` and `claude/audit-fixes-v106-2026-10-15.md`. Migrations `v106a`
(where the data is kept, how it reaches the message, the number check) and `v106b` (the explanations in Italian, the prompts'
versions); live apply: `tools/go-live/live-apply/2026-10-15_v106_sql-editor.sql` (built by `make_v106_script.py`); tablet sw `perla-v73`.
- **Kept by the database, never copied by the bot:** each bot wraps its step-1 read, `select fabula.keep_basis('<agent>', '<function>',
  fabula.<function>())`; `keep_basis` stores what the function returned in `fabula.message_basis`, without phone numbers and e-mails
  (`_basis_strip`; RLS on, no access for logins; up to `bots.basis_max_kb` = 256 KB, else only «too big») and returns the same JSON. 9 prompts: milk_planning, procurement, sell_down,
  wholesale_orders, haccp_nudge, daily_brief (+ weekly_brief on Monday), monthly_review, ops_health (+ infra_checks),
  compliance_calendar. `tools/bots/sync_rules.py --check` (CI) fails when one of them calls its function without the wrapper.
- **Linked to the message:** `post_bot_message` gives the message the agent's unused reads since its previous message (at most 60
  minutes; `bot_messages.basis_at`), also when it rewrites the run's short «auto» message. When the database read (its stand-in, its
  own alarms) only its reads go, so a read left by a bot run that stopped is never shown as the database's. The database keeps its own:
  `bot_fallback_run` (the stand-in and «Esegui ora»; the evening check with the system checks), `auto_approve_due`, `trg_batch_ccp_check`
  (the points, the values, the limits), `milk_reject`, `prod_watch`.
- **The number check (E-19):** for a bot's own reads, `_basis_check` compares every number and date of the title and body (Italian
  «1.200», «20,5 %», the database's «1530.40», a written sign; not the EN line, the drafts, «(invariato …)», phone numbers, times,
  «alle 6», codes, lots, «cella frigo 1», list numbers, «4 settimane») with the data (also the numbers inside its texts, the digits of
  its codes and the length of its lists), rounded to the precision written. Stored in `bot_messages.basis_check`; Panoramica → Sistema
  «Numeri dei messaggi» (7 days; «da controllare» above one message in ten). In «Perché?» only for Sistema «gestisce» until
  `bots.number_check_all` = 1.
- **Written out:** `fabula.message_why(id)` (definer; Sistema, the feed's readers, or for an alarm or a Telegram decision the
  message's area, never «comune» — the briefs carry sales, costs and people): one explainer per function
  (`_why_plan_milk`, `_why_purchase`, `_why_sell_down`, `_why_wholesale`, `_why_evening`, `_why_daily_brief`, `_why_weekly_brief`,
  `_why_ops_health`, `_why_infra`, `_why_compliance`, `_why_monthly`, `_why_auto_approve`, `_why_batch_ccp`, `_why_milk_reject`,
  `_why_prod_watch`), any other read through `fabula.basis_labels` (a key without a label is not shown). Values only from the data,
  never a phone or an e-mail; «Dati grezzi» for Sistema «gestisce». What the database adds for the explanation (the orders' approvals,
  the promo's full price) is `message_basis.extra`, never seen by the bot nor used by the check.
- **Pages:** `UI.why` (ui.js, ui.css): the «Perché?» button in Configurazione → Bot and Console → Oggi «Avvisi aperti»
  (`v_bot_feed.has_basis`, `my_alarms()` has_basis); `console.html#oggi&perche=<id>` opens it as a sheet, and Telegram carries that
  link («perché» next to «apri»; one text for every recipient, the Console then says who may open it).
- **Clean-up:** `fabula.basis_trim()` nightly (`fabula_basis_trim`, 03:20 UTC; 24 expected jobs): unused reads after a day, the others
  after `bots.basis_keep_days` (90).

## Bots, alerts and operations: rules, versions, evening list, go-live list (v1.05)
Medium and Low items of the 12/10/2026 audit, area E: E-06, E-09 (rest), E-14 (rest), E-16, E-17 (rest), E-19, E-27, E-28, E-31,
E-30, E-32 (project doc `claude/audit-fixes-v105-2026-10-15.md`). Migrations `v105a` (message rules, alarms by area, system checks),
`v105b` (placeholders, prompt versions, briefs, daily tasks), `v105c` (evening list, go-live list); live apply:
`tools/go-live/live-apply/2026-10-15_v105_sql-editor.sql` (built by `make_v105_script.py`); tablet sw `perla-v72`.
- **E-06 · one rule per database message:** `fabula.message_rules` (kind, messaggio/avviso, agent or notice key prefix, title regex,
  severity, Telegram topic, area, meaning in Italian). Triggers `bot_messages_rule` / `notices_rule` set the severity from the rule
  (null = the function decides); `notify_topic_for` takes the topic from it, the old words-based guess only without a rule. Milk
  accepted and not worked for 48 h is now an alarm for food safety.
- **E-09 · alarms by area:** `bot_nicknames.area`, `message_area()`, `fabula.my_alarms()` (open bot alarms of the caller's areas, all
  with Sistema); `v_active_notices.area` (from the rule); `bot_bell()` counts both for a profile without Sistema, whose bell
  «Avvisi» opens Console → Oggi; «Avvisi aperti» there lists the alarms and notices of its areas.
- **E-14 · Italian:** `infra_checks()` details in Italian (`_it_infra_detail`, `_infra_name`); notice items without a label get one
  (trigger `notices_items`); `fabula.system_checks()` feeds Configurazione → Panoramica → Sistema.
- **E-27 · drift:** the repo_sync / code_pushed detail says which way to fix it («git push» dal Mac, or the version's SQL Editor
  script), in the notice, its feed copy and the evening check. `fabula.schema_fingerprint()` + `tools/ci/compare_live.py` compare
  every live function and view with a fresh replay (code vs comments only). `confirm_standing_orders` on live lacked one inert line
  since v0.83: aligned.
- **E-28 · one-time set-ups:** `fabula.cron_jobs_expected` (23 jobs) and `cron_jobs_check()`, `vault_secret_check()`; the
  save-ledger trim job is created by the migration (`save_ledger_trim()`).
- **E-16 · placeholder names:** `fabula.placeholder_status()` (one next step each, Console → Anagrafiche, never Shopify), quoted by
  the evening check, `confirm_standing_orders` (→ the wholesale bot), the database's own wholesale run and the Shopify customer sync.
- **E-17 · prompt versions:** `tools/bots/sync_rules.py` stamps each prompt with a version (`--versions`, `--check`; CI compares them
  with `fabula.bot_prompt_versions`); bots pass it as `post_bot_message(…, p_prompt => …)` (`bot_messages.prompt_version`);
  `fabula.prompt_drift()` lists scheduled tasks running an older copy (evening check, Panoramica → Sistema). The retired Shopify
  prompts have no version. Prompts stay in the scheduled tasks (a prompt read from the database would be instructions from data).
- **E-19 · only the data:** MESSAGE-RULES rule 12 in every prompt; `daily_brief()->'changes'` and `weekly_brief()->'changes'`
  (`pct_change`), so the bot never computes; `sales_add_lead` marks a lead from the sales bot «Da verificare». Not done: a database
  role per bot (the connector has one role).
- **E-32 · tasks:** settings `prod.tasks_from` (empty = trial week, else opening date) and `prod.closed_weekdays` (default 7) +
  `trade_closures`: `generate_daily_tasks` creates nothing before the start, only the cold rooms on a closed day, and a weekly/monthly
  task on the first open day of its week/month. The nightly job `fabula_daily_tasks` is on again.
- **E-31 · evening list:** `fabula.haccp_open_list()` (today's list, yesterday's food-safety gaps as `PAPER:<cp>@<day>[@<lot>]`);
  the tablet shows it live from 14:00 («Prima di chiudere», red from 19:00), «Ieri non registrato» before 14:00, and asks at
  «Fine turno: esco» (the last one on shift: everything; otherwise the lots' CCP and milk tests). `_haccp_evening_items()` counts the
  Rome day; nothing before the tasks start (unless something was produced), only cold rooms on a closed day, badges from 19:00.
- **E-30 · go-live list:** `dash_checks.label_it/hint_it/done_by_id/done_at/sign_note`; `fabula.golive_checklist()` and
  Configurazione → Panoramica «Verso l'apertura»; `dash_set_check` from a login needs Sistema 3 and a note, records who and when
  (`sign_note`; Nick's board keeps `note`); trigger `dash_checks_guard` blocks direct writes from a login; `dash_checks_audit`.

## Database guard rails: paper copies, packing and DDT numbers, NCs, bank, tasks, permissions (v1.04)
Medium and Low items of the 12/10/2026 audit, area D: D-17 (rest), D-22 with PRINT-04, D-26 (rest), D-28, D-31, D-33 (project doc
`claude/audit-fixes-v104-2026-10-15.md`). Migrations `v104a` (paper, packing, DDT), `v104b` (NCs, arrival checks), `v104c` (bank,
tasks, permissions); live apply: `tools/go-live/live-apply/2026-10-15_v104_sql-editor.sql` (built by `make_v104_script.py`); tablet
sw `perla-v71`.
- **D-17 · paper copies:** `log_ccp` (paper) refuses a line already in the register (same control point, value and lot within 2
  minutes, from paper or tablet); `log_milk_check` the same per milk delivery. A lot's check must fall from 3 hours before the
  earliest of the lot's day, its start and its parent vat's start, to 6 hours after its close.
- **D-22 / PRINT-04 · packing and DDT:** `pack_order` compares each product with the order: more than `ship.max_variance_pct`
  (30 %) over is refused even confirmed (hint `weight`, a red card on the tablet), a product not in the order is refused, less or
  missing is asked (partial shipment); the order row is locked. DDT numbers: `fabula.next_ddt_number(date)` over
  `fabula.ddt_counters` (one gap-free series per year, `DDT-2026-0001`), given by trigger `shipments_ddt_number` to every shipment
  (packing sends none, the tablet's direct shipment sends none, anything a login sends and the old daily form are replaced; a login's
  shipment is dated today, Rome). From a login a DDT's number, date, customer and order cannot change and a shipment cannot be
  deleted (`shipments_ddt_guard`). `shipments.ship_date` defaults to the Rome date.
- **D-26 · NCs and arrival checks:** `nc_edit_guard`: an NC's origin never changes from a login, severity/description only at
  haccp 3, lot/batch/machine filled once below haccp 3, a closed NC frozen until reopened; `nc_insert_guard`: a login's NC is opened
  now and open. `record_receipt_check`: «NON conforme» is never re-checked «conforme» (the NC decides), `goods_receipts.inspected_at`
  and `inspection_nc_id`. While that NC is open the delivery's lots are isolated: `record_batch_consumable` refuses them
  (`_lot_quarantine()`), and asks for the lot when the ingredient has one isolated.
- **D-28 · bank:** `recon_set_bank` refuses a movement in the wrong direction (invoice, order, payout), an invoice or order already
  matched elsewhere or an invoice already paid, and adds «importi diversi (…)» after the note when the amounts differ by > € 0,50.
- **D-31 · tasks:** `close_open_task` closes a task tied to a control point only if a reading of it exists in the task's window (from
  3 hours before it is due, or that day for a once-a-day task); the cold-room display check no longer closes a task on the tablet.
- **D-33 · permissions:** `approvals_a0_insert_guard` (a login's request is «pending», auto-approval recomputed),
  `purchase_orders_status_guard` (from a login: created draft / awaiting approval, never moved to approved / sent / received),
  `purchase_order_lines_unit_price_check` (≥ 0).

## Secrets hidden, the Masseria's two links, lot labels from the database (v1.03)
The security and print High items of the 12/10/2026 audit: C-05, FARM-04, PRINT-08 (project doc `claude/audit-fixes-v103-2026-10-14.md`).
Migrations `v103a` (secrets), `v103b` (farm links), `v103c` (lot labels); live apply:
`tools/go-live/live-apply/2026-10-14_v103_sql-editor.sql` (built by `make_v103_script.py`); edge function `farm-order` updated;
tablet sw `perla-v70`.
- **C-05 · secrets:** `fabula.secret_setting(key)` names them (`milk.farm_token`, `milk.farm_ship_token`, `trade.job_secret`).
  Restrictive RLS on `settings` hides them from every login (not read, changed, added or deleted through the API; definer functions
  and the service role still read them); `_setting()` no longer returns them; trigger `settings_secret_format` accepts only 32-64
  hex characters and two different farm keys; `trg_audit` stores «••••» for their values (old Registro rows scrubbed);
  `trade.job_secret` replaced once. Wholesale portal keys: `parties.portal_token` is not readable through the API (table SELECT
  revoked from `authenticated`, every other column granted by name — **a new column on `parties` needs
  `grant select (col) on fabula.parties to authenticated`**, `test_v103_security_labels.sql` checks it) and only the database
  changes it (trigger `parties_portal_token_guard`; Ingrosso «Nuovo link» as before). `UI.upd` asks back only the columns it
  matched on (`select=*` would be refused). `agent_runs`: read-only for logins (bots run as the database role).
- **FARM-04 · two links:** the full link (owner of the Masseria: orders, 30 days, month, corrections, «Visto») and the QR in the
  barn (`milk.farm_ship_token`: record a shipment, today's loads, correct its own load within 2 hours). `fabula._farm_scope(token)`
  says which; `farm_milk_orders/ship/amend/seen` follow it. «Chi spedisce»: names in `milk.farm_people`, asked on the farm page and
  remembered on the phone, stored in `milk_shipments.recorded_by` with `source` farm_page / farm_qr; shown on the tablet's milk
  arrival and in the Console. `farm_links()` / `farm_link_rotate('full'|'qr')` (Sistema = gestisce) give the links and make new
  random keys; Configurazione → Utenti e accessi → «Link della Masseria» (open, copy, WhatsApp, poster, «Genera nuovo link/QR»,
  «Chi spedisce»); the Console card shows the links only to the same people, with the poster from the QR key. The full link
  refuses to become a poster. Old functions accept calls without `p_by` (older edge function).
- **PRINT-08 · lot labels:** tablet Home → «🖨 Ristampa etichette lotto» (`lot_labels()`: lots being worked, then the last 14
  days; a search goes back 60) → the lot → copies → «Prepara l'etichetta» (`lot_label_reprint()`: counted on the lot's label row,
  `labels.reprinted_count`, who and when; no row is created for a lot still being worked, its close creates it). `labels.html` checks
  every `LOT:` line with `lot_label_info()`: name and expiry/arrival from the database (a wrong one corrected); a lot that does not
  exist is red and not printed unless it is in the tablet's offline queue (amber); a close still in that queue prints as the tablet
  wrote it (amber); no network or login = «NON controllati». Lot lines from the tablet are read-only («Modifica a mano»).
- Tests: `prod-test/test_v103_security_labels.sql` 28/28; `tablet-test/v103_e2e.py` (browser, the real `farm-order` with Deno);
  four older suites updated (new farm function signatures, «Chi spedisce» remembered, the poster from the QR key).

## Shopify sync in the database, morning summary, quiet nights (v1.02)
The «Shopify sync and digest» items of the 12/10/2026 audit (project doc `claude/audit-fixes-v102-2026-10-14.md`). Migrations
`v102a` (Shopify sync) and `v102b` (summary and quiet nights); live apply: `tools/go-live/live-apply/2026-10-14_v102_sql-editor.sql`
(built by `make_v102_script.py`); new edge function `shopify-sync`; tablet sw `perla-v69`.
- **E-18 · Shopify without an LLM in between:** `supabase/functions/shopify-sync/` (index.ts, shopify.ts, sync.ts) copies orders
  (and confirms packed web shipments on Shopify with the tracking), customers and stock. The three Shopify «bots» are database
  jobs now (`bot_schedule.runner = 'db'`, same times: customers 06:05, orders 06:11, stock 07:32 and 13:32): pg_cron
  `fabula_shopify_sync` (every 5 minutes) runs `shopify_sync_tick()`, which calls the function at each slot with the key in
  `fabula.job_secrets` (service role only, never in a backup). A call that never started or failed is repeated once after 20
  minutes; a run cut short is marked failed; a call that never reached the function (not published, a login asked, no answer)
  becomes a failed run with the reason in plain words. The function logs its run (`shopify_sync_start` / `shopify_sync_finish`)
  and the database writes the message from the numbers (`shopify_sync_finish`): what changed, what to do, «(invariato)» when
  nothing changed, and no second alarm while the same one is still open. Configurazione → Bot → «Esegui ora» starts a sync now
  (`run_bot_fallback` → `shopify_sync_now`).
- **Guards:** the customer list must have as many customers as Shopify's own count, or nothing changes; one run never deactivates
  more than `shopify.max_deactivate_pct` % (5) of the Shopify customers — it lists the missing ones instead; the orders must
  match Shopify's own count for a fixed window (`ordersCount`, read once more if an order moved while reading), with no order twice,
  or nothing is written. A cancelled order is never confirmed as shipped. The stock is only compared until
  `shopify_push_enabled()`; then only the quantities that differ are set, with an idempotency key (required since API 2026-04).
  Shopify permissions the app «Caseificio ops» still needs for the stock (`read_inventory`, `write_inventory`, `read_locations`)
  and for confirming shipments (`read/write_merchant_managed_fulfillment_orders`): without them those parts say what is missing
  and change nothing. Rollback: `shopify.sync_enabled = 0` and switch the Claude tasks back on (prompts kept, marked RETIRED).
- **E-07 · morning summary, quiet nights:** `notify_targets.digest_at` — a daily Telegram «Riepilogo» at each person's own time
  (`notify_digest_tick()`, from `notify_tick`): decisions waiting and when they approve by themselves, open alarms, what is new,
  what was approved automatically, bots to check, the morning brief; only what the person may see in the app (Sistema «vede» for
  messages, «gestisce» for approvals). Nick: 07:30 New York, silence 22:00–07:30. At night only food safety and «system down»
  (site or server not answering, database scheduler stopped) go out at once; other system alarms wait for the end of the silence,
  are dropped if they cleared meanwhile, and are folded into the summary when it goes out at that moment. The routine decisions of
  the day (`notify.decision_agents`: milk plan, promo, wholesale) reach Telegram as «Da decidere» even when not alarms, without the
  30-minute reminder, saying when they approve by themselves. Configurazione → Utenti → Avvisi Telegram: «Riepilogo ogni giorno
  alle …».
- **Prompts:** message rules v1.02 — rule 7: bots never call SendUserMessage (the database delivers: Telegram + summary); the
  «Allarme bot» task pushes only when the database's automations are stopped. `tools/bots/sync_rules.py` copies the rules into
  every prompt (`--check` reports drift). Milk plan: «alert» only when demand stays uncovered (E-06); the evening check lists bots
  already sent to Telegram on one line (E-33); the partners are «i soci» (E-17); `weekly_brief.txt` and
  `tools/sales/bot_vendite_prompt.md` removed (E-17). The live tasks held older prompts than the repo (v0.99 changes never
  pasted): the apply step replaces them all from the repo.
- Tests: `prod-test/test_shopify_sync_digest.sql` 43/43; `supabase/functions/shopify-sync/sync_test.ts` (Deno) 12/12;
  `tablet-test/shopify_sync_fn_e2e.py` 12/12 (the function with Deno against PostgREST and a fake Shopify);
  `tablet-test/sync_e2e.py` 10/10 (browser); `test_audit_critical.sql` updated for the new night rule. Every SQL suite (766
  checks, 24 suites, only the known B-19 failures) and all 20 browser suites in a row pass on a fresh database.

## Audit alerts and operations (v1.00)
The «alerts and operations» items of the 12/10/2026 audit (project doc `claude/audit-fixes-v100-2026-10-14.md`). Migrations
`v100b` (the feed: reads per person, «Risolto», links, names) and `v100c` (notices for the floor or the office, one incident per
bot that stopped, «Esegui ora», refused saves); live apply: `tools/go-live/live-apply/2026-10-14_v100_sql-editor.sql` (built by
`make_v100_script.py`; database first, then the site); tablet sw `perla-v68`. No edge function changes. Shopify sync (E-18) and the
07:30 digest (E-07) are v1.02.
- **E-04 / C-12 · who has read what:** `bot_messages.read_at` now means «closed for everyone». Each person's reads are in
  `bot_message_reads` (written only by `mark_bot_messages_read`); «Segna tutto come letto» is for me and never touches an alarm.
  An alarm stays open until someone with «gestisce» in Sistema marks it «Risolto» with what was done (`resolve_bot_messages`,
  who and note kept, its Telegram counts as taken), or until it clears by itself. The feed shows «Visto da …». Browsers can no
  longer write `bot_messages` at all. The bell (`bot_bell()`): open alarms first, then what I have not read.
- **E-05 · routine messages close by themselves:** a scheduled bot's info/warn is closed by its next message; a milk plan or promo
  message closes when its request is decided (`approval_id`); a notice's copy closes with the notice, and only the newest copy of a
  notice is open. A message that closes stops its 30-minute Telegram reminder.
- **E-08 · a link in every message:** `action_url` + `action_label`, only to the app's own pages (`safe_link()`, the same rule in
  the browser), a default page per sender; the milk plan and promo messages open their request (`console.html#oggi&appr=<id>`,
  highlighted). Telegram messages and their reminders carry the same link.
- **E-13 · names:** what the bot does first, then the nickname («Piano latte · Zio Gennaro»); what the database writes by itself
  has no nickname: «Sicurezza alimentare» (CCPs, milk, refused HACCP records — food-safety Telegram topic), «Turni», «Tablet»,
  «Avvisi della console», «Masseria», «Configurazione».
- **E-03 · notices:** `notices.audience` — the floor tablet shows only the evening HACCP list, the lot guard (items in Italian, a
  tap opens the lot) and lab results for an unknown lot; the rest (git, cron, bots, Incassi, trade requests without e-mails) is in
  Console → Oggi «Avvisi aperti», with the open alarms and their «Risolto…».
- **E-33 / E-20 · bots that stop:** the hourly database job (`fabula_bot_heartbeat` :25) runs `bot_watchdog()`: one `bot_alerts`
  incident per missed slot, failed run, run that never finished, scheduler stopped (one per stoppage) or database job whose last run
  failed (one per job and day); one Telegram (system topic) when it opens, never for one that cleared first; it closes by itself
  (bot ran, database stood in, run finished, job succeeded, older than a day) and so does the failed run's alarm in the feed. The
  failed run's alarm is not pushed separately. One office notice «N bot da controllare» lists what is open. A bot that started
  and failed is now stood in for by the database too. «Bot fermi: cosa fare»: Configurazione → Bot (`admin.html#bots&fermi`) and
  `sop/bot_fermi.html` (+ PDF). The evening check marks missing bots already reported.
- **E-21 · run now, refused saves:** «Esegui ora (versione del database)» on the bots the database can stand in for
  (`run_bot_fallback`, «registra» in Sistema, asks naming the effect and again on a second run the same day, recorded with the
  name). Autocontrollo → Registri «Registrazioni rifiutate» (`tablet_rejects_list`): what, the values in one line, who, HACCP
  flagged; «Segna come rifatta» with a note (HACCP or Sistema «registra»), and the alarm closes when nothing is left for that tablet.
- Small fixes: the tablet's waiting-records date («delle 06:06 del 13/10», not «4el»); refused records named in Italian.
- `v100d` (one-off, 14/10): closes the 16 alarms scheduled bots had left open before v1.00 (`2026-10-14_v100d_sql-editor.sql`).
- Tests: `prod-test/test_audit_alerts.sql` 71/71, `tablet-test/alerts_e2e.py` 30/30; every other suite passes on a fresh database
  (three browser suites no longer depend on the hour they run).

## Audit office decisions and undo (v0.99)
The «office decisions and undo» items of the 12/10/2026 audit, plus A-02 (project doc `claude/audit-fixes-v099-2026-10-13.md`).
Migrations `v099a` (approvals: decide, undo, deadlines, milk plan, DOP declaration, posts) and `v099b` (orders, wholesale forecast,
recipes, holds and NCs, B2B prices); live apply: `tools/go-live/live-apply/2026-10-13_v099_sql-editor.sql` (built by
`make_v099_script.py`; database first, then the `trade-portal` function, then the site); tablet sw `perla-v67`; wholesale theme
`shopify-theme-trade/assets/trade.js`.
- **FIX · milk plans:** a milk plan approved by a person in the Console never reached `milk_plans` (the sync trigger ran with the
  person's rights and had no UPDATE policy): the farm page never showed it. The trigger runs as definer now, and the migration
  repairs plans stuck at «proposed» after a decision.
- **D-24 · a decision stays decided:** a trigger refuses changing a decided request (except through «Annulla»), approving after
  the deadline, and rewriting who decided; every change is a line in `approvals.history`. The browser no longer updates
  `approvals` itself: `decide_approval()` (profile, notes a recall or a DOP declaration need, signer from the login),
  `revoke_approval()`, `dop_declaration_sent()`.
- **B-12 · Console → Oggi:** cards by urgency, consequence-naming questions (milk, DOP, recall), «Decise di recente» (7 days)
  with «Annulla» while it can still be undone (`approval_undo_block()` says why not: farm already saw it, order sent, posts out,
  a newer order for the same items…).
- **B-09 · milk plan:** the card shows capacity, farm supply, minimum run and history as facts; «Approva con … kg» (capacity
  checked, above the farm's kg it asks); after «Rifiuta», «Ordina di nuovo» (`milk_order_again`).
- **B-11 · DOP declaration:** «Approva i dati» needs the checks ticked (or a note); it stays «da inviare» with print/PDF
  (`consorzio.html`) and CSV until «Segna inviata» with date and protocol, which closes the monthly task.
- **E-10 / E-12 / E-11 · automatic approvals and deadlines:** the bots say when a request approves itself (`auto_approve_at`);
  an automatic approval posts a line and a push with how to undo it; promo posts approved automatically stay «in revisione».
  Deadlines run every 10 minutes (`expire_approvals()`); an expired card is grey without «Approva», and an expired milk plan
  pushes «nessun latte ordinato».
- **B-13 · posts:** a post edited while in review refreshes its approval card; the card shows date, picture and a link.
- **B-18 · catalogue orders:** confirmation with every line and total; a line without a price needs «prezzo da confermare»
  and then always waits for a person; above `approve.auto_po_max_eur` or from a «registra» profile the order waits in Oggi; the
  creator is stored; «Annulla ordine» with a reason (`cancel_po`), with the message for the supplier when it was already sent.
- **B-19 · wholesale:** the old «Ordini fissi» grid is gone; the 7-day milk forecast and the Vendite numbers read the Ingrosso plans.
- **B-15 / B-16 · recipes and presets:** «Togli» asks and ends a component from tomorrow (at once if it was put in today),
  «Rimetti» the same day; a removed row can't be saved back. Preset targets take «94,5»; «Togli» on a step asks.
- **B-06 · holds and NCs:** a lot is not released while its recall assessment is open, nor after a recall was decided; the
  release names the conforming analysis of that lot (checked by the database) or a written reason; an NC closes only with its
  corrective action; closed NCs (30 days) can be reopened.
- **B-21 / B-22 / B-23 / B-24 · Ingrosso:** exception form with labels and only the fields the type needs; «Invia a Shopify» shows
  what changes first (`prices-preview`) and sends rules and breaks in one all-or-nothing Shopify update (`prices.ts`, unit
  tests in `prices_test.ts`); «da inviare» marks per product and tier; a tier is a price or a discount, never € 0; stop buttons
  apart and asked. **TRADE-06:** «Pausa senza data» in the portal asks, naming the first date, and the office gets a dashboard line.
- **A-02 · lot label:** after «Inizio lotto» the tablet offers the label of the lot in progress, to put on the vat and scan.
- Tests: `prod-test/test_audit_office.sql` 70/70, `tablet-test/office_e2e.py` 42/42, `supabase/functions/trade-portal/prices_test.ts`
  9/9; every other suite passes on a fresh database.

## Audit numbers and limits (v0.98)
The «numbers and limits» items of the 12/10/2026 audit (project doc `claude/audit-fixes-v098-2026-10-13.md`). Migrations
`v098a` (settings), `v098b` (batch, milk, recipes, dosing, goods receipt, farm page) and `v098c` (wholesale); live apply:
`tools/go-live/live-apply/2026-10-13_v098_sql-editor.sql` (built by `make_v098_script.py`; database first, then the site);
tablet sw `perla-v66`; wholesale theme `shopify-theme-trade/assets/trade.js`.
- **A-13 · numbers on the tablet:** every number field takes the Italian comma («1,5»), refuses «1.200» as ambiguous, has a
  minimum, a maximum and a unit (from the CCP limits and the settings), and shows under the field what it understood
  («= 1,5 kg»). Out of range it turns red with the allowed range and Salva stops on it.
- **C-02 / C-03 / D-13 · settings:** min, max and unit per number setting, lists for the choice settings, sì/no for flags,
  dates as dd/mm/yyyy; the database refuses out-of-range values with the setting's name. High-impact settings (milk price,
  vat size, approvals, stock push…) ask before saving and post who changed what to the bell. `setting_num()` falls back to the
  default instead of breaking on an unreadable value. Magic-link validity 24 h.
- **D-06 · batch yield:** mozzarella 10–45 %, ricotta 2–25 % (`prod.*yield_min/max_pct`). Above the maximum the close asks to
  correct the milk kg (`correct_batch_milk`: milk taken, raw-milk stock and a correction record); below the minimum it asks the
  reason (`yield_note`, also in the HACCP correction dialog). Milk in a vat ≤ `prod.vat_kg` + 10 %; whey ≤ 95 % of the vat.
- **D-07 / FARM-07 · milk:** the database rejects milk over the CCP 1a limit itself; physical limits on temperature, kg, fat,
  protein, pH and cells. The farm page warns before shipping milk over the alert or rejection temperature.
- **B-14 / D-27 · recipe doses:** the console shows each dose per vat with before/after; more than ±25 % asks, ×2 or ÷2 needs a
  confirmation and a reason (kept in the notes); 0 refused. **D-20:** units normalised; an item used in a recipe keeps its unit,
  stays active and counted.
- **D-19 · dosing:** negative refused, more than 3× or under ⅓ of the recipe asks; the pack lot (rennet, cultures, salt) is
  recorded and remembered per item; a closed lot takes no more doses.
- **D-18 · goods receipt:** expired goods refused; more than 3× what is still to arrive, or a price ±50 % from the order, asks.
- **TRADE-01 / D-23 · wholesale:** quantities in whole steps; customers cannot go above `trade.max_kg_per_delivery` (150 kg)
  in one delivery; over 3× their usual and over `trade.confirm_kg_per_delivery` the portal asks «Confermi?» (only pages that
  send `can_confirm`). Reserved prices > 0 and ≤ base; tiers ≤ reserved price, discounts ≤ 50 %; `trade_price()` stays
  between 0 and the list.
- Every «asks» is a database error with HINT `confirm` (P0001 «…Confermi?» for wholesale): the page asks, then resends with
  `p_confirm` / `confirm = true`.
- Tests: `prod-test/test_audit_numbers.sql` 89/89, `tablet-test/numbers_e2e.py` 39/39; every other suite passes on a fresh database.

## Audit floor flows (v0.97)
The High items of the 12/10/2026 audit on the floor tablet (project doc `claude/audit-fixes-v097-2026-10-13.md`). Migrations
`v097a` (tasks, follow-ups, offline times, Italian errors, lot letters) and `v097b` (stock count, 60 h DOP, paper milk date); live
apply: `tools/go-live/live-apply/2026-10-13_v097_sql-editor.sql` (database first, then the site); tablet sw `perla-v65`.
- **A-07 · values that reject milk or hold a lot ask first:** a red «È giusto?» with the value, the limit and the consequence
  (cold rooms, milk arrival, 🛡 menu, paper copy, CCP 2 at the start, CCP steps, the CCPs asked at the close, the pasteuriser check).
  After a non-conformity a card stays on screen with what to do; it no longer flashes for 2,6 s.
- **A-15 · follow-ups are timed tasks** (`T-FOLLOW`): «ricontrolla la cella entro 1 ora» (cold room in its alert band or over its limit)
  and «in caldaia entro 2 ore» (milk over 6 °C). Red box on top of Home with the minutes left; the next reading / the first vat closes
  them; not done in time → Telegram (food safety, `fabula_followup_tick` every 5 minutes).
- **A-05 · task list:** overdue shows the same day (computed in `v_tasks_open`); «Da fare oggi» is today only, earlier days apart
  with «Non fatta…» and a reason (`skip_task`); tasks open more than 7 days are closed as not done; a check closes the task whose
  time has come (a 10:00 re-check no longer closes the 18:00 cold-room task).
- **A-09 · nothing to confirm without measuring:** packing weights, goods received, expiry dates, stock count lines and pest
  stations start empty, with what was expected as the hint («✓ Ci sono N» / «Tutte OK (14)» say it explicitly).
- **D-05 · stock count:** the adjustment is against what the system holds when the count is saved; a sheet older than 3 hours is
  replaced; an empty line is «non contata», not «same as the system»; negative counts refused.
- **A-11 / A-08 / D-15 · refused saves:** red banner on Home, a screen listing each one in Italian (what it was, when, why) with
  «↻ Rifai» (opens the form with the values); records depending on a refused one (same lot, or milk that was refused) are held back
  with it; `save_ops` explains errors in Italian. Two offline tablets with the same lot letter: the database gives the second the
  next letter, and the tablet moves its queued steps to it and says so on Home.
- **D-04 · offline times:** `save_ops(p_client_at)`: a check, a step or a task closed offline keeps the time it was done (≤ 7 days);
  the register prints «inserito nel sistema alle …».
- **A-14 / D-08 · 60 hours:** `milk_age_hours()`; milk past 60 h cannot start a DOP batch (database and tablet).
- **A-20 · paper copy:** milk arrival, batch start and close have «Ricopio dal foglio di carta» (date, time, signer); a DDT photo taken
  offline waits on the tablet and goes up later.
- **Medium items in the same screens:** A-17 (questions instead of «premi Salva di nuovo»), A-18 (a double tap in dosing is ignored),
  A-22 («Fatto (non misurato)», the curd pH is never erased), A-23 (cleaning item not done, with the reason), A-26 («Uscire senza
  salvare?»), A-29 (pasteuriser check decided on Salva; «Ok» after a «NON ok» needs a note).
- Tests: `prod-test/test_audit_floor.sql` 63/63, `tablet-test/floor_e2e.py` 38/38; every other suite passes on a fresh database.

## Audit Critical items (v0.96)
The remaining Critical items of the 12/10/2026 audit (project doc `claude/audit-2026-10-12/`). Migrations `v096a` (milk, CCP,
records), `v096b` (operator), `v096c` (Telegram alerts), `v096d` (dairy weight); edge function `notify`; live apply:
`tools/go-live/live-apply/2026-10-13_v096_sql-editor.sql` (database first, then the site: the tablet calls the new functions); tablet sw `perla-v64`.
- **A-04 · a positive milk check blocks that milk** (`log_milk_check`, `milk_reject`):
  - From the 🛡 menu or the paper copy, the antibiotic test and the arrival temperature ask which delivery (last 3 days).
  - Out of limit, the delivery is rejected, the farm load is marked rejected, and the raw milk left is written off.
  - Every lot made from it, and their ricotta, is held. A lot already held for another reason gets the milk reason added.
  - One alert goes out (Telegram too), also when the milk is refused at arrival.
- **A-03 · a lot closed without its CCPs is held** (not only reported):
  - The tablet always shows «Continua più tardi» and, on re-scan, resumes unfinished start steps and doses.
  - «Fine lotto» asks every missing CCP (pasteurisation included).
- **D-02 · records are locked:**
  - Users cannot UPDATE or DELETE `haccp_log`, `milk_intake`, `batch_milk_inputs`, `stock_moves`, `labels`, `goods_receipts`,
    `lab_samples`; no DELETE on `non_conformities` and `production_batches`. Every change is in the audit log.
  - The only way to change them is `correct_record` (Autocontrollo → «Correggi», with a reason from a list). The original value
    stays on the record and on the printed register («CORREZIONE: …»), and a row goes to `record_corrections`.
  - Who may correct: the operator, on their own record, within 15 minutes; otherwise the manager (haccp or produzione level 3).
  - A corrected value is evaluated again. Out of limit → NC + hold, and for a milk check, the A-04 rejection. Moved to another
    lot → that lot is held, the NC follows, and the lot it left is held if it has no reading left.
  - An open lot cannot be "closed" by a correction. A delivery's temperature is corrected only through its CCP 1a record.
- **D-21:** a closed lot cannot be closed again (Italian message with time and kg); one production output per lot.
- **A-01 · who is recording on the shared tablet:**
  - The header chip shows the operator. Badge scan, or name + 4-digit PIN, sets it; it lapses after 15 minutes idle and at
    badge-out. A form left open for 15 minutes asks «Sono … / Non sono io» at the first touch.
  - Every record button asks «Chi sta registrando?» when nobody is set.
  - A badge scan clocks in only when needed: the same badge again offers «Fine turno» instead of clocking out (A-25). The
    evening «badge di uscita non passato» item closes that shift with a confirm.
  - PINs: `staff_pins` stores bcrypt hashes only, and the apps cannot read it. Configurazione → Utenti → «PIN». Easy PINs are
    refused; 5 wrong attempts lock the PIN for 15 minutes.
  - Offline, only a PIN already checked on that tablet works (PBKDF2 on the device).
  - Records keep the operator and the logged-in account (`entered_by_id`).
  - The daily check flags tablet checks signed by someone not clocked in.
  - Paper copy: «Chi l'ha scritto» is a list with no default (A-19).
- **E-01 · alerts on Telegram (@bubalina_avvisi_bot):**
  - Every `alert` bot message, alert notice and new non-conformity goes to `notify_outbox`, by topic:
    - food safety → whoever subscribed, the HACCP responsible and whoever is clocked in, at any hour;
    - system → Nick, at any hour;
    - decisions → owner/partners, after their quiet hours.
  - Two buttons: «👀 Ho visto» and «✋ Me ne occupo io». Taking charge updates everyone's copy.
  - Nobody takes it within 30 minutes → one reminder, also to the owner, the partners and the HACCP responsible.
  - pg_cron `fabula_notify_tick` runs every minute and calls the function `notify` when something is due. The function sends,
    and receives `/start <code>`, `/stop` and the buttons through the webhook (secret header). It registers that webhook by itself.
  - Configurazione → Utenti → «Avvisi su Telegram»:
    - link your own phone (t.me link + QR), choose topics, quiet hours and time zone, send a test message;
    - the owner can send a link to anyone and sees who is linked and the last alerts.
  - The daily check flags undelivered or stuck alerts and «nobody linked».
- **FARM-02 · the dairy's scale weight is kept:**
  - With a farm load, the Masseria's kg stay read-only and «kg pesati qui» is asked.
  - Within 2 % (`milk.weight_tolerance_pct`) the farm's figure counts. Beyond it a reason is required, and the dairy's weight
    becomes `qty_kg` (stock and the farm's month total).
  - The office gets a notice, the farm page shows «Pesato al caseificio … (vale questo peso)», and MOD-01 prints both weights.
- **E-23 · restore without wiping live data:**
  - `restore_backup.py` puts back only missing rows by default, and only the day-to-day records unless `--tables` says otherwise.
  - A full restore needs `--wipe-all --target <ref>`. The target must equal the `--db` project ref, never a substring. The SQL
    refuses any database holding records newer than the backup.
  - Every generated SQL stops unless `set restore.confirm = '<backup time>'` was run first.
  - Partners get the one-page card `sop/sistema_giu.html` (+ PDF): paper, who to call, what never to do.
- **Tests:**
  - `prod-test/test_audit_critical.sql` 89/89.
  - `tablet-test/operator_e2e.py` 37/37, `farm_weight_e2e.py` 11/11, `notify_fn_e2e.py` 12/12 (the function run in Deno against a
    fake Telegram).
  - `drill/restore_guard_test.py` 15/15.
  - Existing e2e tests store the operator like a login, fill «kg pesati qui», and record start steps on SQL-made batches.
    On the long-used local copy, failures left by old test data stay as before (see `tablet-test/README.md`).
## Bubalina domain, tracking links and tablet name (13/10/2026)
The shop trades as **Caseificio Bubalina** on **www.bubalina.it** (perladelcilento.it only redirects there). Project doc
`claude/ga4-setup-2026-10-12.md` has the GA4 set-up and the tagged links for the Google profile and social bios.
- Migrations `20261013041042_bubalina_domain_cleanup` and `20261013041309_bubalina_launch_newsletter_utm` (applied live via
  MCP, files saved here with the same versions; patches are guarded: no match, no change):
  `mkt_local_qr` / `trade_settings` / `company_name()` fallbacks → bubalina.it / "Caseificio Bubalina"; launch-plan post links
  (`mkt_seed_launch`) built from `trade.store_url`, newsletter links with `utm_medium=email`; creator outreach signature
  "bubalina.it"; collab-disclosure message "@caseificiobubalina"; settings `trade.store_url` → https://www.bubalina.it and
  `mkt.hashtags` #laperladelcilento → #caseificiobubalina; `mkt_channels` "sito" note.
- Setting `mkt.local_site_url` → https://www.bubalina.it (a settings edit, in the settings history): every signage and
  local-ad QR (`mkt_local_qr`, `v_mkt_local_items.qr_url`) now opens bubalina.it.
- Tablet (sw **perla-v63**): Marketing → Canali link/QR builder uses `mkt.local_site_url` (was hard-coded
  perladelcilento.it); the offline / first-load company name (`brand.js` DEFAULT, page `<title>`s and `data-brand` headers)
  is "Caseificio Bubalina". Internal keys keep the old prefix on purpose: service-worker cache `perla-vNN` (the outside
  watcher `tools/watch/check.sh` and `app.js` match on it), localStorage `perla_*`, backup format `la-perla-backup/1`.
- Bot message rule 10 now says: website www.bubalina.it, handle @caseificiobubalina, never the old domain or handle
  (`tools/bots/MESSAGE-RULES.md`, `tools/bots/prompts/*.txt` and the same sentence
  in the 14 enabled scheduled bots, updated 13/10; the disabled weekly-brief task was left as it was).


## Audit backlog: items under an hour, High/Critical (v0.95)
From the 12/10/2026 audit backlog (project doc `claude/audit-2026-10-12/`): every item with effort S and severity High or
Critical that v0.93/v0.94 had not fixed. Migrations `v095a` (food safety, production) and `v095b` (farm, settings, print,
watcher); live apply: `tools/go-live/live-apply/2026-10-12_v095_sql-editor.sql`.
- **Tablet** (`app.js`):
  - **Esci** (A-12): with records still waiting it first tries to send them. If they cannot go out it refuses, and a second tap
    within 10 s logs out anyway (no dead end). `close_open_task` signs with the staff id sent with the record.
  - **Ricotta** (A-16):
    - A vat started from milk no longer offers ricotta.
    - The batch close asks «Ricotta con il siero di questo lotto?» Sì / No as a required choice; «No» is stored as `whey_kg = 0`.
    - Home → Produzione di oggi offers «Avvia ricotta dal siero di oggi» for lots closed in the last 4 hours without ricotta.
  - **Milk left** (D-09): the start form says «restano 400 kg (ricevuti 1.000, già in caldaia 600)» and refuses more (+2 %).
    The offline copy now keeps the milk used by closed batches too.
  - **Impossible values** (D-12): CCP readings and curd pH are checked against the same ranges as the database before
    anything is saved or queued, offline too.
- **Database guards:**
  - D-03: a food-safety hold is lifted only through `release_lot_hold`. A plain UPDATE is refused, and every hold change goes
    to the audit log. Setting a hold stays open.
  - D-09: `batch_milk_inputs` cannot exceed the delivery's kg + 2 %, with an Italian message.
  - D-12:
    - `haccp_control_points.plausible_min/max` (PAST/STRETCH/RIC 10–99/100, milk −2–45, cold rooms −10–45, ABX and valve 0–1):
      a reading outside is refused («Valore impossibile… controlla la virgola»). Sensor and simulation rows are exempt.
    - A CCP is never recorded empty, and `batch_ccp_check` counts only readings with a value.
    - Curd pH must be between 3 and 8.
- **Autocontrollo** (`haccp.js`):
  - B-02: no default lab outcome, and the result is required for conforme/non conforme. «Correggi esito» takes a reason
    (`correct_lab_result`); the first outcome stays in the sample's notes and the audit log.
  - B-03: an external calibration needs the certificate number plus the deviation or the PDF, and cannot be dated in the
    future. Without a deviation it is «da verificare»: the instrument does not go back in service and the due date does not move.
  - B-04: the register review is a dialog. The period runs from the last review to today (never later), it shows the record
    and out-of-limit count, needs «Ho letto le registrazioni», and is signed by whoever is logged in.
  - B-05: «Prelevato» picks the lot from the recent lots, or a typed lot is looked up. `record_sample_taken` upper-cases it
    and refuses an unknown lot.
- **Configurazione** (`admin.js`):
  - C-28: kg per Shopify piece shows the grams, is pre-filled from the title, asks above 5 kg and refuses above 25. DB check 0–25.
  - C-04: the B2B cut-off is a time field and the delivery days are seven boxes. The database normalises «18.00», «ore 18»,
    «lun-sab» and «1-6», refuses the rest, and `trade_cutoff_at` falls back to 18:00.
- **Farm page** (FARM-01):
  - The weight is read the Italian way («1.050» = 1050) and under 50 kg is refused.
  - A weight more than ±30 % from today's order (or what is still missing of it) and from the usual loads is spelled out big
    with «Sì, 105 kg» / «Correggi».
  - `farm_milk_ship(p_confirm)` repeats the check on the server. The edge function `farm-order` passes it and still works
    against an older database.
- **Print** (PRINT-03): a wholesale DDT without legal name, P.IVA or address shows a red banner and cannot be printed. An
  address without a recognisable street only warns. The PO shows the same banner, and the go-live board has the
  `company_docs` check.
- **Outside watcher** (E-20): `public.fabula_health()` adds `bots_ok`/`bots_missed` (a bot slot of the last 4 hours with no run
  of its own), and `tools/watch/check.sh` fails on it.
- **SOP** (E-26): rev. 4. The «tablet non funziona» box points to the printed MOD sheet → 🛡 → 📝 Ricopia da foglio di carta
  with the sheet's date and time; there is a «Chi chiamare» box, the red banner and the 60 h DOP rule.
- **Tests:**
  - `prod-test/test_audit_s_items.sql` 63/63 (most fail on v0.94b).
  - `tablet-test/s_items_e2e.py` 41/41.
  - Existing e2e tests were updated for the ricotta choice and the refused over-draw.

## Milk arrival: the load is checked against the driver's paper (v0.94)
Rest of audit A-10. When more than one farm load is in transit, the tablet:
- lists them by departure time, age and kg, without lot or DDT;
- shows the picked load big (kg, departure, age);
- asks for the end of the lot written on the DDT or the tank (e.g. `12-2`), or the last 3 digits of the DDT number.

What it does with that entry:
- A value belonging to another load is refused and names that load. An unknown value is refused, and the reason stays
  on screen.
- The lot and kg are only locked in once the entry matches.
- A load older than 36 h is listed only after «mostra le spedizioni più vecchie».
- One fresh load (< 12 h) is still preselected with no check, as in v0.93.
- A DDT number read from the paper's QR picks its load directly.

Front end only, so it needs no database change. `tablet-test/audit_e2e.py` 22/22.

**v0.94a: wrong or stale farm loads can be put right** (FARM-03, FARM-02b; migration `v094a`, edge function `farm-order`
action `amend`):
- **Farm page** (`latte.html`):
  - «Correggi o annulla» on a load still «in viaggio»: fix the kg, or cancel a load registered by mistake.
  - A reason is required, and a second tap confirms.
  - The first kg is kept (`original_kg`), and the office gets a message in the Bot feed (agent `masseria`).
  - After registering, the lot is shown big with «scrivi il lotto sul DDT e sulla cisterna».
- **Console → Oggi:**
  - Every load still in transit is listed; one older than 36 h is in red.
  - Produzione level 2 or higher (Titolare, Socio, Responsabile produzione, Produzione, Qualità) can cancel a load, giving a reason.
- **`ops_health_check`** reports a load in transit for more than 36 h (`milk_shipments_stale`) every evening.
- **A cancelled load:**
  - the tablet no longer offers it;
  - the intake trigger refuses it ("già stata annullata (motivo)");
  - re-entering the same kg right after a cancel is no longer taken as a double tap.
- **Tests:** `prod-test/test_audit_farm_shipments.sql` 18/18 (12 fail on v0.93), `tablet-test/farm_amend_e2e.py` 16/16.

## Audit fixes, phase 0 (v0.93)
From the 12/10/2026 usability & error-proofing audit (Claude Doc "Caseificio ops — usability & error-proofing audit",
project doc `claude/audit-2026-10-12/`). 16 of the 17 phase-0 bugs; #9 (CCP 2 limit 72 °C vs vat 63 °C × 30 min) waits
for the HACCP consultant.
- **Database** (`v093a`–`v093d`):
  - `log_ccp`, `hold_lot` and `record_lab_result` run as definer after `require_perm('haccp', 2)`, so a CCP out of limit
    holds the lot from every profile that can record it (Banco/Spedizioni used to save the CCP but not the hold).
  - A recall assessment no longer expires after 2 days; `ops_health_check` reports it as `recall_pending` until decided.
  - Alerts sort first in `v_active_notices`.
  - The `haccp_cp_limits_guard` trigger refuses a blank or inverted CCP limit, and alert thresholds outside the limits.
  - A weighed POS sale (no variant, `sku`/`peso_kg` in the line properties) reduces stock instead of breaking the Shopify
    sync; an unknown free sale lands in `shopify_unmapped_lines` as "vendita libera".
  - `generate_daily_tasks` sets due times in Rome time (they were one or two hours late).
  - Wholesale:
    - A change that takes a day under the minimum order is refused with the reason.
    - A day still under the minimum at the 18:20 booking is logged for the customer and posted to the office.
    - «Salta» on a day already booked cancels the order and its Shopify queue entry; any other change to a booked day
      is refused.
    - Messages no longer show a stray `s`.
    - `v_shipment_doc` gives the DDT the delivery address, window, instructions and PO number.
- **Tablet and console**:
  - Numbers: `1.234` with a dot is read as a thousands figure only when it really is one (`0.044` stays 0.044), and
    a value that jumps ten-fold or more asks before saving (Parametri, supplier prices).
  - The HACCP plan editor shows the diff and refuses blank or inverted CCP limits.
  - Scanning a tank label when two lots share the milk asks which lot.
  - Milk arrival no longer preselects one of several loads in transit, and shows how long ago each left.
  - Task times are shown in Rome time.
  - An invite link opened on a device already logged in signs that user out first.
  - The DDT prints the delivery address.
- **Till** (`cashdro-middleware`, POS extension):
  - A paid sale whose receipt failed is `paid_no_receipt`, not `error`, and the tile refuses to charge the same cart again.
  - Change the machine could not give stays visible to the end (`change_short_cents`) and must be acknowledged.
  - Status polls are retried.
  - See `cashdro-middleware/DEPLOYMENT.md` §4.
- **Bot**: `tools/bots/prompts/shopify_orders.txt` also reads the line properties (needed for weighed sales); the live
  "Ordini Shopify" scheduled task must get the same change.
- Tests (12/10/2026, all pass on a fresh replay):
  - `prod-test/test_audit_food_safety.sql` 18/18
  - `test_audit_weighed_sales.sql` 6/6
  - `test_audit_task_times.sql` 4/4
  - `test_audit_wholesale.sql` 16/16
  - `tablet-test/audit_e2e.py` 10/10
  - `cashdro-middleware/test_engine.py` 12/12

## Configurazione: Panoramica e Parametri per sezione (v0.84)
Front end only (`fabula-tablet/admin.html`, `admin.js`; sw perla-v53), no database changes.
- **Panoramica** is the first tab: one status card per area — Parametri (values still empty, or that their own description calls
  provisional: "da confermare", "STIMA", "ipotesi"), Macchine e scadenze (late / within 30 days / without dates), Prodotti Shopify
  (variants with order lines waiting), Bot (errors, unread alarms, warnings), Utenti e accessi (expired links, invites to send),
  Sistema (app version from `infra.sw_seen` + `public.fabula_health()`: pg_cron and backup). Each card opens its tab or section; the
  headline counts the areas to fix; "Ultime modifiche" shows the last 6 audit rows. Tab badges: Panoramica = areas to fix, Bot =
  unread alarms, Utenti = accesses to fix.
- **Parametri**: 133 settings in 15 sections (new: Approvazioni automatiche, Professionisti · ingrosso B2B, Incassi e banca, Settimana
  di prova, Sistema — before, 40 of them fell under "Altri parametri"). One section on screen at a time, section list on the left with
  counts (phone: chips); search looks across every section. Empty values are tagged "da compilare", provisional ones "da confermare"
  (an empty value whose description says "Vuoto = …" is a documented choice, not a gap). Ids, tokens and addresses are folded under
  "Impostazioni tecniche" at the end of their section; `infra.sw_seen` is read-only. Since v1.03 the secret keys (`milk.farm_token`,
  `milk.farm_ship_token`, `trade.job_secret`) never reach the browser at all (see «v1.03»).
  Save bar, previous value, Enter/Escape, validation and old `#azienda…#lavoro` links work as before; `#professionisti` etc. added
  (Ingrosso now links there). Dirty counts show per section so nothing typed is lost when switching sections.
- **No raw keys on screen** (v0.84a): parameter rows show only their description (the key is the row's tooltip); the Registro
  modifiche and the Panoramica "Ultime modifiche" name a setting by its description; save errors too. Console's milk note and
  Ingrosso's "Regole in vigore" no longer print `farm.*` / `trade.*` keys.
- **Descriptions rewritten** (v0.84b, migration `20261007143441_v084b_settings_descriptions.sql`, applied live): all 133
  `settings.description` in plain Italian — what the value is, unit, effect; no keys, no "(AAAA-MM-GG)" / "(1 = sì" hints, no
  history notes. New column `settings.kind` (flag | date | month, null = by data_type) tells the page which field to draw; the page
  still falls back to the old description hints. "Vuoto = …" marks an empty value as a documented choice; "da confermare" marks a
  provisional one (DOP fee, water/sewer/gas tariffs, overtime premium, internet) — remove the phrase when the real figure is in.
  Audit/touch triggers were off during the rewrite, so the Registro shows no 133 "modificato" rows. Repo and live history both at 140 migrations.
- **Macchine e scadenze**: status strip on top (già scadute · entro 30 giorni · senza data · attive); machines and deadlines sorted
  late → without date → by date.
- Tested headless (desktop 1280 and phone 390) with the live settings rows plus synthetic rows: every tab loads with no JS errors and
  no sideways scrolling; 82 checks pass (cards, section switching, tags, folded tech keys, search, save/undo/validation, hash links).

## Per i professionisti — Shopify B2B + piani consegne (v0.83)
Shopify B2B is native on the Basic plan (verified 06/10/2026): companies, company locations, Net terms, B2B market + catalog with its
own price list, quantity rules and price breaks. What Shopify does not do — application queue, weekly delivery plan with per-day
quantities and windows, skips/closures/temporary quantities/pause, pricing rules beyond the native ones, booking into the ops
system — lives here. Nothing is a paid app.
- **Shopify (native):** B2B market `Ho.Re.Ca. Italia (B2B)` (all company locations) → catalog `Listino Ho.Re.Ca.` → price list
  (fixed trade prices per kg, quantity rules min/step, price breaks when `trade.tier_basis` = delivery). Trade product
  `mozzarella-bufala-dop-ristorazione` (5 pezzature, €14 base = banco, €11.50 trade), template `product.trade`. Customer metafield
  `trade.portal_token` (pinned definition) + tag `ingrosso` = the storefront gate. Pages `/pages/professionisti` (portal) and
  `/pages/richiesta-professionisti` (application); theme files in `shopify-theme-trade/` (uploaded to the unpublished theme
  "Perla · Professionisti (anteprima B2B)", id 135103840331; to go live copy the 7 files into a duplicate of the live theme and publish).
- **Database (v083a–g):** `trade_applications`, `trade_products` (mirror of the trade variants, ops product + kg/unit), `trade_price_tiers`,
  `trade_schedules` + `trade_schedule_days` (+ `active`) + `trade_schedule_lines` (qty per weekday per variant), `trade_exceptions`
  (skip / override / window, date ranges, expire by themselves), `trade_closures` (dairy closed), `trade_change_log` (confirmations the
  customer sees), `trade_order_queue` (booked deliveries → Shopify orders). Settings `trade.*` (Configurazione → Parametri): minimum,
  cut-off, delivery days, windows, recurring discount %, combine rule, tier basis (delivery | week), payment terms, ids of the Shopify objects,
  `trade.job_secret` (pg_cron → edge function). Engine: `trade_effective_lines(date)` (plan + exceptions + closures + pause),
  `trade_price(customer, variant, qty, recurring)` (list → tier → recurring discount; combine or best-of), `trade_upcoming`, `trade_daily_totals`.
  `confirm_standing_orders` (bot Ordini ingrosso 18:20 / db fallback) now books from the trade plan into `sales_orders` (channel wholesale,
  source standing_order, delivery window/address/instructions) and queues each order; pg_cron `fabula_trade_push` (18:25 Rome) and
  `fabula_trade_push_retry` (hourly) call the edge function. Trigger `sales_orders_b2b`: a Shopify order of a trade customer is wholesale
  and confirmed even while unpaid (net terms). Trigger `parties_trade_guard`: the nightly customer sync cannot rename or de-wholesale an
  approved trade customer. Legacy `standing_orders` rows are no longer read (placeholders only).
- **Edge function `trade-portal`** (verify_jwt off): `apply` (public form), `state`/`portal` (customer key = metafield token),
  `approve`/`reject`/`link` (staff JWT, Vendite ≥ 3), `sync-prices` and `run-queue` (staff or job secret), `status` (diagnostics). Theme: the 7 files in `shopify-theme-trade/` are live in theme "Perla · Professionisti 2026-10-06" (published 06/10); header menu item "Per i professionisti" → /pages/professionisti. Shopify side:
  Dev Dashboard app **Caseificio ops** (org "La Perla del Cilento", installed on the store; scopes read/write customers, companies,
  draft_orders, orders, products, markets, publications, payment_terms). Dev Dashboard apps have no permanent token: the function mints
  one with the client-credentials grant (24 h, cached) from the Supabase secrets `SHOPIFY_CLIENT_ID` + `SHOPIFY_CLIENT_SECRET` (Dev Dashboard →
  app → Overview → Credentials); `SHOPIFY_SHOP` = pxssjd-cq.myshopify.com; a static `SHOPIFY_ADMIN_TOKEN` is still honoured. Without them
  approvals still work here and say what to do by hand, orders stay in the queue (`configured: false`).
- **Console → Ingrosso** (`ingrosso.html`, page `ingrosso` = Vendite ≥ 1; approvals/prices need Vendite ≥ 3): Richieste, Clienti e piani
  (plan grid, pause/resume/cancel, exceptions with "force" past the cut-off, suspend access, portal link, new link), Consegne (per date with
  product totals, CSV totals / CSV per customer, Shopify queue + "Invia ora"), Listino e sconti (trade prices, min/step, tiers, "Invia a
  Shopify"), Giorni e chiusure.
- Rules worth remembering: changes for date D are accepted until `trade.cutoff_time` of D-1 (staff can force); a booked delivery is a snapshot
  (later plan changes do not touch it); "pausa fino al" = skip range that resumes by itself; recurring discount applies only to plan lines;
  tiers "tutti i prodotti" on the weekly basis read the whole plan's kg. Tests of 06/10: scenario in the project doc.

## Operating decisions encoded in the database (v0.39)
- Milk price: setting `milk.price_eur_kg` (1.70, confirmed by Nick 05/10 after a stray edit to 1.6). Every intake without a price takes it; all cost reports read it.
- Milk is **pasteurised** (`food.milk_process` = pastorizzato): CCP 2 is required on every mozzarella lot.
- Website and Shopify POS sell even at zero stock ("continue selling"). Stock sync (v0.63): `shopify.push_inventory` = 2 —
  report-only until the opening stock count is posted, then the Giacenze bot updates Shopify by itself (`fabula.shopify_push_enabled()`).
  The mozzarella pool is split across the 16 variants: 80 % by kg sold in the last 28 days, 20 % equal (`shopify.mix_weight`),
  equal split while nothing has sold; the pieces offered never add up to more than the pool (`v_shopify_inventory_push`).
- Milk order to the Masseria (v0.64): approved milk plans appear on the farm's private page `latte.html?t=<milk.farm_token>`
  (edge function `farm-order`, no login). The farm taps "Visto"; the Console shows the next order and whether it was seen. Since
  v1.03 the keys are made by the database and replaced from Configurazione → Utenti e accessi → «Link della Masseria» (titolare
  and soci only); see «v1.03».
- Masseria shipments (v0.65): the farm records each load on its page (QR poster: since v1.03 printed from the QR key
  `milk.farm_ship_token`, latte.html?t=<qr key>&stampa=1 → opens `&azione=spedizione`); the farm's kg is the source of truth and each load gets a lot M<yymmdd>-<n>. The tablet's milk
  intake lists loads still in transit: picking one locks kg/lot/supplier (trigger `milk_intake_shipment_check` enforces it
  and blocks a second receipt); saving marks the load received or rejected, which the farm sees on its page.
- Sell-down promos (v0.64): the sell-down bot pre-creates a random Shopify code per promo it proposes (ends 20:00); the tablet
  shows it only once Nick approves; approving writes two approved posts (WhatsApp "oggi al banco", Instagram story).
- Consorzio DOP declaration (v0.63): pg_cron runs `consorzio_declaration()` on the 1st (05:30 UTC); it lands in Console → Oggi
  with the disciplinare checks (60 h, fat/protein, DOP suppliers, traceability) and a fee estimate (`dop.consorzio_eur_kg`, estimate).
  Approving it closes the month's T-DOP task. Sending it to the Consorzio stays manual until the official format is known.
  Since v1.11 nothing is proposed while `dop.rina_code` is empty and the month has no DOP lot.
  Paid web orders not yet shipped count as demand for the next production day (`v_preorder_demand`).
- Lot guard: system-allocated sales never drive a lot below zero (FEFO, then unassigned + notice);
  scanned sales keep the scanned lot and raise a notice to check the batch output weight.
- Bots run on Agropoli time (Europe/Rome); `bot_schedule.due_times` are Rome times.
- `fabula.bot_heartbeat()` runs hourly from pg_cron and puts a console notice up if any bot missed its slot.
- Bot nicknames (v0.46) are display only: `bot_nicknames` (agent → Zio/Zia) and `bot_display_name(agent)` →
  "Zio Gennaro · Piano latte". Never rename an `agent` key — watchdog, heartbeat, `expected_bots()` and the
  bot prompts all match on it. To rename a nickname, upsert `bot_nicknames` in a new migration.
- Company name (v0.48): `company.name` (Configurazione → Azienda) drives every page header and tab title (`fabula-tablet/brand.js`,
  `data-brand="name"`), printed orders/DDT, and the operational messages built in the database (`fabula.company_name()`:
  PO e-mail/WhatsApp, standing-order confirmations, lab sampling requests, monthly pack). Never hardcode the name in a page.
  v0.49 extends it to marketing/sales copy (creator outreach, Predis brief, Vendite lead messages: "Nick di <nome>") and
  to the 16 scheduled bots, whose prompts read `company.name` at run time. Not dynamic: `fabula-tablet/manifest.json`
  (home-screen name, edit by hand), the SOP sheet and go-live board (static text). The domain perladelcilento.it and the
  handle @laperladelcilento were kept at first; since 13/10 the site is www.bubalina.it and the handle @caseificiobubalina.

## Production floor guard rails (v0.80)
The tablet now enforces the HACCP critical points instead of trusting a tap. `v_process_steps` returns each step's
`ccp_code`: a CCP step (pasteurisation, stretching, ricotta) asks for the value read (no one-tap "Fatto" recording the
target as measured, no "Salta"). The first batch of the day asks for the pasteuriser valve check (PRP-PAST-VALVE); a failed
valve is logged NON ok and the batch does not start. If the preset has no CCP step, CCP 2 is asked on the start form, and
CCP 3 (mozzarella) or CCP 4 (ricotta) on the close form, when not already recorded (queued offline ops count). Server side:
constraint trigger `batch_ccp_check` (deferred to commit) alerts Zio Ciro when a batch closes without its CCP records;
`fabula.prod_watch()` (pg_cron `fabula_prod_watch`, runs at 19:45 Rome) warns once a day about batches left open and
accepted milk 48 h old or more (DOP limit 60 h). Tests: `prod-test/test_prod_guards.sql` (10), `tablet-test/guard_e2e.py` (15).

## Review fixes and board re-audit (v0.79)
An independent review of v0.69–v0.78 found 5 defects (none high), all fixed: the 2-hourly "latest" backup at 21:05 Rome no
longer counts as the nightly in `bot_fallback`/`bot_watchdog` (it hid a missing nightly in summer); `device_watch` keeps when
the live app version last changed (`infra.sw_seen`) so the old-app warning can fire; `fabula_health.cron_ok` ignores a run row
without a start time; the offline task list hides only one task per queued close; packing drops rows set to 0. Tests added
in `test_bot_fallback.sql` (22), `test_devices_watchdog.sql` (15), `pack_e2e.py` (16), `offline_e2e.py` (11).
The go-live board was re-audited (v0.79b, new `prev` baseline) with a stated rubric: *reliable* tops out around 75 until an
area has handled real transactions, and open opening gates count against it. Headline 85 / 66 / 67 (was 85 / 72 / 66).

## Outside watcher (v0.78)
GitHub Actions `.github/workflows/watch.yml` runs `tools/watch/check.sh` at :07 and :37 every hour, outside Supabase, the bots
and Claude: tablet site serves the app, `public.fabula_health()` (public key; returns only `db`, `cron_ok` = pg_cron ran in
the last 20 min, `backup_ok` = backup in the last 26 h) and edge function `farm-order` answers 403 without token. A failure
is re-checked after 3 minutes; a confirmed one fails the run, and GitHub e-mails the repo owner (GitHub → Settings →
Notifications → Actions). Run it by hand from the repo's Actions tab ("Run workflow").

**Offline gaps closed (v0.78):** a batch started without network can also be closed without network (the close updates it by
lot number and later steps take its id from that update; `stepBatchEnd`); the day's task list is kept on the tablet
(`perla_tasks_v1`) and tasks closed offline are hidden (`v_tasks_open` now also returns `control_point_id`, `equipment_id`);
direct shipment from a closed lot works offline (customers kept in the reference store; held lots refused on the tablet).
Still online-only: stock count, packing from "Da spedire", goods receipt of a purchase order. Test:
`tools/go-live/drill/tablet-test/offline_e2e.py` (10).

## Trial week, paper back-up, recall drill in the console (v0.77)
- **Trial week:** set `trial.start` (Configurazione → Parametri) to day 1. `fabula.trial_check(day)` lists the 12 daily steps
  (milk + temperature, antibiotics, pasteuriser check, pasteurisation, batches closed, stretching per lot, cold rooms ×2,
  cleaning, out-of-limit with action, open tasks, tablets, bot errors) plus that day's extra steps (1 stock count + tablet,
  2 ricotta + CCP 4, 3 packed order with DDT + sales, 4 paper copy + MOZ-DOP sample, 5 recall drill + registers verified).
  pg_cron `fabula_trial_report` (20:35 Rome) posts it as Zia Carmela (agent `prova`) during the `trial.days` (5). The
  script is the Claude Doc "Settimana di prova".
- **Paper back-up:** 🛡 → "Ricopia da foglio di carta" on the tablet: pick the check, write the sheet's date and time (up
  to 7 days back), who wrote it, the value. `fabula.log_ccp(..., p_logged_at, ..., p_written_by)` (new overload) keeps that
  time for `p_source = 'paper'`, notes who copied it and when, applies the same limits, NCs and lot holds; any other
  source still records now(). The old signature calls the new one. Offline it queues like any check. The Manuale console
  marks paper rows "📝 carta".
- **Recall drill:** console → Manuale → Lotti bloccati e NC → Prova di richiamo (calls `fabula.recall_drill(lot)`).
- Tests: `tools/go-live/drill/prod-test/test_trial_paper.sql` (16), `tools/go-live/drill/tablet-test/paper_e2e.py` (9).

## Internet in the expenses (v0.80)
`opex.internet_eur_year` = 600 (€50/month, assumption until the contract is signed). `weekly_brief()` shows it as
`pnl_estimate.internet_eur` (setting/52 ≈ €11.54) and subtracts it from the operating result. `benchmark.annual_profit_eur`
= 150300 (≈ €2,890/week; ≈ €149,700/yr from 2028 at the €1,100 rent).

## Lease at the agreed rent (v0.76)
`opex.lease_eur_year` = 12600 (€1,050/month, 2027), `opex.lease_eur_year_step` = 13200 (€1,100/month) from
`opex.lease_step_from` = 2028-01-01. `fabula.lease_eur_year(day)` picks the year; `weekly_brief()` uses it, so the brief
steps up by itself in January 2028. `benchmark.annual_profit_eur` = 150900 (v49 base + lease saving, ≈ €2,902/week).

## Go-live checklist review (v0.75)
The checklist covered the software and the data but not the gates to open legally or the dry run. It now has 35 items in
four groups (board order): **gates** (purchase deed, lease, CE approval/SCIA in Masseria's name, RINA/Consorzio, HACCP
training, Manuale, e-invoicing, RT printer) · **setup** (opening date, stock count, real names, doses, Fortino capacity,
deadline and calibration dates, Shopify catalog, labels) · **dry run** (tablet check-in, first milk, first batch, MOZ-DOP
moisture test, first packed order, paper sheets) · **system** (green). New automatic checks in `ops_dashboard()`:
`ce_approval` (`food.ce_approval_no` set), `haccp_training` (`v_training_matrix`, nothing missing or expired),
`opening_date` (`mkt.store_opening_date`), `tablet_checkin` (`fabula.devices`), `first_milk`, `moisture_test` (a
`MOZ-DOP` lab sample `conforme`), `first_shipment`. Manual ones are ticked on the board ("Mark done").

## Reliability: tablet check-in, refused saves, pg_cron watched (v0.74)
- Every tablet/browser running the app calls `fabula.device_checkin()` at start, after each send and every 5 min: device id
  (kept in `localStorage` `perla_device_uid`), label, app version (`sw.js` CACHE), records waiting and since when, and the
  saves the database refused. Devices are in `fabula.devices`; refused saves are kept in full in `fabula.tablet_rejects`
  and each new one rings the bell from Zio Tonino (agent `tablet`, own card in Configurazione → Bot). The tablet marks them
  reported (`perla_failed_reported`) and the pending line says "Già segnalate all'ufficio". Mark one dealt with:
  `select fabula.resolve_tablet_reject('<qid>', 'rifatta a mano')` (sistema ≥ 2).
- The answer carries the live app version (`fabula.live_app_version()`, from the infra probe); an older tablet shows
  "È disponibile una nuova versione · Aggiorna ora".
- pg_cron `fabula_device_watch` (every 15 min): records waiting > 2 h, or an old app a day after a release → one warning a day.
- `bot_watchdog()` (run hourly by the external alarm bot, which relays `message_it` unchanged) now also reports pg_cron
  silent for 20 min ("🛑 automazioni del database ferme") and every failed scheduled job in the last 26 h.
- Tests: `tools/go-live/drill/infra-test/test_devices_watchdog.sql` (13), `tools/go-live/drill/tablet-test/device_e2e.py` (8).

## Auto-approval rules and rota autocopy (v0.73)
- A new approval is checked by `fabula.auto_approve_rule()`; if routine it gets `auto_approve_at` (now + `approve.auto_delay_min`,
  60 min, never after it expires) and `auto_rule`. The console card shows "⏱ Si approva da sola alle HH:MM · <rule>"; a person
  can still approve or reject. pg_cron `fabula_auto_approve` (every 10 min) re-checks and approves the due ones with the same
  status update as the console (milk plan / PO / promo triggers run as usual) and posts "Approvato da solo" from Zia Rosa
  (agent `auto_approve`, own card in Configurazione → Bot). If the rule no longer holds, the timer is removed.
- Rules: milk plan (`approve.auto_milk_plan`, ±`approve.milk_tolerance_pct` 15 % of the milk worked on the last 4 same weekdays,
  real history, no capacity / minimum batch / farm limit); purchase order (`approve.auto_po_max_eur` 150, real supplier, item
  already received from them at a price within 10 %); counter sell-down promo (`approve.auto_promo`, standard discount,
  ≤ `approve.promo_max_kg` 20 kg). Everything else (DOP, recipes, recalls, posts) always needs a person.
- pg_cron `fabula_rota_autocopy` (Saturday): next week's rota is copied from this week when still empty.
- Test: `tools/go-live/drill/prod-test/test_auto_approve.sql` (14).

## Placeholder customers and routine messages (v0.72)
- `confirm_standing_orders` (wholesale bot and its database stand-in) does not book the standing orders of a placeholder customer
  (`fabula.is_placeholder_party`: parties.notes/source = 'placeholder', i.e. "Cliente 1/2" not yet renamed); their unshipped
  orders are cancelled at every run (`fabula.cancel_placeholder_orders`). Renaming the customer in the console clears the flag
  and booking resumes. Before, they added fake wholesale demand to the milk plan and piled up in Da spedire.
- pg_cron `fabula_bot_messages_autoread` (hourly :17): info messages older than 24 h are marked read; warnings and alerts stay.
- Test: `tools/go-live/drill/prod-test/test_placeholders_autoread.sql` (7).

## Packing on autopilot (v0.71)
- `fabula.packing_plan(date)` (tablet → 🚚 Da spedire): orders in packing order (late first, then due date, wholesale before
  online on the same day) with lots already allocated — oldest in-date first (FEFO), a line split over lots when one is not
  enough, allocated across the whole list so no kg is promised twice — plus the cold-room pick list (product · lot · kg ·
  orders), late days and kg short. Lots on food-safety hold, expired, or with less life left than the channel needs
  (`ship.min_days_left_online` 2, `ship.min_days_left_wholesale` 1) are never allocated and are shown as "Non usare".
- Pack form: one row per allocated lot, already filled in; scanning a held or expired lot is refused on the spot.
- `pack_order` (same signature): held or expired lot → refused, no override; short stock, short shelf life and weight outside
  `ship.tolerance_pct` → `needs_confirm` with `reasons`, saved on the second Salva and written on the shipment ("Confermato: …").
  The weight confirmation no longer skips the stock check. An online order with no customer gets a consignee from the
  Shopify shipping name instead of failing.
- Tests: `tools/go-live/drill/prod-test/test_packing.sql` (14), `tools/go-live/drill/tablet-test/pack_e2e.py` (14).

## Production autopilot (v0.70)
- `fabula.production_plan(date)` (tablet Home → "Produzione di oggi"): for each accepted milk delivery with kg not yet in a batch
  (oldest first) the batches to make — equal vat loads (`prod.vat_kg`, 800), mozzarella with its default preset, start doses
  from the recipe, expected kg from `fabula.expected_yield` (preset's last 10 batches if ≥ 3, else product's last 30 days if
  ≥ 3, else `sales.yield_pct` 30 % / ricotta `prod.ricotta_yield_pct` 10 %), whey and ricotta, the 60 h DOP deadline (from
  arrival or shipment), plus open batches, today's output and the approved milk-plan target. Read-only, `require_perm(produzione, 1)`.
- Tablet: one tap on a proposal opens the batch start filled in (kg, product, preset, expected kg); more kg than is left on
  the lot asks to confirm; the plan is kept on the tablet, so a load can be started offline (and leaves the kept plan).
  Closing shows the expected kg and asks once to confirm a yield more than `prod.yield_tolerance_pts` (4) points off.
- Database: closing stores `yield_expected_pct`; a yield outside the tolerance sets `yield_flag` bassa/alta and posts a
  message from "Zio Ciro · Resa produzione" (agent `produzione`, its own card in Configurazione → Bot).
- Tests: `tools/go-live/drill/prod-test/test_production_plan.sql` (19), `tools/go-live/drill/tablet-test/prod_e2e.py` (13).
- `prod.vat_kg` = capacity of the Fortino mini caseificio ("TINO"), not yet read: 800 is a placeholder (the Fortino 800 L offer in
  the project is a reference quote, not the machine in the sale — v0.70c). Machine tags from the 05/10 site photos are in `fabula.equipment`.

## Self-healing bots (v0.69)
- pg_cron `fabula_bot_fallback` (every 5 min) runs `fabula.bot_fallback()`: when a bot in `fabula.bot_fallback_agents()` has not
  started 45 min (`bot_schedule.grace_min`) after its due time, and up to 6 h after it, the database runs that bot's own function
  once: `plan_milk` (Piano latte), `propose_purchase_orders` (Acquisti), `confirm_standing_orders` (Ordini ingrosso),
  `haccp_evening_status` (tablet banner), `ops_health_check` (+ `infra_checks`), `sell_down_signals` (no Shopify code: counter
  only), and re-sends the nightly backup. All of them skip work already done, so a late bot is harmless.
- Each stand-in run: one row in `fabula.bot_fallback_runs` (agent, slot), an `agent_runs` row with `details.via = 'db_fallback'`
  (not for the backup, which logs itself), and a message "Sostituito dal database · …" in Configurazione → Bot. A failure is an
  `agent_runs` error, so the alarm bot reports it. `bot_watchdog` waits 20 extra minutes for these bots.
- Not covered (they need Shopify or write text): Shopify sync, briefs, marketing, sales, deadlines — the heartbeat/alarm stay.
- Switch off: setting `bots.db_fallback` = 0. Nightly backup: `fabula_backup_nightly` fires 19:15 and 20:15 UTC and
  `backup_nightly_rome()` only sends at 21:xx Rome, so it stays at 21:15 after the clocks change.
- Test: `tools/go-live/drill/infra-test/test_bot_fallback.sql` (22 checks).

## Infra & security autopilot (v0.68)
- **Hourly monitor** (pg_cron `fabula_infra_probe` :40 → `fabula_infra_collect` :43 UTC): reads GitHub main of the public repo
  (`infra.github_repo`: migration list, `fabula-tablet/sw.js`, last commit), the Netlify site (`infra.site_url` → `/sw.js`) and
  the `farm-order` / `backup-export` functions (a wrong token must give 403). Results in `fabula.infra_status`.
- **Board checks now automatic** (`fabula.infra_checks()`): code_pushed (every live migration is on GitHub), repo_sync (exact match),
  app_deployed (Netlify serves the sw version on GitHub), restore_tested (an ok `agent_runs` row `restore_drill` in the last
  100 days), advisors_clean, uptime. Never tick these by hand: push, deploy or run the drill and the board follows within an hour.
- **Notices**: `infra_uptime` (alert, down on 2 checks in a row), `infra_drift` (GitHub / Netlify / live database out of step > 6 h),
  `infra_security`, `infra_advisors`.
- **Security scan** `fabula.security_scan()` (hourly): the Supabase security-advisor lints in SQL + anon table grants + public buckets.
  Anything not in `fabula.security_accepted` raises `infra_security`. A deliberate exception gets a row there (key `<lint>:<object>`,
  reason) in a migration. `create or replace view` drops `security_invoker` — always write `with (security_invoker = true)`.
  The nightly system-check bot sends the real advisor's lint counts to `fabula.infra_record_advisors()`, which flags lints the SQL
  scan doesn't cover (accept with key `advisor:<lint>`) or counts that differ.
- **Backup v3** adds `auth_users` (no passwords) and `storage_manifest` to every file (`restore_backup.py logins|files`).
- One-time paste for Nick: `tools/go-live/sql-editor/save_ledger_trim.sql`. Test kit: `tools/go-live/drill/infra-test/`.

## Manuale di Autocontrollo (v0.57)
- The legally required HACCP self-control manual is the Claude Doc "Manuale di Autocontrollo — Caseificio di Agropoli"
  (link in setting `food.manuale_url`; revision/date/status in `food.manuale_rev`, `food.manuale_data`, `food.manuale_stato`).
  It replaces the old "Piano HACCP — La Perla del Cilento" doc (written for raw milk).
- Every HACCP record belongs to one of the manual's 23 forms `fabula.haccp_forms` (MOD-01…MOD-23, with manual section).
  `haccp_control_points.form_code` and `task_schedules.form_code` map controls and tasks to their form.
- `fabula.haccp_register(form, from, to)` builds the register of a form for a period with the manual header; `fabula.manual_ref(form)`
  gives the reference line ("MOD-05 · Manuale di Autocontrollo rev. 0 del 04/10/2026 (bozza) · §7.8 · §8.2").
  `fabula-tablet/registro.html?mod=MOD-05&from=…&to=…[&blank=1]` prints it (blank = paper form when the tablet is down).
- Console HACCP → Registri: all forms, records in 30 days, print, and the responsible's weekly "Verificato"
  (`mark_register_reviewed` → `haccp_register_reviews`, shown on every printed register).
- New controls required by the manual: PRP-PAST-VALVE (pasteuriser start-of-day check, MOD-02, task T-VALVE), PRP-INNESTO (MOD-03),
  PRP-BRINE (MOD-17, task T-BRINE). Goods receipt now records the arrival check (`goods_receipts.inspection_ok`, `record_receipt_check`,
  NC when not conforming, MOD-15).
- A new HACCP record type must get a form: add/choose a `haccp_forms` row and a branch in `haccp_register()`; never leave a record without a MOD.

## Console and Configurazione (v0.51)
- Both pages share `fabula-tablet/ui.js` + `ui.css` (login, header with page links / Bot bell / user menu, lazy tabs, helpers). Add new
  console or config features there instead of copying helpers into a page.
- Configurazione → Parametri lists **every** `settings` row, grouped by key prefix (`SECTIONS` in `admin.js`); a new prefix appears under
  "Altri parametri" automatically, so a setting can never be hidden again. 0/1 settings whose description says "(1 = sì, 0 = …)" show as Sì/No;
  descriptions containing AAAA-MM-GG / AAAA-MM-01 get a date / month picker.
- Bot schedules are shown only from `bot_schedule` (via `v_bot_dashboard`); there is no hand-typed schedule table any more.
