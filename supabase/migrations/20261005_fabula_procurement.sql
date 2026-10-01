-- =============================================================================
-- v0.5: procurement — propose purchase orders from stock signals.
--   select fabula.propose_purchase_orders();   -- idempotent per product/day
-- Creates purchase_orders (status pending_approval) + approvals rows.
-- Approving the approvals row (console) flips the PO to approved via trigger.
-- Nothing is sent to a supplier here; that is a later, human-triggered step.
-- =============================================================================
set search_path = fabula, public;

-- Keep PO status in sync with the approval decision, whoever makes it
create or replace function fabula.sync_po_from_approval() returns trigger language plpgsql as $$
begin
  if new.related_table = 'purchase_orders' and new.related_id is not null and new.status is distinct from old.status then
    update fabula.purchase_orders set status = case new.status when 'approved' then 'approved'::fabula.po_status when 'rejected' then 'cancelled'::fabula.po_status else status end
    where id = new.related_id;
  end if;
  return new;
end $$;
drop trigger if exists approvals_sync_po on fabula.approvals;
create trigger approvals_sync_po after update on fabula.approvals for each row execute function fabula.sync_po_from_approval();

create or replace function fabula.propose_purchase_orders(p_date date default (now() at time zone 'Europe/Rome')::date)
returns jsonb language plpgsql as $$
declare
  sig record; v_po uuid; v_price numeric; v_total numeric; v_n int := 0; v_seq int;
  created jsonb := '[]'::jsonb; skipped jsonb := '[]'::jsonb; v_po_number text;
begin
  for sig in
    with s as (
      select product_id, sku, name, sum(qty_on_hand) qty_on_hand, max(reorder_point) reorder_point
      from fabula.v_stock_on_hand where kind in ('consumable','packaging') group by product_id, sku, name),
    u as (
      select product_id, round(coalesce(-sum(qty),0) / 14.0, 3) daily_use
      from fabula.stock_moves where qty < 0 and moved_at::date between p_date-13 and p_date group by product_id)
    select s.*, p.reorder_qty, p.unit, p.iva_rate, p.preferred_supplier_id, sp.legal_name as supplier, sp.email as supplier_email,
           coalesce(u.daily_use,0) daily_use,
           case when coalesce(u.daily_use,0) > 0 then round(s.qty_on_hand / u.daily_use, 1) end days_cover
    from s join fabula.products p on p.id = s.product_id
    left join fabula.parties sp on sp.id = p.preferred_supplier_id
    left join u on u.product_id = s.product_id
    where s.reorder_point is not null
      and (s.qty_on_hand <= s.reorder_point or (coalesce(u.daily_use,0) > 0 and s.qty_on_hand / u.daily_use < 10))
  loop
    -- already proposed and still open?
    if exists (select 1 from fabula.purchase_order_lines l join fabula.purchase_orders po on po.id = l.purchase_order_id
               where l.product_id = sig.product_id and po.status in ('draft','pending_approval','approved','sent')) then
      skipped := skipped || jsonb_build_object('sku', sig.sku, 'reason', 'open_po_exists'); continue;
    end if;
    if sig.preferred_supplier_id is null then
      skipped := skipped || jsonb_build_object('sku', sig.sku, 'reason', 'no_preferred_supplier', 'on_hand', sig.qty_on_hand, 'days_cover', sig.days_cover); continue;
    end if;
    select price_eur into v_price from fabula.supplier_prices
      where supplier_id = sig.preferred_supplier_id and product_id = sig.product_id and valid_from <= p_date
      order by valid_from desc limit 1;
    v_price := coalesce(v_price, 0);
    v_total := round(coalesce(sig.reorder_qty, sig.reorder_point * 2) * v_price, 2);

    select count(*) + 1 into v_seq from fabula.purchase_orders where order_date = p_date;
    v_po_number := 'PO-' || to_char(p_date, 'YYYYMMDD') || '-' || lpad(v_seq::text, 2, '0');

    insert into fabula.purchase_orders (po_number, supplier_id, status, order_date, expected_date, subtotal_eur, iva_eur, total_eur, drafted_by, rationale, source)
    values (v_po_number, sig.preferred_supplier_id, 'pending_approval', p_date, p_date + 5, v_total, round(v_total * coalesce(sig.iva_rate,22) / 100, 2),
            round(v_total * (1 + coalesce(sig.iva_rate,22) / 100), 2), 'agent',
            format('%s: giacenza %s %s, consumo %s %s/giorno, copertura %s giorni (soglia %s). Prezzo %s da listino fornitore.',
                   sig.name, sig.qty_on_hand, sig.unit, sig.daily_use, sig.unit, coalesce(sig.days_cover::text,'n/d'), sig.reorder_point,
                   case when v_price = 0 then 'NON DISPONIBILE' else v_price::text end),
            'agent:procurement')
    returning id into v_po;
    insert into fabula.purchase_order_lines (purchase_order_id, product_id, qty_ordered, unit_price_eur, iva_rate)
    values (v_po, sig.product_id, coalesce(sig.reorder_qty, sig.reorder_point * 2), v_price, coalesce(sig.iva_rate,22));

    insert into fabula.approvals (kind, requested_by, summary, payload, related_table, related_id, amount_eur, expires_at)
    values ('purchase_order', 'agent:procurement',
            format('Ordine %s: %s × %s %s a %s — copertura %s giorni%s', v_po_number, coalesce(sig.reorder_qty, sig.reorder_point*2), sig.unit, sig.name, sig.supplier,
                   coalesce(sig.days_cover::text,'n/d'), case when v_price = 0 then ' · PREZZO MANCANTE' else '' end),
            jsonb_build_object('po_number', v_po_number, 'supplier', sig.supplier, 'supplier_email', sig.supplier_email, 'sku', sig.sku,
                               'qty', coalesce(sig.reorder_qty, sig.reorder_point*2), 'unit', sig.unit, 'unit_price_eur', v_price, 'total_eur', v_total,
                               'on_hand', sig.qty_on_hand, 'daily_use', sig.daily_use, 'days_cover', sig.days_cover),
            'purchase_orders', v_po, v_total, p_date + 7);
    v_n := v_n + 1;
    created := created || jsonb_build_object('po_number', v_po_number, 'sku', sig.sku, 'name', sig.name, 'qty', coalesce(sig.reorder_qty, sig.reorder_point*2), 'unit', sig.unit,
                                             'supplier', sig.supplier, 'total_eur', v_total, 'days_cover', sig.days_cover, 'price_missing', v_price = 0);
  end loop;
  return jsonb_build_object('date', p_date, 'created', created, 'skipped', skipped, 'count', v_n);
end $$;
grant execute on function fabula.propose_purchase_orders(date) to authenticated, service_role;

-- Simulation support: suppliers + list prices, removed by purge
create or replace function fabula.seed_simulation_suppliers() returns void language plpgsql as $$
declare v_pkg uuid; v_ing uuid;
begin
  if not exists (select 1 from fabula.parties where legal_name = 'Imballaggi Sud (SIM)') then
    insert into fabula.parties (type, legal_name, city, province, email, payment_terms_days, notes) values ('supplier','Imballaggi Sud (SIM)','Battipaglia','SA','ordini@imballaggisud.example',30,'simulation') returning id into v_pkg;
    insert into fabula.parties (type, legal_name, city, province, email, payment_terms_days, notes) values ('supplier','Caseoingredienti Campania (SIM)','Salerno','SA','vendite@caseoingredienti.example',30,'simulation') returning id into v_ing;
    update fabula.products set preferred_supplier_id = v_pkg where sku = 'PKG-BAG-500';
    update fabula.products set preferred_supplier_id = v_ing where sku in ('CON-SALT','CON-RENNET');
    insert into fabula.supplier_prices (supplier_id, product_id, price_eur, valid_from, source)
    select v_pkg, id, 0.085, date '2026-01-01', 'simulation' from fabula.products where sku = 'PKG-BAG-500';
    insert into fabula.supplier_prices (supplier_id, product_id, price_eur, valid_from, source)
    select v_ing, id, 0.42, date '2026-01-01', 'simulation' from fabula.products where sku = 'CON-SALT';
    insert into fabula.supplier_prices (supplier_id, product_id, price_eur, valid_from, source)
    select v_ing, id, 38.00, date '2026-01-01', 'simulation' from fabula.products where sku = 'CON-RENNET';
  end if;
end $$;

create or replace function fabula.purge_simulation() returns table (table_name text, deleted bigint)
language plpgsql as $$
declare n bigint;
begin
  delete from fabula.task_instances where scan_event_id is null and completed_at is null and due_at::date in (select generate_series(from_date, to_date, '1 day')::date from fabula.simulation_runs);
  delete from fabula.approvals where requested_by = 'agent:procurement'; get diagnostics n = row_count; table_name:='approvals'; deleted:=n; return next;
  delete from fabula.purchase_orders where source = 'agent:procurement'; get diagnostics n = row_count; table_name:='purchase_orders'; deleted:=n; return next;
  delete from fabula.supplier_prices where source = 'simulation';
  update fabula.products set preferred_supplier_id = null where preferred_supplier_id in (select id from fabula.parties where notes = 'simulation');
  delete from fabula.shipment_lines sl using fabula.shipments s, fabula.sales_orders o where sl.shipment_id = s.id and s.sales_order_id = o.id and o.source='simulation';
  delete from fabula.shipments s using fabula.sales_orders o where s.sales_order_id = o.id and o.source='simulation'; get diagnostics n = row_count; table_name:='shipments'; deleted:=n; return next;
  delete from fabula.non_conformities where description like 'CF-0% alla chiusura' and haccp_log_id is null; get diagnostics n = row_count; table_name:='non_conformities'; deleted:=n; return next;
  delete from fabula.waste_log where notes='simulation'; get diagnostics n = row_count; table_name:='waste_log'; deleted:=n; return next;
  delete from fabula.pos_daily_closings where notes='simulation'; get diagnostics n = row_count; table_name:='pos_daily_closings'; deleted:=n; return next;
  delete from fabula.meter_readings where source='simulation'; get diagnostics n = row_count; table_name:='meter_readings'; deleted:=n; return next;
  delete from fabula.stock_moves where source='simulation'; get diagnostics n = row_count; table_name:='stock_moves'; deleted:=n; return next;
  delete from fabula.sales_orders where source='simulation'; get diagnostics n = row_count; table_name:='sales_orders'; deleted:=n; return next;
  delete from fabula.haccp_log where source='simulation'; get diagnostics n = row_count; table_name:='haccp_log'; deleted:=n; return next;
  delete from fabula.production_batches where source='simulation'; get diagnostics n = row_count; table_name:='production_batches'; deleted:=n; return next;
  delete from fabula.milk_intake where source='simulation'; get diagnostics n = row_count; table_name:='milk_intake'; deleted:=n; return next;
  delete from fabula.parties where notes='simulation'; get diagnostics n = row_count; table_name:='parties'; deleted:=n; return next;
  delete from fabula.agent_runs where agent in ('daily_brief','procurement') and started_at < (select max(to_date) + 1 from fabula.simulation_runs);
  delete from fabula.simulation_runs; get diagnostics n = row_count; table_name:='simulation_runs'; deleted:=n; return next;
end $$;
