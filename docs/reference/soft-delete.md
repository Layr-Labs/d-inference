# Soft delete

> Last updated: 2026-10-04

Reference for the coordinator store's soft-delete columns: which tables have
`deleted_at`, every read that hides a soft-deleted row in `PostgresStore` and
`MemoryStore`, the writers of the column, the paths that do not filter, the
indexes, and what a soft delete changes. Only account erasure writes
`deleted_at`. Why the model exists and how it fits the schema is in
[schema lifecycle](../architecture/schema-lifecycle.md#soft-delete).

## Tables

`coordinator/store/postgres/schema/migrations/00013_soft_delete_columns.sql` adds the
column; the Go field is `DeletedAt *time.Time` with `json:"-"`
(`coordinator/store/user_types.go`, `apikey_types.go`, `provider_types.go`,
`device_auth_types.go`).

| Table | Column | Go type with the field | Generated field (sqlc) |
|---|---|---|---|
| `users` | `deleted_at TIMESTAMPTZ` (nullable, no default) | `User` | — |
| `api_keys` | `deleted_at TIMESTAMPTZ` (nullable, no default) | `APIKey` | `storedb.ApiKey.DeletedAt *time.Time` (`coordinator/store/postgres/storedb/models.go`) |
| `providers` | `deleted_at TIMESTAMPTZ` (nullable, no default) | `ProviderRecord` | — |
| `provider_tokens` | `deleted_at TIMESTAMPTZ` (nullable, no default) | `ProviderToken` | — |

`PostgresStore` reads do not load the column into `DeletedAt`; they filter it
in SQL. `MemoryStore` keeps the field on its records and checks it.

## Reads that hide a soft-deleted row

Postgres filters `deleted_at IS NULL`; MemoryStore skips a record whose
`DeletedAt` is not `nil`. `coordinator/tests/store/postgres/soft_delete_reads_test.go`
sets `deleted_at` directly and covers each PostgresStore read.
`coordinator/tests/store/contracts/erasure_soft_delete_reads_test.go` soft
deletes an account through `RequestAccountErasure` on both backends and checks
that the reads hide its rows and still return the rows of another account.

### `users`

| Store method | PostgresStore | MemoryStore | Result for a soft-deleted user |
|---|---|---|---|
| `GetUserByAccountID` | `coordinator/store/postgres/users.go` | `coordinator/store/memory/users.go` | `ErrNotFound` |
| `GetUserByPrivyID` | `coordinator/store/postgres/users.go` | `coordinator/store/memory/users.go` | `ErrNotFound` |
| `GetUserByStripeAccount` | `coordinator/store/postgres/users.go` | `coordinator/store/memory/users.go` | not found |
| `GetUserByEmail` | `coordinator/store/postgres/users.go` | `coordinator/store/memory/users.go` | not found |
| `ClaimModelTokenPromotion` | `coordinator/store/postgres/model_token_promotions.go` | `coordinator/store/memory/model_token_promotions.go` | `ErrPromotionIneligible` |
| `CreateUser` (Privy ID check) | `idx_users_privy_live` | `coordinator/store/memory/users.go` | The Privy ID is free; a new live user may take it |

### `api_keys`

PostgresStore methods are in `coordinator/store/postgres/apikey.go`; their
SQL is in `coordinator/store/postgres/queries/api_keys.sql`. MemoryStore
methods are in `coordinator/store/memory/apikey.go`.

| Store method | Query (PostgresStore) | MemoryStore | Result for a soft-deleted key |
|---|---|---|---|
| `GetKeyAccount` | `GetActiveKeyAccount` | `coordinator/store/memory/apikey.go` | `""` |
| `AuthenticateKey` | `GetAPIKeyByHash` | `coordinator/store/memory/apikey.go` | error; the request is not authenticated |
| `ListAPIKeys` | `ListAPIKeysByOwner` | `coordinator/store/memory/apikey.go` | omitted |
| `GetAPIKeyByID` | `GetAPIKeyByID` | `coordinator/store/memory/apikey.go` | not found |
| `UpdateAPIKey` | `UpdateAPIKey` (`UPDATE ... AND deleted_at IS NULL`) | `coordinator/store/memory/apikey.go` | `key not found`; nothing changes |
| `RotateAPIKey` | `GetAPIKeyByIDForUpdate` | `coordinator/store/memory/apikey.go` | `key not found`; nothing changes |

### `provider_tokens`

| Store method | PostgresStore | MemoryStore | Result for a soft-deleted token |
|---|---|---|---|
| `GetProviderToken` | `coordinator/store/postgres/device_auth.go` | `coordinator/store/memory/device_auth.go` | `provider token not found` |

### `providers`

| Store method | PostgresStore | MemoryStore | Result for a soft-deleted record |
|---|---|---|---|
| `GetProviderRecord` | `coordinator/store/postgres/provider_read.go` | `coordinator/store/memory/providers.go` | not found |
| `GetMDAChainBySerial` | `coordinator/store/postgres/providers.go` | `coordinator/store/memory/providers.go` | its chain is not used |
| `ListProvidersByAccount` | `coordinator/store/postgres/providers.go` | `coordinator/store/memory/providers.go` | omitted |
| `GetProviderForRestore` | `coordinator/store/postgres/provider_restore.go` | `coordinator/store/memory/provider_restore.go` | not a restore candidate; an older live row can be |
| `ResolveMachineContinuity` | `coordinator/store/postgres/machine_continuity.go` | `coordinator/store/memory/machine_continuity.go` | not continuity history |
| `UsageFlowBuckets` (provider location) | `coordinator/store/postgres/analytics_flows.go` (`usageFlowBucketsSQL`) | `coordinator/store/memory/analytics.go` | its location is not used |
| `BackfillMachineInventory` | `coordinator/store/postgres/machine_inventory_backfill.go` | — (Postgres only) | not backfilled |

## Writers of `deleted_at`

| Store method | Effect | PostgresStore | MemoryStore |
|---|---|---|---|
| `RequestAccountErasure` (confirm) | Sets `deleted_at` on the user and its providers; sets `active = false` and `deleted_at` on its API keys and provider tokens. Rows that already have `deleted_at` do not change | `coordinator/store/postgres/erasure.go` (`SoftDeleteUser`, `SoftDeleteProviders`, `SoftDeleteAPIKeys`, `SoftDeleteProviderTokens`) | `coordinator/store/memory/erasure.go` |
| `CancelAccountErasure` | Clears `deleted_at` on the user and its providers. API keys and provider tokens stay revoked and soft deleted | `coordinator/store/postgres/erasure.go` (`RestoreUser`, `RestoreProviders`) | `coordinator/store/memory/erasure.go` |

The scrub (`ScrubAccount`) does not change `deleted_at`; the rows stay soft
deleted after the scrub. How erasure works is in
[account erasure](../architecture/account-erasure.md).

## Paths that do not filter

Writes and hard deletes act on a soft-deleted row as on any other row, with
one exception: `UpsertProvider` and `UpsertProviderWithReputation` leave a
soft-deleted `providers` row unchanged, so a late heartbeat persist cannot
rewrite it (`upsertProviderRecord`, `WHERE providers.deleted_at IS NULL`,
`coordinator/store/postgres/providers.go`; `upsertProviderRecordLocked`,
`coordinator/store/memory/providers.go`; `TestSoftDeletedProviderIgnoresLatePersist`).

| Table | Methods |
|---|---|
| `users` | `CreateUser` insert, `SetUserStripeAccount`, `SetUserRole`, `SetUserPlatformFeePercent` (`coordinator/store/postgres/users.go`) |
| `api_keys` | `CreateAPIKey` and `SeedKey` inserts (`InsertAPIKey`, `InsertAPIKeyIfAbsent`), `TouchAPIKey`, `RevokeKey` (`DeactivateAPIKeyByHash`), `RevokeAPIKeyByID` and the delete in `RotateAPIKey` (`DeleteAPIKeyByID`) |
| `provider_tokens` | `CreateProviderToken`, `RevokeProviderToken` (`coordinator/store/postgres/device_auth.go`) |
| `providers` | `DeleteProvidersBySerial` (`coordinator/store/postgres/providers.go`). `UpsertProvider` and `UpsertProviderWithReputation` (`coordinator/store/postgres/provider_record_write.go`) skip a soft-deleted row (see above) |
| other tables | `usage`, `provider_earnings`, `ledger_entries` and the other history tables have no `deleted_at`; `KeySpendSince` still counts a soft-deleted key's usage |
| outside the store | `admin-ui` reads the read replica with its own SQL (`admin-ui/src/lib/queries/`) and does not filter `deleted_at` |

## Indexes

| Index | Definition | Version | Why |
|---|---|---|---|
| `idx_users_privy_live` | `UNIQUE (privy_user_id) WHERE deleted_at IS NULL` | 14 (`indexMigrations`) | One live user per Privy ID; an erased user's ID can sign up again. Replaces `users_privy_user_id_key` (dropped by version 15) and `idx_users_privy` (dropped by version 16). |
| `idx_provider_sessions_account` | `provider_sessions (account_id)` | 6 | Erasure finds rows by account |
| `idx_provider_log_reports_account` | `provider_log_reports (account_id)` | 7 | Erasure finds rows by account |
| `idx_device_codes_account` | `device_codes (account_id)` | 8 | Erasure finds rows by account |
| `idx_darkbloom_machine_sessions_account` | `darkbloom_machine_sessions (account_id)` | 9 | Erasure finds rows by account |
| `idx_model_token_reservations_account` | `model_token_reservations (account_id)` | 10 | Erasure finds rows by account |
| `idx_inference_routes_consumer_key_hash` | `inference_routes (consumer_key_hash)` | 11 | Erasure finds rows by hashed key |
| `idx_request_rejections_consumer_key_hash` | `request_rejections (consumer_key_hash)` | 12 | Erasure finds rows by hashed key |
| `idx_billing_sessions_referral_code` | `billing_sessions (referral_code) WHERE referral_code <> ''` | 19 | Erasure finds the copies of a referrer code |
| `idx_users_privy_deleted` | `users (privy_user_id) WHERE deleted_at IS NOT NULL` | 20 | `PrivyUserPendingErasure` finds a soft-deleted user by Privy ID |

All are built `CONCURRENTLY` by `indexMigrations`
(`coordinator/store/postgres/migration_indexes.go`). Only
`idx_users_privy_live` and `idx_users_privy_deleted` read `deleted_at`. Version 17 also replaces the
`referrals.referrer_code` foreign key with
`referrals_referrer_code_cascade_fkey` (`ON UPDATE CASCADE`), so a referrer
code change reaches `referrals`.

## What a soft delete changes

| Effect | Where |
|---|---|
| The row stays in its table with `deleted_at` set; every read above treats it as absent | the reads above |
| The user's Privy ID is free for a new live user | `idx_users_privy_live`; `MemoryStore.CreateUser` |
| `CachedStore` drops its cached users after `RequestAccountErasure`, `CancelAccountErasure` and `ScrubAccount`. A call that does not go through it leaves a cached user for up to `UserTTL` (`30 * time.Second`) | `coordinator/store/cached.go`; `coordinator/internal/store/storecache/config.go` (`DefaultConfig`) |
| History rows that reference the account (usage, earnings, ledger) do not change | no `deleted_at` on those tables |
| A pre-goose coordinator image cannot boot once a soft-deleted and a live user share a Privy ID | its boot DDL runs `CREATE UNIQUE INDEX IF NOT EXISTS idx_users_privy`; see the [rollback rules](../operations/schema-migration.md#rollback) |
| `CancelAccountErasure` during the grace period clears `deleted_at` on the user and its providers; API keys and provider tokens stay revoked. After the scrub, nothing clears `deleted_at` | [Writers of `deleted_at`](#writers-of-deleted_at) |

## Related

- [Schema lifecycle: soft delete](../architecture/schema-lifecycle.md#soft-delete) — the model and its invariants
- [Add a database migration: add soft delete to a table](../developer/database-migrations.md#add-soft-delete-to-a-table)
- [Apply schema migrations in production](../operations/schema-migration.md#rollback) — rollback rules after the soft-delete versions
