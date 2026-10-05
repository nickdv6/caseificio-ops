-- v0.63c (05/10/2026) · go-live board after the Shopify stock split and the Consorzio declaration autopilot (sw perla-v36).
-- Same-day update: `prev` stays on the 3 Oct audit.
insert into fabula.dash_areas(area, sort, built, reliable, automated, next_step, evidence, updated_at) values
 ('Sales & orders', 2, 84, 73, 83,
  'Post the opening stock count (stock sync then starts by itself); Shopify catalog decisions; RT printer once the P.IVA is final',
  'Shopify customers/orders sync daily without errors; held and expired lots no longer sold online (v055). v0.63: stock sync splits the mozzarella pool across the 16 variants (80 % by 28-day sales, 20 % equal, never more than the pool) and starts updating Shopify by itself once the opening stock count is posted; report-only until then.', now()),
 ('Compliance & HACCP', 7, 91, 68, 64,
  'Consultant signs the Manuale (rev 0 bozza); date 8 deadlines; calibrate pasteuriser, 2 scales, reference thermometer; get the Consorzio format and contribution rate',
  'Manuale di Autocontrollo with 23 MOD forms and registers; HACCP saves never fail silently and work offline (v0.60). Manual still a draft. v0.63: the Consorzio DOP declaration is prepared on the 1st by pg_cron with the disciplinare checks (60 h, fat/protein, DOP suppliers, traceability) and a fee estimate; approving it closes the T-DOP task. September 2026 declaration waiting in Console (0 kg, no production yet). Sending stays manual.', now())
on conflict (area) do update
   set built = excluded.built, reliable = excluded.reliable, automated = excluded.automated,
       next_step = excluded.next_step, evidence = excluded.evidence, updated_at = excluded.updated_at;

insert into fabula.dash_checks(key, sort, label, kind, done, note) values
 ('code_pushed',  2, 'Latest code pushed to GitHub',             'manual', true, 'v0.63 on GitHub, 05/10'),
 ('app_deployed', 3, 'Tablet app redeployed (sw perla-v36)',     'manual', true, 'Netlify auto-deploy, sw perla-v36'),
 ('repo_sync',    6, 'Repo migrations match the live database',  'manual', true, '89 files = 89 live versions (05/10, v0.63)')
on conflict (key) do update
   set label = excluded.label, done = excluded.done, note = excluded.note, updated_at = now();
