-- v1.18a (audit S-1, step 2 of 4 towards a private repo; claude/s1-pre-change-review-2026-10-28.md): the database stops reading GitHub.
-- Until now the hourly infra probe fetched three public GitHub URLs without a token: the migration tree (api.github.com), the app's
-- sw.js (raw.githubusercontent.com) and the commit feed (github.com/…/commits/main.atom). On a private repo all three answer 404,
-- and «Ultimo codice su GitHub», «Migrazioni del repo uguali al database» and «App del tablet pubblicata» go blind.
-- From here GitHub says what main holds: the release workflow at every push to main (plan job, and again after an apply) and the
-- outside watcher at every run read it from their own checkout (tools/release/release.py github) and send the head commit, the
-- migration versions and the app version through public.fabula_outside_report, kind «github», with the backup token the watcher and
-- the release already use. The facts land in the same infra_status rows (github_tree, github_head, github_sw) with the same data the
-- probe produced, so infra_checks(), the go-live board, the drift notice and live_app_version() read them unchanged.
--   1. fabula.github_report(detail): checks and stores one report. Not callable by logins or anon.
--   2. public.fabula_outside_report: + kind «github», handled before the 8,000-character cut (210 versions are already 3,600).
--   3. fabula.infra_probe(): the three GitHub requests are gone; the tablet site and the two server functions are still probed hourly.
-- fabula.infra_collect() is unchanged: its GitHub branches are no longer reached (a report leaves no pending request on the row).
-- Rollback: tools/go-live/rollback/20261028200000_v118a_down.sql.

create or replace function fabula.github_report(p_detail jsonb, p_now timestamptz default now())
returns jsonb
language plpgsql
security invoker
set search_path to 'pg_catalog', 'fabula', 'public'
as $function$
declare
  v_sha text := p_detail->>'sha';
  v_title text := left(coalesce(p_detail->>'title', ''), 200);
  v_updated timestamptz;
  v_versions jsonb := p_detail->'versions';
  v_sw text := p_detail->>'sw';
  v_src text := coalesce(nullif(left(p_detail->>'source', 20), ''), '?');
  v_run text := left(coalesce(p_detail->>'run_url', ''), 200);
  v_n int;
  v_sw_ok boolean;
begin
  if jsonb_typeof(p_detail) is distinct from 'object' then
    raise exception 'resoconto GitHub non valido: non è un oggetto' using errcode = '22023';
  end if;
  if v_sha is null or v_sha !~ '^[0-9a-f]{40}$' then
    raise exception 'resoconto GitHub non valido: commit «%»', left(coalesce(v_sha, ''), 50) using errcode = '22023';
  end if;
  begin
    v_updated := (p_detail->>'updated')::timestamptz;
  exception when others then
    v_updated := null;
  end;
  if v_updated is null or v_updated > p_now + interval '10 minutes' then
    raise exception 'resoconto GitHub non valido: data del commit «%»', left(coalesce(p_detail->>'updated', ''), 40) using errcode = '22023';
  end if;
  if jsonb_typeof(v_versions) is distinct from 'array' or jsonb_array_length(v_versions) > 5000
     or exists (select 1 from jsonb_array_elements(v_versions) e where jsonb_typeof(e) <> 'string' or (e #>> '{}') !~ '^[0-9]{14}$') then
    raise exception 'resoconto GitHub non valido: elenco delle migrazioni' using errcode = '22023';
  end if;
  v_versions := (select coalesce(jsonb_agg(distinct x order by x), '[]'::jsonb) from jsonb_array_elements_text(v_versions) x);
  v_n := jsonb_array_length(v_versions);
  v_sw_ok := coalesce(v_sw ~ '^[A-Za-z0-9._-]{1,60}$', false);

  -- the same detail texts as the probe's (fabula._it_infra_detail translates them); no pending request: infra_collect leaves the rows alone
  insert into fabula.infra_status (key, ok, detail, data, req_id, sent_at, checked_at, last_ok_at, fail_streak)
  values ('github_tree', true, v_n || ' migration files on GitHub main',
          jsonb_build_object('versions', v_versions, 'sha', v_sha, 'source', v_src, 'run_url', v_run, 'reported_at', p_now),
          null, null, p_now, p_now, 0),
         ('github_head', true, left(v_sha, 7),
          jsonb_build_object('sha', v_sha, 'title', v_title, 'updated', v_updated, 'source', v_src),
          null, null, p_now, p_now, 0)
  on conflict (key) do update set ok = true, detail = excluded.detail, data = excluded.data, req_id = null, sent_at = null,
    checked_at = excluded.checked_at, last_ok_at = excluded.last_ok_at, fail_streak = 0;

  if v_sw_ok then
    insert into fabula.infra_status (key, ok, detail, data, req_id, sent_at, checked_at, last_ok_at, fail_streak)
    values ('github_sw', true, v_sw, jsonb_build_object('sw', v_sw), null, null, p_now, p_now, 0)
    on conflict (key) do update set ok = true, detail = excluded.detail, data = excluded.data, req_id = null, sent_at = null,
      checked_at = excluded.checked_at, last_ok_at = excluded.last_ok_at, fail_streak = 0;
  else
    -- like the probe: a sw.js without a version is a failed check, and the last good version is kept
    insert into fabula.infra_status (key, ok, detail, data, req_id, sent_at, checked_at, last_ok_at, fail_streak)
    values ('github_sw', false, 'GitHub main, sw.js without version', '{}'::jsonb, null, null, p_now, null, 1)
    on conflict (key) do update set ok = false, detail = excluded.detail, req_id = null, sent_at = null,
      checked_at = excluded.checked_at, fail_streak = infra_status.fail_streak + 1;
  end if;

  return jsonb_build_object('ok', true, 'sha', left(v_sha, 7), 'versions', v_n, 'sw', case when v_sw_ok then v_sw end);
end $function$;

revoke all on function fabula.github_report(jsonb, timestamptz) from public, anon, authenticated;
grant execute on function fabula.github_report(jsonb, timestamptz) to service_role;

CREATE OR REPLACE FUNCTION public.fabula_outside_report(p_token text, p_kind text, p_detail jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'fabula', 'public'
AS $function$
declare
  v_ok boolean;
  v_key text;
  v_detail jsonb := case when jsonb_typeof(p_detail) = 'object' then p_detail else '{}'::jsonb end;
begin
  if not coalesce(fabula.backup_check_token(p_token), false) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_kind is null or p_kind not in ('watcher', 'offsite_backup', 'restore_drill', 'release', 'github') then
    raise exception 'kind non valido: %', p_kind using errcode = '22023';
  end if;
  -- v1.18 (audit S-1): what GitHub main holds, from the release workflow and the outside watcher (the probe no longer reads GitHub).
  -- Before the 8,000-character cut below, which would drop the list of migration versions.
  if p_kind = 'github' then
    if length(v_detail::text) > 200000 then
      raise exception 'resoconto GitHub troppo grande' using errcode = '22023';
    end if;
    return fabula.github_report(v_detail);
  end if;
  if length(v_detail::text) > 8000 then
    v_detail := jsonb_strip_nulls(jsonb_build_object('ok', v_detail->'ok', 'stale', v_detail->'stale', 'summary', left(v_detail->>'summary', 300),
                  'error', left(v_detail->>'error', 300), 'run_url', left(v_detail->>'run_url', 200), 'truncated', true));
  end if;
  -- only an explicit {"ok": true} counts as success (audit review: a report without «ok» must not turn the board green)
  v_ok := coalesce(v_detail->'ok' = 'true'::jsonb, false);

  if p_kind = 'release' then                 -- v1.08: the plan or the rehearsal stopped before anyone was asked
    perform fabula.release_blocked(v_detail);
    return jsonb_build_object('ok', true);
  end if;

  if p_kind = 'restore_drill' then
    insert into fabula.agent_runs (agent, status, started_at, finished_at, summary, error, details)
    values ('restore_drill', case when v_ok then 'ok' else 'error' end, now(), now(),
            left(coalesce(v_detail->>'summary', 'Prova di ripristino su GitHub'), 500),
            case when v_ok then null else left(coalesce(v_detail->>'error', v_detail->>'summary', 'non riuscita'), 500) end,
            v_detail || jsonb_build_object('via', 'github'));
    return jsonb_build_object('ok', true);
  end if;

  v_key := case p_kind when 'watcher' then 'outside_watcher' else 'offsite_backup' end;
  insert into fabula.infra_status (key, ok, detail, data, checked_at, last_ok_at, fail_streak)
  values (v_key, v_ok, left(coalesce(v_detail->>'summary', case when v_ok then 'OK' else 'problema' end), 300), v_detail,
          now(), case when v_ok then now() end, case when v_ok then 0 else 1 end)
  on conflict (key) do update set
    ok = excluded.ok, detail = excluded.detail, data = excluded.data, checked_at = now(),
    last_ok_at = case when excluded.ok then now() else infra_status.last_ok_at end,
    fail_streak = case when excluded.ok then 0 else infra_status.fail_streak + 1 end;
  return jsonb_build_object('ok', true);
end $function$;

-- the hourly probe: the tablet site and the two server functions only (v1.18: GitHub reports itself, see above)
CREATE OR REPLACE FUNCTION fabula.infra_probe()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'fabula', 'public', 'extensions'
AS $function$
declare
  v_site text := rtrim(coalesce(fabula._setting('infra.site_url'), ''), '/');
  v_fn   text := 'https://ojkquhzaeypsphncjqwy.supabase.co/functions/v1/';
  v_ua   jsonb := jsonb_build_object('User-Agent', 'caseificio-ops-monitor');
  v_ts   text := extract(epoch from now())::bigint::text;
  r record; v_id bigint; v_out jsonb := '{}'::jsonb;
begin
  for r in select * from (values
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
end $function$;
