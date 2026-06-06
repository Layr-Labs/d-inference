import { describe, it, expect, vi, afterEach } from "vitest";
import {
  formatNumber,
  formatUSDFromMicro,
  formatDateTime,
  formatRelative,
  formatDuration,
  isOnline,
  truncate,
  ONLINE_WINDOW_SECONDS,
} from "./format";

afterEach(() => vi.useRealTimers());

describe("formatNumber", () => {
  it("formats numbers and numeric strings with grouping", () => {
    expect(formatNumber(1234567)).toBe("1,234,567");
    expect(formatNumber("1000")).toBe("1,000"); // bigint-as-string from pg
    expect(formatNumber(0)).toBe("0");
  });
  it("renders dash for null/empty/undefined", () => {
    expect(formatNumber(null)).toBe("—");
    expect(formatNumber(undefined)).toBe("—");
    expect(formatNumber("")).toBe("—");
  });
});

describe("formatUSDFromMicro", () => {
  it("converts integer micro-USD to dollars", () => {
    expect(formatUSDFromMicro(1_000_000)).toBe("$1.00");
    expect(formatUSDFromMicro("11000000")).toBe("$11.00"); // string from pg BIGINT
    expect(formatUSDFromMicro(0)).toBe("$0.00");
  });
  it("keeps sub-cent precision and dash for null", () => {
    expect(formatUSDFromMicro(124)).toBe("$0.000124");
    expect(formatUSDFromMicro(null)).toBe("—");
  });
});

describe("truncate", () => {
  it("truncates long strings with an ellipsis and passes short ones through", () => {
    expect(truncate("abcdefghijklmnop", 12)).toBe("abcdefghijkl…");
    expect(truncate("short", 12)).toBe("short");
    expect(truncate(null)).toBe("—");
  });
});

describe("isOnline / formatRelative (time-based)", () => {
  it("treats a recent last_seen as online and an old one as offline", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-06-03T12:00:00Z"));
    const recent = new Date("2026-06-03T11:59:30Z").toISOString(); // 30s ago
    const stale = new Date("2026-06-03T11:55:00Z").toISOString(); // 5m ago
    expect(isOnline(recent)).toBe(true);
    expect(isOnline(stale)).toBe(false);
    expect(isOnline(null)).toBe(false);
    expect(ONLINE_WINDOW_SECONDS).toBe(90);
  });
  it("renders coarse relative buckets", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-06-03T12:00:00Z"));
    expect(formatRelative(new Date("2026-06-03T11:59:50Z").toISOString())).toBe("10s ago");
    expect(formatRelative(new Date("2026-06-03T11:50:00Z").toISOString())).toBe("10m ago");
    expect(formatRelative(new Date("2026-06-03T09:00:00Z").toISOString())).toBe("3h ago");
    expect(formatRelative(new Date("2026-05-31T12:00:00Z").toISOString())).toBe("3d ago");
    expect(formatRelative(null)).toBe("—");
  });
});

describe("formatDuration", () => {
  it("renders coarse human durations from seconds (number or pg bigint string)", () => {
    expect(formatDuration(45)).toBe("45s");
    expect(formatDuration("3600")).toBe("1h 0m"); // bigint string from EXTRACT(EPOCH)
    expect(formatDuration(7200)).toBe("2h 0m");
    expect(formatDuration(60)).toBe("1m");
    expect(formatDuration(90061)).toBe("1d 1h");
  });
  it("renders dash for null/negative/NaN", () => {
    expect(formatDuration(null)).toBe("—");
    expect(formatDuration(-5)).toBe("—");
    expect(formatDuration("")).toBe("—");
  });
});

describe("formatDateTime", () => {
  it("renders an ISO-ish timestamp and dash for null", () => {
    expect(formatDateTime("2026-06-03T12:00:00.000Z")).toBe("2026-06-03 12:00:00Z");
    expect(formatDateTime(null)).toBe("—");
  });
});
