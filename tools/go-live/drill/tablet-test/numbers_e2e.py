"""v0.98 audit numbers and limits in the browser, against the local copy (restore_drill + setup.sql + PostgREST on :3000, v098a–c applied).
The browser runs in Italian (locale it-IT), as the tablets do.
- A-13  numbers are read the Italian way: «4,5» is saved as 4.5 and repeated under the box («= 4,5 °C»); «1.200» is refused (1,2 or
        1200?) and so is a value outside what is possible for the field (450 °C), with the reason, before anything is saved.
- D-06  a vat of 3100 kg (vat 800 kg) is refused on the tablet. Closing 62 kg from 31 kg of milk (200 %): «impossibile», the milk kg
        are corrected with a reason in the same save (lot, milk input and correction record); a yield under the minimum needs what
        was lost (yield_note).
- D-19  dosing 10 times the recipe is a red question; confirmed, it is saved with the lot of the pack, which the next vat shows again.
- D-18  goods receipt: a DDT price 100 times the list asks first, then saves.
- B-14  Console → Ricette: the dose is shown per vat while typing; Enter does not save; ×10 asks with old → new per vat and a reason.
- C-02/C-03  Configurazione: range and unit on the row, a value out of range is refused, a high-impact setting asks first and posts to
        the bell; the manual status is a list.
- FARM-07  farm page: 6,5 °C warns «entro 2 ore», 9 °C warns «RESPINGERE» and asks before shipping.
- D-23  Ingrosso → Listino: «1150» for a price is refused, «11,90» is saved as 11.9.
Expect "FAILURES: none"."""
import json, subprocess, time, os, hmac, hashlib, base64, uuid
from playwright.sync_api import sync_playwright
from e2e_op import op_js, answer_ask

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../../../fabula-tablet'))
REF = 'ojkquhzaeypsphncjqwy'; PORT = 8778
def _b64(b): return base64.urlsafe_b64encode(b).rstrip(b'=').decode()
def _jwt(sub, email, secret=b"test-secret-test-secret-test-secret-0123456789"):
    h = _b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    p = _b64(json.dumps({"sub": sub, "role": "authenticated", "email": email, "aud": "authenticated", "exp": int(time.time()) + 86400}).encode())
    return h + '.' + p + '.' + _b64(hmac.new(secret, (h + '.' + p).encode(), hashlib.sha256).digest())
def _jwt_role(role, secret=b"test-secret-test-secret-test-secret-0123456789"):
    h = _b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode()); p = _b64(json.dumps({"role": role, "exp": int(time.time()) + 3600}).encode())
    return h + '.' + p + '.' + _b64(hmac.new(secret, (h + '.' + p).encode(), hashlib.sha256).digest())
def sql(q):
    r = subprocess.run(['su', 'postgres', '-c', f'psql -At -d restore_drill -c "{q}"'], capture_output=True, text=True)
    return r.stdout.strip() or r.stderr.strip()
def sql1(q): return (sql(q).splitlines() or [''])[0]
def rpc(fn, args):
    import urllib.request, urllib.error
    req = urllib.request.Request('http://127.0.0.1:3000/rpc/' + fn, data=json.dumps(args).encode(),
                                 headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + _jwt_role('service_role'), 'Content-Profile': 'fabula', 'Accept-Profile': 'fabula'})
    try:
        with urllib.request.urlopen(req) as r: return 200, json.loads(r.read() or 'null')
    except urllib.error.HTTPError as e: return e.code, json.loads(e.read() or '{}')

RUN = time.strftime('%H%M%S'); CAS_ID = '10000000-0000-4000-a000-000000000001'
CASARO = ("00000000-0000-4000-a000-000000000001", "casaro@test.it")
OWNER = ("00000000-0000-4000-a000-0000000000b1", "owner@test.it")
sql(f"insert into auth.users(id, email) values ('{OWNER[0]}', '{OWNER[1]}') on conflict do nothing")
sql(f"insert into fabula.staff(id, full_name, auth_user_id, app_role, role, active) values ('10000000-0000-4000-a000-0000000000b1', 'Owner E2E', '{OWNER[0]}', 'titolare', 'owner', true) on conflict do nothing")
TODAY = sql1("select (now() at time zone 'Europe/Rome')::date")
sup = sql1("select id from fabula.parties where is_milk_supplier and active order by created_at limit 1")
sql("update fabula.milk_shipments set status = 'cancelled', cancel_reason = 'reset numbers_e2e', cancelled_at = now() where status = 'shipped'")
sql("update fabula.settings set value = '800' where key = 'prod.vat_kg'")
VAT = 800
MILK = 'MN' + RUN                                                   # a big delivery: room for the vat-size test and three vats
sql(f"insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source) values ('{TODAY}', (now() at time zone 'Europe/Rome')::time, '{sup}', '{MILK}', 5000, true, 4, 'tablet')")
sql(f"insert into fabula.labels (kind, code, lot_number, milk_intake_id) select 'milk_lot', 'LOT:{MILK}', '{MILK}', id from fabula.milk_intake where milk_lot = '{MILK}'")
NOPRE = sql1(f"insert into fabula.products (sku, name, kind, unit, is_dop, shelf_life_days, active, track_stock) values ('NUM{RUN}', 'Prova numeri {RUN}', 'finished_good', 'kg', false, 5, true, true) returning id")
moz = sql1("select id from fabula.products where sku = 'MOZ-DOP-KG'")
rennet = sql1("select id from fabula.products where sku = 'CON-RENNET'")
# a purchase order on its way: rennet 10 l at 4,10 €/l
SUPP = sql1(f"insert into fabula.parties (type, legal_name, active) values ('supplier', 'Fornitore numeri {RUN}', true) returning id")
PO = 'PO-N' + RUN
POID = sql1(f"insert into fabula.purchase_orders (po_number, supplier_id, status) values ('{PO}', '{SUPP}', 'sent') returning id")
sql(f"insert into fabula.purchase_order_lines (purchase_order_id, product_id, qty_ordered, unit_price_eur, iva_rate) values ('{POID}', '{rennet}', 10, 4.10, 22)")
sql(f"insert into fabula.supplier_prices (supplier_id, product_id, price_eur, valid_from, source) values ('{SUPP}', '{rennet}', 4.10, current_date - 30, 'listino')")
TOKEN = sql1("select value from fabula.settings where key = 'milk.farm_token'")
if not TOKEN:
    TOKEN = 'abcdef0123456789abcdef01234567' + RUN[:2]; sql(f"update fabula.settings set value = '{TOKEN}' where key = 'milk.farm_token'")
TP = 'gid://numbers/' + RUN
sql(f"insert into fabula.trade_products (variant_id, product_id, title, variant_title, kg_per_unit, unit_label, base_price_eur, trade_price_eur, min_qty, step_qty) values ('{TP}', '{moz}', 'Mozzarella numeri', '{RUN}', 1, 'kg', 14, 11.5, 1, 1)")

srv = subprocess.Popen(['python3', '-m', 'http.server', str(PORT)], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1)
fails = []
def check(name, cond, info=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f'  [{info}]' if info else ''))
    if not cond: fails.append(name)

def farm_fn(route):                                    # emulates supabase/functions/farm-order (GET, ship)
    r = route.request; H = {'access-control-allow-origin': '*', 'content-type': 'application/json'}
    if r.method == 'OPTIONS': return route.fulfill(status=200, headers=H, body='ok')
    if r.method == 'GET':
        code, d = rpc('farm_milk_orders', {'p_token': r.url.split('t=')[1].split('&')[0]})
        return route.fulfill(status=200 if d else 403, headers=H, body=json.dumps(d or {'error': 'link non valido'}))
    b = json.loads(r.post_data or '{}'); shipped.append(b)
    code, d = rpc('farm_milk_ship', {'p_token': b['t'], 'p_kg': float(b['kg']), 'p_temp': b.get('temp'), 'p_ddt': b.get('ddt'), 'p_note': b.get('note'), 'p_confirm': True})
    ok = code == 200 and d
    return route.fulfill(status=200 if ok else 400, headers=H, body=json.dumps({'ok': True, 'shipment': d} if ok else {'error': str(d)}))
shipped = []

def page_as(b, who, path, logs, width=1100):
    s = {"access_token": _jwt(*who), "refresh_token": "r", "expires_at": int(time.time()) + 86400, "expires_in": 86400, "token_type": "bearer",
         "user": {"id": who[0], "email": who[1], "aud": "authenticated", "role": "authenticated"}}
    def handler(route):
        u = route.request.url
        if '/functions/v1/farm-order' in u: return farm_fn(route)
        if '/rest/v1/' in u: return route.fulfill(response=route.fetch(url='http://127.0.0.1:3000/' + u.split('/rest/v1/', 1)[1]))
        if '/auth/v1/' in u: return route.fulfill(status=200, content_type='application/json', body=json.dumps(s['user']), headers={'access-control-allow-origin': '*'})
        return route.fulfill(status=200, body='{}', headers={'access-control-allow-origin': '*'})
    ctx = b.new_context(service_workers='block', viewport={'width': width, 'height': 1300}, locale='it-IT'); ctx.route('**/*.supabase.co/**', handler)
    pg = ctx.new_page(); pg.on('pageerror', lambda e: logs.append('PAGEERROR ' + str(e)))
    pg.goto(f'http://localhost:{PORT}/labels.html')
    pg.evaluate(f"localStorage.clear(); localStorage.setItem('sb-{REF}-auth-token', {json.dumps(json.dumps(s))}){op_js(s)}")
    pg.goto(f'http://localhost:{PORT}/{path}')
    return ctx, pg

def ask_input(pg, text, wait=300):
    """a question with a text box (yield reason, milk kg): types the answer and presses the first button"""
    pg.wait_for_timeout(wait)
    txt = pg.evaluate("(document.querySelector('.ask') || {}).innerText || ''")
    if txt:
        pg.fill('#ask-in', str(text)); pg.wait_for_timeout(1600)
        pg.evaluate("document.querySelector('.ask button').click()"); pg.wait_for_timeout(1200)
    return txt

try:
  with sync_playwright() as p:
    b = p.chromium.launch(); logs = []
    # ================= tablet =================
    ctx, pg = page_as(b, CASARO, 'index.html', logs, 800)
    pg.wait_for_function("document.querySelector('#v-home.active')", timeout=20000); pg.wait_for_timeout(4000)
    view = lambda: pg.evaluate("(document.querySelector('.view.active')||{}).id")
    toast = lambda: pg.evaluate("document.getElementById('toast').textContent")
    title = lambda: pg.evaluate("document.getElementById('f-title').textContent")
    form_txt = lambda: pg.evaluate("document.getElementById('form').innerText")
    echo = lambda i: pg.evaluate("i => (document.getElementById('echo-' + i) || {}).textContent || ''", i)
    def code(c): pg.evaluate("c => { document.getElementById('manual').value = c; document.getElementById('btn-manual').click(); }", c); pg.wait_for_timeout(1800)
    def setf(vals):
        for k, v in vals.items(): pg.evaluate("([k, v]) => { const e = document.getElementById(k); if (!e) return; e.value = v; e.dispatchEvent(new Event('change')); e.dispatchEvent(new Event('input')); }", [k, str(v)])
    def typef(k, v):                                      # real typing: what a person does (a field the form does not have is skipped)
        if not pg.evaluate("k => !!document.getElementById(k) && document.getElementById(k).offsetParent !== null", k): return
        pg.fill('#' + k, ''); pg.type('#' + k, str(v)); pg.wait_for_timeout(150)
    def save(): pg.evaluate("document.getElementById('btn-form-save').click()"); pg.wait_for_timeout(900)
    def done_btn():
        pg.evaluate("(() => { const b = [...document.querySelectorAll('#form button')].find(x => x.textContent === 'Fatto'); if (b) b.click(); })()"); pg.wait_for_timeout(1500)
    def home(): pg.evaluate("document.querySelectorAll('.view').forEach(e => e.classList.toggle('active', e.id === 'v-home'))"); pg.wait_for_timeout(300)

    # ---- A-13 Italian numbers on a cold room ----
    CF1 = "select count(*) from fabula.haccp_log l join fabula.haccp_control_points c on c.id = l.control_point_id where c.code = 'CCP-COLD-1'"
    n0 = int(sql1(CF1))
    code('EQ:CF-01'); typef('temp', '450'); save()
    check('A-13 450 °C in a cold room is refused before saving, with the reason (comma)', view() == 'v-form' and int(sql1(CF1)) == n0
          and '450 °C non è possibile' in toast() and 'Controlla la virgola' in toast(), toast())
    check('A-13 …the box turns red and says it under the field', 'non è possibile' in echo('temp') and pg.evaluate("document.getElementById('temp').classList.contains('bad')"), echo('temp'))
    typef('temp', '1.200'); save()
    check('A-13 «1.200» is refused: 1,2 or 1200?', view() == 'v-form' and int(sql1(CF1)) == n0 and 'senza punto' in echo('temp') and '1,200 con la virgola' in echo('temp'), echo('temp'))
    typef('temp', '3,5')
    check('A-13 «3,5» is read 3,5 and repeated under the box', echo('temp') == '= 3,5 °C', echo('temp'))
    save(); pg.wait_for_timeout(1200)
    check('A-13 …and saved as 3.5 (it-IT browser)', sql1("select l.measured_value from fabula.haccp_log l join fabula.haccp_control_points c on c.id = l.control_point_id where c.code = 'CCP-COLD-1' order by l.created_at desc limit 1") == '3.50', toast())
    home()

    # ---- D-06 vat size at the start ----
    code('LOT:' + MILK)
    check('D-06 scanning the milk opens the batch start', 'Inizio lotto' in title(), title())
    setf({'product': NOPRE}); setf({'valve': '0'}); typef('kg', '3100'); typef('past', '72,5'); typef('pasthold', '30'); save()
    check('D-06 3100 kg in one vat (vat 800 kg) is refused on the tablet before anything is saved', view() == 'v-form'
          and 'una caldaia ne tiene al massimo 880 kg' in toast() and sql1(f"select count(*) from fabula.production_batches where product_id = '{NOPRE}'") == '0', toast())
    typef('kg', '31'); save(); pg.wait_for_timeout(1500)
    L1 = sql1(f"select batch_lot from fabula.production_batches where product_id = '{NOPRE}' order by created_at desc limit 1")
    check('D-06 a start with 31 kg (the typo) goes through: it is a possible vat', L1 != '' and sql1(f"select milk_in_kg from fabula.production_batches where batch_lot = '{L1}'") == '31.000', L1)
    home()

    # ---- D-06 closing at 200 %: the milk is corrected with a reason, in the same save ----
    code('LOT:' + L1)
    check('D-06 scanning the lot opens its close', 'Fine lotto' in title(), title())
    typef('out', '62'); typef('ccpv', '61'); save()
    q1 = answer_ask(pg, wait=0)
    check('D-06 62 kg from 31 kg: «Resa 200 %: impossibile» with both numbers', 'Resa 200 %: impossibile' in q1 and '31 kg di latte' in q1 and 'al 45 %' in q1, q1.replace('\n', ' | '))
    q2 = ask_input(pg, '310')
    check('D-06 …«Correggo i kg di latte» asks for the right kg', 'Kg di latte del lotto' in q2 and 'sono stati scritti 31 kg' in q2, q2.replace('\n', ' | '))
    q3 = ask_input(pg, 'scritto 31 invece di 310')
    check('D-06 …then the reason, with old → new', 'Motivo della correzione' in q3 and '31 → 310 kg' in q3, q3.replace('\n', ' | '))
    q4 = answer_ask(pg, wait=0); pg.wait_for_timeout(1500)       # 20 % against an expected 30 %: «Controlla i kg»
    row = sql1(f"select milk_in_kg || '|' || output_kg || '|' || coalesce(notes, '') from fabula.production_batches where batch_lot = '{L1}'")
    check('D-06 …saved together: the lot has 310 kg of milk and 62 kg made, with the correction in its notes',
          row.startswith('310.000|62.000|') and 'latte in caldaia corretto da Test Casaro: 31 → 310 kg (scritto 31 invece di 310)' in row, row + ' || ' + q4.replace('\n', ' | '))
    check('D-06 …the milk input and the correction record follow',
          sql1(f"select qty_kg from fabula.batch_milk_inputs i join fabula.production_batches b on b.id = i.batch_id where b.batch_lot = '{L1}'") == '310.000'
          and sql1(f"select changes::text from fabula.record_corrections r join fabula.production_batches b on b.id = r.row_id where b.batch_lot = '{L1}'") == '{"milk_in_kg": [31.000, 310]}',
          sql1(f"select changes::text from fabula.record_corrections r join fabula.production_batches b on b.id = r.row_id where b.batch_lot = '{L1}'"))
    check('D-06 …and the closed card says it', '✓ Lotto' in title() and 'chiuso' in title(), title())
    done_btn()

    # ---- D-06 a yield under the minimum needs what was lost ----
    code('LOT:' + MILK); setf({'product': NOPRE}); typef('kg', '300'); typef('past', '72'); typef('pasthold', '30'); save(); pg.wait_for_timeout(1500)
    L2 = sql1(f"select batch_lot from fabula.production_batches where product_id = '{NOPRE}' order by created_at desc limit 1")
    home(); code('LOT:' + L2); typef('out', '15'); typef('ccpv', '61'); save()
    q5 = ask_input(pg, 'metà cagliata persa: caldaia fredda', wait=0); pg.wait_for_timeout(1500)
    check('D-06 15 kg from 300 kg (5 %): «troppo bassa», asks what happened', 'Resa 5 %: troppo bassa' in q5 and 'di solito almeno il 10 %' in q5, q5.replace('\n', ' | '))
    check('D-06 …saved with the reason (no second «Controlla i kg» question)', sql1(f"select output_kg || '|' || coalesce(yield_note, '') from fabula.production_batches where batch_lot = '{L2}'") == '15.000|metà cagliata persa: caldaia fredda',
          sql1(f"select output_kg || '|' || coalesce(yield_note, '') from fabula.production_batches where batch_lot = '{L2}'"))
    done_btn()

    # ---- D-19 dosing: 10 times the rennet is a red question; the pack lot is kept ----
    code('LOT:' + MILK); setf({'product': moz}); pg.wait_for_timeout(500); typef('kg', '300'); save(); pg.wait_for_timeout(1500)
    L3 = sql1(f"select batch_lot from fabula.production_batches where product_id = '{moz}' order by created_at desc limit 1")
    seen_red = ''; pack_shown = ''
    for _ in range(25):
        if view() != 'v-dose': break
        name = pg.evaluate("document.getElementById('d-name').textContent")
        ccp = pg.evaluate("document.getElementById('d-ok').style.display === 'none'")
        if ccp:
            pg.fill('#d-alt-in', '72'); pg.wait_for_timeout(800); pg.evaluate("document.getElementById('d-alt-ok').click()"); answer_ask(pg, wait=400)
        elif 'Caglio' in name:
            pack_shown = pg.evaluate("document.getElementById('d-pack').style.display")
            pg.wait_for_timeout(800); pg.evaluate("document.getElementById('d-diff').click()"); pg.wait_for_timeout(300)
            pg.fill('#d-lot', 'cg-2611'); pg.fill('#d-alt-in', '750'); pg.wait_for_timeout(200)
            alt_echo = pg.evaluate("document.getElementById('d-alt-echo').textContent")
            pg.evaluate("document.getElementById('d-alt-ok').click()"); pg.wait_for_timeout(300)
            seen_red = pg.evaluate("(document.querySelector('.ask.danger') || {}).innerText || ''")
            answer_ask(pg, wait=0)
        else:
            pg.wait_for_timeout(800); pg.evaluate("document.getElementById('d-ok').click()")
        pg.wait_for_timeout(900)
    check('D-19 the rennet step shows the pack-lot box', pack_shown == '', pack_shown)
    check('D-19 750 ml of rennet where the recipe says 75 ml: a red «Controlla la virgola»', 'Controlla la virgola' in seen_red and '750 ml' in seen_red and '75 ml' in seen_red, seen_red.replace('\n', ' | '))
    dose = sql1(f"select c.qty || '|' || coalesce(c.lot_number, '') from fabula.batch_consumables c join fabula.production_batches b on b.id = c.batch_id where b.batch_lot = '{L3}' and c.product_id = '{rennet}'")
    check('D-19 …confirmed, it is saved (0,75 l) with the pack lot in capitals', dose == '0.750|CG-2611', dose)
    home()
    pg.evaluate("localStorage.getItem('perla_pack_lots_v1')")
    kept = pg.evaluate("(JSON.parse(localStorage.getItem('perla_pack_lots_v1') || '{}')['CON-RENNET'] || {}).lot || ''")
    check('D-19 the tablet keeps the pack in use for the next vat of the day', kept == 'CG-2611', kept)

    # ---- D-18 goods receipt: a price 100 times the list asks first ----
    code('PO:' + PO); typef('q0', '10'); typef('pr0', '410'); setf({'chk': '1'}); save()
    q6 = pg.evaluate("(document.querySelector('.ask.danger') || {}).innerText || ''")
    check('D-18 a DDT price of 410 €/l (list 4,10) is a red question before anything is saved', 'Prezzo molto diverso dal listino' in q6 and '410 €/l sul DDT, listino 4,1 €' in q6
          and sql1(f"select count(*) from fabula.goods_receipts where purchase_order_id = '{POID}'") == '0', q6.replace('\n', ' | '))
    answer_ask(pg, yes=False, wait=0)
    typef('pr0', '4,30'); save(); pg.wait_for_timeout(1500)
    check('D-18 …corrected to 4,30 it is received and the new price recorded', sql1(f"select status from fabula.purchase_orders where id = '{POID}'") == 'received'
          and sql1(f"select price_eur = 4.3 from fabula.supplier_prices where supplier_id = '{SUPP}' and source = 'ddt'") == 't', sql1(f"select status from fabula.purchase_orders where id = '{POID}'"))
    ctx.close()

    # ================= console: recipes =================
    ctx2, cp = page_as(b, OWNER, 'console.html#ricette', logs)
    cp.wait_for_timeout(5000)
    dialogs = []
    def on_dialog(d):
        dialogs.append(d.type + ': ' + d.message)
        if d.type == 'prompt': d.accept('caglio nuovo, più debole')
        else: d.accept()
    cp.on('dialog', on_dialog)
    rid = sql1(f"select r.id from fabula.recipes r where r.finished_product_id = '{moz}' and r.component_product_id = '{rennet}' and r.valid_to is null")
    tr = "[...document.querySelectorAll('#recipes tr')].find(t => t.textContent.includes('CON-RENNET') && t.closest('.card').querySelector('h3').textContent.includes('MOZ-DOP-KG'))"
    pv = cp.evaluate(f"(() => {{ const t = {tr}; return t ? t.querySelector('td.num .small').textContent : ''; }})()")
    check('B-14 the rennet dose is shown per vat («= 200 ml per una caldaia da 800 kg di latte»)', pv == '= 200 ml per una caldaia da 800 kg di latte', pv)
    cp.evaluate(f"(() => {{ const t = {tr}; const i = t.querySelector('td.num input'); i.focus(); i.value = '0,0025'; i.dispatchEvent(new Event('input', {{ bubbles: true }})); }})()")
    pv2 = cp.evaluate(f"(() => {{ const t = {tr}; return t.querySelector('td.num .small').textContent; }})()")
    check('B-14 …live while typing: 0,0025 → «= 2 l per una caldaia»', pv2 == '= 2 l per una caldaia da 800 kg di latte', pv2)
    cp.keyboard.press('Enter'); cp.wait_for_timeout(1200)
    check('B-14 Enter in the dose does not save it', sql1(f"select qty_per_unit from fabula.recipes where id = '{rid}'") == '0.000250' and not dialogs, str(dialogs))
    cp.evaluate(f"(() => {{ const t = {tr}; t.querySelector('button.save').click(); }})()"); cp.wait_for_timeout(2500)
    newq = sql1(f"select qty_per_unit || '|' || replace(coalesce(notes, ''), chr(10), ' / ') from fabula.recipes where finished_product_id = '{moz}' and component_product_id = '{rennet}' and valid_to is null")
    check('B-14 «Salva» on ×10 asks with old → new per vat, then the reason', len(dialogs) == 2 and 'da 0,00025 a 0,0025 l (10 volte di più)' in dialogs[0] and 'Prima: 200 ml' in dialogs[0] and 'Dopo: 2 l' in dialogs[0]
          and dialogs[1].startswith('prompt'), ' || '.join(dialogs))
    check('B-14 …saved with the reason and the old dose in the notes', newq.startswith('0.002500|') and '0,00025 → 0,0025: caglio nuovo, più debole' in newq, newq)
    ctx2.close()

    # ================= Configurazione =================
    ctx3, ap = page_as(b, OWNER, 'admin.html#produzione', logs)
    ap.wait_for_timeout(5000)
    adlg = []
    ap.on('dialog', lambda d: (adlg.append(d.message), d.accept()))
    vrow = "document.querySelector('.set-row[data-key=\"prod.vat_kg\"]')"
    rtxt = ap.evaluate(f"{vrow}.innerText")
    check('C-02 the vat row shows its range and unit', 'possibile da 50 a 3000 kg' in rtxt and ap.evaluate(f"{vrow}.querySelector('.unit').textContent") == 'kg', rtxt.replace('\n', ' | '))
    ap.evaluate(f"(() => {{ const i = {vrow}.querySelector('input'); i.value = '3100'; i.dispatchEvent(new Event('input')); }})()"); ap.wait_for_timeout(300)
    ap.evaluate("document.getElementById('p-go').click()"); ap.wait_for_timeout(1500)
    t = ap.evaluate("document.querySelector('.toast').textContent")
    check('C-02 3100 kg is refused on the page with the range', '3100 kg non è possibile' in t and 'da 50 a 3000 kg' in t and sql1("select value from fabula.settings where key = 'prod.vat_kg'") == '800', t)
    ap.evaluate(f"(() => {{ const i = {vrow}.querySelector('input'); i.value = '900'; i.dispatchEvent(new Event('input')); }})()"); ap.wait_for_timeout(300)
    ap.evaluate("document.getElementById('p-go').click()"); ap.wait_for_timeout(2500)
    check('C-02 900 kg (high impact) asks first, saying what it changes', len(adlg) == 1 and 'cambiano il comportamento per tutti' in adlg[0] and '800 kg → 900 kg' in adlg[0] and 'il tablet non accetta' in adlg[0], ' || '.join(adlg))
    check('C-02 …saved, and the bell has it with who', sql1("select value from fabula.settings where key = 'prod.vat_kg'") == '900'
          and sql1("select count(*) from fabula.bot_messages where agent = 'configurazione' and body like 'Owner E2E ha cambiato «Latte per lotto (kg)»: 800 kg → 900 kg%'") == '1')
    ap.goto(f'http://localhost:{PORT}/admin.html#sicurezza'); ap.wait_for_timeout(4000)
    opts = ap.evaluate("[...document.querySelectorAll('.set-row[data-key=\"food.manuale_stato\"] select option')].map(o => o.textContent).join(',')")
    check('C-03 the manual status is a list (Bozza, Firmato), not free text', opts == 'Bozza,Firmato', opts)
    sql("update fabula.settings set value = '800' where key = 'prod.vat_kg'")
    ctx3.close()

    # ================= Ingrosso: listino =================
    ctx4, ip = page_as(b, OWNER, 'ingrosso.html#listino', logs)
    ip.wait_for_timeout(5000)
    ip.evaluate("(() => { const b = [...document.querySelectorAll('nav a, .tabs a, [data-tab]')].find(x => /listino/i.test(x.textContent)); if (b) b.click(); })()"); ip.wait_for_timeout(2500)
    trow = f"document.querySelector('tr[data-v=\"{TP}\"]')"
    ip.evaluate(f"(() => {{ const i = {trow}.querySelector('[data-f=\"trade_price_eur\"]'); i.value = '1150'; i.dispatchEvent(new Event('input', {{ bubbles: true }})); {trow}.querySelector('button.save').click(); }})()"); ip.wait_for_timeout(1500)
    t2 = ip.evaluate("document.querySelector('.toast').textContent")
    check('D-23 a reserved price of «1150» (meant 11,50) is refused', 'più alto del prezzo base' in t2 and sql1(f"select trade_price_eur from fabula.trade_products where variant_id = '{TP}'") == '11.5', t2)
    ip.evaluate(f"(() => {{ const i = {trow}.querySelector('[data-f=\"trade_price_eur\"]'); i.value = '11,90'; i.dispatchEvent(new Event('input', {{ bubbles: true }})); {trow}.querySelector('button.save').click(); }})()"); ip.wait_for_timeout(1500)
    check('D-23 «11,90» is saved as 11.9', sql1(f"select trade_price_eur from fabula.trade_products where variant_id = '{TP}'") == '11.9', ip.evaluate("document.querySelector('.toast').textContent"))
    ctx4.close()

    # ================= farm page =================
    ctx5, fp = page_as(b, CASARO, f'latte.html?t={TOKEN}', logs, 390)
    fp.wait_for_timeout(3500)
    fdlg = []
    fp.on('dialog', lambda d: (fdlg.append(d.message), d.dismiss()))
    fp.evaluate("document.getElementById('ship-open').click()"); fp.wait_for_timeout(500)
    fp.fill('#temp', '6,5'); fp.wait_for_timeout(200)
    w1 = fp.evaluate("document.getElementById('temp-warn').textContent")
    check('FARM-07 6,5 °C: «entro 2 ore» (alert band of CCP 1a)', 'oltre 6 °C il caseificio deve lavorarlo entro 2 ore' in w1, w1)
    fp.fill('#temp', '9'); fp.wait_for_timeout(200)
    w2 = fp.evaluate("document.getElementById('temp-warn').textContent")
    check('FARM-07 9 °C: «RESPINGERE»', 'Oltre 8 °C il caseificio deve RESPINGERE il latte' in w2, w2)
    fp.fill('#kg', '1050'); fp.evaluate("document.getElementById('ship-go').click()"); fp.wait_for_timeout(800)
    check('FARM-07 shipping at 9 °C asks first (dismissed: nothing sent)', len(fdlg) == 1 and '9 °C' in fdlg[0] and 'respingere' in fdlg[0].lower() and not shipped, ' || '.join(fdlg))
    ctx5.close()

    errs = [l for l in logs if 'PAGEERROR' in l]
    check('no page errors', not errs, ' | '.join(errs[:3]))
finally:
    srv.terminate()
print('FAILURES:', fails or 'none')
