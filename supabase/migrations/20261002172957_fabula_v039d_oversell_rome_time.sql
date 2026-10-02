-- v0.39 · 2026-10-02 · web overselling (inventory push off, unshipped web orders = milk-plan demand) · bots on Agropoli time
-- (part of the v0.39 integrity pass; see 20261002172859 for the overview)

-- ---------------------------------------------------------------- 5. web overselling
update fabula.settings set value = '0',
  description = 'Push giacenze su Shopify (1 = sì, 0 = no). Disattivato dal 02/10/2026: sito e POS vendono anche a giacenza zero e la produzione segue gli ordini. Prima di riattivarlo va allocata la giacenza per prodotto (oggi tutte le varianti puntano alla stessa mozzarella).'
  where key = 'shopify.push_inventory';
update fabula.bot_schedule set active = false where agent = 'shopify_inventory';

-- paid web orders waiting to ship become demand for the next production day (pickups keep their own date)
create or replace view fabula.v_preorder_demand with (security_invoker = on) as
select o.pickup_date, l.product_id, round(sum(l.qty), 2) as kg, count(distinct o.id) as orders, 'ritiro'::text as kind
  from fabula.sales_orders o join fabula.sales_order_lines l on l.sales_order_id = o.id
 where o.fulfilment_kind = 'pickup' and o.status = 'confirmed' and o.pickup_date is not null
 group by o.pickup_date, l.product_id
union all
select (select d from (select (now() at time zone 'Europe/Rome')::date + i as d from generate_series(1, 2) i) x
         where extract(isodow from d) <> 7 order by d limit 1) as pickup_date,
       l.product_id, round(sum(l.qty), 2) as kg, count(distinct o.id) as orders, 'spedizione_web'::text as kind
  from fabula.sales_orders o join fabula.sales_order_lines l on l.sales_order_id = o.id
 where o.channel = 'shopify' and o.fulfilment_kind is distinct from 'pickup' and o.status = 'confirmed'
   and not exists (select 1 from fabula.shipments sh where sh.sales_order_id = o.id and sh.status in ('picked', 'in_transit', 'delivered'))
 group by l.product_id;

-- ---------------------------------------------------------------- 6. Agropoli time
update fabula.bot_schedule bs set due_times = v.t from (values
  ('shopify_customers',   array['06:05']::time[]),
  ('shopify_orders',      array['06:11']::time[]),
  ('procurement',         array['06:20']::time[]),
  ('daily_brief',         array['06:47']::time[]),
  ('weekly_brief',        array['07:08']::time[]),
  ('compliance_calendar', array['07:17']::time[]),
  ('sell_down',           array['07:23']::time[]),
  ('shopify_inventory',   array['07:32', '13:32']::time[]),
  ('monthly_review',      array['07:41']::time[]),
  ('marketing',           array['07:53']::time[]),
  ('wholesale_orders',    array['18:20']::time[]),
  ('milk_planning',       array['18:52']::time[]),
  ('haccp_nudge',         array['19:02']::time[]),
  ('ops_health',          array['20:36']::time[])
) v(agent, t) where bs.agent = v.agent;
comment on column fabula.bot_schedule.due_times is 'Europe/Rome (ora di Agropoli) — dal v0.39';

do $$
declare d text;
begin
  d := pg_get_functiondef('fabula.bot_watchdog(timestamptz)'::regprocedure);
  d := replace(d, '''America/New_York''', '''Europe/Rome''');
  d := replace(d, 'format(''⏰ %s: non è partito (previsto %s it. / %s NY)'', x->>''name'', x->>''due_rome'', x->>''due_ny'')',
                  'format(''⏰ %s: non è partito (previsto alle %s, ora di Agropoli)'', x->>''name'', x->>''due_rome'')');
  execute d;
end $$;
