-- v0.61b (05/10/2026) · go-live board after the backup restore drill. Same-day update: `prev` stays on the 3 Oct audit.
insert into fabula.dash_areas(area, sort, built, reliable, automated, next_step, evidence, updated_at) values
 ('Infra & security', 13, 92, 86, 88,
  'Repeat the restore drill every 3 months (next early Jan 2027); keep a list of logins and secrets to re-create after a restore',
  'XSS fixed, repo = live (clean replay), search_path advisors cleared. Restore drill 05/10: the nightly backup restored into a scratch database built from the migrations — 93/93 tables and 1,017 rows match live, 154 foreign keys clean, partial and full restore both work (tools/go-live/restore_backup.py). Logins, Storage files and secrets are not in the backup.', now())
on conflict (area) do update
   set built = excluded.built, reliable = excluded.reliable, automated = excluded.automated,
       next_step = excluded.next_step, evidence = excluded.evidence, updated_at = excluded.updated_at;

insert into fabula.dash_checks(key, sort, label, kind, done, note) values
 ('restore_tested', 19, 'Backup restore tested', 'manual', true, 'Drill 05/10/2026: 93 tables, 1,017 rows, all match; repeat quarterly'),
 ('repo_sync', 6, 'Repo migrations match the live database', 'manual', true, '82 files = 82 live versions (05/10, v0.61)')
on conflict (key) do update
   set label = excluded.label, done = excluded.done, note = excluded.note, updated_at = now();
