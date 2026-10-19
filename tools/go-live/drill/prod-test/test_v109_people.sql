-- v1.09 «Persone»: personal access links, login state, C-13 e-mail guard, C-14 offboarding, stale shifts · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh p109
--   su postgres -c "psql -d p109 -f tools/go-live/drill/prod-test/test_v109_people.sql" | grep -E "PASS|FAIL"
-- (the server functions and pages are tested in the browser: tools/go-live/drill/tablet-test/v109_e2e.py)
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
create or replace function pg_temp.h(t text) returns text language sql as $$ select encode(sha256(convert_to(t, 'UTF8')), 'hex') $$;
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return null; exception when others then return sqlerrm; end $$;

-- people: a titolare with a login (M), a new person without login (A), a person with a password (B), someone to switch off (C)
insert into auth.users (id, email, email_confirmed_at, encrypted_password, last_sign_in_at) values
  ('00000000-0000-4000-a000-0000000109a1', 'titolare109@example.it', now(), 'x', now()),
  ('00000000-0000-4000-a000-0000000109b1', 'bruna109@example.it', now(), 'x', now()),
  ('00000000-0000-4000-a000-0000000109c1', 'carlo109@example.it', now(), 'x', now());
insert into fabula.staff (id, full_name, role, app_role, email, active, auth_user_id) values
  ('00000000-0000-4000-b000-0000000109a0', 'Mario Titolare', 'owner', 'titolare', 'titolare109@example.it', true, '00000000-0000-4000-a000-0000000109a1'),
  ('00000000-0000-4000-b000-0000000109aa', 'Anna Nuova', 'operaio', 'produzione', 'anna109@example.it', true, null),
  ('00000000-0000-4000-b000-0000000109b0', 'Bruna Attiva', 'commesso', 'banco', 'bruna109@example.it', true, '00000000-0000-4000-a000-0000000109b1'),
  ('00000000-0000-4000-b000-0000000109c0', 'Carlo Uscente', 'operaio', 'produzione', 'carlo109@example.it', true, '00000000-0000-4000-a000-0000000109c1');

-- ---------------------------------------------------------------- 1. settings
select pg_temp.ck('auth.link_days = 7, between 1 and 30 days',
  (select value = '7' and min_value = 1 and max_value = 30 and unit = 'giorni' from fabula.settings where key = 'auth.link_days'));
select pg_temp.ck('auth.link_hours (C-18) is 24 and says it is about Supabase''s e-mails',
  (select value = '24' and description ilike '%Supabase%' from fabula.settings where key = 'auth.link_hours'));

-- ---------------------------------------------------------------- 2. personal links
select fabula.access_link_new('00000000-0000-4000-b000-0000000109aa', pg_temp.h('tokA1'), '00000000-0000-4000-b000-0000000109a0') as a1 \gset
select pg_temp.ck('a new person''s link is an invite for 7 days, with the name, profile, home page and company',
  (:'a1'::jsonb ->> 'purpose') = 'invite' and (:'a1'::jsonb ->> 'first_name') = 'Anna' and (:'a1'::jsonb ->> 'home') is not null
  and (:'a1'::jsonb ->> 'expires_at')::timestamptz between now() + interval '6 days 23 hours' and now() + interval '7 days 1 hour'
  and (:'a1'::jsonb ->> 'company') is not null, :'a1');
select pg_temp.ck('only the hash is kept', not exists (select 1 from fabula.staff_access_links where token_hash = 'tokA1')
  and exists (select 1 from fabula.staff_access_links where token_hash = pg_temp.h('tokA1')));
select pg_temp.ck('the link greets the person',
  (fabula.access_link_check(pg_temp.h('tokA1')) ->> 'ok')::boolean and fabula.access_link_check(pg_temp.h('tokA1')) ->> 'full_name' = 'Anna Nuova');
select pg_temp.ck('an unknown link says so', fabula.access_link_check(pg_temp.h('nope')) ->> 'reason' = 'unknown');
select fabula.access_link_new('00000000-0000-4000-b000-0000000109aa', pg_temp.h('tokA2'), null) as a2 \gset
select pg_temp.ck('a newer link replaces the older one',
  fabula.access_link_check(pg_temp.h('tokA1')) ->> 'reason' = 'replaced' and (fabula.access_link_check(pg_temp.h('tokA2')) ->> 'ok')::boolean);
select pg_temp.ck('a password link for someone who already has a password',
  fabula.access_link_new('00000000-0000-4000-b000-0000000109b0', pg_temp.h('tokB1'), null) ->> 'purpose' = 'reset');
select pg_temp.ck('no link for a person without e-mail or switched off',
  pg_temp.err($$select fabula.access_link_new((select id from fabula.staff where full_name = 'Mario Titolare'), 'zz', null)$$) is not null);
insert into fabula.staff (id, full_name, role, app_role, email, active) values ('00000000-0000-4000-b000-0000000109d0', 'Dario Senzamail', 'operaio', 'produzione', null, true);
select pg_temp.ck('…without e-mail: «Manca l''email»',
  pg_temp.err($$select fabula.access_link_new('00000000-0000-4000-b000-0000000109d0', '$$ || pg_temp.h('tokD') || $$', null)$$) ilike '%manca l''email%');

-- claim / unclaim / done (the server function «welcome»)
select fabula.access_link_claim(pg_temp.h('tokA2')) as c1 \gset
select pg_temp.ck('the link is used when the password is saved', (:'c1'::jsonb ->> 'claimed')::boolean, :'c1');
select pg_temp.ck('…and only once (a second «Salva» is refused: used)',
  not (fabula.access_link_claim(pg_temp.h('tokA2')) ->> 'claimed')::boolean and fabula.access_link_check(pg_temp.h('tokA2')) ->> 'reason' = 'used');
select fabula.access_link_unclaim((:'c1'::jsonb ->> 'link_id')::uuid) as un \gset
select pg_temp.ck('if the password could not be set the link works again', :'un'::boolean and (fabula.access_link_check(pg_temp.h('tokA2')) ->> 'ok')::boolean);
select fabula.access_link_claim(pg_temp.h('tokA2')) as c2 \gset
insert into auth.users (id, email, email_confirmed_at, encrypted_password) values ('00000000-0000-4000-a000-0000000109aa', 'anna109@example.it', now(), 'x');
select fabula.access_link_done((:'c2'::jsonb ->> 'link_id')::uuid, '00000000-0000-4000-a000-0000000109aa') as dn \gset
select pg_temp.ck('done: the person is linked to the new login', (:'dn'::jsonb ->> 'ok')::boolean and (:'c2'::jsonb ->> 'claimed')::boolean
  and (select auth_user_id from fabula.staff where id = '00000000-0000-4000-b000-0000000109aa') = '00000000-0000-4000-a000-0000000109aa');
select fabula.access_link_new('00000000-0000-4000-b000-0000000109b0', pg_temp.h('tokB2'), null) is not null as b2 \gset
update fabula.staff_access_links set expires_at = now() - interval '1 minute' where token_hash = pg_temp.h('tokB2');
select pg_temp.ck('an expired link says so, and cannot be used', fabula.access_link_check(pg_temp.h('tokB2')) ->> 'reason' = 'expired'
  and not (fabula.access_link_claim(pg_temp.h('tokB2')) ->> 'claimed')::boolean);
select pg_temp.ck('nobody signed in can read or call the links',
  not has_table_privilege('authenticated', 'fabula.staff_access_links', 'SELECT') and not has_table_privilege('anon', 'fabula.staff_access_links', 'SELECT')
  and not has_function_privilege('authenticated', 'fabula.access_link_claim(text)', 'EXECUTE')
  and not has_function_privilege('anon', 'fabula.access_link_check(text)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'fabula.access_link_new(uuid, text, uuid)', 'EXECUTE'));

-- ---------------------------------------------------------------- 3. login state
insert into fabula.staff (id, full_name, role, app_role, email, active) values
  ('00000000-0000-4000-b000-0000000109e0', 'Elena Daninvitare', 'operaio', 'produzione', 'elena109@example.it', true),
  ('00000000-0000-4000-b000-0000000109f0', 'Franco Invitato', 'operaio', 'produzione', 'franco109@example.it', true),
  ('00000000-0000-4000-b000-0000000109f1', 'Gino Scaduto', 'operaio', 'produzione', 'gino109@example.it', true);
select fabula.access_link_new('00000000-0000-4000-b000-0000000109f0', pg_temp.h('tokF'), '00000000-0000-4000-b000-0000000109a0') is not null as f \gset
select fabula.access_link_new('00000000-0000-4000-b000-0000000109f1', pg_temp.h('tokG'), null) is not null as g \gset
update fabula.staff_access_links set expires_at = now() - interval '1 hour' where token_hash = pg_temp.h('tokG');
create temp table ls as select * from fabula.staff_login_rows();
select pg_temp.ck('login state: no link yet → da_invitare', (select state from ls where staff_id = '00000000-0000-4000-b000-0000000109e0') = 'da_invitare');
select pg_temp.ck('…open link → invitato, until its expiry, made by whom',
  (select state = 'invitato' and link_kind = 'link' and link_open and link_by = 'Mario Titolare' and link_expires_at > now() + interval '6 days'
     from ls where staff_id = '00000000-0000-4000-b000-0000000109f0'),
  (select row_to_json(ls)::text from ls where staff_id = '00000000-0000-4000-b000-0000000109f0'));
select pg_temp.ck('…link expired unused → link_scaduto', (select state from ls where staff_id = '00000000-0000-4000-b000-0000000109f1') = 'link_scaduto');
select pg_temp.ck('…password chosen through the link → attivo (even before the first sign-in)',
  (select state from ls where staff_id = '00000000-0000-4000-b000-0000000109aa') = 'attivo');
select pg_temp.ck('…no e-mail → senza_email', (select state from ls where staff_id = '00000000-0000-4000-b000-0000000109d0') = 'senza_email');
select pg_temp.ck('…someone signed in stays attivo whatever their links', (select state from ls where staff_id = '00000000-0000-4000-b000-0000000109b0') = 'attivo');
drop table ls;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-0000000109a1","role":"authenticated"}', false);
set role authenticated;
select pg_temp.ck('the Console wrapper answers the titolare with the link columns',
  (select count(*) from fabula.staff_logins() j where j ? 'link_open' and j ? 'link_by') >= 7);
reset role;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-0000000109b1","role":"authenticated"}', false);
set role authenticated;
select pg_temp.ck('…and nobody else', pg_temp.err('select count(*) from fabula.staff_logins()') ilike '%titolare%');
reset role;
select set_config('request.jwt.claims', '', false);

-- ---------------------------------------------------------------- 4. C-13 the e-mail of someone with a login
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-0000000109a1","role":"authenticated"}', false);
set role authenticated;
select pg_temp.ck('C-13: a plain edit of the e-mail of someone with a login is refused, saying to use «Cambia email»',
  pg_temp.err($$update fabula.staff set email = 'bruna.nuova@example.it' where id = '00000000-0000-4000-b000-0000000109b0'$$) ilike '%Cambia email%');
select pg_temp.ck('…for someone without a login it is a plain edit',
  pg_temp.err($$update fabula.staff set email = 'elena.nuova@example.it' where id = '00000000-0000-4000-b000-0000000109e0'$$) is null);
select pg_temp.ck('…and the same e-mail written differently (case) is not a change of login',
  pg_temp.err($$update fabula.staff set email = 'BRUNA109@example.it' where id = '00000000-0000-4000-b000-0000000109b0'$$) is null);
reset role;
select set_config('request.jwt.claims', '', false);
update fabula.staff set email = 'bruna109@example.it' where id = '00000000-0000-4000-b000-0000000109b0';
select pg_temp.ck('…the server function (service role) changes it with the login',
  pg_temp.err($$update fabula.staff set email = 'bruna.x@example.it' where id = '00000000-0000-4000-b000-0000000109b0'$$) is null);
update fabula.staff set email = 'bruna109@example.it' where id = '00000000-0000-4000-b000-0000000109b0';

-- ---------------------------------------------------------------- 5. C-14 switching someone off
insert into fabula.shifts (staff_id, clock_in) values ('00000000-0000-4000-b000-0000000109c0', now() - interval '3 hours');
insert into fabula.rota_entries (staff_id, work_date, kind, start_time, end_time) values
  ('00000000-0000-4000-b000-0000000109c0', (now() at time zone 'Europe/Rome')::date, 'lavoro', '05:00', '13:00'),
  ('00000000-0000-4000-b000-0000000109c0', (now() at time zone 'Europe/Rome')::date + 1, 'lavoro', '05:00', '13:00'),
  ('00000000-0000-4000-b000-0000000109c0', (now() at time zone 'Europe/Rome')::date + 2, 'riposo', null, null);
select fabula.access_link_new('00000000-0000-4000-b000-0000000109c0', pg_temp.h('tokC'), null) is not null as cl \gset
insert into fabula.notify_targets (staff_id, chat_id, linked_at) values ('00000000-0000-4000-b000-0000000109c0', 109109, now());
insert into fabula.staff_pins (staff_id, pin_hash) values ('00000000-0000-4000-b000-0000000109c0', 'h');
update fabula.settings set value = 'Carlo Uscente' where key = (select key from fabula.settings where coalesce(data_type, 'text') = 'text' and key like 'food.%' order by key limit 1);
insert into fabula.compliance_deadlines (kind, subject_it, responsible) values ('other', 'Rinnovo attestato v109', 'Carlo Uscente');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-0000000109b1","role":"authenticated"}', false);
set role authenticated;
select pg_temp.ck('C-14: only someone who manages users can switch a person off',
  pg_temp.err($$select fabula.staff_offboard('00000000-0000-4000-b000-0000000109c0')$$) ilike '%gestisce utenti%');
reset role;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-0000000109a1","role":"authenticated"}', false);
set role authenticated;
select fabula.staff_offboard_preview('00000000-0000-4000-b000-0000000109c0') as pv \gset
select pg_temp.ck('the preview lists what will happen: open shift, 2 future days, link, Telegram, PIN, mentions',
  (:'pv'::jsonb ->> 'open_shift_since') is not null and (:'pv'::jsonb ->> 'future_rota')::int = 2 and (:'pv'::jsonb ->> 'open_links')::int = 1
  and (:'pv'::jsonb ->> 'telegram')::boolean and (:'pv'::jsonb ->> 'pin')::boolean and jsonb_array_length(:'pv'::jsonb -> 'mentions') = 2, :'pv');
select pg_temp.ck('…and nothing has changed yet', (select active from fabula.staff where id = '00000000-0000-4000-b000-0000000109c0'));
select pg_temp.ck('nobody can switch himself off',
  pg_temp.err($$select fabula.staff_offboard('00000000-0000-4000-b000-0000000109a0')$$) ilike '%te stesso%');
select fabula.staff_offboard('00000000-0000-4000-b000-0000000109c0') as off \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('switched off, with a summary', (:'off'::jsonb ->> 'ok')::boolean and (:'off'::jsonb ->> 'shift_closed')::boolean
  and (:'off'::jsonb ->> 'rota_removed')::int = 2 and (:'off'::jsonb ->> 'links_revoked')::int = 1
  and (:'off'::jsonb ->> 'telegram_unlinked')::boolean and (:'off'::jsonb ->> 'pin_removed')::boolean, :'off');
select pg_temp.ck('…inactive', not (select active from fabula.staff where id = '00000000-0000-4000-b000-0000000109c0'));
select pg_temp.ck('…the open shift closed now, with a note',
  (select clock_out between now() - interval '1 minute' and now() + interval '1 minute' and notes ilike '%disattivazione%'
     from fabula.shifts where staff_id = '00000000-0000-4000-b000-0000000109c0'));
select pg_temp.ck('…today''s rota kept as history, the future removed',
  (select count(*) from fabula.rota_entries where staff_id = '00000000-0000-4000-b000-0000000109c0') = 1
  and exists (select 1 from fabula.rota_entries where staff_id = '00000000-0000-4000-b000-0000000109c0' and work_date = (now() at time zone 'Europe/Rome')::date));
select pg_temp.ck('…their link no longer works (revoked)', fabula.access_link_check(pg_temp.h('tokC')) ->> 'reason' = 'revoked');
select pg_temp.ck('…Telegram unlinked, PIN gone',
  (select chat_id is null and not active from fabula.notify_targets where staff_id = '00000000-0000-4000-b000-0000000109c0')
  and not exists (select 1 from fabula.staff_pins where staff_id = '00000000-0000-4000-b000-0000000109c0'));
select pg_temp.ck('…the setting and the deadline that name them are listed, not changed',
  (select string_agg(m ->> 'kind', ',' order by m ->> 'kind') from jsonb_array_elements(:'off'::jsonb -> 'mentions') m) = 'parametro,scadenza'
  and exists (select 1 from fabula.compliance_deadlines where subject_it = 'Rinnovo attestato v109' and responsible = 'Carlo Uscente'));
select pg_temp.ck('…the tablet''s «In turno» no longer lists them',
  not exists (select 1 from fabula.floor_open_shifts() where full_name = 'Carlo Uscente'));
select pg_temp.ck('the change log names who did it',
  exists (select 1 from fabula.audit_log where table_name = 'staff' and row_key = '00000000-0000-4000-b000-0000000109c0' and actor = 'Mario Titolare'),
  (select string_agg(actor, ',') from fabula.audit_log where table_name = 'staff' and row_key = '00000000-0000-4000-b000-0000000109c0'));

-- ---------------------------------------------------------------- 6. stale shifts close by themselves
insert into fabula.shifts (staff_id, clock_in) values ('00000000-0000-4000-b000-0000000109b0', now() - interval '13 hours'),
                                                      ('00000000-0000-4000-b000-0000000109e0', now() - interval '2 hours');
select fabula.close_stale_shifts() as stale \gset
select pg_temp.ck('a shift open past labor.max_shift_hours (12) closes by itself at 12 h; a recent one stays open',
  :'stale'::int = 1
  and (select hours = 12 and notes ilike '%dimenticato%' from fabula.shifts where staff_id = '00000000-0000-4000-b000-0000000109b0')
  and (select clock_out is null from fabula.shifts where staff_id = '00000000-0000-4000-b000-0000000109e0'));
select pg_temp.ck('…every hour (scheduled job, in the expected list)',
  exists (select 1 from cron.job where jobname = 'fabula_close_stale_shifts' and schedule = '7 * * * *')
  and exists (select 1 from fabula.cron_jobs_expected where jobname = 'fabula_close_stale_shifts'));

-- ---------------------------------------------------------------- 7. Telegram links last 7 days
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-0000000109a1","role":"authenticated"}', false);
set role authenticated;
select fabula.notify_link_code('00000000-0000-4000-b000-0000000109b0') as tg \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('a Telegram link for someone''s phone lasts 7 days',
  (:'tg'::jsonb ->> 'expires')::timestamptz between now() + interval '6 days 23 hours' and now() + interval '7 days 1 hour', :'tg');

-- ---------------------------------------------------------------- 8. security
select pg_temp.ck('no new security finding without a reason', not exists (
  select 1 from fabula.security_findings() f where not exists (select 1 from fabula.security_accepted a where a.key = f.key)),
  (select string_agg(f.key, ', ') from fabula.security_findings() f where not exists (select 1 from fabula.security_accepted a where a.key = f.key)));
