/* Console → Incassi (v0.82): Shopify payments and bank statements matched against orders.
   Data: fabula.recon_status() for the numbers and the "da controllare" list, bank_transactions for the statement,
   bank_import() / payments_import() for files read by recon.js, recon_run() to match, recon_set_bank() / recon_ack() by hand.
   Who: area finanza — "registra" or more imports and matches, "vede" reads only. */
(() => {
  const { sb, $, esc, fmtD, toast, act } = UI;
  const eur2 = n => n == null || n === '' ? '–' : new Intl.NumberFormat('it-IT', { style: 'currency', currency: 'EUR' }).format(Number(n));
  const KIND = { payout: 'Versamento Shopify', invoice: 'Fattura', order: 'Ordine ingrosso', bank_fee: 'Spese banca', cash_deposit: 'Versamento contanti',
    transfer: 'Giroconto', expense: 'Spesa', supplier: 'Fornitore', salary: 'Stipendi', tax: 'Tasse e contributi', other: 'Altro', ignore: 'Ignorato' };
  const MANUAL = ['supplier', 'expense', 'bank_fee', 'cash_deposit', 'transfer', 'salary', 'tax', 'other', 'ignore'];
  const EXC = { order_no_payment: 'Ordine senza incasso', charge_mismatch: 'Importo diverso', tx_no_order: 'Pagamento senza ordine', payout_not_in_bank: 'Versamento non arrivato',
    payout_failed: 'Versamento non riuscito', bank_credit: 'Entrata da riconoscere', bank_debit: 'Uscita da classificare' };
  const FIELDS = {
    bank: { date: 'Data', value_date: 'Data valuta', amount: 'Importo (con segno)', debit: 'Uscite / Dare', credit: 'Entrate / Avere', description: 'Descrizione',
            counterparty: 'Controparte', ref: 'Riferimento', balance: 'Saldo' },
    payments: { id: 'ID transazione', date: 'Data', type: 'Tipo', order: 'Ordine', payout_id: 'ID versamento', payout_date: 'Data versamento', payout_status: 'Stato versamento',
                amount: 'Importo', fee: 'Commissione', net: 'Netto', payment_method: 'Metodo', currency: 'Valuta' }
  };
  let days = 60, st = null, bankFilter = 'open', file = null, edit = false, ready = false;

  async function load() {
    edit = PERM.can('finanza', 2);
    if (!ready) { ready = true; wire(); }
    const to = UI.romeISO(), from = UI.daysAgo(days);
    const { data, error } = await sb.rpc('recon_status', { p_from: from, p_to: to });
    if (error) { $('rc-tiles').innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    st = data; renderTiles(); renderExceptions(); renderPayouts(); renderImport(); await loadBank();
  }

  function wire() {
    $('rc-period').onclick = e => { const b = e.target.closest('.chip'); if (!b) return; days = Number(b.dataset.days); $('rc-period').querySelectorAll('.chip').forEach(x => x.setAttribute('aria-pressed', x === b)); load(); };
    $('rc-bank-filter').onclick = e => { const b = e.target.closest('.chip'); if (!b) return; bankFilter = b.dataset.f; $('rc-bank-filter').querySelectorAll('.chip').forEach(x => x.setAttribute('aria-pressed', x === b)); loadBank(); };
    $('rc-run').onclick = () => act($('rc-run'), async () => { const { data, error } = await sb.rpc('recon_run'); if (error) throw error; await load(); return data; },
      r => `Abbinati: ${r.payouts_matched} versamenti, ${r.invoices_paid + r.wholesale_matched} fatture/ordini, ${r.rules_applied} da regole · ${r.to_check} da controllare`);
    $('rc-run').hidden = !PERM.can('finanza', 2);
  }

  // ---------- numbers ----------
  function renderTiles() {
    const p = st.payments, po = st.payouts, b = st.bank, c = st.cash;
    const lastBank = (b.accounts || []).map(a => a.last_date).sort().pop();
    const stale = !lastBank || (Date.now() - new Date(lastBank + 'T12:00:00')) / 864e5 > 7;
    const notArrived = (st.exceptions || []).filter(e => e.kind === 'payout_not_in_bank').length;
    const tiles = [
      ['Incassato con carta', eur2(p.charges_eur), `${p.charges_n} pagamenti Shopify${Number(p.refunds_eur) ? ` · rimborsi ${eur2(p.refunds_eur)}` : ''}`],
      ['Commissioni Shopify', eur2(p.fees_eur), p.fee_pct != null ? `${String(p.fee_pct).replace('.', ',')} % dell'incassato` : 'nessun pagamento nel periodo'],
      ['Versato in banca', eur2(po.in_bank_eur), `${po.in_bank_n} di ${po.n} versamenti del periodo`],
      ['In arrivo', eur2(po.waiting_eur), notArrived ? `${notArrived} in ritardo` : `${po.waiting_n} versamenti non ancora in banca`, notArrived > 0],
      ['Contanti al banco', eur2(c.pos_cash_eur), `versati in banca ${eur2(c.deposited_eur)}`],
      ['Estratto conto', lastBank ? fmtD(lastBank) : '—', lastBank ? (stale ? 'più vecchio di 7 giorni: importa il nuovo' : 'ultimo movimento importato') : 'nessun estratto importato', stale],
      ['Da controllare', String(st.exceptions_n || 0), 'versamenti, ordini, entrate', (st.exceptions_n || 0) > 0]
    ];
    $('rc-tiles').innerHTML = tiles.map(([l, v, d, bad]) => `<div class="tile${bad ? ' bad' : ''}"><div class="l">${l}</div><div class="v" style="font-size:1.5rem">${v}</div><div class="d">${esc(d)}</div></div>`).join('');
    const warn = [];
    if (!p.last_import) warn.push('Nessun file pagamenti Shopify importato: senza quello i versamenti non si possono controllare.');
    if (c.orders_without_gateway > 0) warn.push(`${c.orders_without_gateway} ordini del periodo senza metodo di pagamento (arrivati prima che il bot Ordini Shopify lo leggesse): non entrano nei controlli carta/contanti.`);
    $('rc-warn').innerHTML = warn.map(w => `<div class="status" style="margin-top:6px">⚠ ${esc(w)}</div>`).join('');
    UI.badge('n-incassi', st.exceptions_n || 0);
  }

  // ---------- da controllare ----------
  function renderExceptions() {
    const list = st.exceptions || [], box = $('rc-exc');
    $('rc-n').textContent = st.exceptions_n ? `(${st.exceptions_n})` : '';
    if (!list.length) { box.innerHTML = '<div class="empty">Niente da controllare.</div>'; return; }
    box.innerHTML = '<table class="nw2"><tr><th>Giorno</th><th>Cosa</th><th>Dettaglio</th><th class="num">€</th><th></th></tr>' + list.map((e, i) => `<tr data-i="${i}"${e.severity === 'info' ? ' style="opacity:.75"' : ''}>
      <td>${fmtD(e.on_date)}</td><td class="${e.severity === 'info' ? '' : 'ko'}">${esc(EXC[e.kind] || e.kind)}</td><td>${esc(String(e.label_it).replace(/^(Entrata non riconosciuta|Uscita da classificare): /, ''))}</td><td class="num">${eur2(e.amount_eur)}</td>
      <td style="white-space:nowrap">${edit ? (e.bank_tx_id ? `<button class="btn sm sec" data-act="match">Abbina…</button>` : '') + ` <button class="btn sm sec" data-act="ack">Controllato</button>` : ''}</td></tr>`).join('') + '</table>';
    box.onclick = e => {
      const btn = e.target.closest('button[data-act]'); if (!btn) return;
      const tr = btn.closest('tr'), ex = list[Number(tr.dataset.i)];
      if (tr.nextElementSibling && tr.nextElementSibling.classList.contains('rc-panel')) { tr.nextElementSibling.remove(); return; }
      if (btn.dataset.act === 'ack') ackPanel(tr, ex); else matchPanel(tr, ex.bank_tx_id, Number(ex.amount_eur));
    };
  }
  function panelRow(tr, html) {
    const p = document.createElement('tr'); p.className = 'rc-panel nodirty';
    p.innerHTML = `<td colspan="${tr.children.length}" style="background:var(--tile)">${html}</td>`; tr.after(p); return p;
  }
  function ackPanel(tr, ex) {
    const p = panelRow(tr, `<div class="row"><input type="text" class="rc-note" placeholder="Perché va bene così? (obbligatorio)" style="flex:1;min-width:220px">
      <button class="btn sm" data-go>Segna come controllato</button></div>`);
    p.querySelector('[data-go]').onclick = ev => act(ev.target, async () => {
      const { error } = await sb.rpc('recon_ack', { p_key: ex.key, p_note: p.querySelector('.rc-note').value }); if (error) throw error; await load();
    }, 'Segnato come controllato');
  }
  async function matchPanel(tr, bankId, amount) {
    const p = panelRow(tr, '<div class="status">Cerco versamenti, fatture e ordini con lo stesso importo…</div>');
    const { data: c, error } = await sb.rpc('recon_candidates', { p_bank_tx: bankId });
    if (error) { p.querySelector('td').innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    const opts = [
      ...(c.payouts || []).map(x => [`payout|${x.id}`, `Versamento Shopify del ${fmtD(x.date)} · ${eur2(x.net)}${Number(x.net) !== amount ? ' (importo diverso)' : ''}`]),
      ...(c.invoices || []).map(x => [`invoice|${x.id}`, `Fattura ${x.number} del ${fmtD(x.date)} · ${x.party || ''} · ${eur2(x.total)}`]),
      ...(c.orders || []).map(x => [`order|${x.id}`, `Ordine ${x.number} del ${fmtD(x.date)} · ${x.party || ''} · ${eur2(x.total)}`])];
    const kinds = MANUAL.filter(k => amount < 0 ? !['cash_deposit'].includes(k) : !['supplier', 'salary', 'bank_fee', 'expense', 'tax'].includes(k));
    p.querySelector('td').innerHTML = `<div class="row" style="margin-top:0">
      <select class="rc-pick" style="min-width:260px">
        ${opts.length ? `<optgroup label="Stesso importo (±1 €)">${opts.map(([v, l]) => `<option value="${esc(v)}">${esc(l)}</option>`).join('')}</optgroup>` : ''}
        <optgroup label="Classifica come">${kinds.map(k => `<option value="${k}|">${KIND[k]}</option>`).join('')}</optgroup>
        ${tr.dataset.kind ? '<option value="clear|">Togli l\'abbinamento</option>' : ''}
      </select>
      <input type="text" class="rc-note" placeholder="Nota (obbligatoria per Altro e Ignorato)" style="flex:1;min-width:200px">
      <button class="btn sm" data-go>Salva</button></div>
      ${opts.length ? '' : '<div class="status" style="margin-top:6px">Nessun versamento, fattura o ordine aperto con questo importo: classificalo.</div>'}`;
    p.querySelector('[data-go]').onclick = ev => act(ev.target, async () => {
      const [kind, ref] = p.querySelector('.rc-pick').value.split('|');
      const { error } = await sb.rpc('recon_set_bank', { p_bank_tx: bankId, p_kind: kind, p_ref: ref || null, p_note: p.querySelector('.rc-note').value || null });
      if (error) throw error; await load();
    }, 'Movimento aggiornato');
  }

  // ---------- versamenti ----------
  function renderPayouts() {
    const list = st.payouts.list || [], box = $('rc-payouts');
    if (!list.length) { box.innerHTML = `<div class="empty">Nessun versamento Shopify nel periodo${st.payments.last_import ? '' : ' (importa il file pagamenti)'}.</div>`; return; }
    const late = new Set((st.exceptions || []).filter(e => e.kind === 'payout_not_in_bank').map(e => e.ref));
    box.innerHTML = '<table class="nw2"><tr><th>Data</th><th class="num">Lordo</th><th class="num">Commiss.</th><th class="num">Netto</th><th>Ordini</th><th>In banca</th></tr>' + list.map(x => `<tr>
      <td>${fmtD(x.date)}</td><td class="num">${eur2(x.gross)}</td><td class="num">${eur2(x.fee)}</td><td class="num"><b>${eur2(x.net)}</b></td><td>${x.orders || '–'}</td>
      <td>${x.bank_date ? `<span class="ok">✓ ${fmtD(x.bank_date)}</span>${x.note ? ` <span class="status">${esc(x.note)}</span>` : ''}`
            : late.has(x.id) ? '<span class="ko">non arrivato</span>' : `<span class="status">${esc({ in_transit: 'in viaggio', scheduled: 'programmato', paid: 'in attesa dell\'estratto', failed: 'non riuscito' }[x.status] || x.status || 'in attesa')}</span>`}</td></tr>`).join('') + '</table>';
  }

  // ---------- banca ----------
  async function loadBank() {
    let q = sb.from('bank_transactions').select('id,bank_account,value_date,amount_eur,description,counterparty,match_kind,match_note,matched_payout_id,invoices(invoice_number),sales_orders(order_number)')
      .gte('value_date', UI.daysAgo(days)).order('value_date', { ascending: false }).order('created_at', { ascending: false }).limit(400);
    if (bankFilter === 'open') q = q.is('match_kind', null);
    const { data, error } = await q, box = $('rc-bank');
    if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    if (!data.length) { box.innerHTML = `<div class="empty">${bankFilter === 'open' ? 'Tutti i movimenti del periodo sono abbinati o classificati.' : 'Nessun movimento nel periodo: importa l\'estratto conto.'}</div>`; return; }
    const what = r => !r.match_kind ? '<span class="ko">da abbinare</span>'
      : r.match_kind === 'invoice' ? `Fattura ${esc(r.invoices && r.invoices.invoice_number || '')}`
      : r.match_kind === 'order' ? `Ordine ${esc(r.sales_orders && r.sales_orders.order_number || '')}`
      : esc(KIND[r.match_kind] || r.match_kind);
    box.innerHTML = '<table class="nw2"><tr><th>Valuta</th><th>Conto</th><th>Descrizione</th><th class="num">€</th><th>Abbinato a</th><th></th></tr>' + data.map((r, i) => `<tr data-i="${i}"${r.match_kind ? ` data-kind="${esc(r.match_kind)}"` : ''}>
      <td>${fmtD(r.value_date)}</td><td>${esc(r.bank_account)}</td><td>${esc(r.description || '')}${r.counterparty ? ` <span class="status">${esc(r.counterparty)}</span>` : ''}</td>
      <td class="num ${Number(r.amount_eur) < 0 ? '' : 'ok'}">${eur2(r.amount_eur)}</td><td>${what(r)}${r.match_note ? ` <span class="status">${esc(r.match_note)}</span>` : ''}</td>
      <td>${edit ? '<button class="btn sm sec" data-act="match">' + (r.match_kind ? 'Cambia' : 'Abbina…') + '</button>' : ''}</td></tr>`).join('') + '</table>';
    box.onclick = e => {
      const btn = e.target.closest('button[data-act]'); if (!btn) return;
      const tr = btn.closest('tr'), r = data[Number(tr.dataset.i)];
      if (tr.nextElementSibling && tr.nextElementSibling.classList.contains('rc-panel')) { tr.nextElementSibling.remove(); return; }
      matchPanel(tr, r.id, Number(r.amount_eur));
    };
  }

  // ---------- importa ----------
  function renderImport() {
    const card = $('rc-import'); card.hidden = !edit; if (!edit) return;
    const accounts = (st.bank.accounts || []).map(a => a.account);
    $('rc-acc-list').innerHTML = accounts.map(a => `<option value="${esc(a)}">`).join('');
    if (!$('rc-acc').value) $('rc-acc').value = accounts[0] || '';
    $('rc-kind').onchange = () => { $('rc-acc-row').hidden = $('rc-kind').value !== 'bank'; if (file) preview(RECON.read(file.text, $('rc-kind').value)); };
    $('rc-acc-row').hidden = $('rc-kind').value !== 'bank';
    $('rc-file').onchange = async () => {
      const f = $('rc-file').files[0]; if (!f) return;
      if (/\.xlsx?$/i.test(f.name)) { toast('È un file Excel: aprilo e salvalo come CSV (File → Salva con nome → CSV), poi caricalo qui.', 'err'); $('rc-file').value = ''; return; }
      const buf = await f.arrayBuffer(); let text;
      try { text = new TextDecoder('utf-8', { fatal: true }).decode(buf); } catch { text = new TextDecoder('windows-1252').decode(buf); }   // many Italian banks export ANSI
      const guess = RECON.read(text);
      if (guess.kind && guess.kind !== $('rc-kind').value) { $('rc-kind').value = guess.kind; $('rc-acc-row').hidden = guess.kind !== 'bank'; toast(guess.kind === 'bank' ? 'Sembra un estratto conto: impostato "Estratto conto"' : 'Sembra il file pagamenti Shopify: impostato "Pagamenti Shopify"'); }
      file = { name: f.name, text }; preview(RECON.read(text, $('rc-kind').value));
    };
  }
  function preview(res) {
    const box = $('rc-preview'); file.res = res;
    if (res.error) { box.innerHTML = `<div class="ko" style="margin-top:8px">${esc(res.error)}</div>`; return; }
    const kind = res.kind, F = FIELDS[kind], cols = res.header.header, map = res.header.map;
    const sel = field => { const cur = Array.isArray(map[field]) ? map[field][0] : map[field];
      return `<select data-field="${field}"><option value="">—</option>${cols.map((c, i) => `<option value="${i}"${cur === i ? ' selected' : ''}>${esc(c || `colonna ${i + 1}`)}</option>`).join('')}</select>`; };
    const rows = res.rows, inn = rows.filter(r => r.amount > 0).reduce((a, r) => a + r.amount, 0), out = rows.filter(r => r.amount < 0).reduce((a, r) => a + r.amount, 0);
    const dates = rows.map(r => String(r.date).slice(0, 10)).sort();
    box.innerHTML = `<details class="nodirty" style="margin-top:8px"><summary class="status">Colonne riconosciute (correggi se serve)</summary>
        <table class="nw2" style="margin-top:6px">${Object.entries(F).map(([k, l]) => `<tr><td>${l}</td><td>${sel(k)}</td></tr>`).join('')}</table></details>
      <div class="status" style="margin-top:8px"><b>${rows.length}</b> righe${dates.length ? ` dal ${fmtD(dates[0])} al ${fmtD(dates[dates.length - 1])}` : ''} · entrate ${eur2(inn)} · uscite ${eur2(out)}
        ${kind === 'payments' ? ` · ${new Set(rows.map(r => r.payout_id).filter(Boolean)).size} versamenti` : ''}</div>
      ${res.errors.length ? `<div class="ko" style="margin-top:6px">${res.errors.length} righe non lette (data o importo non validi): ${res.errors.slice(0, 4).map(e => 'riga ' + e.line).join(', ')}${res.errors.length > 4 ? '…' : ''}</div>` : ''}
      <div style="overflow-x:auto;margin-top:6px"><table class="nw2">${kind === 'bank'
        ? '<tr><th>Data</th><th>Descrizione</th><th class="num">€</th></tr>' + rows.slice(0, 6).map(r => `<tr><td>${fmtD(r.value_date)}</td><td>${esc(r.description)}</td><td class="num">${eur2(r.amount)}</td></tr>`).join('')
        : '<tr><th>Data</th><th>Tipo</th><th>Ordine</th><th class="num">Importo</th><th class="num">Comm.</th><th>Versamento</th></tr>' + rows.slice(0, 6).map(r => `<tr><td>${fmtD(String(r.date).slice(0, 10))}</td><td>${esc(r.type)}</td><td>${esc(r.order)}</td><td class="num">${eur2(r.amount)}</td><td class="num">${eur2(r.fee)}</td><td>${esc(r.payout_id)} ${r.payout_date ? fmtD(r.payout_date) : ''}</td></tr>`).join('')}</table></div>
      <div class="row"><button class="btn" id="rc-go"${rows.length ? '' : ' disabled'}>Importa ${rows.length} righe e abbina</button></div>`;
    box.querySelectorAll('select[data-field]').forEach(s => s.onchange = () => preview(RECON.remap(file.res, s.dataset.field, s.value)));
    $('rc-go').onclick = () => act($('rc-go'), async () => {
      let r;
      if (kind === 'bank') {
        const acc = $('rc-acc').value.trim(); if (!acc) throw new Error('Scrivi il nome del conto (es. "BCC Aquara 1234")');
        r = await sb.rpc('bank_import', { p_account: acc, p_rows: rows });
      } else r = await sb.rpc('payments_import', { p_provider: 'shopify_payments', p_rows: rows, p_source: 'csv' });
      if (r.error) throw r.error;
      const m = await sb.rpc('recon_run'); if (m.error) throw m.error;
      file = null; $('rc-file').value = ''; box.innerHTML = ''; await load();
      return { i: r.data, m: m.data };
    }, x => { const dup = kind === 'bank' ? x.i.skipped : x.i.updated; return `Importate ${x.i.inserted} righe nuove${dup ? ` (${dup} già presenti)` : ''} · abbinati ${x.m.payouts_matched} versamenti · ${x.m.to_check} da controllare`; });
  }

  window.INCASSI = { load };
})();
