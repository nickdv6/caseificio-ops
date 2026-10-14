-- v1.04a–c for the Supabase dashboard SQL Editor (15/10/2026): database guard rails from the 12/10 audit.
--   v1.04a  D-17 a paper sheet line is not copied twice, and a lot's check must fall in that lot's working time;
--           D-22 / PRINT-04 packing compares each product with the order (more than +30 % is refused), and DDT numbers are one
--           progressive series per year made by the database (DDT-2026-0001…), for packing and the direct shipment from a lot
--   v1.04b  D-26 non-conformities can no longer be quietly rewritten; a «NON conforme» arrival stays so, and its goods are isolated
--           for dosing while the NC is open
--   v1.04c  D-28 bank matching checks direction and double matches; D-31 a task tied to a control point needs its reading;
--           D-33 approvals and purchase orders from a login start «in attesa» / in bozza; no negative PO prices
-- Same files as supabase/migrations/20261014230000_* … 20261014230200_* (built by make_v104_script.py).
-- One transaction: if any step fails nothing changes. It records the three versions in the migration history and refuses a second run.
-- Paste everything, Run, and check the last result shows 20261014230200, 20261014230100 and 20261014230000 at the top.
-- AFTER this: push the site (perla-v71, README «v1.04»).
begin;
do $chk$ begin
  if exists (select 1 from supabase_migrations.schema_migrations where version in ('20261014230000', '20261014230100', '20261014230200')) then
    raise exception 'STOP: v1.04 is already in the migration history — nothing to do';
  end if;
  if (select max(version) from supabase_migrations.schema_migrations) <> '20261014210200' then
    raise exception 'STOP: the live history does not end at 20261014210200 (v103c_lot_label_reprint) — tell Claude before applying';
  end if;
end $chk$;

-- ======================= v104a =======================
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

-- ======================= v104b =======================
-- v1.04b · Audit 12/10/2026, D-26 (rest): non-conformities and arrival checks can no longer be quietly rewritten.
--   (Since v0.96 an NC cannot be deleted and every change is in the Registro; since v0.99 closing needs the corrective action.)
--   * An NC's origin (when and by whom it was opened, its record, lot, batch and machine) never changes from a login; a missing lot,
--     batch or machine can be filled in once.
--   * Severity and description change only with the HACCP manager's level (haccp 3): a floor or office profile adds cause and
--     actions, it cannot turn «critica» into «minore».
--   * A closed NC is frozen (texts, links and the closing date): to change it, the HACCP manager reopens it first (that stays in the
--     Registro). A login's new NC is opened now and open (opening date and closure are not written by hand).
--   * Arrival check (MOD-15): a delivery checked «NON conforme» cannot be re-checked «conforme»; the NC decides what happens to the
--     goods. A delivery checked «conforme» can still be found non-conforming later (new NC). Each check keeps its time and NC.
--   * Goods found non-conforming stay isolated while their NC is open: dosing refuses a lot of that delivery, and asks for the lot
--     when the ingredient has one isolated.

-- ============================== NC edits ==============================
create or replace function fabula.trg_nc_edit_guard() returns trigger
language plpgsql set search_path = fabula, public as $$
-- invoker: the database's own functions (definer) and the bots pass; a login (Autocontrollo page, API) is checked
begin
  if current_user not in ('authenticated', 'anon') or coalesce(current_setting('fabula.correct_ctx', true), '') = 'on' then return new; end if;
  if new.opened_at is distinct from old.opened_at or new.opened_by_id is distinct from old.opened_by_id
     or new.haccp_log_id is distinct from old.haccp_log_id then
    raise exception using errcode = '42501', message = 'Quando e da chi è stata aperta una non conformità, e la registrazione da cui nasce, non si cambiano';
  end if;
  if (old.lot_number is not null and new.lot_number is distinct from old.lot_number)
     or (old.batch_id is not null and new.batch_id is distinct from old.batch_id)
     or (old.equipment_id is not null and new.equipment_id is distinct from old.equipment_id) then
    if fabula.perm_level('haccp') < 3 then
      raise exception using errcode = '42501', message = 'Il lotto o la macchina di una non conformità li cambia solo il responsabile HACCP (si può aggiungere se manca)';
    end if;
  end if;
  -- a closed NC is frozen until the HACCP manager reopens it (the reopening is itself checked by nc_close_guard)
  if old.status = 'closed' and new.status = 'closed'
     and (new.severity, new.description, new.corrective_action, new.root_cause, new.preventive_action, new.lot_number, new.batch_id, new.equipment_id, new.document_id, new.closed_at)
         is distinct from (old.severity, old.description, old.corrective_action, old.root_cause, old.preventive_action, old.lot_number, old.batch_id, old.equipment_id, old.document_id, old.closed_at) then
    raise exception using errcode = '42501', message = format('La non conformità è chiusa%s: per cambiarla il responsabile HACCP la riapre, così resta traccia.', coalesce(' (' || to_char(old.closed_at at time zone 'Europe/Rome', 'DD/MM/YYYY') || ')', ''));
  end if;
  if (new.severity is distinct from old.severity or new.description is distinct from old.description) and fabula.perm_level('haccp') < 3 then
    raise exception using errcode = '42501', message = 'Gravità e descrizione di una non conformità le cambia solo il responsabile HACCP: scrivi quello che serve in «Causa» o «Azione correttiva».';
  end if;
  return new;
end $$;
drop trigger if exists nc_edit_guard on fabula.non_conformities;
create trigger nc_edit_guard before update on fabula.non_conformities for each row execute function fabula.trg_nc_edit_guard();

-- a login's new NC (the API; the tablet's NCs come from the database's own functions) is opened now and open
create or replace function fabula.trg_nc_insert_guard() returns trigger
language plpgsql set search_path = fabula, public as $$
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  new.opened_at := now(); new.status := 'open'; new.closed_at := null; new.closed_by_id := null;
  return new;
end $$;
drop trigger if exists nc_insert_guard on fabula.non_conformities;
create trigger nc_insert_guard before insert on fabula.non_conformities for each row execute function fabula.trg_nc_insert_guard();

-- ============================== arrival checks ==============================
alter table fabula.goods_receipts add column if not exists inspected_at timestamptz;
alter table fabula.goods_receipts add column if not exists inspection_nc_id uuid references fabula.non_conformities(id);
comment on column fabula.goods_receipts.inspection_nc_id is 'v1.04 (audit D-26): the NC opened by a «NON conforme» arrival check; while it is open the goods of this receipt are isolated (dosing refuses them).';

create or replace function fabula.record_receipt_check(p_po_number text, p_ok boolean, p_note text default null::text, p_staff_id uuid default null::uuid, p_ddt text default null::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'fabula', 'public'
as $function$
declare g record; v_nc uuid; v_sup text;
begin
  perform fabula.require_perm('magazzino', 2);
  if p_ok is null then raise exception 'Esito del controllo all''arrivo mancante'; end if;
  if not p_ok and coalesce(trim(p_note), '') = '' then raise exception 'Merce non conforme: scrivi cosa non va (es. confezione rotta, temperatura, etichetta)'; end if;
  select gr.id, gr.inspection_ok, gr.inspection_note, gr.inspected_at, gr.inspection_nc_id, p.legal_name as supplier into g
  from fabula.goods_receipts gr join fabula.purchase_orders po on po.id = gr.purchase_order_id left join fabula.parties p on p.id = po.supplier_id
  where po.po_number = p_po_number and (p_ddt is null or gr.ddt_number is not distinct from p_ddt)
  order by gr.received_at desc limit 1
  for update of gr;
  if g.id is null then raise exception 'Ricevimento non trovato per l''ordine %', p_po_number; end if;
  v_sup := g.supplier;
  -- v1.04 (audit D-26): a «NON conforme» check is not turned into «conforme» by checking again; the NC decides (reso, distruzione…)
  if g.inspection_ok is false then
    if p_ok then
      raise exception using errcode = '22023', message = format('Il ricevimento di %s è già registrato NON conforme%s: «%s». Non si rifà il controllo: la merce resta isolata finché il responsabile HACCP chiude la non conformità.',
        p_po_number, coalesce(' il ' || to_char(g.inspected_at at time zone 'Europe/Rome', 'DD/MM HH24:MI'), ''), coalesce(g.inspection_note, '—'));
    end if;
    return jsonb_build_object('receipt_id', g.id, 'nc_id', g.inspection_nc_id, 'already', true);   -- the same «non conforme» again: nothing new
  end if;
  if g.inspection_ok is true and p_ok then
    return jsonb_build_object('receipt_id', g.id, 'nc_id', null, 'already', true);
  end if;
  -- first check, or a «conforme» delivery found non-conforming later (the earlier check stays in the Registro)
  if not p_ok then
    insert into fabula.non_conformities (severity, description, corrective_action, opened_by_id)
    values ('major', format('MOD-15 · Merce non conforme all''arrivo: ordine %s%s — %s', p_po_number, coalesce(' (' || v_sup || ')', ''), trim(p_note)),
            'Merce isolata con cartello, fornitore avvisato · decidere reso o distruzione', p_staff_id)
    returning id into v_nc;
  end if;
  update fabula.goods_receipts set inspection_ok = p_ok, inspection_note = nullif(trim(p_note), ''), inspected_by_id = p_staff_id, inspected_at = now(),
         inspection_nc_id = coalesce(v_nc, inspection_nc_id)
   where id = g.id;
  return jsonb_build_object('receipt_id', g.id, 'nc_id', v_nc);
end $function$;

-- the isolated goods: a supplier lot received on a «NON conforme» delivery whose NC is still open
create or replace function fabula._lot_quarantine(p_product_id uuid, p_lot text) returns text
language sql stable security definer set search_path = fabula, public as $$
  select format('lotto %s, ordine %s%s', coalesce(l.supplier_lot, '—'), po.po_number, coalesce(': ' || g.inspection_note, ''))
    from fabula.goods_receipt_lines l join fabula.goods_receipts g on g.id = l.receipt_id join fabula.purchase_orders po on po.id = g.purchase_order_id
    join fabula.non_conformities n on n.id = g.inspection_nc_id
   where l.product_id = p_product_id and g.inspection_ok is false and n.status::text <> 'closed'
     and (p_lot is null or upper(btrim(l.supplier_lot)) = upper(btrim(p_lot)))
   order by g.received_at desc limit 1
$$;
revoke all on function fabula._lot_quarantine(uuid, text) from public, anon;
grant execute on function fabula._lot_quarantine(uuid, text) to authenticated;
insert into fabula.security_accepted (key, reason) values
  ('authenticated_security_definer_function_executable:fabula._lot_quarantine(p_product_id uuid, p_lot text)', 'by design (v1.04b, audit D-26): dosing (record_batch_consumable, invoker) asks whether an ingredient lot is isolated; returns only lot, order number and the check note')
on conflict (key) do nothing;

create or replace function fabula.record_batch_consumable(p_batch_lot text, p_sku text, p_qty numeric, p_qty_standard numeric, p_staff_id uuid default null::uuid, p_lot text default null::text, p_confirm boolean default false)
 returns text
 language plpgsql
 set search_path to 'fabula', 'public', 'extensions'
as $function$
declare b record; v_comp uuid; v_name text; v_unit text; v_rec uuid; v_lot text := nullif(upper(trim(coalesce(p_lot, ''))), ''); v_q text;
begin
  select * into b from fabula.production_batches where batch_lot = p_batch_lot;
  select id, name, unit into v_comp, v_name, v_unit from fabula.products where sku = p_sku;
  if b is null or v_comp is null then raise exception 'Lotto o SKU sconosciuto: % / %', p_batch_lot, p_sku using errcode = '22023'; end if;
  -- v0.98 (audit D-19)
  if b.output_kg is not null then
    raise exception 'Il lotto % è già chiuso: i dosaggi si registrano prima della chiusura', p_batch_lot using errcode = '22023';
  end if;
  if p_qty is null or p_qty < 0 then raise exception 'Quantità di % non valida: scrivi la quantità usata (0 se non l''hai messo)', v_name using errcode = '22023'; end if;
  -- v1.04 (audit D-26): goods found non-conforming at arrival stay isolated while their NC is open
  if p_qty > 0 then
    v_q := fabula._lot_quarantine(v_comp, v_lot);
    if v_q is not null and v_lot is not null then
      raise exception using errcode = '22023', message = format('%s, %s: merce NON conforme all''arrivo, è isolata. Usa un''altra confezione o chiama il responsabile HACCP.', v_name, v_q);
    elsif v_q is not null then
      raise exception using errcode = '22023', message = format('%s: c''è merce NON conforme all''arrivo e isolata (%s). Scrivi il lotto della confezione che usi.', v_name, v_q);
    end if;
  end if;
  if coalesce(p_qty_standard, 0) > 0 and not coalesce(p_confirm, false) and (p_qty > p_qty_standard * 3 or p_qty < p_qty_standard / 3) then
    raise exception using errcode = '22023', hint = 'confirm', message = format('%s: %s %s contro %s previsti dalla ricetta. Controlla la virgola; se è giusto conferma.',
      v_name, fabula._it_num(round(p_qty, 4)), v_unit, fabula._it_num(round(p_qty_standard, 4)));
  end if;
  if exists (select 1 from fabula.batch_consumables where batch_id = b.id and product_id = v_comp) then
    perform fabula.correct_batch_consumable(p_batch_lot, p_sku, p_qty, 'riconferma da tablet');
    update fabula.batch_consumables set confirmed_at = now(), confirmed_by_id = coalesce(p_staff_id, confirmed_by_id),
           qty_standard = coalesce(qty_standard, p_qty_standard), lot_number = coalesce(v_lot, lot_number)
     where batch_id = b.id and product_id = v_comp;
    return 'corrected';
  end if;
  select id into v_rec from fabula.recipes
   where finished_product_id = b.product_id and component_product_id = v_comp
     and valid_from <= b.batch_date and (valid_to is null or valid_to >= b.batch_date)
   order by valid_from desc limit 1;
  insert into fabula.batch_consumables (batch_id, product_id, qty, recipe_id, qty_standard, entry, confirmed_at, confirmed_by_id, lot_number)
  values (b.id, v_comp, p_qty, v_rec, p_qty_standard, case when p_qty = p_qty_standard then 'confirmed' else 'corrected' end, now(), p_staff_id, v_lot);
  insert into fabula.stock_moves (product_id, lot_number, qty, move_type, batch_id, source, reason)
  values (v_comp, v_lot, -p_qty, 'production_in', b.id, 'tablet',
          format('Lotto %s: dosato e confermato %s (ricetta %s)', p_batch_lot, p_qty, p_qty_standard));
  return 'recorded';
end $function$;

-- ======================= v104c =======================
-- v1.04c · Audit 12/10/2026, D-28, D-31, D-33.
--   * D-28 Incassi, manual matching: an outgoing payment cannot settle a customer invoice, a wholesale order or a Shopify payout,
--     and an incoming one cannot pay a supplier invoice; an invoice or order already matched to another bank movement (or an invoice
--     already paid) is refused with where it is (an instalment: the other movement is classified «Altro» with a note); a different
--     amount (more than € 0,50) is written in the note, after the note typed by hand.
--   * D-31 A task tied to a control point (cold rooms, valve, chlorine, cleaning, brine…) is closed only when a reading of that point
--     exists for it (from 3 hours before it is due, or that day when it is the only one): a cold-room display check («CAL:CF-01»)
--     no longer ticks «Temperatura cella 1».
--   * D-33 A login inserts an approval request only as «in attesa» (it cannot write one already approved or set to approve itself);
--     a purchase order is created only as draft or awaiting approval and reaches «approvato / inviato / ricevuto» only through the
--     database's own functions (approval, «Invia», receipt); a PO line cannot have a negative price.
--     (create_manual_po already asks for approval below acquisti 3 since v0.99; hold_lot and record_lab_result are definer since v0.93.)

-- ============================== D-28 bank matching ==============================
create or replace function fabula.recon_set_bank(p_bank_tx uuid, p_kind text, p_ref text default null::text, p_note text default null::text)
 returns jsonb
 language plpgsql
 set search_path to 'fabula', 'public'
as $function$
declare b fabula.bank_transactions; v_who uuid := fabula.my_staff_id(); v_kind text := lower(btrim(coalesce(p_kind, ''))); v_note text := nullif(btrim(coalesce(p_note, '')), '');
        p fabula.payment_payouts; v_inv fabula.invoices; v_so fabula.sales_orders; x record;
begin
  if not fabula.can('finanza', 2) then raise exception 'Il tuo profilo non può abbinare gli incassi' using errcode = '42501'; end if;
  select * into b from fabula.bank_transactions where id = p_bank_tx for update;
  if b.id is null then raise exception 'Movimento non trovato'; end if;
  -- undo whatever was there
  update fabula.payment_payouts set bank_tx_id = null, matched_at = null, matched_by = null, match_note = null, updated_at = now() where bank_tx_id = b.id;
  if b.matched_invoice_id is not null then
    update fabula.invoices set status = 'approved', paid_at = null, payment_ref = null, updated_at = now() where id = b.matched_invoice_id and payment_ref = b.external_id and status = 'paid';
  end if;
  update fabula.bank_transactions set match_kind = null, matched_payout_id = null, matched_invoice_id = null, matched_order_id = null, reconciled = false,
         match_note = null, matched_at = null, matched_by = null where id = b.id;
  if v_kind = 'clear' then return jsonb_build_object('id', b.id, 'kind', null); end if;

  if v_kind = 'payout' then
    select * into p from fabula.payment_payouts where id = p_ref;
    if p.id is null then raise exception 'Versamento non trovato'; end if;
    if p.bank_tx_id is not null then raise exception 'Questo versamento è già abbinato a un altro movimento'; end if;
    -- v1.04 (audit D-28): a payout and its bank movement go the same way
    if sign(coalesce(p.net_eur, 0)) <> sign(b.amount_eur) then
      raise exception using errcode = '22023', message = format('Un''%s (%s €) non può essere il versamento Shopify del %s (%s €): scegli un movimento nella stessa direzione.',
        case when b.amount_eur < 0 then 'uscita' else 'entrata' end, fabula._it_num(b.amount_eur), to_char(p.payout_date, 'DD/MM/YYYY'), fabula._it_num(p.net_eur));
    end if;
    update fabula.bank_transactions set match_kind = 'payout', matched_payout_id = p.id, reconciled = true, matched_at = now(), matched_by = v_who,
           match_note = coalesce(v_note, case when p.net_eur <> b.amount_eur then 'Abbinato a mano: importi diversi (' || p.net_eur || ' / ' || b.amount_eur || ')' end) where id = b.id;
    update fabula.payment_payouts set bank_tx_id = b.id, matched_at = now(), matched_by = v_who, match_note = v_note, updated_at = now() where id = p.id;
  elsif v_kind = 'invoice' then
    select * into v_inv from fabula.invoices where id = p_ref::uuid for update;
    if v_inv.id is null then raise exception 'Fattura non trovata'; end if;
    -- v1.04 (audit D-28): the direction must match, and an invoice is settled once
    if v_inv.direction = 'out' and b.amount_eur <= 0 then
      raise exception using errcode = '22023', message = format('Un''uscita (%s €) non può incassare la fattura cliente %s: scegli un''entrata, oppure abbina l''uscita come fornitore o spesa.', fabula._it_num(b.amount_eur), v_inv.invoice_number);
    elsif v_inv.direction = 'in' and b.amount_eur >= 0 then
      raise exception using errcode = '22023', message = format('Un''entrata (%s €) non paga la fattura fornitore %s: scegli un''uscita.', fabula._it_num(b.amount_eur), v_inv.invoice_number);
    end if;
    if v_inv.status::text = 'void' then raise exception using errcode = '22023', message = format('La fattura %s è annullata', v_inv.invoice_number); end if;
    select bt.value_date, bt.amount_eur into x from fabula.bank_transactions bt where bt.matched_invoice_id = v_inv.id and bt.id <> b.id limit 1;
    if found then
      raise exception using errcode = '22023', message = format('La fattura %s è già abbinata al movimento del %s (%s €): togli prima quell''abbinamento. Se è una rata, classifica questo movimento come «Altro» con una nota.', v_inv.invoice_number, to_char(x.value_date, 'DD/MM/YYYY'), fabula._it_num(x.amount_eur));
    end if;
    if v_inv.status::text = 'paid' then
      raise exception using errcode = '22023', message = format('La fattura %s risulta già pagata%s%s.', v_inv.invoice_number, coalesce(' il ' || to_char(v_inv.paid_at, 'DD/MM/YYYY'), ''), coalesce(' (' || nullif(v_inv.payment_ref, '') || ')', ''));
    end if;
    update fabula.bank_transactions set match_kind = 'invoice', matched_invoice_id = v_inv.id, reconciled = true, matched_at = now(), matched_by = v_who,
           match_note = nullif(concat_ws(' · ', v_note, case when abs(abs(b.amount_eur) - coalesce(v_inv.total_eur, 0)) > 0.5
                                              then format('Abbinato a mano: importi diversi (fattura %s €, movimento %s €)', fabula._it_num(v_inv.total_eur), fabula._it_num(b.amount_eur)) end), '')
     where id = b.id;
    update fabula.invoices set status = 'paid', paid_at = b.value_date, payment_ref = b.external_id, updated_at = now() where id = v_inv.id;
  elsif v_kind = 'order' then
    select * into v_so from fabula.sales_orders where id = p_ref::uuid for update;
    if v_so.id is null then raise exception 'Ordine non trovato'; end if;
    if b.amount_eur <= 0 then
      raise exception using errcode = '22023', message = format('Un''uscita (%s €) non può incassare l''ordine %s: scegli un''entrata.', fabula._it_num(b.amount_eur), v_so.order_number);
    end if;
    if v_so.status::text in ('cancelled', 'draft') then raise exception using errcode = '22023', message = format('L''ordine %s è %s: non si incassa', v_so.order_number, case when v_so.status::text = 'draft' then 'una bozza' else 'annullato' end); end if;
    select bt.value_date, bt.amount_eur into x from fabula.bank_transactions bt where bt.matched_order_id = v_so.id and bt.id <> b.id limit 1;
    if found then
      raise exception using errcode = '22023', message = format('L''ordine %s è già abbinato al movimento del %s (%s €): togli prima quell''abbinamento. Se è una rata, classifica questo movimento come «Altro» con una nota.', v_so.order_number, to_char(x.value_date, 'DD/MM/YYYY'), fabula._it_num(x.amount_eur));
    end if;
    update fabula.bank_transactions set match_kind = 'order', matched_order_id = v_so.id, reconciled = true, matched_at = now(), matched_by = v_who,
           match_note = nullif(concat_ws(' · ', v_note, case when abs(b.amount_eur - coalesce(v_so.total_eur, 0)) > 0.5
                                              then format('Abbinato a mano: importi diversi (ordine %s €, movimento %s €)', fabula._it_num(v_so.total_eur), fabula._it_num(b.amount_eur)) end), '')
     where id = b.id;
  elsif v_kind in ('bank_fee', 'cash_deposit', 'transfer', 'expense', 'supplier', 'salary', 'tax', 'other', 'ignore') then
    if v_kind in ('other', 'ignore') and v_note is null then raise exception 'Scrivi una nota: cosa è questo movimento?'; end if;
    update fabula.bank_transactions set match_kind = v_kind, reconciled = true, matched_at = now(), matched_by = v_who, match_note = v_note where id = b.id;
  else
    raise exception 'Tipo di abbinamento sconosciuto: %', p_kind;
  end if;
  return jsonb_build_object('id', b.id, 'kind', v_kind);
end $function$;

-- ============================== D-31 a task needs its record ==============================
create or replace function fabula.close_open_task(p_day date, p_code text default null::text, p_equipment_id uuid default null::uuid, p_control_point_id uuid default null::uuid, p_staff_id uuid default null::uuid, p_scan_event_id uuid default null::uuid, p_at timestamp with time zone default null::timestamp with time zone)
 returns uuid
 language plpgsql
 set search_path to 'fabula', 'public'
as $function$
declare v_id uuid; v_at timestamptz := coalesce(p_at, now()); v_from timestamptz;
begin
  if p_code is null and p_equipment_id is null and p_control_point_id is null then return null; end if;
  if v_at > now() + interval '5 minutes' or v_at < now() - interval '7 days' then v_at := now(); end if;   -- a wrong tablet clock
  v_from := coalesce(p_day, (v_at at time zone 'Europe/Rome')::date)::timestamp at time zone 'Europe/Rome';
  select ti.id into v_id from fabula.task_instances ti join fabula.task_schedules ts on ts.id = ti.schedule_id
   cross join lateral (select count(*) = 1 as single from fabula.task_instances t2 where t2.schedule_id = ti.schedule_id and t2.followup_kind is null
                         and t2.due_at >= v_from and t2.due_at < v_from + interval '1 day') s
   where ti.status in ('due', 'overdue') and ti.followup_kind is null and ti.due_at >= v_from and ti.due_at < v_from + interval '1 day'
     and (p_code is null or ts.code = p_code) and (p_equipment_id is null or ts.equipment_id = p_equipment_id)
     and (p_control_point_id is null or ts.control_point_id = p_control_point_id)
     -- v0.97 (audit A-05): with more than one task of that kind in the day (cold rooms morning and evening) a check closes only one
     -- whose time has come (from 3 hours before it): an extra re-check at 10:00 leaves the evening reading on the list
     and (ti.due_at - interval '3 hours' <= v_at or s.single)
     -- v1.04 (audit D-31): a task tied to a control point is done only if a reading of that point exists for it — not because a
     -- calibration of the same machine (CAL:CF-01) or another scan of it came by
     and (ts.control_point_id is null or exists (
           select 1 from fabula.haccp_log h
            where h.control_point_id = ts.control_point_id
              and h.logged_at >= case when s.single then v_from else greatest(v_from, ti.due_at - interval '3 hours') end
              and h.logged_at < least(v_from + interval '1 day', v_at + interval '5 minutes')))
   order by (v_at between ti.due_at - interval '3 hours' and ti.due_at + interval '6 hours') desc, ti.due_at
   limit 1;
  if v_id is null then return null; end if;
  update fabula.task_instances set status = 'done', completed_at = v_at, completed_by_id = coalesce(p_staff_id, fabula.my_staff_id()),
         scan_event_id = coalesce(p_scan_event_id, scan_event_id)
   where id = v_id;
  return v_id;
end $function$;

-- ============================== D-33 permission levels ==============================
-- approvals: a login writes a request only as «in attesa»; the auto-approval window is set by the database (approvals_auto_rule,
-- which fires after this one: triggers run in name order)
create or replace function fabula.trg_approvals_insert_guard() returns trigger
language plpgsql set search_path = fabula, public as $$
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if new.status::text <> 'pending' then
    raise exception using errcode = '42501', message = 'Una richiesta di approvazione nasce «in attesa»: la decide chi ne ha il livello, da Console → Oggi';
  end if;
  new.decided_by := null; new.decided_at := null; new.decision_note := null; new.auto_approve_at := null; new.auto_rule := null;
  return new;
end $$;
drop trigger if exists approvals_a0_insert_guard on fabula.approvals;
create trigger approvals_a0_insert_guard before insert on fabula.approvals for each row execute function fabula.trg_approvals_insert_guard();

-- purchase orders: created by a login only as draft or awaiting approval; approved / sent / received only through the database's
-- own functions (the approval in Console → Oggi, «Invia», the goods receipt), which run as definer and pass
create or replace function fabula.trg_po_status_guard() returns trigger
language plpgsql set search_path = fabula, public as $$
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if tg_op = 'INSERT' and new.status::text not in ('draft', 'pending_approval') then
    raise exception using errcode = '42501', message = 'Un ordine d''acquisto nasce in bozza o in attesa di approvazione: si approva da Console → Oggi';
  end if;
  if tg_op = 'UPDATE' and new.status is distinct from old.status and new.status::text in ('approved', 'sent', 'partially_received', 'received') then
    raise exception using errcode = '42501', message = format('L''ordine %s diventa «%s» solo dalla sua approvazione, da «Invia al fornitore» o dal ricevimento merce', new.po_number,
      case new.status::text when 'approved' then 'approvato' when 'sent' then 'inviato' else 'ricevuto' end);
  end if;
  return new;
end $$;
drop trigger if exists purchase_orders_status_guard on fabula.purchase_orders;
create trigger purchase_orders_status_guard before insert or update of status on fabula.purchase_orders for each row execute function fabula.trg_po_status_guard();

alter table fabula.purchase_order_lines drop constraint if exists purchase_order_lines_unit_price_check;
alter table fabula.purchase_order_lines add constraint purchase_order_lines_unit_price_check check (unit_price_eur is null or unit_price_eur >= 0) not valid;
alter table fabula.purchase_order_lines validate constraint purchase_order_lines_unit_price_check;
comment on constraint purchase_order_lines_unit_price_check on fabula.purchase_order_lines is 'Il prezzo di una riga d''ordine non può essere negativo';

insert into supabase_migrations.schema_migrations (version, name) values
  ('20261014230000', 'v104a_paper_packing_ddt'),
  ('20261014230100', 'v104b_nc_receipts'),
  ('20261014230200', 'v104c_bank_tasks_perms');
commit;

select version, name from supabase_migrations.schema_migrations order by version desc limit 5;
