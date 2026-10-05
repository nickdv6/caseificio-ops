/* La Perla food-safety console (v0.28). Reads v_haccp_plan, v_lots_on_hold, non_conformities, haccp_log, v_lab_plan_status, v_lab_samples_recent,
   v_pest_status, pest_inspections, v_training_matrix, v_instruments, calibration_checks. Writes through the DB functions
   (log_ccp, record_sample_taken, record_lab_result, record_pest_inspection, record_calibration_check, release_lot_hold) so the
   rules (NC, lot holds, recall assessment, deadlines) live in one place. Files go to the private `documents` bucket.
   v0.57 Manuale di Autocontrollo: haccp_forms_status() feeds the Registri tab (23 MOD forms, print via registro.html, weekly
   verification via mark_register_reviewed); every card shows its MOD-xx chip linking to the printable register. */
(() => {
  const CFG = window.FABULA_CONFIG;
  const sb = supabase.createClient(CFG.supabaseUrl, CFG.supabaseKey, { db: { schema: 'fabula' } });
  const $ = id => document.getElementById(id);
  document.addEventListener('wheel', e => { const a = document.activeElement; if (a && a.tagName === 'INPUT' && a.type === 'number' && e.target === a) e.preventDefault(); }, { passive: false });
  let staff = null, isManager = false, FORMS = {};
  const addDays = (iso, n) => { const d = new Date(iso + 'T12:00:00'); d.setDate(d.getDate() + n); return d.toISOString().slice(0, 10); };
  // MOD-xx chip → printable register of that form (Manuale di Autocontrollo §11). '§8.2' chips point to the manual itself.
  const modChip = code => { const f = FORMS[code]; if (!f) return ''; return `<a class="modref" href="registro.html?mod=${esc(code)}" target="_blank" rel="noopener" title="${esc(f.title_it)} · registro stampabile">${esc(code)} · ${esc(f.manual_section)}</a>`; };
  const show = v => document.querySelectorAll('.view').forEach(e => e.classList.toggle('active', e.id === 'v-' + v));
  const toast = (m, cls = '') => { const t = $('toast'); t.textContent = m; t.className = 'toast ' + cls; t.style.display = 'block'; setTimeout(() => t.style.display = 'none', 4200); };
  const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const num = (n, d = 1) => n == null ? '–' : Number(n).toLocaleString('it-IT', { maximumFractionDigits: d });
  const fmtD = s => s ? String(s).slice(8, 10) + '/' + String(s).slice(5, 7) + '/' + String(s).slice(0, 4) : '—';
  const fmtDT = s => s ? new Date(s).toLocaleString('it-IT', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Rome' }) : '—';
  const todayRome = () => new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Rome' });
  const daysTo = d => d ? Math.round((new Date(d + 'T12:00:00') - new Date(todayRome() + 'T12:00:00')) / 864e5) : null;
  const pill = (txt, cls = '') => `<span class="pill ${cls}">${esc(txt)}</span>`;
  const badge = (id, n) => { const e = $(id); if (!e) return; e.textContent = n || ''; e.classList.toggle('on', !!n); };
  const fail = (r, what) => { if (r.error) { toast(`${what}: ${r.error.message}`, 'err'); throw r.error; } return r.data; };
  const failNone = (r, what) => { fail(r, what); if (!(r.data || []).length) { toast(`${what}: ${PERM.NOT_SAVED}`, 'err'); throw new Error(PERM.NOT_SAVED); } return r.data; };   // v0.56
  const dueCell = d => { const k = daysTo(d); if (d == null) return '<span class="ko">data da impostare</span>'; return `${fmtD(d)} ${k < 0 ? `<span class="ko">scaduto da ${-k} g</span>` : k <= 30 ? `<span class="ko">tra ${k} g</span>` : ''}`; };

  async function upload(file, folder, kind, relatedTable) {     // → documents.id
    if (!file) return null;
    const ext = (file.name.split('.').pop() || 'pdf').toLowerCase(), path = `${folder}/${todayRome()}_${Date.now()}.${ext}`;
    const up = await sb.storage.from('documents').upload(path, file, { upsert: false });
    if (up.error) { toast('Caricamento file: ' + up.error.message, 'err'); throw up.error; }
    const doc = await sb.from('documents').insert({ kind, storage_path: path, original_filename: file.name, mime_type: file.type, document_date: todayRome(), uploaded_by_id: staff.id, related_table: relatedTable }).select('id').single();
    return fail(doc, 'Documento').id;
  }
  async function openDoc(id) {
    const { data } = await sb.from('documents').select('storage_path').eq('id', id).single();
    if (!data) return;
    const { data: u } = await sb.storage.from('documents').createSignedUrl(data.storage_path, 300);
    if (u) window.open(u.signedUrl, '_blank');
  }
  document.addEventListener('click', e => { const a = e.target.closest('[data-doc]'); if (a) { e.preventDefault(); openDoc(a.dataset.doc); } });

  // ---------- auth & tabs ----------
  async function init() {
    const { data: { session } } = await sb.auth.getSession();
    if (!session) return show('login');
    const P = await PERM.load(sb);
    if (!P || !P.staff_id) return PERM.deny(sb, PERM.notLinked(session.user.email));
    if (!PERM.page('haccp')) return PERM.deny(sb, PERM.notForProfile());
    const { data } = await sb.from('staff').select('*').eq('id', P.staff_id).maybeSingle();
    staff = { ...(data || { id: P.staff_id, full_name: P.full_name }), app_role: P.role, role_name: P.role_name };
    isManager = PERM.can('haccp', 3);
    $('who').textContent = staff.full_name;
    show('main'); showTab((location.hash || '#registri').slice(1) || 'registri'); load();   // v0.57b: the Manuale's home opens on Registri
  }
  $('btn-login').onclick = async () => { const { error } = await sb.auth.signInWithPassword({ email: $('email').value, password: $('pw').value }); if (error) return toast(error.message, 'err'); init(); };
  $('pw').addEventListener('keydown', e => { if (e.key === 'Enter') $('btn-login').click(); });
  PERM.forgot(sb, toast);
  $('btn-refresh').onclick = () => load();
  function showTab(t) {
    if (!$('p-' + t)) t = 'registri';
    document.querySelectorAll('.tab').forEach(b => b.setAttribute('aria-selected', b.dataset.tab === t));
    document.querySelectorAll('.pane').forEach(p => p.classList.toggle('active', p.id === 'p-' + t));
    history.replaceState(null, '', '#' + t);
  }
  $('tabs').onclick = e => { const b = e.target.closest('.tab'); if (b) showTab(b.dataset.tab); };

  // ---------- load everything ----------
  async function load() {
    const since7 = new Date(Date.now() - 7 * 864e5).toISOString();
    const [plan, holds, ncs, logs, lab, samples, stations, insp, matrix, courses, people, instr, checks, forms, manual] = await Promise.all([
      sb.from('v_haccp_plan').select('*'),
      sb.from('v_lots_on_hold').select('*'),
      sb.from('non_conformities').select('id, opened_at, severity, status, description, lot_number, corrective_action, root_cause, preventive_action').in('status', ['open', 'investigating']).order('opened_at', { ascending: false }),
      sb.from('haccp_log').select('logged_at, measured_value, result, operator, corrective_action, source, haccp_control_points(code, ccp_no, name, unit, form_code), production_batches(batch_lot)').gte('logged_at', since7).order('logged_at', { ascending: false }).limit(200),
      sb.from('v_lab_plan_status').select('*'),
      sb.from('v_lab_samples_recent').select('*').limit(80),
      sb.from('v_pest_status').select('*'),
      sb.from('pest_inspections').select('inspected_on, by_kind, company, report_no, activity_found, activity_inside, findings, actions_it, document_id').order('inspected_on', { ascending: false }).limit(12),
      sb.from('v_training_matrix').select('*'),
      sb.from('training_courses').select('code, name_it, category, sort').order('sort'),
      sb.from('staff').select('id, full_name, role').eq('active', true).order('full_name'),
      sb.from('v_instruments').select('*'),
      sb.from('calibration_checks').select('checked_at, kind, method, max_deviation, tolerance, result, provider, certificate_no, certificate_document_id, note, equipment(code, name)').order('checked_at', { ascending: false }).limit(25),
      sb.rpc('haccp_forms_status'),
      sb.from('settings').select('key, value').like('key', 'food.manuale_%')
    ]);
    [plan, holds, ncs, logs, lab, samples, stations, insp, matrix, courses, people, instr, checks, forms, manual].forEach((r, i) => { if (r.error) toast('Lettura dati: ' + r.error.message, 'err'); });
    FORMS = Object.fromEntries((forms.data || []).map(f => [f.code, f]));
    renderManual(Object.fromEntries((manual.data || []).map(r => [r.key, r.value])));
    renderForms(forms.data || []);
    renderTiles(holds.data || [], ncs.data || [], samples.data || [], matrix.data || [], instr.data || [], lab.data || []);
    renderHolds(holds.data || []); renderNcs(ncs.data || []); renderLogs(logs.data || []);
    renderPlan(plan.data || []);
    renderLab(lab.data || []); renderSamples(samples.data || []);
    renderStations(stations.data || []); renderInspections(insp.data || []);
    renderMatrix(matrix.data || [], courses.data || [], people.data || []);
    renderInstruments(instr.data || []); renderChecks(checks.data || []);
    document.querySelectorAll('[data-mod]').forEach(e => { const c = e.dataset.mod; e.innerHTML = c.startsWith('MOD-') ? modChip(c) : (MANUAL_URL ? `<a class="modref" href="${esc(MANUAL_URL)}" target="_blank" rel="noopener">Manuale ${esc(c)}</a>` : ''); });
  }

  // ---------- Manuale di Autocontrollo + Registri (v0.57) ----------
  let MANUAL_URL = '';
  function renderManual(m) {
    MANUAL_URL = m['food.manuale_url'] || '';
    const draft = (m['food.manuale_stato'] || 'bozza') !== 'firmato';
    $('manual').innerHTML = `Manuale di Autocontrollo rev. ${esc(m['food.manuale_rev'] || '?')}${m['food.manuale_data'] ? ' del ' + fmtD(m['food.manuale_data']) : ''}`
      + (draft ? ' · <span class="draft">bozza, da firmare</span>' : ' · firmato') + (MANUAL_URL ? ` · <a href="${esc(MANUAL_URL)}" target="_blank" rel="noopener">apri il manuale</a>` : '');
  }
  const ST = { attivo: '', parziale: pill('parziale', 'warn'), cartaceo: pill('cartaceo'), da_attivare: pill('da attivare', 'ko') };
  const KIND_REVIEW = new Set(['milk', 'ccp', 'batch', 'pest', 'calibration', 'lab', 'nc', 'hold', 'receipt', 'effluent']);   // registers the responsible checks every week
  function needsReview(f) { return f.status !== 'da_attivare' && KIND_REVIEW.has(f.register_kind) && f.last_at && (!f.last_review_to || f.last_review_to < addDays(todayRome(), -7)); }
  function renderForms(rows) {
    if (!$('rg-to').value) { $('rg-to').value = todayRome(); $('rg-from').value = addDays(todayRome(), -6); }
    const due = rows.filter(needsReview).length; badge('n-registri', due);
    if (!rows.length) { $('forms').innerHTML = '<div class="empty">Moduli non disponibili.</div>'; return; }
    $('forms').innerHTML = `<table><tr><th>Modulo</th><th>Registro</th><th>Frequenza · chi</th><th class="num">30 gg</th><th>Ultima registrazione</th><th>Ultima verifica</th><th></th></tr>${rows.map(f => `
      <tr data-form="${esc(f.code)}"><td class="nw"><b>${esc(f.code)}</b><br><small>Manuale ${esc(f.manual_section)}</small></td>
      <td>${esc(f.title_it)} ${ST[f.status] || ''}<br><small>${esc(f.where_it || '')}</small></td>
      <td><small>${esc(f.frequency_it || '')}<br>${esc(f.responsible_it || '')}</small></td>
      <td class="num">${f.records_30d == null ? '—' : f.records_30d}</td>
      <td class="nw">${f.last_at ? fmtDT(f.last_at) : '<span class="empty">nessuna</span>'}</td>
      <td class="nw">${f.last_review_at ? `${fmtD(String(f.last_review_to))} ${f.last_review_outcome === 'ok' ? pill('ok', 'ok') : pill('rilievi', 'warn')}<br><small>${esc(f.last_review_by || '')}</small>` : ''}${needsReview(f) ? ' ' + pill('da verificare', 'ko') : ''}</td>
      <td class="nw"><a class="btn sm sec" data-print="${esc(f.code)}" href="#">Stampa</a> <a class="btn sm sec" data-blank="${esc(f.code)}" href="#">Modulo vuoto</a>${isManager && f.status !== 'da_attivare' ? ` <button class="btn sm" data-review="${esc(f.code)}">Verificato</button>` : ''}</td></tr>`).join('')}</table>`;
    const period = () => ({ from: $('rg-from').value || addDays(todayRome(), -6), to: $('rg-to').value || todayRome() });
    $('forms').querySelectorAll('[data-print]').forEach(a => a.onclick = e => { e.preventDefault(); const p = period(); window.open(`registro.html?mod=${a.dataset.print}&from=${p.from}&to=${p.to}`, '_blank', 'noopener'); });
    $('forms').querySelectorAll('[data-blank]').forEach(a => a.onclick = e => { e.preventDefault(); window.open(`registro.html?mod=${a.dataset.blank}&blank=1`, '_blank', 'noopener'); });
    $('forms').querySelectorAll('[data-review]').forEach(b => b.onclick = async () => {
      const p = period(), code = b.dataset.review;
      const note = prompt(`Verifica del registro ${code} dal ${fmtD(p.from)} al ${fmtD(p.to)}.\nHai letto le registrazioni del periodo? Scrivi i rilievi, oppure lascia vuoto se è tutto in ordine.`, '');
      if (note === null) return;
      b.disabled = true;
      try {
        fail(await sb.rpc('mark_register_reviewed', { p_form: code, p_from: p.from, p_to: p.to, p_staff_id: staff.id, p_outcome: note.trim() ? 'con_rilievi' : 'ok', p_note: note.trim() || null }), 'Verifica');
        toast(`${code} verificato ${note.trim() ? 'con rilievi' : '· tutto in ordine'}`); load();
      } finally { b.disabled = false; }
    });
  }

  function renderTiles(holds, ncs, samples, matrix, instr, lab) {
    const crit = ncs.filter(n => n.severity === 'critical').length, pending = samples.filter(s => s.outcome === 'in_attesa').length;
    const trGap = matrix.filter(m => m.status !== 'valido').length, oos = instr.filter(i => i.out_of_service).length;
    const overdue = lab.filter(l => l.plan_active && l.next_due && daysTo(l.next_due) < 0).length;
    const t = (l, v, bad) => `<div class="tile ${bad ? 'bad' : ''}"><div class="l">${l}</div><div class="v">${v}</div></div>`;
    $('tiles').innerHTML = t('Lotti bloccati', holds.length, holds.length) + t('NC aperte', ncs.length + (crit ? ` <small style="font-size:1rem">(${crit} critiche)</small>` : ''), ncs.length) +
      t('Analisi scadute', lab.some(l => l.plan_active) ? overdue : '—', overdue) + t('Referti attesi', pending, false) + t('Formazione da sistemare', trGap, trGap) + t('Strumenti fuori servizio', oos, oos);
    badge('n-registro', holds.length + crit); badge('n-analisi', overdue); badge('n-formazione', trGap); badge('n-strumenti', oos);
  }

  // ---------- Registro ----------
  function renderHolds(rows) {
    if (!rows.length) { $('holds').innerHTML = '<div class="empty">Nessun lotto bloccato.</div>'; return; }
    $('holds').innerHTML = `<table><tr><th>Lotto</th><th>Prodotto</th><th>Motivo</th><th class="num">In giacenza</th><th class="num">Già venduto</th><th></th></tr>${rows.map(r => `
      <tr><td class="nw"><b>${esc(r.batch_lot)}</b><br><small>${fmtD(r.batch_date)}</small></td><td>${esc(r.product)}</td><td>${esc(r.hold_reason)}</td><td class="num">${num(r.kg_on_hand)} kg</td>
      <td class="num ${r.kg_sold > 0 ? 'ko' : ''}">${num(r.kg_sold)} kg</td><td>${isManager ? `<button class="btn sm sec" data-release="${esc(r.batch_lot)}">Sblocca…</button>` : ''}</td></tr>`).join('')}</table>
      ${rows.some(r => r.kg_sold > 0) ? '<div class="hint ko" style="margin-top:6px">Parte del lotto è già uscita: valuta ritiro/richiamo con il consulente (tracciabilità nella simulazione di richiamo).</div>' : ''}`;
    $('holds').querySelectorAll('[data-release]').forEach(b => b.onclick = async () => {
      const note = prompt(`Motivo dello sblocco del lotto ${b.dataset.release} (es. analisi conforme n. …, valutazione del consulente):`);
      if (!note) return;
      fail(await sb.rpc('release_lot_hold', { p_lot: b.dataset.release, p_staff_id: staff.id, p_note: note }), 'Sblocco'); toast('Lotto sbloccato'); load();
    });
  }
  // v0.77: recall drill from the console (MOD-14) — writes a recall_drills row, shows the trace
  $('rc-run').onclick = async () => {
    const lot = $('rc-lot').value.trim().toUpperCase() || null; $('rc-run').disabled = true;
    try {
      const r = fail(await sb.rpc('recall_drill', { p_lot: lot }), 'Prova di richiamo');
      if (!r || r.result === 'no_lots') { $('rc-out').innerHTML = '<div class="empty">Nessun lotto venduto negli ultimi 30 giorni: scrivi un lotto.</div>'; return; }
      const res = { ok: pill('tracciato', 'ok'), manca_latte_a_monte: pill('manca il latte a monte', 'ko'), kg_non_giustificati: pill('kg non giustificati', 'ko') };
      $('rc-out').innerHTML = `<div style="margin:6px 0">${res[r.result] || esc(r.result)} <b>${esc(r.lot)}</b> · ${esc(r.sku)} del ${fmtD(r.batch_date)} · in ${num(r.elapsed_ms / 1000, 1)} s</div>
        <div>Prodotti ${num(r.produced_kg)} kg · venduti ${num(r.sold_kg)} · scartati ${num(r.wasted_kg)} · in giacenza ${num(r.on_hand_kg)} · <span class="${Math.abs(r.unaccounted_kg) > 0.5 ? 'ko' : ''}">non giustificati ${num(r.unaccounted_kg)} kg</span></div>
        <details open><summary>Latte a monte</summary>${(r.milk_lots || []).map(m => `<div>• ${fmtD(m.date)} · ${esc(m.supplier || '?')} · lotto ${esc(m.milk_lot || '?')} · ${num(m.kg)} kg${m.ddt ? ' · DDT ' + esc(m.ddt) : ''}</div>`).join('') || '<div class="ko">Nessun latte collegato al lotto.</div>'}</details>
        <details open><summary>A chi è andato</summary>${(r.destinations || []).map(d => `<div>• ${fmtD(d.date)} · ${esc(d.channel || '')} · ${esc(d.customer || 'banco')} · ${num(d.kg)} kg</div>`).join('') || '<div>Nessuna uscita: tutto in giacenza.</div>'}</details>`;
      toast('Prova di richiamo registrata');
    } finally { $('rc-run').disabled = false; }
  };
  function renderNcs(rows) {
    if (!rows.length) { $('ncs').innerHTML = '<div class="empty">Nessuna non conformità aperta.</div>'; return; }
    const sev = { critical: ['critica', 'ko'], major: ['maggiore', 'warn'], minor: ['minore', ''] };
    $('ncs').innerHTML = rows.map(n => `<div style="border-bottom:1px solid var(--rule);padding:8px 0" data-nc="${n.id}">
      <div class="row" style="margin:0;justify-content:space-between"><div>${pill(sev[n.severity]?.[0] || n.severity, sev[n.severity]?.[1])} <small>${fmtDT(n.opened_at)}${n.lot_number ? ' · lotto ' + esc(n.lot_number) : ''}</small></div></div>
      <div style="margin:4px 0">${esc(n.description)}</div>
      <div class="form"><div><label>Azione correttiva</label><input type="text" data-k="corrective_action" value="${esc(n.corrective_action || '')}"></div><div><label>Causa</label><input type="text" data-k="root_cause" value="${esc(n.root_cause || '')}"></div><div><label>Azione preventiva</label><input type="text" data-k="preventive_action" value="${esc(n.preventive_action || '')}"></div>
      <div class="row" style="margin:0"><button class="btn sm sec" data-act="save">Salva</button>${isManager ? '<button class="btn sm" data-act="close">Chiudi NC</button>' : ''}</div></div></div>`).join('');
    $('ncs').querySelectorAll('[data-nc]').forEach(box => box.querySelectorAll('button').forEach(b => b.onclick = async () => {
      const v = {}; box.querySelectorAll('input[data-k]').forEach(i => v[i.dataset.k] = i.value.trim() || null);
      if (b.dataset.act === 'close') { if (!v.corrective_action) return toast('Scrivi l\'azione correttiva prima di chiudere', 'err'); if (!confirm('Chiudere questa non conformità? Esce dall\'elenco delle NC aperte.')) return; Object.assign(v, { status: 'closed', closed_at: new Date().toISOString(), closed_by_id: staff.id }); }
      else v.status = 'investigating';
      failNone(await sb.from('non_conformities').update(v).eq('id', box.dataset.nc).select('id'), 'NC'); toast(b.dataset.act === 'close' ? 'NC chiusa' : 'Salvato'); load();
    }));
  }
  function renderLogs(rows) {
    if (!rows.length) { $('logs').innerHTML = '<div class="empty">Nessuna registrazione negli ultimi 7 giorni.</div>'; return; }
    const res = { ok: pill('ok', 'ok'), warning: pill('allerta', 'warn'), non_conformity: pill('NC', 'ko') };
    $('logs').innerHTML = `<table><tr><th>Quando</th><th>Punto</th><th>Modulo</th><th class="num">Valore</th><th>Esito</th><th>Lotto</th><th>Chi</th><th>Azione</th></tr>${rows.map(l => `
      <tr><td class="nw">${fmtDT(l.logged_at)}</td><td>${esc(l.haccp_control_points?.ccp_no || '')} ${esc(l.haccp_control_points?.name || '')}</td><td class="nw">${modChip(l.haccp_control_points?.form_code)}</td>
      <td class="num">${l.measured_value == null ? '—' : l.haccp_control_points?.unit === 'esito' ? (Number(l.measured_value) === 0 ? 'ok' : 'NON OK') : num(l.measured_value, 2) + ' ' + esc(l.haccp_control_points?.unit || '')}</td><td>${res[l.result] || esc(l.result)}</td>
      <td class="nw">${esc(l.production_batches?.batch_lot || '')}</td><td>${esc(l.operator || l.source || '')}${l.source === 'paper' ? ' <small title="Ricopiata dal foglio di carta">📝 carta</small>' : ''}</td><td>${esc(l.corrective_action || '')}</td></tr>`).join('')}</table>`;
  }

  // ---------- Piano ----------
  function renderPlan(rows) {
    const inp = (r, k) => `<input type="number" step="0.01" data-k="${k}" value="${r[k] ?? ''}" ${isManager ? '' : 'disabled'}>`;
    $('plan').innerHTML = `<table><tr><th>Punto</th><th>Fase</th><th>Registro</th><th>Limite critico (testo)</th><th class="num">Min</th><th class="num">Max</th><th class="num">Allerta min</th><th class="num">Allerta max</th><th class="num">30 gg</th><th></th></tr>${rows.map(r => `
      <tr data-code="${esc(r.code)}"><td>${pill(r.ccp_no || 'PRP', r.is_ccp ? 'ccp' : '')}<br><b>${esc(r.name)}</b>${r.applies_when !== 'sempre' ? `<br><small>${esc(r.applies_when.replace('_', ' '))}</small>` : ''}</td><td>${esc(r.process_step || '')}</td><td class="nw">${modChip(r.form_code)}</td>
      <td style="min-width:240px">${esc(r.critical_limit_it || '')}
        <details class="more"><summary>Pericolo, monitoraggio, azioni</summary><dl><dt>Pericolo</dt><dd>${esc(r.hazard_it || '—')}</dd><dt>Monitoraggio</dt><dd>${esc(r.monitoring_it || '—')}</dd><dt>Azione correttiva</dt><dd>${esc(r.corrective_it || '—')}</dd><dt>Verifica</dt><dd>${esc(r.verification_it || '—')}</dd><dt>Registrazioni</dt><dd>${esc(r.records_it || '—')}</dd></dl></details></td>
      <td class="num">${inp(r, 'min_value')}</td><td class="num">${inp(r, 'max_value')}</td><td class="num">${inp(r, 'warn_min')}</td><td class="num">${inp(r, 'warn_max')}</td>
      <td class="num">${r.logs_30d}${r.nc_30d ? `<br><span class="ko">${r.nc_30d} NC</span>` : ''}</td><td>${isManager ? '<button class="btn sm sec" data-save>Salva</button>' : ''}</td></tr>`).join('')}</table>`;
    $('plan').querySelectorAll('[data-save]').forEach(b => b.onclick = async () => {
      const tr = b.closest('tr'), v = {}; tr.querySelectorAll('input[data-k]').forEach(i => v[i.dataset.k] = i.value === '' ? null : Number(i.value));
      v.updated_at = new Date().toISOString();
      if (!confirm(`Cambiare i limiti di ${tr.dataset.code}? Fallo solo se deciso con il consulente HACCP: vale da subito per tablet e bot.`)) return;
      failNone(await sb.from('haccp_control_points').update(v).eq('code', tr.dataset.code).select('code'), 'Limiti'); toast('Limiti aggiornati'); load();
    });
  }

  // ---------- Analisi ----------
  function renderLab(rows) {
    const active = rows.some(r => r.plan_active);
    $('plan-state').innerHTML = active ? 'Piano attivo: il bot del martedì prepara la richiesta al laboratorio per ciò che scade nei 14 giorni.' :
      '<span class="ko">Piano non ancora attivo.</span> Inserisci laboratorio e data di avvio in ⚙ Configurazione → Macchine e scadenze → Sicurezza alimentare (food.sampling_start).';
    const out = { conforme: pill('conforme', 'ok'), attenzione: pill('attenzione', 'warn'), non_conforme: pill('non conforme', 'ko') };
    $('labplan').innerHTML = `<table><tr><th>Codice</th><th>Analisi</th><th>Limite</th><th class="num">Ogni</th><th>Ultimo</th><th>Prossimo</th><th></th></tr>${rows.map(r => `
      <tr><td class="nw"><b>${esc(r.code)}</b><br><small>${esc(r.matrix.replace('_', ' '))}</small></td><td>${esc(r.analyte_it)}<br><small>${esc(r.criterion_ref || '')}${r.n ? ` · n=${r.n} c=${r.c}` : ''}</small></td>
      <td style="min-width:200px"><small>${esc(r.limit_it || '')}</small></td><td class="num">${r.frequency_days} gg</td>
      <td class="nw">${r.last_taken ? fmtD(r.last_taken) + ' ' + (out[r.last_outcome] || (r.pending ? pill('in attesa') : '')) : '—'}</td>
      <td class="nw">${r.plan_active ? dueCell(r.next_due) : '—'}</td><td><button class="btn sm sec" data-take="${esc(r.code)}">Prelevato</button></td></tr>`).join('')}</table>`;
    $('labplan').querySelectorAll('[data-take]').forEach(b => b.onclick = async () => {
      const lot = prompt(`Campione ${b.dataset.take}: lotto di prodotto (vuoto se non serve)`, '');
      if (lot === null) return;
      const r = fail(await sb.rpc('record_sample_taken', { p_test_code: b.dataset.take, p_lot: lot || null, p_staff_id: staff.id }), 'Campione');
      toast(`Campione ${r.sample_code}: scrivilo sul contenitore`); load();
    });
  }
  function renderSamples(rows) {
    if (!rows.length) { $('samples').innerHTML = '<div class="empty">Nessun campione registrato.</div>'; return; }
    const out = { in_attesa: pill('in attesa'), conforme: pill('conforme', 'ok'), attenzione: pill('attenzione', 'warn'), non_conforme: pill('non conforme', 'ko'), annullato: pill('annullato') };
    $('samples').innerHTML = `<table><tr><th>Campione</th><th>Analisi</th><th>Lotto</th><th>Esito</th><th>Referto</th></tr>${rows.map(s => `
      <tr data-sample="${esc(s.sample_code)}"><td class="nw"><b>${esc(s.sample_code)}</b><br><small>${fmtD(s.taken_on)}${s.taken_by ? ' · ' + esc(s.taken_by) : ''}</small></td><td>${esc(s.test_code)}<br><small>${esc(s.analyte_it)}</small></td><td class="nw">${esc(s.lot_number || '')}</td>
      <td>${out[s.outcome] || esc(s.outcome)}${s.outcome === 'in_attesa' && s.days_waiting > 14 ? `<br><span class="ko">da ${s.days_waiting} g</span>` : ''}${s.result_it ? `<br><small>${esc(s.result_it)}</small>` : ''}</td>
      <td>${s.outcome === 'in_attesa' ? `<div class="form" style="min-width:420px"><div><label>Esito</label><select data-k="outcome"><option value="conforme">Conforme</option><option value="attenzione">Attenzione</option><option value="non_conforme">NON conforme</option><option value="annullato">Annullato</option></select></div>
          <div><label>Risultato</label><input type="text" data-k="text" placeholder="es. assente in 25 g"></div><div><label>N. referto</label><input type="text" data-k="report"></div><div><label>PDF</label><input type="file" data-k="file" accept="application/pdf,image/*"></div><div><button class="btn sm" data-res>Registra</button></div></div>`
        : `${esc(s.report_no || '')} ${s.report_date ? fmtD(s.report_date) : ''} ${s.document_id ? `<a href="#" data-doc="${s.document_id}">PDF</a>` : ''}`}</td></tr>`).join('')}</table>`;
    $('samples').querySelectorAll('[data-res]').forEach(b => b.onclick = async () => {
      const tr = b.closest('tr'), g = k => tr.querySelector(`[data-k=${k}]`), outcome = g('outcome').value;
      if (outcome === 'non_conforme' && !confirm('Esito NON conforme: si apre una non conformità e, per le analisi di sicurezza, il lotto viene bloccato e si chiede la valutazione del ritiro. Confermi?')) return;
      b.disabled = true;
      try {
        const docId = await upload(g('file').files[0], 'lab', 'lab_report', 'lab_samples');
        const r = fail(await sb.rpc('record_lab_result', { p_sample_code: tr.dataset.sample, p_outcome: outcome, p_text: g('text').value || null, p_report_no: g('report').value || null, p_document_id: docId, p_staff_id: staff.id }), 'Referto');
        if (r.nc_id) alert('NON CONFORMITÀ aperta.\n\nCosa fare:\n• ' + (r.actions_it || []).join('\n• ') + (r.distribution && r.distribution.length ? `\n\nIl lotto è uscito verso ${r.distribution.length} destinazioni: vedi la richiesta in console → Oggi.` : ''));
        else toast('Referto registrato');
        load();
      } finally { b.disabled = false; }
    });
  }

  // ---------- Infestanti ----------
  const PEST_KIND = { esca_esterna: 'esca esterna', trappola_meccanica: 'trappola a cattura', trappola_collante: 'piastra collante', lampada_uv: 'lampada UV', feromoni: 'feromoni', altro: 'altro' };
  const PEST_ST = [['', '—'], ['consumo', 'Esca consumata'], ['cattura', 'Cattura'], ['insetti', 'Insetti'], ['tracce', 'Tracce'], ['danneggiata', 'Danneggiata'], ['mancante', 'Mancante']];
  function renderStations(rows) {
    $('stations').innerHTML = `<table><tr><th>Postazione</th><th>Tipo</th><th>Dove</th><th>Ultimo controllo</th><th class="num">Segnalazioni 90 gg</th></tr>${rows.map(r => `
      <tr><td><b>${esc(r.code)}</b></td><td>${esc(PEST_KIND[r.kind] || r.kind)}${r.inside ? '' : ' · <small>esterno</small>'}</td><td>${esc(r.location_it)}</td>
      <td class="nw">${r.last_inspected_on ? fmtD(r.last_inspected_on) + ' ' + (r.last_status === 'ok' ? pill('ok', 'ok') : pill(r.last_status, 'ko')) : '—'}</td><td class="num ${r.findings_90d ? 'ko' : ''}">${r.findings_90d}</td></tr>`).join('')}</table>`;
    $('pc-findings').innerHTML = rows.map(r => `<div><label>${esc(r.code)}</label><select data-st="${esc(r.code)}">${PEST_ST.map(([v, t]) => `<option value="${v}">${t}</option>`).join('')}</select></div>`).join('');
    $('pc-date').value = $('pc-date').value || todayRome();
  }
  $('pc-save').onclick = async () => {
    if (!$('pc-company').value.trim()) return toast('Scrivi la ditta', 'err');
    const findings = [...$('pc-findings').querySelectorAll('select')].map(s => ({ station: s.dataset.st, status: s.value || 'ok' }));
    $('pc-save').disabled = true;
    try {
      const docId = await upload($('pc-file').files[0], 'pest', 'pest_report', 'pest_inspections');
      const r = fail(await sb.rpc('record_pest_inspection', { p_by: 'ditta', p_findings: findings, p_staff_id: staff.id, p_company: $('pc-company').value.trim(), p_report_no: $('pc-report').value || null,
        p_actions: $('pc-actions').value || null, p_products: $('pc-products').value || null, p_document_id: docId, p_on: $('pc-date').value || null }), 'Visita');
      toast(r.activity_inside ? 'Visita registrata · attività interna: NC aperta' : 'Visita registrata, prossima tra 45 giorni', r.activity_inside ? 'err' : '');
      ['pc-report', 'pc-actions', 'pc-products', 'pc-file'].forEach(id => $(id).value = ''); load();
    } finally { $('pc-save').disabled = false; }
  };
  function renderInspections(rows) {
    if (!rows.length) { $('inspections').innerHTML = '<div class="empty">Nessuna ispezione registrata.</div>'; return; }
    $('inspections').innerHTML = `<table><tr><th>Data</th><th>Chi</th><th>Esito</th><th>Segnalazioni</th><th>Azioni</th><th></th></tr>${rows.map(i => `
      <tr><td class="nw">${fmtD(i.inspected_on)}</td><td>${i.by_kind === 'ditta' ? esc(i.company || 'ditta') + (i.report_no ? ' · ' + esc(i.report_no) : '') : 'giro interno'}</td>
      <td>${i.activity_inside ? pill('attività interna', 'ko') : i.activity_found ? pill('attività esterna', 'warn') : pill('ok', 'ok')}</td>
      <td><small>${esc((i.findings || []).filter(f => f.status !== 'ok').map(f => f.station + ' ' + f.status).join(', '))}</small></td><td><small>${esc(i.actions_it || '')}</small></td><td>${i.document_id ? `<a href="#" data-doc="${i.document_id}">PDF</a>` : ''}</td></tr>`).join('')}</table>`;
  }

  // ---------- Formazione ----------
  function renderMatrix(rows, courses, people) {
    const st = { valido: pill('valido', 'ok'), in_scadenza: pill('in scadenza', 'warn'), scaduto: pill('scaduto', 'ko'), mancante: pill('mancante', 'ko') };
    $('matrix').innerHTML = rows.length ? `<table><tr><th>Persona</th><th>Ruolo</th><th>Corso</th><th>Stato</th><th>Fatto</th><th>Scade</th><th></th></tr>${rows.map(m => `
      <tr><td><b>${esc(m.full_name)}</b></td><td>${esc(m.role)}</td><td>${esc(m.course_name)}</td><td>${st[m.status] || esc(m.status)}</td><td class="nw">${fmtD(m.completed_on)}</td><td class="nw">${fmtD(m.expires_on)}</td>
      <td>${m.certificate_document_id ? `<a href="#" data-doc="${m.certificate_document_id}">attestato</a>` : ''}</td></tr>`).join('')}</table>` : '<div class="empty">Nessun dipendente attivo in anagrafica.</div>';
    const keepS = $('tr-staff').value, keepC = $('tr-course').value;
    $('tr-staff').innerHTML = '<option value="">—</option>' + people.map(p => `<option value="${p.id}">${esc(p.full_name)} (${esc(p.role)})</option>`).join('');
    $('tr-course').innerHTML = courses.map(c => `<option value="${c.code}">${esc(c.name_it)}</option>`).join('');
    if (keepS) $('tr-staff').value = keepS; if (keepC) $('tr-course').value = keepC;
  }
  $('tr-save').onclick = async () => {
    const sid = $('tr-staff').value || null, name = $('tr-name').value.trim() || null;
    if (!sid && !name) return toast('Scegli la persona o scrivi il nome', 'err');
    if (!$('tr-date').value) return toast('Data dell\'attestato', 'err');
    $('tr-save').disabled = true;
    try {
      const docId = await upload($('tr-file').files[0], 'formazione', 'training_cert', 'training_records');
      fail(await sb.from('training_records').insert({ staff_id: sid, person_name: sid ? null : name, course_code: $('tr-course').value, provider: $('tr-provider').value || null,
        hours: $('tr-hours').value === '' ? null : Number($('tr-hours').value), completed_on: $('tr-date').value, certificate_document_id: docId }), 'Attestato');
      toast('Attestato registrato'); ['tr-name', 'tr-provider', 'tr-date', 'tr-hours', 'tr-file'].forEach(id => $(id).value = ''); load();
    } finally { $('tr-save').disabled = false; }
  };

  // ---------- Strumenti ----------
  function renderInstruments(rows) {
    $('instruments').innerHTML = `<table><tr><th>Strumento</th><th class="num">Tolleranza</th><th>Verifica interna</th><th>Taratura esterna</th><th>Ultimo esito</th></tr>${rows.map(r => `
      <tr><td><b>${esc(r.code)}</b> ${r.reference_instrument ? pill('riferimento', 'ccp') : ''} ${r.out_of_service ? pill('fuori servizio', 'ko') : ''}<br><small>${esc(r.name)}</small>${r.notes ? `<details class="more"><summary>Procedura</summary>${esc(r.notes)}</details>` : ''}</td>
      <td class="num">${r.tolerance != null ? '±' + num(r.tolerance, 2) + ' ' + esc(r.tolerance_unit || '') : '—'}</td>
      <td class="nw">${r.check_interval_days ? `ogni ${r.check_interval_days} gg<br>${r.check_interval_days >= 7 ? dueCell(r.next_check_on) : (r.last_checked_on ? 'ultima ' + fmtD(r.last_checked_on) : '<span class="ko">mai</span>')}` : '—'}</td>
      <td class="nw">${r.calibration_interval_days ? `ogni ${r.calibration_interval_days} gg<br>${dueCell(r.next_calibration_on)}${r.calibration_cert_ref ? '<br><small>cert. ' + esc(r.calibration_cert_ref) + '</small>' : ''}` : '—'}</td>
      <td class="nw">${r.last_result ? (r.last_result === 'ok' ? pill('ok', 'ok') : pill('fuori tolleranza', 'ko')) + `<br><small>${fmtDT(r.last_check_at)}${r.last_deviation != null ? ' · scarto ' + num(r.last_deviation, 2) : ''}</small>` : '—'}</td></tr>`).join('')}</table>`;
    const keep = $('ce-code').value;
    $('ce-code').innerHTML = rows.filter(r => r.calibration_interval_days || r.reference_instrument).map(r => `<option value="${esc(r.code)}">${esc(r.code)} · ${esc(r.name)}</option>`).join('');
    if (keep) $('ce-code').value = keep;
    $('ce-date').value = $('ce-date').value || todayRome();
  }
  $('ce-save').onclick = async () => {
    if (!$('ce-provider').value.trim()) return toast('Scrivi il centro o il tecnico', 'err');
    $('ce-save').disabled = true;
    try {
      const docId = await upload($('ce-file').files[0], 'tarature', 'calibration_cert', 'equipment');
      const dev = $('ce-dev').value === '' ? null : Number($('ce-dev').value);
      const r = fail(await sb.rpc('record_calibration_check', { p_code: $('ce-code').value, p_kind: 'taratura_esterna', p_method: 'certificato_lab', p_points: dev == null ? [] : [{ ref: 0, reading: dev }],
        p_staff_id: staff.id, p_provider: $('ce-provider').value.trim(), p_certificate_no: $('ce-cert').value || null, p_document_id: docId, p_on: $('ce-date').value || null }), 'Taratura');
      toast(r.result === 'ok' ? 'Taratura registrata · prossima scadenza aggiornata' : 'Scarto oltre la tolleranza: strumento fuori servizio', r.result === 'ok' ? '' : 'err');
      ['ce-provider', 'ce-cert', 'ce-dev', 'ce-file'].forEach(id => $(id).value = ''); load();
    } finally { $('ce-save').disabled = false; }
  };
  function renderChecks(rows) {
    if (!rows.length) { $('checks').innerHTML = '<div class="empty">Nessuna verifica registrata.</div>'; return; }
    const M = { ghiaccio_fondente: 'ghiaccio fondente', acqua_bollente: 'acqua bollente', confronto_riferimento: 'confronto col riferimento', tamponi_ph: 'tamponi pH', pesi_campione: 'pesi campione', certificato_lab: 'certificato', confronto_display: 'confronto display' };
    $('checks').innerHTML = `<table><tr><th>Quando</th><th>Strumento</th><th>Tipo</th><th class="num">Scarto</th><th>Esito</th><th></th></tr>${rows.map(c => `
      <tr><td class="nw">${fmtDT(c.checked_at)}</td><td>${esc(c.equipment?.code || '')}</td><td>${c.kind === 'taratura_esterna' ? 'taratura esterna' : 'verifica interna'} · ${esc(M[c.method] || c.method)}${c.provider ? '<br><small>' + esc(c.provider) + (c.certificate_no ? ' · ' + esc(c.certificate_no) : '') + '</small>' : ''}</td>
      <td class="num">${c.max_deviation != null ? num(c.max_deviation, 2) : '—'}${c.tolerance != null ? ` / ±${num(c.tolerance, 2)}` : ''}</td><td>${c.result === 'ok' ? pill('ok', 'ok') : pill('fuori tolleranza', 'ko')}</td>
      <td>${c.certificate_document_id ? `<a href="#" data-doc="${c.certificate_document_id}">PDF</a>` : ''}</td></tr>`).join('')}</table>`;
  }

  init();
})();
