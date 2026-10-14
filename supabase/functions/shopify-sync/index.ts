// shopify-sync — Shopify orders, customers and stock copied by code, not by an LLM (v1.02, 14/10/2026, audit E-18)
//
// Only the database calls it: pg_cron → fabula.shopify_sync_tick() at the slots of bot_schedule (runner 'db'), or «Esegui ora»
// in Configurazione → Bot → fabula.shopify_sync_now(). The call carries the header x-sync-secret, which must equal the row
// 'shopify_sync' of fabula.job_secrets (only the service role and the database can read it). Deploy with verify_jwt = false
// (pinned in supabase/config.toml): pg_cron has no user login.
//
//   POST { agent: "shopify_orders" | "shopify_customers" | "shopify_inventory", by?, slot? } → one run:
//        fabula.shopify_sync_start (the run record, one at a time) → the job in sync.ts → fabula.shopify_sync_finish
//        (the run's result and the message in Configurazione → Bot, both written by the database from the numbers)
//   POST { agent: "status" } → are the credentials working, which permissions each job is missing
//
// Shopify credentials: the same secrets as trade-portal (SHOPIFY_CLIENT_ID + SHOPIFY_CLIENT_SECRET, or SHOPIFY_ADMIN_TOKEN;
// SHOPIFY_SHOP). Permissions of the app «Caseificio ops»: orders and customers work with what it has; the stock needs
// read_inventory, write_inventory, read_locations and the shipment confirmations read/write_merchant_managed_fulfillment_orders.
// Without them those parts say what is missing and change nothing.

import { createClient } from "npm:@supabase/supabase-js@2";
import { CONFIGURED, gql, resetToken, scopes, SHOP_DOMAIN } from "./shopify.ts";
import { type Db, has, syncCustomers, syncInventory, syncOrders } from "./sync.ts";

const AGENTS = ["shopify_orders", "shopify_customers", "shopify_inventory"];
const NEEDS: Record<string, string[]> = {
  shopify_orders: ["read_orders"],
  shopify_customers: ["read_customers"],
  shopify_inventory: ["read_products", "read_inventory", "read_locations", "write_inventory"],
  shipments: ["read_merchant_managed_fulfillment_orders", "write_merchant_managed_fulfillment_orders"],
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
function same(a: string, b: string) {             // constant time for keys of the same length
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  if (!x.length || x.length !== y.length) return false;
  let d = 0;
  for (let i = 0; i < x.length; i++) d |= x[i] ^ y[i];
  return d === 0;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ ok: true, service: "shopify-sync" });
  const fab = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } }).schema("fabula");
  const { data: sec, error: secErr } = await fab.from("job_secrets").select("value").eq("name", "shopify_sync").maybeSingle();
  if (secErr) { console.error("job_secrets", secErr.message); return json({ error: "database non raggiungibile" }, 500); }
  if (!sec?.value || !same(req.headers.get("x-sync-secret") ?? "", sec.value)) return json({ error: "non autorizzato" }, 403);
  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* empty body */ }
  const agent = String(body.agent ?? "");

  if (agent === "status") {
    if (!CONFIGURED) return json({ configured: false, shop: SHOP_DOMAIN });
    try {
      resetToken();
      const sc = await scopes(gql);
      return json({ configured: true, shop: SHOP_DOMAIN, scopes: [...sc].sort(),
                    missing: Object.fromEntries(Object.entries(NEEDS).map(([k, v]) => [k, v.filter((s) => !has(sc, s))])) });
    } catch (e) { return json({ configured: true, shop: SHOP_DOMAIN, error: (e as Error).message }, 502); }
  }
  if (!AGENTS.includes(agent)) return json({ error: "sincronizzazione sconosciuta" }, 400);

  const db: Db = {
    rpc: async (fn, args) => { const { data, error } = await fab.rpc(fn, args ?? {}); return { data, error: error ? { message: error.message, code: error.code } : null }; },
    rows: async (view) => { const { data, error } = await fab.from(view).select("*"); if (error) throw new Error(error.message); return data ?? []; },
  };
  const st = await fab.rpc("shopify_sync_start", { p_agent: agent, p_by: body.by ?? null, p_slot: body.slot ?? null });
  if (st.error) return json({ error: st.error.message }, /in corso/.test(st.error.message) ? 409 : 500);
  const run = String(st.data);
  const t0 = Date.now();
  let result: Record<string, unknown>;
  try {
    if (!CONFIGURED) throw new Error("not_configured");
    resetToken();
    const sc = await scopes(gql);
    if (agent === "shopify_orders") {
      const { data: s } = await fab.from("settings").select("value").eq("key", "shopify.orders_days").maybeSingle();
      result = await syncOrders(gql, db, { days: Number(s?.value ?? 3), now: new Date(), scopes: sc });
    } else if (agent === "shopify_customers") {
      result = await syncCustomers(gql, db);
    } else {
      result = await syncInventory(gql, db, sc, run);
    }
  } catch (e) {
    result = { ok: false, error: (e as Error).message ?? String(e) };
  }
  result.ms = Date.now() - t0;
  if (body.by) result.by = body.by;
  const fin = await fab.rpc("shopify_sync_finish", { p_run: run, p_result: result });
  if (fin.error) { console.error("shopify_sync_finish", fin.error.message); return json({ error: fin.error.message, run }, 500); }
  return json({ ok: result.ok, run, ...(fin.data ?? {}) });
});
