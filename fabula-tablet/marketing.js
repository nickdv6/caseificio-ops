/* La Perla · Marketing ("Sempre 100% bufala"): Oggi · Calendario contenuti (claims check, approvazione, bozze Predis.ai) · Ritiri su preordine ·
   Canali (Glovo, Just Eat, sito, banco) + link/QR tracciati · Creator (CRM, messaggi, collaborazioni, codici) · Foto e video · Campagne e budget. */
(() => {
  const CFG = window.FABULA_CONFIG;
  const sb = supabase.createClient(CFG.supabaseUrl, CFG.supabaseKey, { db: { schema: 'fabula' } });
  const $ = id => document.getElementById(id);
  document.addEventListener('wheel', e => { const a = document.activeElement; if (a && a.tagName === 'INPUT' && a.type === 'number' && e.target === a) e.preventDefault(); }, { passive: false });
  let staff = null, settings = {}, assets = [], campaigns = [], calStart = mondayOf(new Date()), cur = null, curInf = null;
  const show = v => document.querySelectorAll('.view').forEach(e => e.classList.toggle('active', e.id === 'v-' + v));
  const toast = (m, cls = '') => { const t = $('toast'); t.textContent = m; t.className = 'toast ' + cls; t.style.display = 'block'; setTimeout(() => t.style.display = 'none', 3200); };
  const eur = (n, d = 0) => n == null ? '–' : new Intl.NumberFormat('it-IT', { style: 'currency', currency: 'EUR', maximumFractionDigits: d, minimumFractionDigits: d }).format(n);
  const num = (n, d = 0) => n == null ? '–' : Number(n).toLocaleString('it-IT', { maximumFractionDigits: d });
  const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const romeDate = d => new Date(d).toLocaleDateString('sv-SE', { timeZone: 'Europe/Rome' });
  const romeTime = d => new Date(d).toLocaleTimeString('it-IT', { timeZone: 'Europe/Rome', hour: '2-digit', minute: '2-digit' });
  const dayLabel = s => new Date(s + 'T12:00:00').toLocaleDateString('it-IT', { weekday: 'long', day: 'numeric', month: 'long' });
  function mondayOf(d) { const x = new Date(d); x.setHours(12, 0, 0, 0); x.setDate(x.getDate() - ((x.getDay() + 6) % 7)); return x; }
  const addDays = (d, n) => { const x = new Date(d); x.setDate(x.getDate() + n); return x; };
  const iso = d => d.toLocaleDateString('sv-SE');
  const STATUS_IT = { idea: 'idea', generating: 'in generazione', draft: 'bozza', review: 'da approvare', approved: 'approvato', scheduled: 'programmato', published: 'pubblicato', rejected: 'scartato',
    planned: 'da attivare', applying: 'in attivazione', live: 'attivo', paused: 'in pausa', prospect: 'da contattare', contacted: 'contattato', negotiating: 'trattativa', gifted: 'visita/regalo', posted: 'ha pubblicato', affiliate: 'affiliato', declined: 'rifiutato',
    da_preparare: 'da preparare', pronto: 'pronto', ritirato: 'ritirato', non_ritirato: 'non ritirato', active: 'attiva', done: 'chiusa', cancelled: 'annullata' };
  const pill = s => `<span class="pill ${esc(s)}">${esc(STATUS_IT[s] || s)}</span>`;
  const PLAT = { instagram: 'IG', facebook: 'FB', tiktok: 'TT', google: 'G', newsletter: '✉', whatsapp: 'WA', sito: 'WEB' };
  const run = async (fn, okMsg) => { try { const r = await fn(); if (okMsg) toast(okMsg); return r; } catch (e) { toast(e.message || String(e), 'err'); throw e; } };
  const must = ({ data, error }) => { if (error) throw error; return data; };

  // ---------- auth ----------
  async function init() {
    const { data: { session } } = await sb.auth.getSession();
    if (!session) return show('login');
    const P = await PERM.load(sb);
    if (!P || !P.staff_id) return PERM.deny(sb, PERM.notLinked(session.user.email));
    if (!PERM.page('marketing')) return PERM.deny(sb, PERM.notForProfile());
    const { data } = await sb.from('staff').select('*').eq('id', P.staff_id).maybeSingle();
    staff = { ...(data || { id: P.staff_id, full_name: P.full_name }), app_role: P.role, role_name: P.role_name };
    $('who').textContent = staff.full_name; $('btn-logout').hidden = false; $('btn-refresh').hidden = false;
    show('main'); await loadAll(); showTab((location.hash || '#oggi').slice(1).replace(/[^a-z]/g, '') || 'oggi', false);
  }
  $('btn-login').onclick = async () => { const { error } = await sb.auth.signInWithPassword({ email: $('email').value, password: $('pw').value }); if (error) return toast(error.message, 'err'); init(); };
  $('pw').addEventListener('keydown', e => { if (e.key === 'Enter') $('btn-login').click(); });
  PERM.forgot(sb, toast);
  $('btn-logout').onclick = async () => { await sb.auth.signOut(); location.reload(); };
  $('btn-refresh').onclick = () => loadAll();
  function showTab(name, push = true) {
    document.querySelectorAll('.tab').forEach(t => t.setAttribute('aria-selected', t.dataset.tab === name));
    document.querySelectorAll('.pane').forEach(p => p.classList.toggle('active', p.id === 'p-' + name));
    if (push) { try { history.replaceState(null, '', '#' + name); } catch {} }
  }
  $('tabs').onclick = e => { const t = e.target.closest('.tab'); if (t) showTab(t.dataset.tab); };
  const badge = (id, n) => { const b = $(id); b.textContent = n || ''; b.classList.toggle('on', !!n); };

  async function loadAll() {
    const [s, a, c] = await Promise.all([sb.from('settings').select('*'), sb.from('mkt_assets').select('*').order('created_at', { ascending: false }), sb.from('mkt_campaigns').select('*').order('starts_on', { nullsFirst: false })]);
    settings = Object.fromEntries((s.data || []).map(r => [r.key, r])); assets = a.data || []; campaigns = c.data || [];
    await Promise.all([loadOggi(), loadCal(), loadPickups(), loadChannels(), loadInf(), renderLib(), renderCampaigns()]);
    renderParams();
  }

  // ---------- OGGI ----------
  async function loadOggi() {
    const [w, ch, codes] = await Promise.all([sb.rpc('mkt_weekly_status'), sb.from('v_mkt_channel_sales_30d').select('*'), sb.from('v_mkt_code_performance').select('*').order('revenue_eur', { ascending: false })]);
    const s = w.data || {};
    const pickTom = (s.pickups_next_7d || []).find(p => p.date === iso(addDays(new Date(), 1)));
    const tiles = [
      ['Preordini domani', pickTom ? num(pickTom.orders) : '0', pickTom ? num(pickTom.kg, 1) + ' kg' : 'nessuno', false],
      ['Post prossimi 7 gg', num((s.content_next_7d || []).length), s.content_gaps ? s.content_gaps + ' giorni scoperti' : 'calendario pieno', s.content_gaps > 2],
      ['Da approvare', num(s.to_review), 'post in attesa', s.to_review > 0],
      ['Creator da ricontattare', num((s.influencers_follow_up || []).length), 'nessun contatto da 7+ giorni', (s.influencers_follow_up || []).length > 0],
      ['Canali non attivi', num((s.channels_not_live || []).length), (s.channels_not_live || []).slice(0, 3).join(', ') || 'tutti attivi', false],
      ['Budget marketing', eur(s.budget?.spent_eur), 'speso su ' + eur(s.budget?.year_eur) + ' / anno', false]];
    $('tiles').innerHTML = tiles.map(([l, v, d, bad]) => `<div class="tile ${bad ? 'bad' : ''}"><div class="l">${l}</div><div class="v">${v}</div><div class="d">${esc(d)}</div></div>`).join('');
    badge('n-review', s.to_review); badge('n-follow', (s.influencers_follow_up || []).length);
    const wk = s.content_next_7d || [];
    $('o-week').innerHTML = wk.length ? wk.map(p => `<div class="slot"><span><b>${esc(p.when)}</b> · ${esc(PLAT[p.platform] || p.platform)} · ${esc(p.text || '—')}</span><span>${pill(p.status)}${p.no_asset ? ' <span class="pill">senza foto</span>' : ''}${p.blocking ? ' <span class="pill review">testo da correggere</span>' : ''}</span></div>`).join('')
      : '<div class="empty">Nessun post nei prossimi 7 giorni. Vai al Calendario.</div>';
    const rows = ch.data || [];
    $('o-channels').innerHTML = rows.length ? '<table><tr><th>Canale</th><th class="num">Ordini</th><th class="num">kg</th><th class="num">Incasso</th></tr>' + rows.sort((a, b) => b.revenue_eur - a.revenue_eur).map(r => `<tr><td>${esc(r.channel)}</td><td class="num">${num(r.orders)}</td><td class="num">${num(r.kg, 1)}</td><td class="num">${eur(r.revenue_eur)}</td></tr>`).join('') + '</table>' : '<div class="empty">Nessuna vendita negli ultimi 30 giorni.</div>';
    const cr = (codes.data || []).filter(r => r.influencer || r.campaign || r.orders);
    $('o-codes').innerHTML = cr.length ? '<table><tr><th>Codice</th><th>Di chi</th><th class="num">Ordini</th><th class="num">Incasso</th></tr>' + cr.map(r => `<tr><td class="mono">${esc(r.code)}</td><td>${esc(r.influencer || r.campaign || '—')}</td><td class="num">${num(r.orders)}</td><td class="num">${eur(r.revenue_eur)}</td></tr>`).join('') + '</table>' : '<div class="empty">Nessun codice ancora.</div>';
    loadAiStatus();
  }
  async function loadAiStatus() {
    const box = $('o-ai');
    try {
      const { data, error } = await sb.functions.invoke('predis', { body: { action: 'status' } });
      if (error) throw error;
      box.innerHTML = data.configured ? '<div class="ok">Collegato. Le bozze arrivano nel calendario (stato "bozza") appena pronte.</div><div class="row"><button class="btn sm sec" id="ai-sync">Recupera bozze pronte</button></div>'
        : `<div class="ko">Da collegare.</div><ol class="hint" style="padding-left:18px">
           <li>Abbonamento Predis.ai (piano Core o Rise: l'API è inclusa) e Brand Kit con logo, colori navy/oro, font.</li>
           <li>Supabase → Edge Functions → Secrets: <span class="mono">PREDIS_API_KEY</span>${data.has_key ? ' ✓' : ''}, <span class="mono">PREDIS_WEBHOOK_TOKEN</span> (una parola segreta a scelta).</li>
           <li>Configurazione → Marketing (qui sotto): brand_id di Predis${data.has_brand ? ' ✓' : ''}.</li>
           <li>Predis → Pricing &amp; Account → Rest API → webhook: <span class="mono">${CFG.supabaseUrl}/functions/v1/predis-webhook?token=…</span></li></ol>
           <div class="params" data-groups="mkt"></div>`;
      if ($('ai-sync')) $('ai-sync').onclick = () => run(async () => { const r = await sb.functions.invoke('predis', { body: { action: 'sync' } }); if (r.error) throw r.error; await loadCal(); return r; }, 'Bozze aggiornate');
      renderParams();
    } catch (e) { box.innerHTML = `<div class="ko">Funzione non raggiungibile: ${esc(e.message || e)}</div>`; }
  }

  // ---------- settings editor (pickup.*, mkt.*) ----------
  function renderParams() {
    document.querySelectorAll('.params').forEach(box => {
      const groups = box.dataset.groups.split(',');
      const mine = Object.values(settings).filter(r => groups.includes(r.key.split('.')[0])).sort((a, b) => (a.sort ?? 100) - (b.sort ?? 100));
      box.innerHTML = '';
      mine.forEach(r => {
        const row = document.createElement('div'); row.className = 'set-row text';
        row.innerHTML = `<div class="lbl">${esc(r.description || r.key)}<small>${esc(r.key)}</small></div>`;
        const right = document.createElement('div'); right.className = 'row'; right.style.marginTop = '0';
        const inp = document.createElement('input'); inp.type = 'text'; inp.className = 'wide'; inp.value = r.value;
        const b = document.createElement('button'); b.className = 'btn sm'; b.textContent = 'Salva';
        b.onclick = () => run(async () => { let v = inp.value.trim(); if (r.data_type === 'number' && isNaN(Number(v.replace(',', '.')))) throw new Error('Inserisci un numero'); if (r.data_type === 'number') v = String(Number(v.replace(',', '.'))); PERM.changed(await sb.from('settings').update({ value: v }).eq('key', r.key).select('key')); settings[r.key].value = v; }, 'Salvato');
        right.append(inp, b); row.append(right); box.append(row);
      });
    });
  }

  // ---------- CALENDARIO ----------
  $('cal-prev').onclick = () => { calStart = addDays(calStart, -7); loadCal(); };
  $('cal-next').onclick = () => { calStart = addDays(calStart, 7); loadCal(); };
  $('cal-today').onclick = () => { calStart = mondayOf(new Date()); loadCal(); };
  $('cal-filter').onchange = () => loadCal();
  async function loadCal() {
    const from = calStart, to = addDays(calStart, 14);
    $('cal-range').textContent = from.toLocaleDateString('it-IT', { day: 'numeric', month: 'short' }) + ' – ' + addDays(to, -1).toLocaleDateString('it-IT', { day: 'numeric', month: 'short', year: 'numeric' });
    let q = sb.from('mkt_content').select('*').gte('scheduled_at', romeInputToIso(iso(from) + 'T00:00')).lt('scheduled_at', romeInputToIso(iso(to) + 'T00:00')).order('scheduled_at');   // v0.60: window starts at midnight in Agropoli, not UTC
    if ($('cal-filter').value) q = q.eq('status', $('cal-filter').value);
    const [{ data: rows }, { data: undated }, { data: anyRow }] = await Promise.all([q, sb.from('mkt_content').select('*').is('scheduled_at', null).neq('status', 'rejected'), sb.from('mkt_content').select('id').limit(1)]);
    $('cal-seed').innerHTML = (anyRow || []).length ? '' : `Calendario vuoto. <b>Crea il piano di lancio</b>: 4 campagne e 28 post (dal giorno -7 al +27) con i brief già scritti. Data di apertura: <input type="date" id="seed-date" class="fi" style="width:auto"> <button class="btn sm" id="seed-go">Crea piano</button>`;
    if ($('seed-go')) $('seed-go').onclick = () => run(async () => { const d = $('seed-date').value; if (!d) throw new Error('Scegli la data di apertura'); const r = must(await sb.rpc('mkt_seed_launch', { p_launch: d })); calStart = mondayOf(new Date(d + 'T12:00:00')); calStart = addDays(calStart, -7); await loadAll(); return r; }, 'Piano di lancio creato');
    const byDay = {}; (rows || []).forEach(r => { const k = romeDate(r.scheduled_at); (byDay[k] = byDay[k] || []).push(r); });
    const today = romeDate(new Date());
    let html = '';
    for (let i = 0; i < 14; i++) {
      const k = iso(addDays(from, i)); const list = byDay[k] || [];
      html += `<div class="day"><div class="dh ${k === today ? 'today' : ''}">${dayLabel(k)}${list.length ? '' : ' <span class="status" style="font-family:var(--body);font-weight:400;text-transform:none">· niente in programma</span>'}</div>${list.map(postRow).join('')}</div>`;
    }
    if ((undated || []).length) html += `<div class="day"><div class="dh">Senza data</div>${undated.map(postRow).join('')}</div>`;
    $('cal').innerHTML = html;
    $('cal').querySelectorAll('.post').forEach(el => el.onclick = () => openPost(el.dataset.id));
  }
  function postRow(r) {
    const camp = campaigns.find(c => c.id === r.campaign_id);
    return `<div class="post" data-id="${r.id}"><div class="tm">${r.scheduled_at ? romeTime(r.scheduled_at) : '—'}<br><b>${esc(PLAT[r.platform] || r.platform)}</b></div>
      <div class="tx">${esc((r.caption_it || r.brief_it || '').slice(0, 140))}<small>${esc(r.format)} · ${esc(r.pillar.replace('_', ' '))}${camp ? ' · ' + esc(camp.name) : ''}</small></div>
      <div class="flags">${pill(r.status)}${r.asset_ids?.length ? `<span class="pill">${r.asset_ids.length} media</span>` : '<span class="pill">senza foto</span>'}${r.claims_blocking ? '<span class="pill review">testo ⚠</span>' : ''}</div></div>`;
  }
  $('cal-new').onclick = () => openPost(null);

  const toLocalInput = s => { if (!s) return ''; const d = new Date(s); return d.toLocaleDateString('sv-SE', { timeZone: 'Europe/Rome' }) + 'T' + d.toLocaleTimeString('it-IT', { timeZone: 'Europe/Rome', hour: '2-digit', minute: '2-digit' }); };
  function romeInputToIso(v) { // treat datetime-local as Europe/Rome wall clock
    if (!v) return null; const guess = new Date(v + ':00Z');
    const off = (new Date(guess.toLocaleString('en-US', { timeZone: 'Europe/Rome' })) - new Date(guess.toLocaleString('en-US', { timeZone: 'UTC' }))) / 60000;
    return new Date(guess.getTime() - off * 60000).toISOString();
  }
  async function openPost(id) {
    cur = id ? must(await sb.from('mkt_content').select('*').eq('id', id).single()) : { status: 'idea', platform: 'instagram', format: 'post', pillar: 'origine', asset_ids: [], hashtags: settings['mkt.hashtags']?.value || '', claims: [] };
    $('pe-title').textContent = id ? 'Post' : 'Nuovo post';
    $('pe-when').value = toLocalInput(cur.scheduled_at); $('pe-platform').value = cur.platform; $('pe-format').value = cur.format; $('pe-pillar').value = cur.pillar;
    $('pe-campaign').innerHTML = '<option value="">—</option>' + campaigns.map(c => `<option value="${c.id}" ${c.id === cur.campaign_id ? 'selected' : ''}>${esc(c.name)}</option>`).join('');
    $('pe-status').value = STATUS_IT[cur.status] || cur.status; $('pe-brief').value = cur.brief_it || ''; $('pe-cap').value = cur.caption_it || ''; $('pe-cap-en').value = cur.caption_en || '';
    $('pe-tags').value = cur.hashtags || ''; $('pe-link').value = cur.link_url || ''; $('pe-pub').value = cur.published_url || '';
    $('pe-published').hidden = !['approved', 'scheduled'].includes(cur.status); $('pe-review').hidden = ['review', 'approved', 'scheduled', 'published'].includes(cur.status);
    renderClaims(cur.claims); renderPicker(); $('dlg-post').showModal();
  }
  function renderClaims(list) {
    $('pe-claims').innerHTML = (list || []).length ? list.map(c => `<div class="claim ${c.severity}"><b>${c.severity === 'block' ? 'Da correggere' : c.severity === 'warn' ? 'Attenzione' : 'Nota'}</b> · ${esc(c.message)}${c.match ? ` <span class="mono">“${esc(c.match)}”</span>` : ''}</div>`).join('') : '<div class="claim info">Nessun problema nel testo.</div>';
  }
  let claimTimer = null;
  ['pe-cap', 'pe-cap-en', 'pe-tags'].forEach(id => $(id).addEventListener('input', () => {
    clearTimeout(claimTimer); claimTimer = setTimeout(async () => {
      const hasAi = assets.some(a => cur.asset_ids.includes(a.id) && a.ai_generated);
      const { data } = await sb.rpc('mkt_check_claims', { p_text: [$('pe-cap').value, $('pe-cap-en').value, $('pe-tags').value].join(' '), p_is_collab: $('pe-pillar').value === 'collab' || !!cur.collab_id, p_has_ai: hasAi });
      renderClaims(data);
    }, 500);
  }));
  function renderPicker() {
    const box = $('pe-assets');
    const usable = assets.slice(0, 60);
    box.innerHTML = usable.length ? usable.map(a => `<div class="thumb ${cur.asset_ids.includes(a.id) ? 'on' : ''}" data-id="${a.id}">${a.kind === 'video' ? `<video src="${esc(a.url)}" muted></video>` : `<img src="${esc(a.url)}" loading="lazy" alt="">`}${a.ai_generated ? '<span class="ai">IA</span>' : ''}<small>${esc((a.tags || []).join(' ') || a.source)}${!a.consent_ok || !a.hygiene_ok ? ' ⚠' : ''}</small></div>`).join('')
      : '<div class="empty">Nessuna foto: caricale in "Foto e video".</div>';
    box.querySelectorAll('.thumb').forEach(t => t.onclick = () => {
      const a = assets.find(x => x.id === t.dataset.id);
      if (!cur.asset_ids.includes(a.id) && (!a.consent_ok || !a.hygiene_ok) && !confirmLike(t)) return;
      cur.asset_ids = cur.asset_ids.includes(a.id) ? cur.asset_ids.filter(x => x !== a.id) : [...cur.asset_ids, a.id]; t.classList.toggle('on');
    });
  }
  function confirmLike(t) { // no browser dialogs: second tap within 4 s confirms an asset not yet checked for consent/hygiene
    if (t.dataset.warned) return true; t.dataset.warned = '1'; toast('Consenso o igiene non verificati per questo media: tocca di nuovo per usarlo comunque', 'err'); setTimeout(() => delete t.dataset.warned, 4000); return false;
  }
  function formPost() {
    return { scheduled_at: romeInputToIso($('pe-when').value), platform: $('pe-platform').value, format: $('pe-format').value, pillar: $('pe-pillar').value, campaign_id: $('pe-campaign').value || null,
      brief_it: $('pe-brief').value.trim() || null, caption_it: $('pe-cap').value.trim() || null, caption_en: $('pe-cap-en').value.trim() || null, hashtags: $('pe-tags').value.trim() || null,
      link_url: $('pe-link').value.trim() || null, published_url: $('pe-pub').value.trim() || null, asset_ids: cur.asset_ids };
  }
  async function savePost(extra = {}) {
    const row = { ...formPost(), ...extra };
    const saved = cur.id ? PERM.changed(await sb.from('mkt_content').update(row).eq('id', cur.id).select())[0] : must(await sb.from('mkt_content').insert(row).select().single());
    cur = saved; return saved;
  }
  $('pe-save').onclick = () => run(async () => { const s = await savePost(); renderClaims(s.claims); $('pe-status').value = STATUS_IT[s.status]; await loadCal(); }, 'Salvato');
  $('pe-review').onclick = () => run(async () => {
    if (!$('pe-cap').value.trim()) throw new Error('Scrivi il testo (o genera una bozza) prima di inviarlo in approvazione');
    const s = await savePost({ status: 'review' }); $('dlg-post').close(); await Promise.all([loadCal(), loadOggi()]);
    if (s.claims_blocking) toast(`Inviato, ma ci sono ${s.claims_blocking} problemi da correggere: l'approvazione sarà bloccata finché non li sistemi`, 'err');
    else toast('Inviato in approvazione: lo trovi nella console → Da approvare');
  });
  $('pe-published').onclick = () => run(async () => { if (!$('pe-pub').value.trim()) throw new Error('Incolla il link del post pubblicato'); await savePost({ status: 'published' }); $('dlg-post').close(); await loadCal(); }, 'Segnato come pubblicato');
  $('pe-copy').onclick = async () => { const t = [$('pe-cap').value, $('pe-tags').value, $('pe-link').value].filter(Boolean).join('\n\n'); try { await navigator.clipboard.writeText(t); toast('Testo copiato'); } catch { toast('Copia non riuscita', 'err'); } };
  $('pe-ai').onclick = () => run(async () => {
    if (!$('pe-brief').value.trim() && !$('pe-cap').value.trim()) throw new Error('Scrivi un brief di almeno qualche parola');
    await savePost();
    const { data, error } = await sb.functions.invoke('predis', { body: { action: 'generate', content_id: cur.id, media_type: $('pe-ai-media').value, n_posts: 1 } });
    if (error) { let msg = error.message; try { const b = await error.context.json(); msg = b.error || msg; } catch {} throw new Error(msg); }
    $('dlg-post').close(); await loadCal(); return data;
  }, 'Richiesta inviata a Predis: la bozza arriva nel calendario tra qualche minuto');

  // ---------- RITIRI ----------
  async function loadPickups() {
    const [{ data: rows }, { data: slots }] = await Promise.all([sb.from('v_pickups_upcoming').select('*'), sb.from('v_pickup_slot_load').select('*').order('pickup_date')]);
    const open = (rows || []).filter(r => ['da_preparare', 'pronto'].includes(r.pickup_status) && r.pickup_date >= romeDate(new Date()));
    badge('n-pick', open.filter(r => r.pickup_date === romeDate(new Date())).length);
    const byDay = {}; (rows || []).forEach(r => (byDay[r.pickup_date] = byDay[r.pickup_date] || []).push(r));
    $('pick-list').innerHTML = Object.keys(byDay).length ? Object.entries(byDay).map(([d, list]) => `<div class="day"><div class="dh ${d === romeDate(new Date()) ? 'today' : ''}">${dayLabel(d)} · ${list.length} ordini · ${num(list.reduce((s, r) => s + Number(r.kg || 0), 0), 1)} kg</div>
      <table><tr><th>Fascia</th><th>Ordine</th><th>Cliente</th><th>Prodotti</th><th class="num">€</th><th>Stato</th><th></th></tr>${list.map(r => `<tr><td>${esc(r.pickup_slot || '—')}</td><td>${esc(r.order_number)}</td><td>${esc(r.customer || '')}${r.phone ? `<br><a class="status" href="tel:${esc(r.phone)}">${esc(r.phone)}</a>` : ''}</td><td class="status">${esc(r.items || num(r.kg, 2) + ' kg')}</td><td class="num">${eur(r.total_eur, 2)}</td><td>${pill(r.pickup_status)}</td>
        <td style="white-space:nowrap">${r.pickup_status === 'da_preparare' ? `<button class="btn sm sec" data-o="${r.id}" data-s="pronto">Pronto</button>` : ''}${['da_preparare', 'pronto'].includes(r.pickup_status) ? ` <button class="btn sm" data-o="${r.id}" data-s="ritirato">Ritirato</button>` : ''}${r.pickup_status === 'pronto' && d < romeDate(new Date()) ? ` <button class="btn sm warn" data-o="${r.id}" data-s="non_ritirato">Non ritirato</button>` : ''}</td></tr>`).join('')}</table></div>`).join('')
      : '<div class="empty">Nessun preordine di ritiro in arrivo.</div>';
    $('pick-list').querySelectorAll('button[data-o]').forEach(b => b.onclick = () => run(async () => { const r = must(await sb.rpc('mkt_set_pickup_status', { p_order: b.dataset.o, p_status: b.dataset.s })); await loadPickups(); if (r.note) toast(r.note); }));
    const cfgSlots = (settings['pickup.slots']?.value || '').split(',').map(s => s.trim()).filter(Boolean);
    const days = [...new Set([iso(addDays(new Date(), 1)), ...(slots || []).map(s => s.pickup_date)])].sort().slice(0, 4);
    $('pick-slots').innerHTML = days.map(d => `<div class="day"><div class="dh">${dayLabel(d)}</div>${[...new Set([...cfgSlots, ...(slots || []).filter(s => s.pickup_date === d).map(s => s.slot)])].map(sl => {
      const r = (slots || []).find(s => s.pickup_date === d && s.slot === sl); const n = r ? r.orders : 0; const cap = Number(settings['pickup.slot_capacity_orders']?.value || 15);
      return `<div class="slot"><span>${esc(sl)}</span><span class="status">${n}/${cap}</span></div><div class="bar"><i class="${n >= cap ? 'full' : ''}" style="width:${Math.min(100, n / cap * 100)}%"></i></div>`; }).join('')}</div>`).join('');
  }

  // ---------- CANALI ----------
  async function loadChannels() {
    const { data: rows } = await sb.from('mkt_channels').select('*').order('sort');
    const base = Number(settings['price.retail_moz_eur_kg']?.value || 14); $('ch-base').textContent = eur(base, 2);
    const tbl = document.createElement('table'); tbl.className = 'rec';
    tbl.innerHTML = '<tr><th>Canale</th><th>Stato</th><th>Link negozio / profilo</th><th class="num">Commissione %</th><th class="num">Ricarico %</th><th class="num">Prezzo/kg</th><th class="num">Netto/kg</th><th></th></tr>';
    (rows || []).forEach(r => {
      const tr = document.createElement('tr');
      const isMk = r.kind === 'marketplace';
      tr.innerHTML = `<td><b>${esc(r.name)}</b>${r.notes ? `<br><small class="status">${esc(r.notes)}</small>` : ''}</td>
        <td><select data-k="status">${['planned', 'applying', 'live', 'paused'].map(s => `<option value="${s}" ${s === r.status ? 'selected' : ''}>${STATUS_IT[s]}</option>`).join('')}</select></td>
        <td><input type="text" data-k="store_url" value="${esc(r.store_url || '')}" placeholder="https://"></td>
        <td class="num">${isMk ? `<input type="number" step="0.5" data-k="commission_pct" value="${r.commission_pct ?? ''}">` : '—'}</td>
        <td class="num">${isMk ? `<input type="number" step="1" data-k="markup_pct" value="${r.markup_pct ?? 0}">` : '—'}</td>
        <td class="num" data-c="price"></td><td class="num" data-c="net"></td><td></td>`;
      const calc = () => {
        if (!isMk) { tr.querySelector('[data-c=price]').textContent = r.kind === 'social' || r.kind === 'newsletter' ? '' : eur(base, 2); tr.querySelector('[data-c=net]').textContent = ''; return; }
        const m = Number(tr.querySelector('[data-k=markup_pct]').value || 0), c = Number(tr.querySelector('[data-k=commission_pct]').value || 0);
        const p = base * (1 + m / 100), n = p * (1 - c / 100);
        tr.querySelector('[data-c=price]').textContent = eur(p, 2);
        const td = tr.querySelector('[data-c=net]'); td.textContent = eur(n, 2) + ' (' + (n >= base ? '+' : '') + num((n - base) / base * 100, 0) + '%)'; td.className = 'num ' + (n < base * 0.97 ? 'ko' : 'ok');
      };
      tr.querySelectorAll('input').forEach(i => i.oninput = calc); calc();
      const b = document.createElement('button'); b.className = 'btn sm'; b.textContent = 'Salva';
      b.onclick = () => run(async () => { const v = { updated_at: new Date().toISOString() }; tr.querySelectorAll('[data-k]').forEach(i => v[i.dataset.k] = i.type === 'number' ? (i.value === '' ? null : Number(i.value)) : (i.value.trim() || null)); if (v.markup_pct == null && isMk) v.markup_pct = 0; PERM.changed(await sb.from('mkt_channels').update(v).eq('code', r.code).select('code')); }, 'Canale salvato');
      tr.lastElementChild.append(b); tbl.append(tr);
    });
    $('ch-table').innerHTML = ''; $('ch-table').append(tbl);
  }
  let lastUtm = '';
  $('utm-go').onclick = () => {
    const p = new URLSearchParams({ utm_source: $('utm-src').value.trim() || 'qr', utm_medium: $('utm-med').value.trim() || 'qr', utm_campaign: $('utm-camp').value.trim() || 'lancio' });
    lastUtm = 'https://perladelcilento.it' + $('utm-page').value + '?' + p.toString();
    $('utm-out').textContent = lastUtm; $('utm-qr').innerHTML = '';
    if (window.QRCode) new QRCode($('utm-qr'), { text: lastUtm, width: 180, height: 180, colorDark: '#1e3a5f', colorLight: '#ffffff' });
  };
  $('utm-copy').onclick = async () => { if (!lastUtm) $('utm-go').click(); try { await navigator.clipboard.writeText(lastUtm); toast('Link copiato'); } catch { toast('Copia non riuscita', 'err'); } };

  // ---------- CREATOR ----------
  async function loadInf() {
    const { data: rows } = await sb.from('v_mkt_influencers').select('*').order('status').order('followers', { ascending: false, nullsFirst: false });
    const order = ['negotiating', 'contacted', 'gifted', 'posted', 'affiliate', 'prospect', 'paused', 'declined'];
    const list = (rows || []).sort((a, b) => order.indexOf(a.status) - order.indexOf(b.status));
    $('inf-table').innerHTML = list.length ? '<table><tr><th>Creator</th><th class="num">Follower</th><th>Fascia</th><th>Stato</th><th>Codice</th><th class="num">Ordini</th><th class="num">Incasso</th><th class="num">Costo</th><th>Prossima azione</th></tr>' + list.map(r => `<tr data-id="${r.id}" style="cursor:pointer">
      <td><b>${esc(r.name)}</b><br><small class="status">${esc(r.platform)} ${r.handle ? '@' + esc(String(r.handle).replace(/^@/, '')) : ''}${r.city ? ' · ' + esc(r.city) : ''}${r.niche ? ' · ' + esc(r.niche) : ''}</small></td>
      <td class="num">${num(r.followers)}</td><td>${esc(r.tier || '—')}${r.followers >= 500000 && !r.agcom_registered ? ' <span class="ko">⚠ AGCOM</span>' : ''}</td><td>${pill(r.status)}</td>
      <td class="mono">${esc(r.discount_code || '—')}</td><td class="num">${num(r.code_orders)}</td><td class="num">${eur(r.code_revenue_eur)}</td><td class="num">${eur(r.cost_eur)}</td>
      <td class="status">${esc(r.next_action || '')}${r.last_contact_on ? '<br>ultimo contatto ' + esc(r.last_contact_on) : ''}</td></tr>`).join('') + '</table>'
      : '<div class="empty">Nessun creator ancora. Aggiungi i primi 15–20 profili del Cilento e della Campania (cucina, territorio, famiglie, chef).</div>';
    $('inf-table').querySelectorAll('tr[data-id]').forEach(tr => tr.onclick = () => openInf(tr.dataset.id));
  }
  const IE = { name: 'name', handle: 'handle', platform: 'platform', followers: 'followers', eng: 'engagement_pct', city: 'city', niche: 'niche', email: 'email', phone: 'phone', status: 'status', code: 'discount_code', comm: 'commission_pct', last: 'last_contact_on', collabs: 'collabs_url', next: 'next_action', notes: 'notes' };
  async function openInf(id) {
    curInf = id ? must(await sb.from('mkt_influencers').select('*').eq('id', id).single()) : { platform: 'instagram', status: 'prospect' };
    $('ie-title').textContent = id ? curInf.name : 'Nuovo creator';
    Object.entries(IE).forEach(([k, col]) => $('ie-' + k).value = curInf[col] ?? '');
    $('ie-agcom').checked = !!curInf.agcom_registered;
    $('ie-extra').innerHTML = '';
    if (id) {
      const { data: col } = await sb.from('mkt_collabs').select('*').eq('influencer_id', id).order('created_at', { ascending: false });
      $('ie-extra').innerHTML = '<label class="fl">Collaborazioni</label>' + ((col || []).length ? '<table><tr><th>Tipo</th><th>Cosa</th><th class="num">Costo</th><th>Post</th><th>Dicitura</th></tr>' + col.map(c => `<tr><td>${esc(c.kind)}</td><td class="status">${esc(c.deliverables || '')}</td><td class="num">${eur(Number(c.fee_eur) + Number(c.product_value_eur))}</td><td>${c.post_url ? `<a href="${esc(c.post_url)}" target="_blank" rel="noopener">post</a>` : '—'}</td><td class="${c.disclosure_ok ? 'ok' : c.post_url ? 'ko' : ''}">${c.disclosure_ok ? '✓' : c.post_url ? 'da verificare' : ''}</td></tr>`).join('') + '</table>' : '<div class="empty">Nessuna.</div>');
    }
    $('dlg-inf').showModal();
  }
  $('inf-new').onclick = () => openInf(null);
  function formInf() {
    const v = {}; Object.entries(IE).forEach(([k, col]) => { const el = $('ie-' + k); v[col] = el.type === 'number' ? (el.value === '' ? null : Number(el.value)) : (el.value.trim() || null); });
    if (v.discount_code) v.discount_code = v.discount_code.toUpperCase(); if (v.handle) v.handle = v.handle.replace(/^@/, '');
    v.agcom_registered = $('ie-agcom').checked; v.updated_at = new Date().toISOString(); return v;
  }
  async function saveInf() {
    const v = formInf(); if (!v.name) throw new Error('Inserisci il nome');
    curInf = curInf.id ? PERM.changed(await sb.from('mkt_influencers').update(v).eq('id', curInf.id).select())[0] : must(await sb.from('mkt_influencers').insert(v).select().single());
    return curInf;
  }
  $('ie-save').onclick = () => run(async () => { await saveInf(); $('dlg-inf').close(); await Promise.all([loadInf(), loadOggi()]); }, 'Creator salvato');
  const draft = kind => run(async () => {
    await saveInf(); const t = must(await sb.rpc('mkt_outreach_draft', { p_influencer: curInf.id, p_kind: kind }));
    try { await navigator.clipboard.writeText(t); } catch {}
    if (kind === 'email' && curInf.email) { const [subj, ...body] = t.split('\n'); window.open(`mailto:${encodeURIComponent(curInf.email)}?subject=${encodeURIComponent(subj.replace(/^Oggetto:\s*/, ''))}&body=${encodeURIComponent(body.join('\n').trim())}`); }
    const upd = { last_contact_on: romeDate(new Date()) }; if (curInf.status === 'prospect') upd.status = 'contacted';
    PERM.changed(await sb.from('mkt_influencers').update(upd).eq('id', curInf.id).select('id')); $('ie-last').value = upd.last_contact_on; if (upd.status) $('ie-status').value = upd.status;
    loadInf();
  }, kind === 'dm' ? 'Messaggio copiato: incollalo nel DM. Contatto registrato.' : 'Email pronta e copiata. Contatto registrato.');
  $('ie-dm').onclick = () => draft('dm'); $('ie-mail').onclick = () => draft('email');
  $('ie-collab').onclick = () => run(async () => {
    if ($('cb-save')) { $('cb-kind').focus(); return; }   // a form is already open
    await saveInf(); const box = $('ie-extra');
    const f = document.createElement('div'); f.className = 'fgrid'; f.style.marginTop = '10px';
    f.innerHTML = `<div><label>Tipo</label><select id="cb-kind"><option value="gift">regalo / visita</option><option value="paid">a pagamento</option><option value="affiliate">affiliazione</option><option value="event">evento</option></select></div>
      <div><label>Compenso €</label><input id="cb-fee" type="number" value="0"></div><div><label>Valore prodotto €</label><input id="cb-val" type="number" value="0"></div>
      <div><label>Campagna</label><select id="cb-camp"><option value="">—</option>${campaigns.map(c => `<option value="${c.id}">${esc(c.name)}</option>`).join('')}</select></div>
      <div style="grid-column:1/-1"><label>Cosa si è concordato</label><input id="cb-del" placeholder="1 reel + 3 storie entro 7 giorni, con #adv"></div>
      <div style="grid-column:1/-1"><label>Link del post (quando c'è)</label><input id="cb-url"></div>
      <div><label class="status" style="text-transform:none"><input type="checkbox" id="cb-disc"> dicitura #adv presente</label></div>
      <div><button class="btn sm" type="button" id="cb-save">Registra</button></div>`;
    box.append(f);
    $('cb-save').onclick = () => run(async () => {
      must(await sb.from('mkt_collabs').insert({ influencer_id: curInf.id, kind: $('cb-kind').value, fee_eur: Number($('cb-fee').value || 0), product_value_eur: Number($('cb-val').value || 0), campaign_id: $('cb-camp').value || null,
        deliverables: $('cb-del').value.trim() || null, post_url: $('cb-url').value.trim() || null, posted_on: $('cb-url').value.trim() ? romeDate(new Date()) : null, disclosure_ok: $('cb-disc').checked, agreed_on: romeDate(new Date()) }));
      if ($('cb-url').value.trim()) PERM.changed(await sb.from('mkt_influencers').update({ status: curInf.discount_code ? 'affiliate' : 'posted' }).eq('id', curInf.id).select('id'));
      await openInf(curInf.id); loadInf();
    }, 'Collaborazione registrata');
  });

  // ---------- FOTO E VIDEO ----------
  function renderLib() {
    $('lib').innerHTML = assets.length ? assets.map(a => `<div class="it" data-id="${a.id}">${a.kind === 'video' ? `<video src="${esc(a.url)}" controls muted preload="metadata"></video>` : `<img src="${esc(a.url)}" loading="lazy" alt="">`}
      <div class="m"><div>${a.ai_generated ? '<span class="pill generating">IA</span> ' : ''}<span class="status">${esc(a.source)}</span> ${esc((a.tags || []).join(', '))}</div>
      <label><input type="checkbox" data-k="consent_ok" ${a.consent_ok ? 'checked' : ''}> consenso</label><label><input type="checkbox" data-k="hygiene_ok" ${a.hygiene_ok ? 'checked' : ''}> igiene ok</label></div></div>`).join('')
      : '<div class="empty">Nessun file. Le clip migliori della prova del 29/09 (pasta filata nella tramoggia, taglio della cagliata, bocconcini nell\'acqua, ricotta nelle fuscelle) sono un ottimo inizio, dopo il controllo di volti e igiene.</div>';
    $('lib').querySelectorAll('input[data-k]').forEach(i => i.onchange = () => run(async () => { const id = i.closest('.it').dataset.id; PERM.changed(await sb.from('mkt_assets').update({ [i.dataset.k]: i.checked }).eq('id', id).select('id')); const a = assets.find(x => x.id === id); a[i.dataset.k] = i.checked; }, 'Aggiornato'));
  }
  $('up-go').onclick = () => run(async () => {
    const files = [...$('up-file').files]; if (!files.length) throw new Error('Scegli uno o più file');
    const tags = $('up-tags').value.split(/[,\s]+/).map(s => s.trim()).filter(Boolean);
    for (const f of files) {
      const path = `${romeDate(new Date())}/${Date.now()}-${f.name.replace(/[^\w.\-]+/g, '_')}`;
      const { error } = await sb.storage.from('marketing').upload(path, f, { contentType: f.type, upsert: false }); if (error) throw error;
      const url = sb.storage.from('marketing').getPublicUrl(path).data.publicUrl;
      must(await sb.from('mkt_assets').insert({ kind: f.type.startsWith('video') ? 'video' : 'photo', url, source: 'caseificio', consent_ok: $('up-consent').checked, hygiene_ok: $('up-hyg').checked, tags }));
    }
    $('up-file').value = ''; const a = await sb.from('mkt_assets').select('*').order('created_at', { ascending: false }); assets = a.data || []; renderLib();
  }, 'Caricato');

  // ---------- CAMPAGNE ----------
  function renderCampaigns() {
    const year = Number(settings['opex.marketing_eur_year']?.value || 15900);
    const planned = campaigns.filter(c => c.status !== 'cancelled').reduce((s, c) => s + Number(c.budget_eur || 0), 0);
    const spent = campaigns.reduce((s, c) => s + Number(c.spent_eur || 0), 0);
    $('camp-budget').innerHTML = `Budget marketing annuo (benchmark): <b>${eur(year)}</b> · assegnato alle campagne: <b>${eur(planned)}</b> · speso: <b>${eur(spent)}</b> · libero: <b class="${year - planned < 0 ? 'ko' : 'ok'}">${eur(year - planned)}</b>. Predis.ai (~€450/anno) e Shopify Collabs (gratuito, 2,9% sulle commissioni pagate) sono costi fissi a parte.`;
    const tbl = document.createElement('table'); tbl.className = 'rec';
    tbl.innerHTML = '<tr><th>Campagna</th><th>Dal</th><th>Al</th><th>Codice</th><th class="num">Budget €</th><th class="num">Speso €</th><th>Stato</th><th></th></tr>';
    campaigns.forEach(c => {
      const tr = document.createElement('tr');
      tr.innerHTML = `<td><input type="text" data-k="name" value="${esc(c.name)}" style="font-weight:600"><br><small class="status">${esc(c.goal || '')}</small>${c.notes ? `<br><small class="status">${esc(c.notes)}</small>` : ''}</td>
        <td><input type="date" data-k="starts_on" value="${c.starts_on || ''}"></td><td><input type="date" data-k="ends_on" value="${c.ends_on || ''}"></td>
        <td><input type="text" data-k="discount_code" value="${esc(c.discount_code || '')}" style="min-width:110px"></td>
        <td class="num"><input type="number" data-k="budget_eur" value="${c.budget_eur}"></td><td class="num"><input type="number" data-k="spent_eur" value="${c.spent_eur}"></td>
        <td><select data-k="status">${['planned', 'active', 'done', 'cancelled'].map(s => `<option value="${s}" ${s === c.status ? 'selected' : ''}>${STATUS_IT[s] || s}</option>`).join('')}</select></td><td></td>`;
      const b = document.createElement('button'); b.className = 'btn sm'; b.textContent = 'Salva';
      b.onclick = () => run(async () => { const v = {}; tr.querySelectorAll('[data-k]').forEach(i => v[i.dataset.k] = i.type === 'number' ? Number(i.value || 0) : i.type === 'date' ? (i.value || null) : (i.value.trim() ? (i.dataset.k === 'discount_code' ? i.value.trim().toUpperCase() : i.value.trim()) : null)); PERM.changed(await sb.from('mkt_campaigns').update(v).eq('id', c.id).select('id')); Object.assign(c, v); renderCampaigns(); }, 'Campagna salvata');
      tr.lastElementChild.append(b); tbl.append(tr);
    });
    $('camp-table').innerHTML = ''; $('camp-table').append(tbl);
    if (!campaigns.length) $('camp-table').innerHTML = '<div class="empty">Nessuna campagna: crea il piano di lancio dal Calendario o aggiungine una.</div>';
  }
  $('camp-new').onclick = () => run(async () => { const c = must(await sb.from('mkt_campaigns').insert({ name: 'Nuova campagna', status: 'planned' }).select().single()); campaigns.push(c); renderCampaigns(); }, 'Campagna aggiunta: dai un nome, date e budget');

  init();
})();
