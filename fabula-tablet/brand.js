/* Company name and details from settings company.* (Configurazione → Azienda), v0.48.
   Every page header and title that shows the company name reads it from here — never hardcode it in a page:
   - <span data-brand="name">…</span> gets company.name; any other company.* field works too (data-brand="address", "phone", …)
   - document.title keeps its page part after " · ": "<nome> · Console"; pages with a dynamic title call BRAND.title('DDT-…')
   The last values are remembered on the device, so the right name shows on the login screen and offline.
   PERM.load(sb) refreshes them after login; admin.js updates them the moment a company.* setting is saved. */
(() => {
  const DEFAULT = { name: 'La Perla del Cilento' }, KEY = 'fabula_company';
  const clean = o => Object.fromEntries(Object.entries(o || {}).map(([k, v]) => [k, String(v ?? '').trim()]).filter(([, v]) => v));
  let data = { ...DEFAULT };
  try { Object.assign(data, clean(JSON.parse(localStorage.getItem(KEY) || '{}'))); } catch {}
  let page = null;   // page part of the <title>, captured on first apply
  const BRAND = window.BRAND = {
    get data() { return { ...data }; },
    get name() { return data.name || DEFAULT.name; },
    field(f) { return f === 'name' ? this.name : (data[f] || ''); },
    title(part) { if (part !== undefined) page = part || ''; document.title = page ? `${this.name} · ${page}` : this.name; },
    apply(root = document) {
      root.querySelectorAll('[data-brand]').forEach(el => { const v = this.field(el.dataset.brand); if (v) el.textContent = v; });
      if (page === null) { const t = document.title, i = t.indexOf(' · '); page = i >= 0 ? t.slice(i + 3) : ''; }
      this.title();
    },
    // replace = true: values are the full company.* set (missing/empty fields drop back to defaults)
    set(values, replace = false) {
      const v = Object.fromEntries(Object.entries(values || {}).map(([k, x]) => [k.replace(/^company\./, ''), String(x ?? '').trim()]));
      data = replace ? { ...DEFAULT, ...clean(v) } : { ...data, ...v };
      Object.keys(data).forEach(k => { if (!data[k]) { if (DEFAULT[k]) data[k] = DEFAULT[k]; else delete data[k]; } });
      try { localStorage.setItem(KEY, JSON.stringify(data)); } catch {}
      this.apply(); return this.data;
    },
    async load(sb) {
      try { const { data: rows, error } = await sb.from('settings').select('key, value').like('key', 'company.%');
        if (!error && rows) this.set(Object.fromEntries(rows.map(r => [r.key, r.value])), true); } catch {}
      return this.data;
    }
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => BRAND.apply()); else BRAND.apply();
})();
