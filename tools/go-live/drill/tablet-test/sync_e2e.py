"""v1.02 Shopify sync in the database (E-18) and the morning summary (E-07) in the browser, against the local copy
(restore_drill + setup.sql + PostgREST on :3000, v102a–b applied). The browser runs in Italian (locale it-IT). Port 8781.
- E-18   Configurazione → Bot: the Shopify jobs say «dal database»; «Esegui ora» on one starts the sync (no «versione del database»),
         asks first, says the result comes in a couple of minutes, and the call carries the person's name; a second press asks again.
- E-18   a sync message written by the database shows in the feed with its link (products page for an unlinked product).
- E-07   Configurazione → Utenti → Avvisi Telegram: the system topic says it waits for the silence unless the system is down;
         the summary time is shown, saved, and cleared with an empty field.
Expect "FAILURES: none"."""
import json, subprocess, time, os, hmac, hashlib, base64
from playwright.sync_api import sync_playwright
from e2e_op import op_js

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../../../fabula-tablet'))
REF = 'ojkquhzaeypsphncjqwy'; PORT = 8781
def _b64(b): return base64.urlsafe_b64encode(b).rstrip(b'=').decode()
def _jwt(sub, email, secret=b"test-secret-test-secret-test-secret-0123456789"):
    h = _b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    p = _b64(json.dumps({"sub": sub, "role": "authenticated", "email": email, "aud": "authenticated", "exp": int(time.time()) + 86400}).encode())
    return h + '.' + p + '.' + _b64(hmac.new(secret, (h + '.' + p).encode(), hashlib.sha256).digest())
def sql(q):
    r = subprocess.run(['su', 'postgres', '-c', f'psql -At -d restore_drill -c "{q}"'], capture_output=True, text=True)
    if 'ERROR' in r.stderr: print('SQL ERROR:', q[:90], '→', r.stderr.strip()[:300])
    return r.stdout.strip() or r.stderr.strip()
def sql1(q): return (sql(q).splitlines() or [''])[0]

RUN = time.strftime('%H%M%S')
OWNER = ("00000000-0000-4000-a000-0000000000e1", "sync-owner@test.it")
OWNER_STAFF = '10000000-0000-4000-a000-0000000000e1'
sql(f"insert into auth.users(id, email) values ('{OWNER[0]}', '{OWNER[1]}') on conflict do nothing")
sql(f"insert into fabula.staff(id, full_name, auth_user_id, app_role, role, active) values ('{OWNER_STAFF}', 'Titolare Sync', '{OWNER[0]}', 'titolare', 'owner', true) on conflict do nothing")
sql(f"insert into fabula.notify_targets (staff_id, chat_id, topics, tz, quiet_from, quiet_to, digest_at) values ('{OWNER_STAFF}', 880001, '{{food_safety,infra,decisions}}', "
    "'America/New_York', '22:00', '07:30', '07:30') on conflict (staff_id) do update set chat_id = 880001, digest_at = '07:30', tz = 'America/New_York'")
sql("update fabula.agent_runs set status = 'ok', finished_at = now() where status = 'running' and agent like 'shopify_%'")
sql("delete from fabula.db_job_calls")
# a sync run written by the database: a product sold online not linked to the stock
RUNID = sql1("select fabula.shopify_sync_start('shopify_orders')")
res = {"ok": True, "window": {"days": 3}, "shopify": {"count": 1, "pos": 0}, "fulfil": {"pending": 0, "done": 0, "failed": []},
       "upsert": {"created": 1, "updated": 0, "unmapped_variants": [{"variant_id": f"gid://v/{RUN}", "label": f"Sync ricotta {RUN}"}]}}
open('/tmp/sync_e2e_fx.sql', 'w').write(f"select fabula.shopify_sync_finish('{RUNID}', $j${json.dumps(res)}$j$::jsonb);"); os.chmod('/tmp/sync_e2e_fx.sql', 0o644)
subprocess.run(['su', 'postgres', '-c', 'psql -q -d restore_drill -f /tmp/sync_e2e_fx.sql'], capture_output=True)

srv = subprocess.Popen(['python3', '-m', 'http.server', str(PORT)], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1)
fails = []
def check(name, cond, info=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f'  [{info}]' if info else ''))
    if not cond: fails.append(name)
class Dlg:
    def __init__(self, pg): self.log, self.answers = [], []; pg.on('dialog', self.on)
    def on(self, d):
        self.log.append(d.type + ': ' + d.message)
        a = self.answers.pop(0) if self.answers else True
        if a is False: d.dismiss()
        elif d.type == 'prompt': d.accept(a if isinstance(a, str) else '')
        else: d.accept()
def page_as(b, who, path, logs, width=1100):
    s = {"access_token": _jwt(*who), "refresh_token": "r", "expires_at": int(time.time()) + 86400, "expires_in": 86400, "token_type": "bearer",
         "user": {"id": who[0], "email": who[1], "aud": "authenticated", "role": "authenticated"}}
    def handler(route):
        u = route.request.url
        if '/rest/v1/' in u: return route.fulfill(response=route.fetch(url='http://127.0.0.1:3000/' + u.split('/rest/v1/', 1)[1]))
        if '/auth/v1/' in u: return route.fulfill(status=200, content_type='application/json', body=json.dumps(s['user']), headers={'access-control-allow-origin': '*'})
        return route.fulfill(status=200, body='{}', headers={'access-control-allow-origin': '*'})
    ctx = b.new_context(service_workers='block', viewport={'width': width, 'height': 1300}, locale='it-IT'); ctx.route('**/*.supabase.co/**', handler)
    pg = ctx.new_page(); pg.on('pageerror', lambda e: logs.append('PAGEERROR ' + str(e)))
    pg.goto(f'http://localhost:{PORT}/labels.html')
    pg.evaluate(f"localStorage.clear(); localStorage.setItem('sb-{REF}-auth-token', {json.dumps(json.dumps(s))}){op_js(s)}")
    pg.goto(f'http://localhost:{PORT}/{path}')
    return ctx, pg
toast = lambda pg: pg.evaluate("(document.getElementById('toast') || {}).textContent || ''")

try:
  with sync_playwright() as p:
    b = p.chromium.launch(); logs = []
    ctx, ap = page_as(b, OWNER, 'admin.html#bots', logs)
    ap.wait_for_timeout(6000); dl = Dlg(ap)
    sched = ap.evaluate("Object.fromEntries([...document.querySelectorAll('#bd-bots .botc')].map(c => [c.dataset.a, c.title + ' || ' + c.innerText.replace(/\\s+/g, ' ')]))")
    check('E-18 the Shopify jobs say they run in the database', all('dal database' in sched.get(a, '') for a in ['shopify_orders', 'shopify_customers', 'shopify_inventory'])
          and 'dal database' not in sched.get('milk_planning', ''), str({k: v[:90] for k, v in sched.items() if k.startswith('shopify')}))
    check('E-18 …and offer «Esegui ora»', '«Esegui ora» disponibile' in sched.get('shopify_customers', ''), sched.get('shopify_customers', '')[:200])
    # the message written by the database, with the products page
    m = ap.evaluate(f"(() => {{ const m = [...document.querySelectorAll('#bd-feed .msg')].find(x => x.innerText.includes('Sync ricotta {RUN}')); const a = m && m.querySelector('a.go'); return m ? m.innerText.replace(/\\s+/g, ' ') + '||' + (a ? a.getAttribute('href') : '') : ''; }})()")
    check('E-18 the sync message: what to link, the products page', 'Collega al magazzino: Sync ricotta' in m and m.endswith('||admin.html#prodotti'), m[:300])
    # «Esegui ora» on Clienti Shopify
    ap.evaluate("document.querySelector('#bd-bots .botc[data-a=shopify_customers]').click()"); ap.wait_for_timeout(1500)
    rn = ap.evaluate("document.getElementById('bd-run').hidden ? '' : document.getElementById('bd-run').innerText")
    check('E-18 the run card: «Esegui ora», what it does, the result in a couple of minutes (not «versione del database»)',
          'Clienti Shopify · Esegui ora' in rn and 'versione del database' not in rn and 'elenco completo dei clienti' in rn and 'entro un paio di minuti' in rn, rn.replace('\n', ' | '))
    dl.answers = [True]
    ap.evaluate("document.getElementById('bd-run-go').click()"); ap.wait_for_timeout(2500)
    t = toast(ap)
    call = sql1("select by_name || '|' || attempt || '|' || (slot is null) from fabula.db_job_calls where agent = 'shopify_customers' order by id desc limit 1")
    req = sql1("select body->>'agent' || '|' || (body->>'by') || '|' || (headers ? 'x-sync-secret') from net.http_request_queue where url like '%shopify-sync' order by id desc limit 1")
    check('E-18 «Esegui ora» asks first, then calls the function with the person\'s name and the key',
          any('avviare adesso la sincronizzazione con Shopify' in x for x in dl.log) and call == 'Titolare Sync|1|true' and req == 'shopify_customers|Titolare Sync|true',
          f'{dl.log[-1:]} / {call} / {req}')
    check('E-18 …and says the result arrives here', 'Clienti Shopify avviata' in t and 'entro un paio di minuti' in t, t)
    dl.answers = [False]
    ap.evaluate("document.getElementById('bd-run-go').click()"); ap.wait_for_timeout(1500)
    dl.answers = [True, False]
    ap.evaluate("document.getElementById('bd-run-go').click()"); ap.wait_for_timeout(2500)
    n_calls = sql1("select count(*) from fabula.db_job_calls where agent = 'shopify_customers'")
    check('E-18 pressed again: it says it was just started and asks; «Annulla» starts nothing', any('è stato avviato alle' in x for x in dl.log) and n_calls == '1', f'{dl.log} / calls {n_calls}')
    ctx.close()

    # ================= Utenti → Avvisi Telegram: the summary time =================
    ctx, up = page_as(b, OWNER, 'admin.html#utenti', logs)
    up.wait_for_timeout(5000)
    card = up.evaluate("(document.getElementById('notify-me') || {}).innerText || ''")
    dg = up.evaluate("(document.getElementById('nt-dg') || {}).value")
    check('E-07 the Telegram card: system alarms wait for the silence unless the system is down; the summary time is there',
          'subito solo se il sistema è giù' in card and 'Riepilogo ogni giorno alle' in card and dg == '07:30', f'{dg} / ' + card.replace('\n', ' | ')[:300])
    up.fill('#nt-dg', '07:05'); up.click('#nt-save'); up.wait_for_timeout(2000)
    v1 = sql1(f"select to_char(digest_at, 'HH24:MI') from fabula.notify_targets where staff_id = '{OWNER_STAFF}'")
    up.fill('#nt-dg', ''); up.click('#nt-save'); up.wait_for_timeout(2000)
    v2 = sql1(f"select coalesce(to_char(digest_at, 'HH24:MI'), 'none') || '|' || tz from fabula.notify_targets where staff_id = '{OWNER_STAFF}'")
    check('E-07 the summary time is saved, and an empty field switches the summary off (the time zone stays)', v1 == '07:05' and v2 == 'none|America/New_York', f'{v1} / {v2}')
    ctx.close()
    check('no page errors', not logs, '; '.join(logs)[:300])
    b.close()
finally:
    srv.terminate()
    sql(f"delete from fabula.notify_targets where staff_id = '{OWNER_STAFF}'")
print('FAILURES:', fails or 'none')
