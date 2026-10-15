#!/usr/bin/env python3
"""Compare the live database with the repo, function by function (audit E-27). Read-only on both sides.

The repo is the truth (repo = live): every function and view on the live database should be exactly what a fresh replay of
supabase/migrations builds. This finds a function pasted by hand in the SQL Editor, a migration applied live but changed in
the repo afterwards, or one not applied at all, and tells a real code difference from a comment-only one.

1. On live (Claude, through the Supabase connector's read-only execute_sql), run ONE of:
     select fabula.schema_fingerprint();                    -- from v1.05 on
     <the query printed by: python3 tools/ci/compare_live.py --print-sql>   -- any version, nothing to install
   and save the JSON it returns as live.json (the connector's wrapping [{"schema_fingerprint": …}] is fine).
2. Build a replay of the repo (tools/go-live/drill/infra-test/replay.sh repo_now) — or of the commit that is live.
3. sudo python3 tools/ci/compare_live.py live.json repo_now
   Exit 0 when the code is the same (comment-only differences are listed, not failed); 1 when a function or view differs.

The function names are compared without the «fabula.» prefix (it depends on the search_path the query ran with). Live runs Postgres 17
and the replay 16: on 15/10/2026 every view and every function's code came out the same across the two (17 functions differed in
comments or spacing only, a leftover of earlier pastes; harmless)."""
import json, re, subprocess, sys

# the same as fabula.schema_fingerprint(), self-contained (no function needed on live); 'via' says how it was taken
SQL = r"""select jsonb_build_object('via', 'sql',
  'functions', (select jsonb_object_agg(p.oid::regprocedure::text, jsonb_build_array(md5(pg_get_functiondef(p.oid)),
                  md5(btrim(regexp_replace(regexp_replace(pg_get_functiondef(p.oid), '--[^\n]*', '', 'g'), '\s+', ' ', 'g')))))
                  from pg_proc p where p.pronamespace = 'fabula'::regnamespace and p.prokind in ('f', 'p')),
  'views', (select jsonb_object_agg(c.relname, md5(pg_get_viewdef(c.oid))) from pg_class c where c.relnamespace = 'fabula'::regnamespace and c.relkind in ('v', 'm')),
  'migrations', (select count(*) from supabase_migrations.schema_migrations),
  'last_migration', (select max(version) from supabase_migrations.schema_migrations)) as schema_fingerprint"""
# the search_path the Supabase connector runs with: a type outside it is printed with its schema, so the replay uses the same
LIVE_PATH = 'set search_path = "$user", public, extensions;'


def norm(name):
    return re.sub(r'\bfabula\.', '', name)


def load_live(path):
    data = json.load(open(path, encoding='utf-8'))
    while isinstance(data, list):
        data = data[0]
    if isinstance(data, dict) and 'functions' not in data and len(data) == 1:
        data = next(iter(data.values()))
    if isinstance(data, str):
        data = json.loads(data)
    return data


def repo_fingerprint(db, via_sql):
    q = (LIVE_PATH + SQL) if via_sql else 'select fabula.schema_fingerprint()'
    r = subprocess.run(['su', 'postgres', '-c', f"psql -X -At -v ON_ERROR_STOP=1 -d {db}"], input=q, capture_output=True, text=True, cwd='/tmp')
    if r.returncode != 0:
        sys.exit('replay query failed: ' + r.stderr.strip()[:300])
    return json.loads(r.stdout.strip().splitlines()[-1])


def main():
    if '--print-sql' in sys.argv:
        print(SQL + ';')
        return 0
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    live = load_live(sys.argv[1])
    repo = repo_fingerprint(sys.argv[2], live.get('via') == 'sql')
    lf = {norm(k): v for k, v in (live.get('functions') or {}).items()}
    rf = {norm(k): v for k, v in (repo.get('functions') or {}).items()}
    only_live = sorted(set(lf) - set(rf))
    only_repo = sorted(set(rf) - set(lf))
    both = sorted(set(lf) & set(rf))
    code = [k for k in both if lf[k][1] != rf[k][1]]
    comments = [k for k in both if lf[k][0] != rf[k][0] and lf[k][1] == rf[k][1]]
    lv, rv = live.get('views') or {}, repo.get('views') or {}
    views = sorted(k for k in set(lv) | set(rv) if lv.get(k) != rv.get(k))

    print(f"live: {live.get('migrations')} migrations, last {live.get('last_migration')} · repo replay: {repo.get('migrations')}, last {repo.get('last_migration')}")
    print(f"functions: {len(lf)} live, {len(rf)} repo, {len(both) - len(code) - len(comments)} identical")
    for title, items in (('ONLY LIVE (made by hand or from a migration not in the repo)', only_live),
                         ('ONLY IN THE REPO (not applied live)', only_repo),
                         ('CODE DIFFERS', code), ('VIEWS DIFFER', views),
                         ('comments or spacing only (fine)', comments)):
        if items:
            print(f'{title}: {len(items)}')
            for k in items:
                print('  ' + k)
    bad = only_live or only_repo or code or views
    print('RESULT: ' + ('DIFFERENT' if bad else 'same code'))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
