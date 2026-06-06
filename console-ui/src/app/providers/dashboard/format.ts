// Formatting helpers for the provider dashboard. Pure functions, no React,
// so they can be unit-tested and reused across every card/section.

/** Format micro-USD as a dollar string. Small amounts keep more precision. */
export function formatUSD(microUSD: number): string {
  const v = (microUSD ?? 0) / 1_000_000;
  if (v === 0) return "$0.00";
  if (Math.abs(v) < 0.01) return `$${v.toFixed(6)}`;
  return `$${v.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

/** Human relative time ("4s ago", "3m ago", "2h ago", "5d ago"). */
export function formatRelative(iso?: string): string {
  if (!iso) return "never";
  const t = new Date(iso).getTime();
  if (!Number.isFinite(t)) return "never";
  const seconds = Math.max(0, Math.floor((Date.now() - t) / 1000));
  if (seconds < 60) return `${seconds}s ago`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 48) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  return `${days}d ago`;
}

/** Whole-number count with thousands separators. */
export function formatNumber(n: number): string {
  return new Intl.NumberFormat("en-US", { maximumFractionDigits: 0 }).format(n ?? 0);
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

/** Mask a hardware serial, keeping the first 4 and last 2 chars. */
export function maskSerial(serial?: string): string {
  if (!serial) return "";
  if (serial.length <= 6) return serial;
  return serial.slice(0, 4) + "•".repeat(Math.min(6, serial.length - 6)) + serial.slice(-2);
}

/** Last path segment of a model id (org/name -> name). */
export function shortModelName(model: string): string {
  if (!model) return model;
  return model.split("/").pop() || model;
}

/** Fraction (0..1) -> integer percent string, clamped. */
export function pct(fraction: number): string {
  return `${Math.round(clampPct((fraction ?? 0) * 100))}%`;
}

/** Clamp a percentage to [0, 100]. NaN/Infinity collapse to 0/100. */
export function clampPct(value: number): number {
  if (!Number.isFinite(value)) return value > 0 ? 100 : 0;
  return Math.max(0, Math.min(100, value));
}

/** Round tokens-per-second to a tidy display number. */
export function formatTps(tps?: number): string {
  if (!tps || !Number.isFinite(tps) || tps <= 0) return "—";
  return tps >= 100 ? tps.toFixed(0) : tps.toFixed(1);
}

/** Seconds -> compact uptime ("3d 4h", "5h 12m", "8m"). */
export function humanizeUptime(seconds?: number): string {
  const s = seconds ?? 0;
  if (s <= 0) return "—";
  const days = Math.floor(s / 86_400);
  const hours = Math.floor((s % 86_400) / 3_600);
  const minutes = Math.floor((s % 3_600) / 60);
  if (days > 0) return `${days}d ${hours}h`;
  if (hours > 0) return `${hours}h ${minutes}m`;
  if (minutes > 0) return `${minutes}m`;
  return `${s}s`;
}
