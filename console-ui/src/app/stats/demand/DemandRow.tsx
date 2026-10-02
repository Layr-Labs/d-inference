import { useId } from "react";
import { ChevronDown } from "lucide-react";
import { ModelMakerMark } from "../ModelMakerMark";
import { formatCompactNumber } from "../format";
import { outcomeEntries, otherOutcomes, percent, type ModelDemand } from "./types";
import { trafficShare } from "./traffic";
import styles from "./demand.module.css";

export function DemandRow({ model, name, total, expanded, onToggle, onHistory }: {
  model: ModelDemand; name: string; total: number; expanded: boolean; onToggle: () => void; onHistory: () => void;
}) {
  const detailId = useId();
  const other = otherOutcomes(model);
  const exact = (n: number) => n.toLocaleString();
  return (
    <div className="border-b border-border-dim last:border-0">
      <button type="button" aria-expanded={expanded} aria-controls={detailId} onClick={onToggle}
        aria-label={`${expanded ? "Hide" : "Show"} demand details for ${name}`}
        className={`${styles.row} w-full items-center py-5 text-left hover:bg-bg-hover focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-accent-brand`}>
        <span className="flex min-w-0 items-start gap-3">
          <ModelMakerMark modelId={model.model} compact />
          <span className="min-w-0"><span className="block break-words text-[15px] font-semibold text-text-primary">{name}</span><span className="mt-1 block truncate text-xs text-text-tertiary" title={model.model}>{model.model}</span></span>
        </span>
        <span className={styles.metrics}>
          <span className="block min-w-0">
            <span className="mb-2 flex flex-wrap items-baseline justify-between gap-2 text-sm tabular-nums text-text-primary" title={`${exact(model.requests)} published requests`}><span>{formatCompactNumber(model.requests)} <span className="text-xs text-text-tertiary">requests</span></span><span className="text-xs text-text-secondary">{trafficShare(model.requests, total)} share</span></span>
            <span role="img" aria-label={`${name}: ${exact(model.requests)} published requests, ${trafficShare(model.requests, total)} of published model traffic`} className="block h-2 w-full rounded-sm bg-bg-tertiary">
              <span className="block h-full rounded-sm bg-accent-brand" style={{ width: `${100 * model.requests / total}%` }} />
            </span>
          </span>
          <span className="block min-w-0">
            <span className="mb-2 flex flex-wrap justify-between gap-2 text-xs tabular-nums"><span className="text-text-secondary">{percent(model.completed, model.requests)} completed</span><span className="text-accent-amber">{percent(model.capacity_rejected, model.requests)} capacity rejected</span></span>
            <span role="img" aria-label={`${name} outcomes: ${exact(model.completed)} completed, ${exact(model.capacity_rejected)} capacity rejected, ${exact(other)} other outcomes`} className="flex h-2 w-full overflow-hidden rounded-sm">
              <span className="h-full bg-accent-brand" style={{ width: `${100 * model.completed / model.requests}%` }} />
              <span className="h-full bg-accent-amber" style={{ width: `${100 * model.capacity_rejected / model.requests}%` }} />
              <span className="h-full bg-text-tertiary/40" style={{ width: `${100 * other / model.requests}%` }} />
            </span>
          </span>
        </span>
        <ChevronDown size={17} aria-hidden="true" className={`${styles.chevron} text-text-tertiary transition-transform motion-reduce:transition-none ${expanded ? "rotate-180" : ""}`} />
      </button>
      {expanded && <div id={detailId} role="region" aria-label={`${name} demand details`} className="pb-6">
        <dl className="grid gap-x-8 gap-y-3 rounded-xl bg-bg-secondary p-5 sm:grid-cols-2 lg:grid-cols-3">
          {outcomeEntries(model).map(([key, label, count]) => <div key={key} className="flex items-baseline justify-between gap-3 text-xs"><dt className="text-text-secondary">{label}</dt><dd className="shrink-0 whitespace-nowrap tabular-nums text-text-primary">{exact(count)} <span className="text-text-tertiary">· {percent(count, model.requests)}</span></dd></div>)}
        </dl>
        <p className="mt-3 text-xs leading-5 text-text-tertiary">Counts and percentages above cover published hourly observations only. Published HTTP 429 responses: {exact(model.http_429)}. These overlap the outcomes above; a 429 can reflect capacity, latency limits, or a timeout. Latency limited means rejected before dispatch for the first-token target. Pending / unknown includes incomplete or conflicting observations.</p>
        <a href="#model-demand-history" onClick={onHistory} className="mt-3 inline-flex min-h-10 items-center text-sm font-medium text-accent-brand">View {name} history and interval data</a>
      </div>}
    </div>
  );
}
