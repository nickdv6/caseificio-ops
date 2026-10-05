-- v0.72a (05/10/2026) · Placeholder customers stop generating orders; routine bot messages read themselves.
-- 1. Standing orders of a placeholder customer (parties.notes/source = 'placeholder', i.e. "Cliente 1/2" not yet renamed in
--    the console) are no longer booked by confirm_standing_orders (bot or database stand-in): they inflated the milk plan
--    sent to the farm (it counts confirmed wholesale orders) and piled up as late orders in Da spedire. The orders of
--    placeholder customers already booked and not shipped are cancelled, now and at every run. Renaming the customer in
--    the console clears the flag and booking resumes by itself.
-- 2. Bot messages with severity info older than 24 h are marked read automatically (pg_cron hourly), so the bell counts
--    only what is new or needs attention. Warnings and alerts stay unread until someone reads them.

create or replace function fabula.is_placeholder_party(p_id uuid) returns boolean
language sql stable set search_path = fabula, public as $$
  select coalesce((select notes = 'placeholder' or source = 'placeholder' from fabula.parties where id = p_id), false)
$$;

-- cancel the not-yet-shipped standing orders of placeholder customers
create or replace function fabula.cancel_placeholder_orders() returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare v jsonb;
begin
  with c as (
    update fabula.sales_orders o
       set status = 'cancelled', updated_at = now(),
           notes = concat_ws(' · ', nullif(o.notes, ''), 'annullato: cliente segnaposto (v0.72)')
     where o.status = 'confirmed' and o.source = 'standing_order' and o.channel = 'wholesale'
       and fabula.is_placeholder_party(o.customer_id)
       and not exists (select 1 from fabula.shipments sh where sh.sales_order_id = o.id)
    returning o.order_number)
  select coalesce(jsonb_agg(order_number order by order_number), '[]') into v from c;
  return v;
end $$;
revoke all on function fabula.cancel_placeholder_orders() from public, anon, authenticated;

create or replace function fabula.confirm_standing_orders(p_date date default null::date) returns jsonb
language plpgsql set search_path = fabula, public, extensions as $$
declare d date; c record; l record; v_order uuid; v_total numeric; v_price numeric; n int := 0; msgs jsonb := '[]'; lines_txt text; v_num text; v_lines int;
        v_cancelled jsonb; v_skipped jsonb;
        wd constant text[] := array['lunedì','martedì','mercoledì','giovedì','venerdì','sabato','domenica'];
begin
  d := coalesce(p_date, (now() at time zone 'Europe/Rome')::date + 1);
  if extract(isodow from d) = 7 then d := d + 1; end if;
  v_cancelled := fabula.cancel_placeholder_orders();   -- v0.72
  select coalesce(jsonb_agg(distinct p.legal_name), '[]') into v_skipped
    from fabula.standing_orders s join fabula.parties p on p.id = s.customer_id
   where s.active and s.weekday = extract(isodow from d) and fabula.is_placeholder_party(s.customer_id);
  for c in select distinct s.customer_id, p.legal_name, p.phone from fabula.standing_orders s join fabula.parties p on p.id = s.customer_id
           where s.active and s.weekday = extract(isodow from d) and not fabula.is_placeholder_party(s.customer_id) order by p.legal_name loop
    if exists (select 1 from fabula.sales_orders o where o.customer_id = c.customer_id and o.order_date = d and o.channel = 'wholesale' and o.source = 'standing_order' and o.status <> 'cancelled') then
      select order_number into v_num from fabula.sales_orders o where o.customer_id = c.customer_id and o.order_date = d and o.channel = 'wholesale' and o.source = 'standing_order' and o.status <> 'cancelled' limit 1;
      msgs := msgs || jsonb_build_object('customer', c.legal_name, 'phone', c.phone, 'already_booked', true, 'order_number', v_num); continue;
    end if;
    v_num := 'WS-' || to_char(d, 'YYMMDD') || '-' || lpad((select count(*) + 1 from fabula.sales_orders where order_date = d and channel = 'wholesale')::text, 2, '0');
    while exists (select 1 from fabula.sales_orders where order_number = v_num) loop
      v_num := v_num || 'b';
    end loop;
    insert into fabula.sales_orders (order_number, channel, order_date, customer_id, status, source, notes)
    values (v_num, 'wholesale', d, c.customer_id, 'confirmed', 'standing_order', 'ordine fisso ' || wd[extract(isodow from d)]) returning id into v_order;
    v_total := 0; lines_txt := ''; v_lines := 0;
    for l in select s.qty_kg, s.unit_price_eur, pr.id product_id, pr.name, pr.iva_rate, pr.sku from fabula.standing_orders s join fabula.products pr on pr.id = s.product_id
             where s.active and s.customer_id = c.customer_id and s.weekday = extract(isodow from d) loop
      v_price := coalesce(l.unit_price_eur, case when l.sku = 'MOZ-DOP-KG' then fabula.setting_num('price.wholesale_moz_eur_kg', 11.5) else 0 end);
      insert into fabula.sales_order_lines (sales_order_id, product_id, qty, unit_price_eur, iva_rate) values (v_order, l.product_id, l.qty_kg, v_price, coalesce(l.iva_rate, 4));
      v_total := v_total + l.qty_kg * v_price; v_lines := v_lines + 1;
      lines_txt := lines_txt || format('%s kg %s', trim_scale(l.qty_kg), l.name) || ', ';
    end loop;
    lines_txt := rtrim(lines_txt, ', ');
    update fabula.sales_orders set subtotal_eur = round(v_total, 2), iva_eur = round(v_total * 0.04, 2), total_eur = round(v_total * 1.04, 2) where id = v_order;
    n := n + 1;
    msgs := msgs || jsonb_build_object('customer', c.legal_name, 'phone', c.phone, 'order_number', v_num, 'lines', v_lines, 'total_eur', round(v_total, 2),
      'message_it', format('Buongiorno, ' || fabula.company_name(true) || ' conferma per %s %s: %s. Consegna in mattinata. Per cambiare quantità basta rispondere entro le 19:00. Grazie!', wd[extract(isodow from d)], to_char(d, 'DD/MM'), lines_txt));
  end loop;
  return jsonb_build_object('date', d, 'weekday', wd[extract(isodow from d)], 'booked', n, 'customers', msgs,
    'total_kg', (select coalesce(sum(sl.qty), 0) from fabula.sales_order_lines sl join fabula.sales_orders o on o.id = sl.sales_order_id where o.order_date = d and o.channel = 'wholesale' and o.status = 'confirmed'),
    'is_placeholder', jsonb_array_length(v_skipped) > 0,
    'skipped_placeholder', v_skipped, 'cancelled_placeholder', v_cancelled);
end $$;

-- routine messages read themselves after 24 h
create or replace function fabula.bot_messages_autoread(p_now timestamptz default now()) returns int
language plpgsql security definer set search_path = fabula, public as $$
declare n int;
begin
  update fabula.bot_messages set read_at = p_now
   where read_at is null and severity = 'info' and created_at < p_now - interval '24 hours';
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function fabula.bot_messages_autoread(timestamptz) from public, anon, authenticated;

select cron.schedule('fabula_bot_messages_autoread', '17 * * * *', $c$select fabula.bot_messages_autoread()$c$);

-- apply now
select fabula.cancel_placeholder_orders();
select fabula.bot_messages_autoread();
