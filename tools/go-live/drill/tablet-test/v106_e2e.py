"""v1.06 «Perché?» in the browser, against the local copy (restore_drill + setup.sql + PostgREST on :3000, v106a–b applied). Port 8786.
- Configurazione → Bot as the titolare: «Perché?» only under the messages that have their data; the milk plan opens «Perché 900 kg di
  latte…» with its steps, the number check naming the invented number and «Dati grezzi»; a second tap hides it; on a phone the panel
  never scrolls sideways.
- Console → Oggi «Avvisi aperti» as the cheesemaker (production / HACCP): the food-safety alarm has «Perché?» («Perché il lotto … è
  bloccato», the CCP values), without the raw data and without the number check.
- The link in Telegram (console.html#oggi&perche=<id>) opens the same panel as a sheet; Esc closes it and the address goes back to #oggi.
- A marketing profile following the food-safety link gets «Il tuo profilo non vede questo messaggio».
Expect "FAILURES: none"."""
import json, subprocess, time, os, hmac, hashlib, base64
from playwright.sync_api import sync_playwright

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../../../fabula-tablet'))
REF = 'ojkquhzaeypsphncjqwy'; PORT = 8786
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
OWNER = ("00000000-0000-4000-a000-0000000106e1", "v106-owner@test.it")
MKT = ("00000000-0000-4000-a000-0000000106e2", "v106-mkt@test.it")
for (uid, em), (sid, name, role, job) in [(OWNER, ('10000000-0000-4000-a000-0000000106e1', 'Titolare V106', 'titolare', 'owner')),
                                          (MKT, ('10000000-0000-4000-a000-0000000106e2', 'Marketing V106', 'marketing', 'operaio'))]:
    sql(f"insert into auth.users(id, email) values ('{uid}', '{em}') on conflict do nothing")
    sql(f"insert into fabula.staff(id, full_name, auth_user_id, app_role, role, active) values ('{sid}', '{name}', '{uid}', '{role}', '{job}', true) on conflict do nothing")
MOZ = sql1("select id from fabula.products where sku = 'MOZ-DOP-KG'")
LOT = 'LW6' + RUN
sql("update fabula.bot_messages set read_at = now() where read_at is null")
# 1. a milk plan message from the bot, with its read (one number invented: 950)
PLAN = ('{\\"date\\":\\"2026-10-16\\",\\"weekday\\":\\"venerdì\\",\\"demand\\":{\\"retail_kg\\":112,\\"wholesale_kg\\":40,\\"wholesale_confirmed_kg\\":40,\\"history_source\\":\\"same_weekday_4w\\",\\"history_days\\":4},'
        '\\"carry_kg\\":18,\\"carry_raw_kg\\":36,\\"carry_pct\\":50,\\"safety_kg\\":15,\\"planned_output_kg\\":149,\\"yield_pct\\":20.5,\\"yield_source\\":\\"avg_30d\\",\\"milk_kg\\":900,\\"milk_unrounded_kg\\":727,'
        '\\"capacity_kg\\":1200,\\"min_kg\\":900,\\"min_run_applied\\":true,\\"farm\\":{\\"kg_available\\":1100},\\"price_eur_per_kg\\":1.6,\\"est_cost_eur\\":1440}')
sql(f"select fabula.keep_basis('milk_planning', 'plan_milk', '{PLAN}'::jsonb)")
M_PLAN = sql1(f"select fabula.post_bot_message('milk_planning', 'warn', 'Approva il latte di ven 16/10: 900 kg · prova R{RUN}', 'Domanda 950 kg · resa 20,5 %')")
# 2. a message without data (a bot on the old prompt)
M_OLD = sql1(f"select fabula.post_bot_message('procurement', 'info', 'Nessun ordine {RUN}', 'Nessun materiale da ordinare')")
# 3. a food-safety alarm from the database: a lot closed without CCP 3
sql(f"insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, source) values (current_date, '{LOT}', '{MOZ}', 500, 'milk', now(), 'tablet')")
sql(f"select fabula.log_ccp(p_cp_code => 'CCP-PAST', p_value => 72.5, p_staff_id => (select id from fabula.staff where auth_user_id = '{CASARO[0]}'), p_batch_lot => '{LOT}')")
sql(f"update fabula.production_batches set output_kg = 150, finished_at = now() where batch_lot = '{LOT}'")
M_CCP = sql1(f"select id from fabula.bot_messages where agent = 'sicurezza' and title like 'Lotto {LOT} chiuso senza%' order by id desc limit 1")

srv = subprocess.Popen(['python3', '-m', 'http.server', str(PORT)], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1)
fails = []
def check(name, cond, info=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f'  [{info}]' if info else ''))
    if not cond: fails.append(name)
def page_as(b, who, path, logs, width=1100):
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
    pg.goto(f'http://localhost:{PORT}/labels.html')
    pg.evaluate(f"localStorage.clear(); localStorage.setItem('sb-{REF}-auth-token', {json.dumps(json.dumps(s))})")
    pg.goto(f'http://localhost:{PORT}/{path}')
    return ctx, pg
sideways = lambda pg: pg.evaluate("document.documentElement.scrollWidth - window.innerWidth")

try:
  with sync_playwright() as p:
    b = p.chromium.launch(); logs = []
    # ================= Configurazione → Bot as the titolare =================
    for width in (1100, 390):
        ctx, ap = page_as(b, OWNER, 'admin.html#bots', logs, width)
        ap.wait_for_timeout(7000)
        msg = lambda mid: f"[...document.querySelectorAll('#bd-feed .msg')].find(m => m.querySelector('[data-x=why][data-id=\"{mid}\"]'))"
        has = ap.evaluate(f"[!!({msg(M_PLAN)}), !!({msg(M_CCP)}), !![...document.querySelectorAll('#bd-feed .msg')].find(m => m.textContent.includes('Nessun ordine {RUN}') && m.querySelector('[data-x=why]')), !![...document.querySelectorAll('#bd-feed .msg')].find(m => m.textContent.includes('Nessun ordine {RUN}'))]")
        if width == 1100:
            check('feed: «Perché?» under the milk plan and the food-safety alarm, not under the message without data', has == [True, True, False, True], str(has))
        ap.evaluate(f"{msg(M_PLAN)}.querySelector('[data-x=why]').click()"); ap.wait_for_timeout(2500)
        w = ap.evaluate(f"(() => {{ const m = {msg(M_PLAN)}; const p = m.querySelector('.whyp'); return [p.hidden, p.innerText, m.querySelector('[data-x=why]').textContent, !!p.querySelector('.why-raw')]; }})()")
        if width == 1100:
            check('the milk plan opens «Perché 900 kg di latte per ven 16/10» with its steps and the cost', not w[0] and 'Perché 900 kg di latte per ven 16/10' in w[1]
                  and 'Vendite al banco e online' in w[1] and 'Lotto minimo' in w[1] and '900 kg × € 1,60/kg = € 1.440' in w[1] and w[2] == 'Nascondi il perché', w[1].replace('\n', ' | ')[:400])
            check('…the number check names the invented number, for the titolare only, and «Dati grezzi» is there', '⚠ Nel messaggio c\'è un numero che non si trova nei dati letti: 950' in w[1]
                  and 'lo vede solo chi gestisce il sistema' in w[1] and w[3], w[1][:200].replace('\n', ' | '))
            ap.evaluate(f"{msg(M_PLAN)}.querySelector('[data-x=why]').click()"); ap.wait_for_timeout(400)
            hid = ap.evaluate(f"[{msg(M_PLAN)}.querySelector('.whyp').hidden, {msg(M_PLAN)}.querySelector('[data-x=why]').textContent]")
            check('a second tap hides it', hid == [True, 'Perché?'], str(hid))
        else:
            ap.evaluate(f"{msg(M_PLAN)}.querySelector('.whyp').scrollIntoView()"); ap.wait_for_timeout(300)
            check('on a phone (390 px) the open panel never scrolls the page sideways', not w[0] and sideways(ap) <= 1, f'{sideways(ap)} px')
            ap.screenshot(path='/tmp/v106_phone_feed.png', full_page=False)
        ctx.close()

    # ================= Console → Oggi «Avvisi aperti» as the cheesemaker =================
    ctx, cp = page_as(b, CASARO, 'console.html#oggi', logs, 800)
    cp.wait_for_timeout(7000)
    av = f"document.querySelector('#avvisi .av[data-id=\"{M_CCP}\"]')"
    ok = cp.evaluate(f"!!({av} && {av}.querySelector('[data-x=why]'))")
    check('«Avvisi aperti»: the food-safety alarm has «Perché?»', ok)
    if ok:
        cp.evaluate(f"{av}.querySelector('[data-x=why]').click()"); cp.wait_for_timeout(2500)
        t = cp.evaluate(f"{av}.querySelector('.whyp').innerText")
        check('…«Perché il lotto … è bloccato» with the CCP 2 value and CCP 3 missing, no raw data, no number check', f'Perché il lotto {LOT} è bloccato' in t and '72,5 °C' in t and 'mancante' in t
              and 'Dati grezzi' not in t and 'Numeri controllati' not in t and 'Nel messaggio' not in t, t.replace('\n', ' | ')[:400])
    ctx.close()

    # ================= the Telegram link: a sheet over the Console =================
    ctx, cp = page_as(b, CASARO, f'console.html#oggi&perche={M_CCP}', logs, 390)
    cp.wait_for_timeout(7000)
    sh = cp.evaluate("(() => { const s = document.getElementById('why-sheet'); return s && !s.hidden ? s.innerText : ''; })()")
    check('console.html#oggi&perche=<id> opens the panel as a sheet, with the message\'s title and who wrote it', f'Lotto {LOT} chiuso senza' in sh and 'Sicurezza alimentare' in sh
          and f'Perché il lotto {LOT} è bloccato' in sh, sh.replace('\n', ' | ')[:300])
    check('…on a phone without sideways scrolling', sideways(cp) <= 1, f'{sideways(cp)} px')
    cp.screenshot(path='/tmp/v106_phone_sheet.png', full_page=False)
    cp.keyboard.press('Escape'); cp.wait_for_timeout(400)
    st = cp.evaluate("[document.getElementById('why-sheet').hidden, location.hash]")
    check('Esc closes it and the address goes back to #oggi', st == [True, '#oggi'], str(st))
    ctx.close()
    ctx, mp = page_as(b, MKT, f'console.html#oggi&perche={M_CCP}', logs, 800)
    mp.wait_for_timeout(7000)
    sh = mp.evaluate("(() => { const s = document.getElementById('why-sheet'); return s && !s.hidden ? s.innerText : ''; })()")
    check('a marketing profile following the food-safety link: «Il tuo profilo non vede questo messaggio»', 'Non disponibile' in sh and 'Il tuo profilo non vede questo messaggio' in sh, sh.replace('\n', ' | ')[:200])
    ctx.close()

    check('no page errors', not logs, ' / '.join(logs)[:300])
    b.close()
finally:
    srv.terminate()
    sql(f"update fabula.bot_messages set read_at = now() where id in ({M_PLAN or 0}, {M_OLD or 0}, {M_CCP or 0})")
print('FAILURES: ' + (', '.join(fails) if fails else 'none'))
