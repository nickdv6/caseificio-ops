-- v0.55 · Food-safety fixes from the 04/10 bug test (BUG-REPORT-2026-10-04 items 1, 3, 4, 5).
-- Function bodies are patched in place (pattern must match, otherwise the migration stops) so nothing else in them changes.

-- 1 · Shopify / POS orders never take a lot that is on food-safety hold or past its expiry.
--     Before: upsert_shopify_orders allocated FEFO from v_stock_on_hand with no hold filter and used expired lots last.
--     Now: held and expired lots are skipped; what can't be covered is booked without a lot ("giacenza insufficiente"), as before.
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.upsert_shopify_orders(jsonb)'::regprocedure);
  n := regexp_replace(d,
    'for lot in select lot_number, expiry_date, qty_on_hand from fabula\.v_stock_on_hand where product_id = v_prod and qty_on_hand > 0\s+order by \(expiry_date is not null and expiry_date < current_date\), expiry_date nulls last, lot_number loop',
    'for lot in select s.lot_number, s.expiry_date, s.qty_on_hand from fabula.v_stock_on_hand s where s.product_id = v_prod and s.qty_on_hand > 0
                     and (s.expiry_date is null or s.expiry_date >= (now() at time zone ''Europe/Rome'')::date)
                     and not exists (select 1 from fabula.production_batches b where b.batch_lot = s.lot_number and b.food_safety_hold)
                   order by s.expiry_date nulls last, s.lot_number loop');
  if n = d then raise exception 'v055: lot query not found in upsert_shopify_orders'; end if;
  execute n;
end $mig$;

-- 3 · A NON CONFORME safety result is always saved, even when the sample's lot is not a production batch
--     (typo, milk lot, lot from before the system). Before: hold_lot raised "Lotto sconosciuto" and rolled back the
--     whole result (no non-conformity, no recall card). Now: known lot → held as before; unknown or missing lot → the
--     result, NC and recall card are saved, a console notice asks to block the lots by hand, and lot_on_hold says the truth.
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.record_lab_result(text,text,numeric,text,text,date,uuid,uuid)'::regprocedure);
  n := replace(d, 'v_actions text[] := ''{}'';', 'v_actions text[] := ''{}''; v_lot_found boolean := false;');
  n := replace(n,
    'perform fabula.hold_lot(s.lot_number, format(''Analisi %s non conforme (%s)'', t.code, s.sample_code), p_staff_id);',
    'if exists (select 1 from fabula.production_batches where batch_lot = s.lot_number) then
          perform fabula.hold_lot(s.lot_number, format(''Analisi %s non conforme (%s)'', t.code, s.sample_code), p_staff_id);
          v_lot_found := true;
        end if;');
  n := replace(n,
    'v_actions := array[''Lotto bloccato: non vendere'',',
    'if not v_lot_found then
        insert into fabula.notices (key, severity, title_it, items, expires_at)
        values (''lab_lot_unknown:'' || s.sample_code, ''alert'',
                format(''Analisi %s NON CONFORME: lotto %s non trovato tra i lotti di produzione · bloccare a mano i lotti interessati'', t.code, coalesce(s.lot_number, ''non indicato'')),
                jsonb_build_array(jsonb_build_object(''label_it'', format(''Campione %s · lotto %s'', s.sample_code, coalesce(s.lot_number, ''non indicato'')), ''sample_code'', s.sample_code, ''lot'', s.lot_number, ''nc_id'', v_nc)),
                now() + interval ''14 days'')
        on conflict (key) do update set resolved_at = null, expires_at = excluded.expires_at, items = excluded.items;
      end if;
      v_actions := array[case when v_lot_found then ''Lotto bloccato: non vendere''
                              when s.lot_number is null then ''Nessun lotto sul campione: individuare e bloccare a mano i lotti interessati''
                              else format(''Lotto %s NON trovato tra i lotti di produzione: individuare e bloccare a mano i lotti interessati'', s.lot_number) end,');
  n := replace(n, '''lot_on_hold'', v_nc is not null and t.kind = ''sicurezza'' and s.lot_number is not null', '''lot_on_hold'', v_lot_found');
  if n = d or position('v_lot_found := true' in n) = 0 or position('''lot_on_hold'', v_lot_found' in n) = 0 or position('lab_lot_unknown' in n) = 0 then
    raise exception 'v055: record_lab_result patterns not found';
  end if;
  execute n;
end $mig$;

-- 4a · A failed calibration puts the instrument out of service for every profile that can record it (HACCP level 2: Produzione,
--      Banco, Spedizioni…). Before: the function ran with the caller's rights and the equipment update (HACCP level 3) was
--      silently skipped by RLS, so the thermometer stayed in service and the due dates never moved.
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.record_calibration_check(text,text,text,jsonb,uuid,text,text,uuid,text,boolean,date)'::regprocedure);
  n := regexp_replace(d, '\nbegin\n', E'\nbegin\n  perform fabula.require_perm(''haccp'', 2);\n');
  if n = d then raise exception 'v055: begin not found in record_calibration_check'; end if;
  execute n;
end $mig$;
alter function fabula.record_calibration_check(text,text,text,jsonb,uuid,text,text,uuid,text,boolean,date) security definer;
revoke execute on function fabula.record_calibration_check(text,text,text,jsonb,uuid,text,text,uuid,text,boolean,date) from public, anon;
grant execute on function fabula.record_calibration_check(text,text,text,jsonb,uuid,text,text,uuid,text,boolean,date) to authenticated, service_role;

-- 4b · A CCP reading taken with an out-of-service instrument is never recorded as "ok": it becomes at least a warning,
--      the corrective note says to repeat it with a verified instrument, and the result carries equipment_out_of_service.
--      (Not refused: the tablet sends the milk-intake CCPs after the intake row, so refusing would half-save the intake.)
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.log_ccp(text,numeric,uuid,text,text,text,text)'::regprocedure);
  n := replace(d, 'v_hold boolean := false;', 'v_hold boolean := false; v_oos text;');
  n := replace(n,
    'v_res := fabula.ccp_eval(cp.min_value, cp.max_value, cp.warn_min, cp.warn_max, p_value);',
    'v_res := fabula.ccp_eval(cp.min_value, cp.max_value, cp.warn_min, cp.warn_max, p_value);
  select code into v_oos from fabula.equipment where id = v_eq and out_of_service;
  if v_oos is not null then
    if v_res = ''ok'' then v_res := ''warning''; end if;
    p_action := concat_ws('' · '', nullif(p_action, ''''), format(''Strumento %s fuori servizio: ripetere la misura con uno strumento verificato'', v_oos));
  end if;');
  n := replace(n,
    '''corrective_it'', case when v_res <> ''ok'' then cp.corrective_it end,',
    '''corrective_it'', case when v_oos is not null then format(''Strumento %s fuori servizio: ripetere la misura con uno strumento verificato. '', v_oos) else '''' end || coalesce(case when v_res <> ''ok'' then cp.corrective_it end, ''''), ''equipment_out_of_service'', v_oos,');
  if n = d or position('v_oos' in n) = 0 or position('''equipment_out_of_service''' in n) = 0 then raise exception 'v055: log_ccp patterns not found'; end if;
  execute n;
end $mig$;

-- 5 · Rejected milk (accepted = false, e.g. positive antibiotic test) can never go into a batch.
create or replace function fabula.trg_batch_milk_accepted() returns trigger language plpgsql set search_path = fabula, public as $$
declare m record;
begin
  select milk_lot, accepted, rejection_reason into m from fabula.milk_intake where id = new.milk_intake_id;
  if m.accepted is false then
    raise exception 'Latte respinto (lotto %, %): non si può usare in produzione', m.milk_lot, coalesce(m.rejection_reason, 'non conforme')
      using errcode = 'P0001';
  end if;
  return new;
end $$;
drop trigger if exists batch_milk_inputs_accepted on fabula.batch_milk_inputs;
create trigger batch_milk_inputs_accepted before insert or update of milk_intake_id on fabula.batch_milk_inputs
  for each row execute function fabula.trg_batch_milk_accepted();
revoke execute on function fabula.trg_batch_milk_accepted() from public, anon;

insert into supabase_migrations.schema_migrations (version, name) values ('20261004203100','v055_food_safety_fixes') on conflict do nothing;
