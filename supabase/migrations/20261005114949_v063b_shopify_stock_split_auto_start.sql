-- v0.63b (05/10/2026) · Shopify stock sync: split the mozzarella pool across the variants, start by itself after the count.
-- Before: every one of the 16 Shopify variants was offered the WHOLE mozzarella stock (all point at MOZ-DOP-KG), so the
-- same kg showed up 16 times. Now each variant gets a share of the pool:
--   share = 80 % by its kg sold in the last 28 days (web shop + Shopify POS, from the order line items) + 20 % equal
--           split, so a variant that has not sold lately still shows something (setting shopify.mix_weight, 0–1);
--   with no sales in the last 28 days the pool is split equally.
-- available_units = floor(pool kg × share / kg per piece): the pieces offered never add up to more than the pool.
-- shopify.push_inventory: 0 = report only · 1 = push · 2 = report only until the opening stock count is posted, then push
-- (set to 2 today, Nick's choice). fabula.shopify_push_enabled() says whether this run may change Shopify.

insert into fabula.settings(key, value, description, data_type, sort) values
 ('shopify.push_inventory', '2', 'Push giacenze su Shopify: 0 = solo report · 1 = sì · 2 = automatico: solo report finché non c''è la conta magazzino d''apertura, poi aggiorna Shopify da solo (scelto da Nick il 05/10/2026). La mozzarella è divisa tra le varianti in base alle vendite degli ultimi 28 giorni (v0.63).', 'number', 60),
 ('shopify.mix_weight', '0.8', 'Quota della giacenza mozzarella divisa tra le varianti Shopify in base alle vendite degli ultimi 28 giorni (0–1); il resto è diviso in parti uguali', 'number', 61)
on conflict (key) do update set value = excluded.value, description = excluded.description, updated_at = now()
 where fabula.settings.key = 'shopify.push_inventory';

create or replace function fabula.shopify_push_enabled() returns int
language sql stable security definer set search_path = fabula, public as $$
  select case fabula.setting_num('shopify.push_inventory', 0)::int
           when 1 then 1
           when 2 then case when exists (select 1 from fabula.stock_counts where status = 'posted') then 1 else 0 end
           else 0 end
$$;
grant execute on function fabula.shopify_push_enabled() to authenticated, service_role;

create or replace view fabula.v_shopify_inventory_push as
with avail as (
  select p_1.id as product_id,
         greatest(0::numeric,
           coalesce((select sum(s.qty_on_hand) from fabula.v_stock_on_hand s
                      where s.product_id = p_1.id and (s.expiry_date is null or s.expiry_date >= (now() at time zone 'Europe/Rome')::date)), 0)
         - coalesce((select sum(l.qty) from fabula.sales_order_lines l join fabula.sales_orders o on o.id = l.sales_order_id
                      where l.product_id = p_1.id and o.status = 'confirmed' and o.channel in ('shopify', 'wholesale')
                        and not exists (select 1 from fabula.stock_moves m_1 where m_1.sales_order_id = o.id and m_1.move_type = 'sale')), 0)
         - case when p_1.sku = 'MOZ-DOP-KG' then fabula.setting_num('shopify.reserve_kg', 0) else 0 end) as available_kg
    from fabula.products p_1
   where p_1.kind = 'finished_good'
), sold as (                                   -- kg sold per variant in the last 28 days (web + POS)
  select l->>'variant_id' as variant_id, sum((l->>'quantity')::numeric * mm.kg_per_unit) as kg
    from fabula.sales_orders o
    cross join lateral jsonb_array_elements(coalesce(o.shopify_payload->'line_items', '[]'::jsonb)) l
    join fabula.shopify_variant_map mm on mm.variant_id = l->>'variant_id' and mm.kg_per_unit > 0
   where o.channel in ('shopify', 'store_pos') and o.status in ('confirmed', 'fulfilled')
     and o.order_date >= (now() at time zone 'Europe/Rome')::date - 28
   group by 1
), v as (
  select m.variant_id, m.label, p.sku, a.available_kg, m.kg_per_unit, coalesce(x.kg, 0) as sold_kg,
         count(*) over (partition by p.id) as n, sum(coalesce(x.kg, 0)) over (partition by p.id) as tot,
         least(1, greatest(0, fabula.setting_num('shopify.mix_weight', 0.8))) as w
    from fabula.shopify_variant_map m
    join fabula.products p on p.id = m.product_id
    join avail a on a.product_id = p.id
    left join sold x on x.variant_id = m.variant_id
   where m.kg_per_unit > 0
), s as (
  select v.*, case when tot > 0 then w * sold_kg / tot + (1 - w) / n else 1.0 / n end as share from v
)
select variant_id, label, sku, available_kg, kg_per_unit,
       floor(available_kg * share / kg_per_unit)::integer as available_units,
       round(share * 100, 1) as share_pct,
       round(available_kg * share, 3) as allocated_kg,
       round(sold_kg, 3) as sold_kg_28d,
       case when tot > 0 then 'vendite_28gg' else 'parti_uguali' end as split_basis
  from s
 order by label;
comment on view fabula.v_shopify_inventory_push is 'v0.63: pieces each Shopify variant may sell. The product pool (in-date stock − unshipped orders − counter reserve) is split across its variants: shopify.mix_weight by kg sold in the last 28 days, the rest equally; equal split when nothing sold. Offered pieces never exceed the pool.';
