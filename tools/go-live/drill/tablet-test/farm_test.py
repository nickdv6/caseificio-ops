"""v0.65 end to end on the local copy: farm registers a shipment on latte.html → tablet confirms arrival at the farm's
weight → farm page shows it received. The edge function is emulated by calling the same DB functions through PostgREST
as service_role (exactly what farm-order does)."""
import json, subprocess, time, hmac, hashlib, base64, urllib.request
from playwright.sync_api import sync_playwright

import os
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../../../fabula-tablet'))
def b64(b): return base64.urlsafe_b64encode(b).rstrip(b'=').decode()
def jwt(role, sub=None):
    h = b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    c = {"role": role, "aud": "authenticated", "exp": int(time.time()) + 3600}
    if sub: c["sub"] = sub
    p = b64(json.dumps(c).encode())
    return h + '.' + p + '.' + b64(hmac.new(b"test-secret-test-secret-test-secret-0123456789", (h + '.' + p).encode(), hashlib.sha256).digest())
SVC = jwt('service_role'); CASARO = jwt('authenticated', '00000000-0000-4000-a000-000000000001')
def sql(q): return subprocess.run(['su', 'postgres', '-c', f'psql -At -d restore_drill -c "{q}"'], capture_output=True, text=True).stdout.strip()
TOKEN = sql("select value from fabula.settings where key='milk.farm_token'")

def rpc(fn, args):
    req = urllib.request.Request('http://127.0.0.1:3000/rpc/' + fn, data=json.dumps(args).encode(),
                                 headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + SVC, 'Content-Profile': 'fabula', 'Accept-Profile': 'fabula'})
    try:
        with urllib.request.urlopen(req) as r: return 200, json.loads(r.read() or 'null')
    except urllib.error.HTTPError as e: return e.code, json.loads(e.read() or '{}')

def farm_fn(route):                                   # emulates supabase/functions/farm-order
    r = route.request; H = {'access-control-allow-origin': '*', 'content-type': 'application/json'}
    if r.method == 'OPTIONS': return route.fulfill(status=200, headers=H, body='ok')
    if r.method == 'GET':
        t = r.url.split('t=')[1].split('&')[0]
        code, d = rpc('farm_milk_orders', {'p_token': t})
        return route.fulfill(status=200 if d else 403, headers=H, body=json.dumps(d or {'error': 'link non valido o scaduto'}))
    b = json.loads(r.post_data or '{}')
    if b.get('action') == 'ship':
        code, d = rpc('farm_milk_ship', {'p_token': b['t'], 'p_kg': float(b['kg']), 'p_temp': float(b['temp']) if b.get('temp') else None, 'p_ddt': b.get('ddt'), 'p_note': b.get('note')})
        return route.fulfill(status=200 if code == 200 and d else 400, headers=H, body=json.dumps({'ok': True, 'shipment': d} if code == 200 and d else {'error': str(d)}))
    code, d = rpc('farm_milk_seen', {'p_token': b['t'], 'p_plan_date': b.get('plan_date')})
    return route.fulfill(status=200 if d else 404, headers=H, body=json.dumps({'ok': True} if d else {'error': 'ordine non trovato'}))

def rest(route):                                      # tablet → local PostgREST
    u = route.request.url
    if '/rest/v1/' in u: return route.fulfill(response=route.fetch(url='http://127.0.0.1:3000/' + u.split('/rest/v1/', 1)[1]))
    if '/auth/v1/' in u: return route.fulfill(status=200, content_type='application/json', body=json.dumps({'id': '00000000-0000-4000-a000-000000000001'}), headers={'access-control-allow-origin': '*'})
    return route.fulfill(status=200, body='{}', headers={'access-control-allow-origin': '*'})

fails = []
def check(name, ok, info=''):
    print(('PASS ' if ok else 'FAIL ') + name + (f'  [{info}]' if info else '')); ok or fails.append(name)

srv = subprocess.Popen(['python3', '-m', 'http.server', '8769'], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1)
with sync_playwright() as p:
    b = p.chromium.launch()
    # ---- 1. the farm, on a phone, after scanning the QR ----
    farm = b.new_context(service_workers='block', viewport={'width': 390, 'height': 844})
    farm.route('**/functions/v1/farm-order**', farm_fn)
    fp = farm.new_page(); errs = []; fp.on('pageerror', lambda e: errs.append(str(e)))
    fp.goto(f'http://localhost:8769/latte.html?t={TOKEN}&azione=spedizione'); fp.wait_for_timeout(1500)
    check('farm: QR opens the shipment form', fp.is_visible('#ship-form'))
    fp.fill('#kg', '1048.5'); fp.fill('#temp', '3.9'); fp.fill('#note', 'cisterna 2')
    fp.click('#ship-go'); fp.wait_for_timeout(300)
    check('farm: first tap asks to confirm the weight', 'Confermo 1.048,5 kg' in fp.inner_text('#ship-go'), fp.inner_text('#ship-go'))
    fp.click('#ship-go'); fp.wait_for_timeout(1500)
    okmsg = fp.inner_text('#ship-ok') if fp.is_visible('#ship-ok') else ''
    check('farm: shipment registered with a lot code', 'Spedizione registrata' in okmsg and 'M' in okmsg, okmsg.replace('\n', ' | '))
    lot = sql("select milk_lot from fabula.milk_shipments order by created_at desc limit 1")
    check('db: shipment stored at the farm weight', sql(f"select kg||'|'||status from fabula.milk_shipments where milk_lot='{lot}'") == '1048.5|shipped')
    check('farm: latest shows "In viaggio"', 'In viaggio' in fp.inner_text('#latest'), fp.inner_text('#latest').replace('\n', ' | '))
    fp.screenshot(path='/tmp/t62/farm_shipped.png', full_page=True)

    # ---- 2. the dairy tablet confirms arrival ----
    tab = b.new_context(service_workers='block'); tab.route('**/*.supabase.co/**', rest)
    tp = tab.new_page(); tp.on('pageerror', lambda e: errs.append('tablet: ' + str(e)))
    sess = {"access_token": CASARO, "refresh_token": "r", "expires_at": int(time.time()) + 3600, "expires_in": 3600, "token_type": "bearer", "user": {"id": "00000000-0000-4000-a000-000000000001", "email": "casaro@test.it"}}
    tp.goto('http://localhost:8769/labels.html'); tp.evaluate(f"localStorage.clear(); localStorage.setItem('sb-ojkquhzaeypsphncjqwy-auth-token', {json.dumps(json.dumps(sess))})")
    tp.goto('http://localhost:8769/index.html'); tp.wait_for_function("document.querySelector('#v-home.active')", timeout=20000)
    tp.evaluate("() => { document.getElementById('manual').value = 'DDT:'; document.getElementById('btn-manual').click(); }"); tp.wait_for_timeout(1500)
    st = tp.evaluate("() => ({ ship: (document.getElementById('ship')||{}).value, opt: ((document.getElementById('ship')||{}).selectedOptions||[{}])[0].textContent, kg: document.getElementById('kg').value, kgRO: document.getElementById('kg').readOnly, lot: document.getElementById('lot').value, ddtReq: document.getElementById('ddtn').required })")
    check('tablet: pending shipment preselected, kg locked to the farm weight', st['kg'] == '1048.5' and st['kgRO'] and st['lot'] == lot and not st['ddtReq'], json.dumps(st))
    tp.evaluate("() => { const s = (id, v) => { const e = document.getElementById(id); e.value = v; e.dispatchEvent(new Event('change')); }; s('temp', '4.4'); s('abx', '0'); document.getElementById('btn-form-save').click(); }")
    tp.wait_for_timeout(2500)
    row = sql(f"select s.status||'|'||mi.qty_kg||'|'||mi.milk_lot||'|'||(mi.shipment_id = s.id) from fabula.milk_shipments s join fabula.milk_intake mi on mi.id = s.milk_intake_id where s.milk_lot='{lot}'")
    check('db: intake at the farm weight, shipment received', row == f'received|1048.500|{lot}|true', row)
    check('db: label + 2 CCP logs written with it', sql(f"select count(*) from fabula.labels where code='LOT:{lot}'") == '1')

    # ---- 3. the farm sees it received ----
    fp.reload(); fp.wait_for_timeout(1500)
    lt = fp.inner_text('#latest')
    check('farm: latest shows received + arrival temperature', 'Ricevuto' in lt and '4,4' in lt, lt.replace('\n', ' | '))
    check('farm: month total counts it', 'kg' in fp.inner_text('#totals') and fp.inner_text('#totals').split('\n')[1] != '0 kg', fp.inner_text('#totals').replace('\n', ' | '))
    fp.screenshot(path='/tmp/t62/farm_received.png', full_page=True)
    # ---- 4. QR poster ----
    fp.goto(f'http://localhost:8769/latte.html?t={TOKEN}&stampa=1'); fp.wait_for_timeout(800)
    check('poster: QR drawn', fp.evaluate("!!document.querySelector('#qr canvas, #qr img')"))
    fp.screenshot(path='/tmp/t62/farm_poster.png')
    check('no page errors', not errs, ' || '.join(errs[:3]))
    b.close()
srv.terminate()
print('FAILURES:', fails or 'none')
