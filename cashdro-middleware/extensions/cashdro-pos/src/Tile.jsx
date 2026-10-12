/**
 * Tile.jsx — Smart Grid tile "Paga con CashDro"
 * Target: pos.home.tile.render
 *
 * Enabled only when the cart has a positive total; tapping it opens the
 * modal rendered by CheckoutExtension.jsx (pos.home.modal.render).
 */
import { render } from "preact";
import { useEffect, useState } from "preact/hooks";

function Tile() {
  const [total, setTotal] = useState(0);
  useEffect(() => {
    const read = (c) => setTotal(parseFloat(c?.grandTotal) || 0);
    read(shopify.cart.current ?? shopify.cart.value);
    const unsub = shopify.cart.subscribe?.(read);
    return () => (typeof unsub === "function" ? unsub() : undefined);
  }, []);

  return (
    <s-tile
      heading="Paga con CashDro"
      subheading={total > 0 ? `${total.toFixed(2).replace(".", ",")} € in contanti` : "Carrello vuoto"}
      enabled={total > 0}
      onClick={() => shopify.action.presentModal()}
    />
  );
}

export default async () => {
  render(<Tile />, document.body);
};
