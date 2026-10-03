import { expect, it } from 'vitest';
import {
  HOUR,
  HOURS,
  MAX_SAMPLE_INTERVAL,
  hourlyTokens,
  reportedHours,
} from '../src/renderer/features/machines/overview/hourlyTokens';
import type { ActivitySample } from '../src/shared/contracts';

// A local clock hour keeps bucket alignment independent of the test time zone.
const hour = new Date(2026, 9, 2, 14).getTime() / 1000;
const now = hour + 30 * 60;

function minuteSamples(from: number, to: number, perMinute: number, start = 0): ActivitySample[] {
  const samples: ActivitySample[] = [];
  for (let at = from, index = 0; at <= to; at += 60, index++)
    samples.push({ at, tokens: start + index * perMinute, requests: start / 100 + index });
  return samples;
}

it('returns the past 24 local clock hours ending with the current hour', () => {
  const buckets = hourlyTokens([], now);
  expect(buckets).toHaveLength(HOURS);
  expect(buckets.at(-1)!.start).toBe(hour);
  expect(buckets[0].start).toBe(hour - 23 * HOUR);
  expect(buckets.every((bucket) => bucket.tokens === null && bucket.requests === null)).toBe(true);
});

it('sums counter deltas into their hour and keeps an observed idle hour at zero', () => {
  const busy = minuteSamples(hour - HOUR, hour, 1000);
  const idle = minuteSamples(hour + 60, now, 0, 60_000).map((sample) => ({
    ...sample,
    requests: 60,
  }));
  const buckets = hourlyTokens([...busy, ...idle], now);
  expect(buckets.at(-2)).toEqual({
    start: hour - HOUR,
    tokens: 60_000,
    requests: 60,
    observed: HOUR,
  });
  expect(buckets.at(-1)).toEqual({ start: hour, tokens: 0, requests: 0, observed: 30 * 60 });
  expect(buckets.at(-3)!.tokens).toBeNull();
});

it('leaves hours without observations as gaps, not zero', () => {
  const morning = minuteSamples(hour - 3 * HOUR, hour - 2 * HOUR, 500);
  const afternoon = minuteSamples(hour - HOUR / 2, now, 200, 90_000);
  const buckets = hourlyTokens([...morning, ...afternoon], now);
  expect(buckets.at(-4)).toMatchObject({ tokens: 30_000, observed: HOUR });
  expect(buckets.at(-3)).toMatchObject({ tokens: null, requests: null, observed: 0 });
  expect(buckets.at(-2)).toMatchObject({ tokens: 6000, observed: HOUR / 2 });
  expect(buckets.at(-1)).toMatchObject({ tokens: 6000, observed: HOUR / 2 });
});

it('attributes an interval up to the sampling limit and drops a longer one', () => {
  const samples = [
    { at: hour, tokens: 0, requests: 0 },
    { at: hour + MAX_SAMPLE_INTERVAL, tokens: 500, requests: 5 },
    { at: hour + 2 * MAX_SAMPLE_INTERVAL + 1, tokens: 9000, requests: 90 },
  ];
  expect(hourlyTokens(samples, now).at(-1)).toMatchObject({
    tokens: 500,
    requests: 5,
    observed: MAX_SAMPLE_INTERVAL,
  });
});

it('counts a decreased counter as a restart from zero', () => {
  const samples = [
    { at: hour + 60, tokens: 5000, requests: 5 },
    { at: hour + 120, tokens: 5600, requests: 6 },
    { at: hour + 180, tokens: 300, requests: 1 },
    { at: hour + 240, tokens: 700, requests: 2 },
  ];
  expect(hourlyTokens(samples, now).at(-1)).toMatchObject({ tokens: 1300, requests: 3 });
});

it('splits an interval that spans an hour boundary', () => {
  const samples = [
    { at: hour - 30, tokens: 0, requests: 0 },
    { at: hour + 30, tokens: 600, requests: 2 },
  ];
  const buckets = hourlyTokens(samples, now);
  expect(buckets.at(-2)).toMatchObject({ tokens: 300, requests: 1, observed: 30 });
  expect(buckets.at(-1)).toMatchObject({ tokens: 300, requests: 1, observed: 30 });
});

it('ignores reversed timestamps and samples outside the window', () => {
  const samples = [
    { at: hour - 25 * HOUR, tokens: 0, requests: 0 },
    { at: hour - 25 * HOUR + 60, tokens: 999, requests: 9 },
    { at: hour + 60, tokens: 1000, requests: 10 },
    { at: hour + 120, tokens: 1100, requests: 11 },
    { at: hour + 100, tokens: 1200, requests: 12 },
    { at: hour + 160, tokens: 1300, requests: 13 },
    { at: now + 60, tokens: 1400, requests: 14 },
    { at: now + 120, tokens: 1500, requests: 15 },
  ];
  const buckets = hourlyTokens(samples, now);
  expect(buckets.at(-1)).toMatchObject({ tokens: 200, requests: 2, observed: 120 });
  expect(buckets.slice(0, -1).every((bucket) => bucket.tokens === null)).toBe(true);
});

it('aligns reported hourly totals to the hour of the observation and pads missing hours', () => {
  const buckets = reportedHours([1200, null, 900], now);
  expect(buckets).toHaveLength(HOURS);
  expect(buckets.at(-1)).toEqual({ start: hour, tokens: 900, requests: null, observed: 30 * 60 });
  expect(buckets.at(-2)).toEqual({ start: hour - HOUR, tokens: null, requests: null, observed: 0 });
  expect(buckets.at(-3)).toMatchObject({ start: hour - 2 * HOUR, tokens: 1200, observed: HOUR });
  expect(buckets.slice(0, -3).every((bucket) => bucket.tokens === null)).toBe(true);
  expect(
    reportedHours(
      Array.from({ length: 30 }, (_, i) => i),
      now,
    )[0].tokens,
  ).toBe(6);
});
