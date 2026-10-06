# Add a database migration

> Last updated: 2026-10-06

How to change the coordinator's Postgres schema: choose the migration kind,
write it as a numbered goose version, regenerate the checked-in schema, and
test it. Every schema change is a new version. Put ordinary DDL in SQL files;
use Go migrations for the checks and concurrent indexes described below.
Do not edit a migration that has merged. Why the rules exist is in
[schema lifecycle](../architecture/schema-lifecycle.md); applying a migration
in production is the [schema migration runbook](../operations/schema-migration.md).

## Prerequisites

- Go as pinned in `go.mod`, and Docker.
- A throwaway Postgres 17 server, the major version that production runs:

  ```bash
  docker run -d --name dinf-store-pg -e POSTGRES_PASSWORD=pg -p 55432:5432 postgres:17
  ```

- `DATABASE_URL` for the store tests ([test](test.md)):

  ```bash
  export DATABASE_URL='postgres://postgres:pg@127.0.0.1:55432/postgres?sslmode=disable'
  ```

## Steps

1. **Choose the kind.** Use the first row that fits.

   | Change | Kind | Example in the repo |
   |---|---|---|
   | Add a table, a nullable column, or a column with a constant default; drop a constraint; add a constraint `NOT VALID` | SQL file, one transaction (the default) | `coordinator/store/postgres/schema/migrations/00019_users_privy_drop_unique_constraint.sql` |
   | Several `ALTER TABLE`s on busy tables that must not hold their locks together | SQL file with `-- +goose NO TRANSACTION` | `coordinator/store/postgres/schema/migrations/00017_soft_delete_columns.sql` |
   | `VALIDATE CONSTRAINT` after a `NOT VALID` add | SQL file with `-- +goose NO TRANSACTION` | `coordinator/store/postgres/schema/migrations/00021_referrals_referrer_code_cascade.sql` |
   | `DROP INDEX CONCURRENTLY` | SQL file with `-- +goose NO TRANSACTION` and `SET lock_timeout = '1min'` | `coordinator/store/postgres/schema/migrations/00020_users_privy_drop_old_index.sql` |
   | Create an index on a table that has rows in production | Go migration in `indexMigrations` | Versions 10 to 16 and 18 (`coordinator/store/postgres/migration_indexes.go`) |
   | A step that must read data first, check a precondition, or check its own result | Go migration | `checkRetiredBackfills` (version 2) |
   | Rename or drop a column, or tighten a constraint | Compatible release phases; see [expand and contract](#change-a-column-while-preserving-rollback-compatibility) | — |
   | Fix rows that a writer keeps producing | Not a migration: fix the writer | — |
   | A cleanup that needs a long lock | Manual SQL under `coordinator/store/postgres/migrations/`, applied under an approved operation | `coordinator/store/postgres/migrations/dedupe_provider_earnings.sql` |

2. **Pick the version.** Use one more than the highest version in
   `coordinator/store/postgres/schema/migrations/`, in `goMigrations`
   (`coordinator/store/postgres/migrations.go`) and in `indexMigrations`
   (`coordinator/store/postgres/migration_indexes.go`). SQL files and Go
   migrations share one sequence. If a branch that merges before yours takes the same
   number, renumber yours before it merges.

3. **Write the migration.** Follow the part for your kind.

   *SQL file, one transaction.* Create
   `coordinator/store/postgres/schema/migrations/<NNNNN>_<short_name>.sql`, where
   `<NNNNN>` is the version with leading zeros:

   ```sql
   -- +goose Up
   ALTER TABLE providers ADD COLUMN IF NOT EXISTS example TEXT;
   ```

   Goose runs every statement and the `goose_db_version` insert in one
   transaction. A failure rolls all of it back.

   *SQL file, no transaction.* Put `-- +goose NO TRANSACTION` above
   `-- +goose Up`. Each statement commits on its own, and the version is
   recorded after the last one. A failure in the middle leaves the earlier
   statements applied, and the next boot runs the whole file again, so every
   statement must be safe to run twice (`IF NOT EXISTS`, `IF EXISTS`, or
   drop-then-add, as in version 21). Wrap a statement that contains `;`, such
   as a `DO` block, in `-- +goose StatementBegin` and `-- +goose StatementEnd`,
   as the baseline does. A `DROP INDEX CONCURRENTLY` waits for older snapshots
   like a concurrent build; set `lock_timeout = '1min'` before it and reset it
   after, as version 20 does.

   *Go migration.* Write a method on `PostgresStore` that takes a
   `context.Context` and returns an error, and add it to `goMigrations`:

   ```go
   step(22, s.checkExampleRows),
   ```

   It runs on the store pool with no session timeouts unless the database URL
   sets them. It runs once; keep it safe to run again after a failure, because
   a failed run is not recorded.

   *Concurrent index.* Do not put `CREATE INDEX CONCURRENTLY` in an SQL file;
   `TestSQLMigrationsDoNotBuildIndexesConcurrently` fails. Add the index to
   `indexMigrations` (`coordinator/store/postgres/migration_indexes.go`)
   instead:

   ```go
   index(22, "idx_example_account", `CREATE INDEX CONCURRENTLY idx_example_account ON example (account_id)`),
   ```

   `buildConcurrentIndex` returns at once when a valid index exists, drops an
   invalid leftover of an interrupted attempt, builds the index on its own
   connection with a 1 min `lock_timeout` (the build waits for every older
   snapshot), and fails unless the result is valid. The version is recorded
   only after it succeeds.

4. **Keep it lock-safe.** SQL migrations run with `lock_timeout` 3 s and
   `statement_timeout` 10 min ([locks and timeouts](../architecture/schema-lifecycle.md#locks-and-timeouts)).
   - Add a column without a volatile default; a nullable column with no
     default changes only the catalog.
   - Add a foreign key or check `NOT VALID`, then `VALIDATE` it in a separate
     statement of a `NO TRANSACTION` file.
   - Do not catch errors in a `DO ... EXCEPTION WHEN others` block. A failure
     must stop the boot.
   - Do not drop or rename a column, or add `NOT NULL` or a constraint to a
     table the baseline creates, in one step; see
     [destructive changes](#destructive-changes-and-the-pre-goose-fallback).

5. **Apply it to an empty database and regenerate the schema file.**

   ```bash
   docker exec dinf-store-pg createdb -U postgres schema_dump
   EIGENINFERENCE_DATABASE_URL='postgres://postgres:pg@127.0.0.1:55432/schema_dump?sslmode=disable' \
     go run ./coordinator/cmd/coordinator --migrate-only
   docker exec dinf-store-pg pg_dump -U postgres --schema-only --no-owner --no-privileges \
     --exclude-table=goose_db_version schema_dump \
     | grep -v '^\\restrict \|^\\unrestrict \|^-- Dumped from database version\|^-- Dumped by pg_dump version' \
     > coordinator/store/postgres/schema/schema.sql
   docker exec dinf-store-pg dropdb -U postgres schema_dump
   ```

   The `--migrate-only` run logs one `postgres migration` line per version
   with `"result":"applied"`, then `coordinator migrations complete`. Use the
   `pg_dump` inside the container, so that its major version matches
   production (17). Review `git diff coordinator/store/postgres/schema/schema.sql`: it
   must show only your change. Keep the frozen legacy fixture under
   `coordinator/tests/store/postgres/testdata/legacy_schema.sql` unchanged;
   the upgrade test compares it to the newly generated current schema.

6. **Regenerate the sqlc code** if a query in `coordinator/store/postgres/queries/`
   reads the changed table: `make sqlc-generate`
   ([Write store queries with sqlc](sqlc.md)).

7. **Update the rest of the store.** Make `MemoryStore`
   (`coordinator/store/memory/`) match, and update the docs that describe
   the changed tables ([storage](../architecture/storage.md)).

## Verify

```bash
go test ./coordinator/tests/store/postgres -count=1 \
  -run 'TestMigrations|TestConcurrent|TestMigrateRetries|TestSQLMigrations|TestIndexMigration'
```

| Test | Fails when |
|---|---|
| `TestMigrationsBuildCheckedInSchema` | `schema.sql` differs from what the migrations build |
| `TestMigrationsUpgradeLegacyDatabase` | A frozen pre-goose database does not upgrade to the current schema, or loses preserved marker/counter rows |
| `TestMigrationsBlockedLegacyColumnRemainsPending` | A blocked baseline is recorded as successful, or the missing column is not restored on retry |
| `TestConcurrentMigrationsApplyOnce` | Two runs at once apply a version twice, or a run changes the schema while another session holds the goose advisory lock |
| `TestSQLMigrationsDoNotBuildIndexesConcurrently` | An SQL file contains `CREATE [UNIQUE] INDEX CONCURRENTLY` |
| `TestConcurrentIndexMigrationWaitsForOlderSnapshot`, `TestIndexMigrationRebuildsInvalidLeftover`, `TestIndexMigrationFailureIsNotRecorded` | An index migration gives up behind an older snapshot, keeps an invalid leftover, or records a failed build |

Do not regenerate
`coordinator/tests/store/postgres/testdata/legacy_schema.sql`; it is the
schema of the last pre-goose boot.

Then run the store tests for the tables you changed, on both backends. CI
also runs `make sqlc-check`, which runs `TestMigrationsBuildCheckedInSchema`
and fails when the generated sqlc code is stale:

```bash
make sqlc-check
```

## Change a column while preserving rollback compatibility

A rollback starts an older image against the already-migrated schema
([invariants](../architecture/schema-lifecycle.md#invariants)). Both the active
image and every permitted fallback must read current values and accept each
other's writes. `--migrate-only` can also run while the previous image serves.

For a column replacement, keep the old column authoritative while any writer
updates only that column. Reading `COALESCE(new_col, old_col)` during this
phase can return a stale non-null value after a rollback writer updates only
`old_col`. Use these phases when both representations can preserve the values
accepted by the active image and its fallback:

```mermaid
flowchart TD
  classDef rel fill:#dbeafe,stroke:#1d4ed8,color:#0b1220
  classDef gate fill:#fef3c7,stroke:#b45309,color:#1f1300
  classDef fb fill:#f1f5f9,stroke:#475569,color:#0f172a
  N["N: expand<br/>read old_col<br/>write both atomically"]:::rel
  G["Retire every N-1 writer and fallback<br/>reconcile new_col from current old_col"]:::gate
  N1["N+1: switch reads<br/>read new_col<br/>keep writing both atomically"]:::rel
  N2["N+2: retire old access<br/>read and write new_col only<br/>keep old_col in schema"]:::rel
  N3["N+3: contract<br/>drop old_col"]:::rel
  F0["Fallback N-1<br/>reads and writes current old_col"]:::fb
  F1["Fallback N<br/>reads current old_col<br/>writes both"]:::fb
  F2["Fallback N+1<br/>reads current new_col<br/>writes both"]:::fb
  F3["Fallback N+2<br/>never accesses old_col"]:::fb
  N --> G --> N1 --> N2 --> N3
  N -. "rollback" .-> F0
  N1 -. "rollback" .-> F1
  N2 -. "rollback" .-> F2
  N3 -. "rollback" .-> F3
```

Legend: blue = release, amber = required transition, grey = permitted fallback.

1. **Release N, expand.** Add `new_col` with an additive migration. Read
   `old_col` and update both representations in the same transaction on every
   write path, including inserts and maintenance commands. The N-1 fallback
   can keep updating only `old_col`; N continues reading the authoritative
   value after a rollback and re-upgrade.
2. **Retire old-only writers and reconcile.** Once N is deployed, remove N-1
   from the permitted fallback set and retire every old-only writer before
   switching reads. Reconcile `new_col` from authoritative `old_col` in small
   batches, including rows whose `new_col` is already non-null. Lock each row
   and derive the new value from its current old value in the same transaction
   so reconciliation cannot overwrite a concurrent dual write with stale data.
   Verify parity before proceeding. Perform production backfills under the
   [schema migration runbook](../operations/schema-migration.md), with approval
   for that specific mutation.
3. **Release N+1, switch reads.** Read `new_col` and keep updating both columns
   atomically. N is the permitted fallback: its reads of `old_col` remain current.
   Keep values compatible with both representations while such a fallback is
   permitted.
4. **Release N+2, retire old access.** After N+1 is deployed and N is retired
   from the fallback set, read and write only `new_col`. Keep `old_col` in the
   schema for N+1, whose reads already use `new_col` and whose writes still
   mention both columns. Before omitting old-column writes, ensure inserts and
   updates still satisfy the old column's defaults, nullability and constraints;
   stage any compatible schema relaxation separately.
5. **Release N+3, contract.** After N+2 is deployed and N+1 is retired from the
   fallback set, drop `old_col`. The permitted N+2 fallback never accesses it.
   Check every remaining reader, writer and database dependency before removal.
   Tightening a constraint similarly requires all active and fallback writers
   to satisfy it before it is enforced; use `NOT VALID` and `VALIDATE` where
   PostgreSQL supports them.

## Add soft delete to a table

1. Add the column in a new SQL migration. It is nullable with no default, so
   it changes only the catalog:

   ```sql
   -- +goose Up
   ALTER TABLE example ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
   ```

   For several busy tables, use one `NO TRANSACTION` file, as version 17 does.
2. If a unique key must let a new live row reuse the value of an erased one,
   replace it with a partial unique index, in three versions: build
   `CREATE UNIQUE INDEX CONCURRENTLY ... WHERE deleted_at IS NULL` in
   `indexMigrations` (version 18), drop the old constraint (version 19), then
   drop the old index with `DROP INDEX CONCURRENTLY` (version 20). Read the
   [pre-goose fallback rule](#destructive-changes-and-the-pre-goose-fallback)
   first.
3. Add `DeletedAt *time.Time` with the tag `json:"-"` to the store type in
   its `coordinator/store/*_types.go` file.
4. Add `AND deleted_at IS NULL` to every read that returns a live row: the
   hand-written SQL in `coordinator/store/postgres/` and the queries in
   `coordinator/store/postgres/queries/`. Find them with:

   ```bash
   grep -n -E "(FROM|JOIN)\s+example\b" coordinator/store/postgres/*.go coordinator/store/postgres/queries/*.sql
   ```

   Make each `MemoryStore` read (`coordinator/store/memory/`) skip a record
   whose `DeletedAt` is not `nil`.
   Leave inserts, hard deletes and maintenance writes unfiltered. Filter an
   update only when it must not change a soft-deleted row, as `UpdateAPIKey`
   does.
5. If `CachedStore` (`coordinator/store/cached.go`) caches the table, the
   writer that sets `deleted_at` must invalidate the cache.
6. Regenerate `schema.sql` (step 5 above) and run `make sqlc-generate`.
7. Add the table to `softDelete` in
   `coordinator/tests/store/postgres/soft_delete_reads_test.go` and a test
   that checks every filtered read.
8. Add the table and its reads to the [soft-delete reference](../reference/soft-delete.md).

## Destructive changes and the pre-goose fallback

A coordinator image built before goose ignores `goose_db_version` and replays
its own boot DDL. `ADD COLUMN IF NOT EXISTS` brings a dropped column back, and
its `DROP NOT NULL` on `fleet_snapshots.free_for_load_gb` undoes a later
`SET NOT NULL`. Its `CREATE UNIQUE INDEX IF NOT EXISTS idx_users_privy`
rebuilds the index that version 20 drops, and fails once a soft-deleted and a
live user share a Privy ID, so the image cannot boot. Ship no contract step on
a table the baseline creates while a pre-goose image can be started as the
fallback. The
[runbook](../operations/schema-migration.md#rollback) states which images are
safe.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `found duplicate migration version` | Two sources share a number; renumber yours. |
| `detected 1 missing (out-of-order) migration lower than database version` on a shared database | A higher version was applied first; renumber the unapplied one above it. |
| `canceling statement due to lock timeout` three times | Another session holds the table. Stop it, or make the statement take a weaker lock. |
| `TestMigrationsBuildCheckedInSchema` fails | `schema.sql` is stale. Repeat step 5 on an empty database. |
| The `schema.sql` diff shows objects you did not add | The dump came from a database that held other objects, or from a `pg_dump` older than 17. Repeat step 5 with a new database. |
| `index ... is invalid; repair the interrupted concurrent index build before retrying` locally | Versions 3, 5 and 9 only: drop the index (`DROP INDEX CONCURRENTLY <name>`) and run again. An `indexMigrations` version drops and rebuilds an invalid leftover itself. |

## Related

- [Schema lifecycle](../architecture/schema-lifecycle.md) — how goose runs, locks, timeouts, failure modes
- [Apply schema migrations in production](../operations/schema-migration.md) — backup, checks, rollback
- [Write store queries with sqlc](sqlc.md) — queries generated from `schema.sql`
- [Soft delete](../reference/soft-delete.md) — the tables, reads and indexes
- [Storage](../architecture/storage.md) — what the tables hold
- [Test](test.md) — running the Postgres tests
