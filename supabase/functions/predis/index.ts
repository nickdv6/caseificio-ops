// La Perla · Predis.ai content generation (called from marketing.html with the user's session).
// POST { action: "generate", content_id, media_type?: "single_image"|"carousel"|"video", n_posts?: 1..4 }
// POST { action: "sync" }   — pulls finished posts for in-progress jobs (fallback when the webhook didn't arrive)
// POST { action: "status" } — tells the page whether the API key / brand are configured
// Secrets (Supabase → Edge Functions → Secrets): PREDIS_API_KEY, PREDIS_BRAND_ID (optional if set in fabula.settings mkt.predis_brand_id)
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const PREDIS = "https://brain.predis.ai/predis_api/v1";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const url = Deno.env.get("SUPABASE_URL")!;
  const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const authHeader = req.headers.get("Authorization") ?? "";
  // who is calling: must be a staff member
  const userClient = createClient(url, anon, { global: { headers: { Authorization: authHeader } }, db: { schema: "fabula" } });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "non autenticato" }, 401);
  const db = createClient(url, service, { db: { schema: "fabula" } });
  const { data: staff } = await db.from("staff").select("full_name, role").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (!staff) return json({ error: "utente non abilitato" }, 403);
  // v0.60: generating spends Predis credits — only profiles that can register marketing content (marketing ≥ 2), checked with the caller's own rights
  const { data: lvl } = await userClient.rpc("perm_level", { p_area: "marketing" });

  const key = Deno.env.get("PREDIS_API_KEY") ?? "";
  const { data: setBrand } = await db.from("settings").select("value").eq("key", "mkt.predis_brand_id").maybeSingle();
  const brand = (setBrand?.value || Deno.env.get("PREDIS_BRAND_ID") || "").trim();
  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* empty */ }
  const action = String(body.action ?? "status");

  if (action === "status") return json({ configured: !!key && !!brand, has_key: !!key, has_brand: !!brand, can_generate: Number(lvl ?? 0) >= 2 });
  if (Number(lvl ?? 0) < 2) return json({ error: "Il tuo profilo non può generare contenuti (serve Marketing: registra)" }, 403);
  if (!key || !brand) return json({ error: "Predis.ai non configurato: aggiungi il segreto PREDIS_API_KEY e il brand_id (Configurazione → Marketing).", configured: false }, 412);

  if (action === "generate") {
    const contentId = String(body.content_id ?? "");
    const media = ["single_image", "carousel", "video"].includes(String(body.media_type)) ? String(body.media_type) : "single_image";
    const n = Math.max(1, Math.min(4, Number(body.n_posts ?? 1)));
    const { data: q, error: qe } = await db.rpc("mkt_ai_queue", { p_content: contentId, p_media: media, p_n: n, p_by: staff.full_name });
    if (qe) return json({ error: qe.message }, 400);
    const jobId = q.job_id as string;
    const reqBody = q.request as Record<string, unknown>;
    const fd = new FormData();
    fd.append("brand_id", brand);
    fd.append("text", String(reqBody.text).slice(0, 2000));
    fd.append("media_type", media);
    fd.append("n_posts", String(n));
    fd.append("input_language", "italian");
    fd.append("output_language", String(reqBody.output_language ?? "italian"));
    fd.append("color_palette_type", "brand");
    fd.append("model_version", "4");
    // v0.60: a network error (or timeout) used to leave the post stuck in "generating" forever
    let r: Response | null = null; let out: Record<string, unknown> = {};
    try {
      r = await fetch(`${PREDIS}/create_content/`, { method: "POST", headers: { Authorization: key }, body: fd, signal: AbortSignal.timeout(30000) });
      out = await r.json().catch(() => ({}));
    } catch (e) { out = { network_error: String(e) }; }
    const ids: string[] = Array.isArray(out.post_ids) ? (out.post_ids as unknown[]).map(String) : [];
    if (!r || !r.ok || ids.length === 0) {
      await db.from("mkt_ai_jobs").update({ status: "error", error: JSON.stringify(out).slice(0, 2000), response: out, completed_at: new Date().toISOString() }).eq("id", jobId);
      await db.from("mkt_content").update({ status: "idea" }).eq("id", contentId).eq("status", "generating");
      return json({ error: r ? "Predis.ai ha rifiutato la richiesta" : "Predis.ai non raggiungibile: riprova più tardi", detail: out, http: r?.status ?? 0 }, 502);
    }
    await db.from("mkt_ai_jobs").update({ status: "in_progress", external_ids: ids, response: out }).eq("id", jobId);
    return json({ ok: true, job_id: jobId, post_ids: ids, status: out.post_status ?? "inProgress" });
  }

  if (action === "sync") {
    const { data: jobs } = await db.from("mkt_ai_jobs").select("id, external_ids, request").eq("status", "in_progress").limit(20);
    let done = 0;
    for (const media of ["single_image", "carousel", "video"]) {
      const wanted = (jobs ?? []).filter((j) => (j.request?.media_type ?? "single_image") === media);
      if (!wanted.length) continue;
      let out: Record<string, unknown> = {};
      try {
        const r = await fetch(`${PREDIS}/get_posts/?brand_id=${encodeURIComponent(brand)}&media_type=${media}&page_n=1&items_n=20`, { headers: { Authorization: key }, signal: AbortSignal.timeout(30000) });
        out = await r.json().catch(() => ({}));
      } catch { continue; }
      for (const p of (out.posts ?? []) as Array<{ post_id: string; urls: string[]; caption: string }>) {
        if (!wanted.some((j) => (j.external_ids ?? []).includes(String(p.post_id)))) continue;
        if (!p.urls?.length) continue;
        const { data } = await db.rpc("mkt_ai_complete", { p_external_id: String(p.post_id), p_status: "completed", p_caption: p.caption ?? null, p_media: p.urls, p_raw: p });
        if (data?.ok) done++;
      }
    }
    return json({ ok: true, jobs_checked: jobs?.length ?? 0, completed: done });
  }
  return json({ error: "azione sconosciuta" }, 400);
});
