-- v0.68 infra autopilot test (run on a database built by replay.sh). Every block raises if a check fails.
\set ON_ERROR_STOP 1
-- the scratch database does not record v068 itself as a migration: add every replayed version so "live" = repo
insert into supabase_migrations.schema_migrations(version) values ('20261005000000') on conflict do nothing;  -- harmless extra version

-- 1. security scan on the replayed schema
select jsonb_pretty(fabula.security_scan() -> 'new') as new_findings;

-- 2. probe + simulated answers (everything healthy)
select fabula.infra_probe();
create temp table want as select key, req_id from fabula.infra_status where req_id is not null;
insert into net._http_response(id, status_code, content)
select w.req_id, case when w.key like 'fn_%' then 403 else 200 end,
  case w.key
    when 'github_tree' then (select jsonb_build_object('sha', 'abc', 'truncated', false, 'tree',
                               jsonb_agg(jsonb_build_object('path', 'supabase/migrations/' || version || '_x.sql', 'type', 'blob'))
                               || '[{"path":"fabula-tablet/sw.js","type":"blob"}]'::jsonb)::text from supabase_migrations.schema_migrations)
    when 'github_sw' then 'const CACHE = ''perla-v39'';'
    when 'site' then 'const CACHE = ''perla-v39'';'
    when 'github_head' then '<feed><title>Recent Commits</title><entry>
    <id>tag:github.com,2008:Grit::Commit/fdc56b02e5ba4be6b310914c371067e16403ae15</id>
    <title>
        v0.67: &#39;Password dimenticata?&#39; on every login screen
    </title>
    <updated>2026-10-05T15:38:53Z</updated></entry><entry><title>older</title></entry></feed>'
    else '{"error":"forbidden"}' end
from want w;
select fabula.infra_collect();
do $$ declare c jsonb := fabula.infra_checks(); k text; begin
  raise notice 'checks: %', jsonb_pretty(c);
  foreach k in array array['code_pushed','repo_sync','app_deployed','restore_tested','uptime'] loop
    if not (c->k->>'done')::boolean then raise exception 'FAIL healthy: % = %', k, c->k; end if;
  end loop;
  if (c->'code_pushed'->>'detail') not like 'main fdc56b0 · v0.67: ''Password dimenticata?''%' then raise exception 'FAIL head title: %', c->'code_pushed'->>'detail'; end if;
  raise notice 'PASS 2 healthy: all infra checks green';
end $$;

-- 3. ops_dashboard carries 36 checks (35 since the v0.75 review + outside watcher), the 6 infra ones as auto
do $$ declare d jsonb := fabula.ops_dashboard(); n int; a int; begin
  select count(*), count(*) filter (where e->>'kind' = 'auto' and e->>'key' in ('code_pushed','repo_sync','app_deployed','restore_tested','advisors_clean','uptime'))
    into n, a from jsonb_array_elements(d->'checks') e;
  if n <> 36 or a <> 6 then raise exception 'FAIL dashboard checks n=% auto infra=%', n, a; end if;
  raise notice 'PASS 3 dashboard: 36 checks, 6 infra auto';
end $$;

-- 4. trouble: live migration not on GitHub, Netlify behind, farm-order 500 twice, GitHub rate limit
insert into supabase_migrations.schema_migrations(version) values ('20991231000000');
select fabula.infra_probe();
truncate want; insert into want select key, req_id from fabula.infra_status where req_id is not null;
insert into net._http_response(id, status_code, content)
select req_id, case key when 'github_tree' then 403 when 'fn_farm_order' then 503 when 'fn_backup_export' then 403 else 200 end,
       case key when 'site' then 'const CACHE = ''perla-v38'';' when 'github_sw' then 'const CACHE = ''perla-v39'';' when 'github_head' then '' else '{}' end
  from want where key <> 'github_head';
-- github_head gets no answer at all
select fabula.infra_collect();
select fabula.infra_probe();
truncate want; insert into want select key, req_id from fabula.infra_status where req_id is not null;
insert into net._http_response(id, status_code, content)
select req_id, case key when 'github_tree' then 403 when 'fn_farm_order' then 503 when 'fn_backup_export' then 403 else 200 end,
       case key when 'site' then 'const CACHE = ''perla-v38'';' when 'github_sw' then 'const CACHE = ''perla-v39'';' else '{}' end
  from want;
select fabula.infra_collect();
do $$ declare c jsonb := fabula.infra_checks(); t fabula.infra_status; begin
  raise notice 'checks: %', jsonb_pretty(c);
  if (c->'code_pushed'->>'done')::boolean then raise exception 'FAIL code_pushed should be red'; end if;
  if (c->'code_pushed'->>'detail') not like '1 live migration(s) not on GitHub: 20991231000000%' then raise exception 'FAIL code_pushed detail %', c->'code_pushed'; end if;
  if (c->'app_deployed'->>'done')::boolean or (c->'app_deployed'->>'detail') <> 'Live perla-v38, GitHub perla-v39 — Netlify has not deployed yet' then raise exception 'FAIL app_deployed %', c->'app_deployed'; end if;
  if (c->'uptime'->>'done')::boolean then raise exception 'FAIL uptime should be red'; end if;
  select * into t from fabula.infra_status where key = 'github_tree';
  if t.ok is not null or jsonb_array_length(t.data->'versions') < 90 then raise exception 'FAIL rate limit should keep the list: %', t; end if;
  if not exists (select 1 from fabula.notices where key = 'infra_uptime' and resolved_at is null and severity = 'alert') then raise exception 'FAIL no uptime alert'; end if;
  if exists (select 1 from fabula.notices where key = 'infra_drift' and resolved_at is null) then raise exception 'FAIL drift notice too early'; end if;
  raise notice 'PASS 4 trouble detected, uptime alert raised, GitHub list kept on rate limit';
end $$;

-- 5. drift notice after 6 h
insert into fabula.infra_status(key, data) values ('drift', '{"since":{"code_pushed":"2026-01-01T00:00:00Z"}}')
  on conflict (key) do update set data = excluded.data;
select fabula.infra_probe(); truncate want; insert into want select key, req_id from fabula.infra_status where req_id is not null;
insert into net._http_response(id, status_code, content) select req_id, case when key like 'fn_%' then 403 else 200 end,
  case key when 'github_tree' then '{"tree":[]}' when 'site' then 'const CACHE = ''perla-v39'';' when 'github_sw' then 'const CACHE = ''perla-v39'';' else '' end from want;
select fabula.infra_collect();
do $$ begin
  if not exists (select 1 from fabula.notices where key = 'infra_drift' and resolved_at is null) then raise exception 'FAIL no drift notice'; end if;
  if exists (select 1 from fabula.notices where key = 'infra_uptime' and resolved_at is null) then raise exception 'FAIL uptime notice not resolved'; end if;
  raise notice 'PASS 5 drift notice after 6 h, uptime notice resolved when back up';
end $$;

-- 6. advisors from the bot: same counts → ok; unknown lint → notice
do $$ declare s jsonb := (select data->'counts' from fabula.infra_status where key = 'security_scan'); r jsonb; begin
  r := fabula.infra_record_advisors((select jsonb_agg(jsonb_build_object('name', k, 'level', 'WARN', 'count', v::int)) from jsonb_each_text(s) x(k, v) where k not in ('anon_table_grant','public_bucket')));
  if jsonb_array_length(r->'unknown') <> 0 then raise exception 'FAIL advisors matching counts flagged: %', r; end if;
  r := fabula.infra_record_advisors('[{"name":"auth_leaked_password_protection","level":"WARN","count":1}]');
  if jsonb_array_length(r->'unknown') <> 1 or not exists (select 1 from fabula.notices where key = 'infra_advisors' and resolved_at is null) then raise exception 'FAIL unknown lint not flagged: %', r; end if;
  raise notice 'PASS 6 advisor report: known counts accepted, unknown lint raises a notice';
end $$;

-- 7. new security problem → alert; fixed → resolved
create view fabula.v_test_definer as select 1 as x;
select fabula.security_scan();
do $$ begin
  if not exists (select 1 from fabula.notices where key = 'infra_security' and resolved_at is null and severity = 'alert') then raise exception 'FAIL definer view not flagged'; end if;
end $$;
alter view fabula.v_test_definer set (security_invoker = true);
select fabula.security_scan();
do $$ begin
  if exists (select 1 from fabula.notices where key = 'infra_security' and resolved_at is null) then raise exception 'FAIL security notice not resolved'; end if;
  raise notice 'PASS 7 security scan raises and resolves';
end $$;

-- 8. permissions: bot-only functions refused to signed-in users; the two views are security_invoker
do $$ begin
  if has_function_privilege('authenticated', 'fabula.promo_set_code(uuid,text,text)', 'EXECUTE')
     or has_function_privilege('authenticated', 'fabula.sell_down_codes_needed()', 'EXECUTE')
     or has_function_privilege('anon', 'fabula.company_name(boolean)', 'EXECUTE')
     or has_function_privilege('authenticated', 'fabula.infra_collect()', 'EXECUTE')
     or has_function_privilege('authenticated', 'fabula.backup_auth_users()', 'EXECUTE')
     or has_function_privilege('authenticated', 'fabula.ops_dashboard()', 'EXECUTE') then raise exception 'FAIL grants'; end if;
  if not has_function_privilege('service_role', 'fabula.backup_auth_users()', 'EXECUTE') then raise exception 'FAIL service_role grant'; end if;
  if exists (select 1 from pg_class where relname in ('v_sell_down_today','v_shopify_inventory_push') and not coalesce(reloptions && array['security_invoker=true'], false)) then raise exception 'FAIL views'; end if;
  raise notice 'PASS 8 grants and views';
end $$;

-- 9. restore drill + backup extras
do $$ declare c jsonb := fabula.infra_checks(); begin
  if not (c->'restore_tested'->>'done')::boolean then raise exception 'FAIL restore_tested %', c->'restore_tested'; end if;
  insert into fabula.agent_runs(agent, status, summary, error) values ('restore_drill', 'error', 'drill failed', '3 tables differ');
  c := fabula.infra_checks();
  if (c->'restore_tested'->>'done')::boolean or (c->'restore_tested'->>'detail') not like 'Last drill FAILED%' then raise exception 'FAIL failed drill %', c->'restore_tested'; end if;
  raise notice 'PASS 9 restore drill: passed drill green, failed drill red (%)', c->'restore_tested'->>'detail';
end $$;
insert into auth.users(id, email) values ('11111111-1111-1111-1111-111111111111', 'test@example.com');
insert into storage.buckets(id, name) values ('documents', 'documents') on conflict do nothing;
insert into storage.objects(bucket_id, name, metadata) values ('documents', 'ddt/a.jpg', '{"size": 1234, "mimetype": "image/jpeg", "eTag": "\"x\""}'),
  ('documents', 'backups/latest.json.gz', '{"size": 9}');
do $$ declare u jsonb := fabula.backup_auth_users(); m jsonb := fabula.backup_storage_manifest(); begin
  if jsonb_array_length(u) < 1 or u::text like '%encrypted_password%' then raise exception 'FAIL auth users %', u; end if;
  if jsonb_array_length(m) <> 1 or m->0->>'name' <> 'ddt/a.jpg' or (m->0->>'size')::int <> 1234 then raise exception 'FAIL manifest %', m; end if;
  raise notice 'PASS 10 backup extras: % login(s), % file(s), backups/ excluded', jsonb_array_length(u), jsonb_array_length(m);
end $$;
