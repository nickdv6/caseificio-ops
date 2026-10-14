"""v0.96 audit A-01 (who is recording on the shared tablet) in the browser, against the local copy (restore_drill + setup.sql +
PostgREST on :3000, v096a/b applied). The tablet is logged in as Test Casaro all along.
- No operator chosen: the header asks «Chi registra?», and 🛡 HACCP opens «Chi sta registrando?» instead of the menu.
- Name + PIN: a wrong PIN says how many tries are left; the right one sets the operator, clocks in (box ticked) and goes on to the
  menu the person had tapped.
- Badge scan of another person: they become the operator and are clocked in; a cold-room check is then signed by them, while the
  database also keeps the logged-in account (entered_by_id). The same badge again does NOT clock out: a card offers «Fine turno»,
  which closes the shift and clears the operator.
- 15 minutes idle (simulated): the operator lapses and the next record asks again.
- Offline: a PIN already checked on this tablet works; a PIN never used here is refused with a clear message.
- Paper copy: «Chi l'ha scritto» is a list with no default.
- Configurazione → Utenti: the owner sets a PIN with the «PIN» button; it is stored as a hash only.
Expect "FAILURES: none"."""
import json, subprocess, time, os, hmac, hashlib, base64
from playwright.sync_api import sync_playwright
from e2e_op import op_js

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../../../fabula-tablet'))
REF = 'ojkquhzaeypsphncjqwy'; PORT = 8774
def _b64(b): return base64.urlsafe_b64encode(b).rstrip(b'=').decode()
def _jwt(sub, email, secret=b"test-secret-test-secret-test-secret-0123456789"):
    h = _b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    p = _b64(json.dumps({"sub": sub, "role": "authenticated", "email": email, "aud": "authenticated", "exp": int(time.time()) + 86400}).encode())
    return h + '.' + p + '.' + _b64(hmac.new(secret, (h + '.' + p).encode(), hashlib.sha256).digest())
CASARO = ("00000000-0000-4000-a000-000000000001", "casaro@test.it")
OWNER = ("00000000-0000-4000-a000-0000000000b1", "owner@test.it")
CAS_ID = '10000000-0000-4000-a000-000000000001'
def sql(q):
    r = subprocess.run(['su', 'postgres', '-c', f'psql -At -d restore_drill -c "{q}"'], capture_output=True, text=True)
    return r.stdout.strip() or r.stderr.strip()
def sql1(q): return (sql(q).splitlines() or [''])[0]

RUN = time.strftime('%H%M%S')
BADGE = 'STAFF:OPE2E' + RUN
AIUTO = sql1(f"insert into fabula.staff (full_name, role, app_role, active, badge_code) values ('Aiuto E2E {RUN}', 'commesso', 'banco', true, '{BADGE}') returning id")
# since the quick fixes of 13/10 (audit C-24) the database gives every badge a random code: use the one it gave
BADGE = sql1(f"select badge_code from fabula.staff where id = '{AIUTO}'") or BADGE
sql(f"insert into fabula.staff(id, full_name, auth_user_id, app_role, role, active) values ('10000000-0000-4000-a000-0000000000b1', 'Owner E2E', '{OWNER[0]}', 'titolare', 'owner', true) on conflict do nothing")
sql(f"select fabula.staff_set_pin('{CAS_ID}', '4826')")
sql(f"select fabula.staff_set_pin('{AIUTO}', '3917')")
sql(f"update fabula.shifts set clock_out = now() where staff_id in ('{CAS_ID}', '{AIUTO}') and clock_out is null")

srv = subprocess.Popen(['python3', '-m', 'http.server', str(PORT)], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(1)
fails = []
def check(name, cond, info=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f'  [{info}]' if info else ''))
    if not cond: fails.append(name)

def page_as(b, who, path, logs, width=800, operator=False):
    s = {"access_token": _jwt(*who), "refresh_token": "r", "expires_at": int(time.time()) + 86400, "expires_in": 86400, "token_type": "bearer",
         "user": {"id": who[0], "email": who[1], "aud": "authenticated", "role": "authenticated"}}
    def handler(route):
        try: return _handler(route)
        except Exception: pass                        # the page/context closed while a request was in flight
    def _handler(route):
        u = route.request.url
        if '/rest/v1/' in u: return route.fulfill(response=route.fetch(url='http://127.0.0.1:3000/' + u.split('/rest/v1/', 1)[1]))
        if '/auth/v1/' in u: return route.fulfill(status=200, content_type='application/json', body=json.dumps(s['user']), headers={'access-control-allow-origin': '*'})
        return route.fulfill(status=200, body='{}', headers={'access-control-allow-origin': '*'})
    ctx = b.new_context(service_workers='block', viewport={'width': width, 'height': 1300}); ctx.route('**/*.supabase.co/**', handler)
    pg = ctx.new_page(); pg.on('pageerror', lambda e: logs.append('PAGEERROR ' + str(e)))
    pg.goto(f'http://localhost:{PORT}/labels.html')
    pg.evaluate(f"localStorage.clear(); localStorage.setItem('sb-{REF}-auth-token', {json.dumps(json.dumps(s))}){op_js(s) if operator else ''}")
    pg.goto(f'http://localhost:{PORT}/{path}')
    return ctx, pg

try:
  with sync_playwright() as p:
    b = p.chromium.launch(); logs = []
    ctx, pg = page_as(b, CASARO, 'index.html', logs)
    pg.wait_for_function("document.querySelector('#v-home.active')", timeout=20000); pg.wait_for_timeout(2500)
    view = lambda: pg.evaluate("(document.querySelector('.view.active')||{}).id")
    toast = lambda: pg.evaluate("document.getElementById('toast').textContent")
    who = lambda: pg.evaluate("document.getElementById('who').textContent")
    title = lambda: pg.evaluate("document.getElementById('f-title').textContent")
    def code(c): pg.evaluate("c => { document.getElementById('manual').value = c; document.getElementById('btn-manual').click(); }", c); pg.wait_for_timeout(1800)
    def save_form(): pg.evaluate("document.getElementById('btn-form-save').click()"); pg.wait_for_timeout(1800)
    def pick(name): pg.locator('#form .nitem', has_text=name).first.click(); pg.wait_for_timeout(500)

    # 1. nobody chosen
    check('A-01 header asks who is recording', 'Chi registra?' in who() and 'none' in pg.evaluate("document.getElementById('who').className"), who())
    check('A-01 …and shows the logged-in account at the bottom', 'Tablet collegato come Test Casaro' in pg.evaluate("document.getElementById('acct').textContent"))
    pg.click('#btn-haccp'); pg.wait_for_timeout(1200)
    check('A-01 🛡 HACCP asks «Chi sta registrando?» first', view() == 'v-form' and title() == 'Chi sta registrando?', title())
    names = pg.evaluate("[...document.querySelectorAll('#form .nitem')].map(b => b.textContent)")
    check('A-01 the list shows the people, with shift state', any('Test Casaro' in n and 'non in turno' in n for n in names) and any(f'Aiuto E2E {RUN}' in n for n in names), str(names)[:300])

    # 2. name + PIN
    pick('Test Casaro')
    check('A-01 tapping a name asks the PIN, with «inizio anche il turno» ticked', pg.locator('#pin').count() == 1 and pg.evaluate("document.getElementById('pin-shift').checked") is True)
    pg.fill('#pin', '0000'); save_form()
    check('A-01 a wrong PIN says how many tries are left', 'PIN sbagliato' in toast() and 'ancora 4 tentativi' in toast() and view() == 'v-form', toast())
    pg.fill('#pin', '4826'); save_form(); pg.wait_for_timeout(800)
    check('A-01 the right PIN goes on to the menu that was tapped', view() == 'v-form' and title() == 'Sicurezza alimentare', title())
    check('A-01 the header now shows who records', who().startswith('👤 Test Casaro'), who())
    check('A-01 …and the shift was started', sql1(f"select count(*) from fabula.shifts where staff_id = '{CAS_ID}' and clock_out is null") == '1')
    pg.click('#btn-form-cancel'); pg.wait_for_timeout(500)

    # 3. another person's badge: they record from now on; the record keeps both people
    pg.click('#btn-scan'); pg.wait_for_timeout(500); code(BADGE)
    check('A-01 a badge scan makes that person the operator and clocks them in', who().startswith(f'👤 Aiuto E2E {RUN}') and 'inizio turno' in toast(), who() + ' / ' + toast())
    check('A-01 …shift open in the database', sql1(f"select count(*) from fabula.shifts where staff_id = '{AIUTO}' and clock_out is null") == '1')
    pg.click('#btn-scan'); pg.wait_for_timeout(500); code('EQ:CF-01')
    pg.fill('#temp', '3'); save_form()
    row = sql1("select operator || '|' || operator_id || '|' || coalesce(entered_by_id::text, '-') from fabula.haccp_log l join fabula.haccp_control_points c on c.id = l.control_point_id where c.code = 'CCP-COLD-1' order by l.created_at desc limit 1")
    check('A-01 the cold-room check is signed by the badge holder; the logged-in account is kept too', row == f'Aiuto E2E {RUN}|{AIUTO}|{CAS_ID}', row)

    # 4. the same badge again: no clock-out by mistake, a card with «Fine turno»
    pg.click('#btn-scan'); pg.wait_for_timeout(500); code(BADGE)
    check('A-25 scanning the same badge again does not clock out: a card offers «Fine turno»',
          view() == 'v-form' and pg.locator('#form button', has_text='Fine turno').count() == 1
          and sql1(f"select count(*) from fabula.shifts where staff_id = '{AIUTO}' and clock_out is null") == '1')
    pg.locator('#form button', has_text='Fine turno').click(); pg.wait_for_timeout(1500)
    check('A-01 «Fine turno» closes the shift and clears the operator',
          sql1(f"select count(*) from fabula.shifts where staff_id = '{AIUTO}' and clock_out is null") == '0' and 'Chi registra?' in who() and 'fine turno' in toast(), who() + ' / ' + toast())

    # 5. a record now asks again (scan of a machine with nobody chosen)
    pg.click('#btn-scan'); pg.wait_for_timeout(500); code('EQ:CF-01')
    check('A-01 a scan with nobody chosen asks who is recording', title() == 'Chi sta registrando?', title())
    pick('Test Casaro'); pg.fill('#pin', '4826'); save_form(); pg.wait_for_timeout(800)
    check('A-01 …then opens the scanned machine (PIN, already on shift: no shift box)', pg.locator('#temp').count() == 1, title())
    pg.click('#btn-form-cancel'); pg.wait_for_timeout(400)

    # 6. 15 minutes idle (simulated on reload): the operator lapses
    pg.evaluate("(() => { const o = JSON.parse(localStorage.getItem('perla_operator_v1')); o.last = Date.now() - 16 * 60000; localStorage.setItem('perla_operator_v1', JSON.stringify(o)); })()")
    pg.reload(); pg.wait_for_function("document.querySelector('#v-home.active')", timeout=20000); pg.wait_for_timeout(2000)
    check('A-01 after 15 minutes idle nobody is recording', 'Chi registra?' in who(), who())
    pg.click('#btn-count'); pg.wait_for_timeout(1000)
    check('A-01 …and a Home button asks again', title() == 'Chi sta registrando?', title())

    # 7. offline PIN
    ctx.set_offline(True); pg.wait_for_timeout(300)
    pick(f'Aiuto E2E {RUN}'); pg.fill('#pin', '3917'); save_form()
    check('A-01 offline: a PIN never checked on this tablet is refused, with what to do', 'Senza rete' in toast() and 'badge' in toast(), toast())
    pg.click('#btn-form-cancel'); pg.wait_for_timeout(300); pg.click('#btn-count'); pg.wait_for_timeout(800)
    pick('Test Casaro'); pg.fill('#pin', '1357'); save_form()
    check('A-01 offline: a wrong PIN is refused', toast().startswith('PIN sbagliato'), toast())
    pg.fill('#pin', '4826'); save_form(); pg.wait_for_timeout(800)
    check('A-01 offline: a PIN already used here works', who().startswith('👤 Test Casaro'), who() + ' / ' + toast())
    ctx.set_offline(False); pg.wait_for_timeout(500)
    pg.evaluate("document.querySelectorAll('.view').forEach(e => e.classList.toggle('active', e.id === 'v-home'))")

    # 8. paper copy: the signer is chosen from the list, no default
    pg.click('#btn-scan'); pg.wait_for_timeout(400); code('PAPER:CCP-COLD-1')
    opts = pg.evaluate("[...document.querySelectorAll('#pwho option')].map(o => o.value)")
    check('A-19 «Chi l\'ha scritto» is a list, nothing chosen', pg.evaluate("document.getElementById('pwho').tagName") == 'SELECT' and opts[0] == '' and 'Test Casaro' in opts
          and pg.evaluate("document.getElementById('pwho').value") == '', str(opts)[:200])
    pg.click('#btn-form-cancel'); pg.wait_for_timeout(300)

    # 8b. the evening notice «badge di uscita non passato» closes that person's shift; it does not make them the one recording
    sql(f"select fabula.badge_in('{BADGE}')")
    sql(f"insert into fabula.notices (key, severity, title_it, items, expires_at) values ('haccp_evening_e2e_{RUN}', 'warn', 'Badge di uscita non passati', "
        f"jsonb_build_array(jsonb_build_object('label_it', 'Aiuto E2E {RUN}: badge di uscita non passato', 'scan', '{BADGE}')), now() + interval '1 hour')")
    pg.reload(); pg.wait_for_function("document.querySelector('#v-home.active')", timeout=20000); pg.wait_for_timeout(2500)
    who_before = who()
    pg.locator('#notice-wrap .nitem', has_text=f'Aiuto E2E {RUN}: badge di uscita').click(); pg.wait_for_timeout(1200)
    check('A-01 the evening «badge di uscita» item opens a «Fine turno» card for that person', title() == 'Fine turno' and pg.locator('#form button', has_text=f'Chiudi il turno di Aiuto E2E {RUN}').count() == 1, title())
    pg.locator('#form button', has_text='Chiudi il turno').click(); pg.wait_for_timeout(1500)
    check('A-01 …which closes the shift and leaves who is recording as it was', sql1(f"select count(*) from fabula.shifts where staff_id = '{AIUTO}' and clock_out is null") == '0'
          and who() == who_before and f'Aiuto E2E {RUN}' not in who(), who_before + ' → ' + who())
    sql(f"delete from fabula.notices where key = 'haccp_evening_e2e_{RUN}'")
    pg.wait_for_timeout(1500); ctx.close()

    # 8c. a form left open 15 minutes: whoever touches it says who they are first (fake clock)
    ctx, pg = page_as(b, CASARO, 'index.html', logs, operator=True)
    pg.clock.install()
    pg.reload(); pg.wait_for_function("document.querySelector('#v-home.active')", timeout=20000); pg.wait_for_timeout(2000)
    pg.click('#btn-scan'); pg.wait_for_timeout(400)
    pg.evaluate("c => { document.getElementById('manual').value = c; document.getElementById('btn-manual').click(); }", 'EQ:CF-01'); pg.wait_for_timeout(1500)
    pg.clock.fast_forward(16 * 60 * 1000); pg.wait_for_timeout(300)
    pg.locator('#temp').click(); pg.wait_for_timeout(400)
    check('A-01 a form left open 15 min: the first touch asks «Chi sta registrando?»', pg.locator('#op-still').count() == 1 and 'Test Casaro' in pg.inner_text('#op-still'))
    pg.click('#op-still-no'); pg.wait_for_timeout(600)
    check('A-01 …«Non sono io» drops the form and the operator', pg.evaluate("(document.querySelector('.view.active')||{}).id") == 'v-home' and 'Chi registra?' in pg.evaluate("document.getElementById('who').textContent"))
    ctx.close()

    # 9. Configurazione → Utenti: the owner sets a PIN
    ctx, ap = page_as(b, OWNER, 'admin.html', logs, 1300)
    ap.wait_for_timeout(2500); ap.click('.tab[data-tab="utenti"]'); ap.wait_for_timeout(2000)
    rowl = ap.locator('#users tr', has_text=f'Aiuto E2E {RUN}')
    check('A-01 Utenti shows «PIN ✓» for someone with a PIN', rowl.locator('button', has_text='PIN ✓').count() == 1)
    before = sql1(f"select pin_hash from fabula.staff_pins where staff_id = '{AIUTO}'")
    rowl.locator('button', has_text='PIN ✓').click(); ap.wait_for_timeout(300)
    rowl.locator('input[type=password]').fill('1234'); rowl.locator('button', has_text='Salva PIN').click(); ap.wait_for_timeout(1200)
    check('A-01 an easy PIN is refused', 'troppo facile' in ap.evaluate("document.getElementById('toast') ? document.getElementById('toast').textContent : document.body.innerText"))
    rowl.locator('input[type=password]').fill('6081'); rowl.locator('button', has_text='Salva PIN').click(); ap.wait_for_timeout(1500)
    after = sql1(f"select pin_hash from fabula.staff_pins where staff_id = '{AIUTO}'")
    check('A-01 the owner changes the PIN (stored as a hash)', after != before and after.startswith('$2') and '6081' not in after,
          sql1(f"select (fabula.operator_pin_check('{AIUTO}', '6081'))->>'ok'"))

    # 10. E-01 · Configurazione → Utenti → Avvisi su Telegram
    sql("update fabula.notify_targets set chat_id = null where staff_id = '10000000-0000-4000-a000-0000000000b1'")
    ap.reload(); ap.wait_for_timeout(2500); ap.click('.tab[data-tab="utenti"]'); ap.wait_for_timeout(2000)
    tgc = ap.locator('#telegram')
    check('E-01 the Telegram card offers «Collega il mio Telegram»', tgc.locator('#nt-link').count() == 1)
    tgc.locator('#nt-link').click(); ap.wait_for_timeout(1200)
    url = ap.evaluate("(document.querySelector('#nt-linkout input') || {}).value || ''")
    check('E-01 …which shows a one-time t.me link and a QR to scan', url.startswith('https://t.me/bubalina_avvisi_bot?start=') and ap.locator('#nt-linkout .nt-qr canvas, #nt-linkout .nt-qr img').count() >= 1, url)
    prow = ap.locator('#notify-all table').first.locator('tr', has_text='Test Casaro')
    check('E-01 the owner sees who is linked', prow.count() == 1 and 'collegato' in prow.inner_text(), prow.inner_text() if prow.count() else '')
    prow.locator('[data-ntlink]').click(); ap.wait_for_timeout(1000)
    check('E-01 …and can make a link to send to someone else', 'Test Casaro' in ap.evaluate("document.getElementById('nt-otherlink').textContent")
          and ap.evaluate("(document.querySelector('#nt-otherlink input') || {}).value || ''").startswith('https://t.me/'))
    sql(f"select fabula.notify_link('{url.split('start=')[1]}', 5555, 'Owner')")
    ap.reload(); ap.wait_for_timeout(2500); ap.click('.tab[data-tab="utenti"]'); ap.wait_for_timeout(2000); tgc = ap.locator('#telegram')
    check('E-01 once linked: topics, quiet hours, time zone', 'Collegato' in tgc.inner_text() and tgc.locator('[data-topic]').count() == 3)
    tgc.locator('[data-topic="decisions"]').uncheck(); ap.select_option('#nt-tz', 'America/New_York'); tgc.locator('#nt-save').click(); ap.wait_for_timeout(1200)
    check('E-01 …saved', sql1("select array_to_string(topics, ',') || '|' || tz from fabula.notify_targets where staff_id = '10000000-0000-4000-a000-0000000000b1'") == 'food_safety,infra|America/New_York')
    check('E-01 the last alerts list who took them', ap.locator('#notify-all', has_text='Ultimi allarmi').count() == 1)
    sql("update fabula.notify_targets set chat_id = null where chat_id = 5555")
    ctx.close()

    errs = [l for l in logs if 'PAGEERROR' in l]
    check('no page errors', not errs, '; '.join(errs)[:400])
finally:
    srv.terminate()
    sql(f"update fabula.shifts set clock_out = now() where staff_id in ('{CAS_ID}', '{AIUTO}') and clock_out is null")
    sql(f"update fabula.staff set active = false where id = '{AIUTO}'")
print('FAILURES:', ', '.join(fails) if fails else 'none')
