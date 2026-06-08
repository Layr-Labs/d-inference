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
}: {
  providers: MyProvider[];
  ctx: RoutingCtx;
  fleetMaxDecodeTps: number;
}) {
  const [sort, setSort] = useState<SortMode>("attention");
  const [density, setDensity] = useState<Density>("grid");

  const sorted = useMemo(() => {
    const withState = providers.map((p) => ({ p, state: routingFor(p, ctx) }));
    withState.sort((a, b) => {
      if (sort === "earnings") {
        return b.p.earnings_total_micro_usd - a.p.earnings_total_micro_usd;
      }
      if (sort === "name") {
        return (a.p.hardware.chip_name || "").localeCompare(b.p.hardware.chip_name || "");
      }
      // attention: worst routing state first, then higher earners.
      const rank = STATE_RANK[a.state] - STATE_RANK[b.state];
      if (rank !== 0) return rank;
      return b.p.earnings_total_micro_usd - a.p.earnings_total_micro_usd;
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
          <MachineCard key={p.id} provider={p} ctx={ctx} fleetMaxDecodeTps={fleetMaxDecodeTps} />
        ))}
      </div>
    </div>
  );
}
