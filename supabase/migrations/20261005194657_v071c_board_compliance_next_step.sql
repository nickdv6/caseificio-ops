-- v0.71c (05/10/2026) · go-live board: the compliance deadlines were dated on 05/10 (v0.66a/b: 7 on 30/01/2027, the
-- Consorzio fee on 01/03/2027, provisional) — the Compliance next step still asked to date them.
insert into fabula.dash_areas(area, sort, built, reliable, automated, next_step, evidence, updated_at) values
 ('Compliance & HACCP', 7, 91, 71, 66,
  'Consultant signs the Manuale (rev 0 bozza); set the calibration dates and get the pasteuriser, 2 scales and reference thermometer calibrated; get the Consorzio format and contribution rate; confirm the provisional deadline dates',
  'v0.66: all 8 compliance deadlines dated (HACCP review, pest control, electrical check, extinguishers, waste-water analysis, AUA, whey contract on 30/01/2027; Consorzio fee on 01/03/2027 — provisional, to confirm).', now())
on conflict (area) do update
   set next_step = excluded.next_step,
       evidence = case when dash_areas.evidence like '%v0.66: all 8 compliance deadlines dated%' then dash_areas.evidence else dash_areas.evidence || ' ' || excluded.evidence end,
       updated_at = excluded.updated_at;
