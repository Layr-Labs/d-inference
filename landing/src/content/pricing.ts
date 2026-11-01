import { publicLinks } from "./public-site";

export const pricingSource = `${publicLinks.apiBase}/pricing`;
export const pricingExplanation = "Rates are USD per million tokens. Input, output and cache-read tokens have separate rates. Paid fleet inference requires a funded account. Rates and model availability can change; custom provider arrangements may differ.";
export type PriceRow = { model: string; input: number; output: number; cacheRead: number };
export type PricingSnapshot =
  | { available: true; retrievedAt: string; rows: PriceRow[]; fallback: Omit<PriceRow, "model"> }
  | { available: false };

function isPrice(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

export function formatPrice(microUsd: number): string {
  return `$${(microUsd / 1_000_000).toFixed(6).replace(/0+$/, "").replace(/\.$/, ".00")}`;
}

export async function getPricingSnapshot(): Promise<PricingSnapshot> {
  const base = (process.env.DARKBLOOM_API_BASE_URL ?? publicLinks.apiBase).replace(/\/$/, "");
  try {
    const response = await fetch(`${base}/pricing`, {
      cache: "no-store",
      headers: { accept: "application/json" },
      signal: AbortSignal.timeout(5_000),
    });
    if (!response.ok) return { available: false };
    const data = await response.json();
    if (!Array.isArray(data.prices) || !isPrice(data.fallback_input_price) || !isPrice(data.fallback_output_price) || !isPrice(data.fallback_cache_read_price)) return { available: false };
    const rows: PriceRow[] = [];
    for (const row of data.prices) {
      if (!row || typeof row.model !== "string" || !row.model.trim() || !isPrice(row.input_price) || !isPrice(row.output_price) || !isPrice(row.cache_read_price)) return { available: false };
      rows.push({ model: row.model, input: row.input_price, output: row.output_price, cacheRead: row.cache_read_price });
    }
    return {
      available: true,
      retrievedAt: new Date().toISOString(),
      rows,
      fallback: { input: data.fallback_input_price, output: data.fallback_output_price, cacheRead: data.fallback_cache_read_price },
    };
  } catch {
    return { available: false };
  }
}

export async function getPricingMarkdown(): Promise<string> {
  const snapshot = await getPricingSnapshot();
  const lines = ["# Darkbloom pricing", "", pricingExplanation, "", `[Public pricing source](${pricingSource})`, ""];
  if (!snapshot.available) return [...lines, "Current rates are unavailable. Check the public pricing source or try again later.", "", "[Developers](https://darkbloom.ai/developers.md) | [Home](https://darkbloom.ai/)", ""].join("\n");
  lines.push(`Retrieved at: ${snapshot.retrievedAt}. This is the retrieval time, not the source's last-updated time.`, "", "| Model | Input | Output | Cache read |", "| --- | ---: | ---: | ---: |");
  for (const row of snapshot.rows) lines.push(`| ${row.model.replace(/[|\r\n]/g, " ")} | ${formatPrice(row.input)} | ${formatPrice(row.output)} | ${formatPrice(row.cacheRead)} |`);
  lines.push("", "## Fallback rates", "", `Input: ${formatPrice(snapshot.fallback.input)}. Output: ${formatPrice(snapshot.fallback.output)}. Cache read: ${formatPrice(snapshot.fallback.cacheRead)}. All rates are USD per million tokens.`, "", "[Developers](https://darkbloom.ai/developers.md) | [Home](https://darkbloom.ai/)", "");
  return lines.join("\n");
}
