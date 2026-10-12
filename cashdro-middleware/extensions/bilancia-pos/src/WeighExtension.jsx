/**
 * WeighExtension.jsx — "Pesa" modal for Shopify POS (weighed cheese sales)
 * Target: pos.home.modal.render  (opened from Tile.jsx)
 *
 * Flow
 *   1. Load the price-per-kg catalogue from the bridge (GET /scale/products).
 *   2. Cashier taps a product, puts the tub on the scale, taps "Leggi peso".
 *      The bridge returns the STABLE net weight read from the CE-M scale.
 *   3. Price = round(weight_kg × €/kg, 2). "Aggiungi" adds a custom sale
 *      line titled  "Mozzarella DOP — 0,350 kg × 16,80 €/kg"  at that price,
 *      with line properties peso_kg / prezzo_kg / sku so the Epson receipt
 *      prints weight × unit price and the order keeps the SKU.
 *
 * Why a custom sale and not the product variant: Shopify POS has no decimal
 * quantities and no per-line price override, so a variant can't carry
 * 0.350 kg exactly. A custom sale is taxed at the store's BASE rate — set the
 * Italy base rate to 4 % and put 10 %/22 % goods in override collections
 * (see SCALE.md) so weighed cheese is taxed correctly.
 */

import { render } from "preact";
import { useEffect, useState } from "preact/hooks";

const MIDDLEWARE_URL = "https://pos-bridge.fabula.lan:8443"; // same as CheckoutExtension.jsx
const WEIGH_TIMEOUT_S = 6;

const fmtEur = (n) => n.toFixed(2).replace(".", ",") + " €";
const fmtKg = (n) => n.toFixed(3).replace(".", ",") + " kg";

async function api(path) {
  const token = await shopify.sessionToken.get();
  const res = await fetch(`${MIDDLEWARE_URL}${path}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.detail || `HTTP ${res.status}`);
  return data;
}

/** Price to the cent — the figure the customer pays; also printed on the receipt. */
export const priceFor = (weightKg, pricePerKg) => Math.round(weightKg * pricePerKg * 100) / 100;

function Extension() {
  const [products, setProducts] = useState([]);
  const [sel, setSel] = useState(null);
  const [weight, setWeight] = useState(null); // {weight_kg, stable}
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState(null);

  useEffect(() => {
    api("/scale/products").then(setProducts).catch((e) => setErr(e.message));
  }, []);

  async function readWeight() {
    setErr(null); setBusy(true); setWeight(null);
    try {
      setWeight(await api(`/scale/weight?timeout=${WEIGH_TIMEOUT_S}`));
    } catch (e) { setErr(e.message); }
    finally { setBusy(false); }
  }

  async function addToCart() {
    if (!sel || !weight) return;
    setBusy(true); setErr(null);
    const price = priceFor(weight.weight_kg, sel.price_per_kg);
    const title = `${sel.title} — ${fmtKg(weight.weight_kg)} × ${fmtEur(sel.price_per_kg)}/kg`;
    try {
      const before = new Set((shopify.cart.current?.lineItems || []).map((l) => l.uuid));
      await shopify.cart.addCustomSale({ title, price, quantity: 1, taxable: true });
      const after = shopify.cart.current?.lineItems || [];
      const added = after.find((l) => !before.has(l.uuid)) || after[after.length - 1];
      if (added?.uuid) {
        await shopify.cart.addLineItemProperties(added.uuid, {
          peso_kg: weight.weight_kg.toFixed(3),
          prezzo_kg: sel.price_per_kg.toFixed(2),
          sku: sel.sku,
          iva: String(sel.vat_rate),
        });
      }
      shopify.toast.show(`Aggiunto: ${title} = ${fmtEur(price)}`);
      setWeight(null); // ready for the next piece of the same product
    } catch (e) { setErr(`Impossibile aggiungere al carrello: ${e.message}`); }
    finally { setBusy(false); }
  }

  const price = sel && weight ? priceFor(weight.weight_kg, sel.price_per_kg) : null;

  return (
    <s-screen name="bilancia" title="Pesa e aggiungi">
      <s-scroll-box>
        <s-section heading="Prodotto">
          <s-stack direction="block" gap="small">
            {products.length === 0 && <s-text tone="subdued">Nessun prodotto a peso configurato (products_a_peso.json)</s-text>}
            {products.map((p) => (
              <s-button
                key={p.sku}
                variant={sel?.sku === p.sku ? "primary" : "secondary"}
                onClick={() => { setSel(p); setWeight(null); setErr(null); }}
              >
                {p.title} — {fmtEur(p.price_per_kg)}/kg (IVA {p.vat_rate}%)
              </s-button>
            ))}
          </s-stack>
        </s-section>

        {sel && (
          <s-section heading="Peso">
            <s-stack direction="block" gap="base">
              <s-button variant="primary" loading={busy} disabled={busy} onClick={readWeight}>
                Leggi peso dalla bilancia
              </s-button>
              {weight && (
                <s-stack direction="block" gap="small">
                  <s-text type="h1">{fmtKg(weight.weight_kg)}</s-text>
                  <s-text type="h2">{fmtEur(price)}</s-text>
                  <s-text tone="subdued">
                    {fmtKg(weight.weight_kg)} × {fmtEur(sel.price_per_kg)}/kg — peso netto stabile
                  </s-text>
                </s-stack>
              )}
            </s-stack>
          </s-section>
        )}

        {err && (
          <s-section><s-banner tone="critical" heading="Bilancia">{err}</s-banner></s-section>
        )}

        <s-section>
          <s-stack direction="block" gap="base">
            <s-button variant="primary" disabled={!price || busy} onClick={addToCart}>
              {price ? `Aggiungi ${fmtEur(price)} al carrello` : "Aggiungi al carrello"}
            </s-button>
            <s-button variant="secondary" onClick={() => shopify.navigation.dismiss()}>
              Chiudi
            </s-button>
          </s-stack>
        </s-section>
      </s-scroll-box>
    </s-screen>
  );
}

export default async () => {
  render(<Extension />, document.body);
};
