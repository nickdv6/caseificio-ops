// The three Shopify jobs of shopify-sync (v1.02, audit E-18), written against two small interfaces so the tests can run them
// with a fake Shopify and a fake database: `Gql` (shopify.ts) and `Db` below. Every job returns a plain result object; the
// database turns it into the run record and the message (fabula.shopify_sync_finish). Nothing here decides what to tell people.
import type { Gql, GqlError } from "./shopify.ts";

// write_x implies read_x in Shopify
export const has = (s: Set<string>, scope: string) => s.has(scope) || (scope.startsWith("read_") && s.has("write_" + scope.slice(5)));

export type Db = {
  rpc: (fn: string, args?: Record<string, unknown>) => Promise<{ data: any; error: { message: string; code?: string } | null }>;
  rows: (view: string) => Promise<any[]>;
};
export type Result = Record<string, unknown> & { ok: boolean };

const errText = (e: GqlError[]) => e.map((x) => x.message).join("; ");
const accessDenied = (e: GqlError[]) => e.length > 0 && e.every((x) => /access denied|required access|not approved/i.test(x.message));
const costTooHigh = (e: GqlError[]) => e.some((x) => /max(imum)? cost|MAX_COST_EXCEEDED|query cost/i.test(x.message + " " + (x.extensions?.code ?? "")));
async function must(db: Db, fn: string, args?: Record<string, unknown>) {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data;
}
const gid = (kind: string, id: string) => (String(id).startsWith("gid://") ? String(id) : `gid://shopify/${kind}/${id}`);
const cents = (x: unknown) => Math.round(parseFloat(String(x ?? "0")) * 100);

// ---------------------------------------------------------------------------------------------------------------------------
// Orders: the same JSON the «Ordini Shopify» bot used to build by hand, plus the address fields the packing slip reads
// ---------------------------------------------------------------------------------------------------------------------------
const LINE = `title variantTitle quantity sku product { productType } variant { id } customAttributes { key value }
  originalUnitPriceSet { shopMoney { amount } } taxLines { ratePercentage }`;
const RICH = `email phone customer { id displayName } purchasingEntity { __typename ... on PurchasingCompany { company { name } } }
  shippingAddress { name address1 address2 city zip province countryCodeV2 phone }`;
const BASIC = `customer { id } purchasingEntity { __typename ... on PurchasingCompany { company { name } } }`;
const ORDER = (extra: string, lines: number) => `id name createdAt updatedAt cancelledAt displayFinancialStatus displayFulfillmentStatus sourceName tags
  paymentGatewayNames subtotalPriceSet { shopMoney { amount } } totalTaxSet { shopMoney { amount } } totalPriceSet { shopMoney { amount } } ${extra}
  lineItems(first: ${lines}) { pageInfo { hasNextPage endCursor } nodes { ${LINE} } }`;

export function mapOrder(n: any) {
  const sa = n.shippingAddress ?? null;
  return {
    id: n.id, name: n.name, source_name: n.sourceName ?? null,
    financial_status: n.displayFinancialStatus ?? null, fulfillment_status: n.displayFulfillmentStatus ?? null,
    cancelled_at: n.cancelledAt ?? null, created_at: n.createdAt, updated_at: n.updatedAt,
    subtotal: n.subtotalPriceSet?.shopMoney?.amount ?? "0", tax: n.totalTaxSet?.shopMoney?.amount ?? "0", total: n.totalPriceSet?.shopMoney?.amount ?? "0",
    customer_id: n.customer?.id ?? null, customer_name: n.customer?.displayName ?? null,
    tags: (n.tags ?? []).join(", "), email: n.email ?? null, phone: n.phone ?? null,
    company: n.purchasingEntity?.__typename === "PurchasingCompany" ? (n.purchasingEntity.company?.name ?? null) : null,
    ship_city: sa?.city ?? null,
    shipping_address: sa ? { name: sa.name ?? null, address1: sa.address1 ?? null, address2: sa.address2 ?? null, city: sa.city ?? null, zip: sa.zip ?? null,
                             province: sa.province ?? null, country: sa.countryCodeV2 ?? null, phone: sa.phone ?? null } : null,
    payment_gateways: n.paymentGatewayNames ?? [],
    line_items: (n.lineItems?.nodes ?? []).map((l: any) => ({
      variant_id: l.variant?.id ?? null,
      properties: Object.fromEntries((l.customAttributes ?? []).map((a: any) => [a.key, a.value])),
      title: l.title, variant_title: l.variantTitle ?? null, sku: l.sku ?? null, product_type: l.product?.productType ?? null,
      quantity: l.quantity, price: l.originalUnitPriceSet?.shopMoney?.amount ?? "0",
      tax_rate: l.taxLines?.[0]?.ratePercentage ?? 4,
    })),
  };
}

async function fetchOrders(q: Gql, filter: string) {
  let extra = RICH, limited: string[] = [], page = 10, mismatches = 0;
  for (let attempt = 0; attempt < 8; attempt++) {
    const c = await q(`query($q: String!) { ordersCount(query: $q, limit: null) { count precision } }`, { q: filter });
    if (c.errors.length) throw new Error(errText(c.errors));
    const count = Number(c.data.ordersCount.count);
    if (c.data.ordersCount.precision !== "EXACT") throw new Error(`Shopify non dà il numero esatto degli ordini (${count}+)`);
    const nodes: any[] = []; let after: string | null = null, restart = false;
    do {
      const r = await q(`query($q: String!, $after: String) { orders(first: ${page}, after: $after, sortKey: ID, query: $q) { pageInfo { hasNextPage endCursor } nodes { ${ORDER(extra, 30)} } } }`, { q: filter, after });
      if (r.errors.length) {
        if (costTooHigh(r.errors) && page > 2) { page = Math.max(2, Math.floor(page / 2)); restart = true; break; }
        // a field this app may not read (customer addresses and phones are «protected customer data»): go on without it
        if (extra === RICH && accessDenied(r.errors)) { extra = BASIC; limited = ["email", "phone", "customer_name", "shipping_address"]; restart = true; break; }
        throw new Error(errText(r.errors));
      }
      nodes.push(...r.data.orders.nodes);
      after = r.data.orders.pageInfo.hasNextPage ? r.data.orders.pageInfo.endCursor : null;
    } while (after);
    if (restart) continue;
    // an order with more than 30 lines: read the rest of its lines
    for (const n of nodes) {
      let more = n.lineItems.pageInfo.hasNextPage ? n.lineItems.pageInfo.endCursor : null;
      while (more) {
        const r = await q(`query($id: ID!, $after: String) { order(id: $id) { lineItems(first: 50, after: $after) { pageInfo { hasNextPage endCursor } nodes { ${LINE} } } } }`, { id: n.id, after: more });
        if (r.errors.length) throw new Error(errText(r.errors));
        n.lineItems.nodes.push(...r.data.order.lineItems.nodes);
        more = r.data.order.lineItems.pageInfo.hasNextPage ? r.data.order.lineItems.pageInfo.endCursor : null;
      }
    }
    if (nodes.length !== count && mismatches++ === 0) continue;   // an order moved while reading: read once more (then the database refuses)
    return { count, nodes, limited };
  }
  throw new Error("Shopify: lettura degli ordini non riuscita");
}

export async function syncOrders(q: Gql, db: Db, opt: { days: number; now: Date; scopes: Set<string> }): Promise<Result> {
  const days = Math.max(1, Math.min(30, Math.round(opt.days || 3)));
  // a fixed window for the count and the list: an order changed while reading is left to the next run, both sides agree
  const until = new Date(opt.now.getTime() - 60_000).toISOString().replace(/\.\d+Z$/, "Z");
  const since = new Date(opt.now.getTime() - days * 86_400_000).toISOString().replace(/\.\d+Z$/, "Z");
  const filter = `updated_at:>='${since}' AND updated_at:<='${until}'`;
  const { count, nodes, limited } = await fetchOrders(q, filter);
  const rows = nodes.map(mapOrder);
  const total = rows.reduce((s, r) => s + cents(r.total), 0) / 100;
  // the database checks the count, repeats and the total again, and writes nothing if they do not agree
  const upsert = await must(db, "upsert_shopify_orders", { p_rows: rows, p_expected: { count, total } });
  const posDays = [...new Set(rows.filter((r) => String(r.source_name ?? "").toLowerCase() === "pos" && !r.cancelled_at)
    .map((r) => new Date(r.created_at).toLocaleDateString("sv-SE", { timeZone: "Europe/Rome" })))].sort();
  const fulfil = await fulfilShipments(q, db, opt.scopes);
  return {
    ok: true, window: { since, until, days },
    shopify: { count, pos: rows.filter((r) => String(r.source_name ?? "").toLowerCase() === "pos").length },
    upsert, pos_days: posDays, fulfil, limited,
  };
}

// packed shipments of web orders: confirmed («evaso») on Shopify with the tracking, then marked in the database
export async function fulfilShipments(q: Gql, db: Db, sc: Set<string>) {
  const ship = await db.rows("v_shipments_to_fulfill");
  if (!ship.length) return { pending: 0, done: 0, failed: [] };
  const names = ship.map((s) => s.order_number).join(", ");
  if (!has(sc, "write_merchant_managed_fulfillment_orders")) return { pending: ship.length, done: 0, failed: [], blocked: "scope", orders: names };
  let done = 0, already = 0; const failed: { order: string; error: string }[] = [];
  for (const s of ship) {
    try {
      const o = await q(`query($id: ID!) { order(id: $id) { id cancelledAt displayFulfillmentStatus fulfillmentOrders(first: 10) { nodes { id status } } } }`, { id: gid("Order", s.shopify_order_id) });
      if (o.errors.length) throw new Error(errText(o.errors));
      if (!o.data.order) throw new Error("ordine non trovato su Shopify");
      if (o.data.order.cancelledAt) throw new Error("ordine annullato su Shopify: non spedirlo");
      const open = (o.data.order.fulfillmentOrders?.nodes ?? []).filter((f: any) => ["OPEN", "IN_PROGRESS"].includes(f.status));
      if (!open.length) {
        if (o.data.order.displayFulfillmentStatus === "FULFILLED") { await must(db, "mark_shopify_fulfilled", { p_shipment_id: s.shipment_id, p_fulfillment_gid: null }); already++; continue; }
        throw new Error("nessuna parte dell'ordine da evadere su Shopify");
      }
      let last: string | null = null;
      for (const fo of open) {   // one fulfillment per fulfillment order (they may sit at different locations)
        const tracking: Record<string, string> = {};
        if (s.carrier) tracking.company = s.carrier;
        if (s.tracking_number) tracking.number = s.tracking_number;
        const m = await q(`mutation($f: FulfillmentInput!) { fulfillmentCreate(fulfillment: $f) { fulfillment { id status } userErrors { field message } } }`,
          { f: { lineItemsByFulfillmentOrder: [{ fulfillmentOrderId: fo.id }], notifyCustomer: true, ...(Object.keys(tracking).length ? { trackingInfo: tracking } : {}) } });
        if (m.errors.length) throw new Error(errText(m.errors));
        const ue = m.data.fulfillmentCreate.userErrors ?? [];
        if (ue.length) throw new Error(ue.map((e: any) => e.message).join("; "));
        last = m.data.fulfillmentCreate.fulfillment?.id ?? last;
      }
      await must(db, "mark_shopify_fulfilled", { p_shipment_id: s.shipment_id, p_fulfillment_gid: last });
      done++;
    } catch (e) { failed.push({ order: s.order_number, error: (e as Error).message }); }
  }
  return { pending: ship.length, done, already, failed };
}

// ---------------------------------------------------------------------------------------------------------------------------
// Customers: the whole list, checked against Shopify's own count (a short list must never deactivate anyone)
// ---------------------------------------------------------------------------------------------------------------------------
export function mapCustomer(n: any) {
  return {
    id: n.id, first_name: n.firstName ?? null, last_name: n.lastName ?? null, name: n.displayName ?? null,
    email: n.defaultEmailAddress?.emailAddress ?? null, phone: n.defaultPhoneNumber?.phoneNumber ?? null,
    tags: n.tags ?? [], company: n.defaultAddress?.company ?? null, city: n.defaultAddress?.city ?? null,
    orders_count: parseInt(String(n.numberOfOrders ?? "0"), 10) || 0, total_spent: n.amountSpent?.amount ?? "0",
  };
}

export async function syncCustomers(q: Gql, db: Db): Promise<Result> {
  for (let attempt = 0; attempt < 2; attempt++) {
    const c = await q(`query { customersCount(limit: null) { count precision } }`);
    if (c.errors.length) throw new Error(errText(c.errors));
    if (c.data.customersCount.precision !== "EXACT") throw new Error("Shopify non dà il numero esatto dei clienti");
    const count = Number(c.data.customersCount.count);
    const nodes: any[] = []; let after: string | null = null;
    do {
      const r = await q(`query($after: String) { customers(first: 100, after: $after, sortKey: ID) { pageInfo { hasNextPage endCursor } nodes {
        id firstName lastName displayName defaultEmailAddress { emailAddress } defaultPhoneNumber { phoneNumber } tags numberOfOrders
        amountSpent { amount } defaultAddress { company city } } } }`, { after });
      if (r.errors.length) throw new Error(errText(r.errors));
      nodes.push(...r.data.customers.nodes);
      after = r.data.customers.pageInfo.hasNextPage ? r.data.customers.pageInfo.endCursor : null;
    } while (after);
    if (nodes.length !== count && attempt === 0) continue;   // a customer added while reading: read once more
    const upsert = await must(db, "upsert_shopify_customers", { p_rows: nodes.map(mapCustomer), p_expected: count });
    return { ok: true, shopify: { count }, upsert };
  }
  throw new Error("Shopify: lettura dei clienti non riuscita");
}

// ---------------------------------------------------------------------------------------------------------------------------
// Stock: compare (and, when switched on, set) the sellable units of each linked variant
// ---------------------------------------------------------------------------------------------------------------------------
export async function syncInventory(q: Gql, db: Db, sc: Set<string>, key: string): Promise<Result> {
  const plan = await must(db, "shopify_inventory_plan");
  const push = Number(plan.push) === 1;
  const base = { push: push ? 1 : 0, setting: Number(plan.setting), counted: !!plan.counted };
  const need = ["read_inventory", "read_locations", ...(push ? ["write_inventory"] : [])].filter((s) => !has(sc, s));
  if (need.length) return { ok: true, ...base, blocked: "scope", missing: need.join(", ") };
  const rows: any[] = plan.rows ?? [];
  const pool = new Map<string, number>(); rows.forEach((r) => pool.set(r.sku ?? r.variant_id, Number(r.available_kg) || 0));
  const available_kg = Math.round([...pool.values()].reduce((s, x) => s + x, 0) * 1000) / 1000;
  if (!rows.length) return { ok: true, ...base, available_kg, variants: [], set_count: 0, untracked: [], selling_at_zero: [], not_found: [], errors: [] };
  const r = await q(`query($ids: [ID!]!) { nodes(ids: $ids) { ... on ProductVariant { id inventoryQuantity inventoryPolicy inventoryItem { id tracked } } }
    locations(first: 10) { nodes { id name isActive } } }`, { ids: rows.map((x) => gid("ProductVariant", x.variant_id)) });
  if (r.errors.length) throw new Error(errText(r.errors));
  const loc = (r.data.locations?.nodes ?? []).find((l: any) => l.isActive) ?? null;
  const byId = new Map<string, any>((r.data.nodes ?? []).filter(Boolean).map((n: any) => [n.id, n]));
  const variants = rows.map((x) => {
    const n = byId.get(gid("ProductVariant", x.variant_id));
    return { variant_id: x.variant_id, label: x.label, available_units: Number(x.available_units) || 0, available_kg: Number(x.allocated_kg ?? x.available_kg) || 0,
             split_basis: x.split_basis ?? null, found: !!n, shopify_qty: n ? n.inventoryQuantity : null, tracked: n ? !!n.inventoryItem?.tracked : null,
             policy: n ? n.inventoryPolicy : null, item: n?.inventoryItem?.id ?? null, set: false };
  });
  const errors: string[] = [];
  let set_count = 0;
  const toSet = variants.filter((v) => v.found && v.tracked && v.item && v.shopify_qty !== v.available_units);
  if (push && toSet.length) {
    if (!loc) errors.push("nessuna sede attiva su Shopify");
    else {
      const m = await q(`mutation($input: InventorySetQuantitiesInput!, $key: String!) { inventorySetQuantities(input: $input) @idempotent(key: $key) {
        inventoryAdjustmentGroup { createdAt } userErrors { field message code } } }`, {
        key, input: { name: "available", reason: "correction", referenceDocumentUri: "gid://caseificio-ops/StockSync/" + key,
                      quantities: toSet.map((v) => ({ inventoryItemId: v.item, locationId: loc.id, quantity: v.available_units, changeFromQuantity: null })) } });
      if (m.errors.length) errors.push(errText(m.errors));
      else if ((m.data.inventorySetQuantities.userErrors ?? []).length) errors.push(...m.data.inventorySetQuantities.userErrors.map((e: any) => e.message));
      else { toSet.forEach((v) => { v.set = true; }); set_count = toSet.length; }
    }
  }
  return {
    ok: true, ...base, available_kg, location: loc?.name ?? null,
    variants: variants.map(({ item: _i, ...v }) => v),
    set_count, errors,
    untracked: variants.filter((v) => v.found && v.tracked === false).map((v) => v.label),
    selling_at_zero: variants.filter((v) => v.found && v.policy === "CONTINUE").map((v) => v.label),
    not_found: variants.filter((v) => !v.found).map((v) => v.label),
  };
}
