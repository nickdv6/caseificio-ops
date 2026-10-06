-- Fabula v0.83c — trade portal: booking into sales_orders + Shopify queue, order sync rule, permissions, access, pg_cron (part 3 of 3)
set search_path = fabula, public, extensions;

-- ---------- booking: next-day deliveries → sales_orders + Shopify queue (replaces the v0.72 body) ----------
create or replace function fabula.confirm_standing_orders(p_date date default null::date) returns jsonb
language plpgsql set search_path = fabula, public, extensions as $$
declare d date; c record; l record; v_order uuid; v_total numeric; v_iva numeric; n int := 0; msgs jsonb := '[]'; lines_txt text; v_num text; v_lines int; v_cancelled jsonb; v_skipped jsonb;
        pr jsonb; v_price numeric; v_qlines jsonb; v_rate numeric; s jsonb := fabula.trade_settings(); v_min numeric := (fabula.trade_settings()->>'min_order_kg')::numeric; v_kg numeric; under jsonb := '[]';
begin
  d := coalesce(p_date, fabula.trade_now_rome()::date + 1);
  while not fabula.trade_is_delivery_day(d) and d < coalesce(p_date, fabula.trade_now_rome()::date + 1) + 7 loop d := d + 1; end loop;
  v_cancelled := fabula.cancel_placeholder_orders();   -- v0.72
  select coalesce(jsonb_agg(distinct p.legal_name), '[]') into v_skipped
    from fabula.standing_orders so join fabula.parties p on p.id = so.customer_id where so.active and so.weekday = extract(isodow from d) and fabula.is_placeholder_party(so.customer_id);
  for c in select e.customer_id, p.legal_name, p.phone, max(e.window_code) window_code, max(e.delivery_address) delivery_address, max(e.delivery_instructions) delivery_instructions, max(e.po_number) po_number, sum(e.kg) kg
           from fabula.trade_effective_lines(d) e join fabula.parties p on p.id = e.customer_id group by e.customer_id, p.legal_name, p.phone order by p.legal_name loop
    if exists (select 1 from fabula.sales_orders o where o.customer_id = c.customer_id and o.order_date = d and o.channel = 'wholesale' and o.source = 'standing_order' and o.status <> 'cancelled') then
      select order_number into v_num from fabula.sales_orders o where o.customer_id = c.customer_id and o.order_date = d and o.channel = 'wholesale' and o.source = 'standing_order' and o.status <> 'cancelled' limit 1;
      msgs := msgs || jsonb_build_object('customer', c.legal_name, 'phone', c.phone, 'already_booked', true, 'order_number', v_num); continue;
    end if;
    if c.kg < v_min then under := under || jsonb_build_object('customer', c.legal_name, 'kg', c.kg); continue; end if;
    v_num := 'WS-' || to_char(d, 'YYMMDD') || '-' || lpad((select count(*) + 1 from fabula.sales_orders where order_date = d and channel = 'wholesale')::text, 2, '0');
    while exists (select 1 from fabula.sales_orders where order_number = v_num) loop v_num := v_num || 'b'; end loop;
    insert into fabula.sales_orders (order_number, channel, order_date, customer_id, status, source, notes, delivery_window, delivery_address, delivery_instructions, po_number, payment_method)
    values (v_num, 'wholesale', d, c.customer_id, 'confirmed', 'standing_order', 'consegna ' || fabula.trade_wd_it(extract(isodow from d)::int) || coalesce(' · ' || c.window_code, ''), c.window_code, c.delivery_address, c.delivery_instructions, c.po_number, 'shopify_b2b')
    returning id into v_order;
    v_total := 0; v_iva := 0; lines_txt := ''; v_lines := 0; v_qlines := '[]';
    for l in select e.*, tp.title, tp.variant_title, tp.unit_label, p2.iva_rate, p2.name from fabula.trade_effective_lines(d) e join fabula.trade_products tp on tp.variant_id = e.variant_id left join fabula.products p2 on p2.id = e.product_id
             where e.customer_id = c.customer_id order by tp.sort loop
      pr := fabula.trade_price(c.customer_id, l.variant_id, l.qty, l.recurring);
      v_price := (pr->>'final_price')::numeric; v_rate := coalesce(l.iva_rate, 4);
      if l.product_id is not null then
        insert into fabula.sales_order_lines (sales_order_id, product_id, qty, unit_price_eur, iva_rate)
        values (v_order, l.product_id, l.kg, round(v_price / nullif((select kg_per_unit from fabula.trade_products where variant_id = l.variant_id), 0), 4), v_rate)
        on conflict do nothing;
      end if;
      v_total := v_total + v_price * l.qty; v_iva := v_iva + v_price * l.qty * v_rate / 100; v_lines := v_lines + 1;
      lines_txt := lines_txt || format('%s %s %s', trim_scale(l.qty), l.unit_label, l.title || coalesce(' ' || l.variant_title, '')) || ', ';
      v_qlines := v_qlines || jsonb_build_object('variant_id', l.variant_id, 'qty', l.qty, 'list_price', pr->>'list_price', 'final_price', v_price, 'discount_pct', case when (pr->>'list_price')::numeric > 0 then round((1 - v_price / (pr->>'list_price')::numeric) * 100, 2) else 0 end,
                                                 'recurring', l.recurring, 'title', l.title || coalesce(' ' || l.variant_title, ''));
    end loop;
    lines_txt := rtrim(lines_txt, ', ');
    update fabula.sales_orders set subtotal_eur = round(v_total, 2), iva_eur = round(v_iva, 2), total_eur = round(v_total + v_iva, 2) where id = v_order;
    insert into fabula.trade_order_queue (sales_order_id, customer_id, delivery_date, payload)
    values (v_order, c.customer_id, d, jsonb_build_object('order_number', v_num, 'lines', v_qlines, 'window', c.window_code, 'address', c.delivery_address, 'instructions', c.delivery_instructions, 'po_number', c.po_number, 'lines_txt', lines_txt))
    on conflict (sales_order_id) do nothing;
    n := n + 1;
    msgs := msgs || jsonb_build_object('customer', c.legal_name, 'phone', c.phone, 'order_number', v_num, 'lines', v_lines, 'total_eur', round(v_total, 2), 'window', c.window_code,
      'message_it', format('Buongiorno, ' || fabula.company_name(true) || ' conferma per %s %s: %s. Consegna %s. Per cambiare quantità basta rispondere entro le %s di oggi. Grazie!',
                           fabula.trade_wd_it(extract(isodow from d)::int), to_char(d, 'DD/MM'), lines_txt, coalesce('ore ' || c.window_code, 'in mattinata'), s->>'cutoff_time'));
  end loop;
  return jsonb_build_object('date', d, 'weekday', fabula.trade_wd_it(extract(isodow from d)::int), 'booked', n, 'customers', msgs, 'under_minimum', under,
    'total_kg', (select coalesce(sum(sl.qty), 0) from fabula.sales_order_lines sl join fabula.sales_orders o on o.id = sl.sales_order_id where o.order_date = d and o.channel = 'wholesale' and o.status = 'confirmed'),
    'queued_for_shopify', (select count(*) from fabula.trade_order_queue where status = 'pending'),
    'is_placeholder', jsonb_array_length(v_skipped) > 0, 'skipped_placeholder', v_skipped, 'cancelled_placeholder', v_cancelled);
end $$;

-- queue access for the edge function (service_role)
create or replace function fabula.trade_queue_pending() returns jsonb language sql stable security definer set search_path = fabula, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'sales_order_id', q.sales_order_id, 'delivery_date', q.delivery_date, 'payload', q.payload, 'attempts', q.attempts,
           'customer', jsonb_build_object('id', p.id, 'name', p.legal_name, 'email', p.email, 'phone', p.phone, 'shopify_company_id', p.shopify_company_id, 'shopify_location_id', p.shopify_location_id, 'shopify_contact_id', p.shopify_contact_id, 'shopify_customer_id', p.shopify_customer_id, 'terms', p.payment_terms_days)) order by q.created_at), '[]')
  from fabula.trade_order_queue q join fabula.parties p on p.id = q.customer_id where q.status = 'pending' and q.attempts < 8
$$;
create or replace function fabula.trade_queue_result(p_id uuid, p_ok boolean, p_draft text, p_order text, p_name text, p_error text) returns boolean
language plpgsql security definer set search_path = fabula, public as $$
begin
  if p_ok then
    update fabula.trade_order_queue set status = 'created', shopify_draft_id = p_draft, shopify_order_id = p_order, shopify_order_name = p_name, error = null, attempts = attempts + 1, done_at = now() where id = p_id;
    update fabula.sales_orders o set shopify_order_id = coalesce(o.shopify_order_id, regexp_replace(p_order, '^.*/', '')), updated_at = now() from fabula.trade_order_queue q where q.id = p_id and o.id = q.sales_order_id;
  else
    update fabula.trade_order_queue set status = case when attempts + 1 >= 8 then 'failed' else 'pending' end, error = left(p_error, 500), attempts = attempts + 1 where id = p_id;
    if (select attempts from fabula.trade_order_queue where id = p_id) >= 8 then
      insert into fabula.bot_messages (agent, severity, title, body, source) values ('wholesale_orders', 'alert', 'Ordine Shopify non creato', 'Ordine ingrosso ' || (select payload->>'order_number' from fabula.trade_order_queue where id = p_id) || ' non creato su Shopify dopo 8 tentativi: ' || coalesce(left(p_error, 200), '?'), 'trade_queue');
    end if;
  end if;
  return found;
end $$;

-- the database asks the edge function to push the queue (pg_cron, Rome 18:25 after the 18:20 booking; hourly retry while something is pending)
create or replace function fabula.trade_push_queue(p_only_if_pending boolean default true) returns bigint language plpgsql security definer set search_path = fabula, public, extensions as $$
declare url text := fabula.setting_text('trade.edge_url'); sec text := fabula.setting_text('trade.job_secret'); rid bigint;
begin
  if url is null or sec is null then return null; end if;
  if p_only_if_pending and not exists (select 1 from fabula.trade_order_queue where status = 'pending' and attempts < 8) then return null; end if;
  select net.http_post(url := url || '?action=run-queue', headers := jsonb_build_object('Content-Type', 'application/json', 'x-trade-secret', sec), body := '{}'::jsonb, timeout_milliseconds := 60000) into rid;
  return rid;
end $$;

-- ---------- Shopify order sync: B2B orders are wholesale and confirmed even while unpaid (net terms) ----------
create or replace function fabula.trade_is_b2b_row(r jsonb, p_customer uuid) returns boolean language sql stable set search_path = fabula, public as $$
  select coalesce((select is_wholesale or trade_status = 'approved' from fabula.parties where id = p_customer), false)
      or lower(coalesce(r->>'tags', '')) ~ '(^|,\s*)(ingrosso|b2b)(\s*,|$)'
      or nullif(r->>'company', '') is not null
      or nullif(r->>'payment_terms', '') is not null
$$;


-- Shopify order sync (upsert_shopify_orders) marks every web order 'shopify' and unpaid orders 'draft'; a B2B order on net terms is a
-- confirmed wholesale order. This trigger fixes both on insert and on every sync update, without touching the sync itself.
create or replace function fabula.trg_sales_order_b2b() returns trigger language plpgsql set search_path = fabula, public as $$
begin
  if new.shopify_payload is not null and fabula.trade_is_b2b_row(new.shopify_payload, new.customer_id) then
    new.channel := 'wholesale';
    if new.status = 'draft' and nullif(new.shopify_payload->>'cancelled_at', '') is null then new.status := 'confirmed'; end if;
    if coalesce(new.payment_method, '') in ('', 'shopify') then new.payment_method := 'shopify_b2b'; end if;
  end if;
  return new;
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'sales_orders_b2b' and tgrelid = 'fabula.sales_orders'::regclass) then
    create trigger sales_orders_b2b before insert or update of status, channel, shopify_payload on fabula.sales_orders for each row execute function fabula.trg_sales_order_b2b();
  end if;
end $$;

-- ---------- permissions ----------
create or replace function fabula.my_permissions() returns jsonb language sql stable security definer set search_path = fabula, public as $$
  select case when s.id is null then jsonb_build_object('staff_id', null, 'active', false, 'areas', '{}'::jsonb, 'pages', '{}'::jsonb)
  else jsonb_build_object(
    'staff_id', s.id, 'full_name', s.full_name, 'job_role', s.role, 'role', r.code, 'role_name', r.name_it, 'home', r.home, 'active', s.active,
    'can_manage_users', r.can_manage_users,
    'areas', (select jsonb_object_agg(a.code, coalesce(rp.level, case when a.code = 'comune' then 2 else 0 end)) from fabula.app_areas a
              left join fabula.role_permissions rp on rp.role_code = r.code and rp.area = a.code),
    'pages', jsonb_build_object(
       'tablet',   exists (select 1 from fabula.role_permissions where role_code = r.code and area in ('produzione','haccp','magazzino','spedizioni') and level >= 2),
       'console',  exists (select 1 from fabula.role_permissions where role_code = r.code and area in ('produzione','acquisti','vendite','magazzino','personale','finanza') and level >= 1),
       'haccp',    exists (select 1 from fabula.role_permissions where role_code = r.code and area = 'haccp' and level >= 1),
       'marketing',exists (select 1 from fabula.role_permissions where role_code = r.code and area = 'marketing' and level >= 1),
       'vendite',  exists (select 1 from fabula.role_permissions where role_code = r.code and area = 'vendite' and level >= 1),
       'ingrosso', exists (select 1 from fabula.role_permissions where role_code = r.code and area = 'vendite' and level >= 1),
       'pacchetto',exists (select 1 from fabula.role_permissions where role_code = r.code and area = 'finanza' and level >= 1),
       'admin',    exists (select 1 from fabula.role_permissions where role_code = r.code and area = 'sistema' and level >= 1)))
  end
  from (select 1) x left join fabula.staff s on s.auth_user_id = auth.uid() and s.active left join fabula.app_roles r on r.code = s.app_role
$$;

-- ---------- access: tables (area vendite), functions ----------
insert into fabula.table_areas (table_name, area, write_level, read_open) values
 ('trade_applications', 'vendite', 2, false), ('trade_products', 'vendite', 3, false), ('trade_price_tiers', 'vendite', 3, false),
 ('trade_schedules', 'vendite', 2, false), ('trade_schedule_days', 'vendite', 2, false), ('trade_schedule_lines', 'vendite', 2, false),
 ('trade_exceptions', 'vendite', 2, false), ('trade_closures', 'vendite', 3, false), ('trade_change_log', 'vendite', 2, false), ('trade_order_queue', 'vendite', 3, false)
on conflict (table_name) do update set area = excluded.area, write_level = excluded.write_level, read_open = excluded.read_open;

do $$ declare t text; begin
  foreach t in array array['trade_applications','trade_products','trade_price_tiers','trade_schedules','trade_schedule_days','trade_schedule_lines','trade_exceptions','trade_closures','trade_change_log','trade_order_queue'] loop
    execute format('alter table fabula.%I enable row level security', t);
    execute format('create policy %I on fabula.%I for all to authenticated using (true) with check (true)', t || '_authenticated_all', t);
    execute format('create policy %I on fabula.%I as restrictive for select to authenticated using ((select fabula.can_table(%L, false)))', t || '_role_select', t, t);
    execute format('create policy %I on fabula.%I as restrictive for insert to authenticated with check ((select fabula.can_table(%L, true)))', t || '_role_insert', t, t);
    execute format('create policy %I on fabula.%I as restrictive for update to authenticated using ((select fabula.can_table(%L, true)))', t || '_role_update', t, t);
    execute format('create policy %I on fabula.%I as restrictive for delete to authenticated using ((select fabula.can_table(%L, true)))', t || '_role_delete', t, t);
    execute format('grant select, insert, update, delete on fabula.%I to authenticated, service_role', t);
    execute format('revoke all on fabula.%I from anon', t);
  end loop;
  -- audit trail on the configuration tables
  foreach t in array array['trade_products','trade_price_tiers','trade_schedules','trade_exceptions','trade_closures','trade_applications'] loop
    if not exists (select 1 from pg_trigger where tgname = t || '_audit' and tgrelid = ('fabula.' || t)::regclass) then
      execute format('create trigger %I after insert or update or delete on fabula.%I for each row execute function fabula.trg_audit()', t || '_audit', t);
    end if;
  end loop;
end $$;

do $$ declare f text; begin
  -- staff + service
  foreach f in array array['trade_settings()','trade_cutoff_at(date)','trade_can_change(date)','trade_is_closed(date)','trade_is_delivery_day(date)','trade_week_qty(uuid,text)',
    'trade_price(uuid,text,numeric,boolean)','trade_effective_lines(date)','trade_upcoming(date,int,uuid)','trade_daily_totals(date,int)','trade_wd_it(int)','trade_now_rome()',
    'trade_approve(uuid,text)','trade_reject(uuid,text)','trade_customers()','trade_staff_action(uuid,text,jsonb,boolean)','trade_push_queue(boolean)'] loop
    execute format('revoke all on function fabula.%s from public, anon', f);
    execute format('grant execute on function fabula.%s to authenticated, service_role', f);
  end loop;
  -- service only (token / secret paths)
  foreach f in array array['trade_party_by_token(text)','trade_portal_state(text)','trade_portal_action(text,text,jsonb)','trade_apply(jsonb)','trade_approve_done(uuid,uuid,text,text,text,text)',
    'trade_queue_pending()','trade_queue_result(uuid,boolean,text,text,text,text)','trade_portal_state_for(uuid)','trade_save_schedule(uuid,jsonb,text)','trade_add_exception(uuid,jsonb,text,boolean)',
    'trade_cancel_exception(uuid,uuid,text,boolean)','trade_set_status(uuid,text,date,text)','trade_log(uuid,text,text,jsonb,text)','trade_is_b2b_row(jsonb,uuid)'] loop
    execute format('revoke all on function fabula.%s from public, anon, authenticated', f);
    execute format('grant execute on function fabula.%s to service_role', f);
  end loop;
end $$;

-- pg_cron: push the queue to Shopify right after the 18:20 booking (both UTC slots; the function is a no-op when nothing is pending) and hourly retry
select cron.schedule('fabula_trade_push', '25 16,17 * * 1-6', $c$select fabula.trade_push_queue(true)$c$);
select cron.schedule('fabula_trade_push_retry', '50 * * * *', $c$select fabula.trade_push_queue(true)$c$);

-- v0.72 placeholder standing orders are out of the new engine (they never had a trade plan); nothing else to migrate on 06/10/2026.

-- the base plan only reads active days (v0.83b adds trade_schedule_days.active)
create or replace function fabula.trade_effective_lines(p_date date)
returns table (customer_id uuid, variant_id text, product_id uuid, qty numeric, kg numeric, recurring boolean, window_code text,
               delivery_address text, delivery_instructions text, po_number text, source text)
language sql stable set search_path = fabula, public as $$
  with s as (select fabula.trade_settings() j),
  wd as (select extract(isodow from p_date)::int d),
  ok_day as (select fabula.trade_is_delivery_day(p_date) ok),
  cust as (
    select ts.customer_id, ts.window_code sched_window, ts.delivery_address, ts.delivery_instructions, ts.po_number,
           (ts.status = 'active' and ts.start_date <= p_date and (ts.end_date is null or ts.end_date >= p_date)) as plan_on,
           (ts.status <> 'cancelled') as plan_exists
    from fabula.trade_schedules ts join fabula.parties p on p.id = ts.customer_id
    where p.active and p.trade_status = 'approved' and not fabula.is_placeholder_party(p.id)),
  skip as (select e.customer_id from fabula.trade_exceptions e where e.kind = 'skip' and e.cancelled_at is null and p_date between e.date_from and e.date_to),
  base as (
    select c.customer_id, l.variant_id, l.qty, true as recurring, 'piano' as source
    from cust c join wd on true join ok_day on true
    join fabula.trade_schedule_days d on d.customer_id = c.customer_id and d.weekday = wd.d and d.active
    join fabula.trade_schedule_lines l on l.customer_id = c.customer_id and l.weekday = wd.d
    where c.plan_on and ok_day.ok and c.customer_id not in (select customer_id from skip) and l.qty > 0),
  ov as (
    select e.customer_id, e.variant_id, e.qty,
           exists (select 1 from base b where b.customer_id = e.customer_id) as recurring, 'modifica' as source
    from fabula.trade_exceptions e join cust c on c.customer_id = e.customer_id join ok_day on true
    where e.kind = 'override' and e.cancelled_at is null and p_date between e.date_from and e.date_to and ok_day.ok
      and c.plan_exists and e.customer_id not in (select customer_id from skip)),
  merged as (
    select * from ov
    union all
    select b.* from base b where not exists (select 1 from ov where ov.customer_id = b.customer_id and ov.variant_id = b.variant_id)),
  win as (select e.customer_id, e.window_code from fabula.trade_exceptions e where e.kind = 'window' and e.cancelled_at is null and p_date between e.date_from and e.date_to)
  select m.customer_id, m.variant_id, tp.product_id, m.qty, round(m.qty * tp.kg_per_unit, 3) as kg, m.recurring,
         coalesce((select w.window_code from win w where w.customer_id = m.customer_id limit 1),
                  (select d.window_code from fabula.trade_schedule_days d where d.customer_id = m.customer_id and d.weekday = (select d from wd) and d.active),
                  c.sched_window, (select j->>'default_window' from s)) as window_code,
         coalesce(c.delivery_address, p.delivery_address, concat_ws(', ', p.address, p.postcode, p.city)) as delivery_address,
         coalesce(c.delivery_instructions, p.delivery_instructions) as delivery_instructions,
         c.po_number, m.source
  from merged m join cust c on c.customer_id = m.customer_id join fabula.parties p on p.id = m.customer_id
  join fabula.trade_products tp on tp.variant_id = m.variant_id
  where m.qty > 0 and tp.active and tp.trade_price_eur is not null
$$;
