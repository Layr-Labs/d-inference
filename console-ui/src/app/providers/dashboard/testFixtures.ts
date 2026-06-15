// Shared test fixtures for the provider dashboard. Builds a fully-populated
// MyProvider so individual tests only override the few fields they exercise.

import type { MyProvider, MyReputation } from "../types";

export function makeReputation(overrides: Partial<MyReputation> = {}): MyReputation {
  return {
    score: 0.92,
    total_jobs: 120,
    successful_jobs: 118,
    failed_jobs: 2,
    total_uptime_seconds: 90_000,
    avg_response_time_ms: 842,
    challenges_passed: 10,
    challenges_failed: 0,
    ...overrides,
  };
}

export function makeProvider(overrides: Partial<MyProvider> = {}): MyProvider {
  const { reputation, hardware, ...rest } = overrides;
  return {
    id: "p1",
    account_id: "acct-1",
    status: "offline",
    online: false,
    hardware: {
      machine_model: "Mac Studio",
      chip_name: "M4 Max",
      memory_gb: 64,
      gpu_cores: 40,
      ...hardware,
    },
    models: [],
    serial_number: "SER-1",
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
    max_concurrency: 4,
    reputation: makeReputation(reputation),
    lifetime_requests_served: 4200,
    lifetime_tokens_generated: 1_500_000,
    ...rest,
  };
}
