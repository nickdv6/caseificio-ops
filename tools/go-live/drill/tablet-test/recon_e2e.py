"""v0.82 Console → Incassi in headless Chromium against a local copy (fresh replay + v0.82a, setup.sql, PostgREST on :3000):
the owner uploads the Shopify payments CSV (Italian admin) and a bank CSV with a preamble, the payout is matched to the
bank credit, an unknown credit is classified by hand (note required), a missing payment is marked as checked, and a
production login does not see the tab. Run with DB=<name> (default restore_drill)."""
import json, subprocess, time, os, hmac, hashlib, base64, tempfile
from playwright.sync_api import sync_playwright

DB = os.environ.get('DB', 'restore_drill')
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../../../fabula-tablet'))
REF = 'ojkquhzaeypsphncjqwy'
def _b64(b): return base64.urlsafe_b64encode(b).rstrip(b'=').decode()
def _jwt(sub, email, secret=b"test-secret-test-secret-test-secret-0123456789"):
    h = _b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    p = _b64(json.dumps({"sub": sub, "role": "authenticated", "email": email, "aud": "authenticated", "exp": int(time.time()) + 86400}).encode())
    return h + '.' + p + '.' + _b64(hmac.new(secret, (h + '.' + p).encode(), hashlib.sha256).digest())
def sql(q):
    r = subprocess.run(['su', 'postgres', '-c', f'psql -At -d {DB} -c "{q}"'], capture_output=True, text=True)
    return r.stdout.strip() or r.stderr.strip()
OWNER = ("00000000-0000-4000-a000-0000000000b1", "owner@test.it")
CASARO = ("00000000-0000-4000-a000-000000000001", "casaro@test.it")
sql(f"insert into auth.users(id, email) values ('{OWNER[0]}', '{OWNER[1]}') on conflict do nothing")
sql(f"insert into fabula.staff(id, full_name, auth_user_id, app_role, role, active) values ('10000000-0000-4000-a000-0000000000b1', 'Owner E2E', '{OWNER[0]}', 'titolare', 'owner', true) on conflict do nothing")
D = lambda n: sql(f"select to_char((now() at time zone 'Europe/Rome')::date - 30 + {n}, 'DD/MM/YYYY')")
ISO = lambda n: sql(f"select (now() at time zone 'Europe/Rome')::date - 30 + {n}")
sql("insert into fabula.sales_orders (order_number, channel, order_date, status, subtotal_eur, iva_eur, total_eur, payment_method, shopify_order_id, source, shopify_payload) values "
    f"('#2001', 'shopify', '{ISO(1)}', 'fulfilled', 28.85, 1.15, 30.00, 'shopify', 'gid://shopify/Order/7001', 'shopify', '{{\\\"payment_gateways\\\":[\\\"shopify_payments\\\"]}}'),"
    f"('#2002', 'store_pos', '{ISO(2)}', 'fulfilled', 19.23, 0.77, 20.00, 'shopify_pos', 'gid://shopify/Order/7002', 'shopify', '{{\\\"payment_gateways\\\":[\\\"shopify_payments\\\"]}}'),"
    f"('#2003', 'shopify', '{ISO(2)}', 'confirmed', 38.46, 1.54, 40.00, 'shopify', 'gid://shopify/Order/7003', 'shopify', '{{\\\"payment_gateways\\\":[\\\"shopify_payments\\\"]}}')")

SHOP = f"""Data della transazione;Tipo;Ordine;Stato del pagamento;Data del pagamento;ID pagamento;Importo;Commissione;Netto;Valuta
{D(1)} 10:12;Addebito;#2001;Pagato;{D(4)};E2E-P1;30,00;0,75;29,25;EUR
{D(2)} 18:40;Addebito;#2002;Pagato;{D(4)};E2E-P1;20,00;0,55;19,45;EUR
"""
BANK = f"""Elenco movimenti
Intestatario: AZIENDA AGRICOLA MASSERIA CILENTANA

Data contabile;Data valuta;Descrizione;Accrediti;Addebiti
{D(5)};{D(5)};BONIFICO A VOSTRO FAVORE SHOPIFY INTERNATIONAL LTD;48,70;
{D(6)};{D(6)};BONIFICO DA SCONOSCIUTO SPA;77,77;
{D(6)};{D(6)};COMMISSIONI BONIFICO;;1,50
{D(20)};{D(20)};SDD ENEL ENERGIA;;123,40
Saldo finale;;;;
"""
tmp = tempfile.mkdtemp(); fs, fb = os.path.join(tmp, 'pagamenti.csv'), os.path.join(tmp, 'movimenti.csv')
open(fs, 'w', encoding='utf-8').write(SHOP); open(fb, 'w', encoding='cp1252').write(BANK)   # bank file in Windows encoding, like many Italian banks

srv = subprocess.Popen(['python3', '-m', 'http.server', '8771'], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1)
def session(who):
    jwt = _jwt(*who)
    return {"access_token": jwt, "refresh_token": "r", "expires_at": int(time.time()) + 86400, "expires_in": 86400, "token_type": "bearer",
            "user": {"id": who[0], "email": who[1], "aud": "authenticated", "role": "authenticated"}}
fails = []
def check(name, cond, info=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f'  [{info}]' if info else ''))
    if not cond: fails.append(name)
def open_console(p, who, hash_='incassi'):
    s = session(who)
    def handler(route):
        url = route.request.url
        if '/rest/v1/' in url: return route.fulfill(response=route.fetch(url='http://127.0.0.1:3000/' + url.split('/rest/v1/', 1)[1]))
        if '/auth/v1/' in url: return route.fulfill(status=200, content_type='application/json', body=json.dumps(s['user']), headers={'access-control-allow-origin': '*'})
        return route.fulfill(status=200, body='{}', headers={'access-control-allow-origin': '*'})
    ctx = p.chromium.launch().new_context(service_workers='block', viewport={'width': 1280, 'height': 1400})
    ctx.route('**/*.supabase.co/**', handler)
    pg = ctx.new_page(); logs = []
    pg.on('pageerror', lambda e: logs.append('PAGEERROR ' + str(e)))
    pg.goto('http://localhost:8771/labels.html')
    pg.evaluate(f"localStorage.clear(); localStorage.setItem('sb-{REF}-auth-token', {json.dumps(json.dumps(s))})")
    pg.goto(f'http://localhost:8771/console.html#{hash_}')
    pg.wait_for_function("document.querySelector('#v-main.active')", timeout=20000)
    return pg, logs
toast = lambda pg: pg.evaluate("document.getElementById('toast').textContent")
try:
  with sync_playwright() as p:
    pg, logs = open_console(p, OWNER)
    pg.wait_for_function("document.querySelector('#rc-tiles .tile')", timeout=15000)
    check('Incassi tab open for the owner, numbers shown', pg.evaluate("document.querySelectorAll('#rc-tiles .tile').length") == 7)
    check('warns that no Shopify payments file was imported yet', 'Nessun file pagamenti' in pg.inner_text('#rc-warn'))
    # Shopify payments file, chosen while "Estratto conto" is selected: the page switches by itself
    pg.set_input_files('#rc-file', fs); pg.wait_for_selector('#rc-go', timeout=5000)
    check('payments file recognised and the kind switched', pg.evaluate("document.getElementById('rc-kind').value") == 'payments' and '2 righe' in pg.inner_text('#rc-preview'), pg.inner_text('#rc-preview')[:200])
    pg.click('#rc-go'); pg.wait_for_function("!document.getElementById('rc-go')", timeout=10000); pg.wait_for_timeout(800)
    check('payments imported (2 rows, 1 payout of 48,70)', sql("select count(*) from fabula.payment_transactions") == '2' and sql("select net_eur from fabula.payment_payouts where id = 'E2E-P1'") == '48.70', toast(pg))
    # bank file
    pg.select_option('#rc-kind', 'bank'); pg.fill('#rc-acc', 'BCC Test 1234')
    pg.set_input_files('#rc-file', fb); pg.wait_for_selector('#rc-go', timeout=5000)
    prev = pg.inner_text('#rc-preview')
    check('bank file: 4 rows, footer skipped, Windows encoding read', '4 righe' in prev and 'righe non lette' not in prev and 'SCONOSCIUTO' in prev, prev[:300])
    pg.click('#rc-go'); pg.wait_for_function("!document.getElementById('rc-go')", timeout=10000); pg.wait_for_timeout(1000)
    check('bank rows in with the account name', sql("select count(*) from fabula.bank_transactions where bank_account = 'BCC Test 1234'") == '4', toast(pg))
    check('payout matched to the Shopify credit automatically', sql("select match_kind || '|' || matched_payout_id from fabula.bank_transactions where amount_eur = 48.70") == 'payout|E2E-P1')
    check('bank fee classified by the rule', sql("select match_kind from fabula.bank_transactions where amount_eur = -1.50") == 'bank_fee')
    check('payout shows as in the bank', '✓' in pg.inner_text('#rc-payouts'), pg.inner_text('#rc-payouts')[:200])
    exc = pg.inner_text('#rc-exc')
    check('list shows the unknown credit, the debit to classify and the order with no payment', 'SCONOSCIUTO' in exc and 'ENEL' in exc and '#2003' in exc, exc[:400])
    # classify the unknown credit by hand: a note is required for "Altro"
    row = pg.locator('#rc-exc tr', has_text='SCONOSCIUTO'); row.locator('button[data-act=match]').click()
    pg.wait_for_selector('.rc-panel select.rc-pick', timeout=5000)
    pg.select_option('.rc-panel select.rc-pick', 'other|'); pg.click('.rc-panel [data-go]'); pg.wait_for_timeout(600)
    check('"Altro" without a note is refused', 'nota' in toast(pg).lower() and sql("select match_kind from fabula.bank_transactions where amount_eur = 77.77") == '', toast(pg))
    pg.fill('.rc-panel .rc-note', 'Rimborso deposito cauzionale'); pg.click('.rc-panel [data-go]'); pg.wait_for_timeout(1200)
    check('classified as Altro with the note', sql("select match_kind || '|' || match_note from fabula.bank_transactions where amount_eur = 77.77") == 'other|Rimborso deposito cauzionale')
    # mark the order with no payment as checked
    row = pg.locator('#rc-exc tr', has_text='#2003'); row.locator('button[data-act=ack]').click()
    pg.fill('.rc-panel .rc-note', 'Pagato in contanti al ritiro'); pg.click('.rc-panel [data-go]'); pg.wait_for_timeout(1200)
    check('order marked as checked and gone from the list', sql("select note from fabula.recon_acks where key like 'order_no_payment:%'") == 'Pagato in contanti al ritiro' and '#2003' not in pg.inner_text('#rc-exc'))
    pg.click('#rc-bank-filter [data-f=all]'); pg.wait_for_timeout(800)
    check('bank list "Tutti" shows all 4 with what they matched', pg.evaluate("document.querySelectorAll('#rc-bank tr').length") == 5 and 'Versamento Shopify' in pg.inner_text('#rc-bank'))
    check('console notice raised', sql("select count(*) from fabula.notices where key = 'recon' and resolved_at is null") == '1')
    pg.screenshot(path='/tmp/recon_console.png', full_page=True)
    check('no page errors (owner)', not logs, ' | '.join(logs)[:300])
    # production login: no tab
    pg2, logs2 = open_console(p, CASARO, 'oggi')
    pg2.wait_for_timeout(1500)
    check('production login does not see Incassi', pg2.evaluate("document.querySelector('.tab[data-tab=incassi]').hidden") is True)
    check('no page errors (production)', not logs2, ' | '.join(logs2)[:300])
finally:
    srv.terminate()
print('FAILURES:', ', '.join(fails) if fails else 'none')
