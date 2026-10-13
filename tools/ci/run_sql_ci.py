#!/usr/bin/env python3
"""CI for the database (audit E-29). Runs on GitHub Actions (.github/workflows/ci.yml) and on any machine with
Postgres 16, as root (the drill scripts use `su postgres`):

    sudo python3 tools/ci/run_sql_ci.py            # whole run
    sudo python3 tools/ci/run_sql_ci.py --keep     # keep the scratch databases for a look afterwards

1. Replays every migration in supabase/migrations on an empty database (tools/go-live/drill/infra-test/replay.sh).
   Any migration that fails stops the run.
2. Security: the same scan as the live board (fabula.security_findings()); a finding that is not in
   fabula.security_accepted fails the run, so a new definer function or view without a reason never reaches main.
3. Every SQL suite (prod-test, infra-test) on its own copy of the replay, plus the CSV reader
   (node) and the restore guard (python). tablet-test/test_save_ops.sql prints values to read by eye (no PASS/FAIL), so
   it stays out; the browser suites cover the same saves. A suite fails on any «FAIL …» line, on an unexpected ERROR, or when it prints
   no PASS at all.
4. tools/ci/known_failures.txt lists the checks that are known to fail, each with its reason. They are reported but do
   not fail the run; a listed check that passes again is reported so its line can be removed.

The result goes to the job summary ($GITHUB_STEP_SUMMARY) and the exit code is 0 only when nothing unexpected failed."""
import glob, os, re, shutil, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..'))
DRILL = os.path.join(REPO, 'tools', 'go-live', 'drill')
TEMPLATE = 'ci_template'
KEEP = '--keep' in sys.argv
SUMMARY = os.environ.get('GITHUB_STEP_SUMMARY')

LINE = re.compile(r'(?:^|NOTICE:\s+|ERROR:\s+)\s*(PASS|FAIL)\s+(.*?)\s*$')
# a psql error line («psql:/tmp/x.sql:12: ERROR:  …» or «ERROR:  …»), not a check's info text that mentions ERROR
PSQL_ERROR = re.compile(r'^(?:psql:[^:]*:\d+:\s+)?ERROR:\s+(.*)$')


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def as_postgres(command):
    return sh(['su', 'postgres', '-c', command], cwd='/tmp')


def psql_file(db, path):
    """Run one SQL file as postgres from a world-readable copy; returns stdout + stderr."""
    tmp = tempfile.NamedTemporaryFile('w', suffix='.sql', delete=False, dir='/tmp')
    with open(path, encoding='utf-8') as f:
        tmp.write(f.read())
    tmp.close()
    os.chmod(tmp.name, 0o644)
    r = as_postgres(f'psql -X -d {db} -f {tmp.name}')
    os.unlink(tmp.name)
    return r.stdout + r.stderr


def psql_query(db, sql):
    r = as_postgres(f"psql -X -At -v ON_ERROR_STOP=1 -d {db} -c {sh_quote(sql)}")
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip())
    return r.stdout.strip()


def sh_quote(s):
    return "'" + s.replace("'", "'\"'\"'") + "'"


def copy_db(name):
    as_postgres(f'dropdb --if-exists {name}; createdb -T {TEMPLATE} {name}')


def drop_db(name):
    if not KEEP:
        as_postgres(f'dropdb --if-exists {name}')


def check_name(text):
    # «FAIL name  [info]»: the name is what comes before the info block
    return text.split('  [', 1)[0].strip()


def parse(output):
    passed, failed, errors = 0, [], []
    for raw in output.splitlines():
        m = LINE.search(raw)
        if m:
            if m.group(1) == 'PASS':
                passed += 1
            else:
                failed.append(check_name(m.group(2)))
        else:
            e = PSQL_ERROR.match(raw)
            if e:
                errors.append(e.group(1).strip()[:200])
    return passed, failed, errors


def load_known():
    known = []
    path = os.path.join(HERE, 'known_failures.txt')
    if os.path.exists(path):
        for line in open(path, encoding='utf-8'):
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = [p.strip() for p in line.split('|')]
            if len(parts) >= 3:
                known.append({'suite': parts[0], 'check': parts[1], 'reason': parts[2], 'seen': False})
    return known


def is_known(known, suite, name):
    for k in known:
        if k['suite'] == suite and name.startswith(k['check']):
            k['seen'] = True
            return k
    return None


def main():
    t0 = time.time()
    rows, unexpected, notes = [], [], []
    as_postgres('true')
    sh(['pg_ctlcluster', '16', 'main', 'start'])

    # 1. replay
    r = sh(['bash', os.path.join(DRILL, 'infra-test', 'replay.sh'), TEMPLATE])
    tail = (r.stdout + r.stderr).strip().splitlines()
    last = next((l for l in reversed(tail) if l.startswith('migrations:')), 'replay did not finish')
    fails_m = [l for l in tail if l.startswith('FAIL ')]
    ok_replay = re.search(r'failures: 0\b', last) is not None
    rows.append(('migrations (replay)', 'ok' if ok_replay else 'FAILED', last))
    if not ok_replay:
        unexpected += [f'migration {l[5:]}' for l in fails_m] or [last]
        return finish(rows, unexpected, notes, [], t0)

    # 2. security scan on the replay
    try:
        new = psql_query(TEMPLATE, "select coalesce(string_agg(f.key, E'\\n' order by f.key), '') from fabula.security_findings() f "
                                   "where not exists (select 1 from fabula.security_accepted a where a.key = f.key)")
        found = [k for k in new.splitlines() if k]
        rows.append(('security scan', 'ok' if not found else 'FAILED', f'{len(found)} finding(s) without an accepted reason'))
        unexpected += [f'security: {k}' for k in found]
    except RuntimeError as e:
        rows.append(('security scan', 'FAILED', str(e)[:200]))
        unexpected.append(f'security scan could not run: {e}')

    # 3. SQL suites
    known = load_known()
    suites = sorted(glob.glob(os.path.join(DRILL, 'prod-test', 'test_*.sql'))) + \
             sorted(glob.glob(os.path.join(DRILL, 'infra-test', 'test_*.sql')))
    for path in suites:
        suite = os.path.relpath(path, DRILL)
        db = 'ci_' + re.sub(r'[^a-z0-9_]', '_', os.path.basename(path)[:-4].lower())
        copy_db(db)
        out = psql_file(db, path)
        drop_db(db)
        passed, failed, errors = parse(out)
        bad, known_hit = [], []
        for name in failed:
            k = is_known(known, suite, name)
            (known_hit if k else bad).append(name)
        bad_err = [e for e in errors if not e.startswith('FAIL')]
        status = 'ok'
        if bad or bad_err or (passed == 0 and not failed):
            status = 'FAILED'
            unexpected += [f'{suite}: {n}' for n in bad] + [f'{suite}: error: {e}' for e in bad_err]
            if passed == 0 and not failed and not bad_err:
                unexpected.append(f'{suite}: no PASS line at all')
        detail = f'{passed} pass' + (f', {len(bad)} fail' if bad else '') + (f', {len(known_hit)} known' if known_hit else '') + \
                 (f', {len(bad_err)} error' if bad_err else '')
        rows.append((suite, status, detail))

    # 4. other suites: CSV reader (node) and restore guard (python)
    node = shutil.which('node')
    if node:
        r = sh([node, os.path.join(DRILL, 'recon-test', 'test_recon_csv.js')])
        m = re.search(r'(\d+) passed, (\d+) failed', r.stdout)
        ok = r.returncode == 0 and m and m.group(2) == '0'
        rows.append(('recon-test/test_recon_csv.js', 'ok' if ok else 'FAILED', m.group(0) if m else (r.stderr or r.stdout)[-200:]))
        if not ok:
            unexpected.append('recon-test/test_recon_csv.js: ' + (m.group(0) if m else 'did not finish'))
    else:
        notes.append('node not found: CSV reader test skipped')
    r = sh([sys.executable, os.path.join(DRILL, 'restore_guard_test.py'), TEMPLATE])
    p, f, _ = parse(r.stdout)
    ok = 'FAILURES: none' in r.stdout
    rows.append(('restore_guard_test.py', 'ok' if ok else 'FAILED', f'{p} pass' + (f', {len(f)} fail' if f else '')))
    if not ok:
        unexpected += [f'restore_guard_test.py: {n}' for n in f] or ['restore_guard_test.py: ' + (r.stderr or r.stdout)[-200:]]

    stale = [k for k in known if not k['seen']]
    return finish(rows, unexpected, notes, stale, t0, known)


def finish(rows, unexpected, notes, stale, t0, known=None):
    lines = ['## Caseificio CI: ' + ('green' if not unexpected else 'RED'), '',
             '| Step | Result | Detail |', '|---|---|---|']
    lines += [f'| {a} | {b} | {c} |' for a, b, c in rows]
    if unexpected:
        lines += ['', '### Unexpected failures'] + [f'- {u}' for u in unexpected]
    seen = [k for k in (known or []) if k['seen']]
    if seen:
        lines += ['', '### Known failures (tools/ci/known_failures.txt)'] + [f"- {k['suite']}: {k['check']} — {k['reason']}" for k in seen]
    if stale:
        lines += ['', '### Known failures that passed: remove their line'] + [f"- {k['suite']}: {k['check']}" for k in stale]
    if notes:
        lines += ['', '### Notes'] + [f'- {n}' for n in notes]
    lines += ['', f'{time.time() - t0:.0f} s']
    text = '\n'.join(lines) + '\n'
    print(text)
    if SUMMARY:
        with open(SUMMARY, 'a', encoding='utf-8') as f:
            f.write(text)
    if not KEEP:
        as_postgres(f'dropdb --if-exists {TEMPLATE}')
    return 1 if unexpected else 0


if __name__ == '__main__':
    if os.geteuid() != 0:
        sys.exit('run as root (sudo): the drill scripts use su postgres')
    sys.exit(main())
