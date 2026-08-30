package registry

import (
	"encoding/base64"
	"errors"
	"reflect"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const PrivateV2ProcessCertificateVersion = "process_certificate_v1"
const privateV2ProviderVersionFloor = "0.8.16"

var (
	ErrPrivateV2ProviderUnavailable = errors.New("private-v2 provider unavailable")
	ErrPrivateV2SnapshotChanged     = errors.New("private-v2 provider snapshot changed")
)

// PrivateV2ProcessCertificate is the client-verifiable projection of the
// certified process evidence. It excludes account identity while retaining the
// Apple MDA chain and exact SE-signed process transcript required for browsers
// to authenticate the process key independently of the coordinator.
type PrivateV2ProcessCertificate struct {
	Backend                   string    `json:"backend"`
	ExpiresAt                 time.Time `json:"expires_at"`
	MDADERChain               []string  `json:"mda_der_chain"`
	MetallibHash              string    `json:"metallib_hash"`
	MLXNAX                    bool      `json:"mlx_nax"`
	Platform                  string    `json:"platform"`
	PolicyGeneration          uint64    `json:"policy_generation"`
	ProcessEvidenceSignature  string    `json:"process_evidence_signature"`
	ProcessEvidenceTranscript string    `json:"process_evidence_transcript"`
	ProcessPublicKey          string    `json:"process_public_key"`
	ProviderVersion           string    `json:"provider_version"`
	ReleaseBinaryHash         string    `json:"release_binary_hash"`
	RuntimeHash               string    `json:"runtime_hash"`
	SEPublicKey               string    `json:"se_public_key"`
	VerifiedAt                time.Time `json:"verified_at"`
	Version                   string    `json:"version"`
}

// PrivateV2ProviderSnapshot binds a lease to one live connection and its exact
// certified release/model facts. ProviderID, challenge and desired generation
// remain coordinator-internal and are never serialized to a consumer.
type PrivateV2ProviderSnapshot struct {
	ProviderID              string
	Certificate             PrivateV2ProcessCertificate
	ChallengeGeneration     string
	ModelManifestHash       string
	ReleaseGeneration       uint64
	ModelGeneration         uint64
	ModelEvidenceGeneration uint64
}

func (r *Registry) providerPrivateV2CapableLocked(p *Provider, now time.Time) bool {
	if p == nil || p.PrivacyCapabilities == nil || !p.PrivacyCapabilities.PrivateV2 ||
		p.ProcessEvidenceVersion != protocol.ProcessEvidenceV1 ||
		!p.MDAVerified || !p.SEKeyBound || len(p.MDACertChain) == 0 {
		return false
	}
	cert := p.ApplicationEvidence.CertifiedProcessEvidence
	return cert.Version == protocol.ProcessEvidenceV1 &&
		CompareVersions(cert.ProviderVersion, privateV2ProviderVersionFloor) >= 0 &&
		cert.ProviderVersion == p.Version && cert.Backend == p.Backend &&
		cert.ProcessPublicKey != "" && cert.BinaryHash != "" &&
		cert.BinaryHash == p.ApplicationEvidence.BinaryHash &&
		cert.PolicyGeneration == r.releasePolicyGeneration &&
		cert.ChallengeGeneration != "" && cert.CoordinatorSessionID == p.ID &&
		cert.ProcessPublicKey == p.PublicKey && len(cert.ProcessEvidenceCanonical) > 0 &&
		cert.ProcessEvidenceSignature != "" && now.Before(cert.ExpiresAt)
}

func (r *Registry) privateV2SnapshotLocked(p *Provider, eligibility ProviderModelEligibility) (PrivateV2ProviderSnapshot, bool) {
	cert := eligibility.Process
	if !r.providerPrivateV2CapableLocked(p, time.Now()) {
		return PrivateV2ProviderSnapshot{}, false
	}
	signature, err := base64.StdEncoding.DecodeString(cert.ProcessEvidenceSignature)
	if err != nil {
		return PrivateV2ProviderSnapshot{}, false
	}
	mdaChain := make([]string, len(p.MDACertChain))
	for i, der := range p.MDACertChain {
		mdaChain[i] = base64.RawURLEncoding.EncodeToString(der)
	}
	return PrivateV2ProviderSnapshot{
		ProviderID: p.ID,
		Certificate: PrivateV2ProcessCertificate{
			Backend: cert.Backend, ExpiresAt: cert.ExpiresAt, MDADERChain: mdaChain,
			MetallibHash: cert.MetallibHash, MLXNAX: cert.MLXNAX,
			Platform: cert.Platform, PolicyGeneration: cert.PolicyGeneration,
			ProcessEvidenceSignature:  base64.RawURLEncoding.EncodeToString(signature),
			ProcessEvidenceTranscript: base64.RawURLEncoding.EncodeToString(cert.ProcessEvidenceCanonical),
			ProcessPublicKey:          cert.ProcessPublicKey, ProviderVersion: cert.ProviderVersion,
			ReleaseBinaryHash: cert.BinaryHash, RuntimeHash: cert.RuntimeHash,
			SEPublicKey: cert.SEPublicKey, VerifiedAt: cert.VerifiedAt,
			Version: PrivateV2ProcessCertificateVersion,
		},
		ChallengeGeneration:     cert.ChallengeGeneration,
		ModelManifestHash:       eligibility.Model.ManifestHash,
		ReleaseGeneration:       p.UpdateDesiredGeneration,
		ModelGeneration:         eligibility.Model.DesiredGeneration,
		ModelEvidenceGeneration: eligibility.Model.EvidenceGeneration,
	}, true
}

func privateV2SnapshotsEqual(a, b PrivateV2ProviderSnapshot) bool {
	return a.ProviderID == b.ProviderID &&
		a.ChallengeGeneration == b.ChallengeGeneration &&
		a.ModelManifestHash == b.ModelManifestHash &&
		a.ReleaseGeneration == b.ReleaseGeneration &&
		a.ModelGeneration == b.ModelGeneration &&
		a.ModelEvidenceGeneration == b.ModelEvidenceGeneration &&
		reflect.DeepEqual(a.Certificate, b.Certificate)
}

// SelectPrivateV2Provider performs the production candidate scan without
// reserving capacity. Submit must subsequently call ReservePrivateV2Provider;
// failure there is final and never falls back to another route.
func (r *Registry) SelectPrivateV2Provider(model string, pr *PendingRequest) (*Provider, PrivateV2ProviderSnapshot, RoutingDecision) {
	if pr == nil || pr.RequestID == "" {
		return nil, PrivateV2ProviderSnapshot{}, RoutingDecision{Model: model}
	}
	if pr.Model == "" {
		pr.Model = model
	}
	if pr.RequestedMaxTokens <= 0 {
		pr.RequestedMaxTokens = defaultRequestedMaxTokens
	}
	pr.Traits.RequiresPrivateV2 = true

	r.mu.Lock()
	defer r.mu.Unlock()
	selected, candidates, capacityRejects, tooLarge, visionRejects, ttftRejects, bestTTFT :=
		r.selectBestCandidateLockedFull(model, pr)
	decision := RoutingDecision{Model: model, CandidateCount: candidates,
		CapacityRejections: capacityRejects, ModelTooLargeRejections: tooLarge,
		VisionRejections: visionRejects, TTFTRejections: ttftRejects, BestTTFTMs: bestTTFT}
	if selected == nil {
		return nil, PrivateV2ProviderSnapshot{}, decision
	}

	p := selected.provider
	p.mu.Lock()
	defer p.mu.Unlock()
	owned := p.AccountID != "" && p.AccountID == pr.OwnerAccountID
	owner := pr.SelfRouteOnly || (pr.PreferOwner && owned)
	if !r.providerCanAdmitLockedEx(p, model, pr.Traits, owner, false) ||
		(pr.RequiresVision && !r.providerServesVisionModelLocked(p, model, owner)) {
		return nil, PrivateV2ProviderSnapshot{}, decision
	}
	eligibility := r.providerModelEligibilityLocked(p, model,
		servingEligibilityPurpose(r.MinTrustLevel, owner), time.Now())
	if !eligibility.Eligible {
		return nil, PrivateV2ProviderSnapshot{}, decision
	}
	snapshot, ok := r.privateV2SnapshotLocked(p, eligibility)
	if !ok {
		return nil, PrivateV2ProviderSnapshot{}, decision
	}
	decision.ProviderID = p.ID
	decision.CostMs = selected.breakdown.Total
	decision.TTFTMs = selected.breakdown.TTFTMs
	return p, snapshot, decision
}

// ReservePrivateV2Provider atomically revalidates and reserves only providerID.
// It cannot route to another provider, including one that became preferable
// after preflight.
func (r *Registry) ReservePrivateV2Provider(providerID, model string, pr *PendingRequest, expected PrivateV2ProviderSnapshot) (*Provider, error) {
	if pr == nil || pr.RequestID == "" || providerID == "" {
		return nil, ErrPrivateV2ProviderUnavailable
	}
	if pr.Model == "" {
		pr.Model = model
	}
	if pr.RequestedMaxTokens <= 0 {
		pr.RequestedMaxTokens = defaultRequestedMaxTokens
	}
	pr.Traits.RequiresPrivateV2 = true

	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.ID != expected.ProviderID {
		return nil, ErrPrivateV2ProviderUnavailable
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	owned := p.AccountID != "" && p.AccountID == pr.OwnerAccountID
	owner := pr.SelfRouteOnly || (pr.PreferOwner && owned)
	if !r.providerCanAdmitLockedEx(p, model, pr.Traits, owner, false) ||
		(pr.RequiresVision && !r.providerServesVisionModelLocked(p, model, owner)) {
		return nil, ErrPrivateV2ProviderUnavailable
	}
	eligibility := r.providerModelEligibilityLocked(p, model,
		servingEligibilityPurpose(r.MinTrustLevel, owner), time.Now())
	if !eligibility.Eligible {
		return nil, ErrPrivateV2ProviderUnavailable
	}
	current, ok := r.privateV2SnapshotLocked(p, eligibility)
	if !ok || !privateV2SnapshotsEqual(current, expected) {
		return nil, ErrPrivateV2SnapshotChanged
	}
	pr.ProviderID = p.ID
	p.addPendingLocked(pr)
	r.claimCapacityProbeLocked(p.ID, model, time.Now())
	if p.Status != StatusUntrusted && p.Status != StatusOffline {
		p.Status = StatusServing
	}
	return p, nil
}

// AcceptPrivateV2Sequence provides a hard one-way sequence ledger for a single
// provider request. Duplicate, skipped, post-terminal, and nonterminal metadata
// chunks fail closed before reaching the client or billing paths.
func (pr *PendingRequest) AcceptPrivateV2Sequence(msg protocol.PrivateChunkV2Message, decodedCiphertextBytes int) bool {
	if pr == nil || decodedCiphertextBytes < 16 {
		return false
	}
	pr.privateV2Mu.Lock()
	defer pr.privateV2Mu.Unlock()
	if pr.privateV2Done || msg.Sequence != pr.privateV2Next ||
		pr.privateV2Next >= 8192 ||
		pr.privateV2Bytes > (64<<20)-decodedCiphertextBytes {
		return false
	}
	if !msg.Terminal && (msg.Usage != nil || msg.FailureCode != "" || msg.StatusCode != 0) {
		return false
	}
	pr.privateV2Bytes += decodedCiphertextBytes
	pr.privateV2Next++
	if msg.Terminal {
		pr.privateV2Done = true
	}
	return true
}

// ResolvePrivateV2Delivery releases terminal settlement after the HTTP relay
// has either committed encrypted content or finalized a pre-content refund.
func (pr *PendingRequest) ResolvePrivateV2Delivery() {
	if pr == nil || pr.PrivateV2DeliveryCh == nil {
		return
	}
	pr.privateV2DeliveryOnce.Do(func() { close(pr.PrivateV2DeliveryCh) })
}

func (pr *PendingRequest) AwaitPrivateV2Delivery() {
	if pr != nil && pr.PrivateV2DeliveryCh != nil {
		<-pr.PrivateV2DeliveryCh
	}
}
