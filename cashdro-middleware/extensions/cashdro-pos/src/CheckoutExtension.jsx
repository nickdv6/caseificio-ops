/**
 * CheckoutExtension.jsx — "Paga con CashDro" modal for Shopify POS
 * Target: pos.home.modal.render  (opened from Tile.jsx on the Smart Grid)
 * Framework: Shopify POS UI Extensions, Preact build (api_version 2025-10+)
 *
 * Flow
 *   1. Read the live cart from the POS Cart API and flatten it into the
 *      middleware payload (unit prices, line + allocated cart discounts,
 *      VAT rate per line, grand total).
 *   2. POST /cash/transactions → middleware starts the CashDro operation.
 *   3. Poll GET /cash/transactions/{id} every second and mirror the
 *      recycler state on screen ("Inserire 27,40 €", "Erogazione resto…").
 *   4. On `completed`: write the transaction id + fiscal receipt number into
 *      the cart properties (audit trail on the Shopify order) and tell the
 *      cashier to close the sale with  Cash → exact amount.
 *   5. "Annulla" → POST .../cancel: the recycler returns inserted cash.
 *
 * Config: MIDDLEWARE_URL below must be an https:// URL that resolves on the
 * shop LAN (see DEPLOYMENT.md — iOS blocks plain http to LAN IPs). AUTH is
 * the Shopify session token by default; HMAC is optional on top.
 */

import { render } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------
const MIDDLEWARE_URL = "https://pos-bridge.fabula.lan:8443"; // see DEPLOYMENT.md
const POLL_MS = 1000;
const REQUEST_TIMEOUT_MS = 8000;
// Optional HMAC on top of the session token. Leave empty to disable.
// NOTE: a secret in a bundled extension is obfuscation, not a secret — the
// session token is the real authentication; HMAC only hardens the LAN hop.
const HMAC_SECRET = "";

// ---------------------------------------------------------------------------
// Cart → middleware payload
// ---------------------------------------------------------------------------

const toNum = (v) => (v == null ? 0 : typeof v === "number" ? v : parseFloat(v) || 0);
const cents = (eur) => Math.round(toNum(eur) * 100);
const eur = (c) => (c / 100).toFixed(2).replace(".", ",") + " €";

/**
 * Flatten the POS cart. Cart-level discounts are allocated to lines pro-rata
 * (largest-remainder on the cents) so that Σ line nets == grandTotal, which
 * the middleware enforces before fiscalizing.
 */
export function buildPayload(cart, ctx) {
  const lines = (cart.lineItems || []).filter((li) => toNum(li.quantity) > 0);
  if (!lines.length) throw new Error("Il carrello è vuoto");

  const gross = lines.map((li) => Math.round(toNum(li.price) * toNum(li.quantity) * 100));
  const lineDisc = lines.map((li) =>
    (li.discounts || []).reduce((s, d) => s + cents(d.amount), 0),
  );
  const grandTotal = cents(cart.grandTotal);
  const netBefore = gross.reduce((s, g, i) => s + g - lineDisc[i], 0);
  let remaining = netBefore - grandTotal; // cart-level discount to spread
  const alloc = new Array(lines.length).fill(0);
  if (remaining > 0) {
    const base = netBefore || 1;
    let spread = 0;
    lines.forEach((_, i) => {
      alloc[i] = Math.floor(((gross[i] - lineDisc[i]) * remaining) / base);
      spread += alloc[i];
    });
    // Largest-remainder: push leftover cents onto the biggest line.
    let leftover = remaining - spread;
    const order = [...alloc.keys()].sort((a, b) => gross[b] - gross[a]);
    for (const i of order) {
      if (leftover <= 0) break;
      alloc[i] += 1;
      leftover -= 1;
    }
  }

  return {
    idempotency_key: ctx.idempotencyKey,
    pos_device_id: ctx.deviceId || null,
    pos_location_id: ctx.locationId || null,
    staff_name: ctx.staffName || null,
    lottery_code: ctx.lotteryCode || null,
    cart: {
      currency: cart.currency || "EUR",
      grand_total: grandTotal / 100,
      subtotal: toNum(cart.subtotal) || null,
      tax_total: toNum(cart.taxTotal) || null,
      note: cart.note || null,
      line_items: lines.map((li, i) => {
        // Weighed lines added by the "Pesa" extension carry peso_kg / prezzo_kg
        // properties; the fiscal receipt then prints weight × €/kg.
        const props = li.properties || {};
        const weighed = props.peso_kg && props.prezzo_kg;
        return {
          uuid: li.uuid || null,
          // Strip the " — 0,350 kg × 16,80 €/kg" suffix: the receipt line shows it itself.
          title: weighed ? (li.title || "").split(" — ")[0] : li.title || li.name || "Articolo",
          sku: li.sku || props.sku || null,
          quantity: toNum(li.quantity),
          unit_price: toNum(li.price),
          discount_total: (lineDisc[i] + alloc[i]) / 100,
          taxable: li.taxable !== false,
          tax_lines: (li.taxLines || []).map((t) => ({
            title: t.title || null,
            rate: toNum(t.rate),
          })),
          weight_kg: weighed ? toNum(props.peso_kg) : null,
          price_per_kg: weighed ? toNum(props.prezzo_kg) : null,
        };
      }),
    },
  };
}

// ---------------------------------------------------------------------------
// HTTP helpers (session token + optional HMAC, timeout, JSON)
// ---------------------------------------------------------------------------

async function hmacHeaders(body) {
  if (!HMAC_SECRET) return {};
  const ts = String(Math.floor(Date.now() / 1000));
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw", enc.encode(HMAC_SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(`${ts}.${body}`));
  const hex = [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
  return { "X-CashDro-Timestamp": ts, "X-CashDro-Signature": hex };
}

async function api(path, { method = "GET", json } = {}) {
  const body = json ? JSON.stringify(json) : "";
  const token = await shopify.sessionToken.get();
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), REQUEST_TIMEOUT_MS);
  try {
    const res = await fetch(`${MIDDLEWARE_URL}${path}`, {
      method,
      signal: ctrl.signal,
      headers: {
        Authorization: `Bearer ${token}`,
        ...(json ? { "Content-Type": "application/json" } : {}),
        ...(await hmacHeaders(body)),
      },
      body: json ? body : undefined,
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.detail || `HTTP ${res.status}`);
    return data;
  } finally {
    clearTimeout(timer);
  }
}

// ---------------------------------------------------------------------------
// Cart subscription (small adapter over the POS Cart API)
// ---------------------------------------------------------------------------

function useCart() {
  const [cart, setCart] = useState(() => shopify.cart.current ?? shopify.cart.value ?? null);
  useEffect(() => {
    const unsub = shopify.cart.subscribe?.((c) => setCart(c));
    return () => (typeof unsub === "function" ? unsub() : undefined);
  }, []);
  return cart;
}

// ---------------------------------------------------------------------------
// UI
// ---------------------------------------------------------------------------

const TERMINAL = new Set(["completed", "cancelled", "timeout", "error", "change_short"]);
const TONE = {
  completed: "success", change_short: "warning", cancelled: "info",
  timeout: "warning", error: "critical",
};

function Extension() {
  const cart = useCart();
  const [tx, setTx] = useState(null);       // last TransactionOut from middleware
  const [phase, setPhase] = useState("idle"); // idle | starting | running | done
  const [err, setErr] = useState(null);
  const [lottery, setLottery] = useState("");
  const idemRef = useRef(null);
  const pollRef = useRef(null);

  const stopPolling = () => { if (pollRef.current) clearInterval(pollRef.current); pollRef.current = null; };
  useEffect(() => stopPolling, []);

  async function start() {
    setErr(null);
    setPhase("starting");
    idemRef.current = idemRef.current || crypto.randomUUID();
    try {
      const payload = buildPayload(cart, {
        idempotencyKey: idemRef.current,
        deviceId: shopify.device?.id,
        locationId: shopify.session?.currentSession?.locationId,
        staffName: shopify.session?.currentSession?.staffMember?.name,
        lotteryCode: lottery.trim().toUpperCase() || null,
      });
      const created = await api("/cash/transactions", { method: "POST", json: payload });
      setTx(created);
      setPhase("running");
      pollRef.current = setInterval(async () => {
        try {
          const t = await api(`/cash/transactions/${created.id}`);
          setTx(t);
          if (TERMINAL.has(t.status)) { stopPolling(); await finish(t); }
        } catch (e) {
          setErr(`Connessione al server persa: ${e.message}`);
        }
      }, POLL_MS);
    } catch (e) {
      setPhase("idle");
      setErr(e.message);
    }
  }

  async function cancel() {
    if (!tx) return;
    try { await api(`/cash/transactions/${tx.id}/cancel`, { method: "POST" }); }
    catch (e) { setErr(e.message); }
  }

  async function finish(t) {
    setPhase("done");
    if (t.status === "completed" || t.status === "change_short") {
      // Audit trail on the Shopify order: who paid where, and the fiscal doc.
      try {
        await shopify.cart.addCartProperties({
          cashdro_tx: t.id,
          cashdro_operation: t.cashdro_operation_id || "",
          documento_commerciale: t.fiscal_receipt_number
            ? `${t.fiscal_receipt_number} del ${t.fiscal_receipt_date}` : "",
        });
      } catch (e) { console.warn("addCartProperties failed", e); }
      shopify.toast.show(
        t.status === "completed"
          ? `CashDro: pagato ${eur(t.amount_due_cents)} — ora Contanti → importo esatto`
          : `Resto incompleto: integrare ${eur(t.change_due_cents - t.change_dispensed_cents)} a mano`,
      );
    } else {
      shopify.toast.show(`CashDro: ${t.message}`);
    }
  }

  function reset() { stopPolling(); setTx(null); setPhase("idle"); setErr(null); idemRef.current = null; }

  const total = cart ? cents(cart.grandTotal) : 0;
  const canStart = phase === "idle" && cart && total > 0;

  return (
    <s-screen name="cashdro" title="Paga con CashDro">
      <s-scroll-box>
        <s-section heading="Totale da incassare">
          <s-stack direction="block" gap="base">
            <s-text type="h1">{eur(total)}</s-text>
            {cart?.lineItems?.map((li) => (
              <s-text key={li.uuid} tone="subdued">
                {toNum(li.quantity)} × {li.title} — {eur(Math.round(toNum(li.price) * toNum(li.quantity) * 100))}
              </s-text>
            ))}
          </s-stack>
        </s-section>

        {phase === "idle" && (
          <s-section heading="Lotteria degli scontrini (facoltativo)">
            <s-text-field
              label="Codice lotteria"
              value={lottery}
              maxLength={8}
              onInput={(e) => setLottery(e.currentTarget.value)}
            />
          </s-section>
        )}

        {tx && (
          <s-section heading="Stato CashDro">
            <s-stack direction="block" gap="base">
              <s-badge tone={TONE[tx.status] || "info"}>{tx.status.toUpperCase()}</s-badge>
              <s-text type="h2">{tx.message}</s-text>
              <s-text>Inseriti: {eur(tx.amount_inserted_cents)}</s-text>
              {tx.change_due_cents > 0 && (
                <s-text>Resto: {eur(tx.change_dispensed_cents)} / {eur(tx.change_due_cents)}</s-text>
              )}
              {tx.fiscal_receipt_number && (
                <s-text tone="success">
                  Documento commerciale n. {tx.fiscal_receipt_number} del {tx.fiscal_receipt_date}
                </s-text>
              )}
              <s-text tone="subdued">Rif. {tx.id}</s-text>
            </s-stack>
          </s-section>
        )}

        {err && (
          <s-section>
            <s-banner tone="critical" heading="Errore">{err}</s-banner>
          </s-section>
        )}

        <s-section>
          <s-stack direction="block" gap="base">
            {phase === "idle" && (
              <s-button variant="primary" disabled={!canStart} onClick={start}>
                Avvia incasso {eur(total)}
              </s-button>
            )}
            {phase === "starting" && <s-button variant="primary" loading disabled>Avvio…</s-button>}
            {phase === "running" && tx?.status !== "fiscalizing" && (
              <s-button variant="secondary" tone="critical" onClick={cancel}>
                Annulla e restituisci contanti
              </s-button>
            )}
            {phase === "done" && (tx?.status === "completed" || tx?.status === "change_short") && (
              <s-button variant="primary" onClick={() => shopify.navigation.dismiss()}>
                Chiudi — poi Contanti → importo esatto
              </s-button>
            )}
            {phase === "done" && !(tx?.status === "completed" || tx?.status === "change_short") && (
              <s-button variant="primary" onClick={reset}>Riprova</s-button>
            )}
          </s-stack>
        </s-section>
      </s-scroll-box>
    </s-screen>
  );
}

export default async () => {
  render(<Extension />, document.body);
};
