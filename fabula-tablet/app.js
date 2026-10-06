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

  // ---------- UI helpers ----------
  const show = v => { document.querySelectorAll('.view').forEach(e => e.classList.toggle('active', e.id === 'v-' + v)); };
  let lastToastAt = 0;
  const toast = (msg, cls = 'ok') => { lastToastAt = Date.now(); const t = $('toast'); t.textContent = msg; t.className = 'toast ' + cls; t.style.display = 'block'; setTimeout(() => t.style.display = 'none', 2600); };
  // v0.59: dates are Agropoli dates (Europe/Rome), not UTC: between 00:00 and 02:00 the UTC date was still yesterday
  const ROME_DAY = new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Rome', year: 'numeric', month: '2-digit', day: '2-digit' });
  const today = () => ROME_DAY.format(new Date());
  const addDays = (ymd, n) => { const d = new Date(ymd + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() + Number(n || 0)); return d.toISOString().slice(0, 10); };
  // start of today in Agropoli as an ISO timestamp (for timestamptz comparisons)
  const romeDayStartIso = () => { const off = (new Intl.DateTimeFormat('en-US', { timeZone: 'Europe/Rome', timeZoneName: 'longOffset' }).formatToParts(new Date()).find(x => x.type === 'timeZoneName') || {}).value || 'GMT+01:00';
    const m = off.match(/GMT([+-]\d{2}):?(\d{2})?/); return `${today()}T00:00:00${m ? m[1] + ':' + (m[2] || '00') : '+01:00'}`; };
  const likeSafe = v => String(v).replace(/[\\%_]/g, c => '\\' + c);   // exact, case-insensitive match with ilike
  const field = (id, label, type = 'number', extra = {}) => {
    const l = document.createElement('label'); l.htmlFor = id; l.textContent = label;
    const i = document.createElement(type === 'select' ? 'select' : 'input');
    i.id = id; i.name = id;
    if (type !== 'select') { i.type = type; if (type === 'number') { i.step = 'any'; i.inputMode = 'decimal'; } }   // v0.59: 'any' — a step made reportValidity() refuse real values (96.64 kg)
    if (extra.options) extra.options.forEach(([v, t]) => { const o = document.createElement('option'); o.value = v; o.textContent = t; i.appendChild(o); });
    if (extra.required !== false) i.required = true;
    $('form').append(l, i);
    if (extra.limit) { const d = document.createElement('div'); d.className = 'limit'; d.textContent = extra.limit; $('form').append(d); }
    return i;
  };
  const checklist = items => items.forEach((t, k) => { const d = document.createElement('div'); d.className = 'check'; d.innerHTML = `<input type="checkbox" id="c${k}" name="c${k}"><label for="c${k}" style="margin:0;text-transform:none;color:inherit;font-weight:400">${t}</label>`; $('form').append(d); });
  const val = id => { const e = $(id); return e ? (e.type === 'number' ? (e.value === '' ? null : Number(e.value)) : e.value) : null; };

  // ---------- Offline queue (v0.39: idempotent, refused items set aside, auth errors retried) ----------
  const Q = 'fabula_queue', QF = 'fabula_failed';
  const UUID_TABLES = new Set(['scan_events', 'milk_intake', 'labels', 'production_batches', 'stock_moves', 'haccp_log', 'meter_readings', 'effluent_log', 'shipments', 'shipment_lines', 'waste_log', 'sales_orders', 'batch_step_logs']);
  const uuid = () => (crypto.randomUUID ? crypto.randomUUID() : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => { const r = crypto.getRandomValues(new Uint8Array(1))[0] & 15; return (c === 'x' ? r : (r & 3) | 8).toString(16); }));
  const readList = k => { try { return JSON.parse(localStorage.getItem(k) || '[]'); } catch { return []; } };
  const queue = () => readList(Q), failedList = () => readList(QF);
  const showPending = () => { const q = queue().length, f = failedList().length;
    $('pending').textContent = [q ? `${q} registrazioni in attesa di rete` : '', f ? `${f} rifiutate dal database (tocca qui)` : ''].filter(Boolean).join(' · '); };
  // (v0.74 check-in further down reports both numbers to the office)
  const setQueue = q => { try { localStorage.setItem(Q, JSON.stringify(q)); } catch {} showPending(); };
  const setFailed = f => { try { localStorage.setItem(QF, JSON.stringify(f)); } catch {} showPending(); };
  // retryable = network down, timeout, or an expired login; anything else is the database refusing the data
  const retryable = e => !e || !e.code || /fetch|network|timeout|jwt|token/i.test(e.message || '') || e.code === 'PGRST301' || e.status === 401;
  // every insert carries its own id, generated once on the tablet: a re-send after a lost reply hits the same row instead of duplicating it
  const stamp = ops => ops.forEach(op => { if (op.table && !op.update && op.row && !op.row.id && UUID_TABLES.has(op.table)) op.row.id = uuid(); });
  async function save(ops) {                 // ops: [{table, row}] executed in order; later rows may reference earlier via $0.id
    stamp(ops);
    const qid = uuid();                       // v0.62: one id per save — the server writes it once, however many times it is sent
    const st = { done: 0, out: [] };          // v0.59: progress travels with the queued item, so a re-send skips the steps already saved
    const enqueue = () => setQueue([...queue(), { qid, at: Date.now(), ops, st }]);
    if (!navigator.onLine) { enqueue(); toast('Salvato offline, invio appena c\'è rete'); return true; }
    if (queue().length) await flush();        // v0.62: records saved offline go first (a batch start needs its milk intake on the server)
    if (queue().length) { enqueue(); toast('In coda dietro le registrazioni offline: partono insieme', 'err'); setTimeout(flush, 1000); return true; }
    try { await run(ops, st, qid); lotsChanged(); return true; }
    catch (e) {
      console.error(e);
      if (!retryable(e)) { toast(st.done ? `Salvato solo in parte (${st.done} di ${ops.length} passi): ${e.message}` : e.message, 'err'); throw e; }   // refused by the database: show it, don't queue it
      enqueue(); toast('Rete assente: messo in coda', 'err'); return true;
    }
  }
  const REF = /^\$(\d+)\.(\w+)$/;          // "$1.id" = a field of the row saved by step 1 (v0.59: only this exact shape; "$5" in a note stays text)
  // v0.62: a save with several steps runs on the server in ONE transaction (fabula.save_ops): all steps are written or none,
  // and the queue id makes a re-send after a lost reply return the first result instead of writing again.
  // Items half-sent by an older version (st.done > 0) finish step by step as before.
  // single RPCs that write (dosing, steps, CCP, receipts) go the same way, so a lost reply never records them twice
  const ONCE_RPCS = new Set(['log_ccp', 'receive_purchase_order', 'record_receipt_check', 'close_open_task', 'start_byproduct_batch', 'log_batch_step', 'record_batch_consumable']);
  let atomicOk = true;
  async function run(ops, st = { done: 0, out: [] }, qid = null) {
    if ((ops.length > 1 || (qid && ops[0] && ONCE_RPCS.has(ops[0].rpc))) && !(st.done > 0) && atomicOk) {
      const { data, error } = await sb.rpc('save_ops', { p_ops: ops, p_qid: qid });
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
    const q = queue(); if (!q.length || !navigator.onLine) return;
    if (!staff || !(await PERM.session(sb))) return;            // v0.59: logged out → keep the queue for the next login (it used to fail every item)
    q.forEach(i => { if (!i.qid) i.qid = uuid(); }); setQueue(q);   // v0.56: every item gets an id (same tick as the read, so nothing is lost)
    flushing = true;
    try {
      try { await sb.auth.getSession(); } catch {}           // refreshes an expired login before re-sending
      const left = [], failed = [];
      for (let i = 0; i < q.length; i++) {
        const item = q[i];
        stamp(item.ops);                                      // items queued by older versions get their ids now
        try { await run(item.ops, item.st || (item.st = { done: 0, out: [] }), item.qid); }
        catch (e) {
          console.error(e);
          // v0.62: strictly in order — when the network drops, stop here (a batch's steps must never arrive before the batch)
          if (retryable(e)) { left.push(...q.slice(i)); break; }
          failed.push({ ...item, error: e.message, code: e.code, failed_at: Date.now() });
        }
      }
      const seen = new Set(q.map(i => i.qid));                  // v0.56: keep what save() queued while this flush was sending
      const added = queue().filter(i => !seen.has(i.qid));
      setQueue([...left, ...added]);
      if (added.length && !left.length) setTimeout(flush, 500);  // v0.62: send those now instead of at the next minute
      if (failed.length) { setFailed([...failedList(), ...failed]); toast(`${failed.length} registrazioni rifiutate dal database: tocca la riga in basso`, 'err'); }
      const sent = q.length - left.length - failed.length;
      if (sent > 0) { toast(`Inviate ${sent} registrazioni`); loadTasks(); warmLots(); }
    } finally { flushing = false; setTimeout(checkin, 300); }
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
  let failedTap = 0;
  $('pending').addEventListener('click', () => {
    const f = failedList(); if (!f.length) return;
    if (Date.now() - failedTap < 5000) { setFailed([]); toast('Registrazioni rifiutate eliminate: rifalle a mano se servono'); failedTap = 0; return; }
    failedTap = Date.now();
    const first = f[0]; const what = (first.ops.find(o => o.table) || first.ops[0] || {}).table || (first.ops[0] || {}).rpc || '?';
    const rep = reported(), sent = f.filter(x => rep.has(x.qid)).length;
    toast(`${f.length} rifiutate · prima: ${what} — ${first.error}. ${sent === f.length ? 'Già segnalate all\'ufficio. ' : 'Verranno segnalate all\'ufficio appena c\'è rete. '}Tocca di nuovo entro 5 s per toglierle da qui.`, 'err');
    if (sent < f.length) checkin();
  });

  // ---------- Auth ----------
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
    $('who').textContent = staff.full_name;
    show('home'); loadTasks(); setQueue(queue()); flush(); if (!PERM.offline) { warmRefs(); warmLots(); } setTimeout(checkin, 1500);
    if (PERM.offline) toast('Offline: profilo salvato su questo tablet. Le registrazioni vanno in coda e partono al ritorno della rete.');
  }
  $('btn-login').onclick = async () => {
    const { error } = await sb.auth.signInWithPassword({ email: $('email').value, password: $('pw').value });
    if (error) return toast('Accesso negato: ' + error.message, 'err'); init();
  };
  PERM.forgot(sb, toast);
  $('btn-logout').onclick = async () => {
    const n = queue().length;
    staff = null; await sb.auth.signOut(); show('login');
    if (n) toast(`${n} registrazioni restano in coda su questo tablet: partono al prossimo accesso`, 'err');
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
  async function loadPlan() {
    const wrap = $('plan-wrap'), box = $('plan'), sum = $('plan-sum'); if (!wrap) return;
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
    const { data, error } = await sb.from('v_active_notices').select('*');
    if (error || !data || !data.length) { wrap.style.display = 'none'; return; }
    wrap.style.display = ''; wrap.innerHTML = '';
    data.forEach(n => {
      const d = document.createElement('div'); d.className = 'notice ' + n.severity;
      d.innerHTML = `<div class="nt">${esc(n.title_it)}</div>`;
      (n.items || []).forEach(it => {                 // v0.59: items with no scan (lot guard, heartbeat, watchdog) are text, not a dead button
        const label = it.label_it || it.label || it.title_it || it.scan || '';
        if (!label) return;
        if (!it.scan) { const t = document.createElement('div'); t.className = 'code'; t.textContent = label; d.append(t); return; }
        const b = document.createElement('button'); b.className = 'nitem'; b.textContent = label + ' ›'; b.onclick = () => handleCode(it.scan); d.append(b); });
      wrap.append(d);
    });
  }
  async function loadShifts() {            // who is clocked in right now
    const el = $('onshift'); if (!el) return;
    let { data, error } = await sb.rpc('floor_open_shifts');   // v0.59: works for floor profiles too (v_open_shifts needs personale ≥ 1)
    if (error) ({ data } = await sb.from('v_open_shifts').select('full_name, hours_so_far'));
    el.textContent = data && data.length ? 'In turno: ' + data.map(r => `${r.full_name} (${Number(r.hours_so_far).toLocaleString('it-IT')} h)`).join(', ') : 'Nessuno in turno · passa il badge per iniziare';
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
      const closes = queue().flatMap(i => (i.ops || []).filter(o => o.rpc === 'close_open_task').map(o => o.args || {}));
      const left = [...c.data].sort((a, b) => String(a.due_at).localeCompare(String(b.due_at)));
      closes.forEach(a => { const k = left.findIndex(t => (a.p_code && t.code === a.p_code) || (a.p_control_point_id && t.control_point_id === a.p_control_point_id) || (a.p_equipment_id && t.equipment_id === a.p_equipment_id)); if (k >= 0) left.splice(k, 1); });
      data = left;
      const n = document.createElement('div'); n.className = 'code'; n.textContent = `Senza rete: elenco delle ${hhmm(c.at)} · le attività fatte ora si chiudono al ritorno della rete`; box.append(n);
    }
    if (!data.length) { box.append('Tutto fatto ✓'); return; }
    data.forEach(t => {
      const d = document.createElement('div'); d.className = 'task ' + t.status;
      d.innerHTML = `<div><div>${esc(t.title_it)}</div><div class="code">${esc(t.equipment_code || t.code)}</div></div><time>${new Date(t.due_at).toTimeString().slice(0, 5)}</time>`;
      d.onclick = () => t.equipment_code ? handleCode('EQ:' + t.equipment_code) : t.code === 'T-COUNT' ? stepStockCount() : t.code === 'T-CLEAN' ? handleCode('CLEAN:')
        : t.code === 'T-CL' ? handleCode('CCP:PRP-WATER-CL') : t.code === 'T-PEST' ? handleCode('PEST:')
        : t.control_point_code ? handleCode('CCP:' + t.control_point_code) : startScan();   // v0.57: valvola deviatrice, salamoia…
      box.append(d);
    });
  }
  async function closeTask(filter, scanEventId) {   // marks today's matching open task done — v0.59: one RPC, queued when offline, for the Agropoli day it was done
    try {
      await save([{ rpc: 'close_open_task', args: { p_day: today(), p_code: filter.code || null, p_equipment_id: filter.equipment_id || null, p_control_point_id: filter.control_point_id || null, p_staff_id: staff.id, p_scan_event_id: scanEventId || null } }]);
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
  async function warmRefs() {                       // after login, in the background: one read per list
    try {
      const [eq, cps, sup, pest, cust] = await Promise.all([sb.from('equipment').select('*').eq('active', true), sb.from('haccp_control_points').select('*').eq('active', true),
        sb.from('parties').select('id, legal_name').eq('is_milk_supplier', true).eq('active', true), sb.from('pest_stations').select('code, kind, location_it, inside').eq('active', true).order('inside', { ascending: false }).order('code'),
        sb.from('parties').select('id, legal_name').in('type', ['customer', 'both']).eq('active', true).order('legal_name')]);
      const patch = {};
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
        live(sb.from('products').select('id, name, sku, kind, active, shelf_life_days, byproduct_product_id'))]);
      if ([milk, open, recent, prods].some(r => r.error || !r.data)) return;      // keep the previous copy
      const byId = new Map(); [...recent.data, ...open.data].forEach(b => byId.set(b.id, b));
      const openIds = open.data.map(b => b.id), lotOf = id => (byId.get(id) || {}).batch_lot;
      const [inp, stp] = openIds.length ? await Promise.all([live(sb.from('batch_milk_inputs').select('batch_id, milk_intake_id, qty_kg').in('batch_id', openIds)),
                                                            live(sb.from('batch_step_logs').select('batch_id, step_id').in('batch_id', openIds))]) : [{ data: [] }, { data: [] }];
      if (inp.error || stp.error) return;
      localStorage.setItem(LK, JSON.stringify({ at: Date.now(), milk: milk.data, batches: [...byId.values()], inputs: inp.data, steps: (stp.data || []).map(x => ({ ...x, batch_lot: lotOf(x.batch_id) })), products: prods.data }));
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
  const scanEvent = (code, action, extra = {}) => ({ table: 'scan_events', row: { code, action, staff_id: staff.id, device: CFG.device, ...extra } });

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
      const items = po.lines.map(l => `${l.name} ${Number(l.remaining).toLocaleString('it-IT')} ${l.unit}`).join(' · ');
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
  $('btn-form-cancel').onclick = () => show('home');

  // ---------- Route a code to its step ----------
  // v0.59: what each scan needs (area, level 2 = registra); the database enforces the same, this just stops before a form that can't be saved
  const NEED = { EQ: 'haccp', CAL: 'haccp', CCP: 'haccp', PAPER: 'haccp', PEST: 'haccp', SAMPLE: 'haccp', HACCP: 'haccp', CLEAN: 'haccp', DDT: 'produzione', LOT: 'produzione', METER: 'produzione', EFFL: 'produzione', PO: 'magazzino', COUNT: 'magazzino', SHIP: 'spedizioni' };
  const allowed = kind => { const a = NEED[kind]; if (!a || PERM.can(a, 2)) return true; toast(`Il profilo "${(PERM.data && PERM.data.role_name) || '?'}" non può registrare qui (${a}): chiedi al responsabile`, 'err'); show('home'); return false; };
  async function handleCode(code) {
    $('form').innerHTML = ''; current = { code };
    const [kind, ...rest] = code.split(':'); const ref = rest.join(':');
    if (!allowed(/^[LR]\d{8}-[A-Z]$/.test(kind) && !rest.length ? 'LOT' : kind)) return;
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
      if (kind === 'PAPER') return ref ? await stepPaper(ref) : stepPaperMenu();
      if (kind === 'STAFF') {                       // one scan = clock in, next scan = clock out
        const { data: r, error } = await sb.rpc('toggle_shift', { p_badge: code });
        if (error) throw error;
        await save([scanEvent(code, 'task_done', { payload: { shift: r.action, hours: r.hours } })]);
        toast(r.action === 'in' ? `${r.staff}: inizio turno ✓` : `${r.staff}: fine turno ✓ · ${Number(r.hours).toLocaleString('it-IT')} h`);
        loadShifts(); return show('home');
      }
      if (!rest.length && /^[LR]\d{8}-[A-Z]$/.test(kind)) return await stepLot(kind);   // v0.54: a lot number typed by hand (L20261005-A) without LOT:
      toast('Codice non riconosciuto: ' + code, 'err'); show('home');
    } catch (e) { console.error(e); toast(e.message, 'err'); show('home'); }
  }
  function openForm(title, sub, onSave) { $('f-title').textContent = title; $('f-sub').textContent = sub; current.onSave = onSave; $('btn-form-save').style.display = ''; show('form'); const f = $('form').querySelector('input,select'); if (f) f.focus(); }
  // v0.52: lot labels — labels.html prints the QR from the URL (code, name, sub, n copies)
  const ddmm = d => d ? d.slice(8, 10) + '/' + d.slice(5, 7) + '/' + d.slice(0, 4) : '';
  const labelUrl = (lot, name, sub, n) => 'labels.html?' + new URLSearchParams({ code: 'LOT:' + lot, name: name || '', sub: sub || '', n: String(Math.max(1, Math.min(60, Math.round(n || 1)))) });
  function showDone(title, lines, links) {        // result card with print buttons; returns 'stay' so the caller does not jump home
    $('form').innerHTML = ''; $('btn-form-save').style.display = 'none';
    const c = document.createElement('div'); c.className = 'card';
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
    if (!$('form').reportValidity()) return; $('btn-form-save').disabled = true;
    try { const r = await current.onSave(); if (r !== 'stay') { show('home'); loadTasks(); } }
    catch (e) { console.error(e); if (Date.now() - lastToastAt > 500) toast((e && e.message) || 'Non salvato', 'err'); }   // v0.59: no silent failures
    finally { $('btn-form-save').disabled = false; }
  };
  // v0.59: Enter on a one-field screen (meter, temperature, chlorine) saves instead of reloading the page to Home
  $('form').addEventListener('submit', e => { e.preventDefault(); const b = $('btn-form-save'); if (b.style.display !== 'none' && !b.disabled) b.click(); });
  // v0.59: changing anything after a "check and press Salva again" warning asks for the confirmation again
  $('form').addEventListener('input', () => { if (current) { current.force = false; current.overOk = false; current.bigOk = false; current.yieldOk = false; } });

  // 1/4/7/9 — equipment: cold room, pasteurizer, thermometer → temperature; POS → Z report
  async function stepEquipment(code) {
    const { data: eq, error: eqErr } = await cached('eq_' + code, () => sb.from('equipment').select('*').eq('code', code).maybeSingle());
    if (!eq) throw new Error(eqErr && !navigator.onLine ? 'Senza rete e macchina non ancora salvata sul tablet: ' + code : 'Macchina sconosciuta: ' + code);
    if (eq.kind === 'pos') return stepZ(eq);
    if (eq.kind === 'thermometer' || eq.kind === 'scale' || eq.code.startsWith('PH-') || current.code.startsWith('CAL:')) return stepCalibration(eq);
    const { data: cp } = await cached('cp_eq_' + eq.id, () => sb.from('haccp_control_points').select('*').eq('equipment_id', eq.id).eq('active', true).neq('code', 'CCP-MILK-TEMP').maybeSingle());
    const lim = cp ? `limite ${cp.min_value ?? ''}${cp.min_value != null && cp.max_value != null ? '–' : ''}${cp.max_value ?? ''} ${cp.unit || ''}`.replace('limite –', 'limite max ') : '';
    const t = field('temp', 'Temperatura °C', 'number', { limit: lim });
    let note = null;
    t.oninput = () => { const v = Number(t.value); const bad = cp && ((cp.max_value != null && v > cp.max_value) || (cp.min_value != null && v < cp.min_value)); if (bad && !note) { note = field('action', 'Fuori limite: cosa hai fatto?', 'text'); } t.style.borderColor = bad ? 'var(--warn)' : ''; };
    openForm(eq.name, eq.code, async () => {
      const v = val('temp'); const bad = cp && ((cp.max_value != null && v > cp.max_value) || (cp.min_value != null && v < cp.min_value));
      const warn = cp && ((cp.warn_max != null && v > cp.warn_max) || (cp.warn_min != null && v < cp.warn_min));
      const ops = [scanEvent(current.code, 'temp_check', { equipment_id: eq.id, payload: { temp_c: v } })];
      if (cp) ops.push({ rpc: 'log_ccp', args: { p_cp_code: cp.code, p_value: v, p_staff_id: staff.id, p_action: val('action'), p_source: 'tablet', p_equipment_code: eq.code } });   // server opens the NC
      await save(ops); await closeTask({ equipment_id: eq.id });
      toast(bad ? 'Registrato come NON CONFORMITÀ' : warn ? 'Registrato · ALLERTA: ricontrolla entro 1 ora' : 'Registrato ✓', bad || warn ? 'err' : 'ok');
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
    field('reading', meter === 'elec_main' ? 'kWh sul contatore' : 'Lettura', 'number', { step: '1' });
    openForm('Contatore', meter, async () => {
      await save([scanEvent(current.code, 'task_done'), { table: 'meter_readings', row: { meter, reading: val('reading'), unit: meter === 'elec_main' ? 'kWh' : 'm3', read_by_id: staff.id } }]);
      await closeTask({ code: 'T-KWH' }); toast('Lettura registrata ✓');
    });
  }
  // 8 — cleaning checklist
  async function stepClean() {
    const { data: cp } = await cached('cp_PRP-CLEAN', () => sb.from('haccp_control_points').select('*').eq('code', 'PRP-CLEAN').maybeSingle());
    if (!cp) throw new Error('Punto di controllo PRP-CLEAN non disponibile: riprova con la rete');
    const items = ['Caldaia / pastorizzatore', 'Filatrice', 'Tavoli e utensili', 'Pavimenti e scarichi', 'Celle frigo'];
    checklist(items);
    openForm('Sanificazione fine turno', 'Spunta tutto prima di salvare', async () => {
      const done = items.filter((_, k) => $('c' + k).checked);
      if (done.length < items.length) { toast('Mancano: ' + items.filter((_, k) => !$('c' + k).checked).join(', '), 'err'); throw new Error('incompleto'); }
      await save([scanEvent(current.code, 'clean_done', { payload: { items: done } }), { table: 'haccp_log', row: { control_point_id: cp.id, result: 'ok', operator: staff.full_name, operator_id: staff.id, source: 'tablet' } }]);
      await closeTask({ control_point_id: cp.id }); toast('Sanificazione registrata ✓');
    });
  }
  // 2 — milk arrival (QR on DDT encodes DDT:<number>, or type it)
  async function stepMilk(ddt) {
    const { data: sup } = await cached('milk_suppliers', () => sb.from('parties').select('id, legal_name').eq('is_milk_supplier', true).eq('active', true));
    if (!sup || !sup.length) throw new Error(navigator.onLine ? 'Nessun fornitore di latte attivo in anagrafica' : 'Senza rete e fornitori non ancora salvati sul tablet');
    // v0.65: shipments the Masseria registered from its page (its weight is the source of truth): pick one, confirm arrival
    let ships = [];
    try { const r = await cached('milk_ships_pending', () => sb.from('milk_shipments').select('id, milk_lot, kg, shipped_at, supplier_id, ddt_number, temperature_c').eq('status', 'shipped').order('shipped_at', { ascending: false }).limit(10)); ships = r.data || []; } catch {}
    const queuedShips = new Set(queue().flatMap(i => (i.ops || []).filter(o => o.table === 'milk_intake' && o.row && o.row.shipment_id).map(o => o.row.shipment_id)));
    ships = ships.filter(x => !queuedShips.has(x.id));                     // already confirmed offline, still in the queue
    const shipLabel = x => `${new Date(x.shipped_at).toLocaleString('it-IT', { weekday: 'short', hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Rome' })} · ${Number(x.kg).toLocaleString('it-IT')} kg · lotto ${x.milk_lot}`;
    const shipSel = ships.length ? field('ship', 'Spedizione dalla Masseria', 'select', { options: [...ships.map(x => [x.id, shipLabel(x)]), ['', '— nessuna: altro fornitore o latte non registrato —']], required: false,
      limit: 'Il peso registrato alla Masseria è quello che vale: qui confermi solo l\'arrivo e fai i controlli.' }) : null;
    field('supplier', 'Fornitore', 'select', { options: sup.map(s => [s.id, s.legal_name]) });
    const ddtIn = field('ddtn', 'Numero DDT', 'text'); ddtIn.value = ddt || ''; ddtIn.placeholder = 'come stampato sul DDT';   // v0.53: station QR "DDT:" arrives with no number
    const { data: cpT } = await cached('cp_CCP-MILK-TEMP', () => sb.from('haccp_control_points').select('*').eq('code', 'CCP-MILK-TEMP').maybeSingle());
    const tMax = Number(cpT?.max_value ?? 8), tWarn = Number(cpT?.warn_max ?? 6);
    field('lot', 'Lotto / cisterna', 'text'); field('kg', 'kg (bilancia)', 'number', { step: '0.1' }); field('temp', 'Temperatura latte °C', 'number', { limit: `CCP 1a: ≤ ${tMax} °C (oltre ${tWarn} °C lavorare entro 2 ore)` });
    field('abx', 'Test antibiotici (CCP 1b)', 'select', { options: [['', '— scegli —'], ['0', 'Negativo'], ['1', 'POSITIVO']], limit: 'Test rapido prima dello scarico' });
    field('fat', 'Grasso % (se noto)', 'number', { step: '0.01', required: false }); field('prot', 'Proteine % (se note)', 'number', { step: '0.01', required: false }); field('scc', 'Cellule somatiche /ml (da analisi, se note)', 'number', { step: '1000', required: false }); field('photo', 'Foto DDT', 'file', { required: false });
    const applyShip = () => {                                              // a chosen shipment fixes supplier, lot and kg
      const x = ships.find(y => y.id === (shipSel && shipSel.value)), kgIn = $('kg'), lotF = $('lot');
      if (x) { if (x.supplier_id && sup.some(y => y.id === x.supplier_id)) $('supplier').value = x.supplier_id;
        kgIn.value = x.kg; lotF.value = x.milk_lot; if (x.ddt_number && !ddtIn.value) ddtIn.value = x.ddt_number; }
      else if (kgIn.readOnly) { kgIn.value = ''; lotF.value = ''; }
      [kgIn, lotF].forEach(e => { e.readOnly = !!x; e.style.background = x ? '#f1efe9' : ''; });
      ddtIn.required = !x;                                                 // the farm may not have a DDT number for it
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
      const shipId = (shipSel && shipSel.value) || null;
      let lotIn = String(val('lot') || '').trim();
      if (lotIn && !shipId) {
        const base = lotIn; let k = 0; const known = lotView().milk;
        while (k < 9) { const { count, error } = await live(sb.from('labels').select('id', { count: 'exact', head: true }).ilike('code', likeSafe('LOT:' + lotIn)));
          const taken = error ? known.some(x => lotEq(x.milk_lot, lotIn)) : !!count;   // offline: lots on the tablet
          if (!taken) break;
          k++; lotIn = base + '-' + today().slice(8, 10) + today().slice(5, 7) + (k > 1 ? '-' + k : ''); }
        if (lotIn !== base) { $('lot').value = lotIn; toast(`Lotto ${base} già usato: registrato come ${lotIn}`, 'err'); }
      }
      const hot = val('temp') > tMax, abxPos = val('abx') === '1', accepted = !hot && !abxPos;
      const why = [hot ? `temperatura > ${tMax} °C` : null, abxPos ? 'test antibiotici positivo' : null].filter(Boolean).join(' · ');
      const ops = [scanEvent(current.code, 'milk_receive', { payload: { kg: val('kg'), temp_c: val('temp'), abx: Number(val('abx')), shipment_id: shipId } }),
        { table: 'milk_intake', row: { intake_date: today(), intake_time: new Date().toTimeString().slice(0, 8), supplier_id: val('supplier'), milk_lot: lotIn, qty_kg: val('kg'), temperature_c: val('temp'), fat_pct: val('fat'), protein_pct: val('prot'), scc_cells_ml: val('scc') == null ? null : Math.round(val('scc')), ddt_number: ddtNo || null, accepted, rejection_reason: accepted ? null : why, received_by: staff.full_name, received_by_id: staff.id, source: 'tablet', shipment_id: shipId } },
        { table: 'labels', row: { kind: 'milk_lot', code: 'LOT:' + lotIn, lot_number: lotIn, milk_intake_id: '$1.id', printed_by_id: staff.id } },
        { rpc: 'log_ccp', args: { p_cp_code: 'CCP-MILK-TEMP', p_value: val('temp'), p_staff_id: staff.id, p_action: hot ? 'latte respinto' : null, p_source: 'tablet', p_equipment_code: 'TERM-01' } },
        { rpc: 'log_ccp', args: { p_cp_code: 'CCP-MILK-ABX', p_value: Number(val('abx')), p_staff_id: staff.id, p_action: abxPos ? 'latte respinto e isolato, Masseria avvisata' : null, p_source: 'tablet' } }];
      await save(ops);
      const f = $('photo').files[0]; if (f && navigator.onLine) { const path = `ddt/${today()}_${(ddtNo || lotIn).replace(/[^A-Za-z0-9-]/g, '_')}.jpg`; const { error } = await sb.storage.from('documents').upload(path, f, { upsert: true }); if (!error) await sb.from('documents').insert({ kind: 'ddt_in', storage_path: path, original_filename: f.name, mime_type: f.type, document_date: today(), uploaded_by_id: staff.id }); }
      toast(accepted ? (val('temp') > tWarn ? `Latte accettato · ${val('temp')} °C: iniziare la lavorazione entro 2 ore` : 'Latte registrato ✓') : 'Latte RIFIUTATO: ' + why, accepted && val('temp') <= tWarn ? 'ok' : 'err');
      const lotv = lotIn, kgv = val('kg'), sup = ($('supplier').selectedOptions[0] || {}).textContent || '';
      if (!accepted) return showDone('Latte RIFIUTATO', [`Lotto ${lotv} · ${kgv} kg`, why, 'Isola il latte e avvisa la Masseria e il responsabile.'], []);
      return showDone('✓ Latte registrato', [`Lotto ${lotv} · ${kgv} kg · ${sup}`, 'Attacca l\'etichetta al tank: la scansioni per avviare la caldaia.'],
        [['🖨 Stampa etichetta lotto latte', labelUrl(lotv, 'Latte di bufala · ' + sup, 'arrivo ' + ddmm(today()), 1)]]);
    });
  }
  // 3/5/6 — a lot label: milk lot → start/end batch; batch lot → sale or shipment
  async function stepLot(lot) {
    if (navigator.onLine && queue().length) await flush();   // v0.62: send what was saved offline first, so the database knows those lots
    let milk = null, batch = null, off = false, view = null;
    const [m, b] = await Promise.all([
      live(sb.from('milk_intake').select('id, milk_lot, qty_kg, intake_date, accepted, rejection_reason').ilike('milk_lot', likeSafe(lot)).order('intake_date', { ascending: false }).order('created_at', { ascending: false }).limit(1).maybeSingle()),
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
    if (off) {
      const ids = new Set(view.inputs.filter(i => i.milk_intake_id === milk.id).map(i => i.batch_id));
      const openB = view.batches.find(x => ids.has(x.id) && x.output_kg == null);
      if (openB) return stepBatchWork(openB);
    } else {
      const { data: open } = await sb.from('batch_milk_inputs').select('batch_id, production_batches!inner(id, batch_lot, product_id, preset_id, output_kg, milk_in_kg, input_kind)').eq('milk_intake_id', milk.id).is('production_batches.output_kg', null).limit(1);
      if (open && open[0]) return stepBatchWork(open[0].production_batches);
    }
    return stepBatchStart(milk, lot);
  }
  // 5b — the 'make' steps of the preset (maturazione, filatura, formatura…): run once per batch, then the lot closes
  async function stepBatchWork(b) {
    const presets = await loadPresets();
    const preset = b.preset_id || (presetsFor(presets, b.product_id).find(p => p.is_default) || {}).id;
    const make = processSteps(presets, preset, 'make');
    if (!make.length) return stepBatchEnd(b);
    let { data: done, error: de } = b.id ? await live(sb.from('batch_step_logs').select('step_id').eq('batch_id', b.id)) : { data: null, error: { name: 'Timeout' } };
    if (de || !done) done = lotView().steps.filter(x => lotEq(x.batch_lot, b.batch_lot));   // offline: copy + queued steps
    else done = [...done, ...lotView().steps.filter(x => lotEq(x.batch_lot, b.batch_lot))];
    const doneIds = new Set((done || []).map(d => d.step_id));
    const left = make.filter(st => !doneIds.has(st.step_id));
    if (!left.length) return stepBatchEnd(b);
    runDosing(`Lavorazione ${b.batch_lot}`, b.batch_lot, left, async () => { toast('Lavorazione registrata ✓ · a fine lotto scansiona di nuovo l\'etichetta sul tank'); }, { skippable: true, onSkipAll: () => stepBatchEnd(b) });
  }
  async function stepBatchStart(milk, lot, pre = null) {   // pre: a proposal from the production plan (v0.70)
    let { data: prods, error: pe } = await live(sb.from('products').select('id, name, byproduct_product_id').eq('kind', 'finished_good').eq('active', true));
    if (pe || !prods) prods = lotView().products.filter(p => p.kind === 'finished_good' && p.active);   // offline
    if (!prods.length) throw new Error('Nessun prodotto disponibile (senza rete e prodotti non ancora salvati sul tablet)');
    const fromWhey = new Set(prods.map(p => p.byproduct_product_id).filter(Boolean));   // v0.80: whey products (ricotta) last: milk goes to mozzarella by default
    prods = [...prods].sort((a, b) => (fromWhey.has(a.id) - fromWhey.has(b.id)) || String(a.name).localeCompare(String(b.name)));
    // v0.59: next free letter among today's L-lots (ricotta R-lots and old simulation rows no longer shift it); re-read at save time
    const nextLot = async () => { const pre = 'L' + today().replace(/-/g, '') + '-';
      let { data: ls, error: le } = await live(sb.from('production_batches').select('batch_lot').like('batch_lot', pre + '%'));
      ls = [...((le || !ls) ? [] : ls), ...lotView().batches.filter(x => String(x.batch_lot || '').startsWith(pre))];   // + the device copy and the queue
      const used = new Set(ls.map(x => x.batch_lot.slice(pre.length)));
      for (let c = 65; c <= 90; c++) if (!used.has(String.fromCharCode(c))) return pre + String.fromCharCode(c);
      return pre + 'Z' + Date.now().toString().slice(-3); };
    let batchLot = await nextLot();
    const prodSel = field('product', 'Prodotto', 'select', { options: prods.map(p => [p.id, p.name]) });
    const presets = await loadPresets();
    const preSel = field('preset', 'Impostazioni di processo', 'select', { options: [['', '—']], required: false });
    const fillPresets = () => { const mine = presetsFor(presets, prodSel.value); preSel.innerHTML = mine.length ? mine.map(p => `<option value="${p.id}" ${p.is_default ? 'selected' : ''}>${p.name}${p.is_default ? ' · predefinito' : ''}</option>`).join('') : '<option value="">nessun preset: solo dosi</option>'; };
    prodSel.onchange = fillPresets; fillPresets();
    if (pre) {
      if ([...prodSel.options].some(o => o.value === pre.product_id)) { prodSel.value = pre.product_id; fillPresets(); }
      if (pre.preset_id && [...preSel.options].some(o => o.value === pre.preset_id)) preSel.value = pre.preset_id;
    }
    field('mu', 'Unità', 'select', { options: [['kg', 'kg (bilancia)'], ['l', 'litri (contalitri)']] });
    const kgIn = field('kg', 'Latte in caldaia', 'number', { step: '0.1' });
    // v0.80: the day's pasteuriser check, asked here if nobody has recorded it yet (NON ok = no batch)
    const valveDone = await ccpRecorded('PRP-PAST-VALVE', null, null, true);
    if (!valveDone) {
      const vs = field('valve', 'Pastorizzatore: verifica di inizio giornata (non ancora registrata oggi)', 'select', { options: [['', '— scegli —'], ['0', 'Ok'], ['1', 'NON ok']], limit: 'NON ok = non pastorizzare: chiama il responsabile' });
      vs.onchange = async () => {                      // NON ok: recorded at once (non-conformity) and no batch
        if (vs.value !== '1') return;
        try { await rpcNow('log_ccp', { p_cp_code: 'PRP-PAST-VALVE', p_value: 1, p_staff_id: staff.id, p_action: 'Verifica non ok all\'inizio lotto: lotto non avviato', p_source: 'tablet' }); } catch (e) { console.warn(e); }
        toast('Pastorizzatore NON ok: lotto non avviato. Chiama il responsabile.', 'err'); show('home'); loadTasks();
      };
    }
    // v0.80: pasteurisation (CCP 2) asked here when the chosen preset has no pasteurisation step
    const pastIn = field('past', 'Temperatura di pastorizzazione (CCP 2), °C', 'number', { step: '0.1', required: false });
    const pastLbl = pastIn.previousElementSibling;
    const togglePast = () => { const has = processSteps(presets, preSel.value, 'start').some(st => st.ccp === 'CCP-PAST' || /CCP\s*2/.test(st.name)); pastIn.style.display = pastLbl.style.display = has ? 'none' : ''; pastIn.required = !has; };
    preSel.addEventListener('change', togglePast); prodSel.addEventListener('change', togglePast); togglePast();
    if (pre) {
      kgIn.value = pre.milk_kg;
      const h = document.createElement('div'); h.className = 'hint'; $('form').append(h);
      const upd = () => { const v = val('mu') === 'l' ? (val('kg') || 0) * MILK_DENSITY : (val('kg') || 0);
        h.textContent = `Proposta: ${fmtKg(pre.milk_kg)} kg → ≈ ${fmtKg(Math.round(v * pre.yield_pct) / 100)} kg di ${pre.product} (resa ${String(pre.yield_pct).replace('.', ',')}%). Le dosi sono nel passo successivo.`; };
      kgIn.addEventListener('input', upd); $('mu').addEventListener('change', upd); upd();
    }
    openForm('Inizio lotto ' + batchLot, `latte ${lot} · disponibili ${milk.qty_kg} kg`, async () => {
      const kg = val('mu') === 'l' ? Math.round(val('kg') * MILK_DENSITY * 10) / 10 : val('kg');
      const product = val('product'), preset = val('preset') || null;
      if (pre && kg > pre.left_kg * 1.02 && !current.overOk) { current.overOk = true; toast(`${fmtKg(kg)} kg sono più del latte rimasto su ${lot} (${fmtKg(pre.left_kg)} kg): controlla e premi Salva di nuovo`, 'err'); throw new Error('confirm'); }
      batchLot = await nextLot();                            // another tablet may have opened a lot meanwhile (offline: the device copy)
      const extra = [];
      if (!valveDone) extra.push({ rpc: 'log_ccp', args: { p_cp_code: 'PRP-PAST-VALVE', p_value: 0, p_staff_id: staff.id, p_source: 'tablet' } });
      if (pastIn.required && val('past') != null) extra.push({ rpc: 'log_ccp', args: { p_cp_code: 'CCP-PAST', p_value: val('past'), p_staff_id: staff.id, p_batch_lot: batchLot, p_source: 'tablet', p_equipment_code: 'TERM-02' } });
      await save([scanEvent(current.code, 'batch_start', { payload: { batch_lot: batchLot, kg, entered: val('kg'), unit: val('mu'), preset_id: preset } }),
        { table: 'production_batches', row: { batch_date: today(), batch_lot: batchLot, product_id: product, milk_in_kg: kg, preset_id: preset, started_at: new Date().toISOString(), casaro: staff.full_name, casaro_id: staff.id, source: 'tablet' } },
        { table: 'batch_milk_inputs', row: { batch_id: '$1.id', milk_intake_id: milk.id, qty_kg: kg } },
        { table: 'stock_moves', row: { product_id: await rawMilkId(), lot_number: lot, qty: -kg, move_type: 'production_in', batch_id: '$1.id', source: 'tablet' } }, ...extra]);
      if (pre) planStarted(pre, kg);
      const steps = mergeSteps(await doseSteps(product, 'start', { milk: kg }), processSteps(presets, preset, 'start'));
      if (!steps.length) { toast('Lotto ' + batchLot + ' avviato ✓'); return; }
      runDosing(`Avvio ${batchLot} · ${kg} kg latte`, batchLot, steps, async () => toast('Lotto ' + batchLot + ' avviato ✓ · scansiona di nuovo il lotto per la lavorazione'));
      return 'stay';
    });
  }
  async function stepBatchEnd(b) {
    // v0.78: a batch started offline (no id yet) closes offline too: the update finds it by lot number, later steps take its id from that step
    const bKey = b.id ? { id: b.id } : { batch_lot: b.batch_lot }, bId = b.id || '$1.id';
    let { data: prod, error: pre } = await live(sb.from('products').select('name, shelf_life_days, byproduct_product_id').eq('id', b.product_id).single());
    if (pre || !prod) prod = cachedProduct(b.product_id);
    const byp = b.input_kind !== 'whey' ? prod?.byproduct_product_id : null;
    let ey = null;                                   // v0.70: expected yield (online; offline the plan kept on the tablet)
    const er = await live(sb.rpc('expected_yield', { p_product: b.product_id, p_preset: b.preset_id || null, p_exclude: b.id || null }), 5000);
    if (!er.error && er.data) ey = er.data; else if (planCache && planCache.yield && b.input_kind !== 'whey') ey = planCache.yield;
    const outIn = field('out', 'kg prodotto', 'number', { step: '0.1' });
    if (ey) { const h = document.createElement('div'); h.className = 'hint'; $('form').append(h);
      const upd = () => { const o = val('out'); h.textContent = `Attesi ≈ ${fmtKg(Math.round(b.milk_in_kg * ey.pct) / 100)} kg (resa ${String(ey.pct).replace('.', ',')}%${String(ey.source).startsWith('default') ? ', stimata' : ''})` + (o ? ` · con ${fmtKg(o)} kg la resa è ${String(Math.round(o / b.milk_in_kg * 1000) / 10).replace('.', ',')}%` : ''); };
      outIn.addEventListener('input', upd); upd(); }
    // v0.80: the lot's critical point (mozzarella CCP 3 stretching, ricotta CCP 4) asked here if it is not recorded yet
    const ccpCode = b.input_kind === 'whey' ? 'CCP-RIC' : 'CCP-STRETCH';
    const ccpDone = await ccpRecorded(ccpCode, b.batch_lot, b.id);
    if (!ccpDone) field('ccpv', b.input_kind === 'whey' ? 'Temperatura di affioramento (CCP 4), °C · non ancora registrata' : 'Temperatura della pasta filata (CCP 3), °C · non ancora registrata', 'number', { step: '0.1', limit: 'Valore letto sul termometro; se era scritto sul foglio, ricopialo qui' });
    field('ph', 'pH cagliata (se misurato)', 'number', { step: '0.01', required: false }); field('n', 'Etichette da stampare', 'number', { step: '1', required: false });
    if (byp) field('whey', 'Siero per ricotta, kg (0 = niente ricotta)', 'number', { step: '1', required: false });
    openForm('Fine lotto ' + b.batch_lot, `${b.milk_in_kg} kg ${b.input_kind === 'whey' ? 'siero' : 'latte'} in caldaia`, async () => {
      const out = val('out'), ph = val('ph'), n = val('n'), whey = byp ? (val('whey') || 0) : 0, y = Math.round(out / b.milk_in_kg * 1000) / 10;
      if (ey && Math.abs(y - ey.pct) > (ey.tolerance_pts ?? 4) && !current.yieldOk) {   // likely a typo in the kg: ask once
        current.yieldOk = true;
        toast(`Resa ${String(y).replace('.', ',')}% contro ${String(ey.pct).replace('.', ',')}% attesa: controlla i kg (prodotto e ${b.input_kind === 'whey' ? 'siero' : 'latte'}). Se è giusto premi Salva di nuovo.`, 'err');
        throw new Error('confirm');
      }
      const expS = addDays(today(), prod?.shelf_life_days || 5), code = current.code;
      const lotLink = [`🖨 Stampa ${n || 1} etichett${(n || 1) === 1 ? 'a' : 'e'} lotto ${b.batch_lot}`, labelUrl(b.batch_lot, prod?.name, 'scad. ' + ddmm(expS), n || 1)];
      const startRicotta = async () => {
        const ricLot = 'R' + b.batch_lot.slice(1);
        await save([{ rpc: 'start_byproduct_batch', args: { p_parent_lot: b.batch_lot, p_whey_kg: whey, p_staff_id: staff.id } }]);
        const done = () => { toast(`Ricotta ${ricLot} avviata ✓ · stampa l'etichetta per il tino`);
          return showDone(`✓ Lotto ${b.batch_lot} chiuso`, [`${out} kg · resa ${y}% · scade ${ddmm(expS)}`, `Ricotta ${ricLot} avviata con ${whey} kg di siero. Attacca l'etichetta al tino: a fine ricotta scansionala per chiudere il lotto (le etichette delle fuscelle si stampano alla chiusura).`],
            [lotLink, ['🖨 Stampa etichetta tino ricotta', labelUrl(ricLot, 'Ricotta in lavorazione', 'tino · ' + ddmm(today()), 1)]]); };   // v0.54: the tino gets its own label to scan at close
        const steps = await doseSteps(byp, 'start', { milk: whey });
        if (!steps.length) return done();
        runDosing(`Ricotta ${ricLot} · ${whey} kg siero`, ricLot, steps, async () => done());
        return 'stay';
      };
      const close = async () => {
        const ops = [scanEvent(code, 'batch_end', { payload: { output_kg: out, yield_pct: y, whey_to_byproduct_kg: whey } }),
          { table: 'production_batches', update: bKey, row: { output_kg: out, curd_ph: ph, finished_at: new Date().toISOString() } },
          { table: 'stock_moves', row: { product_id: b.product_id, lot_number: b.batch_lot, expiry_date: expS, qty: out, move_type: 'production_out', batch_id: bId, source: 'tablet' } }];
        if (!ccpDone && val('ccpv') != null) ops.push({ rpc: 'log_ccp', args: { p_cp_code: ccpCode, p_value: val('ccpv'), p_staff_id: staff.id, p_batch_lot: b.batch_lot, p_source: 'tablet', p_equipment_code: 'TERM-02' } });   // v0.80 (after the update: ids above stay $1)
        if (b.input_kind !== 'whey')   // ricotta label row is created when the batch starts; the printable label is offered at close (v0.52)
          ops.push({ table: 'labels', row: { kind: 'batch_lot', code: 'LOT:' + b.batch_lot, lot_number: b.batch_lot, product_id: b.product_id, batch_id: bId, qty_printed: n || 1, printed_by_id: staff.id } });
        await save(ops);
        toast(`Resa ${y}% · ${out} kg ✓`);
        if (whey > 0) return startRicotta();
        return showDone(`✓ Lotto ${b.batch_lot} chiuso`, [`${out} kg · resa ${y}% · scade ${ddmm(expS)}`, 'Etichetta ogni cassa e confezione con il lotto.'], [lotLink]);
      };
      const presets = await loadPresets();
      const steps = mergeSteps(await doseSteps(b.product_id, 'close', { milk: b.milk_in_kg, out }), processSteps(presets, b.preset_id || (presetsFor(presets, b.product_id).find(p => p.is_default) || {}).id, 'close'));
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
    field('kg', 'kg', 'number', { step: '0.01' });
    field('cust', 'Cliente', 'select', { options: [['', '—'], ...custs.map(x => [x.id, x.legal_name])] });
    openForm('Spedizione', 'lotto ' + b.batch_lot, async () => {
      const kg = val('kg');
      if (!val('cust')) { toast('Scegli il cliente', 'err'); throw new Error('cliente'); }
      const ddt = 'DDT-' + today().replace(/-/g, '') + '-' + Date.now().toString().slice(-4);
      await save([scanEvent(current.code, 'pick', { payload: { kg, mode: 'ship' } }),
        { table: 'shipments', row: { ddt_number: ddt, customer_id: val('cust'), status: 'picked', driver_id: staff.id } },
        { table: 'shipment_lines', row: { shipment_id: '$1.id', product_id: prod.id, lot_number: b.batch_lot, qty: kg } },
        { table: 'stock_moves', row: { product_id: prod.id, lot_number: b.batch_lot, qty: -kg, move_type: 'sale', source: 'tablet' } }]);
      toast(`Spedizione ${ddt} · ${kg} kg ✓`);
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
      const q = field('q' + i, `Ricevuti (${l.unit})`, 'number', { step: l.unit === 'pz' ? '1' : '0.01' }); q.value = l.remaining;
      field('lot' + i, 'Lotto fornitore', 'text', { required: false });
      const e = field('exp' + i, 'Scadenza (se stampata)', 'date', { required: false });
      if (l.shelf_life_days) e.value = addDays(today(), l.shelf_life_days);
      field('pr' + i, `Prezzo sul DDT €/${l.unit} (solo se diverso)`, 'number', { step: '0.0001', required: false });
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
      if (over.length && !current.overOk) { current.overOk = true; toast('Quantità superiore all\'ordine: ricontrolla e premi Salva di nuovo', 'err'); throw new Error('over'); }
      const ddt = val('ddt') || null, chk = val('chk'), chkNote = (val('chknote') || '').trim();
      if (chk === '') { toast('Registra il controllo all\'arrivo', 'err'); throw new Error('chk'); }
      if (chk === '0' && !chkNote) { toast('Scrivi cosa non va nella merce', 'err'); throw new Error('chknote'); }
      await save([scanEvent(current.code, 'goods_receive', { payload: { po_number: po.po_number, ddt, lines, check_ok: chk === '1', check_note: chkNote || null } }),
        { rpc: 'receive_purchase_order', args: { p_po_number: po.po_number, p_lines: lines, p_staff_id: staff.id, p_ddt: ddt } },
        { rpc: 'record_receipt_check', args: { p_po_number: po.po_number, p_ok: chk === '1', p_note: chkNote || null, p_staff_id: staff.id, p_ddt: ddt } }]);
      const f = $('photo').files[0];
      if (f && navigator.onLine) { const path = `ddt/${today()}_${po.po_number}.jpg`; const { error: ue } = await sb.storage.from('documents').upload(path, f, { upsert: true });
        if (!ue) await sb.from('documents').insert({ kind: 'ddt_in', storage_path: path, original_filename: f.name, mime_type: f.type, document_date: today(), related_table: 'purchase_orders', related_id: po.id, uploaded_by_id: staff.id }); }
      const tot = lines.reduce((a, x) => a + x.qty, 0);
      if (chk === '0') toast(`Ricevuto ${po.po_number} · merce NON conforme: isolala con il cartello e avvisa il responsabile`, 'err');
      else toast(`Ricevuto ${po.po_number} · ${tot.toLocaleString('it-IT')} pezzi/kg in magazzino ✓`);
    });
  }

  // 12 — weekly stock count: sheet prefilled with the system quantity; change only what differs
  async function stepStockCount() {
    $('form').innerHTML = ''; current = { code: 'COUNT:' };
    const { data: sheet, error } = await sb.rpc('start_stock_count', { p_staff_id: staff.id });
    if (error) { toast('Conta non disponibile offline', 'err'); return; }
    const lines = sheet.lines || [];
    let lastKind = '';
    lines.forEach((l, i) => {
      if (l.kind !== lastKind) { lastKind = l.kind; const h = document.createElement('h2'); h.style.marginTop = '18px'; h.textContent = l.kind === 'finished_good' ? 'Prodotto finito (per lotto)' : 'Consumabili e imballi'; $('form').append(h); }
      const q = field('c' + i, `${l.name}${l.lot ? ' · ' + l.lot : ''}  —  sistema ${Number(l.system_qty).toLocaleString('it-IT')} ${l.unit}`, 'number', { step: l.unit === 'pz' ? '1' : '0.1', required: false });
      q.value = l.system_qty; q.dataset.sys = l.system_qty; q.dataset.line = l.line_id;
      q.oninput = () => { q.style.borderColor = Number(q.value) !== Number(q.dataset.sys) ? 'var(--warn)' : ''; };
    });
    field('note', 'Note (facoltative)', 'text', { required: false });
    openForm('Conta magazzino', `${lines.length} righe · cambia solo ciò che è diverso, poi Salva`, async () => {
      const changed = [...$('form').querySelectorAll('input[data-line]')].filter(i => i.value !== '' && Number(i.value) !== Number(i.dataset.sys)).map(i => ({ line_id: i.dataset.line, counted_qty: Number(i.value) }));
      const big = changed.filter(c => { const i = $('form').querySelector(`input[data-line="${c.line_id}"]`); const sys = Number(i.dataset.sys); return sys > 0 && Math.abs(c.counted_qty - sys) / sys > 0.5; });
      if (big.length && !current.bigOk) { current.bigOk = true; toast(`${big.length} righe con differenza oltre il 50%: ricontrolla e premi Salva di nuovo`, 'err'); throw new Error('check'); }
      const { data, error: pe } = await sb.rpc('post_stock_count', { p_count_id: sheet.count_id, p_lines: changed, p_staff_id: staff.id, p_note: val('note') || null });
      if (pe) { toast(pe.message, 'err'); throw pe; }
      await save([scanEvent('COUNT:', 'task_done', { payload: { count_id: sheet.count_id, changed: data.lines_changed } })]);
      await closeTask({ code: 'T-COUNT' });
      toast(data.lines_changed ? `Conta registrata · ${data.lines_changed} rettifiche ✓` : 'Conta registrata · tutto coincide ✓');
    });
  }
  $('btn-count').onclick = () => stepStockCount().catch(e => { toast(e.message, 'err'); show('home'); });

  // 13 — effluent register: what left the dairy today, where it went, which document covers it
  function stepEffluent() {
    $('form').innerHTML = ''; current = { code: 'EFFL:' };
    field('kind', 'Cosa', 'select', { options: [['scotta', 'Scotta (dopo la ricotta)'], ['siero', 'Siero (non lavorato)'], ['acque_lavaggio', 'Acque di lavaggio'], ['fanghi', 'Fanghi / residui'], ['altro', 'Altro']] });
    field('qty', 'Quantità', 'number', { step: '10' });
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
        { table: 'effluent_log', row: { kind: val('kind'), qty: val('qty'), unit: val('unit'), destination: val('dest'), recipient: val('recipient') || null, document_ref: val('doc') || null, notes: val('note') || null, staff_id: staff.id } }]);
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
    const { data: cfg } = await sb.from('settings').select('key, value').in('key', ['ship.default_carrier', 'ship.wholesale_carrier', 'ship.tolerance_pct']);
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
        const q = field('q' + k, `Peso effettivo (${l.unit})${alloc.length > 1 ? ' da questo lotto' : ''}`, 'number', { step: '0.01' }); q.value = Number(a.qty); q.dataset.weighed = '0';
        q.oninput = () => { q.dataset.weighed = '0'; current.force = false; };
        $('form').append(scaleButton(q, 'net'));
        rows.push({ l, lot, q });
      });
    });
    const g = field('gross', 'Peso lordo collo (kg, facoltativo)', 'number', { step: '0.01', required: false }); $('form').append(scaleButton(g, 'gross'));
    const carrier = field('carrier', 'Vettore', 'text', { required: false }); carrier.value = o.channel === 'wholesale' ? (S['ship.wholesale_carrier'] || 'Consegna diretta') : (S['ship.default_carrier'] || 'BRT');
    field('tracking', 'Tracking / n. lettera di vettura (se già stampata)', 'text', { required: false });
    field('note', 'Note', 'text', { required: false });
    openForm(`Prepara ${o.order_number}`, `${o.customer || 'cliente online'} · ${o.lines.length} righe · tolleranza ±${S['ship.tolerance_pct'] || 5}%`, async () => {
      // v0.79: a row set to 0 (all the kg taken from the other lot of a split line) is left out instead of refusing the save
      const lines = rows.map(r => ({ product_id: r.l.product_id, lot_number: r.lot.value, qty: Number(r.q.value) || 0, weighed: r.q.dataset.weighed === '1' })).filter(x => x.qty > 0);
      if (!lines.length) { toast('Nessuna quantità da spedire', 'err'); throw new Error('qty'); }
      if (lines.some(x => !x.lot_number)) { toast('Manca il lotto su una riga', 'err'); throw new Error('lot'); }
      const { data, error } = await sb.rpc('pack_order', { p_order_id: o.order_id, p_lines: lines, p_staff_id: staff.id, p_gross_kg: val('gross'), p_carrier: val('carrier') || null, p_tracking: val('tracking') || null, p_notes: val('note') || null, p_force: current.force });
      if (error) { toast(error.message, 'err'); throw error; }
      if (data && data.needs_confirm) { current.force = true;
        toast((data.reasons && data.reasons.length ? 'Da confermare: ' + data.reasons.join('; ') : `Pesati ${fmtKg(data.packed_kg)} kg contro ${fmtKg(data.ordered_kg)} ordinati (${data.variance_pct > 0 ? '+' : ''}${data.variance_pct}%)`) + '. Ricontrolla e premi Salva di nuovo per confermare', 'err'); throw new Error('confirm'); }
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
      try { const kg = await readScale(); input.value = Math.round(kg * 100) / 100; input.dataset.weighed = '1'; input.dispatchEvent(new Event('change')); toast(`Bilancia: ${fmtKg(kg)} kg`); }
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
  const queuedOps = () => queue().flatMap(i => i.ops || []);
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
  function runDosing(title, batchLot, steps, onDone, opts = {}) {
    let k = 0, warned = false;
    const btns = ['d-ok', 'd-diff', 'd-alt-ok', 'd-skip', 'd-pause'].map($);
    const render = () => {
      const s = steps[k]; warned = false;
      $('d-title').textContent = title; $('d-prog').textContent = `Passo ${k + 1} di ${steps.length}`;
      $('d-bar').style.width = (k / steps.length * 100) + '%';
      $('d-name').textContent = s.name;
      if (s.kind === 'process') {
        $('d-mach').textContent = s.machine; $('d-qty').textContent = s.target_txt || '—'; $('d-src').textContent = '';
        $('d-diff').textContent = s.metric === 'none' ? '' : (METRIC[s.metric] || [])[1] + ' diversa'; $('d-diff').style.display = s.metric === 'none' ? 'none' : '';
        $('d-alt-l').textContent = (METRIC[s.metric] || ['', 'Valore'])[1]; $('d-alt-u').textContent = (METRIC[s.metric] || [''])[0]; $('d-alt-in').step = s.metric === 'ph' ? '0.01' : '0.5';
        $('d-ok').textContent = s.metric === 'none' ? '✓ Fatto' : `✓ Fatto · ${s.target}${(METRIC[s.metric] || [''])[0] ? ' ' + METRIC[s.metric][0] : ''}`;
      } else {
        $('d-mach').textContent = ''; $('d-qty').textContent = fmtQty(s.qty, s); $('d-src').textContent = s.source === 'placeholder' ? 'ricetta provvisoria' : '';
        $('d-diff').textContent = 'Ho usato una quantità diversa'; $('d-diff').style.display = ''; $('d-alt-l').textContent = 'Quantità usata'; $('d-alt-u').textContent = disp(s).u; $('d-alt-in').step = '0.1'; $('d-ok').textContent = '✓ Fatto';
      }
      $('d-instr').textContent = s.instruction_it || '';
      $('d-skip').style.display = opts.skippable ? '' : 'none'; $('d-pause').style.display = opts.skippable ? '' : 'none';
      $('d-alt').style.display = 'none'; $('d-alt-in').value = ''; $('d-warn').textContent = ''; $('d-ok').style.display = '';
      if (s.kind === 'process' && s.ccp) {             // v0.80: CCP = write the value read on the thermometer; no one-tap "Fatto · target", no skip
        $('d-ok').style.display = 'none'; $('d-diff').style.display = 'none'; $('d-skip').style.display = 'none';
        $('d-alt').style.display = 'block'; $('d-alt-l').textContent = `${(METRIC[s.metric] || ['', 'Valore misurato'])[1]} (punto critico: scrivi il valore letto)`;
        $('d-instr').textContent = [s.instruction_it, `Obiettivo ${s.target ?? '—'}${(METRIC[s.metric] || [''])[0] ? ' ' + METRIC[s.metric][0] : ''}${s.lo != null || s.hi != null ? ` · intervallo ${s.lo ?? '…'}–${s.hi ?? '…'}` : ''}`].filter(Boolean).join(' · ');
      }
      btns.forEach(b => b.disabled = false); show('dose');
    };
    const finish = async () => {                      // 'stay' = next sequence took over
      $('d-bar').style.width = '100%';
      try { const r = await onDone(); if (r !== 'stay') { show('home'); loadTasks(); } }
      catch (e) {                                      // v0.59: the close failed — stay here, ✓ tries the close again (it used to freeze on steps[k])
        console.error(e); if (Date.now() - lastToastAt > 500) toast((e && e.message) || 'Chiusura non salvata', 'err');
        $('d-prog').textContent = 'Passi registrati · chiusura non salvata'; $('d-ok').textContent = '↻ Riprova a chiudere'; btns.forEach(b => b.disabled = false); show('dose');
      }
    };
    const next = async q => {
      const s = steps[k]; btns.forEach(b => b.disabled = true);
      try {
        if (s.kind === 'process') await save([{ rpc: 'log_batch_step', args: { p_batch_lot: batchLot, p_step_id: s.step_id, p_actual: q, p_staff_id: staff.id } }]);
        else await save([{ rpc: 'record_batch_consumable', args: { p_batch_lot: batchLot, p_sku: s.sku, p_qty: q, p_qty_standard: s.qty, p_staff_id: staff.id } }]);
      } finally { btns.forEach(b => b.disabled = false); }
      k++; if (k < steps.length) return render();
      return finish();
    };
    $('d-ok').onclick = () => { if (k >= steps.length) return finish(); const s = steps[k]; if (s.kind === 'process' && s.ccp) { $('d-alt').style.display = 'block'; $('d-alt-in').focus(); return; } next(s.kind === 'process' ? s.target : s.qty); };
    $('d-diff').onclick = () => { $('d-alt').style.display = 'block'; $('d-alt-in').focus(); };
    $('d-pause').onclick = () => { toast('I passi confermati sono salvati: scansiona di nuovo il lotto per continuare'); show('home'); loadTasks(); };
    $('d-skip').onclick = () => { if (steps[k] && steps[k].kind === 'process' && steps[k].ccp) return toast('Punto critico: non si salta, scrivi il valore misurato', 'err'); k++; if (k < steps.length) return render(); if (opts.onSkipAll && steps.every(st => st.kind === 'process')) { $('form').innerHTML = ''; return opts.onSkipAll(); } return finish(); };
    $('d-alt-ok').onclick = () => {
      if (k >= steps.length) return finish();
      const s = steps[k], raw = $('d-alt-in').value;
      if (raw === '' || isNaN(Number(raw))) return toast(s.kind === 'process' ? 'Scrivi il valore misurato' : 'Scrivi la quantità usata', 'err');
      if (s.kind === 'process') {
        const v = Number(raw), out = (s.lo != null && v < s.lo) || (s.hi != null && v > s.hi);
        if (out && !warned) { warned = true; $('d-warn').textContent = `Fuori dall'intervallo ${s.lo ?? '…'}–${s.hi ?? '…'} ${(METRIC[s.metric] || [''])[0]}. Ricontrolla e premi di nuovo Conferma.`; return; }
        return next(v);
      }
      if (!(Number(raw) >= 0)) return toast('Scrivi la quantità usata', 'err');
      const q = Number(raw) / disp(s).f, dev = Math.abs(q - s.qty) / s.qty;
      if (dev > 0.2 && !warned) { warned = true; $('d-warn').textContent = `Differenza ${Math.round(dev * 100)}% dalla ricetta. Ricontrolla e premi di nuovo Conferma.`; return; }
      next(s.unit === 'pz' ? Math.ceil(q) : Math.round(q * 1000) / 1000);
    };
    render();
  }


  // ---------- Sicurezza alimentare (v0.28) ----------
  const rpcNow = async (fn, args) => {          // online: run now and return the answer · offline (or network error): queue it
    if (!navigator.onLine) { await save([{ rpc: fn, args }]); return null; }
    const { data, error } = await sb.rpc(fn, args);
    if (error && retryable(error)) { await save([{ rpc: fn, args }]); return null; }   // v0.59: Wi-Fi up but no internet → queued, not lost
    if (error) throw error; return data;
  };
  function stepHaccpMenu() {
    $('form').innerHTML = ''; current = { code: 'HACCP:' };
    const items = [['🥛 Test antibiotici latte (CCP 1b)', 'CCP:CCP-MILK-ABX'], ['🔥 Temperatura pasta filata (CCP 3)', 'CCP:CCP-STRETCH'], ['🍶 Ricotta: affioramento (CCP 4)', 'CCP:CCP-RIC'],
      ['♨ Pastorizzazione (CCP 2)', 'CCP:CCP-PAST'], ['🔧 Pastorizzatore: verifica di inizio giornata', 'CCP:PRP-PAST-VALVE'], ['🧫 Siero-innesto: acidità', 'CCP:PRP-INNESTO'],
      ['🧂 Salamoia: concentrazione', 'CCP:PRP-BRINE'], ['💧 Cloro acqua (settimanale)', 'CCP:PRP-WATER-CL'], ['🌡 Verifica termometro sonda', 'CAL:TERM-01'], ['🌡 Verifica termometro alta temperatura', 'CAL:TERM-02'],
      ['⚗ Calibrazione pH-metro', 'CAL:PH-01'], ['🐭 Giro infestanti', 'PEST:'], ['🧪 Campione prelevato per il laboratorio', 'SAMPLE:'], ['📝 Ricopia da foglio di carta', 'PAPER:']];
    items.forEach(([t, c]) => { const b = document.createElement('button'); b.type = 'button'; b.className = 'nitem'; b.textContent = t + ' ›'; b.onclick = () => handleCode(c); $('form').append(b); });
    openForm('Sicurezza alimentare', 'Scegli cosa registrare', async () => {}); $('btn-form-save').style.display = 'none';
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
    if (cp.code === 'CCP-MILK-ABX') {
      field('v', 'Esito test rapido', 'select', { options: [['', '— scegli —'], ['0', 'Negativo'], ['1', 'POSITIVO']], limit: 'Positivo = latte non accettato' });
      field('action', 'Note / azione (se positivo)', 'text', { required: false });
    } else if (cp.unit === 'esito') {     // v0.57: pass/fail checks (verifica pastorizzatore)
      field('v', 'Esito della verifica', 'select', { options: [['', '— scegli —'], ['0', 'Ok'], ['1', 'NON ok']], limit: cp.monitoring_it || 'NON ok = non pastorizzare, chiama il responsabile' });
      field('action', 'Note / cosa hai fatto (se NON ok)', 'text', { required: false });
    } else {
      const v = field('v', `${cp.name} (${cp.unit || ''})`, 'number', { step: cp.unit === 'mg/l' ? '0.01' : '0.1', limit: lim ? `${cp.ccp_no || ''} limite ${lim} ${cp.unit || ''}`.trim() : 'Intervallo da fissare con il casaro: scrivi il valore letto' });
      if (!cp.is_ccp && cp.min_value == null && cp.max_value == null) field('action', cp.code === 'PRP-BRINE' ? 'Note: rinnovata, filtrata, rabbocco, aspetto' : 'Note (es. pH, innesto nuovo)', 'text', { required: false });
      let note = null;
      v.oninput = () => { const x = Number(v.value); const bad = (cp.min_value != null && x < cp.min_value) || (cp.max_value != null && x > cp.max_value); if (bad && !note) note = field('action', 'Fuori limite: cosa hai fatto?', 'text'); v.style.borderColor = bad ? 'var(--warn)' : ''; };
    }
    openForm(`${cp.ccp_no || ''} ${cp.name}`.trim(), lot ? 'lotto ' + lot : (cp.monitoring_it || ''), async () => {
      const value = (cp.code === 'CCP-MILK-ABX' || cp.unit === 'esito') ? (val('v') === '' ? null : Number(val('v'))) : val('v');
      if (value == null) { toast('Inserisci il valore', 'err'); throw new Error('valore'); }
      const theLot = lot || val('lot') || null;
      if (needsLot && !theLot) { toast('Scegli il lotto', 'err'); throw new Error('lotto'); }
      const r = await rpcNow('log_ccp', { p_cp_code: cp.code, p_value: value, p_staff_id: staff.id, p_batch_lot: theLot, p_action: val('action'), p_source: 'tablet', p_equipment_code: needsLot ? 'TERM-02' : null });
      await closeTask({ control_point_id: cp.id });   // v0.57: any task tied to this control point (cloro, valvola, salamoia)
      if (!r) return toast('Salvato offline');
      if (r.result === 'non_conformity') toast(`NON CONFORMITÀ${r.lot_on_hold ? ' · lotto ' + theLot + ' BLOCCATO' : ''}. ${r.corrective_it || ''}`, 'err');
      else if (r.result === 'warning') toast('Registrato · ALLERTA vicino al limite', 'err');
      else toast(`${r.ccp} registrato ✓`);
    });
  }
  // v0.77: PAPER:[<control point>] — a check written on the printed sheet (tablet or Wi-Fi down), typed in later with the time on the sheet
  const PAPER_CPS = [['🥛 Test antibiotici latte (MOD-01)', 'CCP-MILK-ABX'], ['🔧 Pastorizzatore: verifica di inizio giornata (MOD-02)', 'PRP-PAST-VALVE'], ['♨ Pastorizzazione (MOD-02)', 'CCP-PAST'],
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
  async function stepPaper(cpCode) {
    const { data: cp } = await cached('cp_' + cpCode, () => sb.from('haccp_control_points').select('*').eq('code', cpCode).eq('active', true).maybeSingle());
    if (!cp) throw new Error('Punto di controllo sconosciuto: ' + cpCode);
    const needsLot = ['CCP-STRETCH', 'CCP-RIC', 'CCP-PAST'].includes(cp.code);
    const d = field('pday', 'Data scritta sul foglio', 'date'); d.value = today(); d.max = today(); d.min = addDays(today(), -7);
    field('ptime', 'Ora scritta sul foglio', 'time');
    const w = field('pwho', 'Chi l\'ha scritto (firma sul foglio)', 'text'); w.value = staff.full_name;
    if (needsLot) field('lot', 'Lotto (come sul foglio, es. L20261012-A)', 'text');
    if (cp.code === 'CCP-MILK-ABX') field('v', 'Esito test rapido', 'select', { options: [['', '— scegli —'], ['0', 'Negativo'], ['1', 'POSITIVO']] });
    else if (cp.unit === 'esito') field('v', 'Esito della verifica', 'select', { options: [['', '— scegli —'], ['0', 'Ok'], ['1', 'NON ok']] });
    else if (cp.code === 'PRP-CLEAN') field('v', 'Sanificazione', 'select', { options: [['0', 'Fatta']] });
    else {
      const lim = [cp.min_value != null ? `≥ ${Number(cp.min_value)}` : null, cp.max_value != null ? `≤ ${Number(cp.max_value)}` : null].filter(Boolean).join(' e ');
      field('v', `${cp.name} (${cp.unit || ''})`, 'number', { limit: lim ? `limite ${lim} ${cp.unit || ''}`.trim() : '' });
    }
    field('action', 'Note / azione scritta sul foglio (se fuori limite)', 'text', { required: false });
    openForm(`📝 ${cp.ccp_no || ''} ${cp.name}`.trim(), 'Ricopia dal foglio di carta', async () => {
      const day = val('pday'), hm = val('ptime'), value = val('v') === '' || val('v') == null ? null : Number(val('v'));
      if (!day || !hm) { toast('Scrivi data e ora come sul foglio', 'err'); throw new Error('data'); }
      if (day > today() || day < addDays(today(), -7)) { toast('Si ricopiano solo fogli degli ultimi 7 giorni', 'err'); throw new Error('data'); }
      if (value == null || Number.isNaN(value)) { toast('Inserisci il valore', 'err'); throw new Error('valore'); }
      const lot = needsLot ? (val('lot') || '').trim().toUpperCase() : null;
      if (needsLot && !lot) { toast('Scrivi il lotto', 'err'); throw new Error('lotto'); }
      const r = await rpcNow('log_ccp', { p_cp_code: cp.code, p_value: value, p_logged_at: romeIso(day, hm), p_staff_id: staff.id, p_batch_lot: lot, p_action: val('action'),
                                          p_source: 'paper', p_equipment_code: needsLot ? 'TERM-02' : null, p_written_by: (val('pwho') || '').trim() || staff.full_name });
      try { await save([{ rpc: 'close_open_task', args: { p_day: day, p_code: null, p_equipment_id: null, p_control_point_id: cp.id, p_staff_id: staff.id, p_scan_event_id: null } }]); } catch (e) { console.warn('closeTask', e); }
      if (!r) toast('Salvato offline: parte appena c\'è rete');
      else if (r.result === 'non_conformity') toast(`NON CONFORMITÀ${r.lot_on_hold ? ' · lotto ' + lot + ' BLOCCATO' : ''}. ${r.corrective_it || ''}`, 'err');
      else toast(`Ricopiato ✓ ${fmtDay(day)} ${hm}`);
      stepPaperMenu(); return 'stay';   // next line of the same sheet
    });
  }
  // CAL:<code> or EQ:<thermometer|pH|scale> — internal verification against a reference
  async function stepCalibration(eq) {
    let method, pts;
    const isPh = eq.code.startsWith('PH-'), isScale = eq.kind === 'scale', isHot = eq.code === 'TERM-02', isRoom = eq.kind === 'cold_room';
    if (eq.reference_instrument) { toast('Il termometro di riferimento si tara solo in laboratorio: registra il certificato nella console HACCP', 'err'); return show('home'); }
    if (isPh) { method = 'tamponi_ph'; field('r4', 'Lettura nel tampone pH 4,01', 'number', { step: '0.01' }); field('r7', 'Lettura nel tampone pH 7,00', 'number', { step: '0.01' }); field('slope', 'Pendenza % (se lo strumento la mostra)', 'number', { step: '0.1', required: false, limit: 'Tolleranza ±0,05 pH · pendenza 95–105 %' }); }
    else if (isScale) { method = 'pesi_campione'; field('ref', 'Peso campione (kg)', 'number', { step: '0.001' }); field('read', 'Lettura bilancia (kg)', 'number', { step: '0.001' }); }
    else if (isRoom) { method = 'confronto_display'; field('ref', 'Termometro sonda TERM-01 nella cella (°C)', 'number'); field('read', 'Display della cella (°C)', 'number', { limit: 'Tolleranza ±1 °C' }); }
    else {
      method = 'confronto_riferimento';
      field('p1', isHot ? 'Acqua in ebollizione: lettura (riferimento 100 °C)' : 'Ghiaccio fondente: lettura (riferimento 0 °C)', 'number');
      field('ref', `Termometro di riferimento TERM-REF a ~${isHot ? 90 : 60} °C`, 'number', { required: false });
      field('read', `${eq.code} nello stesso punto`, 'number', { required: false, limit: `Tolleranza ±${eq.tolerance ?? 0.5} °C` });
    }
    openForm('Verifica ' + eq.name, eq.code, async () => {
      if (isPh) pts = [{ ref: 4.01, reading: val('r4') }, { ref: 7.00, reading: val('r7') }, ...(val('slope') != null ? [{ slope: val('slope') }] : [])];
      else if (isScale || isRoom) pts = [{ ref: val('ref'), reading: val('read') }];
      else pts = [{ ref: isHot ? 100 : 0, reading: val('p1') }, ...(val('ref') != null && val('read') != null ? [{ ref: val('ref'), reading: val('read') }] : [])];
      const r = await rpcNow('record_calibration_check', { p_code: eq.code, p_kind: 'verifica_interna', p_method: method, p_points: pts, p_staff_id: staff.id });
      await closeTask({ equipment_id: eq.id });
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
    st.forEach((x, k) => field('st' + k, `${x.code} · ${x.location_it}`, 'select', { options: opts }));
    field('note', 'Note / azioni', 'text', { required: false });
    openForm('Giro infestanti', 'Una postazione per riga · dentro solo trappole senza veleno', async () => {
      const findings = st.map((x, k) => ({ station: x.code, status: val('st' + k) }));
      const r = await rpcNow('record_pest_inspection', { p_by: 'interno', p_findings: findings, p_staff_id: staff.id, p_actions: val('note') });
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
      const r = await rpcNow('record_sample_taken', { p_test_code: testv, p_lot: lotv || null, p_point: val('point') || null, p_staff_id: staff.id });
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
