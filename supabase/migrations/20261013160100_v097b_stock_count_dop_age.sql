-- v0.97b · Audit 12/10/2026, floor flows (High items), second part.
--   D-05         Stock count: the adjustment is the count minus what the system holds WHEN it is saved (not when the sheet was
--                opened), under a lock; a sheet opened more than 3 hours ago is replaced by a fresh one; a line left empty is
--                «not counted» (no adjustment), no longer «counted, same as the system»; «✓ Ci sono» (confirm) means «what the
--                system holds is right» and adjusts nothing even if stock moved meanwhile; a negative count is refused.
--   A-14/D-08    60 hours: milk older than 60 hours (from the farm's departure, or the arrival) cannot start a DOP batch — the
--                database refuses it with the reason, the tablet says it before the form; milk_age_hours() is the one clock.
--   A-20         A milk arrival copied from the paper sheet keeps the sheet's date and time (up to 7 days back, not in the future).

-- ============================================================================================================================
-- 1. D-05 stock count
-- ============================================================================================================================
alter table fabula.stock_count_lines add column if not exists system_qty_post numeric(10,3);
comment on column fabula.stock_count_lines.system_qty_post is 'v0.97 (audit D-05): what the system held for this line when the count was saved; delta = counted − this';
comment on column fabula.stock_count_lines.counted_qty is 'null = not counted (v0.97: no longer filled with the system quantity)';
do $mig$ begin
  if not exists (select 1 from pg_constraint where conname = 'stock_count_lines_counted_nonneg') then
    alter table fabula.stock_count_lines add constraint stock_count_lines_counted_nonneg check (counted_qty is null or counted_qty >= 0) not valid;
    alter table fabula.stock_count_lines validate constraint stock_count_lines_counted_nonneg;
  end if;
end $mig$;
comment on constraint stock_count_lines_counted_nonneg on fabula.stock_count_lines is 'Quantità contata negativa: scrivi 0 se non c''è più niente';

create or replace function fabula.start_stock_count(p_staff_id uuid default null)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare v_id uuid; v_old record;
begin
  perform fabula.require_perm('magazzino', 2);
  -- v0.97 (audit D-05): today's open sheet is reused only if it is fresh; one opened more than 3 hours ago is set aside (its
  -- quantities are old: sales and production since then would be counted twice) and a new one is made
  select id, counted_at into v_old from fabula.stock_counts
   where status = 'open' and (counted_at at time zone 'Europe/Rome')::date = (now() at time zone 'Europe/Rome')::date
   order by counted_at desc limit 1;
  if v_old.id is not null and v_old.counted_at > now() - interval '3 hours' then
    v_id := v_old.id;
  else
    update fabula.stock_counts set status = 'abandoned',
           notes = concat_ws(' · ', nullif(notes, ''), format('Foglio aperto alle %s e non salvato: sostituito da uno nuovo', to_char(counted_at at time zone 'Europe/Rome', 'HH24:MI')))
     where status = 'open' and counted_at <= now() - interval '3 hours';
    insert into fabula.stock_counts (counted_by_id) values (p_staff_id) returning id into v_id;
    insert into fabula.stock_count_lines (count_id, product_id, lot_number, system_qty, unit_cost_eur)
    select v_id, p.id, null, coalesce(sum(s.qty_on_hand), 0), fabula.unit_cost_estimate(p.id)
    from fabula.products p left join fabula.v_stock_on_hand s on s.product_id = p.id
    where p.kind in ('consumable','packaging') and p.active and p.track_stock group by p.id
    union all
    select v_id, s.product_id, s.lot_number, s.qty_on_hand, fabula.unit_cost_estimate(s.product_id)
    from fabula.v_stock_on_hand s where s.kind = 'finished_good' and s.qty_on_hand > 0;
  end if;
  return jsonb_build_object('count_id', v_id,
    'lines', (select jsonb_agg(jsonb_build_object('line_id', l.id, 'sku', p.sku, 'name', p.name, 'unit', p.unit, 'kind', p.kind, 'lot', l.lot_number, 'system_qty', l.system_qty, 'counted_qty', l.counted_qty)
                               order by case p.kind when 'finished_good' then 0 else 1 end, p.name, l.lot_number)
              from fabula.stock_count_lines l join fabula.products p on p.id = l.product_id where l.count_id = v_id));
end $$;

create or replace function fabula.post_stock_count(p_count_id uuid, p_lines jsonb, p_staff_id uuid default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare l jsonb; r record; v_cnt numeric; v_now numeric; v_delta numeric; v_move uuid; n_changed int := 0; n_counted int := 0; v_shrink numeric := 0;
        v_total int; changed jsonb := '[]';
begin
  perform fabula.require_perm('magazzino', 2);
  perform 1 from fabula.stock_counts where id = p_count_id for update;            -- two tablets saving the same sheet: one waits, then finds it posted
  if not exists (select 1 from fabula.stock_counts where id = p_count_id and status = 'open') then
    raise exception 'Questo foglio di conta non è più aperto (salvato o sostituito): riapri la conta' using errcode = '22023';
  end if;
  for l in select * from jsonb_array_elements(coalesce(p_lines, '[]')) loop
    select scl.*, p.sku, p.name, p.unit into r from fabula.stock_count_lines scl join fabula.products p on p.id = scl.product_id
     where scl.id = (l->>'line_id')::uuid and scl.count_id = p_count_id;
    continue when r is null or (nullif(l->>'counted_qty', '') is null and coalesce((l->>'confirm')::boolean, false) is false);
    -- v0.97 (audit D-05): the difference is against what the system holds NOW, under the same lock as the sales and packing guard
    -- (product + lot), not against the quantity printed on the sheet when it was opened (moves since then would be counted twice)
    perform pg_advisory_xact_lock(hashtext('lot:' || r.product_id::text || ':' || coalesce(r.lot_number, '')));
    select coalesce(sum(s.qty_on_hand), 0) into v_now from fabula.v_stock_on_hand s
     where s.product_id = r.product_id and (r.lot_number is null or s.lot_number = r.lot_number);
    -- «✓ Ci sono» = the system's quantity is right: no adjustment, whatever moved since the sheet was opened
    v_cnt := case when coalesce((l->>'confirm')::boolean, false) then v_now else (l->>'counted_qty')::numeric end;
    if v_cnt < 0 then raise exception 'Quantità contata negativa per %: scrivi 0 se non c''è più niente', r.name using errcode = '23514'; end if;
    v_delta := round(v_cnt - v_now, 3);
    update fabula.stock_count_lines set counted_qty = v_cnt, delta = v_delta, system_qty_post = v_now where id = r.id;
    n_counted := n_counted + 1;
    if v_delta <> 0 then
      insert into fabula.stock_moves (product_id, lot_number, qty, move_type, unit_cost_eur, source, reason)
      values (r.product_id, r.lot_number, v_delta, 'adjustment', r.unit_cost_eur, 'stock_count',
              format('Conta magazzino: contati %s, a sistema %s al salvataggio', fabula._it_num(v_cnt), fabula._it_num(v_now)))
      returning id into v_move;
      update fabula.stock_count_lines set stock_move_id = v_move where id = r.id;
      n_changed := n_changed + 1;
      if v_delta < 0 then v_shrink := v_shrink + (-v_delta) * coalesce(r.unit_cost_eur, 0); end if;
      changed := changed || jsonb_build_object('sku', r.sku, 'name', r.name, 'lot', r.lot_number, 'unit', r.unit, 'system', v_now, 'sheet', r.system_qty,
                                               'counted', v_cnt, 'delta', v_delta);
    end if;
  end loop;
  -- lines nobody counted stay «not counted» (counted_qty null): no adjustment, and the sheet says so
  select count(*) into v_total from fabula.stock_count_lines where count_id = p_count_id;
  update fabula.stock_counts set status = 'posted', counted_at = now(), counted_by_id = coalesce(p_staff_id, counted_by_id),
         notes = concat_ws(' · ', nullif(p_note, ''), case when v_total > n_counted then format('%s righe non contate', v_total - n_counted) end),
         lines_total = v_total, lines_changed = n_changed, shrink_eur = round(v_shrink, 2)
   where id = p_count_id;
  return jsonb_build_object('count_id', p_count_id, 'lines_total', v_total, 'lines_counted', n_counted, 'lines_not_counted', v_total - n_counted,
                            'lines_changed', n_changed, 'shrink_eur', round(v_shrink, 2), 'changed', changed);
end $$;

-- ============================================================================================================================
-- 2. A-14 / D-08: one clock for the milk's age, and no DOP batch from milk past 60 hours
-- ============================================================================================================================
create or replace function fabula.milk_age_hours(p_intake_id uuid, p_at timestamptz default now())
returns numeric language sql stable set search_path = fabula, public as $$
  -- from the farm's departure when the load came from the Masseria's page (closest to milking), else from the arrival
  -- (same anchor as production_plan's 60 h deadline)
  select round((extract(epoch from (coalesce(p_at, now()) - least(coalesce(s.shipped_at, 'infinity'::timestamptz),
                 (mi.intake_date + coalesce(mi.intake_time, time '06:00')) at time zone 'Europe/Rome'))) / 3600)::numeric, 1)
    from fabula.milk_intake mi left join fabula.milk_shipments s on s.id = mi.shipment_id
   where mi.id = p_intake_id
$$;
revoke all on function fabula.milk_age_hours(uuid, timestamptz) from public, anon;
grant execute on function fabula.milk_age_hours(uuid, timestamptz) to authenticated, service_role;

create or replace function fabula.trg_batch_milk_dop_age()
returns trigger language plpgsql security definer set search_path = fabula, public as $$
declare v_dop boolean; v_prod text; v_at timestamptz; v_age numeric; v_lot text;
begin
  select p.is_dop, p.name, b.started_at into v_dop, v_prod, v_at
    from fabula.production_batches b join fabula.products p on p.id = b.product_id where b.id = new.batch_id;
  if not coalesce(v_dop, false) then return new; end if;
  v_age := fabula.milk_age_hours(new.milk_intake_id, coalesce(least(v_at, now()), now()));
  if v_age > 60 then
    select milk_lot into v_lot from fabula.milk_intake where id = new.milk_intake_id;
    raise exception 'Il latte % ha già % ore: oltre le 60 ore non si può fare %. Chiama il responsabile: va usato per un prodotto non DOP o scartato.',
      coalesce(v_lot, '?'), fabula._it_int(v_age), v_prod using errcode = '23514';
  end if;
  return new;
end $$;
revoke all on function fabula.trg_batch_milk_dop_age() from public, anon, authenticated;
drop trigger if exists batch_milk_dop_age on fabula.batch_milk_inputs;
create trigger batch_milk_dop_age before insert on fabula.batch_milk_inputs for each row execute function fabula.trg_batch_milk_dop_age();

-- ============================================================================================================================
-- 3. A-20: a milk arrival copied from the paper sheet (source paper) is dated within the last 7 days, not in the future
-- ============================================================================================================================
create or replace function fabula.trg_milk_paper_date()
returns trigger language plpgsql set search_path = fabula, public as $$
declare v_today date := (now() at time zone 'Europe/Rome')::date;
begin
  if new.source = 'paper' and (new.intake_date < v_today - 7
                               or new.intake_date + coalesce(new.intake_time, time '00:00') > (now() at time zone 'Europe/Rome') + interval '5 minutes') then
    raise exception 'Data e ora del foglio non valide: al massimo 7 giorni fa, non nel futuro' using errcode = '22023';
  end if;
  return new;
end $$;
drop trigger if exists milk_intake_paper_date on fabula.milk_intake;
create trigger milk_intake_paper_date before insert on fabula.milk_intake for each row execute function fabula.trg_milk_paper_date();
