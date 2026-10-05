-- v0.64a (05/10/2026) · two automations Nick asked for:
-- 1. Milk order to the Masseria: a private order page for the farm (latte.html?t=<token>, served by the edge function
--    farm-order). It always shows the approved milk plans for yesterday → next 7 days, and a plan waiting for Nick's
--    approval as "da confermare". The farm taps "Visto" and the Console sees when they saw it. Nothing to send by hand.
-- 2. Sell-down promos: the sell-down bot pre-creates an unguessable Shopify discount code for each promo it proposes
--    (it expires at 20:00 with the proposal; the code is shown to staff only once Nick approves). When Nick approves the
--    promo in the Console, two posts are written and approved straight away: a WhatsApp "oggi al banco" message and an
--    Instagram story, ready to publish.

-- 1 ---------------------------------------------------------------------------------------------------------------
alter table fabula.milk_plans add column if not exists farm_seen_at timestamptz;

insert into fabula.settings(key, value, description, data_type, sort) values
 ('milk.farm_token', encode(extensions.gen_random_bytes(16), 'hex'),
  'Chiave della pagina ordini latte per la Masseria (latte.html?t=…). Cambiala per disattivare il link vecchio.', 'text', 30)
on conflict (key) do nothing;

create or replace function fabula.farm_milk_orders(p_token text) returns jsonb
language plpgsql stable security definer set search_path = fabula, public as $$
declare v_today date := (now() at time zone 'Europe/Rome')::date; v_tok text := (select value from fabula.settings where key = 'milk.farm_token');
begin
  if v_tok is null or length(v_tok) < 16 or p_token is distinct from v_tok then return null; end if;
  return jsonb_build_object(
    'company', fabula.company_name(),
    'receiving_hours', (select value from fabula.settings where key = 'company.receiving_hours'),
    'today', v_today,
    'orders', (select coalesce(jsonb_agg(jsonb_build_object('plan_date', plan_date, 'milk_kg', milk_kg, 'seen_at', farm_seen_at) order by plan_date), '[]')
                 from fabula.milk_plans where status = 'approved' and plan_date between v_today - 1 and v_today + 7),
    'pending', (select coalesce(jsonb_agg(jsonb_build_object('plan_date', m.plan_date, 'milk_kg', m.milk_kg, 'decide_by', a.expires_at) order by m.plan_date), '[]')
                  from fabula.milk_plans m left join fabula.approvals a on a.id = m.approval_id
                 where m.status = 'proposed' and m.plan_date between v_today and v_today + 7
                   and (a.expires_at is null or a.expires_at > now())));
end $$;

create or replace function fabula.farm_milk_seen(p_token text, p_plan_date date) returns boolean
language plpgsql security definer set search_path = fabula, public as $$
declare v_tok text := (select value from fabula.settings where key = 'milk.farm_token'); n int;
begin
  if v_tok is null or length(v_tok) < 16 or p_token is distinct from v_tok then return false; end if;
  update fabula.milk_plans set farm_seen_at = coalesce(farm_seen_at, now()) where plan_date = p_plan_date and status = 'approved';
  get diagnostics n = row_count;
  return n > 0;
end $$;

-- the link for the Console (staff with Produzione or Acquisti ≥ 1)
create or replace function fabula.farm_order_link() returns text
language sql stable security definer set search_path = fabula, public as $$
  select case when greatest(fabula.perm_level('produzione'), fabula.perm_level('acquisti')) >= 1
              then 'latte.html?t=' || (select value from fabula.settings where key = 'milk.farm_token') end
$$;

revoke all on function fabula.farm_milk_orders(text) from public, anon, authenticated;
revoke all on function fabula.farm_milk_seen(text, date) from public, anon, authenticated;
grant execute on function fabula.farm_milk_orders(text) to service_role;
grant execute on function fabula.farm_milk_seen(text, date) to service_role;
revoke all on function fabula.farm_order_link() from public, anon;
grant execute on function fabula.farm_order_link() to authenticated, service_role;

-- 2 ---------------------------------------------------------------------------------------------------------------
-- promos proposed today that still need their Shopify code (for the sell-down bot)
create or replace function fabula.sell_down_codes_needed() returns jsonb
language sql stable security definer set search_path = fabula, public, extensions as $$
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
$$;

create or replace function fabula.promo_set_code(p_approval uuid, p_code text, p_discount_id text default null) returns boolean
language plpgsql security definer set search_path = fabula, public as $$
declare n int;
begin
  if p_code is null or p_code !~ '^[A-Z0-9-]{6,40}$' then raise exception 'codice non valido: %', p_code; end if;
  update fabula.approvals
     set payload = payload || jsonb_build_object('shopify_code', p_code, 'shopify_discount_id', p_discount_id, 'shopify_code_at', now())
   where id = p_approval and kind = 'price_change' and payload->>'type' = 'sell_down';
  get diagnostics n = row_count;
  return n = 1;
end $$;
revoke all on function fabula.sell_down_codes_needed() from public, anon;
revoke all on function fabula.promo_set_code(uuid, text, text) from public, anon;
grant execute on function fabula.sell_down_codes_needed() to authenticated, service_role;
grant execute on function fabula.promo_set_code(uuid, text, text) to authenticated, service_role;

-- approving a sell-down promo writes the two posts (approved: Nick just approved the promo they announce)
create or replace function fabula.sell_down_promo_posts() returns trigger
language plpgsql security definer set search_path = fabula, public as $$
declare v_name text; v_price text; v_list text; v_pct text; v_txt text; v_wa uuid; v_ig uuid; v_where text;
begin
  if new.kind <> 'price_change' or coalesce(new.payload->>'type', '') <> 'sell_down'
     or new.status <> 'approved' or old.status is not distinct from 'approved' or new.payload ? 'posts' then
    return new;
  end if;
  select name into v_name from fabula.products where sku = new.payload->>'sku';
  v_price := replace(to_char((new.payload->>'promo_price_eur_kg')::numeric, 'FM990.00'), '.', ',');
  v_list  := replace(to_char((new.payload->>'list_price_eur_kg')::numeric, 'FM990.00'), '.', ',');
  v_pct   := round((new.payload->>'promo_pct')::numeric)::text;
  v_where := coalesce(nullif((select value from fabula.settings where key = 'company.address'), ''), 'Agropoli');
  v_txt := format('Oggi al banco: %s a € %s/kg invece di € %s (−%s%%), fino a esaurimento. Ti aspettiamo da %s, %s.',
                  coalesce(v_name, 'mozzarella'), v_price, v_list, v_pct, fabula.company_name(), v_where);
  insert into fabula.mkt_content (platform, format, pillar, status, scheduled_at, brief_it, caption_it, approved_by)
  values ('whatsapp', 'post', 'oggi_al_banco', 'approved', now(), format('Promo scorte lotto %s, approvata in Console', new.payload->>'lot'), v_txt, coalesce(new.decided_by, 'Console'))
  returning id into v_wa;
  insert into fabula.mkt_content (platform, format, pillar, status, scheduled_at, brief_it, caption_it, approved_by)
  values ('instagram', 'story', 'oggi_al_banco', 'approved', now(), format('Promo scorte lotto %s, approvata in Console: foto del banco con la mozzarella in offerta', new.payload->>'lot'),
          format('Oggi al banco −%s%%: %s a € %s/kg. Fino a esaurimento!', v_pct, coalesce(v_name, 'mozzarella'), v_price), coalesce(new.decided_by, 'Console'))
  returning id into v_ig;
  update fabula.approvals set payload = payload || jsonb_build_object('posts', jsonb_build_array(v_wa, v_ig)) where id = new.id;
  return new;
end $$;
revoke all on function fabula.sell_down_promo_posts() from public, anon, authenticated;
do $$ begin
  if not exists (select 1 from pg_trigger where tgrelid = 'fabula.approvals'::regclass and tgname = 'approvals_sell_down_posts') then
    create trigger approvals_sell_down_posts after update of status on fabula.approvals for each row execute function fabula.sell_down_promo_posts();
  end if;
end $$;

-- the tablet's "vendere prima" list shows the code once the promo is approved
create or replace view fabula.v_sell_down_today as
 select s.sku, s.name, s.lot_number, round(s.qty_on_hand, 1) as kg, s.expiry_date,
        s.expiry_date - (now() at time zone 'Europe/Rome')::date as days_left,
        a.status as promo_status, (a.payload->>'promo_pct')::numeric as promo_pct, (a.payload->>'promo_price_eur_kg')::numeric as promo_price_eur_kg,
        case when a.status = 'approved' then a.payload->>'shopify_code' end as promo_code
   from fabula.v_stock_on_hand s
   left join lateral (select approvals.status, approvals.payload from fabula.approvals
                       where approvals.requested_by = 'agent:sell_down' and (approvals.payload->>'lot') = s.lot_number
                         and approvals.requested_at::date = (now() at time zone 'Europe/Rome')::date
                       order by approvals.requested_at desc limit 1) a on true
  where s.kind = 'finished_good' and s.qty_on_hand > 0 and s.expiry_date <= ((now() at time zone 'Europe/Rome')::date + 1)
  order by s.expiry_date, s.sku;
