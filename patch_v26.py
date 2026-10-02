import sys
root = sys.argv[1]; T = root + '/fabula-tablet/'
def must(s, a, b):
    assert s.count(a) == 1, (s.count(a), a[:100]); return s.replace(a, b)

# ====================== tablet ======================
h = open(T + 'index.html').read()
h = must(h, '''    <div class="dose-name" id="d-name"></div>
    <div class="dose-qty" id="d-qty"></div>''', '''    <div class="dose-name" id="d-name"></div>
    <div class="dose-src" id="d-mach"></div>
    <div class="dose-qty" id="d-qty"></div>''')
h = must(h, '''    <label for="d-alt-in">Quantità usata</label>''', '''    <label for="d-alt-in" id="d-alt-l">Quantità usata</label>''')
h = must(h, '''    <button class="btn" id="d-alt-ok">Conferma</button>''', '''    <button class="btn" id="d-alt-ok">Conferma</button>
  </div>
  <div style="text-align:center;margin-top:10px"><button class="btn secondary" id="d-skip" style="display:none">Salta questo passo</button> <button class="btn secondary" id="d-pause" style="display:none">Continua più tardi</button>''')
open(T + 'index.html', 'w').write(h)

s = open(T + 'app.js').read()
# --- batch start: preset picker + merged start sequence ---
s = must(s, '''    field('product', 'Prodotto', 'select', { options: prods.map(p => [p.id, p.name]) });
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
    });''', '''    const prodSel = field('product', 'Prodotto', 'select', { options: prods.map(p => [p.id, p.name]) });
    const presets = await loadPresets();
    const preSel = field('preset', 'Impostazioni di processo', 'select', { options: [['', '—']], required: false });
    const fillPresets = () => { const mine = presetsFor(presets, prodSel.value); preSel.innerHTML = mine.length ? mine.map(p => `<option value="${p.id}" ${p.is_default ? 'selected' : ''}>${p.name}${p.is_default ? ' · predefinito' : ''}</option>`).join('') : '<option value="">nessun preset: solo dosi</option>'; };
    prodSel.onchange = fillPresets; fillPresets();
    field('mu', 'Unità', 'select', { options: [['kg', 'kg (bilancia)'], ['l', 'litri (contalitri)']] });
    field('kg', 'Latte in caldaia', 'number', { step: '0.1' });
    openForm('Inizio lotto ' + batchLot, `latte ${lot} · disponibili ${milk.qty_kg} kg`, async () => {
      const kg = val('mu') === 'l' ? Math.round(val('kg') * MILK_DENSITY * 10) / 10 : val('kg');
      const product = val('product'), preset = val('preset') || null;
      await save([scanEvent(current.code, 'batch_start', { payload: { batch_lot: batchLot, kg, entered: val('kg'), unit: val('mu'), preset_id: preset } }),
        { table: 'production_batches', row: { batch_date: today(), batch_lot: batchLot, product_id: product, milk_in_kg: kg, preset_id: preset, started_at: new Date().toISOString(), casaro: staff.full_name, casaro_id: staff.id, source: 'tablet' } },
        { table: 'batch_milk_inputs', row: { batch_id: '$1.id', milk_intake_id: milk.id, qty_kg: kg } },
        { table: 'stock_moves', row: { product_id: await rawMilkId(), lot_number: lot, qty: -kg, move_type: 'production_in', batch_id: '$1.id', source: 'tablet' } }]);
      const steps = mergeSteps(await doseSteps(product, 'start', { milk: kg }), processSteps(presets, preset, 'start'));
      if (!steps.length) { toast('Lotto ' + batchLot + ' avviato ✓'); return; }
      runDosing(`Avvio ${batchLot} · ${kg} kg latte`, batchLot, steps, async () => toast('Lotto ' + batchLot + ' avviato ✓ · scansiona di nuovo il lotto per la lavorazione'));
      return 'stay';
    });''')
# --- open batch: working phase (make) before the close ---
s = must(s, '''    if (batch) return batch.output_kg == null ? stepBatchEnd(batch) : stepPick(batch);   // open batch (e.g. ricotta) → close it''',
'''    if (batch) return batch.output_kg == null ? stepBatchWork(batch) : stepPick(batch);   // open batch → working steps, then close''')
s = must(s, '''    if (open && open[0]) return stepBatchEnd(open[0].production_batches);
    return stepBatchStart(milk, lot);
  }''', '''    if (open && open[0]) return stepBatchWork(open[0].production_batches);
    return stepBatchStart(milk, lot);
  }
  // 5b — the 'make' steps of the preset (maturazione, filatura, formatura…): run once per batch, then the lot closes
  async function stepBatchWork(b) {
    const presets = await loadPresets();
    const preset = b.preset_id || (presetsFor(presets, b.product_id).find(p => p.is_default) || {}).id;
    const make = processSteps(presets, preset, 'make');
    if (!make.length) return stepBatchEnd(b);
    const { data: done } = await sb.from('batch_step_logs').select('step_id').eq('batch_id', b.id);
    const doneIds = new Set((done || []).map(d => d.step_id));
    const left = make.filter(st => !doneIds.has(st.step_id));
    if (!left.length) return stepBatchEnd(b);
    runDosing(`Lavorazione ${b.batch_lot}`, b.batch_lot, left, async () => { toast('Lavorazione registrata ✓ · a fine lotto scansiona di nuovo LOT:' + b.batch_lot); }, { skippable: true, onSkipAll: () => stepBatchEnd(b) });
  }''')
# --- batch end: merged close sequence ---
s = must(s, '''      const steps = await doseSteps(b.product_id, 'close', { milk: b.milk_in_kg, out });
      if (!steps.length) return close();''', '''      const presets = await loadPresets();
      const steps = mergeSteps(await doseSteps(b.product_id, 'close', { milk: b.milk_in_kg, out }), processSteps(presets, b.preset_id || (presetsFor(presets, b.product_id).find(p => p.is_default) || {}).id, 'close'));
      if (!steps.length) return close();''')
# --- presets cache + helpers, placed before doseSteps ---
s = must(s, '''  async function doseSteps(productId, phase, base) {''', '''  const PK = 'perla_process_v1';
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
    return { kind: 'process', step_id: r.step_id, step_order: r.step_order, name: r.name_it, machine: r.equipment_code ? `${r.equipment_name} · ${r.equipment_code}` : '', target_txt: r.target_txt || '', instruction_it: r.instruction_it, metric: r.record_metric, target: t == null ? null : Number(t), lo: lo == null ? null : Number(lo), hi: hi == null ? null : Number(hi) };
  }) : [];
  const mergeSteps = (doses, proc) => [...doses.map(d => ({ ...d, kind: 'dose' })), ...proc].sort((a, b) => a.step_order - b.step_order);
  async function doseSteps(productId, phase, base) {''')
# --- runDosing: dose steps + process steps on the same screen ---
i = s.index('  function runDosing(title, batchLot, steps, onDone) {'); j = s.index('\n  }\n', i) + 4
s = s[:i] + r'''  function runDosing(title, batchLot, steps, onDone, opts = {}) {
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
      $('d-alt').style.display = 'none'; $('d-alt-in').value = ''; $('d-warn').textContent = '';
      btns.forEach(b => b.disabled = false); show('dose');
    };
    const finish = async () => { $('d-bar').style.width = '100%'; const r = await onDone(); if (r !== 'stay') { show('home'); loadTasks(); } };   // 'stay' = next sequence took over
    const next = async q => {
      const s = steps[k]; btns.forEach(b => b.disabled = true);
      try {
        if (s.kind === 'process') await save([{ rpc: 'log_batch_step', args: { p_batch_lot: batchLot, p_step_id: s.step_id, p_actual: q, p_staff_id: staff.id } }]);
        else await save([{ rpc: 'record_batch_consumable', args: { p_batch_lot: batchLot, p_sku: s.sku, p_qty: q, p_qty_standard: s.qty, p_staff_id: staff.id } }]);
      } finally { btns.forEach(b => b.disabled = false); }
      k++; if (k < steps.length) return render();
      return finish();
    };
    $('d-ok').onclick = () => { const s = steps[k]; next(s.kind === 'process' ? s.target : s.qty); };
    $('d-diff').onclick = () => { $('d-alt').style.display = 'block'; $('d-alt-in').focus(); };
    $('d-pause').onclick = () => { toast('I passi confermati sono salvati: scansiona di nuovo il lotto per continuare'); show('home'); loadTasks(); };
    $('d-skip').onclick = () => { k++; if (k < steps.length) return render(); if (opts.onSkipAll && steps.every(st => st.kind === 'process')) { $('form').innerHTML = ''; return opts.onSkipAll(); } return finish(); };
    $('d-alt-ok').onclick = () => {
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
''' + s[j:]
open(T + 'app.js', 'w').write(s)
sw = open(T + 'sw.js').read(); sw = must(sw, "const CACHE = 'perla-v14';", "const CACHE = 'perla-v15';"); open(T + 'sw.js', 'w').write(sw)

# ====================== console: Ricette → Processo e preset ======================
c = open(T + 'console.html').read()
c = must(c, '''    <div id="recipes"></div>''', '''    <div id="recipes"></div>
    <h3 style="margin-top:22px">Processo e preset macchine</h3>
    <div class="hint">Per ogni prodotto puoi salvare più configurazioni con nome (temperature, tempi, velocità, pH per ogni passo). Il casaro sceglie il preset all'avvio del lotto; il tablet mostra i valori obiettivo passo per passo e registra quelli effettivi. Copia un preset per provare una variante senza perdere quello che funziona.</div>
    <div id="presets"></div>''')
c = must(c, "table.rec td{", "table.rec input[type=number].n{width:50px;padding:5px 4px}table.rec select.phs{width:112px}table.rec td .rng{opacity:.55;margin:0 1px}table.rec input[type=text].w{min-width:120px;width:140px}table.rec input[type=text].sh{min-width:70px;width:70px}table.rec select.eq{max-width:170px}table.rec tr.stepsub td{border-top:none;padding-top:0;color:var(--muted);font-size:.85rem}table.rec tr.stepsub input[type=text]{width:100%;min-width:0}.pchip{display:inline-block;padding:6px 12px;border:1px solid var(--rule);border-radius:999px;margin:0 6px 6px 0;cursor:pointer;background:var(--tile);font-size:13px}.pchip.on{background:var(--accent);color:var(--accent-fg);border-color:var(--accent)}.pchip small{opacity:.75}\ntable.rec td{")
open(T + 'console.html', 'w').write(c)

j = open(T + 'console.js').read()
j = must(j, "ricette: () => loadRecipes() };", "ricette: () => { loadRecipes(); loadPresets(); } };")
j = must(j, "  async function loadRecipes() {", r'''  // ---------- process presets (machine settings per step) ----------
  const PPHASE = { start: 'Avvio', make: 'Lavorazione', close: 'Chiusura' };
  const PMETRIC = { none: '—', temp: 'temperatura', duration: 'durata', ph: 'pH', speed: 'velocità' };
  const chosenPreset = {};
  async function loadPresets() {
    const box = $('presets'); box.innerHTML = '';
    const [{ data: res, error }, { data: steps }, { data: eq }] = await Promise.all([
      sb.from('v_preset_results').select('*').order('product_sku').order('created_at'),
      sb.from('v_process_steps').select('*').eq('active', true).order('phase').order('step_order'),
      sb.from('equipment').select('id, code, name').eq('active', true).order('code')]);
    if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    const byProd = {}; (res || []).forEach(r => (byProd[r.product_id] = byProd[r.product_id] || []).push(r));
    Object.values(byProd).forEach(list => {
      const prod = list[0];
      const card = document.createElement('div'); card.className = 'card'; card.style.marginBottom = '16px';
      card.innerHTML = `<h3>${esc(prod.product_name)} <small class="status">${esc(prod.product_sku)}</small></h3>`;
      const active = list.filter(p => p.active);
      const cur = chosenPreset[prod.product_id] && active.find(p => p.preset_id === chosenPreset[prod.product_id]) ? chosenPreset[prod.product_id] : (active.find(p => p.is_default) || active[0] || {}).preset_id;
      const chips = document.createElement('div');
      active.forEach(p => { const b = document.createElement('span'); b.className = 'pchip' + (p.preset_id === cur ? ' on' : ''); b.innerHTML = `${p.is_default ? '★ ' : ''}${esc(p.name)} <small>· ${p.n_steps} passi${p.n_batches ? ` · ${p.n_batches} lotti · resa ${p.avg_yield_pct ?? '—'}%` : ''}</small>`; b.onclick = () => { chosenPreset[prod.product_id] = p.preset_id; loadPresets(); }; chips.append(b); });
      card.append(chips);
      const P = active.find(p => p.preset_id === cur); if (!P) { card.append(Object.assign(document.createElement('div'), { className: 'empty', textContent: 'Nessun preset attivo.' })); box.append(card); return; }
      const meta = document.createElement('div'); meta.className = 'status'; meta.style.margin = '6px 0 10px';
      meta.innerHTML = `${esc(P.description || '')}${P.based_on_name ? ` · da «${esc(P.based_on_name)}»` : ''}${P.n_batches ? ` · <b>${P.n_batches} lotti</b>, resa media <b>${P.avg_yield_pct ?? '—'}%</b>, pH medio ${P.avg_curd_ph ?? '—'}, scostamento medio dai valori obiettivo ${P.avg_abs_dev_pct ?? '—'}%` : ' · nessun lotto ancora prodotto con questo preset'}`;
      card.append(meta);
      const bar = document.createElement('div'); bar.style.margin = '0 0 10px';
      const mk = (t, cls, fn, title) => { const b = document.createElement('button'); b.className = 'btn sm ' + cls; b.textContent = t; b.title = title || ''; b.style.marginRight = '6px'; b.onclick = async () => { b.disabled = true; try { await fn(); } catch (e) { toast(e.message, 'err'); } b.disabled = false; }; return b; };
      bar.append(mk('Copia come nuovo preset', '', async () => { const name = prompt('Nome del nuovo preset (es. "Estate · filatura 94")'); if (!name) return; const { data, error } = await sb.rpc('clone_preset', { p_preset_id: P.preset_id, p_name: name, p_staff_id: null }); if (error) throw error; chosenPreset[prod.product_id] = data; toast('Preset copiato: modifica i passi e provalo sul prossimo lotto'); loadPresets(); }, 'Duplica tutti i passi in un preset con un altro nome'));
      if (!P.is_default) bar.append(mk('Rendi predefinito', 'sec', async () => { const { error } = await sb.rpc('set_default_preset', { p_preset_id: P.preset_id }); if (error) throw error; toast('Preset predefinito aggiornato'); loadPresets(); }, 'Il tablet lo propone all\'avvio del lotto'));
      if (!P.is_default) bar.append(mk('Archivia', 'sec', async () => { if (!confirm('Archiviare il preset «' + P.name + '»? I lotti già prodotti restano collegati.')) return; await upd('process_presets', { id: P.preset_id }, { active: false, updated_at: new Date().toISOString() }); toast('Preset archiviato'); loadPresets(); }));
      card.append(bar);
      const mine = (steps || []).filter(s => s.preset_id === P.preset_id);
      const tbl = document.createElement('table'); tbl.className = 'rec';
      tbl.innerHTML = '<tr><th>Fase · ordine</th><th>Passo</th><th>Macchina</th><th>°C (min–max)</th><th>Minuti (min–max)</th><th>Velocità</th><th>pH (min–max)</th></tr>';
      const num = (v, step = 'any', ph = '') => { const i = document.createElement('input'); i.type = 'number'; i.step = step; i.className = 'n'; i.value = v ?? ''; i.placeholder = ph; return i; };
      const eqSel = (v) => { const sel = document.createElement('select'); sel.className = 'eq'; sel.innerHTML = '<option value="">—</option>' + (eq || []).map(e => `<option value="${e.id}" ${e.id === v ? 'selected' : ''}>${esc(e.code)} ${esc(e.name)}</option>`).join(''); return sel; };
      const phSel = (v) => { const sel = document.createElement('select'); sel.className = 'phs'; sel.innerHTML = Object.entries(PPHASE).map(([k, l]) => `<option value="${k}" ${k === v ? 'selected' : ''}>${l}</option>`).join(''); return sel; };
      const mSel = (v) => { const sel = document.createElement('select'); sel.innerHTML = Object.entries(PMETRIC).map(([k, l]) => `<option value="${k}" ${k === v ? 'selected' : ''}>${l}</option>`).join(''); return sel; };
      const extraTxt = x => Object.entries(x || {}).map(([k, v]) => `${k}: ${v}`).join(' · ');
      const parseExtra = t => { const o = {}; t.split(/\s*[·;\n]\s*/).map(p => p.trim()).filter(Boolean).forEach(p => { const m = p.match(/^([^:]+):\s*(.+)$/); if (m) o[m[1].trim()] = m[2].trim(); }); return o; };
      const row = (st) => {
        const tr = document.createElement('tr'); if (!st) tr.style.background = 'var(--tile)';
        const ph = phSel(st?.phase || 'make'), ord = num(st?.step_order ?? (mine.length + 1) * 10, '1', 'ordine'); ord.style.width = '58px';
        const name = document.createElement('input'); name.type = 'text'; name.className = 'w'; name.value = st?.name_it || ''; name.placeholder = 'es. Filatura';
        const eqs = eqSel(st?.equipment_id);
        const t1 = num(st?.target_temp_c, '0.5', '°C'), t2 = num(st?.temp_min_c, '0.5', 'min'), t3 = num(st?.temp_max_c, '0.5', 'max');
        const d1 = num(st?.duration_min, '1', 'min'), d2 = num(st?.duration_min_min, '1', 'min'), d3 = num(st?.duration_max_min, '1', 'max');
        const sp = num(st?.speed, '0.1', 'vel.'), su = document.createElement('input'); su.type = 'text'; su.className = 'sh'; su.value = st?.speed_unit || ''; su.placeholder = 'unità';
        const p1 = num(st?.target_ph, '0.01', 'pH'), p2 = num(st?.ph_min, '0.01', 'min'), p3 = num(st?.ph_max, '0.01', 'max');
        const ex = document.createElement('input'); ex.type = 'text'; ex.className = 'w'; ex.value = extraTxt(st?.extra); ex.placeholder = 'es. salamoia: 15% · tamburo: 250 g';
        const ins = document.createElement('input'); ins.type = 'text'; ins.className = 'w'; ins.value = st?.instruction_it || ''; ins.placeholder = 'cosa deve fare il casaro';
        const met = mSel(st?.record_metric || 'none');
        const payload = () => ({ preset_id: P.preset_id, phase: ph.value, step_order: Number(ord.value) || 10, name_it: name.value.trim(), equipment_id: eqs.value || null,
          target_temp_c: t1.value === '' ? null : Number(t1.value), temp_min_c: t2.value === '' ? null : Number(t2.value), temp_max_c: t3.value === '' ? null : Number(t3.value),
          duration_min: d1.value === '' ? null : Number(d1.value), duration_min_min: d2.value === '' ? null : Number(d2.value), duration_max_min: d3.value === '' ? null : Number(d3.value),
          speed: sp.value === '' ? null : Number(sp.value), speed_unit: su.value.trim() || null, target_ph: p1.value === '' ? null : Number(p1.value), ph_min: p2.value === '' ? null : Number(p2.value), ph_max: p3.value === '' ? null : Number(p3.value),
          extra: parseExtra(ex.value), instruction_it: ins.value.trim() || null, record_metric: met.value, updated_at: new Date().toISOString() });
        const rng = () => Object.assign(document.createElement('span'), { className: 'rng', textContent: '–' });
        const cells = [[ph, ' ', ord], [name], [eqs], [t1, ' ', t2, rng(), t3], [d1, ' ', d2, rng(), d3], [sp, ' ', su], [p1, ' ', p2, rng(), p3]];
        cells.forEach(parts => { const td = document.createElement('td'); td.style.whiteSpace = 'nowrap'; parts.forEach(p => td.append(typeof p === 'string' ? document.createTextNode(p) : p)); tr.append(td); });
        // second line: free-text settings + the instruction the casaro reads
        const sub = document.createElement('tr'); sub.className = 'stepsub'; if (!st) sub.style.background = 'var(--tile)';
        const sTd = document.createElement('td'); sTd.colSpan = 7; sTd.style.whiteSpace = 'nowrap'; sTd.style.flex = '1 1 100%';
        const grid = document.createElement('div'); grid.style.cssText = 'display:grid;grid-template-columns:auto 1fr auto 2fr auto auto auto;gap:6px 8px;align-items:center;padding-bottom:6px';
        const tdB = document.createElement('span'); tdB.style.whiteSpace = 'nowrap';
        grid.append(Object.assign(document.createElement('span'), { textContent: 'Altro' }), ex, Object.assign(document.createElement('span'), { textContent: 'Istruzione' }), ins, Object.assign(document.createElement('span'), { textContent: 'Il tablet registra' }), met, tdB);
        sTd.append(grid); sub.append(sTd);
        if (st) {
          tdB.append(saveBtn(async () => { const p = payload(); if (!p.name_it) throw new Error('Dai un nome al passo'); await upd('process_steps', { id: st.step_id }, p); loadPresets(); }));
          const rm = document.createElement('button'); rm.className = 'btn sm sec'; rm.textContent = 'Togli'; rm.style.marginLeft = '6px'; rm.title = 'Il passo non compare più sul tablet';
          rm.onclick = async () => { rm.disabled = true; try { await upd('process_steps', { id: st.step_id }, { active: false, updated_at: new Date().toISOString() }); toast('Passo tolto'); loadPresets(); } catch (e) { toast(e.message, 'err'); rm.disabled = false; } };
          tdB.append(rm);
        } else {
          const add = document.createElement('button'); add.className = 'btn sm'; add.textContent = 'Aggiungi';
          add.onclick = async () => { const p = payload(); if (!p.name_it) return toast('Dai un nome al passo', 'err'); add.disabled = true; const { error } = await sb.from('process_steps').insert(p); add.disabled = false; if (error) return toast(error.message, 'err'); toast('Passo aggiunto'); loadPresets(); };
          tdB.append(add);
        }
        const frag = document.createDocumentFragment(); frag.append(tr, sub); return frag;
      };
      mine.forEach(st => tbl.append(row(st))); tbl.append(row(null));
      const wrap = document.createElement('div'); wrap.style.overflowX = 'auto'; wrap.append(tbl); card.append(wrap); box.append(card);
    });
    if (!Object.keys(byProd).length) box.innerHTML = '<div class="empty">Nessun preset: vengono creati con la migrazione v0.26.</div>';
  }

  async function loadRecipes() {''')
open(T + 'console.js', 'w').write(j)
print('v26 patched')
