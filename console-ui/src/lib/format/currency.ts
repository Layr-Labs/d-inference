// USD / micro-USD formatting. The coordinator settles in integer micro-USD;
// the UI displays dollars. Centralizing the conversion + the several display
// variants kills the 5+ forked USD formatters (proposal F5).

export const MICRO_PER_USD = 1_000_000;

/** Integer micro-USD → USD float. */
export function microToUsd(micro: number): number {
  return (micro ?? 0) / MICRO_PER_USD;
}

/** "$1.23" — fixed decimals, no sign handling. */
export function formatUsd(usd: number, decimals = 2): string {
  return `$${usd.toFixed(decimals)}`;
}

/** Whole-dollar with thousands separators, signed. */
export function formatUsdWhole(usd: number): string {
  const abs = Math.abs(usd).toLocaleString(undefined, { maximumFractionDigits: 0 });
  return usd < 0 ? `-$${abs}` : `$${abs}`;
}

/**
 * Micro-USD → "$x.xx", keeping more precision for sub-cent amounts so tiny
 * per-request costs don't all collapse to "$0.00".
 */
export function formatUsdMicro(micro: number): string {
  const v = microToUsd(micro);
  if (v === 0) return "$0.00";
  if (Math.abs(v) < 0.01) return `$${v.toFixed(6)}`;
  return `$${v.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}
