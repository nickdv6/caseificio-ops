"""v0.70 production autopilot on the tablet, against the local copy (same setup as e2e.py: restore_drill + setup.sql +
PostgREST on :3000; run e2e.py or add a milk supplier first). A 1,150 kg delivery → Home shows two 575 kg loads; one tap
opens the batch start filled in; more milk than is left asks to confirm; the second load starts offline from the plan kept
on the tablet; after reconnect both batches are in the database; closing at a normal yield saves at once with the
expected kg shown."""
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
RUN = time.strftime('%H%M%S'); LOT = 'PM' + RUN
state = {'off': False}

def sql(q):
    r = subprocess.run(['su', 'postgres', '-c', f'psql -At -d restore_drill -c "{q}"'], capture_output=True, text=True)
    return r.stdout.strip() or r.stderr.strip()

sup = sql("select id from fabula.parties where is_milk_supplier and active order by created_at limit 1")
sql(f"insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source) values ((now() at time zone 'Europe/Rome')::date, '07:00', '{sup}', '{LOT}', 1150, true, 4, 'tablet')")
srv = subprocess.Popen(['python3', '-m', 'http.server', '8767'], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(1)
sess = {"access_token": JWT, "refresh_token": "r", "expires_at": int(time.time()) + 86400, "expires_in": 86400, "token_type": "bearer",
        "user": {"id": "00000000-0000-4000-a000-000000000001", "email": "casaro@test.it", "aud": "authenticated", "role": "authenticated"}}

def handler(route):
    url = route.request.url
    if state['off']: return route.abort('internetdisconnected')
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
    ctx.add_init_script("window.__off=false;Object.defineProperty(Navigator.prototype,'onLine',{get:()=>!window.__off})")
    pg = ctx.new_page(); logs = []
    pg.on('pageerror', lambda e: logs.append('PAGEERROR ' + str(e)))
    pg.goto('http://localhost:8767/labels.html')
    pg.evaluate(f"localStorage.clear(); localStorage.setItem('sb-{REF}-auth-token', {json.dumps(json.dumps(sess))})")
    pg.goto('http://localhost:8767/index.html')
    pg.wait_for_function("document.querySelector('#v-home.active')", timeout=20000); pg.wait_for_timeout(3000)
    view = lambda: pg.evaluate("(document.querySelector('.view.active')||{}).id")
    toast = lambda: pg.evaluate("document.getElementById('toast').textContent")
    plan_txt = lambda: pg.evaluate("document.getElementById('plan-wrap').style.display !== 'none' ? document.getElementById('plan-wrap').innerText : ''")
    mine = lambda: pg.evaluate(f"[...document.querySelectorAll('#plan .task.go')].filter(d => d.innerText.includes('{LOT}')).length")
    def setf(vals):
        for k, v in vals.items(): pg.evaluate("([k, v]) => { const e = document.getElementById(k); e.value = v; e.dispatchEvent(new Event('change')); }", [k, str(v)])
    def save_form(): pg.evaluate("(() => { const v = document.getElementById('valve'); if (v && !v.value) v.value = '0'; const p = document.getElementById('past'); if (p && p.required && !p.value) p.value = '72.5'; const c = document.getElementById('ccpv'); if (c && !c.value) c.value = (c.previousElementSibling && /CCP 4/.test(c.previousElementSibling.textContent)) ? '88' : '65'; })()"); pg.evaluate("document.getElementById('btn-form-save').click()"); pg.wait_for_timeout(1500)
    def dose_through(n=0):
        while view() == 'v-dose' and n < 40: pg.evaluate("(() => { const ok = document.getElementById('d-ok'); if (ok.style.display === 'none') { const i = document.getElementById('d-alt-in'); const m = (document.getElementById('d-instr').textContent.match(/Obiettivo ([0-9.,]+)/) || [])[1]; i.value = (m || '70').replace(',', '.'); document.getElementById('d-alt-ok').click(); } else ok.click(); })()"); pg.wait_for_timeout(450); n += 1
        return n
    def home():
        pg.evaluate("document.querySelector('#v-form .btn.secondary, #btn-form-cancel') && 0"); pg.goto('http://localhost:8767/index.html')
        pg.wait_for_function("document.querySelector('#v-home.active')", timeout=20000); pg.wait_for_timeout(2500)
    def tap_first():
        pg.evaluate(f"[...document.querySelectorAll('#plan .task.go')].find(d => d.innerText.includes('{LOT}')).click()"); pg.wait_for_timeout(1800)

    t = plan_txt()
    check('Home: "Produzione di oggi" with two 575 kg loads of the new milk', mine() == 2 and f'575 kg di latte {LOT}' in t and '≈ 172,5 kg' in t, t[:300].replace('\n', ' | '))
    pg.screenshot(path='/tmp/prod_home.png')

    tap_first()
    f = pg.evaluate("({ t: document.getElementById('f-title').textContent, kg: document.getElementById('kg').value, prod: document.getElementById('product').selectedOptions[0].text, pre: document.getElementById('preset').selectedOptions[0].text, hint: (document.querySelector('#form .hint')||{}).textContent })")
    check('one tap: batch start filled in (kg, product, preset, expected kg)', view() == 'v-form' and f['kg'] == '575' and f['prod'].startswith('Mozzarella') and f['pre'].startswith('Base · prova 29/09') and '≈ 172,5 kg' in (f['hint'] or ''), json.dumps(f, ensure_ascii=False))
    pg.screenshot(path='/tmp/prod_start.png')
    setf({'kg': 1200}); save_form()
    check('more milk than is left on the lot asks to confirm', view() == 'v-form' and 'più del latte rimasto' in toast(), toast())
    pg.evaluate("document.getElementById('kg').value = '575'; document.getElementById('kg').dispatchEvent(new Event('input', { bubbles: true }))")
    save_form(); n = dose_through()
    check('batch started from the plan, start doses run', n >= 2 and 'avviato' in toast(), f'{n} steps · {toast()}')
    lot1 = sql(f"select b.batch_lot from fabula.production_batches b join fabula.batch_milk_inputs i on i.batch_id = b.id join fabula.milk_intake m on m.id = i.milk_intake_id where m.milk_lot = '{LOT}' order by b.created_at limit 1")
    home()
    t = plan_txt()
    check('Home after the start: one load left, the batch shown as open', mine() == 1 and f'{lot1}' in t and 'in lavorazione' in t, t[:300].replace('\n', ' | '))

    # second load offline, from the plan kept on the tablet
    state['off'] = True; pg.evaluate("window.__off=true; dispatchEvent(new Event('offline'))")
    tap_first()
    check('offline: the kept plan still opens the batch start', view() == 'v-form' and pg.evaluate("document.getElementById('kg').value") == '575', pg.evaluate("document.getElementById('f-title').textContent") + ' | ' + toast())
    save_form(); dose_through()
    pg.evaluate("document.querySelector('[id=btn-scan]') && 0")
    pg.evaluate("(() => { const v = document.querySelectorAll('.view'); v.forEach(e => e.classList.toggle('active', e.id === 'v-home')); })()")
    check('offline: queued, not in the database yet', sql(f"select count(*) from fabula.batch_milk_inputs i join fabula.milk_intake m on m.id = i.milk_intake_id where m.milk_lot = '{LOT}'") == '1',
          'queue ' + str(pg.evaluate("JSON.parse(localStorage.getItem('fabula_queue')||'[]').length")))
    kept = pg.evaluate("JSON.parse(localStorage.getItem('perla_plan_v1')||'{}')")
    check('offline: the started load is gone from the kept plan', not any(x['milk_lot'] == LOT for x in kept.get('p', {}).get('proposals', [])))
    state['off'] = False; pg.evaluate("window.__off=false; dispatchEvent(new Event('online'))"); pg.wait_for_timeout(5000)
    check('after reconnect: two batches of 575 kg on the lot',
          sql(f"select count(*)||'|'||sum(i.qty_kg) from fabula.batch_milk_inputs i join fabula.milk_intake m on m.id = i.milk_intake_id where m.milk_lot = '{LOT}'") == '2|1150.000')
    home()
    check('Home: no loads left for this milk', mine() == 0, plan_txt()[:200].replace('\n', ' | '))

    # close the first batch at a normal yield
    pg.evaluate("c => { document.getElementById('manual').value = c; document.getElementById('btn-manual').click(); }", 'LOT:' + lot1); pg.wait_for_timeout(1500)
    dose_through()
    if view() != 'v-form':
        pg.evaluate("c => { document.getElementById('manual').value = c; document.getElementById('btn-manual').click(); }", 'LOT:' + lot1); pg.wait_for_timeout(1800)
    hint = pg.evaluate("(document.querySelector('#form .hint')||{}).textContent || ''")
    check('close form shows the expected kg', view() == 'v-form' and 'Attesi ≈ 172,5 kg' in hint, hint)
    setf({'out': 170, 'n': 1})
    if pg.evaluate("!!document.getElementById('whey')"): setf({'whey': 0})
    save_form(); dose_through()
    row = sql(f"select output_kg||'|'||yield_expected_pct||'|'||coalesce(yield_flag,'-') from fabula.production_batches where batch_lot = '{lot1}'")
    check('normal yield (29.6 %) saved at once, no flag', row == '170.000|30.00|-', row)
    check('no page errors', not logs, ' | '.join(logs)[:300])
    b.close()
finally:
    srv.terminate()
print('FAILURES:', fails or 'none')
