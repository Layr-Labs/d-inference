import { formatCompactNumber } from "./format";
import { calculateKVHeadroom, calculateModelAvailability } from "./model-capacity";

export interface ModelCapacityCardProps {
  id: string;
  displayName: string;
  description?: string;
  statusLabel?: string | null;
  family?: string;
  quantization?: string;
  sizeGB?: number;
  minRAMGB?: number;
  maxContextLength?: number;
  totalNodes: number;
  eligibleNodes?: number;
  hardwareNodes: number;
  fleetSharePct: number;
  acceptingNodes?: number;
  warmNodes?: number;
  coldNodes?: number;
  activeRequests?: number;
  queuedRequests?: number;
  queueLimit?: number;
  aggregateTPS?: number;
  estimatedTTFTMS?: number;
  tokenBudgetRemaining?: number;
  tokenBudgetTotal?: number;
  canAccept?: boolean;
}

function formatLatency(ms?: number): string {
  if (ms === undefined) return "—";
  return ms >= 1_000 ? `${(ms / 1_000).toFixed(1)} s` : `${Math.round(ms)} ms`;
}

function Metric({ label, value, detail }: { label: string; value: string; detail?: string }) {
  return <div><dt className="text-xs text-text-tertiary">{label}</dt><dd className="mt-1.5 text-lg font-semibold tabular-nums tracking-tight text-text-primary">{value}</dd>{detail && <p className="mt-1 text-xs leading-5 text-text-tertiary">{detail}</p>}</div>;
}

export function ModelCapacityCard(props: ModelCapacityCardProps) {
  const availability = calculateModelAvailability(props.totalNodes, props.eligibleNodes, props.acceptingNodes);
  const kvHeadroom = calculateKVHeadroom(props.tokenBudgetRemaining, props.tokenBudgetTotal);
  const requirements = [
    props.quantization ? `${props.quantization.toUpperCase()} weights` : null,
    props.sizeGB !== undefined ? `${props.sizeGB.toLocaleString()} GB model` : null,
    props.minRAMGB !== undefined ? `${props.minRAMGB.toLocaleString()} GB minimum RAM` : null,
    props.maxContextLength ? `${formatCompactNumber(props.maxContextLength)} context` : null,
  ].filter(Boolean);

  return (
    <article aria-label={`${props.displayName} capacity`} className="rounded-2xl bg-bg-secondary p-5 sm:p-6">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div><h3 className="text-sm font-semibold text-text-primary">Capacity details</h3>{props.description && <p className="mt-1.5 max-w-xl text-sm leading-6 text-text-secondary">{props.description}</p>}</div>
        {props.statusLabel && <span className="text-xs text-accent-amber">{props.statusLabel}</span>}
      </div>
      {requirements.length > 0 && <ul className="mt-4 flex flex-wrap gap-x-6 gap-y-2 text-xs text-text-tertiary" aria-label="Model requirements">{requirements.map((requirement) => <li key={requirement}>{requirement}</li>)}</ul>}
      <dl className="mt-6 grid grid-cols-3 gap-4 border-y border-border-dim py-5">
        <Metric label="Connected" value={availability.connected.toLocaleString()} detail="Advertise this model" />
        <Metric label="Routing eligible" value={availability.eligible?.toLocaleString() ?? "—"} detail={availability.eligible === null ? "Not published per node" : "Coordinator routing verdicts"} />
        <Metric label="Accepting now" value={availability.accepting?.toLocaleString() ?? "—"} detail={availability.accepting === null ? "Capacity not reported" : "Available request capacity"} />
      </dl>
      <div className="mt-5 flex items-center justify-between gap-3 text-xs text-text-tertiary"><span>{props.hardwareNodes.toLocaleString()} hardware-attested nodes</span><span>{props.fleetSharePct.toFixed(0)}% of model placements</span></div>
      <div className="mt-7"><h4 className="text-sm font-medium text-text-primary">Current load</h4>
        <dl className="mt-4 grid grid-cols-2 gap-x-6 gap-y-5 lg:grid-cols-5">
          <Metric label="In progress" value={props.activeRequests?.toLocaleString() ?? "—"} detail="Active requests" />
          <Metric label="Waiting" value={props.queuedRequests?.toLocaleString() ?? "—"} detail={props.queueLimit ? `Queue limit ${props.queueLimit}` : "Queued requests"} />
          <Metric label="Token headroom" value={kvHeadroom === null ? "—" : `${kvHeadroom}%`} detail="Free token memory" />
          <Metric label="Combined speed" value={props.aggregateTPS === undefined ? "—" : `${formatCompactNumber(props.aggregateTPS)} tok/s`} detail="Estimated generation" />
          <Metric label="First token" value={formatLatency(props.estimatedTTFTMS)} detail="Best loaded node estimate" />
        </dl>
      </div>
      <div className="mt-6 flex flex-wrap justify-between gap-2 border-t border-border-dim pt-4 text-xs leading-5 text-text-tertiary">
        <span>{props.warmNodes === undefined ? "Loaded count not reported" : `${props.warmNodes.toLocaleString()} loaded nodes`}{props.coldNodes !== undefined ? `; ${props.coldNodes.toLocaleString()} available to load` : ""}</span>
        <span>{availability.accepting === null ? "Admission data unavailable" : `${availability.acceptingPct}% of connected nodes can accept requests`}</span>
      </div>
    </article>
  );
}
