"""v1.02 audit E-18: the edge function `shopify-sync` run locally with Deno against the local copy (restore_drill + PostgREST on :3000,
v102a applied) and a fake Shopify Admin API on :8791 (it also forwards /rest/v1 to PostgREST, as Supabase does).
- no key or a wrong key: 403; «status»: the permissions each job is missing.
- customers: Shopify's count + every page → the customers in the database, a run record and an «info» message written by the database.
- orders: two orders (one at the till) → the orders and the till day; a packed web shipment confirmed on Shopify with its tracking.
- orders that do not match Shopify's count: the run fails, nothing is written, the alarm says why.
- stock, comparison only (push off): Shopify untouched; a product that does not track quantities is listed. Push on: without the
  permission nothing is sent; with it only the tracked product that differs is set, with an idempotency key.
Needs Deno: DENO=/path/to/deno (e.g. npm i deno → node_modules/.bin/deno). Expect "FAILURES: none"."""
import json, os, subprocess, threading, time, hmac, hashlib, base64, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DENO = os.environ.get('DENO', '/tmp/claude-0/denoinst/node_modules/.bin/deno')
FN = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../../../supabase/functions/shopify-sync/index.ts'))
def _b64(b): return base64.urlsafe_b64encode(b).rstrip(b'=').decode()
def _jwt_role(role, secret=b"test-secret-test-secret-test-secret-0123456789"):
    h = _b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode()); p = _b64(json.dumps({"role": role, "exp": int(time.time()) + 3600}).encode())
    return h + '.' + p + '.' + _b64(hmac.new(secret, (h + '.' + p).encode(), hashlib.sha256).digest())
def sql(q):
    r = subprocess.run(['su', 'postgres', '-c', f'psql -At -d restore_drill -c "{q}"'], capture_output=True, text=True)
    if 'ERROR' in r.stderr: print('SQL ERROR:', q[:90], '→', r.stderr.strip()[:300])
    return r.stdout.strip() or r.stderr.strip()
def sql1(q): return (sql(q).splitlines() or [''])[0]

RUN = time.strftime('%H%M%S')
NOW = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(time.time() - 3600))
money = lambda a: {"shopMoney": {"amount": a}}
LINE = lambda t, q, p, v=None, attrs=None: {"title": t, "variantTitle": "250 g", "quantity": q, "sku": None, "product": {"productType": "Mozzarella"},
                                            "variant": {"id": v} if v else None, "customAttributes": attrs or [], "originalUnitPriceSet": money(p), "taxLines": [{"ratePercentage": 4}]}
ORDERS = [
  {"id": f"gid://shopify/Order/9{RUN}1", "name": f"#E{RUN}1", "createdAt": NOW, "updatedAt": NOW, "cancelledAt": None, "displayFinancialStatus": "PAID",
   "displayFulfillmentStatus": "UNFULFILLED", "sourceName": "web", "tags": [], "paymentGatewayNames": ["shopify_payments"], "subtotalPriceSet": money("10.00"),
   "totalTaxSet": money("0.40"), "totalPriceSet": money("10.40"), "customer": {"id": f"gid://shopify/Customer/8{RUN}1", "displayName": "Anna Test"}, "email": "anna@test.it",
   "phone": None, "purchasingEntity": None, "shippingAddress": {"name": "Anna Test", "address1": "Via Roma 1", "address2": None, "city": "Salerno", "zip": "84100", "province": "SA", "countryCodeV2": "IT", "phone": None},
   "lineItems": {"pageInfo": {"hasNextPage": False, "endCursor": None}, "nodes": [LINE("Mozzarella di bufala", 2, "5.00", f"gid://shopify/ProductVariant/7{RUN}")]}},
  {"id": f"gid://shopify/Order/9{RUN}2", "name": f"#E{RUN}2", "createdAt": NOW, "updatedAt": NOW, "cancelledAt": None, "displayFinancialStatus": "PAID",
   "displayFulfillmentStatus": "FULFILLED", "sourceName": "pos", "tags": [], "paymentGatewayNames": ["cash"], "subtotalPriceSet": money("6.00"),
   "totalTaxSet": money("0.24"), "totalPriceSet": money("6.24"), "customer": None, "email": None, "phone": None, "purchasingEntity": None, "shippingAddress": None,
   "lineItems": {"pageInfo": {"hasNextPage": False, "endCursor": None}, "nodes": [LINE("Vendita libera", 1, "6.00", None, [{"key": "sku", "value": "MOZ-DOP-KG"}, {"key": "peso_kg", "value": "0.4"}])]}},
]
CUSTOMERS = [{"id": f"gid://shopify/Customer/8{RUN}{i}", "firstName": "Cliente", "lastName": f"E2E{i}", "displayName": f"Cliente E2E{RUN}{i}", "defaultEmailAddress": {"emailAddress": f"e2e{RUN}{i}@test.it"},
              "defaultPhoneNumber": None, "tags": ["ingrosso"] if i == 3 else [], "numberOfOrders": str(i), "amountSpent": {"amount": "10.0"}, "defaultAddress": {"company": None, "city": "Agropoli"}} for i in (1, 2, 3)]
STATE = {"orders_count": 2, "scopes": ["read_orders", "write_orders", "read_customers", "read_products", "read_inventory", "read_locations",
                                       "read_merchant_managed_fulfillment_orders", "write_merchant_managed_fulfillment_orders"]}
CALLS = []
SR = _jwt_role('service_role')

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
        n = int(self.headers.get('Content-Length') or 0); raw = self.rfile.read(n) or b''
        if self.path.endswith('/admin/oauth/access_token'): return self._send(200, {"access_token": "shpat_test", "expires_in": 86400})
        if '/graphql.json' not in self.path: return self._send(404, {})
        if self.headers.get('X-Shopify-Access-Token') != 'shpat_test': return self._send(401, {"errors": "unauthorized"})
        b = json.loads(raw or b'{}'); q = b.get('query', ''); v = b.get('variables') or {}; CALLS.append((q, v))
        if 'currentAppInstallation' in q: return self._send(200, {"data": {"currentAppInstallation": {"accessScopes": [{"handle": s} for s in STATE['scopes']]}}})
        if 'ordersCount' in q: return self._send(200, {"data": {"ordersCount": {"count": STATE['orders_count'], "precision": "EXACT"}}})
        if 'orders(first' in q: return self._send(200, {"data": {"orders": {"pageInfo": {"hasNextPage": False, "endCursor": None}, "nodes": ORDERS}}})
        if 'customersCount' in q: return self._send(200, {"data": {"customersCount": {"count": 3, "precision": "EXACT"}}})
        if 'customers(first' in q:
            page = CUSTOMERS[:2] if not v.get('after') else CUSTOMERS[2:]
            return self._send(200, {"data": {"customers": {"pageInfo": {"hasNextPage": not v.get('after'), "endCursor": "c2"}, "nodes": page}}})
        if 'fulfillmentOrders' in q: return self._send(200, {"data": {"order": {"id": v['id'], "displayFulfillmentStatus": "UNFULFILLED", "fulfillmentOrders": {"nodes": [{"id": "gid://shopify/FulfillmentOrder/1", "status": "OPEN"}]}}}})
        if 'fulfillmentCreate' in q: return self._send(200, {"data": {"fulfillmentCreate": {"fulfillment": {"id": f"gid://shopify/Fulfillment/{RUN}", "status": "SUCCESS"}, "userErrors": []}}})
        if 'nodes(ids' in q:
            nodes = [{"id": i, "inventoryQuantity": 12, "inventoryPolicy": "DENY", "inventoryItem": {"id": "II-" + i.rsplit('/', 1)[-1], "tracked": i.endswith('1')}} for i in v['ids']]
            return self._send(200, {"data": {"nodes": nodes, "locations": {"nodes": [{"id": "gid://shopify/Location/1", "name": "Caseificio", "isActive": True}]}}})
        if 'inventorySetQuantities' in q: return self._send(200, {"data": {"inventorySetQuantities": {"inventoryAdjustmentGroup": {"createdAt": NOW}, "userErrors": []}}})
        return self._send(200, {"errors": [{"message": "unexpected query in the fake Shopify"}]})

fails = []
def check(name, cond, info=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f'  [{info}]' if info else ''))
    if not cond: fails.append(name)
def post(body, key=None):
    hdr = {'Content-Type': 'application/json'}
    if key is not None: hdr['x-sync-secret'] = key
    req = urllib.request.Request('http://127.0.0.1:8000/', data=json.dumps(body).encode(), headers=hdr)
    try:
        with urllib.request.urlopen(req, timeout=60) as r: return r.status, json.loads(r.read().decode() or '{}')
    except urllib.error.HTTPError as e: return e.code, json.loads(e.read().decode() or '{}')

KEY = sql1("select value from fabula.job_secrets where name = 'shopify_sync'")
sql("update fabula.agent_runs set status = 'ok', finished_at = now() where status = 'running' and agent like 'shopify_%'")
sql("update fabula.settings set value = '3' where key = 'shopify.orders_days'")
sql("update fabula.parties set source = 'manual' where source = 'shopify' and legal_name like 'Cliente E2E%'")   # an earlier run's fake customers: not «gone from Shopify»
srv = ThreadingHTTPServer(('127.0.0.1', 8791), H); threading.Thread(target=srv.serve_forever, daemon=True).start()
env = dict(os.environ, SUPABASE_URL='http://127.0.0.1:8791', SUPABASE_SERVICE_ROLE_KEY=SR, SHOPIFY_CLIENT_ID='cid', SHOPIFY_CLIENT_SECRET='csecret',
           SHOPIFY_API_BASE='http://127.0.0.1:8791', DENO_DIR=os.environ.get('DENO_DIR', '/tmp/claude-0/denocache'))
fn = subprocess.Popen([DENO, 'run', '--allow-net', '--allow-env', FN], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
try:
    for _ in range(90):
        try: urllib.request.urlopen('http://127.0.0.1:8000/', timeout=1); break
        except urllib.error.HTTPError: break
        except Exception: time.sleep(1)
    st, _ = post({'agent': 'status'}); st2, _ = post({'agent': 'status'}, 'nope')
    check('no key or a wrong key: refused', st == 403 and st2 == 403, f'{st}/{st2}')
    st, r = post({'agent': 'status'}, KEY)
    check('status: credentials work; the stock job is missing write_inventory', st == 200 and r.get('configured') and r['missing']['shopify_inventory'] == ['write_inventory']
          and r['missing']['shipments'] == [] and r['missing']['shopify_orders'] == [], str(r)[:300])

    st, r = post({'agent': 'shopify_customers', 'by': 'Test E2E'}, KEY)
    run = r.get('run', '')
    check('customers: every page copied, checked against Shopify\'s count', st == 200 and r.get('ok')
          and sql1(f"select count(*) from fabula.parties where legal_name like 'Cliente E2E{RUN}%' and active") == '3'
          and sql1(f"select is_wholesale from fabula.parties where legal_name = 'Cliente E2E{RUN}3'") == 't', str(r)[:300])
    check('customers: the run record and the message come from the database', sql1(f"select status || '|' || (details->>'by') || '|' || summary from fabula.agent_runs where id = '{run}'").startswith('ok|Test E2E|3 letti, 3 nuovi')
          and sql1(f"select severity || '|' || title from fabula.bot_messages where run_id = '{run}'") == 'info|3 nuovi clienti da Shopify',
          sql1(f"select severity || '|' || title from fabula.bot_messages where run_id = '{run}'"))

    # a packed web shipment for the first order, once the order is in
    st, r = post({'agent': 'shopify_orders'}, KEY)
    run = r.get('run', '')
    check('orders: both written (the till one closes its day), the run is ok', st == 200 and r.get('ok')
          and sql1(f"select string_agg(channel::text, ',' order by order_number) from fabula.sales_orders where order_number like '#E{RUN}%'") == 'shopify,store_pos'
          and sql1(f"select ship_city || '|' || (shopify_payload->'shipping_address'->>'address1') from fabula.sales_orders where order_number = '#E{RUN}1'") == 'Salerno|Via Roma 1', str(r)[:300])
    q = [c for c in CALLS if 'orders(first' in c[0]][-1]
    check('orders: one fixed window for count and list, sorted by id', "updated_at:<=" in q[1].get('q', '') and 'sortKey: ID' in q[0], q[1].get('q', ''))
    so = sql1(f"select id from fabula.sales_orders where order_number = '#E{RUN}1'"); cust = sql1(f"select id from fabula.parties where type = 'customer' limit 1")
    sql(f"insert into fabula.shipments (ddt_number, customer_id, sales_order_id, status, carrier, tracking_number, packed_at) values ('DDT-E{RUN}', '{cust}', '{so}', 'picked', 'BRT', 'TRK{RUN}', now())")
    st, r = post({'agent': 'shopify_orders'}, KEY)
    fc = [c for c in CALLS if 'fulfillmentCreate' in c[0]]
    check('orders: the packed shipment is confirmed on Shopify with its tracking, then marked in the database',
          st == 200 and fc and fc[-1][1]['f']['trackingInfo'] == {'company': 'BRT', 'number': f'TRK{RUN}'}
          and sql1(f"select status || '|' || shopify_fulfillment_id from fabula.shipments where ddt_number = 'DDT-E{RUN}'") == f'in_transit|gid://shopify/Fulfillment/{RUN}', str(r)[:300])

    STATE['orders_count'] = 3
    n_before = sql1(f"select count(*) || '|' || max(updated_at) from fabula.sales_orders where order_number like '#E{RUN}%'")
    st, r = post({'agent': 'shopify_orders'}, KEY)
    run = r.get('run', '')
    check('orders that do not match Shopify\'s count: the run fails, nothing is written, the alarm says why',
          st == 200 and r.get('ok') is False and sql1(f"select count(*) || '|' || max(updated_at) from fabula.sales_orders where order_number like '#E{RUN}%'") == n_before
          and sql1(f"select status from fabula.agent_runs where id = '{run}'") == 'error'
          and sql1(f"select body like '%ne sono arrivati 2: nessuna modifica%' from fabula.bot_messages where run_id = '{run}'") == 't', str(r)[:300])
    STATE['orders_count'] = 2

    sql(f"insert into fabula.shopify_variant_map (variant_id, product_id, kg_per_unit, label) values ('gid://shopify/ProductVariant/7{RUN}1', (select id from fabula.products where sku = 'MOZ-DOP-KG'), 0.25, 'E2E 250 g'), "
        f"('gid://shopify/ProductVariant/7{RUN}2', (select id from fabula.products where sku = 'MOZ-DOP-KG'), 0.5, 'E2E 500 g') on conflict do nothing")
    push_was = sql1("select value from fabula.settings where key = 'shopify.push_inventory'")
    sql("update fabula.settings set value = '0' where key = 'shopify.push_inventory'")   # comparison only, whatever the other suites counted
    st, r = post({'agent': 'shopify_inventory'}, KEY)
    run = r.get('run', '')
    det = json.loads(sql1(f"select details from fabula.agent_runs where id = '{run}'") or '{}')
    check('stock, comparison only: Shopify untouched, the untracked product listed', st == 200 and r.get('ok') and det.get('push') == 0
          and not any('inventorySetQuantities' in c[0] for c in CALLS) and 'E2E 500 g' in det.get('untracked', []), str(det)[:300])
    # switched on, without the permission: nothing sent, the missing permission named; with it: only what differs, with a key
    sql("update fabula.settings set value = '1' where key = 'shopify.push_inventory'")
    st, r = post({'agent': 'shopify_inventory'}, KEY)
    det = json.loads(sql1(f"select details from fabula.agent_runs where id = '{r.get('run', '')}'") or '{}')
    check('stock switched on without the Shopify permission: nothing sent, the permission named', det.get('blocked') == 'scope' and det.get('missing') == 'write_inventory'
          and not any('inventorySetQuantities' in c[0] for c in CALLS), str(det)[:200])
    STATE['scopes'].append('write_inventory')
    st, r = post({'agent': 'shopify_inventory'}, KEY)
    det = json.loads(sql1(f"select details from fabula.agent_runs where id = '{r.get('run', '')}'") or '{}')
    m = [c for c in CALLS if 'inventorySetQuantities' in c[0]]
    check('stock switched on with the permission: only tracked products that differ are set, with an idempotency key',
          len(m) == 1 and '@idempotent(key: $key)' in m[0][0] and m[0][1]['key'] == r.get('run')
          and all(q['inventoryItemId'].endswith('1') and q['changeFromQuantity'] is None and q['quantity'] != 12 for q in m[0][1]['input']['quantities'])
          and f'II-7{RUN}1' in [q['inventoryItemId'] for q in m[0][1]['input']['quantities']]
          and det.get('set_count') == len(m[0][1]['input']['quantities']), str(m[-1][1] if m else det)[:300])
    sql(f"update fabula.settings set value = '{push_was}' where key = 'shopify.push_inventory'")
    out = ''
finally:
    os.killpg(fn.pid, 15)
    try: out = fn.communicate(timeout=10)[0]
    except Exception: out = ''
    srv.shutdown()
errs = [l for l in out.splitlines() if 'error' in l.lower() and 'shopify_sync_finish' not in l]
check('no errors in the function log', not errs, ' | '.join(errs)[:300])
print('FAILURES:', fails or 'none')
