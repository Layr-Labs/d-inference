package api

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

const (
	processEvidenceProviderVersionFloor = "0.8.16"
	processEvidenceTTL                  = 10 * time.Minute
)

type processEvidenceResult string

type processEvidenceReason string

const (
	processEvidenceAcceptedV1     processEvidenceResult = "accepted_v1"
	processEvidenceAcceptedLegacy processEvidenceResult = "accepted_legacy"
	processEvidenceRejected       processEvidenceResult = "rejected"

	processEvidenceReasonOK                  processEvidenceReason = "ok"
	processEvidenceReasonLegacy              processEvidenceReason = "legacy"
	processEvidenceReasonUnsupportedVersion  processEvidenceReason = "unsupported_version"
	processEvidenceReasonMixedVersion        processEvidenceReason = "mixed_v0_v1"
	processEvidenceReasonMissingChallenge    processEvidenceReason = "missing_challenge"
	processEvidenceReasonSessionMismatch     processEvidenceReason = "session_mismatch"
	processEvidenceReasonGenerationMismatch  processEvidenceReason = "generation_mismatch"
	processEvidenceReasonExpiryMismatch      processEvidenceReason = "expiry_mismatch"
	processEvidenceReasonExpired             processEvidenceReason = "expired"
	processEvidenceReasonIdentityMismatch    processEvidenceReason = "identity_mismatch"
	processEvidenceReasonProcessKeyMismatch  processEvidenceReason = "process_key_mismatch"
	processEvidenceReasonReleaseMismatch     processEvidenceReason = "release_mismatch"
	processEvidenceReasonRuntimeMismatch     processEvidenceReason = "runtime_mismatch"
	processEvidenceReasonPostureMissing      processEvidenceReason = "posture_missing"
	processEvidenceReasonPostureUnsafe       processEvidenceReason = "posture_unsafe"
	processEvidenceReasonSignatureMissing    processEvidenceReason = "signature_missing"
	processEvidenceReasonSignatureInvalid    processEvidenceReason = "signature_invalid"
	processEvidenceReasonRegistrationInvalid processEvidenceReason = "registration_invalid"
	processEvidenceReasonPolicyUnavailable   processEvidenceReason = "policy_unavailable"
)

func generateChallengeGeneration() (string, error) {
	var generation [16]byte
	if _, err := rand.Read(generation[:]); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(generation[:]), nil
}

func providerRequiresProcessEvidenceV1(provider *registry.Provider) bool {
	if provider == nil {
		return false
	}
	provider.Mu().Lock()
	version := provider.Version
	advertised := provider.ProcessEvidenceVersion
	provider.Mu().Unlock()
	return advertised != "" ||
		(version != "" && !semverLess(version, processEvidenceProviderVersionFloor))
}

func responseCarriesProcessEvidence(resp *protocol.AttestationResponseMessage) bool {
	return resp != nil && (resp.ProcessEvidenceVersion != "" ||
		resp.ProcessEvidenceSignature != "" ||
		resp.CoordinatorSessionID != "" || resp.ChallengeGeneration != "" ||
		resp.ChallengeExpiresAt != "" || resp.SEPublicKey != "" ||
		resp.SerialNumber != "" || resp.ProviderVersion != "" ||
		resp.ProviderPlatform != "" || resp.ProviderBackend != "" ||
		resp.MetallibHash != "")
}

func (s *Server) processEvidenceMetric(result processEvidenceResult, reason processEvidenceReason) {
	if s.metrics != nil {
		s.metrics.IncCounter("process_evidence_verifications_total",
			MetricLabel{"result", string(result)}, MetricLabel{"reason", string(reason)})
	}
	s.ddIncr("attestation.process_evidence", []string{
		"result:" + string(result), "reason:" + string(reason),
	})
}

func (s *Server) verifyProcessEvidenceV1(
	provider *registry.Provider,
	pc *pendingChallenge,
	resp *protocol.AttestationResponseMessage,
	now time.Time,
) (approvedReleaseTransitionFact, registry.ApplicationEvidence, processEvidenceReason) {
	if provider == nil || pc == nil || resp == nil {
		return approvedReleaseTransitionFact{}, registry.ApplicationEvidence{}, processEvidenceReasonMissingChallenge
	}

	provider.Mu().Lock()
	advertisedVersion := provider.ProcessEvidenceVersion
	processKey := provider.PublicKey
	providerVersion := provider.Version
	providerBackend := provider.Backend
	apnsToken := provider.APNsDeviceToken
	attested := provider.AttestationResult
	provider.Mu().Unlock()

	if advertisedVersion != protocol.ProcessEvidenceV1 ||
		resp.ProcessEvidenceVersion != protocol.ProcessEvidenceV1 {
		if advertisedVersion != "" && advertisedVersion != protocol.ProcessEvidenceV1 {
			return approvedReleaseTransitionFact{}, registry.ApplicationEvidence{}, processEvidenceReasonUnsupportedVersion
		}
		return approvedReleaseTransitionFact{}, registry.ApplicationEvidence{}, processEvidenceReasonMixedVersion
	}

	expected := provider.ConsumeProcessEvidenceChallenge()
	if expected.Version != protocol.ProcessEvidenceV1 {
		return approvedReleaseTransitionFact{}, registry.ApplicationEvidence{}, processEvidenceReasonMissingChallenge
	}
	if resp.CoordinatorSessionID != expected.CoordinatorSessionID ||
		expected.CoordinatorSessionID != provider.ID {
		return approvedReleaseTransitionFact{}, registry.ApplicationEvidence{}, processEvidenceReasonSessionMismatch
	}
	if resp.ChallengeGeneration != expected.ChallengeGeneration {
		return approvedReleaseTransitionFact{}, registry.ApplicationEvidence{}, processEvidenceReasonGenerationMismatch
	}
	if resp.ChallengeExpiresAt != expected.ExpiresAtRaw {
		return approvedReleaseTransitionFact{}, registry.ApplicationEvidence{}, processEvidenceReasonExpiryMismatch
	}
	if !now.Before(expected.ExpiresAt) {
		return approvedReleaseTransitionFact{}, registry.ApplicationEvidence{}, processEvidenceReasonExpired
	}
	if attested == nil || !attested.Valid || attested.PublicKey == "" ||
		attested.SerialNumber == "" || apnsToken == "" {
		return approvedReleaseTransitionFact{}, registry.ApplicationEvidence{}, processEvidenceReasonRegistrationInvalid
	}
	if resp.SEPublicKey != attested.PublicKey || resp.SerialNumber != attested.SerialNumber {
		return approvedReleaseTransitionFact{}, registry.ApplicationEvidence{}, processEvidenceReasonIdentityMismatch
	}
	if resp.PublicKey == "" || resp.PublicKey != processKey {
		return approvedReleaseTransitionFact{}, registry.ApplicationEvidence{}, processEvidenceReasonProcessKeyMismatch
	}
	if resp.ProviderVersion != providerVersion || resp.ProviderBackend != providerBackend ||
		resp.ProviderPlatform == "" {
		return approvedReleaseTransitionFact{}, registry.ApplicationEvidence{}, processEvidenceReasonReleaseMismatch
	}
	if resp.SIPEnabled == nil || resp.SecureBootEnabled == nil {
		return approvedReleaseTransitionFact{}, registry.ApplicationEvidence{}, processEvidenceReasonPostureMissing
	}
	if !*resp.SIPEnabled || !*resp.SecureBootEnabled {
		return approvedReleaseTransitionFact{}, registry.ApplicationEvidence{}, processEvidenceReasonPostureUnsafe
	}

	freshHash, err := normalizeSHA256Hex(resp.BinaryHash, "binary_hash")
	if err != nil {
		return approvedReleaseTransitionFact{}, registry.ApplicationEvidence{}, processEvidenceReasonReleaseMismatch
	}
	attestedHash, err := normalizeSHA256Hex(attested.BinaryHash, "attested binary_hash")
	if err != nil || freshHash != attestedHash {
		return approvedReleaseTransitionFact{}, registry.ApplicationEvidence{}, processEvidenceReasonReleaseMismatch
	}
	metallibHash, err := normalizeSHA256Hex(resp.MetallibHash, "metallib_hash")
	if err != nil {
		return approvedReleaseTransitionFact{}, registry.ApplicationEvidence{}, processEvidenceReasonRuntimeMismatch
	}
	templateMetallib, err := normalizeSHA256Hex(
		resp.TemplateHashes["mlx_metallib"], "template mlx_metallib")
	if err != nil || templateMetallib != metallibHash {
		return approvedReleaseTransitionFact{}, registry.ApplicationEvidence{}, processEvidenceReasonRuntimeMismatch
	}

	input := attestation.ProcessEvidenceCanonicalInput{
		CoordinatorNonce: pc.nonce, CoordinatorTimestamp: pc.timestamp,
		CoordinatorSessionID: resp.CoordinatorSessionID,
		ChallengeGeneration:  resp.ChallengeGeneration,
		EvidenceExpiresAt:    resp.ChallengeExpiresAt,
		SEPublicKey:          resp.SEPublicKey, SerialNumber: resp.SerialNumber,
		ProcessPublicKey: resp.PublicKey, BinaryHash: freshHash,
		ProviderVersion: resp.ProviderVersion, ProviderPlatform: resp.ProviderPlatform,
		ProviderBackend: resp.ProviderBackend, RuntimeHash: resp.RuntimeHash,
		MetallibHash: metallibHash, SIPEnabled: resp.SIPEnabled,
		SecureBootEnabled: resp.SecureBootEnabled,
	}
	if resp.ProcessEvidenceSignature == "" {
		return approvedReleaseTransitionFact{}, registry.ApplicationEvidence{}, processEvidenceReasonSignatureMissing
	}
	if err := attestation.VerifyProcessEvidenceSignatureV1(
		attested.PublicKey, resp.ProcessEvidenceSignature, input); err != nil {
		return approvedReleaseTransitionFact{}, registry.ApplicationEvidence{}, processEvidenceReasonSignatureInvalid
	}

	snapshot := s.releaseTrustPolicy.Load()
	if snapshot == nil || !snapshot.Required {
		return approvedReleaseTransitionFact{}, registry.ApplicationEvidence{}, processEvidenceReasonPolicyUnavailable
	}
	var current approvedReleasePolicy
	found := false
	for _, candidate := range snapshot.ByBinaryHash[freshHash] {
		if candidate.Version == resp.ProviderVersion &&
			candidate.Platform == resp.ProviderPlatform &&
			candidate.Backend == resp.ProviderBackend {
			current = candidate
			found = true
			break
		}
	}
	if !found || !releaseRuntimeMatches(current, resp) ||
		!strings.EqualFold(current.RuntimeHash, resp.RuntimeHash) {
		return approvedReleaseTransitionFact{}, registry.ApplicationEvidence{}, processEvidenceReasonRuntimeMismatch
	}
	expectedMetallib, err := normalizeSHA256Hex(current.MetallibHash, "release metallib_hash")
	if err != nil || expectedMetallib != metallibHash {
		return approvedReleaseTransitionFact{}, registry.ApplicationEvidence{}, processEvidenceReasonRuntimeMismatch
	}

	approvedFrom := make(map[string]struct{})
	for binaryHash, candidates := range snapshot.ByBinaryHash {
		for _, candidate := range candidates {
			if candidate.Platform == current.Platform && candidate.Backend == current.Backend &&
				!semverLess(current.Version, candidate.Version) {
				approvedFrom[binaryHash] = struct{}{}
				break
			}
		}
	}
	mlxNAX := false
	for _, capability := range attested.RuntimeCapabilities {
		if capability == registry.ProviderCapabilityMLXNAX {
			mlxNAX = true
			break
		}
	}
	verifiedAt := now.UTC()
	certificate := registry.CertifiedProcessEvidence{
		Version: protocol.ProcessEvidenceV1, SEPublicKey: attested.PublicKey,
		Serial: attested.SerialNumber, ProcessPublicKey: processKey,
		BinaryHash: freshHash, ProviderVersion: current.Version,
		Platform: current.Platform, Backend: current.Backend,
		RuntimeHash: resp.RuntimeHash, MetallibHash: metallibHash,
		CoordinatorSessionID: expected.CoordinatorSessionID,
		ChallengeGeneration:  expected.ChallengeGeneration,
		ExpiresAt:            expected.ExpiresAt, PolicyGeneration: snapshot.Generation,
		VerifiedAt: verifiedAt, MLXNAX: mlxNAX,
	}
	evidence := registry.ApplicationEvidence{
		SEPublicKey: attested.PublicKey, Serial: attested.SerialNumber,
		ProcessPublicKey: processKey, APNsToken: apnsToken,
		BinaryHash: freshHash, Version: current.Version, Platform: current.Platform,
		Backend: current.Backend, RuntimeHash: resp.RuntimeHash,
		MetallibHash: metallibHash, VerifiedAt: verifiedAt, MLXNAX: mlxNAX,
		PolicyGeneration: snapshot.Generation, CertifiedProcessEvidence: certificate,
	}
	fact := approvedReleaseTransitionFact{
		Approved: true, BinaryHash: freshHash, Version: current.Version,
		Platform: current.Platform, Backend: current.Backend,
		PolicyGeneration:         snapshot.Generation,
		ApprovedFromBinaryHashes: approvedFrom,
	}
	return fact, evidence, processEvidenceReasonOK
}

func processEvidenceFailureMessage(reason processEvidenceReason) string {
	return fmt.Sprintf("process evidence rejected: %s", reason)
}
