/* Registro HACCP stampabile (v0.57). registro.html?mod=MOD-05&from=AAAA-MM-GG&to=AAAA-MM-GG[&blank=1]
   Reads fabula.haccp_register(mod, from, to): header (azienda, riconoscimento CE, responsabile, revisione del Manuale di Autocontrollo),
   columns, rows (_ko / _warn flag the row), weekly verifications of that register. blank=1 prints the empty paper form (tablet down). */
(() => {
  const CFG = window.FABULA_CONFIG;
  const sb = supabase.createClient(CFG.supabaseUrl, CFG.supabaseKey, { db: { schema: 'fabula' } });
  const $ = id => document.getElementById(id);
  const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const todayRome = () => new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Rome' });
  const addDays = (iso, n) => { const d = new Date(iso + 'T12:00:00'); d.setDate(d.getDate() + n); return d.toISOString().slice(0, 10); };
  const fmtD = s => s ? String(s).slice(8, 10) + '/' + String(s).slice(5, 7) + '/' + String(s).slice(0, 4) : '';
  const fmtDT = s => s ? new Date(s).toLocaleString('it-IT', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Rome' }) : '';
  const qs = new URLSearchParams(location.search);
  const BLANK_ROWS = 18;

  async function init() {
    const { data: { session } } = await sb.auth.getSession();
    if (!session) { $('sheet').innerHTML = '<p>Accedi prima dalla pagina <a href="haccp.html">Manuale di Autocontrollo</a>, poi riapri il registro.</p>'; return; }
    const P = await PERM.load(sb);
    if (!P || !P.staff_id) return PERM.deny(sb, PERM.notLinked(session.user.email));
    if (!PERM.page('haccp')) return PERM.deny(sb, PERM.notForProfile());
    const { data: forms, error } = await sb.from('haccp_forms').select('code, title_it').order('sort');
    if (error) { $('sheet').innerHTML = `<p class="err">${esc(error.message)}</p>`; return; }
    $('mod').innerHTML = (forms || []).map(f => `<option value="${esc(f.code)}">${esc(f.code)} · ${esc(f.title_it)}</option>`).join('');
    const to = qs.get('to') || todayRome();
    $('mod').value = (qs.get('mod') || 'MOD-01').toUpperCase();
    $('to').value = to; $('from').value = qs.get('from') || addDays(to, -30);
    $('blank').checked = qs.get('blank') === '1';
    $('go').onclick = load; $('print').onclick = () => window.print();
    $('mod').onchange = load; $('blank').onchange = load;
    [$('from'), $('to')].forEach(i => i.addEventListener('keydown', e => { if (e.key === 'Enter') load(); }));
    load();
  }

  async function load() {
    const mod = $('mod').value, from = $('from').value, to = $('to').value, blank = $('blank').checked;
    history.replaceState(null, '', `?mod=${encodeURIComponent(mod)}&from=${from}&to=${to}${blank ? '&blank=1' : ''}`);
    $('sheet').innerHTML = '<p>Caricamento…</p>';
    const { data, error } = await sb.rpc('haccp_register', { p_form: mod, p_from: from || null, p_to: to || null });
    if (error) { $('sheet').innerHTML = `<p class="err">${esc(error.message)}</p>`; return; }
    render(data, blank);
  }

  function render(r, blank) {
    const h = r.header || {}, f = r.form || {}, cols = r.columns || [];
    const draft = (h.manual_status || 'bozza') !== 'firmato';
    document.title = `${f.code} · ${f.title_it}`;
    const rows = blank ? Array.from({ length: BLANK_ROWS }, () => null) : (r.rows || []);
    const ko = blank ? 0 : rows.filter(x => x._ko).length, warn = blank ? 0 : rows.filter(x => x._warn && !x._ko).length;
    const period = blank ? 'Modulo da compilare a mano · riportare i dati sul sistema appena possibile' : `Periodo dal ${fmtD(r.from)} al ${fmtD(r.to)}`;
    const banner = f.status === 'da_attivare' ? '<div class="banner">Registro non ancora attivo sul sistema (Manuale §13): usare il modulo cartaceo.</div>'
      : f.status === 'cartaceo' ? '<div class="banner">Registro cartaceo: stampare il modulo vuoto, compilarlo e archiviarlo in Documenti.</div>' : '';
    const tbody = rows.length ? rows.map(x => x ? `<tr class="${x._ko ? 'ko' : x._warn ? 'warn' : ''}">${cols.map(([k]) => `<td>${esc(x[k])}</td>`).join('')}</tr>`
                                                 : `<tr class="blank">${cols.map(() => '<td></td>').join('')}</tr>`).join('')
      : `<tr><td class="empty" colspan="${cols.length}">Nessuna registrazione nel periodo.</td></tr>`;
    const revs = (r.reviews || []).map(v => `${fmtD(v.from)}–${fmtD(v.to)}: ${v.outcome === 'ok' ? 'verificato, nessun rilievo' : 'verificato CON RILIEVI: ' + esc(v.note || '')} (${esc(v.by || '')}, ${fmtDT(v.at)}${v.rev ? ', rev. ' + esc(v.rev) : ''})`);
    $('sheet').innerHTML = `
      ${banner}
      <div class="hd">
        <div class="co">
          <div class="name">${esc(h.legal_name || h.company || '')}</div>
          <div>${h.legal_name && h.company && h.legal_name !== h.company ? esc(h.company) + ' · ' : ''}${esc(h.address || 'indirizzo da compilare')}${h.piva ? ' · P.IVA ' + esc(h.piva) : ''}</div>
          <div>Riconoscimento CE n. ${h.ce_no ? '<b>' + esc(h.ce_no) + '</b>' : '<span class="draft">da compilare</span>'} (Reg. CE 853/2004)</div>
          <div>Responsabile dell'autocontrollo: ${h.responsabile ? esc(h.responsabile) : '<span class="draft">da nominare</span>'}</div>
        </div>
        <div class="man">
          <div class="mod">${esc(f.code)}</div>
          <div class="t">${esc(f.title_it)}</div>
          <div>Manuale di Autocontrollo rev. ${esc(h.manual_rev || '?')}${h.manual_date ? ' del ' + fmtD(h.manual_date) : ''}${draft ? ' · <span class="draft">BOZZA</span>' : ''} · ${esc(f.manual_section)}</div>
          <div>${period}</div>
        </div>
      </div>
      ${blank ? '' : `<p class="sum">${rows.length} registrazioni${ko ? ` · <b class="draft">${ko} non conformi o mancanti</b>` : ''}${warn ? ` · ${warn} in allerta` : ''} · righe in rosso = fuori limite o controllo non registrato, vedi MOD-12 per le azioni correttive.</p>`}
      <table class="reg">
        <thead>
          <tr class="ref"><th colspan="${cols.length}">${esc(r.ref)} · ${esc(h.company || '')} · ${blank ? 'modulo vuoto' : esc(period)}</th></tr>
          <tr>${cols.map(([, label]) => `<th>${esc(label)}</th>`).join('')}</tr>
        </thead>
        <tbody>${tbody}</tbody>
      </table>
      <div class="foot">
        <div class="meta">Frequenza: ${esc(f.frequency_it || '—')} · Chi registra: ${esc(f.responsible_it || '—')} · Dove: ${esc(f.where_it || '—')}</div>
        ${blank ? '' : `<div class="revs"><b>Verifiche del responsabile nel periodo:</b> ${revs.length ? revs.join(' · ') : 'nessuna registrata sul sistema'}</div>`}
        <div class="sign"><div>Verificato dal responsabile dell'autocontrollo${h.responsabile ? ': ' + esc(h.responsabile) : ''}</div><div>Data</div><div>Firma</div></div>
        <div class="small">Stampato il ${fmtDT(r.printed_at)}. Le registrazioni non si cancellano: un errore si corregge con una nuova registrazione e la motivazione (Manuale §11). Conservare almeno ${esc(h.retention_years || '2')} anni.</div>
      </div>`;
  }

  init();
})();
