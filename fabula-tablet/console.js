/* La Perla owner console — reads fabula.daily_brief() + 30-day series, approves/rejects fabula.approvals rows. */
(() => {
  const CFG = window.FABULA_CONFIG;
  const sb = supabase.createClient(CFG.supabaseUrl, CFG.supabaseKey, { db: { schema: 'fabula' } });
  const $ = id => document.getElementById(id);
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
    $('who').textContent = staff.full_name; $('btn-logout').hidden = false; $('btn-refresh').hidden = false;
    show('main'); load();
  }
  $('btn-login').onclick = async () => { const { error } = await sb.auth.signInWithPassword({ email: $('email').value, password: $('pw').value }); if (error) return toast(error.message, 'err'); init(); };
  $('pw').addEventListener('keydown', e => { if (e.key === 'Enter') $('btn-login').click(); });
  $('btn-logout').onclick = async () => { await sb.auth.signOut(); location.reload(); };
  $('btn-refresh').onclick = () => load();

  // ---------- data ----------
  async function load() {
    const [brief, prod, sales, runs] = await Promise.all([
      sb.rpc('daily_brief'),
      sb.from('v_daily_production').select('batch_date, product, yield_pct, output_kg').ilike('product', 'Mozzarella%').gte('batch_date', daysAgo(30)).order('batch_date'),
      sb.from('v_daily_sales').select('order_date, channel, revenue_eur').gte('order_date', daysAgo(30)).order('order_date'),
      sb.from('agent_runs').select('agent, started_at, status, summary, error').order('started_at', { ascending: false }).limit(8)
    ]);
    if (brief.error) return toast('daily_brief: ' + brief.error.message, 'err');
    const b = brief.data;
    $('simbadge').hidden = !b.is_simulation;
    $('sub').textContent = 'Brief di ' + dateIt(b.date);
    renderTiles(b); renderApprovals(b.pending_approvals); renderHaccp(b); renderStock(b.stock_finished, b.date); renderProcurement(b.procurement_signals); renderRuns(runs.data || []);
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

  // ---------- approvals ----------
  function renderApprovals(list) {
    const box = $('approvals');
    if (!list || !list.length) { box.innerHTML = '<div class="empty">Niente in attesa. I bot propongono, tu decidi: tutto ciò che impegna denaro o documenti compare qui prima.</div>'; return; }
    box.innerHTML = list.map(a => `
      <div class="appr" data-id="${a.id}">
        <div class="k">${esc(a.kind).replace('_', ' ')} · ${esc(a.requested_by)} · ${a.age_days} g</div>
        <div class="s">${esc(a.summary)}</div>
        <div class="meta">${a.amount_eur != null ? eur(a.amount_eur) : ''}</div>
        <div class="row"><input type="text" placeholder="Nota (facoltativa)" id="note-${a.id}"><button class="btn" data-act="approved">Approva</button><button class="btn warn" data-act="rejected">Rifiuta</button></div>
      </div>`).join('');
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
  function renderRuns(list) {
    $('runs').innerHTML = list.length ? '<table>' + list.map(r => `<tr><td>${esc(r.agent)}</td><td class="status">${new Date(r.started_at).toLocaleString('it-IT', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' })}</td><td class="${r.status === 'ok' ? 'ok' : 'ko'}">${esc(r.status)}</td></tr>`).join('') + '</table>' : '<div class="empty">Nessuna esecuzione registrata.</div>';
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
