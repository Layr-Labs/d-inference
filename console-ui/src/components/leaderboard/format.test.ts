import { describe, it, expect } from "vitest";
import {
  formatEarningsBreakdown,
  formatNumber,
  formatUSDFromMicro,
  rewardToneClass,
} from "./format";

// A tiny stub matching the shape of `formatUSDFromMicro` so the breakdown
// logic can be tested without the real number formatter.
const usd = (micro: number) => `$${(micro / 1_000_000).toFixed(2)}`;

describe("formatEarningsBreakdown", () => {
  it("labels work and rewards in order", () => {
    expect(formatEarningsBreakdown(1_200_000, 300_000, usd)).toBe(
      "Work $1.20 · Rewards $0.30",
    );
  });

  it("maps work micros to Work and reward micros to Rewards (no swap)", () => {
    // Distinct values catch an accidental argument swap.
    expect(formatEarningsBreakdown(5_000_000, 1_000_000, usd)).toBe(
      "Work $5.00 · Rewards $1.00",
    );
  });

  it("handles a zero reward split", () => {
    expect(formatEarningsBreakdown(2_000_000, 0, usd)).toBe(
      "Work $2.00 · Rewards $0.00",
    );
  });

  it("uses the injected formatter for both values", () => {
    const tagged = (micro: number) => `#${micro}`;
    expect(formatEarningsBreakdown(10, 20, tagged)).toBe("Work #10 · Rewards #20");
  });
});

describe("rewardToneClass", () => {
  it("uses the amber accent when rewards are paid out", () => {
    expect(rewardToneClass(1)).toBe("text-accent-amber");
    expect(rewardToneClass(300_000)).toBe("text-accent-amber");
  });

  it("stays muted when there are no rewards", () => {
    expect(rewardToneClass(0)).toBe("text-text-tertiary");
  });

  it("treats negative values as no reward", () => {
    expect(rewardToneClass(-5)).toBe("text-text-tertiary");
  });
});

describe("formatNumber", () => {
  it("abbreviates thousands and millions", () => {
    expect(formatNumber(1_500)).toBe("1.5K");
    expect(formatNumber(2_300_000)).toBe("2.3M");
  });

  it("leaves small numbers as locale strings", () => {
    expect(formatNumber(999)).toBe("999");
  });
});

describe("formatUSDFromMicro", () => {
  it("shows cents below $10", () => {
    expect(formatUSDFromMicro(1_230_000)).toBe("$1.23");
  });

  it("drops cents from $10 up", () => {
    expect(formatUSDFromMicro(42_000_000)).toBe("$42");
  });

  it("abbreviates $1000 and up", () => {
    expect(formatUSDFromMicro(1_500_000_000_000)).toBe("$1.5M");
  });
});
