-- Rollback of v1.18a (audit S-1 step 2): puts back exactly what was live before it (captured on 28/10/2026, identical on production
-- and on a replay of main b84106b: public.fabula_outside_report md5(prosrc) 6923267785d40ff0c9198d37572d497d, fabula.infra_probe
-- fea5057314b18ee8b4dc91fbd98df27f), drops fabula.github_report and puts the wording back (below). The probe then reads GitHub again, which works only while the repo
-- is public. To use it, copy it into supabase/migrations under a new, later version and release it through the pipeline like any other
-- release (the pipeline never re-releases an older commit). The github_* rows of fabula.infra_status are left as they are: the next
-- hourly probe overwrites them.

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
  if p_kind is null or p_kind not in ('watcher', 'offsite_backup', 'restore_drill', 'release') then
    raise exception 'kind non valido: %', p_kind using errcode = '22023';
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

CREATE OR REPLACE FUNCTION fabula.infra_probe()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'fabula', 'public', 'extensions'
AS $function$
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
end $function$;

drop function if exists fabula.github_report(jsonb, timestamptz);

-- the wording back as it was (infra_checks md5(prosrc) 10b1c9da71a6df1ce1e43285c4985162 and the three hints)
do $$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.infra_checks()'::regprocedure);
  n := replace(d, $s$'In attesa del primo resoconto di GitHub (a ogni rilascio e a ogni giro del controllo esterno)'$s$,
                  $s$'In attesa del primo controllo di GitHub (ogni ora, ai :43)'$s$);
  if n = d then raise exception 'v118a down: infra_checks waiting text not found'; end if;
  execute n;
end $$;

update fabula.dash_checks set hint_it = 'Si chiude da solo (controllo orario).'
 where key in ('code_pushed', 'repo_sync') and hint_it = 'Si chiude da solo: GitHub lo comunica a ogni rilascio e a ogni giro del controllo esterno.';
update fabula.dash_checks set hint_it = 'Si chiude da solo (controllo orario).'
 where key = 'app_deployed' and hint_it = 'Si chiude da solo: il sito si controlla ogni ora, GitHub lo comunica a ogni rilascio e a ogni giro del controllo esterno.';

-- The three workflow steps that send «github» reports (release.yml ×2, watch.yml) can stay: after this rollback each run only logs a
-- «kind non valido: github» warning. Remove them in the same commit to keep the logs clean.
