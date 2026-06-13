# Telemetry

Darkbloom's telemetry system carries operational events from the coordinator, provider CLI, macOS app, and console UI to a central sink (Datadog). The wire types are defined canonically in Go and mirrored in Swift and TypeScript. The three implementations must agree on JSON shape, enum values, and field names.

Canonical code:

* Go wire types: `coordinator/protocol/telemetry.go`
* Swift mirror: `provider-swift/Sources/ProviderCore/Telemetry/TelemetryEvent.swift`
* TypeScript mirror: `console-ui/src/lib/telemetry-types.ts`
* Ingestion: `coordinator/api/telemetry_handlers.go`
* Swift client: `provider-swift/Sources/ProviderCore/Telemetry/TelemetryClient.swift`
* Swift overflow queue: `provider-swift/Sources/ProviderCore/Telemetry/TelemetryOverflowQueue.swift`
* Swift panic hook: `provider-swift/Sources/ProviderCore/Telemetry/PanicHook.swift`

## Symmetry requirement

The telemetry contract has three mirrors that must stay aligned:

| Language | File | What must match |
|---|---|---|
| Go | `coordinator/protocol/telemetry.go` | Canonical enum constants, struct tags, batch shape |
| Swift | `provider-swift/Sources/ProviderCore/Telemetry/TelemetryEvent.swift` | Raw enum values, snake_case `CodingKeys`, optional-field omission |
| TypeScript | `console-ui/src/lib/telemetry-types.ts` | Literal string unions, optional fields, allowlist |

The coordinator coerces unknown source/severity/kind values to safe defaults (`custom`, `info`, `custom`) on ingest (`telemetry_handlers.go:327-339`), so a mismatch does not crash the server — but it breaks filtering, dashboard grouping, and alerting. Symmetry tests in each language pin enum casing and optional-field omission.

All three field allowlists (Go server, Swift client, TypeScript client) must also stay in sync:

* Go: `telemetryFieldAllowlist` (`telemetry_handlers.go:48-87`)
* Swift: `TelemetryFieldFilter.allowed` (`TelemetryEvent.swift:229-236`)
* TypeScript: `TELEMETRY_ALLOWED_FIELDS` (`telemetry-types.ts:54-85`)

## Wire event shape

`TelemetryEvent` (`coordinator/protocol/telemetry.go:105-119`):

```go
type TelemetryEvent struct {
    ID        string            `json:"id"`
    Timestamp time.Time         `json:"timestamp"`
    Source    TelemetrySource   `json:"source"`
    Severity  TelemetrySeverity `json:"severity"`
    Kind      TelemetryKind     `json:"kind"`
    Version   string            `json:"version,omitempty"`
    MachineID string            `json:"machine_id,omitempty"`
    AccountID string            `json:"account_id,omitempty"`
    RequestID string            `json:"request_id,omitempty"`
    SessionID string            `json:"session_id,omitempty"`
    Message   string            `json:"message"`
    Fields    map[string]any    `json:"fields,omitempty"`
    Stack     string            `json:"stack,omitempty"`
}
```

The Swift struct uses identical snake_case `CodingKeys` and omits empty optionals (`TelemetryEvent.swift:69-77`). The TypeScript interface uses the same optional fields (`telemetry-types.ts:34-50`).

## Enums

### Source

| Go constant | Raw value | Swift case | TS literal |
|---|---|---|---|
| `TelemetrySourceCoordinator` | `"coordinator"` | `.coordinator` | `"coordinator"` |
| `TelemetrySourceProvider` | `"provider"` | `.provider` | `"provider"` |
| `TelemetrySourceApp` | `"app"` | `.app` | `"app"` |
| `TelemetrySourceConsole` | `"console"` | `.console` | `"console"` |
| `TelemetrySourceBridge` | `"bridge"` | `.bridge` | `"bridge"` |

Unknown sources coerce to `"custom"` (`telemetry.go:57`, `telemetry_handlers.go:327-329`).

### Severity

| Go constant | Raw value | Swift case | TS literal |
|---|---|---|---|
| `SeverityDebug` | `"debug"` | `.debug` | `"debug"` |
| `SeverityInfo` | `"info"` | `.info` | `"info"` |
| `SeverityWarn` | `"warn"` | `.warn` | `"warn"` |
| `SeverityError` | `"error"` | `.error` | `"error"` |
| `SeverityFatal` | `"fatal"` | `.fatal` | `"fatal"` |

Unknown severities coerce to `"info"` (`telemetry_handlers.go:331-334`).

### Kind

| Go constant | Raw value | Swift case | TS literal |
|---|---|---|---|
| `KindPanic` | `"panic"` | `.panic` | `"panic"` |
| `KindHTTPError` | `"http_error"` | `.httpError` (raw `"http_error"`) | `"http_error"` |
| `KindProtocolError` | `"protocol_error"` | `.protocolError` | `"protocol_error"` |
| `KindBackendCrash` | `"backend_crash"` | `.backendCrash` | `"backend_crash"` |
| `KindAttestationFailure` | `"attestation_failure"` | `.attestationFailure` | `"attestation_failure"` |
| `KindInferenceError` | `"inference_error"` | `.inferenceError` | `"inference_error"` |
| `KindRuntimeMismatch` | `"runtime_mismatch"` | `.runtimeMismatch` | `"runtime_mismatch"` |
| `KindConnectivity` | `"connectivity"` | `.connectivity` | `"connectivity"` |
| `KindLog` | `"log"` | `.log` | `"log"` |
| `KindCustom` | `"custom"` | `.custom` | `"custom"` |

Unknown kinds coerce to `"custom"` (`telemetry_handlers.go:336-339`).

## Ingestion endpoint

`POST /v1/telemetry/events` accepts a `TelemetryBatch` of up to 100 events with a 64 KB body limit (`telemetry_handlers.go:35-41`). Authentication is optional:

1. Provider token → machine-id bucket.
2. Privy JWT or API key → account bucket.
3. Anonymous → stricter rate limit.

Rate limits (`telemetry_handlers.go:108-115`):

| Auth | Burst | Refill |
|---|---|---|
| Authenticated | 200 | 100 events / minute |
| Anonymous | 30 | 10 events / minute |

The handler sanitizes each event (`telemetry_handlers.go:301-402`):

* Mints/validates a UUIDv4 id.
* Clamps timestamp to `[now-7d, now+5min]`.
* Coerces source/severity/kind to known values.
* Truncates message, stack, and string fields.
* Filters `Fields` through the allowlist and caps the JSON size to 8 KB.
* Stamps `machine_id` and `account_id` from auth context.

Events are forwarded to Datadog Logs API asynchronously and are **not** persisted to the store (`telemetry_handlers.go:211-227`, `411-443`).

## Field allowlist

Only non-sensitive operational fields may be attached to events. The current allowlist (`telemetry_handlers.go:48-87`) includes generic metadata (`component`, `operation`, `duration_ms`), provider/backend context (`model`, `backend`, `hardware_chip`, `memory_gb`), coordinator context (`provider_id`, `trust_level`, `queue_depth`), connectivity (`reconnect_count`, `ws_state`), billing booleans (`billing_method`, `payment_failed`), and UI context (`url`, `route`).

**Prompt or response content must never appear in telemetry.** This is enforced by design (no such field exists) and by the allowlist.

## Swift client

`TelemetryClient` (`TelemetryClient.swift`) is a global singleton that batches events in memory and flushes them periodically.

* Configuration: coordinator URL, auth token, version, machine id, account id, source (`TelemetryClient.swift:19-70`).
* Defaults: max batch 50, flush interval 10 seconds, in-memory cap 1000 events.
* `emit(_:)` is non-blocking. When the in-memory buffer is full, events spill to disk (`TelemetryClient.swift:140-175`).
* `shutdown()` flushes pending events over the network; `shutdownSync()` writes them to disk for signal-handler safety.
* URL normalization converts WebSocket coordinator URLs (`wss://.../ws/provider`) to the HTTPS telemetry endpoint (`TelemetryClient.swift:416-433`).

### Overflow queue

`TelemetryOverflowQueue` (`TelemetryOverflowQueue.swift`) is a disk-backed JSONL queue at `~/.darkbloom/telemetry-queue.jsonl` with a 5 MB cap. When the cap is exceeded, the oldest half of the file is discarded.

### Panic hook

`PanicHook` (`PanicHook.swift`) installs signal handlers for `SIGSEGV`, `SIGBUS`, `SIGILL`, `SIGABRT`, and `SIGFPE`, plus an uncaught Objective-C exception handler. On a crash it:

1. Builds a `TelemetryEvent` with `kind = .panic`, `severity = .fatal`, and `Thread.callStackSymbols` as the stack.
2. Pushes the event directly to the disk overflow queue.
3. Calls `TelemetryClient.shared.shutdownSync()` to flush the in-memory buffer to disk.
4. Re-raises the signal so the process exits with the real status and Apple's CrashReporter still writes its report.

## Console UI telemetry

The TypeScript mirror (`telemetry-types.ts`) defines the same event shape and allowlist. The console UI emits events through the same `POST /v1/telemetry/events` endpoint, authenticated via the user's API key or Privy JWT.
