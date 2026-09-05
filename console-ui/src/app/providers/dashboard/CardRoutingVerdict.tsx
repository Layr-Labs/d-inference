import { AlertTriangle, CheckCircle2, CircleSlash, XCircle, type LucideIcon } from "lucide-react";
import type { MyProvider } from "../types";
import type { Warning } from "../warnings";
import { routingMeta, type RoutingState } from "./routing";
import { freshServiceStatus, serviceReason } from "./serviceStatus";
import { formatRelative, shortModelName } from "./format";

const ICON: Record<RoutingState, LucideIcon> = {
  routable: CheckCircle2, degraded: AlertTriangle, blocked: XCircle,
  offline: CircleSlash, unknown: CircleSlash,
};

export function CardRoutingVerdict({ provider, state }: {
  provider: MyProvider; state: RoutingState; topWarning: Warning | null;
}) {
  const meta = routingMeta(state);
  const Icon = ICON[state];
  const status = freshServiceStatus(provider);
  const pending = status?.pending_requests ?? 0;
  let title = meta.verb;
  if (state === "offline") title = `Offline — last seen ${formatRelative(provider.last_heartbeat || provider.last_seen)}`;
  else if (status?.state === "draining") title = "Finishing existing work";
  else if (status?.state === "busy") title = "At capacity for this workload";
  const requestLabel = pending === 1 ? "request" : "requests";
  const progress = pending > 0 ? `${pending} ${requestLabel} in progress.` : "No requests currently in progress.";
  return (
    <div className={`px-4 py-3 border-t border-border-dim/40 ${meta.tint}`}>
      <div className={`flex items-center gap-2 text-sm font-semibold ${meta.color}`}>
        <Icon size={16} className="shrink-0" /><span>{title}</span>
      </div>
      {status ? <>
        {status.reason && <p className="text-xs text-text-secondary mt-1">{serviceReason(status.reason)}</p>}
        <p className="text-xs text-text-secondary mt-1">
          {progress}
          {" "}Checked {formatRelative(status.observed_at)}.
        </p>
        <details className="mt-2 text-xs text-text-secondary">
          <summary className="cursor-pointer">Public routing checks by model</summary>
          <p className="mt-2">Plain text · {status.probe.prompt_tokens} input / {status.probe.max_tokens} output tokens. Other request sizes, capabilities and deadlines may differ. These are normal routing checks; emergency fallback can differ. This check does not reserve capacity or guarantee traffic.</p>
          <ul className="mt-2 space-y-1">
            {status.models.map((model) => <li key={model.model}>
              <span className="font-medium">{shortModelName(model.model)}</span>{": "}
              {serviceReason(model.reason)}{model.eligible && model.capacity_rate_ms > 0 ? " · recent capacity refusals affect preference" : ""}
            </li>)}
          </ul>
        </details>
      </> : state !== "offline" && <p className="text-xs text-text-secondary mt-1">
        A fresh coordinator routing check is unavailable. Connection status and diagnostics are shown separately.
      </p>}
    </div>
  );
}
