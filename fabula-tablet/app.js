/* Fabula tablet — one screen per scan point. Vanilla JS, supabase-js v2, html5-qrcode.
   Every write goes through `save()` which queues offline and flushes when back online. */
(() => {
  const CFG = window.FABULA_CONFIG;
  const sb = supabase.createClient(CFG.supabaseUrl, CFG.supabaseKey, { db: { schema: 'fabula' } });
  const $ = id => document.getElementById(id);
  // every value from the database or Shopify goes through esc() before it lands in innerHTML
  const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  // Mouse wheel over a focused number field must never change its value (keyboard only).
  document.addEventListener('wheel', e => { const a = document.activeElement; if (a && a.tagName === 'INPUT' && a.type === 'number' && e.target === a) e.preventDefault(); }, { passive: false });
  let staff = null, scanner = null, current = null;
  let redoPending = null;   // v1.10: declared (it worked only because the file is not in strict mode)

  // ---------- UI helpers ----------
  const show = v => { if (v === 'home') redoPending = null; document.querySelectorAll('.view').forEach(e => e.classList.toggle('active', e.id === 'v-' + v)); };
  let lastToastAt = 0;
  let toastT = null;   // v0.95: a newer toast is not hidden by the timer of an older one; long messages can stay longer
  const toast = (msg, cls = 'ok', ms = 2600) => { lastToastAt = Date.now(); const t = $('toast'); t.textContent = msg; t.className = 'toast ' + cls; t.style.display = 'block'; clearTimeout(toastT); toastT = setTimeout(() => t.style.display = 'none', ms); };
  // v0.59: dates are Agropoli dates (Europe/Rome), not UTC: between 00:00 and 02:00 the UTC date was still yesterday
  const ROME_DAY = new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Rome', year: 'numeric', month: '2-digit', day: '2-digit' });
  const today = () => ROME_DAY.format(new Date());
  const addDays = (ymd, n) => { const d = new Date(ymd + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() + Number(n || 0)); return d.toISOString().slice(0, 10); };
  // start of today in Agropoli as an ISO timestamp (for timestamptz comparisons)
  const romeDayStartIso = () => { const off = (new Intl.DateTimeFormat('en-US', { timeZone: 'Europe/Rome', timeZoneName: 'longOffset' }).formatToParts(new Date()).find(x => x.type === 'timeZoneName') || {}).value || 'GMT+01:00';
    const m = off.match(/GMT([+-]\d{2}):?(\d{2})?/); return `${today()}T00:00:00${m ? m[1] + ':' + (m[2] || '00') : '+01:00'}`; };
  const likeSafe = v => String(v).replace(/[\\%_]/g, c => '\\' + c);   // exact, case-insensitive match with ilike
  // v0.98 (audit A-13): numbers are typed in a text box with the number keyboard and read the Italian way, not left to the browser:
  // «4,5» and «4.5» are the same; «1.200» (a dot before exactly three digits) is refused because it could be 1,2 or 1200 (and a
  // browser in Italian read it as 1,2); «1.200,5» is 1200,5. A field may say what is physically possible (min/max/unit): outside it
  // the field turns red, says why, and Salva does not go on. The value read is repeated under the box: «= 4,5 °C».
  const parseNum = s => {
    let t = String(s ?? '').trim().replace(/\s/g, '');
    if (t === '') return { v: null };
    if (t.includes(',') && t.includes('.')) { if (!/^[+-]?\d{1,3}(\.\d{3})+,\d+$/.test(t)) return { bad: true }; t = t.replace(/\./g, '').replace(',', '.'); }
    else if (/^[+-]?[1-9]\d{0,2}(\.\d{3})+$/.test(t)) return { amb: true };
    else t = t.replace(',', '.');
    return /^[+-]?(\d+(\.\d*)?|\.\d+)$/.test(t) ? { v: Number(t) } : { bad: true };
  };
  const itNum = (v, d = 3) => v == null || v === '' || !Number.isFinite(Number(v)) ? '' : Number(v).toLocaleString('it-IT', { maximumFractionDigits: d, useGrouping: false });
  function numCheck(i) {
    const p = parseNum(i.value), e = $('echo-' + i.id), lbl = (i.labels && i.labels[0] ? i.labels[0].textContent : 'Valore').replace(/\s*[·(].*$/, '');
    const u = i.dataset.unit ? ' ' + i.dataset.unit : '', lo = i.dataset.min === undefined ? null : Number(i.dataset.min), hi = i.dataset.max === undefined ? null : Number(i.dataset.max);
    let msg = '';
    if (p.amb) msg = i.dataset.int ? `«${i.value}»: scrivi ${i.value.replace(/\./g, '')} senza punto` : `«${i.value}»: scrivi ${i.value.replace(/\./g, '')} senza punto, oppure ${i.value.replace('.', ',')} con la virgola`;
    else if (p.bad) msg = 'Scrivi solo il numero, con la virgola per i decimali (es. 4,5)';
    else if (p.v != null && i.dataset.int && !Number.isInteger(p.v)) msg = `${lbl}: scrivi un numero intero`;
    else if (p.v != null && ((lo != null && p.v < lo) || (hi != null && p.v > hi)))
      msg = `${itNum(p.v)}${u} non è possibile per «${lbl}»: ${lo != null && hi != null ? `tra ${itNum(lo)} e ${itNum(hi)}${u}` : lo != null ? `almeno ${itNum(lo)}${u}` : `al massimo ${itNum(hi)}${u}`}. Controlla la virgola.`;
    i.setCustomValidity(msg);
    i.classList.toggle('bad', !!msg);
    if (e) { e.textContent = msg || (p.v == null ? '' : `= ${itNum(p.v)}${u}`); e.classList.toggle('bad', !!msg); }
    return msg ? null : p.v;
  }
  // a number put into a field by the tablet (a farm load, a plan, the scale) is written the Italian way, so it reads back the same
  const setNum = (i, v) => { i.value = v == null || v === '' ? '' : itNum(v, 4); numCheck(i); };
  const numOf = i => { const p = parseNum(i.value); return p.v == null || p.amb || p.bad ? null : p.v; };
  const field = (id, label, type = 'number', extra = {}) => {
    const l = document.createElement('label'); l.htmlFor = id; l.textContent = label;
    const i = document.createElement(type === 'select' ? 'select' : 'input');
    i.id = id; i.name = id;
    if (type === 'number') {
      i.type = 'text'; i.inputMode = 'decimal'; i.autocomplete = 'off'; i.dataset.num = '1';
      if (extra.min != null) i.dataset.min = extra.min; if (extra.max != null) i.dataset.max = extra.max;
      if (extra.unit) i.dataset.unit = extra.unit; if (extra.int) i.dataset.int = '1';
    } else if (type !== 'select') i.type = type;
    if (extra.options) extra.options.forEach(([v, t]) => { const o = document.createElement('option'); o.value = v; o.textContent = t; i.appendChild(o); });
    if (extra.required !== false) i.required = true;
    $('form').append(l, i);
    if (type === 'number') { const e = document.createElement('div'); e.className = 'echo'; e.id = 'echo-' + id; $('form').append(e); i.addEventListener('input', () => numCheck(i)); }
    if (extra.limit) { const d = document.createElement('div'); d.className = 'limit'; d.textContent = extra.limit; $('form').append(d); }
    return i;
  };
  const val = id => { const e = $(id); return e ? (e.dataset.num ? numOf(e) : e.value) : null; };
  const noteShow = (n, on) => { if (!n) return; n.required = on; n.style.display = on ? '' : 'none'; if (n.previousElementSibling) n.previousElementSibling.style.display = on ? '' : 'none'; };
  // the possible range of a control point's reading (haccp_control_points.plausible_min/max, or the built-in copy)
  const cpRange = code => { const c = refStore()['cp_' + code] || {}; const p = PLAUS[code] || [];
    return { min: c.plausible_min ?? p[0], max: c.plausible_max ?? p[1], unit: c.unit && c.unit !== 'esito' ? c.unit : '' }; };
  // settings the tablet needs offline (vat size, possible yields), kept with the other reference data
  const setting = (k, d) => { const v = (refStore().settings || {})[k]; const n = Number(v); return v == null || v === '' || !Number.isFinite(n) ? d : n; };
  // v0.97 (audit A-17/A-07): a question that stays on screen until answered, with the numbers — no more «premi Salva di nuovo»
  // (a double tap answered it). Its buttons wait 1,5 s before they work. danger = red, for values that reject milk or hold a lot.
  function ask({ title, lines = [], yes = 'Sì, è giusto', no = 'No, correggo', danger = false, input = null }) {
    return new Promise(res => {
      const w = document.createElement('div'); w.className = 'ask-wrap';
      const c = document.createElement('div'); c.className = 'ask' + (danger ? ' danger' : '');
      const h = document.createElement('div'); h.className = 'ask-t'; h.textContent = title; c.append(h);
      lines.filter(Boolean).forEach(t => { const p = document.createElement('div'); p.className = 'ask-l'; p.textContent = t; c.append(p); });
      let inp = null;
      if (input) { const l = document.createElement('label'); l.textContent = input.label; inp = document.createElement('input'); inp.type = 'text'; inp.id = 'ask-in'; inp.placeholder = input.placeholder || ''; if (input.mode) inp.inputMode = input.mode; inp.autocomplete = 'off'; c.append(l, inp); }
      const y = document.createElement('button'); y.type = 'button'; y.className = 'btn' + (danger ? ' warn' : ''); y.textContent = yes;
      const n = document.createElement('button'); n.type = 'button'; n.className = 'btn secondary'; n.textContent = no;
      [y, n].forEach(b => { b.disabled = true; }); setTimeout(() => [y, n].forEach(b => { b.disabled = false; }), 1500);
      const done = v => { w.remove(); res(v); };
      y.onclick = () => { if (inp && inp.value.trim().length < (input.min || 0)) { inp.focus(); inp.style.borderColor = 'var(--warn)'; return; } done(inp ? inp.value.trim() : true); };
      n.onclick = () => done(inp ? null : false);
      c.append(y); if (no !== null) c.append(n); w.append(c); document.body.append(w);
    });
  }
  const stop = () => { const e = new Error('annullato'); e.silent = true; return e; };   // the person chose to correct: no red toast
  // v0.97 (audit A-07): is a value outside the critical limit of its control point? (kept on the tablet: works offline)
  function ccpOut(code, v) {
    const c = refStore()['cp_' + code]; if (!c || v == null || v === '') return null;
    const x = Number(v), lo = c.min_value == null ? null : Number(c.min_value), hi = c.max_value == null ? null : Number(c.max_value);
    if (!((lo != null && x < lo) || (hi != null && x > hi))) return null;
    const lim = c.unit === 'esito' ? '' : [lo != null ? `≥ ${itN(lo)}` : null, hi != null ? `≤ ${itN(hi)}` : null].filter(Boolean).join(' e ') + ' ' + (c.unit || '');
    return { cp: c, lim: lim.trim() };
  }
  const CONSEQ = code => /^CCP-MILK/.test(code) ? 'il latte verrà RESPINTO (non si usa in produzione) e i lotti già fatti con esso BLOCCATI'
    : code === 'PRP-PAST-VALVE' ? 'non si pastorizza e si apre una NON CONFORMITÀ'
    : /^CCP-COLD/.test(code) ? 'si apre una NON CONFORMITÀ per la cella' : 'si apre una NON CONFORMITÀ';
  // the red question before saving: true = go on (value within limits, or the person confirmed it)
  async function confirmOut(code, v, lot) {
    const o = ccpOut(code, v); if (!o) return true;
    const c = o.cp, what = c.unit === 'esito' ? `Hai scelto «${code === 'CCP-MILK-ABX' ? 'POSITIVO' : 'NON ok'}»` : `Hai scritto ${itN(v)} ${c.unit || ''}. Il limite è ${o.lim}`;
    return ask({ danger: true, title: `${c.ccp_no ? c.ccp_no + ' · ' : ''}${c.name}: fuori limite`, yes: 'Sì, è giusto: registra', no: 'No, correggo',
      lines: [what.trim() + ':', (lot && ['CCP-PAST', 'CCP-STRETCH', 'CCP-RIC'].includes(code) ? `il lotto ${lot} verrà BLOCCATO (non si vende)` : CONSEQ(code)) + '.', 'È giusto?'] });
  }
  // after a non-conformity: a card that stays until OK, with what to do now (it used to flash for 2,6 s in a toast)
  function ncCard(code, r, lot, extra = []) {
    const c = refStore()['cp_' + code] || {};
    const held = r ? r.lot_on_hold : !!lot && ['CCP-PAST', 'CCP-STRETCH', 'CCP-RIC'].includes(code);
    return showDone(`⚠ NON CONFORMITÀ · ${c.ccp_no || ''} ${c.name || code}`.replace(/\s+/g, ' ').trim(), [
      held ? `Lotto ${lot} BLOCCATO: non si vende finché il responsabile HACCP non lo sblocca.` : null,
      ...extra,
      'Cosa fare adesso: ' + ((r && r.corrective_it) || c.corrective_it || 'avvisa il responsabile HACCP.'),
      r ? 'Il responsabile HACCP riceve l\'avviso su Telegram.' : 'Salvato senza rete: l\'avviso parte appena torna la connessione. Intanto avvisa a voce il responsabile.'], [], { warn: true });
  }

  // ---------- Offline queue (v0.39: idempotent, refused items set aside, auth errors retried) ----------
  const Q = 'fabula_queue', QF = 'fabula_failed';
  const UUID_TABLES = new Set(['scan_events', 'milk_intake', 'labels', 'production_batches', 'stock_moves', 'haccp_log', 'meter_readings', 'effluent_log', 'shipments', 'shipment_lines', 'waste_log', 'sales_orders', 'batch_step_logs']);
  const uuid = () => (crypto.randomUUID ? crypto.randomUUID() : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => { const r = crypto.getRandomValues(new Uint8Array(1))[0] & 15; return (c === 'x' ? r : (r & 3) | 8).toString(16); }));
  const readList = k => { try { return JSON.parse(localStorage.getItem(k) || '[]'); } catch { return []; } };
  const queue = () => readList(Q), failedList = () => readList(QF);
  const showPending = () => { const q = queue().length;
    $('pending').textContent = q ? (q === 1 ? '1 registrazione in attesa di rete: parte da sola' : `${q} registrazioni in attesa di rete: partono da sole`) : '';
    try { renderRejects(); } catch {} };   // v0.97 (A-11): refused saves are the red banner at the top of Home
  // (v0.74 check-in further down reports both numbers to the office)
  // v1.10: a write that fails (tablet storage full) is reported, so «Salvato offline» is never shown for a record that was not kept
  const writeList = (k, v) => { try { localStorage.setItem(k, JSON.stringify(v)); return true; } catch { return false; } };
  const setQueue = q => { const ok = writeList(Q, q); showPending(); return ok; };
  const setFailed = f => { const ok = writeList(QF, f); showPending(); return ok; };
  // retryable = network down, timeout, or an expired login; anything else is the database refusing the data
  const retryable = e => !e || !e.code || /fetch|network|timeout|jwt|token/i.test(e.message || '') || e.code === 'PGRST301' || e.status === 401;
  // every insert carries its own id, generated once on the tablet: a re-send after a lost reply hits the same row instead of duplicating it
  const stamp = ops => ops.forEach(op => { if (op.table && !op.update && op.row && !op.row.id && UUID_TABLES.has(op.table)) op.row.id = uuid(); });
  // v0.95 (audit D-12): the same "possible values" as the database (haccp_control_points.plausible_min/max, kept on the tablet;
  // built-in copy if not read yet), checked before saving or queuing — offline too, so one slipped comma cannot send a whole
  // batch close to «rifiutate» when the queue goes out
  const PLAUS = { 'CCP-PAST': [10, 100], 'CCP-STRETCH': [10, 99], 'CCP-RIC': [10, 99], 'CCP-MILK-TEMP': [-2, 45], 'CCP-COLD-1': [-10, 45], 'CCP-COLD-2': [-10, 45], 'CCP-MILK-ABX': [0, 1], 'PRP-PAST-VALVE': [0, 1] };
  const itN = v => String(v).replace('.', ',');
  function plausCheck(code, v) {
    if (v == null || v === '' || !code) return;
    const c = refStore()['cp_' + code] || {}, lo = c.plausible_min ?? (PLAUS[code] || [])[0], hi = c.plausible_max ?? (PLAUS[code] || [])[1];
    if ((lo != null && Number(v) < Number(lo)) || (hi != null && Number(v) > Number(hi)))
      throw new Error(`Valore impossibile: ${itN(v)}${c.unit && c.unit !== 'esito' ? ' ' + c.unit : ''} per «${c.name || code}» (possibili ${itN(lo)}–${itN(hi)}). Controlla la virgola e riscrivi.`);
  }
  const phCheck = v => { if (v != null && v !== '' && (Number(v) < 3 || Number(v) > 8)) throw new Error(`pH della cagliata impossibile: ${itN(v)} (possibile da 3 a 8). Controlla la virgola e riscrivi.`); };
  function plausOps(ops) {
    for (const op of ops) {
      if ((op.rpc === 'log_ccp' || op.rpc === 'log_milk_check') && op.args) plausCheck(op.args.p_cp_code, op.args.p_value);
      if (op.table === 'production_batches' && op.row) phCheck(op.row.curd_ph);
    }
  }
  // v0.97 (audit A-08/D-29): a lot letter another tablet had already used is changed by the database (L…-B → L…-C). The tablet
  // keeps the change for 3 days and applies it to everything it saves or still has queued for that lot, so steps, CCPs and the
  // close land on the right batch, and Home says which letter to write on the vat sheet.
  const RNK = 'perla_lot_renames_v1';
  const renames = () => { const r = readObj(RNK), now = Date.now(); return Object.fromEntries(Object.entries(r).filter(([, x]) => x && now - x.at < 3 * 864e5)); };
  function addRename(from, to) { const r = renames(); r[from] = { to, at: Date.now() }; writeObj(RNK, r); renderRenames(); toast(`Il lotto ${from} di questo tablet ora si chiama ${to}: la ${from.slice(-1)} era già usata da un altro tablet. Scrivi ${to} sul foglio della caldaia.`, 'err', 12000); }
  // only renames found AFTER `since` (when the form, the dosing sequence or the queued item was made with the old letter): a form
  // opened later is about whatever lot was scanned then — maybe the other tablet's, which keeps its letter
  // skip: letters this item already got from an earlier rename (L-B → L-C, then L-C → L-D found later: the item stays on L-C).
  // Returns the letters it gave (empty: nothing changed).
  function applyRenames(ops, since = 0, skip = []) {
    const r = {}, made = new Set(), sk = new Set(skip);
    Object.entries(renames()).filter(([, x]) => x.at > since).forEach(([from, x]) => { r[from] = x; r['R' + from.slice(1)] = { ...x, to: 'R' + x.to.slice(1) }; });   // its ricotta too
    if (!Object.keys(r).length) return [];
    const to = v => { made.add(v); return v; };
    const sub = v => { if (typeof v !== 'string' || sk.has(v) || sk.has(v.replace(/^LOT:/, ''))) return v;
      if (r[v]) return to(r[v].to); if (v.startsWith('LOT:') && r[v.slice(4)]) return 'LOT:' + to(r[v.slice(4)].to); return v; };
    const walk = x => Array.isArray(x) ? x.map(walk) : (x && typeof x === 'object') ? Object.fromEntries(Object.entries(x).map(([k, v]) => [k, walk(v)])) : sub(x);
    ops.forEach((op, i) => { ops[i] = walk(op); });
    return [...made];
  }
  function renderRenames() {
    const box = $('renames'); if (!box) return;
    const r = Object.entries(renames()).filter(([from]) => from.includes(today().replace(/-/g, '')));
    box.style.display = r.length ? '' : 'none';
    box.innerHTML = r.length ? '<div class="nt">Lotti con la lettera cambiata</div>' + r.map(([from, x]) => `<div>${esc(from)} → <b>${esc(x.to)}</b> (la lettera era già usata da un altro tablet): scrivi <b>${esc(x.to)}</b> su fogli ed etichette.</div>`).join('') : '';
  }
  // after a save reached the database: did it get another letter?
  async function checkRenames(ops, out) {
    for (let k = 0; k < ops.length; k++) {
      const op = ops[k]; if (op.table !== 'production_batches' || op.update || !op.row || !op.row.batch_lot) continue;
      let got = out && out[k] && typeof out[k] === 'object' ? out[k].batch_lot : null;
      if (!got && op.row.id) {
        const r = await live(sb.from('production_batches').select('batch_lot').eq('id', op.row.id).maybeSingle());
        if (r.error) throw { message: 'Rete: controllo della lettera del lotto non riuscito', code: null };   // retryable: the flush stops, the item is re-sent (ledger)
        got = r.data && r.data.batch_lot; }
      if (got && got !== op.row.batch_lot) addRename(op.row.batch_lot, got);
    }
  }
  async function save(ops, since = null) {   // ops: [{table, row}] executed in order; later rows may reference earlier via $0.id
    applyRenames(ops, since ?? ((current && current.openedAt) || Date.now()));   // v0.97: a lot renamed since this form was opened
    plausOps(ops);
    stamp(ops);
    const qid = uuid();                       // v0.62: one id per save — the server writes it once, however many times it is sent
    const st = { done: 0, out: [] };          // v0.59: progress travels with the queued item, so a re-send skips the steps already saved
    const at = Date.now();                    // v0.97 (audit D-04): when it was done; sent with the item, so a check queued offline keeps it
    const enqueue = () => {
      if (!setQueue([...queue(), { qid, at, ops, st }])) {   // v1.10: storage full → say so instead of «Salvato offline»
        throw new Error('Memoria del tablet piena: questa registrazione NON è salvata. Scrivila sul foglio di carta e avvisa l\'ufficio.');
      }
      markRedo(ops);
    };
    // v0.97: the answer of each step when it was saved now (null when it went into the queue), e.g. the CCP result for the NC card
    if (!navigator.onLine) { enqueue(); toast('Salvato offline, invio appena c\'è rete'); return null; }
    if (queue().length) await flush();        // v0.62: records saved offline go first (a batch start needs its milk intake on the server)
    if (queue().length) { enqueue(); toast('In coda dietro le registrazioni offline: partono insieme', 'info'); setTimeout(flush, 1000); return null; }
    try { const out = await run(ops, st, qid); lotsChanged(); await checkRenames(ops, out); markRedo(ops); return out || []; }
    catch (e) {
      console.error(e);
      if (!retryable(e)) { toast(st.done ? `Salvato solo in parte (${st.done} di ${ops.length} passi): ${e.message}` : e.message, 'err', 8000); throw e; }   // refused by the database: show it, don't queue it
      enqueue(); toast('Rete assente: messo in coda', 'info'); return null;
    }
  }
  const REF = /^\$(\d+)\.(\w+)$/;          // "$1.id" = a field of the row saved by step 1 (v0.59: only this exact shape; "$5" in a note stays text)
  // v0.62: a save with several steps runs on the server in ONE transaction (fabula.save_ops): all steps are written or none,
  // and the queue id makes a re-send after a lost reply return the first result instead of writing again.
  // Items half-sent by an older version (st.done > 0) finish step by step as before.
  // single RPCs that write (dosing, steps, CCP, receipts) go the same way, so a lost reply never records them twice
  // v1.10: the badge scans and the calibration, pest round and lab sample records too (they could be written twice after a lost reply)
  const ONCE_RPCS = new Set(['log_ccp', 'log_milk_check', 'receive_purchase_order', 'record_receipt_check', 'close_open_task', 'start_byproduct_batch', 'log_batch_step', 'record_batch_consumable',
    'badge_in', 'badge_out', 'record_calibration_check', 'record_pest_inspection', 'record_sample_taken']);
  let atomicOk = true, clientAtOk = true;
  async function run(ops, st = { done: 0, out: [] }, qid = null, at = null) {
    if ((ops.length > 1 || (qid && ops[0] && ONCE_RPCS.has(ops[0].rpc))) && !(st.done > 0) && atomicOk) {
      // v0.97 (audit D-04): with the time it was done on the tablet (a save queued offline keeps it; the server ignores it if recent)
      // only for a queued item (at): the time it was done, and the tablet's clock now — the database uses the difference, so a
      // tablet clock that is off cancels out; a save made now gets the database time
      const args = { p_ops: ops, p_qid: qid, ...(at && clientAtOk ? { p_client_at: new Date(at).toISOString(), p_client_now: new Date().toISOString() } : {}) };
      let { data, error } = await sb.rpc('save_ops', args);
      if (error && error.code === 'PGRST202' && args.p_client_at) {   // a database still at v0.96: same save without the time
        clientAtOk = false; delete args.p_client_at; delete args.p_client_now; ({ data, error } = await sb.rpc('save_ops', args));
      }
      if (!error) { st.out = data; st.done = ops.length; return data; }
      if (error.code !== 'PGRST202') throw error;              // PGRST202 = server without save_ops yet: old way
      atomicOk = false;
    }
    const out = st.out || (st.out = []);
    for (let k = st.done || 0; k < ops.length; k++) {
      const op = ops[k];
      if (op.rpc) { const { data, error } = await sb.rpc(op.rpc, op.args); if (error) throw error; out[k] = data; st.done = k + 1; continue; }
      const row = JSON.parse(JSON.stringify(op.row), (key, v) => { const m = typeof v === 'string' && v.match(REF); return m ? (out[Number(m[1])] || {})[m[2]] : v; });
      let q = op.update ? sb.from(op.table).update(row).match(op.update).select().single()
                        : sb.from(op.table).insert(row).select().single();
      let { data, error } = await q;
      if (error && error.code === '23505' && row.id && !op.update) {   // already saved on an earlier attempt: reuse it
        const again = await sb.from(op.table).select().eq('id', row.id).maybeSingle();
        if (again.data) ({ data, error } = again);
        else error = { ...error, message: 'Valore già registrato (doppione): ' + (error.details || error.message) };
      }
      if (error) throw error; out[k] = data; st.done = k + 1;
    }
    return out;
  }
  let flushing = false;
  async function flush() {
    if (flushing) return;
    if (!queue().length || !navigator.onLine) return;
    flushing = true;                                            // v1.10: taken before the first wait, so two flushes never send the same items
    let signedIn = false;
    try { signedIn = !!staff && !!(await PERM.session(sb)); } catch {}
    if (!signedIn) { flushing = false; return; }                // v0.59: logged out → keep the queue for the next login (it used to fail every item)
    const q = queue(); if (!q.length) { flushing = false; return; }
    q.forEach(i => { if (!i.qid) i.qid = uuid(); }); setQueue(q);   // v0.56: every item gets an id (same tick as the read, so nothing is lost)
    try {
      try { await sb.auth.getSession(); } catch {}           // refreshes an expired login before re-sending
      const left = [], failed = [], blocked = new Set();
      failedList().forEach(f => { const d = opDeps(f.ops); [...d.keys, ...d.made].forEach(k => blocked.add(k)); });   // refused earlier and not redone yet
      for (let i = 0; i < q.length; i++) {
        const item = q[i];
        // v0.97: a lot renamed after this item was queued (once: an item already moved to a new letter is not moved again)
        if (!(item.st && item.st.done > 0)) { const got = applyRenames(item.ops, item.at || 0, item.renamed || []); if (got.length) item.renamed = [...(item.renamed || []), ...got]; }
        stamp(item.ops);                                      // items queued by older versions get their ids now
        // v0.97 (audit A-08): a record that depends on one the database refused (its batch start, its milk) is not sent on its own:
        // it is set aside with it, so a vat's steps and close can't land on another tablet's lot of the same letter
        const dep = opDeps(item.ops), hold = () => [...dep.keys, ...dep.made].forEach(k => blocked.add(k));
        if ([...dep.keys, ...dep.used].some(k => blocked.has(k))) {
          hold();
          failed.push({ ...item, error: 'Non inviata: dipende da una registrazione rifiutata qui sopra (stesso lotto o stesso latte). Rifalle insieme.', code: 'DEPENDS', failed_at: Date.now() });
          continue;
        }
        try { const out = await run(item.ops, item.st || (item.st = { done: 0, out: [] }), item.qid, item.at); await checkRenames(item.ops, out); }
        catch (e) {
          console.error(e);
          // v0.62: strictly in order — when the network drops, stop here (a batch's steps must never arrive before the batch)
          if (retryable(e)) { left.push(...q.slice(i)); break; }
          hold();
          failed.push({ ...item, error: e.message, detail: e.details || null, code: e.code, failed_at: Date.now() });
        }
      }
      const seen = new Set(q.map(i => i.qid));                  // v0.56: keep what save() queued while this flush was sending
      const added = queue().filter(i => !seen.has(i.qid));
      setQueue([...left, ...added]);
      if (added.length && !left.length) setTimeout(flush, 500);  // v0.62: send those now instead of at the next minute
      if (failed.length) { setFailed([...failedList(), ...failed]); toast(failed.length === 1 ? '1 registrazione NON salvata: guarda il riquadro rosso in alto e rifalla' : `${failed.length} registrazioni NON salvate: guarda il riquadro rosso in alto e rifalle`, 'err', 8000); }
      const sent = q.length - left.length - failed.length;
      if (sent > 0) { toast(`Inviate ${sent} registrazioni`); loadTasks(); warmLots(); }
    } finally { flushing = false; setTimeout(checkin, 300); setTimeout(uploadPhotos, 600); }
  }
  window.addEventListener('online', flush);
  setInterval(() => { if (queue().length) flush(); }, 60000);   // online event is unreliable on some tablets
  // v0.74: the tablet checks in (app version, offline queue, refused saves) so the office knows; refused saves are sent
  // to the database in full (fabula.tablet_rejects) and announced on the bell, so deleting them here no longer loses them.
  const DUK = 'perla_device_uid', REPK = 'perla_failed_reported';
  const deviceUid = () => { try { let u = localStorage.getItem(DUK); if (!u) { u = uuid(); localStorage.setItem(DUK, u); } return u; } catch { return 'nostorage-' + CFG.device; } };
  const reported = () => new Set(readList(REPK));
  let appVer = null;
  async function appVersion() {
    if (appVer) return appVer;
    try { const ks = await caches.keys(); const k = ks.find(x => /^perla-v\d+$/.test(x)); if (k) return (appVer = k); } catch {}
    try { const t = await (await fetch('sw.js', { cache: 'no-cache' })).text(); const m = t.match(/CACHE\s*=\s*'(perla-v\d+)'/); if (m) return (appVer = m[1]); } catch {}
    return null;
  }
  let checkingIn = false;
  async function checkin() {
    if (checkingIn || !staff || !navigator.onLine) return; checkingIn = true;
    try {
      const q = queue(), rep = reported(), fresh = failedList().filter(f => f.qid && !rep.has(f.qid));
      const ver = await appVersion();
      const { data, error } = await live(sb.rpc('device_checkin', { p_device_uid: deviceUid(), p_label: CFG.device, p_version: ver, p_queue_len: q.length,
        p_oldest: q.length ? new Date(Math.min(...q.map(i => i.at || Date.now()))).toISOString() : null,
        p_failed: fresh.map(f => ({ qid: f.qid, ops: f.ops, error: f.error, code: f.code, failed_at: f.failed_at })), p_user_agent: navigator.userAgent.slice(0, 200) }), 8000);
      if (error) return;                                      // older database or no network: try again later
      if (fresh.length) { try { localStorage.setItem(REPK, JSON.stringify([...rep, ...fresh.map(f => f.qid)].slice(-500))); } catch {} showPending(); }
      const bn = $('update-banner');
      if (bn) bn.style.display = data && data.live_version && ver && data.live_version !== ver ? '' : 'none';
    } catch (e) { console.warn('checkin', e); } finally { checkingIn = false; }
  }
  setInterval(checkin, 5 * 60000);
  // v0.97 (audit A-20): a DDT photo taken without network waits on the tablet (IndexedDB) and goes up after its record
  const PDB = 'perla_photos', PST = 'p';
  const idb = () => new Promise((res, rej) => { const r = indexedDB.open(PDB, 1); r.onupgradeneeded = () => r.result.createObjectStore(PST, { keyPath: 'id' }); r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error); });
  async function idbDo(mode, fn) { const db = await idb(); return new Promise((res, rej) => { const tx = db.transaction(PST, mode); const rq = fn(tx.objectStore(PST)); tx.oncomplete = () => res(rq ? rq.result : null); tx.onerror = () => rej(tx.error); }); }
  async function putPhoto(file, meta) {
    const { error } = await sb.storage.from('documents').upload(meta.path, file, { upsert: true }); if (error) throw error;
    const { error: de } = await sb.from('documents').insert({ kind: meta.kind, storage_path: meta.path, original_filename: file.name || 'foto.jpg', mime_type: file.type || 'image/jpeg', document_date: meta.date,
      related_table: meta.related_table || null, related_id: meta.related_id || null, uploaded_by_id: meta.by || null });
    if (de) throw de;
  }
  async function savePhoto(file, meta) {        // 'up' = uploaded now · 'kept' = waits on the tablet · 'lost' = could not keep it
    if (navigator.onLine && !queue().length) { try { await putPhoto(file, meta); return 'up'; } catch (e) { console.warn('photo', e); } }
    try { if (!window.indexedDB) return 'lost'; await idbDo('readwrite', s => s.put({ id: uuid(), file, meta, at: Date.now() })); return 'kept'; } catch (e) { console.warn('photo keep', e); return 'lost'; }
  }
  let uploading = false;
  async function uploadPhotos() {
    if (uploading || !navigator.onLine || !staff || !window.indexedDB) return; uploading = true;
    try {
      const all = await idbDo('readonly', s => s.getAll());
      for (const p of all || []) {
        if (queue().some(i => (i.ops || []).some(o => o.row && o.row.id === p.meta.related_id))) continue;   // its record is still waiting
        try { await putPhoto(p.file, p.meta); await idbDo('readwrite', s => s.delete(p.id)); } catch (e) { console.warn('photo up', e); break; }
      }
    } catch (e) { console.warn('photos', e); } finally { uploading = false; }
  }
  // ---------- Refused saves (v0.97, audit A-11): a red banner on Home, a screen that says what each one was, «Rifai» ----------
  const isRef = v => typeof v === 'string' && v.startsWith('$');
  // what a queued save makes and uses (v0.97, audit A-08): batch lots and batch ids both ways (a refused start, step or close holds back
  // everything else of that lot); milk only one way (a refused milk arrival holds back what uses it, a refused vat does not hold back
  // another vat from the same milk)
  function opDeps(ops) {
    const keys = new Set(), made = new Set(), used = new Set();
    const lot = v => { if (v && !isRef(v)) keys.add('lot:' + String(v).replace(/^LOT:/i, '').toUpperCase()); }, id = v => { if (v && !isRef(v)) keys.add('id:' + v); };
    const milk = (set, v) => { if (v && !isRef(v)) set.add('milk:' + String(v).toUpperCase()); };
    for (const op of ops || []) {
      const r = op.row || {}, a = op.args || {}, u = op.update || {};
      if (op.table === 'scan_events') continue;
      if (op.table === 'milk_intake' && !op.update) { milk(made, r.id); milk(made, r.milk_lot); continue; }
      if (op.table === 'production_batches') { if (!op.update) id(r.id); lot(r.batch_lot); lot(u.batch_lot); id(u.id); continue; }
      if (op.table === 'labels') { if (r.kind === 'milk_lot') { milk(made, r.lot_number); continue; } lot(r.lot_number); id(r.batch_id); continue; }
      if (op.table === 'stock_moves') { if (r.move_type === 'production_in') milk(used, r.lot_number); else lot(r.lot_number); id(r.batch_id); continue; }
      if (op.table === 'batch_milk_inputs') { id(r.batch_id); milk(used, r.milk_intake_id); continue; }
      milk(used, r.milk_intake_id); milk(used, a.p_milk_intake_id); id(r.batch_id); lot(a.p_batch_lot); lot(a.p_parent_lot);
      if (op.rpc === 'start_byproduct_batch' && a.p_parent_lot) lot('R' + String(a.p_parent_lot).slice(1));
    }
    return { keys: [...keys], made: [...made], used: [...used] };
  }
  const cpName = code => ((refStore()['cp_' + code] || {}).name) || code;
  // one line in Italian for what a queued save was, and where to redo it (+ the values, to fill the form again)
  // what kind of record a save is (to know when «Rifai» has really redone it), the time and person of a check for the paper form
  function redoKind(ops) {
    ops = resolveRefs(ops);
    const f = (t, pred = () => true) => ops.find(o => o.table === t && pred(o)), r = n => ops.find(o => o.rpc === n), U = v => String(v || '').toUpperCase();
    let o;
    if ((o = f('milk_intake'))) return 'milk:' + U(o.row.ddt_number || o.row.milk_lot);
    if ((o = f('production_batches', x => !x.update))) { const mv = f('stock_moves'); return 'start:' + U(mv && mv.row.lot_number); }
    if ((o = f('production_batches', x => !!x.update))) { const mv = f('stock_moves'); return 'close:' + U((o.update && o.update.batch_lot) || (mv && mv.row.lot_number) || o.update.id); }
    if ((o = r('log_milk_check'))) return 'ccp:' + o.args.p_cp_code;
    if ((o = r('log_ccp'))) return 'ccp:' + o.args.p_cp_code + ':' + U(o.args.p_batch_lot);
    if ((o = r('log_batch_step'))) return 'step:' + U(o.args.p_batch_lot);
    if ((o = r('record_batch_consumable'))) return 'step:' + U(o.args.p_batch_lot);
    if ((o = f('haccp_log'))) return 'clean';
    if ((o = f('meter_readings'))) return 'meter';
    if ((o = r('receive_purchase_order'))) return 'po:' + o.args.p_po_number;
    if ((o = f('effluent_log'))) return 'effl';
    return null;
  }
  function describeOps(ops) {
    const d = describeOps0(ops), c = resolveRefs(ops).find(o => o.rpc === 'log_ccp' || o.rpc === 'log_milk_check');
    if (c && d.code && d.code.startsWith('PAPER:')) {          // the paper form: the time the check was made (sheet or tablet) and who made it
      const a = c.args, t = a.p_logged_at ? new Date(a.p_logged_at) : null, who = a.p_written_by || ((opList().find(p => p.id === a.p_staff_id) || {}).full_name);
      d.fill = { ...(d.fill || {}), ...(t && !isNaN(t) ? { pday: ROME_DAY.format(t), ptime: t.toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Rome', hour12: false }) } : {}), ...(who ? { pwho: who } : {}) };
      d.src = a.p_source || 'tablet';
    }
    return { ...d, kind: redoKind(ops) };
  }
  function describeOps0(ops) {
    ops = resolveRefs(ops);
    const f = (t, pred = () => true) => (ops || []).find(o => o.table === t && pred(o)), r = n => (ops || []).find(o => o.rpc === n);
    let o;
    if ((o = f('milk_intake'))) return { what: `Arrivo latte ${o.row.milk_lot || ''} · ${itNum(o.row.qty_kg)} kg · ${itNum(o.row.temperature_c)} °C`, code: 'DDT:' + (o.row.ddt_number || ''),
      fill: { temp: o.row.temperature_c, ddtn: o.row.ddt_number, kg: o.row.qty_kg, kgh: o.row.dairy_kg, lot: o.row.milk_lot } };
    if ((o = f('production_batches', x => !x.update))) { const mv = f('stock_moves');
      return { what: `Inizio lotto ${o.row.batch_lot} · ${itNum(o.row.milk_in_kg)} kg di latte`, code: mv && mv.row.lot_number ? 'LOT:' + mv.row.lot_number : null, fill: { kg: o.row.milk_in_kg } }; }
    if ((o = f('production_batches', x => !!x.update))) { const mv = f('stock_moves'), lot = (o.update && o.update.batch_lot) || (mv && mv.row.lot_number) || '';
      return { what: `Fine lotto ${lot} · ${itNum(o.row.output_kg)} kg`, code: lot ? 'LOT:' + lot : null, fill: { out: o.row.output_kg, ph: o.row.curd_ph } }; }
    if ((o = r('log_milk_check'))) return { what: `${cpName(o.args.p_cp_code)}: ${itNum(o.args.p_value)}`, code: 'PAPER:' + o.args.p_cp_code, fill: { v: o.args.p_value, mi: o.args.p_milk_intake_id } };
    if ((o = r('log_ccp'))) return { what: `${cpName(o.args.p_cp_code)}: ${itNum(o.args.p_value)}${o.args.p_batch_lot ? ' · lotto ' + o.args.p_batch_lot : ''}`,
      code: PAPER_CPS.some(([, c]) => c === o.args.p_cp_code) ? 'PAPER:' + o.args.p_cp_code : 'CCP:' + o.args.p_cp_code, fill: { v: o.args.p_value, lot: o.args.p_batch_lot } };
    if ((o = r('log_batch_step'))) return { what: `Passo di lavorazione · lotto ${o.args.p_batch_lot}${o.args.p_actual != null ? ' · ' + itNum(o.args.p_actual) : ''}`, code: 'LOT:' + o.args.p_batch_lot };
    if ((o = r('record_batch_consumable'))) return { what: `Dosaggio · lotto ${o.args.p_batch_lot} · ${itNum(o.args.p_qty)}`, code: 'LOT:' + o.args.p_batch_lot };
    if ((o = r('start_byproduct_batch'))) return { what: `Avvio ricotta dal lotto ${o.args.p_parent_lot} · ${itNum(o.args.p_whey_kg)} kg di siero`, code: null };
    if ((o = f('haccp_log'))) return { what: 'Sanificazione di fine turno', code: 'CLEAN:' };
    if ((o = f('meter_readings'))) return { what: `Lettura contatore ${itNum(o.row.reading)}`, code: 'METER:' + o.row.meter, fill: { reading: o.row.reading } };
    if ((o = f('shipments'))) return { what: `Spedizione ${o.row.ddt_number || '(numero DDT dal database)'}`, code: null };
    if ((o = r('receive_purchase_order'))) return { what: `Arrivo merce ${o.args.p_po_number}`, code: 'PO:' + o.args.p_po_number };
    if ((o = r('badge_in') || r('badge_out'))) return { what: o.rpc === 'badge_in' ? 'Inizio turno' : 'Fine turno', code: null };
    if ((o = r('close_open_task'))) return { what: 'Attività del giorno segnata come fatta', code: null };
    if ((o = f('effluent_log'))) return { what: `Reflui ${itNum(o.row.qty)} ${o.row.unit || ''}`, code: 'EFFL:' };
    const x = (ops || [])[0] || {}; return { what: x.table || x.rpc || 'registrazione', code: null };
  }
  const when = ms => ms ? new Date(ms).toLocaleString('it-IT', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Rome' }) : '';
  function renderRejects() {
    const b = $('rej-banner'); if (!b) return;
    const f = failedList();
    b.style.display = f.length ? '' : 'none'; if (!f.length) return;
    const d = describeOps(f[0].ops);
    b.innerHTML = `<div class="nt">${f.length === 1 ? '1 registrazione NON salvata' : f.length + ' registrazioni NON salvate'}</div><div>${esc(d.what)} · ${esc(when(f[0].at))}${f.length > 1 ? ` e altre ${f.length - 1}` : ''}</div><button type="button" class="nitem">Tocca per vederle e rifarle ›</button>`;
  }
  $('rej-banner') && $('rej-banner').addEventListener('click', () => stepRejects());
  // «Rifai»: the refused save travels with its scan (current.redo) to the form it opens; it leaves the list only when the same kind of
  // record (same milk, same lot, same check) is saved again — not when another form, a chooser or a «NON ok» is saved
  function markRedo(ops) {
    const r = current && current.redo; if (!r || !r.kind) return;
    if (redoKind(ops) === r.kind) { setFailed(failedList().filter(y => y.qid !== r.qid)); current.redo = null; }
  }
  function stepRejects() {
    $('form').innerHTML = ''; current = { code: 'REJECTS' };
    const f = failedList(), rep = reported();
    if (!f.length) { show('home'); return; }
    if (f.some(x => !rep.has(x.qid))) checkin();
    f.forEach((x, i) => {
      const d = describeOps(x.ops), c = document.createElement('div'); c.className = 'card rej';
      c.innerHTML = `<div class="scan">${esc(d.what)}</div><div class="code">fatta il ${esc(when(x.at))} · rifiutata il ${esc(when(x.failed_at))}</div>`
        + `<div style="margin-top:6px"><b>Perché:</b> ${esc(x.error || '?')}</div>`
        + `<div class="code" style="margin-top:4px">${rep.has(x.qid) ? 'L\'ufficio l\'ha già ricevuta.' : 'Arriva all\'ufficio appena c\'è rete.'}</div>`;
      if (d.code) { const b = document.createElement('button'); b.type = 'button'; b.className = 'btn'; b.textContent = '↻ Rifai';
        b.onclick = () => { redoPending = { what: d.what, at: x.at, fill: d.fill || {}, qid: x.qid, kind: d.kind, src: d.src || null }; handleCode(d.code); }; c.append(b); }
      const rm = document.createElement('button'); rm.type = 'button'; rm.className = 'btn secondary'; rm.textContent = 'Togli dalla lista';
      rm.onclick = async () => {
        if (!reported().has(x.qid)) return toast('Prima deve arrivare all\'ufficio: collegati a internet, poi riprova', 'err', 6000);
        if (!(await ask({ title: 'Togliere dalla lista?', lines: [d.what, 'Non verrà più rifatta da qui: fallo solo se l\'hai già rifatta o se l\'ufficio lo sa.'], yes: 'Sì, togli', no: 'No' }))) return;
        setFailed(failedList().filter(y => y.qid !== x.qid)); stepRejects();
      };
      c.append(rm); $('form').append(c);
    });
    openForm('Registrazioni NON salvate', 'Il database le ha rifiutate: rifalle adesso, con i valori scritti qui', async () => {});
    $('btn-form-save').style.display = 'none';
  }

  // ---------- Auth ----------
  let justLoggedIn = false;
  async function init() {
    const session = await PERM.session(sb);
    // offline with an expired login: supabase keeps the stored session when the refresh fails for lack of network,
    // so a stored user means "logged in, just offline" (a real logout or revoked login clears it)
    const user = (session && session.user) || PERM.storedUser();
    if (!user) return show('login');
    const P = await PERM.load(sb);
    if (!P && PERM.offline) return PERM.deny(sb, PERM.offlineFirstLogin());
    if (!P || !P.staff_id) return PERM.deny(sb, PERM.notLinked(user.email));
    if (!PERM.page('tablet')) return PERM.deny(sb, PERM.notForProfile());
    const { data } = PERM.offline ? { data: null } : await PERM.timeout(sb.from('staff').select('*').eq('id', P.staff_id).maybeSingle().then(x => x, () => ({ data: null })));
    staff = { ...(data || { id: P.staff_id, full_name: P.full_name }), app_role: P.role, role_name: P.role_name };
    if (justLoggedIn) { justLoggedIn = false; setOperator(staff, 'login'); }   // v0.96 (A-01): who typed the password records, until someone else badges
    renderWho(); loadOperators().catch(() => {});
    show('home'); loadTasks(); setQueue(queue()); flush(); if (!PERM.offline) { warmRefs(); warmLots(); } setTimeout(checkin, 1500);
    renderRenames(); setTimeout(uploadPhotos, 3000);
    if (PERM.offline) toast('Offline: profilo salvato su questo tablet. Le registrazioni vanno in coda e partono al ritorno della rete.');
  }
  $('btn-login').onclick = async () => {
    const { error } = await sb.auth.signInWithPassword({ email: $('email').value, password: $('pw').value });
    if (error) return toast('Accesso negato: ' + error.message, 'err'); justLoggedIn = true; init();
  };
  PERM.forgot(sb, toast);
  // v0.95 (audit A-12): records still waiting would be sent later under the next person's login (wrong name, maybe refused):
  // try to send them now, and if they cannot go out, do not log out
  // A second tap within 10 s logs out anyway (Wi-Fi down at shift change, expired login): better than the next person working under
  // this login. The queued records keep the name of who did them (p_staff_id), but may be refused if the next profile has fewer rights.
  let logoutAsk = 0;
  $('btn-logout').onclick = async () => {
    for (let i = 0; i < 20 && flushing; i++) await new Promise(r => setTimeout(r, 500));   // a send already running: wait for it
    if (queue().length && navigator.onLine) await flush();
    const n = queue().length;
    if (n && Date.now() - logoutAsk > 10000) {
      logoutAsk = Date.now();
      toast(`${n === 1 ? 'C\'è 1 registrazione non ancora inviata' : `Ci sono ${n} registrazioni non ancora inviate`}: collegati a internet prima di uscire, partono da sole. Se devi uscire per forza, tocca di nuovo «Esci» entro 10 secondi.`, 'err', 9000);
      return;
    }
    logoutAsk = 0; staff = null; clearOperator(); await sb.auth.signOut(); show('login');
    if (n) toast(`${n === 1 ? '1 registrazione resta' : n + ' registrazioni restano'} su questo tablet: ${n === 1 ? 'parte' : 'partono'} con il prossimo accesso`, 'err', 6000);
  };

  // ---------- Tasks ----------
  async function loadSellDown() {          // lots to sell first today (or pull), with any approved promo price
    const box = $('selldown'), wrap = $('selldown-wrap'); if (!box) return;
    const { data, error } = await sb.from('v_sell_down_today').select('*');
    if (error || !data || !data.length) { wrap.style.display = 'none'; return; }
    wrap.style.display = ''; box.innerHTML = '';
    data.forEach(r => {
      const d = document.createElement('div'); d.className = 'task' + (r.days_left < 0 ? ' overdue' : '');
      const when = r.days_left < 0 ? 'SCADUTO · ritirare' : r.days_left === 0 ? 'scade oggi' : 'scade domani';
      const promo = r.promo_status === 'approved' ? ` · PROMO -${r.promo_pct}% → € ${Number(r.promo_price_eur_kg).toLocaleString('it-IT', { minimumFractionDigits: 2 })}/kg${r.promo_code ? ' · codice cassa ' + r.promo_code : ''}` : r.promo_status === 'pending' ? ' · promo in attesa di ok' : '';
      d.innerHTML = `<div><div>${esc(r.name)} · ${Number(r.kg).toLocaleString('it-IT')} kg</div><div class="code">${esc(r.lot_number)} · ${when}${promo}</div></div>`;
      box.append(d);
    });
  }
  // v0.70: production autopilot — today's batches from the milk on hand (fabula.production_plan). One tap opens the batch
  // start already filled in (milk lot, kg, product, preset); open batches are one tap away from their next step.
  // Offline it shows the last plan of today (kept on the tablet) and drops the loads started meanwhile.
  const PLK = 'perla_plan_v1';
  let planCache = null;
  const hhmm = iso => new Date(iso).toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Rome' });
  const planPut = (p, at) => { planCache = p; try { localStorage.setItem(PLK, JSON.stringify({ at: at || Date.now(), p })); } catch {} };
  let planRun = 0;
  async function loadPlan() {
    const wrap = $('plan-wrap'), box = $('plan'), sum = $('plan-sum'); if (!wrap) return;
    const run = ++planRun;
    if (!PERM.can('produzione', 2)) { wrap.style.display = 'none'; return; }
    let p = null, at = null;
    const r = await live(sb.rpc('production_plan'));
    if (!r.error && r.data) { p = r.data; planPut(p); }
    else { try { const c = JSON.parse(localStorage.getItem(PLK) || 'null'); if (c && c.p && c.p.date === today()) { p = c.p; at = c.at; planCache = p; } } catch {} }
    const done = (p && p.done) || {};
    if (!p || (!p.proposals.length && !p.open.length && !done.batches)) { wrap.style.display = 'none'; return; }
    wrap.style.display = ''; box.innerHTML = '';
    const milkKg = p.proposals.reduce((a, x) => a + Number(x.milk_kg), 0), expKg = p.proposals.reduce((a, x) => a + Number(x.expected_kg), 0);
    sum.textContent = [p.target ? `Obiettivo ${fmtKg(p.target.planned_output_kg)} kg${p.target.status === 'proposed' ? ' (piano latte da approvare)' : ''}` : '',
      done.batches ? `fatti ${fmtKg(done.output_kg)} kg in ${done.batches} lott${done.batches === 1 ? 'o' : 'i'}${done.yield_pct != null ? ` (resa ${String(done.yield_pct).replace('.', ',')}%)` : ''}` : '',
      p.proposals.length ? `da fare ≈ ${fmtKg(Math.round(expKg))} kg da ${fmtKg(milkKg)} kg di latte` : '',
      at ? `senza rete: dati delle ${hhmm(at)}` : ''].filter(Boolean).join(' · ');
    p.open.forEach(b => {
      const d = document.createElement('div'); d.className = 'task';
      d.innerHTML = `<div><div>⏳ ${esc(b.batch_lot)} · ${esc(b.product)} in lavorazione</div><div class="code">${fmtKg(b.milk_in_kg)} kg di ${b.input_kind === 'whey' ? 'siero' : 'latte'}${b.started_at ? ' · avviato alle ' + hhmm(b.started_at) : ''} · attesi ≈ ${fmtKg(b.expected_kg)} kg · tocca per continuare</div></div><time>›</time>`;
      d.onclick = () => handleCode('LOT:' + b.batch_lot); box.append(d);
    });
    p.proposals.forEach(x => {
      const h = (Date.parse(x.use_by) - Date.now()) / 36e5, late = h < 8;
      const due = h <= 0 ? '⚠ oltre le 60 h DOP: non è più DOP' : late ? `⚠ entro le ${hhmm(x.use_by)} (60 h DOP)` : `entro ${new Date(x.use_by).toLocaleDateString('it-IT', { weekday: 'short', timeZone: 'Europe/Rome' })} ${hhmm(x.use_by)}`;
      const d = document.createElement('div'); d.className = 'task go' + (late ? ' overdue' : '');
      d.innerHTML = `<div><div>Avvia lotto: ${fmtKg(x.milk_kg)} kg di latte ${esc(x.milk_lot)}</div><div class="code">${esc(x.product)} · ≈ ${fmtKg(x.expected_kg)} kg (resa ${String(x.yield_pct).replace('.', ',')}%${String(x.yield_source).startsWith('default') ? ' stimata' : ''})${x.small ? ' · lotto piccolo' : ''} · ${due}</div></div><time>▶</time>`;
      d.onclick = () => startFromPlan(x); box.append(d);
    });
    // v0.95 (audit A-16): today's closed mozzarella lots whose whey has not gone into ricotta (online only)
    const [rb, rp] = await Promise.all([live(sb.from('production_batches').select('batch_lot, product_id, output_kg, whey_kg, input_kind, finished_at').eq('batch_date', today())),
                                        live(sb.from('products').select('id, byproduct_product_id').not('byproduct_product_id', 'is', null))]);
    if (run === planRun && !rb.error && rb.data && !rp.error && rp.data) {
      const byp = new Map(rp.data.map(p => [p.id, p.byproduct_product_id])), lots = new Set(rb.data.map(b => b.batch_lot));
      const fresh = b => b.finished_at && Date.now() - Date.parse(b.finished_at) < 4 * 36e5;   // whey waits a few hours at most
      const cand = rb.data.filter(b => b.output_kg != null && b.input_kind !== 'whey' && byp.has(b.product_id) && !lots.has('R' + String(b.batch_lot).slice(1)) && fresh(b) && !(Number(b.whey_kg) > 0))
                          .map(b => ({ ...b, byp: byp.get(b.product_id) })).sort((a, b) => String(a.batch_lot).localeCompare(String(b.batch_lot)));
      if (cand.length) {
        const d = document.createElement('div'); d.className = 'task';
        d.innerHTML = `<div><div>🧀 Avvia ricotta dal siero di oggi</div><div class="code">lotti chiusi nelle ultime 4 ore senza ricotta: ${esc(cand.map(b => b.batch_lot).join(', '))}</div></div><time>▶</time>`;
        d.onclick = () => startRicottaLater(cand); box.append(d);
      }
    }
  }
  async function startFromPlan(x) {
    $('form').innerHTML = ''; current = { code: 'LOT:' + x.milk_lot, plan: x };
    if (!allowed('LOT')) return;
    try { await stepBatchStart({ id: x.milk_intake_id, milk_lot: x.milk_lot, qty_kg: x.left_kg }, x.milk_lot, x); }
    catch (e) { console.error(e); toast(e.message, 'err'); show('home'); }
  }
  const planStarted = (x, kg) => {           // offline view: take the started load out of the kept plan
    if (!planCache) return; let c = null; try { c = JSON.parse(localStorage.getItem(PLK) || 'null'); } catch {}
    const p = planCache; p.proposals = p.proposals.filter(y => !(y.milk_intake_id === x.milk_intake_id && y.seq === x.seq));
    p.proposals.forEach(y => { if (y.milk_intake_id === x.milk_intake_id) y.left_kg = Math.max(0, Math.round((y.left_kg - kg) * 10) / 10); });
    planPut(p, c && c.at);
  };
  async function loadNotices() {           // red banner: what is still missing tonight — tap an item to go straight to its scan
    const wrap = $('notice-wrap'); if (!wrap) return;
    // v1.00 (audit E-03): only the floor's notices (evening HACCP list, lot guard, unknown lab lots); git, cron, bots, Incassi
    // and trade notices stay in the office (Console → Oggi «Avvisi aperti»)
    // v1.05 (audit E-31): the evening list is live from 14:00 (not only from the 19:02 bot); before 14:00 yesterday's food-safety gaps,
    // each opening the paper copy on yesterday's date. The 19:02 notice is not shown twice.
    const [nr, hl] = await Promise.all([sb.from('v_active_notices').select('*').eq('audience', 'floor'), navigator.onLine ? live(sb.rpc('haccp_open_list')) : Promise.resolve({ error: 'offline' })]);
    const H = !hl.error && hl.data ? hl.data : null, hour = Number(new Intl.DateTimeFormat('en-GB', { hour: '2-digit', hourCycle: 'h23', timeZone: 'Europe/Rome' }).format(new Date()));
    if (H) lastHaccp = H;            // offline or slow: keep the last list read (eveningOk checks its day)
    const boxes = [];
    if (H && hour >= 14 && H.count > 0) boxes.push({ key: 'live_today', severity: hour >= 19 ? 'alert' : 'warn', title_it: `Prima di chiudere: ${H.count} ${H.count === 1 ? 'cosa' : 'cose'} da registrare`, items: H.items });
    if (H && hour < 14 && H.yesterday && H.yesterday.count > 0) boxes.push({ key: 'live_yesterday', severity: 'alert', title_it: `Ieri non registrato: ${H.yesterday.count} · ricopia dal foglio di carta`, items: H.yesterday.items });
    const data = [...boxes, ...((nr.data || []).filter(n => !(H && String(n.key).startsWith('haccp_evening:'))))];
    if (!data.length) { wrap.style.display = 'none'; return; }
    wrap.style.display = ''; wrap.innerHTML = '';
    data.forEach(n => {
      const d = document.createElement('div'); d.className = 'notice ' + n.severity;
      d.innerHTML = `<div class="nt">${esc(n.title_it)}</div>`;
      (n.items || []).forEach(it => {                 // v0.59: items with no scan (lot guard, heartbeat, watchdog) are text, not a dead button
        const label = it.label_it || it.label || it.title_it || it.scan || '';
        if (!label) return;
        if (!it.scan) { const t = document.createElement('div'); t.className = 'code'; t.textContent = label; d.append(t); return; }
        const b = document.createElement('button'); b.className = 'nitem'; b.textContent = label + ' ›';
        // v0.96 (A-01): «badge di uscita non passato» closes that person's shift (with a confirm); it never makes them the one recording
        b.onclick = () => String(it.scan).startsWith('STAFF:') ? shiftOutCard(it.scan).catch(e => { toast(e.message, 'err'); show('home'); }) : handleCode(it.scan); d.append(b); });
      wrap.append(d);
    });
  }
  async function loadShifts() {            // who is clocked in right now
    const el = $('onshift'); if (!el) return;
    let { data, error } = await sb.rpc('floor_open_shifts');   // v0.59: works for floor profiles too (v_open_shifts needs personale ≥ 1)
    if (error) ({ data } = await sb.from('v_open_shifts').select('full_name, hours_so_far'));
    el.textContent = data && data.length ? 'In turno: ' + data.map(r => `${r.full_name} (${Number(r.hours_so_far).toLocaleString('it-IT')} h)`).join(', ') : 'Nessuno in turno · passa il badge per iniziare';
    loadOperators().catch(() => {});   // v0.96: keeps the tablet's list of people (badge, PIN, in turno) fresh
  }
  async function loadTasks() {
    loadSellDown(); loadNotices(); loadShifts(); loadShipCount(); loadPlan();
    let { data, error } = await sb.from('v_tasks_open').select('*');
    const box = $('tasks'); box.innerHTML = '';
    // v0.78: the last list is kept on the tablet, so the day's tasks still show without network
    const TK = 'perla_tasks_v1';
    if (!error && data) { try { localStorage.setItem(TK, JSON.stringify({ at: Date.now(), day: today(), data })); } catch {} }
    else {
      let c = null; try { c = JSON.parse(localStorage.getItem(TK) || 'null'); } catch {}
      if (!c || c.day !== today()) { box.textContent = 'Lista non disponibile senza rete (non ancora salvata oggi su questo tablet)'; return; }
      // v0.79: each queued close hides only ONE task — the earliest open one it matches, as close_open_task does on the server
      // (a twice-daily cold-room check done in the morning must leave the evening one on the list)
      const closes = queue().flatMap(i => (i.ops || []).filter(o => o.rpc === 'close_open_task').map(o => ({ ...(o.args || {}), _at: (o.args && o.args.p_at) ? Date.parse(o.args.p_at) : (i.at || Date.now()) })));
      const left = [...c.data].sort((a, b) => String(a.due_at).localeCompare(String(b.due_at)));
      // v0.97 (audit A-05): same rule as close_open_task — with more than one of that task in the day, only one whose time has come
      closes.forEach(a => {
        const match = t => !t.followup_kind && ((a.p_code && t.code === a.p_code) || (a.p_control_point_id && t.control_point_id === a.p_control_point_id) || (a.p_equipment_id && t.equipment_id === a.p_equipment_id));
        const all = left.map((t, k) => ({ t, k, due: Date.parse(t.due_at) })).filter(x => match(x.t));
        const ok = all.filter(x => all.length === 1 || x.due - 3 * 36e5 <= a._at);
        const inWin = x => a._at >= x.due - 3 * 36e5 && a._at <= x.due + 6 * 36e5;
        ok.sort((x, y) => (inWin(y) - inWin(x)) || (x.due - y.due));
        if (ok.length) left.splice(ok[0].k, 1);
      });
      // a queued reading of a control point also takes its follow-up («ricontrolla») off the list
      const cpDone = new Set(queue().flatMap(i => (i.ops || []).filter(o => (o.rpc === 'log_ccp' || o.rpc === 'log_milk_check') && o.args).map(o => o.args.p_cp_code)));
      for (let k = left.length - 1; k >= 0; k--) if (left[k].followup_kind === 'recheck' && cpDone.has(left[k].control_point_code)) left.splice(k, 1);
      data = left;
      const n = document.createElement('div'); n.className = 'code'; n.textContent = `Senza rete: elenco delle ${hhmm(c.at)} · le attività fatte ora si chiudono al ritorno della rete`; box.append(n);
    }
    // v0.97 (audit A-05/A-15): follow-ups («ricontrolla», «in caldaia entro») in their own red box on top with the time left;
    // «Da fare oggi» only today's; earlier days apart, with «Non fatta» (reason) so they stop piling up
    const nowDay = today(), dayOf = t => t.due_day || (t.due_at ? ROME_DAY.format(new Date(t.due_at)) : nowDay);
    const fus = data.filter(t => t.followup_kind), todays = data.filter(t => !t.followup_kind && dayOf(t) >= nowDay), older = data.filter(t => !t.followup_kind && dayOf(t) < nowDay);
    renderFollowups(fus);
    const route = t => () => t.scan ? handleCode(t.scan) : t.equipment_code ? handleCode('EQ:' + t.equipment_code) : t.code === 'T-COUNT' ? stepStockCount() : t.code === 'T-CLEAN' ? handleCode('CLEAN:')
      : t.code === 'T-CL' ? handleCode('CCP:PRP-WATER-CL') : t.code === 'T-PEST' ? handleCode('PEST:')
      : t.control_point_code ? handleCode('CCP:' + t.control_point_code) : startScan();   // v0.57: valvola deviatrice, salamoia…
    const row = (t, withDay) => {
      const d = document.createElement('div'); d.className = 'task ' + t.status;
      d.innerHTML = `<div><div>${esc(t.title_it)}</div><div class="code">${esc(t.equipment_code || t.code)}${t.status === 'overdue' ? ' · in ritardo' : ''}</div></div><time>${withDay ? esc(fmtDay(dayOf(t))) + ' ' : ''}${hhmm(t.due_at)}</time>`;
      d.onclick = route(t);
      const sk = document.createElement('button'); sk.type = 'button'; sk.className = 'skip'; sk.textContent = 'Non fatta…';
      sk.onclick = e => { e.stopPropagation(); skipTask(t).catch(err => toast(err.message, 'err')); };
      d.append(sk); return d;
    };
    if (!todays.length) box.append('Tutto fatto ✓');
    todays.forEach(t => box.append(row(t, false)));
    const ob = $('tasks-old'), ow = $('tasks-old-wrap');
    if (ob && ow) { ob.innerHTML = ''; ow.style.display = older.length ? '' : 'none'; older.forEach(t => ob.append(row(t, true))); }
  }
  function renderFollowups(list) {
    const box = $('followups'); if (!box) return; lastFus = list || [];
    box.innerHTML = ''; box.style.display = list.length ? '' : 'none';
    list.forEach(t => {
      const min = Math.round((Date.parse(t.due_at) - Date.now()) / 6e4);
      const d = document.createElement('div'); d.setAttribute('role', 'button'); d.className = 'fu' + (min < 0 ? ' late' : min <= 15 ? ' soon' : '');
      d.innerHTML = `<div class="fu-t">${esc(t.title_it)}</div><div class="fu-m">${min < 0 ? `IN RITARDO di ${-min} min` : min < 60 ? `mancano ${min} min` : `mancano ${Math.floor(min / 60)} h ${min % 60} min`} · tocca per farlo ora ›</div>`;
      d.onclick = () => t.scan ? handleCode(t.scan) : t.equipment_code ? handleCode('EQ:' + t.equipment_code) : startScan();
      // the milk went elsewhere, the cold room was emptied…: «Non serve più» with the reason (stays in the register)
      const sk = document.createElement('span'); sk.className = 'skip'; sk.textContent = 'Non serve più…'; sk.setAttribute('role', 'button');
      sk.onclick = e => { e.stopPropagation(); skipTask(t).catch(err => toast(err.message, 'err')); };
      d.append(sk); box.append(d);
    });
  }
  let lastFus = [];
  setInterval(() => { renderFollowups(lastFus); }, 60000);                 // the minutes left stay current (no network)
  setInterval(() => { const a = $('v-home'); if (a && a.classList.contains('active') && navigator.onLine && !busy()) loadTasks(); }, 5 * 60000);
  async function skipTask(t) {
    if (!navigator.onLine) throw new Error('Per segnare «non fatta» serve la rete');
    if (needOperator(() => { show('home'); skipTask(t).catch(e => toast(e.message, 'err')); }, 'Chi dice che non è stata fatta? Passa il badge o tocca il tuo nome')) return;
    const why = await ask({ title: 'Non fatta: perché?', lines: [t.title_it + ' · ' + fmtDay(t.due_day || today()) + ' ' + hhmm(t.due_at), 'Resta nel registro come «non fatta» con il motivo.'],
      yes: 'Segna come non fatta', no: 'Annulla', input: { label: 'Motivo', placeholder: 'es. cella vuota e spenta, pH-metro in riparazione', min: 3 } });
    if (!why) return;
    const { error } = await sb.rpc('skip_task', { p_task_id: t.id, p_reason: why, p_staff_id: me().id });
    if (error) throw error;
    toast('Segnata come non fatta ✓'); loadTasks();
  }
  async function closeTask(filter, scanEventId) {   // marks today's matching open task done — v0.59: one RPC, queued when offline, for the Agropoli day it was done
    try {
      await save([{ rpc: 'close_open_task', args: { p_day: today(), p_code: filter.code || null, p_equipment_id: filter.equipment_id || null, p_control_point_id: filter.control_point_id || null, p_staff_id: me().id, p_scan_event_id: scanEventId || null } }]);
    } catch (e) { console.warn('closeTask', e); }
  }
  // v0.59: reference data (machines, control points, milk suppliers, pest stations) is kept on the device, so the
  // temperature, milk-intake, cleaning, CCP and pest forms open with no network (the records then go into the queue)
  const CK = 'perla_ref_v1';
  const refStore = () => { try { return JSON.parse(localStorage.getItem(CK) || '{}'); } catch { return {}; } };
  const putRef = (patch) => { try { localStorage.setItem(CK, JSON.stringify({ ...refStore(), ...patch })); } catch {} };
  async function cached(key, fn) {
    let r; try { r = await PERM.timeout(fn(), navigator.onLine ? 8000 : 0); } catch (e) { r = { data: null, error: e }; }
    if (r && !r.error && r.data != null) { putRef({ [key]: r.data }); return { data: r.data, error: null }; }
    const st = refStore(); if (key in st) return { data: st[key], error: null, cached: true };
    return { data: r ? r.data : null, error: (r && r.error) || null };
  }
  const TABLET_SETTINGS = ['prod.vat_kg', 'prod.yield_min_pct', 'prod.yield_max_pct', 'prod.ricotta_yield_min_pct', 'prod.ricotta_yield_max_pct'];
  // read again when a batch starts or closes (a manager may have changed them since the tablet started); offline: the kept copy
  async function refreshSettings() {
    const r = await live(sb.from('settings').select('key, value').in('key', TABLET_SETTINGS), 4000);
    if (!r.error && Array.isArray(r.data) && r.data.length) putRef({ settings: { ...(refStore().settings || {}), ...Object.fromEntries(r.data.map(x => [x.key, x.value])) } });
  }
  // v0.98: the database asks for a confirmation (HINT confirm) that the tablet did not ask itself (other numbers on the server):
  // ask now, then send the same save confirmed
  async function saveConfirm(ops, idx, since = null) {
    try { return await save(ops, since); }
    catch (e) {
      if (!(e && e.hint === 'confirm')) throw e;
      const msg = String(e.message || '').replace(/^Passo \d+ di \d+ \([^)]*\):\s*/, '');
      if (!(await ask({ danger: true, title: 'Controlla', lines: [msg, 'È giusto?'], yes: 'Sì, è giusto', no: 'No, correggo' }))) throw stop();
      ops[idx].args.p_confirm = true; return save(ops, since);
    }
  }
  async function warmRefs() {                       // after login, in the background: one read per list
    try {
      const [eq, cps, sup, pest, cust, set] = await Promise.all([sb.from('equipment').select('*').eq('active', true), sb.from('haccp_control_points').select('*').eq('active', true),
        sb.from('parties').select('id, legal_name').eq('is_milk_supplier', true).eq('active', true), sb.from('pest_stations').select('code, kind, location_it, inside').eq('active', true).order('inside', { ascending: false }).order('code'),
        sb.from('parties').select('id, legal_name').in('type', ['customer', 'both']).eq('active', true).order('legal_name'),
        sb.from('settings').select('key, value').in('key', TABLET_SETTINGS)]);
      const patch = {};
      if (set.data) patch.settings = Object.fromEntries(set.data.map(r => [r.key, r.value]));   // v0.98: vat size and possible yields, offline too
      (eq.data || []).forEach(e => { patch['eq_' + e.code] = e; });
      (cps.data || []).forEach(c => { patch['cp_' + c.code] = c; if (c.equipment_id && c.code !== 'CCP-MILK-TEMP') patch['cp_eq_' + c.equipment_id] = c; });
      if (sup.data) patch.milk_suppliers = sup.data; if (pest.data) patch.pest_stations = pest.data; if (cust.data) patch.customers = cust.data;   // v0.78
      putRef(patch);
    } catch (e) { /* offline: keep what we have */ }
  }
  // ---------- Lots on the device (v0.62) ----------
  // Recent milk lots, open and recent batches, their milk inputs and done steps, and the products are kept on the tablet
  // (refreshed after login, after each online save that touches them, after a flush and every 5 minutes). What is still
  // waiting in the offline queue is laid over that copy, so a lot received offline can start a batch offline, and a
  // batch started offline can run its steps and close offline. Everything then reaches the database in order.
  const LK = 'perla_lots_v1', LOT_DAYS = 10;
  const lotStore = () => { try { return JSON.parse(localStorage.getItem(LK) || 'null') || {}; } catch { return {}; } };
  const lotEq = (a, b) => String(a || '').toLowerCase() === String(b || '').toLowerCase();
  let warmLotsT = null;
  const lotsChanged = () => { if (!navigator.onLine) return; clearTimeout(warmLotsT); warmLotsT = setTimeout(warmLots, 1500); };
  // a read that gives up quickly: offline → no wait; Wi-Fi up but no internet → 8 s
  const live = (q, ms = 8000) => PERM.timeout(Promise.resolve(q).then(x => x, e => ({ data: null, error: e })), navigator.onLine ? ms : 0);
  const unreachable = e => !!e && (PERM.isNetworkError(e) || e.name === 'Timeout' || retryable(e));
  async function warmLots() {
    if (!navigator.onLine || !staff) return;
    try {
      const since = addDays(today(), -LOT_DAYS);
      loadRecipes(); loadPresets();                  // both keep their own copy on the device (dosing and process steps offline)
      const [milk, open, recent, prods] = await Promise.all([
        live(sb.from('milk_intake').select('id, milk_lot, qty_kg, intake_date, accepted, rejection_reason, created_at').gte('intake_date', since).order('intake_date', { ascending: false }).order('created_at', { ascending: false }).limit(500)),
        live(sb.from('production_batches').select('*').is('output_kg', null).limit(200)),
        live(sb.from('production_batches').select('*').gte('batch_date', since).limit(500)),
        live(sb.from('products').select('id, name, sku, kind, active, shelf_life_days, byproduct_product_id, is_dop'))]);
      if ([milk, open, recent, prods].some(r => r.error || !r.data)) return;      // keep the previous copy
      const byId = new Map(); [...recent.data, ...open.data].forEach(b => byId.set(b.id, b));
      const openIds = open.data.map(b => b.id), lotOf = id => (byId.get(id) || {}).batch_lot;
      // v0.95: milk inputs of every recent batch (closed ones too), so the milk still left is right offline as well
      const [inp, stp] = await Promise.all([live(sb.from('batch_milk_inputs').select('batch_id, milk_intake_id, qty_kg, production_batches!inner(batch_date)').gte('production_batches.batch_date', since).limit(2000)),
                                            openIds.length ? live(sb.from('batch_step_logs').select('batch_id, step_id').in('batch_id', openIds)) : { data: [] }]);
      if (inp.error || stp.error) return;
      localStorage.setItem(LK, JSON.stringify({ at: Date.now(), milk: milk.data, batches: [...byId.values()], inputs: (inp.data || []).map(({ batch_id, milk_intake_id, qty_kg }) => ({ batch_id, milk_intake_id, qty_kg })), steps: (stp.data || []).map(x => ({ ...x, batch_lot: lotOf(x.batch_id) })), products: prods.data }));
    } catch (e) { console.warn('warmLots', e); }
  }
  setInterval(() => { if (navigator.onLine && staff) warmLots(); }, 5 * 60000);
  function lotView() {                              // the device copy + everything still waiting in the queue
    const c = lotStore();
    const v = { at: c.at || 0, milk: [...(c.milk || [])], batches: (c.batches || []).map(b => ({ ...b })), inputs: [...(c.inputs || [])], steps: [...(c.steps || [])], products: c.products || [] };
    for (const item of queue()) {
      const ops = item.ops || [];
      const ref = x => { const m = typeof x === 'string' && x.match(REF); return m ? ((ops[Number(m[1])] || {}).row || {})[m[2]] : x; };
      const rowOf = op => Object.fromEntries(Object.entries(op.row || {}).map(([k, x]) => [k, ref(x)]));
      for (const op of ops) {
        if (op.table === 'milk_intake' && !op.update) v.milk.unshift({ ...rowOf(op), pending: true });
        else if (op.table === 'production_batches' && !op.update) v.batches.push({ output_kg: null, input_kind: 'milk', ...rowOf(op), pending: true });
        else if (op.table === 'production_batches') { const b = v.batches.find(x => Object.entries(op.update).every(([k, y]) => x[k] === ref(y))); if (b) Object.assign(b, rowOf(op)); }
        else if (op.table === 'batch_milk_inputs') v.inputs.push(rowOf(op));
        else if (op.rpc === 'log_batch_step') v.steps.push({ batch_lot: op.args.p_batch_lot, step_id: op.args.p_step_id });
        else if (op.rpc === 'start_byproduct_batch') {
          const parent = v.batches.find(x => lotEq(x.batch_lot, op.args.p_parent_lot)), prod = parent && v.products.find(p => p.id === parent.product_id);
          v.batches.push({ id: null, batch_lot: 'R' + String(op.args.p_parent_lot).slice(1), product_id: prod ? prod.byproduct_product_id : null, milk_in_kg: op.args.p_whey_kg, input_kind: 'whey', output_kg: null, batch_date: today(), pending: true });
        }
      }
    }
    return v;
  }
  const cachedProduct = id => (lotView().products || []).find(p => p.id === id) || null;
  const scanEvent = (code, action, extra = {}) => ({ table: 'scan_events', row: { code, action, staff_id: me().id, device: CFG.device, ...extra } });

  // ---------- Who is recording (v0.96, audit A-01) ----------
  // The tablet stays logged in on one account; the person who records is the "operator": badge scan, or name + 4-digit PIN.
  // It lapses after 15 minutes without a touch (not while a form or a dosing sequence is open) and at badge-out.
  // Every record carries the operator (me()); the database also keeps the logged-in account (entered_by_id).
  const OPK = 'perla_operator_v1', OPLK = 'perla_operators_v1', PINK = 'perla_pinok_v1', IDLE_MS = 15 * 60000;
  let operator = null; try { operator = JSON.parse(localStorage.getItem(OPK) || 'null'); } catch {}
  const readObj = k => { try { return JSON.parse(localStorage.getItem(k) || '{}') || {}; } catch { return {}; } };
  const writeObj = (k, o) => { try { localStorage.setItem(k, JSON.stringify(o)); } catch {} };
  const me = () => operator || staff;                       // who did it (the logged-in account only as a fallback)
  const opIdle = () => !operator || Date.now() - (operator.last || 0) > IDLE_MS;
  const busy = () => ['form', 'dose'].some(v => { const e = $('v-' + v); return e && e.classList.contains('active'); });
  function saveOp() { try { operator ? localStorage.setItem(OPK, JSON.stringify(operator)) : localStorage.removeItem(OPK); } catch {} renderWho(); }
  function setOperator(p, via) { operator = { id: p.id, full_name: p.full_name, badge_code: p.badge_code || null, via, at: Date.now(), last: Date.now() }; saveOp(); }
  function clearOperator() { operator = null; saveOp(); }
  let opTouchSaved = 0;
  const activeView = () => ((document.querySelector('.view.active') || {}).id || '').replace('v-', '');
  document.addEventListener('pointerdown', e => {
    if (!operator) return;
    if (opIdle()) {
      const v = activeView();
      // a form left open for 15 minutes: whoever touches it says who they are first; at the vat (dosing) a long wait is normal
      if (v === 'form' && !$('op-still')) { e.stopPropagation(); e.preventDefault(); askStillYou(); return; }
      if (v !== 'dose') return;                       // Home / scan: lapsed, the next record asks
    }
    operator.last = Date.now(); if (Date.now() - opTouchSaved > 30000) { opTouchSaved = Date.now(); saveOp(); } }, true);
  function askStillYou() {
    const o = operator; if (!o) return;
    const w = document.createElement('div'); w.id = 'op-still';
    w.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.55);z-index:50;display:flex;align-items:center;justify-content:center;padding:16px';
    w.innerHTML = `<div class="card" style="max-width:520px;width:100%;background:var(--paper,#fff)"><div class="scan">Chi sta registrando?</div>
      <p>Questo modulo è aperto da più di 15 minuti a nome di <b>${esc(o.full_name)}</b>.</p>
      <button type="button" class="btn" id="op-still-yes">Sono ${esc(o.full_name)}: continuo</button>
      <button type="button" class="btn secondary" id="op-still-no">Non sono io: annulla il modulo</button></div>`;
    document.body.append(w);
    $('op-still-yes').onclick = () => { operator.last = Date.now(); saveOp(); w.remove(); };
    $('op-still-no').onclick = () => { w.remove(); clearOperator(); show('home'); loadTasks(); toast('Modulo annullato: alla prossima registrazione passa il tuo badge'); };
  }
  setInterval(() => { if (operator && opIdle() && !busy()) { clearOperator(); } }, 30000);
  function renderWho() {
    const w = $('who'); if (!w) return;
    if (!staff) { w.textContent = ''; w.className = 'who'; w.style.display = 'none'; return; }
    w.style.display = '';
    const o = operator && (!opIdle() || busy()) ? operator : null;
    w.textContent = o ? `👤 ${o.full_name} · cambia` : '👤 Chi registra? tocca qui';
    w.className = 'who' + (o ? '' : ' none');
    const a = $('acct'); if (a) a.textContent = `Tablet collegato come ${staff.full_name}`;
  }
  // the people who can record (kept on the tablet: a badge scan works offline too)
  const opList = () => { const c = readObj(OPLK); return Array.isArray(c.list) ? c.list : []; };
  async function loadOperators() {
    if (navigator.onLine) {
      const { data, error } = await live(sb.rpc('floor_operators'));
      if (!error && Array.isArray(data)) { writeObj(OPLK, { at: Date.now(), list: data }); return data; }
    }
    return opList();
  }
  const markShift = (id, on) => { const c = readObj(OPLK); (c.list || []).forEach(p => { if (p.id === id) { p.on_shift = on; p.shift_since = on ? new Date().toISOString() : null; } }); writeObj(OPLK, c); };
  // records need a person: returns true when it opened the "who is recording?" screen (then() runs after the choice)
  function needOperator(then, why) {
    if (operator && (!opIdle() || busy())) { operator.last = Date.now(); return false; }
    if (operator) clearOperator();
    pickOperator(then, why).catch(e => { toast(e.message, 'err'); show('home'); }); return true;
  }
  async function pickOperator(then, why) {
    $('form').innerHTML = ''; current = { code: 'OPERATOR' };
    const list = await loadOperators();
    const bb = document.createElement('button'); bb.type = 'button'; bb.className = 'btn'; bb.textContent = '▣ Passa il badge';
    bb.onclick = () => { scanTarget = code => badgeScan(code, then).catch(e => { toast(e.message, 'err'); show('form'); }); startScan(); };
    $('form').append(bb);
    const h = document.createElement('div'); h.className = 'code'; h.style.margin = '14px 0 4px'; h.textContent = 'Oppure tocca il tuo nome e scrivi il PIN:'; $('form').append(h);
    if (!list.length) { const e = document.createElement('div'); e.className = 'code'; e.textContent = 'Elenco persone non ancora salvato su questo tablet (serve la rete una volta): passa il badge.'; $('form').append(e); }
    list.forEach(p => {
      const b = document.createElement('button'); b.type = 'button'; b.className = 'nitem';
      b.innerHTML = `${esc(p.full_name)}<span class="code" style="display:block;font-weight:400">${p.on_shift ? 'in turno' + (p.shift_since ? ' dalle ' + hhmm(p.shift_since) : '') : 'non in turno'}${p.has_pin ? '' : ' · PIN non impostato: usa il badge'}</span>`;
      b.onclick = () => p.has_pin ? askPin(p, then) : toast(`${p.full_name} non ha un PIN: passa il badge, oppure il titolare lo imposta in Configurazione → Utenti`, 'err', 5000);
      $('form').append(b);
    });
    openForm('Chi sta registrando?', why || 'Ogni registrazione porta il nome di chi la fa: passa il tuo badge', async () => {});
    $('btn-form-save').style.display = 'none';
  }
  function askPin(p, then) {
    $('form').innerHTML = ''; current = { code: 'OPERATOR' };
    const f = field('pin', `PIN di ${p.full_name} (4 cifre)`, 'password'); f.inputMode = 'numeric'; f.maxLength = 4; f.pattern = '[0-9]{4}'; f.autocomplete = 'off';
    if (!p.on_shift) { const d = document.createElement('div'); d.className = 'check'; d.innerHTML = '<input type="checkbox" id="pin-shift" checked><label for="pin-shift" style="margin:0;text-transform:none;color:inherit;font-weight:400">Inizio anche il turno adesso (non risulti in turno)</label>'; $('form').append(d); }
    openForm(p.full_name, 'Scrivi il tuo PIN', async () => {
      const pin = String($('pin').value || '').trim(); if (!/^\d{4}$/.test(pin)) throw new Error('Il PIN è di 4 cifre');
      await checkPin(p, pin);
      setOperator(p, 'pin');
      if ($('pin-shift') && $('pin-shift').checked) await clockIn(p, null);
      toast(`Registra: ${p.full_name}`);
      if (then) { setTimeout(then, 0); return 'stay'; }
    });
  }
  // the PIN is checked on the server (5 wrong → 15 min lock). Offline only a PIN already checked online on THIS tablet
  // (last 30 days) is accepted, from a salted hash kept on the tablet; 5 wrong offline lock it here for 15 minutes too.
  async function pinKey(id, pin) {
    if (!(window.crypto && crypto.subtle)) return null;
    let salt = null; try { salt = localStorage.getItem('perla_dev_salt'); if (!salt) { salt = uuid(); localStorage.setItem('perla_dev_salt', salt); } } catch { return null; }
    const base = await crypto.subtle.importKey('raw', new TextEncoder().encode(String(pin)), 'PBKDF2', false, ['deriveBits']);
    const h = await crypto.subtle.deriveBits({ name: 'PBKDF2', hash: 'SHA-256', salt: new TextEncoder().encode(`${salt}:${id}`), iterations: 200000 }, base, 256);
    return 'p2:' + [...new Uint8Array(h)].map(b => b.toString(16).padStart(2, '0')).join('');   // slow on purpose: a 4-digit PIN kept on the tablet
  }
  async function checkPin(p, pin) {
    let r = null;
    if (navigator.onLine) { const x = await live(sb.rpc('operator_pin_check', { p_staff_id: p.id, p_pin: pin })); if (!x.error) r = x.data; else if (!unreachable(x.error)) throw x.error; }
    const store = readObj(PINK);
    if (r) {
      if (r.ok) { const k = await pinKey(p.id, pin); if (k) { store[p.id] = { k, at: Date.now(), f: 0 }; writeObj(PINK, store); } return true; }
      if (r.why === 'locked') throw new Error(`PIN bloccato fino alle ${hhmm(r.until)} (troppi tentativi sbagliati): passa il badge`);
      if (r.why === 'no_pin') throw new Error(`${p.full_name} non ha ancora un PIN: passa il badge`);
      if (r.why === 'wrong') { $('pin').value = ''; throw new Error(`PIN sbagliato · ${r.left === 1 ? 'ancora 1 tentativo' : `ancora ${r.left} tentativi`}, poi si blocca per 15 minuti`); }
      throw new Error('Persona non attiva: chiedi al titolare');
    }
    const c = store[p.id];
    if (!c || Date.now() - c.at > 30 * 864e5) throw new Error('Senza rete posso controllare solo un PIN già usato su questo tablet: passa il badge');
    if (c.lu && c.lu > Date.now()) throw new Error(`PIN bloccato fino alle ${hhmm(new Date(c.lu).toISOString())}: passa il badge`);
    if ((await pinKey(p.id, pin)) !== c.k) {
      c.f = (c.f || 0) + 1; if (c.f >= 5) { c.f = 0; c.lu = Date.now() + 15 * 60000; } store[p.id] = c; writeObj(PINK, store); $('pin').value = '';
      throw new Error(c.lu > Date.now() ? 'PIN sbagliato 5 volte: bloccato per 15 minuti, passa il badge' : 'PIN sbagliato');
    }
    c.f = 0; c.lu = null; store[p.id] = c; writeObj(PINK, store); return true;
  }
  // badge scan: sets the operator; clocks in if not on shift. The same badge again (already recording) → card with «Fine turno».
  // A second scan never clocks out by mistake (audit A-25).
  async function badgeScan(code, then) {
    let list = opList(), p = list.find(x => x.badge_code === code);
    if (!p || navigator.onLine) { list = await loadOperators(); p = list.find(x => x.badge_code === code) || p; }
    if (!p) throw new Error(`Badge sconosciuto: ${code}${navigator.onLine ? '' : ' (senza rete: elenco persone non ancora salvato su questo tablet)'}`);
    if (!then && operator && operator.id === p.id && !opIdle() && p.on_shift) return badgeCard(p, code);
    setOperator(p, 'badge');
    if (!p.on_shift) { await clockIn(p, code); toast(`${p.full_name}: inizio turno ✓ · ora registri tu`); }
    else toast(`Ora registra: ${p.full_name}`);
    if (then) return then();
    show('home'); loadTasks();
  }
  function badgeCard(p, code) {
    $('form').innerHTML = ''; current = { code };
    const c = document.createElement('div'); c.className = 'card';
    c.innerHTML = `<div class="scan">${esc(p.full_name)}</div><div>In turno${p.shift_since ? ' dalle ' + hhmm(p.shift_since) : ''} · stai registrando tu</div>`;
    const out = document.createElement('button'); out.type = 'button'; out.className = 'btn warn'; out.textContent = 'Fine turno: esco';
    out.onclick = async () => { out.disabled = true; try { if (!(await eveningOk(p))) { out.disabled = false; return; } await clockOut(p, code); } catch (e) { toast(e.message, 'err'); out.disabled = false; } };
    const stay = document.createElement('button'); stay.type = 'button'; stay.className = 'btn secondary'; stay.textContent = 'Continuo a lavorare';
    stay.onclick = () => { show('home'); loadTasks(); };
    $('form').append(c, out, stay);
    $('f-title').textContent = 'Badge'; $('f-sub').textContent = ''; $('btn-form-save').style.display = 'none'; show('form');
    return 'stay';
  }
  // v1.05 (audit E-31): leaving after 14:00 with food-safety records still missing today asks first. The last one on shift is asked
  // everything (evening cold rooms, cleaning, the lots' CCP, milk tests); with others still at work only the lots' CCP and milk tests
  // (the evening checks are theirs to do), so nobody learns to tap «Esco lo stesso» every day
  let lastHaccp = null;
  async function eveningOk(p) {
    const hour = Number(new Intl.DateTimeFormat('en-GB', { hour: '2-digit', hourCycle: 'h23', timeZone: 'Europe/Rome' }).format(new Date()));
    if (hour < 14) return true;
    let H = lastHaccp;
    if (navigator.onLine) { const r = await live(sb.rpc('haccp_open_list')); if (!r.error && r.data) H = lastHaccp = r.data; }
    if (!H || H.date !== today()) return true;      // no list of today (offline since yesterday): nothing to ask
    const others = opList().filter(x => x.on_shift && x.id !== p.id).map(x => x.full_name);
    const fs = (H.items || []).filter(i => (others.length ? /^(ccp:|abx$)/ : /^(cold:|ccp:|clean$|abx$)/).test(i.code || ''));
    if (!fs.length) return true;
    return !!(await ask({ danger: true, title: `Prima di uscire: ${fs.length} ${fs.length === 1 ? 'controllo' : 'controlli'} di sicurezza alimentare da registrare`,
      lines: [...fs.slice(0, 5).map(i => '• ' + i.label_it), fs.length > 5 ? `e altri ${fs.length - 5}` : '', others.length ? `In turno restano: ${others.join(', ')}.` : 'Sei l\'ultimo in turno.'],
      yes: 'Esco lo stesso', no: 'Li registro adesso' }));
  }
  async function shiftOutCard(code) {
    let p = opList().find(x => x.badge_code === code);
    if (!p || navigator.onLine) p = (await loadOperators()).find(x => x.badge_code === code) || p;
    if (!p) throw new Error('Persona sconosciuta: ' + code);
    $('form').innerHTML = ''; current = { code };
    const c = document.createElement('div'); c.className = 'card';
    c.innerHTML = `<div class="scan">${esc(p.full_name)}</div><div>${p.on_shift ? 'Risulta ancora in turno' + (p.shift_since ? ' dalle ' + hhmm(p.shift_since) : '') : 'Non risulta in turno'}: il badge di uscita non è stato passato.</div>`;
    const out = document.createElement('button'); out.type = 'button'; out.className = 'btn warn'; out.textContent = `Chiudi il turno di ${p.full_name} adesso`;
    out.onclick = async () => { out.disabled = true; try { await clockOut(p, code); } catch (e) { toast(e.message, 'err'); out.disabled = false; } };
    const no = document.createElement('button'); no.type = 'button'; no.className = 'btn secondary'; no.textContent = 'Lascia così';
    no.onclick = () => { show('home'); loadTasks(); };
    $('form').append(c, ...(p.on_shift ? [out] : []), no);
    $('f-title').textContent = 'Fine turno'; $('f-sub').textContent = ''; $('btn-form-save').style.display = 'none'; show('form');
  }
  async function clockIn(p, code) {
    await rpcNow('badge_in', { p_badge: code || null, p_staff_id: p.id, p_at: new Date().toISOString() });
    markShift(p.id, true);
    try { await save([scanEvent(code || 'PIN', 'task_done', { payload: { shift: 'in', via: code ? 'badge' : 'pin' } })]); } catch (e) { console.warn('scanEvent', e); }
    loadShifts();
  }
  async function clockOut(p, code) {
    const r = await rpcNow('badge_out', { p_badge: code || null, p_staff_id: p.id, p_at: new Date().toISOString() });
    try { await save([scanEvent(code || 'PIN', 'task_done', { payload: { shift: 'out', hours: r && r.hours } })]); } catch (e) { console.warn('scanEvent', e); }
    markShift(p.id, false);
    if (operator && operator.id === p.id) clearOperator();
    // v1.10: what the database did is what the screen says (nothing closed → «non risultavi in turno»; a forgotten badge-out → closed at the maximum)
    toast(r && r.action === 'none' ? `${p.full_name}: non risultavi in turno (nessun turno chiuso)` :
          r && r.auto_closed ? `${p.full_name}: il turno era aperto da più di ${Number(r.hours).toLocaleString('it-IT')} h, chiuso al massimo: correggi l'ora in Console → Personale` :
          r && r.hours != null ? `${p.full_name}: fine turno ✓ · ${Number(r.hours).toLocaleString('it-IT')} h` : `${p.full_name}: fine turno ✓${r ? '' : ' (parte appena c\'è rete)'}`, r && (r.action === 'none' || r.auto_closed) ? 'err' : undefined, r && r.auto_closed ? 8000 : undefined);
    show('home'); loadTasks();
  }
  $('who').onclick = () => {
    if (!staff) return;
    if (busy()) return toast('Finisci o annulla prima questa registrazione, poi cambia chi registra', 'err');
    if (operator) clearOperator();
    pickOperator(null, 'Chi registra da adesso? Passa il badge o tocca il tuo nome').catch(e => toast(e.message, 'err'));
  };
  // Home: every button that leads to a record asks first who is recording (Scansiona is free: a badge scan needs nobody)
  $('v-home').addEventListener('click', e => {
    const t = e.target.closest('button, .task, .nitem'); if (!t || !staff) return;
    if (t.id === 'btn-scan' || t.id === 'btn-logout' || t.closest('#update-banner') || t.closest('#pending') || t.closest('#selldown') || t.closest('#rej-banner') || t.closest('#renames')) return;
    if (operator && !opIdle()) { operator.last = Date.now(); return; }
    e.stopPropagation(); e.preventDefault();
    needOperator(() => { show('home'); t.click(); });
  }, true);


  // ---------- Scanner ----------
  let scanStarting = null, scanTarget = null;   // scanTarget: one-shot consumer of the next code (lot scan inside a form)
  function startScan() {
    show('scan'); $('manual').value = ''; $('manual').focus();
    if (!window.Html5Qrcode) return;                 // library blocked → manual entry only
    scanner = new Html5Qrcode('reader', { verbose: false });
    scanStarting = scanner.start({ facingMode: 'environment' }, { fps: 10, qrbox: 240 },
        txt => { const code = txt.trim(); stopScan().then(() => { if (scanTarget) { const f = scanTarget; scanTarget = null; f(code); } else handleCode(code); }); }, () => {})
      .catch(() => { toast('Fotocamera non disponibile: scrivi il codice', 'err'); })
      .finally(() => { scanStarting = null; });
  }
  async function stopScan() {
    const s = scanner; scanner = null;
    if (!s) return;
    try { if (scanStarting) await scanStarting; } catch {}
    try { if (s.isScanning) await s.stop(); } catch {}
    try { s.clear(); } catch {}
  }
  $('btn-scan').onclick = startScan;
  $('btn-receive').onclick = async () => {
    $('form').innerHTML = ''; current = { code: 'PO:LIST' };
    const { data, error } = await sb.from('v_open_purchase_orders').select('po_number, supplier, status, expected_date, lines');
    if (error) return toast('Lista ordini non disponibile offline', 'err');
    if (!data || !data.length) return toast('Nessun ordine in arrivo');
    data.forEach(po => {
      const d = document.createElement('div'); d.className = 'task';
      const items = po.lines.map(l => `${esc(l.name)} ${Number(l.remaining).toLocaleString('it-IT')} ${esc(l.unit)}`).join(' · ');
      d.innerHTML = `<div><div>${esc(po.po_number)} · ${esc(po.supplier)}</div><div class="code">${items}${po.status === 'partially_received' ? ' · parziale' : ''}</div></div><time>${po.expected_date ? po.expected_date.slice(8, 10) + '/' + po.expected_date.slice(5, 7) : ''}</time>`;
      d.onclick = () => { $('form').innerHTML = ''; current = { code: 'PO:' + po.po_number }; stepReceive(po.po_number).catch(e => { toast(e.message, 'err'); show('home'); }); };
      $('form').append(d);
    });
    openForm('Arrivo merce', 'Tocca l\'ordine che è arrivato', async () => {});
    $('btn-form-save').style.display = 'none';
  };
  $('btn-scan-cancel').onclick = () => { const back = !!scanTarget; scanTarget = null; show(back ? 'form' : 'home'); stopScan(); };   // v0.59: a cancelled lot scan no longer hijacks the next one
  // v0.59: only the prefix is upper-cased (METER:elec_main, lower-case milk lots stay as typed); a typed lot number is upper-cased
  const normCode = c => { const i = c.indexOf(':'); if (i < 0) return /^[lr]\d{8}-[a-z]$/i.test(c) ? c.toUpperCase() : c.toUpperCase(); return c.slice(0, i).toUpperCase() + c.slice(i); };
  $('btn-manual').onclick = () => { const code = normCode($('manual').value.trim()); if (!code) return; stopScan().then(() => handleCode(code)); };
  $('manual').addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); $('btn-manual').click(); } });
  const _manual = $('btn-manual').onclick; $('btn-manual').onclick = () => { const code = $('manual').value.trim(); if (scanTarget && code) { const f = scanTarget; scanTarget = null; stopScan().then(() => f(code)); return; } return _manual && _manual(); };
  // v0.97 (audit A-26): «Annulla» on a form with something written asks first (one gloved tap lost a 40-line count)
  $('btn-form-cancel').onclick = async () => {
    const record = current && current.code !== 'OPERATOR' && $('btn-form-save').style.display !== 'none';   // a PIN or a list is not a record
    if (record && current.dirty && !(await ask({ title: 'Uscire senza salvare?', lines: ['Quello che hai scritto in questo modulo si perde.'], yes: 'Sì, esci senza salvare', no: 'No, resto qui' }))) return;
    show('home'); loadTasks();
  };

  // ---------- Route a code to its step ----------
  // v0.59: what each scan needs (area, level 2 = registra); the database enforces the same, this just stops before a form that can't be saved
  const NEED = { EQ: 'haccp', CAL: 'haccp', CCP: 'haccp', PAPER: 'haccp', PEST: 'haccp', SAMPLE: 'haccp', HACCP: 'haccp', CLEAN: 'haccp', DDT: 'produzione', LOT: 'produzione', METER: 'produzione', EFFL: 'produzione', PO: 'magazzino', COUNT: 'magazzino', SHIP: 'spedizioni' };
  const allowed = kind => { const a = NEED[kind]; if (!a || PERM.can(a, 2)) return true; toast(`Il profilo "${(PERM.data && PERM.data.role_name) || '?'}" non può registrare qui (${a}): chiedi al responsabile`, 'err'); show('home'); return false; };
  async function handleCode(code) {
    $('form').innerHTML = ''; current = { code };
    const [kind, ...rest] = code.split(':'); const ref = rest.join(':');
    if (!allowed(/^[LR]\d{8}-[A-Z]$/.test(kind) && !rest.length ? 'LOT' : kind)) return;
    if (kind !== 'STAFF' && needOperator(() => handleCode(code), 'Prima di registrare: chi sei? Passa il badge o tocca il tuo nome')) return;   // v0.96 (audit A-01)
    if (redoPending) { current.redo = redoPending; redoPending = null; }   // v0.97 (audit A-11)
    try {
      if (kind === 'EQ') return await stepEquipment(ref);
      if (kind === 'DDT') return await stepMilk(ref);
      if (kind === 'LOT') return await stepLot(ref);
      if (kind === 'PO') return await stepReceive(ref);
      if (kind === 'COUNT') return await stepStockCount();
      if (kind === 'EFFL') return stepEffluent();
      if (kind === 'SHIP') return await stepShipList();
      if (kind === 'METER') return stepMeter(ref || 'elec_main');
      if (kind === 'CLEAN') return stepClean();
      if (kind === 'CCP') { const [cp, ...lot] = rest; return await stepCcp(cp, lot.join(':')); }   // CCP:<control point>[:<lot>]
      if (kind === 'CAL') return await stepEquipment(ref);
      if (kind === 'PEST') return await stepPest();
      if (kind === 'SAMPLE') return await stepSample(ref);
      if (kind === 'HACCP') return stepHaccpMenu();
      // v1.05 (audit E-31): PAPER:<control point>[@<day>[@<lot>]] — «Ieri non registrato» opens the copy on yesterday's date
      if (kind === 'PAPER') { const [pcp, pday, plot] = String(ref || '').split('@'); return ref ? await stepPaper(pcp, pday, plot) : stepPaperMenu(); }
      if (kind === 'STAFF') return await badgeScan(code);   // v0.96 (A-01/A-25): the badge says who records; clocks in if needed, never out by mistake
      if (!rest.length && /^[LR]\d{8}-[A-Z]$/.test(kind)) return await stepLot(kind);   // v0.54: a lot number typed by hand (L20261005-A) without LOT:
      toast('Codice non riconosciuto: ' + code, 'err'); show('home');
    } catch (e) { console.error(e); toast(e.message, 'err'); show('home'); }
  }
  function openForm(title, sub, onSave) {
    $('f-title').textContent = title; $('f-sub').textContent = sub; current.onSave = onSave; current.dirty = false; current.openedAt = current.openedAt || Date.now(); $('btn-form-save').style.display = '';
    $('btn-form-save').textContent = current.saveLabel || 'Salva';   // v1.03: a form can name its button (reprint: «Prepara l'etichetta»)
    // v0.97 (audit A-11): «Rifai» from a refused save: what it was, with its values filled in again where the form has the same field
    if (current.redo && !current.redo.shown && !['OPERATOR', 'REJECTS'].includes(current.code) && !current.picker) {   // not the «who are you?» or a lot chooser on the way
      const r = current.redo; r.shown = true;
      const c = document.createElement('div'); c.className = 'card rej';
      c.innerHTML = `<div class="scan">Da rifare: ${esc(r.what)}</div><div>Fatta il ${esc(when(r.at))}. Controlla i valori e salva: se era su un foglio di carta, ricopia ora e data del foglio.</div>`;
      $('form').prepend(c);
      Object.entries(r.fill || {}).forEach(([id, v]) => { const e = $(id); if (e && v != null && v !== '' && !e.readOnly && e.type !== 'file') { if (e.dataset.num) setNum(e, v); else e.value = v; e.dispatchEvent(new Event('input')); e.dispatchEvent(new Event('change')); } });
      if ($('pday') && $('ptime') && r.at && !(r.fill || {}).pday) { const d = new Date(r.at); $('pday').value = ROME_DAY.format(d); $('ptime').value = d.toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Rome', hour12: false }); }
    }
    show('form'); const f = $('form').querySelector('input:not([readonly]),select'); if (f) f.focus();
  }
  // v0.52: lot labels — labels.html prints the QR from the URL (code, name, sub, n copies)
  const ddmm = d => d ? d.slice(8, 10) + '/' + d.slice(5, 7) + '/' + d.slice(0, 4) : '';
  const labelUrl = (lot, name, sub, n) => 'labels.html?' + new URLSearchParams({ code: 'LOT:' + lot, name: name || '', sub: sub || '', n: String(Math.max(1, Math.min(60, Math.round(n || 1)))) });
  function showDone(title, lines, links, opts = {}) {   // result card with print buttons; returns 'stay' so the caller does not jump home
    $('form').innerHTML = ''; $('btn-form-save').style.display = 'none'; if (current) current.dirty = false;
    lines = (lines || []).filter(Boolean);
    const c = document.createElement('div'); c.className = 'card' + (opts.warn ? ' rej' : '');
    const h = document.createElement('div'); h.className = 'scan'; h.textContent = title; c.append(h);
    lines.forEach(t => { const d = document.createElement('div'); d.textContent = t; c.append(d); });
    $('form').append(c);
    links.forEach(([label, href]) => { const a = document.createElement('a'); a.className = 'btn'; a.style.cssText = 'display:block;text-align:center;text-decoration:none;margin-top:12px'; a.target = '_blank'; a.href = href; a.textContent = label; $('form').append(a); });
    const ok = document.createElement('button'); ok.type = 'button'; ok.className = 'btn secondary'; ok.style.cssText = 'display:block;width:100%;margin-top:8px'; ok.textContent = 'Fatto';
    ok.onclick = () => { show('home'); loadTasks(); }; $('form').append(ok);
    $('f-title').textContent = title; $('f-sub').textContent = ''; show('form');
    return 'stay';
  }
  $('btn-form-save').onclick = async () => {
    $('form').querySelectorAll('input[data-num]').forEach(i => { if (i.offsetParent === null) i.setCustomValidity(''); else numCheck(i); });   // a hidden field does not block
    if (!$('form').reportValidity()) {                    // v0.98 (audit A-13): an impossible number also says why, big enough to read
      const bad = $('form').querySelector('input[data-num]:invalid'); if (bad && bad.validationMessage) { toast(bad.validationMessage, 'err', 7000); bad.focus(); }
      return; }
    $('btn-form-save').disabled = true;
    const cur = current;
    try {
      const r = await cur.onSave();
      if (r !== 'stay') { show('home'); loadTasks(); }
    }
    catch (e) { console.error(e); if (!(e && e.silent) && Date.now() - lastToastAt > 500) toast((e && e.message) || 'Non salvato', 'err', 7000); }   // v0.59: no silent failures (v0.97: except «No, correggo»)
    finally { $('btn-form-save').disabled = false; }
  };
  // v0.59: Enter on a one-field screen (meter, temperature, chlorine) saves instead of reloading the page to Home
  $('form').addEventListener('submit', e => { e.preventDefault(); const b = $('btn-form-save'); if (b.style.display !== 'none' && !b.disabled) b.click(); });
  // v0.97 (audit A-26): anything typed or chosen makes «Annulla» ask first
  ['input', 'change'].forEach(ev => $('form').addEventListener(ev, e => { if (current && e.isTrusted) current.dirty = true; }));

  // 1/4/7/9 — equipment: cold room, pasteurizer, thermometer → temperature; POS → Z report
  async function stepEquipment(code) {
    const { data: eq, error: eqErr } = await cached('eq_' + code, () => sb.from('equipment').select('*').eq('code', code).maybeSingle());
    if (!eq) throw new Error(eqErr && !navigator.onLine ? 'Senza rete e macchina non ancora salvata sul tablet: ' + code : 'Macchina sconosciuta: ' + code);
    if (eq.kind === 'pos') return stepZ(eq);
    if (eq.kind === 'thermometer' || eq.kind === 'scale' || eq.code.startsWith('PH-') || current.code.startsWith('CAL:')) return stepCalibration(eq);
    const { data: cp } = await cached('cp_eq_' + eq.id, () => sb.from('haccp_control_points').select('*').eq('equipment_id', eq.id).eq('active', true).neq('code', 'CCP-MILK-TEMP').maybeSingle());
    const lim = cp ? `limite ${cp.min_value ?? ''}${cp.min_value != null && cp.max_value != null ? '–' : ''}${cp.max_value ?? ''} ${cp.unit || ''}`.replace('limite –', 'limite max ') : '';
    const t = field('temp', 'Temperatura °C', 'number', { limit: lim, ...(cp ? cpRange(cp.code) : { min: -30, max: 120 }), unit: '°C' });
    let note = null;
    // v0.98: the «what did you do» field appears for a possible value out of limit, and goes away (not required) when corrected
    t.oninput = () => { const v = t.validity.customError ? null : numOf(t); const bad = v != null && cp && ((cp.max_value != null && v > cp.max_value) || (cp.min_value != null && v < cp.min_value));
      if (bad && !note) { note = field('action', 'Fuori limite: cosa hai fatto?', 'text'); } noteShow(note, bad); t.style.borderColor = bad ? 'var(--warn)' : ''; };
    openForm(eq.name, eq.code, async () => {
      const v = val('temp'); const bad = cp && ((cp.max_value != null && v > cp.max_value) || (cp.min_value != null && v < cp.min_value));
      const warn = cp && ((cp.warn_max != null && v > cp.warn_max) || (cp.warn_min != null && v < cp.warn_min));
      if (cp) plausCheck(cp.code, v);
      if (cp && bad && !(await confirmOut(cp.code, v))) throw stop();         // v0.97 (audit A-07): «Hai scritto 45 °C…» before saving
      const ops = [scanEvent(current.code, 'temp_check', { equipment_id: eq.id, payload: { temp_c: v } })];
      if (cp) ops.push({ rpc: 'log_ccp', args: { p_cp_code: cp.code, p_value: v, p_staff_id: me().id, p_action: val('action'), p_source: 'tablet', p_equipment_code: eq.code } });   // server opens the NC
      const out = await save(ops); await closeTask({ equipment_id: eq.id });
      const r = out && out[1] && typeof out[1] === 'object' ? out[1] : null;
      // v0.97 (audit A-15): the re-check is a task with a time (top of Home), and the card says it
      const by = hhmm(new Date(Date.now() + 3600e3).toISOString());
      if (bad || (r && r.result === 'non_conformity')) return ncCard(cp.code, r, null, [`Ricontrolla la cella entro le ${by}: è in cima alla lista di Home.`]);
      if (warn || (r && r.result === 'warning')) return showDone(`⚠ ${eq.name}: ${itN(v)} °C, vicino al limite`, [`Ricontrolla entro le ${by}: è in cima alla lista di Home, in rosso.`, 'Chiudi bene la porta e non caricare prodotto caldo.'], [], { warn: true });
      toast('Registrato ✓');
    });
  }
  // 9 — till: closes itself from Shopify POS (bot Ordini Shopify writes pos_daily_closings)
  async function stepZ(eq) {
    const { data: pc } = await sb.from('pos_daily_closings').select('rt_total_eur, rt_receipts, source').eq('closing_date', today()).maybeSingle();
    const d = document.createElement('div'); d.className = 'card';
    d.innerHTML = `<div class="scan">La cassa è Shopify POS</div><div>Le vendite al banco si battono sul POS; ogni mattina il bot Ordini Shopify le copia qui e chiude la giornata da solo. Non c'è più nulla da digitare.</div>` +
      (pc ? `<div style="margin-top:8px">Oggi finora: <b>€ ${Number(pc.rt_total_eur).toLocaleString('it-IT', { minimumFractionDigits: 2 })}</b> · ${pc.rt_receipts} scontrini${pc.source === 'shopify_pos' ? ' (da Shopify POS)' : ''}</div>` : `<div style="margin-top:8px" class="status">Oggi non è ancora stata sincronizzata nessuna vendita POS.</div>`);
    $('form').append(d);
    openForm('Chiusura cassa', eq.code, async () => {}); $('btn-form-save').style.display = 'none';
  }
  // 10 — meter
  function stepMeter(meter) {
    field('reading', meter === 'elec_main' ? 'kWh sul contatore' : 'Lettura', 'number', { min: 0, max: 99999999, unit: meter === 'elec_main' ? 'kWh' : 'm³' });
    openForm('Contatore', meter, async () => {
      await save([scanEvent(current.code, 'task_done'), { table: 'meter_readings', row: { meter, reading: val('reading'), unit: meter === 'elec_main' ? 'kWh' : 'm3', read_by_id: me().id } }]);
      await closeTask({ code: 'T-KWH' }); toast('Lettura registrata ✓');
    });
  }
  // 8 — cleaning checklist
  async function stepClean() {
    const { data: cp } = await cached('cp_PRP-CLEAN', () => sb.from('haccp_control_points').select('*').eq('code', 'PRP-CLEAN').maybeSingle());
    if (!cp) throw new Error('Punto di controllo PRP-CLEAN non disponibile: riprova con la rete');
    // v0.97 (audit A-23): each item ✓ fatto or ✗ non fatto with the reason — an honest «not done» is recorded (alert to the HACCP
    // responsible) instead of ticking everything or not saving at all
    const items = ['Caldaia / pastorizzatore', 'Filatrice', 'Tavoli e utensili', 'Pavimenti e scarichi', 'Celle frigo'];
    const all = document.createElement('button'); all.type = 'button'; all.className = 'btn secondary'; all.textContent = `✓ Tutto fatto (${items.length})`;
    all.onclick = () => items.forEach((_, k) => { $('c' + k).value = 'ok'; $('c' + k).dispatchEvent(new Event('change')); });
    $('form').append(all);
    items.forEach((t, k) => {
      const s = field('c' + k, t, 'select', { options: [['', '— scegli —'], ['ok', '✓ Fatto'], ['ko', '✗ Non fatto']] });
      const w = field('w' + k, `${t}: perché non è stato fatto?`, 'text', { required: false }), wl = w.previousElementSibling;
      const tog = () => { const ko = s.value === 'ko'; w.style.display = wl.style.display = ko ? '' : 'none'; w.required = ko; };
      s.addEventListener('change', tog); tog();
    });
    openForm('Sanificazione fine turno', 'Per ogni zona: fatto o non fatto (con il motivo)', async () => {
      const miss = items.filter((_, k) => !$('c' + k).value);
      if (miss.length) throw new Error('Scegli fatto o non fatto per: ' + miss.join(', '));
      const done = items.filter((_, k) => $('c' + k).value === 'ok'), ko = items.map((t, k) => $('c' + k).value === 'ko' ? `${t} (${String(val('w' + k) || '').trim()})` : null).filter(Boolean);
      if (ko.length && !(await ask({ title: 'Sanificazione non completa', lines: ['Non fatto: ' + ko.join('; '), 'Si registra così e il responsabile HACCP viene avvisato.'], yes: 'Registra', no: 'Correggo' }))) throw stop();
      await save([scanEvent(current.code, 'clean_done', { payload: { items: done, not_done: ko } }),
        { table: 'haccp_log', row: { control_point_id: cp.id, result: ko.length ? 'warning' : 'ok', corrective_action: ko.length ? 'Non fatto: ' + ko.join('; ') : null, operator: me().full_name, operator_id: me().id, source: 'tablet' } }]);
      await closeTask({ control_point_id: cp.id });
      if (ko.length) return showDone('Sanificazione registrata: NON completa', ['Non fatto: ' + ko.join('; '), 'Il responsabile HACCP riceve l\'avviso. Rifalla appena possibile.'], [], { warn: true });
      toast('Sanificazione registrata ✓');
    });
  }
  // v0.97 (audit A-20): «Ricopio dal foglio di carta» on milk arrival, batch start and close: the sheet's date, time and signer
  // are what gets recorded (up to 7 days back), not the moment it is typed in
  function paperBox(what) {
    const d = document.createElement('div'); d.className = 'check';
    d.innerHTML = `<input type="checkbox" id="pp-on"><label for="pp-on" style="margin:0;text-transform:none;color:inherit;font-weight:400">Ricopio ${what} dal foglio di carta (tablet o rete erano giù)</label>`;
    $('form').append(d);
    const dy = field('pday', 'Data scritta sul foglio', 'date', { required: false }); dy.value = today(); dy.max = today(); dy.min = addDays(today(), -7);
    const tm = field('ptime', 'Ora scritta sul foglio', 'time', { required: false });
    const who = field('pwho', 'Chi l\'ha scritto (firma sul foglio)', 'select', { required: false, options: [['', '— scegli chi ha firmato —'], ...opList().map(p => [p.full_name, p.full_name]), ['firma non leggibile', 'Non si legge / non firmato']] });
    const els = [dy, tm, who].flatMap(e => [e.previousElementSibling, e]);
    const tog = () => { const on = $('pp-on').checked; els.forEach(e => { e.style.display = on ? '' : 'none'; }); [dy, tm, who].forEach(e => { e.required = on; }); };
    $('pp-on').addEventListener('change', tog); tog();
    return {
      on: () => $('pp-on').checked,
      day: () => val('pday'), hm: () => val('ptime'), who: () => val('pwho'),
      iso: () => romeIso(val('pday'), val('ptime')),
      check() {
        if (!this.on()) return;
        const day = val('pday'), hm = val('ptime');
        if (!day || !hm) throw new Error('Scrivi data e ora come sul foglio');
        if (day > today() || day < addDays(today(), -7)) throw new Error('Si ricopiano solo fogli degli ultimi 7 giorni');
        if (Date.parse(romeIso(day, hm)) > Date.now() + 5 * 60000) throw new Error('Data e ora del foglio nel futuro: controlla');
        if (!val('pwho')) throw new Error('Scegli chi ha firmato il foglio');
      }
    };
  }
  // 2 — milk arrival (QR on DDT encodes DDT:<number>, or type it)
  async function stepMilk(ddt) {
    const { data: sup } = await cached('milk_suppliers', () => sb.from('parties').select('id, legal_name').eq('is_milk_supplier', true).eq('active', true));
    if (!sup || !sup.length) throw new Error(navigator.onLine ? 'Nessun fornitore di latte attivo in anagrafica' : 'Senza rete e fornitori non ancora salvati sul tablet');
    // v0.65: shipments the Masseria registered from its page (its weight is the source of truth): pick one, confirm arrival
    let ships = [];
    try { const r = await cached('milk_ships_pending', () => sb.from('milk_shipments').select('id, milk_lot, kg, shipped_at, supplier_id, ddt_number, temperature_c, recorded_by').eq('status', 'shipped').order('shipped_at', { ascending: false }).limit(10)); ships = r.data || []; } catch {}
    const queuedShips = new Set(queue().flatMap(i => (i.ops || []).filter(o => o.table === 'milk_intake' && o.row && o.row.shipment_id).map(o => o.row.shipment_id)));
    ships = ships.filter(x => !queuedShips.has(x.id));                     // already confirmed offline, still in the queue
    // v0.93 (audit A-10/FARM-03): the newest load is no longer picked for you when there is a choice — with two loads in transit
    // (or an old one) the wrong lot and kg were locked in. One fresh load (< 12 h) is still preselected.
    // v0.94 (audit A-10, rest): when there is a choice, the load picked is confirmed from the driver's paper — the end of the lot the
    // Masseria writes on the DDT or the tank (or the DDT's last 3 digits) must match it, so a wrong pick is refused before its lot and
    // kg are locked in; the list and the card do not show lot or DDT then, so the check is read from the paper, not copied from the
    // screen. Departure time, age and kg are shown big. Loads older than 36 h (past the DOP window) sit behind «mostra».
    const norm = s => String(s || '').toUpperCase().replace(/\s+/g, '');
    const ageMin = x => Math.max(0, Math.round((Date.now() - new Date(x.shipped_at)) / 6e4));
    const ageH = x => Math.round(ageMin(x) / 60);
    const ageTxt = x => ageMin(x) < 60 ? 'da meno di 1 ora' : ageH(x) + ' h fa';
    const when = x => new Date(x.shipped_at).toLocaleString('it-IT', { weekday: 'short', hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Rome' });
    const kgTxt = x => Number(x.kg).toLocaleString('it-IT');
    const fresh = ships.filter(x => ageH(x) <= 36), old = ships.filter(x => ageH(x) > 36);
    const pickFirst = fresh.length === 1 && ageH(fresh[0]) < 12;
    const byDdt = ddt ? ships.filter(x => x.ddt_number && norm(x.ddt_number) === norm(ddt)) : [];   // a DDT number read from the paper's QR
    const needCheck = x => !!x && !(pickFirst && x.id === fresh[0].id) && !(byDdt.length === 1 && byDdt[0].id === x.id);
    const shipLabel = x => `${when(x)} · ${kgTxt(x)} kg · partita ${ageTxt(x)}` + (x.recorded_by ? ` · da ${x.recorded_by}` : '') + (needCheck(x) ? '' : ` · lotto ${x.milk_lot}`);   // v1.03 (FARM-04): who sent it
    const shipOpts = list => [...(pickFirst && list === fresh ? [] : [['', list.length ? `— scegli quale spedizione è arrivata (${list.length}) —` : '— scegli —']]),
      ...list.map(x => [x.id, shipLabel(x)]), ...(list === fresh && old.length ? [['old', `— mostra le spedizioni più vecchie di 36 h (${old.length}) —`]] : []),
      ['none', '— nessuna: altro fornitore o latte non registrato —']];
    const shipSel = ships.length ? field('ship', 'Spedizione dalla Masseria', 'select', { options: shipOpts(fresh),
      limit: 'Scegli la cisterna arrivata guardando ora di partenza e kg sul foglio dell\'autista: il peso registrato alla Masseria è quello che vale, qui confermi l\'arrivo e fai i controlli.' }) : null;
    const setShipOpts = list => { shipSel.innerHTML = ''; shipOpts(list).forEach(([v, t]) => { const o = document.createElement('option'); o.value = v; o.textContent = t; shipSel.appendChild(o); }); };
    let card = null, chk = null, chkErr = null, chkEls = [];
    if (shipSel) {
      card = document.createElement('div'); card.id = 'shipcard'; card.className = 'shipcard'; $('form').append(card);
      chk = field('shipchk', 'Controllo sul foglio dell\'autista', 'text', { required: false,
        limit: 'Scrivi la fine del lotto che la Masseria ha scritto sul DDT o sulla cisterna (es. «12-2»), oppure le ultime 3 cifre del numero DDT.' });
      chk.autocomplete = 'off'; chk.autocapitalize = 'characters'; chk.placeholder = 'come lo leggi sul foglio';
      chkErr = document.createElement('div'); chkErr.className = 'shipchk-err'; chkErr.id = 'shipchk-err'; $('form').append(chkErr);
      chkEls = [chk.previousElementSibling, chk, chk.nextElementSibling, chkErr];
      chk.addEventListener('input', () => { chkErr.textContent = ''; });
      if (byDdt.length === 1) { if (!fresh.includes(byDdt[0])) setShipOpts(ships); shipSel.value = byDdt[0].id; }
    }
    field('supplier', 'Fornitore', 'select', { options: sup.map(s => [s.id, s.legal_name]) });
    const ddtIn = field('ddtn', 'Numero DDT', 'text'); ddtIn.value = ddt || ''; ddtIn.placeholder = 'come stampato sul DDT';   // v0.53: station QR "DDT:" arrives with no number
    const { data: cpT } = await cached('cp_CCP-MILK-TEMP', () => sb.from('haccp_control_points').select('*').eq('code', 'CCP-MILK-TEMP').maybeSingle());
    const tMax = Number(cpT?.max_value ?? 8), tWarn = Number(cpT?.warn_max ?? 6);
    field('lot', 'Lotto / cisterna', 'text'); field('kg', 'kg (bilancia)', 'number', { min: 1, max: 5000, unit: 'kg' });
    // v0.96 (audit FARM-02): with a farm load the Masseria's kg stay as written, and the reception scale gets its own field;
    // over the tolerance (2 %) a reason is required and the dairy's weight is the one that counts
    const { data: tolRow } = await cached('set_milk_tol', () => sb.from('settings').select('value').eq('key', 'milk.weight_tolerance_pct').maybeSingle());
    const tolPct = Number((tolRow || {}).value) || 2;
    const kgh = field('kgh', 'kg pesati qui (bilancia ricezione)', 'number', { required: false, min: 1, max: 5000, unit: 'kg' }); kgh.placeholder = 'leggi la bilancia';
    const kgInfo = document.createElement('div'); kgInfo.className = 'limit'; kgInfo.id = 'kgh-info'; $('form').append(kgInfo);
    const kgWhy = field('kgwhy', 'Perché i kg sono diversi?', 'text', { required: false }); kgWhy.placeholder = 'es. latte rimasto nella cisterna, la Masseria ha sbagliato a scrivere';
    const kgEls = [kgh.previousElementSibling, kgh, kgInfo], whyEls = [kgWhy.previousElementSibling, kgWhy];
    const kgDiff = () => { const x = ships.find(y => y.id === (shipSel && shipSel.value)), d = val('kgh');
      if (!x || d == null || !(Number(x.kg) > 0)) return null; const pct = (d - Number(x.kg)) / Number(x.kg) * 100; return { x, d, pct, over: Math.abs(pct) > tolPct }; };
    const showDiff = () => { const k = kgDiff(), over = !!(k && k.over);
      whyEls.forEach(e => { e.style.display = over ? '' : 'none'; }); kgWhy.required = over;
      kgInfo.textContent = !k ? '' : `Masseria ${Number(k.x.kg).toLocaleString('it-IT')} kg · pesati qui ${k.d.toLocaleString('it-IT')} kg: ${k.pct > 0 ? '+' : ''}${k.pct.toLocaleString('it-IT', { maximumFractionDigits: 1 })} %`
        + (over ? ` — oltre il ${tolPct.toLocaleString('it-IT')} %: vale il peso del caseificio, scrivi il motivo (la Masseria e l'ufficio lo vedono)` : ' — vale il peso della Masseria');
      kgInfo.style.color = over ? '' : 'var(--muted)'; };
    kgh.addEventListener('input', showDiff);
    field('temp', 'Temperatura latte °C', 'number', { limit: `CCP 1a: ≤ ${tMax} °C (oltre ${tWarn} °C lavorare entro 2 ore)`, ...cpRange('CCP-MILK-TEMP'), unit: '°C' });
    field('abx', 'Test antibiotici (CCP 1b)', 'select', { options: [['', '— scegli —'], ['0', 'Negativo'], ['1', 'POSITIVO']], limit: 'Test rapido prima dello scarico' });
    field('fat', 'Grasso % (se noto)', 'number', { required: false, min: 3, max: 15, unit: '%' }); field('prot', 'Proteine % (se note)', 'number', { required: false, min: 2, max: 8, unit: '%' }); field('scc', 'Cellule somatiche /ml (da analisi, se note)', 'number', { required: false, min: 0, max: 10000000, int: true }); field('photo', 'Foto DDT', 'file', { required: false });
    const pb = paperBox('l\'arrivo del latte');                          // v0.97 (audit A-20)
    const applyShip = () => {                                              // a chosen shipment fixes supplier, lot and kg
      if (shipSel && shipSel.value === 'old') { setShipOpts(ships); shipSel.value = ''; }
      const x = ships.find(y => y.id === (shipSel && shipSel.value)), kgIn = $('kg'), lotF = $('lot'), need = needCheck(x);
      if (ddtIn.dataset.auto && ddtIn.value === ddtIn.dataset.auto) ddtIn.value = '';   // a DDT number filled in for the previous pick
      delete ddtIn.dataset.auto;
      if (x) { if (x.supplier_id && sup.some(y => y.id === x.supplier_id)) $('supplier').value = x.supplier_id;
        setNum(kgIn, x.kg); lotF.value = need ? '' : x.milk_lot; lotF.placeholder = need ? 'dal controllo sul foglio' : '';
        if (!need && x.ddt_number && !ddtIn.value) { ddtIn.value = x.ddt_number; ddtIn.dataset.auto = x.ddt_number; } }
      else if (kgIn.readOnly) { setNum(kgIn, ''); lotF.value = ''; lotF.placeholder = ''; }
      [kgIn, lotF].forEach(e => { e.readOnly = !!x; e.style.background = x ? '#f1efe9' : ''; });
      if (kgIn.previousElementSibling) kgIn.previousElementSibling.textContent = x ? 'kg scritti dalla Masseria' : 'kg (bilancia)';   // v0.96 (FARM-02)
      kgEls.forEach(e => { e.style.display = x ? '' : 'none'; }); kgh.required = !!x; if (!x) { setNum(kgh, ''); kgWhy.value = ''; } showDiff();
      ddtIn.required = !x;                                                 // the farm may not have a DDT number for it
      if (chk) { chk.required = need; chkEls.forEach(e => { if (e) e.style.display = need ? '' : 'none'; }); if (!need) chk.value = ''; chkErr.textContent = ''; }
      if (card) { card.style.display = x ? '' : 'none';
        card.innerHTML = x ? `<div class="sc-kg">${esc(kgTxt(x))} kg</div><div class="sc-when">partita ${esc(when(x))} · ${esc(ageTxt(x))}</div>` +
          (need ? '<div class="sc-note">Controlla sul foglio dell\'autista: stessa ora di partenza e stessi kg? Poi scrivi qui sotto il lotto o il DDT che leggi sul foglio.</div>'
                : `<div class="sc-note">lotto ${esc(x.milk_lot)}${x.ddt_number ? ' · DDT ' + esc(x.ddt_number) : ''}</div>`) : ''; }
    };
    if (shipSel) { shipSel.onchange = applyShip; applyShip(); }
    // today's milk plan, if the planning bot made one (approved or still proposed)
    let planTxt = '';
    try { const { data: plan } = await sb.from('milk_plans').select('milk_kg, status').eq('plan_date', today()).in('status', ['proposed', 'approved']).maybeSingle();
      if (plan) planTxt = ` · piano ${plan.status === 'approved' ? 'approvato' : 'PROPOSTO (non approvato)'}: ${Number(plan.milk_kg).toLocaleString('it-IT')} kg`; } catch {}
    openForm('Arrivo latte', (ddt ? 'DDT ' + ddt : 'Scrivi il numero del DDT') + planTxt, async () => {
      if (val('abx') === '') { toast('Registra l\'esito del test antibiotici', 'err'); throw new Error('abx'); }
      const ddtNo = String(val('ddtn') || '').trim().toUpperCase();
      // v0.59: lot labels are unique — a tank id used before (T1) gets the date (T1-0510, then T1-0510-2…) so intake never breaks
      const shipId = (shipSel && shipSel.value && shipSel.value !== 'none') ? shipSel.value : null;
      const shipX = ships.find(y => y.id === shipId);
      if (needCheck(shipX)) {                                             // v0.94 (A-10): the paper must match the load picked
        const t = norm(val('shipchk'));
        const fits = y => t.length >= 3 && ((y.ddt_number && (norm(y.ddt_number) === t || norm(y.ddt_number).endsWith(t)))
                                             || norm(y.milk_lot) === t || (t.includes('-') && norm(y.milk_lot).endsWith(t)));
        if (!fits(shipX)) {                                               // the reason stays on screen under the field, not only in the toast
          const other = ships.filter(y => y.id !== shipX.id && fits(y)), o = other.length === 1 ? other[0] : null;
          const msg = o ? `Sul foglio c'è «${t}»: è la spedizione partita ${when(o)} (${kgTxt(o)} kg), non quella scelta. Scegli quella${old.includes(o) ? ' (è tra le più vecchie di 36 h: «mostra»)' : ''} e salva di nuovo.`
            : t.length < 3 ? 'Scrivi la fine del lotto (es. «12-2») o le ultime 3 cifre del DDT, come le leggi sul foglio dell\'autista.'
            : `«${t}» non corrisponde alla spedizione scelta (partita ${when(shipX)}, ${kgTxt(shipX)} kg). Controlla il foglio dell'autista; se questo latte non è registrato dalla Masseria scegli «nessuna».`;
          chkErr.textContent = msg; chkErr.scrollIntoView({ block: 'center' }); throw new Error(msg);
        }
        $('lot').value = shipX.milk_lot;
      }
      let lotIn = shipX ? shipX.milk_lot : String(val('lot') || '').trim();   // with a load, its lot (the database sets it too)
      if (lotIn && !shipId) {
        const base = lotIn; let k = 0; const known = lotView().milk;
        while (k < 9) { const { count, error } = await live(sb.from('labels').select('id', { count: 'exact', head: true }).ilike('code', likeSafe('LOT:' + lotIn)));
          const taken = error ? known.some(x => lotEq(x.milk_lot, lotIn)) : !!count;   // offline: lots on the tablet
          if (!taken) break;
          k++; lotIn = base + '-' + today().slice(8, 10) + today().slice(5, 7) + (k > 1 ? '-' + k : ''); }
        if (lotIn !== base) { $('lot').value = lotIn; toast(`Lotto ${base} già usato: registrato come ${lotIn}`, 'err'); }
      }
      const kd = shipX ? kgDiff() : null;                                 // v0.96 (FARM-02)
      if (shipX && !kd) { toast('Pesa il latte e scrivi i kg della bilancia', 'err'); throw new Error('kgh'); }
      if (kd && kd.over && String(val('kgwhy') || '').trim().length < 3) { toast('I kg sono diversi da quelli della Masseria: scrivi il motivo', 'err'); throw new Error('kgwhy'); }
      const kgEntered = kd ? (kd.over ? kd.d : Number(shipX.kg)) : val('kg');
      const hot = val('temp') > tMax, abxPos = val('abx') === '1', accepted = !hot && !abxPos;
      const why = [hot ? `temperatura > ${tMax} °C` : null, abxPos ? 'test antibiotici positivo' : null].filter(Boolean).join(' · ');
      pb.check(); plausCheck('CCP-MILK-TEMP', val('temp'));
      // v0.97 (audit A-07): rejecting a whole delivery takes a red «È giusto?» with the numbers (a missing comma made 4,5 °C → 45)
      if (!accepted && !(await ask({ danger: true, title: 'Il latte verrà RESPINTO', yes: 'Sì, è giusto: respingi', no: 'No, correggo',
        lines: [hot ? `Hai scritto ${itN(val('temp'))} °C: il limite è ${itN(tMax)} °C.` : null, abxPos ? 'Hai scelto: test antibiotici POSITIVO.' : null,
                `${Number(kgEntered).toLocaleString('it-IT')} kg di latte non si usano in produzione${shipX ? ' e la Masseria li vede respinti' : ''}.`, 'È giusto?'] }))) throw stop();
      const paper = pb.on(), pWho = paper ? pb.who() : null, pId = paper ? ((opList().find(p => p.full_name === pWho) || {}).id || null) : null;
      const ops = [scanEvent(current.code, 'milk_receive', { payload: { kg: kgEntered, farm_kg: kd ? Number(shipX.kg) : null, dairy_kg: kd ? kd.d : null, temp_c: val('temp'), abx: Number(val('abx')), shipment_id: shipId, ...(paper ? { paper_at: pb.iso() } : {}) } }),
        { table: 'milk_intake', row: { intake_date: paper ? pb.day() : today(), intake_time: paper ? pb.hm() + ':00' : new Date().toLocaleTimeString('it-IT', { timeZone: 'Europe/Rome', hour12: false }), supplier_id: val('supplier'), milk_lot: lotIn, qty_kg: kgEntered, ...(kd ? { dairy_kg: kd.d, weight_note: String(val('kgwhy') || '').trim() || null } : {}), temperature_c: val('temp'), fat_pct: val('fat'), protein_pct: val('prot'), scc_cells_ml: val('scc') == null ? null : Math.round(val('scc')), ddt_number: ddtNo || null, accepted, rejection_reason: accepted ? null : why,
          received_by: paper ? pWho : me().full_name, received_by_id: paper ? pId : me().id, source: paper ? 'paper' : 'tablet', shipment_id: shipId, ...(paper ? { notes: `Ricopiato dal foglio di carta da ${me().full_name}` } : {}) } },
        { table: 'labels', row: { kind: 'milk_lot', code: 'LOT:' + lotIn, lot_number: lotIn, milk_intake_id: '$1.id', printed_by_id: me().id } },
        // v0.96 (audit A-04): both checks are linked to this delivery ($1 = the milk_intake row above)
        { rpc: 'log_milk_check', args: { p_milk_intake_id: '$1.id', p_cp_code: 'CCP-MILK-TEMP', p_value: val('temp'), p_staff_id: me().id, p_action: hot ? 'latte respinto' : null, p_source: paper ? 'paper' : 'tablet', p_equipment_code: 'TERM-01', ...(paper ? { p_logged_at: pb.iso(), p_written_by: pWho } : {}) } },
        { rpc: 'log_milk_check', args: { p_milk_intake_id: '$1.id', p_cp_code: 'CCP-MILK-ABX', p_value: Number(val('abx')), p_staff_id: me().id, p_action: abxPos ? 'latte respinto e isolato, Masseria avvisata' : null, p_source: paper ? 'paper' : 'tablet', ...(paper ? { p_logged_at: pb.iso(), p_written_by: pWho } : {}) } }];
      const svOut = await save(ops);
      // v0.98 (audit D-07): the database decides the rejection (CCP 1a limit read there): if it rejected what the tablet accepted, say so
      const dbRow = Array.isArray(svOut) && svOut[1] && typeof svOut[1] === 'object' ? svOut[1] : null, dbRej = accepted && !!dbRow && dbRow.accepted === false;
      // v0.97 (audit A-20): the DDT photo goes up with the record, or waits on the tablet until there is network
      const f = $('photo').files[0]; let photo = null;
      if (f) photo = await savePhoto(f, { path: `ddt/${paper ? pb.day() : today()}_${(ddtNo || lotIn).replace(/[^A-Za-z0-9-]/g, '_')}.jpg`, kind: 'ddt_in', date: paper ? pb.day() : today(), related_table: 'milk_intake', related_id: ops[1].row.id, by: me().id });
      const photoLine = photo === 'kept' ? 'Foto del DDT tenuta sul tablet: parte appena c\'è rete.' : photo === 'lost' ? 'La foto del DDT non si è potuta salvare: rifalla quando torna la rete.' : null;
      const lotv = lotIn, kgv = Number(kgEntered).toLocaleString('it-IT'), sup = ($('supplier').selectedOptions[0] || {}).textContent || '';
      const wLine = kd && kd.over ? `Pesati qui ${kd.d.toLocaleString('it-IT')} kg, la Masseria ne aveva scritti ${Number(shipX.kg).toLocaleString('it-IT')}: vale il peso del caseificio (la Masseria e l'ufficio lo vedono)` : null;
      if (!accepted || dbRej) return showDone('Latte RIFIUTATO', [`Lotto ${lotv} · ${kgv} kg`, dbRej ? (dbRow.rejection_reason || 'respinto dal sistema: oltre il limite') : why, 'Isola il latte e avvisa la Masseria e il responsabile.', photoLine], [], { warn: true });
      // v0.97 (audit A-15): warm milk = into the vat within 2 hours; it is a task with a time on Home, and the card says it
      const warm = val('temp') > tWarn && !paper, by = hhmm(new Date(Date.now() + 2 * 3600e3).toISOString());
      if (!warm) toast('Latte registrato ✓');
      return showDone(warm ? `⚠ Latte registrato a ${itN(val('temp'))} °C` : '✓ Latte registrato', [`Lotto ${lotv} · ${kgv} kg · ${sup}`, wLine,
        warm ? `Sopra i ${itN(tWarn)} °C: mettilo in caldaia entro le ${by} (2 ore). È in cima alla lista di Home, in rosso.` : null,
        'Attacca l\'etichetta al tank: la scansioni per avviare la caldaia.', photoLine],
        [['🖨 Stampa etichetta lotto latte', labelUrl(lotv, 'Latte di bufala · ' + sup, 'arrivo ' + ddmm(paper ? pb.day() : today()), 1)]], { warn: warm });
    });
  }
  // 3/5/6 — a lot label: milk lot → start/end batch; batch lot → sale or shipment
  async function stepLot(lot) {
    if (navigator.onLine && queue().length) await flush();   // v0.62: send what was saved offline first, so the database knows those lots
    let milk = null, batch = null, off = false, view = null;
    const [m, b] = await Promise.all([
      live(sb.from('milk_intake').select('id, milk_lot, qty_kg, intake_date, accepted, rejection_reason, created_at').ilike('milk_lot', likeSafe(lot)).order('intake_date', { ascending: false }).order('created_at', { ascending: false }).limit(1).maybeSingle()),
      live(sb.from('production_batches').select('*').ilike('batch_lot', likeSafe(lot)).maybeSingle())]);
    if (m.error || b.error) {
      const e = m.error || b.error; if (!unreachable(e)) throw e;
      off = true; view = lotView();                  // no network: the tablet's copy + the queue
      if (!view.at && !queue().length) throw new Error('Senza rete e lotti non ancora salvati sul tablet: riprova quando torna la connessione');
      batch = view.batches.find(x => lotEq(x.batch_lot, lot)) || null;
      milk = view.milk.find(x => lotEq(x.milk_lot, lot)) || null;
    } else { milk = m.data; batch = b.data; }
    if (milk && !batch) lot = milk.milk_lot;            // the stored spelling, for the stock move
    if (batch) {
      if (batch.output_kg == null) return stepBatchWork(batch);   // open batch → working steps, then close
      if (batch.food_safety_hold) throw new Error(`Lotto ${batch.batch_lot} BLOCCATO (${batch.hold_reason || 'sicurezza alimentare'}): non si spedisce`);   // v0.78: offline too (the device copy keeps the hold)
      return stepPick(batch);
    }
    if (!milk) throw new Error('Lotto sconosciuto: ' + lot + (off ? ` (senza rete il tablet conosce i lotti degli ultimi ${LOT_DAYS} giorni)` : ''));
    if (milk.accepted === false) throw new Error(`Latte respinto (${milk.rejection_reason || 'non conforme'}): non si può usare in produzione`);   // v0.55
    // v0.93 (audit A-02): one delivery can feed several vat loads. With more than one batch open on this milk the tank label
    // cannot tell them apart, so the casaro picks the lot instead of the tablet taking an arbitrary one (was .limit(1), no order).
    let opens = [];
    if (off) {
      const ids = new Set(view.inputs.filter(i => i.milk_intake_id === milk.id).map(i => i.batch_id));
      opens = view.batches.filter(x => ids.has(x.id) && x.output_kg == null);
    } else {
      const { data: open } = await sb.from('batch_milk_inputs').select('batch_id, production_batches!inner(id, batch_lot, product_id, preset_id, output_kg, milk_in_kg, input_kind, started_at)').eq('milk_intake_id', milk.id).is('production_batches.output_kg', null);
      opens = (open || []).map(x => x.production_batches);
    }
    opens = [...new Map(opens.map(b => [b.id || b.batch_lot, b])).values()].sort((a, b) => String(a.started_at || a.batch_lot).localeCompare(String(b.started_at || b.batch_lot)));
    if (opens.length === 1) return stepBatchWork(opens[0]);
    if (opens.length > 1) {
      field('pickb', 'Quale lotto stai lavorando?', 'select', { options: [['', '— scegli il lotto —'], ...opens.map(b => [b.batch_lot,
        `${b.batch_lot}${b.started_at ? ' · avviato alle ' + hhmm(b.started_at) : ''}${b.milk_in_kg ? ' · ' + Number(b.milk_in_kg).toLocaleString('it-IT') + ' kg' : ''}`])],
        limit: `Da questo latte ci sono ${opens.length} lotti aperti: scegli quello che hai in mano (la lettera è sul foglio della caldaia).` });
      current.picker = true;
      openForm('Più lotti aperti da questo latte', `latte ${milk.milk_lot}`, async () => {
        const b = opens.find(x => x.batch_lot === val('pickb')); if (!b) { toast('Scegli il lotto', 'err'); throw new Error('Scegli il lotto'); }
        current.picker = false; $('form').innerHTML = ''; await stepBatchWork(b); return 'stay';
      });
      return;
    }
    return stepBatchStart(milk, lot);
  }
  // 5b — the 'make' steps of the preset (maturazione, filatura, formatura…): run once per batch, then the lot closes
  async function stepBatchWork(b) {
    const presets = await loadPresets();
    const preset = b.preset_id || (presetsFor(presets, b.product_id).find(p => p.is_default) || {}).id;
    // v0.96 (audit A-03): an interrupted START is resumed too (pasteurisation CCP 2 included), not only the working steps
    const start = processSteps(presets, preset, 'start'), make = processSteps(presets, preset, 'make');
    let { data: done, error: de } = b.id ? await live(sb.from('batch_step_logs').select('step_id').eq('batch_id', b.id)) : { data: null, error: { name: 'Timeout' } };
    if (de || !done) done = lotView().steps.filter(x => lotEq(x.batch_lot, b.batch_lot));   // offline: copy + queued steps
    else done = [...done, ...lotView().steps.filter(x => lotEq(x.batch_lot, b.batch_lot))];
    const doneIds = new Set((done || []).map(d => d.step_id));
    // start doses not yet confirmed (online only: offline we can't know what was dosed, so none is asked twice)
    let doses = [];
    const dc = b.id ? await live(sb.from('batch_consumables').select('products!inner(sku)').eq('batch_id', b.id)) : { error: true };
    if (!dc.error && dc.data) {
      const doneSku = new Set([...dc.data.map(x => x.products.sku), ...queuedOps().filter(o => o.rpc === 'record_batch_consumable' && o.args && lotEq(o.args.p_batch_lot || '', b.batch_lot)).map(o => o.args.p_sku)]);
      doses = (await doseSteps(b.product_id, 'start', { milk: b.milk_in_kg })).filter(d => !doneSku.has(d.sku))
        .map(d => ({ ...d, instruction_it: ['Ripresa dopo un\'interruzione: se l\'hai già messo, conferma solo la quantità messa.', d.instruction_it].filter(Boolean).join(' ') }));
    }
    const left = [...mergeSteps(doses, start.filter(st => !doneIds.has(st.step_id))), ...make.filter(st => !doneIds.has(st.step_id))];
    if (!left.length) return stepBatchEnd(b);
    runDosing(`Lavorazione ${b.batch_lot}`, b.batch_lot, left, async () => { toast('Lavorazione registrata ✓ · a fine lotto scansiona l\'etichetta del lotto'); }, { skippable: true, onSkipAll: () => stepBatchEnd(b) });
  }
  // v0.97 (audit A-29): was the pasteuriser check «NON ok» earlier today? (then an «Ok» needs a note: what was done)
  async function valveKoToday() {
    if (queuedOps().some(o => o.rpc === 'log_ccp' && o.args && o.args.p_cp_code === 'PRP-PAST-VALVE' && Number(o.args.p_value) === 1)) return true;
    const r = await live(sb.from('haccp_log').select('id, haccp_control_points!inner(code)').eq('haccp_control_points.code', 'PRP-PAST-VALVE').eq('result', 'non_conformity').gte('logged_at', romeDayStartIso()).limit(1), 5000);
    return !r.error && !!(r.data && r.data.length);
  }
  async function stepBatchStart(milk, lot, pre = null) {   // pre: a proposal from the production plan (v0.70)
    await refreshSettings();                         // v0.98: the vat size as it is now
    let { data: prods, error: pe } = await live(sb.from('products').select('id, name, byproduct_product_id, is_dop').eq('kind', 'finished_good').eq('active', true));
    if (pe || !prods) prods = lotView().products.filter(p => p.kind === 'finished_good' && p.active);   // offline
    if (!prods.length) throw new Error('Nessun prodotto disponibile (senza rete e prodotti non ancora salvati sul tablet)');
    const fromWhey = new Set(prods.map(p => p.byproduct_product_id).filter(Boolean));   // v0.95 (audit A-16): whey products (ricotta) start from a closed lot's whey, never from milk
    prods = prods.filter(p => !fromWhey.has(p.id)).sort((a, b) => String(a.name).localeCompare(String(b.name)));
    if (!prods.length) throw new Error('Nessun prodotto da latte disponibile');
    // v0.97 (audit A-14/D-08): how old the milk is (from the farm's departure, as the database counts it); past 60 h no DOP product
    let ageH = null;
    if (pre && pre.use_by) ageH = 60 - (Date.parse(pre.use_by) - Date.now()) / 36e5;
    else { const a = await live(sb.rpc('milk_age_hours', { p_intake_id: milk.id }), 5000);
      if (!a.error && a.data != null) ageH = Number(a.data); else if (milk.created_at) ageH = (Date.now() - Date.parse(milk.created_at)) / 36e5; }
    const useBy = ageH == null ? null : new Date(Date.now() + (60 - ageH) * 36e5).toISOString();
    if (ageH != null && ageH > 60) {
      const dop = prods.filter(p => p.is_dop); prods = prods.filter(p => !p.is_dop);
      if (!prods.length) throw new Error(`Il latte ${lot} ha già ${Math.floor(ageH)} ore: oltre le 60 ore non si può fare ${dop.map(p => p.name).join(', ') || 'un prodotto DOP'}. Chiama il responsabile: va usato per un prodotto non DOP o scartato.`);
    }
    // v0.95 (audit D-09/A-14): what is still left of this milk (the delivery minus the vats already started), not the delivery total
    let usedKg = 0;
    if (!pre) {
      const r = await live(sb.from('batch_milk_inputs').select('qty_kg').eq('milk_intake_id', milk.id));
      usedKg = (!r.error && r.data ? r.data : lotView().inputs.filter(i => i.milk_intake_id === milk.id)).reduce((a, x) => a + Number(x.qty_kg || 0), 0);
    }
    const leftKg = pre ? Number(pre.left_kg) : Math.max(0, Math.round((Number(milk.qty_kg) - usedKg) * 10) / 10);
    // v0.59: next free letter among the day's L-lots (ricotta R-lots and old simulation rows no longer shift it); re-read at save time.
    // v0.97: the day is the sheet's when copied from paper; if another tablet took the letter meanwhile the database gives the next one
    const nextLot = async (ymd = today()) => { const pre = 'L' + ymd.replace(/-/g, '') + '-';
      let { data: ls, error: le } = await live(sb.from('production_batches').select('batch_lot').like('batch_lot', pre + '%'));
      ls = [...((le || !ls) ? [] : ls), ...lotView().batches.filter(x => String(x.batch_lot || '').startsWith(pre))];   // + the device copy and the queue
      const used = new Set(ls.map(x => x.batch_lot.slice(pre.length)));
      for (let c = 65; c <= 90; c++) if (!used.has(String.fromCharCode(c))) return pre + String.fromCharCode(c);
      return pre + 'Z' + Date.now().toString().slice(-3); };
    let batchLot = await nextLot();
    if (ageH != null && ageH > 48) {
      const n = document.createElement('div'); n.className = 'limit';
      n.textContent = ageH > 60 ? `Latte di ${Math.floor(ageH)} ore: oltre le 60 ore, i prodotti DOP non sono nell'elenco.` : `Latte di ${Math.floor(ageH)} ore: per la DOP va in caldaia entro le ${hhmm(useBy)} (60 ore).`;
      $('form').append(n);
    }
    const prodSel = field('product', 'Prodotto', 'select', { options: prods.map(p => [p.id, p.name]) });
    const presets = await loadPresets();
    const preSel = field('preset', 'Impostazioni di processo', 'select', { options: [['', '—']], required: false });
    const fillPresets = () => { const mine = presetsFor(presets, prodSel.value); preSel.innerHTML = mine.length ? mine.map(p => `<option value="${esc(p.id)}" ${p.is_default ? 'selected' : ''}>${esc(p.name)}${p.is_default ? ' · predefinito' : ''}</option>`).join('') : '<option value="">nessun preset: solo dosi</option>'; };
    prodSel.onchange = fillPresets; fillPresets();
    if (pre) {
      if ([...prodSel.options].some(o => o.value === pre.product_id)) { prodSel.value = pre.product_id; fillPresets(); }
      if (pre.preset_id && [...preSel.options].some(o => o.value === pre.preset_id)) preSel.value = pre.preset_id;
    }
    field('mu', 'Unità', 'select', { options: [['kg', 'kg (bilancia)'], ['l', 'litri (contalitri)']] });
    const kgIn = field('kg', 'Latte in caldaia', 'number', { min: 1, max: 5000, unit: 'kg' });
    $('mu').addEventListener('change', () => { kgIn.dataset.unit = val('mu') === 'l' ? 'l' : 'kg'; numCheck(kgIn); });
    // v0.80: the day's pasteuriser check, asked here if nobody has recorded it yet (NON ok = no batch).
    // v0.97 (audit A-29): decided on Salva (a mis-tap on the list no longer records a non-conformity), and after a «NON ok» earlier
    // today an «Ok» needs a note of what was done
    const valveDone = await ccpRecorded('PRP-PAST-VALVE', null, null, true);
    const valveKo = valveDone ? false : await valveKoToday();
    if (!valveDone) {
      field('valve', 'Pastorizzatore: verifica di inizio giornata (non ancora registrata oggi)', 'select', { required: false, options: [['', '— scegli —'], ['0', 'Ok'], ['1', 'NON ok']], limit: 'NON ok = non pastorizzare: chiama il responsabile' });
      if (valveKo) field('valvenote', 'Oggi era NON ok: cosa è stato fatto? (es. riparato da …, provato di nuovo)', 'text', { required: false });
    }
    // v0.80: pasteurisation (CCP 2) asked here when the chosen preset has no pasteurisation step
    const pastIn = field('past', 'Temperatura di pastorizzazione (CCP 2), °C', 'number', { required: false, ...cpRange('CCP-PAST'), unit: '°C' });
    const pastLbl = pastIn.previousElementSibling;
    const togglePast = () => { const has = processSteps(presets, preSel.value, 'start').some(st => st.ccp === 'CCP-PAST' || /CCP\s*2/.test(st.name)); pastIn.style.display = pastLbl.style.display = has ? 'none' : ''; pastIn.required = !has; };
    preSel.addEventListener('change', togglePast); prodSel.addEventListener('change', togglePast); togglePast();
    if (pre) {
      setNum(kgIn, pre.milk_kg);
      const h = document.createElement('div'); h.className = 'hint'; $('form').append(h);
      const upd = () => { const v = val('mu') === 'l' ? (val('kg') || 0) * MILK_DENSITY : (val('kg') || 0);
        h.textContent = `Proposta: ${fmtKg(pre.milk_kg)} kg → ≈ ${fmtKg(Math.round(v * pre.yield_pct) / 100)} kg di ${pre.product} (resa ${String(pre.yield_pct).replace('.', ',')}%). Le dosi sono nel passo successivo.`; };
      kgIn.addEventListener('input', upd); $('mu').addEventListener('change', upd); upd();
    }
    const pb = paperBox('l\'inizio del lotto');                           // v0.97 (audit A-20)
    openForm('Inizio lotto ' + batchLot, `latte ${lot} · restano ${fmtKg(leftKg)} kg${usedKg ? ` (ricevuti ${fmtKg(milk.qty_kg)}, già in caldaia ${fmtKg(usedKg)})` : ''}${ageH != null ? ` · latte di ${Math.floor(ageH)} h` : ''}`, async () => {
      const kg = val('mu') === 'l' ? Math.round(val('kg') * MILK_DENSITY * 10) / 10 : val('kg');
      const product = val('product'), preset = val('preset') || null, paper = pb.on();
      pb.check();
      if (pastIn.required) plausCheck('CCP-PAST', val('past'));             // v0.95 (audit D-12)
      // v0.95 (audit D-09): the database refuses more than the milk left (+2 % for the scale): say it here, before the dosing starts
      if (kg > leftKg * 1.02) throw new Error(`Sul latte ${lot} restano ${fmtKg(leftKg)} kg: hai scritto ${fmtKg(kg)} kg. Controlla il lotto sull'etichetta e i kg`);
      const vat = setting('prod.vat_kg', null);                            // v0.98 (audit D-06): a vat holds what it holds (the database checks it too)
      if (vat && kg > vat * 1.1) throw new Error(`Latte in caldaia ${fmtKg(kg)} kg: una caldaia ne tiene al massimo ${fmtKg(Math.round(vat * 1.1))} kg (Latte per lotto ${fmtKg(vat)} kg, +10 %). Controlla i kg.`);
      // the valve check of the day (a vat copied from today's paper sheet too: the result is the one on the sheet; a sheet of an
      // earlier day has its own line in «Ricopia», MOD-02)
      const askValve = !valveDone && (!paper || pb.day() === today());
      const vp = paper ? { p_source: 'paper', p_logged_at: pb.iso(), p_written_by: pb.who() } : { p_source: 'tablet' };
      if (askValve) {
        if (val('valve') === '') throw new Error('Registra la verifica del pastorizzatore (Ok o NON ok)');
        if (val('valve') === '1') {
          if (!(await confirmOut('PRP-PAST-VALVE', 1))) throw stop();
          const r = await rpcNow('log_ccp', { p_cp_code: 'PRP-PAST-VALVE', p_value: 1, p_staff_id: me().id, p_action: 'Verifica non ok all\'inizio lotto: lotto non avviato', ...vp });
          return ncCard('PRP-PAST-VALVE', r, null, ['Lotto NON avviato: non pastorizzare finché il pastorizzatore non è sistemato.']);
        }
        if (valveKo && String(val('valvenote') || '').trim().length < 3) throw new Error('Oggi il pastorizzatore era NON ok: scrivi cosa è stato fatto prima di dire «Ok»');
      }
      batchLot = await nextLot(paper ? pb.day() : today());     // another tablet may have opened a lot meanwhile (offline: the device copy)
      if (pastIn.required && val('past') != null && !(await confirmOut('CCP-PAST', val('past'), batchLot))) throw stop();   // v0.97 (audit A-07)
      const pWho = paper ? pb.who() : null, pId = paper ? ((opList().find(p => p.full_name === pWho) || {}).id || null) : null;
      const extra = [];
      if (askValve) extra.push({ rpc: 'log_ccp', args: { p_cp_code: 'PRP-PAST-VALVE', p_value: 0, p_staff_id: me().id, p_action: valveKo ? String(val('valvenote')).trim() : null, ...vp } });
      // the lot of row $1 as saved: if another tablet had the letter, the database gave the next one and CCP 2 goes with it
      if (pastIn.required && val('past') != null) extra.push({ rpc: 'log_ccp', args: { p_cp_code: 'CCP-PAST', p_value: val('past'), p_staff_id: me().id, p_batch_lot: '$1.batch_lot', p_source: paper ? 'paper' : 'tablet', p_equipment_code: 'TERM-02', ...(paper ? { p_logged_at: pb.iso(), p_written_by: pWho } : {}) } });
      const ops = [scanEvent(current.code, 'batch_start', { payload: { batch_lot: batchLot, kg, entered: val('kg'), unit: val('mu'), preset_id: preset, ...(paper ? { paper_at: pb.iso() } : {}) } }),
        { table: 'production_batches', row: { batch_date: paper ? pb.day() : today(), batch_lot: batchLot, product_id: product, milk_in_kg: kg, preset_id: preset, started_at: paper ? pb.iso() : new Date().toISOString(),
          casaro: paper ? pWho : me().full_name, casaro_id: paper ? pId : me().id, source: paper ? 'paper' : 'tablet', ...(paper ? { notes: `Inizio ricopiato dal foglio di carta da ${me().full_name}` } : {}) } },
        { table: 'batch_milk_inputs', row: { batch_id: '$1.id', milk_intake_id: milk.id, qty_kg: kg } },
        { table: 'stock_moves', row: { product_id: await rawMilkId(), lot_number: lot, qty: -kg, move_type: 'production_in', batch_id: '$1.id', source: 'tablet' } }, ...extra];
      const out = await save(ops);
      batchLot = (out && out[1] && out[1].batch_lot) || batchLot;          // v0.97: the letter the database gave it
      if (pre) planStarted(pre, kg);
      const pr = out && out[4 + (askValve ? 1 : 0)];
      if (pastIn.required && ccpOut('CCP-PAST', val('past')))               // CCP 2 out of limit: the lot is held — said now, the work goes on
        await ask({ danger: true, title: `⚠ NON CONFORMITÀ · CCP 2: lotto ${batchLot} BLOCCATO`, lines: ['Non si vende finché il responsabile HACCP non lo sblocca (riceve l\'avviso).', 'Cosa fare adesso: ' + ((pr && pr.corrective_it) || (refStore()['cp_CCP-PAST'] || {}).corrective_it || 'avvisa il responsabile HACCP.')], yes: 'Ho capito', no: null });
      // v0.99 (audit A-02): the lot gets its own label at the start, for the vat or the curd tray: from now on the lot is scanned on
      // its label (LOT:L…-A), not on the milk tank shared by every vat of that delivery
      const pName = ((prodSel.selectedOptions && prodSel.selectedOptions[0]) || {}).textContent || 'Lotto';
      const started = () => { toast('Lotto ' + batchLot + ' avviato ✓ · stampa l\'etichetta del lotto');
        return showDone(`✓ Lotto ${batchLot} avviato`, [`${fmtKg(kg)} kg di latte · ${pName}`,
          'Stampa l\'etichetta del lotto e attaccala alla caldaia (poi al vassoio della cagliata): per continuare la lavorazione e a fine lotto scansiona questa etichetta, non quella del tank del latte.'],
          [['🖨 Stampa etichetta lotto in lavorazione', labelUrl(batchLot, pName + ' · in lavorazione', 'avviato ' + ddmm(paper ? pb.day() : today()) + ' alle ' + hhmm(paper ? pb.iso() : new Date().toISOString()), 1)]]); };
      const steps = mergeSteps(await doseSteps(product, 'start', { milk: kg }), processSteps(presets, preset, 'start'));
      if (!steps.length) return started();
      runDosing(`Avvio ${batchLot} · ${kg} kg latte`, batchLot, steps, async () => started(), { at: paper ? pb.iso() : null });
      return 'stay';
    });
  }
  // v0.95 (audit A-16): ricotta from a closed mozzarella lot's whey — at its close, or later from Home (Produzione di oggi)
  async function runRicotta(parentLot, byp, whey, doneTitle, doneLines, links) {
    const ricLot = 'R' + parentLot.slice(1);
    await save([{ rpc: 'start_byproduct_batch', args: { p_parent_lot: parentLot, p_whey_kg: whey, p_staff_id: me().id } }]);
    const done = () => { toast(`Ricotta ${ricLot} avviata ✓ · stampa l'etichetta per il tino`);
      return showDone(doneTitle, [...doneLines, `Ricotta ${ricLot} avviata con ${fmtKg(whey)} kg di siero. Attacca l'etichetta al tino: a fine ricotta scansionala per chiudere il lotto (le etichette delle fuscelle si stampano alla chiusura).`],
        [...links, ['🖨 Stampa etichetta tino ricotta', labelUrl(ricLot, 'Ricotta in lavorazione', 'tino · ' + ddmm(today()), 1)]]); };   // v0.54: the tino gets its own label to scan at close
    const steps = await doseSteps(byp, 'start', { milk: whey });
    if (!steps.length) return done();
    runDosing(`Ricotta ${ricLot} · ${fmtKg(whey)} kg siero`, ricLot, steps, async () => done());
    return 'stay';
  }
  function startRicottaLater(cand) {
    $('form').innerHTML = ''; current = { code: 'RICOTTA' };
    if (!allowed('LOT')) return;
    const sel = field('parent', 'Siero di quale lotto?', 'select', { options: [['', '— scegli il lotto —'], ...cand.map(b => [b.batch_lot,
      `${b.batch_lot} · ${fmtKg(b.output_kg)} kg${b.finished_at ? ' · chiuso alle ' + hhmm(b.finished_at) : ''}${Number(b.whey_kg) === 0 ? ' · avevi scelto «niente ricotta»' : ''}`])] });
    if (cand.length === 1) sel.value = cand[0].batch_lot;
    field('whey', 'Siero per ricotta, kg', 'number', { min: 1, max: 5000, unit: 'kg' });
    openForm('Avvia ricotta', 'dal siero di un lotto di mozzarella chiuso oggi', async () => {
      const b = cand.find(x => x.batch_lot === val('parent')); if (!b) throw new Error('Scegli il lotto');
      if (!(val('whey') > 0)) throw new Error('Scrivi i kg di siero');
      return runRicotta(b.batch_lot, b.byp, val('whey'), `✓ Ricotta dal lotto ${b.batch_lot}`, [], []);
    });
  }
  async function stepBatchEnd(b) {
    await refreshSettings();                         // v0.98: the possible yields as they are now
    // v0.78: a batch started offline (no id yet) closes offline too: the update finds it by lot number, later steps take its id from that step
    const bKey = b.id ? { id: b.id } : { batch_lot: b.batch_lot };
    let bId = b.id || '$1.id';                      // v0.98: '$2.id' when a milk correction goes before the close
    let { data: prod, error: pre } = await live(sb.from('products').select('name, shelf_life_days, byproduct_product_id').eq('id', b.product_id).single());
    if (pre || !prod) prod = cachedProduct(b.product_id);
    const byp = b.input_kind !== 'whey' ? prod?.byproduct_product_id : null;
    let ey = null;                                   // v0.70: expected yield (online; offline the plan kept on the tablet)
    const er = await live(sb.rpc('expected_yield', { p_product: b.product_id, p_preset: b.preset_id || null, p_exclude: b.id || null }), 5000);
    if (!er.error && er.data) ey = er.data; else if (planCache && planCache.yield && b.input_kind !== 'whey') ey = planCache.yield;
    const outIn = field('out', 'kg prodotto', 'number', { min: 0, max: 5000, unit: 'kg' });
    if (ey) { const h = document.createElement('div'); h.className = 'hint'; $('form').append(h);
      const upd = () => { const o = val('out'); h.textContent = `Attesi ≈ ${fmtKg(Math.round(b.milk_in_kg * ey.pct) / 100)} kg (resa ${String(ey.pct).replace('.', ',')}%${String(ey.source).startsWith('default') ? ', stimata' : ''})` + (o ? ` · con ${fmtKg(o)} kg la resa è ${String(Math.round(o / b.milk_in_kg * 1000) / 10).replace('.', ',')}%` : ''); };
      outIn.addEventListener('input', upd); upd(); }
    // v0.80: the lot's critical point (mozzarella CCP 3 stretching, ricotta CCP 4) asked here if it is not recorded yet
    const ccpCode = b.input_kind === 'whey' ? 'CCP-RIC' : 'CCP-STRETCH';
    const ccpDone = await ccpRecorded(ccpCode, b.batch_lot, b.id);
    // v0.96 (audit A-03): pasteurisation too — a start interrupted before CCP 2 must not close without it
    const pastDone = b.input_kind === 'whey' ? true : await ccpRecorded('CCP-PAST', b.batch_lot, b.id);
    if (!pastDone) field('pastv', 'Temperatura di pastorizzazione (CCP 2), °C · non ancora registrata', 'number', { ...cpRange('CCP-PAST'), unit: '°C', limit: 'Valore letto all\'inizio del lotto; se era scritto sul foglio, ricopialo qui' });
    if (!ccpDone) field('ccpv', b.input_kind === 'whey' ? 'Temperatura di affioramento (CCP 4), °C · non ancora registrata' : 'Temperatura della pasta filata (CCP 3), °C · non ancora registrata', 'number', { ...cpRange(ccpCode), unit: '°C', limit: 'Valore letto sul termometro; se era scritto sul foglio, ricopialo qui' });
    field('ph', 'pH cagliata (se misurato)', 'number', { required: false, min: 3, max: 8 }); field('n', 'Etichette da stampare', 'number', { required: false, min: 0, max: 200, int: true });
    const pb = paperBox('la fine del lotto');                            // v0.97 (audit A-20)
    if (byp) {                                       // v0.95 (audit A-16): an explicit choice, not an optional field that is easy to leave empty
      const ric = field('ricyn', 'Ricotta con il siero di questo lotto?', 'select', { options: [['', '— scegli —'], ['si', 'Sì, faccio la ricotta'], ['no', 'No, niente ricotta oggi']] });
      const wIn = field('whey', 'Siero per ricotta, kg', 'number', { required: false, min: 1, max: 5000, unit: 'kg' }), wLbl = wIn.previousElementSibling;
      const tog = () => { const on = ric.value === 'si'; wIn.style.display = wLbl.style.display = on ? '' : 'none'; wIn.required = on; };
      ric.addEventListener('change', tog); tog();
    }
    openForm('Fine lotto ' + b.batch_lot, `${b.milk_in_kg} kg ${b.input_kind === 'whey' ? 'siero' : 'latte'} in caldaia`, async () => {
      phCheck(val('ph')); if (!ccpDone) plausCheck(ccpCode, val('ccpv')); if (!pastDone) plausCheck('CCP-PAST', val('pastv'));   // v0.95 (audit D-12): before the packing steps, not after them
      pb.check(); const paper = pb.on(), pWho = paper ? pb.who() : null;
      const ricNo = !!byp && val('ricyn') === 'no';
      if (byp && val('ricyn') === 'si' && !(val('whey') > 0)) throw new Error('Scrivi i kg di siero per la ricotta');
      bId = b.id || '$1.id';                       // per attempt: an earlier attempt with a milk correction must not leave '$2.id'
      const out = val('out'), ph = val('ph'), n = val('n'), whey = byp && val('ricyn') === 'si' ? val('whey') : 0;
      // v0.98 (audit D-06): a yield that cannot be means a wrong number of kg. Above the maximum: the kg of milk written at the start
      // are corrected here with a reason (or the kg made); below the minimum: what was lost is written down. The database checks the same.
      const isWhey = b.input_kind === 'whey', what = isWhey ? 'siero' : 'latte';
      const yLo = isWhey ? setting('prod.ricotta_yield_min_pct', 2) : setting('prod.yield_min_pct', 10), yHi = isWhey ? setting('prod.ricotta_yield_max_pct', 25) : setting('prod.yield_max_pct', 45);
      let milkKg = Number(b.milk_in_kg), fix = null, yNote = null, y = Math.round(out / milkKg * 1000) / 10;
      if (y > yHi) {
        if (!(await ask({ danger: true, title: `Resa ${itN(y)} %: impossibile`, yes: `Correggo i kg di ${what}`, no: 'Correggo i kg prodotti',
          lines: [`${fmtKg(out)} kg di prodotto da ${fmtKg(milkKg)} kg di ${what}: al massimo si arriva al ${itN(yHi)} %.`,
                  `Se all'inizio del lotto i kg di ${what} sono stati scritti sbagliati, correggili ora (con il motivo). Se hai sbagliato i kg prodotti, correggili nel modulo.`] }))) throw stop();
        const kgT = await ask({ title: `Kg di ${what} del lotto ${b.batch_lot}`, yes: 'Avanti', no: 'Annulla', lines: [`All'inizio sono stati scritti ${fmtKg(milkKg)} kg. Scrivi quelli giusti.`],
          input: { label: `Kg di ${what} messi in caldaia`, placeholder: `es. ${fmtKg(setting('prod.vat_kg', 310))}`, min: 1, mode: 'decimal' } });
        if (kgT == null) throw stop();
        const pk = parseNum(kgT);
        if (pk.amb || pk.bad || !(pk.v > 0)) throw new Error(`«${kgT}»: scrivi solo il numero dei kg, senza punto (es. 310)`);
        const vat = setting('prod.vat_kg', null);
        if (!isWhey && vat && pk.v > vat * 1.1) throw new Error(`${fmtKg(pk.v)} kg: una caldaia ne tiene al massimo ${fmtKg(Math.round(vat * 1.1))} kg. Controlla i kg.`);
        const why = await ask({ title: 'Motivo della correzione', yes: 'Correggi', no: 'Annulla', lines: [`${what} in caldaia: ${fmtKg(milkKg)} → ${fmtKg(pk.v)} kg.`],
          input: { label: 'Perché (es. scritto 31 invece di 310)', min: 3 } });
        if (why == null) throw stop();
        fix = { kg: pk.v, reason: why }; milkKg = pk.v; y = Math.round(out / milkKg * 1000) / 10;
        if (y > yHi) throw new Error(`Anche con ${fmtKg(milkKg)} kg di ${what} la resa è ${itN(y)} %: controlla i kg prodotti (${fmtKg(out)}).`);
      }
      if (y < yLo) {
        yNote = await ask({ title: `Resa ${itN(y)} %: troppo bassa`, yes: 'Registra con il motivo', no: 'Correggo i kg',
          lines: [`${fmtKg(out)} kg di prodotto da ${fmtKg(milkKg)} kg di ${what}: di solito almeno il ${itN(yLo)} %.`, 'Se i kg sono giusti e una parte del lotto è andata persa, scrivi cosa è successo.'],
          input: { label: 'Cosa è successo? (es. metà cagliata persa)', min: 3 } });
        if (yNote == null) throw stop();
      }
      if (fix && !b.id) bId = '$2.id';
      // v0.97 (audit A-17): an unusual yield is a question with the numbers that stays until answered (a double tap used to confirm it)
      if (ey && !yNote && Math.abs(y - ey.pct) > (ey.tolerance_pts ?? 4) && !(await ask({ title: 'Controlla i kg', yes: 'Sì, è giusto', no: 'Correggo',
        lines: [`${fmtKg(out)} kg di prodotto da ${fmtKg(milkKg)} kg di ${what}: resa ${itN(y)} %.`, `Di solito ${itN(ey.pct)} %: hai scritto bene i kg?`] }))) throw stop();
      if (whey > milkKg * 0.95) throw new Error(`Siero per la ricotta ${fmtKg(whey)} kg: non può superare il latte della caldaia (${fmtKg(milkKg)} kg). Controlla i kg.`);   // v0.98 (D-30)
      // v0.97 (audit A-07): a missing CCP written here out of its limit holds the lot: red question first
      if (!pastDone && !(await confirmOut('CCP-PAST', val('pastv'), b.batch_lot))) throw stop();
      if (!ccpDone && !(await confirmOut(ccpCode, val('ccpv'), b.batch_lot))) throw stop();
      const closeDay = paper ? pb.day() : today();
      const expS = addDays(closeDay, prod?.shelf_life_days || 5), code = current.code;
      const lotLink = [`🖨 Stampa ${n || 1} etichett${(n || 1) === 1 ? 'a' : 'e'} lotto ${b.batch_lot}`, labelUrl(b.batch_lot, prod?.name, 'scad. ' + ddmm(expS), n || 1)];
      const startRicotta = () => runRicotta(b.batch_lot, byp, whey, `✓ Lotto ${b.batch_lot} chiuso`, [`${out} kg · resa ${y}% · scade ${ddmm(expS)}`], [lotLink]);
      const close = async () => {
        const ops = [scanEvent(code, 'batch_end', { payload: { output_kg: out, yield_pct: y, whey_to_byproduct_kg: whey, ...(fix ? { milk_corrected: fix } : {}), ...(paper ? { paper_at: pb.iso(), paper_by: pWho, copied_by: me().full_name } : {}) } }),
          // v0.98 (audit D-06): the milk kg corrected first (same atomic save), so the close is checked with the right kg
          ...(fix ? [{ rpc: 'correct_batch_milk', args: { p_batch_lot: b.batch_lot, p_milk_kg: fix.kg, p_reason: fix.reason, p_staff_id: me().id } }] : []),
          // v0.97 (audit A-22): the curd pH only when measured here (an empty field no longer erases the one recorded in the steps)
          { table: 'production_batches', update: bKey, row: { output_kg: out, ...(ph != null ? { curd_ph: ph } : {}), finished_at: paper ? pb.iso() : new Date().toISOString(), ...(ricNo ? { whey_kg: 0 } : {}), ...(yNote ? { yield_note: yNote } : {}) } },   // whey_kg 0 = "no ricotta" was chosen
          { table: 'stock_moves', row: { product_id: b.product_id, lot_number: b.batch_lot, expiry_date: expS, qty: out, move_type: 'production_out', batch_id: bId, source: 'tablet' } }];
        const pp = paper ? { p_source: 'paper', p_logged_at: pb.iso(), p_written_by: pWho } : { p_source: 'tablet' };
        if (!pastDone && val('pastv') != null) ops.push({ rpc: 'log_ccp', args: { p_cp_code: 'CCP-PAST', p_value: val('pastv'), p_staff_id: me().id, p_batch_lot: b.batch_lot, p_equipment_code: 'TERM-02', ...pp } });   // v0.96 (A-03)
        if (!ccpDone && val('ccpv') != null) ops.push({ rpc: 'log_ccp', args: { p_cp_code: ccpCode, p_value: val('ccpv'), p_staff_id: me().id, p_batch_lot: b.batch_lot, p_equipment_code: 'TERM-02', ...pp } });   // v0.80 (after the update: ids above stay $1)
        if (b.input_kind !== 'whey')   // ricotta label row is created when the batch starts; the printable label is offered at close (v0.52)
          ops.push({ table: 'labels', row: { kind: 'batch_lot', code: 'LOT:' + b.batch_lot, lot_number: b.batch_lot, product_id: b.product_id, batch_id: bId, qty_printed: n || 1, printed_by_id: me().id } });
        const sv = await save(ops);
        toast(`Resa ${itN(y)}% · ${itN(out)} kg ✓`);
        const ccpKo = (!pastDone && ccpOut('CCP-PAST', val('pastv'))) || (!ccpDone && ccpOut(ccpCode, val('ccpv')));
        if (whey > 0) {
          if (ccpKo) await ask({ danger: true, title: `⚠ NON CONFORMITÀ: lotto ${b.batch_lot} BLOCCATO`, lines: ['Non si vende finché il responsabile HACCP non lo sblocca (riceve l\'avviso).', 'Cosa fare adesso: ' + ((refStore()['cp_' + (!pastDone && ccpOut('CCP-PAST', val('pastv')) ? 'CCP-PAST' : ccpCode)] || {}).corrective_it || 'avvisa il responsabile HACCP.')], yes: 'Ho capito: avvio la ricotta', no: null });
          return startRicotta();
        }
        if (ccpKo) return ncCard(!pastDone && ccpOut('CCP-PAST', val('pastv')) ? 'CCP-PAST' : ccpCode, sv ? (sv.find(x => x && typeof x === 'object' && x.result === 'non_conformity') || { lot_on_hold: true }) : null, b.batch_lot, [`Lotto chiuso: ${itN(out)} kg · scade ${ddmm(expS)}. Le etichette si stampano lo stesso, ma il lotto resta bloccato.`]);
        return showDone(`✓ Lotto ${b.batch_lot} chiuso`, [`${itN(out)} kg · resa ${itN(y)}% · scade ${ddmm(expS)}`, 'Etichetta ogni cassa e confezione con il lotto.'], [lotLink]);
      };
      const presets = await loadPresets();
      const steps = mergeSteps(await doseSteps(b.product_id, 'close', { milk: milkKg, out }), processSteps(presets, b.preset_id || (presetsFor(presets, b.product_id).find(p => p.is_default) || {}).id, 'close'));
      if (!steps.length) return close();
      runDosing(`Confezionamento ${b.batch_lot} · ${out} kg`, b.batch_lot, steps, close);
      return 'stay';
    });
  }
  // 6 — direct shipment line from a batch QR (counter sales live on Shopify POS; online/wholesale orders go through 🚚 Da spedire)
  async function stepPick(b) {
    // v0.78: works offline — product from the device copy, customers from the list kept on the tablet
    let { data: prod } = await live(sb.from('products').select('*').eq('id', b.product_id).single());
    if (!prod) prod = cachedProduct(b.product_id);
    if (!prod) throw new Error('Prodotto non disponibile senza rete: riprova quando torna la connessione');
    const { data: custs } = await cached('customers', () => sb.from('parties').select('id, legal_name').in('type', ['customer', 'both']).eq('active', true).order('legal_name'));
    if (!custs || !custs.length) throw new Error(navigator.onLine ? 'Nessun cliente attivo in anagrafica' : 'Senza rete e clienti non ancora salvati sul tablet');
    const d = document.createElement('div'); d.className = 'card';
    d.innerHTML = `<div class="scan">${esc(prod.name)}</div><div class="status">Spedizione diretta senza ordine. Le vendite al banco si battono su Shopify POS; gli ordini online e ingrosso si preparano da 🚚 Da spedire.</div>`;
    $('form').append(d);
    field('kg', 'kg', 'number', { min: 0.01, max: 1000, unit: 'kg' });
    field('cust', 'Cliente', 'select', { options: [['', '—'], ...custs.map(x => [x.id, x.legal_name])] });
    openForm('Spedizione', 'lotto ' + b.batch_lot, async () => {
      const kg = val('kg');
      if (!val('cust')) { toast('Scegli il cliente', 'err'); throw new Error('cliente'); }
      // v1.04 (audit D-22, PRINT-04): the DDT number comes from the database's yearly series (DDT-2026-0001…), also when sent later
      const out = await save([scanEvent(current.code, 'pick', { payload: { kg, mode: 'ship' } }),
        { table: 'shipments', row: { customer_id: val('cust'), status: 'picked', driver_id: me().id } },
        { table: 'shipment_lines', row: { shipment_id: '$1.id', product_id: prod.id, lot_number: b.batch_lot, qty: kg } },
        { table: 'stock_moves', row: { product_id: prod.id, lot_number: b.batch_lot, qty: -kg, move_type: 'sale', source: 'tablet' } }]);
      const sh = out && out[1] && typeof out[1] === 'object' ? out[1] : null;
      if (out) toast(`Spedizione ${sh && sh.ddt_number ? sh.ddt_number + ' ' : ''}· ${kg} kg ✓`);
      else toast(`Spedizione di ${kg} kg salvata senza rete: il numero DDT arriva quando torna la rete. Non far partire la merce senza il DDT.`, 'err', 8000);
    });
  }
  // 11 — goods receipt: approved PO arrives → stock goes up
  async function stepReceive(poNumber) {
    const { data: po, error } = await sb.from('v_open_purchase_orders').select('*').eq('po_number', poNumber).maybeSingle();
    if (error) throw new Error('Ordine non leggibile offline');
    if (!po) throw new Error('Ordine ' + poNumber + ' non in arrivo (non approvato o già ricevuto)');
    $('form').innerHTML = '';
    po.lines.forEach((l, i) => {
      const h = document.createElement('div'); h.className = 'card'; h.style.marginTop = '14px';
      h.innerHTML = `<div class="scan">${esc(l.name)}</div><div>ordinati ${Number(l.qty_ordered).toLocaleString('it-IT')} ${esc(l.unit)}${Number(l.qty_received) > 0 ? ` · già ricevuti ${Number(l.qty_received).toLocaleString('it-IT')}` : ''} · listino € ${Number(l.unit_price_eur).toLocaleString('it-IT', { minimumFractionDigits: 2, maximumFractionDigits: 4 })}/${esc(l.unit)}</div>`;
      $('form').append(h);
      // v0.97 (audit A-09): count and read, don't confirm a prefilled number — empty fields, what was ordered as the hint
      const q = field('q' + i, `Ricevuti (${l.unit}) · contali`, 'number', { required: false, min: 0, max: 1000000, unit: l.unit, int: l.unit === 'pz' });
      q.placeholder = `ordinati ${Number(l.remaining).toLocaleString('it-IT')}`;
      field('lot' + i, 'Lotto fornitore', 'text', { required: false });
      const e = field('exp' + i, 'Scadenza (se stampata: leggila sulla confezione)', 'date', { required: false, limit: l.shelf_life_days ? `di solito dura ${l.shelf_life_days} giorni` : '' });
      e.min = today();
      field('pr' + i, `Prezzo sul DDT €/${l.unit} (solo se diverso)`, 'number', { required: false, min: 0, max: 100000, unit: '€/' + l.unit });
    });
    field('ddt', 'Numero DDT', 'text', { required: false }); field('photo', 'Foto DDT', 'file', { required: false });
    // v0.57 · Manuale §7.7: controllo all'arrivo registrato con il ricevimento
    field('chk', 'Controllo all\'arrivo', 'select', { options: [['', '— scegli —'], ['1', 'Conforme: confezioni integre, etichette, scadenze, temperatura ok'], ['0', 'NON conforme']] });
    field('chknote', 'Cosa non va (se non conforme)', 'text', { required: false });
    openForm(po.po_number, po.supplier + (po.status === 'partially_received' ? ' · consegna parziale in corso' : ''), async () => {
      const lines = po.lines.map((l, i) => ({ sku: l.sku, qty: val('q' + i), lot: val('lot' + i) || null, expiry: val('exp' + i) || null, unit_price: val('pr' + i) }))
        .filter(x => x.qty && x.qty > 0);
      if (!lines.length) { toast('Inserisci almeno una quantità ricevuta', 'err'); throw new Error('vuoto'); }
      const over = lines.filter(x => { const l = po.lines.find(p => p.sku === x.sku); return x.qty > Number(l.remaining) * 1.02; });
      if (over.length && !(await ask({ title: 'Più di quanto ordinato', lines: over.map(x => { const l = po.lines.find(p => p.sku === x.sku); return `${l.name}: ricevuti ${itN(x.qty)} ${l.unit}, ordinati ${itN(l.remaining)}`; }).concat('È giusto?') }))) throw stop();
      // v0.98 (audit D-18): a DDT price far from the list is almost always a comma slip (410 for 4,10): it would become the new list price
      const pricey = lines.filter(x => { const l = po.lines.find(p => p.sku === x.sku), lp = Number(l.unit_price_eur); return x.unit_price != null && lp > 0 && (x.unit_price > lp * 1.5 || x.unit_price < lp * 0.5); });
      if (pricey.length && !(await ask({ danger: true, title: 'Prezzo molto diverso dal listino', yes: 'Sì, è il prezzo del DDT', no: 'Correggo',
        lines: pricey.map(x => { const l = po.lines.find(p => p.sku === x.sku); return `${l.name}: ${itNum(x.unit_price, 4)} €/${l.unit} sul DDT, listino ${itNum(l.unit_price_eur, 4)} €.`; }).concat('Diventa il nuovo prezzo per i prossimi ordini. Controlla la virgola: è giusto?') }))) throw stop();
      const confirmed = over.length > 0 || pricey.length > 0;
      const skipped = po.lines.filter(l => !lines.some(x => x.sku === l.sku));
      if (skipped.length && !(await ask({ title: 'Righe senza quantità', lines: [skipped.map(l => l.name).join(', ') + ': non arrivate (restano da ricevere).', 'È giusto?'], yes: 'Sì, non sono arrivate', no: 'Le scrivo' }))) throw stop();
      const ddt = val('ddt') || null, chk = val('chk'), chkNote = (val('chknote') || '').trim();
      if (chk === '') { toast('Registra il controllo all\'arrivo', 'err'); throw new Error('chk'); }
      if (chk === '0' && !chkNote) { toast('Scrivi cosa non va nella merce', 'err'); throw new Error('chknote'); }
      await saveConfirm([scanEvent(current.code, 'goods_receive', { payload: { po_number: po.po_number, ddt, lines, check_ok: chk === '1', check_note: chkNote || null } }),
        { rpc: 'receive_purchase_order', args: { p_po_number: po.po_number, p_lines: lines, p_staff_id: me().id, p_ddt: ddt, ...(confirmed ? { p_confirm: true } : {}) } },
        { rpc: 'record_receipt_check', args: { p_po_number: po.po_number, p_ok: chk === '1', p_note: chkNote || null, p_staff_id: me().id, p_ddt: ddt } }], 1);
      const f = $('photo').files[0];
      if (f && navigator.onLine) { const path = `ddt/${today()}_${po.po_number}.jpg`; const { error: ue } = await sb.storage.from('documents').upload(path, f, { upsert: true });
        if (!ue) await sb.from('documents').insert({ kind: 'ddt_in', storage_path: path, original_filename: f.name, mime_type: f.type, document_date: today(), related_table: 'purchase_orders', related_id: po.id, uploaded_by_id: me().id }); }
      const tot = lines.reduce((a, x) => a + x.qty, 0);
      if (chk === '0') toast(`Ricevuto ${po.po_number} · merce NON conforme: isolala con il cartello e avvisa il responsabile`, 'err');
      else toast(`Ricevuto ${po.po_number} · ${tot.toLocaleString('it-IT')} pezzi/kg in magazzino ✓`);
    });
  }

  // 12 — weekly stock count. v0.97 (audit A-09/D-05): nothing prefilled — each line is counted (or «✓ ci sono» says the system
  // quantity is right, line by line); a line left empty is «not counted», not «same as the system». The database compares the
  // count with what it holds when the count is SAVED (sales and batches in the meantime are not counted twice).
  async function stepStockCount() {
    $('form').innerHTML = ''; current = { code: 'COUNT:' };
    const { data: sheet, error } = await sb.rpc('start_stock_count', { p_staff_id: me().id });
    if (error) { toast('Conta non disponibile offline', 'err'); return; }
    const lines = sheet.lines || [];
    let lastKind = '';
    lines.forEach((l, i) => {
      if (l.kind !== lastKind) { lastKind = l.kind; const h = document.createElement('h2'); h.style.marginTop = '18px'; h.textContent = l.kind === 'finished_good' ? 'Prodotto finito (per lotto)' : 'Consumabili e imballi'; $('form').append(h); }
      const q = field('c' + i, `${l.name}${l.lot ? ' · ' + l.lot : ''} (${l.unit})`, 'number', { required: false, min: 0, max: 1000000, unit: l.unit });
      q.placeholder = 'contati'; q.dataset.sys = l.system_qty; q.dataset.line = l.line_id;
      const b = document.createElement('button'); b.type = 'button'; b.className = 'nitem'; b.style.marginTop = '4px';
      b.textContent = `✓ Ci sono ${Number(l.system_qty).toLocaleString('it-IT')} ${l.unit} (come a sistema)`;
      b.onclick = () => { setNum(q, l.system_qty); q.dispatchEvent(new Event('input')); q.dataset.confirm = '1'; current.dirty = true; };
      $('form').append(b);
      q.oninput = e => { if (e.isTrusted) delete q.dataset.confirm; q.style.borderColor = numOf(q) != null && numOf(q) !== Number(q.dataset.sys) ? 'var(--warn)' : ''; };
    });
    field('note', 'Note (facoltative)', 'text', { required: false });
    openForm('Conta magazzino', `${lines.length} righe · conta e scrivi, oppure «✓ Ci sono» se il numero a sistema è giusto`, async () => {
      const inputs = [...$('form').querySelectorAll('input[data-line]')];
      const counted = inputs.filter(i => i.value !== '');
      if (counted.some(i => numOf(i) < 0)) throw new Error('Una quantità contata è negativa: scrivi 0 se non c\'è più niente');
      const changed = counted.filter(i => numOf(i) !== Number(i.dataset.sys));
      const big = changed.filter(i => { const sys = Number(i.dataset.sys); return sys > 0 && Math.abs(numOf(i) - sys) / sys > 0.5; });
      if (big.length && !(await ask({ title: 'Differenze grandi', lines: [`${big.length === 1 ? '1 riga ha' : big.length + ' righe hanno'} una differenza oltre il 50 % dal sistema: ricontrolla.`], yes: 'Ho ricontrollato: salva', no: 'Ricontrollo' }))) throw stop();
      const empty = inputs.length - counted.length;
      if (empty && !(await ask({ title: `${empty === 1 ? '1 riga senza numero' : empty + ' righe senza numero'}`, lines: ['Restano «non contate»: il sistema non le cambia.', 'Se non c\'è più niente, scrivi 0.'], yes: 'Salva così', no: 'Le conto' }))) throw stop();
      const { data, error: pe } = await sb.rpc('post_stock_count', { p_count_id: sheet.count_id, p_lines: counted.map(i => i.dataset.confirm === '1' ? { line_id: i.dataset.line, confirm: true } : { line_id: i.dataset.line, counted_qty: numOf(i) }), p_staff_id: me().id, p_note: val('note') || null });
      if (pe) { toast(pe.message, 'err', 8000); throw pe; }
      await save([scanEvent('COUNT:', 'task_done', { payload: { count_id: sheet.count_id, changed: data.lines_changed, counted: data.lines_counted ?? counted.length } })]);
      await closeTask({ code: 'T-COUNT' });
      toast(`Conta registrata · ${data.lines_counted ?? counted.length} righe contate${data.lines_changed ? ` · ${data.lines_changed} rettifiche` : ' · tutto coincide'}${empty ? ` · ${empty} non contate` : ''} ✓`, 'ok', 6000);
    });
  }
  $('btn-count').onclick = () => stepStockCount().catch(e => { toast(e.message, 'err'); show('home'); });

  // 13 — effluent register: what left the dairy today, where it went, which document covers it
  function stepEffluent() {
    $('form').innerHTML = ''; current = { code: 'EFFL:' };
    field('kind', 'Cosa', 'select', { options: [['scotta', 'Scotta (dopo la ricotta)'], ['siero', 'Siero (non lavorato)'], ['acque_lavaggio', 'Acque di lavaggio'], ['fanghi', 'Fanghi / residui'], ['altro', 'Altro']] });
    field('qty', 'Quantità', 'number', { min: 0, max: 1000000 });
    field('unit', 'Unità', 'select', { options: [['l', 'litri'], ['m3', 'm³'], ['kg', 'kg']] });
    field('dest', 'Destinazione', 'select', { options: [['allevamento', 'Allevamento (sottoprodotto)'], ['fognatura', 'Fognatura (scarico autorizzato)'], ['trasportatore', 'Trasportatore autorizzato'], ['ricotta', 'Riusato per ricotta'], ['depuratore_interno', 'Depuratore interno'], ['altro', 'Altro']] });
    field('recipient', 'Chi ritira (allevamento / ditta)', 'text', { required: false });
    field('doc', 'Documento (DDT sottoprodotto / FIR / RENTRI)', 'text', { required: false });
    field('note', 'Note', 'text', { required: false });
    const dest = $('dest'), doc = $('doc'), rec = $('recipient');
    const needDoc = () => ['allevamento', 'trasportatore'].includes(dest.value);
    dest.onchange = () => { doc.required = needDoc(); rec.required = needDoc(); doc.style.borderColor = needDoc() && !doc.value ? 'var(--warn)' : ''; };
    dest.onchange();
    openForm('Reflui', 'Una riga per ogni ritiro o scarico. Allevamento e trasportatore richiedono il documento.', async () => {
      if (needDoc() && !val('doc')) { toast('Serve il numero del documento per allevamento o trasportatore', 'err'); throw new Error('doc'); }
      await save([scanEvent('EFFL:', 'task_done', { payload: { kind: val('kind'), qty: val('qty'), unit: val('unit'), destination: val('dest') } }),
        { table: 'effluent_log', row: { kind: val('kind'), qty: val('qty'), unit: val('unit'), destination: val('dest'), recipient: val('recipient') || null, document_ref: val('doc') || null, notes: val('note') || null, staff_id: me().id } }]);
      toast('Refluo registrato ✓');
    });
  }
  $('btn-effl').onclick = () => { try { stepEffluent(); } catch (e) { toast(e.message, 'err'); show('home'); } };

  // 14 — fulfilment: paid Shopify orders + confirmed wholesale orders → scan lot, weigh, confirm. pack_order() does the rest.
  async function loadShipCount() {
    const { data } = await sb.from('v_ship_backlog').select('*').maybeSingle();
    const n = data ? Number(data.shopify_waiting) + Number(data.wholesale_waiting) : 0;
    $('ship-n').textContent = n ? `(${n})` : ''; $('btn-ship').classList.toggle('attention', n > 0);
  }
  const fmtKg = n => Number(n).toLocaleString('it-IT', { maximumFractionDigits: 2 });
  const fmtDay = s => s ? s.slice(8, 10) + '/' + s.slice(5, 7) : '';
  async function stepShipList() {
    $('form').innerHTML = ''; current = { code: 'SHIP:' };
    // v0.71: the day's packing plan — lots already allocated (oldest in-date first, split over lots, never twice), held/expired
    // lots blocked, pick list for the cold room. Older database: the plain list with the suggested lots.
    let plan = null;
    const r = await live(sb.rpc('packing_plan'));
    if (!r.error && r.data) plan = r.data;
    else {
      const { data, error } = await sb.from('v_orders_to_ship').select('*');
      if (error) { toast('Lista spedizioni non disponibile offline', 'err'); return; }
      plan = { pick: [], orders: (data || []).map(o => ({ ...o, late_days: 0, short_kg: 0, lines: (o.lines || []).map(l => ({ ...l, blocked: [], short_kg: 0, eligible: l.suggested || [],
        alloc: (l.suggested || []).slice(0, 1).map(x => ({ lot: x.lot, expiry: x.expiry, qty: l.qty, on_hand: x.on_hand })) })) })) };
    }
    if (!plan.orders.length) { toast('Niente da spedire'); return; }
    if (plan.pick && plan.pick.length) {
      const c = document.createElement('div'); c.className = 'card';
      c.innerHTML = '<div class="scan">Prelievo dalla cella</div>' + plan.pick.map(x => `<div style="margin-top:4px">${esc(x.product)} · lotto <b>${esc(x.lot)}</b>${x.expiry ? ' (scade ' + esc(fmtDay(x.expiry)) + ')' : ''} · <b>${fmtKg(x.kg)} ${esc(x.unit)}</b> <span class="code">→ ${(x.orders || []).map(esc).join(', ')}</span></div>`).join('');
      $('form').append(c);
    }
    plan.orders.forEach(o => {
      const d = document.createElement('div'); d.className = 'task' + ((o.late_days > 0 || o.short_kg > 0) ? ' overdue' : ''); d.style.marginTop = '8px';
      const items = (o.lines || []).map(l => `${fmtKg(l.qty)} ${esc(l.unit)} ${esc(l.name)}${(l.alloc || []).length ? ' ← ' + l.alloc.map(a => `${esc(a.lot)} ${fmtKg(a.qty)}`).join(' + ') : ''}`).join(' · ');
      const addr = o.ship_address ? [o.ship_address.city, o.ship_address.zip].filter(Boolean).join(' ') : (o.ship_city || '');
      const flags = [o.late_days > 0 ? `⏰ in ritardo di ${o.late_days} g` : '', o.short_kg > 0 ? `⚠ mancano ${fmtKg(o.short_kg)} kg in giacenza` : '', o.unmapped ? `⚠ ${esc(o.unmapped)} righe non collegate` : ''].filter(Boolean).join(' · ');
      d.innerHTML = `<div><div>${o.channel === 'shopify' ? '🛒 ' : '🏬 '}${esc(o.order_number)} · ${esc(o.customer || (o.ship_address && o.ship_address.name) || 'cliente online')}${addr ? ' · ' + esc(addr) : ''}</div><div class="code">${items || 'nessuna riga collegata al magazzino'}${flags ? '<br>' + flags : ''}</div></div><time>${esc(fmtDay(o.due_date))}</time>`;
      d.onclick = () => stepPack(o).catch(e => { toast(e.message, 'err'); show('home'); });
      $('form').append(d);
    });
    const late = plan.orders.filter(o => o.late_days > 0).length;
    openForm('Da spedire', `${plan.orders.length} ordin${plan.orders.length === 1 ? 'e' : 'i'}${late ? ` · ${late} in ritardo` : ''} · nell'ordine in cui prepararli, lotti già assegnati`, async () => {});
    $('btn-form-save').style.display = 'none';
  }
  async function stepPack(o) {
    $('form').innerHTML = ''; current = { code: 'SHIP:' + o.order_number, force: false };
    const { data: cfg } = await sb.from('settings').select('key, value').in('key', ['ship.default_carrier', 'ship.wholesale_carrier', 'ship.tolerance_pct', 'ship.max_variance_pct']);
    const S = Object.fromEntries((cfg || []).map(r => [r.key, r.value]));
    if (!(o.lines || []).length) throw new Error('Ordine senza righe collegate al magazzino: collega i prodotti Shopify in Configurazione → Vendite');
    const rows = [];
    const why = x => x.reason === 'held' ? 'bloccato (sicurezza alimentare)' : x.reason === 'expired' ? 'scaduto' : `scade ${fmtDay(x.expiry)}, troppo presto`;
    o.lines.forEach((l, i) => {
      // v0.71: one row per allocated lot (oldest in-date first; a line split over two lots gets two rows), already filled in
      const alloc = (l.alloc && l.alloc.length) ? l.alloc : [{ lot: '', qty: l.qty }];
      const card = document.createElement('div'); card.className = 'card'; card.style.marginTop = '14px';
      card.innerHTML = `<div class="scan">${esc(l.name)}</div><div>ordinati <b>${fmtKg(l.qty)} ${esc(l.unit)}</b>${(l.alloc || []).length > 1 ? ` · da ${l.alloc.length} lotti, prima il più vecchio` : ''}${l.short_kg > 0 ? ` · <span style="color:var(--warn)">mancano ${fmtKg(l.short_kg)} ${esc(l.unit)} in giacenza</span>` : ''}${!(l.alloc || []).length ? ' · <span style="color:var(--warn)">nessun lotto utilizzabile in giacenza</span>' : ''}</div>`
        + ((l.blocked || []).length ? `<div class="code">Non usare: ${l.blocked.map(x => `${esc(x.lot)} · ${esc(why(x))}`).join(' · ')}</div>` : '');
      $('form').append(card);
      alloc.forEach((a, j) => {
        const k = i + '_' + j;
        const opts = [...(l.eligible || [])]; if (a.lot && !opts.some(x => x.lot === a.lot)) opts.unshift({ lot: a.lot, expiry: a.expiry, on_hand: a.on_hand });
        const lot = field('lot' + k, alloc.length > 1 ? `Lotto ${j + 1} di ${alloc.length}` : 'Lotto (già assegnato: conferma o scansiona l\'etichetta)', 'select',
          { options: [['', '— scegli il lotto —'], ...opts.map(x => [x.lot, `${x.lot} · scade ${fmtDay(x.expiry)} · ${fmtKg(x.on_hand)} ${l.unit}`])] });
        lot.value = a.lot || '';
        const scanBtn = document.createElement('button'); scanBtn.type = 'button'; scanBtn.className = 'btn secondary'; scanBtn.textContent = '📷 Scansiona lotto'; scanBtn.style.marginTop = '6px';
        scanBtn.onclick = () => { scanTarget = code => {
          const v = code.replace(/^LOT:/i, '').trim(); show('form');
          const bl = (l.blocked || []).find(x => x.lot.toLowerCase() === v.toLowerCase());
          if (bl && bl.reason !== 'short_life') { lot.style.borderColor = 'var(--warn)'; toast(`Lotto ${v} ${bl.reason === 'held' ? 'bloccato per sicurezza alimentare' : 'scaduto'}: non si può spedire. Prendi ${lot.value || 'un altro lotto'}.`, 'err'); return; }
          const ok = [...lot.options].some(op => op.value === v);
          if (!ok) { const op = document.createElement('option'); op.value = v; op.textContent = v + (bl ? ' · scade troppo presto' : ' · non tra quelli assegnati'); lot.append(op); }
          lot.value = v; lot.style.borderColor = ok && !bl ? 'var(--ok)' : 'var(--warn)'; current.force = false;
          toast(v === a.lot ? 'Lotto confermato ✓' : bl ? `Lotto ${v}: scade il ${fmtDay(bl.expiry)}, prima del minimo — verrà chiesta conferma` : 'Lotto diverso da quello assegnato: controlla la scadenza', v === a.lot ? '' : 'err'); }; startScan(); };
        $('form').append(scanBtn);
        // v0.97 (audit A-09): the weight is read on the scale, not confirmed from the order: empty field, the planned kg as the hint
        const q = field('q' + k, `Peso effettivo (${l.unit})${alloc.length > 1 ? ' da questo lotto' : ''} · pesa`, 'number', { required: alloc.length === 1, min: 0, max: 1000, unit: l.unit });
        q.placeholder = `previsti ${fmtKg(a.qty)}`; q.dataset.weighed = '0';
        q.oninput = () => { q.dataset.weighed = '0'; current.force = false; };
        $('form').append(scaleButton(q, 'net'));
        rows.push({ l, lot, q });
      });
    });
    const g = field('gross', 'Peso lordo collo (kg, facoltativo)', 'number', { required: false, min: 0, max: 1000, unit: 'kg' }); $('form').append(scaleButton(g, 'gross'));
    const carrier = field('carrier', 'Vettore', 'text', { required: false }); carrier.value = o.channel === 'wholesale' ? (S['ship.wholesale_carrier'] || 'Consegna diretta') : (S['ship.default_carrier'] || 'BRT');
    field('tracking', 'Tracking / n. lettera di vettura (se già stampata)', 'text', { required: false });
    field('note', 'Note', 'text', { required: false });
    openForm(`Prepara ${o.order_number}`, `${o.customer || 'cliente online'} · ${o.lines.length} righe · tolleranza ±${S['ship.tolerance_pct'] || 5}%, oltre +${S['ship.max_variance_pct'] || 30}% non si spedisce`, async () => {
      // v0.79: a row set to 0 (all the kg taken from the other lot of a split line) is left out instead of refusing the save
      const lines = rows.map(r => ({ product_id: r.l.product_id, lot_number: r.lot.value, qty: numOf(r.q) || 0, weighed: r.q.dataset.weighed === '1' })).filter(x => x.qty > 0);
      if (!lines.length) { toast('Nessuna quantità da spedire', 'err'); throw new Error('qty'); }
      if (lines.some(x => !x.lot_number)) { toast('Manca il lotto su una riga', 'err'); throw new Error('lot'); }
      // v0.97 (audit A-17): what needs confirming is a question with the reasons that stays until answered, then the same save with force
      let { data, error } = await sb.rpc('pack_order', { p_order_id: o.order_id, p_lines: lines, p_staff_id: me().id, p_gross_kg: val('gross'), p_carrier: val('carrier') || null, p_tracking: val('tracking') || null, p_notes: val('note') || null, p_force: false });
      // v1.04 (audit D-22): too much of a product, or a product not in the order: a card that stays until read, then back to the weights
      if (error && error.hint === 'weight') { await ask({ danger: true, title: 'Non si spedisce così', lines: [error.message], yes: 'Correggo', no: null }); throw stop(); }
      if (error) { toast(error.message, 'err'); throw error; }
      if (data && data.needs_confirm) {
        const ok = await ask({ title: 'Da confermare prima di spedire', lines: data.reasons && data.reasons.length ? data.reasons : [`Pesati ${fmtKg(data.packed_kg)} kg contro ${fmtKg(data.ordered_kg)} ordinati (${data.variance_pct > 0 ? '+' : ''}${itN(data.variance_pct)} %)`], yes: 'Sì, spedisco così', no: 'Correggo' });
        if (!ok) throw stop();
        ({ data, error } = await sb.rpc('pack_order', { p_order_id: o.order_id, p_lines: lines, p_staff_id: me().id, p_gross_kg: val('gross'), p_carrier: val('carrier') || null, p_tracking: val('tracking') || null, p_notes: val('note') || null, p_force: true }));
        if (error) { toast(error.message, 'err'); throw error; }
      }
      await save([scanEvent(current.code, 'pick', { payload: { order: o.order_number, ddt: data.ddt_number, kg: data.packed_kg, lines: lines.length } })]);
      // done: show the print buttons instead of going home
      $('form').innerHTML = ''; $('btn-form-save').style.display = 'none';
      const c = document.createElement('div'); c.className = 'card';
      c.innerHTML = `<div class="scan">✓ ${esc(data.ddt_number)}</div><div>${esc(o.order_number)} · ${fmtKg(data.packed_kg)} kg in ${esc(data.lines)} righe · ${esc(data.carrier)}${data.needs_shopify_fulfilment ? '<br>Shopify verrà aggiornato dal bot (cliente avvisato con il tracking).' : '<br>Ordine ingrosso chiuso.'}${(data.confirmed || []).length ? '<br><span class="code">Confermato: ' + data.confirmed.map(esc).join('; ') + '</span>' : ''}</div>`;
      const pr = document.createElement('a'); pr.className = 'btn'; pr.style.cssText = 'display:block;text-align:center;text-decoration:none;margin-top:12px'; pr.target = '_blank'; pr.href = 'spedizione.html?id=' + data.shipment_id; pr.textContent = o.channel === 'wholesale' ? '🖨 Stampa DDT' : '🖨 Stampa packing list';
      const ok = document.createElement('button'); ok.type = 'button'; ok.className = 'btn secondary'; ok.style.cssText = 'display:block;width:100%;margin-top:8px'; ok.textContent = 'Fatto'; ok.onclick = () => { show('home'); loadTasks(); };
      $('form').append(c, pr, ok); toast('Spedizione registrata ✓');
      return 'stay';
    });
  }
  // ⚖ connected scale: Bluetooth (GATT Weight Scale 0x181D) on the tablet, HID scale (Dymo/Fairbanks class) on a PC. Manual entry always works.
  let bleChar = null;
  function scaleButton(input, kind) {
    const b = document.createElement('button'); b.type = 'button'; b.className = 'btn secondary'; b.style.marginTop = '6px'; b.textContent = '⚖ Leggi dalla bilancia';
    b.onclick = async () => {
      b.disabled = true; b.textContent = '⚖ lettura…';
      try { const kg = await readScale(); setNum(input, Math.round(kg * 100) / 100); input.dataset.weighed = '1'; input.dispatchEvent(new Event('change')); toast(`Bilancia: ${fmtKg(kg)} kg`); }
      catch (e) { toast(e.message || 'Bilancia non collegata: inserisci il peso a mano', 'err'); }
      finally { b.disabled = false; b.textContent = '⚖ Leggi dalla bilancia'; }
    };
    return b;
  }
  async function readScale() {
    if (navigator.bluetooth) {
      if (!bleChar) {
        const dev = await navigator.bluetooth.requestDevice({ filters: [{ services: ['weight_scale'] }], optionalServices: ['weight_scale'] });
        const srv = await (await dev.gatt.connect()).getPrimaryService('weight_scale');
        bleChar = await srv.getCharacteristic('weight_measurement');
        dev.addEventListener('gattserverdisconnected', () => { bleChar = null; });
      }
      return await new Promise((res, rej) => {
        const t = setTimeout(() => { bleChar.removeEventListener('characteristicvaluechanged', h); rej(new Error('Nessun peso ricevuto: appoggia il collo e riprova')); }, 6000);
        const h = e => { const v = e.target.value; const flags = v.getUint8(0); const raw = v.getUint16(1, true); const kg = (flags & 1) ? raw * 0.01 * 0.45359237 : raw * 0.005; clearTimeout(t); bleChar.removeEventListener('characteristicvaluechanged', h); res(kg); };
        bleChar.addEventListener('characteristicvaluechanged', h); bleChar.startNotifications().catch(rej);
      });
    }
    if (navigator.hid) {
      const [dev] = await navigator.hid.requestDevice({ filters: [{ usagePage: 0x8D }] });
      if (!dev) throw new Error('Nessuna bilancia scelta');
      if (!dev.opened) await dev.open();
      return await new Promise((res, rej) => {
        const t = setTimeout(() => { dev.removeEventListener('inputreport', h); rej(new Error('Nessun peso ricevuto dalla bilancia USB')); }, 6000);
        const h = e => { const d = e.data; if (d.byteLength < 5) return; const unit = d.getUint8(1), exp = d.getInt8(2), raw = d.getUint16(3, true); const val = raw * Math.pow(10, exp); const kg = unit === 3 ? val : unit === 2 ? val / 1000 : unit === 11 ? val * 0.0283495 : unit === 12 ? val * 0.45359237 : val; clearTimeout(t); dev.removeEventListener('inputreport', h); res(kg); };
        dev.addEventListener('inputreport', h);
      });
    }
    throw new Error('Questo browser non supporta bilance Bluetooth/USB: inserisci il peso a mano');
  }
  $('btn-ship').onclick = () => stepShipList().catch(e => { toast(e.message, 'err'); show('home'); });
  $('btn-reprint').onclick = () => stepReprint().catch(e => { toast(e.message, 'err'); show('home'); });

  // v1.03 (audit PRINT-08): a lot label is reprinted from the database (product, lot, expiry or arrival), never typed by hand.
  // The list: lots still being worked, then the last 14 days; a search finds older ones (up to 60 days) by any part of the code.
  async function stepReprint(q) {
    if (!['produzione', 'magazzino', 'spedizioni'].some(a => PERM.can(a, 2))) {
      toast(`Il profilo "${(PERM.data && PERM.data.role_name) || '?'}" non stampa etichette di lotto: chiedi al responsabile`, 'err'); show('home'); return; }
    $('form').innerHTML = ''; current = { code: 'REPRINT:' };
    const r = await live(sb.rpc('lot_labels', { p_q: q || null, p_days: q ? 60 : 14 }));
    if (r.error) throw new Error(unreachable(r.error) ? 'Serve la rete per ristampare: prodotto, lotto e scadenza vengono dal database' : r.error.message);
    const lots = r.data || [];
    const c = document.createElement('div'); c.className = 'card';
    c.innerHTML = '<label for="rp-q">Cerca il lotto (anche solo la fine, es. 15-A)</label>';
    const row = document.createElement('div'); row.className = 'row';
    const inp = document.createElement('input'); inp.id = 'rp-q'; inp.value = q || ''; inp.placeholder = 'es. L20261015-A o M261015-1'; inp.autocomplete = 'off';
    const go = document.createElement('button'); go.type = 'button'; go.className = 'btn secondary'; go.textContent = 'Cerca';
    row.append(inp, go); c.append(row); $('form').append(c);
    const search = () => stepReprint(inp.value.trim()).catch(e => { toast(e.message, 'err'); show('home'); });
    go.onclick = search; inp.onkeydown = e => { if (e.key === 'Enter') { e.preventDefault(); search(); } };
    if (!lots.length) { const d = document.createElement('div'); d.className = 'pending'; d.style.textAlign = 'left';
      d.textContent = q ? `Nessun lotto con «${q}» negli ultimi 60 giorni.` : 'Nessun lotto negli ultimi 14 giorni.'; $('form').append(d); }
    lots.forEach(l => {
      const d = document.createElement('div'); d.className = 'task' + (l.on_hold || l.rejected ? ' overdue' : ''); d.style.marginTop = '8px';
      const top = document.createElement('div'); const b = document.createElement('b'); b.textContent = l.lot; top.append(b, document.createTextNode(' · ' + (l.name || '')));
      const sub = document.createElement('div'); sub.className = 'code';
      sub.textContent = (l.sub || '') + (l.on_hold ? ` · ⚠ BLOCCATO (${l.hold_reason || 'sicurezza alimentare'}): non si vende` : '') + (l.rejected ? ' · latte respinto' : '');
      const w = document.createElement('div'); w.append(top, sub); d.append(w);
      d.onclick = () => pickReprint(l).catch(e => { toast(e.message, 'err'); show('home'); });
      $('form').append(d);
    });
    openForm('Ristampa etichette', q ? `Ricerca «${q}» · tocca il lotto da ristampare` : 'Lotti in lavorazione e degli ultimi 14 giorni · tocca quello da ristampare', async () => {});
    $('btn-form-save').style.display = 'none';
    if (!q) inp.blur();
  }
  async function pickReprint(l) {
    $('form').innerHTML = ''; current = { code: 'REPRINT:' + l.lot, saveLabel: 'Prepara l\'etichetta' };
    const c = document.createElement('div'); c.className = 'card' + (l.on_hold || l.rejected ? ' rej' : '');
    const h = document.createElement('div'); h.className = 'scan'; h.textContent = `Lotto ${l.lot}`; c.append(h);
    [l.name, l.sub, l.on_hold ? `⚠ Lotto BLOCCATO (${l.hold_reason || 'sicurezza alimentare'}): l'etichetta serve solo a riconoscerlo, non si vende` : null,
     l.rejected ? 'Latte respinto all\'arrivo: non si usa in produzione' : null].filter(Boolean).forEach(t => { const d = document.createElement('div'); d.textContent = t; c.append(d); });
    $('form').append(c);
    const n = field('rp-n', 'Quante etichette?', 'number', { min: 1, max: 60, int: true, limit: 'Nome, lotto e scadenza vengono dal database: non si scrivono a mano.' });
    setNum(n, l.copies || 1);
    openForm('Ristampa etichetta', `${l.lot} · ${l.name || ''}`, async () => {
      const k = val('rp-n');
      if (!(k >= 1 && k <= 60)) throw new Error('Scrivi quante etichette (da 1 a 60)');
      const r = await live(sb.rpc('lot_label_reprint', { p_lot: l.lot, p_copies: k, p_staff_id: me() ? me().id : null }));
      if (r.error) throw new Error(unreachable(r.error) ? 'Serve la rete per ristampare' : r.error.message);
      const d = r.data;
      return showDone(`Etichetta lotto ${d.lot} pronta`, [d.name, d.sub],
        [[`🖨 Stampa ${d.copies} etichett${d.copies === 1 ? 'a' : 'e'} lotto ${d.lot}`, labelUrl(d.lot, d.name, d.sub, d.copies)]]);
    });
  }

  // ---------- Guided dosing: recipe × milk → one confirm per ingredient ----------
  const MILK_DENSITY = 1.035;                       // kg per litre, buffalo milk (to confirm with the casaro)
  const RK = 'fabula_recipes';
  async function loadRecipes() {
    try { const { data, error } = await sb.from('v_recipe_active').select('*'); if (error) throw error; try { localStorage.setItem(RK, JSON.stringify(data)); } catch {} return data; }
    catch { try { return JSON.parse(localStorage.getItem(RK) || '[]'); } catch { return []; } }
  }
  const PK = 'perla_process_v1';
  async function loadPresets() {
    try { const { data, error } = await sb.from('v_process_steps').select('*').eq('preset_active', true).eq('active', true); if (error) throw error; try { localStorage.setItem(PK, JSON.stringify(data)); } catch {} return data; }
    catch { try { return JSON.parse(localStorage.getItem(PK) || '[]'); } catch { return []; } }
  }
  const presetsFor = (rows, productId) => { const m = new Map(); rows.filter(r => r.product_id === productId).forEach(r => m.set(r.preset_id, { id: r.preset_id, name: r.preset_name, is_default: r.is_default })); return [...m.values()].sort((a, b) => (b.is_default - a.is_default) || a.name.localeCompare(b.name)); };
  const METRIC = { temp: ['°C', 'Temperatura misurata'], duration: ['min', 'Minuti effettivi'], ph: ['pH', 'pH misurato'], speed: ['', 'Velocità usata'] };
  const processSteps = (rows, presetId, phase) => presetId ? rows.filter(r => r.preset_id === presetId && r.phase === phase).sort((a, b) => a.step_order - b.step_order).map(r => {
    const t = r.record_metric === 'temp' ? r.target_temp_c : r.record_metric === 'duration' ? r.duration_min : r.record_metric === 'ph' ? r.target_ph : r.record_metric === 'speed' ? r.speed : null;
    const lo = r.record_metric === 'temp' ? r.temp_min_c : r.record_metric === 'duration' ? r.duration_min_min : r.record_metric === 'ph' ? r.ph_min : null;
    const hi = r.record_metric === 'temp' ? r.temp_max_c : r.record_metric === 'duration' ? r.duration_max_min : r.record_metric === 'ph' ? r.ph_max : null;
    return { kind: 'process', step_id: r.step_id, step_order: r.step_order, name: r.name_it, machine: r.equipment_code ? `${r.equipment_name} · ${r.equipment_code}` : '', target_txt: r.target_txt || '', instruction_it: r.instruction_it, metric: r.record_metric, target: t == null ? null : Number(t), lo: lo == null ? null : Number(lo), hi: hi == null ? null : Number(hi),
      ccp: r.ccp_code || (/\(CCP\s*\d/.test(r.name_it || '') ? 'CCP' : null) };   // v0.80: a CCP step needs the measured value
  }) : [];
  // v0.80: is a CCP already recorded? (server when online, plus anything still in this tablet's queue)
  const resolveRefs = ops => (ops || []).map(op => !op.args ? op : { ...op, args: Object.fromEntries(Object.entries(op.args).map(([k, v]) => {
    const m = typeof v === 'string' && v.match(REF); return [k, m ? (((ops[Number(m[1])] || {}).row || {})[m[2]] ?? v) : v]; })) });
  const queuedOps = () => queue().flatMap(i => resolveRefs(i.ops));   // v0.97: «$1.batch_lot» read from the item's own rows
  async function ccpRecorded(code, lot, batchId, okOnly = false) {   // okOnly: only a passed check counts (pasteuriser start-of-day)
    const pres = await loadPresets(), stepIds = new Set(pres.filter(r => r.ccp_code === code).map(r => r.step_id));
    if (queuedOps().some(o => (o.rpc === 'log_ccp' && o.args && o.args.p_cp_code === code && (lot ? lotEq(o.args.p_batch_lot || '', lot) : true) && (!okOnly || Number(o.args.p_value) === 0))
                           || (lot && o.rpc === 'log_batch_step' && o.args && lotEq(o.args.p_batch_lot || '', lot) && stepIds.has(o.args.p_step_id)))) return true;
    let q = sb.from('haccp_log').select('id, haccp_control_points!inner(code)').eq('haccp_control_points.code', code).limit(1);
    if (batchId) q = q.eq('batch_id', batchId); else if (lot) return false; else q = q.gte('logged_at', romeDayStartIso());
    if (okOnly) q = q.eq('result', 'ok');
    const { data, error } = await live(q, 5000);
    if (error || !data) return null;                 // offline / unknown: ask, a second record does no harm
    return data.length > 0;
  }
  const mergeSteps = (doses, proc) => [...doses.map(d => ({ ...d, kind: 'dose' })), ...proc].sort((a, b) => a.step_order - b.step_order);
  async function doseSteps(productId, phase, base) {
    const all = await loadRecipes();
    return all.filter(r => r.finished_product_id === productId && r.phase === phase)
      .sort((a, b) => a.step_order - b.step_order)
      .map(r => {
        let q = r.qty_per_unit * (r.basis === 'per_kg_milk' ? base.milk : r.basis === 'per_kg_output' ? (base.out || 0) : 1);
        q = r.round_up ? Math.ceil(q) : Math.round(q * 1000) / 1000;
        return { ...r, qty: q };
      }).filter(r => r.qty > 0);
  }
  // show in a unit people can weigh: litres → ml, small kg → g
  const disp = s => s.unit === 'l' ? { f: 1000, u: 'ml' } : (s.unit === 'kg' && s.qty < 1) ? { f: 1000, u: 'g' } : { f: 1, u: s.unit === 'pz' ? 'pz' : s.unit };
  const fmtQty = (q, s) => { const d = disp(s); const v = q * d.f; return (d.u === 'pz' ? Math.ceil(v) : Math.round(v * 10) / 10).toLocaleString('it-IT') + ' ' + d.u; };
  // v0.98 (audit D-19): the lot of the pack in use (rennet, cultures, salt), kept per item for the day: the next vat shows it, and it
  // is changed when a new pack is opened. It goes with each dose, so a recalled pack can be traced to the lots made with it.
  const PACKK = 'perla_pack_lots_v1';
  const packLot = sku => { const x = readObj(PACKK)[sku]; return x && x.day === today() ? x.lot : ''; };
  const setPackLot = (sku, lot) => { const o = readObj(PACKK); if (lot) o[sku] = { lot, day: today() }; else delete o[sku]; writeObj(PACKK, o); };
  function runDosing(title, batchLot, steps, onDone, opts = {}) {
    let k = 0, readyAt = 0;
    const since = Math.min(Date.now(), (current && current.openedAt) || Date.now());   // v0.97: a rename found during the sequence applies to it
    const btns = ['d-ok', 'd-diff', 'd-alt-ok', 'd-skip', 'd-pause'].map($);
    // v0.97 (audit A-18): a new step ignores taps for 0,7 s, so a double tap on «✓ Fatto» cannot confirm the next ingredient too
    const ready = () => Date.now() >= readyAt;
    const unit = s => (METRIC[s.metric] || [''])[0];
    const render = () => {
      const s = steps[k]; readyAt = Date.now() + 700;
      $('d-title').textContent = title; $('d-prog').textContent = `Passo ${k + 1} di ${steps.length}`;
      $('d-bar').style.width = (k / steps.length * 100) + '%';
      $('d-name').textContent = s.name;
      if (s.kind === 'process') {
        $('d-mach').textContent = s.machine; $('d-qty').textContent = s.target_txt || '—'; $('d-src').textContent = '';
        $('d-diff').textContent = s.metric === 'none' ? '' : 'Scrivi il valore misurato'; $('d-diff').style.display = s.metric === 'none' ? 'none' : '';
        $('d-alt-l').textContent = (METRIC[s.metric] || ['', 'Valore'])[1]; $('d-alt-u').textContent = unit(s); $('d-alt-in').step = s.metric === 'ph' ? '0.01' : '0.5';
        // v0.97 (audit A-22): «Fatto» on a measured step no longer records the target as if it had been measured
        $('d-ok').textContent = s.metric === 'none' ? '✓ Fatto' : '✓ Fatto (non misurato)';
      } else {
        $('d-mach').textContent = ''; $('d-qty').textContent = fmtQty(s.qty, s); $('d-src').textContent = s.source === 'placeholder' ? 'ricetta provvisoria' : '';
        $('d-diff').textContent = 'Ho usato una quantità diversa'; $('d-diff').style.display = ''; $('d-alt-l').textContent = 'Quantità usata'; $('d-alt-u').textContent = disp(s).u; $('d-alt-in').step = '0.1'; $('d-ok').textContent = '✓ Fatto';
      }
      $('d-pack').style.display = s.kind === 'process' ? 'none' : ''; $('d-lot').value = s.kind === 'process' ? '' : packLot(s.sku);
      $('d-alt-echo').textContent = ''; $('d-alt-echo').classList.remove('bad');
      $('d-instr').textContent = s.instruction_it || '';
      $('d-skip').style.display = opts.skippable ? '' : 'none'; $('d-pause').style.display = '';   // v0.96 (audit A-03): every sequence can be left and resumed
      $('d-alt').style.display = 'none'; $('d-alt-in').value = ''; $('d-warn').textContent = ''; $('d-ok').style.display = '';
      if (s.kind === 'process' && s.ccp) {             // v0.80: CCP = write the value read on the thermometer; no one-tap "Fatto · target", no skip
        $('d-ok').style.display = 'none'; $('d-diff').style.display = 'none'; $('d-skip').style.display = 'none';
        $('d-alt').style.display = 'block'; $('d-alt-l').textContent = `${(METRIC[s.metric] || ['', 'Valore misurato'])[1]} (punto critico: scrivi il valore letto)`;
        $('d-instr').textContent = [s.instruction_it, `Obiettivo ${s.target ?? '—'}${unit(s) ? ' ' + unit(s) : ''}${s.lo != null || s.hi != null ? ` · intervallo ${s.lo ?? '…'}–${s.hi ?? '…'}` : ''}`].filter(Boolean).join(' · ');
      }
      btns.forEach(b => b.disabled = false); show('dose');
    };
    const lastLine = (s, q) => { const l = $('d-last'); if (!l) return;
      const t = new Date().toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Rome' });
      l.textContent = `✓ ${s.name}${q == null ? (s.kind === 'process' && s.metric !== 'none' ? ' (non misurato)' : '') : ' · ' + (s.kind === 'process' ? itN(q) + (unit(s) ? ' ' + unit(s) : '') : fmtQty(q, s))} registrato alle ${t}`; };
    const finish = async () => {                      // 'stay' = next sequence took over
      $('d-bar').style.width = '100%';
      try { const r = await onDone(); if (r !== 'stay') { show('home'); loadTasks(); } }
      catch (e) {                                      // v0.59: the close failed — stay here, ✓ tries the close again (it used to freeze on steps[k])
        console.error(e); if (!(e && e.silent) && Date.now() - lastToastAt > 500) toast((e && e.message) || 'Chiusura non salvata', 'err', 8000);
        $('d-prog').textContent = 'Passi registrati · chiusura non salvata'; $('d-ok').textContent = '↻ Riprova a chiudere'; $('d-ok').style.display = ''; btns.forEach(b => b.disabled = false); show('dose');
      }
    };
    const next = async (q, confirmed = false) => {
      const s = steps[k]; btns.forEach(b => b.disabled = true);
      try {
        if (s.kind === 'process') await save([{ rpc: 'log_batch_step', args: { p_batch_lot: batchLot, p_step_id: s.step_id, p_actual: q, p_staff_id: me().id, ...(opts.at ? { p_at: opts.at } : {}) } }], since);
        else {
          const lot = String($('d-lot').value || '').trim().toUpperCase(); setPackLot(s.sku, lot);   // v0.98 (D-19)
          await saveConfirm([{ rpc: 'record_batch_consumable', args: { p_batch_lot: batchLot, p_sku: s.sku, p_qty: q, p_qty_standard: s.qty, p_staff_id: me().id,
            ...(lot ? { p_lot: lot } : {}), ...(confirmed ? { p_confirm: true } : {}) } }], 0, since);
        }
      } finally { btns.forEach(b => b.disabled = false); }
      lastLine(s, q);
      // v0.97 (audit A-07): a CCP step out of its critical limit holds the lot — said now, in a card that waits for «Ho capito»
      if (s.kind === 'process' && s.ccp && ccpOut(s.ccp, q)) {
        const c = refStore()['cp_' + s.ccp] || {};
        await ask({ danger: true, title: `⚠ NON CONFORMITÀ · ${c.ccp_no || s.ccp}: lotto ${batchLot} BLOCCATO`, lines: ['Non si vende finché il responsabile HACCP non lo sblocca (riceve l\'avviso).', 'Cosa fare adesso: ' + (c.corrective_it || 'avvisa il responsabile HACCP.')], yes: 'Ho capito: continuo', no: null });
      }
      k++; if (k < steps.length) return render();
      return finish();
    };
    $('d-ok').onclick = () => { if (!ready()) return; if (k >= steps.length) return finish(); const s = steps[k]; if (s.kind === 'process' && s.ccp) { $('d-alt').style.display = 'block'; $('d-alt-in').focus(); return; }
      next(s.kind === 'process' ? (s.metric === 'none' ? s.target : null) : s.qty); };
    $('d-diff').onclick = () => { if (!ready()) return; $('d-alt').style.display = 'block'; $('d-alt-in').focus(); };
    $('d-pause').onclick = () => { toast('I passi confermati sono salvati: scansiona l\'etichetta del lotto (o tocca il lotto in Home) per continuare da qui', 'ok', 5000); show('home'); loadTasks(); };
    $('d-skip').onclick = () => { if (!ready()) return; if (steps[k] && steps[k].kind === 'process' && steps[k].ccp) return toast('Punto critico: non si salta, scrivi il valore misurato', 'err'); k++; if (k < steps.length) return render(); if (opts.onSkipAll && steps.every(st => st.kind === 'process')) { $('form').innerHTML = ''; return opts.onSkipAll(); } return finish(); };
    $('d-alt-ok').onclick = async () => {
      if (!ready()) return;
      if (k >= steps.length) return finish();
      const s = steps[k], pn = parseNum($('d-alt-in').value);   // v0.98 (audit A-13): read the Italian way, «1.200» refused
      if (pn.amb) return toast(`«${$('d-alt-in').value}»: scrivi il numero senza punto, oppure con la virgola per i decimali`, 'err', 6000);
      if (pn.bad || pn.v == null) return toast(s.kind === 'process' ? 'Scrivi il valore misurato' : 'Scrivi la quantità usata', 'err');
      const raw = pn.v;
      if (s.kind === 'process') {
        const v = raw, out = (s.lo != null && v < s.lo) || (s.hi != null && v > s.hi);
        try { if (s.ccp) plausCheck(s.ccp, v); if (s.metric === 'ph') phCheck(v); } catch (e) { return toast(e.message, 'err', 6000); }   // v0.95 (audit D-12)
        if (s.ccp && ccpOut(s.ccp, v)) { if (!(await confirmOut(s.ccp, v, batchLot))) return; }               // v0.97 (audit A-07): red, the lot is held
        else if (out && !(await ask({ title: 'Fuori dall\'intervallo', lines: [`Hai scritto ${itN(v)} ${unit(s)}: l'intervallo è ${s.lo ?? '…'}–${s.hi ?? '…'} ${unit(s)}.`, 'È giusto?'] }))) return;   // v0.97 (A-17)
        return next(v);
      }
      if (!(raw >= 0)) return toast('Scrivi la quantità usata (0 se non l\'hai messo)', 'err');
      const q = raw / disp(s).f, dev = Math.abs(q - s.qty) / s.qty;
      // v0.98 (audit D-19): more than 3 times or under a third of the recipe is a red question (the database asks for it too)
      const far = q > s.qty * 3 || q < s.qty / 3;
      if (dev > 0.2 && !(await ask({ danger: far, title: far ? 'Controlla la virgola' : 'Quantità diversa dalla ricetta',
        lines: [`${s.name}: hai scritto ${fmtQty(q, s)}, la ricetta dice ${fmtQty(s.qty, s)} (${Math.round(dev * 100)} % di differenza).`, 'È giusto?'] }))) return;
      next(s.unit === 'pz' ? Math.ceil(q) : Math.round(q * 1000) / 1000, dev > 0.2);
    };
    if ($('d-last')) $('d-last').textContent = '';
    $('d-alt-in').oninput = () => { const s = steps[k], pn = parseNum($('d-alt-in').value), e = $('d-alt-echo');
      e.textContent = pn.amb ? 'senza punto: 1200, oppure 1,2' : pn.bad ? 'solo il numero, con la virgola (es. 4,5)' : pn.v == null ? '' : `= ${itNum(pn.v)} ${s && s.kind === 'process' ? unit(s) : disp(s || {}).u || ''}`.trim();
      e.classList.toggle('bad', !!(pn.amb || pn.bad)); };
    render();
  }


  // ---------- Sicurezza alimentare (v0.28) ----------
  // online: run now and return the answer · offline (or network error): queue it (null). v1.10: always through save(), so the first
  // attempt already carries the save id: a reply lost after the database wrote the record can no longer write it a second time
  const rpcNow = async (fn, args) => {
    const out = await save([{ rpc: fn, args }]);
    return out && out.length ? (out[0] ?? null) : null;
  };
  function stepHaccpMenu() {
    $('form').innerHTML = ''; current = { code: 'HACCP:' };
    const items = [['🥛 Test antibiotici latte (CCP 1b)', 'CCP:CCP-MILK-ABX'], ['🌡 Temperatura latte in arrivo (CCP 1a)', 'CCP:CCP-MILK-TEMP'], ['🔥 Temperatura pasta filata (CCP 3)', 'CCP:CCP-STRETCH'], ['🍶 Ricotta: affioramento (CCP 4)', 'CCP:CCP-RIC'],
      ['♨ Pastorizzazione (CCP 2)', 'CCP:CCP-PAST'], ['🔧 Pastorizzatore: verifica di inizio giornata', 'CCP:PRP-PAST-VALVE'], ['🧫 Siero-innesto: acidità', 'CCP:PRP-INNESTO'],
      ['🧂 Salamoia: concentrazione', 'CCP:PRP-BRINE'], ['💧 Cloro acqua (settimanale)', 'CCP:PRP-WATER-CL'], ['🌡 Verifica termometro sonda', 'CAL:TERM-01'], ['🌡 Verifica termometro alta temperatura', 'CAL:TERM-02'],
      ['⚗ Calibrazione pH-metro', 'CAL:PH-01'], ['🐭 Giro infestanti', 'PEST:'], ['🧪 Campione prelevato per il laboratorio', 'SAMPLE:'], ['📝 Ricopia da foglio di carta', 'PAPER:']];
    items.forEach(([t, c]) => { const b = document.createElement('button'); b.type = 'button'; b.className = 'nitem'; b.textContent = t + ' ›'; b.onclick = () => handleCode(c); $('form').append(b); });
    openForm('Sicurezza alimentare', 'Scegli cosa registrare', async () => {}); $('btn-form-save').style.display = 'none';
  }
  // v0.96 (audit A-04): a milk check from the 🛡 menu or the paper copy belongs to ONE delivery (last 3 days): a positive test
  // rejects it and holds what was made from it (log_milk_check). Offline the deliveries kept on the tablet are listed.
  const MILK_CPS = new Set(['CCP-MILK-ABX', 'CCP-MILK-TEMP']);
  async function milkPicker() {
    const r = await live(sb.from('milk_intake').select('id, milk_lot, intake_date, intake_time, qty_kg, accepted, created_at').gte('intake_date', addDays(today(), -3)).order('created_at', { ascending: false }).limit(20));
    const rows = !r.error && r.data ? r.data : lotView().milk.filter(m => m.id && String(m.intake_date || today()) >= addDays(today(), -3));
    if (!rows.length) throw new Error('Nessuna consegna di latte negli ultimi 3 giorni: registra prima l\'arrivo del latte');
    const day = d => d === today() ? 'oggi' : d === addDays(today(), -1) ? 'ieri' : ddmm(d);
    field('mi', 'Quale consegna di latte?', 'select', { options: [['', '— scegli la consegna —'], ...rows.map(m => [m.id,
      `${m.milk_lot} · ${day(String(m.intake_date))}${m.intake_time ? ' ' + String(m.intake_time).slice(0, 5) : ''} · ${Number(m.qty_kg).toLocaleString('it-IT')} kg${m.accepted === false ? ' · già respinta' : ''}`])],
      limit: 'Il lotto è sull\'etichetta del tank. Un esito positivo respinge quel latte e blocca i lotti già fatti con esso.' });
    return rows;
  }
  function milkResult(r) {            // a persistent card, not a toast: what happened to the milk and to the lots made from it
    if (!r) return toast('Salvato offline: parte appena c\'è rete');
    if (r.result !== 'non_conformity') return toast(`${r.ccp} registrato ✓ · latte ${r.milk_lot}`);
    const held = r.lots_held || [];
    return showDone(`⚠ Latte ${r.milk_lot} RESPINTO`, [r.corrective_it || '', 'Isola il latte: non si usa in produzione.',
      held.length ? `Lotti già fatti con questo latte BLOCCATI: ${held.join(', ')}. Non vendere, avvisa il responsabile HACCP.` : 'Nessun lotto era stato fatto con questo latte.', 'Avvisa la Masseria.'].filter(Boolean), []);
  }
  // CCP:<code>[:<lot>] — one measurement against the HACCP plan; the server opens the NC and blocks the lot when out of limit
  async function stepCcp(cpCode, lot) {
    const { data: cp } = await cached('cp_' + cpCode, () => sb.from('haccp_control_points').select('*').eq('code', cpCode).eq('active', true).maybeSingle());
    if (!cp) throw new Error('Punto di controllo sconosciuto: ' + cpCode);
    const needsLot = ['CCP-STRETCH', 'CCP-RIC', 'CCP-PAST'].includes(cp.code);
    if (needsLot && !lot) {
      const { data: bs } = await cached('batches_today_' + today(), () => sb.from('production_batches').select('batch_lot, input_kind').eq('batch_date', today()).order('batch_lot'));
      const mine = (bs || []).filter(b => cp.code === 'CCP-RIC' ? b.input_kind === 'whey' : b.input_kind !== 'whey');
      field('lot', 'Lotto', 'select', { options: [['', '— scegli —'], ...mine.map(b => [b.batch_lot, b.batch_lot])] });
    }
    const lim = [cp.min_value != null ? `≥ ${Number(cp.min_value)}` : null, cp.max_value != null ? `≤ ${Number(cp.max_value)}` : null].filter(Boolean).join(' e ');
    if (MILK_CPS.has(cp.code)) await milkPicker();
    if (cp.code === 'CCP-MILK-ABX') {
      field('v', 'Esito test rapido', 'select', { options: [['', '— scegli —'], ['0', 'Negativo'], ['1', 'POSITIVO']], limit: 'Positivo = latte non accettato' });
      field('action', 'Note / azione (se positivo)', 'text', { required: false });
    } else if (cp.unit === 'esito') {     // v0.57: pass/fail checks (verifica pastorizzatore)
      field('v', 'Esito della verifica', 'select', { options: [['', '— scegli —'], ['0', 'Ok'], ['1', 'NON ok']], limit: cp.monitoring_it || 'NON ok = non pastorizzare, chiama il responsabile' });
      field('action', 'Note / cosa hai fatto (se NON ok)', 'text', { required: false });
    } else {
      const v = field('v', `${cp.name} (${cp.unit || ''})`, 'number', { ...cpRange(cp.code), limit: lim ? `${cp.ccp_no || ''} limite ${lim} ${cp.unit || ''}`.trim() : 'Intervallo da fissare con il casaro: scrivi il valore letto' });
      if (!cp.is_ccp && cp.min_value == null && cp.max_value == null) field('action', cp.code === 'PRP-BRINE' ? 'Note: rinnovata, filtrata, rabbocco, aspetto' : 'Note (es. pH, innesto nuovo)', 'text', { required: false });
      let note = null;
      v.oninput = () => { const x = v.validity.customError ? null : numOf(v); const bad = x != null && ((cp.min_value != null && x < cp.min_value) || (cp.max_value != null && x > cp.max_value));
        if (bad && !note) note = field('action', 'Fuori limite: cosa hai fatto?', 'text'); noteShow(note, bad); v.style.borderColor = bad ? 'var(--warn)' : ''; };
    }
    openForm(`${cp.ccp_no || ''} ${cp.name}`.trim(), lot ? 'lotto ' + lot : (cp.monitoring_it || ''), async () => {
      const value = (cp.code === 'CCP-MILK-ABX' || cp.unit === 'esito') ? (val('v') === '' ? null : Number(val('v'))) : val('v');
      if (value == null) { toast('Inserisci il valore', 'err'); throw new Error('valore'); }
      const theLot = lot || val('lot') || null;
      if (needsLot && !theLot) { toast('Scegli il lotto', 'err'); throw new Error('lotto'); }
      plausCheck(cp.code, value);
      // v0.97 (audit A-29): after a «NON ok» earlier today, an «Ok» on the pasteuriser says what was done
      if (cp.code === 'PRP-PAST-VALVE' && value === 0 && (await valveKoToday()) && String(val('action') || '').trim().length < 3)
        throw new Error('Oggi il pastorizzatore era NON ok: scrivi nelle note cosa è stato fatto (riparato da …) prima di dire «Ok»');
      if (!(await confirmOut(cp.code, value, theLot))) throw stop();           // v0.97 (audit A-07): red «È giusto?» before an NC
      if (MILK_CPS.has(cp.code)) {
        if (!val('mi')) { toast('Scegli la consegna di latte', 'err'); throw new Error('consegna'); }
        const rm = await rpcNow('log_milk_check', { p_milk_intake_id: val('mi'), p_cp_code: cp.code, p_value: value, p_staff_id: me().id, p_action: val('action'), p_source: 'tablet', p_equipment_code: cp.code === 'CCP-MILK-TEMP' ? 'TERM-01' : null });
        return milkResult(rm);
      }
      const r = await rpcNow('log_ccp', { p_cp_code: cp.code, p_value: value, p_staff_id: me().id, p_batch_lot: theLot, p_action: val('action'), p_source: 'tablet', p_equipment_code: needsLot ? 'TERM-02' : null });
      await closeTask({ control_point_id: cp.id });   // v0.57: any task tied to this control point (cloro, valvola, salamoia)
      if ((r && r.result === 'non_conformity') || (!r && ccpOut(cp.code, value))) return ncCard(cp.code, r, theLot);
      if (!r) return toast('Salvato offline');
      if (r.result === 'warning') toast('Registrato · ALLERTA vicino al limite', 'err', 6000);
      else toast(`${r.ccp} registrato ✓`);
    });
  }
  // v0.77: PAPER:[<control point>] — a check written on the printed sheet (tablet or Wi-Fi down), typed in later with the time on the sheet
  const PAPER_CPS = [['🥛 Test antibiotici latte (MOD-01)', 'CCP-MILK-ABX'], ['🌡 Temperatura latte in arrivo (MOD-01)', 'CCP-MILK-TEMP'], ['🔧 Pastorizzatore: verifica di inizio giornata (MOD-02)', 'PRP-PAST-VALVE'], ['♨ Pastorizzazione (MOD-02)', 'CCP-PAST'],
    ['🧫 Siero-innesto (MOD-03)', 'PRP-INNESTO'], ['🔥 Temperatura pasta filata (MOD-03)', 'CCP-STRETCH'], ['🍶 Ricotta: affioramento (MOD-04)', 'CCP-RIC'],
    ['❄ Cella 1 (MOD-05)', 'CCP-COLD-1'], ['❄ Cella 2 (MOD-05)', 'CCP-COLD-2'], ['🧽 Sanificazione fine turno (MOD-06)', 'PRP-CLEAN'], ['🧂 Salamoia (MOD-17)', 'PRP-BRINE']];
  function stepPaperMenu() {
    $('form').innerHTML = ''; current = { code: 'PAPER:' };
    const n = document.createElement('div'); n.className = 'limit'; n.textContent = 'Una riga del foglio alla volta: scegli il controllo, poi scrivi data, ora e valore come sul foglio.'; $('form').append(n);
    PAPER_CPS.forEach(([t, c]) => { const b = document.createElement('button'); b.type = 'button'; b.className = 'nitem'; b.textContent = t + ' ›'; b.onclick = () => handleCode('PAPER:' + c); $('form').append(b); });
    openForm('Ricopia da foglio di carta', 'Registrazioni fatte sul foglio quando il tablet o la rete non c\'erano', async () => {}); $('btn-form-save').style.display = 'none';
  }
  const romeIso = (ymd, hm) => {   // the sheet's date + time in Agropoli → ISO with the right offset for that day
    const probe = new Date(`${ymd}T${hm}:00Z`);
    const off = (new Intl.DateTimeFormat('en-US', { timeZone: 'Europe/Rome', timeZoneName: 'longOffset' }).formatToParts(probe).find(x => x.type === 'timeZoneName') || {}).value || 'GMT+01:00';
    const m = off.match(/GMT([+-]\d{2}):?(\d{2})?/); return `${ymd}T${hm}:00${m ? m[1] + ':' + (m[2] || '00') : '+01:00'}`;
  };
  // v0.97 (audit A-11): a reading made on the tablet and refused by the database is redone here with its own time, but stays a tablet
  // reading (no «Ricopiata dal foglio» note), with a note that it was entered again
  const redoTab = () => !!(current && current.redo && current.redo.src && current.redo.src !== 'paper');
  const redoSrc = () => redoTab() ? 'tablet' : 'paper';
  const redoNote = a => redoTab() ? [a, `Registrata sul tablet e rifiutata dal database: inserita di nuovo da ${me().full_name}`].filter(Boolean).join(' · ') : a;
  async function stepPaper(cpCode, pDay, pLot) {
    const { data: cp } = await cached('cp_' + cpCode, () => sb.from('haccp_control_points').select('*').eq('code', cpCode).eq('active', true).maybeSingle());
    if (!cp) throw new Error('Punto di controllo sconosciuto: ' + cpCode);
    const needsLot = ['CCP-STRETCH', 'CCP-RIC', 'CCP-PAST'].includes(cp.code);
    const d = field('pday', 'Data scritta sul foglio', 'date'); d.max = today(); d.min = addDays(today(), -7);
    d.value = pDay && /^\d{4}-\d{2}-\d{2}$/.test(pDay) && pDay <= today() && pDay >= addDays(today(), -7) ? pDay : today();
    field('ptime', 'Ora scritta sul foglio', 'time');
    // v0.96 (audit A-19): who signed the sheet is chosen from the list, never prefilled with whoever is copying it
    field('pwho', 'Chi l\'ha scritto (firma sul foglio)', 'select', { options: [['', '— scegli chi ha firmato —'], ...opList().map(p => [p.full_name, p.full_name]), ['firma non leggibile', 'Non si legge / non firmato']] });
    if (needsLot) { const lf = field('lot', 'Lotto (come sul foglio, es. L20261012-A)', 'text'); if (pLot) lf.value = pLot; }
    if (MILK_CPS.has(cp.code)) await milkPicker();
    if (cp.code === 'CCP-MILK-ABX') field('v', 'Esito test rapido', 'select', { options: [['', '— scegli —'], ['0', 'Negativo'], ['1', 'POSITIVO']] });
    else if (cp.unit === 'esito') field('v', 'Esito della verifica', 'select', { options: [['', '— scegli —'], ['0', 'Ok'], ['1', 'NON ok']] });
    else if (cp.code === 'PRP-CLEAN') field('v', 'Sanificazione', 'select', { options: [['0', 'Fatta']] });
    else {
      const lim = [cp.min_value != null ? `≥ ${Number(cp.min_value)}` : null, cp.max_value != null ? `≤ ${Number(cp.max_value)}` : null].filter(Boolean).join(' e ');
      field('v', `${cp.name} (${cp.unit || ''})`, 'number', { ...cpRange(cp.code), limit: lim ? `limite ${lim} ${cp.unit || ''}`.trim() : '' });
    }
    field('action', 'Note / azione scritta sul foglio (se fuori limite)', 'text', { required: false });
    openForm(`📝 ${cp.ccp_no || ''} ${cp.name}`.trim(), 'Ricopia dal foglio di carta', async () => {
      const day = val('pday'), hm = val('ptime'), value = val('v') === '' || val('v') == null ? null : Number(val('v'));
      if (!day || !hm) { toast('Scrivi data e ora come sul foglio', 'err'); throw new Error('data'); }
      if (day > today() || day < addDays(today(), -7)) { toast('Si ricopiano solo fogli degli ultimi 7 giorni', 'err'); throw new Error('data'); }
      if (value == null || Number.isNaN(value)) { toast('Inserisci il valore', 'err'); throw new Error('valore'); }
      const lot = needsLot ? (val('lot') || '').trim().toUpperCase() : null;
      if (needsLot && !lot) { toast('Scrivi il lotto', 'err'); throw new Error('lotto'); }
      plausCheck(cp.code, value);
      if (!(await confirmOut(cp.code, value, lot))) throw stop();              // v0.97 (audit A-07)
      if (MILK_CPS.has(cp.code)) {
        if (!val('mi')) { toast('Scegli la consegna di latte', 'err'); throw new Error('consegna'); }
        const rm = await rpcNow('log_milk_check', { p_milk_intake_id: val('mi'), p_cp_code: cp.code, p_value: value, p_logged_at: romeIso(day, hm), p_staff_id: me().id, p_action: redoNote(val('action')),
                                                   p_source: redoSrc(), p_equipment_code: cp.code === 'CCP-MILK-TEMP' ? 'TERM-01' : null, p_written_by: val('pwho') });
        if (rm && rm.result === 'non_conformity') return milkResult(rm);
        toast(rm ? `Ricopiato ✓ ${fmtDay(day)} ${hm} · latte ${rm.milk_lot}` : 'Salvato offline: parte appena c\'è rete');
        stepPaperMenu(); return 'stay';
      }
      const r = await rpcNow('log_ccp', { p_cp_code: cp.code, p_value: value, p_logged_at: romeIso(day, hm), p_staff_id: me().id, p_batch_lot: lot, p_action: redoNote(val('action')),
                                          p_source: redoSrc(), p_equipment_code: needsLot ? 'TERM-02' : null, p_written_by: val('pwho') });
      // v0.97 (audit A-05): with the sheet's time, so a morning line closes the morning task and not the evening one
      try { await save([{ rpc: 'close_open_task', args: { p_day: day, p_code: null, p_equipment_id: null, p_control_point_id: cp.id, p_staff_id: me().id, p_scan_event_id: null, p_at: romeIso(day, hm) } }]); } catch (e) { console.warn('closeTask', e); }
      if ((r && r.result === 'non_conformity') || (!r && ccpOut(cp.code, value))) return ncCard(cp.code, r, lot, [`Riga del foglio ${fmtDay(day)} ${hm} ricopiata.`]);
      if (!r) toast('Salvato offline: parte appena c\'è rete');
      else toast(`Ricopiato ✓ ${fmtDay(day)} ${hm}`);
      stepPaperMenu(); return 'stay';   // next line of the same sheet
    });
  }
  // CAL:<code> or EQ:<thermometer|pH|scale> — internal verification against a reference
  async function stepCalibration(eq) {
    let method, pts;
    const isPh = eq.code.startsWith('PH-'), isScale = eq.kind === 'scale', isHot = eq.code === 'TERM-02', isRoom = eq.kind === 'cold_room';
    if (eq.reference_instrument) { toast('Il termometro di riferimento si tara solo in laboratorio: registra il certificato nella console HACCP', 'err'); return show('home'); }
    if (isPh) { method = 'tamponi_ph'; field('r4', 'Lettura nel tampone pH 4,01', 'number', { min: 0, max: 14 }); field('r7', 'Lettura nel tampone pH 7,00', 'number', { min: 0, max: 14 }); field('slope', 'Pendenza % (se lo strumento la mostra)', 'number', { required: false, min: 50, max: 150, unit: '%', limit: 'Tolleranza ±0,05 pH · pendenza 95–105 %' }); }
    else if (isScale) { method = 'pesi_campione'; field('ref', 'Peso campione (kg)', 'number', { min: 0, max: 1000, unit: 'kg' }); field('read', 'Lettura bilancia (kg)', 'number', { min: 0, max: 1000, unit: 'kg' }); }
    else if (isRoom) { method = 'confronto_display'; field('ref', 'Termometro sonda TERM-01 nella cella (°C)', 'number', { min: -30, max: 50, unit: '°C' }); field('read', 'Display della cella (°C)', 'number', { min: -30, max: 50, unit: '°C', limit: 'Tolleranza ±1 °C' }); }
    else {
      method = 'confronto_riferimento';
      field('p1', isHot ? 'Acqua in ebollizione: lettura (riferimento 100 °C)' : 'Ghiaccio fondente: lettura (riferimento 0 °C)', 'number', { min: -20, max: 120, unit: '°C' });
      field('ref', `Termometro di riferimento TERM-REF a ~${isHot ? 90 : 60} °C`, 'number', { required: false, min: -20, max: 150, unit: '°C' });
      field('read', `${eq.code} nello stesso punto`, 'number', { required: false, min: -20, max: 150, unit: '°C', limit: `Tolleranza ±${eq.tolerance ?? 0.5} °C` });
    }
    openForm('Verifica ' + eq.name, eq.code, async () => {
      if (isPh) pts = [{ ref: 4.01, reading: val('r4') }, { ref: 7.00, reading: val('r7') }, ...(val('slope') != null ? [{ slope: val('slope') }] : [])];
      else if (isScale || isRoom) pts = [{ ref: val('ref'), reading: val('read') }];
      else pts = [{ ref: isHot ? 100 : 0, reading: val('p1') }, ...(val('ref') != null && val('read') != null ? [{ ref: val('ref'), reading: val('read') }] : [])];
      const r = await rpcNow('record_calibration_check', { p_code: eq.code, p_kind: 'verifica_interna', p_method: method, p_points: pts, p_staff_id: me().id });
      // v1.04 (audit D-31): the display check of a cold room is not its temperature reading: no task of the room is ticked
      if (!isRoom) await closeTask({ equipment_id: eq.id });
      if (!r) return toast('Salvato offline');
      if (r.result === 'ko') toast(`${eq.code} FUORI TOLLERANZA (scarto ${r.max_deviation}): non usarlo, è fuori servizio. ${r.records_to_review} registrazioni da rivalutare.`, 'err');
      else toast(`${eq.code} ok · scarto ${r.max_deviation ?? 0} ✓`);
    });
  }
  // PEST: — weekly internal round of the stations
  async function stepPest() {
    const { data: st } = await cached('pest_stations', () => sb.from('pest_stations').select('code, kind, location_it, inside').eq('active', true).order('inside', { ascending: false }).order('code'));
    if (!st || !st.length) throw new Error('Nessuna postazione registrata');
    const opts = [['ok', 'OK'], ['consumo', 'Esca consumata'], ['cattura', 'Cattura'], ['insetti', 'Insetti'], ['tracce', 'Tracce / escrementi'], ['danneggiata', 'Danneggiata'], ['mancante', 'Mancante']];
    // v0.97 (audit A-09): nothing preselected — each station is looked at; «Tutte OK» says how many it sets
    const all = document.createElement('button'); all.type = 'button'; all.className = 'btn secondary'; all.textContent = `✓ Tutte OK (${st.length} postazioni)`;
    all.onclick = () => st.forEach((_, k) => { $('st' + k).value = 'ok'; });
    $('form').append(all);
    st.forEach((x, k) => field('st' + k, `${x.code} · ${x.location_it}`, 'select', { options: [['', '— scegli —'], ...opts] }));
    field('note', 'Note / azioni', 'text', { required: false });
    openForm('Giro infestanti', 'Una postazione per riga · dentro solo trappole senza veleno', async () => {
      const miss = st.filter((_, k) => !val('st' + k)); if (miss.length) throw new Error('Scegli lo stato di: ' + miss.map(x => x.code).join(', '));
      const findings = st.map((x, k) => ({ station: x.code, status: val('st' + k) }));
      const r = await rpcNow('record_pest_inspection', { p_by: 'interno', p_findings: findings, p_staff_id: me().id, p_actions: val('note') });
      if (!r) return toast('Salvato offline');
      toast(r.activity_inside ? 'Infestanti ALL\'INTERNO: non conformità aperta, chiama la ditta' : r.activity_found ? 'Attività all\'esterno: segnalata' : 'Giro infestanti registrato ✓', r.activity_found ? 'err' : 'ok');
    });
  }
  // SAMPLE:[test code] — a sample taken for the lab; the code goes on the container
  async function stepSample(testCode) {
    const { data: tests } = await sb.from('v_lab_plan_status').select('code, analyte_it, matrix, next_due').order('sort');
    field('test', 'Analisi', 'select', { options: (tests || []).map(t => [t.code, `${t.code} · ${t.analyte_it}${t.next_due ? ' · entro ' + t.next_due.slice(8, 10) + '/' + t.next_due.slice(5, 7) : ''}`]) });
    if (testCode) $('test').value = testCode;
    field('lot', 'Lotto (prodotto) — facoltativo', 'text', { required: false }); field('point', 'Punto di prelievo (se diverso dal piano)', 'text', { required: false });
    openForm('Campione per il laboratorio', 'Poi scrivi il codice sul contenitore', async () => {
      const testv = val('test'), lotv = val('lot') || '';
      const r = await rpcNow('record_sample_taken', { p_test_code: testv, p_lot: lotv || null, p_point: val('point') || null, p_staff_id: me().id });
      if (!r || !r.sample_code) return toast('Salvato offline: scrivi a mano analisi, lotto e data sul contenitore', 'ok');
      toast(`Campione ${r.sample_code} registrato ✓`);
      return showDone(`Campione ${r.sample_code}`, [`Analisi ${testv}${lotv ? ' · lotto ' + lotv : ''}`, 'Stampa l\'etichetta e attaccala al contenitore (oppure scrivi il codice a mano).'],
        [['🖨 Stampa etichetta campione', 'labels.html?' + new URLSearchParams({ code: r.sample_code, name: 'Campione ' + testv, sub: (lotv ? 'lotto ' + lotv + ' · ' : '') + ddmm(today()), n: '2' })]]);
    });
  }
  window.__haccp = () => handleCode('HACCP:');

  let _rawId; async function rawMilkId() {
    if (!_rawId) { const { data } = await live(sb.from('products').select('id').eq('sku', 'RAW-MILK').single());
      _rawId = data ? data.id : (lotView().products.find(p => p.sku === 'RAW-MILK') || {}).id; }
    if (!_rawId) throw new Error('Prodotto latte crudo non trovato (senza rete e prodotti non ancora salvati sul tablet)');
    return _rawId; }

  if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});
  init();
})();
