-- v1.09a «Persone» (19/10/2026) · staff onboarding and offboarding (re-score 15/10, «Staff & rota»; audit C-13, C-14, C-15, C-18)
--   1. Personal access links. Supabase's own invite and reset links last at most 24 hours (Emilio's lapsed twice unused). The app now
--      makes its own link: valid for auth.link_days (7), until it is used or a newer one is made. Only a hash of it is kept. It is
--      used up only when the person saves the password (server function «welcome»), so a WhatsApp or mail preview cannot spend it.
--   2. Login state (Configurazione → Persone) reads these links as well as Supabase's e-mails.
--   3. C-13: the e-mail of someone who already has a login changes only through «Cambia email» (server function invite-user, which
--      changes the login e-mail too); a plain edit of the row is refused instead of leaving two different addresses.
--   4. C-14: switching someone off closes their open shift, removes their future rota, cancels their links, Telegram and PIN, and
--      lists the settings and deadlines that still name them. Shifts left open past labor.max_shift_hours close by themselves
--      (checked every hour, 12 hours after that, so a queued offline badge-out still lands; before, it happened only at the
--      person's next badge scan).
--   5. Telegram links for someone's phone last auth.link_days too (they lasted 24 hours).

-- ============================================================================================================================
-- 1. Settings
-- ============================================================================================================================
insert into fabula.settings (key, value, description, data_type, sort, min_value, max_value, unit)
values ('auth.link_days', '7', 'Validità in giorni dei link di accesso personali (WhatsApp o email dal tuo telefono) e dei link per collegare Telegram', 'number', 119, 1, 30, 'giorni')
on conflict (key) do nothing;
update fabula.settings set description = 'Validità in ore dei link che manda Supabase per email («Password dimenticata?»): deve coincidere con Supabase → Authentication → Email OTP Expiration'
 where key = 'auth.link_hours';
update fabula.settings set value = '24' where key = 'auth.link_hours' and value = '1';   -- C-18: the seed of v0.81 was 1 (the live value is 24)

-- ============================================================================================================================
-- 2. Personal access links
-- ============================================================================================================================
create table if not exists fabula.staff_access_links (
  id          uuid primary key default gen_random_uuid(),
  staff_id    uuid not null references fabula.staff(id) on delete cascade,
  token_hash  text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  purpose     text not null check (purpose in ('invite', 'reset')),
  created_at  timestamptz not null default now(),
  created_by  uuid references fabula.staff(id),
  expires_at  timestamptz not null,
  used_at     timestamptz,
  revoked_at  timestamptz,
  revoked_why text
);
comment on table fabula.staff_access_links is 'v1.09 (staff onboarding): personal links to choose a password (benvenuto.html#invito=…). Only the sha256 of the link is kept. Read and written only by the server functions invite-user and welcome (service role) through the functions below.';
create index if not exists staff_access_links_staff_idx on fabula.staff_access_links (staff_id, created_at desc);
alter table fabula.staff_access_links enable row level security;
revoke all on fabula.staff_access_links from public, anon, authenticated;
grant all on fabula.staff_access_links to service_role;

-- a new link for a person (invite-user, after checking the caller manages users): older open links stop working
create or replace function fabula.access_link_new(p_staff_id uuid, p_token_hash text, p_by uuid default null)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare s record; v_pw boolean; v_purpose text; v_exp timestamptz; v_id uuid;
begin
  select st.id, st.full_name, st.email, st.active, st.auth_user_id, r.name_it as role_name, r.home into s
    from fabula.staff st left join fabula.app_roles r on r.code = st.app_role where st.id = p_staff_id;
  if s.id is null then raise exception 'Persona non trovata' using errcode = 'P0002'; end if;
  if not s.active then raise exception 'Questa persona è disattivata: prima riattivala' using errcode = 'P0001'; end if;
  if s.email is null then raise exception 'Manca l''email: aggiungila prima di creare il link (serve per entrare)' using errcode = 'P0001'; end if;
  if p_token_hash !~ '^[0-9a-f]{64}$' then raise exception 'Link non valido' using errcode = '22023'; end if;
  select coalesce(u.encrypted_password, '') <> '' and u.email_confirmed_at is not null into v_pw from auth.users u where u.id = s.auth_user_id;
  v_purpose := case when coalesce(v_pw, false) then 'reset' else 'invite' end;
  v_exp := now() + make_interval(days => greatest(1, least(30, coalesce(fabula.setting_num('auth.link_days', 7), 7)))::int);
  update fabula.staff_access_links set revoked_at = now(), revoked_why = 'sostituito da un link nuovo'
   where staff_id = s.id and used_at is null and revoked_at is null;
  insert into fabula.staff_access_links (staff_id, token_hash, purpose, created_by, expires_at)
  values (s.id, p_token_hash, v_purpose, p_by, v_exp) returning id into v_id;
  return jsonb_build_object('id', v_id, 'purpose', v_purpose, 'expires_at', v_exp, 'full_name', s.full_name,
                            'first_name', split_part(s.full_name, ' ', 1), 'role_name', s.role_name, 'home', s.home, 'email', s.email,
                            'company', coalesce(nullif(fabula.setting_text('company.name'), ''), 'Caseificio'));
end $$;

-- what a link is (the welcome page greets the person by name before they choose the password)
create or replace function fabula.access_link_check(p_token_hash text)
returns jsonb language plpgsql stable security definer set search_path = fabula, public as $$
declare l record; s record;
begin
  select * into l from fabula.staff_access_links where token_hash = p_token_hash;
  if l.id is null then return jsonb_build_object('ok', false, 'reason', 'unknown'); end if;
  select st.id, st.full_name, st.email, st.active, st.auth_user_id, st.app_role, r.name_it as role_name, r.home into s
    from fabula.staff st left join fabula.app_roles r on r.code = st.app_role where st.id = l.staff_id;
  return jsonb_build_object(
    'ok', l.used_at is null and l.revoked_at is null and l.expires_at > now() and coalesce(s.active, false),
    'reason', case when l.used_at is not null then 'used'
                   when l.revoked_at is not null and l.revoked_why = 'sostituito da un link nuovo' then 'replaced'
                   when l.revoked_at is not null then 'revoked'
                   when l.expires_at <= now() then 'expired'
                   when not coalesce(s.active, false) then 'inactive' end,
    'link_id', l.id, 'purpose', l.purpose, 'expires_at', l.expires_at, 'used_at', l.used_at,
    'staff_id', s.id, 'full_name', s.full_name, 'first_name', split_part(s.full_name, ' ', 1), 'email', s.email,
    'auth_user_id', s.auth_user_id, 'role_name', s.role_name, 'home', s.home,
    'company', coalesce(nullif(fabula.setting_text('company.name'), ''), 'Caseificio'));
end $$;

-- the link is used now (atomically: two taps on «Salva» cannot both set a password)
create or replace function fabula.access_link_claim(p_token_hash text)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare v_id uuid;
begin
  update fabula.staff_access_links l set used_at = now()
   where l.token_hash = p_token_hash and l.used_at is null and l.revoked_at is null and l.expires_at > now()
     and exists (select 1 from fabula.staff s where s.id = l.staff_id and s.active)
  returning l.id into v_id;
  return fabula.access_link_check(p_token_hash) || jsonb_build_object('claimed', v_id is not null);
end $$;

-- the password could not be set: the link works again
create or replace function fabula.access_link_unclaim(p_link_id uuid)
returns boolean language sql security definer set search_path = fabula, public as $$
  with u as (update fabula.staff_access_links l set used_at = null
              where l.id = p_link_id and l.used_at > now() - interval '10 minutes' and l.revoked_at is null
                and not exists (select 1 from fabula.staff_access_links n where n.staff_id = l.staff_id and n.created_at > l.created_at)
             returning 1)
  select exists (select 1 from u)
$$;

-- the login the link will set the password of, linked to the person BEFORE anything is written to it (review H1): a login that
-- belongs to someone else is refused (errcode P0409), so a link can never set another person's password
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
  update fabula.staff_access_links set revoked_at = now(), revoked_why = 'password già scelta'
   where staff_id = v_staff and id <> p_link_id and used_at is null and revoked_at is null;
  return jsonb_build_object('ok', true, 'staff_id', v_staff);
end $$;

revoke all on function fabula.access_link_new(uuid, text, uuid) from public, anon, authenticated;
revoke all on function fabula.access_link_check(text) from public, anon, authenticated;
revoke all on function fabula.access_link_claim(text) from public, anon, authenticated;
revoke all on function fabula.access_link_unclaim(uuid) from public, anon, authenticated;
revoke all on function fabula.access_link_bind(uuid, uuid) from public, anon, authenticated;
grant execute on function fabula.access_link_new(uuid, text, uuid), fabula.access_link_check(text), fabula.access_link_claim(text),
  fabula.access_link_unclaim(uuid), fabula.access_link_bind(uuid, uuid) to service_role;

-- ============================================================================================================================
-- 3. Login state: the app's own links count as well as Supabase's e-mails
-- ============================================================================================================================
drop function if exists fabula.staff_login_rows();
create function fabula.staff_login_rows()
returns table(staff_id uuid, state text, link_sent_at timestamptz, link_expires_at timestamptz, last_sign_in_at timestamptz,
              link_kind text, link_open boolean, link_purpose text, link_by text)
language sql stable security definer set search_path = fabula, public as $$
  with x as (
    select s.id, s.active, s.email, s.auth_user_id, u.id as uid, u.banned_until, u.last_sign_in_at, u.email_confirmed_at,
           coalesce(u.encrypted_password, '') <> '' as has_pw,
           greatest(u.invited_at, u.recovery_sent_at, u.confirmation_sent_at) as mail_at,
           make_interval(secs => coalesce(fabula._setting('auth.link_hours')::numeric, 24) * 3600) as mail_valid,
           l.created_at as l_at, l.expires_at as l_exp, l.used_at as l_used, l.revoked_at as l_rev, l.purpose as l_purpose, cb.full_name as l_by
      from fabula.staff s
      left join auth.users u on u.id = s.auth_user_id
      left join lateral (select * from fabula.staff_access_links a where a.staff_id = s.id order by a.created_at desc limit 1) l on true
      left join fabula.staff cb on cb.id = l.created_by),
  y as (select x.*, (l_at is not null and l_used is null and l_rev is null and l_exp > now()) as l_open,
               (l_at is not null and l_at >= coalesce(mail_at, '-infinity'::timestamptz)) as l_newer from x)
  select id,
    case when not active or banned_until > now() then 'disattivato'
         when uid is not null and has_pw and email_confirmed_at is not null and (last_sign_in_at is not null or l_used is not null) then 'attivo'
         when l_open then 'invitato'
         when uid is null and email is null then 'senza_email'
         when last_sign_in_at is not null then 'senza_password'
         when uid is not null and mail_at > now() - mail_valid and not l_newer then 'invitato'
         when uid is null and l_at is null then 'da_invitare'
         else 'link_scaduto' end,
    case when l_newer then l_at else mail_at end,
    case when l_newer then l_exp else mail_at + mail_valid end,
    last_sign_in_at,
    case when l_newer then 'link' when mail_at is not null then 'email' end,
    coalesce(l_open, false), l_purpose, l_by
  from y;
$$;
revoke all on function fabula.staff_login_rows() from public, anon, authenticated;
grant execute on function fabula.staff_login_rows() to service_role;

-- ============================================================================================================================
-- 4. C-13: the e-mail of someone with a login changes only with «Cambia email» (the server function changes both)
-- ============================================================================================================================
create or replace function fabula.trg_staff_guard() returns trigger language plpgsql security definer set search_path = fabula, public as $$
begin
  if auth.uid() is not null and (new.app_role is distinct from old.app_role or new.email is distinct from old.email or new.auth_user_id is distinct from old.auth_user_id
                                 or new.active is distinct from old.active)
     and not exists (select 1 from fabula.staff s join fabula.app_roles r on r.code = s.app_role where s.auth_user_id = auth.uid() and s.active and r.can_manage_users) then
    raise exception 'Solo chi gestisce utenti e ruoli può cambiare profilo, email o attivazione' using errcode = '42501';
  end if;
  -- v1.09 (audit C-13): a plain edit of the e-mail left the login on the old address, and «Reimposta password» then made a second account
  if auth.uid() is not null and new.email is distinct from old.email and new.auth_user_id is not null
     and exists (select 1 from auth.users u where u.id = new.auth_user_id and lower(u.email) is distinct from lower(new.email)) then
    raise exception 'L''email di chi ha già un accesso si cambia con «Cambia email»: così cambia anche l''email con cui entra' using errcode = 'P0001';
  end if;
  return new;
end $$;
revoke execute on function fabula.trg_staff_guard() from public, anon, authenticated;

-- ============================================================================================================================
-- 5. C-14: switching someone off
-- ============================================================================================================================
-- what «Disattiva» will do (the confirmation in Configurazione lists it before anything happens)
create or replace function fabula.staff_offboard_preview(p_staff_id uuid)
returns jsonb language plpgsql stable security definer set search_path = fabula, public as $$
declare s record; v_today date := (now() at time zone 'Europe/Rome')::date;
begin
  if auth.role() <> 'service_role' and not fabula.can_manage_users() then
    raise exception 'Solo chi gestisce utenti e ruoli può disattivare una persona' using errcode = '42501';
  end if;
  select id, full_name, email, active into s from fabula.staff where id = p_staff_id;
  if s.id is null then raise exception 'Persona non trovata' using errcode = 'P0002'; end if;
  return jsonb_build_object(
    'staff_id', s.id, 'full_name', s.full_name, 'active', s.active, 'self', s.id = fabula.my_staff_id(),
    'open_shift_since', (select min(clock_in) from fabula.shifts where staff_id = s.id and clock_out is null),
    'future_rota', (select count(*) from fabula.rota_entries where staff_id = s.id and work_date > v_today),
    'open_links', (select count(*) from fabula.staff_access_links where staff_id = s.id and used_at is null and revoked_at is null and expires_at > now()),
    'telegram', exists (select 1 from fabula.notify_targets where staff_id = s.id and (chat_id is not null or link_expires > now())),
    'pin', exists (select 1 from fabula.staff_pins where staff_id = s.id),
    'mentions', fabula._staff_mentions(s.full_name, s.email));
end $$;

-- settings and open deadlines that still name the person (shown, never changed by itself)
create or replace function fabula._staff_mentions(p_name text, p_email text)
returns jsonb language sql stable security definer set search_path = fabula, public as $$
  -- strpos, not ILIKE: «_» or «\» in a name or an e-mail are plain characters (review L5)
  select coalesce(jsonb_agg(m order by m->>'kind', m->>'what'), '[]'::jsonb) from (
    select jsonb_build_object('kind', 'parametro', 'what', coalesce(description, key), 'where', 'Configurazione → Parametri') as m
      from fabula.settings
     where coalesce(data_type, 'text') = 'text' and length(coalesce(p_name, '')) >= 3
       and (strpos(lower(value), lower(p_name)) > 0 or (coalesce(p_email, '') <> '' and strpos(lower(value), lower(p_email)) > 0))
    union all
    select jsonb_build_object('kind', 'scadenza', 'what', subject_it, 'where', 'Configurazione → Macchine e scadenze')
      from fabula.compliance_deadlines
     where done_on is null and length(coalesce(p_name, '')) >= 3
       and (strpos(lower(coalesce(responsible, '')), lower(p_name)) > 0 or strpos(lower(coalesce(contact, '')), lower(p_name)) > 0)) z
$$;

-- «Disattiva»: one transaction. The login itself is blocked by the server function (invite-user) right after.
create or replace function fabula.staff_offboard(p_staff_id uuid)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare s record; v_today date := (now() at time zone 'Europe/Rome')::date; v_max numeric := fabula.setting_num('labor.max_shift_hours', 12);
        v_shift int; v_rota int; v_links int; v_tg boolean; v_pin boolean; v_mentions jsonb;
begin
  if auth.role() <> 'service_role' and not fabula.can_manage_users() then
    raise exception 'Solo chi gestisce utenti e ruoli può disattivare una persona' using errcode = '42501';
  end if;
  select id, full_name, email, active into s from fabula.staff where id = p_staff_id for update;
  if s.id is null then raise exception 'Persona non trovata' using errcode = 'P0002'; end if;
  if s.id = fabula.my_staff_id() then raise exception 'Non puoi disattivare te stesso' using errcode = 'P0001'; end if;
  update fabula.staff set active = false where id = s.id;
  -- an open shift ends now, or at the most after labor.max_shift_hours
  update fabula.shifts set clock_out = least(now(), clock_in + make_interval(hours => v_max::int)),
         notes = concat_ws(' · ', notes, 'chiuso alla disattivazione della persona')
   where staff_id = s.id and clock_out is null;
  get diagnostics v_shift = row_count;
  delete from fabula.rota_entries where staff_id = s.id and work_date > v_today;
  get diagnostics v_rota = row_count;
  update fabula.staff_access_links set revoked_at = now(), revoked_why = 'persona disattivata'
   where staff_id = s.id and used_at is null and revoked_at is null;
  get diagnostics v_links = row_count;
  with t as (update fabula.notify_targets set chat_id = null, tg_name = null, linked_at = null, link_code = null, link_expires = null,
                    active = false, updated_at = now()
              where staff_id = s.id and (chat_id is not null or link_code is not null) returning 1)
  select exists (select 1 from t) into v_tg;
  with p as (delete from fabula.staff_pins where staff_id = s.id returning 1) select exists (select 1 from p) into v_pin;
  v_mentions := fabula._staff_mentions(s.full_name, s.email);
  return jsonb_build_object('ok', true, 'staff_id', s.id, 'full_name', s.full_name, 'was_active', s.active,
    'shift_closed', v_shift > 0, 'rota_removed', v_rota, 'links_revoked', v_links, 'telegram_unlinked', v_tg, 'pin_removed', v_pin,
    'mentions', v_mentions);
end $$;

revoke all on function fabula.staff_offboard_preview(uuid) from public, anon;
revoke all on function fabula._staff_mentions(text, text) from public, anon, authenticated;
revoke all on function fabula.staff_offboard(uuid) from public, anon;
grant execute on function fabula.staff_offboard_preview(uuid), fabula.staff_offboard(uuid) to authenticated, service_role;
grant execute on function fabula._staff_mentions(text, text) to service_role;

-- shifts left open past labor.max_shift_hours close by themselves (every hour), as the setting says. They close at clock-in +
-- max hours, but only 12 hours after that: badge_out accepts a tablet's queued scan up to 12 hours late with its own time, and a
-- shift closed earlier would turn that real badge-out into «nessun turno aperto» and the shift into max hours (review M1)
create or replace function fabula.close_stale_shifts()
returns integer language plpgsql security definer set search_path = fabula, public as $$
declare v_max numeric := fabula.setting_num('labor.max_shift_hours', 12); n int;
begin
  update fabula.shifts set clock_out = clock_in + make_interval(hours => v_max::int),
         notes = concat_ws(' · ', notes, 'chiuso automaticamente (badge dimenticato)')
   where clock_out is null and clock_in < now() - make_interval(hours => v_max::int + 12);
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function fabula.close_stale_shifts() from public, anon, authenticated;
grant execute on function fabula.close_stale_shifts() to service_role;
select cron.schedule('fabula_close_stale_shifts', '7 * * * *', $c$select fabula.close_stale_shifts()$c$);
insert into fabula.cron_jobs_expected (jobname, schedule, purpose_it) values
  ('fabula_close_stale_shifts', '7 * * * *', 'Chiude i turni rimasti aperti oltre le ore massime (badge di uscita dimenticato)')
on conflict (jobname) do update set schedule = excluded.schedule, purpose_it = excluded.purpose_it;

-- the tablet's «In turno» lists only people who are still active
create or replace function fabula.floor_open_shifts()
returns table (full_name text, hours_so_far numeric) language sql stable security definer set search_path = fabula, public as $$
  select st.full_name, round(extract(epoch from now() - s.clock_in) / 3600.0, 1)
    from fabula.shifts s join fabula.staff st on st.id = s.staff_id
   where s.clock_out is null and st.active and (fabula.my_staff_id() is not null or auth.uid() is null)
   order by s.clock_in
$$;
revoke execute on function fabula.floor_open_shifts() from public, anon;
grant execute on function fabula.floor_open_shifts() to authenticated, service_role;

-- ============================================================================================================================
-- 6. Telegram links last auth.link_days (they lasted 24 hours)
-- ============================================================================================================================
create or replace function fabula.notify_link_code(p_staff_id uuid default null)
returns jsonb language plpgsql security definer set search_path = fabula, public, extensions as $$
declare v_me uuid := fabula.my_staff_id(); v_id uuid := coalesce(p_staff_id, fabula.my_staff_id()); v_code text; s record;
        v_exp timestamptz := now() + make_interval(days => greatest(1, least(30, coalesce(fabula.setting_num('auth.link_days', 7), 7)))::int);
begin
  if v_id is null then raise exception 'Persona non trovata' using errcode = 'P0002'; end if;
  if v_me is null or v_id <> v_me then perform fabula.require_perm('personale', 3); end if;
  select id, full_name, app_role, active into s from fabula.staff where id = v_id;
  if not coalesce(s.active, false) then raise exception 'Persona non attiva' using errcode = 'P0002'; end if;
  v_code := encode(extensions.gen_random_bytes(9), 'hex');
  insert into fabula.notify_targets (staff_id, topics, link_code, link_expires)
  values (v_id, case s.app_role when 'titolare' then '{food_safety,infra,decisions}'::text[] when 'socio' then '{food_safety,decisions}'::text[] else '{food_safety}'::text[] end,
          v_code, v_exp)
  on conflict (staff_id) do update set link_code = excluded.link_code, link_expires = excluded.link_expires, active = true, updated_at = now();
  if coalesce(fabula.setting_text('notify.webhook_url'), '') = '' then   -- first link ever: let the function register itself with Telegram now
    perform net.http_post(url := fabula.setting_text('notify.function_url'), body := jsonb_build_object('op', 'dispatch'),
                          headers := jsonb_build_object('Content-Type', 'application/json'), timeout_milliseconds := 30000);
  end if;
  return jsonb_build_object('code', v_code, 'url', 'https://t.me/' || fabula.setting_text('notify.telegram_bot') || '?start=' || v_code,
                            'expires', v_exp, 'staff', s.full_name);
end $$;

-- ============================================================================================================================
-- 7. Security scan: the reasons
-- ============================================================================================================================
insert into fabula.security_accepted (key, reason) values
  ('rls_enabled_no_policy:fabula.staff_access_links', 'by design (v1.09): personal access links are read and written only by the server functions invite-user and welcome (service role) through access_link_*; only a sha256 of each link is stored'),
  ('authenticated_security_definer_function_executable:fabula.staff_offboard_preview(p_staff_id uuid)', 'by design (v1.09, audit C-14): only for a profile that manages users (can_manage_users); lists what «Disattiva» will do'),
  ('authenticated_security_definer_function_executable:fabula.staff_offboard(p_staff_id uuid)', 'by design (v1.09, audit C-14): only for a profile that manages users (can_manage_users), never on oneself; switches the person off and closes their shift, future rota, links, Telegram and PIN in one transaction')
on conflict (key) do update set reason = excluded.reason;
