-- Fabula v0.83d — plpgsql variable "v" shadowed the column alias v in two set-returning subqueries (found by the first scenario test)
set search_path = fabula, public, extensions;

create or replace function fabula.trade_save_schedule(p_customer uuid, p_payload jsonb, p_actor text default 'customer')
returns jsonb language plpgsql set search_path = fabula, public as $$
declare s jsonb := fabula.trade_settings(); d text; v text; q numeric; kgd numeric; v_start date; existed boolean; wd_txt text := ''; n_days int := 0; min_kg numeric := (s->>'min_order_kg')::numeric;
begin
  if not (s->>'enabled')::boolean then raise exception 'Sezione professionisti non attiva' using errcode = '22023'; end if;
  v_start := coalesce(nullif(p_payload->>'start_date', '')::date, fabula.trade_now_rome()::date + 1);
  if v_start < fabula.trade_now_rome()::date then raise exception 'La data di inizio non può essere nel passato' using errcode = '22023'; end if;
  existed := exists (select 1 from fabula.trade_schedules where customer_id = p_customer);
  insert into fabula.trade_schedules (customer_id, status, start_date, delivery_address, delivery_instructions, window_code, po_number, updated_at, updated_by)
  values (p_customer, 'active', v_start, nullif(p_payload->>'address', ''), nullif(p_payload->>'instructions', ''), nullif(p_payload->>'window', ''), nullif(p_payload->>'po_number', ''), now(), p_actor)
  on conflict (customer_id) do update set status = case when fabula.trade_schedules.status = 'cancelled' then 'active' else fabula.trade_schedules.status end,
    start_date = excluded.start_date, end_date = null, delivery_address = excluded.delivery_address, delivery_instructions = excluded.delivery_instructions,
    window_code = excluded.window_code, po_number = excluded.po_number, updated_at = now(), updated_by = p_actor;
  -- no destructive statements (connector rule): old lines go to 0 and old days inactive, then the new plan is upserted
  update fabula.trade_schedule_lines set qty = 0 where customer_id = p_customer;
  update fabula.trade_schedule_days set active = false where customer_id = p_customer;
  for d in select * from jsonb_object_keys(coalesce(p_payload->'days', '{}'::jsonb)) loop
    if d !~ '^[1-7]$' then continue; end if;
    if not (d::int in (select dd.val::int from jsonb_array_elements_text(s->'delivery_days') as dd(val))) then
      raise exception 'Il % non è un giorno di consegna', fabula.trade_wd_it(d::int) using errcode = '22023';
    end if;
    kgd := 0;
    for v, q in select k, (p_payload->'days'->d->'lines'->>k)::numeric from jsonb_object_keys(coalesce(p_payload->'days'->d->'lines', '{}'::jsonb)) k loop
      if q is null or q <= 0 then continue; end if;
      if not exists (select 1 from fabula.trade_products tp where tp.variant_id = v and tp.active and tp.trade_price_eur is not null) then raise exception 'Prodotto non in listino: %', v using errcode = '22023'; end if;
      if q < (select tp.min_qty from fabula.trade_products tp where tp.variant_id = v) then raise exception 'Quantità sotto il minimo per %', (select tp.title from fabula.trade_products tp where tp.variant_id = v) using errcode = '22023'; end if;
      insert into fabula.trade_schedule_lines (customer_id, weekday, variant_id, qty) values (p_customer, d::int, v, q)
      on conflict (customer_id, weekday, variant_id) do update set qty = excluded.qty;
      kgd := kgd + q * (select tp.kg_per_unit from fabula.trade_products tp where tp.variant_id = v);
    end loop;
    if kgd > 0 then
      if kgd < min_kg then raise exception 'Il % è sotto l''ordine minimo di % kg', fabula.trade_wd_it(d::int), trim_scale(min_kg) using errcode = '22023'; end if;
      insert into fabula.trade_schedule_days (customer_id, weekday, window_code, active) values (p_customer, d::int, nullif(p_payload->'days'->d->>'window', ''), true)
      on conflict (customer_id, weekday) do update set window_code = excluded.window_code, active = true;
      n_days := n_days + 1; wd_txt := wd_txt || fabula.trade_wd_it(d::int) || ' ' || trim_scale(round(kgd, 2)) || ' kg, ';
    end if;
  end loop;
  if n_days = 0 then raise exception 'Indica almeno un giorno con una quantità' using errcode = '22023'; end if;
  perform fabula.trade_log(p_customer, p_actor, case when existed then 'plan_updated' else 'plan_created' end, p_payload,
    format('%s piano consegne dal %s: %s. %s', case when existed then 'Aggiornato il' else 'Creato il' end, to_char(v_start, 'DD/MM/YYYY'), rtrim(wd_txt, ', '), s->>'cutoff_rule_it'));
  return jsonb_build_object('ok', true, 'days', n_days, 'start_date', v_start);
end $$;

create or replace function fabula.trade_add_exception(p_customer uuid, p_payload jsonb, p_actor text default 'customer', p_force boolean default false)
returns jsonb language plpgsql set search_path = fabula, public as $$
declare k text := p_payload->>'kind'; d1 date := (p_payload->>'date_from')::date; d2 date := coalesce(nullif(p_payload->>'date_to', '')::date, (p_payload->>'date_from')::date); v_id uuid; msg text; s jsonb := fabula.trade_settings(); tp fabula.trade_products%rowtype;
begin
  if k not in ('skip','override','window') then raise exception 'Tipo di modifica non valido' using errcode = '22023'; end if;
  if d2 < d1 then raise exception 'Date non valide' using errcode = '22023'; end if;
  if not p_force and not fabula.trade_can_change(d1) then
    raise exception 'La consegna del %s è già confermata (modifiche entro le %s del giorno prima)', to_char(d1, 'DD/MM'), s->>'cutoff_time' using errcode = '22023';
  end if;
  if k = 'override' then
    select * into tp from fabula.trade_products where variant_id = p_payload->>'variant_id' and active and trade_price_eur is not null;
    if tp.variant_id is null then raise exception 'Prodotto non in listino' using errcode = '22023'; end if;
    if (p_payload->>'qty')::numeric > 0 and (p_payload->>'qty')::numeric < tp.min_qty then raise exception 'Quantità sotto il minimo (%)', trim_scale(tp.min_qty) using errcode = '22023'; end if;
    -- one override per product per range: the newest replaces the older one on overlapping dates
    update fabula.trade_exceptions set cancelled_at = now() where customer_id = p_customer and kind = 'override' and variant_id = tp.variant_id and cancelled_at is null and date_from <= d2 and date_to >= d1;
  elsif k = 'window' then
    if not ((p_payload->>'window') in (select ww.val from jsonb_array_elements_text(s->'windows') as ww(val))) then raise exception 'Fascia oraria non disponibile' using errcode = '22023'; end if;
    update fabula.trade_exceptions set cancelled_at = now() where customer_id = p_customer and kind = 'window' and cancelled_at is null and date_from <= d2 and date_to >= d1;
  end if;
  insert into fabula.trade_exceptions (customer_id, kind, date_from, date_to, variant_id, qty, window_code, note, created_by)
  values (p_customer, k, d1, d2, case when k = 'override' then tp.variant_id end, case when k = 'override' then (p_payload->>'qty')::numeric end,
          case when k = 'window' then p_payload->>'window' end, nullif(p_payload->>'note', ''), p_actor) returning id into v_id;
  msg := case k
    when 'skip' then case when d1 = d2 then format('Saltata la consegna del %s.', to_char(d1, 'DD/MM/YYYY')) else format('Chiusura dal %s al %s: nessuna consegna in quei giorni.', to_char(d1, 'DD/MM/YYYY'), to_char(d2, 'DD/MM/YYYY')) end
    when 'override' then format('%s: %s → %s %s %s. Dopo si torna al piano normale.', case when d1 = d2 then 'Il ' || to_char(d1, 'DD/MM/YYYY') else 'Dal ' || to_char(d1, 'DD/MM/YYYY') || ' al ' || to_char(d2, 'DD/MM/YYYY') end,
                                tp.title || coalesce(' ' || tp.variant_title, ''), trim_scale((p_payload->>'qty')::numeric), tp.unit_label, case when (p_payload->>'qty')::numeric = 0 then '(tolto)' else '' end)
    else format('%s: consegna nella fascia %s. Dopo si torna alla fascia abituale.', case when d1 = d2 then 'Il ' || to_char(d1, 'DD/MM/YYYY') else 'Dal ' || to_char(d1, 'DD/MM/YYYY') || ' al ' || to_char(d2, 'DD/MM/YYYY') end, p_payload->>'window') end;
  perform fabula.trade_log(p_customer, p_actor, 'exception_' || k, p_payload || jsonb_build_object('id', v_id), msg);
  return jsonb_build_object('ok', true, 'id', v_id, 'message_it', msg);
end $$;
