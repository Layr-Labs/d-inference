# coordinator-rs

Rust coordinator implementing `docs/architecture/rust-coordinator-plan.md`.

## Layout

| Path | Contents |
|---|---|
| `crates/protocol` | Wire types (JSON v1 + protocol v2 + binary frames), NaCl Box / P-256 crypto compatibility. Pure, no I/O. |
| `crates/core` | Domain newtypes, request/fleet state reducers, admission, scoring, calibration, health, hedging, money math. Pure, no I/O. |
| `crates/server` | Axum API adapter, FleetActor, ProviderSession, RequestTask, SQLx ledger, recovery workers, binary entry point. |
| `migrations/` | Additive `rust_coord` schema migrations (applied by a separate command, never at startup). |
| `fixtures/` | Golden wire frames and cross-language crypto vectors. |
| `tests/` | Workspace-level black-box suites (protocol goldens, fault injection). |

## Build and test

```bash
cd coordinator-rs
cargo build --workspace
cargo test --workspace
cargo clippy --workspace --all-targets
```

Postgres-backed ledger tests use an ephemeral database and are gated behind
`DARKBLOOM_TEST_DATABASE_URL` (or spawn ephemeral Postgres when `initdb` is on
PATH). Everything else runs with no external dependencies.

## Authority model (plan §7)

- `FleetActor` — live provider membership, eligibility, advisory capacity, prepare permits.
- `ProviderSession` — one WebSocket, one epoch, bounded two-lane writer, frame demux.
- `RequestTask` — one logical request: attempts, deadlines, commitment, cancellation.
- PostgreSQL — durable jobs, money, idempotency, catalog, trust records.
