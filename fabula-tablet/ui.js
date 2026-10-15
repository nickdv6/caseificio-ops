/* Shared shell for console.html and admin.html (v0.51): Supabase client, formatting helpers, login, one header with the
   page links + bot bell + user menu, lazy tabs with #hash, unsaved-change guard. Each page script calls
   UI.boot({ page: 'console', onReady, onRefresh }) and keeps only its own logic.
   Unsaved changes: any input typed inside a row/card that has a .save button marks that scope .dirty — the button lights up,
   Enter saves it, and leaving the page asks first. A successful save clears it. */
(() => {
  const CFG = window.FABULA_CONFIG;
  const sb = supabase.createClient(CFG.supabaseUrl, CFG.supabaseKey, { db: { schema: 'fabula' } });
  const $ = id => document.getElementById(id);
  const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const eur = n => n == null ? '–' : new Intl.NumberFormat('it-IT', { style: 'currency', currency: 'EUR', maximumFractionDigits: 0 }).format(n);
  const num = (n, d = 1) => n == null || n === '' || isNaN(Number(n)) ? '–' : Number(n).toLocaleString('it-IT', { maximumFractionDigits: d, minimumFractionDigits: d });
  const fmtD = s => s ? esc(String(s).slice(8, 10) + '/' + String(s).slice(5, 7) + '/' + String(s).slice(0, 4)) : '—';
  const dateIt = s => new Date(s + 'T12:00:00').toLocaleDateString('it-IT', { weekday: 'long', day: 'numeric', month: 'long' });
  // today / n days ago as YYYY-MM-DD in Agropoli time (the business day), not UTC
  const romeISO = (d = new Date()) => d.toLocaleDateString('sv-SE', { timeZone: 'Europe/Rome' });
  const daysAgo = n => romeISO(new Date(Date.now() - n * 864e5));
  // v0.60: Italian numbers — "1.300" is one thousand three hundred, "1,3" and "1.3" are 1.3, "1.300,5" works; anything else is an error, never NULL/0
  const parseIt = v => {
    let t = String(v).trim().replace(/\s|€/g, '');
    if (t.includes(',') && t.includes('.')) t = t.replace(/\./g, '').replace(',', '.');
    else if (t.includes(',')) t = t.replace(',', '.');
    else if (/^-?[1-9]\d{0,2}(\.\d{3})+$/.test(t)) t = t.replace(/\./g, '');   // v0.93 (audit C-01): "0.044" is a decimal, not 44
    return /^-?(\d+\.?\d*|\.\d+)$/.test(t) ? Number(t) : NaN;
  };
  // v0.93 (audit C-01/B-17): a new value 10× bigger or smaller than the old one is almost always a comma/dot slip ("1.325" read as 1325)
  const jump = (was, now) => { const a = Number(was), b = Number(now); if (!a || !b || !Number.isFinite(a) || !Number.isFinite(b)) return 0; const r = b / a; return r >= 10 || r <= 0.1 ? r : 0; };
  const nOrNull = v => { if (v === '' || v == null) return null; if (typeof v === 'number') return v; const n = parseIt(v); if (!Number.isFinite(n)) throw new Error(`Numero non valido: "${v}"`); return n; };
  const dOrNull = v => v || null;
  // v0.60: phone → wa.me number. +39 / 0039 kept once; Italian mobiles (3…, including 390–393…) and landlines (0…) get 39
  const waNumber = p => { let d = String(p || '').replace(/[^\d+]/g, ''); if (d.startsWith('+')) d = d.slice(1); else if (d.startsWith('00')) d = d.slice(2); else if (/^(3\d{8,9}|0\d{5,10})$/.test(d)) d = '39' + d; return d.replace(/\D/g, ''); };

  let toastT = null;
  const toast = (m, cls = '') => { const t = $('toast'); if (!t) return; t.textContent = m; t.className = 'toast ' + cls; t.style.display = 'block'; clearTimeout(toastT); toastT = setTimeout(() => t.style.display = 'none', cls === 'err' ? 5000 : 2800); };
  const badge = (id, n) => { const el = typeof id === 'string' ? $(id) : id; if (!el) return; el.textContent = n || ''; el.classList.toggle('on', n > 0); };
  // v0.56: 0 rows = not saved. v1.03 (audit C-05): it asks back only the columns it matched on — «select=*» would include columns
  // a login may not read (parties.portal_token) and the whole save would be refused
  const upd = async (table, match, row) => PERM.changed(await sb.from(table).update(row).match(match).select(Object.keys(match).join(',')));

  // ---------- unsaved changes ----------
  const SCOPE = 'tr, .set-row, .eq, [data-scope]';
  const scopeOf = el => { let s = el.closest(SCOPE); while (s && !s.querySelector('.save')) s = s.parentElement && s.parentElement.closest(SCOPE); return s; };
  const clean = el => { const s = el && (el.matches(SCOPE) ? el : el.closest(SCOPE)); if (s) s.classList.remove('dirty'); };
  document.addEventListener('input', e => { const t = e.target; if (!t.matches('input, select, textarea') || t.closest('.nodirty')) return; const s = scopeOf(t); if (s) s.classList.add('dirty'); });
  document.addEventListener('change', e => { const t = e.target; if (!t.matches('select, input[type=checkbox], input[type=date]') || t.closest('.nodirty')) return; const s = scopeOf(t); if (s) s.classList.add('dirty'); });
  document.addEventListener('keydown', e => {
    if (e.key !== 'Enter' || !e.target.matches('input') || e.target.closest('.nodirty, .login') || e.target.dataset.noenter) return;   // v0.98 (B-14): a recipe dose is never saved by Enter
    const s = scopeOf(e.target); const b = s && s.classList.contains('dirty') && s.querySelector('.save');
    if (b && !b.disabled) { e.preventDefault(); b.click(); }
  });
  window.addEventListener('beforeunload', e => { if (document.querySelector('.dirty')) { e.preventDefault(); e.returnValue = ''; } });
  const unsaved = () => document.querySelectorAll('.dirty').length;
  // Mouse wheel over a focused number field must never change its value (keyboard only).
  document.addEventListener('wheel', e => { const a = document.activeElement; if (a && a.tagName === 'INPUT' && a.type === 'number' && e.target === a) e.preventDefault(); }, { passive: false });

  // Salva button: disables while saving, toasts the result, clears the dirty mark of its row/card on success
  // v0.60: saving one row used to re-render the whole list and wipe edits typed in other rows. Pages call UI.after(reload):
  // while other rows are still unsaved the reload waits, and runs once the last of them is saved.
  let savingScope = null, deferred = false; const pending = new Set();
  const otherDirty = () => [...document.querySelectorAll('.dirty')].filter(s => !savingScope || (s !== savingScope && !s.contains(savingScope) && !savingScope.contains(s)));
  const after = fn => { if (otherDirty().length) { pending.add(fn); deferred = true; return; } fn(); };
  const runPending = () => { if (!pending.size || document.querySelector('.dirty')) return; const fns = [...pending]; pending.clear(); fns.forEach(f => { try { Promise.resolve(f()).catch(e => toast(e.message || String(e), 'err')); } catch (e) { toast(e.message || String(e), 'err'); } }); };
  const saveBtn = (fn, label = 'Salva') => {
    const b = document.createElement('button'); b.type = 'button'; b.className = 'btn sm save'; b.textContent = label;
    b.onclick = async () => {
      b.disabled = true; savingScope = scopeOf(b) || b.closest(SCOPE); deferred = false;
      try { await fn(); clean(b); toast(deferred ? 'Salvato · l\'elenco si aggiorna quando salvi anche le altre righe modificate' : 'Salvato'); runPending(); }
      catch (err) { if (!(err && err.silent)) toast(err.message || String(err), 'err'); }   // v0.98: silent = the person chose not to save
      finally { savingScope = null; b.disabled = false; }
    };
    return b;
  };
  // run an async action from a button with the same disable/toast/error handling
  const act = async (btn, fn, ok) => { if (btn) btn.disabled = true; try { const r = await fn(); if (ok && r !== false) toast(typeof ok === 'function' ? ok(r) : ok); return r; } catch (err) { if (!(err && err.silent)) toast(err.message || String(err), 'err'); } finally { if (btn) btn.disabled = false; } };   // v0.99: silent = the person said no

  // ---------- hints on/off (per device) ----------
  const HINTS = 'fabula_hints';
  const hintsOff = () => { try { return localStorage.getItem(HINTS) === 'off'; } catch { return false; } };
  document.documentElement.classList.toggle('nohints', hintsOff());

  // ---------- header: page links, bot bell, user menu ----------
  const PAGES = [['console', 'console.html', 'Console'], ['haccp', 'haccp.html', 'Autocontrollo'], ['marketing', 'marketing.html', 'Marketing'], ['vendite', 'vendite.html', 'Vendite'], ['ingrosso', 'ingrosso.html', 'Ingrosso'], ['admin', 'admin.html', 'Configurazione']];
  let current = null, refreshFn = null, staff = null;
  function renderNav() {
    const nav = $('nav'); if (!nav) return;
    const links = PAGES.filter(([p]) => p === current || PERM.page(p)).map(([p, href, label]) =>
      `<a href="${href}" class="pg${p === current ? ' on' : ''}"${p === current ? ' aria-current="page"' : ''}>${label}</a>`).join('');
    // v1.05 (audit E-09): every office profile has the bell — with Configurazione it opens the bots' feed, otherwise the open alarms of
    // its own areas in Console → Oggi («Avvisi aperti»)
    const bell = PERM.page('admin') ? `<a href="admin.html#bots" class="bell" id="bell" title="Notifiche dei bot">Bot <span class="n" id="bell-n"></span></a>`
      : PERM.page('console') ? `<a href="console.html#oggi" class="bell" id="bell" title="Allarmi aperti delle tue aree">Avvisi <span class="n" id="bell-n"></span></a>` : '';
    nav.innerHTML = `<div class="pages">${links}</div><div class="tools">${bell}
      ${refreshFn ? '<button class="btn sec sm" id="ui-refresh" title="Ricarica i dati di questa scheda" aria-label="Aggiorna">⟳<span class="lbl"> Aggiorna</span></button>' : ''}
      <details class="me" id="me"><summary>${esc(staff.full_name)} <small>${esc(staff.role_name || '')}</small></summary><div class="menu">
        <button type="button" id="ui-hints">${hintsOff() ? 'Mostra le spiegazioni' : 'Nascondi le spiegazioni'}</button>
        ${PERM.page('admin') ? '<a href="admin.html#account">Cambia password</a>' : ''}
        <button type="button" id="ui-out">Esci</button></div></details></div>`;
    if (refreshFn) $('ui-refresh').onclick = () => act($('ui-refresh'), refreshFn, 'Dati aggiornati');
    $('ui-hints').onclick = () => { const off = !hintsOff(); try { localStorage.setItem(HINTS, off ? 'off' : 'on'); } catch {} document.documentElement.classList.toggle('nohints', off); $('ui-hints').textContent = off ? 'Mostra le spiegazioni' : 'Nascondi le spiegazioni'; $('me').open = false; };
    $('ui-out').onclick = async () => { await sb.auth.signOut(); location.reload(); };
    document.addEventListener('click', e => { const m = $('me'); if (m && m.open && !m.contains(e.target)) m.open = false; });
    if (bell) { bellCount(); setInterval(() => { if (document.visibilityState === 'visible') bellCount(); }, 120000); }
  }
  // v1.00 (E-04): the open alarms first (the same for everyone until someone marks them «Risolto»), then what *I* have not read
  async function bellCount() {
    const el = $('bell-n'); if (!el) return;
    const { data, error } = await sb.rpc('bot_bell');
    if (error || !data) return;
    const al = Number(data.alerts) || 0, n = Number(data.unread) || 0;
    el.textContent = al ? `${al} ${al === 1 ? 'allarme' : 'allarmi'}${n ? ` · ${n}` : ''}` : n ? String(n) : '';
    el.classList.toggle('on', al + n > 0); $('bell').classList.toggle('al', al > 0);
    $('bell').title = [al ? `${al} ${al === 1 ? 'allarme aperto' : 'allarmi aperti'}` : '', n ? `${n} ${n === 1 ? 'notifica' : 'notifiche'} da leggere` : ''].filter(Boolean).join(', ') || 'Nessuna notifica da leggere';
  }

  // ---------- login + access ----------
  const show = v => document.querySelectorAll('.view').forEach(e => e.classList.toggle('active', e.id === 'v-' + v));
  function loginView() {
    if ($('v-login')) return;
    const s = document.createElement('section'); s.className = 'view login'; s.id = 'v-login';
    s.innerHTML = `<label for="email">Email</label><input id="email" type="email" autocomplete="username">
      <label for="pw">Password</label><input id="pw" type="password" autocomplete="current-password"><button class="btn" id="btn-login">Entra</button>`;
    $('v-main').before(s);
  }
  async function boot({ page, onReady, onRefresh }) {
    current = page; refreshFn = onRefresh || null; loginView();
    $('btn-login').onclick = async () => { const b = $('btn-login'); b.disabled = true; const { error } = await sb.auth.signInWithPassword({ email: $('email').value.trim(), password: $('pw').value }); b.disabled = false; if (error) return toast(error.message === 'Invalid login credentials' ? 'Email o password non corretti' : error.message, 'err'); boot({ page, onReady, onRefresh }); };
    $('pw').onkeydown = e => { if (e.key === 'Enter') $('btn-login').click(); };
    PERM.forgot(sb, toast);
    const { data: { session } } = await sb.auth.getSession();
    if (!session) { show('login'); $('email').focus(); return; }
    const P = await PERM.load(sb);
    if (!P || !P.staff_id) return PERM.deny(sb, PERM.notLinked(session.user.email));
    if (!PERM.page(page)) return PERM.deny(sb, PERM.notForProfile());
    const { data } = await sb.from('staff').select('*').eq('id', P.staff_id).maybeSingle();
    staff = { ...(data || { id: P.staff_id, full_name: P.full_name }), app_role: P.role, role_name: P.role_name };
    renderNav(); show('main');
    await onReady(staff);
  }

  // ---------- tabs: lazy (each pane loads the first time it is shown), #hash remembered, old hashes redirected ----------
  // v1.00 (E-08): a hash can carry parameters after the tab, for the links in the bots' messages: #oggi&appr=<id>, #bots&fermi
  const hashTab = (h = location.hash) => String(h || '').replace(/^#/, '').split(/[&=]/)[0].replace(/[^a-z]/g, '');
  const hashParams = (h = location.hash) => { const o = {};
    String(h || '').replace(/^#/, '').split('&').slice(1).forEach(x => { if (!x) return; const i = x.indexOf('=');
      try { o[i < 0 ? x : x.slice(0, i)] = i < 0 ? '' : decodeURIComponent(x.slice(i + 1)); } catch { /* malformed: ignored */ } });
    return o; };
  function tabs({ def, loaders = {}, alias = {}, onShow, onHash }) {
    const loaded = {};
    const visible = n => { const t = document.querySelector(`.tab[data-tab="${n}"]`); return t && !t.hidden; };
    const api = {
      current: def,
      show(name, push = true) {
        name = alias[name] || name; if (!visible(name)) name = def;
        api.current = name;
        document.querySelectorAll('.tab').forEach(t => t.setAttribute('aria-selected', t.dataset.tab === name));
        document.querySelectorAll('.pane').forEach(p => p.classList.toggle('active', p.id === 'p-' + name));
        if (push) { try { history.replaceState(null, '', '#' + name); } catch {} }
        if (loaders[name] && !loaded[name]) { loaded[name] = true; Promise.resolve(loaders[name]()).catch(err => toast(err.message || String(err), 'err')); }
        if (onShow) onShow(name);
      },
      // forget what was loaded; reload the pane on screen now, the others when next opened
      async reload() { Object.keys(loaded).forEach(k => delete loaded[k]); if (loaders[api.current]) { loaded[api.current] = true; await loaders[api.current](); } },
      isLoaded: n => !!loaded[n],
      start() {
        $('tabs').onclick = e => { const t = e.target.closest('.tab'); if (t) api.show(t.dataset.tab); };
        api.show(hashTab() || def, false);
        if (onHash) onHash(hashParams());
        // v0.60: links like admin.html#bots / #account clicked on the same page now switch the tab (v1.00: and pass their parameters)
        window.addEventListener('hashchange', () => { const n = hashTab(); if (n && n !== api.current) api.show(n, false); if (onHash) onHash(hashParams()); });
      }
    };
    return api;
  }

  window.UI = { sb, $, esc, eur, num, fmtD, dateIt, romeISO, daysAgo, nOrNull, parseIt, jump, after, waNumber, dOrNull, toast, badge, upd, saveBtn, act, clean, unsaved, boot, tabs, hashTab, hashParams, bellCount, get staff() { return staff; } };
})();
