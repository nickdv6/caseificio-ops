// farm-order — the Masseria's milk page (v0.64 orders, v0.65 shipments; 05/10/2026)
//
// fabula-tablet/latte.html?t=<token> calls this function; nobody logs in. v1.03 (audit FARM-04): two keys, both made by the
// database (Configurazione → Utenti e accessi → Link della Masseria): milk.farm_token = the full link of the farm's owner,
// milk.farm_ship_token = the QR poster in the barn (record a shipment, today's loads, correct its own load within 2 hours).
// The database functions do the token check and tell which link it is (scope "full" / "qr" in the GET answer):
//   GET  ?t=<token>                                    → fabula.farm_milk_orders(token): latest shipment, last 30 days,
//                                                        month totals, approved milk orders and orders awaiting approval
//   POST { t, action: "ship", kg, confirm?, temp?, ddt?, note?, by? }
//                                                    → fabula.farm_milk_ship(...): the farm records the kg it shipped
//                                                        (the farm's weight is the source of truth). v0.95 (audit FARM-01):
//                                                        confirm false = check the weight against today's order and the usual
//                                                        loads first (answers { needs_confirm, message }), true = confirmed
//   POST { t, action: "amend", lot, kg?, cancel?, reason, by? }
//                                                    → fabula.farm_milk_amend(...) (v0.94): the farm corrects the kg of, or
//                                                        cancels, a load still in transit (reason required)
//   by = who at the farm (v1.03, setting milk.farm_people); a database without v1.03 gets the call without it
//   POST { t, plan_date: "YYYY-MM-DD" }                → fabula.farm_milk_seen(token, date): the farm has seen that order
// All these functions are executable by service_role only, so the page never touches the database directly.
// Deploy with verify_jwt = false (the page has no Supabase login).

import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" } });
const TOKEN = /^[0-9a-f]{16,64}$/i;
const num = (v: unknown) => (v === null || v === undefined || v === "" ? null : Number(String(v).replace(",", ".")));
const who = (v: unknown) => { const s = String(v ?? "").replace(/\s+/g, " ").trim().slice(0, 60); return s || null; };
// call an RPC; when the database is older than the arguments (PGRST202 = no such function signature), drop the newest ones in turn
// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function rpcCompat(fab: any, fn: string, args: Record<string, unknown>, newest: string[]) {
  let r = await fab.rpc(fn, args);
  for (const k of newest) {
    if (!(r.error && r.error.code === "PGRST202")) break;
    delete args[k];
    r = await fab.rpc(fn, args);
  }
  return r;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const fab = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } }).schema("fabula");

  if (req.method === "GET") {
    const t = new URL(req.url).searchParams.get("t") ?? "";
    if (!TOKEN.test(t)) return json({ error: "link non valido" }, 403);
    const { data, error } = await fab.rpc("farm_milk_orders", { p_token: t });
    if (error) return json({ error: "errore del server" }, 500);
    if (!data) return json({ error: "link non valido o scaduto" }, 403);
    return json(data);
  }
  if (req.method === "POST") {
    let b: Record<string, unknown> = {};
    try { b = await req.json(); } catch { /* empty */ }
    const t = String(b.t ?? "");
    if (!TOKEN.test(t)) return json({ error: "link non valido" }, 403);

    if (b.action === "ship") {
      const kg = num(b.kg), temp = num(b.temp), confirm = b.confirm === true ? true : b.confirm === false ? false : null;
      if (kg === null || !Number.isFinite(kg) || kg <= 0 || kg > 5000) return json({ error: "peso non valido" }, 400);
      if (temp !== null && (!Number.isFinite(temp) || temp < -2 || temp > 40)) return json({ error: "temperatura non valida" }, 400);
      const args: Record<string, unknown> = {
        p_token: t, p_kg: kg, p_temp: temp,
        p_ddt: b.ddt ? String(b.ddt).slice(0, 40) : null, p_note: b.note ? String(b.note).slice(0, 300) : null, p_confirm: confirm,
        p_by: who(b.by),
      };
      const { data, error } = await rpcCompat(fab, "farm_milk_ship", args, ["p_by", "p_confirm"]);   // older database: without v1.03 / v0.95b
      if (error) return json({ error: error.code === "22023" ? error.message : "errore del server" }, error.code === "22023" ? 400 : 500);
      if (!data) return json({ error: "link non valido o scaduto" }, 403);
      if (data.needs_confirm) return json({ ok: false, needs_confirm: true, kg: data.kg, message: data.message_it });
      return json({ ok: true, shipment: data });
    }

    if (b.action === "amend") {
      const lot = String(b.lot ?? ""), cancel = b.cancel === true, kg = cancel ? null : num(b.kg);
      if (!/^[A-Za-z0-9-]{3,40}$/.test(lot)) return json({ error: "spedizione non valida" }, 400);
      if (!cancel && (kg === null || !Number.isFinite(kg) || kg <= 0 || kg > 5000)) return json({ error: "peso non valido" }, 400);
      const { data, error } = await rpcCompat(fab, "farm_milk_amend", {
        p_token: t, p_lot: lot, p_kg: kg, p_cancel: cancel, p_reason: b.reason ? String(b.reason).slice(0, 300) : null, p_by: who(b.by),
      }, ["p_by"]);
      if (error) return json({ error: error.code === "22023" ? error.message : "errore del server" }, error.code === "22023" ? 400 : 500);
      if (!data) return json({ error: "link non valido o scaduto" }, 403);
      return json({ ok: true, shipment: data });
    }

    const d = String(b.plan_date ?? "");
    if (!/^\d{4}-\d{2}-\d{2}$/.test(d)) return json({ error: "richiesta non valida" }, 400);
    const { data, error } = await fab.rpc("farm_milk_seen", { p_token: t, p_plan_date: d });
    if (error) return json({ error: "errore del server" }, 500);
    return data ? json({ ok: true }) : json({ error: "ordine non trovato o link non valido" }, 404);
  }
  return json({ error: "metodo non ammesso" }, 405);
});
