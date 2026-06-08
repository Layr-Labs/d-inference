// The hero of every machine card: a full-width banner that states, in the
// load-bearing verb EARNING / NOT EARNING, whether this machine is making
// money right now — plus the single most important WHY and the FIX, so the
// next action is always one click away without expanding anything.

import { AlertTriangle, CheckCircle2, CircleSlash, XCircle, type LucideIcon } from "lucide-react";
import type { MyProvider } from "../types";
import type { Warning } from "../warnings";
import { routingMeta, type RoutingState } from "./routing";
import { resolveFix } from "./fixes";
import { FixAffordance } from "./FixAffordance";
import { formatRelative } from "./format";

const ICON: Record<RoutingState, LucideIcon> = {
  routable: CheckCircle2,
  degraded: AlertTriangle,
  blocked: XCircle,
  offline: CircleSlash,
};

export function CardRoutingVerdict({
  provider,
  state,
  topWarning,
}: {
  provider: MyProvider;
  state: RoutingState;
  topWarning: Warning | null;
}) {
  const meta = routingMeta(state);
  const Icon = ICON[state];

  // Offline machines describe themselves by last-seen; everyone else by the
  // top warning. Routable machines have nothing to fix.
  const verb =
    state === "offline"
      ? `OFFLINE — last seen ${formatRelative(provider.last_heartbeat || provider.last_seen)}`
      : meta.verb;

  const why = state === "routable" ? null : topWarning?.title ?? null;
  const fix = topWarning ? resolveFix(topWarning.id) : null;

  return (
    <div className={`px-4 py-3 border-t border-border-dim/40 ${meta.tint}`}>
      <div className="flex items-start justify-between gap-3 flex-wrap">
        <div className="min-w-0">
          <div className={`flex items-center gap-2 text-sm font-semibold ${meta.color}`}>
            <Icon size={16} className="shrink-0" />
            <span className="tracking-tight">{verb}</span>
          </div>
          {why ? (
            <p className="text-xs text-text-secondary mt-1 leading-snug">{why}</p>
          ) : state === "routable" ? (
            <p className="text-xs text-text-tertiary mt-1">Full routing priority — no action needed.</p>
          ) : null}
        </div>

        {state === "routable" ? (
          <span className="text-[11px] font-mono text-text-tertiary shrink-0 mt-0.5">priority: normal</span>
        ) : fix ? (
          <div className="shrink-0">
            <FixAffordance fix={fix} compact showNote={false} />
          </div>
        ) : null}
      </div>
    </div>
  );
}
