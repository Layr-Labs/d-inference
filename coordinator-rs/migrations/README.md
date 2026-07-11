# Rust schema migration mirror

The Go `coordinator-migrate` command is the only production migration runner.
The durable SQL in this directory exists for SQLx integration tests and schema
inspection; the canonical/mirror rule is documented in
`coordinator/store/migrations/README.md`.

Application startup performs compatibility checks only and never executes DDL.
