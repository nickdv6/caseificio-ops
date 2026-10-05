/* La Perla · access profiles (v0.37). Every page calls PERM.load(sb) after login: my_permissions() returns the person's profile,
   the level per area (0 nessuno · 1 vede · 2 registra · 3 gestisce) and which pages they use. The database enforces the same rules (RLS);
   this file only hides what the person can't use. */
window.PERM = {
  data: null,
  HOME: { tablet: 'index.html', console: 'console.html', haccp: 'haccp.html', marketing: 'marketing.html', vendite: 'vendite.html', admin: 'admin.html' },
  offline: false,
  // v0.59: the last profile seen on this device is kept per user, so the tablet still opens when the network is down.
  // Only used when the database can't be reached; the database keeps enforcing the real rules when the records are sent.
  CACHE_KEY: 'perm.cache.v1',
  storedUser() {
    try {
      for (let i = 0; i < localStorage.length; i++) {
        const k = localStorage.key(i);
        if (/^sb-.*-auth-token$/.test(k)) { const v = JSON.parse(localStorage.getItem(k) || 'null'); const u = v && (v.user || (v.currentSession && v.currentSession.user)); if (u && u.id) return u; }
      }
    } catch (e) { /* storage blocked */ }
    return null;
  },
  // offline, supabase-js retries an expired login for ~50 s before giving up, and every query waits behind it:
  // cap each startup call so the tablet opens in seconds and falls back to the saved profile
  TIMEOUT_MS: 6000,
  timeout(p, ms = this.TIMEOUT_MS) { return Promise.race([Promise.resolve(p), new Promise(res => setTimeout(() => res({ data: null, error: { name: 'Timeout', message: 'timeout: nessuna risposta dal server' } }), ms))]); },
  async session(sb) { const r = await this.timeout(sb.auth.getSession().catch(e => ({ data: { session: null }, error: e })), navigator.onLine ? 2500 : 0); return (r && r.data && r.data.session) || null; },
  isNetworkError(e) { return !!e && (!navigator.onLine || /fetch|network|load failed|timeout|offline/i.test(String(e.message || e)) || e.status === 0 || e.name === 'AuthRetryableFetchError'); },
  cached(uid) { try { return uid ? (JSON.parse(localStorage.getItem(this.CACHE_KEY) || '{}')[uid] || null) : null; } catch (e) { return null; } },
  remember(uid, data) { try { if (!uid) return; const all = JSON.parse(localStorage.getItem(this.CACHE_KEY) || '{}'); all[uid] = { ...data, cached_at: new Date().toISOString() }; localStorage.setItem(this.CACHE_KEY, JSON.stringify(all)); } catch (e) { /* storage full or blocked */ } },
  async load(sb) {
    const session = await this.session(sb);
    const uid = (session && session.user && session.user.id) || (this.storedUser() || {}).id || null;
    const ask = () => this.timeout(sb.rpc('my_permissions').then(x => x, e => ({ data: null, error: e })), !navigator.onLine ? 0 : session ? 10000 : 3000);
    let r = await ask();
    if (!r.error && r.data && !r.data.staff_id) { await this.timeout(sb.rpc('claim_staff_profile').then(x => x, () => null)); r = await ask(); }
    if (r.error && (this.isNetworkError(r.error) || !session)) {
      const c = this.cached(uid);
      this.offline = true; this.lastError = r.error; this.data = c ? { ...c, offline: true } : null;
      return this.data;
    }
    this.offline = false; this.lastError = r.error || null; this.data = r.data || null;
    if (this.data && this.data.staff_id) this.remember(uid, this.data);
    if (window.BRAND) BRAND.load(sb); return this.data;
  },
  offlineFirstLogin() { return 'Nessuna connessione e questo tablet non ha ancora un accesso salvato per questo account. Collegati a internet una volta, poi funziona anche offline.'; },
  level(a) { return Number((this.data && this.data.areas && this.data.areas[a]) || 0); },
  can(a, l = 1) { return this.level(a) >= l; },
  page(p) { return !!(this.data && this.data.pages && this.data.pages[p]); },
  // v0.56: an update/delete blocked by row-level security "succeeds" with 0 rows. Add .select('<key>') and pass the result here.
  NOT_SAVED: 'Non salvato: il tuo profilo non può modificare questi dati, oppure la riga non esiste più. Ricarica la pagina.',
  changed(r) { if (r.error) throw r.error; if (!Array.isArray(r.data) || !r.data.length) throw new Error(this.NOT_SAVED); return r.data; },
  isAdmin() { return !!(this.data && this.data.can_manage_users); },
  approvalArea(a) {
    const k = a.kind, t = (a.payload && a.payload.type) || '';
    if (k === 'purchase_order') return 'acquisti'; if (k === 'payment' || k === 'invoice_coding') return 'finanza';
    if (k === 'price_change') return 'vendite'; if (k === 'shopify_publish' || k === 'outreach_email') return 'marketing'; if (k === 'dop_declaration') return 'haccp';
    if (['milk_plan', 'recipe_update', 'process_preset'].includes(t)) return 'produzione';
    if (/^(content|mkt|local|campaign|post)/.test(t)) return 'marketing'; if (/^(invoice|payment|bank)/.test(t)) return 'finanza'; if (/^(haccp|lot|recall|nc)/.test(t)) return 'haccp';
    return 'sistema';
  },
  // hide links to pages the profile doesn't use: <a data-page="haccp">
  navLinks(root = document) { root.querySelectorAll('[data-page]').forEach(el => { el.hidden = !this.page(el.dataset.page); }); },
  deny(sb, msg) {
    const home = this.data && this.data.home && this.page(this.data.home) ? this.HOME[this.data.home] : null;
    const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
    document.body.innerHTML = `<div style="max-width:440px;margin:14vh auto;padding:0 16px;font:16px/1.5 system-ui,sans-serif;color:#161514">
      <h2 style="font-weight:600">Accesso non abilitato</h2><p>${esc(msg)}</p>
      ${home ? `<p><a href="${home}">Vai alla tua pagina</a></p>` : ''}<p><a href="#" id="perm-out">Esci e cambia account</a></p></div>`;
    document.body.style.background = '#f6f4ef';
    document.getElementById('perm-out').onclick = async e => { e.preventDefault(); await sb.auth.signOut(); location.reload(); };
  },
  notLinked(email) { return `L'account ${email} non è collegato a nessuna persona attiva. Chiedi al titolare di invitarti da Configurazione → Utenti e accessi.`; },
  notForProfile() { return `Il profilo "${(this.data && this.data.role_name) || '?'}" non usa questa pagina.`; },
};
