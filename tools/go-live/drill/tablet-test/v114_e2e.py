"""v1.14 (R-04, audit A-35) in the browser, against the local copy (restore_drill + setup.sql + PostgREST on :3000, v114a applied).
Pages on :8794.
- the tablet checks in as «tablet-1» and shows its name and code at the bottom of Home;
- Configurazione → Utenti e accessi → Dispositivi (titolare): the device with the same code, «Nessun dispositivo è segnato»; the
  titolare names it «Tablet laboratorio» and ticks «Tablet del caseificio»; the database keeps it and the go-live check ticks;
- the tablet takes the name at its next check-in (Home and its own storage);
- the «Aggiorna» banner shows only when the app in line is newer than the tablet's, not when the site check is behind it.
Expect "FAILURES: none"."""
import json, os, subprocess, time, hmac, hashlib, base64
from playwright.sync_api import sync_playwright
from e2e_op import op_js

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '../../../../fabula-tablet'))
REF = 'ojkquhzaeypsphncjqwy'; PORT = 8794
SECRET = b"test-secret-test-secret-test-secret-0123456789"
def _b64(b): return base64.urlsafe_b64encode(b).rstrip(b'=').decode()
def _jwt(sub, email):
    h = _b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    p = _b64(json.dumps({"sub": sub, "role": "authenticated", "email": email, "aud": "authenticated", "exp": int(time.time()) + 86400}).encode())
    return h + '.' + p + '.' + _b64(hmac.new(SECRET, (h + '.' + p).encode(), hashlib.sha256).digest())
def sql(q):
    r = subprocess.run(['su', 'postgres', '-c', f'psql -At -d restore_drill -c "{q}"'], capture_output=True, text=True)
    return r.stdout.strip() or r.stderr.strip()
def session(sub, email):
    return {"access_token": _jwt(sub, email), "refresh_token": "r", "expires_at": int(time.time()) + 86400, "expires_in": 86400, "token_type": "bearer",
            "user": {"id": sub, "email": email, "aud": "authenticated", "role": "authenticated"}}
CASARO = session("00000000-0000-4000-a000-000000000001", "casaro@test.it")
OWNER = session("00000000-0000-4000-a000-000000114e01", "owner114@test.it")
sql("insert into auth.users(id, email) values ('00000000-0000-4000-a000-000000114e01', 'owner114@test.it') on conflict do nothing")
sql("insert into fabula.staff(id, full_name, auth_user_id, app_role, role, active) values ('10000000-0000-4000-a000-000000114e01', 'Owner Uno', "
    "'00000000-0000-4000-a000-000000114e01', 'titolare', 'owner', true) on conflict (id) do nothing")
SW = open(os.path.join(ROOT, 'sw.js')).read().split("'")[1]          # perla-v80
def live(v):
    for k in ('site', 'github_sw'):
        sql(f"insert into fabula.infra_status (key, ok, detail, data, checked_at, last_ok_at) values ('{k}', true, '{v}', jsonb_build_object('sw', '{v}'), now(), now()) "
            f"on conflict (key) do update set ok = true, data = excluded.data, checked_at = now()")
live(SW)
sql("delete from fabula.devices")

def handler_for(s):
    def handler(route):
        url = route.request.url
        if '/rest/v1/' in url: return route.fulfill(response=route.fetch(url='http://127.0.0.1:3000/' + url.split('/rest/v1/', 1)[1]))
        if '/auth/v1/' in url: return route.fulfill(status=200, content_type='application/json', body=json.dumps(s['user']), headers={'access-control-allow-origin': '*'})
        return route.fulfill(status=200, body='{}', headers={'access-control-allow-origin': '*'})
    return handler
fails = []
def check(name, cond, info=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f'  [{info}]' if info else ''))
    if not cond: fails.append(name)
def page_as(b, s, path, logs, width=1100, ua=None):
    ctx = b.new_context(service_workers='block', viewport={'width': width, 'height': 1300}, locale='it-IT', **({'user_agent': ua} if ua else {}))
    ctx.route('**/*.supabase.co/**', handler_for(s))
    pg = ctx.new_page(); pg.on('pageerror', lambda e: logs.append('PAGEERROR ' + str(e)))
    pg.goto(f'http://localhost:{PORT}/labels.html')
    pg.evaluate(f"localStorage.clear(); localStorage.setItem('sb-{REF}-auth-token', {json.dumps(json.dumps(s))}){op_js(s)}")
    pg.goto(f'http://localhost:{PORT}/{path}')
    return ctx, pg
def home(pg):
    pg.wait_for_function("document.querySelector('#v-home.active')", timeout=20000); pg.wait_for_timeout(4500)   # check-in 1,5 s after start
def tc():
    return sql("select (c->>'done') || '|' || (c->>'detail') from jsonb_array_elements(fabula.ops_dashboard()->'checks') c where c->>'key' = 'tablet_checkin'")

srv = subprocess.Popen(['python3', '-m', 'http.server', str(PORT)], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1)
try:
  with sync_playwright() as p:
    b = p.chromium.launch(); logs = []
    # ================= the tablet (Android tablet, the casaro) =================
    tctx, tp = page_as(b, CASARO, 'index.html', logs, width=800, ua='Mozilla/5.0 (Linux; Android 14; SM-X200) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 Safari/537.36')
    home(tp)
    uid = tp.evaluate("localStorage.getItem('perla_device_uid')"); code = uid[:4].upper()
    row = sql(f"select label || '|' || floor || '|' || app_version from fabula.devices where device_uid = '{uid}'")
    check('the tablet checks in as «tablet-1», not a floor tablet yet', row == f'tablet-1|false|{SW}', row)
    acct = tp.evaluate("document.getElementById('acct').textContent")
    check("Home shows the tablet's name and code at the bottom", f'Tablet «tablet-1» · codice {code} · collegato come Test Casaro' == acct, acct)
    check('go-live: the tablet on the latest app does not count until it is marked', tc().startswith('false|No device is marked as the floor tablet'), tc())

    # ================= Configurazione → Dispositivi (titolare) =================
    actx, ap = page_as(b, OWNER, 'admin.html#utenti', logs, width=420)   # a phone
    ap.wait_for_selector('#devices table td', timeout=20000); ap.wait_for_timeout(1000)
    txt = ap.evaluate("document.getElementById('devices-card').innerText")
    check('the card lists the device with the same code, what it is and who used it',
          f'codice {code}' in txt and 'tablet Android' in txt and 'Test Casaro' in txt and 'aggiornata' in txt, txt.replace('\n', ' | ')[:400])
    check('…and says that no device is marked yet', 'Nessun dispositivo è segnato come «Tablet del caseificio»' in txt)
    ph = ap.evaluate("document.querySelector('#devices input[data-name]').placeholder")
    check('an unnamed device suggests a name: what it is and who used it', ph == 'tablet Android di Test', ph)
    sw = ap.evaluate("document.documentElement.scrollWidth <= window.innerWidth + 1")
    check('on a phone the page does not scroll sideways (the table scrolls in its box)', sw)
    ap.fill('#devices input[data-name]', 'Tablet laboratorio'); ap.check('#devices input[data-floor]')
    ap.evaluate("[...document.querySelectorAll('#devices button')].find(x => x.textContent.trim() === 'Salva').click()"); ap.wait_for_timeout(2500)
    row = sql(f"select label || '|' || floor || '|' || (named_at is not null) from fabula.devices where device_uid = '{uid}'")
    check('Salva names it and marks it as the floor tablet', row == 'Tablet laboratorio|true|true', row)
    check('…written to «Registro modifiche» by the titolare', sql(f"select actor || '|' || array_to_string(changed, ',') from fabula.audit_log where table_name = 'devices' and row_key = '{uid}' order by at desc limit 1") == 'Owner Uno|label,floor')
    txt = ap.evaluate("document.getElementById('devices-card').innerText")
    ap.evaluate("document.getElementById('devices-card').scrollIntoView()"); ap.screenshot(path='/tmp/claude-0/v114_devices.png', full_page=False)
    check('the list shows 1 floor tablet', '1 tablet del caseificio' in txt, txt.replace('\n', ' | ')[:300])
    check('go-live: the floor tablet on the latest app ticks the check', tc().startswith('true|Tablet laboratorio on ' + SW + ' (latest)'), tc())

    # ================= the tablet takes the name =================
    tp.reload(); home(tp)
    acct = tp.evaluate("document.getElementById('acct').textContent")
    check('at its next check-in the tablet takes the name (Home and its storage)',
          'Tablet «Tablet laboratorio»' in acct and tp.evaluate("localStorage.getItem('fabula_device')") == 'Tablet laboratorio', acct)
    check('the database kept the name although the tablet started as «tablet-1»', sql(f"select label from fabula.devices where device_uid = '{uid}'") == 'Tablet laboratorio')

    # ================= the update banner =================
    n = int(SW.split('v')[-1])
    live(f'perla-v{n - 1}')                       # the site check has not seen the new app yet
    tp.reload(); home(tp)
    check('no «Aggiorna» when the site check is behind the tablet (it said «nuova versione» before v1.14)', tp.evaluate("document.getElementById('update-banner').style.display") == 'none')
    live(f'perla-v{n + 1}')
    tp.reload(); home(tp)
    check('«Aggiorna» when a newer app is in line', tp.evaluate("document.getElementById('update-banner').style.display") == '')
    live(SW)
    check('no page errors', not logs, ' | '.join(logs)[:300])
    b.close()
finally:
    srv.terminate()
print('FAILURES:', fails or 'none')
