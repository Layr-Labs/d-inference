// Telemetry wire types — TypeScript mirror of the canonical Go definitions in
// `coordinator/protocol/telemetry.go` (also mirrored in Swift under
// `provider-swift/Sources/ProviderCore/Telemetry/`).
//
// Any change here MUST be reflected in the Go canonical type and the Swift
// mirror. The Go and Swift symmetry tests pin the canonical JSON; the event
// types here only type the inert `telemetry.ts` facade, which sends nothing.

export type TelemetrySource =
  | "coordinator"
  | "provider"
  | "app"
  | "console"
  | "bridge";

export type TelemetrySeverity =
  | "debug"
  | "info"
  | "warn"
  | "error"
  | "fatal";

export type TelemetryKind =
  | "panic"
  | "http_error"
  | "protocol_error"
  | "backend_crash"
  | "attestation_failure"
  | "inference_error"
  | "runtime_mismatch"
  | "connectivity"
  | "oom"
  // Provider engine-health diagnostics for the first-token wedge (model-load
  // milestones, periodic engine snapshots, wedge-suspected transitions).
  | "engine_health"
  | "log"
  | "custom";

export interface TelemetryEvent {
  /** UUIDv4, generated client-side. */
  id: string;
  /** ISO 8601 timestamp. */
  timestamp: string;
  source: TelemetrySource;
  severity: TelemetrySeverity;
  kind: TelemetryKind;
  version?: string;
  machine_id?: string;
  account_id?: string;
  request_id?: string;
  session_id?: string;
  message: string;
  fields?: Record<string, unknown>;
  stack?: string;
}

// Heartbeat capacity diagnostics mirror coordinator/protocol/profile.go and
// process_memory_telemetry.go, and Swift Protocol/ProcessMemoryTelemetry.swift.
export interface ProcessMemoryTelemetry {
  generation: number;
  sample_seq: number;
  sample_age_ms: number;
  policy_epoch: number;
  cap_bytes: number;
  activation_reserve_bytes: number;
  active_bytes: number;
  cache_bytes: number;
  charged_bytes: number;
  materialized_bytes: number;
  unmaterialized_bytes: number;
  remaining_bytes: number;
  commitment_debt_bytes: number;
  owner_count: number;
  closing_owner_count: number;
  system_available_bytes?: number;
}

export interface CapacityTelemetry {
  low_power_mode?: boolean;
  memory_pressure_level?: "normal" | "warning" | "critical" | "other";
  mlx_num_resources?: number;
  in_admission?: number;
  inflight_tasks?: number;
  process_memory?: ProcessMemoryTelemetry;
}
