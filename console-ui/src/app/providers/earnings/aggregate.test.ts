import { describe, it, expect } from "vitest";
import {
  filterEarnings,
  modelOptions,
  perDayTotals,
  perModelSummary,
  truncationNote,
} from "./aggregate";
import { FIXTURE_NOW, makeEarning, makeScenario } from "./testFixtures";

describe("perDayTotals", () => {
  it("returns an empty array for no rows", () => {
    expect(perDayTotals([])).toEqual([]);
  });

  it("sums per local day and zero-fills gaps", () => {
    const rows = [
      makeEarning({ id: 1, amount_micro_usd: 100, created_at: "2025-05-01T10:00:00" }),
      makeEarning({ id: 2, amount_micro_usd: 50, created_at: "2025-05-01T22:00:00" }),
      makeEarning({ id: 3, amount_micro_usd: 70, created_at: "2025-05-03T09:00:00" }),
    ];
    const days = perDayTotals(rows);
    expect(days.map((d) => d.micro)).toEqual([150, 0, 70]);
    expect(days[0].day).toBe("2025-05-01");
    expect(days[2].day).toBe("2025-05-03");
  });
});

describe("modelOptions", () => {
  it("returns distinct models, most-earned first", () => {
    const rows = [
      makeEarning({ id: 1, model: "a/small", amount_micro_usd: 10 }),
      makeEarning({ id: 2, model: "b/big", amount_micro_usd: 100 }),
      makeEarning({ id: 3, model: "a/small", amount_micro_usd: 20 }),
    ];
    expect(modelOptions(rows)).toEqual(["b/big", "a/small"]);
  });
});

describe("perModelSummary", () => {
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

describe("filterEarnings", () => {
  const rows = makeScenario("TYPICAL").earnings;

  it("passes everything through with no filter", () => {
    expect(filterEarnings(rows, { model: "", days: 0 }, FIXTURE_NOW)).toHaveLength(
      rows.length,
    );
  });

  it("filters by model", () => {
    const out = filterEarnings(
      rows,
      { model: "Qwen/Qwen3-30B-A3B", days: 0 },
      FIXTURE_NOW,
    );
    expect(out.length).toBeGreaterThan(0);
    expect(out.every((e) => e.model === "Qwen/Qwen3-30B-A3B")).toBe(true);
  });

  it("filters by look-back window", () => {
    const out = filterEarnings(rows, { model: "", days: 7 }, FIXTURE_NOW);
    expect(out.length).toBeGreaterThan(0);
    expect(out.length).toBeLessThan(rows.length);
    const cutoff = FIXTURE_NOW - 7 * 86_400_000;
    expect(out.every((e) => new Date(e.created_at).getTime() >= cutoff)).toBe(true);
  });
});

describe("truncationNote", () => {
  it("is null when everything fits", () => {
    expect(truncationNote(40, 40)).toBeNull();
    expect(truncationNote(0, 0)).toBeNull();
  });

  it("reports shown vs lifetime totals when the server truncated", () => {
    expect(truncationNote(4210, 100)).toEqual({ shown: 100, total: 4210 });
  });
});
