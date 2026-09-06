package registry

import (
	"encoding/json"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

// DeviceEvidence and ApplicationEvidence are independent live snapshots. A
// durable store row may seed a device proof candidate, but only a fresh signed
// connection challenge can create ApplicationEvidence.
type DeviceEvidence struct {
	SEPublicKey          string
	Serial               string
	VerifiedAt           time.Time
	EvidenceGeneration   uint64
	RevocationGeneration uint64
}

// ApplicationEvidence proves this connection's process runs an active approved
// release: the SE-signed challenge binary hash matched an active release row
// for the provider's version/platform/backend, and the runtime metallib hash
// matched that release. Deliberately NO python/runtime/per-family-template
// facts: mlx-swift providers never report them (python is gone; family
// template hashes were CI fabrications no provider could echo — requiring
// them made evidence underivable fleet-wide, 2026-08-31 incident).
type ApplicationEvidence struct {
	SEPublicKey      string
	Serial           string
	ProcessPublicKey string
	// APNsToken binds the evidence to the provider's APNs device token when it
	// has one. It MAY be empty: tokenless (legacy/headless) providers with a
	// valid signed challenge still earn application evidence — APNs token
	// possession is enforced exclusively by the APNs code-identity gate.
	APNsToken          string
	BinaryHash         string
	Version            string
	Platform           string
	Backend            string
	MetallibHash       string
	VerifiedAt         time.Time
	EvidenceGeneration uint64
	PolicyGeneration   uint64
}

// SetAttested updates attestation state (thread-safe).
// Note: persistence is handled by the Registry methods that call this,
// via persistProvider() after attestation verification completes.
func (p *Provider) SetAttested(attested bool, trust TrustLevel) {
	p.mu.Lock()
	p.Attested = attested
	p.TrustLevel = trust
	if !attested || trust != TrustHardware {
		p.RuntimeCapabilities = nil
	}
	p.mu.Unlock()
	p.reconcileRuntimeCapabilities()
}

func (p *Provider) reconcileRuntimeCapabilities() {
	if p.registry == nil {
		return
	}
	if err := p.registry.ReconcileAttestedRuntimeCapabilities(p.ID); err != nil {
		p.registry.MarkUntrusted(p.ID)
	}
}

// GrantHardwareIfNotUntrusted preserves the existing atomic grant surface.
func (p *Provider) GrantHardwareIfNotUntrusted() bool {
	p.mu.Lock()
	evidence := p.DeviceEvidence
	p.mu.Unlock()
	return p.GrantHardwareEvidenceIfNotUntrusted(evidence)
}

// GrantHardwareEvidenceIfNotUntrusted atomically joins a valid device proof to
// the live provider unless a hard untrust already won the provider lock.
func (p *Provider) GrantHardwareEvidenceIfNotUntrusted(evidence DeviceEvidence) bool {
	p.mu.Lock()
	if p.Status == StatusUntrusted {
		p.mu.Unlock()
		return false
	}
	p.Attested = true
	p.TrustLevel = TrustHardware
	if evidence.SEPublicKey != "" && evidence.Serial != "" {
		p.DeviceEvidence = evidence
	}
	p.mu.Unlock()
	p.reconcileRuntimeCapabilities()
	return true
}

// GrantHardwareEvidenceAtEpochIfNotUntrusted joins a durable device proof only
// if the provider is still in the exact live security epoch observed before the
// store CAS. A hard untrust either wins this lock or demotes a grant immediately
// afterward; it can never be overwritten by a stale persistence result.
func (p *Provider) GrantHardwareEvidenceAtEpochIfNotUntrusted(evidence DeviceEvidence, expectedEpoch uint64) bool {
	p.mu.Lock()
	if p.Status == StatusUntrusted || p.untrustEpoch.Load() != expectedEpoch {
		p.mu.Unlock()
		return false
	}
	p.Attested = true
	p.TrustLevel = TrustHardware
	if evidence.SEPublicKey != "" && evidence.Serial != "" {
		p.DeviceEvidence = evidence
	}
	p.mu.Unlock()
	p.reconcileRuntimeCapabilities()
	return true
}

// GrantApplicationEvidenceIfNotUntrusted stores the server-derived current
// release/runtime fact from a fresh signed process challenge. It deliberately
// does not set either code-attestation flag: self-measured hashes authenticate
// the claimant, not genuine Apple/APNs code identity.
//
// The evidence's policy generation is validated against the registry's live
// release-policy generation ATOMICALLY with the install (registry read-lock
// held across the provider-lock critical section, matching
// SetReleasePolicyGeneration's r.mu → p.mu order). This closes the
// clear/derive/grant race: a challenge that derived evidence from the OLD
// policy snapshot must not install it after a generation sweep — the sweep's
// kick (if any) may already have been consumed by an in-flight challenge, and
// non-required sweeps kick nobody, so the provider would otherwise idle
// un-kicked with stale-generation, unroutable evidence until the periodic
// ticker. A grant carrying a non-current generation is refused and the
// provider receives the same immediate out-of-band re-challenge kick a sweep
// invalidation triggers.
//
// An APNs device token is deliberately NOT required: tokenless
// (legacy/headless) providers with a valid signed challenge still earn
// application evidence. Token possession is enforced exclusively by the APNs
// code-identity gate; when the provider does hold a token, the evidence must
// still be bound to it.
func (p *Provider) GrantApplicationEvidenceIfNotUntrusted(evidence ApplicationEvidence) bool {
	r := p.registry
	if r != nil {
		r.mu.RLock()
	}
	staleGeneration := r != nil && evidence.PolicyGeneration != r.releasePolicyGeneration
	p.mu.Lock()
	if staleGeneration ||
		p.Status == StatusUntrusted ||
		evidence.SEPublicKey == "" || evidence.Serial == "" ||
		evidence.ProcessPublicKey == "" ||
		evidence.PolicyGeneration == 0 ||
		p.PublicKey != evidence.ProcessPublicKey ||
		p.APNsDeviceToken != evidence.APNsToken ||
		p.Version != evidence.Version ||
		p.Backend != evidence.Backend ||
		p.AttestationResult == nil || !p.AttestationResult.Valid ||
		p.AttestationResult.PublicKey != evidence.SEPublicKey ||
		p.AttestationResult.SerialNumber != evidence.Serial ||
		!p.RuntimeVerified || !p.RuntimeManifestChecked || !p.MetallibVerified {
		p.mu.Unlock()
		if r != nil {
			r.mu.RUnlock()
		}
		if staleGeneration {
			// Same recovery path as a sweep invalidation: re-verify now
			// instead of leaving the provider unroutable until the next tick.
			p.RequestImmediateChallenge()
		}
		return false
	}
	p.applicationEvidenceGeneration++
	evidence.EvidenceGeneration = p.applicationEvidenceGeneration
	p.ApplicationEvidence = evidence
	p.mu.Unlock()
	if r != nil {
		r.mu.RUnlock()
	}
	p.SignalApplicationProofSettled()
	p.reconcileRuntimeCapabilities()
	return true
}

func (p *Provider) ApplicationEvidenceSnapshot() (ApplicationEvidence, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	evidence := p.ApplicationEvidence
	return evidence, evidence.EvidenceGeneration != 0
}

func (p *Provider) ClearApplicationEvidence() {
	p.mu.Lock()
	p.ApplicationEvidence = ApplicationEvidence{}
	p.RuntimeCapabilities = nil
	p.mu.Unlock()
	p.reconcileRuntimeCapabilities()
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

// SetMDAProofIfHardwareBound atomically attaches an Apple Device Attestation proof
// IFF the provider currently holds hardware trust AND the proof binds to THIS
// machine — either by SE-key freshness (seKeyBound, the FreshnessCode OID equals
// SHA-256 of this connection's SE public key) OR by a matching attested serial.
// Returns true if attached. Unlike SetMDAProofIfHardware (which requires a serial
// match), this accepts an SE-key binding so a privacy-preserving attestation that
// omits the serial can still be reused. Same single-lock TOCTOU/race rationale as
// SetMDAProofIfHardware.
func (p *Provider) SetMDAProofIfHardwareBound(certChain [][]byte, mdaResult *attestation.MDAResult, seKeyBound bool) bool {
	if mdaResult == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.TrustLevel != TrustHardware {
		return false
	}
	serialOK := mdaResult.DeviceSerial != "" && p.AttestationResult != nil &&
		mdaResult.DeviceSerial == p.AttestationResult.SerialNumber
	if !seKeyBound && !serialOK {
		return false
	}
	p.MDAVerified = true
	p.MDACertChain = certChain
	p.MDAResult = mdaResult
	p.SEKeyBound = seKeyBound
	return true
}

// StagedMDAChain returns the durable MDA cert chain restored from the store for
// this reconnect (nil if none). Thread-safe. The chain is a CANDIDATE only: the
// caller must re-verify it against Apple's root and re-bind it to the live SE key
// before trusting it (see api.attachCachedMDAProof).
func (p *Provider) StagedMDAChain() [][]byte {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.restoredMDAChain
}

// StageMDAChainFromJSON stages a JSON-encoded ([][]byte) MDA cert chain — recovered
// from a live store record at reconnect — as a reuse candidate. No-op on empty
// input or a decode error. Like the staging in RestoreProviderState, this only
// sets the candidate; the proof is surfaced only after attachCachedMDAProof
// re-verifies it against Apple's root and re-binds it to this SE key.
func (p *Provider) StageMDAChainFromJSON(raw json.RawMessage) {
	if len(raw) == 0 {
		return
	}
	var chain [][]byte
	if err := json.Unmarshal(raw, &chain); err != nil || len(chain) == 0 {
		return
	}
	p.mu.Lock()
	p.restoredMDAChain = chain
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

// SetCodeAttested updates general code-proof state at validated call sites.
// Persisted proof reuse never calls this with true: every new connection must
// first complete a live encrypted process-key possession challenge.
func (p *Provider) SetCodeAttested(v bool) {
	p.mu.Lock()
	p.CodeAttested = v
	if !v {
		p.FreshCodeAttested = false
		p.RuntimeCapabilities = nil
	}
	p.mu.Unlock()
	p.reconcileRuntimeCapabilities()
}

// SetFreshCodeAttested records a nonce round-trip completed by this live
// connection. It is never set by persisted/same-version reuse.
func (p *Provider) SetFreshCodeAttested() {
	p.mu.Lock()
	p.CodeAttested = true
	p.FreshCodeAttested = true
	p.mu.Unlock()
	p.reconcileRuntimeCapabilities()
}

// GrantProcessCodeAttested atomically binds a verified live response to the
// live token and registration X25519 process key. Rotation before grant fails;
// rotation after grant clears the state under the same provider lock.
func (p *Provider) GrantProcessCodeAttested(
	expectedToken, expectedNodeKey string,
) bool {
	p.mu.Lock()
	if expectedToken == "" || expectedNodeKey == "" ||
		p.APNsDeviceToken != expectedToken ||
		p.PublicKey != expectedNodeKey {
		p.mu.Unlock()
		return false
	}
	p.CodeAttested = true
	p.FreshCodeAttested = true
	p.mu.Unlock()
	p.reconcileRuntimeCapabilities()
	return true
}

func (p *Provider) RequiresFreshRuntimeCodeProof() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, capability := range p.ReportedRuntimeCapabilities {
		if capability == ProviderCapabilityAppleM5 ||
			capability == ProviderCapabilityMLXNAX {
			return true
		}
	}
	return false
}

func (p *Provider) GetFreshCodeAttested() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.FreshCodeAttested
}

type CodeIdentityState struct {
	APNsDeviceToken        string
	Version                string
	SEPublicKey            string
	AttestationValid       bool
	RuntimeVerified        bool
	RuntimeManifestChecked bool
	ChallengeVerifiedSIP   bool
}

// GrantCodeAttestedIf runs `decide` against the live state and sets
// CodeAttested=true iff it returns true — atomically under the provider lock, so a
// concurrent token rotation can't interleave between the decision and the grant
// (closes the rotation TOCTOU). `decide` must not take this provider's lock; it
// may take others (e.g. the throttle) — lock order is always provider → throttle.
func (p *Provider) GrantCodeAttestedIf(decide func(CodeIdentityState) bool) bool {
	p.mu.Lock()
	st := CodeIdentityState{
		APNsDeviceToken:        p.APNsDeviceToken,
		Version:                p.Version,
		AttestationValid:       p.AttestationResult != nil && p.AttestationResult.Valid,
		RuntimeVerified:        p.RuntimeVerified,
		RuntimeManifestChecked: p.RuntimeManifestChecked,
		ChallengeVerifiedSIP:   p.ChallengeVerifiedSIP,
	}
	if p.AttestationResult != nil {
		st.SEPublicKey = p.AttestationResult.PublicKey
	}
	if !decide(st) {
		p.mu.Unlock()
		return false
	}
	p.CodeAttested = true
	p.mu.Unlock()
	p.reconcileRuntimeCapabilities()
	return true
}

// GetCodeAttested reports whether this connection passed code-identity
// attestation (thread-safe).
func (p *Provider) GetCodeAttested() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.CodeAttested
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

func (p *Provider) SignalApplicationProofSettled() {
	if p.applicationProofSettled == nil {
		return
	}
	p.applicationProofOnce.Do(func() { close(p.applicationProofSettled) })
}

func (p *Provider) ApplicationProofSettledChan() <-chan struct{} {
	return p.applicationProofSettled
}

// RequestImmediateChallenge asks this connection's challenge loop to send an
// out-of-band attestation challenge now instead of waiting for the next
// periodic tick. Non-blocking; concurrent requests coalesce. No-op on bare
// test Providers without a kick channel.
func (p *Provider) RequestImmediateChallenge() {
	select {
	case p.challengeKick <- struct{}{}:
	default:
	}
}

// ImmediateChallengeChan is the challenge loop's receive side of
// RequestImmediateChallenge. Nil (never ready) on bare test Providers.
func (p *Provider) ImmediateChallengeChan() <-chan struct{} {
	return p.challengeKick
}

// HardUntrustEpoch returns the current hard-untrust epoch (thread-safe). It is
// bumped on every hard untrust; the trust-reuse write-through captures it at grant
// time and re-checks it before persisting so a hard untrust that races a grant
// cannot leave a stale, reseedable `hardware` row (DAR-326 FIX A).
func (p *Provider) HardUntrustEpoch() uint64 {
	return p.untrustEpoch.Load()
}

// SetAttestationResult stores an immutable snapshot of the parsed attestation
// result. It copies both the struct and its capability slice: the registration
// path continues mutating its local result while persistence may concurrently
// marshal the Provider snapshot.
func (p *Provider) SetAttestationResult(result *attestation.VerificationResult) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if result == nil {
		p.AttestationResult = nil
	} else {
		snapshot := *result
		snapshot.RuntimeCapabilities = append(
			[]string(nil), result.RuntimeCapabilities...)
		p.AttestationResult = &snapshot
	}
	// Re-derive the stable identity and bind it while p.mu is STILL held
	// (lock order r.mu → p.mu → gatesMu → gate.mu; bindStableFaultKey takes the
	// last two). The bind — which repoints p.gate — must not land inside a
	// section that reads p.gate and acts on it under p.mu: the reservation
	// commit's admit re-check through its pending debit, the scan's gate chain,
	// the alias resolver's routability read. Binding at attestation time is what
	// re-attaches a reconnecting machine's fault state (breakers/cooldowns keyed
	// by serial/SE-key) to its fresh session id BEFORE it becomes routable —
	// public routing requires attestation.
	if r := p.registry; r != nil {
		r.bindStableFaultKey(p, stableProviderIdentityLocked(p))
	}
}

// RebindStableFaultKey re-derives this session's stable identity and re-binds
// its fault key. Account linkage happens AFTER the registration-time
// attestation bind (api/provider.go resolves the auth token only once
// Register + verifyProviderAttestation have returned), so a provider whose
// identity resolves to the ACCOUNT fallback — attestation absent (Open Mode)
// or invalid — would otherwise never bind: all its fault state would key by
// session UUID and be wiped on reconnect. Same lock discipline as
// SetAttestationResult: derive AND bind under p.mu.
func (p *Provider) RebindStableFaultKey() {
	p.mu.Lock()
	defer p.mu.Unlock()
	if r := p.registry; r != nil {
		r.bindStableFaultKey(p, stableProviderIdentityLocked(p))
	}
}

// GetAttestationResult returns the current attestation result (thread-safe).
func (p *Provider) GetAttestationResult() *attestation.VerificationResult {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.AttestationResult
}

// SetStore configures the persistence store for the registry.
// When set, provider state and reputation are persisted to the store.
// TruncHash returns the first 16 chars of a hash string for logging.
func TruncHash(h string) string {
	if len(h) > 16 {
		return h[:16] + "..."
	}
	return h
}
