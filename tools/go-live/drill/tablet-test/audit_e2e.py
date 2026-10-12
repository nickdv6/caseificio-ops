"""v0.93 audit fixes on the tablet (A-02, A-10/FARM-03), against the local copy (same setup as e2e.py: restore_drill + setup.sql +
PostgREST on :3000 + a milk supplier).
A-02: one delivery feeds two open vat loads → scanning the tank label asks which lot (it used to take an arbitrary one), refuses to
      go on without a choice, and opens the lot that was picked.
A-10: two farm loads in transit → milk arrival no longer preselects the newest one; it asks which load arrived, shows how long ago
      each left, and a choice locks that load's kg and lot.
Expect "FAILURES: none"."""
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
RUN = time.strftime('%H%M%S'); MILK = 'AM' + RUN; L1 = 'LA' + RUN + '-A'; L2 = 'LA' + RUN + '-B'

def sql(q):
    r = subprocess.run(['su', 'postgres', '-c', f'psql -At -d restore_drill -c "{q}"'], capture_output=True, text=True)
    return r.stdout.strip() or r.stderr.strip()

sup = sql("select id from fabula.parties where is_milk_supplier and active order by created_at limit 1")
moz = sql("select id from fabula.products where sku = 'MOZ-DOP-KG'")
mid = sql(f"insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source) values ((now() at time zone 'Europe/Rome')::date, '06:30', '{sup}', '{MILK}', 1200, true, 4, 'tablet') returning id").splitlines()[0]
for lot, mins in ((L1, 180), (L2, 40)):
    bid = sql(f"insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, source) values ((now() at time zone 'Europe/Rome')::date, '{lot}', '{moz}', 600, 'milk', now() - interval '{mins} minutes', 'tablet') returning id").splitlines()[0]
    sql(f"insert into fabula.batch_milk_inputs (batch_id, milk_intake_id, qty_kg) values ('{bid}', '{mid}', 600)")
sql("update fabula.milk_shipments set status = 'received' where status = 'shipped'")   # only this test's loads in transit
sql(f"insert into fabula.milk_shipments (shipped_at, supplier_id, kg, milk_lot, status) values (now() - interval '5 hours', '{sup}', 1050, 'MS{RUN}-1', 'shipped'), (now() - interval '1 hour', '{sup}', 980, 'MS{RUN}-2', 'shipped')")

srv = subprocess.Popen(['python3', '-m', 'http.server', '8768'], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(1)
sess = {"access_token": JWT, "refresh_token": "r", "expires_at": int(time.time()) + 86400, "expires_in": 86400, "token_type": "bearer",
        "user": {"id": "00000000-0000-4000-a000-000000000001", "email": "casaro@test.it", "aud": "authenticated", "role": "authenticated"}}

def handler(route):
    url = route.request.url
    if '/rest/v1/' in url:
        return route.fulfill(response=route.fetch(url='http://127.0.0.1:3000/' + url.split('/rest/v1/', 1)[1]))
    if '/auth/v1/' in url:
        return route.fulfill(status=200, content_type='application/json', body=json.dumps(sess['user']), headers={'access-control-allow-origin': '*'})
    return route.fulfill(status=200, body='{}', headers={'access-control-allow-origin': '*'})

fails = []
def check(name, cond, info=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f'  [{info}]' if info else ''))
    if not cond: fails.append(name)

try:
  with sync_playwright() as p:
    b = p.chromium.launch(); ctx = b.new_context(service_workers='block', viewport={'width': 800, 'height': 1280})
    ctx.route('**/*.supabase.co/**', handler)
    pg = ctx.new_page(); logs = []
    pg.on('pageerror', lambda e: logs.append('PAGEERROR ' + str(e)))
    pg.goto('http://localhost:8768/labels.html')
    pg.evaluate(f"localStorage.clear(); localStorage.setItem('sb-{REF}-auth-token', {json.dumps(json.dumps(sess))})")
    pg.goto('http://localhost:8768/index.html')
    pg.wait_for_function("document.querySelector('#v-home.active')", timeout=20000); pg.wait_for_timeout(2500)
    view = lambda: pg.evaluate("(document.querySelector('.view.active')||{}).id")
    title = lambda: pg.evaluate("document.getElementById('f-title').textContent")
    scan = lambda c: (pg.evaluate("c => { document.getElementById('manual').value = c; document.getElementById('btn-manual').click(); }", c), pg.wait_for_timeout(1800))

    # A-02 · two open loads on one delivery
    scan('LOT:' + MILK)
    opts = pg.evaluate("[...document.querySelectorAll('#pickb option')].map(o => o.value + '|' + o.textContent)") if pg.evaluate("!!document.getElementById('pickb')") else []
    check('tank scan with two open lots asks which one', view() == 'v-form' and title() == 'Più lotti aperti da questo latte' and len(opts) == 3, f"{title()} {opts}")
    check('…no lot preselected, the oldest listed first with its start time', opts and opts[0].startswith('|') and opts[1].startswith(L1 + '|') and 'avviato alle' in opts[1], str(opts))
    pg.evaluate("document.getElementById('btn-form-save').click()"); pg.wait_for_timeout(800)
    check('…Salva without a choice does not go on', view() == 'v-form' and title() == 'Più lotti aperti da questo latte', title())
    pg.evaluate(f"(() => {{ const s = document.getElementById('pickb'); s.value = '{L2}'; s.dispatchEvent(new Event('change')); document.getElementById('btn-form-save').click(); }})()"); pg.wait_for_timeout(2000)
    where = pg.evaluate("(document.querySelector('.view.active #d-title')||{}).textContent || document.getElementById('f-title').textContent")
    check('…the lot that was picked opens (working steps or close)', L2 in where and L1 not in where, f"{view()} · {where}")

    # A-10 · two farm loads in transit
    pg.goto('http://localhost:8768/index.html'); pg.wait_for_function("document.querySelector('#v-home.active')", timeout=20000); pg.wait_for_timeout(1500)
    scan('DDT:')
    s = pg.evaluate("(() => { const s = document.getElementById('ship'); return s ? { v: s.value, req: s.required, opts: [...s.options].map(o => o.value + '|' + o.textContent), kgRO: document.getElementById('kg').readOnly } : null; })()")
    check('milk arrival with two loads in transit: nothing preselected, the choice is required',
          s and s['v'] == '' and s['req'] and not s['kgRO'] and '(2)' in s['opts'][0], json.dumps(s, ensure_ascii=False))
    check('…each load shows how long ago it left', s and any('partita 5 h fa' in o for o in s['opts']) and any('partita 1 h fa' in o for o in s['opts']), json.dumps(s and s['opts'], ensure_ascii=False))
    pg.evaluate(f"(() => {{ const s = document.getElementById('ship'); s.value = [...s.options].find(o => o.textContent.includes('MS{RUN}-1')).value; s.dispatchEvent(new Event('change')); }})()")
    picked = pg.evaluate("({ kg: document.getElementById('kg').value, lot: document.getElementById('lot').value, ro: document.getElementById('kg').readOnly })")
    check('…picking a load locks its kg and lot', picked['kg'] == '1050' and picked['lot'] == f'MS{RUN}-1' and picked['ro'], json.dumps(picked))
    pg.evaluate("(() => { const s = document.getElementById('ship'); s.value = 'none'; s.dispatchEvent(new Event('change')); })()")
    check('…«nessuna» unlocks the fields again', pg.evaluate("!document.getElementById('kg').readOnly && document.getElementById('kg').value === ''"))
    check('no page errors', not logs, '; '.join(logs))
    b.close()
finally:
    srv.terminate()
    sql("update fabula.milk_shipments set status = 'received' where milk_lot like 'MS" + RUN + "-%'")
print('FAILURES: ' + (', '.join(fails) if fails else 'none'))
