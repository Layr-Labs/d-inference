// Loaded models use the same slot snapshot as the fleet overview. The catalog
// lists approved models, including those currently unloaded.

import { loadedModels } from "./activity";
import type { MyProvider } from "../types";
import { describeIdlePolicy, shortModelName } from "./format";

const CATALOG_LIMIT = 8;

export function ModelsStrip({ provider }: { provider: MyProvider }) {
  const warm = loadedModels(provider);

  // Catalog can be long; show a window and collapse the rest to "+N".
  const catalog = provider.models ?? [];
  const shownCatalog = catalog.slice(0, CATALOG_LIMIT);
  const extraCatalog = catalog.length - shownCatalog.length;

  // The operator's idle-memory policy tells the reader whether an empty
  // "Loaded" set is by design (sleeping, wakes on demand) or a problem.
  const idlePolicy = provider.online ? describeIdlePolicy(provider.idle_unload_mins) : undefined;
  const sleeping =
    provider.online && warm.length === 0 && catalog.length > 0 && (provider.idle_unload_mins ?? 0) > 0
    && !provider.backend_capacity?.slots.some((slot) => slot.state !== "idle_shutdown");

  if (warm.length === 0 && catalog.length === 0) {
    return <p className="px-4 pb-3 text-xs text-text-tertiary">No models loaded yet.</p>;
  }

  return (
    <div className="px-4 pb-3 space-y-2.5">
      {sleeping && (
        <p className="text-xs text-text-tertiary" data-testid="models-sleeping">
          Nothing loaded right now — sleeping until the next request (~10–30 s to reload).
        </p>
      )}
      {warm.length > 0 && (
        <div className="space-y-1.5">
          <p className="text-[10px] uppercase tracking-wider text-text-tertiary">Loaded</p>
          <div className="flex flex-wrap gap-1.5">
            {warm.map((m) => {
              const active = provider.backend_capacity
                ? provider.backend_capacity.slots.some((slot) => slot.model === m && slot.num_running > 0)
                : provider.status === "serving" && m === provider.current_model;
              return (
                <span
                  key={m}
                  className={`inline-flex items-center gap-1.5 px-2 py-0.5 rounded-md text-xs font-mono ${
                    active ? "bg-accent-brand/15 text-accent-brand" : "bg-bg-tertiary text-text-secondary"
                  }`}
                >
                  {active && <span className="w-1.5 h-1.5 rounded-full bg-accent-green animate-pulse" />}
                  {shortModelName(m)}
                  {active && <span className="opacity-70">active</span>}
                </span>
              );
            })}
          </div>
        </div>
      )}

      {catalog.length > 0 && (
        <div className="space-y-1.5">
          <p className="text-[10px] uppercase tracking-wider text-text-tertiary">
            Catalog ({catalog.length})
          </p>
          <div className="flex flex-wrap gap-1.5">
            {shownCatalog.map((m) => (
              <span key={m.id} className="px-2 py-0.5 rounded-md bg-bg-tertiary/70 text-xs font-mono text-text-tertiary">
                {shortModelName(m.id)}
              </span>
            ))}
            {extraCatalog > 0 && (
              <span className="px-2 py-0.5 rounded-md bg-bg-tertiary/70 text-xs font-mono text-text-tertiary">
                +{extraCatalog}
              </span>
            )}
          </div>
        </div>
      )}

      {idlePolicy && (
        <p className="text-[11px] text-text-tertiary" data-testid="idle-policy">
          <span className="uppercase tracking-wider text-[10px]">Memory when idle</span>
          {" · "}
          {idlePolicy}
        </p>
      )}
    </div>
  );
}
