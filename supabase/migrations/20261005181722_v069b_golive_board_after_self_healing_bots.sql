-- v0.69b (05/10/2026) · go-live board after the self-healing bots. Same-day update: `prev` stays on the 3 Oct audit;
-- scores only go up, the v0.69 note is appended once to the existing evidence.
insert into fabula.dash_areas(area, sort, built, reliable, automated, next_step, evidence, updated_at) values
 ('Sales & orders',     2, 84, 75, 83, '', 'v0.69: standing wholesale orders are booked by the database (with the WhatsApp texts) if the bot doesn''t start.', now()),
 ('Inventory & lots',   4, 89, 80, 74, '', 'v0.69: sell-down promos are proposed by the database if the bot doesn''t start (no Shopify code then: counter only).', now()),
 ('Milk plan & intake', 5, 94, 83, 74, '', 'v0.69: if the Piano latte bot doesn''t start, the database proposes tomorrow''s milk itself 45 min later (the farm page shows it).', now()),
 ('Procurement',        6, 86, 64, 55, '', 'v0.69: purchase proposals are made by the database if the Acquisti bot doesn''t start.', now()),
 ('Compliance & HACCP', 7, 91, 71, 66, '', 'v0.69: the evening "Prima di chiudere" banner and the nightly health check run from the database if their bots don''t start.', now()),
 ('Infra & security',  13, 96, 94, 96, '', 'v0.69: self-healing bots (pg_cron every 5 min stands in for 7 bots, 22/22 tests); nightly backup fixed at 21:15 Rome in winter too; a missed nightly backup is re-sent once.', now())
on conflict (area) do update
   set reliable  = greatest(dash_areas.reliable, excluded.reliable),
       automated = greatest(dash_areas.automated, excluded.automated),
       evidence  = case when dash_areas.evidence like '%v0.69:%' then dash_areas.evidence else dash_areas.evidence || ' ' || excluded.evidence end,
       updated_at = excluded.updated_at;
