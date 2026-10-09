"use client";

// The machine grid: owns sort + density state, orders the cards, and renders
// them. Default sort surfaces machines that need attention first.

import { useMemo, useState } from "react";
import type { MyProvider } from "../types";
import { routingFor, type RoutingCtx, type RoutingState } from "./routing";
import { MachineCard } from "./MachineCard";
import { FleetControls, type Density, type SortMode } from "./FleetControls";

const STATE_RANK: Record<RoutingState, number> = {
  blocked: 0,
  offline: 1,
  degraded: 2,
  routable: 3,
};

export function MachineGrid({
  providers,
  ctx,
  fleetMaxDecodeTps,
  onRemoved,
}: {
  providers: MyProvider[];
  ctx: RoutingCtx;
  fleetMaxDecodeTps: number;
  onRemoved?: () => void;
}) {
  const [sort, setSort] = useState<SortMode>("attention");
  const [density, setDensity] = useState<Density>("grid");

  const sorted = useMemo(() => {
    const withState = providers.map((p) => ({ p, state: routingFor(p, ctx) }));
    withState.sort((a, b) => {
      if (sort === "name") {
        return (a.p.hardware.chip_name || "").localeCompare(b.p.hardware.chip_name || "");
      }
      // attention: worst routing state first, then by name for a stable order.
      const rank = STATE_RANK[a.state] - STATE_RANK[b.state];
      if (rank !== 0) return rank;
      return (a.p.hardware.chip_name || "").localeCompare(b.p.hardware.chip_name || "");
    });
    return withState.map((x) => x.p);
  }, [providers, ctx, sort]);

  return (
    <div className="space-y-3">
      <FleetControls
        count={providers.length}
        sort={sort}
        onSort={setSort}
        density={density}
        onDensity={setDensity}
      />
      <div className={`grid gap-4 ${density === "grid" ? "grid-cols-1 lg:grid-cols-2" : "grid-cols-1"}`}>
        {sorted.map((p) => (
          <MachineCard
            key={p.id}
            provider={p}
            ctx={ctx}
            fleetMaxDecodeTps={fleetMaxDecodeTps}
            onRemoved={onRemoved}
          />
        ))}
      </div>
    </div>
  );
}
