// Package registry manages the set of connected provider agents, their
// capabilities, and routes inference requests to appropriate providers.
//
// The registry is the coordinator's in-memory view of the provider fleet.
// It tracks each provider's hardware, available models, attestation status,
// trust level, and operational state (online/serving/offline/untrusted).
//
// Routing uses round-robin among idle providers that serve the requested
// model. Providers that fail too many attestation challenges are marked
// as untrusted and excluded from routing. Stale providers (no heartbeat
// within the timeout) are evicted by a background goroutine.
//
// Trust levels:
//   - none: Provider did not include an attestation blob
//   - self_signed: Provider's attestation was signed by its own SE key
//   - hardware: MDA certificate chain verified (future, requires Apple
//     Business Manager enrollment)
package registry

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log/slog"
	"math"
	"math/rand"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/saferun"
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

// PendingRequest is a channel-based handle for an in-flight inference request.
type PendingRequest struct {
	RequestID  string
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

	// Timing fields for latency decomposition. Written and read only by the
	// consumer/dispatch goroutine that owns the request — never shared. The
	// reputation latency sample is therefore recorded from that goroutine at
	// commit (see dispatch.writeCommittedResponse), never from the provider
	// read-loop goroutine that runs handleComplete.
	Timing *RequestTiming
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
	ReceivedAt   time.Time // handler entry
	ParsedAt     time.Time // after parse + validate
	ReservedAt   time.Time // after balance reservation
	RoutedAt     time.Time // after provider selection (including queue wait)
	EncryptedAt  time.Time // after E2E encryption
	QueuedAt     time.Time // set when request enters the queue
	DispatchedAt time.Time // set when request is sent to provider via WebSocket
	FirstChunkAt time.Time // set when first inference chunk (incl. held boilerplate) arrives from provider
	// FirstContentAt is set when the first CONTENT-bearing chunk is committed to
	// the client — i.e. excluding role-only / lifecycle boilerplate the dispatch
	// loop holds back. The reputation latency sample uses this so a provider that
	// emits a fast preamble then stalls can't earn an undeserved score;
	// FirstChunkAt remains the X-Timing provider-first-byte diagnostic.
	FirstContentAt time.Time
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

	// MDMFailureReason records the last MDM verification outcome for this
	// connection, bucketed for observability: "" (verified/none),
	// "device-not-found", "found-not-enrolled", "securityinfo-timeout",
	// "posture-mismatch", or "error". In-memory + per-connection — it explains
	// why a provider is (still) self_signed so the stuck-cohort gauge can
	// distinguish "never enrolled" from "enrolled but unresponsive".
	MDMFailureReason string

	Status           ProviderStatus
	Conn             *websocket.Conn
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

	// lastReputationPersisted tracks when this provider's reputation was last
	// written to the store from the heartbeat path. Used by
	// persistReputationThrottled so accumulated uptime survives restarts without
	// a DB write on every 30s heartbeat. Zero value persists on the first
	// heartbeat. (Challenge/job handlers persist reputation unthrottled.)
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

// GrantHardwareIfNotUntrusted atomically promotes the provider to hardware trust
// unless it is currently untrusted, returning whether it granted. The status
// check and the trust write happen under a SINGLE lock on purpose: a separate
// GetStatus() check followed by SetAttested(hardware) is a TOCTOU — a concurrent
// hard untrust from the challenge loop (binary-hash change / SIP disabled /
// signature failure) landing in the gap would leave the registry in
// hardware/untrusted and push a false "online" to the provider. Callers must only
// run the rest of the grant (sendTrustStatus / persist / MDA) when this returns
// true. Mirrors the SetMDAProofIfHardware single-lock pattern.
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

// GetTrustLevel returns the current trust level (thread-safe).
func (p *Provider) GetTrustLevel() TrustLevel {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.TrustLevel
}

// GetStatus returns the current provider status (thread-safe).
func (p *Provider) GetStatus() ProviderStatus {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.Status
}

// SetMDMFailureReason records the bucketed reason this connection's MDM
// verification has not (yet) granted hardware trust (thread-safe). Empty string
// clears it (verified / no failure).
func (p *Provider) SetMDMFailureReason(reason string) {
	p.mu.Lock()
	p.MDMFailureReason = reason
	p.mu.Unlock()
}

// GetMDMFailureReason returns the last bucketed MDM verification reason (thread-safe).
func (p *Provider) GetMDMFailureReason() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.MDMFailureReason
}

// SetMDAProofIfHardware atomically attaches a late-arriving Apple Device
// Attestation proof to the provider IFF it currently holds hardware trust and
// the MDA serial matches the attested serial. Returns true if attached.
//
// The trust check and the field writes happen under a single p.mu acquisition on
// purpose: doing them separately (read GetTrustLevel, then write the fields) is a
// TOCTOU — a concurrent SetAttested demotion between the check and the write
// would attach MDA proof to a now-self_signed connection, re-creating the
// "mda_verified while self_signed" drift. The single lock also closes the data
// race with handleProviderAttestation, which reads these fields under p.mu.
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

// Registry holds all connected providers and provides routing.
type Registry struct {
	mu        sync.RWMutex
	providers map[string]*Provider

	queue *RequestQueue

	MinTrustLevel TrustLevel

	// APNs code-identity rollout policy (v0.6.0), guarded by r.mu and evaluated
	// LIVE at every routing decision so a deadline can flip enforcement on/off
	// without forcing providers to reconnect.
	//
	//   - codeAttestationConfigured: true once an APNs attestor is wired
	//     (SetCodeAttestationConfigured). The coordinator only issues code-identity
	//     challenges when configured.
	//   - codeAttestationDeadline: the instant enforcement begins. Before it (or
	//     when zero) the coordinator is in GRACE/observe mode — it challenges and
	//     measures providers but still ROUTES un-attested ones, so configuring the
	//     attestor never deroutes the fleet. At/after the deadline, enforcement is
	//     fail-closed: un-attested providers (and any too-old to ever attest) stop
	//     being routed.
	//
	// Operator flow: set APNS_* secrets (configured, grace) → fleet updates to
	// 0.6.0 and attests → set APNS_ENFORCE_AFTER = release+24h → enforcement flips
	// on automatically when that instant passes.
	codeAttestationConfigured bool
	codeAttestationDeadline   time.Time

	modelCatalog map[string]CatalogEntry

	// modelAliases maps a public-facing alias id (e.g. "gemma-4-26b") to the
	// desired (and optional previous) concrete build it resolves to. Populated by
	// SetModelAliases at catalog sync time. nil = no aliases configured.
	modelAliases map[string]AliasTarget

	store store.Store

	tpsRegistry *TPSRegistry

	logger *slog.Logger

	onlineCount      atomic.Int64
	modelProviders   map[string]*atomic.Int64
	modelProvidersMu sync.Mutex

	// pendingModelLoads tracks provider-model pairs that have been sent a
	// load_model command and are awaiting completion, or are cooling down
	// after a failed one. The value is the entry's expiry time. While an
	// entry lives, the provider is skipped for new load_model sends
	// (bestModelLoadProviderLocked / reservePendingModelLoads).
	pendingModelLoads       map[string]time.Time // key: "providerID:modelID", value: expiry
	pendingModelLoadStarted map[string]time.Time

	// dispatchLoadCooldowns: provider-model pairs that rejected a dispatch with a
	// load failure ("insufficient memory"). Routing skips the pair until expiry —
	// it would instant-503 again, and without this the scheduler re-picks it
	// (looks idle), causing the dispatch→503→retry storms seen in prod. Cleared
	// on re-registration and on a served request for the pair.
	dispatchLoadCooldowns map[string]time.Time // key: "providerID:modelID", value: expiry

	// inferenceErrorStrikes / inferenceErrorCooldowns implement the error-class
	// circuit breaker for provider-side inference failures: a (provider, model,
	// shape) triple that returns repeated 5xx errors (e.g. the deterministic
	// Gemma chat-template render crash on tool schemas) enters a routing
	// cool-down so retries fall to OTHER providers instead of burning every
	// attempt on the same broken pair. 4xx (client-shape) errors never count.
	//
	// The key is SHAPE-KEYED (inferenceErrorKey) rather than a "providerID:modelID"
	// string concat. Shape-keying fixes the root bug where a clean non-tool
	// success reset the SHARED strike counter, so in mixed traffic a deterministic
	// tool/template failure interleaved with text successes never reached the
	// 2-strike threshold and the broken provider was never quarantined for tools.
	// Strikes now accumulate per shape ("tools" independent of "base"), a success
	// clears only its own shape bucket, and the struct key also closes the
	// threat-model colon-collision note (a provider or model id containing ':'
	// could previously alias another pair). Strikes slide over inferenceErrorWindow.
	// Guarded by r.mu like dispatchLoadCooldowns. See error_cooldown.go.
	inferenceErrorStrikes   map[inferenceErrorKey][]time.Time // recent 5xx strike times per (provider, model, shape)
	inferenceErrorCooldowns map[inferenceErrorKey]time.Time   // cool-down expiry per (provider, model, shape)

	// evictStrikes counts consecutive eviction sweeps a provider has been stale.
	// A provider is only evicted after STALE on two sweeps in a row, so a single
	// transient coordinator stall (which ages many LastHeartbeat values at once)
	// or one missed heartbeat doesn't mass-reap a live fleet. Guarded by r.mu;
	// rebuilt each sweep so disconnected providers drop out automatically.
	evictStrikes map[string]int

	cacheAffinity        *cacheAffinityTracker
	cacheAffinityBonusMs float64
	warmPool             *warmPoolController
	// loadModelSender is a test seam for SendLoadModel. Nil uses the provider WebSocket.
	loadModelSender func(providerID, modelID string) error
}

// pendingModelLoadTTL bounds how long an outstanding (or failed) load_model
// suppresses re-sends to the same provider.
const pendingModelLoadTTL = 2 * time.Minute

// pendingModelLoadDrainBackoff is the short cooldown used when a provider
// rejects load_model because it is draining for an auto-update restart. The
// entry keeps the planner away from a provider that is about to bounce, but
// must not outlive a failed restart: if the provider aborts the restart and
// resumes serving, it is fully loadable again, and the full 2-minute cooldown
// would strand queued requests that this provider (or its post-restart
// re-registration) could serve.
const pendingModelLoadDrainBackoff = 30 * time.Second

// dispatchLoadCooldownTTL is how long routing skips a pair after a dispatch
// load failure — long enough to stop the retry loop, short enough that a
// recovered provider returns on its own.
const dispatchLoadCooldownTTL = 2 * time.Minute

type modelLoadAction struct {
	providerID string
	modelID    string
}

// New creates a new Registry.
func New(logger *slog.Logger) *Registry {
	return &Registry{
		providers:               make(map[string]*Provider),
		queue:                   NewRequestQueue(10, 120*time.Second),
		MinTrustLevel:           TrustHardware,
		tpsRegistry:             NewTPSRegistry(),
		modelProviders:          make(map[string]*atomic.Int64),
		pendingModelLoads:       make(map[string]time.Time),
		pendingModelLoadStarted: make(map[string]time.Time),
		dispatchLoadCooldowns:   make(map[string]time.Time),
		inferenceErrorStrikes:   make(map[inferenceErrorKey][]time.Time),
		inferenceErrorCooldowns: make(map[inferenceErrorKey]time.Time),
		evictStrikes:            make(map[string]int),
		cacheAffinity:           newCacheAffinityTracker(cacheAffinityTTL),
		cacheAffinityBonusMs:    defaultCacheAffinityBonusMs,
		logger:                  logger,
	}
}

func (r *Registry) ConfigureCacheAffinity(cfg CacheAffinityConfig) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if cfg.TTL <= 0 {
		cfg.TTL = cacheAffinityTTL
	}
	r.cacheAffinity = newCacheAffinityTracker(cfg.TTL)
	r.cacheAffinityBonusMs = cfg.BonusMs
}

func (r *Registry) CacheAffinityConfigSnapshot() CacheAffinityConfig {
	r.mu.RLock()
	defer r.mu.RUnlock()
	ttl := cacheAffinityTTL
	if r.cacheAffinity != nil {
		ttl = r.cacheAffinity.ttl
	}
	return CacheAffinityConfig{TTL: ttl, BonusMs: r.cacheAffinityBonusMs}
}

// RecordDispatchLoadFailure puts a provider-model pair on a routing cool-down
// after the provider rejected a dispatch with a load failure. Returns true
// when this call started a new cool-down (false when one was already live),
// so callers can emit metrics without double-counting the retry storm.
func (r *Registry) RecordDispatchLoadFailure(providerID, modelID string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	now := time.Now()
	// Opportunistic sweep: provider ids are per-session UUIDs, so dead entries
	// never get re-keyed — bound the map by dropping expired ones when it grows.
	if len(r.dispatchLoadCooldowns) > 1024 {
		for key, expiry := range r.dispatchLoadCooldowns {
			if !now.Before(expiry) {
				delete(r.dispatchLoadCooldowns, key)
			}
		}
	}
	key := providerID + ":" + modelID
	_, active := r.dispatchLoadCooldowns[key]
	active = active && now.Before(r.dispatchLoadCooldowns[key])
	r.dispatchLoadCooldowns[key] = now.Add(dispatchLoadCooldownTTL)
	return !active
}

// ClearDispatchLoadCooldown removes the cool-down for one provider-model pair
// (called when the pair serves a request successfully — it can load after all).
func (r *Registry) ClearDispatchLoadCooldown(providerID, modelID string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.dispatchLoadCooldowns, providerID+":"+modelID)
}

// clearDispatchLoadCooldownsLocked drops a provider's cool-downs on
// (re-)registration — a fresh process has fresh memory. Caller holds r.mu.
func (r *Registry) clearDispatchLoadCooldownsLocked(providerID string) {
	prefix := providerID + ":"
	for key := range r.dispatchLoadCooldowns {
		if strings.HasPrefix(key, prefix) {
			delete(r.dispatchLoadCooldowns, key)
		}
	}
}

// dispatchLoadCooldownActiveLocked reports whether routing should skip the pair.
// READ-ONLY (no lazy delete) — some callers hold only r.mu.RLock. Caller holds
// r.mu in either mode.
func (r *Registry) dispatchLoadCooldownActiveLocked(providerID, modelID string, now time.Time) bool {
	expiry, ok := r.dispatchLoadCooldowns[providerID+":"+modelID]
	return ok && now.Before(expiry)
}

// SetStore configures the persistence store for the registry.
// When set, provider state and reputation are persisted to the store.
func (r *Registry) SetStore(st store.Store) {
	r.store = st
}

// LoadStoredProviders loads provider records and reputation from the store
// on startup. This pre-populates a lookup table so that reconnecting providers
// can have their trust level and reputation restored. Providers are NOT added
// to the active registry (they need to reconnect via WebSocket first).
func (r *Registry) LoadStoredProviders() map[string]*store.ProviderRecord {
	if r.store == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	records, err := r.store.ListProviderRecords(ctx)
	if err != nil {
		r.logger.Warn("failed to load stored providers", "error", err)
		return nil
	}

	lookup := make(map[string]*store.ProviderRecord, len(records))
	for i := range records {
		rec := records[i]
		// Index by serial number for matching reconnecting providers
		if rec.SerialNumber != "" {
			lookup[rec.SerialNumber] = &rec
		}
		// Also index by SE public key
		if rec.SEPublicKey != "" {
			lookup["sekey:"+rec.SEPublicKey] = &rec
		}
	}

	r.logger.Info("loaded stored provider records", "count", len(records))
	return lookup
}

// RestoreProviderState restores trust level and reputation from a stored record
// onto a live provider. Called after a provider reconnects and is matched to
// its stored state by serial number or SE key.
func (r *Registry) RestoreProviderState(p *Provider, rec *store.ProviderRecord) {
	if rec == nil {
		return
	}

	p.mu.Lock()
	defer p.mu.Unlock()

	// Restore trust level, but NEVER above self_signed. Hardware trust must be
	// re-earned via a fresh live challenge + MDM/ACME on every (re)connection.
	// Resurrecting a stored "hardware" level would route real traffic to a
	// provider that has not yet passed a live challenge, and is the source of
	// the "registry says hardware but the live verdict is self_signed" drift.
	// The challenge-success path (verifyChallengeResponse) re-upgrades to
	// hardware once the live legs pass.
	if r := trustRank(TrustLevel(rec.TrustLevel)); r > trustRank(TrustSelfSigned) {
		p.TrustLevel = TrustSelfSigned
	} else {
		p.TrustLevel = TrustLevel(rec.TrustLevel)
	}
	// Do NOT clobber a fresh live attestation: verifyProviderAttestation runs
	// just before this and may have already set Attested=true (self_signed) from
	// a passing SE attestation. Only fall back to the stored flag when we don't
	// already have a fresh one — otherwise consumers/stats would see
	// X-Provider-Attested:false despite a successful live attestation.
	if !p.Attested {
		p.Attested = rec.Attested
	}
	// Never resurrect MDA/ACME proofs from the store. Trust above self_signed was
	// just capped away (see above), so a restored connection is always
	// self_signed or lower — and a hardware proof is only meaningful for the
	// connection that earned it live. Restoring MDAVerified=true here produced the
	// misleading "mda_verified=true while self_signed" drift on
	// /v1/providers/attestation. These flags are re-set by the live MDM/ACME legs
	// (verifyAppleDeviceAttestation / applyACMETrust) once hardware is re-earned
	// this connection.
	p.MDAVerified = false
	p.ACMEVerified = false

	// Restore challenge state, but never move a fresh live verification
	// backwards. Registration attestation sets LastChallengeVerified=now before
	// RestoreProviderState runs; clobbering it with an old persisted timestamp
	// can make a just-reconnected provider fail the freshness gate until the
	// first challenge response lands.
	if rec.LastChallengeVerified != nil && rec.LastChallengeVerified.After(p.LastChallengeVerified) {
		p.LastChallengeVerified = *rec.LastChallengeVerified
	}
	p.FailedChallenges = rec.FailedChallenges

	// Restore location only if the provider doesn't already have a fresh one
	// (attachProviderLocation may have set it from the current request before
	// RestoreProviderState runs).
	if rec.Location != nil && p.Location == nil {
		cp := *rec.Location
		p.Location = &cp
	}

	// Restore account linkage
	if rec.AccountID != "" && p.AccountID == "" {
		p.AccountID = rec.AccountID
	}

	// Restore lifetime counters and the last raw session counters so future
	// heartbeats can merge cleanly after coordinator or provider restarts.
	p.Stats = protocol.HeartbeatStats{
		RequestsServed:  rec.LifetimeRequestsServed,
		TokensGenerated: rec.LifetimeTokensGenerated,
	}
	p.lastSessionStats = protocol.HeartbeatStats{
		RequestsServed:  rec.LastSessionRequestsServed,
		TokensGenerated: rec.LastSessionTokensGenerated,
	}

	// Restore reputation from store
	if r.store != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		repRec, err := r.store.GetReputation(ctx, rec.ID)
		if err == nil {
			p.Reputation.TotalJobs = repRec.TotalJobs
			p.Reputation.SuccessfulJobs = repRec.SuccessfulJobs
			p.Reputation.FailedJobs = repRec.FailedJobs
			p.Reputation.TotalUptime = time.Duration(repRec.TotalUptimeSeconds) * time.Second
			p.Reputation.AvgResponseTime = time.Duration(repRec.AvgResponseTimeMs) * time.Millisecond
			p.Reputation.ChallengesPassed = repRec.ChallengesPassed
			p.Reputation.ChallengesFailed = repRec.ChallengesFailed
		}
	}

	r.logger.Info("restored provider state from store",
		"provider_id", p.ID,
		"stored_id", rec.ID,
		"trust_level", rec.TrustLevel,
		"attested", rec.Attested,
		"serial", rec.SerialNumber,
	)
}

// PersistProvider unconditionally persists provider state to the store.
// Use for critical state changes (attestation, trust level, disconnect).
func (r *Registry) PersistProvider(p *Provider) {
	r.persistProviderNow(p)
}

// PersistProviderThrottled persists provider state at most once per 30 seconds.
// Use for high-frequency updates (heartbeats) that would otherwise saturate the
// DB connection pool. Skipped writes are not lost — the next unthrottled persist
// or the next throttle window will capture the current state.
func (r *Registry) PersistProviderThrottled(p *Provider) {
	const minInterval = 30 * time.Second
	p.mu.Lock()
	if time.Since(p.lastPersisted) < minInterval {
		p.mu.Unlock()
		return
	}
	p.lastPersisted = time.Now()
	p.mu.Unlock()
	r.persistProviderNow(p)
}

// persistReputationThrottled persists provider reputation at most once per 30
// seconds. Used by the heartbeat path so accumulated uptime is durable across
// coordinator restarts/reconnects (reputation is reloaded from the store on
// registration) without a DB write on every heartbeat. Skipped writes are not
// lost — the in-memory TotalUptime keeps accumulating and the next throttle
// window captures it.
func (r *Registry) persistReputationThrottled(p *Provider) {
	const minInterval = 30 * time.Second
	p.mu.Lock()
	if time.Since(p.lastReputationPersisted) < minInterval {
		p.mu.Unlock()
		return
	}
	p.lastReputationPersisted = time.Now()
	p.mu.Unlock()
	r.persistReputation(p)
}

// persistProviderNow saves a provider's current state to the store.
// Called asynchronously to avoid blocking the hot path.
func (r *Registry) persistProviderNow(p *Provider) {
	if r.store == nil {
		return
	}
	saferun.Go(r.logger, "registry.persistProvider", func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()

		p.mu.Lock()
		hardwareJSON, _ := json.Marshal(p.Hardware)
		modelsJSON, _ := json.Marshal(p.Models)
		var attestJSON json.RawMessage
		if p.AttestationResult != nil {
			attestJSON, _ = json.Marshal(p.AttestationResult)
		}
		seKey := ""
		serial := ""
		if p.AttestationResult != nil {
			seKey = p.AttestationResult.PublicKey
			serial = p.AttestationResult.SerialNumber
		}
		var mdaCertJSON json.RawMessage
		if len(p.MDACertChain) > 0 {
			mdaCertJSON, _ = json.Marshal(p.MDACertChain)
		}
		var lastChallenge *time.Time
		if !p.LastChallengeVerified.IsZero() {
			t := p.LastChallengeVerified
			lastChallenge = &t
		}

		var locationCopy *store.ProviderLocation
		if p.Location != nil {
			lc := *p.Location
			locationCopy = &lc
		}

		rec := store.ProviderRecord{
			ID:                         p.ID,
			Hardware:                   hardwareJSON,
			Models:                     modelsJSON,
			Backend:                    p.Backend,
			Location:                   locationCopy,
			TrustLevel:                 string(p.TrustLevel),
			Attested:                   p.Attested,
			AttestationResult:          attestJSON,
			SEPublicKey:                seKey,
			PublicKey:                  p.PublicKey,
			SerialNumber:               serial,
			MDAVerified:                p.MDAVerified,
			MDACertChain:               mdaCertJSON,
			ACMEVerified:               p.ACMEVerified,
			Version:                    p.Version,
			RuntimeVerified:            p.RuntimeVerified,
			PythonHash:                 p.PythonHash,
			RuntimeHash:                p.RuntimeHash,
			LastChallengeVerified:      lastChallenge,
			FailedChallenges:           p.FailedChallenges,
			AccountID:                  p.AccountID,
			LifetimeRequestsServed:     p.Stats.RequestsServed,
			LifetimeTokensGenerated:    p.Stats.TokensGenerated,
			LastSessionRequestsServed:  p.lastSessionStats.RequestsServed,
			LastSessionTokensGenerated: p.lastSessionStats.TokensGenerated,
			RegisteredAt:               time.Now(),
			LastSeen:                   time.Now(),
		}
		p.mu.Unlock()

		if err := r.store.UpsertProvider(ctx, rec); err != nil {
			r.logger.Warn("failed to persist provider", "provider_id", p.ID, "error", err)
		}

		// Keep this connection's session row fresh and backfill serial/account
		// once attestation/linking has populated them.
		if err := r.store.TouchProviderSession(ctx, rec.ID, rec.SerialNumber, rec.AccountID, rec.LastSeen); err != nil {
			r.logger.Warn("failed to touch provider session", "provider_id", rec.ID, "error", err)
		}
	})
}

// persistReputation saves a provider's current reputation to the store.
// Called asynchronously to avoid blocking the hot path.
func (r *Registry) persistReputation(p *Provider) {
	if r.store == nil {
		return
	}
	saferun.Go(r.logger, "registry.persistReputation", func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()

		p.mu.Lock()
		rep := store.ReputationRecord{
			TotalJobs:          p.Reputation.TotalJobs,
			SuccessfulJobs:     p.Reputation.SuccessfulJobs,
			FailedJobs:         p.Reputation.FailedJobs,
			TotalUptimeSeconds: int64(p.Reputation.TotalUptime / time.Second),
			AvgResponseTimeMs:  int64(p.Reputation.AvgResponseTime / time.Millisecond),
			ChallengesPassed:   p.Reputation.ChallengesPassed,
			ChallengesFailed:   p.Reputation.ChallengesFailed,
		}
		p.mu.Unlock()

		if err := r.store.UpsertReputation(ctx, p.ID, rep); err != nil {
			r.logger.Warn("failed to persist reputation", "provider_id", p.ID, "error", err)
		}
	})
}

// TruncHash returns the first 16 chars of a hash string for logging.
func TruncHash(h string) string {
	if len(h) > 16 {
		return h[:16] + "..."
	}
	return h
}

// CatalogEntry holds metadata about an active model in the catalog.
type CatalogEntry struct {
	ID         string
	WeightHash string  // expected SHA-256 weight fingerprint (empty = not enforced)
	SizeGB     float64 // disk/GPU footprint of the model weights (zero = unknown, gate disabled)
	// MinRAMGB is the catalog's authoritative minimum unified memory (GB) to run
	// this model — the operator-published requirement. The hardware-fit gate
	// prefers this over any heuristic multiple of SizeGB. Zero = unknown.
	MinRAMGB int
}

// SetModelCatalog updates the set of active models. Only models in this
// set will be accepted from providers during registration and routable to
// consumers. Pass nil to disable catalog filtering for tests/dev flows. Passing
// an empty non-nil slice configures a deny-all catalog, which is what a fresh
// DB-backed registry should do until an operator registers and promotes models.
func (r *Registry) SetModelCatalog(entries []CatalogEntry) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if entries == nil {
		r.modelCatalog = nil
		return
	}
	catalog := make(map[string]CatalogEntry, len(entries))
	for _, e := range entries {
		catalog[e.ID] = e
	}
	r.modelCatalog = catalog
}

// AliasTarget is the declarative resolution target for a public alias: a single
// Desired build the fleet converges to, with an optional still-acceptable
// Previous build during a staggered rollout. No weights, no ramp. Retired holds
// former members (rotated out by later upserts) — never routed, but used to
// recognize a returning provider that was offline through a retirement as part
// of this alias's fleet so it still receives desired_models.
type AliasTarget struct {
	Desired  string
	Previous string
	Retired  []string
}

// SetModelAliases installs the public-alias → {desired, previous} mapping. Pass
// nil (or an empty map) to clear all aliases. Callers pass only ACTIVE aliases
// (the store/sync layer filters inactive ones out). An alias whose Desired is
// empty contributes nothing routable.
func (r *Registry) SetModelAliases(aliases map[string]AliasTarget) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(aliases) == 0 {
		r.modelAliases = nil
		return
	}
	m := make(map[string]AliasTarget, len(aliases))
	for alias, t := range aliases {
		m[alias] = t
	}
	r.modelAliases = m
}

// PublicNameForBuild returns the public alias a concrete build is exposed under
// (the consumer-facing name), or the build id unchanged if it isn't the desired
// or previous build of any alias. This lets consumer-facing surfaces (e.g. usage
// history) show the alias while billing/stats/earnings keep storing the concrete
// build. If several aliases map to the build, the lexicographically-first is
// returned for stability.
func (r *Registry) PublicNameForBuild(buildID string) string {
	if buildID == "" {
		return buildID
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	best := ""
	for alias, t := range r.modelAliases {
		if t.Desired == buildID || t.Previous == buildID {
			if best == "" || alias < best {
				best = alias
			}
		}
	}
	if best == "" {
		return buildID
	}
	return best
}

// IsAlias reports whether requested is a configured public alias.
func (r *Registry) IsAlias(requested string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	_, ok := r.modelAliases[requested]
	return ok
}

// AliasTarget returns the configured desired/previous build pointers for alias.
func (r *Registry) AliasTarget(alias string) (AliasTarget, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	t, ok := r.modelAliases[alias]
	return t, ok
}

// ResolveModel maps a requested model id to a concrete build id for routing.
//
//   - If requested is NOT an alias, it is returned unchanged (isAlias=false,
//     ok=true) — raw build ids keep working for backward compatibility.
//   - If requested IS an alias, it resolves to the Desired build when at least
//     one provider can route it; otherwise to the Previous build when that is
//     routable; otherwise it returns Desired so the request queues against a
//     real build instead of black-holing. ok=false only when Desired is empty.
func (r *Registry) ResolveModel(requested string) (buildID string, isAlias bool, ok bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()

	t, found := r.modelAliases[requested]
	if !found {
		return requested, false, true
	}
	if t.Desired == "" {
		return "", true, false
	}
	if r.anyProviderCanRouteBuildLocked(t.Desired) {
		return t.Desired, true, true
	}
	if t.Previous != "" && r.anyProviderCanRouteBuildLocked(t.Previous) {
		return t.Previous, true, true
	}
	// Neither build is routable yet — resolve to Desired so the request queues
	// against a real build instead of failing outright.
	return t.Desired, true, true
}

// ResolveModelConstrained is ResolveModel, but when a request is restricted to
// specific providers — a serial allowlist or self-route to the owner's own
// machines — it only treats a build as servable if an ELIGIBLE provider (one
// that both matches the constraint and can route the build) can serve it. This
// stops an alias from resolving to a build that's routable somewhere globally
// but absent from the request's allowed provider set (which would then fail at
// dispatch). With no constraints it is identical to ResolveModel.
func (r *Registry) ResolveModelConstrained(requested string, allowedSerials []string, ownerAccountID string, selfRouteOnly, preferOwner bool) (buildID string, isAlias bool, ok bool) {
	if len(allowedSerials) == 0 && !selfRouteOnly && !preferOwner {
		return r.ResolveModel(requested)
	}
	r.mu.RLock()
	defer r.mu.RUnlock()

	t, found := r.modelAliases[requested]
	if !found {
		return requested, false, true
	}
	if t.Desired == "" {
		return "", true, false
	}
	allowed := make(map[string]struct{}, len(allowedSerials))
	for _, s := range allowedSerials {
		if s != "" {
			allowed[s] = struct{}{}
		}
	}
	now := time.Now()
	hardConstrained := len(allowed) > 0 || selfRouteOnly
	if preferOwner && ownerAccountID != "" {
		if r.anyEligibleProviderCanRouteLocked(t.Desired, nil, ownerAccountID, true, true, now) {
			return t.Desired, true, true
		}
		if t.Previous != "" && r.anyEligibleProviderCanRouteLocked(t.Previous, nil, ownerAccountID, true, true, now) {
			return t.Previous, true, true
		}
	}
	if !hardConstrained {
		if r.anyProviderCanRouteBuildLocked(t.Desired) {
			return t.Desired, true, true
		}
		if t.Previous != "" && r.anyProviderCanRouteBuildLocked(t.Previous) {
			return t.Previous, true, true
		}
		return t.Desired, true, true
	}
	if t.Desired != "" && r.anyEligibleProviderCanRouteLocked(t.Desired, allowed, ownerAccountID, selfRouteOnly, preferOwner, now) {
		return t.Desired, true, true
	}
	if t.Previous != "" && r.anyEligibleProviderCanRouteLocked(t.Previous, allowed, ownerAccountID, selfRouteOnly, preferOwner, now) {
		return t.Previous, true, true
	}
	// Only HARD-constrained requests (serial pin / self-route-only) reach here —
	// the unconstrained path returned ResolveModel above. So if no allowed+
	// eligible provider can serve either build, do NOT fall back to Desired: that
	// would resolve to a build the allowed providers can't serve (the exact thing
	// this function exists to prevent) and then queue/fail against the wrong
	// build, or for self-route leak toward the fleet. Return unavailable.
	return "", true, false
}

// anyEligibleProviderCanRouteLocked reports whether some provider both matches
// the request's constraint (serial allowlist and/or self-route ownership) and
// can route the build. Self-route to an OWNED machine relaxes trust and allows
// private-only providers, mirroring snapshotProviderLocked. Caller holds r.mu.
func (r *Registry) anyEligibleProviderCanRouteLocked(buildID string, allowedSerials map[string]struct{}, ownerAccountID string, selfRouteOnly, preferOwner bool, now time.Time) bool {
	for _, p := range r.providers {
		p.mu.Lock()
		ok := func() bool {
			if len(allowedSerials) > 0 {
				// A provider with no attestation result can't be serial-matched
				// (and dereferencing it would panic) — treat as not eligible.
				serial := ""
				if p.AttestationResult != nil {
					serial = p.AttestationResult.SerialNumber
				}
				if _, in := allowedSerials[serial]; !in || serial == "" {
					return false
				}
			}
			owned := p.AccountID != "" && p.AccountID == ownerAccountID
			if selfRouteOnly && !owned {
				return false
			}
			minTrust := r.MinTrustLevel
			allowPrivate := false
			if owned && (selfRouteOnly || preferOwner) {
				minTrust = TrustNone
				allowPrivate = true
			}
			return r.providerCanRouteBuildLocked(p, buildID, minTrust, now, allowPrivate)
		}()
		p.mu.Unlock()
		if ok {
			return true
		}
	}
	return false
}

// providerCanRouteBuildLocked is the single source of truth for "could this
// provider actually serve this build right now" — the same gates
// snapshotProviderLocked applies (advertises the build + in catalog, not
// offline/untrusted, public, trust ≥ floor, runtime verified, private-text
// capable, fresh challenge, AND the model fits the provider's RAM), minus the
// per-request capacity/headroom checks. Cold-but-healthy providers pass (no warm
// slot required — they load on first demand). Caller holds r.mu (RLock) and p.mu.
func (r *Registry) providerCanRouteBuildLocked(p *Provider, buildID string, minTrust TrustLevel, now time.Time, allowPrivate bool) bool {
	if !r.providerServesCatalogModelLocked(p, buildID) {
		return false
	}
	if r.dispatchLoadCooldownActiveLocked(p.ID, buildID, now) {
		return false
	}
	if p.Status == StatusOffline || p.Status == StatusUntrusted {
		return false
	}
	if p.PrivateOnly && !allowPrivate {
		return false
	}
	if trustRank(p.TrustLevel) < trustRank(minTrust) {
		return false
	}
	if !p.RuntimeVerified || !r.providerSupportsPrivateTextLocked(p) {
		return false
	}
	if p.LastChallengeVerified.IsZero() || now.Sub(p.LastChallengeVerified) > challengeFreshnessMaxAge {
		return false
	}
	if p.BackendCapacity != nil {
		for _, slot := range p.BackendCapacity.Slots {
			if slot.Model != buildID {
				continue
			}
			if _, eligible := slotStatePenalty(slot.State); !eligible {
				return false
			}
			break
		}
	}
	// Hardware fit: don't count a provider whose RAM can't hold the build (e.g.
	// migrating to a larger build than the source). totalMemory prefers the
	// backend-reported figure, matching snapshotProviderLocked.
	totalMemoryGB := float64(p.Hardware.MemoryGB)
	if p.BackendCapacity != nil && p.BackendCapacity.TotalMemoryGB > 0 {
		totalMemoryGB = p.BackendCapacity.TotalMemoryGB
	}
	return modelFitsHardware(r.catalogMinRAMGbLocked(buildID), r.catalogSizeGBLocked(buildID), totalMemoryGB)
}

// anyProviderCanRouteBuildLocked reports whether at least one provider could
// route the build right now. Caller holds r.mu.
func (r *Registry) anyProviderCanRouteBuildLocked(buildID string) bool {
	now := time.Now()
	minTrust := r.MinTrustLevel
	for _, p := range r.providers {
		p.mu.Lock()
		ok := r.providerCanRouteBuildLocked(p, buildID, minTrust, now, false)
		p.mu.Unlock()
		if ok {
			return true
		}
	}
	return false
}

// MergeProviderModels applies a provider's authoritative models_update to its
// advertised Models in place — used for the message a provider sends after it
// converges on a desired build (background prefetch verified, then hard-swap),
// so a new build becomes routable WITHOUT a reconnect and WITHOUT resetting
// trust/reputation/challenge state. It is authoritative for each alias whose
// desired build appears in the validated update: that alias's previous build is
// dropped if omitted. Seeing a build only as another alias's previous build is
// not enough to drop that other alias's desired build, which keeps aliases that
// share a concrete build independent.
//
// Each model's WeightHash is cross-checked against the catalog's expected hash;
// a mismatch is REJECTED (the build is not made routable) so a bad or buggy
// prefetch/swap can never take traffic. Returns build ids that were merged and
// build ids that were dropped from this provider.
func (r *Registry) MergeProviderModels(providerID string, models []protocol.ModelInfo) (merged, dropped []string) {
	if len(models) == 0 {
		return nil, nil
	}
	r.mu.RLock()
	p, ok := r.providers[providerID]
	// hasCatalog mirrors modelAllowedByCatalogLocked: a nil catalog (dev/test
	// setups) imposes no membership gate; a present catalog makes membership
	// mandatory for merging.
	hasCatalog := r.modelCatalog != nil
	expected := make(map[string]string, len(models))
	for _, m := range models {
		if e, has := r.modelCatalog[m.ID]; has {
			expected[m.ID] = e.WeightHash
		}
	}
	// Snapshot the alias targets under the read lock so the drop set can be
	// computed later (under p.mu) without nesting r.mu — and, crucially, from
	// the builds that actually PASS validation below, not from the raw message.
	aliasTargets := make([]AliasTarget, 0, len(r.modelAliases))
	for _, t := range r.modelAliases {
		aliasTargets = append(aliasTargets, t)
	}
	r.mu.RUnlock()
	if !ok {
		return nil, nil
	}

	p.mu.Lock()
	defer p.mu.Unlock()
	// present tracks only builds that passed validation and were merged — the
	// hard-swap drop is derived from THIS set, never from the raw message. A
	// desired build rejected for a bad weight hash therefore does NOT cause its
	// previous sibling to be dropped (which would strand the provider on neither
	// build — the exact failure the hash check exists to prevent).
	present := make(map[string]struct{}, len(models))
	for _, m := range models {
		if m.ID == "" {
			continue
		}
		// A build the catalog has never heard of is rejected outright (when a
		// catalog exists). It could never be routed anyway
		// (modelAllowedByCatalogLocked), and merging it would let a provider
		// grow its own p.Models without bound via repeated models_update
		// messages carrying fabricated ids.
		if _, inCatalog := expected[m.ID]; hasCatalog && !inCatalog {
			r.logger.Warn("models_update for build not in catalog; rejecting",
				"provider_id", providerID, "model_id", m.ID)
			continue
		}
		// When the catalog pins an expected hash, a models_update MUST carry a
		// non-empty MATCHING hash. A missing hash is rejected just like a
		// mismatched one — otherwise a buggy/malicious update that omits
		// weight_hash (or a nil WeightHasher.computeHash on the provider) would be
		// merged as "validated" and could cut the provider over to an unverified
		// desired build while dropping the last known-good previous sibling.
		if exp := expected[m.ID]; exp != "" && !strings.EqualFold(m.WeightHash, exp) {
			r.logger.Warn("models_update weight-hash missing or mismatched; rejecting build",
				"provider_id", providerID, "model_id", m.ID, "expected", exp, "got", m.WeightHash)
			continue
		}
		replaced := false
		for i := range p.Models {
			if p.Models[i].ID == m.ID {
				p.Models[i] = m
				replaced = true
				break
			}
		}
		if !replaced {
			p.Models = append(p.Models, m)
		}
		merged = append(merged, m.ID)
		present[m.ID] = struct{}{}
	}
	// Compute the hard-swap drop set: a VALIDATED desired build authorizes
	// dropping only that alias's previous build. This is intentionally
	// directional; if two aliases share a build, updating one alias to that shared
	// desired build must not drop the desired build of another alias where the
	// shared build is merely "previous".
	drop := make(map[string]struct{})
	for _, t := range aliasTargets {
		if t.Desired == "" || t.Previous == "" || t.Desired == t.Previous {
			continue
		}
		if _, desiredPresent := present[t.Desired]; !desiredPresent {
			continue
		}
		if _, previousStillPresent := present[t.Previous]; !previousStillPresent {
			drop[t.Previous] = struct{}{}
		}
	}
	// Apply the hard-swap drop: remove any alias-sibling build the provider no
	// longer advertises.
	if len(drop) > 0 {
		kept := p.Models[:0]
		for _, m := range p.Models {
			if _, gone := drop[m.ID]; gone {
				r.logger.Info("models_update hard-swap: dropping retired build",
					"provider_id", providerID, "model_id", m.ID)
				dropped = append(dropped, m.ID)
				continue
			}
			kept = append(kept, m)
		}
		p.Models = kept
	}
	return merged, dropped
}

// RoutableProviderIDsForBuild returns the ids of providers that would actually
// pass the routing gate for the build right now — the SAME checks
// snapshotProviderLocked applies (advertises the build, not offline/untrusted,
// public, trust ≥ floor, runtime verified, private-text capable, fresh
// challenge), minus per-request capacity/headroom. Cold-but-healthy providers
// count (no warm slot required — they load on first demand). Used to measure how
// much of the fleet can truly serve a build (e.g. rollout progress / hard-swap
// drop verification in tests) without counting capacity it can't actually route.
func (r *Registry) RoutableProviderIDsForBuild(buildID string) []string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	now := time.Now()
	minTrust := r.MinTrustLevel
	var ids []string
	for id, p := range r.providers {
		p.mu.Lock()
		ok := r.providerCanRouteBuildLocked(p, buildID, minTrust, now, false)
		p.mu.Unlock()
		if ok {
			ids = append(ids, id)
		}
	}
	return ids
}

// ModelType returns the model type string for the given model ID, or
// "unknown" if no provider is currently serving it.
func (r *Registry) ModelType(model string) string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, p := range r.providers {
		p.mu.Lock()
		for _, m := range p.Models {
			if m.ID == model && m.ModelType != "" {
				p.mu.Unlock()
				return m.ModelType
			}
		}
		p.mu.Unlock()
	}
	return "unknown"
}

// IsModelInCatalog returns true if the model is in the active catalog, or if
// catalog filtering has been explicitly disabled by setting a nil catalog.
func (r *Registry) IsModelInCatalog(model string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if r.modelCatalog == nil {
		return true
	}
	_, ok := r.modelCatalog[model]
	return ok
}

// UpdateModelWeightHashes refreshes the stored per-model weight hashes for a
// provider from a verified attestation challenge response. Providers recompute
// weight hashes when a model is (re)loaded from disk — e.g. after a model was
// re-published and re-downloaded while the daemon kept running. Without this,
// the registry would keep the registration-time snapshot and the per-model
// catalog filter (modelAllowedByCatalogLocked) would silently stop routing the
// model to this provider until its next reconnect.
//
// Concurrency: the p.Models slice header is replaced (copy-on-write, never
// mutated in place) under p.mu — NOT under the registry-wide r.mu, which is held
// only as a read lock to look the provider up in the map. p.mu is therefore the
// sole lock guarding p.Models, so every reader that ranges p.Models must hold
// p.mu (see providerModelIDs and the *Locked helpers). Do not rely on r.mu to
// serialize reads against this write: it does not.
func (r *Registry) UpdateModelWeightHashes(providerID string, hashes map[string]string) {
	if len(hashes) == 0 {
		return
	}
	r.mu.RLock()
	p, ok := r.providers[providerID]
	r.mu.RUnlock()
	if !ok {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	changed := false
	models := make([]protocol.ModelInfo, len(p.Models))
	copy(models, p.Models)
	for i := range models {
		if h, ok := hashes[models[i].ID]; ok && h != "" && models[i].WeightHash != h {
			models[i].WeightHash = h
			changed = true
		}
	}
	if changed {
		p.Models = models
	}
}

// CatalogWeightHash returns the expected weight hash for a model, or empty
// string if not set or not in catalog.
func (r *Registry) CatalogWeightHash(model string) string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if e, ok := r.modelCatalog[model]; ok {
		return e.WeightHash
	}
	return ""
}

// IsAliasLineageBuild reports whether buildID is a PREVIOUS or RETIRED member of
// any active alias — i.e. an old build that a hot-swap migration legitimately
// leaves GPU-resident on providers after it drops from the advertised set. Used
// to scope the attestation active-hash alibi to exactly that migration case, so
// a provider can't use the alibi to claim an arbitrary unrelated catalog model
// as active. (Desired members are still advertised, so they never need it.)
func (r *Registry) IsAliasLineageBuild(buildID string) bool {
	if buildID == "" {
		return false
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, t := range r.modelAliases {
		if t.Previous == buildID {
			return true
		}
		for _, retired := range t.Retired {
			if retired == buildID {
				return true
			}
		}
	}
	return false
}

// modelAllowedByCatalogLocked returns whether a provider-reported model is
// allowed by the current catalog. Caller must hold r.mu (read or write). A nil
// catalog disables filtering; an empty non-nil catalog denies all models.
func (r *Registry) modelAllowedByCatalogLocked(model protocol.ModelInfo) bool {
	if r.modelCatalog == nil {
		return true
	}
	entry, ok := r.modelCatalog[model.ID]
	if !ok {
		return false
	}
	return entry.WeightHash == "" || model.WeightHash == "" || model.WeightHash == entry.WeightHash
}

// providerServesCatalogModelLocked returns true if the provider advertises the
// model and that model is currently allowed by the catalog. Caller must hold
// r.mu and p.mu.
func (r *Registry) providerServesCatalogModelLocked(p *Provider, model string) bool {
	for _, m := range p.Models {
		if m.ID == model && r.modelAllowedByCatalogLocked(m) {
			return true
		}
	}
	return false
}

// providerServesVisionModelLocked reports whether the provider advertises the
// model as a vision-capable (VLM) build — required to route image/video requests
// so the media is actually perceived rather than silently dropped. Caller must
// hold r.mu AND p.mu (mirrors providerServesCatalogModelLocked): p.Models is
// guarded by p.mu and mutated by MergeProviderModels/UpdateModelWeightHashes.
// Pre-0.6.0 providers never set IsVision, so they are correctly excluded.
func (r *Registry) providerServesVisionModelLocked(p *Provider, model string) bool {
	for _, m := range p.Models {
		if m.ID == model && m.IsVision && r.modelAllowedByCatalogLocked(m) {
			return true
		}
	}
	return false
}

// HasVisionProviderForModel reports whether any online, non-untrusted provider
// advertises a vision-capable build for the resolved model id. The consumer uses
// it to fail a media request fast with a clear error when the fleet has no
// VLM-capable provider for the model (e.g. before the gemma fleet finishes
// updating to 0.6.0), instead of queueing the request to a timeout.
//
// When allowedSerials is non-empty the check is restricted to providers whose
// attested serial is in the set, exactly as the routing path constrains the
// candidate pool. Without this filter a constrained media request would be
// falsely reported as serviceable by an unrelated public provider (the same
// latent gap as HasToolCapableProviderForModel).
func (r *Registry) HasVisionProviderForModel(model string, allowedSerials ...string) bool {
	allowedSet := make(map[string]struct{}, len(allowedSerials))
	for _, s := range allowedSerials {
		allowedSet[s] = struct{}{}
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, p := range r.providers {
		// Allowed-serial filter first (providerMatchesAllowedSerial takes p.mu
		// internally), mirroring the routing candidate filter and QuickCapacityCheck.
		if len(allowedSet) > 0 && !providerMatchesAllowedSerial(p, allowedSet) {
			continue
		}
		// p.Status and p.Models are guarded by p.mu (writers hold it), so the
		// whole eligibility read must happen under the provider lock.
		p.mu.Lock()
		eligible := p.Status != StatusOffline && p.Status != StatusUntrusted &&
			r.providerServesVisionModelLocked(p, model)
		p.mu.Unlock()
		if eligible {
			return true
		}
	}
	return false
}

// catalogSizeGBLocked returns the model's reported weight footprint in GB,
// or 0 when unknown. Caller must hold r.mu (read or write). Zero means the
// memory-admission gate should not enforce for this model — typically a
// catalog entry that pre-dates the SizeGB field, or a model the operator
// hasn't sized yet.
func (r *Registry) catalogSizeGBLocked(model string) float64 {
	if e, ok := r.modelCatalog[model]; ok {
		return e.SizeGB
	}
	return 0
}

// catalogMinRAMGbLocked returns the model's authoritative minimum-RAM
// requirement (GB) from the catalog, or 0 when unknown. Caller must hold r.mu.
func (r *Registry) catalogMinRAMGbLocked(model string) int {
	if e, ok := r.modelCatalog[model]; ok {
		return e.MinRAMGB
	}
	return 0
}

// trustMeetsMinimum returns true if the given trust level meets the minimum.
func (r *Registry) trustMeetsMinimum(level TrustLevel) bool {
	return trustRank(level) >= trustRank(r.MinTrustLevel)
}

// Queue returns the registry's request queue.
func (r *Registry) Queue() *RequestQueue {
	return r.queue
}

// SetQueue replaces the registry's request queue. This is useful for tests
// that need a larger queue capacity than the default.
func (r *Registry) SetQueue(q *RequestQueue) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.queue = q
}

// Sanity caps on provider-reported stats. A malicious (or broken) provider
// could otherwise report absurd values to monopolize routing. These caps are
// ~3-4x current hardware ceilings (M2 Ultra is ~800 GB/s, MLX decode is ~120
// tok/s, max Mac Studio RAM is 512 GB) so legitimate future hardware isn't
// clamped unnecessarily.
const (
	maxDecodeTPS                    = 500.0
	maxPrefillTPS                   = 5000.0
	maxMemoryBandwidthGBs           = 2000.0
	maxMemoryGB                     = 1024
	maxMemoryGBFloat                = 1024.0
	maxReportedMaxConcurrency       = 24
	maxTokensPotential              = 1_000_000
	maxTokenBudgetCap         int64 = 10_000_000_000 // 10 billion — generous safety valve for total token budget capacity
)

// clampNonNeg returns v clamped into [0, max]; NaN/negative become 0.
// The bool is true if the value was out of range.
func clampNonNeg(v, max float64) (float64, bool) {
	if math.IsNaN(v) || v < 0 {
		return 0, true
	}
	if v > max {
		return max, true
	}
	return v, false
}

// clampBackendCapacity applies sanity caps to provider-reported backend
// capacity fields that feed the routing scorer. A provider reporting
// TotalMemoryGB=1e9 would make gpuUtil ~= 0 and dodge health penalties, so
// we cap it at maxMemoryGBFloat. Same for MaxTokensPotential which directly
// controls backlog cost. NaN/negative become 0.
func clampBackendCapacity(logger *slog.Logger, providerID string, bc *protocol.BackendCapacity) {
	if bc == nil {
		return
	}
	if v, changed := clampNonNeg(bc.TotalMemoryGB, maxMemoryGBFloat); changed {
		logger.Warn("provider total_memory_gb out of range, clamping",
			"provider_id", providerID, "reported", bc.TotalMemoryGB, "clamped", v)
		bc.TotalMemoryGB = v
	}
	if v, changed := clampNonNeg(bc.GPUMemoryActiveGB, maxMemoryGBFloat); changed {
		logger.Warn("provider gpu_memory_active_gb out of range, clamping",
			"provider_id", providerID, "reported", bc.GPUMemoryActiveGB, "clamped", v)
		bc.GPUMemoryActiveGB = v
	}
	if v, changed := clampNonNeg(bc.GPUMemoryPeakGB, maxMemoryGBFloat); changed {
		bc.GPUMemoryPeakGB = v
	}
	if v, changed := clampNonNeg(bc.GPUMemoryCacheGB, maxMemoryGBFloat); changed {
		bc.GPUMemoryCacheGB = v
	}
	for i := range bc.Slots {
		s := &bc.Slots[i]
		if s.MaxTokensPotential < 0 || s.MaxTokensPotential > maxTokensPotential {
			logger.Warn("provider slot max_tokens_potential out of range, clamping",
				"provider_id", providerID, "model", s.Model, "reported", s.MaxTokensPotential)
			if s.MaxTokensPotential < 0 {
				s.MaxTokensPotential = 0
			} else {
				s.MaxTokensPotential = maxTokensPotential
			}
		}
		if s.NumRunning < 0 {
			s.NumRunning = 0
		}
		if s.NumWaiting < 0 {
			s.NumWaiting = 0
		}
		if s.MaxConcurrency < 0 || s.MaxConcurrency > maxReportedMaxConcurrency {
			logger.Warn("provider slot max_concurrency out of range, clamping",
				"provider_id", providerID, "model", s.Model, "reported", s.MaxConcurrency)
			if s.MaxConcurrency < 0 {
				s.MaxConcurrency = 0
			} else {
				s.MaxConcurrency = maxReportedMaxConcurrency
			}
		}
		if v, changed := clampNonNeg(s.ObservedDecodeTPS, maxDecodeTPS); changed {
			logger.Warn("provider slot observed_decode_tps out of range, clamping",
				"provider_id", providerID, "model", s.Model, "reported", s.ObservedDecodeTPS, "clamped", v)
			s.ObservedDecodeTPS = v
		}
		if s.ActiveTokenBudgetUsed < 0 || s.ActiveTokenBudgetUsed > maxTokenBudgetCap {
			if s.ActiveTokenBudgetUsed < 0 {
				s.ActiveTokenBudgetUsed = 0
			} else {
				s.ActiveTokenBudgetUsed = maxTokenBudgetCap
			}
		}
		if s.ActiveTokenBudgetMax < 0 || s.ActiveTokenBudgetMax > maxTokenBudgetCap {
			if s.ActiveTokenBudgetMax < 0 {
				s.ActiveTokenBudgetMax = 0
			} else {
				s.ActiveTokenBudgetMax = maxTokenBudgetCap
			}
		}
		if s.QueuedTokenBudget < 0 || s.QueuedTokenBudget > maxTokenBudgetCap {
			if s.QueuedTokenBudget < 0 {
				s.QueuedTokenBudget = 0
			} else {
				s.QueuedTokenBudget = maxTokenBudgetCap
			}
		}
	}
}

// Register adds a new provider to the registry, returning its assigned ID.
// Provider-reported model inventory is preserved even when the current catalog
// denies every model; catalog checks are applied dynamically during routing so
// providers that connect before a model is promoted become routable immediately
// after the catalog is updated.
func (r *Registry) Register(id string, conn *websocket.Conn, msg *protocol.RegisterMessage) *Provider {
	// Clamp provider-reported performance stats used in routing score.
	// Refuse to trust unbounded values — a malicious provider reporting
	// DecodeTPS=1e9 would otherwise starve all other providers.
	if v, changed := clampNonNeg(msg.DecodeTPS, maxDecodeTPS); changed {
		r.logger.Warn("provider decode_tps out of range, clamping",
			"provider_id", id, "reported", msg.DecodeTPS, "clamped", v)
		msg.DecodeTPS = v
	}
	if v, changed := clampNonNeg(msg.PrefillTPS, maxPrefillTPS); changed {
		r.logger.Warn("provider prefill_tps out of range, clamping",
			"provider_id", id, "reported", msg.PrefillTPS, "clamped", v)
		msg.PrefillTPS = v
	}
	if v, changed := clampNonNeg(msg.Hardware.MemoryBandwidthGBs, maxMemoryBandwidthGBs); changed {
		r.logger.Warn("provider memory_bandwidth_gbs out of range, clamping",
			"provider_id", id, "reported", msg.Hardware.MemoryBandwidthGBs, "clamped", v)
		msg.Hardware.MemoryBandwidthGBs = v
	}
	if msg.Hardware.MemoryGB < 0 || msg.Hardware.MemoryGB > maxMemoryGB {
		r.logger.Warn("provider memory_gb out of range, clamping",
			"provider_id", id, "reported", msg.Hardware.MemoryGB)
		if msg.Hardware.MemoryGB < 0 {
			msg.Hardware.MemoryGB = 0
		} else {
			msg.Hardware.MemoryGB = maxMemoryGB
		}
	}

	models := msg.Models

	// Validate X25519 public key if provided.
	// Reject invalid keys at registration rather than failing at encryption time.
	pubKey := msg.PublicKey
	if pubKey != "" {
		decoded, err := base64.StdEncoding.DecodeString(pubKey)
		if err != nil || len(decoded) != 32 {
			r.logger.Warn("provider public key invalid, clearing",
				"provider_id", id,
				"error", "must be 32-byte base64-encoded X25519 key",
			)
			pubKey = "" // clear so provider can register but won't receive encrypted requests
		}
	}

	p := &Provider{
		ID:                      id,
		Hardware:                msg.Hardware,
		Models:                  models,
		Backend:                 msg.Backend,
		PublicKey:               pubKey,
		EncryptedResponseChunks: msg.EncryptedResponseChunks,
		PrivateOnly:             msg.PrivateOnly,
		APNsDeviceToken:         msg.APNsDeviceToken,
		APNsEnvironment:         msg.APNsEnvironment,
		PrefillTPS:              msg.PrefillTPS,
		DecodeTPS:               msg.DecodeTPS,
		TrustLevel:              TrustNone,
		RuntimeVerified:         true,  // default to verified; API layer sets false when manifest check fails
		RuntimeManifestChecked:  true,  // default to true; API layer sets false when no manifest is configured
		ChallengeVerifiedSIP:    false, // starts false; set true by attestation challenge handler after SIP check
		PrivacyCapabilities:     msg.PrivacyCapabilities,
		TemplateHashes:          CloneStringMap(msg.TemplateHashes),
		Status:                  StatusOnline,
		Conn:                    conn,
		LastHeartbeat:           time.Now(),
		Reputation:              NewReputation(),
		pendingReqs:             make(map[string]*PendingRequest),
	}

	r.mu.Lock()
	r.providers[id] = p
	r.onlineCount.Add(1)
	for _, m := range models {
		r.modelProviderInc(m.ID)
	}
	// A (re-)registration means a fresh provider process: any dispatch-time
	// load-failure cool-downs belonged to the previous process's memory state.
	r.clearDispatchLoadCooldownsLocked(id)
	r.mu.Unlock()

	// Open a session row for this connection (async; durable uptime history).
	// serial/account are empty here (set after attestation/linking) and are
	// backfilled by the throttled TouchProviderSession in persistProviderNow.
	if r.store != nil {
		sessionID := p.ID
		saferun.Go(r.logger, "registry.openSession", func() {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if err := r.store.OpenProviderSession(ctx, sessionID, "", ""); err != nil {
				r.logger.Warn("failed to open provider session", "provider_id", sessionID, "error", err)
			}
		})
	}

	r.logger.Info("provider registered",
		"provider_id", id,
		"chip", msg.Hardware.ChipName,
		"memory_gb", msg.Hardware.MemoryGB,
		"models", len(msg.Models),
		"backend", msg.Backend,
		"prefill_tps", msg.PrefillTPS,
		"decode_tps", msg.DecodeTPS,
	)

	// Persist provider record to store (async).
	r.persistProviderNow(p)

	return p
}

func CloneStringMap(in map[string]string) map[string]string {
	if len(in) == 0 {
		return nil
	}
	out := make(map[string]string, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}

// DisconnectDuplicatesBySerial disconnects all providers that share the same
// serial number as the given provider, except the given provider itself.
// This prevents multiple WebSocket connections from the same physical machine
// from competing for the same vllm-mlx backend on localhost.
func (r *Registry) DisconnectDuplicatesBySerial(keepID string, serial string) {
	if serial == "" {
		return
	}

	var toEvict []string

	r.mu.RLock()
	for id, p := range r.providers {
		if id == keepID {
			continue
		}
		if p.AttestationResult != nil && p.AttestationResult.SerialNumber == serial {
			toEvict = append(toEvict, id)
		}
	}
	r.mu.RUnlock()

	for _, id := range toEvict {
		r.logger.Warn("evicting duplicate provider from same device",
			"evicted_id", id,
			"kept_id", keepID,
			"serial", serial,
		)
		// Disconnect closes the socket itself.
		r.Disconnect(id)
	}
}

// RemoveProviderBySerial reports whether any currently-connected provider
// matches the identity (serial OR session id) and, if force is set, evicts them
// from the in-memory map. The DELETE endpoint calls it first with force=false
// to detect an online box (→409), then after the persisted record is purged it
// may call with force=true to drop a lingering in-memory entry so an evict-race
// can't re-persist. Returns true if a matching provider was connected.
func (r *Registry) RemoveProviderBySerial(serialOrID string, force bool) (online bool) {
	if serialOrID == "" {
		return false
	}

	var matched []string
	r.mu.RLock()
	for id, p := range r.providers {
		match := id == serialOrID
		if !match {
			// AttestationResult is written under p.mu (SetAttestationResult), so
			// read it through the thread-safe accessor — this loop holds only the
			// registry lock, not the per-provider one.
			if ar := p.GetAttestationResult(); ar != nil && ar.SerialNumber == serialOrID {
				match = true
			}
		}
		if match {
			matched = append(matched, id)
			// Presence in the map means a live WebSocket connection; treat it as
			// online regardless of routing status (an untrusted-but-connected box
			// would still re-register and re-persist).
			online = true
		}
	}
	r.mu.RUnlock()

	if force {
		// Disconnect takes r.mu itself — call OUTSIDE the RLock above to avoid a
		// self-deadlock (same pattern as DisconnectDuplicatesBySerial).
		for _, id := range matched {
			r.Disconnect(id)
		}
	}
	return online
}

// Heartbeat updates the provider's status and stats.
func (r *Registry) Heartbeat(id string, msg *protocol.HeartbeatMessage) {
	r.mu.RLock()
	p, ok := r.providers[id]
	r.mu.RUnlock()
	if !ok {
		r.logger.Warn("heartbeat from unknown provider", "provider_id", id)
		return
	}

	// Clamp heartbeat-reported capacity and metrics so a malicious provider
	// can't skew routing by reporting absurd values (e.g. TotalMemoryGB=1e9
	// would drive gpuUtil to 0 and sidestep health penalties).
	clampBackendCapacity(r.logger, id, msg.BackendCapacity)
	if v, changed := clampNonNeg(msg.SystemMetrics.MemoryPressure, 1.0); changed {
		msg.SystemMetrics.MemoryPressure = v
	}
	if v, changed := clampNonNeg(msg.SystemMetrics.CPUUsage, 1.0); changed {
		msg.SystemMetrics.CPUUsage = v
	}

	p.mu.Lock()
	now := time.Now()
	prevHB := p.LastHeartbeat
	p.LastHeartbeat = now
	p.Stats.RequestsServed += cumulativeDelta(p.lastSessionStats.RequestsServed, msg.Stats.RequestsServed)
	p.Stats.TokensGenerated += cumulativeDelta(p.lastSessionStats.TokensGenerated, msg.Stats.TokensGenerated)
	p.lastSessionStats = msg.Stats
	p.SystemMetrics = msg.SystemMetrics
	// Update backend capacity from heartbeat. A nil report clears prior live
	// capacity so stale slot state cannot keep influencing routing.
	p.BackendCapacity = msg.BackendCapacity
	if p.BackendCapacity != nil {
		chipFamily := p.Hardware.ChipFamily
		for _, slot := range p.BackendCapacity.Slots {
			if slot.ObservedDecodeTPS > 0 {
				r.tpsRegistry.Record(slot.Model, chipFamily, slot.ObservedDecodeTPS)
			}
		}
	}
	// Credit wall-clock time since the previous heartbeat as uptime, so an
	// always-online provider's uptimeRate reaches 1.0 and its reputation can
	// exceed the old 0.85 cap (RecordUptime was never called in prod).
	// Bound the credit to a window just above the heartbeat interval (30s) and
	// within the eviction staleness (90s): a larger gap means the provider was
	// effectively offline (it would have been reaped, or this is an in-process
	// stall) and must NOT be credited. A fresh registration sets LastHeartbeat
	// to registration time, so the first real heartbeat credits ~one interval.
	// Must run under p.mu (held here) — p.Reputation is mutated under p.mu by
	// the job/challenge handlers.
	if !prevHB.IsZero() {
		const maxUptimeCredit = 2 * time.Minute
		if delta := now.Sub(prevHB); delta > 0 && delta <= maxUptimeCredit {
			p.Reputation.RecordUptime(delta)
		}
	}
	// Update warm models from heartbeat. Always overwrite -- an empty list
	// means the provider has no models loaded, and stale entries must be
	// cleared to prevent TriggerModelSwaps from suppressing needed swaps.
	p.WarmModels = msg.WarmModels
	if msg.ActiveModel != nil {
		p.CurrentModel = *msg.ActiveModel
	} else {
		// nil active_model means no model is loaded — clear stale state
		// so attestation challenges don't compare against an unloaded model.
		p.CurrentModel = ""
	}
	// Only update status from heartbeat if provider is not actively serving
	// (serving status is managed by request lifecycle). Crucially, an
	// untrusted provider must NOT transition back to StatusOnline here —
	// that would cause an onlineCount double-decrement when Disconnect
	// later sees StatusOnline and decrements a second time.
	if p.Status == StatusUntrusted {
		// no status transitions allowed
	} else if p.Status != StatusServing || msg.Status == "idle" {
		switch msg.Status {
		case "idle":
			p.Status = StatusOnline
		case "serving":
			p.Status = StatusServing
		}
	}
	p.mu.Unlock()

	r.PersistProviderThrottled(p)
	// Persist accumulated uptime (throttled) so it survives restarts/reconnects;
	// the heartbeat path is otherwise the only place uptime grows.
	r.persistReputationThrottled(p)

	// Heartbeats can make a recovered slot routable again (for example after a
	// crash auto-restart). Drain matching queues using the canonical scheduler
	// rather than the legacy direct queue assignment path.
	r.drainQueuedRequestsForModels(providerModelIDs(p))

	// If queue drain didn't satisfy all pending requests (no warm provider),
	// check if a cold provider should swap models to serve queued demand.
	r.TriggerModelSwaps()
}

// SendLoadModel instructs a provider to eagerly load a model so it becomes
// warm for incoming requests. The provider will autonomously evict idle
// models to make room. This is a fire-and-forget call — the coordinator
// does not block waiting for the load to complete. The provider replies
// asynchronously with a load_model_status message.
func (r *Registry) SendLoadModel(providerID, modelID string) error {
	if r.loadModelSender != nil {
		if err := r.loadModelSender(providerID, modelID); err != nil {
			return err
		}
		r.logger.Info("sent load_model to provider", "provider_id", providerID, "model_id", modelID)
		return nil
	}

	r.mu.RLock()
	p, ok := r.providers[providerID]
	r.mu.RUnlock()
	if !ok {
		return fmt.Errorf("provider %q not found", providerID)
	}

	msg := protocol.LoadModelMessage{
		Type:    protocol.TypeLoadModel,
		ModelID: modelID,
	}
	data, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("failed to marshal load_model message: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	p.mu.Lock()
	conn := p.Conn
	p.mu.Unlock()

	if conn == nil {
		return fmt.Errorf("provider %q has no active connection", providerID)
	}

	if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
		return fmt.Errorf("failed to send load_model to provider %q: %w", providerID, err)
	}

	r.logger.Info("sent load_model to provider",
		"provider_id", providerID,
		"model_id", modelID,
	)
	return nil
}

// SendPrefetchModel instructs a provider to download + verify a model build
// in the background without loading it into GPU memory. It mirrors
// SendLoadModel but carries no expectation that the model becomes warm; the
// provider replies asynchronously with prefetch_model_status messages and
// re-advertises the build once it is verified on disk. It is the download-only
// primitive a provider's declarative reconciler uses internally to pre-stage a
// desired build before the hard-swap; the coordinator no longer drives a
// weighted migration with it.
func (r *Registry) SendPrefetchModel(providerID, modelID string, priority int) error {
	r.mu.RLock()
	p, ok := r.providers[providerID]
	r.mu.RUnlock()
	if !ok {
		return fmt.Errorf("provider %q not found", providerID)
	}

	msg := protocol.PrefetchModelMessage{
		Type:     protocol.TypePrefetchModel,
		ModelID:  modelID,
		Priority: priority,
	}
	data, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("failed to marshal prefetch_model message: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	p.mu.Lock()
	conn := p.Conn
	p.mu.Unlock()

	if conn == nil {
		return fmt.Errorf("provider %q has no active connection", providerID)
	}

	if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
		return fmt.Errorf("failed to send prefetch_model to provider %q: %w", providerID, err)
	}

	r.logger.Info("sent prefetch_model to provider",
		"provider_id", providerID,
		"model_id", modelID,
		"priority", priority,
	)
	return nil
}

// SendDesiredModels tells a provider, declaratively, the desired build per
// public alias it should converge to (plus the still-acceptable previous build).
// The provider reconciles on its own: background-prefetch any missing desired
// build, then hard-swap (advertise new, drop old) once verified. Mirrors
// SendPrefetchModel — fire-and-forget over the provider's WebSocket.
//
// An EMPTY entries set is still sent ("nothing is desired"): the provider's
// reconcile treats any build it was previously converging to but that is absent
// from the latest set as stale, so an alias delete/repoint that leaves a
// provider with no remaining entries MUST reach it — otherwise an in-flight
// prefetch for the removed alias would complete and hard-swap anyway. Callers
// MUST gate this on backend == mlx-swift AND a provider version that
// understands desired_models, because a pre-feature provider's strict decoder
// throws on unknown message types.
func (r *Registry) SendDesiredModels(providerID string, entries []protocol.DesiredModelEntry) error {
	if entries == nil {
		// Marshal as "models": [] — the Swift decoder requires an array.
		entries = []protocol.DesiredModelEntry{}
	}
	r.mu.RLock()
	p, ok := r.providers[providerID]
	r.mu.RUnlock()
	if !ok {
		return fmt.Errorf("provider %q not found", providerID)
	}

	msg := protocol.DesiredModelsMessage{
		Type:   protocol.TypeDesiredModels,
		Models: entries,
	}
	data, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("failed to marshal desired_models message: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	p.mu.Lock()
	conn := p.Conn
	p.mu.Unlock()

	if conn == nil {
		return fmt.Errorf("provider %q has no active connection", providerID)
	}

	if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
		return fmt.Errorf("failed to send desired_models to provider %q: %w", providerID, err)
	}

	r.logger.Info("sent desired_models to provider",
		"provider_id", providerID,
		"entries", len(entries),
	)
	return nil
}

// DesiredModelsForProvider builds the desired_models entries to push to a
// provider. Policy (conservative for this release): emit an entry only for
// aliases where the provider ALREADY advertises the desired OR previous build —
// i.e. the provider is already part of this alias's fleet and should converge to
// the desired build. Aliases the provider has never served are not offered (a
// brand-new provider must advertise some member of an alias to be told its
// desired build). An alias with an empty desired build is skipped.
func (r *Registry) DesiredModelsForProvider(providerID string) []protocol.DesiredModelEntry {
	r.mu.RLock()
	defer r.mu.RUnlock()
	p, ok := r.providers[providerID]
	if !ok || len(r.modelAliases) == 0 {
		return nil
	}
	p.mu.Lock()
	advertised := make(map[string]struct{}, len(p.Models))
	for _, m := range p.Models {
		if m.ID != "" {
			advertised[m.ID] = struct{}{}
		}
	}
	p.mu.Unlock()

	var entries []protocol.DesiredModelEntry
	for alias, t := range r.modelAliases {
		if t.Desired == "" {
			continue
		}
		_, hasDesired := advertised[t.Desired]
		_, hasPrevious := advertised[t.Previous]
		// A provider advertising only a RETIRED member (offline through a
		// retirement, e.g. previous_build cleared at the end of a rollout) is
		// still part of this alias's fleet — without this it would never learn
		// the desired build and serve zero alias traffic until manual action.
		hasRetired := false
		if !hasDesired && !hasPrevious {
			for _, b := range t.Retired {
				if _, ok := advertised[b]; ok {
					hasRetired = true
					break
				}
			}
		}
		if !hasDesired && !(t.Previous != "" && hasPrevious) && !hasRetired {
			continue
		}
		entries = append(entries, protocol.DesiredModelEntry{
			ModelName:     alias,
			DesiredBuild:  t.Desired,
			PreviousBuild: t.Previous,
		})
	}
	// Stable ordering keeps the wire output deterministic (and tests simple).
	sort.Slice(entries, func(i, j int) bool { return entries[i].ModelName < entries[j].ModelName })
	return entries
}

// TriggerModelSwaps checks for queued requests that have no warm provider
// and sends load_model to cold providers that have the model available on
// disk. This enables demand-driven model swapping: when requests queue for
// a model that no provider has warm, the coordinator proactively triggers
// a swap on an idle provider.
//
// Called after heartbeat processing and queue drain to catch demand that
// can't be satisfied by warm providers alone.
func (r *Registry) TriggerModelSwaps() {
	if r.queue == nil {
		return
	}

	queuedModels := r.queue.QueuedModels()
	if len(queuedModels) == 0 {
		return
	}

	now := time.Now()
	r.expirePendingModelLoads(now)

	actions := r.planModelLoadActions(queuedModels, now)
	actions = r.reservePendingModelLoads(actions, now)
	r.sendModelLoadActions(actions)
}

func (r *Registry) expirePendingModelLoads(now time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for key, expiresAt := range r.pendingModelLoads {
		if now.After(expiresAt) {
			delete(r.pendingModelLoads, key)
			delete(r.pendingModelLoadStarted, key)
		}
	}
}

func (r *Registry) planModelLoadActions(queuedModels []string, now time.Time) []modelLoadAction {
	r.mu.RLock()
	defer r.mu.RUnlock()

	selectedProviders := make(map[string]struct{})
	actions := make([]modelLoadAction, 0, len(queuedModels))
	for _, model := range queuedModels {
		if r.hasWarmProviderLocked(model, now) {
			continue
		}

		providerID := r.bestModelLoadProviderLocked(model, now, selectedProviders)
		if providerID == "" {
			continue
		}
		selectedProviders[providerID] = struct{}{}
		actions = append(actions, modelLoadAction{providerID: providerID, modelID: model})
	}
	return actions
}

// hasWarmProviderLocked reports whether a connected provider already has the
// model warm. Caller must hold r.mu (read or write).
func (r *Registry) hasWarmProviderLocked(model string, now time.Time) bool {
	for _, p := range r.providers {
		p.mu.Lock()
		warm := r.providerHasWarmModelLocked(p, model, now)
		p.mu.Unlock()
		if warm {
			return true
		}
	}
	return false
}

// providerHasWarmModelLocked checks whether the provider has the model warm
// AND passes the same routing safety gates used by the scheduler. A provider
// with stale attestation or failed privacy checks should not suppress swap
// planning. Caller must hold p.mu. Caller must hold r.mu (read or write).
func (r *Registry) providerHasWarmModelLocked(p *Provider, model string, now time.Time) bool {
	if p.Status == StatusOffline || p.Status == StatusUntrusted {
		return false
	}
	// Private-only providers serve only their owner's self-route traffic, never
	// the public fleet. They must not suppress public swap planning: otherwise a
	// private-only machine that happens to hold a queued public model warm makes
	// the planner believe the model is already served and skip load_model to an
	// eligible public node, stranding public requests until queue timeout.
	if p.PrivateOnly {
		return false
	}
	if trustRank(p.TrustLevel) < trustRank(r.MinTrustLevel) {
		return false
	}
	if !p.RuntimeVerified {
		return false
	}
	if !r.providerSupportsPrivateTextLocked(p) {
		return false
	}
	if p.LastChallengeVerified.IsZero() || now.Sub(p.LastChallengeVerified) > challengeFreshnessMaxAge {
		return false
	}
	if !r.providerServesCatalogModelLocked(p, model) {
		return false
	}
	if p.BackendCapacity != nil {
		for _, slot := range p.BackendCapacity.Slots {
			if slot.Model == model {
				// BackendCapacity is authoritative when present.
				// Only "running" and "idle" mean the model is warm.
				return slot.State == "running" || slot.State == "idle"
			}
		}
		// Model has no slot in BackendCapacity -- it's not loaded.
		return false
	}
	// Legacy provider without BackendCapacity: fall back to WarmModels.
	for _, warmModel := range p.WarmModels {
		if warmModel == model {
			return true
		}
	}
	return false
}

// bestModelLoadProviderLocked selects the eligible provider with the fewest
// pending requests. Caller must hold r.mu (read or write).
func (r *Registry) bestModelLoadProviderLocked(model string, now time.Time, selectedProviders map[string]struct{}) string {
	bestProviderID := ""
	for id, p := range r.providers {
		if _, selected := selectedProviders[id]; selected {
			continue
		}
		// Skip providers that have any pending model load -- sending a
		// second load_model while the first is in progress can cause
		// swap oscillation on single-slot providers.
		if r.providerHasPendingLoad(id) {
			continue
		}

		pendingCount, ok := r.modelLoadCandidatePendingLocked(p, model, now)
		if !ok {
			continue
		}
		// Only consider idle providers (no in-flight requests). Sending
		// load_model to a provider that is actively serving another model
		// will fail because the active slot cannot be evicted.
		if pendingCount == 0 {
			bestProviderID = id
			break
		}
	}
	return bestProviderID
}

// modelLoadCandidatePendingLocked applies the same routing safety gates used by
// the scheduler, then returns the provider's current pending request count.
// Caller must hold r.mu (read or write).
func (r *Registry) modelLoadCandidatePendingLocked(p *Provider, model string, now time.Time) (int, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()

	if p.Status == StatusOffline || p.Status == StatusUntrusted {
		return 0, false
	}
	// Private-only providers never serve public traffic, so never pick one as a
	// public load_model target (mirrors the public-routing exclusion).
	if p.PrivateOnly {
		return 0, false
	}
	if trustRank(p.TrustLevel) < trustRank(r.MinTrustLevel) {
		return 0, false
	}
	if !p.RuntimeVerified {
		return 0, false
	}
	if !r.providerSupportsPrivateTextLocked(p) {
		return 0, false
	}
	if p.LastChallengeVerified.IsZero() || now.Sub(p.LastChallengeVerified) > challengeFreshnessMaxAge {
		return 0, false
	}
	if !r.providerServesCatalogModelLocked(p, model) {
		return 0, false
	}

	// Memory gate: reject providers that cannot run the model per the catalog's
	// authoritative min_ram_gb (falling back to the weight heuristic only when
	// unknown). Shares modelFitsHardware with the consumer-routing admission
	// gate so the two can never drift. This prevents the coordinator from
	// sending load_model commands to machines that clearly cannot fit it, while
	// trusting the operator-published requirement rather than a synthetic
	// multiple that would exclude catalog-qualified nodes.
	if entry, ok := r.modelCatalog[model]; ok && (entry.MinRAMGB > 0 || entry.SizeGB > 0) {
		if !modelFitsHardware(entry.MinRAMGB, entry.SizeGB, float64(p.Hardware.MemoryGB)) {
			return 0, false
		}
	}

	return p.pendingCount(), true
}

func (r *Registry) reservePendingModelLoads(actions []modelLoadAction, now time.Time) []modelLoadAction {
	if len(actions) == 0 {
		return nil
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.pendingModelLoads == nil {
		r.pendingModelLoads = make(map[string]time.Time)
	}

	reserved := actions[:0]
	for _, action := range actions {
		// Check per-provider (not just per-key) to prevent concurrent
		// heartbeat goroutines from reserving the same idle provider
		// for different models.
		if r.providerHasPendingLoad(action.providerID) {
			continue
		}
		key := modelLoadKey(action.providerID, action.modelID)
		r.pendingModelLoads[key] = now.Add(pendingModelLoadTTL)
		r.pendingModelLoadStarted[key] = now
		reserved = append(reserved, action)
	}
	return reserved
}

func (r *Registry) sendModelLoadActions(actions []modelLoadAction) {
	for _, action := range actions {
		if err := r.SendLoadModel(action.providerID, action.modelID); err != nil {
			r.logger.Warn("failed to trigger model swap",
				"provider_id", action.providerID,
				"model_id", action.modelID,
				"error", err,
			)
			r.ClearPendingModelLoad(action.providerID, action.modelID)
		}
	}
}

func modelLoadKey(providerID, modelID string) string {
	return providerID + ":" + modelID
}

// providerHasPendingLoad reports whether the provider has any pending
// load_model command. Caller must hold r.mu (read or write).
func (r *Registry) providerHasPendingLoad(providerID string) bool {
	prefix := providerID + ":"
	for key := range r.pendingModelLoads {
		if len(key) > len(prefix) && key[:len(prefix)] == prefix {
			return true
		}
	}
	return false
}

// MarkModelWarm adds a model to the provider's WarmModels list if not already
// present. Called when load_model_status:succeeded arrives before the next
// heartbeat, so the scheduler sees the provider as warm during queue drain.
func (r *Registry) MarkModelWarm(providerID, modelID string) {
	r.mu.RLock()
	p, ok := r.providers[providerID]
	r.mu.RUnlock()
	if !ok {
		return
	}

	p.mu.Lock()
	defer p.mu.Unlock()
	for _, wm := range p.WarmModels {
		if wm == modelID {
			return // already warm
		}
	}
	p.WarmModels = append(p.WarmModels, modelID)
	p.CurrentModel = modelID

	// Inject a synthetic "idle" slot into BackendCapacity so the scheduler
	// sees the model as warm. Without this, the scheduler only checks
	// BackendCapacity.Slots (not WarmModels) for Swift providers, and a
	// stale snapshot without the new model's slot would treat it as cold
	// until the next heartbeat arrives.
	//
	// We only add/update the new model's slot and leave existing slots
	// untouched — the provider may have multiple model slots loaded
	// simultaneously (maxModelSlots defaults to 3). The next heartbeat
	// will provide the authoritative slot list.
	if p.BackendCapacity != nil {
		found := false
		for i, slot := range p.BackendCapacity.Slots {
			if slot.Model == modelID {
				p.BackendCapacity.Slots[i].State = "idle"
				found = true
				break
			}
		}
		if !found {
			p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{
				Model: modelID,
				State: "idle",
			})
		}
	}
}

// ClearPendingModelLoad removes a pending model load entry after a terminal
// load_model_status response.
func (r *Registry) ClearPendingModelLoad(providerID, modelID string) time.Duration {
	r.mu.Lock()
	key := modelLoadKey(providerID, modelID)
	started := r.pendingModelLoadStarted[key]
	delete(r.pendingModelLoads, key)
	delete(r.pendingModelLoadStarted, key)
	r.mu.Unlock()
	if started.IsZero() {
		return 0
	}
	return time.Since(started)
}

func (r *Registry) PendingModelLoadDuration(providerID, modelID string) time.Duration {
	r.mu.RLock()
	started := r.pendingModelLoadStarted[modelLoadKey(providerID, modelID)]
	r.mu.RUnlock()
	if started.IsZero() {
		return 0
	}
	return time.Since(started)
}

// BackoffPendingModelLoadForDrain re-stamps a pending load entry with the
// short drain backoff. Called when a provider rejects load_model because it
// is draining ahead of an auto-update restart: clearing the entry outright
// would re-send load_model to the same draining provider on the very next
// TriggerModelSwaps pass, while the full failure cooldown would suppress the
// provider long after a failed restart resumed serving. A successful restart
// clears the entry anyway via Disconnect.
func (r *Registry) BackoffPendingModelLoadForDrain(providerID, modelID string) {
	r.mu.Lock()
	key := modelLoadKey(providerID, modelID)
	r.pendingModelLoads[key] = time.Now().Add(pendingModelLoadDrainBackoff)
	if r.pendingModelLoadStarted == nil {
		r.pendingModelLoadStarted = make(map[string]time.Time)
	}
	if r.pendingModelLoadStarted[key].IsZero() {
		r.pendingModelLoadStarted[key] = time.Now()
	}
	r.mu.Unlock()
}

// RejectUnservableQueuedRequests checks whether any eligible provider can
// serve the given model. If not, all queued requests for the model are
// rejected immediately rather than waiting for the 120s queue timeout.
// Called after a load_model failure to give consumers a fast error.
func (r *Registry) RejectUnservableQueuedRequests(modelID string) {
	if r.queue == nil {
		return
	}
	if r.queue.QueueSize(modelID) == 0 {
		return
	}

	// Check if any provider can still serve this model. Only reject when
	// NO provider serves the model at all. If providers exist but are
	// temporarily at capacity (capacityRejections > 0), the requests
	// should wait — those providers may finish current work and become
	// available.
	// modelTooLarge is intentionally ignored here: a model that can never fit
	// any provider should NOT keep its queued requests waiting (they'd time out
	// after 120s) — fall through to fail them fast.
	// Base-shape check: "can any provider serve this model at all?" carries no
	// tool/vision constraint, so use the default (base) traits.
	candidates, capacityRejections, _ := r.QuickCapacityCheck(modelID, 500, defaultRequestedMaxTokens, RequestTraits{})
	if candidates > 0 || capacityRejections > 0 {
		return
	}

	// Prefer waiters are preserved only when their owner actually has an owned
	// provider serving this model (it may free up). A prefer waiter with no
	// owned provider is just waiting on the (now-unservable) public fleet, so it
	// should fail fast like any public request. Compute eligibility here —
	// OUTSIDE the queue lock — since OwnedProviderSummary takes the registry lock.
	preferOwnerEligible := make(map[string]bool)
	for _, owner := range r.queue.PreferWaiterOwners(modelID) {
		_, servesModel := r.OwnedProviderSummary(owner, modelID)
		preferOwnerEligible[owner] = servesModel > 0
	}

	failed := r.queue.FailQueuedRequestsForModel(modelID, preferOwnerEligible)
	if failed > 0 {
		r.logger.Warn("rejected queued requests for unservable model",
			"model_id", modelID,
			"rejected", failed,
		)
	}
}

func cumulativeDelta(previous, current int64) int64 {
	if current <= 0 {
		return 0
	}
	if current >= previous {
		return current - previous
	}
	// The provider process restarted and reset its in-memory counters.
	return current
}

// Disconnect removes a provider from the registry and cleans up pending requests.
func (r *Registry) Disconnect(id string) {
	r.mu.Lock()
	p, ok := r.providers[id]
	if ok {
		delete(r.providers, id)
		// Clear any pending model load entries for this provider.
		for key := range r.pendingModelLoads {
			if len(key) > len(id)+1 && key[:len(id)+1] == id+":" {
				delete(r.pendingModelLoads, key)
				delete(r.pendingModelLoadStarted, key)
			}
		}
		p.mu.Lock()
		if p.Status != StatusUntrusted {
			r.onlineCount.Add(-1)
			for _, m := range p.Models {
				r.modelProviderDec(m.ID)
			}
		}
		p.mu.Unlock()
	}
	r.mu.Unlock()

	if !ok {
		return
	}

	// Close all pending request channels so consumers get errors. Pending
	// requests created by tests may leave these channels nil, and consumer
	// goroutines may have already closed them on a successful/error path. Use
	// non-nil checks and recover so a single bad request cannot hang or panic
	// the disconnect cleanup.
	p.mu.Lock()
	for reqID, pr := range p.pendingReqs {
		if pr == nil {
			continue
		}
		if pr.ErrorCh != nil {
			func() {
				defer func() { recover() }()
				pr.ErrorCh <- protocol.InferenceErrorMessage{
					Type:       protocol.TypeInferenceError,
					RequestID:  reqID,
					Error:      "provider disconnected",
					StatusCode: 502,
				}
			}()
			func() {
				defer func() { recover() }()
				close(pr.ErrorCh)
			}()
		}
		if pr.ChunkCh != nil {
			func() {
				defer func() { recover() }()
				close(pr.ChunkCh)
			}()
		}
		if pr.CompleteCh != nil {
			func() {
				defer func() { recover() }()
				close(pr.CompleteCh)
			}()
		}
	}
	p.pendingReqs = make(map[string]*PendingRequest)
	p.mu.Unlock()

	// Tear down the socket. Deleting the map entry only makes the provider
	// unroutable; its read loop and challenge loop keep running on the open
	// socket and the coordinator keeps auto-ponging it, so the provider never
	// detects the drop and never reconnects — a "zombie" that's unroutable yet
	// still reports stale trust locally. CloseNow unblocks the read loop, which
	// unwinds the rest, and re-arms the provider's reconnect. CloseNow not Close:
	// Disconnect runs serially in the eviction loop and Close would block ~5s
	// waiting for a handshake the stale peer won't send. No-op if already closed;
	// outside r.mu so it can't stall the registry.
	if p.Conn != nil {
		_ = p.Conn.CloseNow()
	}

	// Close this connection's session row (async; durable uptime history).
	// Covers both graceful disconnects and evictStale (which calls Disconnect).
	if r.store != nil {
		saferun.Go(r.logger, "registry.closeSession", func() {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if err := r.store.CloseProviderSession(ctx, id, "disconnect", time.Now()); err != nil {
				r.logger.Warn("failed to close provider session", "provider_id", id, "error", err)
			}
		})
	}

	r.logger.Info("provider disconnected", "provider_id", id)
}

// GetProvider returns a provider by ID, or nil if not found.
func (r *Registry) GetProvider(id string) *Provider {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.providers[id]
}

// CountProvidersByBinaryHash returns the number of currently connected
// providers whose registration attested the given provider binary hash. Used by
// release administration to avoid removing a hash from the forced allowlist
// while old-but-still-connected providers are draining/restarting into a newer
// release.
func (r *Registry) CountProvidersByBinaryHash(hash string) int {
	normalized := strings.ToLower(strings.TrimSpace(hash))
	if normalized == "" {
		return 0
	}

	r.mu.RLock()
	defer r.mu.RUnlock()

	count := 0
	for _, p := range r.providers {
		p.mu.Lock()
		status := p.Status
		attestedHash := ""
		if p.AttestationResult != nil {
			attestedHash = p.AttestationResult.BinaryHash
		}
		p.mu.Unlock()

		if status != StatusOffline && strings.EqualFold(attestedHash, normalized) {
			count++
		}
	}
	return count
}

// MarkUntrusted sets a provider's status to untrusted for a hard/security
// reason (bad encrypted chunk, MDM/MDA failure, SIP disabled, binary or model
// hash mismatch, serial impersonation, attestation failure). The deroute is
// non-recoverable: the provider stays untrusted until it reconnects and
// re-registers. This is the default for every direct deroute call site.
func (r *Registry) MarkUntrusted(providerID string) {
	r.markUntrusted(providerID, false)
}

// MarkUntrustedTransient sets a provider's status to untrusted for a *transient*
// reason — MaxFailedChallenges consecutive missed-challenge timeouts (screen
// sleep, network blip, momentary Secure Enclave inaccessibility). Unlike
// MarkUntrusted, the provider remains eligible to self-recover: the challenge
// loop keeps challenging it (see ChallengeShouldStop), and a subsequent fully
// passing challenge (RecordChallengeSuccess) restores it to online.
//
// A passing challenge re-verifies signature, SIP, secure boot, binary hash,
// model hash and runtime before RecordChallengeSuccess is reached, so using it
// as the recovery trigger is safe.
func (r *Registry) MarkUntrustedTransient(providerID string) {
	r.markUntrusted(providerID, true)
}

// markUntrusted is the shared implementation. recoverable=true marks the untrust
// as transiently recoverable; recoverable=false is a hard deroute.
//
// Transition rules:
//   - not untrusted -> untrusted: decrement online/model counts, set status and
//     the recoverable flag.
//   - already untrusted + hard (recoverable=false): clear the flag. A hard
//     reason always overrides/downgrades a previously-recoverable untrust.
//   - already untrusted + transient (recoverable=true): leave the flag as-is, so
//     a transient timeout can never *upgrade* a hard deroute to recoverable
//     (matters for an in-flight challenge timeout that races a hard deroute).
func (r *Registry) markUntrusted(providerID string, recoverable bool) {
	r.mu.Lock()
	p, ok := r.providers[providerID]
	if !ok {
		r.mu.Unlock()
		return
	}

	p.mu.Lock()
	if p.Status != StatusUntrusted {
		r.onlineCount.Add(-1)
		for _, m := range p.Models {
			r.modelProviderDec(m.ID)
		}
		p.Status = StatusUntrusted
		p.untrustedRecoverable = recoverable
	} else if !recoverable {
		p.untrustedRecoverable = false
	}
	failed := p.FailedChallenges // read under p.mu (the old code read this unlocked)
	p.mu.Unlock()
	r.mu.Unlock()

	r.logger.Warn("provider marked as untrusted",
		"provider_id", providerID,
		"failed_challenges", failed,
		"recoverable", recoverable,
	)
}

// SetTrustLevel updates a provider's trust level (thread-safe).
func (r *Registry) SetTrustLevel(providerID string, level TrustLevel) {
	r.mu.RLock()
	p, ok := r.providers[providerID]
	r.mu.RUnlock()
	if !ok {
		return
	}
	p.mu.Lock()
	p.TrustLevel = level
	p.mu.Unlock()

	// Persist trust state.
	r.persistProviderNow(p)
}

// RecordChallengeSuccess records a successful challenge-response verification.
// A fully passing challenge re-verifies signature, SIP, secure boot, binary
// hash, model hash and runtime (see verifyChallengeResponse) before this is
// called, so it doubles as the recovery trigger for a *transiently* untrusted
// provider.
//
// Returns true iff this call recovered a transiently-untrusted provider back to
// online. The caller (verifyChallengeResponse) uses that to push a fresh
// "online" trust_status so the provider clears its local untrusted state and
// cancels the pending diagnostic auto-report it scheduled at deroute time.
func (r *Registry) RecordChallengeSuccess(providerID string) bool {
	r.mu.RLock()
	p, ok := r.providers[providerID]
	r.mu.RUnlock()
	if !ok {
		return false
	}

	recovered := r.recoverIfTransientlyUntrusted(providerID, p)

	p.mu.Lock()
	p.LastChallengeVerified = time.Now()
	p.FailedChallenges = 0
	if !p.ChallengeVerifiedSIP {
		p.ChallengeVerifiedSIP = true
	}
	p.Reputation.RecordChallengePass()
	p.mu.Unlock()

	// Persist challenge state and reputation.
	r.persistProviderNow(p)
	r.persistReputation(p)

	if recovered {
		r.logger.Info("provider recovered from transient deroute", "provider_id", providerID)
	}

	// A newly verified (or newly recovered) provider may unlock queued requests
	// for any model it serves.
	r.drainQueuedRequestsForModels(providerModelIDs(p))

	return recovered
}

// recoverIfTransientlyUntrusted promotes a transiently-untrusted provider back
// to online, mirroring markUntrusted's bookkeeping in reverse. Returns true iff
// a transition occurred. It acquires r.mu (write) then p.mu — the same order as
// markUntrusted/Register/Disconnect — so online/model counts stay consistent and
// the path is deadlock-free.
func (r *Registry) recoverIfTransientlyUntrusted(providerID string, p *Provider) bool {
	// Cheap pre-check under p.mu only, so the common (non-recovery) success path
	// never contends on the registry write lock.
	p.mu.Lock()
	eligible := p.Status == StatusUntrusted && p.untrustedRecoverable
	p.mu.Unlock()
	if !eligible {
		return false
	}

	r.mu.Lock()
	// Re-verify membership: RecordChallengeSuccess looked p up under RLock and
	// released it, so Disconnect may have removed (or replaced) it since. A
	// transiently-untrusted provider was already decremented out of the counts,
	// and Disconnect does not decrement an untrusted provider, so incrementing a
	// stale/removed pointer here would permanently corrupt onlineCount and
	// modelProviders. Only recover the provider still registered under this ID.
	if cur, ok := r.providers[providerID]; !ok || cur != p {
		r.mu.Unlock()
		return false
	}
	p.mu.Lock()
	// Re-check under the write lock: a hard deroute may have intervened and
	// cleared the recoverable flag between the pre-check and here.
	if p.Status != StatusUntrusted || !p.untrustedRecoverable {
		p.mu.Unlock()
		r.mu.Unlock()
		return false
	}
	r.onlineCount.Add(1)
	for _, m := range p.Models {
		r.modelProviderInc(m.ID)
	}
	p.Status = StatusOnline
	p.untrustedRecoverable = false
	p.mu.Unlock()
	r.mu.Unlock()
	return true
}

// RecordChallengeFailure records a failed challenge-response. Returns the
// new consecutive failure count.
//
// When transientOnly is true (timeout — the provider didn't respond in time),
// routing eligibility is preserved until MaxFailedChallenges consecutive
// failures. A single transient timeout should not instantly deroute a provider
// that was verified seconds ago.
//
// When transientOnly is false (security failure — wrong signature, SIP
// disabled, binary hash mismatch, etc.), routing eligibility is cleared
// immediately because the provider actively failed a security check.
func (r *Registry) RecordChallengeFailure(providerID string, transientOnly bool) int {
	r.mu.RLock()
	p, ok := r.providers[providerID]
	r.mu.RUnlock()
	if !ok {
		return 0
	}

	p.mu.Lock()
	p.FailedChallenges++
	p.Reputation.RecordChallengeFail()
	count := p.FailedChallenges

	if !transientOnly {
		// Security failure — clear routing eligibility immediately.
		p.LastChallengeVerified = time.Time{}
		p.ChallengeVerifiedSIP = false
	} else if count >= MaxFailedChallenges {
		// Transient failures only clear after hitting the threshold.
		p.LastChallengeVerified = time.Time{}
		p.ChallengeVerifiedSIP = false
	}
	p.mu.Unlock()

	// Persist challenge state and reputation.
	r.persistProviderNow(p)
	r.persistReputation(p)

	return count
}

// TrustMultiplier returns the trust multiplier for routing score calculation.
func TrustMultiplier(t TrustLevel) float64 {
	switch t {
	case TrustHardware:
		return 1.0
	case TrustSelfSigned:
		return 0.8
	default:
		return 0.5
	}
}

// DefaultMaxConcurrent is the fallback concurrency limit for providers
// that don't report backend capacity. Providers that report BackendCapacity
// in heartbeats get a dynamic limit based on their total memory.
const DefaultMaxConcurrent = 4

// MaxConcurrentRequests is kept as an alias for backward compatibility
// with tests and external code that reference the old constant name.
const MaxConcurrentRequests = DefaultMaxConcurrent

// ScoreProvider calculates a routing score for a provider.
// Higher scores indicate better routing candidates.
// Score = (1 - load) * decode_tps * trust_multiplier * reputation * warm_bonus * health_factor
//
// Uses dynamic max based on hardware when backend capacity is reported.
func ScoreProvider(p *Provider, model string) float64 {
	// Providers that have not passed runtime integrity verification score 0
	// and should never be selected for routing.
	p.mu.Lock()
	runtimeVerified := p.RuntimeVerified
	p.mu.Unlock()
	if !runtimeVerified {
		return 0
	}

	// Load: gradient from 0.0 (idle) to 1.0 (at max concurrency).
	// Uses a positive provider-reported slot cap when present, otherwise the
	// legacy provider-level dynamic max.
	p.mu.Lock()
	maxConc := p.maxConcurrencyForModelLocked(model)
	pending := float64(p.pendingLoadForModelLocked(model))
	p.mu.Unlock()
	load := pending / float64(maxConc)
	if load > 1.0 {
		load = 1.0
	}

	// Snapshot mutable fields under lock. These are written by Heartbeat
	// and SetTrustLevel from other goroutines.
	p.mu.Lock()
	decodeTPS := p.DecodeTPS
	trustLevel := p.TrustLevel
	warmModels := append([]string{}, p.WarmModels...)
	currentModel := p.CurrentModel
	sysMetrics := p.SystemMetrics
	repScore := p.Reputation.Score()
	backendCap := p.BackendCapacity
	p.mu.Unlock()

	// Base decode TPS — when not reported by the provider, estimate from
	// hardware memory bandwidth using sqrt scaling. Linear bandwidth
	// ratios (e.g. 546 vs 300 = 1.8x) create too much routing skew;
	// sqrt dampens this to ~1.35x, giving faster hardware a mild
	// preference while still distributing load across all providers.
	if decodeTPS <= 0 {
		bw := float64(p.Hardware.MemoryBandwidthGBs)
		if bw > 0 {
			decodeTPS = math.Sqrt(bw) // sqrt scaling: 546→23.4, 400→20, 300→17.3, 150→12.2
		} else {
			decodeTPS = 1.0
		}
	}

	trustMul := TrustMultiplier(trustLevel)

	// Warm model bonus: only applies when the provider is IDLE (no pending
	// requests). This prevents a warm provider from monopolizing all traffic.
	// Once a warm provider has any pending requests, cold providers compete
	// on equal terms — a 20s parallel cold-start beats waiting in a serial
	// queue behind a single warm provider.
	warmBonus := 1.0
	isIdle := pending == 0
	if isIdle {
		for _, wm := range warmModels {
			if wm == model {
				warmBonus = 1.5
				break
			}
		}
		if currentModel == model {
			warmBonus = 1.5
		}
	}

	// Cold-start / crash penalty: apply regardless of load. These represent
	// providers whose backend is DOWN (not just cold in cache). Loading from
	// idle_shutdown takes ~30s, crashed backends may not recover at all.
	if backendCap != nil {
		for _, slot := range backendCap.Slots {
			if slot.Model == model {
				switch slot.State {
				case "idle_shutdown":
					warmBonus = 0.1
				case "crashed":
					warmBonus = 0.05
				}
				break
			}
		}
	}

	// Health factor from live system metrics
	m := sysMetrics

	// Memory pressure: linear penalty. At 0.9 -> factor 0.1
	memFactor := 1.0 - m.MemoryPressure
	if memFactor < 0.1 {
		memFactor = 0.1
	}

	// CPU usage: gentle penalty (max 50% reduction at full load)
	cpuFactor := 1.0 - (m.CPUUsage * 0.5)

	// Thermal: step penalties
	thermalFactor := 1.0
	switch m.ThermalState {
	case "fair":
		thermalFactor = 0.8
	case "serious":
		thermalFactor = 0.4
	case "critical":
		thermalFactor = 0.0
	}

	healthFactor := memFactor * cpuFactor * thermalFactor

	// GPU memory pressure from backend capacity: penalize providers with
	// high GPU utilization to prefer those with more headroom.
	if backendCap != nil && backendCap.GPUMemoryActiveGB > 0 {
		totalMem := backendCap.TotalMemoryGB
		if totalMem <= 0 {
			totalMem = float64(p.Hardware.MemoryGB)
		}
		if totalMem > 0 {
			gpuUtil := backendCap.GPUMemoryActiveGB / totalMem
			gpuFactor := 1.0 - (gpuUtil * 0.5) // max 50% penalty at full GPU
			if gpuFactor < 0.1 {
				gpuFactor = 0.1
			}
			healthFactor *= gpuFactor
		}
	}

	return (1.0 - load) * decodeTPS * trustMul * repScore * warmBonus * healthFactor
}

// FindProvider selects an available provider for the given model using
// intelligent scoring based on benchmark data, trust level, reputation,
// warm model cache, and backend capacity. Picks the highest-scoring
// provider that has concurrency headroom (dynamic limit based on hardware).
// Optional excludeIDs are provider IDs to skip (e.g. providers that
// already failed for this request during retry).
func (r *Registry) FindProvider(model string, excludeIDs ...string) *Provider {
	return r.FindProviderWithTrust(model, "", excludeIDs...)
}

// FindProviderWithTrust selects a provider with an optional per-request
// minimum trust level. If minTrust is empty, the registry's default
// MinTrustLevel is used. Consumers can request a specific trust level
// (e.g. hardware) to filter providers. Optional excludeIDs are provider
// IDs to skip during selection.
func (r *Registry) FindProviderWithTrust(model string, minTrust TrustLevel, excludeIDs ...string) *Provider {
	r.mu.Lock()
	defer r.mu.Unlock()

	// Build a set of excluded provider IDs for O(1) lookup.
	excludeSet := make(map[string]struct{}, len(excludeIDs))
	for _, id := range excludeIDs {
		excludeSet[id] = struct{}{}
	}

	// Determine effective minimum: max of registry default and per-request
	effectiveMin := r.MinTrustLevel
	if minTrust != "" && trustRank(minTrust) > trustRank(effectiveMin) {
		effectiveMin = minTrust
	}

	// Challenge staleness threshold: providers must have passed a
	// challenge within the last interval + grace period. The challenge
	// interval is 5 minutes, so we allow up to 6 minutes (interval +
	// 1-minute grace) to avoid a gap where providers are unroutable
	// between challenge cycles.
	challengeMaxAge := 6 * time.Minute
	now := time.Now()

	var candidates []*Provider
	for _, p := range r.providers {
		// Skip explicitly excluded providers (failed on previous retry attempts).
		if _, excluded := excludeSet[p.ID]; excluded {
			continue
		}
		// Skip pairs cooling down after a dispatch-time load failure —
		// re-picking them just burns a retry attempt on an instant 503.
		if r.dispatchLoadCooldownActiveLocked(p.ID, model, now) {
			continue
		}

		p.mu.Lock()
		status := p.Status
		trust := p.TrustLevel
		lastChallenge := p.LastChallengeVerified
		runtimeVerified := p.RuntimeVerified
		privateReady := r.providerSupportsPrivateTextLocked(p)
		p.mu.Unlock()

		if status == StatusOffline || status == StatusUntrusted {
			continue
		}
		if trustRank(trust) < trustRank(effectiveMin) {
			continue
		}
		if !runtimeVerified || !privateReady {
			continue
		}
		if lastChallenge.IsZero() || now.Sub(lastChallenge) > challengeMaxAge {
			continue
		}
		// providerServesCatalogModelLocked ranges p.Models, which is replaced
		// copy-on-write by UpdateModelWeightHashes under p.mu (not r.mu), so it
		// must run under p.mu — fold it into the same locked section as the
		// headroom check rather than calling it after unlock.
		p.mu.Lock()
		hasHeadroom := p.hasConcurrencyHeadroomForModelLocked(model)
		serves := hasHeadroom && r.providerServesCatalogModelLocked(p, model)
		p.mu.Unlock()
		if !hasHeadroom {
			continue
		}
		if serves {
			candidates = append(candidates, p)
		}
	}

	if len(candidates) == 0 {
		return nil
	}

	// Score all candidates and pick the highest.
	bestIdx := 0
	bestScore := ScoreProvider(candidates[0], model)
	for i := 1; i < len(candidates); i++ {
		s := ScoreProvider(candidates[i], model)
		if s > bestScore {
			bestScore = s
			bestIdx = i
		}
	}

	// When multiple candidates tie for the best score (common when all
	// providers have the same hardware/TPS and load), randomly pick among
	// them to distribute load instead of always picking the first one.
	var ties []*Provider
	for _, c := range candidates {
		if ScoreProvider(c, model) >= bestScore-0.001 {
			ties = append(ties, c)
		}
	}
	var selected *Provider
	if len(ties) > 1 {
		selected = ties[rand.Intn(len(ties))]
	} else {
		selected = candidates[bestIdx]
	}

	selected.mu.Lock()
	selected.Status = StatusServing
	selected.mu.Unlock()

	return selected
}

// SetProviderIdle updates a provider's status after a request completes.
// If pending count reaches zero, status goes back to online. If there are
// queued requests and the provider has concurrency headroom, the next
// queued request is assigned immediately.
func (r *Registry) SetProviderIdle(id string) {
	r.mu.RLock()
	p, ok := r.providers[id]
	r.mu.RUnlock()
	if !ok {
		return
	}

	p.mu.Lock()
	if p.pendingCount() == 0 && p.Status != StatusUntrusted && p.Status != StatusOffline {
		p.Status = StatusOnline
	}
	p.mu.Unlock()

	// Use all newly available capacity, not just a single queued request.
	r.drainQueuedRequestsForModels(providerModelIDs(p))
}

// AttestationSummary provides aggregate attestation status for a model's providers.
type AttestationSummary struct {
	SecureEnclave bool `json:"secure_enclave"`
	SIPEnabled    bool `json:"sip_enabled"`
	SecureBoot    bool `json:"secure_boot"`
}

// AggregateModel is a deduplicated model entry for the /v1/models endpoint.
type AggregateModel struct {
	ID                string              `json:"id"`
	ModelType         string              `json:"model_type"`
	Quantization      string              `json:"quantization"`
	Providers         int                 `json:"providers"`          // number of providers offering this model
	AttestedProviders int                 `json:"attested_providers"` // number of attested providers
	TrustLevel        TrustLevel          `json:"trust_level"`        // highest trust level among providers
	Attestation       *AttestationSummary `json:"attestation,omitempty"`
}

// ListModels returns deduplicated models from all online providers.
func (r *Registry) ListModels() []AggregateModel {
	r.mu.RLock()
	defer r.mu.RUnlock()

	type modelAgg struct {
		modelType     string
		quantization  string
		count         int
		attestedCount int
		highestTrust  TrustLevel
		secureEnclave bool
		sipEnabled    bool
		secureBoot    bool
	}

	// Aggregate by model ID only — consumers request by ID, so providers
	// offering the same model ID should be counted together regardless of
	// minor metadata differences.
	agg := make(map[string]*modelAgg)
	for _, p := range r.providers {
		p.mu.Lock()
		status := p.Status
		trust := p.TrustLevel
		attested := p.Attested
		attestResult := p.AttestationResult
		privateReady := r.providerSupportsPrivateTextLocked(p)
		privateOnly := p.PrivateOnly
		// p.Models is replaced copy-on-write by UpdateModelWeightHashes (which
		// holds only p.mu, not r.mu), so snapshot it here under p.mu rather than
		// ranging the field after unlock.
		models := make([]protocol.ModelInfo, len(p.Models))
		copy(models, p.Models)
		p.mu.Unlock()

		if status == StatusOffline || status == StatusUntrusted {
			continue
		}
		// Private-only providers serve only their owner's self-route traffic, so
		// they must not appear in or inflate the public /v1/models aggregation.
		if privateOnly {
			continue
		}
		if !r.trustMeetsMinimum(trust) || !privateReady {
			continue
		}
		for _, m := range models {
			if !r.modelAllowedByCatalogLocked(m) {
				continue
			}
			k := m.ID
			a, ok := agg[k]
			if !ok {
				a = &modelAgg{
					modelType:    m.ModelType,
					quantization: m.Quantization,
					highestTrust: TrustNone,
				}
				agg[k] = a
			}
			a.count++

			// Update highest trust level
			if trustRank(trust) > trustRank(a.highestTrust) {
				a.highestTrust = trust
			}

			if attested && attestResult != nil {
				a.attestedCount++
				a.secureEnclave = a.secureEnclave || attestResult.SecureEnclaveAvailable
				a.sipEnabled = a.sipEnabled || attestResult.SIPEnabled
				a.secureBoot = a.secureBoot || attestResult.SecureBootEnabled
			}
		}
	}

	models := make([]AggregateModel, 0, len(agg))
	for k, a := range agg {
		am := AggregateModel{
			ID:                k,
			ModelType:         a.modelType,
			Quantization:      a.quantization,
			Providers:         a.count,
			AttestedProviders: a.attestedCount,
			TrustLevel:        a.highestTrust,
		}
		if a.attestedCount > 0 {
			am.Attestation = &AttestationSummary{
				SecureEnclave: a.secureEnclave,
				SIPEnabled:    a.sipEnabled,
				SecureBoot:    a.secureBoot,
			}
		}
		models = append(models, am)
	}

	return models
}

// ModelCountryCodes returns the sorted, de-duplicated ISO 3166-1 alpha-2
// country codes of online providers serving the given model. Used to populate
// the OpenRouter "datacenters" field. Only routing-eligible providers count —
// the same gates as ListModels (online, meets the minimum trust level, and
// private-text ready) — so a country whose providers can't actually serve the
// model is not advertised. Providers without a known location are skipped.
func (r *Registry) ModelCountryCodes(modelID string) []string {
	r.mu.RLock()
	defer r.mu.RUnlock()

	seen := make(map[string]bool)
	for _, p := range r.providers {
		p.mu.Lock()
		status := p.Status
		trust := p.TrustLevel
		privateReady := r.providerSupportsPrivateTextLocked(p)
		var cc string
		if p.Location != nil {
			cc = strings.ToUpper(strings.TrimSpace(p.Location.CountryCode))
		}
		serves := false
		if cc != "" {
			for i := range p.Models {
				if p.Models[i].ID == modelID {
					serves = true
					break
				}
			}
		}
		p.mu.Unlock()
		if !serves {
			continue
		}
		// Apply the same routing-eligibility gates as ListModels.
		if status == StatusOffline || status == StatusUntrusted {
			continue
		}
		if !r.trustMeetsMinimum(trust) || !privateReady {
			continue
		}
		seen[cc] = true
	}
	if len(seen) == 0 {
		return nil
	}
	out := make([]string, 0, len(seen))
	for c := range seen {
		out = append(out, c)
	}
	sort.Strings(out)
	return out
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

// RecordJobSuccess records a successful job completion for the provider's
// reputation. latency is the per-request responsiveness sample (time to first
// content, with the prompt-size prefill removed); a non-positive value records
// the success without touching the latency EWMA. Both updates happen under one
// lock and a single persist.
func (r *Registry) RecordJobSuccess(providerID string, latency time.Duration) {
	r.mu.RLock()
	p, ok := r.providers[providerID]
	r.mu.RUnlock()
	if !ok {
		return
	}

	p.mu.Lock()
	p.Reputation.RecordJobSuccess()
	p.Reputation.RecordLatency(latency)
	p.mu.Unlock()

	// Persist reputation.
	r.persistReputation(p)
}

// RecordLatency folds a per-request responsiveness sample into the provider's
// latency EWMA, independent of job-success counting. It is recorded by the
// consumer/dispatch goroutine (which owns the request timing) at commit, so the
// provider read-loop goroutine never has to read that goroutine's timing. A
// non-positive latency is ignored.
//
// It updates the in-memory EWMA only and does NOT persist. The updated
// AvgResponseTime is persisted by the RecordJobSuccess / RecordJobFailure that
// follows on completion (which snapshots the whole reputation row). Persisting a
// full row here would race that terminal write — a pre-terminal snapshot carrying
// stale TotalJobs/SuccessfulJobs could land after it and clobber the counts.
func (r *Registry) RecordLatency(providerID string, latency time.Duration) {
	if latency <= 0 {
		return
	}
	r.mu.RLock()
	p, ok := r.providers[providerID]
	r.mu.RUnlock()
	if !ok {
		return
	}

	p.mu.Lock()
	p.Reputation.RecordLatency(latency)
	p.mu.Unlock()
}

// RecordJobFailure records a failed job for the provider's reputation.
func (r *Registry) RecordJobFailure(providerID string) {
	r.mu.RLock()
	p, ok := r.providers[providerID]
	r.mu.RUnlock()
	if !ok {
		return
	}

	p.mu.Lock()
	p.Reputation.RecordJobFailure()
	p.mu.Unlock()

	// Persist reputation.
	r.persistReputation(p)
}

// ProviderCount returns the number of registered providers.
// modelProviderInc increments the provider count for a model. Must be called
// with r.mu held.
func (r *Registry) modelProviderInc(model string) {
	r.modelProvidersMu.Lock()
	c, ok := r.modelProviders[model]
	if !ok {
		c = &atomic.Int64{}
		r.modelProviders[model] = c
	}
	r.modelProvidersMu.Unlock()
	c.Add(1)
}

// modelProviderDec decrements the provider count for a model. Must be called
// with r.mu held.
func (r *Registry) modelProviderDec(model string) {
	r.modelProvidersMu.Lock()
	c, ok := r.modelProviders[model]
	r.modelProvidersMu.Unlock()
	if ok {
		v := c.Add(-1)
		if v <= 0 {
			r.modelProvidersMu.Lock()
			delete(r.modelProviders, model)
			r.modelProvidersMu.Unlock()
		}
	}
}

// OnlineCount returns the number of online providers.
func (r *Registry) OnlineCount() int64 {
	return r.onlineCount.Load()
}

// CodeAttestationCoverage reports how many currently online (non-offline,
// non-untrusted) providers have passed APNs code-identity attestation, plus the
// online total. Operators watch this during the grace window to judge when it is
// safe to let the APNS_ENFORCE_AFTER deadline pass — after which every
// un-attested provider (incl. all headless / pre-0.6.0 boxes) is derouted.
// Thread-safe.
func (r *Registry) CodeAttestationCoverage() (codeAttested, online int) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, p := range r.providers {
		p.mu.Lock()
		if p.Status != StatusOffline && p.Status != StatusUntrusted {
			online++
			if p.CodeAttested {
				codeAttested++
			}
		}
		p.mu.Unlock()
	}
	return codeAttested, online
}

// ModelProviderSnapshot returns a snapshot of model_id -> provider count.
func (r *Registry) ModelProviderSnapshot() map[string]int64 {
	r.modelProvidersMu.Lock()
	snap := make(map[string]int64, len(r.modelProviders))
	for model, c := range r.modelProviders {
		if v := c.Load(); v > 0 {
			snap[model] = v
		}
	}
	r.modelProvidersMu.Unlock()
	return snap
}

func (r *Registry) ProviderCount() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.providers)
}

func (r *Registry) ProviderCountByVersion() map[string]int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	counts := make(map[string]int)
	for _, p := range r.providers {
		p.mu.Lock()
		online := p.Status != StatusOffline && p.Status != StatusUntrusted
		p.mu.Unlock()
		if !online {
			continue
		}
		ver := p.Version
		if ver == "" {
			ver = "unknown"
		}
		counts[ver]++
	}
	return counts
}

// TrustStatusCount is one bucket of the fleet trust-state gauge.
type TrustStatusCount struct {
	TrustLevel string
	Status     string
	Count      int
}

// ProviderCountByTrustStatus buckets every connected provider by
// (trust_level, status) so the coordinator can alert on a growing
// self_signed/untrusted cohort. Offline providers are excluded (they are not a
// live routability problem). Unlike most gauges this includes untrusted, since
// the untrusted cohort is exactly what we want visibility into.
func (r *Registry) ProviderCountByTrustStatus() []TrustStatusCount {
	r.mu.RLock()
	defer r.mu.RUnlock()
	type key struct{ trust, status string }
	counts := make(map[key]int)
	for _, p := range r.providers {
		p.mu.Lock()
		status := p.Status
		trust := p.TrustLevel
		p.mu.Unlock()
		if status == StatusOffline {
			continue
		}
		counts[key{string(trust), string(status)}]++
	}
	out := make([]TrustStatusCount, 0, len(counts))
	for k, n := range counts {
		out = append(out, TrustStatusCount{TrustLevel: k.trust, Status: k.status, Count: n})
	}
	return out
}

// ProviderCountByMDMFailure buckets connected, non-hardware providers by their
// last MDM verification failure reason (device-not-found, found-not-enrolled,
// securityinfo-timeout, posture-mismatch, error). This is the stuck-cohort
// breakdown: it distinguishes "never enrolled" from "enrolled but the live
// SecurityInfo check is timing out" so an operator knows whether the problem is
// provider-side enrollment or APNs/MDM delivery. Hardware providers (reason
// cleared) are excluded.
func (r *Registry) ProviderCountByMDMFailure() map[string]int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	counts := make(map[string]int)
	for _, p := range r.providers {
		p.mu.Lock()
		status := p.Status
		trust := p.TrustLevel
		reason := p.MDMFailureReason
		p.mu.Unlock()
		if status == StatusOffline || trust == TrustHardware {
			continue
		}
		if reason == "" {
			reason = "pending"
		}
		counts[reason]++
	}
	return counts
}

// FleetSnapshot is the read-only summary used by metrics polling. We
// don't lock individual providers — counts may be off-by-one under
// heavy churn — that's acceptable for gauges.
type FleetSnapshot struct {
	Connected  int
	Idle       int
	QueueDepth int
}

// Snapshot returns aggregate counts for /metrics gauges. Cheap enough
// to call every few seconds. Takes the registry's read lock for the
// outer iteration AND each provider's mutex briefly to read Status and
// pending count — those fields are written under p.mu elsewhere
// (Heartbeat, AddPending, RemovePending), so reading them without
// p.mu is a data race even if the gauge value is only advisory.
func (r *Registry) Snapshot() FleetSnapshot {
	r.mu.RLock()
	defer r.mu.RUnlock()
	idle := 0
	for _, p := range r.providers {
		p.mu.Lock()
		isIdle := p.Status == StatusOnline && len(p.pendingReqs) == 0
		p.mu.Unlock()
		if isIdle {
			idle++
		}
	}
	q := 0
	if r.queue != nil {
		q = r.queue.TotalSize()
	}
	return FleetSnapshot{
		Connected:  len(r.providers),
		Idle:       idle,
		QueueDepth: q,
	}
}

// ModelCapacity describes the live capacity for a single model.
type ModelCapacity struct {
	ModelID              string  `json:"id"`
	Ready                bool    `json:"ready"`                  // at least one routable provider with headroom
	CanAccept            bool    `json:"can_accept"`             // ready AND queue not full
	RoutableProviders    int     `json:"routable_providers"`     // passed all gates
	WarmProviders        int     `json:"warm_providers"`         // model loaded (slot state "running" or "idle")
	RunningProviders     int     `json:"running_providers"`      // model loaded with active requests (slot state "running")
	ColdProviders        int     `json:"cold_providers"`         // model available but not loaded
	ActiveRequests       int     `json:"active_requests"`        // in-flight across fleet
	QueuedRequests       int     `json:"queued_requests"`        // waiting in coordinator queue
	QueueLimit           int     `json:"queue_limit"`            // max queue depth per model
	AggregateTPS         float64 `json:"aggregate_tps"`          // sum of effective decode TPS
	EstimatedTTFTMs      int64   `json:"estimated_ttft_ms"`      // best-case TTFT from lowest-cost warm provider
	TokenBudgetRemaining int64   `json:"token_budget_remaining"` // aggregate free budget across providers
	TokenBudgetTotal     int64   `json:"token_budget_total"`     // aggregate total budget
}

// providerCapSnap is a per-provider snapshot collected under the registry
// lock, then aggregated into ModelCapacity outside the lock.
type providerCapSnap struct {
	model                 string
	warm                  bool
	running               bool
	hasHeadroom           bool // pending < maxConcurrency
	effectiveTPS          float64
	prefillTPS            float64
	activeRequests        int // numRunning + numWaiting from backend slot, or pendingCount
	backlogTokens         float64
	activeTokenBudgetMax  int64
	activeTokenBudgetUsed int64
	queuedTokenBudget     int64
}

// ModelCapacitySnapshot returns a capacity snapshot for every model served
// by at least one provider. Providers must pass the same routing gates as
// snapshotProviderLocked (status, trust, runtime, privacy, challenge
// freshness, concurrency headroom) to be counted as routable.
func (r *Registry) ModelCapacitySnapshot() []ModelCapacity {
	now := time.Now()

	// Phase 1: collect per-provider snapshots under the lock.
	var snaps []providerCapSnap

	r.mu.RLock()
	for _, p := range r.providers {
		p.mu.Lock()

		// Apply the same gates as snapshotProviderLocked. Private-only machines
		// never serve the public fleet, so they do not count toward public
		// model capacity.
		if p.Status == StatusOffline || p.Status == StatusUntrusted {
			p.mu.Unlock()
			continue
		}
		if p.PrivateOnly {
			p.mu.Unlock()
			continue
		}
		if trustRank(p.TrustLevel) < trustRank(r.MinTrustLevel) {
			p.mu.Unlock()
			continue
		}
		if !p.RuntimeVerified {
			p.mu.Unlock()
			continue
		}
		if !r.providerSupportsPrivateTextLocked(p) {
			p.mu.Unlock()
			continue
		}
		if p.LastChallengeVerified.IsZero() || now.Sub(p.LastChallengeVerified) > challengeFreshnessMaxAge {
			p.mu.Unlock()
			continue
		}

		decodeTPS := resolvedDecodeTPS(p)
		prefillTPS := resolvedPrefillTPS(p)

		// Enumerate every model this provider serves.
		for _, m := range p.Models {
			if !r.modelAllowedByCatalogLocked(m) {
				continue
			}
			hasHeadroom := p.hasConcurrencyHeadroomForModelLocked(m.ID)
			// Count only pending requests for this specific model, not the
			// total across all models. Using the total inflates
			// activeRequests for multi-model providers.
			modelPending := 0
			for _, pr := range p.pendingReqs {
				if pr.Model == m.ID {
					modelPending++
				}
			}

			snap := providerCapSnap{
				model:          m.ID,
				hasHeadroom:    hasHeadroom,
				effectiveTPS:   decodeTPS,
				prefillTPS:     prefillTPS,
				activeRequests: modelPending,
			}

			// Check backend capacity for this model's slot.
			if p.BackendCapacity != nil {
				for _, slot := range p.BackendCapacity.Slots {
					if slot.Model != m.ID {
						continue
					}
					snap.warm = slotStateModelLoaded(slot.State)
					snap.running = slot.State == "running"
					slotActive := int(slot.NumRunning) + int(slot.NumWaiting)
					if slotActive > snap.activeRequests {
						snap.activeRequests = slotActive
					}
					if slot.ObservedDecodeTPS > 0 {
						snap.effectiveTPS = slot.ObservedDecodeTPS
					}
					snap.activeTokenBudgetMax = slot.ActiveTokenBudgetMax
					snap.activeTokenBudgetUsed = slot.ActiveTokenBudgetUsed
					snap.queuedTokenBudget = slot.QueuedTokenBudget
					snap.backlogTokens = float64(slot.MaxTokensPotential)
					break
				}
			} else {
				// Without backend capacity, warm if currently serving this model.
				snap.warm = p.CurrentModel == m.ID
			}

			snaps = append(snaps, snap)
		}
		p.mu.Unlock()
	}
	r.mu.RUnlock()

	// Phase 2: aggregate per-model outside the lock.
	type modelAgg struct {
		routable         int
		warm             int
		running          int
		cold             int
		activeRequests   int
		aggregateTPS     float64
		budgetRemaining  int64
		budgetTotal      int64
		bestWarmTTFTMs   int64 // -1 = not set
		bestColdTTFTMs   int64 // -1 = not set
		anyImmediateSlot bool  // at least one provider with headroom
	}
	agg := make(map[string]*modelAgg)
	for _, s := range snaps {
		a, ok := agg[s.model]
		if !ok {
			a = &modelAgg{bestWarmTTFTMs: -1, bestColdTTFTMs: -1}
			agg[s.model] = a
		}
		if s.warm {
			a.warm++
			if s.running {
				a.running++
			}
		} else {
			a.cold++
		}
		a.activeRequests += s.activeRequests
		a.aggregateTPS += s.effectiveTPS
		if s.activeTokenBudgetMax > 0 {
			headroom := s.activeTokenBudgetMax - s.activeTokenBudgetUsed - s.queuedTokenBudget
			if headroom < 0 {
				headroom = 0
			}
			a.budgetRemaining += headroom
			a.budgetTotal += s.activeTokenBudgetMax
		}
		// Routable providers require both concurrency headroom AND token-budget
		// headroom. A provider with exhausted token budget should not make the
		// model appear immediately ready.
		hasBudgetHeadroom := s.activeTokenBudgetMax <= 0 ||
			s.activeTokenBudgetUsed+s.queuedTokenBudget < s.activeTokenBudgetMax
		if s.hasHeadroom && hasBudgetHeadroom {
			a.routable++
			a.anyImmediateSlot = true
		}

		// Estimate TTFT for this provider: prefill 500 tokens + backlog drain.
		const defaultPromptTokens = 500
		ttftMs := int64(0)
		if s.prefillTPS > 0 {
			ttftMs = int64(float64(defaultPromptTokens) / s.prefillTPS * 1000)
		}
		if s.effectiveTPS > 0 {
			ttftMs += int64(s.backlogTokens / s.effectiveTPS * 1000)
		}
		if s.warm {
			if a.bestWarmTTFTMs < 0 || ttftMs < a.bestWarmTTFTMs {
				a.bestWarmTTFTMs = ttftMs
			}
		} else {
			coldTTFT := ttftMs + 20_000 // 20s cold-start penalty
			if a.bestColdTTFTMs < 0 || coldTTFT < a.bestColdTTFTMs {
				a.bestColdTTFTMs = coldTTFT
			}
		}
	}

	// Phase 3: read queue sizes (separate lock, safe to call after releasing r.mu).
	queueLimit := 0
	if r.queue != nil {
		queueLimit = r.queue.MaxSize()
	}

	result := make([]ModelCapacity, 0, len(agg))
	for model, a := range agg {
		queued := 0
		if r.queue != nil {
			queued = r.queue.QueueSize(model)
		}
		ready := a.routable > 0
		canAccept := ready && (queued < queueLimit || a.anyImmediateSlot)

		ttft := a.bestWarmTTFTMs
		if ttft < 0 {
			ttft = a.bestColdTTFTMs
		}
		if ttft < 0 {
			ttft = 0
		}

		result = append(result, ModelCapacity{
			ModelID:              model,
			Ready:                ready,
			CanAccept:            canAccept,
			RoutableProviders:    a.routable,
			WarmProviders:        a.warm,
			RunningProviders:     a.running,
			ColdProviders:        a.cold,
			ActiveRequests:       a.activeRequests,
			QueuedRequests:       queued,
			QueueLimit:           queueLimit,
			AggregateTPS:         a.aggregateTPS,
			EstimatedTTFTMs:      ttft,
			TokenBudgetRemaining: a.budgetRemaining,
			TokenBudgetTotal:     a.budgetTotal,
		})
	}
	return result
}

// ForEachProvider iterates over all registered providers (read lock held).
func (r *Registry) ForEachProvider(fn func(p *Provider)) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, p := range r.providers {
		fn(p)
	}
}

// ProviderIDs returns the IDs of all registered providers.
func (r *Registry) ProviderIDs() []string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	ids := make([]string, 0, len(r.providers))
	for id := range r.providers {
		ids = append(ids, id)
	}
	return ids
}

// StartEvictionLoop starts a background goroutine that removes providers
// that haven't sent a heartbeat within the given timeout. It stops when
// the context is cancelled.
func (r *Registry) StartEvictionLoop(ctx context.Context, timeout time.Duration) {
	ticker := time.NewTicker(timeout / 3)
	saferun.Go(r.logger, "registry.evictionLoop", func() {
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				r.evictStale(timeout)
			}
		}
	})
}

func (r *Registry) evictStale(timeout time.Duration) {
	now := time.Now()

	// Scan under the write lock: we both READ LastHeartbeat and REBUILD
	// evictStrikes. Collect every provider's heartbeat age for the summary, and
	// decide who to evict: a provider is reaped only after it is stale on TWO
	// consecutive sweeps (strike >= 2), so a single transient stall that ages
	// many timestamps at once gives the fleet a sweep to recover instead of a
	// mass reap.
	r.mu.Lock()
	fleet := len(r.providers)
	ages := make([]time.Duration, 0, fleet)
	nextStrikes := make(map[string]int, len(r.evictStrikes))
	var toEvict []string
	var evictAges []time.Duration
	for id, p := range r.providers {
		p.mu.Lock()
		lastHeartbeat := p.LastHeartbeat
		p.mu.Unlock()
		age := now.Sub(lastHeartbeat)
		ages = append(ages, age)
		if age > timeout {
			strikes := r.evictStrikes[id] + 1
			if strikes >= evictStrikeThreshold {
				toEvict = append(toEvict, id)
				evictAges = append(evictAges, age)
			} else {
				nextStrikes[id] = strikes // carry the strike to next sweep
			}
		}
	}
	r.evictStrikes = nextStrikes
	r.mu.Unlock()

	if len(ages) > 0 {
		amin, amed, ap90, amax := durationStats(ages)
		// A tight evicted-age spread (emax-emin small) means many providers went
		// stale at the same instant — a coordinator-side stall. A broad spread
		// means independent provider sleeps. The summary makes that diagnosable.
		emin, _, _, emax := durationStats(evictAges)
		r.logger.Info("eviction sweep",
			"fleet", fleet,
			"evicting", len(toEvict),
			"hb_age_min_s", int(amin.Seconds()),
			"hb_age_p50_s", int(amed.Seconds()),
			"hb_age_p90_s", int(ap90.Seconds()),
			"hb_age_max_s", int(amax.Seconds()),
			"evicted_age_min_s", int(emin.Seconds()),
			"evicted_age_max_s", int(emax.Seconds()),
		)
	}

	for _, id := range toEvict {
		r.logger.Warn("evicting stale provider", "provider_id", id, "timeout", timeout)
		r.Disconnect(id)
	}
}

// evictStrikeThreshold is how many consecutive stale sweeps trigger eviction.
// With a timeout/3 sweep cadence, 2 strikes ≈ one extra sweep interval of grace.
const evictStrikeThreshold = 2

// durationStats returns min, median, p90, max of ds (zeros for an empty slice).
// Sorts a copy; ds is small (fleet-sized) so this is cheap.
func durationStats(ds []time.Duration) (min, median, p90, max time.Duration) {
	if len(ds) == 0 {
		return 0, 0, 0, 0
	}
	s := make([]time.Duration, len(ds))
	copy(s, ds)
	sort.Slice(s, func(i, j int) bool { return s[i] < s[j] })
	return s[0], s[len(s)/2], s[(len(s)*9)/10], s[len(s)-1]
}
