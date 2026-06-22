// Relative-time + duration display helpers. Pure, no React.

/**
 * Human relative time, title-case fallbacks: "just now", "5m ago", "Never".
 * Coarse granularity (minutes up). Used by API-key "last used" style fields.
 */
export function relativeTime(iso?: string): string {
  if (!iso) return "Never";
  const t = new Date(iso).getTime();
  if (Number.isNaN(t)) return "Never";
  const diff = Date.now() - t;
  if (diff < 60_000) return "just now";
  const min = Math.floor(diff / 60_000);
  if (min < 60) return `${min}m ago`;
  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr}h ago`;
  const day = Math.floor(hr / 24);
  if (day < 30) return `${day}d ago`;
  const mo = Math.floor(day / 30);
  if (mo < 12) return `${mo}mo ago`;
  return `${Math.floor(mo / 12)}y ago`;
}

/**
 * Human relative time with seconds granularity, lower-case fallback:
 * "4s ago", "3m ago", "never". Used by live dashboards (heartbeats).
 */
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
