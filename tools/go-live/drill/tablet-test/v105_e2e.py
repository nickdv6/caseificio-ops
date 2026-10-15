"""v1.05 in the browser, against the local copy (restore_drill + setup.sql + PostgREST on :3000, v105a–c applied). Port 8784.
The browser runs in Italian; the tablet's clock is set (Playwright clock) to 09:30 and 15:30 Rome of the database's day.
- E-31 at 09:30 the tablet shows «Ieri non registrato» with yesterday's food-safety gaps; an item opens «Ricopia da foglio di carta»
       on yesterday's date with the lot filled in.
- E-31 at 15:30 the live list «Prima di chiudere: N cose da registrare», once (the 19:02 notice of the same day is not shown twice).
- E-31 «Fine turno: esco» after 14:00 with food-safety records missing asks first; «Li registro adesso» keeps the shift open,
       «Esco lo stesso» closes it.
- E-09 a marketing profile (no Configurazione) has the bell «Avvisi» with the open alarms of its areas, opening Console → Oggi, where
       «Avvisi aperti» lists them (not the food-safety one).
- E-14/E-28 Configurazione → Panoramica → Sistema lists the system checks in Italian.
- E-30 «Verso l'apertura»: the list in Italian; «Segna fatto…» needs a note and a confirmation, then shows who and when; «Annulla…»
       asks why. The office (Sistema «vede») sees the list without the buttons.
Expect "FAILURES: none"."""
import json, subprocess, time, os, hmac, hashlib, base64
from playwright.sync_api import sync_playwright
from e2e_op import op_js

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../../../fabula-tablet'))
REF = 'ojkquhzaeypsphncjqwy'; PORT = 8784
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
def as_user(uid, q):   # the same call as that login (the database's view of «my» alarms)
    return (sql(f"select set_config('request.jwt.claims', '{{\\\"sub\\\":\\\"{uid}\\\",\\\"role\\\":\\\"authenticated\\\"}}', false); {q}").splitlines() or [''])[-1]

RUN = time.strftime('%H%M%S')
CASARO = ("00000000-0000-4000-a000-000000000001", "casaro@test.it")
OWNER = ("00000000-0000-4000-a000-0000000105e1", "v105-owner@test.it")
MKT = ("00000000-0000-4000-a000-0000000105e2", "v105-mkt@test.it")
UFF = ("00000000-0000-4000-a000-0000000105e3", "v105-uff@test.it")
for (uid, em), (sid, name, role, job) in [(OWNER, ('10000000-0000-4000-a000-0000000105e1', 'Titolare V105', 'titolare', 'owner')),
                                          (MKT, ('10000000-0000-4000-a000-0000000105e2', 'Marketing V105', 'marketing', 'operaio')),
                                          (UFF, ('10000000-0000-4000-a000-0000000105e3', 'Ufficio V105', 'amministrazione', 'operaio'))]:
    sql(f"insert into auth.users(id, email) values ('{uid}', '{em}') on conflict do nothing")
    sql(f"insert into fabula.staff(id, full_name, auth_user_id, app_role, role, active) values ('{sid}', '{name}', '{uid}', '{role}', '{job}', true) on conflict do nothing")
TODAY = sql1("select (now() at time zone 'Europe/Rome')::date")
Y = sql1("select (now() at time zone 'Europe/Rome')::date - 1")
# Playwright's clock (Python) takes seconds since 1970
T0930 = int(sql1(f"select extract(epoch from ('{TODAY}'::date + time '09:30') at time zone 'Europe/Rome')::bigint"))
T1530 = int(sql1(f"select extract(epoch from ('{TODAY}'::date + time '15:30') at time zone 'Europe/Rome')::bigint"))
MOZ = sql1("select id from fabula.products where sku = 'MOZ-DOP-KG'")
LOT = 'LV5' + RUN
# a clean feed and notices
sql("update fabula.bot_messages set read_at = now() where read_at is null")
sql("update fabula.notices set resolved_at = now() where resolved_at is null")
sql("update fabula.shifts set clock_out = now() where clock_out is null")
# yesterday: a real lot without its stretching check
sql(f"insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, output_kg, input_kind, started_at, finished_at, source) values "
    f"('{Y}', '{LOT}', '{MOZ}', 300, 60, 'milk', ('{Y}'::date + time '08:00') at time zone 'Europe/Rome', ('{Y}'::date + time '12:00') at time zone 'Europe/Rome', 'tablet')")
# alarms: one for sales (vendite), one for food safety (haccp)
A_SALES = sql1(f"select fabula.post_bot_message('sales', 'alert', 'V105 cliente perso {RUN}', 'x')")
A_HACCP = sql1(f"select fabula.post_bot_message('sicurezza', 'alert', 'Lotto {LOT} chiuso senza filatura {RUN}', 'x')")
# today's 19:02 notice exists too (same title as the live list): the tablet must show the list once
sql(f"select fabula.haccp_evening_status('{TODAY}')")
# someone on shift to badge out
BADGE = sql1(f"insert into fabula.staff (full_name, role, app_role, active) values ('Aiuto V105 {RUN}', 'commesso', 'banco', true) returning badge_code")
sql(f"select fabula.badge_in('{BADGE}')")
sql("update fabula.dash_checks set done = false, done_by_id = null, done_at = null where key = 'paper_fallback'")

srv = subprocess.Popen(['python3', '-m', 'http.server', str(PORT)], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1)
fails = []
def check(name, cond, info=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f'  [{info}]' if info else ''))
    if not cond: fails.append(name)
def page_as(b, who, path, logs, width=1100, clock=None, operator=False):
    s = {"access_token": _jwt(*who), "refresh_token": "r", "expires_at": int(time.time()) + 86400, "expires_in": 86400, "token_type": "bearer",
         "user": {"id": who[0], "email": who[1], "aud": "authenticated", "role": "authenticated"}}
    def handler(route):
        try:
            u = route.request.url
            if '/rest/v1/' in u: return route.fulfill(response=route.fetch(url='http://127.0.0.1:3000/' + u.split('/rest/v1/', 1)[1]))
            if '/auth/v1/' in u: return route.fulfill(status=200, content_type='application/json', body=json.dumps(s['user']), headers={'access-control-allow-origin': '*'})
            return route.fulfill(status=200, body='{}', headers={'access-control-allow-origin': '*'})
        except Exception: pass
    ctx = b.new_context(service_workers='block', viewport={'width': width, 'height': 1400}, locale='it-IT'); ctx.route('**/*.supabase.co/**', handler)
    pg = ctx.new_page(); pg.on('pageerror', lambda e: logs.append('PAGEERROR ' + str(e)))
    if clock: pg.clock.set_fixed_time(clock)
    pg.goto(f'http://localhost:{PORT}/labels.html')
    op = op_js(s) if operator else ''
    pg.evaluate(f"localStorage.clear(); localStorage.setItem('sb-{REF}-auth-token', {json.dumps(json.dumps(s))}){op}")
    # the one recording was chosen «now» on the tablet's (fake) clock, not on the real one
    if op and clock: pg.evaluate("() => { const o = JSON.parse(localStorage.getItem('perla_operator_v1')); o.at = o.last = Date.now(); localStorage.setItem('perla_operator_v1', JSON.stringify(o)); }")
    pg.goto(f'http://localhost:{PORT}/{path}')
    return ctx, pg
toast = lambda pg: pg.evaluate("(document.getElementById('toast') || {}).textContent || ''")
notices = lambda pg: pg.evaluate("[...document.querySelectorAll('#notice-wrap .notice')].map(n => n.className + '||' + n.innerText)")

try:
  with sync_playwright() as p:
    b = p.chromium.launch(); logs = []
    # ================= tablet at 09:30: yesterday's gaps =================
    ctx, tp = page_as(b, CASARO, 'index.html', logs, 800, clock=T0930, operator=True)
    tp.wait_for_function("document.querySelector('#v-home.active')", timeout=20000); tp.wait_for_timeout(4000)
    ns = notices(tp)
    yb = next((n for n in ns if 'Ieri non registrato:' in n), '')
    check('E-31 at 09:30: «Ieri non registrato: N · ricopia dal foglio di carta», red, with yesterday\'s lot',
          yb.startswith('notice alert') and 'ricopia dal foglio di carta' in yb and f'lotto {LOT}' in yb, ' ## '.join(ns)[:400])
    check('E-31 …and not today\'s list in the morning', not any('Prima di chiudere' in n for n in ns), ' ## '.join(ns)[:200])
    tp.locator('#notice-wrap .nitem', has_text=f'lotto {LOT}').first.click(); tp.wait_for_timeout(2500)
    f = tp.evaluate("[document.getElementById('f-title').textContent, (document.getElementById('pday') || {}).value, (document.getElementById('lot') || {}).value]")
    check('E-31 the item opens the paper copy on yesterday\'s date, the lot filled in', f[1] == Y and f[2] == LOT, str(f))
    ctx.close()

    # ================= tablet at 15:30: the live list, once; badge-out asks =================
    ctx, tp = page_as(b, CASARO, 'index.html', logs, 800, clock=T1530, operator=True)
    tp.wait_for_function("document.querySelector('#v-home.active')", timeout=20000); tp.wait_for_timeout(4000)
    ns = notices(tp)
    live = [n for n in ns if 'Prima di chiudere:' in n]
    check('E-31 at 15:30: «Prima di chiudere: N cose da registrare», shown once (the 19:02 notice of today is not repeated)',
          len(live) == 1 and live[0].startswith('notice warn') and 'Temperatura serale' in live[0], ' ## '.join(ns)[:400])
    check('E-31 …yesterday\'s box is a morning thing', not any('Ieri non registrato' in n for n in ns))
    code = lambda c: (tp.evaluate("document.querySelectorAll('.view').forEach(e => e.classList.toggle('active', e.id === 'v-home'))"),
                      tp.evaluate("c => { document.getElementById('manual').value = c; document.getElementById('btn-manual').click(); }", c), tp.wait_for_timeout(2200))
    code(BADGE)                                   # becomes the one recording
    code(BADGE)                                   # the same badge again: the card with «Fine turno: esco»
    tp.locator('#form button', has_text='Fine turno: esco').click(); tp.wait_for_timeout(2500)
    ask = tp.evaluate("(document.querySelector('.ask') || {}).innerText || ''")
    check('E-31 «Fine turno: esco» after 14:00 asks first, naming the checks', 'Prima di uscire:' in ask and 'sicurezza alimentare da registrare' in ask and 'Temperatura serale' in ask
          and 'Esco lo stesso' in ask and 'Li registro adesso' in ask, ask.replace('\n', ' | ')[:300])
    tp.wait_for_timeout(1600); tp.evaluate("document.querySelectorAll('.ask button')[1].click()"); tp.wait_for_timeout(1500)
    check('E-31 «Li registro adesso»: the shift stays open', sql1(f"select count(*) from fabula.shifts s join fabula.staff st on st.id = s.staff_id where st.badge_code = '{BADGE}' and s.clock_out is null") == '1')
    tp.locator('#form button', has_text='Fine turno: esco').click(); tp.wait_for_timeout(2500)
    tp.wait_for_timeout(1600); tp.evaluate("document.querySelectorAll('.ask button')[0].click()"); tp.wait_for_timeout(2000)
    check('E-31 «Esco lo stesso»: the shift is closed', sql1(f"select count(*) from fabula.shifts s join fabula.staff st on st.id = s.staff_id where st.badge_code = '{BADGE}' and s.clock_out is null") == '0', toast(tp))
    ctx.close()

    # ================= Console as marketing: the bell and «Avvisi aperti» =================
    n_mkt = int(as_user(MKT[0], 'select jsonb_array_length(fabula.my_alarms())') or -1)
    ctx, cp = page_as(b, MKT, 'console.html#oggi', logs)
    cp.wait_for_timeout(7000)
    bell = cp.evaluate("(() => { const b = document.getElementById('bell'); return b ? b.getAttribute('href') + '|' + b.innerText : ''; })()")
    check('E-09 a marketing profile has the bell «Avvisi», opening Console → Oggi, with its open alarms', bell.startswith('console.html#oggi|Avvisi') and n_mkt >= 1
          and f"{n_mkt} allarm" in bell, bell + f' (database: {n_mkt})')
    av = cp.evaluate("(() => { const c = document.getElementById('c-avvisi'); return c && !c.hidden ? c.innerText : ''; })()")
    check('E-09 «Avvisi aperti» lists the sales alarm and not the food-safety one', f'V105 cliente perso {RUN}' in av and f'chiuso senza filatura {RUN}' not in av, av.replace('\n', ' | ')[:300])
    ctx.close()

    # ================= Configurazione → Panoramica as the titolare =================
    ctx, ap = page_as(b, OWNER, 'admin.html#panoramica', logs)
    ap.wait_for_timeout(8000)
    sysc = ap.evaluate("(() => { const c = [...document.querySelectorAll('#ov .ovc')].find(x => x.textContent.includes('Sistema')); return c ? c.textContent : ''; })()")
    check('E-14/E-28 the Sistema card carries the system checks in Italian', ('Sito e funzioni del server' in sysc or 'Segreto del backup' in sysc or 'Attività programmate' in sysc)
          and not any(w in sysc for w in ('Waiting', 'push from', 'Netlify has not', 'Last drill')), sysc.replace('\n', ' | ')[:300])
    gl = ap.evaluate("(() => { const c = document.getElementById('golive-card'); return c && !c.hidden ? document.getElementById('golive-n').textContent + '||' + c.innerText : ''; })()")
    n_items = sql1("select count(*) from fabula.dash_checks")
    check('E-30 «Verso l\'apertura» in Italian, with how each item closes (not the English working notes of Nick\'s board)', f' di {n_items} fatti' in gl and 'Atto di acquisto firmato dopo la due diligence' in gl
          and 'Fogli di carta pronti' in gl and 'Si segna a mano' in gl and 'Handshake' not in gl and 'Print the blank' not in gl, gl[:300].replace('\n', ' | '))
    li = "document.querySelector('#golive li[data-k=paper_fallback]')"
    ap.evaluate(f"{li}.querySelector('[data-gl=do]').click()"); ap.wait_for_timeout(300)
    ap.evaluate(f"(() => {{ const l = {li}; l.querySelector('.glf input').value = 'ok'; l.querySelector('[data-gl=ok]').click(); }})()"); ap.wait_for_timeout(1200)
    t1 = toast(ap)
    check('E-30 «Segna fatto» without a real note is refused', 'Scrivi cosa è stato fatto' in t1 and sql1("select done from fabula.dash_checks where key = 'paper_fallback'") == 'f', t1)
    dlg = []
    ap.on('dialog', lambda d: (dlg.append(d.message), d.accept()))
    ap.evaluate(f"(() => {{ const l = {li}; l.querySelector('.glf input').value = 'Fogli stampati {RUN}, nel raccoglitore HACCP'; l.querySelector('[data-gl=ok]').click(); }})()"); ap.wait_for_timeout(3000)
    r = sql1("select done || '|' || coalesce(sign_note, '') || '|' || coalesce((select full_name from fabula.staff where id = done_by_id), '') from fabula.dash_checks where key = 'paper_fallback'")
    check('E-30 …with a note and a confirmation it is done, with who', dlg and 'Resta nel Registro con il tuo nome' in dlg[-1] and r == f'true|Fogli stampati {RUN}, nel raccoglitore HACCP|Titolare V105', ' / '.join(dlg) + ' · ' + r)
    row = ap.evaluate(f"(() => {{ const l = {li}; return l ? (l.closest('details') ? 'fatti|' : 'aperti|') + l.textContent : ''; }})()")
    check('E-30 …and it moves to «Fatti», saying who and when', row.startswith('fatti|') and 'fatto da Titolare V105 il ' in row, row.replace('\n', ' | ')[:200])
    ap.evaluate(f"(() => {{ const l = {li}; l.closest('details').open = true; l.querySelector('[data-gl=undo]').click(); l.querySelector('.glf input').value = 'Fogli da ristampare {RUN}'; l.querySelector('[data-gl=ok]').click(); }})()")
    ap.wait_for_timeout(3000)
    r = sql1("select done || '|' || (done_by_id is null) || '|' || coalesce(sign_note, '') || '|' || (note like 'Print the blank MOD sheets%') from fabula.dash_checks where key = 'paper_fallback'")
    check('E-30 «Annulla…» with a reason puts it back to do', r == f'false|true|Fogli da ristampare {RUN}|true' and 'Annullare' in (dlg[-1] if dlg else ''), r)
    ctx.close()

    # ================= the office sees the list without the buttons =================
    ctx, up = page_as(b, UFF, 'admin.html#panoramica', logs)
    up.wait_for_timeout(8000)
    st = up.evaluate("(() => { const c = document.getElementById('golive-card'); return (c && !c.hidden) + '|' + document.querySelectorAll('#golive [data-gl]').length; })()")
    check('E-30 the office (Sistema «vede») sees the list but cannot tick it', st == 'true|0', st)
    ctx.close()

    check('no page errors', not logs, ' / '.join(logs)[:300])
    b.close()
finally:
    srv.terminate()
    sql(f"update fabula.bot_messages set read_at = now() where id in ({A_SALES or 0}, {A_HACCP or 0})")
    sql("update fabula.notices set resolved_at = now() where resolved_at is null and key like 'haccp_evening:%'")
print('FAILURES: ' + (', '.join(fails) if fails else 'none'))
