-- v0.77b (05/10/2026) · Paper back-up for HACCP checks. When the tablet or the Wi-Fi is down the check is written on the
-- printed MOD sheet; later it is typed in from the tablet (🛡 Sicurezza alimentare → "Ricopia da foglio di carta") with the
-- date and time written on the sheet and who wrote it. fabula.log_ccp gains a version with p_logged_at / p_written_by:
-- source 'paper' keeps the sheet's time (at most 7 days back, never in the future) and notes who copied it and when;
-- any other source still records now(). The old signature stays and calls the new one, so the tablet, the offline queue
-- (save_ops) and the bots work as before. Limits, non-conformities and lot holds apply exactly as for a live check.

create or replace function fabula.log_ccp(p_cp_code text, p_value numeric, p_logged_at timestamptz, p_staff_id uuid DEFAULT NULL::uuid, p_batch_lot text DEFAULT NULL::text, p_action text DEFAULT NULL::text, p_source text DEFAULT 'tablet'::text, p_equipment_code text DEFAULT NULL::text, p_written_by text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'fabula', 'public', 'extensions'
AS $function$
declare v_at timestamptz := now(); v_op text; v_op_id uuid; cp fabula.haccp_control_points%rowtype; v_res fabula.haccp_result; v_batch uuid; v_log uuid; v_nc uuid; v_staff text; v_eq uuid; v_hold boolean := false; v_oos text;
begin
  -- v0.77: a check written on paper (tablet or Wi-Fi down) and typed in later keeps the time it was done
  if coalesce(p_source, 'tablet') = 'paper' then
    if p_logged_at is null or p_logged_at > now() + interval '5 minutes' or p_logged_at < now() - interval '7 days' then
      raise exception 'Data e ora del foglio non valide: al massimo 7 giorni fa, non nel futuro' using errcode = '22023';
    end if;
    v_at := p_logged_at;
  end if;
  select * into cp from fabula.haccp_control_points where code = p_cp_code and active;
  if cp.id is null then raise exception 'Punto di controllo sconosciuto o non attivo: %', p_cp_code; end if;
  if p_batch_lot is not null and p_batch_lot <> '' then
    select id into v_batch from fabula.production_batches where batch_lot = p_batch_lot;
    if v_batch is null then raise exception 'Lotto sconosciuto: %', p_batch_lot; end if;
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
      update fabula.production_batches set food_safety_hold = true, hold_at = now(), hold_reason = format('%s fuori limite (%s %s)', coalesce(cp.ccp_no, cp.code), p_value, coalesce(cp.unit, '')), hold_nc_id = v_nc,
             hold_released_at = null, hold_released_by_id = null
      where id = v_batch;
      v_hold := true;
    end if;
  end if;
  return jsonb_build_object('result', v_res, 'haccp_log_id', v_log, 'nc_id', v_nc, 'lot_on_hold', v_hold,
                            'corrective_it', case when v_oos is not null then format('Strumento %s fuori servizio: ripetere la misura con uno strumento verificato. ', v_oos) else '' end || coalesce(case when v_res <> 'ok' then cp.corrective_it end, ''), 'equipment_out_of_service', v_oos, 'limit_it', cp.critical_limit_it, 'ccp', coalesce(cp.ccp_no, cp.code));
end $function$;
revoke all on function fabula.log_ccp(text, numeric, timestamptz, uuid, text, text, text, text, text) from public, anon;
grant execute on function fabula.log_ccp(text, numeric, timestamptz, uuid, text, text, text, text, text) to authenticated, service_role;

create or replace function fabula.log_ccp(p_cp_code text, p_value numeric, p_staff_id uuid DEFAULT NULL::uuid, p_batch_lot text DEFAULT NULL::text, p_action text DEFAULT NULL::text, p_source text DEFAULT 'tablet'::text, p_equipment_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO 'fabula', 'public', 'extensions'
AS $function$
  -- v0.77: same as before; the version with p_logged_at does the work (checks typed in from paper keep their time)
  select fabula.log_ccp(p_cp_code => p_cp_code, p_value => p_value, p_logged_at => now(), p_staff_id => p_staff_id, p_batch_lot => p_batch_lot,
                        p_action => p_action, p_source => case when p_source = 'paper' then 'tablet' else p_source end, p_equipment_code => p_equipment_code)
$function$;
