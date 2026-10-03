package releases

import (
	"maps"
	"reflect"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// PolicyView holds one immutable published generation. Scalar fields belong to
// the view; the owner never exposes the underlying policy maps.
type PolicyView struct {
	Generation uint64
	Required   bool
	snapshot   *releaseTrustPolicySnapshot
}

func (s *Owner) Policy() *PolicyView {
	snapshot := s.releaseTrustPolicy.Load()
	if snapshot == nil {
		return nil
	}
	return &PolicyView{Generation: snapshot.Generation, Required: snapshot.Required, snapshot: snapshot}
}

func (v *PolicyView) AllowsEvidence(e registry.ApplicationEvidence) bool {
	return v != nil && releaseEvidenceStillApproved(v.snapshot, e)
}

func (v *PolicyView) Known() bool { return v != nil && len(v.snapshot.ByBinaryHash) > 0 }

func (v *PolicyView) ContainsQualifiedRelease(release store.Release) bool {
	if v == nil {
		return false
	}
	expected := &releaseTrustPolicySnapshot{ByBinaryHash: make(map[string][]approvedReleasePolicy)}
	expected.addRelease(&release, release.BinaryHash)
	for _, policy := range v.snapshot.ByBinaryHash[release.BinaryHash] {
		if reflect.DeepEqual(policy, expected.ByBinaryHash[release.BinaryHash][0]) {
			return true
		}
	}
	return false
}

func (v *PolicyView) ApprovedTransitionPredecessor(hash, platform, backend, version string) bool {
	return v != nil && approvedTransitionPredecessor(v.snapshot, hash, platform, backend, version)
}

func (v *PolicyView) AppAttestReleaseApproved(p *registry.Provider, status *protocol.AppAttestStatus) bool {
	return v != nil && appAttestReleaseApproved(v.snapshot, p, status)
}

// RuntimeManifest returns a detached copy, preserving nil for a withdrawn policy.
func (s *Owner) RuntimeManifest() *RuntimeManifest {
	m := s.runtimeManifest.Load()
	if m == nil {
		return nil
	}
	return m.clone()
}

func (s *Owner) RuntimeConfigured() bool { return s.runtimeManifest.Load() != nil }

func (s *Owner) RuntimeApprovesMetallib(reported map[string]string) bool {
	return RuntimeManifestApprovesMetallib(s.runtimeManifest.Load(), reported)
}

func (s *Owner) BinaryHashPolicySnapshot() (bool, map[string]bool) {
	configured, hashes := s.binaryHashPolicySnapshot()
	return configured, maps.Clone(hashes)
}
