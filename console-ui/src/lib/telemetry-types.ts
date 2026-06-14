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
]);
