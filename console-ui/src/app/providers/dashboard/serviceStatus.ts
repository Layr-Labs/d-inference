import type { MyProvider, ProviderServiceStatus } from "../types";

export function freshServiceStatus(p: MyProvider, now = Date.now()): ProviderServiceStatus | null {
  const status = p.service_status;
  if (!status || status.schema_version !== 1 || status.probe?.scope !== "public_text") return null;
  const observed = Date.parse(status.observed_at);
  const expires = Date.parse(status.expires_at);
  if (!Number.isFinite(observed) || !Number.isFinite(expires) || observed > now + 5_000 || expires <= now || expires <= observed || expires - observed > 30_000) return null;
  if (!Array.isArray(status.models) || !Number.isFinite(status.pending_requests) || status.pending_requests < 0) return null;
  return status;
}

const REASONS: Record<string, string> = {
  eligible: "Ready for this workload",
  offline: "Provider is disconnected",
  untrusted: "Verification needs attention",
  trust_floor: "Hardware verification is incomplete",
  private_only: "Configured for private use",
  runtime_unverified: "Runtime verification is incomplete",
  private_text: "Private serving verification is incomplete",
  challenge_stale: "Waiting for a fresh verification challenge",
  trait_floor: "This request capability is unavailable",
  dedicated: "Model requires a dedicated serving configuration",
  dispatch_load_cooldown: "Model loading is temporarily cooling down",
  error_cooldown: "Recent failures temporarily restrict this workload",
  capacity_cooldown: "Temporarily backing off capacity offers",
  breaker: "Recent provider failures temporarily restrict public work",
  ejection: "Provider is temporarily recovering from repeated failures",
  slot_crashed: "Model engine is recovering from a crash",
  slot_reloading: "Model is reloading",
  thermal_critical: "Mac needs time to cool down",
  no_headroom: "At capacity for this workload",
  free_memory: "Insufficient free memory for this workload",
  not_serving_model: "Model is not approved for this public route",
  heartbeat_stale: "Latest provider heartbeat is stale",
  no_models: "No models are advertised",
  draining: "Finishing existing work before stopping",
  capacity_rate: "Recent capacity refusals affect routing preference",
};

export function serviceReason(reason?: string): string {
  if (!reason) return "";
  return Object.hasOwn(REASONS, reason) ? REASONS[reason] : "This workload is currently unavailable";
}
