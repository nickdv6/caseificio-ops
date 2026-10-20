"""v1.10 «Sicurezza e salvataggi» in the browser, against the local copy (restore_drill + setup.sql + PostgREST on :3000, v110a/b applied),
with the REAL server functions `invite-user` and `welcome` run by Deno (DENO=…) behind the same small fake Supabase as v109_e2e (:8792).
The browser runs in Italian. Pages on :8789. Quality test 20/10/2026 (claude/quality-test-2026-10-20.md):
- item 3: a CCP reading whose reply is lost after the database saved it is written ONCE (the re-send carries the same save id);
- item 12: with the tablet's storage full, an offline save says «Memoria del tablet piena», never «Salvato offline»;
- item 11: a product name with HTML in the incoming-goods list is shown as text, not run;
- item 4: Autocontrollo → «Correggi» reads «1.050» kg as 1050 (it saved 1,05);
- item 1: a socio sees the app's address as text in Configurazione (the database refuses the change too); the titolare can edit it;
  invite-user builds the access link on app.bubalina.it even when the setting names another site;
- item 10: «Cambia email» to the address already on the row moves a login still on the old address;
- the welcome page opened with no link says where the link comes from; a password refused for its kinds of character says so.
Expect "FAILURES: none"."""
import json, os, subprocess, threading, time, hmac, hashlib, base64, urllib.request, urllib.error, re, shutil
from urllib.parse import urlparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from playwright.sync_api import sync_playwright
from e2e_op import op_js, answer_ask

DENO = os.environ.get('DENO', '/tmp/claude-0/denoinst/node_modules/.bin/deno')
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '../../../../fabula-tablet'))
FNS = os.path.abspath(os.path.join(HERE, '../../../../supabase/functions'))
REF = 'ojkquhzaeypsphncjqwy'; PORT = 8789; FAKE = 8792; FN_PORT = {'welcome': 8803, 'invite-user': 8804}
SECRET = b"test-secret-test-secret-test-secret-0123456789"
def _b64(b): return base64.urlsafe_b64encode(b).rstrip(b'=').decode()
def _jwt(claims):
    h = _b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode()); p = _b64(json.dumps({"exp": int(time.time()) + 86400, **claims}).encode())
    return h + '.' + p + '.' + _b64(hmac.new(SECRET, (h + '.' + p).encode(), hashlib.sha256).digest())
def user_jwt(sub, email): return _jwt({"sub": sub, "role": "authenticated", "email": email, "aud": "authenticated"})
def claims_of(auth):
    try: return json.loads(base64.urlsafe_b64decode(auth.split(' ')[-1].split('.')[1] + '=='))
    except Exception: return {}
def sql(qs):
    r = subprocess.run(['su', 'postgres', '-c', 'psql -At -q -d restore_drill'], input=qs, capture_output=True, text=True)
    if 'ERROR' in r.stderr: print('SQL ERROR:', qs[:90], '→', r.stderr.strip()[:300])
    return r.stdout.strip() or r.stderr.strip()
def sql1(qs): return (sql(qs).splitlines() or [''])[0]
q = lambda s: "'" + str(s).replace("'", "''") + "'"
fails = []
def check(name, cond, info=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f'  [{str(info)[:300]}]' if info != '' else ''), flush=True)
    if not cond: fails.append(name)

# ---------------------------------------------------------------- fake Supabase (as v109_e2e): /rest/v1 → PostgREST, /auth/v1/admin on auth.users
def user_json(uid):
    r = sql1(f"select json_build_object('id', id, 'email', email, 'aud', 'authenticated', 'role', 'authenticated', 'email_confirmed_at', email_confirmed_at, "
             f"'last_sign_in_at', last_sign_in_at, 'created_at', created_at, 'banned_until', banned_until, 'app_metadata', '{{}}'::json, 'user_metadata', coalesce(raw_user_meta_data, '{{}}')) "
             f"from auth.users where id = {q(uid)}")
    return json.loads(r) if r.startswith('{') else None
class Fake(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, body, ctype='application/json', hdr=None):
        b = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code); self.send_header('Content-Type', ctype); self.send_header('Content-Length', str(len(b)))
        for k, v in (hdr or {}).items(): self.send_header(k, v)
        self.end_headers(); self.wfile.write(b)
    def _body(self):
        n = int(self.headers.get('Content-Length') or 0); return self.rfile.read(n) if n else b''
    def _proxy(self):
        data = self._body() or None
        url = 'http://127.0.0.1:3000/' + self.path.split('/rest/v1/', 1)[1]
        hdr = {k: v for k, v in self.headers.items() if k.lower() in ('authorization', 'content-type', 'accept', 'accept-profile', 'content-profile', 'prefer', 'apikey')}
        req = urllib.request.Request(url, data=data, method=self.command, headers=hdr)
        try:
            with urllib.request.urlopen(req) as r: self._send(r.status, r.read(), r.headers.get('Content-Type', 'application/json'))
        except urllib.error.HTTPError as e: self._send(e.code, e.read(), e.headers.get('Content-Type', 'application/json'))
    def _admin(self):
        path = urlparse(self.path).path; m = re.search(r'/auth/v1/admin/users/([0-9a-f-]{36})$', path)
        if self.command == 'GET' and path.endswith('/admin/users'):
            rows = sql1("select coalesce(json_agg(id), '[]') from auth.users")
            return self._send(200, {'users': [user_json(i) for i in json.loads(rows)], 'aud': 'authenticated'}, hdr={'x-total-count': '0'})
        if self.command == 'GET' and m:
            u = user_json(m.group(1)); return self._send(200, u) if u else self._send(404, {'code': 404, 'msg': 'User not found'})
        if self.command in ('PUT', 'POST'):
            a = json.loads(self._body() or b'{}')
            if 'password' in a:
                if len(a['password']) < 8: return self._send(422, {'code': 422, 'msg': 'Password should be at least 8 characters'})
                if a['password'].islower(): return self._send(422, {'code': 422, 'error_code': 'weak_password',
                    'msg': 'Password should contain at least one character of each: abcdefghijklmnopqrstuvwxyz, ABCDEFGHIJKLMNOPQRSTUVWXYZ, 0123456789.'})
            if self.command == 'POST':
                if sql1(f"select count(*) from auth.users where lower(email) = lower({q(a.get('email'))})") != '0': return self._send(422, {'code': 422, 'msg': 'A user with this email address has already been registered'})
                uid = sql1(f"insert into auth.users (email, raw_user_meta_data) values (lower({q(a.get('email'))}), {q(json.dumps(a.get('user_metadata') or {}))}::jsonb) returning id")
            else: uid = m.group(1)
            sets = []
            if 'password' in a: sets.append(f"encrypted_password = {q('set:' + a['password'])}")
            if 'email' in a:
                if sql1(f"select count(*) from auth.users where lower(email) = lower({q(a['email'])}) and id <> {q(uid)}") != '0': return self._send(422, {'code': 422, 'msg': 'A user with this email address has already been registered'})
                sets.append(f"email = lower({q(a['email'])})")
            if a.get('email_confirm'): sets.append('email_confirmed_at = coalesce(email_confirmed_at, now())')
            if a.get('ban_duration') == 'none': sets.append('banned_until = null')
            elif a.get('ban_duration'): sets.append("banned_until = now() + interval '100 years'")
            if sets: sql(f"update auth.users set {', '.join(sets)} where id = {q(uid)}")
            return self._send(200, user_json(uid))
        return self._send(404, {})
    def do_GET(self):
        if '/rest/v1/' in self.path: return self._proxy()
        if '/auth/v1/admin/' in self.path: return self._admin()
        if self.path.startswith('/auth/v1/user'):
            c = claims_of(self.headers.get('Authorization', '')); u = user_json(c.get('sub')) if c.get('sub') else None
            return self._send(200, u) if u else self._send(401, {'code': 401, 'msg': 'invalid JWT'})
        self._send(404, {})
    def do_POST(self):
        if '/rest/v1/' in self.path: return self._proxy()
        if '/auth/v1/admin/' in self.path: return self._admin()
        self._send(404, {})
    def do_PATCH(self): return self._proxy()
    def do_DELETE(self): return self._proxy()
    def do_PUT(self): return self._admin()
srv = ThreadingHTTPServer(('127.0.0.1', FAKE), Fake); threading.Thread(target=srv.serve_forever, daemon=True).start()

WORK = '/tmp/v110fn'; shutil.rmtree(WORK, ignore_errors=True); os.makedirs(WORK)
open(f'{WORK}/run.ts', 'w').write("""const [file, port] = Deno.args;
const orig = Deno.serve.bind(Deno);
// deno-lint-ignore no-explicit-any
(Deno as any).serve = (a: any, b?: any) => typeof a === 'function' ? orig({ port: Number(port) }, a) : orig({ ...a, port: Number(port) }, b);
await import('file://' + file);
""")
env = dict(os.environ, SUPABASE_URL=f'http://127.0.0.1:{FAKE}', SUPABASE_SERVICE_ROLE_KEY=_jwt({'role': 'service_role'}), SUPABASE_ANON_KEY=_jwt({'role': 'anon'}),
           DENO_DIR=os.environ.get('DENO_DIR', '/tmp/claude-0/denocache'))
env.pop('SITE_URL', None); env.pop('SITE_HOSTS', None)
procs = []
for name, port in FN_PORT.items():
    src = open(f'{FNS}/{name}/index.ts').read().replace('import "jsr:@supabase/functions-js/edge-runtime.d.ts";', '')
    open(f'{WORK}/{name}.ts', 'w').write(src)
    procs.append(subprocess.Popen([DENO, 'run', '--allow-net', '--allow-env', '--allow-read', f'{WORK}/run.ts', f'{WORK}/{name}.ts', str(port)], env=env,
                                  stdout=open(f'{WORK}/{name}.log', 'w'), stderr=subprocess.STDOUT, start_new_session=True))
for port in FN_PORT.values():
    for _ in range(90):
        try: urllib.request.urlopen(urllib.request.Request(f'http://127.0.0.1:{port}/', method='OPTIONS'), timeout=1); break
        except Exception: time.sleep(1)
srv_pages = subprocess.Popen(['python3', '-m', 'http.server', str(PORT)], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1)
def fn(name, body, who=None):
    hdr = {'Content-Type': 'application/json'}
    if who: hdr['Authorization'] = 'Bearer ' + user_jwt(*who)
    req = urllib.request.Request(f'http://127.0.0.1:{FN_PORT[name]}/', data=json.dumps(body).encode(), method='POST', headers=hdr)
    try:
        with urllib.request.urlopen(req) as r: return r.status, json.loads(r.read() or b'{}')
    except urllib.error.HTTPError as e: return e.code, json.loads(e.read() or b'{}')

# ---------------------------------------------------------------- data
RUN = time.strftime('%H%M%S')
OWNER = ("00000000-0000-4000-a000-0000000000c1", "office@test.it")
sql(f"insert into auth.users(id, email, email_confirmed_at, encrypted_password, last_sign_in_at) values ('{OWNER[0]}', '{OWNER[1]}', now(), 'x', now()) on conflict (id) do update set banned_until = null")
sql(f"insert into fabula.staff(id, full_name, auth_user_id, app_role, role, active, email) values ('10000000-0000-4000-a000-0000000000c1', 'Owner Office', '{OWNER[0]}', 'titolare', 'owner', true, '{OWNER[1]}') on conflict (id) do update set active = true, app_role = 'titolare'")
CASARO = ("00000000-0000-4000-a000-000000000001", "casaro@test.it")
SOCIO = (f'00000000-0000-4000-a000-00000{RUN}5', f'socio{RUN}@test.it')
sql(f"insert into auth.users(id, email, email_confirmed_at, encrypted_password, last_sign_in_at) values ('{SOCIO[0]}', '{SOCIO[1]}', now(), 'set:Socio12345', now())")
sql(f"insert into fabula.staff(full_name, auth_user_id, app_role, role, active, email) values ('Sandro Socio{RUN}', '{SOCIO[0]}', 'socio', 'partner', true, '{SOCIO[1]}')")
SITE0 = sql1("select value from fabula.settings where key = 'infra.site_url'")
TODAY = sql1("select (now() at time zone 'Europe/Rome')::date")
sup = sql1("select id from fabula.parties where is_milk_supplier and active order by created_at limit 1")
MLOT = 'MV' + RUN
sql(f"insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source) values ('{TODAY}', (now() at time zone 'Europe/Rome')::time, '{sup}', '{MLOT}', 1000, true, 4, 'tablet')")
EVIL = f'<img src=x onerror="window.__xss=1">Caglio{RUN}'
PROD = sql1(f"insert into fabula.products (sku, name, kind, unit, active) values ('XSS{RUN}', {q(EVIL)}, 'consumable', 'kg', true) returning id")
SUPP = sql1(f"insert into fabula.parties (type, legal_name, active) values ('supplier', 'Fornitore V110 {RUN}', true) returning id")

def session_for(uid, email):
    return {"access_token": user_jwt(uid, email), "refresh_token": "r", "expires_at": int(time.time()) + 86400, "expires_in": 86400, "token_type": "bearer",
            "user": {"id": uid, "email": email, "aud": "authenticated", "role": "authenticated"}}
state = {'off': False, 'drop_save_ops': 0}
def handler_for(s):
    def handler(route):
        try: return handler_(route)
        except Exception as e:
            if 'closed' not in str(e) and 'already handled' not in str(e): raise
    def handler_(route):
        u = route.request.url; H = {'access-control-allow-origin': '*', 'access-control-allow-headers': '*'}
        if state['off']: return route.abort('internetdisconnected')
        for name, port in FN_PORT.items():
            if f'/functions/v1/{name}' in u:
                if route.request.method == 'OPTIONS': return route.fulfill(status=200, headers=H, body='ok')
                return route.fulfill(response=route.fetch(url=f'http://127.0.0.1:{port}/'))
        if '/rest/v1/' in u:
            r = route.fetch(url='http://127.0.0.1:3000/' + u.split('/rest/v1/', 1)[1])
            if re.search(r'/rpc/(save_ops|log_ccp)\b', u) and state['drop_save_ops'] > 0 and r.status < 300:   # whichever call writes it (save_ops since v1.10)
                state['drop_save_ops'] -= 1
                return route.abort('connectionreset')            # the database saved it, the reply is lost on the way back
            return route.fulfill(response=r)
        if '/auth/v1/token' in u and 'grant_type=password' in u:
            b = json.loads(route.request.post_data or '{}'); uid = sql1(f"select id from auth.users where lower(email) = lower({q(b.get('email'))}) and encrypted_password = {q('set:' + str(b.get('password')))} and banned_until is null")
            if not uid: return route.fulfill(status=400, content_type='application/json', headers=H, body=json.dumps({'error': 'invalid_grant', 'error_description': 'Invalid login credentials', 'msg': 'Invalid login credentials'}))
            sess = session_for(uid, b.get('email')); s.clear(); s.update(sess)
            return route.fulfill(status=200, content_type='application/json', headers=H, body=json.dumps(sess))
        if '/auth/v1/logout' in u: s.clear(); return route.fulfill(status=204, headers=H, body='')
        if '/auth/v1/' in u: return route.fulfill(status=200, content_type='application/json', headers=H, body=json.dumps(s.get('user') or {}))
        return route.fulfill(status=200, body='{}', headers=H)
    return handler
def page_as(b, who, path, logs, width=1100, init=''):
    s = session_for(*who) if who else {}
    ctx = b.new_context(service_workers='block', viewport={'width': width, 'height': 1300}, locale='it-IT'); ctx.route('**/*.supabase.co/**', handler_for(s))
    ctx.add_init_script("window.__off=false;Object.defineProperty(Navigator.prototype,'onLine',{get:()=>!window.__off});" + init)
    pg = ctx.new_page(); pg.on('pageerror', lambda e: logs.append('PAGEERROR ' + str(e)))
    pg.goto(f'http://localhost:{PORT}/labels.html')
    pg.evaluate("localStorage.clear()" + (f"; localStorage.setItem('sb-{REF}-auth-token', {json.dumps(json.dumps(s))}){op_js(s)}" if s else ''))
    pg.goto(f'http://localhost:{PORT}/{path}')
    return ctx, pg
toast = lambda pg: pg.evaluate("(document.getElementById('toast') || {}).textContent || ''")

try:
  with sync_playwright() as p:
    b = p.chromium.launch(); logs = []
    # ================= the floor tablet =================
    ctx, tp = page_as(b, CASARO, 'index.html', logs, width=800)
    tp.wait_for_function("document.querySelector('#v-home.active')", timeout=20000); tp.wait_for_timeout(4000)
    def code(c): tp.evaluate("c => { document.getElementById('manual').value = c; document.getElementById('btn-manual').click(); }", c); tp.wait_for_timeout(1800)
    def setf(vals):
        for k, v in vals.items(): tp.evaluate("([k, v]) => { const e = document.getElementById(k); e.value = v; e.dispatchEvent(new Event('change')); e.dispatchEvent(new Event('input')); }", [k, str(v)])
    def save(): tp.evaluate("document.getElementById('btn-form-save').click()"); tp.wait_for_timeout(900)
    CF1 = "select count(*) from fabula.haccp_log l join fabula.haccp_control_points c on c.id = l.control_point_id where c.code = 'CCP-COLD-1'"
    queue = lambda: tp.evaluate("JSON.parse(localStorage.getItem('fabula_queue')||'[]')")
    # item 3: the reply of the save is lost after the database wrote it
    n0 = int(sql1(CF1))
    state['drop_save_ops'] = 1
    code('CCP:CCP-COLD-1'); setf({'v': '3'}); save(); answer_ask(tp, wait=300); tp.wait_for_timeout(1500)
    lost_toast = toast(tp)
    tp.evaluate("dispatchEvent(new Event('online'))"); tp.wait_for_timeout(6000)
    n2 = int(sql1(CF1))
    led = sql1("select count(*) from fabula.save_ledger where created_at > now() - interval '5 minutes'")
    check('item 3: a reading whose reply was lost after the database wrote it is written ONCE when sent again (before: 2 rows), the queue empties',
          state['drop_save_ops'] == 0 and n2 == n0 + 1 and len(queue()) == 0 and led != '0', f'{lost_toast} · rows +{n2 - n0} · queue {len(queue())} · ledger {led}')
    # item 12: storage full while offline
    tp.evaluate("""(() => { const o = Storage.prototype.setItem; window.__full = true;
      Storage.prototype.setItem = function (k, v) { if (window.__full && k === 'fabula_queue') { const e = new Error('QuotaExceededError'); e.name = 'QuotaExceededError'; throw e; } return o.call(this, k, v); }; })()""")
    state['off'] = True; tp.evaluate("window.__off=true; dispatchEvent(new Event('offline'))")
    code('CCP:CCP-COLD-1'); setf({'v': '3'}); save(); answer_ask(tp, wait=300); tp.wait_for_timeout(800)
    t = toast(tp)
    check('item 12: storage full, offline: «Memoria del tablet piena … NON è salvata», never «Salvato offline»', 'Memoria del tablet piena' in t and 'Salvato offline' not in t and len(queue()) == 0, t)
    tp.evaluate("window.__full = false; window.__off=false; dispatchEvent(new Event('online'))"); state['off'] = False; tp.wait_for_timeout(1500)
    # item 11: a product name with HTML in the incoming-goods list
    POID = sql1(f"insert into fabula.purchase_orders (po_number, supplier_id, status, order_date, expected_date) values ('PO-V110-{RUN}', '{SUPP}', 'sent', '{TODAY}', '{TODAY}') returning id")
    sql(f"insert into fabula.purchase_order_lines (purchase_order_id, product_id, qty_ordered, unit_price_eur, iva_rate) values ('{POID}', '{PROD}', 5, 2, 22)")
    po_ok = sql1(f"select count(*) from fabula.v_open_purchase_orders where supplier = 'Fornitore V110 {RUN}'")
    tp.evaluate("document.querySelectorAll('.view').forEach(e => e.classList.toggle('active', e.id === 'v-home'))")
    tp.evaluate("document.getElementById('btn-receive').click()"); tp.wait_for_timeout(2500)
    shown = tp.evaluate(f"(() => {{ const d = [...document.querySelectorAll('#form .task')].find(x => x.textContent.includes('Fornitore V110 {RUN}')); return d ? d.innerText : ''; }})()")
    check('item 11: a product name with HTML is shown as text in «Arrivo merce», no script runs', po_ok != '0' and '<img' in shown and tp.evaluate("!window.__xss"), f'{po_ok} | {shown[:160]}')
    ctx.close()

    # ================= Autocontrollo: correcting a milk arrival =================
    ctx, hp = page_as(b, OWNER, 'haccp.html', logs)
    hp.wait_for_timeout(3500)
    hp.evaluate("(() => { const t = document.querySelector('.tab[data-tab=\"registro\"]'); if (t) t.click(); })()"); hp.wait_for_timeout(1500)
    mid = sql1(f"select id from fabula.milk_intake where milk_lot = '{MLOT}'")
    clicked = hp.evaluate(f"(() => {{ const b = document.querySelector('[data-fixmi=\"{mid}\"]'); if (!b) return false; b.click(); return true; }})()"); hp.wait_for_timeout(600)
    if clicked:
        hp.fill('#fx-kg', '1.050'); hp.select_option('#fx-why', 'pesata di nuovo'); hp.click('#dlg-ok'); hp.wait_for_timeout(2500)
    kg = sql1(f"select qty_kg from fabula.milk_intake where milk_lot = '{MLOT}'")
    check('item 4: «Correggi» on a milk arrival reads «1.050» as 1.050 kg (it saved 1,05 kg)', clicked and kg != '' and float(kg) == 1050, f'{clicked} · {kg} · {toast(hp)}')
    ctx.close()

    # ================= Configurazione: the app's address =================
    ctx, sp = page_as(b, SOCIO, 'admin.html', logs)
    sp.wait_for_timeout(3500); sp.click('.tab[data-tab="parametri"]'); sp.wait_for_timeout(1500)
    sp.fill('#p-q', 'infra.site_url'); sp.evaluate("document.getElementById('p-q').dispatchEvent(new Event('input'))"); sp.wait_for_timeout(800)
    ro = sp.evaluate("(() => { const r = document.querySelector('.set-row[data-key=\"infra.site_url\"]'); return r ? { ro: !!r.querySelector('.ro'), input: !!r.querySelector('input,textarea') } : null; })()")
    check('item 1: a socio sees the app\'s address as text, with nothing to edit', ro and ro['ro'] and not ro['input'], ro)
    ctx.close()
    ctx, op = page_as(b, OWNER, 'admin.html', logs)
    op.wait_for_timeout(3500); op.click('.tab[data-tab="parametri"]'); op.wait_for_timeout(1500)
    op.fill('#p-q', 'infra.site_url'); op.evaluate("document.getElementById('p-q').dispatchEvent(new Event('input'))"); op.wait_for_timeout(800)
    ed = op.evaluate("(() => { const r = document.querySelector('.set-row[data-key=\"infra.site_url\"]'); return r ? !!r.querySelector('input,textarea') : null; })()")
    check('item 1: …the titolare can edit it', ed is True, ed)
    ctx.close()

    # ================= invite-user and welcome =================
    sql("update fabula.settings set value = 'https://app.bubalina.it.evil.example' where key = 'infra.site_url'")
    PER = sql1(f"insert into fabula.staff (full_name, app_role, role, active, email) values ('Pia Link{RUN}', 'banco', 'commesso', true, 'pia{RUN}@test.it') returning id")
    st, r = fn('invite-user', {'action': 'access_link', 'staff_id': PER}, OWNER)
    link = r.get('link', '')
    check('item 1: with the setting pointing at another site, the access link is still built on https://app.bubalina.it', st == 200 and link.startswith('https://app.bubalina.it/benvenuto.html#invito='), f'{st} {link[:70]}')
    sql(f"update fabula.settings set value = {q(SITE0)} where key = 'infra.site_url'")
    tok = link.split('#invito=', 1)[-1]
    st, r = fn('welcome', {'action': 'redeem', 'token': tok, 'password': 'tuttominuscole'})
    check('a password refused for its kinds of character says so (not «almeno 8 caratteri»)', r.get('reason') == 'weak' and 'maiuscole' in r.get('message', ''), r)
    st, r = fn('welcome', {'action': 'redeem', 'token': tok, 'password': 'Buona2026x'})
    check('…a good password then works with the same link', r.get('ok') is True, r)
    # item 10: the row already has the new address, the login still the old one
    U10, S10 = f'00000000-0000-4000-a000-00000{RUN}a', f'10000000-0000-4000-a000-00000{RUN}a'
    sql(f"insert into auth.users(id, email, email_confirmed_at, encrypted_password) values ('{U10}', 'vecchia{RUN}@test.it', now(), 'set:Vecchia123')")
    sql(f"insert into fabula.staff(id, full_name, auth_user_id, app_role, role, active, email) values ('{S10}', 'Ugo Mail{RUN}', '{U10}', 'banco', 'commesso', true, 'nuova{RUN}@test.it')")
    st, r = fn('invite-user', {'action': 'update_email', 'staff_id': S10, 'email': f'nuova{RUN}@test.it'}, OWNER)
    em = sql1(f"select email from auth.users where id = '{U10}'")
    check('item 10: «Cambia email» to the address on the row moves the login still on the old one (it answered «unchanged»)', st == 200 and em == f'nuova{RUN}@test.it' and not r.get('unchanged'), f'{st} {r} {em}')
    st, r = fn('invite-user', {'action': 'update_email', 'staff_id': S10, 'email': f'nuova{RUN}@test.it'}, OWNER)
    check('…and once both agree it answers «unchanged»', r.get('unchanged') is True, r)

    # ================= the welcome page with no link =================
    ctx, wp = page_as(b, None, 'benvenuto.html', logs, width=390)
    wp.wait_for_timeout(2500)
    sub = wp.evaluate("document.getElementById('sub').textContent")
    check('the welcome page opened with no link says the link comes from the titolare (not «scaduto o già usato»)', 'si apre dal link di accesso' in sub and 'scaduto o è già stato usato' not in sub, sub)
    ctx.close()

    pe = [x for x in logs if x.startswith('PAGEERROR')]
    check('no page errors', not pe, pe[:3])
    b.close()
finally:
    srv_pages.terminate(); srv.shutdown()
    for pr in procs:
        try: os.killpg(pr.pid, 15)
        except Exception: pass
    for name in FN_PORT:
        try:
            lg = open(f'{WORK}/{name}.log').read()
            if 'error' in lg.lower(): print(f'--- {name} log:', lg[-600:])
        except Exception: pass
print('FAILURES: ' + (', '.join(fails) if fails else 'none'))
