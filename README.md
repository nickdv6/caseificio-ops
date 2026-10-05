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
