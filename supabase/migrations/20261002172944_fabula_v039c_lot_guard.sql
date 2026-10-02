-- v0.39 · 2026-10-02 · lot guard on finished-goods stock + repair of negative lots
-- (part of the v0.39 integrity pass; see 20261002172859 for the overview)

-- ---------------------------------------------------------------- 4. lot guard
create or replace function fabula.trg_stock_move_guard() returns trigger
language plpgsql security definer set search_path = fabula, public as $$
declare v_kind fabula.product_kind; v_sku text; v_bal numeric; v_need numeric; v_take numeric; v_orig text := new.lot_number; v_orig_qty numeric := new.qty;
        lot record; v_alloc jsonb := '[]'::jsonb; a jsonb; v_today date := (now() at time zone 'Europe/Rome')::date;
begin
  select kind, sku into v_kind, v_sku from fabula.products where id = new.product_id;
  -- raw milk: the lot expires at the processing deadline
  if v_sku = 'RAW-MILK' and new.move_type = 'milk_intake' and new.expiry_date is null then
    new.expiry_date := coalesce(new.moved_at, now())::date + fabula.setting_num('milk.raw_shelf_days', 2)::int;
  end if;
  if v_kind is distinct from 'finished_good' or new.qty >= 0 or new.lot_number is null or new.move_type not in ('sale', 'waste')
     or coalesce(current_setting('fabula.lot_guard', true), 'on') = 'off' then
    return new;
  end if;

  perform pg_advisory_xact_lock(hashtext('lot:' || new.product_id::text || ':' || new.lot_number));
  select coalesce(sum(qty), 0) into v_bal from fabula.stock_moves where product_id = new.product_id and lot_number = new.lot_number;
  v_need := -new.qty;
  if v_bal >= v_need then return new; end if;

  -- scanned on the floor: the label is the truth for a recall — keep the lot, flag the under-recorded output
  if new.source = 'tablet' then
    insert into fabula.notices (key, severity, title_it, items, expires_at)
    values ('lot_guard:' || to_char(v_today, 'YYYY-MM-DD'), 'warn', 'Lotti usciti oltre la produzione registrata: verificare il peso in uscita del lotto',
            jsonb_build_array(jsonb_build_object('lot', v_orig, 'move', new.move_type, 'kg', v_need, 'on_hand', v_bal, 'at', now(), 'kept', true)), now() + interval '3 days')
    on conflict (key) do update set items = fabula.notices.items || excluded.items, resolved_at = null, expires_at = excluded.expires_at;
    return new;
  end if;

  -- allocated by the system: take what the lot has, then FEFO over in-date lots not on hold, then book the rest without a lot
  v_take := greatest(v_bal, 0);
  if v_take > 0 then
    v_alloc := v_alloc || jsonb_build_object('lot', new.lot_number, 'exp', new.expiry_date, 'qty', v_take);
    v_need := v_need - v_take;
  end if;
  if new.move_type = 'sale' then
    for lot in select s.lot_number, s.expiry_date, s.qty_on_hand from fabula.v_stock_on_hand s
               where s.product_id = new.product_id and s.qty_on_hand > 0 and s.lot_number is not null and s.lot_number <> v_orig
                 and (s.expiry_date is null or s.expiry_date >= v_today)
                 and not exists (select 1 from fabula.production_batches b where b.batch_lot = s.lot_number and b.food_safety_hold)
               order by s.expiry_date nulls last, s.lot_number loop
      exit when v_need <= 0;
      v_alloc := v_alloc || jsonb_build_object('lot', lot.lot_number, 'exp', lot.expiry_date, 'qty', least(v_need, lot.qty_on_hand));
      v_need := v_need - least(v_need, lot.qty_on_hand);
    end loop;
  end if;
  if v_need > 0 then v_alloc := v_alloc || jsonb_build_object('lot', null, 'exp', null, 'qty', v_need); end if;

  perform set_config('fabula.lot_guard', 'off', true);
  for a in select value from jsonb_array_elements(v_alloc) with ordinality e(value, i) where i > 1 loop
    insert into fabula.stock_moves (moved_at, product_id, lot_number, expiry_date, qty, move_type, batch_id, sales_order_id, purchase_order_id, unit_cost_eur, reason, source)
    values (new.moved_at, new.product_id, a->>'lot', (a->>'exp')::date, -(a->>'qty')::numeric, new.move_type, new.batch_id, new.sales_order_id, new.purchase_order_id, new.unit_cost_eur,
            concat_ws(' · ', new.reason, case when a->>'lot' is null then format('giacenza insufficiente (richiesto lotto %s)', v_orig)
                                              else format('FEFO: lotto %s esaurito', v_orig) end), new.source);
  end loop;
  perform set_config('fabula.lot_guard', 'on', true);

  a := v_alloc->0;
  new.lot_number := a->>'lot'; new.expiry_date := (a->>'exp')::date; new.qty := -(a->>'qty')::numeric;
  if new.lot_number is distinct from v_orig then
    new.reason := concat_ws(' · ', new.reason, case when new.lot_number is null then format('giacenza insufficiente (richiesto lotto %s)', v_orig)
                                                    else format('FEFO: lotto %s esaurito', v_orig) end);
  end if;
  insert into fabula.notices (key, severity, title_it, items, expires_at)
  values ('lot_guard:' || to_char(v_today, 'YYYY-MM-DD'), 'warn', 'Lotti usciti oltre la produzione registrata: verificare il peso in uscita del lotto',
          jsonb_build_array(jsonb_build_object('lot', v_orig, 'move', new.move_type, 'kg', -v_orig_qty, 'on_hand', v_bal, 'alloc', v_alloc, 'at', now(), 'kept', false)), now() + interval '3 days')
  on conflict (key) do update set items = fabula.notices.items || excluded.items, resolved_at = null, expires_at = excluded.expires_at;
  return new;
end $$;
create or replace trigger stock_moves_lot_guard before insert on fabula.stock_moves
  for each row execute function fabula.trg_stock_move_guard();

-- repair: excess booked against a lot beyond what it produced moves to an unassigned row (lot balances back to ≥ 0)
do $$
declare r record; m record; v_def numeric;
begin
  perform set_config('fabula.lot_guard', 'off', true);
  for r in select sm.product_id, sm.lot_number, -sum(sm.qty) deficit
             from fabula.stock_moves sm join fabula.products p on p.id = sm.product_id
            where p.kind = 'finished_good' and sm.lot_number is not null
            group by 1, 2 having sum(sm.qty) < -0.0005 loop
    v_def := r.deficit;
    for m in select id, qty from fabula.stock_moves
              where product_id = r.product_id and lot_number = r.lot_number and qty < 0 and move_type in ('sale', 'waste')
              order by moved_at desc, created_at desc loop
      exit when v_def <= 0.0005;
      if -m.qty <= v_def then
        update fabula.stock_moves set lot_number = null, expiry_date = null,
               reason = concat_ws(' · ', reason, format('giacenza insufficiente sul lotto %s (correzione v0.39)', r.lot_number))
         where id = m.id;
        v_def := v_def + m.qty;
      else
        update fabula.stock_moves set qty = qty + v_def where id = m.id;
        insert into fabula.stock_moves (moved_at, product_id, lot_number, qty, move_type, batch_id, sales_order_id, purchase_order_id, unit_cost_eur, reason, source)
        select moved_at, product_id, null, -v_def, move_type, batch_id, sales_order_id, purchase_order_id, unit_cost_eur,
               concat_ws(' · ', reason, format('giacenza insufficiente sul lotto %s (correzione v0.39)', r.lot_number)), source
          from fabula.stock_moves where id = m.id;
        v_def := 0;
      end if;
    end loop;
  end loop;
  perform set_config('fabula.lot_guard', 'on', true);
end $$;
