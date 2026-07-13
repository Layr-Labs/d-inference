import { describe, expect, it } from "vitest";
import { calculateKVHeadroom, calculateModelAvailability } from "./model-capacity";

describe("model availability under load", () => {
  it("uses the stricter capacity count for accepting-now coverage", () => {
    expect(calculateModelAvailability(163, 145, 141)).toEqual({
      connected: 163,
      eligible: 145,
      accepting: 141,
      acceptingPct: 87,
    });
  });

  it("bounds alias-aggregated capacity by unique eligible nodes", () => {
    expect(calculateModelAvailability(163, 145, 190).accepting).toBe(145);
  });

  it("reports exhausted pooled capacity as zero accepting nodes", () => {
    expect(calculateModelAvailability(163, 145, 0).acceptingPct).toBe(0);
  });

  it("presents token budget as free KV headroom", () => {
    expect(calculateKVHeadroom(990, 1_000)).toBe(99);
    expect(calculateKVHeadroom(-50, 1_000)).toBe(0);
    expect(calculateKVHeadroom(10, 0)).toBeNull();
  });
});
