-- v1.10b «Sicurezza e salvataggi» (20/10/2026) · saves, wholesale portal, farm (quality test 20/10, claude/quality-test-2026-10-20.md)
--   1. Item 3: the calibration check, the pest round and the lab sample go through save_ops with the save id like the CCP readings,
--      so a re-send after a lost reply returns the first answer instead of writing the record a second time (the tablet sends them so
--      from v1.10, perla-v77). The badge scans, which now go through save_ops too, take the database's time when sent at once and the
--      measured time of the scan when queued: a tablet clock that is off no longer moves them.
--   2. Item 13: the farm's 8 loads a day count only loads that were not cancelled (8 cancelled loads blocked the real one).
--   3. Item 5: approving a trade application for an e-mail already in the register no longer overwrites that customer's name, P.IVA,
--      SDI, PEC, phone and address with what the request says: blanks are filled, differences are listed for the office. The Shopify
--      customer id typed in the form is not trusted: the link to Shopify is made by the server function on the verified e-mail.
--   4. Item 6: the queue of wholesale orders for Shopify is claimed by one run at a time (trade_queue_claim, a claim lasts 10 minutes).
--   5. Item 7: a customer's new weekly plan may not change a delivery already confirmed (past its cut-off); delivery windows only
--      from the list offered.
--   6. Item 15: «Se ne occupa <name>» on Telegram escapes «&» too (fabula.tg_esc).

-- ============================================================================================================================
-- 1. save_ops: three more records with the save id
-- ============================================================================================================================
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.save_ops(jsonb,uuid,timestamp with time zone,timestamp with time zone)'::regprocedure);
  n := replace(d, $s$'badge_in','badge_out','correct_batch_milk']$s$,
                  $s$'badge_in','badge_out','correct_batch_milk',
                                  'record_calibration_check','record_pest_inspection','record_sample_taken']$s$);
  if n = d then raise exception 'v110b: save_ops rpc list not found'; end if;
  -- a badge scan carries the tablet's clock (p_at): sent at once it takes the database's time, queued it takes the time it was made as
  -- the database measures it (p_client_at / p_client_now), so a tablet whose clock is off never puts a badge-out before the shift it
  -- closes (the badge scans go through save_ops from v1.10; badge_out keeps a late time only for the shift that was running then)
  d := n;
  n := replace(d, $s$        elsif v_late and v_op ->> 'rpc' in ('close_open_task', 'log_batch_step') and not v_args ? 'p_at' then
          v_args := v_args || jsonb_build_object('p_at', v_cat);
        end if;
$s$, $s$        elsif v_late and v_op ->> 'rpc' in ('close_open_task', 'log_batch_step') and not v_args ? 'p_at' then
          v_args := v_args || jsonb_build_object('p_at', v_cat);
        end if;
        if v_op ->> 'rpc' in ('badge_in', 'badge_out') then
          v_args := case when v_cat is null then v_args - 'p_at' else v_args || jsonb_build_object('p_at', v_cat) end;
        end if;
$s$);
  if n = d then raise exception 'v110b: save_ops badge time anchor not found'; end if;
  execute n;
end $mig$;

-- ============================================================================================================================
-- 2. Farm: cancelled loads do not count towards the 8 a day
-- ============================================================================================================================
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.farm_milk_ship(text,numeric,numeric,text,text,boolean,text)'::regprocedure);
  n := replace(d, $s$  select count(*) into v_n from fabula.milk_shipments where ship_date = v_today;
  if v_n >= 8 then raise exception 'Troppe spedizioni oggi (%)', v_n using errcode = '22023'; end if;
$s$, $s$  select count(*) into v_n from fabula.milk_shipments where ship_date = v_today;
  -- v1.10 (quality test item 13): the cap counts the loads that stand (a cancelled one no longer blocks the real one); the lot number
  -- below still counts every load, so it never repeats
  if (select count(*) from fabula.milk_shipments where ship_date = v_today and status <> 'cancelled') >= 8 then
    raise exception 'Troppe spedizioni oggi (%)', (select count(*) from fabula.milk_shipments where ship_date = v_today and status <> 'cancelled') using errcode = '22023';
  end if;
$s$);
  if n = d then raise exception 'v110b: farm_milk_ship cap not found'; end if;
  execute n;
end $mig$;

-- ============================================================================================================================
-- 3. Trade applications: an existing customer keeps their data
-- ============================================================================================================================
create or replace function fabula.trade_approve(p_app uuid, p_note text default null) returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare a fabula.trade_applications%rowtype; v_party uuid; v_tok text; v_terms int := (fabula.trade_settings()->>'payment_terms_days')::int; v_seg text;
        p fabula.parties%rowtype; v_diff jsonb := '[]';
begin
  perform fabula.require_perm('vendite', 3);
  select * into a from fabula.trade_applications where id = p_app;
  if a.id is null then raise exception 'Richiesta non trovata' using errcode = '22023'; end if;
  if a.status = 'approved' and a.party_id is not null then
    return jsonb_build_object('ok', true, 'already', true, 'party_id', a.party_id, 'token', (select portal_token from fabula.parties where id = a.party_id));
  end if;
  v_seg := case a.business_type when 'pizzeria' then 'pizzeria' when 'ristorante' then 'ristorante' when 'hotel' then 'hotel' when 'bnb' then 'bnb' when 'agriturismo' then 'agriturismo' when 'lido' then 'lido' else 'altro' end;
  -- v1.10 (quality test item 5): matched on the e-mail only. The Shopify customer id comes from a hidden field of a public form and
  -- is not trusted: the server function links the Shopify customer found by the verified e-mail (trade_approve_done)
  select id into v_party from fabula.parties where type = 'customer' and lower(email) = lower(a.email) and active order by (source = 'shopify') desc limit 1;
  v_tok := encode(extensions.gen_random_bytes(16), 'hex');
  if v_party is null then
    insert into fabula.parties (type, legal_name, trade_name, piva, codice_fiscale, sdi_code, pec_email, email, phone, address, city, province, postcode, country, payment_terms_days, source, is_wholesale, trade_status, portal_token, segment, business_type, shopify_customer_id, active)
    values ('customer', a.business_name, a.business_name, a.piva, a.codice_fiscale, a.sdi_code, a.pec_email, a.email, a.phone, a.address, a.city, a.province, a.postcode, 'IT', v_terms, 'trade', true, 'approved', v_tok, v_seg, a.business_type, null, true)
    returning id into v_party;
  else
    select * into p from fabula.parties where id = v_party;
    -- what the request says differently from the register: listed for the office, never written over (an application with someone
    -- else's e-mail would otherwise move their invoices to another SDI/PEC)
    select coalesce(jsonb_agg(jsonb_build_object('field', f, 'label', l, 'current', cur, 'request', req) order by o), '[]') into v_diff
      from (values (1, 'legal_name', 'Ragione sociale', p.legal_name, a.business_name), (2, 'piva', 'P.IVA', p.piva, a.piva),
                   (3, 'codice_fiscale', 'Codice fiscale', p.codice_fiscale, a.codice_fiscale), (4, 'sdi_code', 'Codice SDI', p.sdi_code, a.sdi_code),
                   (5, 'pec_email', 'PEC', p.pec_email, a.pec_email), (6, 'phone', 'Telefono', p.phone, a.phone),
                   (7, 'address', 'Indirizzo', p.address, a.address), (8, 'city', 'Comune', p.city, a.city),
                   (9, 'province', 'Provincia', p.province, a.province), (10, 'postcode', 'CAP', p.postcode, a.postcode)) x(o, f, l, cur, req)
     where nullif(trim(cur), '') is not null and nullif(trim(req), '') is not null and lower(trim(cur)) <> lower(trim(req));
    update fabula.parties set legal_name = coalesce(nullif(legal_name, ''), nullif(a.business_name, '')), trade_name = coalesce(nullif(trade_name, ''), a.business_name),
      piva = coalesce(nullif(piva, ''), a.piva), codice_fiscale = coalesce(nullif(codice_fiscale, ''), a.codice_fiscale), sdi_code = coalesce(nullif(sdi_code, ''), a.sdi_code),
      pec_email = coalesce(nullif(pec_email, ''), a.pec_email), phone = coalesce(nullif(phone, ''), a.phone), address = coalesce(nullif(address, ''), a.address),
      city = coalesce(nullif(city, ''), a.city), province = coalesce(nullif(province, ''), a.province), postcode = coalesce(nullif(postcode, ''), a.postcode),
      payment_terms_days = coalesce(nullif(payment_terms_days, 0), v_terms), is_wholesale = true, trade_status = 'approved', portal_token = coalesce(portal_token, v_tok), segment = coalesce(segment, v_seg),
      business_type = coalesce(business_type, a.business_type),
      tags = (select array_agg(distinct t) from unnest(tags || array['ingrosso']) t), notes = case when notes = 'placeholder' then null else notes end, active = true, updated_at = now()
    where id = v_party;
    select portal_token into v_tok from fabula.parties where id = v_party;
  end if;
  update fabula.trade_applications set status = 'approved', party_id = v_party, decided_by = coalesce((select full_name from fabula.staff where auth_user_id = auth.uid()), 'staff'), decided_at = now(),
    decision_note = concat_ws(' · ', p_note, case when jsonb_array_length(v_diff) > 0 then 'cliente già in anagrafica, dati non cambiati: diversi ' ||
                    (select string_agg(x->>'label', ', ') from jsonb_array_elements(v_diff) x) end)
   where id = p_app;
  perform fabula.trade_notice_refresh();
  perform fabula.trade_log(v_party, 'staff', 'approved', jsonb_build_object('application', p_app, 'differences', v_diff), 'Accesso professionisti attivato. Accedi al sito con la tua email per vedere il listino e impostare le consegne.');
  return jsonb_build_object('ok', true, 'party_id', v_party, 'token', v_tok, 'application', to_jsonb(a) || jsonb_build_object('party_id', v_party), 'payment_terms_days', v_terms,
                            'differences', v_diff);
end $$;

-- ============================================================================================================================
-- 4. The Shopify order queue: one run per row
-- ============================================================================================================================
alter table fabula.trade_order_queue add column if not exists claimed_at timestamptz;
comment on column fabula.trade_order_queue.claimed_at is 'v1.10: when a run of trade-portal «run-queue» took the row (for 10 minutes no other run takes it)';

create or replace function fabula.trade_queue_claim() returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare v_ids uuid[];
begin
  with c as (select q.id from fabula.trade_order_queue q
              where q.status = 'pending' and q.attempts < 8 and (q.claimed_at is null or q.claimed_at < now() - interval '10 minutes')
              order by q.created_at for update skip locked),
       u as (update fabula.trade_order_queue q set claimed_at = now() from c where q.id = c.id returning q.id)
  select coalesce(array_agg(id), '{}') into v_ids from u;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'sales_order_id', q.sales_order_id, 'delivery_date', q.delivery_date, 'payload', q.payload, 'attempts', q.attempts,
            'customer', jsonb_build_object('id', p.id, 'name', p.legal_name, 'email', p.email, 'phone', p.phone, 'shopify_company_id', p.shopify_company_id, 'shopify_location_id', p.shopify_location_id,
                                           'shopify_contact_id', p.shopify_contact_id, 'shopify_customer_id', p.shopify_customer_id, 'terms', p.payment_terms_days)) order by q.created_at), '[]')
            from fabula.trade_order_queue q join fabula.parties p on p.id = q.customer_id where q.id = any (v_ids));
end $$;
revoke all on function fabula.trade_queue_claim() from public, anon, authenticated;
grant execute on function fabula.trade_queue_claim() to service_role;

create or replace function fabula.trade_queue_result(p_id uuid, p_ok boolean, p_draft text, p_order text, p_name text, p_error text) returns boolean
language plpgsql security definer set search_path = fabula, public as $$
begin
  if p_ok then
    update fabula.trade_order_queue set status = 'created', shopify_draft_id = p_draft, shopify_order_id = p_order, shopify_order_name = p_name, error = null, attempts = attempts + 1, done_at = now(), claimed_at = null where id = p_id;
    update fabula.sales_orders o set shopify_order_id = coalesce(o.shopify_order_id, p_order), updated_at = now() from fabula.trade_order_queue q where q.id = p_id and o.id = q.sales_order_id;
  else
    update fabula.trade_order_queue set status = case when attempts + 1 >= 8 then 'failed' else 'pending' end, error = left(p_error, 500), attempts = attempts + 1, claimed_at = null where id = p_id;
    if (select attempts from fabula.trade_order_queue where id = p_id) >= 8 then
      insert into fabula.bot_messages (agent, severity, title, body, source) values ('wholesale_orders', 'alert', 'Ordine Shopify non creato', 'Ordine ingrosso ' || (select payload->>'order_number' from fabula.trade_order_queue where id = p_id) || ' non creato su Shopify dopo 8 tentativi: ' || coalesce(left(p_error, 200), '?'), 'trade_queue');
    end if;
  end if;
  return found;
end $$;

-- ============================================================================================================================
-- 5. The weekly plan: confirmed deliveries stay as booked; windows from the list
-- ============================================================================================================================
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.trade_save_schedule(uuid,jsonb,text)'::regprocedure);
  n := replace(d, $s$  if v_start < fabula.trade_now_rome()::date then raise exception 'La data di inizio non può essere nel passato' using errcode = '22023'; end if;
$s$, $s$  if v_start < fabula.trade_now_rome()::date then raise exception 'La data di inizio non può essere nel passato' using errcode = '22023'; end if;
  -- v1.10 (quality test item 7): the windows offered only (trade.windows); empty = the plan's own
  if jsonb_array_length(coalesce(s->'windows', '[]')) > 0 then
    for v in select w from (select nullif(p_payload->>'window', '') w
                            union all select nullif(dd.value->>'window', '') from jsonb_each(case when jsonb_typeof(p_payload->'days') = 'object' then p_payload->'days' else '{}' end) dd
                             where jsonb_typeof(dd.value) = 'object') x
              where w is not null and not exists (select 1 from jsonb_array_elements_text(s->'windows') o where o = w) loop
      raise exception 'Fascia oraria non prevista: % (quelle possibili: %)', v, (select string_agg(o, ', ') from jsonb_array_elements_text(s->'windows') o) using errcode = '22023';
    end loop;
  end if;
  -- v1.10 (quality test item 7): a customer's new plan may not change a delivery already confirmed (past its cut-off); before, saving
  -- the plan «from tomorrow» after the 18:00 cut-off changed tomorrow's order until the booking at 18:20
  -- (a paused plan stays paused when saved, so it changes no delivery: not checked)
  if p_actor = 'customer' and not exists (select 1 from fabula.trade_schedules where customer_id = p_customer and status = 'paused') then
    declare v_d date := v_start; v_old jsonb; v_new jsonb; v_first date; v_wd text;
    begin
      while not fabula.trade_can_change(v_d) and v_d < fabula.trade_now_rome()::date + 14 loop
        -- a day the customer skips (a skip, or «Pausa fino al») has no delivery whatever the plan says
        if fabula.trade_is_delivery_day(v_d) and not exists (select 1 from fabula.trade_exceptions e where e.customer_id = p_customer and e.kind = 'skip'
                                                               and e.cancelled_at is null and v_d between e.date_from and e.date_to) then
          v_wd := extract(isodow from v_d)::int::text;
          select coalesce(jsonb_object_agg(l.variant_id, l.qty), '{}') into v_old
            from fabula.trade_schedule_lines l
            join fabula.trade_schedules ts on ts.customer_id = l.customer_id
            join fabula.trade_schedule_days sd on sd.customer_id = l.customer_id and sd.weekday = l.weekday and sd.active
           where l.customer_id = p_customer and l.weekday = v_wd::int and l.qty > 0
             and ts.status = 'active' and ts.start_date <= v_d and (ts.end_date is null or ts.end_date >= v_d);
          select coalesce(jsonb_object_agg(k, (p_payload->'days'->v_wd->'lines'->>k)::numeric), '{}') into v_new
            from jsonb_object_keys(case when jsonb_typeof(p_payload->'days'->v_wd->'lines') = 'object' then p_payload->'days'->v_wd->'lines' else '{}' end) k
           where coalesce((p_payload->'days'->v_wd->'lines'->>k)::numeric, 0) > 0;
          if v_old is distinct from v_new then
            v_first := v_d + 1;
            while not fabula.trade_can_change(v_first) and v_first < v_d + 14 loop v_first := v_first + 1; end loop;
            raise exception 'Gli ordini per % % sono già chiusi (%): fai partire il piano dal %', fabula.trade_wd_it(v_wd::int), to_char(v_d, 'DD/MM'),
              coalesce(s->>'cutoff_rule_it', 'ordini chiusi il giorno prima'), to_char(v_first, 'DD/MM/YYYY') using errcode = '22023';
          end if;
        end if;
        v_d := v_d + 1;
      end loop;
    end;
  end if;
$s$);
  if n = d then raise exception 'v110b: trade_save_schedule anchor not found'; end if;
  execute n;
end $mig$;

-- ============================================================================================================================
-- 6. Telegram: the name in «Se ne occupa …» escaped like every other text
-- ============================================================================================================================
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.notify_ack(bigint,uuid,text)'::regprocedure);
  n := replace(d, $s$replace(replace(v_name, '<', '&lt;'), '>', '&gt;')$s$, $s$fabula.tg_esc(v_name)$s$);
  if n = d then raise exception 'v110b: notify_ack anchor not found'; end if;
  execute n;
end $mig$;
