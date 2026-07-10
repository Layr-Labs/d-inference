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
EIGENINFERENCE_RUST_BIND_ADDRESS              default 0.0.0.0:8081
EIGENINFERENCE_RUST_DATABASE_MAX_CONNECTIONS default 32
EIGENINFERENCE_RUST_SHUTDOWN_GRACE_SECONDS   default 30
```

Application startup never applies DDL. Checked SQL metadata is committed under
`.sqlx/`; schema changes will be applied by a separate migration command.
