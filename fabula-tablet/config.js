// Supabase project "Caseificio" (org AG AI, eu-central-1). Publishable key is safe to ship to browsers.
window.FABULA_CONFIG = {
  supabaseUrl: "https://ojkquhzaeypsphncjqwy.supabase.co",
  supabaseKey: "sb_publishable_Kl7c4NqV44tjDYs6IbpA0Q_S5ENoKq3",
  // each tablet can name itself once: open the app with ?device=tablet-2 (remembered on that device)
  device: (() => { try { const q = new URLSearchParams(location.search).get("device"); if (q) localStorage.setItem("fabula_device", q); return localStorage.getItem("fabula_device") || "tablet-1"; } catch { return "tablet-1"; } })()
};

// v1.08b: the app's address is https://app.bubalina.it (GitHub Pages, published by every release). Every page opened on the old
// Netlify address goes to the same page there (path, ?query and #hash kept: the Masseria's QR and the trade links still work).
// The tablet (index.html) first waits until nothing is waiting to be sent from this address (records, refused saves not yet
// reported, photos) and carries its name and id (?device=, ?device_uid=), so the office keeps seeing the same tablet. Each address
// keeps its own sign-in: people sign in once on the new one.
window.FABULA_HOME = "https://app.bubalina.it";
(function moveToNewHome() {
  const HOME = window.FABULA_HOME;
  const read = k => { try { return localStorage.getItem(k); } catch { return null; } };
  if (!/\.netlify\.app$/i.test(location.hostname)) {
    // on the new address: a tablet that arrives from the old one keeps its id (only when it has none yet here)
    try {
      const q = new URLSearchParams(location.search), uid = q.get("device_uid");
      if (uid !== null) {
        if (/^[A-Za-z0-9-]{8,64}$/.test(uid) && !read("perla_device_uid")) localStorage.setItem("perla_device_uid", uid);
        q.delete("device_uid");
        history.replaceState(history.state, "", location.pathname + (q.toString() ? "?" + q : "") + location.hash);
      }
    } catch { /* storage or history blocked: the tablet gets a new id */ }
    return;
  }
  const list = k => { try { return JSON.parse(read(k) || "[]") || []; } catch { return []; } };
  const photos = () => new Promise(res => {
    try {
      const r = indexedDB.open("perla_photos", 1);
      r.onupgradeneeded = () => r.result.createObjectStore("p", { keyPath: "id" });
      r.onerror = () => res(0);
      r.onsuccess = () => {
        try { const c = r.result.transaction("p", "readonly").objectStore("p").count(); c.onsuccess = () => { res(c.result); r.result.close(); }; c.onerror = () => res(0); }
        catch { res(0); }
      };
    } catch { res(0); }
  });
  const waiting = async () => {
    const reported = new Set(list("perla_failed_reported"));
    return list("fabula_queue").length + list("fabula_failed").filter(f => !(f && reported.has(f.qid))).length + await photos();
  };
  const go = async () => {
    const u = new URL(location.pathname + location.search + location.hash, HOME);
    const dev = read("fabula_device"), uid = read("perla_device_uid");
    if (dev && !u.searchParams.get("device")) u.searchParams.set("device", dev);
    if (uid) u.searchParams.set("device_uid", uid);
    // the old address keeps no copy of the app (its service worker would otherwise answer offline with the old version)
    const clean = (async () => {
      try { if (navigator.serviceWorker) for (const r of await navigator.serviceWorker.getRegistrations()) await r.unregister(); } catch {}
      try { if (window.caches) for (const k of await caches.keys()) await caches.delete(k); } catch {}
    })();
    await Promise.race([clean, new Promise(r => setTimeout(r, 1500))]);
    location.replace(u.toString());
  };
  const tablet = /\/(index\.html)?$/.test(location.pathname);
  if (!tablet) { go(); return; }
  let bar = null;
  const show = n => {
    const put = () => {
      if (!bar) {
        bar = document.createElement("div");
        bar.id = "move-home";
        bar.setAttribute("role", "status");
        bar.style.cssText = "position:fixed;top:0;left:0;right:0;z-index:99999;padding:10px 16px;background:#1f3a5f;color:#fff;font:15px/1.4 system-ui,sans-serif;text-align:center";
        document.body.appendChild(bar);
      }
      bar.textContent = `L'app ha un nuovo indirizzo: app.bubalina.it. Prima invio quello che è ancora in attesa (${n}), poi passo da solo. Non chiudere l'app.`;
    };
    if (document.body) put(); else document.addEventListener("DOMContentLoaded", put, { once: true });
  };
  const tick = async () => {
    const n = await waiting();
    if (n === 0) return go();
    show(n);
    setTimeout(tick, 10000);           // the app keeps sending by itself (app.js): look again in 10 s
  };
  tick();
})();
