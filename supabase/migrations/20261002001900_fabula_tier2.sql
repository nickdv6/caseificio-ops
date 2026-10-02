-- =============================================================================
-- v0.19: Tier 2 with placeholders — rename the parties in the console when real.
--   * Parties: Fornitore 1 (imballi), Fornitore 2 (caglio, sale), Fornitore 3
--     (acido citrico, fuscelle) replace the SIM suppliers as preferred suppliers;
--     Cliente 1, Cliente 2 are wholesale customers. All notes = 'placeholder'.
--   * Standing orders: weekday → kg per customer (~10 kg/day total to start).
--     confirm_standing_orders(date) books tomorrow's confirmed wholesale orders
--     and returns a WhatsApp-ready confirmation per customer. plan_milk() already
--     prefers confirmed orders over history.
--   * PO send: po_send_package(po) returns email + WhatsApp text; mark_po_sent().
--   * Farm supply: farm_supply (date, kg available) from the Masseria; plan_milk
--     flags when the plan exceeds what the farm can deliver.
--   * Consorzio: consorzio_declaration(month) compiles the monthly DOP declaration
--     (milk in, mozzarella out, labels used) → approvals kind dop_declaration.
-- Written without destructive keywords (connector rule).
-- =============================================================================
set search_path = fabula, public;

-- 1. placeholder parties ------------------------------------------------------
insert into fabula.parties (type, legal_name, email, phone, payment_terms_days, notes)
select * from (values
  ('supplier'::fabula.party_type, 'Fornitore 1 (imballi)',              'ordini@fornitore1.example', '+39 000 000 0001', 30, 'placeholder'),
  ('supplier'::fabula.party_type, 'Fornitore 2 (caglio, sale)',         'ordini@fornitore2.example', '+39 000 000 0002', 30, 'placeholder'),
  ('supplier'::fabula.party_type, 'Fornitore 3 (acido citrico, fuscelle)', 'ordini@fornitore3.example', '+39 000 000 0003', 30, 'placeholder'),
  ('customer'::fabula.party_type, 'Cliente 1',                           null, '+39 000 000 0101', 30, 'placeholder'),
  ('customer'::fabula.party_type, 'Cliente 2',                           null, '+39 000 000 0102', 30, 'placeholder')
) v(type, legal_name, email, phone, payment_terms_days, notes)
where not exists (select 1 from fabula.parties p where p.legal_name = v.legal_name);

update fabula.products p set preferred_supplier_id = s.id from fabula.parties s
 where s.legal_name = 'Fornitore 1 (imballi)' and p.sku in ('PKG-BAG-500');
update fabula.products p set preferred_supplier_id = s.id from fabula.parties s
 where s.legal_name = 'Fornitore 2 (caglio, sale)' and p.sku in ('CON-SALT','CON-RENNET');
update fabula.products p set preferred_supplier_id = s.id, reorder_point = coalesce(p.reorder_point, case p.sku when 'CON-CITRIC' then 2 else 400 end),
       reorder_qty = coalesce(p.reorder_qty, case p.sku when 'CON-CITRIC' then 10 else 2000 end)
  from fabula.parties s where s.legal_name = 'Fornitore 3 (acido citrico, fuscelle)' and p.sku in ('CON-CITRIC','PKG-FUSC-250');
-- carry the SIM list prices over to the placeholders (source placeholder) so procurement keeps a price
insert into fabula.supplier_prices (supplier_id, product_id, price_eur, valid_from, source)
select p.preferred_supplier_id, p.id, v.price, date '2026-01-01', 'placeholder'
from fabula.products p join (values ('PKG-BAG-500', 0.085), ('CON-SALT', 0.42), ('CON-RENNET', 38.00), ('CON-CITRIC', 4.50), ('PKG-FUSC-250', 0.12)) v(sku, price) on v.sku = p.sku
where p.preferred_supplier_id is not null
  and not exists (select 1 from fabula.supplier_prices sp where sp.supplier_id = p.preferred_supplier_id and sp.product_id = p.id);

-- 2. standing orders -----------------------------------------------------------
create table if not exists fabula.standing_orders (
  id          uuid primary key default gen_random_uuid(),
  customer_id uuid not null references fabula.parties(id),
  product_id  uuid not null references fabula.products(id),
  weekday     int not null check (weekday between 1 and 7),       -- 1 = lunedì
  qty_kg      numeric(10,2) not null check (qty_kg > 0),
  unit_price_eur numeric(12,4),                                    -- null = settings price.wholesale_moz_eur_kg
  active      boolean not null default true,
  notes       text,
  unique (customer_id, product_id, weekday)
);
grant all on fabula.standing_orders to authenticated, service_role;
alter table fabula.standing_orders enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='fabula' and tablename='standing_orders' and policyname='standing_orders_authenticated_all') then
    create policy standing_orders_authenticated_all on fabula.standing_orders for all to authenticated using (true) with check (true);
  end if;
end $$;
insert into fabula.settings (key, value, description) values ('price.wholesale_moz_eur_kg', '11.50', 'Prezzo ingrosso mozzarella €/kg (default per gli ordini fissi)') on conflict (key) do nothing;

-- ~10 kg/day: Cliente 1 6 kg Mon–Sat, Cliente 2 4 kg Mon–Sat
insert into fabula.standing_orders (customer_id, product_id, weekday, qty_kg, notes)
select c.id, p.id, d, case c.legal_name when 'Cliente 1' then 6 else 4 end, 'placeholder'
from fabula.parties c cross join fabula.products p cross join generate_series(1, 6) d
where c.legal_name in ('Cliente 1','Cliente 2') and p.sku = 'MOZ-DOP-KG'
  and not exists (select 1 from fabula.standing_orders s where s.customer_id = c.id and s.product_id = p.id and s.weekday = d);

create or replace view fabula.v_standing_orders as
select s.id, c.legal_name as customer, c.phone, p.sku, p.name as product, s.weekday, s.qty_kg, s.unit_price_eur, s.active, s.notes, s.customer_id, s.product_id
from fabula.standing_orders s join fabula.parties c on c.id = s.customer_id join fabula.products p on p.id = s.product_id
order by c.legal_name, p.sku, s.weekday;
grant select on fabula.v_standing_orders to authenticated, service_role;

-- books the confirmed orders for p_date (default tomorrow Rome; Sunday → Monday); idempotent
create or replace function fabula.confirm_standing_orders(p_date date default null)
returns jsonb language plpgsql as $$
declare d date; c record; l record; v_order uuid; v_total numeric; v_price numeric; n int := 0; msgs jsonb := '[]'; lines_txt text; v_num text; v_lines int;
        wd constant text[] := array['lunedì','martedì','mercoledì','giovedì','venerdì','sabato','domenica'];
begin
  d := coalesce(p_date, (now() at time zone 'Europe/Rome')::date + 1);
  if extract(isodow from d) = 7 then d := d + 1; end if;
  for c in select distinct s.customer_id, p.legal_name, p.phone from fabula.standing_orders s join fabula.parties p on p.id = s.customer_id
           where s.active and s.weekday = extract(isodow from d) order by p.legal_name loop
    if exists (select 1 from fabula.sales_orders o where o.customer_id = c.customer_id and o.order_date = d and o.channel = 'wholesale' and o.source = 'standing_order') then
      select order_number into v_num from fabula.sales_orders o where o.customer_id = c.customer_id and o.order_date = d and o.channel = 'wholesale' and o.source = 'standing_order' limit 1;
      msgs := msgs || jsonb_build_object('customer', c.legal_name, 'phone', c.phone, 'already_booked', true, 'order_number', v_num); continue;
    end if;
    v_num := 'WS-' || to_char(d, 'YYMMDD') || '-' || lpad((select count(*) + 1 from fabula.sales_orders where order_date = d and channel = 'wholesale')::text, 2, '0');
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
      'message_it', format('Buongiorno, La Perla del Cilento conferma per %s %s: %s. Consegna in mattinata. Per cambiare quantità basta rispondere entro le 19:00. Grazie!', wd[extract(isodow from d)], to_char(d, 'DD/MM'), lines_txt));
  end loop;
  return jsonb_build_object('date', d, 'weekday', wd[extract(isodow from d)], 'booked', n, 'customers', msgs,
    'total_kg', (select coalesce(sum(sl.qty), 0) from fabula.sales_order_lines sl join fabula.sales_orders o on o.id = sl.sales_order_id where o.order_date = d and o.channel = 'wholesale' and o.status = 'confirmed'),
    'is_placeholder', exists (select 1 from fabula.standing_orders where notes = 'placeholder' and active));
end $$;
grant execute on function fabula.confirm_standing_orders(date) to authenticated, service_role;

-- 3. send an approved PO -----------------------------------------------------------
alter table fabula.purchase_orders add column if not exists sent_at timestamptz, add column if not exists sent_via text;
create or replace function fabula.po_send_package(p_po_number text)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'po_number', po.po_number, 'status', po.status, 'supplier', s.legal_name, 'email', s.email, 'phone', s.phone, 'expected_date', po.expected_date,
    'subject', format('Ordine %s — La Perla del Cilento', po.po_number),
    'body_it', format(E'Buongiorno,\ncon la presente ordiniamo:\n%s\nConsegna richiesta entro il %s presso La Perla del Cilento, Agropoli (SA).\nRiferimento ordine: %s. Pagamento a %s giorni.\nGrazie e cordiali saluti,\nLa Perla del Cilento',
      (select string_agg(format('- %s %s %s a € %s/%s', trim_scale(l.qty_ordered), p.unit, p.name, trim_scale(l.unit_price_eur), p.unit), E'\n') from fabula.purchase_order_lines l join fabula.products p on p.id = l.product_id where l.purchase_order_id = po.id),
      to_char(po.expected_date, 'DD/MM/YYYY'), po.po_number, coalesce(s.payment_terms_days, 30)),
    'whatsapp_it', format('Buongiorno, La Perla del Cilento ordina: %s. Consegna entro il %s ad Agropoli. Rif. %s. Grazie!',
      (select string_agg(format('%s %s %s', trim_scale(l.qty_ordered), p.unit, p.name), ', ') from fabula.purchase_order_lines l join fabula.products p on p.id = l.product_id where l.purchase_order_id = po.id),
      to_char(po.expected_date, 'DD/MM'), po.po_number),
    'total_eur', po.subtotal_eur)
  from fabula.purchase_orders po join fabula.parties s on s.id = po.supplier_id where po.po_number = p_po_number
$$;
create or replace function fabula.mark_po_sent(p_po_number text, p_via text default 'email')
returns text language plpgsql as $$
begin
  update fabula.purchase_orders set status = 'sent', sent_at = now(), sent_via = p_via where po_number = p_po_number and status = 'approved';
  if not found then raise exception 'Ordine % non in stato approvato', p_po_number; end if;
  return 'sent';
end $$;
grant execute on function fabula.po_send_package(text), fabula.mark_po_sent(text, text) to authenticated, service_role;

create or replace view fabula.v_pos_to_send as
select po.po_number, s.legal_name as supplier, s.email, s.phone, po.subtotal_eur, po.expected_date, po.updated_at as approved_at,
       (now() at time zone 'Europe/Rome')::date - po.updated_at::date as days_waiting
from fabula.purchase_orders po join fabula.parties s on s.id = po.supplier_id where po.status = 'approved' order by po.updated_at;
grant select on fabula.v_pos_to_send to authenticated, service_role;

-- 4. farm milk supply ----------------------------------------------------------------
create table if not exists fabula.farm_supply (
  supply_date date primary key,
  kg_available numeric(10,1) not null check (kg_available >= 0),
  source text not null default 'manual',
  notes text,
  updated_at timestamptz not null default now()
);
grant all on fabula.farm_supply to authenticated, service_role;
alter table fabula.farm_supply enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='fabula' and tablename='farm_supply' and policyname='farm_supply_authenticated_all') then
    create policy farm_supply_authenticated_all on fabula.farm_supply for all to authenticated using (true) with check (true);
  end if;
end $$;
insert into fabula.settings (key, value, description) values ('farm.default_kg_per_day', '1300', 'Latte disponibile dalla Masseria quando non c''è un dato per il giorno (kg)') on conflict (key) do nothing;
create or replace function fabula.farm_kg_available(p_date date) returns numeric language sql stable as $$
  select coalesce((select kg_available from fabula.farm_supply where supply_date = p_date), fabula.setting_num('farm.default_kg_per_day', 1300))
$$;
grant execute on function fabula.farm_kg_available(date) to authenticated, service_role;

-- 5. Consorzio monthly declaration ------------------------------------------------------
create or replace function fabula.consorzio_declaration(p_month date default null)
returns jsonb language plpgsql as $$
declare m0 date; m1 date; j jsonb; v_appr uuid;
begin
  m0 := date_trunc('month', coalesce(p_month, (date_trunc('month', (now() at time zone 'Europe/Rome')::date) - interval '1 month')::date))::date;
  m1 := (m0 + interval '1 month')::date - 1;
  select jsonb_build_object('month', to_char(m0, 'YYYY-MM'), 'from', m0, 'to', m1,
    'milk_in_kg', (select coalesce(sum(qty_kg), 0) from fabula.milk_intake where accepted and intake_date between m0 and m1),
    'milk_suppliers', (select coalesce(jsonb_agg(jsonb_build_object('supplier', p.legal_name, 'kg', kg, 'dop_certified', p.is_dop_certified)), '[]')
                       from (select supplier_id, round(sum(qty_kg), 1) kg from fabula.milk_intake where accepted and intake_date between m0 and m1 group by supplier_id) x join fabula.parties p on p.id = x.supplier_id),
    'milk_processed_kg', (select coalesce(sum(b.milk_in_kg), 0) from fabula.production_batches b join fabula.products p on p.id = b.product_id where p.sku = 'MOZ-DOP-KG' and b.batch_date between m0 and m1 and b.output_kg is not null),
    'mozzarella_dop_kg', (select coalesce(sum(b.output_kg), 0) from fabula.production_batches b join fabula.products p on p.id = b.product_id where p.sku = 'MOZ-DOP-KG' and b.batch_date between m0 and m1),
    'batches', (select count(*) from fabula.production_batches b join fabula.products p on p.id = b.product_id where p.sku = 'MOZ-DOP-KG' and b.batch_date between m0 and m1 and b.output_kg is not null),
    'labels_printed', (select coalesce(sum(qty_printed), 0) from fabula.labels l where l.kind in ('batch_lot','retail_pack','wholesale_case') and l.printed_at::date between m0 and m1),
    'lots', (select coalesce(jsonb_agg(b.batch_lot order by b.batch_date), '[]') from fabula.production_batches b join fabula.products p on p.id = b.product_id where p.sku = 'MOZ-DOP-KG' and b.batch_date between m0 and m1 and b.output_kg is not null),
    'sold_kg', (select coalesce(-sum(sm.qty), 0) from fabula.stock_moves sm join fabula.products p on p.id = sm.product_id where p.sku = 'MOZ-DOP-KG' and sm.move_type = 'sale' and sm.moved_at::date between m0 and m1),
    'note', 'Bozza dai dati di produzione; il formato ufficiale del Consorzio va confermato con i partner (modulo / portale).') into j;
  if not exists (select 1 from fabula.approvals where kind = 'dop_declaration' and payload->>'month' = to_char(m0, 'YYYY-MM') and status in ('pending','approved')) then
    insert into fabula.approvals (kind, requested_by, summary, payload, related_table)
    values ('dop_declaration', 'agent:monthly_review',
            format('Dichiarazione Consorzio %s: latte %s kg → mozzarella DOP %s kg in %s lotti, %s etichette', to_char(m0, 'MM/YYYY'), round((j->>'milk_processed_kg')::numeric), round((j->>'mozzarella_dop_kg')::numeric), j->>'batches', j->>'labels_printed'),
            j, 'consorzio') returning id into v_appr;
    j := j || jsonb_build_object('approval_id', v_appr, 'approval_created', true);
  else
    j := j || jsonb_build_object('approval_created', false);
  end if;
  return j;
end $$;
grant execute on function fabula.consorzio_declaration(date) to authenticated, service_role;

-- 6. integration: plan_milk vs farm supply, health check, expected bots -----------------------
-- plan_milk: same signature; new setting milk.cap_to_farm (1 = never plan more than the Masseria can deliver).
insert into fabula.settings (key, value, description) values ('milk.cap_to_farm', '1', 'Limita il piano latte alla disponibilità della Masseria (1 = sì, 0 = solo avviso)') on conflict (key) do nothing;
create or replace function fabula.plan_milk(p_date date default null, p_capacity_kg numeric default null, p_round_kg numeric default null, p_safety_pct numeric default null)
returns jsonb language plpgsql as $$
declare
  d date; v_moz uuid; v_n int; v_total numeric; v_whole_hist numeric; v_whole_conf numeric; v_retail numeric; v_whole numeric;
  v_carry numeric; v_safety numeric; v_out numeric; v_yield numeric; v_yield_src text; v_milk numeric; v_milk_r numeric; v_cap boolean := false;
  v_price numeric; v_cost numeric; v_last_milk numeric; v_waste numeric; v_hist_src text; v_id uuid; v_appr uuid; v_rat text; v_sim boolean;
  v_dates date[]; v_carry_raw numeric; v_min boolean := false; v_wd text;
  v_farm numeric; v_farm_hit boolean := false; v_farm_short numeric := 0; v_farm_surplus numeric := 0; v_farm_cap boolean;
  wd constant text[] := array['lunedì','martedì','mercoledì','giovedì','venerdì','sabato','domenica'];
  p_carry_pct numeric; p_min_kg numeric;
begin
  p_capacity_kg := coalesce(p_capacity_kg, fabula.setting_num('milk.capacity_kg', 1200));
  p_round_kg    := coalesce(p_round_kg,    fabula.setting_num('milk.round_kg', 25));
  p_safety_pct  := coalesce(p_safety_pct,  fabula.setting_num('milk.safety_pct', 10));
  p_carry_pct   := fabula.setting_num('milk.carry_pct', 50);
  p_min_kg      := fabula.setting_num('milk.min_run_kg', 300);
  v_farm_cap    := fabula.setting_num('milk.cap_to_farm', 1) = 1;
  d := coalesce(p_date, (now() at time zone 'Europe/Rome')::date + 1);
  if extract(isodow from d) = 7 then d := d + 1; end if;
  v_dates := array[d-7, d-14, d-21, d-28]; v_wd := wd[extract(isodow from d)];
  select id into v_moz from fabula.products where sku = 'MOZ-DOP-KG';
  v_farm := fabula.farm_kg_available(d);

  if exists (select 1 from fabula.milk_plans where plan_date = d and status in ('proposed','approved')) then
    return jsonb_build_object('date', d, 'skipped', 'plan_exists',
      'plan', (select jsonb_build_object('milk_kg', milk_kg, 'status', status, 'planned_output_kg', planned_output_kg) from fabula.milk_plans where plan_date = d and status in ('proposed','approved')));
  end if;

  select count(*), coalesce(avg(total),0), coalesce(avg(whole),0) into v_n, v_total, v_whole_hist from (
    select sm.moved_at::date sd, sum(-sm.qty) total, sum(case when so.channel = 'wholesale' then -sm.qty else 0 end) whole
    from fabula.stock_moves sm left join fabula.sales_orders so on so.id = sm.sales_order_id
    where sm.product_id = v_moz and sm.move_type = 'sale' and sm.moved_at::date = any(v_dates)
    group by sm.moved_at::date) x;
  v_hist_src := 'same_weekday_4w';
  if v_n = 0 then
    select count(*), coalesce(avg(total),0) into v_n, v_total from (
      select sm.moved_at::date sd, sum(-sm.qty) total from fabula.stock_moves sm
      where sm.product_id = v_moz and sm.move_type = 'sale' and sm.moved_at::date between d-28 and d-1 group by sm.moved_at::date) x;
    v_whole_hist := 0; v_hist_src := case when v_n > 0 then 'any_day_28d' else 'none' end;
  end if;
  select coalesce(sum(l.qty),0) into v_whole_conf from fabula.sales_order_lines l join fabula.sales_orders o on o.id = l.sales_order_id
   where l.product_id = v_moz and o.channel = 'wholesale' and o.order_date = d and o.status = 'confirmed';
  v_retail := round(v_total - v_whole_hist, 1);
  v_whole  := round(case when v_whole_conf > 0 then v_whole_conf else v_whole_hist end, 1);

  select coalesce(sum(qty_on_hand),0) into v_carry_raw from fabula.v_stock_on_hand where product_id = v_moz and expiry_date >= d + 3;
  v_carry := round(v_carry_raw * p_carry_pct / 100, 1);

  v_safety := round((v_retail + v_whole) * p_safety_pct / 100, 1);
  v_out := greatest(0, round(v_retail + v_whole + v_safety - v_carry, 1));

  select round(avg(yield_pct),2) into v_yield from fabula.production_batches where product_id = v_moz and output_kg is not null and batch_date between d-30 and d-1;
  v_yield_src := 'avg_30d'; if v_yield is null or v_yield <= 0 then v_yield := 30; v_yield_src := 'assumption'; end if;

  if v_hist_src = 'none' then
    select round(avg(qty_kg),1) into v_milk from fabula.milk_intake where accepted and intake_date between d-28 and d-1;
    v_milk := coalesce(v_milk, p_capacity_kg); v_out := round(v_milk * v_yield / 100, 1);
  else
    v_milk := round(v_out / v_yield * 100, 1);
  end if;
  v_milk_r := ceil(v_milk / p_round_kg) * p_round_kg;
  if v_milk_r < p_min_kg then v_milk_r := p_min_kg; v_min := true; end if;
  if v_milk_r > p_capacity_kg then v_milk_r := p_capacity_kg; v_cap := true; end if;
  -- Masseria supply check
  if v_milk_r > v_farm then
    v_farm_short := v_milk_r - v_farm; v_farm_hit := true;
    if v_farm_cap then v_milk_r := floor(v_farm / p_round_kg) * p_round_kg; v_out := round(v_milk_r * v_yield / 100, 1); end if;
  else
    v_farm_surplus := v_farm - v_milk_r;
  end if;

  select coalesce(round(avg(price_eur_per_kg),4), 1.30) into v_price from fabula.milk_intake where intake_date between d-30 and d-1 and price_eur_per_kg is not null;
  v_cost := round(v_milk_r * v_price, 2);
  select round(avg(t),0) into v_last_milk from (select sum(qty_kg) t from fabula.milk_intake where accepted and intake_date = any(v_dates) group by intake_date) x;
  select round(coalesce(avg(t),0),0) into v_waste from (select sum(qty) t from fabula.waste_log where product_id = v_moz and wasted_at::date = any(v_dates) group by wasted_at::date) x;
  v_sim := exists (select 1 from fabula.simulation_runs where d-28 between from_date and to_date or d-7 between from_date and to_date);

  v_rat := format('Piano latte %s (%s): vendite medie stesso giorno ultime 4 sett. %s kg%s, giacenza fresca %s kg, margine %s%% → produzione %s kg; resa %s%% → latte %s kg%s. Masseria disponibile %s kg%s. Ultime 4 sett. stesso giorno: latte %s kg, scarti %s kg. Costo stimato € %s.',
    to_char(d, 'DD/MM'), v_wd, round(v_retail + v_whole_hist, 0),
    case when v_whole_conf > 0 then format(' + ordini ingrosso confermati %s kg', trim_scale(v_whole_conf)) when v_whole_hist > 0 then format(' (ingrosso %s kg)', round(v_whole_hist,0)) else '' end,
    round(v_carry,0), p_safety_pct, v_out, v_yield, v_milk_r, case when v_cap then ' (CAPACITÀ MASSIMA)' when v_min then ' (LOTTO MINIMO)' else '' end,
    trim_scale(v_farm), case when v_farm_hit and v_farm_cap then format(' → LIMITATO ALLA MASSERIA, mancano %s kg', trim_scale(v_farm_short)) when v_farm_hit then format(' → ATTENZIONE: servono %s kg in più da altri fornitori', trim_scale(v_farm_short)) when v_farm_surplus > 0 then format(' (avanzano %s kg)', trim_scale(v_farm_surplus)) else '' end,
    coalesce(v_last_milk::text, 'n/d'), v_waste, v_cost);

  insert into fabula.milk_plans (plan_date, demand_retail_kg, demand_wholesale_kg, carry_kg, safety_kg, planned_output_kg, yield_pct_used, milk_kg, est_cost_eur, rationale, details)
  values (d, v_retail, v_whole, v_carry, v_safety, v_out, v_yield, v_milk_r, v_cost, v_rat,
          jsonb_build_object('history_source', v_hist_src, 'history_days', v_n, 'yield_source', v_yield_src, 'milk_unrounded_kg', v_milk, 'capacity_hit', v_cap, 'min_run_applied', v_min, 'carry_raw_kg', v_carry_raw, 'carry_pct', p_carry_pct,
                             'price_eur_per_kg', v_price, 'last_4w_same_weekday_milk_kg', v_last_milk, 'last_4w_same_weekday_waste_kg', v_waste,
                             'wholesale_confirmed_kg', v_whole_conf, 'est_whey_kg', round(v_milk_r * 0.62, 0), 'est_ricotta_kg', round(v_milk_r * 0.62 * 0.07, 0), 'is_simulation', v_sim,
                             'farm_kg_available', v_farm, 'exceeds_farm_supply', v_farm_hit, 'farm_shortfall_kg', v_farm_short, 'farm_surplus_kg', v_farm_surplus, 'capped_to_farm', v_farm_hit and v_farm_cap))
  returning id into v_id;

  insert into fabula.approvals (kind, requested_by, summary, payload, related_table, related_id, amount_eur, expires_at)
  values ('other', 'agent:milk_planning',
          format('Latte per %s %s: %s kg (≈ %s kg mozzarella, € %s)%s', v_wd, to_char(d,'DD/MM'), v_milk_r, v_out, v_cost,
                 case when v_farm_hit then ' · ⚠ oltre la Masseria' when v_cap then ' · capacità massima' when v_min then ' · lotto minimo' else '' end),
          jsonb_build_object('type', 'milk_plan', 'plan_date', d, 'milk_kg', v_milk_r, 'planned_output_kg', v_out, 'est_cost_eur', v_cost, 'rationale', v_rat),
          'milk_plans', v_id, v_cost, ((d::timestamp + time '06:00') at time zone 'Europe/Rome'))
  returning id into v_appr;
  update fabula.milk_plans set approval_id = v_appr where id = v_id;

  return jsonb_build_object('date', d, 'weekday', v_wd, 'is_simulation', v_sim,
    'demand', jsonb_build_object('retail_kg', v_retail, 'wholesale_kg', v_whole, 'wholesale_confirmed_kg', v_whole_conf, 'history_source', v_hist_src, 'history_days', v_n),
    'carry_kg', v_carry, 'carry_raw_kg', v_carry_raw, 'carry_pct', p_carry_pct, 'safety_kg', v_safety, 'planned_output_kg', v_out,
    'yield_pct', v_yield, 'yield_source', v_yield_src,
    'milk_kg', v_milk_r, 'milk_unrounded_kg', v_milk, 'capacity_kg', p_capacity_kg, 'capacity_hit', v_cap, 'min_kg', p_min_kg, 'min_run_applied', v_min,
    'farm', jsonb_build_object('kg_available', v_farm, 'exceeds_farm_supply', v_farm_hit, 'shortfall_kg', v_farm_short, 'surplus_kg', v_farm_surplus, 'capped_to_farm', v_farm_hit and v_farm_cap),
    'price_eur_per_kg', v_price, 'est_cost_eur', v_cost,
    'last_4w_same_weekday', jsonb_build_object('milk_kg', v_last_milk, 'waste_kg', v_waste),
    'est_whey_kg', round(v_milk_r * 0.62, 0), 'est_ricotta_kg', round(v_milk_r * 0.62 * 0.07, 0),
    'rationale', v_rat, 'plan_id', v_id, 'approval_id', v_appr);
end $$;

-- expected bots: + wholesale_orders (Mon–Sat)
create or replace function fabula.expected_bots(p_date date)
returns table(agent text) language sql immutable as $$
  select a from unnest(array['daily_brief','procurement','wholesale_orders','milk_planning','sell_down','haccp_nudge']) a where extract(isodow from p_date) between 1 and 6
  union all select 'weekly_brief' where extract(isodow from p_date) = 1
  union all select 'compliance_calendar' where extract(isodow from p_date) = 2
  union all select 'monthly_review' where extract(day from p_date) = 1
$$;

-- health check: + approved POs not sent, placeholder parties still in use
create or replace function fabula.ops_health_check(p_date date default (now() at time zone 'Europe/Rome')::date)
returns jsonb language plpgsql as $$
declare bots jsonb; dq jsonb := '[]'; n_exp int;
begin
  select jsonb_agg(jsonb_build_object('agent', e.agent, 'ran', r.n > 0, 'runs', coalesce(r.n, 0), 'errors', coalesce(r.err, 0), 'last_error', r.last_error) order by e.agent) into bots
  from fabula.expected_bots(p_date) e
  left join lateral (select count(*) n, count(*) filter (where status = 'error') err, max(error) filter (where status = 'error') last_error
                     from fabula.agent_runs ar where ar.agent = e.agent and (ar.started_at at time zone 'Europe/Rome')::date = p_date) r on true;
  update fabula.approvals set status = 'expired' where status = 'pending' and expires_at < now();
  with issues as (
    select 'open_batches' k, 'Lotti aperti da più di un giorno: ' || string_agg(batch_lot, ', ') t, count(*) c
      from fabula.production_batches where output_kg is null and batch_date < p_date and source <> 'simulation' having count(*) > 0
    union all
    select 'negative_stock', 'Giacenza negativa: ' || string_agg(sku || ' ' || round(qty_on_hand,1), ', '), count(*)
      from (select sku, sum(qty_on_hand) qty_on_hand from fabula.v_stock_on_hand group by sku having sum(qty_on_hand) < -0.01) x having count(*) > 0
    union all
    select 'unlabelled_lots', 'Lotti chiusi senza etichetta stampata: ' || string_agg(b.batch_lot, ', '), count(*)
      from fabula.production_batches b where b.output_kg is not null and b.batch_date between p_date - 7 and p_date and b.source <> 'simulation'
       and not exists (select 1 from fabula.labels l where l.batch_id = b.id) having count(*) > 0
    union all
    select 'milk_no_ddt_photo', 'Arrivi latte senza foto DDT (7 gg): ' || count(*), count(*)
      from fabula.milk_intake m where m.intake_date between p_date - 7 and p_date and m.source <> 'simulation'
       and not exists (select 1 from fabula.documents d where d.kind = 'ddt_in' and d.document_date = m.intake_date) having count(*) > 0
    union all
    select 'unknown_lot_sales', 'Vendite su lotti sconosciuti (7 gg): ' || string_agg(distinct sm.lot_number, ', '), count(*)
      from fabula.stock_moves sm where sm.move_type = 'sale' and sm.moved_at::date between p_date - 7 and p_date and sm.source <> 'simulation'
       and sm.lot_number is not null and not exists (select 1 from fabula.production_batches b where b.batch_lot = sm.lot_number) having count(*) > 0
    union all
    select 'stock_count_overdue', 'Conta magazzino non fatta da ' || (p_date - max(counted_at::date)) || ' giorni', 1
      from fabula.stock_counts where status = 'posted' having max(counted_at::date) < p_date - 9
    union all
    select 'stock_count_never', 'Nessuna conta magazzino registrata', 1 where not exists (select 1 from fabula.stock_counts where status = 'posted')
    union all
    select 'approvals_stale', 'Approvazioni in attesa da oltre 3 giorni: ' || count(*), count(*)
      from fabula.approvals where status = 'pending' and requested_at < now() - interval '3 days' having count(*) > 0
    union all
    select 'po_not_sent', 'Ordini approvati ma non ancora inviati al fornitore: ' || string_agg(po_number, ', '), count(*)
      from fabula.purchase_orders where status = 'approved' and updated_at < now() - interval '1 day' having count(*) > 0
    union all
    select 'placeholder_parties', 'Fornitori/clienti ancora con nome segnaposto (da rinominare nella console): ' || string_agg(legal_name, ', '), count(*)
      from fabula.parties where notes = 'placeholder' and active having count(*) > 0
    union all
    select 'tablet_silent', 'Nessuna scansione dal tablet oggi (giorno lavorativo)', 1
      where extract(isodow from p_date) between 1 and 6 and not exists (select 1 from fabula.scan_events where scanned_at::date = p_date)
        and not exists (select 1 from fabula.simulation_runs where p_date between from_date and to_date)
  )
  select coalesce(jsonb_agg(jsonb_build_object('key', k, 'text', t, 'count', c)), '[]') into dq from issues;
  return jsonb_build_object('date', p_date, 'bots', coalesce(bots, '[]'),
    'bots_missing', (select coalesce(jsonb_agg(b->>'agent'), '[]') from jsonb_array_elements(coalesce(bots,'[]')) b where not (b->>'ran')::boolean),
    'bots_errors', (select coalesce(sum((b->>'errors')::int), 0) from jsonb_array_elements(coalesce(bots,'[]')) b),
    'data_quality', dq, 'issues', jsonb_array_length(dq),
    'is_simulation', exists (select 1 from fabula.simulation_runs where p_date - 1 between from_date and to_date));
end $$;

-- 7. console views for Tier 2 editors ----------------------------------------------------------
create or replace view fabula.v_parties_editor as
  select id, type::text as type, legal_name, email, phone, payment_terms_days, is_milk_supplier, is_dop_certified, notes, active,
         (notes = 'placeholder') as is_placeholder,
         (select count(*) from fabula.products pr where pr.preferred_supplier_id = p.id) as products_supplied,
         (select count(*) from fabula.standing_orders s where s.customer_id = p.id and s.active) as standing_orders
  from fabula.parties p where active order by type, legal_name;
grant select on fabula.v_parties_editor to authenticated, service_role;
create or replace view fabula.v_farm_supply_next as
  select d::date as supply_date, fabula.farm_kg_available(d::date) as kg_available,
         (select source from fabula.farm_supply f where f.supply_date = d::date) as source,
         (select milk_kg from fabula.milk_plans m where m.plan_date = d::date and m.status in ('proposed','approved') limit 1) as planned_kg
  from generate_series((now() at time zone 'Europe/Rome')::date, (now() at time zone 'Europe/Rome')::date + 6, interval '1 day') d;
grant select on fabula.v_farm_supply_next to authenticated, service_role;
create or replace view fabula.v_wholesale_tomorrow as
  select o.order_number, o.order_date, p.legal_name as customer, p.phone, o.status::text as status, o.total_eur,
         (select string_agg(trim_scale(l.qty) || ' kg ' || pr.name, ', ') from fabula.sales_order_lines l join fabula.products pr on pr.id = l.product_id where l.sales_order_id = o.id) as lines_txt
  from fabula.sales_orders o join fabula.parties p on p.id = o.customer_id
  where o.channel = 'wholesale' and o.order_date >= (now() at time zone 'Europe/Rome')::date order by o.order_date, p.legal_name;
grant select on fabula.v_wholesale_tomorrow to authenticated, service_role;
