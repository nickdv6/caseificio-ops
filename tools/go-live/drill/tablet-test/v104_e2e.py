"""v1.04 on the tablet, against the local copy (restore_drill + setup.sql + PostgREST on :3000, v104a–c applied). Port 8783.
- D-22 packing: 50 kg weighed for 5 ordered → a red card «Non si spedisce così» that stays until read, the order not shipped; weighed
       right it ships with a DDT number of the yearly series (DDT-<year>-NNNN).
- D-22 / PRINT-04 the direct shipment from a lot: the toast carries the database's DDT number, the next of the series.
- D-17 «Ricopia da foglio di carta»: the same sheet line copied twice → the second is refused with «già nel registro».
- D-31 the display check of cold room 1 («CAL:CF-01») does not tick «Temperatura cella 1».
Expect "FAILURES: none"."""
import json, subprocess, time, os, hmac, hashlib, base64
from playwright.sync_api import sync_playwright
from e2e_op import op_js, answer_ask
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../../../fabula-tablet'))
REF = 'ojkquhzaeypsphncjqwy'; PORT = 8783
def _b64(b): return base64.urlsafe_b64encode(b).rstrip(b'=').decode()
def _jwt(sub, email, secret=b"test-secret-test-secret-test-secret-0123456789"):
    h = _b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    p = _b64(json.dumps({"sub": sub, "role": "authenticated", "email": email, "aud": "authenticated", "exp": int(time.time()) + 86400}).encode())
    return h + '.' + p + '.' + _b64(hmac.new(secret, (h + '.' + p).encode(), hashlib.sha256).digest())
JWT = _jwt("00000000-0000-4000-a000-000000000001", "casaro@test.it")
R = time.strftime('%H%M%S')
def sql(q):
    r = subprocess.run(['su', 'postgres', '-c', f'psql -At -d restore_drill -c "{q}"'], capture_output=True, text=True)
    if 'ERROR' in r.stderr: print('SQL ERROR:', q[:90], '→', r.stderr.strip()[:300])
    return r.stdout.strip() or r.stderr.strip()
def sql1(q): return (sql(q).splitlines() or [''])[0]
D = "(now() at time zone 'Europe/Rome')::date"
YEAR = sql1(f"select extract(year from {D})::int")
MOZ = sql1("select id from fabula.products where sku = 'MOZ-DOP-KG'")
CUST = sql1(f"insert into fabula.parties (type, legal_name) values ('customer', 'Trattoria {R}') returning id")
sql(f"insert into fabula.stock_moves (product_id, lot_number, expiry_date, qty, move_type, source) values ('{MOZ}', 'P{R}', {D} + 5, 60, 'production_out', 'test')")
sql(f"insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, output_kg, finished_at, source) values ({D}, 'P{R}', '{MOZ}', 300, 'milk', now() - interval '6 hours', 60, now() - interval '2 hours', 'test')")
sql(f"insert into fabula.sales_orders (order_number, channel, order_date, customer_id, status, source) values ('WX-{R}', 'wholesale', {D}, '{CUST}', 'confirmed', 'test')")
sql(f"insert into fabula.sales_order_lines (sales_order_id, product_id, qty, unit_price_eur, iva_rate) select id, '{MOZ}', 5, 12, 4 from fabula.sales_orders where order_number = 'WX-{R}'")
sql(f"select fabula.generate_daily_tasks({D})")
PDAY, PTIME = sql1("select to_char((now() - interval '1 hour') at time zone 'Europe/Rome', 'YYYY-MM-DD|HH24:MI')").split('|')
srv = subprocess.Popen(['python3', '-m', 'http.server', str(PORT)], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1)
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
    b = p.chromium.launch(); ctx = b.new_context(service_workers='block', viewport={'width': 800, 'height': 1600}, locale='it-IT')
    ctx.route('**/*.supabase.co/**', handler)
    pg = ctx.new_page(); logs = []
    pg.on('pageerror', lambda e: logs.append('PAGEERROR ' + str(e)))
    pg.goto(f'http://localhost:{PORT}/labels.html')
    pg.evaluate(f"localStorage.clear(); localStorage.setItem('sb-{REF}-auth-token', {json.dumps(json.dumps(sess))}){op_js(sess)}")
    pg.goto(f'http://localhost:{PORT}/index.html')
    pg.wait_for_function("document.querySelector('#v-home.active')", timeout=20000); pg.wait_for_timeout(2500)
    toast = lambda: pg.evaluate("document.getElementById('toast').textContent")
    form_txt = lambda: pg.evaluate("document.getElementById('form').innerText")
    ask_txt = lambda: pg.evaluate("(document.querySelector('.ask') || {}).innerText || ''")
    def save(): pg.evaluate("document.getElementById('btn-form-save').click()"); pg.wait_for_timeout(1800)
    def scan(code):
        pg.evaluate("document.querySelectorAll('.view').forEach(e => e.classList.toggle('active', e.id === 'v-home'))")
        pg.evaluate("c => { document.getElementById('manual').value = c; document.getElementById('btn-manual').click(); }", code); pg.wait_for_timeout(2200)
    def setv(sel, v): pg.evaluate("([s, v]) => { const e = document.querySelector(s); e.value = v; e.dispatchEvent(new Event('input')); e.dispatchEvent(new Event('change')); }", [sel, v])

    # ================= D-22 packing: 50 kg for 5 =================
    pg.evaluate("document.getElementById('btn-ship').click()"); pg.wait_for_timeout(2000)
    pg.evaluate(f"[...document.querySelectorAll('#form .task')].find(d => d.innerText.includes('WX-{R}')).click()"); pg.wait_for_timeout(2000)
    check('D-22 the pack form says the limit («oltre +30% non si spedisce»)', 'oltre +30% non si spedisce' in pg.evaluate("document.getElementById('f-sub').textContent"), pg.evaluate("document.getElementById('f-sub').textContent"))
    setv('#form input[id^=q]', '50'); save(); pg.wait_for_timeout(500)
    a = ask_txt()
    check('D-22 50 kg weighed for 5: a red card «Non si spedisce così» with the reason, not a toast', 'Non si spedisce così' in a and 'pesati 50 kg contro 5 ordinati (+900 %)' in a
          and pg.evaluate("!!document.querySelector('.ask.danger')"), a.replace('\n', ' | ')[:300])
    answer_ask(pg, wait=0)
    check('D-22 …after «Correggo» the form is still there and nothing was shipped', 'peso effettivo' in form_txt().lower()
          and sql1(f"select count(*) from fabula.shipments s join fabula.sales_orders o on o.id = s.sales_order_id where o.order_number = 'WX-{R}'") == '0')
    setv('#form input[id^=q]', '5,02'); save()
    ddt1 = sql1(f"select s.ddt_number from fabula.shipments s join fabula.sales_orders o on o.id = s.sales_order_id where o.order_number = 'WX-{R}'")
    check('D-22 weighed right: shipped with a number of the yearly series', ddt1.startswith(f'DDT-{YEAR}-') and len(ddt1) >= 13 and ddt1 in form_txt(), ddt1 + ' / ' + form_txt()[:120].replace('\n', ' | '))
    pg.evaluate("[...document.querySelectorAll('#form button')].find(x => x.textContent === 'Fatto').click()"); pg.wait_for_timeout(1500)

    # ================= D-22 / PRINT-04 direct shipment from a lot =================
    scan(f'LOT:P{R}')
    check('D-22 the lot opens the direct shipment form', 'Spedizione diretta' in form_txt(), form_txt()[:120].replace('\n', ' | '))
    setv('#kg', '2')
    pg.evaluate(f"(() => {{ const s = document.getElementById('cust'); s.value = '{CUST}'; s.dispatchEvent(new Event('change')); }})()")
    save()
    ddt2 = sql1(f"select s.ddt_number from fabula.shipments s where s.customer_id = '{CUST}' and s.sales_order_id is null")
    n1 = int(ddt1.rsplit('-', 1)[1]) if '-' in ddt1 else -1
    check('D-22 the toast carries the database\'s number, the next of the series (no more «-<4 digits of the clock>»)',
          ddt2 == f'DDT-{YEAR}-{n1 + 1:04d}' and ddt2 in toast(), ddt2 + ' / ' + toast())

    # ================= D-17 a sheet line copied twice =================
    def paper_line():
        scan('PAPER:CCP-COLD-1'); pg.wait_for_timeout(500)
        setv('#pday', PDAY); setv('#ptime', PTIME)   # the sheet: an hour ago (Rome), so never in the future
        pg.evaluate("(() => { const s = document.getElementById('pwho'); s.selectedIndex = 1; s.dispatchEvent(new Event('change')); })()")
        setv('#v', '3,7'); save()
        return toast()
    sql("delete from fabula.haccp_log h using fabula.haccp_control_points c where c.id = h.control_point_id and c.code = 'CCP-COLD-1' and h.measured_value = 3.7")
    t1 = paper_line()
    check('D-17 the sheet line is copied', 'Ricopiato' in t1, t1)
    t2 = paper_line()
    check('D-17 …the same line again is refused: «già nel registro … già ricopiata»', 'già nel registro' in t2 and 'già ricopiata' in t2, t2)
    check('D-17 …one row in the register', sql1("select count(*) from fabula.haccp_log h join fabula.haccp_control_points c on c.id = h.control_point_id where c.code = 'CCP-COLD-1' and h.measured_value = 3.7") == '1')

    # ================= D-31 cold room display check =================
    done0 = sql1(f"select count(*) from fabula.task_instances ti join fabula.task_schedules s on s.id = ti.schedule_id where s.code = 'T-CF1' and ti.status = 'done' and (ti.due_at at time zone 'Europe/Rome')::date = {D}")
    sql("update fabula.equipment set out_of_service = false where code = 'CF-01'")
    scan('CAL:CF-01'); pg.wait_for_timeout(500)
    check('D-31 «CAL:CF-01» opens the display check of the cold room', 'display della cella' in form_txt().lower(), form_txt()[:120].replace('\n', ' | '))
    setv('#ref', '3,0'); setv('#read', '3,4')
    save()
    done1 = sql1(f"select count(*) from fabula.task_instances ti join fabula.task_schedules s on s.id = ti.schedule_id where s.code = 'T-CF1' and ti.status = 'done' and (ti.due_at at time zone 'Europe/Rome')::date = {D}")
    check('D-31 the display check is saved and «Temperatura cella 1» is not ticked', 'CF-01' in toast() and done1 == done0, toast() + ' / ' + done0 + ' → ' + done1)
    check('no page errors', not logs, ' | '.join(logs)[:300])
    b.close()
finally:
    srv.terminate()
print('FAILURES:', fails or 'none')
