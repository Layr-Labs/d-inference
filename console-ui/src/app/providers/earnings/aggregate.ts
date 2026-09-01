// Pure client-side derivations over the earnings rows. No React, no fetch.

import type { Earning } from "./types";

/**
 * Sentinel model id the coordinator writes for base-reward (floor draw)
 * credits. Real money, but not organic demand: it earns into the chart's
 * earnings line yet is excluded from the jobs/demand series.
 */
export const BASE_REWARD_MODEL = "base_reward";

export interface DayBucket {
  /** Bucket key in local time: "YYYY-MM-DD" (day) or "YYYY-MM-DDTHH" (hour). */
  day: string;
  micro: number;
  /** Number of earning rows (jobs served) in the bucket — the demand series. */
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
    // base_reward rows add money but are not inference jobs (mirrors the
    // coordinator's lifetime summary and perDayTotals' demand series).
    if (e.model !== BASE_REWARD_MODEL) s.jobs += 1;
    s.tokens += e.prompt_tokens + e.completion_tokens;
    if (e.created_at > s.lastActive) s.lastActive = e.created_at;
    byModel.set(e.model, s);
  }
  return [...byModel.values()].sort((a, b) => b.micro - a.micro);
}

export type Granularity = "hour" | "day";

export interface EarningsSeries {
  granularity: Granularity;
  buckets: DayBucket[];
}

// A fetched window at or below this span charts per hour: a busy provider's
// latest 1000 rows can fit in a day, where day buckets would leave no trend.
const HOUR_MODE_MAX_MS = 48 * 3_600_000;

function localHourKey(d: Date): string {
  return `${localDay(d)}T${String(d.getHours()).padStart(2, "0")}`;
}

/** Sum earnings per local hour, ascending, zero-filling gaps. */
function perHourTotals(earnings: Earning[]): DayBucket[] {
  const sums = new Map<string, { micro: number; jobs: number }>();
  let minMs = Infinity;
  let maxMs = -Infinity;
  for (const e of earnings) {
    const d = new Date(e.created_at);
    const t = d.getTime();
    if (Number.isNaN(t)) continue;
    minMs = Math.min(minMs, t);
    maxMs = Math.max(maxMs, t);
    const key = localHourKey(d);
    const s = sums.get(key) ?? { micro: 0, jobs: 0 };
    s.micro += e.amount_micro_usd;
    if (e.model !== BASE_REWARD_MODEL) s.jobs += 1;
    sums.set(key, s);
  }
  if (sums.size === 0) return [];
  const cursor = new Date(minMs);
  cursor.setMinutes(0, 0, 0);
  const lastKey = localHourKey(new Date(maxMs));
  const out: DayBucket[] = [];
  // Step in real ms so a DST jump can't loop, but bound on the local key so a
  // half-hour DST shift can't drop the final bucket; a fall-back hour repeats
  // its key, so skip the duplicate (its rows already merged in `sums`).
  for (let ms = cursor.getTime(); ; ms += 3_600_000) {
    const key = localHourKey(new Date(ms));
    if (key > lastKey) break;
    if (out.length > 0 && out[out.length - 1].day === key) continue;
    const s = sums.get(key);
    out.push({ day: key, micro: s?.micro ?? 0, jobs: s?.jobs ?? 0 });
  }
  return out;
}

/**
 * Bucket the fetched window at a granularity that fits its span: hour buckets
 * up to two days, day buckets beyond. The window is whatever the server
 * returned (latest N rows), so the chart self-scales to busy and quiet
 * providers alike.
 */
export function perBucketTotals(earnings: Earning[]): EarningsSeries {
  let minMs = Infinity;
  let maxMs = -Infinity;
  for (const e of earnings) {
    const t = new Date(e.created_at).getTime();
    if (Number.isNaN(t)) continue;
    minMs = Math.min(minMs, t);
    maxMs = Math.max(maxMs, t);
  }
  if (minMs !== Infinity && maxMs - minMs <= HOUR_MODE_MAX_MS) {
    return { granularity: "hour", buckets: perHourTotals(earnings) };
  }
  return { granularity: "day", buckets: perDayTotals(earnings) };
}

/** ISO timestamp of the oldest parseable row, or null when there is none. */
export function oldestRowIso(earnings: Earning[]): string | null {
  let oldest: string | null = null;
  let oldestMs = Infinity;
  for (const e of earnings) {
    const t = new Date(e.created_at).getTime();
    if (Number.isNaN(t) || t >= oldestMs) continue;
    oldestMs = t;
    oldest = e.created_at;
  }
  return oldest;
}
