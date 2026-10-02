import sys
root = sys.argv[1]; T = root + '/fabula-tablet/'
def must(s, a, b):
    assert s.count(a) == 1, (s.count(a), a[:100]); return s.replace(a, b)

# ---- tablet: counter sale and typed Z retired (Shopify POS is the till) ----
s = open(T + 'app.js').read()
i = s.index('  // 9 — till close\n  function stepZ(eq) {'); j = s.index('  // 10 — meter\n')
s = s[:i] + r'''  // 9 — till: closes itself from Shopify POS (bot Ordini Shopify writes pos_daily_closings)
  async function stepZ(eq) {
    const { data: pc } = await sb.from('pos_daily_closings').select('rt_total_eur, rt_receipts, source').eq('closing_date', today()).maybeSingle();
    const d = document.createElement('div'); d.className = 'card';
    d.innerHTML = `<div class="scan">La cassa è Shopify POS</div><div>Le vendite al banco si battono sul POS; ogni mattina il bot Ordini Shopify le copia qui e chiude la giornata da solo. Non c'è più nulla da digitare.</div>` +
      (pc ? `<div style="margin-top:8px">Oggi finora: <b>€ ${Number(pc.rt_total_eur).toLocaleString('it-IT', { minimumFractionDigits: 2 })}</b> · ${pc.rt_receipts} scontrini${pc.source === 'shopify_pos' ? ' (da Shopify POS)' : ''}</div>` : `<div style="margin-top:8px" class="status">Oggi non è ancora stata sincronizzata nessuna vendita POS.</div>`);
    $('form').append(d);
    openForm('Chiusura cassa', eq.code, async () => {}); $('btn-form-save').style.display = 'none';
  }
''' + s[j:]
i = s.index('  // 6 — sale at the counter or shipment line\n  async function stepPick(b) {'); j = s.index('  // 11 — goods receipt')
s = s[:i] + r'''  // 6 — direct shipment line from a batch QR (counter sales live on Shopify POS; online/wholesale orders go through 🚚 Da spedire)
  async function stepPick(b) {
    const { data: prod } = await sb.from('products').select('*').eq('id', b.product_id).single();
    const { data: custs } = await sb.from('parties').select('id, legal_name').in('type', ['customer', 'both']).eq('active', true).order('legal_name');
    const d = document.createElement('div'); d.className = 'card';
    d.innerHTML = `<div class="scan">${prod.name}</div><div class="status">Spedizione diretta senza ordine. Le vendite al banco si battono su Shopify POS; gli ordini online e ingrosso si preparano da 🚚 Da spedire.</div>`;
    $('form').append(d);
    field('kg', 'kg', 'number', { step: '0.01' });
    field('cust', 'Cliente', 'select', { options: [['', '—'], ...custs.map(x => [x.id, x.legal_name])] });
    openForm('Spedizione', 'lotto ' + b.batch_lot, async () => {
      const kg = val('kg');
      if (!val('cust')) { toast('Scegli il cliente', 'err'); throw new Error('cliente'); }
      const ddt = 'DDT-' + today().replace(/-/g, '') + '-' + Date.now().toString().slice(-4);
      await save([scanEvent(current.code, 'pick', { payload: { kg, mode: 'ship' } }),
        { table: 'shipments', row: { ddt_number: ddt, customer_id: val('cust'), status: 'picked', driver_id: staff.id } },
        { table: 'shipment_lines', row: { shipment_id: '$1.id', product_id: prod.id, lot_number: b.batch_lot, qty: kg } },
        { table: 'stock_moves', row: { product_id: prod.id, lot_number: b.batch_lot, qty: -kg, move_type: 'sale', source: 'tablet' } }]);
      toast(`Spedizione ${ddt} · ${kg} kg ✓`);
    });
  }
''' + s[j:]
open(T + 'app.js', 'w').write(s)

sw = open(T + 'sw.js').read(); sw = must(sw, "const CACHE = 'perla-v13';", "const CACHE = 'perla-v14';"); open(T + 'sw.js', 'w').write(sw)

# ---- console: till wording ----
c = open(T + 'console.js').read()
c = must(c, "if (pc.missing) items.push(['ko', 'Chiusura cassa mancante']);", "if (pc.missing) items.push(['status', 'Nessuna vendita POS sincronizzata per ieri']);")
open(T + 'console.js', 'w').write(c)

# ---- admin: Shopify card in Vendite ----
h = open(T + 'admin.html').read()
h = must(h, '''      <div class="card"><h3>Prezzi</h3><div class="params" data-groups="price"></div></div>''',
'''      <div class="card"><h3>Prezzi</h3><div class="params" data-groups="price"></div></div>
      <div class="card"><h3>Shopify POS e giacenze online</h3><div class="hint">Shopify è la cassa e il sito: le vendite arrivano qui ogni mattina (bot Ordini Shopify) e la chiusura cassa si scrive da sola. Il bot Giacenze Shopify spinge su Shopify i pezzi vendibili (scorte in corso di validità meno ordini pagati da spedire meno la riserva banco).</div><div class="params" data-groups="shopify"></div></div>''')
open(T + 'admin.html', 'w').write(h)
a = open(T + 'admin.js').read()
a = must(a, "price: 'Prezzi',", "price: 'Prezzi', shopify: 'Shopify',")
open(T + 'admin.js', 'w').write(a)
print('v25 patched')
