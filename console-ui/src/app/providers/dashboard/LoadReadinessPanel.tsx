import { AlertTriangle } from "lucide-react";
import type { MyProvider } from "../types";
import { shortModelName } from "./format";
import { coldModelReadiness } from "./load-readiness";

export function LoadReadinessPanel({ provider, heartbeatTimeoutSeconds }: {
  provider: MyProvider; heartbeatTimeoutSeconds: number;
}) {
  const models = coldModelReadiness(provider, heartbeatTimeoutSeconds);
  if (models.length === 0) return null;
  const blocked = models.filter((model) =>
    !model.busyServing && model.shortfallGb > 0 && model.canLoadAfterEviction === false);

  return (
    <section className="px-4 pb-3 space-y-2" aria-label="Model load readiness">
      <div className="flex items-center justify-between text-[10px] uppercase tracking-wider text-text-tertiary">
        <span>Cold model load readiness</span>
        <span>Live memory · last heartbeat</span>
      </div>
      {models.map((model) => {
        const cannotPreload = model.shortfallGb > 0;
        const cannotLoad = !model.busyServing && cannotPreload && model.canLoadAfterEviction === false;
        let label = "Fits now";
        if (model.busyServing && cannotPreload) label = "Busy serving";
        else if (cannotLoad) label = "Cannot cold-load now";
        else if (cannotPreload) label = "Preload blocked";
        return (
          <div key={model.model} className={`rounded-lg border px-3 py-2.5 text-xs ${
            cannotPreload ? "border-accent-amber/40 bg-accent-amber/10" : "border-border-dim bg-bg-tertiary/40"
          }`}>
            <div className="flex items-center gap-2 font-semibold">
              {cannotPreload && <AlertTriangle size={14} className="text-accent-amber shrink-0" aria-hidden="true" />}
              <span className="font-mono text-text-primary truncate" title={model.model}>{shortModelName(model.model)}</span>
              <span className={`ml-auto shrink-0 ${cannotPreload ? "text-accent-amber" : "text-accent-green"}`}>
                {label}
              </span>
            </div>
            <p className="mt-1.5 font-mono text-text-secondary tabular-nums">
              {model.estimatedGb.toFixed(1)} GB model + {model.headroomGb.toFixed(1)} GB serving reserve
              {" = "}{model.requiredGb.toFixed(1)} GB needed
            </p>
            <p className="mt-1 text-text-secondary tabular-nums">
              {model.usableGb.toFixed(1)} GB usable now
              {cannotPreload && <strong className="text-accent-amber"> · {model.shortfallGb.toFixed(1)} GB short without eviction</strong>}
            </p>
            {cannotLoad && model.coldLoadShortfallGb !== undefined && (
              <p className="mt-1 font-semibold text-accent-amber tabular-nums">
                Still {model.coldLoadShortfallGb.toFixed(1)} GB short after idle eviction.
              </p>
            )}
            {model.busyServing && cannotPreload && (
              <p className="mt-1 text-text-secondary">Another request is active. Recheck this load budget when the Mac is idle.</p>
            )}
            {cannotPreload && model.canLoadAfterEviction && (
              <p className="mt-1 text-text-secondary">A request may load it after evicting idle models; startup preload keeps existing slots resident.</p>
            )}
          </div>
        );
      })}
      {blocked.length > 0 && (
        <p className="text-[11px] text-text-secondary">
          Physical RAM is not the live load budget. Free at least{" "}
          {Math.max(...blocked.map((model) => model.coldLoadShortfallGb ?? 0)).toFixed(1)} GB
          {" "}of usable memory with margin, confirm with{" "}
          <code className="font-mono">darkbloom doctor</code>, then restart to retry the load.
        </p>
      )}
    </section>
  );
}
