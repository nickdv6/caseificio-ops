/* Owner console (v0.51) — operations only. Oggi: daily_brief() tiles + approvals gate + compliance; Operazioni: PO send, purchase signals,
   wholesale, Shopify orders, milk for the next 7 days (demand + Masseria availability in one table), effluent; Andamento: charts + monthly pack;
   Anagrafiche: Fornitori (parties + supply catalogue in supplies.js + terms/prices) | Clienti (Shopify customers; delivery plans in ingrosso.html); Ricette: doses + process presets;
   Personale: rota, hours/overtime, people (contract hours, safety roles, certificates). Shared shell (login, header, tabs, helpers) in ui.js;
   parameters, machines, bots and users in admin.html. */
(() => {
  const { sb, $, esc, eur, num, fmtD, dateIt, daysAgo, nOrNull, toast, badge, upd, saveBtn, act } = UI;
  let staff = null, PRODUCTS = {}, NICK = {}, APPR = [], briefP = null, FARM_LINK = null, FARM_POSTER = null;

  // ---------- daily brief: fetched once per refresh, shared by Oggi, Operazioni and Andamento ----------
  const getBrief = () => briefP || (briefP = sb.rpc('daily_brief').then(({ data, error }) => {
    if (error) { briefP = null; throw new Error('daily_brief: ' + error.message); }
    $('simbadge').hidden = !data.is_simulation; $('sub').textContent = 'Brief di ' + dateIt(data.date);
    return data;
  }));

  // ---------- Oggi ----------
  async function loadOggi() {
    const [b, appr, prods, nick, farm] = await Promise.all([
      getBrief(),
      sb.from('approvals').select('id, kind, summary, amount_eur, requested_by, requested_at, expires_at, payload, related_table, auto_approve_at, auto_rule').eq('status', 'pending').order('requested_at'),
      sb.from('products').select('sku, name, unit'),
      sb.from('bot_nicknames').select('agent, nickname, title_it'),
      // v0.64: the Masseria's order page. v1.03 (audit FARM-04): only for Sistema = gestisce; the poster uses the QR key (record shipments only)
      sb.rpc('farm_links').then(r => r.error ? sb.rpc('farm_order_link').then(o => ({ data: o.data ? { full: o.data, poster: o.data + '&stampa=1' } : null }), () => ({ data: null })) : r, () => ({ data: null }))]);
    FARM_LINK = farm && farm.data && farm.data.full ? new URL(farm.data.full, location.href).href : null;
    FARM_POSTER = farm && farm.data && farm.data.poster ? new URL(farm.data.poster, location.href).href : null;
    PRODUCTS = Object.fromEntries((prods.data || []).map(p => [p.sku, p]));
    NICK = Object.fromEntries((nick.data || []).map(n => [n.agent, n]));
    APPR = appr.data || [];
    const issues = complianceItems(b);
    renderFarm();
    const td = UI.romeISO(); renderTiles(b, issues); renderApprovals(td); renderHaccp(b, issues); renderStock(b.stock_finished, td);
    apprShown = true; focusAppr();
    loadAvvisi().catch(e => toast(e.message || String(e), 'err'));
    renderRecent().catch(e => toast(e.message || String(e), 'err'));   // v0.60: days left count from today, not from the brief date (yesterday)
  }

  // one list of compliance issues: the tile counts exactly the red lines the card shows
  function complianceItems(b) {
    const h = b.haccp || {}, t = b.tasks || {}, items = [];
    (h.non_conformities || []).forEach(n => items.push(['ko', `Non conformità ${esc(n.point)}: ${num(n.value)} °C${n.action ? ' · ' + esc(n.action) : ''}`]));
    (h.missing_daily_checks || []).forEach(c => items.push(['ko', `Controllo mancante: ${esc(c)}`]));
    (h.evening_cold_checks_missing || []).filter(c => !(h.missing_daily_checks || []).includes(c)).forEach(c => items.push(['ko', `Controllo serale mancante: ${esc(c)}`]));
    // the same recurring task missed several times = one line with the count, not one line per missed slot
    const od = {}; (t.overdue || []).forEach(o => { const k = o.code + '|' + o.title; (od[k] = od[k] || { o, n: 0, first: o.due }).n++; if (o.due < od[k].first) od[k].first = o.due; });
    Object.values(od).forEach(({ o, n, first }) => items.push(['ko', `Attività scaduta: ${esc(o.title)} (${esc(o.code)})${n > 1 ? ` · ${n} volte dal ${fmtD(String(first).slice(0, 10)).slice(0, 5)}` : ''}`]));
    if (t.open_non_conformities) items.push(['ko', `${t.open_non_conformities} non conformità ancora aperte`]);
    (t.calibration_due || []).forEach(c => items.push(['ko', `Taratura ${esc(c.code)} entro ${fmtD(c.due)}`]));
    (t.training_expiring || []).forEach(s => items.push(['ko', `Formazione HACCP ${esc(s.name)} scade ${fmtD(s.expires)}`]));
    const pc = b.pos_close || {};
    if (b.pos_close == null || pc.missing) items.push(['status',   // v0.60: the brief sends null (not {missing:true}) when there was no POS day
      'Nessuna vendita di cassa sincronizzata per ieri (normale se il negozio era chiuso)']);
    else if (pc.variance_eur && Math.abs(pc.variance_eur) > 0.5) items.push(['ko', `Cassa: scostamento ${eur(pc.variance_eur)} tra scontrino Z e registrato`]);
    const e = b.energy || {};
    if (e.yesterday_kwh_per_kg && e.avg_30d_kwh_per_kg && e.yesterday_kwh_per_kg > e.avg_30d_kwh_per_kg * 1.15) items.push(['ko', `Energia ${num(e.yesterday_kwh_per_kg, 2)} kWh/kg vs media ${num(e.avg_30d_kwh_per_kg, 2)}`]);
    return items;
  }

  function renderTiles(b, issues) {
    const moz = (b.production || []).find(p => /Mozzarella/.test(p.product)) || {};
    const y = b.yield || {}, st = b.sales_trend || {}, w = b.waste || {};
    const yieldDelta = y.yesterday != null && y.avg_30d != null ? y.yesterday - y.avg_30d : null;
    const salesDelta = st.same_weekday_avg_4w_eur ? (st.yesterday_eur - st.same_weekday_avg_4w_eur) / st.same_weekday_avg_4w_eur * 100 : null;
    const ko = issues.filter(i => i[0] === 'ko').length;
    const tiles = [
      ['Resa ieri', y.yesterday != null ? num(y.yesterday) + ' %' : '–', yieldDelta != null ? (yieldDelta >= 0 ? '+' : '') + num(yieldDelta) + ' vs media 30 gg' : 'nessuna produzione', yieldDelta != null && yieldDelta < -1.5],
      ['Mozzarella ieri', moz.output_kg != null ? num(moz.output_kg, 0) + ' kg' : '–', moz.milk_in_kg ? 'da ' + num(moz.milk_in_kg, 0) + ' kg latte' : '', false],
      ['Vendite ieri', eur(st.yesterday_eur), salesDelta != null ? (salesDelta >= 0 ? '+' : '') + num(salesDelta, 0) + ' % vs stesso giorno' : '', salesDelta != null && salesDelta < -15],
      ['Settimana', eur(st.week_to_date_eur), 'da lunedì', false],
      ['Scarti 7 gg', w.last_7d_pct_of_output != null ? num(w.last_7d_pct_of_output) + ' %' : '–', num(w.last_7d_kg, 0) + ' kg', (w.last_7d_pct_of_output || 0) > 10],
      ['Conformità', ko ? String(ko) : 'OK', ko ? (ko === 1 ? 'punto da verificare ↓' : 'punti da verificare ↓') : 'nessun problema', ko > 0, 'c-haccp'],
      ['Da approvare', String(APPR.length), APPR.length ? 'richieste dei bot ↓' : 'niente in attesa', APPR.length > 0, 'h-appr'],
    ];
    $('tiles').innerHTML = tiles.map(([l, v, d, bad, go]) => `<div class="tile${bad ? ' bad' : ''}${go ? ' go' : ''}"${go ? ` data-go="${go}" role="button" tabindex="0"` : ''}${l === 'Da approvare' ? ' id="tile-appr"' : ''}><div class="l">${l}</div><div class="v">${v}</div><div class="d">${d}</div></div>`).join('');
    $('tiles').querySelectorAll('[data-go]').forEach(t => { const go = () => $(t.dataset.go).scrollIntoView({ behavior: 'smooth', block: 'start' }); t.onclick = go; t.onkeydown = e => { if (e.key === 'Enter') go(); }; });
  }
  const apprCount = () => {
    const n = APPR.length; badge('n-oggi', n);
    const t = $('tile-appr'); if (t) { t.querySelector('.v').textContent = n; t.querySelector('.d').textContent = n ? 'richieste dei bot ↓' : 'niente in attesa'; t.classList.toggle('bad', n > 0); }
  };
  // v1.00 (E-13): what the bot does first, the nickname after (the database's own senders have none)
  const proposer = a => { const k = String(a.requested_by || '').replace(/^agent:/, ''), n = NICK[k]; return n ? (n.nickname ? `${n.title_it} · ${n.nickname}` : n.title_it) : k.replace(/_/g, ' ') || 'sistema'; };
  // a link in a message (console.html#oggi&appr=<id>) opens Oggi on that request, highlighted
  let wantAppr = null, apprShown = false;
  const focusAppr = () => {
    if (!wantAppr || !apprShown) return; const id = wantAppr; wantAppr = null;
    if (!/^[0-9a-f-]{36}$/i.test(id)) return;
    const el = document.querySelector(`#approvals .appr[data-id="${id}"]`);
    if (el) { el.classList.add('hl'); el.scrollIntoView({ behavior: 'smooth', block: 'center' }); setTimeout(() => el.classList.remove('hl'), 8000); return; }
    toast('Questa richiesta non è più in attesa: la trovi in «Decise di recente»');
    const r = $('c-recent'); if (r) { r.open = true; r.scrollIntoView({ behavior: 'smooth', block: 'start' }); }
  };

  // ---------- Avvisi aperti (v1.00, audit E-03/E-09): the office's notices and the open alarms, each with where to go ----------
  const LINK_OK = /^(index|console|haccp|admin|ingrosso|vendite|marketing|latte|consorzio|labels|registro)\.html(#[A-Za-z0-9=&:._-]{0,120})?$/;
  const linkLabel = l => /#oggi&appr=/.test(l) ? 'Apri la richiesta' : /^console/.test(l) ? 'Apri la Console' : /^haccp/.test(l) ? 'Apri Autocontrollo' : /^admin\.html#bots/.test(l) ? 'Apri i bot'
    : /^admin/.test(l) ? 'Apri Configurazione' : /^ingrosso/.test(l) ? 'Apri Ingrosso' : /^vendite/.test(l) ? 'Apri Vendite' : /^marketing/.test(l) ? 'Apri Marketing' : 'Apri';
  const goLink = (url, label) => url && LINK_OK.test(url) ? `<a class="go" href="${esc(url)}">${esc(label || linkLabel(url))} →</a>` : '';
  async function loadAvvisi() {
    const card = $('c-avvisi'); if (!card) return;
    const [nt, al] = await Promise.all([
      sb.from('v_active_notices').select('key, severity, title_it, items, created_at, audience, link'),
      PERM.can('sistema', 1) ? sb.from('v_bot_feed').select('id, agent, agent_title, created_at, title, action_url, action_label').eq('severity', 'alert').is('read_at', null).is('notice_key', null)
        .order('created_at', { ascending: false }).limit(30) : Promise.resolve({ data: [] })]);
    if (nt.error) throw nt.error;
    const N = nt.data || [], A = al.data || [];
    badge('n-avvisi', N.length + A.length);
    if (!N.length && !A.length) { card.hidden = true; return; }
    card.hidden = false;
    const canFix = PERM.can('sistema', 3);
    const lines = n => (Array.isArray(n.items) ? n.items : []).map(x => x && typeof x === 'object' ? (x.label_it || x.label || x.title_it || x.text) : typeof x === 'string' ? x : null).filter(Boolean);
    $('avvisi').innerHTML = [
      ...A.map(m => `<div class="av alert" data-id="${m.id}"><div class="t">${esc(m.title)}</div><div class="by">Allarme · ${esc(m.agent_title || m.agent)} · ${whenIt(m.created_at)}</div>
        <div class="ac">${goLink(m.action_url, m.action_label)}${canFix ? '<button type="button" class="lnkbtn" data-x="fix">✓ Risolto…</button>' : ''}</div>
        <div class="fixf nodirty" hidden><input type="text" maxlength="300" placeholder="Cosa è stato fatto?" aria-label="Cosa è stato fatto"><button class="btn sm" type="button" data-x="fixok">Risolto</button><button class="btn sm sec" type="button" data-x="fixno">Annulla</button></div></div>`),
      ...N.map(n => { const it = lines(n); return `<div class="av ${esc(n.severity)}"><div class="t">${esc(n.title_it)}</div><div class="by">${n.audience === 'floor' ? 'Anche sul tablet · ' : ''}dal ${whenIt(n.created_at)}</div>
        ${it.length ? `<ul>${it.slice(0, 5).map(x => `<li>${esc(x)}</li>`).join('')}${it.length > 5 ? `<li class="status">e ${it.length - 5} ${it.length - 5 === 1 ? 'altro' : 'altri'}</li>` : ''}</ul>` : ''}
        <div class="ac">${goLink(n.link)}</div></div>`; })].join('');
    const box = $('avvisi');
    box.querySelectorAll('[data-x=fix]').forEach(b => b.onclick = () => { const f = b.closest('.av').querySelector('.fixf'); f.hidden = false; b.hidden = true; f.querySelector('input').focus(); });
    box.querySelectorAll('[data-x=fixno]').forEach(b => b.onclick = () => { const c = b.closest('.av'); c.querySelector('.fixf').hidden = true; c.querySelector('[data-x=fix]').hidden = false; });
    box.querySelectorAll('.fixf input').forEach(i => i.onkeydown = e => { if (e.key === 'Enter') { e.preventDefault(); i.closest('.fixf').querySelector('[data-x=fixok]').click(); } });
    box.querySelectorAll('[data-x=fixok]').forEach(b => b.onclick = () => act(b, async () => {
      const note = b.closest('.fixf').querySelector('input').value.trim();
      if (note.length < 3) { toast('Scrivi cosa è stato fatto (almeno qualche parola)', 'err'); return false; }
      const { error } = await sb.rpc('resolve_bot_messages', { p_ids: [Number(b.closest('.av').dataset.id)], p_note: note }); if (error) throw error;
      UI.bellCount(); await loadAvvisi();
    }, 'Allarme chiuso per tutti'));
  }

  // ---------- approvals: one structured card per request; deciding one never reloads the others (notes typed elsewhere stay) ----------
  // v0.99 (audit B-12): most urgent first (recall, milk plan due within 24 h, DOP, promo, orders, posts); a request past its deadline
  // is greyed out and can't be approved (E-12); milk plans, DOP and recall ask once naming the consequence; decisions go through
  // decide_approval (signer from the login) and land in «Decise di recente», where they can be undone while nothing happened yet.
  const typeOf = a => { const p = a.payload || {}; return a.kind === 'other' ? (p.type || 'other') : (p.type === 'recipe_update' ? 'recipe_update' : a.kind); };
  const isGone = a => a.expires_at && new Date(a.expires_at) <= Date.now();
  const urgency = a => { const t = typeOf(a), due = a.expires_at ? new Date(a.expires_at) - Date.now() : Infinity;
    return t === 'recall_assessment' ? 0 : t === 'milk_plan' && due < 864e5 ? 1 : t === 'dop_declaration' ? 2 : t === 'milk_plan' ? 3 : (t === 'price_change' || t === 'sell_down') ? 4 : t === 'purchase_order' ? 5 : t === 'content_post' ? 6 : 7; };
  const sortAppr = list => list.sort((x, y) => urgency(x) - urgency(y) || String(x.expires_at || x.requested_at).localeCompare(String(y.expires_at || y.requested_at)));
  const hhmm = t => new Date(t).toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Rome' });
  const whenIt = t => new Date(t).toLocaleString('it-IT', { weekday: 'short', day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Rome' });
  const silent = () => { const e = new Error('annullato'); e.silent = true; return e; };
  async function decideRpc(id, act, note, kg, confirmed) {
    const { data, error } = await sb.rpc('decide_approval', { p_id: id, p_decision: act, p_note: note || null, p_milk_kg: kg ?? null, p_confirm: !!confirmed });
    if (error && error.hint === 'confirm') { if (!confirm(error.message)) throw silent(); return decideRpc(id, act, note, kg, true); }
    if (error) throw error;
    return data;
  }
  function renderApprovals(today) {
    const box = $('approvals'); apprCount();
    if (!APPR.length) { box.innerHTML = '<div class="empty">Niente in attesa. I bot propongono, tu decidi: tutto ciò che impegna denaro o documenti compare qui prima.</div>'; return; }
    sortAppr(APPR);
    const age = a => Math.max(0, Math.round((Date.now() - new Date(a.requested_at)) / 864e5));
    box.innerHTML = APPR.map(a => { const v = approvalView(a, today), gone = isGone(a), can = PERM.can(PERM.approvalArea(a), 3); return `
      <div class="appr${gone ? ' gone' : ''}" data-id="${a.id}">
        <div class="hd"><div><span class="kind ${v.kcls}">${v.klabel}</span><div class="t">${v.title}</div><div class="by">proposto da ${esc(proposer(a))} · ${age(a) === 0 ? 'oggi' : age(a) === 1 ? 'ieri' : age(a) + ' giorni fa'}</div></div><div class="amt">${v.amount}</div></div>
        ${v.facts ? `<div class="facts">${v.facts}</div>` : `<div class="s" style="margin:8px 0">${esc(a.summary)}</div>`}${v.more}
        ${gone ? `<div class="status ko" style="margin-top:8px">⌛ Scaduta ${whenIt(a.expires_at)}: non si approva più.${v.type === 'milk_plan' ? ' Se serve latte, ordinalo da «Decise di recente» qui sotto.' : ''}</div>`
          : a.auto_approve_at ? `<div class="status" style="margin-top:8px">⏱ Si approva da sola alle <b>${hhmm(a.auto_approve_at)}</b> se nessuno decide prima · ${esc(a.auto_rule || '')}</div>` : ''}
        ${gone ? '' : can ? `<div class="row nodirty">${v.type === 'milk_plan' ? `<label class="kgw" title="Per approvare un'altra quantità scrivi i kg">kg <input type="text" inputmode="decimal" data-kg value="${esc(UI.num(a.payload.milk_kg, 0).replace(/\./g, ''))}" style="width:90px"></label>` : ''}<input type="text" placeholder="${v.type === 'recall_assessment' ? 'Nota (obbligatoria se rifiuti)' : v.type === 'dop_declaration' ? 'Nota (cosa hai verificato)' : 'Nota (facoltativa)'}" id="note-${a.id}"><button class="btn" data-act="approved">${v.type === 'dop_declaration' ? 'Approva i dati' : 'Approva'}</button><button class="btn warn" data-act="rejected">Rifiuta</button></div>`
          : `<div class="status" style="margin-top:8px">Solo lettura: decide chi ha "gestisce" in quest'area.</div>`}
      </div>`; }).join('');
    // «Approva con … kg»: the button says it as soon as the kg change
    box.querySelectorAll('input[data-kg]').forEach(i => { const card = i.closest('.appr'), a = APPR.find(x => String(x.id) === card.dataset.id) || {}, btn = card.querySelector('[data-act=approved]');
      i.oninput = () => { const k = UI.parseIt(i.value); btn.textContent = Number.isFinite(k) && k > 0 && k !== Number(a.payload.milk_kg) ? `Approva con ${UI.num(k, 0)} kg` : 'Approva'; }; });
    box.querySelectorAll('button[data-act]').forEach(btn => btn.onclick = async () => {
      const card = btn.closest('.appr'), id = card.dataset.id, act = btn.dataset.act, a = APPR.find(x => String(x.id) === id) || {};
      const v = approvalView(a, today), p = a.payload || {};
      let note = $('note-' + id).value.trim(), kg = null;
      try {
        if (v.type === 'recall_assessment') {
          if (act === 'rejected' && !note) { toast('Scrivi nella nota perché il ritiro non serve', 'err'); $('note-' + id).focus(); return; }
          if (!confirm(act === 'approved' ? `Confermi il ritiro/richiamo del lotto ${p.lot || ''}? Vanno avvisati l'ASL e i clienti della lista.` : `Confermi che il ritiro del lotto ${p.lot || ''} non serve?\nResta nel registro con la tua nota.`)) return;
        }
        if (v.type === 'milk_plan') {
          const ki = card.querySelector('input[data-kg]'), k = ki ? UI.parseIt(ki.value) : Number(p.milk_kg);
          if (act === 'approved') {
            if (!Number.isFinite(k) || k <= 0) { toast('kg di latte: un numero maggiore di zero (per non ordinare latte usa «Rifiuta»)', 'err'); ki && ki.focus(); return; }
            if (k !== Number(p.milk_kg)) kg = k;
            if (!confirm(`Approvare ${UI.num(k, 0)} kg di latte per ${dShort(p.plan_date)}${kg != null ? ` (il piano ne proponeva ${UI.num(p.milk_kg, 0)})` : ''}?\nLa Masseria vede subito l'ordine sulla sua pagina.`)) return;
          } else if (!confirm(`Rifiutare il piano latte per ${dShort(p.plan_date)}?\nNessun latte ordinato per quel giorno: se serve lo ordini da «Decise di recente».`)) return;
        }
        if (v.type === 'dop_declaration' && act === 'approved') {
          const boxes = [...card.querySelectorAll('input[data-iss]')], seen = boxes.filter(b => b.checked).map(b => b.dataset.iss);
          if (boxes.length && seen.length < boxes.length && !note) { toast('Spunta i controlli che hai visto, o scrivi nella nota cosa hai verificato', 'err'); $('note-' + id).focus(); return; }
          if (seen.length) note = ['Visti: ' + seen.join('; '), note].filter(Boolean).join(' · ');
          if (!confirm(`Approvare i dati della dichiarazione ${p.month || ''}?\nPoi la stampi, la invii al Consorzio e la segni inviata (Decise di recente).`)) return;
        }
        card.querySelectorAll('button').forEach(b => b.disabled = true);
        const r = await decideRpc(id, act, note, kg);
        APPR = APPR.filter(x => String(x.id) !== id); card.remove(); apprCount();
        if (act === 'approved' && v.type === 'purchase_order') {   // v0.90: approved is not sent: show the next step
          let done = $('appr-done'); if (!done) { done = document.createElement('div'); done.id = 'appr-done'; $('approvals').before(done); }
          done.insertAdjacentHTML('beforeend', `<div class="status" style="margin:0 0 8px">✓ ${esc(p.po_number || 'Ordine')} approvato · <a href="#ops" class="lnk">invialo al fornitore in Operazioni →</a></div>`);
        }
        if (!APPR.length) renderApprovals(today);
        toast((r && r.next_it) || (act === 'approved' ? 'Approvato' : 'Rifiutato'));
        if (a.related_table === 'purchase_orders' && T.isLoaded('ops')) renderPoSend();
        if (v.type === 'milk_plan') renderFarm();
        renderRecent(); refreshBadges();
      } catch (e) { if (!e.silent) toast(e.message || String(e), 'err'); card.querySelectorAll('button').forEach(b => b.disabled = false); }
    });
  }

  // ---------- v0.99 (audit B-12/E-10/B-09/B-11): decided in the last 7 days, with «Annulla»; DOP declarations still to send ----------
  const ST_DEC = { approved: ['✓ approvata', 'ok'], rejected: ['✗ rifiutata', 'ko'], expired: ['⌛ scaduta', 'ko'], pending: ['da decidere', ''] };
  const milkCanReorder = m => { if (!m) return false; const t = UI.romeISO(), nowRome = new Date().toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit', hour12: false, timeZone: 'Europe/Rome' });
    return !m.other_active && (m.plan_date > t || (m.plan_date === t && nowRome < '06:00')) && new Date(m.plan_date + 'T12:00:00').getDay() !== 0; };
  const csvDl = (name, rows) => { const b = new Blob(['﻿' + rows.map(r => r.map(v => '"' + String(v ?? '').replace(/"/g, '""') + '"').join(';')).join('\n')], { type: 'text/csv;charset=utf-8' }); const a = document.createElement('a'); a.href = URL.createObjectURL(b); a.download = name; a.click(); };
  async function renderRecent() {
    const box = $('appr-recent'), dop = $('dop-send'); if (!box) return;
    const [{ data, error }, { data: dops }] = await Promise.all([
      sb.from('v_approvals_recent').select('*').order('decided_at', { ascending: false, nullsFirst: false }).limit(80),
      sb.from('v_approvals_recent').select('*').eq('type', 'dop_declaration').eq('status', 'approved')]);   // never pushed out by a busy week
    if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    const rows = data || [], toSend = (dops || []).filter(r => !(r.payload || {}).sent_at);
    // a declaration approved but not sent stays in sight until it is marked sent
    dop.innerHTML = toSend.map(r => { const p = r.payload || {}; return `<div class="appr dop" data-id="${r.id}"><div class="hd"><div><span class="kind">Consorzio DOP</span><div class="t">Dichiarazione ${esc(p.month || '')}: dati approvati, da inviare</div><div class="by">approvata da ${esc(r.decided_by || '')} · ${whenIt(r.decided_at)}</div></div><div class="amt">${UI.num(p.mozzarella_dop_kg, 0)} kg</div></div>
      <div class="row nodirty"><a class="btn sm sec" style="text-decoration:none" target="_blank" rel="noopener" href="consorzio.html?id=${esc(r.id)}">🖨 Stampa / PDF</a><button class="btn sm sec" data-csv>Scarica CSV</button></div>
      ${PERM.can('haccp', 3) ? `<div class="row nodirty"><label>Inviata il <input type="date" data-on max="${UI.romeISO()}" value="${UI.romeISO()}"></label><input type="text" data-prot placeholder="n. di protocollo, oppure come (PEC del …)"><button class="btn sm" data-sent>Segna inviata</button></div>` : '<div class="status">La segna inviata chi ha «gestisce» in Autocontrollo.</div>'}</div>`; }).join('');
    dop.querySelectorAll('.appr.dop').forEach(c => { const r = toSend.find(x => x.id === c.dataset.id), p = r.payload || {};
      c.querySelector('[data-csv]').onclick = () => csvDl('dichiarazione-consorzio-' + (p.month || '') + '.csv', [['Voce', 'Valore'], ['Mese', p.month], ['Latte ricevuto (kg)', p.milk_in_kg], ['Latte respinto (kg)', p.milk_rejected_kg], ['Latte lavorato DOP (kg)', p.milk_processed_kg], ['Mozzarella DOP (kg)', p.mozzarella_dop_kg], ['Lotti', p.batches], ['Etichette', p.labels_printed], ['Venduto (kg)', p.sold_kg]]
        .concat((p.by_product || []).map(x => ['Prodotto: ' + x.product + ' (kg)', x.kg])).concat([['Lotti DOP', (p.lots || []).join(' ')]]).map(rw => rw.map(v => typeof v === 'number' ? String(v).replace('.', ',') : v)));
      const sb2 = c.querySelector('[data-sent]'); if (sb2) sb2.onclick = () => act(sb2, async () => {
        const prot = c.querySelector('[data-prot]').value.trim(), on = c.querySelector('[data-on]').value;
        const isProt = /\d/.test(prot) && !/\s/.test(prot) && prot.length <= 40;          // «2026/1234» is a protocol; «PEC del 05/11» says how
        const { error } = await sb.rpc('dop_declaration_sent', { p_id: r.id, p_sent_on: on, p_protocol: isProt ? prot : null, p_note: isProt ? null : prot });
        if (error) throw error; renderRecent();
      }, 'Dichiarazione segnata come inviata: il compito del mese è chiuso'); });
    const list = rows.filter(r => r.status !== 'pending');
    badge('n-recent', list.length);
    if (!list.length) { box.innerHTML = '<div class="empty">Nessuna decisione negli ultimi 7 giorni.</div>'; return; }
    box.innerHTML = list.map(r => { const [lab, cls] = ST_DEC[r.status] || [r.status, ''], can = PERM.can(PERM.approvalArea(r), 3), m = r.milk;
      const redo = r.type === 'milk_plan' && (r.status === 'rejected' || r.status === 'expired') && milkCanReorder(m) && PERM.can('produzione', 3);
      return `<div class="dec" data-id="${r.id}"><div><span class="pill ${cls}">${lab}</span> <b>${esc(r.summary)}</b></div>
        <div class="small">${r.status === 'expired' ? 'nessuno ha deciso entro ' + whenIt(r.expires_at) : `${esc(r.decided_by || '')} · ${whenIt(r.decided_at)}`}${r.decision_note ? ' · ' + esc(r.decision_note) : ''}${r.type === 'dop_declaration' && (r.payload || {}).sent_at ? ` · inviata il ${fmtD((r.payload || {}).sent_on)}` : ''}</div>
        <div class="row nodirty" style="margin:4px 0 0">${!r.undo_block && can ? '<button class="btn sm sec" data-undo>↶ Annulla la decisione</button>' : `<span class="small">${r.undo_block && r.status !== 'expired' ? 'non si annulla: ' + esc(r.undo_block) : ''}</span>`}
          ${redo ? `<button class="btn sm sec" data-again>Proponi di nuovo</button><label class="kgw">Ordina <input type="text" inputmode="decimal" data-okg value="${esc(String(Math.round(Number(m.milk_kg) || 0)))}" style="width:80px"> kg</label><button class="btn sm" data-order>Ordina</button>` : ''}</div></div>`; }).join('');
    box.querySelectorAll('.dec').forEach(d => { const r = list.find(x => x.id === d.dataset.id);
      const u = d.querySelector('[data-undo]'); if (u) u.onclick = () => act(u, async () => {
        if (!confirm(`Annullare la decisione su «${r.summary}»?\nTorna tra le richieste da decidere${r.type === 'milk_plan' && r.status === 'approved' ? ' e sparisce dalla pagina della Masseria' : r.type === 'purchase_order' && r.status === 'approved' ? ' e l\'ordine non è più da inviare' : ''}.`)) return false;
        const { error } = await sb.rpc('revoke_approval', { p_id: r.id, p_note: null }); if (error) throw error;
        await loadOggi(); }, 'Decisione annullata: la richiesta è di nuovo da decidere');
      const ag = d.querySelector('[data-again]'); if (ag) ag.onclick = () => act(ag, async () => {
        const { error } = await sb.rpc('milk_order_again', { p_date: r.milk.plan_date }); if (error) throw error; await loadOggi(); }, 'Nuovo piano latte proposto: lo trovi in Da approvare');
      const od = d.querySelector('[data-order]'); if (od) od.onclick = () => act(od, async () => {
        const k = UI.parseIt(d.querySelector('[data-okg]').value);
        if (!Number.isFinite(k) || k <= 0) throw new Error('kg di latte: un numero maggiore di zero');
        if (!confirm(`Ordinare ${UI.num(k, 0)} kg di latte per ${dShort(r.milk.plan_date)}?\nLa Masseria vede subito l'ordine sulla sua pagina.`)) return false;
        const go = async conf => { const { data, error } = await sb.rpc('milk_order_again', { p_date: r.milk.plan_date, p_kg: k, p_note: 'ordinato a mano', p_confirm: conf });
          if (error && error.hint === 'confirm') { if (!confirm(error.message)) throw silent(); return go(true); } if (error) throw error; return data; };
        await go(false); await loadOggi(); renderFarm(); }, 'Latte ordinato: la Masseria lo vede sulla sua pagina');
    });
  }
  const KIND = { purchase_order: ['Ordine d’acquisto', 'po'], milk_plan: ['Piano latte', 'milk'], price_change: ['Promo scorte', ''], sell_down: ['Vendere prima', ''], recipe_update: ['Ricetta', ''], dop_declaration: ['Consorzio DOP', ''], content_post: ['Post social', 'milk'], recall_assessment: ['Sicurezza alimentare', ''], other: ['Richiesta', ''] };
  const WDAY = ['domenica', 'lunedì', 'martedì', 'mercoledì', 'giovedì', 'venerdì', 'sabato'];
  const dShort = s => s ? WDAY[new Date(s + 'T12:00:00').getDay()] + ' ' + fmtD(s) : '—';
  const eur2 = n => n == null ? '–' : new Intl.NumberFormat('it-IT', { style: 'currency', currency: 'EUR' }).format(n);
  const fact = (l, v, cls = '') => `<div><div class="l">${l}</div><div class="v ${cls}">${v}</div></div>`;
  const kgf = n => num(n, Number(n) % 1 ? 1 : 0);
  function approvalView(a, today) {
    const p = a.payload || {}, type = a.kind === 'other' ? (p.type || 'other') : (p.type === 'recipe_update' ? 'recipe_update' : a.kind);
    const prod = PRODUCTS[p.sku] || PRODUCTS[p.finished_sku] || {};
    let title = esc(a.summary), facts = '', more = '', amount = a.amount_eur != null ? eur(a.amount_eur) : '';
    switch (type) {
      case 'purchase_order':
        title = `${esc(p.po_number || 'Ordine')} · ${esc(p.supplier || '')}`;
        if (Array.isArray(p.lines)) {          // v0.99 (audit B-18): an order from the catalogue, one card with every line
          facts = fact('Righe', String(p.lines.length)) + fact('Totale', eur2(p.total_eur)) + fact('Creato da', esc(p.created_by || '—')) + fact('Consegna', fmtD(p.expected_date));
          more = `<details open><summary>Righe dell'ordine</summary>${p.lines.map(l => `<div>• ${esc(UI.num(l.qty, Number(l.qty) % 1 ? 2 : 0))} ${esc(l.unit || '')} ${esc(l.name || l.sku)} × ${l.unit_price_eur != null ? '€ ' + UI.num(l.unit_price_eur, 3) : '<span class="ko">prezzo da confermare</span>'} = ${eur2(l.total_eur)}</div>`).join('')}</details>`
            + (p.over_limit ? `<div class="status">Sopra il limite delle approvazioni automatiche (${eur2(p.limit_eur)}): serve una persona.</div>` : '')
            + (p.price_missing ? '<div class="status ko">Righe con prezzo da confermare: il totale non è quello vero. Chiedi il prezzo al fornitore prima di approvare.</div>' : '')
            + (p.price_missing ? '<div class="status ko">Ci sono prezzi da confermare con il fornitore.</div>' : '');
          break;
        }
        facts = fact('Articolo', esc(prod.name || p.sku || '—')) + fact('Quantità', `${num(p.qty, 0)} <small>${esc(p.unit || '')}</small>`) +
          fact('Prezzo', p.unit_price_eur != null ? `€ ${num(p.unit_price_eur, 3)} <small>/${esc(p.unit || '')}</small>` : '<span class="ko">da confermare</span>') +
          fact('Giacenza', `${num(p.on_hand, 0)} <small>${esc(p.unit || '')}</small>`) + fact('Consumo', p.daily_use != null ? `${num(p.daily_use, 0)} <small>${esc(p.unit || '')}/giorno</small>` : '—') +
          fact('Copertura', p.days_cover != null ? `${num(p.days_cover)} <small>giorni</small>` : '—', p.days_cover != null && p.days_cover < 5 ? 'ko' : '');
        more = p.price_missing ? '<div class="status ko">Prezzo non a listino: confermalo con il fornitore prima di approvare.</div>' : '';
        break;
      case 'milk_plan':
        title = `Latte per ${dShort(p.plan_date)}`;
        // what this milk makes (at the minimum run the plan's «need» can be far less: say both)
        const makes = p.yield_pct ? Number(p.milk_kg) * Number(p.yield_pct) / 100 : Number(p.planned_output_kg);
        facts = fact('Latte', `${num(p.milk_kg, 0)} <small>kg</small>`) + fact('Mozzarella prevista', `≈ ${kgf(makes)} <small>kg${p.yield_pct && Math.abs(makes - Number(p.planned_output_kg)) >= 1 ? ` (ne servono ≈ ${kgf(p.planned_output_kg)})` : ''}</small>`) +
          fact('Costo stimato', eur(p.est_cost_eur)) + fact('Decidere entro', a.expires_at ? new Date(a.expires_at).toLocaleString('it-IT', { weekday: 'short', hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Rome' }) + ' <small>ora italiana</small>' : '—');
        {   // v0.99 (audit B-09): the warnings that used to sit in «Come è stato calcolato»
          const w = [];
          if (p.exceeds_farm_supply) w.push(fact('Masseria', `${num(p.farm_kg_available, 0)} <small>kg disponibili</small>`, 'ko'), fact('Mancano', `${num(p.farm_shortfall_kg, 0)} <small>kg${p.capped_to_farm ? ' (piano ridotto)' : ' da altri fornitori'}</small>`, 'ko'));
          if (p.capacity_hit) w.push(fact('Capacità', 'al massimo', 'ko'));
          if (p.min_run_applied) w.push(fact('Lotto minimo', 'piano alzato', 'ko'));
          if (p.history_source && p.history_source !== 'same_weekday_4w') w.push(fact('Storico', `${esc(p.history_days ?? 0)} <small>giorni: controlla</small>`, 'ko'));
          if (!('capacity_hit' in p) && /⚠|capacità|lotto minimo/.test(a.summary || '')) w.push(fact('Attenzione', esc(String(a.summary).split('·').slice(1).join('·').trim() || 'vedi il calcolo'), 'ko'));   // proposals made before v0.99
          facts += w.join('');
        }
        more = (p.rationale ? `<details><summary>Come è stato calcolato</summary>${esc(p.rationale)}</details>` : '')
          + (FARM_LINK ? `<div class="status">Approvando, l'ordine compare subito sulla pagina della Masseria (<a href="${esc(FARM_LINK)}" target="_blank" rel="noopener">pagina ordini latte</a> · <a href="#" data-copy="${esc(FARM_LINK)}">copia link</a>); lì segnano "Visto".</div>` : '');
        break;
      case 'sell_down': case 'price_change': {
        const act = { promo_banco: 'promo al banco', offerta_ingrosso_e_promo: 'promo al banco + offerta ai clienti ingrosso', ritirare: 'ritirare dalla vendita', spingere_al_banco: 'spingere al banco' }[p.action] || p.action || '';
        const days = p.expiry && today ? Math.round((new Date(p.expiry) - new Date(today)) / 864e5) : null;
        title = `${esc(prod.name || p.sku || '')} · lotto ${esc(p.lot || '')}`;
        facts = fact('A rischio', `${kgf(p.at_risk_kg)} <small>kg</small>`, 'ko') + fact('Giacenza', `${kgf(p.on_hand_kg)} <small>kg</small>`) +
          fact('Scade', days == null ? fmtD(p.expiry) : days <= 0 ? 'oggi' : days === 1 ? 'domani' : fmtD(p.expiry), days != null && days <= 1 ? 'ko' : '') +
          fact('Prezzo', `<s style="color:var(--muted);font-weight:400">€ ${num(p.list_price_eur_kg, 2)}</s> → € ${num(p.promo_price_eur_kg, 2)} <small>/kg</small>`) + fact('Sconto', `−${esc(p.promo_pct)} %`) + fact('Azione', esc(act))
          + fact('Codice Shopify', p.shopify_code ? esc(p.shopify_code) : 'in preparazione', p.shopify_code ? '' : 'ko');
        more = `<div class="status">Approvando: il codice ${p.shopify_code ? esc(p.shopify_code) : '(lo crea il bot vendere prima)'} compare sul tablet per la cassa e vengono scritti due post già approvati, WhatsApp "oggi al banco" e storia Instagram (Marketing → Contenuti). Il codice scade alle 20:00.</div>`;
        break;
      }
      case 'recipe_update':
        title = `Ricetta ${esc(prod.name || p.finished_sku || '')} · ${esc((PRODUCTS[p.component_sku] || {}).name || p.component_sku || '')}`;
        facts = fact('Dose attuale', `${esc(p.from)} <small>${esc(p.unit || '')}</small>`) + fact('Dose proposta', `${esc(p.to)} <small>${esc(p.unit || '')}</small>`) + fact('Scostamento', `${p.deviation_pct > 0 ? '+' : ''}${num(p.deviation_pct)} %`) + fact('Lotti osservati', esc(p.batches ?? '—'));
        break;
      case 'content_post': {
        const cl = p.claims || [], blk = cl.filter(c => c.severity === 'block').length;
        title = `Post ${esc(p.platform || '')}`;
        facts = fact('Canale', esc(p.platform || '—')) + fact('Uscita', p.scheduled_at ? whenIt(p.scheduled_at) : 'senza data') + fact('Problemi nel testo', blk ? `${blk} da correggere` : 'nessuno', blk ? 'ko' : '') + fact('Avvisi', String(cl.filter(c => c.severity === 'warn').length));
        // v0.99 (audit B-13): what will be approved is the text as it is now (refreshed when the post is edited), with its picture
        more = `<details open><summary>Testo${p.edited_at ? ' <small class="ko">· modificato ' + whenIt(p.edited_at) + '</small>' : ''}</summary>${p.image_url ? `<img src="${esc(p.image_url)}" alt="" loading="lazy" style="max-width:160px;max-height:160px;border-radius:6px;float:right;margin:0 0 6px 10px">` : ''}<div style="white-space:pre-wrap;color:var(--fg)">${esc(p.caption_it || '')}${p.hashtags ? '\n' + esc(p.hashtags) : ''}</div>${cl.filter(c => c.severity !== 'info').map(c => `<div class="${c.severity === 'block' ? 'ko' : 'status'}">• ${esc(c.message)}</div>`).join('')}<div style="clear:both"><a href="marketing.html#post=${esc(p.content_id || '')}">Apri il post in Marketing ↗</a></div></details>`;
        break;
      }
      case 'recall_assessment': {
        const dist = p.distribution || [];
        title = `Valutare ritiro/richiamo · lotto ${esc(p.lot || 'n/d')}`;
        facts = fact('Analisi', esc(p.test || '')) + fact('Campione', esc(p.sample_code || '')) + fact('Destinazioni', String(dist.length), dist.length ? 'ko' : '');
        more = `<details open><summary>A chi è andato il lotto</summary>${dist.length ? dist.map(d => `<div>• ${fmtD(d.on_date)} · ${esc(d.channel || '')} · ${esc(d.customer || 'banco')} · ${num(d.qty)} kg</div>`).join('') : '<div>Nessuna uscita registrata: il lotto è tutto in giacenza (bloccato).</div>'}<div style="margin-top:6px">Approva = ritiro/richiamo deciso (avvisare ASL Salerno e clienti) · Rifiuta = non necessario, motivare nella nota. <a href="haccp.html#registro">Apri Lotti bloccati e NC</a></div></details>`;
        break;
      }
      case 'dop_declaration':
        title = `Dichiarazione Consorzio ${esc(p.month || '')}`;
        facts = fact('Latte lavorato', `${num(p.milk_processed_kg, 0)} <small>kg</small>`) + fact('Mozzarella DOP', `${num(p.mozzarella_dop_kg, 0)} <small>kg</small>`) + fact('Lotti', esc(p.batches ?? '—')) + fact('Etichette', num(p.labels_printed, 0)) + fact('Venduto', `${num(p.sold_kg, 0)} <small>kg</small>`)
          + (p.fees_estimate_eur ? fact('Contributo stimato', `€ ${num(Number(p.fees_estimate_eur.consorzio || 0) + Number(p.fees_estimate_eur.rina_variable || 0), 2)}`) : '')
          + (Array.isArray(p.issues) ? fact('Controlli disciplinare', p.issues.length ? `${p.issues.length} da vedere` : 'tutto ok', p.issues.length ? 'ko' : '') : '');
        {   // v0.63: what the Consorzio/RINA will ask about, then how to send it
          const iss = Array.isArray(p.issues) ? p.issues : [];
          const one = x => typeof x !== 'object' || !x ? esc(x)
            : x.hours != null ? `${esc(x.lot)} (latte ${esc(x.milk_lot)}, ${num(x.hours, 0)} h)`
            : x.fat_pct !== undefined ? `${esc(x.milk_lot)} del ${esc(x.date)}: grasso ${num(x.fat_pct, 2)} %, proteine ${num(x.protein_pct, 2)} %`
            : Object.values(x).map(v => esc(v)).join(' · ');
          const det = d => Array.isArray(d) ? d.slice(0, 8).map(one).join('; ') : '';
          more = `<details${iss.length ? ' open' : ''}><summary>Controlli e invio</summary>`
            + (iss.length ? '<div class="status">Spunta ogni controllo dopo averlo guardato (o scrivi nella nota cosa hai verificato):</div>' + iss.map(i => `<label class="ko" style="display:block"><input type="checkbox" data-iss="${esc(i.it)}"> ${esc(i.it)}: ${esc(i.n)}${det(i.detail) ? ` <small>(${det(i.detail)})</small>` : ''}</label>`).join('') : '<div class="status">Nessun problema su 60 h, grasso/proteine, fornitori DOP e tracciabilità.</div>')
            + ((p.by_product || []).length ? `<div>${p.by_product.map(x => `${esc(x.product)}: ${num(x.kg, 0)} kg in ${esc(x.batches)} lotti`).join(' · ')}</div>` : '')
            + `<div class="status">Approvando approvi i dati: poi la stampi (o scarichi il CSV), la invii al Consorzio e la segni inviata. Il compito del mese si chiude solo allora.</div></details>`;
        }
        break;
    }
    const [klabel, kcls] = KIND[type] || KIND.other;
    return { type, title, facts, more, amount, klabel, kcls };
  }
  // v0.64: the next approved milk order and whether the Masseria has seen it on its order page
  async function renderFarm() {
    const box = $('approvals'); if (!box) return;
    let el = $('farm-status'); if (!el) { el = document.createElement('div'); el.id = 'farm-status'; el.className = 'status'; el.style.margin = '0 0 10px'; box.parentNode.insertBefore(el, box); }
    const [pl, sh, road] = await Promise.all([
      sb.from('milk_plans').select('plan_date, milk_kg, farm_seen_at').eq('status', 'approved').gte('plan_date', UI.romeISO()).order('plan_date').limit(1),
      sb.from('milk_shipments').select('milk_lot, kg, shipped_at, status, received_at, recorded_by').neq('status', 'cancelled').order('shipped_at', { ascending: false }).limit(1),   // v0.65
      sb.from('milk_shipments').select('id, milk_lot, kg, shipped_at, original_kg, recorded_by').eq('status', 'shipped').order('shipped_at').limit(20)]);              // v0.94
    const m = pl.data && pl.data[0], s = sh.data && sh.data[0], onRoad = road.data || [];
    const when = t => new Date(t).toLocaleString('it-IT', { weekday: 'short', hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Rome' });
    const ageH = t => Math.round((Date.now() - new Date(t)) / 36e5);
    const parts = [];
    if (s && !(s.status === 'shipped' && onRoad.length)) parts.push(`🚚 Ultima spedizione Masseria: ${num(s.kg, 1)} kg (${esc(s.milk_lot)}, partita ${when(s.shipped_at)}${s.recorded_by ? ', da ' + esc(s.recorded_by) : ''}) · ${s.status === 'received' ? 'ricevuta ' + when(s.received_at) : s.status === 'rejected' ? '<b class="ko">respinta</b>' : '<b class="ko">in viaggio: confermala all\'arrivo dal tablet</b>'}`);
    // v0.94 (audit A-10/FARM-03): every load still «in viaggio», the stale ones (> 36 h) in red with a way to close them
    const canCancel = PERM.can('produzione', 2);
    onRoad.forEach(x => { const stale = ageH(x.shipped_at) > 36;
      parts.push(`🚚 ${stale ? '<b class="ko">' : ''}In viaggio da ${ageH(x.shipped_at) < 1 ? 'meno di 1 ora' : ageH(x.shipped_at) + ' h'}: ${num(x.kg, 1)} kg (${esc(x.milk_lot)}, partita ${when(x.shipped_at)}${x.recorded_by ? ', da ' + esc(x.recorded_by) : ''})${stale ? '</b> · mai confermata all\'arrivo: se il latte è arrivato confermala dal tablet, altrimenti annullala' : ' · confermala all\'arrivo dal tablet'}`
        + (x.original_kg != null ? ` · peso corretto dalla Masseria (prima ${num(x.original_kg, 1)} kg)` : '')
        + (canCancel ? ` · <a href="#" data-cancel-ship="${esc(x.id)}" data-lot="${esc(x.milk_lot)}">annulla</a>` : '')); });
    if (m) parts.push(`🥛 Ordine ${esc(dShort(m.plan_date))}: ${num(m.milk_kg, 0)} kg · ${m.farm_seen_at ? 'visto ' + when(m.farm_seen_at) : '<b class="ko">non ancora visto</b>'}`);
    // v1.03 (audit FARM-04): the full link opens everything (orders, history, corrections): it goes to the farm's owner only
    if (FARM_LINK) parts.push(`<a href="${esc(FARM_LINK)}" target="_blank" rel="noopener">pagina Masseria</a> · <a href="#" data-copy="${esc(FARM_LINK)}">copia link</a> <small class="status">(accesso completo: solo al titolare della Masseria)</small>`
      + (FARM_POSTER ? ` · <a href="${esc(FARM_POSTER)}" target="_blank" rel="noopener">stampa QR spedizioni</a>` : '') + ` · <a href="admin.html#utenti&masseria">nuovo link o QR</a>`);
    el.innerHTML = (s || m) ? parts.join('<br>') : (FARM_LINK ? parts.join('') : '');
  }
  function renderHaccp(b, items) {
    const h = b.haccp || {};
    $('haccp').innerHTML = items.length ? '<ul style="margin:0;padding-left:18px">' + items.map(([c, s]) => `<li class="${c}">${s}</li>`).join('') + '</ul>' : `<div class="ok">${h.checks_logged || 0} controlli registrati, nessuna anomalia.</div>`;
  }

  // ---------- tab badges (cheap counts, refreshed after every decision) ----------
  async function refreshBadges() {
    const [ap, po, ws, pl, ce] = await Promise.all([
      sb.from('approvals').select('id').eq('status', 'pending'),
      sb.from('v_pos_to_send').select('po_number'),
      sb.from('v_wholesale_tomorrow').select('order_number'),
      sb.from('v_parties_editor').select('id').eq('is_placeholder', true),
      PERM.can('personale') ? sb.from('v_certificates_expiring').select('status') : Promise.resolve({ data: [] })]);
    badge('n-oggi', (ap.data || []).length);
    const nPo = (po.data || []).length, nWs = (ws.data || []).length;
    badge('n-ops', nPo); $('n-ops').title = `${nPo} ordini da inviare · ${nWs} consegne ingrosso prenotate`;
    badge('n-anag', (pl.data || []).length); $('n-anag').title = 'segnaposto da completare';
    const bad = (ce.data || []).filter(x => x.status === 'scaduto' || x.status === 'mancante').length;
    badge('n-pers', bad); $('n-pers').title = 'attestati scaduti o mancanti';
  }

  // ---------- Operazioni: milk for the next 7 days — demand and Masseria availability in one table ----------
  async function loadMilk7() {
    const box = $('demand7'); box.innerHTML = '<div class="status">Carico…</div>'; UI.clean(box.closest('[data-scope]'));
    const [{ data: dem, error }, { data: farm, error: e2 }] = await Promise.all([sb.from('v_demand_7d').select('*'), sb.from('v_farm_supply_next').select('*')]);
    if (error || e2) { box.innerHTML = `<div class="empty">${esc((error || e2).message)}</div>`; return; }
    const F = Object.fromEntries((farm || []).map(r => [r.supply_date, r])), D = Object.fromEntries((dem || []).map(r => [r.plan_date, r]));
    // production days come from the demand view; a farm day without demand is shown only if it is not a Sunday
    const dates = [...new Set([...Object.keys(D), ...Object.keys(F).filter(d => new Date(d + 'T12:00:00').getDay() !== 0)])].sort();
    if (!dates.length) { box.innerHTML = '<div class="empty">Nessun giorno di produzione nei prossimi 7 giorni.</div>'; return; }
    box.innerHTML = '';
    const tbl = document.createElement('table');
    tbl.innerHTML = '<tr><th>Giorno</th><th class="num">Banco kg</th><th class="num">Ingrosso kg</th><th class="num">Preordini kg</th><th class="num">Mozzarella kg</th><th class="num">Latte kg</th><th class="num">Masseria kg</th><th>Piano latte</th></tr>';
    const t = { r: 0, w: 0, p: 0, o: 0, m: 0, c: 0 }, inputs = [];
    dates.forEach(dt => {
      const r = D[dt] || {}, f = F[dt] || {}, d = new Date(dt + 'T12:00:00');
      const avail = f.kg_available != null ? Number(f.kg_available) : Number(r.farm_kg || 0), milk = Number(r.milk_kg || 0);
      t.r += +(r.retail_kg || 0); t.w += +(r.wholesale_kg || 0); t.p += +(r.preorder_kg || 0); t.o += +(r.output_kg || 0); t.m += milk; t.c += +(r.est_cost_eur || 0);
      const plan = r.plan_status ? `${r.plan_status === 'approved' ? 'approvato' : 'proposto'} ${num(r.plan_milk_kg, 0)} kg` : (f.planned_kg != null ? `${num(f.planned_kg, 0)} kg` : '–');
      const tr = document.createElement('tr');
      tr.innerHTML = `<td style="white-space:nowrap">${d.toLocaleDateString('it-IT', { weekday: 'short', day: 'numeric', month: 'short' })}${r.plan_date && Number(r.history_days) < 2 ? ' <small class="status" title="Meno di 2 settimane di vendite per questo giorno: la previsione banco è incerta">poco storico</small>' : ''}</td>
        <td class="num">${num(r.retail_kg, 0)}</td><td class="num" title="${esc(r.wholesale_source || '')}">${num(r.wholesale_kg, 0)}</td><td class="num">${Number(r.preorder_kg) ? num(r.preorder_kg, 0) : '–'}</td>
        <td class="num">${num(r.output_kg, 0)}</td><td class="num${r.capacity_hit ? ' ko' : ''}" title="${r.capacity_hit ? 'Serve più della capacità della caldaia' : ''}">${r.plan_date ? num(milk, 0) : '–'}${r.capacity_hit ? ' ▲' : ''}</td>`;
      const td = document.createElement('td'); td.className = 'num'; td.style.whiteSpace = 'nowrap';
      const inp = document.createElement('input'); inp.type = 'number'; inp.step = '25'; inp.min = '0'; inp.style.width = '84px'; inp.value = avail; inp.title = 'kg di latte disponibili dalla Masseria';
      const tag = document.createElement('small'); tag.className = 'status'; tag.style.display = 'block'; tag.textContent = f.source ? '' : 'predefinito';
      const mark = () => { const short = r.plan_date && milk > Number(inp.value || 0); td.classList.toggle('ko', !!short); inp.style.borderColor = short ? 'var(--warn)' : ''; inp.title = short ? `La Masseria non basta: mancano ${num(milk - Number(inp.value || 0), 0)} kg` : 'kg di latte disponibili dalla Masseria'; };
      inp.oninput = () => { mark(); tag.textContent = Number(inp.value) !== avail ? 'modificato' : f.source ? '' : 'predefinito'; };
      td.append(inp, tag); mark();
      const tdp = document.createElement('td'); tdp.innerHTML = `<small>${plan}</small>`;
      tr.append(td, tdp); tbl.append(tr); inputs.push({ dt, inp, orig: avail });
    });
    const tf = document.createElement('tr'); tf.style.fontWeight = '600';
    tf.innerHTML = `<td>Totale</td><td class="num">${num(t.r, 0)}</td><td class="num">${num(t.w, 0)}</td><td class="num">${t.p ? num(t.p, 0) : '–'}</td><td class="num">${num(t.o, 0)}</td><td class="num">${num(t.m, 0)}</td><td></td><td><small>${t.c ? '€ ' + num(t.c, 0) + ' latte' : ''}</small></td>`;
    tbl.append(tf);
    const wrap = document.createElement('div'); wrap.style.overflowX = 'auto'; wrap.append(tbl); box.append(wrap);
    const bar = document.createElement('div'); bar.className = 'row';
    bar.append(saveBtn(async () => {
      const ch = inputs.filter(x => String(x.inp.value) !== String(x.orig));
      if (!ch.length) { toast('Nessuna modifica'); return; }
      if (ch.some(x => x.inp.value === '' || Number(x.inp.value) < 0)) throw new Error('Inserisci i kg disponibili (0 o più)');
      const { error } = await sb.from('farm_supply').upsert(ch.map(x => ({ supply_date: x.dt, kg_available: Number(x.inp.value), source: 'console', notes: 'da ' + staff.full_name })), { onConflict: 'supply_date' });
      if (error) throw error; loadMilk7();
    }, 'Salva disponibilità Masseria'));
    box.append(bar);
    const rows = dates.map(d => D[d]).filter(Boolean);
    const capDays = rows.filter(r => r.capacity_hit).length, shortDays = rows.filter(r => Number(r.farm_gap_kg) < 0).length;
    const note = document.createElement('div'); note.className = 'status'; note.style.marginTop = '6px';
    note.innerHTML = (rows[0] ? `Resa usata ${num(rows[0].yield_pct, 1)}% (media 30 gg). ` : '') + (capDays ? `<span class="ko">${capDays} giorni oltre la capacità della caldaia (▲): anticipare produzione o aumentare i turni.</span> ` : '')
      + (shortDays ? `<span class="ko">${shortDays} giorni la Masseria non basta: serve latte da altri fornitori.</span> ` : 'La Masseria copre tutti i giorni. ')
      + `"predefinito" = latte disponibile dalla Masseria quando non c'è un dato per il giorno (<a class="lnk" href="admin.html#produzione">Configurazione → Produzione e latte</a>).`;
    box.append(note);
  }

  // ---------- Personale: people — contract hours, safety designations, certificates (one Salva per person) ----------
  const DESIG = [['primo_soccorso', 'Primo soccorso'], ['antincendio', 'Antincendio'], ['preposto', 'Preposto'], ['rls', 'RLS']];
  async function loadStaffCard() {
    const box = $('set-staff');
    const [{ data: rows, error }, { data: exp }, { data: cfg }] = await Promise.all([
      sb.from('staff').select('id, full_name, role, contract_hours_week, designations, active').eq('active', true).order('full_name'),
      sb.from('v_certificates_expiring').select('*'),
      sb.from('settings').select('value').eq('key', 'labor.contract_hours_week').maybeSingle()]);
    if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    const defH = Number(cfg?.value || 40), edit = PERM.can('personale', 3);
    box.innerHTML = rows && rows.length ? '' : '<div class="empty">Nessuna persona attiva.</div>';
    (rows || []).forEach(r => {
      const mine = (exp || []).filter(x => x.staff_id === r.id);
      const bad = mine.filter(x => x.status === 'scaduto' || x.status === 'mancante'), soon = mine.filter(x => x.status !== 'scaduto' && x.status !== 'mancante');
      const row = document.createElement('div'); row.className = 'set-row';
      const lines = [...bad.map(x => `<span class="ko">${esc(x.course_name)}: ${x.status === 'scaduto' ? 'scaduto il ' + fmtD(x.expires_on) : 'manca'}</span>`),
                     ...soon.map(x => `${esc(x.course_name)}: scade ${fmtD(x.expires_on)} (${x.days_left} gg)`)];
      row.innerHTML = `<div class="lbl"><b>${esc(r.full_name)}</b><small>${esc(r.role)}${lines.length ? '<br>' + lines.join('<br>') : ' · attestati in regola'}</small></div>`;
      const right = document.createElement('div'); right.className = 'row'; right.style.cssText = 'margin-top:0;flex-wrap:wrap;gap:6px 10px;justify-content:flex-end';
      const hl = document.createElement('label'); hl.style.cssText = 'display:flex;gap:4px;align-items:center;font-size:.85rem';
      const h = document.createElement('input'); h.type = 'number'; h.step = '0.5'; h.min = '0'; h.style.width = '64px'; h.value = r.contract_hours_week ?? ''; h.placeholder = String(defH); h.disabled = !edit; h.title = `Vuoto = ${defH} h (valore aziendale)`;
      hl.append('Ore/sett.', h); right.append(hl);
      const boxes = DESIG.map(([k, l]) => { const lab = document.createElement('label'); lab.style.cssText = 'display:flex;gap:4px;align-items:center;font-size:.85rem'; const c = document.createElement('input'); c.type = 'checkbox'; c.value = k; c.checked = (r.designations || []).includes(k); c.disabled = !edit; lab.append(c, l); right.append(lab); return c; });
      if (edit) right.append(saveBtn(async () => { await upd('staff', { id: r.id }, { contract_hours_week: nOrNull(h.value), designations: boxes.filter(c => c.checked).map(c => c.value) }); UI.after(() => { loadStaffCard(); if (rotaDirty()) loadHours(isoDay(rotaMon)); else loadRota(); }); refreshBadges(); }));
      row.append(right); box.append(row);
    });
  }

  // ---------- tabs ----------
  const T = UI.tabs({
    def: 'oggi', alias: { turni: 'personale' },
    onHash: p => { if (p.appr) { wantAppr = p.appr; focusAppr(); } },   // v1.00 (E-08): console.html#oggi&appr=<id>
    loaders: {
      oggi: loadOggi,
      ops: async () => { const b = await getBrief(); renderProcurement(b.procurement_signals); await Promise.all([renderPoSend(), renderWholesale(), loadMilk7(), loadEffluent(), loadShopifyOrders()]); },
      trend: loadTrend,
      anag: () => Promise.all([loadParties(), loadTerms(), window.SUPPLIES.load()]),
      ricette: () => Promise.all([loadRecipes(), loadPresets()]),
      personale: () => Promise.all([loadRota(), loadStaffCard()]),
      incassi: () => window.INCASSI.load()
    }
  });
  async function loadTrend() {
    const [b, prod, sales] = await Promise.all([getBrief(),
      sb.from('v_daily_production').select('batch_date, product, yield_pct, output_kg').ilike('product', 'Mozzarella%').gte('batch_date', daysAgo(30)).order('batch_date'),
      sb.from('v_daily_sales').select('order_date, channel, revenue_eur').gte('order_date', daysAgo(30)).order('order_date')]);
    yieldChart(prod.data || [], b.yield || {}); salesChart(sales.data || []);
  }
  async function refresh() {
    if (UI.unsaved() && !confirm('Ci sono modifiche non salvate: aggiornando le perdi. Continuare?')) return false;
    document.querySelectorAll('.dirty').forEach(e => e.classList.remove('dirty'));
    briefP = null; await Promise.all([T.reload(), refreshBadges()]);
    if (T.current !== 'oggi') getBrief().catch(() => {});
  }
  function renderStock(list, date) {
    const soon = (list || []).filter(s => s.expires && (new Date(s.expires) - new Date(date)) / 864e5 <= 2);
    $('stock').innerHTML = soon.length ? '<table><tr><th>Lotto</th><th>Prodotto</th><th class="num">kg</th><th>Scade</th></tr>' + soon.map(s => `<tr><td>${esc(s.lot)}</td><td>${esc((PRODUCTS[s.sku] || {}).name || s.sku)}</td><td class="num">${num(s.kg)}</td><td class="${s.expires <= date ? 'ko' : ''}">${fmtD(s.expires)}</td></tr>`).join('') + '</table>' : '<div class="empty">Nessun lotto in scadenza entro 2 giorni.</div>';
  }
  function renderProcurement(list) {
    // v0.90: each signal has an "Ordina" button: it opens Anagrafiche → Fornitori with the reorder quantity already in the order bar
    const canOrder = PERM.can('acquisti', 2);
    $('procurement').innerHTML = (list && list.length) ? '<table><tr><th>Articolo</th><th class="num">Giacenza</th><th class="num">Copertura</th><th class="num">Riordino</th><th></th></tr>' + list.map(p => `<tr><td>${esc(p.name)}${p.supplier ? `<br><small class="status">${esc(p.supplier)}</small>` : ''}</td><td class="num">${num(p.on_hand, 0)}</td><td class="num ${p.days_cover != null && p.days_cover < 5 ? 'ko' : ''}">${p.days_cover != null ? num(p.days_cover) + ' gg' : '–'}</td><td class="num">${num(p.reorder_qty, 0)}</td><td>${canOrder ? `<button type="button" class="btn sm sec" data-order-sku="${esc(p.sku)}" data-order-qty="${esc(p.reorder_qty ?? '')}">Ordina</button>` : ''}</td></tr>`).join('') + '</table>' : '<div class="empty">Scorte consumabili sopra il punto di riordino.</div>';
    $('procurement').querySelectorAll('[data-order-sku]').forEach(b => b.onclick = () => { window.SUPPLIES.prefill(b.dataset.orderSku, Number(b.dataset.orderQty) || null); T.show('anag'); });
  }  async function loadTerms() {
    const box = $('set-terms'); box.innerHTML = '<div class="status">Carico…</div>';
    const { data, error } = await sb.from('v_supplier_terms').select('*').order('supplier').order('sku');
    if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    if (!(data || []).length) { box.innerHTML = '<div class="empty">Nessun articolo collegato a un fornitore: imposta un prezzo di listino o il fornitore preferito.</div>'; return; }
    box.innerHTML = '';
    const tbl = document.createElement('table');
    tbl.innerHTML = '<tr><th>Fornitore</th><th>Articolo</th><th class="num">Consegna gg</th><th class="num">Minimo</th><th class="num">Multipli</th><th>Pagamento</th><th class="num">Listino €</th><th class="num">Pagato €</th><th class="num">90 gg</th><th></th></tr>';
    const ni = (v, step) => { const i = document.createElement('input'); i.type = 'number'; i.step = step; i.min = '0'; i.style.width = '70px'; i.value = v ?? ''; return i; };
    data.forEach(r => {
      const tr = document.createElement('tr');
      const trend = r.price_90d_ago_eur && r.last_paid_eur ? Math.round((r.last_paid_eur / r.price_90d_ago_eur - 1) * 1000) / 10 : null;
      tr.innerHTML = `<td>${esc(r.supplier)}${r.preferred ? ' <small class="status">preferito</small>' : ''}</td><td>${esc(r.product)} <small>${esc(r.unit || '')}</small></td>`;
      const lead = ni(r.lead_time_days, '1'), mn = ni(r.min_order_qty, 'any'), mul = ni(r.order_multiple, 'any');
      const pay = document.createElement('input'); pay.type = 'text'; pay.style.width = '110px'; pay.placeholder = 'es. 60 gg DFFM'; pay.value = r.payment_terms || '';
      [lead, mn, mul].forEach(i => { const td = document.createElement('td'); td.className = 'num'; td.append(i); tr.append(td); });
      const tdp = document.createElement('td'); tdp.append(pay); tr.append(tdp);
      const c = (html, cls = 'num') => { const td = document.createElement('td'); td.className = cls; td.innerHTML = html; tr.append(td); };
      c(r.list_price_eur != null ? num(r.list_price_eur, 3) : '–');
      c(r.last_paid_eur != null ? `${num(r.last_paid_eur, 3)}<br><small>${fmtD(r.last_paid_on)}</small>` : '–', 'num' + (r.list_price_eur && r.last_paid_eur && Number(r.last_paid_eur) > Number(r.list_price_eur) ? ' ko' : ''));
      c(trend == null ? '–' : `${trend > 0 ? '+' : ''}${num(trend, 1)}%`, 'num' + (trend > 5 ? ' ko' : ''));
      const td = document.createElement('td'); td.style.whiteSpace = 'nowrap';
      td.append(saveBtn(async () => { await upd('supplier_products', { supplier_id: r.supplier_id, product_id: r.product_id }, { lead_time_days: nOrNull(lead.value), min_order_qty: nOrNull(mn.value), order_multiple: nOrNull(mul.value), payment_terms: pay.value.trim() || null, updated_at: new Date().toISOString() }); UI.after(loadTerms); }));
      const h = document.createElement('button'); h.className = 'btn sm sec'; h.textContent = '↗'; h.title = 'Storico prezzi'; h.style.marginLeft = '4px';
      h.onclick = () => togglePriceHist(r, tr, h); td.append(h); tr.append(td);
      tbl.append(tr);
    });
    box.append(tbl);
  }
  async function togglePriceHist(r, tr, btn) {
    const nx = tr.nextElementSibling; if (nx && nx.classList.contains('hist')) { nx.remove(); btn.textContent = '↗'; return; }
    const htr = document.createElement('tr'); htr.className = 'hist nodirty'; const box = document.createElement('td'); box.colSpan = 10; box.style.background = 'var(--bg)'; htr.append(box); tr.after(htr); btn.textContent = '✕';
    box.innerHTML = '<div class="status">Carico…</div>';
    const { data, error } = await sb.from('v_supplier_price_history').select('*').eq('supplier_id', r.supplier_id).eq('product_id', r.product_id).order('price_date', { ascending: false }).limit(40);
    if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    box.innerHTML = `<h4 style="margin:4px 0 6px">Storico prezzi · ${esc(r.product)} da ${esc(r.supplier)}</h4>`;
    if (!(data || []).length) { box.innerHTML += '<div class="empty">Ancora nessun prezzo.</div>'; return; }
    const tbl = document.createElement('table');
    tbl.innerHTML = '<tr><th>Data</th><th>Fonte</th><th>Rif.</th><th class="num">Qtà</th><th class="num">€ / ' + esc(r.unit || 'unità') + '</th><th class="num">Var.</th></tr>' +
      data.map(x => `<tr><td>${fmtD(x.price_date)}</td><td>${esc(x.source)}</td><td>${esc(x.ref || '')}</td><td class="num">${x.qty != null ? num(x.qty, 0) : ''}</td><td class="num">${num(x.price_eur, 4)}</td><td class="num ${Number(x.change_pct) > 5 ? 'ko' : ''}">${x.change_pct != null ? (x.change_pct > 0 ? '+' : '') + num(x.change_pct, 1) + '%' : ''}</td></tr>`).join('');
    box.append(tbl);
  }  // ---------- Personale: weekly rota + hours/overtime ----------
  const isoDay = d => { const x = new Date(d); x.setMinutes(x.getMinutes() - x.getTimezoneOffset()); return x.toISOString().slice(0, 10); };
  const mondayOf = d => { const x = new Date(d); x.setHours(12, 0, 0, 0); x.setDate(x.getDate() - ((x.getDay() + 6) % 7)); return x; };
  let rotaMon = mondayOf(new Date()); rotaMon.setDate(rotaMon.getDate() + 7);
  const KIND_L = { F: 'ferie', P: 'permesso', M: 'malattia', R: 'riposo' }, L_KIND = { ferie: 'F', permesso: 'P', malattia: 'M', riposo: 'R' };
  const hm = t => t ? t.slice(0, 5).replace(/:00$/, '') : '';
  const cellText = e => !e ? '' : e.kind !== 'lavoro' ? L_KIND[e.kind] : `${hm(e.start_time)}-${hm(e.end_time)}${e.break_min ? '/' + e.break_min : ''}${e.area ? ' ' + e.area : ''}`;
  function parseCell(s) {
    s = (s || '').trim(); if (!s) return null;
    if (/^[FPMR]$/i.test(s)) return { kind: KIND_L[s.toUpperCase()], start_time: null, end_time: null, break_min: 0, area: null };
    const m = s.match(/^(\d{1,2})(?:[:.](\d{2}))?\s*-\s*(\d{1,2})(?:[:.](\d{2}))?(?:\s*\/\s*(\d{1,3}))?(?:\s+(.+))?$/);
    if (!m || +m[1] > 23 || +m[3] > 24) throw new Error(`Orario non valido: "${s}"`);
    const t = (h, mi) => `${String(+h % 24).padStart(2, '0')}:${mi || '00'}`;
    return { kind: 'lavoro', start_time: t(m[1], m[2]), end_time: t(m[3], m[4]), break_min: m[5] ? +m[5] : 0, area: m[6] ? m[6].trim() : null };
  }
  const cellHours = c => { if (!c || c.kind !== 'lavoro') return 0; const [a, b] = [c.start_time, c.end_time].map(x => +x.slice(0, 2) + +x.slice(3, 5) / 60); return Math.max(0, (b > a ? b - a : b + 24 - a) - c.break_min / 60); };
  let rotaReq = 0;   // v0.60: fast ◀ ▶ clicks — only the latest week renders, so a late answer can't put last week's rota under this week's dates
  async function loadRota() {
    const myReq = ++rotaReq;
    const mon = isoDay(rotaMon), sunD = new Date(rotaMon); sunD.setDate(sunD.getDate() + 6); const sun = isoDay(sunD);
    $('rota-week').textContent = `${rotaMon.toLocaleDateString('it-IT', { day: 'numeric', month: 'short' })} – ${sunD.toLocaleDateString('it-IT', { day: 'numeric', month: 'short', year: 'numeric' })}`;
    const box = $('rota-grid'); box.innerHTML = '<div class="status">Carico…</div>'; UI.clean(box.closest('[data-scope]'));
    const [{ data: people, error: e1 }, { data: rows, error: e2 }, { data: cfg }] = await Promise.all([
      sb.from('staff').select('id, full_name, role, contract_hours_week').eq('active', true).order('full_name'),
      sb.from('rota_entries').select('*').gte('work_date', mon).lte('work_date', sun),
      sb.from('settings').select('value').eq('key', 'labor.contract_hours_week').maybeSingle()]);
    if (myReq !== rotaReq) return;
    if (e1 || e2) { box.innerHTML = `<div class="empty">${esc((e1 || e2).message)}</div>`; return; }
    const defH = Number(cfg?.value || 40);
    const days = [...Array(7)].map((_, i) => { const d = new Date(rotaMon); d.setDate(d.getDate() + i); return d; });
    const byKey = {}; (rows || []).forEach(r => { byKey[r.staff_id + '|' + r.work_date] = r; });
    const tbl = document.createElement('table'); tbl.className = 'rota';
    tbl.innerHTML = '<tr><th>Persona</th>' + days.map(d => `<th>${d.toLocaleDateString('it-IT', { weekday: 'short', day: 'numeric' })}</th>`).join('') + '<th class="num">Ore</th></tr>';
    const inputs = [];
    (people || []).forEach(p => {
      const tr = document.createElement('tr'); const tdN = document.createElement('td'); tdN.innerHTML = `${esc(p.full_name)}<br><small>${esc(p.role)}</small>`; tr.append(tdN);
      const tot = document.createElement('td'); tot.className = 'num';
      const contract = Number(p.contract_hours_week || defH);
      const recompute = () => { let h = 0, bad = false; inputs.filter(x => x.p === p.id).forEach(x => { try { h += cellHours(parseCell(x.i.value)); x.i.style.borderColor = ''; } catch { bad = true; x.i.style.borderColor = 'var(--warn)'; } }); tot.innerHTML = `${num(h, 1)}<br><small>/ ${num(contract, 0)}</small>`; tot.classList.toggle('ko', h > contract || bad); };
      days.forEach(d => {
        const key = p.id + '|' + isoDay(d); const td = document.createElement('td');
        const i = document.createElement('input'); i.type = 'text'; i.style.width = '108px'; i.value = cellText(byKey[key]); i.placeholder = '—';
        i.oninput = recompute; td.append(i); tr.append(td); inputs.push({ p: p.id, date: isoDay(d), i, orig: i.value, id: byKey[key]?.id });
      });
      tr.append(tot); tbl.append(tr); recompute();
    });
    box.innerHTML = ''; box.append(tbl);
    const { data: cover } = await sb.from('v_safety_cover').select('*').gte('work_date', mon).lte('work_date', sun);
    const cv = {}; (cover || []).forEach(c => { cv[c.work_date] = c; });
    const trc = document.createElement('tr');
    trc.innerHTML = '<td><small>Primo soccorso · antincendio in turno</small></td>' + days.map(d => { const c = cv[isoDay(d)]; if (!c) return '<td></td>';
      const miss = [c.first_aid ? '' : 'PS', c.fire_warden ? '' : 'AI'].filter(Boolean);
      return `<td><small class="${miss.length ? 'ko' : 'ok'}" title="${esc([c.first_aid_names && 'PS: ' + c.first_aid_names, c.fire_warden_names && 'AI: ' + c.fire_warden_names].filter(Boolean).join(' · '))}">${miss.length ? 'manca ' + miss.join(' + ') : 'PS ✓ AI ✓'}</small></td>`; }).join('') + '<td></td>';
    tbl.append(trc);
    if (!(people || []).length) box.innerHTML = '<div class="empty">Nessuna persona attiva in anagrafica.</div>';
    $('rota-save').onclick = async () => {
      const b = $('rota-save'); b.disabled = true;
      try {
        const ups = [], dels = [];
        for (const x of inputs) {
          if (x.i.value.trim() === x.orig.trim()) continue;
          const c = parseCell(x.i.value);
          if (!c) { if (x.id) dels.push(x.id); continue; }
          ups.push({ staff_id: x.p, work_date: x.date, ...c, created_by: staff.id, updated_at: new Date().toISOString() });
        }
        if (ups.length) { const { error } = await sb.from('rota_entries').upsert(ups, { onConflict: 'staff_id,work_date' }); if (error) throw error; }
        if (dels.length) { const { data: gone, error } = await sb.from('rota_entries').delete().in('id', dels).select('id'); if (error) throw error; if ((gone || []).length < dels.length) throw new Error(PERM.NOT_SAVED); }
        UI.clean(b); toast(ups.length + dels.length ? `Turni salvati (${ups.length + dels.length})` : 'Nessuna modifica'); loadRota();
      } catch (err) { toast(err.message || String(err), 'err'); } finally { b.disabled = false; }
    };
    loadHours(mon);
  }
  async function loadHours(mon) {
    const box = $('rota-hours'); box.innerHTML = '';
    const from = new Date(mon + 'T12:00:00'); from.setDate(from.getDate() - 21);
    const { data, error } = await sb.from('v_hours_weekly').select('*').gte('week_start', isoDay(from)).lte('week_start', mon).order('week_start', { ascending: false }).order('full_name');
    if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    const week = (data || []).filter(r => r.week_start === mon);
    const tbl = document.createElement('table');
    tbl.innerHTML = '<tr><th>Persona</th><th class="num">Previste</th><th class="num">Lavorate</th><th class="num">Contratto h</th><th class="num">Straord. h</th><th class="num">Straord. €</th><th class="num">Domenica h</th><th>Note</th></tr>';
    if (!week.length) tbl.innerHTML += '<tr><td colspan="8" class="empty">Nessuna timbratura né turno in questa settimana.</td></tr>';
    week.forEach(r => {
      const tr = document.createElement('tr');
      const notes = [r.planned_no_clock_days ? `${r.planned_no_clock_days} gg in turno senza badge` : '', r.clock_no_rota_days ? `${r.clock_no_rota_days} gg timbrati fuori turno` : '', r.absence_days ? `${r.absence_days} gg assenza` : ''].filter(Boolean).join(' · ');
      tr.innerHTML = `<td>${esc(r.full_name)}</td><td class="num">${num(r.planned_h, 1)}</td><td class="num">${num(r.worked_h, 1)}</td>`;
      tr.insertAdjacentHTML('beforeend', `<td class="num">${num(r.contract_h, 1)}</td>`);
      tr.insertAdjacentHTML('beforeend', `<td class="num${Number(r.overtime_h) > 0 ? ' ko' : ''}">${num(r.overtime_h, 1)}</td><td class="num">${Number(r.overtime_eur) ? '€ ' + num(r.overtime_eur, 0) : '–'}</td><td class="num">${r.sunday_h ? num(r.sunday_h, 1) : '–'}</td><td><small>${esc(notes)}</small></td>`);
      tbl.append(tr);
    });
    box.append(tbl);
    const four = {}; (data || []).forEach(r => { const f = four[r.full_name] = four[r.full_name] || { w: 0, o: 0, e: 0 }; f.w += +r.worked_h; f.o += +r.overtime_h; f.e += +r.overtime_eur; });
    const names = Object.keys(four);
    if (names.length) { const n = document.createElement('div'); n.className = 'status'; n.style.marginTop = '8px'; n.textContent = 'Ultime 4 settimane: ' + names.map(k => `${k} ${num(four[k].w, 0)} h, straordinari ${num(four[k].o, 1)} h (€ ${num(four[k].e, 0)})`).join(' · '); box.append(n); }
  }
  const rotaDirty = () => !!document.querySelector('#p-personale [data-scope].dirty');
  const leaveRota = () => !rotaDirty() || confirm('Ci sono turni non salvati in questa settimana: se continui li perdi. Continuare?');
  $('rota-prev').onclick = () => { if (!leaveRota()) return; rotaMon.setDate(rotaMon.getDate() - 7); loadRota(); };
  $('rota-next').onclick = () => { if (!leaveRota()) return; rotaMon.setDate(rotaMon.getDate() + 7); loadRota(); };
  $('rota-copy').onclick = async () => { if (!leaveRota()) return; const prev = new Date(rotaMon); prev.setDate(prev.getDate() - 7); const { data, error } = await sb.rpc('copy_rota_week', { p_from: isoDay(prev), p_to: isoDay(rotaMon) }); if (error) return toast(error.message, 'err'); toast(`${data} turni copiati (le celle già compilate restano)`); loadRota(); };
  // ---------- Tier 2: send POs, wholesale confirmations ----------
  const copyText = async (t) => { try { await navigator.clipboard.writeText(t); toast('Copiato'); } catch { toast('Copia non riuscita', 'err'); } };
  document.addEventListener('click', e => { const a = e.target.closest && e.target.closest('[data-copy]'); if (a) { e.preventDefault(); copyText(a.dataset.copy); } });   // v0.64
  // v0.94: the office closes a farm load that will never arrive (registered twice, never left) — reason required, the farm page shows it
  document.addEventListener('click', async e => {
    const a = e.target.closest && e.target.closest('[data-cancel-ship]'); if (!a) return; e.preventDefault();
    const why = (prompt(`Annullare la spedizione ${a.dataset.lot}? Non comparirà più sul tablet e la Masseria la vedrà annullata.\nMotivo (obbligatorio):`) || '').trim();
    if (!why) return;
    const { error } = await sb.rpc('milk_shipment_cancel', { p_id: a.dataset.cancelShip, p_reason: why });
    if (error) return toast(error.message, 'err');
    toast(`Spedizione ${a.dataset.lot} annullata`); renderFarm();
  });
  const waLink = (phone, text) => 'https://wa.me/' + UI.waNumber(phone) + '?text=' + encodeURIComponent(text);   // v0.60: local numbers get 39 (they opened French numbers)
  async function renderPoSend() {
    const box = $('po-send');
    const { data, error } = await sb.from('v_pos_to_send').select('*');
    if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    renderPoSent();
    if (!data || !data.length) { box.innerHTML = '<div class="empty">Nessun ordine approvato in attesa di invio.</div>'; return; }
    const pks = await Promise.all(data.map(po => sb.rpc('po_send_package', { p_po_number: po.po_number }).then(r => r.data)));
    box.innerHTML = '';
    data.forEach((po, k) => { const pk = pks[k];
      const c = document.createElement('div'); c.className = 'eq';
      c.innerHTML = `<div class="h"><b>${esc(po.po_number)}</b><span class="status">${esc(pk?.supplier || po.supplier)} · ${eur(pk?.total_eur)} · consegna ${fmtD(pk?.expected_date)}</span></div>
        <pre style="white-space:pre-wrap;font:inherit;font-size:13px;background:var(--bg,#f6f3ee);padding:8px;border-radius:6px;margin:6px 0">${esc(pk?.body_it || '')}</pre>`;
      const row = document.createElement('div'); row.className = 'row';
      // v0.90: a supplier without email or phone can't receive the order from here: say so and point to the fix
      const email = pk?.email || po.email, phone = pk?.phone || po.phone;
      if (!email || !phone) c.insertAdjacentHTML('beforeend', `<div class="status ${!email && !phone ? 'ko' : ''}">${!email && !phone ? 'Questo fornitore non ha né email né telefono' : !email ? 'Manca l\'email del fornitore' : 'Manca il telefono del fornitore'}: <a href="#anag" class="lnk">aggiungili in Anagrafiche → Fornitori</a>${!email && !phone ? ', oppure stampa il PO o copia il testo.' : '.'}</div>`);
      const mail = document.createElement('a'); mail.className = 'btn sm sec'; mail.style.textDecoration = 'none'; mail.textContent = '✉️ Email';
      mail.href = 'mailto:' + encodeURIComponent(email || '') + '?subject=' + encodeURIComponent(pk?.subject || '') + '&body=' + encodeURIComponent(pk?.body_it || ''); mail.target = '_blank';
      const wa = document.createElement('a'); wa.className = 'btn sm sec'; wa.style.textDecoration = 'none'; wa.textContent = '💬 WhatsApp'; wa.href = waLink(phone, pk?.whatsapp_it || ''); wa.target = '_blank';
      if (!email) { mail.removeAttribute('href'); mail.setAttribute('aria-disabled', 'true'); mail.style.opacity = '.45'; mail.title = 'Manca l\'email del fornitore'; }
      if (!phone) { wa.removeAttribute('href'); wa.setAttribute('aria-disabled', 'true'); wa.style.opacity = '.45'; wa.title = 'Manca il telefono del fornitore'; }
      const cp = document.createElement('button'); cp.className = 'btn sm sec'; cp.textContent = 'Copia testo'; cp.onclick = () => copyText(pk?.body_it || '');
      const pr = document.createElement('a'); pr.className = 'btn sm sec'; pr.style.textDecoration = 'none'; pr.textContent = '🖨 Stampa PO'; pr.href = 'ordine.html?po=' + encodeURIComponent(po.po_number); pr.target = '_blank';
      const sent = document.createElement('button'); sent.className = 'btn sm'; sent.textContent = '✓ Segna inviato';
      sent.onclick = async () => { sent.disabled = true; const { error } = await sb.rpc('mark_po_sent', { p_po_number: po.po_number, p_via: 'console' }); if (error) { toast(error.message, 'err'); sent.disabled = false; return; } toast('Ordine segnato come inviato'); renderPoSend(); refreshBadges(); };
      // v0.90: after opening the e-mail / WhatsApp / print, the next step is "Segna inviato": make it obvious
      const nudge = () => { sent.textContent = '✓ Inviato? Segna inviato'; sent.classList.add('save'); sent.closest('.eq').classList.add('dirty'); };
      [mail, wa, pr].forEach(a => a.addEventListener('click', () => { if (a.hasAttribute('href')) nudge(); })); cp.addEventListener('click', nudge);
      const cx = document.createElement('button'); cx.className = 'btn sm warn'; cx.textContent = 'Annulla ordine'; cx.style.marginLeft = 'auto'; cx.onclick = () => cancelPo(po.po_number, cx);   // v0.99 (audit B-18)
      row.append(mail, wa, cp, pr, sent, cx); c.append(row); box.append(c);
    });
  }
  // v0.99 (audit B-18): a wrong order is cancelled with a reason, before or after sending, until goods arrive
  async function cancelPo(poNumber, btn) {
    const why = prompt(`Annullare l'ordine ${poNumber}?\nScrivi il motivo (es. quantità sbagliata, rifatto con un altro fornitore):`);
    if (why == null) return; if (why.trim().length < 3) return toast('Scrivi il motivo dell\'annullamento', 'err');
    btn.disabled = true;
    const { data, error } = await sb.rpc('cancel_po', { p_po_number: poNumber, p_reason: why.trim() });
    btn.disabled = false;
    if (error) return toast(error.message, 'err');
    if (data.was_sent) {          // the supplier already has it: the message to send, ready
      const t = data.message_it || '', box = $('po-sent');
      box.insertAdjacentHTML('afterbegin', `<div class="status ko" style="margin-bottom:8px">${esc(poNumber)} annullato. Era già stato inviato: avvisa ${esc(data.supplier || 'il fornitore')} · ${data.phone ? `<a class="lnk" target="_blank" href="${waLink(data.phone, t)}">💬 WhatsApp</a> · ` : ''}${data.email ? `<a class="lnk" target="_blank" href="mailto:${encodeURIComponent(data.email)}?subject=${encodeURIComponent('Annullamento ordine ' + poNumber)}&body=${encodeURIComponent(t)}">✉️ Email</a> · ` : ''}<a class="lnk" href="#" data-copy="${esc(t)}">copia il testo</a></div>`);
    }
    toast(`Ordine ${poNumber} annullato`); renderPoSend(); refreshBadges();
  }
  async function renderPoSent() {
    const box = $('po-sent'); if (!box) return;
    const { data, error } = await sb.from('purchase_orders').select('po_number, total_eur, expected_date, sent_at, supplier:parties(legal_name)').eq('status', 'sent').order('sent_at', { ascending: false }).limit(20);
    box.querySelectorAll('table').forEach(t => t.remove());
    if (error || !(data || []).length) return;
    const t = document.createElement('table'); t.className = 'nw2';
    t.innerHTML = '<tr><th colspan="5">Inviati, merce non ancora arrivata</th></tr>' + data.map(o => `<tr><td>${esc(o.po_number)}</td><td>${esc((o.supplier || {}).legal_name || '')}</td><td class="num">${eur(o.total_eur)}</td><td>attesa ${fmtD(o.expected_date)}</td><td><button class="btn sm sec" data-cxpo="${esc(o.po_number)}">Annulla ordine</button></td></tr>`).join('');
    t.querySelectorAll('[data-cxpo]').forEach(b => b.onclick = () => cancelPo(b.dataset.cxpo, b));
    box.append(t);
  }
  async function renderWholesale() {
    const box = $('wholesale');
    const { data, error } = await sb.from('v_wholesale_tomorrow').select('*').limit(12);
    if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    if (!data || !data.length) { box.innerHTML = '<div class="empty">Nessuna consegna ingrosso prenotata. Il bot "Ordini ingrosso" prenota ogni giorno alle 18:20 per il giorno dopo.</div>'; return; }
    box.innerHTML = '<table class="nw2"><tr><th>Giorno</th><th>Cliente</th><th>Cosa</th><th class="num">€</th><th></th></tr>' + data.map(o => `<tr><td>${dShort(o.order_date).replace(/^(\p{L}{3})\p{L}*/u, '$1').slice(0, -5)}</td><td>${esc(o.customer)}</td><td>${esc(o.lines_txt)}</td><td class="num">${eur(o.total_eur)}</td><td>${o.phone ? `<a class="btn sm sec" style="text-decoration:none" target="_blank" href="${waLink(o.phone, `Buongiorno, ${BRAND.name} conferma per ${fmtD(o.order_date)}: ${o.lines_txt}. Consegna in mattinata. Grazie!`)}">💬</a>` : ''}</td></tr>`).join('') + '</table>';
  }
    // ---------- parties: one compact editable table, sub-tabs Fornitori | Clienti ----------
  let partyType = 'supplier', PARTIES = [];
  $('party-tabs').onclick = e => { const b = e.target.closest('.sub'); if (!b) return; if (document.querySelector('#p-anag .dirty') && !confirm('Ci sono modifiche non salvate: se cambi scheda le perdi. Continuare?')) return; partyType = b.dataset.type; document.querySelectorAll('#party-tabs .sub').forEach(x => x.setAttribute('aria-selected', x === b)); document.querySelectorAll('#p-anag [data-show]').forEach(x => { x.hidden = x.dataset.show !== partyType; }); renderParties(); };
  async function loadParties() {
    const { data, error } = await sb.from('v_parties_editor').select('*');
    if (error) { $('set-parties').innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    PARTIES = data || [];
    badge('n-sup', PARTIES.filter(p => p.type === 'supplier' && p.is_placeholder).length); badge('n-cus', PARTIES.filter(p => p.type === 'customer' && p.is_placeholder).length);
    renderParties();
  }
  function renderParties() {
    const box = $('set-parties'); box.innerHTML = '';
    const last = PARTIES.filter(p => p.type === 'customer' && p.last_synced_at).map(p => p.last_synced_at).sort().pop();
    $('party-hint').innerHTML = partyType === 'customer'
      ? `I clienti si creano e si modificano su <b>Shopify → Clienti</b>; il bot "Clienti Shopify" li copia qui ogni mattina (ultima sincronizzazione: ${last ? new Date(last).toLocaleString('it-IT', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' , timeZone: 'Europe/Rome' }) : 'mai'}). Tag <b>ingrosso</b> su Shopify = cliente all'ingrosso qui. Un segnaposto con la stessa e-mail viene adottato automaticamente. Qui si modificano solo i giorni di pagamento.`
      : '"Fornitore 1" e simili sono segnaposto: scrivi il nome vero, email e telefono e i bot li usano subito. Modifica nella riga e premi Salva (o Invio).';
    const rows = PARTIES.filter(p => p.type === partyType);
    if (!rows.length) { box.innerHTML = `<div class="empty">Nessun ${partyType === 'supplier' ? 'fornitore' : 'cliente'}.</div>`; return; }
    const tbl = document.createElement('table'); tbl.className = 'par';
    const isCus = partyType === 'customer';
    tbl.innerHTML = isCus
      ? `<tr><th>Cliente</th><th>Email</th><th>Telefono</th><th>Tag</th><th class="num">Ordini</th><th class="num">Speso</th><th class="num">Pag. gg</th><th>Ingrosso</th><th></th></tr>`
      : `<tr><th>Nome / ragione sociale</th><th>Email</th><th>Telefono / WhatsApp</th><th class="num">Pag. gg</th><th>Articoli</th><th></th></tr>`;
    rows.forEach(p => {
      const tr = document.createElement('tr'); if (p.is_placeholder) tr.className = 'ph';
      const mk = (type, k, v, ph = '') => { const i = document.createElement(type === 'number' ? 'input' : 'input'); i.type = type; i.dataset.k = k; i.value = v ?? ''; i.placeholder = ph; return i; };
      const days = mk('number', 'payment_terms_days', p.payment_terms_days);
      if (isCus) {
        // Shopify is the source of truth: name, e-mail, phone, tags are read-only here
        const fromShopify = p.source === 'shopify';
        const t1 = document.createElement('td'); t1.innerHTML = `<b>${esc(p.legal_name)}</b>${p.city ? ` <small class="status">${esc(p.city)}</small>` : ''}<br><small class="${p.is_placeholder ? 'status ko' : 'status'}">${p.is_placeholder ? 'segnaposto · crealo su Shopify' : fromShopify ? 'Shopify' : 'locale (non su Shopify)'}</small>`;
        const t2 = document.createElement('td'); t2.textContent = p.email || '—'; const t3 = document.createElement('td'); t3.textContent = p.phone || '—';
        const t4 = document.createElement('td'); t4.innerHTML = (p.is_wholesale ? '<span class="kind" style="border-color:var(--accent);color:var(--accent);font-size:.75rem;padding:0 5px;border-radius:3px;border:1.5px solid">ingrosso</span> ' : '') + (p.tags || []).filter(t => !['ingrosso', 'b2b', 'wholesale', 'horeca'].includes(t)).map(t => `<small class="status">${esc(t)}</small>`).join(' ');
        const t5 = document.createElement('td'); t5.className = 'num'; t5.textContent = p.orders_count ?? '—'; const t6 = document.createElement('td'); t6.className = 'num'; t6.textContent = p.total_spent_eur != null ? eur(p.total_spent_eur) : '—';
        const t7 = document.createElement('td'); t7.className = 'num'; t7.append(days);
        const t8 = document.createElement('td'); t8.className = 'status'; t8.innerHTML = p.is_wholesale && PERM.page('ingrosso') ? '<a class="lnk" href="ingrosso.html#clienti">piano →</a>' : '—';   // v0.99 (audit B-19): plans live in Ingrosso
        const t9 = document.createElement('td'); t9.style.whiteSpace = 'nowrap';
        t9.append(saveBtn(async () => { await upd('parties', { id: p.id }, { payment_terms_days: nOrNull(days.value) }); UI.after(loadParties); }));
        if (fromShopify && p.shopify_customer_id) { const a = document.createElement('a'); a.className = 'btn sm sec'; a.style.cssText = 'text-decoration:none;margin-left:6px'; a.target = '_blank'; a.textContent = 'Shopify ↗'; a.href = 'https://admin.shopify.com/store/pxssjd-cq/customers/' + p.shopify_customer_id.split('/').pop(); t9.append(a); }
        tr.append(t1, t2, t3, t4, t5, t6, t7, t8, t9); tbl.append(tr); return;
      }
      const name = mk('text', 'legal_name', p.legal_name), email = mk('email', 'email', p.email, '—'), phone = mk('tel', 'phone', p.phone, '+39 …');
      const t1 = document.createElement('td'); t1.append(name); if (p.is_placeholder) { const s = document.createElement('small'); s.className = 'status ko'; s.textContent = 'segnaposto'; t1.append(document.createElement('br'), s); }
      const t2 = document.createElement('td'); t2.append(email); const t3 = document.createElement('td'); t3.append(phone); const t4 = document.createElement('td'); t4.className = 'num'; t4.append(days);
      const t5 = document.createElement('td'); t5.className = 'status';
      if (p.products_supplied) { const a = document.createElement('button'); a.type = 'button'; a.className = 'btn sm sec'; a.textContent = p.products_supplied + (p.products_supplied === 1 ? ' articolo' : ' articoli'); a.title = 'Mostra gli articoli di questo fornitore'; a.onclick = () => window.SUPPLIES.showSupplier(p.id); t5.append(a); }   // v0.89
      if (PERM.can('acquisti', 3)) { const g = document.createElement('button'); g.type = 'button'; g.className = 'btn sm sec'; g.textContent = p.products_supplied ? 'Assegna' : 'Assegna articoli'; g.title = 'Spunta gli articoli che compri da questo fornitore e scrivi i prezzi, tutto insieme'; if (p.products_supplied) g.style.marginLeft = '6px'; g.onclick = () => window.SUPPLIES.assign(p.id); t5.append(g); }   // v0.90
      else if (!p.products_supplied) t5.textContent = '—';
      if (!p.is_placeholder && !p.email && !p.phone) { const w = document.createElement('small'); w.className = 'status ko'; w.textContent = 'senza email né telefono: servono per inviare gli ordini'; t1.append(document.createElement('br'), w); }   // v0.90
      const t6 = document.createElement('td'); t6.style.whiteSpace = 'nowrap';
      t6.append(saveBtn(async () => {
        const v = {}; tr.querySelectorAll('input[data-k]').forEach(i => { v[i.dataset.k] = i.type === 'number' ? nOrNull(i.value) : (i.value.trim() || null); });
        if (!v.legal_name) throw new Error('Il nome è obbligatorio');
        if (p.is_placeholder && !/^(Fornitore|Cliente) \d/.test(v.legal_name)) { v.notes = null; v.source = 'manual'; }   // renamed → no longer a placeholder
        await upd('parties', { id: p.id }, v); UI.after(loadParties); refreshBadges();
      }));
      tr.append(t1, t2, t3, t4, t5, t6); tbl.append(tr);
    });
    if (isCus) { box.append(tbl); return; }
    // new supplier row
    const add = document.createElement('tr'); add.className = 'nodirty'; add.style.background = 'var(--tile)';
    const nn = document.createElement('input'); nn.type = 'text'; nn.placeholder = 'Nuovo fornitore…';
    const ne = document.createElement('input'); ne.type = 'email'; ne.placeholder = 'email'; const np = document.createElement('input'); np.type = 'tel'; np.placeholder = '+39 …'; const nd = document.createElement('input'); nd.type = 'number'; nd.value = 30;
    const nb = document.createElement('button'); nb.className = 'btn sm'; nb.textContent = 'Aggiungi';
    nb.onclick = async () => { if (!nn.value.trim()) return toast('Scrivi il nome', 'err'); nb.disabled = true; const { error } = await sb.from('parties').insert({ type: partyType, legal_name: nn.value.trim(), email: ne.value.trim() || null, phone: np.value.trim() || null, payment_terms_days: nOrNull(nd.value) }); nb.disabled = false; if (error) return toast(error.message, 'err'); toast('Aggiunto'); loadParties(); };
    [nn, ne, np, nd].forEach((el, k) => { const td = document.createElement('td'); if (k === 3) td.className = 'num'; td.append(el); add.append(td); });
    const e5 = document.createElement('td'); const e6 = document.createElement('td'); e6.append(nb); add.append(e5, e6); tbl.append(add);
    box.append(tbl);
  }
  // v0.99 (audit B-19): the old «Ordini fissi» grid is gone — it booked nothing; the plans are in Ingrosso → Clienti e piani
  const EFFL_KIND = { scotta: 'Scotta', siero: 'Siero', acque_lavaggio: 'Acque di lavaggio', fanghi: 'Fanghi', altro: 'Altro' };
  const EFFL_DEST = { ricotta: 'ricotta', allevamento: 'allevamento', fognatura: 'fognatura', trasportatore: 'trasportatore', depuratore_interno: 'depuratore interno', altro: 'altro' };
  async function loadEffluent() {
    const box = $('effluent');
    const [{ data: rows, error }, { data: bal }] = await Promise.all([sb.from('v_effluent_recent').select('*').limit(30), sb.from('v_effluent_balance').select('*').limit(7)]);
    if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    const missing = (bal || []).filter(b => Number(b.whey_logged_m3) === 0 && Number(b.wash_logged_m3) === 0).length;
    const tot = (rows || []).reduce((a, r) => { a[r.kind] = (a[r.kind] || 0) + Number(r.m3); return a; }, {});
    let html = Object.keys(tot).length ? `<div class="status" style="margin-bottom:6px">${Object.entries(tot).map(([k, v]) => `${EFFL_KIND[k] || k} <b>${num(v, 1)} m³</b>`).join(' · ')}</div>` : '';
    if (missing) html += `<div class="status ko" style="margin-bottom:6px">${missing} giorni di produzione (ultimi 7) senza registrazione reflui.</div>`;
    html += (rows && rows.length) ? '<table class="nw2"><tr><th>Giorno</th><th>Cosa</th><th class="num">m³</th><th>Destinazione</th><th>Doc.</th></tr>' + rows.map(r => `<tr><td>${fmtD(r.log_date).slice(0, 5)}</td><td>${EFFL_KIND[r.kind] || esc(r.kind)}</td><td class="num">${num(r.m3, 2)}</td><td>${EFFL_DEST[r.destination] || esc(r.destination)}${r.recipient ? ' · ' + esc(r.recipient) : ''}</td><td class="${r.document_ref ? '' : 'status'}">${esc(r.document_ref || (r.destination === 'trasportatore' || r.destination === 'allevamento' ? 'manca' : '—'))}</td></tr>`).join('') + '</table>'
      : '<div class="empty">Nessun refluo registrato negli ultimi 14 giorni.</div>';
    box.innerHTML = html;
  }
  // ---------- recipes: dose per kg, versioned by date ----------
  const BASIS = (fin) => ({ per_kg_milk: fin === 'RIC-BUF-KG' ? 'per kg siero' : 'per kg latte', per_kg_output: 'per kg prodotto', per_batch: 'per lotto' });
  const PHASE = { start: 'Avvio', close: 'Chiusura' };
  // ---------- process presets (machine settings per step) ----------
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
      // v0.99 (audit B-16): text fields read the Italian way (94,5), so a comma never empties a target silently
      const num = (v, step = 'any', ph = '') => { const i = document.createElement('input'); i.type = 'text'; i.inputMode = 'decimal'; i.className = 'n'; i.value = v == null ? '' : String(v).replace('.', ','); i.placeholder = ph; i.dataset.was = v ?? ''; return i; };
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
        const LBL = new Map([[t1, '°C obiettivo'], [t2, '°C minimo'], [t3, '°C massimo'], [d1, 'minuti'], [d2, 'minuti minimo'], [d3, 'minuti massimo'], [sp, 'velocità'], [p1, 'pH obiettivo'], [p2, 'pH minimo'], [p3, 'pH massimo']]);
        const nv = i => { const t = i.value.trim(); if (t === '') return null; const n = UI.parseIt(t);
          if (!Number.isFinite(n)) throw new Error(`${LBL.get(i) || 'Valore'}: «${t}» non è un numero (scrivi 94,5 o 94.5)`); return n; };
        const payload = () => ({ preset_id: P.preset_id, phase: ph.value, step_order: Number(ord.value) || 10, name_it: name.value.trim(), equipment_id: eqs.value || null,
          target_temp_c: nv(t1), temp_min_c: nv(t2), temp_max_c: nv(t3), duration_min: nv(d1), duration_min_min: nv(d2), duration_max_min: nv(d3),
          speed: nv(sp), speed_unit: su.value.trim() || null, target_ph: nv(p1), ph_min: nv(p2), ph_max: nv(p3),
          extra: parseExtra(ex.value), instruction_it: ins.value.trim() || null, record_metric: met.value, updated_at: new Date().toISOString() });
        // a target that was there and is now empty is asked, never cleared silently; a preset already used by lots asks once
        const checkSave = () => { const gone = [...LBL.keys()].filter(i => i.dataset.was !== '' && i.value.trim() === '');
          if (gone.length && !confirm(`Passo «${name.value.trim()}»: togli ${gone.map(i => `${LBL.get(i)} (era ${String(i.dataset.was).replace('.', ',')})`).join(', ')}?\nIl tablet non mostrerà più quel valore al casaro.`)) throw silent();
          if (P.n_batches && !confirm(`Il preset «${P.name}» ha già ${P.n_batches} lotti: cambiando i valori cambiano anche i confronti con quei lotti (scostamento medio).\nSalvare comunque? Per provare una variante usa «Copia come nuovo preset».`)) throw silent(); };
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
          tdB.append(saveBtn(async () => { const p = payload(); if (!p.name_it) throw new Error('Dai un nome al passo'); checkSave(); await upd('process_steps', { id: st.step_id }, p); UI.after(loadPresets); }));
          const rm = document.createElement('button'); rm.className = 'btn sm sec'; rm.textContent = 'Togli'; rm.style.marginLeft = '6px'; rm.title = 'Il passo non compare più sul tablet';
          rm.onclick = async () => { if (!confirm(`Togliere il passo «${st.name_it}» dal preset «${P.name}»?\nIl tablet non lo mostrerà più dai prossimi lotti.`)) return;   // v0.99 (audit B-16)
            rm.disabled = true; try { await upd('process_steps', { id: st.step_id }, { active: false, updated_at: new Date().toISOString() }); toast('Passo tolto'); loadPresets(); } catch (e) { toast(e.message, 'err'); rm.disabled = false; } };
          tdB.append(rm);
        } else {
          const add = document.createElement('button'); add.className = 'btn sm'; add.textContent = 'Aggiungi';
          add.onclick = async () => { let p; try { p = payload(); } catch (er) { return toast(er.message, 'err'); } if (!p.name_it) return toast('Dai un nome al passo', 'err'); add.disabled = true; const { error } = await sb.from('process_steps').insert(p); add.disabled = false; if (error) return toast(error.message, 'err'); toast('Passo aggiunto'); loadPresets(); };
          tdB.append(add);
        }
        const grp = document.createElement('tbody'); grp.dataset.scope = 'step'; grp.append(tr, sub); return grp;   // v0.60: both lines of a step are one unsaved-change scope (Salva sits in the second)
      };
      mine.forEach(st => tbl.append(row(st))); tbl.append(row(null));
      const wrap = document.createElement('div'); wrap.style.overflowX = 'auto'; wrap.append(tbl); card.append(wrap); box.append(card);
    });
    if (!Object.keys(byProd).length) box.innerHTML = '<div class="empty">Nessun preset: vengono creati con la migrazione v0.26.</div>';
  }

  // v0.98 (audit B-14/D-27): a dose is shown in what it means for one vat («= 0,08 l per una caldaia da 310 kg»), live while typing;
  // a change of more than 25 % asks with old → new per vat, more than 2 times also asks the reason (the database refuses it without).
  // Doses are written with the comma (0,00025) and never saved by Enter.
  let VAT = 310;
  const fq = (v, d) => Number(v).toLocaleString('it-IT', { maximumFractionDigits: d });
  const qtyHuman = (v, unit) => { const u = String(unit || '');
    if (u === 'l' && v < 1) return fq(v * 1000, v * 1000 < 10 ? 1 : 0) + ' ml'; if (u === 'kg' && v < 1) return fq(v * 1000, v * 1000 < 10 ? 1 : 0) + ' g';
    return fq(v, v < 10 ? 2 : 1) + ' ' + u; };
  const perVat = (basis, v, unit, sku) => !Number.isFinite(v) ? 'numero non valido: usa la virgola per i decimali (0,00025)'
    : basis === 'per_kg_milk' ? (sku === 'RIC-BUF-KG' ? `= ${qtyHuman(v * 100, unit)} ogni 100 kg di siero` : `= ${qtyHuman(v * VAT, unit)} per una caldaia da ${UI.num(VAT, 0)} kg di latte`)
    : basis === 'per_kg_output' ? `= ${qtyHuman(v * 100, unit)} ogni 100 kg di prodotto` : `= ${qtyHuman(v, unit)} a lotto`;
  const doseTxt = v => Number(v).toLocaleString('it-IT', { maximumFractionDigits: 10, useGrouping: false });   // never «5e-7»
  async function saveDose(r, f, v, extra) {
    const go = (more = {}) => sb.rpc('update_recipe_dose', { p_recipe_id: r.recipe_id, p_qty: v, ...extra, ...more });
    const old = Number(r.qty_per_unit), ratio = old > 0 ? v / old : 1;
    let more = {};
    const askReason = () => { const why = prompt('Perché cambia così tanto? (es. caglio nuovo, più debole) — resta nella ricetta:'); if (why == null) { const e = new Error('annullato'); e.silent = true; throw e; }
      if (why.trim().length < 3) throw new Error('Scrivi il motivo del cambio della dose'); return why.trim(); };
    if (old > 0 && v !== old && (ratio > 1.25 || ratio < 0.8)) {
      const times = ratio >= 1 ? ratio : 1 / ratio;
      if (!confirm(`${r.component_name}: la dose cambia da ${doseTxt(old)} a ${doseTxt(v)} ${r.unit} (${UI.num(times, times < 10 ? 1 : 0)} volte ${ratio >= 1 ? 'di più' : 'di meno'}).\n\n` +
          `Prima: ${perVat(r.basis, old, r.unit, f.sku).replace(/^= /, '')}\nDopo: ${perVat(r.basis, v, r.unit, f.sku).replace(/^= /, '')}\n\nVale da oggi per ogni lotto. Controlla la virgola: confermi?`)) { const e = new Error('annullato'); e.silent = true; throw e; }
      if (ratio > 2 || ratio < 0.5) more = { p_confirm: true, p_notes: askReason() };
    }
    let { error } = await go(more);
    if (error && error.hint === 'confirm') {                   // the database thinks it is a big change (another tab, older numbers)
      if (!confirm(error.message + '\n\nConfermi?')) { const e = new Error('annullato'); e.silent = true; throw e; }
      ({ error } = await go({ p_confirm: true, p_notes: askReason() }));
    }
    if (error) throw error;
  }
  async function loadRecipes() {
    const box = $('recipes'); box.innerHTML = '';
    const [{ data: rows, error }, { data: fins }, { data: comps }, { data: vs }] = await Promise.all([
      sb.from('v_recipe_editor').select('*'),
      sb.from('products').select('sku, name').eq('kind', 'finished_good').eq('active', true).order('sku'),
      sb.from('products').select('sku, name, unit').in('kind', ['consumable', 'packaging']).eq('active', true).order('name'),
      sb.from('settings').select('value').eq('key', 'prod.vat_kg').maybeSingle()]);
    if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    if (vs && Number(vs.value) > 0) VAT = Number(vs.value);
    (fins || []).forEach(f => {
      const mine = (rows || []).filter(r => r.finished_sku === f.sku);
      const card = document.createElement('div'); card.className = 'card'; card.style.marginBottom = '16px';
      card.innerHTML = `<h3>${esc(f.name)} <small class="status">${esc(f.sku)}</small></h3>`;
      const tbl = document.createElement('table'); tbl.className = 'rec';
      tbl.innerHTML = '<tr><th>Fase</th><th>Componente</th><th>Base</th><th class="num">Dose</th><th>↑</th><th>Istruzione sul tablet</th><th></th></tr>';
      if (!mine.length) tbl.innerHTML += '<tr><td colspan="7" class="empty">Nessun componente: aggiungine uno qui sotto.</td></tr>';
      mine.forEach(r => {
        const tr = document.createElement('tr');
        tr.innerHTML = `<td><span class="ph">${PHASE[r.phase] || esc(r.phase)} · ${r.step_order}</span></td><td><b>${esc(r.component_name)}</b><br><small class="status">${esc(r.component_sku)}</small></td><td class="status">${BASIS(f.sku)[r.basis] || esc(r.basis)}</td>`;
        const tdQ = document.createElement('td'); tdQ.className = 'num'; const q = document.createElement('input'); q.type = 'text'; q.inputMode = 'decimal'; q.dataset.noenter = '1'; q.style.width = '110px'; q.value = doseTxt(Number(r.qty_per_unit));
        const pv = document.createElement('div'); pv.className = 'small'; pv.style.whiteSpace = 'normal';
        const prev = () => { pv.textContent = perVat(r.basis, UI.parseIt(q.value), r.unit, f.sku); }; q.addEventListener('input', prev); prev();
        tdQ.append(q, document.createTextNode(' ' + r.unit), pv);
        const tdR = document.createElement('td'); const ru = document.createElement('input'); ru.type = 'checkbox'; ru.checked = !!r.round_up; ru.title = 'Arrotonda per eccesso (pezzi)'; tdR.append(ru);
        const tdI = document.createElement('td'); const ins = document.createElement('input'); ins.type = 'text'; ins.value = r.instruction_it || ''; ins.placeholder = 'es. Pesa il caglio e aggiungilo al latte'; tdI.append(ins);
        const tdB = document.createElement('td'); tdB.style.whiteSpace = 'nowrap';
        // v0.99 (audit B-15): «Togli» asks and ends the component from tomorrow (today's lots still dose it); the same day «Rimetti» undoes it.
        // A removed row has no «Salva» (saving a dose there would put the component back without saying so)
        if (r.valid_to) {
          tr.style.opacity = '.6'; tdQ.innerHTML = `${esc(doseTxt(Number(r.qty_per_unit)))} ${esc(r.unit)}<div class="small ko">tolto: da domani non si dosa più</div>`;
          ru.disabled = true; ins.disabled = true;
          const back = document.createElement('button'); back.className = 'btn sm'; back.textContent = 'Rimetti';
          back.onclick = () => act(back, async () => { const { error } = await sb.rpc('restore_recipe_component', { p_recipe_id: r.recipe_id }); if (error) throw error; loadRecipes(); }, `${r.component_name} rimesso nella ricetta`);
          tdB.append(back); tr.append(tdQ, tdR, tdI, tdB); tbl.append(tr); return;
        }
        tdB.append(saveBtn(async () => { const v = UI.parseIt(q.value);
          if (!Number.isFinite(v) || v <= 0) throw new Error(`${r.component_name}: scrivi la dose, un numero maggiore di zero con la virgola per i decimali`);
          await saveDose(r, f, v, { p_round_up: ru.checked, p_instruction: ins.value.trim() }); UI.after(loadRecipes); }));
        const today = r.valid_from >= UI.romeISO();      // put in (or changed) today: it stops at once
        const end = document.createElement('button'); end.className = 'btn sm sec'; end.textContent = 'Togli'; end.style.marginLeft = '6px';
        end.title = today ? 'Inserito oggi: smette subito di essere dosato' : 'Il componente non viene più dosato da domani';
        end.onclick = () => act(end, async () => {
          if (!confirm(today ? `Togliere ${r.component_name} dalla ricetta di ${f.name}?\nÈ stato inserito o cambiato oggi: smette subito, anche per i lotti di oggi non ancora dosati. Per rimetterlo aggiungilo di nuovo dalla riga in fondo.`
                             : `Togliere ${r.component_name} dalla ricetta di ${f.name}?\nDa domani non si dosa più; i lotti di oggi lo dosano ancora. Oggi puoi ancora rimetterlo.`)) return false;
          const { error } = await sb.rpc('end_recipe_component', { p_recipe_id: r.recipe_id }); if (error) throw error; loadRecipes(); },
          today ? `${r.component_name} tolto da subito` : `${r.component_name} tolto da domani · «Rimetti» per annullare`);
        tdB.append(end); tr.append(tdQ, tdR, tdI, tdB); tbl.append(tr);
      });
      // add row
      const add = document.createElement('tr'); add.className = 'nodirty'; add.style.background = 'var(--tile)';
      const used = new Set(mine.map(r => r.component_sku));
      const selC = document.createElement('select'); selC.innerHTML = '<option value="">+ componente…</option>' + (comps || []).filter(c => !used.has(c.sku)).map(c => `<option value="${esc(c.sku)}">${esc(c.name)} (${esc(c.unit)})</option>`).join('');
      const selB = document.createElement('select'); selB.innerHTML = Object.entries(BASIS(f.sku)).map(([k, v]) => `<option value="${k}">${v}</option>`).join('');
      const selP = document.createElement('select'); selP.innerHTML = '<option value="start">Avvio</option><option value="close">Chiusura</option>';
      const ord = document.createElement('input'); ord.type = 'number'; ord.value = 10 * (mine.length + 1); ord.style.width = '64px'; ord.title = 'ordine del passo';
      const q2 = document.createElement('input'); q2.type = 'text'; q2.inputMode = 'decimal'; q2.placeholder = 'dose'; q2.style.width = '110px';
      const pv2 = document.createElement('div'); pv2.className = 'small'; pv2.style.whiteSpace = 'normal';
      q2.addEventListener('input', () => { pv2.textContent = q2.value.trim() ? perVat(selB.value, UI.parseIt(q2.value), (comps || []).find(c => c.sku === selC.value)?.unit || '', f.sku) : ''; });
      const ru2 = document.createElement('input'); ru2.type = 'checkbox';
      const ins2 = document.createElement('input'); ins2.type = 'text'; ins2.placeholder = 'istruzione (facoltativa)';
      const btn = document.createElement('button'); btn.className = 'btn sm'; btn.textContent = 'Aggiungi';
      btn.onclick = async () => {
        const d2 = UI.parseIt(q2.value);
        if (!selC.value) return toast('Scegli il componente', 'err'); if (!(d2 > 0)) return toast('Inserisci la dose: un numero maggiore di zero, con la virgola per i decimali', 'err');
        if (!confirm(`Aggiungere ${selC.selectedOptions[0].textContent} alla ricetta di ${f.name}: ${doseTxt(d2)} ${BASIS(f.sku)[selB.value]} (${perVat(selB.value, d2, (comps || []).find(c => c.sku === selC.value)?.unit || '', f.sku).replace(/^= /, '')})?\nVale da oggi per ogni lotto.`)) return;
        btn.disabled = true; const { error } = await sb.rpc('add_recipe_component', { p_finished_sku: f.sku, p_component_sku: selC.value, p_basis: selB.value, p_qty: d2, p_round_up: ru2.checked, p_phase: selP.value, p_step_order: Number(ord.value) || 10, p_instruction: ins2.value.trim() || null });
        btn.disabled = false; if (error) return toast(error.message, 'err'); toast('Componente aggiunto'); loadRecipes();
      };
      const c1 = document.createElement('td'); c1.append(selP, document.createTextNode(' '), ord); const c2 = document.createElement('td'); c2.append(selC); const c3 = document.createElement('td'); c3.append(selB);
      const c4 = document.createElement('td'); c4.className = 'num'; c4.append(q2, pv2); const c5 = document.createElement('td'); c5.append(ru2); const c6 = document.createElement('td'); c6.append(ins2); const c7 = document.createElement('td'); c7.append(btn);
      add.append(c1, c2, c3, c4, c5, c6, c7); tbl.append(add);
      const wrap = document.createElement('div'); wrap.style.overflowX = 'auto'; wrap.append(tbl); card.append(wrap); box.append(card);
    });
    const note = document.createElement('div'); note.className = 'hint'; note.textContent = 'Le dosi attuali sono segnaposto finché i partner non confermano caglio, sale, acido citrico e imballi reali. La revisione mensile propone correzioni quando i casari dosano sistematicamente in modo diverso.'; box.append(note);
  }

  const OSTATUS = { draft: ['non pagato', 'status'], confirmed: ['pagato · da spedire', 'ko'], fulfilled: ['spedito', 'ok'], cancelled: ['annullato', 'status'], refunded: ['rimborsato', 'status'] };
  async function loadShopifyOrders() {
    const box = $('shopify-orders');
    const { data, error } = await sb.from('v_shopify_orders_recent').select('*').limit(25);
    if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    if (!data || !data.length) { box.innerHTML = '<div class="empty">Nessun ordine online negli ultimi 14 giorni.</div>'; return; }
    const toShip = data.filter(o => o.status === 'confirmed').length, unm = data.reduce((a, o) => a + Number(o.unmapped || 0), 0);
    let html = `<div class="status" style="margin-bottom:6px">${data.length} ordini · <b class="${toShip ? 'ko' : ''}">${toShip} da spedire</b> · ${eur(data.reduce((a, o) => a + Number(o.total_eur || 0), 0))}${unm ? ` · <span class="ko">${unm} righe da collegare al magazzino</span>` : ''}</div>`;
    html += '<table class="nw2"><tr><th>Ordine</th><th>Giorno</th><th>Cliente</th><th>Cosa</th><th class="num">€</th><th>Stato</th></tr>' + data.map(o => { const [lbl, cls] = OSTATUS[o.status] || [o.status, '']; return `<tr><td>${esc(o.order_number)}</td><td>${fmtD(o.order_date).slice(0, 5)}</td><td>${esc(o.customer || '—')}${o.ship_city ? ` <small class="status">${esc(o.ship_city)}</small>` : ''}</td><td>${esc(o.lines_txt || '')}${o.unmapped ? ` <small class="ko">+${o.unmapped} non collegate</small>` : ''}</td><td class="num">${eur(o.total_eur)}</td><td class="${cls}">${lbl}${o.stock_booked ? ' ✓' : ''}</td></tr>`; }).join('') + '</table>';
    box.innerHTML = html;
  }

  // ---------- charts (inline SVG, single scale, hover layer) ----------
  const tip = $('tip');
  const showTip = (e, html) => { tip.innerHTML = html; tip.style.display = 'block'; tip.style.left = (e.clientX + 12) + 'px'; tip.style.top = (e.clientY - 28) + 'px'; };
  const hideTip = () => tip.style.display = 'none';
  const W = 520, H = 200, P = { l: 36, r: 10, t: 10, b: 24 };
  const sx = (i, n) => P.l + (n <= 1 ? 0 : i * (W - P.l - P.r) / (n - 1));
  const ticks = (lo, hi, k = 4) => Array.from({ length: k + 1 }, (_, i) => lo + (hi - lo) * i / k);
  const shortDate = s => s.slice(8, 10) + '/' + s.slice(5, 7);

  function yieldChart(rows, y) {
    rows = rows.filter(r => r.yield_pct != null);   // v0.60: open batches have no yield yet (they pulled the line to 0 %)
    const box = $('chart-yield'); if (!rows.length) { box.innerHTML = '<div class="empty">Nessuna produzione negli ultimi 30 giorni.</div>'; return; }
    const vals = rows.map(r => Number(r.yield_pct)); const lo = Math.floor(Math.min(...vals, y.avg_30d || 99) - 1), hi = Math.ceil(Math.max(...vals, y.avg_30d || 0) + 1);
    const sy = v => P.t + (H - P.t - P.b) * (1 - (v - lo) / (hi - lo));
    const n = rows.length, pts = rows.map((r, i) => [sx(i, n), sy(Number(r.yield_pct))]);
    const path = pts.map((p, i) => (i ? 'L' : 'M') + p[0].toFixed(1) + ' ' + p[1].toFixed(1)).join(' ');
    const area = path + ` L${pts[n - 1][0].toFixed(1)} ${sy(lo)} L${pts[0][0].toFixed(1)} ${sy(lo)} Z`;
    const avg = y.avg_30d != null ? `<line x1="${P.l}" x2="${W - P.r}" y1="${sy(y.avg_30d)}" y2="${sy(y.avg_30d)}" stroke="var(--muted)" stroke-dasharray="4 4"/><text x="${W - P.r}" y="${sy(y.avg_30d) - 4}" text-anchor="end">media ${num(y.avg_30d)} %</text>` : '';
    box.innerHTML = `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="Resa mozzarella ultimi 30 giorni">
      <g class="grid">${ticks(lo, hi).map(t => `<line x1="${P.l}" x2="${W - P.r}" y1="${sy(t)}" y2="${sy(t)}"/><text x="${P.l - 6}" y="${sy(t) + 4}" text-anchor="end">${t.toFixed(0)}</text>`).join('')}</g>
      <path d="${area}" fill="var(--series-1)" opacity=".12"/><path d="${path}" fill="none" stroke="var(--series-1)" stroke-width="2" stroke-linejoin="round"/>${avg}
      <circle cx="${pts[n - 1][0]}" cy="${pts[n - 1][1]}" r="4" fill="var(--series-1)" stroke="var(--paper)" stroke-width="2"/>
      ${rows.map((r, i) => i % Math.ceil(n / 6) === 0 ? `<text x="${pts[i][0]}" y="${H - 6}" text-anchor="middle">${shortDate(r.batch_date)}</text>` : '').join('')}
      ${rows.map((r, i) => `<rect x="${pts[i][0] - (W - P.l - P.r) / n / 2}" y="${P.t}" width="${(W - P.l - P.r) / n}" height="${H - P.t - P.b}" fill="transparent" data-i="${i}"/>`).join('')}
    </svg>`;
    box.querySelectorAll('rect[data-i]').forEach(r => { r.onmousemove = e => { const d = rows[r.dataset.i]; showTip(e, `${dateIt(d.batch_date)}<br>resa <b>${num(d.yield_pct)} %</b> · ${num(d.output_kg, 0)} kg`); }; r.onmouseleave = hideTip; });
  }

  function salesChart(rows) {
    const box = $('chart-sales'); if (!rows.length) { box.innerHTML = '<div class="empty">Nessuna vendita negli ultimi 30 giorni.</div>'; return; }
    const days = [...new Set(rows.map(r => r.order_date))].sort();
    const by = {}; rows.forEach(r => { by[r.order_date] = by[r.order_date] || { store: 0, whole: 0 }; by[r.order_date][r.channel === 'wholesale' ? 'whole' : 'store'] += Number(r.revenue_eur); });
    const hi = Math.max(...days.map(d => by[d].store + by[d].whole)) * 1.05, n = days.length;
    const bw = (W - P.l - P.r) / n, sy = v => P.t + (H - P.t - P.b) * (1 - v / hi);
    box.innerHTML = `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="Vendite per canale ultimi 30 giorni">
      <g class="grid">${ticks(0, hi).map(t => `<line x1="${P.l}" x2="${W - P.r}" y1="${sy(t)}" y2="${sy(t)}"/><text x="${P.l - 6}" y="${sy(t) + 4}" text-anchor="end">${(t / 1000).toFixed(1)}k</text>`).join('')}</g>
      ${days.map((d, i) => { const s = by[d].store, w = by[d].whole, x = P.l + i * bw + 1.5, wd = Math.max(1, bw - 3);
        return `<g data-i="${i}"><rect x="${x}" y="${sy(s)}" width="${wd}" height="${Math.max(0, sy(0) - sy(s))}" fill="var(--series-1)" rx="2"/>` +
               (w ? `<rect x="${x}" y="${sy(s + w)}" width="${wd}" height="${Math.max(0, sy(s) - sy(s + w) - 2)}" fill="var(--series-2)" rx="2"/>` : '') +
               `<rect x="${P.l + i * bw}" y="${P.t}" width="${bw}" height="${H - P.t - P.b}" fill="transparent"/></g>`; }).join('')}
      <line class="axis" x1="${P.l}" x2="${W - P.r}" y1="${sy(0)}" y2="${sy(0)}"/>
      ${days.map((d, i) => i % Math.ceil(n / 6) === 0 ? `<text x="${P.l + i * bw + bw / 2}" y="${H - 6}" text-anchor="middle">${shortDate(d)}</text>` : '').join('')}
    </svg>`;
    box.querySelectorAll('g[data-i]').forEach(g => { g.onmousemove = e => { const d = days[g.dataset.i]; showTip(e, `${dateIt(d)}<br>banco <b>${eur(by[d].store)}</b> · ingrosso <b>${eur(by[d].whole)}</b>`); }; g.onmouseleave = hideTip; });
  }

  // ---------- start ----------
  UI.boot({
    page: 'console', onRefresh: refresh,
    onReady: async s => {
      staff = s;
      const TAB_AREAS = { ops: ['produzione', 'acquisti', 'vendite'], trend: ['produzione', 'vendite'], anag: ['vendite', 'acquisti'], ricette: ['produzione'], personale: ['personale'], incassi: ['finanza'] };
      document.querySelectorAll('.tab').forEach(t => { const a = TAB_AREAS[t.dataset.tab]; if (a) t.hidden = !a.some(x => PERM.can(x)); });
      $('c-pkg').hidden = !PERM.page('pacchetto'); PERM.navLinks();
      T.start(); refreshBadges();
    }
  });
})();
