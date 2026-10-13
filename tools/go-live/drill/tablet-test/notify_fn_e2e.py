"""v0.96 audit E-01: the `notify` edge function run locally with Deno against the local copy (restore_drill + PostgREST on :3000,
v096c applied) and a fake Telegram API on :8790 (it also forwards /rest/v1 to PostgREST, as Supabase does).
- /start <code> from Telegram (with the webhook secret) links the chat; a wrong secret is refused (403).
- An alert posted by a bot → dispatch sends it as HTML with the two buttons, registers the webhook first, stores the message id.
- «✋ Me ne occupo io» → the alert is taken, everyone's copy is edited, the button press is answered; /stop unlinks.
Needs Deno: DENO=/path/to/deno (e.g. npm i deno → node_modules/.bin/deno). Expect "FAILURES: none"."""
import json, os, signal, subprocess, threading, time, hmac, hashlib, base64, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DENO = os.environ.get('DENO', '/tmp/claude-0/denoinst/node_modules/.bin/deno')
FN = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../../../supabase/functions/notify/index.ts'))
def _b64(b): return base64.urlsafe_b64encode(b).rstrip(b'=').decode()
def _jwt_role(role, secret=b"test-secret-test-secret-test-secret-0123456789"):
    h = _b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode()); p = _b64(json.dumps({"role": role, "exp": int(time.time()) + 3600}).encode())
    return h + '.' + p + '.' + _b64(hmac.new(secret, (h + '.' + p).encode(), hashlib.sha256).digest())
def sql(q):
    r = subprocess.run(['su', 'postgres', '-c', f'psql -At -d restore_drill -c "{q}"'], capture_output=True, text=True)
    return r.stdout.strip() or r.stderr.strip()
def sql1(q): return (sql(q).splitlines() or [''])[0]

CALLS = []; MSG = [1000]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, body, ctype='application/json'):
        b = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code); self.send_header('Content-Type', ctype); self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
    def _proxy(self):
        n = int(self.headers.get('Content-Length') or 0); data = self.rfile.read(n) if n else None
        url = 'http://127.0.0.1:3000/' + self.path.split('/rest/v1/', 1)[1]
        hdr = {k: v for k, v in self.headers.items() if k.lower() in ('authorization', 'content-type', 'accept', 'accept-profile', 'content-profile', 'prefer', 'apikey')}
        req = urllib.request.Request(url, data=data, method=self.command, headers=hdr)
        try:
            with urllib.request.urlopen(req) as r: self._send(r.status, r.read(), r.headers.get('Content-Type', 'application/json'))
        except urllib.error.HTTPError as e: self._send(e.code, e.read(), e.headers.get('Content-Type', 'application/json'))
    def do_GET(self):
        if '/rest/v1/' in self.path: return self._proxy()
        self._send(404, {})
    def do_PATCH(self): return self._proxy()
    def do_POST(self):
        if '/rest/v1/' in self.path: return self._proxy()
        n = int(self.headers.get('Content-Length') or 0); body = json.loads(self.rfile.read(n) or b'{}')
        method = self.path.rsplit('/', 1)[-1]; CALLS.append((method, body))
        if method == 'getMe': return self._send(200, {'ok': True, 'result': {'id': 1, 'is_bot': True, 'username': 'bubalina_avvisi_bot'}})
        if method == 'sendMessage':
            if body.get('chat_id') == 7777: return self._send(403, {'ok': False, 'error_code': 403, 'description': 'Forbidden: bot was blocked by the user'})
            MSG[0] += 1; return self._send(200, {'ok': True, 'result': {'message_id': MSG[0]}})
        return self._send(200, {'ok': True, 'result': True})

fails = []
def check(name, cond, info=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f'  [{info}]' if info else ''))
    if not cond: fails.append(name)
def post(body, secret=None):
    hdr = {'Content-Type': 'application/json'}
    if secret is not None: hdr['X-Telegram-Bot-Api-Secret-Token'] = secret
    req = urllib.request.Request('http://127.0.0.1:8000/', data=json.dumps(body).encode(), headers=hdr)
    try:
        with urllib.request.urlopen(req, timeout=30) as r: return r.status, r.read().decode()
    except urllib.error.HTTPError as e: return e.code, e.read().decode()

srv = ThreadingHTTPServer(('127.0.0.1', 8790), H); threading.Thread(target=srv.serve_forever, daemon=True).start()
env = dict(os.environ, SUPABASE_URL='http://127.0.0.1:8790', SUPABASE_SERVICE_ROLE_KEY=_jwt_role('service_role'), TELEGRAM_BOT_TOKEN='TEST',
           TELEGRAM_WEBHOOK_SECRET='sekret-e2e', TELEGRAM_API_BASE='http://127.0.0.1:8790', DENO_DIR=os.environ.get('DENO_DIR', '/tmp/claude-0/denocache'))
fn = subprocess.Popen([DENO, 'run', '--allow-net', '--allow-env', FN], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)   # own group: the npm wrapper starts a child
RUN = time.strftime('%H%M%S')
CAS = '10000000-0000-4000-a000-000000000001'
try:
    for _ in range(60):
        try: urllib.request.urlopen('http://127.0.0.1:8000/', timeout=1); break
        except Exception: time.sleep(1)
    sql("delete from fabula.settings where key = 'notify.webhook_url'")
    sql(f"update fabula.notify_targets set chat_id = null where chat_id in (4242, 7777)")
    code = json.loads(sql1(f"select fabula.notify_link_code('{CAS}')"))['code']

    st, _ = post({'update_id': 1, 'message': {'message_id': 1, 'chat': {'id': 4242, 'type': 'private'}, 'from': {'first_name': 'Test'}, 'text': f'/start {code}'}}, 'wrong')
    check('a webhook call with the wrong secret is refused', st == 403, st)
    st, _ = post({'update_id': 2, 'message': {'message_id': 2, 'chat': {'id': 4242, 'type': 'private'}, 'from': {'first_name': 'Test', 'last_name': 'Casaro'}, 'text': f'/start {code}'}}, 'sekret-e2e')
    check('/start <code> links the chat', st == 200 and sql1(f"select chat_id || '|' || tg_name from fabula.notify_targets where staff_id = '{CAS}'") == '4242|Test Casaro')
    reply = [b for m, b in CALLS if m == 'sendMessage' and b.get('chat_id') == 4242]
    check('…and answers in Italian with what will arrive', reply and 'Collegato' in reply[-1]['text'] and 'sicurezza alimentare' in reply[-1]['text'], (reply[-1]['text'] if reply else '')[:120])

    CALLS.clear()
    bm = sql1(f"select fabula.post_bot_message('produzione', 'alert', 'Lotto LN{RUN} chiuso senza CCP 3', E'**Da fare**\\n1. Ricopia la misura')")
    ob = sql1(f"select id from fabula.notify_outbox where source_ref = '{bm}'")
    st, out = post({'op': 'dispatch'})
    sends = [b for m, b in CALLS if m == 'sendMessage' and b.get('chat_id') == 4242]
    check('dispatch registers the webhook (with the secret) first', [m for m, _ in CALLS][:2] == ['getMe', 'setWebhook']
          and any(m == 'setWebhook' and b.get('secret_token') == 'sekret-e2e' and b.get('url', '').endswith('/functions/v1/notify') for m, b in CALLS), [m for m, _ in CALLS][:4])
    check('the alert goes out as HTML with «Ho visto» / «Me ne occupo io»', sends and sends[0].get('parse_mode') == 'HTML' and f'Lotto LN{RUN}' in sends[0]['text']
          and [x['callback_data'] for x in sends[0]['reply_markup']['inline_keyboard'][0]] == ['s:' + ob, 't:' + ob], out)
    check('the delivery is marked sent with the Telegram message id', sql1(f"select status || '|' || (message_id is not null) from fabula.notify_deliveries where outbox_id = '{ob}' and chat_id = 4242") == 'sent|true')
    check('the bot username is stored', sql1("select value from fabula.settings where key = 'notify.telegram_bot'") == 'bubalina_avvisi_bot')

    CALLS.clear()
    st, _ = post({'update_id': 3, 'callback_query': {'id': 'cq1', 'data': 't:' + ob, 'from': {'id': 4242}, 'message': {'message_id': 1, 'chat': {'id': 4242, 'type': 'private'}}}}, 'sekret-e2e')
    check('«Me ne occupo io» takes the alert', sql1(f"select acked_by_id from fabula.notify_outbox where id = '{ob}'") == CAS)
    edits = [b for m, b in CALLS if m == 'editMessageText']
    check('…edits the copies (who takes care, buttons removed) and answers the press', edits and 'Se ne occupa Test Casaro' in edits[0]['text'] and edits[0]['reply_markup'] == {'inline_keyboard': []}
          and any(m == 'answerCallbackQuery' and 'te ne occupi tu' in b.get('text', '') for m, b in CALLS), str(edits[:1])[:200])

    # a chat that blocked the bot: marked failed, unlinked
    sql(f"update fabula.notify_targets set chat_id = 7777 where staff_id = '{CAS}'")
    sql1(f"select fabula.post_bot_message('produzione', 'alert', 'Lotto LB{RUN} senza CCP 2', null)")
    post({'op': 'dispatch'})
    check('a blocked bot: delivery failed and the chat unlinked', sql1(f"select chat_id is null from fabula.notify_targets where staff_id = '{CAS}'") == 't'
          and sql1("select count(*) from fabula.notify_deliveries where chat_id = 7777 and status = 'failed'") != '0')
    sql(f"update fabula.notify_targets set chat_id = 4242 where staff_id = '{CAS}'")
    st, _ = post({'update_id': 4, 'message': {'message_id': 3, 'chat': {'id': 4242, 'type': 'private'}, 'text': '/stop'}}, 'sekret-e2e')
    check('/stop unlinks', sql1(f"select chat_id is null from fabula.notify_targets where staff_id = '{CAS}'") == 't')
finally:
    try: os.killpg(fn.pid, signal.SIGTERM)
    except Exception: fn.terminate()
    try: out = fn.communicate(timeout=5)[0]
    except Exception: out = ''
    errs = [l for l in (out or '').splitlines() if 'error' in l.lower() and 'TEST' not in l]
    check('no function errors in the log', not errs, ' | '.join(errs)[:300])
    srv.shutdown()
print('FAILURES:', ', '.join(fails) if fails else 'none')
