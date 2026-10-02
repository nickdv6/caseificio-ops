/* La Perla configuration page, separate from the operational console: one tab per category (Azienda, Produzione, Vendite, Utenze e reflui, Lavoro e benchmark, Macchine e scadenze, Bot, Account). Settings rows are routed to cards by key prefix; data_type text|number. Owner/partner only. */
(() => {
  const CFG = window.FABULA_CONFIG;
  const sb = supabase.createClient(CFG.supabaseUrl, CFG.supabaseKey, { db: { schema: 'fabula' } });
  const $ = id => document.getElementById(id);
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
    const { data } = await sb.from('staff').select('*').eq('auth_user_id', session.user.id).maybeSingle();
    staff = data || { id: null, full_name: session.user.email, role: 'owner' };
    $('who').textContent = staff.full_name; $('btn-logout').hidden = false; $('btn-refresh').hidden = false;
    if (!canEdit()) { show('denied'); return; }
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
  async function load() { loadSettings(); loadBots(); }

  // ---------- helpers ----------
  const GROUPS = { milk: 'Piano latte', sell: 'Vendere prima', opex: 'Benchmark OpEx (€/anno)', price: 'Prezzi', farm: 'Masseria (latte)', energy: 'Energia', labor: 'Lavoro' };
  const canEdit = () => ['owner', 'partner'].includes(staff.role);
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
    const { data: runs } = await sb.from('agent_runs').select('agent, started_at, status, summary, error').order('started_at', { ascending: false }).limit(60);
    const last = {}; (runs || []).forEach(r => { if (!last[r.agent]) last[r.agent] = r; });
    const fmtT = s => new Date(s).toLocaleString('it-IT', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Rome' });
    $('bots').innerHTML = '<table class="nw2"><tr><th>Bot</th><th>Quando (ora italiana)</th><th>Legge</th><th>Ultima esecuzione</th><th>Esito</th></tr>' + BOTS.map(([a, n, w, f]) => {
      const r = last[a];
      return `<tr><td><b>${n}</b><br><small class="status">${a}</small></td><td>${w}</td><td><code>${f}</code></td><td>${r ? fmtT(r.started_at) : '<span class="status">mai</span>'}</td><td class="${r ? (r.status === 'ok' ? 'ok' : 'ko') : ''}">${r ? esc(r.status) + (r.summary ? ' · <span class="status">' + esc(r.summary) + '</span>' : '') + (r.error ? ' · ' + esc(r.error) : '') : ''}</td></tr>`; }).join('') + '</table>';
    $('runs').innerHTML = (runs && runs.length) ? '<table>' + runs.slice(0, 40).map(r => `<tr><td>${esc(r.agent)}</td><td class="status">${fmtT(r.started_at)}</td><td class="${r.status === 'ok' ? 'ok' : 'ko'}">${esc(r.status)}</td><td class="status">${esc(r.summary || r.error || '')}</td></tr>`).join('') + '</table>' : '<div class="empty">Nessuna esecuzione registrata.</div>';
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
      if (!canEdit()) { const n = document.createElement('div'); n.className = 'hint'; n.textContent = 'Solo titolare e partner possono modificare.'; box.append(n); }
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
