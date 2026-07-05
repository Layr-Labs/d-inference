import { describe, it, expect } from "vitest";
import {
  MICRO_PER_USD,
  microToUsd,
  formatUsd,
  formatUsdWhole,
  formatUsdMicro,
} from "@/lib/format/currency";
import {
  formatNumber,
  abbreviateNumber,
  formatCount,
  plural,
  clampPct,
  pct,
  formatTps,
} from "@/lib/format/number";
import { relativeTime, formatRelative, humanizeUptime } from "@/lib/format/time";
import { maskSerial, shortModelName } from "@/lib/format/text";

describe("format/currency", () => {
  it("converts micro <-> usd", () => {
    expect(MICRO_PER_USD).toBe(1_000_000);
    expect(microToUsd(1_500_000)).toBe(1.5);
    expect(microToUsd(0)).toBe(0);
  });

  it("formatUsd is fixed-decimals, unsigned", () => {
    expect(formatUsd(1.2)).toBe("$1.20");
    expect(formatUsd(1.239, 3)).toBe("$1.239");
  });

  it("formatUsdWhole uses separators and signs", () => {
    expect(formatUsdWhole(1234)).toBe("$1,234");
    expect(formatUsdWhole(-1234)).toBe("-$1,234");
  });

  it("formatUsdMicro keeps sub-cent precision", () => {
    expect(formatUsdMicro(0)).toBe("$0.00");
    expect(formatUsdMicro(5)).toBe("$0.000005");
    expect(formatUsdMicro(2_500_000)).toBe("$2.50");
  });
});

describe("format/number", () => {
  it("formatNumber adds thousands separators", () => {
    expect(formatNumber(1234567)).toBe("1,234,567");
    expect(formatNumber(0)).toBe("0");
  });

  it("abbreviateNumber compacts and strips .0", () => {
    expect(abbreviateNumber(999)).toBe("999");
    expect(abbreviateNumber(1200)).toBe("1.2K");
    expect(abbreviateNumber(1_000_000)).toBe("1M");
    expect(abbreviateNumber(2_500_000_000)).toBe("2.5B");
  });

  it("formatCount and plural", () => {
    expect(formatCount(1000)).toBe((1000).toLocaleString());
    expect(plural(1, "item")).toBe("1 item");
    expect(plural(2, "item")).toBe("2 items");
  });

  it("clampPct and pct clamp to [0,100]", () => {
    expect(clampPct(150)).toBe(100);
    expect(clampPct(-5)).toBe(0);
    expect(clampPct(Infinity)).toBe(100);
    expect(pct(0.5)).toBe("50%");
    expect(pct(2)).toBe("100%");
  });

  it("formatTps", () => {
    expect(formatTps(0)).toBe("—");
    expect(formatTps(undefined)).toBe("—");
    expect(formatTps(12.34)).toBe("12.3");
    expect(formatTps(150)).toBe("150");
  });
});

describe("format/time", () => {
  it("relativeTime title-cases the fallback", () => {
    expect(relativeTime(undefined)).toBe("Never");
    expect(relativeTime("not-a-date")).toBe("Never");
    expect(relativeTime(new Date(Date.now() - 5 * 60_000).toISOString())).toBe("5m ago");
  });

  it("formatRelative uses seconds + lower-case fallback", () => {
    expect(formatRelative(undefined)).toBe("never");
    expect(formatRelative(new Date(Date.now() - 5000).toISOString())).toBe("5s ago");
  });

  it("humanizeUptime", () => {
    expect(humanizeUptime(0)).toBe("—");
    expect(humanizeUptime(90)).toBe("1m");
    expect(humanizeUptime(3700)).toBe("1h 1m");
    expect(humanizeUptime(90_000)).toBe("1d 1h");
  });
});

describe("format/text", () => {
  it("maskSerial keeps head + tail", () => {
    expect(maskSerial(undefined)).toBe("");
    expect(maskSerial("ABC")).toBe("ABC");
    expect(maskSerial("ABCDEFGHIJ")).toBe("ABCD••••IJ");
  });

  it("shortModelName takes the last path segment", () => {
    expect(shortModelName("org/model")).toBe("model");
    expect(shortModelName("model")).toBe("model");
    expect(shortModelName("")).toBe("");
  });
});
