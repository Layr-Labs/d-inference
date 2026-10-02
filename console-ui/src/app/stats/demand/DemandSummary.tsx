import { formatCompactNumber } from "../format";
import { rankedTraffic, trafficShare } from "./traffic";
import type { ModelDemand } from "./types";

export function DemandSummary({ models, names }: { models: ModelDemand[]; names: Map<string, string> }) {
  if (!models.length) return null;
  const requests = models.reduce((sum, model) => sum + model.requests, 0);
  const completed = models.reduce((sum, model) => sum + model.completed, 0);
  const rejected = models.reduce((sum, model) => sum + model.capacity_rejected, 0);
  const leader = rankedTraffic(models)[0];
  const items = [
    { label: "Published requests", value: formatCompactNumber(requests), detail: `${requests.toLocaleString()} across ${models.length} models` },
    { label: "Largest traffic share", value: trafficShare(leader.requests, requests), detail: names.get(leader.model) || leader.model },
    { label: "Completed", value: trafficShare(completed, requests), detail: `${completed.toLocaleString()} published requests` },
    { label: "Capacity rejected", value: trafficShare(rejected, requests), detail: `${rejected.toLocaleString()} published requests` },
  ];
  return <dl aria-label="Published model traffic summary" className="mt-6 grid grid-cols-2 gap-x-6 gap-y-5 border-y border-border-dim py-5 xl:grid-cols-4">
    {items.map(item => <div key={item.label} className="min-w-0"><dt className="text-xs text-text-secondary">{item.label}</dt><dd className="mt-2 text-[28px] leading-none tracking-tight tabular-nums text-text-primary">{item.value}<span className="mt-2 block break-words text-xs leading-5 tracking-normal text-text-tertiary">{item.detail}</span></dd></div>)}
  </dl>;
}
