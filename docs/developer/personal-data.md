# Add personal data safely

> Last updated: 2026-10-04

How-to for a coordinator change that stores personal data or writes to an
account: add an erasure rule for a new column or table, and respect the hooks
that keep an erased account erased. When you finish, the scrub removes the new
data and the marker tests prove it. Why the scrub works this way is in
[account erasure](../architecture/account-erasure.md).

## Prerequisites

- A Go toolchain and the repository checkout ([build](build.md)).
- A throwaway Postgres for the Postgres tests, with `DATABASE_URL` set
  ([test](test.md)). Without it the Postgres marker test skips.
- `sqlc` through `make sqlc-generate` (`coordinator/store/postgres/sqlc.yaml`).
- The migration procedure: [database migrations](database-migrations.md).

Personal data here is any value that can identify a person: an email, a
user-chosen name or label, a host name, a serial number, UDID or push token, a
location, region or IP address, a Stripe or other external account ID, a
wallet address, a raw proof, receipt or log. Random IDs, public keys, counts
and amounts are not personal data alone
([context](../architecture/account-erasure.md#context)).

## Steps

### Add a personal column or table

1. Add the schema change as a migration
   ([database migrations](database-migrations.md)).

2. Choose the link to the account. The scrub can only reach rows through a
   key that `collectErasureKeys` reads first
   (`coordinator/store/postgres/erasure_keys.go`) into `erasure.Keys`
   (`coordinator/internal/store/erasure/keys.go`):

   | The row has | Use |
   |---|---|
   | `account_id` (or `owner_account_id`) | `k.AccountID` |
   | A provider ID or session ID | `k.ProviderIDs` |
   | A Secure Enclave key | `k.SEKeys` (shared keys already removed) |
   | An App Attest key ID | `k.AppAttestKeyIDs` (shared keys already removed) |
   | `consumer_key_hash` | `k.ConsumerKeyHash` |
   | A serial number | `k.Serials` or a digest of it |
   | None of these | Add a column that links to the account, or add a new key set |

   For a new key set, add a field to `erasure.Keys`. Read it in
   `collectErasureKeys`, inside the same transaction, and in
   `collectErasureKeysLocked` (`coordinator/store/memory/erasure_keys.go`). If
   another account can hold the same key, remove the shared values
   (`erasure.WithoutKeys`), count them, and add a reason to `Keys.Retained`
   and to
   [retained data](../reference/personal-data-rules.md#retained-data).

3. Add a count query and an apply query to
   `coordinator/store/postgres/queries/erasure.sql`, after the rule it follows. Give
   both the same `WHERE` clause, bounded by the key from step 2. The count is
   `:one`; the apply is `:execrows`:

   ```sql
   -- name: CountWidgetLabelRows :one
   SELECT COUNT(*) FROM widgets WHERE account_id = $1;

   -- name: ScrubWidgetLabelRows :execrows
   UPDATE widgets SET label = '' WHERE account_id = $1;
   ```

   Do not filter on a column that an earlier rule changes; the scrub counts
   and applies each rule in order.

4. Regenerate the Go code:

   ```bash
   make sqlc-generate
   ```

5. Add a `Rule` to `erasure.Rules`
   (`coordinator/internal/store/erasure/rules.go`), at the place in the scrub
   order where it runs: a unique `Name`, the `Table`, a `Link` that says how
   rows reach the account, and either `Columns` with an `Action` each or
   `Delete: true` with no columns:

   ```go
   {
       Name: "widgets", Table: "widgets", Link: "account_id",
       Columns: []Column{{"label", SetEmpty}},
   },
   ```

   Pick the action from [rule actions](../reference/personal-data-rules.md#rule-actions).
   Use a unique random value (`SetRandom`) for a column with a unique
   constraint: add a replacement field to `erasure.Keys` and draw it in
   `NewKeys` with `erasedValue`. Use a tombstone when other code reads the
   row's existence.

6. Add the Postgres statements under the same name in `erasureStatements`
   (`coordinator/store/postgres/erasure_rules.go`). A count and apply query
   pair that takes one key is `byKey`; one that takes a key set is `byKeys`,
   which runs nothing for an account with no such keys. Use `one` when a
   query takes other parameters:

   ```go
   "widgets": func(k *erasure.Keys) []piiStatement {
       return byKey(k.AccountID, (*storedb.Queries).CountWidgetLabelRows, (*storedb.Queries).ScrubWidgetLabelRows)
   },
   ```

7. Add the memory form under the same name in `memoryErasureRules`
   (`coordinator/store/memory/erasure_rules.go`). It returns the number of
   linked items, and changes them only when `apply` is true. Use
   `memoryNoTable` only when `MemoryStore` holds no such data, and then add
   the name to `memoryRulesWithoutTable`
   (`coordinator/tests/store/memory/erasure_marker_test.go`). A backend that
   has no form for a rule fails every plan and scrub.

8. Seed the marker tests. Add an `INSERT` to `erasureMarkerFixture`
   (`coordinator/tests/store/postgres/erasure_marker_test.go`) that puts `PIIMARK` in every
   personal column for `acct-A`. If the data can be shared, add a `KEEPMARK`
   row for `acct-B` that must survive. Seed the same data in
   `seedMemoryMarkers` (`coordinator/tests/store/memory/erasure_marker_test.go`).
   Both tests fail when a rule counts no fixture rows.

9. Add the rule to the [rule table](../reference/personal-data-rules.md#rule-table)
   and, when you add a file, to `affected_files` of threat `T-059` in
   [`../threat-model.yaml`](../threat-model.yaml).

### Respect the erasure hooks in a new writer

1. **A new `Store` method that writes `users`**: override it in `CachedStore`
   (`coordinator/store/cached.go`) and call `c.users.Invalidate()` after the
   write, as `RequestAccountErasure`, `CancelAccountErasure` and
   `ScrubAccount` do. Otherwise a cached user outlives a soft delete or a
   scrub for up to `UserTTL`. Call erasure methods through the `Store`, not
   through `store.As`, so the override runs.

2. **A new read of a live user, key, provider or token**: filter
   `deleted_at IS NULL` in Postgres and `DeletedAt == nil` in `MemoryStore`
   ([soft-deleted rows](../architecture/storage.md#soft-deleted-rows)).

3. **A new upsert or late write of an account's row**: skip a soft-deleted
   row, as `upsertProviderRecord` does with
   `WHERE providers.deleted_at IS NULL` and `upsertProviderRecordLocked`
   does in memory. Otherwise a heartbeat or retry writes the data back during
   the grace period or after the scrub.

4. **A new in-memory copy of personal data** (a cache or map keyed by
   account, provider or Secure Enclave key): add a forget method and call it
   from a hook in `erasure.Hooks` (`coordinator/api/accounts/erasure/owner.go`),
   which `scrub` (`coordinator/api/accounts/erasure/loop.go`) calls after the
   commit. The hooks are set in `NewRuntime` (`coordinator/api/server.go`). If
   it needs keys the transaction collected, return them in `ErasureResult`.
   Leave entries of shared keys alone; `ErasureResult.SEKeys` already
   excludes them.

5. **A new credit path**:
   - Postgres: write the credit as an `INSERT` into `ledger_entries` with a
     positive amount and an increase of `balances`. The migration 21
     triggers then refuse it for an erased account
     ([refused credits](../architecture/account-erasure.md#refused-credits-after-the-scrub)).
     Money held in another table is not covered; refuse it there.
   - Memory: credit through `creditLocked`, and change `withdrawable` only
     when it returns `true`. A path that bypasses `creditLocked` must call
     `refuseErasedCreditLocked` itself.

6. **A new login or account-creation path**: refuse a soft-deleted account
   as `GetOrCreateUser` does with `PrivyUserPendingErasure`
   (`coordinator/auth/privy.go`), so the person cannot get a second live
   account during the grace period.

7. **A new external object linked to the account** (a Stripe object or
   another provider's account): collect its ID in `collectErasureKeys` and
   write an outbox row for it (`Keys.OutboxRows`); add the target to
   `ErasureTarget` and to the `erasure_outbox.target` `CHECK`.

8. **A new log line**: name the account or provider by `account_id` or
   `provider_id` only; never log an email, IP address, serial number or
   UDID. The scrub cannot reach Datadog. This rule lands with
   [PR #1327](https://github.com/Layr-Labs/d-inference/pull/1327), which is
   open and not yet merged; until it merges some existing log lines still
   hold such values.

## Verify

```bash
cd coordinator
export DATABASE_URL='postgres://postgres:pg@127.0.0.1:5432/postgres?sslmode=disable'  # throwaway database
go test -p 1 ./tests/store/... -count=1 -run 'Erasure|Erased|ScrubLocks|LocksUserFirst|SoftDeleted'
go test ./tests/api/accounts/... ./tests/api/billing/... ./tests/api/provider/trust/... -count=1 -run 'Erasure|Erased|PrivyLoginRefused|MDMSchedulerForget|TrustReuseCacheForget'
go test ./tests/auth -count=1 -run PendingErasure
cd .. && make sqlc-check && make docs-check
```

These must pass:

| Test | Proves |
|---|---|
| `TestErasureMarkerPostgres` | No `PIIMARK` is left in any text, JSON, array or `bytea` column of any table, the second account's `KEEPMARK` data is unchanged, every rule had fixture rows, applied counts equal planned counts |
| `TestErasureMarkerMemory` | The same over every value reachable from `MemoryStore` |
| `TestErasurePlanRunsEveryRuleInOrder` | Rule names are unique, a delete rule lists no columns and an update rule lists some, and the plan of each backend has one row per rule in `erasure.Rules` order |
| `TestAccountErasureLifecycle` | Plan, confirm, cancel and scrub on both backends |
| `TestErasedAccountRefusesCredits` | Credits after the scrub are refused and recorded |
| `TestCachedStoreInvalidatesUsersOnErasure` | The erasure writers drop cached users |

## Troubleshooting

| Failure | Cause | Fix |
|---|---|---|
| `rule <name> (<table>) has no fixture rows` | The fixture has no row the rule's count query sees | Add a fixture row with the link key |
| `rule <name> has no memory fixture` | `seedMemoryMarkers` seeds no data for the rule | Seed it, or use `memoryNoTable` and `memoryRulesWithoutTable` if `MemoryStore` has no such data |
| `personal data left in <table>.<column>` | A personal column has no rule, or the rule misses rows | Add or widen the rule (steps 2 to 7) |
| `the other account's data changed` | A predicate reaches another account's rows | Bound it by a collected key; remove shared keys |
| `store: no memory erasure rule "<name>"` | `memoryErasureRules` lacks the name | Step 7 |
| `store: no postgres erasure rule "<name>"` | `erasureStatements` lacks the name | Step 6 |
| `erasure: affected rows differ from the count: <rule> counted N, changed M` | The count and apply predicates differ, or a trigger skips the write | Make the `WHERE` clauses equal; check the table's triggers |
| `make sqlc-check` fails | `storedb` or `schema.sql` is stale | `make sqlc-generate`; regenerate the schema dump ([database migrations](database-migrations.md)) |

## Related

- [Account erasure](../architecture/account-erasure.md): the mechanism and its invariants
- [Personal-data rules](../reference/personal-data-rules.md): every current rule
- [Database migrations](database-migrations.md): add the schema change
- [Storage](../architecture/storage.md): the store interface and soft-deleted rows
