-- v0.80b (06/10/2026) · go-live board, same-day update after v0.80 (production floor guard rails). `prev` untouched.
insert into fabula.dash_areas(area, sort, built, reliable, automated, next_step, evidence, updated_at) values
 ('Production floor', 12, 96, 73, 56,
  'Fortino capacity → prod.vat_kg (800 is a placeholder); casaro confirms the 6 doses and presets; set trial.start and run the Settimana di prova',
  'Re-audit 06/10 + v0.80: daily plan with equal vat loads, expected yield and out-of-range flag, start and close fully offline, paper back-up, trial-week check. v0.80 guard rails: CCP steps ask for the value read and cannot be skipped; the first batch of the day asks for the pasteuriser valve check (a failed valve stops the batch); CCP 2/3/4 are asked at start or close when missing; a batch closed without its CCP records alerts Zio Ciro; 19:45 watch for batches left open and milk 48 h old or more (60 h DOP limit). 0 real batches; vat size and all 6 doses are placeholders.', now()),
 ('Compliance & HACCP', 7, 92, 69, 68,
  'CE approval and SCIA in Masseria''s name; RINA adhesion and Consorzio marks; HACCP training for the three partners; consultant signs the Manuale; calibrate the pasteuriser, 2 scales and reference thermometer; MOZ-DOP moisture test',
  'Re-audit 06/10 + v0.80: Manuale with 23 MOD forms, printable registers, paper back-up with the sheet''s time, trial-week evening check, recall drill in the console, all tested; every closed batch now carries its CCP records or raises an alert. Opening gates open: Manuale unsigned (rev 0 bozza), 0 training records (6 required courses missing), 4 machines uncalibrated, no CE approval or RINA adhesion in Masseria''s name, no lab result.', now())
on conflict (area) do update
   set sort = excluded.sort, built = excluded.built, reliable = excluded.reliable, automated = excluded.automated,
       next_step = excluded.next_step, evidence = excluded.evidence, updated_at = excluded.updated_at;
