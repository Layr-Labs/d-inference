# Telemetry event schema

> Last updated: 2026-10-06

The shape of a telemetry *event* as it exists in three mirrors (Go, Swift,
TypeScript), the closed enums it carries, and the tests that keep the mirrors
identical. Only one producer of this shape is live today: the coordinator's own
emitter, which forwards to Datadog. The coordinator has no client ingestion
route; the retired `POST /v1/telemetry/events` is not registered and gets a
plain 404. What each live datum is and where it goes:
[`telemetry-inventory.md`](telemetry-inventory.md); design and failure modes:
[`../architecture/telemetry.md`](../architecture/telemetry.md).

The terminal-profile [prediction decision fields](prediction-decision-telemetry.md)
use the separate Go/Swift profiler protocol, not this event shape or its
TypeScript mirror. Their optional `unbounded_reason` is a closed engine cause
folded by the coordinator before storage; it adds no event fields.

Durable cache statistics use optional typed heartbeat objects, not event
`fields`: [`slots[].prefix_cache`](protocol-messages.md#slotsprefix_cache) and
`backend_capacity.prefix_cache_maintenance`. The live producer/consumer and
counter units are listed in the [telemetry inventory](telemetry-inventory.md).
The client event facade remains disabled.

Cache donation outcomes also use the separate typed heartbeat protocol:
[`PrefixCacheDonationOutcomeCount`](protocol-messages.md) carries a bounded
reason and a cumulative count. Complete-checkpoint providers distinguish host
memory refusal, epoch invalidation, maintenance contention, insufficient disk
space, unsafe roots, write I/O failure, unreadable existing files and eviction.
`skipped_novel` identifies a complete checkpoint declined before any write
budget was charged because neither the coordinator's
`cache_repeated_prefix_tokens` nor local tag history showed repeat demand.
`write_speculative_limited` identifies a first-sight checkpoint classed
speculative (the request carried `cache_first_sight_tokens` and no observed
repeat, the store had not seen the tag and the request restored nothing from
it) that yielded to write-budget, writer or disk pressure before any budget
was charged. It is counted per offered checkpoint and published as a
fleet-wide total. The three limited outcomes (`write_queue_full` and the two
below) are not emitted for a speculative offer; they still count a
first-sight request's offers of the other two classes.
`write_priority_limited` identifies exhaustion of the novel-checkpoint write
share; `write_rate_limited` identifies exhaustion of the total write budget.
See the [SSD write policy](ssd-kv-cache.md#size-and-eviction-rules) for admission
semantics (`SSDWriteRateLimiter.decision`).
The legacy `write_failed` remains the fallback for unclassified producer errors
and older providers; it is not an I/O-error total. These are not event `fields`
and do not add fields to the TypeScript event mirror.

Paged allocator observations use the separate optional
[`slots[].paged_storage`](protocol-messages.md#slotspaged_storage) heartbeat
object (`coordinator/protocol/paged_storage_telemetry.go`, `PagedStorageTelemetry`).
They add no event fields. The native queue captures
`PagedKVStorageSnapshot`; `PagedStorageTelemetryAdapter` copies its scalars and
computes age for the heartbeat without traversing allocator ownership. Optional
`allocator_padding_bytes` and `last_allocation_allowance_bytes` distinguish
retained nonusable bytes from released preparation allowance. The canonical
`coordinator/tests/protocol/testdata/paged_footprint_wire.json` fixture pins their
wire representation and omission behavior across Swift, Go and TypeScript.

Process ownership uses optional
[`backend_capacity.telemetry.process_memory`](protocol-messages.md#backend_capacitytelemetryprocess_memory)
(`coordinator/protocol/process_memory_telemetry.go`, `ProcessMemoryTelemetry`).
The Swift producer, Go consumer and TypeScript mirror share the canonical
`coordinator/tests/protocol/testdata/process_memory_wire.json` fixture. These scalar
observations add no event fields.

## Local provider drain events

`provider-swift/Sources/ProviderCore/Service/ProviderDrainTelemetry.swift`
(`ProviderDrainTelemetry`) writes a local stderr JSON event when phase or
remaining-work count changes. It contains only `operation = provider_drain`,
`reason` (`serving`, `draining`, `drained`, `timedOut`, `forced`, `busy`),
`in_flight`, and `coordinator_acknowledged`. It has no inference/control IDs,
models, credentials, prompts or responses. These local records are not uploaded;
the privacy-disabled `TelemetryClient` and the wire enums remain unchanged. A startup/scheduled-idle process with no coordinator connection can
be drained without claiming `coordinator_acknowledged = true`. The daemon state and CLI also report the drain deadline and outcome.


## Mirrors

Serving-rate observations are heartbeat capacity fields, not events in this
schema. Their optional age/count/epoch and workload-bucket contract is documented
in [protocol messages](protocol-messages.md#slotsperformance_measurements) and mirrored by the
Go/Swift profiler fixture. They do not add an event kind or a TS event field.

| Mirror | File | Types | Role today |
|---|---|---|---|
| Go (canon) | `coordinator/protocol/telemetry.go` | `TelemetryEvent`, `TelemetrySource`, `TelemetrySeverity`, `TelemetryKind` | shape and enums |
| Go emitter | `coordinator/telemetry/emitter.go` | `Emitter.Emit`, `Event` | the only live producer; source forced to `coordinator`; Datadog is the sole durable sink |
| Swift | `provider-swift/Sources/ProviderCore/Telemetry/TelemetryEvent.swift` | `TelemetryEvent`, `TelemetrySource`, `TelemetrySeverity`, `TelemetryKind` | inert: `TelemetryClient.swift` is a no-op facade (`emit` discards, `configure`/`shutdown` do nothing) |
| TypeScript | `console-ui/src/lib/telemetry-types.ts` | `TelemetryEvent`, `TelemetrySource`, `TelemetrySeverity`, `TelemetryKind` | types for the no-op `console-ui/src/lib/telemetry.ts` facade |

## Event fields

| JSON key | Go | Swift | TS | Presence | Notes |
|---|---|---|---|---|---|
| `id` | `string` | `String` | `string` | req | UUIDv4 minted by the producer |
| `timestamp` | `time.Time` (RFC 3339) | `String` (ISO 8601) | `string` | req | producer wall clock |
| `source` | `TelemetrySource` | `TelemetrySource` | union | req | see enums; the emitter writes `coordinator` |
| `severity` | `TelemetrySeverity` | `TelemetrySeverity` | union | req | see enums |
| `kind` | `TelemetryKind` | `TelemetryKind` | union | req | see enums |
| `version` | `string` | `String?` | `string?` | opt | component version |
| `machine_id` | `string` | `String?` | `string?` | opt | stable per-machine identifier |
| `account_id` | `string` | `String?` | `string?` | opt | account the event concerns |
| `request_id` | `string` | `String?` | `string?` | opt | correlation with an inference job |
| `session_id` | `string` | `String?` | `string?` | opt | per-process UUID (`TelemetrySession.id` in Swift, `telemetry.SessionID` in Go) |
| `message` | `string` | `String` | `string` | req | developer-authored |
| `fields` | `map[string]any` | `[String: AnyCodableValue]?` | `Record<string, unknown>?` | opt | structured operational fields fixed by the emitting call site |
| `stack` | `string` | `String?` | `string?` | opt | backtrace (panics) |

Casing and omission rules: every key is snake_case and identical across the
three mirrors (`TelemetrySymmetryTests.swift` pins the exact encoded string).
Go optional fields are `omitempty`; Swift uses `encodeIfPresent`; TS marks them
`?`. The six required keys are always present in every mirror. There is no
batch wire type: nothing sends or accepts events.

## Enums

Every raw value is lowercase snake_case. Swift cases are camelCase with an
explicit raw value where the two differ; TS uses string-literal unions.

| Enum | Values |
|---|---|
| `source` | `coordinator`, `provider`, `app`, `console`, `bridge`; the coordinator emitter writes `coordinator` |
| `severity` | `debug`, `info`, `warn`, `error`, `fatal` |
| `kind` | `panic`, `http_error`, `protocol_error`, `backend_crash`, `attestation_failure`, `inference_error`, `runtime_mismatch`, `connectivity`, `oom`, `engine_health`, `log`, `custom` |

The emitter maps severity to `slog` level: `fatal`/`error` → `Error`, `warn` →
`Warn`, `debug` → `Debug`, else `Info`.

## Event fields are fixed at the call site

No server-side field allowlist exists: nothing ingests client events, and the
coordinator emitter does not filter. Each emitting call site passes a fixed set
of operational keys (bounded enums, counters, byte counts and durations; never
prompt, completion, media or cache content), enumerated in
[`telemetry-inventory.md`](telemetry-inventory.md#coordinator-emitted-events).
No mirror carries a field filter. To add a field, add it at the call site with a bounded value and
list it in the inventory.

## Coordinator emitter

`Emitter.Emit` (`coordinator/telemetry/emitter.go`) is the one live path that
builds this shape. It does not filter fields; every call site passes its fixed
keys. Each event goes to three places in order:

| Sink | What |
|---|---|
| `slog` | `telemetry: <message>` at the mapped level, with `kind`, `request_id` (when set) and every field as attributes |
| in-process registry | `telemetry_events_total{source, severity, kind}` via `Metrics.IncCounterEvent` (`coordinator/api/`), readable at `GET /v1/admin/metrics` |
| Datadog Logs API | `datadog.Client.ForwardLog` (`coordinator/datadog/datadog.go`) → `https://http-intake.logs.<site>/api/v2/logs`, only when `DD_API_KEY` is set |

Call sites (`Owner.Emit`, `Owner.EmitRequest`, `Owner.EmitPanic` in `coordinator/api/observation/events.go`)
and their fields are enumerated in
[`telemetry-inventory.md`](telemetry-inventory.md#coordinator-emitted-events).

## Tests that pin the mirrors

| Test | File | Pins |
|---|---|---|
| `TestTelemetryJSONSymmetry`, `TestTelemetryKindsMatch` | `coordinator/tests/protocol/telemetry_symmetry_test.go` | canonical event encodes to the exact JSON string; the kind set |
| `telemetryEventJSONSymmetry`, `telemetryKindsMatch`, `sourceAndSeverityRawValues` | `provider-swift/Tests/ProviderCoreTests/Telemetry/TelemetrySymmetryTests.swift` | the Swift mirror of the two Go tests plus the source/severity raw values |
| `TestTelemetryE2E_NoClientIngestionRoute` | `coordinator/tests/api/operations/contracts/telemetry_e2e_test.go` | the retired ingest route is gone: 404, body not reflected, nothing counted |
| `TelemetryClientTests.swift`, `TelemetryOverflowQueueTests.swift` | `provider-swift/Tests/ProviderCoreTests/Telemetry/TelemetryClientTests.swift`, `provider-swift/Tests/ProviderCoreTests/Telemetry/TelemetryOverflowQueueTests.swift` | the client facade stays inert and the legacy queue purge removes only regular files |

## Related

- [`telemetry-inventory.md`](telemetry-inventory.md) — every datum, producer, sink, cadence, retention
- [`../architecture/telemetry.md`](../architecture/telemetry.md) — mechanism, invariants, failure modes, Datadog metric names
- [`protocol-messages.md`](protocol-messages.md) — the heartbeat fields the coordinator turns into metrics
