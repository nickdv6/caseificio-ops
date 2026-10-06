"""v0.71 packing on autopilot on the tablet, against the local copy (restore_drill + setup.sql + PostgREST on :3000).
Stock: A expires tomorrow 5 kg, B in 4 days 8 kg, C on food-safety hold 10 kg, X expired 3 kg. Orders: S1 online due
yesterday 5 kg, W1 wholesale today 6 kg, W2 wholesale tomorrow 4 kg. Checks: Da spedire shows the pick list and the
orders in packing order with lots and flags; W1 opens with two rows already filled (A 5 + B 1); scanning the held lot is
refused on the spot; W1 and S1 save at once; W2 (2 kg short) asks to confirm with the reason, then saves."""
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
R = time.strftime('%H%M%S')

def sql(q):
    r = subprocess.run(['su', 'postgres', '-c', f'psql -At -d restore_drill -c "{q}"'], capture_output=True, text=True)
    return r.stdout.strip() or r.stderr.strip()

D = "(now() at time zone 'Europe/Rome')::date"
MOZ = sql("select id from fabula.products where sku = 'MOZ-DOP-KG'")
CUST = sql(f"insert into fabula.parties (type, legal_name) values ('customer', 'Pizzeria {R}') returning id").splitlines()[0]
sql(f"insert into fabula.stock_moves (product_id, lot_number, expiry_date, qty, move_type, source) values ('{MOZ}', 'A{R}', {D} + 1, 5, 'production_out', 'test'), ('{MOZ}', 'B{R}', {D} + 4, 8, 'production_out', 'test'), ('{MOZ}', 'C{R}', {D} + 5, 10, 'production_out', 'test'), ('{MOZ}', 'X{R}', {D} - 1, 3, 'production_out', 'test')")
sql(f"insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, output_kg, food_safety_hold, hold_reason, source) values ({D}, 'C{R}', '{MOZ}', 30, 10, true, 'esito laboratorio in attesa', 'test')")
sql(f"insert into fabula.sales_orders (order_number, channel, order_date, customer_id, status, source) values ('S1-{R}', 'shopify', {D} - 1, null, 'confirmed', 'test'), ('W1-{R}', 'wholesale', {D}, '{CUST}', 'confirmed', 'test'), ('W2-{R}', 'wholesale', {D} + 1, '{CUST}', 'confirmed', 'test')")
sql(f"insert into fabula.sales_order_lines (sales_order_id, product_id, qty, unit_price_eur, iva_rate) select id, '{MOZ}', case when order_number like 'S1%' then 5 when order_number like 'W1%' then 6 else 4 end, 12, 4 from fabula.sales_orders where order_number like '%-{R}'")

srv = subprocess.Popen(['python3', '-m', 'http.server', '8768'], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1)
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
    b = p.chromium.launch(); ctx = b.new_context(service_workers='block', viewport={'width': 800, 'height': 1600})
    ctx.route('**/*.supabase.co/**', handler)
    pg = ctx.new_page(); logs = []
    pg.on('pageerror', lambda e: logs.append('PAGEERROR ' + str(e)))
    pg.goto('http://localhost:8768/labels.html')
    pg.evaluate(f"localStorage.clear(); localStorage.setItem('sb-{REF}-auth-token', {json.dumps(json.dumps(sess))})")
    pg.goto('http://localhost:8768/index.html')
    pg.wait_for_function("document.querySelector('#v-home.active')", timeout=20000); pg.wait_for_timeout(2500)
    view = lambda: pg.evaluate("(document.querySelector('.view.active')||{}).id")
    toast = lambda: pg.evaluate("document.getElementById('toast').textContent")
    form_txt = lambda: pg.evaluate("document.getElementById('form').innerText")
    def open_list():
        pg.evaluate("document.getElementById('btn-ship').click()"); pg.wait_for_timeout(2000)
    def open_order(num):
        pg.evaluate(f"[...document.querySelectorAll('#form .task')].find(d => d.innerText.includes('{num}')).click()"); pg.wait_for_timeout(2000)
    def save(): pg.evaluate("document.getElementById('btn-form-save').click()"); pg.wait_for_timeout(1800)
    def done_home():
        pg.evaluate("[...document.querySelectorAll('#form button')].find(x => x.textContent === 'Fatto').click()"); pg.wait_for_timeout(1500)

    open_list(); t = form_txt()
    mine = pg.evaluate(f"[...document.querySelectorAll('#form .task')].map(d => d.innerText).filter(x => x.includes('{R}'))")
    check('Da spedire: pick list for the cold room with A 5 kg and B 8 kg', 'Prelievo dalla cella' in t and f'A{R}' in t and f'B{R}' in t, t[:260].replace('\n', ' | '))
    check('orders in packing order: late online S1, then W1, then W2', [m.split(' · ')[0][2:].strip() for m in mine] == [f'S1-{R}', f'W1-{R}', f'W2-{R}'], ' || '.join(m.split('\n')[0] for m in mine))
    check('flags: S1 late, W2 short', 'in ritardo di 1 g' in mine[0] and 'mancano 2 kg' in mine[2], mine[0].replace('\n', ' ') + ' || ' + mine[2].replace('\n', ' '))
    pg.screenshot(path='/tmp/pack_list.png')

    open_order(f'W1-{R}')
    f = pg.evaluate("[...document.querySelectorAll('#form select[id^=lot]')].map((s, i) => s.value + '=' + document.getElementById('q' + s.id.slice(3)).value)")
    check('W1 opens with two rows already filled: A 5 + B 1', f == [f'A{R}=5', f'B{R}=1'], str(f))
    check('the card lists the lots not to use (held C, expired X)', f'C{R} · bloccato' in form_txt() and f'X{R} · scaduto' in form_txt(), form_txt()[:300].replace('\n', ' | '))
    pg.screenshot(path='/tmp/pack_w1.png')
    # scan the held lot on the first row: refused, row unchanged
    pg.evaluate(f"""(() => {{ const btn = [...document.querySelectorAll('#form button')].find(x => x.textContent.includes('Scansiona lotto')); btn.click(); }})()"""); pg.wait_for_timeout(800)
    pg.evaluate(f"c => {{ document.getElementById('manual').value = c; document.getElementById('btn-manual').click(); }}", f'LOT:C{R}'); pg.wait_for_timeout(1200)
    check('scanning the held lot is refused on the spot', 'bloccato per sicurezza alimentare' in toast() and pg.evaluate("document.querySelector('#form select[id^=lot]').value") == f'A{R}', toast())
    if view() != 'v-form': pg.evaluate("document.querySelectorAll('.view').forEach(e => e.classList.toggle('active', e.id === 'v-form'))")
    save()
    check('W1 saved at once: DDT, stock moved, order fulfilled', 'DDT-' in form_txt() and sql(f"select status from fabula.sales_orders where order_number = 'W1-{R}'") == 'fulfilled', form_txt()[:160].replace('\n', ' | '))
    done_home()

    open_list(); open_order(f'S1-{R}')
    f = pg.evaluate("[...document.querySelectorAll('#form select[id^=lot]')].map(s => s.value + '=' + document.getElementById('q' + s.id.slice(3)).value)")
    check('S1 online opens on B (A expires too soon for online)', f == [f'B{R}=5'], str(f)); save()
    check('S1 saved; guest order got a consignee', 'DDT-' in form_txt() and sql(f"select p.legal_name from fabula.sales_orders o join fabula.parties p on p.id = o.customer_id where o.order_number = 'S1-{R}'") == f'Cliente online S1-{R}', form_txt()[:120].replace('\n', ' | '))
    done_home()

    open_list(); open_order(f'W2-{R}')
    f = pg.evaluate("[...document.querySelectorAll('#form select[id^=lot]')].map(s => s.value + '=' + document.getElementById('q' + s.id.slice(3)).value)")
    check('W2 opens with what is left: B 2 (2 kg short shown)', f == [f'B{R}=2'] and 'mancano 2 kg' in form_txt(), str(f)); save()
    check('W2: weight off asks to confirm with the reason', view() == 'v-form' and 'Da confermare: pesati 2.00 kg contro 4.00 ordinati' in toast(), toast())
    save()
    check('second Salva saves and shows what was confirmed', 'DDT-' in form_txt() and 'Confermato:' in form_txt(), form_txt()[:200].replace('\n', ' | '))
    check('stock after packing: A 0, B 0, C and X untouched',
          sql(f"select string_agg(lot_number || '=' || trim_scale(qty_on_hand), ',' order by lot_number) from fabula.v_stock_on_hand where lot_number like '%{R}'") == f'C{R}=10,X{R}=3')
    # v0.79: a split line where the packer takes everything from the first lot and sets the second row to 0
    sql(f"insert into fabula.stock_moves (product_id, lot_number, expiry_date, qty, move_type, source) values ('{MOZ}', 'D{R}', {D} + 4, 3, 'production_out', 'test'), ('{MOZ}', 'E{R}', {D} + 5, 3, 'production_out', 'test')")
    sql(f"insert into fabula.sales_orders (order_number, channel, order_date, customer_id, status, source) values ('W3-{R}', 'wholesale', {D} + 1, '{CUST}', 'confirmed', 'test')")
    sql(f"insert into fabula.sales_order_lines (sales_order_id, product_id, qty, unit_price_eur, iva_rate) select id, '{MOZ}', 4, 12, 4 from fabula.sales_orders where order_number = 'W3-{R}'")
    open_list(); open_order(f'W3-{R}')
    f = pg.evaluate("[...document.querySelectorAll('#form select[id^=lot]')].map(s => s.value + '=' + document.getElementById('q' + s.id.slice(3)).value)")
    check('W3 opens split: D 3 + E 1', f == [f'D{R}=3', f'E{R}=1'], str(f))
    pg.evaluate("(() => { const s = [...document.querySelectorAll('#form select[id^=lot]')][1]; const q = document.getElementById('q' + s.id.slice(3)); q.value = '0'; q.dispatchEvent(new Event('input')); })()")
    save()
    if view() == 'v-form' and 'Quantità non valida' not in toast(): save()
    check('second row set to 0: saved with one line (no "Quantità non valida")', 'DDT-' in form_txt()
          and sql(f"select string_agg(l.lot_number || '=' || trim_scale(l.qty), ',') from fabula.shipment_lines l join fabula.shipments sh on sh.id = l.shipment_id join fabula.sales_orders o on o.id = sh.sales_order_id where o.order_number = 'W3-{R}'") == f'D{R}=3', toast())
    check('no page errors', not logs, ' | '.join(logs)[:300])
    b.close()
finally:
    srv.terminate()
print('FAILURES:', fails or 'none')
