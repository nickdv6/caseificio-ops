-- Fabula v0.83g — Shopify ids are stored as GIDs everywhere (the customer sync already stores gid://shopify/Customer/…):
-- the order created from the queue keeps its full gid in sales_orders.shopify_order_id so the morning order sync matches it.
set search_path = fabula, public, extensions;

create or replace function fabula.trade_queue_result(p_id uuid, p_ok boolean, p_draft text, p_order text, p_name text, p_error text) returns boolean
language plpgsql security definer set search_path = fabula, public as $$
begin
  if p_ok then
    update fabula.trade_order_queue set status = 'created', shopify_draft_id = p_draft, shopify_order_id = p_order, shopify_order_name = p_name, error = null, attempts = attempts + 1, done_at = now() where id = p_id;
    update fabula.sales_orders o set shopify_order_id = coalesce(o.shopify_order_id, p_order), updated_at = now() from fabula.trade_order_queue q where q.id = p_id and o.id = q.sales_order_id;
  else
    update fabula.trade_order_queue set status = case when attempts + 1 >= 8 then 'failed' else 'pending' end, error = left(p_error, 500), attempts = attempts + 1 where id = p_id;
    if (select attempts from fabula.trade_order_queue where id = p_id) >= 8 then
      insert into fabula.bot_messages (agent, severity, title, body, source) values ('wholesale_orders', 'alert', 'Ordine Shopify non creato', 'Ordine ingrosso ' || (select payload->>'order_number' from fabula.trade_order_queue where id = p_id) || ' non creato su Shopify dopo 8 tentativi: ' || coalesce(left(p_error, 200), '?'), 'trade_queue');
    end if;
  end if;
  return found;
end $$;

update fabula.parties set shopify_customer_id = 'gid://shopify/Customer/' || shopify_customer_id where shopify_customer_id ~ '^[0-9]+$';
update fabula.trade_applications set shopify_customer_id = 'gid://shopify/Customer/' || shopify_customer_id where shopify_customer_id ~ '^[0-9]+$';
