-- v1.04a · Audit 12/10/2026, D-17 (rest) and D-22 + PRINT-04: paper copies and packing.
--   * D-17 «Ricopia da foglio di carta»: a sheet line already in the register (same check, same value, same lot or same milk
--     delivery, within 2 minutes) is refused, saying when and how it was recorded. A check on a lot must fall within that lot's
--     working time (from 3 hours before its production day, or its start, or its parent vat's start, to 6 hours after its close): a
--     line copied with the wrong date is refused. (A ricotta lot started on the tablet after the fact, when its sheet is copied, keeps
--     its sheet lines: the day and the parent vat count, not only the moment the lot was typed in.)
--     (The signer is chosen from the list since v0.96, audit A-19.)
--   * D-22 packing: each product is compared with what was ordered of it, not the order total. Over-packing beyond
--     ship.max_variance_pct (30 %) is refused even when confirmed (50 kg typed for 5); a product that is not in the order is refused;
--     a product left out or under the tolerance still asks for confirmation (partial shipment). Two tablets packing the same order
--     at once: the second waits and is told it is already packed.
--   * D-22 / PRINT-04 DDT numbers: one progressive series per year, gap-free, made by the database (DDT-2026-0001, -0002, …) for
--     every shipment: packing and the direct shipment from a lot (which used «DDT-<date>-<last 4 digits of the clock>»). A number in
--     the old daily form sent by an older tablet is replaced. A login's shipment is dated today (Rome), which also picks the year.
--     From a login a DDT's number, date, customer and order cannot be changed and a shipment cannot be deleted (it would leave a
--     hole in the series). shipments.ship_date defaults to the Rome date (it was the UTC date: yesterday between 00:00 and 02:00).

-- ============================== D-17 paper copies ==============================
create or replace function fabula.log_ccp(p_cp_code text, p_value numeric, p_logged_at timestamp with time zone, p_staff_id uuid default null::uuid, p_batch_lot text default null::text, p_action text default null::text, p_source text default 'tablet'::text, p_equipment_code text default null::text, p_written_by text default null::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'fabula', 'public', 'extensions'
as $function$
declare v_at timestamptz := now(); v_op text; v_op_id uuid; cp fabula.haccp_control_points%rowtype; v_res fabula.haccp_result; v_batch uuid; v_log uuid; v_nc uuid; v_staff text; v_eq uuid; v_hold boolean := false; v_oos text;
        d record; b record; v_lo timestamptz; v_hi timestamptz; v_parent_start timestamptz;
begin
  perform fabula.require_perm('haccp', 2);   -- v0.93a: runs as definer, so the lot hold below always applies
  -- v0.77: a check written on paper (tablet or Wi-Fi down) and typed in later keeps the time it was done
  if coalesce(p_source, 'tablet') = 'paper' then
    if p_logged_at is null or p_logged_at > now() + interval '5 minutes' or p_logged_at < now() - interval '7 days' then
      raise exception 'Data e ora del foglio non valide: al massimo 7 giorni fa, non nel futuro' using errcode = '22023';
    end if;
    v_at := p_logged_at;
  -- v0.97 (audit D-04): a check saved on the tablet without network keeps the time it was taken (created_at = when it arrived)
  elsif p_logged_at is not null and p_logged_at < now() - interval '2 minutes' and p_logged_at > now() - interval '7 days' then
    v_at := p_logged_at;
  end if;
  select * into cp from fabula.haccp_control_points where code = p_cp_code and active;
  if cp.id is null then raise exception 'Punto di controllo sconosciuto o non attivo: %', p_cp_code; end if;
  if p_batch_lot is not null and p_batch_lot <> '' then
    select id into v_batch from fabula.production_batches where batch_lot = p_batch_lot;
    if v_batch is null then raise exception 'Lotto sconosciuto: %', p_batch_lot; end if;
  end if;
  if coalesce(p_source, 'tablet') = 'paper' then
    -- v1.04 (audit D-17): the same sheet line copied twice (the place lost while copying 12 lines). The milk checks are compared by
    -- delivery in log_milk_check, since two tanks can read the same temperature
    if p_cp_code not in ('CCP-MILK-ABX', 'CCP-MILK-TEMP') then
      select h.logged_at, h.source, h.operator into d from fabula.haccp_log h
       where h.control_point_id = cp.id and h.batch_id is not distinct from v_batch and h.measured_value is not distinct from p_value
         and h.logged_at between v_at - interval '2 minutes' and v_at + interval '2 minutes'
       order by h.created_at limit 1;
      if found then
        raise exception using errcode = '22023', message = format('Questa riga del foglio è già nel registro: %s%s, %s alle %s (%s). Passa alla riga successiva.',
          coalesce(cp.ccp_no || ' ', ''), cp.name,
          case when cp.unit = 'esito' then case when p_value = 0 then 'esito ok' else 'esito NON ok' end
               else coalesce(fabula._it_num(p_value), '—') || coalesce(' ' || nullif(cp.unit, ''), '') end,
          to_char(d.logged_at at time zone 'Europe/Rome', 'DD/MM HH24:MI'),
          case when d.source = 'paper' then 'già ricopiata' else 'registrata sul tablet' end || coalesce(' da ' || nullif(d.operator, ''), ''));
      end if;
    end if;
    -- v1.04 (audit D-17): a check on a lot belongs to that lot's working time: from 3 hours before the earliest of its production
    -- day, its start and its parent vat's start (a ricotta lot typed in on the tablet after the fact starts «now»), to 6 hours after
    -- its close
    if v_batch is not null then
      select batch_lot, batch_date, started_at, finished_at, parent_batch_id into b from fabula.production_batches where id = v_batch;
      select started_at into v_parent_start from fabula.production_batches where id = b.parent_batch_id;
      v_lo := least(coalesce(b.started_at, 'infinity'), b.batch_date::timestamp at time zone 'Europe/Rome', coalesce(v_parent_start, 'infinity')) - interval '3 hours';
      v_hi := coalesce(b.finished_at, now()) + interval '6 hours';
      if v_at < v_lo or v_at > v_hi then
        raise exception using errcode = '22023', message = format('Il foglio dice %s, ma il lotto %s è stato avviato %s%s. Un controllo del lotto va dal giorno del lotto (3 ore prima) a 6 ore dopo la chiusura: controlla la data e l''ora sul foglio, o il lotto.',
          to_char(v_at at time zone 'Europe/Rome', 'DD/MM HH24:MI'), b.batch_lot,
          coalesce('il ' || to_char(b.started_at at time zone 'Europe/Rome', 'DD/MM HH24:MI'), 'il ' || to_char(b.batch_date, 'DD/MM')),
          coalesce(' e chiuso il ' || to_char(b.finished_at at time zone 'Europe/Rome', 'DD/MM HH24:MI'), ''));
      end if;
    end if;
  end if;
  select full_name into v_staff from fabula.staff where id = p_staff_id;
  v_op := coalesce(nullif(trim(p_written_by), ''), v_staff); v_op_id := p_staff_id;
  if v_op is distinct from v_staff then v_op_id := (select id from fabula.staff where full_name = v_op and active limit 1); end if;
  if coalesce(p_source, 'tablet') = 'paper' then
    p_action := concat_ws(' · ', nullif(p_action, ''), format('Ricopiata dal foglio cartaceo da %s il %s', coalesce(v_staff, '?'), to_char(now() at time zone 'Europe/Rome', 'DD/MM HH24:MI')));
  end if;
  v_eq := coalesce((select id from fabula.equipment where code = p_equipment_code), cp.equipment_id);
  v_res := fabula.ccp_eval(cp.min_value, cp.max_value, cp.warn_min, cp.warn_max, p_value);
  select code into v_oos from fabula.equipment where id = v_eq and out_of_service;
  if v_oos is not null then
    if v_res = 'ok' then v_res := 'warning'; end if;
    p_action := concat_ws(' · ', nullif(p_action, ''), format('Strumento %s fuori servizio: ripetere la misura con uno strumento verificato', v_oos));
  end if;
  insert into fabula.haccp_log (control_point_id, logged_at, measured_value, result, batch_id, equipment_id, operator, operator_id, corrective_action, source)
  values (cp.id, v_at, p_value, v_res, v_batch, v_eq, v_op, v_op_id, p_action, coalesce(p_source, 'tablet')) returning id into v_log;
  if v_res = 'non_conformity' then
    insert into fabula.non_conformities (severity, description, haccp_log_id, batch_id, lot_number, equipment_id, corrective_action, opened_by_id)
    values (cp.nc_severity,
            format('%s%s: %s %s fuori dal limite critico. Limite: %s', coalesce(cp.ccp_no || ' · ', ''), cp.name, p_value, coalesce(cp.unit, ''), coalesce(cp.critical_limit_it, '')),
            v_log, v_batch, nullif(p_batch_lot, ''), v_eq, p_action, p_staff_id)
    returning id into v_nc;
    if v_batch is not null and cp.is_ccp then
      perform set_config('fabula.hold_ctx', 'on', true);   -- v0.95a: the hold guard lets this update through
      update fabula.production_batches set food_safety_hold = true, hold_at = now(), hold_reason = format('%s fuori limite (%s %s)', coalesce(cp.ccp_no, cp.code), p_value, coalesce(cp.unit, '')), hold_nc_id = v_nc,
             hold_released_at = null, hold_released_by_id = null
      where id = v_batch;
      v_hold := found;
    end if;
  end if;
  return jsonb_build_object('result', v_res, 'haccp_log_id', v_log, 'nc_id', v_nc, 'lot_on_hold', v_hold,
                            'corrective_it', case when v_oos is not null then format('Strumento %s fuori servizio: ripetere la misura con uno strumento verificato. ', v_oos) else '' end || coalesce(case when v_res <> 'ok' then cp.corrective_it end, ''), 'equipment_out_of_service', v_oos, 'limit_it', cp.critical_limit_it, 'ccp', coalesce(cp.ccp_no, cp.code));
end $function$;

create or replace function fabula.log_milk_check(p_milk_intake_id uuid, p_cp_code text, p_value numeric, p_staff_id uuid default null::uuid, p_action text default null::text, p_source text default 'tablet'::text, p_logged_at timestamp with time zone default null::timestamp with time zone, p_written_by text default null::text, p_equipment_code text default null::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'fabula', 'public'
as $function$
declare mi fabula.milk_intake%rowtype; r jsonb; v_reason text; x jsonb; d record;
begin
  perform fabula.require_perm('haccp', 2);
  if p_cp_code not in ('CCP-MILK-ABX', 'CCP-MILK-TEMP') then raise exception 'Questo controllo non è del latte in arrivo: %', p_cp_code using errcode = '22023'; end if;
  select * into mi from fabula.milk_intake where id = p_milk_intake_id;
  if mi.id is null then raise exception 'Consegna di latte non trovata: scegli la consegna dall''elenco' using errcode = '22023'; end if;
  -- v1.04 (audit D-17): the same sheet line copied twice for the same delivery
  if coalesce(p_source, 'tablet') = 'paper' and p_logged_at is not null then
    select h.logged_at, h.source, h.operator into d from fabula.haccp_log h join fabula.haccp_control_points c on c.id = h.control_point_id
     where c.code = p_cp_code and h.milk_intake_id = mi.id and h.measured_value is not distinct from p_value
       and h.logged_at between p_logged_at - interval '2 minutes' and p_logged_at + interval '2 minutes'
     order by h.created_at limit 1;
    if found then
      raise exception using errcode = '22023', message = format('Questa riga del foglio è già nel registro: latte %s, %s alle %s (%s). Passa alla riga successiva.',
        mi.milk_lot,
        case when p_cp_code = 'CCP-MILK-ABX' then case when p_value = 0 then 'antibiotici negativo' else 'antibiotici POSITIVO' end
             else fabula._it_num(p_value) || ' °C' end,
        to_char(d.logged_at at time zone 'Europe/Rome', 'DD/MM HH24:MI'),
        case when d.source = 'paper' then 'già ricopiata' else 'registrata sul tablet' end || coalesce(' da ' || nullif(d.operator, ''), ''));
    end if;
  end if;
  r := fabula.log_ccp(p_cp_code, p_value, coalesce(p_logged_at, now()), p_staff_id, null, p_action, coalesce(p_source, 'tablet'), p_equipment_code, p_written_by);
  update fabula.haccp_log set milk_intake_id = mi.id where id = (r ->> 'haccp_log_id')::uuid;
  if r ->> 'result' = 'non_conformity' then
    v_reason := case p_cp_code when 'CCP-MILK-ABX' then 'test antibiotici POSITIVO'
                else format('temperatura %s °C oltre il limite', fabula._it_num(p_value)) end
                || case when coalesce(p_source, 'tablet') = 'paper' then ' (dal foglio di carta)'
                        when mi.created_at = now() then ' (all''arrivo)' else ' (ricontrollo)' end;
    x := fabula.milk_reject(mi.id, v_reason, p_staff_id, (r ->> 'nc_id')::uuid, p_source);
  end if;
  return r || jsonb_build_object('milk_lot', mi.milk_lot, 'milk_rejected', coalesce((x ->> 'new_reject')::boolean, false) or mi.accepted is false,
                                 'lots_held', coalesce(x -> 'lots_held', '[]'::jsonb));
end $function$;

-- ============================== D-22 / PRINT-04 DDT numbers ==============================
create table if not exists fabula.ddt_counters (
  year       int primary key check (year between 2020 and 2100),
  last_no    int not null default 0 check (last_no >= 0),
  updated_at timestamptz not null default now()
);
comment on table fabula.ddt_counters is 'v1.04 (audit D-22, PRINT-04): the last DDT number issued in each year. Written only by fabula.next_ddt_number(), inside the transaction that creates the shipment, so a refused shipment leaves no gap.';
alter table fabula.ddt_counters enable row level security;
revoke all on fabula.ddt_counters from public, anon, authenticated;
drop policy if exists ddt_counters_read on fabula.ddt_counters;
create policy ddt_counters_read on fabula.ddt_counters for select to authenticated using (fabula.can('spedizioni', 1));
grant select on fabula.ddt_counters to authenticated;

create or replace function fabula.next_ddt_number(p_date date default null) returns text
language plpgsql security definer set search_path = fabula, public as $$
declare v_y int := extract(year from coalesce(p_date, (now() at time zone 'Europe/Rome')::date))::int; n int;
begin
  insert into fabula.ddt_counters as c (year, last_no) values (v_y, 1)
  on conflict (year) do update set last_no = c.last_no + 1, updated_at = now()
  returning c.last_no into n;
  return format('DDT-%s-%s', v_y, lpad(n::text, 4, '0'));
end $$;
revoke all on function fabula.next_ddt_number(date) from public, anon, authenticated;

-- every new shipment gets the next number: packing sends none, the direct shipment from a lot sends none, and whatever a login
-- sends (an older tablet: «DDT-20261014-4821») is replaced, as is the old daily form. A number written by the database's own
-- jobs or tests (no login) in another form is kept.
create or replace function fabula.trg_shipments_ddt_number() returns trigger
language plpgsql security definer set search_path = fabula, public as $$
begin
  if tg_op = 'INSERT' then
    -- a login's shipment is dated today: the date also picks the year of the series (no DDT-2025-… in 2026)
    new.ship_date := case when auth.uid() is not null then (now() at time zone 'Europe/Rome')::date
                          else coalesce(new.ship_date, (now() at time zone 'Europe/Rome')::date) end;
    if new.ddt_number is null or btrim(new.ddt_number) = '' or new.ddt_number ~ '^DDT-[0-9]{8}-[0-9]+$' or auth.uid() is not null then
      new.ddt_number := fabula.next_ddt_number(new.ship_date);
    end if;
  end if;
  return new;
end $$;
revoke all on function fabula.trg_shipments_ddt_number() from public, anon, authenticated;
drop trigger if exists shipments_ddt_number on fabula.shipments;
create trigger shipments_ddt_number before insert on fabula.shipments for each row execute function fabula.trg_shipments_ddt_number();
alter table fabula.shipments alter column ship_date set default ((now() at time zone 'Europe/Rome')::date);

-- a login cannot renumber a DDT or delete a shipment (the series would have a hole); invoker, so it sees who is writing
create or replace function fabula.trg_shipments_ddt_guard() returns trigger
language plpgsql set search_path = fabula, public as $$
begin
  if current_user not in ('authenticated', 'anon') then return case when tg_op = 'DELETE' then old else new end; end if;
  if tg_op = 'DELETE' then
    raise exception using errcode = '42501', message = format('Il DDT %s è già numerato e non si cancella: il numero progressivo resterebbe con un buco. Se è sbagliato, avvisa l''ufficio.', old.ddt_number);
  end if;
  if new.ddt_number is distinct from old.ddt_number then
    raise exception using errcode = '42501', message = format('Il numero del DDT (%s) lo dà il database e non si cambia', old.ddt_number);
  end if;
  if (new.ship_date, new.customer_id, new.sales_order_id) is distinct from (old.ship_date, old.customer_id, old.sales_order_id) then
    raise exception using errcode = '42501', message = format('Data, cliente e ordine del DDT %s non si cambiano dopo l''emissione', old.ddt_number);
  end if;
  return new;
end $$;
drop trigger if exists shipments_ddt_guard on fabula.shipments;
create trigger shipments_ddt_guard before update of ddt_number, ship_date, customer_id, sales_order_id or delete on fabula.shipments for each row execute function fabula.trg_shipments_ddt_guard();

-- ============================== D-22 packing per product ==============================
insert into fabula.settings (key, value, description, data_type, sort, min_value, max_value, unit, impact_it)
values ('ship.max_variance_pct', '30',
        'Oltre questo scostamento in più tra kg pesati e ordinati (per prodotto) la spedizione non parte nemmeno confermando: è quasi sempre una cifra o una virgola sbagliata (50 per 5).',
        'number', 70, 10, 100, '%',
        'Sopra questa percentuale in più il tablet rifiuta la spedizione e chiede di ripesare; tra la tolleranza e questo limite chiede conferma.')
on conflict (key) do nothing;

create or replace function fabula.pack_order(p_order_id uuid, p_lines jsonb, p_staff_id uuid, p_gross_kg numeric default null::numeric, p_carrier text default null::text, p_tracking text default null::text, p_notes text default null::text, p_force boolean default false)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'fabula', 'public'
as $function$
declare o fabula.sales_orders%rowtype; l jsonb; v_ship uuid; v_ddt text; v_on_hand numeric; v_ordered numeric; v_packed numeric := 0; v_tol numeric; v_max numeric; v_var numeric; v_pv numeric; v_carrier text; n int := 0; v_exp date; v_order_total_kg numeric;
        v_today date := (now() at time zone 'Europe/Rome')::date; v_min int; v_reasons jsonb := '[]'; v_held boolean; v_lot_need jsonb := '{}'; v_k text; pp record;
begin
  perform fabula.require_perm('spedizioni', 2);
  -- v1.04 (audit D-22): locked, so two tablets packing the same order at once do not both pass the «già preparato» check
  select * into o from fabula.sales_orders where id = p_order_id for update;
  if o.id is null then raise exception 'Ordine non trovato'; end if;
  if exists (select 1 from fabula.shipments where sales_order_id = p_order_id and status in ('picked','in_transit','delivered')) then raise exception 'Ordine % già preparato', o.order_number; end if;
  if o.status <> 'confirmed' then raise exception 'Ordine % non in stato confermato (%)', o.order_number, o.status; end if;
  if jsonb_array_length(coalesce(p_lines, '[]'::jsonb)) = 0 then raise exception 'Nessuna riga'; end if;
  v_min := fabula.ship_min_days(o.channel::text);
  select coalesce(sum(qty), 0) into v_order_total_kg from fabula.sales_order_lines where sales_order_id = p_order_id and qty > 0;
  for l in select * from jsonb_array_elements(p_lines) loop
    if coalesce((l->>'qty')::numeric, 0) <= 0 then raise exception 'Quantità non valida per il lotto %', l->>'lot_number'; end if;
    select qty_on_hand, expiry_date into v_on_hand, v_exp from fabula.v_stock_on_hand where product_id = (l->>'product_id')::uuid and lot_number = l->>'lot_number';
    if v_on_hand is null then raise exception 'Lotto % non in giacenza per questo prodotto', l->>'lot_number'; end if;
    select food_safety_hold into v_held from fabula.production_batches where batch_lot = l->>'lot_number';
    if coalesce(v_held, false) then raise exception 'Lotto % bloccato per sicurezza alimentare: non si può spedire', l->>'lot_number' using errcode = '23514'; end if;
    if v_exp is not null and v_exp < v_today then raise exception 'Lotto % scaduto il %: non si può spedire', l->>'lot_number', to_char(v_exp, 'DD/MM/YYYY') using errcode = '23514'; end if;
    if v_exp is not null and v_exp < v_today + v_min then
      v_reasons := v_reasons || to_jsonb(format('il lotto %s scade il %s (minimo %s giorni per %s)', l->>'lot_number', to_char(v_exp, 'DD/MM'), v_min, case when o.channel = 'wholesale' then 'l''ingrosso' else 'gli ordini online' end));
    end if;
    -- the same lot on two rows counts once against its stock
    v_k := (l->>'product_id') || '|' || (l->>'lot_number');
    v_lot_need := v_lot_need || jsonb_build_object(v_k, coalesce((v_lot_need->>v_k)::numeric, 0) + (l->>'qty')::numeric);
    if v_on_hand + 0.0005 < (v_lot_need->>v_k)::numeric then
      v_reasons := v_reasons || to_jsonb(format('il lotto %s ha %s kg in giacenza, ne prepari %s', l->>'lot_number', round(v_on_hand, 2), round((v_lot_need->>v_k)::numeric, 2)));
    end if;
    v_packed := v_packed + (l->>'qty')::numeric;
  end loop;
  v_tol := fabula.setting_num('ship.tolerance_pct', 5);
  v_max := greatest(fabula.setting_num('ship.max_variance_pct', 30), v_tol);
  v_var := case when v_order_total_kg > 0 then round((v_packed - v_order_total_kg) / v_order_total_kg * 100, 2) else 0 end;
  -- v1.04 (audit D-22): each product against what was ordered of it (2 kg mozzarella + 1 kg ricotta packed as 3 kg mozzarella is
  -- not «0 %»). Too much of a product is refused even when confirmed; less, or a product left out, is asked (partial shipment).
  for pp in
    with ol as (select product_id, sum(qty) as q from fabula.sales_order_lines where sales_order_id = p_order_id and qty > 0 and product_id is not null group by 1),
         pl as (select (x->>'product_id')::uuid as product_id, sum((x->>'qty')::numeric) as q from jsonb_array_elements(p_lines) x group by 1)
    select coalesce(ol.product_id, pl.product_id) as product_id, coalesce(ol.q, 0) as ordered, coalesce(pl.q, 0) as packed,
           coalesce(pr.name, 'prodotto') as name, coalesce(nullif(pr.unit, ''), 'kg') as unit
      from ol full join pl on pl.product_id = ol.product_id left join fabula.products pr on pr.id = coalesce(ol.product_id, pl.product_id)
     order by pr.name
  loop
    if pp.ordered = 0 then
      raise exception using errcode = '22023', hint = 'weight', message = format('«%s» non è in questo ordine (%s): togli la riga o scegli il prodotto giusto.', pp.name, o.order_number);
    end if;
    v_pv := round((pp.packed - pp.ordered) / pp.ordered * 100, 1);
    if v_pv > v_max then
      raise exception using errcode = '22023', hint = 'weight', message = format('%s: pesati %s %s contro %s ordinati (+%s %%). Oltre il +%s %% non si spedisce, nemmeno confermando: ripesa e controlla la virgola. Se il cliente ne vuole di più, cambia prima l''ordine.',
        pp.name, fabula._it_num(round(pp.packed, 2)), pp.unit, fabula._it_num(round(pp.ordered, 2)), fabula._it_num(v_pv), fabula._it_num(v_max));
    elsif pp.packed = 0 then
      v_reasons := v_reasons || to_jsonb(format('%s non preparato: 0 di %s %s ordinati (spedizione parziale)', pp.name, fabula._it_num(round(pp.ordered, 2)), pp.unit));
    elsif abs(v_pv) > v_tol then
      v_reasons := v_reasons || to_jsonb(format('%s: pesati %s %s contro %s ordinati (%s%s %%)', pp.name, fabula._it_num(round(pp.packed, 2)), pp.unit, fabula._it_num(round(pp.ordered, 2)),
                                                case when v_pv > 0 then '+' else '' end, fabula._it_num(v_pv)));
    end if;
  end loop;
  if jsonb_array_length(v_reasons) > 0 and not p_force then
    return jsonb_build_object('ok', false, 'needs_confirm', true, 'reasons', v_reasons, 'ordered_kg', v_order_total_kg, 'packed_kg', v_packed, 'variance_pct', v_var, 'tolerance_pct', v_tol, 'max_variance_pct', v_max);
  end if;
  -- an online order with no customer (guest checkout, customer not synced yet): the consignee comes from the Shopify
  -- shipping name, so the shipment and its DDT/packing list always have one
  if o.customer_id is null then
    insert into fabula.parties (type, legal_name, notes)
    values ('customer', coalesce(nullif(trim(o.shopify_payload #>> '{shipping_address,name}'), ''), 'Cliente online ' || o.order_number),
            'Creato alla spedizione di ' || o.order_number || ' (ordine senza cliente)')
    returning id into o.customer_id;
    update fabula.sales_orders set customer_id = o.customer_id, updated_at = now() where id = o.id;
  end if;
  v_carrier := coalesce(nullif(p_carrier, ''), case when o.channel = 'wholesale' then fabula.setting_text('ship.wholesale_carrier', 'Consegna diretta') else fabula.setting_text('ship.default_carrier', 'BRT') end);
  -- v1.04 (audit D-22, PRINT-04): the number comes from the yearly series (trigger shipments_ddt_number)
  insert into fabula.shipments (ddt_number, customer_id, sales_order_id, status, ship_date, driver_id, notes, carrier, tracking_number, gross_weight_kg, packed_by_id, packed_at, weight_variance_pct)
  values (null, o.customer_id, o.id, 'picked', v_today, p_staff_id, nullif(concat_ws(' · ', nullif(p_notes, ''), case when jsonb_array_length(v_reasons) > 0 then 'Confermato: ' || (select string_agg(r #>> '{}', '; ') from jsonb_array_elements(v_reasons) r) end), ''),
          v_carrier, nullif(p_tracking, ''), p_gross_kg, p_staff_id, now(), v_var)
  returning id, ddt_number into v_ship, v_ddt;
  for l in select * from jsonb_array_elements(p_lines) loop
    select sum(qty) into v_ordered from fabula.sales_order_lines where sales_order_id = p_order_id and product_id = (l->>'product_id')::uuid;
    select expiry_date into v_exp from fabula.v_stock_on_hand where product_id = (l->>'product_id')::uuid and lot_number = l->>'lot_number';
    insert into fabula.shipment_lines (shipment_id, product_id, lot_number, qty, ordered_qty, weighed) values (v_ship, (l->>'product_id')::uuid, l->>'lot_number', (l->>'qty')::numeric, v_ordered, coalesce((l->>'weighed')::boolean, false));
    insert into fabula.stock_moves (product_id, lot_number, expiry_date, qty, move_type, sales_order_id, reason, source)
    values ((l->>'product_id')::uuid, l->>'lot_number', v_exp, -(l->>'qty')::numeric, 'sale', o.id, 'Spedizione ' || v_ddt || ' · ' || o.order_number, 'tablet');
    update fabula.sales_order_lines set lot_number = coalesce(lot_number, l->>'lot_number') where sales_order_id = o.id and product_id = (l->>'product_id')::uuid;
    n := n + 1;
  end loop;
  if o.channel = 'wholesale' then update fabula.sales_orders set status = 'fulfilled', updated_at = now() where id = o.id; end if;
  return jsonb_build_object('ok', true, 'shipment_id', v_ship, 'ddt_number', v_ddt, 'order_number', o.order_number, 'channel', o.channel, 'lines', n, 'packed_kg', v_packed, 'ordered_kg', v_order_total_kg, 'variance_pct', v_var, 'carrier', v_carrier,
                            'needs_shopify_fulfilment', o.channel = 'shopify', 'confirmed', v_reasons);
end $function$;
