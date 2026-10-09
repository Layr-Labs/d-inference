// Fleet capacity bar — one segmented bar showing how many machines are
// routable / degraded / blocked / offline, sized proportionally to machine
// count, with a labelled dot legend so the colors are never ambiguous.

import { capacitySegments, type FleetCounts } from "../aggregate";
import { routingMeta, type RoutingState } from "../routing";

const LABEL: Record<RoutingState, string> = {
  routable: "Earning",
  degraded: "Degraded",
  blocked: "Blocked",
  offline: "Offline",
};

export function CapacityBar({ counts }: { counts: FleetCounts }) {
  const segments = capacitySegments(counts);
  const total = counts.total || 1;

  return (
    <div className="space-y-2">
      <div className="flex w-full h-2 rounded-full overflow-hidden bg-bg-tertiary" aria-hidden="true">
        {segments.map((s) => (
          <div
            key={s.state}
            className={`${s.meta.segment} h-full first:rounded-l-full last:rounded-r-full`}
            style={{ flexBasis: `${(s.count / total) * 100}%`, minWidth: s.count > 0 ? "6px" : 0 }}
            title={`${s.count} ${LABEL[s.state]}`}
          />
        ))}
      </div>
      <div className="flex flex-wrap items-center gap-x-4 gap-y-1">
        {(["routable", "degraded", "blocked", "offline"] as RoutingState[])
          .filter((state) => counts[state] > 0)
          .map((state) => (
            <span key={state} className="inline-flex items-center gap-1.5 text-[11px] text-text-secondary">
              <span className={`w-1.5 h-1.5 rounded-full ${routingMeta(state).segment}`} />
              <span className="font-mono text-text-primary">{counts[state]}</span>
              {LABEL[state]}
            </span>
          ))}
      </div>
    </div>
  );
}
