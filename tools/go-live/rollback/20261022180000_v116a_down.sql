-- Rollback of v1.16a (audit D-2): puts back exactly what was live before it (captured from production on 22/10/2026:
-- fabula.sync_po_from_approval md5 948d6fe6022be4d78ca60abcb8eaf472, fabula.sell_down_codes_needed md5 6fdf5e0d16f9f3a4da8f92cd3fec7f32,
-- approvals ACL authenticated=ardDxtm). To use it, copy it into supabase/migrations under a new, later version and release it through the
-- pipeline like any other release (the pipeline never re-releases an older commit). It touches nothing else.

grant insert on fabula.approvals to authenticated;

CREATE OR REPLACE FUNCTION fabula.sync_po_from_approval()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'fabula', 'public', 'extensions'
AS $function$
declare pl jsonb;
begin
  if new.status is distinct from old.status then
    if new.related_table = 'purchase_orders' and new.related_id is not null then
      -- v0.99: rejected or expired = never approved → cancelled; back to pending («Annulla») → waiting for approval again.
      -- A sent or received order is never touched from here.
      update fabula.purchase_orders set status = case
               when new.status = 'approved' then 'approved'::fabula.po_status
               when new.status in ('rejected', 'expired') then 'cancelled'::fabula.po_status
               when new.status = 'pending' then 'pending_approval'::fabula.po_status
               else status end,
             updated_at = now()
       where id = new.related_id and status in ('draft', 'pending_approval', 'approved', 'cancelled')
         and not (status = 'cancelled' and cancel_reason is not null);
    elsif new.related_table = 'milk_plans' and new.related_id is not null then
      update fabula.milk_plans set status = case new.status when 'approved' then 'approved' when 'rejected' then 'rejected'
                                                            when 'expired' then 'rejected' when 'pending' then 'proposed' else status end
       where id = new.related_id and status in ('proposed', 'approved', 'rejected');
    elsif new.related_table = 'recipes' and new.status = 'approved' and new.payload->>'type' = 'recipe_update' then
      pl := new.payload;
      perform fabula.set_recipe(pl->>'finished_sku', pl->>'component_sku', (pl->>'basis')::fabula.recipe_basis, (pl->>'to_qty')::numeric,
                                (select round_up from fabula.recipes where id = (pl->>'recipe_id')::uuid),
                                (now() at time zone 'Europe/Rome')::date, 'measured', format('aggiornata da %s su %s lotti (approvazione %s)', pl->>'from_qty', pl->>'batches', new.id));
    end if;
  end if;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION fabula.sell_down_codes_needed()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'fabula', 'public', 'extensions'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'approval_id', a.id, 'lot', a.payload->>'lot', 'sku', a.payload->>'sku', 'status', a.status,
           'percentage', round((a.payload->>'promo_pct')::numeric / 100, 4),
           'code', 'SC' || upper(substr(encode(extensions.gen_random_bytes(6), 'hex'), 1, 8)),
           'title', format('Promo scorte lotto %s (-%s%%)', a.payload->>'lot', a.payload->>'promo_pct'),
           'starts_at', now(), 'ends_at', a.expires_at,
           'variant_ids', (select coalesce(jsonb_agg(m.variant_id order by m.label), '[]') from fabula.shopify_variant_map m join fabula.products p on p.id = m.product_id
                            where p.sku = a.payload->>'sku' and m.kg_per_unit > 0)) order by a.requested_at), '[]')
    from fabula.approvals a
   where a.kind = 'price_change' and a.payload->>'type' = 'sell_down' and a.status in ('pending', 'approved')
     and a.payload->>'shopify_code' is null and coalesce(a.expires_at, now() + interval '1 hour') > now()
$function$;
