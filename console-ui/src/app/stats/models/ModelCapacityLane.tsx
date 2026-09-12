import { useId } from "react";
import { ChevronDown, Circle, ListOrdered } from "lucide-react";
import { ModelMakerMark } from "../ModelMakerMark";
import { formatCompactNumber } from "../format";
import { ModelDiagnostic } from "./ModelDiagnostic";
import { modelAvailability } from "./model-availability";
import { deprecatedModelLabel, modelDisplayName, type ActiveModelInventory } from "./model-inventory";

export const CAPACITY_LANE_COLUMNS = "lg:grid-cols-[minmax(190px,.9fr)_minmax(230px,1.4fr)_110px_20px]";

function CapacityBar({ connected, accepting, maxNodes, name }: { connected: number; accepting: number | null; maxNodes: number; name: string }) {
  const patternId = useId();
  const scale = maxNodes > 0 ? 600 / maxNodes : 0;
  const description = accepting === null
    ? `${name}: accepting capacity unknown; ${connected} connected nodes. Shared scale 0 to ${maxNodes} nodes.`
    : `${name}: ${accepting} accepting of ${connected} connected nodes. Shared scale 0 to ${maxNodes} nodes.`;
  return (
    <svg role="img" aria-label={description} viewBox="0 0 600 34" preserveAspectRatio="none" className="block h-9 w-full overflow-visible">
      <defs><pattern id={patternId} width="7" height="7" patternUnits="userSpaceOnUse"><path d="M-1 1L1-1M0 7L7 0M6 8L8 6" className="stroke-text-tertiary/35" strokeWidth="1" /></pattern></defs>
      {[0, 150, 300, 450, 600].map((x) => <line key={x} x1={x} x2={x} y1="0" y2="34" className="stroke-border-dim" strokeDasharray={x === 0 ? undefined : "2 4"} />)}
      <rect x="0" y="8" width={connected * scale} height="18" rx="3" className="fill-text-tertiary/20" />
      {accepting === null
        ? <rect x="0" y="8" width={connected * scale} height="18" rx="3" fill={`url(#${patternId})`} />
        : <rect x="0" y="8" width={accepting * scale} height="18" rx="3" className="fill-accent-brand transition-[width] duration-500 motion-reduce:transition-none" />}
      {connected > 0 && <line x1={connected * scale} x2={connected * scale} y1="5" y2="29" className="stroke-text-tertiary/60" strokeWidth="1" />}
    </svg>
  );
}

function RequestLoad({ item }: { item: ActiveModelInventory }) {
  const active = item.capacity?.activeRequests;
  const queued = item.capacity?.queuedRequests;
  if (active === undefined && queued === undefined) return <span className="text-xs text-text-tertiary">Request load not reported</span>;
  return (
    <span className="flex flex-wrap items-center gap-x-5 gap-y-1 text-xs tabular-nums text-text-tertiary">
      <span className="inline-flex items-center gap-1.5"><Circle size={8} className="fill-text-tertiary" aria-hidden="true" />{active?.toLocaleString() ?? "—"} active requests</span>
      <span className="inline-flex items-center gap-1.5"><ListOrdered size={12} aria-hidden="true" />{queued?.toLocaleString() ?? "—"} queued</span>
    </span>
  );
}

export function ModelCapacityLane({ item, capacityKnown, maxNodes, expanded, onToggle }: {
  item: ActiveModelInventory;
  capacityKnown: boolean;
  maxNodes: number;
  expanded: boolean;
  onToggle: () => void;
}) {
  const name = modelDisplayName(item);
  const availability = modelAvailability(item, capacityKnown);
  const lifecycle = deprecatedModelLabel(item.catalogStatus);
  const detailId = `landscape-detail-${encodeURIComponent(item.id)}`;
  const estimatedTPS = item.capacity?.aggregateTPS;
  return (
    <div className="border-b border-border-dim last:border-b-0">
      <button
        type="button"
        aria-expanded={expanded}
        aria-controls={detailId}
        aria-label={`${expanded ? "Hide" : "Show"} capacity details for ${name}`}
        onClick={onToggle}
        className={`group grid w-full grid-cols-[minmax(0,1fr)_20px] items-center gap-x-6 gap-y-3 py-5 text-left transition-colors hover:bg-bg-hover focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-accent-brand ${CAPACITY_LANE_COLUMNS}`}
      >
        <span className="flex min-w-0 items-start gap-3">
          <ModelMakerMark modelId={item.id} family={item.catalogModel?.family} compact />
          <span className="min-w-0"><span className="block break-words text-[15px] font-semibold leading-5 text-text-primary">{name}</span><span className="mt-1 block truncate text-xs leading-5 text-text-tertiary" title={item.id}>{lifecycle || item.id}</span></span>
        </span>
        <span className="col-span-2 min-w-0 lg:col-span-1">
          <span className="mb-1 flex flex-wrap items-baseline justify-between gap-x-2 gap-y-1 text-xs tabular-nums text-text-tertiary">
            {availability.accepting === null ? <span>Accepting capacity unknown</span> : <span><strong className="text-sm font-semibold text-accent-brand">{availability.accepting.toLocaleString()}</strong> accepting</span>}
            <span>{availability.connected.toLocaleString()} connected</span>
          </span>
          <CapacityBar connected={availability.connected} accepting={availability.accepting} maxNodes={maxNodes} name={name} />
          <span className="mt-1 block"><RequestLoad item={item} /></span>
        </span>
        <span className="col-span-2 flex items-baseline gap-2 lg:col-span-1 lg:block lg:text-right">
          <span className="text-base font-semibold tabular-nums tracking-tight text-text-primary">{estimatedTPS === undefined ? "—" : formatCompactNumber(estimatedTPS)}<span className="ml-1 text-xs font-normal text-text-tertiary">tok/s</span></span>
          <span className="text-xs text-text-tertiary lg:mt-1 lg:block">Estimated generation</span>
        </span>
        <ChevronDown size={17} className={`col-start-2 row-start-1 self-start text-text-tertiary transition-transform motion-reduce:transition-none lg:col-auto lg:row-auto lg:self-center ${expanded ? "rotate-180" : ""}`} />
      </button>
      {expanded && <div id={detailId} role="region" aria-label={`${name} capacity details`} className="pb-6"><ModelDiagnostic item={item} capacityKnown={capacityKnown} /></div>}
    </div>
  );
}
