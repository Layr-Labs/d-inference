import type { ApiKey, KeyResetWindow } from "@/lib/api";

// API-key-specific presentation helpers. Generic formatters (USD, counts,
// relative time) come from the shared lib/format module — re-exported here so
// existing `./format` import sites in this folder are unchanged (proposal F5).
export { formatUsd, formatCount, plural, relativeTime } from "@/lib/format";

export function usageBarColor(pct: number): string {
  if (pct >= 100) return "bg-accent-red";
  if (pct >= 75) return "bg-accent-amber";
  return "bg-teal";
}

export function windowLabel(reset: KeyResetWindow): string {
  switch (reset) {
    case "daily":
      return "Daily";
    case "weekly":
      return "Weekly";
    case "monthly":
      return "Monthly";
    default:
      return "Lifetime";
  }
}

export function isExpired(key: ApiKey): boolean {
  if (!key.expires_at) return false;
  const t = new Date(key.expires_at).getTime();
  return !Number.isNaN(t) && t < Date.now();
}

export function keyStatus(key: ApiKey): { label: string; cls: string } {
  if (key.disabled) {
    return { label: "Disabled", cls: "text-text-tertiary bg-bg-tertiary border-border-subtle/40" };
  }
  if (isExpired(key)) {
    return { label: "Expired", cls: "text-accent-red bg-accent-red-dim border-accent-red/25" };
  }
  return { label: "Active", cls: "text-teal bg-teal/10 border-teal/30" };
}
