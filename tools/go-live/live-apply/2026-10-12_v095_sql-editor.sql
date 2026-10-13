-- v0.95a + v0.95b for the Supabase dashboard SQL Editor (12/10/2026): the audit backlog items that take under an hour, severity
-- High/Critical — food-safety and production guards (A-12, B-02..B-05, D-03, D-09, D-12) and farm weight / settings / print data /
-- outside watcher (FARM-01, C-04, C-28, E-20, PRINT-03). Same files as supabase/migrations/20261012230000_* and 20261012230100_*.
-- One transaction: if any step fails nothing changes. It records both versions in the migration history and refuses a second run.
-- Paste everything, Run, and check the last result shows 20261012230100 and 20261012230000 at the top.
begin;
do $chk$ begin
  if exists (select 1 from supabase_migrations.schema_migrations where version in ('20261012230000', '20261012230100')) then
    raise exception 'STOP: v0.95 is already in the migration history — nothing to do';
  end if;
  if (select max(version) from supabase_migrations.schema_migrations) <> '20261012220000' then
    raise exception 'STOP: the live history does not end at v0.94b (20261012220000) — tell Claude before applying';
  end if;
end $chk$;

-- ======================= v0.95a =======================
-- v0.95a · Audit 12/10/2026, backlog items that take under an hour, severity High/Critical — food safety and production guards.
-- (audit doc "Caseificio ops — usability & error-proofing audit", backlog: A-12, B-02, B-03, B-04, B-05, D-03, D-09, D-12)
-- Function bodies are patched in place: each pattern must match, otherwise the migration stops and nothing changes.

-- small helper: Italian whole kg with the thousands dot (1.050), for messages
create or replace function fabula._it_int(x numeric) returns text language sql immutable set search_path = fabula, public as
$$ select case when x is null then '' else replace(to_char(round(x), 'FM999G999G990'), ',', '.') end $$;

-- 1 · (A-12) A queued check closes its task in the name of the person who did it, even if someone else's login sends it later.
--     Before: close_open_task signed with the session user first, so records queued offline and sent after "Esci" + a new login
--     were attributed to the next person.
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.close_open_task(date,text,uuid,uuid,uuid,uuid)'::regprocedure);
  n := replace(d, 'completed_by_id = coalesce(fabula.my_staff_id(), p_staff_id)', 'completed_by_id = coalesce(p_staff_id, fabula.my_staff_id())');
  if n = d then raise exception 'v095a: close_open_task pattern not found'; end if;
  execute n;
end $mig$;

-- 2 · (B-02) A lab result can be corrected afterwards, with a reason, keeping the first outcome.
--     The correction goes through record_lab_result (same NC / lot hold / recall rules); the old outcome stays in the sample's notes
--     and in the audit log (Configurazione → Registro modifiche).
do $$ begin
  if to_regclass('fabula.lab_samples') is not null and not exists (select 1 from pg_trigger where tgname = 'lab_samples_audit' and tgrelid = 'fabula.lab_samples'::regclass) then
    create trigger lab_samples_audit after update on fabula.lab_samples for each row execute function fabula.trg_audit();
  end if;
end $$;

create or replace function fabula.correct_lab_result(p_sample_code text, p_outcome text, p_reason text, p_text text default null, p_report_no text default null, p_staff_id uuid default null)
returns jsonb language plpgsql set search_path = fabula, public as $$
declare s fabula.lab_samples%rowtype; v_by text;
  lbl constant jsonb := '{"in_attesa":"in attesa","conforme":"conforme","attenzione":"attenzione","non_conforme":"NON conforme","annullato":"annullato"}';
begin
  perform fabula.require_perm('haccp', 2);
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Scrivi il motivo della correzione (es. esito letto male dal referto)' using errcode = '22023'; end if;
  select * into s from fabula.lab_samples where sample_code = p_sample_code;
  if s.id is null then raise exception 'Campione sconosciuto: %', p_sample_code; end if;
  if s.outcome = 'in_attesa' then raise exception 'Il campione % non ha ancora un esito: registralo, non serve correggerlo', p_sample_code using errcode = '22023'; end if;
  if s.outcome = p_outcome then raise exception 'L''esito è già «%»', lbl ->> p_outcome using errcode = '22023'; end if;
  select full_name into v_by from fabula.staff where id = coalesce(fabula.my_staff_id(), p_staff_id);
  update fabula.lab_samples
     set notes = concat_ws(E'\n', notes, format('[%s] esito corretto da %s: %s → %s (prima: %s%s). Motivo: %s',
                   to_char(now() at time zone 'Europe/Rome', 'DD/MM/YYYY HH24:MI'), coalesce(v_by, 'utente'),
                   coalesce(lbl ->> s.outcome, s.outcome), coalesce(lbl ->> p_outcome, p_outcome),
                   coalesce(nullif(s.result_it, ''), 'nessun risultato'), coalesce(', referto ' || nullif(s.report_no, ''), ''), trim(p_reason)))
   where id = s.id;
  return fabula.record_lab_result(p_sample_code, p_outcome, null, coalesce(nullif(trim(p_text), ''), s.result_it), coalesce(nullif(trim(p_report_no), ''), s.report_no), null, null, p_staff_id)
         || jsonb_build_object('corrected_from', s.outcome);
end $$;
revoke execute on function fabula.correct_lab_result(text,text,text,text,text,uuid) from public, anon;
grant execute on function fabula.correct_lab_result(text,text,text,text,text,uuid) to authenticated, service_role;

-- 3 · (B-03) An external calibration needs its certificate number and either the deviation or the PDF. With no deviation the result
--     is "da verificare" and an instrument out of service stays out of service. A calibration or check cannot be dated in the future.
alter table fabula.calibration_checks drop constraint if exists calibration_checks_result_check;
alter table fabula.calibration_checks add constraint calibration_checks_result_check check (result in ('ok', 'ko', 'da_verificare'));
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.record_calibration_check(text,text,text,jsonb,uuid,text,text,uuid,text,boolean,date)'::regprocedure);
  n := replace(d, E'  perform fabula.require_perm(''haccp'', 2);\n', E'  perform fabula.require_perm(''haccp'', 2);\n' ||
$s$  -- v0.95a (audit B-03): no future dates; an external calibration needs its certificate and the deviation or the PDF
  if p_on > (now() at time zone 'Europe/Rome')::date then
    raise exception 'La data (%) è nel futuro: scrivi il giorno in cui è stata fatta', to_char(p_on, 'DD/MM/YYYY') using errcode = '22023';
  end if;
  if p_kind = 'taratura_esterna' then
    if coalesce(trim(p_certificate_no), '') = '' then raise exception 'Scrivi il numero del certificato di taratura' using errcode = '22023'; end if;
    if p_document_id is null and not exists (select 1 from jsonb_array_elements(coalesce(p_points, '[]')) pt where pt ? 'ref' and pt ? 'reading') then
      raise exception 'Scrivi lo scarto massimo indicato sul certificato oppure allega il PDF del certificato' using errcode = '22023';
    end if;
  end if;
$s$);
  n := replace(n, $s$when p_kind = 'taratura_esterna' and v_dev is null then 'ok'$s$, $s$when p_kind = 'taratura_esterna' and v_dev is null then 'da_verificare'$s$);
  n := replace(n, E'  if v_res = ''ok'' then\n    update fabula.equipment set out_of_service = false,',
                  E'  if v_res = ''da_verificare'' then   -- v0.95a: certificate kept, but no return to service and the due date does not move until the deviation is written\n    update fabula.equipment set calibration_cert_ref = coalesce(p_certificate_no, calibration_cert_ref) where id = e.id;\n  elsif v_res = ''ok'' then\n    update fabula.equipment set out_of_service = false,');
  n := replace(n, $s$'records_to_review', v_affected);$s$, $s$'records_to_review', v_affected, 'out_of_service', (select out_of_service from fabula.equipment where id = e.id));$s$);
  if position('Scrivi il numero del certificato' in n) = 0 or position('then ''da_verificare''' in n) = 0
     or position('the due date does not move' in n) = 0 or position('''out_of_service'', (select' in n) = 0 then
    raise exception 'v095a: record_calibration_check patterns not found';
  end if;
  execute n;

  -- the calibration register (MOD) prints "da verificare", not "FUORI TOLLERANZA", for a certificate without a deviation
  d := pg_get_functiondef('fabula.haccp_register(text,date,date)'::regprocedure);
  n := replace(d, $s$'esito', case when k.result = 'ok' then 'conforme' else 'FUORI TOLLERANZA' end,$s$,
                  $s$'esito', case when k.result = 'ok' then 'conforme' when k.result = 'da_verificare' then 'da verificare: scarto non indicato' else 'FUORI TOLLERANZA' end,$s$);
  n := replace(n, $s$'_ko', k.result <> 'ok')$s$, $s$'_ko', k.result = 'ko', '_warn', k.result = 'da_verificare')$s$);
  if position('da verificare: scarto non indicato' in n) = 0 or position('''_warn'', k.result = ''da_verificare''' in n) = 0 then
    raise exception 'v095a: haccp_register calibration patterns not found';
  end if;
  execute n;
end $mig$;

-- 4 · (B-04) A register review cannot cover days still to come, and it is signed by whoever is logged in.
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.mark_register_reviewed(text,date,date,uuid,text,text)'::regprocedure);
  n := replace(d, E'declare v uuid;\n', E'declare v uuid; v_today date := (now() at time zone ''Europe/Rome'')::date;\n');
  n := replace(n, E'  perform fabula.require_perm(''haccp'', 3);\n', E'  perform fabula.require_perm(''haccp'', 3);\n' ||
$s$  -- v0.95a (audit B-04): the period ends today at the latest; it must start before it ends
  if p_from is null or p_to is null then raise exception 'Indica il periodo verificato (dal … al …)' using errcode = '22023'; end if;
  if p_to > v_today then p_to := v_today; end if;
  if p_from > p_to then
    raise exception 'Periodo non valido: dal % al %. Si verificano solo giorni già passati (fino a oggi)', to_char(p_from, 'DD/MM/YYYY'), to_char(p_to, 'DD/MM/YYYY') using errcode = '22023';
  end if;
$s$);
  n := replace(n, 'coalesce(p_staff_id, fabula.my_staff_id())', 'coalesce(fabula.my_staff_id(), p_staff_id)');
  if position('v_today date' in n) = 0 or position('Periodo non valido' in n) = 0 or position('coalesce(fabula.my_staff_id(), p_staff_id)' in n) = 0 then
    raise exception 'v095a: mark_register_reviewed patterns not found';
  end if;
  execute n;
end $mig$;

-- 5 · (B-05) A sample's lot is upper-cased and must exist (a production lot or a milk lot): a positive result can then hold it.
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.record_sample_taken(text,text,text,uuid,text,date)'::regprocedure);
  n := replace(d, $s$  if p_lot is not null and p_lot <> '' then select id into v_batch from fabula.production_batches where batch_lot = p_lot; end if;$s$,
$s$  p_lot := nullif(upper(regexp_replace(coalesce(p_lot, ''), '\s', '', 'g')), '');   -- v0.95a (audit B-05)
  if p_lot is not null then select id into v_batch from fabula.production_batches where batch_lot = p_lot; end if;
  if p_lot is not null and v_batch is null and not exists (select 1 from fabula.milk_intake where upper(regexp_replace(milk_lot, '\s', '', 'g')) = p_lot)
     and not exists (select 1 from fabula.milk_shipments where upper(regexp_replace(milk_lot, '\s', '', 'g')) = p_lot) then
    raise exception 'Lotto % non trovato: controlla il codice sull''etichetta (es. L20261012-A) oppure lascia vuoto se il campione non è di un lotto', p_lot using errcode = '22023';
  end if;$s$);
  if n = d then raise exception 'v095a: record_sample_taken pattern not found'; end if;
  execute n;
end $mig$;

-- 6 · (D-03) A food-safety hold is lifted only through release_lot_hold (HACCP manager, reason, signature): a plain UPDATE from the
--     API, an old cached tablet or a script is refused. Setting a hold stays open to anyone who may write the batch (it only protects).
--     Every change of the hold is written to the audit log.
--     (D-12, part) the curd pH must be a pH: 3–8.
create or replace function fabula.trg_batch_guard() returns trigger language plpgsql set search_path = fabula, public as $$
declare v_ctx boolean := false;
begin
  if tg_op = 'UPDATE' and coalesce(current_setting('fabula.hold_ctx', true), '') = 'on' then
    v_ctx := true; perform set_config('fabula.hold_ctx', '', true);   -- one use: the next update in the same transaction is checked again
  end if;
  if new.curd_ph is not null and (tg_op = 'INSERT' or new.curd_ph is distinct from old.curd_ph) and (new.curd_ph < 3 or new.curd_ph > 8) then
    raise exception 'pH della cagliata impossibile: % (possibile da 3 a 8). Controlla la virgola e riscrivi.', fabula._it_num(new.curd_ph) using errcode = '23514';
  end if;
  if tg_op = 'UPDATE' and (old.food_safety_hold is distinct from new.food_safety_hold or old.hold_released_at is distinct from new.hold_released_at
                           or old.hold_released_by_id is distinct from new.hold_released_by_id or old.hold_reason is distinct from new.hold_reason
                           or old.hold_at is distinct from new.hold_at or old.hold_nc_id is distinct from new.hold_nc_id) then
    if v_ctx then
      null;                                                    -- hold_lot / release_lot_hold / log_ccp
    elsif (old.food_safety_hold and not coalesce(new.food_safety_hold, false))
          or (old.food_safety_hold and coalesce(new.food_safety_hold, false) and (old.hold_reason is distinct from new.hold_reason or old.hold_nc_id is distinct from new.hold_nc_id))
          or old.hold_released_at is distinct from new.hold_released_at or old.hold_released_by_id is distinct from new.hold_released_by_id then
      raise exception 'Lotto % bloccato per sicurezza alimentare: lo sblocco si fa solo da Autocontrollo → Lotti bloccati (serve il responsabile HACCP)', new.batch_lot using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists batch_guard on fabula.production_batches;
create trigger batch_guard before insert or update on fabula.production_batches for each row execute function fabula.trg_batch_guard();
drop trigger if exists production_batches_hold_audit on fabula.production_batches;
create trigger production_batches_hold_audit after update on fabula.production_batches for each row
  when (old.food_safety_hold is distinct from new.food_safety_hold or old.hold_reason is distinct from new.hold_reason or old.hold_released_at is distinct from new.hold_released_at)
  execute function fabula.trg_audit();

do $mig$
declare f text; d text; n text;
begin
  foreach f in array array['fabula.hold_lot(text,text,uuid)', 'fabula.release_lot_hold(text,uuid,text)',
                           'fabula.log_ccp(text,numeric,timestamptz,uuid,text,text,text,text,text)'] loop
    d := pg_get_functiondef(f::regprocedure);
    n := regexp_replace(d, '(\n[ ]*)(update fabula\.production_batches set food_safety_hold)', E'\\1perform set_config(''fabula.hold_ctx'', ''on'', true);   -- v0.95a: the hold guard lets this update through\\1\\2');
    if n = d then raise exception 'v095a: hold update not found in %', f; end if;
    execute n;
  end loop;
end $mig$;

-- 7 · (D-09) A milk delivery cannot go into the vats for more than it weighed (+2 % for the dairy's scale and the litre conversion).
create or replace function fabula.trg_batch_milk_left() returns trigger language plpgsql set search_path = fabula, public as $$
declare v_in numeric; v_lot text; v_used numeric;
begin
  perform pg_advisory_xact_lock(hashtext('batch_milk_inputs:' || new.milk_intake_id::text));   -- two tablets starting a vat at the same time
  select qty_kg, milk_lot into v_in, v_lot from fabula.milk_intake where id = new.milk_intake_id;
  if v_in is null then return new; end if;
  select coalesce(sum(qty_kg), 0) into v_used from fabula.batch_milk_inputs
   where milk_intake_id = new.milk_intake_id and not (tg_op = 'UPDATE' and batch_id = old.batch_id and milk_intake_id = old.milk_intake_id);
  if v_used + new.qty_kg > v_in * 1.02 then
    raise exception 'Sul latte % restano % kg (ricevuti %, già in caldaia %): hai scritto % kg. Controlla il lotto sull''etichetta e i kg',
      coalesce(v_lot, '?'), fabula._it_int(greatest(v_in - v_used, 0)), fabula._it_int(v_in), fabula._it_int(v_used), fabula._it_int(new.qty_kg) using errcode = '23514';
  end if;
  return new;
end $$;
drop trigger if exists batch_milk_left on fabula.batch_milk_inputs;
create trigger batch_milk_left before insert or update of qty_kg, milk_intake_id on fabula.batch_milk_inputs for each row execute function fabula.trg_batch_milk_left();

-- 8 · (D-12) Every CCP reading must be possible (a slipped comma is refused before anything is saved) and a CCP is never recorded empty.
alter table fabula.haccp_control_points add column if not exists plausible_min numeric(10,2), add column if not exists plausible_max numeric(10,2);
comment on column fabula.haccp_control_points.plausible_min is 'Lowest physically possible reading: below it the reading is refused as a typing error (v0.95a)';
update fabula.haccp_control_points c set plausible_min = v.lo, plausible_max = v.hi
  -- wide enough to record a real failure (a pasteuriser that did not heat, a cold room that broke down in August),
  -- narrow enough to catch a slipped comma (7,2 or 720 for 72; 520 for 52; 45 for 4,5 °C of milk stays possible and opens the NC)
  from (values ('CCP-PAST', 10, 100), ('CCP-STRETCH', 10, 99), ('CCP-RIC', 10, 99), ('CCP-MILK-TEMP', -2, 45),
               ('CCP-COLD-1', -10, 45), ('CCP-COLD-2', -10, 45), ('CCP-MILK-ABX', 0, 1), ('PRP-PAST-VALVE', 0, 1)) v(code, lo, hi)
 where c.code = v.code and c.plausible_min is null and c.plausible_max is null;

create or replace function fabula.trg_haccp_log_plausible() returns trigger language plpgsql set search_path = fabula, public as $$
declare cp record;
begin
  if coalesce(new.source, '') = 'simulation' then return new; end if;
  if tg_op = 'UPDATE' and new.measured_value is not distinct from old.measured_value then return new; end if;
  select code, name, ccp_no, is_ccp, unit, plausible_min, plausible_max into cp from fabula.haccp_control_points where id = new.control_point_id;
  if cp.code is null then return new; end if;
  if new.measured_value is null then
    if cp.is_ccp then
      raise exception '%: è un punto critico, scrivi il valore misurato (non si registra vuoto)', coalesce(cp.ccp_no || ' · ', '') || cp.name using errcode = '23502';
    end if;
    return new;
  end if;
  if coalesce(new.source, '') <> 'sensor'
     and ((cp.plausible_min is not null and new.measured_value < cp.plausible_min) or (cp.plausible_max is not null and new.measured_value > cp.plausible_max)) then
    raise exception 'Valore impossibile: % per «%» (possibili %–%). Controlla la virgola e riscrivi.',
      fabula._it_num(new.measured_value) || case when coalesce(cp.unit, 'esito') = 'esito' then '' else ' ' || cp.unit end, cp.name,
      fabula._it_num(cp.plausible_min), fabula._it_num(cp.plausible_max) using errcode = '22003';
  end if;
  return new;
end $$;
drop trigger if exists haccp_log_plausible on fabula.haccp_log;
create trigger haccp_log_plausible before insert or update of measured_value on fabula.haccp_log for each row execute function fabula.trg_haccp_log_plausible();

-- a CCP counts as recorded for a batch only with a measured value
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.trg_batch_ccp_check()'::regprocedure);
  n := replace(d, 'where l.batch_id = new.id and cp.code = c);', 'where l.batch_id = new.id and cp.code = c and l.measured_value is not null);   -- v0.95a (audit D-12)');
  if n = d then raise exception 'v095a: trg_batch_ccp_check pattern not found'; end if;
  execute n;
end $mig$;

-- ======================= v0.95b =======================
-- v0.95b · Audit 12/10/2026, backlog items under an hour, severity High/Critical — farm weight, settings, print data, outside watcher.
-- (audit backlog: FARM-01, C-04, C-28, E-20 health part, PRINT-03 go-live check). Patches are guarded: no match, no change.

-- 1 · (FARM-01) A farm weight far from today's order and from the usual loads is not recorded until the farm confirms it.
--     farm_milk_ship gets p_confirm: false = check first (answers needs_confirm with the numbers), true = the farm has confirmed.
--     NULL (an older farm-order function that does not send it) keeps the old behaviour, so the order of deploys does not matter.
--     Under 50 kg is refused in every case: no real tanker load is that small.
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.farm_milk_ship(text,numeric,numeric,text,text)'::regprocedure);
  n := replace(d, 'p_note text DEFAULT NULL::text)', 'p_note text DEFAULT NULL::text, p_confirm boolean DEFAULT NULL::boolean)');
  n := replace(n, 'declare v_tok text := ', 'declare v_order numeric; v_left numeric; v_med numeric; v_nrec int; v_fit boolean; v_tok text := ');
  n := replace(n, E'  if p_temp is not null and (p_temp < -2 or p_temp > 40)',
$s$  if p_kg < 50 then raise exception 'Peso troppo basso: % kg. Scrivi i kg di latte caricati (almeno 50 kg; 1.050 si scrive 1050)', round(p_kg, 1) using errcode = '22023'; end if;
  if p_temp is not null and (p_temp < -2 or p_temp > 40)$s$);
  n := replace(n, E'  insert into fabula.milk_shipments (ship_date, supplier_id,',
$s$  -- v0.95b (audit FARM-01): compare with today's approved order (and what is still missing of it) and with the median of the last 10 loads
  if p_confirm is false then
    select milk_kg into v_order from fabula.milk_plans where status = 'approved' and plan_date = v_today order by milk_kg desc limit 1;
    v_left := v_order - coalesce((select sum(kg) from fabula.milk_shipments where ship_date = v_today and status <> 'cancelled'), 0);
    select count(*), percentile_cont(0.5) within group (order by kg) into v_nrec, v_med
      from (select kg from fabula.milk_shipments where status <> 'cancelled' and ship_date >= v_today - 30 order by shipped_at desc limit 10) x;   -- the loads the farm page shows
    if v_nrec < 3 then v_med := null; end if;
    v_fit := (v_order is null and v_med is null)
          or (v_order is not null and p_kg between v_order * 0.7 and v_order * 1.3)
          or (v_left > 0 and p_kg between v_left * 0.7 and v_left * 1.3)
          or (v_med is not null and p_kg between v_med * 0.7 and v_med * 1.3);
    if not coalesce(v_fit, false) then   -- NULL = no reference matched (e.g. no order today and the weight far from the usual loads)
      return jsonb_build_object('needs_confirm', true, 'kg', round(p_kg, 1), 'order_kg', v_order, 'left_kg', case when v_left > 0 then v_left end,
        'usual_kg', round(v_med),
        'message_it', case when v_order is not null
          then format('Hai scritto %s kg ma l''ordine di oggi è %s kg%s. È giusto?', fabula._it_num(round(p_kg, 1)), fabula._it_int(v_order),
                      case when v_left > 0 and v_left < v_order then format(' (ne mancano %s)', fabula._it_int(v_left)) else '' end)
          else format('Hai scritto %s kg: di solito una spedizione è di circa %s kg. È giusto?', fabula._it_num(round(p_kg, 1)), fabula._it_int(v_med)) end);
    end if;
  end if;
  insert into fabula.milk_shipments (ship_date, supplier_id,$s$);
  if position('p_confirm boolean' in n) = 0 or position('v_order numeric' in n) = 0 or position('Peso troppo basso' in n) = 0 or position('needs_confirm' in n) = 0 then
    raise exception 'v095b: farm_milk_ship patterns not found';
  end if;
  drop function fabula.farm_milk_ship(text,numeric,numeric,text,text);
  execute n;
end $mig$;
revoke execute on function fabula.farm_milk_ship(text,numeric,numeric,text,text,boolean) from public, anon, authenticated;
grant execute on function fabula.farm_milk_ship(text,numeric,numeric,text,text,boolean) to service_role;

-- 2 · (C-28) kg per Shopify piece is a weight in kg: 0 < kg ≤ 25. A piece typed in grams (250) is refused instead of deducting 250 kg
--     per sale. The title auto-mapper only maps weights in that range (a "30 kg" catering title stays unmapped instead of failing).
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.upsert_shopify_orders(jsonb)'::regprocedure);
  n := replace(d, $s$if v_kg is not null and (coalesce(l->>'product_type', '') ilike '%mozzarella%'$s$, $s$if v_kg > 0 and v_kg <= 25 and (coalesce(l->>'product_type', '') ilike '%mozzarella%'$s$);
  if n = d then raise exception 'v095b: upsert_shopify_orders auto-map pattern not found'; end if;
  execute n;
end $mig$;
alter table fabula.shopify_variant_map drop constraint if exists shopify_variant_map_kg_per_unit_check;
alter table fabula.shopify_variant_map add constraint shopify_variant_map_kg_per_unit_check check (kg_per_unit > 0 and kg_per_unit <= 25) not valid;
do $$ begin
  alter table fabula.shopify_variant_map validate constraint shopify_variant_map_kg_per_unit_check;
exception when check_violation then
  raise notice 'v095b: some kg per piece are outside 0–25 kg: fix them in Configurazione → Prodotti Shopify (new values are checked already)';
end $$;

-- 3 · (C-04) B2B cut-off and delivery days: written the Italian way they are normalised ("18.00", "ore 18" → 18:00; "lun,mar" or
--     "1-6" → 1,2,3,4,5,6); anything unreadable is refused with a sentence instead of breaking the trade portal. The cut-off falls back
--     to 18:00 if the stored value is ever unreadable. Configurazione shows a time field and seven weekday boxes (settings.kind).
create or replace function fabula.trg_settings_format() returns trigger language plpgsql set search_path = fabula, public as $$
declare v text := lower(trim(coalesce(new.value, ''))); m text[]; x text; days int[] := '{}'; a int; b int;
begin
  if new.key = 'trade.cutoff_time' then
    m := regexp_match(v, '^(?:ore\s*)?(\d{1,2})(?:\s*[:.,h]\s*(\d{2}))?$');
    if m is null or m[1]::int > 23 or coalesce(m[2], '00')::int > 59 then
      raise exception 'Orario limite non valido: «%». Scrivilo come 18:00', new.value using errcode = '22023';
    end if;
    new.value := lpad(m[1], 2, '0') || ':' || coalesce(m[2], '00');
  elsif new.key = 'trade.default_window' then
    m := regexp_match(v, '^(\d{1,2})[:.](\d{2})\s*[-–]\s*(\d{1,2})[:.](\d{2})$');
    if m is null or m[1]::int > 23 or m[3]::int > 23 or m[2]::int > 59 or m[4]::int > 59 then
      raise exception 'Fascia di consegna non valida: «%». Scrivila come 07:00-09:00', new.value using errcode = '22023';
    end if;
    new.value := lpad(m[1], 2, '0') || ':' || m[2] || '-' || lpad(m[3], 2, '0') || ':' || m[4];
  elsif new.key = 'pickup.cutoff_hour' then
    if v !~ '^\d{1,2}$' or v::int > 23 then raise exception 'Ora limite ritiro non valida: «%». Scrivi l''ora intera, es. 18', new.value using errcode = '22023'; end if;
    new.value := v::int::text;
  elsif new.key = 'trade.delivery_days' then
    v := regexp_replace(v, '\s*-\s*', '-', 'g');
    foreach x in array regexp_split_to_array(v, '\s*[,;/ ]+\s*') loop
      continue when x = '';
      if x like '%-%' then                                 -- a range: 1-6, lun-sab, lunedì-venerdì
        a := case when split_part(x, '-', 1) ~ '^[1-7]$' then split_part(x, '-', 1)::int else array_position(array['lun','mar','mer','gio','ven','sab','dom'], left(split_part(x, '-', 1), 3)) end;
        b := case when split_part(x, '-', 2) ~ '^[1-7]$' then split_part(x, '-', 2)::int else array_position(array['lun','mar','mer','gio','ven','sab','dom'], left(split_part(x, '-', 2), 3)) end;
        if a is null or b is null or split_part(x, '-', 3) <> '' then
          raise exception 'Giorni di consegna non riconosciuti: «%». Usa 1 = lunedì … 7 = domenica, es. 1-6 oppure 1,2,3', x using errcode = '22023'; end if;
        if a > b then raise exception 'Giorni di consegna: «%» va scritto dal primo all''ultimo giorno (es. 1-6 o lun-sab)', x using errcode = '22023'; end if;
        days := days || array(select generate_series(a, b));
      elsif x ~ '^[1-7]$' then days := days || x::int;
      else
        a := array_position(array['lun','mar','mer','gio','ven','sab','dom'], left(x, 3));
        if a is null then raise exception 'Giorno di consegna non riconosciuto: «%». Usa 1 = lunedì … 7 = domenica, es. 1,2,3,4,5,6', x using errcode = '22023'; end if;
        days := days || a;
      end if;
    end loop;
    if cardinality(days) = 0 then raise exception 'Indica almeno un giorno di consegna (1 = lunedì … 7 = domenica)' using errcode = '22023'; end if;
    new.value := (select string_agg(dd::text, ',' order by dd) from (select distinct unnest(days) dd) z);
  end if;
  return new;
end $$;
drop trigger if exists settings_format on fabula.settings;
create trigger settings_format before insert or update of value on fabula.settings for each row
  when (new.key in ('trade.cutoff_time', 'trade.default_window', 'pickup.cutoff_hour', 'trade.delivery_days'))
  execute function fabula.trg_settings_format();
alter table fabula.settings drop constraint if exists settings_kind_check;
alter table fabula.settings add constraint settings_kind_check check (kind in ('flag', 'date', 'month', 'time', 'weekdays'));
update fabula.settings set kind = 'time' where key = 'trade.cutoff_time';
update fabula.settings set kind = 'weekdays' where key = 'trade.delivery_days';

create or replace function fabula.trade_cutoff_at(p_date date) returns timestamp language sql stable set search_path = fabula, public as $$
  -- v0.95b (audit C-04): an unreadable cut-off falls back to 18:00 instead of breaking the portal and Console → Ingrosso
  select (p_date - 1)::timestamp + case when fabula.setting_text('trade.cutoff_time', '18:00') ~ '^([01]?\d|2[0-3]):[0-5]\d(:[0-5]\d)?$'
                                        then fabula.setting_text('trade.cutoff_time', '18:00')::time else time '18:00' end
$$;

-- 4 · (E-20, health part) The outside watcher (GitHub, every 30 min) also fails when scheduled bots stopped running: a bot slot of
--     today, due in the last 4 hours and past its grace (+20 min for the database stand-in), with no run of the bot itself.
--     The nightly backup has its own check (backup_ok). Only a count is published (the endpoint is public).
create or replace function public.fabula_health() returns jsonb language sql stable security definer set search_path = fabula, public, pg_catalog as $$
  with d as (select (now() at time zone 'Europe/Rome')::date as day),
  slots as (
    select bs.agent, (d.day + t.due) at time zone 'Europe/Rome' as due_at, bs.grace_min
      from fabula.bot_schedule bs cross join d cross join unnest(bs.due_times) t(due)
     where bs.active and bs.agent <> 'backup_export' and extract(isodow from d.day) = any (bs.weekdays)
       and (bs.month_day is null or extract(day from d.day) = bs.month_day)),
  missed as (
    select s.agent from slots s
     where s.due_at + make_interval(mins => s.grace_min + 20) <= now() and s.due_at > now() - interval '4 hours'
       and not exists (select 1 from fabula.agent_runs ar where ar.agent = s.agent and ar.started_at >= s.due_at - interval '30 minutes'
                         and coalesce(ar.details->>'via', '') <> 'db_fallback'))
  select jsonb_build_object(
    'db', true,
    'cron_ok', coalesce((select start_time from cron.job_run_details where start_time is not null order by runid desc limit 1) > now() - interval '20 minutes', false),
    'backup_ok', exists (select 1 from fabula.agent_runs where agent = 'backup_export' and status = 'ok' and started_at > now() - interval '26 hours'),
    'bots_ok', not exists (select 1 from missed),
    'bots_missed', (select count(*) from missed),
    'at', now())
$$;

-- 5 · (PRINT-03) Go-live board: an automatic check that DDTs and purchase orders carry the legal name, the P.IVA and a street address.
-- a street address = a street word (via, lungomare, località…) or a house number (a number that is not the 5-digit CAP)
create or replace function fabula.is_street_address(p text) returns boolean language sql immutable set search_path = fabula, public as $$
  select coalesce(p, '') ~* '(^|[[:space:],])(via|v\.|viale|v\.le|piazza|p\.zza|piazzale|corso|c\.so|largo|strada|str\.|località|loc\.|contrada|c\.da|vicolo|vico|traversa|borgo|frazione|fraz\.|lungomare|rione|salita|discesa|calata|parco|zona|s\.s\.|ss|s\.p\.|sp|snc)([[:space:].,0-9]|$)'
      or regexp_replace(coalesce(p, ''), '(^|[^0-9])[0-9]{5}([^0-9]|$)', '\1\2', 'g') ~ '[0-9]'
$$;
create or replace function fabula.company_docs_check() returns jsonb language sql stable set search_path = fabula, public as $$
  with c as (select trim(coalesce(fabula.setting_text('company.legal_name', ''), '')) ln, trim(coalesce(fabula.setting_text('company.piva', ''), '')) piva,
                    trim(coalesce(fabula.setting_text('company.address', ''), '')) addr),
  m as (select array_remove(array[case when ln = '' then 'ragione sociale' end,
                                  case when piva !~* '^(it)?\s*\d{11}$' then 'P.IVA' end,
                                  case when not fabula.is_street_address(addr) then 'indirizzo (via e numero)' end], null) miss from c)
  select jsonb_build_object('done', cardinality(miss) = 0,
                            'detail', case when cardinality(miss) = 0 then 'Legal name, P.IVA and street address set'
                                           else 'Missing on DDTs: ' || array_to_string(miss, ', ') || ' (Configurazione → Azienda)' end) from m
$$;
insert into fabula.dash_checks (key, sort, label, kind) values ('company_docs', 9, 'Company data on DDTs and POs (legal name, P.IVA, street address)', 'auto')
on conflict (key) do nothing;
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.ops_dashboard()'::regprocedure);
  n := replace(d, E'  v_auto := jsonb_build_object(\n', E'  v_auto := jsonb_build_object(\n    ''company_docs'', fabula.company_docs_check(),   -- v0.95b (audit PRINT-03)\n');
  if n = d or (length(n) - length(replace(n, 'company_docs_check()', ''))) <> length('company_docs_check()') then
    raise exception 'v095b: ops_dashboard pattern not found (or found more than once)';
  end if;
  execute n;
end $mig$;

insert into supabase_migrations.schema_migrations (version, name) values
  ('20261012230000', 'v095a_audit_s_items_food_safety'),
  ('20261012230100', 'v095b_audit_s_items_farm_config');
commit;

select version, name from supabase_migrations.schema_migrations order by version desc limit 3;
