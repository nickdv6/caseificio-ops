#!/usr/bin/env python3
"""Release pipeline (v1.08, 15/10/2026). Used by .github/workflows/release.yml; RELEASING.md explains the flow for people.

What a release is: everything on GitHub main since the last release. The commit that is live is the git tag `live` (before the
first automatic release: tools/release/baseline.txt). After CI passes on main, the workflow runs:

    release.py plan      --sha S            no secrets: what changed since `live`, the rehearsal script, the summary for the approval page
    release.py rehearse  --sha S            no secrets: builds a scratch database at `live` and applies the release script to it
    (Nick approves the «live» environment on GitHub: the only step a person does)
    release.py check     --sha S            the tag again (another release may have finished meanwhile): stop if superseded
    release.py deploy    --sha S            server functions and database, in release.json's order; stops at the first failure
    (the workflow publishes the site to GitHub Pages)
    release.py site-check --url U           the published sw.js carries the version of fabula-tablet/sw.js
    release.py record    --sha S            writes the result in fabula.releases (Bot feed «Rilasci», Telegram on a failure)
    (the workflow moves the tag `live` to S, only when everything succeeded)

The database step is the same as the SQL Editor scripts of v0.93–v1.07: the live migration history is read first; every live version
must exist on GitHub (otherwise STOP: the database has something GitHub does not), the new files go in ONE transaction with a guard
that refuses to run if the history changed meanwhile, and they are recorded in supabase_migrations.schema_migrations.
SQL goes through the Supabase Management API (POST /v1/projects/{ref}/database/query, the same path as the dashboard's SQL Editor),
functions through the Supabase CLI; both use the SUPABASE_ACCESS_TOKEN secret of the «live» environment and nothing else.

Fallback without the pipeline: `release.py editor-script --live-last <version>` writes the SQL Editor script for the migrations after
that version (paste it in Supabase → SQL Editor as before).
"""
import argparse, json, os, re, subprocess, sys, tempfile, time, tomllib, urllib.error, urllib.request

REPO = os.environ.get('RELEASE_REPO') or os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
TOOLS = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))   # this checkout's tools/ (replay.sh)
REF = os.environ.get('SUPABASE_PROJECT_REF', 'ojkquhzaeypsphncjqwy')
API = os.environ.get('SUPABASE_API_URL', 'https://api.supabase.com').rstrip('/')
CLI = os.environ.get('SUPABASE_CLI', 'npx -y supabase@2.118.0')       # pinned; tests point this at a fake
BASELINE = 'tools/release/baseline.txt'
META = 'tools/release/release.json'
MIG = re.compile(r'^supabase/migrations/(\d{14})_([A-Za-z0-9_.-]+)\.sql$')
FN = re.compile(r'^supabase/functions/([A-Za-z0-9_-]+)/(.+)$')
UA = 'caseificio-ops-release/1.08'


class Stop(Exception):
    """A reason not to go on, in Italian (it reaches the Bot feed) with the technical detail after « · »."""


# ------------------------------------------------------------------ git
def git(*args, check=True):
    r = subprocess.run(['git', '-C', REPO, *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        raise Stop(f'git {" ".join(args[:2])} non riuscito · {r.stderr.strip()[:300]}')
    return r.stdout


def commit_of(rev):
    out = subprocess.run(['git', '-C', REPO, 'rev-parse', '-q', '--verify', rev + '^{commit}'], capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else None


def is_ancestor(a, b):
    return subprocess.run(['git', '-C', REPO, 'merge-base', '--is-ancestor', a, b]).returncode == 0


def base_commit():
    """The commit that is live: tag `live`, else the baseline file of the commit being released."""
    live = commit_of('refs/tags/live')
    if live:
        return live, 'tag live'
    sha = open(os.path.join(REPO, BASELINE), encoding='utf-8').read().split()[0]
    c = commit_of(sha)
    if not c:
        raise Stop(f'Commit di partenza {sha[:7]} non trovato nel repo · {BASELINE}')
    return c, BASELINE


def relation(base, sha):
    if base == sha:
        return 'same'
    if is_ancestor(base, sha):
        return 'ahead'
    if is_ancestor(sha, base):
        return 'behind'
    return 'diverged'


def file_at(commit, path):
    return git('show', f'{commit}:{path}')


def exists_at(commit, path):
    return subprocess.run(['git', '-C', REPO, 'cat-file', '-e', f'{commit}:{path}'], capture_output=True).returncode == 0


def migrations_at(commit):
    """{version: (name, path)} of the migration files in that commit; two files with the same version are refused."""
    out = {}
    for p in git('ls-tree', '-r', '--name-only', commit, 'supabase/migrations').split('\n'):
        m = MIG.match(p)
        if not m:
            continue
        if m.group(1) in out:
            raise Stop(f'Due migrazioni con la stessa versione {m.group(1)} · {out[m.group(1)][1]}, {p}')
        out[m.group(1)] = (m.group(2), p)
    return out


def changes(base, sha):
    """[(status, path)] between the two commits, renames as delete + add."""
    out = []
    for line in git('diff', '--no-renames', '--name-status', base, sha).split('\n'):
        if line.strip():
            st, path = line.split('\t', 1)
            out.append((st[0], path))
    return out


def function_config(commit):
    """{function: verify_jwt} from supabase/config.toml at that commit (a function not listed verifies the JWT, the CLI default)."""
    if not exists_at(commit, 'supabase/config.toml'):
        return {}
    cfg = tomllib.loads(file_at(commit, 'supabase/config.toml'))
    return {k: bool(v.get('verify_jwt', True)) for k, v in (cfg.get('functions') or {}).items() if isinstance(v, dict)}


def functions_at(commit):
    names = set()
    for p in git('ls-tree', '-r', '--name-only', commit, 'supabase/functions').split('\n'):
        m = FN.match(p)
        if m and not m.group(1).startswith('_') and m.group(2) == 'index.ts':
            names.add(m.group(1))
    return names


def meta(commit):
    m = {'version': None, 'title_it': None, 'order': ['functions', 'database'], 'force': [], 'after_it': []}
    if exists_at(commit, META):
        try:
            m.update(json.loads(file_at(commit, META)))
        except json.JSONDecodeError as e:
            raise Stop(f'{META} non è JSON valido · {e}')
    if sorted(m['order']) != ['database', 'functions']:
        raise Stop(f'{META}: «order» deve contenere esattamente "functions" e "database" · {m["order"]}')
    return m


# ------------------------------------------------------------------ plan
def plan(sha):
    sha = commit_of(sha) or sha
    if not commit_of(sha):
        raise Stop(f'Commit {sha} non trovato')
    base, base_from = base_commit()
    rel = relation(base, sha)
    p = {'sha': sha, 'base': base, 'base_from': base_from, 'relation': rel, 'migrations': [], 'migrations_edited': [],
         'functions': [], 'functions_removed': [], 'site': False, 'prompts': [], 'warnings': [], 'meta': meta(sha), 'anything': False}
    if rel != 'ahead':
        return p
    ch = changes(base, sha)
    paths = {path for _, path in ch}
    meta_changed = META in paths
    force = set(p['meta'].get('force') or []) if meta_changed else set()   # a «force» acts only in the release that writes it

    base_migs, migs = migrations_at(base), migrations_at(sha)
    p['migrations'] = [{'version': v, 'name': migs[v][0]} for v in sorted(set(migs) - set(base_migs))]
    p['migrations_edited'] = sorted(v for st, path in ch if st == 'M' and (m := MIG.match(path)) and (v := m.group(1)) in base_migs)
    if p['migrations_edited']:
        p['warnings'].append('Migration files changed after they went live (not run again): ' + ', '.join(p['migrations_edited']))
    gone = sorted(set(base_migs) - set(migs))
    if gone:
        p['warnings'].append('Migration files removed from GitHub but live on the database: ' + ', '.join(gone)
                             + ' (the database step will stop)')

    fns_now, fns_base = functions_at(sha), functions_at(base)
    touched = set()
    shared = False
    for st, path in ch:
        m = FN.match(path)
        if not m:
            continue
        if m.group(1).startswith('_'):
            shared = True                     # supabase/functions/_shared: every function may import it
        elif not path.endswith('_test.ts'):
            touched.add(m.group(1))
    if shared:
        touched |= fns_now
    cfg_now, cfg_base = function_config(sha), function_config(base)
    touched |= {f for f in fns_now if cfg_now.get(f, True) != cfg_base.get(f, True)}
    if 'functions' in force:
        touched |= fns_now
    p['functions'] = sorted(touched & fns_now)
    p['functions_removed'] = sorted(fns_base - fns_now)
    if p['functions_removed']:
        p['warnings'].append('Functions removed from GitHub are NOT deleted on Supabase: ' + ', '.join(p['functions_removed']))

    site_paths = [path for _, path in ch if path.startswith('fabula-tablet/') and os.path.basename(path) not in ('README.md', 'netlify.toml')]
    p['site'] = bool(site_paths) or 'site' in force
    p['prompts'] = sorted({os.path.basename(path)[:-4] for _, path in ch if path.startswith('tools/bots/prompts/') and path.endswith('.txt')})
    for v in p['migrations']:
        p['warnings'] += lint_migration(file_at(sha, migs[v['version']][1]), v['version'])
    p['anything'] = bool(p['migrations'] or p['functions'] or p['site'])
    return p


def lint_migration(sql, version):
    """Statements that break «one transaction for the whole release» stop the release before anyone approves it."""
    out = []
    body = re.sub(r'--[^\n]*', '', sql)
    body = re.sub(r'\$([A-Za-z_]*)\$.*?\$\1\$', '', body, flags=re.S)   # function bodies may say begin/commit freely
    if re.search(r'(^|;)\s*(begin|commit|rollback|start\s+transaction)\s*;', body, re.I | re.M):
        out.append(f'STOP {version}: the file opens or closes a transaction itself (begin/commit): remove it, the release wraps everything in one')
    if re.search(r'^\s*\\', body, re.M):
        out.append(f'STOP {version}: a psql command (a line starting with a backslash) does not run through the Supabase API')
    if re.search(r'\bconcurrently\b', body, re.I):
        out.append(f'STOP {version}: «concurrently» cannot run inside a transaction')
    if re.search(r'alter\s+type\s+\S+\s+add\s+value', body, re.I):
        out.append(f'NOTE {version}: adds an enum value; it cannot be used later in the same release')
    return out


def stops(p):
    return [w for w in p['warnings'] if w.startswith('STOP')]


def summary_md(p, title='Release plan'):
    m = p['meta']
    lines = [f'### {title}: {m.get("version") or "?"} · {m.get("title_it") or ""}'.rstrip(' ·'), '',
             f'Commit `{p["sha"][:7]}` · live now `{p["base"][:7]}` ({p["base_from"]})', '']
    if p['relation'] == 'same':
        lines.append('Nothing to release: this commit is already live.')
    elif p['relation'] == 'behind':
        lines.append('Nothing to release: a newer commit is already live (this run is superseded).')
    elif p['relation'] == 'diverged':
        lines.append('**STOP:** this commit does not contain the live one (history rewritten?). Ask Claude.')
    else:
        lines.append('| Part | What changes |')
        lines.append('|---|---|')
        order = m['order']
        parts = {'functions': ('Server functions', ', '.join(p['functions']) or '—'),
                 'database': ('Database', ', '.join(f'{x["version"]} {x["name"]}' for x in p['migrations']) or '—')}
        for k in order:
            lines.append(f'| {parts[k][0]} | {parts[k][1]} |')
        lines.append(f'| Site (app.bubalina.it) | {"publish fabula-tablet" if p["site"] else "—"} |')
        if p['prompts']:
            lines.append(f'| Bot prompts (Claude updates the scheduled tasks) | {", ".join(p["prompts"])} |')
        for a in m.get('after_it') or []:
            lines.append(f'| After the release | {a} |')
        if not p['anything']:
            lines += ['', 'Nothing to deploy (only docs, tests or tools changed): no approval needed.']
    if p['warnings']:
        lines += [''] + [f'- {w}' for w in p['warnings']]
    return '\n'.join(lines) + '\n'


# ------------------------------------------------------------------ the database script
def build_script(pending, prev, label):
    """pending: [(version, name, sql)] in order; prev: the live history's last version (None for an empty history).
    The same shape as the SQL Editor scripts: one transaction, a guard, the files, the history rows."""
    versions = ', '.join(f"'{v}'" for v, _, _ in pending)
    guard_prev = (f"  if (select max(version) from supabase_migrations.schema_migrations) is distinct from '{prev}' then\n"
                  f"    raise exception 'STOP: la storia del database non finisce più a {prev}: qualcuno ha applicato altro nel frattempo';\n"
                  f"  end if;\n") if prev else ''
    out = [f'-- {label}: {len(pending)} migration(s) after {prev or "an empty history"} (built by tools/release/release.py)\n',
           '-- One transaction: if any step fails nothing changes. It records the versions and refuses a second run.\n',
           'begin;\n',
           'do $release_guard$ begin\n',
           f'  if exists (select 1 from supabase_migrations.schema_migrations where version in ({versions})) then\n',
           "    raise exception 'STOP: queste versioni sono già nella storia del database: niente da fare';\n",
           '  end if;\n', guard_prev, 'end $release_guard$;\n']
    for v, n, sql in pending:
        out.append(f'\n-- ======================= {v}_{n} =======================\n' + sql.rstrip() + '\n')
    out.append('\ninsert into supabase_migrations.schema_migrations (version, name) values\n'
               + ',\n'.join(f"  ('{v}', '{n}')" for v, n, _ in pending) + ';\ncommit;\n\n'
               'select version, name from supabase_migrations.schema_migrations order by version desc limit 5;\n')
    return ''.join(out)


def pending_against(live, sha):
    """The migrations of `sha` the live history does not have, with the checks that make it safe to apply them."""
    migs = migrations_at(sha)
    extra = sorted(set(live) - set(migs))
    if extra:
        raise Stop('Il database ha versioni che GitHub main non ha: ' + ', '.join(extra[:5])
                   + ' · applicate fuori dal rilascio: il file va prima salvato su GitHub main')
    pending = sorted(set(migs) - set(live))
    if not pending:
        return [], (max(live) if live else None)
    prev = max(live) if live else None
    if prev and pending[0] < prev:
        raise Stop(f'La migrazione {pending[0]} è più vecchia dell\'ultima applicata ({prev}) · rinominala con una versione più recente')
    problems = [w for v in pending for w in lint_migration(file_at(sha, migs[v][1]), v) if w.startswith('STOP')]
    if problems:
        raise Stop('Migrazione non applicabile in una sola transazione · ' + ' | '.join(problems))
    return [(v, migs[v][0], file_at(sha, migs[v][1])) for v in pending], prev


# ------------------------------------------------------------------ Supabase Management API
class Supabase:
    def __init__(self, token=None):
        self.token = token or os.environ.get('SUPABASE_ACCESS_TOKEN', '')
        if not self.token:
            raise Stop('Manca il segreto SUPABASE_ACCESS_TOKEN nell\'ambiente «live» di GitHub')

    def call(self, method, path, body=None, timeout=180):
        req = urllib.request.Request(API + path, method=method,
                                     data=None if body is None else json.dumps(body).encode(),
                                     headers={'Authorization': 'Bearer ' + self.token, 'Content-Type': 'application/json',
                                              'Accept': 'application/json', 'User-Agent': UA})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                raw = r.read().decode() or 'null'
                return json.loads(raw)
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors='replace')[:1500]
            try:
                detail = json.loads(detail).get('message', detail)
            except (ValueError, AttributeError):
                pass
            hint = {401: 'token non valido o scaduto', 403: 'il token non può accedere al progetto'}.get(e.code, '')
            raise Stop(f'Supabase API HTTP {e.code}{": " + hint if hint else ""} · {detail}')
        except urllib.error.URLError as e:
            raise Stop(f'Supabase API non raggiungibile · {e.reason}')

    def sql(self, query):
        rows = self.call('POST', f'/v1/projects/{REF}/database/query', {'query': query})
        return rows if isinstance(rows, list) else []

    def live_versions(self):
        return [r['version'] for r in self.sql('select version from supabase_migrations.schema_migrations order by version')]

    def function(self, slug):
        return self.call('GET', f'/v1/projects/{REF}/functions/{slug}')


# ------------------------------------------------------------------ the steps
def step_database(sb, sha, label):
    live = sb.live_versions()
    pending, prev = pending_against(live, sha)
    if not pending:
        return {'status': 'skipped', 'versions': [], 'detail': 'nessuna migrazione nuova'}
    script = build_script(pending, prev, label)
    print(f'database: applying {len(pending)} migration(s) after {prev}: {", ".join(v for v, _, _ in pending)}', flush=True)
    try:
        sb.sql(script)
    except Stop as e:
        after = set(sb.live_versions())
        half = [v for v, _, _ in pending if v in after]
        if half:                                        # cannot happen with one transaction; said loudly if it ever does
            raise Stop(f'ATTENZIONE: errore ma {len(half)} versioni risultano applicate ({", ".join(half)}) · {e}')
        raise Stop(f'Database non aggiornato (nessuna modifica) · {e}')
    after = set(sb.live_versions())
    missing = [v for v, _, _ in pending if v not in after]
    if missing:
        raise Stop('Lo script è andato ma la storia non ha ' + ', '.join(missing))
    return {'status': 'ok', 'versions': [v for v, _, _ in pending], 'names': [n for _, n, _ in pending], 'after': prev}


def step_functions(sb, sha, names):
    if not names:
        return {'status': 'skipped', 'names': []}
    cfg = function_config(sha)
    done = []
    for name in names:
        jwt = cfg.get(name, True)
        cmd = CLI.split() + ['--workdir', REPO, 'functions', 'deploy', name, '--project-ref', REF, '--use-api'] + ([] if jwt else ['--no-verify-jwt'])
        print('functions: ' + ' '.join(cmd), flush=True)
        t0 = time.time()
        r = subprocess.run(cmd, capture_output=True, text=True, env={**os.environ, 'SUPABASE_ACCESS_TOKEN': sb.token}, timeout=600)
        print(r.stdout[-3000:] + r.stderr[-3000:], flush=True)
        if r.returncode != 0:
            raise Stop(f'Funzione {name} non pubblicata' + (f' (già pubblicate: {", ".join(done)})' if done else '')
                       + ' · ' + (r.stderr.strip() or r.stdout.strip())[-600:])
        info = sb.function(name) or {}
        upd = _epoch(info.get('updated_at'))
        if upd is not None and upd < t0 - 120:
            raise Stop(f'Funzione {name}: Supabase non mostra una versione nuova (ultima {info.get("updated_at")})')
        if (info or {}).get('verify_jwt') is not None and bool(info['verify_jwt']) != jwt:
            raise Stop(f'Funzione {name}: verify_jwt è {info["verify_jwt"]} su Supabase, {jwt} in config.toml')
        done.append(name)
    return {'status': 'ok', 'names': done}


def _epoch(v):
    """updated_at of a function: milliseconds (what the API gives today) or an ISO date; None when unknown."""
    if isinstance(v, (int, float)):
        return v / 1000 if v > 1e11 else float(v)
    if isinstance(v, str):
        try:
            from datetime import datetime
            return datetime.fromisoformat(v.replace('Z', '+00:00')).timestamp()
        except ValueError:
            return None
    return None


def cmd_plan(a):
    p = plan(a.sha)
    md = summary_md(p)
    print(md)
    if a.out:
        json.dump(p, open(a.out, 'w'), indent=2)
    _summary(md)
    _output('anything', 'true' if p['relation'] == 'ahead' and p['anything'] else 'false')
    _output('database', 'true' if p['migrations'] else 'false')
    _output('site', 'true' if p['site'] else 'false')
    _output('version', p['meta'].get('version') or '')
    if p['relation'] == 'diverged' or stops(p):
        return 2
    return 0


def cmd_rehearse(a):
    """A scratch database with the migrations of the live commit, then the release script on it, as one transaction (needs local
    Postgres 16 and root, like tools/ci/run_sql_ci.py)."""
    p = plan(a.sha)
    if p['relation'] != 'ahead' or not p['migrations']:
        print('rehearsal: no database change in this release')
        return 0
    base_migs = migrations_at(p['base'])
    work = tempfile.mkdtemp(prefix='release-rehearsal-')
    os.chmod(work, 0o755)
    for v, (n, path) in base_migs.items():
        with open(os.path.join(work, os.path.basename(path)), 'w', encoding='utf-8') as f:
            f.write(file_at(p['base'], path))
    db = a.db
    r = subprocess.run(['bash', os.path.join(TOOLS, 'go-live/drill/infra-test/replay.sh'), db],
                       capture_output=True, text=True, env={**os.environ, 'MIGRATIONS_DIR': work})
    print(r.stdout[-2000:] + r.stderr[-2000:])
    if 'failures: 0' not in r.stdout:
        print('rehearsal: the live commit does not replay cleanly')
        return 2
    live = sorted(base_migs)
    pending, prev = pending_against(live, p['sha'])
    script = build_script(pending, prev, f'rehearsal of {p["meta"].get("version") or p["sha"][:7]}')
    script = re.sub(r'create extension if not exists pg_net[^;]*;', '-- pg_net stubbed', script, flags=re.I)
    script = re.sub(r'create extension if not exists pg_cron[^;]*;', '-- pg_cron stubbed', script, flags=re.I)
    path = os.path.join(work, 'release.sql')
    open(path, 'w', encoding='utf-8').write(script)
    os.chmod(path, 0o644)
    r = subprocess.run(['su', 'postgres', '-c', f'psql -X -q -v ON_ERROR_STOP=1 -d {db} -f {path}'], capture_output=True, text=True, cwd='/tmp')
    print(r.stdout[-1500:] + r.stderr[-3000:])
    if r.returncode != 0:
        _summary(f'\n**Rehearsal FAILED**: the release script does not apply on a copy of the live commit.\n\n```\n{r.stderr[-1500:]}\n```\n')
        return 2
    again = subprocess.run(['su', 'postgres', '-c', f'psql -X -q -v ON_ERROR_STOP=1 -d {db} -f {path}'], capture_output=True, text=True, cwd='/tmp')
    if again.returncode == 0 or 'STOP' not in again.stderr:
        print('rehearsal: a second run was NOT refused')
        return 2
    _summary(f'\nRehearsal: the {len(pending)} migration(s) apply in one transaction on a copy built at the live commit, and a second run is refused.\n')
    print('rehearsal: ok')
    return 0


def cmd_check(a):
    base, _ = base_commit()
    rel = relation(base, commit_of(a.sha) or a.sha)
    print(f'live {base[:7]}, this {a.sha[:7]}: {rel}')
    _output('go', 'true' if rel == 'ahead' else 'false')
    if rel == 'diverged':
        print('STOP: the commit does not contain the live one')
        return 2
    return 0


def cmd_deploy(a):
    p = plan(a.sha)
    res = {'steps': {}, 'plan': {k: p[k] for k in ('sha', 'base', 'migrations', 'functions', 'site', 'prompts', 'warnings')}, 'meta': p['meta']}
    rc = 0
    try:
        if p['relation'] != 'ahead':
            raise Stop(f'Niente da rilasciare: il commit è {p["relation"]} rispetto a quello live')
        if stops(p):
            raise Stop('Rilascio fermato prima di cambiare qualcosa · ' + ' | '.join(stops(p)))
        sb = Supabase()
        label = p['meta'].get('version') or p['sha'][:7]
        pending_against(sb.live_versions(), p['sha'])     # before anything changes: the token works and the live history fits GitHub
        for step in p['meta']['order']:
            res['steps'][step] = {'status': 'running'}
            res['steps'][step] = step_database(sb, p['sha'], label) if step == 'database' else step_functions(sb, p['sha'], p['functions'])
    except Exception as e:          # a Stop, or anything unexpected: written down so the record step can say where it stopped
        if not isinstance(e, Stop):
            e = Stop(f'Errore imprevisto · {type(e).__name__}: {e}')
        failed = next((k for k, v in res['steps'].items() if v.get('status') == 'running'), None)
        if failed:
            res['steps'][failed] = {'status': 'failed', 'error': str(e)}
        res['error'] = str(e)
        print('STOP: ' + str(e), file=sys.stderr)
        rc = 2
    json.dump(res, open(a.out, 'w'), indent=2)
    _summary(result_md(res))
    _output('site', 'true' if rc == 0 and p['site'] else 'false')
    return rc


def result_md(res):
    lines = ['', '### Result', '']
    names = {'functions': 'Server functions', 'database': 'Database', 'site': 'Site'}
    for k, v in res['steps'].items():
        what = ', '.join(v.get('names') or v.get('versions') or []) or v.get('detail') or v.get('sw') or ''
        lines.append(f'- {names.get(k, k)}: **{v.get("status")}** {what} {("· " + v["error"]) if v.get("error") else ""}'.rstrip())
    if res.get('error') and not any(v.get('error') for v in res['steps'].values()):
        lines.append(f'- **STOP**: {res["error"]}')
    return '\n'.join(lines) + '\n'


def sw_version(text):
    m = re.search(r"const CACHE = '([^']+)'", text or '')
    return m.group(1) if m else None


def cmd_site_check(a):
    """The site must serve the sw.js version of the release (GitHub Pages can take a minute; DNS or HTTPS may lag on day one)."""
    want = sw_version(open(os.path.join(REPO, 'fabula-tablet/sw.js'), encoding='utf-8').read())
    got, err = None, None
    for i in range(a.tries):
        try:
            req = urllib.request.Request(a.url.rstrip('/') + f'/sw.js?release={int(time.time())}', headers={'User-Agent': UA, 'Cache-Control': 'no-cache'})
            with urllib.request.urlopen(req, timeout=20) as r:
                got = sw_version(r.read().decode(errors='replace'))
            if got == want:
                break
        except Exception as e:      # noqa: BLE001 — any failure is reported, the release itself already happened
            err = str(e)
        time.sleep(a.wait)
    ok = got == want
    out = {'status': 'ok' if ok else 'warn', 'sw': want, 'url': a.url, 'detail': None if ok else f'il sito risponde con {got or "niente"} ({err or "versione vecchia"})'}
    json.dump(out, open(a.out, 'w'), indent=2)
    print(json.dumps(out))
    return 0


def cmd_record(a):
    res = json.load(open(a.result)) if a.result and os.path.exists(a.result) else {'steps': {}, 'meta': meta(a.sha)}
    if a.site:
        site = json.load(open(a.site)) if os.path.exists(a.site) else None
        if a.site_outcome == 'failure':
            res['steps']['site'] = {'status': 'failed', 'error': 'Pubblicazione su GitHub Pages non riuscita (vedi il run)'}
        elif site:
            res['steps']['site'] = site
        elif a.site_outcome in ('skipped', ''):
            res['steps']['site'] = {'status': 'skipped'}
    if a.job_status != 'success' and not res.get('error') and not any(v.get('status') == 'failed' for v in res['steps'].values()):
        res['error'] = f'Il run di GitHub è finito come «{a.job_status}» (vedi il run)'
    failed = bool(res.get('error')) or any(v.get('status') == 'failed' for v in res['steps'].values())
    m = res.get('meta') or meta(a.sha)
    payload = {'version': m.get('version'), 'title_it': m.get('title_it'), 'sha': a.sha, 'base_sha': (res.get('plan') or {}).get('base'),
               'status': 'failed' if failed else 'ok', 'steps': res['steps'], 'error': res.get('error'),
               'after_it': m.get('after_it') or [], 'prompts': (res.get('plan') or {}).get('prompts') or [], 'run_url': a.run_url,
               'warnings': (res.get('plan') or {}).get('warnings') or []}
    print(json.dumps(payload, indent=2, ensure_ascii=False))
    try:
        sb = Supabase()
        found = sb.sql("select to_regprocedure('fabula.release_record(jsonb)') is not null as ok")
        if not (found and found[0].get('ok')):
            print('record: fabula.release_record() is not on the database yet; nothing written')
            return 0
        lit = json.dumps(payload, ensure_ascii=False).replace("'", "''")
        sb.sql(f"select fabula.release_record('{lit}'::jsonb) as id")
        print('record: written')
    except Stop as e:
        print('record: could not write the result (the run status on GitHub stays the reference) · ' + str(e))
    return 0


def cmd_editor_script(a):
    """Fallback without the pipeline: the SQL Editor script for the migrations after --live-last (read it from the live database)."""
    sha = commit_of(a.sha) or a.sha
    live = [v for v in migrations_at(sha) if v <= a.live_last]
    if a.live_last not in live:
        raise Stop(f'{a.live_last} non è una migrazione del repo')
    pending, prev = pending_against(live, sha)
    if not pending:
        print('nothing after ' + a.live_last)
        return 0
    script = build_script(pending, prev, f'SQL Editor script for {meta(sha).get("version") or sha[:7]}')
    open(a.out, 'w', encoding='utf-8').write(script)
    print(f'{a.out}: {len(pending)} migration(s) after {prev}')
    return 0


def _summary(md):
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a', encoding='utf-8') as f:
            f.write(md)


def _output(k, v):
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as f:
            f.write(f'{k}={v}\n')


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('plan'); s.add_argument('--sha', default='HEAD'); s.add_argument('--out')
    s = sub.add_parser('rehearse'); s.add_argument('--sha', default='HEAD'); s.add_argument('--db', default='release_rehearsal')
    s = sub.add_parser('check'); s.add_argument('--sha', default='HEAD')
    s = sub.add_parser('deploy'); s.add_argument('--sha', default='HEAD'); s.add_argument('--out', default='release-result.json')
    s = sub.add_parser('site-check'); s.add_argument('--url', required=True); s.add_argument('--out', default='release-site.json')
    s.add_argument('--tries', type=int, default=18); s.add_argument('--wait', type=float, default=10)
    s = sub.add_parser('record'); s.add_argument('--sha', default='HEAD'); s.add_argument('--result', default='release-result.json')
    s.add_argument('--site', default='release-site.json'); s.add_argument('--site-outcome', default='')
    s.add_argument('--job-status', default='success'); s.add_argument('--run-url', default='')
    s = sub.add_parser('editor-script'); s.add_argument('--sha', default='HEAD'); s.add_argument('--live-last', required=True)
    s.add_argument('--out', default='release-sql-editor.sql')
    a = ap.parse_args(argv)
    try:
        return {'plan': cmd_plan, 'rehearse': cmd_rehearse, 'check': cmd_check, 'deploy': cmd_deploy, 'site-check': cmd_site_check,
                'record': cmd_record, 'editor-script': cmd_editor_script}[a.cmd](a)
    except Stop as e:
        print('STOP: ' + str(e), file=sys.stderr)
        _summary(f'\n**STOP**: {e}\n')
        return 2


if __name__ == '__main__':
    sys.exit(main())
