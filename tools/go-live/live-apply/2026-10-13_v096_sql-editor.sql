-- v0.96a–d for the Supabase dashboard SQL Editor (13/10/2026): the remaining Critical items of the 12/10 audit.
--   v0.96a  A-04 a positive milk check blocks that delivery and every lot made from it · A-03 a lot closed without its CCPs is held ·
--           D-02 HACCP and traceability records are locked, «Correggi» with a reason is the only way to change them · D-21 no double close
--   v0.96b  A-01 who is recording on the shared tablet: badge or name + PIN, both identities on every record, badge-in never clocks out
--   v0.96c  E-01 alerts on Telegram (@bubalina_avvisi_bot): outbox, routing by topic, quiet hours, «Me ne occupo io», 30-min reminder
--   v0.96d  FARM-02 the dairy scale weight is kept next to the farm's; over 2 % (with a reason) it is what entered
-- Same files as supabase/migrations/20261013090000_* … 20261013090300_* (built by make_v096_script.py).
-- One transaction: if any step fails nothing changes. It records the four versions in the migration history and refuses a second run.
-- Paste everything, Run, and check the last result shows 20261013090300 … 20261013090000 at the top.
-- AFTER this: deploy the site (the tablet calls the new functions), deploy the edge function `notify` and set its two secrets.
begin;
do $chk$ begin
  if exists (select 1 from supabase_migrations.schema_migrations where version in ('20261013090000', '20261013090100', '20261013090200', '20261013090300')) then
    raise exception 'STOP: v0.96 is already in the migration history — nothing to do';
  end if;
  if (select max(version) from supabase_migrations.schema_migrations) <> '20261013041309' then
    raise exception 'STOP: the live history does not end at 20261013041309 (bubalina_launch_newsletter_utm) — tell Claude before applying';
  end if;
end $chk$;

-- ======================= v096a =======================
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

-- ======================= v096b =======================
-- v0.96b · Audit 12/10/2026, Critical item A-01: who is recording on the shared tablet.
-- The tablet stays logged in on one account all day; the person who records is now the "operator" chosen on the tablet
-- (badge scan, or name + 4-digit PIN; it lapses after 15 minutes idle and at badge-out). Every record carries the operator
-- (p_staff_id, operator_id, received_by_id, casaro_id …, as before) AND the logged-in account (entered_by_id, new).
-- A badge scan no longer toggles: it clocks in only when the person is not on shift; badge-out is a separate, explicit step.

-- ============================================================================================================================
-- 1. PINs: a separate table nobody reads directly (hash only, bcrypt); checked by a function with a lockout
-- ============================================================================================================================
create table if not exists fabula.staff_pins (
  staff_id     uuid primary key references fabula.staff(id) on delete cascade,
  pin_hash     text not null,
  set_at       timestamptz not null default now(),
  set_by_id    uuid references fabula.staff(id),
  failed       int not null default 0,
  locked_until timestamptz
);
alter table fabula.staff_pins enable row level security;
revoke all on fabula.staff_pins from anon, authenticated;
grant all on fabula.staff_pins to service_role;

-- set (or, with p_pin null, remove) a PIN: the person for themselves, or a manager (personale 3) for anyone
create or replace function fabula.staff_set_pin(p_staff_id uuid, p_pin text)
returns jsonb language plpgsql security definer set search_path = fabula, public, extensions as $$
declare s record; v_me uuid := fabula.my_staff_id(); v_pin text := trim(coalesce(p_pin, ''));
begin
  if v_me is null or p_staff_id is distinct from v_me then perform fabula.require_perm('personale', 3); end if;
  select id, full_name, active into s from fabula.staff where id = p_staff_id;
  if s.id is null then raise exception 'Persona sconosciuta' using errcode = 'P0002'; end if;
  if p_pin is null then
    delete from fabula.staff_pins where staff_id = p_staff_id;
    return jsonb_build_object('ok', true, 'staff', s.full_name, 'removed', true);
  end if;
  if v_pin !~ '^[0-9]{4}$' then raise exception 'Il PIN è di 4 cifre (solo numeri)' using errcode = '22023'; end if;
  if v_pin ~ '^(.)\1{3}$' or position(v_pin in '0123456789') > 0 or position(v_pin in '9876543210') > 0 then
    raise exception 'PIN troppo facile da indovinare: evita 4 cifre uguali o in fila (1111, 1234, 4321)' using errcode = '22023';
  end if;
  insert into fabula.staff_pins (staff_id, pin_hash, set_at, set_by_id, failed, locked_until)
  values (p_staff_id, extensions.crypt(v_pin, extensions.gen_salt('bf', 8)), now(), v_me, 0, null)
  on conflict (staff_id) do update set pin_hash = excluded.pin_hash, set_at = now(), set_by_id = v_me, failed = 0, locked_until = null;
  return jsonb_build_object('ok', true, 'staff', s.full_name);
end $$;

-- check a PIN on the floor tablet. Never raises on a wrong PIN (the failure count must be kept): 5 wrong in a row → 15 min lock
create or replace function fabula.operator_pin_check(p_staff_id uuid, p_pin text)
returns jsonb language plpgsql security definer set search_path = fabula, public, extensions as $$
declare s record; p fabula.staff_pins%rowtype; v_fail int;
begin
  perform fabula.require_perm('comune', 2);
  select id, full_name, active into s from fabula.staff where id = p_staff_id;
  if s.id is null or not s.active then return jsonb_build_object('ok', false, 'why', 'unknown'); end if;
  select * into p from fabula.staff_pins where staff_id = p_staff_id for update;
  if p.staff_id is null then return jsonb_build_object('ok', false, 'why', 'no_pin'); end if;
  if p.locked_until > now() then return jsonb_build_object('ok', false, 'why', 'locked', 'until', p.locked_until); end if;
  if p.pin_hash = extensions.crypt(coalesce(p_pin, ''), p.pin_hash) then
    update fabula.staff_pins set failed = 0, locked_until = null where staff_id = p_staff_id;
    return jsonb_build_object('ok', true, 'staff_id', s.id, 'full_name', s.full_name,
      'on_shift', exists (select 1 from fabula.shifts where staff_id = s.id and clock_out is null));
  end if;
  v_fail := p.failed + 1;
  if v_fail >= 5 then
    update fabula.staff_pins set failed = 0, locked_until = now() + interval '15 minutes' where staff_id = p_staff_id;
    return jsonb_build_object('ok', false, 'why', 'locked', 'until', now() + interval '15 minutes');
  end if;
  update fabula.staff_pins set failed = v_fail where staff_id = p_staff_id;
  return jsonb_build_object('ok', false, 'why', 'wrong', 'left', 5 - v_fail);
end $$;

-- the people the tablet can offer as operator (kept on the tablet for offline badge scans): no PIN data, only "has a PIN"
create or replace function fabula.floor_operators()
returns table (id uuid, full_name text, job_role text, badge_code text, has_pin boolean, on_shift boolean, shift_since timestamptz)
language sql stable security definer set search_path = fabula, public as $$
  select s.id, s.full_name, s.role::text, s.badge_code,
         exists (select 1 from fabula.staff_pins p where p.staff_id = s.id),
         sh.clock_in is not null, sh.clock_in
    from fabula.staff s
    left join lateral (select clock_in from fabula.shifts x where x.staff_id = s.id and x.clock_out is null order by x.clock_in desc limit 1) sh on true
   where s.active and fabula.can('comune', 2)
   order by s.full_name
$$;

-- ============================================================================================================================
-- 2. Shifts: badge IN only clocks in (a second scan no longer clocks out by mistake, audit A-25); badge OUT is explicit.
--    Both take the tablet's time (p_at) so a scan queued offline keeps its real time (within the last 12 hours).
-- ============================================================================================================================
create or replace function fabula.badge_in(p_badge text, p_staff_id uuid default null, p_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare v_staff record; v_open record; v_max numeric := fabula.setting_num('labor.max_shift_hours', 12); v_at timestamptz; v_last timestamptz;
begin
  perform fabula.require_perm('comune', 2);
  select * into v_staff from fabula.staff where active and (badge_code = p_badge or id = p_staff_id) limit 1;
  if v_staff is null then raise exception 'Badge sconosciuto o persona disattivata: %', coalesce(p_badge, p_staff_id::text) using errcode = 'P0002'; end if;
  v_at := case when p_at is null or p_at > now() + interval '5 minutes' or p_at < now() - interval '12 hours' then now() else least(p_at, now()) end;
  -- forgotten badge-out: auto-close anything older than max hours before deciding (as toggle_shift)
  update fabula.shifts set clock_out = clock_in + make_interval(hours => v_max::int), notes = coalesce(notes || ' · ', '') || 'chiuso automaticamente (badge dimenticato)'
   where staff_id = v_staff.id and clock_out is null and clock_in < now() - make_interval(hours => v_max::int);
  select * into v_open from fabula.shifts where staff_id = v_staff.id and clock_out is null order by clock_in desc limit 1;
  if v_open.id is not null then
    return jsonb_build_object('action', 'already', 'staff_id', v_staff.id, 'staff', v_staff.full_name, 'since', v_open.clock_in);
  end if;
  select max(clock_out) into v_last from fabula.shifts where staff_id = v_staff.id;
  if v_last > v_at then v_at := v_last; end if;            -- a late offline scan never overlaps a shift already closed
  insert into fabula.shifts (staff_id, clock_in, source, notes)
  values (v_staff.id, v_at, 'tablet', case when v_at < now() - interval '5 minutes' then 'entrata registrata dopo, con l''ora del tablet (senza rete): ' || to_char(now() at time zone 'Europe/Rome', 'DD/MM HH24:MI') end)
  returning * into v_open;
  return jsonb_build_object('action', 'in', 'staff_id', v_staff.id, 'staff', v_staff.full_name, 'at', v_open.clock_in);
end $$;

create or replace function fabula.badge_out(p_badge text, p_staff_id uuid default null, p_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare v_staff record; v_open record; v_at timestamptz;
begin
  perform fabula.require_perm('comune', 2);
  select * into v_staff from fabula.staff where (badge_code = p_badge or id = p_staff_id) limit 1;
  if v_staff is null then raise exception 'Badge sconosciuto: %', coalesce(p_badge, p_staff_id::text) using errcode = 'P0002'; end if;
  select * into v_open from fabula.shifts where staff_id = v_staff.id and clock_out is null order by clock_in desc limit 1;
  if v_open.id is null then return jsonb_build_object('action', 'none', 'staff_id', v_staff.id, 'staff', v_staff.full_name); end if;
  v_at := case when p_at is null or p_at > now() + interval '5 minutes' or p_at < now() - interval '12 hours' then now() else least(p_at, now()) end;
  update fabula.shifts set clock_out = greatest(v_at, clock_in),
         notes = case when v_at < now() - interval '5 minutes' then concat_ws(' · ', notes, 'uscita registrata dopo, con l''ora del tablet (senza rete): ' || to_char(now() at time zone 'Europe/Rome', 'DD/MM HH24:MI')) else notes end
   where id = v_open.id returning * into v_open;
  return jsonb_build_object('action', 'out', 'staff_id', v_staff.id, 'staff', v_staff.full_name, 'at', v_open.clock_out, 'hours', v_open.hours);
end $$;

revoke all on function fabula.staff_set_pin(uuid, text) from public, anon;
revoke all on function fabula.operator_pin_check(uuid, text) from public, anon;
revoke all on function fabula.floor_operators() from public, anon;
revoke all on function fabula.badge_in(text, uuid, timestamptz) from public, anon;
revoke all on function fabula.badge_out(text, uuid, timestamptz) from public, anon;
grant execute on function fabula.staff_set_pin(uuid, text) to authenticated, service_role;
grant execute on function fabula.operator_pin_check(uuid, text) to authenticated, service_role;
grant execute on function fabula.floor_operators() to authenticated, service_role;
grant execute on function fabula.badge_in(text, uuid, timestamptz) to authenticated, service_role;
grant execute on function fabula.badge_out(text, uuid, timestamptz) to authenticated, service_role;

-- the offline queue sends badge scans together with their scan event (one transaction)
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.save_ops(jsonb,uuid)'::regprocedure);
  n := replace(d, $s$'record_batch_consumable','log_milk_check'];$s$, $s$'record_batch_consumable','log_milk_check','badge_in','badge_out'];$s$);
  if n = d then raise exception 'v096b: save_ops rpc list not found'; end if;
  execute n;
end $mig$;

-- ============================================================================================================================
-- 3. Both identities on the legal records: the operator (as before) and the account logged in on the device (new)
-- ============================================================================================================================
alter table fabula.haccp_log          add column if not exists entered_by_id uuid references fabula.staff(id) default fabula.my_staff_id();
alter table fabula.milk_intake        add column if not exists entered_by_id uuid references fabula.staff(id) default fabula.my_staff_id();
alter table fabula.production_batches add column if not exists entered_by_id uuid references fabula.staff(id) default fabula.my_staff_id();
comment on column fabula.haccp_log.entered_by_id is 'v0.96b (A-01): the account logged in on the device that sent the record; operator_id is who did it';
comment on column fabula.milk_intake.entered_by_id is 'v0.96b (A-01): the account logged in on the device; received_by_id is who received the milk';
comment on column fabula.production_batches.entered_by_id is 'v0.96b (A-01): the account logged in on the device; casaro_id is who made the lot';

-- ============================================================================================================================
-- 4. Daily check: tablet records signed by someone who was not clocked in (badge not scanned) in the last 24 hours
-- ============================================================================================================================
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.ops_health_check(date)'::regprocedure);
  n := replace(d, $s$    select 'approvals_stale', $s$,
$s$    select 'operator_off_shift', 'Controlli HACCP registrati dal tablet da chi non risultava in turno (ultime 24 ore): ' ||
           string_agg(x.full_name || ' ' || x.n, ', ') || ' · all''inizio del turno passate il badge sul tablet', sum(x.n)::bigint
      from (select s.full_name, count(*) n from fabula.haccp_log l join fabula.staff s on s.id = l.operator_id
             where l.source = 'tablet' and l.logged_at > now() - interval '24 hours'
               and not exists (select 1 from fabula.shifts sh where sh.staff_id = l.operator_id
                                 and l.logged_at between sh.clock_in - interval '15 minutes' and coalesce(sh.clock_out, now()) + interval '15 minutes')
             group by s.full_name) x having count(*) > 0
    union all
    select 'approvals_stale', $s$);
  if n = d then raise exception 'v096b: ops_health_check anchor not found'; end if;
  execute n;
end $mig$;

-- ============================================================================================================================
-- 5. Accepted in the evening security check
-- ============================================================================================================================
insert into fabula.security_accepted (key, reason, accepted_at) values
 ('rls_enabled_no_policy:fabula.staff_pins', 'by design (v0.96b, audit A-01): PIN hashes are never read by the apps; only staff_set_pin / operator_pin_check / floor_operators reach them', now()),
 ('authenticated_security_definer_function_executable:fabula.staff_set_pin(p_staff_id uuid, p_pin text)',
  'by design (v0.96b, audit A-01): own PIN, or require_perm(personale, 3) for someone else; stores a bcrypt hash only', now()),
 ('authenticated_security_definer_function_executable:fabula.operator_pin_check(p_staff_id uuid, p_pin text)',
  'by design (v0.96b, audit A-01): require_perm(comune, 2); returns ok/wrong only, 5 wrong → 15 min lock', now()),
 ('authenticated_security_definer_function_executable:fabula.floor_operators()',
  'by design (v0.96b, audit A-01): active staff names, badge and shift state for the floor tablet; no PIN data; empty for non-staff', now()),
 ('authenticated_security_definer_function_executable:fabula.badge_in(p_badge text, p_staff_id uuid, p_at timestamp with time zone)',
  'by design (v0.96b, audit A-01/A-25): require_perm(comune, 2); clocks in only if not on shift', now()),
 ('authenticated_security_definer_function_executable:fabula.badge_out(p_badge text, p_staff_id uuid, p_at timestamp with time zone)',
  'by design (v0.96b, audit A-01/A-25): require_perm(comune, 2); closes the open shift', now())
on conflict (key) do nothing;

-- ======================= v096c =======================
-- v0.96c · Audit 12/10/2026, Critical item E-01: food-safety alerts leave the building.
-- Every 'alert' (bot dashboard message or tablet/office notice) becomes one outbox row with a topic:
--   food_safety → whoever subscribed + the HACCP responsible (setting food.responsabile_autocontrollo) + whoever is clocked in,
--                 any hour (no quiet hours);
--   infra       → whoever subscribed (Nick by default), any hour;
--   decisions   → whoever subscribed (owner and partners by default), held until the end of their quiet hours.
-- Telegram (@bubalina_avvisi_bot) delivers it with two buttons: «👀 Ho visto» and «✋ Me ne occupo io». Nobody taking charge within
-- 30 minutes (food safety and decisions) sends a reminder to the owner, the partners and the HACCP responsible too.
-- pg_cron (every minute) escalates and, when something is due, calls the edge function `notify`, which sends and receives the
-- Telegram updates (linking with /start <code>, the buttons). The bot token lives only in the function's secrets.

insert into fabula.settings (key, value, description, data_type) values
  ('notify.telegram_bot', 'bubalina_avvisi_bot', 'Bot Telegram degli avvisi (nome utente, senza @): si aggiorna da solo al primo invio', 'text'),
  ('notify.function_url', 'https://ojkquhzaeypsphncjqwy.supabase.co/functions/v1/notify', 'Indirizzo della funzione che invia gli avvisi Telegram', 'text'),
  ('notify.escalate_min', '30', 'Avvisi Telegram: minuti senza «Me ne occupo io» prima di avvisare anche titolare, soci e responsabile HACCP', 'number')
on conflict (key) do nothing;

-- ============================================================================================================================
-- 1. Tables (no direct access from the apps: only through the functions below)
-- ============================================================================================================================
create table if not exists fabula.notify_targets (
  staff_id     uuid primary key references fabula.staff(id) on delete cascade,
  chat_id      bigint unique,
  tg_name      text,
  topics       text[] not null default '{food_safety}',
  quiet_from   time not null default '22:00',
  quiet_to     time not null default '07:00',
  tz           text not null default 'Europe/Rome',
  link_code    text unique,
  link_expires timestamptz,
  linked_at    timestamptz,
  active       boolean not null default true,
  updated_at   timestamptz not null default now(),
  constraint notify_targets_topics check (topics <@ array['food_safety', 'infra', 'decisions']::text[])
);
create table if not exists fabula.notify_outbox (
  id           uuid primary key default gen_random_uuid(),
  created_at   timestamptz not null default now(),
  topic        text not null check (topic in ('food_safety', 'infra', 'decisions', 'test')),
  title        text not null,
  body         text,
  sender       text,
  source       text,
  source_ref   text,
  dedupe_key   text,
  text_html    text not null,
  parent_id    uuid references fabula.notify_outbox(id) on delete cascade,
  escalate_at  timestamptz,
  escalated_at timestamptz,
  acked_at     timestamptz,
  acked_by_id  uuid references fabula.staff(id)
);
create index if not exists notify_outbox_dedupe on fabula.notify_outbox (dedupe_key, created_at desc);
create index if not exists notify_outbox_escalate on fabula.notify_outbox (escalate_at) where acked_at is null and escalated_at is null;
create table if not exists fabula.notify_deliveries (
  id          uuid primary key default gen_random_uuid(),
  outbox_id   uuid not null references fabula.notify_outbox(id) on delete cascade,
  staff_id    uuid not null references fabula.staff(id) on delete cascade,
  chat_id     bigint not null,
  due_at      timestamptz not null default now(),
  status      text not null default 'queued' check (status in ('queued', 'sending', 'sent', 'failed', 'skipped')),
  attempts    int not null default 0,
  claimed_at  timestamptz,
  sent_at     timestamptz,
  message_id  bigint,
  error       text,
  seen_at     timestamptz,
  unique (outbox_id, staff_id)
);
create index if not exists notify_deliveries_due on fabula.notify_deliveries (due_at) where status in ('queued', 'sending');
alter table fabula.notify_targets enable row level security;
alter table fabula.notify_outbox enable row level security;
alter table fabula.notify_deliveries enable row level security;
revoke all on fabula.notify_targets, fabula.notify_outbox, fabula.notify_deliveries from anon, authenticated;
grant all on fabula.notify_targets, fabula.notify_outbox, fabula.notify_deliveries to service_role;

-- ============================================================================================================================
-- 2. Topic, text, routing
-- ============================================================================================================================
drop function if exists fabula.notify_topic_for(text, text);   -- an earlier draft had two arguments (a call would be ambiguous)
create or replace function fabula.notify_topic_for(p_agent text, p_text text, p_key text default null)
returns text language sql immutable as $$
  select case
    -- infrastructure first: «haccp_nudge non è partito» or «backup bloccato» are about the system, not the food
    when coalesce(p_key, '') ~ '^(bot_|infra_)'
      or p_agent in ('ops_health', 'bot_watchdog', 'bot_heartbeat', 'backup_export', 'restore_drill', 'invite_user', 'predis', 'infra') then 'infra'
    when p_agent = 'tablet' and coalesce(p_text, '') ~* 'rifiutat' then 'food_safety'   -- records lost on the floor: to redo today
    when p_agent = 'tablet' then 'infra'
    when coalesce(p_key, '') ~ '^(lot_guard|lab_lot_unknown)' or p_agent in ('haccp_nudge', 'nc')
      or coalesce(p_text, '') ~* '(⚠|\mCCP|HACCP|respint|lott[oi]\s+(\S+\s+)?bloccat|non conform|richiam|ritiro|antibiotic|fuori limite|sicurezza alimentare|cella frigo|pastorizz|filatura)'
      then 'food_safety'
    else 'decisions' end
$$;

-- Telegram HTML: escape, keep **bold**, cap the length, sender + time + a link to the right page
create or replace function fabula.notify_html(p_topic text, p_title text, p_body text, p_sender text, p_at timestamptz)
returns text language plpgsql stable set search_path = fabula, public as $$
declare v_site text := rtrim(coalesce(nullif(fabula.setting_text('infra.site_url'), ''), ''), '/'); v_b text; v_page text;
begin
  v_b := replace(replace(replace(coalesce(p_body, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
  v_b := regexp_replace(v_b, '\*\*([^*\n]+)\*\*', '<b>\1</b>', 'g');
  if length(v_b) > 3000 then v_b := left(v_b, 3000) || ' …'; end if;
  v_page := case p_topic when 'food_safety' then '/haccp.html' when 'infra' then '/admin.html' else '/console.html' end;
  return concat_ws(E'\n',
    case p_topic when 'food_safety' then '⚠ <b>SICUREZZA ALIMENTARE</b>' when 'infra' then '🔧 <b>Sistema</b>' when 'decisions' then '📌 <b>Da decidere</b>' else '🔔 <b>Prova</b>' end,
    '<b>' || replace(replace(replace(p_title, '&', '&amp;'), '<', '&lt;'), '>', '&gt;') || '</b>',
    nullif(v_b, ''),
    '',
    '<i>' || replace(replace(replace(coalesce(p_sender, 'Caseificio'), '&', '&amp;'), '<', '&lt;'), '>', '&gt;') || ' · ' || to_char(p_at at time zone 'Europe/Rome', 'DD/MM HH24:MI') || '</i>'
      || case when v_site <> '' then ' · <a href="' || v_site || v_page || '">apri</a>' else '' end);
end $$;

-- the end of a recipient's quiet hours (now, when outside them)
create or replace function fabula.notify_due(p_tz text, p_from time, p_to time)
returns timestamptz language plpgsql stable as $$
declare v_local timestamp := now() at time zone coalesce(p_tz, 'Europe/Rome'); v_t time := v_local::time; v_end timestamptz; v_quiet boolean;
begin
  if p_from is null or p_to is null or p_from = p_to then return now(); end if;
  v_quiet := case when p_from < p_to then v_t >= p_from and v_t < p_to else v_t >= p_from or v_t < p_to end;
  if not v_quiet then return now(); end if;
  v_end := (v_local::date + p_to) at time zone coalesce(p_tz, 'Europe/Rome');
  if v_end <= now() then v_end := ((v_local::date + 1) + p_to) at time zone coalesce(p_tz, 'Europe/Rome'); end if;
  return v_end;
end $$;

-- who gets an outbox row. p_wide = the reminder: also owner, partners and the HACCP responsible, whatever they subscribed to
create or replace function fabula.notify_route(p_outbox uuid, p_wide boolean default false)
returns int language plpgsql security definer set search_path = fabula, public as $$
declare o fabula.notify_outbox%rowtype; v_resp text := fabula.setting_text('food.responsabile_autocontrollo'); n int;
begin
  select * into o from fabula.notify_outbox where id = p_outbox;
  if o.id is null or o.topic = 'test' then return 0; end if;
  insert into fabula.notify_deliveries (outbox_id, staff_id, chat_id, due_at)
  select o.id, t.staff_id, t.chat_id,
         case when o.topic in ('food_safety', 'infra') then now() else fabula.notify_due(t.tz, t.quiet_from, t.quiet_to) end   -- only decisions wait (audit E-07)
    from fabula.notify_targets t join fabula.staff s on s.id = t.staff_id
   where t.active and s.active and t.chat_id is not null
     and (o.topic = any (t.topics)
          or (o.topic = 'food_safety' and (s.full_name = v_resp
                                           or exists (select 1 from fabula.shifts sh where sh.staff_id = s.id and sh.clock_out is null)))
          or (p_wide and o.topic in ('food_safety', 'decisions') and (s.app_role in ('titolare', 'socio') or s.full_name = v_resp)))
  on conflict (outbox_id, staff_id) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- one alert in: deduplicated (same key within 3 hours = already sent), routed, escalation set
create or replace function fabula.notify_enqueue(p_topic text, p_title text, p_body text, p_sender text, p_source text default null,
  p_ref text default null, p_dedupe text default null, p_parent uuid default null)
returns uuid language plpgsql security definer set search_path = fabula, public as $$
declare v_id uuid; v_min int := greatest(coalesce(fabula.setting_num('notify.escalate_min', 30), 30)::int, 5);
begin
  if p_dedupe is not null and exists (select 1 from fabula.notify_outbox where dedupe_key = p_dedupe and created_at > now() - interval '3 hours') then
    return null;
  end if;
  insert into fabula.notify_outbox (topic, title, body, sender, source, source_ref, dedupe_key, text_html, parent_id, escalate_at)
  values (p_topic, left(coalesce(nullif(p_title, ''), 'Avviso'), 200), p_body, p_sender, p_source, p_ref, p_dedupe,
          fabula.notify_html(p_topic, coalesce(nullif(p_title, ''), 'Avviso'), p_body, p_sender, now()), p_parent,
          case when p_parent is null and p_topic in ('food_safety', 'decisions') then now() + make_interval(mins => v_min) end)
  returning id into v_id;
  perform fabula.notify_route(v_id, p_parent is not null);
  return v_id;
end $$;

-- ============================================================================================================================
-- 3. Sources: bot dashboard messages and notices with severity 'alert'. A failure here never blocks the original write.
-- ============================================================================================================================
create or replace function fabula.trg_notify_bot_message()
returns trigger language plpgsql security definer set search_path = fabula, public as $$
begin
  if new.severity <> 'alert' or new.title like 'SIMULAZIONE%' or new.notice_key is not null then return null; end if;   -- a notice's copy: sent by notices_notify
  if tg_op = 'UPDATE' and old.severity = 'alert' and old.title is not distinct from new.title and old.body is not distinct from new.body then return null; end if;
  begin
    perform fabula.notify_enqueue(fabula.notify_topic_for(new.agent, new.title || ' ' || coalesce(new.body, '')), new.title, new.body,
                                  fabula.bot_display_name(new.agent), 'bot_messages', new.id::text, 'bm:' || new.agent || ':' || md5(new.title));
  exception when others then raise warning 'notify (bot_messages %): %', new.id, sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists bot_messages_notify on fabula.bot_messages;
create trigger bot_messages_notify after insert or update of severity, title, body on fabula.bot_messages
  for each row execute function fabula.trg_notify_bot_message();

create or replace function fabula.trg_notify_notice()
returns trigger language plpgsql security definer set search_path = fabula, public as $$
declare v_body text;
begin
  if new.severity <> 'alert' or new.resolved_at is not null then return null; end if;
  if tg_op = 'UPDATE' and old.severity = 'alert' and old.resolved_at is null and old.title_it is not distinct from new.title_it then return null; end if;
  begin
    select string_agg('- ' || coalesce(i ->> 'label_it', i ->> 'text', i::text), E'\n') into v_body
      from jsonb_array_elements(case when jsonb_typeof(new.items) = 'array' then new.items else '[]'::jsonb end) i;
    perform fabula.notify_enqueue(fabula.notify_topic_for('notice', new.title_it || ' ' || coalesce(v_body, ''), new.key),
                                  new.title_it, v_body, 'Avviso', 'notices', new.key, 'nt:' || new.key || ':' || md5(new.title_it));
  exception when others then raise warning 'notify (notices %): %', new.key, sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists notices_notify on fabula.notices;
create trigger notices_notify after insert or update of severity, title_it, resolved_at on fabula.notices
  for each row execute function fabula.trg_notify_notice();

-- every non-conformity opened (a CCP out of its critical limit, a lab result, a corrected value) is pushed at once.
-- An NC on a milk check linked to its delivery is left to milk_reject (v0.96a), whose alert («Latte … respinto», with the lots
-- held) says more.
create or replace function fabula.trg_notify_nc()
returns trigger language plpgsql security definer set search_path = fabula, public as $$
declare v_lot text; v_held boolean;
begin
  if exists (select 1 from fabula.haccp_log l join fabula.haccp_control_points c on c.id = l.control_point_id
              where l.id = new.haccp_log_id and l.milk_intake_id is not null and c.code in ('CCP-MILK-ABX', 'CCP-MILK-TEMP')) then return null; end if;
  begin
    select batch_lot, food_safety_hold into v_lot, v_held from fabula.production_batches where id = new.batch_id;
    v_lot := coalesce(v_lot, new.lot_number);
    perform fabula.notify_enqueue('food_safety',
      left('Non conformità · ' || case when v_lot is not null then 'lotto ' || v_lot || case when v_held then ' BLOCCATO' else '' end || ' · ' else '' end
           || split_part(coalesce(new.description, ''), '. Limite', 1), 160),
      concat_ws(E'\n', new.description, case when nullif(new.corrective_action, '') is not null then '**Azione** ' || new.corrective_action end,
                case when v_held then 'Il lotto è bloccato: non si vende finché il responsabile HACCP non lo sblocca.' end,
                'Autocontrollo → Non conformità'),
      'Autocontrollo', 'non_conformities', new.id::text, 'nc:' || new.id);
  exception when others then raise warning 'notify (non_conformities %): %', new.id, sqlerrm;
  end;
  return null;
end $$;
revoke all on function fabula.trg_notify_nc() from public, anon, authenticated;
drop trigger if exists non_conformities_notify on fabula.non_conformities;
-- deferred to the end of the transaction, so the lot hold set right after the NC (same save) is in the message
create constraint trigger non_conformities_notify after insert on fabula.non_conformities deferrable initially deferred
  for each row execute function fabula.trg_notify_nc();

-- ============================================================================================================================
-- 4. Every minute: reminders for alerts nobody took, then wake the sender if something is due
-- ============================================================================================================================
create or replace function fabula.notify_tick()
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare o record; v_rem int := 0; v_due int; v_req bigint;
begin
  for o in select * from fabula.notify_outbox where acked_at is null and escalated_at is null and escalate_at <= now() order by created_at for update skip locked loop
    update fabula.notify_outbox set escalated_at = now() where id = o.id;
    perform fabula.notify_enqueue(o.topic, '⏰ Nessuno se ne occupa da ' || extract(epoch from now() - o.created_at)::int / 60 || ' min: ' || o.title,
                                  o.body, o.sender, o.source, o.source_ref, null, o.id);
    v_rem := v_rem + 1;
  end loop;
  select count(*) into v_due from fabula.notify_deliveries
   where (status = 'queued' and due_at <= now()) or (status = 'sending' and claimed_at < now() - interval '5 minutes' and attempts < 5);
  if v_due > 0 or (coalesce(fabula.setting_text('notify.webhook_url'), '') = '' and extract(minute from now())::int % 10 = 0) then
    select net.http_post(url := fabula.setting_text('notify.function_url'), body := jsonb_build_object('op', 'dispatch'),
                         headers := jsonb_build_object('Content-Type', 'application/json'), timeout_milliseconds := 30000) into v_req;
  end if;
  return jsonb_build_object('reminders', v_rem, 'due', v_due, 'request', v_req);
end $$;

-- ============================================================================================================================
-- 5. Called by the edge function (service role only)
-- ============================================================================================================================
create or replace function fabula.notify_claim(p_limit int default 25)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare r jsonb;
begin
  -- an alert someone already took in the meantime is not sent late (e.g. a decision held overnight)
  update fabula.notify_deliveries d set status = 'skipped', error = 'già preso in carico'
    from fabula.notify_outbox o
   where o.id = d.outbox_id and d.status = 'queued' and d.due_at <= now() and o.topic <> 'test'
     and coalesce(o.acked_at, (select p.acked_at from fabula.notify_outbox p where p.id = o.parent_id)) is not null;
  -- the person unlinked (/stop), changed Telegram, was switched off or deactivated while it waited: not sent
  update fabula.notify_deliveries d set status = 'skipped', error = 'destinatario non più collegato'
   where d.status = 'queued' and d.due_at <= now()
     and not exists (select 1 from fabula.notify_targets t join fabula.staff s on s.id = t.staff_id
                      where t.staff_id = d.staff_id and t.chat_id = d.chat_id and t.active and s.active);
  -- sent 5 times without an answer from the sender: given up, shown as failed (the daily check lists it)
  update fabula.notify_deliveries set status = 'failed', error = coalesce(error, 'nessuna risposta dalla funzione di invio')
   where status = 'sending' and attempts >= 5 and claimed_at < now() - interval '5 minutes';
  with c as (
    select d.id from fabula.notify_deliveries d
     where (d.status = 'queued' and d.due_at <= now()) or (d.status = 'sending' and d.claimed_at < now() - interval '5 minutes' and d.attempts < 5)
     order by d.due_at limit greatest(1, least(p_limit, 100)) for update skip locked),
  u as (update fabula.notify_deliveries d set status = 'sending', claimed_at = now(), attempts = d.attempts + 1 from c where d.id = c.id
        returning d.id, d.chat_id, d.outbox_id)
  select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'chat_id', u.chat_id, 'outbox_id', coalesce(o.parent_id, o.id), 'text', o.text_html,
                                               'buttons', o.topic <> 'test')), '[]')
    into r from u join fabula.notify_outbox o on o.id = u.outbox_id;
  return r;
end $$;

create or replace function fabula.notify_mark(p_id uuid, p_ok boolean, p_message_id bigint default null, p_error text default null)
returns void language plpgsql security definer set search_path = fabula, public as $$
begin
  if p_ok then
    update fabula.notify_deliveries set status = 'sent', sent_at = now(), message_id = p_message_id, error = null where id = p_id;
  else
    update fabula.notify_deliveries
       set status = case when attempts >= 5 or coalesce(p_error, '') ~* '(blocked|chat not found|deactivated|forbidden)' then 'failed' else 'queued' end,
           due_at = now() + make_interval(mins => 2 * attempts), error = left(p_error, 500)
     where id = p_id;
    -- the person blocked the bot or deleted the chat: stop trying, the console shows it as not linked
    update fabula.notify_targets t set chat_id = null, linked_at = null, updated_at = now()
      from fabula.notify_deliveries d where d.id = p_id and t.staff_id = d.staff_id and coalesce(p_error, '') ~* '(blocked|chat not found|deactivated)';
  end if;
end $$;

-- /start <code> in the bot links that Telegram chat to the person who created the code
create or replace function fabula.notify_link(p_code text, p_chat_id bigint, p_tg_name text default null)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare t fabula.notify_targets%rowtype; v_name text;
begin
  select * into t from fabula.notify_targets where link_code = p_code and link_expires > now() for update;
  if t.staff_id is null then return jsonb_build_object('ok', false); end if;
  update fabula.notify_targets set chat_id = null, linked_at = null where chat_id = p_chat_id and staff_id <> t.staff_id;
  update fabula.notify_targets set chat_id = p_chat_id, tg_name = left(p_tg_name, 80), linked_at = now(), link_code = null, link_expires = null,
         active = true, updated_at = now() where staff_id = t.staff_id;
  select full_name into v_name from fabula.staff where id = t.staff_id;
  return jsonb_build_object('ok', true, 'full_name', v_name, 'topics', t.topics, 'quiet_from', to_char(t.quiet_from, 'HH24:MI'), 'quiet_to', to_char(t.quiet_to, 'HH24:MI'));
end $$;

create or replace function fabula.notify_unlink_chat(p_chat_id bigint)
returns boolean language sql security definer set search_path = fabula, public as $$
  with u as (update fabula.notify_targets set chat_id = null, linked_at = null, updated_at = now() where chat_id = p_chat_id returning 1)
  select exists (select 1 from u)
$$;

-- the buttons. «Me ne occupo io» stops the reminder and tells everyone who got the alert (the function edits their messages)
create or replace function fabula.notify_ack(p_chat_id bigint, p_outbox uuid, p_kind text)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare v_staff uuid; v_name text; v_root uuid; r fabula.notify_outbox%rowtype; v_by text; v_edits jsonb;
begin
  select t.staff_id, s.full_name into v_staff, v_name from fabula.notify_targets t join fabula.staff s on s.id = t.staff_id where t.chat_id = p_chat_id;
  if v_staff is null then return jsonb_build_object('ok', false, 'toast', 'Questo Telegram non è più collegato'); end if;
  select coalesce(parent_id, id) into v_root from fabula.notify_outbox where id = p_outbox;
  if v_root is null then return jsonb_build_object('ok', false, 'toast', 'Avviso non trovato'); end if;
  update fabula.notify_deliveries set seen_at = coalesce(seen_at, now())
   where staff_id = v_staff and outbox_id in (select id from fabula.notify_outbox where id = v_root or parent_id = v_root);
  select * into r from fabula.notify_outbox where id = v_root for update;
  if p_kind <> 'take' then return jsonb_build_object('ok', true, 'toast', 'Segnato come visto'); end if;
  if r.acked_at is not null then
    select full_name into v_by from fabula.staff where id = r.acked_by_id;
    return jsonb_build_object('ok', true, 'toast', case when r.acked_by_id = v_staff then 'Te ne occupi già tu' else 'Se ne occupa già ' || coalesce(v_by, '?') end);
  end if;
  update fabula.notify_outbox set acked_at = now(), acked_by_id = v_staff where id = v_root or parent_id = v_root;
  select coalesce(jsonb_agg(jsonb_build_object('chat_id', d.chat_id, 'message_id', d.message_id,
           'text', o.text_html || E'\n\n✋ <b>Se ne occupa ' || replace(replace(v_name, '<', '&lt;'), '>', '&gt;') || '</b> (dalle ' || to_char(now() at time zone 'Europe/Rome', 'HH24:MI') || ')')), '[]')
    into v_edits
    from fabula.notify_deliveries d join fabula.notify_outbox o on o.id = d.outbox_id
   where (o.id = v_root or o.parent_id = v_root) and d.status = 'sent' and d.message_id is not null;
  return jsonb_build_object('ok', true, 'toast', 'Ok: te ne occupi tu. Gli altri lo vedono.', 'edits', v_edits);
end $$;

-- ============================================================================================================================
-- 6. Called from Configurazione → Utenti (logged-in people)
-- ============================================================================================================================
-- a one-time link (24 h) for yourself, or (personale 3) for someone else to open on their phone
create or replace function fabula.notify_link_code(p_staff_id uuid default null)
returns jsonb language plpgsql security definer set search_path = fabula, public, extensions as $$
declare v_me uuid := fabula.my_staff_id(); v_id uuid := coalesce(p_staff_id, fabula.my_staff_id()); v_code text; s record;
begin
  if v_id is null then raise exception 'Persona non trovata' using errcode = 'P0002'; end if;
  if v_me is null or v_id <> v_me then perform fabula.require_perm('personale', 3); end if;
  select id, full_name, app_role, active into s from fabula.staff where id = v_id;
  if not coalesce(s.active, false) then raise exception 'Persona non attiva' using errcode = 'P0002'; end if;
  v_code := encode(extensions.gen_random_bytes(9), 'hex');
  insert into fabula.notify_targets (staff_id, topics, link_code, link_expires)
  values (v_id, case s.app_role when 'titolare' then '{food_safety,infra,decisions}'::text[] when 'socio' then '{food_safety,decisions}'::text[] else '{food_safety}'::text[] end,
          v_code, now() + interval '24 hours')
  on conflict (staff_id) do update set link_code = excluded.link_code, link_expires = excluded.link_expires, updated_at = now();
  if coalesce(fabula.setting_text('notify.webhook_url'), '') = '' then   -- first link ever: let the function register itself with Telegram now
    perform net.http_post(url := fabula.setting_text('notify.function_url'), body := jsonb_build_object('op', 'dispatch'),
                          headers := jsonb_build_object('Content-Type', 'application/json'), timeout_milliseconds := 30000);
  end if;
  return jsonb_build_object('code', v_code, 'url', 'https://t.me/' || fabula.setting_text('notify.telegram_bot') || '?start=' || v_code,
                            'expires', now() + interval '24 hours', 'staff', s.full_name);
end $$;

create or replace function fabula.notify_set_prefs(p_topics text[], p_quiet_from time, p_quiet_to time, p_tz text, p_staff_id uuid default null)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare v_me uuid := fabula.my_staff_id(); v_id uuid := coalesce(p_staff_id, fabula.my_staff_id());
begin
  if v_id is null then raise exception 'Persona non trovata' using errcode = 'P0002'; end if;
  if v_me is null or v_id <> v_me then perform fabula.require_perm('personale', 3); end if;
  if not (coalesce(p_topics, '{}') <@ array['food_safety', 'infra', 'decisions']::text[]) then raise exception 'Argomento sconosciuto' using errcode = '22023'; end if;
  if p_tz is not null and not exists (select 1 from pg_timezone_names where name = p_tz) then raise exception 'Fuso orario sconosciuto: %', p_tz using errcode = '22023'; end if;
  update fabula.notify_targets set topics = coalesce(p_topics, '{}'), quiet_from = coalesce(p_quiet_from, quiet_from), quiet_to = coalesce(p_quiet_to, quiet_to),
         tz = coalesce(p_tz, tz), updated_at = now() where staff_id = v_id;
  if not found then raise exception 'Prima collega Telegram' using errcode = 'P0002'; end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function fabula.notify_unlink(p_staff_id uuid default null)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare v_me uuid := fabula.my_staff_id(); v_id uuid := coalesce(p_staff_id, fabula.my_staff_id());
begin
  if v_me is null or v_id is distinct from v_me then perform fabula.require_perm('personale', 3); end if;
  update fabula.notify_targets set chat_id = null, linked_at = null, tg_name = null, link_code = null, link_expires = null, updated_at = now() where staff_id = v_id;
  return jsonb_build_object('ok', true);
end $$;

-- a test message to yourself (or, personale 3, to someone else) right away
create or replace function fabula.notify_test(p_staff_id uuid default null)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare v_me uuid := fabula.my_staff_id(); v_id uuid := coalesce(p_staff_id, fabula.my_staff_id()); t fabula.notify_targets%rowtype; v_o uuid; v_name text;
begin
  if v_me is null or v_id is distinct from v_me then perform fabula.require_perm('personale', 3); end if;
  select * into t from fabula.notify_targets where staff_id = v_id;
  if t.chat_id is null then raise exception 'Telegram non ancora collegato' using errcode = 'P0002'; end if;
  select full_name into v_name from fabula.staff where id = v_id;
  insert into fabula.notify_outbox (topic, title, body, sender, source, text_html)
  values ('test', 'Messaggio di prova', 'Se lo leggi, gli avvisi arrivano qui.', 'Configurazione',
          'test', fabula.notify_html('test', 'Messaggio di prova per ' || v_name, 'Se lo leggi, gli avvisi del caseificio arrivano qui.', 'Configurazione', now()))
  returning id into v_o;
  insert into fabula.notify_deliveries (outbox_id, staff_id, chat_id) values (v_o, v_id, t.chat_id);
  perform fabula.notify_tick();
  return jsonb_build_object('ok', true);
end $$;

-- own state (anyone logged in) + everybody's state and the last alerts (owner/partners: personale 3)
create or replace function fabula.notify_overview()
returns jsonb language plpgsql stable security definer set search_path = fabula, public as $$
declare v_me uuid := fabula.my_staff_id(); v_all boolean := fabula.can('personale', 3); r jsonb;
begin
  select jsonb_build_object(
    'bot', fabula.setting_text('notify.telegram_bot'),
    'me', (select jsonb_build_object('linked', t.chat_id is not null, 'tg_name', t.tg_name, 'linked_at', t.linked_at, 'topics', t.topics,
                                     'quiet_from', to_char(t.quiet_from, 'HH24:MI'), 'quiet_to', to_char(t.quiet_to, 'HH24:MI'), 'tz', t.tz,
                                     'link_pending', t.link_expires > now())
             from fabula.notify_targets t where t.staff_id = v_me),
    'people', case when v_all then (select coalesce(jsonb_agg(jsonb_build_object('staff_id', s.id, 'full_name', s.full_name, 'app_role', s.app_role,
                 'linked', t.chat_id is not null, 'topics', t.topics, 'tz', t.tz,
                 'haccp_resp', s.full_name = fabula.setting_text('food.responsabile_autocontrollo'),
                 'last_sent', (select max(d.sent_at) from fabula.notify_deliveries d where d.staff_id = s.id),
                 'failed_24h', (select count(*) from fabula.notify_deliveries d where d.staff_id = s.id and d.status = 'failed' and d.due_at > now() - interval '24 hours'))
               order by s.full_name), '[]')
             from fabula.staff s left join fabula.notify_targets t on t.staff_id = s.id where s.active) end,
    'webhook_ok', coalesce(fabula.setting_text('notify.webhook_url'), '') <> '',
    'recent', case when v_all then (select coalesce(jsonb_agg(x order by x.created_at desc), '[]') from (
                 select o.created_at, o.topic, o.title, (select full_name from fabula.staff where id = o.acked_by_id) taken_by, o.acked_at,
                        (select count(*) from fabula.notify_deliveries d where d.outbox_id = o.id and d.status = 'sent') sent,
                        (select count(*) from fabula.notify_deliveries d where d.outbox_id = o.id and d.status in ('queued', 'sending')) waiting,
                        (select count(*) from fabula.notify_deliveries d where d.outbox_id = o.id and d.status = 'failed') failed
                   from fabula.notify_outbox o where o.topic <> 'test' order by o.created_at desc limit 15) x) end)
  into r;
  return r;
end $$;

-- ============================================================================================================================
-- 7. Grants, schedule, daily check, security acceptances
-- ============================================================================================================================
revoke all on function fabula.notify_route(uuid, boolean) from public, anon, authenticated;
revoke all on function fabula.notify_enqueue(text, text, text, text, text, text, text, uuid) from public, anon, authenticated;
revoke all on function fabula.notify_tick() from public, anon, authenticated;
revoke all on function fabula.notify_claim(int) from public, anon, authenticated;
revoke all on function fabula.notify_mark(uuid, boolean, bigint, text) from public, anon, authenticated;
revoke all on function fabula.notify_link(text, bigint, text) from public, anon, authenticated;
revoke all on function fabula.notify_unlink_chat(bigint) from public, anon, authenticated;
revoke all on function fabula.notify_ack(bigint, uuid, text) from public, anon, authenticated;
grant execute on function fabula.notify_route(uuid, boolean), fabula.notify_enqueue(text, text, text, text, text, text, text, uuid), fabula.notify_tick(),
  fabula.notify_claim(int), fabula.notify_mark(uuid, boolean, bigint, text), fabula.notify_link(text, bigint, text), fabula.notify_unlink_chat(bigint),
  fabula.notify_ack(bigint, uuid, text) to service_role;
revoke all on function fabula.notify_link_code(uuid), fabula.notify_set_prefs(text[], time, time, text, uuid), fabula.notify_unlink(uuid),
  fabula.notify_test(uuid), fabula.notify_overview() from public, anon;
grant execute on function fabula.notify_link_code(uuid), fabula.notify_set_prefs(text[], time, time, text, uuid), fabula.notify_unlink(uuid),
  fabula.notify_test(uuid), fabula.notify_overview() to authenticated, service_role;
revoke all on function fabula.trg_notify_bot_message(), fabula.trg_notify_notice() from public, anon, authenticated;

do $mig$ begin
  if exists (select 1 from cron.job where jobname = 'fabula_notify_tick') then perform cron.unschedule('fabula_notify_tick'); end if;
  perform cron.schedule('fabula_notify_tick', '* * * * *', $c$select fabula.notify_tick()$c$);
end $mig$;

-- daily check: alerts that could not be delivered, and nobody linked for food safety
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.ops_health_check(date)'::regprocedure);
  n := replace(d, $s$    select 'approvals_stale', $s$,
$s$    select 'notify_failed', 'Avvisi Telegram non consegnati nelle ultime 24 ore: ' || count(*) || ' · Configurazione → Utenti → Avvisi Telegram', count(*)
      from fabula.notify_deliveries where status = 'failed' and due_at > now() - interval '24 hours' having count(*) > 0
    union all
    select 'notify_stuck', 'Avvisi Telegram fermi da oltre 15 minuti: ' || count(*) || ' · la funzione notify non risponde (secrets? deploy con --no-verify-jwt?)', count(*)
      from fabula.notify_deliveries where status in ('queued', 'sending') and due_at < now() - interval '15 minutes' having count(*) > 0
    union all
    select 'notify_nobody', 'Avvisi di sicurezza alimentare: nessuno ha collegato Telegram (Configurazione → Utenti → Avvisi Telegram)', 1
      where not exists (select 1 from fabula.notify_targets where chat_id is not null and active)
    union all
    select 'approvals_stale', $s$);
  if n = d then raise exception 'v096c: ops_health_check anchor not found'; end if;
  execute n;
end $mig$;

insert into fabula.security_accepted (key, reason, accepted_at) values
 ('rls_enabled_no_policy:fabula.notify_targets', 'by design (v0.96c, audit E-01): reached only through the notify_* functions', now()),
 ('rls_enabled_no_policy:fabula.notify_outbox', 'by design (v0.96c, audit E-01): reached only through the notify_* functions', now()),
 ('rls_enabled_no_policy:fabula.notify_deliveries', 'by design (v0.96c, audit E-01): reached only through the notify_* functions', now()),
 ('authenticated_security_definer_function_executable:fabula.notify_link_code(p_staff_id uuid)',
  'by design (v0.96c, audit E-01): own link, or require_perm(personale, 3) for someone else', now()),
 ('authenticated_security_definer_function_executable:fabula.notify_set_prefs(p_topics text[], p_quiet_from time without time zone, p_quiet_to time without time zone, p_tz text, p_staff_id uuid)',
  'by design (v0.96c, audit E-01): own settings, or require_perm(personale, 3)', now()),
 ('authenticated_security_definer_function_executable:fabula.notify_unlink(p_staff_id uuid)',
  'by design (v0.96c, audit E-01): own link, or require_perm(personale, 3)', now()),
 ('authenticated_security_definer_function_executable:fabula.notify_test(p_staff_id uuid)',
  'by design (v0.96c, audit E-01): a test message to own Telegram, or require_perm(personale, 3)', now()),
 ('authenticated_security_definer_function_executable:fabula.notify_overview()',
  'by design (v0.96c, audit E-01): own state for everyone; people and recent alerts only with personale 3', now())
on conflict (key) do nothing;

-- ======================= v096d =======================
-- v0.96d · Audit 12/10/2026, Critical item FARM-02 (part 2): the dairy's scale weight is no longer thrown away.
-- A delivery confirmed from a farm shipment keeps both weights: farm_kg (what the Masseria wrote) and dairy_kg (the reception
-- scale, BIL-01). Within the tolerance (setting milk.weight_tolerance_pct, 2 %) the farm's figure stays the one that counts.
-- Beyond it, a reason is required, the dairy's weight becomes qty_kg (stock, production, the farm's monthly total), the office
-- gets a notice and the farm sees the weighed kg and the reason on its page.

insert into fabula.settings (key, value, description, data_type) values
  ('milk.weight_tolerance_pct', '2', 'Arrivo latte: differenza massima (%) tra i kg della Masseria e quelli pesati qui senza dover scrivere il motivo; oltre, vale il peso del caseificio', 'number')
on conflict (key) do nothing;

alter table fabula.milk_intake add column if not exists farm_kg numeric(10,3);
alter table fabula.milk_intake add column if not exists dairy_kg numeric(10,3);
alter table fabula.milk_intake add column if not exists weight_note text;
comment on column fabula.milk_intake.farm_kg is 'v0.96d (FARM-02): kg written by the Masseria on its shipment';
comment on column fabula.milk_intake.dairy_kg is 'v0.96d (FARM-02): kg weighed at reception (BIL-01); qty_kg = dairy_kg when the difference is over the tolerance';
comment on column fabula.milk_intake.weight_note is 'v0.96d (FARM-02): why the two weights differ (required over the tolerance)';
do $mig$ begin
  if not exists (select 1 from pg_constraint where conname = 'milk_intake_dairy_kg_chk') then
    alter table fabula.milk_intake add constraint milk_intake_dairy_kg_chk check (dairy_kg is null or (dairy_kg > 0 and dairy_kg < 20000));
  end if;
end $mig$;

do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.milk_intake_shipment_check()'::regprocedure);
  n := replace(d, $s$  new.qty_kg := s.kg; new.milk_lot := s.milk_lot;$s$,
$s$  new.milk_lot := s.milk_lot; new.farm_kg := s.kg;
  -- v0.96d (audit FARM-02): the dairy's own scale reading stays next to the farm's; beyond the tolerance (with a reason) it is what entered
  if new.dairy_kg is not null and s.kg > 0
     and abs(new.dairy_kg - s.kg) > s.kg * coalesce(fabula.setting_num('milk.weight_tolerance_pct', 2), 2) / 100 then
    if coalesce(trim(new.weight_note), '') = '' then
      raise exception 'Pesato qui % kg, la Masseria ha scritto % kg (% %%): scrivi il motivo della differenza',
        replace(to_char(new.dairy_kg, 'FM999990.0'), '.', ','), replace(to_char(s.kg, 'FM999990.0'), '.', ','),
        replace(to_char(round((new.dairy_kg - s.kg) / s.kg * 100, 1), 'FMSG9990.0'), '.', ',') using errcode = '23514';
    end if;
    new.qty_kg := new.dairy_kg;
  else
    new.qty_kg := s.kg;
  end if;$s$);
  if n = d then raise exception 'v096d: milk_intake_shipment_check pattern not found'; end if;
  execute n;
end $mig$;

-- the office is told (notice, also on the tablet Home), once per delivery
create or replace function fabula.trg_milk_weight_notice()
returns trigger language plpgsql security definer set search_path = fabula, public as $$
begin
  if new.shipment_id is null or new.farm_kg is null or new.qty_kg is not distinct from new.farm_kg then return null; end if;
  insert into fabula.notices (key, severity, title_it, items, expires_at)
  values ('milk_weight:' || new.milk_lot, 'warn',
          format('Latte %s: pesato qui %s kg, la Masseria ha scritto %s kg (%s %%): vale il peso del caseificio', new.milk_lot,
                 replace(to_char(new.qty_kg, 'FM999990.0'), '.', ','), replace(to_char(new.farm_kg, 'FM999990.0'), '.', ','),
                 replace(to_char(round((new.qty_kg - new.farm_kg) / new.farm_kg * 100, 1), 'FMSG9990.0'), '.', ',')),
          jsonb_build_array(jsonb_build_object('label_it', 'Motivo: ' || coalesce(new.weight_note, '—')),
                            jsonb_build_object('label_it', 'La Masseria lo vede sulla sua pagina; controlla il conto del latte del mese')),
          now() + interval '7 days')
  on conflict (key) do update set title_it = excluded.title_it, items = excluded.items, resolved_at = null, expires_at = excluded.expires_at;
  return null;
end $$;
revoke all on function fabula.trg_milk_weight_notice() from public, anon, authenticated;
drop trigger if exists milk_intake_weight_notice on fabula.milk_intake;
create trigger milk_intake_weight_notice after insert on fabula.milk_intake for each row execute function fabula.trg_milk_weight_notice();

-- the farm sees both weights and the reason; its month total counts what entered
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.farm_milk_orders(text)'::regprocedure);
  n := replace(d, $s$'original_kg', s.original_kg, 'correction_reason', s.correction_reason)$s$,
                  $s$'original_kg', s.original_kg, 'correction_reason', s.correction_reason,
                                                              'dairy_kg', mi.dairy_kg, 'entered_kg', mi.qty_kg,
                                                              'weight_note', case when mi.qty_kg is distinct from mi.farm_kg then mi.weight_note end)$s$);
  n := replace(n, $s$'received_kg', (select coalesce(sum(kg), 0) from fabula.milk_shipments where status = 'received' and ship_date >= date_trunc('month', v_today)::date),$s$,
                  $s$'received_kg', (select coalesce(sum(coalesce(mi2.qty_kg, s2.kg)), 0) from fabula.milk_shipments s2 left join fabula.milk_intake mi2 on mi2.id = s2.milk_intake_id
                                    where s2.status = 'received' and s2.ship_date >= date_trunc('month', v_today)::date),$s$);
  n := replace(n, $s$'prev_received_kg', (select coalesce(sum(kg), 0) from fabula.milk_shipments where status = 'received'
                               and ship_date >= (date_trunc('month', v_today) - interval '1 month')::date and ship_date < date_trunc('month', v_today)::date)),$s$,
                  $s$'prev_received_kg', (select coalesce(sum(coalesce(mi2.qty_kg, s2.kg)), 0) from fabula.milk_shipments s2 left join fabula.milk_intake mi2 on mi2.id = s2.milk_intake_id
                               where s2.status = 'received'
                               and s2.ship_date >= (date_trunc('month', v_today) - interval '1 month')::date and s2.ship_date < date_trunc('month', v_today)::date)),$s$);
  if position('''dairy_kg'', mi.dairy_kg' in n) = 0 or position('sum(coalesce(mi2.qty_kg, s2.kg))' in n) = 0
     or (length(n) - length(replace(n, 'sum(coalesce(mi2.qty_kg, s2.kg))', ''))) / length('sum(coalesce(mi2.qty_kg, s2.kg))') <> 2 then
    raise exception 'v096d: farm_milk_orders patterns not found';
  end if;
  execute n;
end $mig$;

-- the milk register (MOD-01) prints the two weights when they differ
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.haccp_register(text,date,date)'::regprocedure);
  n := replace(d, $s$'kg', fabula._it_num(mi.qty_kg),$s$,
                  $s$'kg', case when mi.farm_kg is not null and mi.qty_kg is distinct from mi.farm_kg
                                then fabula._it_num(mi.qty_kg) || ' (pesati qui; Masseria ' || fabula._it_num(mi.farm_kg) || ': ' || coalesce(mi.weight_note, '') || ')'
                                else fabula._it_num(mi.qty_kg) end,$s$);
  if n = d then raise exception 'v096d: haccp_register milk kg pattern not found'; end if;
  execute n;
end $mig$;

insert into supabase_migrations.schema_migrations (version, name) values
  ('20261013090000', 'v096a_critical_milk_ccp_records'),
  ('20261013090100', 'v096b_operator'),
  ('20261013090200', 'v096c_notify_telegram'),
  ('20261013090300', 'v096d_milk_dairy_weight');
commit;

select version, name from supabase_migrations.schema_migrations order by version desc limit 6;
