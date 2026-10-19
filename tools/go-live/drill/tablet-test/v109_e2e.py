"""v1.09 «Persone» in the browser, against the local copy (restore_drill + setup.sql + PostgREST on :3000, v109a applied), with the
REAL server functions `invite-user` and `welcome` run by Deno (DENO=…, as notify_fn_e2e) behind a small fake Supabase on :8791 that
forwards /rest/v1 to PostgREST and plays Supabase's auth admin API on auth.users (a password is stored as «set:<password>»).
The browser runs in Italian. Pages on :8783.
- Configurazione → Persone: one card per person with the checklist; «Aggiungi una persona» with an e-mail shows the access link at
  once (WhatsApp, e-mail, a week, the company's name, the profile's page); the same e-mail again opens that card.
- C-17: the profile sets the job role; making someone Titolare asks first.
- C-13: «Cambia email» of someone with a login changes the login e-mail too (and asks first).
- The welcome page (#invito=…): greets by name, checks the password, sets it with the server function, signs in, offers Telegram,
  then the profile's page; the same link again says it was used; an older link says it was replaced.
- C-14: «Disattiva» lists what will happen, then closes the open shift, removes the future rota, blocks the login and shows what is
  still in the person's name. C-15: adding the same e-mail again says «Riattiva»; «Riattiva» unblocks.
- C-23: «Cambia password» is in the user menu of a profile without Configurazione; a wrong current password is refused.
- B-26: the rota cell editor: times, break, area, «Anche questi giorni», a night shift only when ticked, riposo; saved and shown again.
Expect "FAILURES: none"."""
import json, os, subprocess, threading, time, hmac, hashlib, base64, urllib.request, urllib.error, re, shutil, datetime
from urllib.parse import urlparse, parse_qs, unquote
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from playwright.sync_api import sync_playwright
from e2e_op import op_js

DENO = os.environ.get('DENO', '/tmp/claude-0/denoinst/node_modules/.bin/deno')
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '../../../../fabula-tablet'))
FNS = os.path.abspath(os.path.join(HERE, '../../../../supabase/functions'))
REF = 'ojkquhzaeypsphncjqwy'; PORT = 8783; FAKE = 8791; FN_PORT = {'welcome': 8801, 'invite-user': 8802}
SECRET = b"test-secret-test-secret-test-secret-0123456789"
def _b64(b): return base64.urlsafe_b64encode(b).rstrip(b'=').decode()
def _jwt(claims):
    h = _b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode()); p = _b64(json.dumps({"exp": int(time.time()) + 86400, **claims}).encode())
    return h + '.' + p + '.' + _b64(hmac.new(SECRET, (h + '.' + p).encode(), hashlib.sha256).digest())
def user_jwt(sub, email): return _jwt({"sub": sub, "role": "authenticated", "email": email, "aud": "authenticated"})
def claims_of(auth):
    try: return json.loads(base64.urlsafe_b64decode(auth.split(' ')[-1].split('.')[1] + '=='))
    except Exception: return {}
def sql(q):   # the query goes in on stdin: no shell quoting to get wrong (JSON has double quotes)
    r = subprocess.run(['su', 'postgres', '-c', 'psql -At -q -d restore_drill'], input=q, capture_output=True, text=True)
    if 'ERROR' in r.stderr: print('SQL ERROR:', q[:90], '→', r.stderr.strip()[:300])
    return r.stdout.strip() or r.stderr.strip()
def sql1(q): return (sql(q).splitlines() or [''])[0]
q = lambda s: "'" + str(s).replace("'", "''") + "'"
fails = []
def check(name, cond, info=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f'  [{str(info)[:300]}]' if info != '' else ''), flush=True)
    if not cond: fails.append(name)

# ---------------------------------------------------------------- fake Supabase: /rest/v1 → PostgREST, /auth/v1/admin on auth.users
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
            if 'password' in a:   # checked before anything is written, as Supabase does
                if len(a['password']) < 8: return self._send(422, {'code': 422, 'msg': 'Password should be at least 8 characters'})
                if a['password'] == 'password123': return self._send(422, {'code': 422, 'error_code': 'weak_password', 'msg': 'Password is known to be weak and easy to guess, please choose a different one.'})
            if self.command == 'POST':
                if sql1(f"select count(*) from auth.users where lower(email) = lower({q(a.get('email'))})") != '0': return self._send(422, {'code': 422, 'msg': 'A user with this email address has already been registered'})
                uid = sql1(f"insert into auth.users (email, raw_user_meta_data) values (lower({q(a.get('email'))}), {q(json.dumps(a.get('user_metadata') or {}))}::jsonb) returning id")
            else: uid = m.group(1)
            sets = []
            if 'password' in a: sets.append(f"encrypted_password = {q('set:' + a['password'])}")
            if 'email' in a: sets.append(f"email = lower({q(a['email'])})")
            if a.get('email_confirm'): sets.append('email_confirmed_at = coalesce(email_confirmed_at, now())')
            if a.get('ban_duration') == 'none': sets.append('banned_until = null')
            elif a.get('ban_duration'): sets.append("banned_until = now() + interval '100 years'")
            if sets: sql(f"update auth.users set {', '.join(sets)} where id = {q(uid)}")
            ADMIN_CALLS.append((self.command, uid, sorted(a.keys())))
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
ADMIN_CALLS = []
srv = ThreadingHTTPServer(('127.0.0.1', FAKE), Fake); threading.Thread(target=srv.serve_forever, daemon=True).start()

# ---------------------------------------------------------------- the two server functions, as written (without the type-only jsr import)
WORK = '/tmp/v109fn'; shutil.rmtree(WORK, ignore_errors=True); os.makedirs(WORK)
open(f'{WORK}/run.ts', 'w').write("""const [file, port] = Deno.args;
const orig = Deno.serve.bind(Deno);
// deno-lint-ignore no-explicit-any
(Deno as any).serve = (a: any, b?: any) => typeof a === 'function' ? orig({ port: Number(port) }, a) : orig({ ...a, port: Number(port) }, b);
await import('file://' + file);
""")
env = dict(os.environ, SUPABASE_URL=f'http://127.0.0.1:{FAKE}', SUPABASE_SERVICE_ROLE_KEY=_jwt({'role': 'service_role'}), SUPABASE_ANON_KEY=_jwt({'role': 'anon'}),
           DENO_DIR=os.environ.get('DENO_DIR', '/tmp/claude-0/denocache'))
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

# ---------------------------------------------------------------- data
RUN = time.strftime('%H%M%S')
OWNER = ("00000000-0000-4000-a000-0000000000c1", "office@test.it")
sql(f"insert into auth.users(id, email, email_confirmed_at, encrypted_password, last_sign_in_at) values ('{OWNER[0]}', '{OWNER[1]}', now(), 'x', now()) on conflict (id) do update set banned_until = null")
sql(f"insert into fabula.staff(id, full_name, auth_user_id, app_role, role, active, email) values ('10000000-0000-4000-a000-0000000000c1', 'Owner Office', '{OWNER[0]}', 'titolare', 'owner', true, '{OWNER[1]}') on conflict (id) do update set active = true, app_role = 'titolare'")
CASARO = ("00000000-0000-4000-a000-000000000001", "casaro@test.it")
COMPANY = sql1("select value from fabula.settings where key = 'company.name'")
GIADA, GMAIL = f'Giada Prova{RUN}', f'giada{RUN}@test.it'
BRUNA_U, BRUNA_S, BMAIL = f'00000000-0000-4000-a000-00000{RUN}b', f'10000000-0000-4000-a000-00000{RUN}b', f'bruna{RUN}@test.it'
sql(f"insert into auth.users(id, email, email_confirmed_at, encrypted_password, last_sign_in_at) values ('{BRUNA_U}', '{BMAIL}', now(), 'set:vecchia123', now())")
sql(f"insert into fabula.staff(id, full_name, auth_user_id, app_role, role, active, email) values ('{BRUNA_S}', 'Bruna Login{RUN}', '{BRUNA_U}', 'banco', 'commesso', true, '{BMAIL}')")
RITA = sql1(f"insert into fabula.staff(full_name, app_role, role, active) values ('Rita Rota{RUN}', 'produzione', 'operaio', true) returning id")
SESS = {}   # the browser's sessions by user id
def session_for(uid, email):
    return {"access_token": user_jwt(uid, email), "refresh_token": "r", "expires_at": int(time.time()) + 86400, "expires_in": 86400, "token_type": "bearer",
            "user": {"id": uid, "email": email, "aud": "authenticated", "role": "authenticated"}}
def handler_for(s):
    def handler(route):
        u = route.request.url; H = {'access-control-allow-origin': '*', 'access-control-allow-headers': '*'}
        for name, port in FN_PORT.items():
            if f'/functions/v1/{name}' in u:
                if route.request.method == 'OPTIONS': return route.fulfill(status=200, headers=H, body='ok')
                return route.fulfill(response=route.fetch(url=f'http://127.0.0.1:{port}/'))
        if '/rest/v1/' in u: return route.fulfill(response=route.fetch(url='http://127.0.0.1:3000/' + u.split('/rest/v1/', 1)[1]))
        if '/auth/v1/token' in u and 'grant_type=password' in u:
            b = json.loads(route.request.post_data or '{}'); uid = sql1(f"select id from auth.users where lower(email) = lower({q(b.get('email'))}) and encrypted_password = {q('set:' + str(b.get('password')))} and banned_until is null")
            if not uid: return route.fulfill(status=400, content_type='application/json', headers=H, body=json.dumps({'error': 'invalid_grant', 'error_description': 'Invalid login credentials', 'msg': 'Invalid login credentials'}))
            sess = session_for(uid, b.get('email')); s.clear(); s.update(sess)
            sql(f"update auth.users set last_sign_in_at = now() where id = {q(uid)}")
            return route.fulfill(status=200, content_type='application/json', headers=H, body=json.dumps(sess))
        if '/auth/v1/logout' in u: s.clear(); return route.fulfill(status=204, headers=H, body='')
        if '/auth/v1/' in u: return route.fulfill(status=200, content_type='application/json', headers=H, body=json.dumps(s.get('user') or {}))
        return route.fulfill(status=200, body='{}', headers=H)
    return handler
class Dlg:
    """answers browser dialogs in order: True = OK, False = Annulla"""
    def __init__(self, pg): self.log, self.answers = [], []; pg.on('dialog', self.on)
    def on(self, d):
        self.log.append(d.type + ': ' + d.message); a = self.answers.pop(0) if self.answers else True
        d.dismiss() if a is False else d.accept()
def page_as(b, who, path, logs, width=1100):
    s = session_for(*who) if who else {}
    ctx = b.new_context(service_workers='block', viewport={'width': width, 'height': 1300}, locale='it-IT'); ctx.route('**/*.supabase.co/**', handler_for(s))
    pg = ctx.new_page(); pg.on('pageerror', lambda e: logs.append('PAGEERROR ' + str(e)))
    pg.goto(f'http://localhost:{PORT}/labels.html')
    pg.evaluate("localStorage.clear()" + (f"; localStorage.setItem('sb-{REF}-auth-token', {json.dumps(json.dumps(s))}){op_js(s)}" if s else ''))
    pg.goto(f'http://localhost:{PORT}/{path}')
    return ctx, pg, Dlg(pg)
toast = lambda pg: pg.evaluate("(document.getElementById('toast') || {}).textContent || ''")
card = lambda name: f"[...document.querySelectorAll('#users .person')].find(c => c.querySelector('.p-head b').textContent === {json.dumps(name)})"
def click_in_card(pg, name, label):
    return pg.evaluate(f"(() => {{ const c = {card(name)}; const b = c && [...c.querySelectorAll('.p-actions button, .p-email button, .p-fields button')].find(x => x.textContent.trim() === {json.dumps(label)}); if (!b) return false; b.click(); return true; }})()")

try:
  with sync_playwright() as p:
    b = p.chromium.launch(); logs = []
    # ================= Configurazione → Persone =================
    ctx, ap, dl = page_as(b, OWNER, 'admin.html#utenti', logs, width=420)   # a phone
    ap.wait_for_selector('#users .person', timeout=20000); ap.wait_for_timeout(1500)
    me = ap.evaluate(f"(() => {{ const c = {card('Owner Office')}; return c ? c.innerText : ''; }})()")
    check('people are cards with a checklist (Accesso, Telegram, PIN, Formazione), mine marked «(tu)»',
          '(tu)' in me and 'Accesso' in me and 'Telegram' in me and 'PIN' in me and 'Formazione' in me, me.replace('\n', ' | '))
    sw = ap.evaluate("document.documentElement.scrollWidth <= window.innerWidth + 1")
    check('…and they fit a phone: no sideways scrolling', sw)
    # add a person with an e-mail: the link is ready at once
    ap.fill('#inv-name', GIADA); ap.fill('#inv-email', GMAIL.upper()); ap.select_option('#inv-role', 'banco'); ap.click('#inv-go')
    ap.wait_for_function(f"(() => {{ const c = {card(GIADA)}; return c && c.querySelector('.linkbox'); }})()", timeout=20000)
    lb = ap.evaluate(f"(() => {{ const c = {card(GIADA)}; const l = c.querySelector('.linkbox'); return {{ text: l.innerText, link: l.querySelector('input').value, wa: l.querySelector('a[href^=\"https://wa.me\"]').href, mail: l.querySelector('a[href^=\"mailto:\"]').href }}; }})()")
    token = lb['link'].split('#invito=', 1)[1] if '#invito=' in lb['link'] else ''
    wa = unquote(lb['wa'].split('text=', 1)[1])
    check('«Aggiungi una persona» with an e-mail: the access link is shown at once in her card', len(token) >= 40 and '/benvenuto.html#invito=' in lb['link'], lb['link'][:90])
    check('…valid a week, one use, sent by me (no e-mail left by itself)', 'una volta sola' in lb['text'] and 'mandalo tu' in lb['text'], lb['text'][:200])
    week = (datetime.datetime.now() + datetime.timedelta(days=7))
    check('C-19: the WhatsApp message greets her, names the company, the expiry date and the page her profile uses (the tablet)',
          wa.startswith('Ciao Giada,') and COMPANY in wa and f'{week.day}/{week.month}' in wa and '/index.html' in wa and GMAIL in wa and 'console.html' not in wa, wa)
    check('…and «Manda per email» opens a mail to her with the same text', lb['mail'].startswith('mailto:' + GMAIL) and 'Giada' in unquote(lb['mail']), lb['mail'][:120])
    row = sql1(f"select s.email || '|' || s.app_role || '|' || s.role || '|' || (s.auth_user_id is null) || '|' || l.purpose || '|' || (l.token_hash = encode(sha256(convert_to({q(token)}, 'UTF8')), 'hex')) "
               f"from fabula.staff s join fabula.staff_access_links l on l.staff_id = s.id where s.full_name = {q(GIADA)} order by l.created_at desc limit 1")
    check('…stored: the person (e-mail in lower case, Banco, job commesso, no login yet) and only the hash of the link', row == f'{GMAIL}|banco|commesso|true|invite|true', row)
    st = ap.evaluate(f"{card(GIADA)}.querySelector('.p-state').textContent")
    check('her card says the link was sent and until when', 'link mandato' in st and 'vale fino a' in st, st)
    # the same e-mail again
    ap.fill('#inv-name', 'Altra Giada'); ap.fill('#inv-email', GMAIL); ap.click('#inv-go'); ap.wait_for_timeout(2500)
    check('the same e-mail again: «già di Giada», and her card is shown', 'già di' in toast(ap) and sql1(f"select count(*) from fabula.staff where email = {q(GMAIL)}") == '1', toast(ap))
    # C-17 job role follows the profile; Titolare asks
    ap.evaluate(f"(() => {{ const s = {card(GIADA)}.querySelectorAll('.p-fields select'); s[0].value = 'produzione'; s[0].dispatchEvent(new Event('change', {{ bubbles: true }})); }})()")
    job = ap.evaluate(f"{card(GIADA)}.querySelectorAll('.p-fields select')[1].value")
    check('C-17: choosing the profile Produzione sets the job role to operaio', job == 'operaio', job)
    ap.evaluate(f"(() => {{ const s = {card(GIADA)}.querySelectorAll('.p-fields select'); s[0].value = 'titolare'; s[0].dispatchEvent(new Event('change', {{ bubbles: true }})); }})()")
    dl.answers = [False]; click_in_card(ap, GIADA, 'Salva'); ap.wait_for_timeout(1500)
    check('C-17: making someone Titolare asks first; «Annulla» saves nothing', any('diventa Titolare' in x for x in dl.log) and sql1(f"select app_role from fabula.staff where full_name = {q(GIADA)}") == 'banco', dl.log[-1:])
    ap.reload(); ap.wait_for_selector('#users .person', timeout=20000); ap.wait_for_timeout(1500)
    # C-13 change the e-mail of someone with a login
    click_in_card(ap, f'Bruna Login{RUN}', 'Cambia')
    ap.evaluate(f"(() => {{ const i = {card(f'Bruna Login{RUN}')}.querySelector('.p-email input'); i.value = 'BRUNA.NUOVA{RUN}@test.it'; i.dispatchEvent(new Event('input', {{ bubbles: true }})); }})()")
    dl.answers = [True]; click_in_card(ap, f'Bruna Login{RUN}', 'Salva email'); ap.wait_for_timeout(3500)
    em = sql1(f"select s.email || '|' || u.email from fabula.staff s join auth.users u on u.id = s.auth_user_id where s.id = '{BRUNA_S}'")
    check('C-13: «Cambia email» of someone with a login asks, then changes the login e-mail too (one account, no second one)',
          any('Cambia anche l\'email con cui Bruna entra' in x for x in dl.log) and em == f'bruna.nuova{RUN}@test.it|bruna.nuova{RUN}@test.it'
          and sql1(f"select count(*) from auth.users where email like 'bruna%{RUN}%'") == '1', em)
    # «Link per nuova password» for someone with a password
    click_in_card(ap, f'Bruna Login{RUN}', 'Link per nuova password'); ap.wait_for_timeout(3000)
    rt = ap.evaluate(f"(() => {{ const l = {card(f'Bruna Login{RUN}')}.querySelector('.linkbox'); return l ? l.innerText : ''; }})()")
    check('someone with a password gets «Link per una nuova password»', rt.startswith('Link per una nuova password'), rt[:80])
    ctx.close()

    # ================= the welcome page =================
    ctx, wp, _ = page_as(b, None, f'benvenuto.html#invito={token}', logs, width=390)
    wp.wait_for_selector('#form:not([hidden])', timeout=20000)
    sub, who = wp.evaluate("[document.getElementById('sub').textContent, document.getElementById('who').textContent]")
    check('the link greets her by name with the company and shows the e-mail she will sign in with', sub.startswith('Ciao Giada!') and COMPANY in sub and GMAIL in who, f'{sub} | {who}')
    wp.fill('#pw1', 'corta'); wp.fill('#pw2', 'corta'); wp.click('#go'); wp.wait_for_timeout(300)
    e1 = wp.evaluate("document.getElementById('err').textContent")
    wp.fill('#pw1', 'Mozzarella2026'); wp.fill('#pw2', 'Mozzarella2027'); wp.click('#go'); wp.wait_for_timeout(300)
    e2 = wp.evaluate("document.getElementById('err').textContent")
    check('a short password and two different ones are refused on the page', '8 caratteri' in e1 and 'non coincidono' in e2, f'{e1} | {e2}')
    wp.fill('#pw1', 'password123'); wp.fill('#pw2', 'password123'); wp.click('#go'); wp.wait_for_timeout(3000)
    e3 = wp.evaluate("document.getElementById('err').textContent")
    check('a password Supabase finds too common is refused, and the link still works',
          'troppo comune' in e3 and sql1(f"select used_at is null from fabula.staff_access_links l join fabula.staff s on s.id = l.staff_id where s.full_name = {q(GIADA)} order by l.created_at desc limit 1") == 't', e3)
    wp.fill('#pw1', 'Mozzarella2026'); wp.fill('#pw2', 'Mozzarella2026'); wp.click('#go')
    try: wp.wait_for_function("!document.getElementById('steps').hidden || document.getElementById('err').textContent || document.getElementById('form').hidden", timeout=20000)
    except Exception: pass
    wp.wait_for_timeout(1500)
    acc = sql1(f"select (u.encrypted_password = 'set:Mozzarella2026') || '|' || (u.email_confirmed_at is not null) || '|' || (s.auth_user_id = u.id) from fabula.staff s join auth.users u on lower(u.email) = s.email where s.full_name = {q(GIADA)}")
    check('«Salva e entra»: her login is created with that password and linked to her; she is signed in', acc == 'true|true|true', acc)
    stp = wp.evaluate("({ tg: !document.getElementById('st-tg').hidden, href: document.getElementById('tg-go').href, enter: document.getElementById('enter').getAttribute('href'), url: location.href })")
    check('then «Collega Telegram» with her own link (t.me/…?start=…)', stp['tg'] and stp['href'].startswith('https://t.me/') and '?start=' in stp['href'], stp)
    check('…and «Entra nell\'app» opens her profile\'s page (the tablet); the link left the address bar', stp['enter'] == 'index.html' and 'invito' not in stp['url'], stp)
    ls = sql1(f"select state from fabula.staff_login_rows() r join fabula.staff s on s.id = r.staff_id where s.full_name = {q(GIADA)}")
    check('Configurazione now sees her as «attivo»', ls == 'attivo', ls)
    ctx.close()
    ctx, wp, _ = page_as(b, None, f'benvenuto.html#invito={token}', logs, width=390)
    wp.wait_for_timeout(4000)
    s2 = wp.evaluate("[document.getElementById('sub').textContent, !document.getElementById('form').hidden, document.getElementById('have').offsetParent !== null]")
    check('the same link again: «già stato usato», no form, only «Ho già la password: entra»', 'già stato usato' in s2[0] and not s2[1] and s2[2], s2)
    ctx.close()
    # an older link, replaced by a newer one
    old = 'vecchio' + RUN + 'x' * 40
    sql(f"insert into fabula.staff_access_links (staff_id, token_hash, purpose, expires_at, revoked_at, revoked_why) select id, encode(sha256(convert_to({q(old)}, 'UTF8')), 'hex'), 'invite', now() + interval '6 days', now(), 'sostituito da un link nuovo' from fabula.staff where id = '{RITA}'")
    sql(f"update fabula.staff set email = 'rita{RUN}@test.it' where id = '{RITA}'")
    ctx, wp, _ = page_as(b, None, f'benvenuto.html#invito={old}', logs, width=390)
    wp.wait_for_timeout(4000)
    s3 = wp.evaluate("document.getElementById('sub').textContent")
    check('an older link says it was replaced by a newer one', 'sostituito' in s3, s3)
    ctx.close()

    # ================= C-14 / C-15: switching off and back =================
    GID = sql1(f"select id from fabula.staff where full_name = {q(GIADA)}")
    GUID = sql1(f"select auth_user_id from fabula.staff where id = '{GID}'")
    sql(f"insert into fabula.shifts (staff_id, clock_in) values ('{GID}', now() - interval '2 hours')")
    sql(f"insert into fabula.rota_entries (staff_id, work_date, kind, start_time, end_time) values ('{GID}', (now() at time zone 'Europe/Rome')::date + 1, 'lavoro', '06:00', '12:00'), ('{GID}', (now() at time zone 'Europe/Rome')::date + 2, 'lavoro', '06:00', '12:00')")
    ctx, ap, dl = page_as(b, OWNER, 'admin.html#utenti', logs)
    ap.wait_for_selector('#users .person', timeout=20000); ap.wait_for_timeout(1500)
    dl.answers = [True]; click_in_card(ap, GIADA, 'Disattiva'); ap.wait_for_timeout(5000)
    q1 = next((x for x in dl.log if 'Disattivare' in x), '')
    check('C-14: «Disattiva» first lists what will happen (open shift, 2 future shifts, Telegram link)', 'turno aperto' in q1 and '2 turni futuri' in q1, q1.replace('\n', ' | ')[:300])
    off = sql1(f"select s.active || '|' || (select count(*) from fabula.shifts where staff_id = s.id and clock_out is null) || '|' || (select count(*) from fabula.rota_entries where staff_id = s.id and work_date > (now() at time zone 'Europe/Rome')::date) || '|' || (u.banned_until > now()) from fabula.staff s join auth.users u on u.id = s.auth_user_id where s.id = '{GID}'")
    check('…then: switched off, shift closed, future rota removed, login blocked', off == 'false|0|0|true', off)
    done = ap.evaluate("(document.getElementById('usr-done') || {}).innerText || ''")
    check('…and a summary of what was done stays on screen', 'è disattivato' in done and 'accesso bloccato' in done, done.replace('\n', ' | ')[:200])
    ap.fill('#inv-name', GIADA); ap.fill('#inv-email', GMAIL); ap.click('#inv-go'); ap.wait_for_timeout(2500)
    check('C-15: adding her again with the same e-mail says to use «Riattiva»', 'Riattiva' in toast(ap) and sql1(f"select count(*) from fabula.staff where email = {q(GMAIL)}") == '1', toast(ap))
    click_in_card(ap, GIADA, 'Riattiva'); ap.wait_for_timeout(3500)
    back = sql1(f"select s.active || '|' || (u.banned_until is null) from fabula.staff s join auth.users u on u.id = s.auth_user_id where s.id = '{GID}'")
    check('«Riattiva» brings her back and unblocks the login', back == 'true|true', back)
    ctx.close()

    # ================= C-23: «Cambia password» for a profile without Configurazione =================
    sql(f"update auth.users set encrypted_password = 'set:Casaro2026' where id = '{CASARO[0]}'")
    ctx, cp, dl = page_as(b, CASARO, 'console.html', logs)
    cp.wait_for_selector('#ui-pw-open', state='attached', timeout=20000)
    cp.evaluate("document.getElementById('me').open = true"); cp.click('#ui-pw-open'); cp.wait_for_timeout(300)
    cp.fill('#ui-pw0', 'sbagliata'); cp.fill('#ui-pw1', 'NuovaPass2026'); cp.fill('#ui-pw2', 'NuovaPass2026'); cp.click('#ui-pwok'); cp.wait_for_timeout(1500)
    pe = cp.evaluate("document.getElementById('ui-pwerr').textContent")
    check('C-23: «Cambia password» is in the menu of a profile without Configurazione, and a wrong current password is refused', 'non è corretta' in pe, pe)
    ctx.close()

    # ================= B-26: the rota editor =================
    nxt = sql1("select (date_trunc('week', (now() at time zone 'Europe/Rome')::date) + interval '7 days')::date")
    sql(f"delete from fabula.rota_entries where staff_id = '{RITA}'")
    ctx, cp, dl = page_as(b, OWNER, 'console.html#personale', logs)
    cp.wait_for_selector('#rota-grid table.rota', timeout=20000); cp.wait_for_timeout(1000)
    wk = cp.evaluate("document.getElementById('rota-week').textContent")
    check('B-26: the week says which one it is («settimana prossima»)', 'settimana prossima' in wk, wk)
    CELLS = f"[...document.querySelectorAll('#rota-grid tr')].find(r => r.cells[0] && r.cells[0].textContent.startsWith('Rita Rota{RUN}')).querySelectorAll('.r-cell')"
    cell = lambda i: f"{CELLS}[{i}]"
    cp.evaluate(f"{cell(0)}.click()"); cp.wait_for_selector('#rota-dlg[open]')
    cp.fill('#rd-a', '15:00'); cp.fill('#rd-b', '05:00'); cp.click('#rd-ok'); cp.wait_for_timeout(200)
    ne = cp.evaluate("document.getElementById('rd-e').textContent")
    check('an end before the start is refused unless «finisce il giorno dopo» is ticked (15-05 for 05-15 can no longer be 14 h)', 'giorno dopo' in ne, ne)
    cp.fill('#rd-a', '05:00'); cp.fill('#rd-b', '13:30'); cp.select_option('#rd-p', '30'); cp.fill('#rd-r', 'banco')
    hrs = cp.evaluate("document.getElementById('rd-h').textContent")
    cp.evaluate("document.querySelectorAll('#rota-dlg [data-day]')[1].click(); document.querySelectorAll('#rota-dlg [data-day]')[2].click()")
    cp.click('#rd-ok'); cp.wait_for_timeout(300)
    cells = cp.evaluate(f"(() => {{ const c = {CELLS}; return [0, 1, 2, 3].map(i => c[i].className + '|' + c[i].innerText); }})()")
    check('times, a 30 min break and the area: «8 h» shown before applying', hrs.startswith('8 h'), hrs)
    check('«Anche questi giorni» copies it to Tuesday and Wednesday; the changed cells are marked until saved',
          all('r-changed' in cells[i] and '05:00–13:30' in cells[i] and 'banco' in cells[i] for i in range(3)) and 'r-changed' not in cells[3], cells)
    tot = cp.evaluate(f"[...document.querySelectorAll('#rota-grid tr')].find(r => r.cells[0] && r.cells[0].textContent.startsWith('Rita Rota{RUN}')).lastElementChild.textContent")
    check('…the week total follows (3 × 8 h = 24)', tot.startswith('24'), tot)
    cp.evaluate(f"{cell(4)}.click()"); cp.wait_for_selector('#rota-dlg[open]'); cp.click('#rota-dlg [data-kind=riposo]'); cp.click('#rd-ok'); cp.wait_for_timeout(300)
    cp.click('#rota-save'); cp.wait_for_timeout(3000)
    rows = sql(f"select work_date - '{nxt}'::date || ':' || kind || ':' || coalesce(to_char(start_time, 'HH24:MI') || '-' || to_char(end_time, 'HH24:MI'), '') || ':' || break_min || ':' || coalesce(area, '') from fabula.rota_entries where staff_id = '{RITA}' order by work_date")
    check("«Salva settimana» saves the three shifts and Friday's riposo", rows.split('\n') == ['0:lavoro:05:00-13:30:30:banco', '1:lavoro:05:00-13:30:30:banco', '2:lavoro:05:00-13:30:30:banco', '4:riposo::0:'], rows.replace('\n', ' '))
    cp.wait_for_timeout(1500)
    after = cp.evaluate(f"{cell(0)}.className + '|' + {cell(0)}.innerText")
    check('…and shows them again, no longer marked', '05:00–13:30' in after and 'r-changed' not in after, after)
    cp.evaluate(f"{cell(5)}.click()"); cp.wait_for_selector('#rota-dlg[open]'); cp.click('#rota-dlg [data-kind=ferie]'); cp.click('#rd-ok'); cp.wait_for_timeout(300)
    dl.answers = [False]; cp.click('#rota-prev'); cp.wait_for_timeout(800)
    check('changing week with an unsaved cell asks first', any('non salvati' in x for x in dl.log) and 'settimana prossima' in cp.evaluate("document.getElementById('rota-week').textContent"), dl.log[-1:])
    ctx.close()

    errs = [l for l in logs if 'PAGEERROR' in l]
    check('no page errors', not errs, errs[:3])
    b.close()
finally:
    srv_pages.terminate(); srv.shutdown()
    for pr in procs:
        try: os.killpg(pr.pid, 15)
        except Exception: pass
    sql(f"delete from fabula.rota_entries where staff_id = '{RITA}'")

print('FAILURES: ' + (', '.join(fails) if fails else 'none'))
