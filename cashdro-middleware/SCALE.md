# Scale integration — weighed cheese on Shopify POS

## The constraint that drives the design

Shopify POS cannot sell `0.350 kg` of a product: line quantities are integers and there is no per-line price override. Shopify has no native scale support and no variable-weight (prefix 2x) barcode decoding. So a weighed sale has to enter the cart as a **custom sale** whose price is `round(weight × €/kg, 2)` and whose title and properties carry the weight — that is what the **Pesa** tile does.

The side effect: a custom sale is taxed at the store's **base rate**, not a product rate. Fix it in Shopify Admin → Settings → Taxes → Italy:

| | Setting |
|---|---|
| Base rate for Italy | **4 %** (formaggi e latticini, Tabella A parte II) |
| Collection override "IVA 22" | 22 % — cosmetics, non-food |
| Collection override "IVA 10" | 10 % — if you ever stock it |

With that, weighed cheese (custom sale) is taxed at 4 %, every other product gets its collection rate, and the middleware's department mapping (`4→3, 10→2, 22→1`) stays consistent with what POS charged. Sell cosmetics only as catalogue products, never as custom sales.

Reporting: weighed lines are not linked to a variant, so Shopify's "sales by product" won't see them. Each line carries `sku`, `peso_kg`, `prezzo_kg`, `iva` properties; a nightly Admin API query on line-item properties gives kg sold per SKU (this plugs straight into the ops console's sales module). Stock for bulk cheese is production-batch driven anyway, not Shopify inventory.

## Legal metrology (metrologia legale) — what the scale must be

- **CE-M approved** non-automatic weighing instrument, accuracy class III, **approved for direct sale to the public** (Direttiva 2014/31/UE / D.Lgs. 22/2007), with a **customer-facing display**. Ordinary "bilancia da banco" without the CE-M marking is not legal for selling by weight.
- **Verificazione periodica every 3 years** by an accredited organismo (DM 93/2017), and the **comunicazione d'inizio utilizzo** to the Camera di Commercio within 30 days of putting it in service. Keep the libretto metrologico at the counter.
- **Scale → POS link:** the instrument measures and shows the weight; the POS only transports and prices it. Our bridge accepts only readings the scale flags *stable*, never edits them, and the receipt prints `peso netto × €/kg = totale`. Ask the organismo/dealer to confirm this "bilancia collegata a cassa" configuration passes verification with your model — it is a standard setup in Italian delis, but confirm before buying.
- **Tare:** done on the scale (T key) with the tub/paper, so the transmitted weight is net. Keep a tare table for the standard tubs.
- **Price display:** the customer must see the weight on the scale display; the iPad shows weight, €/kg and price before the line is added.

### Scale shortlist (ask for Italian dealer quotes; prices est.)

| Model family | Interface | Note |
|---|---|---|
| **Dibal G-300 / G-310** series | Ethernet + RS-232, customer display, CE-M | Designed for "connessione a cassa"; Ethernet matches the RT and CashDro on the same LAN. Likely first choice. |
| Helmac GPE / GP series | RS-232/USB, CE-M | Italian maker, cheaper, serial only (USB-serial adapter to the Mac mini). |
| Dini Argeo / Baxtran counter scales | RS-232 or Ethernet, CE-M | Known A&D-style frame `ST,GS,+ 0.350 kg` (matches the default regex). |

Alternative worth a quote: a **label-printing scale** (Dibal/DIGI) that prints a variable-weight EAN-13 with the price; the price computing then happens entirely inside the approved instrument. The POS side would need a scanner-subscription extension that decodes the barcode into the same custom sale. Fall back to this only if the organismo objects to the direct link.

## Wiring and config

1. Scale on the LAN (Ethernet) at `192.168.1.70`, or USB/RS-232 into the Mac mini.
2. `.env`:
   ```
   SCALE_ENABLED=true
   SCALE_TRANSPORT=tcp             # or serial
   SCALE_PORT=192.168.1.70:4001    # or /dev/tty.usbserial-XXXX
   SCALE_BAUD=9600
   SCALE_MODE=poll                 # scale answers a request; stream if it broadcasts
   SCALE_REQUEST_CMD=W\r\n         # from the protocol sheet
   SCALE_REGEX=(?P<status>ST|US|OL)?[^\d+\-]*(?P<sign>[+-])?\s*(?P<value>\d+(?:[.,]\d+)?)\s*(?P<unit>kg|g)?
   SCALE_PRODUCTS_FILE=products_a_peso.json
   ```
3. `products_a_peso.json`: SKU, title, €/kg, IVA. Keep €/kg identical to the shelf price card (obbligo di prezzo al kg).
4. `curl -sk https://pos-bridge…:8443/scale/health` → `ok: true` and a parsed weight.
5. Deploy `extensions/bilancia-pos` with the same `shopify app deploy`, add the **Pesa** tile to the Smart Grid.

## Counter flow

1. Tare the tub on the scale → place the mozzarella.
2. iPad: **Pesa** → tap the product → **Leggi peso** → `0,350 kg · 5,88 €` → **Aggiungi**.
3. Repeat per item; then **Paga con CashDro** (or card). The documento commerciale shows `Mozzarella di Bufala Campana DOP  0,350 × 16,80  5,88` on reparto 3 (IVA 4 %).

## Test without a scale

`simulator.py` opens a fake scale on TCP 9001 (`SIM_SCALE_KG=0.350`), sends two unstable frames then a stable one:

```bash
uvicorn simulator:app --port 9000 &
SCALE_ENABLED=true SCALE_TRANSPORT=tcp SCALE_PORT=127.0.0.1:9001 \
CASHDRO_HOST=127.0.0.1:9000 EPSON_HOST=127.0.0.1:9000 AUTH_MODE=none uvicorn middleware:app --port 8080
curl "localhost:8080/scale/weight?timeout=5"
```
