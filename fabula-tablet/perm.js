/* La Perla · access profiles (v0.37). Every page calls PERM.load(sb) after login: my_permissions() returns the person's profile,
   the level per area (0 nessuno · 1 vede · 2 registra · 3 gestisce) and which pages they use. The database enforces the same rules (RLS);
   this file only hides what the person can't use. */
window.PERM = {
  data: null,
  HOME: { tablet: 'index.html', console: 'console.html', haccp: 'haccp.html', marketing: 'marketing.html', vendite: 'vendite.html', admin: 'admin.html' },
  async load(sb) {
    let { data } = await sb.rpc('my_permissions');
    if (data && !data.staff_id) { await sb.rpc('claim_staff_profile'); ({ data } = await sb.rpc('my_permissions')); }
    this.data = data || null; if (window.BRAND) BRAND.load(sb); return this.data;
  },
  level(a) { return Number((this.data && this.data.areas && this.data.areas[a]) || 0); },
  can(a, l = 1) { return this.level(a) >= l; },
  page(p) { return !!(this.data && this.data.pages && this.data.pages[p]); },
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
  notLinked(email) { return `L'account ${email} non è collegato a nessuna persona attiva. Chiedi al titolare di invitarti da Configurazione → Utenti e ruoli.`; },
  notForProfile() { return `Il profilo "${(this.data && this.data.role_name) || '?'}" non usa questa pagina.`; },
};
