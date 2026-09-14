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
// before trusting it (see verification.Verifier.AttachCachedMDA).
func (p *Provider) StagedMDAChain() [][]byte {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.restoredMDAChain
}

// StageMDAChainFromJSON stages a JSON-encoded ([][]byte) MDA cert chain — recovered
// from a live store record at reconnect — as a reuse candidate. No-op on empty
// input or a decode error. Like the staging in RestoreProviderState, this only
// sets the candidate; the proof is surfaced only after verification.Verifier.AttachCachedMDA
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
