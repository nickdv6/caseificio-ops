/* Configuration page (v0.84), separate from the operational console. Tabs: Panoramica (one status card per area: what is late,
   empty or waiting, each opening its tab) · Parametri (every fabula.settings row grouped by key prefix; a section list on the left,
   one section on screen at a time, search across all of them, technical keys folded at the end of their section, one "Salva tutto"
   bar; prefixes not listed in SECTIONS show under "Altri parametri" so no setting is ever hidden) · Macchine e scadenze (status
   strip + cards) · Prodotti Shopify · Bot (status cards, notification feed, run log) · Utenti e accessi (people, profiles, own
   password) · Registro modifiche. Shared shell (login, header, tabs, helpers) in ui.js. */
(() => {
  const { sb, $, esc, fmtD, nOrNull, dOrNull, toast, badge, upd, saveBtn } = UI;
  let staff = null;
  const dueCls = s => { if (!s) return ''; const d = (new Date(s) - new Date(UI.romeISO())) / 864e5; return d <= 30 ? 'ko' : ''; };
  const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;

  // ---------- Parametri ----------
  // [anchor, title, key prefixes, explanation]. Old links (#azienda, #produzione, #vendite, #utenze, #lavoro) land on their section.
  const SECTIONS = [
    ['azienda', 'Azienda', ['company'], "Intestazione di ordini e documenti stampati. Inserisci i dati dell'acquirente (non quelli del venditore) quando la società è definita. Il nome commerciale cambia subito intestazioni e titoli di tutte le pagine."],
    ['produzione', 'Produzione e latte', ['milk', 'farm', 'prod'], 'Come il bot Piano latte dimensiona il latte del giorno dopo, capacità e lotto, tolleranze di resa. I kg disponibili giorno per giorno si correggono in <a class="lnk" href="console.html#ops">Console → Operazioni</a>.'],
    ['approvazioni', 'Approvazioni automatiche', ['approve', 'bots'], 'Cosa si approva da solo e dopo quanto; tutto il resto aspetta te in <a class="lnk" href="console.html#oggi">Console → Oggi</a>.'],
    ['acquisti', 'Acquisti', ['purchasing'], 'Quando il bot Acquisti propone un ordine. Tempi e minimi per singolo fornitore: <a class="lnk" href="console.html#anag">Console → Anagrafiche</a>.'],
    ['vendite', 'Vendite e prezzi', ['price', 'sell', 'sales'], 'Prezzi di riferimento, soglie del bot Vendere prima (lotti in scadenza) e obiettivi del bot Vendite.'],
    ['professionisti', 'Professionisti · ingrosso B2B', ['trade'], 'Regole del portale per ristoranti, pizzerie e hotel: minimo, ora limite, giorni e fasce di consegna, sconti e pagamento. Richieste, piani e listino: <a class="lnk" href="ingrosso.html">Ingrosso</a>.'],
    ['canali', 'Shopify, ritiri e spedizioni', ['shopify', 'pickup', 'ship'], 'Shopify è la cassa e il sito: ordini, clienti e giacenze li sincronizza il database ogni mattina (Configurazione → Bot → Ordini, Clienti e Giacenze Shopify). Fasce di ritiro (anche in Marketing) e vettori/tolleranze usati dal tablet in spedizione.'],
    ['incassi', 'Incassi e banca', ['recon'], 'Tolleranze degli abbinamenti fra versamenti Shopify, estratto conto e ordini (<a class="lnk" href="console.html#incassi">Console → Incassi</a>).'],
    ['marketing', 'Marketing', ['mkt'], 'Usati dal bot Marketing e dalle bozze dei contenuti.'],
    ['sicurezza', 'Sicurezza alimentare e DOP', ['food', 'dop'], 'Latte crudo o pastorizzato (attiva il CCP 2), laboratorio, consulenti, revisione del manuale e tariffe DOP. Regole complete nel <a class="lnk" href="haccp.html">Manuale di Autocontrollo</a>.'],
    ['utenze', 'Utenze e reflui', ['energy', 'effluent'], 'Tariffe da bolletta (entrano nel costo pieno al kg e nel pacchetto mensile) e stime dei reflui per giorno di produzione, confrontate con il registro 💧 Reflui del tablet.'],
    ['lavoro', 'Lavoro', ['labor'], 'Costo orario e regole per ore e straordinari (<a class="lnk" href="console.html#personale">Console → Personale</a>).'],
    ['benchmark', 'Benchmark economici', ['opex', 'benchmark'], 'Usati dal brief settimanale finché non arriva la contabilità reale.'],
    ['prova', 'Settimana di prova', ['trial'], 'Imposta la data di inizio per far partire il bot della settimana di prova; vuota = nessuna prova in corso.'],
    ['sistema', 'Sistema', ['infra', 'auth', 'scale'], 'Indirizzi e versioni controllati dal monitor esterno, durata dei link di invito, bilancia. Da toccare solo se sai perché.'],
  ];
  const SEC_OF = Object.fromEntries(SECTIONS.flatMap(([id, , g]) => g.map(p => [p, id])));
  // keys that are ids, tokens or addresses: folded under "Impostazioni tecniche" at the end of their section
  const TECH = new Set(['shopify.sync_url', 'milk.farm_token', 'milk.farm_supplier_id', 'trade.shopify_market_id', 'trade.shopify_catalog_id', 'trade.shopify_price_list_id', 'trade.edge_url', 'trade.job_secret', 'trade.store_url',
    'mkt.ai_provider', 'mkt.predis_brand_id', 'mkt.output_language', 'sales.whey_sku_regex', 'infra.sw_seen']);
  // v1.03 (audit C-05): the secret keys no longer reach the browser at all (the database hides them); kept masked should one ever show
  const SECRET = new Set(['trade.job_secret', 'milk.farm_token', 'milk.farm_ship_token']);
  const READONLY = new Set(['infra.sw_seen']);   // written by the system, shown as text
  const canEdit = () => PERM.can('sistema', 3);
  let PROWS = [], pendingSection = null, curSec = null;
  const secOf = r => SEC_OF[r.key.split('.')[0]] || 'altro';
  // field kind: settings.kind (v0.84b: flag / date / month) or data_type; the old description hints remain a fallback
  const kindOf = r => {
    if (r.kind) return r.kind;
    const d = r.description || '';
    if (r.data_type === 'number' && /\(1\s*=\s*s[iì]/i.test(d)) return 'flag';
    if (r.data_type === 'number') return 'number';
    if (/AAAA-MM-01/.test(d)) return 'month';
    if (/AAAA-MM-GG/.test(d)) return 'date';
    return 'text';
  };
  // what still needs a hand: an empty value where empty is not a documented choice ("Vuoto = …"), or a value the description
  // itself calls provisional (da confermare, STIMA, ipotesi, da sostituire). Shown as a small tag on the row and counted per section.
  const attOf = r => {
    const d = r.description || '', v = String(r.value ?? '').trim();
    if (!v) return /vuot[oa]\s*=|vuote\b/i.test(d) || READONLY.has(r.key) ? '' : 'da compilare';
    return /da confermare|\bSTIMA\b|\bipotesi\b|da sostituire/i.test(d) ? 'da confermare' : '';
  };
  // v0.93 (audit C-01): number settings are shown with the decimal comma ("0,044"), so retyping what is on screen can never be read as thousands
  const itNum = v => v === '' || v == null || !Number.isFinite(Number(v)) ? String(v ?? '') : String(v).trim().replace('.', ',');
  const WDAYS = ['lun', 'mar', 'mer', 'gio', 'ven', 'sab', 'dom'];
  const shown = (r, v) => { const k = kindOf(r); if (v === '' || v == null) return 'vuoto'; if (k === 'flag') return Number(v) === 1 ? 'sì' : 'no'; if (k === 'date') return fmtD(v);
    if (k === 'choice') return ((r.options || []).find(o => o.v === String(v)) || {}).l || v;
    if (k === 'weekdays') return String(v).split(',').map(x => WDAYS[Number(x) - 1] || x).join(' '); if (k === 'number') return itNum(v) + (r.unit ? ' ' + r.unit : ''); return SECRET.has(r.key) ? '••••' : v; };
  // v0.98 (audit C-02): the range a number setting accepts (the database refuses anything outside it)
  const rangeOf = r => r.min_value == null && r.max_value == null ? '' : `da ${r.min_value == null ? '…' : itNum(r.min_value)} a ${r.max_value == null ? '…' : itNum(r.max_value)}${r.unit ? ' ' + r.unit : ''}`;
  const outOfRange = r => { const n = Number(r.value); return (r.min_value != null && n < Number(r.min_value)) || (r.max_value != null && n > Number(r.max_value)); };
  async function loadParams() {
    const { data, error } = await sb.from('settings').select('*').order('key');
    if (error) { $('p-secs').innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    PROWS = (data || []).map(r => ({ ...r, orig: r.value ?? '' }));
    if (!curSec) curSec = pendingSection || 'azienda'; pendingSection = null;
    renderParams();
  }
  const allSections = () => {
    const extra = [...new Set(PROWS.map(r => r.key.split('.')[0]).filter(p => !SEC_OF[p]))];
    return [...SECTIONS, ...(extra.length ? [['altro', 'Altri parametri', extra, 'Parametri senza una sezione dedicata (nuovi o tecnici).']] : [])];
  };
  const rowsOf = (groups) => PROWS.filter(r => groups.includes(r.key.split('.')[0])).sort((a, b) => groups.indexOf(a.key.split('.')[0]) - groups.indexOf(b.key.split('.')[0]) || (a.sort ?? 100) - (b.sort ?? 100) || a.key.localeCompare(b.key));
  const isDirty = r => String(r.value) !== String(r.orig) && !(kindOf(r) === 'number' && r.value !== '' && Number(r.value) === Number(r.orig));
  // one section on screen (curSec); with a search, every matching row of every section, each under its heading
  function renderParams() {
    const edit = canEdit(); $('p-ro').hidden = edit;
    const q = $('p-q').value.trim().toLowerCase(), secs = allSections();
    if (!secs.some(s => s[0] === curSec)) curSec = secs[0][0];
    const host = $('p-secs'); host.innerHTML = ''; let any = false;
    secs.forEach(([id, title, groups, hint]) => {
      const mine = rowsOf(groups); if (!mine.length) return;
      const hit = r => !q || [r.key, r.description, SECRET.has(r.key) ? '' : r.value, title].some(x => String(x || '').toLowerCase().includes(q));
      const vis = q ? mine.filter(hit) : (id === curSec ? mine : []);
      if (!vis.length) return; any = true;
      const att = mine.filter(r => attOf(r)).length;
      const card = document.createElement('div'); card.className = 'card psec'; card.id = 'sec-' + id; card.dataset.title = title;
      card.innerHTML = `<h3>${esc(title)}${att ? `<span class="st wn">${plural(att, 'parametro da sistemare', 'parametri da sistemare')}</span>` : q ? '' : '<span class="st">tutto compilato</span>'}</h3>${q ? '' : `<div class="hint">${hint}</div>`}`;
      const plain = vis.filter(r => !TECH.has(r.key)), tech = vis.filter(r => TECH.has(r.key));
      plain.forEach(r => card.append(paramRow(r, edit)));
      if (tech.length) {
        const d = document.createElement('details'); d.className = 'tech'; d.open = !!q || tech.some(isDirty);
        d.innerHTML = `<summary><span>Impostazioni tecniche · ${tech.length}</span></summary><div class="hint">Chiavi, indirizzi e identificativi usati dal sistema: di norma non si toccano.</div>`;
        tech.forEach(r => d.append(paramRow(r, edit)));
        card.append(d);
      }
      host.append(card);
    });
    $('p-none').hidden = any;
    renderNav(secs); saveState();
  }
  function renderNav(secs) {
    const q = $('p-q').value.trim(), nav = $('p-nav');
    nav.innerHTML = secs.map(([id, title, groups]) => { const rows = rowsOf(groups); if (!rows.length) return '';
      const att = rows.filter(r => attOf(r)).length, d = rows.filter(isDirty).length;
      return `<a href="#${id}" data-sec="${id}" class="${!q && id === curSec ? 'on' : ''}" title="${esc(title)}${att ? ` · ${plural(att, 'parametro da sistemare', 'parametri da sistemare')}` : ''}"><span class="t">${esc(title)}</span>${d ? `<span class="d" title="modifiche non salvate">${d}</span>` : ''}${att ? `<span class="n">${att}</span>` : ''}</a>`; }).join('');
    nav.querySelectorAll('a').forEach(a => a.onclick = e => { e.preventDefault(); showSection(a.dataset.sec); });
    const on = nav.querySelector('a.on'); if (on && nav.scrollWidth > nav.clientWidth + 2) on.scrollIntoView({ inline: 'center', block: 'nearest' });
  }
  function showSection(id) {
    curSec = id; $('p-q').value = ''; renderParams();
    try { history.replaceState(null, '', '#' + id); } catch {}
    const top = $('p-secs').getBoundingClientRect().top + window.scrollY - 120; if (window.scrollY > top) window.scrollTo({ top, behavior: 'smooth' });
  }
  // v0.60: month settings typed as MM/AAAA (browsers without a month picker) become AAAA-MM-01, not "11/2026-01"
  const monthVal = v => { const t = String(v || '').trim(); if (!t) return ''; let m = t.match(/^(\d{4})-(\d{1,2})/); if (m) return `${m[1]}-${m[2].padStart(2, '0')}-01`; m = t.match(/^(\d{1,2})[\/.-](\d{4})$/); return m ? `${m[2]}-${m[1].padStart(2, '0')}-01` : t; };
  function paramRow(r, edit) {
    const k = kindOf(r), att = attOf(r), row = document.createElement('div'); row.className = 'set-row' + (k === 'text' ? ' text' : '') + (att ? ' att' + (att === 'da compilare' ? ' att-empty' : '') : ''); row.dataset.key = r.key; if (att) row.dataset.att = att;
    row.innerHTML = `<div class="lbl"${att ? ` data-att="${att}"` : ''}>${esc(r.description || r.key)}${k === 'number' && rangeOf(r) ? `<small class="rng">possibile ${esc(rangeOf(r))}</small>` : ''}${r.impact_it ? '<small class="imp" title="' + esc(r.impact_it) + '">cambia il comportamento per tutti</small>' : ''}<span class="was" hidden></span></div>`; row.title = r.key;
    const right = document.createElement('div'); right.className = 'row'; right.style.marginTop = '0'; row.append(right);
    if (READONLY.has(r.key)) { const t = document.createElement('div'); t.className = 'ro'; t.textContent = r.value || '—'; right.append(t); return row; }
    if (k === 'weekdays') {          // v0.95 (audit C-04): seven boxes instead of a "1,2,3,4,5,6" text that could silently empty the delivery days
      const box = document.createElement('span'); box.className = 'wdays'; box.style.cssText = 'display:flex;flex-wrap:wrap;gap:4px 12px';
      const on = new Set(String(r.value || '').split(',').map(x => x.trim()));
      WDAYS.forEach((t, i) => { const l = document.createElement('label'); l.style.cssText = 'display:inline-flex;align-items:center;gap:4px;font-size:.95rem;text-transform:none;margin:0';
        const c = document.createElement('input'); c.type = 'checkbox'; c.value = String(i + 1); c.checked = on.has(String(i + 1)); c.disabled = !edit; l.append(c, t); box.append(l); });
      box.onchange = () => { r.value = [...box.querySelectorAll('input:checked')].map(c => c.value).join(','); const dirty = isDirty(r);
        row.classList.toggle('dirty', dirty); const w = row.querySelector('.was'); w.hidden = !dirty; w.textContent = 'prima: ' + shown(r, r.orig); saveState(); };
      right.append(box); return row;
    }
    let inp;
    if (k === 'flag') { inp = document.createElement('select'); inp.innerHTML = '<option value="1">Sì</option><option value="0">No</option>'; inp.value = Number(r.value) === 1 ? '1' : '0'; }
    else if (k === 'choice') { inp = document.createElement('select'); inp.innerHTML = (r.options || []).map(o => `<option value="${esc(o.v)}">${esc(o.l)}</option>`).join(''); inp.value = r.value; }   // v0.98 (audit C-03): a list, never free text
    else { inp = document.createElement('input'); inp.type = k === 'date' ? 'date' : k === 'month' ? 'month' : k === 'time' ? 'time' : SECRET.has(r.key) ? 'password' : 'text';
      inp.value = k === 'month' ? String(r.value || '').slice(0, 7) : k === 'number' ? itNum(r.value) : (r.value ?? '');
      if (k === 'number') { inp.inputMode = 'decimal'; inp.style.textAlign = 'right'; }
      if (k === 'text') { inp.className = 'wide'; inp.placeholder = '—'; }
      if (SECRET.has(r.key)) inp.autocomplete = 'off'; }
    inp.disabled = !edit; inp.setAttribute('aria-label', r.description || r.key);
    const val = () => k === 'month' ? monthVal(inp.value) : k === 'number' ? (inp.value.trim() === '' ? '' : String(UI.parseIt(inp.value))) : inp.value.trim();   // v0.60: 1.300 = 1300; "11/2026" = 2026-11
    const sync = () => { r.value = val(); const dirty = isDirty(r);
      row.classList.toggle('dirty', dirty); const w = row.querySelector('.was'); w.hidden = !dirty; w.textContent = 'prima: ' + shown(r, r.orig); saveState(); };
    inp.oninput = sync; inp.onchange = sync;
    inp.onkeydown = e => { if (e.key === 'Enter') { e.preventDefault(); saveParams().catch(err => toast(err.message || String(err), 'err')); } if (e.key === 'Escape') { inp.value = k === 'month' ? String(r.orig).slice(0, 7) : k === 'flag' ? (Number(r.orig) === 1 ? '1' : '0') : k === 'number' ? itNum(r.orig) : r.orig; sync(); r.value = r.orig; row.classList.remove('dirty'); row.querySelector('.was').hidden = true; saveState(); } };
    right.append(inp);
    if (k === 'number' && r.unit) { const u = document.createElement('span'); u.className = 'unit'; u.textContent = r.unit; right.append(u); }   // v0.98 (audit C-02)
    if (SECRET.has(r.key)) { const b = document.createElement('button'); b.type = 'button'; b.className = 'eye'; b.textContent = 'mostra'; b.onclick = () => { const on = inp.type === 'password'; inp.type = on ? 'text' : 'password'; b.textContent = on ? 'nascondi' : 'mostra'; }; right.append(b); }
    return row;
  }
  function saveState() {
    const dirty = PROWS.filter(isDirty);
    $('p-save').hidden = !dirty.length; $('p-save-n').textContent = dirty.length === 1 ? '1 modifica non salvata' : `${dirty.length} modifiche non salvate`;
    badge('n-par', dirty.length);
    document.querySelectorAll('#p-nav a').forEach(a => { const sec = allSections().find(s => s[0] === a.dataset.sec); const n = sec ? rowsOf(sec[2]).filter(isDirty).length : 0; let d = a.querySelector('.d');
      if (n && !d) { d = document.createElement('span'); d.className = 'd'; d.title = 'modifiche non salvate'; a.querySelector('.t').after(d); } if (d) { d.textContent = n; d.hidden = !n; } });
    return dirty;
  }
  async function saveParams() {
    const dirty = saveState(); if (!dirty.length) return;
    for (const r of dirty) {
      const k = kindOf(r);
      if (k === 'number' && (r.value === '' || isNaN(Number(r.value)))) { focusRow(r.key); throw new Error(`"${r.description || r.key}": inserisci un numero`); }
      if (k === 'number' && outOfRange(r)) { focusRow(r.key); throw new Error(`"${r.description || r.key}": ${itNum(r.value)}${r.unit ? ' ' + r.unit : ''} non è possibile, scrivi un valore ${rangeOf(r)}. Controlla la virgola.`); }
      if ((k === 'date' || k === 'month') && r.value && !/^\d{4}-\d{2}-\d{2}$/.test(r.value)) { focusRow(r.key); throw new Error(`"${r.description || r.key}": data non valida`); }
      if (k === 'time' && !/^([01]\d|2[0-3]):[0-5]\d$/.test(r.value)) { focusRow(r.key); throw new Error(`"${r.description || r.key}": scrivi l'ora, es. 18:00`); }
      if (k === 'weekdays' && !r.value) { focusRow(r.key); throw new Error(`"${r.description || r.key}": scegli almeno un giorno`); }
    }
    // v0.93 (audit C-01/C-02): a number that changes 10× or more is almost always a comma/dot slip: say it before saving
    const jumps = dirty.filter(r => kindOf(r) === 'number' && UI.jump(r.orig, r.value));
    if (jumps.length && !confirm('Controlla questi valori: cambiano di 10 volte o più.\n\n' +
        jumps.map(r => `${r.description || r.key}: ${itNum(r.orig)} → ${itNum(Number(r.value))}`).join('\n') +
        '\n\nI decimali si scrivono con la virgola (0,044). Salvare comunque?')) { focusRow(jumps[0].key); return; }
    // v0.98 (audit C-02): a setting that changes behaviour for everyone says what it does before it is saved (and goes to the bell after)
    const imp = dirty.filter(r => r.impact_it);
    if (imp.length && !confirm('Questi parametri cambiano il comportamento per tutti:\n\n' +
        imp.map(r => `${r.description || r.key}: ${shown(r, r.orig)} → ${shown(r, kindOf(r) === 'number' ? Number(r.value) : r.value)}\n   ${r.impact_it}`).join('\n\n') +
        '\n\nLa modifica arriva come avviso nella campanella, con il tuo nome. Salvare?')) { focusRow(imp[0].key); return; }
    const res = await Promise.all(dirty.map(r => { const v = kindOf(r) === 'number' ? String(Number(r.value)) : r.value; return sb.from('settings').update({ value: v }).eq('key', r.key).select('key').then(x => ({ r, v, ...x })); }));
    const bad = res.filter(x => x.error || !(x.data || []).length);
    res.filter(x => !x.error && (x.data || []).length).forEach(({ r, v }) => { r.orig = v; r.value = v; if (r.key.startsWith('company.')) BRAND.set({ [r.key]: v }); });
    renderParams(); ovStale = true;
    if (bad.length) throw new Error(`${bad.length} non salvati: ${bad[0].error ? bad[0].error.message : 'permesso negato'} (${bad.map(x => x.r.description || x.r.key).join(', ')})`);
    toast(res.length === 1 ? 'Parametro salvato' : `${res.length} parametri salvati`);
  }
  // a row that is not on screen (other section) is shown first, then focused
  const focusRow = key => { const r = PROWS.find(x => x.key === key); if (r && !$('p-q').value.trim() && secOf(r) !== curSec) { curSec = secOf(r); renderParams(); }
    const row = document.querySelector(`.set-row[data-key="${CSS.escape(key)}"]`); if (row) { const t = row.closest('details.tech'); if (t) t.open = true; row.scrollIntoView({ block: 'center' }); const i = row.querySelector('input, select'); if (i) i.focus(); } };
  let qT = null;
  $('p-q').oninput = () => { clearTimeout(qT); qT = setTimeout(renderParams, 120); };
  $('p-q').onkeydown = e => { if (e.key === 'Escape') { $('p-q').value = ''; renderParams(); } };
  $('p-go').onclick = () => UI.act($('p-go'), saveParams);
  $('p-undo').onclick = () => { PROWS.forEach(r => { r.value = r.orig; }); renderParams(); };
  window.addEventListener('beforeunload', e => { if (PROWS.some(r => String(r.value) !== String(r.orig))) { e.preventDefault(); e.returnValue = ''; } });

  // ---------- Macchine e scadenze ----------
  // status strip on top: late, due within 30 days, without dates — each number is what the Panoramica card shows too
  const maintStatus = (eq, dl) => {
    const today = UI.romeISO(), soon = UI.romeISO(new Date(Date.now() + 30 * 864e5));
    const items = [];
    (eq || []).filter(x => x.active).forEach(x => {
      const nc = x.next_calibration_on, nm = x.next_maintenance_on;
      if (!nc && !nm) return items.push({ st: 'unset', when: null, txt: `${x.name}: date da impostare`, id: x.id });
      [['taratura', nc], ['manutenzione', nm]].forEach(([w, d]) => { if (!d) return; const st = d < today ? 'late' : d <= soon ? 'soon' : 'ok';
        items.push({ st, when: d, txt: `${x.name}: ${w} ${d < today ? 'scaduta il' : 'entro il'} ${fmtD(d)}`, id: x.id }); });
    });
    (dl || []).forEach(x => { if (!x.due_on) return items.push({ st: 'unset', when: null, txt: `${x.subject_it}: data da impostare`, id: x.id });
      const st = x.due_on < today ? 'late' : x.due_on <= soon ? 'soon' : 'ok'; items.push({ st, when: x.due_on, txt: `${x.subject_it}: ${x.due_on < today ? 'scaduta il' : 'scade il'} ${fmtD(x.due_on)}`, id: x.id }); });
    const n = k => items.filter(i => i.st === k).length;
    const order = { late: 0, soon: 1, unset: 2, ok: 3 };
    items.sort((a, b) => order[a.st] - order[b.st] || String(a.when || '9').localeCompare(String(b.when || '9')));
    return { late: n('late'), soon: n('soon'), unset: n('unset'), items };
  };
  let MAINT = null;
  async function loadMaint() {
    const [e, d] = await Promise.all([sb.from('v_equipment_schedule').select('*'), sb.from('compliance_deadlines').select('*').is('done_on', null).order('due_on', { nullsFirst: false })]);
    if (e.error || d.error) { toast((e.error || d.error).message, 'err'); return; }
    MAINT = maintStatus(e.data, d.data);
    $('maint-sum').innerHTML = `
      <div class="sm s-al${MAINT.late ? '' : ' zero'}"><b>${MAINT.late}</b><span>già scadute</span></div>
      <div class="sm s-wn${MAINT.soon ? '' : ' zero'}"><b>${MAINT.soon}</b><span>entro 30 giorni</span></div>
      <div class="sm${MAINT.unset ? ' s-wn' : ' zero'}"><b>${MAINT.unset}</b><span>senza data</span></div>
      <div class="sm s-ok"><b>${(e.data || []).filter(x => x.active).length}</b><span>macchine attive · ${plural((d.data || []).length, 'scadenza aperta', 'scadenze aperte')}</span></div>`;
    renderEquipment(e.data || []); renderDeadlines(d.data || []);
    badge('n-maint', MAINT.late); $('n-maint').title = 'scadenze o tarature già passate';
  }
  // ---------- Bot dashboard: every bot notification (v1.00: v_bot_feed — read per person, «Risolto» with a note, a link to act) ----------
  let bdFilter = 'unread', bdAgent = null, bdLimit = 50, bdNames = {}, bdNick = {};
  // v0.46 display-only nicknames (Zio/Zia) from bot_nicknames; agent keys never change. v1.00 (E-13): what the bot does comes first,
  // the nickname after; what the database writes by itself (Sicurezza alimentare, Turni, Tablet…) has no nickname.
  async function loadNicknames() { const { data } = await sb.from('bot_nicknames').select('agent, nickname, title_it, avatar_url'); (data || []).forEach(n => { bdNick[n.agent] = n; }); }
  // avatar slot: image when bot_nicknames.avatar_url is set, otherwise a dashed circle with the initial
  const botAvatar = agent => { const n = bdNick[agent]; if (n && n.avatar_url) return `<div class="bav img" aria-hidden="true"><img src="${esc(n.avatar_url)}" alt="" loading="lazy"></div>`;
    const w = String(n ? (n.nickname || n.title_it || agent) : agent).replace(/^(zio|zia)\s+/i, '').trim(); return `<div class="bav" aria-hidden="true">${esc((w[0] || '?').toUpperCase())}</div>`; };
  const botTitle = agent => (bdNick[agent] && bdNick[agent].title_it) || agent;
  const botLabel = (agent, base) => { const n = bdNick[agent], t = base || botTitle(agent); return n && n.nickname ? `${t} · ${n.nickname}` : t; };
  // v1.00 (E-21): the bots the database can stand in for (fabula.bot_fallback_agents()) — «Esegui ora» runs that version now
  const RUN_NOW = {
    milk_planning: 'Prepara la proposta del piano latte di domani (da approvare in Console → Oggi).',
    procurement: 'Controlla le scorte e prepara gli ordini ai fornitori (sopra la soglia restano da approvare).',
    wholesale_orders: 'Conferma gli ordini fissi dei clienti ingrosso per domani.',
    haccp_nudge: 'Prepara l\'elenco serale delle registrazioni HACCP che mancano (compare anche sul tablet).',
    ops_health: 'Fa il controllo serale del sistema e ne scrive il riepilogo.',
    sell_down: 'Prepara la proposta di promozione dei prodotti da vendere prima (da approvare).',
    backup_export: 'Avvia subito il backup completo del database (quello della notte).',
    // v1.02 (E-18): the Shopify jobs run in the database itself; «Esegui ora» starts them now
    shopify_orders: 'Copia subito da Shopify gli ordini online e del banco degli ultimi giorni e conferma su Shopify le spedizioni imballate.',
    shopify_customers: 'Copia subito da Shopify l\'elenco completo dei clienti (non disattiva nessuno se ne mancano troppi).',
    shopify_inventory: 'Confronta subito le giacenze con Shopify (e le aggiorna, se l\'aggiornamento è acceso).' };
  // jobs the database runs by itself (bot_schedule.runner = 'db'): no Claude task behind them
  const DBJOB = new Set(['shopify_orders', 'shopify_customers', 'shopify_inventory', 'backup_export']);
  // a message's button only opens a page of the app (the same rule as fabula.safe_link in the database)
  const LINK_OK = /^(index|console|haccp|admin|ingrosso|vendite|marketing|latte|consorzio|labels|registro)\.html(#[A-Za-z0-9=&:._-]{0,120})?$/;
  // Bot dashboard redesign (03/10): status summary on top, bots grouped by status (da sistemare → da controllare → in ordine → disattivati),
  // one card per bot, plain-language times ("3 ore fa", "domani 06:05"). These cards are the senders that are not scheduled bots.
  // v1.00 (E-33): the hourly check runs in the database at :25 (one alarm per bot that stopped); Claude's check at :50 is the spare
  const SYS = { bot_watchdog: { agents: ['bot_watchdog', 'bot_heartbeat'], role: 'Allarme bot', sched: 'ogni ora · :25 dal database (e :50, controllo di Claude)', times: Array.from({ length: 24 }, (_, i) => String(i).padStart(2, '0') + ':25'), wd: [1, 2, 3, 4, 5, 6, 7], okLine: 'Tutti i bot sono partiti' },
                avvisi: { agents: ['avvisi'], role: 'Avvisi della console', sched: 'quando si apre un avviso', times: [], wd: [], okLine: 'Nessun avviso aperto' },
                sicurezza: { agents: ['sicurezza'], role: 'Sicurezza alimentare', sched: 'quando un lotto, il latte o una registrazione HACCP non va', times: [], wd: [], okLine: 'Nessun allarme di sicurezza alimentare' },   // v1.00 (E-13)
                produzione: { agents: ['produzione'], role: 'Resa e lotti aperti', sched: 'alla chiusura di ogni lotto · controllo serale 19:45', times: [], wd: [], okLine: 'Nessuna resa fuori norma' },   // v0.70
                auto_approve: { agents: ['auto_approve'], role: 'Approvazioni automatiche', sched: 'ogni 10 minuti', times: [], wd: [], okLine: 'Nessuna approvazione automatica da leggere' },   // v0.73
                turni: { agents: ['turni'], role: 'Turni', sched: 'il sabato mattina copia i turni della settimana dopo', times: [], wd: [], okLine: 'Turni a posto' },   // v1.00
                tablet: { agents: ['tablet'], role: 'Tablet', sched: 'a ogni contatto del tablet · controllo ogni 15 minuti', times: [], wd: [], okLine: 'Tablet aggiornati, nessuna registrazione in attesa' },   // v0.74
                masseria: { agents: ['masseria'], role: 'Masseria', sched: 'quando la masseria corregge un carico di latte', times: [], wd: [], okLine: 'Nessuna correzione dalla masseria' },
                configurazione: { agents: ['configurazione'], role: 'Configurazione', sched: 'quando cambia un\'impostazione che pesa sul lavoro', times: [], wd: [], okLine: 'Nessuna impostazione cambiata di recente' },
                prova: { agents: ['prova'], role: 'Settimana di prova', sched: 'ogni sera alle 20:35 durante la settimana di prova', times: [], wd: [], okLine: 'Nessuna prova in corso' } };   // v0.77
  const DOW = ['dom', 'lun', 'mar', 'mer', 'gio', 'ven', 'sab'];
  const romeNow = () => { const p = Object.fromEntries(new Intl.DateTimeFormat('en-GB', { timeZone: 'Europe/Rome', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false }).formatToParts(new Date()).map(x => [x.type, x.value]));
    return { y: +p.year, mo: +p.month, d: +p.day, hm: `${p.hour === '24' ? '00' : p.hour}:${p.minute}` }; };
  const nextRun = (times, wd, md) => { if (!times || !times.length) return null; const n = romeNow(), ts = times.map(t => t.slice(0, 5)).sort();
    for (let k = 0; k < 40; k++) { const dt = new Date(Date.UTC(n.y, n.mo - 1, n.d + k)), iso = dt.getUTCDay() || 7;
      if (md ? dt.getUTCDate() !== md : wd && wd.length && !wd.includes(iso)) continue;
      const t = ts.find(x => k > 0 || x > n.hm); if (!t) continue;
      const day = k === 0 ? 'oggi' : k === 1 ? 'domani' : `${DOW[dt.getUTCDay()]} ${String(dt.getUTCDate()).padStart(2, '0')}/${String(dt.getUTCMonth() + 1).padStart(2, '0')}`;
      return { label: `${day} ${t}`, key: k * 1440 + (+t.slice(0, 2)) * 60 + (+t.slice(3)) }; }
    return null; };
  const schedTxt = (times, wd, md) => { const t = (times || []).map(x => x.slice(0, 5)).join(', ');
    const days = md ? `il ${md} del mese` : !wd || wd.length >= 7 ? 'ogni giorno' : wd.join() === '1,2,3,4,5,6' ? 'lun–sab' : wd.map(d => DOW[d % 7]).join(', ');
    return `${days} · ${t}`; };
  const ago = s => { const m = Math.round((Date.now() - new Date(s)) / 60000); if (m < 1) return 'adesso'; if (m < 60) return `${m} min fa`;
    const h = Math.round(m / 60); if (h < 24) return h === 1 ? '1 ora fa' : `${h} ore fa`; const d = Math.round(h / 24); return d === 1 ? 'ieri' : `${d} giorni fa`; };
  // one readable line: no leading icons, no long English translations in brackets, nothing after an arrow (file paths)
  const cleanTxt = s => String(s || '').replace(/^[\s⛔⚠✅ℹ️•·\-–—:]+/u, '').replace(/\s*\([^()]{30,}\)/g, '').split(/\s(?:→|->)\s?/)[0].replace(/\s+/g, ' ').trim();
  const ST = { al: ['Allarme', 'Da sistemare'], wn: ['Da controllare', 'Da controllare'], ok: ['In ordine', 'In ordine'], new: ['Mai eseguito', 'In attesa della prima esecuzione'], off: ['Disattivato', 'Disattivati'] };
  // ---------- notification text helpers: Italian only by default, light markdown, no repeated "bot · date" header ----------
  let bdEn = false, bdRole = {};
  // English detection for the bots' "Italiano (English)" habit: brackets with an English word and no Italian word are the translation
  const EN_W = new Set(('the is are was were and to of no nothing not with from for by on at this that today yet all check checks it its be been has have an as or so please will would should any only stay stays '
    + 'evening temperature sanitation meter reading logged missing overdue tasks since thermometer production declaration proposed est cost confirmed orders order demand output mismatch approving approve reject '
    + 'customer customers suppliers supplier rename placeholder names recorded scans working day off offline fix first connected booked include them phones tap item record shows list red yield available '
    + 'averages sales yesterday week weeks average close history hand assumed measured last same waste system ran errors error new updated read deactivated wholesale adopted next sync what when where how').split(' '));
  const IT_W = new Set('il lo la le gli di del della dei delle che è e per non nessun nessuna nessuno sono da con oggi ancora alla al nel nella una un più già prima resta restano dal sul o senza'.split(' '));
  const wordsOf = s => String(s).toLowerCase().match(/[a-zà-ù']+/g) || [];
  const isEn = s => { let en = 0, it = 0; wordsOf(s).forEach(x => { if (EN_W.has(x)) en++; if (IT_W.has(x)) it++; }); return en >= 2 && en > it * 1.5; };
  const isEnBracket = s => { let en = 0, it = 0; wordsOf(s).forEach(x => { if (EN_W.has(x)) en++; if (IT_W.has(x)) it++; }); return it === 0 ? en >= 1 : en >= 2 && en > it * 1.5; };
  const dropEn = t => {
    let s = String(t || '').replace(/\r/g, '');
    s = s.replace(/\s*\((?:[^()]|\([^()]*\))*\)/g, m => m.includes('\n') && isEn(m) ? '' : m);   // multi-line translation in brackets
    return s.split('\n').filter(l => !/^\s*(EN|English)\s*[—:–-]/i.test(l))
      .map(l => l.replace(/^\s*IT\s*[—:–-]\s*/, '').replace(/\s*\(((?:[^()]|\([^()]*\))*)\)/g, (m, inner) => { const sl = inner.split(' / '); if (sl.length === 2 && isEnBracket(sl[1]) && !isEnBracket(sl[0])) return ` (${sl[0]})`; return isEnBracket(inner) ? '' : m; }))
      .filter(l => !(l.trim() && isEn(l))).join('\n');
  };
  const MONTHS = /(\d{1,2}[\/ ]\d{0,2}|gennaio|febbraio|marzo|aprile|maggio|giugno|luglio|agosto|settembre|ottobre|novembre|dicembre)/i;
  const mdLite = t => {
    const lines = String(t || '').split('\n').map(l => l.trimEnd());
    while (lines.length && !lines[0].trim()) lines.shift();
    if (lines.length && lines[0].length < 90 && / · /.test(lines[0]) && MONTHS.test(lines[0]) && !/^\s*[-•*]\s/.test(lines[0])) lines.shift();
    const inl = s => esc(s).replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
    let html = '', list = false;
    for (const l of lines) {
      const li = l.match(/^\s*(?:[-•*]|\d+[.)])\s+(.*)$/);
      if (li) { if (!list) { html += '<ul>'; list = true; } html += `<li>${inl(li[1])}</li>`; continue; }
      if (list) { html += '</ul>'; list = false; }
      if (!l.trim()) continue;
      const q = l.match(/^\s*>\s?(.*)$/);
      html += q ? `<blockquote>${inl(q[1])}</blockquote>` : `<p>${inl(l)}</p>`;
    }
    return list ? html + '</ul>' : html;
  };
  const plainTxt = h => String(h).replace(/<[^>]+>/g, ' ').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&amp;/g, '&').replace(/\s+/g, ' ').trim();
  const romeDay = s => new Date(s).toLocaleDateString('sv-SE', { timeZone: 'Europe/Rome' });
  const hmRome = s => new Date(s).toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Rome' });
  const dayLabel = d => { if (d === romeDay(Date.now())) return 'Oggi'; if (d === romeDay(Date.now() - 864e5)) return 'Ieri';
    return new Date(d + 'T12:00:00').toLocaleDateString('it-IT', { weekday: 'long', day: 'numeric', month: 'long' }); };
  const whenIt = s => { const d = romeDay(s); return d === romeDay(Date.now()) ? `alle ${hmRome(s)}` : `il ${new Date(s).toLocaleDateString('it-IT', { day: '2-digit', month: '2-digit', timeZone: 'Europe/Rome' })} alle ${hmRome(s)}`; };
  async function loadBotFeed() {
    const [{ data: bots }, bell, { data: sysMsgs }] = await Promise.all([
      sb.from('v_bot_dashboard').select('*').order('name_it'),
      sb.rpc('bot_bell'),
      sb.from('v_bot_feed').select('agent, title, severity, created_at, read_at, for_me').in('agent', Object.values(SYS).flatMap(x => x.agents)).order('created_at', { ascending: false }).limit(300),
      loadNicknames()]);
    const B = bell.data || {}, nAl = Number(B.alerts) || 0, nU = Number(B.unread) || 0;
    UI.bellCount(); badge('n-bots', nAl);
    (bots || []).forEach(b => { bdRole[b.agent] = botTitle(b.agent) === b.agent ? b.name_it : botTitle(b.agent); bdNames[b.agent] = botLabel(b.agent, bdRole[b.agent]); });
    Object.entries(SYS).forEach(([a, x]) => { bdRole[a] = bdNick[a] ? bdNick[a].title_it : x.role; bdNames[a] = botLabel(a, bdRole[a]); });
    // one item per card: what it does first (E-13), the nickname under it
    const items = (bots || []).map(b => {
      const st = !b.active ? 'off' : (b.last_status === 'error' || b.unread_alerts > 0 || b.last_severity === 'alert') ? 'al' : b.last_severity === 'warn' ? 'wn' : !b.last_run_at ? 'new' : 'ok';
      const raw = (b.last_title || '').trim(), generic = !raw || [b.name_it, b.display_name, bdRole[b.agent]].some(x => x && (raw === x || raw.startsWith(x + ' · ')));
      return { agent: b.agent, nick: bdNick[b.agent] ? bdNick[b.agent].nickname || '' : '', role: bdRole[b.agent], st, err: b.active && b.last_status === 'error',
        sched: schedTxt(b.due_times, b.weekdays, b.month_day) + (DBJOB.has(b.agent) ? ' · dal database' : ''), next: b.active ? nextRun(b.due_times, b.weekdays, b.month_day) : null,
        last: b.last_run_at, line: cleanTxt(b.last_status === 'error' ? (b.last_summary || 'Ultima esecuzione fallita') : generic ? (b.last_summary || raw) : raw),
        unread: b.unread || 0, unreadAl: b.unread_alerts || 0, active: b.active, run: !!RUN_NOW[b.agent] };
    });
    Object.entries(SYS).forEach(([a, s]) => {
      const ms = (sysMsgs || []).filter(m => s.agents.includes(m.agent)), m = ms[0];
      const open = ms.filter(x => x.severity === 'alert' ? !x.read_at : x.for_me);
      const st = open.some(x => x.severity === 'alert') ? 'al' : open.some(x => x.severity === 'warn') ? 'wn' : 'ok';
      items.push({ agent: a, nick: bdNick[a] ? bdNick[a].nickname || '' : '', role: bdRole[a], st, sched: s.sched, next: nextRun(s.times, s.wd), last: m ? m.created_at : null, sys: true,
        line: open.length ? cleanTxt(open[0].title) : (s.okLine || 'Nessun allarme: tutti i bot sono regolari'), unread: open.length, unreadAl: open.filter(x => x.severity === 'alert').length, active: true });
    });
    // summary strip
    const c = k => items.filter(i => i.st === k).length;
    const nx = items.filter(i => i.next && !i.sys).sort((x, y) => x.next.key - y.next.key)[0];
    $('bd-sum').innerHTML = `
      <div class="sm s-al${c('al') ? '' : ' zero'}"><b>${c('al')}</b><span>da sistemare</span></div>
      <div class="sm s-wn${c('wn') ? '' : ' zero'}"><b>${c('wn')}</b><span>da controllare</span></div>
      <div class="sm s-ok"><b>${c('ok')}</b><span>in ordine</span></div>
      <div class="sm${nAl ? ' s-al' : ' zero'}"><b>${nAl}</b><span>${nAl === 1 ? 'allarme aperto' : 'allarmi aperti'}</span></div>
      <div class="sm"><b>${nU}</b><span>da leggere per te</span></div>
      ${nx ? `<div class="sm nx">${botAvatar(nx.agent)}<div><span>Prossimo bot</span><b>${esc(nx.role)}</b><span>${nx.nick ? esc(nx.nick) + ' · ' : ''}${esc(nx.next.label)}</span></div></div>` : ''}`;
    // cards grouped by status, each group ordered by next run
    // card: what it does, the nickname, one-line latest news, then when it last ran and when it runs next. Group heading + coloured edge carry the status.
    const when = i => i.active ? [i.last ? `Ultima: ${ago(i.last)}` : i.sys ? 'Nessun avviso finora' : 'Non ha ancora girato', i.next ? `Prossima: ${i.next.label}` : '']
      : ['Disattivato' + (i.last ? ` · ha girato ${ago(i.last)}` : '')];
    const card = i => `<div class="botc s-${i.st}${bdAgent === i.agent ? ' sel' : ''}" data-a="${esc(i.agent)}" role="button" tabindex="0" aria-pressed="${bdAgent === i.agent}" title="${esc(i.role)} · ${esc(i.sched)}">${botAvatar(i.agent)}
        <div class="bi"><div class="hd"><span class="nm">${esc(i.role)}</span>${i.err ? '<span class="pill s-al">Errore</span>' : ''}</div>
        ${i.nick ? `<div class="ti">${esc(i.nick)}</div>` : ''}
        <div class="bl">${esc(i.line || (i.st === 'new' ? 'Nessuna notizia: parte alla prossima esecuzione' : '—'))}</div>
        <div class="ft">${when(i).filter(Boolean).map(t => `<span>${esc(t)}</span>`).join('')}${i.run && PERM.can('sistema', 2) ? '<span>«Esegui ora» disponibile</span>' : ''}${i.unread ? `<span class="u${i.unreadAl ? ' al' : ''}">${i.unread} ${i.unreadAl ? (i.unreadAl === 1 ? 'allarme' : 'allarmi') : i.unread === 1 ? 'nuova' : 'nuove'}</span>` : ''}</div></div></div>`;
    const bb = $('bd-bots');
    bb.innerHTML = ['al', 'wn', 'ok', 'new', 'off'].map(k => { const g = items.filter(i => i.st === k).sort((x, y) => (x.next ? x.next.key : 1e9) - (y.next ? y.next.key : 1e9));
      return g.length ? `<div class="bd-grp s-${k}"><h4>${ST[k][1]} <span>${g.length}</span></h4><div class="bd-bots">${g.map(card).join('')}</div></div>` : ''; }).join('');
    const pick = el => { bdAgent = bdAgent === el.dataset.a ? null : el.dataset.a; bdLimit = 50; loadBotFeed(); if ($('runs-card').open) loadRuns(); if (bdAgent) $('bd-feed-card').scrollIntoView({ behavior: 'smooth', block: 'start' }); };
    bb.querySelectorAll('.botc').forEach(el => { el.onclick = () => pick(el); el.onkeydown = e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); pick(el); } }; });
    $('bd-bot').textContent = bdAgent ? 'Solo: ' + (bdNames[bdAgent] || bdAgent) : '';
    // «Esegui ora (versione del database)» for the selected bot, when the database can stand in for it (E-21)
    const rn = $('bd-run');
    if (bdAgent && RUN_NOW[bdAgent] && PERM.can('sistema', 2)) {
      rn.hidden = false;
      const sync = /^shopify_/.test(bdAgent);
      rn.innerHTML = `<div><b>${esc(bdRole[bdAgent] || bdAgent)} · Esegui ora${sync ? '' : ' (versione del database)'}</b><span>${esc(RUN_NOW[bdAgent])} ${sync ? 'Il risultato arriva qui entro un paio di minuti e resta registrato con il tuo nome.' : 'Usa i numeri del database, senza il commento del bot, e resta registrato con il tuo nome.'}</span></div><button class="btn sm" id="bd-run-go" type="button">Esegui ora</button>`;
      $('bd-run-go').onclick = () => runNow(bdAgent);
    } else { rn.hidden = true; rn.innerHTML = ''; }
    // the feed: for me / open alarms / everything
    let q = sb.from('v_bot_feed').select('id, agent, created_at, severity, title, body, notice_key, read_at, resolved_at, resolution, resolved_by, action_url, action_label, read_by_me, seen_by, for_me, has_basis')
      .order('created_at', { ascending: false }).limit(bdLimit + 1);
    if (bdFilter === 'unread') q = q.eq('for_me', true);
    if (bdFilter === 'alert') q = q.eq('severity', 'alert').is('read_at', null);
    if (bdAgent) q = q.in('agent', SYS[bdAgent] ? SYS[bdAgent].agents : [bdAgent]);
    const { data: msgs, error } = await q;
    const feed = $('bd-feed');
    if (error) { feed.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    $('bd-more').hidden = (msgs || []).length <= bdLimit;
    const rows = (msgs || []).slice(0, bdLimit);
    if (!rows.length) { feed.innerHTML = `<div class="empty">${bdFilter === 'unread' ? 'Niente da leggere per te.' : bdFilter === 'alert' ? 'Nessun allarme aperto.' : 'Nessuna notifica.'}</div>`; return; }
    // grouped by day; same bot + same title on the same day = one entry ("3 volte"); Italian only unless "Mostra inglese"
    const items2 = [], byKey = {};
    rows.forEach(m => {
      const day = romeDay(m.created_at), key = `${day}|${m.agent}|${m.title}|${m.resolved_at ? 'r' : ''}`;
      // mine: still to read for me (an open alarm stays «for me» until it closes: «Visto» goes once I have seen it); open: alarms still open
      const add = it => { if (m.severity === 'alert' && !m.read_at ? !m.read_by_me : m.for_me) it.mine.push(m.id); if (m.severity === 'alert' && !m.read_at) it.open.push(m.id); };
      if (byKey[key]) { const it = byKey[key]; it.n++; add(it); return; }
      const it = byKey[key] = { m, day, n: 1, mine: [], open: [] }; add(it); items2.push(it);
    });
    const canFix = PERM.can('sistema', 3);
    let lastDay = null;
    feed.innerHTML = items2.map(({ m, day, n, mine, open }) => {
      const a = m.agent, nk = bdNick[a], role = bdRole[a] || botTitle(a), nick = nk && nk.nickname;
      const generic = !m.title || [role, nk && nk.title_it, bdNames[a]].some(x => x && (m.title === x || m.title.startsWith(x + ' · ')));
      let body = mdLite(bdEn ? (m.body || '') : dropEn(m.body || '')), title = m.title || '';
      if (!bdEn) title = dropEn(title);
      if (generic) { const f = body.match(/^<(p|li)>(.*?)<\/\1>/) || body.match(/<(p|li)>(.*?)<\/\1>/);
        if (f) { title = plainTxt(f[2]); if (f[1] === 'p' && body.startsWith(f[0])) body = body.slice(f[0].length); } }
      title = title.replace(/^Oggi\s*[—–-]\s*/, '');
      const head = day !== lastDay ? `<div class="bd-day">${esc(dayLabel(day))}</div>` : ''; lastDay = day;
      const sv = m.severity === 'alert' ? `<span class="sv">${m.resolved_at ? 'Allarme risolto' : open.length ? 'Allarme aperto' : 'Allarme'}</span>` : m.severity === 'warn' ? '<span class="sv">Da controllare</span>' : '';
      const go = m.action_url && LINK_OK.test(m.action_url) ? `<a class="go" href="${esc(m.action_url)}">${esc(m.action_label || 'Apri')} →</a>` : '';
      const done = m.resolved_at ? `<div class="rs">✓ ${m.resolved_by ? `Risolto da ${esc(m.resolved_by)}` : 'Chiuso'} ${esc(whenIt(m.resolved_at))}${m.resolution ? ` · ${esc(m.resolution)}` : ''}</div>` : '';
      const seen = m.seen_by ? `<span class="seen">Visto da ${esc(m.seen_by.split(' · ').map(x => x.replace(/ \d\d\/\d\d \d\d:\d\d$/, '')).join(', '))}</span>` : '';
      const isOpenAl = open.length > 0, quiet = !mine.length && !isOpenAl;   // an open alarm never looks «read»
      return `${head}<div class="msg ${esc(m.severity)}${quiet ? ' read' : ''}" data-ids="${mine.join(',')}" data-open="${open.join(',')}">${botAvatar(a)}<div class="mb">
        <div class="hd"><span class="who"><b>${esc(role)}</b>${nick ? `<span class="role">${esc(nick)}</span>` : ''}</span><span class="tm">${hmRome(m.created_at)}${n > 1 ? ` · ${n} volte` : ''}</span></div>
        <div class="t">${sv}${esc(title)}</div>${body ? `<div class="b">${body}</div>` : ''}${done}${m.has_basis ? '<div class="whyp" hidden></div>' : ''}
        <div class="ac">${go}${m.has_basis ? `<button class="whyb" type="button" data-x="why" data-id="${m.id}" aria-expanded="false">Perché?</button>` : ''}<button class="more" data-x="more" hidden>Mostra tutto</button>${isOpenAl && canFix && !m.notice_key ? '<button class="rd fx" data-x="fix">✓ Risolto…</button>' : isOpenAl && m.notice_key ? '<span class="seen">Si chiude da solo quando è sistemato</span>' : ''}${mine.length ? `<button class="rd" data-x="read">${isOpenAl ? '👀 Visto' : '✓ Segna come letta'}</button>` : ''}${seen}</div>
        <div class="fixf nodirty" hidden><input type="text" maxlength="300" placeholder="Cosa è stato fatto? (es. «ricopiato da carta», «bot rilanciato»)" aria-label="Cosa è stato fatto"><button class="btn sm" data-x="fixok" type="button">Risolto</button><button class="btn sm sec" data-x="fixno" type="button">Annulla</button></div></div></div>`;
    }).join('');
    feed.querySelectorAll('.msg .b').forEach(b => { if (b.scrollHeight > b.clientHeight + 4) { b.classList.add('cut'); b.closest('.mb').querySelector('[data-x=more]').hidden = false; } });
    // v1.06 «Perché?»: the numbers this message was based on, written out by the database
    feed.querySelectorAll('[data-x=why]').forEach(btn => btn.onclick = () => UI.why.toggle(btn, btn.closest('.mb').querySelector('.whyp'), btn.dataset.id));
    feed.querySelectorAll('[data-x=more]').forEach(btn => btn.onclick = () => { const bd = btn.closest('.mb').querySelector('.b'); bd.classList.toggle('open'); btn.textContent = bd.classList.contains('open') ? 'Riduci' : 'Mostra tutto'; });
    const ids = (el, k) => (el.closest('.msg').dataset[k] || '').split(',').filter(Boolean).map(Number);
    feed.querySelectorAll('[data-x=read]').forEach(btn => btn.onclick = () => UI.act(btn, async () => { const { error } = await sb.rpc('mark_bot_messages_read', { p_ids: ids(btn, 'ids') }); if (error) throw error; loadBotFeed(); }));
    // «Risolto»: closes the alarm for everyone, with what was done (sistema «gestisce»; C-12)
    feed.querySelectorAll('[data-x=fix]').forEach(btn => btn.onclick = () => { const f = btn.closest('.mb').querySelector('.fixf'); f.hidden = false; btn.hidden = true; f.querySelector('input').focus(); });
    feed.querySelectorAll('[data-x=fixno]').forEach(btn => btn.onclick = () => { const mb = btn.closest('.mb'); mb.querySelector('.fixf').hidden = true; mb.querySelector('[data-x=fix]').hidden = false; });
    feed.querySelectorAll('.fixf input').forEach(i => i.onkeydown = e => { if (e.key === 'Enter') { e.preventDefault(); i.closest('.fixf').querySelector('[data-x=fixok]').click(); } });
    feed.querySelectorAll('[data-x=fixok]').forEach(btn => btn.onclick = () => UI.act(btn, async () => {
      const note = btn.closest('.fixf').querySelector('input').value.trim();
      if (note.length < 3) { toast('Scrivi cosa è stato fatto (almeno qualche parola)', 'err'); return false; }
      const { data, error } = await sb.rpc('resolve_bot_messages', { p_ids: ids(btn, 'open'), p_note: note }); if (error) throw error;
      loadBotFeed(); return data;
    }, n => n === 1 ? 'Allarme chiuso per tutti' : `${n} allarmi chiusi per tutti`));
  }
  async function runNow(agent) {
    const t = bdRole[agent] || botTitle(agent), b = $('bd-run-go');
    if (!confirm(/^shopify_/.test(agent) ? `${t}: avviare adesso la sincronizzazione con Shopify?\n\n${RUN_NOW[agent]}` : `${t}: eseguire adesso la versione del database?\n\n${RUN_NOW[agent]}`)) return;
    await UI.act(b, async () => {
      let r = await sb.rpc('run_bot_fallback', { p_agent: agent });
      if (r.error && r.error.hint === 'confirm') { if (!confirm(r.error.message)) return false; r = await sb.rpc('run_bot_fallback', { p_agent: agent, p_confirm: true }); }
      if (r.error) throw r.error;
      loadBotFeed(); if ($('runs-card').open) loadRuns(); return r.data;
    }, d => d && d.started ? `${d.title} · ${d.summary}` : `Fatto · ${(d && (d.title || d.summary)) || t}`);
  }
  document.querySelectorAll('.bd-bar .chip[data-f]').forEach(c => c.onclick = () => { bdFilter = c.dataset.f; bdLimit = 50; document.querySelectorAll('.bd-bar .chip[data-f]').forEach(x => x.setAttribute('aria-pressed', x === c)); loadBotFeed(); });
  $('bd-en').onclick = () => { bdEn = !bdEn; $('bd-en').setAttribute('aria-pressed', bdEn); loadBotFeed(); };
  $('bd-more').onclick = () => { bdLimit += 50; loadBotFeed(); };
  // «Segna tutto come letto»: only for me, and never the alarms (they stay until someone marks them «Risolto»)
  $('bd-readall').onclick = async () => {
    let ids = null, n = 0;
    if (bdAgent) { const { data } = await sb.from('v_bot_feed').select('id').eq('for_me', true).neq('severity', 'alert').in('agent', SYS[bdAgent] ? SYS[bdAgent].agents : [bdAgent]); ids = (data || []).map(x => x.id); n = ids.length; }
    else { const { data } = await sb.rpc('bot_bell'); n = Number(data && data.unread) || 0; }
    if (!n) return toast('Niente da segnare');
    if (!confirm(`Segnare come lette ${n} notifiche, solo per te?\nGli allarmi restano aperti finché qualcuno li segna «Risolto».`)) return;
    const { data, error } = await sb.rpc('mark_bot_messages_read', { p_ids: ids }); if (error) return toast(error.message, 'err');
    toast(`${data} notifiche segnate come lette`); loadBotFeed();
  };
  setInterval(() => { if (document.visibilityState === 'visible' && T.current === 'bots' && !UI.unsaved()) loadBotFeed(); }, 60000);
  // run log: loaded when opened, follows the selected bot
  $('runs-card').addEventListener('toggle', () => { if ($('runs-card').open) loadRuns(); });
  async function loadRuns() {
    const box = $('runs'); box.innerHTML = '<div class="status">Carico…</div>';
    let q = sb.from('agent_runs').select('agent, started_at, status, summary, error').order('started_at', { ascending: false }).limit(40);
    if (bdAgent) q = q.in('agent', SYS[bdAgent] ? SYS[bdAgent].agents : [bdAgent]);
    const { data: runs, error } = await q;
    $('runs-who').textContent = bdAgent ? '· solo ' + (bdNames[bdAgent] || bdAgent) : '· ultime 40';
    if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    const fmtT = s => new Date(s).toLocaleString('it-IT', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Rome' });
    box.innerHTML = (runs && runs.length) ? '<table><tr><th>Bot</th><th>Quando</th><th>Esito</th><th>Dettaglio</th></tr>' + runs.map(r => `<tr><td>${esc(botLabel(r.agent))}</td><td class="status" style="white-space:nowrap">${fmtT(r.started_at)}</td><td class="${r.status === 'ok' ? 'ok' : 'ko'}">${esc(r.status)}</td><td class="status">${esc(r.summary || r.error || '')}</td></tr>`).join('') + '</table>' : '<div class="empty">Nessuna esecuzione registrata.</div>';
  }  // ---------- Utenti e ruoli ----------
  const LVL = ['—', 'vede', 'registra', 'gestisce'];
  const JOBS = [['owner', 'titolare'], ['partner', 'socio'], ['casaro', 'casaro'], ['operaio', 'operaio'], ['commesso', 'commesso'], ['consulente', 'consulente']];
  // v1.09 (audit C-17): the job role («Mansione»: courses and rota) follows the profile unless it is changed by hand
  const JOB_FOR = { titolare: 'owner', socio: 'partner', resp_produzione: 'casaro', produzione: 'operaio', qualita: 'operaio', spedizioni: 'operaio', banco: 'commesso', marketing: 'consulente', amministrazione: 'consulente', consulente: 'consulente' };
  const fmtWhen = s => new Date(s).toLocaleString('it-IT', { weekday: 'short', day: 'numeric', month: 'numeric', hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Rome' });
  // v1.09: the personal access link (a week, one use, only the newest works) with the message ready for WhatsApp or e-mail.
  // Nothing leaves by itself: Nick sends it from his phone (no Supabase e-mail, so no 24 h and no hourly limit). Audit C-19: the
  // message names the company and the page the profile uses, not «La Perla» and the office Console.
  function showLink(p, r, box) {
    const first = (p.full_name || '').split(' ')[0], company = r.company || BRAND.name;
    const home = `${r.site || location.origin}/${PERM.HOME[r.home] || 'index.html'}`, until = fmtWhen(r.expires_at), email = r.email || p.email || '';
    const text = r.purpose === 'reset'
      ? `Ciao ${first}, ecco il link per scegliere una nuova password per l'app di ${company}. Vale fino a ${until}, una volta sola:\n${r.link}`
      : `Ciao ${first}, ecco il tuo link per entrare nell'app di ${company}${r.role_name ? ' (' + r.role_name + ')' : ''}: aprilo e scegli la tua password. Vale fino a ${until}, una volta sola:\n${r.link}\n\nPoi entra sempre da ${home} con la tua email (${email}) e la password.`;
    const subject = r.purpose === 'reset' ? `Nuova password per l'app di ${company}` : `Il tuo accesso all'app di ${company}`;
    box.innerHTML = `<div class="linkbox"><b>${r.purpose === 'reset' ? 'Link per una nuova password' : 'Link di accesso'} per ${esc(p.full_name)}</b>
      <div class="status">vale fino a ${esc(until)} · una volta sola · un link mandato prima non vale più · non è partita nessuna email: mandalo tu</div>
      <div class="row" style="gap:6px;margin-top:8px;flex-wrap:wrap"><input readonly style="flex:1;min-width:200px" value="${esc(r.link)}" aria-label="Link di accesso"><button class="btn sm sec" type="button" data-copy>Copia</button></div>
      <div class="row" style="gap:6px;margin-top:6px;flex-wrap:wrap"><a class="btn sm" style="text-decoration:none" target="_blank" rel="noopener" href="https://wa.me/?text=${encodeURIComponent(text)}">Manda su WhatsApp</a>
        <a class="btn sm sec" style="text-decoration:none" href="mailto:${esc(email)}?subject=${encodeURIComponent(subject)}&amp;body=${encodeURIComponent(text)}">Manda per email</a></div>
      <details style="margin-top:6px"><summary class="status">Testo del messaggio</summary><pre style="white-space:pre-wrap;font:inherit;margin:4px 0">${esc(text)}</pre></details></div>`;
    box.querySelector('[data-copy]').onclick = async () => { try { await navigator.clipboard.writeText(r.link); toast('Link copiato'); } catch { box.querySelector('input').select(); } };
    box.scrollIntoView({ behavior: 'smooth', block: 'center' });
  }
  async function callUsers(body) {
    const { data, error } = await sb.functions.invoke('invite-user', { body });
    if (error) { let m = error.message, j = null; try { j = await error.context.json(); m = j.error || m; } catch {} throw Object.assign(new Error(m), { data: j }); }
    if (data && data.error) throw Object.assign(new Error(data.error), { data }); return data;
  }
  const badgeLine = p => [p.badge_code, p.full_name, (JOBS.find(([v]) => v === p.role) || [, ''])[1]].map(s => String(s || '').replace(/[|\n]/g, ' ')).join(' | ');
  const flashPerson = id => { const c = document.querySelector(`.person[data-staff="${id}"]`); if (!c) return null; c.classList.add('flash'); c.scrollIntoView({ behavior: 'smooth', block: 'center' }); setTimeout(() => c.classList.remove('flash'), 2500); return c; };
  // v1.09 (audit C-14): what «Disattiva» did, kept on screen with what is still in the person's name
  function showOffboard(sum) {
    let box = $('usr-done'); if (!box) { box = document.createElement('div'); box.id = 'usr-done'; box.className = 'card'; box.style.marginTop = '12px'; $('users').before(box); }
    const done = [sum.shift_closed ? 'turno aperto chiuso' : '', sum.rota_removed ? `${sum.rota_removed} ${sum.rota_removed === 1 ? 'turno futuro tolto' : 'turni futuri tolti'}` : '',
      sum.links_revoked ? 'link di accesso annullato' : '', sum.telegram_unlinked ? 'Telegram scollegato' : '', sum.pin_removed ? 'PIN tolto' : '', 'accesso bloccato'].filter(Boolean);
    box.innerHTML = `<b>${esc(sum.full_name)} è disattivato</b><div class="status">${esc(done.join(' · '))}</div>
      ${(sum.mentions || []).length ? `<div style="margin-top:6px"><b>Ancora a suo nome, da cambiare a mano:</b><ul style="margin:4px 0 0 18px;padding:0">${sum.mentions.map(m => `<li>${esc(m.kind)} «${esc(m.what)}» <small class="status">· ${esc(m.where)}</small></li>`).join('')}</ul></div>` : ''}
      <div class="row" style="margin-top:6px"><button class="btn sm sec" type="button" id="usr-done-x">Chiudi</button></div>`;
    $('usr-done-x').onclick = () => box.remove();
  }
  // one card per person (v1.09: the table did not fit a phone, audit C-33): a checklist of what is set up, the profile, the e-mail
  // and the actions, the main one chosen by what is missing
  function personCard(p, { admin, roleOpts, L, pin, tg, todo }) {
    const c = document.createElement('div'); c.className = 'person' + (p.active ? '' : ' off'); c.dataset.staff = p.id;
    const first = (p.full_name || '').split(' ')[0], self = p.id === staff.id;
    const st = !p.active ? 'disattivato' : L ? L.state : p.auth_user_id ? 'account' : p.email ? 'da_invitare' : 'senza_email';
    const ACC = { attivo: ['ok', `accesso attivo${L && L.last_sign_in_at ? ' · ultimo ' + fmtWhen(L.last_sign_in_at) : ''}${L && L.link_open ? ' · link per nuova password mandato, vale fino a ' + fmtWhen(L.link_expires_at) : ''}`],
      invitato: ['wn', L && L.link_kind === 'link' ? `link mandato${L.link_by ? ' da ' + L.link_by : ''}: vale fino a ${fmtWhen(L.link_expires_at)}, non l'ha ancora aperto` : `invito email: vale fino a ${L ? fmtWhen(L.link_expires_at) : '?'}`],
      link_scaduto: ['ko', `il link è scaduto senza essere usato${L && L.link_expires_at ? ' (' + fmtWhen(L.link_expires_at) + ')' : ''}: mandagliene uno nuovo`],
      senza_password: ['ko', 'ha aperto un link ma non ha scelto la password: mandagliene uno nuovo'],
      da_invitare: ['wn', 'non ha ancora un accesso: mandagli il link'], senza_email: ['', 'senza email: sul tablet usa badge e PIN, in console non entra'],
      disattivato: ['', 'disattivato: non entra più'], account: ['', 'account creato'] }[st] || ['', st];
    const ck = (ok, txt, title) => `<span class="ck ${ok ? 'ok' : 'todo'}" title="${esc(title)}">${ok ? '✓ ' : ''}${txt}</span>`;
    const checks = !p.active ? '' : [
      ck(st === 'attivo', 'Accesso', ACC[1]),
      admin ? ck(tg && tg.linked, 'Telegram', tg && tg.linked ? 'collegato: riceve gli allarmi sul telefono' : 'non collegato: gli allarmi gli arrivano solo nell\'app') : '',
      admin ? ck(pin, 'PIN', pin ? 'PIN del tablet impostato' : 'senza PIN: sul tablet si sceglie solo col badge') : '',
      ck(!todo, todo ? `Formazione: ${todo} da fare` : 'Formazione', todo ? 'corsi HACCP mancanti o scaduti (Console → Personale)' : 'corsi in regola')].join('');
    c.innerHTML = `<div class="p-head"><b>${esc(p.full_name)}</b>${self ? ' <small class="status">(tu)</small>' : ''}</div>
      <div class="p-state ${ACC[0] === 'ko' ? 'ko' : 'status'}">${esc(ACC[1])}</div><div class="p-checks">${checks}</div>
      <div class="p-fields"></div><div class="p-email"></div><div class="p-actions"></div><div class="p-out"></div>`;
    const out = c.querySelector('.p-out'), acts = c.querySelector('.p-actions'), fields = c.querySelector('.p-fields'), emailLine = c.querySelector('.p-email');
    const roleName = (roleOpts.list.find(r => r.code === p.app_role) || {}).name_it || p.app_role, jobName = (JOBS.find(([v]) => v === p.role) || [, p.role])[1];
    // profile and job role
    if (admin && p.active) {
      fields.dataset.scope = '';
      fields.innerHTML = `<label>Profilo <select aria-label="Profilo di ${esc(p.full_name)}">${roleOpts(p.app_role)}</select></label>
        <label>Mansione <small>(corsi e turni)</small> <select aria-label="Mansione di ${esc(p.full_name)}">${JOBS.map(([v, l]) => `<option value="${v}"${v === p.role ? ' selected' : ''}>${l}</option>`).join('')}</select></label>`;
      const [rs, js] = fields.querySelectorAll('select');
      rs.onchange = () => { if (JOB_FOR[rs.value]) js.value = JOB_FOR[rs.value]; };
      fields.append(saveBtn(async () => {
        if (rs.value !== p.app_role && (rs.value === 'titolare' || p.app_role === 'titolare') && !confirm(rs.value === 'titolare'
          ? `${p.full_name} diventa Titolare: potrà gestire utenti e ruoli e cambiare tutta la configurazione. Confermi?`
          : `${p.full_name} non sarà più Titolare: non potrà più gestire utenti e ruoli. Confermi?`)) throw Object.assign(new Error('non salvato'), { silent: true });
        PERM.changed(await sb.from('staff').update({ app_role: rs.value, role: js.value }).eq('id', p.id).select('id'));
        UI.after(loadUsers);
      }));
    } else fields.innerHTML = `<span class="status">Profilo ${esc(roleName)} · mansione ${esc(jobName)}</span>`;
    // e-mail (audit C-13: with a login, «Cambia» changes the login e-mail too)
    const renderEmail = () => {
      emailLine.innerHTML = `Email: ${p.email ? `<b>${esc(p.email)}</b>` : '<span class="status">nessuna</span>'} `;
      if (admin && p.active) { const e = document.createElement('button'); e.type = 'button'; e.className = 'btn sm sec'; e.textContent = p.email ? 'Cambia' : 'Aggiungi'; e.onclick = openEmail; emailLine.append(e); }
    };
    const openEmail = () => {
      emailLine.innerHTML = ''; const w = document.createElement('div'); w.className = 'row'; w.dataset.scope = ''; w.style.cssText = 'gap:6px;flex-wrap:wrap;align-items:center';
      w.innerHTML = `<input type="email" autocomplete="off" autocapitalize="off" spellcheck="false" placeholder="nome@esempio.it" style="flex:1;min-width:200px" aria-label="Nuova email di ${esc(p.full_name)}">
        <button type="button" class="btn sm save">Salva email</button><button type="button" class="btn sm sec">Annulla</button>`;
      const [inp, ok, no] = w.querySelectorAll('input, button'); inp.value = p.email || '';
      ok.onclick = async () => {
        const v = inp.value.trim().toLowerCase();
        if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v)) return toast('Scrivi un\'email valida', 'err');
        if (p.auth_user_id && p.email && v !== p.email.toLowerCase() && !confirm(`Cambia anche l'email con cui ${first} entra: da ora entra con ${v} (la password resta la stessa). Confermi?`)) return;
        ok.disabled = true;
        try { const r = await callUsers({ action: 'update_email', staff_id: p.id, email: v }); UI.clean(w);
          toast(r.unchanged ? 'Nessuna modifica' : r.login_changed ? `Email cambiata: ${first} ora entra con ${v}` : 'Email salvata'); loadUsers(); }
        catch (err) { toast(err.message || String(err), 'err'); } finally { ok.disabled = false; }
      };
      no.onclick = () => { UI.clean(w); renderEmail(); };
      emailLine.append(w); inp.focus();
    };
    renderEmail();
    // actions
    const b = (label, cls, fn, title) => { const x = document.createElement('button'); x.type = 'button'; x.className = 'btn sm ' + cls; x.textContent = label; if (title) x.title = title;
      x.onclick = async () => { x.disabled = true; try { await fn(); } catch (err) { toast(err.message || String(err), 'err'); } finally { x.disabled = false; } }; acts.append(x); return x; };
    if (admin && p.active && !self) {
      if (!p.email) b('Aggiungi l\'email per l\'accesso', '', async () => openEmail());
      else b(st === 'attivo' ? 'Link per nuova password' : 'Link di accesso', st === 'attivo' || st === 'invitato' ? 'sec' : '', async () => {
        if (st === 'invitato' && !confirm(`${first} ha già un link valido fino a ${fmtWhen(L.link_expires_at)}. Ne crei uno nuovo? Quello di prima smette di funzionare.`)) return;
        const r = await callUsers({ action: 'access_link', staff_id: p.id }); showLink(p, r, out);
      }, 'Un link personale da mandare su WhatsApp o per email: vale una settimana, una volta sola');
      if (!(tg && tg.linked)) b('Link Telegram', 'sec', async () => {
        const { data, error } = await sb.rpc('notify_link_code', { p_staff_id: p.id }); if (error) throw error; ntLinkBox(out, data, true); out.scrollIntoView({ behavior: 'smooth', block: 'center' });
      }, 'Per ricevere gli allarmi sul suo telefono');
    }
    if (admin && p.active) {   // v0.96 (A-01): the 4-digit PIN that, with the badge, says who is recording on the floor tablet
      const pb = b(pin ? 'PIN ✓' : 'PIN', 'sec', async () => {
        if (out.querySelector('[data-pin]')) { out.innerHTML = ''; return; }
        const w = document.createElement('span'); w.dataset.pin = '1'; w.style.cssText = 'display:inline-flex;gap:4px;align-items:center;margin-top:6px';
        w.innerHTML = '<input type="password" inputmode="numeric" maxlength="4" autocomplete="new-password" placeholder="4 cifre" style="width:80px" aria-label="PIN"><button type="button" class="btn sm save">Salva PIN</button>' + (pin ? '<button type="button" class="btn sm warn">Togli</button>' : '');
        const [inp, ok, del] = w.querySelectorAll('input, button');
        const run = async v => { try { if (v !== null && !/^\d{4}$/.test(v)) throw new Error('Il PIN è di 4 cifre');
            const { error } = await sb.rpc('staff_set_pin', { p_staff_id: p.id, p_pin: v }); if (error) throw error;
            toast(v === null ? `PIN di ${p.full_name} tolto` : `PIN di ${p.full_name} impostato: diglielo a voce, non scriverlo da nessuna parte`); loadUsers(); }
          catch (err) { toast(err.message || String(err), 'err'); } };
        ok.onclick = () => run(inp.value.trim()); inp.onkeydown = e => { if (e.key === 'Enter') { e.preventDefault(); run(inp.value.trim()); } };
        if (del) del.onclick = () => { if (confirm(`Togliere il PIN di ${p.full_name}? Sul tablet potrà registrare solo passando il badge.`)) run(null); };
        out.innerHTML = ''; out.append(w); inp.focus();
      }, pin ? 'PIN del tablet impostato: tocca per cambiarlo o toglierlo' : 'Imposta il PIN di 4 cifre per scegliersi sul tablet senza badge');
      pb.classList.toggle('done', !!pin);
    }
    if (p.active && p.badge_code) { const a = document.createElement('a'); a.className = 'btn sm sec'; a.style.textDecoration = 'none'; a.target = '_blank'; a.textContent = 'Badge';
      a.title = 'Stampa il badge QR da passare sul tablet'; a.href = 'labels.html?' + new URLSearchParams({ l: badgeLine(p) }); acts.append(a); }
    if (admin && !self) {
      if (p.active) b('Disattiva', 'warn', async () => {
        const { data: pv, error } = await sb.rpc('staff_offboard_preview', { p_staff_id: p.id }); if (error) throw error;
        const lines = [`Disattivare ${p.full_name}?`, '', '• Non potrà più entrare nell\'app, e sul tablet non comparirà più'];
        if (pv.open_shift_since) lines.push(`• Il turno aperto da ${fmtWhen(pv.open_shift_since)} si chiude adesso`);
        if (pv.future_rota) lines.push(`• ${pv.future_rota === 1 ? '1 turno futuro tolto' : pv.future_rota + ' turni futuri tolti'} dalla turnazione`);
        if (pv.open_links) lines.push('• Il link di accesso mandato non vale più');
        if (pv.telegram) lines.push('• Telegram scollegato: non riceve più gli allarmi');
        if (pv.pin) lines.push('• PIN del tablet tolto');
        if ((pv.mentions || []).length) { lines.push('', 'Ancora a suo nome (da cambiare a mano dopo):'); pv.mentions.forEach(m => lines.push(`• ${m.kind} «${m.what}»`)); }
        lines.push('', 'Si può riattivare in qualsiasi momento.');
        if (!confirm(lines.join('\n'))) return;
        const r = await callUsers({ action: 'deactivate', staff_id: p.id });
        await loadUsers(); showOffboard(r.summary || { full_name: p.full_name }); toast(`${p.full_name} disattivato`);
      });
      else b('Riattiva', 'sec', async () => {
        await callUsers({ action: 'reactivate', staff_id: p.id });
        toast(`${p.full_name} riattivato: se serve mandagli un link di accesso, poi ricollega Telegram e il PIN`); loadUsers();
      });
    }
    return c;
  }
  async function loadUsers() {
    const admin = PERM.isAdmin();
    $('usr-invite').hidden = !admin; $('usr-ro').hidden = admin;
    const [{ data: people, error }, { data: roles }, { data: areas }, { data: perms }, { data: train }] = await Promise.all([
      sb.from('staff').select('id, full_name, email, role, app_role, auth_user_id, active, badge_code').order('active', { ascending: false }).order('full_name'),
      sb.from('app_roles').select('*').order('sort'), sb.from('app_areas').select('*').neq('code', 'comune').order('sort'), sb.from('role_permissions').select('*'),
      sb.from('v_training_matrix').select('staff_id, status')]);
    // v0.81: real login state from auth (an invite sent is not a login); v1.09 also the app's own links. Titolare only.
    // v0.96 (A-01): who has a tablet PIN (the PIN itself is never readable). Telegram: who receives the alarms on the phone.
    const LOGIN = {}, HASPIN = {}, TG = {};
    if (admin) {
      const [lg, fo, nt] = await Promise.all([sb.rpc('staff_logins'), sb.rpc('floor_operators'), sb.rpc('notify_overview')]);
      (lg.data || []).forEach(r => { LOGIN[r.staff_id] = r; });
      (fo.data || []).forEach(r => { HASPIN[r.id] = r.has_pin; });
      ((nt.data && nt.data.people) || []).forEach(r => { TG[r.staff_id] = r; });
    }
    const TODO = {}; (train || []).forEach(t => { if (t.status === 'mancante' || t.status === 'scaduto') TODO[t.staff_id] = (TODO[t.staff_id] || 0) + 1; });
    const box = $('users'); if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    const roleOpts = sel => (roles || []).map(r => `<option value="${r.code}"${r.code === sel ? ' selected' : ''}>${esc(r.name_it)}</option>`).join('');
    roleOpts.list = roles || [];
    $('inv-role').innerHTML = roleOpts('produzione');
    box.innerHTML = '';
    (people || []).forEach(p => box.append(personCard(p, { admin, roleOpts, L: LOGIN[p.id], pin: HASPIN[p.id], tg: TG[p.id], todo: TODO[p.id] })));
    if (!(people || []).length) box.innerHTML = '<div class="empty">Nessuna persona: aggiungila qui sopra.</div>';
    const withBadge = (people || []).filter(p => p.active && p.badge_code);
    if (withBadge.length) { const q = new URLSearchParams(); withBadge.forEach(p => q.append('l', badgeLine(p)));
      const all = document.createElement('a'); all.className = 'btn sm sec'; all.style.cssText = 'text-decoration:none;display:inline-block;margin-top:8px'; all.target = '_blank';
      all.textContent = `Stampa tutti i badge (${withBadge.length})`; all.href = 'labels.html?' + q; box.append(all); }
    loadNotify().catch(e => toast(e.message || String(e), 'err'));   // v0.96 (E-01)
    loadFarmLinks().catch(e => toast(e.message || String(e), 'err'));   // v1.03 (FARM-04)
    // matrix
    const mbox = $('roles-matrix'); const lv = {}; (perms || []).forEach(x => { lv[x.role_code + '|' + x.area] = x.level; });
    const mt = document.createElement('table');
    mt.innerHTML = '<tr><th>Profilo</th>' + (areas || []).map(a => `<th title="${esc(a.description_it || '')}">${esc(a.name_it)}</th>`).join('') + '</tr>';
    const edits = [];
    (roles || []).forEach(r => {
      const tr = document.createElement('tr'); tr.innerHTML = `<td><b>${esc(r.name_it)}</b>${r.can_manage_users ? ' <small class="status">utenti</small>' : ''}<br><small>${esc(r.description_it || '')}</small></td>`;
      (areas || []).forEach(a => {
        const td = document.createElement('td'); const v = lv[r.code + '|' + a.code] ?? 0;
        if (admin && r.code !== 'titolare') { const s = document.createElement('select'); s.innerHTML = LVL.map((l, i) => `<option value="${i}"${i === v ? ' selected' : ''}>${l}</option>`).join(''); s.dataset.orig = v; edits.push({ role: r.code, area: a.code, s }); td.append(s); }
        else td.innerHTML = `<small>${LVL[v]}</small>`;
        tr.append(td);
      });
      mt.append(tr);
    });
    mbox.innerHTML = ''; mbox.append(mt);
    $('roles-save').hidden = !admin;
    $('roles-save').onclick = async () => {
      const ch = edits.filter(e => String(e.s.value) !== String(e.s.dataset.orig)).map(e => ({ role_code: e.role, area: e.area, level: Number(e.s.value) }));
      if (!ch.length) return toast('Nessuna modifica');
      const { error } = await sb.from('role_permissions').upsert(ch, { onConflict: 'role_code,area' }); if (error) return toast(error.message, 'err');
      UI.clean($('roles-card')); toast(`Permessi aggiornati (${ch.length})`); loadUsers();
    };
  }
  // v1.09: «Aggiungi una persona». With an e-mail, the person's access link is ready at once (WhatsApp or e-mail from your phone).
  // An e-mail already in use opens that person's card instead (audit C-15: someone switched off comes back with «Riattiva»).
  $('inv-go').onclick = async () => {
    const b = $('inv-go'), name = $('inv-name').value.trim().replace(/\s+/g, ' '), email = $('inv-email').value.trim().toLowerCase();
    if (name.length < 3) return toast('Scrivi nome e cognome', 'err');
    if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return toast('Email non valida', 'err');
    b.disabled = true;
    try {
      const r = await callUsers({ action: 'add', full_name: name, email, app_role: $('inv-role').value });
      $('inv-name').value = ''; $('inv-email').value = ''; UI.clean($('usr-invite'));
      await loadUsers();
      const card = flashPerson(r.staff_id);
      if (r.link && card) showLink({ full_name: name, email }, r, card.querySelector('.p-out'));
      toast(r.link ? `${name} aggiunto: mandagli il link di accesso` : `${name} aggiunto, senza email: sul tablet usa badge e PIN`);
    } catch (err) { toast(err.message || String(err), 'err'); if (err.data && err.data.staff_id) flashPerson(err.data.staff_id); }
    finally { b.disabled = false; }
  };
  // v0.84: a settings row is shown by its description ("Prezzo del latte di bufala €/kg…"), never by its key
  let SETNAME = {};
  const settingName = k => SETNAME[k] || (PROWS.find(r => r.key === k) || {}).description || k;
  async function loadSettingNames() { if (Object.keys(SETNAME).length) return; const { data } = await sb.from('settings').select('key, description'); (data || []).forEach(r => { SETNAME[r.key] = r.description || r.key; }); }
  const AUD_T = { settings: 'Parametri', approvals: 'Approvazioni', recipes: 'Ricette', standing_orders: 'Ordini fissi', staff: 'Personale', products: 'Prodotti', equipment: 'Macchine',
    compliance_deadlines: 'Scadenze', haccp_control_points: 'Punti HACCP', process_steps: 'Processo', supplier_products: 'Condizioni fornitori', supplier_prices: 'Listini',
    farm_supply: 'Latte Masseria', shopify_variant_map: 'Prodotti Shopify', training_courses: 'Corsi', rota_entries: 'Turni' };
  const AUD_A = { insert: 'aggiunto', update: 'modificato', delete: 'eliminato' };
  const short = v => { if (v == null) return '∅'; const s = typeof v === 'object' ? JSON.stringify(v) : String(v); return s.length > 60 ? s.slice(0, 57) + '…' : s; };  async function loadAudit() {
    const sel = $('aud-table'); if (sel.options.length === 1) Object.entries(AUD_T).forEach(([k, l]) => sel.add(new Option(l, k)));
    const box = $('audit'); box.innerHTML = '<div class="status">Carico…</div>';
    let q = sb.from('audit_log').select('*').order('at', { ascending: false }).limit(150);
    if (sel.value) q = q.eq('table_name', sel.value);
    const [{ data, error }] = await Promise.all([q, loadSettingNames()]);
    if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    audRows = data || []; renderAudit();
  }
  function renderAudit() {
    const box = $('audit'), data = audRows;
    const needle = $('aud-q').value.trim().toLowerCase();
    const rows = (data || []).filter(r => !needle || (JSON.stringify(r) + ' ' + (r.table_name === 'settings' ? settingName(r.row_key) : '')).toLowerCase().includes(needle));
    if (!rows.length) { box.innerHTML = '<div class="empty">Nessuna modifica registrata.</div>'; return; }
    const label = r => { const d = r.new_data || r.old_data || {}; return r.table_name === 'settings' ? settingName(r.row_key) : d.summary || d.full_name || d.name || d.name_it || d.code || d.subject_it || d.po_number || d.work_date || (r.row_key || '').slice(0, 8); };
    box.innerHTML = `<table><tr><th>Quando</th><th>Chi</th><th>Dove</th><th>Cosa</th><th>Modifica</th></tr>${rows.map(r => {
      const diff = r.action === 'update' ? (r.changed || []).map(c => `<b>${esc(c)}</b>: ${esc(short(r.old_data?.[c]))} → ${esc(short(r.new_data?.[c]))}`).join('<br>') : esc(AUD_A[r.action]);
      return `<tr><td class="nw">${new Date(r.at).toLocaleString('it-IT', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Rome' })}</td><td>${esc(r.actor)}</td><td>${esc(AUD_T[r.table_name] || r.table_name)}</td><td>${esc(label(r))}</td><td><small>${diff}</small></td></tr>`; }).join('')}</table>`;
  }
  // the table filter asks the database again; the text filter works on what is already loaded, as you type
  let audRows = [], audT = null;
  $('aud-table').onchange = () => loadAudit();
  $('aud-q').oninput = () => { clearTimeout(audT); audT = setTimeout(renderAudit, 200); };
  // ---------- Shopify variant → stock product map ----------
  async function loadVariantMap() {
    const box = $('variant-map'); box.innerHTML = '';
    const [{ data: rows, error }, { data: prods }] = await Promise.all([sb.from('v_shopify_variant_map').select('*'), sb.from('products').select('id, sku, name, unit').eq('kind', 'finished_good').eq('active', true).order('name')]);
    if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    if (!rows || !rows.length) { box.innerHTML = '<div class="empty">Nessuna variante ancora vista: compare dopo il primo ordine o la prima sincronizzazione.</div>'; return; }
    rows.sort((a, b) => (b.unmapped_lines || 0) - (a.unmapped_lines || 0) || (!a.product_sku) - (!b.product_sku));
    badge('n-prod', rows.filter(r => r.unmapped_lines).length); $('n-prod').title = 'varianti con righe d\'ordine in attesa';
    const tbl = document.createElement('table'); tbl.className = 'rec';
    tbl.innerHTML = '<tr><th>Variante Shopify</th><th>Tipo</th><th>Prodotto magazzino</th><th class="num">kg / pezzo</th><th></th></tr>';
    rows.forEach(r => {
      const tr = document.createElement('tr'); if (!r.product_sku) tr.style.background = 'var(--tile)';
      tr.innerHTML = `<td><b>${esc(r.label)}</b>${r.unmapped_lines ? `<br><small class="ko">${r.unmapped_lines} righe d'ordine in attesa</small>` : ''}${r.auto_mapped ? '<br><small class="status">collegata automaticamente</small>' : ''}</td><td class="status">${esc(r.product_type || '')}</td>`;
      const sel = document.createElement('select'); sel.innerHTML = '<option value="">— non scarica il magazzino —</option>' + (prods || []).map(p => `<option value="${p.id}" ${p.sku === r.product_sku ? 'selected' : ''}>${esc(p.name)} (${esc(p.unit)})</option>`).join('');
      // v0.95 (audit C-28): kg per piece, with the grams shown next to it; a value typed in grams (250) is caught before it deducts 250 kg per sale
      const kg = document.createElement('input'); kg.type = 'text'; kg.inputMode = 'decimal'; kg.autocomplete = 'off'; kg.style.width = '6em'; kg.style.textAlign = 'right'; kg.placeholder = 'kg';
      const fromTitle = (() => { const t = String(r.label || ''); let m = t.match(/(\d+(?:[.,]\d+)?)\s*kg\b/i); if (m) return Number(m[1].replace(',', '.')); m = t.match(/(\d+)\s*g\b/i); return m ? Number(m[1]) / 1000 : null; })();
      kg.value = r.kg_per_unit != null ? String(r.kg_per_unit).replace('.', ',') : (fromTitle > 0 && fromTitle <= 25 ? String(fromTitle).replace('.', ',') : '');
      const gr = document.createElement('div'); gr.className = 'status'; gr.style.fontSize = '.8rem';
      const showG = () => { const k = UI.parseIt(kg.value); gr.textContent = kg.value.trim() === '' ? '' : Number.isFinite(k) && k > 0 ? `= ${Math.round(k * 1000).toLocaleString('it-IT')} g` + (k > 5 ? ' ⚠' : '') : 'numero non valido'; };
      kg.oninput = showG; showG();
      const td3 = document.createElement('td'); td3.append(sel); const td4 = document.createElement('td'); td4.className = 'num'; td4.append(kg, gr);
      const td5 = document.createElement('td'); td5.append(saveBtn(async () => {
        const pid = sel.value || null, k = pid ? UI.parseIt(kg.value) : null; if (pid && !(k > 0)) throw new Error('Inserisci i kg per pezzo (es. 0,25 per 250 g)');
        if (pid && k > 25) throw new Error(`${String(k).replace('.', ',')} kg per pezzo non è possibile: se sono grammi scrivi ${String(k / 1000).replace('.', ',')}`);
        if (pid && k > 5 && !confirm(`${String(k).replace('.', ',')} kg per pezzo? Ogni pezzo venduto scarica ${String(k).replace('.', ',')} kg dal magazzino.\n\nSe sono grammi scrivi ${String(k / 1000).replace('.', ',')}.\n\nSalvare ${String(k).replace('.', ',')} kg?`)) throw new Error('Non salvato: correggi i kg per pezzo');
        await upd('shopify_variant_map', { variant_id: r.variant_id }, { product_id: pid, kg_per_unit: k, auto_mapped: false, updated_at: new Date().toISOString() }); UI.after(loadVariantMap);
      }));
      tr.append(td3, td4, td5); tbl.append(tr);
    });
    box.append(tbl);
  }
  function renderEquipment(rows) {
    const box = $('set-equipment'); box.innerHTML = '';
    // v0.84: late first, then without dates, then by the nearest date
    const today = UI.romeISO(), rank = r => { const ds = [r.next_calibration_on, r.next_maintenance_on].filter(Boolean); return !ds.length ? 1 : ds.some(d => d < today) ? 0 : 2; }, near = r => [r.next_calibration_on, r.next_maintenance_on].filter(Boolean).sort()[0] || '';
    const act = rows.filter(r => r.active).sort((a, b) => rank(a) - rank(b) || near(a).localeCompare(near(b)) || String(a.code).localeCompare(String(b.code)));
    if (!act.length) box.innerHTML = '<div class="empty">Nessuna macchina attiva.</div>';
    act.forEach(r => {
      const c = document.createElement('details'); c.className = 'eq';
      const nc = r.next_calibration_on, nm = r.next_maintenance_on, unset = !nc && !nm;
      c.innerHTML = `<summary class="h"><b>${esc(r.name)} <small class="status">${esc(r.code)}</small></b><span class="status">${unset ? '<span class="ko">date da impostare</span>' : `taratura <span class="${dueCls(nc)}">${fmtD(nc)}</span> · manutenzione <span class="${dueCls(nm)}">${fmtD(nm)}</span>`}</span></summary>
        <div class="f">
          <div><label>Ultima taratura</label><input type="date" data-k="last_calibrated_on" value="${r.last_calibrated_on || ''}"></div>
          <div><label>Ogni (giorni)</label><input type="number" data-k="calibration_interval_days" value="${r.calibration_interval_days ?? ''}" placeholder="—"></div>
          <div><label>Ultima manutenzione</label><input type="date" data-k="last_maintenance_on" value="${r.last_maintenance_on || ''}"></div>
          <div><label>Ogni (giorni)</label><input type="number" data-k="maintenance_interval_days" value="${r.maintenance_interval_days ?? ''}" placeholder="—"></div>
          <div style="grid-column:1/-1"><label>Tecnico / contatto</label><input type="text" data-k="technician_contact" value="${esc(r.technician_contact || '')}" placeholder="nome, telefono"></div>
        </div>`;
      const row = document.createElement('div'); row.className = 'row';
      row.append(saveBtn(async () => {
        const v = {}; c.querySelectorAll('input[data-k]').forEach(i => { v[i.dataset.k] = i.type === 'date' ? dOrNull(i.value) : i.type === 'number' ? nOrNull(i.value) : (i.value.trim() || null); });
        await upd('equipment', { id: r.id }, v); UI.after(loadMaint);
      }));
      c.append(row); box.append(c);
    });
  }
  function renderDeadlines(rows) {
    const box = $('set-deadlines'); box.innerHTML = '';
    if (!rows.length) box.innerHTML = '<div class="empty">Nessuna scadenza aperta.</div>';
    // v0.84: late first, then without a date, then by date
    const today = UI.romeISO(); rows = [...rows].sort((a, b) => ((a.due_on ? (a.due_on < today ? 0 : 2) : 1) - (b.due_on ? (b.due_on < today ? 0 : 2) : 1)) || String(a.due_on || '').localeCompare(String(b.due_on || '')));
    rows.forEach(r => {
      const c = document.createElement('details'); c.className = 'eq';
      c.innerHTML = `<summary class="h"><b>${esc(r.subject_it)}</b><span class="status ${dueCls(r.due_on) || (r.due_on ? '' : 'ko')}">${r.due_on ? 'scade ' + fmtD(r.due_on) : 'data da impostare'}</span></summary>
        <div class="f">
          <div><label>Scadenza</label><input type="date" data-k="due_on" value="${r.due_on || ''}"></div>
          <div><label>Ogni (giorni)</label><input type="number" data-k="interval_days" value="${r.interval_days ?? ''}" placeholder="una tantum"></div>
          <div><label>Responsabile</label><input type="text" data-k="responsible" value="${esc(r.responsible || '')}"></div>
          <div><label>Fornitore / contatto</label><input type="text" data-k="contact" value="${esc(r.contact || '')}"></div>
          <div style="grid-column:1/-1"><label>Note</label><input type="text" data-k="notes" value="${esc(r.notes || '')}"></div>
        </div>`;
      const row = document.createElement('div'); row.className = 'row';
      row.append(saveBtn(async () => { const v = {}; c.querySelectorAll('input[data-k]').forEach(i => { v[i.dataset.k] = i.type === 'date' ? dOrNull(i.value) : i.type === 'number' ? nOrNull(i.value) : (i.value.trim() || null); }); await upd('compliance_deadlines', { id: r.id }, v); UI.after(loadMaint); }));
      const done = document.createElement('button'); done.className = 'btn sm sec'; done.textContent = 'Fatto oggi';
      done.onclick = async () => { if (!confirm(`Segnare "${r.subject_it}" come fatta oggi?${r.interval_days ? ' Si apre la prossima scadenza.' : ''}`)) return; done.disabled = true; const { error } = await sb.rpc('complete_deadline', { p_id: r.id }); if (error) { toast(error.message, 'err'); done.disabled = false; return; } toast(r.interval_days ? 'Chiusa · prossima aperta' : 'Chiusa'); loadMaint(); };
      row.append(done); c.append(row); box.append(c);
    });
  }
  $('dl-add').onclick = async () => {
    const subj = $('dl-new-subject').value.trim(); if (!subj) return toast('Scrivi la descrizione', 'err');
    const { error } = await sb.from('compliance_deadlines').insert({ kind: 'other', subject_it: subj, due_on: dOrNull($('dl-new-due').value), interval_days: nOrNull($('dl-new-int').value), responsible: 'partner' });
    if (error) return toast(error.message, 'err');
    $('dl-new-subject').value = ''; $('dl-new-due').value = ''; $('dl-new-int').value = ''; UI.clean($('dl-add')); toast('Aggiunta'); loadMaint();
  };
  $('pw-open').onclick = () => UI.changePassword();   // v1.09 (audit C-23): the same dialog as the user menu

  // ---------- tabs + start ----------
  // ---------- Panoramica (v0.84): one card per area, built from the same views the tabs use ----------
  let ovStale = false, ovAt = 0;
  const ST_LBL = { ok: 'In ordine', wn: 'Da controllare', al: 'Da sistemare', na: 'Non disponibile' };
  const ovCard = c => `<a class="ovc s-${c.st}" href="#${c.tab}" id="ov-${c.id}"><div class="hd"><h3>${esc(c.title)}</h3><span class="pill s-${c.st}">${ST_LBL[c.st]}</span></div>
      <div class="big">${c.big}${c.sub ? `<small>${esc(c.sub)}</small>` : ''}</div>
      ${c.items && c.items.length ? `<ul>${c.items.slice(0, 3).map(i => `<li class="${i.st || ''}"><span>${esc(i.txt)}</span></li>`).join('')}${c.items.length > 3 ? `<li><span class="status">e ${plural(c.items.length - 3, 'altra', 'altre')}</span></li>` : ''}</ul>` : ''}
      <div class="ft">${esc(c.foot)}</div></a>`;
  // v1.05 (audit E-30): the go-live list in Italian. Automatic items close by themselves (each says how); a manual gate is ticked by
  // the titolare or a socio with a note and a confirmation, and shows who and when; undoing it asks why. Every change is in the Registro.
  async function loadGolive() {
    const card = $('golive-card'); if (!card || !PERM.can('sistema', 1)) return;
    const { data, error } = await sb.rpc('golive_checklist'); if (error) throw error;
    const items = data.items || [], open = items.filter(i => !i.done), done = items.filter(i => i.done), sign = !!data.can_sign;
    card.hidden = false; $('golive-n').textContent = `${done.length} di ${items.length} fatti`;
    const row = i => `<li class="gl ${i.done ? 'ok' : 'todo'}" data-k="${esc(i.key)}"><span class="ic">${i.done ? '✓' : '○'}</span><div>
        <b>${esc(i.label)}</b>${i.kind === 'manual' ? ' <small class="status">a mano</small>' : ''}
        ${i.done && i.done_by ? `<div class="status">fatto da ${esc(i.done_by)} il ${esc(new Date(i.done_at).toLocaleString('it-IT', { timeZone: 'Europe/Rome', day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' }))}</div>` : ''}
        ${!i.done && i.hint ? `<div class="status">${esc(i.hint)}</div>` : ''}${i.note ? `<div class="status">Nota: ${esc(i.note)}</div>` : ''}
        ${i.kind === 'manual' && sign ? `<button type="button" class="lnkbtn" data-gl="${i.done ? 'undo' : 'do'}">${i.done ? 'Annulla…' : 'Segna fatto…'}</button>
          <div class="glf nodirty" hidden><input type="text" maxlength="400" aria-label="Nota" placeholder="${i.done ? 'Perché si annulla?' : 'Cosa è stato fatto, dove sta il documento'}">
          <button type="button" class="btn sm" data-gl="ok">${i.done ? 'Annulla' : 'Segna fatto'}</button></div>` : ''}</div></li>`;
    $('golive').innerHTML = `<ul class="gll">${open.map(row).join('')}</ul>${done.length ? `<details><summary>Fatti (${done.length})</summary><ul class="gll">${done.map(row).join('')}</ul></details>` : ''}`;
    $('golive').querySelectorAll('[data-gl=do],[data-gl=undo]').forEach(b => b.onclick = () => { const f = b.parentElement.querySelector('.glf'); f.hidden = false; b.hidden = true; f.querySelector('input').focus(); });
    $('golive').querySelectorAll('[data-gl=ok]').forEach(b => b.onclick = () => UI.act(b, async () => {
      const li = b.closest('li'), it = items.find(x => x.key === li.dataset.k), note = li.querySelector('.glf input').value.trim();
      if (note.length < 3) { toast(it.done ? 'Scrivi perché si annulla' : 'Scrivi cosa è stato fatto e dove sta il documento', 'err'); return false; }
      if (!confirm(it.done ? `Annullare «${it.label}»? Torna da fare.` : `Segnare come fatto «${it.label}»?\n\nResta nel Registro con il tuo nome e la nota.`)) return false;
      const { error: e } = await sb.rpc('dash_set_check', { p_key: it.key, p_done: !it.done, p_note: note }); if (e) throw e;
      await loadGolive();
    }, it => 'Lista aggiornata'));
  }
  async function loadOverview() {
    ovAt = Date.now(); ovStale = false;
    const admin = PERM.isAdmin();
    const [st, eq, dl, vm, bots, un, people, lg, aud, hl, sc] = await Promise.all([
      PROWS.length ? { data: PROWS } : sb.from('settings').select('key, value, data_type, kind, description, sort'),
      sb.from('v_equipment_schedule').select('id, name, active, next_calibration_on, next_maintenance_on'),
      sb.from('compliance_deadlines').select('id, subject_it, due_on').is('done_on', null),
      sb.from('v_shopify_variant_map').select('label, product_sku, unmapped_lines'),
      sb.from('v_bot_dashboard').select('agent, name_it, active, last_status, last_severity, last_run_at, unread, unread_alerts, display_name, nickname'),
      sb.rpc('bot_bell'),
      sb.from('staff').select('id, full_name, email, active, auth_user_id'),
      admin ? sb.rpc('staff_logins') : Promise.resolve({ data: null }),
      sb.from('audit_log').select('at, actor, table_name, row_key, action, new_data, old_data').order('at', { ascending: false }).limit(6),
      Promise.resolve().then(() => sb.schema('public').rpc('fabula_health')).catch(e => ({ error: e })),
      PERM.can('sistema', 1) ? sb.rpc('system_checks') : Promise.resolve({ data: null }),   // v1.05 (audit E-14/E-28)
    ]);
    (st.data || []).forEach(r => { SETNAME[r.key] = r.description || r.key; });
    const cards = [];
    // Parametri: empty or provisional values, grouped by section
    if (st.error) cards.push({ id: 'par', tab: 'parametri', title: 'Parametri', st: 'na', big: '—', items: [{ txt: st.error.message }], foot: 'Apri i parametri' });
    else {
      const rows = st.data || [], titles = Object.fromEntries(SECTIONS.map(s => [s[0], s[1]])); titles.altro = 'Altri parametri';
      const bySec = {}; rows.forEach(r => { const a = attOf(r); if (!a) return; const s = SEC_OF[r.key.split('.')[0]] || 'altro'; (bySec[s] = bySec[s] || { empty: 0, conf: 0 })[a === 'da compilare' ? 'empty' : 'conf']++; });
      const items = Object.entries(bySec).sort((a, b) => (b[1].empty + b[1].conf) - (a[1].empty + a[1].conf)).map(([s, c]) => ({ st: c.empty ? 'al' : 'wn', sec: s,
        txt: `${titles[s] || s}: ${[c.empty ? plural(c.empty, 'valore vuoto', 'valori vuoti') : '', c.conf ? `${c.conf} da confermare` : ''].filter(Boolean).join(', ')}` }));
      const nE = rows.filter(r => attOf(r) === 'da compilare').length, nC = rows.filter(r => attOf(r) === 'da confermare').length;
      cards.push({ id: 'par', tab: items.length ? items[0].sec : 'parametri', title: 'Parametri', st: nE + nC ? 'wn' : 'ok', big: nE + nC || '✓',
        sub: nE + nC ? `${nE ? plural(nE, 'vuoto', 'vuoti') : ''}${nE && nC ? ' · ' : ''}${nC ? `${nC} da confermare` : ''} su ${rows.length}` : `${rows.length} parametri, tutti compilati`,
        items, foot: items.length ? `Apri ${titles[items[0].sec] || 'i parametri'}` : 'Apri i parametri' });
    }
    // Macchine e scadenze
    if (eq.error || dl.error) cards.push({ id: 'maint', tab: 'maint', title: 'Macchine e scadenze', st: 'na', big: '—', items: [{ txt: (eq.error || dl.error).message }], foot: 'Apri macchine e scadenze' });
    else { const m = maintStatus(eq.data, dl.data), items = m.items.filter(i => i.st !== 'ok').map(i => ({ st: i.st === 'late' ? 'al' : 'wn', txt: i.txt }));
      cards.push({ id: 'maint', tab: 'maint', title: 'Macchine e scadenze', st: m.late ? 'al' : m.soon || m.unset ? 'wn' : 'ok', big: m.late || m.soon || m.unset || '✓',
        sub: m.late ? `${m.late === 1 ? 'scaduta' : 'scadute'}${m.soon ? `, ${m.soon} entro 30 giorni` : ''}${m.unset ? `, ${m.unset} senza data` : ''}` : m.soon ? `entro 30 giorni${m.unset ? `, ${m.unset} senza data` : ''}` : m.unset ? 'senza data' : 'niente in scadenza nei prossimi 30 giorni',
        items, foot: 'Apri macchine e scadenze' }); }
    // Prodotti Shopify
    if (vm.error) cards.push({ id: 'prod', tab: 'prodotti', title: 'Prodotti Shopify', st: 'na', big: '—', items: [{ txt: vm.error.message }], foot: 'Apri prodotti Shopify' });
    else { const rows = vm.data || [], wait = rows.filter(r => r.unmapped_lines > 0), free = rows.filter(r => !r.product_sku && !(r.unmapped_lines > 0));
      cards.push({ id: 'prod', tab: 'prodotti', title: 'Prodotti Shopify', st: wait.length ? 'al' : rows.length ? 'ok' : 'na', big: wait.length || (rows.length ? '✓' : '—'),
        sub: wait.length ? `${wait.length === 1 ? 'variante' : 'varianti'} con ordini fermi · ${rows.length - wait.length - free.length} collegate` : rows.length ? `${rows.length - free.length} varianti collegate${free.length ? `, ${free.length} non scaricano il magazzino` : ''}` : 'nessuna variante ancora vista',
        items: wait.sort((a, b) => b.unmapped_lines - a.unmapped_lines).map(r => ({ st: 'al', txt: `${r.label}: ${plural(r.unmapped_lines, 'riga d\'ordine in attesa', 'righe d\'ordine in attesa')}` })), foot: 'Apri prodotti Shopify' }); }
    // Bot
    if (bots.error) cards.push({ id: 'bots', tab: 'bots', title: 'Bot', st: 'na', big: '—', items: [{ txt: bots.error.message }], foot: 'Apri i bot' });
    else { const bs = (bots.data || []).filter(b => b.active), name = b => b.display_name || b.name_it;
      const al = bs.filter(b => b.last_status === 'error' || b.unread_alerts > 0 || b.last_severity === 'alert'), wn = bs.filter(b => !al.includes(b) && b.last_severity === 'warn');
      const bl = un.data || {}, nA = Number(bl.alerts) || 0, nU = nA + (Number(bl.unread) || 0);   // v1.00: open alarms + what I have not read
      const items = [...al.map(b => ({ st: 'al', txt: `${name(b)}: ${b.last_status === 'error' ? 'ultima esecuzione fallita' : plural(b.unread_alerts || 1, 'allarme aperto', 'allarmi aperti')}` })), ...wn.map(b => ({ st: 'wn', txt: `${name(b)}: avviso da controllare` }))];
      cards.push({ id: 'bots', tab: 'bots', title: 'Bot', st: al.length ? 'al' : wn.length ? 'wn' : 'ok', big: al.length + wn.length || '✓',
        sub: al.length + wn.length ? `${al.length ? `${al.length} da sistemare` : ''}${al.length && wn.length ? ' · ' : ''}${wn.length ? `${wn.length} da controllare` : ''} · ${plural(nU, 'notifica da leggere', 'notifiche da leggere')}` : `${bs.length} attivi, in ordine · ${plural(nU, 'notifica da leggere', 'notifiche da leggere')}`,
        items, foot: 'Apri i bot' });
      badge('n-bots', nA); $('n-bots').title = 'allarmi aperti'; }
    // Utenti e accessi
    if (people.error) cards.push({ id: 'usr', tab: 'utenti', title: 'Utenti e accessi', st: 'na', big: '—', items: [{ txt: people.error.message }], foot: 'Apri utenti e accessi' });
    else { const ps = (people.data || []).filter(p => p.active), L = {}; ((lg && lg.data) || []).forEach(r => { L[r.staff_id] = r; });
      const items = []; ps.forEach(p => { const s = L[p.id] ? L[p.id].state : (p.auth_user_id ? 'attivo' : p.email ? 'da_invitare' : 'senza_email');
        if (s === 'link_scaduto' || s === 'senza_password') items.push({ st: 'wn', txt: `${p.full_name}: link scaduto o password mai scelta · mandagli un link di accesso` });
        else if (s === 'da_invitare') items.push({ st: 'wn', txt: `${p.full_name}: non ha ancora un accesso · mandagli il link` });
        else if (s === 'invitato') items.push({ st: 'ok', txt: `${p.full_name}: link mandato, deve ancora scegliere la password` });
        else if (s === 'senza_email') items.push({ st: 'wn', txt: `${p.full_name}: senza email (usa il tablet con badge e PIN, non entra in console)` }); });
      const wn = items.filter(i => i.st === 'wn').length;
      cards.push({ id: 'usr', tab: 'utenti', title: 'Utenti e accessi', st: wn ? 'wn' : 'ok', big: ps.length,
        sub: `${ps.length === 1 ? 'persona attiva' : 'persone attive'}${wn ? ` · ${plural(wn, 'accesso da sistemare', 'accessi da sistemare')}` : admin ? ' · accessi in ordine' : ''}`,
        items: items.sort((a, b) => (a.st === 'wn' ? 0 : 1) - (b.st === 'wn' ? 0 : 1)), foot: 'Apri utenti e accessi' });
      badge('n-usr', wn); $('n-usr').title = 'accessi da sistemare'; }
    // Sistema: app version seen online + the three booleans the outside watcher reads (public.fabula_health)
    { const sw = ((st.data || []).find(r => r.key === 'infra.sw_seen') || {}).value || '', [ver, since] = sw.split('|');
      const h = hl && !hl.error && hl.data ? hl.data : null, items = [];
      if (h) { if (!h.cron_ok) items.push({ st: 'al', txt: 'Attività programmate (pg_cron) ferme da oltre 20 minuti' }); if (!h.backup_ok) items.push({ st: 'al', txt: 'Nessun backup riuscito nelle ultime 26 ore' }); }
      else items.push({ st: 'wn', txt: 'Stato del database non letto' + (hl && hl.error ? `: ${hl.error.message || hl.error}` : '') });
      // v1.05 (audit E-28): the one-time set-ups and the other system checks, in Italian, with what to do
      const URGENT = new Set(['uptime', 'cron_jobs', 'vault_secret']);
      ((sc && !sc.error && sc.data) || []).filter(c => !c.done).forEach(c => items.push({ st: URGENT.has(c.key) ? 'al' : 'wn', txt: `${c.label_it}: ${c.detail || 'da controllare'}` }));
      const RK = { al: 0, wn: 1 }; items.sort((x, y) => (RK[x.st] ?? 2) - (RK[y.st] ?? 2));   // the card shows three: the urgent ones first
      if (ver) items.push({ st: 'ok', txt: `App in linea ${ver}${since ? ' dal ' + fmtD(since.slice(0, 10)) : ''}` });
      const nAl = items.filter(i => i.st === 'al').length, nW = items.filter(i => i.st === 'wn').length;   // v1.05: a warning is not «in ordine»
      cards.push({ id: 'sys', tab: 'sistema', title: 'Sistema', st: h ? (nAl ? 'al' : nW ? 'wn' : 'ok') : 'wn', big: h ? (nAl || nW || '✓') : '?',
        sub: h ? (nAl ? 'da sistemare' : nW ? 'da controllare' : 'database, attività programmate e backup in ordine') : 'stato non disponibile', items, foot: 'Apri i parametri di sistema' }); }
    $('ov').innerHTML = cards.map(ovCard).join('');
    loadGolive().catch(e => { const b = $('golive'); if (b) b.innerHTML = `<div class="status">${esc(e.message || String(e))}</div>`; });
    const nAl = cards.filter(c => c.st === 'al').length, nWn = cards.filter(c => c.st === 'wn').length;
    const big = $('ov-big'); big.className = 'big ' + (nAl ? 'al' : nWn ? 'wn' : 'ok');
    big.textContent = nAl ? `${plural(nAl, 'area da sistemare', 'aree da sistemare')}${nWn ? `, ${nWn} da controllare` : ''}` : nWn ? `Tutto funziona · ${plural(nWn, 'area da controllare', 'aree da controllare')}` : 'Tutto in ordine';
    $('ov-when').textContent = `aggiornato alle ${new Date().toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Rome' })}`;
    badge('n-ov', nAl); $('n-ov').title = 'aree da sistemare';
    // last changes
    const box = $('ov-last'), rows = aud.data || [];
    const label = r => { const d = r.new_data || r.old_data || {}; return r.table_name === 'settings' ? settingName(r.row_key) : d.summary || d.full_name || d.name || d.name_it || d.code || d.subject_it || d.po_number || d.work_date || (r.row_key || '').slice(0, 8); };
    box.innerHTML = aud.error ? `<div class="empty">${esc(aud.error.message)}</div>` : !rows.length ? '<div class="empty">Nessuna modifica registrata.</div>'
      : `<table><tr><th>Quando</th><th>Chi</th><th>Dove</th><th>Cosa</th></tr>${rows.map(r => `<tr><td class="nw">${new Date(r.at).toLocaleString('it-IT', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Rome' })}</td><td>${esc(r.actor)}</td><td>${esc(AUD_T[r.table_name] || r.table_name)}</td><td>${esc(label(r))} <small class="status">${esc(AUD_A[r.action] || r.action)}</small></td></tr>`).join('')}</table>`;
  }

  // ---------- Avvisi su Telegram (v0.96, audit E-01) ----------
  // Each person links their own Telegram (or the owner makes the link for them); the alerts then reach the phone with
  // «Me ne occupo io». Owner/partners also see who is linked and the last alerts with who took them.
  // v1.02b (E-07): at night only food safety and «system down» go out at once; the rest waits for the end of the silence
  const NT_TOPICS = [['food_safety', 'Sicurezza alimentare', 'a qualsiasi ora'], ['infra', 'Sistema: backup, bot, tablet', 'subito solo se il sistema è giù, il resto dopo il silenzio'], ['decisions', 'Decisioni da prendere (latte, promo, ingrosso)', 'non nelle ore di silenzio']];
  const NT_TZ = [['Europe/Rome', 'ora italiana'], ['America/New_York', 'ora della costa est USA']];
  const ntTime = s => new Date(s).toLocaleString('it-IT', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Rome' });
  function ntLinkBox(box, d, forOther) {
    const exp = new Date(d.expires).toLocaleString('it-IT', { weekday: 'short', day: 'numeric', month: 'numeric', hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Rome' });   // v1.09: a week, so the date too
    const text = `Ciao ${String(d.staff || '').split(' ')[0]}, per ricevere gli avvisi del caseificio su Telegram apri questo link sul telefono e tocca «Avvia» (vale fino a ${exp}, una volta sola):\n${d.url}`;
    box.innerHTML = `<div class="hint">${forOther ? `Collegamento per <b>${esc(d.staff)}</b>: mandaglielo.` : 'Inquadra il codice col telefono, oppure apri il link <b>sul telefono</b>,'} poi in Telegram tocca <b>Avvia</b> (Start). Vale fino a ${esc(exp)}, una volta sola.</div>
      <div class="row" style="gap:10px;align-items:center;flex-wrap:wrap"><div class="nt-qr" style="background:#fff;padding:6px"></div>
      <div style="flex:1;min-width:220px"><input readonly style="width:100%" value="${esc(d.url)}"><div class="row" style="gap:6px;margin-top:6px">
      <button class="btn sm sec" data-copy>Copia</button><a class="btn sm" style="text-decoration:none" target="_blank" rel="noopener" href="https://wa.me/?text=${encodeURIComponent(text)}">Manda su WhatsApp</a>
      <a class="btn sm sec" style="text-decoration:none" target="_blank" rel="noopener" href="${esc(d.url)}">Apri</a></div></div></div>`;
    try { if (window.QRCode) new QRCode(box.querySelector('.nt-qr'), { text: d.url, width: 132, height: 132 }); } catch {}
    box.querySelector('[data-copy]').onclick = async () => { try { await navigator.clipboard.writeText(d.url); toast('Link copiato'); } catch { box.querySelector('input').select(); } };
  }
  async function loadNotify() {
    const meBox = $('notify-me'), allBox = $('notify-all'); if (!meBox) return;
    const { data: ov, error } = await sb.rpc('notify_overview');
    if (error) { meBox.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    const me = ov.me;
    if (!me || !me.linked) {
      meBox.innerHTML = `<p style="margin:6px 0">${me && me.link_pending ? 'Collegamento creato ma non ancora aperto sul telefono.' : 'Il tuo Telegram non è ancora collegato: gli allarmi arrivano solo qui in Configurazione.'}</p>
        <button class="btn save" id="nt-link">Collega il mio Telegram</button><div id="nt-linkout" style="margin-top:8px"></div>`;
      $('nt-link').onclick = async () => { const { data, error } = await sb.rpc('notify_link_code'); if (error) return toast(error.message, 'err'); ntLinkBox($('nt-linkout'), data, false); };
    } else {
      const tzs = NT_TZ.some(([v]) => v === me.tz) ? NT_TZ : [...NT_TZ, [me.tz, me.tz]];
      meBox.innerHTML = `<p style="margin:6px 0"><span class="ok">Collegato</span>${me.tg_name ? ' (' + esc(me.tg_name) + ')' : ''}${me.linked_at ? ' dal ' + esc(ntTime(me.linked_at)) : ''}. Ricevo:</p>
        ${NT_TOPICS.map(([k, l, h]) => `<label style="display:block;text-transform:none;letter-spacing:0;font-weight:400;margin:4px 0"><input type="checkbox" data-topic="${k}"${(me.topics || []).includes(k) ? ' checked' : ''}> ${l} <small class="status">· ${h}</small></label>`).join('')}
        <div class="hint">Il responsabile HACCP e chi è in turno ricevono comunque la sicurezza alimentare.</div>
        <div class="row" style="align-items:center;gap:6px;flex-wrap:wrap;margin-top:6px">Silenzio dalle <input type="time" id="nt-qf" value="${esc(me.quiet_from)}"> alle <input type="time" id="nt-qt" value="${esc(me.quiet_to)}">
          <select id="nt-tz" aria-label="Fuso orario">${tzs.map(([v, l]) => `<option value="${esc(v)}"${v === me.tz ? ' selected' : ''}>${esc(l)}</option>`).join('')}</select></div>
        <div class="row" style="align-items:center;gap:6px;flex-wrap:wrap;margin-top:6px">Riepilogo ogni giorno alle <input type="time" id="nt-dg" value="${esc(me.digest_at || '')}" aria-label="Ora del riepilogo">
          <small class="status">decisioni in attesa, allarmi aperti, novità e approvazioni automatiche in un solo messaggio · vuoto = nessun riepilogo</small></div>
        <div class="row" style="gap:6px;margin-top:8px"><button class="btn save" id="nt-save">Salva</button><button class="btn sec" id="nt-test">Manda un messaggio di prova</button><button class="btn warn" id="nt-unlink">Scollega</button></div>`;
      $('nt-save').onclick = async () => {
        const topics = [...meBox.querySelectorAll('[data-topic]')].filter(x => x.checked).map(x => x.dataset.topic);
        const { error } = await sb.rpc('notify_set_prefs', { p_topics: topics, p_quiet_from: $('nt-qf').value || null, p_quiet_to: $('nt-qt').value || null, p_tz: $('nt-tz').value, p_digest_at: $('nt-dg').value || '' });
        if (error) return toast(error.message, 'err'); toast('Salvato'); loadNotify();
      };
      $('nt-test').onclick = async () => { const { error } = await sb.rpc('notify_test'); if (error) return toast(error.message, 'err'); toast('Messaggio di prova in partenza: arriva entro un minuto'); };
      $('nt-unlink').onclick = async () => { if (!confirm('Scollegare il tuo Telegram? Non riceverai più gli allarmi sul telefono.')) return; const { error } = await sb.rpc('notify_unlink'); if (error) return toast(error.message, 'err'); toast('Scollegato'); loadNotify(); };
    }
    if (!ov.people) { allBox.innerHTML = ''; return; }
    const TL = { food_safety: 'sicurezza', infra: 'sistema', decisions: 'decisioni' };
    allBox.innerHTML = `<h4 style="margin:10px 0 4px">Chi riceve gli avvisi</h4><table><tr><th>Persona</th><th>Telegram</th><th>Riceve</th><th>Ultimo avviso</th><th></th></tr>${ov.people.map(p => `
      <tr><td><b>${esc(p.full_name)}</b>${p.haccp_resp ? '<br><small>responsabile HACCP</small>' : ''}</td>
      <td>${p.linked ? '<span class="ok">collegato</span>' : '<span class="ko">non collegato</span>'}${p.failed_24h ? `<br><small class="ko">${p.failed_24h} non consegnati</small>` : ''}</td>
      <td>${p.linked ? esc((p.topics || []).map(t => TL[t] || t).join(', ')) : '—'}</td><td class="nw">${p.last_sent ? esc(ntTime(p.last_sent)) : '—'}</td>
      <td>${p.linked ? '' : `<button class="btn sm sec" data-ntlink="${p.staff_id}">Link da mandare</button>`}</td></tr>`).join('')}</table><div id="nt-otherlink" style="margin-top:8px"></div>
      <h4 style="margin:14px 0 4px">Ultimi allarmi</h4>${(ov.recent || []).length ? `<table><tr><th>Quando</th><th>Cosa</th><th>Inviati</th><th>Chi se ne occupa</th></tr>${ov.recent.map(r => `
      <tr><td class="nw">${esc(ntTime(r.created_at))}</td><td><small class="status">${esc(TL[r.topic] || r.topic)}</small> ${esc(r.title)}</td>
      <td>${r.sent}${r.waiting ? ` <small>(+${r.waiting} in attesa)</small>` : ''}${r.failed ? ` <small class="ko">${r.failed} non consegnati</small>` : ''}</td>
      <td>${r.taken_by ? esc(r.taken_by) + ' · ' + esc(ntTime(r.acked_at)) : r.acked_at ? 'chiuso da solo · ' + esc(ntTime(r.acked_at)) : r.topic === 'infra' ? '—' : '<span class="ko">nessuno</span>'}</td></tr>`).join('')}</table>` : '<div class="empty">Nessun allarme inviato finora.</div>'}`;
    allBox.querySelectorAll('[data-ntlink]').forEach(b => b.onclick = async () => {
      const { data, error } = await sb.rpc('notify_link_code', { p_staff_id: b.dataset.ntlink }); if (error) return toast(error.message, 'err');
      ntLinkBox($('nt-otherlink'), data, true);
    });
  }

  // ---------- Link della Masseria (v1.03, audit FARM-04 + C-05) ----------
  // The two keys are made by the database (32 random hex characters) and never typed: «Genera nuovo …» replaces one at once.
  async function loadFarmLinks() {
    const box = $('farm-links'); if (!box) return;
    if (!canEdit()) { box.innerHTML = '<div class="status">Li vede e li cambia solo chi gestisce il sistema (titolare e soci).</div>'; return; }
    const { data: L, error } = await sb.rpc('farm_links');
    if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    if (!L) { box.innerHTML = '<div class="status">Link non disponibili.</div>'; return; }
    const abs = u => u ? new URL(u, location.href).href : '';
    const full = abs(L.full), qr = abs(L.qr), poster = abs(L.poster);
    const since = (t, what) => t ? `${what} ${fmtD(String(t).slice(0, 10))}` : '';
    const used = (t, what) => t ? ` · ${what} ${new Date(t).toLocaleString('it-IT', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Rome' })}` : '';
    const wa = `https://wa.me/?text=${encodeURIComponent(`Buongiorno, questo è il nuovo link per gli ordini e le spedizioni di latte del caseificio (quello vecchio non funziona più). Salvalo sul telefono e non inoltrarlo:
${full}`)}`;
    box.innerHTML = `
      <div style="margin:10px 0 4px"><b>Link completo</b> · per il titolare della Masseria</div>
      <div class="hint keep">Ordini del caseificio, ultimi 30 giorni, correzioni e «Visto». Chi ha questo link può registrare e correggere spedizioni: mandalo solo al titolare della Masseria.</div>
      ${full ? `<div class="row" style="gap:6px;flex-wrap:wrap;align-items:center"><a class="btn sm sec" style="text-decoration:none" target="_blank" rel="noopener" href="${esc(full)}">Apri</a><button class="btn sm sec" data-fcopy>Copia</button>
        <a class="btn sm sec" style="text-decoration:none" target="_blank" rel="noopener" href="${esc(wa)}">Manda su WhatsApp</a><button class="btn sm warn" data-frot="full">Genera nuovo link</button>
        <small class="status">${since(L.full_changed_at, 'cambiato il')}${used(L.full_last_used_at, 'ultima spedizione da qui')}</small></div>` : '<div class="status">Link non ancora creato: <button class="btn sm" data-frot="full">Genera il link</button></div>'}
      <div style="margin:16px 0 4px"><b>QR in stalla</b> · solo spedizioni</div>
      <div class="hint keep">Chi lo inquadra può solo registrare una spedizione e correggere entro 2 ore quella che ha registrato; non vede ordini né storico. Il poster va appeso dove si carica il latte.</div>
      ${poster ? `<div class="row" style="gap:6px;flex-wrap:wrap;align-items:center"><a class="btn sm" style="text-decoration:none" target="_blank" rel="noopener" href="${esc(poster)}" data-fposter>🖨 Stampa il poster</a>
        <a class="btn sm sec" style="text-decoration:none" target="_blank" rel="noopener" href="${esc(qr)}">Apri</a><button class="btn sm warn" data-frot="qr">Genera nuovo QR</button>
        <small class="status">${since(L.qr_changed_at, 'cambiato il')}${used(L.qr_last_used_at, 'ultima spedizione dal QR')}</small></div>` : '<div class="status">QR non ancora creato: <button class="btn sm" data-frot="qr">Genera il QR</button></div>'}
      <div id="farm-rot-msg"></div>
      <div style="margin:16px 0 4px"><b>Chi spedisce</b></div>
      <div class="hint keep">Nomi di chi registra le spedizioni alla Masseria, separati da virgola. La pagina chiede chi spedisce e lo ricorda sul telefono; ogni spedizione porta il nome (anche sul tablet all'arrivo). Vuoto = scrivono il nome a mano.</div>
      <div class="row" style="gap:6px;align-items:center;flex-wrap:wrap"><input id="farm-people" type="text" style="flex:1;min-width:220px" maxlength="300" placeholder="es. Mario, Luca, Giovanni" value="${esc(L.people_text || '')}"><button class="btn save" id="farm-people-save">Salva</button></div>`;
    const cp = box.querySelector('[data-fcopy]');
    if (cp) cp.onclick = async () => { try { await navigator.clipboard.writeText(full); toast('Link copiato: mandalo solo al titolare della Masseria'); } catch { prompt('Copia il link:', full); } };
    box.querySelectorAll('[data-frot]').forEach(b => b.onclick = async () => {
      const which = b.dataset.frot;
      const sure = which === 'full'
        ? 'Generare un nuovo link completo per la Masseria?\nQuello attuale smette di funzionare subito: va mandato il nuovo al titolare della Masseria («Manda su WhatsApp»).'
        : 'Generare un nuovo QR per le spedizioni?\nIl poster appeso alla Masseria smette di funzionare subito: stampa il nuovo e sostituiscilo.';
      if ((L.full && which === 'full') || (L.poster && which === 'qr')) { if (!confirm(sure)) return; }
      b.disabled = true;
      const { error: e2 } = await sb.rpc('farm_link_rotate', { p_which: which });
      if (e2) { b.disabled = false; return toast(e2.message, 'err'); }
      await loadFarmLinks();
      const msg = $('farm-rot-msg');
      if (msg) msg.innerHTML = which === 'full'
        ? '<div style="margin-top:10px;padding:10px 12px;border:1px solid #e0b252;background:#fff4dc;border-radius:8px;color:#5d4300">Nuovo link creato: il vecchio non funziona più. Mandalo ora al titolare della Masseria con «Manda su WhatsApp».</div>'
        : '<div style="margin-top:10px;padding:10px 12px;border:1px solid #e0b252;background:#fff4dc;border-radius:8px;color:#5d4300">Nuovo QR creato: il poster appeso non funziona più. Stampa il nuovo con «🖨 Stampa il poster» e sostituiscilo.</div>';
      toast(which === 'full' ? 'Nuovo link della Masseria creato' : 'Nuovo QR spedizioni creato');
    });
    $('farm-people-save').onclick = async () => {
      const v = $('farm-people').value.split(/[,;\n]/).map(x => x.replace(/\s+/g, ' ').trim()).filter(Boolean).join(', ');
      try { PERM.changed(await sb.from('settings').update({ value: v }).eq('key', 'milk.farm_people').select('key')); toast('Salvato'); loadFarmLinks(); }
      catch (e) { toast(e.message || String(e), 'err'); }
    };
  }

  const openFermi = () => { const d = $('bd-fermi'); if (!d) return; d.open = true; setTimeout(() => d.scrollIntoView({ behavior: 'smooth', block: 'start' }), 150); };
  // ---------- tabs + start ----------
  const SEC_IDS = SECTIONS.map(s => s[0]).concat('altro');
  const T = UI.tabs({
    def: 'panoramica', alias: Object.assign({ account: 'utenti', telegram: 'utenti', masseria: 'utenti' }, Object.fromEntries(SEC_IDS.map(s => [s, 'parametri']))),
    loaders: { panoramica: loadOverview, parametri: loadParams, maint: loadMaint, prodotti: loadVariantMap, bots: loadBotFeed, utenti: loadUsers, registro: loadAudit },
    onHash: p => { if ('fermi' in p) openFermi(); if ('masseria' in p) setTimeout(() => { const c = $('farm-card'); if (c) c.scrollIntoView({ behavior: 'smooth', block: 'start' }); }, 400); },   // v1.00 (E-20): admin.html#bots&fermi opens «Bot fermi: cosa fare»; v1.03: #utenti&masseria the farm links
    onShow: n => { if (n === 'panoramica' && T.isLoaded('panoramica') && (ovStale || Date.now() - ovAt > 120000)) loadOverview().catch(err => toast(err.message || String(err), 'err')); }
  });
  // a link to a section (#vendite, #sistema…) opens Parametri on that section — from other pages and from the Panoramica cards
  const openSection = h => { if (!SEC_IDS.includes(h)) return; if (PROWS.length) { curSec = h; $('p-q').value = ''; renderParams(); } else pendingSection = h; };
  window.addEventListener('hashchange', () => openSection(UI.hashTab()));
  async function refresh() {
    if ((UI.unsaved() || PROWS.some(r => String(r.value) !== String(r.orig))) && !confirm('Ci sono modifiche non salvate: aggiornando le perdi. Continuare?')) return false;
    document.querySelectorAll('.dirty').forEach(e => e.classList.remove('dirty'));
    await T.reload(); UI.bellCount();
  }
  UI.boot({
    page: 'admin', onRefresh: refresh,
    onReady: async s => {
      staff = s;
      const h = (location.hash || '').slice(1);
      if (SEC_IDS.includes(h)) pendingSection = h;
      T.start();
      if (h === 'account') setTimeout(() => { $('account').scrollIntoView({ block: 'start' }); UI.changePassword(); }, 150);
      // counts for the tabs that are not open yet (the Panoramica fills the rest)
      if (!T.isLoaded('maint')) loadMaint(); if (!T.isLoaded('prodotti')) sb.from('v_shopify_variant_map').select('unmapped_lines').then(({ data }) => badge('n-prod', (data || []).filter(r => r.unmapped_lines).length));
      if (!T.isLoaded('panoramica')) loadOverview().catch(() => {});
    }
  });
})();
