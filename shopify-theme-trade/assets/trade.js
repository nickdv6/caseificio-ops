/* Per i professionisti · portale (v0.83). Reads/writes through the Supabase function trade-portal with the customer's key
   (metafield trade.portal_token, rendered by Liquid only for the logged-in customer). All rules (delivery days, windows,
   minimum, cut-off, tiers, recurring discount) come from the server state: nothing is hard-coded here. */
(function () {
  var root = document.getElementById('trade-app'); if (!root) return;
  var EDGE = root.dataset.edge, T = root.dataset.token, ORDERS = root.dataset.ordersUrl;
  var S = null, tab = 'piano', banner = null, editing = {};
  var WD = ['', 'Lunedì', 'Martedì', 'Mercoledì', 'Giovedì', 'Venerdì', 'Sabato', 'Domenica'], WDS = ['', 'Lun', 'Mar', 'Mer', 'Gio', 'Ven', 'Sab', 'Dom'];
  var esc = function (s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); };
  var eur = function (n) { return new Intl.NumberFormat('it-IT', { style: 'currency', currency: 'EUR' }).format(Number(n || 0)); };
  var kg = function (n) { return Number(n || 0).toLocaleString('it-IT', { maximumFractionDigits: 2 }) + ' kg'; };
  var dIt = function (iso, long) { var d = new Date(iso + 'T12:00:00'); return d.toLocaleDateString('it-IT', long ? { weekday: 'long', day: 'numeric', month: 'long' } : { weekday: 'short', day: '2-digit', month: '2-digit' }); };
  var todayISO = function () { return new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Rome' }); };
  var addDays = function (iso, n) { var d = new Date(iso + 'T12:00:00'); d.setDate(d.getDate() + n); return d.toLocaleDateString('sv-SE'); };
  var pname = function (p) { return p.title + (p.variant_title ? ' · ' + p.variant_title : ''); };

  async function api(action, payload) {
    var r = await fetch(EDGE + '?action=portal', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ t: T, action: action, payload: payload || {} }) });
    var j = await r.json();
    if (!r.ok) throw new Error(j.error || 'Operazione non riuscita');
    if (j.state) S = j.state;
    return j;
  }
  async function load() {
    var r = await fetch(EDGE + '?action=state&t=' + encodeURIComponent(T), { cache: 'no-store' });
    var j = await r.json();
    if (!r.ok) throw new Error(j.error || 'Portale non disponibile');
    S = j;
  }
  function act(btn, fn, okMsg) {
    return (async function () {
      if (btn) btn.disabled = true;
      try { var r = await fn(); banner = { ok: true, text: okMsg || (r && r.message_it) || 'Fatto.' }; render(); }
      catch (e) { banner = { ok: false, text: e.message || String(e) }; render(); }
      finally { if (btn) btn.disabled = false; }
    })();
  }

  // ---- pricing preview (same rules as fabula.trade_price) ----
  function priceFor(p, qty, weekVar, weekAll, recurring) {
    var s = S.settings, list = Number(p.trade_price), basisVar = s.tier_basis === 'week' ? weekVar : qty * Number(p.kg_per_unit), basisAll = s.tier_basis === 'week' ? weekAll : basisVar;
    var tier = list, tierMin = null;
    var ts = (p.tiers || []).filter(function (t) { return Number(t.min_qty) <= (t.scope === 'tutti' ? basisAll : basisVar); })
      .sort(function (a, b) { return (b.scope === 'prodotto') - (a.scope === 'prodotto') || Number(b.min_qty) - Number(a.min_qty); });
    if (ts.length) { var t = ts[0]; tier = t.price != null ? Number(t.price) : Math.round(list * (1 - Number(t.pct) / 100) * 100) / 100; tierMin = t.min_qty; }
    var rec = recurring ? Number(s.recurring_discount_pct || 0) : 0;
    var fin = s.discounts_combine ? Math.round(tier * (1 - rec / 100) * 100) / 100 : Math.min(tier, Math.round(list * (1 - rec / 100) * 100) / 100);
    return { list: list, final: fin, saving: Math.round((list - fin) * 100) / 100, tierMin: tierMin, rec: rec };
  }

  // ---- plan editor state ----
  function planFromState() {
    var days = {}; var src = S.days || {};
    Object.keys(src).forEach(function (d) { days[d] = { window: src[d].window || '', lines: Object.assign({}, src[d].lines || {}) }; });
    var sc = S.schedule || {};
    return { start_date: sc.start_date && sc.start_date >= todayISO() ? sc.start_date : addDays(todayISO(), 1), address: sc.delivery_address || S.customer.address || '', instructions: sc.delivery_instructions || S.customer.instructions || '', po_number: sc.po_number || '', days: days };
  }
  var P = null;

  function render() {
    if (!P) P = planFromState();
    var s = S.settings, sc = S.schedule, st = sc ? sc.status : 'none';
    var chip = st === 'active' ? '<span class="trade-chip trade-chip--ok">Piano attivo</span>' : st === 'paused' ? '<span class="trade-chip trade-chip--warn">In pausa</span>' : st === 'cancelled' ? '<span class="trade-chip trade-chip--muted">Piano annullato</span>' : '<span class="trade-chip trade-chip--muted">Nessun piano</span>';
    var html = '<div class="trade-head"><div><span class="trade-kicker">Per i professionisti</span><h1 class="title heading-size--small">' + esc(S.customer.name) + '</h1></div>' +
      '<div class="trade-head__meta">' + chip + (S.customer.payment_terms_days ? '<span class="trade-chip">Pagamento a ' + esc(S.customer.payment_terms_days) + ' gg</span>' : '') + '<a href="' + esc(ORDERS) + '">I miei ordini e fatture</a></div></div>';
    if (banner) html += '<div class="trade-banner' + (banner.ok ? '' : ' err') + '">' + esc(banner.text) + '</div>';
    var tabs = [['piano', 'Piano settimanale'], ['prossime', 'Prossime consegne'], ['pause', 'Pause e chiusure'], ['storico', 'Storico e conferme']];
    html += '<div class="trade-tabs" role="tablist">' + tabs.map(function (t) { return '<button role="tab" data-tab="' + t[0] + '" aria-selected="' + (tab === t[0]) + '">' + t[1] + '</button>'; }).join('') + '</div>';
    html += '<div class="trade-pane' + (tab === 'piano' ? ' active' : '') + '">' + renderPlan() + '</div>';
    html += '<div class="trade-pane' + (tab === 'prossime' ? ' active' : '') + '">' + renderUpcoming() + '</div>';
    html += '<div class="trade-pane' + (tab === 'pause' ? ' active' : '') + '">' + renderPauses() + '</div>';
    html += '<div class="trade-pane' + (tab === 'storico' ? ' active' : '') + '">' + renderHistory() + '</div>';
    root.innerHTML = html;
    bind();
  }

  function weekTotals() {
    var perVar = {}, all = 0;
    Object.keys(P.days).forEach(function (d) { var L = P.days[d].lines; Object.keys(L).forEach(function (v) { var p = S.products.find(function (x) { return x.variant_id === v; }); if (!p) return; var k = Number(L[v] || 0) * Number(p.kg_per_unit); perVar[v] = (perVar[v] || 0) + k; all += k; }); });
    return { perVar: perVar, all: all };
  }

  function renderPlan() {
    var s = S.settings, sc = S.schedule, days = s.delivery_days, wt = weekTotals(), h = '';
    h += '<div class="trade-card"><h3>Listino riservato e quantità per giorno</h3>';
    h += '<p class="trade-help">Prezzi al ' + esc(S.products[0] ? S.products[0].unit : 'kg') + ', IVA esclusa. ' + (s.recurring_discount_pct > 0 ? 'Sconto piano fisso ' + esc(s.recurring_discount_pct) + '% sulle consegne programmate. ' : '') +
      (s.tier_basis === 'week' ? 'Gli scaglioni di quantità si calcolano sui chili totali della settimana.' : 'Gli scaglioni di quantità si calcolano sui chili di ogni consegna.') + ' Ordine minimo per consegna: ' + esc(s.min_order_kg) + ' kg.</p>';
    h += '<div class="trade-table-wrap"><table class="trade-plan"><thead><tr><th>Prodotto</th><th>Prezzo</th>' + days.map(function (d) { return '<th>' + WDS[d] + '</th>'; }).join('') + '<th>Settimana</th></tr></thead><tbody>';
    S.products.forEach(function (p) {
      var pr = priceFor(p, 0, wt.perVar[p.variant_id] || 0, wt.all, true);
      var tiers = (p.tiers || []).map(function (t) { return 'da ' + t.min_qty + ' kg' + (t.scope === 'tutti' ? '/sett. totali' : '') + ': ' + (t.price != null ? eur(t.price) : '-' + t.pct + '%'); }).join(' · ');
      h += '<tr><td class="trade-prod"><b>' + esc(p.title) + '</b><small>' + esc(p.variant_title || '') + '</small>' + (tiers ? '<div class="trade-tiers">' + esc(tiers) + '</div>' : '') + '</td>';
      h += '<td class="trade-price">' + (pr.saving > 0 ? '<s>' + eur(pr.list) + '</s>' : '') + '<b>' + eur(pr.final) + '</b>' + (pr.saving > 0 ? '<em>risparmi ' + eur(pr.saving) + '/' + esc(p.unit) + '</em>' : '') + '</td>';
      days.forEach(function (d) { var q = (P.days[d] && P.days[d].lines[p.variant_id]) || ''; h += '<td><input type="number" min="0" step="' + esc(p.step_qty) + '" data-day="' + d + '" data-var="' + esc(p.variant_id) + '" value="' + esc(q) + '" inputmode="decimal" aria-label="' + esc(pname(p)) + ' ' + WD[d] + '"></td>'; });
      h += '<td class="tot">' + kg(wt.perVar[p.variant_id] || 0) + '</td></tr>';
    });
    h += '<tr><td><b>Fascia oraria</b></td><td></td>' + days.map(function (d) { var w = (P.days[d] && P.days[d].window) || s.default_window; return '<td><select data-win="' + d + '">' + s.windows.map(function (x) { return '<option' + (x === w ? ' selected' : '') + '>' + esc(x) + '</option>'; }).join('') + '</select></td>'; }).join('') + '<td></td></tr>';
    h += '<tr><td><b>Totale giorno</b></td><td></td>' + days.map(function (d) {
      var L = (P.days[d] && P.days[d].lines) || {}, k = 0, e = 0;
      Object.keys(L).forEach(function (v) { var p = S.products.find(function (x) { return x.variant_id === v; }); if (!p || !Number(L[v])) return; var pr = priceFor(p, Number(L[v]), wt.perVar[v] || 0, wt.all, true); k += Number(L[v]) * Number(p.kg_per_unit); e += pr.final * Number(L[v]); });
      return '<td class="tot' + (k > 0 && k < Number(s.min_order_kg) ? ' ko' : '') + '">' + (k ? kg(k) + '<small>' + eur(e) + '</small>' : '—') + '</td>';
    }).join('') + '<td class="tot">' + kg(wt.all) + '</td></tr></tbody></table></div>';
    h += '<div class="trade-fields"><div><label for="tp-start">Prima consegna dal</label><input type="date" id="tp-start" min="' + todayISO() + '" value="' + esc(P.start_date) + '"></div>' +
      '<div><label for="tp-po">Vostro riferimento / n. ordine (facoltativo)</label><input type="text" id="tp-po" value="' + esc(P.po_number) + '" maxlength="40"></div>' +
      '<div><label for="tp-addr">Indirizzo di consegna</label><input type="text" id="tp-addr" value="' + esc(P.address) + '"></div>' +
      '<div><label for="tp-instr">Istruzioni per l\'autista</label><input type="text" id="tp-instr" value="' + esc(P.instructions) + '" placeholder="Es. ingresso cucina sul retro, citofono 2"></div></div>';
    h += '<div class="trade-actions"><button class="trade-btn" id="tp-save">' + (sc ? 'Salva le modifiche al piano' : 'Attiva il piano consegne') + '</button><span class="trade-help">' + esc(s.cutoff_rule_it) + '. Le consegne già confermate non cambiano.</span></div></div>';
    return h;
  }

  function renderUpcoming() {
    var u = S.upcoming || [], s = S.settings;
    if (!u.length) return '<p class="trade-empty">Nessuna consegna in programma nei prossimi ' + esc(s.horizon_days) + ' giorni. ' + (S.schedule ? '' : 'Imposta il piano settimanale per iniziare.') + '</p>';
    return '<div class="trade-deliv">' + u.map(function (d, i) {
      var ed = editing[d.date];
      var acts = d.can_change ? '<button class="trade-btn trade-btn--ghost trade-btn--sm" data-edit="' + d.date + '">' + (ed ? 'Chiudi' : 'Cambia quantità') + '</button><button class="trade-btn trade-btn--ghost trade-btn--sm" data-win-date="' + d.date + '">Cambia fascia</button><button class="trade-btn trade-btn--warn trade-btn--sm" data-skip="' + d.date + '">Salta</button>' : '';
      var status = d.booked ? '<span class="trade-chip trade-chip--ok">Confermata' + (d.shopify_order ? ' · ordine ' + esc(d.shopify_order) : d.order_number ? ' · ' + esc(d.order_number) : '') + '</span>' : d.can_change ? '<span class="trade-chip">Modificabile fino alle ' + esc(s.cutoff_time) + ' del ' + dIt(addDays(d.date, -1)) + '</span>' : '<span class="trade-chip trade-chip--ok">In preparazione</span>';
      var h = '<div class="trade-deliv__item"><div><div class="trade-deliv__date">' + dIt(d.date, true) + ' · ore ' + esc(d.window || s.default_window) + '</div>' +
        '<ul class="trade-deliv__lines">' + d.lines.map(function (l) { return '<li>' + esc(l.qty) + ' ' + esc(l.unit) + ' ' + esc(l.title + (l.variant_title ? ' ' + l.variant_title : '')) + ' × ' + eur(l.price.final_price) + (l.source === 'modifica' ? ' <small>(modificata)</small>' : '') + '</li>'; }).join('') + '</ul>' +
        '<div class="trade-deliv__total">' + eur(d.total_eur) + ' <span class="trade-deliv__meta">· ' + kg(d.kg) + (d.min_ok ? '' : ' · sotto il minimo di ' + esc(s.min_order_kg) + ' kg: non verrà consegnata') + '</span></div><div class="trade-deliv__meta">' + status + '</div></div>' +
        '<div class="trade-deliv__acts">' + acts + '</div>';
      if (ed) {
        h += '<div class="trade-edit" data-edit-form="' + d.date + '">';
        S.products.forEach(function (p) { var cur = d.lines.find(function (l) { return l.variant_id === p.variant_id; }); h += '<div class="trade-edit__line"><input type="number" min="0" step="' + esc(p.step_qty) + '" data-ev="' + esc(p.variant_id) + '" value="' + esc(cur ? cur.qty : '') + '"><span>' + esc(p.unit) + ' ' + esc(pname(p)) + '</span></div>'; });
        h += '<div class="trade-actions"><button class="trade-btn trade-btn--sm" data-edit-save="' + d.date + '">Salva solo per questa consegna</button><span class="trade-help">Dalla consegna successiva vale di nuovo il piano normale.</span></div></div>';
      }
      if (editing['win-' + d.date]) {
        h += '<div class="trade-edit"><div class="trade-edit__line"><select data-win-sel="' + d.date + '">' + s.windows.map(function (x) { return '<option' + (x === d.window ? ' selected' : '') + '>' + esc(x) + '</option>'; }).join('') + '</select><button class="trade-btn trade-btn--sm" data-win-save="' + d.date + '">Cambia la fascia di questa consegna</button></div></div>';
      }
      return h + '</div>';
    }).join('') + '</div>';
  }

  function renderPauses() {
    var sc = S.schedule, s = S.settings, h = '';
    h += '<div class="trade-grid-2"><div class="trade-card"><h3>Chiusura o ferie</h3><p class="trade-help">Nessuna consegna nei giorni indicati; poi si riprende da soli.</p>' +
      '<div class="trade-fields"><div><label for="cl-from">Dal</label><input type="date" id="cl-from" min="' + todayISO() + '"></div><div><label for="cl-to">Al</label><input type="date" id="cl-to" min="' + todayISO() + '"></div></div>' +
      '<div class="trade-actions"><button class="trade-btn" id="cl-save"' + (sc ? '' : ' disabled') + '>Salta queste consegne</button></div></div>';
    h += '<div class="trade-card"><h3>Pausa del piano</h3><p class="trade-help">' + (sc && sc.status === 'paused' ? 'Il piano è in pausa dal ' + esc(dIt(sc.paused_from || todayISO())) + '.' : sc && sc.paused_until ? 'In pausa fino al ' + esc(dIt(sc.paused_until)) + ', poi riprende da solo.' : 'Metti in pausa fino a una data (riprende da solo) o senza data (riprendi tu quando vuoi).') + '</p>';
    if (sc && sc.status === 'paused') h += '<div class="trade-actions"><button class="trade-btn" id="ps-resume">Riprendi le consegne</button></div>';
    else h += '<div class="trade-fields"><div><label for="ps-until">Fino al (compreso)</label><input type="date" id="ps-until" min="' + todayISO() + '"></div></div><div class="trade-actions"><button class="trade-btn" id="ps-pause"' + (sc ? '' : ' disabled') + '>Metti in pausa</button><button class="trade-btn trade-btn--ghost" id="ps-pause-open"' + (sc ? '' : ' disabled') + '>Pausa senza data</button></div>';
    h += '</div></div>';
    var ex = (S.exceptions || []).filter(function (e) { return e.note !== 'pausa' || true; });
    h += '<div class="trade-card"><h3>Modifiche in programma</h3>';
    if (!ex.length) h += '<p class="trade-empty">Nessuna modifica: valgono i giorni e le quantità del piano.</p>';
    else h += '<ul class="trade-list">' + ex.map(function (e) {
      var what = e.kind === 'skip' ? (e.note === 'pausa' ? 'Pausa' : 'Nessuna consegna') : e.kind === 'override' ? esc(e.product) + ': ' + esc(e.qty) + ' ' + (e.qty > 0 ? '' : '(tolto)') : 'Fascia ' + esc(e.window);
      var when = e.date_from === e.date_to ? dIt(e.date_from) : 'dal ' + dIt(e.date_from) + ' al ' + dIt(e.date_to);
      return '<li><span>' + what + ' · ' + when + (e.created_by !== 'customer' ? ' <small>(dal caseificio)</small>' : '') + '</span>' + (e.can_cancel ? '<button class="trade-btn trade-btn--ghost trade-btn--sm" data-cancel-ex="' + e.id + '">Annulla</button>' : '<span class="trade-deliv__meta">confermata</span>') + '</li>';
    }).join('') + '</ul>';
    h += '</div>';
    if (S.closures && S.closures.length) h += '<div class="trade-card"><h3>Chiusure del caseificio</h3><ul class="trade-list">' + S.closures.map(function (c) { return '<li><span>' + (c.date_from === c.date_to ? dIt(c.date_from) : 'dal ' + dIt(c.date_from) + ' al ' + dIt(c.date_to)) + (c.note ? ' · ' + esc(c.note) : '') + '</span></li>'; }).join('') + '</ul></div>';
    if (sc && sc.status !== 'cancelled') h += '<div class="trade-card"><h3>Annullare il piano</h3><p class="trade-help">Nessuna consegna futura (quelle già confermate arrivano). Potrai sempre crearne uno nuovo.</p><div class="trade-actions"><button class="trade-btn trade-btn--warn" id="ps-cancel">Annulla il piano consegne</button></div></div>';
    return h;
  }

  function renderHistory() {
    var h = '<div class="trade-grid-2"><div class="trade-card"><h3>Conferme</h3>';
    h += (S.log && S.log.length) ? '<ul class="trade-log">' + S.log.map(function (l) { return '<li><time>' + new Date(l.at).toLocaleString('it-IT', { dateStyle: 'short', timeStyle: 'short' }) + (l.actor !== 'customer' && l.actor !== 'system' ? ' · ' + esc(l.actor) : '') + '</time>' + esc(l.message) + '</li>'; }).join('') + '</ul>' : '<p class="trade-empty">Ancora nessuna modifica.</p>';
    h += '</div><div class="trade-card"><h3>Ultime consegne registrate <small>(totali IVA inclusa)</small></h3>';
    h += (S.recent_orders && S.recent_orders.length) ? '<ul class="trade-list">' + S.recent_orders.map(function (o) { return '<li><span>' + dIt(o.date) + ' · ' + esc(o.shopify || o.number) + '</span><span>' + eur(o.total) + '</span></li>'; }).join('') + '</ul><p class="trade-help">Fatture e stato dei pagamenti: <a href="' + esc(ORDERS) + '">i miei ordini</a>.</p>' : '<p class="trade-empty">Nessuna consegna registrata finora.</p>';
    return h + '</div></div>';
  }

  function bind() {
    root.querySelectorAll('.trade-tabs button').forEach(function (b) { b.onclick = function () { tab = b.dataset.tab; banner = null; render(); }; });
    root.querySelectorAll('.trade-plan input[data-day]').forEach(function (i) { i.oninput = function () { var d = i.dataset.day; P.days[d] = P.days[d] || { window: '', lines: {} }; P.days[d].lines[i.dataset.var] = Number(i.value) || 0; refreshTotals(); }; });
    root.querySelectorAll('.trade-plan select[data-win]').forEach(function (sel) { sel.onchange = function () { var d = sel.dataset.win; P.days[d] = P.days[d] || { window: '', lines: {} }; P.days[d].window = sel.value; }; });
    var q = function (id) { return root.querySelector(id); };
    if (q('#tp-save')) q('#tp-save').onclick = function () {
      P.start_date = q('#tp-start').value; P.po_number = q('#tp-po').value; P.address = q('#tp-addr').value; P.instructions = q('#tp-instr').value;
      var days = {}; Object.keys(P.days).forEach(function (d) { var L = {}; Object.keys(P.days[d].lines).forEach(function (v) { if (Number(P.days[d].lines[v]) > 0) L[v] = Number(P.days[d].lines[v]); }); if (Object.keys(L).length) days[d] = { window: P.days[d].window || S.settings.default_window, lines: L }; });
      act(q('#tp-save'), async function () { var r = await api('save_schedule', { start_date: P.start_date, address: P.address, instructions: P.instructions, po_number: P.po_number, days: days }); P = null; tab = 'prossime'; return { message_it: 'Piano salvato. Qui sotto le prossime consegne con prezzi e totali.' }; });
    };
    root.querySelectorAll('[data-skip]').forEach(function (b) { b.onclick = function () { if (!confirm('Saltare la consegna di ' + dIt(b.dataset.skip, true) + '?')) return; act(b, function () { return api('add_exception', { kind: 'skip', date_from: b.dataset.skip }); }); }; });
    root.querySelectorAll('[data-edit]').forEach(function (b) { b.onclick = function () { editing[b.dataset.edit] = !editing[b.dataset.edit]; render(); }; });
    root.querySelectorAll('[data-win-date]').forEach(function (b) { b.onclick = function () { editing['win-' + b.dataset.winDate] = !editing['win-' + b.dataset.winDate]; render(); }; });
    root.querySelectorAll('[data-edit-save]').forEach(function (b) { b.onclick = function () {
      var date = b.dataset.editSave, form = root.querySelector('[data-edit-form="' + date + '"]'), d = S.upcoming.find(function (x) { return x.date === date; });
      var changes = []; form.querySelectorAll('[data-ev]').forEach(function (i) { var v = i.dataset.ev, cur = d.lines.find(function (l) { return l.variant_id === v; }), nq = Number(i.value) || 0, oq = cur ? Number(cur.qty) : 0; if (nq !== oq) changes.push({ variant_id: v, qty: nq }); });
      if (!changes.length) { banner = { ok: false, text: 'Nessuna quantità cambiata.' }; render(); return; }
      act(b, async function () { var last; for (var c of changes) last = await api('add_exception', { kind: 'override', date_from: date, variant_id: c.variant_id, qty: c.qty }); editing = {}; return { message_it: 'Consegna di ' + dIt(date, true) + ' aggiornata: ' + changes.length + ' quantità cambiate solo per quel giorno.' }; });
    }; });
    root.querySelectorAll('[data-win-save]').forEach(function (b) { b.onclick = function () { var date = b.dataset.winSave, sel = root.querySelector('[data-win-sel="' + date + '"]'); act(b, async function () { var r = await api('add_exception', { kind: 'window', date_from: date, window: sel.value }); editing = {}; return r; }); }; });
    if (q('#cl-save')) q('#cl-save').onclick = function () { var f = q('#cl-from').value, t = q('#cl-to').value || f; if (!f) { banner = { ok: false, text: 'Indica la data di inizio.' }; render(); return; } act(q('#cl-save'), function () { return api('add_exception', { kind: 'skip', date_from: f, date_to: t, note: 'chiusura' }); }); };
    if (q('#ps-pause')) q('#ps-pause').onclick = function () { var u = q('#ps-until').value; if (!u) { banner = { ok: false, text: 'Indica fino a quando, oppure usa "Pausa senza data".' }; render(); return; } act(q('#ps-pause'), function () { return api('set_status', { status: 'paused', until: u }); }); };
    if (q('#ps-pause-open')) q('#ps-pause-open').onclick = function () { act(q('#ps-pause-open'), function () { return api('set_status', { status: 'paused' }); }); };
    if (q('#ps-resume')) q('#ps-resume').onclick = function () { act(q('#ps-resume'), function () { return api('set_status', { status: 'active' }); }); };
    if (q('#ps-cancel')) q('#ps-cancel').onclick = function () { if (!confirm('Annullare il piano consegne? Le consegne già confermate arrivano comunque.')) return; act(q('#ps-cancel'), async function () { var r = await api('set_status', { status: 'cancelled' }); P = null; return r; }); };
    root.querySelectorAll('[data-cancel-ex]').forEach(function (b) { b.onclick = function () { act(b, function () { return api('cancel_exception', { id: b.dataset.cancelEx }); }); }; });
  }
  function refreshTotals() { var pane = root.querySelector('.trade-pane.active'); var scroll = pane && pane.querySelector('.trade-table-wrap') ? pane.querySelector('.trade-table-wrap').scrollLeft : 0; var focus = document.activeElement, sel = focus && focus.dataset ? '[data-day="' + focus.dataset.day + '"][data-var="' + focus.dataset.var + '"]' : null, pos = focus && focus.selectionStart; render(); if (sel) { var el = root.querySelector(sel); if (el) { el.focus(); try { el.setSelectionRange(pos, pos); } catch (e) {} } } var w = root.querySelector('.trade-table-wrap'); if (w) w.scrollLeft = scroll; }

  load().then(render).catch(function (e) { root.innerHTML = '<div class="trade-banner err">' + esc(e.message) + '</div>'; });
})();
