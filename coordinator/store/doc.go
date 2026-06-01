// Package store is the coordinator's persistence layer. It defines the Store
// interface and two interchangeable implementations: an in-memory store (the
// production default; provider state is lost on restart) and a Postgres store.
//
// The Store interface is composed from per-domain fragment interfaces
// (APIKeyStore, UsageStore, LedgerStore, ProviderStore, …); each fragment and
// its record/DTO types live in one file. Each implementation provides every
// method, verified at compile time by var _ Store = (*MemoryStore)(nil) and
// (*PostgresStore)(nil). MemoryStore guards all state with a single RWMutex;
// PostgresStore uses pgx with FOR UPDATE + CTE atomics for ledger correctness.
//
// Implementation methods are pinned to their receiver's package, so the
// memory_*.go and postgres_*.go files all live here, mirrored by domain. File
// map:
//
//	Interface, types & shared helpers
//	  interface.go            Store = composition of the per-domain fragments
//	  apikeys.go              APIKeyStore interface + APIKey record
//	  apikey.go               GenerateRawKey/GenerateKeyID/HashKey + KeyPrefix
//	  usage.go                UsageStore interface + leaderboard normalization
//	  ledger.go               LedgerStore interface + LedgerEntry, ErrInsufficientBalance
//	  referrals.go            ReferralStore interface + Referrer/ReferralStats
//	  billing_sessions.go     BillingSessionStore interface + BillingSession
//	  pricing.go              PricingStore interface + ModelPrice
//	  model_registry.go       ModelRegistryStore interface + records
//	  model_registry_common.go manifestFromRecord (record → ModelManifest)
//	  providers.go            ProviderStore interface + ProviderRecord, ProviderLocation
//	  reputation.go           ReputationStore interface + ReputationRecord
//	  provider_tokens.go      ProviderTokenStore interface + ProviderToken
//	  provider_earnings.go    ProviderEarningsStore interface + records
//	  device_codes.go         DeviceCodeStore interface + DeviceCode
//	  users.go                UserStore interface + User (Privy/Stripe linkage)
//	  invites.go              InviteStore interface + InviteCode
//	  releases.go             ReleaseStore interface + Release
//	  release_version.go      releaseVersionGreater semver compare
//	  stripe_withdrawals.go   StripeWithdrawalStore interface + records
//	  log_reports.go          LogReportStore interface + LogReport
//	  telemetry.go            TelemetryEventRecord persistence type
//	  config.go               Config (DatabaseURL, AllowMemoryStore, AdminKey)
//
//	In-memory implementation (methods on *MemoryStore)
//	  memory.go               MemoryStore struct, NewMemory, Prune, var _ Store
//	  memory_clone.go         clone helpers + CloneAccountData
//	  memory_apikeys.go       API key create/validate/list/revoke
//	  memory_balances.go      balances, ledger Credit/Debit/Withdrawable, history
//	  memory_billing.go       billing sessions + external-id idempotency
//	  memory_usage.go         RecordUsage variants + aggregation/leaderboard
//	  memory_users.go         user CRUD + Privy/email/Stripe lookups
//	  memory_referrals.go     referrer create + referral record/stats
//	  memory_model_registry.go model registry upsert/version/manifest
//	  memory_provider_records.go provider record upsert/get/list
//	  memory_provider_tokens.go provider token create/get/revoke
//	  memory_provider_earnings.go earnings record/get/summary
//	  memory_device_auth.go   device-code CRUD + approve
//	  memory_invites.go       invite-code CRUD + redeem
//	  memory_releases.go      release set/list/latest/delete
//	  memory_stripe_withdrawals.go withdrawal CRUD + payout/transfer lookups
//	  memory_log_reports.go   log-report store/get
//
//	Postgres implementation (methods on *PostgresStore)
//	  postgres.go             PostgresStore, NewPostgres, Close, migrate, var _ Store
//	  postgres_helpers.go     rowScanner, nullSince, provider-location marshal
//	  postgres_apikeys.go     apiKeyColumns + scanAPIKeyRow + key CRUD
//	  postgres_balances.go    balances + ledger atomics (FOR UPDATE + CTE)
//	  postgres_billing_sessions.go billing sessions + idempotency
//	  postgres_usage.go       RecordUsage variants + aggregation/leaderboard
//	  postgres_users.go       user CRUD (transaction-wrapped)
//	  postgres_referrals.go   referrer/referral persistence
//	  postgres_pricing.go     model price upsert/get/list/delete
//	  postgres_model_registry.go model registry persistence
//	  postgres_providers.go   providerColumns + scanProviderRow + upsert/trust
//	  postgres_provider_tokens.go provider token CRUD (SHA-256 hashing)
//	  postgres_earnings.go    earnings record/get/summary + leaderboard/totals
//	  postgres_reputation.go  reputation upsert/get
//	  postgres_device_auth.go device-code CRUD + approve
//	  postgres_invites.go     invite-code CRUD + atomic redeem
//	  postgres_releases.go    release set/list/latest/delete
//	  postgres_stripe_withdrawals.go withdrawal CRUD + idempotent lookups
//	  postgres_log_reports.go log-report store/get (paginated)
package store
