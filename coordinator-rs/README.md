# Rust Coordinator

Pre-production replacement for the Go coordinator. It is a single-active
modular monolith with three primary crates:

| Crate | Responsibility |
|---|---|
| `protocol` | Versioned provider wire types, binary framing, crypto compatibility |
| `core` | Pure request/fleet state reducers, admission, health, pricing |
| `server` | Axum/Tokio adapters, provider sessions, SQLx, workers, binary |

The Rust binary is not a production target until the migration's protocol,
money, recovery, parity, pilot, and rollback gates pass. The Go coordinator
remains authoritative during this phase.

## Commands

```bash
make coordinator-rs-fmt
make coordinator-rs-lint
make coordinator-rs-test
make coordinator-rs-build
make coordinator-rs-sqlx
```

Runtime configuration currently required by the composition root:

```text
EIGENINFERENCE_DATABASE_URL
EIGENINFERENCE_COORDINATOR_OWNERSHIP_ENABLED  default false; irreversible once activated
EIGENINFERENCE_RUST_BIND_ADDRESS              default 0.0.0.0:8081
EIGENINFERENCE_RUST_DATABASE_MAX_CONNECTIONS default 32
EIGENINFERENCE_RUST_SHUTDOWN_GRACE_SECONDS   default 30
```

Application startup never applies DDL. Checked SQL metadata is committed under
`.sqlx/`; the Go `coordinator-migrate` command must first bring the public
catalog to version 4 and install `rust_coord.schema_versions` version 2.
`Database::connect` only checks that compatible pair. Regenerating SQLx
metadata likewise requires a disposable database migrated to that exact
catalog pair; CI migrates its isolated PostgreSQL service before checking the
metadata.

The durable schema is additive. Concrete SQLx services under `server/src/db`,
`ledger`, `recovery`, and `projection` own durable jobs, exact reservation
provenance, atomic settlement, Stripe operations, bounded recovery leases,
outbox work, fee checkpoints, and one-statement catalog snapshots. They are
not connected to HTTP/request execution yet. Production migration ownership
remains with the external Go command; integration tests apply the mirror under
`migrations/` only to isolated temporary PostgreSQL databases.

Request execution, terminal ingestion, Stripe webhooks, and supervised
recovery workers consume these services in the durable lifecycle layer.

Every startup takes the same dedicated PostgreSQL primary advisory lock as the
Go coordinator, including disabled legacy mode. It then takes the exclusive
`darkbloom-coordinator-mutation` handoff lock before checking activation or
advancing the public `coordinator_ownership` epoch. Serving-pool checkouts hold
the shared form of that lock and reverify the primary lock plus the expected
epoch (or absent legacy marker), so an old process cannot write across a
handoff. The primary connection is monitored continuously; loss also removes
readiness and triggers runtime shutdown. Once either coordinator has persisted
`coordinator_ownership_activated`, disabled startup is refused.
Durable financial mutations are single READ COMMITTED data-modifying CTE
statements. Each statement verifies the active owner id/epoch in its own
snapshot, uses immutable operation key/digest replay records, exact status and
version CAS, checked `BIGINT` bounds, and deterministic account lock order.
Only SQLSTATE `40001` and `40P01` are retried with bounded jitter; uncertain
transport outcomes are reconciled by operation key and conflicting digests
fail closed. Other SQL mutators continue to enter through
`Database::begin_owned`.
Real PostgreSQL integration tests use the dedicated
`DARKBLOOM_TEST_DATABASE_URL`; they refuse to fall back to a runtime database
URL.
