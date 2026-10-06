# Soft delete

> Last updated: 2026-10-06

Reference for the coordinator store's soft-delete columns: which tables have
`deleted_at`, every read that hides a soft-deleted row in `PostgresStore` and
`MemoryStore`, the writers of the column, the paths that do not filter, the
indexes, and what a soft delete changes. Account erasure and ordinary provider
removal write `deleted_at`. Why the model exists and how it fits the schema is in
[schema lifecycle](../architecture/schema-lifecycle.md#soft-delete).

## Tables

`coordinator/store/postgres/schema/migrations/00017_soft_delete_columns.sql` adds the
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
`coordinator/tests/store/contracts/soft_delete_domain_reads_test.go` covers
contact pagination and initial legacy MDM cohort qualification on both backends,
using real erasure transitions and isolated user/provider tombstones.

### `users`

| Store method | PostgresStore | MemoryStore | Result for a soft-deleted user |
|---|---|---|---|
| `GetUserByAccountID` | `coordinator/store/postgres/users.go` | `coordinator/store/memory/users.go` | `ErrNotFound` |
| `GetUserByPrivyID` | `coordinator/store/postgres/users.go` | `coordinator/store/memory/users.go` | `ErrNotFound` |
| `GetUserByStripeAccount` | `coordinator/store/postgres/users.go` | `coordinator/store/memory/users.go` | not found |
| `GetUserByEmail` | `coordinator/store/postgres/users.go` | `coordinator/store/memory/users.go` | not found |
| `ClaimModelTokenPromotion` | `coordinator/store/postgres/model_token_promotions.go` | `coordinator/store/memory/model_token_promotions.go` | `ErrPromotionIneligible` |
| `ListSmallModelsInterest` | `coordinator/store/postgres/small_models_interest.go` | `coordinator/store/memory/small_models_interest.go` | omitted before pagination; the admin contact export excludes the email |
| `FreezeLegacyMDMCohort` (initial qualification) | `coordinator/store/postgres/legacy_mdm_cohort.go` | `coordinator/store/memory/legacy_mdm_cohort.go` | cannot qualify for the initial frozen cohort |
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
| `GetProviderToken` | `coordinator/store/postgres/device_auth.go` | `coordinator/store/memory/device_auth.go` | `ErrProviderTokenInvalid` |

### `providers`

| Store method | PostgresStore | MemoryStore | Result for a soft-deleted record |
|---|---|---|---|
| `GetProviderRecord` | `coordinator/store/postgres/provider_read.go` | `coordinator/store/memory/providers.go` | not found |
| `GetMDAChainBySerial` | `coordinator/store/postgres/providers.go` | `coordinator/store/memory/providers.go` | its chain is not used |
| `ListProvidersByAccount` | `coordinator/store/postgres/providers.go` | `coordinator/store/memory/providers.go` | omitted |
| `GetProviderForRestore` | `coordinator/store/postgres/provider_restore.go` | `coordinator/store/memory/provider_restore.go` | not a restore candidate; an older live row can be |
| `ResolveMachineContinuity` | `coordinator/store/postgres/machine_continuity.go` | `coordinator/store/memory/machine_continuity.go` | not continuity history |
| `UsageFlowBuckets` (provider location) | `coordinator/store/postgres/analytics_flows.go` (`usageFlowBucketsSQL`) | `coordinator/store/memory/analytics.go` | its location is not used |
| `FreezeLegacyMDMCohort` (initial qualification) | `coordinator/store/postgres/legacy_mdm_cohort.go` | `coordinator/store/memory/legacy_mdm_cohort.go` | cannot qualify for the initial frozen cohort |
| `BackfillMachineInventory` | `coordinator/store/postgres/machine_inventory_backfill.go` | — (Postgres only) | not backfilled |

`FreezeLegacyMDMCohort` applies these filters only when it first constructs the
cohort. Later calls read the persisted snapshot without recomputing membership;
see [frozen legacy authorization](../architecture/security/enrollment.md#frozen-legacy-authorization-cohort).

## Writers of `deleted_at`

| Store method | Effect | PostgresStore | MemoryStore |
|---|---|---|---|
| `RequestAccountErasure` (confirm) | Sets `deleted_at` on the user and its providers; sets `active = false` and `deleted_at` on its API keys and provider tokens. Rows that already have `deleted_at` do not change | `coordinator/store/postgres/erasure.go` (`SoftDeleteUser`, `SoftDeleteProviders`, `SoftDeleteAPIKeys`, `SoftDeleteProviderTokens`) | `coordinator/store/memory/erasure.go` |
| `DeleteProvidersBySerial` | Sets `deleted_at` on live matching providers and removes reputation; preserves identity ownership for future erasure | `coordinator/store/postgres/providers.go` | `coordinator/store/memory/providers.go` |
| `CancelAccountErasure` | Clears `deleted_at` on the user and only providers stamped by this request; earlier provider removals stay hidden. API keys and provider tokens stay revoked and soft deleted | `coordinator/store/postgres/erasure.go` (`RestoreUser`, `RestoreProviders`) | `coordinator/store/memory/erasure.go` |

The scrub (`ScrubAccount`) does not change `deleted_at`; the rows stay soft
deleted after the scrub. How erasure works is in
[account erasure](../architecture/account-erasure.md).

## Paths that do not filter

The methods below remain available for administrative metadata, revocation,
cleanup and historical accounting. New account admissions and asynchronous
personal-data writes have the separate [late-write protections](#late-writes).
`CreateUser` inserts a new account; it does not restore the deleted account.

| Table | Methods |
|---|---|
| `users` | `CreateUser` insert, `SetUserRole`, `SetUserPlatformFeePercent` (`coordinator/store/postgres/users.go`) |
| `api_keys` | `SeedKey` insert (`InsertAPIKeyIfAbsent`), `TouchAPIKey`, `RevokeKey` (`DeactivateAPIKeyByHash`), `RevokeAPIKeyByID` and the delete in `RotateAPIKey` (`DeleteAPIKeyByID`) |
| `provider_tokens` | `RevokeProviderToken` (`coordinator/store/postgres/device_auth.go`) |
| `providers` | Ordinary removal uses `DeleteProvidersBySerial` to set `deleted_at` on live rows and delete reputation. Repeat removal returns zero; hidden identity rows remain available only for erasure ownership |
| other tables | `usage`, `provider_earnings`, `ledger_entries` and the other history tables have no `deleted_at`; `KeySpendSince` still counts a soft-deleted key's usage |
| outside the store | `admin-ui` reads the read replica with its own SQL (`admin-ui/src/lib/queries/`) and does not filter `deleted_at` |

## Indexes

| Index | Definition | Version | Why |
|---|---|---|---|
| `idx_users_privy_live` | `UNIQUE (privy_user_id) WHERE deleted_at IS NULL` | 18 (`indexMigrations`) | One live user per Privy ID; an erased user's ID can sign up again. Replaces `users_privy_user_id_key` (dropped by version 19) and `idx_users_privy` (dropped by version 20). |
| `idx_provider_sessions_account` | `provider_sessions (account_id)` | 10 | Erasure finds rows by account |
| `idx_provider_log_reports_account` | `provider_log_reports (account_id)` | 11 | Erasure finds rows by account |
| `idx_device_codes_account` | `device_codes (account_id)` | 12 | Erasure finds rows by account |
| `idx_darkbloom_machine_sessions_account` | `darkbloom_machine_sessions (account_id)` | 13 | Erasure finds rows by account |
| `idx_model_token_reservations_account` | `model_token_reservations (account_id)` | 14 | Erasure finds rows by account |
| `idx_inference_routes_consumer_key_hash` | `inference_routes (consumer_key_hash)` | 15 | Erasure finds rows by hashed key |
| `idx_request_rejections_consumer_key_hash` | `request_rejections (consumer_key_hash)` | 16 | Erasure finds rows by hashed key |
| `idx_billing_sessions_referral_code` | `billing_sessions (referral_code) WHERE referral_code <> ''` | 23 | Scrub referral-code copies |
| `idx_users_privy_deleted` | `users (privy_user_id) WHERE deleted_at IS NOT NULL` | 24 | Pending-erasure Privy lookup |

All are built `CONCURRENTLY` by `indexMigrations`
(`coordinator/store/postgres/migration_indexes.go`). Only
`idx_users_privy_live` and `idx_users_privy_deleted` read `deleted_at`. Version 21 also replaces the
`referrals.referrer_code` foreign key with
`referrals_referrer_code_cascade_fkey` (`ON UPDATE CASCADE`), so a referrer
code change reaches `referrals`.

## What a soft delete changes

| Effect | Where |
|---|---|
| The row stays in its table with `deleted_at` set; every read above treats it as absent | the reads above |
| The user's Privy ID is free for a new live user | `idx_users_privy_live`; `MemoryStore.CreateUser` |
| `CachedStore` drops its cached users after `RequestAccountErasure`, `CancelAccountErasure` and `ScrubAccount`. A call that does not go through it leaves a cached user for up to `UserTTL` (`30 * time.Second`) | `coordinator/store/cached.go`; `coordinator/internal/store/storecache/config.go` (`DefaultConfig`) |
| Erasure writes decode their returned request before commit, so cancellation after a successful commit does not suppress confirmation or scrub runtime cleanup | `coordinator/store/postgres/erasure.go` (`getErasureRequest`); `coordinator/api/accounts/erasure/loop.go` (`scrub`) |
| Confirming the soft delete leaves usage, earnings and ledger history intact; the later scrub removes their personal fields and forfeits remaining balances | [account erasure](../architecture/account-erasure.md#mechanism) |
| A pre-goose coordinator image cannot boot once a soft-deleted and a live user share a Privy ID | its boot DDL runs `CREATE UNIQUE INDEX IF NOT EXISTS idx_users_privy`; see the [rollback rules](../operations/schema-migration.md#rollback) |
| `CancelAccountErasure` during the grace period clears `deleted_at` on the user and providers stamped by that request; earlier removals stay hidden, and API keys and provider tokens stay revoked. After the scrub, nothing clears `deleted_at` | [Writers of `deleted_at`](#writers-of-deleted_at) |

## Documentation coverage

`scripts/docs-impact-rules.json` requires this reference when the current
live-row readers and writers listed above change, including the API-key SQL
source and generated adapter. This is a path-based guard, not SQL analysis:
a new reader or writer must be added to the rule as well as the tables above.
`scripts/test-docs-impact-check.py` verifies the mapping and keeps unrelated
history-table files and tests outside this gate.

## Late writes

| Writer | Deleted-account behavior | Code |
|---|---|---|
| `CreateAPIKey`, `CreateProviderToken`, `UpsertProvider`, `UpsertProviderWithReputation`, `ObserveMachine`, `CreateReferrer`, hardware-interest writes, payout admission | Refused after acquiring the same user fence as erasure; cancellation permits new writes again. Provider upserts also leave an existing soft-deleted provider row unchanged | `coordinator/store/postgres/erasure_fences.go` (`lockAccountAdmission`), `coordinator/store/postgres/providers.go` (`upsertProviderRecord`), `coordinator/store/memory/erasure_ownership.go` (`accountAdmissionLocked`), `coordinator/store/memory/providers.go` (`upsertProviderRecordLocked`) |
| `SetUserStripeAccount`, `SaveGlobalRecipient`, and Checkout creation results | Preserve cleanup IDs in the erasure outbox and refuse restoring personal fields | `coordinator/store/postgres/erasure_external.go` (`fenceErasureExternalObject`), `coordinator/store/memory/erasure_external.go` (`retainDeletedExternalObjectLocked`) |
| Usage and route persistence | Preserve accounting while clearing erased owners' location and region fields | `coordinator/store/postgres/erasure_observations.go` (`erasedObservationOwners`), `coordinator/store/memory/usage.go` (`RecordUsage`), `coordinator/store/memory/route_telemetry.go` (`recordInferenceRouteLocked`) |
| Trust-reuse upsert/recovery and verification jobs | Hold the shared privacy fence through SE-owner validation and persistence; erased-only keys are rejected, while a live co-owner or a subsequent authenticated owner remains usable | `coordinator/store/postgres/erasure_personal_writes.go` (`checkPersonalSEOwner`), `coordinator/store/memory/erasure_ownership.go` (`erasedSEOwnerLocked`) |

## Related

- [Schema lifecycle: soft delete](../architecture/schema-lifecycle.md#soft-delete) — the model and its invariants
- [Add a database migration: add soft delete to a table](../developer/database-migrations.md#add-soft-delete-to-a-table)
- [Apply schema migrations in production](../operations/schema-migration.md#rollback) — rollback rules after the soft-delete versions
