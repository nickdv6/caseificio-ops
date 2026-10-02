// Supabase project "Caseificio" (org AG AI, eu-central-1). Publishable key is safe to ship to browsers.
window.FABULA_CONFIG = {
  supabaseUrl: "https://ojkquhzaeypsphncjqwy.supabase.co",
  supabaseKey: "sb_publishable_Kl7c4NqV44tjDYs6IbpA0Q_S5ENoKq3",
  // each tablet can name itself once: open the app with ?device=tablet-2 (remembered on that device)
  device: (() => { try { const q = new URLSearchParams(location.search).get("device"); if (q) localStorage.setItem("fabula_device", q); return localStorage.getItem("fabula_device") || "tablet-1"; } catch { return "tablet-1"; } })()
};
