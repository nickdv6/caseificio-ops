// deno test supabase/functions/trade-portal/profile_test.ts — v1.22: customer.profile in the portal state (profile.ts)
import { PROFILE_COLUMNS, PROVINCES, pivaOk, profileOf, splitAddress } from "./profile.ts";
// order-independent deep equality (undefined values count as missing keys, so they are rejected explicitly below)
const canon = (v: unknown): unknown => Array.isArray(v) ? v.map(canon)
  : v && typeof v === "object" ? Object.fromEntries(Object.keys(v as object).sort().map((k) => [k, canon((v as Record<string, unknown>)[k])])) : v;
function assertEquals(a: unknown, b: unknown) {
  const x = JSON.stringify(canon(a)), y = JSON.stringify(canon(b));
  if (x !== y) throw new Error(`expected ${y}\n     got ${x}`);
  if (a && typeof a === "object" && Object.values(a as object).some((v) => v === undefined)) throw new Error(`undefined value in ${x}`);
}

const VALID = "00743110157";   // a well-formed partita IVA (check digit right)
const reg = { legal_name: "Rossi Mario & C. snc", trade_name: null, business_type: "pizzeria", piva: VALID, phone: "+39 333 1234567",
  address: "Via Roma 1", city: "Agropoli", province: "SA", postcode: "84043", delivery_address: null };

Deno.test("no party → no profile", () => {
  assertEquals(profileOf(null), null);
  assertEquals(profileOf(undefined), null);
});

Deno.test("the register's details when there is no other delivery address", () => {
  assertEquals(profileOf(reg), { business_name: "Rossi Mario & C. snc", business_type: "pizzeria", piva: VALID, phone: "+39 333 1234567",
    address: "Via Roma 1", city: "Agropoli", province: "SA", postcode: "84043" });
});

Deno.test("the trade name (insegna) before the legal name; type in lower case", () => {
  assertEquals(profileOf({ ...reg, trade_name: "Pizzeria Da Mario" })?.business_name, "Pizzeria Da Mario");
  assertEquals(profileOf({ ...reg, trade_name: "  " })?.business_name, "Rossi Mario & C. snc");
  assertEquals(profileOf({ ...reg, business_type: " Pizzeria " })?.business_type, "pizzeria");
});

Deno.test("P.IVA: «IT» and spaces taken off; 11 digits with the right check digit, otherwise left out", () => {
  assertEquals(pivaOk(VALID), true);
  assertEquals(pivaOk("01234567890"), false);   // the test customer's made-up number: check digit wrong
  assertEquals(pivaOk("00000000000"), false);
  assertEquals(profileOf({ ...reg, piva: "IT 00743 110157" })?.piva, VALID);
  assertEquals(profileOf({ ...reg, piva: "it00743110157" })?.piva, VALID);
  for (const bad of ["01234567890", "123", "RSSMRA80A01H703X", "00000000000", null]) assertEquals("piva" in (profileOf({ ...reg, piva: bad }) ?? {}), false);
});

Deno.test("empty values are left out; no street → no address parts at all", () => {
  assertEquals(profileOf({ legal_name: "Hotel Prova Bis (test)", trade_name: null, business_type: "hotel", piva: null, phone: "", address: null,
    city: "Agropoli", province: null, postcode: null, delivery_address: null }), { business_name: "Hotel Prova Bis (test)", business_type: "hotel" });
});

Deno.test("province 2 letters (upper case), CAP 5 digits, otherwise left out", () => {
  const p = profileOf({ ...reg, province: "sa", postcode: "8404" });
  assertEquals([p?.province, "postcode" in (p ?? {})], ["SA", false]);
  assertEquals("province" in (profileOf({ ...reg, province: "Salerno" }) ?? {}), false);
});

Deno.test("delivery address: the plan's first, then the portal's / office's, then the register's (as deliveries)", () => {
  const withParty = { ...reg, delivery_address: "Via Lungomare 5, 84043 Agropoli (SA)" };
  const a = (x: ReturnType<typeof profileOf>) => [x?.address, x?.postcode, x?.city, x?.province];
  assertEquals(a(profileOf(withParty, "Piazza Vittorio Veneto 3, 84048 Castellabate (SA)")), ["Piazza Vittorio Veneto 3", "84048", "Castellabate", "SA"]);
  assertEquals(a(profileOf(withParty, "  ")), ["Via Lungomare 5", "84043", "Agropoli", "SA"]);
  assertEquals(a(profileOf(withParty, null)), ["Via Lungomare 5", "84043", "Agropoli", "SA"]);
  assertEquals(a(profileOf(reg, null)), ["Via Roma 1", "84043", "Agropoli", "SA"]);
});

Deno.test("one-line address: parts from that line only; the register's province only for the register's comune", () => {
  // the test customer's plan line: same comune as the register → its province
  const p = profileOf({ ...reg }, "Via Roma 1, 84043 Agropoli");
  assertEquals([p?.address, p?.postcode, p?.city, p?.province], ["Via Roma 1", "84043", "Agropoli", "SA"]);
  // another comune with its CAP: that comune, no province (never Agropoli's)
  const q = profileOf({ ...reg }, "Via Mare 3, 84048 Castellabate");
  assertEquals([q?.address, q?.postcode, q?.city, "province" in (q ?? {})], ["Via Mare 3", "84048", "Castellabate", false]);
  // no CAP: the comune only when it is the register's; otherwise the whole line is the street
  const q2 = profileOf({ ...reg }, "Via Mare 3, Agropoli");
  assertEquals([q2?.address, q2?.city, q2?.province, "postcode" in (q2 ?? {})], ["Via Mare 3", "Agropoli", "SA", false]);
  const q3 = profileOf({ ...reg }, "Via Mare 3, Castellabate");
  assertEquals([q3?.address, "city" in (q3 ?? {})], ["Via Mare 3, Castellabate", false]);
  // a line that cannot be split: the street only, nothing from the register
  const r = profileOf({ ...reg }, "Località Torre 12");
  assertEquals([r?.address, "city" in (r ?? {}), "province" in (r ?? {}), "postcode" in (r ?? {})], ["Località Torre 12", false, false, false]);
});

Deno.test("splitAddress: what it accepts", () => {
  assertEquals(splitAddress("Via Roma 1, 84043, Agropoli"), { address: "Via Roma 1", postcode: "84043", city: "Agropoli" });
  assertEquals(splitAddress("Via Roma 1, 84043 Agropoli (sa)"), { address: "Via Roma 1", postcode: "84043", city: "Agropoli", province: "SA" });
  assertEquals(splitAddress("Via Roma 1, 84043 Agropoli SA"), { address: "Via Roma 1", postcode: "84043", city: "Agropoli", province: "SA" });
  assertEquals(splitAddress("Via Roma 1, 84043 Agropoli Sa"), { address: "Via Roma 1", postcode: "84043", city: "Agropoli", province: "SA" });
  assertEquals(splitAddress("Via Roma 1, 84043, Agropoli, SA, Italia"), { address: "Via Roma 1", postcode: "84043", city: "Agropoli", province: "SA" });
  assertEquals(splitAddress("Via Roma, 1, 84043 Agropoli"), { address: "Via Roma, 1", postcode: "84043", city: "Agropoli" });
  assertEquals(splitAddress("Viale Europa 7, 84047 Capaccio Paestum"), { address: "Viale Europa 7", postcode: "84047", city: "Capaccio Paestum" });
  assertEquals(splitAddress("Via Nuova 2, 80065 Sant'Agnello (NA)"), { address: "Via Nuova 2", postcode: "80065", city: "Sant'Agnello", province: "NA" });
  assertEquals(splitAddress("Via Duomo 3, 84122 Salerno (sa)"), { address: "Via Duomo 3", postcode: "84122", city: "Salerno", province: "SA" });
  // without a CAP, only for the known comune
  assertEquals(splitAddress("Corso Garibaldi 12, Agropoli, SA", "agropoli"), { address: "Corso Garibaldi 12", city: "Agropoli", province: "SA" });
  assertEquals(splitAddress("Via Nuova 2, Sant'Agnello (NA)", "Sant'Agnello"), { address: "Via Nuova 2", city: "Sant'Agnello", province: "NA" });
  assertEquals(splitAddress("  "), {});
});

Deno.test("splitAddress: what it refuses (the whole line stays the street)", () => {
  for (const s of ["Via Lungomare 5 Agropoli", "Via Roma 1, SA", "Via Roma 1, 84043", "Via Roma 1, 84043 Agropoli 2", "Località Torre 12",
                   "Lido Azzurro, Via Lungomare snc", "Via Roma 1, interno cortile", "Agropoli, Corso Italia", "Corso Garibaldi 12, Agropoli, SA",
                   "Via Roma 1, 28856 Re"]) {
    assertEquals(splitAddress(s, "Agropoli Nord"), { address: s });
  }
  // a 2-letter tail that is not a province is not taken as one
  assertEquals(splitAddress("Via Roma 1, 84043 Agropoli XY").province === undefined, true);
  assertEquals(PROVINCES.has("SA") && PROVINCES.has("SU") && !PROVINCES.has("XY") && PROVINCES.size === 111, true);
});

Deno.test("only the columns profileOf needs are read; never the portal key, notes or Shopify ids", () => {
  const cols = PROFILE_COLUMNS.split(",").map((c) => c.trim());
  assertEquals(cols, ["legal_name", "trade_name", "business_type", "piva", "phone", "address", "city", "province", "postcode", "delivery_address"]);
  for (const bad of ["portal_token", "notes", "shopify_customer_id", "email", "sdi_code", "pec_email"]) assertEquals(cols.includes(bad), false);
});
