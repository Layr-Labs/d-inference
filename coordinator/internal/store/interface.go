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
	"time"
)

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

	// RevokeKey deactivates a key. Returns true if the key existed.
	RevokeKey(key string) bool

	// RecordUsage logs an inference usage event.
	RecordUsage(providerID, consumerKey, model string, promptTokens, completionTokens int)

	// RecordUsageWithCost logs an inference usage event including request ID and cost.
	RecordUsageWithCost(providerID, consumerKey, model, requestID string, promptTokens, completionTokens int, costMicroUSD int64)

	// RecordPayment records a settled payment between consumer and provider.
	RecordPayment(txHash, consumerAddr, providerAddr, amountUSD, model string, promptTokens, completionTokens int, memo string) error

	// UsageRecords returns all usage records.
	UsageRecords() []UsageRecord

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

	// LedgerHistory returns ledger entries for an account, newest first.
	LedgerHistory(accountID string) []LedgerEntry

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

	// CreateBillingSession stores a new billing session (Stripe, EVM, Solana).
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

	// --- Supported Models (admin-managed catalog) ---

	// SetSupportedModel adds or updates a supported model in the catalog.
	SetSupportedModel(model *SupportedModel) error

	// ListSupportedModels returns all supported models, ordered by min_ram_gb ascending.
	ListSupportedModels() []SupportedModel

	// DeleteSupportedModel removes a model from the catalog by ID.
	DeleteSupportedModel(modelID string) error

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

	// UpdateProviderLastSeen updates the last_seen timestamp for a provider.
	UpdateProviderLastSeen(ctx context.Context, id string) error

	// UpdateProviderTrust persists trust level and attestation state changes.
	UpdateProviderTrust(ctx context.Context, id string, trustLevel string, attested bool, attestationResult json.RawMessage) error

	// UpdateProviderChallenge persists challenge verification state.
	UpdateProviderChallenge(ctx context.Context, id string, lastVerified time.Time, failedCount int) error

	// UpdateProviderRuntime persists runtime integrity verification state.
	UpdateProviderRuntime(ctx context.Context, id string, verified bool, pythonHash, runtimeHash string) error

	// --- Provider Reputation Persistence ---

	// UpsertReputation creates or updates a provider's reputation record.
	UpsertReputation(ctx context.Context, providerID string, rep ReputationRecord) error

	// GetReputation returns a provider's reputation record.
	GetReputation(ctx context.Context, providerID string) (*ReputationRecord, error)
}

// UsageRecord captures a single inference usage event.
type UsageRecord struct {
	ProviderID       string    `json:"provider_id"`
	ConsumerKey      string    `json:"consumer_key"`
	Model            string    `json:"model"`
	PromptTokens     int       `json:"prompt_tokens"`
	CompletionTokens int       `json:"completion_tokens"`
	Timestamp        time.Time `json:"timestamp"`
	RequestID        string    `json:"request_id,omitempty"`
	CostMicroUSD     int64     `json:"cost_micro_usd,omitempty"`
	CreatedAt        time.Time `json:"created_at,omitempty"`
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
	LedgerInviteCredit   LedgerEntryType = "invite_credit"   // invite code redemption
	LedgerRefund         LedgerEntryType = "refund"          // reservation refund (request failed before inference)
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

// User represents a consumer account linked to a Privy identity.
type User struct {
	AccountID           string    `json:"account_id"`            // internal account ID (used in ledger)
	PrivyUserID         string    `json:"privy_user_id"`         // Privy DID (e.g. "did:privy:abc123")
	Email               string    `json:"email,omitempty"`       // from Privy linked accounts
	SolanaWalletAddress string    `json:"solana_wallet_address"` // embedded wallet public address
	SolanaWalletID      string    `json:"solana_wallet_id"`      // Privy's internal wallet ID (for signing API)
	CreatedAt           time.Time `json:"created_at"`
}

// SupportedModel represents a model in the admin-managed catalog.
// The coordinator is the single source of truth for which models providers can serve.
// SupportedModel represents a model in the admin-managed catalog.
// The coordinator is the single source of truth for which models providers can serve.
//
// ModelType determines routing: "text" for chat/completions, "transcription" for
// speech-to-text, "embedding" for vector search, etc. Only add models that produce
// output worth paying for — small chat models (< 7B) are not useful, but small
// specialized models (transcription, embeddings) can be best-in-class.
type SupportedModel struct {
	ID           string  `json:"id"`           // HuggingFace path (e.g. "mlx-community/Qwen3.5-9B-MLX-4bit")
	S3Name       string  `json:"s3_name"`      // CDN key for download (e.g. "Qwen3.5-9B-MLX-4bit")
	DisplayName  string  `json:"display_name"` // Human-readable (e.g. "Qwen3.5 9B")
	ModelType    string  `json:"model_type"`   // "text", "transcription", "embedding", "tts", "image"
	SizeGB       float64 `json:"size_gb"`      // Disk/memory size in GB
	Architecture string  `json:"architecture"` // e.g. "9B dense", "2B conformer"
	Description  string  `json:"description"`  // e.g. "Balanced", "Best-in-class STT"
	MinRAMGB     int     `json:"min_ram_gb"`   // Minimum system RAM for auto-selection
	Active       bool    `json:"active"`       // Whether available for use
	WeightHash   string  `json:"weight_hash"`  // Expected SHA-256 fingerprint of model weight files
}

// Release represents a versioned provider binary release.
// The GitHub Action registers new releases via POST /v1/releases (scoped key).
// Admins manage releases via /v1/admin/releases (Privy auth).
type Release struct {
	Version         string    `json:"version"`                     // semver, e.g. "0.2.1"
	Platform        string    `json:"platform"`                    // "macos-arm64"
	BinaryHash      string    `json:"binary_hash"`                 // SHA-256 of darkbloom binary (attestation verification)
	BundleHash      string    `json:"bundle_hash"`                 // SHA-256 of the bundle tarball (install.sh download verification)
	PythonHash      string    `json:"python_hash,omitempty"`       // SHA-256 of bundled Python binary (runtime verification)
	RuntimeHash     string    `json:"runtime_hash,omitempty"`      // SHA-256 of vllm-mlx package (runtime verification)
	TemplateHashes  string    `json:"template_hashes,omitempty"`   // comma-separated name=hash pairs
	GrpcBinaryHash  string    `json:"grpc_binary_hash,omitempty"`  // SHA-256 of gRPCServerCLI binary (image generation)
	ImageBridgeHash string    `json:"image_bridge_hash,omitempty"` // SHA-256 of image bridge Python source
	URL             string    `json:"url"`                         // R2 download URL for the bundle tarball
	Changelog       string    `json:"changelog"`                   // human-readable changes in this version
	Active          bool      `json:"active"`                      // whether this version is accepted by the coordinator
	CreatedAt       time.Time `json:"created_at"`
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

// BillingSession tracks an in-progress payment via any method (Stripe, EVM, Solana).
type BillingSession struct {
	ID             string     `json:"id"`
	AccountID      string     `json:"account_id"`
	PaymentMethod  string     `json:"payment_method"` // "stripe", "evm", "solana"
	Chain          string     `json:"chain"`          // "ethereum", "tempo", "solana", ""
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
	ID                    string          `json:"id"`
	Hardware              json.RawMessage `json:"hardware"`
	Models                json.RawMessage `json:"models"`
	Backend               string          `json:"backend"`
	TrustLevel            string          `json:"trust_level"`
	Attested              bool            `json:"attested"`
	AttestationResult     json.RawMessage `json:"attestation_result,omitempty"`
	SEPublicKey           string          `json:"se_public_key,omitempty"`
	SerialNumber          string          `json:"serial_number,omitempty"`
	MDAVerified           bool            `json:"mda_verified"`
	MDACertChain          json.RawMessage `json:"mda_cert_chain,omitempty"`
	ACMEVerified          bool            `json:"acme_verified"`
	Version               string          `json:"version,omitempty"`
	RuntimeVerified       bool            `json:"runtime_verified"`
	PythonHash            string          `json:"python_hash,omitempty"`
	RuntimeHash           string          `json:"runtime_hash,omitempty"`
	LastChallengeVerified *time.Time      `json:"last_challenge_verified,omitempty"`
	FailedChallenges      int             `json:"failed_challenges"`
	AccountID             string          `json:"account_id,omitempty"`
	RegisteredAt          time.Time       `json:"registered_at"`
	LastSeen              time.Time       `json:"last_seen"`
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
