import { useId } from "react";
import { ChevronDown } from "lucide-react";
import { ModelMakerMark } from "../ModelMakerMark";
import { formatCompactNumber } from "../format";
import { outcomeEntries, otherOutcomes, percent, type ModelDemand } from "./types";

export const DEMAND_COLUMNS = "lg:grid-cols-[minmax(180px,1fr)_minmax(200px,1.4fr)_100px_100px_90px_20px]";

export function DemandRow({ model, name, maximum, expanded, onToggle }: {
  model: ModelDemand; name: string; maximum: number; expanded: boolean; onToggle: () => void;
}) {
  const detailId = useId();
  const other = otherOutcomes(model);
  const exact = (n: number) => n.toLocaleString();
  return (
    <div className="border-b border-border-dim last:border-0">
      <button type="button" aria-expanded={expanded} aria-controls={detailId} onClick={onToggle}
        aria-label={`${expanded ? "Hide" : "Show"} demand details for ${name}`}
        className={`grid w-full grid-cols-[minmax(0,1fr)_20px] items-center gap-x-5 gap-y-3 py-5 text-left hover:bg-bg-hover focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-accent-brand ${DEMAND_COLUMNS}`}>
        <span className="flex min-w-0 items-start gap-3">
          <ModelMakerMark modelId={model.model} compact />
          <span className="min-w-0"><span className="block break-words text-[15px] font-semibold text-text-primary">{name}</span><span className="mt-1 block truncate text-xs text-text-tertiary" title={model.model}>{model.model}</span></span>
        </span>
        <span className="col-span-2 lg:col-span-1">
          <span className="mb-2 block text-sm tabular-nums text-text-primary" title={`${exact(model.requests)} published requests`}>{formatCompactNumber(model.requests)} <span className="text-xs text-text-tertiary">published requests</span></span>
          <span role="img" aria-label={`${name} published observations: ${exact(model.completed)} completed, ${exact(model.capacity_rejected)} capacity rejected, ${exact(other)} other outcomes; shared scale to ${exact(maximum)} published requests`} className="block h-3 w-full">
            <span className="flex h-3 overflow-hidden rounded-sm" style={{ width: `${100 * model.requests / maximum}%` }}>
              <span className="h-full bg-accent-brand" style={{ width: `${100 * model.completed / model.requests}%` }} />
              <span className="h-full bg-accent-amber" style={{ width: `${100 * model.capacity_rejected / model.requests}%` }} />
              <span className="h-full bg-text-tertiary/40" style={{ width: `${100 * other / model.requests}%` }} />
            </span>
          </span>
        </span>
        <span className="col-span-2 flex items-baseline justify-between gap-2 tabular-nums lg:col-span-1 lg:block lg:text-right">
          <span className="text-xs text-text-tertiary lg:hidden">Completed</span><span className="text-sm text-text-primary" title={exact(model.completed)}>{formatCompactNumber(model.completed)}<span className="ml-2 text-xs text-text-tertiary lg:ml-0 lg:mt-1 lg:block">{percent(model.completed, model.requests)}</span></span>
        </span>
        <span className="col-span-2 flex items-baseline justify-between gap-2 tabular-nums lg:col-span-1 lg:block lg:text-right">
          <span className="text-xs text-text-tertiary lg:hidden">Capacity rejected</span><span className="text-sm text-text-primary" title={exact(model.capacity_rejected)}>{formatCompactNumber(model.capacity_rejected)}<span className="ml-2 text-xs text-text-tertiary lg:ml-0 lg:mt-1 lg:block">{percent(model.capacity_rejected, model.requests)}</span></span>
        </span>
        <span className="col-span-2 flex items-baseline justify-between gap-2 tabular-nums lg:col-span-1 lg:block lg:text-right"><span className="text-xs text-text-tertiary lg:hidden">Other outcomes</span><span className="text-sm text-text-primary" title={exact(other)}>{formatCompactNumber(other)}</span></span>
        <ChevronDown size={17} aria-hidden="true" className={`col-start-2 row-start-1 text-text-tertiary transition-transform motion-reduce:transition-none lg:col-auto lg:row-auto ${expanded ? "rotate-180" : ""}`} />
      </button>
      {expanded && <div id={detailId} role="region" aria-label={`${name} demand details`} className="pb-6">
        <dl className="grid gap-x-8 gap-y-3 rounded-xl bg-bg-secondary p-5 sm:grid-cols-2 lg:grid-cols-3">
          {outcomeEntries(model).map(([key, label, count]) => <div key={key} className="flex items-baseline justify-between gap-3 text-xs"><dt className="text-text-secondary">{label}</dt><dd className="shrink-0 whitespace-nowrap tabular-nums text-text-primary">{exact(count)} <span className="text-text-tertiary">· {percent(count, model.requests)}</span></dd></div>)}
        </dl>
        <p className="mt-3 text-xs leading-5 text-text-tertiary">Counts and percentages above cover published hourly observations only. Published HTTP 429 responses: {exact(model.http_429)}. These overlap the outcomes above; a 429 can reflect capacity, latency limits, or a timeout. Latency limited means rejected before dispatch for the first-token target. Pending / unknown includes incomplete or conflicting observations.</p>
      </div>}
    </div>
  );
}
