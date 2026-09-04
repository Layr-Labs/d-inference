# Telemetry event schema

> Last updated: 2026-09-03 · commit `5d400cf75`

The shape of a telemetry *event* as it exists in three mirrors (Go, Swift,
TypeScript), the closed enums it carries, the field allowlist, and the tests
that keep the mirrors identical. Only one producer of this shape is live today:
the coordinator's own emitter, which forwards to Datadog. Client ingestion is
switched off — `POST /v1/telemetry/events` answers `telemetry_ingest_disabled`
([`api-contracts.md#telemetry-1`](api-contracts.md#telemetry-1)) without reading
the body — but the allowlist still governs what the Swift and console filters
let through and what the coordinator emits about itself. What each live datum
is and where it goes: [`telemetry-inventory.md`](telemetry-inventory.md);
design and failure modes: [`../architecture/telemetry.md`](../architecture/telemetry.md).

## Mirrors

| Mirror | File | Types | Role today |
|---|---|---|---|
| Go (canon) | `coordinator/protocol/telemetry.go` | `TelemetryEvent`, `TelemetryBatch`, `TelemetrySource`, `TelemetrySeverity`, `TelemetryKind` | shape and enums |
| Go allowlist | `coordinator/api/telemetry_handlers.go` | `telemetryFieldAllowlist`, `sanitizeTelemetryEvent`, `handleTelemetryIngest` | allowlist of record; the sanitizer is retained but no route reaches it |
| Go emitter | `coordinator/telemetry/emitter.go` | `Emitter.Emit`, `Event` | the only live producer; source forced to `coordinator` |
| Go store mirror | `coordinator/store/interface.go` | `TelemetryEventRecord` | `TelemetryEvent` + `received_at`; nothing persists it — Datadog is the sole sink |
| Swift | `provider-swift/Sources/ProviderCore/Telemetry/TelemetryEvent.swift` | `TelemetryEvent`, `TelemetrySource`, `TelemetrySeverity`, `TelemetryKind`, `TelemetryFieldFilter` | client-side pre-filter; `TelemetryClient.swift` is a no-op facade (`emit` discards, `configure`/`shutdown` do nothing) |
| TypeScript | `console-ui/src/lib/telemetry-types.ts` | `TelemetryEvent`, `TelemetrySource`, `TelemetrySeverity`, `TelemetryKind`, `TELEMETRY_ALLOWED_FIELDS` | console filter types |

## Event fields

| JSON key | Go | Swift | TS | Presence | Notes |
|---|---|---|---|---|---|
| `id` | `string` | `String` | `string` | req | UUIDv4 minted by the producer; the sanitizer re-mints anything `uuid.Parse` rejects |
| `timestamp` | `time.Time` (RFC 3339) | `String` (ISO 8601) | `string` | req | producer wall clock; the sanitizer clamps to `[now − 7 d, now + 5 min]`, else `now` |
| `source` | `TelemetrySource` | `TelemetrySource` | union | req | see enums; the emitter overwrites it with `coordinator` |
| `severity` | `TelemetrySeverity` | `TelemetrySeverity` | union | req | unknown → `info` |
| `kind` | `TelemetryKind` | `TelemetryKind` | union | req | unknown → `custom` |
| `version` | `string` | `String?` | `string?` | opt | component version, ≤ 64 chars after sanitising |
| `machine_id` | `string` | `String?` | `string?` | opt | ≤ 128 chars |
| `account_id` | `string` | `String?` | `string?` | opt | ≤ 128 chars; server-stamped from auth when a route existed |
| `request_id` | `string` | `String?` | `string?` | opt | ≤ 128 chars; correlation with an inference job |
| `session_id` | `string` | `String?` | `string?` | opt | ≤ 64 chars; per-process UUID (`TelemetrySession.id` in Swift, `telemetry.SessionID` in Go) |
| `message` | `string` | `String` | `string` | req | developer-authored; empty → event rejected; > `telemetryMaxMessage = 4096` bytes → truncated with `…` |
| `fields` | `map[string]any` | `[String: AnyCodableValue]?` | `Record<string, unknown>?` | opt | allowlist-filtered; serialised size > `telemetryMaxFieldsKB = 8 KiB` → `{}` |
| `stack` | `string` | `String?` | `string?` | opt | > `telemetryMaxStack = 32 KiB` → truncated with `… [truncated]` |
| `received_at` | `time.Time` | — | — | store mirror only | `TelemetryEventRecord` |

Casing and omission rules: every key is snake_case and identical across the
three mirrors (`TelemetrySymmetryTests.swift` pins the exact encoded string).
Go optional fields are `omitempty`; Swift uses `encodeIfPresent`; TS marks them
`?`. The six required keys are always present in every mirror. `TelemetryBatch`
is `{"events": [TelemetryEvent, …]}`, at most `telemetryMaxBatch = 100` events
in `telemetryMaxBodyBytes = 64 KiB`.

## Enums

Every raw value is lowercase snake_case. Swift cases are camelCase with an
explicit raw value where the two differ; TS uses string-literal unions.

| Enum | Values | Fallback |
|---|---|---|
| `source` | `coordinator`, `provider`, `app`, `console`, `bridge` | `custom` (`TelemetrySourceCustomValue`) for anything outside `KnownSources()`; authenticated providers were always rewritten to `provider` |
| `severity` | `debug`, `info`, `warn`, `error`, `fatal` | `info` |
| `kind` | `panic`, `http_error`, `protocol_error`, `backend_crash`, `attestation_failure`, `inference_error`, `runtime_mismatch`, `connectivity`, `oom`, `engine_health`, `log`, `custom` | `custom` |

The emitter maps severity to `slog` level: `fatal`/`error` → `Error`, `warn` →
`Warn`, `debug` → `Debug`, else `Info`.

## Field allowlist

`telemetryFieldAllowlist` (`coordinator/api/telemetry_handlers.go`) has 90 keys.
`sanitizeTelemetryEvent` drops any other key silently. The Swift
`TelemetryFieldFilter.allowed` set and the TS `TELEMETRY_ALLOWED_FIELDS` set are
mirrors of it, minus the [known gaps](#known-mirror-gaps). Values are bounded
enums, counters, byte counts and durations; prompt, completion, media and cache
content are never admitted.

| Group | Keys |
|---|---|
| Generic | `component`, `operation`, `duration_ms`, `attempt`, `endpoint`, `status_code`, `error_class`, `error`, `target` |
| Provider / backend | `model`, `backend`, `exit_code`, `signal`, `hardware_chip`, `memory_gb`, `macos_version` |
| Boot-security posture | `boot_macos_major`, `boot_sip_status` |
| Coordinator | `handler`, `provider_id`, `trust_level`, `queue_depth`, `reason`, `runtime_component` |
| Connectivity | `reconnect_count`, `last_error`, `ws_state`, `network_reachable`, `coordinator_url` |
| Billing (booleans/enums only) | `billing_method`, `payment_failed` |
| OOM / memory pressure | `detect_source`, `peak_memory_bytes`, `report`, `pressure`, `available_bytes`, `mlx_active_bytes`, `memory_pressure`, `in_flight` |
| Engine health / first-token wedge | `steps_executed`, `admits`, `first_tokens_emitted`, `consecutive_admits_without_first_token`, `seconds_since_last_step`, `seconds_since_last_first_token`, `num_running`, `wedge_suspected` |
| Eval / idle-clear / prefill sampling | `eval_in_flight_ms`, `longest_eval_ms`, `evals_completed`, `idle_clear_in_flight_ms`, `idle_clears_completed`, `prefill_samples_accepted`, `prefill_samples_dropped_floor`, `prefill_samples_dropped_ceiling`, `last_prefill_sample_tps`, `observed_prefill_tps_ewma` |
| KV-budget sustained-rejection audit | `streak_seconds`, `reservation_count`, `reserved_bytes`, `mlx_cache_bytes`, `system_available_bytes`, `reservations`, `request_id`, `age_seconds` |
| Media through engine_v2 | `multimodal`, `media_kind` (`image`/`video`/`mixed`) |
| Exact-prefix replay | `prefix_reuse_strategy`, `prefix_matched_tokens`, `prefix_replay_tokens`, `prefix_saved_tokens`, `prefix_boundary_splits`, `prefix_construction_failure`, `prefix_capacity_refusal`, `prefix_cold_fallback` |
| KV-backend discriminator | `kv_backend` (`paged`/`contiguous`, same key as `BackendSlotCapacity.KVBackend` on the heartbeat), `prefix_reuse_backend` (`contiguous_unquantized`/`contiguous_quantized`/`paged_fp16`/`unknown`) |
| Paged KV pool | `pool_utilization` (occupancy ratio), `pool_bytes`, `pool_deferred_growth_bytes`, `pool_stranded_bytes` (raw bytes; `pages_pinned` and `cow_events` are deliberately absent because neither mechanism exists) |
| Multi-token prediction | `mtp_enabled`, `mtp_active`, `mtp_inactive_reason` (`MTPFallbackReason` values plus `inert_kv_unsupported`), `mtp_acceptance_rate`, `mtp_proposed_tokens`, `mtp_accepted_tokens` |
| Console UI context | `url`, `user_agent`, `route` |

### Known mirror gaps

`telemetryKnownMirrorGaps` (`coordinator/api/telemetry_allowlist_parity_test.go`)
lists the drift that ships. Each entry is a client-side completeness gap, not a
wire incompatibility: Go accepts the key, the named client never sends it.

| Key | Missing from | Why |
|---|---|---|
| `network_reachable`, `coordinator_url` | Swift, TS | coordinator-side connectivity bookkeeping only |
| `url`, `user_agent`, `route` | Swift | browser context; TS has them |

### Adding a field: one key, one meaning

Add the key to all three mirrors in one change, with its producer. A key with
no producer reads as a legitimate zero on a dashboard. Do not add a second
ratio under a name that collides with an existing one (`pool_utilization` is
occupancy; `pool_bytes` is emitted so share-of-pool stays derivable). Retiring
a gap means deleting its `telemetryKnownMirrorGaps` entry and adding the key to
the mirror in the same change; `TestTelemetryAllowlistKnownGapsAreStillReal`
fails on stale entries.

## Ingestion endpoint

| Route | Handler | Behaviour |
|---|---|---|
| `POST /v1/telemetry/events` | `handleTelemetryIngest` (`coordinator/api/telemetry_handlers.go`) | Always the `telemetry_ingest_disabled` error (status and route-table entry: [`api-contracts.md#telemetry-1`](api-contracts.md#telemetry-1)), without reading, decoding, logging or forwarding the request body. The route stays registered so old providers get a terminal answer; `TelemetryClient.swift` no longer posts at all |

Retained but unreachable from any route: `sanitizeTelemetryEvent`,
`telemetryLimiter` (`newTelemetryLimiter`: burst 200 / 100 events per minute per
machine or account, burst 30 / 10 per minute anonymous), and the batch and body
limits above. `TestTelemetryIngestIsGoneWithoutReadingOrForwardingBody` pins
the `telemetry_ingest_disabled` response.

## Coordinator emitter

`Emitter.Emit` (`coordinator/telemetry/emitter.go`) is the one live path that
builds this shape. It does not run the allowlist; every call site passes
allowlisted keys by construction. Each event goes to three places in order:

| Sink | What |
|---|---|
| `slog` | `telemetry: <message>` at the mapped level, with `kind`, `request_id` (when set) and every field as attributes |
| in-process registry | `telemetry_events_total{source, severity, kind}` via `Metrics.IncCounterEvent` (`coordinator/api/metrics.go`), readable at `GET /v1/admin/metrics` |
| Datadog Logs API | `datadog.Client.ForwardLog` (`coordinator/datadog/datadog.go`) → `https://http-intake.logs.<site>/api/v2/logs`, only when `DD_API_KEY` is set |

Call sites (`s.emit`, `s.emitRequest`, `s.emitPanic` in `coordinator/api/server.go`)
and their fields are enumerated in
[`telemetry-inventory.md`](telemetry-inventory.md#coordinator-emitted-events).

## Tests that pin the mirrors

| Test | File | Pins |
|---|---|---|
| `TestTelemetryJSONSymmetry`, `TestTelemetryKindsMatch` | `coordinator/protocol/telemetry_symmetry_test.go` | canonical event encodes to the exact JSON string; the kind set |
| `telemetryEventJSONSymmetry`, `telemetryKindsMatch`, `sourceAndSeverityRawValues` | `provider-swift/Tests/ProviderCoreTests/TelemetrySymmetryTests.swift` | the Swift mirror of the two Go tests plus the source/severity raw values |
| `TestTelemetryAllowlistThreeWayParity`, `TestTelemetryAllowlistKnownGapsAreStillReal`, `TestTelemetryAllowlistDiffDetectsNewDrift` | `coordinator/api/telemetry_allowlist_parity_test.go` | Go ↔ Swift ↔ TS allowlist sets, parsed from source; known gaps stay real |
| `TestTelemetryIngestIsGoneWithoutReadingOrForwardingBody`, `TestTelemetryFieldAllowlistHasKnownKeys`, `TestSanitizeTruncatesLongMessage` | `coordinator/api/telemetry_handlers_test.go` | the `telemetry_ingest_disabled` response, allowlist membership, message truncation |
| `TelemetryClientTests.swift`, `TelemetryOverflowQueueTests.swift` | `provider-swift/Tests/ProviderCoreTests/` | the facade stays inert |

## Related

- [`telemetry-inventory.md`](telemetry-inventory.md) — every datum, producer, sink, cadence, retention
- [`../architecture/telemetry.md`](../architecture/telemetry.md) — mechanism, invariants, failure modes, Datadog metric names
- [`protocol-messages.md`](protocol-messages.md) — the heartbeat fields the coordinator turns into metrics
- [`api-contracts.md#telemetry-1`](api-contracts.md#telemetry-1) — the route table entry for `/v1/telemetry/events` (`telemetry_ingest_disabled`)
