# Storage

> Last updated: 2026-10-04

What the coordinator persists, through which interface, in which backend, and
how the schema reaches a fresh database; then what a provider keeps on its own
disk and in its Keychain. Read this to understand what survives a restart, what
does not, and which files an operator may touch. Configuration values are
listed once in [`../reference/configuration.md`](../reference/configuration.md);
the SSD cache file format is in
[`../reference/ssd-kv-cache.md`](../reference/ssd-kv-cache.md).

Promoted, non-retired model versions remain accepted during automatic weight
updates. `ModelRegistryRecord.ServingVersions` derives from existing
`model_versions.promoted_at` and `status`; no new schema migration is required.
The model cache invalidates on publication, promotion and explicit retirement.
Provider snapshots use immutable hidden revision directories selected by
`refs/main`; [revision storage and recovery](model-revisions.md) describes them.

Model versions also store the optional `hugging_face_artifact` as nullable JSONB
(`coordinator/store/postgres/`). `SetModelVersion` replaces it and invalidates
the existing model read-through cache; [artifact schema](../reference/model-registry-format.md#hugging-face-download-artifact).

Attempt decision fields are additive columns and existing provider JSONB;
[prediction telemetry](../reference/prediction-decision-telemetry.md#storage-and-rollout)
defines migration, historical NULLs and the separately applied waterfall view.

App Attest maintenance marks abandoned pending submissions `interrupted` without accepting old assertions or changing counters. Enrollment contexts retain their protocol version so an upgrade does not reinterpret a cached proof. Historical receipt recovery appends new versions; credential revocations are durable and account-scoped. See `coordinator/store/app_attest_maintenance.go` and `coordinator/store/app_attest_readiness.go`. The additive `app_attest_key_rotations` table (`coordinator/store/app_attest_rotation.go`, created with the other App Attest DDL) records one coordinator-requested dead-key retirement per key with a `(machine_id, requested_at DESC)` index for rate limits; it is not a revocation.

The additive [App Attest inventory and evidence tables](../reference/app-attest-shadow.md#storage-and-complete-evidence-archive) retain stable machine mappings, session/OS history, complete proof bytes, receipt versions, and atomic verification results. They do not restore live authorization. The [MDM-optional path](../reference/provider-authorization.md#machine-identity-and-base-rewards) uses verified canonical identity for new base-floor settlement, while retaining original organic-earning keys and historical ledger rows.

Machine-session reconciliation uses a partial index over open sessions and bounded, row-locked batches to repair missed disconnect writes after contention or restart. Fresh inventory or provider-session heartbeats preserve liveness. Known closures retain their timestamp; inferred stale closures are labelled and can recover when fresh observations resume. Older observations and confirmed disconnects are fenced in `ObserveMachine`. See the [inventory lifecycle](../reference/app-attest-shadow.md#machine-inventory-and-identity) and `coordinator/store/machine_inventory_reconcile.go`.

Canonical history and reward queries use the existing inventory tables. `coordinator/store/postgres/machine_inventory_schema.go` adds the reverse-merge index `darkbloom_machines_merged_into`; include it in additive migration preflight. `coordinator/store/postgres/machine_floor_settlement.go` serializes canonical/raw-session settlement with inventory merges, preventing duplicate same-epoch floors without rewriting existing balances. Serving leases remain in memory and are re-established after reconnect.

Provider `attestation_result` JSON additively retains `OSVersion` from the signed
registration blob (`coordinator/attestation/attestation.go`, `VerificationResult`).
Existing rows without it decode as unknown. This app-reported metadata supports
owner upgrade notices; it does not certify an OS or alter trust gates, and needs
no SQL migration.

The additive `app_attest_build_qualifications` table stores immutable signed-artifact approval, test evidence and server-attributed operator/time, plus permanent revocation tombstones. `coordinator/store/postgres/app_attest_builds.go` (`SetQualifiedRelease`) locks the same row used for revocation and atomically checks the exact identity before writing the active release. `store.As[AppAttestBuildStore]` unwraps the store decorator; qualification reads are deliberately uncached there. Service snapshots have a separate bounded lifetime, and stored approval never restores a live serving lease. See the [qualification runbook](../operations/app-attest-build-qualification.md).

## Hardware-interest persistence

`SmallModelsInterestStore` (`coordinator/store/small_models_interest.go`) is composed into `Store`. The memory implementation retains one value per internal account ID under the existing store mutex. The Postgres implementation creates the additive `small_models_interest` table after `users`; its primary key references `users(account_id)` with cascading deletion. An atomic upsert replaces Mac type/chip/RAM, preserves `created_at`, and advances `updated_at` (`coordinator/store/postgres/small_models_interest.go`, `smallModelsInterestDDL`, `UpsertSmallModelsInterest`). Repeated requests cannot create duplicate account rows.

Contact email remains in `users`: bounded admin pages join it when read, so a registration does not freeze a stale email copy. `CachedStore` forwards this new domain through its embedded `Store`; these writes do not mutate cached user records. Postgres records survive reconnects and migrations; memory records last only for that process (`coordinator/store/memory/small_models_interest.go`).

The console stores only pending hardware details; only an explicit click on the current page arms automatic submission after sign-in. After reload, select hardware and click the registration action again; the calculator does not restore its selection from this marker. It ignores the former anonymous success markers and confirms against the authenticated account's server record. An intent already bound to account A cannot submit as account B; late responses cannot replace the current account or a newer write. Explicit cancellation disarms pending sign-in registration; it does not delete an already stored record (`console-ui/src/app/earn/useSmallModelsInterest.ts`, `useSmallModelsInterest`). The [HTTP contract](../reference/api-contracts.md#small-model-interest) defines acknowledgment and export limits. This feature collects opt-ins; it does not send email.

## Context

The coordinator is a single Go process whose in-memory registry is rebuilt from
provider connections after every restart. Everything that must outlive a
process — accounts and keys, the money ledger, usage, the model catalog,
releases, provider trust decisions and telemetry — goes through one `Store`
value chosen at boot. Providers are the opposite: a `darkbloom` daemon keeps a
handful of small JSON files under `~/.darkbloom`, its weights in the Hugging
Face cache, an encrypted SSD prefix cache, and one key-encryption key in the
Keychain. Nothing prompt-derived is stored on either side.

## Mechanism

### The store interface

`Store` (`coordinator/store/interface.go`) is the union of fourteen embedded
domain interfaces. Most are declared in `coordinator/store/interface_domains.go`;
`RequestOutcomeStore` lives in `coordinator/store/request_outcomes.go` and
`SmallModelsInterestStore` in `coordinator/store/small_models_interest.go`. Callers
depend on the narrow slice they need; both implementations satisfy all fourteen.

| Sub-interface | Owns |
|---|---|
| `APIKeyStore` | Consumer API keys: create, seed, validate, per-key limits and counts. |
| `UsageStore` | Usage events and settled payments plus the totals, time-series, geo and leaderboard aggregations behind `/v1/stats`. |
| `RequestOutcomeStore` | Versioned unsampled `request_outcomes`, unique on coordinator UUID, with bounded compact attempt evidence; see [incoming request accounting](request-accounting.md). |
| `TelemetryStore` | Routing-decision snapshots (`inference_routes`), rejection records and the profiler's `request_profiles`/`fleet_snapshots`; prompt-free by construction. |
| `LedgerStore` | The double-entry balance ledger; every amount is micro-USD. |
| `BillingStore` | Referrals, deposit sessions, per-account model prices and Stripe Connect withdrawals. |
| `ModelRegistryStore` | The manifest-backed model catalog and the public aliases that resolve to concrete builds. |
| `ReleaseStore` | Versioned provider binary releases and their hashes. |
| `UserStore` | Privy-linked consumer accounts, role, platform-fee override and Stripe Connect payout fields. |
| `SmallModelsInterestStore` | One Earn-page hardware-interest record per account: upsert, own readback and bounded admin pages joined to the current email; see [hardware-interest persistence](#hardware-interest-persistence). |
| `DeviceAuthStore` | The RFC 8628-style device-code flow and the long-lived provider tokens it mints. |
| `InviteStore` | Invite codes and redemptions. |
| `ProviderEarningsStore` | Per-node earnings, payouts and the base-rewards settlement rows. |
| `ProviderStore` | Provider records and sessions, reputation, the APNs code-identity and trust-reuse caches, verification jobs and log reports. |

`ModelDemandStore` (`coordinator/store/model_demand.go`) is an optional capability,
not an embedded member of `Store`. Both backends implement it; callers discover
it through `store.As[store.ModelDemandStore]`, which unwraps decorators. It owns
compact, revision-aware public demand projections and hourly
per-model/consumer/outcome counters retained for 31 days; PostgreSQL aggregate
reads use bounded read-only transactions.

Telemetry *events* are not in the store at all: the coordinator emitter sends
them to Datadog only (see [`telemetry.md`](telemetry.md)).

### Two implementations and when each runs

| Backend | File | Selected when | Durability |
|---|---|---|---|
| `postgres.PostgresStore` | `coordinator/store/postgres/` | `EIGENINFERENCE_DATABASE_URL` is set | Durable, outside the coordinator process; deployment details are in the [coordinator runbook](../operations/coordinator-deploy.md). |
| `memory.MemoryStore` | `coordinator/store/memory/` | No DSN **and** `EIGENINFERENCE_ALLOW_MEMORY_STORE=true` | Process memory; everything is lost on exit. |

Selection is in `app.openStore` (`coordinator/app/store.go`): with a DSN it
calls `postgres.NewPostgres` and exits 1 on any connect, ping or migration error;
without one it refuses to start unless the memory store is explicitly allowed
(`store.Config.Check`). The memory store is for tests and local hacking, not a
"simple deployment" — it has no fsync'd trust-reuse journal, no durable code
attestations, and the admin key exists only because `memory.NewMemory` received
it in `store.Config`.

Both implementation packages import root `store` contracts; root `store` never
imports a backend. Application assembly applies `store.NewCached` to the chosen
instance. `CachedStore` invalidation and `store.As` capability unwrapping remain
at the contract layer. Moving a method must not bypass either mechanism.

Backend-specific tests live in the mirrored `coordinator/tests/store/memory/`
and `coordinator/tests/store/postgres/` directories. Public parity cases live
under `coordinator/tests/store/contracts/`; each database test process uses
`coordinator/tests/internal/testdb` to allocate its own disposable database before
running fixtures. The local test role needs `CREATEDB`. Packages can execute
concurrently without truncating one another's tables; these fixtures never use
a shared production database.

### Connecting to Postgres

`NewPostgres` parses the DSN with `pgxpool.ParseConfig` and overrides the pool
shape: at least 80 max connections, 10 minimum, 30 minute connection lifetime,
5 minute idle timeout, 30 second health check. The 80 floor exists because the
stats endpoint can hold connections for seconds while heartbeat upserts,
billing settlements and inference completions also need them. The DSN itself is
the only connection-level knob; there is no separate host/user/password set.

### Migrations run inside the process, at every boot

`coordinator --migrate-only` applies the same migrations and exits before admin
key seeding, listeners, or background workers. It requires a PostgreSQL URL;
there is no memory-store fallback or schema-skip mode. Normal startup still
checks every migration. There is no versioned migration directory for the
schema. `PostgresStore.migrate` (`coordinator/store/postgres/migrations.go`) executes an
ordered slice of idempotent statements — `CREATE TABLE IF NOT EXISTS`,
`ADD COLUMN IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`, `DROP TABLE IF EXISTS`
for retired tables — on every start, followed by
`checkRetiredBackfills` (`coordinator/store/postgres/retired_backfills.go`),
`ensureProviderRestoreIndexes` (`coordinator/store/postgres/startup.go`) and
`ensureProviderEarningsJobIndex`, then `ensureProviderEarningsWindowIndex`
(`coordinator/store/postgres/earnings_window_index.go`). One-shot *data* migrations are gated by a row
in `schema_migrations` so they run at most once. Two SQL files under
`coordinator/store/postgres/migrations/` are deliberately **not** on that path and are
applied by hand with `psql`: `dedupe_provider_earnings.sql` (an offline cleanup
that once ran at boot, held a relation lock for ~15 minutes on the production
table and kept the coordinator from binding its port) and
`request_waterfall.sql` (an analysis view joining `request_profiles` to
`inference_routes`, kept off the boot path so a `CREATE VIEW` can never queue
behind a long query's lock). `coordinator/deploy/start.sh` does not touch the
database; it only prepares the persistent disk and MicroMDM before `exec
coordinator`.

The one-shot backfills that derived `earnings_summary`, `usage_totals` and
`balances.withdrawable_micro_usd` from history (markers
`backfill_earnings_summary_v1`, `backfill_usage_totals_v1`,
`backfill_withdrawable_balance_v1`) have run in production and are retired
after v0.9.10. The schema slice now creates `balances` with
`withdrawable_micro_usd`. `checkRetiredBackfills` then guards the boot:

- it fails if `balances.withdrawable_micro_usd` is missing;
- it records each marker whose source table (`balances`, `usage`,
  `provider_earnings`) is empty, because with no history the current schema is
  already exact, and v0.9.10 recorded the same markers on an empty database;
- it seeds the single `usage_totals` row only while `usage` is empty;
- it fails if a source table holds rows but its marker is missing, or if the
  `usage_totals` row is missing.

A failed boot writes no marker and no counter for the data it refused, so the
remedy in the error (boot a coordinator built from v0.9.10, which still
runs them, once; then this build) still runs the real backfill. Databases that ran the
backfills keep their markers and their now-unused scratch tables
(`earnings_summary_backfill_pending`, `usage_totals_backfill_state`).

The Solana-era cleanups are retired the same way: the wallet-keyed price delete (marker `cleanup_wallet_model_prices_v1`,
which on a fresh database ran before `users` existed and so fired on the second
boot) and the one-time column drops `billing_sessions.chain`,
`users.solana_wallet_address`, `users.solana_wallet_id` and
`releases.image_bridge_hash`. A database migrated by the current binary still
boots an older one, whose versions of these statements are no-ops or guarded.

`RecordProviderEarning` and `CreditProviderAccount` maintain new summaries from
inserted earning rows, so duplicate non-empty job IDs never increment twice.
`base_reward` contributes money but zero inference count/tokens, matching floor
draw settlement and MemoryStore. The record-only method does not credit balances
or create ledger entries.

Postgres startup logs connection time and individual schema statement durations
as bounded phase labels, plus named index phases. Logs omit SQL and
parameters. Preparing migrations before the drain moves index builds out of the
cutover window; concurrent index creation can still wait for old transactions. See the [deployment procedure](../operations/coordinator-deploy.md)
for the approval and compatibility boundary.

Provider history is recovered on demand after successful live SE attestation,
using `GetProviderForRestore` with the verified serial first, then SE key if
no serial record exists. Ordered partial indexes on each identity plus
`last_seen DESC, id DESC` select the newest prior session. Every currently registered session is excluded, and a returned row is checked
again for sessions arriving during lookup. Until history lookup/restoration
finishes, persisted rows omit the indexed serial and SE key, including late writes
from a registration that already disconnected. `ProviderPersistence`
(`coordinator/registry/provider_persistence.go`, `CanPublishLocked`) owns the
restore-publication gate and serializes provider-record and reputation snapshots;
pending reputation writes are skipped (`coordinator/registry/persistence.go`,
`PersistProvider`, `PersistReputation`). Completed records publish together with their reputation in
one Postgres transaction or MemoryStore lock (`UpsertProviderWithReputation`,
`coordinator/store/`), so an older zero snapshot cannot
overwrite the completed state and no completed identity appears without its
reputation. Registration retries history/reputation reads up to three times,
within one five-second deadline shared with `RestoreProviderStateContext`.
Verified identities still awaiting restoration fail `state_restoring` in routing,
capacity and model-loading gates; owner self-route cannot bypass it. Exhaustion
ends the new registration with WebSocket close code 1013 before account lookup,
MDM scheduling or duplicate-session eviction. Normal reconnect can retry against
preserved history. Missing legacy reputation is allowed; a failed read never
marks restoration complete. `NewServer` does not scan historical providers.
The existing `RestoreProviderState` trust cap and independent newest-nonempty-MDA
chain re-verification remain in force.
Store errors are logged and do not grant hardware trust. Reputation is still
loaded by the selected historical record ID. No store operation lists every
historical provider record.

```mermaid
flowchart LR
  A[ReadAppConfig] --> B{DATABASE_URL set?}
  B -- yes --> C[pgxpool connect + Ping]
  C --> D[migrate: idempotent DDL slice]
  D --> E[one-shot data migrations\ngated by schema_migrations;\nretired-backfill guard]
  E --> F[ensureProviderEarningsJobIndex\nCONCURRENTLY, fast-path if present]
  F --> F2[ensureProviderEarningsWindowIndex\nBRIN CONCURRENTLY + analyze cadence]
  F2 --> G[SeedKey admin key]
  B -- no, ALLOW_MEMORY_STORE=true --> H[NewMemory + 15 min pruner]
  B -- no --> X[exit 1]
  D -. any error .-> X
```

### Table families

Roughly forty tables; grouped by what would be lost if the family vanished.

| Family | Tables | Notes |
|---|---|---|
| Identity and access | `api_keys`, `users`, `device_codes`, `provider_tokens`, `publishing_api_keys`, `invite_codes`, `invite_redemptions` | Keys are stored as hashes with a display prefix; `users` carries the Stripe Connect fields. |
| Money | `balances`, `ledger_entries`, `billing_sessions`, `model_prices`, `referrers`, `referrals`, `stripe_withdrawals`, `global_payout_recipients`, `global_payout_withdrawals`, `provider_earnings`, `earnings_summary`, `provider_payouts`, `provider_floor_draws`, `payments` (legacy) | The ledger is append-only; `balances` is the materialised view of it. `model_prices.cache_read_price` is nullable: `NULL` means the row sets no cache-read rate and billing derives one from `input_price` (`payments.RatesFor`). Semantics in [`billing.md`](billing.md). |
| Public model demand | `model_demand_requests`, `model_demand_hourly`, `model_demand_collection` | One compact projection per scoped coordinator UUID, hourly counters updated atomically by trigger, and a persistent collection epoch; `coordinator/store/postgres/model_demand_migration.go`, `coordinator/store/postgres/model_demand.go`. |
| Usage and routing telemetry | `usage`, `usage_totals`, `inference_routes`, `request_rejections`, `request_profiles`, `fleet_snapshots`, `request_outcomes` | Row per request, per dispatched attempt, per rejection, per profiled attempt, per fleet sample; `usage_totals` is a single-row counter seeded at boot by `checkRetiredBackfills` and incremented by `RecordUsage`. `usage.cached_tokens` (`INTEGER NOT NULL DEFAULT 0`) is the subset of `prompt_tokens` billed at the cache-read rate; rows written before the column existed read 0, which is what they were billed. It and `model_prices.cache_read_price` are added by plain `ALTER TABLE … ADD COLUMN IF NOT EXISTS` statements, not exception-swallowing `DO` blocks. Settlement reads and writes both columns, so if either cannot be added (a lock timeout, a missing privilege), startup fails rather than boot a coordinator that bills at the default rates and drops usage rows. |
| Provider fleet and trust | `providers`, `provider_reputation`, `provider_sessions`, `provider_trust_reuse`, `provider_verification_jobs`, `code_attestations`, `code_attest_push_budgets`, `provider_log_reports` | Trust reuse and code attestations are durable. `code_attestations.continuous_coverage_until` is compare-and-updated only for the exact original proof tuple; it never refreshes `attested_at` or inserts proof. This allows bounded same-process resume after a redeploy; see [`security/attestation.md`](security/attestation.md). `provider_log_reports.serial_number` is kept empty by trigger. |
| Models and releases | `model_registry`, `model_versions`, `model_version_files`, `model_active_versions`, `model_aliases`, `releases` | The catalog the registry syncs at boot; see [`model-registry.md`](model-registry.md). |
| Cache routing state | `cache_routing_holders`, `cache_routing_demand`, `cache_routing_meta` | Write-behind copy of the registry's in-memory exact prefix-cache holder index and observed-demand index, so a restart does not start from an empty index (`coordinator/store/postgres/cacheroutingstate.go`, `coordinator/store/cacheroutingstate/records.go`, `coordinator/registry/cachepersist/persister.go`). Holders are keyed by boundary key plus the provider's cache epoch (a UUID the provider mints per model SSD root and persists), never by connection-scoped provider ID; rows name a boundary by its keyed identifier (the HMAC output under the route key; the key material itself is never stored) and token count, plus the Ready fallback and measured stage costs; the provider-confirmed chain hash is not stored, and no prompt content is. Rows are pruned in 10,000-row batches every five minutes under the active routing TTL (the effective expiry is the earlier of the stored one and `updated_at` plus the TTL, indexed on both columns), so a longer past TTL cannot leave rows in the table after they stopped loading; rows stamped more than a minute ahead of the pruning clock (a previous instance's skew) are removed too, at boot and on every prune, so a current receipt is never outranked by a quarantined future timestamp. `cache_routing_meta` records a non-secret fingerprint of the cache-key generation (HMAC of the master key over every key-derivation label, the block contract and a persistence generation, `deriveCacheKeys`); nothing is written before a boot has recorded it; a boot under a different master key finds rows whose keys can never match a request again and empties both tables with unconditional bounded deletes, recording the new generation last, instead of restoring them (`cachepersist.Restore`, `ResetCacheRoutingState`). Loads apply the current TTL to each row's expiry before ordering and capping. Losing the tables costs minutes of hit rate, nothing else. |
| Bookkeeping | `schema_migrations` | Completion markers for one-shot data migrations. |

### Global Payouts state

Claims, result application and definitive-rejection records use one locked PostgreSQL mutation boundary (`coordinator/store/postgres/global_payouts.go`, `mutateGlobalPayout`). Operation-specific checks run under the withdrawal row lock; any refund ledger entry and payout update commit together. A no-op claim rolls back without changing the lease or dispatch count.

Payouts marked `manual_reconciliation_required` without an external payment ID are excluded from automatic scans and claims; their pending row and debit are retained. A verified external ID permits readback reconciliation to resume (`coordinator/store/global_payouts.go`, `GlobalPayout.RequiresManualReconciliation`).

Global Payouts uses separate recipient and withdrawal tables with immutable request data, persisted dispatch counts, definitive rejection records, an indexed quote expiry and a unique external-payment index. `GlobalPayoutStore` is accessed through `store.As` so decorators preserve the capability. These mutations do not write the cached users table. The migration creates the payout tables and adds/backfills indexed quote expiry for an earlier Global Payouts schema (`coordinator/store/postgres/global_payouts.go`, `globalPayoutSchema`). Cleanup locks and removes only expired, never-confirmed quotes in bounded batches; confirmed payout and ledger records are retained (`coordinator/store/`, `PruneExpiredGlobalPayoutQuotes`).

Quote invalidation is serialized with confirmation. An invalidation flag prevents an earlier request timestamp from admitting a canceled quote; an already-confirmed payout is returned unchanged for reconciliation (`coordinator/store/`, `ExpireGlobalPayoutQuote`).

### Retention and pruning

The store keeps most business rows forever; the loops that exist are narrow.

| Loop | Where | What it bounds |
|---|---|---|
| Model demand retention, hourly | `coordinator/api/observation/profiler_fleet.go` (`pruneTelemetryOnce` → `PruneModelDemand`) | Compact request projections and hourly aggregates expire after `ModelDemandRetention = 31 * 24 * time.Hour`. PostgreSQL bounds each table's deletes by the requested batch size, using short transactions with 2 s lock timeouts; the partial cutoff hour is preserved and committed progress survives an error. Detailed ledger retention is unchanged. |
| Profiler retention sweep, hourly | `coordinator/api/observation/profiler_fleet.go` (`StartProfilerLoops` → `PruneTelemetry`) | `request_outcomes` by receipt time, plus `request_profiles` and `fleet_snapshots` older than their retention windows ([telemetry-inventory](../reference/telemetry-inventory.md#coordinator-per-request-records-postgres)), in batches; runs even when the profiler is off. |
| Memory-store pruner, every 15 minutes | `coordinator/app/store.go` (`memory_store_pruner`, `MemoryStore.Prune`) | Append-only history slices to `DefaultPruneMaxEntries` (100 000); memory store only. |
| Session reconciliation, once at boot | `coordinator/app/store.go` (`CloseOpenProviderSessions`) | Closes `provider_sessions` rows whose last heartbeat is more than 3 minutes old, so a blue-green cutover does not truncate live sessions. |
| Read-cache janitor, every minute | `coordinator/api/server.go` (`StartReadCacheJanitor`) | In-process response cache, not a table. |

The existing nullable `request_rejections.could_have_served` column stores NULL
when counterfactual servability is not evaluated. Go reads it as `*bool`
(`coordinator/store/interface.go`, `RejectionRecord`); both stores preserve
unknown, false, and true. This requires no schema migration.

`usage`, `inference_routes`, `request_rejections` and `ledger_entries` have no
automatic retention. `DeleteExpiredDeviceCodes` exists on the interface but has
no scheduled caller.

### Provider-side local storage

| What | Where | Owner |
|---|---|---|
| Configuration | `~/.config/darkbloom/provider.toml` (legacy `~/.darkbloom/provider.toml` is still read) | `provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift` |
| Device-auth token | `~/.darkbloom/auth_token` | `provider-swift/Sources/ProviderCore/Auth/DeviceAuth.swift` |
| Daemon state, PID, warm-model journal, watchdog state, KV-backend crash guard | `~/.darkbloom/daemon-state.json`, `provider.pid`, `loaded-models.json`, `watchdog-state.json`, `kv-backend-guard.json` | `provider-swift/Sources/ProviderCore/Service/` |
| Direct-mode token and discovery file | `~/.darkbloom/local_token`, `~/.darkbloom/local.json` | `provider-swift/Sources/ProviderCore/Server/LocalEndpoint.swift` |
| Logs | `~/.darkbloom/provider.log`, `~/.darkbloom/watchdog.log`; unified logging via `darkbloom logs` | `provider-swift/Sources/ProviderCore/Service/LaunchAgent.swift`, `WatchdogAgent.swift` |
| Binaries | `~/.darkbloom/Darkbloom.app`, symlinks in `~/.darkbloom/bin/` | `scripts/install.sh` |
| Model weights | `~/.cache/huggingface/hub` | `provider-swift/Sources/ProviderCore/Models/ModelDownloader.swift` |
| SSD prefix cache | `~/Library/Caches/darkbloom/kv3/<model>/` — encrypted blocks; default budget under [size and eviction rules](../reference/ssd-kv-cache.md#size-and-eviction-rules) | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCacheFactory.swift`; format in [`../reference/ssd-kv-cache.md`](../reference/ssd-kv-cache.md) |
| KV key-encryption key | Keychain item, service `io.darkbloom.kv.kek.v1`, access group `SLDQ2GJ6TL.io.darkbloom.provider`, wrapped by a Secure Enclave key | `provider-swift/Sources/ProviderCore/KVCache/WrappedKEKStorage.swift`, `Security/PersistentEnclaveKey.swift` |
| Fan helper policy | `/Library/Application Support/Darkbloom/fan-policy.json`, `fan-session.json` | [`../provider/fan-control.md`](../provider/fan-control.md) |

Every file path in the first four rows can be moved with the `DARKBLOOM_*`
variables in [`../reference/configuration.md`](../reference/configuration.md).
Sealed request plaintext never reaches disk on a provider; the SSD cache holds
KV blocks under a per-model key, not tokens.

## Invariants

1. **A production coordinator never runs on the memory store.**
   `store.Config.Check` fails and `main` exits unless a DSN is present or the
   memory store is opted into by name (`coordinator/store/config.go`,
   `coordinator/app/store.go`).
2. **Schema changes ship with the binary and are idempotent.** Every statement
   in `PostgresStore.migrate` can run on an already-migrated database; the
   process serves traffic only after the whole slice succeeds
   (`coordinator/store/postgres/`).
3. **Committed migration progress is not applied twice.** One-shot data
   migrations commit their `schema_migrations` marker in the same statement or
   transaction as their update (`coordinator/store/postgres/`,
   `coordinator/internal/store/privacysql/logs.go`).
4. **Boot never holds a long lock on a hot table.** The
   `provider_earnings(job_id)` unique index is built `CONCURRENTLY`, only after
   a duplicate check, and skipped when already valid; the dedupe that violated
   this lives in `coordinator/store/postgres/migrations/dedupe_provider_earnings.sql` and
   is manual (`ensureProviderEarningsJobIndex`). The time index
   `idx_provider_earnings_created_at_brin` is also built `CONCURRENTLY`, with
   `autosummarize=on`; a valid index is retained and an interrupted invalid
   build fails startup pending operator repair. The table's
   `autovacuum_analyze_scale_factor` is `0.005` so planner statistics track
   ingestion (`ensureProviderEarningsWindowIndex`,
   `coordinator/store/postgres/earnings_window_index.go`).
5. **Money is micro-USD integers in an append-only ledger.** `LedgerStore`
   and `balances` never store floats; see
   [`billing.md#invariants`](billing.md#invariants).
6. **Nothing prompt-derived is persisted.** `TelemetryStore` rows carry token
   counts, timings and outcomes only; the `serial_number` column of
   `provider_log_reports` and the legacy `cache_affinity_key` column are kept
   empty by triggers (`coordinator/internal/store/privacysql/logs.go`,
   `legacyCacheAffinityGuardTrigger` in `coordinator/store/postgres/`).
7. **Provider secrets never leave the Keychain in the clear.** The KV KEK is
   wrapped by a Secure Enclave key and the SSD cache is unreadable without it
   (`provider-swift/Sources/ProviderCore/KVCache/WrappedKEKStorage.swift`).

## Failure modes

| Symptom | Cause | Where to look |
|---|---|---|
| Coordinator exits 1 at boot with `store: run migrations` | A DDL statement failed (permissions, a hand-edited schema, or a `CREATE INDEX` waiting on a lock) | The logged statement; `pg_stat_activity` for blockers. |
| Boot fails with `database holds data that retired backfills never processed` or `balances.withdrawable_micro_usd is missing` | The database has billing, usage or earnings history but never ran a backfill retired after v0.9.10 | Boot a coordinator built from v0.9.10 (which still runs them) against it once, then redeploy (`checkRetiredBackfills`). |
| Boot fails with an actionable `provider_earnings` duplicate message | Rows share a non-empty `job_id`, so the unique index cannot be built | Run `dedupe_provider_earnings.sql` offline, then redeploy. |
| `EIGENINFERENCE_DATABASE_URL is required in production` | No DSN and no memory-store opt-in | The environment file; see [`../operations/coordinator-deploy.md`](../operations/coordinator-deploy.md). |
| Billing or key state gone after a restart | The process ran on the memory store | Startup log line `using in-memory store`. |
| `/v1/stats` slow and pool saturated | Full scans on `usage` holding connections; the 80-connection floor is the mitigation, not a fix | `pg_stat_activity`; the read cache. |
| `request_waterfall` view missing after a fresh database | It is applied by hand, not at boot | `coordinator/store/postgres/migrations/request_waterfall.sql`. |
| Provider re-challenged after every coordinator deploy | Trust-reuse rows missing (memory store) or `provider_trust_reuse` revoked | [`security/attestation.md`](security/attestation.md). |
| Provider SSD cache empty after reboot | Budget clamp or block TTL ([size and eviction rules](../reference/ssd-kv-cache.md#size-and-eviction-rules)), or the KEK item missing | [`../reference/ssd-kv-cache.md`](../reference/ssd-kv-cache.md); `darkbloom doctor`. |

## Code map

| Concern | Location |
|---|---|
| Interface and record types | `coordinator/store/interface.go`, `coordinator/store/interface_domains.go` |
| Earnings rankings and startup time index | `coordinator/store/postgres/leaderboard.go` (`Leaderboard`), `coordinator/store/postgres/earnings_window_index.go` (`ensureProviderEarningsWindowIndex`), `coordinator/store/postgres/startup.go` (`ensureConcurrentIndex`) |
| Backend selection and validation | `coordinator/store/config.go`, `coordinator/app/store.go` |
| Postgres pool, schema, one-shot migrations | `coordinator/store/postgres/`, `coordinator/internal/store/privacysql/logs.go`, `coordinator/store/postgres/retired_backfills.go` |
| Provider identity and usage reads | `coordinator/store/postgres/provider_read.go` (`providerRecordColumns`, `scanProviderRecord`, `GetProviderRecord`); `coordinator/store/` (`GetProviderForRestore`, using the same projection); `coordinator/store/postgres/usage_read.go` (`readUsageRecords`, `UsageRecords`); `coordinator/store/postgres/row.go` (`rowScanner`) |
| Domain files | `coordinator/store/postgres/model_registry.go`, `coordinator/store/postgres/base_rewards.go`, `coordinator/store/postgres/profiles.go`, `coordinator/store/`, `coordinator/store/`, `coordinator/store/apikey.go` |
| Memory backend | `coordinator/store/memory/`, `coordinator/store/memory/base_rewards.go` |
| Manual SQL | `coordinator/store/postgres/migrations/` |
| Persistent-disk state outside Postgres (MicroMDM, journals) | `coordinator/deploy/start.sh`, `coordinator/internal/provider/journal/trust_reuse_journal.go`, [`../operations/state-export.md`](../operations/state-export.md) |
| Provider files and Keychain | `provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift`, `provider-swift/Sources/ProviderCore/Service/`, `provider-swift/Sources/ProviderCore/KVCacheSSD/`, `provider-swift/Sources/ProviderCore/KVCache/WrappedKEKStorage.swift` |

## Related

- [`../reference/configuration.md`](../reference/configuration.md) — `EIGENINFERENCE_DATABASE_URL`, `EIGENINFERENCE_ALLOW_MEMORY_STORE`, `USER_PERSISTENT_DATA_PATH` and the provider path overrides
- [`billing.md`](billing.md) — what the money tables mean
- [`telemetry.md`](telemetry.md) and [`system-profiler.md`](system-profiler.md) — what fills the telemetry tables
- [`model-registry.md`](model-registry.md) — the catalog tables
- [`security/attestation.md`](security/attestation.md) — the trust-reuse and code-attestation caches
- [`prefix-cache.md`](prefix-cache.md) and [`../reference/ssd-kv-cache.md`](../reference/ssd-kv-cache.md) — the provider's on-disk cache
- [`../operations/state-export.md`](../operations/state-export.md) — exporting the non-Postgres state on the persistent disk
- [`../operations/coordinator-deploy.md`](../operations/coordinator-deploy.md) — where the DSN is set

## Model token grants

`coordinator/store/postgres/model_token_promotions_schema.go` (`modelTokenPromotionDDL`) adds `model_token_promotions`, account/model keyed `model_token_grants`, durable `model_token_reservations`, and provider-account keyed `model_token_provider_carries`. The carry row retains a sub-micro-dollar payout remainder in `[0, 100000000)`; the additive table also works when upgrading an existing promotion schema. Promotion model IDs deliberately do not reference the model registry, allowing pre-launch setup. The promotion row serializes claims, enforces the maximum claim count and validates the user table’s authoritative account creation timestamp. Account/model uniqueness makes duplicate claims idempotent. Grant counters enforce nonnegative usage/reservations and prevent their sum from exceeding the grant. Reservation terminal state prevents duplicate spending, refunds and provider credit. Claim windows do not expire previously issued grants.

`coordinator/store/postgres/model_token_settlement.go` (`SettleModelTokenReservation`) updates grant usage, consumer money, fractional payout carry and provider earnings in one transaction, locking balance rows in account order before the carry row. `coordinator/store/postgres/model_token_earnings.go` (`carryModelTokenEarningPostgres`) updates the remainder; the reservation persists the credited whole-micro-dollar payout so replay returns the original result without accumulating fractions again. The optional backend capability is discovered through `store.As`; grants bypass the user/model read-through caches and no user/model invalidation is needed. Lease recovery is in `coordinator/store/` (`ReleaseStaleModelTokenReservations`). Operational details: [model token promotions](../operations/model-token-promotions.md).

### Stripe migration settlement

`StripeSettlementStore` (`coordinator/store/stripe_settlement.go`) is discovered
through `store.As`. `CompleteStripeCheckout` locks the local session and commits
the deposit and completion together. `RefundRejectedStripeWithdrawal` locks the
withdrawal, checks the shared refund ledger reference, and commits the credit and
flag together. A durable confirmed-rejection marker makes failed refund writes
retryable; unverified old rows remain for operator review. These methods do not
write cached user records.

`RemoveGlobalRecipient` resets the row to a new empty generation instead of
deleting it. The retained row fences routing to Global Payouts after unlink or
country-policy rollback and invalidates old unconfirmed quotes. Historical
withdrawals retain their immutable destination and source data. Legacy Connect
user IDs remain available for old payout events. The maintenance tool uses an
existing pool through `StripeSettlementForMaintenance` without startup migrations.

## Autopilot operation ledger

`coordinator/store/postgres/autopilot.go` (`autopilotDDL`, `RecordAutopilot`)
creates `autopilot_events`, keyed by `(command_id, phase)` with an indexed `at`
timestamp and a bounded typed JSON record. Insert retries are idempotent. The
ledger stores model/control metadata without prompts or free-form provider
errors. A command intent is persisted before dispatch; failed writes prevent new
changes and terminal observations remain queued for retry. Incomplete historical
phases remain unresolved evidence, not an inferred rollback. Reads use bounded
windows. Records currently have no automatic deletion; preservation and archive
policy can be added independently. `MemoryStore` provides equivalent test/dev
semantics without restart durability. See [Autopilot](model-autopilot.md).

`coordinator/registry/provider_lifecycle.go` (`disconnectProvider`) queues an
`uncertain` record for a pending operation before removing its provider state.
The normal ledger flush persists it outside registry/provider
locks and retains it for retry on database failure. A dropped connection is not
a confirmed failure, success or rollback; intended and actual residency must not
be conflated (`coordinator/registry/autopilot_events.go`, `flushAutopilotEvents`).

Shadow `proposed` phases form a decision ledger, not a per-tick time series. Their
stable SHA-256 identity covers the provider session, consent revision,
workload, reason, target, unload set and prior actual resident/selected state.
Capacity sequence, time and predicted benefit are excluded, so unchanged
decisions reuse the same key. Store idempotency retains the first record, including
its timestamp and benefit; distinct state, session or revision decisions remain
retained. Live command UUIDs are unchanged (`coordinator/registry/autopilot_events.go`,
`autopilotProposalID`; `RecordAutopilot`). This deduplication is not an
absolute database retention cap.

An unchanged decision can age outside the admin endpoint's recent-events window
while the current tick summary remains fresh. Proposals are not dispatched
commands, residency changes or live capacity evidence; see the
[API contract](../reference/api-contracts.md#experimental-model-autopilot).
