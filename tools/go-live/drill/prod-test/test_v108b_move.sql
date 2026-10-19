-- v1.08b the app moves to https://app.bubalina.it, the database side · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh m_test
--   su postgres -c "psql -d m_test -f tools/go-live/drill/prod-test/test_v108b_move.sql" | grep -E "PASS|FAIL"
-- (the forwarding from the old address is tested in the browser: tools/go-live/drill/tablet-test/v108b_e2e.py)
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;

select pg_temp.ck('infra.site_url is the new address', (select value from fabula.settings where key = 'infra.site_url') = 'https://app.bubalina.it',
  (select value from fabula.settings where key = 'infra.site_url'));
select pg_temp.ck('…and its description no longer says Netlify', (select description not ilike '%netlify%' from fabula.settings where key = 'infra.site_url'));

-- the links the database builds follow the setting: a Telegram message opens the new address
select pg_temp.ck('a Telegram message''s «apri» link opens https://app.bubalina.it',
  fabula.notify_html('infra', 'Titolo', 'Corpo', 'Sistema', now(), 'console.html#oggi') like '%<a href="https://app.bubalina.it/console.html#oggi">apri</a>%',
  fabula.notify_html('infra', 'Titolo', 'Corpo', 'Sistema', now(), 'console.html#oggi'));
select pg_temp.ck('no database function names the old Netlify address',
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname in ('fabula', 'public') and p.prokind = 'f' and pg_get_functiondef(p.oid) ilike '%flourishing-swan%'));

-- the drift notice: an app behind GitHub says to approve the release
insert into fabula.notices (key, severity, title_it, items, expires_at) values ('infra_drift', 'warn', 'x', '[{"code":"app_deployed"}]'::jsonb, now() + interval '1 day')
on conflict (key) do update set items = excluded.items, title_it = excluded.title_it, resolved_at = null, expires_at = excluded.expires_at;
select pg_temp.ck('drift notice: «approva il rilascio su GitHub», no Netlify',
  (select body like '%Il tablet non ha l''ultima versione dell''app: approva il rilascio su GitHub (Actions → Release)%' and body not ilike '%netlify%'
     from fabula.bot_messages where notice_key = 'infra_drift' order by id desc limit 1),
  (select body from fabula.bot_messages where notice_key = 'infra_drift' order by id desc limit 1));

-- the uptime alert names GitHub Pages
select pg_temp.ck('uptime alert: «GitHub Pages / Supabase»',
  pg_get_functiondef('fabula.infra_collect()'::regprocedure) like '%non rispondono (GitHub Pages / Supabase)%'
  and pg_get_functiondef('fabula.infra_collect()'::regprocedure) not ilike '%netlify%');
select pg_temp.ck('no database function mentions Netlify any more, except the v1.08 wording kept for a Netlify address',
  (select coalesce(array_agg(p.proname::text order by p.proname), '{}') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('fabula', 'public') and p.prokind = 'f' and pg_get_functiondef(p.oid) ilike '%netlify%') = array['infra_checks'],
  (select string_agg(p.proname, ', ') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('fabula', 'public') and p.prokind = 'f' and pg_get_functiondef(p.oid) ilike '%netlify%'));

-- the app check against GitHub now speaks of the release
insert into fabula.infra_status (key, ok, data, checked_at, last_ok_at) values
  ('github_sw', true, '{"sw":"perla-v99"}', now(), now()), ('site', true, '{"sw":"perla-v98"}', now(), now())
on conflict (key) do update set ok = excluded.ok, data = excluded.data, checked_at = excluded.checked_at, last_ok_at = excluded.last_ok_at;
select pg_temp.ck('«App pubblicata = GitHub» behind: approve the release on GitHub',
  (fabula.infra_checks() -> 'app_deployed' ->> 'detail') = 'Sito perla-v98, GitHub perla-v99: il rilascio non ha ancora pubblicato l''app (approvalo su GitHub: Actions → Release)',
  fabula.infra_checks() -> 'app_deployed' ->> 'detail');

-- the system-check bot's new prompt
select pg_temp.ck('ops_health prompt version', (select version from fabula.bot_prompt_versions where agent = 'ops_health') = '2422561503');

select pg_temp.ck('no new security finding without a reason', not exists (
  select 1 from fabula.security_findings() f where not exists (select 1 from fabula.security_accepted a where a.key = f.key)),
  (select string_agg(f.key, ', ') from fabula.security_findings() f where not exists (select 1 from fabula.security_accepted a where a.key = f.key)));
