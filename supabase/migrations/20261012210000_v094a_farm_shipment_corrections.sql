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
