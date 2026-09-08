package api

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Compatibility path used only while the independent policy is in shadow.
func (s *Server) legacyTryTrustReuseFastSkip(providerID string, provider *registry.Provider, resp *protocol.AttestationResponseMessage, statusFieldsTrusted bool, facts ...approvedReleaseTransitionFact) bool {
	if s.processPostureEnforced() {
		return false
	}
	reject := func(reason trustReuseReason) bool {
		s.trustReuseMetric("", reason)
		return false
	}
	if s == nil || s.trustReuseCache == nil || provider == nil || resp == nil {
		return false
	}
	if blocked, _ := s.trustSafetyStatus(); blocked {
		return reject(trustReuseReasonRevocationSafety)
	}
	if s.mdmClient == nil {
		return reject(trustReuseReasonNoDeviceEvidence)
	}
	if !statusFieldsTrusted ||
		resp.SIPEnabled == nil || !*resp.SIPEnabled ||
		resp.SecureBootEnabled == nil || !*resp.SecureBootEnabled {
		return reject(trustReuseReasonRecordedPostureBad)
	}
	if provider.ChallengeShouldStop() {
		return reject(trustReuseReasonRevoked)
	}
	provider.Mu().Lock()
	var seKey, serial string
	if provider.AttestationResult != nil {
		seKey = provider.AttestationResult.PublicKey
		serial = provider.AttestationResult.SerialNumber
	}
	provider.Mu().Unlock()
	if seKey == "" || serial == "" {
		return reject(trustReuseReasonMissingIdentity)
	}
	if s.trustReuseIdentityPending(seKey) {
		return reject(trustReuseReasonRevocationSafety)
	}
	freshBinaryHash, err := normalizeSHA256Hex(resp.BinaryHash, "binary_hash")
	if err != nil {
		return reject(trustReuseReasonMissingIdentity)
	}
	var fact approvedReleaseTransitionFact
	if len(facts) > 0 {
		fact = facts[0]
	}
	result := s.trustReuseCache.decideTrustReuse(trustReuseInput{
		SEPubKey:          seKey,
		Serial:            serial,
		FreshBinaryHash:   freshBinaryHash,
		ReleaseTransition: fact,
	})
	if result.Decision == "" {
		return reject(result.Reason)
	}
	record := result.Record
	if result.Decision == trustReuseDecisionApprovedReleaseTransition ||
		result.Decision == trustReuseDecisionContinuityReleaseTransition {
		evidence, ok := provider.ApplicationEvidenceSnapshot()
		if !ok || evidence.BinaryHash != freshBinaryHash ||
			evidence.Version != fact.Version ||
			evidence.Platform != fact.Platform ||
			evidence.Backend != fact.Backend {
			return reject(trustReuseReasonTransitionUnapproved)
		}
		record.lastVerifiedBinaryHash = freshBinaryHash
		at := evidence.VerifiedAt
		record.applicationProofVerifiedAt = &at
	}
	record.continuousCoverageUntil = s.trustReuseCache.now()
	epoch := provider.HardUntrustEpoch()
	rec := store.ProviderTrustReuse{
		SEPubKey:                   seKey,
		Serial:                     record.serial,
		TrustLevel:                 record.trustLevel,
		LastVerifiedBinaryHash:     record.lastVerifiedBinaryHash,
		SIPEnabled:                 record.sipEnabled,
		SecureBootFull:             record.secureBootFull,
		MDAUDID:                    record.mdaUDID,
		HardwareProofVerifiedAt:    record.hardwareProofVerifiedAt,
		ApplicationProofVerifiedAt: record.applicationProofVerifiedAt,
		ContinuousCoverageUntil:    coverageToStore(record.continuousCoverageUntil),
		EvidenceGeneration:         record.evidenceGeneration,
		RevocationGeneration:       record.revocationGeneration,
		RevocationEventID:          record.revocationEventID,
	}
	if st := s.trustReuseCache.store; st != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		writeResult, persistErr := st.UpsertProviderTrustReuse(
			ctx, rec, record.revocationGeneration)
		cancel()
		if persistErr != nil || !writeResult.Applied {
			if persistErr != nil {
				s.logger.Warn("trust-reuse: durable grant CAS failed", "error", persistErr)
			}
			if !writeResult.Applied {
				s.trustReuseCache.installRevocationGeneration(
					seKey, writeResult.RevocationGeneration)
			}
			return reject(trustReuseReasonRevoked)
		}
		record.evidenceGeneration = writeResult.EvidenceGeneration
		record.revocationGeneration = writeResult.RevocationGeneration
		rec.EvidenceGeneration = writeResult.EvidenceGeneration
		rec.RevocationGeneration = writeResult.RevocationGeneration
	}
	s.trustReuseCache.recordTrust(rec)
	if !provider.GrantHardwareEvidenceAtEpochIfNotUntrusted(registry.DeviceEvidence{
		SEPublicKey:          seKey,
		Serial:               serial,
		VerifiedAt:           record.hardwareProofVerifiedAt,
		EvidenceGeneration:   record.evidenceGeneration,
		RevocationGeneration: record.revocationGeneration,
	}, epoch) {
		return reject(trustReuseReasonRevoked)
	}
	s.markTrustCoverage(seKey, providerID)
	provider.SetMDMFailureReason("")
	s.sendTrustStatus(provider, registry.TrustHardware, "online", string(result.Decision))
	s.registry.PersistProvider(provider)
	s.trustReuseMetric(result.Decision, trustReuseReasonAllowed)
	s.logger.Info("trust-reuse granted hardware without live MDM or APNs",
		"provider_id", providerID,
		"decision", result.Decision,
		"mda_udid", result.Record.mdaUDID,
	)
	return true
}
