-- =============================================================================
-- v0.16: weekly stock count.
--   Monday task T-COUNT shows in the tablet "Da fare". The count sheet comes
--   prefilled with the system quantity; the operator changes only what differs
--   and taps Salva. Differences post as 'adjustment' stock_moves; the sheet,
--   lines and shrink value are kept for the weekly brief.
--   start_stock_count(staff) → sheet json · post_stock_count(id, lines, staff, note)
-- Written without destructive keywords (connector rule).
-- =============================================================================
set search_path = fabula, public;

create table if not exists fabula.stock_counts (
  id            uuid primary key default gen_random_uuid(),
  counted_at    timestamptz not null default now(),
  status        text not null default 'open' check (status in ('open','posted','abandoned')),
  counted_by_id uuid references fabula.staff(id),
  notes         text,
  lines_total   int,
  lines_changed int,
  shrink_eur    numeric(12,2)                 -- value of negative differences at cost
);
create table if not exists fabula.stock_count_lines (
  id            uuid primary key default gen_random_uuid(),
  count_id      uuid not null references fabula.stock_counts(id),
  product_id    uuid not null references fabula.products(id),
  lot_number    text,
  system_qty    numeric(10,3) not null,
  counted_qty   numeric(10,3),
  delta         numeric(10,3),
  unit_cost_eur numeric(12,4),
  stock_move_id uuid references fabula.stock_moves(id)
);
grant all on fabula.stock_counts, fabula.stock_count_lines to authenticated, service_role;
alter table fabula.stock_counts enable row level security; alter table fabula.stock_count_lines enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='fabula' and tablename='stock_counts' and policyname='stock_counts_authenticated_all') then
    create policy stock_counts_authenticated_all on fabula.stock_counts for all to authenticated using (true) with check (true); end if;
  if not exists (select 1 from pg_policies where schemaname='fabula' and tablename='stock_count_lines' and policyname='stock_count_lines_authenticated_all') then
    create policy stock_count_lines_authenticated_all on fabula.stock_count_lines for all to authenticated using (true) with check (true); end if;
end $$;

insert into fabula.task_schedules (code, title_it, title_en, frequency, due_time, assigned_role)
select 'T-COUNT', 'Conta magazzino settimanale', 'Weekly stock count', 'weekly', time '10:00', 'operaio'
where not exists (select 1 from fabula.task_schedules where code = 'T-COUNT');

-- unit cost: latest supplier price, else PO line price, else milk-cost equivalent for finished goods
create or replace function fabula.unit_cost_estimate(p_product uuid) returns numeric language sql stable as $$
  select coalesce(
    (select price_eur from fabula.supplier_prices where product_id = p_product order by valid_from desc limit 1),
    (select unit_price_eur from fabula.purchase_order_lines where product_id = p_product order by id desc limit 1),
    (select case when p.kind = 'finished_good' then round(100.0 / nullif(coalesce((select avg(yield_pct) from fabula.production_batches where product_id = p.id and output_kg is not null and batch_date > current_date - 30), 30), 0) * 1.30, 2) end
       from fabula.products p where p.id = p_product),
    0)
$$;
grant execute on function fabula.unit_cost_estimate(uuid) to authenticated, service_role;

-- The sheet: one line per consumable/packaging product (all lots together) + one per finished-good lot
create or replace function fabula.start_stock_count(p_staff_id uuid default null)
returns jsonb language plpgsql as $$
declare v_id uuid;
begin
  -- reuse today's open sheet if someone started it already
  select id into v_id from fabula.stock_counts where status = 'open' and counted_at::date = (now() at time zone 'Europe/Rome')::date limit 1;
  if v_id is null then
    insert into fabula.stock_counts (counted_by_id) values (p_staff_id) returning id into v_id;
    insert into fabula.stock_count_lines (count_id, product_id, lot_number, system_qty, unit_cost_eur)
    select v_id, p.id, null, coalesce(sum(s.qty_on_hand), 0), fabula.unit_cost_estimate(p.id)
    from fabula.products p left join fabula.v_stock_on_hand s on s.product_id = p.id
    where p.kind in ('consumable','packaging') and p.active group by p.id
    union all
    select v_id, s.product_id, s.lot_number, s.qty_on_hand, fabula.unit_cost_estimate(s.product_id)
    from fabula.v_stock_on_hand s where s.kind = 'finished_good' and s.qty_on_hand > 0;
  end if;
  return jsonb_build_object('count_id', v_id,
    'lines', (select jsonb_agg(jsonb_build_object('line_id', l.id, 'sku', p.sku, 'name', p.name, 'unit', p.unit, 'kind', p.kind, 'lot', l.lot_number, 'system_qty', l.system_qty, 'counted_qty', l.counted_qty)
                               order by case p.kind when 'finished_good' then 0 else 1 end, p.name, l.lot_number)
              from fabula.stock_count_lines l join fabula.products p on p.id = l.product_id where l.count_id = v_id));
end $$;
grant execute on function fabula.start_stock_count(uuid) to authenticated, service_role;

-- lines: [{"line_id": "...", "counted_qty": 97.5}, …] — only the lines the operator changed need to be sent
create or replace function fabula.post_stock_count(p_count_id uuid, p_lines jsonb, p_staff_id uuid default null, p_note text default null)
returns jsonb language plpgsql as $$
declare l jsonb; r record; v_delta numeric; v_move uuid; n_changed int := 0; v_shrink numeric := 0; v_total int; changed jsonb := '[]';
begin
  if not exists (select 1 from fabula.stock_counts where id = p_count_id and status = 'open') then raise exception 'Conta non aperta'; end if;
  for l in select * from jsonb_array_elements(coalesce(p_lines, '[]')) loop
    select scl.*, p.sku, p.name, p.unit into r from fabula.stock_count_lines scl join fabula.products p on p.id = scl.product_id where scl.id = (l->>'line_id')::uuid and scl.count_id = p_count_id;
    continue when r is null or nullif(l->>'counted_qty','') is null;
    v_delta := round((l->>'counted_qty')::numeric - r.system_qty, 3);
    update fabula.stock_count_lines set counted_qty = (l->>'counted_qty')::numeric, delta = v_delta where id = r.id;
    if v_delta <> 0 then
      insert into fabula.stock_moves (product_id, lot_number, qty, move_type, unit_cost_eur, source, reason)
      values (r.product_id, r.lot_number, v_delta, 'adjustment', r.unit_cost_eur, 'stock_count', format('Conta magazzino: contati %s, sistema %s', l->>'counted_qty', r.system_qty))
      returning id into v_move;
      update fabula.stock_count_lines set stock_move_id = v_move where id = r.id;
      n_changed := n_changed + 1;
      if v_delta < 0 then v_shrink := v_shrink + (-v_delta) * coalesce(r.unit_cost_eur, 0); end if;
      changed := changed || jsonb_build_object('sku', r.sku, 'name', r.name, 'lot', r.lot_number, 'unit', r.unit, 'system', r.system_qty, 'counted', (l->>'counted_qty')::numeric, 'delta', v_delta);
    end if;
  end loop;
  -- untouched lines = confirmed as system qty
  update fabula.stock_count_lines set counted_qty = system_qty, delta = 0 where count_id = p_count_id and counted_qty is null;
  select count(*) into v_total from fabula.stock_count_lines where count_id = p_count_id;
  update fabula.stock_counts set status = 'posted', counted_at = now(), counted_by_id = coalesce(p_staff_id, counted_by_id), notes = p_note,
         lines_total = v_total, lines_changed = n_changed, shrink_eur = round(v_shrink, 2) where id = p_count_id;
  return jsonb_build_object('count_id', p_count_id, 'lines_total', v_total, 'lines_changed', n_changed, 'shrink_eur', round(v_shrink, 2), 'changed', changed);
end $$;
grant execute on function fabula.post_stock_count(uuid, jsonb, uuid, text) to authenticated, service_role;
