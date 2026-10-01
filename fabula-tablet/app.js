/* Fabula tablet — one screen per scan point. Vanilla JS, supabase-js v2, html5-qrcode.
   Every write goes through `save()` which queues offline and flushes when back online. */
(() => {
  const CFG = window.FABULA_CONFIG;
  const sb = supabase.createClient(CFG.supabaseUrl, CFG.supabaseKey, { db: { schema: 'fabula' } });
  const $ = id => document.getElementById(id);
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
  async function loadTasks() {
    const { data, error } = await sb.from('v_tasks_open').select('*');
    const box = $('tasks'); box.innerHTML = '';
    if (error) { box.textContent = 'Lista non disponibile offline'; return; }
    if (!data.length) { box.textContent = 'Tutto fatto ✓'; return; }
    data.forEach(t => {
      const d = document.createElement('div'); d.className = 'task ' + t.status;
      d.innerHTML = `<div><div>${t.title_it}</div><div class="code">${t.equipment_code || t.code}</div></div><time>${new Date(t.due_at).toTimeString().slice(0, 5)}</time>`;
      d.onclick = () => t.equipment_code ? handleCode('EQ:' + t.equipment_code) : startScan();
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
  function startScan() {
    show('scan'); $('manual').value = '';
    scanner = new Html5Qrcode('reader');
    scanner.start({ facingMode: 'environment' }, { fps: 10, qrbox: 240 }, txt => { stopScan(); handleCode(txt.trim()); }, () => {})
      .catch(() => toast('Fotocamera non disponibile: scrivi il codice', 'err'));
  }
  function stopScan() { if (scanner) { scanner.stop().catch(() => {}); scanner.clear(); scanner = null; } }
  $('btn-scan').onclick = startScan;
  $('btn-scan-cancel').onclick = () => { stopScan(); show('home'); };
  $('btn-manual').onclick = () => { stopScan(); handleCode($('manual').value.trim().toUpperCase()); };
  $('btn-form-cancel').onclick = () => show('home');

  // ---------- Route a code to its step ----------
  async function handleCode(code) {
    $('form').innerHTML = ''; current = { code };
    const [kind, ...rest] = code.split(':'); const ref = rest.join(':');
    try {
      if (kind === 'EQ') return await stepEquipment(ref);
      if (kind === 'DDT') return await stepMilk(ref);
      if (kind === 'LOT') return await stepLot(ref);
      if (kind === 'METER') return stepMeter(ref || 'elec_main');
      if (kind === 'CLEAN') return stepClean();
      if (kind === 'STAFF') { toast('Badge letto: ' + ref); return show('home'); }
      toast('Codice non riconosciuto: ' + code, 'err'); show('home');
    } catch (e) { console.error(e); toast(e.message, 'err'); show('home'); }
  }
  function openForm(title, sub, onSave) { $('f-title').textContent = title; $('f-sub').textContent = sub; current.onSave = onSave; show('form'); const f = $('form').querySelector('input,select'); if (f) f.focus(); }
  $('btn-form-save').onclick = async () => { if (!$('form').reportValidity()) return; $('btn-form-save').disabled = true; try { await current.onSave(); show('home'); loadTasks(); } finally { $('btn-form-save').disabled = false; } };

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
    openForm('Arrivo latte', 'DDT ' + ddt, async () => {
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
    if (batch) return stepPick(batch);
    if (!milk) throw new Error('Lotto sconosciuto: ' + lot);
    const { data: open } = await sb.from('batch_milk_inputs').select('batch_id, production_batches!inner(id, batch_lot, output_kg, milk_in_kg)').eq('milk_intake_id', milk.id).is('production_batches.output_kg', null).limit(1);
    if (open && open[0]) return stepBatchEnd(open[0].production_batches);
    return stepBatchStart(milk, lot);
  }
  async function stepBatchStart(milk, lot) {
    const { data: prods } = await sb.from('products').select('id, name').eq('kind', 'finished_good').eq('active', true);
    const { count } = await sb.from('production_batches').select('*', { count: 'exact', head: true }).eq('batch_date', today());
    const batchLot = 'L' + today().replace(/-/g, '') + '-' + String.fromCharCode(65 + (count || 0));
    field('product', 'Prodotto', 'select', { options: prods.map(p => [p.id, p.name]) }); field('kg', 'kg latte in caldaia', 'number', { step: '0.1' });
    openForm('Inizio lotto ' + batchLot, `latte ${lot} · disponibili ${milk.qty_kg} kg`, async () => {
      await save([scanEvent(current.code, 'batch_start', { payload: { batch_lot: batchLot, kg: val('kg') } }),
        { table: 'production_batches', row: { batch_date: today(), batch_lot: batchLot, product_id: val('product'), milk_in_kg: val('kg'), started_at: new Date().toISOString(), casaro: staff.full_name, casaro_id: staff.id, source: 'tablet' } },
        { table: 'batch_milk_inputs', row: { batch_id: '$1.id', milk_intake_id: milk.id, qty_kg: val('kg') } },
        { table: 'stock_moves', row: { product_id: await rawMilkId(), lot_number: lot, qty: -val('kg'), move_type: 'production_in', batch_id: '$1.id', source: 'tablet' } }]);
      toast('Lotto ' + batchLot + ' avviato ✓');
    });
  }
  function stepBatchEnd(b) {
    field('out', 'kg prodotto', 'number', { step: '0.1' }); field('ph', 'pH cagliata (se misurato)', 'number', { step: '0.01', required: false }); field('n', 'Etichette da stampare', 'number', { step: '1', required: false });
    openForm('Fine lotto ' + b.batch_lot, `${b.milk_in_kg} kg latte in caldaia`, async () => {
      const out = val('out'), y = Math.round(out / b.milk_in_kg * 1000) / 10;
      const { data: prod } = await sb.from('products').select('shelf_life_days').eq('id', b.product_id).single();
      const exp = new Date(); exp.setDate(exp.getDate() + (prod?.shelf_life_days || 5));
      await save([scanEvent(current.code, 'batch_end', { payload: { output_kg: out, yield_pct: y } }),
        { table: 'production_batches', update: { id: b.id }, row: { output_kg: out, curd_ph: val('ph'), finished_at: new Date().toISOString() } },
        { table: 'stock_moves', row: { product_id: b.product_id, lot_number: b.batch_lot, expiry_date: exp.toISOString().slice(0, 10), qty: out, move_type: 'production_out', batch_id: b.id, source: 'tablet' } },
        { table: 'labels', row: { kind: 'batch_lot', code: 'LOT:' + b.batch_lot, lot_number: b.batch_lot, product_id: b.product_id, batch_id: b.id, qty_printed: val('n') || 1, printed_by_id: staff.id } }]);
      toast(`Resa ${y}% · ${out} kg ✓`);
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
  let _rawId; async function rawMilkId() { if (!_rawId) { const { data } = await sb.from('products').select('id').eq('sku', 'RAW-MILK').single(); _rawId = data.id; } return _rawId; }

  if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});
  init();
})();
