export type DemandWindow = "24h" | "7d" | "30d";
export interface DemandCounts {
  requests: number;
  completed: number;
  capacity_rejected: number;
  timed_out: number;
  latency_rejected: number;
  failed: number;
  cancelled: number;
  unknown: number;
  http_429: number;
}
export interface DemandBucket { timestamp: string; counts: DemandCounts | null }
export interface ModelDemand extends DemandCounts { model: string; time_series: DemandBucket[] }
export interface ModelDemandResponse {
  bucket_seconds: number;
  window: DemandWindow;
  start_at: string;
  end_at: string;
  updated_at: string;
  collection_started_at: string;
  coverage: "recorded_requests_only";
  models: ModelDemand[];
}
export function outcomeEntries(m: DemandCounts) { return [
  ["completed", "Completed", m.completed],
  ["capacity_rejected", "Capacity rejected", m.capacity_rejected],
  ["latency_rejected", "Latency limited", m.latency_rejected],
  ["timed_out", "Timed out", m.timed_out],
  ["failed", "Service errors / interrupted responses", m.failed],
  ["cancelled", "Client departed", m.cancelled],
  ["unknown", "Pending / unknown", m.unknown],
] as const; }

export function isModelDemandResponse(value: unknown, window: DemandWindow): value is ModelDemandResponse {
  if (!value || typeof value !== "object") return false;
  const r = value as ModelDemandResponse;
  if (r.window !== window || r.coverage !== "recorded_requests_only" || !Array.isArray(r.models)) return false;
  if (![r.start_at, r.end_at, r.updated_at, r.collection_started_at].every(v => typeof v === "string" && Number.isFinite(Date.parse(v)))) return false;
  if (Date.parse(r.start_at) >= Date.parse(r.end_at)) return false;
  let width = 3600;
  let expectedLength = 24;
  if (window === "7d") { width = 21600; expectedLength = 28; }
  if (window === "30d") { width = 86400; expectedLength = 30; }
  if (r.bucket_seconds !== width) return false;
  const length = (Date.parse(r.end_at) - Date.parse(r.start_at)) / (width * 1000);
  if (length !== expectedLength) return false;
  const models = new Set<string>();
  return r.models.every(m => {
    if (!m || typeof m.model !== "string" || !m.model || models.has(m.model)) return false;
    models.add(m.model);
    if (!validCounts(m) || m.requests === 0 || !Array.isArray(m.time_series) || m.time_series.length !== length) return false;
    return m.time_series.every((bucket, index) => bucket && Date.parse(bucket.timestamp) === Date.parse(r.start_at) + index * width * 1000 && (bucket.counts === null || validCounts(bucket.counts)));
  });
}
function validCounts(m: DemandCounts) {
  if (!m || typeof m !== "object") return false;
  const values = [m.requests, m.http_429, ...outcomeEntries(m).map(([, , count]) => count)];
  return values.every(n => Number.isSafeInteger(n) && n >= 0) && m.http_429 <= m.requests
    && outcomeEntries(m).reduce((sum, [, , count]) => sum + count, 0) === m.requests;
}

export function otherOutcomes(m: ModelDemand) { return m.requests - m.completed - m.capacity_rejected; }
export function percent(count: number, total: number) { return `${(total ? 100 * count / total : 0).toFixed(1)}%`; }
