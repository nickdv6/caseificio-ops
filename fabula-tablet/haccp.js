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
  // v0.95 (audit B-02/B-04/B-05): a small dialog for choices a browser prompt cannot offer (lot picker, review, correction).
  // check(form) returns the value or throws an Error whose message is shown in the dialog; Annulla / Esc resolve null.
  function ask(title, html, okText, check) {
    return new Promise(res => {
      const d = $('dlg'), f = $('dlg-form');
      $('dlg-title').textContent = title; $('dlg-body').innerHTML = html; $('dlg-ok').textContent = okText; $('dlg-err').textContent = '';
      $('dlg-cancel').onclick = () => d.close();                            // a plain button: Enter in a field never means Annulla
      f.onsubmit = async e => {
        e.preventDefault();
        try { const v = await check(f); d.close(); res(v); } catch (er) { $('dlg-err').textContent = er.message; }
      };
      d.onclose = () => res(null);
      d.showModal(); const first = $('dlg-body').querySelector('input:not([type=hidden]),select,textarea'); if (first) first.focus();
    });
  }
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
      sb.from('haccp_log').select('id, logged_at, created_at, measured_value, result, operator, corrective_action, correction_note, source, haccp_control_points(code, ccp_no, name, unit, form_code), production_batches(batch_lot)').gte('logged_at', since7).order('logged_at', { ascending: false }).limit(200),
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
    renderHolds(holds.data || []); renderNcs(ncs.data || []); renderLogs(logs.data || []); loadProdRecords();
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
    // v0.95 (audit B-04): the review covers "from the last review to today" (never days still to come), shows how many records and
    // how many out of limit, and needs an explicit "Ho letto le registrazioni" tick instead of OK on an empty prompt
    $('forms').querySelectorAll('[data-review]').forEach(b => b.onclick = async () => {
      const code = b.dataset.review, f = rows.find(x => x.code === code) || {}, today = todayRome();
      const from0 = f.last_review_to && String(f.last_review_to) < today ? addDays(String(f.last_review_to).slice(0, 10), 1) : addDays(today, -6);
      const count = async () => {
        const fr = $('rv-from').value, to = $('rv-to').value, out = $('rv-count');
        if (!fr || !to || fr > to) { out.textContent = 'Periodo non valido'; return; }
        const r = await sb.rpc('haccp_register', { p_form: code, p_from: fr, p_to: to });
        if (r.error) { out.textContent = r.error.message; return; }
        const rs = r.data.rows || [], ko = rs.filter(x => x._ko).length, w = rs.filter(x => x._warn && !x._ko).length;
        out.innerHTML = `<b>${rs.length} registrazion${rs.length === 1 ? 'e' : 'i'}</b> nel periodo${ko ? ` · <span class="ko">${ko} fuori limite o mancanti</span>` : ''}${w ? ` · ${w} in allerta` : ''} · <a href="registro.html?mod=${esc(code)}&from=${fr}&to=${to}" target="_blank" rel="noopener">apri il registro</a>`;
      };
      const pr = ask(`Verifica del registro ${code}`,
        `<div class="hint">${esc(f.title_it || '')}</div>
         <div class="form"><div><label>Dal</label><input id="rv-from" type="date" required max="${today}" value="${from0}"></div><div><label>Al</label><input id="rv-to" type="date" required max="${today}" value="${today}"></div></div>
         <p id="rv-count" class="hint" style="margin:10px 0">…</p>
         <label class="chk"><input type="checkbox" id="rv-read" required> Ho letto le registrazioni del periodo</label>
         <div class="form" style="margin-top:8px"><div><label>Esito</label><select id="rv-out" required><option value="" selected disabled>— scegli —</option><option value="ok">Tutto in ordine</option><option value="con_rilievi">Con rilievi</option></select></div></div>
         <label style="margin-top:8px">Rilievi (obbligatori se «Con rilievi»)</label><textarea id="rv-note" rows="3" style="width:100%"></textarea>`,
        'Firma la verifica', () => {
          const fr = $('rv-from').value, to = $('rv-to').value;
          if (to > today || fr > today) throw new Error('La verifica copre solo giorni già passati: «Al» al massimo oggi');
          if (fr > to) throw new Error('«Dal» deve essere prima di «Al»');
          if ($('rv-out').value === 'con_rilievi' && !$('rv-note').value.trim()) throw new Error('Scrivi i rilievi');
          return { fr, to, out: $('rv-out').value, note: $('rv-note').value.trim() };
        });
      $('rv-from').onchange = $('rv-to').onchange = count; count();            // the dialog is already in the page: count the records now
      const v = await pr;
      if (!v) return;
      b.disabled = true;
      try {
        fail(await sb.rpc('mark_register_reviewed', { p_form: code, p_from: v.fr, p_to: v.to, p_staff_id: staff.id, p_outcome: v.out, p_note: v.note || null }), 'Verifica');
        toast(`${code} verificato dal ${fmtD(v.fr)} al ${fmtD(v.to)} ${v.out === 'con_rilievi' ? 'con rilievi' : '· tutto in ordine'}`); load();
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
    $('logs').innerHTML = `<table><tr><th>Quando</th><th>Punto</th><th>Modulo</th><th class="num">Valore</th><th>Esito</th><th>Lotto</th><th>Chi</th><th>Azione</th><th></th></tr>${rows.map(l => `
      <tr><td class="nw">${fmtDT(l.logged_at)}</td><td>${esc(l.haccp_control_points?.ccp_no || '')} ${esc(l.haccp_control_points?.name || '')}</td><td class="nw">${modChip(l.haccp_control_points?.form_code)}</td>
      <td class="num">${l.measured_value == null ? '—' : l.haccp_control_points?.unit === 'esito' ? (Number(l.measured_value) === 0 ? 'ok' : 'NON OK') : num(l.measured_value, 2) + ' ' + esc(l.haccp_control_points?.unit || '')}</td><td>${res[l.result] || esc(l.result)}</td>
      <td class="nw">${esc(l.production_batches?.batch_lot || '')}</td><td>${esc(l.operator || l.source || '')}${l.source === 'paper' ? ' <small title="Ricopiata dal foglio di carta">📝 carta</small>' : l.created_at && Date.parse(l.created_at) - Date.parse(l.logged_at) > 120000 ? ` <small title="Registrata senza rete sul tablet: arrivata dopo">📶 inserita alle ${fmtDT(l.created_at)}</small>` : ''}</td><td>${esc(l.corrective_action || '')}${l.correction_note ? `<br><small class="ko">Correzione: ${esc(l.correction_note)}</small>` : ''}</td>
      <td>${isManager && l.haccp_control_points?.unit !== 'esito' && l.haccp_control_points?.code !== 'PRP-CLEAN' ? `<button class="btn sm sec" data-fixlog="${l.id}">Correggi</button>` : ''}</td></tr>`).join('')}</table>`;
    // v0.96 (audit D-02): a record is never edited or deleted; a correction keeps the original value and the reason, and prints on the register
    $('logs').querySelectorAll('[data-fixlog]').forEach(b => b.onclick = async () => {
      const l = rows.find(x => x.id === b.dataset.fixlog); if (!l) return;
      const cp = l.haccp_control_points || {};
      const v = await ask(`Correggi: ${cp.ccp_no || ''} ${cp.name || ''} · ${fmtDT(l.logged_at)}`,
        `<div class="hint">Registrato: <b>${num(l.measured_value, 2)} ${esc(cp.unit || '')}</b>${l.production_batches?.batch_lot ? ' · lotto ' + esc(l.production_batches.batch_lot) : ''} · ${esc(l.operator || '')}. Il valore originale resta scritto sul registro insieme al motivo.</div>
         <div class="form"><div><label>Valore giusto (${esc(cp.unit || '')})</label><input id="fx-val" type="text" inputmode="decimal" autocomplete="off"></div>
         ${['CCP-STRETCH', 'CCP-RIC', 'CCP-PAST'].includes(cp.code) ? '<div><label>Lotto giusto (se era sbagliato)</label><input id="fx-lot" type="text" style="text-transform:uppercase"></div>' : ''}</div>
         ${REASONS}`,
        'Salva la correzione', () => {
          const ch = {}, t = $('fx-val').value.trim().replace(',', '.');
          if (t !== '') { if (!/^-?\d+(\.\d+)?$/.test(t)) throw new Error('Valore: scrivi un numero (es. 62 oppure 4,5)'); ch.measured_value = Number(t); }
          if ($('fx-lot') && $('fx-lot').value.trim()) ch.batch_lot = $('fx-lot').value.trim().toUpperCase();
          if (!Object.keys(ch).length) throw new Error('Scrivi il valore giusto (o il lotto giusto)');
          return { ch, reason: reasonOf() };
        });
      if (!v) return;
      const r = fail(await sb.rpc('correct_record', { p_table: 'haccp_log', p_id: l.id, p_changes: v.ch, p_reason: v.reason, p_staff_id: staff.id }), 'Correzione');
      toast(r.nc_id ? 'Corretto: il valore giusto è fuori limite → non conformità aperta e lotto bloccato' : l.result === 'non_conformity' && r.result !== 'non_conformity'
        ? 'Corretto. La NC e l\'eventuale blocco restano: chiudili dopo averli valutati (Non conformità, Lotti bloccati)' : 'Correzione registrata', r.nc_id || l.result === 'non_conformity' ? 'err' : '');
      load();
    });
  }
  // the reason of a correction: a short list (what usually happens) + a note
  const REASONS = `<div class="form" style="margin-top:8px"><div><label>Motivo</label><select id="fx-why" required><option value="" selected disabled>— scegli —</option><option>errore di battitura</option><option>letto male dallo strumento o dal foglio</option><option>strumento sbagliato</option><option>lotto sbagliato</option><option>pesata di nuovo</option><option>altro</option></select></div>
    <div><label>Note (obbligatorie con «altro»)</label><input id="fx-note" type="text"></div></div>`;
  const reasonOf = () => { const w = $('fx-why').value, n = $('fx-note').value.trim(); if (!w) throw new Error('Scegli il motivo'); if (w === 'altro' && n.length < 3) throw new Error('Scrivi il motivo nelle note'); return n ? `${w}: ${n}` : w; };
  // v0.96 (audit D-02): milk deliveries and closed lots of the last 7 days, corrected the same way (kg, temperature, DDT; kg produced, pH)
  async function loadProdRecords() {
    const box = $('prodrecs'); if (!box) return;
    const prodManager = PERM.can('produzione', 3);   // the server asks produzione 3 for someone else's delivery or lot
    const since = addDays(todayRome(), -7);
    const [mi, pb] = await Promise.all([
      sb.from('milk_intake').select('id, milk_lot, intake_date, intake_time, qty_kg, temperature_c, ddt_number, accepted, correction_note').gte('intake_date', since).order('intake_date', { ascending: false }).limit(40),
      sb.from('production_batches').select('id, batch_lot, batch_date, output_kg, curd_ph, whey_kg, input_kind, notes, products(name)').gte('batch_date', since).not('output_kg', 'is', null).order('batch_date', { ascending: false }).order('batch_lot').limit(60)]);
    const M = mi.data || [], B = pb.data || [];
    box.innerHTML = `<h4 style="margin:4px 0">Arrivi latte</h4>${M.length ? `<table><tr><th>Lotto</th><th>Quando</th><th class="num">kg</th><th class="num">°C</th><th>DDT</th><th></th></tr>${M.map(m => `
        <tr><td class="nw"><b>${esc(m.milk_lot)}</b>${m.accepted === false ? ' ' + pill('respinto', 'ko') : ''}</td><td class="nw">${fmtD(m.intake_date)} ${esc(String(m.intake_time || '').slice(0, 5))}</td><td class="num">${num(m.qty_kg)}</td><td class="num">${num(m.temperature_c)}</td>
        <td>${esc(m.ddt_number || '')}${m.correction_note ? `<br><small class="ko">Correzione: ${esc(m.correction_note)}</small>` : ''}</td><td>${prodManager ? `<button class="btn sm sec" data-fixmi="${m.id}">Correggi</button>` : ''}</td></tr>`).join('')}</table>` : '<div class="empty">Nessun arrivo negli ultimi 7 giorni.</div>'}
      <h4 style="margin:12px 0 4px">Lotti chiusi</h4>${B.length ? `<table><tr><th>Lotto</th><th>Prodotto</th><th class="num">kg prodotti</th><th class="num">pH</th><th></th></tr>${B.map(b => `
        <tr><td class="nw"><b>${esc(b.batch_lot)}</b><br><small>${fmtD(b.batch_date)}</small></td><td>${esc(b.products?.name || '')}${/corretto da/.test(b.notes || '') ? `<br><small class="ko">${esc((b.notes || '').split('\n').filter(x => /corretto da/.test(x)).join(' · '))}</small>` : ''}</td>
        <td class="num">${num(b.output_kg, 2)}</td><td class="num">${b.curd_ph == null ? '—' : num(b.curd_ph, 2)}</td><td>${prodManager ? `<button class="btn sm sec" data-fixpb="${b.id}">Correggi</button>` : ''}</td></tr>`).join('')}</table>` : '<div class="empty">Nessun lotto chiuso negli ultimi 7 giorni.</div>'}`;
    const numIn = (id, label, cur) => `<div><label>${label} (ora ${cur == null ? '—' : num(cur, 2)})</label><input id="${id}" type="text" inputmode="decimal" autocomplete="off"></div>`;
    const readNums = ids => { const ch = {}; for (const [id, k] of ids) { const e = $(id); if (!e) continue; const t = (e.value || '').trim().replace(',', '.'); if (t === '') continue; if (!/^\d+(\.\d+)?$/.test(t)) throw new Error('Scrivi un numero (es. 1050 oppure 4,5)'); ch[k] = Number(t); } return ch; };
    box.querySelectorAll('[data-fixmi]').forEach(b => b.onclick = async () => {
      const m = M.find(x => x.id === b.dataset.fixmi);
      const v = await ask(`Correggi l'arrivo latte ${m.milk_lot}`, `<div class="hint">Scrivi solo ciò che cambia. L'originale resta sul registro MOD-01 con il motivo; se cambiano i kg, il magazzino del latte si adegua. La temperatura si corregge dalla sua registrazione CCP 1a qui sopra (così, se è fuori limite, il latte viene respinto).</div>
        <div class="form">${numIn('fx-kg', 'kg', m.qty_kg)}<div><label>DDT (ora ${esc(m.ddt_number || '—')})</label><input id="fx-ddt" type="text"></div></div>${REASONS}`,
        'Salva la correzione', () => { const ch = readNums([['fx-kg', 'qty_kg']]); if ($('fx-ddt').value.trim()) ch.ddt_number = $('fx-ddt').value.trim();
          if (!Object.keys(ch).length) throw new Error('Scrivi almeno un valore da correggere'); return { ch, reason: reasonOf() }; });
      if (!v) return;
      fail(await sb.rpc('correct_record', { p_table: 'milk_intake', p_id: m.id, p_changes: v.ch, p_reason: v.reason, p_staff_id: staff.id }), 'Correzione');
      toast('Correzione registrata'); loadProdRecords();
    });
    box.querySelectorAll('[data-fixpb]').forEach(b => b.onclick = async () => {
      const x = B.find(y => y.id === b.dataset.fixpb);
      const v = await ask(`Correggi il lotto ${x.batch_lot}`, `<div class="hint">Scrivi solo ciò che cambia. La correzione resta nelle note del lotto; se cambiano i kg, il magazzino del lotto si adegua.</div>
        <div class="form">${numIn('fx-out', 'kg prodotti', x.output_kg)}${x.input_kind === 'whey' ? '' : numIn('fx-ph', 'pH cagliata', x.curd_ph)}</div>${REASONS}`,
        'Salva la correzione', () => { const ch = readNums([['fx-out', 'output_kg'], ['fx-ph', 'curd_ph']]); if (!Object.keys(ch).length) throw new Error('Scrivi almeno un valore da correggere');
          if (ch.curd_ph != null && (ch.curd_ph < 3 || ch.curd_ph > 8)) throw new Error('pH impossibile: controlla la virgola'); return { ch, reason: reasonOf() }; });
      if (!v) return;
      fail(await sb.rpc('correct_record', { p_table: 'production_batches', p_id: x.id, p_changes: v.ch, p_reason: v.reason, p_staff_id: staff.id }), 'Correzione');
      toast('Correzione registrata'); loadProdRecords();
    });
  }

  // ---------- Piano ----------
  function renderPlan(rows) {
    // v0.93 (audit B-01): text field with the decimal comma, the old value kept to compare; a blank or mistyped limit is refused, not saved as "no limit"
    const itNum = v => v == null || v === '' ? '' : String(Number(v)).replace('.', ',');
    const inp = (r, k) => `<input type="text" inputmode="decimal" autocomplete="off" data-k="${k}" data-orig="${r[k] ?? ''}" value="${itNum(r[k])}" style="width:6.5em" ${isManager ? '' : 'disabled'}>`;
    $('plan').innerHTML = `<table><tr><th>Punto</th><th>Fase</th><th>Registro</th><th>Limite critico (testo)</th><th class="num">Min</th><th class="num">Max</th><th class="num">Allerta min</th><th class="num">Allerta max</th><th class="num">30 gg</th><th></th></tr>${rows.map(r => `
      <tr data-code="${esc(r.code)}" data-ccp="${r.is_ccp ? 1 : 0}" data-name="${esc((r.ccp_no ? r.ccp_no + ' · ' : '') + r.name)}" data-unit="${esc(r.unit || '')}"><td>${pill(r.ccp_no || 'PRP', r.is_ccp ? 'ccp' : '')}<br><b>${esc(r.name)}</b>${r.applies_when !== 'sempre' ? `<br><small>${esc(r.applies_when.replace('_', ' '))}</small>` : ''}</td><td>${esc(r.process_step || '')}</td><td class="nw">${modChip(r.form_code)}</td>
      <td style="min-width:240px">${esc(r.critical_limit_it || '')}
        <details class="more"><summary>Pericolo, monitoraggio, azioni</summary><dl><dt>Pericolo</dt><dd>${esc(r.hazard_it || '—')}</dd><dt>Monitoraggio</dt><dd>${esc(r.monitoring_it || '—')}</dd><dt>Azione correttiva</dt><dd>${esc(r.corrective_it || '—')}</dd><dt>Verifica</dt><dd>${esc(r.verification_it || '—')}</dd><dt>Registrazioni</dt><dd>${esc(r.records_it || '—')}</dd></dl></details></td>
      <td class="num">${inp(r, 'min_value')}</td><td class="num">${inp(r, 'max_value')}</td><td class="num">${inp(r, 'warn_min')}</td><td class="num">${inp(r, 'warn_max')}</td>
      <td class="num">${r.logs_30d}${r.nc_30d ? `<br><span class="ko">${r.nc_30d} NC</span>` : ''}</td><td>${isManager ? '<button class="btn sm sec" data-save>Salva</button>' : ''}</td></tr>`).join('')}</table>`;
    $('plan').querySelectorAll('[data-save]').forEach(b => b.onclick = async () => {
      const tr = b.closest('tr'), v = {}, changes = [], big = [], u = tr.dataset.unit ? ' ' + tr.dataset.unit : '';
      const LBL = { min_value: 'Limite critico minimo', max_value: 'Limite critico massimo', warn_min: 'Allerta minima', warn_max: 'Allerta massima' };
      for (const i of tr.querySelectorAll('input[data-k]')) {
        const t = i.value.trim().replace(/\s/g, ''), k = i.dataset.k, was = i.dataset.orig === '' ? null : Number(i.dataset.orig);
        if (t !== '' && !/^-?\d+([.,]\d+)?$/.test(t)) { toast(`${LBL[k]}: "${i.value}" non è un numero (es. 72 oppure 72,5)`, 'err'); i.focus(); return; }
        const now = t === '' ? null : Number(t.replace(',', '.'));
        if (now === was) continue;
        if (was != null && now == null && (k === 'min_value' || k === 'max_value') && tr.dataset.ccp === '1') {
          toast(`${LBL[k]} di ${tr.dataset.name}: non si cancella. Scrivi il nuovo valore (era ${itNum(was)}${u}).`, 'err'); i.focus(); return; }
        v[k] = now;
        changes.push(`${LBL[k]}: ${was == null ? '—' : itNum(was) + u} → ${now == null ? '—' : itNum(now) + u}`);
        if (was && now != null && (k === 'min_value' || k === 'max_value') && Math.abs(now - was) / Math.abs(was) > 0.2)
          big.push(`${LBL[k]} cambia del ${Math.round((now - was) / Math.abs(was) * 100)} %`);
      }
      if (!changes.length) { toast('Nessuna modifica da salvare'); return; }
      if (tr.dataset.ccp === '1' && ['min_value', 'max_value'].every(k => (k in v ? v[k] : (tr.querySelector(`input[data-k="${k}"]`).dataset.orig || null)) == null)) {
        toast(`${tr.dataset.name}: un punto critico deve avere almeno un limite (minimo o massimo)`, 'err'); return; }
      const msg = `${tr.dataset.name}\n\n${changes.join('\n')}${big.length ? '\n\n⚠ ATTENZIONE: ' + big.join(' · ') + '. Controlla la virgola.' : ''}\n\n` +
        'Vale da subito per tablet e bot. Fallo solo se deciso con il consulente HACCP, e aggiorna la revisione del Manuale (Configurazione → Parametri → Sicurezza alimentare e DOP).\n\nSalvare?';
      if (!confirm(msg)) return;
      v.updated_at = new Date().toISOString();
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
    // v0.95 (audit B-05): the lot is chosen from the recent lots (or typed and checked), never free text that a positive result cannot find
    $('labplan').querySelectorAll('[data-take]').forEach(b => b.onclick = async () => {
      const t = rows.find(r => r.code === b.dataset.take) || {}, milk = /^latte/.test(t.matrix || ''), noLot = /^(acqua|ambiente)$/.test(t.matrix || '');
      const [pb, mi] = await Promise.all([
        milk ? { data: [] } : sb.from('production_batches').select('batch_lot, batch_date, output_kg, products(name)').gte('batch_date', addDays(todayRome(), -14)).not('output_kg', 'is', null).order('batch_date', { ascending: false }).order('batch_lot').limit(60),
        milk ? sb.from('milk_intake').select('milk_lot, intake_date, qty_kg').gte('intake_date', addDays(todayRome(), -7)).order('intake_date', { ascending: false }).limit(30) : { data: [] }]);
      const opts = [...(pb.data || []).map(x => [x.batch_lot, `${x.batch_lot} · ${x.products?.name || ''} · ${fmtD(x.batch_date)} · ${num(x.output_kg)} kg`]),
                    ...(mi.data || []).map(x => [x.milk_lot, `${x.milk_lot} · latte del ${fmtD(x.intake_date)} · ${num(x.qty_kg, 0)} kg`])];
      const known = new Set(opts.map(o => o[0].toUpperCase()));
      const lot = await ask(`Campione ${b.dataset.take} · ${t.analyte_it || ''}`,
        `<div class="form"><div><label>Lotto</label><select id="sm-lot"><option value="">${noLot ? '— nessun lotto (acqua / ambiente) —' : '— scegli il lotto —'}</option>${opts.map(([v, l]) => `<option value="${esc(v)}">${esc(l)}</option>`).join('')}<option value="__none">Nessun lotto: il campione non è di un lotto</option></select></div>
         <div><label>Oppure scrivi il lotto (es. L20261012-A)</label><input id="sm-typed" type="text" autocomplete="off" style="text-transform:uppercase"></div></div>`,
        'Registra il prelievo', async () => {
          const typed = $('sm-typed').value.replace(/\s/g, '').toUpperCase(), sel = $('sm-lot').value;
          if (typed) {                                                     // not in the list: look it up (older lots, other suppliers' milk)
            if (!known.has(typed)) {
              const [a, m] = await Promise.all([sb.from('production_batches').select('batch_lot').eq('batch_lot', typed).limit(1), sb.from('milk_intake').select('milk_lot').ilike('milk_lot', typed).limit(1)]);
              if (!(a.data || []).length && !(m.data || []).length) throw new Error(`Lotto ${typed} non trovato: controlla il codice sull'etichetta`);
            }
            return typed;
          }
          if (sel === '__none' || (noLot && !sel)) return '';
          if (!sel) throw new Error('Scegli il lotto dall\'elenco, scrivilo, oppure scegli «Nessun lotto»');
          return sel;
        });
      if (lot === null) return;
      const r = fail(await sb.rpc('record_sample_taken', { p_test_code: b.dataset.take, p_lot: lot || null, p_staff_id: staff.id }), 'Campione');
      toast(`Campione ${r.sample_code}${lot ? ' · lotto ' + lot : ''}: scrivilo sul contenitore`); load();
    });
  }
  function renderSamples(rows) {
    if (!rows.length) { $('samples').innerHTML = '<div class="empty">Nessun campione registrato.</div>'; return; }
    const out = { in_attesa: pill('in attesa'), conforme: pill('conforme', 'ok'), attenzione: pill('attenzione', 'warn'), non_conforme: pill('non conforme', 'ko'), annullato: pill('annullato') };
    $('samples').innerHTML = `<table><tr><th>Campione</th><th>Analisi</th><th>Lotto</th><th>Esito</th><th>Referto</th></tr>${rows.map(s => `
      <tr data-sample="${esc(s.sample_code)}"><td class="nw"><b>${esc(s.sample_code)}</b><br><small>${fmtD(s.taken_on)}${s.taken_by ? ' · ' + esc(s.taken_by) : ''}</small></td><td>${esc(s.test_code)}<br><small>${esc(s.analyte_it)}</small></td><td class="nw">${esc(s.lot_number || '')}</td>
      <td>${out[s.outcome] || esc(s.outcome)}${s.outcome === 'in_attesa' && s.days_waiting > 14 ? `<br><span class="ko">da ${s.days_waiting} g</span>` : ''}${s.result_it ? `<br><small>${esc(s.result_it)}</small>` : ''}</td>
      <td>${s.outcome === 'in_attesa' ? `<div class="form" style="min-width:420px"><div><label>Esito</label><select data-k="outcome"><option value="" selected disabled>— scegli l'esito —</option><option value="conforme">Conforme</option><option value="attenzione">Attenzione</option><option value="non_conforme">NON conforme</option><option value="annullato">Annullato</option></select></div>
          <div><label>Risultato</label><input type="text" data-k="text" placeholder="es. assente in 25 g"></div><div><label>N. referto</label><input type="text" data-k="report"></div><div><label>PDF</label><input type="file" data-k="file" accept="application/pdf,image/*"></div><div><button class="btn sm" data-res>Registra</button></div></div>`
        : `${esc(s.report_no || '')} ${s.report_date ? fmtD(s.report_date) : ''} ${s.document_id ? `<a href="#" data-doc="${s.document_id}">PDF</a>` : ''}${s.outcome !== 'annullato' ? ` <button class="btn sm sec" data-fix="${esc(s.sample_code)}" data-was="${esc(s.outcome)}">Correggi esito</button>` : ''}`}</td></tr>`).join('')}</table>`;
    $('samples').querySelectorAll('[data-res]').forEach(b => b.onclick = async () => {
      const tr = b.closest('tr'), g = k => tr.querySelector(`[data-k=${k}]`), outcome = g('outcome').value;
      // v0.95 (audit B-02): no default outcome — one tap on Registra can no longer write "conforme" into the register
      if (!outcome) { toast('Scegli l\'esito del referto', 'err'); g('outcome').focus(); return; }
      if ((outcome === 'conforme' || outcome === 'non_conforme') && !g('text').value.trim()) { toast('Scrivi il risultato come sul referto (es. assente in 25 g)', 'err'); g('text').focus(); return; }
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
    // v0.95 (audit B-02): correct an outcome recorded by mistake — with a reason; the first outcome stays on the sample and in the audit log
    const OUT = { conforme: 'Conforme', attenzione: 'Attenzione', non_conforme: 'NON conforme', annullato: 'Annullato' };
    $('samples').querySelectorAll('[data-fix]').forEach(b => b.onclick = async () => {
      const sc = b.dataset.fix, was = b.dataset.was;
      const v = await ask(`Correggi l'esito del campione ${sc}`,
        `<div class="hint">Esito registrato: <b>${esc(OUT[was] || was)}</b>. Resta scritto sul campione insieme al motivo.</div>
         <div class="form"><div><label>Esito giusto</label><select id="fx-out" required><option value="" selected disabled>— scegli —</option>${Object.entries(OUT).filter(([k]) => k !== was).map(([k, t]) => `<option value="${k}">${t}</option>`).join('')}</select></div>
         <div><label>Risultato (come sul referto)</label><input id="fx-text" type="text" placeholder="es. presente in 25 g"></div></div>
         <label style="margin-top:8px">Motivo della correzione (obbligatorio)</label><input id="fx-why" type="text" required minlength="3" style="width:100%" placeholder="es. esito letto male dal referto">`,
        'Correggi', () => {
          const out = $('fx-out').value, why = $('fx-why').value.trim();
          if (!out) throw new Error('Scegli l\'esito giusto'); if (why.length < 3) throw new Error('Scrivi il motivo');
          if (out === 'non_conforme' && !confirm('Esito NON conforme: si apre una non conformità e, per le analisi di sicurezza, il lotto viene bloccato e si chiede la valutazione del ritiro. Confermi?')) throw new Error('Non salvato');
          return { out, why, text: $('fx-text').value.trim() };
        });
      if (!v) return;
      const r = fail(await sb.rpc('correct_lab_result', { p_sample_code: sc, p_outcome: v.out, p_reason: v.why, p_text: v.text || null, p_staff_id: staff.id }), 'Correzione');
      if (r.nc_id) alert('NON CONFORMITÀ aperta.\n\nCosa fare:\n• ' + (r.actions_it || []).join('\n• '));
      else toast(was === 'non_conforme' ? 'Esito corretto. La non conformità e l\'eventuale blocco del lotto restano: chiudili da Non conformità e Lotti bloccati se l\'esito giusto lo permette.' : 'Esito corretto', was === 'non_conforme' ? 'err' : '');
      load();
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
      <td class="nw">${r.last_result ? (r.last_result === 'ok' ? pill('ok', 'ok') : r.last_result === 'da_verificare' ? pill('da verificare', 'warn') : pill('fuori tolleranza', 'ko')) + `<br><small>${fmtDT(r.last_check_at)}${r.last_deviation != null ? ' · scarto ' + num(r.last_deviation, 2) : ''}</small>` : '—'}</td></tr>`).join('')}</table>`;
    const keep = $('ce-code').value;
    $('ce-code').innerHTML = rows.filter(r => r.calibration_interval_days || r.reference_instrument).map(r => `<option value="${esc(r.code)}">${esc(r.code)} · ${esc(r.name)}</option>`).join('');
    if (keep) $('ce-code').value = keep;
    $('ce-date').value = $('ce-date').value || todayRome(); $('ce-date').max = todayRome();
  }
  $('ce-save').onclick = async () => {
    // v0.95 (audit B-03): certificate number + (deviation or PDF), no future date; without the deviation the instrument does not go back in service
    if (!$('ce-provider').value.trim()) return toast('Scrivi il centro o il tecnico', 'err');
    if (!$('ce-cert').value.trim()) return toast('Scrivi il numero del certificato', 'err');
    const devTxt = $('ce-dev').value.trim().replace(',', '.');
    if (devTxt !== '' && !/^\d+(\.\d+)?$/.test(devTxt)) return toast('Scarto max: scrivi un numero (es. 0,2)', 'err');
    if (devTxt === '' && !$('ce-file').files[0]) return toast('Scrivi lo scarto massimo del certificato oppure allega il PDF', 'err');
    if ($('ce-date').value && $('ce-date').value > todayRome()) return toast('La data è nel futuro: scrivi il giorno della taratura', 'err');
    $('ce-save').disabled = true;
    try {
      const docId = await upload($('ce-file').files[0], 'tarature', 'calibration_cert', 'equipment');
      const dev = devTxt === '' ? null : Number(devTxt);
      const r = fail(await sb.rpc('record_calibration_check', { p_code: $('ce-code').value, p_kind: 'taratura_esterna', p_method: 'certificato_lab', p_points: dev == null ? [] : [{ ref: 0, reading: dev }],
        p_staff_id: staff.id, p_provider: $('ce-provider').value.trim(), p_certificate_no: $('ce-cert').value || null, p_document_id: docId, p_on: $('ce-date').value || null }), 'Taratura');
      toast(r.result === 'ok' ? 'Taratura registrata · prossima scadenza aggiornata'
          : r.result === 'da_verificare' ? (r.out_of_service ? 'Taratura registrata DA VERIFICARE: senza lo scarto lo strumento resta fuori servizio. Registrala di nuovo con lo scarto letto sul certificato.' : 'Taratura registrata DA VERIFICARE: aggiungi lo scarto letto sul certificato appena puoi.')
          : 'Scarto oltre la tolleranza: strumento fuori servizio', r.result === 'ok' ? '' : 'err');
      ['ce-provider', 'ce-cert', 'ce-dev', 'ce-file'].forEach(id => $(id).value = ''); load();
    } finally { $('ce-save').disabled = false; }
  };
  function renderChecks(rows) {
    if (!rows.length) { $('checks').innerHTML = '<div class="empty">Nessuna verifica registrata.</div>'; return; }
    const M = { ghiaccio_fondente: 'ghiaccio fondente', acqua_bollente: 'acqua bollente', confronto_riferimento: 'confronto col riferimento', tamponi_ph: 'tamponi pH', pesi_campione: 'pesi campione', certificato_lab: 'certificato', confronto_display: 'confronto display' };
    $('checks').innerHTML = `<table><tr><th>Quando</th><th>Strumento</th><th>Tipo</th><th class="num">Scarto</th><th>Esito</th><th></th></tr>${rows.map(c => `
      <tr><td class="nw">${fmtDT(c.checked_at)}</td><td>${esc(c.equipment?.code || '')}</td><td>${c.kind === 'taratura_esterna' ? 'taratura esterna' : 'verifica interna'} · ${esc(M[c.method] || c.method)}${c.provider ? '<br><small>' + esc(c.provider) + (c.certificate_no ? ' · ' + esc(c.certificate_no) : '') + '</small>' : ''}</td>
      <td class="num">${c.max_deviation != null ? num(c.max_deviation, 2) : '—'}${c.tolerance != null ? ` / ±${num(c.tolerance, 2)}` : ''}</td><td>${c.result === 'ok' ? pill('ok', 'ok') : c.result === 'da_verificare' ? pill('da verificare', 'warn') : pill('fuori tolleranza', 'ko')}</td>
      <td>${c.certificate_document_id ? `<a href="#" data-doc="${c.certificate_document_id}">PDF</a>` : ''}</td></tr>`).join('')}</table>`;
  }

  init();
})();
