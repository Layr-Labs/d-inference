package authority

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/api/releases"
	trustreuse "github.com/eigeninference/d-inference/coordinator/internal/provider/reuse"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Service,

) trustReuseMetric(decision trustreuse.Decision, reason trustreuse.Reason) {
	decisionLabel := string(decision)
	if decisionLabel == "" {
		decisionLabel = "rejected"
	}
	s.observation.Incr("trust_reuse.decisions", []string{
		"decision:" + decisionLabel,
		"reason:" + string(reason),
	})
	if s.observation.Metrics() != nil {
		s.observation.Metrics().IncCounter("trust_reuse_decisions_total",
			observation.MetricLabel{Name: "decision", Value: decisionLabel},
			observation.MetricLabel{Name: "reason", Value: string(reason)})
	}
}

// tryTrustReuseFastSkip consumes durable device evidence only after the caller
// has verified a fresh registration-bound signed challenge. A changed binary is
// admitted solely through the optional immutable server-derived release fact.
func (s *Service,

) TryTrustReuseFastSkip(providerID string, provider *registry.Provider, resp *protocol.AttestationResponseMessage, statusFieldsTrusted bool, facts ...releases.ApprovedTransitionFact) bool {
	reject := func(reason trustreuse.Reason) bool {
		s.trustReuseMetric("", reason)
		return false
	}
	if s == nil || s.trustReuseCache == nil || provider == nil || resp == nil {
		return false
	}
	if s.legacyMDMAllowed != nil && !s.legacyMDMAllowed(provider) {
		return false
	}
	if blocked, _ := s.TrustSafetyStatus(); blocked {
		return reject(trustreuse.TrustReuseReasonRevocationSafety)
	}
	if s.mdmConfigured == nil || !s.mdmConfigured() {
		return reject(trustreuse.TrustReuseReasonNoDeviceEvidence)
	}
	if !statusFieldsTrusted ||
		resp.SIPEnabled == nil || !*resp.SIPEnabled ||
		resp.SecureBootEnabled == nil || !*resp.SecureBootEnabled {
		return reject(trustreuse.TrustReuseReasonRecordedPostureBad)
	}
	if provider.ChallengeShouldStop() {
		return reject(trustreuse.TrustReuseReasonRevoked)
	}
	provider.Mu().Lock()
	var seKey, serial string
	if provider.AttestationResult != nil {
		seKey = provider.AttestationResult.PublicKey
		serial = provider.AttestationResult.SerialNumber
	}
	provider.Mu().Unlock()
	if seKey == "" || serial == "" {
		return reject(trustreuse.TrustReuseReasonMissingIdentity)
	}
	if s.DeniesIdentity(seKey) {
		return reject(trustreuse.TrustReuseReasonRevocationSafety)
	}
	freshBinaryHash, err := releases.NormalizeSHA256Hex(resp.BinaryHash, "binary_hash")
	if err != nil {
		return reject(trustreuse.TrustReuseReasonMissingIdentity)
	}
	var fact releases.ApprovedTransitionFact
	if len(facts) > 0 {
		fact = facts[0]
	}
	result := s.trustReuseCache.Decide(trustreuse.Input{
		SEPubKey:          seKey,
		Serial:            serial,
		FreshBinaryHash:   freshBinaryHash,
		ReleaseTransition: fact,
	})
	if result.Decision == "" {
		return reject(result.Reason)
	}
	record := result.Record
	if result.Decision == trustreuse.ApprovedReleaseTransition ||
		result.Decision == trustreuse.ContinuityReleaseTransition {
		evidence, ok := provider.ApplicationEvidenceSnapshot()
		if !ok || evidence.BinaryHash != freshBinaryHash ||
			evidence.Version != fact.Version ||
			evidence.Platform != fact.Platform ||
			evidence.Backend != fact.Backend {
			return reject(trustreuse.TrustReuseReasonTransitionUnapproved)
		}
		// The approved A→B transition has just proven binary B (fresh signed
		// challenge + verified application evidence). Advance the cached and
		// durable application identity to B so a later deactivation of
		// release A (ApprovedFromBinaryHashes only lists ACTIVE predecessors)
		// cannot orphan the record and force this device back to live MDM.
		// The hardware-proof timestamp is deliberately NOT refreshed — it
		// still dates the last live device verification, so the reuse window
		// keeps expiring on the hardware proof, not on binary churn.
		record.LastVerifiedBinaryHash = freshBinaryHash
		at := evidence.VerifiedAt
		record.ApplicationProofVerifiedAt = &at
	}
	// Every valid reuse grant (window-fresh OR continuity) re-anchors the
	// continuity chain at the grant instant: a continuity fast-skip is itself
	// proof of a normal-OS boot (the live SE challenge just ran), so chained
	// sub-allowance gaps each extend coverage. The hardware-proof timestamp is
	// NEVER advanced by reuse — only a full live MDM verification moves it.
	record.ContinuousCoverageUntil = s.trustReuseCache.Now()
	epoch := provider.HardUntrustEpoch()
	rec := store.ProviderTrustReuse{
		SEPubKey:                   seKey,
		Serial:                     record.Serial,
		TrustLevel:                 record.TrustLevel,
		LastVerifiedBinaryHash:     record.LastVerifiedBinaryHash,
		SIPEnabled:                 record.SipEnabled,
		SecureBootFull:             record.SecureBootFull,
		MDAUDID:                    record.MdaUDID,
		HardwareProofVerifiedAt:    record.HardwareProofVerifiedAt,
		ApplicationProofVerifiedAt: record.ApplicationProofVerifiedAt,
		ContinuousCoverageUntil:    trustreuse.CoverageToStore(record.ContinuousCoverageUntil),
		EvidenceGeneration:         record.EvidenceGeneration,
		RevocationGeneration:       record.RevocationGeneration,
		RevocationEventID:          record.RevocationEventID,
	}
	if st := s.trustReuseCache.Store; st != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		writeResult, persistErr := st.UpsertProviderTrustReuse(
			ctx, rec, record.RevocationGeneration)
		cancel()
		if persistErr != nil || !writeResult.Applied {
			if persistErr != nil {
				s.logger.Warn("trust-reuse: durable grant CAS failed", "error", persistErr)
			}
			if !writeResult.Applied {
				s.trustReuseCache.InstallRevocationGeneration(
					seKey, writeResult.RevocationGeneration)
			}
			return reject(trustreuse.TrustReuseReasonRevoked)
		}
		record.EvidenceGeneration = writeResult.EvidenceGeneration
		record.RevocationGeneration = writeResult.RevocationGeneration
		rec.EvidenceGeneration = writeResult.EvidenceGeneration
		rec.RevocationGeneration = writeResult.RevocationGeneration
	}
	s.trustReuseCache.RecordTrust(rec)
	if !provider.GrantHardwareEvidenceAtEpochIfNotUntrusted(registry.DeviceEvidence{
		SEPublicKey:          seKey,
		Serial:               serial,
		VerifiedAt:           record.HardwareProofVerifiedAt,
		EvidenceGeneration:   record.EvidenceGeneration,
		RevocationGeneration: record.RevocationGeneration,
	}, epoch) {
		return reject(trustreuse.TrustReuseReasonRevoked)
	}
	s.MarkTrustCoverage(seKey, providerID)
	provider.SetMDMFailureReason("")
	s.sendTrustStatus(provider, registry.TrustHardware, "online", string(result.Decision))
	s.registry.PersistProvider(provider)
	s.trustReuseMetric(result.Decision, trustreuse.TrustReuseReasonAllowed)
	s.logger.Info("trust-reuse granted hardware without live MDM or APNs",
		"provider_id", providerID,
		"decision", result.Decision,
	)
	return true
}

// --- Connection-continuity coverage tracking ---
//
// The coordinator advances a durable ContinuousCoverageUntil watermark for
// every provider it currently observes connected AND hardware-trusted on a
// live SE-challenged connection anchored at a full live verification or a
// valid reuse grant. Writes are batched (one upsert pass every
// trustCoverageWriteInterval — no per-provider goroutines) plus exact-time
// sweeps on provider disconnect and graceful coordinator shutdown. A
// coordinator crash simply leaves the last periodic write standing, so the
// measured gap is only ever OVER-estimated (fail-safe: continuity refuses,
// full live verification runs).

// trustCoverageWriteInterval is the batched periodic coverage-write cadence.
// Also the crash slack: after a coordinator crash the watermark lags the true
// disconnect by at most one interval, which the 90s reconnect allowance and
// the 120s security ceiling both comfortably absorb without ever admitting a
// RecoveryOS round-trip (>= ~3 minutes).
