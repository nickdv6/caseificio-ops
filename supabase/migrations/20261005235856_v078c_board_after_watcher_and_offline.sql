-- v0.78c (06/10/2026) · board after the outside watcher and the offline gaps (same-day update: `prev` untouched).
insert into fabula.dash_areas (area, sort, built, reliable, automated, next_step, evidence, updated_at) values
 ('Infra & security', 13, 0, 97, 0, 'Check that GitHub e-mails you about failed workflows (GitHub → Settings → Notifications → Actions); repeat the restore drill every 3 months (next 5 Jan 2027, scheduled)', 'v0.78: an outside watcher on GitHub Actions checks the site, the database, pg_cron, the backup and an edge function every 30 min, independent of Supabase, the bots and Claude; a confirmed failure e-mails the repo owner.', now()),
 ('Production floor', 12, 0, 82, 0, '', 'v0.78: a batch started without network can also be closed without network; the day''s task list stays visible offline.', now()),
 ('Fulfilment & shipping', 9, 0, 81, 0, '', 'v0.78: direct shipment from a closed lot works offline (held lots refused on the tablet).', now())
on conflict (area) do update
   set reliable = greatest(dash_areas.reliable, excluded.reliable),
       next_step = case when excluded.next_step <> '' then excluded.next_step else dash_areas.next_step end,
       evidence = case when dash_areas.evidence like '%v0.78:%' then dash_areas.evidence else dash_areas.evidence || ' ' || excluded.evidence end,
       updated_at = excluded.updated_at;
