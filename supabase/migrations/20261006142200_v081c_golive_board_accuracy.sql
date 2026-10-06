-- v0.81c (06/10/2026) · go-live board accuracy pass after v0.81. Text only: no scores changed, `prev` untouched.

-- 1. Vat capacity: confirmed 300 L Fortino (Nick, 06/10) -> prod.vat_kg 310 (set 06/10 15:41 Agropoli). Remove the "800 provisional" wording.
update fabula.dash_checks
   set note = 'Fortino in the sale is 300 L (Nick, 06/10) → 310 kg of milk per batch (300 L × 1.035). The daily cap milk.capacity_kg is still 1,200 kg ≈ 4 batches: review it once the casaro times a real cycle.'
 where key = 'vat_capacity';

update fabula.settings
   set description = 'Latte per lotto (kg) = capacità del mini caseificio Fortino ("TINO"): 300 L × 1,035 ≈ 310 kg (confermato da Nick 06/10). Il preventivo Fortino 800 L era per una macchina nuova, non quella in vendita.'
 where key = 'prod.vat_kg';

update fabula.equipment
   set notes = replace(notes,
         'DA RILEVARE: modello, matricola, anno, capacità in litri (targa non fotografata)',
         'Capacità 300 L (confermata da Nick 06/10) = 310 kg di latte per lotto (prod.vat_kg). DA RILEVARE: modello, matricola, anno (targa non fotografata)')
 where code = 'TINO-01';

update fabula.dash_areas
   set next_step = 'Casaro confirms the 6 doses and presets and times one real 310 kg cycle (then set milk.capacity_kg, now 1,200 kg ≈ 4 batches a day); set trial.start and run the Settimana di prova',
       evidence  = 'Re-audit 06/10 + v0.80: daily plan with equal vat loads, expected yield and out-of-range flag, start and close fully offline, paper back-up, trial-week check. v0.80 guard rails: CCP steps ask for the value read and cannot be skipped; the first batch of the day asks for the pasteuriser valve check (a failed valve stops the batch); CCP 2/3/4 are asked at start or close when missing; a batch closed without its CCP records alerts Zio Ciro; 19:45 watch for batches left open and milk 48 h old or more (60 h DOP limit). Vat size set 06/10: Fortino 300 L → 310 kg per batch, so the 1,200 kg daily cap means 4 batches (the equipment review assumed 2–3 per shift until a cycle is timed). 0 real batches; all 6 doses are placeholders.',
       updated_at = now()
 where area = 'Production floor';

-- 2. Staff: v0.81 showed only 1 of 3 has actually signed in.
update fabula.dash_areas
   set next_step = 'Nicola Celso opens the newest invite e-mail and sets a password (link valid until 07/10 15:57 Agropoli); invite Emilio Celso; HACCP training records for all three; first rota (it copies itself every Saturday from then on)',
       evidence  = 'Re-audit 06/10 + v0.81: 1 of 3 partners has signed in (Nick). Nicola re-invited 06/10 with a 24 h link, not yet accepted; Emilio not yet invited. (Earlier "2 of 3" counted an invite sent as a login.) Rota autocopy and badge clock-in built and tested. 0 rota entries, 0 shifts, 0 training records.',
       updated_at = now()
 where area = 'Staff & rota';

-- 3. Infra: the outside watcher has run, but GitHub's scheduler starts it far less often than every 30 min.
update fabula.dash_checks
   set note = 'Runs on GitHub (first run 06/10, manual, success) and e-mails Nick on a failed run. Scheduled for every 30 min, but it ran only 3 times between 02:00 and 16:20 Agropoli on 06/10 (03:14 manual, then scheduled at 07:52 and 15:08): gaps of up to 7 h.'
 where key = 'outside_watcher';

update fabula.dash_areas
   set next_step = 'Make the outside check frequent: GitHub''s scheduler skipped most 30-min runs on 06/10 (3 runs in 13 h). Add an external pinger on fabula_health (e.g. UptimeRobot or healthchecks.io) or accept multi-hour gaps; restore drill every 3 months (next 5 Jan 2027)',
       evidence  = 'Re-audit 06/10: all six infra checks green, restore drilled 05/10, nightly + 2-hourly backups clean, security scan clean (v0.81b: staff_logins and the 24 h OTP accepted), bots stand in for each other, pg_cron watched. Review found 3 monitoring defects (a 2-hourly backup hid a missing nightly in summer, the old-app warning could never fire, a health false alarm), fixed in v0.79a. Outside watcher runs on GitHub, but only 3 times in 13 h on 06/10 instead of every 30 min.',
       updated_at = now()
 where area = 'Infra & security';
