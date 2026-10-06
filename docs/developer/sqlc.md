# Write store queries with sqlc

> Last updated: 2026-10-06

How to add a Postgres query to the coordinator store with sqlc, how to move a
hand-written store domain to sqlc (the api_keys domain is the worked
example), and how to check the generated code. Why the store uses sqlc and
how the pieces fit is in
[schema lifecycle](../architecture/schema-lifecycle.md#generated-queries-sqlc);
the Postgres-to-Go types are in [sqlc type mapping](../reference/sqlc-type-mapping.md).

## Prerequisites

- Go with the default `GOTOOLCHAIN=auto`, or Go 1.26. `make sqlc-generate`
  runs `go run github.com/sqlc-dev/sqlc/cmd/sqlc@v1.31.1`, and sqlc v1.31.1
  needs Go 1.26 (`Makefile`, `SQLC`).
- For `make sqlc-check`, a throwaway Postgres server and `DATABASE_URL`, as in
  [Add a database migration](database-migrations.md#prerequisites).
- A `coordinator/store/postgres/schema/schema.sql` that includes the tables and columns
  your query reads. If your change also adds a migration, regenerate that file
  first ([step 5 of the migration how-to](database-migrations.md#steps)).

## Steps: add a query

1. Add the query to the domain's file in `coordinator/store/postgres/queries/`, for
   example `coordinator/store/postgres/queries/api_keys.sql`. Start it with a name and
   a command:

   ```sql
   -- name: GetAPIKeyByID :one
   SELECT * FROM api_keys WHERE id = $1 AND owner_account_id = $2;
   ```

   Follow the [conventions](#conventions) below for the name, the command and
   the parameters.

2. Generate the Go code:

   ```bash
   make sqlc-generate
   ```

   sqlc writes `coordinator/store/postgres/storedb/<file>.sql.go` and updates
   `coordinator/store/postgres/storedb/models.go`. A query with one parameter takes it
   as an argument; two or more become a `<Name>Params` struct
   (`storedb.GetAPIKeyByIDParams`). Do not edit generated files.

3. Call the query from the store method, through `s.queries()` or, inside a
   transaction, `storedb.New(tx)`:

   ```go
   row, err := s.queries().GetAPIKeyByID(ctx, storedb.GetAPIKeyByIDParams{ID: id, OwnerAccountID: accountID})
   if err != nil {
       return nil, err
   }
   return apiKeyFromRow(row), nil
   ```

   Convert the generated row to the public store type in one function per
   domain (`apiKeyFromRow` in `coordinator/store/postgres/apikey.go`). Keep
   storage encodings, such as the JSON text in `api_keys.allowed_models`, in
   that function and its inverse (`insertAPIKeyParams`).

4. If the method is new on the `Store` interface, implement it in
   `MemoryStore` (`coordinator/store/memory/`) too and cover both backends in
   one test, as `TestAPIKeyLifecycleOnEveryBackend`
   (`coordinator/tests/store/contracts/apikey_backends_test.go`) does.

## Steps: convert a hand-written domain

The api_keys domain in `coordinator/store/postgres/apikey.go` moved from
hand-written SQL to sqlc without a change to the `Store` interface, `MemoryStore` or `CachedStore`. Repeat these steps for another
domain.

1. List every SQL statement of the domain and the helpers it uses. For
   api_keys the statements became twelve named queries; the helpers were the
   `apiKeyColumns` select list and `scanAPIKeyRow`.
2. Write each statement as a named query in
   `coordinator/store/postgres/queries/<table>.sql`. Keep its `WHERE`, `ORDER BY`,
   `FOR UPDATE` and `ON CONFLICT` clauses exactly; `GetAPIKeyByIDForUpdate`
   keeps the row lock that `RotateAPIKey` needs.
3. Run `make sqlc-generate`.
4. Keep the domain's methods in its file in `coordinator/store/postgres/`
   (`apikey.go`) and make them call the generated queries. Keep transactions in the store method: `RotateAPIKey`
   begins the transaction on the pool and runs its read, insert and delete
   through `storedb.New(tx)`.
5. Write one row-to-type function and one type-to-params function. Two
   generated structs with the same fields convert directly:
   `storedb.InsertAPIKeyIfAbsentParams(insertAPIKeyParams(rec))` in `SeedKey`.
6. Delete the old SQL strings and scan helpers.
7. Run the domain's existing tests unchanged, add a test that runs the same
   lifecycle on both backends, and run `make sqlc-check`.

## Conventions

| Topic | Rule | Example |
|---|---|---|
| File | One file per table or domain under `coordinator/store/postgres/queries/` | `coordinator/store/postgres/queries/api_keys.sql` |
| Query name | Verb, noun, qualifier, in PascalCase; spell initialisms as `API`, `ID` | `GetAPIKeyByHash`, `ListAPIKeysByOwner`, `GetAPIKeyByIDForUpdate`, `InsertAPIKeyIfAbsent`, `DeactivateAPIKeyByHash` |
| Command | `:one` for one row (no row returns `pgx.ErrNoRows`); `:many` for a slice; `:exec` when only the error matters; `:execrows` when the caller needs the affected-row count | `UpdateAPIKey :execrows` lets `UpdateAPIKey` return `key not found` on 0 rows |
| Positional parameter | `$n`, each used once and compared with a column; sqlc names it after the column | `$1` in `GetActiveKeyAccount` becomes `keyHash string` |
| Named parameter | `sqlc.arg('name')` when a positional name would be unclear | `sqlc.arg('key_id')` in `KeySpendSince` |
| Nullable parameter | `sqlc.narg('name')` plus a cast; it becomes a pointer | `sqlc.narg('since')::timestamptz` becomes `Since *time.Time` |
| Reused parameter | Name it; use the same `sqlc.arg`/`sqlc.narg` each time | `since` appears twice in `KeySpendSince` and is one field |
| Expression result | Cast it, or sqlc types it `interface{}` | `COALESCE(SUM(cost_micro_usd), 0)::bigint AS total_micro_usd` returns `int64` |
| Struct names | Generated from the table name, singular, with sqlc's default casing; there are no renames in `sqlc.yaml` | table `api_keys` becomes `storedb.ApiKey`; `limit_micro_usd` becomes `LimitMicroUsd` |
| `SELECT *` | Allowed; sqlc expands it to the column list at generation time | `GetAPIKeyByHash` |
| Lease result | Lock the row before checking current-time expiry; require the claim generation and an affected row before dependent writes | `LockErasureOutbox` then `SaveErasureOutboxResult :execrows` in `coordinator/store/postgres/queries/erasure.sql`; `erasure_outbox.go` inserts a manual split only after the fenced update succeeds |

## Verify

```bash
make sqlc-check
```

It needs `DATABASE_URL`. It runs `TestMigrationsBuildCheckedInSchema` (fails
when `schema.sql` is stale), then `sqlc diff` (prints a unified diff and fails
when `coordinator/store/postgres/storedb` is stale). CI runs it in the Coordinator
Tests job. Then run the store tests of the domain on Postgres:

```bash
go test ./coordinator/tests/store/... -count=1 -run 'APIKey'
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `make sqlc-check` prints `--- a/storedb/...` and fails | The generated code is stale | `make sqlc-generate`, then commit `coordinator/store/postgres/storedb`. |
| `sqlc-check: set DATABASE_URL to a disposable Postgres server` | `DATABASE_URL` is unset | Point it at a throwaway server. |
| `TestMigrationsBuildCheckedInSchema` fails inside `make sqlc-check` | `schema.sql` is stale | Regenerate it ([migration how-to step 5](database-migrations.md#steps)), then `make sqlc-generate`. |
| sqlc reports `column "..." does not exist` | `schema.sql` lacks the column (stale), or `sqlc.yaml` was pointed at `coordinator/store/postgres/schema/migrations/`, where the baseline adds columns inside `DO` blocks that sqlc cannot see | Regenerate `schema.sql`; keep `schema: schema/schema.sql`. |
| A result or parameter is `interface{}` | An expression or `sqlc.narg` without a cast, for example `COALESCE(SUM(x), 0)` | Cast it: `::bigint`, `::timestamptz`. |
| A parameter is `pgtype.Timestamp`, not `*time.Time` | The cast is `::timestamp` (without time zone); the overrides cover only `timestamptz` | Cast to `::timestamptz`. |
| A parameter is named `dollar_1` | A positional parameter that sqlc cannot tie to a column | Use `sqlc.arg('name')`. |
| A reused `$1` has the name of only its first column | sqlc gives a positional parameter one name | Use one `sqlc.arg('name')` for both places, or two parameters. |
| `go: downloading go1.26...` fails | `GOTOOLCHAIN=local` with an older Go | Unset `GOTOOLCHAIN` or install Go 1.26. |

## Related

- [Schema lifecycle](../architecture/schema-lifecycle.md#generated-queries-sqlc) — where sqlc sits between the schema and the store
- [sqlc type mapping](../reference/sqlc-type-mapping.md) — Postgres type to Go type, and the store conversion
- [Add a database migration](database-migrations.md) — change the schema that sqlc reads
- [Build](build.md#make-targets) — `sqlc-generate` and `sqlc-check`
