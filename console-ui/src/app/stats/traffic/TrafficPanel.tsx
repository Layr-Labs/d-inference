"use client";

import { useMemo, useState } from "react";
import { ArrowRight, RefreshCw } from "lucide-react";
import { formatCompactNumber } from "../format";
import { normalizeTrafficSeries, TRAFFIC_RANGES, trafficRangeConfig, formatTrafficTimestamp } from "../traffic-series";
import type { TimeSeriesBucket, TrafficRange } from "../types";
import { useTrafficSeries } from "./useTrafficSeries";
import { TrafficPlot } from "./TrafficPlot";
import type { TrafficMetric, TrafficView } from "./chart-math";

function MetricChart({ data, metric, range, view, bucketLabel }: { data: TimeSeriesBucket[]; metric: TrafficMetric; range: TrafficRange; view: TrafficView; bucketLabel: string }) {
  const values = data.map((bucket) => metric === "requests" ? bucket.requests : bucket.prompt_tokens + bucket.completion_tokens);
  const total = values.reduce((sum, value) => sum + value, 0);
  const peak = Math.max(...values, 0);
  return (
    <div className="min-w-0 px-4 py-6 sm:px-6">
      <div className="mb-5 flex items-start justify-between gap-3">
        <div>
          <h3 className="text-sm font-medium text-text-secondary">{metric === "requests" ? "Requests" : "Tokens processed"}</h3>
          <p className="mt-2 text-[32px] font-medium leading-none tracking-tight tabular-nums text-text-primary">{formatCompactNumber(total)}</p>
        </div>
        <p className="pt-1 text-right text-[11px] text-text-tertiary">Peak {formatCompactNumber(peak)}<span className="mt-1 block">per {bucketLabel}</span></p>
      </div>
      <TrafficPlot key={`${range}-${view}`} data={data} metric={metric} range={range} view={view} />
    </div>
  );
}

export function TrafficPanel({ refreshToken }: { refreshToken: string | null }) {
  const [range, setRange] = useState<TrafficRange>("30m");
  const [view, setView] = useState<TrafficView>("rate");
  const { response, loading, error, retry } = useTrafficSeries(range, refreshToken);
  const config = trafficRangeConfig(range);
  const chartData = useMemo(() => normalizeTrafficSeries(response?.time_series ?? [], config, response?.end_at), [response, config]);
  const unavailable = error || !response?.time_series.length;

  let content;
  if (loading) {
    content = <div role="status" className="flex h-[330px] items-center justify-center gap-2 text-sm text-text-secondary"><RefreshCw size={16} className="motion-safe:animate-spin" />Loading activity…</div>;
  } else if (unavailable) {
    content = <div className="flex h-[330px] flex-col items-center justify-center gap-3 text-center"><p className="text-sm text-text-secondary">{error ? "Activity couldn’t be loaded." : "No traffic samples available for this window."}</p>{error && <button type="button" onClick={retry} className="flex items-center gap-1 text-sm text-accent-brand">Try again <ArrowRight size={14} /></button>}</div>;
  } else {
    content = <div className="grid divide-y divide-border-dim lg:grid-cols-2 lg:divide-x lg:divide-y-0"><MetricChart data={chartData} metric="requests" range={range} view={view} bucketLabel={config.bucketLabel} /><MetricChart data={chartData} metric="tokens" range={range} view={view} bucketLabel={config.bucketLabel} /></div>;
  }

  return (
    <section className="border-t border-border-dim pt-8" aria-labelledby="traffic-title">
      <div className="mb-6 flex flex-wrap items-center justify-between gap-4">
        <div><h2 id="traffic-title" className="text-lg font-medium text-text-primary">Activity over time</h2><p className="mt-1 text-sm text-text-secondary">Requests and tokens in completed {config.bucketLabel} buckets{response ? `, through ${formatTrafficTimestamp(response.end_at, range)} local time` : ""}.</p></div>
        <div className="flex flex-wrap items-center gap-3">
          <div className="flex rounded-lg bg-bg-secondary p-1" role="group" aria-label="Traffic time range">
            {TRAFFIC_RANGES.map((option) => <button type="button" key={option.value} aria-pressed={range === option.value} onClick={() => setRange(option.value)} className={`min-h-9 rounded-md px-3 text-xs transition-colors ${range === option.value ? "bg-bg-white font-medium text-text-primary shadow-sm" : "text-text-secondary hover:text-text-primary"}`}>{option.label}</button>)}
          </div>
          <select aria-label="Traffic chart view" value={view} onChange={(event) => setView(event.target.value as TrafficView)} className="h-10 rounded-lg border border-border-dim bg-bg-white px-3 text-xs text-text-secondary"><option value="rate">{config.rateControlLabel}</option><option value="cumulative">Cumulative</option></select>
        </div>
      </div>
      <div className="overflow-hidden rounded-2xl border border-border-dim bg-bg-white">{content}</div>
    </section>
  );
}
