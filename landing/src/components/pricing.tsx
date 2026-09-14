"use client";

import { useEffect, useState } from "react";
import { API_URL, CONSOLE_URL } from "../lib/links";
import { FALLBACK_PRICES, parsePricing } from "../lib/pricing";
import { Arrow } from "./ui";

const priceFormat = new Intl.NumberFormat("en-US", {
  style: "currency",
  currency: "USD",
  minimumFractionDigits: 2,
  maximumFractionDigits: 4,
});

export function Pricing() {
  const [rows, setRows] = useState(FALLBACK_PRICES);
  const [live, setLive] = useState(false);

  useEffect(() => {
    const controller = new AbortController();
    const timeout = window.setTimeout(() => controller.abort(), 8000);
    async function refresh() {
      try {
        const responses = await Promise.all(
          ["/v1/models/catalog", "/v1/pricing"].map((path) =>
            fetch(`${API_URL}${path}`, {
              signal: controller.signal,
              headers: { Accept: "application/json" },
            }),
          ),
        );
        if (responses.some((response) => !response.ok)) return;
        const [catalog, prices]: unknown[] = await Promise.all(
          responses.map((response) => response.json()),
        );
        const current = parsePricing(catalog, prices);
        if (current.length && !controller.signal.aborted) {
          setRows(current);
          setLive(true);
        }
      } catch {
        // Reference prices remain available when the public API is unreachable.
      } finally {
        window.clearTimeout(timeout);
      }
    }
    void refresh();
    return () => {
      controller.abort();
      window.clearTimeout(timeout);
    };
  }, []);

  return (
    <div className="pricing-panel">
      <div className="pricing-toolbar">
        <span className="small-label">TEXT INFERENCE</span>
        <span className="price-status">
          {live && <span className="status-dot" />}
          {live ? "Live catalog prices" : "Reference prices"}
        </span>
      </div>
      <div
        className="table-scroll"
        tabIndex={0}
        role="region"
        aria-label="Model pricing, scroll horizontally on small screens"
      >
        <table className="pricing-table">
          <caption className="sr-only">
            Prices in US dollars per million tokens
          </caption>
          <thead>
            <tr>
              <th scope="col">Model</th>
              <th scope="col">Input / 1M tokens</th>
              <th scope="col">Output / 1M tokens</th>
              <th scope="col">
                <span className="sr-only">Get started</span>
              </th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <tr key={row.id}>
                <th scope="row">
                  {row.name}
                  <span>
                    {row.context
                      ? `${Math.round(row.context / 1024)}K context`
                      : row.id}
                  </span>
                </th>
                <td>{priceFormat.format(row.input)}</td>
                <td className="output-price">
                  {priceFormat.format(row.output)}
                </td>
                <td>
                  <a
                    href={CONSOLE_URL}
                    aria-label={`Start building with ${row.name}`}
                  >
                    <Arrow diagonal />
                  </a>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="pricing-note">
        {live
          ? "Fetched from the public model catalog. Availability varies with network capacity."
          : "Reference rates shown while live pricing is unavailable. Check the console for current rates and model availability."}
      </p>
    </div>
  );
}
