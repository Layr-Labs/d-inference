// Numeric display helpers. Pure, no React, no I/O.

/** Whole-number count with thousands separators (1234 -> "1,234"). */
export function formatNumber(n: number): string {
  return new Intl.NumberFormat("en-US", { maximumFractionDigits: 0 }).format(n ?? 0);
}

/** Locale count with default separators (1234 -> "1,234"). */
export function formatCount(n: number): string {
  return n.toLocaleString();
}

/** Abbreviated count: 1234 -> "1.2K", 1_200_000 -> "1.2M". */
export function abbreviateNumber(n: number): string {
  const v = n ?? 0;
  if (Math.abs(v) < 1000) return String(Math.round(v));
  const units = [
    { v: 1_000_000_000, s: "B" },
    { v: 1_000_000, s: "M" },
    { v: 1_000, s: "K" },
  ];
  for (const u of units) {
    if (Math.abs(v) >= u.v) {
      const scaled = v / u.v;
      const str = scaled >= 100 ? scaled.toFixed(0) : scaled.toFixed(1);
      return `${str.replace(/\.0$/, "")}${u.s}`;
    }
  }
  return String(Math.round(v));
}

/** "N item" / "N items" — naive English pluralization. */
export function plural(n: number, word: string): string {
  return `${n} ${word}${n === 1 ? "" : "s"}`;
}

/** Clamp a percentage to [0, 100]. NaN/Infinity collapse to 0/100. */
export function clampPct(value: number): number {
  if (!Number.isFinite(value)) return value > 0 ? 100 : 0;
  return Math.max(0, Math.min(100, value));
}

/** Fraction (0..1) -> integer percent string, clamped ("0.5" -> "50%"). */
export function pct(fraction: number): string {
  return `${Math.round(clampPct((fraction ?? 0) * 100))}%`;
}

/** Round tokens-per-second to a tidy display number, "—" when absent. */
export function formatTps(tps?: number): string {
  if (!tps || !Number.isFinite(tps) || tps <= 0) return "—";
  return tps >= 100 ? tps.toFixed(0) : tps.toFixed(1);
}
