import { describe, it, expect } from "vitest";
import { filterByDays, perDayTotals, perModelSummary } from "./aggregate";
import { FIXTURE_NOW, makeEarning, makeScenario } from "./testFixtures";

const DAY3 = "2025-05-03";
const DAY3_AT_9 = `${DAY3}T09:00:00`;

describe("perDayTotals", () => {
  it("returns an empty array for no rows", () => {
    expect(perDayTotals([])).toEqual([]);
  });

  it("sums per local day and zero-fills gaps", () => {
    const rows = [
      makeEarning({ id: 1, amount_micro_usd: 100, created_at: "2025-05-01T10:00:00" }),
      makeEarning({ id: 2, amount_micro_usd: 50, created_at: "2025-05-01T22:00:00" }),
      makeEarning({ id: 3, amount_micro_usd: 70, created_at: DAY3_AT_9 }),
    ];
    const days = perDayTotals(rows);
    expect(days.map((d) => d.micro)).toEqual([150, 0, 70]);
    expect(days[0].day).toBe("2025-05-01");
    expect(days[2].day).toBe(DAY3);
  });

  it("skips rows with unparseable dates", () => {
    const days = perDayTotals([
      makeEarning({ id: 1, created_at: "not-a-date" }),
      makeEarning({ id: 2, amount_micro_usd: 70, created_at: DAY3_AT_9 }),
    ]);
    expect(days).toEqual([{ day: DAY3, micro: 70 }]);
  });

  it("caps the zero-fill window at two years and keeps the newest day", () => {
    // A corrupt epoch-era row must not emit decades of empty buckets.
    const days = perDayTotals([
      makeEarning({ id: 1, created_at: "1970-01-01T00:00:00" }),
      makeEarning({ id: 2, amount_micro_usd: 70, created_at: DAY3_AT_9 }),
    ]);
    expect(days).toHaveLength(731);
    expect(days[days.length - 1]).toEqual({ day: DAY3, micro: 70 });
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
        created_at: "2025-05-01T10:00:00",
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
});

describe("filterByDays", () => {
  const rows = makeScenario("TYPICAL").earnings;

  it("passes everything through with a 0-day window", () => {
    expect(filterByDays(rows, 0, FIXTURE_NOW)).toHaveLength(rows.length);
  });

  it("keeps only rows inside the look-back window", () => {
    const out = filterByDays(rows, 7, FIXTURE_NOW);
    expect(out.length).toBeGreaterThan(0);
    expect(out.length).toBeLessThan(rows.length);
    const cutoff = FIXTURE_NOW - 7 * 86_400_000;
    expect(out.every((e) => new Date(e.created_at).getTime() >= cutoff)).toBe(true);
  });
});
