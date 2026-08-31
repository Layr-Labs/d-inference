// Pure client-side derivations over the earnings rows. No React, no fetch.

import type { Earning } from "./types";

/**
 * Sentinel model id the coordinator writes for base-reward (floor draw)
 * credits. Real money, but not organic demand: it earns into the chart's
 * earnings line yet is excluded from the jobs/demand series.
 */
export const BASE_REWARD_MODEL = "base_reward";

export interface DayBucket {
  /** YYYY-MM-DD in local time. */
  day: string;
  micro: number;
  /** Number of earning rows (jobs served) that day — the demand series. */
  jobs: number;
}

function localDay(d: Date): string {
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const dd = String(d.getDate()).padStart(2, "0");
  return `${d.getFullYear()}-${m}-${dd}`;
}

// Zero-fill window guard: one row with a corrupt ancient timestamp must not
// emit decades of empty buckets. 731 covers two full years.
const MAX_BUCKETS = 731;

/**
 * Sum earnings per local day, ascending, with zero-filled gaps between the
 * first and last day so the trend chart doesn't skip quiet days.
 */
export function perDayTotals(earnings: Earning[]): DayBucket[] {
  const sums = new Map<string, { micro: number; jobs: number }>();
  for (const e of earnings) {
    const d = new Date(e.created_at);
    if (Number.isNaN(d.getTime())) continue;
    const day = localDay(d);
    const s = sums.get(day) ?? { micro: 0, jobs: 0 };
    s.micro += e.amount_micro_usd;
    if (e.model !== BASE_REWARD_MODEL) s.jobs += 1;
    sums.set(day, s);
  }
  if (sums.size === 0) return [];
  const days = [...sums.keys()].sort();
  const lastDay = days[days.length - 1];
  // Cursor days are noon-anchored: a DST jump at midnight moves noon by an
  // hour at most, so setDate(±1) always lands in the adjacent local day.
  const cursor = new Date(`${lastDay}T12:00:00`);
  cursor.setDate(cursor.getDate() - (MAX_BUCKETS - 1));
  const floor = localDay(cursor);
  const start = days[0] < floor ? floor : days[0];
  cursor.setTime(new Date(`${start}T12:00:00`).getTime());
  const out: DayBucket[] = [];
  let day = start;
  do {
    const s = sums.get(day);
    out.push({ day, micro: s?.micro ?? 0, jobs: s?.jobs ?? 0 });
    cursor.setDate(cursor.getDate() + 1);
    day = localDay(cursor);
  } while (day <= lastDay);
  return out;
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

/** Shared look-back options for the chart and the activity log. */
export const TIME_RANGES = [
  { label: "Last 7 days", days: 7 },
  { label: "Last 30 days", days: 30 },
  { label: "All time", days: 0 },
];

/**
 * Rows within a look-back window of `days` ending at `now`. `days` 0 keeps
 * everything, even rows with unparseable dates.
 */
export function filterByDays(
  earnings: Earning[],
  days: number,
  now: number,
): Earning[] {
  if (days <= 0) return earnings;
  const cutoff = now - days * 86_400_000;
  return earnings.filter((e) => new Date(e.created_at).getTime() >= cutoff);
}
