-- v0.73b (05/10/2026) · go-live board after auto-approval rules and rota autocopy (same-day update: `prev` stays on 3 Oct).
insert into fabula.dash_areas(area, sort, built, reliable, automated, next_step, evidence, updated_at) values
 ('Milk plan & intake', 5, 94, 83, 80, '', 'v0.73: a milk plan within ±15 % of the last 4 same weekdays (no capacity / farm limit) approves itself 1 h after it is proposed unless someone decides first.', now()),
 ('Procurement', 6, 86, 64, 62, '', 'v0.73: routine purchase orders (≤ € 150, known supplier and price within 10 %) approve themselves after 1 h.', now()),
 ('Inventory & lots', 4, 89, 80, 77, '', 'v0.73: standard counter sell-down promos (≤ 20 kg) approve themselves after 1 h.', now()),
 ('Staff & rota', 3, 88, 64, 50, '', 'v0.73: next week''s rota copies itself on Saturday when still empty.', now())
on conflict (area) do update
   set automated = greatest(dash_areas.automated, excluded.automated),
       evidence = case when dash_areas.evidence like '%v0.73:%' then dash_areas.evidence else dash_areas.evidence || ' ' || excluded.evidence end,
       updated_at = excluded.updated_at;
