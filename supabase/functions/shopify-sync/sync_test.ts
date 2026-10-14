// deno test supabase/functions/shopify-sync/sync_test.ts — v1.02 (audit E-18): the Shopify jobs against a fake Shopify and database
import { type Db, fulfilShipments, mapOrder, syncCustomers, syncInventory, syncOrders } from "./sync.ts";
import type { Gql, GqlResult } from "./shopify.ts";

function eq(a: unknown, b: unknown, what = "") { const x = JSON.stringify(a), y = JSON.stringify(b); if (x !== y) throw new Error(`${what} expected ${y}\n     got ${x}`); }
function ok(c: unknown, what: string) { if (!c) throw new Error("not true: " + what); }

type Call = { query: string; variables: Record<string, any> };
// a fake Shopify: each handler gets (query, variables) and returns data/errors, or null to pass to the next one
function fakeShopify(handlers: ((q: string, v: any) => Partial<GqlResult> | null)[]) {
  const calls: Call[] = [];
  const q: Gql = async (query, variables = {}) => {
    calls.push({ query, variables });
    for (const h of handlers) { const r = h(query, variables); if (r) return { data: r.data ?? null, errors: r.errors ?? [] }; }
    throw new Error("unexpected query: " + query.slice(0, 80));
  };
  return { q, calls };
}
function fakeDb(rows: Record<string, any[]> = {}, rpcs: Record<string, (a: any) => any> = {}) {
  const calls: { fn: string; args: any }[] = [];
  const db: Db = {
    rpc: async (fn, args) => {
      calls.push({ fn, args });
      try { return { data: rpcs[fn] ? rpcs[fn](args) : { ok: true }, error: null }; } catch (e) { return { data: null, error: { message: (e as Error).message } }; }
    },
    rows: async (v) => rows[v] ?? [],
  };
  return { db, calls };
}
const money = (a: string) => ({ shopMoney: { amount: a } });
const order = (id: number, o: Record<string, any> = {}) => ({
  id: `gid://shopify/Order/${id}`, name: `#${id}`, createdAt: "2026-10-13T22:30:00Z", updatedAt: "2026-10-13T22:31:00Z", cancelledAt: null,
  displayFinancialStatus: "PAID", displayFulfillmentStatus: "UNFULFILLED", sourceName: "web", tags: ["a", "b"], paymentGatewayNames: ["shopify_payments"],
  subtotalPriceSet: money("10.00"), totalTaxSet: money("0.40"), totalPriceSet: money("10.40"), customer: { id: "gid://shopify/Customer/1", displayName: "Anna" },
  email: "a@example.com", phone: null, purchasingEntity: null, shippingAddress: { name: "Anna", address1: "Via 1", city: "Agropoli", zip: "84043", countryCodeV2: "IT" },
  lineItems: { pageInfo: { hasNextPage: false, endCursor: null }, nodes: [{ title: "Mozzarella", variantTitle: "250 g", quantity: 2, sku: "M250", product: { productType: "Mozzarella" },
    variant: { id: "gid://shopify/ProductVariant/9" }, customAttributes: [], originalUnitPriceSet: money("5.00"), taxLines: [{ ratePercentage: 4 }] }] },
  ...o,
});
const NOW = new Date("2026-10-14T05:11:00Z");

Deno.test("mapOrder: a weighed counter sale keeps sku and weight; a B2B order carries the company", () => {
  const m = mapOrder(order(1, { sourceName: "pos", purchasingEntity: { __typename: "PurchasingCompany", company: { name: "Pizzeria X" } },
    lineItems: { pageInfo: { hasNextPage: false }, nodes: [{ title: "Vendita libera", quantity: 1, variant: null, customAttributes: [{ key: "sku", value: "MOZ-DOP-KG" }, { key: "peso_kg", value: "0.62" }],
      originalUnitPriceSet: money("9.30"), taxLines: [] }] } }));
  eq(m.line_items[0].variant_id, null, "variant");
  eq(m.line_items[0].properties, { sku: "MOZ-DOP-KG", peso_kg: "0.62" }, "properties");
  eq(m.line_items[0].tax_rate, 4, "default VAT");
  eq(m.company, "Pizzeria X", "company");
  eq(m.tags, "a, b", "tags joined like the old bot");
  eq(m.total, "10.40", "amount kept as Shopify's text");
  eq(m.shipping_address?.city, "Agropoli", "address");
});

Deno.test("orders: reads every page, checks Shopify's count, sends count + total, POS days in Rome time", async () => {
  const p1 = [order(1, { sourceName: "pos" }), order(2)], p2 = [order(3, { totalPriceSet: money("5.10") })];
  const { q, calls } = fakeShopify([
    (s) => s.includes("ordersCount") ? { data: { ordersCount: { count: 3, precision: "EXACT" } } } : null,
    (s, v) => s.includes("orders(first") ? { data: { orders: v.after ? { pageInfo: { hasNextPage: false }, nodes: p2 } : { pageInfo: { hasNextPage: true, endCursor: "c1" }, nodes: p1 } } } : null,
  ]);
  const { db, calls: dc } = fakeDb({}, { upsert_shopify_orders: (a) => ({ received: a.p_rows.length, created: 3 }) });
  const r: any = await syncOrders(q, db, { days: 3, now: NOW, scopes: new Set(["read_orders"]) });
  eq(r.ok, true);
  const up = dc.find((c) => c.fn === "upsert_shopify_orders")!;
  eq(up.args.p_rows.length, 3, "rows");
  eq(up.args.p_expected, { count: 3, total: 25.9 }, "expected count and total");
  eq(r.pos_days, ["2026-10-14"], "22:30 UTC is the 14th in Rome");
  ok(calls[0].variables.q.includes("updated_at:>='2026-10-11T05:11:00Z'") && calls[0].variables.q.includes("updated_at:<='2026-10-14T05:10:00Z'"), "fixed window: " + calls[0].variables.q);
  ok(calls.every((c) => !c.query.includes("orders(") || c.query.includes("sortKey: ID")), "stable order while paging");
  eq(r.fulfil, { pending: 0, done: 0, failed: [] }, "no shipments");
});

Deno.test("orders: an order with more lines than one page gets all its lines", async () => {
  const big = order(7, { lineItems: { pageInfo: { hasNextPage: true, endCursor: "L1" }, nodes: [order(1).lineItems.nodes[0]] } });
  const { q } = fakeShopify([
    (s) => s.includes("ordersCount") ? { data: { ordersCount: { count: 1, precision: "EXACT" } } } : null,
    (s) => s.includes("orders(first") ? { data: { orders: { pageInfo: { hasNextPage: false }, nodes: [big] } } } : null,
    (s, v) => s.includes("order(id") && v.after === "L1" ? { data: { order: { lineItems: { pageInfo: { hasNextPage: false }, nodes: [order(1).lineItems.nodes[0], order(1).lineItems.nodes[0]] } } } } : null,
  ]);
  const { db, calls } = fakeDb();
  await syncOrders(q, db, { days: 3, now: NOW, scopes: new Set() });
  eq(calls[0].args.p_rows[0].line_items.length, 3, "1 + 2 lines");
});

Deno.test("orders: without access to customer addresses it goes on and says so", async () => {
  const { q, calls } = fakeShopify([
    (s) => s.includes("ordersCount") ? { data: { ordersCount: { count: 1, precision: "EXACT" } } } : null,
    (s) => s.includes("shippingAddress") ? { data: null, errors: [{ message: "Access denied for shippingAddress field. Required access: protected customer data" }] } : null,
    (s) => s.includes("orders(first") ? { data: { orders: { pageInfo: { hasNextPage: false }, nodes: [order(1, { email: undefined, shippingAddress: undefined })] } } } : null,
  ]);
  const { db } = fakeDb();
  const r: any = await syncOrders(q, db, { days: 3, now: NOW, scopes: new Set() });
  eq(r.limited, ["email", "phone", "customer_name", "shipping_address"]);
  ok(calls.some((c) => c.query.includes("orders(first") && !c.query.includes("shippingAddress")), "second read without the protected fields");
});

Deno.test("orders: a query too expensive for Shopify is retried with smaller pages", async () => {
  const { q, calls } = fakeShopify([
    (s) => s.includes("ordersCount") ? { data: { ordersCount: { count: 1, precision: "EXACT" } } } : null,
    (s) => s.includes("orders(first: 10") ? { data: null, errors: [{ message: "Query cost is 1302, which exceeds the single query max cost limit (1000)." }] } : null,
    (s) => s.includes("orders(first: 5") ? { data: { orders: { pageInfo: { hasNextPage: false }, nodes: [order(1)] } } } : null,
  ]);
  const { db } = fakeDb();
  const r: any = await syncOrders(q, db, { days: 3, now: NOW, scopes: new Set() });
  eq(r.ok, true); ok(calls.some((c) => c.query.includes("orders(first: 5")), "page halved");
});

Deno.test("orders: a list that keeps disagreeing with Shopify's count is refused by the database (nothing written)", async () => {
  const { q, calls } = fakeShopify([
    (s) => s.includes("ordersCount") ? { data: { ordersCount: { count: 4, precision: "EXACT" } } } : null,
    (s) => s.includes("orders(first") ? { data: { orders: { pageInfo: { hasNextPage: false }, nodes: [order(1), order(2), order(3)] } } } : null,
  ]);
  const { db } = fakeDb({}, { upsert_shopify_orders: (a) => { if (a.p_rows.length !== a.p_expected.count) throw new Error("Shopify ha 4 ordini nel periodo ma ne sono arrivati 3: nessuna modifica"); return {}; } });
  let err = "";
  try { await syncOrders(q, db, { days: 3, now: NOW, scopes: new Set() }); } catch (e) { err = (e as Error).message; }
  ok(err.includes("nessuna modifica"), err);
  eq(calls.filter((c) => c.query.includes("ordersCount")).length, 2, "read twice before giving up");
});

Deno.test("shipments: without the permission nothing is sent and the orders are listed", async () => {
  const { q, calls } = fakeShopify([]);
  const { db } = fakeDb({ v_shipments_to_fulfill: [{ shipment_id: "s1", shopify_order_id: "gid://shopify/Order/5", order_number: "#1005" }] });
  const r: any = await fulfilShipments(q, db, new Set(["read_orders"]));
  eq(r, { pending: 1, done: 0, failed: [], blocked: "scope", orders: "#1005" });
  eq(calls.length, 0);
});

Deno.test("shipments: confirmed with the tracking, already done by hand, refused, cancelled", async () => {
  const ship = [{ shipment_id: "s1", shopify_order_id: "5", order_number: "#1005", carrier: "BRT", tracking_number: "T1" },
                { shipment_id: "s2", shopify_order_id: "gid://shopify/Order/6", order_number: "#1006" },
                { shipment_id: "s3", shopify_order_id: "gid://shopify/Order/7", order_number: "#1007" },
                { shipment_id: "s4", shopify_order_id: "gid://shopify/Order/8", order_number: "#1008" }];
  const { q, calls } = fakeShopify([
    (s, v) => s.includes("fulfillmentOrders") ? { data: { order: v.id.endsWith("/6") ? { id: v.id, displayFulfillmentStatus: "FULFILLED", fulfillmentOrders: { nodes: [{ id: "FO6", status: "CLOSED" }] } }
                                                                                       : v.id.endsWith("/8") ? { id: v.id, cancelledAt: "2026-10-13T10:00:00Z", displayFulfillmentStatus: "UNFULFILLED", fulfillmentOrders: { nodes: [{ id: "FO8", status: "OPEN" }] } }
                                                                                       : { id: v.id, displayFulfillmentStatus: "UNFULFILLED", fulfillmentOrders: { nodes: [{ id: "FO" + v.id.slice(-1), status: "OPEN" }] } } } } : null,
    (s, v) => s.includes("fulfillmentCreate") ? { data: { fulfillmentCreate: v.f.lineItemsByFulfillmentOrder[0].fulfillmentOrderId === "FO7"
      ? { fulfillment: null, userErrors: [{ message: "Fulfillment order is on hold" }] } : { fulfillment: { id: "gid://shopify/Fulfillment/1" }, userErrors: [] } } } : null,
  ]);
  const { db, calls: dc } = fakeDb({ v_shipments_to_fulfill: ship });
  const r: any = await fulfilShipments(q, db, new Set(["write_merchant_managed_fulfillment_orders"]));
  eq([r.done, r.already, r.failed], [1, 1, [{ order: "#1007", error: "Fulfillment order is on hold" }, { order: "#1008", error: "ordine annullato su Shopify: non spedirlo" }]]);
  ok(!calls.some((c) => c.query.includes("fulfillmentCreate") && c.variables.f.lineItemsByFulfillmentOrder[0].fulfillmentOrderId === "FO8"), "a cancelled order is never fulfilled");
  const fc = calls.find((c) => c.query.includes("fulfillmentCreate"))!;
  eq(fc.variables.f.trackingInfo, { company: "BRT", number: "T1" }, "tracking");
  eq(fc.variables.f.notifyCustomer, true);
  ok(calls[0].variables.id === "gid://shopify/Order/5", "a bare id becomes a gid");
  eq(dc.filter((c) => c.fn === "mark_shopify_fulfilled").map((c) => [c.args.p_shipment_id, c.args.p_fulfillment_gid]), [["s1", "gid://shopify/Fulfillment/1"], ["s2", null]]);
});

Deno.test("customers: every page, Shopify's count passed as the expected number; a mismatch is read again", async () => {
  let countCalls = 0;
  const cust = (i: number) => ({ id: `gid://shopify/Customer/${i}`, firstName: "A", lastName: "B", displayName: "A B", defaultEmailAddress: { emailAddress: `c${i}@x.it` },
                                 defaultPhoneNumber: null, tags: ["ingrosso"], numberOfOrders: "3", amountSpent: { amount: "12.5" }, defaultAddress: { company: null, city: "Agropoli" } });
  const { q } = fakeShopify([
    (s) => s.includes("customersCount") ? { data: { customersCount: { count: ++countCalls === 1 ? 4 : 3, precision: "EXACT" } } } : null,
    (s, v) => s.includes("customers(first") ? { data: { customers: v.after ? { pageInfo: { hasNextPage: false }, nodes: [cust(3)] } : { pageInfo: { hasNextPage: true, endCursor: "x" }, nodes: [cust(1), cust(2)] } } } : null,
  ]);
  const { db, calls } = fakeDb({}, { upsert_shopify_customers: (a) => ({ received: a.p_rows.length }) });
  const r: any = await syncCustomers(q, db);
  eq(countCalls, 2, "read again after 4 ≠ 3");
  eq(calls[0].args.p_expected, 3);
  eq(calls[0].args.p_rows[0], { id: "gid://shopify/Customer/1", first_name: "A", last_name: "B", name: "A B", email: "c1@x.it", phone: null, tags: ["ingrosso"],
                                company: null, city: "Agropoli", orders_count: 3, total_spent: "12.5" });
  eq(r.shopify, { count: 3 });
});

const PLAN = (push: number, rows: any[]) => ({ push, setting: 2, counted: push === 1, rows });
const ROW = (id: string, units: number, o: Record<string, any> = {}) => ({ variant_id: `gid://shopify/ProductVariant/${id}`, label: "Mozzarella · " + id, sku: "MOZ-DOP-KG", available_kg: 12.5,
                                                                      kg_per_unit: 0.25, available_units: units, allocated_kg: units * 0.25, split_basis: "vendite", ...o });
function invShopify(nodes: any[]) {
  return fakeShopify([
    (s) => s.includes("nodes(ids") ? { data: { nodes, locations: { nodes: [{ id: "gid://shopify/Location/1", name: "Caseificio", isActive: true }] } } } : null,
    (s) => s.includes("inventorySetQuantities") ? { data: { inventorySetQuantities: { inventoryAdjustmentGroup: { createdAt: "x" }, userErrors: [] } } } : null,
  ]);
}
const NODE = (id: string, qty: number, o: Record<string, any> = {}) => ({ id: `gid://shopify/ProductVariant/${id}`, inventoryQuantity: qty, inventoryPolicy: "DENY", inventoryItem: { id: "I" + id, tracked: true }, ...o });

Deno.test("stock: a missing permission changes nothing and says which", async () => {
  const { q, calls } = invShopify([]);
  const { db } = fakeDb({}, { shopify_inventory_plan: () => PLAN(1, [ROW("1", 4)]) });
  const r: any = await syncInventory(q, db, new Set(["read_products", "read_inventory"]), "k");
  eq([r.blocked, r.missing], ["scope", "read_locations, write_inventory"]);
  eq(calls.length, 0);
});

Deno.test("stock: compare only while the push is off; lists untracked, selling at zero, gone", async () => {
  const { q, calls } = invShopify([NODE("1", 100), NODE("2", 0, { inventoryItem: { id: "I2", tracked: false } }), NODE("3", 5, { inventoryPolicy: "CONTINUE" })]);
  const { db } = fakeDb({}, { shopify_inventory_plan: () => PLAN(0, [ROW("1", 0), ROW("2", 0), ROW("3", 0), ROW("4", 0)]) });
  const r: any = await syncInventory(q, db, new Set(["read_inventory", "read_locations"]), "k");
  ok(!calls.some((c) => c.query.includes("inventorySetQuantities")), "no write");
  eq([r.untracked, r.selling_at_zero, r.not_found], [["Mozzarella · 2"], ["Mozzarella · 3"], ["Mozzarella · 4"]]);
  eq(r.available_kg, 12.5, "one pool per product, not one per variant");
  eq(r.variants[0].shopify_qty, 100);
});

Deno.test("stock: when switched on, sets only what differs, with an idempotency key and no compare", async () => {
  const { q, calls } = invShopify([NODE("1", 3), NODE("2", 7)]);
  const { db } = fakeDb({}, { shopify_inventory_plan: () => PLAN(1, [ROW("1", 3), ROW("2", 4)]) });
  const r: any = await syncInventory(q, db, new Set(["write_inventory", "read_locations"]), "run-123");
  const m = calls.find((c) => c.query.includes("inventorySetQuantities"))!;
  ok(m.query.includes("@idempotent(key: $key)"), "idempotent");
  eq(m.variables.key, "run-123");
  eq(m.variables.input.quantities, [{ inventoryItemId: "I2", locationId: "gid://shopify/Location/1", quantity: 4, changeFromQuantity: null }]);
  eq([r.set_count, r.errors], [1, []]);
});
