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
