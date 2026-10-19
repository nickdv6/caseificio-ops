#!/usr/bin/env python3
"""Tests of tools/release/release.py (v1.08). Run as root with local Postgres 16 (the CI runs it from tools/ci/run_sql_ci.py):

    sudo python3 tools/release/test_release.py <template_db>

template_db is a replay of every migration (CI's ci_template, or `bash tools/go-live/drill/infra-test/replay.sh <db>`). The tests build
small git repositories in a temporary folder, a fake Supabase Management API (it runs the SQL on a copy of the template with psql)
and a fake Supabase CLI, so nothing ever reaches the real project. Prints PASS/FAIL lines and «FAILURES: none»."""
import csv, functools, http.server, importlib.util, io, json, os, shutil, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
REAL = os.path.abspath(os.path.join(HERE, '..', '..'))
TEMPLATE = sys.argv[1] if len(sys.argv) > 1 else 'ci_template'
TOKEN = 'test-token-not-a-secret'
fails = []


def check(name, cond, info=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f'  [{str(info)[:300]}]' if info != '' else ''), flush=True)
    if not cond:
        fails.append(name)


def load():
    spec = importlib.util.spec_from_file_location('release', os.path.join(HERE, 'release.py'))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


R = load()


def run(*cmd, cwd=None, env=None, check_rc=True):
    r = subprocess.run(list(cmd), cwd=cwd, capture_output=True, text=True, env=env)
    if check_rc and r.returncode != 0:
        raise RuntimeError(f'{cmd}: {r.stderr}')
    return r


def as_pg(sql_or_cmd, db=None, file=None):
    if file:
        return run('su', 'postgres', '-c', f'psql -X -q -v ON_ERROR_STOP=1 -d {db} -f {file}', cwd='/tmp', check_rc=False)
    return run('su', 'postgres', '-c', sql_or_cmd, cwd='/tmp', check_rc=False)


def psql_at(db, sql):
    r = run('su', 'postgres', '-c', f"psql -X -At -v ON_ERROR_STOP=1 -d {db} -c \"{sql}\"", cwd='/tmp', check_rc=False)
    return r.stdout.strip()


class Repo:
    """A small git repository; .commit() returns the sha."""
    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix='release-test-')
        run('git', 'init', '-q', '-b', 'main', self.dir)
        run('git', '-C', self.dir, 'config', 'user.email', 'test@example.com')
        run('git', '-C', self.dir, 'config', 'user.name', 'Test')

    def write(self, path, text):
        p = os.path.join(self.dir, path)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, 'w', encoding='utf-8').write(text)

    def rm(self, path):
        os.unlink(os.path.join(self.dir, path))

    def commit(self, msg):
        run('git', '-C', self.dir, 'add', '-A')
        run('git', '-C', self.dir, 'commit', '-q', '--allow-empty', '-m', msg)
        return run('git', '-C', self.dir, 'rev-parse', 'HEAD').stdout.strip()

    def use(self):
        R.REPO = self.dir


# ============================================================== 1. plan on a small repo
def test_plan():
    g = Repo()
    g.write('supabase/migrations/20260101000000_a.sql', 'create schema if not exists fabula;\ncreate table fabula.t1 (id int);\n')
    g.write('supabase/migrations/20260101000100_b.sql', 'create table fabula.t2 (id int);\n')
    g.write('supabase/functions/alpha/index.ts', 'export {}\n')
    g.write('supabase/functions/beta/index.ts', 'export {}\n')
    g.write('supabase/functions/beta/beta_test.ts', 'export {}\n')
    g.write('supabase/functions/_shared/util.ts', 'export const x = 1\n')
    g.write('supabase/config.toml', '[functions.beta]\nverify_jwt = false\n')
    g.write('fabula-tablet/sw.js', "const CACHE = 'perla-v1';\n")
    g.write('fabula-tablet/README.md', 'app\n')
    g.write('tools/bots/prompts/milk_planning.txt', 'prompt\n')
    c0 = g.commit('c0')
    g.write('tools/release/baseline.txt', c0 + '  test baseline\n')
    c0b = g.commit('baseline')
    g.use()

    p = R.plan(c0b)
    check('plan: nothing but the baseline file changed → nothing to deploy', p['relation'] == 'ahead' and not p['anything'], p)
    check('plan: the base comes from baseline.txt before the first release', p['base'] == c0 and p['base_from'] == R.BASELINE, p['base_from'])

    g.write('supabase/migrations/20260102000000_c.sql', 'create table fabula.t3 (id int);\n')
    g.write('supabase/functions/alpha/index.ts', 'export const y = 2\n')
    g.write('fabula-tablet/sw.js', "const CACHE = 'perla-v2';\n")
    g.write('tools/bots/prompts/milk_planning.txt', 'prompt 2\n')
    c1 = g.commit('c1')
    p = R.plan(c1)
    check('plan: a new migration is listed', [m['version'] for m in p['migrations']] == ['20260102000000'], p['migrations'])
    check('plan: only the changed function', p['functions'] == ['alpha'], p['functions'])
    check('plan: the app changed → site', p['site'] is True)
    check('plan: changed prompts are named', p['prompts'] == ['milk_planning'], p['prompts'])
    check('plan: something to deploy', p['anything'] is True)
    md = R.summary_md(p)
    check('plan: the summary names the parts', 'Server functions | alpha' in md and '20260102000000 c' in md and 'publish fabula-tablet' in md, md)

    g.write('supabase/functions/beta/beta_test.ts', 'export const t = 1\n')
    g.write('fabula-tablet/README.md', 'app 2\n')
    c2 = g.commit('tests and readme only')
    p = R.plan(c2, live=c1)
    check('plan: the database\'s live commit is the base once there is one', p['base'] == c1 and p['base_from'] == 'database', p['base_from'])
    check('plan: a test file or the app README deploy nothing', not p['anything'] and p['functions'] == [] and not p['site'], p)

    g.write('supabase/functions/_shared/util.ts', 'export const x = 3\n')
    c3 = g.commit('shared')
    p = R.plan(c3, live=c2)
    check('plan: a change in _shared redeploys every function', p['functions'] == ['alpha', 'beta'], p['functions'])
    g.write('supabase/functions/deno.json', '{}\n')
    c3b = g.commit('root file')
    check('plan: a file at the functions\' root (deno.json) redeploys every function', R.plan(c3b, live=c3)['functions'] == ['alpha', 'beta'])

    g.write('supabase/config.toml', '[functions.beta]\nverify_jwt = true\n')
    c4 = g.commit('jwt')
    p = R.plan(c4, live=c3b)
    check('plan: a verify_jwt change in config.toml redeploys that function', p['functions'] == ['beta'], p['functions'])
    check('function config: a function not listed verifies the JWT', R.function_config(c3).get('alpha', True) is True and R.function_config(c3)['beta'] is False)

    g.write('tools/release/release.json', json.dumps({'version': 'v9', 'force': ['site', 'functions']}))
    c5 = g.commit('force')
    p = R.plan(c5, live=c4)
    check('plan: «force» in the release that writes release.json', p['site'] and p['functions'] == ['alpha', 'beta'] and p['meta']['version'] == 'v9', p)
    g.write('tools/release/release.json', json.dumps({'version': 'v10'}))
    c5b = g.commit('next release before v9 went live')
    p = R.plan(c5b, live=c4)
    check('plan: a «force» of a release that never went live is kept by the next one', p['site'] and p['functions'] == ['alpha', 'beta'], p)
    g.write('docs.md', 'x\n')
    c6 = g.commit('docs')
    p = R.plan(c6, live=c5b)
    check('plan: «force» is not repeated once its release is live', not p['anything'], p)

    check('relation: the live commit itself → same', R.plan(c5, live=c5)['relation'] == 'same')
    check('relation: an older commit → behind (superseded)', R.plan(c4, live=c5)['relation'] == 'behind')
    run('git', '-C', g.dir, 'checkout', '-q', '-b', 'side', c3)
    g.write('side.txt', 'x\n')
    side = g.commit('side')
    run('git', '-C', g.dir, 'checkout', '-q', 'main')
    check('relation: a commit that does not contain the live one → diverged', R.plan(side, live=c5)['relation'] == 'diverged')
    try:
        R.plan(c6, live='0' * 40)
        check('plan: a live commit GitHub does not have → STOP', False)
    except R.Stop as e:
        check('plan: a live commit GitHub does not have → STOP', 'non è nella storia' in str(e), str(e))

    g.write('supabase/migrations/20260103000000_d.sql', 'begin;\ncreate table fabula.t4 (id int);\ncommit;\n')
    c7 = g.commit('begin commit')
    p = R.plan(c7, live=c6)
    check('plan: a migration with its own begin/commit is a STOP before approval', any('STOP 20260103000000' in w for w in p['warnings']), p['warnings'])
    rc = R.main(['plan', '--sha', c7, '--live', c6])
    check('plan: the command exits 2 on a STOP (no approval asked)', rc == 2)
    g.rm('supabase/migrations/20260103000000_d.sql')
    g.write('supabase/migrations/20260103000000_d.sql', 'do $$ begin\n  perform 1;\nend $$;\ncreate function fabula.f() returns int language plpgsql as $f$ begin commit; return 1; end $f$;\n'
            "select case when 1 = 1 then 'a;commit;' else 'b'\nend;\n-- commit;\n/* end; */ select 1;\n")
    c8 = g.commit('begin inside bodies')
    check('lint: begin/commit inside $$ bodies, strings, comments and CASE … END is fine', not R.stops(R.plan(c8, live=c6)), R.plan(c8, live=c6)['warnings'])
    for bad in ('create table a (x int);\nend;', 'select 1; end transaction;', 'abort;', 'commit work;', 'commit and chain;', 'begin transaction;',
                'start transaction isolation level serializable;', '/* x */ commit;', "select '--'; commit;", 'savepoint s1;', 'vacuum t;',
                'alter system set work_mem = 1;', 'create database x;', 'prepare transaction \'t\';'):
        check(f'lint: «{bad[:28]}» is refused', any(w.startswith('STOP') for w in R.lint_migration(bad, 'v')), R.lint_migration(bad, 'v'))
    check('lint: concurrently and psql backslash commands are refused',
          any('concurrently' in w for w in R.lint_migration('create index concurrently i on t(x);', 'v'))
          and any('backslash' in w for w in R.lint_migration('\\set x 1\nselect 1;', 'v')))
    g.write('supabase/migrations/20260101000100_b.sql', 'create table fabula.t2 (id int, x int);\n')
    c9 = g.commit('edit applied migration')
    p = R.plan(c9, live=c8)
    check('plan: editing a migration that is already live is a warning', p['migrations_edited'] == ['20260101000100'], p['migrations_edited'])
    g.rm('supabase/migrations/20260102000000_c.sql')
    c10 = g.commit('remove live migration')
    check('plan: a live migration removed from GitHub is a STOP before approval', any('removed from GitHub' in w for w in R.stops(R.plan(c10, live=c9))))
    g.write('supabase/migrations/20260102000000_c.sql', 'create table fabula.t3 (id int);\n')
    g.write('supabase/migrations/20261016_fix.sql', 'select 1;\n')
    c11 = g.commit('badly named migration')
    check('plan: a migration file without the 14-digit version is a STOP', any('14 digits' in w for w in R.stops(R.plan(c11, live=c9))))
    shutil.rmtree(g.dir, ignore_errors=True)


# ============================================================== 2. the script on a scratch history
def test_script():
    db = 'release_test_script'
    as_pg(f'dropdb --if-exists {db}; createdb {db}')
    psql_at(db, 'create schema supabase_migrations; create table supabase_migrations.schema_migrations (version text primary key, statements text[], name text);'
                " insert into supabase_migrations.schema_migrations(version) values ('20260101000000'), ('20260101000100');")
    g = Repo()
    g.write('supabase/migrations/20260101000000_a.sql', 'create table t1 (id int);\n')
    g.write('supabase/migrations/20260101000100_b.sql', 'create table t2 (id int);\n')
    g.write('supabase/migrations/20260102000000_c.sql', 'create table t3 (id int);\n')
    g.write('supabase/migrations/20260102000100_d.sql', "insert into t3 values (1);\n")
    c = g.commit('c')
    g.use()
    live = psql_at(db, 'select version from supabase_migrations.schema_migrations order by 1').split()
    pending, prev = R.pending_against(live, c)
    check('pending: the two files after the live history', [v for v, _, _ in pending] == ['20260102000000', '20260102000100'] and prev == '20260101000100', pending)
    psql_at(db, 'create table t1 (id int); create table t2 (id int);')
    path = '/tmp/release_test_script.sql'
    open(path, 'w').write(R.build_script(pending, prev, 'test'))
    os.chmod(path, 0o644)
    r = as_pg(None, db, path)
    hist = psql_at(db, 'select string_agg(version, \',\' order by version) from supabase_migrations.schema_migrations')
    check('script: applies and records both versions', r.returncode == 0 and hist.endswith('20260102000000,20260102000100'), r.stderr or hist)
    r = as_pg(None, db, path)
    check('script: a second run is refused (STOP) and changes nothing', r.returncode != 0 and 'STOP' in r.stderr and psql_at(db, 'select count(*) from t3') == '1', r.stderr)

    g.write('supabase/migrations/20260103000000_e.sql', 'create table t5 (id int);\n')
    g.write('supabase/migrations/20260103000100_f.sql', 'select 1/0;\n')
    c2 = g.commit('bad')
    live = psql_at(db, 'select version from supabase_migrations.schema_migrations order by 1').split()
    pending, prev = R.pending_against(live, c2)
    open(path, 'w').write(R.build_script(pending, prev, 'test'))
    r = as_pg(None, db, path)
    check('script: an error in the second file leaves nothing (not even the first file)',
          r.returncode != 0 and psql_at(db, "select to_regclass('t5') is null") == 't'
          and psql_at(db, "select count(*) from supabase_migrations.schema_migrations where version like '20260103%'") == '0', r.stderr[-200:])

    pending_ok = [(v, n, s) for v, n, s in pending if v == '20260103000000']
    open(path, 'w').write(R.build_script(pending_ok, '20260101000000', 'test'))
    r = as_pg(None, db, path)
    check('script: the history changed since it was built → STOP', r.returncode != 0 and 'non finisce più' in r.stderr, r.stderr[-200:])

    # the marker: a file that ends the transaction makes the script fail (and its rehearsal: nobody is asked)
    pending_tx = [('20260104000000', 'endtx', 'create table t6 (id int);\nend;\ncreate table t7 (id int);\n')]
    open(path, 'w').write(R.build_script(pending_tx, max(live), 'test'))
    r = as_pg(None, db, path)
    check('script: a file that ends the transaction itself is caught by the marker (no history row)',
          r.returncode != 0 and 'chiuso la transazione' in r.stderr
          and psql_at(db, "select count(*) from supabase_migrations.schema_migrations where version = '20260104000000'") == '0', r.stderr[-300:])
    psql_at(db, 'drop table if exists t6; drop table if exists t7;')
    # each file starts from the default search_path, as in CI (one session per file)
    psql_at(db, 'create schema if not exists other;')
    pending_sp = [('20260105000000', 'sp1', 'set search_path = other, public;\ncreate table sp_a (id int);\n'),
                  ('20260105000100', 'sp2', 'create table sp_b (id int);\n')]
    open(path, 'w').write(R.build_script(pending_sp, max(live), 'test'))
    r = as_pg(None, db, path)
    check('script: a search_path set by one file does not reach the next one',
          r.returncode == 0 and psql_at(db, "select to_regclass('other.sp_a') is not null and to_regclass('public.sp_b') is not null and to_regclass('other.sp_b') is null") == 't',
          r.stderr[-300:])
    try:
        R.pending_against(live + ['20260109000000'], c2)
        check('pending: a live version GitHub does not have → STOP', False)
    except R.Stop as e:
        check('pending: a live version GitHub does not have → STOP', 'GitHub main non ha' in str(e), str(e))
    g.write('supabase/migrations/20260101000050_old.sql', 'select 1;\n')
    c3 = g.commit('old')
    try:
        R.pending_against(live, c3)
        check('pending: a new file older than the live history → STOP', False)
    except R.Stop as e:
        check('pending: a new file older than the live history → STOP', 'più vecchia' in str(e), str(e))
    out = '/tmp/release_test_editor.sql'
    rc = R.main(['editor-script', '--sha', c2, '--live-last', '20260102000100', '--out', out])
    txt = open(out).read() if os.path.exists(out) else ''
    check('editor-script: the fallback script for the SQL Editor', rc == 0 and "'20260103000000', 'e'" in txt and 'begin;' in txt and 'commit;' in txt, rc)
    as_pg(f'dropdb --if-exists {db}')
    shutil.rmtree(g.dir, ignore_errors=True)


# ============================================================== 3. rehearsal (replay.sh with MIGRATIONS_DIR)
def test_rehearsal():
    g = Repo()
    g.write('supabase/migrations/20260101000000_a.sql', 'create schema if not exists fabula;\ncreate table fabula.t1 (id int primary key);\n')
    c0 = g.commit('c0')
    g.write('tools/release/baseline.txt', c0 + '\n')
    g.write('supabase/migrations/20260102000000_b.sql', 'create table fabula.t2 (id int references fabula.t1(id));\n')
    c1 = g.commit('c1')
    g.use()
    rc = R.main(['rehearse', '--sha', c1, '--db', 'release_test_rehearsal'])
    check('rehearsal: the release applies on a copy built at the live commit', rc == 0)
    g.write('supabase/migrations/20260103000000_c.sql', 'alter table fabula.nope add column x int;\n')
    c2 = g.commit('c2')
    rc = R.main(['rehearse', '--sha', c2, '--db', 'release_test_rehearsal'])
    check('rehearsal: a release that would fail stops before the approval', rc == 2)
    as_pg('dropdb --if-exists release_test_rehearsal')
    shutil.rmtree(g.dir, ignore_errors=True)


# ============================================================== 4. deploy and record against a fake API and CLI
class FakeApi(http.server.BaseHTTPRequestHandler):
    db = None
    calls = []
    fn_jwt = {}
    stale_function = False
    mode = None
    rest_missing = False
    reports = []

    def _rest(self, fn, body):
        if self.headers.get('apikey') != 'test-publishable-key':
            return self._send(401, {'message': 'Invalid API key'})
        if fn == 'fabula_live_release':
            if FakeApi.rest_missing:
                return self._send(404, {'code': 'PGRST202', 'message': 'Could not find the function public.fabula_live_release'})
            return self._send(200, json.loads(psql_at(FakeApi.db, 'select coalesce(public.fabula_live_release(), \'null\'::jsonb)')))
        if fn == 'fabula_outside_report':
            FakeApi.reports.append(body)
            return self._send(200, {'ok': True})
        self._send(404, {'message': 'not found'})

    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _auth(self):
        if self.headers.get('Authorization') != 'Bearer ' + TOKEN:
            self._send(401, {'message': 'Unauthorized'})
            return False
        return True

    def do_GET(self):
        FakeApi.calls.append(('GET', self.path))
        if not self._auth():
            return
        slug = self.path.rsplit('/', 1)[-1]
        ts = (time.time() - 3600 if FakeApi.stale_function else time.time()) * 1000
        self._send(200, {'slug': slug, 'updated_at': int(ts), 'verify_jwt': FakeApi.fn_jwt.get(slug, True)})

    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        body = json.loads(self.rfile.read(n) or b'{}')
        FakeApi.calls.append(('POST', self.path, body.get('query', '')[:120]))
        if self.path.startswith('/rest/v1/rpc/'):                  # PostgREST with the publishable key
            return self._rest(self.path.rsplit('/', 1)[-1], body)
        if not self._auth():
            return
        if not self.path.endswith('/database/query'):
            return self._send(404, {'message': 'not found'})
        script = body['query'].lstrip().startswith('-- ')            # the release script (not a short query)
        if script and FakeApi.mode == 'disconnect':                  # the answer is lost and nothing ran
            FakeApi.mode = None
            self.close_connection = True
            return
        f = tempfile.NamedTemporaryFile('w', suffix='.sql', delete=False, dir='/tmp')
        f.write(body['query'])
        f.close()
        os.chmod(f.name, 0o644)
        r = run('su', 'postgres', '-c', f'psql -X -q --csv -v ON_ERROR_STOP=1 -d {FakeApi.db} -f {f.name}', cwd='/tmp', check_rc=False)
        os.unlink(f.name)
        if script and FakeApi.mode == 'slow':                        # it ran, but the answer comes too late
            FakeApi.mode = None
            time.sleep(3)
        if r.returncode != 0:
            return self._send(400, {'message': 'Failed to run sql query: ' + r.stderr.strip()})
        rows = list(csv.DictReader(io.StringIO(r.stdout))) if r.stdout.strip() else []
        for row in rows:
            for k, v in row.items():
                if v in ('t', 'f'):
                    row[k] = v == 't'
        self._send(201, rows)


def test_deploy_record():
    db = 'release_test_e2e'
    as_pg(f'dropdb --if-exists {db}; createdb -T {TEMPLATE} {db}')
    FakeApi.db = db
    srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), FakeApi)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    R.API = f'http://127.0.0.1:{srv.server_port}'
    clilog = tempfile.mktemp(prefix='fakecli-', dir='/tmp')
    cli = os.path.join(tempfile.mkdtemp(prefix='fakecli-'), 'supabase')
    open(cli, 'w').write('#!/bin/bash\necho "$@" >> ' + clilog + '\n'
                         'for a in "$@"; do [ "$a" = broken ] && { echo "bundle failed" >&2; exit 1; }; done\n'
                         '[ -n "$SUPABASE_ACCESS_TOKEN" ] || { echo "no token" >&2; exit 1; }\necho deployed\n')
    os.chmod(cli, 0o755)
    R.CLI = cli
    os.environ['SUPABASE_ACCESS_TOKEN'] = TOKEN

    # a repo with the real migrations (the template's history) and two functions, then a release on top of it
    g = Repo()
    os.makedirs(os.path.join(g.dir, 'supabase/migrations'))
    for f in sorted(os.listdir(os.path.join(REAL, 'supabase/migrations'))):
        if f.endswith('.sql'):
            shutil.copy(os.path.join(REAL, 'supabase/migrations', f), os.path.join(g.dir, 'supabase/migrations', f))
    g.write('supabase/functions/alpha/index.ts', 'export {}\n')
    g.write('supabase/functions/beta/index.ts', 'export {}\n')
    g.write('supabase/config.toml', '[functions.beta]\nverify_jwt = false\n')
    g.write('fabula-tablet/sw.js', "const CACHE = 'perla-v1';\n")
    c0 = g.commit('c0')
    g.write('tools/release/baseline.txt', c0 + '\n')
    g.write('tools/release/release.json', json.dumps({'version': 'v9.01', 'title_it': 'Prova del rilascio', 'after_it': ['Controlla la prova']}))
    g.write('supabase/migrations/29991231000000_e2e_probe.sql', 'create table fabula.release_e2e_probe (id int);\n')
    g.write('supabase/functions/alpha/index.ts', 'export const a = 1\n')
    g.write('supabase/functions/beta/index.ts', 'export const b = 1\n')
    g.write('fabula-tablet/sw.js', "const CACHE = 'perla-v2';\n")
    g.write('tools/bots/prompts/sales.txt', 'x\n')
    c1 = g.commit('c1')
    g.use()
    FakeApi.fn_jwt = {'alpha': True, 'beta': False}

    out = tempfile.mktemp(suffix='.json', dir='/tmp')
    rc = R.main(['deploy', '--sha', c1, '--out', out])
    res = json.load(open(out))
    cli_args = open(clilog).read() if os.path.exists(clilog) else ''
    check('deploy: functions then database, both ok', rc == 0 and list(res['steps']) == ['functions', 'database']
          and res['steps']['functions']['status'] == 'ok' and res['steps']['database']['status'] == 'ok', res)
    check('deploy: the CLI gets --use-api, the project and --no-verify-jwt only for beta',
          'deploy alpha --project-ref' in cli_args and '--use-api' in cli_args
          and any(l.endswith('--no-verify-jwt') and ' beta ' in l + ' ' for l in cli_args.splitlines())
          and not any('alpha' in l and '--no-verify-jwt' in l for l in cli_args.splitlines()), cli_args)
    check('deploy: the migration is applied and in the history',
          psql_at(db, "select (to_regclass('fabula.release_e2e_probe') is not null)::text || ' ' || count(*) from supabase_migrations.schema_migrations where version = '29991231000000'") == 'true 1')

    rc = R.main(['record', '--sha', c1, '--result', out, '--site', '/nonexistent', '--site-outcome', 'success', '--job-status', 'success',
                 '--run-url', 'https://github.com/nickdv6/caseificio-ops/actions/runs/1'])
    row = psql_at(db, "select status || '|' || version || '|' || (steps->'database'->>'status') || '|' || prompts::text from fabula.releases order by id desc limit 1")
    msg = psql_at(db, "select severity || '|' || title from fabula.bot_messages where agent = 'rilascio' order by id desc limit 1")
    check('record: the release row', rc == 0 and row.startswith('ok|v9.01|ok|'), row)
    check('record: the Bot feed message asks for the step by hand and the prompts', msg.startswith('warn|Rilascio v9.01 fatto: 2 cose da fare'), msg)

    rc = R.main(['deploy', '--sha', c1, '--out', out])
    res = json.load(open(out))
    check('deploy again from the same base: the database step has nothing to do', rc == 0 and res['steps']['database']['status'] == 'skipped', res['steps'])

    g.write('supabase/migrations/29991231000100_e2e_bad.sql', 'create table fabula.release_e2e_bad (id int);\nselect 1/0;\n')
    c2 = g.commit('c2')
    rc = R.main(['deploy', '--sha', c2, '--out', out])
    res = json.load(open(out))
    check('deploy: a failing migration stops the release and changes nothing',
          rc == 2 and res['steps']['database']['status'] == 'failed' and 'Database non aggiornato' in res['steps']['database']['error']
          and psql_at(db, "select to_regclass('fabula.release_e2e_bad') is null") == 't', res['steps'])
    rc = R.main(['record', '--sha', c2, '--result', out, '--site-outcome', 'skipped', '--job-status', 'failure',
                 '--run-url', 'https://github.com/nickdv6/caseificio-ops/actions/runs/2'])
    msg = psql_at(db, "select severity || '|' || title from fabula.bot_messages where agent = 'rilascio' order by id desc limit 1")
    tg = psql_at(db, "select topic from fabula.notify_outbox where title like 'Rilascio v9.01 fermato%' order by created_at desc limit 1")
    check('record: a stopped release is an alert that goes to Telegram (infra)', msg.startswith('alert|Rilascio v9.01 fermato al passo «database»') and tg == 'infra', f'{msg} / {tg}')
    chk = psql_at(db, "select fabula.infra_checks()->'release'->>'done'")
    check('Sistema: «Rilasci automatici» is red after a stopped release', chk == 'false', chk)

    g.rm('supabase/migrations/29991231000100_e2e_bad.sql')
    g.write('supabase/functions/broken/index.ts', 'export {}\n')
    c3 = g.commit('c3')
    rc = R.main(['deploy', '--sha', c3, '--out', out])
    res = json.load(open(out))
    check('deploy: a function that does not deploy stops before the database', rc == 2 and res['steps']['functions']['status'] == 'failed'
          and 'database' not in res['steps'] and 'broken' in res['steps']['functions']['error'], res['steps'])

    psql_at(db, "insert into supabase_migrations.schema_migrations(version, name) values ('29991231000500', 'outside')")
    g.rm('supabase/functions/broken/index.ts')
    c4 = g.commit('c4')
    rc = R.main(['deploy', '--sha', c4, '--out', out])
    res = json.load(open(out))
    check('deploy: a version on the database that GitHub lacks → STOP before any function is deployed',
          rc == 2 and 'GitHub main non ha' in res.get('error', '') and res['steps'] == {}, res)
    psql_at(db, "delete from supabase_migrations.schema_migrations where version = '29991231000500'")

    FakeApi.stale_function = True
    g.write('supabase/functions/alpha/index.ts', 'export const a = 2\n')
    c5 = g.commit('c5')
    rc = R.main(['deploy', '--sha', c5, '--out', out])
    res = json.load(open(out))
    check('deploy: a function Supabase still shows as old is a failure', rc == 2 and 'versione nuova' in (res['steps'].get('functions') or {}).get('error', ''), res['steps'])
    FakeApi.stale_function = False

    os.environ['SUPABASE_ACCESS_TOKEN'] = 'wrong'
    rc = R.main(['deploy', '--sha', c5, '--out', out])
    res = json.load(open(out))
    check('deploy: a wrong token says so in plain words', rc == 2 and 'token non valido' in res.get('error', ''), res.get('error'))
    del os.environ['SUPABASE_ACCESS_TOKEN']
    rc = R.main(['deploy', '--sha', c5, '--out', out])
    res = json.load(open(out))
    check('deploy: no token → STOP naming the missing secret', rc == 2 and 'SUPABASE_ACCESS_TOKEN' in res.get('error', ''), res.get('error'))
    os.environ['SUPABASE_ACCESS_TOKEN'] = TOKEN

    rc = R.main(['deploy', '--sha', c1, '--live', c5, '--out', out])
    res = json.load(open(out))
    check('deploy: an older commit than the live one does nothing', rc == 2 and 'behind' in res.get('error', ''), res.get('error'))

    # the live commit, read back: Management API (apply job) and PostgREST with the publishable key (plan job)
    gho = tempfile.mktemp(dir='/tmp')
    os.environ['GITHUB_OUTPUT'] = gho
    rc = R.main(['live', '--source', 'api'])
    check('live (api): the last «ok» release is the live commit', rc == 0 and f'live={c1}' in open(gho).read(), open(gho).read() if os.path.exists(gho) else '')
    os.environ['SUPABASE_PUBLISHABLE_KEY'] = 'test-publishable-key'
    R.PUBLIC_URL = R.API
    open(gho, 'w').close()
    rc = R.main(['live', '--source', 'public'])
    check('live (public): the same commit through public.fabula_live_release()', rc == 0 and f'live={c1}' in open(gho).read(), open(gho).read())
    FakeApi.rest_missing = True
    open(gho, 'w').close()
    rc = R.main(['live', '--source', 'public'])
    check('live (public): before v1.08 (no function) → empty, the baseline is used', rc == 0 and open(gho).read().strip() == 'live=', open(gho).read())
    FakeApi.rest_missing = False
    del os.environ['GITHUB_OUTPUT']

    # a lost answer: the history decides
    R.SQL_TIMEOUT, R.POLL = 1, (0.3, 20)
    g.write('supabase/migrations/29991231000200_e2e_slow.sql', 'create table fabula.release_e2e_slow (id int);\n')
    c6 = g.commit('c6')
    FakeApi.mode = 'slow'
    rc = R.main(['deploy', '--sha', c6, '--live', c1, '--out', out])
    res = json.load(open(out))
    check('deploy: an answer that comes too late, but the migration is in the history → ok («confermato»)',
          rc == 0 and res['steps']['database']['status'] == 'ok' and 'confermato' in res['steps']['database'].get('detail', ''), res['steps'])
    g.write('supabase/migrations/29991231000300_e2e_lost.sql', 'create table fabula.release_e2e_lost (id int);\n')
    c7 = g.commit('c7')
    R.POLL = (0.1, 5)
    FakeApi.mode = 'disconnect'
    rc = R.main(['deploy', '--sha', c7, '--live', c1, '--out', out])
    res = json.load(open(out))
    check('deploy: a lost answer and nothing in the history → stopped, «esito non confermato»',
          rc == 2 and 'esito non confermato' in (res['steps'].get('database') or {}).get('error', ''), res['steps'])

    # a result that cannot be written (the token, Supabase not answering): exit 2 and a note for the «blocked» step
    rt0 = tempfile.mkdtemp(dir='/tmp')
    os.environ['RUNNER_TEMP'] = rt0
    os.environ['SUPABASE_ACCESS_TOKEN'] = 'wrong'
    rc = R.main(['record', '--sha', c7, '--result', out, '--site-outcome', 'skipped', '--job-status', 'success'])
    nf = os.path.join(rt0, 'release-blocked.json')
    note = json.load(open(nf)) if os.path.exists(nf) else {}
    check('record: a result that cannot be written exits 2 and leaves the reason for the «blocked» step',
          rc == 2 and 'non registrato' in note.get('error', ''), note)
    os.environ['SUPABASE_ACCESS_TOKEN'] = TOKEN
    os.environ['BACKUP_EXPORT_TOKEN'] = 'test-backup-token'
    rc = R.main(['blocked', '--stage', 'record', '--sha', c7, '--run-url', 'https://github.com/nickdv6/caseificio-ops/actions/runs/8'])
    rep = FakeApi.reports[-1] if FakeApi.reports else {}
    check('blocked (record): reported with the stage «record» and the reason',
          rc == 0 and rep.get('p_detail', {}).get('stage') == 'record' and 'non registrato' in rep['p_detail'].get('error', ''), rep)
    del os.environ['BACKUP_EXPORT_TOKEN']

    # blocked before the approval: reported with the backup token through the watcher's function
    rt = tempfile.mkdtemp(dir='/tmp')
    os.environ['RUNNER_TEMP'] = rt
    json.dump({'version': 'v9.02', 'sha': c7, 'error': 'prova generale fallita: boom'}, open(os.path.join(rt, 'release-blocked.json'), 'w'))
    os.environ['BACKUP_EXPORT_TOKEN'] = 'test-backup-token'
    rc = R.main(['blocked', '--sha', c7, '--run-url', 'https://github.com/nickdv6/caseificio-ops/actions/runs/9'])
    rep = FakeApi.reports[-1] if FakeApi.reports else {}
    check('blocked: reported as kind «release» with the backup token, the stage and the reason',
          rc == 0 and rep.get('p_kind') == 'release' and rep.get('p_token') == 'test-backup-token'
          and rep.get('p_detail', {}).get('stage') == 'plan' and rep['p_detail'].get('error') == 'prova generale fallita: boom', rep)
    del os.environ['BACKUP_EXPORT_TOKEN']
    n = len(FakeApi.reports)
    R.main(['blocked', '--sha', c7])
    check('blocked: without the token nothing is sent (GitHub\'s e-mail only)', len(FakeApi.reports) == n)
    del os.environ['RUNNER_TEMP']

    site = tempfile.mktemp(suffix='.json', dir='/tmp')
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a):
            pass
    srv2 = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Quiet, directory=os.path.join(g.dir, 'fabula-tablet')))
    threading.Thread(target=srv2.serve_forever, daemon=True).start()
    rc = R.main(['site-check', '--url', f'http://127.0.0.1:{srv2.server_port}/', '--out', site, '--tries', '2', '--wait', '0.1'])
    s = json.load(open(site))
    check('site-check: the published sw.js has the release version', rc == 0 and s['status'] == 'ok' and s['sw'] == 'perla-v2', s)
    rc = R.main(['site-check', '--url', 'http://127.0.0.1:9/', '--out', site, '--tries', '1', '--wait', '0'])
    s = json.load(open(site))
    check('site-check: a site that does not answer is a warning, not a failure', rc == 0 and s['status'] == 'warn' and s['detail'], s)
    srv.shutdown(); srv2.shutdown()
    as_pg(f'dropdb --if-exists {db}')
    shutil.rmtree(g.dir, ignore_errors=True)


if __name__ == '__main__':
    if os.geteuid() != 0:
        sys.exit('run as root (sudo): the tests use su postgres')
    for t in (test_plan, test_script, test_rehearsal, test_deploy_record):
        try:
            t()
        except Exception as e:      # noqa: BLE001
            import traceback
            traceback.print_exc()
            check(f'{t.__name__} finished', False, f'{type(e).__name__}: {e}')
    print('FAILURES: ' + (', '.join(fails) if fails else 'none'))
    sys.exit(1 if fails else 0)
