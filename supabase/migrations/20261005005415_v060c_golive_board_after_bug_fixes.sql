-- v0.60c (05/10/2026) · go-live board after the v0.60 bug-report fixes (app sw perla-v34). Same-day update: `prev` stays on the 3 Oct audit.
insert into fabula.dash_areas(area, sort, built, reliable, automated, next_step, evidence, updated_at) values
 ('Reports & briefs', 1, 92, 78, 90,
  'Read the first weekly brief Mon 5 Oct (benchmark ≈ €2,869/week)',
  'Daily, weekly and monthly briefs run on schedule; monthly review can no longer close the running month (v059b); accountant pack badge and default month fixed (v0.60).', now()),
 ('B2B sales pipeline', 3, 85, 64, 50,
  'Vendite bot first run Mon 5 Oct 08:04; set sales.plan_start; start working the 45 leads (all still nuovo)',
  'v0.44 module, 45 seeded prospects, Vendite bot scheduled Mon/Wed/Fri but never run. v0.60: chosen stage kept on new leads, one WhatsApp prefix rule, lead notes escaped. Calls and tastings stay human.', now()),
 ('Inventory & lots', 4, 88, 78, 70,
  'Post the opening stock count on the tablet',
  'Printable lot labels, lot guard and hold filter live. v0.60: stock-count form accepts real quantities; lot dates and expiry use the Agropoli date; lot look-ups ignore case.', now()),
 ('Milk plan & intake', 5, 92, 75, 60,
  'First real intake from the station QR; confirm Masseria daily kg',
  'Station QR + DDT number, rejected milk refused at scan and in the DB, milk price €1.70. v0.60: a reused tank id gets a dated lot code instead of breaking the save; milk intake works offline from cached suppliers.', now()),
 ('Procurement', 6, 86, 61, 55,
  'Replace the 3 placeholder suppliers with real ones, prices and reorder points',
  'Arrival check on goods receipt (v0.57). v0.60: a re-sent receipt no longer runs twice. Acquisti bot proposes nothing until suppliers and prices are real.', now()),
 ('Compliance & HACCP', 7, 90, 68, 60,
  'Consultant signs the Manuale (rev 0 bozza); date 8 deadlines; calibrate pasteuriser, 2 scales, reference thermometer',
  'Manuale di Autocontrollo with 23 MOD forms and registers. v0.60: pest visit works for HACCP level 2; releasing a lot and closing an NC need HACCP 3 in the database; HACCP saves never fail silently and work offline. Manual still a draft.', now()),
 ('Marketing', 8, 72, 52, 55,
  'Opening date, Predis keys, BENVENUTO10',
  'Module and bot built; nothing live yet. v0.60: Marketing profile can save mkt.* settings; edited approved posts go back to review; Predis needs Marketing ≥ 2 and recovers from network errors; no duplicate draft media.', now()),
 ('Fulfilment & shipping', 9, 86, 66, 45,
  'Pack one order end to end on the tablet and print the DDT (4 wholesale orders from placeholder customers are queued)',
  'Pack, scale, DDT and Shopify fulfilment built; no shipment yet. v0.60: weight confirmation re-armed by any change; shipment lines safe on re-send. Multi-step saves still not fully atomic.', now()),
 ('Staff & rota', 10, 88, 64, 45,
  'Invite the Celsos and floor staff (1 of 3 can log in)',
  'Badge printing, rota, hours, certificates. v0.60: In turno visible to floor profiles; the last titolare can no longer demote himself; fast rota clicks safe.', now()),
 ('Production floor', 12, 88, 64, 25,
  'Casaro confirms the 6 placeholder doses and presets; record the first real batch',
  'Opens offline with the saved profile; v0.60: Enter saves, a failed close can be retried, batch letters from today''s lots, profile checked before each scan. Batch start/close still needs the network. 0 real batches.', now()),
 ('Infra & security', 13, 90, 82, 88,
  'Test a restore from the nightly backup',
  'XSS fixed, repo = live (76→81 migrations, clean replay), backups locked and now paged in a stable order (verified live), search_path advisors cleared, invite e-mail exact match. Restore never tested.', now())
on conflict (area) do update
   set built = excluded.built, reliable = excluded.reliable, automated = excluded.automated,
       next_step = excluded.next_step, evidence = excluded.evidence, updated_at = excluded.updated_at;

insert into fabula.dash_checks(key, sort, label, kind, done, note) values
 ('code_pushed',  2, 'Latest code pushed to GitHub',             'manual', true, 'v0.60 on GitHub, 05/10'),
 ('app_deployed', 3, 'Tablet app redeployed (sw perla-v34)',     'manual', true, 'Netlify auto-deploy, sw perla-v34'),
 ('fix_first',    5, 'Fix-first bugs closed',                    'manual', true, 'All 11 closed 05/10 (v0.55–v0.60). Still open from the full report: fully atomic multi-step tablet saves')
on conflict (key) do update
   set label = excluded.label, done = excluded.done, note = excluded.note, updated_at = now();
