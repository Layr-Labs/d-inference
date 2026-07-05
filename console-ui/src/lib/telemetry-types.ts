// Telemetry wire types — TypeScript mirror of the canonical Go definitions in
// `coordinator/protocol/telemetry.go` (also mirrored in Swift under
// `provider-swift/Sources/ProviderCore/Telemetry/`).
//
// Any change here MUST be reflected in the Go canonical type and the Swift
// mirror. A symmetry test runs against the Go canonical JSON in CI.

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


/** Server-enforced allowlist — keep in sync with the coordinator handler. */
export const TELEMETRY_ALLOWED_FIELDS = new Set<string>([
  "component",
  "operation",
  "duration_ms",
  "attempt",
  "endpoint",
  "status_code",
  "error_class",
  "error",
  "model",
  "backend",
  "exit_code",
  "signal",
  "hardware_chip",
  "memory_gb",
  "macos_version",
  "handler",
  "provider_id",
  "trust_level",
  "queue_depth",
  "reason",
  "runtime_component",
  "reconnect_count",
  "last_error",
  "ws_state",
  "billing_method",
  "payment_failed",
  "target",
  // OOM / memory pressure (mirror of Go + Swift allowlists).
  "detect_source",
  "peak_memory_bytes",
  "report",
  "pressure",
  "available_bytes",
  "mlx_active_bytes",
  "memory_pressure",
  "in_flight",
  "url",
  "user_agent",
  "route",
  // Engine-health / first-token-wedge diagnostics (mirror of Go + Swift).
  "steps_executed",
  "admits",
  "first_tokens_emitted",
  "consecutive_admits_without_first_token",
  "seconds_since_last_step",
  "seconds_since_last_first_token",
  "num_running",
  "wedge_suspected",
  // Eval-in-flight + idle-clear + prefill-sampling-health diagnostics.
  "eval_in_flight_ms",
  "longest_eval_ms",
  "evals_completed",
  "idle_clear_in_flight_ms",
  "idle_clears_completed",
  "prefill_samples_accepted",
  "prefill_samples_dropped_floor",
  "prefill_samples_dropped_ceiling",
  "last_prefill_sample_tps",
  "observed_prefill_tps_ewma",
  // KV-budget sustained-rejection audit (v0.7.3 black-hole hardening,
  // mirror of Go + Swift allowlists).
  "streak_seconds",
  "reservation_count",
  "reserved_bytes",
  "mlx_cache_bytes",
  "system_available_bytes",
  "reservations",
  "request_id",
  "age_seconds",
]);
