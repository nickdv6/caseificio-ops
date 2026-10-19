// Supabase project "Caseificio" (org AG AI, eu-central-1). Publishable key is safe to ship to browsers.
window.FABULA_CONFIG = {
  supabaseUrl: "https://ojkquhzaeypsphncjqwy.supabase.co",
  supabaseKey: "sb_publishable_Kl7c4NqV44tjDYs6IbpA0Q_S5ENoKq3",
  // each tablet can name itself once: open the app with ?device=tablet-2 (remembered on that device)
  device: (() => { try { const q = new URLSearchParams(location.search).get("device"); if (q) localStorage.setItem("fabula_device", q); return localStorage.getItem("fabula_device") || "tablet-1"; } catch { return "tablet-1"; } })()
};

// v1.08b: the app's address is https://app.bubalina.it (GitHub Pages, published by every release). A page opened on the old Netlify
// address goes to the same page there (path, ?query and #hash kept: the Masseria's QR and the trade links keep working), but only:
//   * when this address has nothing left to send (records, refused saves still to redo or discard, photos): they live only here;
//   * when the new address answers with the v1.08b app or later (so nothing moves before the release is approved, or offline);
//   * when the page starts: never in the middle of someone's work. A tablet left open shows a bar instead, with what is still
//     waiting, and a button to move when everything is sent; it moves by itself the next time it starts.
// The tablet carries its name and id (?device=, ?device_uid=), so the office keeps seeing the same tablet. Each address has its
// own sign-in: people sign in once on the new one.
window.FABULA_HOME = "https://app.bubalina.it";
(function moveToNewHome() {
  const HOME = window.FABULA_HOME, MIN_VERSION = 75;        // perla-v75 = v1.08b, the first version that knows ?device_uid=
  const read = k => { try { return localStorage.getItem(k); } catch { return null; } };
  const list = k => { try { const v = JSON.parse(read(k) || "[]"); return Array.isArray(v) ? v : []; } catch { return []; } };

  if (!/\.netlify\.app$/i.test(location.hostname)) {
    // on the new address: a tablet arriving from the old one keeps its id, unless this address already has its own work waiting
    try {
      const q = new URLSearchParams(location.search), uid = q.get("device_uid");
      if (uid !== null) {
        const here = read("perla_device_uid"), busy = list("fabula_queue").length + list("fabula_failed").length > 0;
        if (/^[A-Za-z0-9-]{8,64}$/.test(uid) && (!here || !busy)) localStorage.setItem("perla_device_uid", uid);
        q.delete("device_uid");
        history.replaceState(history.state, "", location.pathname + (q.toString() ? "?" + q : "") + location.hash);
      }
    } catch { /* storage or history blocked: the tablet keeps or gets its own id */ }
    return;
  }

  const photos = () => new Promise(res => {
    const done = n => { clearTimeout(t); res(n); };
    const t = setTimeout(() => res(-1), 3000);               // a database that never answers counts as «can't tell»: wait
    try {
      const r = indexedDB.open("perla_photos", 1);
      r.onupgradeneeded = () => r.result.createObjectStore("p", { keyPath: "id" });
      r.onerror = () => done(-1);
      r.onsuccess = () => {
        try { const c = r.result.transaction("p", "readonly").objectStore("p").count(); c.onsuccess = () => { done(c.result); r.result.close(); }; c.onerror = () => done(-1); }
        catch { done(-1); }
      };
    } catch { done(window.indexedDB ? -1 : 0); }
  });
  const waiting = async () => {
    const p = await photos();
    return { records: list("fabula_queue").length, refused: list("fabula_failed").length, photos: p, total: list("fabula_queue").length + list("fabula_failed").length + (p < 0 ? 1 : p) };
  };
  const ready = async () => {                              // the new address answers with v1.08b or later
    if (navigator.onLine === false) return false;
    try {
      const r = await fetch(HOME + "/sw.js", { cache: "no-store" });
      const m = r.ok && (await r.text()).match(/perla-v(\d+)/);
      return !!m && Number(m[1]) >= MIN_VERSION;
    } catch { return false; }
  };
  const target = () => {
    const u = new URL(HOME + "/" + location.pathname.replace(/^[\/\\]+/, "") + location.search + location.hash);
    if (u.origin !== HOME) return null;
    const dev = read("fabula_device"), uid = read("perla_device_uid");
    if (dev && !u.searchParams.get("device")) u.searchParams.set("device", dev);
    if (uid) u.searchParams.set("device_uid", uid);
    return u.toString();
  };
  const go = async () => {
    const to = target();
    if (!to) return;
    // nothing is left here: the old address keeps no copy of the app (its service worker would answer offline with the old one)
    const clean = (async () => {
      try { if (navigator.serviceWorker) for (const r of await navigator.serviceWorker.getRegistrations()) await r.unregister(); } catch {}
      try { if (window.caches) for (const k of await caches.keys()) await caches.delete(k); } catch {}
    })();
    await Promise.race([clean, new Promise(r => setTimeout(r, 1500))]);
    location.replace(to);
  };

  const tablet = /\/(index\.html)?$/.test(location.pathname);
  let bar = null;
  const show = (w, ok) => {
    const put = () => {
      if (!bar) {
        bar = document.createElement("div");
        bar.id = "move-home";
        bar.setAttribute("role", "status");
        bar.style.cssText = "position:fixed;left:0;right:0;bottom:0;z-index:99999;padding:10px 16px;background:#1f3a5f;color:#fff;font:15px/1.4 system-ui,sans-serif;display:flex;gap:12px;align-items:center;justify-content:center;flex-wrap:wrap";
        bar.innerHTML = '<span></span><button type="button" style="font:inherit;padding:6px 14px;border-radius:6px;border:0;background:#fff;color:#1f3a5f">Passa al nuovo indirizzo</button>';
        bar.querySelector("button").onclick = async () => { if (!(await update())) return; const n = await waiting(); if (n.total === 0) go(); };
        document.body.appendChild(bar);
      }
      const parts = [];
      if (w.records) parts.push(w.records === 1 ? "1 registrazione da inviare" : `${w.records} registrazioni da inviare`);
      if (w.refused) parts.push(w.refused === 1 ? "1 salvataggio rifiutato da rifare o scartare" : `${w.refused} salvataggi rifiutati da rifare o scartare`);
      if (w.photos > 0) parts.push(w.photos === 1 ? "1 foto da inviare" : `${w.photos} foto da inviare`);
      if (w.photos < 0) parts.push("foto da controllare (chiudi e riapri l'app)");
      bar.querySelector("span").textContent = parts.length
        ? `L'app ha un nuovo indirizzo: app.bubalina.it. Prima di passare, su questo tablet: ${parts.join(", ")}. L'app invia da sola quando c'è rete e qualcuno ha fatto l'accesso.`
        : "L'app ha un nuovo indirizzo: app.bubalina.it. Qui non resta niente da inviare: passa quando hai finito (alla prossima apertura passa da sola).";
      const b = bar.querySelector("button");
      b.disabled = !ok;
      b.style.opacity = ok ? "1" : ".5";
    };
    if (document.body) put(); else document.addEventListener("DOMContentLoaded", put, { once: true });
  };
  const update = async () => {                              // the bar shows what is waiting; true = nothing waiting and the new address ready
    const w = await waiting();
    const ok = w.total === 0 && await ready();
    if (w.total > 0 || ok) show(w, ok);
    return ok;
  };
  const tick = async () => {
    const w = await waiting();
    if (w.records && navigator.onLine !== false) window.dispatchEvent(new Event("online"));   // nudges the app's own sending (app.js)
    await update();
    setTimeout(tick, w.total > 0 ? 10000 : 60000);
  };

  (async () => {
    const w = await waiting();
    if (w.total === 0 && await ready()) return go();       // the page has just started: nothing to lose, move now
    if (tablet) tick();                                      // the tablet left open: say what is waiting, move on a tap
    // other pages (Console, labels…) with something waiting on this tablet, or the new address not ready: stay, as before
  })();
})();
