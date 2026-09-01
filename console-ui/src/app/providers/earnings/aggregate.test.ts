import { describe, it, expect } from "vitest";
import {
  oldestRowIso,
  perBucketTotals,
  perDayTotals,
  perModelSummary,
} from "./aggregate";
import { makeEarning } from "./testFixtures";

const DAY3 = "2025-05-03";
const DAY3_AT_9 = `${DAY3}T09:00:00`;
const DAY1_AT_10 = "2025-05-01T10:00:00";
const DAY2_AT_10 = "2025-05-02T10:00:00";
const BAD_DATE = "not-a-date";

describe("perDayTotals", () => {
  it("returns an empty array for no rows", () => {
    expect(perDayTotals([])).toEqual([]);
  });

  it("sums per local day and zero-fills gaps", () => {
    const rows = [
      makeEarning({ id: 1, amount_micro_usd: 100, created_at: DAY1_AT_10 }),
      makeEarning({ id: 2, amount_micro_usd: 50, created_at: "2025-05-01T22:00:00" }),
      makeEarning({ id: 3, amount_micro_usd: 70, created_at: DAY3_AT_9 }),
    ];
    const days = perDayTotals(rows);
    expect(days.map((d) => d.micro)).toEqual([150, 0, 70]);
    expect(days.map((d) => d.jobs)).toEqual([2, 0, 1]);
    expect(days[0].day).toBe("2025-05-01");
    expect(days[2].day).toBe(DAY3);
  });

  it("counts base_reward money but not its jobs (demand)", () => {
    const days = perDayTotals([
      makeEarning({ id: 1, amount_micro_usd: 70, created_at: DAY3_AT_9 }),
      makeEarning({
        id: 2,
        model: "base_reward",
        amount_micro_usd: 500,
        prompt_tokens: 0,
        completion_tokens: 0,
        created_at: DAY3_AT_9,
      }),
    ]);
    expect(days).toEqual([{ day: DAY3, micro: 570, jobs: 1 }]);
  });

  it("skips rows with unparseable dates", () => {
    const days = perDayTotals([
      makeEarning({ id: 1, created_at: BAD_DATE }),
      makeEarning({ id: 2, amount_micro_usd: 70, created_at: DAY3_AT_9 }),
    ]);
    expect(days).toEqual([{ day: DAY3, micro: 70, jobs: 1 }]);
  });

  it("caps the zero-fill window at two years and keeps the newest day", () => {
    // A corrupt epoch-era row must not emit decades of empty buckets.
    const days = perDayTotals([
      makeEarning({ id: 1, created_at: "1970-01-01T00:00:00" }),
      makeEarning({ id: 2, amount_micro_usd: 70, created_at: DAY3_AT_9 }),
    ]);
    expect(days).toHaveLength(731);
    expect(days[days.length - 1]).toEqual({ day: DAY3, micro: 70, jobs: 1 });
  });
});

describe("perModelSummary", () => {
  it("returns one summary per model, most-earned first", () => {
    const rows = [
      makeEarning({ id: 1, model: "a/small", amount_micro_usd: 10 }),
      makeEarning({ id: 2, model: "b/big", amount_micro_usd: 100 }),
      makeEarning({ id: 3, model: "a/small", amount_micro_usd: 20 }),
    ];
    expect(perModelSummary(rows).map((s) => s.model)).toEqual(["b/big", "a/small"]);
  });

  it("sums earnings, jobs, and tokens per model", () => {
    const rows = [
      makeEarning({
        id: 1, model: "a/small", amount_micro_usd: 10,
        prompt_tokens: 100, completion_tokens: 200,
        created_at: DAY1_AT_10,
      }),
      makeEarning({
        id: 2, model: "a/small", amount_micro_usd: 20,
        prompt_tokens: 50, completion_tokens: 50,
        created_at: "2025-05-03T10:00:00",
      }),
      makeEarning({ id: 3, model: "b/big", amount_micro_usd: 100 }),
    ];
    const [big, small] = perModelSummary(rows);
    expect(big.model).toBe("b/big");
    expect(small).toMatchObject({
      model: "a/small",
      micro: 30,
      jobs: 2,
      tokens: 400,
      lastActive: "2025-05-03T10:00:00",
    });
  });

  it("returns an empty array for no rows", () => {
    expect(perModelSummary([])).toEqual([]);
  });

  it("counts base_reward money but not its jobs", () => {
    const [s] = perModelSummary([
      makeEarning({
        id: 1,
        model: "base_reward",
        amount_micro_usd: 500,
        prompt_tokens: 0,
        completion_tokens: 0,
      }),
      makeEarning({
        id: 2,
        model: "base_reward",
        amount_micro_usd: 300,
        prompt_tokens: 0,
        completion_tokens: 0,
      }),
    ]);
    expect(s).toMatchObject({ model: "base_reward", micro: 800, jobs: 0 });
  });
});

describe("oldestRowIso", () => {
  it("returns null for no rows", () => {
    expect(oldestRowIso([])).toBeNull();
  });

  it("finds the oldest row regardless of order", () => {
    const rows = [
      makeEarning({ id: 1, created_at: "2025-05-03T09:00:00" }),
      makeEarning({ id: 2, created_at: DAY1_AT_10 }),
      makeEarning({ id: 3, created_at: DAY2_AT_10 }),
    ];
    expect(oldestRowIso(rows)).toBe(DAY1_AT_10);
  });

  it("skips rows with unparseable dates", () => {
    const rows = [
      makeEarning({ id: 1, created_at: BAD_DATE }),
      makeEarning({ id: 2, created_at: DAY2_AT_10 }),
    ];
    expect(oldestRowIso(rows)).toBe(DAY2_AT_10);
    expect(oldestRowIso([makeEarning({ created_at: BAD_DATE })])).toBeNull();
  });
});

describe("perBucketTotals", () => {
  it("returns empty day-mode series for no rows", () => {
    expect(perBucketTotals([])).toEqual({ granularity: "day", buckets: [] });
  });

  it("uses hour buckets when the window spans at most two days", () => {
    const { granularity, buckets } = perBucketTotals([
      makeEarning({ id: 1, amount_micro_usd: 100, created_at: "2025-05-01T10:15:00" }),
      makeEarning({ id: 2, amount_micro_usd: 50, created_at: "2025-05-01T10:45:00" }),
      makeEarning({ id: 3, amount_micro_usd: 70, created_at: "2025-05-01T13:30:00" }),
    ]);
    expect(granularity).toBe("hour");
    // 10:00 through 13:00 inclusive, gaps zero-filled.
    expect(buckets.map((b) => b.day)).toEqual([
      "2025-05-01T10",
      "2025-05-01T11",
      "2025-05-01T12",
      "2025-05-01T13",
    ]);
    expect(buckets.map((b) => b.micro)).toEqual([150, 0, 0, 70]);
    expect(buckets.map((b) => b.jobs)).toEqual([2, 0, 0, 1]);
  });

  it("keeps base_reward money out of hourly demand too", () => {
    const { buckets } = perBucketTotals([
      makeEarning({ id: 1, amount_micro_usd: 70, created_at: "2025-05-01T10:00:00" }),
      makeEarning({
        id: 2,
        model: "base_reward",
        amount_micro_usd: 500,
        created_at: "2025-05-01T11:00:00",
      }),
    ]);
    expect(buckets.map((b) => b.jobs)).toEqual([1, 0]);
    expect(buckets.map((b) => b.micro)).toEqual([70, 500]);
  });

  it("uses day buckets when the window spans more than two days", () => {
    const { granularity, buckets } = perBucketTotals([
      makeEarning({ id: 1, created_at: DAY1_AT_10 }),
      makeEarning({ id: 2, created_at: "2025-05-04T10:00:01" }),
    ]);
    expect(granularity).toBe("day");
    expect(buckets.map((b) => b.day)).toEqual([
      "2025-05-01",
      "2025-05-02",
      DAY3,
      "2025-05-04",
    ]);
  });

  it("ignores unparseable dates when measuring the span", () => {
    const { granularity } = perBucketTotals([
      makeEarning({ id: 1, created_at: BAD_DATE }),
      makeEarning({ id: 2, created_at: DAY1_AT_10 }),
      makeEarning({ id: 3, created_at: "2025-05-01T12:00:00" }),
    ]);
    expect(granularity).toBe("hour");
  });
});
