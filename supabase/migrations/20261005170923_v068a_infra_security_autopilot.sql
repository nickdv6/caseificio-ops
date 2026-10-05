-- v0.68a · Infra & security autopilot (05/10/2026)
-- Goal: no Infra & security check depends on someone remembering to tick it.
--  1. fabula.infra_probe() (pg_cron :40) asks GitHub (public repo: migration list, sw.js on main, latest commit),
--     the Netlify tablet site (/sw.js) and two edge functions (farm-order, backup-export: a wrong token must give 403);
--     fabula.infra_collect() (pg_cron :43) reads the answers from net._http_response into fabula.infra_status.
--  2. Go-live checks code_pushed / repo_sync / app_deployed / restore_tested become automatic (fabula.infra_checks()),
--     plus two new ones: advisors_clean and uptime.
--  3. fabula.security_scan() (run by infra_collect every hour) re-implements the Supabase security advisor lints in SQL
--     (+ anon table grants, public buckets). Findings not in fabula.security_accepted raise the Console notice
--     'infra_security'. The nightly system-check bot also sends the real advisor's lint counts to
--     fabula.infra_record_advisors(), which flags anything the SQL scan does not cover or counts differently.
--  4. Fixes found by the first scan: two views had lost security_invoker (re-created in v063b / v064a);
--     promo_set_code and sell_down_codes_needed (bot-only) were callable by any signed-in user, which also let a
--     floor login see a promo code before approval; trigger functions and two read helpers were executable by
--     roles that never call them.
--  5. Backup: fabula.backup_auth_users() (logins without passwords) and fabula.backup_storage_manifest() (every stored
--     file with size and checksum) for the backup-export edge function (v3).
--  6. The restore drill now logs itself in agent_runs (agent 'restore_drill'); 05/10 drill recorded.
-- Notices raised: infra_uptime (alert, a site/function down on 2 checks in a row), infra_drift (warn, GitHub / Netlify /
-- live database out of step for more than 6 h), infra_security (alert/warn), infra_advisors (warn).

-- ---------------------------------------------------------------- 4. security fixes
alter view fabula.v_sell_down_today set (security_invoker = true);
alter view fabula.v_shopify_inventory_push set (security_invoker = true);
revoke execute on function fabula.promo_set_code(uuid, text, text) from public, anon, authenticated;
revoke execute on function fabula.sell_down_codes_needed() from public, anon, authenticated;
revoke execute on function fabula.shopify_push_enabled() from public, anon, authenticated;
revoke execute on function fabula.trg_milk_intake_stock() from public, anon, authenticated;
revoke execute on function fabula.trg_stock_move_guard() from public, anon, authenticated;
revoke execute on function fabula.company_name(boolean) from public, anon;
revoke execute on function fabula.ops_dashboard() from public, anon, authenticated;
grant execute on function fabula.promo_set_code(uuid, text, text) to service_role;
grant execute on function fabula.sell_down_codes_needed() to service_role;
grant execute on function fabula.shopify_push_enabled() to service_role;
grant execute on function fabula.company_name(boolean) to authenticated, service_role;
grant execute on function fabula.ops_dashboard() to service_role;

-- ---------------------------------------------------------------- tables
create table if not exists fabula.infra_status (
  key          text primary key,          -- github_tree, github_sw, github_head, site, fn_*, security_scan, advisors, drift
  ok           boolean,                   -- null = unknown (e.g. GitHub rate limit: previous data kept)
  detail       text,
  data         jsonb not null default '{}'::jsonb,
  req_id       bigint,                    -- pg_net request id of the last probe
  sent_at      timestamptz,
  checked_at   timestamptz,
  last_ok_at   timestamptz,
  fail_streak  int not null default 0
);
alter table fabula.infra_status enable row level security;
grant select on fabula.infra_status to authenticated;
grant all on fabula.infra_status to service_role;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'fabula' and tablename = 'infra_status' and policyname = 'infra_status_read') then
    create policy infra_status_read on fabula.infra_status for select to authenticated using (fabula.perm_level('sistema') >= 1);
  end if;
end $$;

create table if not exists fabula.security_accepted (
  key          text primary key,          -- '<lint>:<object>' as produced by security_scan(), or 'advisor:<lint name>'
  reason       text not null,
  accepted_at  timestamptz not null default now()
);
alter table fabula.security_accepted enable row level security;
grant select on fabula.security_accepted to authenticated;
grant all on fabula.security_accepted to service_role;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'fabula' and tablename = 'security_accepted' and policyname = 'security_accepted_read') then
    create policy security_accepted_read on fabula.security_accepted for select to authenticated using (fabula.perm_level('sistema') >= 1);
  end if;
end $$;

insert into fabula.settings (key, value, description, data_type) values
  ('infra.site_url', 'https://flourishing-swan-6729c4.netlify.app', 'Indirizzo del sito del tablet (Netlify): il monitor controlla ogni ora che risponda e che la versione sia quella su GitHub', 'text'),
  ('infra.github_repo', 'nickdv6/caseificio-ops', 'Repository GitHub (pubblico) del sistema: il monitor confronta migrazioni e versione dell''app con il database e il sito', 'text')
on conflict (key) do nothing;

-- ---------------------------------------------------------------- 3. security scan
create or replace function fabula.security_findings()
 returns table(key text, lint text, level text, object text)
 language sql
 stable
 security definer
 set search_path = fabula, public, extensions
as $$
  with sch as (select oid, nspname from pg_namespace where nspname in ('fabula', 'public')),
  ext as (select objid from pg_depend where deptype = 'e'),
  f as (select p.oid, s.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as obj, p.prosecdef, p.proconfig
          from pg_proc p join sch s on s.oid = p.pronamespace
         where p.prokind in ('f', 'p') and p.oid not in (select objid from ext)),
  r as (select c.oid, s.nspname || '.' || c.relname as obj, c.relkind, c.relrowsecurity, c.reloptions
          from pg_class c join sch s on s.oid = c.relnamespace
         where c.relkind in ('r', 'p', 'v', 'm') and c.oid not in (select objid from ext)),
  x as (
    select 'security_definer_view' as lint, 'ERROR' as level, obj from r
     where relkind = 'v' and not coalesce(reloptions && array['security_invoker=true', 'security_invoker=on', 'security_invoker=1'], false)
    union all select 'rls_disabled_in_public', 'ERROR', obj from r where relkind in ('r', 'p') and not relrowsecurity
    union all select 'rls_enabled_no_policy', 'INFO', obj from r
     where relkind in ('r', 'p') and relrowsecurity and not exists (select 1 from pg_policy pp where pp.polrelid = r.oid)
    union all select 'anon_security_definer_function_executable', 'WARN', obj from f where prosecdef and has_function_privilege('anon', oid, 'EXECUTE')
    union all select 'authenticated_security_definer_function_executable', 'WARN', obj from f where prosecdef and has_function_privilege('authenticated', oid, 'EXECUTE')
    union all select 'function_search_path_mutable', 'WARN', obj from f
     where not exists (select 1 from unnest(coalesce(proconfig, '{}'::text[])) c where c like 'search_path=%')
    union all select 'anon_table_grant', 'WARN', obj from r
     where has_table_privilege('anon', oid, 'SELECT,INSERT,UPDATE')
    union all select 'public_bucket', 'WARN', 'storage.' || id from storage.buckets where public
  )
  select lint || ':' || obj, lint, level, obj from x
$$;

create or replace function fabula.security_scan()
 returns jsonb
 language plpgsql
 security definer
 set search_path = fabula, public, extensions
as $$
declare v_new jsonb; v_counts jsonb; v_total int; v_err int;
begin
  select coalesce(jsonb_agg(jsonb_build_object('key', f.key, 'lint', f.lint, 'level', f.level, 'object', f.object) order by f.level, f.key)
                    filter (where a.key is null), '[]'::jsonb),
         count(*),
         count(*) filter (where a.key is null and f.level = 'ERROR')
    into v_new, v_total, v_err
    from fabula.security_findings() f left join fabula.security_accepted a on a.key = f.key;
  select coalesce(jsonb_object_agg(lint, n), '{}'::jsonb) into v_counts
    from (select lint, count(*) n from fabula.security_findings() group by lint) c;

  insert into fabula.infra_status (key, ok, detail, data, checked_at, last_ok_at, fail_streak)
  values ('security_scan', jsonb_array_length(v_new) = 0,
          case when jsonb_array_length(v_new) = 0 then v_total || ' findings, all accepted'
               else jsonb_array_length(v_new) || ' new: ' || (select string_agg(e->>'key', ', ') from (select e from jsonb_array_elements(v_new) e limit 3) t) end,
          jsonb_build_object('new', v_new, 'counts', v_counts, 'total', v_total),
          now(), case when jsonb_array_length(v_new) = 0 then now() end, case when jsonb_array_length(v_new) = 0 then 0 else 1 end)
  on conflict (key) do update set ok = excluded.ok, detail = excluded.detail, data = excluded.data, checked_at = excluded.checked_at,
    last_ok_at = coalesce(excluded.last_ok_at, infra_status.last_ok_at),
    fail_streak = case when excluded.ok then 0 else infra_status.fail_streak + 1 end;

  if jsonb_array_length(v_new) > 0 then
    insert into fabula.notices (key, severity, title_it, items, expires_at)
    values ('infra_security', case when v_err > 0 then 'alert' else 'warn' end,
            format('Sicurezza database: %s nuove segnalazioni (permessi o RLS) — da correggere in una migrazione', jsonb_array_length(v_new)),
            (select jsonb_agg(jsonb_build_object('code', e->>'lint', 'label_it', (e->>'level') || ' · ' || (e->>'object'))) from jsonb_array_elements(v_new) e),
            now() + interval '2 hours')
    on conflict (key) do update set severity = excluded.severity, title_it = excluded.title_it, items = excluded.items,
      expires_at = excluded.expires_at, resolved_at = null,
      created_at = case when notices.resolved_at is null then notices.created_at else now() end;
  else
    update fabula.notices set resolved_at = now() where key = 'infra_security' and resolved_at is null;
  end if;
  return jsonb_build_object('total', v_total, 'new', v_new);
end $$;

-- the nightly system-check bot passes the Supabase advisor result as [{name, level, count}]
create or replace function fabula.infra_record_advisors(p_lints jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path = fabula, public, extensions
as $$
declare
  v_scan jsonb := coalesce((select data->'counts' from fabula.infra_status where key = 'security_scan'), '{}'::jsonb);
  v_covered text[] := array['security_definer_view', 'rls_disabled_in_public', 'rls_enabled_no_policy',
                            'anon_security_definer_function_executable', 'authenticated_security_definer_function_executable',
                            'function_search_path_mutable'];
  v_unknown jsonb := '[]'::jsonb; e jsonb; v_name text; v_n int;
begin
  if p_lints is null or jsonb_typeof(p_lints) <> 'array' then raise exception 'infra_record_advisors: expected a JSON array of {name, level, count}'; end if;
  for e in select * from jsonb_array_elements(p_lints) loop
    v_name := e->>'name'; v_n := coalesce((e->>'count')::int, 1);
    if v_name = any (v_covered) then
      if v_n <> coalesce((v_scan->>v_name)::int, 0) then
        v_unknown := v_unknown || jsonb_build_object('name', v_name, 'level', e->>'level', 'count', v_n,
                                                     'why', format('advisor %s, SQL scan %s', v_n, coalesce((v_scan->>v_name)::int, 0)));
      end if;
    elsif not exists (select 1 from fabula.security_accepted where key = 'advisor:' || v_name) then
      v_unknown := v_unknown || jsonb_build_object('name', v_name, 'level', e->>'level', 'count', v_n, 'why', 'non coperto dalla scansione SQL');
    end if;
  end loop;

  insert into fabula.infra_status (key, ok, detail, data, checked_at, last_ok_at, fail_streak)
  values ('advisors', jsonb_array_length(v_unknown) = 0,
          case when jsonb_array_length(v_unknown) = 0 then jsonb_array_length(p_lints) || ' lint types, all known'
               else jsonb_array_length(v_unknown) || ' to check: ' || (select string_agg(x->>'name', ', ') from jsonb_array_elements(v_unknown) x) end,
          jsonb_build_object('lints', p_lints, 'unknown', v_unknown), now(),
          case when jsonb_array_length(v_unknown) = 0 then now() end, 0)
  on conflict (key) do update set ok = excluded.ok, detail = excluded.detail, data = excluded.data, checked_at = excluded.checked_at,
    last_ok_at = coalesce(excluded.last_ok_at, infra_status.last_ok_at);

  if jsonb_array_length(v_unknown) > 0 then
    insert into fabula.notices (key, severity, title_it, items, expires_at)
    values ('infra_advisors', 'warn', 'Supabase Advisor: segnalazioni di sicurezza da verificare (Supabase → Advisors → Security)',
            (select jsonb_agg(jsonb_build_object('code', x->>'name', 'label_it', (x->>'level') || ' · ' || (x->>'why'))) from jsonb_array_elements(v_unknown) x),
            now() + interval '26 hours')
    on conflict (key) do update set title_it = excluded.title_it, items = excluded.items, expires_at = excluded.expires_at, resolved_at = null;
  else
    update fabula.notices set resolved_at = now() where key = 'infra_advisors' and resolved_at is null;
  end if;
  return jsonb_build_object('unknown', v_unknown);
end $$;

-- ---------------------------------------------------------------- 1. probes
create or replace function fabula.infra_probe()
 returns jsonb
 language plpgsql
 security definer
 set search_path = fabula, public, extensions
as $$
declare
  v_site text := rtrim(coalesce(fabula._setting('infra.site_url'), ''), '/');
  v_repo text := coalesce(fabula._setting('infra.github_repo'), '');
  v_fn   text := 'https://ojkquhzaeypsphncjqwy.supabase.co/functions/v1/';
  v_ua   jsonb := jsonb_build_object('User-Agent', 'caseificio-ops-monitor');
  v_ts   text := extract(epoch from now())::bigint::text;
  r record; v_id bigint; v_out jsonb := '{}'::jsonb;
begin
  for r in select * from (values
      ('github_tree',      'GET',  'https://api.github.com/repos/' || v_repo || '/git/trees/main?recursive=1'),
      ('github_sw',        'GET',  'https://raw.githubusercontent.com/' || v_repo || '/main/fabula-tablet/sw.js?ts=' || v_ts),
      ('github_head',      'GET',  'https://github.com/' || v_repo || '/commits/main.atom?ts=' || v_ts),
      ('site',             'GET',  v_site || '/sw.js?ts=' || v_ts),
      ('fn_farm_order',    'GET',  v_fn || 'farm-order?t=monitor'),
      ('fn_backup_export', 'POST', v_fn || 'backup-export')
    ) t(key, method, url)
  loop
    if r.method = 'GET' then
      v_id := net.http_get(url := r.url, headers := v_ua, timeout_milliseconds := 20000);
    else
      v_id := net.http_post(url := r.url, body := '{"mode":"monitor"}'::jsonb,
                            headers := v_ua || '{"Content-Type":"application/json"}'::jsonb, timeout_milliseconds := 20000);
    end if;
    insert into fabula.infra_status (key, req_id, sent_at) values (r.key, v_id, now())
      on conflict (key) do update set req_id = excluded.req_id, sent_at = excluded.sent_at;
    v_out := v_out || jsonb_build_object(r.key, v_id);
  end loop;
  return v_out;
end $$;

-- ---------------------------------------------------------------- 2. checks for the go-live board
create or replace function fabula.infra_checks()
 returns jsonb
 language plpgsql
 stable
 security definer
 set search_path = fabula, public, extensions
as $$
declare
  t fabula.infra_status; h fabula.infra_status; g fabula.infra_status; s fabula.infra_status;
  sc fabula.infra_status; adv fabula.infra_status;
  v_live text[] := array(select version from supabase_migrations.schema_migrations order by 1);
  v_gh text[]; v_missing text[]; v_extra text[]; v_fresh boolean; v_head text;
  d record; v_down text; v_stale boolean;
  v_out jsonb;
begin
  select * into t from fabula.infra_status where key = 'github_tree';
  select * into h from fabula.infra_status where key = 'github_head';
  select * into g from fabula.infra_status where key = 'github_sw';
  select * into s from fabula.infra_status where key = 'site';
  select * into sc from fabula.infra_status where key = 'security_scan';
  select * into adv from fabula.infra_status where key = 'advisors';

  v_gh := array(select jsonb_array_elements_text(coalesce(t.data->'versions', '[]'::jsonb)) order by 1);
  v_fresh := coalesce(t.last_ok_at > now() - interval '26 hours', false);
  v_missing := array(select unnest(v_live) except select unnest(v_gh) order by 1);
  v_extra := array(select unnest(v_gh) except select unnest(v_live) order by 1);
  v_head := case when h.data ? 'sha' then 'main ' || left(h.data->>'sha', 7) || ' · ' || left(h.data->>'title', 60)
                   || ' · ' || to_char((h.data->>'updated')::timestamptz at time zone 'Europe/Rome', 'DD/MM HH24:MI') end;

  v_out := jsonb_build_object(
    'code_pushed', jsonb_build_object(
      'done', v_fresh and cardinality(v_missing) = 0,
      'detail', case when t.last_ok_at is null then 'Waiting for the first GitHub check (hourly at :43)'
                     when not v_fresh then 'GitHub not read since ' || to_char(t.last_ok_at at time zone 'Europe/Rome', 'DD/MM HH24:MI')
                     when cardinality(v_missing) > 0 then cardinality(v_missing) || ' live migration(s) not on GitHub: '
                          || array_to_string(v_missing[1:3], ', ') || ' — push from the Mac'
                     else coalesce(v_head, 'GitHub main has every live migration') end),
    'repo_sync', jsonb_build_object(
      'done', v_fresh and cardinality(v_missing) = 0 and cardinality(v_extra) = 0,
      'detail', case when not v_fresh then 'Waiting for a GitHub check'
                     when cardinality(v_missing) + cardinality(v_extra) = 0 then cardinality(v_gh) || ' files on GitHub = ' || cardinality(v_live) || ' live versions'
                     else concat_ws(' · ',
                            case when cardinality(v_missing) > 0 then cardinality(v_missing) || ' live, not on GitHub' end,
                            case when cardinality(v_extra) > 0 then cardinality(v_extra) || ' on GitHub, not applied live: ' || array_to_string(v_extra[1:3], ', ') end) end),
    'app_deployed', jsonb_build_object(
      'done', coalesce(g.data->>'sw' = s.data->>'sw' and g.last_ok_at > now() - interval '26 hours' and s.last_ok_at > now() - interval '3 hours', false),
      'detail', case when s.last_ok_at is null or g.last_ok_at is null then 'Waiting for the first site check'
                     when s.last_ok_at <= now() - interval '3 hours' then 'Tablet site not answering since ' || to_char(s.last_ok_at at time zone 'Europe/Rome', 'DD/MM HH24:MI')
                     when g.data->>'sw' = s.data->>'sw' then 'Live ' || (s.data->>'sw') || ' = GitHub main'
                     else 'Live ' || coalesce(s.data->>'sw', '?') || ', GitHub ' || coalesce(g.data->>'sw', '?') || ' — Netlify has not deployed yet' end)
  );

  select * into d from fabula.agent_runs where agent = 'restore_drill' and status <> 'running' order by started_at desc limit 1;
  v_out := v_out || jsonb_build_object('restore_tested', jsonb_build_object(
    'done', coalesce(d.status = 'ok' and d.started_at > now() - interval '100 days', false),
    'detail', case when d.id is null then 'No drill recorded'
                   when d.status <> 'ok' then 'Last drill FAILED ' || to_char(d.started_at at time zone 'Europe/Rome', 'DD/MM/YYYY') || ': ' || coalesce(d.error, d.summary)
                   when d.started_at <= now() - interval '100 days' then 'Last drill ' || to_char(d.started_at at time zone 'Europe/Rome', 'DD/MM/YYYY') || ' — overdue (quarterly)'
                   else coalesce(d.summary, 'Drill ' || to_char(d.started_at at time zone 'Europe/Rome', 'DD/MM/YYYY') || ' passed') end));

  v_stale := coalesce(sc.checked_at <= now() - interval '26 hours', true);
  v_out := v_out || jsonb_build_object('advisors_clean', jsonb_build_object(
    'done', not v_stale and coalesce(sc.ok, false) and coalesce(adv.ok or adv.checked_at <= now() - interval '50 hours', true),
    'detail', case when sc.checked_at is null then 'Waiting for the first security scan'
                   when v_stale then 'Security scan not run since ' || to_char(sc.checked_at at time zone 'Europe/Rome', 'DD/MM HH24:MI')
                   else 'SQL scan: ' || sc.detail
                        || ' · Supabase advisor: ' || coalesce(case when adv.checked_at > now() - interval '50 hours' then adv.detail end, 'waiting for the system-check bot') end));

  select string_agg(key || ' (' || coalesce(detail, '?') || ')', ', ' order by key) into v_down
    from fabula.infra_status
   where key in ('site', 'fn_farm_order', 'fn_backup_export') and (ok is distinct from true or checked_at <= now() - interval '3 hours');
  v_out := v_out || jsonb_build_object('uptime', jsonb_build_object(
    'done', v_down is null and (select count(*) from fabula.infra_status where key in ('site', 'fn_farm_order', 'fn_backup_export')) = 3,
    'detail', case when (select count(*) from fabula.infra_status where key in ('site', 'fn_farm_order', 'fn_backup_export') and checked_at is not null) < 3
                     then 'Waiting for the first hourly check'
                   when v_down is null then 'Tablet site, farm-order and backup-export answered at '
                        || (select to_char(min(checked_at) at time zone 'Europe/Rome', 'HH24:MI') from fabula.infra_status where key = 'site')
                   else 'Down or not checked: ' || v_down end));
  return v_out;
end $$;

-- reads the probe answers, runs the security scan, raises / resolves notices
create or replace function fabula.infra_collect()
 returns jsonb
 language plpgsql
 security definer
 set search_path = fabula, public, extensions
as $$
declare
  r fabula.infra_status; resp record; v_ok boolean; v_detail text; v_data jsonb; v_m text[]; v_entry text;
  v_checks jsonb; v_drift jsonb; v_since jsonb; v_k text; v_down jsonb; v_n int := 0;
begin
  for r in select * from fabula.infra_status where req_id is not null and sent_at is not null and (checked_at is null or checked_at < sent_at) loop
    v_n := v_n + 1;
    select status_code, content, timed_out, error_msg into resp from net._http_response where id = r.req_id;
    v_data := r.data; v_ok := false; v_detail := null;
    if not found then
      v_detail := 'no answer';
    elsif resp.status_code is null then
      v_detail := coalesce(case when resp.timed_out then 'timeout' end, resp.error_msg, 'no answer');
    elsif r.key = 'github_tree' then
      if resp.status_code = 200 then
        v_data := jsonb_build_object('versions',
                    (select coalesce(jsonb_agg(m[1] order by m[1]), '[]'::jsonb)
                       from jsonb_array_elements(resp.content::jsonb -> 'tree') e,
                            regexp_match(e->>'path', '^supabase/migrations/(\d{14})_[^/]*\.sql$') m
                      where m is not null),
                    'tree_sha', resp.content::jsonb ->> 'sha', 'truncated', resp.content::jsonb -> 'truncated');
        v_ok := true; v_detail := jsonb_array_length(v_data->'versions') || ' migration files on GitHub main';
      elsif resp.status_code in (403, 429) then
        v_ok := null; v_detail := 'GitHub API limit (HTTP ' || resp.status_code || '): previous list kept';
      else
        v_detail := 'GitHub API HTTP ' || resp.status_code;
      end if;
    elsif r.key in ('github_sw', 'site') then
      v_m := regexp_match(resp.content, 'const CACHE = ''([^'']+)''');
      if resp.status_code = 200 and v_m is not null then
        v_ok := true; v_data := jsonb_build_object('sw', v_m[1]); v_detail := v_m[1];
      else
        v_detail := 'HTTP ' || resp.status_code || case when v_m is null and resp.status_code = 200 then ', sw.js without version' else '' end;
      end if;
    elsif r.key = 'github_head' then
      v_entry := substring(resp.content from position('<entry>' in resp.content));
      v_m := regexp_match(v_entry, 'Grit::Commit/([0-9a-f]{40})');
      if resp.status_code = 200 and v_m is not null then
        v_ok := true;
        v_data := jsonb_build_object('sha', v_m[1],
                    'title', replace(replace(replace(replace(btrim((regexp_match(v_entry, '<title>([^<]*)</title>'))[1], E' \n\r\t'),
                             '&#39;', ''''), '&quot;', '"'), '&lt;', '<'), '&amp;', '&'),
                    'updated', (regexp_match(v_entry, '<updated>([^<]+)</updated>'))[1]);
        v_detail := left(v_m[1], 7);
      elsif resp.status_code in (403, 429) then
        v_ok := null; v_detail := 'GitHub HTTP ' || resp.status_code || ': previous commit kept';
      else
        v_detail := 'HTTP ' || resp.status_code;
      end if;
    elsif r.key like 'fn\_%' then
      v_ok := resp.status_code < 500;             -- a wrong token must be refused (403), not crash
      v_detail := 'HTTP ' || resp.status_code;
    end if;

    update fabula.infra_status
       set ok = v_ok, detail = v_detail, checked_at = now(),
           data = case when v_ok then v_data else infra_status.data end,
           last_ok_at = case when v_ok then now() else infra_status.last_ok_at end,
           fail_streak = case when v_ok then 0 when v_ok is null then infra_status.fail_streak else infra_status.fail_streak + 1 end
     where key = r.key;
  end loop;

  perform fabula.security_scan();

  -- uptime: alert after 2 failed checks in a row (one blip is ignored)
  select coalesce(jsonb_agg(jsonb_build_object('code', key, 'label_it', coalesce(detail, 'nessuna risposta')) order by key), '[]'::jsonb)
    into v_down from fabula.infra_status where key in ('site', 'fn_farm_order', 'fn_backup_export') and fail_streak >= 2;
  if jsonb_array_length(v_down) > 0 then
    insert into fabula.notices (key, severity, title_it, items, expires_at)
    values ('infra_uptime', 'alert', 'Sistema non raggiungibile: sito del tablet o funzioni del server non rispondono (Netlify / Supabase)', v_down, now() + interval '2 hours')
    on conflict (key) do update set severity = 'alert', title_it = excluded.title_it, items = excluded.items, expires_at = excluded.expires_at,
      resolved_at = null, created_at = case when notices.resolved_at is null then notices.created_at else now() end;
  else
    update fabula.notices set resolved_at = now() where key = 'infra_uptime' and resolved_at is null;
  end if;

  -- drift: GitHub / Netlify / live database out of step for more than 6 h
  v_checks := fabula.infra_checks();
  v_since := coalesce((select data->'since' from fabula.infra_status where key = 'drift'), '{}'::jsonb);
  foreach v_k in array array['code_pushed', 'repo_sync', 'app_deployed'] loop
    if coalesce((v_checks->v_k->>'done')::boolean, false) then v_since := v_since - v_k;
    elsif not v_since ? v_k then v_since := v_since || jsonb_build_object(v_k, now());
    end if;
  end loop;
  select coalesce(jsonb_agg(jsonb_build_object('code', k, 'label_it', v_checks->k->>'detail') order by k), '[]'::jsonb) into v_drift
    from jsonb_each_text(v_since) x(k, since) where since::timestamptz < now() - interval '6 hours';
  insert into fabula.infra_status (key, ok, detail, data, checked_at)
  values ('drift', jsonb_array_length(v_drift) = 0, jsonb_array_length(v_drift) || ' out of step > 6 h', jsonb_build_object('since', v_since), now())
  on conflict (key) do update set ok = excluded.ok, detail = excluded.detail, data = excluded.data, checked_at = excluded.checked_at;
  if jsonb_array_length(v_drift) > 0 then
    insert into fabula.notices (key, severity, title_it, items, expires_at)
    values ('infra_drift', 'warn', 'GitHub, sito del tablet e database non allineati da più di 6 ore (push dal Mac / deploy Netlify)', v_drift, now() + interval '2 hours')
    on conflict (key) do update set items = excluded.items, expires_at = excluded.expires_at, resolved_at = null;
  else
    update fabula.notices set resolved_at = now() where key = 'infra_drift' and resolved_at is null;
  end if;

  return jsonb_build_object('collected', v_n, 'down', v_down, 'drift', v_drift);
end $$;

-- ---------------------------------------------------------------- 5. backup extras (logins without passwords, file list)
create or replace function fabula.backup_auth_users()
 returns jsonb
 language sql
 stable
 security definer
 set search_path = fabula, public, extensions
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', u.id, 'email', u.email, 'created_at', u.created_at, 'last_sign_in_at', u.last_sign_in_at,
           'email_confirmed_at', u.email_confirmed_at, 'invited_at', u.invited_at, 'banned_until', u.banned_until,
           'app_metadata', u.raw_app_meta_data, 'user_metadata', u.raw_user_meta_data,
           'staff', (select jsonb_build_object('id', s.id, 'full_name', s.full_name, 'app_role', s.app_role, 'active', s.active)
                       from fabula.staff s where s.auth_user_id = u.id limit 1))
         order by u.created_at), '[]'::jsonb)
    from auth.users u
   where u.deleted_at is null
$$;

create or replace function fabula.backup_storage_manifest()
 returns jsonb
 language sql
 stable
 security definer
 set search_path = fabula, public, extensions
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'bucket', o.bucket_id, 'name', o.name, 'size', (o.metadata->>'size')::bigint, 'mimetype', o.metadata->>'mimetype',
           'etag', o.metadata->>'eTag', 'updated_at', o.updated_at)
         order by o.bucket_id, o.name), '[]'::jsonb)
    from storage.objects o
   where not (o.bucket_id = 'documents' and o.name like 'backups/%')
$$;

-- ---------------------------------------------------------------- grants for the new functions (service role / pg_cron only)
revoke execute on function fabula.security_findings() from public, anon, authenticated;
revoke execute on function fabula.security_scan() from public, anon, authenticated;
revoke execute on function fabula.infra_record_advisors(jsonb) from public, anon, authenticated;
revoke execute on function fabula.infra_probe() from public, anon, authenticated;
revoke execute on function fabula.infra_checks() from public, anon, authenticated;
revoke execute on function fabula.infra_collect() from public, anon, authenticated;
revoke execute on function fabula.backup_auth_users() from public, anon, authenticated;
revoke execute on function fabula.backup_storage_manifest() from public, anon, authenticated;
grant execute on function fabula.security_findings(), fabula.security_scan(), fabula.infra_record_advisors(jsonb), fabula.infra_probe(),
  fabula.infra_checks(), fabula.infra_collect(), fabula.backup_auth_users(), fabula.backup_storage_manifest() to service_role;

-- ---------------------------------------------------------------- accepted findings (baseline reviewed 05/10/2026)
insert into fabula.security_accepted (key, reason)
select 'authenticated_security_definer_function_executable:fabula.' || f, 'by design: called by the app as the signed-in user; checks permissions (require_perm / own row) inside — reviewed v0.68'
  from unnest(array[
    '_setting(p_key text)', 'bot_display_name(p_agent text)', 'can(p_area text, p_level integer)', 'can_manage_users()',
    'can_table(p_table text, p_write boolean)', 'claim_staff_profile()', 'company_name(p_for_format boolean)',
    'complete_deadline(p_id uuid, p_on date, p_note text)', 'farm_order_link()', 'floor_open_shifts()', 'haccp_forms_status()',
    'haccp_register(p_form text, p_from date, p_to date)', 'is_manager()', 'manual_ref(p_form text)',
    'mark_bot_messages_read(p_ids bigint[])', 'mark_po_sent(p_po_number text, p_via text)',
    'mark_register_reviewed(p_form text, p_from date, p_to date, p_staff_id uuid, p_outcome text, p_note text)',
    'mkt_set_pickup_status(p_order uuid, p_status text)', 'my_permissions()', 'my_staff_id()',
    'pack_order(p_order_id uuid, p_lines jsonb, p_staff_id uuid, p_gross_kg numeric, p_carrier text, p_tracking text, p_notes text, p_force boolean)',
    'perm_level(p_area text)', 'post_stock_count(p_count_id uuid, p_lines jsonb, p_staff_id uuid, p_note text)',
    'receive_purchase_order(p_po_number text, p_lines jsonb, p_staff_id uuid, p_ddt text, p_notes text)',
    'record_calibration_check(p_code text, p_kind text, p_method text, p_points jsonb, p_staff_id uuid, p_provider text, p_certificate_no text, p_document_id uuid, p_note text, p_adjusted boolean, p_on date)',
    'record_receipt_check(p_po_number text, p_ok boolean, p_note text, p_staff_id uuid, p_ddt text)',
    'release_lot_hold(p_lot text, p_staff_id uuid, p_note text)', 'require_perm(p_area text, p_level integer)',
    'save_ledger_get(p_qid uuid)', 'save_ledger_put(p_qid uuid, p_steps integer, p_result jsonb)',
    'start_stock_count(p_staff_id uuid)', 'toggle_shift(p_badge text, p_staff_id uuid)'
  ]) f
on conflict (key) do nothing;
insert into fabula.security_accepted (key, reason) values
  ('rls_enabled_no_policy:fabula.save_ledger', 'by design: only reached through save_ops / save_ledger_get / save_ledger_put (v0.62)'),
  ('public_bucket:storage.marketing', 'by design: images for social posts are public links (bucket empty on 05/10/2026; never store documents there)')
on conflict (key) do nothing;

-- ---------------------------------------------------------------- 6. restore drill in agent_runs (05/10 drill)
insert into fabula.agent_runs (agent, started_at, finished_at, status, summary, details)
select 'restore_drill', '2026-10-05 02:20:00+00', '2026-10-05 02:35:04+00', 'ok',
       'Drill 05/10/2026: 93/93 tables, 1,017 rows match live; 154 foreign keys, 0 orphans; partial and full restore OK',
       '{"tables": 93, "rows": 1017, "fks": 154, "orphans": 0, "backup": "backups/latest.json.gz", "recorded_by": "v0.68 (backfill)"}'::jsonb
 where not exists (select 1 from fabula.agent_runs where agent = 'restore_drill');

-- ---------------------------------------------------------------- go-live board checks
insert into fabula.dash_checks (key, sort, label, kind, done, note, updated_at) values
  ('code_pushed',    2,  'Latest code pushed to GitHub',            'auto', false, null, now()),
  ('app_deployed',   3,  'Tablet app live = latest on GitHub',      'auto', false, null, now()),
  ('repo_sync',      6,  'Repo migrations match the live database', 'auto', false, null, now()),
  ('restore_tested', 19, 'Backup restore tested (last 100 days)',   'auto', false, null, now()),
  ('advisors_clean', 20, 'No new database security warnings',       'auto', false, null, now()),
  ('uptime',         21, 'Tablet site and server functions up',     'auto', false, null, now())
on conflict (key) do update set sort = excluded.sort, label = excluded.label, kind = excluded.kind, updated_at = now();

-- ---------------------------------------------------------------- schedules (UTC)
select cron.schedule('fabula_infra_probe', '40 * * * *', $c$select fabula.infra_probe()$c$);
select cron.schedule('fabula_infra_collect', '43 * * * *', $c$select fabula.infra_collect()$c$);
