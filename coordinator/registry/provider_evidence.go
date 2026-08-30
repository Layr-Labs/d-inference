package registry

import (
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

const defaultDeviceEvidenceLifetime = time.Hour

// normalizeDeviceEvidenceLocked returns a detached connection snapshot. The M5
// bit is coordinator-derived only from the signed registration evidence; raw
// Hardware registration fields can never turn it on. Caller holds p.mu.
func normalizeDeviceEvidenceLocked(p *Provider, evidence DeviceEvidence) DeviceEvidence {
	evidence.AppleM5 = false
	if evidence.ExpiresAt.IsZero() && !evidence.VerifiedAt.IsZero() {
		evidence.ExpiresAt = evidence.VerifiedAt.Add(defaultDeviceEvidenceLifetime)
	}
	attested := p.AttestationResult
	if !deviceIdentityMatchesAttestation(evidence, attested) {
		return evidence
	}
	if !strings.EqualFold(strings.TrimSpace(attested.ChipFamily), "M5") {
		return evidence
	}
	for _, capability := range attested.RuntimeCapabilities {
		if capability == ProviderCapabilityAppleM5 {
			evidence.AppleM5 = true
			break
		}
	}
	return evidence
}

func deviceIdentityMatchesAttestation(evidence DeviceEvidence, result *attestation.VerificationResult) bool {
	return result != nil && result.Valid && evidence.SEPublicKey != "" &&
		evidence.Serial != "" && evidence.SEPublicKey == result.PublicKey &&
		evidence.Serial == result.SerialNumber
}

func deviceEvidenceHasAppleM5(
	evidence DeviceEvidence,
	result *attestation.VerificationResult,
) bool {
	if !evidence.AppleM5 ||
		!deviceIdentityMatchesAttestation(evidence, result) ||
		!strings.EqualFold(strings.TrimSpace(result.ChipFamily), "M5") {
		return false
	}
	for _, capability := range result.RuntimeCapabilities {
		if capability == ProviderCapabilityAppleM5 {
			return true
		}
	}
	return false
}

func attestedMLXNAX(result *attestation.VerificationResult, metallibHash string) bool {
	if result == nil || !result.Valid || metallibHash == "" ||
		!strings.EqualFold(strings.TrimSpace(result.MetallibHash), strings.TrimSpace(metallibHash)) {
		return false
	}
	for _, capability := range result.RuntimeCapabilities {
		if capability == ProviderCapabilityMLXNAX {
			return true
		}
	}
	return false
}

// DeviceEvidenceSnapshot returns a value copy; callers cannot mutate live
// routing authority through the snapshot.
func (p *Provider) DeviceEvidenceSnapshot() (DeviceEvidence, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	evidence := p.DeviceEvidence
	return evidence, evidence.EvidenceGeneration != 0 &&
		evidence.SEPublicKey != "" && evidence.Serial != ""
}
