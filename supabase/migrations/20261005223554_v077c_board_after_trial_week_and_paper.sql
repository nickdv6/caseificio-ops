-- v0.77c (05/10/2026) · board after the trial-week check, paper back-entry and console recall drill (same-day update: `prev` untouched).
insert into fabula.dash_checks (key, sort, label, kind, done, note, updated_at) values
 ('paper_fallback', 25, 'Paper sheets ready for tablet or Wi-Fi outages', 'manual', false, 'Print the blank MOD sheets (Manuale → Registri → Modulo vuoto: 01, 02, 03, 05, 06) and keep them by the line. Typed in later from the tablet: 🛡 → Ricopia da foglio di carta (keeps the sheet''s date and time, up to 7 days).', now())
on conflict (key) do update set note = excluded.note, updated_at = excluded.updated_at;

insert into fabula.dash_areas (area, sort, built, reliable, automated, next_step, evidence, updated_at) values
 ('Compliance & HACCP', 7, 0, 77, 0, '', 'v0.77: checks written on paper during an outage are typed in with the sheet''s time (source paper, who wrote it, who copied it) and get the same limits, NCs and lot holds; recall drill can be run from the console (MOD-14).', now()),
 ('Production floor', 12, 0, 80, 0, 'Fortino capacity → prod.vat_kg (800 is a placeholder); casaro confirms the 6 doses and presets; set trial.start and run the "Settimana di prova" (5 days, evening check by Zia Carmela)', 'v0.77: trial-week evening check of every day''s records (fabula.trial_check), posted at 20:35 Rome during the trial.', now())
on conflict (area) do update
   set reliable = greatest(dash_areas.reliable, excluded.reliable),
       next_step = case when excluded.next_step <> '' then excluded.next_step else dash_areas.next_step end,
       evidence = case when dash_areas.evidence like '%v0.77:%' then dash_areas.evidence else dash_areas.evidence || ' ' || excluded.evidence end,
       updated_at = excluded.updated_at;
