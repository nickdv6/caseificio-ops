// deno test supabase/functions/trade-portal/queue_test.ts — v1.10 (quality test 20/10, item 6): a queue row becomes one Shopify order
import { createOnce, findByTag, queueTag } from "./queue.ts";
function assertEquals(a: unknown, b: unknown) { const x = JSON.stringify(a), y = JSON.stringify(b); if (x !== y) throw new Error(`expected ${y}\n     got ${x}`); }

// a fake Shopify: draft orders with tags; completing one makes an order
// deno-lint-ignore no-explicit-any
function fakeShopify(drafts: any[] = []) {
  const calls: string[] = [];
  let n = drafts.length;
  // deno-lint-ignore no-explicit-any
  const gql = (query: string, v: Record<string, any> = {}) => {
    if (query.includes("draftOrders(")) {
      calls.push("search");
      const tag = String(v.q).match(/tag:"([^"]+)"/)?.[1];
      // the real search is fuzzy: it may return drafts whose tags only look alike
      return Promise.resolve({ draftOrders: { nodes: drafts.filter((d) => d.tags.some((t: string) => t.startsWith(String(tag).slice(0, 6)))) } });
    }
    if (query.includes("draftOrderCreate")) {
      calls.push("create");
      const d = { id: `gid://shopify/DraftOrder/${++n}`, name: `#D${n}`, status: "OPEN", tags: v.input.tags, order: null };
      drafts.push(d);
      return Promise.resolve({ draftOrderCreate: { draftOrder: { id: d.id, name: d.name }, userErrors: [] } });
    }
    if (query.includes("draftOrderComplete")) {
      calls.push("complete");
      const d = drafts.find((x) => x.id === v.id);
      d.status = "COMPLETED"; d.order = { id: `gid://shopify/Order/${d.id.split("/").pop()}`, name: `#100${d.id.split("/").pop()}` };
      return Promise.resolve({ draftOrderComplete: { draftOrder: { id: d.id, order: d.order }, userErrors: [] } });
    }
    throw new Error("unexpected query " + query.slice(0, 40));
  };
  return { gql, calls, drafts };
}
const input = { lineItems: [], tags: ["professionisti", "piano-consegne"] };

Deno.test("a new row: one draft with the queue tag, completed", async () => {
  const s = fakeShopify();
  const r = await createOnce(s.gql, "q-1", input);
  assertEquals(s.calls, ["search", "create", "complete"]);
  assertEquals(s.drafts[0].tags.includes(queueTag("q-1")), true);
  assertEquals([r.orderId, r.existed], ["gid://shopify/Order/1", false]);
});

Deno.test("sent again after the order was made (a run cut off, a lost reply): the same order, nothing created", async () => {
  const s = fakeShopify();
  await createOnce(s.gql, "q-2", input);
  const again = await createOnce(s.gql, "q-2", input);
  assertEquals(s.drafts.length, 1);
  assertEquals([again.orderId, again.existed], ["gid://shopify/Order/1", true]);
});

Deno.test("a draft left open by a failed «complete»: completed, not a second draft", async () => {
  const s = fakeShopify([{ id: "gid://shopify/DraftOrder/7", name: "#D7", status: "OPEN", tags: ["professionisti", queueTag("q-3")], order: null }]);
  const r = await createOnce(s.gql, "q-3", input);
  assertEquals(s.calls, ["search", "complete"]);
  assertEquals([s.drafts.length, r.draftId, r.existed], [1, "gid://shopify/DraftOrder/7", true]);
});

Deno.test("another row's draft that the fuzzy search returns is not taken", async () => {
  const s = fakeShopify([{ id: "gid://shopify/DraftOrder/9", name: "#D9", status: "COMPLETED", tags: [queueTag("q-4-other")], order: { id: "gid://shopify/Order/9", name: "#1009" } }]);
  const found = await findByTag(s.gql, queueTag("q-4"));
  assertEquals(found, null);
  const r = await createOnce(s.gql, "q-4", input);
  assertEquals([s.drafts.length, r.existed], [2, false]);
});
