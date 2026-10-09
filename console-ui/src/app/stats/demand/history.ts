import type { DemandBucket, DemandCounts, ModelDemand } from "./types";

export type DemandMetric = "requests" | "capacity_rejected" | "timed_out" | "failed" | "latency_rejected" | "http_429" | "completion_rate";
export const METRICS: [DemandMetric, string][] = [["requests", "Published requests"], ["capacity_rejected", "Published capacity rejections"], ["latency_rejected", "Published latency rejections"], ["timed_out", "Published timeouts"], ["failed", "Published service errors"], ["http_429", "Published HTTP 429 responses"], ["completion_rate", "Published completion rate"]];
export function metricValue(c: DemandCounts, metric: DemandMetric) {
  switch (metric) {
    case "requests": return c.requests;
    case "capacity_rejected": return c.capacity_rejected;
    case "timed_out": return c.timed_out;
    case "failed": return c.failed;
    case "latency_rejected": return c.latency_rejected;
    case "http_429": return c.http_429;
    case "completion_rate": return c.requests ? 100 * c.completed / c.requests : 0;
  }
}
export function bucketLabel(timestamp: string, seconds: number) {
  const start = new Date(timestamp);
  const end = new Date(start.getTime() + seconds * 1000);
  const format = (date: Date) => date.toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit", timeZoneName: "short" });
  return `${format(start)} – ${format(end)}`;
}
export function bucketTick(timestamp: string, seconds: number) {
  return new Date(timestamp).toLocaleString(undefined, seconds === 3600 ? { hour: "numeric" } : { month: "short", day: "numeric" });
}
export function historyCoverage(series: DemandBucket[]) {
  return { published: series.filter(bucket => bucket.counts !== null).length, total: series.length };
}
export function demandCSV(model: ModelDemand, bucketSeconds: number) {
  const rows = [["interval_start_utc", "interval_end_utc", "has_published_hourly_cohorts", "published_requests", "published_completed", "published_capacity_rejected", "published_latency_rejected", "published_timed_out", "published_failed", "published_cancelled", "published_unknown", "published_http_429"]];
  for (const b of model.time_series) {
    const c = b.counts;
    rows.push([b.timestamp, new Date(Date.parse(b.timestamp) + bucketSeconds * 1000).toISOString(), c ? "true" : "false", ...(c ? [c.requests, c.completed, c.capacity_rejected, c.latency_rejected, c.timed_out, c.failed, c.cancelled, c.unknown, c.http_429].map(String) : Array<string>(9).fill(""))]);
  }
  return rows.map(row => row.join(",")).join("\n");
}
