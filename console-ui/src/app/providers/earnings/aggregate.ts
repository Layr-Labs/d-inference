// Pure client-side derivations over the earnings rows. No React, no fetch.

import type { Earning } from "./types";

export interface DayBucket {
  /** YYYY-MM-DD in local time. */
  day: string;
  micro: number;
}

function localDay(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const dd = String(d.getDate()).padStart(2, "0");
  return `${d.getFullYear()}-${m}-${dd}`;
}

/**
 * Sum earnings per local day, ascending, with zero-filled gaps between the
 * first and last day so the trend chart doesn't skip quiet days.
 */
export function perDayTotals(earnings: Earning[]): DayBucket[] {
  const sums = new Map<string, number>();
  for (const e of earnings) {
    const day = localDay(e.created_at);
    if (!day) continue;
    sums.set(day, (sums.get(day) ?? 0) + e.amount_micro_usd);
  }
  if (sums.size === 0) return [];
  const days = [...sums.keys()].sort();
  const out: DayBucket[] = [];
  const cursor = new Date(`${days[0]}T00:00:00`);
  const last = new Date(`${days[days.length - 1]}T00:00:00`);
  while (cursor <= last) {
    const key = localDay(cursor.toISOString());
    out.push({ day: key, micro: sums.get(key) ?? 0 });
    cursor.setDate(cursor.getDate() + 1);
  }
  return out;
}

/** Distinct model ids, most-earned first. */
export function modelOptions(earnings: Earning[]): string[] {
  return perModelSummary(earnings).map((s) => s.model);
}

export interface ModelSummary {
  model: string;
  micro: number;
  jobs: number;
  tokens: number;
  /** ISO timestamp of the newest row for this model. */
  lastActive: string;
}

/** One summary per model, most-earned first. */
export function perModelSummary(earnings: Earning[]): ModelSummary[] {
  const byModel = new Map<string, ModelSummary>();
  for (const e of earnings) {
    const s = byModel.get(e.model) ?? {
      model: e.model,
      micro: 0,
      jobs: 0,
      tokens: 0,
      lastActive: e.created_at,
    };
    s.micro += e.amount_micro_usd;
    s.jobs += 1;
    s.tokens += e.prompt_tokens + e.completion_tokens;
    if (e.created_at > s.lastActive) s.lastActive = e.created_at;
    byModel.set(e.model, s);
  }
  return [...byModel.values()].sort((a, b) => b.micro - a.micro);
}

export interface HistoryFilter {
  /** Model id, or "" for all models. */
  model: string;
  /** Look-back window in days, or 0 for all time. */
  days: number;
}

/** Filter rows by model and by a look-back window ending at `now`. */
export function filterEarnings(
  earnings: Earning[],
  filter: HistoryFilter,
  now: number,
): Earning[] {
  const cutoff = filter.days > 0 ? now - filter.days * 86_400_000 : null;
  return earnings.filter((e) => {
    if (filter.model && e.model !== filter.model) return false;
    // No time window -> keep everything, even rows with unparseable dates.
    if (cutoff === null) return true;
    return new Date(e.created_at).getTime() >= cutoff;
  });
}

/**
 * "Showing the latest N of M" — only when the server truncated history
 * (lifetime `count` exceeds the returned `recent_count`).
 */
export function truncationNote(
  count: number,
  recentCount: number,
): { shown: number; total: number } | null {
  if (count > recentCount) return { shown: recentCount, total: count };
  return null;
}
