# Telemetry & Crash Reporting

> Darkbloom ships its own telemetry pipeline instead of depending on Sentry / Datadog / Prometheus SaaS. Everything rides on infrastructure we already own: providers and the console post events over HTTPS to the coordinator, which persists them to Postgres.

---

## Table of Contents

- [Overview](#overview)
- [Wire Protocol](#wire-protocol)
- [Endpoints](#endpoints)
- [Privacy & Field Allowlist](#privacy--field-allowlist)
- [Retention](#retention)
- [Storage Schema](#storage-schema)
- [Emission Sites](#emission-sites)
- [Adding a New Emit Site](#adding-a-new-emit-site)
- [Protocol Symmetry](#protocol-symmetry)

---

## Overview

```
provider (Rust/Swift) ─┐
macOS app ─────────────┤                       ┌─> Postgres `telemetry_events`
image bridge ─────────►├──► Coordinator ingest ├─> In-process metrics registry
console UI ────────────┤    /v1/telemetry/*     └─> Admin UI (read-only)
coordinator ──────────►┘
```

All clients (Go, Rust, Swift, TypeScript) serialize the exact same JSON shape. A symmetry test in each language pins the enum casing and optional field omission so they can't drift.

## Wire Protocol

```jsonc
{
  "events": [
    {
      "id": "uuid-v4",                          // required
      "timestamp": "2026-04-16T10:00:00.000Z",  // required, RFC 3339
      "source": "provider",                     // coordinator | provider | app | console | bridge
      "severity": "error",                      // debug | info | warn | error | fatal
      "kind": "backend_crash",                  // see protocol/telemetry.go
      "version": "0.3.10",                      // component version
      "machine_id": "base64-SE-pubkey-or-uuid",
      "account_id": "account_xyz",              // server-stamped from auth
      "request_id": "req_abc",                  // optional correlation
      "session_id": "per-process-uuid",
      "message": "backend health check failed",
      "fields": {                               // allowlisted keys only
        "backend": "vllm-mlx",
        "exit_code": 134
      },
      "stack": "at foo::bar\n…"                 // optional
    }
  ]
}
```

## Endpoints

| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| `POST` | `/v1/telemetry/events` | Provider token / API key / Privy JWT / anonymous | Ingest a batch of events |
| `GET` | `/v1/admin/telemetry` | Admin | List events with filters |
| `GET` | `/v1/admin/telemetry/summary` | Admin | Rollup by (source, severity, kind) |
| `GET` | `/v1/admin/metrics` | Admin | JSON metrics snapshot |
| `GET` | `/v1/admin/metrics?format=prom` | Admin | Prometheus text format |

### Ingest Limits

| Limit | Value |
|-------|-------|
| Max body size | 64 KB |
| Max events per batch | 100 |
| Rate limit (authenticated) | 200 burst + 100/min per machine/account |
| Rate limit (anonymous) | 30 burst + 10/min |

## Privacy & Field Allowlist

**Telemetry NEVER carries user prompts, completions, or any other user-authored content.**

The server enforces this by running every `fields` key through an allowlist in `coordinator/api/telemetry_handlers.go`. Anything outside the allowlist is silently dropped.

**Allowed keys** (extend this list when adding an emit site, if the field is non-sensitive):

```
component, operation, duration_ms, attempt, endpoint, status_code,
error_class, error, model, backend, exit_code, signal, hardware_chip,
memory_gb, macos_version, handler, provider_id, trust_level, queue_depth,
reason, runtime_component, reconnect_count, last_error, ws_state,
billing_method, payment_failed, target, url, user_agent, route
```

Free-form developer strings go in the `message` field only. Do not put anything user-generated into `message` either.

## Retention

`coordinator/telemetry/retention.go` runs a prune loop hourly (configurable via `EIGENINFERENCE_TELEMETRY_PRUNE_INTERVAL`). Events older than 14 days (configurable via `EIGENINFERENCE_TELEMETRY_MAX_AGE`) are deleted.

The in-memory store uses a bounded 10k-event ring buffer instead.

## Storage Schema

```sql
CREATE TABLE telemetry_events (
    id          UUID        PRIMARY KEY,
    ts          TIMESTAMPTZ NOT NULL,
    source      TEXT        NOT NULL,
    severity    TEXT        NOT NULL,
    kind        TEXT        NOT NULL,
    version     TEXT        NOT NULL DEFAULT '',
    machine_id  TEXT        NOT NULL DEFAULT '',
    account_id  TEXT        NOT NULL DEFAULT '',
    request_id  TEXT        NOT NULL DEFAULT '',
    session_id  TEXT        NOT NULL DEFAULT '',
    message     TEXT        NOT NULL,
    fields      JSONB       NOT NULL DEFAULT '{}',
    stack       TEXT        NOT NULL DEFAULT '',
    received_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

**Indexes:** `ts`, `(source, severity, ts)`, `kind`, `machine_id`, `request_id`

## Emission Sites

### Coordinator (Go)

`coordinator/api/server.go` wraps the mux with `recoverMiddleware`, which catches any handler panic and emits `severity=fatal, kind=panic` with `debug.Stack()` before returning 500.

Explicit emit sites:

| File | Events |
|------|--------|
| `consumer.go` | Inference retry, first-chunk timeout, dispatch exhausted |
| `provider.go` | Registration outcome, attestation-challenge failure, WebSocket read error |
| Server metrics | `providers_online` gauge |

### Provider (Rust)

`provider/src/telemetry/` is a self-contained module.

| Component | Events |
|-----------|--------|
| `panic_hook::install(client)` | Captures backtrace and forwards panics |
| `backend/mod.rs` | Backend health-check failure + restart failure |
| `coordinator.rs` | Coordinator reconnect storms (attempts 3/10/30…) |
| `telemetry::emit(event)` | Direct API for any subsystem |

The client spawns a background batcher that POSTs to the coordinator. On network failure, events spill to `~/.darkbloom/telemetry-queue.jsonl`, capped at 5 MB; the oldest half is rotated out on overflow.

### Provider (Swift)

`provider-swift/Sources/ProviderCore/Telemetry/TelemetryClient.swift` is the Swift telemetry client with a bounded event buffer and debounced flush.

### Console UI (TypeScript)

`console-ui/src/lib/telemetry.ts` runs a browser-side batcher with a debounced flush and `navigator.sendBeacon` fallback on page unload.

| Component | Events |
|-----------|--------|
| `TelemetryInitializer` | `window.error` + `unhandledrejection` listeners; `session_start` log |
| `app/global-error.tsx` | Next.js last-resort boundary; renders friendly page + emits `fatal` event |

## Adding a New Emit Site

1. **Pick the right `kind`.** If none fit, use `custom` with a `component` field rather than inventing a new kind silently.
2. **Only put allowlisted keys in `fields`.** If you need a new key, extend all three mirrors:
   - `coordinator/api/telemetry_handlers.go` (server allowlist)
   - `provider/src/telemetry/layer.rs` (Rust filter)
   - `console-ui/src/lib/telemetry-types.ts` (TS set)
3. **Keep `message` short and developer-authored.** Never interpolate user-supplied strings into `message`.
4. **For latency / duration reporting**, use the metrics registry (`ObserveHistogram`) instead of telemetry events.

## Protocol Symmetry

Three codebases serialize the same event shape. Any change to the protocol requires updates in three places:

| Language | File |
|----------|------|
| Go | `coordinator/protocol/telemetry.go` |
| Rust | `provider/src/telemetry/event.rs` |
| TypeScript | `console-ui/src/lib/telemetry-types.ts` |

Symmetry tests pin enum casing (`lowercase` / `snake_case`) and optional field omission so CI fails loudly when one mirror drifts.
