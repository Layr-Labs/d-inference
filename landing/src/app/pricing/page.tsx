import type { Metadata } from "next";
import { PublicPage } from "../../components/PublicPage";
import { formatPrice, getPricingSnapshot, pricingExplanation, pricingSource } from "../../content/pricing";

export const metadata: Metadata = { title: "Pricing", description: "Current public Darkbloom inference rates, with token units and retrieval time.", alternates: { canonical: "/pricing", types: { "text/markdown": "/pricing.md" } } };
export const dynamic = "force-dynamic";

export default async function PricingPage() {
  const snapshot = await getPricingSnapshot();
  return <PublicPage title="Inference pricing" introduction={pricingExplanation}>
    <p><a href={pricingSource}>Public pricing source</a> · <a href="/pricing.md">Read as Markdown</a></p>
    {snapshot.available ? <>
      <p>Retrieved at <time dateTime={snapshot.retrievedAt}>{snapshot.retrievedAt}</time>. This is the retrieval time, not the source&apos;s last-updated time.</p>
      <div className="public-table-scroll"><table>
        <caption>USD per million tokens</caption>
        <thead><tr><th scope="col">Model</th><th scope="col">Input</th><th scope="col">Output</th><th scope="col">Cache read</th></tr></thead>
        <tbody>{snapshot.rows.map((row, index) => <tr key={`${row.model}-${index}`}><th scope="row">{row.model}</th><td>{formatPrice(row.input)}</td><td>{formatPrice(row.output)}</td><td>{formatPrice(row.cacheRead)}</td></tr>)}</tbody>
      </table></div>
      {!snapshot.rows.length && <p>No model-specific rates were returned by the pricing source.</p>}
      <h2>Fallback rates</h2>
      <p>Where the API applies a fallback rate: input {formatPrice(snapshot.fallback.input)}, output {formatPrice(snapshot.fallback.output)}, and cache read {formatPrice(snapshot.fallback.cacheRead)} per million tokens.</p>
    </> : <p role="status">Current rates are unavailable. Check the public pricing source or try again later.</p>}
    <h2>Using the API</h2>
    <p>Model-specific pricing does not guarantee a model is available to serve a request. Use the authenticated model list to discover models, and check your account balance in the Console before sending paid inference requests.</p>
    <p><a href="/developers">Developer guide</a> · <a href="https://console.darkbloom.dev/">Open Console</a></p>
  </PublicPage>;
}
