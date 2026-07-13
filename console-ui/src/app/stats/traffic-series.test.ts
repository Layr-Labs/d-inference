import { describe, expect, it } from "vitest";
import { normalizeTrafficSeries, trafficRangeConfig } from "./traffic-series";

describe("normalizeTrafficSeries", () => {
  it("fills exactly thirty completed minute buckets", () => {
    const result = normalizeTrafficSeries(
      [{
        timestamp: "2026-07-12T12:14:00.000Z",
        requests: 7,
        prompt_tokens: 11,
        completion_tokens: 3,
        active_providers: 2,
      }],
      trafficRangeConfig("30m"),
      "2026-07-12T12:15:00.000Z",
    );

    expect(result).toHaveLength(30);
    expect(result[0].timestamp).toBe("2026-07-12T11:45:00.000Z");
    expect(result[29].timestamp).toBe("2026-07-12T12:14:00.000Z");
    expect(result[29].requests).toBe(7);
  });

  it("folds minute rows into the adaptive 24-hour buckets", () => {
    const result = normalizeTrafficSeries(
      [
        { timestamp: "2026-07-12T11:31:00.000Z", requests: 2, prompt_tokens: 5, completion_tokens: 1, active_providers: 3 },
        { timestamp: "2026-07-12T11:59:00.000Z", requests: 4, prompt_tokens: 7, completion_tokens: 2, active_providers: 5 },
      ],
      trafficRangeConfig("24h"),
      "2026-07-12T12:00:00.000Z",
    );

    expect(result).toHaveLength(48);
    expect(result[47]).toMatchObject({
      timestamp: "2026-07-12T11:30:00.000Z",
      requests: 6,
      prompt_tokens: 12,
      completion_tokens: 3,
      active_providers: 5,
    });
  });
});
