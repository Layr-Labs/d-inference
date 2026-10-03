# Add a database migration

> Last updated: 2026-10-03

How to change the coordinator's Postgres schema. Every schema change is a new
numbered goose migration under `coordinator/store/schema/migrations/`. Do not
put DDL in Go strings, and do not edit a migration that has merged. The
mechanism is explained in
[storage](../architecture/storage.md#migrations-are-numbered-goose-versions).

## Prerequisites

- Docker, with a throwaway Postgres 17 server:
  `docker run -d --name dinf-store-pg -e POSTGRES_PASSWORD=pg -p 55432:5432 postgres:17`.
- `DATABASE_URL` pointing at that server, as for the other Postgres tests
  ([test](test.md)).

## Steps

1. Pick the next version: one more than the highest file number in
   `coordinator/store/schema/migrations/` or the highest version in
   `goMigrations` (`coordinator/store/postgres_migrations.go`). If a branch that
   merges before yours takes the same number, renumber yours.
2. In `coordinator/store/schema/migrations/`, create `NNNNN_short_name.sql`,
   where `NNNNN` is the version with leading zeros:

   ```sql
   -- +goose Up
   ALTER TABLE providers ADD COLUMN example TEXT;
   ```

   Goose runs the file in one transaction. Put `-- +goose NO TRANSACTION` at
   the top for `CREATE INDEX CONCURRENTLY` or `DROP INDEX CONCURRENTLY`, and
   use one such statement per file. Wrap a statement that contains `;` (a
   `DO` block or a function body) in `-- +goose StatementBegin` and
   `-- +goose StatementEnd`.
3. Keep each statement short and lock-safe. The migration session sets
   `lock_timeout` to 3 s and `statement_timeout` to 10 min. Add a column
   without a volatile default; add a constraint `NOT VALID`, then `VALIDATE`
   it; build indexes on large tables `CONCURRENTLY`. Do not swallow errors in a
   `DO ... EXCEPTION WHEN others` block: a failure must stop the boot.
4. Regenerate the schema file from a database built by the migrations:

   ```bash
   docker exec dinf-store-pg createdb -U postgres schema_dump
   EIGENINFERENCE_DATABASE_URL='postgres://postgres:pg@127.0.0.1:55432/schema_dump?sslmode=disable' \
     go run ./coordinator/cmd/coordinator --migrate-only
   docker exec dinf-store-pg pg_dump -U postgres --schema-only --no-owner --no-privileges \
     --exclude-table=goose_db_version schema_dump \
     | grep -v '^\\restrict \|^\\unrestrict \|^-- Dumped from database version\|^-- Dumped by pg_dump version' \
     > coordinator/store/schema/schema.sql
   ```

   Use a `pg_dump` of the same major version as production (17).
5. Update `MemoryStore` and the docs that describe the changed tables
   ([storage](../architecture/storage.md)).

## Verify

```bash
DATABASE_URL='postgres://postgres:pg@127.0.0.1:55432/postgres?sslmode=disable' \
  go test ./coordinator/store -run 'TestMigrations|TestConcurrentMigrations' -count=1
```

`TestMigrationsBuildCheckedInSchema` fails when `schema.sql` does not match
what the migrations build.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `found duplicate migration version` | Two files share a number; renumber yours. |
| `missing (out-of-order) migration` on a shared database | A higher version was applied first; renumber the unapplied file above it. |
| A statement fails with `canceling statement due to lock timeout` three times | A long query holds the table; rerun when it ends, or make the statement take a weaker lock. |

## Related

- [Storage](../architecture/storage.md) — what the migrations build and why
- [Test](test.md) — running the Postgres tests
