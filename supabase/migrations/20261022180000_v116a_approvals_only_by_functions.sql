-- v1.16a (22/10/2026) · approval requests are created only by the database's own functions, never by a login (audit D-2,
-- claude/production-readiness-audit-2026-10-22.md).
-- Until now any login with level 2 in an area could INSERT straight into fabula.approvals, and the auto-approval trigger trusted what it
-- sent: a request pointing at a REJECTED milk plan got its timer and approved itself, and sync_po_from_approval moved the plan back to
-- «approved», so the farm saw it; a 100 % promo with no end was listed for the sell-down bot to turn into a Shopify code.
-- Every legitimate request is created by a function or trigger that runs as the database owner: the bots and cron (plan_milk,
-- propose_purchase_orders, recipe_tuning_proposals via monthly_review, sell_down_signals, consorzio_declaration), their stand-ins and
-- «Esegui ora» (run_bot_fallback), «Ordina di nuovo» (milk_order_again), manual orders (create_manual_po), lab results
-- (record_lab_result), marketing content (mkt_content_before) and the marketing bot's local-campaign step (mkt_local_before, fired by
-- the bot's own update). No page and no edge function inserts approvals. Three changes:
--   1. logins lose INSERT on approvals. SELECT, DELETE and the five policies are unchanged; UPDATE was already closed. The five proposal
--      functions keep their EXECUTE grant: called by a login they now stop at the approvals insert (plan_milk already stopped earlier,
--      at milk_plans), and the whole call rolls back;
--   2. sync_po_from_approval never moves a REJECTED milk plan to approved. «Annulla» on a rejection (approval back to pending, plan
--      back to proposed) and every other transition are unchanged;
--   3. sell_down_codes_needed lists only the sell-down bot's promos, with a discount above 0 and at most sell.promo_pct, and a real end
--      within 48 hours. A non-numeric discount is skipped instead of breaking the whole list.
-- Not changed on purpose: mkt_local_before stays SECURITY INVOKER (only the marketing bot, as owner, sets «in_approvazione»; as a definer
-- it would keep a login path open), and the EXECUTE grants above.
-- Rollback: tools/go-live/rollback/20261022180000_v116a_down.sql (restores the grant and the two definitions exactly as captured live).

revoke insert on fabula.approvals from authenticated;

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
       where id = new.related_id and status in ('proposed', 'approved', 'rejected')
         and not (status = 'rejected' and new.status = 'approved');   -- v1.16 (D-2): a rejected plan is never approved from here; «Annulla» (→ pending → proposed) still works
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
     and a.payload->>'shopify_code' is null
     -- v1.16 (D-2): only the sell-down bot's own promos, a discount above 0 and at most the standard sell.promo_pct,
     -- and a real end within 48 hours (its promos end at 20:00 of their day)
     and a.requested_by = 'agent:sell_down'
     and case when a.payload->>'promo_pct' ~ '^[0-9]+([.][0-9]+)?$' then (a.payload->>'promo_pct')::numeric end
         between 0.01 and fabula.setting_num('sell.promo_pct', 30)
     and a.expires_at > now() and a.expires_at <= now() + interval '48 hours'
$function$;
