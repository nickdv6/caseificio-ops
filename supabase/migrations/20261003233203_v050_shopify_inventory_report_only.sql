-- v0.50 Zia Fausta (shopify_inventory) back on in REPORT-ONLY mode: she runs 07:32 and 13:32 Rome Mon–Sat and reports what
-- she would set on Shopify, without changing it. shopify.push_inventory stays 0 until the opening stock count is done and
-- stock is allocated per product (all 16 variants still point at the same MOZ-DOP-KG pool).
-- Scheduled task trig_015bmBjK9omNq4TtupFXf6ed: prompt rewritten for report-only mode, schedule moved to CRON_TZ=Europe/Rome 32 7,13 * * 1-6.
do $$
declare n int;
begin
  update fabula.bot_schedule set active = true where agent = 'shopify_inventory';
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'v050: shopify_inventory not in bot_schedule'; end if;
  update fabula.settings
     set description = 'Push giacenze su Shopify (1 = sì, 0 = no). 0 = solo report: Zia Fausta gira lo stesso e dice cosa metterebbe su Shopify senza cambiarlo (dal 03/10/2026). Prima di passare a 1: conta magazzino d''apertura e giacenza allocata per prodotto (oggi tutte le varianti puntano alla stessa mozzarella).',
         updated_at = now()
   where key = 'shopify.push_inventory';
end $$;
