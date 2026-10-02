// La Perla · Predis.ai webhook. Configure in Predis → Pricing & Account → Rest API:
//   https://ojkquhzaeypsphncjqwy.supabase.co/functions/v1/predis-webhook?token=<PREDIS_WEBHOOK_TOKEN>
// Predis sends { status: "completed"|"error", post_id, caption, generated_media: [...], brand_id } exactly once per post.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

Deno.serve(async (req) => {
  const token = Deno.env.get("PREDIS_WEBHOOK_TOKEN") ?? "";
  const given = new URL(req.url).searchParams.get("token") ?? "";
  if (!token || given !== token) return new Response("forbidden", { status: 403 });
  if (req.method !== "POST") return new Response("ok");
  const p = await req.json().catch(() => null);
  if (!p?.post_id) return new Response("bad payload", { status: 400 });
  // generated_media can be a list of URLs or of objects with a url field
  const media = (Array.isArray(p.generated_media) ? p.generated_media : [])
    .map((m: unknown) => typeof m === "string" ? m : (m as Record<string, string>)?.url ?? (m as Record<string, string>)?.media_url)
    .filter(Boolean);
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { db: { schema: "fabula" } });
  const { data, error } = await db.rpc("mkt_ai_complete", {
    p_external_id: String(p.post_id), p_status: p.status === "completed" ? "completed" : "error",
    p_caption: p.caption ?? null, p_media: media, p_raw: p,
  });
  if (error) return new Response(error.message, { status: 500 });
  return new Response(JSON.stringify(data), { headers: { "Content-Type": "application/json" } });
});
