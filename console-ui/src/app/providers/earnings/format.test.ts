import { describe, it, expect } from "vitest";
import {
  chartCoverageNote,
  formatAvgPerJob,
  formatBucketLabel,
  formatMicroDollars,
  formatMicroExact,
  formatTokens,
  modelLabel,
} from "./format";

describe("formatMicroExact", () => {
  it("keeps 6 decimals so sub-cent rows never read as $0.00", () => {
    expect(formatMicroExact(84_210)).toBe("$0.084210");
  });
  it("handles zero", () => {
    expect(formatMicroExact(0)).toBe("$0.000000");
  });
  it("handles whole dollars", () => {
    expect(formatMicroExact(2_500_000)).toBe("$2.500000");
  });
});

const ZERO_USD = "$0.00";

describe("formatMicroDollars", () => {
  it("formats with thousands separators and cents", () => {
    expect(formatMicroDollars(1_284_360_000)).toBe("$1,284.36");
  });
  it("handles zero", () => {
    expect(formatMicroDollars(0)).toBe(ZERO_USD);
  });
});

describe("formatAvgPerJob", () => {
  it("does not divide by zero when there are no jobs", () => {
    expect(formatAvgPerJob(0, 0)).toBe(ZERO_USD);
    expect(formatAvgPerJob(5_000_000, 0)).toBe(ZERO_USD);
  });
  it("uses 4 decimals for sub-dollar averages", () => {
    // 1284.36 / 18742 jobs = ~0.0685
    expect(formatAvgPerJob(1_284_360_000, 18_742)).toBe("$0.0685");
  });
  it("uses 2 decimals and separators for large averages", () => {
    expect(formatAvgPerJob(10_000_000_000, 4)).toBe("$2,500.00");
  });
});

describe("formatTokens", () => {
  it("adds thousands separators", () => {
    expect(formatTokens(1_245_312)).toBe("1,245,312");
  });
});

describe("formatBucketLabel", () => {
  it("formats day keys as short dates", () => {
    expect(formatBucketLabel("2025-05-30", "day")).toBe("May 30");
  });

  it("formats hour keys with the hour", () => {
    expect(formatBucketLabel("2025-05-30T16", "hour")).toBe("May 30, 4 PM");
    expect(formatBucketLabel("2025-05-30T00", "hour")).toBe("May 30, 12 AM");
  });

  it("passes through unparseable keys", () => {
    expect(formatBucketLabel("garbage", "hour")).toBe("garbage");
  });
});

describe("chartCoverageNote", () => {
  it("returns null when the fetched window is complete", () => {
    expect(chartCoverageNote(40, 40, "2025-05-16T10:00:00")).toBeNull();
    expect(chartCoverageNote(0, 0, null)).toBeNull();
  });

  it("names the window and its start date when truncated", () => {
    expect(chartCoverageNote(4_210, 100, "2025-05-16T10:00:00")).toBe(
      "Trend covers your latest 100 of 4,210 payouts, since May 16, 2025.",
    );
  });

  it("drops the date when the oldest row is missing or unparseable", () => {
    const expected = "Trend covers your latest 100 of 4,210 payouts.";
    expect(chartCoverageNote(4_210, 100, null)).toBe(expected);
    expect(chartCoverageNote(4_210, 100, "not-a-date")).toBe(expected);
  });
});

describe("modelLabel", () => {
  const QWEN = "Qwen/Qwen3-30B-A3B";
  const all = [QWEN, "google/gemma-3-27b-it"];
  it("drops the org prefix when unambiguous", () => {
    expect(modelLabel(QWEN, all)).toBe("Qwen3-30B-A3B");
  });
  it("keeps the full id when two orgs ship the same short name", () => {
    const clash = [...all, "other-org/Qwen3-30B-A3B"];
    expect(modelLabel(QWEN, clash)).toBe(QWEN);
  });
  it("passes through ids without a slash", () => {
    expect(modelLabel("plain-model", all)).toBe("plain-model");
  });
});
