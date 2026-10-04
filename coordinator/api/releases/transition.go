package releases

import compiledpolicy "github.com/eigeninference/d-inference/coordinator/internal/api/releases/compiledpolicy"

type ApprovedTransitionFact struct {
	Approved                 bool
	BinaryHash               string
	Version                  string
	Platform                 string
	Backend                  string
	PolicyGeneration         uint64
	ApprovedFromBinaryHashes map[string]struct{}
}

// approvedTransitionPredecessor reports whether fromHash names an ACTIVE
// release row that the current release identity (platform/backend/version) may
// transition from. This is the single approved-transition derivation — the
// same per-candidate rule DeriveApprovedReleaseTransition applies when
// building ApprovedFromBinaryHashes: same platform, backend-compatible (a
// legacy empty row backend matches any), and non-downgrade (the current
// version is not below the predecessor's). A hash absent from the ACTIVE
// inventory — e.g. a deactivated release — is never an approved predecessor.
func approvedTransitionPredecessor(
	snapshot *compiledpolicy.Snapshot,
	fromHash, platform, backend, version string,
) bool {
	if snapshot == nil || fromHash == "" || platform == "" {
		return false
	}
	for _, candidate := range snapshot.Inventory()[fromHash] {
		if candidate.Platform == platform &&
			(candidate.Backend == backend || candidate.Backend == "") &&
			!SemverLess(version, candidate.Version) {
			return true
		}
	}
	return false
}
