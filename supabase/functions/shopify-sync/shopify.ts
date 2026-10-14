// Shopify Admin GraphQL for shopify-sync (v1.02, audit E-18). Same credentials as trade-portal: the Dev Dashboard app
// «Caseificio ops», a token minted with the client-credentials grant from SHOPIFY_CLIENT_ID + SHOPIFY_CLIENT_SECRET (or a legacy
// static SHOPIFY_ADMIN_TOKEN). Unlike trade-portal's helper, a call returns Shopify's errors next to the data, so the caller can
// tell «a field this app may not read» (go on without it) from a real failure (stop, write nothing).

const SHOP = Deno.env.get("SHOPIFY_SHOP") ?? "pxssjd-cq.myshopify.com";
const BASE = (Deno.env.get("SHOPIFY_API_BASE") ?? `https://${SHOP}`).replace(/\/$/, "");   // only the local test points it elsewhere
const STATIC_TOKEN = Deno.env.get("SHOPIFY_ADMIN_TOKEN") ?? "";
const CLIENT_ID = Deno.env.get("SHOPIFY_CLIENT_ID") ?? "";
const CLIENT_SECRET = Deno.env.get("SHOPIFY_CLIENT_SECRET") ?? "";
export const API = "2026-07";
export const CONFIGURED = !!(STATIC_TOKEN || (CLIENT_ID && CLIENT_SECRET));
export const SHOP_DOMAIN = SHOP;

export type GqlError = { message: string; path?: (string | number)[]; extensions?: { code?: string } };
export type GqlResult = { data: any; errors: GqlError[] };
export type Gql = (query: string, variables?: Record<string, unknown>) => Promise<GqlResult>;

let tokenCache: { token: string; exp: number } | null = null;
async function accessToken(force = false): Promise<string> {
  if (STATIC_TOKEN) return STATIC_TOKEN;
  if (!CLIENT_ID || !CLIENT_SECRET) throw new Error("not_configured");
  if (!force && tokenCache && tokenCache.exp > Date.now()) return tokenCache.token;
  const r = await fetch(`${BASE}/admin/oauth/access_token`, {
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "client_credentials", client_id: CLIENT_ID, client_secret: CLIENT_SECRET }),
  });
  if (!r.ok) throw new Error(`Shopify token: ${r.status} ${(await r.text()).slice(0, 200)}`);
  const j = await r.json() as { access_token: string; expires_in?: number };
  tokenCache = { token: j.access_token, exp: Date.now() + Math.max(60, (j.expires_in ?? 86400) - 300) * 1000 };
  return tokenCache.token;
}

// each run starts with a fresh token: one minted before Nick added a permission would not carry it (tokens last 24 h)
export function resetToken() { tokenCache = null; }

const sleep = (ms: number) => new Promise((res) => setTimeout(res, ms));
const throttled = (e: GqlError[]) => e.some((x) => x.extensions?.code === "THROTTLED" || /throttled/i.test(x.message));

export const gql: Gql = async (query, variables = {}) => {
  if (!CONFIGURED) throw new Error("not_configured");
  let force = false, reminted = false;
  for (let i = 0; i < 5; i++) {
    const token = await accessToken(force); force = false;
    const r = await fetch(`${BASE}/admin/api/${API}/graphql.json`, {
      method: "POST", headers: { "Content-Type": "application/json", "X-Shopify-Access-Token": token }, body: JSON.stringify({ query, variables }),
    });
    if (r.status === 429) { await sleep(1500 * (i + 1)); continue; }
    if (r.status === 401 && !STATIC_TOKEN && !reminted) { reminted = true; force = true; continue; }   // token expired or revoked: mint a new one once
    if (r.status >= 500) { if (i < 2) { await sleep(1000 * (i + 1)); continue; } throw new Error(`Shopify ${r.status}`); }
    if (!r.ok) throw new Error(`Shopify ${r.status}: ${(await r.text()).slice(0, 200)}`);
    const b = await r.json();
    const errors: GqlError[] = b.errors ?? [];
    if (errors.length && throttled(errors)) { await sleep(2000 * (i + 1)); continue; }
    return { data: b.data ?? null, errors };
  }
  throw new Error("Shopify: troppe richieste (429)");
};

// the scopes the app has right now (re-read on every run: Nick may add some in the Dev Dashboard)
export async function scopes(q: Gql): Promise<Set<string>> {
  const r = await q(`query { currentAppInstallation { accessScopes { handle } } }`);
  if (r.errors.length) throw new Error(r.errors.map((e) => e.message).join("; "));
  return new Set((r.data?.currentAppInstallation?.accessScopes ?? []).map((x: { handle: string }) => x.handle));
}
