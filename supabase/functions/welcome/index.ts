// La Perla · welcome (v1.09): the personal access link, opened on benvenuto.html#invito=<token>. No login needed: whoever holds the link
// is the person it was made for (Configurazione → Persone → «Link di accesso», sent by WhatsApp or e-mail from the owner's phone).
// Only the sha256 of the link is in the database (fabula.staff_access_links). The link lasts auth.link_days (7), until a newer one is
// made, and is used up only when the password is saved: opening it, a WhatsApp preview or a mail scanner do not spend it.
// POST { action: "info", token }               → who the link is for (to greet them), or why it no longer works
// POST { action: "redeem", token, password }   → sets the password (creating the login the first time), links it to the person;
//                                                the page then signs in with e-mail and password
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });
const sha256hex = async (s: string) =>
  [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)))].map((b) => b.toString(16).padStart(2, "0")).join("");

// what the page may show: never the ids
// deno-lint-ignore no-explicit-any
const pub = (c: any) => ({
  ok: !!c?.ok, reason: c?.reason ?? null, first_name: c?.first_name ?? null, full_name: c?.full_name ?? null, role_name: c?.role_name ?? null,
  home: c?.home ?? null, purpose: c?.purpose ?? null, expires_at: c?.expires_at ?? null, used_at: c?.used_at ?? null, company: c?.company ?? null, email: c?.email ?? null,
});

const weak = (m: string) =>
  /weak|easy to guess|pwned|known/i.test(m) ? "Questa password è troppo comune (compare in elenchi di password rubate): scegline una diversa."
  : /at least|too short|characters/i.test(m) ? "La password deve avere almeno 8 caratteri."
  : null;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "metodo non ammesso" }, 405);
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { db: { schema: "fabula" }, auth: { autoRefreshToken: false, persistSession: false } });
  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* empty */ }
  const action = String(body.action ?? "");
  const token = String(body.token ?? "");
  if (!/^[A-Za-z0-9_-]{32,128}$/.test(token)) return json({ ok: false, reason: "unknown" });
  const hash = await sha256hex(token);

  if (action === "info") {
    const { data, error } = await admin.rpc("access_link_check", { p_token_hash: hash });
    if (error) return json({ error: "Servizio non disponibile: riprova tra poco" }, 503);
    return json(pub(data));
  }

  if (action === "redeem") {
    const password = String(body.password ?? "");
    if (password.length < 8) return json({ ok: false, reason: "weak", message: "La password deve avere almeno 8 caratteri." });
    if (new TextEncoder().encode(password).length > 72) return json({ ok: false, reason: "weak", message: "La password è troppo lunga (al massimo 72 caratteri)." });
    const { data: claim, error: ce } = await admin.rpc("access_link_claim", { p_token_hash: hash });
    if (ce) return json({ error: "Servizio non disponibile: riprova tra poco" }, 503);
    if (!claim?.claimed) return json(pub(claim));
    const email = String(claim.email ?? "").trim().toLowerCase();
    try {
      // the person's login: the one already linked, else one with the same e-mail (an invite sent before v1.09), else a new one
      // deno-lint-ignore no-explicit-any
      let user: any = null;
      if (claim.auth_user_id) { const { data } = await admin.auth.admin.getUserById(claim.auth_user_id); user = data?.user ?? null; }
      if (!user) {
        for (let page = 1; page <= 10 && !user; page++) {
          const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 200 });
          if (error) throw error;
          user = data.users.find((x) => (x.email ?? "").toLowerCase() === email) ?? null;
          if (data.users.length < 200) break;
        }
      }
      if (user) {
        const attrs: Record<string, unknown> = { password, email_confirm: true };
        if ((user.email ?? "").toLowerCase() !== email) attrs.email = email;   // the login follows the e-mail of the person (C-13)
        const { error } = await admin.auth.admin.updateUserById(user.id, attrs);
        if (error) throw error;
      } else {
        const { data, error } = await admin.auth.admin.createUser({ email, password, email_confirm: true, user_metadata: { full_name: claim.full_name } });
        if (error) throw error;
        user = data.user;
      }
      const { error: de } = await admin.rpc("access_link_done", { p_link_id: claim.link_id, p_auth_user_id: user.id });
      if (de) throw de;
      return json({ ok: true, email, first_name: claim.first_name, company: claim.company });
    } catch (e) {
      await admin.rpc("access_link_unclaim", { p_link_id: claim.link_id });   // nothing was set: the link works again
      const m = (e as Error).message ?? String(e);
      const w = weak(m);
      if (w) return json({ ok: false, reason: "weak", message: w });
      return json({ error: "Non è stato possibile salvare la password: riprova tra poco. (" + m + ")" }, 500);
    }
  }
  return json({ error: "azione sconosciuta" }, 400);
});
