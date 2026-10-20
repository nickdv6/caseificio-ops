// notify — alerts on Telegram through @bubalina_avvisi_bot (v0.96, audit E-01; 13/10/2026)
//
// Two callers, one function (deploy with verify_jwt = false):
//   1. pg_cron → fabula.notify_tick() → POST { op: "dispatch" } when messages are due. The function takes them with
//      fabula.notify_claim() (each message is handed out once) and sends them; fabula.notify_mark() records the result.
//      Anyone calling dispatch can only make already-due messages go out a few seconds earlier, so it needs no key.
//   2. Telegram → POST updates (the webhook), recognised by the header X-Telegram-Bot-Api-Secret-Token, which must equal
//      TELEGRAM_WEBHOOK_SECRET:
//        /start <code>  → fabula.notify_link(): links this chat to the person who made the link in Configurazione → Utenti
//        /stop          → fabula.notify_unlink_chat()
//        button «👀 Ho visto» / «✋ Me ne occupo io» → fabula.notify_ack(); taking charge edits everyone's copy of the alert
// Secrets (Supabase → Edge Functions → Secrets): TELEGRAM_BOT_TOKEN (from @BotFather; never in the code, chat or repo) and
// TELEGRAM_WEBHOOK_SECRET (any long random string). The first dispatch registers the webhook by itself (setWebhook) and
// stores the bot's username in the setting notify.telegram_bot.

import { createClient } from "npm:@supabase/supabase-js@2";

const TOKEN = Deno.env.get("TELEGRAM_BOT_TOKEN") ?? "";
const HOOK_SECRET = Deno.env.get("TELEGRAM_WEBHOOK_SECRET") ?? "";
const SELF_URL = (Deno.env.get("SUPABASE_URL") ?? "").replace(/\/$/, "") + "/functions/v1/notify";
const API_BASE = Deno.env.get("TELEGRAM_API_BASE") ?? "https://api.telegram.org";   // only the local test points it elsewhere
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });

type TgResult = { ok: boolean; result?: any; description?: string; error_code?: number };
// Deno's fetch errors carry the full URL, which contains the token: it never reaches the database, the logs or a backup
const clean = (t: unknown) => (TOKEN ? String(t ?? "").split(TOKEN).join("<token>") : String(t ?? ""));
async function tg(method: string, body: Record<string, unknown>): Promise<TgResult> {
  try {
    const r = await fetch(`${API_BASE}/bot${TOKEN}/${method}`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
    const j: TgResult = await r.json().catch(() => ({ ok: false, description: `HTTP ${r.status}` }));
    if (!j.ok) j.description = clean(j.description);
    return j;
  } catch (e) {
    return { ok: false, description: clean(`network: ${(e as Error).message}`) };
  }
}
// the webhook is registered with this URL and this secret; a changed secret (rotated in the dashboard) registers it again
async function hookId(): Promise<string> {
  const h = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode("notify:" + HOOK_SECRET)));
  return SELF_URL + "#" + Array.from(h.slice(0, 6), (b) => b.toString(16).padStart(2, "0")).join("");
}
const plain = (html: string) => html.replace(/<[^>]+>/g, "").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
const buttons = (outboxId: string) => ({ inline_keyboard: [[{ text: "👀 Ho visto", callback_data: "s:" + outboxId }, { text: "✋ Me ne occupo io", callback_data: "t:" + outboxId }]] });

// register the webhook once per URL (and whenever the stored URL differs), learn the bot's username
async function ensureWebhook(fab: any) {
  const { data: rows } = await fab.from("settings").select("key, value").in("key", ["notify.webhook_url", "notify.telegram_bot"]);
  const st: Record<string, string> = Object.fromEntries((rows ?? []).map((r: any) => [r.key, r.value]));
  const id = await hookId();
  if (st["notify.webhook_url"] === id) return;
  const me = await tg("getMe", {});
  const hook = await tg("setWebhook", { url: SELF_URL, secret_token: HOOK_SECRET, allowed_updates: ["message", "callback_query"], drop_pending_updates: false });
  if (!hook.ok) { console.error("setWebhook", hook.description); return; }
  const up = [{ key: "notify.webhook_url", value: id, data_type: "text", description: "Indirizzo (e impronta del secret) registrati su Telegram per i pulsanti e /start: automatico, non modificare" }];
  if (me.ok && me.result?.username) up.push({ key: "notify.telegram_bot", value: me.result.username, data_type: "text", description: "Bot Telegram degli avvisi (nome utente, senza @): si aggiorna da solo al primo invio" });
  await fab.from("settings").upsert(up, { onConflict: "key" });
}

async function dispatch(fab: any) {
  await ensureWebhook(fab);
  let sent = 0, failed = 0;
  for (let round = 0; round < 4; round++) {                       // up to 100 messages per call
    const { data: items, error } = await fab.rpc("notify_claim", { p_limit: 25 });
    if (error) { console.error("notify_claim", clean(error.message)); break; }
    if (!items || !items.length) break;
    for (const it of items) {
      const base: Record<string, unknown> = { chat_id: it.chat_id, disable_web_page_preview: true };
      if (it.buttons) base.reply_markup = buttons(it.outbox_id);
      let r = await tg("sendMessage", { ...base, text: it.text, parse_mode: "HTML" });
      if (!r.ok && /parse entities/i.test(r.description ?? "")) r = await tg("sendMessage", { ...base, text: plain(it.text) });   // never lose an alert to a formatting error
      await fab.rpc("notify_mark", { p_id: it.id, p_ok: !!r.ok, p_message_id: r.ok ? r.result?.message_id ?? null : null, p_error: r.ok ? null : `${r.error_code ?? ""} ${r.description ?? "errore"}`.trim() });
      r.ok ? sent++ : failed++;
    }
  }
  return { sent, failed };
}

async function onUpdate(fab: any, u: any) {
  if (u.callback_query) {
    const cq = u.callback_query; const [k, id] = String(cq.data ?? "").split(":");
    const chatId = cq.message?.chat?.id;
    let toast = "Ok";
    if (chatId && /^[0-9a-f-]{36}$/i.test(id ?? "")) {
      const { data: r, error } = await fab.rpc("notify_ack", { p_chat_id: chatId, p_outbox: id, p_kind: k === "t" ? "take" : "seen" });
      if (error) { console.error("notify_ack", clean(error.message)); toast = "Errore: riprova"; }
      else {
        toast = r?.toast ?? "Ok";
        for (const e of r?.edits ?? []) {
          await tg("editMessageText", { chat_id: e.chat_id, message_id: e.message_id, text: e.text, parse_mode: "HTML", disable_web_page_preview: true, reply_markup: { inline_keyboard: [] } });
        }
      }
    }
    await tg("answerCallbackQuery", { callback_query_id: cq.id, text: toast });
    return;
  }
  const m = u.message;
  if (!m || !m.chat || m.chat.type !== "private" || typeof m.text !== "string") return;
  const text = m.text.trim(); const chatId = m.chat.id;
  const say = (t: string) => tg("sendMessage", { chat_id: chatId, text: t, parse_mode: "HTML", disable_web_page_preview: true });
  const start = text.match(/^\/start(?:@\w+)?(?:\s+([0-9a-f]{8,64}))?$/i);
  if (start) {
    if (!start[1]) return void await say("Ciao! Per ricevere gli avvisi del caseificio apri il collegamento che trovi in <b>Configurazione → Utenti → Avvisi Telegram</b> (vale 24 ore).");
    const name = [m.from?.first_name, m.from?.last_name].filter(Boolean).join(" ") || m.from?.username || "";
    const { data: r, error } = await fab.rpc("notify_link", { p_code: start[1].toLowerCase(), p_chat_id: chatId, p_tg_name: name });
    if (error || !r?.ok) return void await say("Collegamento non valido o scaduto: creane uno nuovo da <b>Configurazione → Utenti → Avvisi Telegram</b>.");
    const T: Record<string, string> = { food_safety: "sicurezza alimentare (a qualsiasi ora)", infra: "sistema (backup, bot, tablet)", decisions: "decisioni da prendere" };
    return void await say(`✅ Collegato: <b>${String(r.full_name ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")}</b>.\nQui arriveranno gli avvisi: ${(r.topics ?? []).map((x: string) => T[x] ?? x).join(", ")}.\n` +
      `Le decisioni non arrivano dalle ${r.quiet_from} alle ${r.quiet_to}; la sicurezza alimentare sì.\nSotto ogni avviso: «✋ Me ne occupo io» avvisa gli altri che ci pensi tu.\nPer non ricevere più nulla scrivi /stop.`);
  }
  if (/^\/stop\b/i.test(text)) {
    const { data: ok } = await fab.rpc("notify_unlink_chat", { p_chat_id: chatId });
    return void await say(ok ? "Scollegato: non riceverai più avvisi. Per ricollegarti usa un nuovo collegamento da Configurazione → Utenti." : "Questo Telegram non era collegato.");
  }
  await say("Questo bot manda solo gli avvisi del caseificio. Rispondi con i pulsanti sotto ogni avviso.");
}

function same(a: string, b: string) {             // v1.10: constant time for keys of the same length (as shopify-sync)
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  if (!x.length || x.length !== y.length) return false;
  let d = 0;
  for (let i = 0; i < x.length; i++) d |= x[i] ^ y[i];
  return d === 0;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ ok: true, service: "notify" });
  if (!TOKEN || !HOOK_SECRET) return json({ error: "TELEGRAM_BOT_TOKEN o TELEGRAM_WEBHOOK_SECRET mancanti nei secrets della funzione" }, 500);
  const fab = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } }).schema("fabula");
  const hook = req.headers.get("x-telegram-bot-api-secret-token");
  if (hook !== null) {
    if (!same(hook, HOOK_SECRET)) return new Response("forbidden", { status: 403 });
    try { await onUpdate(fab, await req.json()); } catch (e) { console.error("update", clean((e as Error).message)); }
    return new Response("ok");                                    // always 200: Telegram would otherwise resend the same update
  }
  try { return json({ ok: true, ...(await dispatch(fab)) }); }
  catch (e) { console.error("dispatch", clean((e as Error).message)); return json({ error: "dispatch failed" }, 500); }
});
