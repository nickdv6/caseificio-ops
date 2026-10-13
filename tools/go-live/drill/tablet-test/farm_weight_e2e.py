"""v0.96 audit FARM-02 (part 2) in the browser, against the local copy (restore_drill + setup.sql + PostgREST on :3000, v096a-d).
Tablet (casaro): a farm load picked at milk arrival keeps the Masseria's kg read-only and asks «kg pesati qui»; within 2 % it says
the farm's weight counts; over 2 % it asks why, refuses to save without a reason, and with it records the dairy's weight (stock
too) and shows both on the result card. The office gets a notice; the farm page shows «Pesato al caseificio … (vale questo peso)».
Expect "FAILURES: none"."""
import json, subprocess, time, os, hmac, hashlib, base64
from playwright.sync_api import sync_playwright
from e2e_op import op_js

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../../../fabula-tablet'))
REF = 'ojkquhzaeypsphncjqwy'; PORT = 8775
def _b64(b): return base64.urlsafe_b64encode(b).rstrip(b'=').decode()
def _jwt(sub, email, secret=b"test-secret-test-secret-test-secret-0123456789"):
    h = _b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    p = _b64(json.dumps({"sub": sub, "role": "authenticated", "email": email, "aud": "authenticated", "exp": int(time.time()) + 86400}).encode())
    return h + '.' + p + '.' + _b64(hmac.new(secret, (h + '.' + p).encode(), hashlib.sha256).digest())
CASARO = ("00000000-0000-4000-a000-000000000001", "casaro@test.it")
OWNER = ("00000000-0000-4000-a000-0000000000b1", "owner@test.it")
RUN = time.strftime('%H%M%S')

def sql(q):
    r = subprocess.run(['su', 'postgres', '-c', f'psql -At -d restore_drill -c "{q}"'], capture_output=True, text=True)
    return r.stdout.strip() or r.stderr.strip()
def sql1(q): return (sql(q).splitlines() or [''])[0]


TODAY = sql1("select (now() at time zone 'Europe/Rome')::date")
TOKEN = sql1("select value from fabula.settings where key = 'milk.farm_token'")
sup = sql1("select id from fabula.parties where is_milk_supplier and active order by created_at limit 1")
LOT = 'MW' + RUN
sql(f"update fabula.milk_shipments set status = 'cancelled', cancel_reason = 'test e2e', cancelled_at = now() where status = 'shipped'")
SID = sql1(f"insert into fabula.milk_shipments (shipped_at, ship_date, kg, milk_lot, status, supplier_id) values (now() - interval '1 hour', '{TODAY}', 1100, '{LOT}', 'shipped', '{sup}') returning id")
srv = subprocess.Popen(['python3', '-m', 'http.server', str(PORT)], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(1)
fails = []
def check(name, cond, info=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f'  [{info}]' if info else ''))
    if not cond: fails.append(name)

def rpc(fn, args):
    import urllib.request, urllib.error
    SVC = _jwt_role('service_role')
    req = urllib.request.Request('http://127.0.0.1:3000/rpc/' + fn, data=json.dumps(args).encode(),
                                 headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + SVC, 'Content-Profile': 'fabula', 'Accept-Profile': 'fabula'})
    try:
        with urllib.request.urlopen(req) as r: return 200, json.loads(r.read() or 'null')
    except urllib.error.HTTPError as e: return e.code, json.loads(e.read() or '{}')
def _jwt_role(role, secret=b"test-secret-test-secret-test-secret-0123456789"):
    h = _b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode()); p = _b64(json.dumps({"role": role, "exp": int(time.time()) + 3600}).encode())
    return h + '.' + p + '.' + _b64(hmac.new(secret, (h + '.' + p).encode(), hashlib.sha256).digest())

def farm_fn(route):                                    # emulates supabase/functions/farm-order (GET, ship) as of v0.95
    r = route.request; H = {'access-control-allow-origin': '*', 'content-type': 'application/json'}
    if r.method == 'OPTIONS': return route.fulfill(status=200, headers=H, body='ok')
    if r.method == 'GET':
        code, d = rpc('farm_milk_orders', {'p_token': r.url.split('t=')[1].split('&')[0]})
        return route.fulfill(status=200 if d else 403, headers=H, body=json.dumps(d or {'error': 'link non valido'}))
    b = json.loads(r.post_data or '{}')
    code, d = rpc('farm_milk_ship', {'p_token': b['t'], 'p_kg': float(b['kg']), 'p_temp': None, 'p_ddt': b.get('ddt'), 'p_note': b.get('note'),
                                     'p_confirm': b.get('confirm') if isinstance(b.get('confirm'), bool) else None})
    if code == 200 and isinstance(d, dict) and d.get('needs_confirm'):
        return route.fulfill(status=200, headers=H, body=json.dumps({'ok': False, 'needs_confirm': True, 'kg': d.get('kg'), 'message': d.get('message_it')}))
    ok = code == 200 and d
    return route.fulfill(status=200 if ok else 400, headers=H, body=json.dumps({'ok': True, 'shipment': d} if ok else {'error': d.get('message', str(d)) if isinstance(d, dict) else str(d)}))

def page_as(b, who, path, logs, width=1100):
    s = {"access_token": _jwt(*who), "refresh_token": "r", "expires_at": int(time.time()) + 86400, "expires_in": 86400, "token_type": "bearer",
         "user": {"id": who[0], "email": who[1], "aud": "authenticated", "role": "authenticated"}}
    def handler(route):
        u = route.request.url
        if '/rest/v1/' in u: return route.fulfill(response=route.fetch(url='http://127.0.0.1:3000/' + u.split('/rest/v1/', 1)[1]))
        if '/auth/v1/' in u: return route.fulfill(status=200, content_type='application/json', body=json.dumps(s['user']), headers={'access-control-allow-origin': '*'})
        if '/storage/v1/' in u: return route.fulfill(status=200, content_type='application/json', body=json.dumps({'Key': 'x'}), headers={'access-control-allow-origin': '*'})
        return route.fulfill(status=200, body='{}', headers={'access-control-allow-origin': '*'})
    ctx = b.new_context(service_workers='block', viewport={'width': width, 'height': 1300}); ctx.route('**/*.supabase.co/**', handler)
    pg = ctx.new_page(); pg.on('pageerror', lambda e: logs.append('PAGEERROR ' + str(e)))
    pg.goto(f'http://localhost:{PORT}/labels.html')
    pg.evaluate(f"localStorage.clear(); localStorage.setItem('sb-{REF}-auth-token', {json.dumps(json.dumps(s))}){op_js(s)}")
    pg.goto(f'http://localhost:{PORT}/{path}')
    return ctx, pg

try:
  with sync_playwright() as p:
    b = p.chromium.launch(); logs = []
    ctx, pg = page_as(b, CASARO, 'index.html', logs, 800)
    pg.wait_for_function("document.querySelector('#v-home.active')", timeout=20000); pg.wait_for_timeout(2500)
    toast = lambda: pg.evaluate("document.getElementById('toast').textContent")
    def code(c): pg.evaluate("c => { document.getElementById('manual').value = c; document.getElementById('btn-manual').click(); }", c); pg.wait_for_timeout(1800)
    shown = lambda i: pg.evaluate(f"!!document.getElementById('{i}') && document.getElementById('{i}').offsetParent !== null")
    pg.click('#btn-scan'); pg.wait_for_timeout(400); code('DDT:')
    check('FARM-02 the fresh farm load is picked; its kg are read-only and labelled as the Masseria\'s',
          pg.evaluate("document.getElementById('ship').value") == SID and pg.evaluate("document.getElementById('kg').readOnly") is True
          and pg.evaluate("document.getElementById('kg').previousElementSibling.textContent") == 'kg scritti dalla Masseria')
    check('FARM-02 …and «kg pesati qui» is asked, required; no reason field yet', shown('kgh') and pg.evaluate("document.getElementById('kgh').required") is True and not shown('kgwhy'))
    pg.fill('#kgh', '1090')
    check('FARM-02 within 2 %: says the farm\'s weight counts', 'vale il peso della Masseria' in pg.inner_text('#kgh-info') and not shown('kgwhy'), pg.inner_text('#kgh-info'))
    pg.fill('#kgh', '1050')
    info = pg.inner_text('#kgh-info')
    check('FARM-02 over 2 %: shows both weights and the difference, asks why', '-4,5 %' in info and 'vale il peso del caseificio' in info and shown('kgwhy') and pg.evaluate("document.getElementById('kgwhy').required") is True, info)
    pg.fill('#temp', '4'); pg.select_option('#abx', '0')
    pg.evaluate("document.getElementById('btn-form-save').click()"); pg.wait_for_timeout(1200)
    check('FARM-02 …no save without the reason', sql1(f"select count(*) from fabula.milk_intake where milk_lot = '{LOT}'") == '0')
    pg.fill('#kgwhy', 'latte rimasto nella cisterna')
    pg.evaluate("document.getElementById('btn-form-save').click()"); pg.wait_for_timeout(2500)
    row = sql1(f"select farm_kg || '|' || dairy_kg || '|' || qty_kg || '|' || weight_note from fabula.milk_intake where milk_lot = '{LOT}'")
    check('FARM-02 saved with both weights; the dairy\'s counts', row == '1100.000|1050.000|1050.000|latte rimasto nella cisterna', row)
    card = pg.inner_text('#form')
    check('FARM-02 the result card says it', '1.050 kg' in card and 'Pesati qui 1.050 kg, la Masseria ne aveva scritti 1.100' in card, card[:200])
    check('FARM-02 the stock of raw milk is the weighed kg', sql1(f"select sum(qty) from fabula.stock_moves where lot_number = '{LOT}' and move_type = 'milk_intake'") == '1050.000')
    check('FARM-02 the office gets a notice', sql1(f"select count(*) from fabula.notices where key = 'milk_weight:{LOT}' and resolved_at is null") == '1')
    ctx.close()
    farm = b.new_context(service_workers='block', viewport={'width': 390, 'height': 844}); farm.route('**/functions/v1/farm-order**', farm_fn)
    fp = farm.new_page(); fp.on('pageerror', lambda e: logs.append('PAGEERROR farm ' + str(e)))
    fp.goto(f'http://localhost:{PORT}/latte.html?t={TOKEN}'); fp.wait_for_timeout(2000)
    body = fp.inner_text('body')
    check('FARM-02 the farm page shows the weight at the dairy and the reason', 'Pesato al caseificio: 1.050 kg (vale questo peso) · latte rimasto nella cisterna' in body, body[:300])
    farm.close()
    errs = [l for l in logs if 'PAGEERROR' in l]
    check('no page errors', not errs, '; '.join(errs)[:400])
finally:
    srv.terminate()
print('FAILURES:', ', '.join(fails) if fails else 'none')
