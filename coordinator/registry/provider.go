package registry

import (
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

// Provider represents a connected provider agent.
type Provider struct {
	ID                string
	Hardware          protocol.Hardware
	Models            []protocol.ModelInfo
	Backend           string
	Location          *store.ProviderLocation
	PublicKey         string // base64-encoded X25519 public key for E2E encryption
	Attested          bool   // true if attestation was verified successfully
	AttestationResult *attestation.VerificationResult
	TrustLevel        TrustLevel             // attestation trust level
	MDAVerified       bool                   // true if Apple Device Attestation cert chain verified
	MDACertChain      [][]byte               // DER-encoded Apple MDA certificate chain (leaf first)
	MDAResult         *attestation.MDAResult // parsed OIDs from Apple cert
	ACMEVerified      bool                   // true if ACME device-attest-01 client cert verified (SE key proven)
	SEKeyBound        bool                   // true if SE key was bound to device via MDA nonce
	Status            ProviderStatus
	Conn              *websocket.Conn
	LastHeartbeat     time.Time
	Stats             protocol.HeartbeatStats // lifetime counters shown to users
	lastSessionStats  protocol.HeartbeatStats // raw counters from the current provider process

	// Account linkage (set when provider authenticates via device auth token)
	AccountID string // internal account ID (from device auth flow)

	// Benchmark data reported at registration
	PrefillTPS float64 // prefill tokens per second
	DecodeTPS  float64 // decode tokens per second

	// Warm model cache tracking
	WarmModels   []string // models currently loaded in provider's memory
	CurrentModel string   // model currently being served

	// Live system metrics from heartbeats
	SystemMetrics protocol.SystemMetrics

	// Live backend capacity from heartbeats (nil for providers without capacity reporting)
	BackendCapacity *protocol.BackendCapacity

	// Reputation tracking
	Reputation Reputation

	// Version and runtime integrity verification
	Version                 string `json:"version,omitempty"`                   // provider binary version (e.g. "0.2.31")
	RuntimeVerified         bool   `json:"runtime_verified"`                    // true if runtime hashes match the known-good manifest
	RuntimeManifestChecked  bool   `json:"runtime_manifest_checked"`            // true only when a manifest was present and hashes were verified (fail-closed for text)
	EncryptedResponseChunks bool   `json:"encrypted_response_chunks,omitempty"` // true when text response chunks are encrypted to the coordinator
	PythonHash              string `json:"python_hash,omitempty"`
	RuntimeHash             string `json:"runtime_hash,omitempty"`
	TemplateHashes          map[string]string

	// Phase 7: Privacy invariant attestation.
	// Self-reported by the provider at registration. SIPEnabled is overridden
	// by the coordinator after each attestation challenge response with a
	// coordinator-verified value. HypervisorActive is informational.
	PrivacyCapabilities *protocol.PrivacyCapabilities `json:"privacy_capabilities,omitempty"`

	// Coordinator-verified SIP status from the most recent attestation challenge.
	// Unlike PrivacyCapabilities.SIPEnabled (provider self-report at registration),
	// this is set by the coordinator after independently checking the challenge response.
	ChallengeVerifiedSIP bool `json:"challenge_verified_sip"`

	// lastPersisted tracks when this provider was last written to the store.
	// Used by PersistProviderThrottled to avoid hammering Postgres on every heartbeat.
	lastPersisted time.Time

	// Challenge-response verification state
	LastChallengeVerified time.Time // last successful challenge verification
	FailedChallenges      int       // consecutive failed challenges

	// untrustedRecoverable marks an untrust as a *transient* missed-challenge
	// deroute (timeout / no-response) that may self-recover on the next passing
	// challenge. It is false for every hard/security deroute. In-memory only —
	// never persisted, because recoverability is meaningless without a live
	// WebSocket and a running challenge loop.
	untrustedRecoverable bool

	mu          sync.Mutex
	pendingReqs map[string]*PendingRequest
}

// AddPending registers a pending request on this provider.
func (p *Provider) AddPending(pr *PendingRequest) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.addPendingLocked(pr)
}

// addPendingLocked registers a pending request. Caller must hold p.mu.
func (p *Provider) addPendingLocked(pr *PendingRequest) {
	p.pendingReqs[pr.RequestID] = pr
}

// RemovePending removes and returns a pending request.
func (p *Provider) RemovePending(requestID string) *PendingRequest {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.removePendingLocked(requestID)
}

// removePendingLocked removes and returns a pending request. Caller must hold p.mu.
func (p *Provider) removePendingLocked(requestID string) *PendingRequest {
	pr := p.pendingReqs[requestID]
	delete(p.pendingReqs, requestID)
	return pr
}

// GetPending retrieves a pending request without removing it.
func (p *Provider) GetPending(requestID string) *PendingRequest {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.pendingReqs[requestID]
}

// SetAttested updates attestation state (thread-safe).
// Note: persistence is handled by the Registry methods that call this,
// via persistProvider() after attestation verification completes.
func (p *Provider) SetAttested(attested bool, trust TrustLevel) {
	p.mu.Lock()
	p.Attested = attested
	p.TrustLevel = trust
	p.mu.Unlock()
}

// SetLastChallengeVerified updates the challenge timestamp (thread-safe).
func (p *Provider) SetLastChallengeVerified(t time.Time) {
	p.mu.Lock()
	p.LastChallengeVerified = t
	p.mu.Unlock()
}

// GetLastChallengeVerified returns the last challenge verification time (thread-safe).
func (p *Provider) GetLastChallengeVerified() time.Time {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.LastChallengeVerified
}

// GetChallengeVerifiedSIP returns whether SIP was verified in the last challenge (thread-safe).
func (p *Provider) GetChallengeVerifiedSIP() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.ChallengeVerifiedSIP
}

func (p *Provider) SetChallengeVerifiedSIP(v bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.ChallengeVerifiedSIP = v
}

// Mu returns the provider's mutex for external callers that need to read
// fields like Status atomically. Prefer dedicated getters where available.
func (p *Provider) Mu() *sync.Mutex {
	return &p.mu
}

// ChallengeShouldStop reports whether the attestation challenge loop should
// stop for this provider. It stops only for a *hard* (non-recoverable) untrust;
// a transiently-untrusted provider keeps being challenged so a later passing
// challenge can restore it via RecordChallengeSuccess. Thread-safe.
func (p *Provider) ChallengeShouldStop() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.Status == StatusUntrusted && !p.untrustedRecoverable
}

// SetAttestationResult stores the parsed attestation result (thread-safe).
func (p *Provider) SetAttestationResult(result *attestation.VerificationResult) {
	p.mu.Lock()
	p.AttestationResult = result
	p.mu.Unlock()
}

// GetAttestationResult returns the current attestation result (thread-safe).
func (p *Provider) GetAttestationResult() *attestation.VerificationResult {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.AttestationResult
}

// pendingCount returns the number of in-flight requests.
// Caller must hold p.mu.
func (p *Provider) pendingCount() int {
	return len(p.pendingReqs)
}

// PendingCount returns the number of in-flight requests (thread-safe).
func (p *Provider) PendingCount() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.pendingCount()
}
