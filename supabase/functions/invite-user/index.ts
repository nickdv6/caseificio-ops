// La Perla · user invitations and account admin (called from admin.html → Utenti e ruoli, with the caller's session).
// Only a staff member whose profile can manage users (fabula.app_roles.can_manage_users, i.e. Titolare) may call it.
// POST { action: "invite", email, full_name, app_role, job_role? }  → creates/updates the staff row, sends the Supabase invite e-mail,
//        links staff.auth_user_id; if the e-mail already has an account it is linked without a new invite.
// POST { action: "resend", staff_id }   → new invite (or password-reset e-mail if the account already set a password)
// POST { action: "link", staff_id }     → v0.81f: NO e-mail. Returns a one-time link to benvenuto.html (token_hash, verified only when the
//        password is saved) for the titolare to send by WhatsApp. Not subject to the Supabase e-mail rate limit.
// POST { action: "deactivate", staff_id } / { action: "reactivate", staff_id } → staff.active false/true and bans/unbans the login.
// Redirect: the e-mail link opens benvenuto.html on the site (Supabase → Authentication → URL configuration must allow it).
// v1.08: the site's address comes from the database (setting infra.site_url, the same one every other link uses), so moving the app
// is one setting (v1.08b: app.bubalina.it); SITE_URL / the app's address are only fallbacks.
// v1.09 «Persone» (staff onboarding):
// POST { action: "add", full_name, email?, app_role, job_role? } → a new person; with an e-mail, also their personal access link
// POST { action: "access_link", staff_id }   → the personal link benvenuto.html#invito=<token>: lasts auth.link_days (7), until a
//        newer one is made, and is used up only when the password is saved (server function «welcome»). Only its sha256 is stored.
//        No e-mail from Supabase: the owner sends it by WhatsApp or from his own mail app (no 24 h limit, no hourly e-mail limit).
// POST { action: "update_email", staff_id, email } → (audit C-13) changes the person's e-mail AND the e-mail they sign in with.
// «deactivate» now switches the person off with fabula.staff_offboard (audit C-14: open shift, future rota, links, Telegram, PIN),
// then blocks the login. «invite» with the e-mail of someone switched off answers «usa Riattiva» (audit C-15).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const SITE_FALLBACK = Deno.env.get("SITE_URL") ?? "https://app.bubalina.it";
// deno-lint-ignore no-explicit-any
async function siteUrl(admin: any): Promise<string> {
  try {
    const { data } = await admin.from("settings").select("value").eq("key", "infra.site_url").maybeSingle();
    const v = String(data?.value ?? "").trim().replace(/\/+$/, "");
    if (/^https:\/\/[a-z0-9.-]+(:\d+)?(\/[A-Za-z0-9._~\/-]*)?$/i.test(v)) return v;
  } catch { /* the fallback below */ }
  return SITE_FALLBACK.replace(/\/+$/, "");
}
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });
const sha256hex = async (t: string) =>
  [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(t)))].map((b) => b.toString(16).padStart(2, "0")).join("");
const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const JOB_FOR: Record<string, string> = { titolare: "owner", socio: "partner", resp_produzione: "casaro", produzione: "operaio", qualita: "operaio",
  spedizioni: "operaio", banco: "commesso", marketing: "consulente", amministrazione: "consulente", consulente: "consulente" };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const url = Deno.env.get("SUPABASE_URL")!;
  const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const userClient = createClient(url, anon, { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } }, db: { schema: "fabula" } });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "non autenticato" }, 401);
  const { data: me } = await userClient.rpc("my_permissions");
  if (!me?.can_manage_users) return json({ error: "Solo il titolare può gestire utenti e ruoli" }, 403);

  const admin = createClient(url, service, { db: { schema: "fabula" }, auth: { autoRefreshToken: false, persistSession: false } });
  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* empty */ }
  const action = String(body.action ?? "");
  const SITE = await siteUrl(admin);
  const redirectTo = `${SITE}/benvenuto.html`;

  const findAuthUser = async (email: string) => {
    for (let page = 1; page <= 10; page++) {
      const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 200 });
      if (error) throw error;
      const u = data.users.find((x) => (x.email ?? "").toLowerCase() === email);
      if (u) return u;
      if (data.users.length < 200) return null;
    }
    return null;
  };
  // v1.09: a personal access link (32 random bytes, base64url); the database keeps only its sha256
  const newLink = async (staffId: string) => {
    const raw = crypto.getRandomValues(new Uint8Array(32));
    const token = btoa(String.fromCharCode(...raw)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
    const { data, error } = await admin.rpc("access_link_new", { p_staff_id: staffId, p_token_hash: await sha256hex(token), p_by: me?.staff_id ?? null });
    if (error) throw error;
    return { link: `${SITE}/benvenuto.html#invito=${token}`, site: SITE, expires_at: data.expires_at, purpose: data.purpose, first_name: data.first_name,
             role_name: data.role_name, home: data.home, email: data.email, company: data.company };
  };
  // review H1: an e-mail whose login already belongs to someone else is refused (the link would otherwise set that person's password)
  const loginOwner = async (email: string, exceptStaff?: string) => {
    const u = await findAuthUser(email);
    if (!u) return null;
    let q = admin.from("staff").select("id, full_name").eq("auth_user_id", u.id);
    if (exceptStaff) q = q.neq("id", exceptStaff);
    const { data } = await q.maybeSingle();
    return data ? { user: u, staff: data } : null;
  };
  const TAKEN = (name: string) => json({ error: `Questa email è già l'accesso di ${name}: scegline un'altra` }, 409);
  // audit C-15: someone switched off comes back with «Riattiva» (which also unblocks the login), not with a new invite
  const OFF = (id: string) => json({ error: "Questa persona è disattivata: usa «Riattiva» nella sua scheda", staff_id: id, inactive: true }, 409);

  try {
    if (action === "add") {
      const full_name = String(body.full_name ?? "").trim().replace(/\s+/g, " ");
      const email = String(body.email ?? "").trim().toLowerCase() || null;
      const app_role = String(body.app_role ?? "");
      if (full_name.length < 3) return json({ error: "Scrivi nome e cognome" }, 400);
      if (email && !EMAIL_RE.test(email)) return json({ error: "Email non valida" }, 400);
      const { data: role } = await admin.from("app_roles").select("code").eq("code", app_role).maybeSingle();
      if (!role) return json({ error: "Profilo sconosciuto" }, 400);
      if (email) {
        const { data: ex } = await admin.from("staff").select("id, full_name, active").eq("email", email).maybeSingle();
        if (ex && !ex.active) return OFF(ex.id);
        if (ex) return json({ error: `Questa email è già di ${ex.full_name}: usa la sua scheda`, staff_id: ex.id }, 409);
        const own = await loginOwner(email);
        if (own) return TAKEN(own.staff.full_name);
      }
      const job_role = String(body.job_role || JOB_FOR[app_role] || "operaio");
      const { data: staff, error } = await admin.from("staff").insert({ full_name, email, app_role, role: job_role, active: true }).select("id").single();
      if (error) throw error;
      return json({ ok: true, staff_id: staff.id, ...(email ? await newLink(staff.id) : {}) });
    }

    if (action === "access_link") {
      const { data: staff } = await admin.from("staff").select("id, email, active").eq("id", String(body.staff_id ?? "")).maybeSingle();
      if (!staff) return json({ error: "Persona non trovata" }, 404);
      if (!staff.active) return OFF(staff.id);
      if (!staff.email) return json({ error: "Manca l'email: aggiungila nella scheda (serve per entrare)" }, 400);
      const own = await loginOwner(String(staff.email).toLowerCase(), staff.id);
      if (own) return TAKEN(own.staff.full_name);
      return json({ ok: true, staff_id: staff.id, ...(await newLink(staff.id)) });
    }

    if (action === "update_email") {
      const { data: staff } = await admin.from("staff").select("id, email, auth_user_id, full_name").eq("id", String(body.staff_id ?? "")).maybeSingle();
      if (!staff) return json({ error: "Persona non trovata" }, 404);
      const email = String(body.email ?? "").trim().toLowerCase();
      if (!EMAIL_RE.test(email)) return json({ error: "Email non valida" }, 400);
      if (email === String(staff.email ?? "").toLowerCase()) return json({ ok: true, unchanged: true });
      const { data: other } = await admin.from("staff").select("id, full_name").eq("email", email).neq("id", staff.id).maybeSingle();
      if (other) return json({ error: `Questa email è già di ${other.full_name}` }, 409);
      let was: string | null = null;
      const own = await loginOwner(email, staff.id);
      if (own) return TAKEN(own.staff.full_name);
      if (staff.auth_user_id) {
        const taken = await findAuthUser(email);
        if (taken && taken.id !== staff.auth_user_id) return json({ error: "Questa email ha già un altro account di accesso: scegline un'altra" }, 409);
        const { data: cur } = await admin.auth.admin.getUserById(staff.auth_user_id);
        was = cur?.user?.email ?? null;
        const { error } = await admin.auth.admin.updateUserById(staff.auth_user_id, { email, email_confirm: true });
        if (error) throw error;
      }
      const { error } = await admin.from("staff").update({ email }).eq("id", staff.id);
      if (error) {
        if (staff.auth_user_id && was) await admin.auth.admin.updateUserById(staff.auth_user_id, { email: was, email_confirm: true });   // back as it was
        throw error;
      }
      return json({ ok: true, login_changed: !!staff.auth_user_id });
    }

    if (action === "invite") {
      const email = String(body.email ?? "").trim().toLowerCase();
      const full_name = String(body.full_name ?? "").trim();
      const app_role = String(body.app_role ?? "");
      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return json({ error: "Email non valida" }, 400);
      if (!full_name) return json({ error: "Nome mancante" }, 400);
      const { data: role } = await admin.from("app_roles").select("code").eq("code", app_role).maybeSingle();
      if (!role) return json({ error: "Profilo sconosciuto" }, 400);
      const job_role = String(body.job_role || JOB_FOR[app_role] || "operaio");

      // staff row: reuse by e-mail, else create
      // v0.60: exact match (staff.email is stored lower-case); ilike treated "_" and "%" in an address as wildcards
      let { data: staff } = await admin.from("staff").select("id, auth_user_id, active").eq("email", email).maybeSingle();
      if (staff && !staff.active) return OFF(staff.id);
      if (staff) {
        const { error } = await admin.from("staff").update({ full_name, app_role, role: job_role, active: true }).eq("id", staff.id);
        if (error) throw error;
      } else {
        // v1.09: the badge code comes from the database (random, audit C-24)
        const { data, error } = await admin.from("staff").insert({ full_name, email, app_role, role: job_role, active: true }).select("id, auth_user_id, active").single();
        if (error) throw error;
        staff = data;
      }
      let authUser = await findAuthUser(email);
      let invited = false;
      if (!authUser) {
        const { data, error } = await admin.auth.admin.inviteUserByEmail(email, { redirectTo, data: { full_name } });
        if (error) throw error;
        authUser = data.user; invited = true;
      }
      if (authUser && staff!.auth_user_id !== authUser.id) {
        const { error } = await admin.from("staff").update({ auth_user_id: authUser.id }).eq("id", staff!.id);
        if (error) throw error;
      }
      return json({ ok: true, staff_id: staff!.id, invited, linked_existing_account: !invited });
    }

    if (action === "link") {
      const { data: staff } = await admin.from("staff").select("id, email, auth_user_id, full_name, active").eq("id", String(body.staff_id ?? "")).maybeSingle();
      if (!staff) return json({ error: "Persona non trovata" }, 404);
      if (!staff.active) return json({ error: "Persona disattivata" }, 400);
      if (!staff.email) return json({ error: "Manca l'email" }, 400);
      const email = staff.email.toLowerCase();
      const existing = await findAuthUser(email);
      const type = existing ? "recovery" : "invite";   // recovery also confirms an invited account that never finished
      const { data, error } = await admin.auth.admin.generateLink(
        existing ? { type: "recovery", email, options: { redirectTo } } : { type: "invite", email, options: { redirectTo, data: { full_name: staff.full_name } } });
      if (error) throw error;
      if (data.user && staff.auth_user_id !== data.user.id) await admin.from("staff").update({ auth_user_id: data.user.id }).eq("id", staff.id);
      const link = `${SITE}/benvenuto.html?token_hash=${encodeURIComponent(data.properties.hashed_token)}&type=${type}`;
      return json({ ok: true, link, type, has_password: !!(existing && existing.last_sign_in_at) });
    }

    if (action === "resend" || action === "deactivate" || action === "reactivate") {
      const { data: staff } = await admin.from("staff").select("id, email, auth_user_id, full_name").eq("id", String(body.staff_id ?? "")).maybeSingle();
      if (!staff) return json({ error: "Persona non trovata" }, 404);
      if (action === "resend") {
        if (!staff.email) return json({ error: "Manca l'email" }, 400);
        const existing = await findAuthUser(staff.email.toLowerCase());
        if (existing && existing.last_sign_in_at) {
          const { error } = await userClient.auth.resetPasswordForEmail(staff.email, { redirectTo });
          if (error) throw error;
          return json({ ok: true, sent: "reset" });
        }
        const { data, error } = await admin.auth.admin.inviteUserByEmail(staff.email, { redirectTo, data: { full_name: staff.full_name } });
        if (error) throw error;
        if (data.user && staff.auth_user_id !== data.user.id) await admin.from("staff").update({ auth_user_id: data.user.id }).eq("id", staff.id);
        return json({ ok: true, sent: "invite" });
      }
      if (staff.auth_user_id === user.id) return json({ error: "Non puoi disattivare te stesso" }, 400);
      const active = action === "reactivate";
      // deno-lint-ignore no-explicit-any
      let summary: any = null;
      if (active) {
        const { error } = await admin.from("staff").update({ active }).eq("id", staff.id);
        if (error) throw error;
      } else {
        // v1.09 (audit C-14): one transaction, as the caller (the change log names who did it)
        const { data, error } = await userClient.rpc("staff_offboard", { p_staff_id: staff.id });
        if (error) throw error;
        summary = data;
      }
      if (staff.auth_user_id) {
        const { error: e2 } = await admin.auth.admin.updateUserById(staff.auth_user_id, { ban_duration: active ? "none" : "876000h" });
        if (e2 && active) throw e2;
        // review L8: the person is already switched off (the app lets in active people only); say so instead of a bare error
        if (e2) return json({ ok: true, active, summary, warning: "Disattivato, ma il blocco dell'accesso non è riuscito: tocca «Riattiva» e poi di nuovo «Disattiva»" });
      }
      return json({ ok: true, active, summary });
    }
    return json({ error: "azione sconosciuta" }, 400);
  } catch (e) {
    const m = (e as Error).message ?? String(e);
    if (/rate limit/i.test(m)) return json({ error: "Supabase ha raggiunto il limite di email (poche all'ora con il servizio email incluso). Usa «Link WhatsApp» oppure riprova tra un'ora." }, 429);
    return json({ error: m }, 500);
  }
});
