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
  serial_number?: string;

  trust_level: "hardware" | "self_signed" | "none" | string;
  attested: boolean;
  mda_verified: boolean;
  acme_verified: boolean;
  se_key_bound: boolean;
  se_public_key?: string;
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

  earnings_total_micro_usd: number;
  earnings_count: number;

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
