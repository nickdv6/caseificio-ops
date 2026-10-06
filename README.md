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
- `sop/` — printable floor procedure sheet.
- `tools/legacy-patches/` — one-off scripts used to patch the app in v0.25–v0.29 (kept for history, not needed).

Deploy the tablet app by pointing Netlify / Cloudflare Pages at the `fabula-tablet` folder.

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
  (edge function `farm-order`, no login; change the setting to switch an old link off). The farm taps "Visto"; the Console
  shows the next order and whether it was seen, with the link to copy.
- Masseria shipments (v0.65): the farm records each load on its page (QR poster: latte.html?t=…&stampa=1 → opens
  `&azione=spedizione`); the farm's kg is the source of truth and each load gets a lot M<yymmdd>-<n>. The tablet's milk
  intake lists loads still in transit: picking one locks kg/lot/supplier (trigger `milk_intake_shipment_check` enforces it
  and blocks a second receipt); saving marks the load received or rejected, which the farm sees on its page.
- Sell-down promos (v0.64): the sell-down bot pre-creates a random Shopify code per promo it proposes (ends 20:00); the tablet
  shows it only once Nick approves; approving writes two approved posts (WhatsApp "oggi al banco", Instagram story).
- Consorzio DOP declaration (v0.63): pg_cron runs `consorzio_declaration()` on the 1st (05:30 UTC); it lands in Console → Oggi
  with the disciplinare checks (60 h, fat/protein, DOP suppliers, traceability) and a fee estimate (`dop.consorzio_eur_kg`, estimate).
  Approving it closes the month's T-DOP task. Sending it to the Consorzio stays manual until the official format is known.
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
  handle @laperladelcilento are accounts, not the name, and stay.

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
