package registry

import (
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const (
	ProviderCapabilityAppleM5 = "apple_m5"
	ProviderCapabilityMLXNAX  = "mlx_nax"

	Qwen38NAXModelID               = "EigenLabs/Qwen3.8-27B-4bit"
	processEvidenceV1ProviderFloor = "0.8.16"
)

var qwen38NAXRequiredProviderCapabilities = []string{
	ProviderCapabilityAppleM5,
	ProviderCapabilityMLXNAX,
}

// normalizeRuntimeCapabilities builds the immutable, connection-scoped
// capability set from registration. apple_m5 is accepted only when the
// structured hardware family independently says M5. Unknown future capability
// names are retained for forward observability, but the containment helper
// below never treats them as satisfying an unknown catalog requirement.
func normalizeRuntimeCapabilities(reported []string, hardware protocol.Hardware) []string {
	seen := make(map[string]struct{}, len(reported))
	for _, capability := range reported {
		capability = strings.TrimSpace(capability)
		if capability == "" {
			continue
		}
		if capability == ProviderCapabilityAppleM5 &&
			!strings.EqualFold(strings.TrimSpace(hardware.ChipFamily), "M5") {
			continue
		}
		seen[capability] = struct{}{}
	}
	if len(seen) == 0 {
		return nil
	}
	out := make([]string, 0, len(seen))
	for capability := range seen {
		out = append(out, capability)
	}
	sort.Strings(out)
	return out
}

func equalRuntimeCapabilities(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for i := range left {
		if left[i] != right[i] {
			return false
		}
	}
	return true
}

// ReconcileAttestedRuntimeCapabilities promotes reported registration claims to
// effective capabilities only after every input to the protected-model decision
// is cryptographically or policy bound.
//
// mlx_nax invariant:
//   - capability + structured chip family + metallib digest are covered by the
//     registration Secure-Enclave signature;
//   - signed claims exactly match the outer Register report;
//   - the same metallib digest passed the existing approved runtime manifest.
//
// Apple hardware trust and APNs code identity are promotion prerequisites, not
// merely exact-model routing gates. Legacy attestations have no signed claim
// fields; they stay trusted for unrelated models but receive no capabilities.
func (r *Registry) ReconcileAttestedRuntimeCapabilities(providerID string) error {
	r.mu.RLock()
	provider := r.providers[providerID]
	r.mu.RUnlock()
	if provider == nil {
		return fmt.Errorf("provider not found")
	}

	provider.mu.Lock()
	defer func() {
		changed := false
		if provider.runtimeCapabilitiesReconciled {
			changed = !equalRuntimeCapabilities(
				provider.lastReconciledRuntimeCapabilities,
				provider.RuntimeCapabilities,
			)
		} else {
			// Initial empty/pending state is not a transition and must not emit
			// a duplicate empty desired_models beside registration.
			changed = len(provider.RuntimeCapabilities) > 0
			provider.runtimeCapabilitiesReconciled = true
		}
		provider.lastReconciledRuntimeCapabilities = append(
			[]string(nil), provider.RuntimeCapabilities...)
		provider.mu.Unlock()
		if changed {
			r.notifyRuntimeCapabilitiesPromoted(providerID)
		}
	}()
	provider.RuntimeCapabilities = nil

	result := provider.AttestationResult
	if result == nil || !result.Valid {
		return nil
	}
	hasSignedClaims := result.ChipFamily != "" ||
		len(result.RuntimeCapabilities) > 0 ||
		result.MetallibHash != ""
	if !hasSignedClaims {
		return nil
	}

	signed := normalizeRuntimeCapabilities(
		result.RuntimeCapabilities,
		protocol.Hardware{ChipFamily: result.ChipFamily},
	)
	if !equalRuntimeCapabilities(signed, result.RuntimeCapabilities) {
		return fmt.Errorf("attested runtime capabilities are not canonical")
	}
	if !equalRuntimeCapabilities(signed, provider.ReportedRuntimeCapabilities) {
		return fmt.Errorf("attested runtime capabilities do not match registration")
	}
	if !strings.EqualFold(
		strings.TrimSpace(result.ChipFamily),
		strings.TrimSpace(provider.Hardware.ChipFamily),
	) {
		return fmt.Errorf("attested chip family does not match registration")
	}
	if result.MetallibHash != "" {
		reportedMetallib := provider.TemplateHashes["mlx_metallib"]
		if reportedMetallib == "" || !strings.EqualFold(
			strings.TrimSpace(result.MetallibHash),
			strings.TrimSpace(reportedMetallib),
		) {
			return fmt.Errorf("attested metallib does not match registration")
		}
	}

	requiresApprovedMetallib := false
	requiresFreshCodeProof := false
	for _, capability := range signed {
		switch capability {
		case ProviderCapabilityAppleM5:
			if !strings.EqualFold(strings.TrimSpace(result.ChipFamily), "M5") {
				return fmt.Errorf("apple_m5 requires attested M5 chip family")
			}
			requiresFreshCodeProof = true
		case ProviderCapabilityMLXNAX:
			if result.MetallibHash == "" {
				return fmt.Errorf("mlx_nax requires an attested metallib")
			}
			requiresApprovedMetallib = true
			requiresFreshCodeProof = true
		}
	}

	// Validation above always runs so a mismatch is rejected immediately, but
	// no reported capability becomes effective until the whole connection trust
	// chain is live. This protects generic catalog capability requirements too,
	// not only the embedded exact-Qwen rule.
	if provider.Status == StatusOffline || provider.Status == StatusUntrusted ||
		!provider.Attested ||
		provider.TrustLevel != TrustHardware ||
		!provider.CodeAttested ||
		!provider.RuntimeVerified ||
		!provider.RuntimeManifestChecked ||
		(requiresApprovedMetallib && !provider.MetallibVerified) ||
		(requiresFreshCodeProof && !provider.FreshCodeAttested) {
		return nil
	}

	provider.RuntimeCapabilities = append([]string(nil), signed...)
	return nil
}

func knownProviderCapability(capability string) bool {
	switch capability {
	case ProviderCapabilityAppleM5, ProviderCapabilityMLXNAX:
		return true
	default:
		return false
	}
}

// capabilitySetContainsAll is the single exact set-containment primitive for
// provider eligibility. Requirements fail closed when malformed or unknown;
// reported unknown extras are inert.
func capabilitySetContainsAll(reported, required []string) bool {
	for _, requirement := range required {
		if requirement == "" || requirement != strings.TrimSpace(requirement) ||
			!knownProviderCapability(requirement) {
			return false
		}
		found := false
		for _, capability := range reported {
			if capability == requirement && knownProviderCapability(capability) {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}

// effectiveRequiredProviderCapabilities makes the exact Qwen3.8 NAX build
// fail closed even while an old coordinator catalog row is being migrated.
func effectiveRequiredProviderCapabilities(modelID string, configured []string) []string {
	if modelID != Qwen38NAXModelID {
		return append([]string(nil), configured...)
	}
	seen := make(map[string]struct{}, len(configured)+len(qwen38NAXRequiredProviderCapabilities))
	out := make([]string, 0, len(configured)+len(qwen38NAXRequiredProviderCapabilities))
	for _, capability := range configured {
		if _, ok := seen[capability]; ok {
			continue
		}
		seen[capability] = struct{}{}
		out = append(out, capability)
	}
	for _, capability := range qwen38NAXRequiredProviderCapabilities {
		if _, ok := seen[capability]; ok {
			continue
		}
		seen[capability] = struct{}{}
		out = append(out, capability)
	}
	return out
}

// providerMeetsModelRequirementsLocked is the pure pair-capability check used by
// alias lineage and heartbeat state ingestion. It deliberately does not require
// current routability; RuntimeCapabilities contains only coordinator-promoted
// signed evidence.
func (r *Registry) providerMeetsModelRequirementsLocked(
	p *Provider, modelID string,
) bool {
	entry := r.modelCatalog[modelID]
	required := effectiveRequiredProviderCapabilities(
		modelID, entry.RequiredProviderCapabilities,
	)
	return capabilitySetContainsAll(p.RuntimeCapabilities, required)
}

// providerCanAcquireCatalogModelLocked is the command-side catalog and
// capability gate. Unlike serving eligibility it does not require an existing
// advertisement, so it is suitable for prefetch/desired targets.
func (r *Registry) providerCanAcquireCatalogModelLocked(p *Provider, modelID string) bool {
	return r.providerModelEligibilityLocked(
		p, modelID, acquisitionEligibilityPurpose(r.MinTrustLevel), time.Now(),
	).Eligible
}

// providerEligibleForDesiredModelLocked keeps the registration-time contract
// for legacy ordinary providers, but treats desired_models as a model-acquisition
// command once a provider opts into process_evidence_v1 or the model is
// capability protected.
func (r *Registry) providerEligibleForDesiredModelLocked(
	p *Provider, modelID string,
) bool {
	if r.modelCatalog != nil {
		if _, tracked := r.modelCatalog[modelID]; !tracked {
			return false
		}
	}
	entry := r.modelCatalog[modelID]
	required := effectiveRequiredProviderCapabilities(
		modelID, entry.RequiredProviderCapabilities,
	)
	if p.ProcessEvidenceVersion == protocol.ProcessEvidenceV1 ||
		len(required) > 0 {
		return r.providerCanAcquireCatalogModelLocked(p, modelID)
	}
	return capabilitySetContainsAll(p.RuntimeCapabilities, required)
}

func (r *Registry) providerModelAllowedByCatalogLocked(
	p *Provider, model protocol.ModelInfo,
) bool {
	return r.modelAllowedByCatalogLocked(model) &&
		r.providerMeetsModelRequirementsLocked(p, model.ID)
}

func (r *Registry) providerServesAnyCatalogModelLocked(p *Provider) bool {
	for _, model := range p.Models {
		if r.providerModelAllowedByCatalogLocked(p, model) {
			return true
		}
	}
	return false
}
