// Wire types for /v1/me/providers and /v1/me/summary, mirroring the Go
// myProvider / myProvidersResponse / mySummaryResponse structs in
// coordinator/internal/api/me_handlers.go.

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
}

export interface MyBackendCapacity {
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

/**
 * Closed set of reasons the coordinator excluded a machine (or one of its
 * models) from routing. Mirrors `RoutingBlocker` in
 * coordinator/registry/routing_diagnostics.go — the Go side owns the strings.
 */
export type RoutingBlocker =
  | "offline"
  | "untrusted"
  | "private_only"
  | "trust_below_minimum"
  | "runtime_hash_mismatch"
  | "attestation_challenge_never_passed"
  | "attestation_challenge_stale"
  | "no_encryption_key"
  | "unsupported_backend"
  | "unencrypted_response_chunks"
  | "runtime_manifest_unchecked"
  | "sip_unverified"
  | "code_attestation_missing"
  | "privacy_capabilities_missing"
  | "privacy_capabilities_incomplete"
  | "no_models_registered"
  | "no_routable_models"
  | "model_not_in_catalog"
  | "model_weight_hash_mismatch"
  | "model_template_render_broken";

export interface MyModelRouting {
  id: string;
  publicly_listed: boolean;
  owner_routable: boolean;
  blockers?: RoutingBlocker[];
}

export interface MyProviderRouting {
  /** Counted into the public /v1/models catalog. */
  advertising: boolean;
  /** Public traffic can actually be dispatched here. Implies `advertising`. */
  routable: boolean;
  /** The owner's own self-route can reach it. */
  owner_routable: boolean;
  blockers?: RoutingBlocker[];
  models?: MyModelRouting[];
  challenge_max_age_seconds: number;
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
  serial_number?: string;

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
  mda_cert_chain_b64?: string[];
  mda_serial?: string;
  mda_udid?: string;
  mda_os_version?: string;
  mda_sepos_version?: string;

  runtime_verified: boolean;
  python_hash?: string;
  runtime_hash?: string;

  last_challenge_verified?: string;
  failed_challenges: number;

  // The coordinator's own routing verdict. Optional only for coordinators that
  // predate it; when present it is authoritative and the client must not
  // re-derive the gates it covers.
  routing?: MyProviderRouting;

  system_metrics?: MySystemMetrics;
  backend_capacity?: MyBackendCapacity;
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

// Response from DELETE /v1/me/providers/{serial}.
export interface DeleteProviderResponse {
  deleted: boolean;
  serial: string;
  rows_removed: number;
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
