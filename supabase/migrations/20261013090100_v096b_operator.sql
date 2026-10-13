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
