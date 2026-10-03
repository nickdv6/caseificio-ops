# caseificio-ops — La Perla del Cilento

Operations system for the Agropoli micro-dairy (ex Latteria Fabula).

- `supabase/migrations/` — database schema. File names are `<14-digit version>_<name>.sql` and match
  `supabase_migrations.schema_migrations` on the live project (history repaired in v0.39), so
  `supabase db push` / `supabase migration list` work. New changes: always as a new migration file
  (or via the Supabase MCP `apply_migration`, then save the same SQL here with the version it got).
- `fabula-tablet/` — floor PWA, console, HACCP and marketing pages (see its README). Libraries are vendored in
  `fabula-tablet/vendor/` so the tablet starts without internet.
- `sop/` — printable floor procedure sheet.
- `tools/legacy-patches/` — one-off scripts used to patch the app in v0.25–v0.29 (kept for history, not needed).

Deploy the tablet app by pointing Netlify / Cloudflare Pages at the `fabula-tablet` folder.

## Operating decisions encoded in the database (v0.39)
- Milk price: setting `milk.price_eur_kg` (1.70). Every intake without a price takes it; all cost reports read it.
- Milk is **pasteurised** (`food.milk_process` = pastorizzato): CCP 2 is required on every mozzarella lot.
- Website and Shopify POS sell even at zero stock ("continue selling"); `shopify.push_inventory` = 0.
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
