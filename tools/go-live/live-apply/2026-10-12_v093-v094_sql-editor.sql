-- One-shot apply of v0.93a–d + v0.94a for the Supabase dashboard SQL Editor (12/10/2026), for when the CLI / MCP route is not available.
-- Paste the whole file into Dashboard → SQL Editor → New query → Run. It runs as ONE transaction: either everything is applied and
-- recorded in the migration history (same versions as the files in supabase/migrations, so `supabase migration list` stays in step),
-- or nothing changes. Running it a second time stops at the first check and changes nothing.
begin;

do $chk$ begin
  if exists (select 1 from supabase_migrations.schema_migrations where version in ('20261012200000','20261012200100','20261012200200','20261012200300','20261012210000')) then
    raise exception 'STOP: v0.93/v0.94 are already in the migration history — nothing to do';
  end if;
  if (select max(version) from supabase_migrations.schema_migrations) <> '20261012183711' then
    raise exception 'STOP: the live history does not end at v0.92a (20261012183711) — tell Claude before applying';
  end if;
end $chk$;


-- ======================================================================= 20261012200000_v093a_audit_food_safety.sql
-- v0.93a · Audit 12/10/2026, phase 0 — food-safety fixes (audit doc "Caseificio ops — usability & error-proofing audit", bugs 1, 6, 7, 13).
-- Function bodies are patched in place (the pattern must match, otherwise the migration stops) so nothing else in them changes.

-- 1 · (D-01) A CCP out of limit holds the lot for every profile that can record it.
--     Before: log_ccp ran with the caller's rights. For Banco and Spedizioni (produzione level 1) the hold UPDATE on production_batches
--     matched 0 rows under RLS, raised nothing, and the function still answered lot_on_hold = true ("lotto … BLOCCATO" on the tablet)
--     while the lot stayed sellable. Same pattern as v055 §4a for record_calibration_check: definer + explicit permission check,
--     and lot_on_hold now reports what really happened. hold_lot and record_lab_result get the same treatment.
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.log_ccp(text,numeric,timestamptz,uuid,text,text,text,text,text)'::regprocedure);
  n := regexp_replace(d, '\nbegin\n', E'\nbegin\n  perform fabula.require_perm(''haccp'', 2);   -- v0.93a: runs as definer, so the lot hold below always applies\n');
  n := replace(n, E'      where id = v_batch;\n      v_hold := true;', E'      where id = v_batch;\n      v_hold := found;');
  if n = d or position('v_hold := found' in n) = 0 or position('require_perm(''haccp'', 2)' in n) = 0 then
    raise exception 'v093a: log_ccp patterns not found';
  end if;
  execute n;

  d := pg_get_functiondef('fabula.hold_lot(text,text,uuid)'::regprocedure);
  n := regexp_replace(d, '\nbegin\n', E'\nbegin\n  perform fabula.require_perm(''haccp'', 2);\n');
  if n = d then raise exception 'v093a: begin not found in hold_lot'; end if;
  execute n;

  d := pg_get_functiondef('fabula.record_lab_result(text,text,numeric,text,text,date,uuid,uuid)'::regprocedure);
  n := regexp_replace(d, '\nbegin\n', E'\nbegin\n  perform fabula.require_perm(''haccp'', 2);\n');
  -- 3 (part) · (B-10/E-11) a recall/withdrawal assessment has no deadline after which it silently disappears
  n := regexp_replace(n, '''pending'', now\(\) \+ interval ''2 days''\)', '''pending'', null)');
  if n = d or position('require_perm(''haccp'', 2)' in n) = 0 or position('''pending'', null)' in n) = 0 then
    raise exception 'v093a: record_lab_result patterns not found';
  end if;
  execute n;
end $mig$;

alter function fabula.log_ccp(text,numeric,timestamptz,uuid,text,text,text,text,text) security definer;
alter function fabula.hold_lot(text,text,uuid) security definer;
alter function fabula.record_lab_result(text,text,numeric,text,text,date,uuid,uuid) security definer;
revoke execute on function fabula.log_ccp(text,numeric,timestamptz,uuid,text,text,text,text,text) from public, anon;
revoke execute on function fabula.hold_lot(text,text,uuid) from public, anon;
revoke execute on function fabula.record_lab_result(text,text,numeric,text,text,date,uuid,uuid) from public, anon;
grant execute on function fabula.log_ccp(text,numeric,timestamptz,uuid,text,text,text,text,text) to authenticated, service_role;
grant execute on function fabula.hold_lot(text,text,uuid) to authenticated, service_role;
grant execute on function fabula.record_lab_result(text,text,numeric,text,text,date,uuid,uuid) to authenticated, service_role;

-- 2 · (E-02) Active notices: alerts first. Before: "order by severity desc" on a text column sorted warn > info > alert, so the red
--     "Prima di chiudere" food-safety list came last on the tablet, under technical warnings.
create or replace view fabula.v_active_notices with (security_invoker = true) as
select id, key, severity, title_it, items, created_at, expires_at, resolved_at
  from fabula.notices
 where resolved_at is null and expires_at > now()
 order by case severity when 'alert' then 0 when 'warn' then 1 else 2 end, created_at desc;

-- 3 · (B-10/E-11) A recall/withdrawal assessment (art. 19 Reg. CE 178/2002) never expires by itself, and while it waits the nightly
--     health check reports it as its own issue, so the system-check bot pushes it every evening until someone decides.
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.ops_health_check(date)'::regprocedure);
  n := replace(d, $s$update fabula.approvals set status = 'expired' where status = 'pending' and expires_at < now();$s$,
                  $s$update fabula.approvals set status = 'expired' where status = 'pending' and expires_at < now()
     and coalesce(payload->>'type', '') <> 'recall_assessment';   -- v0.93a: a recall decision never lapses by itself$s$);
  n := replace(n, $s$    select 'approvals_stale', $s$,
                  $s$    select 'recall_pending', 'DA DECIDERE SUBITO · valutazione ritiro/richiamo (art. 19 Reg. CE 178/2002) in attesa: ' ||
           string_agg(coalesce(payload->>'lot', 'lotto n/d') || ' (' || coalesce(payload->>'test', '?') || ', dal ' || to_char(requested_at at time zone 'Europe/Rome', 'DD/MM') || ')', ', ') ||
           ' · Console → Oggi → Da approvare', count(*)
      from fabula.approvals where status = 'pending' and payload->>'type' = 'recall_assessment' having count(*) > 0
    union all
    select 'approvals_stale', $s$);
  if n = d or position('recall_pending' in n) = 0 or position('<> ''recall_assessment''' in n) = 0 then
    raise exception 'v093a: ops_health_check patterns not found';
  end if;
  execute n;
end $mig$;

-- recall assessments already waiting lose the 2-day deadline; any that lapsed are back in "Da approvare"
update fabula.approvals set expires_at = null where status = 'pending' and payload->>'type' = 'recall_assessment';
update fabula.approvals set status = 'pending', expires_at = null where status = 'expired' and payload->>'type' = 'recall_assessment';

-- 4 · (B-01) Critical limits cannot be blanked by mistake. Before: clearing "Min" in Autocontrollo → Piano HACCP saved NULL and ccp_eval
--     then skipped that limit for good (every reading "ok", no NC, no hold). Now, for a CCP: at least one critical limit, a limit that
--     was set can be changed but not emptied, min below max, alert thresholds inside the critical limits.
create or replace function fabula.haccp_cp_limits_guard() returns trigger
language plpgsql set search_path = fabula, public as $$
declare v_name text := coalesce(new.ccp_no || ' · ', '') || coalesce(new.name, new.code);
begin
  if not new.is_ccp then return new; end if;
  if tg_op = 'UPDATE' then
    if old.min_value is not null and new.min_value is null then
      raise exception '%: il limite minimo (%) non si può cancellare. Scrivi il nuovo valore deciso con il consulente HACCP.', v_name, old.min_value using errcode = '23514';
    end if;
    if old.max_value is not null and new.max_value is null then
      raise exception '%: il limite massimo (%) non si può cancellare. Scrivi il nuovo valore deciso con il consulente HACCP.', v_name, old.max_value using errcode = '23514';
    end if;
  end if;
  if new.min_value is null and new.max_value is null then
    raise exception '%: un punto critico deve avere almeno un limite critico (minimo o massimo)', v_name using errcode = '23514';
  end if;
  if new.min_value is not null and new.max_value is not null and new.min_value >= new.max_value then
    raise exception '%: il minimo (%) deve essere più basso del massimo (%)', v_name, new.min_value, new.max_value using errcode = '23514';
  end if;
  if new.warn_min is not null and new.min_value is not null and new.warn_min < new.min_value then
    raise exception '%: l''allerta minima (%) deve stare dentro il limite critico (minimo %)', v_name, new.warn_min, new.min_value using errcode = '23514';
  end if;
  if new.warn_max is not null and new.max_value is not null and new.warn_max > new.max_value then
    raise exception '%: l''allerta massima (%) deve stare dentro il limite critico (massimo %)', v_name, new.warn_max, new.max_value using errcode = '23514';
  end if;
  return new;
end $$;
drop trigger if exists haccp_cp_limits_guard on fabula.haccp_control_points;
create trigger haccp_cp_limits_guard before insert or update of min_value, max_value, warn_min, warn_max, is_ccp
  on fabula.haccp_control_points for each row execute function fabula.haccp_cp_limits_guard();


-- ======================================================================= 20261012200100_v093b_audit_weighed_pos_sales.sql
-- v0.93b · Audit 12/10/2026, phase 0 — bug 3 (POS-06): a weighed counter sale no longer stops the Shopify order sync.
-- A line added from the «Pesa» tile is a Shopify POS custom sale: it has no variant. upsert_shopify_orders then tried to insert a
-- NULL variant id into shopify_variant_map (primary key) → not-null violation → the whole batch failed, and kept failing for the
-- bot's 3-day window (web orders, POS day closings and stock moves all stopped). Now such a line is booked from its line properties
-- (sku + peso_kg, written by the Pesa tile; the Ordini Shopify bot passes them as "properties"), so weighed sales reach stock and
-- lots like any other sale; without usable properties it is listed in shopify_unmapped_lines ("vendita libera") and the rest of the
-- order and of the batch is saved.
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.upsert_shopify_orders(jsonb)'::regprocedure);
  n := replace(d,
    E'        select * into v_map from fabula.shopify_variant_map where variant_id = l->>''variant_id'';\n',
    E'        -- v0.93b (audit POS-06): weighed counter sale = custom sale with no variant: book it from sku + peso_kg\n'
    '        if nullif(l->>''variant_id'', '''') is null then\n'
    '          v_prod := (select id from fabula.products where sku = coalesce(nullif(l->''properties''->>''sku'', ''''), nullif(l->>''sku'', '''')) limit 1);\n'
    '          v_line_kg := nullif(coalesce(l->''properties''->>''peso_kg'', l->>''peso_kg''), '''')::numeric * coalesce((l->>''quantity'')::numeric, 1);\n'
    '          if v_prod is null or v_line_kg is null or v_line_kg <= 0 then\n'
    '            insert into fabula.shopify_unmapped_lines (sales_order_id, variant_id, title, variant_title, qty, unit_price_eur)\n'
    '            values (v_id, ''vendita libera'', coalesce(l->>''title'', ''?''), l->>''variant_title'', (l->>''quantity'')::numeric, (l->>''price'')::numeric)\n'
    '            on conflict (sales_order_id, variant_id, title) do update set qty = excluded.qty, seen_at = now();\n'
    '            n_unm := n_unm + 1; continue;\n'
    '          end if;\n'
    '          agg := jsonb_set(agg, array[v_prod::text], jsonb_build_object(\n'
    '            ''kg'',  coalesce((agg->v_prod::text->>''kg'')::numeric, 0) + v_line_kg,\n'
    '            ''eur'', coalesce((agg->v_prod::text->>''eur'')::numeric, 0) + (l->>''quantity'')::numeric * (l->>''price'')::numeric,\n'
    '            ''iva'', coalesce((l->>''tax_rate'')::numeric, nullif(l->''properties''->>''iva'', '''')::numeric, 4)));\n'
    '          continue;\n'
    '        end if;\n'
    '        select * into v_map from fabula.shopify_variant_map where variant_id = l->>''variant_id'';\n');
  if n = d or position('audit POS-06' in n) = 0 then raise exception 'v093b: line loop of upsert_shopify_orders not found'; end if;
  execute n;
end $mig$;


-- ======================================================================= 20261012200200_v093c_audit_task_times_rome.sql
-- v0.93c · Audit 12/10/2026, phase 0 — bug 10 (A-05 / D-16): daily task times are Agropoli times.
-- Before: (p_date + due_time)::timestamptz used the database time zone, which is UTC on Supabase (checked live 12/10/2026),
-- so the pasteuriser start-of-day check due 06:45 showed at 07:45 in winter and 08:45 in summer, the twice-daily cold-room checks
-- at 09:00/19:00 or 10:00/20:00, and the day itself was the UTC day. Now every due time is read as Europe/Rome local time
-- (DST included) and the default day is today in Agropoli.
create or replace function fabula.generate_daily_tasks(p_date date default (now() at time zone 'Europe/Rome')::date)
 returns integer
 language plpgsql
 set search_path to 'fabula', 'public', 'extensions'
as $function$
declare n int := 0;
begin
  insert into fabula.task_instances (schedule_id, due_at)
  select s.id, (p_date + coalesce(s.due_time, time '12:00')) at time zone 'Europe/Rome'
  from fabula.task_schedules s
  where s.active and s.frequency in ('daily','per_shift')
  union all
  select s.id, (p_date + time '08:00') at time zone 'Europe/Rome' from fabula.task_schedules s
  where s.active and s.frequency = 'twice_daily'
  union all
  select s.id, (p_date + time '18:00') at time zone 'Europe/Rome' from fabula.task_schedules s
  where s.active and s.frequency = 'twice_daily'
  union all
  select s.id, (p_date + coalesce(s.due_time, time '12:00')) at time zone 'Europe/Rome' from fabula.task_schedules s
  where s.active and s.frequency = 'weekly' and extract(isodow from p_date) = 1
  union all
  select s.id, (p_date + coalesce(s.due_time, time '12:00')) at time zone 'Europe/Rome' from fabula.task_schedules s
  where s.active and s.frequency = 'monthly' and extract(day from p_date) = 1
  on conflict do nothing;
  get diagnostics n = row_count;
  -- mark yesterday's leftovers overdue
  update fabula.task_instances set status = 'overdue'
  where status = 'due' and due_at + make_interval(mins => 120) < now();
  return n;
end $function$;


-- ======================================================================= 20261012200300_v093d_audit_wholesale.sql
-- v0.93d · Audit 12/10/2026, phase 0 — wholesale fixes (bugs 14, 15, 16, 17).
--  14 (TRADE-02 / E-15) A one-day change can no longer drop a delivery under the minimum order: the change is refused with the reason,
--     as the setting trade.min_order_kg always promised. A delivery that is still under the minimum at booking time (18:20) is no longer
--     dropped in silence: the customer reads it in the portal log and the office gets a warning in the Bot feed.
--  15 (D-14 / TRADE-04) "La consegna del 13/10s … le 18:00s": PL/pgSQL placeholders are %, not %s.
--  16 (B-20 / D-10) A change forced by staff after the 18:20 booking used to be logged ("Saltata la consegna") while the booked order
--     still shipped and was invoiced. Now «Salta» on a booked day also cancels that order (and its Shopify queue entry if not sent yet,
--     otherwise the message says to cancel the Shopify order too); any other change to a booked day is refused with what to do instead.
--  17 (PRINT-01) The DDT shows the delivery address, time window, driver instructions and the customer's PO number of the order.

create or replace function fabula.trade_add_exception(p_customer uuid, p_payload jsonb, p_actor text default 'customer'::text, p_force boolean default false)
 returns jsonb
 language plpgsql
 set search_path to 'fabula', 'public'
as $function$
declare k text := p_payload->>'kind'; d1 date := (p_payload->>'date_from')::date; d2 date := coalesce(nullif(p_payload->>'date_to', '')::date, (p_payload->>'date_from')::date); v_id uuid; msg text; s jsonb := fabula.trade_settings(); tp fabula.trade_products%rowtype;
        o record; v_booked text := ''; v_shop text := ''; dd date; v_kg numeric; v_min numeric := nullif(fabula.trade_settings()->>'min_order_kg', '')::numeric;
begin
  if k not in ('skip','override','window') then raise exception 'Tipo di modifica non valido' using errcode = '22023'; end if;
  if d2 < d1 then raise exception 'Date non valide' using errcode = '22023'; end if;
  if not p_force and not fabula.trade_can_change(d1) then
    raise exception 'La consegna del % è già confermata (modifiche entro le % del giorno prima)', to_char(d1, 'DD/MM'), s->>'cutoff_time' using errcode = '22023';
  end if;
  -- v0.93d (audit B-20/D-10): a day already booked as an order. «Salta» cancels the order; other changes would not reach it → refused.
  for o in select so.id, so.order_number, so.order_date, so.status::text as status, q.status as qstatus, q.shopify_order_name
             from fabula.sales_orders so left join fabula.trade_order_queue q on q.sales_order_id = so.id
            where so.customer_id = p_customer and so.channel = 'wholesale' and so.source = 'standing_order' and so.status <> 'cancelled'
              and so.order_date between d1 and d2 order by so.order_date loop
    if o.status = 'fulfilled' then
      raise exception 'La consegna del % è già partita (ordine %): non si può più cambiare.', to_char(o.order_date, 'DD/MM'), o.order_number using errcode = '22023';
    end if;
    if k <> 'skip' then
      raise exception 'La consegna del % è già prenotata (ordine %): questa modifica non la cambierebbe. Per non consegnare usa «Salta» per quel giorno; per altre quantità salta e prepara un ordine a parte.', to_char(o.order_date, 'DD/MM'), o.order_number using errcode = '22023';
    end if;
    update fabula.sales_orders set status = 'cancelled', notes = concat_ws(' · ', notes, 'annullato: consegna saltata dopo la prenotazione (' || p_actor || ')'), updated_at = now() where id = o.id;
    update fabula.trade_order_queue set status = 'skipped', error = 'consegna saltata dopo la prenotazione' where sales_order_id = o.id and status in ('pending', 'failed');
    v_booked := v_booked || case when v_booked = '' then '' else ', ' end || o.order_number;
    if o.qstatus = 'created' then v_shop := v_shop || case when v_shop = '' then '' else ', ' end || coalesce(o.shopify_order_name, o.order_number); end if;
  end loop;
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
  -- v0.93d (audit TRADE-02): a change that leaves a delivery under the minimum order is refused (it used to be accepted and the
  -- delivery then silently not booked). Checked on the plan as it is after this change, for every delivery day in the range.
  if k = 'override' and v_min is not null then
    for dd in select g::date from generate_series(d1, least(d2, d1 + 62), interval '1 day') g loop
      continue when not fabula.trade_is_delivery_day(dd);
      select coalesce(sum(e.kg), 0) into v_kg from fabula.trade_effective_lines(dd) e where e.customer_id = p_customer;
      if v_kg > 0 and v_kg < v_min then
        raise exception 'Con questa modifica la consegna del % scende a % kg, sotto il minimo d''ordine di % kg: aumenta la quantità oppure salta la consegna di quel giorno.',
          to_char(dd, 'DD/MM'), replace(trim_scale(round(v_kg, 2))::text, '.', ','), replace(trim_scale(v_min)::text, '.', ',') using errcode = '22023';
      end if;
    end loop;
  end if;
  msg := case k
    when 'skip' then case when d1 = d2 then format('Saltata la consegna del %s.', to_char(d1, 'DD/MM/YYYY')) else format('Chiusura dal %s al %s: nessuna consegna in quei giorni.', to_char(d1, 'DD/MM/YYYY'), to_char(d2, 'DD/MM/YYYY')) end
    when 'override' then format('%s: %s → %s %s %s. Dopo si torna al piano normale.', case when d1 = d2 then 'Il ' || to_char(d1, 'DD/MM/YYYY') else 'Dal ' || to_char(d1, 'DD/MM/YYYY') || ' al ' || to_char(d2, 'DD/MM/YYYY') end,
                                tp.title || coalesce(' ' || tp.variant_title, ''), trim_scale((p_payload->>'qty')::numeric), tp.unit_label, case when (p_payload->>'qty')::numeric = 0 then '(tolto)' else '' end)
    else format('%s: consegna nella fascia %s. Dopo si torna alla fascia abituale.', case when d1 = d2 then 'Il ' || to_char(d1, 'DD/MM/YYYY') else 'Dal ' || to_char(d1, 'DD/MM/YYYY') || ' al ' || to_char(d2, 'DD/MM/YYYY') end, p_payload->>'window') end;
  if v_booked <> '' then msg := msg || ' Ordine già prenotato ' || v_booked || ' annullato.'; end if;
  perform fabula.trade_log(p_customer, p_actor, 'exception_' || k, p_payload || jsonb_build_object('id', v_id, 'cancelled_orders', v_booked), msg);
  return jsonb_build_object('ok', true, 'id', v_id, 'message_it',
    msg || case when v_shop <> '' then ' ATTENZIONE: era già su Shopify (' || v_shop || '): annullalo anche su Shopify.' else '' end,
    'cancelled_orders', nullif(v_booked, ''), 'cancel_on_shopify', nullif(v_shop, ''));
end $function$;

-- 15 · the other "%s" message
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.trade_cancel_exception(uuid,uuid,text,boolean)'::regprocedure);
  n := replace(d, $s$raise exception 'La consegna del %s è già confermata', $s$, $s$raise exception 'La consegna del % è già confermata', $s$);
  if n = d then raise exception 'v093d: message not found in trade_cancel_exception'; end if;
  execute n;
end $mig$;

-- 14 (booking) · under the minimum at 18:20: the customer is told in the portal and the office gets a warning, once per customer and day
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.confirm_standing_orders(date)'::regprocedure);
  n := replace(d, $s$    if c.kg < v_min then under := under || jsonb_build_object('customer', c.legal_name, 'kg', c.kg); continue; end if;$s$,
$s$    if c.kg < v_min then
      under := under || jsonb_build_object('customer', c.legal_name, 'kg', c.kg, 'phone', c.phone);
      -- v0.93d (audit E-15): no longer silent — portal log for the customer, Bot feed warning for the office (once per customer and day)
      if not exists (select 1 from fabula.trade_change_log x where x.customer_id = c.customer_id and x.action = 'under_minimum' and x.details->>'date' = d::text) then
        perform fabula.trade_log(c.customer_id, 'sistema', 'under_minimum', jsonb_build_object('date', d, 'kg', c.kg, 'min_kg', v_min),
          format('Consegna di %s %s NON prenotata: %s kg sono sotto il minimo d''ordine di %s kg. Se ti serve comunque, chiamaci.',
                 fabula.trade_wd_it(extract(isodow from d)::int), to_char(d, 'DD/MM'), replace(trim_scale(round(c.kg, 2))::text, '.', ','), replace(trim_scale(v_min)::text, '.', ',')));
        perform fabula.post_bot_message('wholesale_orders', 'warn',
          format('Consegna di %s %s NON prenotata: %s', fabula.trade_wd_it(extract(isodow from d)::int), to_char(d, 'DD/MM'), c.legal_name),
          format(E'**Da fare**\n1. Chiama %s%s: %s kg sono sotto il minimo d''ordine di %s kg, quindi la consegna non parte. Se va consegnata comunque, prepara un ordine a parte.\n\nEN — %s will not get a delivery on %s: below the minimum order.',
                 c.legal_name, coalesce(' (' || c.phone || ')', ''), replace(trim_scale(round(c.kg, 2))::text, '.', ','), replace(trim_scale(v_min)::text, '.', ','), c.legal_name, to_char(d, 'DD/MM')));
      end if;
      continue;
    end if;$s$);
  if n = d then raise exception 'v093d: under-minimum line not found in confirm_standing_orders'; end if;
  execute n;
end $mig$;

-- 17 · DDT: where the goods go, when, how, and the customer's reference (columns appended; security_invoker kept)
create or replace view fabula.v_shipment_doc with (security_invoker = true) as
  select sh.id as shipment_id, sh.ddt_number, sh.ship_date, sh.status::text as status, sh.carrier, sh.tracking_number, sh.gross_weight_kg, sh.notes, sh.packed_at,
         o.order_number, o.channel::text as channel, o.order_date, o.total_eur, o.ship_city, o.shopify_payload->'shipping_address' as ship_address, o.shopify_payload->>'email' as order_email,
         p.legal_name as customer, p.address as customer_address, p.city as customer_city, p.province as customer_province, p.postcode as customer_postcode, p.piva as customer_piva, p.phone as customer_phone, p.email as customer_email,
         st.full_name as packed_by,
         (select coalesce(jsonb_agg(jsonb_build_object('name', pr.name, 'sku', pr.sku, 'unit', pr.unit, 'lot', sl.lot_number, 'qty', sl.qty, 'ordered', sl.ordered_qty, 'expiry', s.expiry_date, 'weighed', sl.weighed) order by pr.name, sl.lot_number), '[]')
          from fabula.shipment_lines sl join fabula.products pr on pr.id = sl.product_id
          left join lateral (select max(expiry_date) expiry_date from fabula.stock_moves m where m.product_id = sl.product_id and m.lot_number = sl.lot_number) s on true
          where sl.shipment_id = sh.id) as lines,
         o.delivery_address, o.delivery_window, o.delivery_instructions, o.po_number
  from fabula.shipments sh left join fabula.sales_orders o on o.id = sh.sales_order_id left join fabula.parties p on p.id = sh.customer_id left join fabula.staff st on st.id = sh.packed_by_id;
grant select on fabula.v_shipment_doc to authenticated, service_role;


-- ======================================================================= 20261012210000_v094a_farm_shipment_corrections.sql
-- v0.94a · Audit 12/10/2026 — completes A-10 / FARM-03 (with FARM-02b): a farm load registered by mistake can be put right, and a
-- load left «in viaggio» is flagged to the office instead of sitting in the tablet's list for weeks.
-- Before: the farm could not correct or cancel its own entry (its only option was a second shipment, i.e. a second load in transit
-- for the dairy to pick from), the office had no way to close a stale one, and nothing reported it.
--   1. milk_shipments gets the status 'cancelled' (+ who, when, why) and keeps the kg first entered when the farm corrects it
--      (the audit trigger keeps every old row too).
--   2. farm_milk_amend: from its page the farm corrects the kg of, or cancels, a load that is still «in viaggio» (reason required);
--      the office gets a message in the Bot feed. Called by the edge function farm-order (action "amend"), service_role only.
--   3. milk_shipment_cancel: the office cancels a load from the console (produzione level 2, reason required).
--   4. ops_health_check reports loads «in viaggio» for more than 36 h (past the 60 h DOP window anyway) every evening.
--   5. A cancelled load: not offered on the tablet, refused by the intake trigger ("già stata annullata"), shown on the farm page
--      with its reason; a re-entry with the same kg right after a cancel is no longer taken for a double tap.

-- 1 · status 'cancelled' and the correction trail
alter table fabula.milk_shipments drop constraint if exists milk_shipments_status_check;
alter table fabula.milk_shipments add constraint milk_shipments_status_check check (status in ('shipped', 'received', 'rejected', 'cancelled'));
alter table fabula.milk_shipments
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancelled_by text,                         -- 'Masseria' or the staff member's name
  add column if not exists cancel_reason text,
  add column if not exists original_kg numeric(8,1),                  -- kg first entered, when the farm corrected it
  add column if not exists corrected_at timestamptz,
  add column if not exists correction_reason text;
comment on column fabula.milk_shipments.original_kg is 'v0.94: kg first entered by the farm, kept when it corrects the weight (kg is the corrected value).';

-- 2 · the farm corrects or cancels a load still in transit (token checked here, like farm_milk_ship)
create or replace function fabula.farm_milk_amend(p_token text, p_lot text, p_kg numeric default null, p_cancel boolean default false, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare v_tok text := (select value from fabula.settings where key = 'milk.farm_token');
        r fabula.milk_shipments; v_reason text := nullif(left(trim(coalesce(p_reason, '')), 300), '');
begin
  if v_tok is null or length(v_tok) < 16 or p_token is distinct from v_tok then return null; end if;
  select * into r from fabula.milk_shipments where milk_lot = p_lot for update;
  if not found then raise exception 'Spedizione % non trovata', p_lot using errcode = '22023'; end if;
  if r.status <> 'shipped' then
    raise exception 'La spedizione % è già stata %: non si può più cambiare. Chiama il caseificio.', r.milk_lot,
      case r.status when 'received' then 'ricevuta dal caseificio' when 'rejected' then 'respinta dal caseificio' else 'annullata' end using errcode = '22023';
  end if;
  if r.shipped_at < now() - interval '7 days' then raise exception 'La spedizione % è di più di 7 giorni fa: chiama il caseificio.', r.milk_lot using errcode = '22023'; end if;
  if v_reason is null or length(v_reason) < 3 then raise exception 'Scrivi il motivo (es. «registrata due volte», «peso sbagliato»)' using errcode = '22023'; end if;
  if coalesce(p_cancel, false) then
    update fabula.milk_shipments set status = 'cancelled', cancelled_at = now(), cancelled_by = 'Masseria', cancel_reason = v_reason
     where id = r.id returning * into r;
    perform fabula.post_bot_message('masseria', 'warn', 'Masseria: spedizione ' || r.milk_lot || ' annullata',
      format('La Masseria ha annullato la spedizione %s (%s kg, partita %s). Motivo: %s. Sul tablet non compare più tra quelle in arrivo.',
             r.milk_lot, replace(to_char(r.kg, 'FM99990.0'), '.', ','), to_char(r.shipped_at at time zone 'Europe/Rome', 'DD/MM HH24:MI'), v_reason));
  else
    if p_kg is null or p_kg <= 0 or p_kg > 5000 then raise exception 'Peso non valido: %', p_kg using errcode = '22023'; end if;
    if round(p_kg, 1) = r.kg then raise exception 'Il peso è già % kg', replace(to_char(r.kg, 'FM99990.0'), '.', ',') using errcode = '22023'; end if;
    update fabula.milk_shipments set original_kg = coalesce(original_kg, kg), kg = round(p_kg, 1), corrected_at = now(), correction_reason = v_reason
     where id = r.id returning * into r;
    perform fabula.post_bot_message('masseria', 'info', 'Masseria: peso corretto su ' || r.milk_lot,
      format('La Masseria ha corretto la spedizione %s: %s kg (prima %s kg). Motivo: %s.',
             r.milk_lot, replace(to_char(r.kg, 'FM99990.0'), '.', ','), replace(to_char(r.original_kg, 'FM99990.0'), '.', ','), v_reason));
  end if;
  return jsonb_build_object('milk_lot', r.milk_lot, 'kg', r.kg, 'status', r.status, 'original_kg', r.original_kg);
end $$;
revoke all on function fabula.farm_milk_amend(text, text, numeric, boolean, text) from public, anon, authenticated;
grant execute on function fabula.farm_milk_amend(text, text, numeric, boolean, text) to service_role;

-- 3 · the office cancels a load from the console
create or replace function fabula.milk_shipment_cancel(p_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare r fabula.milk_shipments; v_reason text := nullif(left(trim(coalesce(p_reason, '')), 300), '');
begin
  perform fabula.require_perm('produzione', 2);
  if v_reason is null or length(v_reason) < 3 then raise exception 'Scrivi il motivo dell''annullamento' using errcode = '22023'; end if;
  select * into r from fabula.milk_shipments where id = p_id for update;
  if not found then raise exception 'Spedizione non trovata' using errcode = '22023'; end if;
  if r.status <> 'shipped' then raise exception 'La spedizione % non è più in viaggio (%)', r.milk_lot, r.status using errcode = '22023'; end if;
  update fabula.milk_shipments
     set status = 'cancelled', cancelled_at = now(), cancel_reason = v_reason,
         cancelled_by = coalesce((select full_name from fabula.staff where id = fabula.my_staff_id()), 'ufficio')
   where id = r.id returning * into r;
  return jsonb_build_object('milk_lot', r.milk_lot, 'status', r.status);
end $$;
revoke all on function fabula.milk_shipment_cancel(uuid, text) from public, anon;
grant execute on function fabula.milk_shipment_cancel(uuid, text) to authenticated, service_role;

-- 4 · loads in transit for more than 36 h are reported by the evening health check
-- 5 · cancelled loads: the farm page shows them with the reason; the intake trigger names them; a cancel is not a "double tap"
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.ops_health_check(date)'::regprocedure);
  n := replace(d, $s$    select 'approvals_stale', $s$,
                  $s$    select 'milk_shipments_stale', 'Spedizioni Masseria «in viaggio» da oltre 36 ore (mai confermate all''arrivo): ' ||
           string_agg(milk_lot || ' · ' || replace(to_char(kg, 'FM99990.0'), '.', ',') || ' kg, partita ' || to_char(shipped_at at time zone 'Europe/Rome', 'DD/MM HH24:MI'), ', ' order by shipped_at) ||
           ' · se il latte è arrivato confermalo dal tablet, altrimenti annullala dalla Console → Oggi', count(*)
      from fabula.milk_shipments where status = 'shipped' and shipped_at < now() - interval '36 hours' having count(*) > 0
    union all
    select 'approvals_stale', $s$);
  if n = d or position('milk_shipments_stale' in n) = 0 then raise exception 'v094a: ops_health_check pattern not found'; end if;
  execute n;

  d := pg_get_functiondef('fabula.farm_milk_orders(text)'::regprocedure);
  n := replace(d, $s$'arrival_temp_c', mi.temperature_c, 'rejection_reason', mi.rejection_reason)$s$,
                  $s$'arrival_temp_c', mi.temperature_c, 'rejection_reason', mi.rejection_reason,
                                                              'cancel_reason', s.cancel_reason, 'cancelled_by', s.cancelled_by,
                                                              'original_kg', s.original_kg, 'correction_reason', s.correction_reason)$s$);
  if n = d then raise exception 'v094a: farm_milk_orders pattern not found'; end if;
  execute n;

  d := pg_get_functiondef('fabula.farm_milk_ship(text,numeric,numeric,text,text)'::regprocedure);
  n := replace(d, $s$where kg = round(p_kg, 1) and shipped_at > now() - interval '3 minutes'$s$,
                  $s$where kg = round(p_kg, 1) and shipped_at > now() - interval '3 minutes' and status <> 'cancelled'$s$);
  if n = d then raise exception 'v094a: farm_milk_ship pattern not found'; end if;
  execute n;

  d := pg_get_functiondef('fabula.milk_intake_shipment_check()'::regprocedure);
  n := replace(d, $s$case s.status when 'received' then 'ricevuta' else 'respinta' end$s$,
                  $s$case s.status when 'received' then 'ricevuta' when 'cancelled' then 'annullata (' || coalesce(s.cancel_reason, '') || ')' else 'respinta' end$s$);
  if n = d then raise exception 'v094a: milk_intake_shipment_check pattern not found'; end if;
  execute n;
end $mig$;


-- record them in the migration history, with the same versions as the files
insert into supabase_migrations.schema_migrations (version, name) values
  ('20261012200000', 'v093a_audit_food_safety'),
  ('20261012200100', 'v093b_audit_weighed_pos_sales'),
  ('20261012200200', 'v093c_audit_task_times_rome'),
  ('20261012200300', 'v093d_audit_wholesale'),
  ('20261012210000', 'v094a_farm_shipment_corrections');

commit;

-- the result shown under the editor: the last five lines of the history
select version, name from supabase_migrations.schema_migrations order by version desc limit 5;
