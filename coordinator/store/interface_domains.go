package store

// Domain sub-interfaces composed into Store (see interface.go).
//
// Store was a ~150-method god-interface that forced parallel memory.go /
// postgres.go implementations and gave callers no way to depend on a narrow
// slice of the persistence surface. It is split here into cohesive,
// single-domain sub-interfaces; Store embeds all of them, so the full method
// set — and both implementations — are unchanged. The split is purely
// organizational: every method keeps its exact signature and semantics.

import (
	"context"
	"encoding/json"
	"time"
)

// APIKeyStore covers consumer API-key lifecycle: the legacy single-key helpers,
// multi-key management (one account → many named, limited keys), and key counts.
type APIKeyStore interface {
	// CreateKey generates a new API key, persists it, and returns it.
	CreateKey() (string, error)

	// CreateKeyForAccount generates a new API key linked to a specific account.
	CreateKeyForAccount(accountID string) (string, error)

	// ValidateKey returns true if the given key exists and is active.
	ValidateKey(key string) bool

	// GetKeyAccount returns the account ID that owns this key, or "" if unlinked.
	GetKeyAccount(key string) string

	// ValidateKeyFull returns the active status and owner account ID for an
	// API key in a single query, avoiding the 2-query overhead of
	// ValidateKey + GetKeyAccount on every authenticated request.
	ValidateKeyFull(key string) (active bool, ownerAccountID string, err error)

	// RevokeKey deactivates a key. Returns true if the key existed.
	RevokeKey(key string) bool

	// --- Multi-key management (one account → many named, limited keys) ---

	// CreateAPIKey mints a new API key for an account with optional per-key
	// limits. It returns the raw key (shown once) and the stored record.
	CreateAPIKey(accountID string, opts APIKeyCreate) (rawKey string, key *APIKey, err error)

	// ListAPIKeys returns all (non-deleted) keys owned by an account, newest
	// first. Secrets are never returned — only the masked label + metadata.
	ListAPIKeys(accountID string) ([]APIKey, error)

	// GetAPIKeyByID returns a single key by its public ID, scoped to the owner.
	GetAPIKeyByID(accountID, id string) (*APIKey, error)

	// UpdateAPIKey overwrites the mutable fields (name, disabled, limits,
	// reset window, expiry, model allow-list) of a key, scoped to the owner.
	// The caller supplies the fully-merged desired state; nil pointers clear
	// the corresponding limit.
	UpdateAPIKey(accountID, id string, mutable APIKey) (*APIKey, error)

	// RevokeAPIKeyByID permanently deletes a key by ID, scoped to the owner.
	RevokeAPIKeyByID(accountID, id string) error

	// RotateAPIKey atomically replaces a key: it mints a new secret carrying the
	// old key's name, limits, expiry, and disabled state, deletes the old key,
	// and returns the new raw secret + record — all in one transaction/critical
	// section so the old key is never usable after success and a concurrent
	// rotate of the same key cannot mint two replacements. Scoped to the owner.
	RotateAPIKey(accountID, id string) (rawKey string, key *APIKey, err error)

	// AuthenticateKey resolves a raw key to its active record for request
	// authentication. It returns an error when the key is unknown, disabled,
	// or expired. The returned record carries the owner account and per-key
	// limits used by the request path.
	AuthenticateKey(rawKey string) (*APIKey, error)

	// TouchAPIKey records that a key was used at the given time (last_used_at).
	// Best-effort; callers typically invoke it asynchronously and throttled.
	TouchAPIKey(id string, at time.Time)

	// KeySpendSince returns the total micro-USD charged to the given key ID
	// since the given UTC time. Zero `since` returns lifetime spend. Used to
	// enforce per-key spend caps before the ledger reservation.
	KeySpendSince(keyID string, since time.Time) int64

	// KeyCount returns the number of active API keys.
	KeyCount() int
}

// UsageStore records inference usage events and settled payments and serves the
// usage/stats aggregations (totals, time series, geo, leaderboards).
type UsageStore interface {
	// RecordUsage logs an inference usage event.
	RecordUsage(providerID, consumerKey, model string, promptTokens, completionTokens int)

	// RecordUsageWithCost logs an inference usage event including request ID and cost.
	RecordUsageWithCost(providerID, consumerKey, model, requestID string, promptTokens, completionTokens int, costMicroUSD int64)

	// RecordUsageWithCostAndLocation logs an inference usage event with an
	// approximate request-origin location. Raw IP addresses are not stored.
	RecordUsageWithCostAndLocation(providerID, consumerKey, model, requestID string, promptTokens, completionTokens int, costMicroUSD int64, requestLocation *ProviderLocation)

	// RecordUsageFull logs an inference usage event with full attribution
	// including the originating API key ID (for per-key usage and spend
	// tracking). keyID may be empty for legacy/account-scoped attribution.
	RecordUsageFull(providerID, consumerKey, keyID, model, requestID string, promptTokens, completionTokens int, costMicroUSD int64, requestLocation *ProviderLocation)

	// RecordUsageFullWithPublicModel logs the concrete billing/statistics model
	// plus the optional consumer-facing model name returned by usage history.
	RecordUsageFullWithPublicModel(providerID, consumerKey, keyID, model, publicModel, requestID string, promptTokens, completionTokens int, costMicroUSD int64, requestLocation *ProviderLocation)

	// RecordPayment records a settled payment between consumer and provider.
	RecordPayment(txHash, consumerAddr, providerAddr, amountUSD, model string, promptTokens, completionTokens int, memo string) error

	// UsageRecords returns all usage records.
	UsageRecords() []UsageRecord

	// UsageRecordsSince returns usage records created at or after the given time.
	// Zero since returns all records.
	UsageRecordsSince(since time.Time) []UsageRecord

	// UsageCountSince returns the number of usage records created at or after
	// the given time. Zero since returns all records. Uses SQL COUNT(*) to
	// avoid transferring rows over the wire.
	UsageCountSince(since time.Time) int64

	// UsageTotals returns aggregated lifetime totals across all usage records
	// without transferring per-row data over the wire.
	UsageTotals() UsageTotals

	// UsageTimeSeries returns per-minute aggregates for the given time window.
	// Buckets the rows by created_at truncated to the minute.
	UsageTimeSeries(since time.Time) []UsageBucket

	// UsageLocationBuckets returns approximate request-origin aggregates for
	// public stats. Implementations must not store or return raw client IPs.
	UsageLocationBuckets(since time.Time) []UsageLocationBucket

	// UsageFlowBuckets returns aggregated directional flow buckets between
	// consumer and provider regions. providerLocs supplies live provider
	// locations from the registry so recently-connected providers that
	// haven't been persisted yet are included. PostgresStore uses a SQL
	// JOIN with the providers table and merges the live map; MemoryStore
	// uses providerLocs directly.
	UsageFlowBuckets(since time.Time, providerLocs map[string]*ProviderLocation) []UsageFlowBucket

	// Leaderboard returns the top N accounts ranked by the given metric
	// over the given time window. Zero `since` means all-time.
	Leaderboard(metric LeaderboardMetric, since time.Time, limit int) []LeaderboardRow

	// NetworkTotals returns aggregated metrics across the network for the
	// given window. Zero `since` means all-time.
	NetworkTotals(since time.Time) NetworkTotalsRow

	// UsageByConsumer returns usage records for a specific consumer key.
	UsageByConsumer(consumerKey string) []UsageRecord
}

// TelemetryStore persists routing-decision snapshots and rejection records
// (privacy-safe, no prompt/response content). Forwarded to Datadog elsewhere.
type TelemetryStore interface {
	// RecordInferenceRoute writes or refreshes the routing decision snapshot for a
	// request attempt. Best-effort; failures must not block inference.
	RecordInferenceRoute(record *InferenceRouteRecord) error

	// UpdateInferenceRouteOutcome updates the attempt with final outcome data
	// (tokens, timing, error). Best-effort; failures must not block inference.
	UpdateInferenceRouteOutcome(requestID string, attempt int, outcome *InferenceRouteOutcome) error

	// InferenceRouteRecordsSince returns routing records created at or after the
	// given time. Zero since returns all records.
	InferenceRouteRecordsSince(since time.Time) []InferenceRouteRecord

	// RecordRejection writes a rejected-request record (4xx/5xx) with its
	// counterfactual servability snapshot. Best-effort; failures must not block
	// the request path.
	RecordRejection(record *RejectionRecord) error

	// RejectionRecordsSince returns rejection records created at or after the
	// given time. Zero since returns all records.
	RejectionRecordsSince(since time.Time) []RejectionRecord
}

// LedgerStore is the double-entry balance ledger (all amounts in micro-USD).
type LedgerStore interface {
	// GetBalance returns the current balance in micro-USD for an account.
	GetBalance(accountID string) int64

	// Credit adds micro-USD to an account and records the ledger entry.
	Credit(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error

	// Debit subtracts micro-USD from an account. Returns error if insufficient funds.
	Debit(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error

	// GetWithdrawableBalance returns the withdrawable balance in micro-USD.
	GetWithdrawableBalance(accountID string) int64

	// GetBalanceWithWithdrawable returns both the total balance and the
	// withdrawable balance in a single query, avoiding two round trips to
	// the same row in the balances table.
	GetBalanceWithWithdrawable(accountID string) (balance int64, withdrawable int64)

	// CreditWithdrawable adds micro-USD to both the total balance and the
	// withdrawable balance, and records a ledger entry. Use for provider
	// earnings, referral rewards, and admin rewards.
	CreditWithdrawable(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error

	// CreditWithdrawableOnce is CreditWithdrawable made idempotent on
	// (entryType, reference): if a ledger entry with the same type and
	// reference already exists, the credit is skipped and applied=false.
	// Use for refunds driven by Stripe webhooks, where redelivery (or a
	// crash between the credit and the row persist) must never credit the
	// same refund twice.
	CreditWithdrawableOnce(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) (applied bool, err error)

	// DebitWithdrawable subtracts micro-USD from both the total balance and
	// the withdrawable balance atomically. Returns error if withdrawable
	// balance is insufficient. Use for Stripe Connect withdrawals so the
	// debit is symmetric with CreditWithdrawable refunds.
	DebitWithdrawable(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error

	// LedgerHistory returns ledger entries for an account, newest first.
	LedgerHistory(accountID string) []LedgerEntry

	// MigrateAccountBalance atomically moves the entire balance (and its
	// withdrawable subset) from one account ID to another, merging into the
	// destination, and records ledger entries on both sides. Returns moved=true
	// when funds were transferred; it is a no-op (moved=false) when the source
	// has no balance. Used to carry an unlinked legacy key's funds from its old
	// raw-token identity to the hashed identity (see LegacyAccountID).
	MigrateAccountBalance(from, to string) (moved bool, err error)
}

// BillingStore covers referrals, billing (deposit) sessions, custom per-account
// model pricing, and Stripe Connect withdrawals.
type BillingStore interface {
	// --- Referral System ---

	// CreateReferrer registers an account as a referrer with the given code.
	CreateReferrer(accountID, code string) error

	// GetReferrerByCode returns the referrer for a given referral code.
	GetReferrerByCode(code string) (*Referrer, error)

	// GetReferrerByAccount returns the referrer record for an account, if registered.
	GetReferrerByAccount(accountID string) (*Referrer, error)

	// RecordReferral records that referredAccountID was referred by referrerCode.
	RecordReferral(referrerCode, referredAccountID string) error

	// GetReferrerForAccount returns the referrer code that referred this account, or "" if none.
	GetReferrerForAccount(accountID string) (string, error)

	// GetReferralStats returns referral statistics for a code.
	GetReferralStats(code string) (*ReferralStats, error)

	// --- Billing Sessions ---

	// CreateBillingSession stores a new billing session (Stripe).
	CreateBillingSession(session *BillingSession) error

	// GetBillingSession retrieves a billing session by ID.
	GetBillingSession(sessionID string) (*BillingSession, error)

	// CompleteBillingSession marks a session as completed and sets the completion time.
	CompleteBillingSession(sessionID string) error

	// IsExternalIDProcessed returns true if a billing session with this external ID
	// has already been completed. Used to prevent double-crediting the same on-chain tx.
	IsExternalIDProcessed(externalID string) bool

	// --- Custom Pricing ---

	// SetModelPrice sets a custom price override for a model on an account.
	// Input and output prices are in micro-USD per 1M tokens.
	SetModelPrice(accountID, model string, inputPrice, outputPrice int64) error

	// GetModelPrice returns the custom price for a model on an account.
	// Returns (0, 0, false) if no custom price is set.
	GetModelPrice(accountID, model string) (inputPrice, outputPrice int64, ok bool)

	// ListModelPrices returns all custom price overrides for an account.
	ListModelPrices(accountID string) []ModelPrice

	// DeleteModelPrice removes a custom price override.
	DeleteModelPrice(accountID, model string) error

	// --- Stripe Withdrawals (bank/card payouts via Stripe Connect) ---

	// CreateStripeWithdrawal stores a new withdrawal record. The caller is
	// responsible for debiting the ledger atomically before calling this.
	CreateStripeWithdrawal(withdrawal *StripeWithdrawal) error

	// GetStripeWithdrawal returns a withdrawal by its internal UUID.
	GetStripeWithdrawal(id string) (*StripeWithdrawal, error)

	// GetStripeWithdrawalByPayoutID looks up a withdrawal by Stripe payout ID
	// (po_…). Used in payout.paid / payout.failed webhook handlers.
	GetStripeWithdrawalByPayoutID(payoutID string) (*StripeWithdrawal, error)

	// GetStripeWithdrawalByTransferID looks up a withdrawal by Stripe transfer
	// ID (tr_…). Used in transfer.failed webhook handlers.
	GetStripeWithdrawalByTransferID(transferID string) (*StripeWithdrawal, error)

	// UpdateStripeWithdrawal persists status/transfer/payout/fail-reason changes.
	UpdateStripeWithdrawal(withdrawal *StripeWithdrawal) error

	// ListStripeWithdrawals returns withdrawals for an account, newest first.
	// Pass limit <= 0 for no limit.
	ListStripeWithdrawals(accountID string, limit int) ([]StripeWithdrawal, error)

	// ListStripeWithdrawalsByStatus returns up to limit withdrawals in the
	// given status created before olderThan, oldest first. Used by the payout
	// reconciler to find withdrawals stuck in "transferred".
	ListStripeWithdrawalsByStatus(status string, olderThan time.Time, limit int) ([]StripeWithdrawal, error)

	// ListStripeWithdrawalsForStripeAccount returns withdrawals destined for
	// the given connected account (acct_…) in the given status, oldest first.
	// Used to resolve Stripe's automatic sweep payouts (whose IDs we never
	// see at creation time) back to local withdrawal rows.
	ListStripeWithdrawalsForStripeAccount(stripeAccountID, status string) ([]StripeWithdrawal, error)
}

// ModelRegistryStore is the manifest-backed model catalog plus the
// public-facing model aliases that resolve to concrete builds.
type ModelRegistryStore interface {
	// --- Model Registry (manifest-backed catalog) ---

	UpsertModelRegistryEntry(entry *ModelRegistryEntry) error
	SetModelVersion(entry *ModelRegistryEntry, version *ModelVersion, files []ModelVersionFile) error
	PromoteModelVersion(modelID, version string) error
	SetModelStatus(modelID, status string) error
	ListActiveModelRegistry() []ModelRegistryRecord
	ListActiveModelRegistryWithError() ([]ModelRegistryRecord, error)
	GetModelRegistryRecord(modelID string) (*ModelRegistryRecord, error)
	GetModelManifest(modelID string) (*ModelManifest, error)
	UpsertPublishingAPIKey(key *PublishingAPIKey) error
	FindPublishingAPIKeys() []PublishingAPIKey
	FindPublishingAPIKeysWithError() ([]PublishingAPIKey, error)
	MarkPublishingAPIKeyUsed(id string) error

	// --- Model Aliases (public-facing names → a desired concrete build) ---

	// UpsertModelAlias creates or replaces an alias definition (idempotent on
	// AliasID). The DesiredBuild/PreviousBuild pointers are stored verbatim;
	// resolution happens in the registry.
	UpsertModelAlias(alias *ModelAlias) error
	// GetModelAlias returns the alias by id; ok is false when not found.
	GetModelAlias(aliasID string) (alias *ModelAlias, ok bool, err error)
	// ListModelAliases returns every alias (active and inactive).
	ListModelAliases() ([]ModelAlias, error)
	// DeleteModelAlias removes an alias definition.
	DeleteModelAlias(aliasID string) error
}

// ReleaseStore tracks versioned provider binary releases.
type ReleaseStore interface {
	// SetRelease adds or updates a release in the store.
	SetRelease(release *Release) error

	// ListReleases returns all releases, ordered by created_at descending.
	ListReleases() []Release

	// GetLatestRelease returns the latest active release for a platform.
	GetLatestRelease(platform string) *Release

	// DeleteRelease deactivates a release by version and platform.
	DeleteRelease(version, platform string) error
}

// UserStore manages consumer accounts linked to Privy identities, including
// their Stripe Connect payout fields, role, and platform-fee override.
type UserStore interface {
	// CreateUser creates a new user record linked to a Privy identity.
	CreateUser(user *User) error

	// GetUserByPrivyID returns the user for a Privy DID.
	GetUserByPrivyID(privyUserID string) (*User, error)

	// GetUserByAccountID returns the user for an internal account ID.
	GetUserByAccountID(accountID string) (*User, error)

	// GetUserByEmail returns the user for an email address.
	GetUserByEmail(email string) (*User, error)

	// SetUserStripeAccount upserts the Stripe Connect fields on a user record.
	// Pass empty strings to clear the destination (e.g. before re-onboarding).
	// stripeAccountCountry is the ISO 3166-1 alpha-2 country the Express
	// account is locked to; empty leaves the column unchanged.
	SetUserStripeAccount(accountID, stripeAccountID, status, stripeAccountCountry, destinationType, destinationLast4 string, instantEligible bool) error

	// GetUserByStripeAccount finds a user by their Stripe connected account ID.
	// Used by webhook handlers to route account.updated / payout.* events.
	GetUserByStripeAccount(stripeAccountID string) (*User, error)

	// SetUserRole sets the account role (e.g. "" or RoleService). Used by the
	// admin API to grant a partner account elevated rate limits.
	SetUserRole(accountID, role string) error

	// SetUserPlatformFeePercent sets a per-account platform fee override.
	// Pass nil to clear the override and fall back to the global default.
	// A non-nil value of 0 waives the platform fee entirely.
	SetUserPlatformFeePercent(accountID string, feePercent *int64) error
}

// DeviceAuthStore covers the RFC 8628-style device authorization flow and the
// long-lived provider tokens it mints for device-linked provider machines.
type DeviceAuthStore interface {
	// --- Device Authorization (RFC 8628-style) ---

	// CreateDeviceCode stores a new device authorization request.
	CreateDeviceCode(dc *DeviceCode) error

	// GetDeviceCode returns a device code by its device_code value.
	GetDeviceCode(deviceCode string) (*DeviceCode, error)

	// GetDeviceCodeByUserCode returns a device code by its user-facing code.
	GetDeviceCodeByUserCode(userCode string) (*DeviceCode, error)

	// ApproveDeviceCode links a device code to an account, marking it approved.
	ApproveDeviceCode(deviceCode, accountID string) error

	// DeleteExpiredDeviceCodes removes device codes that have passed their expiry.
	DeleteExpiredDeviceCodes() error

	// --- Provider Tokens (device-linked auth) ---

	// CreateProviderToken stores a long-lived provider auth token linked to an account.
	CreateProviderToken(token *ProviderToken) error

	// GetProviderToken validates a provider token and returns it.
	GetProviderToken(token string) (*ProviderToken, error)

	// RevokeProviderToken deactivates a provider token.
	RevokeProviderToken(token string) error
}

// InviteStore manages coordinator-generated invite codes and their redemptions.
type InviteStore interface {
	// CreateInviteCode stores a new invite code.
	CreateInviteCode(code *InviteCode) error

	// GetInviteCode returns an invite code by its code string.
	GetInviteCode(code string) (*InviteCode, error)

	// ListInviteCodes returns all invite codes (admin view).
	ListInviteCodes() []InviteCode

	// DeactivateInviteCode sets active=false on an invite code.
	DeactivateInviteCode(code string) error

	// RedeemInviteCode atomically increments used_count and records the redemption.
	// Returns error if code is inactive, expired, fully used, or already redeemed by this account.
	RedeemInviteCode(code string, accountID string) error

	// HasRedeemedInviteCode checks if an account has already redeemed a specific code.
	HasRedeemedInviteCode(code, accountID string) bool
}

// ProviderEarningsStore tracks per-node provider earnings and payouts plus the
// base-rewards (earnings-floor) settlement machinery.
type ProviderEarningsStore interface {
	// --- Provider Earnings (per-node tracking) ---

	// RecordProviderEarning stores an earning record for a specific provider node.
	RecordProviderEarning(earning *ProviderEarning) error

	// GetProviderEarnings returns earnings for a specific provider node (by public key), newest first.
	GetProviderEarnings(providerKey string, limit int) ([]ProviderEarning, error)

	// GetAccountEarnings returns all earnings across all nodes for an account, newest first.
	GetAccountEarnings(accountID string, limit int) ([]ProviderEarning, error)

	// GetProviderEarningsSummary returns lifetime aggregates for a provider node
	// across ALL accounts that have ever owned the key.
	GetProviderEarningsSummary(providerKey string) (ProviderEarningsSummary, error)

	// GetAccountEarningsSummary returns lifetime aggregates for an account across all linked nodes.
	GetAccountEarningsSummary(accountID string) (ProviderEarningsSummary, error)

	// RecordProviderPayout stores a payout record for a provider wallet.
	RecordProviderPayout(payout *ProviderPayout) error

	// ListProviderPayouts returns all provider payout records in creation order.
	ListProviderPayouts() ([]ProviderPayout, error)

	// SettleProviderPayout marks a provider payout as settled.
	SettleProviderPayout(id int64) error

	// CreditProviderAccount atomically credits a linked provider account and
	// records the corresponding per-node earning.
	CreditProviderAccount(earning *ProviderEarning) error

	// CreditProviderWallet atomically credits an unlinked provider wallet and
	// records the corresponding payout history row.
	CreditProviderWallet(payout *ProviderPayout) error

	// --- Base Rewards (provider earnings floor) ---

	// SumProviderEarningsByKey returns total organic micro-USD for one provider
	// node in [since, until): amount>0, model != 'base_reward'. Self-route already
	// produces no earning row, so it needs no extra filter.
	SumProviderEarningsByKey(ctx context.Context, providerKey string, since, until time.Time) (int64, error)

	// SettleProviderFloorDraw atomically (1) inserts the idempotent draw row
	// (ON CONFLICT (provider_key, epoch_id) DO NOTHING) and (2) credits the
	// account's balance + withdrawable with a LedgerFloorDraw entry — but ONLY
	// when the row was newly inserted. Returns credited=false on a duplicate
	// epoch. A zero-amount draw still inserts the audit row but credits nothing.
	SettleProviderFloorDraw(ctx context.Context, draw *ProviderFloorDraw) (credited bool, err error)

	// SumFloorDrawsForEpoch returns Σ amount_micro_usd already settled for an
	// epoch (pool-cap accounting + admin status).
	SumFloorDrawsForEpoch(ctx context.Context, epochID string) (int64, error)

	// ListFloorDrawsForEpoch returns all draw rows for an epoch (admin status).
	ListFloorDrawsForEpoch(ctx context.Context, epochID string) ([]ProviderFloorDraw, error)

	// ListProviderSessionsOverlapping returns sessions whose lifetime interval
	// overlaps [start, end). Closed sessions end at disconnected_at; open sessions
	// may overlap via last_seen + openSessionGrace. The caller unions per machine
	// and clamps open sessions to min(end, last_seen + grace). Ordered by
	// serial_number, connected_at.
	ListProviderSessionsOverlapping(ctx context.Context, start, end time.Time, openSessionGrace time.Duration) ([]ProviderSession, error)

	// WithEpochSettlementLock runs fn while holding a cross-instance lock keyed
	// on epochID, so two coordinators cannot settle the same epoch concurrently
	// and overshoot the floor pool cap. The memory store runs fn directly; the
	// postgres store uses a session-level advisory lock.
	WithEpochSettlementLock(ctx context.Context, epochID string, fn func() error) error
}

// ProviderStore persists the provider fleet (records + connect/disconnect
// sessions), reputation, the APNs code-identity and live-MDM trust-reuse caches
// (durable across deploys), and provider log reports.
type ProviderStore interface {
	// --- Provider Fleet Persistence ---

	// UpsertProvider creates or updates a provider record.
	UpsertProvider(ctx context.Context, p ProviderRecord) error

	// GetProviderRecord returns a provider record by ID.
	GetProviderRecord(ctx context.Context, id string) (*ProviderRecord, error)

	// GetProviderBySerial returns a provider record by serial number.
	GetProviderBySerial(ctx context.Context, serial string) (*ProviderRecord, error)

	// GetMDAChainBySerial returns the newest NON-EMPTY Apple MDA cert chain stored
	// for a serial, or (nil, nil) if none. A reconnecting provider gets a new row
	// (keyed by a fresh provider id) that may be persisted with an empty chain
	// before the chain is reattached; GetProviderBySerial would return that newer
	// empty row and shadow a still-valid chain from a prior connection. This query
	// looks past empty rows so MDA reuse survives that race.
	GetMDAChainBySerial(ctx context.Context, serial string) (json.RawMessage, error)

	// ListProviderRecords returns all stored provider records.
	ListProviderRecords(ctx context.Context) ([]ProviderRecord, error)

	// ListProvidersByAccount returns stored provider records linked to an account.
	ListProvidersByAccount(ctx context.Context, accountID string) ([]ProviderRecord, error)

	// UpdateProviderLastSeen updates the last_seen timestamp for a provider.
	UpdateProviderLastSeen(ctx context.Context, id string) error

	// UpdateProviderTrust persists trust level and attestation state changes.
	UpdateProviderTrust(ctx context.Context, id string, trustLevel string, attested bool, attestationResult json.RawMessage) error

	// UpdateProviderChallenge persists challenge verification state.
	UpdateProviderChallenge(ctx context.Context, id string, lastVerified time.Time, failedCount int) error

	// UpdateProviderRuntime persists runtime integrity verification state.
	UpdateProviderRuntime(ctx context.Context, id string, verified bool, pythonHash, runtimeHash string) error

	// DeleteProvidersBySerial removes every persisted provider record sharing the
	// given stable identity (serial, or a session id when serial is empty),
	// scoped to ownerAccountID, plus their provider_reputation rows. usage,
	// provider_earnings and provider_sessions (billing/uptime history) are
	// preserved. Returns the number of provider rows removed.
	DeleteProvidersBySerial(ctx context.Context, ownerAccountID, serialOrID string) (int, error)

	// OpenProviderSession records the start of a provider connection (one row per
	// websocket session). serial/account may be empty at connect time and are
	// backfilled by TouchProviderSession once attestation/linking completes.
	OpenProviderSession(ctx context.Context, sessionID, serial, accountID string) error

	// TouchProviderSession updates the open session's last_seen heartbeat and
	// backfills serial/account/provider_key if they were unknown at open time.
	TouchProviderSession(ctx context.Context, sessionID, serial, accountID, providerKey string, lastSeen time.Time) error

	// CloseProviderSession marks the open session for sessionID as ended.
	CloseProviderSession(ctx context.Context, sessionID, reason string, when time.Time) error

	// CloseOpenProviderSessions closes sessions still marked open whose last
	// heartbeat (last_seen) predates staleBefore — i.e. genuinely orphaned by a
	// dead prior coordinator process. The staleBefore fence is what makes this
	// safe under a blue-green/rolling deploy over a shared DB: a session still
	// live on the OLD instance keeps getting TouchProviderSession heartbeats, so
	// its last_seen stays fresh and is NOT closed by the NEW instance's startup
	// reconcile. Returns the number of sessions closed.
	CloseOpenProviderSessions(ctx context.Context, staleBefore time.Time) (int, error)

	// --- Provider Reputation Persistence ---

	// UpsertReputation creates or updates a provider's reputation record.
	UpsertReputation(ctx context.Context, providerID string, rep ReputationRecord) error

	// GetReputation returns a provider's reputation record.
	GetReputation(ctx context.Context, providerID string) (*ReputationRecord, error)

	// --- APNs code-identity attestation reuse cache (survives deploys) ---

	// ListCodeAttestations returns all persisted code-identity attestation
	// records (for seeding the in-memory reuse cache at startup).
	ListCodeAttestations(ctx context.Context) ([]CodeAttestation, error)

	// UpsertCodeAttestation creates or updates the attestation record for a
	// device (keyed by SEPubKey). Called after a successful code-identity
	// round-trip; best-effort, must not block the read loop.
	UpsertCodeAttestation(ctx context.Context, rec CodeAttestation) error

	// DeleteCodeAttestation removes a device's persisted attestation record
	// (keyed by SEPubKey). Called when the device's APNs token CHANGES so a later
	// coordinator restart cannot reseed and reuse the pre-rotation proof — keeping
	// the "token change forces a real re-challenge" invariant durable across
	// restarts. Best-effort; must not block the read loop.
	DeleteCodeAttestation(ctx context.Context, seKey string) error

	// --- Provider trust-reuse cache (DAR-326 Phase 0) ---

	// ListProviderTrustReuse returns all persisted trust-reuse records (for
	// seeding the in-memory reuse cache at startup).
	ListProviderTrustReuse(ctx context.Context) ([]ProviderTrustReuse, error)

	// UpsertProviderTrustReuse creates or updates the trust-reuse record for a
	// device (keyed by SEPubKey). Called after a successful live MDM verification;
	// best-effort, must not block the read loop.
	UpsertProviderTrustReuse(ctx context.Context, rec ProviderTrustReuse) error

	// DeleteProviderTrustReuse removes a device's persisted trust-reuse record
	// (keyed by SEPubKey). Called when the provider is HARD-untrusted so a later
	// coordinator restart cannot reseed and fast-skip on a stale pre-untrust
	// record — keeping "hard untrust always takes effect" durable across restarts.
	// Best-effort; must not block the read loop.
	DeleteProviderTrustReuse(ctx context.Context, seKey string) error

	// --- Provider Log Reports ---

	// StoreLogReport stores a provider log report.
	StoreLogReport(serialNumber, providerID, accountID string, logData []byte) error

	// GetLogReports retrieves log reports for a serial number, newest first.
	GetLogReports(serialNumber string, limit int) ([]LogReport, error)

	// GetLogReport retrieves a single log report by ID.
	GetLogReport(id int64) (*LogReport, error)
}
