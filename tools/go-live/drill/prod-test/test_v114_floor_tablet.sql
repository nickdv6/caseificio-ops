-- v1.14 · only the floor tablet counts (R-04, audit A-35) · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh f_test
--   su postgres -c "psql -d f_test -f tools/go-live/drill/prod-test/test_v114_floor_tablet.sql" | grep -E "PASS|FAIL"
-- What happened on 19/10, rebuilt: a socio's iPhone on the latest app ticked «Tablet di produzione aggiornato». Now a device counts
-- only once someone marks it as «Tablet del caseificio» in Configurazione → Dispositivi; a named device keeps its name.
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as
$$ begin execute p_sql; return ''; exception when others then return sqlstate || ' ' || sqlerrm; end $$;
create or replace function pg_temp.as_user(p_sub text) returns void language sql as
$$ select set_config('request.jwt.claims', case when p_sub is null then '' else format('{"sub":"%s","role":"authenticated"}', p_sub) end, false) $$;
create or replace function pg_temp.tc() returns jsonb language sql as
$$ select c from jsonb_array_elements(fabula.ops_dashboard() -> 'checks') c where c ->> 'key' = 'tablet_checkin' $$;
create or replace function pg_temp.day1() returns jsonb language sql as
$$ select s from jsonb_array_elements(fabula.trial_check((now() at time zone 'Europe/Rome')::date) -> 'steps') s where s ->> 'step' like 'Giorno 1 · tablet%' $$;

insert into fabula.staff (id, full_name, role, app_role, active, auth_user_id) values
  ('10000000-0000-4000-a000-000000114a01', 'Nick Titolare', 'owner', 'titolare', true, '00000000-0000-4000-a000-000000114a01'),
  ('10000000-0000-4000-a000-000000114a02', 'Mario Casaro', 'casaro', 'produzione', true, '00000000-0000-4000-a000-000000114a02');
insert into fabula.infra_status (key, ok, detail, data, checked_at, last_ok_at) values
  ('site', true, 'perla-v80', '{"sw":"perla-v80"}', now(), now()), ('github_sw', true, 'perla-v80', '{"sw":"perla-v80"}', now(), now())
on conflict (key) do update set ok = true, data = excluded.data, checked_at = excluded.checked_at, last_ok_at = excluded.last_ok_at;
insert into fabula.settings (key, value, data_type) values ('infra.sw_seen', 'perla-v80|' || (now() - interval '2 days')::text, 'text')
on conflict (key) do update set value = excluded.value;   -- released 2 days ago
insert into fabula.settings (key, value, data_type) values ('trial.start', to_char((now() at time zone 'Europe/Rome')::date, 'YYYY-MM-DD'), 'text')
on conflict (key) do update set value = excluded.value;   -- today is day 1 of the trial

-- ============================== 19/10 rebuilt: the socio's iPhone on the latest app ==============================
select pg_temp.as_user('00000000-0000-4000-a000-000000114a01');
select fabula.device_checkin('iphone-nick-0001', 'tablet-1', 'perla-v80', 0, null, '[]', 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605') r0 \gset
select pg_temp.ck('a socio''s iPhone on the latest app no longer ticks «Tablet di produzione aggiornato» (it did on 19/10)',
  (pg_temp.tc() ->> 'done')::boolean = false, pg_temp.tc() ->> 'detail');
select pg_temp.ck('…and the check says what to do: no device is marked, 1 other device not counted',
  pg_temp.tc() ->> 'detail' like 'No device is marked as the floor tablet: Configurazione → Utenti e accessi → Dispositivi%' and pg_temp.tc() ->> 'detail' like '% · 1 other device(s) checked in, not counted');
select pg_temp.ck('the trial''s day 1 does not count it either, and says why',
  (pg_temp.day1() ->> 'ok')::boolean = false and pg_temp.day1() ->> 'detail' like 'nessun dispositivo segnato come «Tablet del caseificio»%', pg_temp.day1()::text);
select pg_temp.ck('an unnamed device answers without a name (the tablet keeps its own)', (:'r0'::jsonb ->> 'name') is null and (:'r0'::jsonb ->> 'floor')::boolean = false, :'r0');

-- the casaro's Android tablet, on the app before the latest
select pg_temp.as_user('00000000-0000-4000-a000-000000114a02');
select fabula.device_checkin('tab-floor-0001', 'tablet-1', 'perla-v79', 0, null, '[]', 'Mozilla/5.0 (Linux; Android 14; SM-X200) AppleWebKit/537.36 Chrome/129 Safari/537.36') is not null c1 \gset
select pg_temp.ck('a device without a name is called by what it is and who used it: «tablet Android di Mario», «iPhone di Nick»',
  fabula._device_name('tab-floor-0001') = 'tablet Android di Mario' and fabula._device_name('iphone-nick-0001') = 'iPhone di Nick',
  fabula._device_name('tab-floor-0001') || ' / ' || fabula._device_name('iphone-nick-0001'));
select pg_temp.ck('kinds from the browser: iPad, Android phone, Mac or iPad, Windows, none',
  fabula._device_kind('Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X)') = 'iPad' and fabula._device_kind('Mozilla/5.0 (Linux; Android 14; Pixel 8) Mobile Safari') = 'telefono Android'
  and fabula._device_kind('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)') = 'Mac o iPad' and fabula._device_kind('Mozilla/5.0 (Windows NT 10.0; Win64; x64)') = 'PC Windows'
  and fabula._device_kind(null) = 'dispositivo');

-- ============================== Configurazione → Dispositivi ==============================
select pg_temp.ck('a production login cannot see the list or mark a device (Sistema)',
  pg_temp.err($$select fabula.device_list()$$) like '42501%' and pg_temp.err($$select fabula.set_device('tab-floor-0001', 'Tablet laboratorio', true)$$) like '42501%',
  pg_temp.err($$select fabula.set_device('tab-floor-0001', 'Tablet laboratorio', true)$$));
select pg_temp.as_user('00000000-0000-4000-a000-000000114a01');
select fabula.device_list() dl0 \gset
select pg_temp.ck('the titolare sees every device: what it is, who used it, its app (old / latest), and may edit',
  (:'dl0'::jsonb ->> 'can_edit')::boolean and jsonb_array_length(:'dl0'::jsonb -> 'devices') = 2
  and exists (select 1 from jsonb_array_elements(:'dl0'::jsonb -> 'devices') x where x ->> 'device_uid' = 'tab-floor-0001' and x ->> 'kind' = 'tablet Android'
              and x ->> 'staff' = 'Mario Casaro' and not (x ->> 'latest')::boolean and x ->> 'name' = 'tablet Android di Mario')
  and exists (select 1 from jsonb_array_elements(:'dl0'::jsonb -> 'devices') x where x ->> 'device_uid' = 'iphone-nick-0001' and (x ->> 'latest')::boolean));
select fabula.set_device('tab-floor-0001', '  Tablet   laboratorio ', true) s1 \gset
select pg_temp.ck('the titolare names the floor tablet and marks it (spaces tidied)',
  (select label || '|' || floor || '|' || (named_at is not null) || '|' || named_by from fabula.devices where device_uid = 'tab-floor-0001')
    = 'Tablet laboratorio|true|true|10000000-0000-4000-a000-000000114a01', :'s1');
select pg_temp.ck('…written to «Registro modifiche» (Dispositivi), by name, with what changed',
  exists (select 1 from fabula.audit_log where table_name = 'devices' and row_key = 'tab-floor-0001' and actor = 'Nick Titolare'
          and changed @> array['label', 'floor'] and old_data ->> 'name' = 'tablet Android di Mario' and new_data ->> 'name' = 'Tablet laboratorio'));
select pg_temp.ck('the floor tablet on the app before the latest: still to do, and the check names it as old',
  (pg_temp.tc() ->> 'done')::boolean = false and pg_temp.tc() ->> 'detail' like 'Tablet laboratorio on perla-v79 (old app) · last seen % · 1 other device(s) not counted', pg_temp.tc() ->> 'detail');
select pg_temp.ck('names: unique, 2 to 40 characters, only for a device that exists',
  pg_temp.err($$select fabula.set_device('iphone-nick-0001', 'tablet LABORATORIO', false)$$) like '23505%già il nome di un altro dispositivo%'
  and pg_temp.err($$select fabula.set_device('iphone-nick-0001', ' ', false)$$) like '22023%'
  and pg_temp.err($$select fabula.set_device('iphone-nick-0001', repeat('x', 41), false)$$) like '22023%'
  and pg_temp.err($$select fabula.set_device('nope-000000', 'Altro', false)$$) like 'P0002%');
select fabula.set_device('iphone-nick-0001', 'iPhone di Nick', false) is not null s2 \gset

-- ============================== the floor tablet checks in ==============================
select pg_temp.as_user('00000000-0000-4000-a000-000000114a02');
select fabula.device_checkin('tab-floor-0001', 'tablet-1', 'perla-v80', 0, null, '[]', 'Mozilla/5.0 (Linux; Android 14; SM-X200) AppleWebKit/537.36') r1 \gset
select pg_temp.ck('a named device keeps its name when the tablet checks in with «tablet-1», and the tablet is told it',
  (select label from fabula.devices where device_uid = 'tab-floor-0001') = 'Tablet laboratorio'
  and :'r1'::jsonb ->> 'name' = 'Tablet laboratorio' and (:'r1'::jsonb ->> 'floor')::boolean, :'r1');
select pg_temp.ck('the floor tablet on the latest app ticks «Tablet di produzione aggiornato»',
  (pg_temp.tc() ->> 'done')::boolean and pg_temp.tc() ->> 'detail' like 'Tablet laboratorio on perla-v80 (latest) · last seen %', pg_temp.tc() ->> 'detail');
select pg_temp.ck('…and the trial''s day 1, by name', (pg_temp.day1() ->> 'ok')::boolean and pg_temp.day1() ->> 'detail' = 'Tablet laboratorio: collegato, app aggiornata', pg_temp.day1()::text);
select fabula.device_checkin('tab-floor-0001', 'tablet-1', 'perla-v81', 0, null) is not null c2 \gset
select pg_temp.ck('a tablet already on a newer app than the site check has seen still counts (the hourly check lags a release)',
  (pg_temp.tc() ->> 'done')::boolean and (pg_temp.day1() ->> 'ok')::boolean, pg_temp.tc() ->> 'detail');
update fabula.devices set last_seen_at = now() - interval '3 days' where device_uid = 'tab-floor-0001';
select pg_temp.ck('a floor tablet last seen 3 days ago no longer counts, and the check says so',
  (pg_temp.tc() ->> 'done')::boolean = false and pg_temp.tc() ->> 'detail' like '%(over 2 days ago: open the app on it)%', pg_temp.tc() ->> 'detail');
update fabula.devices set last_seen_at = now() where device_uid = 'tab-floor-0001';

-- a refused save from the named tablet carries its name
select fabula.device_checkin('tab-floor-0001', 'tablet-1', 'perla-v80', 0, null,
  '[{"qid":"q-114-1","ops":[{"table":"haccp_log","row":{"x":1}}],"error":"new row violates check constraint","code":"23514","failed_at":1759700000000}]') is not null c3 \gset
select pg_temp.ck('a refused save from the named tablet is stored and announced with its name, not «tablet-1»',
  (select device_label from fabula.tablet_rejects where qid = 'q-114-1') = 'Tablet laboratorio'
  and exists (select 1 from fabula.bot_messages where agent = 'sicurezza' and title = '1 registrazione rifiutata dal database (Tablet laboratorio)' and body like 'Il dispositivo «Tablet laboratorio» (Mario Casaro)%'));

-- ============================== the watchdog ==============================
select pg_temp.as_user(null);
update fabula.devices set app_version = 'perla-v79' where device_uid in ('tab-floor-0001', 'iphone-nick-0001');
update fabula.devices set queue_len = 2, oldest_queued_at = now() - interval '3 hours' where device_uid = 'iphone-nick-0001';
select fabula.device_watch() w1 \gset
select pg_temp.ck('old app a day after the release: warned only on the floor tablet, by name',
  exists (select 1 from jsonb_array_elements(:'w1'::jsonb -> 'warnings') x where x ->> 'kind' = 'version' and x ->> 'device' = 'Tablet laboratorio')
  and not exists (select 1 from jsonb_array_elements(:'w1'::jsonb -> 'warnings') x where x ->> 'kind' = 'version' and x ->> 'device' <> 'Tablet laboratorio')
  and exists (select 1 from fabula.bot_messages where agent = 'tablet' and title = 'Tablet laboratorio usa ancora la versione perla-v79 (attuale perla-v80)'), :'w1');
select pg_temp.ck('records waiting too long: still warned on any device, by its name («Il dispositivo» when not a floor tablet)',
  exists (select 1 from jsonb_array_elements(:'w1'::jsonb -> 'warnings') x where x ->> 'kind' = 'queue' and x ->> 'device' = 'iPhone di Nick')
  and exists (select 1 from fabula.bot_messages where agent = 'tablet' and title like 'iPhone di Nick: 2 registrazioni in attesa da %' and body like 'Il dispositivo «iPhone di Nick» ha 2 registrazioni%'), :'w1');
update fabula.devices set app_version = 'perla-v81', warned = '{}' where device_uid = 'tab-floor-0001';
select pg_temp.ck('a floor tablet on a newer app than the site check is not called old',
  not exists (select 1 from jsonb_array_elements((fabula.device_watch()) -> 'warnings') x where x ->> 'kind' = 'version'));

-- ============================== grants and the go-live list ==============================
select pg_temp.ck('grants: the list and the naming for logins only; helpers and the watchdog for the database only',
  has_function_privilege('authenticated', 'fabula.device_list()', 'execute') and not has_function_privilege('anon', 'fabula.device_list()', 'execute')
  and has_function_privilege('authenticated', 'fabula.set_device(text, text, boolean)', 'execute') and not has_function_privilege('anon', 'fabula.set_device(text, text, boolean)', 'execute')
  and not has_function_privilege('authenticated', 'fabula._device_name(text)', 'execute') and not has_function_privilege('authenticated', 'fabula._device_kind(text)', 'execute')
  and not has_function_privilege('authenticated', 'fabula._app_ver_num(text)', 'execute') and not has_function_privilege('authenticated', 'fabula.device_watch(timestamptz)', 'execute')
  and has_function_privilege('authenticated', 'fabula.device_checkin(text, text, text, int, timestamptz, jsonb, text)', 'execute')
  and not has_function_privilege('anon', 'fabula.device_checkin(text, text, text, int, timestamptz, jsonb, text)', 'execute'));
select pg_temp.ck('the two new definer functions are accepted by the security scan with their reason',
  (select count(*) from fabula.security_accepted where key in ('authenticated_security_definer_function_executable:fabula.device_list()',
     'authenticated_security_definer_function_executable:fabula.set_device(p_device_uid text, p_label text, p_floor boolean)')) = 2);
select pg_temp.ck('the go-live list explains where the tablet is marked',
  (select hint_it like '%Configurazione → Utenti e accessi → Dispositivi → «Tablet del caseificio»%' from fabula.dash_checks where key = 'tablet_checkin'));
select pg_temp.ck('app versions as numbers: perla-v80 → 80, anything else → none',
  fabula._app_ver_num('perla-v80') = 80 and fabula._app_ver_num('perla-v9') = 9 and fabula._app_ver_num('v80') is null and fabula._app_ver_num(null) is null);
