// v1.22 handler check: the real trade-portal index.ts against a fake Supabase (PostgREST): ?action=state adds customer.profile.
// Run from the repo root (needs the npm package @supabase/supabase-js; a deno.json with {"nodeModulesDir": "auto"} if offline-cached):
//   deno run --allow-net --allow-env --allow-read supabase/functions/trade-portal/state_e2e.ts supabase/functions/trade-portal/index.ts
// 18 checks; on v1.21 (no profile) the profile checks fail, as they should. Ports: fake Supabase 54399, the function 8000.
let pass = 0, fail = 0;
const ok = (c: boolean, m: string) => { if (c) pass++; else { fail++; console.log("FAIL", m); } };
const seen: { path: string; search: string; profile: string | null }[] = [];
let partiesMode: "ok" | "error" | "none" | "slow" = "ok";
let plan: Record<string, unknown> | null = null;
const STATE = (id: string | null) => ({ settings: { horizon_days: 28 }, schedule: plan, customer: { ...(id ? { id } : {}), name: "PROVA Pizzeria Test (da cancellare)", email: "x@y.it",
  phone: "+39 333 1234567", address: "Via Roma 1, 84043, Agropoli", instructions: null, payment_terms_days: 30, shopify_company_id: null }, products: [] });
const ROW = { legal_name: "PROVA Pizzeria Test (da cancellare)", trade_name: null, business_type: "pizzeria", piva: "IT00743110157", phone: "+39 333 1234567",
  address: "Via Roma 1", city: "Agropoli", province: "SA", postcode: "84043", delivery_address: null };

Deno.serve({ port: 54399, onListen() {} }, async (req) => {
  const u = new URL(req.url);
  seen.push({ path: u.pathname, search: decodeURIComponent(u.search), profile: req.headers.get("accept-profile") ?? req.headers.get("content-profile") });
  if (u.pathname === "/rest/v1/rpc/trade_portal_state") {
    const b = await req.json();
    const body = b.p_token === "aaaaaaaaaaaaaaaa" ? STATE("p1") : b.p_token === "bbbbbbbbbbbbbbbb" ? STATE(null) : null;
    return new Response(JSON.stringify(body), { headers: { "content-type": "application/json" } });
  }
  if (u.pathname === "/rest/v1/parties") {
    if (partiesMode === "error") return new Response(JSON.stringify({ code: "42501", message: "permission denied" }), { status: 401, headers: { "content-type": "application/json" } });
    if (partiesMode === "slow") await new Promise((r) => setTimeout(r, 3000));
    const rows = partiesMode === "none" ? [] : [ROW];
    const one = (req.headers.get("accept") ?? "").includes("vnd.pgrst.object");
    return new Response(JSON.stringify(one ? rows[0] ?? null : rows), { headers: { "content-type": "application/json" } });
  }
  return new Response("{}", { status: 404 });
});

Deno.env.set("SUPABASE_URL", "http://127.0.0.1:54399");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "service");
Deno.env.set("SUPABASE_ANON_KEY", "anon");
await import(new URL(Deno.args[0], `file://${Deno.cwd()}/`).href);   // starts Deno.serve on :8000
await new Promise((r) => setTimeout(r, 300));
const get = async (t: string) => { const r = await fetch(`http://127.0.0.1:8000/?action=state&t=${t}`); return { status: r.status, body: await r.json() }; };

// 1. a valid key: the state plus customer.profile, read from fabula.parties for that customer only
seen.length = 0;
let r = await get("aaaaaaaaaaaaaaaa");
ok(r.status === 200, "1 status " + r.status);
ok(JSON.stringify(r.body.customer.profile) === JSON.stringify({ business_name: "PROVA Pizzeria Test (da cancellare)", business_type: "pizzeria", piva: "00743110157",
  phone: "+39 333 1234567", address: "Via Roma 1", city: "Agropoli", province: "SA", postcode: "84043" }), "1 profile " + JSON.stringify(r.body.customer.profile));
ok(r.body.customer.name === "PROVA Pizzeria Test (da cancellare)" && r.body.settings.horizon_days === 28 && Array.isArray(r.body.products), "1 the rest of the state unchanged");
const pq = seen.find((s) => s.path === "/rest/v1/parties");
ok(!!pq && pq.profile === "fabula", "1 parties read in schema fabula: " + JSON.stringify(pq));
ok(!!pq && pq.search.includes("id=eq.p1"), "1 only the key's customer: " + pq?.search);
ok(!!pq && /select=legal_name,\s*trade_name,\s*business_type,\s*piva,\s*phone,\s*address,\s*city,\s*province,\s*postcode,\s*delivery_address/.test(pq.search.replace(/\+/g, " ")), "1 only the profile columns: " + pq?.search);
ok(!!pq && !/portal_token|notes|\*/.test(pq.search), "1 no token, notes or *");

// 2. reading the profile fails: the state still goes out, without the profile
partiesMode = "error";
r = await get("aaaaaaaaaaaaaaaa");
ok(r.status === 200 && r.body.customer && !("profile" in r.body.customer) && r.body.customer.name, "2 state without profile on error: " + r.status);

// 3. no row: no profile
partiesMode = "none";
r = await get("aaaaaaaaaaaaaaaa");
ok(r.status === 200 && !("profile" in r.body.customer), "3 no row → no profile");
partiesMode = "ok";

// 4. a key with no active customer: 403 and the register is not read
seen.length = 0;
r = await get("cccccccccccccccc");
ok(r.status === 403 && r.body.error === "accesso non attivo", "4 inactive key 403");
ok(!seen.some((s) => s.path === "/rest/v1/parties"), "4 parties not read for an inactive key");

// 5. a malformed key: 403 before the database
seen.length = 0;
r = await get("not-a-key");
ok(r.status === 403 && r.body.error === "link non valido" && seen.length === 0, "5 malformed key 403, nothing read");

// 6. a state without customer.id (older database): no parties query, state as is
seen.length = 0;
r = await get("bbbbbbbbbbbbbbbb");
ok(r.status === 200 && !("profile" in r.body.customer) && !seen.some((s) => s.path === "/rest/v1/parties"), "6 no customer id → no profile, no read");

// 7. the plan's delivery address (in the state) wins, as for deliveries
plan = { status: "active", delivery_address: "Via Mare 3, 84048 Castellabate (SA)" };
r = await get("aaaaaaaaaaaaaaaa");
const pp = r.body.customer.profile ?? {};
ok(pp.address === "Via Mare 3" && pp.postcode === "84048" && pp.city === "Castellabate" && pp.province === "SA", "7 plan address: " + JSON.stringify(pp));
ok(r.body.schedule?.delivery_address === "Via Mare 3, 84048 Castellabate (SA)", "7 the state's schedule unchanged");
// a cancelled plan's address is not used: the register's
plan = { status: "cancelled", delivery_address: "Via Mare 3, 84048 Castellabate (SA)" };
r = await get("aaaaaaaaaaaaaaaa");
ok(r.body.customer.profile?.address === "Via Roma 1" && r.body.customer.profile?.city === "Agropoli", "7 cancelled plan skipped: " + JSON.stringify(r.body.customer.profile));
plan = null;

// 8. the register answers slowly: the state goes out after about 1.5 s, without the profile
partiesMode = "slow";
const t0 = Date.now();
r = await get("aaaaaaaaaaaaaaaa");
const ms = Date.now() - t0;
ok(r.status === 200 && !("profile" in r.body.customer) && r.body.customer.name, "8 slow register: state without profile");
ok(ms < 2600, "8 answered in " + ms + " ms");
partiesMode = "ok";

console.log(`pass ${pass}, fail ${fail}`);
Deno.exit(fail ? 1 : 0);
