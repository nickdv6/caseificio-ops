# CashDro ⇄ Shopify POS ⇄ Epson RT — deployment guide (Latteria Fabula, Agropoli)

```
 iPad (Shopify POS)                 Mac mini / PC "pos-bridge"               LAN devices
 ┌────────────────────┐   HTTPS     ┌──────────────────────────┐   HTTP   ┌──────────────┐
 │ Tile "Paga con     │ ──────────▶ │ middleware.py (FastAPI)  │ ───────▶ │ CashDro S    │
 │ CashDro" + modal   │ ◀────────── │  :8443                   │          │ Cashdro3WS   │
 │ (POS UI extension) │  poll 1 s   │  SQLite journal          │ ───────▶ │ Epson FP-81  │
 └────────────────────┘             └──────────────────────────┘          │ II RT fpmate │
                                                                           └──────────────┘
```

Files in this folder:

| File | Role |
|---|---|
| `middleware.py` | FastAPI server: CashDro 3-step loop, Epson XML, journal, auth |
| `simulator.py` | Fake CashDro + Epson for testing without hardware |
| `extensions/cashdro-pos/` | Shopify POS UI extension (tile + modal) |
| `.env.example` | All settings, copy to `.env` |
| `requirements.txt` | Python dependencies |

---

## 0. Decide who fiscalizes (do this first)

Shopify POS in Italy can drive an Epson RT on its own when the cashier taps **Cash**.
This middleware can also print the documento commerciale. **Pick one, never both**, or every sale produces two fiscal receipts (and the corrispettivi sent to Agenzia delle Entrate double up).

| Option | `.env` | Shopify POS setting | When to choose |
|---|---|---|---|
| **A — middleware fiscalizes** (as specified) | `EPSON_ENABLED=true` | Remove / disable the fiscal printer on this register | You want the receipt printed the instant the recycler finishes, with the lottery code captured in the modal |
| **B — Shopify fiscalizes** | `EPSON_ENABLED=false` | Keep the Epson RT paired in POS | Simplest and the officially supported Shopify path; the middleware only runs the recycler |

Either way the cashier's last action is the same: **Cash → importo esatto** in Shopify POS. There is no POS extension target that can add a cash tender, so this step cannot be automated (see the cash-recycler plan in the project).

---

## 1. Network

1. Give all three devices **static IPs** (or DHCP reservations) on the shop router, same VLAN:
   - CashDro S `192.168.1.50`, Epson RT `192.168.1.60`, bridge `192.168.1.10`, iPads `.21/.22`.
2. **CashDro S** → its web console → enable the HTTP web service (Cashdro3WS) and note the admin user/password. Ask the dealer to confirm the firmware's CashDro3WS manual version — the `# VERIFY` lines in `middleware.py` reference it.
3. **Epson FP-81 II RT** → confirm Ethernet, open `http://192.168.1.60/` in a browser; `cgi-bin/fpmate.cgi` must answer. Program the departments with the technician who activated the RT:
   - Reparto 1 = IVA 22 % (cosmetics), Reparto 2 = IVA 10 %, Reparto 3 = IVA 4 % (formaggi e latticini).
   Any other rate must be added to `VAT_DEPARTMENTS` or the middleware refuses the sale (by design).
4. **Hostname with a real certificate.** iOS blocks plain `http://` to LAN IPs from the POS app and will not trust a self-signed cert silently. Two working routes:
   - **Recommended:** own a domain (e.g. `fabula.it`), create `pos-bridge.fabula.it → 192.168.1.10` as a public **A record pointing at a private IP** (allowed), and get a Let's Encrypt cert with the DNS-01 challenge (`certbot --manual --preferred-challenges dns` or Caddy with a DNS plugin). Put the cert paths in `.env`.
   - **Fallback:** `mkcert -install && mkcert pos-bridge.fabula.lan`, then install the mkcert **root CA** on each iPad (AirDrop the `rootCA.pem`, Settings → Profile Downloaded → Install, then Settings → General → About → Certificate Trust Settings → enable). Add `pos-bridge.fabula.lan` to the router's local DNS.
5. Firewall on the bridge: allow TCP 8443 **only from the iPads' IPs**; also set `ALLOWED_CLIENT_IPS` in `.env`.

---

## 2. Backend on the Mac mini (or PC)

```bash
# macOS: brew install python@3.12 ; Debian/Ubuntu: apt install python3.12-venv
mkdir -p ~/cashdro && cp -r cashdro-middleware/* ~/cashdro && cd ~/cashdro
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env && nano .env        # fill IPs, credentials, cert paths, Shopify keys
mkdir -p certs /var/lib/cashdro          # (or a user-writable JOURNAL_DB path)
```

Smoke test the hardware links, then run:

```bash
uvicorn middleware:app --host 0.0.0.0 --port 8443 \
  --ssl-certfile certs/pos-bridge.fabula.lan.pem --ssl-keyfile certs/pos-bridge.fabula.lan-key.pem
curl -sk https://pos-bridge.fabula.lan:8443/health | python3 -m json.tool
# expect  "cashdro": {"ok": true}  and  "epson": {"ok": true, "status": "..."}
```

### Run as a service (launchd on macOS)

`~/Library/LaunchAgents/it.fabula.cashdro.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>it.fabula.cashdro</string>
  <key>WorkingDirectory</key><string>/Users/fabula/cashdro</string>
  <key>ProgramArguments</key><array>
    <string>/Users/fabula/cashdro/.venv/bin/python</string>
    <string>middleware.py</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/Users/fabula/cashdro/middleware.log</string>
  <key>StandardErrorPath</key><string>/Users/fabula/cashdro/middleware.log</string>
</dict></plist>
```

```bash
launchctl load -w ~/Library/LaunchAgents/it.fabula.cashdro.plist
launchctl list | grep cashdro
```

(`python middleware.py` reads `PORT`, `SSL_CERTFILE`, `SSL_KEYFILE` from `.env`.)
On Linux use an equivalent `systemd` unit with `Restart=always`. Disable sleep on the Mac mini (`sudo pmset -a sleep 0 disksleep 0`).

### Test with no hardware

```bash
uvicorn simulator:app --port 9000 &
CASHDRO_HOST=127.0.0.1:9000 EPSON_HOST=127.0.0.1:9000 AUTH_MODE=none JOURNAL_DB=/tmp/j.sqlite \
  uvicorn middleware:app --port 8080
curl -X POST localhost:8080/cash/transactions -H 'Content-Type: application/json' -d '{
  "idempotency_key":"demo-00000001",
  "cart":{"grand_total":27.40,"line_items":[
    {"title":"Mozzarella di Bufala DOP 500g","quantity":2,"unit_price":9.50,"tax_lines":[{"rate":0.04}]},
    {"title":"Crema viso 50ml","quantity":1,"unit_price":10.00,"discount_total":1.60,"tax_lines":[{"rate":0.22}]}]}}'
# then poll GET /cash/transactions/<id>; the simulator "inserts" 10 € notes every 1.5 s
```

The simulator prints the exact fiscal XML it receives — hand that to the Epson technician to confirm department numbers and the `printRecMessage`/`printRecLotteryID` syntax on your firmware.

---

## 3. Shopify POS UI extension

Prerequisites: Node 20+, Shopify CLI (`npm i -g @shopify/cli`), a **custom app** on the store (free; Dev Dashboard → Apps → Create app → "custom distribution" for your own store).

```bash
shopify app init --name fabula-pos-bridge --template none   # or reuse your ops app
cd fabula-pos-bridge
cp -r ../cashdro-middleware/extensions/cashdro-pos extensions/
npm i preact
```

1. Edit `extensions/cashdro-pos/src/CheckoutExtension.jsx`: set `MIDDLEWARE_URL` to your bridge hostname (`https://pos-bridge.fabula.it:8443`).
2. Copy the app's **Client ID → `SHOPIFY_API_KEY`** and **Client secret → `SHOPIFY_API_SECRET`** into the bridge's `.env`. POS session tokens are JWTs signed with that secret; the middleware verifies them (`AUTH_MODE=session_token`). This is the real authentication — HMAC is optional hardening.
3. Add the `write_products`-free minimal scopes the app needs (none are required for the extension itself; keep the app's scopes empty or whatever your ops app already uses).
4. Develop: `shopify app dev` → scan the QR on an iPad logged into POS → the tile appears after you add it to the **Smart Grid** (POS → Settings → Smart grid → Add tile → *Paga con CashDro*).
5. Release: `shopify app deploy` → in Admin install the app on the store → re-add the tile on each iPad.

> API note: this code targets the **Preact-based POS UI Extensions (api_version 2025-10)** with the `shopify` global and `s-*` components. If your CLI only offers the older React target (`@shopify/ui-extensions-react/point-of-sale`), the two files port mechanically: `useCartSubscription()` replaces `useCart()`, `useApi()` replaces the `shopify` global, and `<Screen>/<Button>/<Text>` replace `<s-screen>/<s-button>/<s-text>`. The payload builder and the HTTP layer are unchanged.

---

## 4. Daily operation

**Sale**
1. Build the cart in POS → tap **Paga con CashDro** on the Smart Grid.
2. Optional: type the customer's lottery code → **Avvia incasso**.
3. Customer feeds notes/coins into the CashDro; the modal mirrors the state and the recycler dispenses change. With option A the Epson prints the documento commerciale as soon as the cash balances.
4. Tap **Chiudi**, then in POS **Cash → importo esatto**. The order carries `cashdro_tx` and `documento_commerciale` as cart properties.

**Abort** — **Annulla e restituisci contanti** in the modal (or the customer presses cancel on the CashDro screen). The middleware sends `finishOperation` with the cancel type; inserted cash is returned and slots lock. The POS cart is untouched.

**Change short** (`change_short`) — coins ran out: the sale is complete and fiscalized, the modal says how much to hand over by hand (`change_short_cents`) and the cashier must tap "Fatto: ho dato … a mano" before the tile lets them close. Reload the recycler (float-in) and check `GET /cash/journal/<day>` → `change_short_cents`.

**Cash collected but no receipt** (`paid_no_receipt`, v0.93; before it was `error`) — the money is in the machine, so the sale counts as **paid**: the tile shows "PAGATO" and refuses to start a second charge on the same cart. Print the documento commerciale manually from the RT keypad for the same amount, tap "Fatto: scontrino emesso a mano", then close the sale in POS as Cash. The journal row keeps the CashDro operation id, and `GET /cash/journal/<day>` → `receipts_to_issue_by_hand` lists them.

**Machine error with cash inside** (`error` after notes went in) — the tile no longer offers "Riprova": it says to check the machine display first and only then tap "Ho controllato…". Status calls to the CashDro are retried three times before the operation is cancelled and the cash returned.

**Tests** (no hardware): `AUTH_MODE=none python3 test_engine.py` — 12 checks on the payment engine with a fake CashDro and Epson (change short, receipt failure, double-start, retries).

**End of day** — `GET https://pos-bridge…/cash/journal/YYYY-MM-DD` gives `cash_collected_cents`; compare with Shopify POS payment-session `totalCashSales` (the `pos_daily_closings` reconciliation already planned in the ops system). Any gap > €0.50 → look for sales closed in POS as Cash without going through the tile.

---

## 5. Before go-live checklist

- [ ] Dealer confirms CashDro3WS operation names, `type` codes and `state` letters → adjust the `# VERIFY` constants in `CashDroClient`
- [ ] Epson technician confirms departments 1/2/3 ↔ 22/10/4 % and tests one receipt from the simulator XML, then runs a **Z report** on the test receipts (annullo if required)
- [ ] One of option A / B chosen; the other path disabled
- [ ] Bridge reachable from both iPads at `https://…:8443/health` with a green lock
- [ ] `AUTH_MODE=session_token`, real `SHOPIFY_API_SECRET`, `ALLOWED_CLIENT_IPS` set, `.env` chmod 600
- [ ] launchd service survives a reboot; Mac mini sleep disabled; journal path backed up nightly
- [ ] Commercialista informed that the documento commerciale is issued by the RT at the moment of payment (unchanged legally; the recycler is not a fiscal device)
- [ ] Manuale di Autocontrollo updated: counter staff no longer handle cash
