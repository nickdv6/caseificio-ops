/* Configuration page (v0.51), separate from the operational console. Tabs: Parametri (every fabula.settings row, grouped by key
   prefix, searchable, one "Salva tutto" bar; groups not listed in SECTIONS show under "Altri parametri" so no setting is ever hidden) ·
   Macchine e scadenze · Prodotti Shopify · Bot (status cards, notification feed, run log) · Utenti e accessi (people, profiles,
   own password) · Registro modifiche. Shared shell (login, header, tabs, helpers) in ui.js. */
(() => {
  const { sb, $, esc, fmtD, nOrNull, dOrNull, toast, badge, upd, saveBtn } = UI;
  let staff = null;
  const dueCls = s => { if (!s) return ''; const d = (new Date(s) - new Date(UI.romeISO())) / 864e5; return d <= 30 ? 'ko' : ''; };

  // ---------- Parametri ----------
  // [anchor, title, key prefixes, explanation]. Old links (#azienda, #produzione, #vendite, #utenze, #lavoro) land on their section.
  const SECTIONS = [
    ['azienda', 'Azienda', ['company'], "Intestazione di ordini e documenti stampati. Inserisci i dati dell'acquirente (non quelli del venditore) quando la società è definita. Il nome commerciale cambia subito intestazioni e titoli di tutte le pagine."],
    ['produzione', 'Produzione e latte', ['milk', 'farm'], 'Come il bot Piano latte dimensiona il latte del giorno dopo. I kg disponibili giorno per giorno si correggono in <a class="lnk" href="console.html#ops">Console → Operazioni</a>.'],
    ['acquisti', 'Acquisti', ['purchasing'], 'Quando il bot Acquisti propone un ordine. Tempi e minimi per singolo fornitore: <a class="lnk" href="console.html#anag">Console → Anagrafiche</a>.'],
    ['vendite', 'Vendite e prezzi', ['price', 'sell', 'sales'], 'Prezzi di riferimento, soglie del bot Vendere prima (lotti in scadenza) e obiettivi del bot Vendite.'],
    ['canali', 'Shopify, ritiri e spedizioni', ['shopify', 'pickup', 'ship'], 'Shopify è la cassa e il sito: le vendite arrivano ogni mattina (bot Ordini Shopify). Fasce di ritiro (anche in Marketing) e vettori/tolleranze usati dal tablet in spedizione.'],
    ['marketing', 'Marketing', ['mkt'], 'Usati dal bot Marketing e dalle bozze dei contenuti.'],
    ['sicurezza', 'Sicurezza alimentare', ['food'], 'Latte crudo o pastorizzato (attiva il CCP 2), laboratorio e data di avvio del piano campionamenti: da quella data il bot del martedì prepara la richiesta al laboratorio. Regole complete nel <a class="lnk" href="haccp.html">Manuale di Autocontrollo</a>.'],
    ['utenze', 'Utenze e reflui', ['energy', 'effluent'], 'Tariffe da bolletta (entrano nel costo pieno al kg e nel pacchetto mensile) e stime dei reflui per giorno di produzione, confrontate con il registro 💧 Reflui del tablet.'],
    ['lavoro', 'Lavoro', ['labor'], 'Costo orario e regole per ore e straordinari (<a class="lnk" href="console.html#personale">Console → Personale</a>).'],
    ['benchmark', 'Benchmark economici', ['opex', 'benchmark'], 'Usati dal brief settimanale finché non arriva la contabilità reale.'],
  ];
  const SEC_OF = Object.fromEntries(SECTIONS.flatMap(([id, , g]) => g.map(p => [p, id])));
  const canEdit = () => PERM.can('sistema', 3);
  let PROWS = [], pendingSection = null;
  // field kind from the setting itself: 0/1 switches, dates, months, numbers, free text
  const kindOf = r => {
    const d = r.description || '';
    if (r.data_type === 'number' && /\(1\s*=\s*s[iì]/i.test(d)) return 'flag';
    if (r.data_type === 'number') return 'number';
    if (/AAAA-MM-01/.test(d)) return 'month';
    if (/AAAA-MM-GG/.test(d)) return 'date';
    return 'text';
  };
  const shown = (r, v) => { const k = kindOf(r); if (v === '' || v == null) return 'vuoto'; if (k === 'flag') return Number(v) === 1 ? 'sì' : 'no'; if (k === 'date') return fmtD(v); return v; };
  async function loadParams() {
    const { data, error } = await sb.from('settings').select('*').order('key');
    if (error) { $('p-secs').innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    PROWS = (data || []).map(r => ({ ...r, orig: r.value ?? '' }));
    renderParams();
  }
  function renderParams() {
    const edit = canEdit(); $('p-ro').hidden = edit;
    const extra = [...new Set(PROWS.map(r => r.key.split('.')[0]).filter(p => !SEC_OF[p]))];
    const secs = [...SECTIONS, ...(extra.length ? [['altro', 'Altri parametri', extra, 'Parametri senza una sezione dedicata (nuovi o tecnici).']] : [])];
    const host = $('p-secs'); host.innerHTML = '';
    secs.forEach(([id, title, groups, hint]) => {
      const mine = PROWS.filter(r => groups.includes(r.key.split('.')[0])).sort((a, b) => groups.indexOf(a.key.split('.')[0]) - groups.indexOf(b.key.split('.')[0]) || (a.sort ?? 100) - (b.sort ?? 100) || a.key.localeCompare(b.key));
      if (!mine.length) return;
      const card = document.createElement('div'); card.className = 'card psec'; card.id = 'sec-' + id; card.dataset.title = title;
      card.innerHTML = `<h3>${esc(title)}</h3><div class="hint">${hint}</div>`;
      mine.forEach(r => card.append(paramRow(r, edit)));
      host.append(card);
    });
    $('p-jump').innerHTML = [...host.querySelectorAll('.psec')].map(c => `<a href="#${c.id.slice(4)}" data-sec="${c.id}">${esc(c.dataset.title)}<span class="n" hidden></span></a>`).join('');
    $('p-jump').querySelectorAll('a').forEach(a => a.onclick = e => { e.preventDefault(); $(a.dataset.sec).scrollIntoView({ behavior: 'smooth', block: 'start' }); });
    filterParams(); saveState();
    if (pendingSection && $('sec-' + pendingSection)) { const s = pendingSection; pendingSection = null; setTimeout(() => $('sec-' + s).scrollIntoView({ block: 'start' }), 50); }
  }
  // v0.60: month settings typed as MM/AAAA (browsers without a month picker) become AAAA-MM-01, not "11/2026-01"
  const monthVal = v => { const t = String(v || '').trim(); if (!t) return ''; let m = t.match(/^(\d{4})-(\d{1,2})/); if (m) return `${m[1]}-${m[2].padStart(2, '0')}-01`; m = t.match(/^(\d{1,2})[\/.-](\d{4})$/); return m ? `${m[2]}-${m[1].padStart(2, '0')}-01` : t; };
  function paramRow(r, edit) {
    const k = kindOf(r), row = document.createElement('div'); row.className = 'set-row' + (k === 'text' ? ' text' : ''); row.dataset.key = r.key;
    row.innerHTML = `<div class="lbl">${esc(r.description || r.key)}<small>${esc(r.key)}</small><span class="was" hidden></span></div>`;
    let inp;
    if (k === 'flag') { inp = document.createElement('select'); inp.innerHTML = '<option value="1">Sì</option><option value="0">No</option>'; inp.value = Number(r.value) === 1 ? '1' : '0'; }
    else { inp = document.createElement('input'); inp.type = k === 'date' ? 'date' : k === 'month' ? 'month' : 'text';
      inp.value = k === 'month' ? String(r.value || '').slice(0, 7) : (r.value ?? '');
      if (k === 'number') { inp.inputMode = 'decimal'; inp.style.textAlign = 'right'; }
      if (k === 'text') { inp.className = 'wide'; inp.placeholder = '—'; } }
    inp.disabled = !edit; inp.setAttribute('aria-label', r.description || r.key);
    const val = () => k === 'month' ? monthVal(inp.value) : k === 'number' ? (inp.value.trim() === '' ? '' : String(UI.parseIt(inp.value))) : inp.value.trim();   // v0.60: 1.300 = 1300; "11/2026" = 2026-11
    const sync = () => { r.value = val(); const dirty = String(r.value) !== String(r.orig) && !(k === 'number' && r.value !== '' && Number(r.value) === Number(r.orig));
      row.classList.toggle('dirty', dirty); const w = row.querySelector('.was'); w.hidden = !dirty; w.textContent = 'prima: ' + shown(r, r.orig); saveState(); };
    inp.oninput = sync; inp.onchange = sync;
    inp.onkeydown = e => { if (e.key === 'Enter') { e.preventDefault(); saveParams().catch(err => toast(err.message || String(err), 'err')); } if (e.key === 'Escape') { inp.value = k === 'month' ? String(r.orig).slice(0, 7) : k === 'flag' ? (Number(r.orig) === 1 ? '1' : '0') : r.orig; sync(); } };
    const right = document.createElement('div'); right.className = 'row'; right.style.marginTop = '0'; right.append(inp); row.append(right);
    return row;
  }
  function saveState() {
    const dirty = PROWS.filter(r => String(r.value) !== String(r.orig) && !(kindOf(r) === 'number' && r.value !== '' && Number(r.value) === Number(r.orig)));
    $('p-save').hidden = !dirty.length; $('p-save-n').textContent = dirty.length === 1 ? '1 modifica non salvata' : `${dirty.length} modifiche non salvate`;
    badge('n-par', dirty.length);
    document.querySelectorAll('#p-jump a').forEach(a => { const n = $(a.dataset.sec).querySelectorAll('.set-row.dirty').length, s = a.querySelector('.n'); s.hidden = !n; s.textContent = n; });
    return dirty;
  }
  async function saveParams() {
    const dirty = saveState(); if (!dirty.length) return;
    for (const r of dirty) {
      const k = kindOf(r);
      if (k === 'number' && (r.value === '' || isNaN(Number(r.value)))) { focusRow(r.key); throw new Error(`"${r.description || r.key}": inserisci un numero`); }
      if ((k === 'date' || k === 'month') && r.value && !/^\d{4}-\d{2}-\d{2}$/.test(r.value)) { focusRow(r.key); throw new Error(`"${r.description || r.key}": data non valida`); }
    }
    const res = await Promise.all(dirty.map(r => { const v = kindOf(r) === 'number' ? String(Number(r.value)) : r.value; return sb.from('settings').update({ value: v }).eq('key', r.key).select('key').then(x => ({ r, v, ...x })); }));
    const bad = res.filter(x => x.error || !(x.data || []).length);
    res.filter(x => !x.error && (x.data || []).length).forEach(({ r, v }) => { r.orig = v; r.value = v; if (r.key.startsWith('company.')) BRAND.set({ [r.key]: v }); });
    renderParams();
    if (bad.length) throw new Error(`${bad.length} non salvati: ${bad[0].error ? bad[0].error.message : 'permesso negato'} (${bad.map(x => x.r.key).join(', ')})`);
    toast(res.length === 1 ? 'Parametro salvato' : `${res.length} parametri salvati`);
  }
  const focusRow = key => { const row = document.querySelector(`.set-row[data-key="${CSS.escape(key)}"]`); if (row) { row.scrollIntoView({ block: 'center' }); const i = row.querySelector('input, select'); if (i) i.focus(); } };
  function filterParams() {
    const q = $('p-q').value.trim().toLowerCase(); let any = false;
    document.querySelectorAll('#p-secs .psec').forEach(sec => {
      let n = 0;
      sec.querySelectorAll('.set-row').forEach(row => {
        const r = PROWS.find(x => x.key === row.dataset.key) || {};
        const hit = !q || [r.key, r.description, r.value, sec.dataset.title].some(x => String(x || '').toLowerCase().includes(q));
        row.hidden = !hit; row.classList.toggle('hit', !!q && hit); if (hit) n++;
      });
      sec.hidden = !n; if (n) any = true;
    });
    document.querySelectorAll('#p-jump a').forEach(a => { a.hidden = $(a.dataset.sec).hidden; });
    $('p-none').hidden = any;
  }
  $('p-q').oninput = filterParams;
  $('p-go').onclick = () => UI.act($('p-go'), saveParams);
  $('p-undo').onclick = () => { PROWS.forEach(r => { r.value = r.orig; }); renderParams(); };
  window.addEventListener('beforeunload', e => { if (PROWS.some(r => String(r.value) !== String(r.orig))) { e.preventDefault(); e.returnValue = ''; } });

  // ---------- Macchine e scadenze ----------
  async function loadMaint() {
    const [e, d] = await Promise.all([sb.from('v_equipment_schedule').select('*'), sb.from('compliance_deadlines').select('*').is('done_on', null).order('due_on', { nullsFirst: false })]);
    if (e.error || d.error) { toast((e.error || d.error).message, 'err'); return; }
    renderEquipment(e.data || []); renderDeadlines(d.data || []);
    const today = UI.romeISO(), late = (d.data || []).filter(x => x.due_on && x.due_on < today).length + (e.data || []).filter(x => x.active && [x.next_calibration_on, x.next_maintenance_on].some(v => v && v < today)).length;
    badge('n-maint', late); $('n-maint').title = 'scadenze o tarature già passate';
  }
  // ---------- Bot dashboard: every bot notification (bot_messages) ----------
  let bdFilter = 'unread', bdAgent = null, bdLimit = 50, bdNames = {}, bdNick = {};
  // v0.46 display-only nicknames (Zio/Zia) from bot_nicknames; agent keys never change
  async function loadNicknames() { const { data } = await sb.from('bot_nicknames').select('agent, nickname, title_it, avatar_url'); (data || []).forEach(n => { bdNick[n.agent] = n; }); }
  // avatar slot: image when bot_nicknames.avatar_url is set, otherwise a dashed circle with the initial
  const botAvatar = agent => { const n = bdNick[agent]; if (n && n.avatar_url) return `<div class="bav img" aria-hidden="true"><img src="${esc(n.avatar_url)}" alt="" loading="lazy"></div>`;
    const w = String(n ? n.nickname : agent).replace(/^(zio|zia)\s+/i, '').trim(); return `<div class="bav" aria-hidden="true">${esc((w[0] || '?').toUpperCase())}</div>`; };
  const botLabel = (agent, base) => { const n = bdNick[agent]; return n ? `${n.nickname} · ${base || n.title_it}` : (base || agent); };
  // Bot dashboard redesign (03/10): status summary on top, bots grouped by status (da sistemare → da controllare → in ordine → disattivati),
  // one card per bot (Zio Vito and Zio Nino are now two cards), plain-language times ("3 ore fa", "domani 06:05").
  const SYS = { bot_watchdog: { agents: ['bot_watchdog', 'avvisi'], role: 'Allarme bot', sched: 'ogni ora · :50, 06:50–21:50 lun–sab', times: Array.from({ length: 16 }, (_, i) => String(6 + i).padStart(2, '0') + ':50'), wd: [1, 2, 3, 4, 5, 6] },
                bot_heartbeat: { agents: ['bot_heartbeat'], role: 'Battito bot', sched: 'ogni ora · :25', times: Array.from({ length: 24 }, (_, i) => String(i).padStart(2, '0') + ':25'), wd: [1, 2, 3, 4, 5, 6, 7] },
                produzione: { agents: ['produzione'], role: 'Resa produzione', sched: 'alla chiusura di ogni lotto', times: [], wd: [], okLine: 'Nessuna resa fuori norma' },   // v0.70
                auto_approve: { agents: ['auto_approve'], role: 'Approvazioni automatiche', sched: 'ogni 10 minuti · turni il sabato', times: [], wd: [], okLine: 'Nessuna approvazione automatica da leggere' } };   // v0.73
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
  async function loadBotFeed() {
    const [{ data: bots }, cnt, { data: sysMsgs }] = await Promise.all([
      sb.from('v_bot_dashboard').select('*').order('name_it'),
      sb.from('bot_messages').select('severity', { count: 'exact', head: false }).is('read_at', null).limit(1000),
      sb.from('bot_messages').select('agent, title, severity, body, created_at, read_at').in('agent', Object.values(SYS).flatMap(x => x.agents)).order('created_at', { ascending: false }).limit(300),
      loadNicknames()]);
    const nU = (cnt.data || []).length;
    UI.bellCount();
    (bots || []).forEach(b => { bdNames[b.agent] = b.display_name || botLabel(b.agent, b.name_it); bdRole[b.agent] = b.name_it; });
    Object.entries(SYS).forEach(([a, x]) => { bdRole[a] = bdNick[a] ? bdNick[a].title_it : x.role; });
    Object.keys(SYS).forEach(a => { bdNames[a] = botLabel(a, bdNick[a] ? bdNick[a].title_it : a); });
    // one item per card
    const items = (bots || []).map(b => {
      const st = !b.active ? 'off' : (b.last_status === 'error' || b.unread_alerts > 0 || b.last_severity === 'alert') ? 'al' : b.last_severity === 'warn' ? 'wn' : !b.last_run_at ? 'new' : 'ok';
      const raw = (b.last_title || '').trim(), generic = !raw || [b.name_it, b.display_name].some(x => x && (raw === x || raw.startsWith(x + ' · ')));
      return { agent: b.agent, nick: bdNick[b.agent] ? bdNick[b.agent].nickname : b.name_it, role: b.name_it, st, err: b.active && b.last_status === 'error',
        sched: schedTxt(b.due_times, b.weekdays, b.month_day), next: b.active ? nextRun(b.due_times, b.weekdays, b.month_day) : null,
        last: b.last_run_at, line: cleanTxt(b.last_status === 'error' ? (b.last_summary || 'Ultima esecuzione fallita') : generic ? (b.last_summary || raw) : raw),
        unread: b.unread || 0, unreadAl: b.unread_alerts || 0, active: b.active };
    });
    Object.entries(SYS).forEach(([a, s]) => {
      const ms = (sysMsgs || []).filter(m => s.agents.includes(m.agent)), m = ms[0], un = ms.filter(x => !x.read_at);
      const st = un.some(x => x.severity === 'alert') ? 'al' : un.some(x => x.severity === 'warn') ? 'wn' : 'ok';
      items.push({ agent: a, nick: bdNick[a] ? bdNick[a].nickname : a, role: s.role, st, sched: s.sched, next: nextRun(s.times, s.wd), last: m ? m.created_at : null, sys: true,
        line: un.length ? cleanTxt(un[0].title) : (s.okLine || 'Nessun allarme: tutti i bot sono regolari'), unread: un.length, unreadAl: un.filter(x => x.severity === 'alert').length, active: true });
    });
    // summary strip
    const c = k => items.filter(i => i.st === k).length;
    const nx = items.filter(i => i.next && !i.sys).sort((x, y) => x.next.key - y.next.key)[0];
    $('bd-sum').innerHTML = `
      <div class="sm s-al${c('al') ? '' : ' zero'}"><b>${c('al')}</b><span>da sistemare</span></div>
      <div class="sm s-wn${c('wn') ? '' : ' zero'}"><b>${c('wn')}</b><span>da controllare</span></div>
      <div class="sm s-ok"><b>${c('ok')}</b><span>in ordine</span></div>
      <div class="sm"><b>${nU}</b><span>notifiche da leggere</span></div>
      ${nx ? `<div class="sm nx">${botAvatar(nx.agent)}<div><span>Prossimo bot</span><b>${esc(nx.nick)}</b><span>${esc(nx.role)} · ${esc(nx.next.label)}</span></div></div>` : ''}`;
    // cards grouped by status, each group ordered by next run
    // card: name, job, one-line latest news, then when it last ran and when it runs next. Group heading + coloured edge carry the status.
    const when = i => i.active ? [i.last ? `Ultima: ${ago(i.last)}` : i.sys ? 'Nessun avviso finora' : 'Non ha ancora girato', i.next ? `Prossima: ${i.next.label}` : '']
      : ['Disattivato' + (i.last ? ` · ha girato ${ago(i.last)}` : '')];
    const card = i => `<div class="botc s-${i.st}${bdAgent === i.agent ? ' sel' : ''}" data-a="${esc(i.agent)}" role="button" tabindex="0" aria-pressed="${bdAgent === i.agent}" title="${esc(i.role)} · ${esc(i.sched)}">${botAvatar(i.agent)}
        <div class="bi"><div class="hd"><span class="nm">${esc(i.nick)}</span>${i.err ? '<span class="pill s-al">Errore</span>' : ''}</div>
        <div class="ti">${esc(i.role)}</div>
        <div class="bl">${esc(i.line || (i.st === 'new' ? 'Nessuna notizia: parte alla prossima esecuzione' : '—'))}</div>
        <div class="ft">${when(i).filter(Boolean).map(t => `<span>${esc(t)}</span>`).join('')}${i.unread ? `<span class="u${i.unreadAl ? ' al' : ''}">${i.unread} ${i.unread === 1 ? 'nuova' : 'nuove'}</span>` : ''}</div></div></div>`;
    const bb = $('bd-bots');
    bb.innerHTML = ['al', 'wn', 'ok', 'new', 'off'].map(k => { const g = items.filter(i => i.st === k).sort((x, y) => (x.next ? x.next.key : 1e9) - (y.next ? y.next.key : 1e9));
      return g.length ? `<div class="bd-grp s-${k}"><h4>${ST[k][1]} <span>${g.length}</span></h4><div class="bd-bots">${g.map(card).join('')}</div></div>` : ''; }).join('');
    const pick = el => { bdAgent = bdAgent === el.dataset.a ? null : el.dataset.a; bdLimit = 50; loadBotFeed(); if ($('runs-card').open) loadRuns(); if (bdAgent) $('bd-feed-card').scrollIntoView({ behavior: 'smooth', block: 'start' }); };
    bb.querySelectorAll('.botc').forEach(el => { el.onclick = () => pick(el); el.onkeydown = e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); pick(el); } }; });
    $('bd-bot').textContent = bdAgent ? 'Solo: ' + (bdNames[bdAgent] || bdAgent) : '';
    let q = sb.from('bot_messages').select('*').order('created_at', { ascending: false }).limit(bdLimit + 1);
    if (bdFilter === 'unread') q = q.is('read_at', null);
    if (bdFilter === 'alert') q = q.eq('severity', 'alert');
    if (bdAgent) q = q.in('agent', SYS[bdAgent] ? SYS[bdAgent].agents : [bdAgent]);
    const { data: msgs, error } = await q;
    const feed = $('bd-feed');
    if (error) { feed.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    $('bd-more').hidden = (msgs || []).length <= bdLimit;
    const rows = (msgs || []).slice(0, bdLimit);
    if (!rows.length) { feed.innerHTML = `<div class="empty">${bdFilter === 'unread' ? 'Nessuna notifica da leggere.' : 'Nessuna notifica.'}</div>`; return; }
    // grouped by day; same bot + same title on the same day = one entry ("3 volte"); Italian only unless "Mostra inglese"
    const items2 = [], byKey = {};
    rows.forEach(m => {
      const day = romeDay(m.created_at), key = `${day}|${m.agent}|${m.title}`;
      if (byKey[key]) { const it = byKey[key]; it.n++; if (!m.read_at) it.unreadIds.push(m.id); return; }
      const it = byKey[key] = { m, day, n: 1, unreadIds: m.read_at ? [] : [m.id] }; items2.push(it);
    });
    let lastDay = null;
    feed.innerHTML = items2.map(({ m, day, n, unreadIds }) => {
      const a = m.agent === 'avvisi' ? 'bot_watchdog' : m.agent, nk = bdNick[a];
      const role = m.agent === 'avvisi' ? 'Avvisi console' : (bdRole[a] || (nk ? nk.title_it : a));
      const generic = !m.title || [role, nk && nk.title_it, bdNames[a]].some(x => x && (m.title === x || m.title.startsWith(x + ' · ')));
      let body = mdLite(bdEn ? (m.body || '') : dropEn(m.body || '')), title = m.title || '';
      if (!bdEn) title = dropEn(title);
      if (generic) { const f = body.match(/^<(p|li)>(.*?)<\/\1>/) || body.match(/<(p|li)>(.*?)<\/\1>/);
        if (f) { title = plainTxt(f[2]); if (f[1] === 'p' && body.startsWith(f[0])) body = body.slice(f[0].length); } }
      title = title.replace(/^Oggi\s*[—–-]\s*/, '');
      const head = day !== lastDay ? `<div class="bd-day">${esc(dayLabel(day))}</div>` : ''; lastDay = day;
      const sv = m.severity === 'alert' ? '<span class="sv">Allarme</span>' : m.severity === 'warn' ? '<span class="sv">Da controllare</span>' : '';
      return `${head}<div class="msg ${esc(m.severity)}${unreadIds.length ? '' : ' read'}" data-ids="${unreadIds.join(',')}">${botAvatar(a)}<div class="mb">
        <div class="hd"><span class="who"><b>${esc(nk ? nk.nickname : role)}</b><span class="role">${esc(role)}</span></span><span class="tm">${hmRome(m.created_at)}${n > 1 ? ` · ${n} volte` : ''}</span></div>
        <div class="t">${sv}${esc(title)}</div>${body ? `<div class="b">${body}</div>` : ''}
        <div class="ac"><button class="more" data-x="more" hidden>Mostra tutto</button>${unreadIds.length ? '<button class="rd" data-x="read">✓ Segna come letta</button>' : ''}</div></div></div>`;
    }).join('');
    feed.querySelectorAll('.msg .b').forEach(b => { if (b.scrollHeight > b.clientHeight + 4) { b.classList.add('cut'); b.closest('.mb').querySelector('[data-x=more]').hidden = false; } });
    feed.querySelectorAll('[data-x=more]').forEach(btn => btn.onclick = () => { const bd = btn.closest('.mb').querySelector('.b'); bd.classList.toggle('open'); btn.textContent = bd.classList.contains('open') ? 'Riduci' : 'Mostra tutto'; });
    feed.querySelectorAll('[data-x=read]').forEach(btn => btn.onclick = async () => { const ids = btn.closest('.msg').dataset.ids.split(',').filter(Boolean).map(Number); const { error } = await sb.rpc('mark_bot_messages_read', { p_ids: ids }); if (error) return toast(error.message, 'err'); loadBotFeed(); });
  }
  document.querySelectorAll('.bd-bar .chip[data-f]').forEach(c => c.onclick = () => { bdFilter = c.dataset.f; bdLimit = 50; document.querySelectorAll('.bd-bar .chip[data-f]').forEach(x => x.setAttribute('aria-pressed', x === c)); loadBotFeed(); });
  $('bd-en').onclick = () => { bdEn = !bdEn; $('bd-en').setAttribute('aria-pressed', bdEn); loadBotFeed(); };
  $('bd-more').onclick = () => { bdLimit += 50; loadBotFeed(); };
  $('bd-readall').onclick = async () => {
    const { data: ids } = await (bdAgent ? sb.from('bot_messages').select('id').is('read_at', null).in('agent', SYS[bdAgent] ? SYS[bdAgent].agents : [bdAgent]) : sb.from('bot_messages').select('id').is('read_at', null));
    if (!ids || !ids.length) return toast('Niente da segnare');
    if (!confirm(`Segnare come lette ${ids.length} notifiche?`)) return;
    const { data, error } = await sb.rpc('mark_bot_messages_read', { p_ids: ids.map(x => x.id) }); if (error) return toast(error.message, 'err');
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
  async function callUsers(body) {
    const { data, error } = await sb.functions.invoke('invite-user', { body });
    if (error) { let m = error.message; try { const j = await error.context.json(); m = j.error || m; } catch {} throw new Error(m); }
    if (data && data.error) throw new Error(data.error); return data;
  }
  const badgeLine = p => [p.badge_code, p.full_name, (JOBS.find(([v]) => v === p.role) || [, ''])[1]].map(s => String(s || '').replace(/[|\n]/g, ' ')).join(' | ');
  async function loadUsers() {
    const admin = PERM.isAdmin();
    $('usr-invite').hidden = !admin; $('usr-ro').hidden = admin;
    const [{ data: people, error }, { data: roles }, { data: areas }, { data: perms }] = await Promise.all([
      sb.from('staff').select('id, full_name, email, role, app_role, auth_user_id, active, badge_code').order('active', { ascending: false }).order('full_name'),
      sb.from('app_roles').select('*').order('sort'), sb.from('app_areas').select('*').neq('code', 'comune').order('sort'), sb.from('role_permissions').select('*')]);
    const box = $('users'); if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    const roleOpts = sel => (roles || []).map(r => `<option value="${r.code}"${r.code === sel ? ' selected' : ''}>${esc(r.name_it)}</option>`).join('');
    $('inv-role').innerHTML = roleOpts('produzione');
    const tbl = document.createElement('table');
    tbl.innerHTML = '<tr><th>Persona</th><th>Email</th><th>Profilo</th><th>Mansione</th><th>Accesso</th><th></th></tr>';
    (people || []).forEach(p => {
      const tr = document.createElement('tr'); if (!p.active) tr.style.opacity = '.55';
      const login = !p.active ? 'disattivato' : p.auth_user_id ? 'collegato' : p.email ? 'invito da inviare' : 'senza email';
      tr.innerHTML = `<td><b>${esc(p.full_name)}</b><br><small>${esc(p.badge_code || '')}</small></td>`;
      const em = document.createElement('input'); em.type = 'email'; em.value = p.email || ''; em.disabled = !admin; em.style.width = '200px';
      const rs = document.createElement('select'); rs.innerHTML = roleOpts(p.app_role); rs.disabled = !admin;
      const js = document.createElement('select'); js.innerHTML = JOBS.map(([v, l]) => `<option value="${v}"${v === p.role ? ' selected' : ''}>${l}</option>`).join(''); js.disabled = !admin;
      [em, rs, js].forEach(x => { const td = document.createElement('td'); td.append(x); tr.append(td); });
      const tdl = document.createElement('td'); tdl.innerHTML = `<small>${login}</small>`; tr.append(tdl);
      const tda = document.createElement('td'); tda.style.whiteSpace = 'nowrap';
      if (p.active && p.badge_code) { const a = document.createElement('a'); a.className = 'btn sm sec'; a.style.cssText = 'text-decoration:none;margin-right:4px'; a.target = '_blank'; a.textContent = 'Badge';
        a.title = 'Stampa il badge QR da passare sul tablet'; a.href = 'labels.html?' + new URLSearchParams({ l: badgeLine(p) }); tda.append(a); }
      if (admin) {
        const b = (label, cls, fn) => { const x = document.createElement('button'); x.className = 'btn sm ' + cls; x.textContent = label; x.style.marginRight = '4px';
          x.onclick = async () => { x.disabled = true; try { const res = await fn(); if (cls === 'save' && res !== false) UI.clean(x); } catch (err) { toast(err.message || String(err), 'err'); } finally { x.disabled = false; } }; tda.append(x); };
        b('Salva', 'save', async () => { PERM.changed(await sb.from('staff').update({ email: em.value.trim() || null, app_role: rs.value, role: js.value }).eq('id', p.id).select('id')); toast('Salvato'); loadUsers(); });
        if (p.active && p.email && p.id !== staff.id) b(p.auth_user_id ? 'Reinvia link' : 'Invia invito', 'sec', async () => { const r = await callUsers({ action: p.auth_user_id ? 'resend' : 'invite', staff_id: p.id, email: p.email, full_name: p.full_name, app_role: p.app_role, job_role: p.role }); toast(r.sent === 'reset' ? 'Email per reimpostare la password inviata' : 'Invito inviato'); loadUsers(); });
        if (p.id !== staff.id) b(p.active ? 'Disattiva' : 'Riattiva', p.active ? 'warn' : 'sec', async () => { if (p.active && !confirm(`Disattivare ${p.full_name}? Non potrà più entrare finché non lo riattivi.`)) return false; await callUsers({ action: p.active ? 'deactivate' : 'reactivate', staff_id: p.id }); toast(p.active ? 'Disattivato: non può più entrare' : 'Riattivato'); loadUsers(); });
      }
      tr.append(tda); tbl.append(tr);
    });
    box.innerHTML = ''; box.append(tbl);
    const withBadge = (people || []).filter(p => p.active && p.badge_code);
    if (withBadge.length) { const q = new URLSearchParams(); withBadge.forEach(p => q.append('l', badgeLine(p)));
      const all = document.createElement('a'); all.className = 'btn sm sec'; all.style.cssText = 'text-decoration:none;display:inline-block;margin-top:8px'; all.target = '_blank';
      all.textContent = `Stampa tutti i badge (${withBadge.length})`; all.href = 'labels.html?' + q; box.append(all); }
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
  $('inv-go').onclick = async () => {
    const b = $('inv-go'); b.disabled = true;
    if (!$('inv-name').value.trim() || !/^\S+@\S+\.\S+$/.test($('inv-email').value.trim())) { b.disabled = false; return toast('Scrivi nome e un\'email valida', 'err'); }
    try { const r = await callUsers({ action: 'invite', full_name: $('inv-name').value.trim(), email: $('inv-email').value.trim(), app_role: $('inv-role').value });
      toast(r.invited ? 'Invito inviato: la persona riceve una email per scegliere la password' : 'Account esistente collegato'); $('inv-name').value = ''; $('inv-email').value = ''; UI.clean($('usr-invite')); loadUsers();
    } catch (err) { toast(err.message || String(err), 'err'); } finally { b.disabled = false; }
  };
  const AUD_T = { settings: 'Parametri', approvals: 'Approvazioni', recipes: 'Ricette', standing_orders: 'Ordini fissi', staff: 'Personale', products: 'Prodotti', equipment: 'Macchine',
    compliance_deadlines: 'Scadenze', haccp_control_points: 'Punti HACCP', process_steps: 'Processo', supplier_products: 'Condizioni fornitori', supplier_prices: 'Listini',
    farm_supply: 'Latte Masseria', shopify_variant_map: 'Prodotti Shopify', training_courses: 'Corsi', rota_entries: 'Turni' };
  const AUD_A = { insert: 'aggiunto', update: 'modificato', delete: 'eliminato' };
  const short = v => { if (v == null) return '∅'; const s = typeof v === 'object' ? JSON.stringify(v) : String(v); return s.length > 60 ? s.slice(0, 57) + '…' : s; };  async function loadAudit() {
    const sel = $('aud-table'); if (sel.options.length === 1) Object.entries(AUD_T).forEach(([k, l]) => sel.add(new Option(l, k)));
    const box = $('audit'); box.innerHTML = '<div class="status">Carico…</div>';
    let q = sb.from('audit_log').select('*').order('at', { ascending: false }).limit(150);
    if (sel.value) q = q.eq('table_name', sel.value);
    const { data, error } = await q;
    if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    audRows = data || []; renderAudit();
  }
  function renderAudit() {
    const box = $('audit'), data = audRows;
    const needle = $('aud-q').value.trim().toLowerCase();
    const rows = (data || []).filter(r => !needle || JSON.stringify(r).toLowerCase().includes(needle));
    if (!rows.length) { box.innerHTML = '<div class="empty">Nessuna modifica registrata.</div>'; return; }
    const label = r => { const d = r.new_data || r.old_data || {}; return r.table_name === 'settings' ? r.row_key : d.summary || d.full_name || d.name || d.name_it || d.code || d.subject_it || d.po_number || d.work_date || (r.row_key || '').slice(0, 8); };
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
      const kg = document.createElement('input'); kg.type = 'number'; kg.step = '0.05'; kg.min = '0'; kg.value = r.kg_per_unit ?? ''; kg.placeholder = 'kg';
      const td3 = document.createElement('td'); td3.append(sel); const td4 = document.createElement('td'); td4.className = 'num'; td4.append(kg);
      const td5 = document.createElement('td'); td5.append(saveBtn(async () => {
        const pid = sel.value || null, k = pid ? Number(kg.value) : null; if (pid && !(k > 0)) throw new Error('Inserisci i kg per pezzo');
        await upd('shopify_variant_map', { variant_id: r.variant_id }, { product_id: pid, kg_per_unit: k, auto_mapped: false, updated_at: new Date().toISOString() }); UI.after(loadVariantMap);
      }));
      tr.append(td3, td4, td5); tbl.append(tr);
    });
    box.append(tbl);
  }
  function renderEquipment(rows) {
    const box = $('set-equipment'); box.innerHTML = '';
    const act = rows.filter(r => r.active).sort((a, b) => (!!(a.next_calibration_on || a.next_maintenance_on)) - (!!(b.next_calibration_on || b.next_maintenance_on)) || String(a.code).localeCompare(String(b.code)));
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
  };  $('pw-save').onclick = async () => {
    const pw = $('pw-new').value; if (pw.length < 8) return toast('Minimo 8 caratteri', 'err');
    $('pw-save').disabled = true; const { error } = await sb.auth.updateUser({ password: pw }); $('pw-save').disabled = false;
    if (error) return toast(error.message, 'err'); $('pw-new').value = ''; UI.clean($('account')); toast('Password cambiata');
  };

  // ---------- tabs + start ----------
  const SEC_IDS = SECTIONS.map(s => s[0]).concat('altro');
  const T = UI.tabs({
    def: 'parametri', alias: Object.assign({ account: 'utenti' }, Object.fromEntries(SEC_IDS.map(s => [s, 'parametri']))),
    loaders: { parametri: loadParams, maint: loadMaint, prodotti: loadVariantMap, bots: loadBotFeed, utenti: loadUsers, registro: loadAudit }
  });
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
      if (h === 'account') setTimeout(() => { $('account').scrollIntoView({ block: 'start' }); $('pw-new').focus(); }, 150);
      // counts for the tabs that are not open yet
      if (!T.isLoaded('maint')) loadMaint(); if (!T.isLoaded('prodotti')) sb.from('v_shopify_variant_map').select('unmapped_lines').then(({ data }) => badge('n-prod', (data || []).filter(r => r.unmapped_lines).length));
    }
  });
})();
