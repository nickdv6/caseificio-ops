/* Console → Anagrafiche → Fornitori → "Articoli che compriamo" (v0.89, reworked v0.90).
   One list of everything we buy, grouped by category (supply_categories), with the suppliers of each item and their price.
   v0.90 — two modes and a bulk panel:
     🛒 Ordina (default): compact rows, nothing editable except the quantity; "Proponi i sotto soglia" fills the reorder quantities;
        minimum order and pack multiples are checked as you type; "Crea ordini" makes one approved PO per supplier and offers the
        jump to Operazioni → Ordini da inviare.
     ✎ Modifica elenco: the full editable rows (name, unit, category, format, stock tracking, reorder point/qty) + "Nuovo articolo".
     Assegna articoli a un fornitore: tick what a supplier sells, type the prices, save once (instead of one item at a time).
   Tapping a supplier chip edits that supplier's price. Search also matches supplier names.
   Data: v_supply_catalog; add_supply_item(), link_supplier_item(), unlink_supplier_item(), create_manual_po().
   Who: area acquisti — "gestisce" edits the list, "registra" can place orders, "vede" reads only.
   Entry points used by console.js: SUPPLIES.showSupplier(id), SUPPLIES.assign(id), SUPPLIES.prefill(sku, qty). */
(() => {
  const { sb, $, esc, num, fmtD, nOrNull, toast, upd, saveBtn, act } = UI;
  const eur = (n, d = 2) => n == null || n === '' ? '–' : new Intl.NumberFormat('it-IT', { style: 'currency', currency: 'EUR', minimumFractionDigits: d, maximumFractionDigits: d }).format(Number(n));
  const price = n => n == null ? '–' : eur(n, Number(n) < 1 ? 3 : 2);
  const itNum = v => v == null || v === '' ? '' : String(v).replace('.', ',');
  const qtyTxt = (v, u) => `${num(v, 2).replace(/,00$/, '')} ${u || ''}`.trim();
  const MODE_KEY = 'supplies.mode';
  let CATS = [], ITEMS = [], SUPS = [], cat = 'all', supF = '', q = '', showArch = false, showNoSup = false, W = false, O = false, loaded = false;
  let mode = (() => { try { return localStorage.getItem(MODE_KEY) || 'order'; } catch { return 'order'; } })();
  let assignSup = null;          // supplier id while the "Assegna articoli" panel is open
  let LAST_MADE = null;          // PO numbers created by the last "Crea ordini", shown with the jump to Operazioni
  const PENDING = [];            // prefill requests that arrived before the data (from Operazioni → Segnali acquisti)
  const ORDER = new Map();       // product_id → { qty, supplier_id } — kept across re-renders, cleared after "Crea ordini"
  let REC = new Map();           // v0.90b: product_id → names of the products whose current recipe uses it (Ricette)

  async function load() {
    const box = $('supplies'); if (!box) return;
    W = PERM.can('acquisti', 3); O = PERM.can('acquisti', 2);
    if (!W) mode = 'order';
    const [c, i, s, r, f] = await Promise.all([
      sb.from('supply_categories').select('*').eq('active', true).order('sort'),
      sb.from('v_supply_catalog').select('*').order('category_sort').order('name'),
      sb.from('parties').select('id, legal_name, email, phone').in('type', ['supplier', 'both']).eq('active', true).order('legal_name'),
      sb.from('recipes').select('component_product_id, finished_product_id, valid_to'),
      sb.from('products').select('id, name').eq('kind', 'finished_good')]);
    const err = c.error || i.error;
    if (err) { box.innerHTML = `<div class="empty">${/does not exist|schema cache/.test(err.message) ? 'Il catalogo forniture non è ancora attivo: esegui la migrazione <b>v0.89a</b> nel SQL editor di Supabase.' : esc(err.message)}</div>`; return; }
    CATS = c.data || []; ITEMS = i.data || []; SUPS = s.data || []; loaded = true;
    // recipes point at these same product records: the item's unit and stock tracking are what the doses are written in
    const today = UI.romeISO(), fin = new Map((f.data || []).map(x => [x.id, x.name]));
    REC = new Map(); (r.data || []).filter(x => !x.valid_to || x.valid_to >= today).forEach(x => { const n = fin.get(x.finished_product_id) || 'un prodotto'; if (!REC.has(x.component_product_id)) REC.set(x.component_product_id, new Set()); REC.get(x.component_product_id).add(n); });
    while (PENDING.length) applyPrefill(...PENDING.shift());
    render();
  }

  const supsOf = it => it.suppliers || [];
  const supName = id => (SUPS.find(s => s.id === id) || {}).legal_name || '?';
  // Ordina hides items that can't be ordered (no supplier) unless asked, searched or filtered for
  const visible = it => (showArch || it.active) && (cat === 'all' || it.category === cat)
    && (mode !== 'order' || showNoSup || q || supF || supsOf(it).length)
    && (!supF || (supF === 'none' ? !supsOf(it).length : supsOf(it).some(x => x.supplier_id === supF)))
    && (!q || [it.name, it.sku, it.spec_it, it.category_name, ...supsOf(it).map(x => x.supplier)].join(' ').toLowerCase().includes(q));
  const lowItems = () => ITEMS.filter(it => it.active && it.track_stock && it.reorder_point != null && Number(it.on_hand) <= Number(it.reorder_point) && supsOf(it).length && Number(it.reorder_qty) > 0);
  const unsavedHere = () => !!document.querySelector('#supplies .dirty');

  function setMode(m) {
    if (m === mode) return;
    if (unsavedHere() && !confirm('Ci sono modifiche non salvate nell\'elenco: se cambi modalità le perdi. Continuare?')) return;
    mode = m; try { localStorage.setItem(MODE_KEY, m); } catch { /* storage blocked */ }
    render();
  }

  function render() {
    const box = $('supplies'); box.innerHTML = '';
    if (assignSup) return renderAssign(box);
    const act_ = ITEMS.filter(x => x.active);
    const bar = document.createElement('div'); bar.className = 'nodirty sup-bar';
    // row 1 · mode switch + bulk assign
    const top = document.createElement('div'); top.className = 'sup-top';
    if (W) {
      const seg = document.createElement('div'); seg.className = 'sup-seg'; seg.setAttribute('role', 'group'); seg.setAttribute('aria-label', 'Modalità');
      [['order', '🛒 Ordina'], ['edit', '✎ Modifica elenco']].forEach(([m, l]) => { const b = document.createElement('button'); b.type = 'button'; b.className = 'chip'; b.textContent = l; b.setAttribute('aria-pressed', String(mode === m)); b.onclick = () => setMode(m); seg.append(b); });
      const asg = document.createElement('button'); asg.type = 'button'; asg.className = 'btn sm sec'; asg.textContent = 'Assegna articoli a un fornitore…';
      asg.onclick = () => openAssign(supF && supF !== 'none' ? supF : (SUPS[0] || {}).id);
      top.append(seg, asg);
    }
    if (mode === 'order' && O) {
      const low = lowItems();
      const fill = document.createElement('button'); fill.type = 'button'; fill.className = 'btn sm sec';
      fill.textContent = `Proponi i sotto soglia (${low.length})`; fill.disabled = !low.length;
      fill.title = low.length ? 'Scrive in "Da ordinare" la quantità di riordino di ogni articolo con giacenza uguale o sotto la soglia' : 'Nessun articolo con fornitore sotto la soglia';
      fill.onclick = () => { low.forEach(it => { if (!ORDER.has(it.id)) ORDER.set(it.id, { qty: Number(it.reorder_qty), supplier_id: supsOf(it)[0].supplier_id }); }); LAST_MADE = null; renderList(); renderOrderBar(); toast(`${low.length} articoli proposti: controlla le quantità e premi Crea ordini`); };
      top.append(fill);
    }
    if (top.childNodes.length) bar.append(top);
    // row 2 · categories
    const chip = (code, label, n) => { const b = document.createElement('span'); b.className = 'pchip' + (cat === code ? ' on' : ''); b.innerHTML = `${esc(label)} <small>${n}</small>`; b.setAttribute('role', 'button'); b.tabIndex = 0; b.onclick = () => { cat = code; render(); }; b.onkeydown = e => { if (e.key === 'Enter') b.click(); }; return b; };
    const chips = document.createElement('div'); chips.className = 'sup-chips'; chips.append(chip('all', 'Tutte', act_.length));
    CATS.forEach(k => { const n = act_.filter(x => x.category === k.code).length; if (n || mode === 'edit') chips.append(chip(k.code, k.name_it, n)); });
    // row 3 · filters
    const f = document.createElement('div'); f.className = 'sup-filters';
    const ss = document.createElement('select'); ss.setAttribute('aria-label', 'Filtra per fornitore');
    ss.innerHTML = `<option value="">Tutti i fornitori</option><option value="none">Senza fornitore</option>` + SUPS.map(p => `<option value="${p.id}">${esc(p.legal_name)}</option>`).join(''); ss.value = supF; ss.onchange = () => { supF = ss.value; render(); };
    const qs = document.createElement('input'); qs.type = 'search'; qs.placeholder = 'Cerca articolo o fornitore…'; qs.value = q; qs.setAttribute('aria-label', 'Cerca');
    qs.oninput = () => { q = qs.value.trim().toLowerCase(); renderList(); };
    f.append(ss, qs);
    if (mode === 'edit') { const ar = document.createElement('label'); ar.className = 'status'; ar.innerHTML = `<input type="checkbox" ${showArch ? 'checked' : ''}> mostra archiviati`; ar.querySelector('input').onchange = e => { showArch = e.target.checked; render(); }; f.append(ar); }
    bar.append(chips, f);
    // missing suppliers: the one thing blocking orders
    const noSup = act_.filter(x => !supsOf(x).length).length;
    if (noSup && W) {
      const n = document.createElement('div'); n.className = 'sup-note';
      n.innerHTML = `<span><b>${noSup} ${noSup === 1 ? 'articolo' : 'articoli'} senza fornitore</b>: non si possono ordinare finché non hanno un fornitore${mode === 'order' && !showNoSup ? ' (qui sono nascosti)' : ''}.</span>`;
      const b = document.createElement('button'); b.type = 'button'; b.className = 'btn sm'; b.textContent = 'Assegna a un fornitore';
      b.onclick = () => openAssign((SUPS[0] || {}).id); n.append(b);
      const v = document.createElement('button'); v.type = 'button'; v.className = 'btn sm sec';
      if (mode === 'order') { v.textContent = showNoSup ? 'Nascondili' : 'Mostrali'; v.onclick = () => { showNoSup = !showNoSup; render(); }; }
      else { v.textContent = supF === 'none' ? 'Mostra tutti' : 'Mostra solo questi'; v.onclick = () => { supF = supF === 'none' ? '' : 'none'; render(); }; }
      n.append(v);
      bar.append(n);
    }
    box.append(bar);
    const list = document.createElement('div'); list.id = 'sup-list'; box.append(list);
    const ob = document.createElement('div'); ob.id = 'sup-order'; ob.className = 'nodirty sup-order'; box.append(ob);
    renderList(); renderOrderBar();
  }

  function renderList() {
    const list = $('sup-list'); if (!list) return; list.innerHTML = '';
    const cats = cat === 'all' ? CATS : CATS.filter(k => k.code === cat);
    let shown = 0;
    cats.forEach(k => {
      const rows = ITEMS.filter(it => it.category === k.code && visible(it));
      if (!rows.length && (q || supF || mode === 'order')) return;   // in Ordina mode or when filtering, empty groups are hidden
      shown += rows.length;
      const sec = document.createElement('section'); sec.className = 'sup-cat';
      sec.innerHTML = `<h4>${esc(k.name_it)} <small class="status">${rows.length} ${rows.length === 1 ? 'articolo' : 'articoli'}${k.hint_it && mode === 'edit' ? ' · ' + esc(k.hint_it) : ''}</small></h4>`;
      const tbl = document.createElement('table'); tbl.className = 'sup' + (mode === 'order' ? ' ord' : '');
      tbl.innerHTML = mode === 'order'
        ? '<tr><th>Articolo</th><th>Fornitore e prezzo</th><th>Magazzino</th><th class="num">Da ordinare</th></tr>'
        : '<tr><th>Articolo</th><th>Fornitori e prezzo</th><th>Magazzino</th><th></th></tr>';
      rows.forEach(it => tbl.append(mode === 'order' ? orderRow(it) : editRow(it)));
      if (W && mode === 'edit' && !q) tbl.append(addRow(k));
      const wrap = document.createElement('div'); wrap.className = 'sup-wrap'; wrap.append(tbl); sec.append(wrap); list.append(sec);
    });
    if (!shown) list.innerHTML = (q || supF) ? '<div class="empty">Nessun articolo con questi filtri.</div>' : '<div class="empty">Nessun articolo. Passa a «Modifica elenco» per aggiungerne.</div>';
  }

  // ---------- supplier chips + the add/edit price form (shared by both modes) ----------
  function supplierCell(it, editable) {
    const td = document.createElement('td'); td.className = 'nodirty';
    const sups = supsOf(it);
    let form = null, sel = null, pr = null;
    const openForm = sid => { if (!form) return; form.hidden = false; sel.value = sid || ''; sel.onchange(); (sid ? pr : sel).focus(); };
    sups.forEach(s => {
      const c = document.createElement('div'); c.className = 'schip' + (s.preferred ? ' pref' : '');
      if (editable && mode === 'edit') {
        const star = document.createElement('button'); star.type = 'button'; star.className = 'x st'; star.textContent = s.preferred ? '★' : '☆';
        star.title = s.preferred ? 'Fornitore preferito (lo usa il bot Acquisti)' : 'Rendi preferito'; star.setAttribute('aria-label', star.title); star.disabled = s.preferred;
        star.onclick = () => act(star, async () => { const { error } = await sb.rpc('link_supplier_item', { p_product_id: it.id, p_supplier_id: s.supplier_id, p_make_preferred: true }); if (error) throw error; await load(); }, 'Fornitore preferito aggiornato');
        c.append(star);
      } else if (s.preferred && sups.length > 1) c.insertAdjacentHTML('beforeend', '<span class="st" title="Fornitore preferito">★</span>');
      const lab = document.createElement(editable ? 'button' : 'span'); lab.className = 'lab';
      lab.innerHTML = `${esc(s.supplier)} <b>${price(s.price_eur)}</b>${s.price_eur != null && it.unit ? `<small>/${esc(it.unit)}</small>` : ''}${s.price_src === 'ultimo DDT' ? ' <small>DDT</small>' : ''}${s.price_eur == null ? ' <small class="ko">senza prezzo</small>' : ''}`;
      if (editable) { lab.type = 'button'; lab.title = 'Cambia il prezzo di questo fornitore'; lab.onclick = () => openForm(s.supplier_id); }
      c.append(lab);
      if (editable && mode === 'edit') {
        const rm = document.createElement('button'); rm.type = 'button'; rm.className = 'x'; rm.textContent = '✕'; rm.title = 'Togli questo fornitore dall\'articolo'; rm.setAttribute('aria-label', rm.title);
        rm.onclick = () => { if (!confirm(`Togliere ${s.supplier} da «${it.name}»? Lo storico prezzi resta.`)) return; act(rm, async () => { const { error } = await sb.rpc('unlink_supplier_item', { p_product_id: it.id, p_supplier_id: s.supplier_id }); if (error) throw error; await load(); }, 'Fornitore tolto'); };
        c.append(rm);
      }
      td.append(c);
    });
    if (!sups.length) td.insertAdjacentHTML('beforeend', '<div class="status ko">nessun fornitore</div>');
    if (editable) {
      const plus = document.createElement('button'); plus.type = 'button'; plus.className = 'btn sm sec'; plus.textContent = sups.length ? '+ Fornitore' : '+ Aggiungi fornitore';
      plus.hidden = mode === 'order' && sups.length > 0;   // Ordina: tap a chip to change its price; adding suppliers is for «Modifica elenco» or «Assegna»
      form = document.createElement('div'); form.className = 'sup-add'; form.hidden = true;
      sel = document.createElement('select'); sel.setAttribute('aria-label', 'Fornitore');
      sel.innerHTML = '<option value="">Scegli fornitore…</option>' + SUPS.map(p => `<option value="${p.id}">${esc(p.legal_name)}${sups.some(x => x.supplier_id === p.id) ? ' (già collegato)' : ''}</option>`).join('');
      pr = document.createElement('input'); pr.type = 'text'; pr.inputMode = 'decimal'; pr.placeholder = `€ / ${it.unit || 'unità'}`; pr.className = 'pr'; pr.setAttribute('aria-label', 'Prezzo');
      sel.onchange = () => { const cur = sups.find(x => x.supplier_id === sel.value); pr.value = cur && cur.price_eur != null ? itNum(cur.price_eur) : ''; };
      const ok = document.createElement('button'); ok.type = 'button'; ok.className = 'btn sm'; ok.textContent = 'Salva';
      const save = () => act(ok, async () => { if (!sel.value) throw new Error('Scegli il fornitore'); const { error } = await sb.rpc('link_supplier_item', { p_product_id: it.id, p_supplier_id: sel.value, p_price_eur: nOrNull(pr.value), p_make_preferred: false }); if (error) throw error; await load(); }, 'Fornitore e prezzo salvati');
      ok.onclick = save; pr.onkeydown = e => { if (e.key === 'Enter') save(); };
      const no = document.createElement('button'); no.type = 'button'; no.className = 'btn sm sec'; no.textContent = 'Annulla'; no.onclick = () => { form.hidden = true; };
      form.append(sel, pr, ok, no); plus.onclick = () => { if (form.hidden) openForm(''); else form.hidden = true; };
      td.append(plus, form);
    }
    return td;
  }

  const recTag = it => { const n = REC.get(it.id); return n ? ` <span class="sup-tag rec" title="Si scarica dal magazzino a ogni lotto, secondo la ricetta">ricetta: ${esc([...n].join(', '))}</span>` : ''; };
  function stockText(it) {
    if (!it.track_stock) return '<small class="status">solo ordine, non si conta</small>';
    const low = it.reorder_point != null && Number(it.on_hand) <= Number(it.reorder_point);
    return `<div class="${low ? 'ko' : ''}">giacenza <b>${num(it.on_hand, 0)}</b> ${esc(it.unit || '')}${low ? ' · sotto soglia' : ''}</div>`
      + (it.reorder_point != null ? `<small class="status">soglia ${num(it.reorder_point, 0)}${it.reorder_qty ? ` · riordino ${num(it.reorder_qty, 0)}` : ''}</small>` : '<small class="status">soglia non impostata</small>');
  }

  // ---------- 🛒 Ordina mode ----------
  function orderRow(it) {
    const tr = document.createElement('tr');
    const t1 = document.createElement('td');
    const meta = [it.spec_it && it.spec_it !== 'elenco di partenza' ? esc(it.spec_it) : '', esc(it.unit || ''), it.last_ordered_on ? 'ultimo ordine ' + fmtD(it.last_ordered_on) : ''].filter(Boolean).join(' · ');
    t1.innerHTML = `<b>${esc(it.name)}</b>${it.open_po ? ' <span class="sup-tag">ordine aperto</span>' : ''}${recTag(it)}<br><small class="status">${meta}</small>`;
    const t3 = document.createElement('td'); t3.innerHTML = stockText(it);
    tr.append(t1, supplierCell(it, W), t3, qtyCell(it)); return tr;
  }

  function qtyCell(it) {
    const td = document.createElement('td'); td.className = 'num nodirty';
    const sups = supsOf(it);
    if (!it.active || !O) return td;
    if (!sups.length) { td.innerHTML = '<small class="status">serve un fornitore</small>'; return td; }
    const o = ORDER.get(it.id) || {};
    const qn = document.createElement('input'); qn.type = 'text'; qn.inputMode = 'decimal'; qn.className = 'q'; qn.placeholder = it.unit || 'qtà'; qn.value = o.qty ? itNum(o.qty) : '';
    qn.setAttribute('aria-label', `Quantità da ordinare di ${it.name}`);
    let sv = o.supplier_id && sups.some(x => x.supplier_id === o.supplier_id) ? o.supplier_id : sups[0].supplier_id;   // sups[0] is the preferred one
    const est = document.createElement('small'); est.className = 'status sup-est';
    const cur = () => sups.find(x => x.supplier_id === sv) || {};
    const upd_ = (user = false) => {
      let v = null; try { v = nOrNull(qn.value); } catch { qn.classList.add('bad'); est.textContent = 'numero non valido'; return; }
      qn.classList.remove('bad');
      if (v && v > 0) ORDER.set(it.id, { qty: v, supplier_id: sv }); else ORDER.delete(it.id);
      const s = cur(), min = Number(s.min_order_qty) || 0, mul = Number(s.order_multiple) || 0;
      const parts = [];
      if (v && s.price_eur != null) parts.push(eur(v * s.price_eur));
      if (v && min && v < min) { parts.push(`sotto il minimo (${num(min, 0)})`); qn.classList.add('bad'); }
      else if (!v && (min || mul)) parts.push([min ? `min ${num(min, 0)}` : '', mul ? `multipli di ${num(mul, 0)}` : ''].filter(Boolean).join(' · '));
      est.textContent = parts.join(' · ');
      if (user) LAST_MADE = null;   // a new quantity typed hides the last «Creati …» panel; redraws do not
      renderOrderBar();
    };
    // pack multiples: round up when leaving the field, and say so
    qn.onblur = () => { const s = cur(), mul = Number(s.order_multiple) || 0; let v = null; try { v = nOrNull(qn.value); } catch { return; }
      if (v && mul && Math.abs(v / mul - Math.round(v / mul)) > 1e-9) { const r = Math.ceil(v / mul) * mul; qn.value = itNum(r); upd_(true); toast(`${it.name}: arrotondato a ${qtyTxt(r, it.unit)} (si ordina a multipli di ${num(mul, 0)})`); } };
    qn.oninput = () => upd_(true); qn.onkeydown = e => { if (e.key === 'Enter') qn.blur(); };
    td.append(qn);
    if (sups.length > 1) { const so = document.createElement('select'); so.className = 'os'; so.setAttribute('aria-label', 'Fornitore per questo ordine'); so.innerHTML = sups.map(s => `<option value="${s.supplier_id}">${esc(s.supplier)}${s.price_eur != null ? ' · ' + price(s.price_eur) : ''}</option>`).join(''); so.value = sv; so.onchange = () => { sv = so.value; upd_(true); }; td.append(so); }
    td.append(est); upd_();
    return td;
  }

  // ---------- ✎ Modifica elenco mode ----------
  function editRow(it) {
    const tr = document.createElement('tr'); if (!it.active) tr.className = 'arch';
    const inp = (type, v, ph = '', cls = '', label = '') => { const i = document.createElement('input'); i.type = type; i.value = v ?? ''; i.placeholder = ph; if (cls) i.className = cls; if (label) i.setAttribute('aria-label', label); return i; };
    const t1 = document.createElement('td');
    const name = inp('text', it.name, 'nome', 'nm', 'Nome articolo'), unit = inp('text', it.unit, 'unità', 'un', 'Unità'), spec = inp('text', it.spec_it === 'elenco di partenza' ? '' : it.spec_it, 'formato / note (es. tanica 10 l)', 'sp', 'Formato o note');
    const cs = document.createElement('select'); cs.setAttribute('aria-label', 'Categoria'); cs.innerHTML = CATS.map(k => `<option value="${k.code}" ${k.code === it.category ? 'selected' : ''}>${esc(k.name_it)}</option>`).join('');
    const l2 = document.createElement('div'); l2.className = 'sup-l2'; l2.append(unit, cs);
    const meta = document.createElement('small'); meta.className = 'status'; meta.textContent = it.sku + (it.spec_it === 'elenco di partenza' ? ' · elenco di partenza' : '') + (it.last_ordered_on ? ' · ultimo ordine ' + fmtD(it.last_ordered_on) : '') + (it.open_po ? ' · ordine aperto' : '');
    const inRec = REC.get(it.id), recNames = inRec ? [...inRec].join(', ') : '';
    if (inRec) {   // v0.90b: changing the unit would silently rescale every dose; untracking would leave recipe deductions on an item nobody counts
      unit.disabled = true; unit.title = `Usato nella ricetta di ${recNames}: le dosi sono scritte in «${it.unit}». Per cambiare unità cambia prima le dosi in Ricette.`;
      t1.insertAdjacentHTML('beforeend', recTag(it));
    }
    t1.append(name, l2, spec, meta);
    const t3 = document.createElement('td');
    const tk = document.createElement('label'); tk.className = 'status'; const tkc = document.createElement('input'); tkc.type = 'checkbox'; tkc.checked = it.track_stock; tk.append(tkc, document.createTextNode(' conta in magazzino'));
    if (inRec && tkc.checked) { tkc.disabled = true; tk.title = `Si scarica a ogni lotto dalla ricetta di ${recNames}: deve restare in magazzino`; }
    const rp = inp('text', itNum(it.reorder_point), 'soglia', 'n', 'Soglia di riordino'), rq = inp('text', itNum(it.reorder_qty), 'riordino', 'n', 'Quantità di riordino');
    rp.inputMode = rq.inputMode = 'decimal'; rp.title = 'Sotto questa giacenza il bot Acquisti propone un ordine'; rq.title = 'Quantità che il bot propone di ordinare';
    const stk = document.createElement('div'); stk.className = 'sup-stk';
    const paint = () => { stk.innerHTML = ''; if (!tkc.checked) { stk.innerHTML = '<small class="status">solo ordine, non si conta</small>'; return; }
      const low = it.reorder_point != null && Number(it.on_hand) <= Number(it.reorder_point);
      stk.insertAdjacentHTML('beforeend', `<div class="${low ? 'ko' : ''}">giacenza <b>${num(it.on_hand, 0)}</b> ${esc(it.unit || '')}</div>`);
      const g = document.createElement('div'); g.className = 'sup-l2'; g.append(rp, rq); stk.append(g); };
    tkc.onchange = paint; paint(); t3.append(tk, stk);
    const t5 = document.createElement('td'); t5.className = 'sup-act';
    t5.append(saveBtn(async () => {
      const nm = name.value.trim(); if (!nm) throw new Error('Il nome è obbligatorio');
      const k = CATS.find(x => x.code === cs.value) || {};
      // saving a starter item clears its "elenco di partenza" mark (the field shows empty for those)
      const v = { name: nm, unit: unit.value.trim() || 'pz', spec_it: spec.value.trim() || null, category: cs.value, track_stock: tkc.checked,
        reorder_point: tkc.checked ? nOrNull(rp.value) : null, reorder_qty: tkc.checked ? nOrNull(rq.value) : null, updated_at: new Date().toISOString() };
      if (k.kind && k.kind !== it.kind) v.kind = k.kind;
      await upd('products', { id: it.id }, v); UI.after(load);
    }));
    const ar = document.createElement('button'); ar.type = 'button'; ar.className = 'btn sm sec';
    ar.textContent = it.active ? 'Archivia' : 'Ripristina'; ar.title = it.active ? 'Non compare più negli ordini e nel conteggio; lo storico resta' : '';
    ar.onclick = () => { if (it.active && inRec) { toast(`«${it.name}» è nella ricetta di ${recNames}: toglilo prima in Ricette, poi archivialo`, 'err'); return; }
      if (it.active && !confirm(`Archiviare «${it.name}»?`)) return; act(ar, async () => { await upd('products', { id: it.id }, { active: !it.active, updated_at: new Date().toISOString() }); ORDER.delete(it.id); await load(); }, it.active ? 'Articolo archiviato' : 'Articolo ripristinato'); };
    t5.append(ar);
    tr.append(t1, supplierCell(it, true), t3, t5); return tr;
  }

  function addRow(k) {
    const tr = document.createElement('tr'); tr.className = 'nodirty sup-new';
    const nm = document.createElement('input'); nm.type = 'text'; nm.placeholder = `Nuovo articolo in ${k.name_it}…`; nm.className = 'nm'; nm.setAttribute('aria-label', 'Nome del nuovo articolo');
    const un = document.createElement('input'); un.type = 'text'; un.placeholder = 'unità (pz, kg, l…)'; un.className = 'un'; un.setAttribute('aria-label', 'Unità');
    const sp = document.createElement('input'); sp.type = 'text'; sp.placeholder = 'formato / note'; sp.className = 'sp'; sp.setAttribute('aria-label', 'Formato o note');
    const ss = document.createElement('select'); ss.setAttribute('aria-label', 'Fornitore'); ss.innerHTML = '<option value="">Fornitore (facoltativo)</option>' + SUPS.map(p => `<option value="${p.id}">${esc(p.legal_name)}</option>`).join('');
    const pr = document.createElement('input'); pr.type = 'text'; pr.inputMode = 'decimal'; pr.placeholder = '€ / unità'; pr.className = 'pr'; pr.setAttribute('aria-label', 'Prezzo');
    const b = document.createElement('button'); b.type = 'button'; b.className = 'btn sm'; b.textContent = 'Aggiungi';
    b.onclick = () => act(b, async () => {
      if (!nm.value.trim()) throw new Error('Scrivi il nome dell\'articolo');
      const { error } = await sb.rpc('add_supply_item', { p_name: nm.value.trim(), p_category: k.code, p_unit: un.value.trim() || 'pz', p_supplier_id: ss.value || null, p_price_eur: nOrNull(pr.value), p_spec: sp.value.trim() || null });
      if (error) throw error; await load();
    }, 'Articolo aggiunto');
    [nm, pr].forEach(e => { e.onkeydown = ev => { if (ev.key === 'Enter') b.click(); }; });
    const td = (...els) => { const t = document.createElement('td'); els.forEach(e => t.append(e)); return t; };
    const l2 = document.createElement('div'); l2.className = 'sup-l2'; l2.append(un);
    const s2 = document.createElement('div'); s2.className = 'sup-l2'; s2.append(ss, pr);
    tr.append(td(nm, l2, sp), td(s2), td(), td(b)); return tr;
  }

  // ---------- order bar ----------
  function renderOrderBar() {
    const ob = $('sup-order'); if (!ob) return;
    const lines = [...ORDER.entries()].map(([pid, o]) => ({ it: ITEMS.find(x => x.id === pid), ...o })).filter(l => l.it && l.it.active);
    if (!lines.length) {
      if (LAST_MADE && LAST_MADE.length) {
        ob.hidden = false; ob.className = 'nodirty sup-order done';
        ob.innerHTML = `<div><b>✓ ${LAST_MADE.length === 1 ? 'Creato' : 'Creati'} ${LAST_MADE.map(esc).join(', ')}</b> <small class="status">già approvati · manca solo l'invio al fornitore</small></div>`;
        const go = document.createElement('a'); go.className = 'btn'; go.href = '#ops'; go.textContent = 'Invia ai fornitori →'; go.style.textDecoration = 'none';
        go.onclick = () => { LAST_MADE = null; };
        const r = document.createElement('div'); r.className = 'sup-l2'; r.append(go); ob.append(r);
      } else { ob.hidden = true; ob.innerHTML = ''; }
      return;
    }
    ob.className = 'nodirty sup-order';
    const by = {}; lines.forEach(l => { (by[l.supplier_id] = by[l.supplier_id] || []).push(l); });
    let tot = 0, noPrice = 0, belowMin = 0;
    const parts = Object.entries(by).map(([sid, ls]) => {
      const sup = SUPS.find(s => s.id === sid) || {};
      const sub = ls.reduce((a, l) => { const s = supsOf(l.it).find(x => x.supplier_id === sid); if (s && s.min_order_qty && l.qty < Number(s.min_order_qty)) belowMin++; if (!s || s.price_eur == null) { noPrice++; return a; } return a + l.qty * s.price_eur; }, 0); tot += sub;
      const noContact = !sup.email && !sup.phone;
      return `<li><b>${esc(sup.legal_name || '?')}</b>: ${ls.map(l => `${qtyTxt(l.qty, l.it.unit)} ${esc(l.it.name)}`).join(', ')} <small>· ${eur(sub)}</small>${noContact ? ' <small class="ko">· senza email né telefono: aggiungili in Fornitori per inviare l\'ordine</small>' : ''}</li>`;
    });
    const nSup = Object.keys(by).length;
    ob.hidden = false;
    ob.innerHTML = `<div><b>${lines.length} ${lines.length === 1 ? 'riga' : 'righe'} · ${nSup} ${nSup === 1 ? 'fornitore' : 'fornitori'} · ${eur(tot)}</b> <small class="status">IVA esclusa${noPrice ? ` · <span class="ko">${noPrice} senza prezzo</span>` : ''}${belowMin ? ` · <span class="ko">${belowMin} sotto il minimo d'ordine</span>` : ''}</small><ul>${parts.join('')}</ul></div>`;
    const note = document.createElement('input'); note.type = 'text'; note.placeholder = 'Nota per il fornitore (facoltativa)'; note.className = 'sp'; note.setAttribute('aria-label', 'Nota per il fornitore');
    const go = document.createElement('button'); go.type = 'button'; go.className = 'btn'; go.textContent = nSup === 1 ? 'Crea ordine' : `Crea ${nSup} ordini`;
    const clr = document.createElement('button'); clr.type = 'button'; clr.className = 'btn sec'; clr.textContent = 'Svuota';
    clr.onclick = () => { ORDER.clear(); renderList(); renderOrderBar(); };
    go.onclick = () => act(go, async () => {
      if (belowMin && !confirm(`${belowMin} ${belowMin === 1 ? 'riga è' : 'righe sono'} sotto il minimo d'ordine del fornitore. Creare comunque?`)) return false;
      const made = [];
      for (const [sid, ls] of Object.entries(by)) {
        const { data, error } = await sb.rpc('create_manual_po', { p_supplier_id: sid, p_lines: ls.map(l => ({ product_id: l.it.id, qty: l.qty })), p_notes: note.value.trim() || null });
        if (error) { if (made.length) { LAST_MADE = made; toast(`Creati ${made.join(', ')}; errore con ${supName(sid)}`, 'err'); } throw error; }
        made.push(data.po_number); ls.forEach(l => ORDER.delete(l.it.id));
      }
      LAST_MADE = made;
      await load();
      return made;
    }, made => `${made.length === 1 ? 'Creato' : 'Creati'} ${made.join(', ')}`);
    const r = document.createElement('div'); r.className = 'sup-l2'; r.append(note, go, clr); ob.append(r);
  }

  // ---------- Assegna articoli a un fornitore (bulk) ----------
  function openAssign(sid) {
    if (!W) return;
    if (!SUPS.length) { toast('Aggiungi prima un fornitore nella tabella qui sopra', 'err'); return; }
    if (unsavedHere() && !confirm('Ci sono modifiche non salvate nell\'elenco: aprendo l\'assegnazione le perdi. Continuare?')) return;
    assignSup = sid || SUPS[0].id; render();
    const c = $('c-supplies'); if (c) c.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }

  function renderAssign(box) {
    const sid = assignSup, sup = SUPS.find(s => s.id === sid) || {};
    const wrap = document.createElement('div'); wrap.className = 'sup-assign nodirty';
    const head = document.createElement('div'); head.className = 'sup-top';
    const ss = document.createElement('select'); ss.setAttribute('aria-label', 'Fornitore'); ss.innerHTML = SUPS.map(p => `<option value="${p.id}">${esc(p.legal_name)}</option>`).join(''); ss.value = sid;
    const close = document.createElement('button'); close.type = 'button'; close.className = 'btn sm sec'; close.textContent = 'Chiudi';
    head.innerHTML = '<b>Assegna articoli a</b>'; head.append(ss, close);
    const hint = document.createElement('div'); hint.className = 'hint keep';
    hint.innerHTML = `Spunta tutto quello che compri da <b>${esc(sup.legal_name || '')}</b> e scrivi il prezzo per unità, IVA esclusa (puoi lasciarlo vuoto se non lo sai ancora). Scrivere un prezzo spunta la riga. Si salva tutto con un solo tasto. Se l'articolo non ha ancora un fornitore, questo diventa il preferito.`
      + (!sup.email && !sup.phone ? ' <span class="ko">Questo fornitore non ha email né telefono: aggiungili nella tabella Fornitori, servono per inviare gli ordini.</span>' : '');
    const qs = document.createElement('input'); qs.type = 'search'; qs.placeholder = 'Cerca articolo…'; qs.setAttribute('aria-label', 'Cerca articolo');
    const only = document.createElement('label'); only.className = 'status'; only.innerHTML = '<input type="checkbox"> solo articoli senza fornitore';
    const f = document.createElement('div'); f.className = 'sup-filters'; f.append(qs, only);
    const list = document.createElement('div'); list.className = 'sup-alist';
    const foot = document.createElement('div'); foot.className = 'sup-order';
    wrap.append(head, hint, f, list, foot); box.append(wrap);

    // state per item: was linked? checked? price
    const S = new Map();
    ITEMS.filter(it => it.active).forEach(it => { const s = supsOf(it).find(x => x.supplier_id === sid); S.set(it.id, { was: !!s, wasPrice: s ? s.price_eur : null, on: !!s, price: s && s.price_eur != null ? itNum(s.price_eur) : '' }); });
    const changes = () => { const add = [], drop = []; let bad = 0;
      ITEMS.filter(it => it.active).forEach(it => { const st = S.get(it.id); let p = null; try { p = nOrNull(st.price); } catch { bad++; return; }
        if (st.on && (!st.was || (p != null && Number(p) !== Number(st.wasPrice)))) add.push({ it, p });
        if (!st.on && st.was) drop.push(it); });
      return { add, drop, bad }; };
    const paintFoot = () => {
      const { add, drop, bad } = changes(); foot.innerHTML = '';
      const t = document.createElement('div'); t.innerHTML = `<b>${add.length} da collegare o aggiornare${drop.length ? ` · ${drop.length} da togliere` : ''}</b>${bad ? ' <small class="ko">· prezzi non validi</small>' : ''}`;
      const sv = document.createElement('button'); sv.type = 'button'; sv.className = 'btn'; sv.textContent = 'Salva'; sv.disabled = !(add.length || drop.length) || bad > 0;
      sv.onclick = () => act(sv, async () => {
        if (drop.length && !confirm(`Togliere ${drop.length} ${drop.length === 1 ? 'articolo' : 'articoli'} da ${sup.legal_name}? Lo storico prezzi resta.`)) return false;
        let n = 0;
        for (const { it, p } of add) { const { error } = await sb.rpc('link_supplier_item', { p_product_id: it.id, p_supplier_id: sid, p_price_eur: p, p_make_preferred: false }); if (error) throw new Error(`${it.name}: ${error.message}` + (n ? ` (salvati ${n} prima dell'errore)` : '')); n++; }
        for (const it of drop) { const { error } = await sb.rpc('unlink_supplier_item', { p_product_id: it.id, p_supplier_id: sid }); if (error) throw new Error(`${it.name}: ${error.message}`); n++; }
        assignSup = null; supF = sid; cat = 'all'; q = ''; mode = 'order';
        await load(); return n;
      }, n => `${sup.legal_name}: ${n} ${n === 1 ? 'modifica salvata' : 'modifiche salvate'}`);
      const cn = document.createElement('button'); cn.type = 'button'; cn.className = 'btn sec'; cn.textContent = 'Annulla'; cn.onclick = () => close.onclick();
      const r = document.createElement('div'); r.className = 'sup-l2'; r.append(sv, cn); foot.append(t, r);
    };
    const paintList = () => {
      const qq = qs.value.trim().toLowerCase(), onlyNone = only.querySelector('input').checked; list.innerHTML = '';
      CATS.forEach(k => {
        const rows = ITEMS.filter(it => it.active && it.category === k.code && (!qq || (it.name + ' ' + (it.spec_it || '')).toLowerCase().includes(qq)) && (!onlyNone || !supsOf(it).length || S.get(it.id).was));
        if (!rows.length) return;
        const sec = document.createElement('section'); sec.className = 'sup-cat'; sec.innerHTML = `<h4>${esc(k.name_it)}</h4>`;
        rows.forEach(it => {
          const st = S.get(it.id), others = supsOf(it).filter(x => x.supplier_id !== sid);
          const r = document.createElement('label'); r.className = 'sup-arow' + (st.on ? ' on' : '');
          const cb = document.createElement('input'); cb.type = 'checkbox'; cb.checked = st.on;
          const nm = document.createElement('span'); nm.className = 'an';
          nm.innerHTML = `<b>${esc(it.name)}</b> <small class="status">${esc(it.unit || '')}${others.length ? ' · già da ' + others.map(x => esc(x.supplier) + (x.price_eur != null ? ' ' + price(x.price_eur) : '')).join(', ') : ' · <span class="ko">nessun fornitore</span>'}</small>`;
          const pr = document.createElement('input'); pr.type = 'text'; pr.inputMode = 'decimal'; pr.className = 'pr'; pr.placeholder = `€ / ${it.unit || 'unità'}`; pr.value = st.price; pr.setAttribute('aria-label', `Prezzo di ${it.name}`);
          cb.onchange = () => { st.on = cb.checked; r.classList.toggle('on', st.on); if (st.on && !pr.value) pr.focus(); paintFoot(); };
          pr.oninput = () => { st.price = pr.value; if (pr.value && !cb.checked) { cb.checked = true; st.on = true; r.classList.add('on'); } paintFoot(); };
          pr.onfocus = () => pr.select();
          r.append(cb, nm, pr); sec.append(r);
        });
        list.append(sec);
      });
      if (!list.childNodes.length) list.innerHTML = '<div class="empty">Nessun articolo con questi filtri.</div>';
    };
    const dirty = () => { const { add, drop } = changes(); return add.length + drop.length; };
    ss.onchange = () => { if (dirty() && !confirm('Le spunte e i prezzi non salvati per questo fornitore si perdono. Cambiare fornitore?')) { ss.value = sid; return; } assignSup = ss.value; render(); };
    close.onclick = () => { if (dirty() && !confirm('Chiudere senza salvare?')) return; assignSup = null; render(); };
    qs.oninput = paintList; only.querySelector('input').onchange = paintList;
    paintList(); paintFoot(); setTimeout(() => qs.focus({ preventScroll: true }), 0);
  }

  // ---------- entry points from console.js ----------
  function applyPrefill(sku, qty) {
    const it = ITEMS.find(x => x.sku === sku && x.active); if (!it) return false;
    const sups = supsOf(it); if (!sups.length) { toast(`${it.name} non ha un fornitore: assegnalo prima di ordinare`, 'err'); return false; }
    ORDER.set(it.id, { qty: Number(qty) > 0 ? Number(qty) : (Number(it.reorder_qty) || 1), supplier_id: sups[0].supplier_id });
    LAST_MADE = null; return true;
  }
  function focusCatalog() { const c = $('c-supplies'); if (c) setTimeout(() => c.scrollIntoView({ behavior: 'smooth', block: 'start' }), 60); }
  // Operazioni → Segnali acquisti → "Ordina": switch to Fornitori, put the quantity in the order bar
  function prefill(sku, qty) {
    const sub = document.querySelector('#party-tabs .sub[data-type="supplier"]'); if (sub && sub.getAttribute('aria-selected') !== 'true') sub.click();
    if (!loaded) { PENDING.push([sku, qty]); mode = 'order'; focusCatalog(); return; }
    if (applyPrefill(sku, qty)) { assignSup = null; mode = 'order'; cat = 'all'; supF = ''; q = ''; render(); }
    focusCatalog();
  }
  // supplier table: "N articoli" → that supplier's items; "Assegna articoli" → the bulk panel
  function showSupplier(id) { assignSup = null; supF = id || ''; cat = 'all'; q = ''; render(); focusCatalog(); }
  function assign(id) { if (!loaded) return; openAssign(id); }

  window.SUPPLIES = { load, showSupplier, assign, prefill };
})();
