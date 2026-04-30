# Telemetry & Crash Reporting

EigenInference ships its own telemetry pipeline instead of depending on
Sentry / Datadog / Prometheus SaaS. Everything rides on infrastructure we
already own: providers and the console post events over HTTPS to the
coordinator, which persists them to Postgres.

```
provider (Rust) ─┐
macOS app ───────┤                    ┌─> Postgres `telemetry_events`
image bridge ───►├─► coordinator ingest┤
console UI ──────┤   /v1/telemetry/*   ├─> in-process metrics registry
coordinator ────►┘                     └─> admin UI (read-only)
```

## Wire protocol

All three clients (Go, Rust, TypeScript) serialize the exact same JSON
shape. A symmetry test in each language pins the enum casing and optional
field omission so they can't drift.

```jsonc
{
  "events": [
    {
      "id": "uuid-v4",                       // required
      "timestamp": "2026-04-16T10:00:00.000Z", // required, RFC3339
      "source": "provider",                    // coordinator|provider|app|console|bridge
      "severity": "error",                     // debug|info|warn|error|fatal
      "kind": "backend_crash",                 // see protocol/telemetry.go
      "version": "0.3.10",                     // component version
      "machine_id": "base64-SE-pubkey-or-uuid",
      "account_id": "account_xyz",             // server-stamped from auth
      "request_id": "req_abc",                 // optional correlation
      "session_id": "per-process-uuid",
      "message": "backend health check failed",
      "fields": {                              // allowlisted keys only
        "backend": "vllm-mlx",
        "exit_code": 134
      },
      "stack": "at foo::bar\n…"                // optional
    }
  ]
}
```

## Endpoints

| Method | Path                              | Auth                        | Purpose                          |
|--------|-----------------------------------|-----------------------------|----------------------------------|
| POST   | /v1/telemetry/events              | provider token / API key / Privy JWT / anonymous | Ingest a batch of events |
| GET    | /v1/admin/telemetry               | admin                       | List events with filters         |
| GET    | /v1/admin/telemetry/summary       | admin                       | Rollup by (source,severity,kind) |
| GET    | /v1/admin/metrics                 | admin                       | JSON metrics snapshot            |
| GET    | /v1/admin/metrics?format=prom     | admin                       | Prometheus text format           |

Ingest limits:

- Max body: 64 KB.
- Max batch: 100 events.
- Rate limit: 200 burst + 100/min per authenticated machine/account.
  Anonymous sources get 30 burst + 10/min.

## Privacy and the field allowlist

**Telemetry NEVER carries user prompts, completions, or any other
user-authored content.** The server enforces this by running every `fields`
key through an allowlist in
`coordinator/internal/api/telemetry_handlers.go`. Anything outside the
allowlist is silently dropped.

Allowed keys (extend this list when adding an emit site, if the field is
non-sensitive):

```
component, operation, duration_ms, attempt, endpoint, status_code,
error_class, error, model, backend, exit_code, signal, hardware_chip,
memory_gb, macos_version, handler, provider_id, trust_level, queue_depth,
reason, runtime_component, reconnect_count, last_error, ws_state,
billing_method, payment_failed, target, url, user_agent, route
```

Free-form developer strings go in the `message` field only. Do not put
anything user-generated into `message` either.

## Retention

`coordinator/internal/telemetry/retention.go` runs a prune loop hourly
(configurable via `EIGENINFERENCE_TELEMETRY_PRUNE_INTERVAL`). Events older
than 14 days (configurable via `EIGENINFERENCE_TELEMETRY_MAX_AGE`) are
deleted.

The in-memory store uses a bounded 10k-event ring buffer instead.

## Storage schema

```sql
CREATE TABLE telemetry_events (
  id UUID PRIMARY KEY,
  ts TIMESTAMPTZ NOT NULL,
  source TEXT NOT NULL,
  severity TEXT NOT NULL,
  kind TEXT NOT NULL,
  version TEXT NOT NULL DEFAULT '',
  machine_id TEXT NOT NULL DEFAULT '',
  account_id TEXT NOT NULL DEFAULT '',
  request_id TEXT NOT NULL DEFAULT '',
  session_id TEXT NOT NULL DEFAULT '',
  message TEXT NOT NULL,
  fields JSONB NOT NULL DEFAULT '{}',
  stack TEXT NOT NULL DEFAULT '',
  received_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

Indexes are created in `postgres.go` on `ts`, `(source, severity, ts)`,
`kind`, `machine_id`, and `request_id`.

## Emission sites

### Coordinator (Go)

`coordinator/internal/api/server.go` wraps the mux with
`recoverMiddleware`, which catches any handler panic and emits
`severity=fatal, kind=panic` with `debug.Stack()` before returning 500.

Explicit emit sites:

- `consumer.go`: inference retry / first-chunk timeout / dispatch exhausted.
- `provider.go`: registration outcome, attestation-challenge failure,
  WebSocket read error.
- Default metrics gauge `providers_online`.

### Provider (Rust)

`provider/src/telemetry/` is a self-contained module.

- `panic_hook::install(client)` captures backtrace and forwards panics.
- Backend health-check failure + restart failure (`backend/mod.rs`).
- Coordinator reconnect storms (`coordinator.rs` at attempts 3/10/30…).
- `telemetry::emit(event)` is a direct API for any subsystem.

The client spawns a background batcher that POSTs to the coordinator.
On network failure events spill to `~/.darkbloom/telemetry-queue.jsonl`,
capped at 5 MB; the oldest half is rotated out on overflow.

### macOS App (Swift)

`app/EigenInference/Sources/EigenInference/TelemetryReporter.swift` is a
singleton with a bounded 500-event buffer and debounced flush.

- `AppDelegate` installs `NSSetUncaughtExceptionHandler` for fatal Obj-C
  exceptions.
- `ProviderManager` emits `backend_crash` on every subprocess exit, and
  `fatal` when the restart limit is exceeded.

### Console UI (TypeScript)

`console-ui/src/lib/telemetry.ts` runs a browser-side batcher with a
debounced flush and `navigator.sendBeacon` fallback on page unload.

- `TelemetryInitializer` registers `window.error` + `unhandledrejection`
  listeners at mount and emits a session_start log.
- `app/global-error.tsx` is the Next.js last-resort boundary; it renders
  a friendly page and emits a `fatal` event.

## Adding a new emit site

1. Pick the right `kind`. If none fit, use `custom` with a `component`
   field rather than inventing a new kind silently.
2. Only put allowlisted keys in `fields`. If you need a new key, extend:
   - `coordinator/internal/api/telemetry_handlers.go` (server allowlist),
   - `provider/src/telemetry/layer.rs` (Rust filter),
   - `console-ui/src/lib/telemetry-types.ts` (TS set).
3. Keep `message` short and developer-authored. Never interpolate
   user-supplied strings into `message`.
4. For latency / duration reporting, use the metrics registry
   (`ObserveHistogram`) instead of telemetry events.

## Protocol symmetry

Because three codebases serialize the same event shape, any change to the
protocol requires updates in three places:

- `coordinator/internal/protocol/telemetry.go`
- `provider/src/telemetry/event.rs`
- `console-ui/src/lib/telemetry-types.ts`

Symmetry tests pin enum casing (`lowercase` / `snake_case`) and optional
field omission so CI fails loudly when one mirror drifts.
