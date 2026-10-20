/* La Perla · Ingrosso (v0.83): richieste dei professionisti, clienti e piani consegne, calendario consegne con totali e CSV,
   listino B2B (prezzi, scaglioni) e chiusure. Legge le stesse funzioni del portale clienti (fabula.trade_*); Shopify è
   raggiunto solo dalla funzione trade-portal (approvazioni → aziende B2B, listino, ordini in coda). */
(() => {
  const { sb, $, esc, num, fmtD, dateIt, romeISO, toast, badge, saveBtn, act, upd } = UI;
  const EDGE = () => SET.edge_url || 'https://ojkquhzaeypsphncjqwy.supabase.co/functions/v1/trade-portal';
  const WD = ['', 'lunedì', 'martedì', 'mercoledì', 'giovedì', 'venerdì', 'sabato', 'domenica'], WDS = ['', 'Lun', 'Mar', 'Mer', 'Gio', 'Ven', 'Sab', 'Dom'];
  const eur2 = n => n == null ? '–' : new Intl.NumberFormat('it-IT', { style: 'currency', currency: 'EUR' }).format(n);
  const must = ({ data, error }) => { if (error) throw error; return data; };
  // v0.98 (audit TRADE-01): a delivery far above the customer's usual comes back as «… Confermi?» (P0001): ask, then send it again confirmed
  const withConfirm = async fn => { try { return await fn(false); } catch (e) {
    if (!(e && e.code === 'P0001' && /Confermi\?\s*$/.test(e.message || ''))) throw e;
    if (!confirm(e.message)) { const x = new Error('annullato'); x.silent = true; throw x; }
    return fn(true); } };
  const pIt = v => { const n = UI.parseIt(v); return Number.isFinite(n) ? n : NaN; };   // Italian numbers (11,50)
  let SET = {}, PRODS = [], TIERS = [], CUSTS = [], canManage = false;

  async function edge(action, body) {
    const { data: { session } } = await sb.auth.getSession();
    const r = await fetch(EDGE() + '?action=' + action, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + session.access_token }, body: JSON.stringify(body || {}) });
    const j = await r.json().catch(() => ({}));
    if (!r.ok && r.status !== 207) throw new Error(j.error || (j.shopify === 'not_configured' ? 'Shopify non collegato (manca il token della custom app nei segreti Supabase)' : 'Errore ' + r.status));
    return j;
  }
  async function loadSettings() {
    SET = must(await sb.rpc('trade_settings')) || {};
    const { data } = await sb.from('settings').select('key,value').like('key', 'trade.%');
    (data || []).forEach(r => { if (r.key === 'trade.edge_url') SET.edge_url = r.value; });
  }
  async function loadProds() { PRODS = must(await sb.from('trade_products').select('*').order('sort')); TIERS = must(await sb.from('trade_price_tiers').select('*').order('min_qty')); }
  const prodName = v => { const p = PRODS.find(x => x.variant_id === v); return p ? p.title + (p.variant_title ? ' ' + p.variant_title : '') : v; };

  // ---------- RICHIESTE ----------
  async function loadApps() {
    const rows = must(await sb.from('trade_applications').select('*').order('created_at', { ascending: false }).limit(200));
    const pend = rows.filter(r => r.status === 'pending'), done = rows.filter(r => r.status !== 'pending');
    badge('n-app', pend.length);
    const box = $('apps'); box.innerHTML = pend.length ? '' : '<div class="empty">Nessuna richiesta in attesa.</div>';
    pend.forEach(a => {
      const d = document.createElement('div'); d.className = 'app';
      d.innerHTML = `<div class="hd"><div><span class="pill">${esc(a.business_type)}</span><div class="t">${esc(a.business_name)}</div><div class="by">richiesta ${fmtD(a.created_at)} · ${esc(a.contact_name)} · ${esc(a.email)}${a.phone ? ' · ' + esc(a.phone) : ''}</div></div>
          <div class="amt">${a.expected_kg_week ? num(a.expected_kg_week, 0) + ' kg/sett.' : ''}</div></div>
        <div class="facts"><div><div class="l">P.IVA</div><div class="v">${esc(a.piva || '—')}</div></div><div><div class="l">Indirizzo</div><div class="v">${esc([a.address, a.postcode, a.city, a.province].filter(Boolean).join(' '))}</div></div>
          <div><div class="l">Giorni preferiti</div><div class="v">${esc(a.preferred_days || '—')}</div></div><div><div class="l">Note</div><div class="v" style="white-space:normal">${esc(a.notes || '—')}</div></div></div>
        <div class="row"><input type="text" placeholder="nota (facoltativa)" data-note><button class="btn sm" data-ok>Approva e crea l'azienda su Shopify</button><button class="btn sm warn" data-no>Rifiuta</button></div><div class="status" data-st></div>`;
      d.querySelector('[data-ok]').onclick = () => act(d.querySelector('[data-ok]'), async () => {
        const r = await edge('approve', { application_id: a.id, note: d.querySelector('[data-note]').value || null });
        const st = d.querySelector('[data-st]');
        // v1.10 (quality test item 5): a customer already in the register keeps their data; what the request says differently is listed
        const diff = (r.approved && r.approved.differences) || [];
        const diffHtml = diff.length ? `<div class="small" style="margin-top:4px">Cliente già in anagrafica: i suoi dati NON sono stati cambiati. Diversi nella richiesta: ${diff.map(x => `${esc(x.label)} «${esc(x.request)}» (in anagrafica «${esc(x.current)}»)`).join(' · ')}. Se sono giusti, correggili a mano nella scheda del cliente.</div>` : '';
        if (r.shopify === 'linked') st.innerHTML = `<span class="ok">Approvato: azienda Shopify ${r.existed ? 'già esistente, collegata' : 'creata'}.</span> Il cliente può entrare nel sito con la sua email.`;
        else if (r.shopify === 'not_configured') st.innerHTML = `<span class="ko">Approvato qui, ma Shopify non è collegato.</span> A mano in Shopify: cliente ${esc(r.manual.email)} → tag <b>${esc(r.manual.tag)}</b> e metafield <b>${esc(r.manual.metafield)}</b> = <span class="mono">${esc(r.manual.value)}</span>; poi crea l'azienda B2B (Clienti → Aziende).`;
        else st.innerHTML = `<span class="ko">Approvato qui; Shopify: ${esc(r.error || r.shopify)}.</span> Riprova da Clienti e piani → "Collega a Shopify".`;
        if (diffHtml) st.insertAdjacentHTML('beforeend', diffHtml);
        setTimeout(() => { loadApps(); loadCusts(); }, diff.length ? 15000 : 2500);
      });
      d.querySelector('[data-no]').onclick = () => act(d.querySelector('[data-no]'), async () => { await edge('reject', { application_id: a.id, note: d.querySelector('[data-note]').value || null }); loadApps(); }, 'Richiesta rifiutata');
      box.appendChild(d);
    });
    $('apps-done').innerHTML = done.length ? '<table><thead><tr><th>Data</th><th>Attività</th><th>Esito</th><th>Chi</th><th>Nota</th></tr></thead><tbody>' + done.map(a => `<tr><td>${fmtD(a.created_at)}</td><td>${esc(a.business_name)}<br><span class="small">${esc(a.email)}</span></td><td><span class="pill ${a.status === 'approved' ? 'ok' : 'ko'}">${a.status === 'approved' ? 'approvata' : 'rifiutata'}</span></td><td>${esc(a.decided_by || '')} ${fmtD(a.decided_at)}</td><td>${esc(a.decision_note || '')}</td></tr>`).join('') + '</tbody></table>' : '<div class="empty">Nessuna.</div>';
  }

  // ---------- CLIENTI E PIANI ----------
  async function loadCusts() {
    CUSTS = must(await sb.rpc('trade_customers')) || [];
    const box = $('custs'); box.innerHTML = CUSTS.length ? '' : '<div class="empty">Nessun cliente professionale ancora. Approva una richiesta o aggiungi il tag "ingrosso" a un cliente Shopify.</div>';
    CUSTS.forEach(c => box.appendChild(custCard(c)));
  }
  function custCard(c) {
    const d = document.createElement('details'); d.className = 'cust';
    const plan = c.plan, st = !plan ? '<span class="pill">nessun piano</span>' : plan.status === 'active' ? '<span class="pill ok">piano attivo</span>' : plan.status === 'paused' ? '<span class="pill ko">in pausa</span>' : '<span class="pill">annullato</span>';
    const shop = c.shopify_company_id ? '<span class="pill ok">Shopify B2B</span>' : '<span class="pill ko">non su Shopify</span>';
    d.innerHTML = `<summary><b>${esc(c.name)}</b> <span class="small">${esc(c.type || '')} · ${esc(c.city || '')}</span> ${st} ${shop} ${c.trade_status === 'suspended' ? '<span class="pill ko">accesso sospeso</span>' : ''} <span class="small">${num(c.week_kg, 1)} kg/sett.${c.exceptions ? ' · ' + c.exceptions + ' modifiche' : ''}</span></summary><div class="body" data-body></div>`;
    d.addEventListener('toggle', () => { if (d.open && !d.dataset.loaded) { d.dataset.loaded = 1; renderCust(d.querySelector('[data-body]'), c); } });
    return d;
  }
  async function renderCust(body, c) {
    body.innerHTML = '<div class="status">Carico…</div>';
    const r = must(await sb.rpc('trade_staff_action', { p_customer: c.id, p_action: 'state', p_payload: {}, p_force: false }));
    const S = r.state, days = S.settings.delivery_days;
    const plan = S.schedule, lines = S.days || {};
    let h = `<div class="small">${esc(c.email || '')} · ${esc(c.phone || '')} · P.IVA ${esc(c.piva || '—')} · pagamento ${esc(c.terms || '')} gg${c.link ? ` · <a class="lnk" href="${esc(c.link)}" target="_blank" rel="noopener">link portale</a>` : ''}</div>`;
    h += `<div style="overflow-x:auto;margin-top:8px"><table class="plan"><thead><tr><th>Prodotto</th>${days.map(x => `<th>${WDS[x]}</th>`).join('')}</tr></thead><tbody>`;
    S.products.forEach(p => { h += `<tr><td>${esc(p.title)} <span class="small">${esc(p.variant_title || '')}</span></td>${days.map(x => `<td><input type="number" min="0" step="${p.step_qty}" data-d="${x}" data-v="${esc(p.variant_id)}" value="${(lines[x] && lines[x].lines[p.variant_id]) || ''}"></td>`).join('')}</tr>`; });
    h += `<tr><td>Fascia</td>${days.map(x => `<td><select data-w="${x}">${S.settings.windows.map(w => `<option${(lines[x] && lines[x].window) === w ? ' selected' : ''}>${esc(w)}</option>`).join('')}</select></td>`).join('')}</tr></tbody></table></div>`;
    h += `<div class="row" data-scope><label>Dal <input type="date" data-start value="${plan && plan.start_date >= romeISO() ? plan.start_date : romeISO()}"></label><input type="text" data-addr placeholder="indirizzo di consegna" value="${esc(plan ? plan.delivery_address || '' : S.customer.address || '')}" style="flex:2;min-width:160px"><input type="text" data-instr placeholder="istruzioni autista" value="${esc(plan ? plan.delivery_instructions || '' : '')}" style="flex:2;min-width:160px"><span data-save></span></div>`;
    // v0.99 (audit B-24): everyday actions on one line; what stops the customer on another, each asking first
    h += `<div class="row">${plan && plan.status === 'paused' ? '<button class="btn sm" data-resume>Riprendi</button>' : ''}${c.trade_status !== 'approved' ? '<button class="btn sm" data-unsuspend>Riattiva accesso</button>' : ''}${canManage && !c.shopify_company_id ? '<button class="btn sm" data-link>Collega a Shopify</button>' : ''}</div>
      <div class="row stop"><span class="small">Fermano il cliente:</span>${plan && plan.status === 'active' ? '<button class="btn sm sec" data-pause>Pausa senza data</button>' : ''}${c.trade_status === 'approved' ? '<button class="btn sm sec" data-suspend>Sospendi accesso</button>' : ''}${canManage ? '<button class="btn sm sec" data-newlink>Nuovo link portale</button>' : ''}${plan && plan.status !== 'cancelled' ? '<button class="btn sm warn" data-cancel>Annulla piano</button>' : ''}</div><div data-newlinkbox></div>`;
    h += `<h3 style="margin-top:12px">Modifiche in programma</h3>` + (S.exceptions.length ? S.exceptions.map(e => `<div class="ex"><span>${e.kind === 'skip' ? (e.note === 'pausa' ? 'Pausa' : 'Salta') : e.kind === 'override' ? esc(e.product) + ' → ' + e.qty : 'Fascia ' + esc(e.window)} · ${fmtD(e.date_from)}${e.date_to !== e.date_from ? ' → ' + fmtD(e.date_to) : ''} <span class="small">(${esc(e.created_by)})</span></span><button class="btn sm sec" data-cx="${e.id}">Annulla</button></div>`).join('') : '<div class="empty">Nessuna.</div>');
    // v0.99 (audit B-21): only the fields the chosen change needs, labelled; a quantity is required (or «Togli il prodotto», explicitly)
    h += `<div class="row exrow" data-scope><label>Cosa <select data-exk><option value="skip">Salta la consegna</option><option value="override">Quantità temporanea</option><option value="window">Fascia temporanea</option></select></label>
      <label>Dal <input type="date" data-exf min="${romeISO()}"></label><label>Al <small>(facoltativo)</small> <input type="date" data-ext min="${romeISO()}"></label>
      <label data-for="override">Prodotto <select data-exv>${S.products.map(p => `<option value="${esc(p.variant_id)}" data-u="${esc(p.unit || 'kg')}">${esc(p.title)} ${esc(p.variant_title || '')}</option>`).join('')}</select></label>
      <label data-for="override">Quantità <input type="text" inputmode="decimal" data-exq style="width:80px"> <span data-exu>${esc((S.products[0] || {}).unit || 'kg')}</span></label>
      <label data-for="override" class="chk"><input type="checkbox" data-exrm> Togli il prodotto</label>
      <label data-for="window">Fascia <select data-exw>${S.settings.windows.map(w => `<option>${esc(w)}</option>`).join('')}</select></label><span data-exadd></span></div>`;
    h += `<h3 style="margin-top:12px">Ultime conferme</h3><div class="small">${S.log.slice(0, 6).map(l => `${new Date(l.at).toLocaleString('it-IT', { dateStyle: 'short', timeStyle: 'short' })} · ${esc(l.message)}`).join('<br>')}</div>`;
    body.innerHTML = h;
    const sa = (action, payload, force) => sb.rpc('trade_staff_action', { p_customer: c.id, p_action: action, p_payload: payload, p_force: !!force }).then(must);
    const reload = async () => { body.dataset.loaded = ''; await renderCust(body, c); loadCusts(); };
    body.querySelector('[data-save]').appendChild(saveBtn(async () => {
      const dd = {}; body.querySelectorAll('input[data-d]').forEach(i => { const q = pIt(i.value) || 0; if (q > 0) { dd[i.dataset.d] = dd[i.dataset.d] || { window: body.querySelector(`select[data-w="${i.dataset.d}"]`).value, lines: {} }; dd[i.dataset.d].lines[i.dataset.v] = q; } });
      await withConfirm(conf => sa('save_schedule', { start_date: body.querySelector('[data-start]').value, address: body.querySelector('[data-addr]').value, instructions: body.querySelector('[data-instr]').value, days: dd, can_confirm: true, ...(conf ? { confirm: true } : {}) }));
      reload();
    }, 'Salva il piano'));
    const bind = (sel, fn, ok) => { const b = body.querySelector(sel); if (b) b.onclick = () => act(b, async () => { await fn(); reload(); }, ok); };
    const no = () => { const e = new Error('annullato'); e.silent = true; return e; };
    bind('[data-pause]', () => { if (!confirm(`Mettere in pausa il piano di ${c.name} senza data di fine?\nNessuna consegna finché non premi «Riprendi». Il cliente lo vede nel portale.`)) throw no(); return sa('set_status', { status: 'paused' }); }, 'Piano in pausa');
    bind('[data-resume]', () => sa('set_status', { status: 'active' }), 'Piano riattivato');
    bind('[data-cancel]', () => { if (!confirm(`Annullare il piano consegne di ${c.name}?\nLe consegne future non si prenotano più; quelle già prenotate restano.`)) throw no(); return sa('set_status', { status: 'cancelled' }); }, 'Piano annullato');
    bind('[data-suspend]', () => { if (!confirm(`Sospendere l'accesso di ${c.name}?\nNiente consegne e il portale non funziona finché non lo riattivi.`)) throw no(); return sa('set_trade_status', { trade_status: 'suspended' }); }, 'Accesso sospeso: niente consegne finché non lo riattivi');
    bind('[data-unsuspend]', () => sa('set_trade_status', { trade_status: 'approved' }), 'Accesso riattivato');
    { const nb = body.querySelector('[data-newlink]'); if (nb) nb.onclick = () => act(nb, async () => {
        if (!confirm(`Creare un nuovo link del portale per ${c.name}?\nIl link attuale smette di funzionare subito: va mandato al cliente quello nuovo.`)) throw no();
        await sa('new_link', {});
        const c2 = (must(await sb.rpc('trade_customers')) || []).find(x => x.id === c.id) || {};
        const box = body.querySelector('[data-newlinkbox]');
        box.innerHTML = c2.link ? `<div class="status" style="margin:6px 0">Nuovo link: <span class="mono">${esc(c2.link)}</span> · <a class="lnk" href="#" data-cp>Copia</a>${c.phone ? ` · <a class="lnk" target="_blank" href="https://wa.me/${esc(UI.waNumber(c.phone))}?text=${encodeURIComponent('Buongiorno, ecco il nuovo link per i vostri ordini: ' + c2.link)}">💬 WhatsApp</a>` : ''}<br>Se il cliente entra dal sito con la sua email: premi «Collega a Shopify» per aggiornare la chiave.</div>` : '<div class="status">Nuovo link creato.</div>';
        const cp = box.querySelector('[data-cp]'); if (cp) cp.onclick = e => { e.preventDefault(); navigator.clipboard.writeText(c2.link).then(() => toast('Link copiato')); };
      }, 'Nuovo link creato: il vecchio non funziona più'); }
    bind('[data-link]', async () => { const r = await edge('link', { party_id: c.id }); if (r.shopify !== 'linked') throw new Error(r.error || (r.shopify === 'not_configured' ? 'Shopify non collegato (token custom app mancante)' : r.shopify)); }, 'Azienda Shopify collegata');
    body.querySelectorAll('[data-cx]').forEach(b => b.onclick = () => act(b, async () => { await sa('cancel_exception', { id: b.dataset.cx }, true); reload(); }, 'Modifica annullata'));
    const exr = body.querySelector('.exrow'), exk = exr.querySelector('[data-exk]');
    const exShow = () => { exr.querySelectorAll('[data-for]').forEach(l => { l.hidden = l.dataset.for !== exk.value; });
      const sel = exr.querySelector('[data-exv]'); exr.querySelector('[data-exu]').textContent = (sel.selectedOptions[0] || {}).dataset ? sel.selectedOptions[0].dataset.u : 'kg';
      exr.querySelector('[data-exq]').disabled = exr.querySelector('[data-exrm]').checked; };
    exk.onchange = exShow; exr.querySelector('[data-exv]').onchange = exShow; exr.querySelector('[data-exrm]').onchange = exShow; exShow();
    body.querySelector('[data-exadd]').appendChild(saveBtn(async () => {
      const k = exk.value, sel = exr.querySelector('[data-exv]'), rm = exr.querySelector('[data-exrm]').checked, qRaw = exr.querySelector('[data-exq]').value.trim();
      const p = { kind: k, date_from: exr.querySelector('[data-exf]').value, date_to: exr.querySelector('[data-ext]').value || null, variant_id: sel.value, qty: null, window: exr.querySelector('[data-exw]').value };
      if (!p.date_from) throw new Error('Indica la data «Dal»');
      if (p.date_to && p.date_to < p.date_from) throw new Error('«Al» viene prima di «Dal»: controlla le date');
      const unit = (sel.selectedOptions[0] || {}).dataset ? sel.selectedOptions[0].dataset.u : 'kg', prod = (sel.selectedOptions[0] || {}).textContent || '';
      if (k === 'override') {
        if (rm) p.qty = 0;
        else { const q = pIt(qRaw); if (qRaw === '' || !(q > 0)) throw new Error('Scrivi la quantità, oppure spunta «Togli il prodotto»'); p.qty = q; }
      }
      const when = fmtD(p.date_from) + (p.date_to && p.date_to !== p.date_from ? ' → ' + fmtD(p.date_to) : '');
      const what = k === 'skip' ? 'nessuna consegna' : k === 'window' ? `consegna nella fascia ${p.window}` : p.qty === 0 ? `${prod.trim()} tolto dalla consegna` : `${prod.trim()} → ${UI.num(p.qty, p.qty % 1 ? 2 : 0)} ${unit}`;
      if (!confirm(`${c.name} · ${when}: ${what}.\nIl cliente lo vede nel suo portale. Confermi?`)) throw no();
      const r = await withConfirm(conf => sa('add_exception', { ...p, can_confirm: true, ...(conf ? { confirm: true } : {}) }, true));
      // v0.93 (audit B-20): «Salta» on a day already booked cancels that order; if it already went to Shopify, say so before anything else
      if (r && r.cancel_on_shopify) alert(r.message_it);
      else if (r && r.cancelled_orders) toast(r.message_it);
      reload();
    }, 'Aggiungi'));
  }

  // ---------- CONSEGNE ----------
  let DELIV = [], TOT = [];
  async function loadDeliv() {
    if (!$('dl-from').value) $('dl-from').value = romeISO();
    const from = $('dl-from').value, days = Number($('dl-days').value) || 14;
    [DELIV, TOT] = await Promise.all([sb.rpc('trade_upcoming', { p_from: from, p_days: days, p_customer: null }).then(must), sb.rpc('trade_daily_totals', { p_from: from, p_days: days }).then(must)]);
    const byDate = {}; (DELIV || []).forEach(d => { (byDate[d.date] = byDate[d.date] || []).push(d); });
    const box = $('deliv'); box.innerHTML = Object.keys(byDate).length ? '' : '<div class="empty">Nessuna consegna nel periodo.</div>';
    Object.keys(byDate).sort().forEach(date => {
      const rows = byDate[date], tot = (TOT || []).filter(t => t.delivery_date === date);
      const d = document.createElement('div'); d.className = 'day';
      d.innerHTML = `<div class="h"><b>${esc(dateIt(date))}</b><span class="small">${rows.length} consegne · ${num(rows.reduce((s, r) => s + Number(r.kg), 0), 1)} kg · ${eur2(rows.reduce((s, r) => s + Number(r.total_eur), 0))} netti · ${rows.filter(r => r.booked).length ? rows.filter(r => r.booked).length + ' prenotate' : 'previsione dal piano'}</span></div>
        <div class="small">Totali: ${tot.map(t => `${num(t.kg, 1)} kg ${esc(t.title)} ${esc(t.variant_title || '')}`).join(' · ')}</div>
        <table><thead><tr><th>Cliente</th><th>Fascia</th><th>Righe</th><th class="num">kg</th><th class="num">€ netti</th><th>Stato</th><th>Indirizzo</th></tr></thead><tbody>${rows.map(r => `<tr><td>${esc(r.customer)}</td><td>${esc(r.window || '')}</td><td>${r.lines.map(l => `${num(l.qty, 1)} ${esc(l.unit)} ${esc(l.title)} ${esc(l.variant_title || '')}${l.source === 'modifica' ? ' <span class="pill">modif.</span>' : ''}`).join('<br>')}</td><td class="num">${num(r.kg, 1)}</td><td class="num">${eur2(r.total_eur)}</td><td>${r.booked ? `<span class="pill ok">${esc(r.shopify_order || r.order_number)}</span>` : r.min_ok ? (r.can_change ? '<span class="pill">modificabile</span>' : '<span class="pill">da prenotare</span>') : '<span class="pill ko">sotto minimo</span>'}</td><td class="small">${esc(r.address || '')}${r.instructions ? '<br>' + esc(r.instructions) : ''}${r.po_number ? '<br>rif. ' + esc(r.po_number) : ''}</td></tr>`).join('')}</tbody></table>`;
      box.appendChild(d);
    });
    loadQueue();
  }
  async function loadQueue() {
    const q = must(await sb.from('trade_order_queue').select('*').in('status', ['pending', 'failed']).order('created_at'));
    $('queue').innerHTML = q.length ? '<table><thead><tr><th>Consegna</th><th>Ordine</th><th>Stato</th><th>Tentativi</th><th>Errore</th></tr></thead><tbody>' + q.map(r => `<tr><td>${fmtD(r.delivery_date)}</td><td>${esc(r.payload.order_number)}</td><td><span class="pill ${r.status === 'failed' ? 'ko' : ''}">${r.status}</span></td><td>${r.attempts}</td><td class="small">${esc(r.error || '')}</td></tr>`).join('') + '</tbody></table>' : '<div class="empty">Niente in coda: tutte le consegne prenotate sono già ordini Shopify.</div>';
  }
  const csv = (name, rows) => { const b = new Blob(['﻿' + rows.map(r => r.map(v => '"' + String(v ?? '').replace(/"/g, '""') + '"').join(';')).join('\n')], { type: 'text/csv;charset=utf-8' }); const a = document.createElement('a'); a.href = URL.createObjectURL(b); a.download = name; a.click(); };

  // ---------- LISTINO ----------
  async function loadListino() {
    await loadProds();
    $('prods').innerHTML = '<table><thead><tr><th>Prodotto</th><th>Variante</th><th class="num">kg/pezzo</th><th class="num">Base €</th><th class="num">Riservato €</th><th class="num">Min</th><th class="num">Passo</th><th>Attivo</th><th>Shopify</th><th></th></tr></thead><tbody>' +
      PRODS.map(p => `<tr data-scope data-v="${esc(p.variant_id)}"><td>${esc(p.title)}</td><td>${esc(p.variant_title || '')}</td><td class="num">${num(p.kg_per_unit, 2)}</td><td class="num">${eur2(p.base_price_eur)}</td><td class="num"><input type="text" inputmode="decimal" data-f="trade_price_eur" value="${p.trade_price_eur == null ? '' : String(p.trade_price_eur).replace('.', ',')}" style="width:90px"></td><td class="num"><input type="number" step="1" min="1" data-f="min_qty" value="${p.min_qty}" style="width:70px" title="pezzi interi (Shopify)"></td><td class="num"><input type="number" step="1" min="1" data-f="step_qty" value="${p.step_qty}" style="width:70px" title="pezzi interi (Shopify)"></td><td><input type="checkbox" data-f="active" ${p.active ? 'checked' : ''}></td><td class="small">${pending(p) ? '<span class="pill ko">da inviare</span> ' : ''}${p.synced_at ? 'inviato ' + fmtD(p.synced_at) : 'mai inviato'}</td><td data-save></td></tr>`).join('') + '</tbody></table>';
    $('prods').querySelectorAll('tr[data-v]').forEach(tr => tr.querySelector('[data-save]').appendChild(saveBtn(async () => {
      const row = {}; tr.querySelectorAll('[data-f]').forEach(i => { row[i.dataset.f] = i.type === 'checkbox' ? i.checked : (i.value.trim() === '' ? null : pIt(i.value)); });
      if (Object.entries(row).some(([k, v]) => k !== 'active' && Number.isNaN(v))) throw new Error('Scrivi i numeri con la virgola per i decimali (11,50)');
      const p0 = PRODS.find(x => x.variant_id === tr.dataset.v);   // v0.98 (audit D-23): «1150» for 11,50 is refused by the database too
      if (row.trade_price_eur != null && p0 && p0.base_price_eur != null && row.trade_price_eur > Number(p0.base_price_eur)) throw new Error(`Prezzo riservato ${UI.num(row.trade_price_eur, 2)} € più alto del prezzo base (${UI.num(p0.base_price_eur, 2)} €): controlla la virgola`);
      row.updated_at = new Date().toISOString();
      await upd('trade_products', { variant_id: tr.dataset.v }, row);
    })));
    $('tr-var').innerHTML = '<option value="">Tutti i prodotti</option>' + PRODS.map(p => `<option value="${esc(p.variant_id)}">${esc(p.title)} ${esc(p.variant_title || '')}</option>`).join('');
    // v0.99 (audit B-23): switching a tier on or off is a change to save (Salva), and it shows «da inviare» until Shopify has it
    const tierPending = t => SET.tier_basis === 'delivery' && (!t.synced_at || t.changed_at > t.synced_at);
    $('tiers').innerHTML = TIERS.length ? '<table><thead><tr><th>Prodotto</th><th class="num">da kg</th><th class="num">Prezzo</th><th class="num">Sconto</th><th>Attivo</th><th></th><th></th></tr></thead><tbody>' + TIERS.map(t => `<tr data-scope data-tid="${t.id}"><td>${t.variant_id ? esc(prodName(t.variant_id)) : '<i>tutti i prodotti</i>'}</td><td class="num">${num(t.min_qty, 1)}</td><td class="num">${t.price_eur != null ? eur2(t.price_eur) : '—'}</td><td class="num">${t.discount_pct != null ? num(t.discount_pct, 1) + ' %' : '—'}</td><td><input type="checkbox" data-t="${t.id}" ${t.active ? 'checked' : ''}></td><td><span class="small">${tierPending(t) ? '<span class="pill ko">da inviare</span> ' : ''}${esc(t.note || '')}</span></td><td data-tsave></td></tr>`).join('') + '</tbody></table>' : '<div class="empty">Nessuno scaglione: vale solo il prezzo riservato.</div>';
    $('tiers').querySelectorAll('tr[data-tid]').forEach(tr => tr.querySelector('[data-tsave]').appendChild(saveBtn(async () => {
      await upd('trade_price_tiers', { id: tr.dataset.tid }, { active: tr.querySelector('[data-t]').checked }); UI.after(loadListino); })));
    $('rules').innerHTML = rulesHtml(['tier_basis', 'discounts_combine', 'recurring_discount_pct', 'payment_terms_days']);
  }
  // v0.99 (audit B-22): a row differs from what Shopify was last sent → «da inviare»
  const same = (a, b) => (a == null && b == null) || (a != null && b != null && Number(a) === Number(b));
  const pending = p => p.active && p.trade_price_eur != null
    ? !(p.synced_active === true && same(p.trade_price_eur, p.synced_price_eur) && same(p.min_qty, p.synced_min_qty) && same(p.step_qty, p.synced_step_qty))
    : p.synced_price_eur != null;
  const RULE_T = { tier_basis: ['Base degli scaglioni', v => v === 'week' ? 'kg settimanali del piano' : 'kg della singola consegna (nativo Shopify)'], discounts_combine: ['Sconto ricorrente + scaglione', v => v ? 'si sommano' : 'solo il migliore'], recurring_discount_pct: ['Sconto piano consegne', v => v + ' %'], payment_terms_days: ['Pagamento', v => v + ' giorni (Net ' + v + ')'],
    min_order_kg: ['Ordine minimo per consegna', v => v + ' kg'], cutoff_time: ['Ora limite (giorno prima)', v => v], delivery_days: ['Giorni di consegna', v => v.map(x => WD[x]).join(', ')], windows: ['Fasce orarie', v => v.join(' · ')], default_window: ['Fascia proposta', v => v], horizon_days: ['Giorni mostrati nel portale', v => v], enabled: ['Sezione attiva', v => v ? 'sì' : 'no'] };
  const rulesHtml = keys => '<table>' + keys.map(k => `<tr><td>${RULE_T[k][0]}</td><td><b>${esc(RULE_T[k][1](SET[k]))}</b></td></tr>`).join('') + '</table>';

  // ---------- REGOLE ----------
  async function loadRegole() {
    const cl = must(await sb.from('trade_closures').select('*').order('date_from'));
    $('closures').innerHTML = cl.length ? cl.map(c => `<div class="ex"><span>${fmtD(c.date_from)}${c.date_to !== c.date_from ? ' → ' + fmtD(c.date_to) : ''} ${esc(c.note || '')}</span>${c.date_to >= romeISO() ? `<button class="btn sm sec" data-cl="${c.id}">Chiudi prima</button>` : '<span class="small">passata</span>'}</div>`).join('') : '<div class="empty">Nessuna chiusura.</div>';
    // no deletes from the browser (same rule as the rest of the system): a closure ends the day before today
    $('closures').querySelectorAll('[data-cl]').forEach(b => b.onclick = () => act(b, async () => { const y = UI.daysAgo(1);   /* v1.10: yesterday in Agropoli, not on the device's clock */ await upd('trade_closures', { id: b.dataset.cl }, { date_to: y, date_from: cl.find(c => c.id === b.dataset.cl).date_from > y ? y : cl.find(c => c.id === b.dataset.cl).date_from, note: 'annullata' }); loadRegole(); }, 'Chiusura annullata'));
    $('rules2').innerHTML = rulesHtml(['enabled', 'delivery_days', 'windows', 'default_window', 'min_order_kg', 'cutoff_time', 'horizon_days']);
  }

  const T = UI.tabs({ def: 'richieste', loaders: { richieste: loadApps, clienti: loadCusts, consegne: loadDeliv, listino: loadListino, regole: loadRegole } });
  UI.boot({
    page: 'ingrosso', onRefresh: async () => { await loadSettings(); await T.reload(); },
    onReady: async () => {
      canManage = PERM.can('vendite', 3);
      await loadSettings(); await loadProds();
      T.start();
      if (!T.isLoaded('richieste')) sb.from('trade_applications').select('id').eq('status', 'pending').then(({ data }) => badge('n-app', (data || []).length));
      $('dl-go').onclick = loadDeliv;
      $('dl-csv-tot').onclick = () => csv('consegne-totali-' + $('dl-from').value + '.csv', [['Data', 'Prodotto', 'Variante', 'Quantità', 'kg', 'Clienti']].concat((TOT || []).map(t => [t.delivery_date, t.title, t.variant_title, t.qty, t.kg, t.customers])));
      $('dl-csv-det').onclick = () => csv('consegne-clienti-' + $('dl-from').value + '.csv', [['Data', 'Cliente', 'Fascia', 'Prodotto', 'Quantità', 'Unità', '€/unità', 'kg', 'Stato', 'Ordine', 'Indirizzo', 'Istruzioni', 'Rif.']].concat((DELIV || []).flatMap(d => d.lines.map(l => [d.date, d.customer, d.window, l.title + ' ' + (l.variant_title || ''), l.qty, l.unit, l.price.final_price, l.kg, d.booked ? 'prenotata' : 'prevista', d.shopify_order || d.order_number || '', d.address || '', d.instructions || '', d.po_number || '']))));
      $('q-run').onclick = () => act($('q-run'), async () => { const r = await edge('run-queue', {}); if (r.configured === false) throw new Error('Shopify non collegato: mancano SHOPIFY_CLIENT_ID e SHOPIFY_CLIENT_SECRET nei segreti Supabase (' + r.pending + ' in attesa)'); loadQueue(); return r; }, r => `Inviati ${r.processed} ordini: ${r.results.filter(x => x.ok).length} creati, ${r.results.filter(x => !x.ok).length} con errore`);
      // v0.99 (audit B-22): first what would change (read from the Shopify price list now), then «Invia N modifiche»
      $('pr-sync').onclick = () => act($('pr-sync'), async () => {
        const box = $('pr-preview'); box.innerHTML = '<div class="status">Leggo il listino su Shopify…</div>';
        if (document.querySelector('#prods .dirty, #tiers .dirty')) { box.innerHTML = ''; throw new Error('Prima salva (o annulla) le righe modificate del listino'); }
        let r; try { r = await edge('prices-preview', {}); } catch (e) { box.innerHTML = '';
          if (!/azione non valida/.test(e.message || '')) throw e;            // the trade-portal function on Supabase is still the old one
          if (!confirm('Anteprima non disponibile: la funzione trade-portal su Supabase va aggiornata (v0.99).\nInviare comunque il listino come prima (senza togliere da Shopify gli scaglioni spenti)?')) return false;
          const s1 = await edge('sync-prices', {}); $('pr-sync-st').textContent = `Inviati ${s1.prices} prezzi, ${s1.rules} regole, ${s1.price_breaks} scaglioni`; loadListino(); return; }
        const ch = r.changes || [], euro = v => v == null ? '—' : /^[\d.]+$/.test(String(v)) ? eur2(Number(v)) : esc(v);
        if (!ch.length) { await edge('sync-prices', {}); loadListino();   // nothing to send: the «da inviare» marks go
          box.innerHTML = '<div class="status ok">Shopify ha già questi prezzi, minimi e scaglioni: niente da inviare.</div>'; return; }
        box.innerHTML = `<table><thead><tr><th>Prodotto</th><th>Cosa</th><th class="num">Su Shopify ora</th><th class="num">Dopo l'invio</th></tr></thead><tbody>${ch.map(c => `<tr><td>${esc(c.name)}</td><td>${esc(c.what)}</td><td class="num">${c.what === 'prezzo €' || c.what === 'tolto dal listino' ? euro(c.now) : esc(c.now ?? '—')}</td><td class="num">${c.what === 'prezzo €' ? euro(c.new) : c.new == null ? '<span class="ko">tolto</span>' : esc(c.new)}</td></tr>`).join('')}</tbody></table>
          <div class="row nodirty"><button class="btn sm" id="pr-go">Invia ${ch.length} ${ch.length === 1 ? 'modifica' : 'modifiche'} a Shopify</button><button class="btn sm sec" id="pr-no">Non inviare</button></div>`;
        $('pr-no').onclick = () => { box.innerHTML = ''; };
        $('pr-go').onclick = () => act($('pr-go'), async () => { const s2 = await edge('sync-prices', {}); box.innerHTML = '';
          $('pr-sync-st').textContent = `Inviati a Shopify: ${s2.prices} prezzi cambiati, ${s2.rules} minimi/passi, ${s2.price_breaks} scaglioni${s2.removed ? `, tolti ${s2.removed} prodotti` : ''}${s2.breaks_removed ? `, ${s2.breaks_removed} scaglioni vecchi rimossi` : ''} (base ${s2.basis === 'week' ? 'settimana' : 'consegna'})`; loadListino(); }, 'Listino inviato a Shopify');
      });
      $('tr-add').replaceWith(saveBtn(async () => {   // v0.99 (audit B-23): a price OR a discount, chosen explicitly
        const v = $('tr-var').value || null, m = pIt($('tr-min').value), kind = $('tr-kind').value, val = pIt($('tr-val').value);
        if (!(m > 0)) throw new Error('Indica da quanti kg'); if (!(val > 0)) throw new Error(kind === 'eur' ? 'Scrivi il prezzo €/kg (con la virgola per i decimali)' : 'Scrivi lo sconto %');
        must(await sb.from('trade_price_tiers').insert({ variant_id: v, min_qty: m, price_eur: kind === 'eur' ? val : null, discount_pct: kind === 'pct' ? val : null, active: true }).select());
        $('tr-min').value = ''; $('tr-val').value = ''; loadListino();
      }, 'Aggiungi'));
      $('cl-add').replaceWith(saveBtn(async () => {
        const f = $('cl-from').value, t = $('cl-to').value || f; if (!f) throw new Error('Indica la data');
        must(await sb.from('trade_closures').insert({ date_from: f, date_to: t, note: $('cl-note').value || null }).select());
        $('cl-from').value = ''; $('cl-to').value = ''; $('cl-note').value = ''; loadRegole();
      }, 'Aggiungi'));
    }
  });
})();
