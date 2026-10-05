-- v0.68c · go-live board after the infra autopilot (same-day follow-up: prev untouched)
insert into fabula.dash_areas (area, built, reliable, automated, evidence, updated_at)
values ('Infra & security', 96, 92, 96,
  'v0.68 autopilot: hourly monitor (pg_cron infra_probe/infra_collect) checks GitHub main (migrations, sw.js, last commit), the Netlify tablet site and the farm-order/backup-export functions; repo sync, code pushed, app deployed, restore tested, security and uptime are now automatic board checks with Console notices (infra_uptime, infra_drift, infra_security, infra_advisors). SQL security scan every hour + nightly Supabase advisor cross-check by the system-check bot; first scan fixed 2 views without security_invoker and 2 bot-only functions open to signed-in users. Backup v3 lists logins (no passwords) and stored files. Restore drill 05/10: 93/93 tables, 1,017 rows; quarterly drill logs itself. Still human: git push from the Mac, Dependabot + off-site backup copy (GitHub settings), save_ledger trim job (one paste in the SQL editor), approvals for access/restores/key changes.',
  now())
on conflict (area) do update set built = excluded.built, reliable = excluded.reliable, automated = excluded.automated,
  evidence = excluded.evidence, updated_at = excluded.updated_at;
