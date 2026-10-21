"""v1.15 «Annulla DDT» in the browser, against the local copy (restore_drill + setup.sql + PostgREST on :3000, v115a applied). Pages on :8795.
- Console → Operazioni → «Spedizioni e DDT» (titolare, on a phone): the DDT just packed, «Annulla DDT» asks the reason, the goods go back,
  the row reads «annullato» with who and why, and the button is gone;
- the DDT page of an annulled DDT says ANNULLATO (banner and watermark), with no «Annulla» button;
- the DDT page of a live DDT: «Annulla questo DDT» for the titolare, not for a production login (Spedizioni = registra); it annuls;
- no page errors. Expect "FAILURES: none"."""
import json, os, subprocess, time, hmac, hashlib, base64
from playwright.sync_api import sync_playwright
from e2e_op import op_js

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '../../../../fabula-tablet'))
REF = 'ojkquhzaeypsphncjqwy'; PORT = 8795
SECRET = b"test-secret-test-secret-test-secret-0123456789"
def _b64(b): return base64.urlsafe_b64encode(b).rstrip(b'=').decode()
def _jwt(sub, email):
    h = _b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    p = _b64(json.dumps({"sub": sub, "role": "authenticated", "email": email, "aud": "authenticated", "exp": int(time.time()) + 86400}).encode())
    return h + '.' + p + '.' + _b64(hmac.new(SECRET, (h + '.' + p).encode(), hashlib.sha256).digest())
def sql(q):
    r = subprocess.run(['su', 'postgres', '-c', f'psql -At -d restore_drill -c "{q}"'], capture_output=True, text=True)
    return r.stdout.strip() or r.stderr.strip()
def session(sub, email):
    return {"access_token": _jwt(sub, email), "refresh_token": "r", "expires_at": int(time.time()) + 86400, "expires_in": 86400, "token_type": "bearer",
            "user": {"id": sub, "email": email, "aud": "authenticated", "role": "authenticated"}}
CASARO = session("00000000-0000-4000-a000-000000000001", "casaro@test.it")
OWNER = session("00000000-0000-4000-a000-000000115e01", "owner115@test.it")
sql("insert into auth.users(id, email) values ('00000000-0000-4000-a000-000000115e01', 'owner115@test.it') on conflict do nothing")
sql("insert into fabula.staff(id, full_name, auth_user_id, app_role, role, active) values ('10000000-0000-4000-a000-000000115e01', 'Owner Annulla', "
    "'00000000-0000-4000-a000-000000115e01', 'titolare', 'owner', true) on conflict (id) do nothing")
RUN = time.strftime('%H%M%S')
CUST = sql(f"insert into fabula.parties (type, legal_name, address, city, piva) values ('customer', 'Trattoria E2E {RUN}', 'Via Roma 1', 'Agropoli', '0{RUN}0000') returning id").split('\n')[0]
MOZ = sql("select id from fabula.products where sku = 'MOZ-DOP-KG'")
sql(f"insert into fabula.stock_moves (product_id, lot_number, expiry_date, qty, move_type, source) values ('{MOZ}', 'E2E-{RUN}', current_date + 7, 30, 'production_out', 'test')")
for k in ('legal_name', 'piva', 'address'):   # the DDT page needs the company data to print (PRINT-03)
    v = {'legal_name': 'Società Agricola Test S.S.', 'piva': '05541290655', 'address': 'Via del Porto 3, 84043 Agropoli (SA)'}[k]
    sql(f"insert into fabula.settings (key, value, data_type) values ('company.{k}', '{v}', 'text') on conflict (key) do update set value = excluded.value")
def order_and_pack(n):
    oid = sql(f"insert into fabula.sales_orders (order_number, channel, order_date, customer_id, status, source) values ('E2E-{RUN}-{n}', 'wholesale', current_date, '{CUST}', 'confirmed', 'test') returning id").split('\n')[0]
    sql(f"insert into fabula.sales_order_lines (sales_order_id, product_id, qty, unit_price_eur, iva_rate) values ('{oid}', '{MOZ}', 4, 12, 4)")
    r = json.loads(sql(f"select fabula.pack_order('{oid}', jsonb_build_array(jsonb_build_object('product_id', '{MOZ}', 'lot_number', 'E2E-{RUN}', 'qty', 4)), null, null, null, null, null, true)"))
    return oid, r['shipment_id'], r['ddt_number']
def lot(): return float(sql(f"select sum(qty) from fabula.stock_moves where lot_number = 'E2E-{RUN}'"))

def handler_for(s):
    def handler(route):
        url = route.request.url
        if '/rest/v1/' in url: return route.fulfill(response=route.fetch(url='http://127.0.0.1:3000/' + url.split('/rest/v1/', 1)[1]))
        if '/auth/v1/' in url: return route.fulfill(status=200, content_type='application/json', body=json.dumps(s['user']), headers={'access-control-allow-origin': '*'})
        return route.fulfill(status=200, body='{}', headers={'access-control-allow-origin': '*'})
    return handler
fails = []
def check(name, cond, info=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f'  [{info}]' if info else ''))
    if not cond: fails.append(name)
def page_as(b, s, path, logs, width=1100, answers=None):
    ctx = b.new_context(service_workers='block', viewport={'width': width, 'height': 1300}, locale='it-IT')
    ctx.route('**/*.supabase.co/**', handler_for(s))
    pg = ctx.new_page(); pg.on('pageerror', lambda e: logs.append('PAGEERROR ' + str(e)))
    asked = []
    def on_dialog(d):
        asked.append(d.message)
        a = answers.pop(0) if answers else None
        d.accept(a) if a is not None else d.dismiss()
    pg.on('dialog', on_dialog)
    pg.goto(f'http://localhost:{PORT}/labels.html')
    pg.evaluate(f"localStorage.clear(); localStorage.setItem('sb-{REF}-auth-token', {json.dumps(json.dumps(s))}){op_js(s)}")
    pg.goto(f'http://localhost:{PORT}/{path}')
    return ctx, pg, asked

srv = subprocess.Popen(['python3', '-m', 'http.server', str(PORT)], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1)
try:
  with sync_playwright() as p:
    b = p.chromium.launch(); logs = []
    o1, sh1, ddt1 = order_and_pack(1)
    check('packed: 4 kg off the lot', lot() == 26, str(lot()))
    # ================= Console → Operazioni → Spedizioni e DDT (titolare, phone) =================
    answers = ['', 'lotto sbagliato, rifare dal tablet']     # first: cancel the prompt (nothing happens); then a reason
    ctx, cp, asked = page_as(b, OWNER, 'console.html#ops', logs, width=420, answers=answers)
    cp.wait_for_selector('#ddt-list table', timeout=25000); cp.wait_for_timeout(800)
    row = cp.evaluate(f"(() => {{ const r = [...document.querySelectorAll('#ddt-list tr')].find(t => t.innerText.includes('{ddt1}')); return r ? r.innerText : ''; }})()")
    check('the register lists the DDT just packed, «preparato», with «Annulla DDT»',
          f'Trattoria E2E {RUN}' in row and 'preparato' in row and 'Annulla DDT' in row, row.replace('\n', ' | '))
    sw = cp.evaluate("document.documentElement.scrollWidth <= window.innerWidth + 1")
    check('on a phone the page does not scroll sideways', sw)
    btn = f"[...document.querySelectorAll('#ddt-list [data-cancel-ddt]')].find(x => x.dataset.cancelDdt === '{sh1}')"
    cp.evaluate(f"{btn}.click()"); cp.wait_for_timeout(1500)
    check('a prompt without a reason annuls nothing', sql(f"select status from fabula.shipments where id = '{sh1}'") == 'picked' and len(asked) == 1, asked[0][:160] if asked else '')
    check('the question says what happens: stock back, the order to ship again, the number kept',
          bool(asked) and 'torna in giacenza' in asked[0] and f'E2E-{RUN}-1 torna in «Da spedire»' in asked[0] and 'resta nel registro come annullato' in asked[0])
    cp.evaluate(f"{btn}.click()"); cp.wait_for_timeout(2500)
    st = sql(f"select status || '|' || cancel_reason from fabula.shipments where id = '{sh1}'")
    check('with a reason the DDT is annulled; the goods are back on the lot; the order is to ship again',
          st == 'cancelled|lotto sbagliato, rifare dal tablet' and lot() == 30 and sql(f"select status from fabula.sales_orders where id = '{o1}'") == 'confirmed', st)
    toast = cp.evaluate("(document.getElementById('toast') || {}).textContent || ''")
    check('the toast says it', f'{ddt1} annullato: 4,0 kg di nuovo in giacenza' in toast and 'di nuovo da spedire' in toast, toast)
    row = cp.evaluate(f"(() => {{ const r = [...document.querySelectorAll('#ddt-list tr')].find(t => t.innerText.includes('{ddt1}')); return r ? r.innerText : ''; }})()")
    check('the row now reads «annullato», who and why, with no button', 'annullato' in row and 'Owner Annulla' in row and 'lotto sbagliato' in row and 'Annulla DDT' not in row, row.replace('\n', ' | '))
    cp.screenshot(path='/tmp/claude-0/v115_console.png', full_page=False)
    # ================= the DDT page of the annulled DDT =================
    ctx2, dp, _ = page_as(b, OWNER, f'spedizione.html?id={sh1}', logs)
    dp.wait_for_selector('#sheet .void', timeout=20000); dp.wait_for_timeout(500)
    v = dp.evaluate("document.querySelector('#sheet .void').innerText")
    check('the DDT page says ANNULLATO, when, by whom and why; red «annullato» badge; watermark on; no «Annulla» button',
          'DDT ANNULLATO' in v and dp.evaluate("document.querySelector('#sheet .badge').textContent") == 'annullato' and 'Owner Annulla' in v and 'lotto sbagliato' in v and dp.evaluate("document.getElementById('sheet').classList.contains('voided')")
          and dp.evaluate("document.getElementById('cancel').hidden"), v)
    dp.screenshot(path='/tmp/claude-0/v115_ddt_void.png', full_page=False)
    # ================= a live DDT page: the button for the titolare, not for production =================
    o2, sh2, ddt2 = order_and_pack(2)
    check('packed again from the tablet side: a new number, the old one not reused', ddt2 > ddt1, f'{ddt1} → {ddt2}')
    ctx3, cz, _ = page_as(b, CASARO, f'spedizione.html?id={sh2}', logs)
    cz.wait_for_selector('#sheet .top', timeout=20000); cz.wait_for_timeout(1500)
    check('a production login sees the DDT but no «Annulla questo DDT»', cz.evaluate("document.getElementById('cancel').hidden"))
    ctx4, op2, asked4 = page_as(b, OWNER, f'spedizione.html?id={sh2}', logs, answers=['cliente sbagliato'])
    op2.wait_for_selector('#sheet .top', timeout=20000); op2.wait_for_timeout(1500)
    check('the titolare sees «Annulla questo DDT»', not op2.evaluate("document.getElementById('cancel').hidden"))
    op2.click('#cancel'); op2.wait_for_selector('#sheet .void', timeout=20000)
    check('…which annuls it and shows it annulled', sql(f"select status from fabula.shipments where id = '{sh2}'") == 'cancelled' and lot() == 30
          and op2.evaluate("document.getElementById('cancel').hidden"))
    # ================= a DDT of another day: no «Annulla» (ingrosso DDTs have no «partito» step) =================
    o3, sh3, ddt3 = order_and_pack(3)
    sql(f"update fabula.shipments set packed_at = packed_at - interval '1 day', created_at = created_at - interval '1 day' where id = '{sh3}'")
    cp.reload(); cp.wait_for_selector('#ddt-list table', timeout=25000); cp.wait_for_timeout(800)
    row3 = cp.evaluate(f"(() => {{ const r = [...document.querySelectorAll('#ddt-list tr')].find(t => t.innerText.includes('{ddt3}')); return r ? r.innerText : ''; }})()")
    check("a DDT packed yesterday shows no «Annulla DDT» (it may have been delivered)", ddt3 in row3 and 'Annulla DDT' not in row3, row3.replace('\n', ' | '))
    ctx5, op3, _ = page_as(b, OWNER, f'spedizione.html?id={sh3}', logs)
    op3.wait_for_selector('#sheet .top', timeout=20000); op3.wait_for_timeout(1500)
    check('…nor on its DDT page', op3.evaluate("document.getElementById('cancel').hidden"))
    check('no page errors', not logs, ' | '.join(logs)[:300])
    b.close()
finally:
    srv.terminate()
print('FAILURES:', fails or 'none')
