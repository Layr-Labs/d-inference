# PostgreSQL migrations

Files named `NNNNNN_name.sql` are embedded, ordered, and checksum-tracked in
`schema_migration_versions`. Applied files are immutable; schema changes require
a new contiguous version.

Migrations run in a transaction by default. Version 1 is the one exception: it
uses per-statement autocommit to preserve the legacy lock lifetime and declares
`darkbloom:bootstrap=true` because its first statement creates the metadata
table. Its statements must therefore be idempotent so a partial failure can be
retried before version 1 is recorded.

A migration containing PostgreSQL concurrent-index statements must declare:

```sql
-- darkbloom:transaction=false
-- darkbloom:concurrent-index=index_name
```

The runner executes each nontransactional statement independently. It skips the
provider-earnings index migration only when the existing index exactly matches
the required unique table/key/predicate definition; invalid or wrong same-name
indexes are dropped and rebuilt concurrently.

Migration SQL must not use `EXCEPTION WHEN OTHERS` to swallow failures. Lock,
permission, type, and data errors must stop the deployment.

An empty schema bootstraps without an extra flag. A nonempty unversioned schema
is never modified unless it matches the complete Darkbloom legacy table/key
fingerprint and the operator passes `-adopt-legacy`. The flag is a one-time
transition authorization and must be removed after adoption. Unrelated or
incompatible schemas are refused even with the flag.

Before a migration version is recorded, and again before the coordinator serves,
the code validates critical table, column type, nullability, key, and canonical
provider-earnings index shapes.

Version 3 creates only the additive `rust_coord.schema_versions` compatibility
catalog. Its version 1 row declares compatibility with public schema version 3.
It intentionally does not create Rust-owned inference jobs or workers.

Version 4 creates the additive durable Rust schema and records
`rust_coord.schema_versions` version 2, compatible only with public version 4.
It adds jobs, attempts, signed terminal receipts, idempotent financial
operations, external inbox/outbox work, authoritative platform/referral fee
allocations, projection checkpoints, and hard-untrust epochs. It does not alter
legacy Go tables.

`000004_rust_durable_schema.sql` is the one canonical durable-schema artifact.
`coordinator-rs/migrations/000002_rust_durable_schema.sql` must remain
byte-for-byte identical so Go's external migrator and Rust's SQLx integration
fixtures exercise exactly the same DDL. `TestRustDurableMigrationMirrorIsByteIdenticalAndTamperEvident`
enforces that invariant. Neither serving binary applies migrations at startup.

Run migrations before serving:

```bash
go run ./coordinator/cmd/migrate
```

Other SQL files in this directory are manual operator tools and are not embedded
or applied automatically.
