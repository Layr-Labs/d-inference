export interface CPUCores {
  total: number;
  performance: number;
  efficiency: number;
}

export interface ProviderStats {
  id: string;
  chip: string;
  chip_family: string;
  chip_tier: string;
  machine_model: string;
  memory_gb: number;
  gpu_cores: number;
  cpu_cores: CPUCores;
  memory_bandwidth_gbs: number;
  status: string;
  trust_level: string;
  decode_tps: number;
  current_model?: string;
  models?: string[];
  requests_served: number;
  tokens_generated: number;
  attested?: boolean;
  mda_verified?: boolean;
  runtime_verified?: boolean;
  certificate_available?: boolean;
  last_challenge_verified?: string;
  failed_challenges?: number;
  routable?: boolean;
}

export type ProviderRouteState = "serving" | "ready" | "attention";
export type ProviderStatusFilter = "all" | ProviderRouteState;
export type ProviderTrustFilter = "all" | "hardware" | "basic";
export type ProviderSortKey = "readiness" | "hardware" | "requests" | "tokens" | "chip";

export interface ProviderFleetSummary {
  visible: number;
  ready: number;
  serving: number;
  attention: number;
}

const FRESH_CHALLENGE_MS = 6 * 60 * 1_000;

export function hasFreshChallenge(iso?: string, now = Date.now()): boolean {
  if (!iso) return false;
  const then = new Date(iso).getTime();
  return Number.isFinite(then) && now - then <= FRESH_CHALLENGE_MS;
}

export function isProviderRoutable(provider: ProviderStats, now = Date.now()): boolean {
  if (typeof provider.routable === "boolean") return provider.routable;
  const statusOK = provider.status === "online" || provider.status === "serving";
  const trustOK = provider.trust_level === "hardware";
  const runtimeOK = provider.runtime_verified !== false;
  return statusOK && trustOK && runtimeOK && hasFreshChallenge(provider.last_challenge_verified, now);
}

export function providerRouteState(provider: ProviderStats, now = Date.now()): ProviderRouteState {
  if (!isProviderRoutable(provider, now)) return "attention";
  return provider.status === "serving" ? "serving" : "ready";
}

export function providerRouteReason(provider: ProviderStats, now = Date.now()): string {
  if (isProviderRoutable(provider, now)) {
    return provider.status === "serving"
      ? "Actively serving traffic with all routing checks passed."
      : "Trust, runtime, and challenge checks are current."
  }
  if (provider.status !== "online" && provider.status !== "serving") {
    return "The node is not currently online for public routing."
  }
  if (provider.trust_level !== "hardware") {
    return "Hardware-backed trust is not available for this node."
  }
  if (provider.runtime_verified === false) {
    return "The latest runtime verification did not pass."
  }
  if (!provider.last_challenge_verified) {
    return "No successful routing challenge has been published yet."
  }
  if (!hasFreshChallenge(provider.last_challenge_verified, now)) {
    return "The latest routing challenge is older than six minutes."
  }
  return "The coordinator has temporarily excluded this node from routing."
}

export function summarizeProviderFleet(
  providers: ProviderStats[],
  now = Date.now(),
): ProviderFleetSummary {
  let ready = 0;
  let serving = 0;
  let attention = 0;
  for (const provider of providers) {
    const state = providerRouteState(provider, now);
    if (state === "serving") serving++;
    else if (state === "ready") ready++;
    else attention++;
  }
  return { visible: providers.length, ready, serving, attention };
}

function compareHardware(a: ProviderStats, b: ProviderStats): number {
  return (
    b.memory_gb - a.memory_gb ||
    b.gpu_cores - a.gpu_cores ||
    b.memory_bandwidth_gbs - a.memory_bandwidth_gbs
  );
}

export function compareProviders(
  a: ProviderStats,
  b: ProviderStats,
  sortKey: ProviderSortKey,
  now = Date.now(),
): number {
  if (sortKey === "requests") return b.requests_served - a.requests_served || a.id.localeCompare(b.id);
  if (sortKey === "tokens") return b.tokens_generated - a.tokens_generated || a.id.localeCompare(b.id);
  if (sortKey === "chip") return a.chip.localeCompare(b.chip) || a.id.localeCompare(b.id);
  if (sortKey === "hardware") return compareHardware(a, b) || a.id.localeCompare(b.id);
  const order: Record<ProviderRouteState, number> = { serving: 0, ready: 1, attention: 2 };
  return (
    order[providerRouteState(a, now)] - order[providerRouteState(b, now)] ||
    compareHardware(a, b) ||
    a.id.localeCompare(b.id)
  );
}

export function matchesTrustFilter(provider: ProviderStats, filter: ProviderTrustFilter): boolean {
  if (filter === "all") return true;
  if (filter === "hardware") return provider.trust_level === "hardware";
  return provider.trust_level !== "hardware";
}

export function relativeChallengeLabel(iso?: string, now = Date.now()): string {
  if (iso === undefined) return "Not published";
  if (!iso) return "Not seen";
  const then = new Date(iso).getTime();
  if (!Number.isFinite(then)) return "Not seen";
  const seconds = Math.max(0, Math.round((now - then) / 1_000));
  if (seconds < 60) return `${seconds}s ago`;
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  return `${Math.round(minutes / 60)}h ago`;
}

export function compactProviderId(id: string): string {
  if (id.length <= 14) return id;
  return `${id.slice(0, 8)}…${id.slice(-4)}`;
}

export function shortProviderModel(id: string): string {
  return id.split("/").pop()?.replace(/-/g, " ") || id;
}
