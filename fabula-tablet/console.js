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
    if (loaded.ops) { renderPoSend(); renderWholesale(); loadFarm(); loadDemand7(); loadEffluent(); loadShopifyOrders(); }
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
  const KIND = { purchase_order: ['Ordine d’acquisto', 'po'], milk_plan: ['Piano latte', 'milk'], price_change: ['Promo scorte', ''], recipe_update: ['Ricetta', ''], dop_declaration: ['Consorzio DOP', ''], content_post: ['Post social', 'milk'], recall_assessment: ['Sicurezza alimentare', ''], other: ['Richiesta', ''] };
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
      case 'content_post': {
        const cl = p.claims || [], blk = cl.filter(c => c.severity === 'block').length;
        title = `Post ${esc(p.platform || '')}`;
        facts = fact('Canale', esc(p.platform || '—')) + fact('Problemi nel testo', blk ? `${blk} da correggere` : 'nessuno', blk ? 'ko' : '') + fact('Avvisi', String(cl.filter(c => c.severity === 'warn').length));
        more = `<details open><summary>Testo</summary><div style="white-space:pre-wrap;color:var(--fg)">${esc(p.caption_it || '')}</div>${cl.filter(c => c.severity !== 'info').map(c => `<div class="${c.severity === 'block' ? 'ko' : 'status'}">• ${esc(c.message)}</div>`).join('')}<div><a href="marketing.html#calendario">Apri nel calendario ↗</a></div></details>`;
        break;
      }
      case 'recall_assessment': {
        const dist = p.distribution || [];
        title = `Valutare ritiro/richiamo · lotto ${esc(p.lot || 'n/d')}`;
        facts = fact('Analisi', esc(p.test || '')) + fact('Campione', esc(p.sample_code || '')) + fact('Destinazioni', String(dist.length), dist.length ? 'ko' : '');
        more = `<details open><summary>A chi è andato il lotto</summary>${dist.length ? dist.map(d => `<div>• ${esc(d.on_date || '')} · ${esc(d.channel || '')} · ${esc(d.customer || 'banco')} · ${num(d.qty)} kg</div>`).join('') : '<div>Nessuna uscita registrata: il lotto è tutto in giacenza (bloccato).</div>'}<div style="margin-top:6px">Approva = ritiro/richiamo deciso (avvisare ASL Salerno e clienti) · Rifiuta = non necessario, motivare nella nota. <a href="haccp.html#registro">Apri HACCP</a></div></details>`;
        break;
      }
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
    const pc = b.pos_close || {}; if (pc.missing) items.push(['status', 'Nessuna vendita POS sincronizzata per ieri']); else if (pc.variance_eur && Math.abs(pc.variance_eur) > 0.5) items.push(['ko', `Cassa: scostamento ${eur(pc.variance_eur)} tra scontrino Z e registrato`]);
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
  const LOADERS = { ops: () => { renderPoSend(); renderWholesale(); loadFarm(); loadDemand7(); loadEffluent(); loadShopifyOrders(); }, anag: () => { loadParties(); loadTerms(); loadStanding(); loadStaffCard(); }, ricette: () => { loadRecipes(); loadPresets(); } };
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
  async function loadTerms() {
    const box = $('set-terms'); box.innerHTML = '';
    const { data, error } = await sb.from('v_supplier_terms').select('*').order('supplier').order('sku');
    if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    if (!(data || []).length) { box.innerHTML = '<div class="empty">Nessun articolo collegato a un fornitore: imposta un prezzo di listino o il fornitore preferito.</div>'; return; }
    const tbl = document.createElement('table');
    tbl.innerHTML = '<tr><th>Fornitore</th><th>Articolo</th><th class="num">Consegna gg</th><th class="num">Minimo</th><th class="num">Multipli</th><th>Pagamento</th><th class="num">Listino €</th><th class="num">Pagato €</th><th class="num">90 gg</th><th></th></tr>';
    const ni = (v, step) => { const i = document.createElement('input'); i.type = 'number'; i.step = step; i.min = '0'; i.style.width = '70px'; i.value = v ?? ''; return i; };
    data.forEach(r => {
      const tr = document.createElement('tr');
      const trend = r.price_90d_ago_eur && r.last_paid_eur ? Math.round((r.last_paid_eur / r.price_90d_ago_eur - 1) * 1000) / 10 : null;
      tr.innerHTML = `<td>${esc(r.supplier)}${r.preferred ? ' <small class="status">preferito</small>' : ''}</td><td>${esc(r.product)} <small>${esc(r.unit || '')}</small></td>`;
      const lead = ni(r.lead_time_days, '1'), mn = ni(r.min_order_qty, 'any'), mul = ni(r.order_multiple, 'any');
      const pay = document.createElement('input'); pay.type = 'text'; pay.style.width = '110px'; pay.placeholder = 'es. 60 gg DFFM'; pay.value = r.payment_terms || '';
      [lead, mn, mul].forEach(i => { const td = document.createElement('td'); td.className = 'num'; td.append(i); tr.append(td); });
      const tdp = document.createElement('td'); tdp.append(pay); tr.append(tdp);
      const c = (html, cls = 'num') => { const td = document.createElement('td'); td.className = cls; td.innerHTML = html; tr.append(td); };
      c(r.list_price_eur != null ? num(r.list_price_eur, 3) : '–');
      c(r.last_paid_eur != null ? `${num(r.last_paid_eur, 3)}<br><small>${fmtD(r.last_paid_on)}</small>` : '–', 'num' + (r.list_price_eur && r.last_paid_eur && Number(r.last_paid_eur) > Number(r.list_price_eur) ? ' ko' : ''));
      c(trend == null ? '–' : `${trend > 0 ? '+' : ''}${num(trend, 1)}%`, 'num' + (trend > 5 ? ' ko' : ''));
      const td = document.createElement('td'); td.style.whiteSpace = 'nowrap';
      td.append(saveBtn(async () => { await upd('supplier_products', { supplier_id: r.supplier_id, product_id: r.product_id }, { lead_time_days: nOrNull(lead.value), min_order_qty: nOrNull(mn.value), order_multiple: nOrNull(mul.value), payment_terms: pay.value.trim() || null, updated_at: new Date().toISOString() }); loadTerms(); }));
      const h = document.createElement('button'); h.className = 'btn sm sec'; h.textContent = '↗'; h.title = 'Storico prezzi'; h.style.marginLeft = '4px';
      h.onclick = () => loadPriceHist(r); td.append(h); tr.append(td);
      tbl.append(tr);
    });
    box.append(tbl);
  }
  async function loadPriceHist(r) {
    const box = $('price-hist'); box.innerHTML = '<div class="status">Carico…</div>';
    const { data, error } = await sb.from('v_supplier_price_history').select('*').eq('supplier_id', r.supplier_id).eq('product_id', r.product_id).order('price_date', { ascending: false }).limit(40);
    if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    box.innerHTML = `<h4 style="margin:14px 0 6px">Storico prezzi · ${esc(r.product)} da ${esc(r.supplier)}</h4>`;
    if (!(data || []).length) { box.innerHTML += '<div class="empty">Ancora nessun prezzo.</div>'; return; }
    const tbl = document.createElement('table');
    tbl.innerHTML = '<tr><th>Data</th><th>Fonte</th><th>Rif.</th><th class="num">Qtà</th><th class="num">€ / ' + esc(r.unit || 'unità') + '</th><th class="num">Var.</th></tr>' +
      data.map(x => `<tr><td>${fmtD(x.price_date)}</td><td>${esc(x.source)}</td><td>${esc(x.ref || '')}</td><td class="num">${x.qty != null ? num(x.qty, 0) : ''}</td><td class="num">${num(x.price_eur, 4)}</td><td class="num ${Number(x.change_pct) > 5 ? 'ko' : ''}">${x.change_pct != null ? (x.change_pct > 0 ? '+' : '') + num(x.change_pct, 1) + '%' : ''}</td></tr>`).join('');
    box.append(tbl);
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
    const isCus = partyType === 'customer';
    tbl.innerHTML = isCus
      ? `<tr><th>Cliente</th><th>Email</th><th>Telefono</th><th>Tag</th><th class="num">Ordini</th><th class="num">Speso</th><th class="num">Pag. gg</th><th>Ordini fissi</th><th></th></tr>`
      : `<tr><th>Nome / ragione sociale</th><th>Email</th><th>Telefono / WhatsApp</th><th class="num">Pag. gg</th><th>Articoli</th><th></th></tr>`;
    rows.forEach(p => {
      const tr = document.createElement('tr'); if (p.is_placeholder) tr.className = 'ph';
      const mk = (type, k, v, ph = '') => { const i = document.createElement(type === 'number' ? 'input' : 'input'); i.type = type; i.dataset.k = k; i.value = v ?? ''; i.placeholder = ph; return i; };
      const days = mk('number', 'payment_terms_days', p.payment_terms_days);
      if (isCus) {
        // Shopify is the source of truth: name, e-mail, phone, tags are read-only here
        const fromShopify = p.source === 'shopify';
        const t1 = document.createElement('td'); t1.innerHTML = `<b>${esc(p.legal_name)}</b>${p.city ? ` <small class="status">${esc(p.city)}</small>` : ''}<br><small class="${p.is_placeholder ? 'status ko' : 'status'}">${p.is_placeholder ? 'segnaposto · crealo su Shopify' : fromShopify ? 'Shopify' : 'locale (non su Shopify)'}</small>`;
        const t2 = document.createElement('td'); t2.textContent = p.email || '—'; const t3 = document.createElement('td'); t3.textContent = p.phone || '—';
        const t4 = document.createElement('td'); t4.innerHTML = (p.is_wholesale ? '<span class="kind" style="border-color:var(--accent);color:var(--accent);font-size:.75rem;padding:0 5px;border-radius:3px;border:1.5px solid">ingrosso</span> ' : '') + (p.tags || []).filter(t => !['ingrosso', 'b2b', 'wholesale', 'horeca'].includes(t)).map(t => `<small class="status">${esc(t)}</small>`).join(' ');
        const t5 = document.createElement('td'); t5.className = 'num'; t5.textContent = p.orders_count ?? '—'; const t6 = document.createElement('td'); t6.className = 'num'; t6.textContent = p.total_spent_eur != null ? eur(p.total_spent_eur) : '—';
        const t7 = document.createElement('td'); t7.className = 'num'; t7.append(days);
        const t8 = document.createElement('td'); t8.className = 'status'; t8.textContent = p.standing_orders ? p.standing_orders + ' giorni' : '—';
        const t9 = document.createElement('td'); t9.style.whiteSpace = 'nowrap';
        t9.append(saveBtn(async () => { await upd('parties', { id: p.id }, { payment_terms_days: nOrNull(days.value) }); loadParties(); }));
        if (fromShopify && p.shopify_customer_id) { const a = document.createElement('a'); a.className = 'btn sm sec'; a.style.cssText = 'text-decoration:none;margin-left:6px'; a.target = '_blank'; a.textContent = 'Shopify ↗'; a.href = 'https://admin.shopify.com/store/pxssjd-cq/customers/' + p.shopify_customer_id.split('/').pop(); t9.append(a); }
        tr.append(t1, t2, t3, t4, t5, t6, t7, t8, t9); tbl.append(tr); return;
      }
      const name = mk('text', 'legal_name', p.legal_name), email = mk('email', 'email', p.email, '—'), phone = mk('tel', 'phone', p.phone, '+39 …');
      const t1 = document.createElement('td'); t1.append(name); if (p.is_placeholder) { const s = document.createElement('small'); s.className = 'status ko'; s.textContent = 'segnaposto'; t1.append(document.createElement('br'), s); }
      const t2 = document.createElement('td'); t2.append(email); const t3 = document.createElement('td'); t3.append(phone); const t4 = document.createElement('td'); t4.className = 'num'; t4.append(days);
      const t5 = document.createElement('td'); t5.className = 'status'; t5.textContent = p.products_supplied ? p.products_supplied + ' articoli' : '—';
      const t6 = document.createElement('td'); t6.style.whiteSpace = 'nowrap';
      t6.append(saveBtn(async () => {
        const v = {}; tr.querySelectorAll('input[data-k]').forEach(i => { v[i.dataset.k] = i.type === 'number' ? nOrNull(i.value) : (i.value.trim() || null); });
        if (!v.legal_name) throw new Error('Il nome è obbligatorio');
        if (p.is_placeholder && !/^(Fornitore|Cliente) \d/.test(v.legal_name)) { v.notes = null; v.source = 'manual'; }   // renamed → no longer a placeholder
        await upd('parties', { id: p.id }, v); loadParties(); refreshBadges();
      }));
      tr.append(t1, t2, t3, t4, t5, t6); tbl.append(tr);
    });
    if (isCus) {
      box.append(tbl);
      const h = document.createElement('div'); h.className = 'hint'; h.style.marginTop = '8px';
      const last = PARTIES.filter(p => p.type === 'customer' && p.last_synced_at).map(p => p.last_synced_at).sort().pop();
      h.innerHTML = `I clienti si creano e si modificano su <b>Shopify → Clienti</b>; il bot "Clienti Shopify" li copia qui ogni mattina (ultima sincronizzazione: ${last ? new Date(last).toLocaleString('it-IT', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' }) : 'mai'}). Tag <b>ingrosso</b> su Shopify = cliente all'ingrosso qui. Un segnaposto con la stessa e-mail viene adottato automaticamente.`;
      box.append(h); return;
    }
    // new supplier row
    const add = document.createElement('tr'); add.style.background = 'var(--tile)';
    const nn = document.createElement('input'); nn.type = 'text'; nn.placeholder = 'Nuovo fornitore…';
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
      sb.from('parties').select('id, legal_name').eq('type', 'customer').eq('active', true).eq('is_wholesale', true).order('legal_name'),
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
    const note = document.createElement('div'); note.className = 'status'; note.style.marginTop = '6px'; note.textContent = 'Prezzo ingrosso: Configurazione → Vendite. Qui compaiono solo i clienti con tag ingrosso su Shopify.'; box.append(note);
  }
  async function loadDemand7() {
    const box = $('demand7'); box.innerHTML = '';
    const { data, error } = await sb.from('v_demand_7d').select('*');
    if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    if (!(data || []).length) { box.innerHTML = '<div class="empty">Nessun giorno di produzione nei prossimi 7 giorni.</div>'; return; }
    const tbl = document.createElement('table');
    tbl.innerHTML = '<tr><th>Giorno</th><th class="num">Banco kg</th><th class="num">Ingrosso kg</th><th class="num">Preordini kg</th><th class="num">Mozzarella kg</th><th class="num">Latte kg</th><th class="num">Masseria kg</th><th>Piano</th></tr>';
    const t = { r: 0, w: 0, p: 0, o: 0, m: 0, f: 0, c: 0 };
    data.forEach(r => {
      const d = new Date(r.plan_date + 'T12:00:00');
      const short = Number(r.farm_gap_kg) < 0, cap = r.capacity_hit;
      t.r += +r.retail_kg; t.w += +r.wholesale_kg; t.p += +r.preorder_kg; t.o += +r.output_kg; t.m += +r.milk_kg; t.f += +r.farm_kg; t.c += +r.est_cost_eur;
      const plan = r.plan_status ? `${r.plan_status === 'approved' ? 'approvato' : 'proposto'} ${num(r.plan_milk_kg, 0)} kg` : '–';
      const tr = document.createElement('tr');
      tr.innerHTML = `<td>${d.toLocaleDateString('it-IT', { weekday: 'short', day: 'numeric', month: 'short' })}${Number(r.history_days) < 2 ? ' <small class="status">poco storico</small>' : ''}</td>
        <td class="num">${num(r.retail_kg, 0)}</td><td class="num" title="${esc(r.wholesale_source)}">${num(r.wholesale_kg, 0)}</td><td class="num">${Number(r.preorder_kg) ? num(r.preorder_kg, 0) : '–'}</td>
        <td class="num">${num(r.output_kg, 0)}</td><td class="num${cap ? ' ko' : ''}" title="${cap ? 'Serve più della capacità della caldaia' : ''}">${num(r.milk_kg, 0)}${cap ? ' ▲' : ''}</td>
        <td class="num${short ? ' ko' : ''}">${num(r.farm_kg, 0)}${short ? ` (−${num(-r.farm_gap_kg, 0)})` : ''}</td><td><small>${plan}</small></td>`;
      tbl.append(tr);
    });
    const tf = document.createElement('tr'); tf.style.fontWeight = '600';
    tf.innerHTML = `<td>Totale</td><td class="num">${num(t.r, 0)}</td><td class="num">${num(t.w, 0)}</td><td class="num">${t.p ? num(t.p, 0) : '–'}</td><td class="num">${num(t.o, 0)}</td><td class="num">${num(t.m, 0)}</td><td class="num">${num(t.f, 0)}</td><td><small>€ ${num(t.c, 0)} latte</small></td>`;
    tbl.append(tf); box.append(tbl);
    const capDays = data.filter(r => r.capacity_hit).length, shortDays = data.filter(r => Number(r.farm_gap_kg) < 0).length;
    const note = document.createElement('div'); note.className = 'status'; note.style.marginTop = '6px';
    note.textContent = `Resa usata ${num(data[0].yield_pct, 1)}% (media 30 gg). ` + (capDays ? `${capDays} giorni oltre la capacità della caldaia (▲): anticipare produzione o aumentare i turni. ` : '') + (shortDays ? `${shortDays} giorni la Masseria non basta: serve latte da altri fornitori.` : 'La Masseria copre tutti i giorni.');
    box.append(note);
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
  // ---------- process presets (machine settings per step) ----------
  const PPHASE = { start: 'Avvio', make: 'Lavorazione', close: 'Chiusura' };
  const PMETRIC = { none: '—', temp: 'temperatura', duration: 'durata', ph: 'pH', speed: 'velocità' };
  const chosenPreset = {};
  async function loadPresets() {
    const box = $('presets'); box.innerHTML = '';
    const [{ data: res, error }, { data: steps }, { data: eq }] = await Promise.all([
      sb.from('v_preset_results').select('*').order('product_sku').order('created_at'),
      sb.from('v_process_steps').select('*').eq('active', true).order('phase').order('step_order'),
      sb.from('equipment').select('id, code, name').eq('active', true).order('code')]);
    if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    const byProd = {}; (res || []).forEach(r => (byProd[r.product_id] = byProd[r.product_id] || []).push(r));
    Object.values(byProd).forEach(list => {
      const prod = list[0];
      const card = document.createElement('div'); card.className = 'card'; card.style.marginBottom = '16px';
      card.innerHTML = `<h3>${esc(prod.product_name)} <small class="status">${esc(prod.product_sku)}</small></h3>`;
      const active = list.filter(p => p.active);
      const cur = chosenPreset[prod.product_id] && active.find(p => p.preset_id === chosenPreset[prod.product_id]) ? chosenPreset[prod.product_id] : (active.find(p => p.is_default) || active[0] || {}).preset_id;
      const chips = document.createElement('div');
      active.forEach(p => { const b = document.createElement('span'); b.className = 'pchip' + (p.preset_id === cur ? ' on' : ''); b.innerHTML = `${p.is_default ? '★ ' : ''}${esc(p.name)} <small>· ${p.n_steps} passi${p.n_batches ? ` · ${p.n_batches} lotti · resa ${p.avg_yield_pct ?? '—'}%` : ''}</small>`; b.onclick = () => { chosenPreset[prod.product_id] = p.preset_id; loadPresets(); }; chips.append(b); });
      card.append(chips);
      const P = active.find(p => p.preset_id === cur); if (!P) { card.append(Object.assign(document.createElement('div'), { className: 'empty', textContent: 'Nessun preset attivo.' })); box.append(card); return; }
      const meta = document.createElement('div'); meta.className = 'status'; meta.style.margin = '6px 0 10px';
      meta.innerHTML = `${esc(P.description || '')}${P.based_on_name ? ` · da «${esc(P.based_on_name)}»` : ''}${P.n_batches ? ` · <b>${P.n_batches} lotti</b>, resa media <b>${P.avg_yield_pct ?? '—'}%</b>, pH medio ${P.avg_curd_ph ?? '—'}, scostamento medio dai valori obiettivo ${P.avg_abs_dev_pct ?? '—'}%` : ' · nessun lotto ancora prodotto con questo preset'}`;
      card.append(meta);
      const bar = document.createElement('div'); bar.style.margin = '0 0 10px';
      const mk = (t, cls, fn, title) => { const b = document.createElement('button'); b.className = 'btn sm ' + cls; b.textContent = t; b.title = title || ''; b.style.marginRight = '6px'; b.onclick = async () => { b.disabled = true; try { await fn(); } catch (e) { toast(e.message, 'err'); } b.disabled = false; }; return b; };
      bar.append(mk('Copia come nuovo preset', '', async () => { const name = prompt('Nome del nuovo preset (es. "Estate · filatura 94")'); if (!name) return; const { data, error } = await sb.rpc('clone_preset', { p_preset_id: P.preset_id, p_name: name, p_staff_id: null }); if (error) throw error; chosenPreset[prod.product_id] = data; toast('Preset copiato: modifica i passi e provalo sul prossimo lotto'); loadPresets(); }, 'Duplica tutti i passi in un preset con un altro nome'));
      if (!P.is_default) bar.append(mk('Rendi predefinito', 'sec', async () => { const { error } = await sb.rpc('set_default_preset', { p_preset_id: P.preset_id }); if (error) throw error; toast('Preset predefinito aggiornato'); loadPresets(); }, 'Il tablet lo propone all\'avvio del lotto'));
      if (!P.is_default) bar.append(mk('Archivia', 'sec', async () => { if (!confirm('Archiviare il preset «' + P.name + '»? I lotti già prodotti restano collegati.')) return; await upd('process_presets', { id: P.preset_id }, { active: false, updated_at: new Date().toISOString() }); toast('Preset archiviato'); loadPresets(); }));
      card.append(bar);
      const mine = (steps || []).filter(s => s.preset_id === P.preset_id);
      const tbl = document.createElement('table'); tbl.className = 'rec';
      tbl.innerHTML = '<tr><th>Fase · ordine</th><th>Passo</th><th>Macchina</th><th>°C (min–max)</th><th>Minuti (min–max)</th><th>Velocità</th><th>pH (min–max)</th></tr>';
      const num = (v, step = 'any', ph = '') => { const i = document.createElement('input'); i.type = 'number'; i.step = step; i.className = 'n'; i.value = v ?? ''; i.placeholder = ph; return i; };
      const eqSel = (v) => { const sel = document.createElement('select'); sel.className = 'eq'; sel.innerHTML = '<option value="">—</option>' + (eq || []).map(e => `<option value="${e.id}" ${e.id === v ? 'selected' : ''}>${esc(e.code)} ${esc(e.name)}</option>`).join(''); return sel; };
      const phSel = (v) => { const sel = document.createElement('select'); sel.className = 'phs'; sel.innerHTML = Object.entries(PPHASE).map(([k, l]) => `<option value="${k}" ${k === v ? 'selected' : ''}>${l}</option>`).join(''); return sel; };
      const mSel = (v) => { const sel = document.createElement('select'); sel.innerHTML = Object.entries(PMETRIC).map(([k, l]) => `<option value="${k}" ${k === v ? 'selected' : ''}>${l}</option>`).join(''); return sel; };
      const extraTxt = x => Object.entries(x || {}).map(([k, v]) => `${k}: ${v}`).join(' · ');
      const parseExtra = t => { const o = {}; t.split(/\s*[·;\n]\s*/).map(p => p.trim()).filter(Boolean).forEach(p => { const m = p.match(/^([^:]+):\s*(.+)$/); if (m) o[m[1].trim()] = m[2].trim(); }); return o; };
      const row = (st) => {
        const tr = document.createElement('tr'); if (!st) tr.style.background = 'var(--tile)';
        const ph = phSel(st?.phase || 'make'), ord = num(st?.step_order ?? (mine.length + 1) * 10, '1', 'ordine'); ord.style.width = '58px';
        const name = document.createElement('input'); name.type = 'text'; name.className = 'w'; name.value = st?.name_it || ''; name.placeholder = 'es. Filatura';
        const eqs = eqSel(st?.equipment_id);
        const t1 = num(st?.target_temp_c, '0.5', '°C'), t2 = num(st?.temp_min_c, '0.5', 'min'), t3 = num(st?.temp_max_c, '0.5', 'max');
        const d1 = num(st?.duration_min, '1', 'min'), d2 = num(st?.duration_min_min, '1', 'min'), d3 = num(st?.duration_max_min, '1', 'max');
        const sp = num(st?.speed, '0.1', 'vel.'), su = document.createElement('input'); su.type = 'text'; su.className = 'sh'; su.value = st?.speed_unit || ''; su.placeholder = 'unità';
        const p1 = num(st?.target_ph, '0.01', 'pH'), p2 = num(st?.ph_min, '0.01', 'min'), p3 = num(st?.ph_max, '0.01', 'max');
        const ex = document.createElement('input'); ex.type = 'text'; ex.className = 'w'; ex.value = extraTxt(st?.extra); ex.placeholder = 'es. salamoia: 15% · tamburo: 250 g';
        const ins = document.createElement('input'); ins.type = 'text'; ins.className = 'w'; ins.value = st?.instruction_it || ''; ins.placeholder = 'cosa deve fare il casaro';
        const met = mSel(st?.record_metric || 'none');
        const payload = () => ({ preset_id: P.preset_id, phase: ph.value, step_order: Number(ord.value) || 10, name_it: name.value.trim(), equipment_id: eqs.value || null,
          target_temp_c: t1.value === '' ? null : Number(t1.value), temp_min_c: t2.value === '' ? null : Number(t2.value), temp_max_c: t3.value === '' ? null : Number(t3.value),
          duration_min: d1.value === '' ? null : Number(d1.value), duration_min_min: d2.value === '' ? null : Number(d2.value), duration_max_min: d3.value === '' ? null : Number(d3.value),
          speed: sp.value === '' ? null : Number(sp.value), speed_unit: su.value.trim() || null, target_ph: p1.value === '' ? null : Number(p1.value), ph_min: p2.value === '' ? null : Number(p2.value), ph_max: p3.value === '' ? null : Number(p3.value),
          extra: parseExtra(ex.value), instruction_it: ins.value.trim() || null, record_metric: met.value, updated_at: new Date().toISOString() });
        const rng = () => Object.assign(document.createElement('span'), { className: 'rng', textContent: '–' });
        const cells = [[ph, ' ', ord], [name], [eqs], [t1, ' ', t2, rng(), t3], [d1, ' ', d2, rng(), d3], [sp, ' ', su], [p1, ' ', p2, rng(), p3]];
        cells.forEach(parts => { const td = document.createElement('td'); td.style.whiteSpace = 'nowrap'; parts.forEach(p => td.append(typeof p === 'string' ? document.createTextNode(p) : p)); tr.append(td); });
        // second line: free-text settings + the instruction the casaro reads
        const sub = document.createElement('tr'); sub.className = 'stepsub'; if (!st) sub.style.background = 'var(--tile)';
        const sTd = document.createElement('td'); sTd.colSpan = 7; sTd.style.whiteSpace = 'nowrap'; sTd.style.flex = '1 1 100%';
        const grid = document.createElement('div'); grid.style.cssText = 'display:grid;grid-template-columns:auto 1fr auto 2fr auto auto auto;gap:6px 8px;align-items:center;padding-bottom:6px';
        const tdB = document.createElement('span'); tdB.style.whiteSpace = 'nowrap';
        grid.append(Object.assign(document.createElement('span'), { textContent: 'Altro' }), ex, Object.assign(document.createElement('span'), { textContent: 'Istruzione' }), ins, Object.assign(document.createElement('span'), { textContent: 'Il tablet registra' }), met, tdB);
        sTd.append(grid); sub.append(sTd);
        if (st) {
          tdB.append(saveBtn(async () => { const p = payload(); if (!p.name_it) throw new Error('Dai un nome al passo'); await upd('process_steps', { id: st.step_id }, p); loadPresets(); }));
          const rm = document.createElement('button'); rm.className = 'btn sm sec'; rm.textContent = 'Togli'; rm.style.marginLeft = '6px'; rm.title = 'Il passo non compare più sul tablet';
          rm.onclick = async () => { rm.disabled = true; try { await upd('process_steps', { id: st.step_id }, { active: false, updated_at: new Date().toISOString() }); toast('Passo tolto'); loadPresets(); } catch (e) { toast(e.message, 'err'); rm.disabled = false; } };
          tdB.append(rm);
        } else {
          const add = document.createElement('button'); add.className = 'btn sm'; add.textContent = 'Aggiungi';
          add.onclick = async () => { const p = payload(); if (!p.name_it) return toast('Dai un nome al passo', 'err'); add.disabled = true; const { error } = await sb.from('process_steps').insert(p); add.disabled = false; if (error) return toast(error.message, 'err'); toast('Passo aggiunto'); loadPresets(); };
          tdB.append(add);
        }
        const frag = document.createDocumentFragment(); frag.append(tr, sub); return frag;
      };
      mine.forEach(st => tbl.append(row(st))); tbl.append(row(null));
      const wrap = document.createElement('div'); wrap.style.overflowX = 'auto'; wrap.append(tbl); card.append(wrap); box.append(card);
    });
    if (!Object.keys(byProd).length) box.innerHTML = '<div class="empty">Nessun preset: vengono creati con la migrazione v0.26.</div>';
  }

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


  const OSTATUS = { draft: ['non pagato', 'status'], confirmed: ['pagato · da spedire', 'ko'], fulfilled: ['spedito', 'ok'], cancelled: ['annullato', 'status'], refunded: ['rimborsato', 'status'] };
  async function loadShopifyOrders() {
    const box = $('shopify-orders');
    const { data, error } = await sb.from('v_shopify_orders_recent').select('*').limit(25);
    if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    if (!data || !data.length) { box.innerHTML = '<div class="empty">Nessun ordine online negli ultimi 14 giorni.</div>'; return; }
    const toShip = data.filter(o => o.status === 'confirmed').length, unm = data.reduce((a, o) => a + Number(o.unmapped || 0), 0);
    let html = `<div class="status" style="margin-bottom:6px">${data.length} ordini · <b class="${toShip ? 'ko' : ''}">${toShip} da spedire</b> · ${eur(data.reduce((a, o) => a + Number(o.total_eur || 0), 0))}${unm ? ` · <span class="ko">${unm} righe da collegare al magazzino</span>` : ''}</div>`;
    html += '<table class="nw2"><tr><th>Ordine</th><th>Giorno</th><th>Cliente</th><th>Cosa</th><th class="num">€</th><th>Stato</th></tr>' + data.map(o => { const [lbl, cls] = OSTATUS[o.status] || [o.status, '']; return `<tr><td>${esc(o.order_number)}</td><td>${fmtD(o.order_date).slice(0, 5)}</td><td>${esc(o.customer || '—')}${o.ship_city ? ` <small class="status">${esc(o.ship_city)}</small>` : ''}</td><td>${esc(o.lines_txt || '')}${o.unmapped ? ` <small class="ko">+${o.unmapped} non collegate</small>` : ''}</td><td class="num">${eur(o.total_eur)}</td><td class="${cls}">${lbl}${o.stock_booked ? ' ✓' : ''}</td></tr>`; }).join('') + '</table>';
    box.innerHTML = html;
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
