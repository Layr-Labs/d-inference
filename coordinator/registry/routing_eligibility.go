package registry

import (
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

type ProviderModelEligibilityReason string

const (
	EligibilityAllowed                 ProviderModelEligibilityReason = "allowed"
	EligibilityProviderOffline         ProviderModelEligibilityReason = "provider_offline"
	EligibilityProviderUntrusted       ProviderModelEligibilityReason = "provider_untrusted"
	EligibilityPrivateOnly             ProviderModelEligibilityReason = "private_only"
	EligibilityTrustBelowMinimum       ProviderModelEligibilityReason = "trust_below_minimum"
	EligibilityDeviceEvidenceMissing   ProviderModelEligibilityReason = "device_evidence_missing"
	EligibilityDeviceEvidenceMismatch  ProviderModelEligibilityReason = "device_evidence_mismatch"
	EligibilityDeviceEvidenceExpired   ProviderModelEligibilityReason = "device_evidence_expired"
	EligibilityRuntimeUnverified       ProviderModelEligibilityReason = "runtime_unverified"
	EligibilityPrivacyUnavailable      ProviderModelEligibilityReason = "privacy_unavailable"
	EligibilityChallengeStale          ProviderModelEligibilityReason = "challenge_stale"
	EligibilityApplicationMissing      ProviderModelEligibilityReason = "application_evidence_missing"
	EligibilityReleasePolicyStale      ProviderModelEligibilityReason = "release_policy_stale"
	EligibilityProcessMissing          ProviderModelEligibilityReason = "process_evidence_missing"
	EligibilityProcessExpired          ProviderModelEligibilityReason = "process_evidence_expired"
	EligibilityCodeProofMissing        ProviderModelEligibilityReason = "code_proof_missing"
	EligibilityMinimumVersion          ProviderModelEligibilityReason = "minimum_version"
	EligibilityCatalogMissing          ProviderModelEligibilityReason = "catalog_missing"
	EligibilityModelNotAdvertised      ProviderModelEligibilityReason = "model_not_advertised"
	EligibilityModelHashMismatch       ProviderModelEligibilityReason = "model_hash_mismatch"
	EligibilityCapabilityUnknown       ProviderModelEligibilityReason = "capability_unknown"
	EligibilityCapabilityMissing       ProviderModelEligibilityReason = "capability_missing"
	EligibilityDedicatedModel          ProviderModelEligibilityReason = "dedicated_model"
	EligibilitySlotNotReady            ProviderModelEligibilityReason = "slot_not_ready"
	EligibilityUpdateLifecycleNotReady ProviderModelEligibilityReason = "update_lifecycle_not_ready"
)

type eligibilityPurpose struct {
	minTrust             TrustLevel
	allowPrivate         bool
	allowOwnedOffCatalog bool
	requireDevice        bool
	requireAdvertisement bool
	requireServingSlot   bool
	applyDedicatedRule   bool
}

func servingEligibilityPurpose(minTrust TrustLevel, owner bool) eligibilityPurpose {
	return eligibilityPurpose{
		minTrust: minTrust, allowPrivate: owner, allowOwnedOffCatalog: owner,
		requireDevice:        true,
		requireAdvertisement: true, requireServingSlot: true,
		applyDedicatedRule: !owner,
	}
}

func acquisitionEligibilityPurpose(minTrust TrustLevel) eligibilityPurpose {
	return eligibilityPurpose{
		minTrust:      minTrust,
		requireDevice: trustRank(minTrust) >= trustRank(TrustHardware),
	}
}

// ModelEvidence is a value-only, per-decision join of the active catalog fact,
// the provider's exact advertisement, capability evidence, and authoritative
// live slot. No returned map or slice aliases provider or catalog state.
type ModelEvidence struct {
	CatalogID                    string
	ManifestHash                 string
	ProviderWeightHash           string
	RequiredProviderCapabilities []string
	Slot                         protocol.BackendSlotCapacity
	SlotReported                 bool
	SlotReady                    bool
	PositiveRequestCapacity      bool
	EvidenceGeneration           uint64
	DesiredGeneration            uint64
}

type ProviderModelEligibility struct {
	Eligible    bool
	Reason      ProviderModelEligibilityReason
	Device      DeviceEvidence
	Application ApplicationEvidence
	Process     CertifiedProcessEvidence
	Model       ModelEvidence
}

func deniedEligibility(reason ProviderModelEligibilityReason, result ProviderModelEligibility) ProviderModelEligibility {
	result.Eligible = false
	result.Reason = reason
	return result
}

// providerModelEligibilityLocked is the only composable device × application ×
// model × lifecycle join. Caller holds r.mu and p.mu. Purpose changes only the
// documented owner trust/private relaxation and whether an acquisition command
// needs an existing advertisement/serving slot; it never weakens privacy,
// release, process, model-integrity, or capability evidence.
func (r *Registry) providerModelEligibilityLocked(
	p *Provider,
	modelID string,
	purpose eligibilityPurpose,
	now time.Time,
) ProviderModelEligibility {
	result := ProviderModelEligibility{
		Reason:      EligibilityAllowed,
		Device:      p.DeviceEvidence,
		Application: p.ApplicationEvidence,
		Process:     p.ApplicationEvidence.CertifiedProcessEvidence,
	}
	if p.Status == StatusOffline {
		return deniedEligibility(EligibilityProviderOffline, result)
	}
	if p.Status == StatusUntrusted {
		return deniedEligibility(EligibilityProviderUntrusted, result)
	}
	if p.RolloutApprovalRequired && !p.RolloutReleaseApproved {
		return deniedEligibility(EligibilityReleasePolicyStale, result)
	}
	if p.UpdateLifecycleReported && !p.ReleaseUpdateReadyLocked() {
		return deniedEligibility(EligibilityUpdateLifecycleNotReady, result)
	}
	if p.PrivateOnly && !purpose.allowPrivate {
		return deniedEligibility(EligibilityPrivateOnly, result)
	}
	if trustRank(p.TrustLevel) < trustRank(purpose.minTrust) {
		return deniedEligibility(EligibilityTrustBelowMinimum, result)
	}
	// Pre-v1 providers retain the deployed connection-live TrustHardware
	// contract. Once a provider advertises v1 or carries explicit device
	// evidence, the independently-expiring device lease is mandatory.
	if purpose.requireDevice &&
		(p.ProcessEvidenceVersion == protocol.ProcessEvidenceV1 ||
			result.Device.EvidenceGeneration != 0) {
		if result.Device.EvidenceGeneration == 0 || result.Device.SEPublicKey == "" ||
			result.Device.Serial == "" || result.Device.VerifiedAt.IsZero() {
			return deniedEligibility(EligibilityDeviceEvidenceMissing, result)
		}
		if !deviceIdentityMatchesAttestation(result.Device, p.AttestationResult) {
			return deniedEligibility(EligibilityDeviceEvidenceMismatch, result)
		}
		if result.Device.ExpiresAt.IsZero() || !now.Before(result.Device.ExpiresAt) {
			return deniedEligibility(EligibilityDeviceEvidenceExpired, result)
		}
	}
	if !p.RuntimeVerified {
		return deniedEligibility(EligibilityRuntimeUnverified, result)
	}
	if p.LastChallengeVerified.IsZero() || now.Before(p.LastChallengeVerified.Add(-2*time.Minute)) ||
		now.Sub(p.LastChallengeVerified) > challengeFreshnessMaxAge {
		return deniedEligibility(EligibilityChallengeStale, result)
	}
	if reason := r.privateTextEligibilityReasonLocked(p, now); reason != EligibilityAllowed {
		return deniedEligibility(reason, result)
	}

	if modelID == "" {
		result.Eligible = true
		return result
	}
	entry, tracked := r.modelCatalog[modelID]
	if r.modelCatalog != nil && !tracked && !purpose.allowOwnedOffCatalog {
		return deniedEligibility(EligibilityCatalogMissing, result)
	}
	required := effectiveRequiredProviderCapabilities(modelID, entry.RequiredProviderCapabilities)
	result.Model = ModelEvidence{
		CatalogID: modelID, ManifestHash: entry.WeightHash,
		RequiredProviderCapabilities: append([]string(nil), required...),
		EvidenceGeneration:           p.modelEvidenceGeneration,
		DesiredGeneration:            p.desiredModelGeneration,
	}

	capabilities := make(map[string]bool, 2)
	if !result.Device.VerifiedAt.IsZero() &&
		!result.Device.ExpiresAt.IsZero() &&
		now.Before(result.Device.ExpiresAt) &&
		deviceEvidenceHasAppleM5(result.Device, p.AttestationResult) {
		capabilities[ProviderCapabilityAppleM5] = true
	}
	processCurrent := result.Process.Version == protocol.ProcessEvidenceV1 &&
		result.Process.CoordinatorSessionID == p.ID &&
		result.Process.ProcessPublicKey == p.PublicKey &&
		result.Process.PolicyGeneration == r.releasePolicyGeneration &&
		result.Process.ChallengeGeneration != "" &&
		now.Before(result.Process.ExpiresAt)
	if result.Application.MLXNAX && result.Process.MLXNAX && processCurrent &&
		result.Application.MetallibHash == result.Process.MetallibHash &&
		attestedMLXNAX(p.AttestationResult, result.Process.MetallibHash) &&
		capabilitySetContainsAll(
			p.RuntimeCapabilities, []string{ProviderCapabilityMLXNAX}) &&
		p.MetallibVerified && p.FreshCodeAttested {
		capabilities[ProviderCapabilityMLXNAX] = true
	}
	for _, capability := range required {
		if !knownProviderCapability(capability) {
			return deniedEligibility(EligibilityCapabilityUnknown, result)
		}
		if !capabilities[capability] {
			return deniedEligibility(EligibilityCapabilityMissing, result)
		}
	}
	if capabilitiesRequired(required, ProviderCapabilityMLXNAX) {
		if CompareVersions(p.Version, processEvidenceV1ProviderFloor) < 0 {
			return deniedEligibility(EligibilityMinimumVersion, result)
		}
		if !p.CodeAttested || !p.FreshCodeAttested {
			return deniedEligibility(EligibilityCodeProofMissing, result)
		}
		if result.Application.EvidenceGeneration == 0 {
			return deniedEligibility(EligibilityApplicationMissing, result)
		}
		if !processCurrent {
			if result.Process.Version == "" {
				return deniedEligibility(EligibilityProcessMissing, result)
			}
			return deniedEligibility(EligibilityProcessExpired, result)
		}
	}

	var advertised *protocol.ModelInfo
	for i := range p.Models {
		if p.Models[i].ID == modelID {
			advertised = &p.Models[i]
			break
		}
	}
	if purpose.requireAdvertisement && advertised == nil {
		return deniedEligibility(EligibilityModelNotAdvertised, result)
	}
	if advertised != nil {
		result.Model.ProviderWeightHash = advertised.WeightHash
		strictModelEvidence := p.ProcessEvidenceVersion == protocol.ProcessEvidenceV1 ||
			len(required) > 0
		if tracked && entry.WeightHash != "" &&
			((strictModelEvidence && advertised.WeightHash == "") ||
				(advertised.WeightHash != "" &&
					!strings.EqualFold(entry.WeightHash, advertised.WeightHash))) {
			return deniedEligibility(EligibilityModelHashMismatch, result)
		}
	}
	if purpose.applyDedicatedRule && r.providerExcludedByDedicatedRuleLocked(p, modelID) {
		return deniedEligibility(EligibilityDedicatedModel, result)
	}

	if p.BackendCapacity != nil {
		for _, slot := range p.BackendCapacity.Slots {
			if slot.Model != modelID {
				continue
			}
			result.Model.Slot = slot
			result.Model.SlotReported = true
			result.Model.SlotReady =
				slot.State == "running" || slot.State == "idle"
			result.Model.PositiveRequestCapacity = slot.MaxConcurrency > 0 &&
				slot.NumRunning+slot.NumWaiting < slot.MaxConcurrency
			break
		}
	}
	if purpose.requireServingSlot && len(required) > 0 {
		if !result.Model.SlotReported || !result.Model.SlotReady {
			return deniedEligibility(EligibilitySlotNotReady, result)
		}
	}
	result.Eligible = true
	return result
}

func capabilitiesRequired(required []string, capability string) bool {
	for _, value := range required {
		if value == capability {
			return true
		}
	}
	return false
}

func (r *Registry) privateTextEligibilityReasonLocked(p *Provider, now time.Time) ProviderModelEligibilityReason {
	if p.PublicKey == "" || !privateTextBackendSupported(p.Backend) ||
		!p.EncryptedResponseChunks || !p.RuntimeManifestChecked ||
		!p.ChallengeVerifiedSIP || p.PrivacyCapabilities == nil {
		return EligibilityPrivacyUnavailable
	}
	caps := p.PrivacyCapabilities
	if !caps.TextBackendInprocess || !caps.TextProxyDisabled ||
		!caps.AntiDebugEnabled || !caps.CoreDumpsDisabled || !caps.EnvScrubbed {
		return EligibilityPrivacyUnavailable
	}
	if r.codeAttestationEnforcedLocked() && !p.CodeAttested {
		return EligibilityCodeProofMissing
	}
	evidence := p.ApplicationEvidence
	if p.ProcessEvidenceVersion != protocol.ProcessEvidenceV1 && !r.releasePolicyRequired {
		return EligibilityAllowed
	}
	if evidence.EvidenceGeneration == 0 {
		return EligibilityApplicationMissing
	}
	if r.releasePolicyRequired &&
		(evidence.PolicyGeneration != r.releasePolicyGeneration ||
			evidence.ProcessPublicKey != p.PublicKey ||
			evidence.APNsToken == "" || evidence.APNsToken != p.APNsDeviceToken ||
			evidence.Version != p.Version || evidence.Backend != p.Backend ||
			evidence.BinaryHash == "" || p.AttestationResult == nil ||
			evidence.SEPublicKey != p.AttestationResult.PublicKey ||
			evidence.Serial != p.AttestationResult.SerialNumber) {
		return EligibilityReleasePolicyStale
	}
	if p.ProcessEvidenceVersion != protocol.ProcessEvidenceV1 {
		return EligibilityAllowed
	}
	certificate := evidence.CertifiedProcessEvidence
	if certificate.Version == "" {
		return EligibilityProcessMissing
	}
	if certificate.Version != protocol.ProcessEvidenceV1 ||
		certificate.CoordinatorSessionID != p.ID ||
		certificate.ProcessPublicKey != p.PublicKey ||
		certificate.PolicyGeneration != r.releasePolicyGeneration ||
		certificate.ChallengeGeneration == "" || !now.Before(certificate.ExpiresAt) {
		return EligibilityProcessExpired
	}
	if !p.CodeAttested {
		return EligibilityCodeProofMissing
	}
	return EligibilityAllowed
}

func (r *Registry) providerLivenessGateLocked(p *Provider, minTrust TrustLevel, allowPrivate bool, now time.Time) bool {
	purpose := servingEligibilityPurpose(minTrust, allowPrivate)
	purpose.requireAdvertisement = false
	purpose.requireServingSlot = false
	return r.providerModelEligibilityLocked(p, "", purpose, now).Eligible
}

func (r *Registry) providerServesRoutableModelLocked(p *Provider, model string, allowDedicated bool) bool {
	purpose := servingEligibilityPurpose(r.MinTrustLevel, allowDedicated)
	purpose.minTrust = TrustNone
	purpose.requireServingSlot = false
	return r.providerModelEligibilityLocked(p, model, purpose, time.Now()).Eligible
}

var providerModelEligibilityReasonVocabulary = []ProviderModelEligibilityReason{
	EligibilityAllowed, EligibilityProviderOffline, EligibilityProviderUntrusted,
	EligibilityPrivateOnly, EligibilityTrustBelowMinimum,
	EligibilityDeviceEvidenceMissing, EligibilityDeviceEvidenceMismatch,
	EligibilityDeviceEvidenceExpired, EligibilityRuntimeUnverified,
	EligibilityPrivacyUnavailable, EligibilityChallengeStale,
	EligibilityApplicationMissing, EligibilityReleasePolicyStale,
	EligibilityProcessMissing, EligibilityProcessExpired,
	EligibilityCodeProofMissing, EligibilityMinimumVersion,
	EligibilityCatalogMissing, EligibilityModelNotAdvertised,
	EligibilityModelHashMismatch, EligibilityCapabilityUnknown,
	EligibilityCapabilityMissing, EligibilityDedicatedModel,
	EligibilitySlotNotReady, EligibilityUpdateLifecycleNotReady,
}

// ProviderModelEligibilityReasonCounts is a low-cardinality operational
// projection. Its keys come only from the fixed vocabulary above; it never
// exposes provider, Secure-Enclave, serial, hash, or model identifiers.
func (r *Registry) ProviderModelEligibilityReasonCounts() map[string]int {
	counts := make(map[string]int, len(providerModelEligibilityReasonVocabulary))
	for _, reason := range providerModelEligibilityReasonVocabulary {
		counts[string(reason)] = 0
	}
	now := time.Now()
	r.mu.RLock()
	for _, p := range r.providers {
		p.mu.Lock()
		if len(p.Models) == 0 {
			reason := r.providerModelEligibilityLocked(
				p, "", servingEligibilityPurpose(r.MinTrustLevel, false), now,
			).Reason
			counts[string(reason)]++
		} else {
			for _, model := range p.Models {
				reason := r.providerModelEligibilityLocked(
					p, model.ID,
					servingEligibilityPurpose(r.MinTrustLevel, false), now,
				).Reason
				counts[string(reason)]++
			}
		}
		p.mu.Unlock()
	}
	r.mu.RUnlock()
	return counts
}
