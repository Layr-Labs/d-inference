import { describe, expect, it } from "vitest";
import { plotScale, plotValues } from "./chart-math";
const data = [
  { timestamp: "2026-09-04T12:00:00Z", requests: 3, prompt_tokens: 5, completion_tokens: 2, active_providers: 1 },
  { timestamp: "2026-09-04T12:01:00Z", requests: 0, prompt_tokens: 0, completion_tokens: 0, active_providers: 1 },
  { timestamp: "2026-09-04T12:02:00Z", requests: 7, prompt_tokens: 11, completion_tokens: 3, active_providers: 1 },
];
describe("Traffic plot arithmetic", () => {
  it("preserves zero-activity buckets instead of inventing a minimum bar", () => {
    expect(plotValues(data, "tokens", "rate")[1]).toMatchObject({ value: 0, input: 0, output: 0 });
  });
  it("accumulates requests and token components independently", () => {
    expect(plotValues(data, "requests", "cumulative").map((point) => point.value)).toEqual([3,3,10]);
    expect(plotValues(data, "tokens", "cumulative")[2]).toMatchObject({ value:21,input:16,output:5 });
  });
  it("keeps the vertical scale above the peak and nonzero for empty windows", () => {
    expect(plotScale([0,19,32])).toBe(40);
    expect(plotScale([])).toBe(1);
  });
});
