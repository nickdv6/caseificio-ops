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
                  E'  if v_res in (''ok'', ''da_verificare'') then   -- v0.95a: back in service only with a deviation inside tolerance\n    update fabula.equipment set out_of_service = case when v_res = ''ok'' then false else out_of_service end,');
  n := replace(n, $s$'records_to_review', v_affected);$s$, $s$'records_to_review', v_affected, 'out_of_service', (select out_of_service from fabula.equipment where id = e.id));$s$);
  if position('Scrivi il numero del certificato' in n) = 0 or position('then ''da_verificare''' in n) = 0
     or position('else out_of_service end' in n) = 0 or position('''out_of_service'', (select' in n) = 0 then
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
  if p_lot is not null and v_batch is null and not exists (select 1 from fabula.milk_intake where upper(milk_lot) = p_lot)
     and not exists (select 1 from fabula.milk_shipments where upper(milk_lot) = p_lot) then
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
begin
  if new.curd_ph is not null and (tg_op = 'INSERT' or new.curd_ph is distinct from old.curd_ph) and (new.curd_ph < 3 or new.curd_ph > 8) then
    raise exception 'pH della cagliata impossibile: % (possibile da 3 a 8). Controlla la virgola e riscrivi.', fabula._it_num(new.curd_ph) using errcode = '23514';
  end if;
  if tg_op = 'UPDATE' and (old.food_safety_hold is distinct from new.food_safety_hold or old.hold_released_at is distinct from new.hold_released_at
                           or old.hold_released_by_id is distinct from new.hold_released_by_id or old.hold_reason is distinct from new.hold_reason
                           or old.hold_at is distinct from new.hold_at or old.hold_nc_id is distinct from new.hold_nc_id) then
    if coalesce(current_setting('fabula.hold_ctx', true), '') = 'on' then
      perform set_config('fabula.hold_ctx', '', true);        -- one use: the next update in the same transaction is checked again
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
  from (values ('CCP-PAST', 40, 100), ('CCP-STRETCH', 40, 99), ('CCP-RIC', 50, 99), ('CCP-MILK-TEMP', -2, 40),
               ('CCP-COLD-1', -10, 25), ('CCP-COLD-2', -10, 25), ('CCP-MILK-ABX', 0, 1), ('PRP-PAST-VALVE', 0, 1)) v(code, lo, hi)
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
