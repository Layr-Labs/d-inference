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

* Go: `telemetryFieldAllowlist` (`telemetry_handlers.go:48-171`)
* Swift: `TelemetryFieldFilter.allowed` (`TelemetryEvent.swift:238-294`)
* TypeScript: `TELEMETRY_ALLOWED_FIELDS` (`telemetry-types.ts:58-160`)

This is enforced, not merely asked for: `coordinator/api/telemetry_allowlist_parity_test.go`
scrapes both client mirrors at test time and diffs them against the Go map in both
directions. Adding a field to one mirror alone fails `TestTelemetryAllowlistThreeWayParity`.

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

The Swift struct uses identical snake_case `CodingKeys` and omits empty optionals (`TelemetryEvent.swift:78-86`). The TypeScript interface uses the same optional fields (`telemetry-types.ts:38-54`).

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

`POST /v1/telemetry/events` is retained only for compatibility and returns HTTP
410 without reading or forwarding the body. Provider and console clients also
drop events before buffering, disk I/O, or network I/O. A field-name allowlist
cannot make arbitrary messages, stacks, URLs, or field values privacy-safe.

The schema below is historical compatibility material. Re-enabling ingestion
requires closed, per-kind value schemas and a new privacy review.

## Field allowlist

Only non-sensitive operational fields may be attached to events. The current allowlist (`telemetry_handlers.go:48-171`) includes generic metadata (`component`, `operation`, `duration_ms`), provider/backend context (`model`, `backend`, `hardware_chip`, `memory_gb`), coordinator context (`provider_id`, `trust_level`, `queue_depth`), connectivity (`reconnect_count`, `ws_state`), billing booleans (`billing_method`, `payment_failed`), UI context (`url`, `route`), and the OOM, engine-health, KV-budget-audit, media, and exact-prefix-replay diagnostic cohorts.

v0.8.0 added three more cohorts, all bounded enums and counters:

* **KV-backend discriminator** — `kv_backend` (`paged` | `contiguous`, the same key and vocabulary as `BackendSlotCapacity.kv_backend` on the heartbeat wire) and `prefix_reuse_backend`. These exist because `backend` was overloaded across three unrelated value vocabularies; see [the ruling in the schema reference](../../reference/telemetry-schema.md#backend-key-semantics). All producer sites now emit the split keys.
* **Paged KV pool** — `pages_pinned`, `cow_events`, `pool_utilization`. Only `pool_utilization` has a producer; the other two are blocked on engine mechanisms that do not exist yet (no pin concept, no copy-on-write page splitting) and are deliberately left unproduced rather than emitted as a hardcoded zero.
* **MTP / speculative decode** — `mtp_enabled`, `mtp_active`, `mtp_inactive_reason`, `mtp_acceptance_rate`. MTP was previously invisible to the coordinator while silently inflating `observed_decode_tps`, so a partially-MTP fleet biased routing on a metric assumed homogeneous.

The producer for the paged-pool and MTP cohorts is `engine_v2_slot_posture`, an INFO `engine_health` event sampled per slot every 60 s by `EngineV2Bridge+MTP.swift` — recurring and traffic-independent, because a rollout dashboard needs a fleet inventory rather than a once-per-load notification.

**Prompt or response content must never appear in telemetry.** This is enforced by design (no such field exists) and by the allowlist.

## Swift client (disabled)

`TelemetryClient` retains a source-compatible facade but drops every event. On
configuration/shutdown it purges the exact legacy queue path.

### Overflow queue

The production shared overflow queue is disabled. Explicitly injected queue
instances remain only for compatibility tests.

### Panic hook

`PanicHook` (`PanicHook.swift`) installs signal handlers for `SIGSEGV`, `SIGBUS`, `SIGILL`, `SIGABRT`, and `SIGFPE`, plus an uncaught Objective-C exception handler. On a crash it:

1. Builds a `TelemetryEvent` with `kind = .panic`, `severity = .fatal`, and `Thread.callStackSymbols` as the stack.
2. Pushes the event directly to the disk overflow queue.
3. Calls `TelemetryClient.shared.shutdownSync()` to flush the in-memory buffer to disk.
4. Re-raises the signal so the process exits with the real status and Apple's CrashReporter still writes its report.

## Console UI telemetry (disabled)

The TypeScript facade drops events, and `/api/telemetry` returns HTTP 410 without
reading or forwarding request bodies.
