// deno test supabase/functions/trade-portal/prices_test.ts — v0.99 (audit B-22/B-23): what «Invia a Shopify» would send
import { planFrom, type Current } from "./prices.ts";
// no network in the test container: a plain deep-equal
function assertEquals(a: unknown, b: unknown) { const x = JSON.stringify(a), y = JSON.stringify(b); if (x !== y) throw new Error(`expected ${y}\n     got ${x}`); }

const P = (o: Record<string, unknown> = {}) => ({ variant_id: "V1", title: "Mozzarella", variant_title: "1 kg", kg_per_unit: 1, trade_price_eur: 11.5, min_qty: 3, step_qty: 1, active: true, ...o });
const T = (o: Record<string, unknown> = {}) => ({ id: "t1", variant_id: null, min_qty: 10, price_eur: 10.5, discount_pct: null, active: true, ...o });
const cur = (prices: [string, string, [string, number, string][]][] = [], rules: [string, number, number][] = []): Current => ({
  prices: new Map(prices.map(([v, p, b]) => [v, { price: p, breaks: b.map(([id, min, price]) => ({ id, min, price })) }])),
  rules: new Map(rules.map(([v, min, inc]) => [v, { min, inc }])),
});

Deno.test("nothing to send when Shopify already has it", () => {
  const r = planFrom([P()], [T()], "delivery", cur([["V1", "11.50", [["b1", 10, "10.50"]]]], [["V1", 3, 1]]));
  assertEquals(r.changes.length, 0);
  assertEquals([r.pricesToAdd.length, r.rulesToAdd.length, r.breaksToAdd.length, r.breaksToDelete.length], [0, 0, 0, 0]);
});

Deno.test("a switched-off tier is removed from Shopify (B-23)", () => {
  const r = planFrom([P()], [T({ active: false })], "delivery", cur([["V1", "11.50", [["b1", 10, "10.50"]]]], [["V1", 3, 1]]));
  assertEquals(r.breaksToDelete, ["b1"]);
  assertEquals(r.breaksToAdd, []);
});

Deno.test("two tiers on the same quantity become one break, the cheapest; a 0 € tier is never sent", () => {
  // 5-kg boxes, minimum 1 box: tiers from 8 kg and from 10 kg both mean «from 2 boxes» (Shopify refuses two breaks at 2)
  const r = planFrom([P({ kg_per_unit: 5, min_qty: 1, step_qty: 1 })], [T({ id: "a", min_qty: 10, price_eur: 10.5 }), T({ id: "b", min_qty: 8, price_eur: 10.2 }), T({ id: "c", min_qty: 20, price_eur: 0 })], "delivery", cur());
  assertEquals(r.breaksToAdd.map((b: any) => [b.minimumQuantity, b.price.amount]), [[2, "10.20"]]);
});

Deno.test("with a step, breaks land on multiples of it", () => {
  const r = planFrom([P({ step_qty: 5, min_qty: 5 })], [T({ id: "a", min_qty: 10, price_eur: 10.5 }), T({ id: "b", min_qty: 12, price_eur: 10.2 })], "delivery", cur());
  assertEquals(r.breaksToAdd.map((b: any) => [b.minimumQuantity, b.price.amount]), [[10, "10.50"], [15, "10.20"]]);
});

Deno.test("a break below the minimum moves up to the minimum; the minimum becomes a multiple of the step", () => {
  const r = planFrom([P({ min_qty: 7, step_qty: 5 })], [T({ min_qty: 2 })], "delivery", cur());
  assertEquals(r.rulesToAdd, [{ variantId: "V1", minimum: 10, increment: 5 }]);
  assertEquals(r.breaksToAdd.map((b: any) => b.minimumQuantity), [10]);
});

Deno.test("a changed rule is deleted then added (no «already exists»)", () => {
  const r = planFrom([P({ min_qty: 5 })], [], "delivery", cur([["V1", "11.50", []]], [["V1", 3, 1]]));
  assertEquals(r.rulesToDelete, ["V1"]);
  assertEquals(r.rulesToAdd, [{ variantId: "V1", minimum: 5, increment: 1 }]);
  assertEquals(r.pricesToAdd, []);                       // the price did not change: not resent
});

Deno.test("a product taken out of the list loses price, breaks and rule; what was sent is recorded", () => {
  const r = planFrom([P({ active: false })], [T()], "delivery", cur([["V1", "11.50", [["b1", 10, "10.50"]]]], [["V1", 3, 1]]));
  assertEquals([r.pricesToDelete, r.breaksToDelete, r.rulesToDelete], [["V1"], ["b1"], ["V1"]]);
  assertEquals(r.sent.V1, { price: null, min: 3, step: 1, active: false });
});

Deno.test("basis «week»: no native breaks on Shopify (the old ones go)", () => {
  const r = planFrom([P()], [T()], "week", cur([["V1", "11.50", [["b1", 10, "10.50"]]]], [["V1", 3, 1]]));
  assertEquals([r.breaksToDelete, r.breaksToAdd], [["b1"], []]);
});

Deno.test("a discount tier is priced from the reserved price", () => {
  const r = planFrom([P({ trade_price_eur: 12 })], [T({ price_eur: null, discount_pct: 10, min_qty: 20 })], "delivery", cur());
  assertEquals(r.breaksToAdd.map((b: any) => b.price.amount), ["10.80"]);
  assertEquals(r.pricesToAdd.length, 1);
});
