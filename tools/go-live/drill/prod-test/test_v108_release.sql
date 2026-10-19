-- v1.08 release pipeline, the database side · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh r_test
--   su postgres -c "psql -d r_test -f tools/go-live/drill/prod-test/test_v108_release.sql" | grep -E "PASS|FAIL"
-- (the pipeline itself, git and the Supabase API, is tested by tools/release/test_release.py)
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as
$$ begin execute p_sql; return ''; exception when others then return sqlerrm; end $$;
create or replace function pg_temp.as_user(p_sub text) returns void language sql as
$$ select set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_sub), false) $$;
insert into fabula.staff (id, full_name, role, app_role, active, auth_user_id) values
  ('10000000-0000-4000-a000-000000108a01', 'Titolare R', 'owner', 'titolare', true, '00000000-0000-4000-a000-000000108a01'),
  ('10000000-0000-4000-a000-000000108a03', 'Marketing R', 'operaio', 'marketing', true, '00000000-0000-4000-a000-000000108a03')
on conflict do nothing;
\set tit '00000000-0000-4000-a000-000000108a01'
\set mkt '00000000-0000-4000-a000-000000108a03'
\set run '\'https://github.com/nickdv6/caseificio-ops/actions/runs/1001\''

-- ============================== before the first release ==============================
select pg_temp.ck('Sistema «Rilasci automatici» before any release: not green, says the first is v1.08',
  (fabula.infra_checks() -> 'release' ->> 'done') = 'false' and (fabula.infra_checks() -> 'release' ->> 'detail') like 'Nessun rilascio automatico ancora%',
  fabula.infra_checks() -> 'release' ->> 'detail');

-- ============================== a release that went through, nothing left to do ==============================
select fabula.release_record(jsonb_build_object('version', 'v1.08', 'title_it', 'Rilasci automatici', 'sha', repeat('a', 40), 'base_sha', repeat('b', 40), 'status', 'ok',
  'steps', jsonb_build_object('functions', jsonb_build_object('status', 'ok', 'names', jsonb_build_array('invite-user')),
                              'database', jsonb_build_object('status', 'ok', 'versions', jsonb_build_array('20261015160000')),
                              'site', jsonb_build_object('status', 'ok', 'sw', 'perla-v75')),
  'run_url', 'https://github.com/nickdv6/caseificio-ops/actions/runs/1001')) r1 \gset
select pg_temp.ck('release_record writes the row (ok, steps, run)',
  (select status = 'ok' and version = 'v1.08' and steps #>> '{site,sw}' = 'perla-v75' and run_url like 'https://github.com/%' and message_id is not null
     from fabula.releases where id = :r1));
select severity, title, body from fabula.bot_messages where id = (select message_id from fabula.releases where id = :r1) \gset m1_
select pg_temp.ck('…and an «info» message in the Bot feed: «Rilascio v1.08 fatto», what reached production, no «Da fare»',
  :'m1_severity' = 'info' and :'m1_title' = 'Rilascio v1.08 fatto' and :'m1_body' like '%In produzione: funzioni del server: invite-user · database: 1 modifica · app del tablet perla-v75%'
  and :'m1_body' not like '%Da fare%' and :'m1_body' like '%EN — Release v1.08 is live (functions invite-user, 1 database change(s), app perla-v75).%', :'m1_body');
select pg_temp.ck('…an «info» does not go to Telegram (the morning summary has it)',
  not exists (select 1 from fabula.notify_outbox where title like 'Rilascio v1.08%'));
select pg_temp.ck('…in «Rilasci» (sistema), opening Configurazione → Panoramica',
  (select fabula.message_area(agent, title) = 'sistema' and action_url = 'admin.html#panoramica' from fabula.bot_messages where id = (select message_id from fabula.releases where id = :r1)));
select pg_temp.ck('Sistema «Rilasci automatici» after it: green, with the date and what changed',
  (fabula.infra_checks() -> 'release' ->> 'done') = 'true' and (fabula.infra_checks() -> 'release' ->> 'detail') ~ '^Ultimo rilascio v1\.08 il \d\d/\d\d \d\d:\d\d · funzioni, database, app perla-v75$',
  fabula.infra_checks() -> 'release' ->> 'detail');

-- ============================== went through, with steps for people ==============================
select fabula.release_record(jsonb_build_object('version', 'v1.09', 'sha', repeat('c', 40), 'status', 'ok',
  'steps', jsonb_build_object('database', jsonb_build_object('status', 'ok', 'versions', jsonb_build_array('1', '2')),
                              'site', jsonb_build_object('status', 'warn', 'sw', 'perla-v76', 'detail', 'il sito risponde con perla-v75')),
  'after_it', jsonb_build_array('Ristampa il poster della Masseria'), 'prompts', jsonb_build_array('milk_planning', 'procurement'))) r2 \gset
select severity, title, body from fabula.bot_messages where id = (select message_id from fabula.releases where id = :r2) \gset m2_
select pg_temp.ck('steps left by hand → «warn», counted in the title',
  :'m2_severity' = 'warn' and :'m2_title' = 'Rilascio v1.09 fatto: 3 cose da fare', :'m2_title');
select pg_temp.ck('…«Da fare»: the release''s step, the bots by their names, the app that still answers with the old version',
  :'m2_body' like '%1. Ristampa il poster della Masseria%' and :'m2_body' like '%2. Chiedi a Claude di aggiornare le istruzioni dei bot (cambiate: Acquisti, Piano latte)%'
  and :'m2_body' like '%3. Controlla l''app del tablet: il sito risponde con perla-v75%' and :'m2_body' like '%database: 2 modifiche%', :'m2_body');

-- ============================== stopped ==============================
select fabula.release_record(jsonb_build_object('version', 'v1.10', 'sha', repeat('d', 40), 'status', 'failed',
  'error', 'Database non aggiornato (nessuna modifica) · Supabase API HTTP 400 · ERROR: boom',
  'steps', jsonb_build_object('functions', jsonb_build_object('status', 'ok', 'names', jsonb_build_array('farm-order')),
                              'database', jsonb_build_object('status', 'failed', 'error', 'boom')),
  'run_url', 'https://github.com/nickdv6/caseificio-ops/actions/runs/1003')) r3 \gset
select severity, title, body from fabula.bot_messages where id = (select message_id from fabula.releases where id = :r3) \gset m3_
select pg_temp.ck('a stopped release → «alert» naming the step',
  :'m3_severity' = 'alert' and :'m3_title' = 'Rilascio v1.10 fermato al passo «database»', :'m3_title');
select pg_temp.ck('…with the error, what already changed, and the link to the run',
  :'m3_body' like '%Errore: Database non aggiornato (nessuna modifica)%' and :'m3_body' like '%Già in produzione: funzioni del server: farm-order%'
  and :'m3_body' like '%https://github.com/nickdv6/caseificio-ops/actions/runs/1003%', :'m3_body');
select pg_temp.ck('…and it goes to Telegram as a system message («infra»)',
  exists (select 1 from fabula.notify_outbox where title = 'Rilascio v1.10 fermato al passo «database»' and topic = 'infra'));
select pg_temp.ck('…the fix comes as a new release to approve (Re-run only for the token or the network)',
  :'m3_body' like '%la correzione arriva come nuovo rilascio da approvare (Re-run su GitHub solo se la causa era il token o la rete)%', :'m3_body');
select pg_temp.ck('Sistema «Rilasci automatici» after a stopped release: red, the fix comes as a new release',
  (fabula.infra_checks() -> 'release' ->> 'done') = 'false' and (fabula.infra_checks() -> 'release' ->> 'detail') like 'Rilascio v1.10 fermato il % · la correzione arriva come nuovo rilascio',
  fabula.infra_checks() -> 'release' ->> 'detail');
select fabula.release_record(jsonb_build_object('version', 'v1.10', 'sha', repeat('e', 40), 'status', 'failed', 'error', 'Funzione farm-order non pubblicata · bundle failed',
  'steps', jsonb_build_object('functions', jsonb_build_object('status', 'failed', 'error', 'bundle failed')))) r4 \gset
select pg_temp.ck('stopped before anything changed: says so',
  (select body like '%Nessuna modifica è arrivata in produzione%' and title = 'Rilascio v1.10 fermato al passo «funzioni del server»'
     from fabula.bot_messages where id = (select message_id from fabula.releases where id = :r4)));
select fabula.release_record(jsonb_build_object('sha', repeat('f', 40), 'status', 'failed', 'error', 'x', 'run_url', 'https://evil.example/actions/runs/1')) r5 \gset
select pg_temp.ck('no version → the short commit; a link that is not a GitHub run is dropped',
  (select version = 'fffffff' and run_url is null from fabula.releases where id = :r5));
select pg_temp.ck('a missing or wrong commit is refused', pg_temp.err($$select fabula.release_record('{"status":"ok","sha":"123"}'::jsonb)$$) like 'release_record: sha%');
select fabula.release_record(jsonb_build_object('version', 'v1.11-' || repeat('x', 80), 'sha', repeat('a', 40), 'status', 'failed', 'steps', '{"database":{"status":"failed"}}'::jsonb)) r6 \gset
select pg_temp.ck('a title never goes over 70 characters', (select length(title) <= 70 from fabula.bot_messages where id = (select message_id from fabula.releases where id = :r6)));

-- ============================== the live commit, without secrets ==============================
set role anon;
select public.fabula_live_release()::text lr_anon \gset
reset role;
select pg_temp.ck('public.fabula_live_release() (anon, the plan job): the last release that went through, not the last row',
  (:'lr_anon'::jsonb ->> 'sha') = repeat('c', 40) and (:'lr_anon'::jsonb ->> 'version') = 'v1.09' and :'lr_anon'::jsonb ? 'at'
  and (select count(*) from fabula.releases where id > (select id from fabula.releases where sha = repeat('c', 40))) > 0, :'lr_anon');
select pg_temp.ck('…and nothing else: three keys', (select count(*) from jsonb_object_keys(:'lr_anon'::jsonb)) = 3, :'lr_anon');

-- ============================== a release blocked before the approval (the watcher's report function) ==============================
select vault.create_secret('test-backup-token-108', 'backup_export_token') is not null as secret_set \gset
set role anon;
select pg_temp.err($$select public.fabula_outside_report('wrong', 'release', '{"version":"v1.12"}'::jsonb)$$) ob_wrong \gset
select public.fabula_outside_report('test-backup-token-108', 'release',
  '{"ok":false,"stage":"plan","version":"v1.12","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","error":"prova generale fallita: boom","run_url":"https://github.com/nickdv6/caseificio-ops/actions/runs/77"}'::jsonb)::text ob_ok \gset
reset role;
select pg_temp.ck('a wrong token is refused', :'ob_wrong' = 'forbidden', :'ob_wrong');
select severity, title, body from fabula.bot_messages where agent = 'rilascio' order by created_at desc, id desc limit 1 \gset mb_
select pg_temp.ck('kind «release»: an alert «bloccato prima dell''approvazione» with the reason and the run, nothing recorded as a release',
  :'ob_ok'::jsonb ->> 'ok' = 'true' and :'mb_severity' = 'alert' and :'mb_title' = 'Rilascio v1.12 bloccato prima dell''approvazione'
  and :'mb_body' like '%Errore: prova generale fallita: boom%' and :'mb_body' like '%actions/runs/77%'
  and not exists (select 1 from fabula.releases where version = 'v1.12'), :'mb_title' || ' / ' || :'mb_body');
select pg_temp.ck('…on Telegram (infra)', exists (select 1 from fabula.notify_outbox where title = 'Rilascio v1.12 bloccato prima dell''approvazione' and topic = 'infra'));
select fabula.release_blocked('{"stage":"apply","version":"v1.13","error":"Supabase HTTP 401: token non valido o scaduto"}'::jsonb) bl2 \gset
select pg_temp.ck('stage «apply» (approved, stopped before changing anything): says so',
  (select title from fabula.bot_messages where id = :bl2) = 'Rilascio v1.13 fermato prima di cambiare qualcosa');
select fabula.release_blocked('{"stage":"record","version":"v1.14","error":"risultato non registrato · Supabase: la risposta non è arrivata"}'::jsonb) bl3 \gset
select title, body from fabula.bot_messages where id = :bl3 \gset b3_
select pg_temp.ck('stage «record» (it ran, the result could not be written): «esito non registrato», may have changed things',
  :'b3_title' = 'Rilascio v1.14: esito non registrato' and :'b3_body' like '%possono essere già aggiornati%'
  and :'b3_body' like '%riparte dall''ultimo registrato%' and :'b3_body' not like '%Nessuna modifica è arrivata%', :'b3_title' || ' / ' || :'b3_body');
select pg_temp.ck('the other kinds still work (watcher)', public.fabula_outside_report('test-backup-token-108', 'watcher', '{"ok":true,"summary":"tutto ok"}'::jsonb) ->> 'ok' = 'true');

-- ============================== the drift texts follow the pipeline ==============================
insert into fabula.infra_status (key, ok, data, checked_at, last_ok_at) values
  ('github_tree', true, jsonb_build_object('versions', (select jsonb_agg(version order by version) from supabase_migrations.schema_migrations) || '["29991231000000"]'::jsonb), now(), now()),
  ('github_sw', true, '{"sw":"perla-v99"}', now(), now()),
  ('site', true, '{"sw":"perla-v98"}', now(), now())
on conflict (key) do update set ok = excluded.ok, data = excluded.data, checked_at = excluded.checked_at, last_ok_at = excluded.last_ok_at;
select pg_temp.ck('a migration on GitHub not on the database: the release waits for the approval on GitHub (no more SQL Editor)',
  (fabula.infra_checks() -> 'repo_sync' ->> 'detail') like '%su GitHub ma non applicate sul database (29991231000000): il rilascio aspetta l''approvazione su GitHub (Actions → Release → «Review deployments»)'
  and (fabula.infra_checks() -> 'repo_sync' ->> 'detail') not like '%SQL Editor%', fabula.infra_checks() -> 'repo_sync' ->> 'detail');
select pg_temp.ck('an app not yet published: approve the release (no more «guarda Netlify»)',
  (fabula.infra_checks() -> 'app_deployed' ->> 'detail') = 'Sito perla-v98, GitHub perla-v99: il rilascio non ha ancora pubblicato l''app (approvalo su GitHub: Actions → Release)',
  fabula.infra_checks() -> 'app_deployed' ->> 'detail');
update fabula.infra_status set data = jsonb_build_object('versions', (select jsonb_agg(version order by version) from supabase_migrations.schema_migrations where version <> (select max(version) from supabase_migrations.schema_migrations)))
 where key = 'github_tree';
select pg_temp.ck('a migration on the database not on GitHub: applied outside the release, its file goes on main',
  (fabula.infra_checks() -> 'code_pushed' ->> 'detail') like '%Applicate fuori dal rilascio automatico: il file va salvato su GitHub main'
  and (fabula.infra_checks() -> 'repo_sync' ->> 'detail') like '%sul database ma non su GitHub: il file va salvato su GitHub main'
  and (fabula.infra_checks()::text) not like '%git push%', fabula.infra_checks() -> 'code_pushed' ->> 'detail');

-- ============================== who sees what ==============================
select pg_temp.ck('notify topic and link of «rilascio»', fabula.notify_topic_for('rilascio', 'Rilascio v1 fatto') = 'infra' and fabula.bot_default_link('rilascio') = 'admin.html#panoramica');
select pg_temp.ck('the Bot feed calls them «Rilasci»', fabula.bot_title('rilascio') = 'Rilasci');
select pg_temp.as_user(:'tit');
set role authenticated;
select pg_temp.err($$select fabula.release_record('{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","status":"ok"}'::jsonb)$$) rr_login \gset
select count(*) n_tit from fabula.releases \gset
select (select x ->> 'label_it' from jsonb_array_elements(fabula.system_checks()) x where x ->> 'key' = 'release') sc_label \gset
reset role;
select pg_temp.ck('a login cannot record a release, not even the owner', :'rr_login' like 'permission denied%', :'rr_login');
select pg_temp.ck('the owner reads the releases', :'n_tit'::int = (select count(*) from fabula.releases), :'n_tit');
select pg_temp.ck('Panoramica → Sistema has «Rilasci automatici»', :'sc_label' = 'Rilasci automatici', :'sc_label');
select pg_temp.as_user(:'mkt');
set role authenticated;
select count(*) n_mkt from fabula.releases \gset
reset role;
select pg_temp.ck('a profile without Sistema does not see them', :'n_mkt'::int = 0, :'n_mkt');
set role anon;
select pg_temp.err($$select count(*) from fabula.releases$$) rel_anon \gset
reset role;
select pg_temp.ck('anon cannot read them', :'rel_anon' like 'permission denied%', :'rel_anon');
select pg_temp.ck('the «Perché?» of the system checks names the line', exists (
  select 1 from unnest(fabula._why_infra_rows(jsonb_build_object('release', jsonb_build_object('done', false, 'detail', 'x')))) r where r::text like '%Rilasci automatici%'));
select pg_temp.ck('no new security finding without a reason', not exists (
  select 1 from fabula.security_findings() f where not exists (select 1 from fabula.security_accepted a where a.key = f.key)),
  (select string_agg(f.key, ', ') from fabula.security_findings() f where not exists (select 1 from fabula.security_accepted a where a.key = f.key)));
