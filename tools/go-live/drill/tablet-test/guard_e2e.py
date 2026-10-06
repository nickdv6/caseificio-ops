"""v0.80 production guard rails on the tablet, against the local copy (restore_drill + setup.sql + PostgREST on :3000, a milk
supplier; run it last: it clears today's pasteuriser checks in the local copy so the first-batch question shows).
The day's pasteuriser check is asked at the first batch start (NON ok = no batch, recorded as a non-conformity); a CCP step
(pasteurisation, stretching) asks for the measured value — no one-tap "Fatto · target", no skip; a batch with no CCP 3
recorded asks for it at close; a fully recorded batch closes with no alert from Zio Ciro."""
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
RUN = time.strftime('%H%M%S'); LOT = 'GM' + RUN
def sql(q):
    r = subprocess.run(['su', 'postgres', '-c', f'psql -At -d restore_drill -c "{q}"'], capture_output=True, text=True)
    return r.stdout.strip() or r.stderr.strip()
# local test database only: move today's pasteuriser checks left by other suites to yesterday, so the first-batch question shows
sql("update fabula.haccp_log set logged_at = logged_at - interval '1 day' where control_point_id = (select id from fabula.haccp_control_points where code = 'PRP-PAST-VALVE') and logged_at >= (now() at time zone 'Europe/Rome')::date::timestamp at time zone 'Europe/Rome'")
sup = sql("select id from fabula.parties where is_milk_supplier and active order by created_at limit 1")
moz = sql("select id from fabula.products where sku = 'MOZ-DOP-KG'")
sql(f"insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source) values ((now() at time zone 'Europe/Rome')::date, '07:00', '{sup}', '{LOT}', 500, true, 4, 'tablet')")
srv = subprocess.Popen(['python3', '-m', 'http.server', '8772'], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1)
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
try:
  with sync_playwright() as p:
    b = p.chromium.launch(); ctx = b.new_context(service_workers='block', viewport={'width': 800, 'height': 1280})
    ctx.route('**/*.supabase.co/**', handler)
    pg = ctx.new_page(); logs = []
    pg.on('pageerror', lambda e: logs.append('PAGEERROR ' + str(e)))
    pg.goto('http://localhost:8772/labels.html')
    pg.evaluate(f"localStorage.clear(); localStorage.setItem('sb-{REF}-auth-token', {json.dumps(json.dumps(sess))})")
    pg.goto('http://localhost:8772/index.html')
    pg.wait_for_function("document.querySelector('#v-home.active')", timeout=20000); pg.wait_for_timeout(3000)
    view = lambda: pg.evaluate("(document.querySelector('.view.active')||{}).id")
    toast = lambda: pg.evaluate("document.getElementById('toast').textContent")
    has = lambda i: pg.evaluate(f"!!document.getElementById('{i}') && document.getElementById('{i}').style.display !== 'none'")
    def code(c): pg.evaluate("c => { document.getElementById('manual').value = c; document.getElementById('btn-manual').click(); }", c); pg.wait_for_timeout(1800)
    def setf(vals):
        for k, v in vals.items(): pg.evaluate("([k, v]) => { const e = document.getElementById(k); e.value = v; e.dispatchEvent(new Event('change')); e.dispatchEvent(new Event('input')); }", [k, str(v)])
    def save_form(): pg.evaluate("document.getElementById('btn-form-save').click()"); pg.wait_for_timeout(1800)
    def home(): pg.evaluate("(() => document.querySelectorAll('.view').forEach(e => e.classList.toggle('active', e.id === 'v-home')))()")
    def dose_state(): return pg.evaluate("({ name: document.getElementById('d-name').textContent, ok: document.getElementById('d-ok').style.display, skip: document.getElementById('d-skip').style.display, alt: document.getElementById('d-alt').style.display, lbl: document.getElementById('d-alt-l').textContent })")
    def through(ccp_values, limit=40):
        seen = []
        for _ in range(limit):
            if view() != 'v-dose': break
            st = dose_state()
            if st['ok'] == 'none':
                seen.append(st)
                v = ccp_values.get('stretch' if 'filata' in st['name'].lower() else 'past' if 'astorizz' in st['name'].lower() else 'other', 70)
                pg.evaluate("v => { document.getElementById('d-alt-in').value = v; document.getElementById('d-alt-ok').click(); }", str(v))
            else:
                pg.evaluate("document.getElementById('d-ok').click()")
            pg.wait_for_timeout(500)
        return seen

    # 1 — first batch of the day: pasteuriser check asked; NON ok stops the batch
    VALVE = "select count(*) from fabula.haccp_log l join fabula.haccp_control_points cp on cp.id = l.control_point_id where cp.code = 'PRP-PAST-VALVE' and l.result {} 'ok'"
    ko0, ok0 = int(sql(VALVE.format('<>'))), int(sql(VALVE.format('=')))
    code('LOT:' + LOT)
    check('first batch of the day: start form asks the pasteuriser check', view() == 'v-form' and has('valve'), toast())
    pg.evaluate("(() => { const s = document.getElementById('product'); const o = [...s.options].find(x => /mozzarella/i.test(x.text)); s.value = o.value; s.dispatchEvent(new Event('change')); })()")
    setf({'kg': 250, 'valve': '1'}); pg.wait_for_timeout(1500)
    check('NON ok: batch not started, recorded as a non-conformity',
          'NON ok' in toast() and sql(f"select count(*) from fabula.batch_milk_inputs i join fabula.milk_intake m on m.id = i.milk_intake_id where m.milk_lot = '{LOT}'") == '0'
          and int(sql(VALVE.format('<>'))) == ko0 + 1, toast())
    home(); code('LOT:' + LOT)
    check('after a NON ok the check is asked again', view() == 'v-form' and has('valve'))
    pick = lambda rx: pg.evaluate("rx => { const s = document.getElementById('product'); const o = [...s.options].find(x => new RegExp(rx, 'i').test(x.text)); s.value = o.value; s.dispatchEvent(new Event('change')); }", rx)
    pick('ricotta')
    check('preset without a pasteurisation step: CCP 2 asked in the form', has('past'), pg.evaluate("document.getElementById('preset').selectedOptions[0].text"))
    pick('mozzarella')
    check('preset with a pasteurisation step: no separate CCP 2 field', not has('past'), pg.evaluate("document.getElementById('preset').selectedOptions[0].text"))
    setf({'kg': 250, 'valve': '0'}); save_form()
    st = dose_state()
    check('pasteurisation step (CCP 2) asks for the measured value: no one-tap, no skip', view() == 'v-dose' and 'astorizz' in st['name'] and st['ok'] == 'none' and st['skip'] == 'none' and st['alt'] == 'block', json.dumps(st, ensure_ascii=False))
    seen = through({'past': 72.5})
    check('start steps done, pasteurisation logged with the value typed (72.5, not the target)',
          sql(f"select l.measured_value from fabula.haccp_log l join fabula.haccp_control_points cp on cp.id = l.control_point_id join fabula.production_batches b on b.id = l.batch_id join fabula.batch_milk_inputs i on i.batch_id = b.id join fabula.milk_intake m on m.id = i.milk_intake_id where cp.code = 'CCP-PAST' and m.milk_lot = '{LOT}'") == '72.50')
    lot1 = sql(f"select b.batch_lot from fabula.production_batches b join fabula.batch_milk_inputs i on i.batch_id = b.id join fabula.milk_intake m on m.id = i.milk_intake_id where m.milk_lot = '{LOT}' limit 1")
    check('the pasteuriser check is now recorded as ok', int(sql(VALVE.format('='))) == ok0 + 1)

    # 2 — working steps: the stretching step (CCP 3) cannot be skipped or one-tapped
    home(); code('LOT:' + lot1)
    stretch_seen = []
    for _ in range(40):
        if view() != 'v-dose': break
        st = dose_state()
        if 'filata' in st['name'].lower() and 'CCP' in st['name']:
            stretch_seen.append(st)
            pg.evaluate("document.getElementById('d-skip').click()"); pg.wait_for_timeout(400)
            skipped_toast = toast()
            pg.evaluate("v => { document.getElementById('d-alt-in').value = v; document.getElementById('d-alt-ok').click(); }", '64'); pg.wait_for_timeout(500)
        elif st['ok'] == 'none':
            pg.evaluate("v => { document.getElementById('d-alt-in').value = v; document.getElementById('d-alt-ok').click(); }", '5.2'); pg.wait_for_timeout(500)
        else:
            pg.evaluate("document.getElementById('d-ok').click()"); pg.wait_for_timeout(500)
    check('stretching step (CCP 3): no one-tap, no skip ("non si salta")', len(stretch_seen) == 1 and stretch_seen[0]['ok'] == 'none' and 'non si salta' in skipped_toast, json.dumps(stretch_seen, ensure_ascii=False)[:200])
    check('stretching logged at 64 °C for the lot', sql(f"select l.measured_value from fabula.haccp_log l join fabula.haccp_control_points cp on cp.id = l.control_point_id join fabula.production_batches b on b.id = l.batch_id where cp.code = 'CCP-STRETCH' and b.batch_lot = '{lot1}'") == '64.00')
    if view() != 'v-form': home(); code('LOT:' + lot1)
    check('close form: CCP 3 already recorded, not asked again', view() == 'v-form' and has('out') and not has('ccpv'), toast())
    setf({'out': 75, 'n': 1})
    if has('whey'): setf({'whey': 0})
    save_form()
    if view() == 'v-form' and 'Salva di nuovo' in toast(): save_form()
    for _ in range(10):
        if view() != 'v-dose': break
        pg.evaluate("document.getElementById('d-ok').click()"); pg.wait_for_timeout(450)
    time.sleep(1)
    check('fully recorded batch closed: no CCP alert from Zio Ciro', sql(f"select output_kg from fabula.production_batches where batch_lot = '{lot1}'") == '75.000'
          and sql(f"select count(*) from fabula.bot_messages where agent = 'produzione' and title like 'Lotto {lot1} chiuso senza%'") == '0')

    # 3 — a batch whose CCP 3 is missing: asked at close, saved with the close
    lot2 = 'LQ' + RUN
    sql(f"insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, casaro, source) values ((now() at time zone 'Europe/Rome')::date, '{lot2}', '{moz}', 200, 'milk', now(), 'Test', 'tablet')")
    sql(f"select fabula.log_ccp(p_cp_code => 'CCP-PAST', p_value => 72, p_batch_lot => '{lot2}', p_staff_id => (select id from fabula.staff where active order by created_at limit 1))")
    # its working steps were done on an old app that let the stretching step be skipped (step marked done, no value)
    sql(f"update fabula.production_batches set preset_id = (select id from fabula.process_presets where name like 'Base · prova%') where batch_lot = '{lot2}'")
    sql(f"insert into fabula.batch_step_logs (batch_id, step_id, step_name, source) select b.id, s.id, s.name_it, 'tablet' from fabula.production_batches b join fabula.process_steps s on s.preset_id = b.preset_id and s.phase = 'make' where b.batch_lot = '{lot2}'")
    pg.goto('http://localhost:8772/index.html'); pg.wait_for_function("document.querySelector('#v-home.active')", timeout=20000); pg.wait_for_timeout(3000)
    code('LOT:' + lot2)
    check('batch without CCP 3: the close form asks for it', view() == 'v-form' and has('ccpv'), toast())
    setf({'out': 60, 'ccpv': 66, 'n': 1})
    if has('whey'): setf({'whey': 0})
    save_form()
    if view() == 'v-form' and 'Salva di nuovo' in toast(): save_form()
    for _ in range(10):
        if view() != 'v-dose': break
        pg.evaluate("document.getElementById('d-ok').click()"); pg.wait_for_timeout(450)
    time.sleep(1)
    check('saved with the close: CCP 3 = 66 °C on the lot, no alert',
          sql(f"select l.measured_value from fabula.haccp_log l join fabula.haccp_control_points cp on cp.id = l.control_point_id join fabula.production_batches b on b.id = l.batch_id where cp.code = 'CCP-STRETCH' and b.batch_lot = '{lot2}'") == '66.00'
          and sql(f"select count(*) from fabula.bot_messages where agent = 'produzione' and title like 'Lotto {lot2} chiuso senza%'") == '0')
    check('no page errors', not logs, ' | '.join(logs)[:300])
    b.close()
finally:
    srv.terminate()
print('FAILURES:', fails or 'none')
