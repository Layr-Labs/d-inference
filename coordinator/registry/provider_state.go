package registry

import (
	"sync"
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

type TokenAdmission struct {
	AdmittedOutputTokens int
	EstimatedOutput      bool
	AccountOutputLimited bool
	AccountTier          string
	KeyOutputLimited     bool
	KeyOutputRPS         float64
	KeyOutputBurst       int
}

func (a TokenAdmission) TracksOutput() bool {
	return a.AccountOutputLimited || a.KeyOutputLimited
}

// PendingRequest is a channel-based handle for an in-flight inference request.
type PendingRequest struct {
	RequestID string
	// Attempt is the zero-based dispatch attempt number that produced this
	// pending request. It lets outcome telemetry correlate the final result
	// with the routing decision record for the same attempt.
	Attempt    int
	ProviderID string
	// Model is the CONCRETE build id used for routing, admission, billing, and
	// warm-model matching (e.g. "mlx-community/gemma-4-26B-A4B-it-qat-4bit").
	Model string
	// PublicModel is the consumer-facing name the caller requested (e.g.
	// "gemma-4-26b"). When the request used a raw build id directly this equals
	// Model. Responses echo PublicModel so consumers never see the quant/build.
	PublicModel string
	ConsumerKey string
	// KeyID is the public ID of the API key that originated the request, used
	// for per-key usage and spend attribution. Empty for account-scoped/legacy
	// callers (Privy JWT, admin, provider tokens, unlinked keys without an ID).
	KeyID string
	// KeyLimitMicroUSD / KeyLimitReset carry the originating key's spend cap so
	// the per-key cap can be re-enforced when a provider's custom price tops up
	// the reservation above the platform rate. Nil limit = no per-key cap.
	KeyLimitMicroUSD *int64
	KeyLimitReset    string
	ConsumerLocation *store.ProviderLocation
	// IsResponsesAPI tracks requests received through /v1/responses so the
	// coordinator can translate provider chat-completions output back into
	// Responses API objects for SDK clients.
	IsResponsesAPI bool
	// AllowedProviderSerials optionally restricts routing to providers with
	// one of these attested hardware serials. Empty means the request may
	// route to any eligible provider.
	AllowedProviderSerials []string
	// SelfRouteOnly restricts routing to providers owned by OwnerAccountID
	// (the "use my own machine" path). When set, the scheduler skips every
	// provider whose AccountID != OwnerAccountID and never falls back to the
	// public fleet. The owner-match is on the coordinator-stamped AccountID,
	// never on any client-supplied value.
	SelfRouteOnly bool
	// PreferOwner is the "prefer my own machine, but fall back to the paid
	// fleet" mode. Unlike SelfRouteOnly it does NOT exclude public providers:
	// the scheduler picks the caller's own machine whenever one can serve, and
	// only falls back to the public fleet (charged normally) when none can. The
	// hardware-trust floor is relaxed for the caller's own (possibly un-enrolled)
	// machine, exactly as for SelfRouteOnly, but never for public providers.
	// Billing is decided at settlement: free if an owned machine actually served
	// it, paid otherwise — so a PreferOwner request takes a normal reservation
	// up front (unlike SelfRouteOnly, which skips it).
	PreferOwner bool
	// OwnerAccountID is the authenticated account that must own the serving
	// provider when SelfRouteOnly or PreferOwner is set. Stamped server-side
	// from the request's authenticated identity.
	OwnerAccountID string
	// FreeSelfRoute marks a request that must settle at zero cost (no charge,
	// no platform fee, no provider payout) because it is served by a machine
	// the requesting account owns. handleComplete re-verifies ownership of the
	// serving provider before honoring this flag.
	FreeSelfRoute bool
	// EstimatedPromptTokens is a coordinator-side heuristic used only for
	// routing and queue admission. It does not need tokenizer-perfect accuracy.
	EstimatedPromptTokens int
	// RequiresVision is true when the request carries image/video input. Such a
	// request must only be routed to a provider advertising a vision-capable
	// (VLM) build for the resolved model; otherwise the provider would silently
	// drop the media and answer image-blind. Set by the consumer handler from the
	// parsed content parts; enforced in the candidate filter and final admit.
	RequiresVision bool
	// Traits carries request-shape attributes beyond the model id (tool
	// schemas, retry version-diversity) that gate or bias provider selection.
	// Set by the consumer handler; enforced in the candidate filter and final
	// admit. See RequestTraits.
	Traits RequestTraits
	// RequestedMaxTokens is the consumer's requested output budget (or a
	// sensible default when omitted). It is used for backlog estimation.
	RequestedMaxTokens int
	// MaxTTFTMs is an optional per-request TTFT ceiling in milliseconds.
	// When > 0, the scheduler only selects providers whose estimated TTFT is
	// <= MaxTTFTMs. Used by public inference routes to honor the public
	// TTFT target. Self-route / prefer-owner requests leave this at 0.
	MaxTTFTMs float64
	// MinDecodeTPS is an optional per-request sustained-decode floor in tokens/sec
	// (Routing v2 W2). When > 0, the scheduler PREFERS providers that would still
	// deliver >= MinDecodeTPS to a newly admitted request (i.e. not overpack a
	// provider into a degraded stream). It is a SOFT preference: if no candidate
	// meets the floor, the full pool is kept so the request is still served
	// (cold-dispatch/queue spill is a separate concern). 0 disables it.
	MinDecodeTPS float64
	// CacheAffinityKey is SHA256(prompt_cache_key) from the request body. Empty
	// means no cache-affinity routing. It is scoped again by account and model in
	// the registry tracker and is never persisted.
	CacheAffinityKey string
	// TokenAdmission records the output-token charge admitted at request time so
	// successful completion can reconcile any positive actual-output delta.
	TokenAdmission TokenAdmission
	AcceptedCh     chan struct{}           // signalled when provider accepts request
	ChunkCh        chan string             // SSE data chunks
	CompleteCh     chan protocol.UsageInfo // closed after usage sent
	ErrorCh        chan protocol.InferenceErrorMessage
	SessionPrivKey *[32]byte // E2E session private key for decrypting responses
	SESignature    string    // SE signature over response hash
	ResponseHash   string    // SHA-256 of response data

	// ReservedMicroUSD is the balance atomically debited at pre-flight.
	// The post-inference charge adjusts for the difference between the
	// actual cost and this reservation, preventing billing race conditions.
	ReservedMicroUSD int64
	// BaseReservedMicroUSD is the shared base reservation (platform price)
	// charged once per request. ReservedMicroUSD may exceed it after a
	// provider-specific top-up; the difference (the per-attempt "extra") must
	// be refunded if this attempt is abandoned (speculative loser, retry,
	// timeout). The base itself is refunded once globally or settled by the
	// winning attempt.
	BaseReservedMicroUSD int64
	// ServiceReservation marks a trusted service account request whose pre-router
	// admission used an in-memory hold instead of a synchronous ledger debit.
	ServiceReservation   bool
	reservationMu        sync.Mutex
	reservationFinalized bool

	// Timing fields for latency decomposition. Written and read by the
	// consumer/dispatch goroutine that owns the request. The reputation latency
	// sample is recorded from that goroutine at commit (see
	// dispatch.writeCommittedResponse). The ONE field the provider read-loop
	// goroutine (handleComplete) also needs — FirstChunkAt, for the routing
	// telemetry decode-throughput metric — must be accessed via
	// MarkFirstChunkArrived / FirstChunkAtSafe, which guard it with timingMu so
	// that cross-goroutine access is race-free. All other Timing fields remain
	// dispatch-goroutine-only.
	Timing   *RequestTiming
	timingMu sync.Mutex
}

// MarkReservationFinalized returns true only for the first settlement or refund
// of a pre-flight balance reservation. It prevents a terminal provider error
// racing with a late completion from crediting or refunding the same reservation
// twice.
func (pr *PendingRequest) MarkReservationFinalized() bool {
	ok, _ := pr.FinalizeReservation(nil)
	return ok
}

// FinalizeReservation runs settle while holding the reservation finalization
// lock and marks the reservation finalized only if settle succeeds. It returns
// false when another terminal path already finalized the reservation.
func (pr *PendingRequest) FinalizeReservation(settle func() error) (bool, error) {
	pr.reservationMu.Lock()
	defer pr.reservationMu.Unlock()
	if pr.reservationFinalized {
		return false, nil
	}
	if settle != nil {
		if err := settle(); err != nil {
			return false, err
		}
	}
	pr.reservationFinalized = true
	return true, nil
}

type RequestTiming struct {
	ReceivedAt     time.Time // handler entry
	ParsedAt       time.Time // after parse + validate
	ReservedAt     time.Time // after balance reservation
	RoutedAt       time.Time // after provider selection (including queue wait)
	EncryptedAt    time.Time // after E2E encryption
	QueuedAt       time.Time // set when request enters the queue
	DispatchedAt   time.Time // set when request is sent to provider via WebSocket
	FirstChunkAt   time.Time // set when first inference chunk arrives from provider
	FirstContentAt time.Time // set when first content-bearing chunk is committed
}

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
	MDMFailureReason  string
	Status            ProviderStatus
	Conn              *websocket.Conn
	LastHeartbeat     time.Time
	Stats             protocol.HeartbeatStats // lifetime counters shown to users
	lastSessionStats  protocol.HeartbeatStats // raw counters from the current provider process

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

	// lastReputationPersisted throttles heartbeat-driven reputation writes.
	lastReputationPersisted time.Time

	// Challenge-response verification state
	LastChallengeVerified time.Time // last successful challenge verification
	FailedChallenges      int       // consecutive failed challenges

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
	CodeAttested bool

	mu          sync.Mutex
	pendingReqs map[string]*PendingRequest
}

// providerSupportsPrivateTextLocked is the SINGLE routing chokepoint for
// private/text traffic. It is a method on *Registry (not a free function) so the
// APNs code-identity gate can consult the live rollout policy
// (codeAttestationEnforcedLocked) rather than a value stamped at registration —
// that is what lets the grace→enforce deadline flip without a reconnect. Callers
// hold r.mu (every call site is inside an r-locked Registry method).
func (r *Registry) providerSupportsPrivateTextLocked(p *Provider) bool {
	if p.PublicKey == "" || !privateTextBackendSupported(p.Backend) || !p.EncryptedResponseChunks {
		return false
	}
	if !p.RuntimeManifestChecked {
		return false
	}
	// Require coordinator-verified SIP (from attestation challenge) rather
	// than trusting the provider's self-reported SIPEnabled field.
	if !p.ChallengeVerifiedSIP {
		return false
	}
	// v0.6.0 APNs code-identity gate — the SINGLE chokepoint, no self-route
	// exemption (gate everyone). Enforced only once configured AND past the grace
	// deadline, so the fleet keeps routing through the rollout; fail-closed after.
	if r.codeAttestationEnforcedLocked() && !p.CodeAttested {
		return false
	}
	caps := p.PrivacyCapabilities
	if caps == nil {
		return false
	}
	// Only mlx-swift is routable (enforced by privateTextBackendSupported above).
	// Python-specific caps (PythonRuntimeLocked, DangerousModulesBlocked) are
	// retained in the protocol struct for wire backward compat but are no longer
	// required for routing.
	return caps.TextBackendInprocess &&
		caps.TextProxyDisabled &&
		caps.AntiDebugEnabled &&
		caps.CoreDumpsDisabled &&
		caps.EnvScrubbed
}

func privateTextBackendSupported(backend string) bool {
	// Python/legacy inprocess-mlx backend is deprecated and no longer
	// routable. Only Swift (mlx-swift) providers are admitted.
	return backend == BackendMLXSwift
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

func (p *Provider) GrantHardwareIfNotUntrusted() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.Status == StatusUntrusted {
		return false
	}
	p.Attested = true
	p.TrustLevel = TrustHardware
	return true
}

func (p *Provider) GetTrustLevel() TrustLevel {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.TrustLevel
}

func (p *Provider) GetStatus() ProviderStatus {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.Status
}

func (p *Provider) SetMDMFailureReason(reason string) {
	p.mu.Lock()
	p.MDMFailureReason = reason
	p.mu.Unlock()
}

func (p *Provider) GetMDMFailureReason() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.MDMFailureReason
}

func (p *Provider) SetMDAProofIfHardware(certChain [][]byte, mdaResult *attestation.MDAResult) bool {
	if mdaResult == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.TrustLevel != TrustHardware {
		return false
	}
	if p.AttestationResult == nil || mdaResult.DeviceSerial != p.AttestationResult.SerialNumber {
		return false
	}
	p.MDAVerified = true
	p.MDACertChain = certChain
	p.MDAResult = mdaResult
	return true
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

// SetCodeAttested records the result of the APNs code-identity round-trip
// (thread-safe). Set true only after the provider returns a valid decrypted
// nonce + Sign_SE over the WebSocket; in-memory only (never persisted).
func (p *Provider) SetCodeAttested(v bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.CodeAttested = v
}

// GetCodeAttested reports whether this connection passed code-identity
// attestation (thread-safe).
func (p *Provider) GetCodeAttested() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.CodeAttested
}

// SetCodeAttestationConfigured records whether an APNs code-identity attestor is
// wired. When configured the coordinator issues code-identity challenges; whether
// a passing challenge is REQUIRED for routing is governed separately by the
// enforcement deadline (SetCodeAttestationDeadline). Call during server setup.
func (r *Registry) SetCodeAttestationConfigured(v bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.codeAttestationConfigured = v
}

// SetCodeAttestationDeadline sets the instant at which code-identity attestation
// becomes MANDATORY for routing. A zero time means "grace/observe indefinitely"
// (challenge + measure, but keep routing un-attested providers). Safe to call at
// runtime; the gate re-reads it on every routing decision.
func (r *Registry) SetCodeAttestationDeadline(t time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.codeAttestationDeadline = t
}

// SetCodeAttestationPolicy sets both knobs atomically (used by tests).
func (r *Registry) SetCodeAttestationPolicy(configured bool, deadline time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.codeAttestationConfigured = configured
	r.codeAttestationDeadline = deadline
}

// CodeAttestationConfigured reports whether an APNs attestor is wired (so the
// connection handler should issue code-identity challenges). Thread-safe.
func (r *Registry) CodeAttestationConfigured() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.codeAttestationConfigured
}

// CodeAttestationEnforced reports whether code-identity attestation is currently
// mandatory for routing (configured AND past the deadline). Thread-safe.
func (r *Registry) CodeAttestationEnforced() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.codeAttestationEnforcedLocked()
}

// codeAttestationEnforcedLocked reports whether code-identity attestation is
// currently MANDATORY for routing. Caller must hold r.mu. Enforcement begins only
// when an attestor is configured AND a non-zero deadline has been reached; before
// then the fleet routes un-attested providers (grace window) while still being
// challenged.
func (r *Registry) codeAttestationEnforcedLocked() bool {
	if !r.codeAttestationConfigured || r.codeAttestationDeadline.IsZero() {
		return false
	}
	return !time.Now().Before(r.codeAttestationDeadline)
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

// SetAttestationResult stores a snapshot of the parsed attestation result
// (thread-safe). It copies the struct instead of retaining the caller's
// pointer: the registration path mutates a single local `result` across several
// validation checks (Valid/Error/...) while `persistProviderNow` asynchronously
// `json.Marshal`s `p.AttestationResult` under `p.mu`. Aliasing the caller's
// struct would let those unsynchronized field writes race the marshal (caught by
// `-race` in coordinator/api). VerificationResult is all value-typed fields, so a
// shallow copy is a complete, immutable snapshot owned by the Provider.
func (p *Provider) SetAttestationResult(result *attestation.VerificationResult) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if result == nil {
		p.AttestationResult = nil
		return
	}
	snapshot := *result
	p.AttestationResult = &snapshot
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

func (p *Provider) hasConcurrencyHeadroomForModelLocked(model string) bool {
	return p.pendingLoadForModelLocked(model) < p.maxConcurrencyForModelLocked(model) &&
		p.pendingCount() < p.maxConcurrency()
}
