package accountfleet

import (
	"encoding/json"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// providerView is the per-machine payload for /v1/me/providers.
type providerView struct {
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
	serialNumber string

	// Trust & attestation
	TrustLevel  string `json:"trust_level"`
	Attested    bool   `json:"attested"`
	MDAVerified bool   `json:"mda_verified"`
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
	RuntimeVerified bool   `json:"runtime_verified"`
	PythonHash      string `json:"python_hash,omitempty"`
	RuntimeHash     string `json:"runtime_hash,omitempty"`

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
	IdleUnloadMins  *int     `json:"idle_unload_mins,omitempty"`
	WarmModels      []string `json:"warm_models,omitempty"`
	CurrentModel    string   `json:"current_model,omitempty"`
	PendingRequests int      `json:"pending_requests"`
	MaxConcurrency  int      `json:"max_concurrency"`
	PrefillTPS      float64  `json:"prefill_tps,omitempty"`
	DecodeTPS       float64  `json:"decode_tps,omitempty"`

	// Reputation
	Reputation reputationView `json:"reputation"`

	// Lifetime stats
	LifetimeRequestsServed  int64 `json:"lifetime_requests_served"`
	LifetimeTokensGenerated int64 `json:"lifetime_tokens_generated"`

	// Payout configuration (via Stripe Connect Express)

	// Timestamps
	RegisteredAt *time.Time `json:"registered_at,omitempty"`
	LastSeen     *time.Time `json:"last_seen,omitempty"`
}

// buildProvider merges a persisted record with the live registry snapshot.
// Either may be nil (a never-connected stored record OR a fresh registration
// that hasn't been persisted yet), but at least one must be non-nil.
func buildProvider(rec *store.ProviderRecord, live *registry.Provider) providerView {
	mp := providerView{Status: "never_seen"}

	// 1. Start from the persisted record (covers offline machines).
	if rec != nil {
		mp.ID = rec.ID
		mp.AccountID = rec.AccountID
		mp.Backend = rec.Backend
		mp.Version = rec.Version
		mp.serialNumber = rec.SerialNumber
		mp.TrustLevel = rec.TrustLevel
		mp.Attested = rec.Attested
		mp.MDAVerified = rec.MDAVerified
		mp.SEPublicKey = rec.SEPublicKey
		// X25519 E2E key from the persisted record so OFFLINE machines still
		// resolve per-node earnings. The live branch below overrides
		// it with live.PublicKey when the machine is currently connected.
		mp.ProviderKey = rec.PublicKey
		mp.RuntimeVerified = rec.RuntimeVerified
		mp.PythonHash = rec.PythonHash
		mp.RuntimeHash = rec.RuntimeHash
		mp.LastChallengeVerified = rec.LastChallengeVerified
		mp.FailedChallenges = rec.FailedChallenges
		mp.LifetimeRequestsServed = rec.LifetimeRequestsServed
		mp.LifetimeTokensGenerated = rec.LifetimeTokensGenerated
		if !rec.RegisteredAt.IsZero() {
			t := rec.RegisteredAt
			mp.RegisteredAt = &t
		}
		if !rec.LastSeen.IsZero() {
			t := rec.LastSeen
			mp.LastSeen = &t
		}
		// Decode embedded JSON blobs.
		if len(rec.Hardware) > 0 {
			_ = json.Unmarshal(rec.Hardware, &mp.Hardware)
		}
		if len(rec.Models) > 0 {
			_ = json.Unmarshal(rec.Models, &mp.Models)
		}
		// AttestationResult holds chip name, SE flags, OS security, system
		// volume hash, etc. Source of truth when we don't have a live snapshot.
		if len(rec.AttestationResult) > 0 {
			var ar attestation.VerificationResult
			if err := json.Unmarshal(rec.AttestationResult, &ar); err == nil {
				if ar.SerialNumber != "" {
					mp.serialNumber = ar.SerialNumber
				}
				if ar.PublicKey != "" {
					mp.SEPublicKey = ar.PublicKey
				}
				mp.SecureEnclave = ar.SecureEnclaveAvailable
				mp.SIPEnabled = ar.SIPEnabled
				mp.SecureBootEnabled = ar.SecureBootEnabled
				mp.AuthenticatedRoot = ar.AuthenticatedRootEnabled
				mp.SystemVolumeHash = ar.SystemVolumeHash
			}
		}
		// Default to offline; will be overwritten below if we have a live snapshot.
		mp.Status = "offline"
	}

	// 2. Overlay the live snapshot if present.
	if live != nil {
		live.Mu().Lock()
		mp.ID = live.ID
		if live.AccountID != "" {
			mp.AccountID = live.AccountID
		}
		mp.Status = string(live.Status)
		mp.Online = live.Status != registry.StatusOffline && live.Status != registry.StatusUntrusted
		hb := live.LastHeartbeat
		if !hb.IsZero() {
			mp.LastHeartbeat = &hb
		}
		// Hardware / models from the live snapshot are authoritative because
		// the provider may have re-registered with new specs.
		mp.Hardware = live.Hardware
		mp.Models = append([]protocol.ModelInfo{}, live.Models...)
		mp.Backend = live.Backend
		mp.Version = live.Version
		mp.TrustLevel = string(live.TrustLevel)
		mp.Attested = live.Attested
		mp.MDAVerified = live.MDAVerified
		mp.SEKeyBound = live.SEKeyBound
		mp.RuntimeVerified = live.RuntimeVerified
		mp.PythonHash = live.PythonHash
		mp.RuntimeHash = live.RuntimeHash
		if !live.LastChallengeVerified.IsZero() {
			t := live.LastChallengeVerified
			mp.LastChallengeVerified = &t
		}
		mp.FailedChallenges = live.FailedChallenges
		// X25519 E2E key — the earnings table is keyed on this. Persisted on the
		// record too, so offline machines resolve earnings; the live
		// value is authoritative when connected.
		if live.PublicKey != "" {
			mp.ProviderKey = live.PublicKey
		}
		mp.LifetimeRequestsServed = live.Stats.RequestsServed
		mp.LifetimeTokensGenerated = live.Stats.TokensGenerated
		mp.PrefillTPS = live.PrefillTPS
		mp.DecodeTPS = live.DecodeTPS

		if live.AttestationResult != nil {
			ar := live.AttestationResult
			if ar.SerialNumber != "" {
				mp.serialNumber = ar.SerialNumber
			}
			if ar.PublicKey != "" {
				mp.SEPublicKey = ar.PublicKey
			}
			mp.SecureEnclave = ar.SecureEnclaveAvailable
			mp.SIPEnabled = ar.SIPEnabled
			mp.SecureBootEnabled = ar.SecureBootEnabled
			mp.AuthenticatedRoot = ar.AuthenticatedRootEnabled
			mp.SystemVolumeHash = ar.SystemVolumeHash
		}
		if live.MDAResult != nil {
			mp.MDAOSVersion = live.MDAResult.OSVersion
			mp.MDASEPVersion = live.MDAResult.SepOSVersion
		}
		// Live system metrics & backend capacity.
		sm := live.SystemMetrics
		mp.SystemMetrics = &sm
		if live.BackendCapacity != nil {
			cap := *live.BackendCapacity
			mp.BackendCapacity = &cap
		}
		if live.IdleUnloadMins != nil {
			v := *live.IdleUnloadMins
			mp.IdleUnloadMins = &v
		}
		mp.WarmModels = append([]string{}, live.WarmModels...)
		mp.CurrentModel = live.CurrentModel
		// Reputation snapshot.
		mp.Reputation = reputationView{
			Score:              live.Reputation.Score(),
			TotalJobs:          live.Reputation.TotalJobs,
			SuccessfulJobs:     live.Reputation.SuccessfulJobs,
			FailedJobs:         live.Reputation.FailedJobs,
			TotalUptimeSeconds: int64(live.Reputation.TotalUptime / time.Second),
			AvgResponseTimeMs:  int64(live.Reputation.AvgResponseTime / time.Millisecond),
			ChallengesPassed:   live.Reputation.ChallengesPassed,
			ChallengesFailed:   live.Reputation.ChallengesFailed,
		}
		live.Mu().Unlock()
		// Concurrency limit lookup acquires its own lock.
		mp.PendingRequests = live.PendingCount()
		mp.MaxConcurrency = live.MaxConcurrency()
	}

	return mp
}
