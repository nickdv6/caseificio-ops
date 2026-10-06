-- v0.81 (06/10/2026): real login state for staff.
-- Bug: the console (Utenti e ruoli) showed "collegato" and the go-live board counted a login as soon as an invite was SENT,
-- because invite-user links staff.auth_user_id to the new (still unconfirmed) auth user immediately.
-- Now the state comes from auth.users: attivo only after the person has actually signed in and chosen a password.

insert into fabula.settings (key, value, description, data_type, sort)
values ('auth.link_hours', '1', 'Validità in ore del link di invito/reset email (deve coincidere con Supabase → Authentication → Email OTP Expiration).', 'number', 118)
on conflict (key) do nothing;

create or replace function fabula.staff_login_rows()
returns table(staff_id uuid, state text, link_sent_at timestamptz, link_expires_at timestamptz, last_sign_in_at timestamptz)
language sql stable security definer set search_path = fabula, public as $$
  with x as (
    select s.id, s.active, s.email, s.auth_user_id, u.id as uid, u.banned_until, u.last_sign_in_at, u.email_confirmed_at,
           coalesce(u.encrypted_password, '') <> '' as has_pw,
           greatest(u.invited_at, u.recovery_sent_at, u.confirmation_sent_at) as sent_at,
           coalesce(fabula._setting('auth.link_hours')::numeric, 1) as hrs
    from fabula.staff s left join auth.users u on u.id = s.auth_user_id)
  select id,
    case when not active or banned_until > now() then 'disattivato'
         when uid is null then case when email is null then 'senza_email' else 'da_invitare' end
         when last_sign_in_at is not null and email_confirmed_at is not null and has_pw then 'attivo'
         when last_sign_in_at is not null then 'senza_password'
         when sent_at > now() - make_interval(secs => hrs * 3600) then 'invitato'
         else 'link_scaduto' end,
    sent_at, sent_at + make_interval(secs => hrs * 3600), last_sign_in_at
  from x;
$$;
revoke all on function fabula.staff_login_rows() from public, anon, authenticated;
grant execute on function fabula.staff_login_rows() to service_role;

-- console wrapper: only for profiles that manage users (titolare)
create or replace function fabula.staff_logins()
returns setof jsonb language plpgsql stable security definer set search_path = fabula, public as $$
begin
  if auth.role() <> 'service_role' and not fabula.can_manage_users() then
    raise exception 'Solo il titolare può vedere lo stato degli accessi' using errcode = '42501';
  end if;
  return query select to_jsonb(r) from fabula.staff_login_rows() r;
end $$;
revoke all on function fabula.staff_logins() from public, anon;
grant execute on function fabula.staff_logins() to authenticated, service_role;

-- go-live board: "second_login" counts people who have really signed in, not invites sent
do $$
declare v text; n text;
begin
  select pg_get_functiondef('fabula.ops_dashboard()'::regprocedure) into v;
  n := replace(v, 'from fabula.staff where active and auth_user_id is not null)',
                  'from fabula.staff_login_rows() where state = ''attivo'')');
  n := replace(n, ' staff can log in''', ' staff have signed in (invites not yet accepted do not count)''');
  if n = v then raise exception 'ops_dashboard: login check not found, nothing patched'; end if;
  execute n;
end $$;
