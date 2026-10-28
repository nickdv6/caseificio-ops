#!/usr/bin/env python3
"""Release pipeline (v1.08, 15/10/2026). Used by .github/workflows/release.yml; RELEASING.md explains the flow for people.

What a release is: everything on GitHub main since the last release. The commit that is live is the last «ok» row of fabula.releases
(read without secrets through public.fabula_live_release(), with the token through the Management API); before the first automatic
release it is tools/release/baseline.txt. After CI passes on main, the workflow runs:

    release.py live --source public             no secrets: the live commit (the database's word, not a git tag) and the live
                                                migration history (--migrations-out F)
    release.py plan      --sha S --live L       no secrets: what changed since L, the summary for the approval page; with
                     [--live-migrations F]      the live history it lists exactly what apply will run
    release.py rehearse  --sha S --live L       no secrets: a scratch database built like the live one gets the release script
    release.py blocked   --sha S                (plan failed, or nothing could be recorded) tells the Bot feed / Telegram, with the
                                                backup token the outside watcher uses
    release.py github    --source S             v1.18: tells the database what GitHub main (origin/main) holds (commit, its history,
                                                migrations, app version), with the same token; also run by the outside watcher. Only
                                                origin/main is ever sent. Never fails the job
    (Nick approves the «live» environment on GitHub: the only step a person does)
    release.py live --source api                the live commit again (another release may have finished meanwhile)
    release.py check     --sha S --live L       superseded → nothing to do; a rewritten history → STOP
    release.py deploy    --sha S --live L       server functions and database, in release.json's order; stops at the first failure
    (the workflow publishes the site to GitHub Pages)
    release.py site-check --url U               the published sw.js carries the version of fabula-tablet/sw.js
    release.py record    --sha S                writes the result in fabula.releases (Bot feed «Rilasci», Telegram on a failure);
                                                an «ok» row makes S the live commit

The database step is the same as the SQL Editor scripts of v0.93–v1.07: the live migration history is read first; every live version
must exist on GitHub (otherwise STOP: the database has something GitHub does not), the new files go in ONE transaction with a guard
that refuses to run if the history changed meanwhile, and they are recorded in supabase_migrations.schema_migrations. A marker made
at the start of the transaction (a temporary table holding its id) must still be there at the end: a file that ends the transaction
itself makes the release (and its rehearsal) fail. SQL goes through the Supabase Management API (POST /v1/projects/{ref}/database/query,
the SQL Editor's path), functions through the Supabase CLI (a checked download, installed by the workflow before the token is in the
environment). When the answer to the script is lost (a timeout, a gateway 5xx, a cut connection) the script is looked for in
pg_stat_activity by its tag until it is no longer running, then the history decides.

Fallback without the pipeline: `release.py editor-script --live-last <version>` writes the SQL Editor script for the migrations after
that version (paste it in Supabase → SQL Editor as before).
"""
import argparse, http.client, json, os, re, subprocess, sys, tempfile, time, tomllib, urllib.error, urllib.request

REPO = os.environ.get('RELEASE_REPO') or os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
TOOLS = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))   # this checkout's tools/ (replay.sh)
REF = os.environ.get('SUPABASE_PROJECT_REF', 'ojkquhzaeypsphncjqwy')
API = os.environ.get('SUPABASE_API_URL', 'https://api.supabase.com').rstrip('/')
PUBLIC_URL = os.environ.get('SUPABASE_URL', f'https://{REF}.supabase.co').rstrip('/')
CLI = os.environ.get('SUPABASE_CLI', 'npx -y supabase@2.118.0')       # the workflow installs a checked binary; tests use a fake
BASELINE = 'tools/release/baseline.txt'
META = 'tools/release/release.json'
MIG_FILE = re.compile(r'^supabase/migrations/[^/]+\.sql$')
MIG = re.compile(r'^supabase/migrations/(\d{14})_([A-Za-z0-9_.-]+)\.sql$')
FN = re.compile(r'^supabase/functions/([A-Za-z0-9_-]+)/(.+)$')
UA = 'caseificio-ops-release/1.08'
SQL_TIMEOUT = 600          # the release script's own wait for an answer
CLI_TIMEOUT = 600          # one function's deploy
POLL = (15, 900)           # a lost answer: every 15 s, for up to 15 minutes, until the script is no longer running; then the history
MARK = 'release_one_tx'    # the temporary table made after «begin» and checked before the history rows


class Stop(Exception):
    """A reason not to go on, in Italian (it reaches the Bot feed) with the technical detail after « · »."""


class Unclear(Stop):
    """The request may or may not have reached Supabase (timeout, a gateway 5xx, connection cut, an answer that is not JSON)."""


class Unknown(Stop):
    """The outcome could not be established: the database may or may not have the release («da verificare»)."""


# ------------------------------------------------------------------ git
def git(*args):
    r = subprocess.run(['git', '-C', REPO, *args], capture_output=True, text=True)
    if r.returncode != 0:
        raise Stop(f'git {" ".join(args[:2])} non riuscito · {r.stderr.strip()[:300]}')
    return r.stdout


def commit_of(rev):
    out = subprocess.run(['git', '-C', REPO, 'rev-parse', '-q', '--verify', (rev or '') + '^{commit}'], capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 and rev else None


def is_ancestor(a, b):
    return subprocess.run(['git', '-C', REPO, 'merge-base', '--is-ancestor', a, b]).returncode == 0


def base_commit(live=None):
    """The commit that is live: the database's last «ok» release when it has one, else the baseline file."""
    if live:
        c = commit_of(live)
        if not c:
            raise Stop(f'Il commit live {live[:7]} (dal database) non è nella storia di GitHub · storia riscritta?')
        return c, 'database'
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


def migration_files(commit):
    return [p for p in git('ls-tree', '-r', '--name-only', commit, 'supabase/migrations').split('\n') if MIG_FILE.match(p)]


def migrations_at(commit):
    """{version: (name, path)} of the migration files in that commit; two files with the same version are refused."""
    out = {}
    for p in migration_files(commit):
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


def forced(base, sha):
    """«force» of every release.json written between the live commit and this one (a release that never went live is not lost)."""
    out = set()
    for c in git('log', '--format=%H', f'{base}..{sha}', '--', META).split():
        try:
            out |= set(json.loads(file_at(c, META)).get('force') or []) if exists_at(c, META) else set()
        except json.JSONDecodeError:
            pass
    return out


# ------------------------------------------------------------------ plan
def plan(sha, live=None, live_migs=None):
    """live_migs: the live migration history (from public.fabula_live_release()), when known; the plan then lists exactly what
    apply will run. Without it (before v1.08) the base commit's migrations stand for the live history."""
    sha = commit_of(sha)
    if not sha:
        raise Stop('Commit da rilasciare non trovato')
    base, base_from = base_commit(live)
    rel = relation(base, sha)
    p = {'sha': sha, 'base': base, 'base_from': base_from, 'relation': rel, 'migrations': [], 'migrations_edited': [],
         'functions': [], 'functions_removed': [], 'site': False, 'prompts': [], 'warnings': [], 'meta': meta(sha), 'anything': False}
    if rel != 'ahead':
        return p
    ch = changes(base, sha)
    force = forced(base, sha)

    bad_names = [path for path in migration_files(sha) if not MIG.match(path)]
    if bad_names:
        p['warnings'].append('STOP: file di migrazione con un nome che non è <14 cifre>_<nome>.sql (la CI li esegue, il rilascio no): '
                             + ', '.join(bad_names))
    base_migs, migs = migrations_at(base), migrations_at(sha)
    live_set = set(live_migs) if live_migs is not None else set(base_migs)
    p['live_history'] = 'database' if live_migs is not None else 'base commit'
    new = sorted(set(migs) - live_set)
    p['migrations'] = [{'version': v, 'name': migs[v][0]} for v in new]
    p['migrations_edited'] = sorted(v for st, path in ch if st == 'M' and (m := MIG.match(path)) and (v := m.group(1)) in live_set)
    if p['migrations_edited']:
        p['warnings'].append('Migrazioni modificate dopo essere andate in produzione (non vengono rieseguite): ' + ', '.join(p['migrations_edited']))
    gone = sorted(live_set - set(migs))
    if gone:
        p['warnings'].append('STOP: il database ha migrazioni che GitHub main non ha (tolte da GitHub, o applicate fuori dal rilascio): '
                             + ', '.join(gone[:5]))
    if new and live_set and new[0] < max(live_set):
        p['warnings'].append(f'STOP: la migrazione {new[0]} è più vecchia dell\'ultima applicata ({max(live_set)}): rinominala con una versione più recente')

    fns_now, fns_base = functions_at(sha), functions_at(base)
    touched, shared = set(), False
    for _, path in ch:
        if not path.startswith('supabase/functions/'):
            continue
        m = FN.match(path)
        if not m or m.group(1).startswith('_'):
            shared = True                     # _shared/ or a file at the functions' root (deno.json, import_map.json): all of them
        elif not path.endswith('_test.ts'):
            touched.add(m.group(1))
    if shared or 'functions' in force:
        touched |= fns_now
    cfg_now, cfg_base = function_config(sha), function_config(base)
    touched |= {f for f in fns_now if cfg_now.get(f, True) != cfg_base.get(f, True)}
    p['functions'] = sorted(touched & fns_now)
    p['functions_removed'] = sorted(fns_base - fns_now)
    if p['functions_removed']:
        p['warnings'].append('Funzioni tolte da GitHub: su Supabase NON vengono cancellate: ' + ', '.join(p['functions_removed']))

    site_paths = [path for _, path in ch if path.startswith('fabula-tablet/') and os.path.basename(path) not in ('README.md', 'netlify.toml')]
    p['site'] = bool(site_paths) or 'site' in force
    # v1.10 (quality test item 16): app files changed but sw.js kept its version: tablets would keep the old offline copy and report
    # the old version (the office's «Aggiorna ora» and the go-live check go by it)
    if any(os.path.basename(path) != 'sw.js' for path in site_paths) and exists_at(base, 'fabula-tablet/sw.js') and exists_at(sha, 'fabula-tablet/sw.js') \
            and sw_version(file_at(base, 'fabula-tablet/sw.js')) == sw_version(file_at(sha, 'fabula-tablet/sw.js')):
        p['warnings'].append('STOP: l\'app cambia (' + ', '.join(sorted(os.path.basename(x) for x in site_paths)[:4])
                             + ') ma fabula-tablet/sw.js ha ancora la versione ' + str(sw_version(file_at(sha, 'fabula-tablet/sw.js')))
                             + ': aumenta CACHE (perla-vNN)')
    p['prompts'] = sorted({os.path.basename(path)[:-4] for _, path in ch if path.startswith('tools/bots/prompts/') and path.endswith('.txt')})
    for v in p['migrations']:
        p['warnings'] += lint_migration(file_at(sha, migs[v['version']][1]), v['version'])
    p['anything'] = bool(p['migrations'] or p['functions'] or p['site'])
    return p


# ------------------------------------------------------------------ the migration lint
TX_FIRST = {'begin', 'commit', 'rollback', 'end', 'abort', 'savepoint', 'release'}
NOT_IN_TX = [r'start\s+transaction', r'prepare\s+transaction', r'commit\s+prepared', r'rollback\s+prepared', r'vacuum', r'alter\s+system',
             r'(create|drop)\s+database', r'(create|drop)\s+tablespace', r'reindex\s+(\w+\s+)*?(system|database)\b']


def sql_skeleton(sql):
    """The SQL with string literals, quoted names, comments and $tag$ bodies blanked out: only the statements' own words are left."""
    out, i, n = [], 0, len(sql)
    while i < n:
        c = sql[i]
        if c == '-' and sql.startswith('--', i):
            j = sql.find('\n', i)
            i = n if j < 0 else j
        elif c == '/' and sql.startswith('/*', i):
            depth, i = 1, i + 2
            while i < n and depth:
                if sql.startswith('/*', i):
                    depth, i = depth + 1, i + 2
                elif sql.startswith('*/', i):
                    depth, i = depth - 1, i + 2
                else:
                    i += 1
            out.append(' ')
        elif c in ("'", '"'):
            # E'…' strings take backslash escapes (E'\'' is one quote); a quote right after a single «:» is a psql variable
            esc = c == "'" and i > 0 and sql[i - 1] in 'Ee' and not (i > 1 and (sql[i - 2].isalnum() or sql[i - 2] in '_$'))
            if i > 0 and sql[i - 1] == ':' and not (i > 1 and sql[i - 2] == ':'):
                out.append(' \x00psqlvar ')
            j = i + 1
            while j < n:
                if esc and sql[j] == '\\':
                    j += 2
                elif sql[j] == c and sql.startswith(c * 2, j):
                    j += 2
                elif sql[j] == c:
                    break
                else:
                    j += 1
            i = j + 1
            out.append(' x ')
        elif c == '$' and (m := re.match(r'\$([A-Za-z_][A-Za-z0-9_]*)?\$', sql[i:])) and not (i and (sql[i - 1].isalnum() or sql[i - 1] == '_')):
            tag = m.group(0)
            j = sql.find(tag, i + len(tag))
            i = n if j < 0 else j + len(tag)
            out.append(' x ')
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def _psql_var(skel):
    """A psql variable «:name» outside [ ] (inside, «x[lo :hi]» is an array slice); «::» is a cast."""
    depth = 0
    for i, c in enumerate(skel):
        if c == '[':
            depth += 1
        elif c == ']':
            depth = max(0, depth - 1)
        elif c == ':' and depth == 0 and (i == 0 or skel[i - 1] != ':') and i + 1 < len(skel) and (skel[i + 1].isalpha() or skel[i + 1] == '_') \
                and not (i > 0 and (skel[i - 1].isalnum() or skel[i - 1] == '_')):
            return True
    return False


def lint_migration(sql, version):
    """Statements that break «one transaction for the whole release», and psql-only syntax (the rehearsal runs the script with psql,
    the release sends it as one query through the API), stop the release before anyone approves it (the marker in the script is the
    backstop for anything this misses)."""
    out = []
    skel = sql_skeleton(sql)
    atomic = False                       # inside a «begin atomic … end» function body: its «end» is not the end of a transaction
    for stmt in skel.split(';'):
        low = stmt.strip().lower()
        words = low.split()
        if not words:
            continue
        if atomic:
            atomic = words != ['end']
            continue
        if (m := re.search(r'\bbegin\s+atomic\b', low)):
            body = low[m.end():]                    # a body without «;» ends in this piece: one «end» more than its «case»s
            atomic = len(re.findall(r'\bend\b', body)) <= len(re.findall(r'\bcase\b', body))
            continue
        if words[0] in TX_FIRST or any(re.match(r'\s*' + pat + r'\b', low) for pat in NOT_IN_TX):
            out.append(f'STOP {version}: «{" ".join(words[:3])}…» non può stare nell\'unica transazione del rilascio: toglilo '
                       '(il rilascio apre e chiude la transazione da sé)')
            break
    if '\\' in skel:
        out.append(f'STOP {version}: un comando di psql (con la barra rovesciata) non passa dall\'API di Supabase')
    if '\x00psqlvar' in skel or _psql_var(skel):
        out.append(f'STOP {version}: una variabile di psql (:nome) non passa dall\'API di Supabase')
    if re.search(r'\bconcurrently\b', skel, re.I):
        out.append(f'STOP {version}: «concurrently» non può stare in una transazione')
    if re.search(r'alter\s+type\s+\S+\s+add\s+value', skel, re.I):
        out.append(f'NOTA {version}: aggiunge un valore a un enum, che non si può usare nello stesso rilascio')
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
        parts = {'functions': ('Server functions', ', '.join(p['functions']) or '—'),
                 'database': ('Database', ', '.join(f'{x["version"]} {x["name"]}' for x in p['migrations']) or '—')}
        for k in m['order']:
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
def build_script(pending, prev, label, tag='manual'):
    """pending: [(version, name, sql)] in order; prev: the live history's last version (None for an empty history); tag: letters,
    digits and «-» (it marks the script in pg_stat_activity). The same shape as the SQL Editor scripts: one transaction, a guard, the
    files, the history rows. Each file starts from the default search_path (as in CI, where each file has its own session), and the
    marker (a temporary table holding the transaction's id, dropped at commit) must still be there at the end."""
    if not re.fullmatch(r'[A-Za-z0-9-]{1,80}', tag or ''):
        raise Stop(f'Etichetta dello script non valida · {tag!r}')
    versions = ', '.join(f"'{v}'" for v, _, _ in pending)
    guard_prev = (f"  if (select max(version) from supabase_migrations.schema_migrations) is distinct from '{prev}' then\n"
                  f"    raise exception 'STOP: la storia del database non finisce più a {prev}: qualcuno ha applicato altro nel frattempo';\n"
                  f"  end if;\n") if prev else ''
    out = [f'-- release-script {tag} · {label}: {len(pending)} migration(s) after {prev or "an empty history"} (tools/release/release.py)\n',
           '-- One transaction: if any step fails nothing changes. It records the versions and refuses a second run.\n',
           'begin;\n',
           f'create temp table {MARK} on commit drop as select txid_current() as tx;\n',
           'do $release_guard$ begin\n',
           f'  if exists (select 1 from supabase_migrations.schema_migrations where version in ({versions})) then\n',
           "    raise exception 'STOP: queste versioni sono già nella storia del database: niente da fare';\n",
           '  end if;\n', guard_prev, 'end $release_guard$;\n']
    for v, n, sql in pending:
        out.append(f'\n-- ======================= {v}_{n} =======================\nreset search_path;\n' + sql.rstrip() + '\n')
    out.append('\ndo $release_tx$ declare same boolean := false; begin\n'
               f"  if to_regclass('pg_temp.{MARK}') is not null then\n"
               f"    execute 'select exists (select 1 from pg_temp.{MARK} where tx = txid_current())' into same;\n"
               '  end if;\n'
               '  if not same then\n'
               "    raise exception 'STOP: una migrazione ha chiuso la transazione da sola (begin/commit/end): il rilascio non è più in un''unica transazione';\n"
               '  end if;\nend $release_tx$;\n'
               'insert into supabase_migrations.schema_migrations (version, name) values\n'
               + ',\n'.join(f"  ('{v}', '{n}')" for v, n, _ in pending) + ';\ncommit;\n\n'
               'select version, name from supabase_migrations.schema_migrations order by version desc limit 5;\n')
    return ''.join(out)


def pending_against(live, sha):
    """The migrations of `sha` the live history does not have, with the checks that make it safe to apply them."""
    migs = migrations_at(sha)
    extra = sorted(set(live) - set(migs))
    if extra:
        raise Stop('Il database ha versioni che GitHub main non ha: ' + ', '.join(extra[:5])
                   + ' · applicate fuori dal rilascio, oppure file tolti da GitHub: il file va (ri)messo su GitHub main')
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


# ------------------------------------------------------------------ Supabase
def http_json(req, timeout):
    """(status, parsed JSON). HTTP errors → Stop with Supabase's message; anything that leaves the outcome open → Unclear."""
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode()
            return r.status, json.loads(raw or 'null')
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors='replace')[:1500]
        detail, pg_code = raw, None
        try:
            j = json.loads(raw)
            if isinstance(j, dict):
                detail, pg_code = j.get('message', raw), j.get('code')
        except ValueError:
            pass
        late = e.code == 408 or e.code >= 500       # a gateway gave up: the query may still be running, and commit
        hint = {401: 'token non valido o scaduto', 403: 'il token non può accedere al progetto', 429: 'troppe richieste'}.get(
            e.code, 'Supabase non ha risposto in tempo' if late else '')
        err = (Unclear if late else Stop)(f'Supabase HTTP {e.code}{": " + hint if hint else ""} · {detail}')
        err.code, err.pg_code = e.code, pg_code
        raise err
    except urllib.error.URLError as e:
        if isinstance(e.reason, (TimeoutError, ConnectionError)):
            raise Unclear(f'Supabase: la risposta non è arrivata · {e.reason}')
        raise Stop(f'Supabase non raggiungibile · {e.reason}')
    except (OSError, http.client.HTTPException, ValueError) as e:
        raise Unclear(f'Supabase: risposta interrotta o non leggibile · {type(e).__name__}: {e}')


class Supabase:
    def __init__(self, token=None):
        self.token = token or os.environ.get('SUPABASE_ACCESS_TOKEN', '')
        if not self.token:
            raise Stop('Manca il segreto SUPABASE_ACCESS_TOKEN nell\'ambiente «live» di GitHub')

    def call(self, method, path, body=None, timeout=180):
        req = urllib.request.Request(API + path, method=method, data=None if body is None else json.dumps(body).encode(),
                                     headers={'Authorization': 'Bearer ' + self.token, 'Content-Type': 'application/json',
                                              'Accept': 'application/json', 'User-Agent': UA})
        return http_json(req, timeout)[1]

    def sql(self, query, timeout=180):
        rows = self.call('POST', f'/v1/projects/{REF}/database/query', {'query': query}, timeout)
        return rows if isinstance(rows, list) else []

    def live_versions(self):
        return [r['version'] for r in self.sql('select version from supabase_migrations.schema_migrations order by version')]

    def live_release(self):
        """The last «ok» release's commit, or None (no table yet before v1.08, or no release yet)."""
        if not (self.sql("select to_regclass('fabula.releases') is not null as ok") or [{}])[0].get('ok'):
            return None
        rows = self.sql("select sha from fabula.releases where status = 'ok' order by id desc limit 1")
        return rows[0]['sha'] if rows else None

    def function(self, slug):
        return self.call('GET', f'/v1/projects/{REF}/functions/{slug}')


def public_key():
    if os.environ.get('SUPABASE_PUBLISHABLE_KEY'):
        return os.environ['SUPABASE_PUBLISHABLE_KEY']
    m = re.search(r'supabaseKey:\s*"([^"]+)"', open(os.path.join(TOOLS, '..', 'fabula-tablet', 'config.js'), encoding='utf-8').read())
    if not m:
        raise Stop('Chiave pubblica di Supabase non trovata in fabula-tablet/config.js')
    return m.group(1)


def public_rpc(name, body):
    """A public database function through PostgREST with the publishable key (the same key the app ships)."""
    req = urllib.request.Request(f'{PUBLIC_URL}/rest/v1/rpc/{name}', method='POST', data=json.dumps(body).encode(),
                                 headers={'apikey': public_key(), 'Content-Type': 'application/json', 'Accept': 'application/json', 'User-Agent': UA})
    return http_json(req, 30)[1]


def live_from_public():
    try:
        r = public_rpc('fabula_live_release', {})
    except Stop as e:
        if getattr(e, 'code', None) == 404 and getattr(e, 'pg_code', None) == 'PGRST202':   # before v1.08: no such function yet
            return None
        raise
    return r if isinstance(r, dict) else None


# ------------------------------------------------------------------ the steps
def script_tag(sha):
    run = re.sub(r'[^0-9]', '', os.environ.get('GITHUB_RUN_ID', ''))[:20] or 'local'
    return f'{sha[:12]}-{run}-{os.urandom(4).hex()}'


def settle(sb, tag, err):
    """After a lost answer: wait while the script (found by its tag) is still running, then return the live history. «Running» is
    state «active» only: a script that failed inside its own «begin» can leave its session «idle in transaction (aborted)», and that
    can never commit. The first look waits one interval (a quick 502 may come before the script reaches Postgres) and «not running»
    must be seen twice in a row. If that cannot be established within POLL[1] seconds → Unknown («da verificare»)."""
    t_end = time.time() + POLL[1]
    quiet = 0
    while True:
        time.sleep(POLL[0])
        try:
            rows = sb.sql("select count(*)::int as n from pg_stat_activity where pid <> pg_backend_pid() and state = 'active' "
                          f"and query like '%-- release-script {tag} %'")
            if int((rows or [{}])[0].get('n') or 0) == 0:
                quiet += 1
                if quiet >= 2:
                    return set(sb.live_versions())
            else:
                quiet = 0
                print('database: the script is still running on Supabase, waiting', flush=True)
        except Stop:
            quiet = 0
        if time.time() >= t_end:
            raise Unknown(f'Database: esito da verificare, lo script era ancora in corso (o Supabase non rispondeva) dopo '
                          f'{int(POLL[1] // 60) or 1} minuti · {err}')


def step_database(sb, sha, label):
    live = sb.live_versions()
    pending, prev = pending_against(live, sha)
    if not pending:
        return {'status': 'skipped', 'versions': [], 'detail': 'nessuna migrazione nuova'}
    want = [v for v, _, _ in pending]
    tag = script_tag(sha)
    script = build_script(pending, prev, label, tag)
    print(f'database: applying {len(pending)} migration(s) after {prev}: {", ".join(want)} (script {tag})', flush=True)
    try:
        sb.sql(script, timeout=SQL_TIMEOUT)
    except Unclear as e:
        # the transaction may still be running, or have committed or failed: once it is no longer running, the history decides
        after = settle(sb, tag, e)
        got = [v for v in want if v in after]
        if len(got) == len(want):
            return {'status': 'ok', 'versions': want, 'names': [n for _, n, _ in pending], 'after': prev,
                    'detail': 'confermato dalla storia dopo un errore di rete'}
        if got:
            raise Stop(f'ATTENZIONE: {len(got)} versioni su {len(want)} risultano applicate ({", ".join(got)}) · {e}')
        raise Stop(f'Database non aggiornato (nessuna modifica, confermato dalla storia dopo un errore di rete) · {e}')
    except Stop as e:
        after = set(sb.live_versions())
        half = [v for v in want if v in after]
        if half:                                        # cannot happen with one transaction; said loudly if it ever does
            raise Stop(f'ATTENZIONE: errore ma {len(half)} versioni risultano applicate ({", ".join(half)}) · {e}')
        raise Stop(f'Database non aggiornato (nessuna modifica) · {e}')
    after = set(sb.live_versions())
    missing = [v for v in want if v not in after]
    if missing:
        raise Stop('Lo script è andato ma la storia non ha ' + ', '.join(missing))
    return {'status': 'ok', 'versions': want, 'names': [n for _, n, _ in pending], 'after': prev}


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


def step_functions(sb, sha, names):
    if not names:
        return {'status': 'skipped', 'names': []}
    cfg = function_config(sha)
    done = []
    for name in names:
        jwt = cfg.get(name, True)
        cmd = CLI.split() + ['--workdir', REPO, 'functions', 'deploy', name, '--project-ref', REF, '--use-api'] + ([] if jwt else ['--no-verify-jwt'])
        print('functions: deploy ' + name + ('' if jwt else ' --no-verify-jwt'), flush=True)
        t0 = time.time()
        maybe = []                                     # deployed (or perhaps deployed), but not confirmed: «da verificare»
        try:
            try:
                r = subprocess.run(cmd, capture_output=True, text=True, env={**os.environ, 'SUPABASE_ACCESS_TOKEN': sb.token}, timeout=CLI_TIMEOUT)
            except subprocess.TimeoutExpired:
                maybe = [name]
                raise Stop(f'Funzione {name}: il deploy non ha finito entro {CLI_TIMEOUT // 60 or 1} minuti' + (f' (già pubblicate: {", ".join(done)})' if done else ''))
            print((r.stdout[-3000:] + r.stderr[-3000:]).replace(sb.token, '***'), flush=True)
            if r.returncode != 0:
                raise Stop(f'Funzione {name} non pubblicata' + (f' (già pubblicate: {", ".join(done)})' if done else '')
                           + ' · ' + (r.stderr.strip() or r.stdout.strip())[-600:].replace(sb.token, '***'))
            maybe = [name]                             # the CLI says it is deployed; the check below may still fail
            info = sb.function(name) or {}
            upd = _epoch(info.get('updated_at'))
            if upd is not None and upd < t0 - 120:
                raise Stop(f'Funzione {name}: Supabase non mostra una versione nuova (ultima {info.get("updated_at")})')
            if info.get('verify_jwt') is not None and bool(info['verify_jwt']) != jwt:
                raise Stop(f'Funzione {name}: verify_jwt è {info["verify_jwt"]} su Supabase, {jwt} in config.toml')
        except Stop as e:
            e.partial = {'names': list(done), 'check': maybe}   # live, and perhaps live: the Bot feed must not say «nothing changed»
            raise
        done.append(name)
    return {'status': 'ok', 'names': done}


# ------------------------------------------------------------------ commands
def cmd_live(a):
    migs = None
    if a.source == 'api':
        sha = Supabase().live_release()
    else:
        r = live_from_public()
        sha = (r or {}).get('sha')
        if r and isinstance(r.get('migrations'), list):
            migs = [str(v) for v in r['migrations']]
    print(f'live commit (database): {sha or "none yet: " + BASELINE}'
          + (f' · live history {len(migs)} migrations, last {max(migs) if migs else "-"}' if migs is not None else ''))
    _output('live', sha or '')
    if a.migrations_out and migs is not None:
        json.dump(migs, open(a.migrations_out, 'w'))
    return 0


def _live_migs(path):
    if path and os.path.exists(path):
        v = json.load(open(path))
        if isinstance(v, list):
            return [str(x) for x in v]
    return None


def cmd_plan(a):
    p = plan(a.sha, a.live, _live_migs(a.live_migrations))
    md = summary_md(p)
    print(md)
    if a.out:
        json.dump(p, open(a.out, 'w'), indent=2)
    _summary(md)
    _output('anything', 'true' if p['relation'] == 'ahead' and p['anything'] else 'false')
    _output('database', 'true' if p['migrations'] else 'false')
    _output('version', p['meta'].get('version') or '')
    if p['relation'] == 'diverged' or stops(p):
        _blocked_note(p, 'STOP nel piano: ' + ' | '.join(stops(p)) if stops(p) else 'storia riscritta: il commit non contiene quello live')
        return 2
    return 0


def _blocked_note(p, why):
    if os.environ.get('RUNNER_TEMP'):
        json.dump({'version': p['meta'].get('version'), 'sha': p['sha'], 'error': why}, open(os.path.join(os.environ['RUNNER_TEMP'], 'release-blocked.json'), 'w'))


def cmd_rehearse(a):
    """A scratch database built like the live one (the live history's versions, each from the live commit's file when it has it, else
    from this commit's), then the release script on it, as one transaction (needs local Postgres 16 and root, like run_sql_ci.py)."""
    live_migs = _live_migs(a.live_migrations)
    p = plan(a.sha, a.live, live_migs)
    if p['relation'] != 'ahead' or not p['migrations']:
        print('rehearsal: no database change in this release')
        return 0
    base_files, sha_files = migrations_at(p['base']), migrations_at(p['sha'])
    want = sorted(live_migs) if live_migs is not None else sorted(base_files)
    work = tempfile.mkdtemp(prefix='release-rehearsal-')
    os.chmod(work, 0o755)
    for v in want:
        commit, (n, path) = (p['base'], base_files[v]) if v in base_files else (p['sha'], sha_files[v]) if v in sha_files else (None, (None, None))
        if not commit:
            _blocked_note(p, f'prova generale: la versione live {v} non ha un file su GitHub')
            raise Stop(f'Prova generale: la versione live {v} non ha un file su GitHub')
        with open(os.path.join(work, os.path.basename(path)), 'w', encoding='utf-8') as f:
            f.write(file_at(commit, path))
    db = a.db
    r = subprocess.run(['bash', os.path.join(TOOLS, 'go-live/drill/infra-test/replay.sh'), db],
                       capture_output=True, text=True, env={**os.environ, 'MIGRATIONS_DIR': work})
    print(r.stdout[-2000:] + r.stderr[-2000:])
    if 'failures: 0' not in r.stdout:
        _blocked_note(p, 'prova generale: le migrazioni del commit live non si ricostruiscono')
        print('rehearsal: the live commit does not replay cleanly')
        return 2
    try:
        pending, prev = pending_against(want, p['sha'])
    except Stop as e:
        _blocked_note(p, f'prova generale: {e}')
        raise
    script = build_script(pending, prev, f'rehearsal of {p["meta"].get("version") or p["sha"][:7]}', 'rehearsal')
    script = re.sub(r'create extension if not exists pg_net[^;]*;', '-- pg_net stubbed', script, flags=re.I)
    script = re.sub(r'create extension if not exists pg_cron[^;]*;', '-- pg_cron stubbed', script, flags=re.I)
    path = os.path.join(work, 'release.sql')
    open(path, 'w', encoding='utf-8').write(script)
    os.chmod(path, 0o644)
    r = subprocess.run(['su', 'postgres', '-c', f'psql -X -q -v ON_ERROR_STOP=1 -d {db} -f {path}'], capture_output=True, text=True, cwd='/tmp')
    print(r.stdout[-1500:] + r.stderr[-3000:])
    if r.returncode != 0:
        _summary(f'\n**Rehearsal FAILED**: the release script does not apply on a copy of the live commit.\n\n```\n{r.stderr[-1500:]}\n```\n')
        lines = r.stderr.strip().splitlines() or ['?']
        _blocked_note(p, 'prova generale fallita: ' + next((l for l in reversed(lines) if 'ERROR:' in l), lines[-1]).strip()[:300])
        return 2
    again = subprocess.run(['su', 'postgres', '-c', f'psql -X -q -v ON_ERROR_STOP=1 -d {db} -f {path}'], capture_output=True, text=True, cwd='/tmp')
    if again.returncode == 0 or 'STOP' not in again.stderr:
        _blocked_note(p, 'prova generale: una seconda esecuzione non è stata rifiutata')
        print('rehearsal: a second run was NOT refused')
        return 2
    _summary(f'\nRehearsal: the {len(pending)} migration(s) apply in one transaction on a copy built at the live commit, and a second run is refused.\n')
    print('rehearsal: ok')
    return 0


def cmd_blocked(a):
    """The plan or the rehearsal stopped before anyone was asked: tell the Bot feed (and Telegram) with the backup token the outside
    watcher already uses. Without the token, GitHub's own failure e-mail is the only notice."""
    note = {}
    if os.environ.get('RUNNER_TEMP') and os.path.exists(os.path.join(os.environ['RUNNER_TEMP'], 'release-blocked.json')):
        note = json.load(open(os.path.join(os.environ['RUNNER_TEMP'], 'release-blocked.json')))
    token = os.environ.get('BACKUP_EXPORT_TOKEN', '')
    if not token:
        print('blocked: no BACKUP_EXPORT_TOKEN, nothing sent')
        return 0
    try:
        version = note.get('version') or meta(commit_of(a.sha) or 'HEAD').get('version')
    except Stop:
        version = None
    default = {'plan': 'il piano del rilascio non è riuscito (vedi il run su GitHub)',
               'apply': 'il rilascio non ha raggiunto Supabase (vedi il run su GitHub)',
               'record': 'il risultato non è stato scritto nel database (vedi il run su GitHub)'}[a.stage]
    detail = {'ok': False, 'stage': a.stage, 'version': version, 'sha': commit_of(a.sha) or a.sha, 'run_url': a.run_url,
              'error': note.get('error') or default}
    try:
        public_rpc('fabula_outside_report', {'p_token': token, 'p_kind': 'release', 'p_detail': detail})
        print('blocked: reported to the database')
    except Exception as e:      # noqa: BLE001 — the run is red anyway; GitHub e-mails Nick
        print(f'blocked: could not report · {e}')
    return 0


def github_facts(ref):
    """What a commit holds, for the database's drift checks (v1.18): the commit, its date and title, its last 50 first-parent commits
    (the database ignores a later report of one of them: old news), the migration versions the release pipeline would see
    (migrations_at: the same files the plan and the rehearsal use) and the app version in fabula-tablet/sw.js."""
    sha = commit_of(ref)
    if not sha:
        raise Stop(f'{ref} non è un commit di questo repo')
    updated, title = (git('show', '-s', '--format=%cI%x00%s', sha).rstrip('\n').split('\x00', 1) + [''])[:2]
    ancestors = git('rev-list', '--first-parent', '--max-count=50', sha).split()   # a shallow clone gives what it has
    sw = sw_version(file_at(sha, 'fabula-tablet/sw.js')) if exists_at(sha, 'fabula-tablet/sw.js') else None
    return {'sha': sha, 'updated': updated, 'title': title[:200], 'ancestors': ancestors, 'versions': sorted(migrations_at(sha)), 'sw': sw}


def cmd_github(a):
    """v1.18 (audit S-1 step 2): tell the database what GitHub main holds, so the hourly check no longer has to read GitHub (it can't
    once the repo is private). Run by the release workflow on every push to main and after an apply, and by the outside watcher on every
    run, each from its own checkout; it uses the backup token the watcher and the «blocked» step already use. It never fails the job:
    a report that does not arrive only means the board's GitHub checks age until the next one (after 26 h they say «GitHub non letto»)."""
    try:
        main = commit_of('origin/main')
        sha = commit_of(a.ref)
        if not main:
            raise Stop('origin/main non c\'è in questo checkout')
        if sha != main:     # only main is reported: a feature branch or a stale checkout would show the board the wrong code
            raise Stop(f'{a.ref} ({(sha or "?")[:7]}) non è origin/main ({main[:7]})')
        facts = github_facts(main)
    except Stop as e:
        print(f'::warning::github: nothing sent · {e}')
        return 0
    detail = {'ok': True, 'source': a.source, 'run_url': a.run_url, **facts}
    print('github: ' + json.dumps({**detail, 'ancestors': len(facts['ancestors']),
                                   'versions': f"{len(facts['versions'])} (last {facts['versions'][-1] if facts['versions'] else '-'})"}))
    token = os.environ.get('BACKUP_EXPORT_TOKEN', '')
    if not token:
        print('::warning::github: no BACKUP_EXPORT_TOKEN, nothing sent (the board\'s GitHub checks will age)')
        return 0
    try:
        r = public_rpc('fabula_outside_report', {'p_token': token, 'p_kind': 'github', 'p_detail': detail})
        if isinstance(r, dict) and r.get('ignored'):
            print(f"::warning::github: il database tiene {r.get('kept')}, più recente di {r.get('sha')} (resoconto ignorato). "
                  "Se main è stato riportato indietro apposta: release.py github --source manual")
        else:
            print('github: reported to the database · ' + json.dumps(r))
    except Exception as e:      # noqa: BLE001 — the board's GitHub checks just wait for the next report
        print(f'::warning::github: il database non ha registrato cosa c\'è su GitHub main · {e}')
    return 0


def cmd_check(a):
    base, src = base_commit(a.live)
    sha = commit_of(a.sha)
    rel = relation(base, sha)
    print(f'live {base[:7]} ({src}), this {sha[:7]}: {rel}')
    _output('go', 'true' if rel == 'ahead' else 'false')
    _output('stop', 'true' if rel == 'diverged' else 'false')
    if rel == 'ahead':
        p = plan(sha, a.live)
        _output('functions', 'true' if p['functions'] else 'false')
    if rel == 'diverged':
        json.dump({'steps': {}, 'meta': meta(sha), 'error': 'Storia riscritta: il commit non contiene quello live (' + base[:7] + ')'},
                  open(a.out, 'w'), indent=2)
        print('STOP: the commit does not contain the live one')
        return 2
    return 0


def cmd_deploy(a):
    p = plan(a.sha, a.live)
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
        res['started'] = True                             # from here on, a run cut short leaves this file unfinished: «da verificare»
        for step in p['meta']['order']:
            res['steps'][step] = {'status': 'running'}
            _save(res, a.out)
            res['steps'][step] = step_database(sb, p['sha'], label) if step == 'database' else step_functions(sb, p['sha'], p['functions'])
            _save(res, a.out)
    except Exception as e:          # a Stop, or anything unexpected: written down so the record step can say where it stopped
        if not isinstance(e, Stop):
            e = Stop(f'Errore imprevisto · {type(e).__name__}: {e}')
        failed = next((k for k, v in res['steps'].items() if v.get('status') == 'running'), None)
        if failed:
            res['steps'][failed] = {'status': 'unknown' if isinstance(e, Unknown) else 'failed', 'error': str(e),
                                    **(getattr(e, 'partial', None) or {})}
        res['error'] = str(e)
        print('STOP: ' + str(e), file=sys.stderr)
        rc = 2
    res['finished'] = True
    _save(res, a.out)
    _summary(result_md(res))
    _output('site', 'true' if rc == 0 and p['site'] else 'false')
    return rc


def _save(res, path):
    tmp = path + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(res, f, indent=2)
    os.replace(tmp, path)


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
    for _ in range(a.tries):
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
    try:
        have = bool(a.result) and os.path.exists(a.result)
        res = json.load(open(a.result)) if have else {'steps': {}}
        # deploy started but never finished (cancelled, killed, timed out): a step it was in is unknown, the rest is as written
        unfinished = bool(res.get('started')) and not res.get('finished')
        if unfinished:
            for k, v in res['steps'].items():
                if v.get('status') == 'running':
                    res['steps'][k] = {'status': 'unknown', 'error': 'il run si è interrotto durante questo passo'}
        if a.site:
            site = json.load(open(a.site)) if os.path.exists(a.site) else None
            if a.site_outcome == 'failure':
                res['steps']['site'] = {'status': 'failed', 'error': 'Pubblicazione su GitHub Pages non riuscita (vedi il run)'}
            elif a.site_outcome == 'cancelled':
                res['steps']['site'] = {'status': 'unknown', 'error': 'Pubblicazione su GitHub Pages interrotta (vedi il run)'}
            elif site:
                res['steps']['site'] = site
            elif a.site_outcome in ('skipped', ''):
                res['steps']['site'] = {'status': 'skipped'}
        if a.job_status != 'success' and not res.get('error') and not any(v.get('status') in ('failed', 'unknown') for v in res['steps'].values()):
            res['error'] = f'Il run di GitHub è finito come «{a.job_status}» (vedi il run)'
        failed = bool(res.get('error')) or any(v.get('status') in ('failed', 'unknown') for v in res['steps'].values())
        m = res.get('meta') or meta(commit_of(a.sha) or a.sha)
        payload = {'version': m.get('version'), 'title_it': m.get('title_it'), 'sha': commit_of(a.sha) or a.sha, 'base_sha': (res.get('plan') or {}).get('base'),
                   'status': 'failed' if failed else 'ok', 'steps': res['steps'], 'error': res.get('error'),
                   'after_it': m.get('after_it') or [], 'prompts': (res.get('plan') or {}).get('prompts') or [], 'run_url': a.run_url,
                   'warnings': (res.get('plan') or {}).get('warnings') or [],
                   'uncertain': unfinished and not any(v.get('status') == 'unknown' for k, v in res['steps'].items() if k != 'site')}
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        sb = Supabase()
        found = sb.sql("select to_regprocedure('fabula.release_record(jsonb)') is not null as ok")
        if not (found and found[0].get('ok')):
            print('record: fabula.release_record() is not on the database; nothing written')
            return 0 if failed else 2          # an «ok» release must be recorded: it is what makes the commit live
        lit = json.dumps(payload, ensure_ascii=False).replace("'", "''")
        sb.sql(f"select fabula.release_record('{lit}'::jsonb) as id")
        print('record: written')
        return 0
    except Exception as e:      # noqa: BLE001
        print(f'record: could not write the result · {type(e).__name__}: {e}')
        if os.environ.get('RUNNER_TEMP'):
            json.dump({'error': f'risultato non registrato · {e}'[:400]}, open(os.path.join(os.environ['RUNNER_TEMP'], 'release-blocked.json'), 'w'))
        return 2


def cmd_editor_script(a):
    """Fallback without the pipeline: the SQL Editor script for the migrations after --live-last (read it from the live database)."""
    sha = commit_of(a.sha)
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
    s = sub.add_parser('live'); s.add_argument('--source', choices=['public', 'api'], default='public'); s.add_argument('--migrations-out')
    s = sub.add_parser('plan'); s.add_argument('--sha', default='HEAD'); s.add_argument('--live', default=''); s.add_argument('--out')
    s.add_argument('--live-migrations')
    s = sub.add_parser('rehearse'); s.add_argument('--sha', default='HEAD'); s.add_argument('--live', default=''); s.add_argument('--db', default='release_rehearsal')
    s.add_argument('--live-migrations')
    s = sub.add_parser('blocked'); s.add_argument('--sha', default='HEAD'); s.add_argument('--run-url', default='')
    s.add_argument('--stage', choices=['plan', 'apply', 'record'], default='plan')
    s = sub.add_parser('github'); s.add_argument('--ref', default='origin/main'); s.add_argument('--source', choices=['release', 'watcher', 'manual'], required=True)
    s.add_argument('--run-url', default='')
    s = sub.add_parser('check'); s.add_argument('--sha', default='HEAD'); s.add_argument('--live', default='')
    s.add_argument('--out', default='release-result.json')
    s = sub.add_parser('deploy'); s.add_argument('--sha', default='HEAD'); s.add_argument('--live', default=''); s.add_argument('--out', default='release-result.json')
    s = sub.add_parser('site-check'); s.add_argument('--url', required=True); s.add_argument('--out', default='release-site.json')
    s.add_argument('--tries', type=int, default=18); s.add_argument('--wait', type=float, default=10)
    s = sub.add_parser('record'); s.add_argument('--sha', default='HEAD'); s.add_argument('--result', default='release-result.json')
    s.add_argument('--site', default='release-site.json'); s.add_argument('--site-outcome', default='')
    s.add_argument('--job-status', default='success'); s.add_argument('--run-url', default='')
    s = sub.add_parser('editor-script'); s.add_argument('--sha', default='HEAD'); s.add_argument('--live-last', required=True)
    s.add_argument('--out', default='release-sql-editor.sql')
    a = ap.parse_args(argv)
    try:
        return {'live': cmd_live, 'plan': cmd_plan, 'rehearse': cmd_rehearse, 'blocked': cmd_blocked, 'github': cmd_github, 'check': cmd_check,
                'deploy': cmd_deploy, 'site-check': cmd_site_check, 'record': cmd_record, 'editor-script': cmd_editor_script}[a.cmd](a)
    except Stop as e:
        print('STOP: ' + str(e), file=sys.stderr)
        _summary(f'\n**STOP**: {e}\n')
        if os.environ.get('RUNNER_TEMP') and not os.path.exists(os.path.join(os.environ['RUNNER_TEMP'], 'release-blocked.json')):
            json.dump({'error': str(e)}, open(os.path.join(os.environ['RUNNER_TEMP'], 'release-blocked.json'), 'w'))
        return 2


if __name__ == '__main__':
    sys.exit(main())
