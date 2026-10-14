"""v1.00 audit alerts and operations in the browser, against the local copy (restore_drill + setup.sql + PostgREST on :3000, v100a–c applied).
The browser runs in Italian (locale it-IT). Port 8780.
- E-13   Configurazione → Bot: the cards say what the bot does first, the nickname under it; the database's own senders have none.
- E-08   a message carries a button to the page where it is fixed; a link outside the app never reaches the page.
- E-04   «Segna come letta» is per person (another person still has it to read and sees who saw it); «Segna tutto» never closes alarms;
         the bell shows the open alarms first.
- C-12   «Risolto…» asks what was done, closes the alarm for everyone, and only «gestisce» in Sistema sees it.
- E-21   «Esegui ora (versione del database)» on a bot the database stands in for: asks naming the effect, asks again the second time;
         not offered to a profile that only «vede» Sistema.
- E-20   admin.html#bots&fermi opens «Bot fermi: cosa fare».
- E-08   console.html#oggi&appr=<id> opens Oggi on that request, highlighted; a request already decided says so.
- E-03/E-09  Console → Oggi «Avvisi aperti»: office notices and open alarms with their link, «Risolto…» there too; the tablet shows
         only the floor's notices.
- E-21   Autocontrollo → Registri «Registrazioni rifiutate»: what, values, «HACCP: da rifare oggi», «Segna come rifatta» with a note.
Expect "FAILURES: none"."""
import json, subprocess, time, os, hmac, hashlib, base64
from playwright.sync_api import sync_playwright
from e2e_op import op_js

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../../../fabula-tablet'))
REF = 'ojkquhzaeypsphncjqwy'; PORT = 8780
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
CASARO = ("00000000-0000-4000-a000-000000000001", "casaro@test.it")
OWNER = ("00000000-0000-4000-a000-0000000000d1", "alerts-owner@test.it")
UFF = ("00000000-0000-4000-a000-0000000000d2", "alerts-ufficio@test.it")
for (uid, em), (sid, name, role, job) in [(OWNER, ('10000000-0000-4000-a000-0000000000d1', 'Titolare Alerts', 'titolare', 'owner')),
                                          (UFF, ('10000000-0000-4000-a000-0000000000d2', 'Ufficio Alerts', 'amministrazione', 'operaio'))]:
    sql(f"insert into auth.users(id, email) values ('{uid}', '{em}') on conflict do nothing")
    sql(f"insert into fabula.staff(id, full_name, auth_user_id, app_role, role, active) values ('{sid}', '{name}', '{uid}', '{role}', '{job}', true) on conflict do nothing")
TODAY = sql1("select (now() at time zone 'Europe/Rome')::date")
WD = lambda n: sql1(f"select g::date from generate_series((now() at time zone 'Europe/Rome')::date + 1, (now() at time zone 'Europe/Rome')::date + 30, interval '1 day') g where extract(isodow from g) <> 7 order by g offset {n - 1} limit 1")
D1 = WD(1)
# ---- a clean feed: what the other suites left is closed ----
sql("update fabula.bot_messages set read_at = now() where read_at is null")
sql("update fabula.approvals set status = 'expired' where status = 'pending'")
sql("update fabula.notices set resolved_at = now() where resolved_at is null")
sql(f"delete from fabula.milk_plans where plan_date >= '{TODAY}'")
# ---- messages ----
M_W = sql1(f"select fabula.post_bot_message('sales', 'warn', 'Alerts da controllare {RUN}', 'Corpo {RUN}', null, 'vendite.html#oggi')")
M_EXT = sql1(f"select fabula.post_bot_message('procurement', 'warn', 'Alerts link esterno {RUN}', 'x', null, 'https://evil.example/console.html')")
M_A = sql1(f"select fabula.post_bot_message('compliance_calendar', 'alert', 'Alerts allarme {RUN}', 'Taratura scaduta')")
M_A2 = sql1(f"select fabula.post_bot_message('shopify_orders', 'alert', 'Alerts secondo allarme {RUN}', 'Connettore scaduto')")
A1 = sql1(f"select fabula.plan_milk('{D1}') ->> 'approval_id'")
sql(f"update fabula.approvals set auto_approve_at = null, auto_rule = null where id = '{A1}'")
M_MILK = sql1(f"select fabula.post_bot_message('milk_planning', 'info', 'Alerts piano latte {RUN}', 'x')")
A_DONE = sql1("insert into fabula.approvals (kind, requested_by, summary, payload, status, decided_by, decided_at) values ('price_change', 'agent:sell_down', 'Promo decisa', "
              "jsonb_build_object('type', 'sell_down', 'sku', 'MOZ-DOP-KG', 'lot', 'L-AL', 'promo_pct', 20), 'approved', 'Titolare Alerts', now()) returning id")
# ---- notices: one for the office, one for the floor ----
sql(f"insert into fabula.notices (key, severity, title_it, items, expires_at) values ('infra_git', 'warn', 'Alerts git {RUN}', '[]', now() + interval '1 day') "
    "on conflict (key) do update set title_it = excluded.title_it, items = excluded.items, resolved_at = null, expires_at = excluded.expires_at")
sql(f"insert into fabula.notices (key, severity, title_it, items, expires_at) values ('haccp_evening', 'alert', 'Alerts serata {RUN}', "
    f"jsonb_build_array(jsonb_build_object('label_it', 'Temperatura cella {RUN}', 'scan', 'EQ:CELLA-1')), now() + interval '1 day') "
    "on conflict (key) do update set title_it = excluded.title_it, items = excluded.items, resolved_at = null, expires_at = excluded.expires_at")
# ---- a refused HACCP save ----
QID = 'AL-' + RUN
sql(f"insert into fabula.tablet_rejects (qid, device_uid, device_label, staff_id, what, ops, error, code, failed_at, reported_at) values ('{QID}', 'dev-al', 'tablet-al', "
    f"(select id from fabula.staff where auth_user_id = '{CASARO[0]}'), 'log_ccp', "
    "'[{\\\"rpc\\\":\\\"log_ccp\\\",\\\"args\\\":{\\\"p_ccp_code\\\":\\\"CCP-3\\\",\\\"p_value\\\":61.5,\\\"p_batch_lot\\\":\\\"LAL-1\\\"}}]', 'valore fuori limite', '23514', now() - interval '1 hour', now())")

srv = subprocess.Popen(['python3', '-m', 'http.server', str(PORT)], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1)
fails = []
def check(name, cond, info=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f'  [{info}]' if info else ''))
    if not cond: fails.append(name)
class Dlg:
    """answers browser dialogs in order: True = OK, False = Annulla, a string = the text for a prompt"""
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
msg = lambda i: f"document.querySelector('#bd-feed .msg[data-ids*=\"{i}\"], #bd-feed .msg[data-open*=\"{i}\"]')"
def msg_by_title(pg, t):
    return pg.evaluate("t => { const m = [...document.querySelectorAll('#bd-feed .msg')].find(x => x.querySelector('.t').textContent.includes(t)); return m ? m.innerText + '||' + m.className : ''; }", t)

try:
  with sync_playwright() as p:
    b = p.chromium.launch(); logs = []
    # ================= Configurazione → Bot, as the owner =================
    ctx, ap = page_as(b, OWNER, 'admin.html#bots', logs)
    ap.wait_for_timeout(6000); dl = Dlg(ap)
    cards = ap.evaluate("Object.fromEntries([...document.querySelectorAll('#bd-bots .botc')].map(c => [c.dataset.a, [c.querySelector('.nm').textContent, (c.querySelector('.ti') || {}).textContent || '']]))")
    check('E-13 a card says what the bot does, the nickname under it', cards.get('milk_planning') == ['Piano latte', 'Zio Gennaro'], str(cards.get('milk_planning')))
    check('E-13 the database\'s own senders have no nickname', cards.get('sicurezza') == ['Sicurezza alimentare', ''] and cards.get('turni') == ['Turni', ''], str([cards.get('sicurezza'), cards.get('turni')]))
    al_open = int(sql1("select count(*) from fabula.bot_messages where read_at is null and severity = 'alert'"))
    bell = ap.evaluate("document.getElementById('bell-n').textContent")
    check('E-04 the bell shows the open alarms first', bell.startswith(f'{al_open} allarm'), bell + f' (open alarms {al_open})')
    w = msg_by_title(ap, f'Alerts da controllare {RUN}')
    link = ap.evaluate(f"(() => {{ const m = [...document.querySelectorAll('#bd-feed .msg')].find(x => x.innerText.includes('Alerts da controllare {RUN}')); const a = m && m.querySelector('a.go'); return a ? a.getAttribute('href') + '|' + a.textContent : ''; }})()")
    check('E-08 a message has a button to where it is fixed', link == 'vendite.html#oggi|Apri Vendite →', link)
    ext = ap.evaluate(f"(() => {{ const m = [...document.querySelectorAll('#bd-feed .msg')].find(x => x.innerText.includes('Alerts link esterno {RUN}')); return m ? [...m.querySelectorAll('a')].map(a => a.getAttribute('href')).join(',') : 'none'; }})()")
    check('E-08 a link outside the app never reaches the page (the bot\'s own page instead)', ext == 'console.html#oggi', ext)
    who = ap.evaluate(f"(() => {{ const m = [...document.querySelectorAll('#bd-feed .msg')].find(x => x.innerText.includes('Alerts piano latte {RUN}')); const a = m && m.querySelector('a.go'); return m ? m.querySelector('.who').innerText + '|' + (a ? a.getAttribute('href') : '') : ''; }})()")
    check('E-08/E-13 the milk plan message: «Piano latte · Zio Gennaro», opens its request', who.replace('\n', ' ').startswith('Piano latte') and 'Zio Gennaro' in who and who.endswith(f'console.html#oggi&appr={A1}'), who)
    # per-person read
    ap.evaluate(f"(() => {{ const m = [...document.querySelectorAll('#bd-feed .msg')].find(x => x.innerText.includes('Alerts da controllare {RUN}')); m.querySelector('[data-x=read]').click(); }})()")
    ap.wait_for_timeout(2500)
    r = sql1(f"select (select count(*) from fabula.bot_message_reads where message_id = {M_W} and staff_id = '10000000-0000-4000-a000-0000000000d1') || '|' || (read_at is null) from fabula.bot_messages where id = {M_W}")
    check('E-04 «Segna come letta» is for me only: my read is kept, the message stays open for the others', r == '1|true', r)
    check('E-04 …and it leaves my «Da leggere» list', msg_by_title(ap, f'Alerts da controllare {RUN}') == '', msg_by_title(ap, f'Alerts da controllare {RUN}')[:120])
    # «Risolto…» with a note
    has_fix = ap.evaluate(f"(() => {{ const m = [...document.querySelectorAll('#bd-feed .msg')].find(x => x.innerText.includes('Alerts allarme {RUN}')); return m ? !!m.querySelector('[data-x=fix]') : null; }})()")
    check('C-12 an open alarm has «Risolto…» for whoever manages the system', has_fix is True, str(has_fix))
    ap.evaluate(f"(() => {{ const m = [...document.querySelectorAll('#bd-feed .msg')].find(x => x.innerText.includes('Alerts allarme {RUN}')); m.querySelector('[data-x=fix]').click(); }})()")
    ap.wait_for_timeout(300)
    ap.evaluate(f"(() => {{ const m = [...document.querySelectorAll('#bd-feed .msg')].find(x => x.innerText.includes('Alerts allarme {RUN}')); m.querySelector('.fixf input').value = 'ok'; m.querySelector('[data-x=fixok]').click(); }})()")
    ap.wait_for_timeout(1200)
    t1 = toast(ap)
    check('C-12 «Risolto» asks what was done', 'Scrivi cosa è stato fatto' in t1 and sql1(f"select resolved_at is null from fabula.bot_messages where id = {M_A}") == 't', t1)
    ap.evaluate(f"(() => {{ const m = [...document.querySelectorAll('#bd-feed .msg')].find(x => x.innerText.includes('Alerts allarme {RUN}')); m.querySelector('.fixf input').value = 'Taratura fatta, certificato in archivio'; m.querySelector('[data-x=fixok]').click(); }})()")
    ap.wait_for_timeout(2500)
    r = sql1(f"select (resolved_at is not null) || '|' || (read_at is not null) || '|' || coalesce(resolution, '') || '|' || coalesce((select full_name from fabula.staff where id = resolved_by_id), '') from fabula.bot_messages where id = {M_A}")
    check('C-12 …then the alarm is closed for everyone, with who and what', r == 'true|true|Taratura fatta, certificato in archivio|Titolare Alerts', r + ' · ' + toast(ap))
    ap.evaluate("document.querySelector('.bd-bar .chip[data-f=all]').click()"); ap.wait_for_timeout(2500)
    done = msg_by_title(ap, f'Alerts allarme {RUN}')
    check('C-12 «Tutte» shows it as solved, by whom and with the note', 'Risolto da Titolare Alerts' in done and 'Taratura fatta' in done, done.replace('\n', ' | ')[:240])
    ap.evaluate("document.querySelector('.bd-bar .chip[data-f=unread]').click()"); ap.wait_for_timeout(2000)
    # «Segna tutto come letto» never closes the alarms
    dl.answers = [True]; ap.evaluate("document.getElementById('bd-readall').click()"); ap.wait_for_timeout(3000)
    r = sql1(f"select (read_at is null) || '|' || (resolved_at is null) from fabula.bot_messages where id = {M_A2}")
    still = msg_by_title(ap, f'Alerts secondo allarme {RUN}')
    check('E-04 «Segna tutto come letto» asks (only for me) and leaves the alarms open', dl.log and 'solo per te' in dl.log[-1] and r == 'true|true' and still != '', ' / '.join(dl.log[-1:]) + ' · ' + r)
    # «Esegui ora»
    ap.evaluate("document.querySelector('#bd-bots .botc[data-a=wholesale_orders]').click()"); ap.wait_for_timeout(3000)
    rn = ap.evaluate("(() => { const r = document.getElementById('bd-run'); return r.hidden ? '' : r.innerText; })()")
    check('E-21 a bot the database can stand in for offers «Esegui ora (versione del database)» with what it does', 'Esegui ora (versione del database)' in rn and 'ordini fissi' in rn, rn.replace('\n', ' | '))
    n0 = int(sql1("select count(*) from fabula.agent_runs where agent = 'wholesale_orders' and details->>'manual' = 'true'"))
    dl.answers = [True]; ap.evaluate("document.getElementById('bd-run-go').click()"); ap.wait_for_timeout(4000)
    n1 = int(sql1("select count(*) from fabula.agent_runs where agent = 'wholesale_orders' and details->>'manual' = 'true' and details->>'by' = 'Titolare Alerts'"))
    check('E-21 it asks first naming the effect, then runs and is recorded with my name', dl.log and 'eseguire adesso la versione del database' in dl.log[-1] and 'ordini fissi' in dl.log[-1] and n1 == n0 + 1 and toast(ap).startswith('Fatto'),
          ' / '.join(dl.log[-1:]) + f' · runs {n0}→{n1} · ' + toast(ap))
    dl.answers = [True, False]; ap.evaluate("document.getElementById('bd-run-go').click()"); ap.wait_for_timeout(4000)
    n2 = int(sql1("select count(*) from fabula.agent_runs where agent = 'wholesale_orders' and details->>'manual' = 'true'"))
    check('E-21 the second time the same day it asks again («ha già girato oggi»); «Annulla» runs nothing', len(dl.log) >= 2 and 'ha già girato oggi' in dl.log[-1] and n2 == n1, ' / '.join(dl.log[-2:]) + f' · runs {n2}')
    ctx.close()

    # ================= the same feed, as the office (Sistema «vede») =================
    ctx2, up = page_as(b, UFF, 'admin.html#bots', logs)
    up.wait_for_timeout(6000)
    w2 = msg_by_title(up, f'Alerts da controllare {RUN}')
    check('E-04 another person still has it to read, and sees who saw it', w2 != '' and 'Visto da Titolare Alerts' in w2 and ' read' not in w2.split('||')[-1], w2.replace('\n', ' | ')[:200])
    a2 = up.evaluate(f"(() => {{ const m = [...document.querySelectorAll('#bd-feed .msg')].find(x => x.innerText.includes('Alerts secondo allarme {RUN}')); return m ? (m.querySelector('[data-x=fix]') ? 'fix' : 'nofix') + '|' + m.innerText : ''; }})()")
    check('C-12 «Risolto…» is not offered to a profile that only «vede» Sistema', a2.startswith('nofix|'), a2[:120])
    up.evaluate("document.querySelector('#bd-bots .botc[data-a=wholesale_orders]').click()"); up.wait_for_timeout(2500)
    check('E-21 «Esegui ora» is not offered to that profile', up.evaluate("document.getElementById('bd-run').hidden") is True)
    ctx2.close()

    # ================= Bot fermi: cosa fare =================
    ctx3, fp = page_as(b, OWNER, 'admin.html#bots&fermi', logs)
    fp.wait_for_timeout(5000)
    st = fp.evaluate("[document.querySelector('.pane.active').id, document.getElementById('bd-fermi').open, document.getElementById('bd-fermi').innerText]")
    check('E-20 admin.html#bots&fermi opens «Bot fermi: cosa fare» on the Bot tab', st[0] == 'p-bots' and st[1] is True and 'Esegui ora' in st[2] and 'Le automazioni del database sono ferme' in st[2], str(st[:2]))
    ctx3.close()

    # ================= Console → Oggi =================
    ctx4, cp = page_as(b, OWNER, f'console.html#oggi&appr={A1}', logs)
    cp.wait_for_timeout(7000)
    hl = cp.evaluate(f"(() => {{ const c = document.querySelector('#approvals .appr[data-id=\"{A1}\"]'); if (!c) return 'none'; const r = c.getBoundingClientRect(); return c.className + '|' + (r.top < innerHeight && r.bottom > 0) + '|' + c.querySelector('.by').textContent; }})()")
    check('E-08 console.html#oggi&appr=<id> opens Oggi on that request, highlighted and in view', hl.startswith('appr hl|true|'), hl)
    check('E-13 «proposto da Piano latte · Zio Gennaro»', 'proposto da Piano latte · Zio Gennaro' in hl, hl)
    av = cp.evaluate("(() => { const c = document.getElementById('c-avvisi'); return c.hidden ? '' : c.innerText; })()")
    check('E-03/E-09 «Avvisi aperti»: the office notice and the open alarm, not the notices\' feed copies', f'Alerts git {RUN}' in av and f'Alerts secondo allarme {RUN}' in av and f'Alerts serata {RUN}' in av and av.count('Alerts git') == 1, av.replace('\n', ' | ')[:400])
    gl = cp.evaluate(f"(() => {{ const c = [...document.querySelectorAll('#avvisi .av')].find(x => x.innerText.includes('Alerts git {RUN}')); const a = c && c.querySelector('a.go'); return a ? a.getAttribute('href') + '|' + a.textContent : ''; }})()")
    check('E-08 …each with where it is fixed', gl == 'admin.html#panoramica|Apri Configurazione →', gl)
    cp.evaluate(f"(() => {{ const c = [...document.querySelectorAll('#avvisi .av')].find(x => x.innerText.includes('Alerts secondo allarme {RUN}')); c.querySelector('[data-x=fix]').click(); c.querySelector('.fixf input').value = 'Connettore ricollegato'; c.querySelector('[data-x=fixok]').click(); }})()")
    cp.wait_for_timeout(2500)
    r = sql1(f"select coalesce(resolution, '') from fabula.bot_messages where id = {M_A2}")
    av2 = cp.evaluate("document.getElementById('avvisi').innerText")
    check('C-12 «Risolto…» from the Console closes it for everyone and it leaves the card', r == 'Connettore ricollegato' and f'Alerts secondo allarme {RUN}' not in av2, r)
    ctx4.close()
    ctx5, cp2 = page_as(b, OWNER, f'console.html#oggi&appr={A_DONE}', logs)
    cp2.wait_for_timeout(7000)
    st = cp2.evaluate("[document.getElementById('c-recent').open, (document.getElementById('toast') || {}).textContent]")
    check('E-08 a request already decided: says so and opens «Decise di recente»', st[0] is True and 'non è più in attesa' in (st[1] or ''), str(st))
    ctx5.close()

    # ================= tablet: only the floor's notices =================
    ctx6, tp = page_as(b, CASARO, 'index.html', logs, 800)
    tp.wait_for_function("document.querySelector('#v-home.active')", timeout=20000); tp.wait_for_timeout(4000)
    nw = tp.evaluate("(document.getElementById('notice-wrap') || {}).innerText || ''")
    check('E-03 the tablet shows the evening HACCP notice and not the office ones (git)', f'Alerts serata {RUN}' in nw and f'Alerts git {RUN}' not in nw, nw.replace('\n', ' | ')[:300])
    ctx6.close()

    # ================= Autocontrollo → Registri: refused saves =================
    ctx7, hp = page_as(b, OWNER, 'haccp.html#registri', logs)
    hp.wait_for_timeout(6000)
    rj = hp.evaluate(f"(() => {{ const c = document.getElementById('c-rej'); const r = document.querySelector('.rej[data-q=\"{QID}\"]'); return (c.hidden ? 'hidden' : 'shown') + '|' + (r ? r.innerText : ''); }})()")
    check('E-21 «Registrazioni rifiutate»: what, the values in one line, who, «HACCP: da rifare oggi»',
          rj.startswith('shown|') and 'Misura CCP' in rj and 'batch_lot: LAL-1 · ccp_code: CCP-3 · value: 61.5' in rj and 'HACCP: DA RIFARE OGGI' in rj.upper() and 'Casaro' in rj, rj.replace('\n', ' | ')[:300])
    hp.evaluate(f"(() => {{ const r = document.querySelector('.rej[data-q=\"{QID}\"]'); r.querySelector('input').value = 'rifatta dal tablet alle 10:40'; r.querySelector('[data-rej]').click(); }})()")
    hp.wait_for_timeout(2500)
    r = sql1(f"select coalesce(resolved_by, '') || '|' || coalesce(resolution, '') from fabula.tablet_rejects where qid = '{QID}'")
    moved = hp.evaluate(f"(() => {{ const r = document.querySelector('.rej[data-q=\"{QID}\"]'); return r ? !!r.closest('details') : null; }})()")
    check('E-21 «Segna come rifatta» with a note: closed with who and what, moved to «Chiuse»', r == 'Titolare Alerts|rifatta dal tablet alle 10:40' and moved is True, r + f' · moved {moved}')
    ctx7.close()

    sql(f"update fabula.notices set resolved_at = now() where key in ('infra_git', 'haccp_evening') and resolved_at is null")
    errs = [l for l in logs if 'PAGEERROR' in l]
    check('no page errors', not errs, ' | '.join(errs[:3]))
finally:
    srv.terminate()
print('FAILURES:', fails or 'none')
