import type { ActivitySample } from '../../../../shared/contracts';

export interface HourBucket {
  // Epoch seconds at the start of the local clock hour.
  start: number;
  // Null when no sample interval covers any part of the hour: a gap, not zero.
  tokens: number | null;
  requests: number | null;
  // Seconds of the hour covered by sample intervals.
  observed: number;
}

export const HOUR = 3600;
export const HOURS = 24;
// The runtime samples about once a minute while it observes the provider; a
// longer interval means it was not observing (asleep, stopped or disconnected).
export const MAX_SAMPLE_INTERVAL = 600;

const hourStart = (at: number) => {
  const date = new Date(at * 1000);
  date.setMinutes(0, 0, 0);
  return date.getTime() / 1000;
};

// Buckets already aggregated elsewhere; the last value is the hour containing `at`.
export function reportedHours(values: (number | null)[], at: number): HourBucket[] {
  const last = hourStart(at);
  return Array.from({ length: HOURS }, (_, index) => {
    const tokens = values[values.length - HOURS + index] ?? null;
    const start = last - (HOURS - 1 - index) * HOUR;
    return tokens === null
      ? { start, tokens: null, requests: null, observed: 0 }
      : { start, tokens, requests: null, observed: Math.min(HOUR, at - start) };
  });
}

// The past 24 local clock hours, ending with the current partial hour. Counter
// deltas between consecutive samples are split across the hours they span; a
// counter that decreased restarted from zero, so its new value is the delta.
export function hourlyTokens(samples: ActivitySample[], now: number): HourBucket[] {
  const first = hourStart(now) - (HOURS - 1) * HOUR;
  const sums = Array.from({ length: HOURS }, (_, index) => ({
    start: first + index * HOUR,
    tokens: 0,
    requests: 0,
    observed: 0,
  }));
  for (let index = 1; index < samples.length; index++) {
    const before = samples[index - 1];
    const after = samples[index];
    const span = after.at - before.at;
    if (!(span > 0 && span <= MAX_SAMPLE_INTERVAL)) continue;
    const reset = after.tokens < before.tokens || after.requests < before.requests;
    const tokens = reset ? after.tokens : after.tokens - before.tokens;
    const requests = reset ? after.requests : after.requests - before.requests;
    const from = Math.max(before.at, first);
    const to = Math.min(after.at, now);
    for (let hour = Math.floor((from - first) / HOUR); hour < HOURS; hour++) {
      const bucket = sums[hour];
      if (bucket.start >= to) break;
      const overlap = Math.min(to, bucket.start + HOUR) - Math.max(from, bucket.start);
      if (overlap <= 0) continue;
      bucket.tokens += (tokens * overlap) / span;
      bucket.requests += (requests * overlap) / span;
      bucket.observed += overlap;
    }
  }
  return sums.map(({ start, tokens, requests, observed }) =>
    observed > 0
      ? { start, tokens: Math.round(tokens), requests: Math.round(requests), observed }
      : { start, tokens: null, requests: null, observed: 0 },
  );
}
