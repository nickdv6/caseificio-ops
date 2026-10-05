// backup-export — off-database copy of the La Perla ops data (v0.43, 03/10/2026)
//
// Called by pg_cron through fabula.backup_export_call(mode):
//   mode "latest"  every 2 h on working days → documents/backups/latest.json.gz (overwritten)
//   mode "nightly" every evening              → documents/backups/daily/YYYY-MM-DD.json.gz (kept 90 days)
// Every fabula base table is exported (new tables are picked up automatically).
// Each run is logged in fabula.agent_runs as agent "backup_export", so the bot
// heartbeat / watchdog and the go-live board notice when it stops.
// Auth: x-backup-token header, checked against the Vault secret "backup_export_token".
// Restore: tools/go-live/BACKUP-RESTORE.md in the repo.
// v0.61: mode "fetch" { path } returns an existing backup file (base64 + sha256) to the caller, same token.
//   The database calls it with fabula.backup_fetch_call(path); the answer lands in net._http_response,
//   which is how a restore drill reads the real file without anyone handling the token or a service key.

import { createClient } from "npm:@supabase/supabase-js@2";

const BUCKET = "documents";
const PAGE = 1000;
const KEEP_DAYS = 90;

Deno.serve(async (req: Request) => {
  const sb = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );
  const fab = sb.schema("fabula");

  const token = req.headers.get("x-backup-token") ?? "";
  const { data: ok } = await fab.rpc("backup_check_token", { p_token: token });
  if (ok !== true) return json({ error: "forbidden" }, 403);

  let mode = "latest";
  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* no body: latest */ }
  if (body?.mode === "nightly") mode = "nightly";

  if (body?.mode === "fetch") {                       // v0.61: hand back a stored backup file (read-only, nothing logged)
    const path = String(body.path ?? "backups/latest.json.gz");
    if (!/^backups\/(latest|daily\/\d{4}-\d{2}-\d{2})\.json\.gz$/.test(path)) return json({ ok: false, error: "path non valido" }, 400);
    const { data, error } = await sb.storage.from(BUCKET).download(path);
    if (error || !data) return json({ ok: false, error: error?.message ?? "file non trovato", path }, 404);
    const bytes = new Uint8Array(await data.arrayBuffer());
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
    return json({ ok: true, path, bytes: bytes.byteLength, sha256: [...digest].map((b) => b.toString(16).padStart(2, "0")).join(""), b64: toBase64(bytes) });
  }

  const { data: run } = await fab.from("agent_runs")
    .insert({ agent: "backup_export", status: "running", summary: `backup ${mode} in corso` })
    .select("id").single();
  const runId = run?.id;

  try {
    const { data: tables, error: tErr } = await fab.rpc("backup_table_list");
    if (tErr) throw new Error("table list: " + tErr.message);
    // v0.60: pages are read in a stable order (primary key, or every column when a table has none) so no row is missed or doubled
    const { data: keys } = await fab.rpc("backup_table_keys");
    const orderOf = (t: string): string[] => ((keys ?? {}) as Record<string, string[]>)[t] ?? [];

    const out: Record<string, unknown[]> = {};
    const counts: Record<string, number> = {};
    for (const t of tables as string[]) {
      const rows: unknown[] = [];
      for (let from = 0; ; from += PAGE) {
        let q = fab.from(t).select("*");
        for (const c of orderOf(t)) q = q.order(c, { ascending: true, nullsFirst: true });
        const { data, error } = await q.range(from, from + PAGE - 1);
        if (error) throw new Error(`${t}: ${error.message}`);
        rows.push(...(data ?? []));
        if (!data || data.length < PAGE) break;
      }
      out[t] = rows;
      counts[t] = rows.length;
    }

    const exportedAt = new Date();
    const romeDay = new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Rome" }).format(exportedAt);
    const payload = JSON.stringify({
      format: "la-perla-backup/1",
      project: "ojkquhzaeypsphncjqwy",
      schema: "fabula",
      mode,
      exported_at: exportedAt.toISOString(),
      rome_day: romeDay,
      counts,
      tables: out,
    });
    const gz = await gzip(payload);

    const paths = ["backups/latest.json.gz"];
    if (mode === "nightly") paths.push(`backups/daily/${romeDay}.json.gz`);
    for (const p of paths) {
      const { error } = await sb.storage.from(BUCKET).upload(p, gz, { contentType: "application/gzip", upsert: true });
      if (error) throw new Error(`upload ${p}: ${error.message}`);
    }

    let pruned = 0;
    if (mode === "nightly") {
      const cutoff = new Date(exportedAt.getTime() - KEEP_DAYS * 86400000).toISOString().slice(0, 10);
      const { data: files } = await sb.storage.from(BUCKET).list("backups/daily", { limit: 1000 });
      const old = (files ?? []).map((f) => f.name).filter((n) => /^\d{4}-\d{2}-\d{2}\.json\.gz$/.test(n) && n.slice(0, 10) < cutoff);
      if (old.length) {
        await sb.storage.from(BUCKET).remove(old.map((n) => `backups/daily/${n}`));
        pruned = old.length;
      }
    }

    const totalRows = Object.values(counts).reduce((a, b) => a + b, 0);
    const kb = Math.round(gz.byteLength / 1024);
    const summary = `backup ${mode}: ${Object.keys(counts).length} tabelle, ${totalRows} righe, ${kb} KB → ${paths.join(", ")}` + (pruned ? `, ${pruned} vecchi rimossi` : "");
    if (runId) {
      await fab.from("agent_runs").update({
        status: "ok", finished_at: new Date().toISOString(), summary,
        details: { mode, paths, kb, total_rows: totalRows, counts, pruned },
      }).eq("id", runId);
    }
    return json({ ok: true, summary });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    if (runId) {
      await fab.from("agent_runs").update({
        status: "error", finished_at: new Date().toISOString(), error: msg, summary: `backup ${mode} fallito`,
      }).eq("id", runId);
    }
    return json({ ok: false, error: msg }, 500);
  }
});

function toBase64(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}

async function gzip(text: string): Promise<Uint8Array> {
  const stream = new Blob([text]).stream().pipeThrough(new CompressionStream("gzip"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}
