/**
 * Tile.jsx — Smart Grid tile "Pesa" (weighed cheese)
 * Target: pos.home.tile.render → opens WeighExtension.jsx
 */
import { render } from "preact";

function Tile() {
  return (
    <s-tile
      heading="Pesa"
      subheading="Formaggi a peso"
      enabled
      onClick={() => shopify.action.presentModal()}
    />
  );
}

export default async () => {
  render(<Tile />, document.body);
};
