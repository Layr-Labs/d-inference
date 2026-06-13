# Telemetry Schema

This document describes the telemetry wire format shared by the coordinator, provider, macOS app, and console UI. The canonical Go definitions are in [`coordinator/protocol/telemetry.go`](../../coordinator/protocol/telemetry.go). Ingestion is handled by [`coordinator/api/telemetry_handlers.go`](../../coordinator/api/telemetry_handlers.go). Mirrors: Swift [`provider-swift/Sources/ProviderCore/Telemetry/TelemetryEvent.swift`](../../provider-swift/Sources/ProviderCore/Telemetry/TelemetryEvent.swift) and TypeScript [`console-ui/src/lib/telemetry-types.ts`](../../console-ui/src/lib/telemetry-types.ts).

## Ingestion endpoint

```
POST /v1/telemetry/events
Authorization: optional Bearer <token>
```

Authentication modes (resolved inside the handler):

| Token type | Identity used | Rate-limit bucket |
|---|---|---|
| Provider device token | `machine_id` derived from token hash | per machine |
| Privy JWT | account id | per account |
| API key | account id | per account |
| Anonymous | none | stricter anonymous bucket |

See [`resolveTelemetryAuth`](../../coordinator/api/telemetry_handlers.go).

## Batch envelope

Go: [`TelemetryBatch`](../../coordinator/protocol/telemetry.go); Swift: `TelemetryBatch`; TS: `TelemetryEvent[]` wrapped as `{ events: ... }`.

| Field | Type | Notes |
|---|---|---|
| `events` | array | [`TelemetryEvent`](#telemetryevent) records |

Server-enforced caps:

| Limit | Value |
|---|---|
| Max body size | 64 KB |
| Max events per batch | 100 |
| Max message length | 4,096 chars |
| Max stack length | 32 KB |
| Max fields JSON size | 8 KB |
| Authenticated rate | 200 burst, 100 events/min refill |
| Anonymous rate | 30 burst, 10 events/min refill |

See [`telemetry_handlers.go:35-41`](../../coordinator/api/telemetry_handlers.go) and [`telemetry_handlers.go:108-116`](../../coordinator/api/telemetry_handlers.go).

## `TelemetryEvent`

| Field | Type | Required | Notes |
|---|---|---|---|
| `id` | string | yes | UUIDv4, client-supplied |
| `timestamp` | string | yes | ISO 8601 (RFC 3339 with fractional seconds in Swift) |
| `source` | string | yes | `coordinator`, `provider`, `app`, `console`, `bridge` |
| `severity` | string | yes | `debug`, `info`, `warn`, `error`, `fatal` |
| `kind` | string | yes | `panic`, `http_error`, `protocol_error`, `backend_crash`, `attestation_failure`, `inference_error`, `runtime_mismatch`, `connectivity`, `log`, `custom` |
| `version` | string | no | Component version |
| `machine_id` | string | no | Stable per-machine identifier |
| `account_id` | string | no | Server-stamped from auth when present |
| `request_id` | string | no | Correlation id |
| `session_id` | string | no | Per-process UUID |
| `message` | string | yes | Human-readable developer string |
| `fields` | object | no | Allowlisted structured fields |
| `stack` | string | no | Backtrace / formatted stack |

Unknown `source`, `severity`, and `kind` values are coerced server-side to `custom` / `info` / `custom`. Timestamps are clamped to `[now-7d, now+5min]`. See [`sanitizeTelemetryEvent`](../../coordinator/api/telemetry_handlers.go).

## Field allowlist

The coordinator silently drops any `fields` key not in this set. Keys must be kept in sync across Go, Swift, and TypeScript.

| Field | Allowed in |
|---|---|
| `component` | Go, Swift, TS |
| `operation` | Go, Swift, TS |
| `duration_ms` | Go, Swift, TS |
| `attempt` | Go, Swift, TS |
| `endpoint` | Go, Swift, TS |
| `status_code` | Go, Swift, TS |
| `error_class` | Go, Swift, TS |
| `error` | Go, Swift, TS |
| `target` | Go, Swift, TS |
| `model` | Go, Swift, TS |
| `backend` | Go, Swift, TS |
| `exit_code` | Go, Swift, TS |
| `signal` | Go, Swift, TS |
| `hardware_chip` | Go, Swift, TS |
| `memory_gb` | Go, Swift, TS |
| `macos_version` | Go, Swift, TS |
| `handler` | Go, Swift, TS |
| `provider_id` | Go, Swift, TS |
| `trust_level` | Go, Swift, TS |
| `queue_depth` | Go, Swift, TS |
| `reason` | Go, Swift, TS |
| `runtime_component` | Go, Swift, TS |
| `reconnect_count` | Go, Swift, TS |
| `last_error` | Go, Swift, TS |
| `ws_state` | Go, Swift, TS |
| `network_reachable` | Go only |
| `coordinator_url` | Go only |
| `billing_method` | Go, Swift, TS |
| `payment_failed` | Go, Swift, TS |
| `url` | Go, TS |
| `user_agent` | Go, TS |
| `route` | Go, TS |

**Important:** No prompt or response content is ever placed in telemetry. The allowlist contains only non-sensitive operational metadata.

Canonical server allowlist: [`telemetry_handlers.go:48-87`](../../coordinator/api/telemetry_handlers.go). Swift client-side filter: [`TelemetryFieldFilter.allowed`](../../provider-swift/Sources/ProviderCore/Telemetry/TelemetryEvent.swift). TS client-side set: [`TELEMETRY_ALLOWED_FIELDS`](../../console-ui/src/lib/telemetry-types.ts).

## Discrepancies

- The TypeScript allowlist in [`console-ui/src/lib/telemetry-types.ts`](../../console-ui/src/lib/telemetry-types.ts) currently omits `network_reachable` and `coordinator_url`, which the Go server accepts. Swift's client-side filter also omits `network_reachable`, `coordinator_url`, `url`, `user_agent`, and `route`. Unknown keys are dropped server-side without error, so this is a client-side completeness gap, not a wire incompatibility.
