// Shared test fixtures for the provider dashboard logic tests.
import type { MyProvider, MyProvidersResponse } from "@/app/providers/types";
import type { RoutingCtx } from "@/app/providers/dashboard/routing";

export const ctx: RoutingCtx = {
  latest_provider_version: "0.5.16",
  min_provider_version: "0.5.16",
  heartbeat_timeout_seconds: 90,
  challenge_max_age_seconds: 360,
};

export function baseProvider(overrides: Partial<MyProvider> = {}): MyProvider {
  return {
    id: "p1",
    account_id: "acct-1",
    status: "online",
    online: true,
    hardware: { chip_name: "Apple M3 Max", memory_gb: 64, gpu_cores: 40 },
    models: [{ id: "mlx-community/Qwen3.5-9B-MLX-4bit" }],
    trust_level: "hardware",
    attested: true,
    mda_verified: true,
    acme_verified: true,
    se_key_bound: true,
    secure_enclave: true,
    sip_enabled: true,
    secure_boot_enabled: true,
    authenticated_root_enabled: true,
    runtime_verified: true,
    failed_challenges: 0,
    pending_requests: 0,
    max_concurrency: 8,
    reputation: {
      score: 0.85,
      total_jobs: 100,
      successful_jobs: 98,
      failed_jobs: 2,
      total_uptime_seconds: 3600,
      avg_response_time_ms: 220,
      challenges_passed: 5,
      challenges_failed: 0,
    },
    lifetime_requests_served: 480,
    lifetime_tokens_generated: 1_200_000,
    earnings_total_micro_usd: 5_000_000,
    earnings_count: 480,
    last_challenge_verified: new Date().toISOString(),
    version: "0.5.16",
    ...overrides,
  };
}

export type { MyProvider, MyProvidersResponse };
