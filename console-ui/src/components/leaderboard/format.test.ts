import { describe, it, expect } from "vitest";
import {
  formatAnnualizedUSD,
  formatDailyUSD,
  formatNumber,
  formatUSDFromMicro,
  rewardToneClass,
} from "./format";

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

  it("never abbreviates — full number with separators", () => {
    expect(formatUSDFromMicro(1_500_000_000_000)).toBe("$1,500,000");
    expect(formatUSDFromMicro(2_190_000_000)).toBe("$2,190");
  });
});

describe("formatAnnualizedUSD", () => {
  it("extrapolates a 24h figure to a yearly rate without a suffix", () => {
    // $1.00 earned in 24h -> $365/yr
    expect(formatAnnualizedUSD(1_000_000)).toBe("$365");
  });

  it("handles zero", () => {
    expect(formatAnnualizedUSD(0)).toBe("$0.00");
  });

  it("shows large annualized figures in full", () => {
    // $10 earned in 24h -> $3,650/yr
    expect(formatAnnualizedUSD(10_000_000)).toBe("$3,650");
  });
});

describe("formatDailyUSD", () => {
  it("shows the 24h amount as a daily rate with suffix", () => {
    expect(formatDailyUSD(1_230_000)).toBe("$1.23/day");
  });

  it("handles zero", () => {
    expect(formatDailyUSD(0)).toBe("$0.00/day");
  });
});