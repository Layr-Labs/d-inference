import { describe, expect, it } from "vitest";
import { formatBandwidth, formatCompactNumber } from "./format";

describe("stats number formatting", () => {
  it("uses billions for lifetime token totals", () => {
    expect(formatCompactNumber(24_950_900_000)).toBe("24.95B");
  });

  it("keeps useful precision below ten units", () => {
    expect(formatCompactNumber(7_412_000)).toBe("7.41M");
  });

  it("uses terabytes per second for aggregate bandwidth", () => {
    expect(formatBandwidth(131_205)).toBe("131 TB/s");
  });
});
