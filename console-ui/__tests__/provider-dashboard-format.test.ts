import { describe, it, expect } from "vitest";
import {
  formatUSD,
  formatNumber,
  abbreviateNumber,
  maskSerial,
  shortModelName,
  pct,
  clampPct,
  formatTps,
  humanizeUptime,
} from "@/app/providers/dashboard/format";

describe("formatUSD", () => {
  it("formats whole and fractional dollars", () => {
    expect(formatUSD(0)).toBe("$0.00");
    expect(formatUSD(5_000_000)).toBe("$5.00");
    expect(formatUSD(1_234_560_000)).toBe("$1,234.56");
  });
  it("keeps precision for sub-cent amounts", () => {
    expect(formatUSD(5_000)).toBe("$0.005000");
  });
});

describe("abbreviateNumber", () => {
  it("abbreviates thousands and millions", () => {
    expect(abbreviateNumber(999)).toBe("999");
    expect(abbreviateNumber(1_234)).toBe("1.2K");
    expect(abbreviateNumber(1_200_000)).toBe("1.2M");
    expect(abbreviateNumber(0)).toBe("0");
  });
});

describe("clampPct", () => {
  it("clamps to [0,100] and tames non-finite input", () => {
    expect(clampPct(-5)).toBe(0);
    expect(clampPct(150)).toBe(100);
    expect(clampPct(42)).toBe(42);
    expect(clampPct(Infinity)).toBe(100);
    expect(clampPct(NaN)).toBe(0);
  });
});

describe("pct", () => {
  it("converts a 0..1 fraction to a clamped percent string", () => {
    expect(pct(0.5)).toBe("50%");
    expect(pct(0)).toBe("0%");
    expect(pct(1.5)).toBe("100%");
  });
});

describe("maskSerial", () => {
  it("masks the middle, keeping head and tail", () => {
    expect(maskSerial("ABCD1234XY")).toBe("ABCD••••XY");
    expect(maskSerial("")).toBe("");
    expect(maskSerial("SHORT")).toBe("SHORT");
  });
});

describe("shortModelName", () => {
  it("returns the last path segment", () => {
    expect(shortModelName("mlx-community/Qwen3.5-9B")).toBe("Qwen3.5-9B");
    expect(shortModelName("plain")).toBe("plain");
  });
});

describe("formatTps", () => {
  it("renders a dash for missing throughput", () => {
    expect(formatTps(0)).toBe("—");
    expect(formatTps(undefined)).toBe("—");
    expect(formatTps(42.4)).toBe("42.4");
    expect(formatTps(120)).toBe("120");
  });
});

describe("humanizeUptime", () => {
  it("formats compact uptime", () => {
    expect(humanizeUptime(0)).toBe("—");
    expect(humanizeUptime(90)).toBe("1m");
    expect(humanizeUptime(3_661)).toBe("1h 1m");
    expect(humanizeUptime(90_061)).toBe("1d 1h");
  });
});
