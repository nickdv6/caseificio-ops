"""v0.97 audit floor flows in the browser, against the local copy (restore_drill + setup.sql + PostgREST on :3000, v097a/b applied).
The tablet is logged in as Test Casaro (operator set).
- A-07  a cold room out of limit asks a red «È giusto?» first («No, correggo» saves nothing); then a card that stays, with what to do.
- A-15  the re-check is a red box on top of Home with the time left; tapping it opens the cold room; the next reading closes it.
        Warm milk: the card says by when it goes into the vat, and it is a timed task.
- A-07  rejecting a delivery (45 °C) asks first.
- A-26  «Annulla» on a form with something typed asks «Uscire senza salvare?».
- A-23  cleaning: an item «non fatto» with the reason is saved as such and pushed to the HACCP responsible.
- A-05  earlier days' tasks are apart, with «Non fatta…» and a reason.
- A-09  stock count: nothing prefilled, «✓ Ci sono» per line, empty lines stay «non contate».
- A-11  refused saves: a red banner on Home, a screen saying what each was and why in Italian, «Rifai» opens the form with the values;
        a record depending on a refused one is held back with it (A-08).
- D-04  a check queued offline keeps the time it was made.
- A-08  two tablets with the same lot letter: the second gets the next letter, and its queued steps follow it.
- A-18  a second tap within 0,7 s of a new dosing step is ignored; the last step done is shown.
- A-14  milk older than 60 hours cannot start a DOP batch.
- A-20  a milk arrival copied from the paper sheet keeps the sheet's date, time and signer.
Expect "FAILURES: none"."""
import json, subprocess, time, os, hmac, hashlib, base64, uuid
from playwright.sync_api import sync_playwright
from e2e_op import op_js, answer_ask

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../../../fabula-tablet'))
REF = 'ojkquhzaeypsphncjqwy'; PORT = 8776
def _b64(b): return base64.urlsafe_b64encode(b).rstrip(b'=').decode()
def _jwt(sub, email, secret=b"test-secret-test-secret-test-secret-0123456789"):
    h = _b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    p = _b64(json.dumps({"sub": sub, "role": "authenticated", "email": email, "aud": "authenticated", "exp": int(time.time()) + 86400}).encode())
    return h + '.' + p + '.' + _b64(hmac.new(secret, (h + '.' + p).encode(), hashlib.sha256).digest())
def sql(q):
    r = subprocess.run(['su', 'postgres', '-c', f'psql -At -d restore_drill -c "{q}"'], capture_output=True, text=True)
    return r.stdout.strip() or r.stderr.strip()
def sql1(q): return (sql(q).splitlines() or [''])[0]

RUN = time.strftime('%H%M%S'); CAS_ID = '10000000-0000-4000-a000-000000000001'
TODAY = sql1("select (now() at time zone 'Europe/Rome')::date"); YDAY = sql1("select (now() at time zone 'Europe/Rome')::date - 1")
sup = sql1("select id from fabula.parties where is_milk_supplier and active order by created_at limit 1")
sql("update fabula.milk_shipments set status = 'cancelled', cancel_reason = 'reset floor_e2e', cancelled_at = now() where status = 'shipped'")
sql("update fabula.task_instances set status = 'skipped', skip_reason = 'reset floor_e2e' where followup_kind is not null and status in ('due', 'overdue')")
LOTM = 'MF' + RUN                                                   # fresh milk for the lot-letter test
sql(f"insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source) values ('{TODAY}', (now() at time zone 'Europe/Rome')::time, '{sup}', '{LOTM}', 600, true, 4, 'tablet')")
LOTM2 = 'MG' + RUN                                                  # a second vat, of a product with no process preset (CCP 2 asked in the form)
sql(f"insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source) values ('{TODAY}', (now() at time zone 'Europe/Rome')::time, '{sup}', '{LOTM2}', 300, true, 4, 'tablet')")
NOPRE = sql1(f"insert into fabula.products (sku, name, kind, unit, is_dop, shelf_life_days, active, track_stock) values ('NOPRE{RUN}', 'Prova senza preset {RUN}', 'finished_good', 'kg', false, 5, true, true) returning id")
LOTO = 'MO' + RUN                                                   # milk that left the farm 62 hours ago
sql(f"insert into fabula.milk_shipments (id, shipped_at, ship_date, kg, milk_lot, status, supplier_id) values ('{uuid.uuid4()}', now() - interval '62 hours', '{TODAY}'::date - 3, 500, '{LOTO}', 'shipped', '{sup}')")
sql(f"insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source, shipment_id) select '{TODAY}'::date - 2, '09:00', '{sup}', '{LOTO}', 500, true, 4, 'tablet', id from fabula.milk_shipments where milk_lot = '{LOTO}'")
OLDTASK = sql1("insert into fabula.task_instances (schedule_id, due_at) select id, now() - interval '2 days' from fabula.task_schedules where code = 'T-KWH' returning id")

state = {'off': False}
sess = {"access_token": _jwt("00000000-0000-4000-a000-000000000001", "casaro@test.it"), "refresh_token": "r", "expires_at": int(time.time()) + 86400, "expires_in": 86400, "token_type": "bearer",
        "user": {"id": "00000000-0000-4000-a000-000000000001", "email": "casaro@test.it", "aud": "authenticated", "role": "authenticated"}}
def handler(route):
    try:
        url = route.request.url
        if state['off']: return route.abort('internetdisconnected')
        if '/rest/v1/' in url: return route.fulfill(response=route.fetch(url='http://127.0.0.1:3000/' + url.split('/rest/v1/', 1)[1]))
        if '/auth/v1/' in url: return route.fulfill(status=200, content_type='application/json', body=json.dumps(sess['user']), headers={'access-control-allow-origin': '*'})
        return route.fulfill(status=200, body='{}', headers={'access-control-allow-origin': '*'})
    except Exception: pass
srv = subprocess.Popen(['python3', '-m', 'http.server', str(PORT)], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1)
fails = []
def check(name, cond, info=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f'  [{info}]' if info else ''))
    if not cond: fails.append(name)
try:
  with sync_playwright() as p:
    b = p.chromium.launch(); ctx = b.new_context(service_workers='block', viewport={'width': 800, 'height': 1300})
    ctx.route('**/*.supabase.co/**', handler)
    ctx.add_init_script("window.__off=false;Object.defineProperty(Navigator.prototype,'onLine',{get:()=>!window.__off})")
    pg = ctx.new_page(); logs = []
    pg.on('pageerror', lambda e: logs.append('PAGEERROR ' + str(e)))
    pg.goto(f'http://localhost:{PORT}/labels.html')
    pg.evaluate(f"localStorage.clear(); localStorage.setItem('sb-{REF}-auth-token', {json.dumps(json.dumps(sess))}){op_js(sess)}")
    pg.goto(f'http://localhost:{PORT}/index.html')
    pg.wait_for_function("document.querySelector('#v-home.active')", timeout=20000); pg.wait_for_timeout(4000)
    view = lambda: pg.evaluate("(document.querySelector('.view.active')||{}).id")
    toast = lambda: pg.evaluate("document.getElementById('toast').textContent")
    title = lambda: pg.evaluate("document.getElementById('f-title').textContent")
    form_txt = lambda: pg.evaluate("document.getElementById('form').innerText")
    has = lambda i: pg.evaluate("i => !!document.getElementById(i)", i)
    def code(c): pg.evaluate("c => { document.getElementById('manual').value = c; document.getElementById('btn-manual').click(); }", c); pg.wait_for_timeout(1800)
    def setf(vals):
        for k, v in vals.items(): pg.evaluate("([k, v]) => { const e = document.getElementById(k); e.value = v; e.dispatchEvent(new Event('change')); e.dispatchEvent(new Event('input')); }", [k, str(v)])
    def save(): pg.evaluate("document.getElementById('btn-form-save').click()"); pg.wait_for_timeout(700)
    def home(): pg.evaluate("document.querySelectorAll('.view').forEach(e => e.classList.toggle('active', e.id === 'v-home'))"); pg.wait_for_timeout(200)
    def done_btn():                                       # «Fatto» on a result card → Home, list reloaded
        pg.evaluate("(() => { const b = [...document.querySelectorAll('#form button')].find(x => x.textContent === 'Fatto'); if (b) b.click(); })()"); pg.wait_for_timeout(2000)
    def go_off(): state['off'] = True; pg.evaluate("window.__off=true; dispatchEvent(new Event('offline'))")
    def go_on(): state['off'] = False; pg.evaluate("window.__off=false; dispatchEvent(new Event('online'))"); pg.wait_for_timeout(5000)
    queue = lambda: pg.evaluate("JSON.parse(localStorage.getItem('fabula_queue')||'[]')")
    CF1 = "select count(*) from fabula.haccp_log l join fabula.haccp_control_points c on c.id = l.control_point_id where c.code = 'CCP-COLD-1'"

    # ---- A-07 cold room out of limit: red question first, then a card that stays ----
    n0 = int(sql1(CF1))
    code('EQ:CF-01'); setf({'temp': 9}); setf({'action': 'porta chiusa, prodotto spostato in cella 2'}); save()
    q = answer_ask(pg, yes=False, wait=0)
    check('A-07 9 °C in cella 1: a red «È giusto?» with the value and the limit, before anything is saved',
          'Hai scritto 9 °C' in q and 'NON CONFORMITÀ' in q and pg.evaluate("!document.querySelector('.ask')") and int(sql1(CF1)) == n0 and view() == 'v-form', q.replace('\n', ' | '))
    save(); q = answer_ask(pg, wait=0); pg.wait_for_timeout(800)
    check('A-07 …«Sì»: saved as non-conformity and a card that stays, with what to do and the re-check time',
          'NON CONFORMITÀ' in title() and 'Cosa fare adesso' in form_txt() and 'Ricontrolla la cella entro le' in form_txt() and int(sql1(CF1)) == n0 + 1, title() + ' | ' + form_txt()[:200].replace('\n', ' | '))
    fu = sql1("select id || '|' || status from fabula.task_instances where followup_kind = 'recheck' and scan = 'EQ:CF-01' order by due_at desc limit 1")
    check('A-15 the re-check is a timed task in the database', fu.endswith('|due'), fu)
    done_btn()
    fbox = pg.evaluate("document.getElementById('followups').innerText")
    check('A-15 Home: a red box on top «Ricontrolla Cella frigo 1 entro le …» with the minutes left', pg.evaluate("document.getElementById('followups').style.display") != 'none' and 'Ricontrolla Cella frigo 1' in fbox and 'mancano' in fbox, fbox)
    pg.evaluate("document.querySelector('#followups .fu').click()"); pg.wait_for_timeout(1800)
    check('A-15 tapping it opens the cold room', view() == 'v-form' and has('temp') and 'CF-01' in pg.evaluate("document.getElementById('f-sub').textContent"), title())
    setf({'temp': 3}); save(); pg.wait_for_timeout(1500)
    check('A-15 the next reading (3 °C) closes the re-check and the red box goes', sql1(f"select status from fabula.task_instances where id = '{fu.split('|')[0]}'") == 'done'
          and 'Ricontrolla Cella frigo 1' not in pg.evaluate("document.getElementById('followups').innerText"), toast())
    code('EQ:CF-01'); setf({'temp': 5}); save(); pg.wait_for_timeout(1200)
    check('A-15 5 °C (alert band): a card «vicino al limite · ricontrolla entro le …», not a 2-second toast', 'vicino al limite' in title() and 'Ricontrolla entro le' in form_txt(), title())
    done_btn()

    # ---- A-26 Annulla on a form with something typed ----
    code('EQ:CF-02'); pg.fill('#temp', '3')
    pg.click('#btn-form-cancel'); q = answer_ask(pg, yes=False)
    check('A-26 «Annulla» after typing asks «Uscire senza salvare?» (No = stay)', 'Uscire senza salvare' in q and view() == 'v-form', q)
    pg.click('#btn-form-cancel'); answer_ask(pg)
    check('A-26 …«Sì» goes back to Home', view() == 'v-home')

    # ---- A-23 cleaning with an item not done ----
    code('CLEAN:')
    pg.evaluate("[...document.querySelectorAll('#form button')].find(x => x.textContent.startsWith('✓ Tutto fatto')).click()")
    setf({'c1': 'ko'}); setf({'w1': 'pezzo rotto'}); save(); q = answer_ask(pg, wait=0); pg.wait_for_timeout(1000)
    cl = sql1("select l.result || '|' || l.corrective_action from fabula.haccp_log l join fabula.haccp_control_points c on c.id = l.control_point_id where c.code = 'PRP-CLEAN' order by l.created_at desc limit 1")
    check('A-23 cleaning: «Filatrice: non fatto (pezzo rotto)» is saved as such (warning), with a card', cl == 'warning|Non fatto: Filatrice (pezzo rotto)' and 'NON completa' in title(), cl + ' | ' + q.replace('\n', ' '))
    check('A-23 …and pushed to the HACCP responsible', sql1("select count(*) from fabula.notify_outbox where dedupe_key like 'clean:%' and body like '%Filatrice (pezzo rotto)%'") != '0')
    done_btn()

    # ---- A-07 / A-15 milk arrival ----
    code('DDT:T' + RUN)
    setf({'lot': 'MW' + RUN, 'kg': 500, 'temp': 45, 'abx': '0'}); save(); q = answer_ask(pg, yes=False, wait=0)
    check('A-07 milk at 45 °C: «Il latte verrà RESPINTO» asked first (No = nothing saved)', 'RESPINTO' in q and 'Hai scritto 45 °C' in q
          and sql1(f"select count(*) from fabula.milk_intake where milk_lot = 'MW{RUN}'") == '0', q.replace('\n', ' | '))
    setf({'temp': 7.2}); save(); pg.wait_for_timeout(2000)
    check('A-15 warm milk (7,2 °C): the card says by when it goes into the vat', 'Latte registrato a 7,2 °C' in title() and 'mettilo in caldaia entro le' in form_txt(), title() + ' | ' + form_txt()[:160])
    check('A-15 …and it is a timed task', sql1(f"select count(*) from fabula.task_instances t join fabula.milk_intake m on m.id = t.milk_intake_id where t.followup_kind = 'milk_start' and m.milk_lot = 'MW{RUN}'") == '1')
    done_btn()

    # ---- A-05 earlier days apart, «Non fatta…» with a reason ----
    old = pg.evaluate("document.getElementById('tasks-old').innerText")
    check('A-05 a task from 2 days ago is under «Non fatte nei giorni scorsi», not «Da fare oggi»', pg.evaluate("document.getElementById('tasks-old-wrap').style.display") != 'none'
          and 'Lettura contatore' in old and 'Lettura contatore' not in pg.evaluate("document.getElementById('tasks').innerText"), old[:120])
    pg.evaluate("[...document.querySelectorAll('#tasks-old .task')].find(t => t.innerText.includes('Lettura contatore')).querySelector('.skip').click()"); pg.wait_for_timeout(400)
    pg.fill('#ask-in', 'contatore coperto dai lavori'); answer_ask(pg)
    check('A-05 «Non fatta…» with the reason: closed as skipped', sql1(f"select status || '|' || skip_reason from fabula.task_instances where id = '{OLDTASK}'") == 'skipped|contatore coperto dai lavori')

    # ---- A-09 / D-05 stock count ----
    pg.click('#btn-count'); pg.wait_for_timeout(2000)
    empty = pg.evaluate("[...document.querySelectorAll('#form input[data-line]')].every(i => i.value === '')")
    nlines = pg.evaluate("document.querySelectorAll('#form input[data-line]').length")
    check('A-09 stock count: nothing prefilled', nlines > 1 and empty, f'{nlines} lines')
    pg.evaluate("[...document.querySelectorAll('#form .nitem')].find(x => x.textContent.startsWith('✓ Ci sono')).click()")
    save(); q = answer_ask(pg, wait=0); pg.wait_for_timeout(1500)
    sc = sql1("select status || '|' || (select count(*) from fabula.stock_count_lines where count_id = c.id and counted_qty is not null) || '|' || (select count(*) from fabula.stock_count_lines where count_id = c.id and counted_qty is null) from fabula.stock_counts c order by counted_at desc limit 1")
    check('A-09 «✓ Ci sono» on one line, the rest left empty: asked, then saved with 1 counted and the others «non contate»',
          'senza numero' in q and sc == f'posted|1|{nlines - 1}', sc + ' | ' + q.replace('\n', ' '))

    # ---- A-11 / A-08 refused saves ----
    go_off()
    items = [{'qid': str(uuid.uuid4()), 'at': int(time.time() * 1000) - 1800000, 'st': {'done': 0, 'out': []},
              'ops': [{'table': 'production_batches', 'update': {'batch_lot': 'LXX' + RUN}, 'row': {'output_kg': 12.4}}, {'table': 'stock_moves', 'row': {'id': str(uuid.uuid4()), 'product_id': CAS_ID, 'lot_number': 'LXX' + RUN, 'qty': 12.4, 'move_type': 'production_out', 'source': 'tablet'}}]},
             {'qid': str(uuid.uuid4()), 'at': int(time.time() * 1000) - 1700000, 'st': {'done': 0, 'out': []},
              'ops': [{'rpc': 'log_ccp', 'args': {'p_cp_code': 'CCP-STRETCH', 'p_value': 61.5, 'p_staff_id': CAS_ID, 'p_batch_lot': 'LXX' + RUN, 'p_source': 'tablet', 'p_equipment_code': 'TERM-02'}}]},
             {'qid': str(uuid.uuid4()), 'at': int(time.time() * 1000) - 1680000, 'st': {'done': 0, 'out': []},
              'ops': [{'rpc': 'log_ccp', 'args': {'p_cp_code': 'CCP-COLD-1', 'p_value': 60, 'p_staff_id': CAS_ID, 'p_source': 'tablet', 'p_equipment_code': 'CF-01'}}]}]
    pg.evaluate("its => localStorage.setItem('fabula_queue', JSON.stringify(its))", items)
    go_on(); pg.wait_for_timeout(2000)
    banner = pg.evaluate("document.getElementById('rej-banner').innerText")
    check('A-11 a red banner on Home: «3 registrazioni NON salvate», what the first was', '3 registrazioni NON salvate' in banner and 'Fine lotto LXX' + RUN in banner, banner.replace('\n', ' | '))
    pg.evaluate("document.querySelector('#rej-banner .nitem').click()"); pg.wait_for_timeout(800)
    ft = form_txt()
    check('A-11 the screen says why in Italian: the lot is not in the database (D-15)', 'Il lotto non è nel database' in ft and 'Fine lotto LXX' + RUN + ' · 12,4 kg' in ft, ft[:300].replace('\n', ' | '))
    check('A-08 the CCP of that lot was held back with it, not sent on its own', 'dipende da una registrazione rifiutata' in ft
          and sql1(f"select count(*) from fabula.haccp_log where measured_value = 61.5 and created_at > now() - interval '5 minutes'") == '0', ft[300:600].replace('\n', ' | '))
    check('A-11 the impossible value is explained in Italian', 'Valore impossibile' in ft, ft[600:900].replace('\n', ' | '))
    nfail = lambda: pg.evaluate("JSON.parse(localStorage.getItem('fabula_failed')||'[]').length")
    pg.evaluate("[...document.querySelectorAll('#form .card.rej')].find(c => c.innerText.includes('Filatura')).querySelector('button.btn').click()"); pg.wait_for_timeout(2000)
    check('A-11 «Rifai» opens the form with the value, the time it was done and who did it',
          'Da rifare' in form_txt() and pg.evaluate("document.getElementById('v').value") in ('61.5', '61,5') and pg.evaluate("document.getElementById('pday').value") == TODAY
          and pg.evaluate("document.getElementById('ptime').value") != '' and pg.evaluate("document.getElementById('pwho').value") == 'Test Casaro',
          title() + ' | ' + form_txt()[:120].replace('\n', ' | '))
    pg.click('#btn-form-cancel'); pg.wait_for_timeout(300); answer_ask(pg)
    check('A-11 leaving «Rifai» without saving keeps it on the list', nfail() == 3 and view() == 'v-home', str(nfail()))
    pg.evaluate("document.querySelector('#rej-banner .nitem').click()"); pg.wait_for_timeout(800)
    pg.evaluate("[...document.querySelectorAll('#form .card.rej')].find(c => c.innerText.includes('Cella frigo 1')).querySelector('button.btn').click()"); pg.wait_for_timeout(2000)
    pg.fill('#v', '4.2'); save(); pg.wait_for_timeout(1500)
    rd = sql1("select l.source || '|' || round(extract(epoch from (now() - l.logged_at)) / 60) || '|' || (l.corrective_action like 'Registrata sul tablet e rifiutata dal database%')::text from fabula.haccp_log l where l.measured_value = 4.2 order by l.created_at desc limit 1")
    check('A-11 a refused tablet reading redone: saved as a tablet reading at the time it was made, with a note, and off the list',
          rd.split('|')[0] == 'tablet' and rd.split('|')[1] in ('27', '28', '29') and rd.endswith('|true') and nfail() == 2, rd + f' · list {nfail()}')
    home(); pg.wait_for_timeout(1500)                    # the check-in reports them to the office
    pg.evaluate("document.querySelector('#rej-banner .nitem').click()"); pg.wait_for_timeout(800)
    pg.evaluate("[...document.querySelectorAll('#form .card.rej')][0].querySelector('button.btn.secondary').click()"); q = answer_ask(pg)
    check('A-11 «Togli dalla lista» (after the office has it) asks, then removes it', 'Togliere dalla lista' in q and nfail() == 1, q)
    pg.evaluate("localStorage.setItem('fabula_failed', '[]')"); home()

    # ---- D-04 a check queued offline keeps its time ----
    go_off(); code('EQ:CF-02'); setf({'temp': 2.9}); save(); pg.wait_for_timeout(800)
    pg.evaluate("(() => { const q = JSON.parse(localStorage.getItem('fabula_queue')||'[]'); q.forEach(i => { i.at = Date.now() - 40 * 60000; }); localStorage.setItem('fabula_queue', JSON.stringify(q)); })()")
    go_on()
    off = sql1("select round(extract(epoch from (now() - logged_at)) / 60) || '|' || round(extract(epoch from (now() - created_at)) / 60) from fabula.haccp_log where measured_value = 2.9 order by created_at desc limit 1")
    check('D-04 a cold-room check saved offline 40 minutes ago keeps that time (arrived now)', off in ('40|0', '41|0', '40|1', '41|1'), off)

    # ---- A-08 two tablets, same letter; A-18 double tap ----
    home(); pg.wait_for_timeout(1000); go_off()
    nxt = sql1(f"select 'L' || to_char('{TODAY}'::date, 'YYYYMMDD') || '-' || chr(min(c)) from generate_series(65, 90) c where not exists (select 1 from fabula.production_batches where batch_lot = 'L' || to_char('{TODAY}'::date, 'YYYYMMDD') || '-' || chr(c))")
    moz = sql1("select id from fabula.products where sku = 'MOZ-DOP-KG'")
    other = sql1(f"insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, source, notes) values ('{TODAY}', '{nxt}', '{moz}', 100, 'milk', now(), 'tablet', 'altro tablet e2e') returning id")
    code('LOT:' + LOTM)
    t_title = title()
    check('A-08 offline, the tablet does not know the other tablet''s lot: it proposes the same letter', nxt in t_title, t_title + ' vs ' + nxt)
    setf({'kg': 300})
    pg.evaluate("(() => { const v = document.getElementById('valve'); if (v && !v.value) v.value = '0'; const p = document.getElementById('past'); if (p && p.required && !p.value) p.value = '72.5'; })()")
    if has('valvenote'): setf({'valvenote': 'riparato e provato (e2e)'})
    save(); pg.wait_for_timeout(1200)
    saw_nm, dbl = False, None
    for i in range(40):
        if view() != 'v-dose': break
        okt = pg.evaluate("document.getElementById('d-ok').textContent"); saw_nm = saw_nm or 'non misurato' in okt
        if pg.evaluate("document.getElementById('d-ok').style.display") == 'none':
            pg.evaluate("(() => { const i = document.getElementById('d-alt-in'); const m = (document.getElementById('d-instr').textContent.match(/Obiettivo ([0-9.,]+)/) || [])[1]; i.value = (m || '74').replace(',', '.'); document.getElementById('d-alt-ok').click(); })()")
        elif dbl is None:                                   # A-18: a second tap 0,25 s after the first lands on the next step and is ignored
            n1 = len(queue()); pg.evaluate("document.getElementById('d-ok').click()"); pg.wait_for_timeout(250); pg.evaluate("document.getElementById('d-ok').click()"); pg.wait_for_timeout(300)
            dbl = (len(queue()) - n1, pg.evaluate("document.getElementById('d-last').textContent"))
        else: pg.evaluate("document.getElementById('d-ok').click()")
        pg.wait_for_timeout(850)
    check('A-18 a double tap on «✓ Fatto» records one step; the line under the card says which', dbl is not None and dbl[0] == 1 and dbl[1].startswith('✓ ') and 'registrato alle' in dbl[1], str(dbl))
    check('A-22 a measured step that is not a CCP says «✓ Fatto (non misurato)»', saw_nm)
    mine = sql1("select count(*) from fabula.production_batches where batch_lot = '" + nxt + "'")
    home(); code('LOT:' + LOTM2)                       # second vat offline: a product with no preset, CCP 2 typed in the form
    pg.evaluate("p => { const s = document.getElementById('product'); s.value = p; s.dispatchEvent(new Event('change')); }", NOPRE)
    t2 = title(); setf({'kg': 200, 'past': 72.4})
    pg.evaluate("(() => { const v = document.getElementById('valve'); if (v && !v.value) v.value = '0'; })()")
    if has('valvenote'): setf({'valvenote': 'riparato e provato (e2e)'})
    save(); pg.wait_for_timeout(1500)
    go_on(); pg.wait_for_timeout(2000)
    row = sql1(f"select b.batch_lot || '|' || b.notes from fabula.production_batches b join fabula.batch_milk_inputs i on i.batch_id = b.id join fabula.milk_intake m on m.id = i.milk_intake_id where m.milk_lot = '{LOTM}' limit 1")
    newlot = row.split('|')[0]
    check('A-08 back online: the tablet''s lot became the next free letter, with a note', newlot != nxt and newlot[:-1] == nxt[:-1] and f'Avviato sul tablet come {nxt}' in row, row)
    steps_mine = sql1(f"select (select count(*) from fabula.batch_step_logs where batch_id = b.id) + (select count(*) from fabula.batch_consumables where batch_id = b.id) from fabula.production_batches b where b.batch_lot = '{newlot}'")
    steps_other = sql1(f"select (select count(*) from fabula.batch_step_logs where batch_id = '{other}') + (select count(*) from fabula.batch_consumables where batch_id = '{other}')")
    check('A-08 …its steps and doses followed it; none landed on the other tablet''s lot', mine == '1' and int(steps_mine or 0) > 0 and steps_other == '0', f'mine {steps_mine} · other {steps_other}')
    v2 = sql1(f"select b.batch_lot from fabula.production_batches b join fabula.batch_milk_inputs i on i.batch_id = b.id join fabula.milk_intake m on m.id = i.milk_intake_id where m.milk_lot = '{LOTM2}'")
    past = sql1(f"select string_agg(b.batch_lot, ',' order by b.batch_lot) from fabula.haccp_log l join fabula.haccp_control_points c on c.id = l.control_point_id join fabula.production_batches b on b.id = l.batch_id where c.code = 'CCP-PAST' and l.measured_value = 72.4 and b.batch_lot in ('{nxt}', '{newlot}', '{v2}')")
    check('A-08 the second vat (offline «' + t2.split(' ')[-1] + '», taken by the first after its rename) got the next letter again, and its CCP 2 went with it',
          v2 not in (nxt, newlot) and past == v2, f'{t2} → {v2} · CCP 2 on {past}')
    rn = pg.evaluate("document.getElementById('renames').innerText")
    check('A-08 Home says which letter to write on the vat sheet', newlot in rn and nxt in rn and v2 in rn, rn)

    # ---- A-14 60 hours ----
    home(); code('LOT:' + LOTO)
    opts = pg.evaluate("[...((document.getElementById('product') || {}).options || [])].map(o => o.text)") if view() == 'v-form' else []
    check('A-14 milk 62 hours old: no DOP product offered, the tablet says why',
          (view() == 'v-home' and 'ha già 62 ore' in toast()) or (view() == 'v-form' and opts and not any('DOP' in o for o in opts) and 'oltre le 60 ore' in form_txt()), toast() + ' | ' + str(opts))
    if view() == 'v-form': pg.click('#btn-form-cancel'); answer_ask(pg)

    # ---- A-20 milk arrival from the paper sheet ----
    code('DDT:P' + RUN)
    check('A-20 the milk arrival has «Ricopio dal foglio di carta»', has('pp-on'))
    pg.check('#pp-on'); pg.fill('#pday', YDAY); pg.fill('#ptime', '06:30'); pg.select_option('#pwho', 'Test Casaro')
    setf({'lot': 'MP' + RUN, 'kg': 300, 'temp': 4, 'abx': '0'}); save(); pg.wait_for_timeout(2000)
    mp = sql1(f"select intake_date || ' ' || intake_time || '|' || source || '|' || received_by from fabula.milk_intake where milk_lot = 'MP{RUN}'")
    lp = sql1(f"select string_agg(to_char(l.logged_at at time zone 'Europe/Rome', 'YYYY-MM-DD HH24:MI') || ' ' || l.source, ',') from fabula.haccp_log l join fabula.milk_intake m on m.id = l.milk_intake_id where m.milk_lot = 'MP{RUN}'")
    check('A-20 …saved with the sheet''s date, time and signer, source paper; its checks too', mp == f'{YDAY} 06:30:00|paper|Test Casaro' and lp == f'{YDAY} 06:30 paper,{YDAY} 06:30 paper', mp + ' · ' + lp)
    check('no page errors', not logs, ' | '.join(logs)[:300])
    b.close()
finally:
    srv.terminate()
print('FAILURES:', fails if fails else 'none')
