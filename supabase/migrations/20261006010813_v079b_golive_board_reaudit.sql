-- v0.79b (06/10/2026) · go-live board RE-AUDIT (new baseline: `prev` = the scores before this audit, 05/10 evening).
-- Rubric, stated so the next audit uses the same yardstick:
--   built     = share of the area's planned features that exist and pass their tests
--   reliable  = how far the area can be trusted on opening day: tested end to end and running clean on schedule tops out
--               around 75 until it has handled real transactions; opening gates still open (approvals, signatures,
--               placeholder data) and defects found by the review count against it
--   automated = share of the area's routine work done without a person
-- Inputs: live data (0 real milk, batches, shipments, orders; 2 milk plans; 45 leads all new), bot health 38/38 runs
-- 1–5 Oct, all infra checks green, security scan clean, every tablet and SQL suite passing on a fresh copy, and an
-- independent code review of v0.69–v0.78 (5 defects: 2 medium, 3 low; fixed in v0.79a and the tablet, none high).
insert into fabula.dash_areas(area, sort, built, reliable, automated, next_step, evidence, updated_at) values
 ('Reports & briefs', 1, 92, 76, 90,
  'Read the first weekly brief built on a real week (after the trial week); check its numbers against the till and the tablet',
  'Re-audit 06/10: daily, weekly and monthly briefs ran on every scheduled day (bot health 38/38, 1–5 Oct); weekly benchmark follows the agreed lease (≈ €2,902/week). Only ever run on empty data.', now()),
 ('Sales & orders', 2, 85, 70, 83,
  'Opening stock count (starts the Shopify stock sync); Shopify catalog decisions; order the Epson RT printer in Masseria''s name',
  'Re-audit 06/10: Shopify customers and orders sync daily without errors; one stock-sync error on 05/10 13:53, next runs clean. No real order yet; stock sync waits for the opening count; no fiscal printer.', now()),
 ('B2B sales pipeline', 3, 85, 60, 50,
  'Set sales.plan_start with the opening date; work the 45 leads (log calls and tastings in Vendite)',
  'Re-audit 06/10: Vendite bot first run 05/10 08:05, clean. 45 leads, all still nuovo, 0 activities logged: nothing has been worked yet.', now()),
 ('Inventory & lots', 4, 90, 72, 77,
  'Post the opening stock count on the tablet',
  'Re-audit 06/10: FEFO allocation, held and expired lots refused at packing and at the tablet (also offline), sell-down promos approve themselves. 0 stock moves and no stock count yet.', now()),
 ('Milk plan & intake', 5, 94, 74, 80,
  'Print the shipment QR for the farm and send it the page link; first real load from the farm (trial week day 1)',
  'Re-audit 06/10: farm order page and shipment QR, nightly plan (5 runs, clean), routine plans approve themselves within ±15 %. 0 real deliveries; plans so far are from no sales history.', now()),
 ('Procurement', 6, 86, 58, 62,
  'Replace the 3 placeholder suppliers with real ones, prices and reorder points',
  'Re-audit 06/10: Acquisti bot runs clean but has nothing to propose: all suppliers are placeholders, so the routine-order auto-approval can never trigger. 0 purchase orders.', now()),
 ('Compliance & HACCP', 7, 92, 68, 66,
  'CE approval and SCIA in Masseria''s name; RINA adhesion and Consorzio marks; HACCP training for the three partners; consultant signs the Manuale; calibrate the pasteuriser, 2 scales and reference thermometer; MOZ-DOP moisture test',
  'Re-audit 06/10: Manuale with 23 MOD forms, printable registers, paper back-up with the sheet''s time, trial-week evening check, recall drill in the console, all tested. Opening gates open: Manuale unsigned (rev 0 bozza), 0 training records (6 required courses missing), 4 machines uncalibrated, no CE approval or RINA adhesion in Masseria''s name, no lab result.', now()),
 ('Marketing', 8, 73, 50, 58,
  'Opening date, Predis keys, BENVENUTO10',
  'Re-audit 06/10: module and bot built, bot runs clean; nothing published, no opening date, no Predis keys.', now()),
 ('Fulfilment & shipping', 9, 91, 72, 65,
  'Pack one real order from Da spedire and print the DDT (trial week day 3); replace the placeholder wholesale customers',
  'Re-audit 06/10: packing pre-filled by FEFO with refusals and confirmations, DDT, Shopify fulfilment, direct shipment offline. Review found a split line could not be packed when one lot was set to 0 (fixed 06/10). 0 shipments.', now()),
 ('Staff & rota', 10, 88, 60, 52,
  'Emilio Celso logs in; HACCP training records for all three; first rota (it copies itself every Saturday from then on)',
  'Re-audit 06/10: 2 of 3 partners can log in; rota autocopy and badge clock-in built and tested. 0 rota entries, 0 shifts, 0 training records.', now()),
 ('Finance & e-invoicing', 11, 40, 40, 35,
  'Commercialista answers the IVA regime and numbering questions; PEC and SDI code; Fatture in Cloud in Masseria''s name, then build the invoicing bot; bank feed',
  'Re-audit 06/10: unchanged. Spec only: 0 invoices, no SDI link, no payout reconciliation. Lease cost and benchmark now at the agreed rent.', now()),
 ('Production floor', 12, 94, 70, 52,
  'Fortino capacity → prod.vat_kg (800 is a placeholder); casaro confirms the 6 doses and presets; set trial.start and run the Settimana di prova',
  'Re-audit 06/10: daily plan with equal vat loads, expected yield and out-of-range flag, start and close fully offline, paper back-up, trial-week check; review found no defect here. 0 real batches; vat size and all 6 doses are placeholders.', now()),
 ('Infra & security', 13, 97, 93, 96,
  'Run the outside watcher once from GitHub (Actions → Outside watcher → Run workflow) and check GitHub e-mails you on failures; restore drill every 3 months (next 5 Jan 2027)',
  'Re-audit 06/10: all six infra checks green, restore drilled 05/10, nightly + 2-hourly backups clean, security scan clean, bots stand in for each other, pg_cron watched. Review found 3 monitoring defects (a 2-hourly backup hid a missing nightly in summer, the old-app warning could never fire, a health false alarm), fixed in v0.79a. Outside watcher pushed but GitHub has not run it yet.', now())
on conflict (area) do update
   set prev = jsonb_build_object('built', fabula.dash_areas.built, 'reliable', fabula.dash_areas.reliable,
                                 'automated', fabula.dash_areas.automated, 'at', fabula.dash_areas.updated_at),
       sort = excluded.sort, built = excluded.built, reliable = excluded.reliable, automated = excluded.automated,
       next_step = excluded.next_step, evidence = excluded.evidence, updated_at = excluded.updated_at;

-- one new system check: the outside watcher has run on GitHub (manual until it has)
insert into fabula.dash_checks (key, sort, label, kind, done, note, updated_at) values
 ('outside_watcher', 42, 'Outside watcher running on GitHub', 'manual', false, 'GitHub → caseificio-ops → Actions → Outside watcher → Run workflow once; then check GitHub → Settings → Notifications → Actions (e-mail on failed workflows).', now())
on conflict (key) do nothing;
