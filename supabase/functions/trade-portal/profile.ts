// v1.22 (31/10/2026, Nick: "this data should not need to be entered for the user. their data should be saved for future use"):
// the customer's own details, added to the portal state as customer.profile, so the trade pages (Contratto estate, theme v1.32)
// start filled on any device: business name, type, P.IVA, phone and the delivery address in parts.
// Read only, for the customer the portal key belongs to (the same key that already gives the state's name, e-mail, phone and
// one-line address). Pure, tested on its own: profile_test.ts.
//   * business_name: the trade name (insegna) when there is one, else the legal name.
//   * business_type: lower case (the page knows ristorante, pizzeria, hotel, bnb, agriturismo, lido, gastronomia, altro).
//   * piva: 11 digits with a valid check digit, without «IT»; anything else is left out (the page then asks for it).
//   * address, city, province, postcode: the delivery address deliveries use, in the same order as fabula.trade_effective_lines:
//     the plan's (trade_schedules.delivery_address, typed in the portal's «Il mio piano»), else the one set from the portal or
//     the office (parties.delivery_address), else the register's address, comune, province and CAP (a cancelled plan's address
//     is skipped). The first two are one line, split here («Via Roma 1, 84043 Agropoli (SA)»); a line that cannot be split safely
//     gives the street only; without a CAP, the comune is accepted only when it is the register's. The parts always
//     come from that one source (the page applies them as a group), except the province, taken from the register when the
//     line's comune is the register's comune. Province: 2 letters; CAP: 5 digits; otherwise left out.
//   * Empty values are left out.

export type PartyRow = {
  legal_name?: string | null; trade_name?: string | null; business_type?: string | null; piva?: string | null; phone?: string | null;
  address?: string | null; city?: string | null; province?: string | null; postcode?: string | null; delivery_address?: string | null;
};
export type Address = { address?: string; city?: string; province?: string; postcode?: string };
export type Profile = Partial<Record<"business_name" | "business_type" | "piva" | "phone" | "address" | "city" | "province" | "postcode", string>>;

// the columns profileOf reads (the edge function selects only these)
export const PROFILE_COLUMNS = "legal_name, trade_name, business_type, piva, phone, address, city, province, postcode, delivery_address";

const str = (v: unknown) => (v == null ? "" : String(v).trim());

// Italian partita IVA: 11 digits, the last one a check digit (odd places as they are, even places doubled minus 9 when > 9)
export function pivaOk(p: string): boolean {
  if (!/^\d{11}$/.test(p) || /^0{11}$/.test(p)) return false;
  let sum = 0;
  for (let i = 0; i < 10; i++) {
    let d = Number(p[i]);
    if (i % 2 === 1) { d *= 2; if (d > 9) d -= 9; }
    sum += d;
  }
  return (10 - (sum % 10)) % 10 === Number(p[10]);
}

// the Italian province codes (with the four Sardinian ones abolished in 2016, still found in addresses)
export const PROVINCES = new Set(("AG AL AN AO AP AQ AR AT AV BA BG BI BL BN BO BR BS BT BZ CA CB CE CH CI CL CN CO CR CS CT CZ EN FC FE FG FI " +
  "FM FR GE GO GR IM IS KR LC LE LI LO LT LU MB MC ME MI MN MO MS MT NA NO NU OG OR OT PA PC PD PE PG PI PN PO PR PT PU PV PZ RA RC RE " +
  "RG RI RM RN RO SA SI SO SP SR SS SU SV TA TE TN TO TP TR TS TV UD VA VB VC VE VI VR VS VT VV").split(" "));

// a comune: Latin letters (accents, apostrophes, hyphens, spaces, dots), no digits or commas, longer than 2
// (no \p{L}: the page's copy of this rule must parse in older browsers too)
const cityOk = (c: string) => c.length > 2 && /^[A-Za-zÀ-ÖØ-öø-ÿ][A-Za-zÀ-ÖØ-öø-ÿ'’.\- ]*$/.test(c);

// one line → parts. Accepted: «street, CAP comune», «street, CAP, comune», each optionally followed by «(PR)», « PR» or «, PR»
// (a real province code, any case) and by «, Italia»; «street, comune» without a CAP only when the comune is `knownCity`
// (the register's). Anything else: the street only (the whole line).
export function splitAddress(line: string, knownCity?: string | null): Address {
  let s = str(line).replace(/,\s*(italia|italy)\.?$/i, "").trim();
  if (!s) return {};
  let province: string | undefined;
  const pr = s.match(/^(.*?)(?:\s*\(([A-Za-z]{2})\)|,\s*([A-Za-z]{2})|\s+([A-Za-z]{2}))$/);
  if (pr && pr[1].includes(",")) {
    const code = (pr[2] ?? pr[3] ?? pr[4]).toUpperCase();
    if (PROVINCES.has(code)) { s = pr[1].trim(); province = code; }
  }
  let m = s.match(/^(.+?),\s*(\d{5}),?\s+(.+)$/);
  if (m && cityOk(m[3].trim())) return { address: m[1].trim(), postcode: m[2], city: m[3].trim(), ...(province ? { province } : {}) };
  m = s.match(/^(.+?),\s*([^,\d]+)$/);
  const known = str(knownCity).toLowerCase();
  if (m && known && m[2].trim().toLowerCase() === known && cityOk(m[2].trim())) return { address: m[1].trim(), city: m[2].trim(), ...(province ? { province } : {}) };
  return { address: str(line) };
}

export function profileOf(p: PartyRow | null | undefined, planAddress?: string | null): Profile | null {
  if (!p) return null;
  const out: Profile = {};
  const put = (k: keyof Profile, v: string | undefined) => { if (v) out[k] = v; };
  put("business_name", str(p.trade_name) || str(p.legal_name));
  put("business_type", str(p.business_type).toLowerCase());
  const piva = str(p.piva).replace(/^IT/i, "").replace(/\s+/g, "");
  if (pivaOk(piva)) out.piva = piva;
  put("phone", str(p.phone));
  const line = str(planAddress) || str(p.delivery_address);
  const a: Address = line ? splitAddress(line, p.city)
    : { address: str(p.address), city: str(p.city), province: str(p.province), postcode: str(p.postcode) };
  if (line && !a.province && a.city && str(p.city) && a.city.toLowerCase() === str(p.city).toLowerCase()) a.province = str(p.province);
  if (str(a.address)) {
    put("address", str(a.address));
    put("city", str(a.city));
    const prov = str(a.province).toUpperCase();
    if (/^[A-Z]{2}$/.test(prov)) out.province = prov;
    const cap = str(a.postcode);
    if (/^\d{5}$/.test(cap)) out.postcode = cap;
  }
  return out;
}
