package releasepolicy

import (
	"maps"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type Release struct {
	Version        string
	Platform       string
	Backend        string
	BinaryHash     string
	MetallibHash   string
	PythonHash     string
	RuntimeHash    string
	TemplateHashes map[string]string
}

type Snapshot struct {
	generation   uint64
	required     bool
	byBinaryHash map[string][]Release
}

// retainedReleaseTrustPolicy copies every still-approved entry except the
// version/platform being replaced or deactivated. The published snapshot and
// its policy maps are immutable; only the new top-level slices are extended.
func retainedReleaseTrustPolicy(last *Snapshot, generation uint64, required bool, version, platform string) *Snapshot {
	snapshot := &Snapshot{
		generation: generation, required: required,
		byBinaryHash: make(map[string][]Release),
	}
	if last != nil {
		for hash, policies := range last.byBinaryHash {
			for _, policy := range policies {
				if policy.Version != version || policy.Platform != platform {
					snapshot.byBinaryHash[hash] = append(snapshot.byBinaryHash[hash], policy)
				}
			}
		}
	}
	return snapshot
}

// addRelease projects a release whose binary hash the caller already validated.
// It preserves the release parser's last-value-wins template semantics.
func (snapshot *Snapshot) addRelease(release *store.Release, normalizedHash string) {
	templates := make(map[string]string)
	for _, pair := range strings.Split(release.TemplateHashes, ",") {
		parts := strings.SplitN(strings.TrimSpace(pair), "=", 2)
		if len(parts) == 2 && parts[0] != "" && parts[1] != "" {
			templates[parts[0]] = parts[1]
		}
	}
	snapshot.byBinaryHash[normalizedHash] = append(snapshot.byBinaryHash[normalizedHash], Release{
		Version: release.Version, Platform: release.Platform, Backend: release.Backend,
		BinaryHash: normalizedHash, MetallibHash: release.MetallibHash,
		PythonHash: release.PythonHash, RuntimeHash: release.RuntimeHash,
		TemplateHashes: templates,
	})
}

// approvedTransitionPredecessor reports whether fromHash names an ACTIVE
// release row that the current release identity (platform/backend/version) may
// transition from. This is the single approved-transition derivation — the
// same per-candidate rule DeriveApprovedTransition applies when
// building ApprovedFromBinaryHashes: same platform, backend-compatible (a
// legacy empty row backend matches any), and non-downgrade (the current
// version is not below the predecessor's). A hash absent from the ACTIVE
// inventory — e.g. a deactivated release — is never an approved predecessor.
func approvedTransitionPredecessor(
	snapshot *Snapshot,
	fromHash, platform, backend, version string,
) bool {
	if snapshot == nil || fromHash == "" || platform == "" {
		return false
	}
	for _, candidate := range snapshot.byBinaryHash[fromHash] {
		if candidate.Platform == platform &&
			(candidate.Backend == backend || candidate.Backend == "") &&
			!VersionLess(version, candidate.Version) {
			return true
		}
	}
	return false
}

func (p *Snapshot) RequiresCodeIdentity() bool { return p.required }

func (p *Snapshot) PolicyGeneration() uint64 { return p.generation }

func (p *Snapshot) AllowsPredecessor(fromHash, platform, backend, version string) bool {
	return approvedTransitionPredecessor(p, fromHash, platform, backend, version)
}

// Releases returns a detached view of the approved inventory. Mutating its maps
// or entries cannot change a published policy or an in-flight trust decision.
func (p *Snapshot) Releases() map[string][]Release {
	out := make(map[string][]Release, len(p.byBinaryHash))
	for hash, entries := range p.byBinaryHash {
		copied := append([]Release(nil), entries...)
		for i := range copied {
			copied[i].TemplateHashes = maps.Clone(copied[i].TemplateHashes)
		}
		out[hash] = copied
	}
	return out
}

// ApprovesEvidence rechecks the release-specific facts an existing grant holds.
func (p *Snapshot) ApprovesEvidence(evidence registry.ApplicationEvidence) bool {
	return releaseEvidenceStillApproved(p, evidence)
}
