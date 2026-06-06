// Pure display helpers. No DB / React imports so they stay trivially testable.

export function formatNumber(n: number | string | null | undefined): string {
  if (n === null || n === undefined || n === "") return "—";
  const v = typeof n === "string" ? Number(n) : n;
  if (Number.isNaN(v)) return String(n);
  return v.toLocaleString("en-US");
}

/** micro-USD (1e-6 USD) integer → "$1.23" */
export function formatUSDFromMicro(micro: number | string | null | undefined): string {
  if (micro === null || micro === undefined || micro === "") return "—";
  const v = typeof micro === "string" ? Number(micro) : micro;
  if (Number.isNaN(v)) return String(micro);
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    minimumFractionDigits: 2,
    maximumFractionDigits: 6,
  }).format(v / 1_000_000);
}

export function formatDateTime(ts: string | Date | null | undefined): string {
  if (!ts) return "—";
  const d = ts instanceof Date ? ts : new Date(ts);
  if (Number.isNaN(d.getTime())) return String(ts);
  return d.toISOString().replace("T", " ").replace(/\.\d+Z$/, "Z");
}

/** Relative "3m ago" / "2d ago" from a timestamp. */
export function formatRelative(ts: string | Date | null | undefined): string {
  if (!ts) return "—";
  const d = ts instanceof Date ? ts : new Date(ts);
  if (Number.isNaN(d.getTime())) return String(ts);
  const secs = Math.floor((Date.now() - d.getTime()) / 1000);
  if (secs < 0) return "just now";
  if (secs < 60) return `${secs}s ago`;
  const mins = Math.floor(secs / 60);
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  const days = Math.floor(hrs / 24);
  return `${days}d ago`;
}

/** Online if a heartbeat landed within the timeout (coordinator uses ~90s). */
export const ONLINE_WINDOW_SECONDS = 90;
export function isOnline(lastSeen: string | Date | null | undefined): boolean {
  if (!lastSeen) return false;
  const d = lastSeen instanceof Date ? lastSeen : new Date(lastSeen);
  if (Number.isNaN(d.getTime())) return false;
  return Date.now() - d.getTime() < ONLINE_WINDOW_SECONDS * 1000;
}

export function truncate(s: string | null | undefined, n = 12): string {
  if (!s) return "—";
  return s.length <= n ? s : `${s.slice(0, n)}…`;
}

/** Human duration from seconds (number or pg bigint string): "45s", "2h 15m", "3d 4h". */
export function formatDuration(seconds: number | string | null | undefined): string {
  if (seconds === null || seconds === undefined || seconds === "") return "—";
  let s = typeof seconds === "string" ? Number(seconds) : seconds;
  if (Number.isNaN(s) || s < 0) return "—";
  s = Math.floor(s);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ${m % 60}m`;
  const d = Math.floor(h / 24);
  return `${d}d ${h % 24}h`;
}
