-- =============================================================================
-- Fabula v0.22 — Shopify is the source of truth for customers
--   * parties gains shopify_customer_id, source (manual | shopify | placeholder),
--     tags, is_wholesale, last_synced_at, orders_count, total_spent_eur.
--   * upsert_shopify_customers(jsonb) — called by the nightly "Clienti Shopify"
--     bot with the customer list read through the Shopify connector. Matches by
--     Shopify id, then by e-mail (so a placeholder re-created in Shopify with the
--     same e-mail is adopted instead of duplicated). Tag "ingrosso" or "b2b" marks
--     a wholesale customer. Customers no longer in Shopify are deactivated, never
--     removed (orders reference them).
--   * v_parties_editor exposes the new columns; console Clienti tab is read-only
--     for Shopify fields.
-- Written without destructive keywords (connector rule).
-- =============================================================================
set search_path = fabula, public;

alter table fabula.parties add column if not exists shopify_customer_id text;
alter table fabula.parties add column if not exists source text not null default 'manual';
alter table fabula.parties add column if not exists tags text[] not null default '{}';
alter table fabula.parties add column if not exists is_wholesale boolean not null default false;
alter table fabula.parties add column if not exists last_synced_at timestamptz;
alter table fabula.parties add column if not exists orders_count int;
alter table fabula.parties add column if not exists total_spent_eur numeric(12,2);
create unique index if not exists parties_shopify_customer_id_uq on fabula.parties (shopify_customer_id) where shopify_customer_id is not null;
update fabula.parties set source = 'placeholder' where notes = 'placeholder' and source = 'manual';
update fabula.parties set is_wholesale = true where type = 'customer' and exists (select 1 from fabula.standing_orders s where s.customer_id = parties.id);

create or replace function fabula.upsert_shopify_customers(p_rows jsonb)
returns jsonb language plpgsql as $$
declare r jsonb; v_id uuid; n_new int := 0; n_upd int := 0; n_off int := 0; v_tags text[]; v_name text; v_ws boolean; ids text[] := '{}';
begin
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    v_tags := coalesce((select array_agg(lower(t)) from jsonb_array_elements_text(coalesce(r->'tags', '[]'::jsonb)) t), '{}');
    v_ws := v_tags && array['ingrosso','b2b','wholesale','horeca'];
    v_name := coalesce(nullif(trim(r->>'company'), ''), nullif(trim(r->>'name'), ''), nullif(trim(concat_ws(' ', r->>'first_name', r->>'last_name')), ''), r->>'email', 'Cliente Shopify ' || (r->>'id'));
    ids := ids || (r->>'id');
    select id into v_id from fabula.parties where shopify_customer_id = r->>'id';
    if v_id is null and nullif(r->>'email', '') is not null then
      select id into v_id from fabula.parties where type = 'customer' and shopify_customer_id is null and lower(email) = lower(r->>'email') limit 1;
    end if;
    if v_id is null then
      insert into fabula.parties (type, legal_name, email, phone, city, payment_terms_days, source, shopify_customer_id, tags, is_wholesale, last_synced_at, orders_count, total_spent_eur, active)
      values ('customer', v_name, nullif(r->>'email', ''), nullif(r->>'phone', ''), nullif(r->>'city', ''), case when v_ws then 30 else 0 end, 'shopify', r->>'id', v_tags, v_ws, now(), (r->>'orders_count')::int, (r->>'total_spent')::numeric, true);
      n_new := n_new + 1;
    else
      update fabula.parties set legal_name = v_name, email = coalesce(nullif(r->>'email', ''), email), phone = coalesce(nullif(r->>'phone', ''), phone), city = coalesce(nullif(r->>'city', ''), city),
             source = 'shopify', shopify_customer_id = r->>'id', tags = v_tags, is_wholesale = v_ws or exists (select 1 from fabula.standing_orders s where s.customer_id = v_id and s.active),
             last_synced_at = now(), orders_count = (r->>'orders_count')::int, total_spent_eur = (r->>'total_spent')::numeric, notes = case when notes = 'placeholder' then null else notes end, active = true
       where id = v_id;
      n_upd := n_upd + 1;
    end if;
  end loop;
  -- customers that vanished from Shopify: deactivate (orders keep referencing them)
  if jsonb_array_length(coalesce(p_rows, '[]'::jsonb)) > 0 then
    update fabula.parties set active = false, last_synced_at = now() where type = 'customer' and source = 'shopify' and active and not (shopify_customer_id = any(ids));
    get diagnostics n_off = row_count;
  end if;
  return jsonb_build_object('received', jsonb_array_length(coalesce(p_rows, '[]'::jsonb)), 'created', n_new, 'updated', n_upd, 'deactivated', n_off,
    'placeholders_left', (select count(*) from fabula.parties where type = 'customer' and source = 'placeholder' and active),
    'wholesale', (select count(*) from fabula.parties where type = 'customer' and active and is_wholesale));
end $$;
grant execute on function fabula.upsert_shopify_customers(jsonb) to authenticated, service_role;

create or replace view fabula.v_parties_editor as
  select id, type::text as type, legal_name, email, phone, payment_terms_days, is_milk_supplier, is_dop_certified, notes, active,
         (source = 'placeholder' or notes = 'placeholder') as is_placeholder,
         (select count(*) from fabula.products pr where pr.preferred_supplier_id = p.id) as products_supplied,
         (select count(*) from fabula.standing_orders s where s.customer_id = p.id and s.active) as standing_orders,
         city, source, shopify_customer_id, tags, is_wholesale, last_synced_at, orders_count, total_spent_eur   -- appended: a view's existing columns cannot be reordered with create or replace
  from fabula.parties p where active order by type, is_wholesale desc, legal_name;
grant select on fabula.v_parties_editor to authenticated, service_role;

-- health check lists placeholders; the Shopify bot joins the expected list
create or replace function fabula.expected_bots(p_date date)
returns table(agent text) language sql immutable as $$
  select a from unnest(array['daily_brief','procurement','wholesale_orders','milk_planning','sell_down','haccp_nudge','shopify_customers']) a where extract(isodow from p_date) between 1 and 6
  union all select 'weekly_brief' where extract(isodow from p_date) = 1
  union all select 'compliance_calendar' where extract(isodow from p_date) = 2
  union all select 'monthly_review' where extract(day from p_date) = 1
$$;
