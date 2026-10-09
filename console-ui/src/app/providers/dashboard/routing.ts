// Routing eligibility — the single source of truth for "is this machine
// earning right now?". The fleet strip, the attention feed, and each machine
// card all derive their verdict from here so the glance, the list, and the
// detail can never disagree.
//
// A machine earns only if the coordinator routes work to it. We map the
// existing warning severities onto an earning verdict:
//   offline  -> not connected (status offline/never_seen)
//   blocked  -> connected but receives ZERO requests (any blocking warning)
//   degraded -> routable at reduced priority (any degrading warning)
//   routable -> healthy, full priority, earning

import type { MyProvider, MyProvidersResponse } from "../types";
import { computeWarnings, type Warning, type WarningSeverity } from "../warnings";

export type RoutingState = "routable" | "degraded" | "blocked" | "offline";

/** The slice of the /v1/me/providers response that warning logic needs. */
export type RoutingCtx = Pick<
  MyProvidersResponse,
  | "latest_provider_version"
  | "min_provider_version"
  | "heartbeat_timeout_seconds"
  | "challenge_max_age_seconds"
>;

/** Default ctx so callers (and tests) never pass undefined fields. */
export const DEFAULT_CTX: RoutingCtx = {
  latest_provider_version: "",
  min_provider_version: "",
  heartbeat_timeout_seconds: 90,
  challenge_max_age_seconds: 360,
};

/** Derive the earning verdict from a machine + its computed warnings. */
export function deriveRouting(p: MyProvider, warnings: Warning[]): RoutingState {
  if (p.status === "offline" || p.status === "never_seen") return "offline";
  if (warnings.some((w) => w.severity === "blocking")) return "blocked";
  if (warnings.some((w) => w.severity === "degrading")) return "degraded";
  return "routable";
}

/** Convenience: compute warnings and derive routing in one call. */
export function routingFor(p: MyProvider, ctx: RoutingCtx): RoutingState {
  return deriveRouting(p, computeWarnings(p, ctx));
}

export interface RoutingMeta {
  state: RoutingState;
  /** Tailwind text color class for the accent. */
  color: string;
  /** Tailwind background tint class for banners. */
  tint: string;
  /** Tailwind border color for the left rail. */
  rail: string;
  /** Short status label ("Earning", "Degraded", ...). */
  label: string;
  /** Load-bearing verb shown on the card hero. */
  verb: string;
  /** Tailwind background for the segmented capacity bar segment. */
  segment: string;
}

const META: Record<RoutingState, RoutingMeta> = {
  routable: {
    state: "routable",
    color: "text-accent-green",
    tint: "bg-accent-green/8",
    rail: "border-l-accent-green",
    label: "Earning",
    verb: "EARNING — receiving traffic",
    segment: "bg-accent-green",
  },
  degraded: {
    state: "degraded",
    color: "text-accent-amber",
    tint: "bg-accent-amber/8",
    rail: "border-l-accent-amber",
    label: "Degraded",
    verb: "EARNING (reduced priority)",
    segment: "bg-accent-amber",
  },
  blocked: {
    state: "blocked",
    color: "text-accent-red",
    tint: "bg-accent-red/10",
    rail: "border-l-accent-red",
    label: "Not earning",
    verb: "NOT EARNING — 0 requests",
    segment: "bg-accent-red",
  },
  offline: {
    state: "offline",
    color: "text-text-tertiary",
    tint: "bg-bg-tertiary",
    rail: "border-l-border-subtle",
    label: "Offline",
    verb: "OFFLINE — not connected",
    segment: "bg-text-tertiary/40",
  },
};

export function routingMeta(state: RoutingState): RoutingMeta {
  return META[state];
}

/** Severity ordering used everywhere we rank issues. */
export const SEVERITY_RANK: Record<WarningSeverity, number> = {
  blocking: 0,
  degrading: 1,
  info: 2,
};

/**
 * The single most important warning to surface in the card hero — highest
 * severity first, original order preserved within a severity (warnings.ts
 * pushes blocking reasons in priority order).
 */
export function selectTopWarning(warnings: Warning[]): Warning | null {
  if (warnings.length === 0) return null;
  return [...warnings].sort(
    (a, b) => SEVERITY_RANK[a.severity] - SEVERITY_RANK[b.severity]
  )[0];
}
