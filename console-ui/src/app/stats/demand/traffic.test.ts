import { describe, expect, it } from "vitest";
import { buildTrafficComparison, rankedTraffic, trafficShare } from "./traffic";
import type { DemandCounts, ModelDemand, ModelDemandResponse } from "./types";

const counts = (requests: number): DemandCounts => ({ requests, completed: requests, capacity_rejected: 0, timed_out: 0, latency_rejected: 0, failed: 0, cancelled: 0, unknown: 0, http_429: 0 });
function model(id: string, values: (number | null)[]): ModelDemand {
  return { model: id, ...counts(values.reduce<number>((sum, n) => sum + (n ?? 0), 0)), time_series: values.map((n, i) => ({ timestamp: new Date(i * 3600000).toISOString(), counts: n === null ? null : counts(n) })) };
}
function data(models: ModelDemand[]): ModelDemandResponse {
  return { models, window: "24h", bucket_seconds: 3600, start_at: new Date(0).toISOString(), end_at: new Date(86400000).toISOString(), updated_at: new Date(86400000).toISOString(), collection_started_at: new Date(0).toISOString(), coverage: "published_hourly_cohorts" };
}

describe("published model traffic comparison", () => {
  it("keeps partial publication and entirely missing intervals distinct", () => {
    const result = buildTrafficComparison(data([model("a", [100, null, null]), model("b", [30, 20, null])]));
    expect(result.intervals.map(b => b.total)).toEqual([130, 20, null]);
    expect(result.intervals.map(b => b.publishedModels)).toEqual([2, 1, 0]);
    expect(result.intervals[1].values.map(v => v.requests)).toEqual([null, 20]);
  });
  it("groups smaller models without inventing zeros or losing traffic", () => {
    const models = [model("a", [600, null]), model("b", [500, null]), model("c", [400, null]), model("d", [300, null]), model("other", [null, 20]), model("f", [40, null])];
    const result = buildTrafficComparison(data(models));
    expect(result.groups).toHaveLength(5);
    expect(result.groups[4].models).toEqual(["f", "other"]);
    expect(result.groups.reduce((sum, g) => sum + g.requests, 0)).toBe(1860);
    expect(result.intervals[1].values[4]).toEqual({ requests: 20, publishedModels: 1, listedModels: 2 });
    expect(result.intervals[1].total).toBe(20);
    expect(result.groups.map(g => g.id).length).toBe(new Set(result.groups.map(g => g.id)).size);
  });
  it("ranks without mutating source and uses a published-traffic denominator", () => {
    const models = [model("b", [30]), model("a", [100])];
    expect(rankedTraffic(models).map(m => m.model)).toEqual(["a", "b"]);
    expect(models[0].model).toBe("b");
    expect(trafficShare(100, 130)).toBe("76.9%");
    expect(trafficShare(1, 100_000)).toBe("<0.1%");
    expect(trafficShare(0, 0)).toBe("—");
    expect(buildTrafficComparison(data([]))).toEqual({ groups: [], intervals: [] });
  });
});
