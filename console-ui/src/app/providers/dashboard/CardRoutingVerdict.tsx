// Show routing readiness and the next diagnostic action, independently of earnings.

import { AlertTriangle, CheckCircle2, CircleSlash, XCircle, type LucideIcon } from "lucide-react";
import { GITHUB_REPO_URL } from "@/components/community/constants";
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
  // top warning. A ready machine can still receive no requests.
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
            <p className="text-xs text-text-tertiary mt-1">No blocking warnings reported. Traffic depends on model demand and routing.</p>
          ) : null}
        </div>

        {state === "routable" ? (
          <a
            href={`${GITHUB_REPO_URL}/blob/master/docs/provider/troubleshooting.md#healthy-but-no-requests`}
            target="_blank"
            rel="noopener noreferrer"
            className="text-xs text-text-secondary underline shrink-0 mt-0.5 focus-ring"
          >
            Healthy but no requests?
          </a>
        ) : fix ? (
          <div className="shrink-0">
            <FixAffordance fix={fix} compact showNote={false} />
          </div>
        ) : null}
      </div>
    </div>
  );
}
