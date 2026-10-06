// v0.82 Incassi: CSV reader for bank statements and Shopify payments files.
//   node tools/go-live/drill/recon-test/test_recon_csv.js
const path = require('path');
const R = require(path.join(__dirname, '../../../../fabula-tablet/recon.js'));
let pass = 0, fail = 0;
const ck = (name, ok, info = '') => { if (ok) { pass++; console.log('PASS ' + name); } else { fail++; console.log('FAIL ' + name + (info ? '  [' + info + ']' : '')); } };
const J = x => JSON.stringify(x);

// values
ck('dates: dd/mm/yyyy, dd.mm.yy, ISO, bad day refused',
  R.parseDate('05/10/2026') === '2026-10-05' && R.parseDate('5.10.26') === '2026-10-05' && R.parseDate('2026-10-05 14:00') === '2026-10-05' && R.parseDate('31/02/2026') === null && R.parseDate('Saldo') === null);
ck('amounts: 1.234,56 · -2,50 · 2,50- · (3,00) · 1234.56 · € 10',
  R.parseAmount('1.234,56', ',') === 1234.56 && R.parseAmount('-2,50', ',') === -2.5 && R.parseAmount('2,50-', ',') === -2.5 && R.parseAmount('(3,00)', ',') === -3
  && R.parseAmount('1234.56', '.') === 1234.56 && R.parseAmount('€ 10', ',') === 10 && R.parseAmount('1.300', ',') === 1300 && Number.isNaN(R.parseAmount('abc', ',')));
ck('date-time: Shopify zone kept, Italian date gets Agropoli time',
  R.parseDateTime('2026-10-03 10:12:31 +0200') === '2026-10-03 10:12:31 +0200' && R.parseDateTime('03/10/2026 10:12') === '2026-10-03 10:12:00 Europe/Rome');

// 1. bank export with a preamble, Dare/Avere-style columns, a footer
const bank1 = `Elenco movimenti conto corrente
Intestatario: AZIENDA AGRICOLA MASSERIA CILENTANA
;;
Data contabile;Data valuta;Descrizione;Causale;Accrediti;Addebiti
05/10/2026;05/10/2026;BONIFICO A VOSTRO FAVORE SHOPIFY INTERNATIONAL;48;1.248,70;
05/10/2026;06/10/2026;COMMISSIONI SU BONIFICO;"16";;2,50
06/10/2026;06/10/2026;SDD ENEL ENERGIA;"50";;-300,00
Saldo finale;;;;;1.246,20
`;
const b1 = R.read(bank1);
ck('bank 1: found as a bank file, header is the 4th line', b1.kind === 'bank' && b1.header.header[0] === 'Data contabile' && b1.table[b1.header.index].line === 4, J(b1.header && b1.header.map));
ck('bank 1: credit +, debit − (also when the bank writes debits negative), footer skipped',
  b1.rows.length === 3 && b1.rows[0].amount === 1248.7 && b1.rows[1].amount === -2.5 && b1.rows[2].amount === -300 && !b1.errors.length, J(b1.rows));
ck('bank 1: value date and both description columns kept', b1.rows[1].value_date === '2026-10-06' && b1.rows[1].description === 'COMMISSIONI SU BONIFICO · 16', J(b1.rows[1]));

// 2. comma-separated, quoted, one signed column, balance
const bank2 = `"Data operazione","Data valuta","Importo","Divisa","Descrizione operazione","Saldo"
"03/10/2026","03/10/2026","-1.234,56","EUR","PAGAMENTO FORNITORE, FATTURA 12","10.000,00"
"04/10/2026","04/10/2026","+500,00","EUR","VERSAMENTO CONTANTI","10.500,00"
`;
const b2 = R.read(bank2);
ck('bank 2: comma separator with quoted commas inside', b2.sep === ',' && b2.rows.length === 2 && b2.rows[0].description === 'PAGAMENTO FORNITORE, FATTURA 12', J(b2.rows));
ck('bank 2: signed amounts and balance', b2.rows[0].amount === -1234.56 && b2.rows[1].amount === 500 && b2.rows[1].balance === 10500);

// 3. "Importo Dare" / "Importo Avere" are not the amount column; "ID operazione" is not the description
const bank3 = `Data;Valuta;Importo Dare;Importo Avere;ID operazione;Operazione
01/10/2026;01/10/2026;12,00;;A1B2;CANONE MENSILE CONTO
02/10/2026;02/10/2026;;100,00;C3D4;BONIFICO DA PIZZERIA DA GINO
`;
const b3 = R.read(bank3);
ck('bank 3: debit/credit columns, reference and description told apart',
  b3.header.map.amount == null && b3.rows[0].amount === -12 && b3.rows[1].amount === 100 && b3.rows[1].ref === 'C3D4' && b3.rows[1].description === 'BONIFICO DA PIZZERIA DA GINO', J(b3.header.map));
ck('bank 3: a column can be corrected by hand', R.remap(b3, 'ref', '').rows[1].ref === '');

// 4. Shopify payments export (English admin)
const shop1 = `Transaction Date,Type,Order,Card Brand,Card Source,Payout Status,Payout Date,Payout ID,Available On,Amount,Fee,Net,Checkout,Payment Method Name,Presentment Amount,Presentment Currency,Currency
2026-10-03 10:12:31 +0200,charge,#1001,visa,online,paid,2026-10-06,123456789,2026-10-06,30.00,0.75,29.25,,card,30.00,EUR,EUR
2026-10-04 09:00:00 +0200,refund,#1001,visa,online,paid,2026-10-06,123456789,2026-10-06,-5.00,0.00,-5.00,,card,-5.00,EUR,EUR
2026-10-05 18:00:00 +0200,charge,#1002,mastercard,pos,in_transit,2026-10-08,987654321,2026-10-08,1234.50,22.10,1212.40,,card,1234.50,EUR,EUR
`;
const s1 = R.read(shop1);
ck('shopify EN: found as a payments file', s1.kind === 'payments', J(s1.header && s1.header.map));
ck('shopify EN: types, orders, payout id/date/status, fee, net',
  s1.rows.length === 3 && s1.rows[0].type === 'charge' && s1.rows[1].type === 'refund' && s1.rows[0].order === '#1001' && s1.rows[0].payout_id === '123456789'
  && s1.rows[0].payout_date === '2026-10-06' && s1.rows[2].payout_status === 'in_transit' && s1.rows[0].fee === 0.75 && s1.rows[2].net === 1212.4 && s1.rows[2].amount === 1234.5, J(s1.rows));
ck('shopify EN: "Amount" not "Presentment Amount", payment method name', s1.header.map.amount === 9 && s1.rows[0].payment_method === 'card');

// 5. Shopify payments export (Italian admin, ; and comma decimals)
const shop2 = `Data della transazione;Tipo;Ordine;Stato del pagamento;Data del pagamento;ID pagamento;Importo;Commissione;Netto;Valuta
03/10/2026 10:12;Addebito;#1001;Pagato;06/10/2026;123;30,00;0,75;29,25;EUR
04/10/2026 09:00;Rimborso;#1001;Pagato;06/10/2026;123;-5,00;0,00;-5,00;EUR
`;
const s2 = R.read(shop2);
ck('shopify IT: Italian headers and values understood',
  s2.kind === 'payments' && s2.rows.length === 2 && s2.rows[0].type === 'charge' && s2.rows[1].type === 'refund' && s2.rows[0].payout_status === 'paid'
  && s2.rows[0].payout_date === '2026-10-06' && s2.rows[0].amount === 30 && s2.rows[0].date === '2026-10-03 10:12:00 Europe/Rome' && s2.rows[0].currency === 'EUR', J(s2.rows));

// 6. bad lines are reported, not dropped silently
const bank4 = `Data;Importo;Descrizione
01/10/2026;10,00;OK
02/10/2026;dieci;RIGA ROTTA
;5,00;SENZA DATA
`;
const b4 = R.read(bank4);
ck('bad amount and missing date reported with their file line', b4.rows.length === 1 && b4.errors.length === 2 && b4.errors[0].line === 3 && b4.errors[1].line === 4, J(b4.errors));
ck('empty file explained', !!R.read('').error && !!R.read('a;b\n1;2').error);

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
