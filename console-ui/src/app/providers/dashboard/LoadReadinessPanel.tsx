import { AlertTriangle } from "lucide-react";
import type { MyProvider } from "../types";
import { shortModelName } from "./format";
import { coldModelReadiness } from "./load-readiness";

export function LoadReadinessPanel({ provider }: { provider: MyProvider }) {
  const models = coldModelReadiness(provider);
  if (models.length === 0) return null;
  const blocked = models.filter((model) => model.shortfallGb > 0 && model.canLoadAfterEviction === false);

  return (
    <section className="px-4 pb-3 space-y-2" aria-label="Model load readiness">
      <div className="flex items-center justify-between text-[10px] uppercase tracking-wider text-text-tertiary">
        <span>Cold model load readiness</span>
        <span>Live memory · last heartbeat</span>
      </div>
      {models.map((model) => {
        const cannotPreload = model.shortfallGb > 0;
        const cannotLoad = cannotPreload && model.canLoadAfterEviction === false;
        let label = "Fits now";
        if (cannotLoad) label = "Cannot cold-load now";
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
              {cannotPreload && <strong className="text-accent-amber"> · {model.shortfallGb.toFixed(1)} GB short for preload</strong>}
            </p>
            {cannotPreload && model.canLoadAfterEviction && (
              <p className="mt-1 text-text-secondary">A request may load it after evicting idle models; startup preload keeps existing slots resident.</p>
            )}
          </div>
        );
      })}
      {blocked.length > 0 && (
        <p className="text-[11px] text-text-secondary">
          Physical RAM is not the live load budget. Free memory on this Mac, confirm with{" "}
          <code className="font-mono">darkbloom doctor</code>, then restart to retry the load.
        </p>
      )}
    </section>
  );
}
