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
//   POST ?action=run-queue                             → header x-trade-secret = setting trade.job_secret (pg_cron) or staff JWT: every pending
//                                                        booked delivery becomes a Shopify B2B draft order for the company location, completed on
//                                                        net terms (paymentPending). Result written back with fabula.trade_queue_result.
//
// Shopify Admin API credentials: secrets SHOPIFY_ADMIN_TOKEN (custom app, scopes write_customers write_companies write_draft_orders
// write_orders write_products read_payment_terms) and SHOPIFY_SHOP (pxssjd-cq.myshopify.com). Without them the database side still
// works and the answers say what is left to do by hand ("shopify": "not_configured").

import { createClient } from "npm:@supabase/supabase-js@2";

const SHOP = Deno.env.get("SHOPIFY_SHOP") ?? "pxssjd-cq.myshopify.com";
const TOKEN = Deno.env.get("SHOPIFY_ADMIN_TOKEN") ?? "";
const API = "2026-07";
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
async function gql(query: string, variables: Record<string, unknown> = {}) {
  if (!TOKEN) throw new Error("not_configured");
  for (let i = 0; i < 3; i++) {
    const r = await fetch(`https://${SHOP}/admin/api/${API}/graphql.json`, {
      method: "POST", headers: { "Content-Type": "application/json", "X-Shopify-Access-Token": TOKEN }, body: JSON.stringify({ query, variables }),
    });
    if (r.status === 429) { await new Promise((res) => setTimeout(res, 1500)); continue; }
    const b = await r.json();
    if (b.errors?.length) throw new Error(b.errors.map((e: { message: string }) => e.message).join("; "));
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
  const q = await gql(`query($q: String!) { customers(first: 1, query: $q) { nodes { id defaultEmailAddress { emailAddress } companyContactProfiles { id company { id name locations(first: 1) { nodes { id } } } } } } }`, { q: `email:"${app.email}"` });
  const cust = q.customers.nodes[0];
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
        buyerExperienceConfiguration: { paymentTermsTemplateId: tmpl?.id, checkoutToDraft: false, editableShippingAddress: false },
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
    ...(tmpl ? { paymentTerms: { paymentTermsTemplateId: tmpl.id } } : {}),
    ...(p.po_number ? { poNumber: String(p.po_number) } : {}),
  };
  const d = await gql(`mutation($input: DraftOrderInput!) { draftOrderCreate(input: $input) { draftOrder { id name } userErrors { field message } } }`, { input });
  const ue = userErr(d.draftOrderCreate); if (ue) throw new Error("draftOrderCreate: " + ue);
  const draftId = d.draftOrderCreate.draftOrder.id;
  const done = await gql(`mutation($id: ID!) { draftOrderComplete(id: $id, paymentPending: true) { draftOrder { id order { id name } } userErrors { field message } } }`, { id: draftId });
  const ue2 = userErr(done.draftOrderComplete); if (ue2) throw new Error("draftOrderComplete: " + ue2 + ` (bozza ${draftId})`);
  const o = done.draftOrderComplete.draftOrder.order;
  return { draftId, orderId: o?.id ?? null, name: o?.name ?? null };
}

async function runQueue() {
  const db = admin();
  const { data, error } = await db.rpc("trade_queue_pending");
  if (error) throw error;
  const rows = (data ?? []) as Record<string, any>[];
  const out: Record<string, unknown>[] = [];
  for (const row of rows) {
    try {
      const r = await createOrder(row);
      await db.rpc("trade_queue_result", { p_id: row.id, p_ok: true, p_draft: r.draftId, p_order: r.orderId, p_name: r.name, p_error: null });
      out.push({ id: row.id, ok: true, order: r.name });
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
async function syncPrices() {
  const db = admin();
  const [{ data: prods, error: e1 }, { data: tiers, error: e2 }, { data: sett }] = await Promise.all([
    db.from("trade_products").select("*").eq("active", true), db.from("trade_price_tiers").select("*").eq("active", true), db.rpc("trade_settings"),
  ]);
  if (e1) throw e1; if (e2) throw e2;
  const s = (sett ?? {}) as Record<string, any>;
  const { data: plRow } = await db.from("settings").select("value").eq("key", "trade.shopify_price_list_id").maybeSingle();
  const priceListId = plRow?.value; if (!priceListId) throw new Error("manca trade.shopify_price_list_id");
  const prices = (prods as any[]).filter((p) => p.trade_price_eur != null).map((p) => ({ variantId: p.variant_id, price: { amount: Number(p.trade_price_eur).toFixed(2), currencyCode: "EUR" } }));
  const d = await gql(`mutation($id: ID!, $prices: [PriceListPriceInput!]!) { priceListFixedPricesAdd(priceListId: $id, prices: $prices) { prices { variant { id } } userErrors { field message } } }`, { id: priceListId, prices });
  const ue = userErr(d.priceListFixedPricesAdd); if (ue) throw new Error("priceListFixedPricesAdd: " + ue);
  // quantity rules (min / step) + native price breaks only when tiers are per delivery (Shopify computes them per order line)
  const rules = (prods as any[]).map((p) => ({ variantId: p.variant_id, minimum: Math.max(1, Math.round(Number(p.min_qty))), increment: Math.max(1, Math.round(Number(p.step_qty))) }));
  const r = await gql(`mutation($id: ID!, $rules: [QuantityRuleInput!]!) { quantityRulesAdd(priceListId: $id, quantityRules: $rules) { userErrors { field message } } }`, { id: priceListId, rules });
  const ue2 = userErr(r.quantityRulesAdd); if (ue2) throw new Error("quantityRulesAdd: " + ue2);
  let breaks = 0;
  if (s.tier_basis === "delivery") {
    const toAdd: Record<string, unknown>[] = [];
    for (const p of prods as any[]) {
      if (p.trade_price_eur == null) continue;
      for (const t of tiers as any[]) {
        if (t.variant_id && t.variant_id !== p.variant_id) continue;
        const price = t.price_eur != null ? Number(t.price_eur) : Number(p.trade_price_eur) * (1 - Number(t.discount_pct) / 100);
        toAdd.push({ variantId: p.variant_id, minimumQuantity: Math.max(1, Math.round(Number(t.min_qty) / Number(p.kg_per_unit || 1))), price: { amount: price.toFixed(2), currencyCode: "EUR" } });
      }
    }
    if (toAdd.length) {
      const b = await gql(`mutation($id: ID!, $add: [QuantityPriceBreakInput!]!) { quantityPricingByVariantUpdate(priceListId: $id, input: { quantityPriceBreaksToAdd: $add, quantityPriceBreaksToDelete: [], quantityRulesToAdd: [], quantityRulesToDeleteByVariantId: [], pricesToAdd: [], pricesToDeleteByVariantId: [] }) { userErrors { field message } } }`, { id: priceListId, add: toAdd });
      const ue3 = userErr(b.quantityPricingByVariantUpdate); if (ue3) throw new Error("quantityPricingByVariantUpdate: " + ue3);
      breaks = toAdd.length;
    }
  }
  await db.from("trade_products").update({ synced_at: new Date().toISOString() }).eq("active", true);
  return { prices: prices.length, rules: rules.length, price_breaks: breaks, basis: s.tier_basis };
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
    if (req.method === "POST" && ["approve", "reject", "link", "sync-prices"].includes(action)) {
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
      let app: Record<string, any>, partyId: string, token: string, approved: Record<string, any> | null = null;
      if (action === "approve") {
        const { data, error } = await user.rpc("trade_approve", { p_app: b.application_id, p_note: b.note ?? null });
        if (error) return dbErr(error);
        approved = data; partyId = data.party_id; token = data.token;
        const { data: a } = await db.from("trade_applications").select("*").eq("id", b.application_id).maybeSingle();
        app = { ...(a ?? {}), party_id: partyId };
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
      const okSecret = sec?.value && req.headers.get("x-trade-secret") === sec.value;
      if (!okSecret && (await staffLevel(req)) < 3) return json({ error: "non autorizzato" }, 403);
      const r = await runQueue();
      return json(r, r.configured ? 200 : 503);
    }
    return json({ error: "azione non valida" }, 404);
  } catch (e) {
    const m = (e as Error).message ?? String(e);
    return m === "not_configured" ? json({ shopify: "not_configured" }, 503) : json({ error: m }, 500);
  }
});
