// v0.99 (audit B-22/B-23): what «Invia a Shopify» sends, computed from Ingrosso (products, tiers, basis) and from what the
// Shopify price list holds now. Pure (no network), so it is tested on its own: prices_test.ts.
// Shopify's rules (quantityPricingByVariantUpdate user errors): a quantity rule's minimum is a multiple of its increment; a
// price break is at or above the minimum and a multiple of the increment; one break per variant and quantity.
export const money = (n: number) => Number(n).toFixed(2);
export type Current = { prices: Map<string, { price: string; breaks: { id: string; min: number; price: string }[] }>; rules: Map<string, { min: number; inc: number }> };
// deno-lint-ignore no-explicit-any
export function planFrom(prods: any[], tiers: any[], basis: string, cur: Current) {
  const name = (p: any) => `${p.title}${p.variant_title ? " " + p.variant_title : ""}`;
  const changes: Record<string, unknown>[] = [];
  const pricesToAdd: Record<string, unknown>[] = [], rulesToAdd: Record<string, unknown>[] = [], breaksToAdd: Record<string, unknown>[] = [];
  const pricesToDelete: string[] = [], rulesToDelete: string[] = [], breaksToDelete: string[] = [];
  const sent: Record<string, { price: number | null; min: number | null; step: number | null; active: boolean }> = {};
  for (const p of prods) {
    const now = cur.prices.get(p.variant_id), rule = cur.rules.get(p.variant_id);
    const wanted = p.active && p.trade_price_eur != null && Number(p.trade_price_eur) > 0;
    if (!wanted) {                                    // out of the list: its breaks, its fixed price and its rule go
      if (now) { pricesToDelete.push(p.variant_id); now.breaks.forEach((b) => breaksToDelete.push(b.id)); changes.push({ variant_id: p.variant_id, name: name(p), what: "tolto dal listino", now: now.price, new: null }); }
      if (rule) rulesToDelete.push(p.variant_id);
      sent[p.variant_id] = { price: null, min: p.min_qty, step: p.step_qty, active: !!p.active };
      continue;
    }
    sent[p.variant_id] = { price: Number(p.trade_price_eur), min: p.min_qty, step: p.step_qty, active: true };
    const price = money(p.trade_price_eur);
    if (!now || now.price !== price) {
      pricesToAdd.push({ variantId: p.variant_id, price: { amount: price, currencyCode: "EUR" } });
      changes.push({ variant_id: p.variant_id, name: name(p), what: "prezzo €", now: now ? now.price : null, new: price });
    }
    const inc = Math.max(1, Math.round(Number(p.step_qty) || 1));
    const min = Math.max(inc, Math.ceil(Math.max(1, Math.round(Number(p.min_qty) || 1)) / inc) * inc);   // Shopify: a multiple of the increment
    if (!rule || rule.min !== min || rule.inc !== inc) {
      if (rule) rulesToDelete.push(p.variant_id);                           // deleted first, then added: no «already exists»
      rulesToAdd.push({ variantId: p.variant_id, minimum: min, increment: inc });
      changes.push({ variant_id: p.variant_id, name: name(p), what: "minimo / passo", now: rule ? `${rule.min} / ${rule.inc}` : null, new: `${min} / ${inc}` });
    }
    // native price breaks only when tiers are per delivery (Shopify computes them per order line)
    const byMin = new Map<number, string>();
    if (basis === "delivery") {
      for (const t of tiers) {
        if (!t.active || (t.variant_id && t.variant_id !== p.variant_id)) continue;
        const pr = t.price_eur != null ? Number(t.price_eur) : Number(p.trade_price_eur) * (1 - Number(t.discount_pct) / 100);
        if (!(pr > 0)) continue;
        const units = Math.max(min, Math.ceil(Number(t.min_qty) / Number(p.kg_per_unit || 1) / inc) * inc);
        const m = money(pr); if (!byMin.has(units) || Number(m) < Number(byMin.get(units))) byMin.set(units, m);   // one break per quantity: the cheapest
      }
    }
    const want = [...byMin.entries()].map(([m, pr]) => ({ min: m, price: pr }));
    const key = (l: { min: number; price: string }[]) => l.map((b) => `${b.min}@${b.price}`).sort().join(",");
    const have = now ? now.breaks : [];
    if (key(have) !== key(want)) {
      have.forEach((b) => breaksToDelete.push(b.id));
      want.forEach((b) => breaksToAdd.push({ variantId: p.variant_id, minimumQuantity: b.min, price: { amount: b.price, currencyCode: "EUR" } }));
      changes.push({ variant_id: p.variant_id, name: name(p), what: "scaglioni", now: have.map((b) => `da ${b.min}: ${b.price}`).join(" · ") || null, new: want.map((b) => `da ${b.min}: ${b.price}`).join(" · ") || null });
    }
  }
  return { changes, pricesToAdd, rulesToAdd, breaksToAdd, pricesToDelete, rulesToDelete, breaksToDelete, sent };
}
