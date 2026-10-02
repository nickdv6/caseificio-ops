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
