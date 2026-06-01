package api

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// myReputation is the wire shape for a provider's reputation snapshot.
type myReputation struct {
	Score              float64 `json:"score"`
	TotalJobs          int     `json:"total_jobs"`
	SuccessfulJobs     int     `json:"successful_jobs"`
	FailedJobs         int     `json:"failed_jobs"`
	TotalUptimeSeconds int64   `json:"total_uptime_seconds"`
	AvgResponseTimeMs  int64   `json:"avg_response_time_ms"`
	ChallengesPassed   int     `json:"challenges_passed"`
	ChallengesFailed   int     `json:"challenges_failed"`
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

	// Identity / hardware
	Hardware     protocol.Hardware    `json:"hardware"`
	Models       []protocol.ModelInfo `json:"models"`
	Backend      string               `json:"backend,omitempty"`
	Version      string               `json:"version,omitempty"`
	SerialNumber string               `json:"serial_number,omitempty"`

	// Trust & attestation
	TrustLevel        string   `json:"trust_level"`
	Attested          bool     `json:"attested"`
	MDAVerified       bool     `json:"mda_verified"`
	ACMEVerified      bool     `json:"acme_verified"`
	SEKeyBound        bool     `json:"se_key_bound"`
	SEPublicKey       string   `json:"se_public_key,omitempty"`
	SecureEnclave     bool     `json:"secure_enclave"`
	SIPEnabled        bool     `json:"sip_enabled"`
	SecureBootEnabled bool     `json:"secure_boot_enabled"`
	AuthenticatedRoot bool     `json:"authenticated_root_enabled"`
	SystemVolumeHash  string   `json:"system_volume_hash,omitempty"`
	MDACertChain      []string `json:"mda_cert_chain_b64,omitempty"`
	MDASerial         string   `json:"mda_serial,omitempty"`
	MDAUDID           string   `json:"mda_udid,omitempty"`
	MDAOSVersion      string   `json:"mda_os_version,omitempty"`
	MDASEPVersion     string   `json:"mda_sepos_version,omitempty"`

	// Runtime integrity
	RuntimeVerified bool   `json:"runtime_verified"`
	PythonHash      string `json:"python_hash,omitempty"`
	RuntimeHash     string `json:"runtime_hash,omitempty"`

	// Challenge state
	LastChallengeVerified *time.Time `json:"last_challenge_verified,omitempty"`
	FailedChallenges      int        `json:"failed_challenges"`

	// Live snapshot (only set when the machine is currently connected)
	SystemMetrics   *protocol.SystemMetrics   `json:"system_metrics,omitempty"`
	BackendCapacity *protocol.BackendCapacity `json:"backend_capacity,omitempty"`
	WarmModels      []string                  `json:"warm_models,omitempty"`
	CurrentModel    string                    `json:"current_model,omitempty"`
	PendingRequests int                       `json:"pending_requests"`
	MaxConcurrency  int                       `json:"max_concurrency"`
	PrefillTPS      float64                   `json:"prefill_tps,omitempty"`
	DecodeTPS       float64                   `json:"decode_tps,omitempty"`

	// Reputation
	Reputation myReputation `json:"reputation"`

	// Lifetime stats
	LifetimeRequestsServed  int64 `json:"lifetime_requests_served"`
	LifetimeTokensGenerated int64 `json:"lifetime_tokens_generated"`

	// Per-node earnings (lifetime).
	EarningsTotalMicroUSD int64 `json:"earnings_total_micro_usd"`
	EarningsCount         int64 `json:"earnings_count"`

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
