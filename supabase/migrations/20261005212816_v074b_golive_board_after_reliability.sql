-- v0.74b (05/10/2026) · go-live board after tablet check-in, refused-save reporting and pg_cron watching (same-day update: `prev` stays on 3 Oct).
insert into fabula.dash_areas(area, sort, built, reliable, automated, next_step, evidence, updated_at) values
 ('Compliance & HACCP', 7, 91, 75, 66, '', 'v0.74: an HACCP record the database refuses after an offline save is kept in full on the server and rings the bell (Zio Tonino), so it can be redone the same day instead of being lost on the tablet.', now()),
 ('Production floor', 12, 93, 79, 50, '', 'v0.74: every tablet checks in (app version, records waiting, refused saves); records stuck over 2 h or an old app version raise a warning, and the tablet shows "Aggiorna ora" when a new version is live.', now()),
 ('Fulfilment & shipping', 9, 90, 80, 65, '', 'v0.74: refused packing/shipping saves from an offline tablet reach the office.', now()),
 ('Infra & security', 13, 96, 96, 96, '', 'v0.74: the external alarm bot also watches the database scheduler: pg_cron silent for 20 min or any failed scheduled job is reported.', now())
on conflict (area) do update
   set reliable = greatest(dash_areas.reliable, excluded.reliable),
       evidence = case when dash_areas.evidence like '%v0.74:%' then dash_areas.evidence else dash_areas.evidence || ' ' || excluded.evidence end,
       updated_at = excluded.updated_at;
