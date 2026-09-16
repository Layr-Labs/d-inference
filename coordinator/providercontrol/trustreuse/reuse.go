package trustreuse

import (
	"context"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"time"
)

// TryReuse consumes durable device evidence only after the caller
// has verified a fresh registration-bound signed challenge. A changed binary is
// admitted solely through the optional immutable server-derived release fact.
func (s *Manager) TryReuse(providerID string, provider *registry.Provider, resp *protocol.AttestationResponseMessage, statusFieldsTrusted bool, facts ...ReleaseTransition) bool {
	reject := func(reason Reason) bool {
		s.recordDecision("", reason)
		return false
	}
	if s == nil || s.cache == nil || provider == nil || resp == nil {
		return false
	}
	if blocked, _ := s.SafetyStatus(); blocked {
		return reject(ReasonRevocationSafety)
	}
	if !s.mdmConfigured() {
		return reject(ReasonNoDeviceEvidence)
	}
	if !statusFieldsTrusted ||
		resp.SIPEnabled == nil || !*resp.SIPEnabled ||
		resp.SecureBootEnabled == nil || !*resp.SecureBootEnabled {
		return reject(ReasonRecordedPostureBad)
	}
	if provider.ChallengeShouldStop() {
		return reject(ReasonRevoked)
	}
	provider.Mu().Lock()
	var seKey, serial string
	if provider.AttestationResult != nil {
		seKey = provider.AttestationResult.PublicKey
		serial = provider.AttestationResult.SerialNumber
	}
	provider.Mu().Unlock()
	if seKey == "" || serial == "" {
		return reject(ReasonMissingIdentity)
	}
	if s.trustReuseIdentityPending(seKey) {
		return reject(ReasonRevocationSafety)
	}
	freshBinaryHash, err := s.normalizeHash(resp.BinaryHash, "binary_hash")
	if err != nil {
		return reject(ReasonMissingIdentity)
	}
	var fact ReleaseTransition
	if len(facts) > 0 {
		fact = facts[0]
	}
	result := s.cache.decide(Input{
		SEPubKey:          seKey,
		Serial:            serial,
		FreshBinaryHash:   freshBinaryHash,
		ReleaseTransition: fact,
	})
	if result.Decision == "" {
		return reject(result.Reason)
	}
	record := result.Record
	if result.Decision == DecisionApprovedReleaseTransition ||
		result.Decision == DecisionContinuityReleaseTransition {
		evidence, ok := provider.ApplicationEvidenceSnapshot()
		if !ok || evidence.BinaryHash != freshBinaryHash ||
			evidence.Version != fact.Version ||
			evidence.Platform != fact.Platform ||
			evidence.Backend != fact.Backend {
			return reject(ReasonTransitionUnapproved)
		}
		// The approved A→B transition has just proven binary B (fresh signed
		// challenge + verified application evidence). Advance the cached and
		// durable application identity to B so a later deactivation of
		// release A (ApprovedFromBinaryHashes only lists ACTIVE predecessors)
		// cannot orphan the record and force this device back to live MDM.
		// The hardware-proof timestamp is deliberately NOT refreshed — it
		// still dates the last live device verification, so the reuse window
		// keeps expiring on the hardware proof, not on binary churn.
		record.lastVerifiedBinaryHash = freshBinaryHash
		at := evidence.VerifiedAt
		record.applicationProofVerifiedAt = &at
	}
	// Every valid reuse grant (window-fresh OR continuity) re-anchors the
	// continuity chain at the grant instant: a continuity fast-skip is itself
	// proof of a normal-OS boot (the live SE challenge just ran), so chained
	// sub-allowance gaps each extend coverage. The hardware-proof timestamp is
	// NEVER advanced by reuse — only a full live MDM verification moves it.
	record.continuousCoverageUntil = s.cache.now()
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
	if st := s.cache.store; st != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		writeResult, persistErr := st.UpsertProviderTrustReuse(
			ctx, rec, record.revocationGeneration)
		cancel()
		if persistErr != nil || !writeResult.Applied {
			if persistErr != nil {
				s.logger.Warn("trust-reuse: durable grant CAS failed", "error", persistErr)
			}
			if !writeResult.Applied {
				s.cache.installRevocationGeneration(
					seKey, writeResult.RevocationGeneration)
			}
			return reject(ReasonRevoked)
		}
		record.evidenceGeneration = writeResult.EvidenceGeneration
		record.revocationGeneration = writeResult.RevocationGeneration
		rec.EvidenceGeneration = writeResult.EvidenceGeneration
		rec.RevocationGeneration = writeResult.RevocationGeneration
	}
	s.cache.recordTrust(rec)
	if !provider.GrantHardwareEvidenceAtEpochIfNotUntrusted(registry.DeviceEvidence{
		SEPublicKey:          seKey,
		Serial:               serial,
		VerifiedAt:           record.hardwareProofVerifiedAt,
		EvidenceGeneration:   record.evidenceGeneration,
		RevocationGeneration: record.revocationGeneration,
	}, epoch) {
		return reject(ReasonRevoked)
	}
	s.MarkCoverage(seKey, providerID)
	provider.SetMDMFailureReason("")
	s.sendStatus(provider, registry.TrustHardware, "online", string(result.Decision))
	s.registry.PersistProvider(provider)
	s.recordDecision(result.Decision, ReasonAllowed)
	s.logger.Info("trust-reuse granted hardware without live MDM or APNs",
		"provider_id", providerID,
		"decision", result.Decision,
		"mda_udid", result.Record.mdaUDID,
	)
	return true
}
