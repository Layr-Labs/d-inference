import { Activity, CheckCircle2, Server, Zap } from "lucide-react";
import { formatCompactNumber } from "./format";
import { calculateKVHeadroom, calculateModelAvailability } from "./model-capacity";
import { modelBrand } from "./model-brand";
import { ModelMakerMark } from "./ModelMakerMark";

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
  eligibleNodes: number;
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
  if (ms === undefined) return "Not reported";
  if (ms >= 1_000) return `${(ms / 1_000).toFixed(1)} sec`;
  return `${Math.round(ms)} ms`;
}

function formatGBRequirement(value: number | undefined, suffix: string): string | null {
  if (value === undefined) return null;
  const display = value >= 10 ? value.toFixed(0) : value.toFixed(1);
  return `${display} GB ${suffix}`;
}

function modelRequirements(props: ModelCapacityCardProps): string[] {
  return [
    props.family ? `${props.family} family` : null,
    props.quantization ? `${props.quantization.toUpperCase()} weights` : null,
    formatGBRequirement(props.sizeGB, "model"),
    formatGBRequirement(props.minRAMGB, "RAM minimum"),
    props.maxContextLength ? `${formatCompactNumber(props.maxContextLength)} context` : null,
  ].filter((value): value is string => Boolean(value));
}

function Requirement({ label }: { label: string }) {
  return (
    <span className="rounded-md border border-border-dim bg-bg-primary/75 px-2.5 py-1 text-[11px] text-text-secondary">
      {label}
    </span>
  );
}

function AvailabilityStep({
  label,
  value,
  description,
  tone,
}: {
  label: string;
  value: number;
  description: string;
  tone?: "green";
}) {
  return (
    <div className="min-w-0 rounded-lg border border-border-dim bg-bg-primary/65 px-3 py-3">
      <p className={`font-mono text-xl font-bold tabular-nums ${tone === "green" ? "text-accent-green" : "text-text-primary"}`}>
        {value.toLocaleString()}
      </p>
      <p className="mt-0.5 text-xs font-semibold text-text-secondary">{label}</p>
      <p className="mt-1 text-[10px] leading-4 text-text-tertiary">{description}</p>
    </div>
  );
}

function LoadMetric({
  label,
  value,
  detail,
  tone,
}: {
  label: string;
  value: string;
  detail: string;
  tone?: "green" | "amber";
}) {
  let valueColor = "text-text-primary";
  if (tone === "green") valueColor = "text-accent-green";
  if (tone === "amber") valueColor = "text-accent-amber";
  return (
    <div>
      <p className="text-[10px] font-mono uppercase tracking-wider text-text-tertiary">{label}</p>
      <p className={`mt-1 font-mono text-base font-bold tabular-nums ${valueColor}`}>{value}</p>
      <p className="mt-0.5 text-[10px] leading-4 text-text-tertiary">{detail}</p>
    </div>
  );
}

function ModelIdentity({ props }: { props: ModelCapacityCardProps }) {
  const brand = modelBrand(props.id, props.family);
  return (
    <div className="flex min-w-0 items-start gap-3">
      <ModelMakerMark modelId={props.id} family={props.family} />
      <div className="min-w-0">
        <div className="flex flex-wrap items-center gap-2">
          <h3 className="text-base font-semibold text-text-primary">{props.displayName}</h3>
          {props.statusLabel && (
            <span className="rounded-full border border-accent-amber/30 bg-accent-amber-dim px-2 py-0.5 text-[9px] font-mono uppercase tracking-wider text-accent-amber">
              {props.statusLabel}
            </span>
          )}
        </div>
        <p className="mt-1 font-mono text-[10px] text-text-tertiary">
          {brand.makerLabel} · {props.id}
        </p>
        {props.description && (
          <p className="mt-2 max-w-xl text-xs leading-5 text-text-secondary">{props.description}</p>
        )}
      </div>
    </div>
  );
}

function TrafficStatus({ accepting }: { accepting: boolean }) {
  const style = accepting
    ? "border-accent-green/25 bg-accent-green/10 text-accent-green"
    : "border-accent-amber/30 bg-accent-amber-dim text-accent-amber";
  return (
    <div className={`inline-flex w-fit items-center gap-1.5 rounded-full border px-2.5 py-1 text-xs font-medium ${style}`}>
      {accepting ? <CheckCircle2 size={13} /> : <Activity size={13} />}
      {accepting ? "Accepting traffic" : "Limited right now"}
    </div>
  );
}

function Requirements({ values }: { values: string[] }) {
  if (values.length === 0) return null;
  return (
    <div className="mt-4 flex flex-wrap gap-1.5">
      {values.map((requirement) => <Requirement key={requirement} label={requirement} />)}
    </div>
  );
}

export function ModelCapacityCard(props: ModelCapacityCardProps) {
  const availability = calculateModelAvailability(
    props.totalNodes,
    props.eligibleNodes,
    props.acceptingNodes,
  );
  const kvHeadroom = calculateKVHeadroom(
    props.tokenBudgetRemaining,
    props.tokenBudgetTotal,
  );
  const active = Math.max(0, props.activeRequests ?? 0);
  const waiting = Math.max(0, props.queuedRequests ?? 0);
  const queueLimit = Math.max(0, props.queueLimit ?? 0);
  const queueAtLimit = queueLimit > 0 && waiting >= queueLimit;
  const acceptingTraffic = Boolean(props.canAccept) && availability.accepting > 0;
  const requirements = modelRequirements(props);

  return (
    <article className="rounded-xl border border-border-dim bg-bg-secondary p-4 shadow-sm">
      <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
        <ModelIdentity props={props} />
        <TrafficStatus accepting={acceptingTraffic} />
      </div>

      <Requirements values={requirements} />

      <div className="mt-4">
        <div className="mb-2 flex items-center gap-2">
          <Server size={13} className="text-accent-brand" />
          <p className="text-xs font-semibold text-text-secondary">Availability path</p>
          <p className="text-[10px] text-text-tertiary">live admission state</p>
        </div>
        <div className="grid grid-cols-3 gap-2">
          <AvailabilityStep label="Connected" value={availability.connected} description="advertise this model" />
          <AvailabilityStep label="Eligible" value={availability.eligible} description="trusted and healthy" />
          <AvailabilityStep label="Accepting now" value={availability.accepting} description="concurrency + KV headroom" tone="green" />
        </div>
        <div className="mt-2 flex items-center justify-between gap-3 text-[10px] text-text-tertiary">
          <span>{props.hardwareNodes.toLocaleString()} hardware-attested</span>
          <span>{props.fleetSharePct.toFixed(0)}% of model-ready fleet</span>
        </div>
      </div>

      <div className="mt-4 rounded-lg border border-border-dim bg-bg-primary/55 p-3">
        <div className="flex items-center justify-between gap-3">
          <div className="flex items-center gap-2">
            <Zap size={13} className="text-accent-brand" />
            <p className="text-xs font-semibold text-text-secondary">Current load</p>
          </div>
          <p className="font-mono text-[10px] text-text-tertiary">
            {props.warmNodes ?? 0} loaded · {props.coldNodes ?? 0} available to load
          </p>
        </div>
        <div className="mt-3 grid grid-cols-2 gap-x-5 gap-y-4 sm:grid-cols-5">
          <LoadMetric label="In progress" value={active.toLocaleString()} detail="active requests" />
          <LoadMetric
            label="Waiting"
            value={waiting.toLocaleString()}
            detail={queueLimit > 0 ? `${queueLimit} queue limit` : "no queue limit reported"}
            tone={queueAtLimit ? "amber" : undefined}
          />
          <LoadMetric
            label="KV headroom"
            value={kvHeadroom === null ? "—" : `${kvHeadroom}%`}
            detail="free token memory"
            tone={kvHeadroom !== null && kvHeadroom > 10 ? "green" : "amber"}
          />
          <LoadMetric
            label="Combined speed"
            value={props.aggregateTPS === undefined ? "—" : `${formatCompactNumber(props.aggregateTPS)} tok/s`}
            detail="estimated generation"
          />
          <LoadMetric
            label="First token"
            value={formatLatency(props.estimatedTTFTMS)}
            detail="best loaded node"
          />
        </div>
      </div>

      <div className="mt-4">
        <div className="flex items-center justify-between gap-3 text-[11px] text-text-tertiary">
          <span>{availability.accepting} of {availability.connected} connected nodes can accept a request now</span>
          <span className="font-mono font-semibold text-accent-green">{availability.acceptingPct}%</span>
        </div>
        <div className="mt-2 h-2 overflow-hidden rounded-full bg-bg-elevated">
          <div
            className="h-full rounded-full bg-accent-green/75 transition-[width] duration-500"
            style={{ width: `${availability.acceptingPct}%` }}
          />
        </div>
      </div>
    </article>
  );
}
