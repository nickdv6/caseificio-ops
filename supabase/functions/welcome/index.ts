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

// what the page may show: never the ids. A link that no longer works says why, and nothing about the person (review L1: a link
// sent to the wrong number and then replaced must not keep telling who it was for)
// deno-lint-ignore no-explicit-any
const pub = (c: any) => c?.ok
  ? { ok: true, reason: null, first_name: c.first_name ?? null, full_name: c.full_name ?? null, role_name: c.role_name ?? null, home: c.home ?? null,
      purpose: c.purpose ?? null, expires_at: c.expires_at ?? null, company: c.company ?? null, email: c.email ?? null }
  : { ok: false, reason: c?.reason ?? "unknown", company: c?.company ?? null,
      home: c?.reason === "used" ? c?.home ?? null : null, used_at: c?.reason === "used" ? c?.used_at ?? null : null,
      expires_at: c?.reason === "expired" ? c?.expires_at ?? null : null };

// v1.10 (review): the rule Supabase gives is said as it is (a length other than 8, or the kinds of character it wants)
const weak = (m: string) => {
  if (/weak|easy to guess|pwned|known/i.test(m)) return "Questa password è troppo comune (compare in elenchi di password rubate): scegline una diversa.";
  if (/password should contain|character of each|at least one (lower|upper|digit|number|symbol)/i.test(m)) {
    return "La password deve contenere lettere minuscole, lettere maiuscole e numeri" + (/symbol|[!@#$%^&*]/i.test(m) ? " e almeno un simbolo (per esempio ! ? #)." : ".");
  }
  const n = m.match(/at least (\d+) char/i);
  if (n || /password.*(too short|characters)/i.test(m)) return `La password deve avere almeno ${n ? n[1] : 8} caratteri.`;
  return null;
};

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
    // review H1: the login is chosen and linked to this person BEFORE anything is written to it. A login that belongs to someone
    // else is refused, so a link can never set another person's password.
    const bind = async (uid: string) => {
      const { error } = await admin.rpc("access_link_bind", { p_link_id: claim.link_id, p_auth_user_id: uid });
      if (error) throw Object.assign(new Error(error.message), { code: error.code });
    };
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
        await bind(user.id);
        const attrs: Record<string, unknown> = { password, email_confirm: true };
        if ((user.email ?? "").toLowerCase() !== email) attrs.email = email;   // the login follows the e-mail of the person (C-13)
        if (user.banned_until && new Date(user.banned_until) > new Date()) attrs.ban_duration = "none";   // the person is active (review L6)
        const { error } = await admin.auth.admin.updateUserById(user.id, attrs);
        if (error) throw error;
      } else {
        const { data, error } = await admin.auth.admin.createUser({ email, password, email_confirm: true, user_metadata: { full_name: claim.full_name } });
        if (error) throw error;
        user = data.user;
        await bind(user.id);
      }
      // v1.10 (review): the person's other open links stop only now that the password is saved (before, a save that failed left
      // both this link and a newer one dead)
      let { error: de } = await admin.rpc("access_link_done", { p_link_id: claim.link_id });
      if (de) ({ error: de } = await admin.rpc("access_link_done", { p_link_id: claim.link_id }));   // once more: the other links must stop
      if (de) console.error("welcome done:", de.message);
      return json({ ok: true, email, first_name: claim.first_name, company: claim.company });
    } catch (e) {
      await admin.rpc("access_link_unclaim", { p_link_id: claim.link_id });   // nothing was set: the link works again
      // deno-lint-ignore no-explicit-any
      const err = e as any, m = err?.message ?? String(e);
      if (err?.code === "P0409") return json({ ok: false, reason: "conflict", message: "Questa email è già l'accesso di un'altra persona: chiedi al titolare di controllare la tua email." });
      const w = weak(m);
      if (w) return json({ ok: false, reason: "weak", message: w });
      console.error("welcome redeem:", m);
      return json({ error: "Non è stato possibile salvare la password: riprova tra poco. Se succede ancora, chiedi al titolare un link nuovo." }, 500);
    }
  }
  return json({ error: "azione sconosciuta" }, 400);
});
