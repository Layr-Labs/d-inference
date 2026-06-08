// Fleet-level aggregation: turns a list of machines + the warning engine into
// the cross-machine attention feed and the top-of-page verdict. Pure functions
// so the feed, the strip, and the cards can all share one consistent view and
// never disagree.

import type { MyProvider } from "../types";
import { computeWarnings, type Warning, type WarningSeverity } from "../warnings";
import {
  deriveRouting,
  routingMeta,
  SEVERITY_RANK,
  type RoutingCtx,
  type RoutingState,
} from "./routing";
import { resolveFix, type FixAction } from "./fixes";

/** One deduped issue affecting one or more machines. */
export interface AttentionGroup {
  id: string;
  severity: WarningSeverity;
  title: string;
  detail: string;
  fix: FixAction;
  providers: MyProvider[];
}

/**
 * Build the deduped, ranked attention feed. Identical warning ids across
 * machines collapse into a single group (with the affected machines attached),
 * so a 20-machine "update available" shows as one actionable row, not twenty.
 */
export function buildAttentionGroups(
  providers: MyProvider[],
  ctx: RoutingCtx
): AttentionGroup[] {
  const groups = new Map<string, AttentionGroup>();

  for (const p of providers) {
    const warnings = computeWarnings(p, ctx);
    for (const w of warnings) {
      const existing = groups.get(w.id);
      if (existing) {
        existing.providers.push(p);
      } else {
        groups.set(w.id, {
          id: w.id,
          severity: w.severity,
          title: w.title,
          detail: w.detail,
          fix: resolveFix(w.id),
          providers: [p],
        });
      }
    }
  }

  return [...groups.values()].sort((a, b) => {
    const sev = SEVERITY_RANK[a.severity] - SEVERITY_RANK[b.severity];
    if (sev !== 0) return sev;
    const count = b.providers.length - a.providers.length;
    if (count !== 0) return count;
    return a.title.localeCompare(b.title);
  });
}

export interface FleetCounts {
  routable: number;
  degraded: number;
  blocked: number;
  offline: number;
  total: number;
}

export interface FleetVerdict {
  /** The headline state: worst of (blocked > offline > degraded > routable). */
  state: RoutingState;
  counts: FleetCounts;
  headline: string;
  sub: string;
}

/** Per-machine routing state for the whole fleet, plus the headline verdict. */
export function deriveFleetVerdict(
  providers: MyProvider[],
  ctx: RoutingCtx
): FleetVerdict {
  const counts: FleetCounts = {
    routable: 0,
    degraded: 0,
    blocked: 0,
    offline: 0,
    total: providers.length,
  };

  for (const p of providers) {
    const state = deriveRouting(p, computeWarnings(p, ctx));
    counts[state]++;
  }

  const { total } = counts;
  let state: RoutingState;
  let headline: string;
  let sub: string;

  if (counts.blocked > 0) {
    state = "blocked";
    headline = `${counts.blocked} machine${counts.blocked === 1 ? "" : "s"} not earning`;
    sub = "Blocked from routing — fix below.";
  } else if (counts.offline > 0 && counts.offline === total) {
    state = "offline";
    headline = "Fleet offline";
    sub = "No machines connected.";
  } else if (counts.offline > 0) {
    state = "offline";
    headline = `${counts.offline} machine${counts.offline === 1 ? "" : "s"} offline`;
    sub = "Not connected — earning $0 while down.";
  } else if (counts.degraded > 0) {
    state = "degraded";
    headline = `${counts.degraded} machine${counts.degraded === 1 ? "" : "s"} degraded`;
    sub = "Still earning at reduced priority.";
  } else {
    state = "routable";
    headline = "Everything's earning";
    sub = total === 1 ? "Your machine is routable. No action needed." : `All ${total} machines routable. No action needed.`;
  }

  return { state, counts, headline, sub };
}

/** Convenience for the capacity bar: ordered segments with counts + colors. */
export function capacitySegments(counts: FleetCounts) {
  return (["routable", "degraded", "blocked", "offline"] as RoutingState[])
    .map((state) => ({
      state,
      count: counts[state],
      meta: routingMeta(state),
    }))
    .filter((s) => s.count > 0);
}

/** Largest decode TPS across the fleet — used to scale per-card TPS bars. */
export function fleetMaxDecodeTps(providers: MyProvider[]): number {
  let max = 0;
  for (const p of providers) {
    if (typeof p.decode_tps === "number" && p.decode_tps > max) max = p.decode_tps;
  }
  return max;
}

/** Aggregate live decode throughput across connected machines. */
export function fleetDecodeTps(providers: MyProvider[]): number {
  let sum = 0;
  for (const p of providers) {
    if (typeof p.decode_tps === "number" && Number.isFinite(p.decode_tps)) sum += p.decode_tps;
  }
  return sum;
}

/** Count machines that are currently connected (online or serving). */
export function onlineCount(providers: MyProvider[]): number {
  return providers.filter((p) => p.status === "online" || p.status === "serving").length;
}

export type { RoutingState, Warning };
