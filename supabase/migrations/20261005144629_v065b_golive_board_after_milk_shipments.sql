-- v0.65b (05/10/2026) · go-live board after the Masseria milk shipments (sw perla-v38). Same-day update: `prev` stays on the 3 Oct audit.
insert into fabula.dash_areas(area, sort, built, reliable, automated, next_step, evidence, updated_at) values
 ('Milk plan & intake', 5, 94, 80, 72,
  'Print the shipment QR for the farm (Console → Oggi → stampa QR spedizioni) and send it the page link; first real load from the farm',
  'Station QR + DDT number, rejected milk refused, milk price €1.70; 5-step intake in one transaction (v0.62); farm order page with "Visto" (v0.64). v0.65: the farm records each load on its page (its kg is the source of truth, lot M<yymmdd>-<n>); the tablet picks the load at arrival with kg/lot locked (enforced by trigger, received only once) and the farm sees it received or rejected.', now())
on conflict (area) do update
   set built = excluded.built, reliable = excluded.reliable, automated = excluded.automated,
       next_step = excluded.next_step, evidence = excluded.evidence, updated_at = excluded.updated_at;

insert into fabula.dash_checks(key, sort, label, kind, done, note) values
 ('code_pushed',  2, 'Latest code pushed to GitHub',             'manual', true, 'v0.65 on GitHub, 05/10'),
 ('app_deployed', 3, 'Tablet app redeployed (sw perla-v38)',     'manual', true, 'Netlify auto-deploy, sw perla-v38'),
 ('repo_sync',    6, 'Repo migrations match the live database',  'manual', true, '93 files = 93 live versions (05/10, v0.65)')
on conflict (key) do update
   set label = excluded.label, done = excluded.done, note = excluded.note, updated_at = now();
