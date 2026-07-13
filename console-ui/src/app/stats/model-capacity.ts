export interface ModelAvailability {
  connected: number;
  eligible: number;
  accepting: number;
  acceptingPct: number;
}
function nonNegativeInteger(value: number | undefined): number {
  if (!Number.isFinite(value)) return 0;
  return Math.max(0, Math.floor(value ?? 0));
}

/**
 * Reconciles the unique provider count from /v1/stats with the stricter,
 * load-aware count from /v1/models/capacity. Alias capacity can sum multiple
 * concrete builds, so accepting is bounded by the unique eligible provider
 * count before it is presented as a percentage.
 */
export function calculateModelAvailability(
  totalNodes: number,
  eligibleNodes: number,
  reportedAcceptingNodes?: number,
): ModelAvailability {
  const connected = nonNegativeInteger(totalNodes);
  const eligible = Math.min(connected, nonNegativeInteger(eligibleNodes));
  const accepting = Math.min(
    eligible,
    reportedAcceptingNodes === undefined
      ? eligible
      : nonNegativeInteger(reportedAcceptingNodes),
  );
  return {
    connected,
    eligible,
    accepting,
    acceptingPct: connected > 0 ? Math.round((accepting / connected) * 100) : 0,
  };
}

/** Remaining pooled KV/token budget as a bounded free-headroom percentage. */
export function calculateKVHeadroom(
  remaining?: number,
  total?: number,
): number | null {
  if (!Number.isFinite(total) || (total ?? 0) <= 0 || !Number.isFinite(remaining)) {
    return null;
  }
  return Math.max(0, Math.min(100, Math.round(((remaining ?? 0) / (total ?? 1)) * 100)));
}
