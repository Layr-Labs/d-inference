"use client";

import { useMemo, useState } from "react";
import type { CapacityModelSummary, CatalogDataSummary } from "@/lib/stats-model-filter";
import type { PlatformStats } from "../platform-types";
import { formatCompactNumber } from "../format";
import { CAPACITY_LANE_COLUMNS, ModelCapacityLane } from "./ModelCapacityLane";
import { prepareModelInventory } from "./model-inventory";

export function ModelCapacityLandscape({ stats, catalogData, capacityModels }: {
  stats: PlatformStats;
  catalogData: CatalogDataSummary | null;
  capacityModels: CapacityModelSummary[] | null;
}) {
  const [showDeprecated, setShowDeprecated] = useState(false);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const inventory = useMemo(() => prepareModelInventory(stats, catalogData, capacityModels, showDeprecated), [stats, catalogData, capacityModels, showDeprecated]);
  const maxNodes = Math.max(0, ...inventory.models.map((item) => item.providers));
  const ticks = [0, maxNodes];

  return (
    <section aria-labelledby="model-capacity-title" className="min-w-0">
      <div className="flex flex-wrap items-start justify-between gap-x-6 gap-y-4">
        <div><h2 id="model-capacity-title" className="text-xl font-semibold tracking-tight text-text-primary">Model capacity</h2><p className="mt-2 text-sm leading-6 text-text-tertiary">How much of each model’s connected capacity can take a request.</p></div>
        {inventory.deprecatedCount > 0 && <label className="flex min-h-10 cursor-pointer items-center gap-2 text-xs text-text-secondary"><input type="checkbox" aria-label="Include deprecated models in capacity chart" checked={showDeprecated} onChange={(event) => setShowDeprecated(event.target.checked)} className="h-4 w-4 accent-accent-brand" />Include deprecated ({inventory.deprecatedCount})</label>}
      </div>
      <div className="mt-5 flex flex-wrap items-center gap-x-6 gap-y-2 text-xs text-text-tertiary" aria-label="Capacity chart legend">
        <span className="inline-flex items-center gap-2"><span className="h-2 w-5 rounded-sm bg-accent-brand" aria-hidden="true" />Accepting requests</span>
        <span className="inline-flex items-center gap-2"><span className="h-2 w-5 rounded-sm bg-text-tertiary/25" aria-hidden="true" />Connected capacity</span>
        <span className="lg:ml-auto">Shared node scale across all models</span>
      </div>
      {inventory.models.length > 0 ? (
        <>
          <div className={`mt-7 hidden items-end gap-6 text-xs text-text-tertiary lg:grid ${CAPACITY_LANE_COLUMNS}`} aria-hidden="true">
            <span>Model</span><span className="flex justify-between tabular-nums">{ticks.map((tick, index) => <span key={index}>{formatCompactNumber(tick)}</span>)}</span><span className="text-right">Generation estimate</span><span />
          </div>
          <div className="mt-3 border-t border-border-dim">
            {inventory.models.map((item) => <ModelCapacityLane key={item.id} item={item} capacityKnown={inventory.capacityKnown} maxNodes={maxNodes} expanded={selectedId === item.id} onToggle={() => setSelectedId((current) => current === item.id ? null : item.id)} />)}
          </div>
        </>
      ) : <div className="mt-6 border-y border-border-dim py-10 text-sm text-text-tertiary">No currently served models. Capacity will appear when providers connect.</div>}
      <p className="mt-4 max-w-3xl text-xs leading-5 text-text-tertiary">One node can advertise multiple models. Accepting counts come from the capacity snapshot; generation is an estimate, not measured network output. Open a lane for details.</p>
    </section>
  );
}
