-- Fabula v0.83b — trade portal: plan editing, exceptions, portal entry points, applications, staff actions (part 2 of 3)
set search_path = fabula, public, extensions;

alter table fabula.trade_schedule_days add column if not exists active boolean not null default true;

-- ---------- confirmation log + message for the customer ----------
create or replace function fabula.trade_log(p_customer uuid, p_actor text, p_action text, p_details jsonb, p_message text) returns uuid
language plpgsql set search_path = fabula, public as $$
declare v uuid;
begin
  insert into fabula.trade_change_log (customer_id, actor, action, details, message_it) values (p_customer, p_actor, p_action, coalesce(p_details, '{}'), p_message) returning id into v;
  return v;
end $$;

create or replace function fabula.trade_wd_it(p int) returns text language sql immutable as $$
  select (array['lunedì','martedì','mercoledì','giovedì','venerdì','sabato','domenica'])[p] $$;

-- ---------- plan editing (shared by portal and console) ----------
-- payload: { start_date, address, instructions, window, po_number, days: {"1": {"window": "07:00-09:00", "lines": {"<variant_id>": qty, ...}}, ...} }
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
    if not (d::int in (select v::int from jsonb_array_elements_text(s->'delivery_days') as x(v))) then
      raise exception 'Il % non è un giorno di consegna', fabula.trade_wd_it(d::int) using errcode = '22023';
    end if;
    kgd := 0;
    for v, q in select k, (p_payload->'days'->d->'lines'->>k)::numeric from jsonb_object_keys(coalesce(p_payload->'days'->d->'lines', '{}'::jsonb)) k loop
      if q is null or q <= 0 then continue; end if;
      if not exists (select 1 from fabula.trade_products where variant_id = v and active and trade_price_eur is not null) then raise exception 'Prodotto non in listino: %', v using errcode = '22023'; end if;
      if q < (select min_qty from fabula.trade_products where variant_id = v) then raise exception 'Quantità sotto il minimo per %', (select title from fabula.trade_products where variant_id = v) using errcode = '22023'; end if;
      insert into fabula.trade_schedule_lines (customer_id, weekday, variant_id, qty) values (p_customer, d::int, v, q)
      on conflict (customer_id, weekday, variant_id) do update set qty = excluded.qty;
      kgd := kgd + q * (select kg_per_unit from fabula.trade_products where variant_id = v);
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

-- add an exception. payload: { kind: skip|override|window, date_from, date_to?, variant_id?, qty?, window?, note? }
create or replace function fabula.trade_add_exception(p_customer uuid, p_payload jsonb, p_actor text default 'customer', p_force boolean default false)
returns jsonb language plpgsql set search_path = fabula, public as $$
declare k text := p_payload->>'kind'; d1 date := (p_payload->>'date_from')::date; d2 date := coalesce(nullif(p_payload->>'date_to', '')::date, (p_payload->>'date_from')::date); v uuid; msg text; s jsonb := fabula.trade_settings(); tp fabula.trade_products%rowtype;
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
    if not ((p_payload->>'window') in (select v from jsonb_array_elements_text(s->'windows') as x(v))) then raise exception 'Fascia oraria non disponibile' using errcode = '22023'; end if;
    update fabula.trade_exceptions set cancelled_at = now() where customer_id = p_customer and kind = 'window' and cancelled_at is null and date_from <= d2 and date_to >= d1;
  end if;
  insert into fabula.trade_exceptions (customer_id, kind, date_from, date_to, variant_id, qty, window_code, note, created_by)
  values (p_customer, k, d1, d2, case when k = 'override' then tp.variant_id end, case when k = 'override' then (p_payload->>'qty')::numeric end,
          case when k = 'window' then p_payload->>'window' end, nullif(p_payload->>'note', ''), p_actor) returning id into v;
  msg := case k
    when 'skip' then case when d1 = d2 then format('Saltata la consegna del %s.', to_char(d1, 'DD/MM/YYYY')) else format('Chiusura dal %s al %s: nessuna consegna in quei giorni.', to_char(d1, 'DD/MM/YYYY'), to_char(d2, 'DD/MM/YYYY')) end
    when 'override' then format('%s: %s → %s %s %s. Dopo si torna al piano normale.', case when d1 = d2 then 'Il ' || to_char(d1, 'DD/MM/YYYY') else 'Dal ' || to_char(d1, 'DD/MM/YYYY') || ' al ' || to_char(d2, 'DD/MM/YYYY') end,
                                tp.title || coalesce(' ' || tp.variant_title, ''), trim_scale((p_payload->>'qty')::numeric), tp.unit_label, case when (p_payload->>'qty')::numeric = 0 then '(tolto)' else '' end)
    else format('%s: consegna nella fascia %s. Dopo si torna alla fascia abituale.', case when d1 = d2 then 'Il ' || to_char(d1, 'DD/MM/YYYY') else 'Dal ' || to_char(d1, 'DD/MM/YYYY') || ' al ' || to_char(d2, 'DD/MM/YYYY') end, p_payload->>'window') end;
  perform fabula.trade_log(p_customer, p_actor, 'exception_' || k, p_payload || jsonb_build_object('id', v), msg);
  return jsonb_build_object('ok', true, 'id', v, 'message_it', msg);
end $$;

create or replace function fabula.trade_cancel_exception(p_customer uuid, p_id uuid, p_actor text default 'customer', p_force boolean default false)
returns jsonb language plpgsql set search_path = fabula, public as $$
declare e fabula.trade_exceptions%rowtype;
begin
  select * into e from fabula.trade_exceptions where id = p_id and customer_id = p_customer and cancelled_at is null;
  if e.id is null then raise exception 'Modifica non trovata' using errcode = '22023'; end if;
  if not p_force and not fabula.trade_can_change(e.date_from) and e.date_from <= fabula.trade_now_rome()::date + 1 then
    raise exception 'La consegna del %s è già confermata', to_char(e.date_from, 'DD/MM') using errcode = '22023';
  end if;
  update fabula.trade_exceptions set cancelled_at = now() where id = p_id;
  perform fabula.trade_log(p_customer, p_actor, 'exception_cancelled', jsonb_build_object('id', p_id, 'kind', e.kind), format('Annullata la modifica del %s: vale di nuovo il piano normale.', to_char(e.date_from, 'DD/MM/YYYY')));
  return jsonb_build_object('ok', true);
end $$;

-- pause (optionally until a date — resumes by itself), resume, cancel
create or replace function fabula.trade_set_status(p_customer uuid, p_status text, p_until date default null, p_actor text default 'customer')
returns jsonb language plpgsql set search_path = fabula, public as $$
declare msg text; s jsonb := fabula.trade_settings();
begin
  if p_status not in ('active','paused','cancelled') then raise exception 'Stato non valido' using errcode = '22023'; end if;
  if not exists (select 1 from fabula.trade_schedules where customer_id = p_customer) then raise exception 'Nessun piano consegne' using errcode = '22023'; end if;
  if p_status = 'paused' then
    -- a pause is a skip from tomorrow (or the first changeable date) to p_until (or open-ended via status)
    if p_until is not null then
      perform fabula.trade_add_exception(p_customer, jsonb_build_object('kind', 'skip', 'date_from', greatest(fabula.trade_now_rome()::date + case when fabula.trade_can_change(fabula.trade_now_rome()::date + 1) then 1 else 2 end, fabula.trade_now_rome()::date), 'date_to', p_until, 'note', 'pausa'), p_actor, true);
      update fabula.trade_schedules set paused_from = null, paused_until = p_until, updated_at = now(), updated_by = p_actor where customer_id = p_customer;
      msg := format('Piano in pausa fino al %s: riprende da solo il giorno dopo.', to_char(p_until, 'DD/MM/YYYY'));
    else
      update fabula.trade_schedules set status = 'paused', paused_from = fabula.trade_now_rome()::date, paused_until = null, updated_at = now(), updated_by = p_actor where customer_id = p_customer;
      msg := 'Piano in pausa: nessuna consegna finché non lo riattivi. ' || case when not fabula.trade_can_change(fabula.trade_now_rome()::date + 1) then 'La consegna di domani è già confermata e sarà consegnata.' else '' end;
    end if;
  elsif p_status = 'active' then
    update fabula.trade_schedules set status = 'active', paused_from = null, paused_until = null, end_date = null, updated_at = now(), updated_by = p_actor where customer_id = p_customer;
    update fabula.trade_exceptions set cancelled_at = now() where customer_id = p_customer and kind = 'skip' and note = 'pausa' and cancelled_at is null and date_to >= fabula.trade_now_rome()::date;
    msg := 'Piano consegne riattivato.';
  else
    update fabula.trade_schedules set status = 'cancelled', end_date = fabula.trade_now_rome()::date, updated_at = now(), updated_by = p_actor where customer_id = p_customer;
    msg := 'Piano consegne annullato. ' || case when not fabula.trade_can_change(fabula.trade_now_rome()::date + 1) then 'La consegna di domani è già confermata e sarà consegnata.' else '' end;
  end if;
  perform fabula.trade_log(p_customer, p_actor, 'status_' || p_status, jsonb_build_object('until', p_until), msg);
  return jsonb_build_object('ok', true, 'message_it', msg);
end $$;

-- ---------- the customer's portal state (one call) ----------
create or replace function fabula.trade_portal_state_for(p_customer uuid) returns jsonb language plpgsql stable set search_path = fabula, public as $$
declare p fabula.parties%rowtype; s jsonb := fabula.trade_settings();
begin
  select * into p from fabula.parties where id = p_customer;
  return jsonb_build_object(
    'settings', s,
    'customer', jsonb_build_object('id', p.id, 'name', p.legal_name, 'email', p.email, 'phone', p.phone, 'address', coalesce(p.delivery_address, concat_ws(', ', p.address, p.postcode, p.city)),
                                   'instructions', p.delivery_instructions, 'payment_terms_days', p.payment_terms_days, 'shopify_company_id', p.shopify_company_id),
    'products', (select coalesce(jsonb_agg(jsonb_build_object('variant_id', variant_id, 'title', title, 'variant_title', variant_title, 'unit', unit_label, 'kg_per_unit', kg_per_unit,
                   'base_price', base_price_eur, 'trade_price', trade_price_eur, 'min_qty', min_qty, 'step_qty', step_qty,
                   'tiers', (select coalesce(jsonb_agg(jsonb_build_object('min_qty', t.min_qty, 'price', t.price_eur, 'pct', t.discount_pct, 'scope', case when t.variant_id is null then 'tutti' else 'prodotto' end) order by t.min_qty), '[]')
                             from fabula.trade_price_tiers t where t.active and (t.variant_id = tp.variant_id or t.variant_id is null)),
                   'price_1', fabula.trade_price(p_customer, variant_id, min_qty, true)) order by sort, title), '[]')
                 from fabula.trade_products tp where active and trade_price_eur is not null),
    'schedule', (select to_jsonb(ts) - 'customer_id' from fabula.trade_schedules ts where ts.customer_id = p_customer),
    'days', (select coalesce(jsonb_object_agg(d.weekday::text, jsonb_build_object('window', d.window_code,
               'lines', (select coalesce(jsonb_object_agg(l.variant_id, l.qty), '{}') from fabula.trade_schedule_lines l where l.customer_id = p_customer and l.weekday = d.weekday and l.qty > 0))), '{}')
             from fabula.trade_schedule_days d where d.customer_id = p_customer and d.active),
    'exceptions', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'kind', e.kind, 'date_from', e.date_from, 'date_to', e.date_to, 'variant_id', e.variant_id,
                     'product', (select title || coalesce(' ' || variant_title, '') from fabula.trade_products where variant_id = e.variant_id), 'qty', e.qty, 'window', e.window_code, 'note', e.note, 'created_by', e.created_by,
                     'can_cancel', fabula.trade_can_change(e.date_from)) order by e.date_from), '[]')
                   from fabula.trade_exceptions e where e.customer_id = p_customer and e.cancelled_at is null and e.date_to >= fabula.trade_now_rome()::date),
    'closures', (select coalesce(jsonb_agg(jsonb_build_object('date_from', date_from, 'date_to', date_to, 'note', note) order by date_from), '[]') from fabula.trade_closures where date_to >= fabula.trade_now_rome()::date),
    'upcoming', fabula.trade_upcoming(null, null, p_customer),
    'recent_orders', (select coalesce(jsonb_agg(jsonb_build_object('date', o.order_date, 'number', o.order_number, 'status', o.status, 'total', o.total_eur, 'shopify', q.shopify_order_name) order by o.order_date desc), '[]')
                      from (select * from fabula.sales_orders where customer_id = p_customer and channel = 'wholesale' and status <> 'cancelled' order by order_date desc limit 20) o
                      left join fabula.trade_order_queue q on q.sales_order_id = o.id),
    'log', (select coalesce(jsonb_agg(jsonb_build_object('at', at, 'actor', actor, 'action', action, 'message', message_it) order by at desc), '[]') from (select * from fabula.trade_change_log where customer_id = p_customer order by at desc limit 30) x));
end $$;

-- ---------- portal entry points (token). Executable by service_role only: the edge function calls them ----------
create or replace function fabula.trade_portal_state(p_token text) returns jsonb language sql stable security definer set search_path = fabula, public as $$
  select case when fabula.trade_party_by_token(p_token) is null then null else fabula.trade_portal_state_for(fabula.trade_party_by_token(p_token)) end
$$;
create or replace function fabula.trade_portal_action(p_token text, p_action text, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare c uuid := fabula.trade_party_by_token(p_token); r jsonb;
begin
  if c is null then return null; end if;
  if p_action = 'save_details' then
    update fabula.parties set delivery_address = nullif(p_payload->>'address', ''), delivery_instructions = nullif(p_payload->>'instructions', ''), phone = coalesce(nullif(p_payload->>'phone', ''), phone), updated_at = now() where id = c;
    perform fabula.trade_log(c, 'customer', 'details_updated', p_payload, 'Aggiornati indirizzo e istruzioni di consegna.');
    return jsonb_build_object('ok', true, 'state', fabula.trade_portal_state_for(c));
  end if;
  r := case p_action
    when 'save_schedule' then fabula.trade_save_schedule(c, p_payload, 'customer')
    when 'add_exception' then fabula.trade_add_exception(c, p_payload, 'customer', false)
    when 'cancel_exception' then fabula.trade_cancel_exception(c, (p_payload->>'id')::uuid, 'customer', false)
    when 'set_status' then fabula.trade_set_status(c, p_payload->>'status', nullif(p_payload->>'until', '')::date, 'customer')
    else null end;
  if r is null then raise exception 'Azione non valida' using errcode = '22023'; end if;
  return r || jsonb_build_object('state', fabula.trade_portal_state_for(c));
end $$;

-- ---------- applications ----------
create or replace function fabula.trade_apply(p jsonb) returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare v uuid; v_email text := lower(trim(p->>'email'));
begin
  if not (fabula.trade_settings()->>'enabled')::boolean then raise exception 'Sezione non attiva' using errcode = '22023'; end if;
  if coalesce(trim(p->>'business_name'), '') = '' or coalesce(trim(p->>'contact_name'), '') = '' or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Compila nome attività, referente ed email' using errcode = '22023';
  end if;
  if exists (select 1 from fabula.trade_applications where lower(email) = v_email and status = 'pending') then
    return jsonb_build_object('ok', true, 'duplicate', true, 'message_it', 'Abbiamo già ricevuto la tua richiesta: ti rispondiamo entro un giorno lavorativo.');
  end if;
  insert into fabula.trade_applications (business_name, business_type, piva, codice_fiscale, sdi_code, pec_email, contact_name, email, phone, address, city, province, postcode, expected_kg_week, preferred_days, notes, shopify_customer_id, source)
  values (trim(p->>'business_name'), coalesce(nullif(lower(trim(p->>'business_type')), ''), 'altro'), nullif(upper(regexp_replace(coalesce(p->>'piva', ''), '\s', '', 'g')), ''), nullif(trim(p->>'codice_fiscale'), ''), nullif(trim(p->>'sdi_code'), ''), nullif(trim(p->>'pec_email'), ''),
          trim(p->>'contact_name'), v_email, nullif(trim(p->>'phone'), ''), nullif(trim(p->>'address'), ''), nullif(trim(p->>'city'), ''), nullif(upper(trim(p->>'province')), ''), nullif(trim(p->>'postcode'), ''),
          nullif(replace(regexp_replace(coalesce(p->>'expected_kg_week', ''), '[^0-9.,]', '', 'g'), ',', '.'), '')::numeric, nullif(trim(p->>'preferred_days'), ''), nullif(trim(p->>'notes'), ''), nullif(trim(p->>'shopify_customer_id'), ''), coalesce(nullif(p->>'source', ''), 'web'))
  returning id into v;
  insert into fabula.notices (key, severity, title_it, items, expires_at)
  values ('trade_applications', 'info', 'Nuova richiesta professionisti', jsonb_build_array(jsonb_build_object('id', v, 'business', trim(p->>'business_name'), 'type', p->>'business_type', 'email', v_email)), now() + interval '14 days');
  return jsonb_build_object('ok', true, 'id', v, 'message_it', 'Richiesta ricevuta. Ti rispondiamo entro un giorno lavorativo e ti scriviamo quando l''accesso è attivo.');
end $$;

-- staff: approve → party linked, token issued; the edge function then creates the Shopify company and calls trade_approve_done
create or replace function fabula.trade_approve(p_app uuid, p_note text default null) returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare a fabula.trade_applications%rowtype; v_party uuid; v_tok text; v_terms int := (fabula.trade_settings()->>'payment_terms_days')::int; v_seg text;
begin
  perform fabula.require_perm('vendite', 3);
  select * into a from fabula.trade_applications where id = p_app;
  if a.id is null then raise exception 'Richiesta non trovata' using errcode = '22023'; end if;
  if a.status = 'approved' and a.party_id is not null then
    return jsonb_build_object('ok', true, 'already', true, 'party_id', a.party_id, 'token', (select portal_token from fabula.parties where id = a.party_id));
  end if;
  v_seg := case a.business_type when 'pizzeria' then 'pizzeria' when 'ristorante' then 'ristorante' when 'hotel' then 'hotel' when 'bnb' then 'bnb' when 'agriturismo' then 'agriturismo' when 'lido' then 'lido' else 'altro' end;
  -- match an existing customer (Shopify id, then e-mail), else create
  select id into v_party from fabula.parties where a.shopify_customer_id is not null and shopify_customer_id = a.shopify_customer_id;
  if v_party is null then select id into v_party from fabula.parties where type = 'customer' and lower(email) = lower(a.email) and active order by (source = 'shopify') desc limit 1; end if;
  v_tok := encode(extensions.gen_random_bytes(16), 'hex');
  if v_party is null then
    insert into fabula.parties (type, legal_name, trade_name, piva, codice_fiscale, sdi_code, pec_email, email, phone, address, city, province, postcode, country, payment_terms_days, source, is_wholesale, trade_status, portal_token, segment, business_type, shopify_customer_id, active)
    values ('customer', a.business_name, a.business_name, a.piva, a.codice_fiscale, a.sdi_code, a.pec_email, a.email, a.phone, a.address, a.city, a.province, a.postcode, 'IT', v_terms, 'trade', true, 'approved', v_tok, v_seg, a.business_type, a.shopify_customer_id, true)
    returning id into v_party;
  else
    update fabula.parties set legal_name = coalesce(nullif(a.business_name, ''), legal_name), trade_name = a.business_name, piva = coalesce(a.piva, piva), codice_fiscale = coalesce(a.codice_fiscale, codice_fiscale), sdi_code = coalesce(a.sdi_code, sdi_code), pec_email = coalesce(a.pec_email, pec_email),
      phone = coalesce(a.phone, phone), address = coalesce(a.address, address), city = coalesce(a.city, city), province = coalesce(a.province, province), postcode = coalesce(a.postcode, postcode),
      payment_terms_days = coalesce(nullif(payment_terms_days, 0), v_terms), is_wholesale = true, trade_status = 'approved', portal_token = coalesce(portal_token, v_tok), segment = coalesce(segment, v_seg), business_type = a.business_type,
      tags = (select array_agg(distinct t) from unnest(tags || array['ingrosso']) t), notes = case when notes = 'placeholder' then null else notes end, active = true, updated_at = now()
    where id = v_party;
    select portal_token into v_tok from fabula.parties where id = v_party;
  end if;
  update fabula.trade_applications set status = 'approved', party_id = v_party, decided_by = coalesce((select full_name from fabula.staff where auth_user_id = auth.uid()), 'staff'), decided_at = now(), decision_note = p_note where id = p_app;
  update fabula.notices set resolved_at = now() where key = 'trade_applications' and resolved_at is null and items @> jsonb_build_array(jsonb_build_object('id', p_app));
  perform fabula.trade_log(v_party, 'staff', 'approved', jsonb_build_object('application', p_app), 'Accesso professionisti attivato. Accedi al sito con la tua email per vedere il listino e impostare le consegne.');
  return jsonb_build_object('ok', true, 'party_id', v_party, 'token', v_tok, 'application', to_jsonb(a) || jsonb_build_object('party_id', v_party), 'payment_terms_days', v_terms);
end $$;

-- the edge function reports the Shopify objects it created
create or replace function fabula.trade_approve_done(p_app uuid, p_party uuid, p_company text, p_location text, p_contact text, p_customer text) returns boolean
language plpgsql security definer set search_path = fabula, public as $$
begin
  update fabula.parties set shopify_company_id = coalesce(p_company, shopify_company_id), shopify_location_id = coalesce(p_location, shopify_location_id), shopify_contact_id = coalesce(p_contact, shopify_contact_id),
         shopify_customer_id = coalesce(shopify_customer_id, p_customer), updated_at = now() where id = p_party;
  update fabula.trade_applications set shopify_company_id = p_company, shopify_location_id = p_location, shopify_contact_id = p_contact, shopify_customer_id = coalesce(shopify_customer_id, p_customer) where id = p_app;
  return found;
end $$;

create or replace function fabula.trade_reject(p_app uuid, p_note text default null) returns boolean language plpgsql security definer set search_path = fabula, public as $$
begin
  perform fabula.require_perm('vendite', 3);
  update fabula.trade_applications set status = 'rejected', decided_by = coalesce((select full_name from fabula.staff where auth_user_id = auth.uid()), 'staff'), decided_at = now(), decision_note = p_note where id = p_app and status = 'pending';
  update fabula.notices set resolved_at = now() where key = 'trade_applications' and resolved_at is null and items @> jsonb_build_array(jsonb_build_object('id', p_app));
  return found;
end $$;

-- staff: customer list for the console (approved trade customers + their plan)
create or replace function fabula.trade_customers() returns jsonb language sql stable security definer set search_path = fabula, public as $$
  select case when fabula.perm_level('vendite') < 1 then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
    'id', p.id, 'name', p.legal_name, 'type', p.business_type, 'email', p.email, 'phone', p.phone, 'city', p.city, 'piva', p.piva, 'trade_status', p.trade_status, 'terms', p.payment_terms_days,
    'shopify_company_id', p.shopify_company_id, 'shopify_location_id', p.shopify_location_id, 'shopify_customer_id', p.shopify_customer_id,
    'link', case when fabula.perm_level('vendite') >= 3 and p.portal_token is not null then fabula.setting_text('trade.store_url', '') || '/pages/professionisti?t=' || p.portal_token end,
    'plan', (select to_jsonb(ts) - 'customer_id' from fabula.trade_schedules ts where ts.customer_id = p.id),
    'week_kg', fabula.trade_week_qty(p.id, null),
    'days', (select coalesce(jsonb_object_agg(d.weekday::text, jsonb_build_object('window', d.window_code, 'lines', (select coalesce(jsonb_object_agg(l.variant_id, l.qty), '{}') from fabula.trade_schedule_lines l where l.customer_id = p.id and l.weekday = d.weekday and l.qty > 0))), '{}') from fabula.trade_schedule_days d where d.customer_id = p.id and d.active),
    'exceptions', (select count(*) from fabula.trade_exceptions e where e.customer_id = p.id and e.cancelled_at is null and e.date_to >= fabula.trade_now_rome()::date)
  ) order by p.legal_name), '[]') end
  from fabula.parties p where p.type in ('customer','both') and p.active and (p.trade_status in ('approved','suspended') or p.is_wholesale) and not fabula.is_placeholder_party(p.id)
$$;

-- staff wrappers (console) — same engine, actor = staff name, cutoff can be forced
create or replace function fabula.trade_staff_action(p_customer uuid, p_action text, p_payload jsonb, p_force boolean default false) returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare who text := coalesce((select full_name from fabula.staff where auth_user_id = auth.uid()), 'staff'); r jsonb; v_tok text;
begin
  perform fabula.require_perm('vendite', 2);
  if p_action = 'set_trade_status' then
    perform fabula.require_perm('vendite', 3);
    if (p_payload->>'trade_status') not in ('approved','suspended') then raise exception 'Stato non valido' using errcode = '22023'; end if;
    update fabula.parties set trade_status = p_payload->>'trade_status', updated_at = now() where id = p_customer;
    perform fabula.trade_log(p_customer, who, 'trade_status', p_payload, case when p_payload->>'trade_status' = 'suspended' then 'Accesso professionisti sospeso dal caseificio.' else 'Accesso professionisti riattivato.' end);
    return jsonb_build_object('ok', true, 'state', fabula.trade_portal_state_for(p_customer));
  elsif p_action = 'new_link' then
    perform fabula.require_perm('vendite', 3);
    v_tok := encode(extensions.gen_random_bytes(16), 'hex');
    update fabula.parties set portal_token = v_tok, updated_at = now() where id = p_customer;
    return jsonb_build_object('ok', true, 'token', v_tok, 'state', fabula.trade_portal_state_for(p_customer));
  elsif p_action = 'save_details' then
    update fabula.parties set delivery_address = nullif(p_payload->>'address', ''), delivery_instructions = nullif(p_payload->>'instructions', ''), updated_at = now() where id = p_customer;
    return jsonb_build_object('ok', true, 'state', fabula.trade_portal_state_for(p_customer));
  end if;
  r := case p_action
    when 'save_schedule' then fabula.trade_save_schedule(p_customer, p_payload, who)
    when 'add_exception' then fabula.trade_add_exception(p_customer, p_payload, who, p_force)
    when 'cancel_exception' then fabula.trade_cancel_exception(p_customer, (p_payload->>'id')::uuid, who, p_force)
    when 'set_status' then fabula.trade_set_status(p_customer, p_payload->>'status', nullif(p_payload->>'until', '')::date, who)
    when 'state' then jsonb_build_object('ok', true)
    else null end;
  if r is null then raise exception 'Azione non valida' using errcode = '22023'; end if;
  return r || jsonb_build_object('state', fabula.trade_portal_state_for(p_customer));
end $$;
