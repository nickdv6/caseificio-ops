"""v0.78 offline gaps closed, against the local copy (restore_drill + setup.sql + PostgREST on :3000, a milk supplier):
a batch started offline is also closed offline (both reach the database in order on reconnect, the close finds the batch
by lot number); the day's task list still shows without network (kept from the last load, tasks closed offline hidden);
a direct shipment from a closed lot works offline (product and customers kept on the tablet); a held lot is refused."""
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
RUN = time.strftime('%H%M%S'); LOT = 'OF' + RUN
state = {'off': False}
def sql(q):
    r = subprocess.run(['su', 'postgres', '-c', f'psql -At -d restore_drill -c "{q}"'], capture_output=True, text=True)
    return r.stdout.strip() or r.stderr.strip()

sup = sql("select id from fabula.parties where is_milk_supplier and active order by created_at limit 1")
sql(f"insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source) values ((now() at time zone 'Europe/Rome')::date, '07:00', '{sup}', '{LOT}', 400, true, 4, 'tablet')")
sql("insert into fabula.parties (type, legal_name, active) select 'customer', 'Pizzeria Prova Offline', true where not exists (select 1 from fabula.parties where legal_name = 'Pizzeria Prova Offline')")
srv = subprocess.Popen(['python3', '-m', 'http.server', '8771'], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1)
sess = {"access_token": JWT, "refresh_token": "r", "expires_at": int(time.time()) + 86400, "expires_in": 86400, "token_type": "bearer",
        "user": {"id": "00000000-0000-4000-a000-000000000001", "email": "casaro@test.it", "aud": "authenticated", "role": "authenticated"}}
def handler(route):
    url = route.request.url
    if state['off']: return route.abort('internetdisconnected')
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
    ctx.add_init_script("window.__off=false;Object.defineProperty(Navigator.prototype,'onLine',{get:()=>!window.__off})")
    pg = ctx.new_page(); logs = []
    pg.on('pageerror', lambda e: logs.append('PAGEERROR ' + str(e)))
    pg.goto('http://localhost:8771/labels.html')
    pg.evaluate(f"localStorage.clear(); localStorage.setItem('sb-{REF}-auth-token', {json.dumps(json.dumps(sess))})")
    pg.goto('http://localhost:8771/index.html')
    pg.wait_for_function("document.querySelector('#v-home.active')", timeout=20000); pg.wait_for_timeout(4000)
    view = lambda: pg.evaluate("(document.querySelector('.view.active')||{}).id")
    toast = lambda: pg.evaluate("document.getElementById('toast').textContent")
    def code(c): pg.evaluate("c => { document.getElementById('manual').value = c; document.getElementById('btn-manual').click(); }", c); pg.wait_for_timeout(1500)
    def setf(vals):
        for k, v in vals.items(): pg.evaluate("([k, v]) => { const e = document.getElementById(k); e.value = v; e.dispatchEvent(new Event('change')); e.dispatchEvent(new Event('input')); }", [k, str(v)])
    def save_form(): pg.evaluate("document.getElementById('btn-form-save').click()"); pg.wait_for_timeout(1500)
    def dose_through(n=0):
        while view() == 'v-dose' and n < 40: pg.evaluate("document.getElementById('d-ok').click()"); pg.wait_for_timeout(450); n += 1
        return n
    def go_off(): state['off'] = True; pg.evaluate("window.__off=true; dispatchEvent(new Event('offline'))")
    def go_on(): state['off'] = False; pg.evaluate("window.__off=false; dispatchEvent(new Event('online'))"); pg.wait_for_timeout(5000)
    queued = lambda: pg.evaluate("JSON.parse(localStorage.getItem('fabula_queue')||'[]').length")
    rej0 = sql("select count(*) from fabula.tablet_rejects")

    # 0 — v0.79: two cold-room checks today; doing the morning one offline must leave the evening one on the list
    sql("insert into fabula.task_instances (schedule_id, due_at, status) select id, ((now() at time zone 'Europe/Rome')::date + time '09:00') at time zone 'Europe/Rome', 'due'::fabula.task_status from fabula.task_schedules where code = 'T-CF1' union all select id, ((now() at time zone 'Europe/Rome')::date + time '17:00') at time zone 'Europe/Rome', 'due'::fabula.task_status from fabula.task_schedules where code = 'T-CF1'")
    pg.goto('http://localhost:8771/index.html'); pg.wait_for_function("document.querySelector('#v-home.active')", timeout=20000); pg.wait_for_timeout(3000)
    n_cf1 = lambda: pg.evaluate("[...document.querySelectorAll('#tasks .task')].filter(d => d.innerText.includes('cella 1')).length")
    before = n_cf1()
    go_off()
    code('CCP:CCP-COLD-1'); setf({'v': 3}); save_form()
    pg.evaluate("(() => document.querySelectorAll('.view').forEach(e => e.classList.toggle('active', e.id === 'v-home')))()")
    after = n_cf1()
    check('offline: one cold-room check done → only that one hidden, the other stays', before >= 2 and after == before - 1, f'{before} → {after}')
    go_on()

    # 1 — start and close a batch with no network
    go_off()
    code('LOT:' + LOT)
    if view() == 'v-form' and pg.evaluate("!!document.getElementById('kg')"):
        setf({'kg': 400}); save_form()
        if view() == 'v-form' and 'Salva di nuovo' in toast(): save_form()
        dose_through()
    blot = pg.evaluate("(JSON.parse(localStorage.getItem('fabula_queue')||'[]').flatMap(i => i.ops||[]).find(o => o.table === 'production_batches' && !o.update) || {row:{}}).row.batch_lot || ''")
    check('offline: batch start queued with its lot number', blot != '' and queued() >= 1, f'{blot} · queue {queued()}')
    pg.evaluate("(() => document.querySelectorAll('.view').forEach(e => e.classList.toggle('active', e.id === 'v-home')))()")
    code('LOT:' + blot); dose_through()
    if view() != 'v-form' or not pg.evaluate("!!document.getElementById('out')"): code('LOT:' + blot); dose_through()
    check('offline: the same batch opens the close form (no "si chiude quando torna la rete")', view() == 'v-form' and pg.evaluate("!!document.getElementById('out')"), toast())
    setf({'out': 120, 'n': 1})
    if pg.evaluate("!!document.getElementById('whey')"): setf({'whey': 0})
    save_form()
    if view() == 'v-form' and 'Salva di nuovo' in toast(): save_form()
    dose_through()
    check('offline: close queued behind the start, nothing in the database yet', queued() >= 2 and sql(f"select count(*) from fabula.production_batches where batch_lot = '{blot}'") == '0', f'queue {queued()}')
    tasks_off = pg.evaluate("document.getElementById('tasks').innerText")
    check('offline: the task list still shows (kept from the last load)', 'Senza rete: elenco delle' in tasks_off and 'non disponibile' not in tasks_off, tasks_off[:120].replace('\n', ' | '))
    go_on()
    row = sql(f"select b.output_kg || '|' || (b.finished_at is not null)::text || '|' || (select count(*) from fabula.stock_moves s where s.batch_id = b.id and s.move_type = 'production_out') from fabula.production_batches b where b.batch_lot = '{blot}'")
    check('back online: batch started and closed in order, stock linked to the batch', row == '120.000|true|1', row)
    check('back online: queue empty, nothing refused', queued() == 0 and sql("select count(*) from fabula.tablet_rejects") == rej0, f"queue {queued()} · rejects {rej0} → {sql('select count(*) from fabula.tablet_rejects')}")

    # 2 — direct shipment from the closed lot, offline
    pg.goto('http://localhost:8771/index.html'); pg.wait_for_function("document.querySelector('#v-home.active')", timeout=20000); pg.wait_for_timeout(4000)   # warms customers and lots
    go_off()
    code('LOT:' + blot)
    opts = pg.evaluate("document.getElementById('cust') ? [...document.getElementById('cust').options].map(o => o.text) : []")
    check('offline: direct shipment opens with the customers kept on the tablet', view() == 'v-form' and 'Pizzeria Prova Offline' in opts, toast() + ' | ' + str(len(opts)))
    cid = sql("select id from fabula.parties where legal_name = 'Pizzeria Prova Offline'")
    if pg.evaluate("!!document.getElementById('cust')"):
        setf({'kg': 10, 'cust': cid}); save_form()
    go_on()
    check('back online: shipment, line and stock move in the database', sql(f"select count(*) from fabula.shipment_lines where lot_number = '{blot}' and qty = 10") == '1'
          and sql(f"select -sum(qty) from fabula.stock_moves where lot_number = '{blot}' and move_type = 'sale'") == '10.000')

    # 3 — a held lot is refused on the tablet, also offline
    sql(f"update fabula.production_batches set food_safety_hold = true, hold_reason = 'prova', hold_at = now() where batch_lot = '{blot}'")
    pg.goto('http://localhost:8771/index.html'); pg.wait_for_function("document.querySelector('#v-home.active')", timeout=20000); pg.wait_for_timeout(4000)
    go_off(); code('LOT:' + blot)
    check('offline: a held lot cannot be shipped', 'BLOCCATO' in toast() and view() != 'v-form', toast())
    go_on()
    check('no page errors', not logs, ' | '.join(logs)[:300])
    b.close()
finally:
    srv.terminate()
print('FAILURES:', fails or 'none')
