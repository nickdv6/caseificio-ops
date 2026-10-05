-- v0.64b (05/10/2026) · go-live board after the milk-order page and the sell-down promo autopilot (sw perla-v37).
-- Same-day update: `prev` stays on the 3 Oct audit.
insert into fabula.dash_areas(area, sort, built, reliable, automated, next_step, evidence, updated_at) values
 ('Inventory & lots', 4, 89, 78, 74,
  'Post the opening stock count on the tablet',
  'Printable lot labels, lot guard and hold filter live; stock-count form takes real quantities (v0.60). v0.64: each sell-down promo gets a random Shopify code from the bot (ends 20:00); the tablet shows it to the till once Nick approves, and approval writes the WhatsApp and Instagram posts.', now()),
 ('Milk plan & intake', 5, 93, 78, 66,
  'Send the Masseria its order-page link (Console → Oggi → copia link); first real intake from the station QR; confirm Masseria daily kg',
  'Station QR + DDT number, rejected milk refused, milk price €1.70; 5-step intake in one transaction (v0.62). v0.64: approved milk plans appear on the farm''s private order page (latte.html, edge function farm-order, no login); the farm taps "Visto" and the Console shows it. Nothing to send by hand.', now()),
 ('Marketing', 8, 73, 52, 58,
  'Opening date, Predis keys, BENVENUTO10',
  'Module and bot built; nothing live yet. v0.60: Marketing profile can save mkt.* settings; edited approved posts go back to review. v0.64: approving a sell-down promo writes two approved posts (WhatsApp "oggi al banco", Instagram story) in Contenuti, ready to publish.', now())
on conflict (area) do update
   set built = excluded.built, reliable = excluded.reliable, automated = excluded.automated,
       next_step = excluded.next_step, evidence = excluded.evidence, updated_at = excluded.updated_at;

insert into fabula.dash_checks(key, sort, label, kind, done, note) values
 ('code_pushed',  2, 'Latest code pushed to GitHub',             'manual', true, 'v0.64 on GitHub, 05/10'),
 ('app_deployed', 3, 'Tablet app redeployed (sw perla-v37)',     'manual', true, 'Netlify auto-deploy, sw perla-v37'),
 ('repo_sync',    6, 'Repo migrations match the live database',  'manual', true, '91 files = 91 live versions (05/10, v0.64)')
on conflict (key) do update
   set label = excluded.label, done = excluded.done, note = excluded.note, updated_at = now();
