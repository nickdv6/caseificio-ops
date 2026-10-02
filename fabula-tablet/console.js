/* La Perla owner console — operations only. Oggi: daily_brief() tiles + approvals gate; Operazioni: PO send, wholesale, farm supply, effluent; Andamento: charts; Anagrafiche: parties (table, Fornitori|Clienti), standing orders, staff; Ricette: dosing steps. Bot parameters, machines, deadlines and account live in admin.html. */
(() => {
  const CFG = window.FABULA_CONFIG;
  const sb = supabase.createClient(CFG.supabaseUrl, CFG.supabaseKey, { db: { schema: 'fabula' } });
  const $ = id => document.getElementById(id);
  // Mouse wheel over a focused number field must never change its value (keyboard only).
  document.addEventListener('wheel', e => { const a = document.activeElement; if (a && a.tagName === 'INPUT' && a.type === 'number' && e.target === a) e.preventDefault(); }, { passive: false });
  let staff = null;
  const show = v => document.querySelectorAll('.view').forEach(e => e.classList.toggle('active', e.id === 'v-' + v));
  const toast = (m, cls = '') => { const t = $('toast'); t.textContent = m; t.className = 'toast ' + cls; t.style.display = 'block'; setTimeout(() => t.style.display = 'none', 2800); };
  const eur = n => n == null ? '–' : new Intl.NumberFormat('it-IT', { style: 'currency', currency: 'EUR', maximumFractionDigits: 0 }).format(n);
  const num = (n, d = 1) => n == null ? '–' : Number(n).toLocaleString('it-IT', { maximumFractionDigits: d, minimumFractionDigits: d });
  const dateIt = s => new Date(s + 'T12:00:00').toLocaleDateString('it-IT', { weekday: 'long', day: 'numeric', month: 'long' });
  const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

  // ---------- auth ----------
  async function init() {
    const { data: { session } } = await sb.auth.getSession();
    if (!session) return show('login');
    const { data } = await sb.from('staff').select('*').eq('auth_user_id', session.user.id).maybeSingle();
    staff = data || { id: null, full_name: session.user.email, role: 'owner' };
    $('who').textContent = staff.full_name; $('btn-logout').hidden = false; $('btn-refresh').hidden = false; $('btn-pkg').hidden = false; $('btn-admin').hidden = !['owner', 'partner'].includes(staff.role);
    show('main'); load(); showTab((location.hash || '#oggi').slice(1).replace(/[^a-z]/g, '') || 'oggi', false);
  }
  $('btn-login').onclick = async () => { const { error } = await sb.auth.signInWithPassword({ email: $('email').value, password: $('pw').value }); if (error) return toast(error.message, 'err'); init(); };
  $('pw').addEventListener('keydown', e => { if (e.key === 'Enter') $('btn-login').click(); });
  $('btn-logout').onclick = async () => { await sb.auth.signOut(); location.reload(); };
  $('btn-refresh').onclick = () => load();

  // ---------- data ----------
  async function load() {
    const [brief, appr, prods, prod, sales] = await Promise.all([
      sb.rpc('daily_brief'),
      sb.from('approvals').select('id, kind, summary, amount_eur, requested_by, requested_at, expires_at, payload, related_table').eq('status', 'pending').order('requested_at'),
      sb.from('products').select('sku, name, unit'),
      sb.from('v_daily_production').select('batch_date, product, yield_pct, output_kg').ilike('product', 'Mozzarella%').gte('batch_date', daysAgo(30)).order('batch_date'),
      sb.from('v_daily_sales').select('order_date, channel, revenue_eur').gte('order_date', daysAgo(30)).order('order_date')
    ]);
    if (brief.error) return toast('daily_brief: ' + brief.error.message, 'err');
    const b = brief.data;
    $('simbadge').hidden = !b.is_simulation;
    $('sub').textContent = 'Brief di ' + dateIt(b.date);
    PRODUCTS = Object.fromEntries((prods.data || []).map(p => [p.sku, p]));
    renderTiles(b); renderApprovals(appr.data || [], b.date); renderHaccp(b); renderStock(b.stock_finished, b.date); renderProcurement(b.procurement_signals);
    badge('n-oggi', (b.pending_approvals || []).length); refreshBadges();
    if (loaded.ops) { renderPoSend(); renderWholesale(); loadFarm(); loadEffluent(); }
    yieldChart(prod.data || [], b.yield); salesChart(sales.data || []);
  }
  const daysAgo = n => { const d = new Date(); d.setDate(d.getDate() - n); return d.toISOString().slice(0, 10); };

  // ---------- tiles ----------
  function renderTiles(b) {
    const moz = (b.production || []).find(p => /Mozzarella/.test(p.product)) || {};
    const y = b.yield || {}, st = b.sales_trend || {}, w = b.waste || {}, t = b.tasks || {}, h = b.haccp || {};
    const yieldDelta = y.yesterday != null && y.avg_30d != null ? y.yesterday - y.avg_30d : null;
    const salesDelta = st.same_weekday_avg_4w_eur ? (st.yesterday_eur - st.same_weekday_avg_4w_eur) / st.same_weekday_avg_4w_eur * 100 : null;
    const pc = b.pos_close || {};
    const compliance = (h.non_conformities || []).length + (h.missing_daily_checks || []).length + (h.evening_cold_checks_missing || []).filter(c => !(h.missing_daily_checks || []).includes(c)).length
      + (t.overdue || []).length + (t.open_non_conformities || 0) + (t.calibration_due || []).length + (t.training_expiring || []).length + (pc.missing || Math.abs(pc.variance_eur || 0) > 0.5 ? 1 : 0);
    const tiles = [
      ['Resa ieri', y.yesterday != null ? num(y.yesterday) + ' %' : '–', yieldDelta != null ? (yieldDelta >= 0 ? '+' : '') + num(yieldDelta) + ' vs 30 gg' : 'nessuna produzione', yieldDelta != null && yieldDelta < -1.5],
      ['Mozzarella ieri', moz.output_kg != null ? num(moz.output_kg, 0) + ' kg' : '–', moz.milk_in_kg ? 'da ' + num(moz.milk_in_kg, 0) + ' kg latte' : '', false],
      ['Vendite ieri', eur(st.yesterday_eur), salesDelta != null ? (salesDelta >= 0 ? '+' : '') + num(salesDelta, 0) + ' % vs stesso giorno' : '', salesDelta != null && salesDelta < -15],
      ['Settimana', eur(st.week_to_date_eur), 'da lunedì', false],
      ['Scarti 7 gg', w.last_7d_pct_of_output != null ? num(w.last_7d_pct_of_output) + ' %' : '–', num(w.last_7d_kg, 0) + ' kg', (w.last_7d_pct_of_output || 0) > 10],
      ['Conformità', compliance === 0 ? 'OK' : String(compliance), compliance === 0 ? 'nessun problema' : 'segnalazioni aperte', compliance > 0],
      ['Da approvare', String((b.pending_approvals || []).length), 'richieste dei bot', (b.pending_approvals || []).length > 0],
    ];
    $('tiles').innerHTML = tiles.map(([l, v, d, bad]) => `<div class="tile${bad ? ' bad' : ''}"><div class="l">${l}</div><div class="v">${v}</div><div class="d">${d}</div></div>`).join('');
  }

  // ---------- approvals: one structured card per request, facts laid out as a grid instead of a sentence ----------
  let PRODUCTS = {};
  const KIND = { purchase_order: ['Ordine d’acquisto', 'po'], milk_plan: ['Piano latte', 'milk'], price_change: ['Promo scorte', ''], recipe_update: ['Ricetta', ''], dop_declaration: ['Consorzio DOP', ''], other: ['Richiesta', ''] };
  const WDAY = ['domenica', 'lunedì', 'martedì', 'mercoledì', 'giovedì', 'venerdì', 'sabato'];
  const dShort = s => s ? WDAY[new Date(s + 'T12:00:00').getDay()] + ' ' + fmtD(s) : '—';
  const fact = (l, v, cls = '') => `<div><div class="l">${l}</div><div class="v ${cls}">${v}</div></div>`;
  const kgf = n => num(n, Number(n) % 1 ? 1 : 0);
  function approvalView(a, today) {
    const p = a.payload || {}, type = a.kind === 'other' ? (p.type || 'other') : (p.type === 'recipe_update' ? 'recipe_update' : a.kind);
    const prod = PRODUCTS[p.sku] || PRODUCTS[p.finished_sku] || {};
    let title = esc(a.summary), facts = '', more = '', amount = a.amount_eur != null ? eur(a.amount_eur) : '';
    switch (type) {
      case 'purchase_order':
        title = `${esc(p.po_number || 'Ordine')} · ${esc(p.supplier || '')}`;
        facts = fact('Articolo', esc(prod.name || p.sku || '—')) + fact('Quantità', `${num(p.qty, 0)} <small>${esc(p.unit || '')}</small>`) +
          fact('Prezzo', p.unit_price_eur != null ? `€ ${num(p.unit_price_eur, 3)} <small>/${esc(p.unit || '')}</small>` : '<span class="ko">da confermare</span>') +
          fact('Giacenza', `${num(p.on_hand, 0)} <small>${esc(p.unit || '')}</small>`) + fact('Consumo', p.daily_use != null ? `${num(p.daily_use, 0)} <small>${esc(p.unit || '')}/giorno</small>` : '—') +
          fact('Copertura', p.days_cover != null ? `${num(p.days_cover)} <small>giorni</small>` : '—', p.days_cover != null && p.days_cover < 5 ? 'ko' : '');
        more = p.price_missing ? '<div class="status ko">Prezzo non a listino: confermalo con il fornitore prima di approvare.</div>' : '';
        break;
      case 'milk_plan':
        title = `Latte per ${dShort(p.plan_date)}`;
        facts = fact('Latte', `${num(p.milk_kg, 0)} <small>kg</small>`) + fact('Mozzarella prevista', `≈ ${kgf(p.planned_output_kg)} <small>kg</small>`) +
          fact('Costo stimato', eur(p.est_cost_eur)) + fact('Decidere entro', a.expires_at ? new Date(a.expires_at).toLocaleString('it-IT', { weekday: 'short', hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Rome' }) + ' <small>ora italiana</small>' : '—');
        more = p.rationale ? `<details><summary>Come è stato calcolato</summary>${esc(p.rationale)}</details>` : '';
        break;
      case 'sell_down': case 'price_change': {
        const act = { promo_banco: 'promo al banco', offerta_ingrosso_e_promo: 'promo al banco + offerta ai clienti ingrosso', ritirare: 'ritirare dalla vendita', spingere_al_banco: 'spingere al banco' }[p.action] || p.action || '';
        const days = p.expiry && today ? Math.round((new Date(p.expiry) - new Date(today)) / 864e5) : null;
        title = `${esc(prod.name || p.sku || '')} · lotto ${esc(p.lot || '')}`;
        facts = fact('A rischio', `${kgf(p.at_risk_kg)} <small>kg</small>`, 'ko') + fact('Giacenza', `${kgf(p.on_hand_kg)} <small>kg</small>`) +
          fact('Scade', days == null ? fmtD(p.expiry) : days <= 0 ? 'oggi' : days === 1 ? 'domani' : fmtD(p.expiry), days != null && days <= 1 ? 'ko' : '') +
          fact('Prezzo', `<s style="color:var(--muted);font-weight:400">€ ${num(p.list_price_eur_kg, 2)}</s> → € ${num(p.promo_price_eur_kg, 2)} <small>/kg</small>`) + fact('Sconto', `−${p.promo_pct} %`) + fact('Azione', esc(act));
        break;
      }
      case 'recipe_update':
        title = `Ricetta ${esc(prod.name || p.finished_sku || '')} · ${esc((PRODUCTS[p.component_sku] || {}).name || p.component_sku || '')}`;
        facts = fact('Dose attuale', `${p.from} <small>${esc(p.unit || '')}</small>`) + fact('Dose proposta', `${p.to} <small>${esc(p.unit || '')}</small>`) + fact('Scostamento', `${p.deviation_pct > 0 ? '+' : ''}${num(p.deviation_pct)} %`) + fact('Lotti osservati', p.batches ?? '—');
        break;
      case 'dop_declaration':
        title = `Dichiarazione Consorzio ${esc(p.month || '')}`;
        facts = fact('Latte lavorato', `${num(p.milk_processed_kg, 0)} <small>kg</small>`) + fact('Mozzarella DOP', `${num(p.mozzarella_dop_kg, 0)} <small>kg</small>`) + fact('Lotti', p.batches ?? '—') + fact('Etichette', num(p.labels_printed, 0)) + fact('Venduto', `${num(p.sold_kg, 0)} <small>kg</small>`);
        break;
    }
    const [klabel, kcls] = KIND[type] || KIND.other;
    return { title, facts, more, amount, klabel, kcls };
  }
  function renderApprovals(list, today) {
    const box = $('approvals');
    if (!list || !list.length) { box.innerHTML = '<div class="empty">Niente in attesa. I bot propongono, tu decidi: tutto ciò che impegna denaro o documenti compare qui prima.</div>'; return; }
    const age = a => Math.max(0, Math.round((Date.now() - new Date(a.requested_at)) / 864e5));
    box.innerHTML = list.map(a => { const v = approvalView(a, today); return `
      <div class="appr" data-id="${a.id}">
        <div class="hd"><div><span class="kind ${v.kcls}">${v.klabel}</span><div class="t">${v.title}</div><div class="by">proposto da ${esc(String(a.requested_by || '').replace('agent:', 'bot ').replace('_', ' '))} · ${age(a) === 0 ? 'oggi' : age(a) + ' g fa'}</div></div><div class="amt">${v.amount}</div></div>
        ${v.facts ? `<div class="facts">${v.facts}</div>` : `<div class="s" style="margin:8px 0">${esc(a.summary)}</div>`}${v.more}
        <div class="row"><input type="text" placeholder="Nota (facoltativa)" id="note-${a.id}"><button class="btn" data-act="approved">Approva</button><button class="btn warn" data-act="rejected">Rifiuta</button></div>
      </div>`; }).join('');
    box.querySelectorAll('button[data-act]').forEach(btn => btn.onclick = async () => {
      const card = btn.closest('.appr'), id = card.dataset.id, act = btn.dataset.act;
      card.querySelectorAll('button').forEach(b => b.disabled = true);
      const { data: row, error } = await sb.from('approvals').update({ status: act, decided_by: staff.full_name, decided_at: new Date().toISOString(), decision_note: $('note-' + id).value || null }).eq('id', id).eq('status', 'pending').select().single();
      if (error) { toast(error.message, 'err'); card.querySelectorAll('button').forEach(b => b.disabled = false); return; }
      if (row.related_table === 'purchase_orders' && row.related_id) await sb.from('purchase_orders').update({ status: act === 'approved' ? 'approved' : 'cancelled' }).eq('id', row.related_id);
      toast(act === 'approved' ? 'Approvato' : 'Rifiutato'); load();
    });
  }

  // ---------- lists ----------
  function renderHaccp(b) {
    const h = b.haccp || {}, t = b.tasks || {}; const items = [];
    (h.non_conformities || []).forEach(n => items.push(['ko', `Non conformità ${esc(n.point)}: ${num(n.value)} °C${n.action ? ' · ' + esc(n.action) : ''}`]));
    (h.missing_daily_checks || []).forEach(c => items.push(['ko', `Controllo mancante: ${esc(c)}`]));
    (h.evening_cold_checks_missing || []).filter(c => !(h.missing_daily_checks || []).includes(c)).forEach(c => items.push(['ko', `Controllo serale mancante: ${esc(c)}`]));
    (t.overdue || []).forEach(o => items.push(['ko', `Attività scaduta: ${esc(o.title)} (${esc(o.code)})`]));
    if (t.open_non_conformities) items.push(['ko', `${t.open_non_conformities} non conformità aperte`]);
    (t.calibration_due || []).forEach(c => items.push(['ko', `Taratura ${esc(c.code)} entro ${c.due}`]));
    (t.training_expiring || []).forEach(s => items.push(['ko', `Formazione HACCP ${esc(s.name)} scade ${s.expires}`]));
    const pc = b.pos_close || {}; if (pc.missing) items.push(['ko', 'Chiusura cassa mancante']); else if (pc.variance_eur && Math.abs(pc.variance_eur) > 0.5) items.push(['ko', `Cassa: scostamento ${eur(pc.variance_eur)} tra scontrino Z e registrato`]);
    const e = b.energy || {}; if (e.yesterday_kwh_per_kg && e.avg_30d_kwh_per_kg && e.yesterday_kwh_per_kg > e.avg_30d_kwh_per_kg * 1.15) items.push(['ko', `Energia ${num(e.yesterday_kwh_per_kg, 2)} kWh/kg vs media ${num(e.avg_30d_kwh_per_kg, 2)}`]);
    $('haccp').innerHTML = items.length ? '<ul style="margin:0;padding-left:18px">' + items.map(([c, s]) => `<li class="${c}">${s}</li>`).join('') + '</ul>' : `<div class="ok">${h.checks_logged || 0} controlli registrati, nessuna anomalia.</div>`;
  }
  function renderStock(list, date) {
    const soon = (list || []).filter(s => s.expires && (new Date(s.expires) - new Date(date)) / 864e5 <= 2);
    $('stock').innerHTML = soon.length ? '<table><tr><th>Lotto</th><th>Prodotto</th><th class="num">kg</th><th>Scade</th></tr>' + soon.map(s => `<tr><td>${esc(s.lot)}</td><td>${esc(s.sku)}</td><td class="num">${num(s.kg)}</td><td class="${s.expires <= date ? 'ko' : ''}">${s.expires}</td></tr>`).join('') + '</table>' : '<div class="empty">Nessun lotto in scadenza entro 2 giorni.</div>';
  }
  function renderProcurement(list) {
    $('procurement').innerHTML = (list && list.length) ? '<table><tr><th>Articolo</th><th class="num">Giacenza</th><th class="num">Copertura</th><th class="num">Riordino</th></tr>' + list.map(p => `<tr><td>${esc(p.name)}</td><td class="num">${num(p.on_hand, 0)}</td><td class="num ${p.days_cover != null && p.days_cover < 5 ? 'ko' : ''}">${p.days_cover != null ? num(p.days_cover) + ' gg' : '–'}</td><td class="num">${num(p.reorder_qty, 0)}</td></tr>`).join('') + '</table>' : '<div class="empty">Scorte consumabili sopra il punto di riordino.</div>';
  }
  // ---------- settings & dates editor ----------
  // ---------- tabs (lazy: each pane loads the first time it is opened; Oggi loads with the brief) ----------
  const loaded = {};
  const LOADERS = { ops: () => { renderPoSend(); renderWholesale(); loadFarm(); loadEffluent(); }, anag: () => { loadParties(); loadStanding(); loadStaffCard(); }, ricette: () => loadRecipes() };
  function showTab(name, push = true) {
    document.querySelectorAll('.tab').forEach(t => t.setAttribute('aria-selected', t.dataset.tab === name));
    document.querySelectorAll('.pane').forEach(p => p.classList.toggle('active', p.id === 'p-' + name));
    if (push) { try { history.replaceState(null, '', '#' + name); } catch {} }
    if (LOADERS[name] && !loaded[name]) { loaded[name] = true; LOADERS[name](); }
  }
  $('tabs').onclick = e => { const t = e.target.closest('.tab'); if (t) showTab(t.dataset.tab); };
  const badge = (id, n) => { const el = $(id); if (!el) return; el.textContent = n; el.classList.toggle('on', n > 0); };
  async function refreshBadges() {
    const [po, ws, pl] = await Promise.all([
      sb.from('v_pos_to_send').select('po_number'),
      sb.from('v_wholesale_tomorrow').select('order_number'),
      sb.from('v_parties_editor').select('id').eq('is_placeholder', true)]);
    badge('n-ops', (po.data || []).length);
    badge('n-anag', (pl.data || []).length);
    $('n-ops').title = `${(po.data || []).length} ordini da inviare · ${(ws.data || []).length} consegne ingrosso`;
  }
  async function loadStaffCard() {
    const { data } = await sb.from('staff').select('id, full_name, role, haccp_training_expires, active').eq('active', true).order('full_name');
    renderStaff(data || []);
  }
  const canEdit = () => ['owner', 'partner'].includes(staff.role);
  const saveBtn = (fn) => { const b = document.createElement('button'); b.className = 'btn sm'; b.textContent = 'Salva'; b.onclick = async () => { b.disabled = true; try { await fn(); toast('Salvato'); } catch (err) { toast(err.message || String(err), 'err'); } finally { b.disabled = false; } }; return b; };
  const upd = async (table, match, row) => { const { error } = await sb.from(table).update(row).match(match); if (error) throw error; };
  const dOrNull = v => v || null, nOrNull = v => v === '' || v == null ? null : Number(v);

  const fmtD = s => s ? s.slice(8, 10) + '/' + s.slice(5, 7) + '/' + s.slice(0, 4) : '—';
  const dueCls = s => { if (!s) return ''; const d = (new Date(s) - new Date(new Date().toISOString().slice(0, 10))) / 864e5; return d < 0 ? 'ko' : d <= 30 ? 'ko' : ''; };
  function renderStaff(rows) {
    const box = $('set-staff'); box.innerHTML = '';
    rows.forEach(r => {
      const row = document.createElement('div'); row.className = 'set-row';
      row.innerHTML = `<div class="lbl">${esc(r.full_name)}<small>${esc(r.role)} · formazione HACCP scade <span class="${dueCls(r.haccp_training_expires)}">${fmtD(r.haccp_training_expires)}</span></small></div>`;
      const right = document.createElement('div'); right.className = 'row'; right.style.marginTop = '0';
      const inp = document.createElement('input'); inp.type = 'date'; inp.value = r.haccp_training_expires || '';
      right.append(inp, saveBtn(async () => { await upd('staff', { id: r.id }, { haccp_training_expires: dOrNull(inp.value) }); loadStaffCard(); }));
      row.append(right); box.append(row);
    });
  }


  // ---------- Tier 2: send POs, wholesale confirmations ----------
  const copyText = async (t) => { try { await navigator.clipboard.writeText(t); toast('Copiato'); } catch { toast('Copia non riuscita', 'err'); } };
  const waLink = (phone, text) => 'https://wa.me/' + String(phone || '').replace(/\D/g, '') + '?text=' + encodeURIComponent(text);
  async function renderPoSend() {
    const box = $('po-send');
    const { data, error } = await sb.from('v_pos_to_send').select('*');
    if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    if (!data || !data.length) { box.innerHTML = '<div class="empty">Nessun ordine approvato in attesa di invio.</div>'; return; }
    box.innerHTML = '';
    for (const po of data) {
      const { data: pk } = await sb.rpc('po_send_package', { p_po_number: po.po_number });
      const c = document.createElement('div'); c.className = 'eq';
      c.innerHTML = `<div class="h"><b>${esc(po.po_number)}</b><span class="status">${esc(pk?.supplier || po.supplier)} · ${eur(pk?.total_eur)} · consegna ${fmtD(pk?.expected_date)}</span></div>
        <pre style="white-space:pre-wrap;font:inherit;font-size:13px;background:var(--bg,#f6f3ee);padding:8px;border-radius:6px;margin:6px 0">${esc(pk?.body_it || '')}</pre>`;
      const row = document.createElement('div'); row.className = 'row';
      const mail = document.createElement('a'); mail.className = 'btn sm sec'; mail.style.textDecoration = 'none'; mail.textContent = '✉️ Email';
      mail.href = 'mailto:' + encodeURIComponent(pk?.email || '') + '?subject=' + encodeURIComponent(pk?.subject || '') + '&body=' + encodeURIComponent(pk?.body_it || ''); mail.target = '_blank';
      const wa = document.createElement('a'); wa.className = 'btn sm sec'; wa.style.textDecoration = 'none'; wa.textContent = '💬 WhatsApp'; wa.href = waLink(pk?.phone, pk?.whatsapp_it || ''); wa.target = '_blank';
      const cp = document.createElement('button'); cp.className = 'btn sm sec'; cp.textContent = 'Copia testo'; cp.onclick = () => copyText(pk?.body_it || '');
      const pr = document.createElement('a'); pr.className = 'btn sm sec'; pr.style.textDecoration = 'none'; pr.textContent = '🖨 Stampa PO'; pr.href = 'ordine.html?po=' + encodeURIComponent(po.po_number); pr.target = '_blank';
      const sent = document.createElement('button'); sent.className = 'btn sm'; sent.textContent = '✓ Segna inviato';
      sent.onclick = async () => { sent.disabled = true; const { error } = await sb.rpc('mark_po_sent', { p_po_number: po.po_number, p_via: 'console' }); if (error) { toast(error.message, 'err'); sent.disabled = false; return; } toast('Ordine segnato come inviato'); renderPoSend(); refreshBadges(); };
      row.append(mail, wa, cp, pr, sent); c.append(row); box.append(c);
    }
  }
  async function renderWholesale() {
    const box = $('wholesale');
    const { data, error } = await sb.from('v_wholesale_tomorrow').select('*').limit(12);
    if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    if (!data || !data.length) { box.innerHTML = '<div class="empty">Nessuna consegna ingrosso prenotata. Il bot "Ordini ingrosso" prenota ogni giorno alle 18:20 per il giorno dopo.</div>'; return; }
    box.innerHTML = '<table class="nw2"><tr><th>Giorno</th><th>Cliente</th><th>Cosa</th><th class="num">€</th><th></th></tr>' + data.map(o => `<tr><td>${dShort(o.order_date).replace(/^(\w{3})\w*/, '$1').slice(0, -5)}</td><td>${esc(o.customer)}</td><td>${esc(o.lines_txt)}</td><td class="num">${eur(o.total_eur)}</td><td>${o.phone ? `<a class="btn sm sec" style="text-decoration:none" target="_blank" href="${waLink(o.phone, `Buongiorno, La Perla del Cilento conferma per ${fmtD(o.order_date)}: ${o.lines_txt}. Consegna in mattinata. Grazie!`)}">💬</a>` : ''}</td></tr>`).join('') + '</table>';
  }

  // ---------- Tier 2 settings: parties, standing orders, farm supply ----------
  // ---------- parties: one compact editable table, sub-tabs Fornitori | Clienti ----------
  let partyType = 'supplier', PARTIES = [];
  $('party-tabs').onclick = e => { const b = e.target.closest('.sub'); if (!b) return; partyType = b.dataset.type; document.querySelectorAll('#party-tabs .sub').forEach(x => x.setAttribute('aria-selected', x === b)); renderParties(); };
  async function loadParties() {
    const { data, error } = await sb.from('v_parties_editor').select('*');
    if (error) { $('set-parties').innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    PARTIES = data || [];
    badge('n-sup', PARTIES.filter(p => p.type === 'supplier' && p.is_placeholder).length); badge('n-cus', PARTIES.filter(p => p.type === 'customer' && p.is_placeholder).length);
    renderParties();
  }
  function renderParties() {
    const box = $('set-parties'); box.innerHTML = '';
    const rows = PARTIES.filter(p => p.type === partyType);
    if (!rows.length) { box.innerHTML = `<div class="empty">Nessun ${partyType === 'supplier' ? 'fornitore' : 'cliente'}.</div>`; return; }
    const tbl = document.createElement('table'); tbl.className = 'par';
    tbl.innerHTML = `<tr><th>Nome / ragione sociale</th><th>Email</th><th>Telefono / WhatsApp</th><th class="num">Pag. gg</th><th>${partyType === 'supplier' ? 'Articoli' : 'Ordini fissi'}</th><th></th></tr>`;
    rows.forEach(p => {
      const tr = document.createElement('tr'); if (p.is_placeholder) tr.className = 'ph';
      const mk = (type, k, v, ph = '') => { const i = document.createElement(type === 'number' ? 'input' : 'input'); i.type = type; i.dataset.k = k; i.value = v ?? ''; i.placeholder = ph; return i; };
      const name = mk('text', 'legal_name', p.legal_name), email = mk('email', 'email', p.email, '—'), phone = mk('tel', 'phone', p.phone, '+39 …'), days = mk('number', 'payment_terms_days', p.payment_terms_days);
      const t1 = document.createElement('td'); t1.append(name); if (p.is_placeholder) { const s = document.createElement('small'); s.className = 'status ko'; s.textContent = 'segnaposto'; t1.append(document.createElement('br'), s); }
      const t2 = document.createElement('td'); t2.append(email); const t3 = document.createElement('td'); t3.append(phone); const t4 = document.createElement('td'); t4.className = 'num'; t4.append(days);
      const t5 = document.createElement('td'); t5.className = 'status'; t5.textContent = partyType === 'supplier' ? (p.products_supplied ? p.products_supplied + ' articoli' : '—') : (p.standing_orders ? p.standing_orders + ' giorni' : '—');
      const t6 = document.createElement('td'); t6.style.whiteSpace = 'nowrap';
      t6.append(saveBtn(async () => {
        const v = {}; tr.querySelectorAll('input[data-k]').forEach(i => { v[i.dataset.k] = i.type === 'number' ? nOrNull(i.value) : (i.value.trim() || null); });
        if (!v.legal_name) throw new Error('Il nome è obbligatorio');
        if (p.is_placeholder && !/^(Fornitore|Cliente) \d/.test(v.legal_name)) v.notes = null;   // renamed → no longer a placeholder
        await upd('parties', { id: p.id }, v); loadParties(); refreshBadges();
      }));
      tr.append(t1, t2, t3, t4, t5, t6); tbl.append(tr);
    });
    // new party row
    const add = document.createElement('tr'); add.style.background = 'var(--tile)';
    const nn = document.createElement('input'); nn.type = 'text'; nn.placeholder = partyType === 'supplier' ? 'Nuovo fornitore…' : 'Nuovo cliente…';
    const ne = document.createElement('input'); ne.type = 'email'; ne.placeholder = 'email'; const np = document.createElement('input'); np.type = 'tel'; np.placeholder = '+39 …'; const nd = document.createElement('input'); nd.type = 'number'; nd.value = 30;
    const nb = document.createElement('button'); nb.className = 'btn sm'; nb.textContent = 'Aggiungi';
    nb.onclick = async () => { if (!nn.value.trim()) return toast('Scrivi il nome', 'err'); nb.disabled = true; const { error } = await sb.from('parties').insert({ type: partyType, legal_name: nn.value.trim(), email: ne.value.trim() || null, phone: np.value.trim() || null, payment_terms_days: nOrNull(nd.value) }); nb.disabled = false; if (error) return toast(error.message, 'err'); toast('Aggiunto'); loadParties(); };
    [nn, ne, np, nd].forEach((el, k) => { const td = document.createElement('td'); if (k === 3) td.className = 'num'; td.append(el); add.append(td); });
    const e5 = document.createElement('td'); const e6 = document.createElement('td'); e6.append(nb); add.append(e5, e6); tbl.append(add);
    box.append(tbl);
  }
  const WD = ['Lun', 'Mar', 'Mer', 'Gio', 'Ven', 'Sab'];
  async function loadStanding() {
    const box = $('set-standing'); box.innerHTML = '';
    const [{ data: so }, { data: cust }, { data: prod }] = await Promise.all([
      sb.from('standing_orders').select('*'),
      sb.from('parties').select('id, legal_name').eq('type', 'customer').eq('active', true).order('legal_name'),
      sb.from('products').select('id, name, sku').eq('sku', 'MOZ-DOP-KG').maybeSingle()]);
    const moz = prod; if (!moz) { box.innerHTML = '<div class="empty">Prodotto MOZ-DOP-KG non trovato.</div>'; return; }
    const tbl = document.createElement('table');
    tbl.innerHTML = '<tr><th>Cliente</th>' + WD.map(d => `<th class="num">${d}</th>`).join('') + '<th></th></tr>';
    (cust || []).forEach(cu => {
      const tr = document.createElement('tr'); tr.innerHTML = `<td>${esc(cu.legal_name)}</td>`;
      WD.forEach((_, i) => {
        const wd = i + 1, cur = (so || []).find(s => s.customer_id === cu.id && s.product_id === moz.id && s.weekday === wd);
        const td = document.createElement('td'); td.className = 'num';
        const inp = document.createElement('input'); inp.type = 'number'; inp.step = '0.5'; inp.min = '0'; inp.style.width = '62px'; inp.value = cur && cur.active ? cur.qty_kg : ''; inp.placeholder = '–'; inp.dataset.wd = wd;
        td.append(inp); tr.append(td);
      });
      const td = document.createElement('td');
      td.append(saveBtn(async () => {
        for (const inp of tr.querySelectorAll('input[data-wd]')) {
          const wd = Number(inp.dataset.wd), q = inp.value === '' ? 0 : Number(inp.value);
          const cur = (so || []).find(s => s.customer_id === cu.id && s.product_id === moz.id && s.weekday === wd);
          if (q > 0) { const { error } = await sb.from('standing_orders').upsert({ customer_id: cu.id, product_id: moz.id, weekday: wd, qty_kg: q, active: true, notes: null }, { onConflict: 'customer_id,product_id,weekday' }); if (error) throw error; }
          else if (cur) { await upd('standing_orders', { id: cur.id }, { active: false }); }
        }
        loadStanding();
      }));
      tr.append(td); tbl.append(tr);
    });
    box.append(tbl);
    const note = document.createElement('div'); note.className = 'status'; note.style.marginTop = '6px'; note.textContent = 'Prezzo ingrosso: Configurazione → Vendite. Nuovo cliente: aggiungilo nella tabella Clienti qui sopra, poi compare in questa griglia.'; box.append(note);
  }
  async function loadFarm() {
    const box = $('set-farm'); box.innerHTML = '';
    const { data, error } = await sb.from('v_farm_supply_next').select('*');
    if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    const tbl = document.createElement('table'); tbl.innerHTML = '<tr><th>Giorno</th><th class="num">Disponibili kg</th><th class="num">Piano kg</th><th></th></tr>';
    (data || []).forEach(r => {
      const tr = document.createElement('tr');
      const d = new Date(r.supply_date + 'T12:00:00'); const isSun = d.getDay() === 0;
      tr.innerHTML = `<td>${d.toLocaleDateString('it-IT', { weekday: 'short', day: 'numeric', month: 'short' })}${r.source ? '' : ' <small class="status">default</small>'}</td>`;
      const td1 = document.createElement('td'); td1.className = 'num';
      const inp = document.createElement('input'); inp.type = 'number'; inp.step = '25'; inp.min = '0'; inp.style.width = '90px'; inp.value = Number(r.kg_available); inp.disabled = isSun; td1.append(inp);
      const td2 = document.createElement('td'); td2.className = 'num' + (r.planned_kg != null && Number(r.planned_kg) > Number(r.kg_available) ? ' ko' : ''); td2.textContent = r.planned_kg != null ? num(r.planned_kg, 0) : '–';
      const td3 = document.createElement('td');
      if (!isSun) td3.append(saveBtn(async () => { const { error } = await sb.from('farm_supply').upsert({ supply_date: r.supply_date, kg_available: Number(inp.value), source: 'console', notes: 'da ' + staff.full_name }, { onConflict: 'supply_date' }); if (error) throw error; loadFarm(); }));
      tr.append(td1, td2, td3); tbl.append(tr);
    });
    box.append(tbl);
    const note = document.createElement('div'); note.className = 'status'; note.style.marginTop = '6px'; note.textContent = 'Default giornaliero: impostazione farm.default_kg_per_day (Parametri dei bot).'; box.append(note);
  }

  const EFFL_KIND = { scotta: 'Scotta', siero: 'Siero', acque_lavaggio: 'Acque di lavaggio', fanghi: 'Fanghi', altro: 'Altro' };
  const EFFL_DEST = { ricotta: 'ricotta', allevamento: 'allevamento', fognatura: 'fognatura', trasportatore: 'trasportatore', depuratore_interno: 'depuratore interno', altro: 'altro' };
  async function loadEffluent() {
    const box = $('effluent');
    const [{ data: rows, error }, { data: bal }] = await Promise.all([sb.from('v_effluent_recent').select('*').limit(30), sb.from('v_effluent_balance').select('*').limit(7)]);
    if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    const missing = (bal || []).filter(b => Number(b.whey_logged_m3) === 0 && Number(b.wash_logged_m3) === 0).length;
    const tot = (rows || []).reduce((a, r) => { a[r.kind] = (a[r.kind] || 0) + Number(r.m3); return a; }, {});
    let html = Object.keys(tot).length ? `<div class="status" style="margin-bottom:6px">${Object.entries(tot).map(([k, v]) => `${EFFL_KIND[k] || k} <b>${num(v, 1)} m³</b>`).join(' · ')}</div>` : '';
    if (missing) html += `<div class="status ko" style="margin-bottom:6px">${missing} giorni di produzione (ultimi 7) senza registrazione reflui.</div>`;
    html += (rows && rows.length) ? '<table class="nw2"><tr><th>Giorno</th><th>Cosa</th><th class="num">m³</th><th>Destinazione</th><th>Doc.</th></tr>' + rows.map(r => `<tr><td>${fmtD(r.log_date).slice(0, 5)}</td><td>${EFFL_KIND[r.kind] || esc(r.kind)}</td><td class="num">${num(r.m3, 2)}</td><td>${EFFL_DEST[r.destination] || esc(r.destination)}${r.recipient ? ' · ' + esc(r.recipient) : ''}</td><td class="${r.document_ref ? '' : 'status'}">${esc(r.document_ref || (r.destination === 'trasportatore' || r.destination === 'allevamento' ? 'manca' : '—'))}</td></tr>`).join('') + '</table>'
      : '<div class="empty">Nessun refluo registrato negli ultimi 14 giorni.</div>';
    box.innerHTML = html;
  }

  // ---------- recipes: dose per kg, versioned by date ----------
  const BASIS = (fin) => ({ per_kg_milk: fin === 'RIC-BUF-KG' ? 'per kg siero' : 'per kg latte', per_kg_output: 'per kg prodotto', per_batch: 'per lotto' });
  const PHASE = { start: 'Avvio', close: 'Chiusura' };
  async function loadRecipes() {
    const box = $('recipes'); box.innerHTML = '';
    const [{ data: rows, error }, { data: fins }, { data: comps }] = await Promise.all([
      sb.from('v_recipe_editor').select('*'),
      sb.from('products').select('sku, name').eq('kind', 'finished_good').eq('active', true).order('sku'),
      sb.from('products').select('sku, name, unit').in('kind', ['consumable', 'packaging']).eq('active', true).order('name')]);
    if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    (fins || []).forEach(f => {
      const mine = (rows || []).filter(r => r.finished_sku === f.sku);
      const card = document.createElement('div'); card.className = 'card'; card.style.marginBottom = '16px';
      card.innerHTML = `<h3>${esc(f.name)} <small class="status">${esc(f.sku)}</small></h3>`;
      const tbl = document.createElement('table'); tbl.className = 'rec';
      tbl.innerHTML = '<tr><th>Fase</th><th>Componente</th><th>Base</th><th class="num">Dose</th><th>↑</th><th>Istruzione sul tablet</th><th></th></tr>';
      if (!mine.length) tbl.innerHTML += '<tr><td colspan="7" class="empty">Nessun componente: aggiungine uno qui sotto.</td></tr>';
      mine.forEach(r => {
        const tr = document.createElement('tr');
        tr.innerHTML = `<td><span class="ph">${PHASE[r.phase] || esc(r.phase)} · ${r.step_order}</span></td><td><b>${esc(r.component_name)}</b><br><small class="status">${esc(r.component_sku)}</small></td><td class="status">${BASIS(f.sku)[r.basis] || esc(r.basis)}</td>`;
        const tdQ = document.createElement('td'); tdQ.className = 'num'; const q = document.createElement('input'); q.type = 'number'; q.step = 'any'; q.min = '0'; q.value = Number(r.qty_per_unit); tdQ.append(q, document.createTextNode(' ' + r.unit));
        const tdR = document.createElement('td'); const ru = document.createElement('input'); ru.type = 'checkbox'; ru.checked = !!r.round_up; ru.title = 'Arrotonda per eccesso (pezzi)'; tdR.append(ru);
        const tdI = document.createElement('td'); const ins = document.createElement('input'); ins.type = 'text'; ins.value = r.instruction_it || ''; ins.placeholder = 'es. Pesa il caglio e aggiungilo al latte'; tdI.append(ins);
        const tdB = document.createElement('td'); tdB.style.whiteSpace = 'nowrap';
        tdB.append(saveBtn(async () => { const { error } = await sb.rpc('update_recipe_dose', { p_recipe_id: r.recipe_id, p_qty: Number(q.value), p_round_up: ru.checked, p_instruction: ins.value.trim() || null }); if (error) throw error; loadRecipes(); }));
        const end = document.createElement('button'); end.className = 'btn sm sec'; end.textContent = 'Togli'; end.style.marginLeft = '6px'; end.title = 'Il componente non viene più dosato da domani';
        end.onclick = async () => { end.disabled = true; const { error } = await sb.rpc('end_recipe_component', { p_recipe_id: r.recipe_id }); if (error) { toast(error.message, 'err'); end.disabled = false; return; } toast('Componente tolto dalla ricetta'); loadRecipes(); };
        tdB.append(end); tr.append(tdQ, tdR, tdI, tdB); tbl.append(tr);
      });
      // add row
      const add = document.createElement('tr'); add.style.background = 'var(--tile)';
      const used = new Set(mine.map(r => r.component_sku));
      const selC = document.createElement('select'); selC.innerHTML = '<option value="">+ componente…</option>' + (comps || []).filter(c => !used.has(c.sku)).map(c => `<option value="${esc(c.sku)}">${esc(c.name)} (${esc(c.unit)})</option>`).join('');
      const selB = document.createElement('select'); selB.innerHTML = Object.entries(BASIS(f.sku)).map(([k, v]) => `<option value="${k}">${v}</option>`).join('');
      const selP = document.createElement('select'); selP.innerHTML = '<option value="start">Avvio</option><option value="close">Chiusura</option>';
      const ord = document.createElement('input'); ord.type = 'number'; ord.value = 10 * (mine.length + 1); ord.style.width = '64px'; ord.title = 'ordine del passo';
      const q2 = document.createElement('input'); q2.type = 'number'; q2.step = 'any'; q2.min = '0'; q2.placeholder = 'dose';
      const ru2 = document.createElement('input'); ru2.type = 'checkbox';
      const ins2 = document.createElement('input'); ins2.type = 'text'; ins2.placeholder = 'istruzione (facoltativa)';
      const btn = document.createElement('button'); btn.className = 'btn sm'; btn.textContent = 'Aggiungi';
      btn.onclick = async () => {
        if (!selC.value) return toast('Scegli il componente', 'err'); if (!(Number(q2.value) > 0)) return toast('Inserisci la dose', 'err');
        btn.disabled = true; const { error } = await sb.rpc('add_recipe_component', { p_finished_sku: f.sku, p_component_sku: selC.value, p_basis: selB.value, p_qty: Number(q2.value), p_round_up: ru2.checked, p_phase: selP.value, p_step_order: Number(ord.value) || 10, p_instruction: ins2.value.trim() || null });
        btn.disabled = false; if (error) return toast(error.message, 'err'); toast('Componente aggiunto'); loadRecipes();
      };
      const c1 = document.createElement('td'); c1.append(selP, document.createTextNode(' '), ord); const c2 = document.createElement('td'); c2.append(selC); const c3 = document.createElement('td'); c3.append(selB);
      const c4 = document.createElement('td'); c4.className = 'num'; c4.append(q2); const c5 = document.createElement('td'); c5.append(ru2); const c6 = document.createElement('td'); c6.append(ins2); const c7 = document.createElement('td'); c7.append(btn);
      add.append(c1, c2, c3, c4, c5, c6, c7); tbl.append(add);
      card.append(tbl); box.append(card);
    });
    const note = document.createElement('div'); note.className = 'hint'; note.textContent = 'Le dosi attuali sono segnaposto finché i partner non confermano caglio, sale, acido citrico e imballi reali. La revisione mensile propone correzioni quando i casari dosano sistematicamente in modo diverso.'; box.append(note);
  }


  // ---------- charts (inline SVG, single scale, hover layer) ----------
  const tip = $('tip');
  const showTip = (e, html) => { tip.innerHTML = html; tip.style.display = 'block'; tip.style.left = (e.clientX + 12) + 'px'; tip.style.top = (e.clientY - 28) + 'px'; };
  const hideTip = () => tip.style.display = 'none';
  const W = 520, H = 200, P = { l: 36, r: 10, t: 10, b: 24 };
  const sx = (i, n) => P.l + (n <= 1 ? 0 : i * (W - P.l - P.r) / (n - 1));
  const ticks = (lo, hi, k = 4) => Array.from({ length: k + 1 }, (_, i) => lo + (hi - lo) * i / k);
  const shortDate = s => s.slice(8, 10) + '/' + s.slice(5, 7);

  function yieldChart(rows, y) {
    const box = $('chart-yield'); if (!rows.length) { box.innerHTML = '<div class="empty">Nessuna produzione negli ultimi 30 giorni.</div>'; return; }
    const vals = rows.map(r => Number(r.yield_pct)); const lo = Math.floor(Math.min(...vals, y.avg_30d || 99) - 1), hi = Math.ceil(Math.max(...vals, y.avg_30d || 0) + 1);
    const sy = v => P.t + (H - P.t - P.b) * (1 - (v - lo) / (hi - lo));
    const n = rows.length, pts = rows.map((r, i) => [sx(i, n), sy(Number(r.yield_pct))]);
    const path = pts.map((p, i) => (i ? 'L' : 'M') + p[0].toFixed(1) + ' ' + p[1].toFixed(1)).join(' ');
    const area = path + ` L${pts[n - 1][0].toFixed(1)} ${sy(lo)} L${pts[0][0].toFixed(1)} ${sy(lo)} Z`;
    const avg = y.avg_30d != null ? `<line x1="${P.l}" x2="${W - P.r}" y1="${sy(y.avg_30d)}" y2="${sy(y.avg_30d)}" stroke="var(--muted)" stroke-dasharray="4 4"/><text x="${W - P.r}" y="${sy(y.avg_30d) - 4}" text-anchor="end">media ${num(y.avg_30d)} %</text>` : '';
    box.innerHTML = `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="Resa mozzarella ultimi 30 giorni">
      <g class="grid">${ticks(lo, hi).map(t => `<line x1="${P.l}" x2="${W - P.r}" y1="${sy(t)}" y2="${sy(t)}"/><text x="${P.l - 6}" y="${sy(t) + 4}" text-anchor="end">${t.toFixed(0)}</text>`).join('')}</g>
      <path d="${area}" fill="var(--series-1)" opacity=".12"/><path d="${path}" fill="none" stroke="var(--series-1)" stroke-width="2" stroke-linejoin="round"/>${avg}
      <circle cx="${pts[n - 1][0]}" cy="${pts[n - 1][1]}" r="4" fill="var(--series-1)" stroke="var(--paper)" stroke-width="2"/>
      ${rows.map((r, i) => i % Math.ceil(n / 6) === 0 ? `<text x="${pts[i][0]}" y="${H - 6}" text-anchor="middle">${shortDate(r.batch_date)}</text>` : '').join('')}
      ${rows.map((r, i) => `<rect x="${pts[i][0] - (W - P.l - P.r) / n / 2}" y="${P.t}" width="${(W - P.l - P.r) / n}" height="${H - P.t - P.b}" fill="transparent" data-i="${i}"/>`).join('')}
    </svg>`;
    box.querySelectorAll('rect[data-i]').forEach(r => { r.onmousemove = e => { const d = rows[r.dataset.i]; showTip(e, `${dateIt(d.batch_date)}<br>resa <b>${num(d.yield_pct)} %</b> · ${num(d.output_kg, 0)} kg`); }; r.onmouseleave = hideTip; });
  }

  function salesChart(rows) {
    const box = $('chart-sales'); if (!rows.length) { box.innerHTML = '<div class="empty">Nessuna vendita negli ultimi 30 giorni.</div>'; return; }
    const days = [...new Set(rows.map(r => r.order_date))].sort();
    const by = {}; rows.forEach(r => { by[r.order_date] = by[r.order_date] || { store: 0, whole: 0 }; by[r.order_date][r.channel === 'wholesale' ? 'whole' : 'store'] += Number(r.revenue_eur); });
    const hi = Math.max(...days.map(d => by[d].store + by[d].whole)) * 1.05, n = days.length;
    const bw = (W - P.l - P.r) / n, sy = v => P.t + (H - P.t - P.b) * (1 - v / hi);
    box.innerHTML = `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="Vendite per canale ultimi 30 giorni">
      <g class="grid">${ticks(0, hi).map(t => `<line x1="${P.l}" x2="${W - P.r}" y1="${sy(t)}" y2="${sy(t)}"/><text x="${P.l - 6}" y="${sy(t) + 4}" text-anchor="end">${(t / 1000).toFixed(1)}k</text>`).join('')}</g>
      ${days.map((d, i) => { const s = by[d].store, w = by[d].whole, x = P.l + i * bw + 1.5, wd = Math.max(1, bw - 3);
        return `<g data-i="${i}"><rect x="${x}" y="${sy(s)}" width="${wd}" height="${Math.max(0, sy(0) - sy(s))}" fill="var(--series-1)" rx="2"/>` +
               (w ? `<rect x="${x}" y="${sy(s + w)}" width="${wd}" height="${Math.max(0, sy(s) - sy(s + w) - 2)}" fill="var(--series-2)" rx="2"/>` : '') +
               `<rect x="${P.l + i * bw}" y="${P.t}" width="${bw}" height="${H - P.t - P.b}" fill="transparent"/></g>`; }).join('')}
      <line class="axis" x1="${P.l}" x2="${W - P.r}" y1="${sy(0)}" y2="${sy(0)}"/>
      ${days.map((d, i) => i % Math.ceil(n / 6) === 0 ? `<text x="${P.l + i * bw + bw / 2}" y="${H - 6}" text-anchor="middle">${shortDate(d)}</text>` : '').join('')}
    </svg>`;
    box.querySelectorAll('g[data-i]').forEach(g => { g.onmousemove = e => { const d = days[g.dataset.i]; showTip(e, `${dateIt(d)}<br>banco <b>${eur(by[d].store)}</b> · ingrosso <b>${eur(by[d].whole)}</b>`); }; g.onmouseleave = hideTip; });
  }

  init();
})();
