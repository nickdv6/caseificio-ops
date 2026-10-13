-- v0.96a · Audit 12/10/2026, Critical items A-04, A-03 (database part), D-02 and D-21.
-- Function bodies are patched in place (pattern must match, otherwise the migration stops and nothing changes).

-- ============================================================================================================================
-- A-04 · A positive antibiotic test (or milk too warm) recorded from the 🛡 menu or the paper copy blocks THAT delivery:
--        the intake is rejected, the farm load is marked rejected, the raw milk left is written off, and every lot already made
--        from it (and its ricotta) is held. Every milk check is linked to its delivery (haccp_log.milk_intake_id).
-- ============================================================================================================================
alter table fabula.haccp_log add column if not exists milk_intake_id uuid references fabula.milk_intake(id);
create index if not exists haccp_log_milk_intake on fabula.haccp_log (milk_intake_id) where milk_intake_id is not null;

-- what happens to a delivery found out of limit (at arrival, on a later check, from paper, or after a correction): the delivery is
-- rejected, the farm load marked rejected, the raw milk left written off, and EVERY lot made from it (and its ricotta) held —
-- a lot already held for another reason (e.g. a missing CCP) gets this reason added, so releasing it for the first reason cannot
-- miss the milk. The office gets one alert (Telegram too, v0.96c).
create or replace function fabula.milk_reject(p_milk_intake_id uuid, p_reason text, p_staff_id uuid default null, p_nc uuid default null,
  p_source text default 'tablet')
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare mi fabula.milk_intake%rowtype; v_held text[] := '{}'; b record; v_raw uuid; v_left numeric; v_new_reject boolean := false;
begin
  select * into mi from fabula.milk_intake where id = p_milk_intake_id;
  if mi.id is null then return null; end if;
  if mi.accepted is not false then
    v_new_reject := true;
    perform set_config('fabula.correct_ctx', 'on', true);
    update fabula.milk_intake set accepted = false, rejection_reason = concat_ws(' · ', nullif(rejection_reason, ''), p_reason) where id = mi.id;
    perform set_config('fabula.correct_ctx', '', true);
    update fabula.milk_shipments set status = 'rejected', milk_intake_id = coalesce(milk_intake_id, mi.id) where id = mi.shipment_id and status in ('shipped', 'received');
    -- the raw milk still in stock from this delivery is written off
    select id into v_raw from fabula.products where sku = 'RAW-MILK';
    select coalesce(sum(qty), 0) into v_left from fabula.stock_moves where product_id = v_raw and lot_number = mi.milk_lot;
    if v_raw is not null and v_left > 0 then
      insert into fabula.stock_moves (product_id, lot_number, qty, move_type, reason, source)
      values (v_raw, mi.milk_lot, -v_left, 'waste', 'Latte respinto: ' || p_reason, coalesce(p_source, 'tablet'));
    end if;
  end if;
  for b in select pb.id, pb.batch_lot, pb.food_safety_hold from fabula.production_batches pb
            where pb.id in (select batch_id from fabula.batch_milk_inputs where milk_intake_id = mi.id)
               or pb.parent_batch_id in (select batch_id from fabula.batch_milk_inputs where milk_intake_id = mi.id)
            order by pb.batch_lot loop
    perform set_config('fabula.hold_ctx', 'on', true);
    update fabula.production_batches
       set food_safety_hold = true, hold_at = case when food_safety_hold then hold_at else now() end,
           hold_reason = case when food_safety_hold and coalesce(hold_reason, '') <> '' and position(format('Latte %s', mi.milk_lot) in hold_reason) = 0
                              then hold_reason || ' · ' || format('Latte %s: %s', mi.milk_lot, p_reason)
                              when food_safety_hold and position(format('Latte %s', mi.milk_lot) in coalesce(hold_reason, '')) > 0 then hold_reason
                              else format('Latte %s: %s', mi.milk_lot, p_reason) end,
           hold_nc_id = coalesce(p_nc, hold_nc_id), hold_released_at = null, hold_released_by_id = null
     where id = b.id;
    perform set_config('fabula.hold_ctx', '', true);
    v_held := v_held || b.batch_lot;
  end loop;
  perform fabula.post_bot_message('produzione', 'alert',
    left(format('Latte %s respinto: %s', mi.milk_lot, p_reason), 70),
    format(E'**Da fare**\n1. Isola il latte %s (%s kg) e non usarlo\n2. %s\n3. Avvisa la Masseria e il responsabile HACCP (Autocontrollo → Non conformità)\n\n**In breve**\n- %s\n- Consegna del %s · DDT %s\n\nEN — Milk %s was rejected (%s); %s.',
           mi.milk_lot, fabula._it_num(mi.qty_kg),
           case when cardinality(v_held) > 0 then '⚠ Lotti fatti con questo latte BLOCCATI: ' || array_to_string(v_held, ', ') || ' (non vendere; lo sblocco vale anche per il latte)' else 'Nessun lotto è stato fatto con questo latte' end,
           p_reason, fabula._it_d(mi.intake_date), coalesce(mi.ddt_number, '—'),
           mi.milk_lot, p_reason, case when cardinality(v_held) > 0 then 'lots held: ' || array_to_string(v_held, ', ') else 'no lots made from it' end));
  return jsonb_build_object('milk_lot', mi.milk_lot, 'new_reject', v_new_reject, 'lots_held', to_jsonb(v_held));
end $$;
revoke all on function fabula.milk_reject(uuid,text,uuid,uuid,text) from public, anon, authenticated;
grant execute on function fabula.milk_reject(uuid,text,uuid,uuid,text) to service_role;

create or replace function fabula.log_milk_check(p_milk_intake_id uuid, p_cp_code text, p_value numeric, p_staff_id uuid default null,
  p_action text default null, p_source text default 'tablet', p_logged_at timestamptz default null, p_written_by text default null,
  p_equipment_code text default null)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare mi fabula.milk_intake%rowtype; r jsonb; v_reason text; x jsonb;
begin
  perform fabula.require_perm('haccp', 2);
  if p_cp_code not in ('CCP-MILK-ABX', 'CCP-MILK-TEMP') then raise exception 'Questo controllo non è del latte in arrivo: %', p_cp_code using errcode = '22023'; end if;
  select * into mi from fabula.milk_intake where id = p_milk_intake_id;
  if mi.id is null then raise exception 'Consegna di latte non trovata: scegli la consegna dall''elenco' using errcode = '22023'; end if;
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
end $$;
revoke execute on function fabula.log_milk_check(uuid,text,numeric,uuid,text,text,timestamptz,text,text) from public, anon;
grant execute on function fabula.log_milk_check(uuid,text,numeric,uuid,text,text,timestamptz,text,text) to authenticated, service_role;

-- the tablet's offline queue may call it (atomic save with the intake it belongs to)
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.save_ops(jsonb,uuid)'::regprocedure);
  n := replace(d, $s$'log_batch_step','record_batch_consumable'];$s$, $s$'log_batch_step','record_batch_consumable','log_milk_check'];$s$);
  if n = d then raise exception 'v096a: save_ops rpc list not found'; end if;
  execute n;
end $mig$;

-- the milk register (MOD-01) uses the explicit link; the old "within 20 minutes" match stays only for checks without a link
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.haccp_register(text,date,date)'::regprocedure);
  n := replace(d, $s$                       where c.code = 'CCP-MILK-TEMP' and l.logged_at between mi.created_at - interval '20 minutes' and mi.created_at + interval '20 minutes'
                       order by abs(extract(epoch from l.logged_at - mi.created_at)) limit 1) t on true$s$,
                  $s$                       where c.code = 'CCP-MILK-TEMP' and (l.milk_intake_id = mi.id or (l.milk_intake_id is null and l.logged_at between mi.created_at - interval '20 minutes' and mi.created_at + interval '20 minutes'))
                       order by (l.result = 'non_conformity') desc, (l.milk_intake_id = mi.id) desc nulls last, abs(extract(epoch from l.logged_at - mi.created_at)) limit 1) t on true$s$);
  n := replace(n, $s$                       where c.code = 'CCP-MILK-ABX' and l.logged_at between mi.created_at - interval '20 minutes' and mi.created_at + interval '20 minutes'
                       order by abs(extract(epoch from l.logged_at - mi.created_at)) limit 1) a on true$s$,
                  $s$                       where c.code = 'CCP-MILK-ABX' and (l.milk_intake_id = mi.id or (l.milk_intake_id is null and l.logged_at between mi.created_at - interval '20 minutes' and mi.created_at + interval '20 minutes'))
                       order by l.measured_value desc nulls last, (l.milk_intake_id = mi.id) desc nulls last, abs(extract(epoch from l.logged_at - mi.created_at)) limit 1) a on true$s$);
  if position('l.milk_intake_id = mi.id or' in n) = 0 or (length(n) - length(replace(n, 'l.milk_intake_id = mi.id or', ''))) <> 2 * length('l.milk_intake_id = mi.id or') then
    raise exception 'v096a: haccp_register milk patterns not found';
  end if;
  execute n;
end $mig$;

-- ============================================================================================================================
-- A-03 · A lot closed without a CCP is HELD (it used to be only a message in the Bot feed): it cannot be packed or sold until the
--        HACCP manager releases it. The tablet now also asks every missing CCP at close (CCP 2 and CCP 3 for mozzarella).
-- ============================================================================================================================
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.trg_batch_ccp_check()'::regprocedure);
  n := replace(d, $s$  if cardinality(v_missing) > 0 and coalesce(new.source, '') not in ('simulation', 'test') then
$s$, $s$  if cardinality(v_missing) > 0 and coalesce(new.source, '') not in ('simulation', 'test') then
    -- v0.96a (audit A-03): the lot is held until the HACCP manager releases it (Autocontrollo → Lotti bloccati)
    perform set_config('fabula.hold_ctx', 'on', true);
    update fabula.production_batches set food_safety_hold = true, hold_at = now(), hold_released_at = null, hold_released_by_id = null,
           hold_reason = 'CCP mancante alla chiusura: ' || array_to_string(v_missing, ', ')
     where id = new.id and not food_safety_hold;
    perform set_config('fabula.hold_ctx', '', true);
$s$);
  n := replace(n, $s$Se non è stata fatta, il lotto va valutato con il responsabile HACCP prima della vendita.$s$,
                  $s$Il lotto è BLOCCATO: non si confeziona e non si vende finché il responsabile HACCP non lo sblocca (Autocontrollo → Lotti bloccati), dopo aver ricopiato la misura o valutato il lotto.$s$);
  if position('CCP mancante alla chiusura' in n) = 0 or position('Il lotto è BLOCCATO' in n) = 0 then raise exception 'v096a: trg_batch_ccp_check patterns not found'; end if;
  execute n;
end $mig$;

-- ============================================================================================================================
-- D-02 · HACCP and traceability records are not edited or deleted from the app: a correction is a signed entry with a reason
--        (correct_record), the original value stays readable (correction_note, record_corrections, audit log) and prints on the
--        register. Changes from the SQL editor / service role are still possible and are written to the audit log.
-- D-21 · A closed batch cannot be closed again (or its kg changed) except through a correction.
-- ============================================================================================================================
create table if not exists fabula.record_corrections (
  id            uuid primary key default gen_random_uuid(),
  table_name    text not null,
  row_id        uuid not null,
  changes       jsonb not null,              -- {"field": [old, new], …}
  reason        text not null,
  corrected_by_id uuid references fabula.staff(id),
  corrected_by  text,
  corrected_at  timestamptz not null default now());
create index if not exists record_corrections_row on fabula.record_corrections (table_name, row_id);
alter table fabula.record_corrections enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'fabula' and tablename = 'record_corrections' and policyname = 'record_corrections_read') then
    create policy record_corrections_read on fabula.record_corrections for select to authenticated using (true);
  end if;
end $$;
grant select on fabula.record_corrections to authenticated; grant all on fabula.record_corrections to service_role;

alter table fabula.haccp_log add column if not exists correction_note text;
alter table fabula.milk_intake add column if not exists correction_note text;

-- the lock: app users (authenticated/anon) cannot UPDATE or DELETE a record; SECURITY DEFINER functions (which check the
-- caller's permission themselves) and correct_record (fabula.correct_ctx) can
create or replace function fabula.trg_record_lock() returns trigger language plpgsql set search_path = fabula, public as $$
begin
  if current_user not in ('authenticated', 'anon') or coalesce(current_setting('fabula.correct_ctx', true), '') = 'on' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  raise exception '%', case when tg_op = 'DELETE'
      then 'Le registrazioni HACCP e di tracciabilità non si cancellano. Se è sbagliata, correggila con il motivo (Autocontrollo → Registro → Correggi): resta traccia dell''originale.'
      else 'Le registrazioni HACCP e di tracciabilità non si modificano direttamente. Usa «Correggi» con il motivo (Autocontrollo → Registro): resta traccia dell''originale.' end
    using errcode = '42501';
end $$;
do $$ declare t text; begin
  foreach t in array array['haccp_log','milk_intake','batch_milk_inputs','stock_moves','labels','goods_receipts','lab_samples'] loop
    execute format('drop trigger if exists %I on fabula.%I', t || '_lock', t);
    execute format('create trigger %I before update or delete on fabula.%I for each row execute function fabula.trg_record_lock()', t || '_lock', t);
  end loop;
  foreach t in array array['non_conformities','production_batches'] loop      -- updated by the app (close an NC, a batch in progress), never deleted
    execute format('drop trigger if exists %I on fabula.%I', t || '_lock', t);
    execute format('create trigger %I before delete on fabula.%I for each row execute function fabula.trg_record_lock()', t || '_lock', t);
  end loop;
end $$;

-- every change to these tables goes to the audit log (inserts are the records themselves)
drop trigger if exists production_batches_hold_audit on fabula.production_batches;
do $$ declare t text; begin
  foreach t in array array['haccp_log','milk_intake','batch_milk_inputs','stock_moves','labels','goods_receipts','non_conformities','production_batches'] loop
    execute format('drop trigger if exists %I on fabula.%I', t || '_audit', t);
    execute format('create trigger %I after update or delete on fabula.%I for each row execute function fabula.trg_audit()', t || '_audit', t);
  end loop;
end $$;

-- a closed batch: only whey (ricotta started later), notes and the hold columns change from the app (D-21: no second close)
create or replace function fabula.trg_batch_closed_guard() returns trigger language plpgsql set search_path = fabula, public as $$
declare v_free constant text[] := array['whey_kg','notes','updated_at','food_safety_hold','hold_reason','hold_nc_id','hold_released_at',
                                         'hold_released_by_id','hold_at','yield_expected_pct','yield_flag',
                                         'yield_pct'];   -- generated: NULL in NEW inside a BEFORE trigger
        o jsonb; n jsonb; k text;
begin
  if old.output_kg is null or current_user not in ('authenticated', 'anon') or coalesce(current_setting('fabula.correct_ctx', true), '') = 'on' then return new; end if;
  o := to_jsonb(old); n := to_jsonb(new);
  foreach k in array v_free loop o := o - k; n := n - k; end loop;
  if o is distinct from n then
    raise exception 'Il lotto % è già stato chiuso alle % con % kg. Per correggerlo: Autocontrollo → Registro → Correggi (con il motivo).',
      old.batch_lot, coalesce(to_char(old.finished_at at time zone 'Europe/Rome', 'HH24:MI'), '?'), fabula._it_num(old.output_kg) using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists batch_closed_guard on fabula.production_batches;
create trigger batch_closed_guard before update on fabula.production_batches for each row execute function fabula.trg_batch_closed_guard();
do $mig$ declare v text; begin   -- a lot already closed twice (the D-21 symptom) must be sorted out by hand before the guard can go in
  select string_agg(b.batch_lot || ' (' || x.n || ')', ', ') into v
    from (select batch_id, count(*) n from fabula.stock_moves where move_type = 'production_out' and batch_id is not null group by 1 having count(*) > 1) x
    join fabula.production_batches b on b.id = x.batch_id;
  if v is not null then raise exception 'v096a: lotti con più di un carico di produzione (chiusi due volte): % — togliere il carico doppio prima di applicare', v; end if;
end $mig$;
create unique index if not exists stock_moves_one_production_out on fabula.stock_moves (batch_id) where move_type = 'production_out';

-- the tablet's atomic save may only update a batch (its close); every other record is insert-only
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.save_ops(jsonb,uuid)'::regprocedure);
  n := replace(d, E'        if v_op ? ''update'' then\n',
                  E'        if v_op ? ''update'' then\n          if v_t <> ''production_batches'' then raise exception ''Le registrazioni (%) non si modificano: usa «Correggi»'', v_t using errcode = ''42501''; end if;   -- v0.96a (audit D-02)\n');
  if n = d then raise exception 'v096a: save_ops update branch not found'; end if;
  execute n;
end $mig$;

-- correct_lab_result updates lab_samples, now locked: it runs as definer (it checks require_perm itself)
alter function fabula.correct_lab_result(text,text,text,text,text,uuid) security definer;

-- the correction itself
create or replace function fabula.correct_record(p_table text, p_id uuid, p_changes jsonb, p_reason text, p_staff_id uuid default null)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare v_by uuid := coalesce(fabula.my_staff_id(), p_staff_id); v_name text; v_note text; v_diff jsonb := '{}'; v_when text;
        l fabula.haccp_log%rowtype; cp fabula.haccp_control_points%rowtype; mi fabula.milk_intake%rowtype; b fabula.production_batches%rowtype;
        v_new numeric; v_res fabula.haccp_result; v_batch uuid; v_lot text; v_nc uuid; v_raw uuid; v_own boolean; v_milk boolean; v_old_lot text; v_moved boolean;
        k text; allowed text[];
begin
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Scrivi il motivo della correzione (es. errore di battitura)' using errcode = '22023'; end if;
  if p_changes is null or jsonb_typeof(p_changes) <> 'object' or p_changes = '{}'::jsonb then raise exception 'Niente da correggere' using errcode = '22023'; end if;
  allowed := case p_table when 'haccp_log' then array['measured_value','corrective_action','batch_lot']
                          when 'milk_intake' then array['qty_kg','ddt_number','fat_pct','protein_pct','scc_cells_ml']   -- the temperature: through its CCP 1a record
                          when 'production_batches' then array['output_kg','curd_ph','whey_kg']
                          else null end;
  if allowed is null then raise exception 'Questa tabella non si corregge da qui: %', p_table using errcode = '22023'; end if;
  for k in select jsonb_object_keys(p_changes) loop
    if not k = any (allowed) then raise exception 'Campo non correggibile: %', k using errcode = '22023'; end if;
  end loop;
  select full_name into v_name from fabula.staff where id = v_by;
  v_when := to_char(now() at time zone 'Europe/Rome', 'DD/MM HH24:MI');
  perform set_config('fabula.correct_ctx', 'on', true);

  if p_table = 'haccp_log' then
    select * into l from fabula.haccp_log where id = p_id;
    if l.id is null then raise exception 'Registrazione non trovata'; end if;
    select * into cp from fabula.haccp_control_points where id = l.control_point_id;
    -- the person who recorded it may correct it within 15 minutes; afterwards (or for someone else's record) the HACCP manager
    v_own := l.operator_id = v_by and l.created_at > now() - interval '15 minutes';
    perform fabula.require_perm('haccp', case when v_own then 2 else 3 end);
    v_new := case when p_changes ? 'measured_value' then (p_changes ->> 'measured_value')::numeric else l.measured_value end;
    v_batch := l.batch_id;
    if p_changes ? 'batch_lot' then
      v_lot := upper(trim(p_changes ->> 'batch_lot'));
      select id into v_batch from fabula.production_batches where batch_lot = v_lot;
      if v_batch is null then raise exception 'Lotto sconosciuto: %', v_lot using errcode = '22023'; end if;
      v_diff := v_diff || jsonb_build_object('batch_lot', jsonb_build_array((select batch_lot from fabula.production_batches where id = l.batch_id), v_lot));
    end if;
    if p_changes ? 'measured_value' then v_diff := v_diff || jsonb_build_object('measured_value', jsonb_build_array(l.measured_value, v_new)); end if;
    if p_changes ? 'corrective_action' then v_diff := v_diff || jsonb_build_object('corrective_action', jsonb_build_array(l.corrective_action, p_changes ->> 'corrective_action')); end if;
    v_res := fabula.ccp_eval(cp.min_value, cp.max_value, cp.warn_min, cp.warn_max, v_new);
    v_note := concat_ws(' · ', nullif(l.correction_note, ''),
      format('corretto il %s da %s%s: %s', v_when, coalesce(v_name, 'utente'),
             case when p_changes ? 'measured_value' then format(' (prima %s)', coalesce(fabula._it_num(l.measured_value), 'vuoto')) else '' end
             || case when p_changes ? 'batch_lot' then format(' (lotto prima %s)', coalesce((select batch_lot from fabula.production_batches where id = l.batch_id), 'nessuno')) else '' end,
             trim(p_reason)));
    update fabula.haccp_log set measured_value = v_new, result = v_res, batch_id = v_batch,
           corrective_action = case when p_changes ? 'corrective_action' then p_changes ->> 'corrective_action' else corrective_action end,
           correction_note = v_note where id = l.id;
    v_milk := cp.code in ('CCP-MILK-ABX', 'CCP-MILK-TEMP') and l.milk_intake_id is not null;
    v_moved := l.batch_id is distinct from v_batch;
    v_old_lot := (select batch_lot from fabula.production_batches where id = l.batch_id);
    if v_milk and cp.code = 'CCP-MILK-TEMP' and p_changes ? 'measured_value' then   -- the delivery's temperature on MOD-01 follows its CCP 1a record
      update fabula.milk_intake set temperature_c = v_new,
             correction_note = concat_ws(' · ', nullif(correction_note, ''), format('temperatura corretta il %s da %s (prima %s): %s', v_when, coalesce(v_name, 'utente'), coalesce(fabula._it_num(l.measured_value), 'vuoto'), trim(p_reason)))
       where id = l.milk_intake_id;
    end if;
    -- now out of limit and it was not: the same NC and lot hold as a live reading (a milk check: the delivery is rejected, A-04)
    if v_res = 'non_conformity' and l.result is distinct from 'non_conformity' then
      insert into fabula.non_conformities (severity, description, haccp_log_id, batch_id, corrective_action, opened_by_id)
      values (cp.nc_severity, format('%s%s: %s %s fuori dal limite critico (valore corretto il %s, motivo: %s). Limite: %s', coalesce(cp.ccp_no || ' · ', ''), cp.name,
              fabula._it_num(v_new), coalesce(cp.unit, ''), v_when, trim(p_reason), coalesce(cp.critical_limit_it, '')), l.id, v_batch, null, v_by)
      returning id into v_nc;
      if v_milk then
        perform set_config('fabula.correct_ctx', '', true);
        perform fabula.milk_reject(l.milk_intake_id, case cp.code when 'CCP-MILK-ABX' then 'test antibiotici POSITIVO' else format('temperatura %s °C oltre il limite', fabula._it_num(v_new)) end
                                   || ' (corretto)', v_by, v_nc, 'console');
        perform set_config('fabula.correct_ctx', 'on', true);
      end if;
      if v_batch is not null and cp.is_ccp then
        perform set_config('fabula.hold_ctx', 'on', true);
        update fabula.production_batches set food_safety_hold = true, hold_at = now(), hold_reason = format('%s fuori limite (valore corretto)', coalesce(cp.ccp_no, cp.code)),
               hold_nc_id = v_nc, hold_released_at = null, hold_released_by_id = null where id = v_batch;
        perform set_config('fabula.hold_ctx', '', true);
      end if;
    elsif v_res = 'non_conformity' and v_moved and v_batch is not null then
      -- still out of limit, but on another lot: that lot is held too and the NC follows the reading
      update fabula.non_conformities set batch_id = v_batch, lot_number = v_lot where haccp_log_id = l.id;
      if cp.is_ccp then
        perform set_config('fabula.hold_ctx', 'on', true);
        update fabula.production_batches set food_safety_hold = true, hold_at = now(), hold_reason = format('%s fuori limite (lotto corretto da %s)', coalesce(cp.ccp_no, cp.code), coalesce(v_old_lot, '—')),
               hold_nc_id = (select id from fabula.non_conformities where haccp_log_id = l.id order by opened_at desc limit 1), hold_released_at = null, hold_released_by_id = null
         where id = v_batch;
        perform set_config('fabula.hold_ctx', '', true);
      end if;
    elsif l.result = 'non_conformity' and v_res is distinct from 'non_conformity' then
      -- it was an NC and the corrected value is within limits: the NC and any hold stay, for the responsible to close with this note
      update fabula.non_conformities set corrective_action = concat_ws(E'\n', corrective_action,
             format('[%s] valore corretto da %s a %s da %s (%s): valutare la chiusura della NC e lo sblocco del lotto', v_when,
                    fabula._it_num(l.measured_value), fabula._it_num(v_new), coalesce(v_name, 'utente'), trim(p_reason)))
       where haccp_log_id = l.id and status in ('open', 'investigating');
    end if;
    -- the reading moved away from a closed lot that now has no such reading left: that lot is held (A-03)
    if v_moved and l.batch_id is not null and cp.is_ccp
       and exists (select 1 from fabula.production_batches where id = l.batch_id and output_kg is not null)
       and not exists (select 1 from fabula.haccp_log x where x.batch_id = l.batch_id and x.control_point_id = cp.id and x.measured_value is not null and x.id <> l.id) then
      perform set_config('fabula.hold_ctx', 'on', true);
      update fabula.production_batches set food_safety_hold = true, hold_at = now(),
             hold_reason = concat_ws(' · ', case when food_safety_hold then nullif(hold_reason, '') end,
                                     format('CCP mancante: la misura %s è stata spostata sul lotto %s (correzione del %s)', coalesce(cp.ccp_no, cp.code), v_lot, v_when)),
             hold_released_at = null, hold_released_by_id = null
       where id = l.batch_id;
      perform set_config('fabula.hold_ctx', '', true);
    end if;

  elsif p_table = 'milk_intake' then
    select * into mi from fabula.milk_intake where id = p_id;
    if mi.id is null then raise exception 'Consegna non trovata'; end if;
    v_own := mi.received_by_id = v_by and mi.created_at > now() - interval '15 minutes';
    perform fabula.require_perm('produzione', case when v_own then 2 else 3 end);
    for k in select jsonb_object_keys(p_changes) loop
      v_diff := v_diff || jsonb_build_object(k, jsonb_build_array(to_jsonb(mi) -> k, p_changes -> k));
    end loop;
    v_note := concat_ws(' · ', nullif(mi.correction_note, ''), format('corretto il %s da %s (%s): %s', v_when, coalesce(v_name, 'utente'),
                (select string_agg(format('%s %s → %s', k2, coalesce(v_diff -> k2 ->> 0, 'vuoto'), coalesce(v_diff -> k2 ->> 1, 'vuoto')), ', ') from jsonb_object_keys(v_diff) k2), trim(p_reason)));
    update fabula.milk_intake set
           qty_kg = case when p_changes ? 'qty_kg' then (p_changes ->> 'qty_kg')::numeric else qty_kg end,
           temperature_c = case when p_changes ? 'temperature_c' then (p_changes ->> 'temperature_c')::numeric else temperature_c end,
           ddt_number = case when p_changes ? 'ddt_number' then nullif(trim(p_changes ->> 'ddt_number'), '') else ddt_number end,
           fat_pct = case when p_changes ? 'fat_pct' then (p_changes ->> 'fat_pct')::numeric else fat_pct end,
           protein_pct = case when p_changes ? 'protein_pct' then (p_changes ->> 'protein_pct')::numeric else protein_pct end,
           scc_cells_ml = case when p_changes ? 'scc_cells_ml' then (p_changes ->> 'scc_cells_ml')::numeric else scc_cells_ml end,
           correction_note = v_note
     where id = mi.id;
    if p_changes ? 'qty_kg' and (p_changes ->> 'qty_kg')::numeric <> mi.qty_kg and mi.accepted is not false then   -- raw-milk stock follows the corrected kg
      select id into v_raw from fabula.products where sku = 'RAW-MILK';
      if v_raw is not null then
        insert into fabula.stock_moves (product_id, lot_number, qty, move_type, reason, source)
        values (v_raw, mi.milk_lot, (p_changes ->> 'qty_kg')::numeric - mi.qty_kg, 'adjustment', 'Correzione kg consegna: ' || trim(p_reason), 'console');
      end if;
    end if;

  else  -- production_batches (a closed batch)
    select * into b from fabula.production_batches where id = p_id;
    if b.id is null then raise exception 'Lotto non trovato'; end if;
    if b.output_kg is null then raise exception 'Il lotto % è ancora aperto: si chiude dal tablet (Fine lotto), non da qui', b.batch_lot using errcode = '22023'; end if;
    v_own := b.casaro_id = v_by and coalesce(b.finished_at, b.created_at) > now() - interval '15 minutes';
    perform fabula.require_perm('produzione', case when v_own then 2 else 3 end);
    for k in select jsonb_object_keys(p_changes) loop
      v_diff := v_diff || jsonb_build_object(k, jsonb_build_array(to_jsonb(b) -> k, p_changes -> k));
    end loop;
    update fabula.production_batches set
           output_kg = case when p_changes ? 'output_kg' then (p_changes ->> 'output_kg')::numeric else output_kg end,
           curd_ph = case when p_changes ? 'curd_ph' then (p_changes ->> 'curd_ph')::numeric else curd_ph end,
           whey_kg = case when p_changes ? 'whey_kg' then (p_changes ->> 'whey_kg')::numeric else whey_kg end,
           notes = concat_ws(E'\n', notes, format('[%s] corretto da %s (%s): %s', v_when, coalesce(v_name, 'utente'),
                   (select string_agg(format('%s %s → %s', k2, coalesce(v_diff -> k2 ->> 0, 'vuoto'), coalesce(v_diff -> k2 ->> 1, 'vuoto')), ', ') from jsonb_object_keys(v_diff) k2), trim(p_reason)))
     where id = b.id;
    if p_changes ? 'output_kg' and b.output_kg is not null and (p_changes ->> 'output_kg')::numeric <> b.output_kg then   -- the lot's stock follows
      insert into fabula.stock_moves (product_id, lot_number, qty, move_type, batch_id, reason, source)
      values (b.product_id, b.batch_lot, (p_changes ->> 'output_kg')::numeric - b.output_kg, 'adjustment', null, 'Correzione kg prodotti: ' || trim(p_reason), 'console');
    end if;
  end if;

  perform set_config('fabula.correct_ctx', '', true);
  insert into fabula.record_corrections (table_name, row_id, changes, reason, corrected_by_id, corrected_by)
  values (p_table, p_id, v_diff, trim(p_reason), v_by, v_name);
  return jsonb_build_object('ok', true, 'changes', v_diff, 'result', v_res, 'nc_id', v_nc);
end $$;
revoke execute on function fabula.correct_record(text,uuid,jsonb,text,uuid) from public, anon;
grant execute on function fabula.correct_record(text,uuid,jsonb,text,uuid) to authenticated, service_role;

-- the CCP register prints the correction next to the value
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.haccp_register(text,date,date)'::regprocedure);
  n := replace(d, $s$'operatore', coalesce(l.operator, s.full_name, l.source, ''), 'azione', coalesce(l.corrective_action, ''),
             '_ko', l.result = 'non_conformity', '_warn', l.result = 'warning')$s$,
                  $s$'operatore', coalesce(l.operator, s.full_name, l.source, ''), 'azione', concat_ws(' · ', nullif(l.corrective_action, ''), case when l.correction_note is not null then 'CORREZIONE: ' || l.correction_note end),
             '_ko', l.result = 'non_conformity', '_warn', l.result = 'warning' or l.correction_note is not null)$s$);
  n := replace(n, $s$'ddt', coalesce(mi.ddt_number, ''), 'operatore', coalesce(mi.received_by, s.full_name, ''),$s$,
                  $s$'ddt', concat_ws(' · ', coalesce(mi.ddt_number, ''), case when mi.correction_note is not null then 'CORREZIONE: ' || mi.correction_note end), 'operatore', coalesce(mi.received_by, s.full_name, ''),$s$);
  -- batch register (MOD-03): the CCP 3 value with its correction
  n := replace(n, $s$select min(l.measured_value) v, (array_agg(l.result order by l.measured_value))[1] r, count(*) n
$s$, $s$select min(l.measured_value) v, (array_agg(l.result order by l.measured_value))[1] r, count(*) n, string_agg(l.correction_note, ' · ') cn
$s$);
  n := replace(n, $s$'ccp3', fabula._it_num(c3.v),$s$, $s$'ccp3', concat_ws(' · CORREZIONE: ', fabula._it_num(c3.v), c3.cn),$s$);
  if position('CORREZIONE: '' || l.correction_note' in n) = 0 or position('CORREZIONE: '' || mi.correction_note' in n) = 0
     or position('string_agg(l.correction_note' in n) = 0 or position('CORREZIONE: '', fabula._it_num(c3.v), c3.cn)' in n) = 0 then
    raise exception 'v096a: haccp_register correction patterns not found';
  end if;
  execute n;
end $mig$;

-- the four new or changed definer functions check the caller's permission inside: accepted in the evening security check
insert into fabula.security_accepted (key, reason, accepted_at) values
 ('authenticated_security_definer_function_executable:fabula.log_milk_check(p_milk_intake_id uuid, p_cp_code text, p_value numeric, p_staff_id uuid, p_action text, p_source text, p_logged_at timestamp with time zone, p_written_by text, p_equipment_code text)',
  'by design (v0.96a, audit A-04): a milk check rejects the delivery and holds its lots; checks require_perm(haccp, 2) inside', now()),
 ('authenticated_security_definer_function_executable:fabula.correct_record(p_table text, p_id uuid, p_changes jsonb, p_reason text, p_staff_id uuid)',
  'by design (v0.96a, audit D-02): the only way to correct a locked record; checks require_perm (2 own record within 15 min, else 3), reason required, logged', now()),
 ('authenticated_security_definer_function_executable:fabula.correct_lab_result(p_sample_code text, p_outcome text, p_reason text, p_text text, p_report_no text, p_staff_id uuid)',
  'by design (v0.96a, audit D-02/B-02): lab_samples is locked; checks require_perm(haccp, 2) inside, reason required', now())
on conflict (key) do nothing;
