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
| `kv_backend` | Go, Swift, TS |
| `prefix_reuse_backend` | Go, Swift, TS |
| `pages_pinned` | Go, Swift, TS |
| `cow_events` | Go, Swift, TS |
| `pool_utilization` | Go, Swift, TS |
| `mtp_enabled` | Go, Swift, TS |
| `mtp_active` | Go, Swift, TS |
| `mtp_inactive_reason` | Go, Swift, TS |
| `mtp_acceptance_rate` | Go, Swift, TS |

This table is not exhaustive: the OOM / memory-pressure, engine-health (first-token
wedge), eval-in-flight, KV-budget audit, media, and exact-prefix-replay cohorts are
allowlisted in all three mirrors but have never been transcribed here. Absence from
this table does **not** mean a key is rejected — the Go map is the authority, and
`TestTelemetryAllowlistThreeWayParity` is what keeps the three mirrors honest.

**Important:** No prompt or response content is ever placed in telemetry. The allowlist contains only non-sensitive operational metadata.

Canonical server allowlist: [`telemetry_handlers.go:48-171`](../../coordinator/api/telemetry_handlers.go). Swift client-side filter: [`TelemetryFieldFilter.allowed`](../../provider-swift/Sources/ProviderCore/Telemetry/TelemetryEvent.swift) (`TelemetryEvent.swift:238-294`). TS client-side set: [`TELEMETRY_ALLOWED_FIELDS`](../../console-ui/src/lib/telemetry-types.ts) (`telemetry-types.ts:58-160`).

## Discrepancies

- The TypeScript allowlist in [`console-ui/src/lib/telemetry-types.ts`](../../console-ui/src/lib/telemetry-types.ts) currently omits `network_reachable` and `coordinator_url`, which the Go server accepts. Swift's client-side filter also omits `network_reachable`, `coordinator_url`, `url`, `user_agent`, and `route`. Unknown keys are dropped server-side without error, so this is a client-side completeness gap, not a wire incompatibility.

## `backend` key semantics

`backend` was overloaded. Across producer sites it carried **three unrelated value
vocabularies**, so any `group by backend` dashboard mis-buckets:

| Meaning | Values | Producer sites |
|---|---|---|
| Engine identity | `engine_v2` | `EngineV2Bridge+Capacity.swift:220`, `EngineV2Bridge.swift:1207,1231`, `EngineV2Config.swift:215,255`, `EngineV2VisionPrefill.swift:468`, `MultiModelBatchSchedulerEngine.swift:854` |
| Process runtime identity | `mlx-swift` | `darkbloom/StartCommand+Modes.swift:209` |
| KV storage kind | `paged`, `contiguous` | `EngineV2Bridge+PrefixCache.swift:197,252` |
| Prefix-reuse row identity | `contiguousUnquantized`, `contiguousQuantized`, `pagedFP16`, `unknown` | `EngineV2SlotFactory.swift:479` |

**Ruling.** `backend` keeps the majority meaning — the engine or process runtime
executing inference (`engine_v2`, `mlx-swift`). It is also the meaning that matches
`RegisterMessage.backend` on the wire, so telemetry and registration stay joinable.
The other two axes move to their own keys:

* `kv_backend` — the KV storage kind, `paged` | `contiguous`. This is **not a new
  name**: it is deliberately the same key and the same two-value vocabulary as
  [`BackendSlotCapacity.KVBackend`](../../coordinator/protocol/messages.go) on the
  heartbeat wire (`messages.go:303`) and `kvBackend` in
  [`Types.swift:518`](../../provider-swift/Sources/ProviderCore/Protocol/Types.swift).
  Telemetry and per-slot capacity therefore group identically, which is the whole
  point of the v0.8.0 rollout dashboard.
* `prefix_reuse_backend` — the finer `CBv2PrefixReuseBackend` row identity. It gets
  its own key rather than being folded into `kv_backend` because
  `contiguousQuantized` vs `contiguousUnquantized` is a real distinction that
  `contiguous` cannot express; collapsing it would be a silent data loss.

**Producer sites that must change** (all outside the allowlist change; none were
edited here):

1. `EngineV2Bridge+PrefixCache.swift:197` and `:252` — currently
   `"backend": .string(kvBackendKind.rawValue)`. Must become
   `"backend": .string("engine_v2")` **plus**
   `"kv_backend": .string(kvBackendKind.rawValue)`.
2. `EngineV2SlotFactory.swift:479` — currently
   `"backend": .string(capability.backend.rawValue)`. Must become
   `"backend": .string("engine_v2")`, `"kv_backend": .string(kvBackendKind.rawValue)`,
   and `"prefix_reuse_backend": .string(capability.backend.rawValue)`. Note the
   `CBv2PrefixReuseBackend` raw values are camelCase today; emit them snake_cased
   (`contiguous_unquantized`, `contiguous_quantized`, `paged_fp16`, `unknown`) to
   match every other telemetry enum.

Until those three sites change, `backend` on `prefix_cache_replay` and
`prefix_cache_construction` events still carries a KV/prefix value and must be read
with that caveat. The allowlist entries land first so the producers can be corrected
without a second coordinator deploy.

## v0.8.0 field semantics

### Paged KV pool

| Field | Type | Meaning |
|---|---|---|
| `pages_pinned` | int | Pages currently pinned in the paged pool and therefore not evictable. |
| `cow_events` | int | Cumulative copy-on-write page splits (shared prefix page diverged and had to be duplicated). |
| `pool_utilization` | float | Occupied pool pages / total pool pages, `[0,1]`. |

Aggregate counters only — never page contents, block hashes, or token ids.

### MTP (speculative decode)

MTP is otherwise **invisible** to the coordinator: before this change, `mtp`,
`speculat`, and `draft` matched nothing in `coordinator/protocol/`,
`coordinator/api/`, the provider `Protocol/` and `Telemetry/` trees, or
`console-ui/src/lib/`. That matters beyond diagnostics: MTP inflates
`observed_decode_tps` with no discriminator, so a partially-MTP fleet biases
coordinator routing on a metric the coordinator believes is homogeneous.

| Field | Type | Meaning |
|---|---|---|
| `mtp_enabled` | bool | `ProviderMTPStatusSnapshot.configured` — MTP is configured and the kill switch is off. |
| `mtp_active` | bool | `ProviderMTPStatusSnapshot.active` — the drafter is loaded and the engine reports itself active. |
| `mtp_inactive_reason` | string | Bounded enum, present whenever MTP is not *productively* running. |
| `mtp_acceptance_rate` | float | `acceptedDraftTokens / proposedTokens` for the reporting window, `[0,1]`; omitted when `proposedTokens == 0`. |

`mtp_inactive_reason` values are
[`MTPFallbackReason`](../../provider-swift/Sources/ProviderCore/SpecDec/SpecDecTypes.swift)
raw values (`config_disabled`, `kill_switch_disabled`, `target_unsupported`, …,
`engine_inactive`) **plus one value that has no enum case yet**:

* `inert_kv_unsupported` — **enabled but doing nothing.** On a paged `gemma-4-26b-qat-4bit`
  slot MTP currently reports `mtp_active = true` while executing zero rounds: the
  provider derives `active` from assistant-load success
  ([`ProviderEngineBundle.swift:32,36`](../../provider-swift/Sources/ProviderCore/Inference/ProviderEngineBundle.swift)),
  not from rounds executed. The slot charges ~236 MB of drafter residency, produces
  no rounds, and climbs `skippedRows["kv_unsupported"]`
  ([`EngineLoopV2+MTPPlanning.swift:47,169`](../../libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/MTP/EngineLoopV2+MTPPlanning.swift)).
  Without this value the state is unnameable: `mtp_active` is `true` and every
  existing `MTPFallbackReason` is wrong.

  **Follow-up required, not done here** (`SpecDecTypes.swift` is outside this change):
  add `case inertKVUnsupported = "inert_kv_unsupported"` to `MTPFallbackReason` and
  derive it in `ProviderMTPStatusSnapshot.init` when
  `rounds == 0 && skippedRows["kv_unsupported", default: 0] > 0`.

`mtp_acceptance_rate` is a per-event ratio and therefore **not** re-aggregatable by a
plain average — a fleet roll-up must weight each sample by its proposed-token count.
If weighted aggregation is needed server-side, add `mtp_proposed_tokens` and
`mtp_accepted_tokens` rather than post-processing the ratio.
