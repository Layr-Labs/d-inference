// Shared test fixtures for the provider dashboard. Builds a fully-populated
// MyProvider so individual tests only override the few fields they exercise,
// plus the catalog ids/names the model-label tests share.

import type { MyBackendSlot, MyProvider, MyReputation } from "../types";
import { modelNamesFrom, type ModelNames } from "./modelNames";

/** Raw catalog build ids as providers advertise them. */
export const QWEN27_ID = "EigenLabs/Qwen3.8-27B-4bit-mtp";
export const MOE_ID = "qwen3.6-35b-a3b-vl-mtp-mxfp8";
export const QWEN27_NAME = "Qwen 3.8 27B";
export const MOE_NAME = "Qwen 3.6 35B A3B";

/** Display names for the two fixture builds, as /v1/me/providers ships them. */
export function makeModelNames(): ModelNames {
  return modelNamesFrom({ model_display_names: { [QWEN27_ID]: QWEN27_NAME, [MOE_ID]: MOE_NAME } });
}

export function makeSlot(model: string, overrides: Partial<MyBackendSlot> = {}): MyBackendSlot {
  return { model, state: "idle", num_running: 0, num_waiting: 0, active_tokens: 0, max_tokens_potential: 8192, ...overrides };
}

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
    trust_level: "hardware",
    attested: true,
    mda_verified: true,
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
