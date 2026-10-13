"""v0.94 (audit A-10 / FARM-03 / FARM-02b) end to end on the local copy (restore_drill + v094a, PostgREST on :3000):
farm page → registers a load with the wrong weight and corrects it (reason, second tap confirms), registers a load twice and
cancels the copy; the page shows the corrected weight and the cancellation; the tablet no longer offers the cancelled load and
takes the corrected kg; the console lists a load stuck «in viaggio» for 40 h in red and the owner cancels it with a reason.
The edge function farm-order is emulated by calling the same database functions as service_role (as farm_test.py does).
Expect "FAILURES: none"."""
import json, os, subprocess, time, hmac, hashlib, base64, urllib.request
from playwright.sync_api import sync_playwright

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../../../fabula-tablet'))
REF = 'ojkquhzaeypsphncjqwy'
def b64(b): return base64.urlsafe_b64encode(b).rstrip(b'=').decode()
def jwt(role, sub=None, email=None):
    h = b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    c = {"role": role, "aud": "authenticated", "exp": int(time.time()) + 3600}
    if sub: c["sub"] = sub
    if email: c["email"] = email
    p = b64(json.dumps(c).encode())
    return h + '.' + p + '.' + b64(hmac.new(b"test-secret-test-secret-test-secret-0123456789", (h + '.' + p).encode(), hashlib.sha256).digest())
SVC = jwt('service_role')
CASARO = ("00000000-0000-4000-a000-000000000001", "casaro@test.it")
OWNER = ("00000000-0000-4000-a000-0000000000b1", "owner@test.it")
def sql(q): return subprocess.run(['su', 'postgres', '-c', f'psql -At -d restore_drill -c "{q}"'], capture_output=True, text=True).stdout.strip()
sql(f"insert into fabula.staff(id, full_name, auth_user_id, app_role, role, active) values ('10000000-0000-4000-a000-0000000000b1', 'Owner E2E', '{OWNER[0]}', 'titolare', 'owner', true) on conflict do nothing")
TOKEN = sql("select value from fabula.settings where key='milk.farm_token'")
RUN = time.strftime('%H%M%S')
OFF = int(RUN[-2:])                                     # distinct kg per run: a re-entry within 3 min is taken as a double tap
K1, K2, K3 = 1400 + OFF, 900 + OFF, 960 + OFF
sql("update fabula.milk_shipments set status = 'received' where status = 'shipped'")   # only this test's loads in transit
sql("update fabula.milk_shipments set ship_date = ship_date - 60 where ship_date >= (now() at time zone 'Europe/Rome')::date - 1")   # earlier runs: the farm may register 8 a day
sql(f"insert into fabula.milk_shipments (shipped_at, ship_date, kg, milk_lot, status) values (now() - interval '40 hours', current_date - 2, 1111, 'MOLD{RUN}', 'shipped')")

def rpc(fn, args):
    req = urllib.request.Request('http://127.0.0.1:3000/rpc/' + fn, data=json.dumps(args).encode(),
                                 headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + SVC, 'Content-Profile': 'fabula', 'Accept-Profile': 'fabula'})
    try:
        with urllib.request.urlopen(req) as r: return 200, json.loads(r.read() or 'null')
    except urllib.error.HTTPError as e: return e.code, json.loads(e.read() or '{}')

def farm_fn(route):                                   # emulates supabase/functions/farm-order (GET, ship, amend)
    r = route.request; H = {'access-control-allow-origin': '*', 'content-type': 'application/json'}
    if r.method == 'OPTIONS': return route.fulfill(status=200, headers=H, body='ok')
    if r.method == 'GET':
        code, d = rpc('farm_milk_orders', {'p_token': r.url.split('t=')[1].split('&')[0]})
        return route.fulfill(status=200 if d else 403, headers=H, body=json.dumps(d or {'error': 'link non valido o scaduto'}))
    b = json.loads(r.post_data or '{}')
    if b.get('action') == 'ship':
        code, d = rpc('farm_milk_ship', {'p_token': b['t'], 'p_kg': float(b['kg']), 'p_temp': None, 'p_ddt': b.get('ddt'), 'p_note': b.get('note'),
                                         'p_confirm': b.get('confirm') if isinstance(b.get('confirm'), bool) else None})
        if code == 200 and isinstance(d, dict) and d.get('needs_confirm'):   # v0.95: same answer as the edge function
            return route.fulfill(status=200, headers=H, body=json.dumps({'ok': False, 'needs_confirm': True, 'kg': d.get('kg'), 'message': d.get('message_it')}))
    elif b.get('action') == 'amend':
        cancel = b.get('cancel') is True
        code, d = rpc('farm_milk_amend', {'p_token': b['t'], 'p_lot': b.get('lot'), 'p_kg': None if cancel else float(b['kg']), 'p_cancel': cancel, 'p_reason': b.get('reason')})
    else:
        return route.fulfill(status=404, headers=H, body='{}')
    ok = code == 200 and d
    return route.fulfill(status=200 if ok else 400, headers=H, body=json.dumps({'ok': True, 'shipment': d} if ok else {'error': d.get('message', str(d)) if isinstance(d, dict) else str(d)}))

def app_ctx(b, who, port):
    s = {"access_token": jwt('authenticated', *who), "refresh_token": "r", "expires_at": int(time.time()) + 3600, "expires_in": 3600, "token_type": "bearer",
         "user": {"id": who[0], "email": who[1], "aud": "authenticated", "role": "authenticated"}}
    def handler(route):
        u = route.request.url
        if '/rest/v1/' in u: return route.fulfill(response=route.fetch(url='http://127.0.0.1:3000/' + u.split('/rest/v1/', 1)[1]))
        if '/auth/v1/' in u: return route.fulfill(status=200, content_type='application/json', body=json.dumps(s['user']), headers={'access-control-allow-origin': '*'})
        return route.fulfill(status=200, body='{}', headers={'access-control-allow-origin': '*'})
    ctx = b.new_context(service_workers='block', viewport={'width': 1100, 'height': 1300}); ctx.route('**/*.supabase.co/**', handler)
    pg = ctx.new_page(); pg.goto(f'http://localhost:{port}/labels.html')
    pg.evaluate(f"localStorage.clear(); localStorage.setItem('sb-{REF}-auth-token', {json.dumps(json.dumps(s))})")
    return pg

fails = []
def check(name, ok, info=''):
    print(('PASS ' if ok else 'FAIL ') + name + (f'  [{info}]' if info else '')); ok or fails.append(name)

PORT = 8772
srv = subprocess.Popen(['python3', '-m', 'http.server', str(PORT)], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1)
try:
  with sync_playwright() as p:
    b = p.chromium.launch(); errs = []
    farm = b.new_context(service_workers='block', viewport={'width': 390, 'height': 844}); farm.route('**/functions/v1/farm-order**', farm_fn)
    fp = farm.new_page(); fp.on('pageerror', lambda e: errs.append('farm: ' + str(e)))
    def ship(k):
        fp.click('#ship-open'); fp.fill('#kg', k); fp.click('#ship-go'); fp.wait_for_timeout(200)
        fp.click('#ship-warn-yes' if fp.is_visible('#ship-warn') else '#ship-go'); fp.wait_for_timeout(1500)   # v0.95: a weight far from the usual loads is confirmed in the red box
        return sql("select milk_lot from fabula.milk_shipments where status = 'shipped' order by created_at desc limit 1")
    fp.goto(f'http://localhost:{PORT}/latte.html?t={TOKEN}'); fp.wait_for_timeout(1500)
    l1 = ship(str(K1))
    okmsg = fp.inner_text('#ship-ok')
    check('farm: after registering, the lot is big with «scrivilo sul DDT e sulla cisterna»', l1 in okmsg and 'Scrivi il lotto sul DDT e sulla cisterna' in okmsg and fp.is_visible('.lotbig'), okmsg.replace('\n', ' | '))

    # correct the weight
    fp.click('#latest [data-amend]'); fp.wait_for_timeout(300)
    check('farm: «Correggi o annulla» opens the form for that load', fp.is_visible('#amend-form') and l1 in fp.inner_text('#am-title'), fp.inner_text('#am-title'))
    fp.fill('#am-kg', '1050'); fp.click('#am-save'); fp.wait_for_timeout(300)
    check('farm: a correction without a reason is not sent', 'motivo' in fp.inner_text('#am-err') and sql(f"select kg from fabula.milk_shipments where milk_lot = '{l1}'") == f'{K1}.0', fp.inner_text('#am-err'))
    fp.fill('#am-why', 'uno zero di troppo'); fp.click('#am-save'); fp.wait_for_timeout(300)
    check('farm: first tap asks to confirm the new weight', f'Confermo 1.050 kg (prima 1.{K1 - 1000:03d})' in fp.inner_text('#am-save'), fp.inner_text('#am-save'))
    fp.click('#am-save'); fp.wait_for_timeout(1500)
    check('db: weight corrected, the first one kept', sql(f"select kg||'|'||original_kg||'|'||correction_reason from fabula.milk_shipments where milk_lot = '{l1}'") == f'1050.0|{K1}.0|uno zero di troppo')
    lt = fp.inner_text('#latest')
    check('farm: the latest card shows the corrected weight and the old one', '1.050' in lt and f'Peso corretto: prima 1.{K1 - 1000:03d} kg' in lt, lt.replace('\n', ' | '))

    # the same load registered twice → cancel the copy
    l2 = ship(str(K2)); l3 = ship(str(K3))
    fp.click(f'#hist [data-amend="0"]'); fp.wait_for_timeout(300)
    fp.fill('#am-why', 'registrata due volte'); fp.click('#am-cancel'); fp.wait_for_timeout(300)
    check('farm: cancelling asks to confirm', f'Confermo: annulla {l3}' in fp.inner_text('#am-cancel'), fp.inner_text('#am-cancel'))
    fp.click('#am-cancel'); fp.wait_for_timeout(1500)
    check('db: the copy is cancelled by the Masseria with the reason', sql(f"select status||'|'||cancelled_by||'|'||cancel_reason from fabula.milk_shipments where milk_lot = '{l3}'") == 'cancelled|Masseria|registrata due volte')
    hist = fp.inner_text('#hist')
    check('farm: the list shows it «Annullata» with the reason', 'Annullata' in hist and 'registrata due volte' in hist, hist.replace('\n', ' | ')[:300])
    check('db: the office got both messages in the Bot feed', sql(f"select count(*) from fabula.bot_messages where agent = 'masseria' and (title like '%{l1}%' or title like '%{l3}%')") == '2')

    # the tablet: the cancelled copy is gone, the corrected load comes at its new weight
    tp = app_ctx(b, CASARO, PORT); tp.on('pageerror', lambda e: errs.append('tablet: ' + str(e)))
    tp.goto(f'http://localhost:{PORT}/index.html'); tp.wait_for_function("document.querySelector('#v-home.active')", timeout=20000); tp.wait_for_timeout(1500)
    tp.evaluate("() => { document.getElementById('manual').value = 'DDT:'; document.getElementById('btn-manual').click(); }"); tp.wait_for_timeout(1800)
    opts = tp.evaluate("[...document.getElementById('ship').options].map(o => o.textContent)")
    check('tablet: the cancelled load is not offered; the corrected one shows 1.050 kg', not any(f'{K3} kg' in o for o in opts) and any('1.050 kg' in o for o in opts) and any(f'{K2} kg' in o for o in opts), json.dumps(opts, ensure_ascii=False))

    # the console: the 40 h load in red, the owner cancels it
    cp = app_ctx(b, OWNER, PORT); cp.on('pageerror', lambda e: errs.append('console: ' + str(e)))
    cp.goto(f'http://localhost:{PORT}/console.html#oggi'); cp.wait_for_function("document.querySelector('#farm-status')", timeout=20000); cp.wait_for_timeout(1500)
    fs = cp.inner_text('#farm-status')
    check('console: every load in transit is listed, the 40 h one flagged as never confirmed', f'MOLD{RUN}' in fs and 'mai confermata' in fs and l1 in fs and l2 in fs and l3 not in fs, fs.replace('\n', ' | ')[:400])
    check('console: the owner has an «annulla» link on each', cp.evaluate(f"!!document.querySelector('[data-cancel-ship][data-lot=\"MOLD{RUN}\"]')"))
    cp.once('dialog', lambda d: d.accept('mai partita, registrata per prova'))
    cp.click(f'[data-cancel-ship][data-lot="MOLD{RUN}"]'); cp.wait_for_timeout(1500)
    check('console: cancelled with the owner\'s name and the reason', sql(f"select status||'|'||cancelled_by||'|'||cancel_reason from fabula.milk_shipments where milk_lot = 'MOLD{RUN}'") == 'cancelled|Owner E2E|mai partita, registrata per prova')
    check('console: the list updates', f'MOLD{RUN}' not in cp.inner_text('#farm-status'), cp.inner_text('#farm-status').replace('\n', ' | ')[:300])
    check('no page errors', not errs, ' || '.join(errs[:3]))
    b.close()
finally:
    srv.terminate()
    sql(f"update fabula.milk_shipments set status = 'received' where status = 'shipped' and created_at > now() - interval '1 hour'")
print('FAILURES: ' + (', '.join(fails) if fails else 'none'))
