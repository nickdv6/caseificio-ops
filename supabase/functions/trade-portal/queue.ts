// v1.10 (quality test 20/10, item 6): a wholesale order goes to Shopify once.
// Before, the queue was read with no claim and the result written afterwards: «Invia ora» pressed during the 18:25 run, or a run cut
// off after Shopify had completed the order, created the same order twice (net terms: two invoices). Now:
//   * the database hands each row to one run only (fabula.trade_queue_claim, «for update skip locked», a claim lasts 10 minutes);
//   * every draft carries the tag fq-<queue id>; before creating, the run looks for a draft with that tag and, if Shopify already has
//     it, completes it or reports the order it already became, instead of making another.
// The Shopify calls go through `gql`, passed in, so the test (queue_test.ts) runs with a fake Shopify.

// deno-lint-ignore no-explicit-any
export type Gql = (query: string, variables?: Record<string, unknown>) => Promise<any>;
export type Created = { draftId: string | null; orderId: string | null; name: string | null; existed: boolean };

export const queueTag = (id: string) => `fq-${id}`;

const userErr = (o: { userErrors?: { message: string; field?: string[] }[] }) =>
  (o?.userErrors ?? []).map((e) => `${(e.field ?? []).join(".")} ${e.message}`.trim()).join("; ");

// the draft (and the order it became) that an earlier run made for this queue row, if any
export async function findByTag(gql: Gql, tag: string) {
  const d = await gql(`query($q: String!) { draftOrders(first: 5, query: $q) { nodes { id name status tags order { id name } } } }`, { q: `tag:"${tag}"` });
  // deno-lint-ignore no-explicit-any
  const nodes = ((d?.draftOrders?.nodes ?? []) as any[]).filter((x) => (x.tags ?? []).includes(tag));   // the search is fuzzy: the tag must be there
  // deno-lint-ignore no-explicit-any
  const done = nodes.find((x: any) => x.order?.id);
  if (done) return { draftId: done.id as string, orderId: done.order.id as string, name: done.order.name as string, open: false };
  // deno-lint-ignore no-explicit-any
  const open = nodes.find((x: any) => x.status !== "COMPLETED");
  if (open) return { draftId: open.id as string, orderId: null, name: null, open: true };
  return null;
}

// create (or finish) the order for one queue row; `input` is the DraftOrderInput without the queue tag
export async function createOnce(gql: Gql, queueId: string, input: Record<string, unknown>): Promise<Created> {
  const tag = queueTag(queueId);
  const had = await findByTag(gql, tag);
  if (had && !had.open) return { draftId: had.draftId, orderId: had.orderId, name: had.name, existed: true };
  let draftId = had?.draftId ?? null;
  if (!draftId) {
    const tags = [...((input.tags as string[]) ?? []), tag];
    const d = await gql(`mutation($input: DraftOrderInput!) { draftOrderCreate(input: $input) { draftOrder { id name } userErrors { field message } } }`,
      { input: { ...input, tags } });
    const ue = userErr(d.draftOrderCreate); if (ue) throw new Error("draftOrderCreate: " + ue);
    draftId = d.draftOrderCreate.draftOrder.id as string;
  }
  const done = await gql(`mutation($id: ID!) { draftOrderComplete(id: $id, paymentPending: true) { draftOrder { id order { id name } } userErrors { field message } } }`, { id: draftId });
  const ue2 = userErr(done.draftOrderComplete); if (ue2) throw new Error("draftOrderComplete: " + ue2 + ` (bozza ${draftId})`);
  const o = done.draftOrderComplete.draftOrder.order;
  return { draftId, orderId: o?.id ?? null, name: o?.name ?? null, existed: !!had };
}
