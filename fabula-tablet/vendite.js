/* La Perla · Vendite (v0.44): obiettivi per canale (banco, online, delivery, ristoranti, hotel), pipeline locali (ristoranti, pizzerie, hotel, B&B, lidi),
   messaggi pronti da copiare, registro contatti, piano 24 mesi. Legge fabula.sales_status() — la stessa funzione del bot Vendite. */
(() => {
  const CFG = window.FABULA_CONFIG;
  const sb = supabase.createClient(CFG.supabaseUrl, CFG.supabaseKey, { db: { schema: 'fabula' } });
  const $ = id => document.getElementById(id);
  document.addEventListener('wheel', e => { const a = document.activeElement; if (a && a.tagName === 'INPUT' && a.type === 'number' && e.target === a) e.preventDefault(); }, { passive: false });
  const show = v => document.querySelectorAll('.view').forEach(e => e.classList.toggle('active', e.id === 'v-' + v));
  const toast = (m, cls = '') => { const t = $('toast'); t.textContent = m; t.className = 'toast ' + cls; t.style.display = 'block'; setTimeout(() => t.style.display = 'none', 3200); };
  const eur = (n, d = 0) => n == null ? '–' : new Intl.NumberFormat('it-IT', { style: 'currency', currency: 'EUR', maximumFractionDigits: d, minimumFractionDigits: d }).format(n);
  const num = (n, d = 0) => n == null ? '–' : Number(n).toLocaleString('it-IT', { maximumFractionDigits: d });
  const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const today = () => new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Rome' });
  const dShort = s => s ? new Date(s + 'T12:00:00').toLocaleDateString('it-IT', { weekday: 'short', day: 'numeric', month: 'short' }) : '';
  const must = ({ data, error }) => { if (error) throw error; return data; };
  const run = async (fn, ok) => { try { const r = await fn(); if (ok) toast(ok); return r; } catch (e) { toast(e.message || String(e), 'err'); throw e; } };
  const STAGES = [['nuovo', 'Nuovi'], ['contattato', 'Contattati'], ['degustazione', 'Degustazione'], ['offerta', 'Offerta'], ['cliente', 'Clienti']];
  const SEG_CH = s => ['hotel', 'bnb', 'agriturismo', 'lido'].includes(s) ? 'hotel' : 'ristoranti';
  let S = null, leads = [], cur = null, canWrite = false, canManage = false;

  async function init() {
    const { data: { session } } = await sb.auth.getSession();
    if (!session) return show('login');
    const P = await PERM.load(sb);
    if (!P || !P.staff_id) return PERM.deny(sb, PERM.notLinked(session.user.email));
    if (!PERM.can('vendite', 1)) return PERM.deny(sb, PERM.notForProfile());
    canWrite = PERM.can('vendite', 2); canManage = PERM.can('vendite', 3);
    $('who').textContent = P.full_name || ''; $('btn-logout').hidden = false; $('btn-refresh').hidden = false;
    $('btn-new').hidden = !canWrite;
    show('main'); await loadAll(); showTab((location.hash || '#oggi').slice(1).replace(/[^a-z]/g, '') || 'oggi', false);
  }
  $('btn-login').onclick = async () => { const { error } = await sb.auth.signInWithPassword({ email: $('email').value, password: $('pw').value }); if (error) return toast(error.message, 'err'); init(); };
  $('pw').addEventListener('keydown', e => { if (e.key === 'Enter') $('btn-login').click(); });
  $('btn-logout').onclick = async () => { await sb.auth.signOut(); location.reload(); };
  $('btn-refresh').onclick = () => loadAll();
  function showTab(name, push = true) {
    if (!document.getElementById('p-' + name)) name = 'oggi';
    document.querySelectorAll('.tab').forEach(t => t.setAttribute('aria-selected', t.dataset.tab === name));
    document.querySelectorAll('.pane').forEach(p => p.classList.toggle('active', p.id === 'p-' + name));
    if (push) { try { history.replaceState(null, '', '#' + name); } catch {} }
  }
  $('tabs').onclick = e => { const t = e.target.closest('.tab'); if (t) showTab(t.dataset.tab); };

  async function loadAll() {
    const [s, l] = await Promise.all([sb.rpc('sales_status'), sb.from('sales_leads').select('*').order('priority').order('next_action_date', { nullsFirst: false })]);
    if (s.error) { toast(s.error.message, 'err'); return; }
    S = s.data; leads = l.data || [];
    renderOggi(); renderBoard(); await renderPiano();
  }

  // ---------- OGGI ----------
  function renderOggi() {
    const t = S.totals || {};
    $('plan-note').innerHTML = S.plan_missing ? `<div class="card" style="border-left:4px solid var(--warn);margin-bottom:12px">Obiettivi non attivi: manca la data di apertura (<span class="mono">mkt.store_opening_date</span>) o <span class="mono">sales.plan_start</span> in Configurazione → Parametri. La pipeline funziona già.</div>` : '';
    const pct = t.target_kg_day ? Math.round(100 * t.mtd_kg_day / t.target_kg_day) : null;
    const due = (S.actions_due || []).length;
    const tiles = [
      ['Venduto / giorno', num(t.mtd_kg_day, 1) + ' kg', S.plan_missing ? 'obiettivo non attivo' : `obiettivo ${num(t.target_kg_day, 0)} kg · ${pct ?? '–'}%`, pct != null && pct < 90],
      ['Incasso del mese', eur(t.mtd_revenue_eur), S.plan_missing ? 'netto IVA' : 'obiettivo ' + eur(t.month_target_eur), false],
      ['Latte usato (7 gg)', num(t.milk_l_day_last7) + ' L/g', `${num(t.pct_of_full_volume)}% dei ${num(t.milk_l_day_full)} L della Masseria`, false],
      ['Locali in trattativa', num(S.pipeline.active_n), `≈ ${num(S.pipeline.open_kg_day, 1)} kg/g se chiusi`, S.pipeline.active_n < (S.research?.min_active_leads || 25)],
      ['Da contattare', num(due), 'oggi e domani', due > 0],
      ['Clienti ristorazione 30 gg', num(S.accounts.active_b2b_30d), `${num(S.accounts.standing_kg_week, 1)} kg/sett. in ordini fissi`, false]];
    $('tiles').innerHTML = tiles.map(([l, v, d, bad]) => `<div class="tile ${bad ? 'bad' : ''}"><div class="l">${l}</div><div class="v">${v}</div><div class="d">${esc(d)}</div></div>`).join('');
    const nd = $('n-due'); nd.textContent = due || ''; nd.classList.toggle('on', !!due);
    const rows = S.channels || [];
    $('o-chan').innerHTML = '<table class="chan"><tr><th>Canale</th><th class="num">kg/g mese</th><th class="num">Obiettivo</th><th>Avanzamento</th><th class="num">Ultimi 7 gg</th><th class="num">Incasso mese</th><th class="num">Serve da qui a fine mese</th></tr>' +
      rows.map(r => { const p = r.pct_of_target; const w = Math.min(100, p || 0);
        return `<tr><td>${esc(r.name)}</td><td class="num">${num(r.mtd_kg_day, 1)}</td><td class="num">${r.target_kg_day == null ? '–' : num(r.target_kg_day, 1)}</td>
        <td><span class="bar"><i class="${p == null ? '' : p >= 100 ? 'ok' : p < 70 ? 'low' : ''}" style="width:${w}%"></i></span>${p == null ? '' : p + '%'}</td>
        <td class="num">${num(r.last7_kg_day, 1)}</td><td class="num">${eur(r.mtd_revenue_eur)}</td><td class="num">${r.needed_kg_day_rest == null ? '–' : num(r.needed_kg_day_rest, 1) + ' kg/g'}</td></tr>`; }).join('') + '</table>';
    $('o-chan-note').textContent = `kg di mozzarella (ricotta esclusa) · resa ${num(S.yield_pct)}% · mese ${S.month_no ?? '–'} del piano` + (t.capacity_warning ? ' · ATTENZIONE: l\'obiettivo del mese supera il 90% della capacità impianto' : '');
    const ad = S.actions_due || [];
    $('o-due').innerHTML = ad.length ? ad.map(a => `<div class="act"><div class="hd"><b>${esc(a.name)}</b><span>${pill(a.stage)} ${a.overdue_days > 0 ? `<span class="pill review">${a.overdue_days} gg di ritardo</span>` : ''}</span></div>
        <div class="status">${esc(a.segment)} · ${esc(a.town || '')}${a.phone ? ' · ' + esc(a.phone) : ''} · ≈ ${num(a.est_kg_week)} kg/sett.</div>
        <div>${esc(a.next_action || '')} · ${dShort(a.due)}</div>
        <div class="row"><button class="btn sm" data-open="${a.id}">Apri</button>${a.phone ? `<a class="btn sec sm" style="text-decoration:none" target="_blank" rel="noopener" href="https://wa.me/${esc(String(a.phone).replace(/\D/g, '').replace(/^(?!39)/, '39'))}">WhatsApp</a>` : ''}</div></div>`).join('')
      : '<div class="empty">Nessun contatto in scadenza.</div>';
    $('o-tast').innerHTML = list(S.tastings_next_7d, r => `${dShort(r.date)} · <b>${esc(r.name)}</b> ${esc(r.town || '')}`, 'Nessuna degustazione in programma.');
    $('o-stale').innerHTML = list(S.stale, r => `<a href="#" data-open="${r.id}">${esc(r.name)}</a> · ${esc(r.stage)} · ${r.days_since_contact == null ? 'mai contattato' : r.days_since_contact + ' gg senza contatto'}`, 'Nessuna trattativa ferma.');
    $('o-lapsed').innerHTML = list(S.accounts.lapsed, r => `<b>${esc(r.customer)}</b> · ultimo ordine ${dShort(r.last_order)} (${r.days} gg)${r.phone ? ' · ' + esc(r.phone) : ''}`, 'Nessun cliente perso.');
    $('o-mkt').innerHTML = list(S.marketplaces, r => `<b>${esc(r.name)}</b> · ${pill(r.status)} · commissione ${num(r.commission_pct)}% → listino +${num(r.markup_pct)}% · ${num(r.orders_30d)} ordini 30 gg`, '—');
  }
  const list = (arr, f, empty) => (arr && arr.length) ? arr.map(r => `<div class="slot"><span>${f(r)}</span></div>`).join('') : `<div class="empty">${empty}</div>`;
  const ST_IT = { nuovo: 'nuovo', contattato: 'contattato', degustazione: 'degustazione', offerta: 'offerta', cliente: 'cliente', perso: 'perso', in_pausa: 'in pausa', planned: 'da attivare', applying: 'in attivazione', live: 'attivo', paused: 'in pausa' };
  const pill = s => `<span class="pill ${s === 'cliente' || s === 'live' ? 'live' : s === 'offerta' || s === 'degustazione' ? 'draft' : s === 'applying' ? 'applying' : ''}">${esc(ST_IT[s] || s)}</span>`;
  document.addEventListener('click', e => { const o = e.target.closest('[data-open]'); if (o) { e.preventDefault(); openLead(o.dataset.open); } });

  // ---------- PIPELINE ----------
  function renderBoard() {
    const q = $('f-q').value.trim().toLowerCase(), seg = $('f-seg').value, td = today();
    const vis = leads.filter(l => (!q || (l.name + ' ' + (l.town || '')).toLowerCase().includes(q)) && (!seg || SEG_CH(l.segment) === seg));
    $('board').innerHTML = STAGES.map(([st, lab]) => { const ls = vis.filter(l => l.stage === st); const kg = ls.reduce((s, l) => s + Number(l.est_kg_week || 0), 0);
      return `<div class="col-st"><h4><span>${lab} · ${ls.length}</span><span>${num(kg)} kg/sett</span></h4>${ls.map(l => `<div class="lead ${l.priority === 1 ? 'p1' : ''}" data-open="${l.id}"><b>${esc(l.name)}</b><small>${esc(l.segment)} · ${esc(l.town || '')}</small>${l.next_action_date ? `<span class="due ${l.next_action_date < td ? 'ko' : ''}">${esc(l.next_action || '')} · ${dShort(l.next_action_date)}</span>` : ''}</div>`).join('') || '<div class="empty">—</div>'}</div>`; }).join('');
    const closed = vis.filter(l => ['perso', 'in_pausa'].includes(l.stage));
    $('closed').innerHTML = closed.length ? '<table><tr><th>Locale</th><th>Fase</th><th>Motivo / note</th></tr>' + closed.map(l => `<tr><td><a href="#" data-open="${l.id}">${esc(l.name)}</a> <small class="status">${esc(l.town || '')}</small></td><td>${pill(l.stage)}</td><td>${esc(l.lost_reason || l.notes || '')}</td></tr>`).join('') + '</table>' : '<div class="empty">Nessuno.</div>';
  }
  $('f-q').oninput = renderBoard; $('f-seg').onchange = renderBoard;
  $('btn-new').onclick = () => openLead(null);

  const F = { name: 'ld-name', segment: 'ld-seg', town: 'ld-town', phone: 'ld-phone', email: 'ld-email', instagram: 'ld-ig', stage: 'ld-stage', priority: 'ld-prio', est_kg_week: 'ld-kg', next_action: 'ld-next', next_action_date: 'ld-nextd', current_supplier: 'ld-sup', notes: 'ld-notes' };
  async function openLead(id) {
    cur = id ? leads.find(l => l.id === id) || must(await sb.from('sales_leads').select('*').eq('id', id).single()) : null;
    $('ld-title').textContent = cur ? cur.name : 'Nuovo locale';
    for (const [k, el] of Object.entries(F)) $(el).value = cur ? (cur[k] ?? '') : (k === 'stage' ? 'nuovo' : k === 'priority' ? '2' : k === 'segment' ? 'pizzeria' : '');
    $('ld-why').innerHTML = cur ? [cur.fit_note, cur.size_hint, cur.website ? `<a href="${esc(cur.website)}" target="_blank" rel="noopener">sito</a>` : '', cur.source_url ? `<a href="${esc(cur.source_url)}" target="_blank" rel="noopener">fonte</a>` : ''].filter(Boolean).join(' · ') : '';
    $('ld-log-box').hidden = !cur; $('ld-msg').innerHTML = '';
    $('ld-save').hidden = !canWrite; $('la-save').disabled = !canWrite;
    $('la-kind').value = 'whatsapp'; $('la-out').value = ''; $('la-next').value = ''; $('la-nextd').value = ''; $('la-note').value = '';
    $('ld-tl').innerHTML = '';
    if (cur) {
      const acts = must(await sb.from('sales_activities').select('*').eq('lead_id', cur.id).order('at', { ascending: false }).limit(30));
      $('ld-tl').innerHTML = acts.length ? acts.map(a => `<div class="tl"><b>${esc(a.kind)}</b>${a.outcome ? ' · ' + esc(a.outcome.replace('_', ' ')) : ''} <small>${new Date(a.at).toLocaleString('it-IT', { timeZone: 'Europe/Rome', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })} · ${esc(a.staff_name || '')}</small>${a.note ? '<br>' + esc(a.note) : ''}</div>`).join('') : '<div class="empty">Nessun contatto registrato.</div>';
    }
    $('dlg-lead').showModal();
  }
  $('ld-save').onclick = () => run(async () => {
    const v = {}; for (const [k, el] of Object.entries(F)) { const x = $(el).value.trim(); v[k] = x === '' ? null : x; }
    if (!v.name) throw new Error('Nome obbligatorio');
    v.priority = Number(v.priority || 2); v.est_kg_week = v.est_kg_week == null ? null : Number(v.est_kg_week);
    if (cur) { if (v.stage === 'perso' && !v.notes && !cur.lost_reason) v.lost_reason = 'non indicato'; must(await sb.from('sales_leads').update(v).eq('id', cur.id)); }
    else { const r = must(await sb.rpc('sales_add_lead', { p: { ...v, source: 'manuale' } })); if (!r.created) throw new Error(r.reason === 'già cliente' ? 'È già un cliente in Shopify' : 'Locale già presente'); }
    $('dlg-lead').close(); await loadAll();
  }, 'Salvato');
  $('la-save').onclick = () => run(async () => {
    must(await sb.rpc('sales_log_activity', { p_lead: cur.id, p_kind: $('la-kind').value, p_outcome: $('la-out').value || null, p_note: $('la-note').value || null, p_next_action: $('la-next').value || null, p_next_date: $('la-nextd').value || null }));
    await loadAll(); await openLead(cur.id);
  }, 'Contatto registrato');
  document.querySelectorAll('[data-msg]').forEach(b => b.onclick = () => run(async () => {
    const m = must(await sb.rpc('sales_lead_message', { p_lead: cur.id, p_kind: b.dataset.msg }));
    const ph = cur.phone ? String(cur.phone).replace(/\D/g, '').replace(/^(?!39)/, '39') : null;
    $('ld-msg').innerHTML = `<div class="msg" id="ld-msg-t">${esc(m)}</div><div class="row"><button class="btn sec sm" type="button" id="ld-copy">Copia</button>${ph ? `<a class="btn sm" style="text-decoration:none" target="_blank" rel="noopener" href="https://wa.me/${ph}?text=${encodeURIComponent(m)}">Apri in WhatsApp</a>` : ''}</div>`;
    $('ld-copy').onclick = () => navigator.clipboard.writeText(m).then(() => toast('Copiato'));
  }));

  // ---------- PIANO ----------
  async function renderPiano() {
    $('piano-note').textContent = S.plan_missing ? 'Imposta la data di apertura per vedere il piano mese per mese.' : `Mese 1 = ${dShort(S.plan_start)}. Obiettivi = rampa per mese di piano × stagionalità del mese. A regime ${num(S.totals.milk_l_day_full)} L/giorno di latte.`;
    const [pm, ch] = await Promise.all([S.plan_missing ? { data: [] } : sb.from('v_sales_plan_months').select('*').order('month_no').order('sort'), sb.from('sales_plan_channels').select('*').order('sort')]);
    const rows = pm.data || [], chans = ch.data || [];
    if (rows.length) {
      const months = [...new Set(rows.map(r => r.month_no))];
      const by = (m, c) => rows.find(r => r.month_no === m && r.channel === c);
      $('plan-tbl').innerHTML = '<table><tr><th>Mese</th>' + chans.map(c => `<th class="num">${esc(c.name_it)}</th>`).join('') + '<th class="num">Totale kg/g</th><th class="num">Latte L/g</th><th class="num">Incasso</th></tr>' +
        months.map(m => { const rs = chans.map(c => by(m, c.code) || {}); const kg = rs.reduce((s, r) => s + Number(r.kg_day || 0), 0); const l = rs.reduce((s, r) => s + Number(r.milk_l_day || 0), 0); const eu = rs.reduce((s, r) => s + Number(r.revenue_net_eur || 0), 0);
          const mo = rs.find(r => r.month)?.month;
          return `<tr><td>${m} · ${mo ? new Date(mo + 'T12:00:00').toLocaleDateString('it-IT', { month: 'short', year: '2-digit' }) : ''}</td>${rs.map(r => `<td class="num">${num(r.kg_day)}</td>`).join('')}<td class="num"><b>${num(kg)}</b></td><td class="num ${l > (S.totals.plant_capacity_l_day || 1200) ? 'ko' : ''}">${num(l)}</td><td class="num">${eur(eu)}</td></tr>`; }).join('') + '</table>';
    } else $('plan-tbl').innerHTML = '<div class="empty">—</div>';
    $('chan-edit').innerHTML = '<table class="rec"><tr><th>Canale</th><th class="num">€/kg netto</th><th class="num">kg/g a regime</th><th>Note</th></tr>' + chans.map(c => `<tr><td>${esc(c.name_it)}</td>
      <td class="num">${canManage ? `<input type="number" step="0.01" data-c="${c.code}" data-k="price_net_eur_kg" value="${c.price_net_eur_kg}">` : num(c.price_net_eur_kg, 2)}</td>
      <td class="num">${canManage ? `<input type="number" step="1" data-c="${c.code}" data-k="full_kg_day" value="${c.full_kg_day}">` : num(c.full_kg_day)}</td><td class="status">${esc(c.notes || '')}</td></tr>`).join('') + '</table>' +
      (canManage ? '<div class="hint" style="margin-top:6px">La rampa mese per mese e la stagionalità si modificano nelle tabelle sales_ramp e sales_seasonality.</div>' : '');
    $('chan-edit').querySelectorAll('input[data-c]').forEach(i => i.onchange = () => run(async () => { must(await sb.from('sales_plan_channels').update({ [i.dataset.k]: Number(i.value) }).eq('code', i.dataset.c)); await loadAll(); }, 'Salvato'));
  }

  init();
})();
