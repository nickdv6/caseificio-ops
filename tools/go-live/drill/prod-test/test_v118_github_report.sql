-- v1.18 (audit S-1 step 2) · the database no longer reads GitHub; GitHub reports what main holds · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh a_test
--   su postgres -c "psql -d a_test -f tools/go-live/drill/prod-test/test_v118_github_report.sql" | grep -E "PASS|FAIL"
-- Sections: 1 structure and grants · 2 the hourly probe sends no GitHub request · 3 the token · 4 a good report and the board ·
-- 5 drift both ways · 6 refused reports change nothing · 7 sw.js without a version · 8 infra_collect leaves reported rows alone ·
-- 9 the other report kinds work as before · 10 old news (a report of a commit the stored one descends from) is ignored · 11 wording.
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as
$$ begin execute p_sql; return ''; exception when others then return sqlstate || ' ' || sqlerrm; end $$;
-- the live history as GitHub would list it (the replay records every migration it applied)
create or replace function pg_temp.live() returns jsonb language sql as
$$ select coalesce(jsonb_agg(version order by version), '[]'::jsonb) from supabase_migrations.schema_migrations $$;
create or replace function pg_temp.rep(p_versions jsonb, p_sw text default 'perla-v81', p_sha text default 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                                       p_updated text default '2026-10-28T15:00:00-04:00', p_source text default 'release',
                                       p_anc jsonb default null) returns jsonb language sql as
$$ select jsonb_strip_nulls(jsonb_build_object('ok', true, 'source', p_source, 'run_url', 'https://github.com/nickdv6/caseificio-ops/actions/runs/1',
          'sha', p_sha, 'title', 'v1.18 (audit S-1): GitHub reports itself', 'updated', p_updated, 'versions', p_versions, 'sw', p_sw, 'ancestors', p_anc)) $$;
create or replace function pg_temp.st(p_key text) returns fabula.infra_status language sql as
$$ select * from fabula.infra_status where key = p_key $$;
create or replace function pg_temp.chk() returns jsonb language sql as $$ select fabula.infra_checks() $$;

select vault.create_secret('test-backup-token-118', 'backup_export_token') is not null as secret_set \gset
-- the tablet site answered with the same version the reports will carry (app_deployed compares the two)
insert into fabula.infra_status (key, ok, detail, data, checked_at, last_ok_at)
values ('site', true, 'perla-v81', '{"sw":"perla-v81"}', now(), now())
on conflict (key) do update set ok = true, detail = excluded.detail, data = excluded.data, checked_at = now(), last_ok_at = now();
-- what the probe left on live before this release: GitHub rows read at :43 (an old commit, a pending request from :40)
insert into fabula.infra_status (key, ok, detail, data, req_id, sent_at, checked_at, last_ok_at) values
  ('github_tree', true, '1 migration files on GitHub main', '{"versions":["20261001000000"],"tree_sha":"old","truncated":false}', 9001, now() - interval '3 minutes', now() - interval '1 hour', now() - interval '1 hour'),
  ('github_head', true, 'bbbbbbb', '{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","title":"old","updated":"2026-10-20T10:00:00Z"}', 9002, now() - interval '3 minutes', now() - interval '1 hour', now() - interval '1 hour'),
  ('github_sw', true, 'perla-v70', '{"sw":"perla-v70"}', 9003, now() - interval '3 minutes', now() - interval '1 hour', now() - interval '1 hour')
on conflict (key) do update set ok = excluded.ok, detail = excluded.detail, data = excluded.data, req_id = excluded.req_id,
  sent_at = excluded.sent_at, checked_at = excluded.checked_at, last_ok_at = excluded.last_ok_at;

-- ============================== 1. structure and grants ==============================
select pg_temp.ck('1a fabula.github_report: SECURITY INVOKER with a fixed search_path',
  (select not prosecdef and proconfig::text like '%search_path=%' from pg_proc where oid = 'fabula.github_report(jsonb,timestamptz)'::regprocedure));
select pg_temp.ck('1b fabula.github_report cannot be run by anon, logins or PUBLIC (only through the report function)',
  not has_function_privilege('anon', 'fabula.github_report(jsonb,timestamptz)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'fabula.github_report(jsonb,timestamptz)', 'EXECUTE')
  and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = 'fabula.github_report(jsonb,timestamptz)'::regprocedure and a.grantee = 0));
select pg_temp.ck('1c public.fabula_outside_report: still SECURITY DEFINER, still callable by anon (the token decides), still not by logins',
  (select prosecdef from pg_proc where oid = 'public.fabula_outside_report(text,text,jsonb)'::regprocedure)
  and has_function_privilege('anon', 'public.fabula_outside_report(text,text,jsonb)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.fabula_outside_report(text,text,jsonb)', 'EXECUTE'));
select pg_temp.ck('1d fabula.infra_probe: still SECURITY DEFINER, not callable by logins or anon',
  (select prosecdef from pg_proc where oid = 'fabula.infra_probe()'::regprocedure)
  and not has_function_privilege('authenticated', 'fabula.infra_probe()', 'EXECUTE') and not has_function_privilege('anon', 'fabula.infra_probe()', 'EXECUTE'));

-- ============================== 2. the hourly probe sends no GitHub request ==============================
select fabula.infra_probe() probe \gset
select pg_temp.ck('2a the probe asks exactly the tablet site and the two server functions',
  (select array_agg(k order by k) from jsonb_object_keys(:'probe'::jsonb) k) = array['fn_backup_export', 'fn_farm_order', 'site'], :'probe');
select pg_temp.ck('2b its source names no GitHub address', (select prosrc !~* 'github' from pg_proc where oid = 'fabula.infra_probe()'::regprocedure));
select pg_temp.ck('2c the GitHub rows keep the old pending request untouched by the probe (req_id 9001–9003)',
  (select array_agg(req_id order by key) from fabula.infra_status where key like 'github\_%') = array[9002, 9003, 9001]::bigint[]);

-- ============================== 3. the token ==============================
-- the reports are built as postgres (anon cannot read the migration history), then sent as anon, the way PostgREST calls it
select pg_temp.rep(pg_temp.live())::text good, pg_temp.rep(pg_temp.live() || '["20261028200000"]'::jsonb || pg_temp.live())::text dup \gset
set role anon;
select pg_temp.ck('3a a GitHub report with a wrong token is refused (42501)',
  pg_temp.err(format('select public.fabula_outside_report(%L, %L, %L)', 'wrong', 'github', :'good')) like '42501%');
select pg_temp.ck('3b …and with no token at all',
  pg_temp.err(format('select public.fabula_outside_report(null, %L, %L)', 'github', :'good')) like '42501%');
reset role;
set role authenticated;
select pg_temp.ck('3c a signed-in user cannot send a GitHub report, even with the token',
  pg_temp.err(format('select public.fabula_outside_report(%L, %L, %L)', 'test-backup-token-118', 'github', :'good')) like '42501%');
reset role;
select pg_temp.ck('3d nothing changed after the refused reports', (pg_temp.st('github_head')).data->>'sha' = repeat('b', 40)
  and (pg_temp.st('github_tree')).req_id = 9001);

-- ============================== 4. a good report and the board ==============================
set role anon;
select public.fabula_outside_report('test-backup-token-118', 'github', :'dup') r4 \gset
reset role;
select pg_temp.ck('4a anon with the token: accepted, with what was stored', (:'r4'::jsonb)->>'ok' = 'true' and (:'r4'::jsonb)->>'sha' = 'aaaaaaa'
  and ((:'r4'::jsonb)->>'versions')::int = jsonb_array_length(pg_temp.live()) and (:'r4'::jsonb)->>'sw' = 'perla-v81', :'r4');
select pg_temp.ck('4b github_tree: the versions sorted and without duplicates, ok, fresh, no pending request, the probe''s detail text',
  (select ok and data->'versions' = pg_temp.live() and data->>'sha' = repeat('a', 40) and data->>'source' = 'release'
          and req_id is null and sent_at is null and last_ok_at > now() - interval '1 minute' and fail_streak = 0
          and detail = jsonb_array_length(pg_temp.live()) || ' migration files on GitHub main'
          and fabula._it_infra_detail(detail) = jsonb_array_length(pg_temp.live()) || ' migrazioni su GitHub (main)'
     from fabula.infra_status where key = 'github_tree'), (pg_temp.st('github_tree')).detail);
select pg_temp.ck('4c github_head: commit, title and date as infra_checks reads them',
  (select ok and data->>'sha' = repeat('a', 40) and data->>'title' = 'v1.18 (audit S-1): GitHub reports itself'
          and (data->>'updated')::timestamptz = '2026-10-28T19:00:00Z' and detail = 'aaaaaaa' and req_id is null
     from fabula.infra_status where key = 'github_head'), (pg_temp.st('github_head')).data::text);
select pg_temp.ck('4d github_sw: the app version', (select ok and data = '{"sw":"perla-v81"}' and detail = 'perla-v81' and req_id is null from fabula.infra_status where key = 'github_sw'));
select pg_temp.ck('4e board: «Ultimo codice su GitHub» green, with the commit, title and Rome time',
  (pg_temp.chk()->'code_pushed'->>'done')::boolean
  and pg_temp.chk()->'code_pushed'->>'detail' = 'main aaaaaaa · v1.18 (audit S-1): GitHub reports itself · 28/10 20:00', pg_temp.chk()->'code_pushed'->>'detail');
select pg_temp.ck('4f board: «Migrazioni del repo uguali al database» green',
  (pg_temp.chk()->'repo_sync'->>'done')::boolean
  and pg_temp.chk()->'repo_sync'->>'detail' = jsonb_array_length(pg_temp.live()) || ' file su GitHub = ' || jsonb_array_length(pg_temp.live()) || ' versioni sul database', pg_temp.chk()->'repo_sync'->>'detail');
select pg_temp.ck('4g board: «App del tablet pubblicata = ultima su GitHub» green', (pg_temp.chk()->'app_deployed'->>'done')::boolean
  and pg_temp.chk()->'app_deployed'->>'detail' = 'Sito perla-v81 = GitHub main', pg_temp.chk()->'app_deployed'->>'detail');
select pg_temp.ck('4h live_app_version() still answers from the site', fabula.live_app_version() = 'perla-v81');
select fabula.infra_collect() c4 \gset
select pg_temp.ck('4i the hourly collect: none of the three code checks is counted as drifting, and no drift notice',
  (select data->'since' = '{}'::jsonb from fabula.infra_status where key = 'drift')
  and not exists (select 1 from fabula.notices where key = 'infra_drift' and resolved_at is null),
  (select data::text from fabula.infra_status where key = 'drift'));
select pg_temp.ck('4j a report without «ok» still stores the facts (the facts are what is checked, not the flag)',
  pg_temp.err(format('select fabula.github_report(%L)', (pg_temp.rep(pg_temp.live()) - 'ok')::text)) = ''
  and (pg_temp.st('github_tree')).ok);

-- ============================== 5. drift both ways ==============================
insert into supabase_migrations.schema_migrations (version) values ('20991231000000');
select pg_temp.ck('5a a migration applied on the database and missing on GitHub: «Ultimo codice su GitHub» red, says which',
  not (pg_temp.chk()->'code_pushed'->>'done')::boolean
  and pg_temp.chk()->'code_pushed'->>'detail' like '1 migrazione applicata sul database ma non su GitHub: 20991231000000.%', pg_temp.chk()->'code_pushed'->>'detail');
select fabula.github_report(pg_temp.rep(pg_temp.live() || '["29990101000000"]'::jsonb)) is not null as r5 \gset
select pg_temp.ck('5b a migration on GitHub and not yet applied: «Migrazioni» red and says the release waits for the approval',
  (pg_temp.chk()->'code_pushed'->>'done')::boolean and not (pg_temp.chk()->'repo_sync'->>'done')::boolean
  and pg_temp.chk()->'repo_sync'->>'detail' like '1 su GitHub ma non applicate sul database (29990101000000)%Review deployments%', pg_temp.chk()->'repo_sync'->>'detail');
delete from supabase_migrations.schema_migrations where version = '20991231000000';
select fabula.github_report(pg_temp.rep(pg_temp.live())) is not null as r5b \gset
select pg_temp.ck('5c the next report in step turns both green again', (pg_temp.chk()->'code_pushed'->>'done')::boolean and (pg_temp.chk()->'repo_sync'->>'done')::boolean);
update fabula.infra_status set last_ok_at = now() - interval '27 hours' where key = 'github_tree';
select pg_temp.ck('5d no report for 27 h: «GitHub non letto dal …» (the checks never stay green on old news)',
  not (pg_temp.chk()->'code_pushed'->>'done')::boolean and pg_temp.chk()->'code_pushed'->>'detail' like 'GitHub non letto dal %'
  and not (pg_temp.chk()->'repo_sync'->>'done')::boolean, pg_temp.chk()->'code_pushed'->>'detail');
select fabula.github_report(pg_temp.rep(pg_temp.live())) is not null as r5c \gset

-- ============================== 6. refused reports change nothing ==============================
create temp table before6 as select key, ok, detail, data, checked_at from fabula.infra_status where key like 'github\_%';
select pg_temp.ck('6a a commit that is not 40 hex characters → 22023',
  pg_temp.err(format('select fabula.github_report(%L)', pg_temp.rep(pg_temp.live(), p_sha => 'main')::text)) like '22023%resoconto GitHub non valido: commit%');
select pg_temp.ck('6b an upper-case or short commit → 22023',
  pg_temp.err(format('select fabula.github_report(%L)', pg_temp.rep(pg_temp.live(), p_sha => upper(repeat('a', 40)))::text)) like '22023%'
  and pg_temp.err(format('select fabula.github_report(%L)', pg_temp.rep(pg_temp.live(), p_sha => repeat('a', 39))::text)) like '22023%');
select pg_temp.ck('6c a commit date that is not an ISO date with its offset → 22023 («ieri», «now», «today», «epoch», «-infinity», a bare day, 30 February)',
  (select bool_and(pg_temp.err(format('select fabula.github_report(%L)', pg_temp.rep(pg_temp.live(), p_updated => x)::text)) like '22023%data del commit%')
     from unnest(array['ieri', 'now', 'today', 'epoch', '-infinity', 'infinity', '2026-10-28', '2026-02-30T10:00:00Z']) x));
select pg_temp.ck('6e versions not a list, a number in the list, a malformed version → 22023',
  pg_temp.err(format('select fabula.github_report(%L)', pg_temp.rep('{"a":1}'::jsonb)::text)) like '22023%elenco delle migrazioni%'
  and pg_temp.err(format('select fabula.github_report(%L)', pg_temp.rep('[20261001000000]'::jsonb)::text)) like '22023%elenco delle migrazioni%'
  and pg_temp.err(format('select fabula.github_report(%L)', pg_temp.rep('["2026100100000x"]'::jsonb)::text)) like '22023%elenco delle migrazioni%'
  and pg_temp.err(format('select fabula.github_report(%L)', (pg_temp.rep(pg_temp.live()) - 'versions')::text)) like '22023%elenco delle migrazioni%');
select pg_temp.ck('6f more than 5,000 versions → 22023',
  pg_temp.err(format('select fabula.github_report(%L)', pg_temp.rep((select jsonb_agg(to_char(20260101000000 + g, 'FM00000000000000')) from generate_series(1, 5001) g))::text)) like '22023%');
select pg_temp.ck('6g a report that is not an object → 22023, directly and through the report function',
  pg_temp.err($$select fabula.github_report('[1,2]'::jsonb)$$) like '22023%non è un oggetto%'
  and pg_temp.err($$select public.fabula_outside_report('test-backup-token-118', 'github', '[1,2]')$$) like '22023%');
select pg_temp.ck('6h a report over 200,000 characters through the report function → 22023, not cut and stored',
  pg_temp.err(format('select public.fabula_outside_report(%L, %L, %L)', 'test-backup-token-118', 'github',
    (pg_temp.rep(pg_temp.live()) || jsonb_build_object('padding', repeat('x', 200001)))::text)) like '22023%troppo grande%');
select pg_temp.ck('6i after every refused report the GitHub rows are exactly as before',
  not exists (select key, ok, detail, data, checked_at from fabula.infra_status where key like 'github\_%'
              except select key, ok, detail, data, checked_at from before6)
  and (select count(*) from fabula.infra_status where key like 'github\_%') = 3);
select pg_temp.ck('6j a title longer than 200 characters is cut, not refused',
  pg_temp.err(format('select fabula.github_report(%L)', (pg_temp.rep(pg_temp.live()) || jsonb_build_object('title', repeat('t', 500)))::text)) = ''
  and length((pg_temp.st('github_head')).data->>'title') = 200);
select pg_temp.ck('6k a report of 4,000 versions (about 20 years of releases) is stored whole, not cut at 8,000 characters',
  pg_temp.err(format('select public.fabula_outside_report(%L, %L, %L)', 'test-backup-token-118', 'github',
    pg_temp.rep((select jsonb_agg(to_char(20260101000000 + g, 'FM00000000000000')) from generate_series(1, 4000) g))::text)) = ''
  and jsonb_array_length((pg_temp.st('github_tree')).data->'versions') = 4000);
select pg_temp.err(format('select fabula.github_report(%L)', pg_temp.rep(pg_temp.live(), p_updated => (now() + interval '1 hour')::text)::text)) e6l \gset
select pg_temp.ck('6l a committer clock ahead of time: the report is stored, with the commit dated now (not refused, not in the future)',
  :'e6l' = '' and ((pg_temp.st('github_head')).data->>'updated')::timestamptz <= now() + interval '1 second'
  and ((pg_temp.st('github_head')).data->>'updated')::timestamptz > now() - interval '1 minute', :'e6l');
select fabula.github_report(pg_temp.rep(pg_temp.live())) is not null as r6 \gset

-- ============================== 7. sw.js without a version ==============================
select fabula.github_report(pg_temp.rep(pg_temp.live(), p_sw => null)) r7 \gset
select pg_temp.ck('7a no app version: github_sw red with the probe''s wording, the last good version kept; tree and head still stored',
  (select not ok and detail = 'GitHub main, sw.js without version' and data = '{"sw":"perla-v81"}' and fail_streak = 1
     from fabula.infra_status where key = 'github_sw')
  and (pg_temp.st('github_tree')).ok and (:'r7'::jsonb)->>'sw' is null, (pg_temp.st('github_sw')).detail);
select pg_temp.ck('7b the board shows it in Italian', fabula._it_infra_detail('GitHub main, sw.js without version') = 'GitHub main, sw.js senza versione');
select fabula.github_report(pg_temp.rep(pg_temp.live(), p_sw => '<script>')) is not null as r7b \gset
select pg_temp.ck('7c a version with markup is not stored as the app version, and the board says why',
  (select not ok and data = '{"sw":"perla-v81"}' and fail_streak = 2 and detail = 'GitHub main, versione di sw.js non accettata' from fabula.infra_status where key = 'github_sw'));
select fabula.github_report(pg_temp.rep(pg_temp.live(), p_sw => 'perla-v82+fix_2')) is not null as r7x \gset
select pg_temp.ck('7d a version with other harmless characters (as the site parser reads it) is accepted', (select ok and data = '{"sw":"perla-v82+fix_2"}' from fabula.infra_status where key = 'github_sw'));
select fabula.github_report(pg_temp.rep(pg_temp.live())) is not null as r7c \gset
select pg_temp.ck('7e the next good report: green again, streak back to 0', (select ok and fail_streak = 0 and data = '{"sw":"perla-v81"}' from fabula.infra_status where key = 'github_sw'));

-- ============================== 8. infra_collect leaves reported rows alone ==============================
-- an answer for one of the old pending requests (as if the probe of v1.17 had sent it just before the release) arrives late
insert into net._http_response (id, status_code, content) values
  (9001, 200, '{"sha":"zzz","truncated":false,"tree":[{"path":"supabase/migrations/20200101000000_x.sql","type":"blob"}]}'),
  (9003, 200, 'const CACHE = ''perla-v1'';');
select fabula.infra_collect() is not null as c8 \gset
select pg_temp.ck('8a a late answer to an old GitHub request does not overwrite what GitHub reported',
  (pg_temp.st('github_tree')).data->'versions' = pg_temp.live() and (pg_temp.st('github_sw')).data->>'sw' = 'perla-v81');
select pg_temp.ck('8b the probe never sets a request on the GitHub rows again',
  fabula.infra_probe() is not null and not exists (select 1 from fabula.infra_status where key like 'github\_%' and req_id is not null));

-- ============================== 9. the other report kinds work as before ==============================
-- each report is sent in its own statement and checked in the next (a check in the same statement would read the row as it was before)
select pg_temp.err($$select public.fabula_outside_report('test-backup-token-118', 'watcher', '{"ok": true, "summary": "tutto OK"}')$$) e9a \gset
select pg_temp.ck('9a watcher report: stored as before', :'e9a' = '' and (select ok and detail = 'tutto OK' from fabula.infra_status where key = 'outside_watcher'), :'e9a');
select pg_temp.err($$select public.fabula_outside_report('test-backup-token-118', 'offsite_backup', '{"ok": true, "summary": "copia ok"}')$$) e9b \gset
select pg_temp.ck('9b off-site backup report: stored as before', :'e9b' = '' and (select ok and detail = 'copia ok' from fabula.infra_status where key = 'offsite_backup'), :'e9b');
select pg_temp.err($$select public.fabula_outside_report('test-backup-token-118', 'restore_drill', '{"ok": true, "summary": "drill ok"}')$$) e9c \gset
select pg_temp.ck('9c restore drill report: an agent run as before', :'e9c' = '' and exists (select 1 from fabula.agent_runs where agent = 'restore_drill' and summary = 'drill ok'), :'e9c');
select pg_temp.ck('9d an unknown kind is still refused', pg_temp.err($$select public.fabula_outside_report('test-backup-token-118', 'other', '{}')$$) like '22023%kind non valido%');
select pg_temp.err(format('select public.fabula_outside_report(%L, %L, %L)', 'test-backup-token-118', 'watcher',
  jsonb_build_object('ok', true, 'summary', 'lungo', 'padding', repeat('x', 9000))::text)) e9e \gset
select pg_temp.ck('9e a watcher report over 8,000 characters is still cut to its summary',
  :'e9e' = '' and (select data->>'truncated' = 'true' and not data ? 'padding' and detail = 'lungo' from fabula.infra_status where key = 'outside_watcher'), :'e9e');
select pg_temp.err($$select public.fabula_outside_report('test-backup-token-118', 'watcher', '{"summary": "senza ok"}')$$) e9f \gset
select pg_temp.ck('9f a watcher report without «ok» still does not turn its check green',
  :'e9f' = '' and (select not ok and detail = 'senza ok' from fabula.infra_status where key = 'outside_watcher'), :'e9f');

-- ============================== 10. old news is ignored ==============================
-- by ancestry, not by date: «d» descends from «c», which descends from «a» (release.py sends the last 50 first-parent commits)
select to_char(now() - interval '1 day', 'YYYY-MM-DD"T"HH24:MI:SSOF') d1, to_char(now() - interval '3 days', 'YYYY-MM-DD"T"HH24:MI:SSOF') d3 \gset
select jsonb_build_array(repeat('d', 40), repeat('c', 40), repeat('a', 40)) anc_d, jsonb_build_array(repeat('c', 40), repeat('a', 40)) anc_c,
       jsonb_build_array(repeat('e', 40), repeat('9', 40)) anc_e \gset
select fabula.github_report(pg_temp.rep(pg_temp.live(), p_sha => repeat('a', 40), p_source => 'manual')) is not null as r10 \gset
select fabula.github_report(pg_temp.rep(pg_temp.live(), p_sha => repeat('d', 40), p_updated => :'d3', p_anc => :'anc_d')) r10a \gset
select pg_temp.ck('10a a newer commit is taken, even when its date is older (the committer''s clock does not matter)',
  (pg_temp.st('github_head')).data->>'sha' = repeat('d', 40) and not (:'r10a'::jsonb ? 'ignored')
  and (pg_temp.st('github_head')).data->'ancestors' = :'anc_d'::jsonb, :'r10a');
create temp table before10 as select key, ok, detail, data, checked_at, last_ok_at from fabula.infra_status where key like 'github\_%';
select fabula.github_report(pg_temp.rep(pg_temp.live() - 0, p_sha => repeat('c', 40), p_updated => :'d1', p_sw => 'perla-v70', p_anc => :'anc_c')) r10b \gset
select pg_temp.ck('10b a commit main has moved past (a long apply that read main before a newer push) is ignored and says so, even with a later date',
  (:'r10b'::jsonb)->>'ignored' = 'older' and (:'r10b'::jsonb)->>'kept' = 'ddddddd', :'r10b');
select pg_temp.ck('10c …and changes nothing: not the facts, not their freshness',
  not exists (select key, ok, detail, data, checked_at, last_ok_at from fabula.infra_status where key like 'github\_%'
              except select * from before10));
select pg_temp.rep(pg_temp.live(), p_sha => repeat('a', 40), p_source => 'watcher')::text old10 \gset
set role anon;
select public.fabula_outside_report('test-backup-token-118', 'github', :'old10') r10d \gset
reset role;
select pg_temp.ck('10d the same through the report function, as the watcher sends it (no history in the report: still ignored)',
  (:'r10d'::jsonb)->>'ignored' = 'older' and (pg_temp.st('github_head')).data->>'sha' = repeat('d', 40), :'r10d');
select fabula.github_report(pg_temp.rep(pg_temp.live(), p_sha => repeat('d', 40), p_anc => :'anc_d')) r10e \gset
select pg_temp.ck('10e the same commit again: taken, and its freshness renewed', not (:'r10e'::jsonb ? 'ignored')
  and (pg_temp.st('github_tree')).last_ok_at > (select last_ok_at from before10 where key = 'github_tree'), :'r10e');
select fabula.github_report(pg_temp.rep(pg_temp.live(), p_sha => repeat('e', 40), p_updated => :'d3', p_anc => :'anc_e')) r10f \gset
select pg_temp.ck('10f a commit outside the stored history (main rewritten, or pushed over): taken', (pg_temp.st('github_head')).data->>'sha' = repeat('e', 40), :'r10f');
select fabula.github_report(pg_temp.rep(pg_temp.live(), p_sha => repeat('9', 40), p_source => 'manual')) r10g \gset
select pg_temp.ck('10g an older commit of main sent by hand (main moved back on purpose): taken', (pg_temp.st('github_head')).data->>'sha' = repeat('9', 40), :'r10g');
select fabula.github_report(pg_temp.rep(pg_temp.live(), p_sha => repeat('e', 40), p_anc => :'anc_e')) is not null as r10h0 \gset
update fabula.infra_status set last_ok_at = now() - interval '27 hours' where key = 'github_tree';
select fabula.github_report(pg_temp.rep(pg_temp.live(), p_sha => repeat('9', 40))) r10h \gset
select pg_temp.ck('10h when the stored facts are already stale (26 h, «GitHub non letto»), an older commit is taken rather than nothing',
  (pg_temp.st('github_head')).data->>'sha' = repeat('9', 40) and (pg_temp.chk()->'code_pushed'->>'done')::boolean, :'r10h');
select pg_temp.ck('10i a history that is not a list of commits → 22023, nothing stored',
  pg_temp.err(format('select fabula.github_report(%L)', pg_temp.rep(pg_temp.live(), p_sha => repeat('b', 40), p_anc => '["main"]')::text)) like '22023%storia dei commit%'
  and pg_temp.err(format('select fabula.github_report(%L)', pg_temp.rep(pg_temp.live(), p_sha => repeat('b', 40), p_anc => '{"x":1}')::text)) like '22023%storia dei commit%'
  and (pg_temp.st('github_head')).data->>'sha' = repeat('9', 40));
select pg_temp.ck('10j a report without its history (a release.py older than v1.18): taken, its history is the commit alone',
  pg_temp.err(format('select fabula.github_report(%L)', pg_temp.rep(pg_temp.live(), p_sha => repeat('b', 40))::text)) = ''
  and (pg_temp.st('github_head')).data->'ancestors' = jsonb_build_array(repeat('b', 40)));

-- ============================== 11. wording ==============================
select pg_temp.ck('11a the three go-live hints no longer say «controllo orario»',
  (select count(*) from fabula.dash_checks where key in ('code_pushed', 'repo_sync', 'app_deployed') and hint_it like '%a ogni rilascio e a ogni giro del controllo esterno%') = 3
  and not exists (select 1 from fabula.dash_checks where key in ('code_pushed', 'repo_sync', 'app_deployed') and hint_it like '%orario%'));
select pg_temp.ck('11b infra_checks waits for the first GitHub report, no longer for an hourly read at :43',
  (select prosrc like '%In attesa del primo resoconto di GitHub (a ogni rilascio e a ogni giro del controllo esterno)%' and prosrc not like '%ogni ora, ai :43%'
     from pg_proc where oid = 'fabula.infra_checks()'::regprocedure));
