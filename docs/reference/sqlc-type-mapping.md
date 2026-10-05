# sqlc type mapping

> Last updated: 2026-10-04

Reference for the Go types that sqlc v1.31.1 generates in
`coordinator/store/postgres/storedb/` from `coordinator/store/postgres/schema/schema.sql`
under `coordinator/store/postgres/sqlc.yaml`, and how the store converts each one to
its public type. How to write a query is
[Write store queries with sqlc](../developer/sqlc.md).

## Configuration flags

Each flag in `coordinator/store/postgres/sqlc.yaml` that changes a Go type.

| Setting | Value | Effect on the generated types |
|---|---|---|
| `sql_package` | `pgx/v5` | Queries take a `storedb.DBTX` (`Exec`, `Query`, `QueryRow` of pgx v5; `coordinator/store/postgres/storedb/db.go`). Without the overrides below, `timestamptz` and `timestamp` come from `pgtype`. |
| `emit_pointers_for_null_types` | `true` | A nullable column or parameter becomes a pointer (`*int64`), not a `pgtype` wrapper (`pgtype.Int8`). |
| `omit_unused_structs` | `true` | `coordinator/store/postgres/storedb/models.go` holds only the table structs that a query returns (`ApiKey`). |
| `overrides`: `db_type: pg_catalog.timestamptz` | `go_type: time.Time`; with `nullable: true`, `*time.Time` | Applies to schema columns (`pg_dump` writes them as `timestamp with time zone`). Without it a column is `pgtype.Timestamptz`. |
| `overrides`: `db_type: timestamptz` | `go_type: time.Time`; with `nullable: true`, `*time.Time` | Applies to a `::timestamptz` cast in a query, as in `KeySpendSince`. Without it `Since` is `pgtype.Timestamptz`. |

## Mappings in the generated code

Every Postgres type that a checked-in query reads or writes. Fields are in
`storedb.ApiKey` (`coordinator/store/postgres/storedb/models.go`) and the
`*Params` structs (`coordinator/store/postgres/storedb/api_keys.sql.go`). Conversions
are in `coordinator/store/postgres/apikey.go`.

| Postgres type | Null | Go type in `storedb` | Caused by | Column or expression → field | Store conversion to the public type |
|---|---|---|---|---|---|
| `text` | `NOT NULL` | `string` | default | `api_keys.key_hash` → `KeyHash`; `owner_account_id` → `OwnerAccountID`; `id` → `ID`; `name` → `Name` | Copied to the `APIKey` field of the same name (`apiKeyFromRow`) |
| `text` | `NOT NULL` | `string` | default | `api_keys.raw_prefix` → `RawPrefix` | Copied to `APIKey.Label` |
| `text` | `NOT NULL` | `string` | default | `api_keys.limit_reset` → `LimitReset` | `NormalizeResetWindow` on read and write |
| `text` (JSON array) | `NOT NULL` | `string` | default | `api_keys.allowed_models` → `AllowedModels` | `decodeModelList` to `[]string` (`""`, `[]` or invalid JSON → `nil`); `encodeModelList` back (empty → `""`) |
| `boolean` | `NOT NULL` | `bool` | default | `api_keys.active` → `Active` | Inverted: `APIKey.Disabled = !row.Active`; params set `Active: !rec.Disabled` |
| `boolean` | `NOT NULL` | `bool` | default | `api_keys.self_route_only` → `SelfRouteOnly` | Copied |
| `bigint` | nullable | `*int64` | `emit_pointers_for_null_types` | `api_keys.limit_micro_usd`, `rpm_limit`, `itpm_limit`, `otpm_limit` → `LimitMicroUsd`, `RpmLimit`, `ItpmLimit`, `OtpmLimit` | Copied to `LimitMicroUSD`, `RPMLimit`, `ITPMLimit`, `OTPMLimit`; `nil` means unlimited or inherited |
| `bigint` (expression) | never null | `int64` | the `::bigint` cast | `COALESCE(SUM(cost_micro_usd), 0)::bigint` in `KeySpendSince` → result | Returned as is; an error returns `0` (`PostgresStore.KeySpendSince`) |
| `timestamptz` | `NOT NULL` | `time.Time` | override `pg_catalog.timestamptz` | `api_keys.created_at` → `CreatedAt` | Copied; writers pass `time.Now().UTC()` |
| `timestamptz` | nullable | `*time.Time` | override `pg_catalog.timestamptz`, `nullable: true` | `api_keys.expires_at`, `last_used_at` → `ExpiresAt`, `LastUsedAt` | Copied; `TouchAPIKey` passes `&lastUsed` (UTC) |
| `timestamptz` | nullable | `*time.Time` | override `pg_catalog.timestamptz`, `nullable: true` | `api_keys.deleted_at` → `DeletedAt` | Not copied by `apiKeyFromRow`: every query that returns `ApiKey` filters `deleted_at IS NULL`, so the value is always `nil` ([soft delete](soft-delete.md)) |
| `timestamptz` (cast parameter) | nullable | `*time.Time` | override `timestamptz`, `nullable: true`; `sqlc.narg` | `sqlc.narg('since')::timestamptz` → `KeySpendSinceParams.Since` | A zero `time.Time` becomes `nil`, which matches every row |
| `text` (parameter) | — | `string` | default | `sqlc.arg('key_id')` compared with `usage.key_id` → `KeySpendSinceParams.KeyID` | Passed as is |

## Query commands

| Annotation | Generated signature | Store use |
|---|---|---|
| `:one` | `(T, error)`; no row returns `pgx.ErrNoRows` | `GetAPIKeyByHash`, `GetAPIKeyByID`, `GetAPIKeyByIDForUpdate`, `GetActiveKeyAccount`, `KeySpendSince` |
| `:many` | `([]T, error)` | `ListAPIKeysByOwner` |
| `:exec` | `error` | `InsertAPIKey`, `InsertAPIKeyIfAbsent`, `TouchAPIKey` |
| `:execrows` | `(int64, error)` (rows affected) | `UpdateAPIKey`, `DeleteAPIKeyByID` (0 → `key not found`), `DeactivateAPIKeyByHash` (`RevokeKey` returns `> 0`) |

A query with one parameter takes it as an argument
(`GetActiveKeyAccount(ctx, keyHash string)`); two or more become a
`<Name>Params` struct. `SELECT *` returns the table struct (`ApiKey`); a
narrower select returns a scalar or a `<Name>Row` struct.

## Schema types that no query uses yet

The schema also has these types. No checked-in query reads them, so
`storedb` has no field for them yet. The Go types below are the output of
sqlc v1.31.1 with `coordinator/store/postgres/sqlc.yaml` for a one-column probe query
on each listed column (2026-10-04). Check the generated code when you add the
first query, and move the row to the table above.

| Postgres type | Null | Go type | Caused by | Probe column in `coordinator/store/postgres/schema/schema.sql` |
|---|---|---|---|---|
| `text` | nullable | `*string` | `emit_pointers_for_null_types` | `darkbloom_machines.merged_into` |
| `bigint` | `NOT NULL` | `int64` | default | `ledger_entries.id` |
| `integer` | `NOT NULL` | `int32` | default | `fleet_snapshots.num_running` |
| `integer` | nullable | `*int32` | `emit_pointers_for_null_types` | `inference_routes.effective_queue` |
| `smallint` | `NOT NULL` | `int16` | default | `provider_verification_jobs.priority` |
| `double precision` | `NOT NULL` | `float64` | default | `fleet_snapshots.observed_decode_tps` |
| `double precision` | nullable | `*float64` | `emit_pointers_for_null_types` | `fleet_snapshots.free_for_load_gb` |
| `boolean` | nullable | `*bool` | `emit_pointers_for_null_types` | `fleet_snapshots.ewma_initialized` |
| `jsonb` | `NOT NULL` | `[]byte` | default | `providers.hardware` |
| `jsonb` | nullable | `[]byte` (`nil` for `NULL`) | default; the pointer flag does not apply | `model_versions.hugging_face_artifact`, `fleet_snapshots.queue_depth_by_model` |
| `bytea` | `NOT NULL` | `[]byte` | default | `app_attest_evidence_blobs.proof` |
| `text[]` | `NOT NULL` | `[]string` | default | `model_registry.capabilities`; a `::text[]` parameter is also `[]string` |

The schema has no `numeric`, `uuid`, `date` or `timestamp without time zone`
column. A `::timestamp` cast in a query generates `pgtype.Timestamp`, because
the overrides cover only `timestamptz`.

## Related

- [Write store queries with sqlc](../developer/sqlc.md) — add a query, convert a domain, troubleshooting
- [Schema lifecycle](../architecture/schema-lifecycle.md#generated-queries-sqlc) — how `schema.sql`, sqlc and the store fit together
