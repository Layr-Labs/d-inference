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

export type ProviderRouteState = "serving" | "ready" | "attention" | "unreported";
export type ProviderStatusFilter = "all" | ProviderRouteState;
export type ProviderTrustFilter = "all" | "hardware" | "basic";
export type ProviderSortKey = "readiness" | "hardware" | "requests" | "tokens" | "chip";

export interface ProviderFleetSummary {
  visible: number;
  ready: number;
  serving: number;
  attention: number;
  unreported: number;
  hardware: number;
}

// Keep the presentation aligned with registry.challengeFreshnessMaxAge so the
// dashboard does not reject nodes that the coordinator can still dispatch to.
const FRESH_CHALLENGE_MS = 16 * 60 * 1_000;

export function hasFreshChallenge(iso?: string, now = Date.now()): boolean {
  if (!iso) return false;
  const then = new Date(iso).getTime();
  return Number.isFinite(then) && then <= now && now - then <= FRESH_CHALLENGE_MS;
}

/** Published checks are useful context, but do not include every routing gate. */
export function passesPublishedVerificationChecks(provider: ProviderStats, now = Date.now()): boolean {
  const statusOK = provider.status === "online" || provider.status === "serving";
  return statusOK && provider.trust_level === "hardware" && provider.runtime_verified === true && hasFreshChallenge(provider.last_challenge_verified, now);
}

/** Only an explicit coordinator verdict can certify routing eligibility. */
export function isProviderRoutable(provider: ProviderStats): boolean {
  return provider.routable === true;
}

export function providerRouteState(provider: ProviderStats): ProviderRouteState {
  if (provider.routable === undefined) return "unreported";
  if (!isProviderRoutable(provider)) return "attention";
  return provider.status === "serving" ? "serving" : "ready";
}

export function providerRouteReason(provider: ProviderStats, now = Date.now()): string {
  if (provider.routable === true) return "The coordinator reports this node as eligible for public routing.";
  if (provider.routable === false) return "The coordinator reports this node as excluded from public routing.";
  const unknown = "Routing eligibility is not published for this node.";
  if (passesPublishedVerificationChecks(provider, now)) return `${unknown} The published hardware, runtime, and challenge checks are current.`;
  if (provider.runtime_verified === false) return `${unknown} The latest published runtime verification did not pass.`;
  if (provider.last_challenge_verified && !hasFreshChallenge(provider.last_challenge_verified, now)) return `${unknown} The last routing challenge is outside the sixteen-minute verification window.`;
  return `${unknown} Hardware identity and challenge information are shown below.`;
}

export function summarizeProviderFleet(providers: ProviderStats[]): ProviderFleetSummary {
  let ready = 0;
  let serving = 0;
  let attention = 0;
  let unreported = 0;
  let hardware = 0;
  for (const provider of providers) {
    const state = providerRouteState(provider);
    if (state === "ready") ready++;
    if (state === "attention") attention++;
    if (state === "unreported") unreported++;
    if (provider.status === "serving") serving++;
    if (provider.trust_level === "hardware") hardware++;
  }
  return { visible: providers.length, ready, serving, attention, unreported, hardware };
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
): number {
  if (sortKey === "requests") return b.requests_served - a.requests_served || a.id.localeCompare(b.id);
  if (sortKey === "tokens") return b.tokens_generated - a.tokens_generated || a.id.localeCompare(b.id);
  if (sortKey === "chip") return a.chip.localeCompare(b.chip) || a.id.localeCompare(b.id);
  if (sortKey === "hardware") return compareHardware(a, b) || a.id.localeCompare(b.id);
  const order: Record<ProviderRouteState, number> = { serving: 0, ready: 1, unreported: 2, attention: 3 };
  return (
    order[providerRouteState(a)] - order[providerRouteState(b)] ||
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
