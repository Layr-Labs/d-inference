// Models on a machine: the loaded/warm set (active one highlighted, with
// cold/crashed/reloading tags pulled from backend slot state) and the catalog
// it's approved to serve. Mono pills; catalog collapses past a threshold to
// protect density.

import type { MyProvider } from "../types";
import { shortModelName } from "./format";

const CATALOG_LIMIT = 8;

const SLOT_TAG: Record<string, { label: string; cls: string }> = {
  idle_shutdown: { label: "cold", cls: "bg-accent-amber/15 text-accent-amber" },
  crashed: { label: "crashed", cls: "bg-accent-red/15 text-accent-red" },
  reloading: { label: "reloading", cls: "bg-blue/15 text-blue" },
};

export function ModelsStrip({ provider }: { provider: MyProvider }) {
  // Prefer the reported warm set; fall back to the single current model.
  const warm = provider.warm_models?.length
    ? provider.warm_models
    : provider.current_model
      ? [provider.current_model]
      : [];

  // Map model id -> backend slot state so we can tag cold/crashed/reloading.
  const slotState = new Map<string, string>();
  for (const s of provider.backend_capacity?.slots ?? []) slotState.set(s.model, s.state);

  // Catalog can be long; show a window and collapse the rest to "+N".
  const catalog = provider.models ?? [];
  const shownCatalog = catalog.slice(0, CATALOG_LIMIT);
  const extraCatalog = catalog.length - shownCatalog.length;

  if (warm.length === 0 && catalog.length === 0) {
    return <p className="px-4 pb-3 text-xs text-text-tertiary">No models loaded yet.</p>;
  }

  return (
    <div className="px-4 pb-3 space-y-2.5">
      {warm.length > 0 && (
        <div className="space-y-1.5">
          <p className="text-[10px] uppercase tracking-wider text-text-tertiary">Loaded</p>
          <div className="flex flex-wrap gap-1.5">
            {warm.map((m) => {
              const active = m === provider.current_model;
              const tag = SLOT_TAG[slotState.get(m) ?? ""];
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
                  {tag && (
                    <span className={`px-1 rounded text-[10px] font-semibold uppercase ${tag.cls}`} title={`backend ${slotState.get(m)}`}>
                      {tag.label}
                    </span>
                  )}
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
    </div>
  );
}
