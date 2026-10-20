-- v1.10a «Sicurezza e salvataggi» (20/10/2026) · security and people (quality test 20/10, claude/quality-test-2026-10-20.md)
--   1. Item 1: the settings that steer where links point and where the database sends its keys (the app's address infra.*, the
--      access-link settings auth.*, the server functions' and webhooks' addresses, the Telegram bot) change only for who manages users.
--      A socio has Sistema 3 and could point the app's address at another site: the next access link then carried a password token
--      there, and trade.edge_url / shopify.sync_url would have sent the job keys there.
--   2. Item 2: adding a staff row went round the staff guard (BEFORE UPDATE only): a socio could add a Titolare row. A row added by
--      someone who does not manage users now has no login, no e-mail and no profile that manages users.
--   3. Someone else's Telegram that is already linked is replaced only by who manages users (a code made by a socio and used on
--      another phone replaced the person's chat, so they stopped getting alarms).
--   4. Item 9: the person's other open access links stop only when the password is saved (access_link_done, called by «welcome»);
--      before, a save that failed left this link and a newer one both dead.
--   5. Item 8: a badge scan queued on a tablet keeps its time up to labor.max_shift_hours + 12 hours (the window in which
--      close_stale_shifts leaves a shift open); a badge-out older than the open shift corrects the earlier shift the database closed by
--      itself (badge forgotten), never the new one; a scan older than the window changes nothing and tells the office. A shift open
--      longer than the maximum hours no longer counts as «in turno» on the tablet (the next scan clocks in and closes it at the maximum).

-- ============================================================================================================================
-- 1. Protected settings
-- ============================================================================================================================
create or replace function fabula.setting_protected(p_key text) returns boolean
language sql immutable set search_path = fabula, public as $$
  select p_key like 'infra.%' or p_key like 'auth.%' or (p_key like '%\_url' and p_key not like 'mkt.%' and p_key <> 'food.manuale_url') or p_key = 'notify.telegram_bot'
$$;
comment on function fabula.setting_protected(text) is 'v1.10: settings only who manages users may change (app address, access links, the addresses the database calls with its keys)';

create or replace function fabula.trg_settings_guard() returns trigger language plpgsql set search_path = fabula, public as $$
declare k text := case when tg_op = 'DELETE' then old.key else new.key end;
begin
  -- only writes made straight through the API (role authenticated/anon) are checked: the database's own functions (backups, the
  -- version watcher, releases) run as their owner
  if current_user in ('authenticated', 'anon') and (fabula.setting_protected(k) or (tg_op = 'UPDATE' and fabula.setting_protected(old.key)))
     and not coalesce(fabula.can_manage_users(), false) then
    raise exception 'Questa impostazione («%») la cambia solo chi gestisce utenti e ruoli (il titolare)', k using errcode = '42501';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;
revoke execute on function fabula.trg_settings_guard() from public, anon, authenticated;
drop trigger if exists settings_guard on fabula.settings;
create trigger settings_guard before insert or update or delete on fabula.settings for each row execute function fabula.trg_settings_guard();

-- ============================================================================================================================
-- 2. The staff guard checks new rows too
-- ============================================================================================================================
-- a separate trigger, not security definer, so «current_user» is who is writing: straight through the API it is authenticated; the
-- database's own functions and the server functions (service role, «Aggiungi una persona») are not checked here
create or replace function fabula.trg_staff_insert_guard() returns trigger language plpgsql set search_path = fabula, public as $$
begin
  -- v1.10 (quality test item 2): a row added by someone who does not manage users: no login, no e-mail (claim_staff_profile would
  -- link a login to it at the next sign-in), no profile that manages users. The update rules are in trg_staff_guard (v1.09).
  if current_user in ('authenticated', 'anon') and not coalesce(fabula.can_manage_users(), false)
     and (new.auth_user_id is not null or new.email is not null
          or exists (select 1 from fabula.app_roles r where r.code = new.app_role and r.can_manage_users)) then
    raise exception 'Le persone con accesso o email le aggiunge solo chi gestisce utenti e ruoli (Configurazione → Persone)' using errcode = '42501';
  end if;
  return new;
end $$;
revoke execute on function fabula.trg_staff_insert_guard() from public, anon, authenticated;
drop trigger if exists staff_insert_guard on fabula.staff;
create trigger staff_insert_guard before insert on fabula.staff for each row execute function fabula.trg_staff_insert_guard();

-- ============================================================================================================================
-- 3. Telegram: someone else's linked chat is replaced only by who manages users
-- ============================================================================================================================
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.notify_link_code(uuid)'::regprocedure);
  n := replace(d, $s$  if v_me is null or v_id <> v_me then perform fabula.require_perm('personale', 3); end if;
$s$, $s$  if v_me is null or v_id <> v_me then perform fabula.require_perm('personale', 3); end if;
  -- v1.10: a code for someone else whose Telegram already works would replace their chat when used on another phone (they would
  -- stop getting alarms): only who manages users may do that; the person can always make their own
  if auth.uid() is not null and (v_me is null or v_id <> v_me) and not coalesce(fabula.can_manage_users(), false)
     and exists (select 1 from fabula.notify_targets t where t.staff_id = v_id and t.chat_id is not null and t.active) then
    raise exception 'Il Telegram di questa persona è già collegato: un collegamento nuovo lo fa lei stessa dal suo menu, oppure il titolare' using errcode = '42501';
  end if;
$s$);
  if n = d then raise exception 'v110a: notify_link_code anchor not found'; end if;
  execute n;
end $mig$;

-- ============================================================================================================================
-- 4. Access links: the other open links stop when the password is saved
-- ============================================================================================================================
create or replace function fabula.access_link_bind(p_link_id uuid, p_auth_user_id uuid)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare v_staff uuid; v_other text;
begin
  select staff_id into v_staff from fabula.staff_access_links where id = p_link_id and used_at is not null and revoked_at is null;
  if v_staff is null then raise exception 'Link non trovato' using errcode = 'P0002'; end if;
  if not exists (select 1 from auth.users where id = p_auth_user_id) then raise exception 'Account non trovato' using errcode = 'P0002'; end if;
  select full_name into v_other from fabula.staff where auth_user_id = p_auth_user_id and id <> v_staff;
  if v_other is not null then
    raise exception 'Questa email è già l''accesso di un''altra persona' using errcode = 'P0409';
  end if;
  update fabula.staff set auth_user_id = p_auth_user_id where id = v_staff and auth_user_id is distinct from p_auth_user_id;
  -- v1.10 (quality test item 9): the other open links are no longer revoked here but in access_link_done, once the password is saved
  return jsonb_build_object('ok', true, 'staff_id', v_staff);
end $$;

create or replace function fabula.access_link_done(p_link_id uuid)
returns integer language plpgsql security definer set search_path = fabula, public as $$
declare v_staff uuid; n int;
begin
  select staff_id into v_staff from fabula.staff_access_links where id = p_link_id and used_at is not null and revoked_at is null;
  if v_staff is null then return 0; end if;
  update fabula.staff_access_links set revoked_at = now(), revoked_why = 'password già scelta'
   where staff_id = v_staff and id <> p_link_id and used_at is null and revoked_at is null;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function fabula.access_link_done(uuid) from public, anon, authenticated;
grant execute on function fabula.access_link_done(uuid) to service_role;

-- ============================================================================================================================
-- 5. A late badge-out that belongs to the shift the database closed by itself
-- ============================================================================================================================
-- the time a badge scan is kept with: the tablet's (queued scans, measured by save_ops) up to max hours + 12; «too old» beyond that
create or replace function fabula._badge_time(p_at timestamptz) returns timestamptz
language sql stable set search_path = fabula, public as $$
  select case when p_at is null or p_at > now() + interval '5 minutes' then now()
              when p_at < now() - make_interval(hours => fabula.setting_num('labor.max_shift_hours', 12)::int + 12) then null
              else least(p_at, now()) end
$$;
revoke all on function fabula._badge_time(timestamptz) from public, anon, authenticated;

create or replace function fabula._badge_too_old(p_staff record, p_at timestamptz, p_kind text) returns jsonb
language plpgsql set search_path = fabula, public as $$
begin
  perform fabula.post_bot_message('tablet', 'warn', format('Badge di %s arrivato troppo tardi', p_staff.full_name),
    format('Il badge di %s di %s (%s) è arrivato dal tablet più di %s ore dopo: non è stato registrato. Segna il turno a mano in Console → Personale.',
           case p_kind when 'in' then 'entrata' else 'uscita' end, p_staff.full_name, to_char(p_at at time zone 'Europe/Rome', 'DD/MM HH24:MI'),
           fabula.setting_num('labor.max_shift_hours', 12)::int + 12));
  return jsonb_build_object('action', 'none', 'too_old', true, 'staff_id', p_staff.id, 'staff', p_staff.full_name);
end $$;
revoke all on function fabula._badge_too_old(record, timestamptz, text) from public, anon, authenticated;

create or replace function fabula.badge_in(p_badge text, p_staff_id uuid default null, p_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare v_staff record; v_open record; v_max numeric := fabula.setting_num('labor.max_shift_hours', 12); v_at timestamptz; v_last timestamptz;
begin
  perform fabula.require_perm('comune', 2);
  select * into v_staff from fabula.staff where active and (badge_code = p_badge or id = p_staff_id) limit 1;
  if v_staff is null then raise exception 'Badge sconosciuto o persona disattivata: %', coalesce(p_badge, p_staff_id::text) using errcode = 'P0002'; end if;
  v_at := fabula._badge_time(p_at);                        -- v1.10: the same window as the badge-out (it was 12 hours, then «now»)
  if v_at is null then return fabula._badge_too_old(v_staff, p_at, 'in'); end if;
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
declare v_staff record; v_open record; v_prev record; v_at timestamptz; v_late boolean;
        v_max numeric := fabula.setting_num('labor.max_shift_hours', 12);
begin
  perform fabula.require_perm('comune', 2);
  select * into v_staff from fabula.staff where (badge_code = p_badge or id = p_staff_id) limit 1;
  if v_staff is null then raise exception 'Badge sconosciuto: %', coalesce(p_badge, p_staff_id::text) using errcode = 'P0002'; end if;
  -- v1.10: a time from the tablet is kept up to the window in which close_stale_shifts leaves a shift open (max hours + 12): a tablet
  -- offline overnight sends a badge-out older than 12 hours (it used to become «now» and close today's new shift); older than that
  -- it changes nothing and the office is told
  v_at := fabula._badge_time(p_at);
  if v_at is null then return fabula._badge_too_old(v_staff, p_at, 'out'); end if;
  v_late := v_at < now() - interval '5 minutes';
  select * into v_open from fabula.shifts where staff_id = v_staff.id and clock_out is null order by clock_in desc limit 1;
  -- v1.10 (quality test item 8): a badge-out sent late (queued on a tablet without network) that is older than the open shift, or
  -- comes when no shift is open, belongs to the shift that was running at that time: the last one started before it. If the database
  -- closed that one by itself at the maximum hours (badge forgotten), its real end is written; if it was closed normally (badge-out
  -- on another tablet), nothing changes. The open shift is never closed at a time before it started (it was closed at 0 hours).
  if v_late and (v_open.id is null or v_at < v_open.clock_in) then
    select * into v_prev from fabula.shifts
     where staff_id = v_staff.id and clock_in <= v_at and clock_out is not null
     order by clock_in desc limit 1;
    if v_prev.id is not null and v_prev.notes like '%chiuso automaticamente%' and v_prev.clock_out = v_prev.clock_in + make_interval(hours => v_max::int)
       and v_at <= v_prev.clock_in + make_interval(hours => v_max::int + 12) then
      update fabula.shifts set clock_out = v_at,
             notes = concat_ws(' · ', notes, 'uscita corretta con l''ora del tablet (inviata senza rete): ' || to_char(now() at time zone 'Europe/Rome', 'DD/MM HH24:MI'))
       where id = v_prev.id returning * into v_prev;
      return jsonb_build_object('action', 'out', 'corrected', true, 'staff_id', v_staff.id, 'staff', v_staff.full_name, 'at', v_prev.clock_out,
                                'hours', v_prev.hours, 'still_open_since', v_open.clock_in);
    end if;
    return jsonb_build_object('action', 'none', 'late', true, 'staff_id', v_staff.id, 'staff', v_staff.full_name, 'still_open_since', v_open.clock_in);
  end if;
  if v_open.id is null then return jsonb_build_object('action', 'none', 'staff_id', v_staff.id, 'staff', v_staff.full_name); end if;
  -- v1.10: a shift open longer than the maximum hours was a forgotten badge-out: it ends at the maximum, as the database would close it
  if v_at > v_open.clock_in + make_interval(hours => v_max::int) then
    update fabula.shifts set clock_out = clock_in + make_interval(hours => v_max::int), notes = concat_ws(' · ', notes, 'chiuso automaticamente (badge dimenticato)')
     where id = v_open.id returning * into v_open;
    return jsonb_build_object('action', 'out', 'auto_closed', true, 'staff_id', v_staff.id, 'staff', v_staff.full_name, 'at', v_open.clock_out, 'hours', v_open.hours);
  end if;
  update fabula.shifts set clock_out = greatest(v_at, clock_in),
         notes = case when v_late then concat_ws(' · ', notes, 'uscita registrata dopo, con l''ora del tablet (senza rete): ' || to_char(now() at time zone 'Europe/Rome', 'DD/MM HH24:MI')) else notes end
   where id = v_open.id returning * into v_open;
  return jsonb_build_object('action', 'out', 'staff_id', v_staff.id, 'staff', v_staff.full_name, 'at', v_open.clock_out, 'hours', v_open.hours);
end $$;

-- a shift open longer than the maximum hours is a forgotten badge-out: not «in turno» on the tablet (the person's next scan clocks in,
-- and badge_in closes the old shift at the maximum); before, the tablet showed «in turno dalle 06:00» the next morning
create or replace function fabula.floor_operators()
returns table (id uuid, full_name text, job_role text, badge_code text, has_pin boolean, on_shift boolean, shift_since timestamptz)
language sql stable security definer set search_path = fabula, public as $$
  select s.id, s.full_name, s.role::text, s.badge_code,
         exists (select 1 from fabula.staff_pins p where p.staff_id = s.id),
         sh.clock_in is not null, sh.clock_in
    from fabula.staff s
    left join lateral (select clock_in from fabula.shifts x where x.staff_id = s.id and x.clock_out is null
                          and x.clock_in > now() - make_interval(hours => fabula.setting_num('labor.max_shift_hours', 12)::int)
                        order by x.clock_in desc limit 1) sh on true
   where s.active and fabula.can('comune', 2)
   order by s.full_name
$$;
create or replace function fabula.floor_open_shifts()
returns table (full_name text, hours_so_far numeric) language sql stable security definer set search_path = fabula, public as $$
  select st.full_name, round(extract(epoch from now() - s.clock_in) / 3600.0, 1)
    from fabula.shifts s join fabula.staff st on st.id = s.staff_id
   where s.clock_out is null and st.active and (fabula.my_staff_id() is not null or auth.uid() is null)
     and s.clock_in > now() - make_interval(hours => fabula.setting_num('labor.max_shift_hours', 12)::int)
   order by s.clock_in
$$;
