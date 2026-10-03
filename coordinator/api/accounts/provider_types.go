package accounts

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// myReputation is the wire shape for a provider's reputation snapshot.
type myReputation struct {
	TotalJobs          int   `json:"total_jobs"`
	SuccessfulJobs     int   `json:"successful_jobs"`
	FailedJobs         int   `json:"failed_jobs"`
	TotalUptimeSeconds int64 `json:"total_uptime_seconds"`
	AvgResponseTimeMs  int64 `json:"avg_response_time_ms"`
	ChallengesPassed   int   `json:"challenges_passed"`
	ChallengesFailed   int   `json:"challenges_failed"`
}

// myProvider is the per-machine payload for /v1/me/providers.
type myProvider struct {
	ID        string `json:"id"`
	AccountID string `json:"account_id"`

	// Live operational state. Status is "offline" when the machine is not
	// currently connected, "never_seen" when it has a stored record but has
	// not connected since the coordinator started, otherwise mirrors the
	// registry status (online|serving|untrusted).
	Status        string     `json:"status"`
	Online        bool       `json:"online"`
	LastHeartbeat *time.Time `json:"last_heartbeat,omitempty"`
	// Last applied backend-capacity frame; rejected sequence frames only advance
	// LastHeartbeat and must not freshen owner load diagnostics.
	CapacityAcceptedAt *time.Time `json:"capacity_accepted_at,omitempty"`

	// Identity / hardware
	Hardware protocol.Hardware    `json:"hardware"`
	Models   []protocol.ModelInfo `json:"models"`
	// CapacityModelIDs is the catalog/capability-accepted subset used to
	// canonicalize warm models and backend slots. Present-empty means none;
	// omitted means no live capacity evidence (offline/legacy).
	CapacityModelIDs *[]string `json:"capacity_model_ids,omitempty"`
	Backend          string    `json:"backend,omitempty"`
	Version          string    `json:"version,omitempty"`
	OSVersion        string    `json:"os_version,omitempty"` // Current or last app-reported macOS version.
	serialNumber     string

	// Trust & attestation
	TrustLevel  string `json:"trust_level"`
	Attested    bool   `json:"attested"`
	MDAVerified bool   `json:"mda_verified"`
	// Live App Attest guidance is independent of legacy proof fields and is
	// never restored from a stored record. The client honors the lease deadline.
	Verification           registry.Verification `json:"verification"`
	AppAttestAuthorized    bool                  `json:"app_attest_authorized"`
	AuthorizationExpiresAt int64                 `json:"authorization_expires_at,omitempty"`
	// Deprecated: the ACME device-attest-01 leg was removed. Key kept (always
	// false) because shipped provider builds decode it as a required field.
	ACMEVerified bool   `json:"acme_verified"`
	SEKeyBound   bool   `json:"se_key_bound"`
	SEPublicKey  string `json:"se_public_key,omitempty"`
	// ProviderKey is the machine's X25519 E2E public key, used to resolve
	// per-node earnings. Same value senders fetch from /v1/encryption-key, so
	// it is not a secret on the owner's own dashboard. Present only for
	// currently-online machines (it is not persisted on ProviderRecord).
	ProviderKey       string `json:"provider_key,omitempty"`
	SecureEnclave     bool   `json:"secure_enclave"`
	SIPEnabled        bool   `json:"sip_enabled"`
	SecureBootEnabled bool   `json:"secure_boot_enabled"`
	AuthenticatedRoot bool   `json:"authenticated_root_enabled"`
	SystemVolumeHash  string `json:"system_volume_hash,omitempty"`
	MDAOSVersion      string `json:"mda_os_version,omitempty"`
	MDASEPVersion     string `json:"mda_sepos_version,omitempty"`

	// Runtime integrity
	RuntimeVerified bool `json:"runtime_verified"`

	// Challenge state
	LastChallengeVerified *time.Time `json:"last_challenge_verified,omitempty"`
	FailedChallenges      int        `json:"failed_challenges"`

	// Live snapshot (only set when the machine is currently connected)
	SystemMetrics   *protocol.SystemMetrics   `json:"system_metrics,omitempty"`
	BackendCapacity *protocol.BackendCapacity `json:"backend_capacity,omitempty"`
	// IdleUnloadMins is the machine's idle-memory policy as reported in its
	// heartbeats: 0 = always ready (models stay loaded), N = unloaded after N
	// idle minutes and reloaded on demand. Omitted for offline machines and
	// for providers too old to report it. Lets the dashboard render a missing
	// slot as "sleeping, wakes on demand" instead of a warning.
	IdleUnloadMins  *int                          `json:"idle_unload_mins,omitempty"`
	ModelAutopilot  *protocol.ModelAutopilotState `json:"model_autopilot,omitempty"`
	WarmModels      []string                      `json:"warm_models,omitempty"`
	CurrentModel    string                        `json:"current_model,omitempty"`
	PendingRequests int                           `json:"pending_requests"`
	MaxConcurrency  int                           `json:"max_concurrency"`
	PrefillTPS      float64                       `json:"prefill_tps,omitempty"`
	DecodeTPS       float64                       `json:"decode_tps,omitempty"`

	// Reputation
	Reputation myReputation `json:"reputation"`

	// Lifetime stats
	LifetimeRequestsServed  int64 `json:"lifetime_requests_served"`
	LifetimeTokensGenerated int64 `json:"lifetime_tokens_generated"`

	// Payout configuration (via Stripe Connect Express)

	// Timestamps
	RegisteredAt *time.Time `json:"registered_at,omitempty"`
	LastSeen     *time.Time `json:"last_seen,omitempty"`
}

type myProvidersResponse struct {
	Providers             []myProvider `json:"providers"`
	LatestProviderVersion string       `json:"latest_provider_version"`
	MinProviderVersion    string       `json:"min_provider_version"`
	HeartbeatTimeoutSec   int          `json:"heartbeat_timeout_seconds"`
	ChallengeMaxAgeSec    int          `json:"challenge_max_age_seconds"`
}

// myFleetCounts aggregates machine counts by status for the dashboard header.
type myFleetCounts struct {
	Total     int `json:"total"`
	Online    int `json:"online"`          // status==online
	Serving   int `json:"serving"`         // status==serving
	Offline   int `json:"offline"`         // status==offline OR never_seen
	Untrusted int `json:"untrusted"`       // status==untrusted
	Hardware  int `json:"hardware"`        // trust_level==hardware
	NeedsAttn int `json:"needs_attention"` // any of: !runtime_verified, trust!=hardware, untrusted, version below min
}

// mySummaryResponse is the page-level dashboard header at /v1/me/summary.
type mySummaryResponse struct {
	AccountID                   string        `json:"account_id"`
	AvailableBalanceMicroUSD    int64         `json:"available_balance_micro_usd"`
	WithdrawableBalanceMicroUSD int64         `json:"withdrawable_balance_micro_usd"`
	PayoutReady                 bool          `json:"payout_ready"`
	LifetimeMicroUSD            int64         `json:"lifetime_micro_usd"`
	LifetimeJobs                int64         `json:"lifetime_jobs"`
	Last24hMicroUSD             int64         `json:"last_24h_micro_usd"`
	Last24hJobs                 int64         `json:"last_24h_jobs"`
	Last7dMicroUSD              int64         `json:"last_7d_micro_usd"`
	Last7dJobs                  int64         `json:"last_7d_jobs"`
	Counts                      myFleetCounts `json:"counts"`
	LatestProviderVersion       string        `json:"latest_provider_version"`
	MinProviderVersion          string        `json:"min_provider_version"`
}
