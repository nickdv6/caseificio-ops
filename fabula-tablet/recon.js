/* Incassi (v0.82): reads bank statement and Shopify payments CSV files in the browser and turns them into the rows that
   fabula.bank_import() / fabula.payments_import() expect. Pure functions, no network: also loaded by tools/go-live/drill/recon-test.
   Italian bank exports differ (separator, preamble lines before the header, "Dare/Avere" or one signed column, 1.234,56 numbers,
   dd/mm/yyyy dates), so the header is found by its names and every column can be corrected by hand in the console. */
(function (root) {
  const strip = s => String(s == null ? '' : s).replace(/^﻿/, '');
  const norm = h => strip(h).toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^a-z0-9]+/g, ' ').trim();

  // ---------- CSV ----------
  function detectSep(text) {
    const lines = text.split(/\r?\n/).filter(l => l.trim()).slice(0, 40);
    let best = ';', bestScore = -1;
    for (const sep of [';', ',', '\t', '|']) {
      const counts = lines.map(l => { let n = 0, q = false; for (const ch of l) { if (ch === '"') q = !q; else if (ch === sep && !q) n++; } return n; });
      const max = Math.max(0, ...counts), rows = counts.filter(c => c === max && c > 0).length;
      const score = max > 0 ? rows * 10 + max : -1;
      if (score > bestScore) { bestScore = score; best = sep; }
    }
    return best;
  }
  function parseCSV(text, sep) {
    text = strip(text); sep = sep || detectSep(text);
    const rows = []; let row = [], cell = '', q = false, line = 1, start = 1;
    for (let i = 0; i < text.length; i++) {
      const ch = text[i];
      if (q) {
        if (ch === '"') { if (text[i + 1] === '"') { cell += '"'; i++; } else q = false; }
        else { cell += ch; if (ch === '\n') line++; }
      } else if (ch === '"') q = true;
      else if (ch === sep) { row.push(cell.trim()); cell = ''; }
      else if (ch === '\n' || ch === '\r') {
        if (ch === '\r' && text[i + 1] === '\n') i++;
        row.push(cell.trim()); cell = '';
        if (row.some(c => c !== '')) { row.line = start; rows.push(row); }
        row = []; line++; start = line;
      } else cell += ch;
    }
    row.push(cell.trim()); if (row.some(c => c !== '')) { row.line = start; rows.push(row); }
    return { sep, rows };
  }

  // ---------- values ----------
  function parseDate(s) {
    const t = strip(s).trim(); let m;
    if ((m = t.match(/^(\d{4})-(\d{2})-(\d{2})/))) return valid(+m[1], +m[2], +m[3]);
    if ((m = t.match(/^(\d{1,2})[\/.\-](\d{1,2})[\/.\-](\d{2,4})\b/))) { let y = +m[3]; if (y < 100) y += 2000; return valid(y, +m[2], +m[1]); }
    if ((m = t.match(/^(\d{4})(\d{2})(\d{2})$/))) return valid(+m[1], +m[2], +m[3]);
    return null;
  }
  function valid(y, mo, d) {
    if (!(y > 1990 && y < 2100 && mo >= 1 && mo <= 12 && d >= 1 && d <= 31)) return null;
    const dt = new Date(Date.UTC(y, mo - 1, d)); if (dt.getUTCMonth() !== mo - 1) return null;
    return `${y}-${String(mo).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
  }
  // date + time for payment rows; times without a zone are Agropoli time
  function parseDateTime(s) {
    const t = strip(s).trim(); const day = parseDate(t); if (!day) return null;
    if (/^\d{4}-\d{2}-\d{2}[ T]\d{1,2}:\d{2}/.test(t)) return /([+-]\d{2}:?\d{2}|Z|UTC)\s*$/.test(t) ? t.replace(' UTC', 'Z') : t + ' Europe/Rome';
    const m = t.match(/\b(\d{1,2}):(\d{2})(?::(\d{2}))?\b/);
    return day + ' ' + (m ? `${m[1].padStart(2, '0')}:${m[2]}:${m[3] || '00'}` : '12:00:00') + ' Europe/Rome';
  }
  // which decimal mark a file uses: look at how values end (",50" vs ".50")
  function decimalMark(values) {
    let c = 0, d = 0;
    for (const v of values) { const t = strip(v).trim(); if (/,\d{1,2}\)?-?$/.test(t)) c++; else if (/\.\d{1,2}\)?-?$/.test(t)) d++; }
    return c >= d ? ',' : '.';
  }
  function parseAmount(s, mark) {
    let t = strip(s).trim().replace(/\s|€|EUR/gi, ''); if (!t) return null;
    let neg = false;
    if (/^\(.*\)$/.test(t)) { neg = true; t = t.slice(1, -1); }
    if (t.endsWith('-')) { neg = true; t = t.slice(0, -1); }
    if (t.startsWith('-')) { neg = !neg; t = t.slice(1); } else if (t.startsWith('+')) t = t.slice(1);
    if (t.includes(',') && t.includes('.')) t = t.lastIndexOf(',') > t.lastIndexOf('.') ? t.replace(/\./g, '').replace(',', '.') : t.replace(/,/g, '');
    else if (t.includes(',')) t = (mark === '.' && /^\d{1,3}(,\d{3})+$/.test(t)) ? t.replace(/,/g, '') : t.replace(',', '.');
    else if (/^\d{1,3}(\.\d{3})+$/.test(t) && mark === ',') t = t.replace(/\./g, '');
    if (!/^\d+(\.\d+)?$/.test(t)) return NaN;
    const n = Math.round(Number(t) * 100) / 100;
    return neg ? -n : n;
  }

  // ---------- column names ----------
  const BANK = {
    date: ['data contabile', 'data operazione', 'data registrazione', 'data contabilizzazione', 'data', 'booking date', 'date', 'transaction date'],
    value_date: ['data valuta', 'valuta', 'value date'],
    debit: ['addebiti', 'addebito', 'dare', 'uscite', 'uscita', 'debit', 'importo dare'],
    credit: ['accrediti', 'accredito', 'avere', 'entrate', 'entrata', 'credit', 'importo avere'],
    amount: ['importo', 'importo eur', 'importo euro', 'importo in euro', 'importo divisa conto', 'amount', 'movimento'],
    ref: ['id operazione', 'id movimento', 'riferimento', 'cro', 'trn', 'numero operazione', 'reference', 'id transazione'],
    counterparty: ['beneficiario', 'ordinante', 'controparte', 'ordinante beneficiario', 'counterparty', 'nome controparte'],
    balance: ['saldo', 'saldo contabile', 'saldo disponibile', 'balance'],
    description: ['descrizione', 'descrizione operazione', 'causale', 'causale descrizione', 'descrizione estesa', 'dettagli', 'dettaglio', 'operazione', 'description', 'details', 'informazioni aggiuntive', 'note']
  };
  const PAY = {
    id: ['transaction id', 'id transazione', 'id della transazione'],
    payout_id: ['payout id', 'id pagamento', 'id del pagamento', 'id versamento', 'id del versamento', 'id bonifico'],
    payout_date: ['payout date', 'data pagamento', 'data del pagamento', 'data versamento', 'data del versamento', 'data bonifico'],
    payout_status: ['payout status', 'stato pagamento', 'stato del pagamento', 'stato versamento', 'stato del versamento', 'stato bonifico'],
    date: ['transaction date', 'data transazione', 'data della transazione', 'data', 'date', 'processed at', 'created at'],
    type: ['type', 'tipo', 'tipo di transazione', 'transaction type'],
    order: ['order', 'ordine', 'order name', 'numero ordine', 'nome ordine'],
    net: ['net', 'netto', 'importo netto'],
    fee: ['fee', 'fees', 'commissione', 'commissioni', 'tariffa', 'tariffe'],
    amount: ['amount', 'importo', 'importo lordo', 'gross', 'lordo'],
    payment_method: ['payment method name', 'metodo di pagamento', 'nome del metodo di pagamento', 'card brand', 'marchio della carta', 'circuito'],
    currency: ['currency', 'valuta']
  };
  const MULTI = { description: true };   // several description columns are joined

  function mapColumns(header, dict) {
    const h = header.map(norm), map = {}, used = new Set();
    for (const [field, aliases] of Object.entries(dict)) {
      const hits = [];
      for (const a of aliases) h.forEach((x, i) => { if (x === a && !used.has(i) && !hits.includes(i)) hits.push(i); });
      if (!hits.length) for (const a of aliases) { if (a.length < 5) continue; h.forEach((x, i) => { if (x.includes(a) && !used.has(i) && !hits.includes(i)) hits.push(i); }); }
      if (!hits.length) continue;
      const take = MULTI[field] ? hits : [hits[0]];
      take.forEach(i => used.add(i)); map[field] = MULTI[field] ? take : take[0];
    }
    return map;
  }
  function findHeader(rows, dict, need) {
    let best = null;
    rows.slice(0, 40).forEach((r, i) => {
      const map = mapColumns(r, dict), score = Object.keys(map).length;
      if (need(map) && (!best || score > best.score)) best = { index: i, header: r, map, score };
    });
    return best;
  }
  const bankNeed = m => m.date != null && (m.amount != null || m.debit != null || m.credit != null);
  const payNeed = m => m.date != null && m.amount != null && (m.type != null || m.net != null);

  function detectKind(rows) {
    const b = findHeader(rows, BANK, bankNeed), p = findHeader(rows, PAY, payNeed);
    const pScore = p ? p.score + (p.map.payout_id != null ? 3 : 0) + (p.map.fee != null ? 2 : 0) : -1;
    return (b ? b.score : -1) >= pScore ? 'bank' : 'payments';
  }

  // ---------- rows ----------
  function bankRows(rows, h) {
    const m = h.map, body = rows.slice(h.index + 1), out = [], errors = [];
    const col = i => i == null ? [] : body.map(r => r[i]);
    const mark = decimalMark([...col(m.amount), ...col(m.debit), ...col(m.credit), ...col(m.balance)]);
    body.forEach((r, k) => {
      const date = parseDate(r[m.date]);
      let amount = null;
      if (m.amount != null && strip(r[m.amount]).trim() !== '') amount = parseAmount(r[m.amount], mark);
      else {
        const d = m.debit != null ? parseAmount(r[m.debit], mark) : null, c = m.credit != null ? parseAmount(r[m.credit], mark) : null;
        if (Number.isNaN(d) || Number.isNaN(c)) amount = NaN;
        else if (d != null || c != null) amount = Math.round(((c ? Math.abs(c) : 0) - (d ? Math.abs(d) : 0)) * 100) / 100;
      }
      if (!date && (amount == null || Number.isNaN(amount))) return;          // preamble, totals, blank lines
      if (!date && /[a-z]/i.test(strip(r[m.date]))) return;                   // "Saldo finale", "Totale" …
      if (!date || amount == null || Number.isNaN(amount)) { errors.push({ line: r.line || h.index + k + 2, text: r.join(' · ') }); return; }
      if (amount === 0) return;
      const desc = (m.description || []).map(i => strip(r[i]).trim()).filter(Boolean);
      out.push({
        date, value_date: m.value_date != null ? (parseDate(r[m.value_date]) || date) : date, amount,
        description: [...new Set(desc)].join(' · '),
        counterparty: m.counterparty != null ? strip(r[m.counterparty]).trim() : '',
        ref: m.ref != null ? strip(r[m.ref]).trim() : '',
        balance: m.balance != null && strip(r[m.balance]).trim() !== '' ? parseAmount(r[m.balance], mark) : null
      });
    });
    out.forEach(x => { if (Number.isNaN(x.balance)) x.balance = null; });
    return { rows: out, errors, mark };
  }

  const TYPES = [[/^(charge|addebito|vendita|pagamento ricevuto|sale)/, 'charge'], [/^(refund|rimborso)/, 'refund'], [/^(adjustment|rettifica|adeguamento)/, 'adjustment'],
    [/^(chargeback|dispute|contestazione|storno|controversia)/, 'chargeback'], [/^(payout|versamento|bonifico|trasferimento|transfer)/, 'payout'], [/^(reserve|riserva)/, 'reserve']];
  const STATUS = [[/^(paid|pagato|versato|completato|inviato)/, 'paid'], [/^(in.?transit|in transito)/, 'in_transit'], [/^(scheduled|programmato|pianificato|in programma)/, 'scheduled'],
    [/^(failed|non riuscito|fallito|rifiutato)/, 'failed'], [/^(cancel|annullato)/, 'canceled'], [/^(pending|in sospeso|in attesa)/, 'pending']];
  const pick = (list, v) => { const t = norm(v); for (const [re, k] of list) if (re.test(t)) return k; return t.replace(/ /g, '_'); };

  function paymentRows(rows, h) {
    const m = h.map, body = rows.slice(h.index + 1), out = [], errors = [];
    const mark = decimalMark([...body.map(r => r[m.amount]), ...(m.fee != null ? body.map(r => r[m.fee]) : [])]);
    body.forEach((r, k) => {
      const date = parseDateTime(r[m.date]), amount = parseAmount(r[m.amount], mark);
      if (!date && (amount == null || Number.isNaN(amount))) return;
      if (!date || amount == null || Number.isNaN(amount)) { errors.push({ line: r.line || h.index + k + 2, text: r.join(' · ') }); return; }
      const fee = m.fee != null ? parseAmount(r[m.fee], mark) : 0, net = m.net != null ? parseAmount(r[m.net], mark) : null;
      out.push({
        id: m.id != null ? strip(r[m.id]).trim() : '', date, type: m.type != null ? pick(TYPES, r[m.type]) : (amount < 0 ? 'refund' : 'charge'),
        order: m.order != null ? strip(r[m.order]).trim() : '', payout_id: m.payout_id != null ? strip(r[m.payout_id]).trim() : '',
        payout_date: m.payout_date != null ? (parseDate(r[m.payout_date]) || '') : '', payout_status: m.payout_status != null ? pick(STATUS, r[m.payout_status]) : '',
        amount, fee: Number.isNaN(fee) || fee == null ? 0 : Math.abs(fee), net: Number.isNaN(net) ? null : net,
        payment_method: m.payment_method != null ? strip(r[m.payment_method]).trim() : '', currency: m.currency != null ? strip(r[m.currency]).trim().toUpperCase() : 'EUR'
      });
    });
    out.forEach(x => { if (x.net == null) x.net = Math.round((x.amount - x.fee) * 100) / 100; });
    return { rows: out, errors, mark };
  }

  // one call for the console: text → kind, header, editable mapping, rows
  function read(text, kind) {
    const { sep, rows: table } = parseCSV(text);
    if (!table.length) return { error: 'Il file è vuoto.' };
    kind = kind || detectKind(table);
    const h = kind === 'bank' ? findHeader(table, BANK, bankNeed) : findHeader(table, PAY, payNeed);
    if (!h) return { sep, kind, table, rows: [], errors: [], error: kind === 'bank' ? 'Non trovo la riga con i nomi delle colonne (serve almeno Data e Importo, oppure Dare/Avere).'
                                                           : 'Non trovo le colonne del file pagamenti (servono almeno Data, Tipo e Importo).' };
    return { sep, kind, table, header: h, ...convert(table, h, kind) };
  }
  function convert(rows, h, kind) { return kind === 'bank' ? bankRows(rows, h) : paymentRows(rows, h); }
  function remap(res, field, index) {
    const map = { ...res.header.map };
    if (MULTI[field]) map[field] = index == null || index === '' ? [] : [Number(index)]; else if (index == null || index === '') delete map[field]; else map[field] = Number(index);
    const header = { ...res.header, map };
    return { ...res, header, ...convert(res.table, header, res.kind) };
  }

  const api = { parseCSV, detectSep, parseDate, parseDateTime, parseAmount, decimalMark, mapColumns, findHeader, detectKind, bankRows, paymentRows, read, remap, BANK, PAY, norm };
  if (typeof module !== 'undefined' && module.exports) module.exports = api; else root.RECON = api;
})(typeof window !== 'undefined' ? window : globalThis);
