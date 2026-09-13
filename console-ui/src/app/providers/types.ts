// Wire types for /v1/me/providers and /v1/me/summary, mirroring the Go
// myProvider / myProvidersResponse / mySummaryResponse structs in
// coordinator/internal/api/me_handlers.go.

import type { CapacityTelemetry } from "@/lib/telemetry-types";

export interface MyHardware {
  machine_model?: string;
  chip_name?: string;
  chip_family?: string;
  chip_tier?: string;
  memory_gb?: number;
  memory_available_gb?: number;
  cpu_cores?: { performance?: number; efficiency?: number };
  gpu_cores?: number;
  memory_bandwidth_gbs?: number;
}

export interface MyModelInfo {
  id: string;
  size_bytes?: number;
  model_type?: string;
  quantization?: string;
  weight_hash?: string;
}

export interface MySystemMetrics {
  memory_pressure: number;
  cpu_usage: number;
  thermal_state: "nominal" | "fair" | "serious" | "critical" | string;
}

export interface MyBackendSlot {
  model: string;
  state: "running" | "idle_shutdown" | "crashed" | "reloading" | string;
  num_running: number;
  num_waiting: number;
  active_tokens: number;
  max_tokens_potential: number;
  // Measured provider telemetry, mirrored from the Go BackendSlotCapacity wire
  // type. Both are `omitempty` server-side (omitted when zero/unmeasured), so
  // they are optional here.
  observed_prefill_tps?: number; // EWMA of measured prefill TPS (admission→first token)
  model_load_time_ms?: number; // measured cold-start load time (ms) for this slot's model
  // Per-slot KV-cache backend the provider's engine was actually built with,
  // mirrored from Go BackendSlotCapacity.KVBackend (`*string`, omitempty).
  // A pre-0.8.0 provider omits the key, so `undefined` means UNKNOWN — never
  // read it as "contiguous", or the paged-rollout comparison silently counts
  // every legacy provider as a contiguous sample.
  kv_backend?: "paged" | "contiguous" | string;
  // Why this slot ended up on `kv_backend` instead of the backend it was asked
  // for, mirrored from Go BackendSlotCapacity.KVBackendFallbackReason
  // (`*string`, omitempty). Verbatim provider text: "kill_switch",
  // "kernel_preflight: …", "physical_capacity: …", "ineligible: …",
  // "pool_construction_capacity: …".
  //
  // READ IT AS A PAIR WITH `kv_backend`, and note the ABSENCE RULE IS
  // INVERTED. Undefined here means NO DEGRADE — the opposite of `kv_backend`,
  // where undefined means UNKNOWN. Both keys ship together in v0.8.0, so a
  // slot that named a `kv_backend` is running a build that also names this
  // whenever there is one: `kv_backend` present + this undefined is an
  // authoritative "did not degrade", and only `kv_backend` undefined is
  // unknown.
  //
  // `kv_backend` alone cannot answer the question the rollout has to ask: a
  // slot reporting "contiguous" is the v0.8.1 default, an operator who chose
  // contiguous, or a box that asked for paged and could not build it — a
  // steady state and a regression wearing the same label. This field is what
  // separates them.
  kv_backend_fallback_reason?: string;
  prefix_cache?: PrefixCacheTelemetry;
  paged_storage?: PagedStorageTelemetry;
}

export interface MyBackendCapacity {
  telemetry?: CapacityTelemetry;
  prefix_cache_maintenance?: PrefixCacheMaintenanceTelemetry;
  slots: MyBackendSlot[];
  gpu_memory_active_gb: number;
  gpu_memory_peak_gb: number;
  gpu_memory_cache_gb: number;
  total_memory_gb: number;
}

export interface MyReputation {
  score: number;
  total_jobs: number;
  successful_jobs: number;
  failed_jobs: number;
  total_uptime_seconds: number;
  // EWMA of real time-to-first-token in ms (rendered as "Avg TTFT"); the JSON
  // key is unchanged for wire stability — only its meaning is now real TTFT.
  avg_response_time_ms: number;
  challenges_passed: number;
  challenges_failed: number;
}

export interface MyProvider {
  id: string;
  account_id: string;
  status: "online" | "serving" | "offline" | "untrusted" | "never_seen" | string;
  online: boolean;
  last_heartbeat?: string;

  hardware: MyHardware;
  models: MyModelInfo[];
  backend?: string;
  version?: string;

  trust_level: "hardware" | "self_signed" | "none" | string;
  attested: boolean;
  mda_verified: boolean;
  se_key_bound: boolean;
  se_public_key?: string;
  // X25519 E2E key (same value as /v1/encryption-key); present only for
  // currently-online machines, omitted for offline ones.
  provider_key?: string;
  secure_enclave: boolean;
  sip_enabled: boolean;
  secure_boot_enabled: boolean;
  authenticated_root_enabled: boolean;
  system_volume_hash?: string;
  mda_os_version?: string;
  mda_sepos_version?: string;

  runtime_verified: boolean;
  python_hash?: string;
  runtime_hash?: string;

  last_challenge_verified?: string;
  failed_challenges: number;

  system_metrics?: MySystemMetrics;
  backend_capacity?: MyBackendCapacity;
  /** Idle-memory policy reported in heartbeats: 0 = always ready (models
   *  stay loaded), N = unloaded after N idle minutes and reloaded on demand.
   *  Absent for offline machines and providers too old to report it. */
  idle_unload_mins?: number;
  warm_models?: string[];
  current_model?: string;
  pending_requests: number;
  max_concurrency: number;
  prefill_tps?: number;
  decode_tps?: number;

  reputation: MyReputation;

  lifetime_requests_served: number;
  lifetime_tokens_generated: number;

  wallet_address?: string;

  registered_at?: string;
  last_seen?: string;
}

export interface MyProvidersResponse {
  providers: MyProvider[];
  latest_provider_version: string;
  min_provider_version: string;
  heartbeat_timeout_seconds: number;
  challenge_max_age_seconds: number;
}

export interface MyFleetCounts {
  total: number;
  online: number;
  serving: number;
  offline: number;
  untrusted: number;
  hardware: number;
  needs_attention: number;
}

export interface MySummaryResponse {
  account_id: string;
  wallet_address?: string;
  available_balance_micro_usd: number;
  withdrawable_balance_micro_usd?: number;
  payout_ready?: boolean;
  lifetime_micro_usd: number;
  lifetime_jobs: number;
  last_24h_micro_usd: number;
  last_24h_jobs: number;
  last_7d_micro_usd: number;
  last_7d_jobs: number;
  counts: MyFleetCounts;
  latest_provider_version: string;
  min_provider_version: string;
}

export interface PrefixCacheTelemetry {
  kind: "attention_blocks" | "complete_checkpoint";
  ttl_expired_total?: number;
  io?: PrefixCacheIOTelemetry;
  generation: number;
  sample_seq: number;
  sample_age_ms: number;
  entries: number;
  disk_bytes: number;
  staging_bytes: number;
  stages_total: number;
  files_written_total: number;
  written_bytes_total: number;
  donation_drops_total: number;
  corrupt_drops_total: number;
  evictions_total: number;
}

export interface PrefixCacheIOTelemetry {
  staging_peak_bytes: number;
  files_read_total: number;
  read_bytes_total: number;
  stage_read_bytes_total: number;
  donation_read_bytes_total: number;
  stage_us_total: number;
  write_us_total: number;
}

export interface PrefixCacheMaintenanceTelemetry {
  ttl_expired_total: number;
  budget_evicted_total: number;
  temp_removed_total: number;
}

// Optional queue-captured allocator observation. Overlapping byte gauges must
// not be summed; missing fields mean uninstrumented, not zero ownership.
export interface PagedStorageTelemetry {
  kind: "segmented";
  generation: number;
  sample_seq: number;
  sample_age_ms: number;
  grant_bytes: number;
  committed_bytes: number;
  reserved_page_bytes: number;
  live_page_bytes: number;
  poison_bytes: number;
  slack_bytes: number;
  over_grant_bytes: number;
  segment_count: number;
  address_pages: number;
  // Padding cannot store KV; allowance is the last settled preparation, not retained memory.
  allocator_padding_bytes?: number;
  last_allocation_allowance_bytes?: number;
  nominal_kv_bytes?: number;
  physical_floor_overhead_bytes?: number;
  allocation_failures_total?: number;
  admission_refusals_total?: number;
  grant_refusals_total?: number;
  grant_epoch_retries_total?: number;
}
