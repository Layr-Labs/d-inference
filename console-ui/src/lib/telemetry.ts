// Client telemetry is disabled for inference privacy. Free-form browser errors,
// URLs, stacks, and request identifiers are not safe to forward merely because
// their field names are allowlisted. Keep the facade so call sites remain
// source-compatible while the product moves to closed, per-kind schemas.

import type { TelemetryKind, TelemetrySeverity } from "./telemetry-types";

export interface EmitOptions {
  kind: TelemetryKind;
  severity: TelemetrySeverity;
  message: string;
  fields?: Record<string, unknown>;
  stack?: string;
  requestId?: string;
}

export function emit(_opts: EmitOptions) {}

export function installGlobalHandlers() {
  // Intentionally empty: global Error/rejection objects can contain user data.
}

export function _resetForTest() {}

export function _bufferSize(): number {
  return 0;
}
