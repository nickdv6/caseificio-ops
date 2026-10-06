-- v0.82b (06/10/2026) · go-live board, same-day update after v0.82a (Console → Incassi). `prev` untouched.
insert into fabula.dash_areas(area, sort, built, reliable, automated, next_step, evidence, updated_at) values
 ('Finance & e-invoicing', 11, 55, 45, 45,
  'Commercialista answers the IVA regime and numbering questions; PEC and SDI code; Fatture in Cloud in Masseria''s name, then build the invoicing bot. Incassi: import the first bank statement and Shopify payments file once the account and Shopify Payments are live',
  'v0.82 (06/10): Console → Incassi built and tested (32 database, 16 file-reader and 18 browser checks): bank statement and Shopify payments CSV import with duplicates skipped; nightly matching of payouts to bank credits, credits to sales invoices and wholesale orders, rules for bank fees and cash deposits; a "da controllare" list with manual match, classify and notes. The Shopify connector cannot read payouts (no payments permission), so the payments file is uploaded by hand. Still spec only: invoices and the SDI link. 0 real bank rows or payouts yet.', now())
on conflict (area) do update
   set sort = excluded.sort, built = excluded.built, reliable = excluded.reliable, automated = excluded.automated,
       next_step = excluded.next_step, evidence = excluded.evidence, updated_at = excluded.updated_at;
