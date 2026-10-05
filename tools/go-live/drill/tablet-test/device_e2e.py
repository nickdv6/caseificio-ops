"""v0.74 tablet check-in against the local copy (restore_drill + setup.sql + PostgREST on :3000): the tablet registers
itself with its app version, a refused save left on the tablet reaches fabula.tablet_rejects and the bell, the pending
line says it was reported, and an older app shows the "Aggiorna" banner."""
import json, subprocess, time, os, hmac, hashlib, base64
from playwright.sync_api import sync_playwright

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../../../fabula-tablet'))
REF = 'ojkquhzaeypsphncjqwy'
def _b64(b): return base64.urlsafe_b64encode(b).rstrip(b'=').decode()
def _jwt(sub, email, secret=b"test-secret-test-secret-test-secret-0123456789"):
    h = _b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    p = _b64(json.dumps({"sub": sub, "role": "authenticated", "email": email, "aud": "authenticated", "exp": int(time.time()) + 86400}).encode())
    return h + '.' + p + '.' + _b64(hmac.new(secret, (h + '.' + p).encode(), hashlib.sha256).digest())
JWT = _jwt("00000000-0000-4000-a000-000000000001", "casaro@test.it")
def sql(q):
    r = subprocess.run(['su', 'postgres', '-c', f'psql -At -d restore_drill -c "{q}"'], capture_output=True, text=True)
    return r.stdout.strip() or r.stderr.strip()
SW = open(os.path.join(ROOT, 'sw.js')).read().split("'")[1]          # e.g. perla-v43
sql(f"insert into fabula.infra_status (key, ok, detail, data, checked_at, last_ok_at) values ('github_sw', true, '{SW}', jsonb_build_object('sw', '{SW}'), now(), now()) on conflict (key) do update set ok = true, data = excluded.data")
srv = subprocess.Popen(['python3', '-m', 'http.server', '8769'], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1)
sess = {"access_token": JWT, "refresh_token": "r", "expires_at": int(time.time()) + 86400, "expires_in": 86400, "token_type": "bearer",
        "user": {"id": "00000000-0000-4000-a000-000000000001", "email": "casaro@test.it", "aud": "authenticated", "role": "authenticated"}}
def handler(route):
    url = route.request.url
    if '/rest/v1/' in url: return route.fulfill(response=route.fetch(url='http://127.0.0.1:3000/' + url.split('/rest/v1/', 1)[1]))
    if '/auth/v1/' in url: return route.fulfill(status=200, content_type='application/json', body=json.dumps(sess['user']), headers={'access-control-allow-origin': '*'})
    return route.fulfill(status=200, body='{}', headers={'access-control-allow-origin': '*'})
fails = []
def check(name, cond, info=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f'  [{info}]' if info else ''))
    if not cond: fails.append(name)
FAILED = [{"qid": "e2e-q-" + time.strftime('%H%M%S'), "at": int(time.time() * 1000), "ops": [{"table": "haccp_log", "row": {"value_num": 99}}],
           "st": {"done": 0, "out": []}, "error": "new row violates check constraint haccp_log_value_chk", "code": "23514", "failed_at": int(time.time() * 1000)}]
try:
  with sync_playwright() as p:
    b = p.chromium.launch(); ctx = b.new_context(service_workers='block', viewport={'width': 800, 'height': 1000})
    ctx.route('**/*.supabase.co/**', handler)
    pg = ctx.new_page(); logs = []
    pg.on('pageerror', lambda e: logs.append('PAGEERROR ' + str(e)))
    pg.goto('http://localhost:8769/labels.html')
    pg.evaluate(f"localStorage.clear(); localStorage.setItem('sb-{REF}-auth-token', {json.dumps(json.dumps(sess))}); localStorage.setItem('fabula_failed', {json.dumps(json.dumps(FAILED))})")
    pg.goto('http://localhost:8769/index.html')
    pg.wait_for_function("document.querySelector('#v-home.active')", timeout=20000); pg.wait_for_timeout(4500)
    uid = pg.evaluate("localStorage.getItem('perla_device_uid')")
    row = sql(f"select label || '|' || app_version || '|' || failed_len from fabula.devices where device_uid = '{uid}'")
    check('tablet checked in with its label and app version', row == f'tablet-1|{SW}|1', row)
    check('the refused save reached the database in full', sql(f"select what || '|' || code from fabula.tablet_rejects where qid = '{FAILED[0]['qid']}'") == 'haccp_log|23514')
    check('and the bell (alert from Zio Tonino)', sql("select count(*) from fabula.bot_messages where agent = 'tablet' and severity = 'alert'") != '0')
    pg.evaluate("document.getElementById('pending').click()"); pg.wait_for_timeout(300)
    check('the pending line says it was already reported', "Già segnalate all'ufficio" in pg.evaluate("document.getElementById('toast').textContent"), pg.evaluate("document.getElementById('toast').textContent"))
    check('no update banner on the current version', pg.evaluate("document.getElementById('update-banner').style.display") == 'none')
    # a newer version is live
    sql("update fabula.infra_status set data = jsonb_build_object('sw', 'perla-v999') where key = 'github_sw'")
    pg.goto('http://localhost:8769/index.html'); pg.wait_for_function("document.querySelector('#v-home.active')", timeout=20000); pg.wait_for_timeout(4000)
    check('older app: "Aggiorna" banner shown', pg.evaluate("document.getElementById('update-banner').style.display") == '', pg.evaluate("document.getElementById('update-banner').innerText"))
    check('refused save not sent twice', sql(f"select count(*) from fabula.tablet_rejects where qid = '{FAILED[0]['qid']}'") == '1')
    pg.screenshot(path='/tmp/device_banner.png', clip={'x': 0, 'y': 0, 'width': 800, 'height': 400})
    check('no page errors', not logs, ' | '.join(logs)[:300])
    b.close()
finally:
    srv.terminate()
print('FAILURES:', fails or 'none')
