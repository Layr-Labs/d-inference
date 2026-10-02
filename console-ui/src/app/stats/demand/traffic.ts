import type { ModelDemand, ModelDemandResponse } from "./types";

const COLORS = ["var(--accent-brand)", "var(--teal)", "var(--purple)", "var(--gold)"];
export interface TrafficGroup { id: string; models: string[]; color: string; requests: number }
export interface TrafficValue { requests: number | null; publishedModels: number; listedModels: number }
export interface TrafficInterval { timestamp: string; values: TrafficValue[]; total: number | null; publishedModels: number }

export function rankedTraffic(models: ModelDemand[]) {
  return [...models].sort((a, b) => b.requests - a.requests || a.model.localeCompare(b.model));
}

export function trafficShare(requests: number, total: number) {
  if (!total) return "—";
  const value = 100 * requests / total;
  return value > 0 && value < .1 ? "<0.1%" : `${value.toFixed(1)}%`;
}

/** Only published values contribute. Null remains unknown, including grouped models. */
export function buildTrafficComparison(data: ModelDemandResponse) {
  const ranked = rankedTraffic(data.models);
  const groups: TrafficGroup[] = ranked.slice(0, 4).map((model, index) => ({
    id: model.model, models: [model.model], color: COLORS[index], requests: model.requests,
  }));
  const rest = ranked.slice(4);
  if (rest.length) groups.push({ id: "", models: rest.map(m => m.model), color: "var(--text-tertiary)", requests: rest.reduce((sum, m) => sum + m.requests, 0) });
  const byID = new Map(ranked.map(model => [model.model, model]));
  const intervals: TrafficInterval[] = (ranked[0]?.time_series ?? []).map((bucket, index) => {
    const values = groups.map(group => {
      const counts = group.models.flatMap(id => {
        const count = byID.get(id)?.time_series[index]?.counts;
        return count ? [count.requests] : [];
      });
      return { requests: counts.length ? counts.reduce((sum, count) => sum + count, 0) : null, publishedModels: counts.length, listedModels: group.models.length };
    });
    const publishedModels = values.reduce((sum, v) => sum + v.publishedModels, 0);
    return { timestamp: bucket.timestamp, values, publishedModels, total: publishedModels ? values.reduce((sum, v) => sum + (v.requests ?? 0), 0) : null };
  });
  return { groups, intervals };
}
