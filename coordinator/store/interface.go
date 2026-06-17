// Package store provides storage backends for API keys, usage tracking,
// balance management, and payment records.
//
// Two implementations are provided:
//   - MemoryStore: In-memory storage for development and testing. Data is
//     lost on restart. Suitable for single-instance coordinators.
//   - PostgresStore: PostgreSQL-backed storage for production. Provides
//     persistence, atomic balance operations, and multi-instance support.
//
// The store also manages a double-entry ledger for consumer and provider
// balances. All monetary amounts are in micro-USD (1 USD = 1,000,000
// micro-USD), which maps 1:1 to pathUSD's 6-decimal on-chain representation
// on the Tempo blockchain.
package store

import (
	"context"
	"encoding/json"
	"errors"
	"time"
)

// ErrInsufficientBalance is returned by Debit when the account has
// insufficient funds (or does not exist). Callers should check with
// errors.Is to distinguish this from transient DB errors.
var ErrInsufficientBalance = errors.New("insufficient balance or account not found")

// Store is the interface that all storage backends must implement.
type Store interface {
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

	// RecordInferenceRoute writes or refreshes the routing decision snapshot for a
	// request attempt. Best-effort; failures must not block inference.
	RecordInferenceRoute(record *InferenceRouteRecord) error

	// UpdateInferenceRouteOutcome updates the attempt with final outcome data
	// (tokens, timing, error). Best-effort; failures must not block inference.
	UpdateInferenceRouteOutcome(requestID string, attempt int, outcome *InferenceRouteOutcome) error

	// InferenceRouteRecords returns routing records created at or after the
	// given time. Zero since returns all records.
	InferenceRouteRecordsSince(since time.Time) []InferenceRouteRecord

	// RecordRejection writes a rejected-request record (4xx/5xx) with its
	// counterfactual servability snapshot. Best-effort; failures must not block
	// the request path.
	RecordRejection(record *RejectionRecord) error

	// RejectionRecordsSince returns rejection records created at or after the
	// given time. Zero since returns all records.
	RejectionRecordsSince(since time.Time) []RejectionRecord

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

	// KeyCount returns the number of active API keys.
	KeyCount() int

	// --- Balance Ledger ---

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

	// --- Releases (provider binary versioning) ---

	// SetRelease adds or updates a release in the store.
	SetRelease(release *Release) error

	// ListReleases returns all releases, ordered by created_at descending.
	ListReleases() []Release

	// GetLatestRelease returns the latest active release for a platform.
	GetLatestRelease(platform string) *Release

	// DeleteRelease deactivates a release by version and platform.
	DeleteRelease(version, platform string) error

	// --- Users (Privy) ---

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
	SetUserStripeAccount(accountID, stripeAccountID, status, destinationType, destinationLast4 string, instantEligible bool) error

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

	// --- Invite Codes ---

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

	// --- Provider Tokens (device-linked auth) ---

	// CreateProviderToken stores a long-lived provider auth token linked to an account.
	CreateProviderToken(token *ProviderToken) error

	// GetProviderToken validates a provider token and returns it.
	GetProviderToken(token string) (*ProviderToken, error)

	// RevokeProviderToken deactivates a provider token.
	RevokeProviderToken(token string) error

	// --- Provider Fleet Persistence ---

	// UpsertProvider creates or updates a provider record.
	UpsertProvider(ctx context.Context, p ProviderRecord) error

	// GetProvider returns a provider record by ID.
	GetProviderRecord(ctx context.Context, id string) (*ProviderRecord, error)

	// GetProviderBySerial returns a provider record by serial number.
	GetProviderBySerial(ctx context.Context, serial string) (*ProviderRecord, error)

	// ListProviders returns all stored provider records.
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
	// backfills serial/account if they were unknown at open time.
	TouchProviderSession(ctx context.Context, sessionID, serial, accountID string, lastSeen time.Time) error

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
	//
	// These persist the in-memory reuse cache used by the APNs code-identity
	// flow (W5 Fix 2) so a blue-green deploy / coordinator restart does not wipe
	// it and trigger a fleet-wide push storm against Apple's ~3/hour/device push
	// budget. SECURITY: a persisted row records that a device (keyed by its Secure
	// Enclave public key) completed a FULL code-identity round-trip at AttestedAt
	// running binary Version. It NEVER by itself grants CodeAttested — it only lets
	// the coordinator skip RE-PUSHING within the same-version, bounded reuse window
	// (api.codeAttestThrottle.reuseAttestation re-checks version + freshness on
	// read, so a stale / wrong-version / expired persisted row falls through to a
	// real challenge).

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
	//
	// These mirror the code-identity reuse cache above. A persisted row records
	// that a device (keyed by its Secure Enclave public key) completed a FULL live
	// MDM SecurityInfo verification at VerifiedAt — proven SIP/Secure-Boot posture,
	// serial, and binary hash. It lets a planned coordinator restart/blue-green
	// swap skip a fleet-wide live MDM SecurityInfo + APNs re-verification HERD: on
	// reconnect, once the live SE challenge re-proves identity + posture, a fresh
	// record short-circuits the (otherwise immediate) live MDM round-trip.
	//
	// SECURITY: a persisted row NEVER by itself grants hardware trust. The reuse
	// decision (api.trustReuseCache.reuseTrust) re-applies, on every read, a live
	// SE challenge, a serial+SE-key identity match, a binary-hash match, a fresh
	// good-posture check, and the freshness window — so a stale / wrong-binary /
	// expired / hard-untrusted row falls through to the full live MDM verification.

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

	// --- Telemetry ---
	//
	// Telemetry events are forwarded to Datadog (Logs API + DogStatsD)
	// for durable storage and querying.
}

// TelemetryEventRecord is the persistence-layer representation of a telemetry
// event. It mirrors protocol.TelemetryEvent but lives in this package so the
// store can stay free of protocol-layer dependencies.
type TelemetryEventRecord struct {
	ID         string          `json:"id"`
	Timestamp  time.Time       `json:"timestamp"`
	Source     string          `json:"source"`
	Severity   string          `json:"severity"`
	Kind       string          `json:"kind"`
	Version    string          `json:"version,omitempty"`
	MachineID  string          `json:"machine_id,omitempty"`
	AccountID  string          `json:"account_id,omitempty"`
	RequestID  string          `json:"request_id,omitempty"`
	SessionID  string          `json:"session_id,omitempty"`
	Message    string          `json:"message"`
	Fields     json.RawMessage `json:"fields,omitempty"`
	Stack      string          `json:"stack,omitempty"`
	ReceivedAt time.Time       `json:"received_at"`
}

// UsageRecord captures a single inference usage event.
type UsageRecord struct {
	ProviderID       string            `json:"provider_id"`
	ConsumerKey      string            `json:"consumer_key"`
	KeyID            string            `json:"key_id,omitempty"`
	Model            string            `json:"model"`
	PublicModel      string            `json:"public_model,omitempty"`
	PromptTokens     int               `json:"prompt_tokens"`
	CompletionTokens int               `json:"completion_tokens"`
	RequestLocation  *ProviderLocation `json:"request_location,omitempty"`
	Timestamp        time.Time         `json:"timestamp"`
	RequestID        string            `json:"request_id,omitempty"`
	CostMicroUSD     int64             `json:"cost_micro_usd,omitempty"`
	CreatedAt        time.Time         `json:"created_at,omitempty"`
}

// maxTelemetryReadRows is the hard upper bound on rows returned by the routing
// telemetry readers (InferenceRouteRecordsSince / RejectionRecordsSince). These
// tables grow unbounded over time, so the readers always cap the result set
// (newest-first) to keep an admin query — or a wide `since` window — from
// loading the whole table into memory. Narrow the time window to see older rows.
const maxTelemetryReadRows = 50000

// InferenceRouteRecord captures a single routing decision and the provider
// snapshot at the moment the scheduler made the choice. It contains no user
// prompt or response content.
type InferenceRouteRecord struct {
	RequestID               string  `json:"request_id"`
	Attempt                 int     `json:"attempt"`
	ProviderID              string  `json:"provider_id"`
	Model                   string  `json:"model"`
	PublicModel             string  `json:"public_model"`
	ConsumerKeyHash         string  `json:"consumer_key_hash"`
	KeyID                   string  `json:"key_id"`
	Outcome                 string  `json:"outcome"`
	CostMs                  float64 `json:"cost_ms"`
	StateMs                 float64 `json:"state_ms"`
	QueueMs                 float64 `json:"queue_ms"`
	PendingMs               float64 `json:"pending_ms"`
	BacklogMs               float64 `json:"backlog_ms"`
	ThisReqMs               float64 `json:"this_req_ms"`
	HealthMs                float64 `json:"health_ms"`
	TTFTMs                  float64 `json:"ttft_ms"`
	BestTTFTMs              float64 `json:"best_ttft_ms"`
	EffectiveQueue          int     `json:"effective_queue"`
	CandidateCount          int     `json:"candidate_count"`
	CapacityRejections      int     `json:"capacity_rejections"`
	ModelTooLargeRejections int     `json:"model_too_large_rejections"`
	VisionRejections        int     `json:"vision_rejections"`
	TTFTRejections          int     `json:"ttft_rejections"`
	EffectiveTPS            float64 `json:"effective_tps"`
	StaticTPS               float64 `json:"static_tps"`

	ProviderStatus        string  `json:"provider_status"`
	ProviderTrustLevel    string  `json:"provider_trust_level"`
	ProviderVersion       string  `json:"provider_version"`
	HardwareChip          string  `json:"hardware_chip"`
	HardwareChipFamily    string  `json:"hardware_chip_family"`
	HardwareTier          string  `json:"hardware_tier"`
	MemoryGB              int     `json:"memory_gb"`
	GPUCores              int     `json:"gpu_cores"`
	CPUCores              int     `json:"cpu_cores"`
	SystemMemoryPressure  float64 `json:"system_memory_pressure"`
	SystemCPUUsage        float64 `json:"system_cpu_usage"`
	SystemThermalState    string  `json:"system_thermal_state"`
	GPUMemoryActiveGB     float64 `json:"gpu_memory_active_gb"`
	GPUMemoryPeakGB       float64 `json:"gpu_memory_peak_gb"`
	GPUMemoryCacheGB      float64 `json:"gpu_memory_cache_gb"`
	SlotState             string  `json:"slot_state"`
	BackendRunning        int     `json:"backend_running"`
	BackendWaiting        int     `json:"backend_waiting"`
	ActiveTokenBudgetUsed int64   `json:"active_token_budget_used"`
	ActiveTokenBudgetMax  int64   `json:"active_token_budget_max"`
	QueuedTokenBudget     int64   `json:"queued_token_budget"`

	EstimatedPromptTokens int    `json:"estimated_prompt_tokens"`
	RequestedMaxTokens    int    `json:"requested_max_tokens"`
	RequiresVision        bool   `json:"requires_vision"`
	HasTools              bool   `json:"has_tools"`
	SelfRouteOnly         bool   `json:"self_route_only"`
	PreferOwner           bool   `json:"prefer_owner"`
	CacheAffinityKey      string `json:"cache_affinity_key"`

	// Geo (coarse region of provider/consumer; no raw IPs). Optional.
	ProviderRegion string `json:"provider_region,omitempty"`
	ConsumerRegion string `json:"consumer_region,omitempty"`

	// Final outcome data, merged from InferenceRouteOutcome updates.
	FinalStatus            string  `json:"final_status"`
	ErrorCode              int     `json:"error_code"`
	ErrorClass             string  `json:"error_class"`
	PromptTokens           int     `json:"prompt_tokens"`
	CompletionTokens       int     `json:"completion_tokens"`
	ReasoningTokens        int     `json:"reasoning_tokens"`
	CostMicroUSD           int64   `json:"cost_micro_usd"`
	ActualTTFTMs           float64 `json:"actual_ttft_ms"`
	DispatchToFirstChunkMs float64 `json:"dispatch_to_first_chunk_ms"`
	TotalDurationMs        float64 `json:"total_duration_ms"`
	ParseMs                float64 `json:"parse_ms"`
	ReserveMs              float64 `json:"reserve_ms"`
	RouteMs                float64 `json:"route_ms"`
	EncryptMs              float64 `json:"encrypt_ms"`
	QueueWaitMs            float64 `json:"queue_wait_ms"`
	DispatchMs             float64 `json:"dispatch_ms"`
	ActualDecodeTPS        float64 `json:"actual_decode_tps"`
	AdmittedButFailed      bool    `json:"admitted_but_failed"`
	UsedBackup             bool    `json:"used_backup"`
	BackupWon              bool    `json:"backup_won"`

	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

// InferenceRouteOutcome carries the final result of a routed request attempt.
type InferenceRouteOutcome struct {
	FinalStatus            string  `json:"final_status"`
	ErrorCode              int     `json:"error_code"`
	ErrorClass             string  `json:"error_class"`
	PromptTokens           int     `json:"prompt_tokens"`
	CompletionTokens       int     `json:"completion_tokens"`
	ReasoningTokens        int     `json:"reasoning_tokens"`
	CostMicroUSD           int64   `json:"cost_micro_usd"`
	ActualTTFTMs           float64 `json:"actual_ttft_ms"`
	DispatchToFirstChunkMs float64 `json:"dispatch_to_first_chunk_ms"`
	TotalDurationMs        float64 `json:"total_duration_ms"`

	// Coordinator-side latency decomposition (ms). Zero = not measured.
	ParseMs     float64 `json:"parse_ms"`
	ReserveMs   float64 `json:"reserve_ms"`
	RouteMs     float64 `json:"route_ms"`
	EncryptMs   float64 `json:"encrypt_ms"`
	QueueWaitMs float64 `json:"queue_wait_ms"` // measured enqueue -> dispatch
	DispatchMs  float64 `json:"dispatch_ms"`

	// Measured decode throughput for the completed request (tokens/s).
	ActualDecodeTPS float64 `json:"actual_decode_tps"`

	// AdmittedButFailed is true when the coordinator admitted the request but the
	// provider failed it (OOM / load failure) — the admission-gate mismatch.
	AdmittedButFailed bool `json:"admitted_but_failed"`
	// Speculative/backup-race dispatch outcome.
	UsedBackup bool `json:"used_backup"`
	BackupWon  bool `json:"backup_won"`
}

// RejectionRecord captures a single rejected inbound inference request (4xx/5xx)
// at any stage of the pipeline, with the request's parameters and a
// counterfactual servability snapshot ("could the fleet have served it?"). It
// contains no prompt or response content.
type RejectionRecord struct {
	RequestID       string `json:"request_id,omitempty"`
	Endpoint        string `json:"endpoint"`
	Stage           string `json:"stage"`       // auth, validation, model_resolution, balance, rate_limit, preflight_capacity, routing_ttft
	ReasonCode      string `json:"reason_code"` // e.g. model_not_found, machine_busy, insufficient_funds
	HTTPStatus      int    `json:"http_status"`
	ConsumerKeyHash string `json:"consumer_key_hash,omitempty"`
	KeyID           string `json:"key_id,omitempty"`
	ClientClass     string `json:"client_class,omitempty"` // e.g. openrouter, direct

	// Request shape / params (non-private — no content).
	RequestedModel        string          `json:"requested_model"` // raw, as the client sent it
	ResolvedModel         string          `json:"resolved_model,omitempty"`
	Stream                bool            `json:"stream"`
	N                     int             `json:"n,omitempty"`
	EstimatedPromptTokens int             `json:"estimated_prompt_tokens"`
	RequestedMaxTokens    int             `json:"requested_max_tokens"`
	RequiresVision        bool            `json:"requires_vision"`
	HasImage              bool            `json:"has_image"`
	HasAudio              bool            `json:"has_audio"`
	HasTools              bool            `json:"has_tools"`
	ToolCount             int             `json:"tool_count,omitempty"`
	ResponseFormat        string          `json:"response_format,omitempty"`
	SelfRouteOnly         bool            `json:"self_route_only"`
	PreferOwner           bool            `json:"prefer_owner"`
	Params                json.RawMessage `json:"params,omitempty"` // non-content knobs (temperature, top_p, …)
	RequestBodyBytes      int             `json:"request_body_bytes,omitempty"`
	RetryAfterMs          int             `json:"retry_after_ms,omitempty"`

	// Counterfactual servability — "could it have produced output?"
	CouldHaveServed         bool    `json:"could_have_served"`
	CandidateCount          int     `json:"candidate_count"`
	CapacityRejections      int     `json:"capacity_rejections"`
	ModelTooLargeRejections int     `json:"model_too_large_rejections"`
	VisionRejections        int     `json:"vision_rejections"`
	WarmProviderExisted     bool    `json:"warm_provider_existed"`
	BestTTFTMs              float64 `json:"best_ttft_ms,omitempty"`
	ShortfallMicroUSD       int64   `json:"shortfall_micro_usd,omitempty"` // for 402
	LimitKind               string  `json:"limit_kind,omitempty"`          // for 429 rate-limit
	OverBy                  int64   `json:"over_by,omitempty"`

	CreatedAt time.Time `json:"created_at"`
}

// UsageTotals aggregates the entire usage table.
type UsageTotals struct {
	Requests         int64 `json:"requests"`
	PromptTokens     int64 `json:"prompt_tokens"`
	CompletionTokens int64 `json:"completion_tokens"`
}

// UsageBucket is a per-minute aggregation of usage rows.
type UsageBucket struct {
	Minute           time.Time `json:"minute"`
	Requests         int64     `json:"requests"`
	PromptTokens     int64     `json:"prompt_tokens"`
	CompletionTokens int64     `json:"completion_tokens"`
}

// UsageLocationBucket aggregates request-origin location data for public stats.
type UsageLocationBucket struct {
	City             string  `json:"city"`
	Region           string  `json:"region"`
	RegionCode       string  `json:"region_code"`
	Country          string  `json:"country"`
	CountryCode      string  `json:"country_code"`
	Latitude         float64 `json:"latitude"`
	Longitude        float64 `json:"longitude"`
	Requests         int64   `json:"requests"`
	PromptTokens     int64   `json:"prompt_tokens"`
	CompletionTokens int64   `json:"completion_tokens"`
	Providers        int     `json:"providers"`
}

// UsageFlowBucket is a pre-aggregated directional flow between a consumer
// location and a provider location, computed via SQL JOIN.
type UsageFlowBucket struct {
	// Consumer (request origin)
	ConsumerCity        string  `json:"consumer_city"`
	ConsumerRegion      string  `json:"consumer_region"`
	ConsumerRegionCode  string  `json:"consumer_region_code"`
	ConsumerCountry     string  `json:"consumer_country"`
	ConsumerCountryCode string  `json:"consumer_country_code"`
	ConsumerLatitude    float64 `json:"consumer_latitude"`
	ConsumerLongitude   float64 `json:"consumer_longitude"`
	// Provider
	ProviderCity        string  `json:"provider_city"`
	ProviderRegion      string  `json:"provider_region"`
	ProviderRegionCode  string  `json:"provider_region_code"`
	ProviderCountry     string  `json:"provider_country"`
	ProviderCountryCode string  `json:"provider_country_code"`
	ProviderLatitude    float64 `json:"provider_latitude"`
	ProviderLongitude   float64 `json:"provider_longitude"`
	// Aggregates
	Requests         int64 `json:"requests"`
	PromptTokens     int64 `json:"prompt_tokens"`
	CompletionTokens int64 `json:"completion_tokens"`
}

// LeaderboardMetric selects the ranking column for a leaderboard query.
type LeaderboardMetric string

const (
	LeaderboardEarnings LeaderboardMetric = "earnings"
	LeaderboardTokens   LeaderboardMetric = "tokens"
	LeaderboardJobs     LeaderboardMetric = "jobs"
)

// LeaderboardRow is a single account's aggregate across provider_earnings.
// Pseudonyms are computed at the API layer from AccountID, never returned
// from the store directly.
type LeaderboardRow struct {
	AccountID        string `json:"account_id"`
	EarningsMicroUSD int64  `json:"earnings_micro_usd"`
	Tokens           int64  `json:"tokens"`
	Jobs             int64  `json:"jobs"`
}

// NetworkTotalsRow holds aggregated network metrics for homepage stats.
type NetworkTotalsRow struct {
	EarningsMicroUSD int64 `json:"earnings_micro_usd"`
	Tokens           int64 `json:"tokens"`
	Jobs             int64 `json:"jobs"`
	ActiveAccounts   int64 `json:"active_accounts"`
}

// LedgerEntryType categorizes balance changes.
type LedgerEntryType string

const (
	LedgerDeposit        LedgerEntryType = "deposit"         // consumer funds account
	LedgerCharge         LedgerEntryType = "charge"          // consumer pays for inference
	LedgerPayout         LedgerEntryType = "payout"          // provider credited for serving
	LedgerPlatformFee    LedgerEntryType = "platform_fee"    // Darkbloom platform cut
	LedgerWithdrawal     LedgerEntryType = "withdrawal"      // on-chain withdrawal
	LedgerReferralReward LedgerEntryType = "referral_reward" // referrer earns share of platform fee
	LedgerStripeDeposit  LedgerEntryType = "stripe_deposit"  // Stripe checkout deposit
	LedgerStripePayout   LedgerEntryType = "stripe_payout"   // user-initiated bank/card withdrawal via Stripe Connect
	LedgerInviteCredit   LedgerEntryType = "invite_credit"   // invite code redemption
	LedgerRefund         LedgerEntryType = "refund"          // reservation refund (request failed before inference)
	LedgerAdminCredit    LedgerEntryType = "admin_credit"    // admin-granted non-withdrawable credit
	LedgerAdminReward    LedgerEntryType = "admin_reward"    // admin-granted withdrawable reward
	LedgerMigration      LedgerEntryType = "migration"       // balance moved between account identities (e.g. legacy key re-keying)
)

// LedgerEntry is a single balance-changing event.
type LedgerEntry struct {
	ID             int64           `json:"id"`
	AccountID      string          `json:"account_id"`
	Type           LedgerEntryType `json:"type"`
	AmountMicroUSD int64           `json:"amount_micro_usd"` // positive = credit, negative = debit
	BalanceAfter   int64           `json:"balance_after"`
	Reference      string          `json:"reference"` // job ID, tx hash, etc.
	CreatedAt      time.Time       `json:"created_at"`
}

// PaymentRecord captures a settled payment.
type PaymentRecord struct {
	TxHash           string    `json:"tx_hash"`
	ConsumerAddress  string    `json:"consumer_address"`
	ProviderAddress  string    `json:"provider_address"`
	AmountUSD        string    `json:"amount_usd"`
	Model            string    `json:"model"`
	PromptTokens     int       `json:"prompt_tokens"`
	CompletionTokens int       `json:"completion_tokens"`
	Memo             string    `json:"memo"`
	CreatedAt        time.Time `json:"created_at"`
}

// Referrer represents a registered referral partner.
type Referrer struct {
	AccountID string    `json:"account_id"`
	Code      string    `json:"code"`
	CreatedAt time.Time `json:"created_at"`
}

// ReferralStats provides aggregate metrics for a referral code.
type ReferralStats struct {
	Code                 string `json:"code"`
	TotalReferred        int    `json:"total_referred"`
	TotalRewardsMicroUSD int64  `json:"total_rewards_micro_usd"`
}

// ModelPrice represents a custom per-model price override for an account.
type ModelPrice struct {
	AccountID   string `json:"account_id"`
	Model       string `json:"model"`
	InputPrice  int64  `json:"input_price"`  // micro-USD per 1M tokens
	OutputPrice int64  `json:"output_price"` // micro-USD per 1M tokens
}

// Per-key spend-cap reset windows. A cap with KeyResetNone is a lifetime cap;
// the others reset at the corresponding UTC calendar boundary (midnight UTC for
// daily, Monday 00:00 UTC for weekly, the 1st 00:00 UTC for monthly).
const (
	KeyResetNone    = "none"
	KeyResetDaily   = "daily"
	KeyResetWeekly  = "weekly"
	KeyResetMonthly = "monthly"
)

// APIKey is a consumer API key with optional per-key limits. One account may
// own many keys. The account's prepaid balance is always the hard ceiling;
// each key's limits are sub-caps enforced before the ledger reservation.
//
// Nil limit pointers mean "no per-key limit" for that dimension (the key is
// bounded only by the account's balance and the global per-account limiters).
type APIKey struct {
	ID             string `json:"id"`               // stable public id (e.g. "key_…"); safe to expose
	OwnerAccountID string `json:"owner_account_id"` // owning account
	Name           string `json:"name"`             // user-set label
	Label          string `json:"label"`            // masked prefix…suffix for display (e.g. "sk-db-1a2b…c3d4")
	KeyHash        string `json:"-"`                // sha256 of the raw key (Postgres); never serialized

	Disabled bool `json:"disabled"` // soft lifecycle — a disabled key fails auth fast

	// Spend cap. LimitMicroUSD nil = unlimited. LimitReset selects the window.
	LimitMicroUSD *int64 `json:"limit_micro_usd,omitempty"`
	LimitReset    string `json:"limit_reset"` // none | daily | weekly | monthly

	// Throughput overrides. Nil = inherit the account-level limiter.
	RPMLimit  *int64 `json:"rpm_limit,omitempty"`  // requests per minute
	ITPMLimit *int64 `json:"itpm_limit,omitempty"` // input tokens per minute
	OTPMLimit *int64 `json:"otpm_limit,omitempty"` // output tokens per minute

	// AllowedModels restricts which models the key may call. Empty = all.
	AllowedModels []string `json:"allowed_models,omitempty"`

	// SelfRouteOnly is a hard ceiling: every request on this key is routed
	// only to a machine the owning account runs, and is free. The key can
	// never spend balance or reach the public fleet. See the "self-route"
	// design in the consumer handler.
	SelfRouteOnly bool `json:"self_route_only"`

	ExpiresAt  *time.Time `json:"expires_at,omitempty"`
	CreatedAt  time.Time  `json:"created_at"`
	LastUsedAt *time.Time `json:"last_used_at,omitempty"`
}

// APIKeyCreate carries the create-time options for a new API key. All limit
// fields are optional; a nil pointer means "no limit" for that dimension.
type APIKeyCreate struct {
	Name          string
	LimitMicroUSD *int64
	LimitReset    string
	RPMLimit      *int64
	ITPMLimit     *int64
	OTPMLimit     *int64
	AllowedModels []string
	SelfRouteOnly bool
	ExpiresAt     *time.Time
}

// Account role values. The empty string is a normal consumer account.
const (
	// RoleService marks a trusted machine/partner account (e.g. an upstream
	// aggregator such as OpenRouter). Service accounts get elevated or
	// bypassed rate limits. They authenticate with a normal API key whose
	// linked user carries this role.
	RoleService = "service"
)

// User represents a consumer account linked to a Privy identity.
type User struct {
	AccountID   string    `json:"account_id"`      // internal account ID (used in ledger)
	PrivyUserID string    `json:"privy_user_id"`   // Privy DID (e.g. "did:privy:abc123")
	Email       string    `json:"email,omitempty"` // from Privy linked accounts
	CreatedAt   time.Time `json:"created_at"`

	// Role gates elevated capabilities. "" = normal consumer,
	// RoleService = trusted partner/aggregator (elevated rate limits).
	Role string `json:"role,omitempty"`

	// PlatformFeePercent overrides the global platform routing fee for this
	// account when non-nil. nil = use the global default. A value of 0 means
	// the account pays no platform fee (the provider receives 100%). Used to
	// waive the fee for wholesale partners such as OpenRouter.
	PlatformFeePercent *int64 `json:"platform_fee_percent,omitempty"`

	// Stripe Connect Express — for bank/card payouts via Stripe.
	// StripeAccountStatus mirrors the readiness of payouts on the connected
	// account: "" (not onboarded), "pending" (link created but not finished),
	// "ready" (payouts_enabled=true), "restricted" (Stripe needs more info),
	// "rejected" (Stripe permanently disabled the account).
	StripeAccountID        string `json:"stripe_account_id,omitempty"`
	StripeAccountStatus    string `json:"stripe_account_status,omitempty"`
	StripeDestinationType  string `json:"stripe_destination_type,omitempty"` // "bank" | "card" | ""
	StripeDestinationLast4 string `json:"stripe_destination_last4,omitempty"`
	StripeInstantEligible  bool   `json:"stripe_instant_eligible,omitempty"` // debit-card destination supports Instant Payouts
}

// StripeWithdrawal records a user-initiated payout via Stripe Connect Express.
// The lifecycle is: pending (debit recorded) → transferred (platform→connected
// account transfer succeeded) → paid (Stripe payout to bank/card succeeded).
// On failure at any stage we re-credit the user via LedgerRefund and set the
// status to "failed".
type StripeWithdrawal struct {
	ID              string    `json:"id"`                       // internal UUID, used as Stripe idempotency key prefix
	AccountID       string    `json:"account_id"`               // internal account that owns the withdrawal
	StripeAccountID string    `json:"stripe_account_id"`        // Stripe connected account (acct_…)
	TransferID      string    `json:"transfer_id,omitempty"`    // Stripe transfer (tr_…)
	PayoutID        string    `json:"payout_id,omitempty"`      // Stripe payout (po_…)
	AmountMicroUSD  int64     `json:"amount_micro_usd"`         // gross amount debited from ledger
	FeeMicroUSD     int64     `json:"fee_micro_usd"`            // fee retained by platform
	NetMicroUSD     int64     `json:"net_micro_usd"`            // amount transferred to user (gross - fee)
	Method          string    `json:"method"`                   // "standard" | "instant"
	Status          string    `json:"status"`                   // "pending" | "transferred" | "paid" | "failed"
	FailureReason   string    `json:"failure_reason,omitempty"` // populated when Status="failed"
	Refunded        bool      `json:"refunded,omitempty"`       // true after the failure refund is credited
	CreatedAt       time.Time `json:"created_at"`
	UpdatedAt       time.Time `json:"updated_at"`
}

// SupportedModel is the lightweight in-memory shape the model-listing and
// routing code uses to describe a servable model. It is derived from the
// canonical model_registry (see supportedModelFromRegistryRecord); it is no
// longer a standalone persisted catalog. The coordinator remains the single
// source of truth for which models providers can serve.
//
// ModelType determines routing: "text" for chat/completions, "embedding" for
// vector search, etc.
type SupportedModel struct {
	ID           string  `json:"id"`           // HuggingFace path (e.g. "mlx-community/Qwen3.5-9B-MLX-4bit")
	S3Name       string  `json:"s3_name"`      // CDN key for download (e.g. "Qwen3.5-9B-MLX-4bit")
	DisplayName  string  `json:"display_name"` // Human-readable (e.g. "Qwen3.5 9B")
	ModelType    string  `json:"model_type"`   // "text", "embedding", "tts"
	SizeGB       float64 `json:"size_gb"`      // Disk/memory size in GB
	Architecture string  `json:"architecture"` // e.g. "9B dense", "2B conformer"
	Description  string  `json:"description"`  // e.g. "Balanced", "Fast reasoning"
	MinRAMGB     int     `json:"min_ram_gb"`   // Minimum system RAM for auto-selection
	Active       bool    `json:"active"`       // Whether available for use
	WeightHash   string  `json:"weight_hash"`  // Expected SHA-256 fingerprint of model weight files
}

// ModelRegistryEntry is the canonical admin-managed model catalog row.
type ModelRegistryEntry struct {
	ID                string         `json:"id"`
	DisplayName       string         `json:"display_name"`
	Family            string         `json:"family"`
	Architecture      string         `json:"architecture"`
	Quantization      string         `json:"quantization"`
	MaxContextLength  int            `json:"max_context_length"`
	MaxOutputLength   int            `json:"max_output_length"`
	MinRAMGB          int            `json:"min_ram_gb"`
	Capabilities      []string       `json:"capabilities"`
	Status            string         `json:"status"`
	Description       string         `json:"description"`
	RuntimeParameters map[string]any `json:"runtime_parameters"`
	Metadata          map[string]any `json:"metadata"`
	CreatedAt         time.Time      `json:"created_at"`
	UpdatedAt         time.Time      `json:"updated_at"`
}

// ModelVersion is an uploaded manifest version for a registered model.
type ModelVersion struct {
	ID              int64          `json:"id"`
	ModelID         string         `json:"model_id"`
	Version         string         `json:"version"`
	R2Prefix        string         `json:"r2_prefix"`
	AggregateSHA256 string         `json:"aggregate_sha256"`
	TotalSizeBytes  int64          `json:"total_size_bytes"`
	FileCount       int            `json:"file_count"`
	Status          string         `json:"status"`
	UploadedBy      string         `json:"uploaded_by,omitempty"`
	UploadedAt      time.Time      `json:"uploaded_at"`
	PromotedAt      *time.Time     `json:"promoted_at,omitempty"`
	Metadata        map[string]any `json:"metadata"`
}

// ModelVersionFile is one file in a model version manifest.
type ModelVersionFile struct {
	ID             int64  `json:"id"`
	ModelVersionID int64  `json:"model_version_id"`
	Path           string `json:"path"`
	SizeBytes      int64  `json:"size_bytes"`
	SHA256         string `json:"sha256"`
	Role           string `json:"role"`
}

// ModelRegistryRecord combines a model with its active version and files.
type ModelRegistryRecord struct {
	ModelRegistryEntry
	ActiveVersion *ModelVersion      `json:"active_version,omitempty"`
	Files         []ModelVersionFile `json:"files,omitempty"`
}

// ModelAlias is a stable, consumer-facing model name (e.g. "gemma-4-26b") that
// resolves to a single DESIRED concrete registry build (a raw HuggingFace id
// such as "mlx-community/gemma-4-26B-A4B-it-qat-4bit"), with an optional
// PreviousBuild that stays acceptable while providers converge on the desired
// one. Consumers only ever see the alias; the coordinator resolves it to a
// concrete build for routing/billing. This is what makes a quant swap
// (fp8 → qat-4bit) invisible to clients: a rollout is just setting DesiredBuild,
// a revert is setting it back. There are no weights, ramps, or migrations.
type ModelAlias struct {
	AliasID       string `json:"alias_id"`
	DisplayName   string `json:"display_name"`
	DesiredBuild  string `json:"desired_build"`            // the single build providers should converge to
	PreviousBuild string `json:"previous_build,omitempty"` // still-acceptable during rollout; "" when none
	// RetiredBuilds is the alias's lineage: former desired/previous builds
	// rotated out by later upserts. Kept so a provider that was offline through
	// a retirement (still advertising only a retired build) is recognized as
	// part of this alias's fleet at re-registration and told to converge. A
	// build promoted back to desired/previous leaves this list. Bounded; oldest
	// entries dropped first.
	RetiredBuilds []string  `json:"retired_builds,omitempty"`
	Active        bool      `json:"active"`
	CreatedAt     time.Time `json:"created_at"`
	UpdatedAt     time.Time `json:"updated_at"`
}

// ModelManifest mirrors the minimal darkbloom-publish manifest JSON.
type ModelManifest struct {
	SchemaVersion   int            `json:"schema_version"`
	ModelID         string         `json:"model_id"`
	Version         string         `json:"version"`
	R2Prefix        string         `json:"r2_prefix"`
	AggregateSHA256 string         `json:"aggregate_sha256"`
	TotalSizeBytes  int64          `json:"total_size_bytes"`
	FileCount       int            `json:"file_count"`
	Files           []ManifestFile `json:"files"`
	CreatedAt       time.Time      `json:"created_at"`
}

// ManifestFile mirrors a file entry in a model manifest.
type ManifestFile struct {
	Path      string `json:"path"`
	SizeBytes int64  `json:"size_bytes"`
	SHA256    string `json:"sha256"`
	Role      string `json:"role"`
}

// PublishingAPIKey stores a hashed key allowed to publish model manifests.
type PublishingAPIKey struct {
	ID         string     `json:"id"`
	Name       string     `json:"name"`
	KeyHash    string     `json:"key_hash"`
	Active     bool       `json:"active"`
	CreatedAt  time.Time  `json:"created_at"`
	LastUsedAt *time.Time `json:"last_used_at,omitempty"`
}

// Release represents a versioned provider binary release.
// The GitHub Action registers new releases via POST /v1/releases (scoped key).
// Admins manage releases via /v1/admin/releases (Privy auth).
type Release struct {
	Version        string    `json:"version"`                   // semver, e.g. "0.5.0"
	Platform       string    `json:"platform"`                  // "macos-arm64"
	Backend        string    `json:"backend,omitempty"`         // "mlx-swift" (post-cutover) or "vllm-mlx" (legacy)
	BinaryHash     string    `json:"binary_hash"`               // SHA-256 of darkbloom binary (attestation verification)
	BundleHash     string    `json:"bundle_hash"`               // SHA-256 of the bundle tarball (install.sh download verification)
	MetallibHash   string    `json:"metallib_hash,omitempty"`   // SHA-256 of mlx.metallib (Swift backend GPU kernel set)
	PythonHash     string    `json:"python_hash,omitempty"`     // legacy: SHA-256 of bundled Python binary (vllm-mlx backend only)
	RuntimeHash    string    `json:"runtime_hash,omitempty"`    // legacy: SHA-256 of vllm-mlx package (vllm-mlx backend only)
	TemplateHashes string    `json:"template_hashes,omitempty"` // comma-separated name=hash pairs
	URL            string    `json:"url"`                       // R2 download URL for the bundle tarball
	Changelog      string    `json:"changelog"`                 // human-readable changes in this version
	Active         bool      `json:"active"`                    // whether this version is accepted by the coordinator
	CreatedAt      time.Time `json:"created_at"`
}

// DeviceCode represents a pending device authorization request (RFC 8628-style).
// The provider CLI creates one, displays the UserCode, and polls until approved.
type DeviceCode struct {
	DeviceCode string    `json:"device_code"` // opaque code for polling (secret, sent only to device)
	UserCode   string    `json:"user_code"`   // short human-readable code (e.g. "ABCD-1234")
	AccountID  string    `json:"account_id"`  // set when user approves (empty while pending)
	Status     string    `json:"status"`      // "pending", "approved", "expired"
	ExpiresAt  time.Time `json:"expires_at"`
	CreatedAt  time.Time `json:"created_at"`
}

// ProviderToken is a long-lived auth token linking a provider machine to an account.
// Created when a device code is approved; used by the provider on every WebSocket connect.
type ProviderToken struct {
	TokenHash string    `json:"token_hash"` // SHA-256 of the raw token
	AccountID string    `json:"account_id"` // the account this provider is linked to
	Label     string    `json:"label"`      // human-readable label (e.g. hostname)
	Active    bool      `json:"active"`
	CreatedAt time.Time `json:"created_at"`
}

// InviteCode represents a coordinator-generated invite code that grants credits.
type InviteCode struct {
	Code           string     `json:"code"`
	AmountMicroUSD int64      `json:"amount_micro_usd"`
	MaxUses        int        `json:"max_uses"` // 0 = unlimited
	UsedCount      int        `json:"used_count"`
	Active         bool       `json:"active"`
	CreatedAt      time.Time  `json:"created_at"`
	ExpiresAt      *time.Time `json:"expires_at,omitempty"`
}

// InviteRedemption records a single redemption of an invite code.
type InviteRedemption struct {
	Code      string    `json:"code"`
	AccountID string    `json:"account_id"`
	CreatedAt time.Time `json:"created_at"`
}

// ProviderEarning records a single earning event for a specific provider node.
// This enables per-node earnings tracking (as opposed to account-level balance).
type ProviderEarning struct {
	ID               int64     `json:"id"`
	AccountID        string    `json:"account_id"`
	ProviderID       string    `json:"provider_id"`
	ProviderKey      string    `json:"provider_key"` // X25519 public key (stable hardware ID)
	JobID            string    `json:"job_id"`
	Model            string    `json:"model"`
	AmountMicroUSD   int64     `json:"amount_micro_usd"`
	PromptTokens     int       `json:"prompt_tokens"`
	CompletionTokens int       `json:"completion_tokens"`
	CreatedAt        time.Time `json:"created_at"`
}

// ProviderEarningsSummary captures lifetime payout aggregates independent of
// any pagination applied to recent earnings history.
type ProviderEarningsSummary struct {
	Count            int64 `json:"count"`
	TotalMicroUSD    int64 `json:"total_micro_usd"`
	PromptTokens     int64 `json:"prompt_tokens"`
	CompletionTokens int64 `json:"completion_tokens"`
}

// ProviderPayout records a provider payout event. This is separate from
// account-linked provider earnings because some providers are paid directly
// without being linked to a Privy account.
type ProviderPayout struct {
	ID              int64     `json:"id"`
	ProviderAddress string    `json:"provider_address"`
	AmountMicroUSD  int64     `json:"amount_micro_usd"`
	Model           string    `json:"model"`
	JobID           string    `json:"job_id"`
	Timestamp       time.Time `json:"timestamp"`
	Settled         bool      `json:"settled"`
}

// BillingSession tracks an in-progress payment via any method (Stripe).
type BillingSession struct {
	ID             string     `json:"id"`
	AccountID      string     `json:"account_id"`
	PaymentMethod  string     `json:"payment_method"` // "stripe"
	AmountMicroUSD int64      `json:"amount_micro_usd"`
	ExternalID     string     `json:"external_id"`   // Stripe session ID, tx hash, etc.
	Status         string     `json:"status"`        // "pending", "completed", "expired"
	ReferralCode   string     `json:"referral_code"` // optional
	CreatedAt      time.Time  `json:"created_at"`
	CompletedAt    *time.Time `json:"completed_at,omitempty"`
}

// ProviderRecord is the persistent representation of a provider for storage.
// Transient fields (WebSocket conn, pending requests, system metrics) are NOT persisted.
type ProviderRecord struct {
	ID                string            `json:"id"`
	Hardware          json.RawMessage   `json:"hardware"`
	Models            json.RawMessage   `json:"models"`
	Backend           string            `json:"backend"`
	Location          *ProviderLocation `json:"location,omitempty"`
	TrustLevel        string            `json:"trust_level"`
	Attested          bool              `json:"attested"`
	AttestationResult json.RawMessage   `json:"attestation_result,omitempty"`
	SEPublicKey       string            `json:"se_public_key,omitempty"`
	// PublicKey is the machine's X25519 E2E public key (non-secret — published
	// at /v1/encryption-key), persisted so an offline machine's key is still
	// available without a live connection.
	PublicKey                  string          `json:"public_key,omitempty"`
	SerialNumber               string          `json:"serial_number,omitempty"`
	MDAVerified                bool            `json:"mda_verified"`
	MDACertChain               json.RawMessage `json:"mda_cert_chain,omitempty"`
	ACMEVerified               bool            `json:"acme_verified"`
	Version                    string          `json:"version,omitempty"`
	RuntimeVerified            bool            `json:"runtime_verified"`
	PythonHash                 string          `json:"python_hash,omitempty"`
	RuntimeHash                string          `json:"runtime_hash,omitempty"`
	LastChallengeVerified      *time.Time      `json:"last_challenge_verified,omitempty"`
	FailedChallenges           int             `json:"failed_challenges"`
	AccountID                  string          `json:"account_id,omitempty"`
	LifetimeRequestsServed     int64           `json:"lifetime_requests_served"`
	LifetimeTokensGenerated    int64           `json:"lifetime_tokens_generated"`
	LastSessionRequestsServed  int64           `json:"last_session_requests_served"`
	LastSessionTokensGenerated int64           `json:"last_session_tokens_generated"`
	LifetimeStats              json.RawMessage `json:"lifetime_stats,omitempty"`
	LastSessionStats           json.RawMessage `json:"last_session_stats,omitempty"`
	RegisteredAt               time.Time       `json:"registered_at"`
	LastSeen                   time.Time       `json:"last_seen"`
}

// ProviderSession is one connect→disconnect lifecycle of a provider machine.
// connected_at/disconnected_at bound the session; last_seen is the most recent
// heartbeat within it. disconnected_at == nil means the session is still open.
// These rows are the durable source for uptime/downtime history (the providers
// table only keeps a single mutable last_seen).
type ProviderSession struct {
	ID               int64      `json:"id"`
	SessionID        string     `json:"session_id"` // providers.id for this connection
	SerialNumber     string     `json:"serial_number"`
	AccountID        string     `json:"account_id"`
	ConnectedAt      time.Time  `json:"connected_at"`
	LastSeen         time.Time  `json:"last_seen"`
	DisconnectedAt   *time.Time `json:"disconnected_at,omitempty"`
	DisconnectReason string     `json:"disconnect_reason"`
}

// ProviderLocation captures approximate geographic location for a provider or
// request origin. Raw IP addresses are never stored. Populated from GeoIP
// database lookups or trusted reverse-proxy headers.
type ProviderLocation struct {
	City             string    `json:"city,omitempty"`
	Region           string    `json:"region,omitempty"`
	RegionCode       string    `json:"region_code,omitempty"`
	Country          string    `json:"country,omitempty"`
	CountryCode      string    `json:"country_code,omitempty"`
	Latitude         float64   `json:"latitude,omitempty"`
	Longitude        float64   `json:"longitude,omitempty"`
	AccuracyRadiusKM int       `json:"accuracy_radius_km,omitempty"`
	Timezone         string    `json:"timezone,omitempty"`
	Source           string    `json:"source,omitempty"`
	UpdatedAt        time.Time `json:"updated_at,omitempty"`
}

// LogReport represents a stored provider log report. LogData is only populated
// when fetching a single report by ID (GetLogReport), not when listing.
type LogReport struct {
	ID           int64     `json:"id"`
	SerialNumber string    `json:"serial_number"`
	ProviderID   string    `json:"provider_id"`
	AccountID    string    `json:"account_id"`
	LogSizeBytes int64     `json:"log_size_bytes"`
	CreatedAt    time.Time `json:"created_at"`
	LogData      []byte    `json:"log_data,omitempty"`
}

// ReputationRecord is the persistent representation of a provider's reputation.
type ReputationRecord struct {
	TotalJobs          int   `json:"total_jobs"`
	SuccessfulJobs     int   `json:"successful_jobs"`
	FailedJobs         int   `json:"failed_jobs"`
	TotalUptimeSeconds int64 `json:"total_uptime_seconds"`
	AvgResponseTimeMs  int64 `json:"avg_response_time_ms"`
	ChallengesPassed   int   `json:"challenges_passed"`
	ChallengesFailed   int   `json:"challenges_failed"`
}

// CodeAttestation is the persistent representation of one device's most recent
// successful APNs code-identity attestation (W5 Fix 2). It is the durable form
// of api.codeAttestRecord. Keyed by the Secure Enclave public key — the stable
// per-device identity that survives reconnects AND coordinator restarts.
//
// SECURITY: the row is written ONLY after a full, verified code-identity
// round-trip; it is never created from an unverified heartbeat token. On read,
// the reuse decision still re-applies the version gate and freshness window, so a
// persisted row can only ever let the coordinator skip a redundant push — never
// extend or fabricate trust.
type CodeAttestation struct {
	SEPubKey   string    `json:"se_pubkey"`   // base64 Secure Enclave P-256 public key (bound at registration)
	Version    string    `json:"version"`     // provider binary version that attested
	AttestedAt time.Time `json:"attested_at"` // instant of the successful round-trip
	APNsToken  string    `json:"apns_token"`  // APNs device token the proof was bound to; reuse requires it to match the new registration token (Codex #7). "" = legacy row from before token-binding.
}

// ProviderTrustReuse is the persistent representation of one device's most recent
// successful FULL live MDM SecurityInfo verification (DAR-326 Phase 0). It is the
// durable form of api.trustReuseRecord. Keyed by the Secure Enclave public key —
// the stable per-device identity that survives reconnects AND coordinator
// restarts. It mirrors CodeAttestation: persistence lets a planned coordinator
// restart/blue-green swap skip a fleet-wide live MDM SecurityInfo + APNs
// re-verification herd.
//
// SECURITY: the row is written ONLY after a full, verified live MDM
// verification; it is never created from an unverified heartbeat or self-report.
// On read, the reuse decision still re-applies a live SE challenge, a serial+SE
// identity match, a binary-hash match, a fresh good-posture check, and the
// freshness window, so a persisted row can only ever let the coordinator skip a
// redundant live MDM round-trip — never extend or fabricate trust.
type ProviderTrustReuse struct {
	SEPubKey       string    `json:"se_pubkey"`        // base64 Secure Enclave P-256 public key (bound at registration)
	Serial         string    `json:"serial"`           // device serial number proven by the SE attestation at last verification
	TrustLevel     string    `json:"trust_level"`      // trust level earned at last verification (only "hardware" is reusable)
	BinaryHash     string    `json:"binary_hash"`      // provider binary SHA-256 at last verification; reuse requires the fresh signed challenge to match
	SIPEnabled     bool      `json:"sip_enabled"`      // SIP posture confirmed by MDM at last verification
	SecureBootFull bool      `json:"secure_boot_full"` // Secure Boot (full) confirmed by MDM at last verification
	MDAUDID        string    `json:"mda_udid"`         // MDM/MDA device UDID at last verification (diagnostics)
	VerifiedAt     time.Time `json:"verified_at"`      // instant of the successful live MDM verification
}
