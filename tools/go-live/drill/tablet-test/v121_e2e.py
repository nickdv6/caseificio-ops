"""v1.21 (CCP 2 a tino: the holding minutes) on the tablet, against the local copy (restore_drill with v121a + setup.sql + PostgREST on
:3000, one milk supplier; pages on :8797). Checks:
- a vat started with the mozzarella preset: after the pasteurisation temperature the wizard asks «Sosta di pastorizzazione (CCP 2)» as a
  critical point (no «Fatto», no «Salta», the minutes typed, target 30 min); 25 minutes → the red question, then the lot is held and the
  register has the minutes as a non-conformity;
- a vat of a product with no preset: the start form asks the temperature AND the minutes; both reach the register, the lot is free;
- a lot that reaches its close without the minutes: the close form asks them; saved with the close, the lot closes free;
- 🛡 → Ricopia da foglio di carta lists «⏱ Pastorizzazione: minuti di sosta (MOD-02)»;
- with CCP-PAST-HOLD switched off while the app is open: the start form re-reads the control points and asks the temperature only, the
  vat starts; the mozzarella preset has no minutes step any more; the paper copy no longer lists them;
- no page errors.
Expect `FAILURES: none`."""
import json, subprocess, time, os, hmac, hashlib, base64
from playwright.sync_api import sync_playwright
from e2e_op import op_js, answer_ask

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../../../fabula-tablet'))
REF = 'ojkquhzaeypsphncjqwy'
PORT = 8797
def _b64(b): return base64.urlsafe_b64encode(b).rstrip(b'=').decode()
def _jwt(sub, email, secret=b"test-secret-test-secret-test-secret-0123456789"):
    h = _b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    p = _b64(json.dumps({"sub": sub, "role": "authenticated", "email": email, "aud": "authenticated", "exp": int(time.time()) + 86400}).encode())
    return h + '.' + p + '.' + _b64(hmac.new(secret, (h + '.' + p).encode(), hashlib.sha256).digest())
JWT = _jwt("00000000-0000-4000-a000-000000000001", "casaro@test.it")
RUN = time.strftime('%H%M%S'); MA = 'MH' + RUN; MB = 'MI' + RUN; LC = 'LH' + RUN

def sql(q):
    r = subprocess.run(['su', 'postgres', '-c', f'psql -At -d restore_drill -c "{q}"'], capture_output=True, text=True)
    return r.stdout.strip() or r.stderr.strip()

TODAY = sql("select ((now() at time zone 'Europe/Rome')::date)::text")
sup = sql("select id from fabula.parties where is_milk_supplier and active order by created_at limit 1")
moz = sql("select id from fabula.products where sku = 'MOZ-DOP-KG'")
NOPRE = sql(f"insert into fabula.products (sku, name, kind, unit, is_dop, shelf_life_days, active, track_stock) values ('H{RUN}', 'Scamorza e2e121 {RUN}', 'finished_good', 'kg', false, 10, true, true) returning id").split('\n')[0]
for lot, kg in ((MA, 300), (MB, 300)):
    sql(f"insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source) values ('{TODAY}', '07:00', '{sup}', '{lot}', {kg}, true, 4, 'tablet')")
sql("update fabula.haccp_control_points set active = true where code = 'CCP-PAST-HOLD'")
STAFF = "(select id from fabula.staff where active order by created_at limit 1)"
# a lot started earlier with CCP 2 temperature and CCP 3 recorded, but not the minutes: its close must ask them
sql(f"insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, casaro, source) values ('{TODAY}', '{LC}', '{NOPRE}', 200, 'milk', now() - interval '3 hours', 'Test', 'tablet')")
sql(f"select fabula.log_ccp(p_cp_code => 'CCP-PAST', p_value => 64, p_batch_lot => '{LC}', p_staff_id => {STAFF})")
sql(f"select fabula.log_ccp(p_cp_code => 'CCP-STRETCH', p_value => 62, p_batch_lot => '{LC}', p_staff_id => {STAFF})")

def lot_of(milk): return sql(f"select b.batch_lot from fabula.production_batches b join fabula.batch_milk_inputs i on i.batch_id = b.id join fabula.milk_intake m on m.id = i.milk_intake_id where m.milk_lot = '{milk}' limit 1")
def logs(lot): return sql(f"select string_agg(c.code || '=' || l.measured_value::numeric(10,1) || ':' || l.result, ' ' order by c.code) from fabula.haccp_log l join fabula.haccp_control_points c on c.id = l.control_point_id join fabula.production_batches b on b.id = l.batch_id where b.batch_lot = '{lot}'")
def held(lot): return sql(f"select food_safety_hold from fabula.production_batches where batch_lot = '{lot}'")

srv = subprocess.Popen(['python3', '-m', 'http.server', str(PORT)], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
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
    pg = ctx.new_page(); errs = []
    pg.on('pageerror', lambda e: errs.append('PAGEERROR ' + str(e)))
    pg.goto(f'http://localhost:{PORT}/labels.html')
    pg.evaluate(f"localStorage.clear(); localStorage.setItem('sb-{REF}-auth-token', {json.dumps(json.dumps(sess))}){op_js(sess)}")
    view = lambda: pg.evaluate("(document.querySelector('.view.active')||{}).id")
    toast = lambda: pg.evaluate("document.getElementById('toast').textContent")
    shown = lambda k: pg.evaluate("k => { const e = document.getElementById(k); return !!e && e.style.display !== 'none'; }", k)
    req = lambda k: pg.evaluate("k => { const e = document.getElementById(k); return !!e && e.required; }", k)
    def home():
        pg.goto(f'http://localhost:{PORT}/index.html')
        pg.wait_for_function("document.querySelector('#v-home.active')", timeout=20000); pg.wait_for_timeout(3000)
    def code(c): pg.evaluate("c => { document.getElementById('manual').value = c; document.getElementById('btn-manual').click(); }", c); pg.wait_for_timeout(1800)
    def setf(vals):
        for k, v in vals.items(): pg.evaluate("([k, v]) => { const e = document.getElementById(k); e.value = v; e.dispatchEvent(new Event('input', { bubbles: true })); e.dispatchEvent(new Event('change')); }", [k, str(v)])
    def save(): pg.evaluate("document.getElementById('btn-form-save').click()"); pg.wait_for_timeout(1800)
    def pick(rx): pg.evaluate("rx => { const s = document.getElementById('product'); const o = [...s.options].find(x => new RegExp(rx, 'i').test(x.text)); s.value = o.value; s.dispatchEvent(new Event('change')); }", rx); pg.wait_for_timeout(300)
    dose = lambda: pg.evaluate("({ name: document.getElementById('d-name').textContent, ok: document.getElementById('d-ok').style.display, skip: document.getElementById('d-skip').style.display, alt: document.getElementById('d-alt').style.display, lbl: document.getElementById('d-alt-l').textContent, qty: document.getElementById('d-qty').textContent, instr: document.getElementById('d-instr').textContent })")
    def type_step(v): pg.evaluate("v => { document.getElementById('d-alt-in').value = v; document.getElementById('d-alt-ok').click(); }", str(v)); pg.wait_for_timeout(900)

    # 1 — the mozzarella preset: the minutes are a critical step right after the temperature
    home(); code('LOT:' + MA)
    pick('mozzarella'); setf({'kg': 300})
    if shown('valve'): setf({'valve': '0'})
    check('preset with the minutes step: the start form does not ask them separately', not shown('pasthold') and not req('pasthold'))
    save()
    st = dose()
    check('first critical step: the pasteurisation temperature', view() == 'v-dose' and 'astorizzazione del latte' in st['name'] and st['ok'] == 'none', json.dumps(st, ensure_ascii=False)[:200])
    type_step(64)
    st = dose()
    check('next: «Sosta di pastorizzazione (CCP 2)», a critical point: no «Fatto», no «Salta», the minutes typed, target 30 min',
          st['name'] == 'Sosta di pastorizzazione (CCP 2)' and st['ok'] == 'none' and st['skip'] == 'none' and st['alt'] == 'block'
          and 'Minuti effettivi' in st['lbl'] and 'punto critico' in st['lbl'] and st['qty'] == '30 min' and 'Obiettivo 30 min' in st['instr'],
          json.dumps(st, ensure_ascii=False)[:300])
    pg.screenshot(path='/tmp/v121_step.png')
    type_step(25)
    q = answer_ask(pg, wait=0)                            # the red «È giusto?» before saving
    check('25 minutes: first the red question (out of limit, the lot will be BLOCKED)', 'fuori limite' in q and 'BLOCCATO' in q, q[:300])
    pg.wait_for_timeout(1500)
    card = pg.evaluate("(document.querySelector('.ask') || {}).innerText || ''")
    check('…then, saved, the card says the lot is BLOCKED and what to do (restart the 30 minutes)',
          'NON CONFORMITÀ' in card and 'BLOCCATO' in card and 'ricomincia il conteggio dei 30 minuti' in card, card[:300])
    answer_ask(pg, wait=0)
    check('…and the wizard moves on past the minutes step', view() != 'v-dose' or dose()['name'] != 'Sosta di pastorizzazione (CCP 2)', json.dumps(dose(), ensure_ascii=False)[:200])
    la = lot_of(MA)
    check('the register has the temperature ok and the minutes as a non-conformity; the lot is held',
          logs(la) == 'CCP-PAST=64.0:ok CCP-PAST-HOLD=25.0:non_conformity' and held(la) == 't', la + ' ' + logs(la))
    for _ in range(40):                                   # the rest of the start steps (doses, other process steps)
        if view() != 'v-dose': break
        st = dose()
        if st['ok'] == 'none': type_step(36)
        else: pg.evaluate("document.getElementById('d-ok').click()"); pg.wait_for_timeout(500)

    # 2 — a product with no preset: the start form asks the temperature and the minutes
    home(); code('LOT:' + MB)
    pick('Scamorza e2e121')
    check('no preset: the start form asks the temperature AND the minutes, both required',
          shown('past') and req('past') and shown('pasthold') and req('pasthold')
          and 'Minuti di sosta a ≥ 63 °C (CCP 2), almeno 30' in pg.evaluate("document.getElementById('pasthold').previousElementSibling.textContent"))
    setf({'kg': 300, 'past': 64})
    if shown('valve'): setf({'valve': '0'})
    save()
    check('the minutes left empty: the form does not save', view() == 'v-form' and lot_of(MB) == '', toast()[:200])
    setf({'pasthold': 35}); save(); answer_ask(pg, wait=0)
    for _ in range(20):
        if view() != 'v-dose': break
        pg.evaluate("document.getElementById('d-ok').click()"); pg.wait_for_timeout(500)
    lb = lot_of(MB)
    check('both reach the register with the lot (64 °C ok, 35 min ok); the lot is free',
          lb != '' and 'CCP-PAST=64.0:ok' in logs(lb) and 'CCP-PAST-HOLD=35.0:ok' in logs(lb) and held(lb) == 'f', lb + ' ' + logs(lb))

    # 3 — a lot that reaches its close without the minutes
    home(); code('LOT:' + LC)
    check('close form: the minutes are asked (not recorded yet), the temperature and CCP 3 are not',
          view() == 'v-form' and shown('pastholdv') and req('pastholdv') and not shown('pastv') and not shown('ccpv'), toast()[:200])
    setf({'out': 50, 'pastholdv': 31, 'n': 1})
    if shown('ricyn'): setf({'ricyn': 'no'})
    save(); answer_ask(pg)
    for _ in range(10):
        if view() != 'v-dose': break
        pg.evaluate("document.getElementById('d-ok').click()"); pg.wait_for_timeout(800)
    time.sleep(1)
    check('the minutes are saved with the close and the lot closes free',
          'CCP-PAST-HOLD=31.0:ok' in logs(LC) and held(LC) == 'f' and sql(f"select output_kg from fabula.production_batches where batch_lot = '{LC}'") == '50.000',
          logs(LC) + ' held ' + held(LC))

    # 4 — the paper copy lists the minutes
    home(); code('PAPER:')
    items = pg.evaluate("[...document.querySelectorAll('#form .nitem')].map(b => b.textContent)")
    check('🛡 → Ricopia da foglio di carta lists «⏱ Pastorizzazione: minuti di sosta (MOD-02)»', any('Pastorizzazione: minuti di sosta (MOD-02)' in t for t in items), str(items)[:300])

    # 5 — the control point switched off while the app is open (its kept list still has it): not asked any more, anywhere
    kept = pg.evaluate("!!JSON.parse(localStorage.getItem('perla_ref_v1') || '{}')['cp_CCP-PAST-HOLD']")
    sql("update fabula.haccp_control_points set active = false where code = 'CCP-PAST-HOLD'")
    MC, MD = 'MJ' + RUN, 'MK' + RUN
    for lot in (MC, MD):
        sql(f"insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source) values ('{TODAY}', '07:00', '{sup}', '{lot}', 200, true, 4, 'tablet')")
    pg.evaluate("document.querySelectorAll('.view').forEach(e => e.classList.toggle('active', e.id === 'v-home'))")   # no reload
    code('LOT:' + MC); pick('Scamorza e2e121')
    check('switched off while the app was open: the start form re-reads the control points and asks the temperature only',
          kept and shown('past') and not shown('pasthold') and not req('pasthold')
          and not pg.evaluate("!!JSON.parse(localStorage.getItem('perla_ref_v1') || '{}')['cp_CCP-PAST-HOLD']"))
    setf({'kg': 200, 'past': 74})
    if shown('valve'): setf({'valve': '0'})
    save(); answer_ask(pg, wait=0)
    for _ in range(20):
        if view() != 'v-dose': break
        pg.evaluate("document.getElementById('d-ok').click()"); pg.wait_for_timeout(500)
    lc = lot_of(MC)
    check('…and the vat starts (the save is not refused), with the temperature only', lc != '' and logs(lc) == 'CCP-PAST=74.0:ok', lc + ' ' + logs(lc) + ' · ' + toast()[:150])
    pg.evaluate("document.querySelectorAll('.view').forEach(e => e.classList.toggle('active', e.id === 'v-home'))")
    code('LOT:' + MD); pick('mozzarella'); setf({'kg': 200})
    if shown('valve'): setf({'valve': '0'})
    save()
    names = []
    for _ in range(40):
        if view() != 'v-dose': break
        st = dose(); names.append(st['name'])
        if st['ok'] == 'none': type_step(64 if 'astorizz' in st['name'] else 36)
        else: pg.evaluate("document.getElementById('d-ok').click()"); pg.wait_for_timeout(500)
    ld = lot_of(MD)
    check('…the mozzarella preset no longer has the minutes step (it went off with its control point) and the start completes',
          'Sosta di pastorizzazione (CCP 2)' not in names and any('astorizzazione del latte' in n for n in names) and ld != '' and logs(ld) == 'CCP-PAST=64.0:ok',
          ' / '.join(names)[:300] + ' · ' + ld + ' ' + logs(ld))
    code('PAPER:')
    items = pg.evaluate("[...document.querySelectorAll('#form .nitem')].map(b => b.textContent)")
    check('…and the paper copy no longer lists the minutes', not any('minuti di sosta' in t for t in items), str(items)[:200])
    sql("update fabula.haccp_control_points set active = true where code = 'CCP-PAST-HOLD'")
    check('no page errors', not errs, ' | '.join(errs)[:300])
    b.close()
finally:
    srv.terminate()
print('FAILURES:', fails or 'none')
