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
	"encoding/json"
	"errors"
	"time"
)

// ErrInsufficientBalance is returned by Debit when the account has
// insufficient funds (or does not exist). Callers should check with
// errors.Is to distinguish this from transient DB errors.
var ErrInsufficientBalance = errors.New("insufficient balance or account not found")

// ErrNotFound is wrapped by lookup methods when no row matches. Callers that
// take a different action on a true miss vs a transient store failure (e.g.
// the Stripe webhook state machine) must check with errors.Is rather than
// treating every error as not-found.
var ErrNotFound = errors.New("not found")

// ErrAutoWithdrawNotAuthorized is returned when an automatic Stripe
// withdrawal no longer matches the user's active authorization and scheduled
// run. Callers must stop before moving money; a later worker pass will load the
// current preference.
var ErrAutoWithdrawNotAuthorized = errors.New("automatic withdrawal is not authorized")

// ErrStripeWithdrawalBusy means another coordinator instance currently owns
// the short-lived execution lock for the same withdrawal. The caller should
// leave the schedule unchanged; the owner will complete or the lock will be
// released when its database session ends.
var ErrStripeWithdrawalBusy = errors.New("Stripe withdrawal is being processed")

// ErrStripeWithdrawalReconciliationRequired means a pending Stripe request is
// older than Stripe's idempotency-key retention guarantee and must not be
// replayed automatically.
var ErrStripeWithdrawalReconciliationRequired = errors.New("Stripe withdrawal requires reconciliation")

// Store is the union of every storage-domain sub-interface (defined in
// interface_domains.go). It was split from a single ~150-method god-interface
// into composed domains so callers can depend on a narrow slice of the
// persistence surface; the full method set — and both the MemoryStore and
// PostgresStore implementations — are unchanged.
//
// Telemetry events (TelemetryEventRecord) are forwarded to Datadog (Logs API +
// DogStatsD) for durable storage and querying, not persisted via this Store.
type Store interface {
	APIKeyStore
	UsageStore
	TelemetryStore
	LedgerStore
	BillingStore
	ModelRegistryStore
	ReleaseStore
	UserStore
	DeviceAuthStore
	InviteStore
	ProviderEarningsStore
	ProviderStore
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

	EstimatedPromptTokens int  `json:"estimated_prompt_tokens"`
	RequestedMaxTokens    int  `json:"requested_max_tokens"`
	RequiresVision        bool `json:"requires_vision"`
	HasTools              bool `json:"has_tools"`
	SelfRouteOnly         bool `json:"self_route_only"`
	PreferOwner           bool `json:"prefer_owner"`

	// Geo (coarse region of provider/consumer; no raw IPs). Optional.
	ProviderRegion string `json:"provider_region,omitempty"`
	ConsumerRegion string `json:"consumer_region,omitempty"`

	// Final outcome data, merged from InferenceRouteOutcome updates.
	FinalStatus            string  `json:"final_status"`
	ErrorCode              int     `json:"error_code"`
	ErrorClass             string  `json:"error_class"`
	ErrorReason            string  `json:"error_reason,omitempty"`
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
	ErrorReason            string  `json:"error_reason,omitempty"`
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

	// CompletionTokensSet forces the completion_tokens column to be written from
	// CompletionTokens even when it is 0. Without it, a terminal cancel/error/
	// timeout row (which delivers 0 tokens) leaves completion_tokens NULL, so the
	// incident-majority 0-token cancels are invisible in telemetry. Success rows
	// already write a real (usually non-zero) count, so this only needs to be set
	// on the terminal cancel/error/timeout constructors (and success, harmlessly).
	CompletionTokensSet bool `json:"completion_tokens_set,omitempty"`

	// InvalidTTFT is a transient (never-persisted) signal that the raw
	// time-to-first-token computed for this outcome was negative and was clamped
	// to 0. The single store-submit funnel emits routing.invalid_ttft when it is
	// set, so any regression of the retried-request shared-Timing bug
	// (FirstContentAt of an early attempt minus a later attempt's DispatchedAt)
	// is loud rather than silent. json:"-" keeps it out of every API payload and
	// neither store impl persists it.
	InvalidTTFT bool `json:"-"`
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

// UsageBucket is a time-bucketed aggregation of usage rows. Minute is retained
// as the field name for wire compatibility with the original minute series.
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

// LeaderboardRow is a single account's aggregate across provider_earnings
// (inference work) combined with reward ledger entries (referral_reward and
// admin_reward). EarningsMicroUSD is the combined total of work + reward.
// Pseudonyms are computed at the API layer from AccountID, never returned
// from the store directly.
type LeaderboardRow struct {
	AccountID              string `json:"account_id"`
	EarningsMicroUSD       int64  `json:"earnings_micro_usd"`        // total = work + reward
	WorkEarningsMicroUSD   int64  `json:"work_earnings_micro_usd"`   // inference payouts
	RewardEarningsMicroUSD int64  `json:"reward_earnings_micro_usd"` // referral_reward + admin_reward
	Tokens                 int64  `json:"tokens"`
	Jobs                   int64  `json:"jobs"`
}

// NetworkTotalsRow holds aggregated network metrics for homepage stats.
type NetworkTotalsRow struct {
	EarningsMicroUSD       int64 `json:"earnings_micro_usd"` // total = work + reward
	WorkEarningsMicroUSD   int64 `json:"work_earnings_micro_usd"`
	RewardEarningsMicroUSD int64 `json:"reward_earnings_micro_usd"`
	Tokens                 int64 `json:"tokens"`
	Jobs                   int64 `json:"jobs"`
	ActiveAccounts         int64 `json:"active_accounts"`
}

// RewardLedgerTypes are the ledger entry types that represent non-inference
// "reward" earnings (network participation incentives) counted on the
// leaderboard separately from inference work earnings.
var RewardLedgerTypes = []LedgerEntryType{LedgerReferralReward, LedgerAdminReward}

// IsRewardLedgerType reports whether t is counted as reward earnings.
func IsRewardLedgerType(t LedgerEntryType) bool {
	for _, rt := range RewardLedgerTypes {
		if t == rt {
			return true
		}
	}
	return false
}

// LedgerEntryType categorizes balance changes.
type LedgerEntryType string

const (
	LedgerDeposit        LedgerEntryType = "deposit"             // consumer funds account
	LedgerCharge         LedgerEntryType = "charge"              // consumer pays for inference
	LedgerPayout         LedgerEntryType = "payout"              // provider credited for serving
	LedgerPlatformFee    LedgerEntryType = "platform_fee"        // Darkbloom platform cut
	LedgerWithdrawal     LedgerEntryType = "withdrawal"          // on-chain withdrawal
	LedgerReferralReward LedgerEntryType = "referral_reward"     // referrer earns share of platform fee
	LedgerStripeDeposit  LedgerEntryType = "stripe_deposit"      // Stripe checkout deposit
	LedgerStripePayout   LedgerEntryType = "stripe_payout"       // user-initiated bank/card withdrawal via Stripe Connect
	LedgerInviteCredit   LedgerEntryType = "invite_credit"       // invite code redemption
	LedgerRefund         LedgerEntryType = "refund"              // reservation refund (request failed before inference)
	LedgerAdminCredit    LedgerEntryType = "admin_credit"        // admin-granted non-withdrawable credit
	LedgerAdminReward    LedgerEntryType = "admin_reward"        // admin-granted withdrawable reward
	LedgerMigration      LedgerEntryType = "migration"           // balance moved between account identities (e.g. legacy key re-keying)
	LedgerFloorDraw      LedgerEntryType = "provider_floor_draw" // base-rewards epoch base income (additive)
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
	StripeAccountCountry   string `json:"stripe_account_country,omitempty"`  // ISO 3166-1 alpha-2 country the Express account is locked to
	StripeDestinationType  string `json:"stripe_destination_type,omitempty"` // "bank" | "card" | ""
	StripeDestinationLast4 string `json:"stripe_destination_last4,omitempty"`
	StripeInstantEligible  bool   `json:"stripe_instant_eligible,omitempty"` // debit-card destination supports Instant Payouts

	// Weekly automatic withdrawals require explicit interactive authorization.
	// NextAt is the exact schedule slot workers must match atomically before
	// debiting; changing or revoking the preference invalidates stale workers.
	StripeAutoWithdrawEnabled      bool       `json:"stripe_auto_withdraw_enabled,omitempty"`
	StripeAutoWithdrawAccountID    string     `json:"-"`
	StripeAutoWithdrawAuthorizedAt *time.Time `json:"stripe_auto_withdraw_authorized_at,omitempty"`
	StripeAutoWithdrawNextAt       *time.Time `json:"stripe_auto_withdraw_next_at,omitempty"`
}

// MaxStripeWithdrawalsByStatusLimit caps ListStripeWithdrawalsByStatus result
// sets. A limit <= 0 no longer means "unbounded" — reading the entire table
// into memory is never intended (threat-model review advisory).
const MaxStripeWithdrawalsByStatusLimit = 1000

const (
	StripeWithdrawalSourceManual    = "manual"
	StripeWithdrawalSourceAutomatic = "automatic"
)

// StripeWithdrawal records a payout via Stripe Connect Express.
// The lifecycle is: pending (debit recorded) → transferred (platform→connected
// account transfer succeeded) → paid (Stripe payout to bank/card succeeded).
// On failure at any stage we re-credit the user via LedgerRefund and set the
// status to "failed".
type StripeWithdrawal struct {
	ID              string     `json:"id"`                        // internal UUID, used as Stripe idempotency key prefix
	AccountID       string     `json:"account_id"`                // internal account that owns the withdrawal
	StripeAccountID string     `json:"stripe_account_id"`         // Stripe connected account (acct_…)
	TransferID      string     `json:"transfer_id,omitempty"`     // Stripe transfer (tr_…)
	PayoutID        string     `json:"payout_id,omitempty"`       // Stripe payout (po_…) we created (instant path)
	SweepPayoutID   string     `json:"sweep_payout_id,omitempty"` // automatic sweep payout (po_…) that claimed this row as paid — lets a later payout.failed for the same sweep reopen it
	AmountMicroUSD  int64      `json:"amount_micro_usd"`          // gross amount debited from ledger
	FeeMicroUSD     int64      `json:"fee_micro_usd"`             // fee retained by platform
	NetMicroUSD     int64      `json:"net_micro_usd"`             // amount transferred to user (gross - fee)
	Method          string     `json:"method"`                    // "standard" | "instant"
	Source          string     `json:"source"`                    // "manual" | "automatic"
	ScheduledFor    *time.Time `json:"scheduled_for,omitempty"`   // weekly schedule slot; automatic withdrawals only
	RetryAfter      *time.Time `json:"-"`                         // internal automatic-transfer retry eligibility
	Status          string     `json:"status"`                    // "pending" | "transferred" | "paid" | "failed"
	FailureReason   string     `json:"failure_reason,omitempty"`  // populated when Status="failed"
	Refunded        bool       `json:"refunded,omitempty"`        // true after the failure refund is credited
	FeeRefunded     bool       `json:"fee_refunded,omitempty"`    // true after the instant fee is credited back (instant payout fell back to the standard sweep)
	CreatedAt       time.Time  `json:"created_at"`
	UpdatedAt       time.Time  `json:"updated_at"`
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

// ProviderFloorDraw is one epoch's base-reward settlement for one machine.
// Idempotent on (ProviderKey, EpochID). AmountMicroUSD is the new money printed
// (max(0, floor − k·earned)); the audit columns record how it was derived.
type ProviderFloorDraw struct {
	ID             int64     `json:"id"`
	ProviderKey    string    `json:"provider_key"`
	AccountID      string    `json:"account_id"`
	EpochID        string    `json:"epoch_id"` // "YYYY-MM" UTC
	AmountMicroUSD int64     `json:"amount_micro_usd"`
	FloorMicroUSD  int64     `json:"floor_micro_usd"`  // scaled floor used
	EarnedMicroUSD int64     `json:"earned_micro_usd"` // organic earned snapshot
	UptimeFrac     float64   `json:"uptime_frac"`
	MemoryGB       int       `json:"memory_gb"` // verified tier
	CreatedAt      time.Time `json:"created_at"`
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
	ProviderKey      string     `json:"provider_key"` // X25519 public key — unifies sessions↔earnings identity (design §8)
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
