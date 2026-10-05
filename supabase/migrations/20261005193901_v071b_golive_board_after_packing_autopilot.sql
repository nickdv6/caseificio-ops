-- v0.71b (05/10/2026) · go-live board after packing on autopilot (same-day update: `prev` stays on the 3 Oct audit).
insert into fabula.dash_areas(area, sort, built, reliable, automated, next_step, evidence, updated_at) values
 ('Fulfilment & shipping', 9, 90, 78, 65,
  'Post the opening stock count, then pack one real order from Da spedire (lots come pre-filled) and print the DDT; replace the placeholder wholesale customers',
  'v0.71 autopilot: Da spedire lists the orders in packing order (late first) with lots already allocated — oldest in-date first, split over lots, never promised twice — plus the cold-room pick list and late/short flags; the pack form opens filled in. Held and expired lots are refused (no override); short stock, short shelf life (online 2 days, wholesale 1) and weight are confirmed with the reason; guest online orders get a consignee. Tests: SQL 14/14, tablet 14/14.', now())
on conflict (area) do update
   set built = greatest(dash_areas.built, excluded.built), reliable = greatest(dash_areas.reliable, excluded.reliable),
       automated = greatest(dash_areas.automated, excluded.automated), next_step = excluded.next_step,
       evidence = case when dash_areas.evidence like '%v0.71 autopilot%' then dash_areas.evidence else dash_areas.evidence || ' ' || excluded.evidence end,
       updated_at = excluded.updated_at;
