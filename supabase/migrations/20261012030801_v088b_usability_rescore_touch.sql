-- v0.88b: user-friendliness rescore after the touch-screen pass (touch.css: 16px fields so iOS stops zooming,
-- 44px tap targets on Console, Configurazione, HACCP, Vendite, Marketing, Ingrosso, Registro) and a correction
-- (packing already has scan-to-confirm per lot and the scale button). prev.usable keeps the first score for the arrows.
update fabula.dash_areas
   set prev = coalesce(prev, '{}'::jsonb) || jsonb_build_object('usable', usable)
 where usable is not null;

update fabula.dash_areas d
   set usable = v.u,
       usable_why = coalesce(v.w, d.usable_why)
from (values
  ('Sales & orders', 61, null),
  ('B2B sales pipeline', 58, 'Trade portal on Shopify is clean. Vendite now works on a phone without zooming into every field (v0.88b), but calls and tastings are still logged by hand, with no one-tap logging from phone or e-mail as in Pipedrive-class CRMs. 0 activities logged so far.'),
  ('Procurement', 54, 'Approve-a-card flow is simple and now finger-sized on the iPad (v0.88b). Suppliers are placeholders so the bot never proposes anything, and there is no one-click reorder from a low-stock alert.'),
  ('Compliance & HACCP', 61, 'CCP steps cannot be skipped and closed batches without records alert (strong mistake-proofing). The HACCP console no longer zooms on iPad fields (v0.88b), but 23 MOD forms across six tabs is still heavy next to guided checklist apps like FoodDocs or Jolt.'),
  ('Marketing', 50, null),
  ('Fulfilment & shipping', 72, 'Packing pre-filled by FEFO, scan the lot label to confirm (held or expired lots refused), weight read from the scale, DDT printed, Shopify fulfilled in one pass, works offline. Missing next to ShipStation: batch label printing and a carrier label in the same flow. 0 real shipments.'),
  ('Staff & rota', 52, null),
  ('Finance & e-invoicing', 42, null)
) as v(a, u, w)
where d.area = v.a;
