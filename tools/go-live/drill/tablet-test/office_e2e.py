"""v0.99 audit office decisions and undo in the browser, against the local copy (restore_drill + setup.sql + PostgREST on :3000, v099a–b applied).
The browser runs in Italian (locale it-IT). Port 8779.
- B-12/E-12  Console → Oggi: most urgent first; a request past its deadline is greyed with no «Approva»; milk, DOP and recall ask once.
- B-09   the milk card shows the farm warning; «Approva con 400 kg»; «Annulla» in «Decise di recente» puts it back; after «Rifiuta»,
         «Ordina 450 kg» orders it again in one go.
- B-11   DOP: «Approva i dati» needs the checks ticked; then «Segna inviata» with the protocol.
- B-13/B-18  the post card links to the post and shows its picture; a catalogue order above the limit is one card with its lines.
- B-18   Operazioni: «Annulla ordine» on an order to send and on a sent one (with the message for the supplier); the catalogue asks
         «prezzo da confermare» for a line without a price and shows every line before creating.
- B-19   Anagrafiche → Clienti: the old «Ordini fissi» grid is gone, with the way to Ingrosso.
- B-15/B-16  Ricette: «Togli» asks and ends the component from tomorrow, «Rimetti» undoes it; a preset target «94,5» is saved as 94.5;
         «Togli» on a step asks.
- B-06   Autocontrollo: no release while the recall decision is open; the release dialog names the conforming analysis; a closed NC
         is reopened from «NC chiuse».
- B-21/B-24/B-22/B-23  Ingrosso: the exception form wants a quantity or «Togli il prodotto», and asks with a summary; «Sospendi»
         and «Nuovo link» ask (the new link is shown); a tier switched off is saved with «Salva» and marked «da inviare»;
         «Invia a Shopify…» shows the changes first (function mocked).
- A-02   tablet: a started lot shows «Stampa etichetta lotto in lavorazione» (LOT:L…).
- B-13   marketing.html#post=<id> opens that post.
Expect "FAILURES: none"."""
import json, subprocess, time, os, hmac, hashlib, base64
from playwright.sync_api import sync_playwright
from e2e_op import op_js

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../../../fabula-tablet'))
REF = 'ojkquhzaeypsphncjqwy'; PORT = 8779
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
def sql_as(uid, q):   # q runs with auth.uid() = uid (the login), like a call from the browser
    return sql1(f"select ({q}) from (select set_config('request.jwt.claim.sub', '{uid}', true)) _s")

RUN = time.strftime('%H%M%S')
CASARO = ("00000000-0000-4000-a000-000000000001", "casaro@test.it")
OWNER = ("00000000-0000-4000-a000-0000000000c1", "office@test.it")
sql(f"insert into auth.users(id, email) values ('{OWNER[0]}', '{OWNER[1]}') on conflict do nothing")
sql(f"insert into fabula.staff(id, full_name, auth_user_id, app_role, role, active) values ('10000000-0000-4000-a000-0000000000c1', 'Owner Office', '{OWNER[0]}', 'titolare', 'owner', true) on conflict do nothing")
TODAY = sql1("select (now() at time zone 'Europe/Rome')::date")
WD = lambda n: sql1(f"select g::date from generate_series((now() at time zone 'Europe/Rome')::date + 1, (now() at time zone 'Europe/Rome')::date + 30, interval '1 day') g where extract(isodow from g) <> 7 order by g offset {n - 1} limit 1")
D1, D2 = WD(1), WD(2)
moz = sql1("select id from fabula.products where sku = 'MOZ-DOP-KG'")
rennet = sql1("select id from fabula.products where sku = 'CON-RENNET'")
salt = sql1("select id from fabula.products where sku = 'CON-SALT'")
# ---- the requests waiting in Oggi ----
sql("update fabula.approvals set status = 'expired' where status = 'pending'")
sql(f"delete from fabula.milk_plans where plan_date >= '{TODAY}'")
sql("update fabula.settings set value = '1' where key = 'milk.cap_to_farm'")
sql(f"insert into fabula.farm_supply (supply_date, kg_available) values ('{D1}', 500) on conflict (supply_date) do update set kg_available = 500")
# a confirmed wholesale order for D1 bigger than the farm can give: the plan hits the farm's 500 kg whatever stock the other suites left
SO = sql1(f"insert into fabula.sales_orders (order_number, channel, status, order_date) values ('WS-OFF{RUN}', 'wholesale', 'confirmed', '{D1}') returning id")
sql(f"insert into fabula.sales_order_lines (sales_order_id, product_id, qty, unit_price_eur, iva_rate) values ('{SO}', '{moz}', 700, 11, 4)")
A1 = sql1(f"select fabula.plan_milk('{D1}') ->> 'approval_id'")
A2 = sql1(f"select fabula.plan_milk('{D2}') ->> 'approval_id'")
sql(f"update fabula.approvals set auto_approve_at = null, auto_rule = null where id in ('{A1}', '{A2}')")
sql(f"update fabula.approvals set expires_at = now() - interval '5 minutes' where id = '{A2}'")
AP = sql1("insert into fabula.approvals (kind, requested_by, summary, payload, related_table, amount_eur, expires_at) values ('price_change', 'agent:sell_down', 'Promo office', "
          "jsonb_build_object('type', 'sell_down', 'sku', 'MOZ-DOP-KG', 'lot', 'L-OFF', 'at_risk_kg', 30, 'on_hand_kg', 40, 'expiry', current_date + 1, 'promo_pct', 30, 'list_price_eur_kg', 16.8, 'promo_price_eur_kg', 11.76, 'action', 'promo_banco'), "
          "'stock_moves', 50, now() + interval '20 hours') returning id")
sql(f"update fabula.approvals set auto_approve_at = null where id = '{AP}'")
ASSET = sql1("insert into fabula.mkt_assets (kind, url, source) values ('photo', 'http://localhost:8779/icon.svg', 'caseificio') returning id")
MC = sql1(f"insert into fabula.mkt_content (platform, format, pillar, status, scheduled_at, brief_it, caption_it, asset_ids) values ('instagram', 'post', 'origine', 'review', now() + interval '3 days', 'office', 'Post office {RUN}', array['{ASSET}']::uuid[]) returning id")
DOP = sql1("insert into fabula.approvals (kind, requested_by, summary, payload, related_table) values ('dop_declaration', 'agent:monthly_review', 'Dichiarazione office', "
           "jsonb_build_object('month', to_char(date_trunc('month', current_date) - interval '1 month', 'YYYY-MM'), 'from', (date_trunc('month', current_date) - interval '1 month')::date, 'to', (date_trunc('month', current_date) - interval '1 day')::date, "
           "'mozzarella_dop_kg', 321, 'batches', 3, 'issues', jsonb_build_array(jsonb_build_object('check', 'latte_60h', 'it', 'Latte oltre 60 h', 'n', 1))), 'consorzio') returning id")
SUP = sql1(f"insert into fabula.parties (type, legal_name, email, phone, active) values ('supplier', 'Fornitore office {RUN}', 'f@office.it', '+39 333 1234567', true) returning id")
sql(f"insert into fabula.supplier_prices (supplier_id, product_id, price_eur, valid_from) values ('{SUP}', '{rennet}', 25, current_date - 10)")
TBC = sql1(f"insert into fabula.products (sku, name, kind, unit, active, track_stock) values ('CON-OFF{RUN}', 'Detergente office {RUN}', 'consumable', 'kg', true, true) returning id")
sql(f"insert into fabula.supplier_products (supplier_id, product_id) values ('{SUP}', '{TBC}') on conflict do nothing")
PO_BIG = json.loads(sql_as(OWNER[0], f"fabula.create_manual_po('{SUP}', '[{{\\\"product_id\\\":\\\"{rennet}\\\",\\\"qty\\\":40}}]'::jsonb)"))
PO_OK = json.loads(sql_as(OWNER[0], f"fabula.create_manual_po('{SUP}', '[{{\\\"product_id\\\":\\\"{rennet}\\\",\\\"qty\\\":2}}]'::jsonb)"))
PO_SENT = 'PO-OS' + RUN
POS_ID = sql1(f"insert into fabula.purchase_orders (po_number, supplier_id, status, sent_at, total_eur) values ('{PO_SENT}', '{SUP}', 'sent', now(), 50) returning id")
# ---- recipes, holds, NCs ----
# a mozzarella component not changed today («Togli» on one changed today stops at once instead; other suites change the rennet dose)
RID, RSKU = (sql1(f"select r.id || '|' || p.sku from fabula.recipes r join fabula.products p on p.id = r.component_product_id where r.finished_product_id = '{moz}' and r.valid_to is null and r.valid_from < (now() at time zone 'Europe/Rome')::date order by p.sku = 'CON-RENNET' desc, p.sku limit 1") + '|').split('|')[:2]
sql("insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, output_kg, source, food_safety_hold, hold_reason, hold_at) values "
    f"(current_date, 'LH1{RUN[-3:]}', '{moz}', 300, 'milk', now(), 90, 'tablet', true, 'analisi non conforme', now()), (current_date, 'LH2{RUN[-3:]}', '{moz}', 300, 'milk', now(), 90, 'tablet', true, 'controllo', now())")
LH1, LH2 = 'LH1' + RUN[-3:], 'LH2' + RUN[-3:]
sql(f"insert into fabula.approvals (kind, requested_by, summary, payload) values ('other', 'agent:food_safety', 'Valutare ritiro {LH1}', jsonb_build_object('type', 'recall_assessment', 'lot', '{LH1}', 'distribution', '[]'::jsonb))")
sql(f"insert into fabula.lab_samples (test_id, sample_code, lot_number, outcome, report_no, report_date) select id, 'C-E2E-{RUN}', '{LH2}', 'conforme', 'R-77', current_date from fabula.lab_tests limit 1")
NC = sql1(f"insert into fabula.non_conformities (severity, status, description, corrective_action, closed_at) values ('minor', 'closed', 'NC office {RUN}', 'fatto', now() - interval '1 day') returning id")
# ---- wholesale ----
sql("update fabula.settings set value = 'delivery' where key = 'trade.tier_basis'")
TP = 'gid://office/' + RUN
sql(f"insert into fabula.trade_products (variant_id, product_id, title, variant_title, kg_per_unit, unit_label, base_price_eur, trade_price_eur, min_qty, step_qty, sort) values ('{TP}', '{moz}', 'Mozzarella office', '{RUN}', 1, 'kg', 14, 11.5, 1, 1, 1)")
TIER = sql1(f"insert into fabula.trade_price_tiers (variant_id, min_qty, price_eur, active, note) values ('{TP}', 40, 10.5, true, 'tier office') returning id")
sql(f"update fabula.trade_price_tiers set synced_at = now() + interval '1 second' where id = '{TIER}'")
CUST = sql1(f"insert into fabula.parties (type, legal_name, phone, active, trade_status, portal_token) values ('customer', 'Pizzeria office {RUN}', '3331112222', true, 'approved', md5('office{RUN}')) returning id")
DD = sql1("select g::date from generate_series(fabula.trade_now_rome()::date + 3, fabula.trade_now_rome()::date + 20, interval '1 day') g where fabula.trade_is_delivery_day(g::date) order by g limit 1")
WW = sql1(f"select extract(isodow from '{DD}'::date)::int")
sql(f"select fabula.trade_save_schedule('{CUST}', '{{\\\"days\\\":{{\\\"{WW}\\\":{{\\\"lines\\\":{{\\\"{TP}\\\":6}}}}}}}}'::jsonb)")
# ---- tablet: a delivery and a product without recipe or preset ----
sup = sql1("select id from fabula.parties where is_milk_supplier and active order by created_at limit 1")
sql("update fabula.milk_shipments set status = 'cancelled', cancel_reason = 'reset office_e2e', cancelled_at = now() where status = 'shipped'")
sql("update fabula.settings set value = '800' where key = 'prod.vat_kg'")
MILK = 'MO' + RUN
sql(f"insert into fabula.milk_intake (intake_date, intake_time, supplier_id, milk_lot, qty_kg, accepted, temperature_c, source) values ('{TODAY}', (now() at time zone 'Europe/Rome')::time, '{sup}', '{MILK}', 800, true, 4, 'tablet')")
sql(f"insert into fabula.labels (kind, code, lot_number, milk_intake_id) select 'milk_lot', 'LOT:{MILK}', '{MILK}', id from fabula.milk_intake where milk_lot = '{MILK}'")
NOPRE = sql1(f"insert into fabula.products (sku, name, kind, unit, is_dop, shelf_life_days, active, track_stock) values ('OFF{RUN}', 'Prova office {RUN}', 'finished_good', 'kg', false, 5, true, true) returning id")

srv = subprocess.Popen(['python3', '-m', 'http.server', str(PORT)], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1)
fails = []
def check(name, cond, info=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f'  [{info}]' if info else ''))
    if not cond: fails.append(name)
edge_calls = []
def trade_fn(route):                                   # mocks supabase/functions/trade-portal (preview and sync)
    r = route.request; H = {'access-control-allow-origin': '*', 'content-type': 'application/json'}
    if r.method == 'OPTIONS': return route.fulfill(status=200, headers=H, body='ok')
    a = r.url.split('action=')[1].split('&')[0]; edge_calls.append(a)
    if a == 'prices-preview':
        return route.fulfill(status=200, headers=H, body=json.dumps({'basis': 'delivery', 'changes': [
            {'variant_id': TP, 'name': 'Mozzarella office ' + RUN, 'what': 'prezzo €', 'now': '11.50', 'new': '11.90'},
            {'variant_id': TP, 'name': 'Mozzarella office ' + RUN, 'what': 'scaglioni', 'now': 'da 40: 10.50', 'new': None}], 'prices': 1, 'removed': 0}))
    if a == 'sync-prices':
        return route.fulfill(status=200, headers=H, body=json.dumps({'prices': 1, 'rules': 1, 'price_breaks': 0, 'removed': 0, 'breaks_removed': 1, 'changes': 2, 'basis': 'delivery'}))
    return route.fulfill(status=404, headers=H, body=json.dumps({'error': 'azione non valida'}))
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
        if '/functions/v1/trade-portal' in u: return trade_fn(route)
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
    # ================= Console → Oggi =================
    ctx, cp = page_as(b, OWNER, 'console.html#oggi', logs)
    cp.wait_for_timeout(6000); dl = Dlg(cp)
    card = lambda i: f"document.querySelector('#approvals .appr[data-id=\"{i}\"]')"
    order = cp.evaluate("[...document.querySelectorAll('#approvals .appr')].map(c => c.dataset.id)")
    pos = lambda i: order.index(i) if i in order else 99
    check('B-12 most urgent first: milk due tomorrow, then DOP, then promo, then the order, then the post',
          pos(A1) < pos(DOP) < pos(AP) < pos(PO_BIG['approval_id']) < pos(MC and sql1(f"select approval_id from fabula.mkt_content where id = '{MC}'")), str([pos(A1), pos(DOP), pos(AP), pos(PO_BIG['approval_id'])]))
    g = cp.evaluate(f"(() => {{ const c = {card(A2)}; return c ? c.className + '|' + !!c.querySelector('[data-act]') + '|' + c.innerText : ''; }})()")
    check('E-12 a request past its deadline is greyed, says so, and has no «Approva»', 'gone' in g and '|false|' in g and 'Scaduta' in g, g[:160].replace('\n', ' '))
    m1 = cp.evaluate(f"{card(A1)}.innerText")
    check('B-09 the milk card shows the farm warning (500 kg available) instead of hiding it', 'MASSERIA' in m1.upper() and '500' in m1, m1.replace('\n', ' | ')[:300])
    cp.evaluate(f"(() => {{ const i = {card(A1)}.querySelector('input[data-kg]'); i.value = '400'; i.dispatchEvent(new Event('input', {{ bubbles: true }})); }})()")
    btxt = cp.evaluate(f"{card(A1)}.querySelector('[data-act=approved]').textContent")
    check('B-09 typing 400 kg turns the button into «Approva con 400 kg»', btxt == 'Approva con 400 kg', btxt)
    dl.answers = [True]; cp.evaluate(f"{card(A1)}.querySelector('[data-act=approved]').click()"); cp.wait_for_timeout(2500)
    mp = sql1(f"select status || '|' || milk_kg from fabula.milk_plans where approval_id = '{A1}'")
    check('B-09 asked once naming the consequence, then the plan is approved at 400 kg (and reaches the farm page)',
          dl.log and 'Approvare 400 kg di latte per' in dl.log[-1] and 'il piano ne proponeva 500' in dl.log[-1] and mp == 'approved|400.0', mp + ' || ' + ' / '.join(dl.log))
    check('B-09 …the toast says what happens next', 'La Masseria vede l\'ordine: 400 kg' in toast(cp), toast(cp))
    # «Decise di recente» → Annulla
    cp.wait_for_timeout(1500)
    dl.answers = [True]; cp.evaluate(f"document.querySelector('#appr-recent .dec[data-id=\"{A1}\"] [data-undo]').click()"); cp.wait_for_timeout(3500)
    st = sql1(f"select a.status || '|' || m.status || '|' || coalesce(a.auto_rule, '') from fabula.approvals a join fabula.milk_plans m on m.approval_id = a.id where a.id = '{A1}'")
    check('B-12 «Annulla» in Decise di recente puts the plan back to decide (off the farm page)', st.startswith('pending|proposed|decisione annullata da Owner Office'), st)
    check('B-12 …and its card is back in «Da approvare»', cp.evaluate(f"!!{card(A1)}"))
    dl.answers = [True]; cp.evaluate(f"{card(A1)}.querySelector('[data-act=rejected]').click()"); cp.wait_for_timeout(3000)
    check('B-09 «Rifiuta» on a milk plan asks first', any('Rifiutare il piano latte per' in x for x in dl.log), ' / '.join(dl.log[-2:]))
    cp.evaluate(f"(() => {{ const d = document.querySelector('#appr-recent .dec[data-id=\"{A1}\"]'); d.querySelector('[data-okg]').value = '450'; }})()")
    dl.answers = [True]; cp.evaluate(f"document.querySelector('#appr-recent .dec[data-id=\"{A1}\"] [data-order]').click()"); cp.wait_for_timeout(3500)
    new = sql1(f"select status || '|' || milk_kg from fabula.milk_plans where plan_date = '{D1}' and status in ('proposed', 'approved')")
    check('B-09 after «Rifiuta», «Ordina 450 kg» orders the day again in one go', new == 'approved|450.0' and 'Ordinare 450 kg di latte' in dl.log[-1], new + ' || ' + dl.log[-1])
    # DOP: the checks first, then «Segna inviata»
    dl.answers = []; cp.evaluate(f"{card(DOP)}.querySelector('[data-act=approved]').click()"); cp.wait_for_timeout(1200)
    check('B-11 «Approva i dati» without ticking the checks (or a note) is stopped', 'Spunta i controlli' in toast(cp) and sql1(f"select status from fabula.approvals where id = '{DOP}'") == 'pending', toast(cp))
    cp.evaluate(f"{card(DOP)}.querySelector('input[data-iss]').click()")
    dl.answers = [True]; cp.evaluate(f"{card(DOP)}.querySelector('[data-act=approved]').click()"); cp.wait_for_timeout(3000)
    dn = sql1(f"select status || '|' || coalesce(decision_note, '') from fabula.approvals where id = '{DOP}'")
    check('B-11 ticked, approved with «Visti: …» as its note', dn.startswith('approved|Visti: Latte oltre 60 h'), dn)
    ds = cp.evaluate("(document.querySelector('#dop-send') || {}).innerText || ''")
    check('B-11 the declaration stays in sight to print and send', 'da inviare' in ds and 'Stampa / PDF' in ds and cp.evaluate(f"!!document.querySelector('#dop-send a[href=\"consorzio.html?id={DOP}\"]')"), ds.replace('\n', ' | '))
    cp.evaluate("(() => { const c = document.querySelector('#dop-send .appr.dop'); c.querySelector('[data-prot]').value = '2026/88'; c.querySelector('[data-sent]').click(); })()"); cp.wait_for_timeout(2500)
    sent = sql1(f"select coalesce(payload->>'protocol', '') || '|' || coalesce(payload->>'sent_by', '') from fabula.approvals where id = '{DOP}'")
    check('B-11 «Segna inviata» records the protocol and who', sent == '2026/88|Owner Office', sent)
    # the post and the order cards
    mca = sql1(f"select approval_id from fabula.mkt_content where id = '{MC}'")
    pc = cp.evaluate(f"(() => {{ const c = {card(mca)}; return c ? [c.querySelector('a[href=\"marketing.html#post={MC}\"]') != null, !!c.querySelector('img')].join('|') : ''; }})()")
    check('B-13 the post card links to that post and shows its picture', pc == 'true|true', pc)
    pt = cp.evaluate(f"{card(PO_BIG['approval_id'])}.innerText")
    check('B-18 a catalogue order above the limit is one card with its lines and why it waits', all(x in pt.lower() for x in ("righe dell'ordine", 'sopra il limite', 'creato da', 'owner office')), pt.replace('\n', ' | ')[:240])
    # ================= Operazioni: «Annulla ordine» =================
    cp.evaluate("document.querySelector('.tab[data-tab=\"ops\"]').click()"); cp.wait_for_timeout(5000)
    dl.answers = ['fornitore sbagliato']
    cp.evaluate(f"(() => {{ const c = [...document.querySelectorAll('#po-send .eq')].find(x => x.textContent.includes('{PO_OK['po_number']}')); c.querySelector('button.warn').click(); }})()"); cp.wait_for_timeout(2500)
    c1 = sql1(f"select status || '|' || coalesce(cancel_reason, '') from fabula.purchase_orders where po_number = '{PO_OK['po_number']}'")
    check('B-18 «Annulla ordine» on an order to send asks the reason and cancels it', c1 == 'cancelled|fornitore sbagliato', c1 + ' || ' + ' / '.join(dl.log[-1:]))
    dl.answers = ['doppione']
    cp.evaluate(f"document.querySelector('#po-sent [data-cxpo=\"{PO_SENT}\"]').click()"); cp.wait_for_timeout(2500)
    box = cp.evaluate("document.getElementById('po-sent').innerText")
    check('B-18 a sent order is cancelled too, with the message for the supplier (WhatsApp ready)', sql1(f"select status from fabula.purchase_orders where po_number = '{PO_SENT}'") == 'cancelled'
          and 'Era già stato inviato' in box and cp.evaluate("!!document.querySelector('#po-sent a[href^=\"https://wa.me/39\"]')"), box[:200].replace('\n', ' | '))
    # ================= Anagrafiche =================
    cp.evaluate("document.querySelector('.tab[data-tab=\"anag\"]').click()"); cp.wait_for_timeout(5000)
    cp.evaluate("document.querySelector('#party-tabs .sub[data-type=\"customer\"]').click()"); cp.wait_for_timeout(1500)
    an = cp.evaluate("document.getElementById('p-anag').innerText")
    check('B-19 the old «Ordini fissi» grid is gone; the plans are in Ingrosso', not cp.evaluate("!!document.getElementById('set-standing')") and 'piani consegne ingrosso' in an.lower() and 'ingrosso → clienti e piani' in an.lower(), an[-260:].replace('\n', ' | '))
    cp.evaluate("document.querySelector('#party-tabs .sub[data-type=\"supplier\"]').click()"); cp.wait_for_timeout(800)
    cp.evaluate(f"window.SUPPLIES.prefill('CON-OFF{RUN}', 5)"); cp.wait_for_timeout(1500)
    n_po = sql1(f"select count(*) from fabula.purchase_orders where supplier_id = '{SUP}'")
    dl.answers = []; cp.evaluate("[...document.querySelectorAll('#sup-order button')].find(x => /^Crea/.test(x.textContent)).click()"); cp.wait_for_timeout(1500)
    check('B-18 a line without a price stops «Crea ordine» until «prezzo da confermare» is ticked', 'senza prezzo' in toast(cp) and sql1(f"select count(*) from fabula.purchase_orders where supplier_id = '{SUP}'") == n_po, toast(cp))
    cp.evaluate("document.getElementById('sup-tbc').click()")
    dl.answers = [True]; cp.evaluate("[...document.querySelectorAll('#sup-order button')].find(x => /^Crea/.test(x.textContent)).click()"); cp.wait_for_timeout(3000)
    po_t = sql1(f"select po.status || '|' || l.unit_price_eur from fabula.purchase_orders po join fabula.purchase_order_lines l on l.purchase_order_id = po.id where po.supplier_id = '{SUP}' and l.product_id = '{TBC}' order by po.created_at desc limit 1")
    check('B-18 before creating: every line and the total, then the order waits for approval with the price to confirm',
          dl.log and 'Controlla quantità e prezzi' in dl.log[-1] and 'prezzo da confermare' in dl.log[-1] and 'aspetta' in dl.log[-1] and po_t.startswith('pending_approval|0'), po_t + ' || ' + dl.log[-1][:200])
    # ================= Ricette =================
    cp.evaluate("document.querySelector('.tab[data-tab=\"ricette\"]').click()"); cp.wait_for_timeout(5000)
    tr = f"[...document.querySelectorAll('#recipes tr')].find(t => t.textContent.includes('{RSKU}') && t.closest('.card').querySelector('h3').textContent.includes('MOZ-DOP-KG'))"
    dl.answers = [True]; cp.evaluate(f"[...{tr}.querySelectorAll('button')].find(x => x.textContent === 'Togli').click()"); cp.wait_for_timeout(3000)
    vt = sql1(f"select coalesce(valid_to::text, '') from fabula.recipes where id = '{RID}'")
    rtxt = cp.evaluate(f"{tr}.innerText")
    check('B-15 «Togli» asks, then the component ends from tomorrow (today still dosed)', any('Da domani non si dosa più' in x for x in dl.log) and vt == TODAY and 'tolto: da domani' in rtxt, vt + ' || ' + rtxt[:120].replace('\n', ' '))
    cp.evaluate(f"[...{tr}.querySelectorAll('button')].find(x => x.textContent === 'Rimetti').click()"); cp.wait_for_timeout(3000)
    check('B-15 «Rimetti» the same day undoes it', sql1(f"select valid_to is null from fabula.recipes where id = '{RID}'") == 't', toast(cp))
    srow = "[...document.querySelectorAll('#presets tbody[data-scope=\"step\"]')].find(t => t.querySelector('input.w') && t.querySelector('input.w').value && t.querySelector('tr').querySelectorAll('input.n')[1].value)"
    sid = cp.evaluate(f"(() => {{ const t = {srow}; return t ? t.querySelector('input.w').value : ''; }})()")
    if sid:
        step_id = sql1(f"select id from fabula.process_steps where name_it = '{sid}' and active order by created_at limit 1")
        cp.evaluate(f"(() => {{ const t = {srow}; const i = t.querySelector('tr').querySelectorAll('input.n')[1]; i.value = '94,5'; i.dispatchEvent(new Event('input', {{ bubbles: true }})); t.querySelector('button.save').click(); }})()")
        cp.wait_for_timeout(2500)
        tv = sql1(f"select target_temp_c from fabula.process_steps where id = '{step_id}'")
        check('B-16 a preset target typed «94,5» is saved as 94.5 (it used to become empty in some browsers)', tv in ('94.5', '94.50'), tv + ' || ' + toast(cp))
        dl.answers = [False]; nlog = len(dl.log)
        cp.evaluate(f"[...[...document.querySelectorAll('#presets tbody[data-scope=\"step\"]')].find(t => t.querySelector('input.w').value === '{sid}').querySelectorAll('button')].find(x => x.textContent === 'Togli').click()"); cp.wait_for_timeout(1500)
        check('B-16 «Togli» on a step asks first (here: no, the step stays)', len(dl.log) > nlog and 'Togliere il passo' in dl.log[-1] and sql1(f"select active from fabula.process_steps where id = '{step_id}'") == 't', ' / '.join(dl.log[nlog:]))
    else: check('B-16 a preset with a temperature target to edit', False, 'no step row with a target')
    ctx.close()

    # ================= Autocontrollo =================
    ctx2, hp = page_as(b, OWNER, 'haccp.html#registro', logs)
    hp.wait_for_timeout(6000); hd = Dlg(hp)
    hp.evaluate(f"document.querySelector('[data-release=\"{LH1}\"]').click()"); hp.wait_for_timeout(1500)
    check('B-06 a lot with an open recall decision is not released (the dialog does not open)', 'Prima decidi la valutazione di ritiro/richiamo' in toast(hp)
          and not hp.evaluate("document.getElementById('dlg').open"), toast(hp))
    hp.evaluate(f"document.querySelector('[data-release=\"{LH2}\"]').click()"); hp.wait_for_timeout(2000)
    dtxt = hp.evaluate("document.getElementById('dlg-body').innerText")
    check('B-06 the release dialog shows why it is held and the conforming analysis to pick', 'Bloccato per' in dtxt and f'C-E2E-{RUN}' in hp.evaluate("document.getElementById('dlg-body').innerHTML"), dtxt[:160].replace('\n', ' | '))
    hp.evaluate("document.querySelector('input[name=rl-k][value=lab]').click()")
    hp.evaluate("document.getElementById('dlg-ok').click()"); hp.wait_for_timeout(2500)
    rel = sql1(f"select food_safety_hold || '|' || coalesce(notes, '') from fabula.production_batches where batch_lot = '{LH2}'")
    check('B-06 released naming the analysis (referto included)', rel.startswith('false|') and f'analisi conforme C-E2E-{RUN} (referto R-77' in rel, rel)
    hd.answers = [True]; hp.evaluate(f"document.querySelector('#ncs-closed [data-reopen=\"{NC}\"]').click()"); hp.wait_for_timeout(2500)
    check('B-06 a closed NC is reopened from «NC chiuse»', sql1(f"select status from fabula.non_conformities where id = '{NC}'") == 'investigating', ' / '.join(hd.log))
    ctx2.close()

    # ================= Ingrosso =================
    ctx3, ip = page_as(b, OWNER, 'ingrosso.html#clienti', logs)
    ip.wait_for_timeout(5000); idl = Dlg(ip)
    # the card opens on demand; saving an exception reloads the list (cards closed again)
    def open_cust():
        ip.evaluate(f"(() => {{ const d = [...document.querySelectorAll('#custs details.cust')].find(x => x.textContent.includes('Pizzeria office {RUN}')); if (!d.open) {{ d.open = true; d.dispatchEvent(new Event('toggle')); }} }})()"); ip.wait_for_timeout(3500)
    open_cust()
    body = f"[...document.querySelectorAll('#custs details.cust')].find(x => x.textContent.includes('Pizzeria office {RUN}')).querySelector('[data-body]')"
    lbl = ip.evaluate(f"{body}.querySelector('.exrow').innerText")
    check('B-21 the exception form has labels («Dal», «Al»)', 'Dal' in lbl and 'Al' in lbl, lbl.replace('\n', ' | '))
    ip.evaluate(f"(() => {{ const r = {body}.querySelector('.exrow'); const k = r.querySelector('[data-exk]'); k.value = 'override'; k.dispatchEvent(new Event('change')); r.querySelector('[data-exf]').value = '{DD}'; r.querySelector('[data-exadd] button').click(); }})()"); ip.wait_for_timeout(1500)
    check('B-21 «Quantità temporanea» with no quantity is refused (it used to remove the product)', 'Scrivi la quantità, oppure spunta «Togli il prodotto»' in toast(ip)
          and sql1(f"select count(*) from fabula.trade_exceptions where customer_id = '{CUST}'") == '0', toast(ip))
    idl.answers = [True]
    ip.evaluate(f"(() => {{ const r = {body}.querySelector('.exrow'); r.querySelector('[data-exrm]').click(); r.querySelector('[data-exadd] button').click(); }})()"); ip.wait_for_timeout(3000)
    ex = sql1(f"select kind || '|' || qty from fabula.trade_exceptions where customer_id = '{CUST}' and cancelled_at is null")
    check('B-21 «Togli il prodotto», confirmed with a summary the customer will see', ex.startswith('override|0') and idl.log and 'tolto dalla consegna' in idl.log[-1] and 'portale' in idl.log[-1], ex + ' || ' + ' / '.join(idl.log[-1:]))
    open_cust()
    idl.answers = [False]; ip.evaluate(f"{body}.querySelector('[data-suspend]').click()"); ip.wait_for_timeout(1500)
    check('B-24 «Sospendi accesso» asks, naming the consequence (here: no)', idl.log and 'Sospendere l\'accesso' in idl.log[-1] and sql1(f"select trade_status from fabula.parties where id = '{CUST}'") == 'approved', ' / '.join(idl.log[-1:]))
    tok0 = sql1(f"select portal_token from fabula.parties where id = '{CUST}'")
    idl.answers = [True]; ip.evaluate(f"{body}.querySelector('[data-newlink]').click()"); ip.wait_for_timeout(3000)
    nl = ip.evaluate(f"{body}.querySelector('[data-newlinkbox]').innerText")
    check('B-24 «Nuovo link portale» asks, then shows the new link to send', idl.log and 'smette di funzionare subito' in idl.log[-1] and sql1(f"select portal_token from fabula.parties where id = '{CUST}'") != tok0 and 'Nuovo link' in nl, nl[:160])
    # listino
    ip.evaluate("document.querySelector('.tab[data-tab=\"listino\"]').click()"); ip.wait_for_timeout(3500)
    trow = f"document.querySelector('tr[data-v=\"{TP}\"]')"
    ip.evaluate(f"(() => {{ const i = {trow}.querySelector('[data-f=\"trade_price_eur\"]'); i.value = '11,90'; i.dispatchEvent(new Event('input', {{ bubbles: true }})); {trow}.querySelector('button.save').click(); }})()"); ip.wait_for_timeout(3000)
    check('B-22 a changed product row says «da inviare»', 'da inviare' in ip.evaluate(f"{trow}.innerText").lower(), ip.evaluate(f"{trow}.innerText").replace('\n', ' '))
    tr2 = f"document.querySelector('tr[data-tid=\"{TIER}\"]')"
    ip.evaluate(f"(() => {{ const c = {tr2}.querySelector('[data-t]'); c.click(); }})()"); ip.wait_for_timeout(500)
    still = sql1(f"select active from fabula.trade_price_tiers where id = '{TIER}'")
    ip.evaluate(f"{tr2}.querySelector('button.save').click()"); ip.wait_for_timeout(3000)
    check('B-23 switching a tier off waits for «Salva» (not saved on the tick), then it is off and «da inviare»',
          still == 't' and sql1(f"select active from fabula.trade_price_tiers where id = '{TIER}'") == 'f' and 'da inviare' in ip.evaluate(f"{tr2}.innerText").lower(), still + ' ' + ip.evaluate(f"{tr2}.innerText").replace('\n', ' '))
    ip.evaluate("document.getElementById('pr-sync').click()"); ip.wait_for_timeout(2500)
    pv = ip.evaluate("document.getElementById('pr-preview').innerText")
    check('B-22 «Invia a Shopify…» first shows what changes (Shopify now → after)', 'prices-preview' in edge_calls and 'scaglioni' in pv and 'Invia 2 modifiche a Shopify' in pv and 'sync-prices' not in edge_calls, pv.replace('\n', ' | ')[:240])
    ip.evaluate("document.getElementById('pr-go').click()"); ip.wait_for_timeout(2500)
    check('B-22 …then sends them', 'sync-prices' in edge_calls and 'scaglioni vecchi rimossi' in ip.evaluate("document.getElementById('pr-sync-st').textContent"), ip.evaluate("document.getElementById('pr-sync-st').textContent"))
    ctx3.close()

    # ================= Marketing deep link =================
    ctx4, mp = page_as(b, OWNER, f'marketing.html#post={MC}', logs)
    mp.wait_for_timeout(5000)
    st = mp.evaluate("[document.querySelector('.pane.active') && document.querySelector('.pane.active').id, (document.getElementById('pe-title') || {}).textContent]")
    check('B-13 marketing.html#post=<id> opens the calendar on that post', st[0] == 'p-calendario' and st[1] == 'Post', str(st))
    ctx4.close()

    # ================= tablet: the lot label at the start =================
    ctx5, tp = page_as(b, CASARO, 'index.html', logs, 800)
    tp.wait_for_function("document.querySelector('#v-home.active')", timeout=20000); tp.wait_for_timeout(4000)
    def code(c): tp.evaluate("c => { document.getElementById('manual').value = c; document.getElementById('btn-manual').click(); }", c); tp.wait_for_timeout(1800)
    def setf(vals):
        for k, v in vals.items(): tp.evaluate("([k, v]) => { const e = document.getElementById(k); if (!e) return; e.value = v; e.dispatchEvent(new Event('change')); e.dispatchEvent(new Event('input')); }", [k, str(v)])
    def typef(k, v):
        if not tp.evaluate("k => !!document.getElementById(k) && document.getElementById(k).offsetParent !== null", k): return
        tp.fill('#' + k, ''); tp.type('#' + k, str(v)); tp.wait_for_timeout(150)
    code('LOT:' + MILK)
    setf({'product': NOPRE}); setf({'valve': '0'}); typef('kg', '300'); typef('past', '72,5')
    tp.evaluate("document.getElementById('btn-form-save').click()"); tp.wait_for_timeout(3500)
    lot = sql1(f"select batch_lot from fabula.production_batches where product_id = '{NOPRE}' order by created_at desc limit 1")
    lk = tp.evaluate("(() => { const a = [...document.querySelectorAll('#form a')].find(x => x.textContent.includes('Stampa etichetta lotto in lavorazione')); return a ? a.getAttribute('href') : ''; })()")
    check('A-02 a started lot offers its own label (LOT:L…, «in lavorazione») to put on the vat', lot != '' and 'labels.html' in lk and ('LOT%3A' + lot) in lk and 'in+lavorazione' in lk, lot + ' · ' + lk)
    check('A-02 …and the card says to scan that label, not the tank', 'non quella del tank' in tp.evaluate("document.getElementById('form').innerText"), tp.evaluate("document.getElementById('form').innerText")[:200].replace('\n', ' | '))
    ctx5.close()

    sql(f"update fabula.sales_orders set status = 'cancelled' where id = '{SO}'")
    errs = [l for l in logs if 'PAGEERROR' in l]
    check('no page errors', not errs, ' | '.join(errs[:3]))
finally:
    srv.terminate()
print('FAILURES:', fails or 'none')
