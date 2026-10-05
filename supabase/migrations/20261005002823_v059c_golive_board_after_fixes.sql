-- v0.59c (05/10/2026) · go-live board after the v0.59 fixes (XSS, offline start, migration history, monthly review,
-- benchmark, milk price; tablet app redeployed as sw perla-v33). Same-day update: `prev` stays on the 3 Oct audit.
insert into fabula.dash_areas(area, sort, built, reliable, automated, next_step, evidence, updated_at) values
 ('Reports & briefs', 1, 92, 74, 90,
  'Read the first weekly brief Mon 5 Oct (benchmark now ≈ €2,869/week); fix the accountant pack SIMULAZIONE badge',
  'Daily, weekly and monthly briefs run on schedule. v059b: monthly review can no longer close the month in progress; weekly benchmark 149,200/yr. Open: accountant pack always shows SIMULAZIONE.', now()),
 ('Sales & orders', 2, 82, 73, 80,
  'Shopify catalog decisions; RT printer once the P.IVA is final',
  'Shopify customers/orders sync daily without errors; held and expired lots no longer sold online (v055); Shopify customer data escaped on the tablet (v0.59).', now()),
 ('B2B sales pipeline', 3, 85, 58, 50,
  'Vendite bot first run Mon 5 Oct 08:04; set sales.plan_start; start working the 45 leads (all still nuovo)',
  'v0.44: 5-channel targets, Vendite page, 45 seeded prospects, Vendite bot scheduled Mon/Wed/Fri but never run. Lead notes escaped and only http(s) links (v0.59). Open: new leads ignore stage, WhatsApp prefix. Calls and tastings stay human.', now()),
 ('Milk plan & intake', 5, 92, 70, 60,
  'First real intake from the station QR; fix the reused tank id (T1) intake error; confirm Masseria daily kg',
  'Station QR + DDT number (v0.53), rejected milk refused at scan and in the DB (v055), milk price back to €1.70 (v059b). Piano latte runs nightly. A reused milk lot id breaks intake and can double-save.', now()),
 ('Fulfilment & shipping', 9, 86, 62, 45,
  'Pack one order end to end on the tablet and print the DDT (4 wholesale orders from placeholder customers are queued)',
  'Pack, scale, DDT and Shopify fulfilment built; no shipment yet; Da spedire list escaped (v0.59). Multi-step saves are not atomic; a weight override stays on for later saves.', now()),
 ('Production floor', 12, 88, 58, 25,
  'Casaro confirms the 6 placeholder doses and presets; fix Enter-reload on single-field forms before the first batch',
  'Plain-language tablet messages, ricotta tino label, rejected-milk stop, resume keeps its preset; opens offline with the saved profile (v0.59). Open: Enter reloads single-field forms, last dosing step can freeze. 0 real batches.', now()),
 ('Infra & security', 13, 90, 78, 88,
  'Test a restore from the nightly backup; pin search_path on the 5 flagged functions',
  'v0.59: stored XSS fixed and deployed (sw perla-v33); repo 76 migrations = live 76 and a clean replay matches the live schema; backups locked to the backup job; leaked-password protection on. Open: restore never tested, 5 functions with mutable search_path.', now())
on conflict (area) do update
   set built = excluded.built, reliable = excluded.reliable, automated = excluded.automated,
       next_step = excluded.next_step, evidence = excluded.evidence, updated_at = excluded.updated_at;

insert into fabula.dash_checks(key, sort, label, kind, done, note) values
 ('code_pushed',  2, 'Latest code pushed to GitHub',             'manual', true,  'v0.59 (3c3aa06) on GitHub, 05/10'),
 ('app_deployed', 3, 'Tablet app redeployed (sw perla-v33)',     'manual', true,  'Netlify auto-deploy verified 05/10: sw perla-v33 live, offline start + XSS fixes served'),
 ('fix_first',    5, 'Fix-first bugs closed',                    'manual', false, 'Closed 05/10: XSS (3 places), offline start. Open: form step / Enter reload (bug 10), accountant pack badge (bug 11)'),
 ('repo_sync',    6, 'Repo migrations match the live database',  'manual', true,  '76 files = 76 live versions; clean replay matches live (05/10, v0.59)')
on conflict (key) do update
   set label = excluded.label, done = excluded.done, note = excluded.note, updated_at = now();
