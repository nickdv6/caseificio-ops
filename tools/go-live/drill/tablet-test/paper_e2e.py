"""v0.77 paper back-up against the local copy (restore_drill + setup.sql + PostgREST on :3000): a check written on the
printed sheet is typed in from 🛡 → "Ricopia da foglio di carta" with the sheet's date and time; it keeps that time
(Agropoli), source 'paper', who wrote it, and a note of who copied it; offline it waits in the queue and keeps the sheet's
time when sent; out of limit it opens the same non-conformity as a live check; after each line the paper menu comes back."""
import json, subprocess, time, os, hmac, hashlib, base64, datetime
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
srv = subprocess.Popen(['python3', '-m', 'http.server', '8770'], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1)
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
yday = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=2) - datetime.timedelta(days=1)).strftime('%Y-%m-%d')
def code(pg, c): pg.evaluate("c => { document.getElementById('manual').value = c; document.getElementById('btn-manual').click(); }", c); pg.wait_for_timeout(1200)
def fill_save(pg, day, hm, v, who=None, action=None):
    pg.fill('#pday', day); pg.fill('#ptime', hm)
    if who is not None: pg.fill('#pwho', who)
    if pg.locator('select#v').count(): pg.select_option('#v', v)
    else: pg.fill('#v', v)
    if action: pg.fill('#action', action)
    pg.click('#btn-form-save'); pg.wait_for_timeout(1800)
try:
  with sync_playwright() as p:
    b = p.chromium.launch(); ctx = b.new_context(service_workers='block', viewport={'width': 800, 'height': 1100})
    ctx.route('**/*.supabase.co/**', handler)
    pg = ctx.new_page(); logs = []
    pg.on('pageerror', lambda e: logs.append('PAGEERROR ' + str(e)))
    pg.goto('http://localhost:8770/labels.html')
    pg.evaluate(f"localStorage.clear(); localStorage.setItem('sb-{REF}-auth-token', {json.dumps(json.dumps(sess))})")
    pg.goto('http://localhost:8770/index.html')
    pg.wait_for_function("document.querySelector('#v-home.active')", timeout=20000); pg.wait_for_timeout(2500)
    code(pg, 'HACCP:')
    check('HACCP menu offers "Ricopia da foglio di carta"', 'Ricopia da foglio di carta' in pg.evaluate("document.getElementById('form').innerText"))
    code(pg, 'PAPER:')
    check('paper menu lists the 10 sheet checks', pg.locator('#form button.nitem').count() == 10)
    code(pg, 'PAPER:CCP-COLD-1')
    fill_save(pg, yday, '07:30', '3.2', who='Aiuto Banco')
    row = sql(f"select source || '|' || to_char(logged_at at time zone 'Europe/Rome', 'YYYY-MM-DD HH24:MI') || '|' || operator || '|' || (corrective_action like 'Ricopiata dal foglio cartaceo da %')::text from fabula.haccp_log l join fabula.haccp_control_points cp on cp.id = l.control_point_id where cp.code = 'CCP-COLD-1' order by created_at desc limit 1")
    check('saved with the sheet time (Agropoli), source paper, who wrote it, copy note', row == f'paper|{yday} 07:30|Aiuto Banco|true', row)
    check('back on the paper menu for the next line', pg.evaluate("document.getElementById('f-title').textContent") == 'Ricopia da foglio di carta')
    # offline: a line copied without network waits and keeps the sheet's time
    ctx.set_offline(True); pg.evaluate("window.dispatchEvent(new Event('offline'))")
    code(pg, 'PAPER:PRP-CLEAN')
    fill_save(pg, yday, '18:45', '0')
    q = pg.evaluate("JSON.parse(localStorage.getItem('fabula_queue') || '[]').length")
    check('offline: queued on the tablet', q >= 1, str(q))
    ctx.set_offline(False); pg.evaluate("window.dispatchEvent(new Event('online'))"); pg.wait_for_timeout(4000)
    row = sql(f"select source || '|' || to_char(logged_at at time zone 'Europe/Rome', 'YYYY-MM-DD HH24:MI') from fabula.haccp_log l join fabula.haccp_control_points cp on cp.id = l.control_point_id where cp.code = 'PRP-CLEAN' and source = 'paper' order by created_at desc limit 1")
    check('back online: sent with the sheet time, not the send time', row == f'paper|{yday} 18:45', row)
    # out of limit from paper: same non-conformity as a live check
    code(pg, 'PAPER:CCP-COLD-2')
    fill_save(pg, yday, '12:00', '8.5', action='prodotto spostato in cella 1')
    t = pg.evaluate("document.getElementById('toast').textContent")
    nc = sql("select count(*) from fabula.non_conformities n join fabula.haccp_log l on l.id = n.haccp_log_id where l.source = 'paper'")
    check('out of limit: NON CONFORMITÀ toast and a non-conformity opened', 'NON CONFORMIT' in t and nc == '1', f'{t[:60]} · nc={nc}')
    # a sheet older than 7 days is refused on the tablet
    code(pg, 'PAPER:CCP-COLD-1')
    old = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=9)).strftime('%Y-%m-%d')
    pg.evaluate("d => { const e = document.getElementById('pday'); e.removeAttribute('min'); e.value = d; }", old)
    pg.fill('#ptime', '08:00'); pg.fill('#v', '3'); pg.click('#btn-form-save'); pg.wait_for_timeout(1200)
    check('a sheet older than 7 days is refused', 'ultimi 7 giorni' in pg.evaluate("document.getElementById('toast').textContent"))
    pg.screenshot(path='/tmp/paper_menu.png', clip={'x': 0, 'y': 0, 'width': 800, 'height': 900})
    check('no page errors', not logs, ' | '.join(logs)[:300])
    b.close()
finally:
    srv.terminate()
print('FAILURES:', fails or 'none')
