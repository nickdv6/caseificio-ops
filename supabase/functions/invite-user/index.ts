// La Perla · user invitations and account admin (called from admin.html → Utenti e ruoli, with the caller's session).
// Only a staff member whose profile can manage users (fabula.app_roles.can_manage_users, i.e. Titolare) may call it.
// POST { action: "invite", email, full_name, app_role, job_role? }  → creates/updates the staff row, sends the Supabase invite e-mail,
//        links staff.auth_user_id; if the e-mail already has an account it is linked without a new invite.
// POST { action: "resend", staff_id }   → new invite (or password-reset e-mail if the account already set a password)
// POST { action: "deactivate", staff_id } / { action: "reactivate", staff_id } → staff.active false/true and bans/unbans the login.
// Redirect: the e-mail link opens benvenuto.html on the site (Supabase → Authentication → URL configuration must allow it).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const SITE = Deno.env.get("SITE_URL") ?? "https://flourishing-swan-6729c4.netlify.app";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });
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

  try {
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
      let { data: staff } = await admin.from("staff").select("id, auth_user_id").eq("email", email).maybeSingle();
      if (staff) {
        const { error } = await admin.from("staff").update({ full_name, app_role, role: job_role, active: true }).eq("id", staff.id);
        if (error) throw error;
      } else {
        const badge = "STAFF:" + full_name.split(/\s+/)[0].toUpperCase().replace(/[^A-Z]/g, "").slice(0, 10) + Math.floor(Math.random() * 90 + 10);
        const { data, error } = await admin.from("staff").insert({ full_name, email, app_role, role: job_role, active: true, badge_code: badge }).select("id, auth_user_id").single();
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
      const { error } = await admin.from("staff").update({ active }).eq("id", staff.id);
      if (error) throw error;
      if (staff.auth_user_id) {
        const { error: e2 } = await admin.auth.admin.updateUserById(staff.auth_user_id, { ban_duration: active ? "none" : "876000h" });
        if (e2) throw e2;
      }
      return json({ ok: true, active });
    }
    return json({ error: "azione sconosciuta" }, 400);
  } catch (e) {
    return json({ error: (e as Error).message ?? String(e) }, 500);
  }
});
