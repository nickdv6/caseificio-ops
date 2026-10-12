/* Console → Anagrafiche → Fornitori → "Articoli che compriamo" (v0.89).
   One list of everything we buy, grouped by category (supply_categories), with the suppliers of each item and their price.
   Edit an item in its row; link suppliers with "+ Fornitore" (★ = preferred, used by the Acquisti bot); type quantities in
   "Da ordinare" and "Crea ordini" makes one approved PO per supplier, which then shows in Operazioni → Ordini da inviare.
   Data: v_supply_catalog; add_supply_item(), link_supplier_item(), unlink_supplier_item(), create_manual_po().
   Who: area acquisti — "gestisce" edits the list, "registra" can place orders, "vede" reads only. */
(() => {
  const { sb, $, esc, num, fmtD, nOrNull, toast, upd, saveBtn, act } = UI;
  const eur = (n, d = 2) => n == null || n === '' ? '–' : new Intl.NumberFormat('it-IT', { style: 'currency', currency: 'EUR', minimumFractionDigits: d, maximumFractionDigits: d }).format(Number(n));
  const price = n => n == null ? '–' : eur(n, Number(n) < 1 ? 3 : 2);
  let CATS = [], ITEMS = [], SUPS = [], cat = 'all', supF = '', q = '', showArch = false, W = false, O = false;
  const ORDER = new Map();   // product_id → { qty, supplier_id } — kept across re-renders, cleared after "Crea ordini"

  async function load() {
    const box = $('supplies'); if (!box) return;
    W = PERM.can('acquisti', 3); O = PERM.can('acquisti', 2);
    const [c, i, s] = await Promise.all([
      sb.from('supply_categories').select('*').eq('active', true).order('sort'),
      sb.from('v_supply_catalog').select('*').order('category_sort').order('name'),
      sb.from('parties').select('id, legal_name').in('type', ['supplier', 'both']).eq('active', true).order('legal_name')]);
    const err = c.error || i.error;
    if (err) { box.innerHTML = `<div class="empty">${/does not exist|schema cache/.test(err.message) ? 'Il catalogo forniture non è ancora attivo: esegui la migrazione <b>v0.89a</b> nel SQL editor di Supabase.' : esc(err.message)}</div>`; return; }
    CATS = c.data || []; ITEMS = i.data || []; SUPS = s.data || [];
    render();
  }

  const visible = it => (showArch || it.active) && (cat === 'all' || it.category === cat)
    && (!supF || (supF === 'none' ? !(it.suppliers || []).length : (it.suppliers || []).some(x => x.supplier_id === supF)))
    && (!q || (it.name + ' ' + it.sku + ' ' + (it.spec_it || '')).toLowerCase().includes(q));

  function render() {
    const box = $('supplies'); box.innerHTML = '';
    const act_ = ITEMS.filter(x => x.active);
    // toolbar: categories, supplier filter, search, archived
    const bar = document.createElement('div'); bar.className = 'nodirty sup-bar';
    const chip = (code, label, n) => { const b = document.createElement('span'); b.className = 'pchip' + (cat === code ? ' on' : ''); b.innerHTML = `${esc(label)} <small>${n}</small>`; b.onclick = () => { cat = code; render(); }; return b; };
    const chips = document.createElement('div'); chips.append(chip('all', 'Tutte', act_.length));
    CATS.forEach(k => chips.append(chip(k.code, k.name_it, act_.filter(x => x.category === k.code).length)));
    const f = document.createElement('div'); f.className = 'sup-filters';
    const ss = document.createElement('select'); ss.innerHTML = `<option value="">Tutti i fornitori</option><option value="none">Senza fornitore</option>` + SUPS.map(p => `<option value="${p.id}">${esc(p.legal_name)}</option>`).join(''); ss.value = supF; ss.onchange = () => { supF = ss.value; render(); };
    const qs = document.createElement('input'); qs.type = 'search'; qs.placeholder = 'Cerca articolo…'; qs.value = q; qs.oninput = () => { q = qs.value.trim().toLowerCase(); renderList(); };
    const ar = document.createElement('label'); ar.className = 'status'; ar.innerHTML = `<input type="checkbox" ${showArch ? 'checked' : ''}> mostra archiviati`; ar.querySelector('input').onchange = e => { showArch = e.target.checked; render(); };
    f.append(ss, qs, ar); bar.append(chips, f); box.append(bar);
    const list = document.createElement('div'); list.id = 'sup-list'; box.append(list);
    const ob = document.createElement('div'); ob.id = 'sup-order'; ob.className = 'nodirty sup-order'; box.append(ob);
    renderList(); renderOrderBar();
  }

  function renderList() {
    const list = $('sup-list'); list.innerHTML = '';
    const cats = cat === 'all' ? CATS : CATS.filter(k => k.code === cat);
    let shown = 0;
    cats.forEach(k => {
      const rows = ITEMS.filter(it => it.category === k.code && visible(it));
      if (!rows.length && (q || supF)) return;   // filtering: hide empty groups; otherwise keep them so items can be added
      shown += rows.length;
      const sec = document.createElement('section'); sec.className = 'sup-cat';
      sec.innerHTML = `<h4>${esc(k.name_it)} <small class="status">${rows.length} articoli${k.hint_it ? ' · ' + esc(k.hint_it) : ''}</small></h4>`;
      const tbl = document.createElement('table'); tbl.className = 'sup';
      tbl.innerHTML = '<tr><th>Articolo</th><th>Fornitori e prezzo</th><th>Magazzino</th><th class="num">Da ordinare</th><th></th></tr>';
      rows.forEach(it => tbl.append(row(it)));
      if (W && !q) tbl.append(addRow(k));
      const wrap = document.createElement('div'); wrap.style.overflowX = 'auto'; wrap.append(tbl); sec.append(wrap); list.append(sec);
    });
    if (!shown && (q || supF)) list.innerHTML = '<div class="empty">Nessun articolo con questi filtri.</div>';
  }

  function row(it) {
    const tr = document.createElement('tr'); if (!it.active) tr.className = 'arch';
    const sups = it.suppliers || [];
    const inp = (type, v, ph = '', cls = '') => { const i = document.createElement('input'); i.type = type; i.value = v ?? ''; i.placeholder = ph; if (cls) i.className = cls; i.disabled = !W; return i; };
    // 1 · item
    const t1 = document.createElement('td');
    const name = inp('text', it.name, 'nome', 'nm'), unit = inp('text', it.unit, 'unità', 'un'), spec = inp('text', it.spec_it === 'elenco di partenza' ? '' : it.spec_it, 'formato / note (es. tanica 10 l)', 'sp');
    const cs = document.createElement('select'); cs.disabled = !W; cs.innerHTML = CATS.map(k => `<option value="${k.code}" ${k.code === it.category ? 'selected' : ''}>${esc(k.name_it)}</option>`).join('');
    const l2 = document.createElement('div'); l2.className = 'sup-l2'; l2.append(unit, cs);
    const meta = document.createElement('small'); meta.className = 'status'; meta.textContent = it.sku + (it.spec_it === 'elenco di partenza' ? ' · elenco di partenza' : '') + (it.last_ordered_on ? ' · ultimo ordine ' + fmtD(it.last_ordered_on) : '') + (it.open_po ? ' · ordine aperto' : '');
    t1.append(name, l2, spec, meta);
    // 2 · suppliers
    const t2 = document.createElement('td'); t2.className = 'nodirty';
    sups.forEach(s => {
      const c = document.createElement('div'); c.className = 'schip' + (s.preferred ? ' pref' : '');
      const star = document.createElement('button'); star.type = 'button'; star.className = 'x st'; star.textContent = s.preferred ? '★' : '☆'; star.title = s.preferred ? 'Fornitore preferito (lo usa il bot Acquisti)' : 'Rendi preferito'; star.disabled = !W || s.preferred;
      star.onclick = () => act(star, async () => { const { error } = await sb.rpc('link_supplier_item', { p_product_id: it.id, p_supplier_id: s.supplier_id, p_make_preferred: true }); if (error) throw error; await load(); }, 'Fornitore preferito aggiornato');
      const lab = document.createElement('span'); lab.innerHTML = `${esc(s.supplier)} <b>${price(s.price_eur)}</b>${s.price_src === 'ultimo DDT' ? ' <small>DDT</small>' : ''}${s.min_order_qty ? ` <small>min ${num(s.min_order_qty, 0)}</small>` : ''}`;
      const rm = document.createElement('button'); rm.type = 'button'; rm.className = 'x'; rm.textContent = '✕'; rm.title = 'Togli questo fornitore dall\'articolo'; rm.hidden = !W;
      rm.onclick = () => { if (!confirm(`Togliere ${s.supplier} da «${it.name}»? Lo storico prezzi resta.`)) return; act(rm, async () => { const { error } = await sb.rpc('unlink_supplier_item', { p_product_id: it.id, p_supplier_id: s.supplier_id }); if (error) throw error; await load(); }, 'Fornitore tolto'); };
      c.append(star, lab, rm); t2.append(c);
    });
    if (!sups.length) t2.insertAdjacentHTML('beforeend', '<div class="status ko">nessun fornitore</div>');
    if (W) {
      const plus = document.createElement('button'); plus.type = 'button'; plus.className = 'btn sm sec'; plus.textContent = sups.length ? '+ Fornitore / prezzo' : '+ Fornitore';
      const form = document.createElement('div'); form.className = 'sup-add'; form.hidden = true;
      const sel = document.createElement('select'); sel.innerHTML = '<option value="">Scegli fornitore…</option>' + SUPS.map(p => `<option value="${p.id}">${esc(p.legal_name)}</option>`).join('');
      const pr = document.createElement('input'); pr.type = 'text'; pr.inputMode = 'decimal'; pr.placeholder = `€ / ${it.unit || 'unità'}`; pr.className = 'pr';
      sel.onchange = () => { const cur = sups.find(x => x.supplier_id === sel.value); pr.value = cur && cur.price_eur != null ? String(cur.price_eur).replace('.', ',') : ''; };
      const ok = document.createElement('button'); ok.type = 'button'; ok.className = 'btn sm'; ok.textContent = 'Salva';
      ok.onclick = () => act(ok, async () => { if (!sel.value) throw new Error('Scegli il fornitore'); const { error } = await sb.rpc('link_supplier_item', { p_product_id: it.id, p_supplier_id: sel.value, p_price_eur: nOrNull(pr.value), p_make_preferred: false }); if (error) throw error; await load(); }, 'Fornitore e prezzo salvati');
      form.append(sel, pr, ok); plus.onclick = () => { form.hidden = !form.hidden; if (!form.hidden) sel.focus(); };
      t2.append(plus, form);
    }
    // 3 · stock
    const t3 = document.createElement('td');
    const tk = document.createElement('label'); tk.className = 'status'; const tkc = document.createElement('input'); tkc.type = 'checkbox'; tkc.checked = it.track_stock; tkc.disabled = !W; tk.append(tkc, document.createTextNode(' conta in magazzino'));
    const rp = inp('text', it.reorder_point != null ? String(it.reorder_point).replace('.', ',') : '', 'soglia', 'n'), rq = inp('text', it.reorder_qty != null ? String(it.reorder_qty).replace('.', ',') : '', 'riordino', 'n');
    rp.inputMode = rq.inputMode = 'decimal'; rp.title = 'Sotto questa giacenza il bot Acquisti propone un ordine'; rq.title = 'Quantità che il bot propone di ordinare';
    const stk = document.createElement('div'); stk.className = 'sup-stk';
    const paint = () => { stk.innerHTML = ''; if (!tkc.checked) { stk.innerHTML = '<small class="status">solo ordine, non si conta</small>'; return; }
      const low = it.reorder_point != null && Number(it.on_hand) <= Number(it.reorder_point);
      stk.insertAdjacentHTML('beforeend', `<div class="${low ? 'ko' : ''}">giacenza <b>${num(it.on_hand, 0)}</b> ${esc(it.unit || '')}</div>`);
      const g = document.createElement('div'); g.className = 'sup-l2'; g.append(rp, rq); stk.append(g); };
    tkc.onchange = paint; paint(); t3.append(tk, stk);
    // 4 · order
    const t4 = document.createElement('td'); t4.className = 'num nodirty';
    if (it.active && O) {
      const o = ORDER.get(it.id) || {};
      if (!sups.length) t4.innerHTML = '<small class="status">serve un fornitore</small>';
      else {
        const qn = document.createElement('input'); qn.type = 'text'; qn.inputMode = 'decimal'; qn.className = 'q'; qn.placeholder = it.unit || 'qtà'; qn.value = o.qty ? String(o.qty).replace('.', ',') : '';
        let sv = o.supplier_id && sups.some(x => x.supplier_id === o.supplier_id) ? o.supplier_id : sups[0].supplier_id;
        const est = document.createElement('small'); est.className = 'status';
        const upd_ = () => { let v = null; try { v = nOrNull(qn.value); } catch { v = null; qn.classList.add('bad'); return; } qn.classList.remove('bad');
          if (v && v > 0) ORDER.set(it.id, { qty: v, supplier_id: sv }); else ORDER.delete(it.id);
          const s = sups.find(x => x.supplier_id === sv); est.textContent = v && s && s.price_eur != null ? eur(v * s.price_eur) : ''; renderOrderBar(); };
        qn.oninput = upd_; t4.append(qn);
        if (sups.length > 1) { const so = document.createElement('select'); so.className = 'os'; so.innerHTML = sups.map(s => `<option value="${s.supplier_id}">${esc(s.supplier)}</option>`).join(''); so.value = sv; so.onchange = () => { sv = so.value; upd_(); }; t4.append(document.createElement('br'), so); }
        t4.append(document.createElement('br'), est); if (o.qty) upd_();
      }
    }
    // 5 · save / archive
    const t5 = document.createElement('td'); t5.style.whiteSpace = 'nowrap';
    if (W) {
      t5.append(saveBtn(async () => {
        const nm = name.value.trim(); if (!nm) throw new Error('Il nome è obbligatorio');
        const k = CATS.find(x => x.code === cs.value) || {};
        // saving a starter item clears its "elenco di partenza" mark (the field shows empty for those)
        const v = { name: nm, unit: unit.value.trim() || 'pz', spec_it: spec.value.trim() || null, category: cs.value, track_stock: tkc.checked,
          reorder_point: tkc.checked ? nOrNull(rp.value) : null, reorder_qty: tkc.checked ? nOrNull(rq.value) : null, updated_at: new Date().toISOString() };
        if (k.kind && k.kind !== it.kind) v.kind = k.kind;
        await upd('products', { id: it.id }, v); UI.after(load);
      }));
      const ar = document.createElement('button'); ar.type = 'button'; ar.className = 'btn sm sec'; ar.style.marginLeft = '6px';
      ar.textContent = it.active ? 'Archivia' : 'Ripristina'; ar.title = it.active ? 'Non compare più negli ordini e nel conteggio; lo storico resta' : '';
      ar.onclick = () => { if (it.active && !confirm(`Archiviare «${it.name}»?`)) return; act(ar, async () => { await upd('products', { id: it.id }, { active: !it.active, updated_at: new Date().toISOString() }); ORDER.delete(it.id); await load(); }, it.active ? 'Articolo archiviato' : 'Articolo ripristinato'); };
      t5.append(ar);
    }
    tr.append(t1, t2, t3, t4, t5); return tr;
  }

  function addRow(k) {
    const tr = document.createElement('tr'); tr.className = 'nodirty sup-new';
    const nm = document.createElement('input'); nm.type = 'text'; nm.placeholder = `Nuovo articolo in ${k.name_it}…`; nm.className = 'nm';
    const un = document.createElement('input'); un.type = 'text'; un.placeholder = 'unità (pz, kg, l…)'; un.className = 'un';
    const sp = document.createElement('input'); sp.type = 'text'; sp.placeholder = 'formato / note'; sp.className = 'sp';
    const ss = document.createElement('select'); ss.innerHTML = '<option value="">Fornitore (facoltativo)</option>' + SUPS.map(p => `<option value="${p.id}">${esc(p.legal_name)}</option>`).join('');
    const pr = document.createElement('input'); pr.type = 'text'; pr.inputMode = 'decimal'; pr.placeholder = '€ / unità'; pr.className = 'pr';
    const b = document.createElement('button'); b.type = 'button'; b.className = 'btn sm'; b.textContent = 'Aggiungi';
    b.onclick = () => act(b, async () => {
      if (!nm.value.trim()) throw new Error('Scrivi il nome dell\'articolo');
      const { error } = await sb.rpc('add_supply_item', { p_name: nm.value.trim(), p_category: k.code, p_unit: un.value.trim() || 'pz', p_supplier_id: ss.value || null, p_price_eur: nOrNull(pr.value), p_spec: sp.value.trim() || null });
      if (error) throw error; await load();
    }, 'Articolo aggiunto');
    nm.onkeydown = e => { if (e.key === 'Enter') b.click(); };
    const td = (...els) => { const t = document.createElement('td'); els.forEach(e => t.append(e)); return t; };
    const l2 = document.createElement('div'); l2.className = 'sup-l2'; l2.append(un);
    const s2 = document.createElement('div'); s2.className = 'sup-l2'; s2.append(ss, pr);
    tr.append(td(nm, l2, sp), td(s2), td(), td(), td(b)); return tr;
  }

  function renderOrderBar() {
    const ob = $('sup-order'); if (!ob) return;
    const lines = [...ORDER.entries()].map(([pid, o]) => ({ it: ITEMS.find(x => x.id === pid), ...o })).filter(l => l.it && l.it.active);
    if (!lines.length) { ob.hidden = true; ob.innerHTML = ''; return; }
    const by = {}; lines.forEach(l => { (by[l.supplier_id] = by[l.supplier_id] || []).push(l); });
    let tot = 0, noPrice = 0;
    const parts = Object.entries(by).map(([sid, ls]) => {
      const name = (SUPS.find(s => s.id === sid) || {}).legal_name || '?';
      const sub = ls.reduce((a, l) => { const s = (l.it.suppliers || []).find(x => x.supplier_id === sid); if (!s || s.price_eur == null) { noPrice++; return a; } return a + l.qty * s.price_eur; }, 0); tot += sub;
      return `<li><b>${esc(name)}</b>: ${ls.map(l => `${num(l.qty, 2).replace(/,00$/, '')} ${esc(l.it.unit || '')} ${esc(l.it.name)}`).join(', ')} <small>· ${eur(sub)}</small></li>`;
    });
    ob.hidden = false;
    ob.innerHTML = `<div><b>${lines.length} righe · ${Object.keys(by).length} ${Object.keys(by).length === 1 ? 'fornitore' : 'fornitori'} · ${eur(tot)}</b> <small class="status">IVA esclusa${noPrice ? ` · ${noPrice} senza prezzo` : ''}</small><ul>${parts.join('')}</ul></div>`;
    const note = document.createElement('input'); note.type = 'text'; note.placeholder = 'Nota per il fornitore (facoltativa)'; note.className = 'sp';
    const go = document.createElement('button'); go.type = 'button'; go.className = 'btn'; go.textContent = Object.keys(by).length === 1 ? 'Crea ordine' : `Crea ${Object.keys(by).length} ordini`;
    const clr = document.createElement('button'); clr.type = 'button'; clr.className = 'btn sec'; clr.textContent = 'Svuota';
    clr.onclick = () => { ORDER.clear(); renderList(); renderOrderBar(); };
    go.onclick = () => act(go, async () => {
      const made = [];
      for (const [sid, ls] of Object.entries(by)) {
        const { data, error } = await sb.rpc('create_manual_po', { p_supplier_id: sid, p_lines: ls.map(l => ({ product_id: l.it.id, qty: l.qty })), p_notes: note.value.trim() || null });
        if (error) { if (made.length) toast(`Creati ${made.join(', ')}; errore con il fornitore successivo`, 'err'); throw error; }
        made.push(data.po_number); ls.forEach(l => ORDER.delete(l.it.id));
      }
      await load();
      return made;
    }, made => `Creati ${made.join(', ')}: li trovi in Operazioni → Ordini da inviare ai fornitori`);
    const r = document.createElement('div'); r.className = 'sup-l2'; r.append(note, go, clr); ob.append(r);
  }

  // called from the supplier table ("N articoli" → show that supplier's items)
  function showSupplier(id) { supF = id || ''; cat = 'all'; q = ''; render(); const c = $('c-supplies'); if (c) c.scrollIntoView({ behavior: 'smooth', block: 'start' }); }

  window.SUPPLIES = { load, showSupplier };
})();
