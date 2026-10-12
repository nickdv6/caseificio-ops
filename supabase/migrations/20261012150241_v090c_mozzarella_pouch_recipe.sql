-- v0.90c: mozzarella packaging. Nick 12/10: the cheese is weighed, brine (liquido di governo) is added, then it goes into a
-- plastic pouch tied with a knot. 2 pouches of 500 g per kg of cheese, rounded up per batch, deducted at batch close.
-- Provisional (source placeholder) like the other doses until the casaro confirms the real pouch count in the trial week.
select fabula.set_recipe('MOZ-DOP-KG', 'PKG-BAG-500', 'per_kg_output', 2, true, (now() at time zone 'Europe/Rome')::date, 'placeholder',
  'Busta 500 g: 2 per kg di mozzarella, arrotondato per lotto. Da confermare con il casaro (formati diversi da 500 g = altra busta).');
update fabula.recipes r
   set phase = 'close', step_order = 30,
       instruction_it = 'Pesa la mozzarella, aggiungi il liquido di governo, chiudi la busta con un nodo.'
 where r.finished_product_id = (select id from fabula.products where sku = 'MOZ-DOP-KG')
   and r.component_product_id = (select id from fabula.products where sku = 'PKG-BAG-500')
   and r.valid_to is null;
update fabula.products
   set spec_it = coalesce(nullif(spec_it, 'elenco di partenza'), 'busta in plastica per mozzarella con liquido di governo, chiusa a nodo'), updated_at = now()
 where sku = 'PKG-BAG-500';
