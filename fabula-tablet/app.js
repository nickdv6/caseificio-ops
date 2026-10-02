/* Fabula tablet — one screen per scan point. Vanilla JS, supabase-js v2, html5-qrcode.
   Every write goes through `save()` which queues offline and flushes when back online. */
(() => {
  const CFG = window.FABULA_CONFIG;
  const sb = supabase.createClient(CFG.supabaseUrl, CFG.supabaseKey, { db: { schema: 'fabula' } });
  const $ = id => document.getElementById(id);
  // Mouse wheel over a focused number field must never change its value (keyboard only).
  document.addEventListener('wheel', e => { const a = document.activeElement; if (a && a.tagName === 'INPUT' && a.type === 'number' && e.target === a) e.preventDefault(); }, { passive: false });
  let staff = null, scanner = null, current = null;

  // ---------- UI helpers ----------
  const show = v => { document.querySelectorAll('.view').forEach(e => e.classList.toggle('active', e.id === 'v-' + v)); };
  const toast = (msg, cls = 'ok') => { const t = $('toast'); t.textContent = msg; t.className = 'toast ' + cls; t.style.display = 'block'; setTimeout(() => t.style.display = 'none', 2600); };
  const today = () => new Date().toISOString().slice(0, 10);
  const field = (id, label, type = 'number', extra = {}) => {
    const l = document.createElement('label'); l.htmlFor = id; l.textContent = label;
    const i = document.createElement(type === 'select' ? 'select' : 'input');
    i.id = id; i.name = id;
    if (type !== 'select') { i.type = type; if (type === 'number') { i.step = extra.step || '0.1'; i.inputMode = 'decimal'; } }
    if (extra.options) extra.options.forEach(([v, t]) => { const o = document.createElement('option'); o.value = v; o.textContent = t; i.appendChild(o); });
    if (extra.required !== false) i.required = true;
    $('form').append(l, i);
    if (extra.limit) { const d = document.createElement('div'); d.className = 'limit'; d.textContent = extra.limit; $('form').append(d); }
    return i;
  };
  const checklist = items => items.forEach((t, k) => { const d = document.createElement('div'); d.className = 'check'; d.innerHTML = `<input type="checkbox" id="c${k}" name="c${k}"><label for="c${k}" style="margin:0;text-transform:none;color:inherit;font-weight:400">${t}</label>`; $('form').append(d); });
  const val = id => { const e = $(id); return e ? (e.type === 'number' ? (e.value === '' ? null : Number(e.value)) : e.value) : null; };

  // ---------- Offline queue ----------
  const Q = 'fabula_queue';
  const queue = () => { try { return JSON.parse(localStorage.getItem(Q) || '[]'); } catch { return []; } };
  const setQueue = q => { try { localStorage.setItem(Q, JSON.stringify(q)); } catch {} $('pending').textContent = q.length ? `${q.length} registrazioni in attesa di rete` : ''; };
  async function save(ops) {                 // ops: [{table, row}] executed in order; later rows may reference earlier via $0.id
    if (!navigator.onLine) { setQueue([...queue(), { at: Date.now(), ops }]); toast('Salvato offline, invio appena c\'è rete'); return true; }
    try { await run(ops); return true; }
    catch (e) { console.error(e); setQueue([...queue(), { at: Date.now(), ops }]); toast('Rete assente: messo in coda', 'err'); return true; }
  }
  async function run(ops) {
    const out = [];
    for (const op of ops) {
      if (op.rpc) { const { data, error } = await sb.rpc(op.rpc, op.args); if (error) throw error; out.push(data); continue; }
      const row = JSON.parse(JSON.stringify(op.row), (k, v) => typeof v === 'string' && v.startsWith('$') ? out[Number(v.slice(1, v.indexOf('.')))][v.slice(v.indexOf('.') + 1)] : v);
      let q = op.update ? sb.from(op.table).update(row).match(op.update).select().single()
                        : sb.from(op.table).insert(row).select().single();
      const { data, error } = await q; if (error) throw error; out.push(data);
    }
    return out;
  }
  async function flush() {
    const q = queue(); if (!q.length || !navigator.onLine) return;
    const left = [];
    for (const item of q) { try { await run(item.ops); } catch (e) { console.error(e); left.push(item); } }
    setQueue(left); if (q.length !== left.length) { toast(`Inviate ${q.length - left.length} registrazioni`); loadTasks(); }
  }
  window.addEventListener('online', flush);

  // ---------- Auth ----------
  async function init() {
    const { data: { session } } = await sb.auth.getSession();
    if (!session) return show('login');
    const { data } = await sb.from('staff').select('*').eq('auth_user_id', session.user.id).maybeSingle();
    staff = data || { id: null, full_name: session.user.email, role: 'operaio' };
    $('who').textContent = staff.full_name;
    show('home'); loadTasks(); setQueue(queue()); flush();
  }
  $('btn-login').onclick = async () => {
    const { error } = await sb.auth.signInWithPassword({ email: $('email').value, password: $('pw').value });
    if (error) return toast('Accesso negato: ' + error.message, 'err'); init();
  };
  $('btn-logout').onclick = async () => { await sb.auth.signOut(); staff = null; show('login'); };

  // ---------- Tasks ----------
  async function loadSellDown() {          // lots to sell first today (or pull), with any approved promo price
    const box = $('selldown'), wrap = $('selldown-wrap'); if (!box) return;
    const { data, error } = await sb.from('v_sell_down_today').select('*');
    if (error || !data || !data.length) { wrap.style.display = 'none'; return; }
    wrap.style.display = ''; box.innerHTML = '';
    data.forEach(r => {
      const d = document.createElement('div'); d.className = 'task' + (r.days_left < 0 ? ' overdue' : '');
      const when = r.days_left < 0 ? 'SCADUTO · ritirare' : r.days_left === 0 ? 'scade oggi' : 'scade domani';
      const promo = r.promo_status === 'approved' ? ` · PROMO -${r.promo_pct}% → € ${Number(r.promo_price_eur_kg).toLocaleString('it-IT', { minimumFractionDigits: 2 })}/kg` : r.promo_status === 'pending' ? ' · promo in attesa di ok' : '';
      d.innerHTML = `<div><div>${r.name} · ${Number(r.kg).toLocaleString('it-IT')} kg</div><div class="code">${r.lot_number} · ${when}${promo}</div></div>`;
      box.append(d);
    });
  }
  async function loadNotices() {           // red banner: what is still missing tonight — tap an item to go straight to its scan
    const wrap = $('notice-wrap'); if (!wrap) return;
    const { data, error } = await sb.from('v_active_notices').select('*');
    if (error || !data || !data.length) { wrap.style.display = 'none'; return; }
    wrap.style.display = ''; wrap.innerHTML = '';
    data.forEach(n => {
      const d = document.createElement('div'); d.className = 'notice ' + n.severity;
      d.innerHTML = `<div class="nt">${n.title_it}</div>`;
      (n.items || []).forEach(it => { const b = document.createElement('button'); b.className = 'nitem'; b.textContent = it.label_it + ' ›'; b.onclick = () => handleCode(it.scan); d.append(b); });
      wrap.append(d);
    });
  }
  async function loadShifts() {            // who is clocked in right now
    const el = $('onshift'); if (!el) return;
    const { data } = await sb.from('v_open_shifts').select('full_name, hours_so_far');
    el.textContent = data && data.length ? 'In turno: ' + data.map(r => `${r.full_name} (${Number(r.hours_so_far).toLocaleString('it-IT')} h)`).join(', ') : 'Nessuno in turno · passa il badge per iniziare';
  }
  async function loadTasks() {
    loadSellDown(); loadNotices(); loadShifts(); loadShipCount();
    const { data, error } = await sb.from('v_tasks_open').select('*');
    const box = $('tasks'); box.innerHTML = '';
    if (error) { box.textContent = 'Lista non disponibile offline'; return; }
    if (!data.length) { box.textContent = 'Tutto fatto ✓'; return; }
    data.forEach(t => {
      const d = document.createElement('div'); d.className = 'task ' + t.status;
      d.innerHTML = `<div><div>${t.title_it}</div><div class="code">${t.equipment_code || t.code}</div></div><time>${new Date(t.due_at).toTimeString().slice(0, 5)}</time>`;
      d.onclick = () => t.equipment_code ? handleCode('EQ:' + t.equipment_code) : t.code === 'T-COUNT' ? stepStockCount() : t.code === 'T-CLEAN' ? handleCode('CLEAN:') : startScan();
      box.append(d);
    });
  }
  async function closeTask(filter, scanEventId) {   // marks today's matching open task done
    let q = sb.from('task_instances').select('id, task_schedules!inner(code, equipment_id, control_point_id)').in('status', ['due', 'overdue']).gte('due_at', today());
    if (filter.equipment_id) q = q.eq('task_schedules.equipment_id', filter.equipment_id);
    if (filter.control_point_id) q = q.eq('task_schedules.control_point_id', filter.control_point_id);
    if (filter.code) q = q.eq('task_schedules.code', filter.code);
    const { data } = await q.order('due_at').limit(1);
    if (data && data[0]) await sb.from('task_instances').update({ status: 'done', completed_at: new Date().toISOString(), completed_by_id: staff.id, scan_event_id: scanEventId || null }).eq('id', data[0].id);
  }
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
      d.innerHTML = `<div><div>${po.po_number} · ${po.supplier}</div><div class="code">${items}${po.status === 'partially_received' ? ' · parziale' : ''}</div></div><time>${po.expected_date ? po.expected_date.slice(8, 10) + '/' + po.expected_date.slice(5, 7) : ''}</time>`;
      d.onclick = () => { $('form').innerHTML = ''; current = { code: 'PO:' + po.po_number }; stepReceive(po.po_number).catch(e => { toast(e.message, 'err'); show('home'); }); };
      $('form').append(d);
    });
    openForm('Arrivo merce', 'Tocca l\'ordine che è arrivato', async () => {});
    $('btn-form-save').style.display = 'none';
  };
  $('btn-scan-cancel').onclick = () => { show('home'); stopScan(); };
  $('btn-manual').onclick = () => { const code = $('manual').value.trim().toUpperCase(); if (!code) return; stopScan().then(() => handleCode(code)); };
  $('manual').addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); $('btn-manual').click(); } });
  const _manual = $('btn-manual').onclick; $('btn-manual').onclick = () => { const code = $('manual').value.trim(); if (scanTarget && code) { const f = scanTarget; scanTarget = null; stopScan().then(() => f(code)); return; } return _manual && _manual(); };
  $('btn-form-cancel').onclick = () => show('home');

  // ---------- Route a code to its step ----------
  async function handleCode(code) {
    $('form').innerHTML = ''; current = { code };
    const [kind, ...rest] = code.split(':'); const ref = rest.join(':');
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
      if (kind === 'STAFF') {                       // one scan = clock in, next scan = clock out
        const { data: r, error } = await sb.rpc('toggle_shift', { p_badge: code });
        if (error) throw error;
        await save([scanEvent(code, 'task_done', { payload: { shift: r.action, hours: r.hours } })]);
        toast(r.action === 'in' ? `${r.staff}: inizio turno ✓` : `${r.staff}: fine turno ✓ · ${Number(r.hours).toLocaleString('it-IT')} h`);
        loadShifts(); return show('home');
      }
      toast('Codice non riconosciuto: ' + code, 'err'); show('home');
    } catch (e) { console.error(e); toast(e.message, 'err'); show('home'); }
  }
  function openForm(title, sub, onSave) { $('f-title').textContent = title; $('f-sub').textContent = sub; current.onSave = onSave; $('btn-form-save').style.display = ''; show('form'); const f = $('form').querySelector('input,select'); if (f) f.focus(); }
  $('btn-form-save').onclick = async () => { if (!$('form').reportValidity()) return; $('btn-form-save').disabled = true; try { const r = await current.onSave(); if (r !== 'stay') { show('home'); loadTasks(); } } finally { $('btn-form-save').disabled = false; } };

  // 1/4/7/9 — equipment: cold room, pasteurizer, thermometer → temperature; POS → Z report
  async function stepEquipment(code) {
    const { data: eq } = await sb.from('equipment').select('*').eq('code', code).single();
    if (!eq) throw new Error('Macchina sconosciuta: ' + code);
    if (eq.kind === 'pos') return stepZ(eq);
    const { data: cp } = await sb.from('haccp_control_points').select('*').eq('equipment_id', eq.id).eq('active', true).maybeSingle();
    const lim = cp ? `limite ${cp.min_value ?? ''}${cp.min_value != null && cp.max_value != null ? '–' : ''}${cp.max_value ?? ''} ${cp.unit || ''}`.replace('limite –', 'limite max ') : '';
    const t = field('temp', 'Temperatura °C', 'number', { limit: lim });
    let note = null;
    t.oninput = () => { const v = Number(t.value); const bad = cp && ((cp.max_value != null && v > cp.max_value) || (cp.min_value != null && v < cp.min_value)); if (bad && !note) { note = field('action', 'Fuori limite: cosa hai fatto?', 'text'); } t.style.borderColor = bad ? 'var(--warn)' : ''; };
    openForm(eq.name, eq.code, async () => {
      const v = val('temp'); const bad = cp && ((cp.max_value != null && v > cp.max_value) || (cp.min_value != null && v < cp.min_value));
      const ops = [scanEvent(current.code, 'temp_check', { equipment_id: eq.id, payload: { temp_c: v } })];
      if (cp) ops.push({ table: 'haccp_log', row: { control_point_id: cp.id, equipment_id: eq.id, measured_value: v, result: bad ? 'non_conformity' : 'ok', operator: staff.full_name, operator_id: staff.id, corrective_action: val('action'), source: 'tablet' } });
      if (bad) ops.push({ table: 'non_conformities', row: { severity: 'major', description: `${eq.name}: ${v} °C fuori limite`, equipment_id: eq.id, corrective_action: val('action'), opened_by_id: staff.id, haccp_log_id: '$1.id' } });
      await save(ops); await closeTask({ equipment_id: eq.id }); toast(bad ? 'Registrato come NON CONFORMITÀ' : 'Registrato ✓', bad ? 'err' : 'ok');
    });
  }
  // 9 — till close
  function stepZ(eq) {
    field('z', 'Totale scontrino Z €', 'number', { step: '0.01' }); field('cash', 'Contanti contati €', 'number', { step: '0.01', required: false }); field('card', 'Carte €', 'number', { step: '0.01', required: false });
    openForm('Chiusura cassa', eq.code, async () => {
      await save([scanEvent(current.code, 'task_done', { equipment_id: eq.id }), { table: 'pos_daily_closings', row: { closing_date: today(), rt_total_eur: val('z'), cash_counted_eur: val('cash'), card_eur: val('card'), closed_by_id: staff.id } }]);
      await closeTask({ code: 'T-Z' }); toast('Cassa chiusa ✓');
    });
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
    const { data: cp } = await sb.from('haccp_control_points').select('*').eq('code', 'PRP-CLEAN').single();
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
    const { data: sup } = await sb.from('parties').select('id, legal_name').eq('is_milk_supplier', true).eq('active', true);
    field('supplier', 'Fornitore', 'select', { options: sup.map(s => [s.id, s.legal_name]) });
    field('lot', 'Lotto / cisterna', 'text'); field('kg', 'kg (bilancia)', 'number', { step: '0.1' }); field('temp', 'Temperatura latte °C', 'number', { limit: 'latte ≤ 4 °C' });
    field('fat', 'Grasso % (se noto)', 'number', { step: '0.01', required: false }); field('photo', 'Foto DDT', 'file', { required: false });
    // today's milk plan, if the planning bot made one (approved or still proposed)
    let planTxt = '';
    try { const { data: plan } = await sb.from('milk_plans').select('milk_kg, status').eq('plan_date', today()).in('status', ['proposed', 'approved']).maybeSingle();
      if (plan) planTxt = ` · piano ${plan.status === 'approved' ? 'approvato' : 'PROPOSTO (non approvato)'}: ${Number(plan.milk_kg).toLocaleString('it-IT')} kg`; } catch {}
    openForm('Arrivo latte', 'DDT ' + ddt + planTxt, async () => {
      const accepted = val('temp') <= 4;
      const ops = [scanEvent(current.code, 'milk_receive', { payload: { kg: val('kg'), temp_c: val('temp') } }),
        { table: 'milk_intake', row: { intake_date: today(), supplier_id: val('supplier'), milk_lot: val('lot'), qty_kg: val('kg'), temperature_c: val('temp'), fat_pct: val('fat'), ddt_number: ddt, accepted, rejection_reason: accepted ? null : 'temperatura > 4 °C', received_by: staff.full_name, received_by_id: staff.id, source: 'tablet' } },
        { table: 'labels', row: { kind: 'milk_lot', code: 'LOT:' + val('lot'), lot_number: val('lot'), milk_intake_id: '$1.id', printed_by_id: staff.id } }];
      await save(ops);
      const f = $('photo').files[0]; if (f && navigator.onLine) { const path = `ddt/${today()}_${ddt}.jpg`; const { error } = await sb.storage.from('documents').upload(path, f, { upsert: true }); if (!error) await sb.from('documents').insert({ kind: 'ddt_in', storage_path: path, original_filename: f.name, mime_type: f.type, document_date: today(), uploaded_by_id: staff.id }); }
      toast(accepted ? 'Latte registrato ✓' : 'Latte registrato come RIFIUTATO', accepted ? 'ok' : 'err');
    });
  }
  // 3/5/6 — a lot label: milk lot → start/end batch; batch lot → sale or shipment
  async function stepLot(lot) {
    const { data: milk } = await sb.from('milk_intake').select('id, qty_kg, intake_date').eq('milk_lot', lot).order('intake_date', { ascending: false }).limit(1).maybeSingle();
    const { data: batch } = await sb.from('production_batches').select('*').eq('batch_lot', lot).maybeSingle();
    if (batch) return batch.output_kg == null ? stepBatchEnd(batch) : stepPick(batch);   // open batch (e.g. ricotta) → close it
    if (!milk) throw new Error('Lotto sconosciuto: ' + lot);
    const { data: open } = await sb.from('batch_milk_inputs').select('batch_id, production_batches!inner(id, batch_lot, product_id, output_kg, milk_in_kg, input_kind)').eq('milk_intake_id', milk.id).is('production_batches.output_kg', null).limit(1);
    if (open && open[0]) return stepBatchEnd(open[0].production_batches);
    return stepBatchStart(milk, lot);
  }
  async function stepBatchStart(milk, lot) {
    const { data: prods } = await sb.from('products').select('id, name').eq('kind', 'finished_good').eq('active', true);
    const { count } = await sb.from('production_batches').select('*', { count: 'exact', head: true }).eq('batch_date', today());
    const batchLot = 'L' + today().replace(/-/g, '') + '-' + String.fromCharCode(65 + (count || 0));
    field('product', 'Prodotto', 'select', { options: prods.map(p => [p.id, p.name]) });
    field('mu', 'Unità', 'select', { options: [['kg', 'kg (bilancia)'], ['l', 'litri (contalitri)']] });
    field('kg', 'Latte in caldaia', 'number', { step: '0.1' });
    openForm('Inizio lotto ' + batchLot, `latte ${lot} · disponibili ${milk.qty_kg} kg`, async () => {
      const kg = val('mu') === 'l' ? Math.round(val('kg') * MILK_DENSITY * 10) / 10 : val('kg');
      const product = val('product');
      await save([scanEvent(current.code, 'batch_start', { payload: { batch_lot: batchLot, kg, entered: val('kg'), unit: val('mu') } }),
        { table: 'production_batches', row: { batch_date: today(), batch_lot: batchLot, product_id: product, milk_in_kg: kg, started_at: new Date().toISOString(), casaro: staff.full_name, casaro_id: staff.id, source: 'tablet' } },
        { table: 'batch_milk_inputs', row: { batch_id: '$1.id', milk_intake_id: milk.id, qty_kg: kg } },
        { table: 'stock_moves', row: { product_id: await rawMilkId(), lot_number: lot, qty: -kg, move_type: 'production_in', batch_id: '$1.id', source: 'tablet' } }]);
      const steps = await doseSteps(product, 'start', { milk: kg });
      if (!steps.length) { toast('Lotto ' + batchLot + ' avviato ✓'); return; }
      runDosing(`Dosaggio ${batchLot} · ${kg} kg latte`, batchLot, steps, async () => toast('Lotto ' + batchLot + ' avviato, dosaggio confermato ✓'));
      return 'stay';
    });
  }
  async function stepBatchEnd(b) {
    const { data: prod } = await sb.from('products').select('shelf_life_days, byproduct_product_id').eq('id', b.product_id).single();
    const byp = b.input_kind !== 'whey' ? prod?.byproduct_product_id : null;
    field('out', 'kg prodotto', 'number', { step: '0.1' }); field('ph', 'pH cagliata (se misurato)', 'number', { step: '0.01', required: false }); field('n', 'Etichette da stampare', 'number', { step: '1', required: false });
    if (byp) field('whey', 'Siero per ricotta, kg (0 = niente ricotta)', 'number', { step: '1', required: false });
    openForm('Fine lotto ' + b.batch_lot, `${b.milk_in_kg} kg ${b.input_kind === 'whey' ? 'siero' : 'latte'} in caldaia`, async () => {
      const out = val('out'), ph = val('ph'), n = val('n'), whey = byp ? (val('whey') || 0) : 0, y = Math.round(out / b.milk_in_kg * 1000) / 10;
      const exp = new Date(); exp.setDate(exp.getDate() + (prod?.shelf_life_days || 5));
      const code = current.code;
      const startRicotta = async () => {
        const ricLot = 'R' + b.batch_lot.slice(1);
        await save([{ rpc: 'start_byproduct_batch', args: { p_parent_lot: b.batch_lot, p_whey_kg: whey, p_staff_id: staff.id } }]);
        const done = () => toast(`Ricotta ${ricLot} avviata ✓ · a fine lotto scansiona LOT:${ricLot}`);
        const steps = await doseSteps(byp, 'start', { milk: whey });
        if (!steps.length) { done(); return; }
        runDosing(`Ricotta ${ricLot} · ${whey} kg siero`, ricLot, steps, async () => done());
        return 'stay';
      };
      const close = async () => {
        const ops = [scanEvent(code, 'batch_end', { payload: { output_kg: out, yield_pct: y, whey_to_byproduct_kg: whey } }),
          { table: 'production_batches', update: { id: b.id }, row: { output_kg: out, curd_ph: ph, finished_at: new Date().toISOString() } },
          { table: 'stock_moves', row: { product_id: b.product_id, lot_number: b.batch_lot, expiry_date: exp.toISOString().slice(0, 10), qty: out, move_type: 'production_out', batch_id: b.id, source: 'tablet' } }];
        if (b.input_kind !== 'whey')   // ricotta lot label is printed when the batch starts
          ops.push({ table: 'labels', row: { kind: 'batch_lot', code: 'LOT:' + b.batch_lot, lot_number: b.batch_lot, product_id: b.product_id, batch_id: b.id, qty_printed: n || 1, printed_by_id: staff.id } });
        await save(ops);
        toast(`Resa ${y}% · ${out} kg ✓`);
        if (whey > 0) return startRicotta();
      };
      const steps = await doseSteps(b.product_id, 'close', { milk: b.milk_in_kg, out });
      if (!steps.length) return close();
      runDosing(`Confezionamento ${b.batch_lot} · ${out} kg`, b.batch_lot, steps, close);
      return 'stay';
    });
  }
  // 6 — sale at the counter or shipment line
  async function stepPick(b) {
    field('mode', 'Operazione', 'select', { options: [['sale', 'Vendita banco'], ['ship', 'Spedizione']] }); field('kg', 'kg', 'number', { step: '0.01' });
    const { data: prod } = await sb.from('products').select('*').eq('id', b.product_id).single();
    const { data: custs } = await sb.from('parties').select('id, legal_name').in('type', ['customer', 'both']).eq('active', true);
    const c = field('cust', 'Cliente (spedizione)', 'select', { options: [['', '—'], ...custs.map(x => [x.id, x.legal_name])], required: false });
    openForm(prod.name, 'lotto ' + b.batch_lot, async () => {
      const kg = val('kg');
      if (val('mode') === 'sale') {
        const price = prod.default_sale_price_eur || 0, total = Math.round(kg * price * 100) / 100, n = 'POS-' + Date.now();
        await save([scanEvent(current.code, 'pick', { payload: { kg, mode: 'sale' } }),
          { table: 'sales_orders', row: { order_number: n, channel: 'store_pos', order_date: today(), subtotal_eur: total, total_eur: total, source: 'tablet' } },
          { table: 'sales_order_lines', row: { sales_order_id: '$1.id', product_id: prod.id, lot_number: b.batch_lot, qty: kg, unit_price_eur: price, iva_rate: prod.iva_rate || 4 } },
          { table: 'stock_moves', row: { product_id: prod.id, lot_number: b.batch_lot, qty: -kg, move_type: 'sale', sales_order_id: '$1.id', source: 'tablet' } }]);
        toast(`Venduti ${kg} kg · € ${total} ✓`);
      } else {
        if (!val('cust')) { toast('Scegli il cliente', 'err'); throw new Error('cliente'); }
        const ddt = 'DDT-' + today().replace(/-/g, '') + '-' + Date.now().toString().slice(-4);
        await save([scanEvent(current.code, 'pick', { payload: { kg, mode: 'ship' } }),
          { table: 'shipments', row: { ddt_number: ddt, customer_id: val('cust'), status: 'picked', driver_id: staff.id } },
          { table: 'shipment_lines', row: { shipment_id: '$1.id', product_id: prod.id, lot_number: b.batch_lot, qty: kg } },
          { table: 'stock_moves', row: { product_id: prod.id, lot_number: b.batch_lot, qty: -kg, move_type: 'sale', source: 'tablet' } }]);
        toast(`Spedizione ${ddt} · ${kg} kg ✓`);
      }
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
      h.innerHTML = `<div class="scan">${l.name}</div><div>ordinati ${Number(l.qty_ordered).toLocaleString('it-IT')} ${l.unit}${Number(l.qty_received) > 0 ? ` · già ricevuti ${Number(l.qty_received).toLocaleString('it-IT')}` : ''} · listino € ${Number(l.unit_price_eur).toLocaleString('it-IT', { minimumFractionDigits: 2, maximumFractionDigits: 4 })}/${l.unit}</div>`;
      $('form').append(h);
      const q = field('q' + i, `Ricevuti (${l.unit})`, 'number', { step: l.unit === 'pz' ? '1' : '0.01' }); q.value = l.remaining;
      field('lot' + i, 'Lotto fornitore', 'text', { required: false });
      const e = field('exp' + i, 'Scadenza (se stampata)', 'date', { required: false });
      if (l.shelf_life_days) { const d = new Date(); d.setDate(d.getDate() + l.shelf_life_days); e.value = d.toISOString().slice(0, 10); }
      field('pr' + i, `Prezzo sul DDT €/${l.unit} (solo se diverso)`, 'number', { step: '0.0001', required: false });
    });
    field('ddt', 'Numero DDT', 'text', { required: false }); field('photo', 'Foto DDT', 'file', { required: false });
    openForm(po.po_number, po.supplier + (po.status === 'partially_received' ? ' · consegna parziale in corso' : ''), async () => {
      const lines = po.lines.map((l, i) => ({ sku: l.sku, qty: val('q' + i), lot: val('lot' + i) || null, expiry: val('exp' + i) || null, unit_price: val('pr' + i) }))
        .filter(x => x.qty && x.qty > 0);
      if (!lines.length) { toast('Inserisci almeno una quantità ricevuta', 'err'); throw new Error('vuoto'); }
      const over = lines.filter(x => { const l = po.lines.find(p => p.sku === x.sku); return x.qty > Number(l.remaining) * 1.02; });
      if (over.length && !current.overOk) { current.overOk = true; toast('Quantità superiore all\'ordine: ricontrolla e premi Salva di nuovo', 'err'); throw new Error('over'); }
      const ddt = val('ddt') || null;
      await save([scanEvent(current.code, 'goods_receive', { payload: { po_number: po.po_number, ddt, lines } }),
        { rpc: 'receive_purchase_order', args: { p_po_number: po.po_number, p_lines: lines, p_staff_id: staff.id, p_ddt: ddt } }]);
      const f = $('photo').files[0];
      if (f && navigator.onLine) { const path = `ddt/${today()}_${po.po_number}.jpg`; const { error: ue } = await sb.storage.from('documents').upload(path, f, { upsert: true });
        if (!ue) await sb.from('documents').insert({ kind: 'ddt_in', storage_path: path, original_filename: f.name, mime_type: f.type, document_date: today(), related_table: 'purchase_orders', related_id: po.id, uploaded_by_id: staff.id }); }
      const tot = lines.reduce((a, x) => a + x.qty, 0);
      toast(`Ricevuto ${po.po_number} · ${tot.toLocaleString('it-IT')} pezzi/kg in magazzino ✓`);
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
    const { data, error } = await sb.from('v_orders_to_ship').select('*');
    if (error) { toast('Lista spedizioni non disponibile offline', 'err'); return; }
    if (!data || !data.length) { toast('Niente da spedire'); return; }
    data.forEach(o => {
      const d = document.createElement('div'); d.className = 'task';
      const items = (o.lines || []).map(l => `${fmtKg(l.qty)} ${l.unit} ${l.name}`).join(' · ');
      const addr = o.ship_address ? [o.ship_address.city, o.ship_address.zip].filter(Boolean).join(' ') : (o.ship_city || '');
      d.innerHTML = `<div><div>${o.channel === 'shopify' ? '🛒 ' : '🏬 '}${o.order_number} · ${o.customer || (o.ship_address && o.ship_address.name) || 'cliente online'}${addr ? ' · ' + addr : ''}</div><div class="code">${items || 'nessuna riga collegata al magazzino'}${o.unmapped ? ' · ⚠ ' + o.unmapped + ' righe non collegate' : ''}</div></div><time>${fmtDay(o.due_date)}</time>`;
      d.onclick = () => stepPack(o).catch(e => { toast(e.message, 'err'); show('home'); });
      $('form').append(d);
    });
    openForm('Da spedire', 'Tocca l\'ordine da preparare · online prima, poi ingrosso', async () => {});
    $('btn-form-save').style.display = 'none';
  }
  async function stepPack(o) {
    $('form').innerHTML = ''; current = { code: 'SHIP:' + o.order_number, force: false };
    const { data: cfg } = await sb.from('settings').select('key, value').in('key', ['ship.default_carrier', 'ship.wholesale_carrier', 'ship.tolerance_pct']);
    const S = Object.fromEntries((cfg || []).map(r => [r.key, r.value]));
    if (!(o.lines || []).length) throw new Error('Ordine senza righe collegate al magazzino: collega i prodotti Shopify in Configurazione → Vendite');
    const rows = [];
    o.lines.forEach((l, i) => {
      const card = document.createElement('div'); card.className = 'card'; card.style.marginTop = '14px';
      const sug = (l.suggested || [])[0];
      card.innerHTML = `<div class="scan">${l.name}</div><div>ordinati <b>${fmtKg(l.qty)} ${l.unit}</b>${sug ? ` · lotto consigliato <b>${sug.lot}</b> (scade ${fmtDay(sug.expiry)}, ${fmtKg(sug.on_hand)} ${l.unit} in giacenza)` : ' · <span style="color:var(--warn)">nessun lotto in giacenza</span>'}</div>`;
      $('form').append(card);
      const lot = field('lot' + i, 'Lotto (scansiona l\'etichetta o conferma quello consigliato)', 'select', { options: (l.suggested || []).map(x => [x.lot, `${x.lot} · scade ${fmtDay(x.expiry)} · ${fmtKg(x.on_hand)} ${l.unit}`]) });
      const scanBtn = document.createElement('button'); scanBtn.type = 'button'; scanBtn.className = 'btn secondary'; scanBtn.textContent = '📷 Scansiona lotto'; scanBtn.style.marginTop = '6px';
      scanBtn.onclick = () => { scanTarget = code => { const v = code.replace(/^LOT:/i, '').trim(); const ok = [...lot.options].some(op => op.value === v); if (!ok) { const op = document.createElement('option'); op.value = v; op.textContent = v + ' · non tra i consigliati'; lot.append(op); } lot.value = v; lot.style.borderColor = ok ? 'var(--ok)' : 'var(--warn)'; show('form'); toast(ok ? 'Lotto confermato ✓' : 'Lotto diverso da quelli consigliati: controlla la scadenza', ok ? '' : 'err'); }; startScan(); };
      $('form').append(scanBtn);
      const q = field('q' + i, `Peso effettivo (${l.unit})`, 'number', { step: '0.01' }); q.value = Number(l.qty); q.dataset.weighed = '0';
      q.oninput = () => { q.dataset.weighed = '0'; };
      const w = scaleButton(q, 'net');
      $('form').append(w);
      rows.push({ l, lot, q });
    });
    const g = field('gross', 'Peso lordo collo (kg, facoltativo)', 'number', { step: '0.01', required: false }); $('form').append(scaleButton(g, 'gross'));
    const carrier = field('carrier', 'Vettore', 'text', { required: false }); carrier.value = o.channel === 'wholesale' ? (S['ship.wholesale_carrier'] || 'Consegna diretta') : (S['ship.default_carrier'] || 'BRT');
    field('tracking', 'Tracking / n. lettera di vettura (se già stampata)', 'text', { required: false });
    field('note', 'Note', 'text', { required: false });
    openForm(`Prepara ${o.order_number}`, `${o.customer || 'cliente online'} · ${o.lines.length} righe · tolleranza ±${S['ship.tolerance_pct'] || 5}%`, async () => {
      const lines = rows.map(r => ({ product_id: r.l.product_id, lot_number: r.lot.value, qty: Number(r.q.value), weighed: r.q.dataset.weighed === '1' }));
      if (lines.some(x => !x.lot_number)) { toast('Manca il lotto su una riga', 'err'); throw new Error('lot'); }
      const { data, error } = await sb.rpc('pack_order', { p_order_id: o.order_id, p_lines: lines, p_staff_id: staff.id, p_gross_kg: val('gross'), p_carrier: val('carrier') || null, p_tracking: val('tracking') || null, p_notes: val('note') || null, p_force: current.force });
      if (error) { toast(error.message, 'err'); throw error; }
      if (data && data.needs_confirm) { current.force = true; toast(`Pesati ${fmtKg(data.packed_kg)} kg contro ${fmtKg(data.ordered_kg)} ordinati (${data.variance_pct > 0 ? '+' : ''}${data.variance_pct}%): ricontrolla e premi Salva di nuovo per confermare`, 'err'); throw new Error('confirm'); }
      await save([scanEvent(current.code, 'pick', { payload: { order: o.order_number, ddt: data.ddt_number, kg: data.packed_kg, lines: lines.length } })]);
      // done: show the print buttons instead of going home
      $('form').innerHTML = ''; $('btn-form-save').style.display = 'none';
      const c = document.createElement('div'); c.className = 'card';
      c.innerHTML = `<div class="scan">✓ ${data.ddt_number}</div><div>${o.order_number} · ${fmtKg(data.packed_kg)} kg in ${data.lines} righe · ${data.carrier}${data.needs_shopify_fulfilment ? '<br>Shopify verrà aggiornato dal bot (cliente avvisato con il tracking).' : '<br>Ordine ingrosso chiuso.'}</div>`;
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
  function runDosing(title, batchLot, steps, onDone) {
    let k = 0, warned = false;
    const btns = ['d-ok', 'd-diff', 'd-alt-ok'].map($);
    const render = () => {
      const s = steps[k]; warned = false;
      $('d-title').textContent = title; $('d-prog').textContent = `Passo ${k + 1} di ${steps.length}`;
      $('d-bar').style.width = (k / steps.length * 100) + '%';
      $('d-name').textContent = s.name; $('d-qty').textContent = fmtQty(s.qty, s);
      $('d-instr').textContent = s.instruction_it || ''; $('d-src').textContent = s.source === 'placeholder' ? 'ricetta provvisoria' : '';
      $('d-alt').style.display = 'none'; $('d-alt-in').value = ''; $('d-alt-u').textContent = disp(s).u; $('d-warn').textContent = '';
      btns.forEach(b => b.disabled = false); show('dose');
    };
    const next = async q => {
      const s = steps[k]; btns.forEach(b => b.disabled = true);
      try { await save([{ rpc: 'record_batch_consumable', args: { p_batch_lot: batchLot, p_sku: s.sku, p_qty: q, p_qty_standard: s.qty, p_staff_id: staff.id } }]); }
      finally { btns.forEach(b => b.disabled = false); }
      k++; if (k < steps.length) return render();
      $('d-bar').style.width = '100%'; const r = await onDone(); if (r !== 'stay') { show('home'); loadTasks(); }   // 'stay' = next sequence (e.g. ricotta) took over
    };
    $('d-ok').onclick = () => next(steps[k].qty);
    $('d-diff').onclick = () => { $('d-alt').style.display = 'block'; $('d-alt-in').focus(); };
    $('d-alt-ok').onclick = () => {
      const s = steps[k], raw = $('d-alt-in').value;
      if (raw === '' || !(Number(raw) >= 0)) return toast('Scrivi la quantità usata', 'err');
      const q = Number(raw) / disp(s).f, dev = Math.abs(q - s.qty) / s.qty;
      if (dev > 0.2 && !warned) { warned = true; $('d-warn').textContent = `Differenza ${Math.round(dev * 100)}% dalla ricetta. Ricontrolla e premi di nuovo Conferma.`; return; }
      next(s.unit === 'pz' ? Math.ceil(q) : Math.round(q * 1000) / 1000);
    };
    render();
  }

  let _rawId; async function rawMilkId() { if (!_rawId) { const { data } = await sb.from('products').select('id').eq('sku', 'RAW-MILK').single(); _rawId = data.id; } return _rawId; }

  if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});
  init();
})();
