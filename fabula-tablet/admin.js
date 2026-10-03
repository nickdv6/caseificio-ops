/* La Perla configuration page, separate from the operational console: one tab per category (Azienda, Produzione, Vendite, Utenze e reflui, Lavoro e benchmark, Macchine e scadenze, Bot, Account). Settings rows are routed to cards by key prefix; data_type text|number. Owner/partner only. */
(() => {
  const CFG = window.FABULA_CONFIG;
  const sb = supabase.createClient(CFG.supabaseUrl, CFG.supabaseKey, { db: { schema: 'fabula' } });
  const $ = id => document.getElementById(id);
  // Mouse wheel over a focused number field must never change its value (keyboard only).
  document.addEventListener('wheel', e => { const a = document.activeElement; if (a && a.tagName === 'INPUT' && a.type === 'number' && e.target === a) e.preventDefault(); }, { passive: false });
  let staff = null;
  const show = v => document.querySelectorAll('.view').forEach(e => e.classList.toggle('active', e.id === 'v-' + v));
  const toast = (m, cls = '') => { const t = $('toast'); t.textContent = m; t.className = 'toast ' + cls; t.style.display = 'block'; setTimeout(() => t.style.display = 'none', 2800); };
  const eur = n => n == null ? '–' : new Intl.NumberFormat('it-IT', { style: 'currency', currency: 'EUR', maximumFractionDigits: 0 }).format(n);
  const num = (n, d = 1) => n == null ? '–' : Number(n).toLocaleString('it-IT', { maximumFractionDigits: d, minimumFractionDigits: d });
  const dateIt = s => new Date(s + 'T12:00:00').toLocaleDateString('it-IT', { weekday: 'long', day: 'numeric', month: 'long' });
  const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));


  // ---------- auth (owner / partner only) ----------
  async function init() {
    const { data: { session } } = await sb.auth.getSession();
    if (!session) return show('login');
    const P = await PERM.load(sb);
    if (!P || !P.staff_id) return PERM.deny(sb, PERM.notLinked(session.user.email));
    if (!PERM.page('admin')) return PERM.deny(sb, PERM.notForProfile());
    const { data } = await sb.from('staff').select('*').eq('id', P.staff_id).maybeSingle();
    staff = { ...(data || { id: P.staff_id, full_name: P.full_name }), app_role: P.role, role_name: P.role_name };
    $('who').textContent = staff.full_name; $('btn-logout').hidden = false; $('btn-refresh').hidden = false;
    $('who').textContent = `${staff.full_name} · ${staff.role_name}`;
    show('main'); load(); showTab((location.hash || '#azienda').slice(1).replace(/[^a-z]/g, '') || 'azienda', false);
  }
  $('btn-login').onclick = async () => { const { error } = await sb.auth.signInWithPassword({ email: $('email').value, password: $('pw').value }); if (error) return toast(error.message, 'err'); init(); };
  $('pw').addEventListener('keydown', e => { if (e.key === 'Enter') $('btn-login').click(); });
  $('btn-logout').onclick = async () => { await sb.auth.signOut(); location.reload(); };
  $('btn-refresh').onclick = () => load();
  function showTab(name, push = true) {
    document.querySelectorAll('.tab').forEach(t => t.setAttribute('aria-selected', t.dataset.tab === name));
    document.querySelectorAll('.pane').forEach(p => p.classList.toggle('active', p.id === 'p-' + name));
    if (push) { try { history.replaceState(null, '', '#' + name); } catch {} }
  }
  $('tabs').onclick = e => { const t = e.target.closest('.tab'); if (t) showTab(t.dataset.tab); };
  async function load() { loadSettings(); loadBots(); loadBotFeed(); loadVariantMap(); loadAudit(); loadUsers(); }
  // ---------- Bot dashboard: every bot notification (bot_messages) ----------
  const SEV = { alert: 'Allarme', warn: 'Attenzione', info: 'Info' };
  const fmtR = s => new Date(s).toLocaleString('it-IT', { weekday: 'short', day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Rome' });
  let bdFilter = 'unread', bdAgent = null, bdLimit = 50, bdNames = {}, bdNick = {};
  // v0.46 display-only nicknames (Zio/Zia) from bot_nicknames; agent keys never change
  async function loadNicknames() { const { data } = await sb.from('bot_nicknames').select('agent, nickname, title_it, avatar_url'); (data || []).forEach(n => { bdNick[n.agent] = n; }); }
  // avatar slot: image when bot_nicknames.avatar_url is set, otherwise a dashed circle with the initial
  const botAvatar = agent => { const n = bdNick[agent]; if (n && n.avatar_url) return `<div class="bav img" aria-hidden="true"><img src="${esc(n.avatar_url)}" alt="" loading="lazy"></div>`;
    const w = String(n ? n.nickname : agent).replace(/^(zio|zia)\s+/i, '').trim(); return `<div class="bav" aria-hidden="true">${esc((w[0] || '?').toUpperCase())}</div>`; };
  const botLabel = (agent, base) => { const n = bdNick[agent]; return n ? `${n.nickname} · ${base || n.title_it}` : (base || agent); };
  // Bot dashboard redesign (03/10): status summary on top, bots grouped by status (da sistemare → da controllare → in ordine → disattivati),
  // one card per bot (Zio Vito and Zio Nino are now two cards), plain-language times ("3 ore fa", "domani 06:05").
  const SYS = { bot_watchdog: { agents: ['bot_watchdog', 'avvisi'], role: 'Allarme bot e avvisi console', sched: 'ogni ora · :50, 06:50–21:50 lun–sab', times: Array.from({ length: 16 }, (_, i) => String(6 + i).padStart(2, '0') + ':50'), wd: [1, 2, 3, 4, 5, 6] },
                bot_heartbeat: { agents: ['bot_heartbeat'], role: 'Battito bot (controllo orario)', sched: 'ogni ora · :25', times: Array.from({ length: 24 }, (_, i) => String(i).padStart(2, '0') + ':25'), wd: [1, 2, 3, 4, 5, 6, 7] } };
  const DOW = ['dom', 'lun', 'mar', 'mer', 'gio', 'ven', 'sab'];
  const romeNow = () => { const p = Object.fromEntries(new Intl.DateTimeFormat('en-GB', { timeZone: 'Europe/Rome', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false }).formatToParts(new Date()).map(x => [x.type, x.value]));
    return { y: +p.year, mo: +p.month, d: +p.day, hm: `${p.hour === '24' ? '00' : p.hour}:${p.minute}` }; };
  const nextRun = (times, wd, md) => { if (!times || !times.length) return null; const n = romeNow(), ts = times.map(t => t.slice(0, 5)).sort();
    for (let k = 0; k < 40; k++) { const dt = new Date(Date.UTC(n.y, n.mo - 1, n.d + k)), iso = dt.getUTCDay() || 7;
      if (md ? dt.getUTCDate() !== md : wd && wd.length && !wd.includes(iso)) continue;
      const t = ts.find(x => k > 0 || x > n.hm); if (!t) continue;
      const day = k === 0 ? 'oggi' : k === 1 ? 'domani' : `${DOW[dt.getUTCDay()]} ${String(dt.getUTCDate()).padStart(2, '0')}/${String(dt.getUTCMonth() + 1).padStart(2, '0')}`;
      return { label: `${day} ${t}`, key: k * 1440 + (+t.slice(0, 2)) * 60 + (+t.slice(3)) }; }
    return null; };
  const schedTxt = (times, wd, md) => { const t = (times || []).map(x => x.slice(0, 5)).join(', ');
    const days = md ? `il ${md} del mese` : !wd || wd.length >= 7 ? 'ogni giorno' : wd.join() === '1,2,3,4,5,6' ? 'lun–sab' : wd.map(d => DOW[d % 7]).join(', ');
    return `${days} · ${t}`; };
  const ago = s => { const m = Math.round((Date.now() - new Date(s)) / 60000); if (m < 1) return 'adesso'; if (m < 60) return `${m} min fa`;
    const h = Math.round(m / 60); if (h < 24) return h === 1 ? '1 ora fa' : `${h} ore fa`; const d = Math.round(h / 24); return d === 1 ? 'ieri' : `${d} giorni fa`; };
  // one readable line: no leading icons, no long English translations in brackets, nothing after an arrow (file paths)
  const cleanTxt = s => String(s || '').replace(/^[\s⛔⚠✅ℹ️•·\-–—:]+/u, '').replace(/\s*\([^()]{30,}\)/g, '').split(/\s(?:→|->)\s?/)[0].replace(/\s+/g, ' ').trim();
  const ST = { al: ['Allarme', 'Da sistemare'], wn: ['Da controllare', 'Da controllare'], ok: ['In ordine', 'In ordine'], new: ['Mai eseguito', 'In attesa della prima esecuzione'], off: ['Disattivato', 'Disattivati'] };
  // ---------- notification text helpers: Italian only by default, light markdown, no repeated "bot · date" header ----------
  let bdEn = false, bdRole = {};
  // English detection for the bots' "Italiano (English)" habit: brackets with an English word and no Italian word are the translation
  const EN_W = new Set(('the is are was were and to of no nothing not with from for by on at this that today yet all check checks it its be been has have an as or so please will would should any only stay stays '
    + 'evening temperature sanitation meter reading logged missing overdue tasks since thermometer production declaration proposed est cost confirmed orders order demand output mismatch approving approve reject '
    + 'customer customers suppliers supplier rename placeholder names recorded scans working day off offline fix first connected booked include them phones tap item record shows list red yield available '
    + 'averages sales yesterday week weeks average close history hand assumed measured last same waste system ran errors error new updated read deactivated wholesale adopted next sync what when where how').split(' '));
  const IT_W = new Set('il lo la le gli di del della dei delle che è e per non nessun nessuna nessuno sono da con oggi ancora alla al nel nella una un più già prima resta restano dal sul o senza'.split(' '));
  const wordsOf = s => String(s).toLowerCase().match(/[a-zà-ù']+/g) || [];
  const isEn = s => { let en = 0, it = 0; wordsOf(s).forEach(x => { if (EN_W.has(x)) en++; if (IT_W.has(x)) it++; }); return en >= 2 && en > it * 1.5; };
  const isEnBracket = s => { let en = 0, it = 0; wordsOf(s).forEach(x => { if (EN_W.has(x)) en++; if (IT_W.has(x)) it++; }); return it === 0 ? en >= 1 : en >= 2 && en > it * 1.5; };
  const dropEn = t => {
    let s = String(t || '').replace(/\r/g, '');
    s = s.replace(/\s*\((?:[^()]|\([^()]*\))*\)/g, m => m.includes('\n') && isEn(m) ? '' : m);   // multi-line translation in brackets
    return s.split('\n').filter(l => !/^\s*(EN|English)\s*[—:–-]/i.test(l))
      .map(l => l.replace(/^\s*IT\s*[—:–-]\s*/, '').replace(/\s*\(((?:[^()]|\([^()]*\))*)\)/g, (m, inner) => { const sl = inner.split(' / '); if (sl.length === 2 && isEnBracket(sl[1]) && !isEnBracket(sl[0])) return ` (${sl[0]})`; return isEnBracket(inner) ? '' : m; }))
      .filter(l => !(l.trim() && isEn(l))).join('\n');
  };
  const MONTHS = /(\d{1,2}[\/ ]\d{0,2}|gennaio|febbraio|marzo|aprile|maggio|giugno|luglio|agosto|settembre|ottobre|novembre|dicembre)/i;
  const mdLite = t => {
    const lines = String(t || '').split('\n').map(l => l.trimEnd());
    while (lines.length && !lines[0].trim()) lines.shift();
    if (lines.length && lines[0].length < 90 && / · /.test(lines[0]) && MONTHS.test(lines[0]) && !/^\s*[-•*]\s/.test(lines[0])) lines.shift();
    const inl = s => esc(s).replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
    let html = '', list = false;
    for (const l of lines) {
      const li = l.match(/^\s*(?:[-•*]|\d+[.)])\s+(.*)$/);
      if (li) { if (!list) { html += '<ul>'; list = true; } html += `<li>${inl(li[1])}</li>`; continue; }
      if (list) { html += '</ul>'; list = false; }
      if (!l.trim()) continue;
      const q = l.match(/^\s*>\s?(.*)$/);
      html += q ? `<blockquote>${inl(q[1])}</blockquote>` : `<p>${inl(l)}</p>`;
    }
    return list ? html + '</ul>' : html;
  };
  const plainTxt = h => String(h).replace(/<[^>]+>/g, ' ').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&amp;/g, '&').replace(/\s+/g, ' ').trim();
  const romeDay = s => new Date(s).toLocaleDateString('sv-SE', { timeZone: 'Europe/Rome' });
  const hmRome = s => new Date(s).toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Rome' });
  const dayLabel = d => { if (d === romeDay(Date.now())) return 'Oggi'; if (d === romeDay(Date.now() - 864e5)) return 'Ieri';
    return new Date(d + 'T12:00:00').toLocaleDateString('it-IT', { weekday: 'long', day: 'numeric', month: 'long' }); };
  async function loadBotFeed() {
    const [{ data: bots }, cnt, { data: sysMsgs }] = await Promise.all([
      sb.from('v_bot_dashboard').select('*').order('name_it'),
      sb.from('bot_messages').select('severity', { count: 'exact', head: false }).is('read_at', null).limit(1000),
      sb.from('bot_messages').select('agent, title, severity, body, created_at, read_at').in('agent', ['bot_watchdog', 'bot_heartbeat', 'avvisi']).order('created_at', { ascending: false }).limit(300),
      loadNicknames()]);
    const unread = cnt.data || [], nU = unread.length, nA = unread.filter(x => x.severity === 'alert').length;
    const tb = $('n-bots'); tb.textContent = nA || nU; tb.classList.toggle('on', nU > 0); tb.classList.toggle('al', nA > 0);
    (bots || []).forEach(b => { bdNames[b.agent] = b.display_name || botLabel(b.agent, b.name_it); bdRole[b.agent] = b.name_it; });
    Object.entries(SYS).forEach(([a, x]) => { bdRole[a] = bdNick[a] ? bdNick[a].title_it : x.role; });
    Object.keys(SYS).forEach(a => { bdNames[a] = botLabel(a, bdNick[a] ? bdNick[a].title_it : a); });
    // one item per card
    const items = (bots || []).map(b => {
      const st = !b.active ? 'off' : (b.last_status === 'error' || b.unread_alerts > 0 || b.last_severity === 'alert') ? 'al' : b.last_severity === 'warn' ? 'wn' : !b.last_run_at ? 'new' : 'ok';
      const raw = (b.last_title || '').trim(), generic = !raw || [b.name_it, b.display_name].some(x => x && (raw === x || raw.startsWith(x + ' · ')));
      return { agent: b.agent, nick: bdNick[b.agent] ? bdNick[b.agent].nickname : b.name_it, role: b.name_it, st, err: b.active && b.last_status === 'error',
        sched: schedTxt(b.due_times, b.weekdays, b.month_day), next: b.active ? nextRun(b.due_times, b.weekdays, b.month_day) : null,
        last: b.last_run_at, line: cleanTxt(b.last_status === 'error' ? (b.last_summary || 'Ultima esecuzione fallita') : generic ? (b.last_summary || raw) : raw),
        unread: b.unread || 0, unreadAl: b.unread_alerts || 0, active: b.active };
    });
    Object.entries(SYS).forEach(([a, s]) => {
      const ms = (sysMsgs || []).filter(m => s.agents.includes(m.agent)), m = ms[0], un = ms.filter(x => !x.read_at);
      const st = un.some(x => x.severity === 'alert') ? 'al' : un.some(x => x.severity === 'warn') ? 'wn' : 'ok';
      items.push({ agent: a, nick: bdNick[a] ? bdNick[a].nickname : a, role: s.role, st, sched: s.sched, next: nextRun(s.times, s.wd), last: m ? m.created_at : null, sys: true,
        line: un.length ? cleanTxt(un[0].title) : 'Nessun allarme: tutti i bot sono regolari', unread: un.length, unreadAl: un.filter(x => x.severity === 'alert').length, active: true });
    });
    // summary strip
    const c = k => items.filter(i => i.st === k).length;
    const nx = items.filter(i => i.next && !i.sys).sort((x, y) => x.next.key - y.next.key)[0];
    $('bd-sum').innerHTML = `
      <div class="sm s-al${c('al') ? '' : ' zero'}"><b>${c('al')}</b><span>da sistemare</span></div>
      <div class="sm s-wn${c('wn') ? '' : ' zero'}"><b>${c('wn')}</b><span>da controllare</span></div>
      <div class="sm s-ok"><b>${c('ok')}</b><span>in ordine</span></div>
      <div class="sm"><b>${nU}</b><span>notifiche da leggere</span></div>
      ${nx ? `<div class="sm nx">${botAvatar(nx.agent)}<div><span>Prossimo bot</span><b>${esc(nx.nick)}</b><span>${esc(nx.role)} · ${esc(nx.next.label)}</span></div></div>` : ''}`;
    // cards grouped by status, each group ordered by next run
    // card: name, job, one-line latest news, then when it last ran and when it runs next. Group heading + coloured edge carry the status.
    const when = i => i.active ? [i.last ? `Ultima: ${ago(i.last)}` : i.sys ? 'Nessun avviso finora' : 'Non ha ancora girato', i.next ? `Prossima: ${i.next.label}` : '']
      : ['Disattivato' + (i.last ? ` · ha girato ${ago(i.last)}` : '')];
    const card = i => `<div class="botc s-${i.st}${bdAgent === i.agent ? ' sel' : ''}" data-a="${esc(i.agent)}" role="button" tabindex="0" aria-pressed="${bdAgent === i.agent}" title="${esc(i.role)} · ${esc(i.sched)}">${botAvatar(i.agent)}
        <div class="bi"><div class="hd"><span class="nm">${esc(i.nick)}</span>${i.err ? '<span class="pill s-al">Errore</span>' : ''}</div>
        <div class="ti">${esc(i.role)}</div>
        <div class="bl">${esc(i.line || (i.st === 'new' ? 'Nessuna notizia: parte alla prossima esecuzione' : '—'))}</div>
        <div class="ft">${when(i).filter(Boolean).map(t => `<span>${esc(t)}</span>`).join('')}${i.unread ? `<span class="u${i.unreadAl ? ' al' : ''}">${i.unread} ${i.unread === 1 ? 'nuova' : 'nuove'}</span>` : ''}</div></div></div>`;
    const bb = $('bd-bots');
    bb.innerHTML = ['al', 'wn', 'ok', 'new', 'off'].map(k => { const g = items.filter(i => i.st === k).sort((x, y) => (x.next ? x.next.key : 1e9) - (y.next ? y.next.key : 1e9));
      return g.length ? `<div class="bd-grp s-${k}"><h4>${ST[k][1]} <span>${g.length}</span></h4><div class="bd-bots">${g.map(card).join('')}</div></div>` : ''; }).join('');
    const pick = el => { bdAgent = bdAgent === el.dataset.a ? null : el.dataset.a; bdLimit = 50; loadBotFeed(); if (bdAgent) $('bd-feed-card').scrollIntoView({ behavior: 'smooth', block: 'start' }); };
    bb.querySelectorAll('.botc').forEach(el => { el.onclick = () => pick(el); el.onkeydown = e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); pick(el); } }; });
    $('bd-bot').textContent = bdAgent ? 'Solo: ' + (bdNames[bdAgent] || bdAgent) : '';
    let q = sb.from('bot_messages').select('*').order('created_at', { ascending: false }).limit(bdLimit + 1);
    if (bdFilter === 'unread') q = q.is('read_at', null);
    if (bdFilter === 'alert') q = q.eq('severity', 'alert');
    if (bdAgent) q = q.in('agent', SYS[bdAgent] ? SYS[bdAgent].agents : [bdAgent]);
    const { data: msgs, error } = await q;
    const feed = $('bd-feed');
    if (error) { feed.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    $('bd-more').hidden = (msgs || []).length <= bdLimit;
    const rows = (msgs || []).slice(0, bdLimit);
    if (!rows.length) { feed.innerHTML = `<div class="empty">${bdFilter === 'unread' ? 'Nessuna notifica da leggere.' : 'Nessuna notifica.'}</div>`; return; }
    // grouped by day; same bot + same title on the same day = one entry ("3 volte"); Italian only unless "Mostra inglese"
    const items2 = [], byKey = {};
    rows.forEach(m => {
      const day = romeDay(m.created_at), key = `${day}|${m.agent}|${m.title}`;
      if (byKey[key]) { const it = byKey[key]; it.n++; if (!m.read_at) it.unreadIds.push(m.id); return; }
      const it = byKey[key] = { m, day, n: 1, unreadIds: m.read_at ? [] : [m.id] }; items2.push(it);
    });
    let lastDay = null;
    feed.innerHTML = items2.map(({ m, day, n, unreadIds }) => {
      const a = m.agent === 'avvisi' ? 'bot_watchdog' : m.agent, nk = bdNick[a];
      const role = m.agent === 'avvisi' ? 'Avvisi console' : (bdRole[a] || (nk ? nk.title_it : a));
      const generic = !m.title || [role, nk && nk.title_it, bdNames[a]].some(x => x && (m.title === x || m.title.startsWith(x + ' · ')));
      let body = mdLite(bdEn ? (m.body || '') : dropEn(m.body || '')), title = m.title || '';
      if (!bdEn) title = dropEn(title);
      if (generic) { const f = body.match(/^<(p|li)>(.*?)<\/\1>/) || body.match(/<(p|li)>(.*?)<\/\1>/);
        if (f) { title = plainTxt(f[2]); if (f[1] === 'p' && body.startsWith(f[0])) body = body.slice(f[0].length); } }
      title = title.replace(/^Oggi\s*[—–-]\s*/, '');
      const head = day !== lastDay ? `<div class="bd-day">${esc(dayLabel(day))}</div>` : ''; lastDay = day;
      const sv = m.severity === 'alert' ? '<span class="sv">Allarme</span>' : m.severity === 'warn' ? '<span class="sv">Da controllare</span>' : '';
      return `${head}<div class="msg ${esc(m.severity)}${unreadIds.length ? '' : ' read'}" data-ids="${unreadIds.join(',')}">${botAvatar(a)}<div class="mb">
        <div class="hd"><span class="who"><b>${esc(nk ? nk.nickname : role)}</b> · ${esc(role)}</span><span class="tm">${hmRome(m.created_at)}${n > 1 ? ` · ${n} volte` : ''}</span></div>
        <div class="t">${sv}${esc(title)}</div>${body ? `<div class="b">${body}</div>` : ''}
        <div class="ac"><button class="more" data-x="more" hidden>Mostra tutto</button>${unreadIds.length ? '<button class="rd" data-x="read">✓ Segna come letta</button>' : ''}</div></div></div>`;
    }).join('');
    feed.querySelectorAll('.msg .b').forEach(b => { if (b.scrollHeight > b.clientHeight + 4) { b.classList.add('cut'); b.closest('.mb').querySelector('[data-x=more]').hidden = false; } });
    feed.querySelectorAll('[data-x=more]').forEach(btn => btn.onclick = () => { const bd = btn.closest('.mb').querySelector('.b'); bd.classList.toggle('open'); btn.textContent = bd.classList.contains('open') ? 'Riduci' : 'Mostra tutto'; });
    feed.querySelectorAll('[data-x=read]').forEach(btn => btn.onclick = async () => { const ids = btn.closest('.msg').dataset.ids.split(',').filter(Boolean).map(Number); const { error } = await sb.rpc('mark_bot_messages_read', { p_ids: ids }); if (error) return toast(error.message, 'err'); loadBotFeed(); });
  }
  document.querySelectorAll('.bd-bar .chip[data-f]').forEach(c => c.onclick = () => { bdFilter = c.dataset.f; bdLimit = 50; document.querySelectorAll('.bd-bar .chip[data-f]').forEach(x => x.setAttribute('aria-pressed', x === c)); loadBotFeed(); });
  $('bd-en').onclick = () => { bdEn = !bdEn; $('bd-en').setAttribute('aria-pressed', bdEn); loadBotFeed(); };
  $('bd-more').onclick = () => { bdLimit += 50; loadBotFeed(); };
  $('bd-readall').onclick = async () => {
    const { data: ids } = await (bdAgent ? sb.from('bot_messages').select('id').is('read_at', null).in('agent', SYS[bdAgent] ? SYS[bdAgent].agents : [bdAgent]) : sb.from('bot_messages').select('id').is('read_at', null));
    if (!ids || !ids.length) return toast('Niente da segnare');
    const { data, error } = await sb.rpc('mark_bot_messages_read', { p_ids: ids.map(x => x.id) }); if (error) return toast(error.message, 'err');
    toast(`${data} notifiche segnate come lette`); loadBotFeed();
  };
  setInterval(() => { if (document.visibilityState === 'visible' && PERM.data && PERM.page('admin')) loadBotFeed(); }, 60000);
  // ---------- Utenti e ruoli ----------
  const LVL = ['—', 'vede', 'registra', 'gestisce'];
  const JOBS = [['owner', 'titolare'], ['partner', 'socio'], ['casaro', 'casaro'], ['operaio', 'operaio'], ['commesso', 'commesso'], ['consulente', 'consulente']];
  async function callUsers(body) {
    const { data, error } = await sb.functions.invoke('invite-user', { body });
    if (error) { let m = error.message; try { const j = await error.context.json(); m = j.error || m; } catch {} throw new Error(m); }
    if (data && data.error) throw new Error(data.error); return data;
  }
  async function loadUsers() {
    const admin = PERM.isAdmin();
    $('usr-invite').hidden = !admin; $('usr-ro').hidden = admin;
    const [{ data: people, error }, { data: roles }, { data: areas }, { data: perms }] = await Promise.all([
      sb.from('staff').select('id, full_name, email, role, app_role, auth_user_id, active, badge_code').order('active', { ascending: false }).order('full_name'),
      sb.from('app_roles').select('*').order('sort'), sb.from('app_areas').select('*').neq('code', 'comune').order('sort'), sb.from('role_permissions').select('*')]);
    const box = $('users'); if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    const roleOpts = sel => (roles || []).map(r => `<option value="${r.code}"${r.code === sel ? ' selected' : ''}>${esc(r.name_it)}</option>`).join('');
    $('inv-role').innerHTML = roleOpts('produzione');
    const tbl = document.createElement('table');
    tbl.innerHTML = '<tr><th>Persona</th><th>Email</th><th>Profilo</th><th>Mansione</th><th>Accesso</th><th></th></tr>';
    (people || []).forEach(p => {
      const tr = document.createElement('tr'); if (!p.active) tr.style.opacity = '.55';
      const login = !p.active ? 'disattivato' : p.auth_user_id ? 'collegato' : p.email ? 'invito da inviare' : 'senza email';
      tr.innerHTML = `<td><b>${esc(p.full_name)}</b><br><small>${esc(p.badge_code || '')}</small></td>`;
      const em = document.createElement('input'); em.type = 'email'; em.value = p.email || ''; em.disabled = !admin; em.style.width = '200px';
      const rs = document.createElement('select'); rs.innerHTML = roleOpts(p.app_role); rs.disabled = !admin;
      const js = document.createElement('select'); js.innerHTML = JOBS.map(([v, l]) => `<option value="${v}"${v === p.role ? ' selected' : ''}>${l}</option>`).join(''); js.disabled = !admin;
      [em, rs, js].forEach(x => { const td = document.createElement('td'); td.append(x); tr.append(td); });
      const tdl = document.createElement('td'); tdl.innerHTML = `<small>${login}</small>`; tr.append(tdl);
      const tda = document.createElement('td'); tda.style.whiteSpace = 'nowrap';
      if (admin) {
        const b = (label, cls, fn) => { const x = document.createElement('button'); x.className = 'btn sm ' + cls; x.textContent = label; x.style.marginRight = '4px';
          x.onclick = async () => { x.disabled = true; try { await fn(); } catch (err) { toast(err.message || String(err), 'err'); } finally { x.disabled = false; } }; tda.append(x); };
        b('Salva', '', async () => { const { error } = await sb.from('staff').update({ email: em.value.trim() || null, app_role: rs.value, role: js.value }).eq('id', p.id); if (error) throw error; toast('Salvato'); loadUsers(); });
        if (p.active && p.email && p.id !== staff.id) b(p.auth_user_id ? 'Reinvia link' : 'Invia invito', 'sec', async () => { const r = await callUsers({ action: p.auth_user_id ? 'resend' : 'invite', staff_id: p.id, email: p.email, full_name: p.full_name, app_role: p.app_role, job_role: p.role }); toast(r.sent === 'reset' ? 'Email per reimpostare la password inviata' : 'Invito inviato'); loadUsers(); });
        if (p.id !== staff.id) b(p.active ? 'Disattiva' : 'Riattiva', p.active ? 'warn' : 'sec', async () => { await callUsers({ action: p.active ? 'deactivate' : 'reactivate', staff_id: p.id }); toast(p.active ? 'Disattivato: non può più entrare' : 'Riattivato'); loadUsers(); });
      }
      tr.append(tda); tbl.append(tr);
    });
    box.innerHTML = ''; box.append(tbl);
    // matrix
    const mbox = $('roles-matrix'); const lv = {}; (perms || []).forEach(x => { lv[x.role_code + '|' + x.area] = x.level; });
    const mt = document.createElement('table');
    mt.innerHTML = '<tr><th>Profilo</th>' + (areas || []).map(a => `<th title="${esc(a.description_it || '')}">${esc(a.name_it)}</th>`).join('') + '</tr>';
    const edits = [];
    (roles || []).forEach(r => {
      const tr = document.createElement('tr'); tr.innerHTML = `<td><b>${esc(r.name_it)}</b>${r.can_manage_users ? ' <small class="status">utenti</small>' : ''}<br><small>${esc(r.description_it || '')}</small></td>`;
      (areas || []).forEach(a => {
        const td = document.createElement('td'); const v = lv[r.code + '|' + a.code] ?? 0;
        if (admin && r.code !== 'titolare') { const s = document.createElement('select'); s.innerHTML = LVL.map((l, i) => `<option value="${i}"${i === v ? ' selected' : ''}>${l}</option>`).join(''); s.dataset.orig = v; edits.push({ role: r.code, area: a.code, s }); td.append(s); }
        else td.innerHTML = `<small>${LVL[v]}</small>`;
        tr.append(td);
      });
      mt.append(tr);
    });
    mbox.innerHTML = ''; mbox.append(mt);
    $('roles-save').hidden = !admin;
    $('roles-save').onclick = async () => {
      const ch = edits.filter(e => String(e.s.value) !== String(e.s.dataset.orig)).map(e => ({ role_code: e.role, area: e.area, level: Number(e.s.value) }));
      if (!ch.length) return toast('Nessuna modifica');
      const { error } = await sb.from('role_permissions').upsert(ch, { onConflict: 'role_code,area' }); if (error) return toast(error.message, 'err');
      toast(`Permessi aggiornati (${ch.length})`); loadUsers();
    };
  }
  $('inv-go').onclick = async () => {
    const b = $('inv-go'); b.disabled = true;
    try { const r = await callUsers({ action: 'invite', full_name: $('inv-name').value, email: $('inv-email').value, app_role: $('inv-role').value });
      toast(r.invited ? 'Invito inviato: la persona riceve una email per scegliere la password' : 'Account esistente collegato'); $('inv-name').value = ''; $('inv-email').value = ''; loadUsers();
    } catch (err) { toast(err.message || String(err), 'err'); } finally { b.disabled = false; }
  };
  const AUD_T = { settings: 'Parametri', approvals: 'Approvazioni', recipes: 'Ricette', standing_orders: 'Ordini fissi', staff: 'Personale', products: 'Prodotti', equipment: 'Macchine',
    compliance_deadlines: 'Scadenze', haccp_control_points: 'Punti HACCP', process_steps: 'Processo', supplier_products: 'Condizioni fornitori', supplier_prices: 'Listini',
    farm_supply: 'Latte Masseria', shopify_variant_map: 'Prodotti Shopify', training_courses: 'Corsi', rota_entries: 'Turni' };
  const AUD_A = { insert: 'aggiunto', update: 'modificato', delete: 'eliminato' };
  const short = v => { if (v == null) return '∅'; const s = typeof v === 'object' ? JSON.stringify(v) : String(v); return s.length > 60 ? s.slice(0, 57) + '…' : s; };
  async function loadAudit() {
    const sel = $('aud-table'); if (sel.options.length === 1) Object.entries(AUD_T).forEach(([k, l]) => sel.add(new Option(l, k)));
    const box = $('audit'); box.innerHTML = '<div class="status">Carico…</div>';
    let q = sb.from('audit_log').select('*').order('at', { ascending: false }).limit(150);
    if (sel.value) q = q.eq('table_name', sel.value);
    const { data, error } = await q;
    if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    const needle = $('aud-q').value.trim().toLowerCase();
    const rows = (data || []).filter(r => !needle || JSON.stringify(r).toLowerCase().includes(needle));
    if (!rows.length) { box.innerHTML = '<div class="empty">Nessuna modifica registrata.</div>'; return; }
    const label = r => { const d = r.new_data || r.old_data || {}; return r.table_name === 'settings' ? r.row_key : d.summary || d.full_name || d.name || d.name_it || d.code || d.subject_it || d.po_number || d.work_date || (r.row_key || '').slice(0, 8); };
    box.innerHTML = `<table><tr><th>Quando</th><th>Chi</th><th>Dove</th><th>Cosa</th><th>Modifica</th></tr>${rows.map(r => {
      const diff = r.action === 'update' ? (r.changed || []).map(c => `<b>${esc(c)}</b>: ${esc(short(r.old_data?.[c]))} → ${esc(short(r.new_data?.[c]))}`).join('<br>') : esc(AUD_A[r.action]);
      return `<tr><td class="nw">${new Date(r.at).toLocaleString('it-IT', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' })}</td><td>${esc(r.actor)}</td><td>${esc(AUD_T[r.table_name] || r.table_name)}</td><td>${esc(label(r))}</td><td><small>${diff}</small></td></tr>`; }).join('')}</table>`;
  }
  $('aud-go').onclick = () => loadAudit(); $('aud-table').onchange = () => loadAudit();
  $('aud-q').addEventListener('keydown', e => { if (e.key === 'Enter') loadAudit(); });

  // ---------- helpers ----------
  const GROUPS = { milk: 'Piano latte', sell: 'Vendere prima', opex: 'Benchmark OpEx (€/anno)', price: 'Prezzi', shopify: 'Shopify', farm: 'Masseria (latte)', energy: 'Energia', labor: 'Lavoro' };
  const canEdit = () => PERM.can('sistema', 3);
  const saveBtn = (fn) => { const b = document.createElement('button'); b.className = 'btn sm'; b.textContent = 'Salva'; b.onclick = async () => { b.disabled = true; try { await fn(); toast('Salvato'); } catch (err) { toast(err.message || String(err), 'err'); } finally { b.disabled = false; } }; return b; };
  const upd = async (table, match, row) => { const { error } = await sb.from(table).update(row).match(match); if (error) throw error; };
  const dOrNull = v => v || null, nOrNull = v => v === '' || v == null ? null : Number(v);
  const fmtD = s => s ? s.slice(8, 10) + '/' + s.slice(5, 7) + '/' + s.slice(0, 4) : '—';
  const dueCls = s => { if (!s) return ''; const d = (new Date(s) - new Date(new Date().toISOString().slice(0, 10))) / 864e5; return d < 0 ? 'ko' : d <= 30 ? 'ko' : ''; };

  // ---------- bots: schedule register + last runs ----------
  const BOTS = [
    ['daily_brief', 'Brief giornaliero', 'lun–sab 12:47', 'daily_brief()'],
    ['procurement', 'Acquisti', 'lun–sab 12:20', 'propose_purchase_orders()'],
    ['sell_down', 'Vendere prima', 'lun–sab 13:23', 'sell_down_signals()'],
    ['wholesale_orders', 'Ordini ingrosso', 'lun–sab 18:20', 'confirm_standing_orders()'],
    ['milk_planning', 'Piano latte', 'lun–sab 18:52', 'plan_milk()'],
    ['haccp_nudge', 'Chiusura serata', 'lun–sab 19:02', 'haccp_evening_status()'],
    ['ops_health', 'Controllo sistema', 'lun–sab 20:36', 'ops_health_check()'],
    ['weekly_brief', 'Brief settimanale', 'lunedì 13:08', 'weekly_brief()'],
    ['compliance_calendar', 'Manutenzioni e scadenze', 'martedì 13:17', 'compliance_calendar()'],
    ['monthly_review', 'Revisione mensile', '1° del mese 13:41', 'monthly_review()']];
  async function loadBots() {
    await loadNicknames();
    const { data: runs } = await sb.from('agent_runs').select('agent, started_at, status, summary, error').order('started_at', { ascending: false }).limit(60);
    const last = {}; (runs || []).forEach(r => { if (!last[r.agent]) last[r.agent] = r; });
    const fmtT = s => new Date(s).toLocaleString('it-IT', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Rome' });
    $('bots').innerHTML = '<table class="nw2"><tr><th>Bot</th><th>Quando (ora italiana)</th><th>Legge</th><th>Ultima esecuzione</th><th>Esito</th></tr>' + BOTS.map(([a, n, w, f]) => {
      const r = last[a];
      return `<tr><td><b>${esc(botLabel(a, n))}</b><br><small class="status">${a}</small></td><td>${w}</td><td><code>${f}</code></td><td>${r ? fmtT(r.started_at) : '<span class="status">mai</span>'}</td><td class="${r ? (r.status === 'ok' ? 'ok' : 'ko') : ''}">${r ? esc(r.status) + (r.summary ? ' · <span class="status">' + esc(r.summary) + '</span>' : '') + (r.error ? ' · ' + esc(r.error) : '') : ''}</td></tr>`; }).join('') + '</table>';
    $('runs').innerHTML = (runs && runs.length) ? '<table>' + runs.slice(0, 40).map(r => `<tr><td>${esc(botLabel(r.agent))}<br><small class="status">${esc(r.agent)}</small></td><td class="status">${fmtT(r.started_at)}</td><td class="${r.status === 'ok' ? 'ok' : 'ko'}">${esc(r.status)}</td><td class="status">${esc(r.summary || r.error || '')}</td></tr>`).join('') + '</table>' : '<div class="empty">Nessuna esecuzione registrata.</div>';
  }

  // ---------- Shopify variant → stock product map ----------
  async function loadVariantMap() {
    const box = $('variant-map'); box.innerHTML = '';
    const [{ data: rows, error }, { data: prods }] = await Promise.all([sb.from('v_shopify_variant_map').select('*'), sb.from('products').select('id, sku, name, unit').eq('kind', 'finished_good').eq('active', true).order('name')]);
    if (error) { box.innerHTML = `<div class="empty">${esc(error.message)}</div>`; return; }
    if (!rows || !rows.length) { box.innerHTML = '<div class="empty">Nessuna variante ancora vista: compare dopo il primo ordine o la prima sincronizzazione.</div>'; return; }
    const tbl = document.createElement('table'); tbl.className = 'rec';
    tbl.innerHTML = '<tr><th>Variante Shopify</th><th>Tipo</th><th>Prodotto magazzino</th><th class="num">kg / pezzo</th><th></th></tr>';
    rows.forEach(r => {
      const tr = document.createElement('tr'); if (!r.product_sku) tr.style.background = 'var(--tile)';
      tr.innerHTML = `<td><b>${esc(r.label)}</b>${r.unmapped_lines ? `<br><small class="ko">${r.unmapped_lines} righe d'ordine in attesa</small>` : ''}${r.auto_mapped ? '<br><small class="status">collegata automaticamente</small>' : ''}</td><td class="status">${esc(r.product_type || '')}</td>`;
      const sel = document.createElement('select'); sel.innerHTML = '<option value="">— non scarica il magazzino —</option>' + (prods || []).map(p => `<option value="${p.id}" ${p.sku === r.product_sku ? 'selected' : ''}>${esc(p.name)} (${esc(p.unit)})</option>`).join('');
      const kg = document.createElement('input'); kg.type = 'number'; kg.step = '0.05'; kg.min = '0'; kg.value = r.kg_per_unit ?? ''; kg.placeholder = 'kg';
      const td3 = document.createElement('td'); td3.append(sel); const td4 = document.createElement('td'); td4.className = 'num'; td4.append(kg);
      const td5 = document.createElement('td'); td5.append(saveBtn(async () => {
        const pid = sel.value || null, k = pid ? Number(kg.value) : null; if (pid && !(k > 0)) throw new Error('Inserisci i kg per pezzo');
        await upd('shopify_variant_map', { variant_id: r.variant_id }, { product_id: pid, kg_per_unit: k, auto_mapped: false, updated_at: new Date().toISOString() }); loadVariantMap();
      }));
      tr.append(td3, td4, td5); tbl.append(tr);
    });
    box.append(tbl);
  }

  // ---------- settings, machines, deadlines ----------
  async function loadSettings() {
    const [s, e, d] = await Promise.all([
      sb.from('settings').select('*').order('key'),
      sb.from('v_equipment_schedule').select('*'),
      sb.from('compliance_deadlines').select('*').is('done_on', null).order('due_on', { nullsFirst: false })]);
    renderParams(s.data || []); renderEquipment(e.data || []); renderDeadlines(d.data || []);
  }
  function renderParams(rows) {
    document.querySelectorAll('.params').forEach(box => {
      box.innerHTML = '';
      const groups = box.dataset.groups.split(',');
      const mine = rows.filter(r => groups.includes(r.key.split('.')[0])).sort((a, b) => (a.sort ?? 100) - (b.sort ?? 100) || a.key.localeCompare(b.key));
      if (!mine.length) { box.innerHTML = '<div class="empty">Nessun parametro.</div>'; return; }
      if (!canEdit()) { const n = document.createElement('div'); n.className = 'hint'; n.textContent = 'Sola lettura: modifica chi ha il livello "gestisce" in Sistema (titolare, socio).'; box.append(n); }
      mine.forEach(r => {
        const isText = r.data_type === 'text';
        const row = document.createElement('div'); row.className = 'set-row' + (isText ? ' text' : '');
        row.innerHTML = `<div class="lbl">${esc(r.description || r.key)}<small>${esc(r.key)}</small></div>`;
        const right = document.createElement('div'); right.className = 'row'; right.style.marginTop = '0';
        const inp = document.createElement('input'); inp.type = 'text'; inp.value = r.value; inp.disabled = !canEdit(); inp.oninput = () => row.classList.add('dirty');
        if (isText) { inp.className = 'wide'; inp.placeholder = '—'; } else inp.inputMode = 'decimal';
        right.append(inp);
        if (canEdit()) right.append(saveBtn(async () => {
          let v = inp.value.trim();
          if (!isText) { if (v === '' || isNaN(Number(v.replace(',', '.')))) throw new Error('Inserisci un numero'); v = String(Number(v.replace(',', '.'))); }
          await upd('settings', { key: r.key }, { value: v }); row.classList.remove('dirty');
          if (r.key.startsWith('company.')) BRAND.set({ [r.key]: v });   // header and tab title follow at once
        }));
        row.append(right); box.append(row);
      });
    });
  }
  function renderEquipment(rows) {
    const box = $('set-equipment'); box.innerHTML = '';
    rows.filter(r => r.active).forEach(r => {
      const c = document.createElement('details'); c.className = 'eq';
      const nc = r.next_calibration_on, nm = r.next_maintenance_on, unset = !nc && !nm;
      c.innerHTML = `<summary class="h"><b>${esc(r.name)} <small class="status">${esc(r.code)}</small></b><span class="status">${unset ? '<span class="ko">date da impostare</span>' : `taratura <span class="${dueCls(nc)}">${fmtD(nc)}</span> · manutenzione <span class="${dueCls(nm)}">${fmtD(nm)}</span>`}</span></summary>
        <div class="f">
          <div><label>Ultima taratura</label><input type="date" data-k="last_calibrated_on" value="${r.last_calibrated_on || ''}"></div>
          <div><label>Ogni (giorni)</label><input type="number" data-k="calibration_interval_days" value="${r.calibration_interval_days ?? ''}" placeholder="—"></div>
          <div><label>Ultima manutenzione</label><input type="date" data-k="last_maintenance_on" value="${r.last_maintenance_on || ''}"></div>
          <div><label>Ogni (giorni)</label><input type="number" data-k="maintenance_interval_days" value="${r.maintenance_interval_days ?? ''}" placeholder="—"></div>
          <div style="grid-column:1/-1"><label>Tecnico / contatto</label><input type="text" data-k="technician_contact" value="${esc(r.technician_contact || '')}" placeholder="nome, telefono"></div>
        </div>`;
      const row = document.createElement('div'); row.className = 'row';
      row.append(saveBtn(async () => {
        const v = {}; c.querySelectorAll('input[data-k]').forEach(i => { v[i.dataset.k] = i.type === 'date' ? dOrNull(i.value) : i.type === 'number' ? nOrNull(i.value) : (i.value.trim() || null); });
        await upd('equipment', { id: r.id }, v); loadSettings();
      }));
      c.append(row); box.append(c);
    });
  }
  function renderDeadlines(rows) {
    const box = $('set-deadlines'); box.innerHTML = '';
    if (!rows.length) box.innerHTML = '<div class="empty">Nessuna scadenza aperta.</div>';
    rows.forEach(r => {
      const c = document.createElement('details'); c.className = 'eq';
      c.innerHTML = `<summary class="h"><b>${esc(r.subject_it)}</b><span class="status ${dueCls(r.due_on) || (r.due_on ? '' : 'ko')}">${r.due_on ? 'scade ' + fmtD(r.due_on) : 'data da impostare'}</span></summary>
        <div class="f">
          <div><label>Scadenza</label><input type="date" data-k="due_on" value="${r.due_on || ''}"></div>
          <div><label>Ogni (giorni)</label><input type="number" data-k="interval_days" value="${r.interval_days ?? ''}" placeholder="una tantum"></div>
          <div><label>Responsabile</label><input type="text" data-k="responsible" value="${esc(r.responsible || '')}"></div>
          <div><label>Fornitore / contatto</label><input type="text" data-k="contact" value="${esc(r.contact || '')}"></div>
          <div style="grid-column:1/-1"><label>Note</label><input type="text" data-k="notes" value="${esc(r.notes || '')}"></div>
        </div>`;
      const row = document.createElement('div'); row.className = 'row';
      row.append(saveBtn(async () => { const v = {}; c.querySelectorAll('input[data-k]').forEach(i => { v[i.dataset.k] = i.type === 'date' ? dOrNull(i.value) : i.type === 'number' ? nOrNull(i.value) : (i.value.trim() || null); }); await upd('compliance_deadlines', { id: r.id }, v); loadSettings(); }));
      const done = document.createElement('button'); done.className = 'btn sm sec'; done.textContent = 'Fatto oggi';
      done.onclick = async () => { done.disabled = true; const { error } = await sb.rpc('complete_deadline', { p_id: r.id }); if (error) { toast(error.message, 'err'); done.disabled = false; return; } toast(r.interval_days ? 'Chiusa · prossima aperta' : 'Chiusa'); loadSettings(); };
      row.append(done); c.append(row); box.append(c);
    });
  }
  $('dl-add').onclick = async () => {
    const subj = $('dl-new-subject').value.trim(); if (!subj) return toast('Scrivi la descrizione', 'err');
    const { error } = await sb.from('compliance_deadlines').insert({ kind: 'other', subject_it: subj, due_on: dOrNull($('dl-new-due').value), interval_days: nOrNull($('dl-new-int').value), responsible: 'partner' });
    if (error) return toast(error.message, 'err');
    $('dl-new-subject').value = ''; $('dl-new-due').value = ''; $('dl-new-int').value = ''; toast('Aggiunta'); loadSettings();
  };
  $('pw-save').onclick = async () => {
    const pw = $('pw-new').value; if (pw.length < 8) return toast('Minimo 8 caratteri', 'err');
    $('pw-save').disabled = true; const { error } = await sb.auth.updateUser({ password: pw }); $('pw-save').disabled = false;
    if (error) return toast(error.message, 'err'); $('pw-new').value = ''; toast('Password cambiata');
  };

  init();
})();
