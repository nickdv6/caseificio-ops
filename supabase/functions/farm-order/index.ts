// farm-order — the Masseria's milk order page (v0.64, 05/10/2026)
//
// fabula-tablet/latte.html?t=<token> calls this function; nobody logs in. The token is the setting milk.farm_token
// (Configurazione → Parametri; change it to switch the old link off). The database functions do the token check:
//   GET  ?t=<token>                      → fabula.farm_milk_orders(token): approved milk plans (yesterday → +7 days) and
//                                          plans still waiting for approval
//   POST { t, plan_date: "YYYY-MM-DD" }  → fabula.farm_milk_seen(token, date): the farm has seen that order
// Both functions are executable by service_role only, so the page never touches the database directly.
// Deploy with verify_jwt = false (the page has no Supabase login).

import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" } });

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const fab = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } }).schema("fabula");

  if (req.method === "GET") {
    const t = new URL(req.url).searchParams.get("t") ?? "";
    if (!/^[0-9a-f]{16,64}$/i.test(t)) return json({ error: "link non valido" }, 403);
    const { data, error } = await fab.rpc("farm_milk_orders", { p_token: t });
    if (error) return json({ error: "errore del server" }, 500);
    if (!data) return json({ error: "link non valido o scaduto" }, 403);
    return json(data);
  }
  if (req.method === "POST") {
    let b: Record<string, unknown> = {};
    try { b = await req.json(); } catch { /* empty */ }
    const t = String(b.t ?? ""), d = String(b.plan_date ?? "");
    if (!/^[0-9a-f]{16,64}$/i.test(t) || !/^\d{4}-\d{2}-\d{2}$/.test(d)) return json({ error: "richiesta non valida" }, 400);
    const { data, error } = await fab.rpc("farm_milk_seen", { p_token: t, p_plan_date: d });
    if (error) return json({ error: "errore del server" }, 500);
    return data ? json({ ok: true }) : json({ error: "ordine non trovato o link non valido" }, 404);
  }
  return json({ error: "metodo non ammesso" }, 405);
});
