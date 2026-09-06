package registry

import (
	"sync"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

// ProviderStatus represents the operational state of a provider.
type ProviderStatus string

const (
	StatusOnline    ProviderStatus = "online"
	StatusServing   ProviderStatus = "serving"
	StatusOffline   ProviderStatus = "offline"
	StatusUntrusted ProviderStatus = "untrusted"
)

// TrustLevel represents the attestation trust level of a provider.
type TrustLevel string

const (
	TrustNone       TrustLevel = "none"        // No attestation provided
	TrustSelfSigned TrustLevel = "self_signed" // Attestation signed by provider's own key
	TrustHardware   TrustLevel = "hardware"    // MDM + MDA + SE key bound to Apple-verified hardware
)

const BackendMLXSwift = "mlx-swift"

// MaxFailedChallenges is the number of consecutive challenge failures before
// a provider is marked untrusted and fully derouted.
const MaxFailedChallenges = 3

func BackendUsesSwiftRuntime(backend string) bool {
	return backend == BackendMLXSwift
}

// Provider represents a connected provider agent.
type Provider struct {
	ID       string
	Hardware protocol.Hardware
	Models   []protocol.ModelInfo
	Backend  string
	// ReportedRuntimeCapabilities is normalized but untrusted Register input.
	// RuntimeCapabilities remains empty until ReconcileAttestedRuntimeCapabilities
	// binds that report to signed claims and approved runtime evidence.
	ReportedRuntimeCapabilities []string
	RuntimeCapabilities         []string
	Location                    *store.ProviderLocation
	PublicKey                   string // base64-encoded X25519 public key for E2E encryption
	Attested                    bool   // true if attestation was verified successfully
	AttestationResult           *attestation.VerificationResult
	TrustLevel                  TrustLevel             // attestation trust level
	MDAVerified                 bool                   // true if Apple Device Attestation cert chain verified
	MDACertChain                [][]byte               // DER-encoded Apple MDA certificate chain (leaf first)
	MDAResult                   *attestation.MDAResult // parsed OIDs from Apple cert
	SEKeyBound                  bool                   // true if SE key was bound to device via MDA nonce

	// DeviceEvidence and ApplicationEvidence are connection state with separate
	// clocks and generations. Neither is persisted as a bearer credential.
	DeviceEvidence                DeviceEvidence
	ApplicationEvidence           ApplicationEvidence
	applicationEvidenceGeneration uint64

	// restoredMDAChain holds the durable Apple-signed MDA cert chain recovered
	// from the store on reconnect (see RestoreProviderState). It is a CANDIDATE
	// only: it is surfaced as a verified proof (MDAVerified/MDACertChain/MDAResult)
	// solely after attachCachedMDAProof re-verifies it against Apple's pinned root
	// AND re-binds it to this connection's SE key at hardware-grant time. Kept
	// unexported so it never serializes to the store or the attestation endpoint.
	restoredMDAChain [][]byte

	// MDMFailureReason records the last MDM verification outcome for this
	// connection, bucketed for observability: "" (verified/none),
	// "device-not-found", "found-not-enrolled", "securityinfo-timeout",
	// "posture-mismatch", or "error". In-memory + per-connection — it explains
	// why a provider is (still) self_signed so the stuck-cohort gauge can
	// distinguish "never enrolled" from "enrolled but unresponsive".
	MDMFailureReason string

	Status ProviderStatus
	// drainingUntil is non-zero while the provider has declared itself
	// draining (heartbeat status "draining" or a typed draining rejection);
	// routing skips it until its next idle/serving heartbeat or the TTL
	// (drain_state.go). Guarded by p.mu.
	drainingUntil    time.Time
	Conn             *websocket.Conn
	writer           *providerWriter
	LastHeartbeat    time.Time
	Stats            protocol.HeartbeatStats // lifetime counters shown to users
	lastSessionStats protocol.HeartbeatStats // raw counters from the current provider process

	// Account linkage (set when provider authenticates via device auth token)
	AccountID string // internal account ID (from device auth flow)

	// PrivateOnly excludes this machine from the public fleet entirely: it
	// serves only its owner's self-route requests. Reported at registration.
	PrivateOnly bool

	// APNs code-identity attestation (v0.6.0). The device token the coordinator
	// pushes the E_K(nonce) code-identity challenge to, bound 1:1 to PublicKey (K).
	// Reported at registration; populated once the provider runs its APNs module.
	APNsDeviceToken string // hex device token from registerForRemoteNotifications
	APNsEnvironment string // "production" | "development" (selects the APNs host)

	// Benchmark data reported at registration
	PrefillTPS float64 // prefill tokens per second
	DecodeTPS  float64 // decode tokens per second
	// PrefixCacheProtocol is the provider-confirmed cache receipt protocol
	// version. Zero means the provider receives no cache fields.
	PrefixCacheProtocol int
	// PrefixCacheV2Models is the validated, connection-scoped capability set
	// keyed by concrete model ID. It is authoritative for v2 receipt identity.
	PrefixCacheV2Models map[string]protocol.PrefixCacheV2Capability
	// Resident capabilities use independent slot epochs and never imply SSD durability.
	PrefixCacheMemoryModels map[string]protocol.PrefixCacheV2Capability
	// PrefixCacheStatuses is the optional, validated, connection-scoped status
	// snapshot for concrete loaded model slots. Reported distinguishes current
	// providers that authoritatively sent [] from old providers that omit it.
	PrefixCacheStatuses       map[string]protocol.PrefixCacheModelStatus
	PrefixCacheStatusReported bool
	// PrefixCacheDonationOutcomes is the last cumulative process-local
	// snapshot. Heartbeats contribute only monotonic deltas to central totals.
	PrefixCacheDonationOutcomes map[string]uint64
	// ToolConstraintProtocol advertises inference-time tool grammar support.
	// ToolConstraintModels is the explicit concrete-model allowlist; required,
	// named, and none choices never route by binary version inference alone.
	ToolConstraintProtocol int
	ToolConstraintModels   map[string]struct{}
	// prefixCacheRevision changes whenever capability identity or quarantine
	// state changes. Scheduler hints snapshot it and revalidate under p.mu so a
	// concurrent heartbeat/proof failure cannot apply a stale cache discount.
	prefixCacheRevision uint64

	// modelIndexIDs is the advertised model-id list the registry's per-model
	// provider index currently holds for this session (model_index.go) — the
	// diff baseline for syncModelIndexLocked. modelIndexDetached is set by
	// Disconnect so a models_update racing the disconnect can only ever remove
	// entries, never re-insert the dead session. Both guarded by p.mu.
	modelIndexIDs      []string
	modelIndexDetached bool

	// Warm model cache tracking
	WarmModels   []string // models currently loaded in provider's memory
	CurrentModel string   // model currently being served

	// Live system metrics from heartbeats
	SystemMetrics protocol.SystemMetrics

	// IdleUnloadMins is the provider's reported idle-memory policy (heartbeat
	// `idle_unload_mins`): 0 = models stay resident, N = unload after N idle
	// minutes. nil until a heartbeat reports it (legacy providers never do).
	// Sticky within a connection — the policy is provider config, so a
	// reporting provider carries it in every heartbeat. Guarded by p.mu.
	// Surfaced on /v1/me/providers; not a routing input.
	IdleUnloadMins *int

	// Live backend capacity from heartbeats (nil for providers without capacity reporting)
	BackendCapacity *protocol.BackendCapacity

	// capacitySamplesAt is the coordinator time of the last accepted slot
	// sample reconciliation. Separate from LastHeartbeat: rejected capacity
	// frames prove liveness but must not erase elapsed sample age. Guarded by p.mu.
	capacitySamplesAt time.Time

	// capacitySeq is the highest BackendCapacity.CapacitySeq applied on THIS
	// connection; capacityQuoteCapable latches true the first time a heartbeat
	// carries seq > 0 (routing v2 W2: seq-stamping providers also answer
	// capacity probes — see protocol/messages.go CapacitySeq).
	//
	// Per-connection on purpose: the provider process restarts its counter on
	// every reconnect, and Register creates a fresh *Provider per connection
	// (see the CodeAttested field's contract), so both fields reset to their
	// zero values with the object — a reconnected provider's seq 1 is never
	// compared against the previous connection's high-water mark. Guarded by
	// p.mu.
	capacitySeq          uint64
	capacityQuoteCapable bool

	// kvBackends is the last KV-cache backend observation each SLOT (keyed by
	// model) named on a heartbeat — the resolved kind AND, when the slot
	// degraded, why — for the v0.8.0 paged rollout's per-backend segmentation.
	// Sticky within a provider session and deliberately NOT cleared by a nil
	// BackendCapacity, so a slot that crashes or is evicted mid-request can
	// still be attributed. A missing key is UNKNOWN and must never read as a
	// backend kind. Guarded by p.mu; see kv_backend.go for the full contract.
	kvBackends map[string]slotKVBackend

	// Reputation tracking
	Reputation Reputation

	// Version and runtime integrity verification
	Version                 string `json:"version,omitempty"`                   // provider binary version (e.g. "0.2.31")
	RuntimeVerified         bool   `json:"runtime_verified"`                    // true if runtime hashes match the known-good manifest
	RuntimeManifestChecked  bool   `json:"runtime_manifest_checked"`            // true only when a manifest was present and hashes were verified (fail-closed for text)
	MetallibVerified        bool   `json:"metallib_verified"`                   // explicit mlx_metallib entry matched the approved runtime manifest
	EncryptedResponseChunks bool   `json:"encrypted_response_chunks,omitempty"` // true when text response chunks are encrypted to the coordinator
	PythonHash              string `json:"python_hash,omitempty"`
	RuntimeHash             string `json:"runtime_hash,omitempty"`
	TemplateHashes          map[string]string

	// Phase 7: Privacy invariant attestation.
	// Self-reported by the provider at registration. SIPEnabled is overridden
	// by the coordinator after each attestation challenge response with a
	// coordinator-verified value.
	PrivacyCapabilities *protocol.PrivacyCapabilities `json:"privacy_capabilities,omitempty"`

	// Coordinator-verified SIP status from the most recent attestation challenge.
	// Unlike PrivacyCapabilities.SIPEnabled (provider self-report at registration),
	// this is set by the coordinator after independently checking the challenge response.
	ChallengeVerifiedSIP bool `json:"challenge_verified_sip"`

	// lastPersisted tracks when this provider was last written to the store.
	// Used by PersistProviderThrottled to avoid hammering Postgres on every heartbeat.
	lastPersisted time.Time

	// lastReputationPersisted tracks when this provider's reputation was last
	// written to the store from the heartbeat path. Used by
	// persistReputationThrottled so accumulated uptime survives restarts without
	// a DB write on every 30s heartbeat. Zero value persists on the first
	// heartbeat. (Challenge/job handlers persist reputation unthrottled.)
	lastReputationPersisted time.Time

	// Challenge-response verification state
	LastChallengeVerified time.Time // last successful challenge verification
	FailedChallenges      int       // consecutive failed challenges

	// applicationProofSettled broadcasts completion of the initial direct
	// application proof attempt. APNs waits for it so approved reconnects and
	// releases cannot race an unnecessary push.
	applicationProofSettled chan struct{}
	applicationProofOnce    sync.Once

	// challengeKick coalesces requests for an immediate out-of-band attestation
	// challenge (e.g. after a release-policy refresh invalidated this provider's
	// application evidence) so the connection's challenge loop re-verifies now
	// instead of waiting out the periodic ticker. Buffered(1); nil on bare test
	// Providers, where both endpoints degrade to no-ops.
	challengeKick chan struct{}

	// untrustEpoch is bumped on every HARD untrust of this provider (DAR-326
	// FIX A). The trust-reuse write-through (api.recordTrustReuse) captures it at
	// grant time and re-checks it immediately before persisting; a bump in between
	// means a hard untrust raced the grant, so the stale `hardware` row is not
	// persisted. This closes the write-after-delete race where an async write could
	// land AFTER the hard-untrust's synchronous delete and resurrect a row that a
	// restart would reseed. atomic so it is read/written without p.mu.
	untrustEpoch atomic.Uint64

	// untrustedRecoverable marks an untrust as a *transient* missed-challenge
	// deroute (timeout / no-response) that may self-recover on the next passing
	// challenge. It is false for every hard/security deroute. In-memory only —
	// never persisted, because recoverability is meaningless without a live
	// WebSocket and a running challenge loop.
	untrustedRecoverable bool

	// CodeAttested is true once this connection passed the APNs code-identity
	// round-trip (E_K(nonce) push → provider returns the decrypted nonce + a
	// Sign_SE signature over the WS). In-memory + per-connection: a fresh Provider
	// is created on every (re)connect (default false) and discarded on Disconnect,
	// so a SIP downgrade — which needs a reboot that drops the WS — forces
	// re-attestation. Never persisted.
	CodeAttested      bool
	FreshCodeAttested bool

	desiredModelsSent                 bool
	runtimeCapabilitiesReconciled     bool
	lastReconciledRuntimeCapabilities []string
	lastDesiredModels                 []protocol.DesiredModelEntry
	desiredModelsSendMu               sync.Mutex

	mu          sync.Mutex
	pendingReqs map[string]*PendingRequest

	// registry back-pointer, set once in Register (nil for bare test Providers).
	// SetAttestationResult uses it to bind this session's id to its stable
	// identity so the fault-tracking state (breakers/cooldowns) keys by identity
	// and survives reconnect churn. Read-only after Register.
	registry *Registry
	// gate is this session's current routing-gate state (gate_state.go): the
	// session-keyed gate from Register until attestation binds the stable
	// identity, then the identity's gate. Atomic so the scan (under p.mu) and
	// the recorders (without p.mu) read it without another lock; written only
	// under r.gatesMu (attachSessionGate / bindStableFaultKey). nil for a bare
	// test Provider — every gate read treats nil as "no state".
	gate                 atomic.Pointer[gateState]
	gateDisconnectedAtNS atomic.Int64
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
	pr := p.removePendingLocked(requestID)
	p.mu.Unlock()
	if pr != nil && p.registry != nil {
		p.registry.MarkCacheAttemptTerminal(pr)
	}
	return pr
}

// RemovePendingForFirstContentTimeout atomically rechecks provider ingress
// while holding pending ownership. deferred is true when an on-time event won
// the deadline race and timeout cleanup must wait for its delivery/settlement.
func (p *Provider) RemovePendingForFirstContentTimeout(
	requestID string,
) (pr *PendingRequest, deferred bool) {
	p.mu.Lock()
	pr = p.pendingReqs[requestID]
	if pr != nil && pr.FirstContentIngressArrivedByDeadline() {
		p.mu.Unlock()
		return nil, true
	}
	if pr != nil {
		pr = p.removePendingLocked(requestID)
	}
	p.mu.Unlock()
	if pr != nil && p.registry != nil {
		p.registry.MarkCacheAttemptTerminal(pr)
	}
	return pr, false
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

// BeginPendingChunkIngress atomically resolves pending ownership and publishes
// the chunk-ingress marker against concurrent RemovePending cleanup.
func (p *Provider) BeginPendingChunkIngress(requestID string) (*PendingRequest, time.Time) {
	p.mu.Lock()
	defer p.mu.Unlock()
	pr := p.pendingReqs[requestID]
	if pr == nil {
		return nil, time.Time{}
	}
	return pr, pr.BeginProviderChunkIngress()
}

// MarkPendingCompletionIngressNow atomically resolves pending ownership and
// publishes completion ingress before asynchronous settlement.
func (p *Provider) MarkPendingCompletionIngressNow(
	requestID string,
) (*PendingRequest, time.Time) {
	p.mu.Lock()
	defer p.mu.Unlock()
	pr := p.pendingReqs[requestID]
	if pr == nil {
		return nil, time.Time{}
	}
	return pr, pr.MarkCompletionIngressNow()
}

// Mu returns the provider's mutex for external callers that need to read
// fields like Status atomically. Prefer dedicated getters where available.
func (p *Provider) Mu() *sync.Mutex {
	return &p.mu
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

// MaxConcurrency returns the dynamic max concurrent request limit.
// Uses hardware-based estimation when backend capacity is reported.
// Falls back to DefaultMaxConcurrent for providers without capacity reporting.
func (p *Provider) MaxConcurrency() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.maxConcurrency()
}

// MaxConcurrencyForModel returns the concurrency limit for a specific model.
// A positive provider-reported slot cap wins; zero/missing preserves the
// legacy provider-level fallback.
func (p *Provider) MaxConcurrencyForModel(model string) int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.maxConcurrencyForModelLocked(model)
}

// ReportedTokenBudgetMaxForModel returns the provider's most recently reported
// live token budget (ActiveTokenBudgetMax) for the given model, or 0 when the
// provider has reported no per-model token budget. The provider derives this
// value from live memory headroom (see BatchScheduler+Telemetry.swift
// tokenBudgetMax = activeTokenBudgetUsed + headroom/kvBytesPerToken, floored at
// 1024), so it SHRINKS under memory pressure and can fall below the model context
// window. The dispatch path (classifyRejection) uses it to tell a fleet-wide
// context overflow (budget >= model context ⇒ the provider's admission cap
// min(context,budget) was the context, so every provider rejects identically)
// apart from THIS node's shrunk KV budget (budget < context ⇒ a healthier
// provider may still serve), which the bare "batch token budget" wire string
// alone cannot distinguish.
func (p *Provider) ReportedTokenBudgetMaxForModel(model string) int64 {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.BackendCapacity == nil {
		return 0
	}
	for _, slot := range p.BackendCapacity.Slots {
		if slot.Model == model {
			return slot.ActiveTokenBudgetMax
		}
	}
	return 0
}

// maxConcurrency is the lock-free version (caller must hold p.mu).
//
// Tier values were lowered in Phase 2 of the routing-algorithm rework
// (was 4/8/16/24/32). The old caps were derived from "how many
// requests can theoretically fit in GPU memory"; the new caps reflect
// "how many concurrent decodes a single MLX backend can run before
// per-request TPS collapses". Empirically this is much smaller than
// the memory-derived ceiling. Pushing past it makes each request slow
// without increasing fleet throughput.
func (p *Provider) maxConcurrency() int {
	if p.BackendCapacity == nil {
		return DefaultMaxConcurrent
	}

	// Token-budget providers use budget-based admission; the concurrency
	// cap is just a safety valve.
	for _, slot := range p.BackendCapacity.Slots {
		if slot.ActiveTokenBudgetMax > 0 {
			return 24
		}
	}

	// Hardware-based cap using total memory reported by the provider.
	memGB := p.BackendCapacity.TotalMemoryGB
	if memGB <= 0 {
		memGB = float64(p.Hardware.MemoryGB)
	}
	var cap int
	switch {
	case memGB <= 24:
		cap = 2
	case memGB <= 48:
		cap = 4
	case memGB <= 96:
		cap = 6
	case memGB <= 128:
		cap = 8
	default:
		cap = 12
	}
	return cap
}

// maxConcurrencyForModelLocked is the lock-free model-aware concurrency cap.
// Caller must hold p.mu.
func (p *Provider) maxConcurrencyForModelLocked(model string) int {
	if p.BackendCapacity != nil {
		for _, slot := range p.BackendCapacity.Slots {
			if slot.Model == model && slot.MaxConcurrency > 0 {
				return slot.MaxConcurrency
			}
		}
	}
	return p.maxConcurrency()
}

func (p *Provider) pendingCountForModelLocked(model string) int {
	count := 0
	for _, pr := range p.pendingReqs {
		if pr.Model == model {
			count++
		}
	}
	return count
}

func (p *Provider) hasReportedMaxConcurrencyForModelLocked(model string) bool {
	if p.BackendCapacity == nil {
		return false
	}
	for _, slot := range p.BackendCapacity.Slots {
		if slot.Model == model && slot.MaxConcurrency > 0 {
			return true
		}
	}
	return false
}

func (p *Provider) pendingLoadForModelLocked(model string) int {
	if !p.hasReportedMaxConcurrencyForModelLocked(model) {
		return p.pendingCount()
	}

	load := p.pendingCountForModelLocked(model)
	if p.BackendCapacity != nil {
		for _, slot := range p.BackendCapacity.Slots {
			if slot.Model != model {
				continue
			}
			backendLoad := slot.NumRunning + slot.NumWaiting
			if backendLoad > load {
				load = backendLoad
			}
			break
		}
	}
	return load
}

// trustMeetsMinimum returns true if the given trust level meets the minimum.
func (r *Registry) trustMeetsMinimum(level TrustLevel) bool {
	return trustRank(level) >= trustRank(r.MinTrustLevel)
}

// trustRank returns a numeric rank for trust levels (higher = more trusted).
// Returns -1 for unknown/invalid trust levels.
func trustRank(t TrustLevel) int {
	switch t {
	case TrustHardware:
		return 2
	case TrustSelfSigned:
		return 1
	case TrustNone:
		return 0
	default:
		return -1
	}
}
