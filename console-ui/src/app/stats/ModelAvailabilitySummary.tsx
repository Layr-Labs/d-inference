import { Gauge } from "lucide-react";
import { calculateModelAvailability } from "./model-capacity";
import { modelBrand } from "./model-brand";
import { ModelMakerMark } from "./ModelMakerMark";

const UNKNOWN_VALUE_CLASS = "text-text-tertiary";
const READY_VALUE_CLASS = "text-accent-green";

export interface ModelAvailabilitySummaryItem {
  id: string;
  displayName: string;
  family?: string;
  connected: number;
  eligible: number;
  accepting?: number;
  fleetSharePct: number;
}

function AvailabilityRow({ item }: { item: ModelAvailabilitySummaryItem }) {
  const availability = calculateModelAvailability(item.connected, item.eligible, item.accepting);
  const eligibleBusy = availability.accepting === null
    ? 0
    : Math.max(0, availability.eligible - availability.accepting);
  const busyPct = availability.accepting !== null && availability.connected > 0
    ? (eligibleBusy / availability.connected) * 100
    : 0;
  const brand = modelBrand(item.id, item.family);
  return (
    <div className="rounded-xl border border-border-dim bg-bg-white p-3">
      <div className="flex items-center gap-3">
        <ModelMakerMark modelId={item.id} family={item.family} compact />
        <div className="min-w-0 flex-1">
          <p className="truncate text-sm font-semibold text-text-primary">{item.displayName}</p>
          <p className="mt-0.5 font-mono text-[9px] uppercase tracking-wider text-text-tertiary">
            {brand.makerLabel} · {item.fleetSharePct.toFixed(0)}% of placements
          </p>
        </div>
        <div className="shrink-0 text-right">
          <p className={`font-mono text-sm font-bold ${availability.accepting === null ? UNKNOWN_VALUE_CLASS : READY_VALUE_CLASS}`}>
            {availability.accepting === null ? "—" : `${availability.accepting}/${availability.connected}`}
          </p>
          <p className="mt-0.5 font-mono text-[9px] text-text-tertiary">
            {availability.acceptingPct === null ? "admission unknown" : `${availability.acceptingPct}% ready`}
          </p>
        </div>
      </div>
      <div
        className="mt-3 flex h-2 overflow-hidden rounded-full bg-bg-elevated"
        aria-label={availability.acceptingPct === null
          ? `${item.displayName}: immediate availability unknown`
          : `${item.displayName}: ${availability.acceptingPct}% immediately available`}
      >
        <span className="bg-accent-green" style={{ width: `${availability.acceptingPct ?? 0}%` }} />
        <span className="bg-accent-amber/55" style={{ width: `${busyPct}%` }} />
        <span className="flex-1 bg-bg-elevated" />
      </div>
      <div className="mt-2 flex items-center justify-between gap-3 font-mono text-[9px] text-text-tertiary">
        <span>{availability.accepting === null ? "Admission unavailable" : `${availability.accepting} accepting now`}</span>
        <span>{availability.accepting === null ? `${availability.eligible} eligible` : `${eligibleBusy} eligible, at capacity`}</span>
      </div>
    </div>
  );
}

export function ModelAvailabilitySummary({
  items,
  totalPlacements,
  eligiblePlacements,
  acceptingPlacements,
}: {
  items: ModelAvailabilitySummaryItem[];
  totalPlacements: number;
  eligiblePlacements: number;
  acceptingPlacements: number | null;
}) {
  let immediatePct: number | null = null;
  if (acceptingPlacements !== null) {
    immediatePct = totalPlacements > 0
      ? Math.round((acceptingPlacements / totalPlacements) * 100)
      : 0;
  }
  const availabilityCallout = acceptingPlacements === null
    ? "border-border-dim bg-bg-primary/70"
    : "border-accent-green bg-accent-green/10";
  const availabilityText = acceptingPlacements === null
    ? "text-text-secondary"
    : READY_VALUE_CLASS;
  return (
    <aside className="rounded-xl border border-border-dim bg-bg-secondary p-4">
      <div className="flex items-start justify-between gap-3">
        <div>
          <div className="flex items-center gap-2">
            <Gauge size={14} className="text-accent-brand" />
            <h3 className="text-xs font-semibold text-text-primary">Model readiness</h3>
          </div>
          <p className="mt-1 text-[10px] leading-4 text-text-tertiary">
            Compare immediate admission across the live model fleet.
          </p>
        </div>
        <div className="shrink-0 text-right">
          <p className={`font-mono text-2xl font-bold ${immediatePct === null ? UNKNOWN_VALUE_CLASS : READY_VALUE_CLASS}`}>
            {immediatePct === null ? "—" : `${immediatePct}%`}
          </p>
          <p className="mt-0.5 font-mono text-[9px] uppercase tracking-wider text-text-tertiary">
            {immediatePct === null ? "unknown" : "ready now"}
          </p>
        </div>
      </div>

      <div className={`mt-4 rounded-lg border-l-4 px-3 py-2.5 ${availabilityCallout}`}>
        <p className={`text-xs font-semibold ${availabilityText}`}>
          {acceptingPlacements === null
            ? "Live admission data is currently unavailable"
            : `${acceptingPlacements} of ${totalPlacements} placements can accept a request`}
        </p>
        <p className="mt-1 text-[10px] leading-4 text-text-secondary">
          {eligiblePlacements} pass trust and health checks; current concurrency and KV memory determine immediate admission.
        </p>
      </div>

      <div className="mt-3 space-y-2.5">
        {items.length === 0 ? (
          <p className="rounded-lg border border-dashed border-border-subtle bg-bg-white p-4 text-xs text-text-tertiary">
            No active catalog models are visible.
          </p>
        ) : items.map((item) => <AvailabilityRow key={item.id} item={item} />)}
      </div>

      <div className="mt-3 flex flex-wrap items-center gap-x-3 gap-y-1 font-mono text-[9px] text-text-tertiary">
        <span className="inline-flex items-center gap-1"><span className="h-1.5 w-1.5 rounded-full bg-accent-green" />Accepting now</span>
        <span className="inline-flex items-center gap-1"><span className="h-1.5 w-1.5 rounded-full bg-accent-amber/70" />Eligible, at capacity</span>
        <span className="inline-flex items-center gap-1"><span className="h-1.5 w-1.5 rounded-full bg-bg-elevated" />Unavailable</span>
      </div>
    </aside>
  );
}
