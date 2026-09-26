import { Download } from "lucide-react";
import { DemandHistoryPlot } from "./DemandHistoryPlot";
import { DemandIntervalTable } from "./DemandIntervalTable";
import { demandCSV, historyCoverage, METRICS, type DemandMetric } from "./history";
import type { ModelDemandResponse } from "./types";

export function DemandHistory({ data, names, modelId, onModelChange, metric, onMetricChange }: {
  data: ModelDemandResponse; names: Map<string, string>; modelId: string;
  onModelChange: (id: string) => void; metric: DemandMetric; onMetricChange: (metric: DemandMetric) => void;
}) {
  const model = data.models.find(m => m.model === modelId) || data.models[0];
  if (!model) return null;
  const coverage = historyCoverage(model.time_series);
  const interval = data.bucket_seconds === 3600 ? "hour" : `${data.bucket_seconds / 3600} hours`;
  function download() {
    const url = URL.createObjectURL(new Blob([demandCSV(model, data.bucket_seconds)], { type: "text/csv;charset=utf-8" }));
    const link = document.createElement("a");
    link.href = url;
    link.download = `model-demand-${model.model.replace(/[^a-zA-Z0-9_-]/g, "-")}-${data.window}.csv`;
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
  return <div className="mt-6 rounded-2xl border border-border-dim bg-bg-white p-4 sm:p-6">
    <div className="mb-5 flex flex-wrap items-start justify-between gap-4">
      <div><h3 className="font-medium text-text-primary">Published observations over time</h3><p className="mt-1 text-xs text-text-tertiary">Per {interval} · {coverage.published} of {coverage.total} intervals contain published observations</p></div>
      <div className="flex min-w-0 flex-wrap gap-2">
        <select aria-label="Model for demand history" value={model.model} onChange={event => onModelChange(event.target.value)} className="h-10 max-w-full rounded-lg border border-border-dim bg-bg-white px-3 text-xs text-text-secondary">{data.models.map(m => <option key={m.model} value={m.model}>{names.get(m.model) || m.model}</option>)}</select>
        <select aria-label="Demand history metric" value={metric} onChange={event => onMetricChange(event.target.value as DemandMetric)} className="h-10 rounded-lg border border-border-dim bg-bg-white px-3 text-xs text-text-secondary">{METRICS.map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select>
      </div>
    </div>
    <DemandHistoryPlot key={`${model.model}-${data.window}-${metric}`} model={model} metric={metric} bucketSeconds={data.bucket_seconds} />
    <div className="mt-3 flex flex-wrap items-center gap-x-5 gap-y-2 text-xs text-text-tertiary">
      {metric === "requests" && <><span className="inline-flex items-center gap-2"><span className="h-2 w-4 bg-accent-brand" />Completed</span><span className="inline-flex items-center gap-2"><span className="h-2 w-4 bg-accent-amber" />Capacity rejected</span><span className="inline-flex items-center gap-2"><span className="h-2 w-4 bg-text-tertiary/50" />Other outcomes</span></>}
      <span>Hatched intervals = not published</span>
      <button type="button" onClick={download} className="inline-flex min-h-10 items-center gap-1.5 text-accent-brand sm:ml-auto"><Download size={13} />Download published interval CSV</button>
    </div>
    {metric === "http_429" && <p className="mt-2 text-xs leading-5 text-text-tertiary">Published HTTP 429 responses overlap the outcome categories. They are not all capacity rejections.</p>}
    <p className="mt-2 text-xs leading-5 text-text-tertiary">Only UTC clock hours with at least 20 recorded requests from 3 distinct consumer accounts contribute to any count. Wider display intervals sum only eligible hours and may include observations from just some of their hours. Gaps have no published hourly observations; they are not plotted as zero.</p>
    <DemandIntervalTable model={model} bucketSeconds={data.bucket_seconds} />
  </div>;
}
