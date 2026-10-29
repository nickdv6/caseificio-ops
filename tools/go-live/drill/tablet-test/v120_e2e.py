"""v1.20 (MILK-1, the house rule «latte del giorno») on the tablet, against the local copy (restore_drill with v120a + setup.sql +
PostgREST on :3000, one milk supplier; pages on :8796). A delivery of today and one of yesterday that nothing was made from:
- Home proposes today's milk «da lavorare oggi» and does not propose yesterday's: it shows it apart, in red, with the rule;
- scanning yesterday's milk opens the batch start with the rule written on it; a start today is refused with the rule's message,
  a paper copy dated today too, and nothing reaches the database;
- a paper copy dated yesterday (the milk's day) is taken: the vat is in the database with yesterday's time, and Home no longer
  shows that milk;
- today's tile opens the start without the rule's note and the batch starts.
Expect `FAILURES: none`."""
import json, subprocess, time, os, hmac, hashlib, base64
from playwright.sync_api import sync_playwright
from e2e_op import op_js, answer_ask

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../../../fabula-tablet'))
REF = 'ojkquhzaeypsphncjqwy'
PORT = 8796
def _b64(b): return base64.urlsafe_b64encode(b).rstrip(b'=').decode()
def _jwt(sub, email, secret=b"test-secret-test-secret-test-secret-0123456789"):
    h = _b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    p = _b64(json.dumps({"sub": sub, "role": "authenticated", "email": email, "aud": "authenticated", "exp": int(time.time()) + 86400}).encode())
    return h + '.' + p + '.' + _b64(hmac.new(secret, (h + '.' + p).encode(), hashlib.sha256).digest())
JWT = _jwt("00000000-0000-4000-a000-000000000001", "casaro@test.it")
RUN = time.strftime('%H%M%S'); LT = 'MT' + RUN; LY = 'MY' + RUN

def sql(q):
    r = subprocess.run(['su', 'postgres', '-c', f'psql -At -d restore_drill -c "{q}"'], capture_output=True, text=True)
    return r.stdout.strip() or r.stderr.strip()

TODAY = sql("select ((now() at time zone 'Europe/Rome')::date)::text")
YDAY = sql("select ((now() at time zone 'Europe/Rome')::date - 1)::text")
YDAY_IT = '/'.join(reversed(YDAY.split('-')))
sup = sql("select id from fabula.parties where is_milk_supplier and active order by created_at limit 1")
sql(f"insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source) values ('{TODAY}', '07:00', '{sup}', '{LT}', 300, true, 4, 'tablet')")
sql(f"insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source) values ('{YDAY}', '07:00', '{sup}', '{LY}', 400, true, 4, 'tablet')")
inputs = lambda lot: sql(f"select count(*) from fabula.batch_milk_inputs i join fabula.milk_intake m on m.id = i.milk_intake_id where m.milk_lot = '{lot}'")

srv = subprocess.Popen(['python3', '-m', 'http.server', str(PORT)], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(1)
sess = {"access_token": JWT, "refresh_token": "r", "expires_at": int(time.time()) + 86400, "expires_in": 86400, "token_type": "bearer",
        "user": {"id": "00000000-0000-4000-a000-000000000001", "email": "casaro@test.it", "aud": "authenticated", "role": "authenticated"}}

def handler(route):
    url = route.request.url
    if '/rest/v1/' in url:
        return route.fulfill(response=route.fetch(url='http://127.0.0.1:3000/' + url.split('/rest/v1/', 1)[1]))
    if '/auth/v1/' in url:
        return route.fulfill(status=200, content_type='application/json', body=json.dumps(sess['user']), headers={'access-control-allow-origin': '*'})
    return route.fulfill(status=200, body='{}', headers={'access-control-allow-origin': '*'})

fails = []
def check(name, cond, info=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f'  [{info}]' if info else ''))
    if not cond: fails.append(name)

RULE = 'si lavora solo il giorno in cui arriva'
try:
  with sync_playwright() as p:
    b = p.chromium.launch(); ctx = b.new_context(service_workers='block', viewport={'width': 800, 'height': 1280})
    ctx.route('**/*.supabase.co/**', handler)
    pg = ctx.new_page(); logs = []
    pg.on('pageerror', lambda e: logs.append('PAGEERROR ' + str(e)))
    pg.goto(f'http://localhost:{PORT}/labels.html')
    pg.evaluate(f"localStorage.clear(); localStorage.setItem('sb-{REF}-auth-token', {json.dumps(json.dumps(sess))}){op_js(sess)}")
    view = lambda: pg.evaluate("(document.querySelector('.view.active')||{}).id")
    toast = lambda: pg.evaluate("document.getElementById('toast').textContent")
    def home():
        pg.goto(f'http://localhost:{PORT}/index.html')
        pg.wait_for_function("document.querySelector('#v-home.active')", timeout=20000); pg.wait_for_timeout(3000)
    tiles = lambda lot, sel: pg.evaluate(f"[...document.querySelectorAll('#plan {sel}')].filter(d => d.innerText.includes('{lot}')).map(d => d.className + ' :: ' + d.innerText.replace(/\\n/g, ' | '))")
    note = lambda: pg.evaluate("[...document.querySelectorAll('#form .limit')].map(e => e.textContent).join(' || ')")
    def code(c): pg.evaluate("c => { document.getElementById('manual').value = c; document.getElementById('btn-manual').click(); }", c); pg.wait_for_timeout(1800)
    def setf(vals):
        for k, v in vals.items(): pg.evaluate("([k, v]) => { const e = document.getElementById(k); e.value = v; e.dispatchEvent(new Event('input', { bubbles: true })); e.dispatchEvent(new Event('change')); }", [k, str(v)])
    def save_form(): pg.evaluate("(() => { const v = document.getElementById('valve'); if (v && !v.value) v.value = '0'; const p = document.getElementById('past'); if (p && p.required && !p.value) p.value = '72.5'; const c = document.getElementById('ccpv'); if (c && !c.value) c.value = (c.previousElementSibling && /CCP 4/.test(c.previousElementSibling.textContent)) ? '88' : '65'; })()"); pg.evaluate("document.getElementById('btn-form-save').click()"); pg.wait_for_timeout(1500)
    def dose_through(n=0):
        while view() == 'v-dose' and n < 40: pg.evaluate("(() => { const ok = document.getElementById('d-ok'); if (ok.style.display === 'none') { const i = document.getElementById('d-alt-in'); const m = (document.getElementById('d-instr').textContent.match(/Obiettivo ([0-9.,]+)/) || [])[1]; i.value = (m || '70').replace(',', '.'); document.getElementById('d-alt-ok').click(); } else ok.click(); })()"); pg.wait_for_timeout(800); n += 1
        return n
    def paper(day, hm):
        if not pg.evaluate("document.getElementById('pp-on').checked"): pg.check('#pp-on')
        pg.fill('#pday', day); pg.fill('#ptime', hm); pg.select_option('#pwho', 'Test Casaro')

    home()
    go_t, go_y = tiles(LT, '.task.go'), tiles(LY, '.task.go')
    check("Home proposes today's milk, «da lavorare oggi»", len(go_t) == 1 and 'da lavorare oggi' in go_t[0] and '300 kg di latte ' + LT in go_t[0], str(go_t)[:300])
    check("Home does not propose yesterday's milk", not go_y, str(go_y)[:300])
    red = tiles(LY, '.task.overdue')
    check("yesterday's milk shown apart in red, with the rule",
          len(red) == 1 and ' go' not in red[0] and f'Latte {LY} del {YDAY_IT}' in red[0] and '400 kg non lavorati il giorno di arrivo' in red[0]
          and 'regola del caseificio' in red[0], str(red)[:300])
    pg.screenshot(path='/tmp/v120_home.png')

    code('LOT:' + LY)
    n = note()
    check("scanning yesterday's milk: the batch start opens with the rule written on it",
          view() == 'v-form' and f'Il latte {LY} è arrivato il {YDAY_IT}' in n and RULE in n and 'ricopiare dal foglio di carta' in n, n[:300])
    pg.screenshot(path='/tmp/v120_start_old.png')
    setf({'kg': 400}); save_form()
    check('a start today from yesterday\'s milk is refused with the rule, nothing in the database',
          view() == 'v-form' and RULE in toast() and inputs(LY) == '0', toast()[:200] + ' · inputs ' + inputs(LY))
    paper(TODAY, '00:00'); save_form()                    # 00:00: never in the future, whatever the time of the run
    check('a paper copy dated today is refused too', view() == 'v-form' and RULE in toast() and inputs(LY) == '0', toast()[:200] + ' · inputs ' + inputs(LY))
    paper(YDAY, '09:00'); save_form(); answer_ask(pg, wait=0); dose_through()
    started = sql(f"select to_char(b.started_at at time zone 'Europe/Rome', 'YYYY-MM-DD HH24:MI') || '|' || i.qty_kg from fabula.batch_milk_inputs i join fabula.milk_intake m on m.id = i.milk_intake_id join fabula.production_batches b on b.id = i.batch_id where m.milk_lot = '{LY}'")
    check("a paper copy dated yesterday (the milk's day) is taken: the vat has yesterday's time", started == f'{YDAY} 09:00|400.000', started + ' · ' + toast()[:200])

    home()
    check("Home no longer shows yesterday's milk once it is all in a vat", not tiles(LY, '.task'), str(tiles(LY, '.task'))[:300])
    pg.evaluate(f"[...document.querySelectorAll('#plan .task.go')].find(d => d.innerText.includes('{LT}')).click()"); pg.wait_for_timeout(1800)
    check("today's tile opens the start without the rule's note", view() == 'v-form' and RULE not in note() and pg.evaluate("document.getElementById('kg').value") == '300', note()[:200])
    save_form(); answer_ask(pg, wait=0); dose_through()
    check("today's milk starts from the tile", inputs(LT) == '1', toast()[:200])
    check('no page errors', not logs, ' | '.join(logs)[:300])
    b.close()
finally:
    srv.terminate()
print('FAILURES:', fails or 'none')
