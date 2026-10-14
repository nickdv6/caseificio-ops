"""v1.03 in the browser, against the local copy (restore_drill + setup.sql + PostgREST on :3000, v103a–c applied). Port 8782, browser
in Italian. The farm page talks to the real edge function `farm-order`, run locally with Deno (DENO=…/deno) through a small proxy that
forwards /rest/v1 to PostgREST, as Supabase does.
- FARM-04 the QR poster's key: «Chi spedisce» asked (names from the setting) and remembered on the phone; the load saved with the name and
          the link it came from; only today's loads, no orders or month; its own load corrected within 2 hours (the office is told who).
- FARM-04 the full link: month, orders and the name on each load; it refuses to become a poster, the QR key prints one.
- FARM-04 Configurazione → Utenti e accessi → «Link della Masseria» (owner): links, WhatsApp text, «Genera nuovo QR» asks, switches the
          old QR off and says to reprint; «Chi spedisce» saved. The office profile sees no links; Console → Oggi: the poster with the QR
          key and the warning for the owner, nothing for production.
- PRINT-08 tablet «🖨 Ristampa etichette lotto»: search, the lot's copies, «Prepara l'etichetta», the label link, the reprint counted;
          labels.html: name and expiry from the database (a wrong one corrected), a lot typed by hand that does not exist in red and
          not printed, one from the tablet not yet in the database in amber, no login = «NON controllati».
Expect "FAILURES: none"."""
import json, subprocess, time, os, hmac, hashlib, base64, threading, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, unquote
from playwright.sync_api import sync_playwright
from e2e_op import op_js

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../../../fabula-tablet'))
FN = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../../../supabase/functions/farm-order/index.ts'))
DENO = os.environ.get('DENO', '/tmp/claude-0/denoinst/node_modules/.bin/deno')
REF = 'ojkquhzaeypsphncjqwy'; PORT = 8782; PROXY = 8792
SECRET = b"test-secret-test-secret-test-secret-0123456789"
def _b64(b): return base64.urlsafe_b64encode(b).rstrip(b'=').decode()
def _jwt(sub, email):
    h = _b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    p = _b64(json.dumps({"sub": sub, "role": "authenticated", "email": email, "aud": "authenticated", "exp": int(time.time()) + 86400}).encode())
    return h + '.' + p + '.' + _b64(hmac.new(SECRET, (h + '.' + p).encode(), hashlib.sha256).digest())
def _jwt_role(role):
    h = _b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode()); p = _b64(json.dumps({"role": role, "exp": int(time.time()) + 3600}).encode())
    return h + '.' + p + '.' + _b64(hmac.new(SECRET, (h + '.' + p).encode(), hashlib.sha256).digest())
def sql(q):
    r = subprocess.run(['su', 'postgres', '-c', f'psql -At -d restore_drill -c "{q}"'], capture_output=True, text=True)
    if 'ERROR' in r.stderr: print('SQL ERROR:', q[:90], '→', r.stderr.strip()[:300])
    return r.stdout.strip() or r.stderr.strip()
def sql1(q): return (sql(q).splitlines() or [''])[0]

OWNER = ("00000000-0000-4000-a000-0000000001f1", "v103-owner@test.it"); OWNER_STAFF = '10000000-0000-4000-a000-0000000001f1'
OFFICE = ("00000000-0000-4000-a000-0000000001f2", "v103-office@test.it")
CASARO = ("00000000-0000-4000-a000-000000000001", "casaro@test.it")
sql(f"insert into auth.users(id, email) values ('{OWNER[0]}', '{OWNER[1]}'), ('{OFFICE[0]}', '{OFFICE[1]}') on conflict do nothing")
sql(f"insert into fabula.staff(id, full_name, auth_user_id, app_role, role, active) values ('{OWNER_STAFF}', 'Titolare V103', '{OWNER[0]}', 'titolare', 'owner', true), "
    f"('10000000-0000-4000-a000-0000000001f2', 'Ufficio V103', '{OFFICE[0]}', 'amministrazione', 'operaio', true) on conflict do nothing")
# the day's farm loads left by the suites before: moved to yesterday (the farm records at most 8 a day)
sql("update fabula.milk_shipments set ship_date = ship_date - 1, shipped_at = shipped_at - interval '1 day' where ship_date = (now() at time zone 'Europe/Rome')::date")
sql("update fabula.settings set value = 'Mario, Luca' where key = 'milk.farm_people'")
FULL = sql1("select value from fabula.settings where key = 'milk.farm_token'")
QR = sql1("select value from fabula.settings where key = 'milk.farm_ship_token'")
KG = int(float(sql1("select coalesce((select milk_kg from fabula.milk_plans where status = 'approved' and plan_date = (now() at time zone 'Europe/Rome')::date order by milk_kg desc limit 1), fabula._farm_usual_kg(), 1000)")))
# two lots: one closed (6 labels printed at close, expiry in 3 days) and one still being worked
MOZ = sql1("select id from fabula.products where sku = 'MOZ-DOP-KG'")
for q in ["delete from fabula.labels where code in ('LOT:LE103-A', 'LOT:LE103-B')", "delete from fabula.stock_moves where lot_number in ('LE103-A', 'LE103-B')",
          "delete from fabula.production_batches where batch_lot in ('LE103-A', 'LE103-B')"]:
    subprocess.run(['su', 'postgres', '-c', f'psql -At -d restore_drill -c "{q}"'], capture_output=True)   # a rerun on the same copy
sql(f"insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, output_kg, finished_at, source) values "
    f"(current_date - 1, 'LE103-A', '{MOZ}', 400, 'milk', now() - interval '1 day', 100, now() - interval '20 hours', 'tablet'), "
    f"(current_date, 'LE103-B', '{MOZ}', 400, 'milk', now() - interval '1 hour', null, null, 'tablet')")
sql(f"insert into fabula.stock_moves (product_id, lot_number, expiry_date, qty, move_type, batch_id, source) select '{MOZ}', 'LE103-A', current_date + 3, 100, 'production_out', id, 'tablet' from fabula.production_batches where batch_lot = 'LE103-A'")
sql(f"insert into fabula.labels (kind, code, lot_number, product_id, batch_id, qty_printed) select 'batch_lot', 'LOT:LE103-A', 'LE103-A', '{MOZ}', id, 6 from fabula.production_batches where batch_lot = 'LE103-A'")
PNAME = sql1(f"select name from fabula.products where id = '{MOZ}'")
EXP = sql1("select to_char(current_date + 3, 'DD/MM/YYYY')")

fails = []
def check(name, cond, info=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f'  [{info}]' if info else ''))
    if not cond: fails.append(name)

# ---- the edge function farm-order, run with Deno; /rest/v1 forwarded to PostgREST ----
class Proxy(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _go(self):
        n = int(self.headers.get('Content-Length') or 0); data = self.rfile.read(n) if n else None
        url = 'http://127.0.0.1:3000/' + self.path.split('/rest/v1/', 1)[1]
        hdr = {k: v for k, v in self.headers.items() if k.lower() in ('authorization', 'content-type', 'accept', 'accept-profile', 'content-profile', 'prefer', 'apikey')}
        req = urllib.request.Request(url, data=data, method=self.command, headers=hdr)
        try:
            with urllib.request.urlopen(req) as r: code, body, ct = r.status, r.read(), r.headers.get('Content-Type', 'application/json')
        except urllib.error.HTTPError as e: code, body, ct = e.code, e.read(), e.headers.get('Content-Type', 'application/json')
        self.send_response(code); self.send_header('Content-Type', ct); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    do_GET = do_POST = do_PATCH = _go
proxy = ThreadingHTTPServer(('127.0.0.1', PROXY), Proxy); threading.Thread(target=proxy.serve_forever, daemon=True).start()
env = dict(os.environ, SUPABASE_URL=f'http://127.0.0.1:{PROXY}', SUPABASE_SERVICE_ROLE_KEY=_jwt_role('service_role'), DENO_DIR=os.environ.get('DENO_DIR', '/tmp/claude-0/denocache'))
fnp = subprocess.Popen([DENO, 'run', '--allow-net', '--allow-env', FN], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
for _ in range(90):
    try: urllib.request.urlopen('http://127.0.0.1:8000/?t=x', timeout=1); break
    except urllib.error.HTTPError: break
    except Exception: time.sleep(1)
def farm_route(route):
    r = route.request; q = r.url.split('farm-order', 1)[1]
    return route.fulfill(response=route.fetch(url='http://127.0.0.1:8000/' + q))

srv = subprocess.Popen(['python3', '-m', 'http.server', str(PORT)], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1)
class Dlg:
    def __init__(self, pg): self.log, self.answers = [], []; pg.on('dialog', self.on)
    def on(self, d):
        self.log.append(d.type + ': ' + d.message)
        a = self.answers.pop(0) if self.answers else True
        if a is False: d.dismiss()
        elif d.type == 'prompt': d.accept(a if isinstance(a, str) else '')
        else: d.accept()
def session(who):
    return {"access_token": _jwt(*who), "refresh_token": "r", "expires_at": int(time.time()) + 86400, "expires_in": 86400, "token_type": "bearer",
            "user": {"id": who[0], "email": who[1], "aud": "authenticated", "role": "authenticated"}}
def page_as(b, who, path, logs, width=1100):
    s = session(who) if who else None
    def handler(route):
        u = route.request.url
        if '/rest/v1/' in u: return route.fulfill(response=route.fetch(url='http://127.0.0.1:3000/' + u.split('/rest/v1/', 1)[1]))
        if '/auth/v1/' in u: return route.fulfill(status=200, content_type='application/json', body=json.dumps(s['user'] if s else {}), headers={'access-control-allow-origin': '*'})
        return route.fulfill(status=200, body='{}', headers={'access-control-allow-origin': '*'})
    ctx = b.new_context(service_workers='block', viewport={'width': width, 'height': 1300}, locale='it-IT'); ctx.route('**/*.supabase.co/**', handler)
    pg = ctx.new_page(); pg.on('pageerror', lambda e: logs.append('PAGEERROR ' + str(e)))
    pg.goto(f'http://localhost:{PORT}/labels.html')
    pg.evaluate(f"localStorage.clear(); localStorage.setItem('sb-{REF}-auth-token', {json.dumps(json.dumps(s))}){op_js(s)}" if s else "localStorage.clear()")
    pg.goto(f'http://localhost:{PORT}/{path}')
    return ctx, pg
def farm_page(b, token, extra, logs):
    ctx = b.new_context(service_workers='block', viewport={'width': 390, 'height': 844}, locale='it-IT'); ctx.route('**/functions/v1/farm-order**', farm_route)
    fp = ctx.new_page(); fp.on('pageerror', lambda e: logs.append('PAGEERROR farm ' + str(e)))
    fp.goto(f'http://localhost:{PORT}/latte.html?t={token}{extra}'); fp.wait_for_timeout(2500)
    return ctx, fp
text = lambda pg, sel: pg.evaluate(f"(document.querySelector({json.dumps(sel)}) || {{}}).innerText || ''")

try:
  with sync_playwright() as p:
    b = p.chromium.launch(); logs = []
    # ================= FARM-04 · the QR in the barn =================
    fctx, fp = farm_page(b, QR, '&azione=spedizione', logs)
    st = fp.evaluate("({ form: !document.getElementById('ship-form').hidden, sel: !document.getElementById('who-sel').hidden, opts: [...document.querySelectorAll('#who-sel option')].map(o => o.textContent),"
                     " month: document.getElementById('sec-month').hidden, orders: document.getElementById('sec-orders').hidden, h: document.getElementById('h-hist').textContent, foot: document.getElementById('foot').textContent })")
    check('FARM-04 QR: the form opens, «Chi spedisce» lists the names; no month, no orders, «Spedizioni di oggi»',
          st['form'] and st['sel'] and st['opts'][1:3] == ['Mario', 'Luca'] and st['month'] and st['orders'] and st['h'] == 'Spedizioni di oggi' and 'QR delle spedizioni' in st['foot'], json.dumps(st))
    fp.fill('#kg', str(KG)); fp.click('#ship-go'); fp.wait_for_timeout(300)
    check('FARM-04 QR: no name chosen → «Scegli chi spedisce», nothing sent', text(fp, '#ship-err') == 'Scegli chi spedisce.' and sql1("select count(*) from fabula.milk_shipments where ship_date = (now() at time zone 'Europe/Rome')::date") == '0', text(fp, '#ship-err'))
    fp.select_option('#who-sel', '__altro'); fp.fill('#who', 'Gino'); fp.select_option('#who-sel', ''); fp.click('#ship-go'); fp.wait_for_timeout(300)
    check('FARM-04 QR: a name typed under «Un altro» and then the list put back to «scegli» counts as nobody', text(fp, '#ship-err') == 'Scegli chi spedisce.', text(fp, '#ship-err'))
    fp.select_option('#who-sel', 'Mario'); fp.click('#ship-go'); fp.wait_for_timeout(300)
    if fp.is_visible('#ship-warn'): fp.click('#ship-warn-yes')
    else: fp.click('#ship-go')
    fp.wait_for_timeout(2500)
    if fp.is_visible('#ship-warn'): fp.click('#ship-warn-yes'); fp.wait_for_timeout(2500)
    row = sql1("select milk_lot || '|' || coalesce(recorded_by, '-') || '|' || source from fabula.milk_shipments where ship_date = (now() at time zone 'Europe/Rome')::date order by shipped_at desc limit 1")
    LOT = row.split('|')[0]
    check('FARM-04 QR: the load is saved with the name and «farm_qr» (through the real farm-order function)', row.endswith('|Mario|farm_qr') and 'registrata da Mario' in text(fp, '#ship-ok'), row + ' / ' + text(fp, '#ship-ok')[:80])
    fp.reload(); fp.wait_for_timeout(2500); fp.click('#ship-open'); fp.wait_for_timeout(300)
    check('FARM-04 QR: the phone remembers who ships', fp.evaluate("document.getElementById('who-sel').value") == 'Mario' and 'Mario' in text(fp, '#hist'), text(fp, '#hist')[:120])
    fp.click('#ship-cancel'); fp.click('[data-amend]'); fp.wait_for_timeout(300)
    fp.fill('#am-kg', str(KG + 10)); fp.fill('#am-why', 'peso sbagliato'); fp.click('#am-save'); fp.wait_for_timeout(200); fp.click('#am-save'); fp.wait_for_timeout(2500)
    check('FARM-04 QR: its own load corrected within 2 hours, the office told who', sql1(f"select kg from fabula.milk_shipments where milk_lot = '{LOT}'") == f'{KG + 10}.0'
          and sql1(f"select count(*) from fabula.bot_messages where agent = 'masseria' and body like 'La Masseria (Mario) ha corretto la spedizione {LOT}%'") == '1', sql1(f"select kg from fabula.milk_shipments where milk_lot = '{LOT}'"))
    fctx.close()

    # ================= FARM-04 · the full link and the poster =================
    fctx, fp = farm_page(b, FULL, '', logs)
    st = fp.evaluate("({ month: document.getElementById('sec-month').hidden, orders: document.getElementById('sec-orders').hidden, h: document.getElementById('h-hist').textContent })")
    check('FARM-04 full link: month, orders and the 30 days, with the name on the load', not st['month'] and not st['orders'] and st['h'] == 'Ultimi 30 giorni' and 'Mario' in text(fp, '#latest'), json.dumps(st) + ' / ' + text(fp, '#latest')[:100])
    fp.goto(f'http://localhost:{PORT}/latte.html?t={FULL}&stampa=1'); fp.wait_for_timeout(2500)
    check('FARM-04 the full link refuses to become a poster', not fp.evaluate("!!document.querySelector('#qr canvas, #qr img')") and 'non va appeso' in text(fp, '#purl'), text(fp, '#purl'))
    fp.goto(f'http://localhost:{PORT}/latte.html?t={QR}&stampa=1'); fp.wait_for_timeout(2500)
    check('FARM-04 the QR key prints the poster', fp.evaluate("!!document.querySelector('#qr canvas, #qr img')") and 'Solo per registrare' in text(fp, '#purl'), text(fp, '#purl'))
    fctx.close()

    # ================= FARM-04 · Configurazione → Link della Masseria =================
    ctx, ap = page_as(b, OWNER, 'admin.html#utenti&masseria', logs)
    ap.wait_for_timeout(6000); dl = Dlg(ap)
    links = ap.evaluate("[...document.querySelectorAll('#farm-links a')].map(a => a.textContent.trim() + '=' + a.href)")
    check('FARM-04 the owner sees the full link (WhatsApp text with it) and the poster with the QR key',
          any(l.startswith('Apri=') and f't={FULL}' in l for l in links) and any(l.startswith('Manda su WhatsApp=') and FULL in unquote(l) for l in links)
          and any('Stampa il poster' in l and f't={QR}&stampa=1' in l for l in links), ' | '.join(l[:80] for l in links))
    dl.answers = [False]; ap.click('[data-frot="qr"]'); ap.wait_for_timeout(1500)
    check('FARM-04 «Genera nuovo QR» asks first (dismissed: nothing changes)', len(dl.log) == 1 and 'poster appeso' in dl.log[0] and sql1("select value from fabula.settings where key = 'milk.farm_ship_token'") == QR, ' | '.join(dl.log))
    dl.answers = [True]; ap.click('[data-frot="qr"]'); ap.wait_for_timeout(3000)
    QR2 = sql1("select value from fabula.settings where key = 'milk.farm_ship_token'")
    check('FARM-04 …confirmed: a new QR key, the page says to reprint, the office feed is told', QR2 != QR and len(QR2) == 32 and 'Stampa il nuovo' in text(ap, '#farm-rot-msg')
          and f't={QR2}&stampa=1' in ap.evaluate("(document.querySelector('[data-fposter]') || {}).href || ''")
          and sql1("select count(*) from fabula.bot_messages where agent = 'configurazione' and title = 'Nuovo QR spedizioni della Masseria' and body like 'Titolare V103 ha generato%' and created_at > now() - interval '2 minutes'") == '1', text(ap, '#farm-rot-msg'))
    ap.fill('#farm-people', 'Mario ,Luca;  Gianni'); ap.click('#farm-people-save'); ap.wait_for_timeout(1500)
    check('FARM-04 «Chi spedisce» saved, tidied', sql1("select value from fabula.settings where key = 'milk.farm_people'") == 'Mario, Luca, Gianni')
    ctx.close()
    fctx, fp = farm_page(b, QR, '', logs)
    check('FARM-04 the old QR key no longer opens the page', 'link non valido' in text(fp, '#err').lower(), text(fp, '#err'))
    fctx.close()
    ctx, op = page_as(b, OFFICE, 'admin.html#utenti', logs)
    op.wait_for_timeout(5000)
    check('FARM-04 the office profile sees no Masseria links', 'solo chi gestisce il sistema' in text(op, '#farm-links') and FULL not in op.content(), text(op, '#farm-links'))
    ctx.close()
    ctx, cp = page_as(b, OWNER, 'console.html#oggi', logs)
    cp.wait_for_timeout(6000)
    fs = cp.evaluate("(() => { const e = document.getElementById('farm-status'); return e ? e.innerHTML : ''; })()")
    pid = sql1("select id from fabula.parties where type in ('customer', 'both', 'supplier') order by created_at limit 1")
    r = cp.evaluate(f"UI.upd('parties', {{ id: '{pid}' }}, {{ payment_terms_days: 45 }}).then(d => 'ok:' + JSON.stringify(d), e => 'err:' + e.message)")
    check('C-05 Console saves on customers and suppliers still work (the shared save asks back only the id)', r.startswith('ok:') and 'portal_token' not in r
          and sql1(f"select payment_terms_days from fabula.parties where id = '{pid}'") == '45', r)
    check('Console → Oggi (owner): the poster uses the QR key, the full link carries its warning', f't={QR2}&amp;stampa=1' in fs and 'accesso completo' in fs and f't={FULL}&amp;stampa=1' not in fs, fs[-300:])
    ctx.close()
    ctx, cp = page_as(b, CASARO, 'console.html#oggi', logs)
    cp.wait_for_timeout(6000)
    fs = cp.evaluate("(() => { const e = document.getElementById('farm-status'); return e ? e.innerHTML : ''; })()")
    check('Console → Oggi (production): no Masseria link at all', 'pagina Masseria' not in fs and FULL not in cp.content(), fs[-200:])
    ctx.close()

    # ================= PRINT-08 · tablet «Ristampa etichette» =================
    ctx, tp = page_as(b, CASARO, 'index.html', logs, 800)
    tp.wait_for_function("document.querySelector('#v-home.active')", timeout=20000)
    check('PRINT-08 Home has «🖨 Ristampa etichette lotto»', tp.is_visible('#btn-reprint'))
    tp.click('#btn-reprint'); tp.wait_for_timeout(2500)
    tp.fill('#rp-q', 'e103'); tp.keyboard.press('Enter'); tp.wait_for_timeout(2500)
    rows = tp.evaluate("[...document.querySelectorAll('#form .task')].map(d => d.innerText.replace(/\\s+/g, ' '))")
    check('PRINT-08 search: the lot being worked first, then the closed one with its expiry', len(rows) == 2 and rows[0].startswith('LE103-B') and 'in lavorazione' in rows[0]
          and rows[1].startswith('LE103-A') and f'scad. {EXP}' in rows[1], ' || '.join(rows))
    tp.click('#form .task:nth-of-type(3)' if False else 'text=LE103-A'); tp.wait_for_timeout(800)
    check('PRINT-08 the closed lot: the copies printed at close, «Prepara l\'etichetta»', tp.evaluate("document.getElementById('rp-n').value") == '6'
          and tp.evaluate("document.getElementById('btn-form-save').textContent") == "Prepara l'etichetta", tp.evaluate("document.getElementById('rp-n').value"))
    tp.click('#btn-form-save'); tp.wait_for_timeout(2500)
    href = tp.evaluate("(document.querySelector('#form a.btn') || {}).href || ''")
    q = parse_qs(urlparse(href).query)
    check('PRINT-08 the label link is built from the database; the reprint counted with who', q.get('code') == ['LOT:LE103-A'] and q.get('name') == [PNAME] and q.get('sub') == [f'scad. {EXP}'] and q.get('n') == ['6']
          and sql1("select reprinted_count || '|' || (last_reprinted_by_id is not null) from fabula.labels where code = 'LOT:LE103-A'") == '1|true', href)
    tp.goto(href); tp.wait_for_timeout(2500)
    st = tp.evaluate("({ st: document.getElementById('st').innerText, cls: document.getElementById('st').className, n: document.querySelectorAll('#g .l').length, ro: document.getElementById('src').readOnly, edit: !document.getElementById('edit').hidden })")
    check('PRINT-08 labels.html: 6 labels checked on the database, the lines read-only («Modifica a mano»)', st['n'] == 6 and 'ok' in st['cls'] and 'controllat' in st['st'] and st['ro'] and st['edit'], json.dumps(st))
    tp.goto(f'http://localhost:{PORT}/labels.html?code=LOT:le103-a&name=Mozzarella&sub=scad.%2001/01/2020&n=1'); tp.wait_for_timeout(2500)
    cell = tp.evaluate("document.querySelector('#g .l').innerText.replace(/\\s+/g, ' ')")
    check('PRINT-08 a wrong expiry in the link: name, lot and expiry from the database, «corretto»', f'scad. {EXP}' in cell and PNAME in cell and 'LOT:LE103-A' in cell and 'corretto' in cell and '2020' not in cell, cell)
    tp.goto(f'http://localhost:{PORT}/labels.html?code=LOT:LE103-Z&name=Mozzarella&sub=scad.%2020/02/2027&n=1'); tp.wait_for_timeout(2500)
    cell = tp.evaluate("document.querySelector('#g .l').innerText.replace(/\\s+/g, ' ')")
    check('PRINT-08 a link to a lot that is neither in the database nor waiting on this tablet: red, not printed', 'Lotto sconosciuto' in cell
          and tp.evaluate("document.querySelectorAll('#g .l.ko').length") == 1, cell)
    tp.evaluate("localStorage.setItem('fabula_queue', JSON.stringify([{ id: 'q1', ops: [{ table: 'production_batches', row: { batch_lot: 'LE103-Z' } }] }]))")
    tp.goto(f'http://localhost:{PORT}/labels.html?code=LOT:LE103-Z&name=Mozzarella&sub=scad.%2020/02/2027&n=1'); tp.wait_for_timeout(2500)
    cell = tp.evaluate("document.querySelector('#g .l').innerText.replace(/\\s+/g, ' ')")
    check('PRINT-08 …the same lot waiting in the tablet\'s queue (saved without network): printed, with the amber note', 'In attesa di invio dal tablet' in cell
          and tp.evaluate("document.querySelectorAll('#g .l.ko').length") == 0 and 'amb' in tp.evaluate("document.getElementById('st').className"), cell)
    tp.evaluate("localStorage.setItem('fabula_queue', '[]')")
    tp.goto(f'http://localhost:{PORT}/labels.html?code=LOT:LE103-B&name=Mozzarella&sub=scad.%2020/10/2026&n=1'); tp.wait_for_timeout(2500)
    cell = tp.evaluate("document.querySelector('#g .l').innerText.replace(/\\s+/g, ' ')")
    check('PRINT-08 a close label for a lot the database still has open (close waiting to be sent): printed as the tablet wrote it, amber',
          'scad. 20/10/2026' in cell and 'Chiusura del lotto non ancora nel database' in cell and 'in lavorazione' not in cell, cell)
    tp.goto(f'http://localhost:{PORT}/labels.html'); tp.wait_for_timeout(1500)
    tp.fill('#src', 'LOT:LE103-Y | Mozzarella | scad. 20/02/2027\nLOT:LE103-A | Mozzarella | scad. 01/01/2020\nEQ:CF-01 | Cella frigo 1'); tp.click('#gen'); tp.wait_for_timeout(2500)
    st = tp.evaluate("({ st: document.getElementById('st').innerText, cls: document.getElementById('st').className, ko: document.querySelectorAll('#g .l.ko').length, n: document.querySelectorAll('#g .l').length })")
    tp.emulate_media(media='print'); tp.wait_for_timeout(200)
    vis = tp.evaluate("[...document.querySelectorAll('#g .l')].map(d => getComputedStyle(d).display !== 'none')")
    tp.emulate_media(media='screen')
    check('PRINT-08 a lot typed by hand that does not exist: red, «non verrà stampato», hidden in print; the others print',
          st['ko'] == 1 and st['n'] == 3 and 'ko' in st['cls'] and 'sconosciuto' in st['st'] and vis == [False, True, True], json.dumps(st) + ' ' + str(vis))
    ctx.close()
    ctx, np = page_as(b, None, 'labels.html?code=LOT:LE103-A&name=Mozzarella&sub=scad.%2001/01/2020&n=1', logs, 800)
    np.wait_for_timeout(2500)
    check('PRINT-08 no login: the page says the lots were NOT checked', 'NON controllati' in text(np, '#st') and 'non sei collegato' in text(np, '#st'), text(np, '#st'))
    ctx.close()

    errs = [l for l in logs if 'PAGEERROR' in l]
    check('no page errors', not errs, ' | '.join(errs[:3]))
finally:
    srv.terminate(); proxy.shutdown()
    try: os.killpg(fnp.pid, 15)
    except Exception: fnp.terminate()
    out = fnp.stdout.read() if fnp.stdout else ''
    bad = [l for l in out.splitlines() if 'error' in l.lower() and 'listening' not in l.lower()]
    if bad: print('farm-order log:', ' | '.join(bad[:5]))
print('FAILURES:', fails or 'none')
