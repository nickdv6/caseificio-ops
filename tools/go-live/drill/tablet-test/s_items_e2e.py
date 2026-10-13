"""v0.95 audit backlog (items under an hour, High/Critical) in the browser, against the local copy (restore_drill + setup.sql +
PostgREST on :3000 + a milk supplier, v095a/b applied).
Tablet (casaro): a vat started from milk never offers ricotta, shows the milk still left and refuses more (D-09/A-16); the batch
close asks «Ricotta sì / no» as a required choice and «no» is stored; Home offers «Avvia ricotta» for today's closed lots; Esci is
refused while records are still waiting (A-12).
Farm page: 105 kg against today's order is spelled out in a red box; «1.050» is read as 1050; under 50 kg is refused (FARM-01).
Autocontrollo (owner): no default lab outcome, result required, «Correggi esito» with a reason (B-02); «Prelevato» picks the lot
(B-05); register review dialog with dates up to today, record count and a required tick (B-04); external calibration needs the
certificate and the deviation or the PDF (B-03).
Configurazione: kg per Shopify piece shows grams and refuses 250 (C-28); delivery days are seven boxes, cut-off a time field (C-04).
DDT: incomplete company data → red banner and printing disabled (PRINT-03).
Expect "FAILURES: none"."""
import json, subprocess, time, os, hmac, hashlib, base64
from playwright.sync_api import sync_playwright

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../../../fabula-tablet'))
REF = 'ojkquhzaeypsphncjqwy'; PORT = 8773
def _b64(b): return base64.urlsafe_b64encode(b).rstrip(b'=').decode()
def _jwt(sub, email, secret=b"test-secret-test-secret-test-secret-0123456789"):
    h = _b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    p = _b64(json.dumps({"sub": sub, "role": "authenticated", "email": email, "aud": "authenticated", "exp": int(time.time()) + 86400}).encode())
    return h + '.' + p + '.' + _b64(hmac.new(secret, (h + '.' + p).encode(), hashlib.sha256).digest())
CASARO = ("00000000-0000-4000-a000-000000000001", "casaro@test.it")
OWNER = ("00000000-0000-4000-a000-0000000000b1", "owner@test.it")
RUN = time.strftime('%H%M%S')

def sql(q):
    r = subprocess.run(['su', 'postgres', '-c', f'psql -At -d restore_drill -c "{q}"'], capture_output=True, text=True)
    return r.stdout.strip() or r.stderr.strip()
def sql1(q): return (sql(q).splitlines() or [''])[0]

TODAY = sql1("select (now() at time zone 'Europe/Rome')::date")
sup = sql1("select id from fabula.parties where is_milk_supplier and active order by created_at limit 1")
moz = sql1("select id from fabula.products where sku = 'MOZ-DOP-KG'")
MILK = 'MS95' + RUN
mid = sql1(f"insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source) values ('{TODAY}', '06:30', '{sup}', '{MILK}', 1000, true, 4, 'tablet') returning id")
bA = sql1(f"insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, output_kg, finished_at, source) values ('{TODAY}', 'LS{RUN}-A', '{moz}', 600, 'milk', now() - interval '3 hours', 180, now() - interval '1 hour', 'tablet') returning id")
sql(f"insert into fabula.batch_milk_inputs (batch_id, milk_intake_id, qty_kg) values ('{bA}', '{mid}', 600)")
# an open batch with its working steps done and CCP 3 recorded: scanning it goes straight to the close form
LB = f'LS{RUN}-B'
sql(f"insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, preset_id, source) values ('{TODAY}', '{LB}', '{moz}', 300, 'milk', now() - interval '2 hours', (select id from fabula.process_presets where product_id = '{moz}' order by is_default desc limit 1), 'tablet')")
sql(f"insert into fabula.batch_step_logs (batch_id, step_id, step_name, source) select b.id, s.id, s.name_it, 'tablet' from fabula.production_batches b join fabula.process_steps s on s.preset_id = b.preset_id and s.phase = 'make' where b.batch_lot = '{LB}'")
sql(f"select fabula.log_ccp(p_cp_code => 'CCP-STRETCH', p_value => 64, p_batch_lot => '{LB}', p_staff_id => '10000000-0000-4000-a000-000000000001')")
# farm: today's approved order (a test one if there is none)
ORDER = sql1(f"select milk_kg from fabula.milk_plans where status = 'approved' and plan_date = '{TODAY}' order by milk_kg desc limit 1")
made_plan = not ORDER
if made_plan:
    sql(f"insert into fabula.milk_plans (plan_date, milk_kg, status) values ('{TODAY}', 1050, 'approved')"); ORDER = '1050'
ORDER = int(float(ORDER))
TOKEN = sql1("select value from fabula.settings where key = 'milk.farm_token'")
# lab sample waiting for its result; a Shopify variant to map; a wholesale DDT to print
SC = json.loads(sql1("select fabula.record_sample_taken('MOZ-ENT', null)"))['sample_code']
VAR = f'gid://shopify/ProductVariant/95{RUN}'
sql(f"insert into fabula.shopify_variant_map (variant_id, label, product_type) values ('{VAR}', 'Bocconcini E2E {RUN} · 250 g', 'Mozzarella')")
DDT = sql1("select ddt_number from fabula.v_shipment_doc where channel is distinct from 'shopify' and ddt_number is not null order by ddt_number desc limit 1")
PIVA = sql1("select value from fabula.settings where key = 'company.piva'")

srv = subprocess.Popen(['python3', '-m', 'http.server', str(PORT)], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(1)
fails = []
def check(name, cond, info=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f'  [{info}]' if info else ''))
    if not cond: fails.append(name)

def rpc(fn, args):
    import urllib.request, urllib.error
    SVC = _jwt_role('service_role')
    req = urllib.request.Request('http://127.0.0.1:3000/rpc/' + fn, data=json.dumps(args).encode(),
                                 headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + SVC, 'Content-Profile': 'fabula', 'Accept-Profile': 'fabula'})
    try:
        with urllib.request.urlopen(req) as r: return 200, json.loads(r.read() or 'null')
    except urllib.error.HTTPError as e: return e.code, json.loads(e.read() or '{}')
def _jwt_role(role, secret=b"test-secret-test-secret-test-secret-0123456789"):
    h = _b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode()); p = _b64(json.dumps({"role": role, "exp": int(time.time()) + 3600}).encode())
    return h + '.' + p + '.' + _b64(hmac.new(secret, (h + '.' + p).encode(), hashlib.sha256).digest())

def farm_fn(route):                                    # emulates supabase/functions/farm-order (GET, ship) as of v0.95
    r = route.request; H = {'access-control-allow-origin': '*', 'content-type': 'application/json'}
    if r.method == 'OPTIONS': return route.fulfill(status=200, headers=H, body='ok')
    if r.method == 'GET':
        code, d = rpc('farm_milk_orders', {'p_token': r.url.split('t=')[1].split('&')[0]})
        return route.fulfill(status=200 if d else 403, headers=H, body=json.dumps(d or {'error': 'link non valido'}))
    b = json.loads(r.post_data or '{}')
    code, d = rpc('farm_milk_ship', {'p_token': b['t'], 'p_kg': float(b['kg']), 'p_temp': None, 'p_ddt': b.get('ddt'), 'p_note': b.get('note'),
                                     'p_confirm': b.get('confirm') if isinstance(b.get('confirm'), bool) else None})
    if code == 200 and isinstance(d, dict) and d.get('needs_confirm'):
        return route.fulfill(status=200, headers=H, body=json.dumps({'ok': False, 'needs_confirm': True, 'kg': d.get('kg'), 'message': d.get('message_it')}))
    ok = code == 200 and d
    return route.fulfill(status=200 if ok else 400, headers=H, body=json.dumps({'ok': True, 'shipment': d} if ok else {'error': d.get('message', str(d)) if isinstance(d, dict) else str(d)}))

def page_as(b, who, path, logs, width=1100):
    s = {"access_token": _jwt(*who), "refresh_token": "r", "expires_at": int(time.time()) + 86400, "expires_in": 86400, "token_type": "bearer",
         "user": {"id": who[0], "email": who[1], "aud": "authenticated", "role": "authenticated"}}
    def handler(route):
        u = route.request.url
        if '/rest/v1/' in u: return route.fulfill(response=route.fetch(url='http://127.0.0.1:3000/' + u.split('/rest/v1/', 1)[1]))
        if '/auth/v1/' in u: return route.fulfill(status=200, content_type='application/json', body=json.dumps(s['user']), headers={'access-control-allow-origin': '*'})
        if '/storage/v1/' in u: return route.fulfill(status=200, content_type='application/json', body=json.dumps({'Key': 'x'}), headers={'access-control-allow-origin': '*'})
        return route.fulfill(status=200, body='{}', headers={'access-control-allow-origin': '*'})
    ctx = b.new_context(service_workers='block', viewport={'width': width, 'height': 1300}); ctx.route('**/*.supabase.co/**', handler)
    pg = ctx.new_page(); pg.on('pageerror', lambda e: logs.append('PAGEERROR ' + str(e)))
    pg.goto(f'http://localhost:{PORT}/labels.html')
    pg.evaluate(f"localStorage.clear(); localStorage.setItem('sb-{REF}-auth-token', {json.dumps(json.dumps(s))})")
    pg.goto(f'http://localhost:{PORT}/{path}')
    return ctx, pg

try:
  with sync_playwright() as p:
    b = p.chromium.launch(); logs = []
    # ================= tablet =================
    ctx, pg = page_as(b, CASARO, 'index.html', logs, 800)
    pg.wait_for_function("document.querySelector('#v-home.active')", timeout=20000); pg.wait_for_timeout(3000)
    view = lambda: pg.evaluate("(document.querySelector('.view.active')||{}).id")
    toast = lambda: pg.evaluate("document.getElementById('toast').textContent")
    has = lambda i: pg.evaluate(f"!!document.getElementById('{i}') && document.getElementById('{i}').offsetParent !== null")
    def code(c): pg.evaluate("c => { document.getElementById('manual').value = c; document.getElementById('btn-manual').click(); }", c); pg.wait_for_timeout(1800)
    def setf(vals):
        for k, v in vals.items(): pg.evaluate("([k, v]) => { const e = document.getElementById(k); e.value = v; e.dispatchEvent(new Event('change')); e.dispatchEvent(new Event('input')); }", [k, str(v)])
    def save_form(): pg.evaluate("document.getElementById('btn-form-save').click()"); pg.wait_for_timeout(1500)
    def home(): pg.evaluate("(() => document.querySelectorAll('.view').forEach(e => e.classList.toggle('active', e.id === 'v-home')))()")
    def dose_through():
        for _ in range(40):
            if view() != 'v-dose': break
            pg.evaluate("(() => { const ok = document.getElementById('d-ok'); if (ok.style.display === 'none') { const i = document.getElementById('d-alt-in'); i.value = '70'; document.getElementById('d-alt-ok').click(); } else ok.click(); })()"); pg.wait_for_timeout(450)

    # D-09 / A-16 · a vat from milk: no ricotta offered, the milk still left, more is refused
    code('LOT:' + MILK)
    sub = pg.evaluate("document.getElementById('f-sub').textContent")
    prods = pg.evaluate("[...document.getElementById('product').options].map(o => o.text)") if has('product') else []
    check('D-09 the start form says what is left of the milk, not the delivery total', view() == 'v-form' and 'restano 400 kg' in sub and 'ricevuti 1.000' in sub and 'già in caldaia 600' in sub, sub)
    check('A-16 ricotta is not offered for a vat started from milk', prods and not any('icotta' in x for x in prods), str(prods))
    n0 = sql1(f"select count(*) from fabula.batch_milk_inputs where milk_intake_id = '{mid}'")
    setf({'kg': 500, 'mu': 'kg'})
    pg.evaluate("(() => { const v = document.getElementById('valve'); if (v && !v.value) { v.value = '0'; } const p = document.getElementById('past'); if (p && p.required && !p.value) p.value = '72.5'; })()")
    save_form()
    check('D-09 500 kg on 400 left is refused, saying what is left', view() == 'v-form' and 'restano 400 kg: hai scritto 500 kg' in toast()
          and sql1(f"select count(*) from fabula.batch_milk_inputs where milk_intake_id = '{mid}'") == n0, toast())
    home()

    # A-16 · the batch close asks ricotta yes / no
    code('LOT:' + LB)
    check('A-16 the close form asks «Ricotta con il siero…» with no answer preselected, kg of whey hidden',
          view() == 'v-form' and has('ricyn') and pg.evaluate("document.getElementById('ricyn').value") == '' and not has('whey'), toast())
    setf({'out': 90, 'n': 1}); save_form()
    check('A-16 Salva without answering does not close the lot', view() == 'v-form' and sql1(f"select output_kg is null from fabula.production_batches where batch_lot = '{LB}'") == 't')
    setf({'ricyn': 'si'})
    check('A-16 «Sì» shows the kg of whey', has('whey'))
    setf({'ricyn': 'no'}); save_form()
    if view() == 'v-form' and 'Salva di nuovo' in toast(): save_form()
    dose_through(); pg.wait_for_timeout(1200)
    check('A-16 «No» closes the lot and records "no ricotta" (whey 0)', sql1(f"select output_kg::int || '|' || whey_kg::int from fabula.production_batches where batch_lot = '{LB}'") == '90|0',
          sql1(f"select output_kg || '|' || coalesce(whey_kg::text, 'null') from fabula.production_batches where batch_lot = '{LB}'"))

    # A-16 · ricotta later from Home
    pg.goto(f'http://localhost:{PORT}/index.html'); pg.wait_for_function("document.querySelector('#v-home.active')", timeout=20000); pg.wait_for_timeout(3500)
    tile = pg.evaluate("[...document.querySelectorAll('#plan .task')].map(d => d.innerText).find(t => t.includes('Avvia ricotta')) || ''")
    check('A-16 Home offers «Avvia ricotta» for today\'s closed lots without ricotta', 'Avvia ricotta dal siero di oggi' in tile and LB in tile, tile.replace('\n', ' | '))
    pg.evaluate("[...document.querySelectorAll('#plan .task')].find(d => d.innerText.includes('Avvia ricotta')).click()"); pg.wait_for_timeout(1200)
    opt = pg.evaluate(f"[...document.getElementById('parent').options].map(o => o.textContent).find(t => t.startsWith('{LB}')) || ''") if has('parent') else ''
    check('A-16 …the form lists the lot and says «niente ricotta» was chosen', view() == 'v-form' and 'avevi scelto «niente ricotta»' in opt, opt)
    setf({'parent': LB, 'whey': 120}); save_form(); dose_through(); pg.wait_for_timeout(1500)
    rlot = 'R' + LB[1:]
    check('A-16 …the ricotta lot starts from that whey', sql1(f"select milk_in_kg::int || '|' || input_kind from fabula.production_batches where batch_lot = '{rlot}'") == '120|whey'
          and sql1(f"select whey_kg::int from fabula.production_batches where batch_lot = '{LB}'") == '120', sql1(f"select milk_in_kg || '|' || input_kind from fabula.production_batches where batch_lot = '{rlot}'"))
    home()

    # A-12 · Esci refused while records wait
    ctx.set_offline(True); pg.evaluate("dispatchEvent(new Event('offline'))")
    pg.evaluate("localStorage.setItem('fabula_queue', JSON.stringify([{ qid: 'e2e-" + RUN + "', at: Date.now(), ops: [], st: { done: 0, out: [] } }]))")
    pg.evaluate("document.getElementById('btn-logout').click()"); pg.wait_for_timeout(800)
    check('A-12 Esci with a record still waiting is refused and says why', view() == 'v-home' and "non ancora inviata" in toast() and 'collegati a internet' in toast(), f'{view()} · {toast()}')
    pg.evaluate("localStorage.setItem('fabula_queue', '[]')"); ctx.set_offline(False); pg.evaluate("dispatchEvent(new Event('online'))")
    pg.evaluate("document.getElementById('btn-logout').click()"); pg.wait_for_timeout(1200)
    check('A-12 with nothing waiting Esci logs out', view() == 'v-login', view())
    ctx.close()

    # ================= farm page =================
    farm = b.new_context(service_workers='block', viewport={'width': 390, 'height': 844}); farm.route('**/functions/v1/farm-order**', farm_fn)
    fp = farm.new_page(); fp.on('pageerror', lambda e: logs.append('PAGEERROR farm ' + str(e)))
    fp.goto(f'http://localhost:{PORT}/latte.html?t={TOKEN}&azione=spedizione'); fp.wait_for_timeout(1800)
    nship = sql1("select count(*) from fabula.milk_shipments")
    fp.fill('#kg', '105'); fp.click('#ship-go'); fp.wait_for_timeout(400)
    warn = fp.inner_text('#ship-warn') if fp.is_visible('#ship-warn') else ''
    check('FARM-01 105 kg against today\'s order is spelled out in the red box, not recorded', 'Hai scritto 105 kg' in warn and "ordine di oggi" in warn and '105 kg' in fp.inner_text('#ship-warn-kg')
          and not fp.is_visible('#ship-go') and sql1("select count(*) from fabula.milk_shipments") == nship, warn.replace('\n', ' | '))
    fp.click('#ship-warn-no'); fp.wait_for_timeout(200)
    k_it = f'{ORDER:,}'.replace(',', '.')
    fp.fill('#kg', k_it); fp.click('#ship-go'); fp.wait_for_timeout(300)
    check(f'FARM-01 «{k_it}» (thousands dot) is read as {ORDER} kg', fp.is_visible('#ship-go') and f'Confermo {k_it} kg' in fp.inner_text('#ship-go'), fp.inner_text('#ship-go'))
    fp.click('#ship-go'); fp.wait_for_timeout(1500)
    lot = sql1("select milk_lot || '|' || kg::int from fabula.milk_shipments order by created_at desc limit 1")
    check('FARM-01 …and recorded at that weight', lot.endswith(f'|{ORDER}') and 'Spedizione registrata' in fp.inner_text('#ship-ok'), lot)
    fp.click('#ship-open'); fp.fill('#kg', '30'); fp.click('#ship-go'); fp.wait_for_timeout(300)
    check('FARM-01 under 50 kg is refused on the page', 'tra 50 e 5.000' in fp.inner_text('#ship-err'), fp.inner_text('#ship-err'))
    sql(f"update fabula.milk_shipments set status = 'cancelled', cancel_reason = 'test e2e' where milk_lot = '{lot.split('|')[0]}'")
    farm.close()

    # ================= Autocontrollo (owner) =================
    ctx, hp = page_as(b, OWNER, 'haccp.html', logs)
    hp.wait_for_timeout(3500)
    htoast = lambda: hp.evaluate("document.getElementById('toast').textContent")
    tab = lambda t: (hp.click(f'.tab[data-tab="{t}"]'), hp.wait_for_timeout(500))
    tab('analisi')
    row = f'tr[data-sample="{SC}"]'
    check('B-02 a waiting sample starts with no outcome chosen', hp.eval_on_selector(f'{row} [data-k=outcome]', 'e => e.value') == '')
    hp.click(f'{row} [data-res]'); hp.wait_for_timeout(500)
    check('B-02 Registra without an outcome is refused', "Scegli l'esito" in htoast() and sql1(f"select outcome from fabula.lab_samples where sample_code = '{SC}'") == 'in_attesa', htoast())
    hp.select_option(f'{row} [data-k=outcome]', 'conforme'); hp.click(f'{row} [data-res]'); hp.wait_for_timeout(500)
    check('B-02 «Conforme» needs the result written', 'Scrivi il risultato' in htoast(), htoast())
    hp.fill(f'{row} [data-k=text]', 'assente in 25 g'); hp.click(f'{row} [data-res]'); hp.wait_for_timeout(2500)
    check('B-02 with outcome and result it is recorded', sql1(f"select outcome from fabula.lab_samples where sample_code = '{SC}'") == 'conforme')
    tab('analisi'); hp.wait_for_timeout(300)
    hp.click(f'[data-fix="{SC}"]'); hp.wait_for_timeout(400)
    hp.select_option('#fx-out', 'attenzione'); hp.fill('#fx-text', 'presenti 20 ufc/g'); hp.fill('#fx-why', 'letto male dal referto'); hp.click('#dlg-ok'); hp.wait_for_timeout(2500)
    check('B-02 «Correggi esito» changes it with the reason, keeping the first outcome',
          sql1(f"select outcome || '|' || (notes like '%conforme → attenzione (prima: assente in 25 g)%letto male dal referto%') from fabula.lab_samples where sample_code = '{SC}'") == 'attenzione|true',
          sql1(f"select outcome || ' ' || coalesce(notes, '') from fabula.lab_samples where sample_code = '{SC}'"))
    # B-05 · Prelevato with the lot picker
    tab('analisi'); n_s = sql1("select count(*) from fabula.lab_samples")
    hp.click('[data-take="MOZ-LM"]'); hp.wait_for_timeout(1200)
    lots = hp.evaluate("[...document.querySelectorAll('#sm-lot option')].map(o => o.value)")
    check('B-05 «Prelevato» opens a picker with the recent lots', hp.is_visible('#dlg') and 'LS' + RUN + '-A' in lots, str(lots[:6]))
    hp.fill('#sm-typed', 'xx-123'); hp.click('#dlg-ok'); hp.wait_for_timeout(300)
    check('B-05 a typed lot that does not exist is refused in the dialog', 'non riconosciuto' in hp.inner_text('#dlg-err') and sql1("select count(*) from fabula.lab_samples") == n_s, hp.inner_text('#dlg-err'))
    hp.fill('#sm-typed', ''); hp.select_option('#sm-lot', f'LS{RUN}-A'); hp.click('#dlg-ok'); hp.wait_for_timeout(2000)
    check('B-05 the chosen lot is stored and linked to its batch', sql1(f"select lot_number || '|' || (batch_id is not null) from fabula.lab_samples order by created_at desc limit 1") == f'LS{RUN}-A|true',
          sql1("select lot_number from fabula.lab_samples order by created_at desc limit 1"))
    # B-04 · register review
    tab('registri'); hp.wait_for_timeout(300); n_r = sql1("select count(*) from fabula.haccp_register_reviews")
    hp.click('[data-review="MOD-05"]'); hp.wait_for_timeout(1500)
    mx = hp.eval_on_selector('#rv-to', 'e => e.max')
    cnt = hp.inner_text('#rv-count')
    check('B-04 the review dialog stops at today and shows how many records', mx == TODAY and hp.eval_on_selector('#rv-to', 'e => e.value') == TODAY and 'registrazion' in cnt, f'max {mx} · {cnt}')
    hp.select_option('#rv-out', 'ok'); hp.click('#dlg-ok'); hp.wait_for_timeout(500)
    check('B-04 without «Ho letto le registrazioni» it is not signed', hp.is_visible('#dlg') and sql1("select count(*) from fabula.haccp_register_reviews") == n_r)
    hp.check('#rv-read'); hp.click('#dlg-ok'); hp.wait_for_timeout(2000)
    check('B-04 with the tick it is signed up to today by the person logged in',
          sql1("select period_to::text || '|' || (reviewed_by_id = (select id from fabula.staff where auth_user_id = '00000000-0000-4000-a000-0000000000b1')) from fabula.haccp_register_reviews order by reviewed_at desc limit 1") == f'{TODAY}|true',
          sql1("select period_from || '..' || period_to from fabula.haccp_register_reviews order by reviewed_at desc limit 1"))
    # B-03 · external calibration
    tab('strumenti'); n_c = sql1("select count(*) from fabula.calibration_checks")
    hp.select_option('#ce-code', 'TERM-REF'); hp.fill('#ce-provider', 'Lab E2E'); hp.fill('#ce-cert', ''); hp.click('#ce-save'); hp.wait_for_timeout(400)
    check('B-03 without certificate number it is refused', 'numero del certificato' in htoast(), htoast())
    hp.fill('#ce-cert', 'C-' + RUN); hp.click('#ce-save'); hp.wait_for_timeout(400)
    check('B-03 without deviation or PDF it is refused', 'scarto massimo' in htoast() and sql1("select count(*) from fabula.calibration_checks") == n_c, htoast())
    hp.fill('#ce-dev', '0,1'); hp.click('#ce-save'); hp.wait_for_timeout(2000)
    check('B-03 with certificate and deviation (decimal comma) it is recorded ok', sql1("select certificate_no || '|' || max_deviation || '|' || result from fabula.calibration_checks order by checked_at desc, id limit 1") == f'C-{RUN}|0.1|ok'
          or sql1(f"select max_deviation || '|' || result from fabula.calibration_checks where certificate_no = 'C-{RUN}'") == '0.1|ok', htoast())
    ctx.close()

    # ================= Configurazione (owner) =================
    ctx, ap = page_as(b, OWNER, 'admin.html', logs)
    ap.wait_for_timeout(3500)
    ap.click('.tab[data-tab="prodotti"]'); ap.wait_for_timeout(1500)
    vrow = ap.locator('#variant-map tr', has_text=f'Bocconcini E2E {RUN}')
    kgin = vrow.locator('input')
    check('C-28 the kg per piece is pre-filled from the title (250 g → 0,25)', kgin.input_value() == '0,25', kgin.input_value())
    kgin.fill('250'); ap.wait_for_timeout(200)
    check('C-28 the grams are shown next to it', '250.000 g' in vrow.inner_text(), vrow.inner_text().replace('\n', ' | '))
    vrow.locator('select').select_option(label='Mozzarella di Bufala Campana DOP (kg)') if vrow.locator('select option', has_text='Mozzarella di Bufala Campana DOP').count() else None
    vrow.locator('button.save').click(); ap.wait_for_timeout(800)
    t = ap.evaluate("document.getElementById('toast') ? document.getElementById('toast').textContent : ''")
    check('C-28 250 kg per piece is refused with the grams hint', 'se sono grammi scrivi 0,25' in t and sql1(f"select coalesce(kg_per_unit::text, 'null') from fabula.shopify_variant_map where variant_id = '{VAR}'") == 'null', t)
    ap.click('.tab[data-tab="parametri"]'); ap.wait_for_timeout(800)
    ap.evaluate("document.querySelector('#p-nav a[data-sec=\"professionisti\"]') && document.querySelector('#p-nav a[data-sec=\"professionisti\"]').click()"); ap.wait_for_timeout(600)
    boxes = ap.evaluate("[...document.querySelectorAll('.set-row[data-key=\"trade.delivery_days\"] input[type=checkbox]')].length")
    ttype = ap.evaluate("(document.querySelector('.set-row[data-key=\"trade.cutoff_time\"] input') || {}).type")
    check('C-04 delivery days are seven boxes and the cut-off a time field', boxes == 7 and ttype == 'time', f'{boxes} boxes · {ttype}')
    ctx.close()

    # ================= DDT =================
    if DDT:
        sql("update fabula.settings set value = '' where key = 'company.piva'")
        ctx, sp = page_as(b, OWNER, f'spedizione.html?id={DDT}', logs)
        sp.wait_for_timeout(3000)
        ban = sp.inner_text('#incomplete') if sp.is_visible('#incomplete') else ''
        check('PRINT-03 a wholesale DDT without P.IVA shows the red banner and cannot be printed', 'Documento incompleto' in ban and 'P.IVA' in ban and sp.eval_on_selector('#print', 'e => e.disabled'), ban)
        sql("update fabula.settings set value = '05541290655' where key = 'company.piva'")   # a valid P.IVA (the original is put back at the end)
        sp.click('#go'); sp.wait_for_timeout(2500)
        check('PRINT-03 with the data complete the banner goes and printing is back', not sp.is_visible('#incomplete') and not sp.eval_on_selector('#print', 'e => e.disabled'))
        ctx.close()
    else:
        check('PRINT-03 a wholesale DDT exists to test with', False, 'no wholesale shipment in restore_drill')
    check('no page errors', not logs, '; '.join(logs)[:300])
finally:
    sql(f"update fabula.settings set value = '{PIVA}' where key = 'company.piva'")
    if made_plan: sql(f"delete from fabula.milk_plans where plan_date = '{TODAY}' and milk_kg = 1050 and status = 'approved'")
    srv.terminate()
print('FAILURES:', fails or 'none')
