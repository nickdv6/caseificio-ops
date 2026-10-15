"""v1.07 «Prima dell'avvio» in the browser, against the local copy (restore_drill + setup.sql + PostgREST on :3000, v107a–b applied). Port 8787.
Console → Oggi as the titolare, «Conformità ieri»:
- when the brief says pre_opening (before the start, nothing real going on), the card says the day's checks are not asked, as a grey
  status line (not red, not counted as a problem), so an empty list is not read as «all done»;
- without pre_opening the line is not there.
The suites before this one leave real lots and milk in restore_drill, so the database is never quiet here: the brief the page receives
is the database's own, with pre_opening added for the first load (what the database sends on a quiet day is covered by
prod-test/test_v107_quiet.sql). Expect "FAILURES: none"."""
import json, subprocess, time, os, hmac, hashlib, base64
from playwright.sync_api import sync_playwright

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../../../fabula-tablet'))
REF = 'ojkquhzaeypsphncjqwy'; PORT = 8787
def _b64(b): return base64.urlsafe_b64encode(b).rstrip(b'=').decode()
def _jwt(sub, email, secret=b"test-secret-test-secret-test-secret-0123456789"):
    h = _b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    p = _b64(json.dumps({"sub": sub, "role": "authenticated", "email": email, "aud": "authenticated", "exp": int(time.time()) + 86400}).encode())
    return h + '.' + p + '.' + _b64(hmac.new(secret, (h + '.' + p).encode(), hashlib.sha256).digest())
def sql(q):
    r = subprocess.run(['su', 'postgres', '-c', f'psql -At -d restore_drill -c "{q}"'], capture_output=True, text=True)
    if 'ERROR' in r.stderr: print('SQL ERROR:', q[:90], '→', r.stderr.strip()[:300])
    return r.stdout.strip() or r.stderr.strip()

OWNER = ("00000000-0000-4000-a000-0000000107e1", "v107-owner@test.it")
sql(f"insert into auth.users(id, email) values ('{OWNER[0]}', '{OWNER[1]}') on conflict do nothing")
sql(f"insert into fabula.staff(id, full_name, auth_user_id, app_role, role, active) values ('10000000-0000-4000-a000-0000000107e1', 'Titolare V107', '{OWNER[0]}', 'titolare', 'owner', true) on conflict do nothing")
NOTE = "Prima dell'avvio (lun 25/01) i controlli HACCP del giorno non sono richiesti"

srv = subprocess.Popen(['python3', '-m', 'http.server', str(PORT)], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1)
fails = []
def check(name, cond, info=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f'  [{info}]' if info else ''))
    if not cond: fails.append(name)
def page_as(b, who, path, logs, quiet):
    s = {"access_token": _jwt(*who), "refresh_token": "r", "expires_at": int(time.time()) + 86400, "expires_in": 86400, "token_type": "bearer",
         "user": {"id": who[0], "email": who[1], "aud": "authenticated", "role": "authenticated"}}
    def handler(route):
        try:
            u = route.request.url
            if '/rest/v1/' in u:
                r = route.fetch(url='http://127.0.0.1:3000/' + u.split('/rest/v1/', 1)[1])
                if quiet and '/rpc/daily_brief' in u and r.status == 200:
                    j = r.json()
                    j['haccp'] = dict(j.get('haccp') or {}, missing_daily_checks=[], evening_cold_checks_missing=[])
                    j['tasks'] = dict(j.get('tasks') or {}, overdue=[])
                    j['pre_opening'] = {'tasks_start': '2027-01-25', 'note_it': NOTE}
                    return route.fulfill(response=r, body=json.dumps(j))
                return route.fulfill(response=r)
            if '/auth/v1/' in u: return route.fulfill(status=200, content_type='application/json', body=json.dumps(s['user']), headers={'access-control-allow-origin': '*'})
            return route.fulfill(status=200, body='{}', headers={'access-control-allow-origin': '*'})
        except Exception: pass
    ctx = b.new_context(service_workers='block', viewport={'width': 1100, 'height': 1400}, locale='it-IT'); ctx.route('**/*.supabase.co/**', handler)
    pg = ctx.new_page(); pg.on('pageerror', lambda e: logs.append('PAGEERROR ' + str(e)))
    pg.goto(f'http://localhost:{PORT}/labels.html')
    pg.evaluate(f"localStorage.clear(); localStorage.setItem('sb-{REF}-auth-token', {json.dumps(json.dumps(s))})")
    pg.goto(f'http://localhost:{PORT}/{path}')
    return ctx, pg

try:
  with sync_playwright() as p:
    b = p.chromium.launch(); logs = []
    ctx, cp = page_as(b, OWNER, 'console.html#oggi', logs, quiet=True)
    cp.wait_for_timeout(7000)
    lines = cp.evaluate("[...document.querySelectorAll('#haccp li')].map(li => [li.className, li.innerText])")
    note = [l for l in lines if NOTE in l[1]]
    check('«Conformità ieri» before the start: the day\'s checks are not asked, said in a line', len(note) == 1, json.dumps(lines, ensure_ascii=False)[:300])
    check('…as a grey status line, not red', bool(note) and note[0][0] == 'status', json.dumps(note, ensure_ascii=False))
    check('…and no missing-check line', not any('Controllo mancante' in l[1] or 'Controllo serale mancante' in l[1] for l in lines), json.dumps(lines, ensure_ascii=False)[:300])
    ctx.close()
    ctx, cp = page_as(b, OWNER, 'console.html#oggi', logs, quiet=False)
    cp.wait_for_timeout(7000)
    lines = cp.evaluate("[...document.querySelectorAll('#haccp li, #haccp div')].map(li => li.innerText)")
    check('without pre_opening the line is not there', lines and not any("Prima dell'avvio" in l for l in lines), json.dumps(lines, ensure_ascii=False)[:300])
    ctx.close()
    check('no page errors', not logs, ' / '.join(logs)[:300])
    b.close()
finally:
    srv.terminate()
print('FAILURES: ' + (', '.join(fails) if fails else 'none'))
