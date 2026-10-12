-- v0.88a: user-friendliness score per area on the go-live board.
-- 0-100, where 100 = a best-in-class commercial program for the same job
-- (Tulip/Katana-class MES on the floor, ShipStation/Shopify-class fulfilment, Shopify POS at the counter,
-- Pipedrive-class CRM, Fatture in Cloud-class invoicing): scan-first, fewest taps, no training needed,
-- mistakes blocked or undoable, clear state at a glance, works on phone/tablet and offline.
alter table fabula.dash_areas
  add column if not exists usable smallint check (usable between 0 and 100),
  add column if not exists usable_why text;

update fabula.dash_areas d set usable = v.u, usable_why = v.w
from (values
  ('Reports & briefs', 72, 'Briefs arrive by themselves and v0.87 made bot messages readable at a glance. A polished BI tool adds drill-down charts and one-tap filters, which here means opening the Console.'),
  ('Sales & orders', 60, 'Web orders ride on Shopify''s own checkout (benchmark-grade). Counter sales have no POS screen or fiscal printer yet, and the order flow has never run with a real customer.'),
  ('B2B sales pipeline', 55, 'Trade portal on Shopify is clean. Leads, calls and tastings are logged by hand in Vendite, with no one-tap logging from phone or e-mail as in Pipedrive-class CRMs. 0 activities logged so far.'),
  ('Inventory & lots', 66, 'QR labels, FEFO picks itself, held and expired lots refused even offline. The stock count form had save bugs (fixed 04/10) and no count has been done by staff yet.'),
  ('Milk plan & intake', 70, 'Shipment QR, farm page with a single Visto tap, routine plans approve themselves. Intake asks several typed values (antibiotic test, temperature) where top systems read them from the device.'),
  ('Procurement', 52, 'Approve-a-card flow is simple, but suppliers are placeholders so the bot never proposes anything. No supplier portal or one-click reorder from a low-stock alert.'),
  ('Compliance & HACCP', 58, 'CCP steps cannot be skipped and closed batches without records alert (strong mistake-proofing). 23 MOD forms across six HACCP tabs is heavy next to guided checklist apps like FoodDocs or Jolt.'),
  ('Marketing', 48, 'Module built but nothing published. Posts still go out by hand through Predis, without the schedule-and-forget calendar of a dedicated social tool.'),
  ('Fulfilment & shipping', 68, 'Packing pre-filled by FEFO, DDT printed, Shopify fulfilled in one pass, works offline. No scan-to-verify per item or batch label printing as in ShipStation. 0 real shipments.'),
  ('Staff & rota', 50, 'Login is the weakest step: invite links expire within 24 h and it took several invites to get 2 of 3 partners signed in. Rota copies itself and badge clock-in exists, but nobody has used them yet.'),
  ('Finance & e-invoicing', 40, 'Bank and Shopify payment files are uploaded by hand as CSV and matched in a review list. Invoicing and SDI are still spec only, where Fatture in Cloud does both from one screen.'),
  ('Production floor', 64, 'Fully offline, presets, CCP values asked in the right order, paper back-up. All 6 doses are placeholders and the casaro has not run a real cycle on the tablet, so tap count and speed are untested.'),
  ('Infra & security', 55, 'Health and backups watch themselves, but changes still need a git push from the Mac and SQL migrations, and alerts land on this board. Managed SaaS needs no owner effort here.')
) as v(a, u, w)
where d.area = v.a;

-- ops_dashboard(): add the averaged usable score (and its previous-audit value when present).
do $do$
declare
  v_def text := pg_get_functiondef('fabula.ops_dashboard()'::regprocedure);
  v_new text;
begin
  v_new := replace(v_def,
    $s$'built', round(avg(built)), 'reliable', round(avg(reliable)), 'automated', round(avg(automated)),$s$,
    $s$'built', round(avg(built)), 'reliable', round(avg(reliable)), 'automated', round(avg(automated)), 'usable', round(avg(usable)),$s$);
  v_new := replace(v_new,
    $s$'automated', round(avg((prev->>'automated')::numeric)),$s$,
    $s$'automated', round(avg((prev->>'automated')::numeric)), 'usable', round(avg((prev->>'usable')::numeric)),$s$);
  if v_new = v_def or position($s$'usable', round(avg(usable))$s$ in v_new) = 0
     or position($s$prev->>'usable'$s$ in v_new) = 0 then
    raise exception 'ops_dashboard() text did not match, nothing changed';
  end if;
  execute v_new;
end
$do$;
