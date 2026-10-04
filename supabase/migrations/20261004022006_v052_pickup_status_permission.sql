-- v0.52 (04/10/2026): marking a store pickup (Marketing > Ritiri: Pronto / Ritirato / Non ritirato)
-- writes sales_orders, whose area is vendite (write level 2). The Banco and Marketing profiles have
-- vendite = 1, so their clicks were refused by RLS. The function now runs as definer and checks
-- the person itself: vendite >= 2, spedizioni >= 2 (Banco, Spedizioni, Produzione) or marketing >= 2.
-- It still touches only pickup_status of pickup orders.
create or replace function fabula.mkt_set_pickup_status(p_order uuid, p_status text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'fabula', 'public', 'extensions'
as $function$
begin
  if not (fabula.can('vendite', 2) or fabula.can('spedizioni', 2) or fabula.can('marketing', 2)) then
    raise exception 'Permesso negato: serve il livello registra in Vendite, Spedizioni o Marketing' using errcode = '42501';
  end if;
  if p_status not in ('da_preparare','pronto','ritirato','non_ritirato') then raise exception 'stato non valido: %', p_status; end if;
  update fabula.sales_orders set pickup_status = p_status, updated_at = now() where id = p_order and fulfilment_kind = 'pickup';
  if not found then raise exception 'ordine di ritiro non trovato'; end if;
  return jsonb_build_object('order', p_order, 'pickup_status', p_status,
    'note', case when p_status = 'ritirato' then 'Segna l''ordine come evaso in Shopify (POS o admin): lo scarico di magazzino avviene alla sincronizzazione.' end);
end $function$;

revoke execute on function fabula.mkt_set_pickup_status(uuid, text) from public, anon;
grant execute on function fabula.mkt_set_pickup_status(uuid, text) to authenticated, service_role;
