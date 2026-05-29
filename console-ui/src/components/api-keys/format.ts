import type { ApiKey, KeyResetWindow } from "@/lib/api";

// Pure presentation helpers for rendering API key state. No React, no I/O.

export function formatUsd(n: number, decimals = 2): string {
  return `$${n.toFixed(decimals)}`;
}

export function formatCount(n: number): string {
  return n.toLocaleString();
}

export function plural(n: number, word: string): string {
  return `${n} ${word}${n === 1 ? "" : "s"}`;
}

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
