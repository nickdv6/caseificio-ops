/* La Perla owner console — five tabs. Oggi: daily_brief() tiles + approvals gate; Operazioni: PO send, wholesale, farm supply; Andamento: charts; Anagrafiche: parties, standing orders, staff; Impostazioni: settings, machines, deadlines, account. */
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
    $('who').textContent = staff.full_name; $('btn-logout').hidden = false; $('btn-refresh').hidden = false; $('btn-pkg').hidden = false;
    show('main'); load(); showTab((location.hash || '#oggi').slice(1).replace(/[^a-z]/g, '') || 'oggi', false);
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
    badge('n-oggi', (b.pending_approvals || []).length); refreshBadges();
    if (loaded.ops) { renderPoSend(); renderWholesale(); loadFarm(); }
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

  // ---------- settings & dates editor ----------
  const GROUPS = { milk: 'Piano latte', sell: 'Vendere prima', opex: 'Benchmark OpEx (€/anno)', price: 'Prezzi', farm: 'Masseria (latte)', energy: 'Energia', labor: 'Lavoro' };
  // ---------- tabs (lazy: each pane loads the first time it is opened; Oggi loads with the brief) ----------
  const loaded = {};
  const LOADERS = { ops: () => { renderPoSend(); renderWholesale(); loadFarm(); }, anag: () => { loadParties(); loadStanding(); loadStaffCard(); }, set: () => loadSettings() };
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
  async function loadSettings() {
    const [s, e, d] = await Promise.all([
      sb.from('settings').select('*').order('key'),
      sb.from('v_equipment_schedule').select('*'),
      sb.from('compliance_deadlines').select('*').is('done_on', null).order('due_on', { nullsFirst: false })]);
    renderParams(s.data || []); renderEquipment(e.data || []); renderDeadlines(d.data || []);
  }
  async function loadStaffCard() {
    const { data } = await sb.from('staff').select('id, full_name, role, haccp_training_expires, active').eq('active', true).order('full_name');
    renderStaff(data || []);
  }
  $('pw-save').onclick = async () => {
    const pw = $('pw-new').value; if (pw.length < 8) return toast('Minimo 8 caratteri', 'err');
    $('pw-save').disabled = true; const { error } = await sb.auth.updateUser({ password: pw }); $('pw-save').disabled = false;
    if (error) return toast(error.message, 'err'); $('pw-new').value = ''; toast('Password cambiata');
  };
  const canEdit = () => ['owner', 'partner'].includes(staff.role);
  const saveBtn = (fn) => { const b = document.createElement('button'); b.className = 'btn sm'; b.textContent = 'Salva'; b.onclick = async () => { b.disabled = true; try { await fn(); toast('Salvato'); } catch (err) { toast(err.message || String(err), 'err'); } finally { b.disabled = false; } }; return b; };
  const upd = async (table, match, row) => { const { error } = await sb.from(table).update(row).match(match); if (error) throw error; };
  const dOrNull = v => v || null, nOrNull = v => v === '' || v == null ? null : Number(v);

  function renderParams(rows) {
    const box = $('set-params'); box.innerHTML = '';
    if (!canEdit()) { const n = document.createElement('div'); n.className = 'empty'; n.textContent = 'Solo titolare e partner possono modificare i parametri.'; box.append(n); }
    let last = '', det = null, first = true;
    rows.forEach(r => {
      const g = r.key.split('.')[0];
      if (g !== last) {
        last = g; det = document.createElement('details'); det.className = 'grp'; det.open = first; first = false;
        const sm = document.createElement('summary'); sm.innerHTML = `<span>${esc(GROUPS[g] || g)}</span><span class="status">${rows.filter(x => x.key.split('.')[0] === g).length} parametri</span>`;
        det.append(sm); box.append(det);
      }
      const row = document.createElement('div'); row.className = 'set-row';
      row.innerHTML = `<div class="lbl">${esc(r.description || r.key)}<small>${esc(r.key)}</small></div>`;
      const right = document.createElement('div'); right.className = 'row'; right.style.marginTop = '0';
      const inp = document.createElement('input'); inp.type = 'text'; inp.value = r.value; inp.inputMode = 'decimal'; inp.disabled = !canEdit(); inp.oninput = () => row.classList.add('dirty');
      right.append(inp);
      if (canEdit()) right.append(saveBtn(async () => { if (inp.value.trim() === '' || isNaN(Number(inp.value.replace(',', '.')))) throw new Error('Inserisci un numero'); await upd('settings', { key: r.key }, { value: String(Number(inp.value.replace(',', '.'))) }); row.classList.remove('dirty'); }));
      row.append(right); det.append(row);
    });
  }
  const fmtD = s => s ? s.slice(8, 10) + '/' + s.slice(5, 7) + '/' + s.slice(0, 4) : '—';
  const dueCls = s => { if (!s) return ''; const d = (new Date(s) - new Date(new Date().toISOString().slice(0, 10))) / 864e5; return d < 0 ? 'ko' : d <= 30 ? 'ko' : ''; };
  function renderEquipment(rows) {
    const box = $('set-equipment'); box.innerHTML = '';
    rows.filter(r => r.active).forEach(r => {
      const c = document.createElement('div'); c.className = 'eq';
      c.innerHTML = `<div class="h"><b>${esc(r.name)}</b><span class="status">${esc(r.code)}</span></div>
        <div class="f">
          <div><label>Ultima taratura</label><input type="date" data-k="last_calibrated_on" value="${r.last_calibrated_on || ''}"></div>
          <div><label>Ogni (giorni)</label><input type="number" data-k="calibration_interval_days" value="${r.calibration_interval_days ?? ''}" placeholder="—"></div>
          <div><label>Ultima manutenzione</label><input type="date" data-k="last_maintenance_on" value="${r.last_maintenance_on || ''}"></div>
          <div><label>Ogni (giorni)</label><input type="number" data-k="maintenance_interval_days" value="${r.maintenance_interval_days ?? ''}" placeholder="—"></div>
          <div style="grid-column:1/-1"><label>Tecnico / contatto</label><input type="text" data-k="technician_contact" value="${esc(r.technician_contact || '')}" placeholder="nome, telefono"></div>
        </div>
        <div class="next">prossima taratura <span class="${dueCls(r.next_calibration_on)}">${fmtD(r.next_calibration_on)}</span> · prossima manutenzione <span class="${dueCls(r.next_maintenance_on)}">${fmtD(r.next_maintenance_on)}</span></div>`;
      const row = document.createElement('div'); row.className = 'row';
      row.append(saveBtn(async () => {
        const v = {}; c.querySelectorAll('input[data-k]').forEach(i => { v[i.dataset.k] = i.type === 'date' ? dOrNull(i.value) : i.type === 'number' ? nOrNull(i.value) : (i.value.trim() || null); });
        await upd('equipment', { id: r.id }, v); loadSettings();
      }));
      c.append(row); box.append(c);
    });
  }
  function renderDeadlines(rows) {
    const box = $('set-deadlines'); box.innerHTML = '';
    if (!rows.length) box.innerHTML = '<div class="empty">Nessuna scadenza aperta.</div>';
    rows.forEach(r => {
      const c = document.createElement('div'); c.className = 'eq';
      c.innerHTML = `<div class="h"><b>${esc(r.subject_it)}</b><span class="status ${dueCls(r.due_on)}">${r.due_on ? 'scade ' + fmtD(r.due_on) : 'data da impostare'}</span></div>
        <div class="f">
          <div><label>Scadenza</label><input type="date" data-k="due_on" value="${r.due_on || ''}"></div>
          <div><label>Ogni (giorni)</label><input type="number" data-k="interval_days" value="${r.interval_days ?? ''}" placeholder="una tantum"></div>
          <div><label>Responsabile</label><input type="text" data-k="responsible" value="${esc(r.responsible || '')}"></div>
          <div><label>Fornitore / contatto</label><input type="text" data-k="contact" value="${esc(r.contact || '')}"></div>
          <div style="grid-column:1/-1"><label>Note</label><input type="text" data-k="notes" value="${esc(r.notes || '')}"></div>
        </div>`;
      const row = document.createElement('div'); row.className = 'row';
      row.append(saveBtn(async () => { const v = {}; c.querySelectorAll('input[data-k]').forEach(i => { v[i.dataset.k] = i.type === 'date' ? dOrNull(i.value) : i.type === 'number' ? nOrNull(i.value) : (i.value.trim() || null); }); await upd('compliance_deadlines', { id: r.id }, v); loadSettings(); }));
      const done = document.createElement('button'); done.className = 'btn sm sec'; done.textContent = 'Fatto oggi';
      done.onclick = async () => { done.disabled = true; const { error } = await sb.rpc('complete_deadline', { p_id: r.id }); if (error) { toast(error.message, 'err'); done.disabled = false; return; } toast(r.interval_days ? 'Chiusa · prossima aperta' : 'Chiusa'); loadSettings(); };
      row.append(done); c.append(row); box.append(c);
    });
  }
  $('dl-add').onclick = async () => {
    const subj = $('dl-new-subject').value.trim(); if (!subj) return toast('Scrivi la descrizione', 'err');
    const { error } = await sb.from('compliance_deadlines').insert({ kind: 'other', subject_it: subj, due_on: dOrNull($('dl-new-due').value), interval_days: nOrNull($('dl-new-int').value), responsible: 'partner' });
    if (error) return toast(error.message, 'err');
    $('dl-new-subject').value = ''; $('dl-new-due').value = ''; $('dl-new-int').value = ''; toast('Aggiunta'); loadSettings();
  };
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
      const sent = document.createElement('button'); sent.className = 'btn sm'; sent.textContent = '✓ Segna inviato';
      sent.onclick = async () => { sent.disabled = true; const { error } = await sb.rpc('mark_po_sent', { p_po_number: po.po_number, p_via: 'console' }); if (error) { toast(error.message, 'err'); sent.disabled = false; return; } toast('Ordine segnato come inviato'); renderPoSend(); refreshBadges(); };
      row.append(mail, wa, cp, sent); c.append(row); box.append(c);
    }
  }
  async function renderWholesale() {
    const box = $('wholesale');
    const { data, error } = await sb.from('v_wholesale_tomorrow').select('*').limit(12);
    if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    if (!data || !data.length) { box.innerHTML = '<div class="empty">Nessuna consegna ingrosso prenotata. Il bot "Ordini ingrosso" prenota ogni giorno alle 18:20 per il giorno dopo.</div>'; return; }
    box.innerHTML = '<table><tr><th>Giorno</th><th>Cliente</th><th>Cosa</th><th class="num">€</th><th></th></tr>' + data.map(o => `<tr><td>${fmtD(o.order_date)}</td><td>${esc(o.customer)}</td><td>${esc(o.lines_txt)}</td><td class="num">${eur(o.total_eur)}</td><td>${o.phone ? `<a class="btn sm sec" style="text-decoration:none" target="_blank" href="${waLink(o.phone, `Buongiorno, La Perla del Cilento conferma per ${fmtD(o.order_date)}: ${o.lines_txt}. Consegna in mattinata. Grazie!`)}">💬</a>` : ''}</td></tr>`).join('') + '</table>';
  }

  // ---------- Tier 2 settings: parties, standing orders, farm supply ----------
  async function loadParties() {
    const box = $('set-parties'); box.innerHTML = '';
    const { data, error } = await sb.from('v_parties_editor').select('*');
    if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    (data || []).forEach(p => {
      const c = document.createElement('div'); c.className = 'eq' + (p.is_placeholder ? ' dirty' : '');
      c.innerHTML = `<div class="h"><b>${esc(p.legal_name)}</b><span class="status">${p.type === 'supplier' ? 'fornitore' : 'cliente'}${p.is_placeholder ? ' · SEGNAPOSTO' : ''}${p.products_supplied ? ' · ' + p.products_supplied + ' articoli' : ''}${p.standing_orders ? ' · ordini fissi' : ''}</span></div>
        <div class="f">
          <div style="grid-column:1/-1"><label>Nome / ragione sociale</label><input type="text" data-k="legal_name" value="${esc(p.legal_name)}"></div>
          <div><label>Email ordini</label><input type="email" data-k="email" value="${esc(p.email || '')}" placeholder="—"></div>
          <div><label>Telefono / WhatsApp</label><input type="tel" data-k="phone" value="${esc(p.phone || '')}" placeholder="+39 …"></div>
          <div><label>Pagamento (giorni)</label><input type="number" data-k="payment_terms_days" value="${p.payment_terms_days ?? ''}"></div>
        </div>`;
      const row = document.createElement('div'); row.className = 'row';
      row.append(saveBtn(async () => {
        const v = {}; c.querySelectorAll('input[data-k]').forEach(i => { v[i.dataset.k] = i.type === 'number' ? nOrNull(i.value) : (i.value.trim() || null); });
        if (!v.legal_name) throw new Error('Il nome è obbligatorio');
        if (p.is_placeholder && !/^(Fornitore|Cliente) \d/.test(v.legal_name)) v.notes = null;   // renamed → no longer a placeholder
        await upd('parties', { id: p.id }, v); loadParties(); refreshBadges();
      }));
      c.append(row); box.append(c);
    });
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
    const note = document.createElement('div'); note.className = 'status'; note.style.marginTop = '6px'; note.textContent = 'Prezzo ingrosso: impostazione price.wholesale_moz_eur_kg (Parametri dei bot). Nuovo cliente: aggiungilo in "Fornitori e clienti" rinominando un segnaposto.'; box.append(note);
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
