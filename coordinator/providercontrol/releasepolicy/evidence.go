package releasepolicy

import (
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/trustreuse"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// releaseEvidenceStillApproved reports whether previously granted application
// evidence remains approved under a freshly built release-policy snapshot: the
// same binary hash still maps to an active release with the same version,
// platform, and backend, and that release's metallib hash is unchanged. These
// are the ONLY facts application evidence proves — python/runtime/per-family
// template facts were deliberately removed (mlx-swift providers never report
// them; requiring them made evidence underivable fleet-wide, 2026-08-31
// incident). Binary hash and metallib fail closed on absence or mismatch.
func releaseEvidenceStillApproved(
	snapshot *Snapshot,
	evidence registry.ApplicationEvidence,
) bool {
	if evidence.BinaryHash == "" || evidence.MetallibHash == "" {
		return false
	}
	for _, candidate := range snapshot.byBinaryHash[evidence.BinaryHash] {
		if candidate.Version != evidence.Version ||
			candidate.Platform != evidence.Platform ||
			candidate.Platform == "" {
			continue
		}
		// Legacy release rows may carry an empty backend (the column was added
		// with an empty default); treat it as matching the evidence backend,
		// mirroring DeriveApprovedTransition.
		if candidate.Backend != "" && candidate.Backend != evidence.Backend {
			continue
		}
		expectedMetallib, err := NormalizeSHA256Hex(candidate.MetallibHash, "release.metallib_hash")
		if err != nil || expectedMetallib != evidence.MetallibHash {
			continue
		}
		return true
	}
	return false
}

// RecordEvidenceOutcome counts one application-evidence derivation
// outcome. No-op without DogStatsD.
func (s *Manager) RecordEvidenceOutcome(outcome string) {
	s.deps.Incr("release_evidence.outcome", []string{"outcome:" + outcome})
}

// evidenceRejected records the typed rejection reason and returns the empty
// derivation result.
func (s *Manager) evidenceRejected(reason string) (trustreuse.ReleaseTransition, registry.ApplicationEvidence, bool) {
	s.RecordEvidenceOutcome(reason)
	return trustreuse.ReleaseTransition{}, registry.ApplicationEvidence{}, false
}

func (s *Manager) DeriveApprovedTransition(
	provider *registry.Provider,
	resp *protocol.AttestationResponseMessage,
	statusFieldsTrusted bool,
) (trustreuse.ReleaseTransition, registry.ApplicationEvidence, bool) {
	if provider == nil || resp == nil || !statusFieldsTrusted ||
		resp.SIPEnabled == nil || !*resp.SIPEnabled ||
		resp.SecureBootEnabled == nil || !*resp.SecureBootEnabled ||
		provider.ChallengeShouldStop() {
		return s.evidenceRejected(evidenceReasonPrecondition)
	}
	freshHash, err := NormalizeSHA256Hex(resp.BinaryHash, "binary_hash")
	if err != nil {
		return s.evidenceRejected(evidenceReasonInvalidBinaryHash)
	}
	snapshot := s.releaseTrustPolicy.Load()
	if snapshot == nil {
		return s.evidenceRejected(evidenceReasonPolicyUnavailable)
	}

	provider.Mu().Lock()
	version, backend, processKey := provider.Version, provider.Backend, provider.PublicKey
	apnsToken := provider.APNsDeviceToken
	runtimeVerified := provider.RuntimeVerified
	manifestChecked := provider.RuntimeManifestChecked
	metallibVerified := provider.MetallibVerified
	attested := provider.AttestationResult
	provider.Mu().Unlock()
	// An APNs device token is deliberately NOT required: application evidence
	// proves the live binary/runtime is an active approved release, while APNs
	// token possession is enforced exclusively by the code-identity gate (with
	// its own grace semantics). Tokenless legacy/headless providers with a
	// valid signed challenge must still derive and keep evidence.
	if !snapshot.required {
		return s.evidenceRejected(evidenceReasonPolicyNotRequired)
	}
	if processKey == "" || attested == nil || !attested.Valid ||
		attested.PublicKey == "" || attested.SerialNumber == "" {
		return s.evidenceRejected(evidenceReasonProcessIdentity)
	}
	if !runtimeVerified || !manifestChecked || !metallibVerified {
		return s.evidenceRejected(evidenceReasonRuntimeGate)
	}
	if s.deps.MinimumVersion() != "" &&
		(version == "" || VersionLess(version, s.deps.MinimumVersion())) {
		return s.evidenceRejected(evidenceReasonVersionFloor)
	}
	// Registration-time binary_hash is optional and the production fleet omits
	// it. The fresh hash is carried by this already-signature-verified challenge
	// from the same attested SE identity and is still required to match an active
	// release below. When registration did carry a hash, keep the stronger
	// cross-check and fail closed on a mismatch.
	if strings.TrimSpace(attested.BinaryHash) != "" {
		attestedHash, hashErr := NormalizeSHA256Hex(attested.BinaryHash, "attested binary_hash")
		if hashErr != nil || attestedHash != freshHash {
			return s.evidenceRejected(evidenceReasonRegistrationHashMismatch)
		}
	}

	// Legacy release rows can carry an empty backend: the migration added the
	// column with an empty default and registration accepts an omitted backend.
	// Such rows MUST NOT leave providers permanently unroutable — an empty
	// backend matches the provider-reported backend (an exact match is
	// preferred when both exist), and the derived fact/evidence is stamped with
	// the provider-reported backend so routing's evidence.Backend == p.Backend
	// check keeps holding.
	var current Release
	found := false
	for _, candidate := range snapshot.byBinaryHash[freshHash] {
		if candidate.Version == version && candidate.Backend == backend &&
			candidate.Platform != "" {
			current = candidate
			found = true
			break
		}
	}
	if !found {
		for _, candidate := range snapshot.byBinaryHash[freshHash] {
			if candidate.Version == version && candidate.Backend == "" &&
				candidate.Platform != "" {
				current = candidate
				current.Backend = backend
				found = true
				break
			}
		}
	}
	if !found {
		return s.evidenceRejected(evidenceReasonNoActiveRelease)
	}
	if !releaseMetallibMatches(current, resp) {
		return s.evidenceRejected(evidenceReasonMetallibMismatch)
	}

	approvedFrom := make(map[string]struct{})
	for binaryHash := range snapshot.byBinaryHash {
		if approvedTransitionPredecessor(
			snapshot, binaryHash,
			current.Platform, current.Backend, current.Version,
		) {
			approvedFrom[binaryHash] = struct{}{}
		}
	}
	metallibHash, _ := NormalizeSHA256Hex(
		resp.TemplateHashes["mlx_metallib"], "mlx_metallib")
	fact := trustreuse.ReleaseTransition{
		Approved: true, BinaryHash: freshHash, Version: current.Version,
		Platform: current.Platform, Backend: current.Backend,
		PolicyGeneration:         snapshot.generation,
		ApprovedFromBinaryHashes: approvedFrom,
	}
	evidence := registry.ApplicationEvidence{
		SEPublicKey: attested.PublicKey, Serial: attested.SerialNumber,
		ProcessPublicKey: processKey, APNsToken: apnsToken,
		BinaryHash: freshHash,
		Version:    current.Version, Platform: current.Platform,
		Backend:      current.Backend,
		MetallibHash: metallibHash, VerifiedAt: time.Now().UTC(),
		PolicyGeneration: snapshot.generation,
	}
	s.RecordEvidenceOutcome(evidenceOutcomeGranted)
	return fact, evidence, true
}

// releaseMetallibMatches verifies the ONE release-specific runtime fact both
// sides always hold: the release row's metallib hash must equal the provider's
// reported mlx_metallib template hash (both normalized 64-hex; absence on
// either side fails closed). Nothing else is compared here by design — the
// python plane is gone (mlx-swift providers hardcode it nil), and release
// rows' per-model-family template hashes were CI fabrications (hashed from
// CDN jinja files by release-swift.yml) that no provider ever reported;
// requiring provider coverage of those made application evidence underivable
// for 100% of the production fleet (2026-08-31 zero-capacity incident).
// Binary-hash ↔ active-release matching is the caller's job.
func releaseMetallibMatches(policy Release, resp *protocol.AttestationResponseMessage) bool {
	if policy.MetallibHash == "" {
		return false
	}
	expectedMetallib, err := NormalizeSHA256Hex(policy.MetallibHash, "release.metallib_hash")
	if err != nil {
		return false
	}
	gotMetallib, err := NormalizeSHA256Hex(resp.TemplateHashes["mlx_metallib"], "mlx_metallib")
	return err == nil && gotMetallib == expectedMetallib
}

// Closed outcome set for application-evidence derivation. Every
// DeriveApprovedTransition return path records exactly one of these as
// a release_evidence.outcome DogStatsD counter tag so a candidate coordinator
// can be judged in SHADOW mode from per-reason fleet counts instead of a
// silent boolean (the 2026-08-31 zero-capacity deploys were undiagnosable
// precisely because every rejection branch looked identical). No hashes,
// keys, serials, or tokens ride on these tags.
const (
	evidenceOutcomeGranted                 = "granted"
	evidenceReasonPrecondition             = "precondition"
	evidenceReasonInvalidBinaryHash        = "invalid_binary_hash"
	evidenceReasonPolicyUnavailable        = "policy_unavailable"
	evidenceReasonPolicyNotRequired        = "policy_not_required"
	evidenceReasonProcessIdentity          = "process_identity"
	evidenceReasonRuntimeGate              = "runtime_gate"
	evidenceReasonVersionFloor             = "version_floor"
	evidenceReasonRegistrationHashMismatch = "registration_hash_mismatch"
	evidenceReasonNoActiveRelease          = "no_active_release"
	evidenceReasonMetallibMismatch         = "metallib_mismatch"
)
