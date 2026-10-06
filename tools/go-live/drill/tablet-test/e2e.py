"""End-to-end test of the tablet (v0.62) against a local copy — see README.md in this folder.
Postgres database restore_drill (built by ../run_drill.sh) + PostgREST on :3000 (pgrst.conf).
Supabase REST calls are forwarded to PostgREST; 'offline' = navigator.onLine false + requests aborted.
Scenarios: A online milk intake (one transaction) · B lost reply → re-send writes once · C a full production day offline
(milk in, batch start, dosing, process steps, close) then reconnect · D Wi-Fi up but no internet."""
import json, subprocess, time, sys, os, hmac, hashlib, base64
from playwright.sync_api import sync_playwright

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../../../fabula-tablet'))
REF = 'ojkquhzaeypsphncjqwy'
def _b64(b): return base64.urlsafe_b64encode(b).rstrip(b'=').decode()
def _jwt(sub, email, secret=b"test-secret-test-secret-test-secret-0123456789"):   # same secret as pgrst.conf
    h = _b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    p = _b64(json.dumps({"sub": sub, "role": "authenticated", "email": email, "aud": "authenticated", "exp": int(time.time()) + 86400}).encode())
    return h + '.' + p + '.' + _b64(hmac.new(secret, (h + '.' + p).encode(), hashlib.sha256).digest())
JWT = _jwt("00000000-0000-4000-a000-000000000001", "casaro@test.it")   # the Test Casaro of setup.sql (role produzione)
RUN = time.strftime('%H%M%S')
state = {'off': False, 'drop_reply': False, 'calls': []}

def sql(q):
    r = subprocess.run(['su', 'postgres', '-c', f'psql -At -d restore_drill -c "{q}"'], capture_output=True, text=True)
    return r.stdout.strip() or r.stderr.strip()

srv = subprocess.Popen(['python3', '-m', 'http.server', '8766'], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(1)
sess = {"access_token": JWT, "refresh_token": "r", "expires_at": int(time.time()) + 86400, "expires_in": 86400, "token_type": "bearer",
        "user": {"id": "00000000-0000-4000-a000-000000000001", "email": "casaro@test.it", "aud": "authenticated", "role": "authenticated"}}

def handler(route):
    url = route.request.url
    if state['off']:
        return route.abort('internetdisconnected')
    if '/rest/v1/' in url:
        target = 'http://127.0.0.1:3000/' + url.split('/rest/v1/', 1)[1]
        state['calls'].append(route.request.method + ' ' + url.split('/rest/v1/', 1)[1][:60])
        resp = route.fetch(url=target)
        if state['drop_reply'] and '/rpc/save_ops' in url:
            state['drop_reply'] = False
            return route.abort('connectionreset')       # the server committed, the reply is lost
        return route.fulfill(response=resp)
    if '/auth/v1/' in url:
        return route.fulfill(status=200, content_type='application/json', body=json.dumps(sess['user']), headers={'access-control-allow-origin': '*'})
    return route.fulfill(status=200, body='{}', headers={'access-control-allow-origin': '*'})

fails = []
def check(name, cond, info=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f'  [{info}]' if info else ''))
    if not cond: fails.append(name)

with sync_playwright() as p:
    b = p.chromium.launch()
    ctx = b.new_context(service_workers='block')
    ctx.route('**/*.supabase.co/**', handler)
    ctx.add_init_script("window.__off=false;Object.defineProperty(Navigator.prototype,'onLine',{get:()=>!window.__off})")
    pg = ctx.new_page()
    logs = []
    pg.on('console', lambda m: logs.append(m.type + ': ' + m.text))
    pg.on('pageerror', lambda e: logs.append('PAGEERROR ' + str(e)))
    pg.goto('http://localhost:8766/labels.html')
    pg.evaluate(f"localStorage.clear(); localStorage.setItem('sb-{REF}-auth-token', {json.dumps(json.dumps(sess))})")
    pg.goto('http://localhost:8766/index.html')
    pg.wait_for_function("document.querySelector('#v-home.active')", timeout=20000)
    pg.wait_for_timeout(2500)
    check('home loaded, lot copy on the tablet', pg.evaluate("!!localStorage.getItem('perla_lots_v1')"))

    view = lambda: pg.evaluate("(document.querySelector('.view.active')||{}).id")
    toast = lambda: pg.evaluate("document.getElementById('toast').textContent")
    qlen = lambda: pg.evaluate("JSON.parse(localStorage.getItem('fabula_queue')||'[]').length")
    def go_off():
        state['off'] = True; pg.evaluate("window.__off=true; dispatchEvent(new Event('offline'))")
    def go_on():
        state['off'] = False; pg.evaluate("window.__off=false; dispatchEvent(new Event('online'))")
    def scan(code):
        pg.evaluate("c => { document.getElementById('manual').value = c; document.getElementById('btn-manual').click(); }", code)
        pg.wait_for_timeout(1200)
    def setf(vals):
        for k, v in vals.items():
            pg.evaluate("([k, v]) => { const e = document.getElementById(k); e.value = v; e.dispatchEvent(new Event('change')); }", [k, str(v)])
    def save_form():
        pg.evaluate("(() => { const v = document.getElementById('valve'); if (v && !v.value) v.value = '0'; const p = document.getElementById('past'); if (p && p.required && !p.value) p.value = '72.5'; const c = document.getElementById('ccpv'); if (c && !c.value) c.value = (c.previousElementSibling && /CCP 4/.test(c.previousElementSibling.textContent)) ? '88' : '65'; })()"); pg.evaluate("document.getElementById('btn-form-save').click()"); pg.wait_for_timeout(1500)
    def milk(ddt, lot, kg=600):
        scan('DDT:' + ddt)
        check(f'milk form opens ({lot}, offline={state["off"]})', view() == 'v-form', pg.evaluate("document.getElementById('f-title').textContent") + ' | ' + toast())
        setf({'lot': lot, 'kg': kg, 'temp': 4, 'abx': '0'}); save_form()
        pg.evaluate("() => { const b=[...document.querySelectorAll('#form button')].find(x=>x.textContent==='Fatto'); if (b) b.click(); }"); pg.wait_for_timeout(300)
    def dose_through(max_steps=40):
        n = 0
        while view() == 'v-dose' and n < max_steps:
            pg.evaluate("(() => { const ok = document.getElementById('d-ok'); if (ok.style.display === 'none') { const i = document.getElementById('d-alt-in'); const m = (document.getElementById('d-instr').textContent.match(/Obiettivo ([0-9.,]+)/) || [])[1]; i.value = (m || '70').replace(',', '.'); document.getElementById('d-alt-ok').click(); } else ok.click(); })()"); pg.wait_for_timeout(500); n += 1
        return n

    # A — online milk intake: 5 steps in one transaction
    milk('E2E1', 'TE1'+RUN)
    check('A online milk intake saved', sql("select count(*) from fabula.milk_intake where milk_lot='"+'TE1'+RUN+"'") == '1' and sql("select count(*) from fabula.labels l join fabula.milk_intake m on m.id=l.milk_intake_id where l.code='LOT:"+'TE1'+RUN+"'") == '1')
    check('A went through save_ops', any('rpc/save_ops' in c for c in state['calls']))

    # B — lost reply: the server commits, the tablet hears nothing → queued → re-sent with the same id → written once
    before_ccp = sql("select count(*) from fabula.haccp_log")
    state['drop_reply'] = True
    milk('E2E2', 'TE2'+RUN)
    check('B lost reply → queued', qlen() == 1, toast())
    go_on(); pg.wait_for_timeout(2500)
    check('B queue emptied after re-send', qlen() == 0, toast())
    check('B written exactly once', sql("select count(*) from fabula.milk_intake where milk_lot='"+'TE2'+RUN+"'") == '1' and sql("select count(*) from fabula.labels where code='LOT:"+'TE2'+RUN+"'") == '1'
          and int(sql("select count(*) from fabula.haccp_log")) - int(before_ccp) == 2, sql("select count(*) from fabula.milk_intake where milk_lot='"+'TE2'+RUN+"'"))

    # C — whole production day offline: milk in → batch start → steps → batch close, then back online
    go_off()
    milk('E2E3', 'TE3'+RUN, 500)
    scan('LOT:TE3'+RUN)
    check('C offline: lot received offline starts a batch', view() == 'v-form' and 'Inizio lotto' in pg.evaluate("document.getElementById('f-title').textContent"), pg.evaluate("document.getElementById('f-title').textContent") + ' | ' + toast())
    lot_code = pg.evaluate("document.getElementById('f-title').textContent").replace('Inizio lotto ', '')
    prod = pg.evaluate("[...document.getElementById('product').options].find(o => /Mozzarella/.test(o.textContent)).value")
    setf({'product': prod, 'mu': 'kg', 'kg': 500}); save_form()
    n1 = dose_through()
    check('C offline batch start queued', qlen() >= 2, f'queue {qlen()}, dose steps {n1}, lot {lot_code}')
    scan('LOT:TE3'+RUN)                       # again: working steps (if any), then the close form
    n2 = dose_through()
    if not (view() == 'v-form' and 'Fine lotto' in pg.evaluate("document.getElementById('f-title').textContent")):
        scan('LOT:TE3'+RUN)               # working steps done (queued) → this scan must go straight to the close form
    check('C offline: open batch found, close form reached', view() == 'v-form' and 'Fine lotto' in pg.evaluate("document.getElementById('f-title').textContent"),
          pg.evaluate("document.getElementById('f-title').textContent") + ' | ' + toast() + f' | make steps {n2}')
    setf({'out': 100, 'n': 1});
    if pg.evaluate("!!document.getElementById('whey')"): setf({'whey': 0})
    save_form()                           # v0.70: 100 kg from 500 kg = 20 % against 30 % expected → the tablet asks once
    check('C far-off yield asks to confirm (offline: yield from the kept plan)', view() == 'v-form' and 'Resa 20%' in toast() and 'premi Salva di nuovo' in toast(), toast())
    save_form(); n3 = dose_through()
    queued = qlen()
    check('C nothing reached the database while offline', sql("select count(*) from fabula.milk_intake where milk_lot='"+'TE3'+RUN+"'") == '0', f'queue {queued}, close steps {n3}')
    go_on(); pg.wait_for_timeout(4000)
    check('C queue sent after reconnect', qlen() == 0, toast())
    row = sql(f"select b.batch_lot||'|'||b.milk_in_kg||'|'||b.output_kg||'|'||(select count(*) from fabula.batch_milk_inputs i join fabula.milk_intake m on m.id=i.milk_intake_id where i.batch_id=b.id and m.milk_lot='TE3{RUN}')||'|'||(select count(*) from fabula.stock_moves s where s.batch_id=b.id and s.source='tablet') from fabula.production_batches b where b.batch_lot='{lot_code}'")
    check('C batch in the database: milk 500, output 100, milk input linked, milk + 3 dosed ingredients + output', row.endswith('|500.000|100.000|1|5'), row)
    check('C dosing/steps recorded', True, sql(f"select (select count(*) from fabula.batch_step_logs l join fabula.production_batches b on b.id=l.batch_id where b.batch_lot='{lot_code}')||' step logs, '||(select count(*) from fabula.stock_moves s where s.lot_number='{lot_code}' and s.source <> 'tablet')||' ingredient moves'"))
    check('C ledger rows (exactly-once ids)', True, sql("select count(*) from fabula.save_ledger"))
    # D — Wi-Fi up but no internet (navigator says online, every request fails): lot TE1 from the tablet copy
    state['off'] = True
    scan('LOT:TE1'+RUN)
    title = pg.evaluate("document.getElementById('f-title').textContent")
    check('D no internet: lot read from the tablet copy, batch start form', view() == 'v-form' and 'Inizio lotto' in title, title + ' | ' + toast())
    lot2 = title.replace('Inizio lotto ', '')
    prod = pg.evaluate("[...document.getElementById('product').options].find(o => /Mozzarella/.test(o.textContent)).value")
    setf({'product': prod, 'mu': 'kg', 'kg': 300}); save_form(); dose_through()
    check('D saved into the queue', qlen() >= 1, toast())
    go_on(); pg.wait_for_timeout(4000)
    check('D sent after the internet came back', qlen() == 0 and sql(f"select count(*) from fabula.production_batches where batch_lot='{lot2}'") == '1', toast())
    failed = pg.evaluate("localStorage.getItem('fabula_failed')")
    check('no refused records', failed in (None, '[]'), failed or '')
    errs = [l for l in logs if l.startswith('PAGEERROR')]
    check('no page errors', not errs, ' || '.join(errs[:5]))
    b.close()
srv.terminate()
print('FAILURES:', fails if fails else 'none')
