// trade-portal — "Per i professionisti" (v0.83, 06/10/2026). Shopify ids are kept as GIDs, like the customer sync does.
//
// One function behind the Shopify trade pages and the Ingrosso console tab. Deploy with verify_jwt = false: the
// storefront has no Supabase login; every path does its own check.
//
//   GET  ?action=state&t=<token>                       → fabula.trade_portal_state(token): the customer's plan, prices, upcoming deliveries
//   POST ?action=portal   { t, action, payload }       → fabula.trade_portal_action(...) (save_schedule, add_exception, cancel_exception, set_status, save_details)
//   POST ?action=apply    { business_name, ... }       → fabula.trade_apply(...): public application form (honeypot field "website" must be empty)
//   POST ?action=approve  { application_id, note }     → staff (Supabase JWT, Vendite ≥ 3 enforced by the database): fabula.trade_approve, then the
//                                                        Shopify company / location / contact (Net terms) + customer tag "ingrosso" + metafield trade.portal_token
//   POST ?action=reject   { application_id, note }     → staff: fabula.trade_reject
//   POST ?action=link     { party_id }                 → staff: (re)create the Shopify link for an already-approved customer
//   POST ?action=sync-prices                           → staff: push trade_products prices + delivery-basis tiers to the Shopify B2B price list
//                                                        (v0.99: a full replace against what the list holds: products out of the list and tiers
//                                                        switched off are removed too)
//   POST ?action=prices-preview                        → staff: the changes sync-prices would make (product, Shopify now → new), nothing written
//   POST ?action=run-queue                             → header x-trade-secret = setting trade.job_secret (pg_cron) or staff JWT: every pending
//                                                        booked delivery becomes a Shopify B2B draft order for the company location, completed on
//                                                        net terms (paymentPending). Result written back with fabula.trade_queue_result.
//   GET  ?action=status                                → staff or x-trade-secret: are the Shopify credentials working, which scopes
//
// Shopify Admin API credentials — Dev Dashboard app "Caseificio ops" (scopes read/write customers, companies, draft_orders, orders,
// products, markets, publications, payment_terms). Dev Dashboard apps have no permanent token: the function mints one with the
// client-credentials grant from the secrets SHOPIFY_CLIENT_ID + SHOPIFY_CLIENT_SECRET (valid 24 h, cached and renewed by itself).
// A legacy static token still works through SHOPIFY_ADMIN_TOKEN. SHOPIFY_SHOP = pxssjd-cq.myshopify.com. Without any of them the
// database side still works and the answers say what is left to do by hand ("shopify": "not_configured").

import { createClient } from "npm:@supabase/supabase-js@2";
import { money, planFrom } from "./prices.ts";
import { createOnce } from "./queue.ts";

const SHOP = Deno.env.get("SHOPIFY_SHOP") ?? "pxssjd-cq.myshopify.com";
const STATIC_TOKEN = Deno.env.get("SHOPIFY_ADMIN_TOKEN") ?? "";
const CLIENT_ID = Deno.env.get("SHOPIFY_CLIENT_ID") ?? "";
const CLIENT_SECRET = Deno.env.get("SHOPIFY_CLIENT_SECRET") ?? "";
const API = "2026-07";
const CONFIGURED = !!(STATIC_TOKEN || (CLIENT_ID && CLIENT_SECRET));

// access token: static one if given, else client-credentials grant (Dev Dashboard app), cached until 5 minutes before it expires
let tokenCache: { token: string; exp: number } | null = null;
async function accessToken(force = false): Promise<string> {
  if (STATIC_TOKEN) return STATIC_TOKEN;
  if (!CLIENT_ID || !CLIENT_SECRET) throw new Error("not_configured");
  if (!force && tokenCache && tokenCache.exp > Date.now()) return tokenCache.token;
  const r = await fetch(`https://${SHOP}/admin/oauth/access_token`, {
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "client_credentials", client_id: CLIENT_ID, client_secret: CLIENT_SECRET }),
  });
  if (!r.ok) throw new Error(`Shopify token: ${r.status} ${(await r.text()).slice(0, 200)}`);
  const j = await r.json() as { access_token: string; expires_in?: number };
  tokenCache = { token: j.access_token, exp: Date.now() + Math.max(60, (j.expires_in ?? 86400) - 300) * 1000 };
  return tokenCache.token;
}
const TAG = "ingrosso";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-trade-secret",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" } });
const TOK = /^[0-9a-f]{16,64}$/i;
const admin = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } }).schema("fabula");
const asUser = (req: Request) => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
  auth: { persistSession: false }, global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
}).schema("fabula");
const dbErr = (e: { code?: string; message?: string }) => json({ error: e.code === "22023" || e.code === "42501" || e.code === "P0001" ? e.message : "errore del server", code: e.code }, e.code === "42501" ? 403 : e.code === "22023" || e.code === "P0001" ? 400 : 500);

// ---------- Shopify Admin GraphQL ----------
function same(a: string, b: string) {             // v1.10: constant time for keys of the same length (as shopify-sync)
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  if (!x.length || x.length !== y.length) return false;
  let d = 0;
  for (let i = 0; i < x.length; i++) d |= x[i] ^ y[i];
  return d === 0;
}

async function gql(query: string, variables: Record<string, unknown> = {}) {
  if (!CONFIGURED) throw new Error("not_configured");
  for (let i = 0; i < 3; i++) {
    const r = await fetch(`https://${SHOP}/admin/api/${API}/graphql.json`, {
      method: "POST", headers: { "Content-Type": "application/json", "X-Shopify-Access-Token": await accessToken(i > 0) }, body: JSON.stringify({ query, variables }),
    });
    if (r.status === 429) { await new Promise((res) => setTimeout(res, 1500)); continue; }
    if (r.status === 401 && i === 0) continue;   // token expired or revoked: mint a new one once
    const b = await r.json();
    if (b.errors?.length) {
      const msg = b.errors.map((e: { message: string }) => e.message).join("; ");
      if (i === 0 && !STATIC_TOKEN && /access denied|not approved to access|must have access/i.test(msg)) { tokenCache = null; continue; }   // scopes changed since the token was minted
      throw new Error(msg);
    }
    // same thing reported as a userError (e.g. "The user must have access to set payment terms"): re-mint once, scopes may have grown
    if (i === 0 && !STATIC_TOKEN && /must have access|access denied/i.test(JSON.stringify(b.data ?? {}))) { tokenCache = null; continue; }
    return b.data;
  }
  throw new Error("Shopify: troppe richieste");
}
const userErr = (o: { userErrors?: { message: string; field?: string[] }[] }) => (o?.userErrors ?? []).map((e) => `${(e.field ?? []).join(".")} ${e.message}`.trim()).join("; ");
const splitName = (n: string) => { const p = String(n ?? "").trim().split(/\s+/); return { first: p.shift() ?? "Cliente", last: p.join(" ") || "-" }; };
const e164 = (p?: string | null) => { if (!p) return null; let d = p.replace(/[^\d+]/g, ""); if (d.startsWith("00")) d = "+" + d.slice(2); if (!d.startsWith("+")) d = "+39" + d.replace(/^0+(?=3)/, ""); return /^\+\d{8,15}$/.test(d) ? d : null; };

async function termsTemplate(days: number | null) {
  const d = await gql(`{ paymentTermsTemplates { id name paymentTermsType dueInDays } }`);
  const t = (d.paymentTermsTemplates as { id: string; paymentTermsType: string; dueInDays: number | null }[]);
  return (days && t.find((x) => x.paymentTermsType === "NET" && x.dueInDays === days)) ?? t.find((x) => x.paymentTermsType === "NET" && x.dueInDays === 30) ?? t.find((x) => x.paymentTermsType === "NET") ?? null;
}

// the Shopify company for an application / party: existing company of the customer with that e-mail, else a new one
async function ensureCompany(app: Record<string, string | null>, termsDays: number | null) {
  // v1.10 (review M1): the e-mail goes into the search without quotes of its own, and the customer found must have exactly that e-mail
  const email = String(app.email ?? "").trim().toLowerCase().replace(/["\\\s]/g, "");
  const q = await gql(`query($q: String!) { customers(first: 5, query: $q) { nodes { id defaultEmailAddress { emailAddress } companyContactProfiles { id company { id name locations(first: 1) { nodes { id } } } } } } }`, { q: `email:"${email}"` });
  // deno-lint-ignore no-explicit-any
  const cust = (q.customers.nodes as any[]).find((c) => String(c.defaultEmailAddress?.emailAddress ?? "").toLowerCase() === email);
  const prof = cust?.companyContactProfiles?.[0];
  if (prof?.company?.id) {
    return { companyId: prof.company.id, locationId: prof.company.locations.nodes[0]?.id ?? null, contactId: prof.id, customerId: cust.id, existed: true };
  }
  const tmpl = await termsTemplate(termsDays);
  const nm = splitName(app.contact_name ?? "");
  const d = await gql(`mutation($input: CompanyCreateInput!) { companyCreate(input: $input) { company { id mainContact { id customer { id } } locations(first: 1) { nodes { id } } } userErrors { field message } } }`, {
    input: {
      company: { name: app.business_name, externalId: app.party_id ?? undefined, note: `Richiesta dal sito il ${(app.created_at ?? "").slice(0, 10)} · ${app.business_type ?? ""}` },
      companyContact: { email: app.email, firstName: nm.first, lastName: nm.last, phone: e164(app.phone), locale: "it" },
      companyLocation: {
        name: `${app.business_name} · ${app.city ?? "sede"}`, locale: "it", phone: e164(app.phone) ?? undefined, taxRegistrationId: app.piva ? `IT${app.piva.replace(/^IT/i, "")}` : undefined,
        billingSameAsShipping: true,
        shippingAddress: { address1: app.address ?? "-", city: app.city ?? "Agropoli", zip: app.postcode ?? undefined, zoneCode: app.province ?? "SA", countryCode: "IT", recipient: app.business_name, phone: e164(app.phone) ?? undefined },
        buyerExperienceConfiguration: { paymentTermsTemplateId: tmpl ? tmpl.id : undefined, checkoutToDraft: false, editableShippingAddress: false },
      },
    },
  });
  const ue = userErr(d.companyCreate); if (ue) throw new Error("Shopify companyCreate: " + ue);
  const c = d.companyCreate.company;
  return { companyId: c.id, locationId: c.locations.nodes[0]?.id ?? null, contactId: c.mainContact?.id ?? null, customerId: c.mainContact?.customer?.id ?? null, existed: false };
}

async function markCustomer(customerId: string, token: string) {
  const d = await gql(`mutation($id: ID!, $tags: [String!]!, $mf: [MetafieldsSetInput!]!) {
    tagsAdd(id: $id, tags: $tags) { userErrors { message } }
    metafieldsSet(metafields: $mf) { userErrors { field message } } }`, {
    id: customerId, tags: [TAG], mf: [{ ownerId: customerId, namespace: "trade", key: "portal_token", type: "single_line_text_field", value: token }],
  });
  const ue = userErr(d.metafieldsSet) || userErr(d.tagsAdd); if (ue) throw new Error("Shopify customer: " + ue);
}

// ---------- queue → Shopify B2B orders ----------
async function createOrder(row: Record<string, any>) {
  const c = row.customer, p = row.payload;
  if (!c.shopify_company_id || !c.shopify_location_id) throw new Error("cliente senza azienda Shopify collegata");
  const tmpl = await termsTemplate(c.terms);
  const lineItems = (p.lines as Record<string, any>[]).map((l) => ({
    variantId: l.variant_id, quantity: Math.round(Number(l.qty)),
    ...(Number(l.discount_pct) > 0 ? { appliedDiscount: { valueType: "PERCENTAGE", value: Number(l.discount_pct), title: l.recurring ? "Sconto piano consegne" : "Sconto quantità" } } : {}),
  }));
  const dateIt = String(row.delivery_date).split("-").reverse().join("/");
  const input: Record<string, unknown> = {
    purchasingEntity: { purchasingCompany: { companyId: c.shopify_company_id, companyLocationId: c.shopify_location_id, ...(c.shopify_contact_id ? { companyContactId: c.shopify_contact_id } : {}) } },
    lineItems,
    note: `Consegna ${dateIt}${p.window ? " ore " + p.window : ""}${p.address ? " · " + p.address : ""}${p.instructions ? " · " + p.instructions : ""} · ordine ${p.order_number}`,
    tags: [TAG, "piano-consegne", `consegna-${row.delivery_date}`],
    customAttributes: [
      { key: "Data consegna", value: dateIt }, { key: "Fascia oraria", value: p.window ?? "" }, { key: "Ordine interno", value: p.order_number },
      ...(p.instructions ? [{ key: "Istruzioni", value: String(p.instructions).slice(0, 250) }] : []),
    ],
    shippingLine: { title: "Consegna diretta", price: "0.00" },
    // net terms need an issue date: the delivery day (Shopify computes the due date from the template)
    ...(tmpl ? { paymentTerms: { paymentTermsTemplateId: tmpl.id, paymentSchedules: [{ issuedAt: `${row.delivery_date}T06:00:00Z` }] } } : {}),
    ...(p.po_number ? { poNumber: String(p.po_number) } : {}),
  };
  return await createOnce(gql, String(row.id), input);   // v1.10: once per queue row (queue.ts)
}

async function runQueue() {
  const db = admin();
  // v1.10: the rows are claimed for this run (another run, or «Invia ora» pressed meanwhile, does not get them)
  const { data, error } = await db.rpc("trade_queue_claim");
  if (error) throw error;
  const rows = (data ?? []) as Record<string, any>[];
  const out: Record<string, unknown>[] = [];
  for (const row of rows) {
    try {
      const r = await createOrder(row);
      const { error: re } = await db.rpc("trade_queue_result", { p_id: row.id, p_ok: true, p_draft: r.draftId, p_order: r.orderId, p_name: r.name, p_error: null });
      // v1.10: not recorded → the row stays claimed and the next run finds the order by its tag instead of creating another
      if (re) { console.error("trade_queue_result", row.id, re.message); out.push({ id: row.id, ok: true, order: r.name, recorded: false }); continue; }
      out.push({ id: row.id, ok: true, order: r.name, ...(r.existed ? { existed: true } : {}) });
    } catch (e) {
      const msg = (e as Error).message ?? String(e);
      if (msg === "not_configured") return { configured: false, pending: rows.length };
      await db.rpc("trade_queue_result", { p_id: row.id, p_ok: false, p_draft: null, p_order: null, p_name: null, p_error: msg });
      out.push({ id: row.id, ok: false, error: msg });
    }
  }
  return { configured: true, processed: out.length, results: out };
}

// ---------- prices → Shopify price list ----------
// v0.99 (audit B-22/B-23): the push is computed against what the price list holds now (read from Shopify), shown first
// («prices-preview»: product, Shopify now → new) and then sent: a product taken out of the list or without a reserved price
// loses its fixed price and its quantity rule; price breaks are replaced, so a tier switched off (or the basis moved to «week»)
// disappears from Shopify instead of staying there. What is sent respects Shopify's own rules (minimum a multiple of the
// increment, a break at or above the minimum and a multiple of the increment, one break per quantity: the cheapest).
async function readPriceList(priceListId: string) {
  const prices = new Map<string, { price: string; breaks: { id: string; min: number; price: string }[] }>();
  let after: string | null = null;
  for (let page = 0; page < 20; page++) {
    const d = await gql(`query($id: ID!, $after: String) { priceList(id: $id) { prices(first: 100, after: $after, originType: FIXED) { pageInfo { hasNextPage endCursor } nodes { variant { id } price { amount } quantityPriceBreaks(first: 20) { nodes { id minimumQuantity price { amount } } } } } } }`, { id: priceListId, after });
    const c = d.priceList?.prices; if (!c) throw new Error("listino Shopify non trovato (trade.shopify_price_list_id)");
    for (const n of c.nodes) prices.set(n.variant.id, { price: money(n.price.amount), breaks: (n.quantityPriceBreaks?.nodes ?? []).map((b: any) => ({ id: b.id, min: Number(b.minimumQuantity), price: money(b.price.amount) })) });
    if (!c.pageInfo.hasNextPage) break; after = c.pageInfo.endCursor;
  }
  const rules = new Map<string, { min: number; inc: number }>();
  const r = await gql(`query($id: ID!) { priceList(id: $id) { quantityRules(first: 100) { nodes { minimum increment productVariant { id } } } } }`, { id: priceListId });
  for (const n of r.priceList?.quantityRules?.nodes ?? []) rules.set(n.productVariant.id, { min: Number(n.minimum), inc: Number(n.increment) });
  return { prices, rules };
}
async function planPrices() {
  const db = admin(), readAt = new Date().toISOString();
  const [{ data: prods, error: e1 }, { data: tiers, error: e2 }, { data: sett }, { data: plRow }] = await Promise.all([
    db.from("trade_products").select("*").order("sort"), db.from("trade_price_tiers").select("*"), db.rpc("trade_settings"),
    db.from("settings").select("value").eq("key", "trade.shopify_price_list_id").maybeSingle(),
  ]);
  if (e1) throw e1; if (e2) throw e2;
  const s = (sett ?? {}) as Record<string, any>;
  const priceListId = plRow?.value; if (!priceListId) throw new Error("manca trade.shopify_price_list_id");
  const cur = await readPriceList(priceListId);
  const plan = planFrom(prods as any[], tiers as any[], s.tier_basis, cur);
  return { priceListId, basis: s.tier_basis, readAt, ...plan, tierIds: (tiers as any[]).map((t) => t.id) };
}
async function syncPrices() {
  const db = admin(), P = await planPrices(), at = new Date().toISOString();
  // what was sent becomes «inviato» (a change made during the push stays «da inviare»): products, then the tiers read for this push
  const markSent = async (all: boolean) => {
    for (const [v, x] of Object.entries(P.sent)) {
      await db.from("trade_products").update(all ? { synced_at: at, synced_price_eur: x.price, synced_min_qty: x.min, synced_step_qty: x.step, synced_active: x.active }
                                               : { synced_price_eur: x.price }).eq("variant_id", v);
    }
    if (all && P.tierIds.length) await db.from("trade_price_tiers").update({ synced_at: at }).in("id", P.tierIds).lte("changed_at", P.readAt);
  };
  // 1. new or changed fixed prices (an upsert: on its own it never removes anything)
  if (P.pricesToAdd.length) {
    const d = await gql(`mutation($id: ID!, $prices: [PriceListPriceInput!]!) { priceListFixedPricesAdd(priceListId: $id, prices: $prices) { prices { variant { id } } userErrors { field message } } }`, { id: P.priceListId, prices: P.pricesToAdd });
    const ue = userErr(d.priceListFixedPricesAdd); if (ue) throw new Error("Prezzi non inviati: " + ue);
  }
  // 2. everything else in ONE quantityPricingByVariantUpdate: Shopify runs the deletes before the adds and applies all or
  //    nothing, so a refused break never leaves a product without its breaks or its rule
  if (P.pricesToDelete.length || P.rulesToDelete.length || P.rulesToAdd.length || P.breaksToDelete.length || P.breaksToAdd.length) {
    const b = await gql(`mutation($id: ID!, $input: QuantityPricingByVariantUpdateInput!) { quantityPricingByVariantUpdate(priceListId: $id, input: $input) { userErrors { field message } } }`,
      { id: P.priceListId, input: { pricesToAdd: [], pricesToDeleteByVariantId: P.pricesToDelete, quantityRulesToDeleteByVariantId: P.rulesToDelete, quantityRulesToAdd: P.rulesToAdd,
                                    quantityPriceBreaksToDelete: P.breaksToDelete, quantityPriceBreaksToAdd: P.breaksToAdd } });
    const ue = userErr(b.quantityPricingByVariantUpdate);
    if (ue) {
      if (P.pricesToAdd.length) await markSent(false);
      throw new Error(`${P.pricesToAdd.length ? "Prezzi inviati; " : ""}scaglioni e minimi NON inviati (Shopify non ha cambiato niente): ${ue}`);
    }
  }
  await markSent(true);
  return { prices: P.pricesToAdd.length, rules: P.rulesToAdd.length, price_breaks: P.breaksToAdd.length, removed: P.pricesToDelete.length,
           breaks_removed: P.breaksToDelete.length, changes: P.changes.length, basis: P.basis };
}

// ---------- staff gate ----------
async function staffLevel(req: Request): Promise<number> {
  if (!req.headers.get("Authorization")) return 0;
  const { data } = await asUser(req).rpc("my_permissions");
  return Number((data as any)?.areas?.vendite ?? 0);
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const url = new URL(req.url);
  const action = url.searchParams.get("action") ?? "";
  let b: Record<string, any> = {};
  if (req.method === "POST") { try { b = await req.json(); } catch { b = {}; } }

  try {
    // ----- customer portal (token) -----
    if (req.method === "GET" && action === "state") {
      const t = url.searchParams.get("t") ?? "";
      if (!TOK.test(t)) return json({ error: "link non valido" }, 403);
      const { data, error } = await admin().rpc("trade_portal_state", { p_token: t });
      if (error) return dbErr(error);
      return data ? json(data) : json({ error: "accesso non attivo" }, 403);
    }
    if (req.method === "POST" && action === "portal") {
      const t = String(b.t ?? "");
      if (!TOK.test(t)) return json({ error: "link non valido" }, 403);
      const { data, error } = await admin().rpc("trade_portal_action", { p_token: t, p_action: String(b.action ?? ""), p_payload: b.payload ?? {} });
      if (error) return dbErr(error);
      return data ? json(data) : json({ error: "accesso non attivo" }, 403);
    }
    // ----- public application -----
    if (req.method === "POST" && action === "apply") {
      if (b.website) return json({ ok: true, message_it: "Richiesta ricevuta." });   // honeypot
      const { data, error } = await admin().rpc("trade_apply", { p: b });
      if (error) return dbErr(error);
      return json(data);
    }
    // ----- staff -----
    if (req.method === "POST" && ["approve", "reject", "link", "sync-prices", "prices-preview"].includes(action)) {
      const lvl = await staffLevel(req);
      if (lvl < 3) return json({ error: "serve il livello Gestisce in Vendite" }, 403);
      const user = asUser(req), db = admin();
      if (action === "reject") {
        const { data, error } = await user.rpc("trade_reject", { p_app: b.application_id, p_note: b.note ?? null });
        if (error) return dbErr(error);
        return json({ ok: !!data });
      }
      if (action === "sync-prices") {
        try { return json(await syncPrices()); } catch (e) { const m = (e as Error).message; return m === "not_configured" ? json({ shopify: "not_configured" }, 503) : json({ error: m }, 502); }
      }
      if (action === "prices-preview") {        // v0.99 (audit B-22): what «Invia a Shopify» would change, read from the price list now
        try { const P = await planPrices(); return json({ basis: P.basis, changes: P.changes, prices: P.pricesToAdd.length, removed: P.pricesToDelete.length }); }
        catch (e) { const m = (e as Error).message; return m === "not_configured" ? json({ shopify: "not_configured" }, 503) : json({ error: m }, 502); }
      }
      let app: Record<string, any>, partyId: string, token: string, approved: Record<string, any> | null = null;
      if (action === "approve") {
        const { data, error } = await user.rpc("trade_approve", { p_app: b.application_id, p_note: b.note ?? null });
        if (error) return dbErr(error);
        approved = data; partyId = data.party_id; token = data.token;
        const { data: a } = await db.from("trade_applications").select("*").eq("id", b.application_id).maybeSingle();
        app = { ...(a ?? {}), party_id: partyId };
        // v1.10 (review L2): a customer already in the register whose data differ from the request: the Shopify company is made from
        // the register, never from what the request says (name, P.IVA, address)
        if (data?.already || (Array.isArray(data?.differences) && data.differences.length)) {
          const { data: p } = await db.from("parties").select("*").eq("id", partyId).maybeSingle();
          if (p) app = { ...app, business_name: p.legal_name ?? app.business_name, piva: p.piva, phone: p.phone, address: p.address, city: p.city,
                         province: p.province, postcode: p.postcode, email: p.email ?? app.email };
        }
      } else {
        partyId = b.party_id;
        const { data: p } = await db.from("parties").select("*").eq("id", partyId).maybeSingle();
        if (!p || p.trade_status !== "approved" || !p.portal_token) return json({ error: "cliente non approvato" }, 400);
        token = p.portal_token;
        app = { business_name: p.legal_name, business_type: p.business_type, contact_name: p.legal_name, email: p.email, phone: p.phone, address: p.address, city: p.city, province: p.province, postcode: p.postcode, piva: p.piva, party_id: p.id, created_at: p.created_at };
      }
      if (!app.email) return json({ ok: true, approved, shopify: "no_email" });
      try {
        const { data: p } = await db.from("parties").select("payment_terms_days, shopify_company_id, shopify_location_id, shopify_contact_id, shopify_customer_id").eq("id", partyId).maybeSingle();
        const cid = p?.shopify_customer_id ? (String(p.shopify_customer_id).startsWith("gid://") ? p.shopify_customer_id : `gid://shopify/Customer/${p.shopify_customer_id}`) : null;
        let link = { companyId: p?.shopify_company_id, locationId: p?.shopify_location_id, contactId: p?.shopify_contact_id, customerId: cid, existed: true };
        if (!link.companyId || !link.locationId) link = await ensureCompany(app as Record<string, string | null>, p?.payment_terms_days ?? null);
        if (link.customerId) await markCustomer(link.customerId, token);
        await db.rpc("trade_approve_done", { p_app: action === "approve" ? b.application_id : null, p_party: partyId, p_company: link.companyId, p_location: link.locationId, p_contact: link.contactId, p_customer: link.customerId ?? null });
        return json({ ok: true, approved, shopify: "linked", company_id: link.companyId, location_id: link.locationId, existed: link.existed, token });
      } catch (e) {
        const m = (e as Error).message;
        if (m === "not_configured") return json({ ok: true, approved, shopify: "not_configured", token, manual: { tag: TAG, metafield: "trade.portal_token", value: token, email: app.email } });
        return json({ ok: true, approved, shopify: "error", error: m, token }, 207);
      }
    }
    // ----- queue → Shopify orders -----
    if (req.method === "POST" && action === "run-queue") {
      const { data: sec } = await admin().from("settings").select("value").eq("key", "trade.job_secret").maybeSingle();
      const okSecret = !!sec?.value && same(req.headers.get("x-trade-secret") ?? "", sec.value);
      if (!okSecret && (await staffLevel(req)) < 3) return json({ error: "non autorizzato" }, 403);
      const r = await runQueue();
      return json(r, r.configured ? 200 : 503);
    }
    // ----- diagnostics: is Shopify reachable with the configured credentials? (staff or job secret) -----
    if (req.method === "GET" && action === "status") {
      const { data: sec } = await admin().from("settings").select("value").eq("key", "trade.job_secret").maybeSingle();
      const okSecret = !!sec?.value && same(req.headers.get("x-trade-secret") ?? "", sec.value);
      if (!okSecret && (await staffLevel(req)) < 1) return json({ error: "non autorizzato" }, 403);
      if (!CONFIGURED) return json({ configured: false, shop: SHOP, mode: "none" });
      try {
        const d = await gql(`{ shop { name myshopifyDomain plan { partnerDevelopment shopifyPlus } } currentAppInstallation { accessScopes { handle } } }`);
        return json({ configured: true, shop: SHOP, mode: STATIC_TOKEN ? "static_token" : "client_credentials", shop_name: d.shop?.name, scopes: (d.currentAppInstallation?.accessScopes ?? []).map((x: { handle: string }) => x.handle) });
      } catch (e) { return json({ configured: true, shop: SHOP, mode: STATIC_TOKEN ? "static_token" : "client_credentials", error: (e as Error).message }, 502); }
    }
    return json({ error: "azione non valida" }, 404);
  } catch (e) {
    const m = (e as Error).message ?? String(e);
    return m === "not_configured" ? json({ shopify: "not_configured" }, 503) : json({ error: m }, 500);
  }
});
