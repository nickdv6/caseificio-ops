"""v0.96 audit E-23: restore_backup.py cannot wipe live data by mistake.
Runs against a scratch copy of a local database (default template t96c; pass another as argv[1]); needs Postgres 16 and root.
- default = partial, and only the day-to-day records: only missing rows are added back, nothing is deleted; other tables
  (e.g. notices, settings, PINs) only when named with --tables;
- every generated SQL stops unless `set restore.confirm = '<exported_at>'` ran first, and says the backup time;
- --wipe-all needs --target; `load` needs --confirm and refuses a --target that is not the --db;
- a full restore refuses a database holding any record newer than the backup;
- --target must be exactly the project ref (or database name) of --db, never a substring.
Expect "FAILURES: none"."""
import gzip, json, os, subprocess, sys, tempfile, datetime

TEMPLATE = sys.argv[1] if len(sys.argv) > 1 else 't96c'
DB = 'restore_guard'
SCRIPT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../restore_backup.py'))
fails = []
def check(name, cond, info=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f'  [{info}]' if info else ''))
    if not cond: fails.append(name)
def sh(cmd): return subprocess.run(cmd, capture_output=True, text=True)
def psql(sql_text):
    f = tempfile.NamedTemporaryFile('w', suffix='.sql', delete=False); f.write(sql_text); f.close(); os.chmod(f.name, 0o644)
    r = sh(['su', 'postgres', '-c', f'psql -v ON_ERROR_STOP=1 -At -d {DB} -f {f.name}']); os.unlink(f.name); return r
def q(sql_text): return psql(sql_text).stdout.strip()

sh(['su', 'postgres', '-c', f'dropdb --if-exists {DB}; createdb -T {TEMPLATE} {DB}'])
# live data: two notices, one HACCP record from now (newer than the backup)
q("insert into fabula.notices (key, severity, title_it, items, expires_at) values ('rg-keep', 'info', 'live notice', '[]', now() + interval '1 day'), ('rg-gone', 'info', 'deleted after backup', '[]', now() + interval '1 day')")
cp = q("select id from fabula.haccp_control_points where code = 'CCP-COLD-1'")
q(f"insert into fabula.haccp_log (control_point_id, measured_value, result, source, operator) values ('{cp}', 3, 'ok', 'tablet', 'Test')")
rows = json.loads(q("select json_agg(n) from fabula.notices n where key like 'rg-%'"))
q("delete from fabula.notices where key = 'rg-gone'; update fabula.notices set title_it = 'live notice, changed after backup' where key = 'rg-keep'")
exp = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=1)).isoformat()
bk = tempfile.NamedTemporaryFile(suffix='.json.gz', delete=False).name
open(bk, 'wb').write(gzip.compress(json.dumps({'format': 'la-perla-backup/1', 'mode': 'latest', 'exported_at': exp, 'rome_day': exp[:10], 'tables': {'notices': rows}}).encode()))
os.chmod(bk, 0o644)
run = lambda *a: sh(['python3', SCRIPT, *a])

r = run('when', bk)
check('`when` prints the export time and the Agropoli time', r.stdout.strip() == exp and 'ora italiana' in r.stderr, r.stderr.strip())
r = run('sql', bk)
check('default = partial of the records only: notices are not touched unless named', 'PARTIAL' in r.stdout and "restore_table('notices'" not in r.stdout and 'registrazioni' in r.stderr, r.stderr.strip()[:160])
r = run('sql', bk, '--tables', 'notices')
check('partial SQL keeps a safety stop', 'PARTIAL' in r.stdout and "-- set restore.confirm = '" + exp + "';" in r.stdout and 'truncate' not in r.stdout.lower(), r.stderr.strip()[:160])
res = psql(r.stdout)
check('without the confirmation line it stops, with the backup time and the line to add', res.returncode != 0 and 'FERMO: ripristino non confermato' in res.stderr and f"set restore.confirm = '{exp}'" in res.stderr, res.stderr.strip()[:200])
check('…and nothing changed', q("select string_agg(key || '=' || title_it, ',' order by key) from fabula.notices where key like 'rg-%'") == 'rg-keep=live notice, changed after backup')
r = run('sql', bk, '--tables', 'notices', '--confirm', exp)
res = psql(r.stdout)
check('confirmed partial restore adds back the deleted row and keeps the changed one', res.returncode == 0
      and q("select string_agg(key || '=' || title_it, ',' order by key) from fabula.notices where key like 'rg-%'") == 'rg-gone=deleted after backup,rg-keep=live notice, changed after backup', res.stderr.strip()[:200])
r = run('sql', bk, '--tables', 'notices', '--confirm', '2020-01-01T00:00:00Z')
check('a --confirm that is not this backup''s time is refused', r.returncode != 0 and 'does not match' in r.stderr, r.stderr.strip()[:120])
r = run('sql', bk, '--wipe-all')
check('--wipe-all without --target is refused', r.returncode != 0 and '--target' in r.stderr, r.stderr.strip()[:120])
r = run('sql', bk, '--wipe-all', '--target', DB, '--confirm', exp)
check('a full restore says what will be lost', 'FULL' in r.stdout and 'perderai tutto quello registrato dopo' in r.stderr, r.stderr.strip()[:160])
res = psql(r.stdout)
check('a full restore refuses a database with records newer than the backup, naming the tables', res.returncode != 0 and 'registrazioni più recenti del backup' in res.stderr and 'haccp_log' in res.stderr, res.stderr.strip()[:240])
check('…and nothing was wiped', q("select count(*) from fabula.notices where key like 'rg-%'") == '2')
q("delete from fabula.haccp_log where operator = 'Test' and source = 'tablet'")   # an empty project: no record newer than the backup
res = psql(r.stdout)
check('on a database with no newer records the full restore runs (the drill case)', res.returncode == 0
      and q("select string_agg(key || '=' || title_it, ',' order by key) from fabula.notices where key like 'rg-%'") == 'rg-gone=deleted after backup,rg-keep=live notice'
      and q("select count(*) from fabula.notices") == '2', res.stderr.strip()[:200])
r = run('load', bk, '--db', f'postgresql:///{DB}')
check('`load` needs --confirm and says the backup time', r.returncode != 0 and '--confirm is required' in r.stderr and exp in r.stderr, r.stderr.strip()[:160])
r = run('load', bk, '--db', 'postgresql:///other_db', '--wipe-all', '--target', 'ojkquhzaeypsphncjqwy', '--confirm', exp)
check('`load --wipe-all` refuses a --target that is not the --db', r.returncode != 0 and 'is not the database of --db' in r.stderr, r.stderr.strip()[:160])
r = run('load', bk, '--db', 'postgresql://postgres:x@db.ojkquhzaeypsphncjqwy.supabase.co:5432/postgres', '--wipe-all', '--target', 'postgres', '--confirm', exp)
check('…and «postgres» is not accepted as the target of a Supabase project', r.returncode != 0 and 'is not the database of --db (ojkquhzaeypsphncjqwy)' in r.stderr, r.stderr.strip()[:160])
os.unlink(bk); sh(['su', 'postgres', '-c', f'dropdb --if-exists {DB}'])
print('FAILURES:', ', '.join(fails) if fails else 'none')
