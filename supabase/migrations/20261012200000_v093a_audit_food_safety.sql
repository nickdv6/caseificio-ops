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
