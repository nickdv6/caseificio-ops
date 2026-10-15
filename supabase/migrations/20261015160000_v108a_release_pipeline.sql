-- v1.08a (15/10/2026): releases apply themselves after one approval on GitHub (project doc claude/audit-fixes-v108-2026-10-15.md).
-- Until v1.07 every release was a list of steps for Nick: a temporary Supabase token and a CLI deploy from the Mac, a paste in the SQL
-- Editor, a git merge and push, a Netlify deploy (15 of the free plan's 300 monthly credits; at zero the whole site stops, as on 14/10).
-- From v1.08, merging into main is the release: GitHub Actions (.github/workflows/release.yml, tools/release/release.py) waits for CI,
-- shows what will change, rehearses the database part on a copy, asks Nick to approve once («live» environment), then deploys the
-- server functions, applies the migrations in one transaction (the same guard as the SQL Editor scripts) and publishes the app on
-- GitHub Pages. This migration is the database side:
--   * fabula.releases: one row per automatic release (ok or stopped, what changed, the GitHub run).
--   * fabula.release_record(jsonb): called by the pipeline at the end (database role only). It writes the row and a message in the Bot
--     feed («Rilasci»): done (info, or warn when something is left to do by hand: steps of release.json, bot prompts to update), or
--     stopped (alert: Telegram, with what already changed and what did not).
--   * Panoramica → Sistema «Rilasci automatici» (infra_checks 'release'): the last release, green when it went through.
--   * The drift texts say what to do now: a migration on GitHub but not on the database, or an app not yet published, means a release
--     is waiting for the approval on GitHub (no more «SQL Editor» or «guarda Netlify»); a migration on the database but not on GitHub
--     was applied outside the release and its file goes on main.

-- ============================== the releases ==============================
create table if not exists fabula.releases (
  id         bigserial primary key,
  version    text,
  title_it   text,
  sha        text not null check (sha ~ '^[0-9a-f]{40}$'),
  base_sha   text check (base_sha is null or base_sha ~ '^[0-9a-f]{40}$'),
  status     text not null check (status in ('ok', 'failed')),
  steps      jsonb not null default '{}'::jsonb,
  error      text,
  after_it   jsonb not null default '[]'::jsonb,
  prompts    jsonb not null default '[]'::jsonb,
  warnings   jsonb not null default '[]'::jsonb,
  run_url    text check (run_url is null or run_url ~ '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/runs/[0-9]+'),
  message_id bigint,
  created_at timestamptz not null default now()
);
comment on table fabula.releases is 'v1.08: one row per automatic release (tools/release/release.py record → release_record). steps = {functions|database|site: {status ok|skipped|failed|warn, names|versions|sw, error}}; base_sha = what was live before; the git tag «live» on GitHub moves to sha only when status = ok.';
create index if not exists releases_recent on fabula.releases (id desc);
alter table fabula.releases enable row level security;
revoke all on fabula.releases from public, anon, authenticated;
grant select on fabula.releases to authenticated;
drop policy if exists releases_read on fabula.releases;
create policy releases_read on fabula.releases for select to authenticated using ((select fabula.can('sistema', 1)));
insert into fabula.table_areas (table_name, area, write_level, read_open) values ('releases', 'sistema', 3, false) on conflict do nothing;

-- the Bot feed's name for these messages, and where they open
insert into fabula.bot_nicknames (agent, nickname, title_it, sort, area) values ('rilascio', null, 'Rilasci', 210, 'sistema')
on conflict (agent) do update set title_it = excluded.title_it, area = excluded.area;

create or replace function fabula.release_record(p jsonb) returns bigint
language plpgsql security definer set search_path = fabula, public as $$
declare
  v_id bigint; v_msg bigint;
  v_ok boolean := coalesce(p->>'status', '') = 'ok';
  v_ver text; s jsonb := case when jsonb_typeof(p->'steps') = 'object' then p->'steps' else '{}'::jsonb end;
  v_done text[] := '{}'; v_todo text[] := '{}'; v_brief text[] := '{}'; v_failed text; v_err text;
  v_title text; v_sev text; v_body text; v_en text; x text; i int := 0;
  v_run text := nullif(p->>'run_url', '');
begin
  if coalesce(p->>'sha', '') !~ '^[0-9a-f]{40}$' then raise exception 'release_record: sha mancante o non valido'; end if;
  if v_run is not null and v_run !~ '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/runs/[0-9]+' then v_run := null; end if;
  v_ver := coalesce(nullif(btrim(p->>'version'), ''), left(p->>'sha', 7));
  v_err := nullif(btrim(left(coalesce(p->>'error', ''), 600)), '');

  insert into fabula.releases (version, title_it, sha, base_sha, status, steps, error, after_it, prompts, warnings, run_url)
  values (v_ver, nullif(btrim(p->>'title_it'), ''), p->>'sha', nullif(p->>'base_sha', ''), case when v_ok then 'ok' else 'failed' end, s, v_err,
          case when jsonb_typeof(p->'after_it') = 'array' then p->'after_it' else '[]' end,
          case when jsonb_typeof(p->'prompts') = 'array' then p->'prompts' else '[]' end,
          case when jsonb_typeof(p->'warnings') = 'array' then p->'warnings' else '[]' end, v_run)
  returning id into v_id;

  -- what reached production, in plain words
  if s #>> '{functions,status}' = 'ok' then
    v_done := v_done || ('funzioni del server: ' || (select string_agg(e, ', ') from jsonb_array_elements_text(coalesce(s #> '{functions,names}', '[]')) e));
  end if;
  if s #>> '{database,status}' = 'ok' then
    v_done := v_done || ('database: ' || fabula.it_n(jsonb_array_length(coalesce(s #> '{database,versions}', '[]')), 'modifica', 'modifiche'));
  end if;
  if s #>> '{site,status}' in ('ok', 'warn') then
    v_done := v_done || ('app del tablet ' || coalesce(s #>> '{site,sw}', ''));
  end if;
  select k into v_failed from jsonb_each(s) e(k, v) where v->>'status' in ('failed', 'running') limit 1;

  if v_ok then
    for x in select e from jsonb_array_elements_text(case when jsonb_typeof(p->'after_it') = 'array' then p->'after_it' else '[]' end) e loop
      v_todo := v_todo || x;
    end loop;
    if jsonb_array_length(case when jsonb_typeof(p->'prompts') = 'array' then p->'prompts' else '[]' end) > 0 then
      v_todo := v_todo || ('Chiedi a Claude di aggiornare le istruzioni dei bot (cambiate: '
                           || (select string_agg(fabula.bot_title(e), ', ' order by fabula.bot_title(e)) from jsonb_array_elements_text(p->'prompts') e) || ')');
    end if;
    if s #>> '{site,status}' = 'warn' then
      v_todo := v_todo || ('Controlla l''app del tablet: ' || coalesce(s #>> '{site,detail}', 'non risponde ancora con la versione nuova')
                           || '; se non si aggiorna entro un''ora apri il rilascio su GitHub');
    end if;
    v_title := left(format('Rilascio %s fatto', v_ver) || case when cardinality(v_todo) > 0 then ': ' || fabula.it_n(cardinality(v_todo), 'cosa da fare', 'cose da fare') else '' end, 70);
    v_sev := case when cardinality(v_todo) > 0 then 'warn' else 'info' end;
    v_brief := v_brief || ('In produzione: ' || coalesce(array_to_string(v_done, ' · '), 'nessuna modifica (solo documenti o prove)'));
    v_en := format('EN — Release %s is live (%s)%s.', v_ver,
                   coalesce(nullif(concat_ws(', ',
                     case when s #>> '{functions,status}' = 'ok' then 'functions ' || (select string_agg(e, ', ') from jsonb_array_elements_text(coalesce(s #> '{functions,names}', '[]')) e) end,
                     case when s #>> '{database,status}' = 'ok' then jsonb_array_length(coalesce(s #> '{database,versions}', '[]')) || ' database change(s)' end,
                     case when s #>> '{site,status}' in ('ok', 'warn') then 'app ' || coalesce(s #>> '{site,sw}', '') end), ''), 'nothing to deploy'),
                   case when cardinality(v_todo) > 0 then '; ' || cardinality(v_todo) || ' step(s) left by hand' else '' end);
  else
    v_todo := array['Apri il rilascio su GitHub e leggi dove si è fermato' || coalesce(' (' || v_run || ')', ''),
                    'Chiedi a Claude di correggerlo: poi il rilascio si riapprova da GitHub (Actions → Release → «Re-run»)'];
    v_title := left(format('Rilascio %s fermato', v_ver) || coalesce(' al passo ' || case v_failed when 'functions' then '«funzioni del server»'
                                                                                         when 'database' then '«database»' when 'site' then '«app del tablet»'
                                                                                         else v_failed end, ''), 70);
    v_sev := 'alert';
    v_brief := v_brief || ('Errore: ' || coalesce(v_err, (select v->>'error' from jsonb_each(s) e(k, v) where v->>'error' is not null limit 1), 'vedi il rilascio su GitHub'));
    v_brief := v_brief || case when cardinality(v_done) > 0 then 'Già in produzione: ' || array_to_string(v_done, ' · ')
                               else 'Nessuna modifica è arrivata in produzione' end;
    v_en := format('EN — Release %s stopped%s: nothing else changed; open the GitHub run, fix, and re-run it.', v_ver,
                   coalesce(' at the ' || v_failed || ' step', ''));
  end if;
  if nullif(btrim(p->>'title_it'), '') is not null then v_brief := v_brief || btrim(p->>'title_it'); end if;

  v_body := '';
  if cardinality(v_todo) > 0 then
    v_body := '**Da fare**' || E'\n';
    foreach x in array v_todo[1:5] loop i := i + 1; v_body := v_body || i || '. ' || x || E'\n'; end loop;
    v_body := v_body || E'\n';
  end if;
  v_body := v_body || '**In breve**' || E'\n' || (select string_agg('- ' || b, E'\n') from unnest(v_brief) b) || E'\n\n' || v_en;

  v_msg := fabula.post_bot_message('rilascio', v_sev, v_title, v_body);
  update fabula.releases set message_id = v_msg where id = v_id;
  return v_id;
end $$;
revoke all on function fabula.release_record(jsonb) from public, anon, authenticated;
grant execute on function fabula.release_record(jsonb) to service_role;

-- ============================== patches: where the messages go, the Sistema checks ==============================
do $mig$
declare d text; n text;
begin
  -- a stopped release is about the system (Telegram «infra»), like the other system messages
  d := pg_get_functiondef('fabula.notify_topic_for(text,text,text)'::regprocedure);
  n := replace(d, $s$'invite_user', 'predis', 'infra', 'tablet', 'configurazione') then 'infra'$s$,
                  $s$'invite_user', 'predis', 'infra', 'tablet', 'configurazione', 'rilascio') then 'infra'$s$);
  if n = d then raise exception 'v108a: notify_topic_for pattern not found'; end if;
  execute n;

  -- the message opens Configurazione → Panoramica, where the Sistema card shows the release
  d := pg_get_functiondef('fabula.bot_default_link(text)'::regprocedure);
  n := replace(d, $s$    when p_agent = 'prova' then 'admin.html#panoramica'
$s$, $s$    when p_agent = 'prova' then 'admin.html#panoramica'
    when p_agent = 'rilascio' then 'admin.html#panoramica'
$s$);
  if n = d then raise exception 'v108a: bot_default_link pattern not found'; end if;
  execute n;

  -- infra_checks: the drift texts follow the release pipeline, and a «release» check
  d := pg_get_functiondef('fabula.infra_checks()'::regprocedure);
  n := replace(d, $s$|| array_to_string(v_missing[1:3], ', ') || '. Fai «git push» dal Mac'$s$,
                  $s$|| array_to_string(v_missing[1:3], ', ') || '. Applicate fuori dal rilascio automatico: il file va salvato su GitHub main'$s$);
  if n = d then raise exception 'v108a: infra_checks code_pushed pattern not found'; end if;
  d := n;
  n := replace(d, $s$' sul database ma non su GitHub: fai «git push» dal Mac' end$s$,
                  $s$' sul database ma non su GitHub: il file va salvato su GitHub main' end$s$);
  if n = d then raise exception 'v108a: infra_checks repo_sync missing pattern not found'; end if;
  d := n;
  n := replace(d, $s$'): applica lo script SQL Editor della versione (tools/go-live/live-apply); un push non serve' end) end),$s$,
                  $s$'): il rilascio aspetta l''approvazione su GitHub (Actions → Release → «Review deployments»)' end) end),$s$);
  if n = d then raise exception 'v108a: infra_checks repo_sync extra pattern not found'; end if;
  d := n;
  n := replace(d, $s$': Netlify non ha ancora pubblicato (guarda il deploy su Netlify)' end)$s$,
                  $s$': il rilascio non ha ancora pubblicato l''app (approvalo su GitHub: Actions → Release)' end)$s$);
  if n = d then raise exception 'v108a: infra_checks app_deployed pattern not found'; end if;
  d := n;
  n := replace(d, $s$    'vault_secret', fabula.vault_secret_check());
  return v_out;$s$, $s$    'vault_secret', fabula.vault_secret_check());
  -- v1.08: the automatic releases (tools/release/release.py → release_record)
  v_out := v_out || jsonb_build_object('release', (select jsonb_build_object(
      'done', coalesce(x.status = 'ok', false),
      'detail', case when x.id is null then 'Nessun rilascio automatico ancora: il primo è v1.08 (RELEASING.md nel repo)'
                     when x.status = 'ok' then 'Ultimo rilascio ' || x.version || ' il ' || to_char(x.created_at at time zone 'Europe/Rome', 'DD/MM HH24:MI')
                          || coalesce(' · ' || nullif(concat_ws(', ',
                               case when x.steps #>> '{functions,status}' = 'ok' then 'funzioni' end,
                               case when x.steps #>> '{database,status}' = 'ok' then 'database' end,
                               case when x.steps #>> '{site,status}' in ('ok', 'warn') then 'app ' || coalesce(x.steps #>> '{site,sw}', '') end), ''), '')
                     else 'Rilascio ' || x.version || ' fermato il ' || to_char(x.created_at at time zone 'Europe/Rome', 'DD/MM HH24:MI') || ': '
                          || left(coalesce(x.error, 'vedi il rilascio su GitHub'), 160) || ' · da correggere e riapprovare su GitHub' end)
    from (select 1) one left join lateral (select * from fabula.releases order by id desc limit 1) x on true));
  return v_out;$s$);
  if n = d then raise exception 'v108a: infra_checks return pattern not found'; end if;
  execute n;

  -- Panoramica → Sistema and the «Perché?» of the system checks: the new line
  d := pg_get_functiondef('fabula.system_checks()'::regprocedure);
  n := replace(d, $s$(10, 'app_deployed', 'App del tablet pubblicata'), (11, 'advisors_clean', 'Sicurezza del database')) v(o, k, l));$s$,
                  $s$(10, 'app_deployed', 'App del tablet pubblicata'), (11, 'release', 'Rilasci automatici'), (12, 'advisors_clean', 'Sicurezza del database')) v(o, k, l));$s$);
  if n = d then raise exception 'v108a: system_checks pattern not found'; end if;
  execute n;
  d := pg_get_functiondef('fabula._why_infra_rows(jsonb)'::regprocedure);
  n := replace(d, $s$(10, 'advisors_clean', 'Sicurezza del database')) l(o, key, label_it) on l.key = e.k$s$,
                  $s$(10, 'advisors_clean', 'Sicurezza del database'), (11, 'release', 'Rilasci automatici')) l(o, key, label_it) on l.key = e.k$s$);
  if n = d then raise exception 'v108a: _why_infra_rows pattern not found'; end if;
  execute n;
end $mig$;
