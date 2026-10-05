-- v0.62b (05/10/2026) · go-live board after the reliability work (atomic exactly-once saves, ordered queue, offline batches; sw perla-v35).
-- Same-day update: `prev` stays on the 3 Oct audit.
insert into fabula.dash_areas(area, sort, built, reliable, automated, next_step, evidence, updated_at) values
 ('Milk plan & intake', 5, 92, 78, 60,
  'First real intake from the station QR; confirm Masseria daily kg',
  'Station QR + DDT number, rejected milk refused at scan and in the DB, milk price €1.70, reused tank ids get a dated lot code. v0.62: the 5-step intake (scan, intake, label, 2 CCP) is one transaction and is written once even if the reply is lost; a lot received offline can start a batch offline.', now()),
 ('Fulfilment & shipping', 9, 86, 70, 45,
  'Pack one order end to end on the tablet and print the DDT (4 wholesale orders from placeholder customers are queued)',
  'Pack, scale, DDT and Shopify fulfilment built; no shipment yet. Weight confirmation re-armed by any change (v0.60). v0.62: direct shipments (shipment + line + stock move) and goods receipts save in one transaction, exactly once.', now()),
 ('Production floor', 12, 90, 72, 25,
  'Casaro confirms the 6 placeholder doses and presets; record the first real batch',
  'Opens offline with the saved profile. v0.62: lot scans, batch start, dosing and process steps and batch close work with no network (tablet copy + queue) and are sent in order when it is back; every batch save is one transaction, written once. Tested end to end against a copy with the real role policies. Still online: ricotta started offline closes when back online. 0 real batches.', now()),
 ('Infra & security', 13, 93, 88, 88,
  'Repeat the restore drill every 3 months (next 5 Jan 2027, scheduled); keep a list of logins and secrets to re-create after a restore',
  'XSS fixed, repo = live (clean replay), search_path advisors cleared. Restore drill 05/10: 93/93 tables and 1,017 rows match live, 154 foreign keys clean, partial and full restore work. v0.62: tablet saves go through fabula.save_ops (one transaction, RLS as the user, whitelisted tables/RPCs, exactly-once ledger); reliability test kit in tools/go-live/drill/tablet-test. Logins, Storage files and secrets are not in the backup.', now())
on conflict (area) do update
   set built = excluded.built, reliable = excluded.reliable, automated = excluded.automated,
       next_step = excluded.next_step, evidence = excluded.evidence, updated_at = excluded.updated_at;

insert into fabula.dash_checks(key, sort, label, kind, done, note) values
 ('code_pushed',  2, 'Latest code pushed to GitHub',             'manual', true, 'v0.62 on GitHub, 05/10'),
 ('app_deployed', 3, 'Tablet app redeployed (sw perla-v35)',     'manual', true, 'Netlify auto-deploy, perla-v35 verified live 05/10'),
 ('fix_first',    5, 'Fix-first bugs closed',                    'manual', true, 'All 11 closed 05/10 (v0.55–v0.60); atomic multi-step saves done in v0.62'),
 ('repo_sync',    6, 'Repo migrations match the live database',  'manual', true, '86 files = 86 live versions (05/10, v0.62)')
on conflict (key) do update
   set label = excluded.label, done = excluded.done, note = excluded.note, updated_at = now();
