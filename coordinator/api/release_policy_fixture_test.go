package api

import (
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/providercontrol/releasepolicy"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Fixture observations are detached from the published private policy. Existing
// assertions keep inspecting exact entries, required state and generations.
type approvedReleasePolicy = releasepolicy.Release

type releasePolicyObservation struct {
	Generation   uint64
	Required     bool
	ByBinaryHash map[string][]approvedReleasePolicy
}

func releasePolicySnapshotForTest(srv *Server) *releasePolicyObservation {
	p := srv.releasePolicyOwner().Snapshot()
	if p == nil {
		return nil
	}
	return &releasePolicyObservation{Generation: p.PolicyGeneration(), Required: p.RequiresCodeIdentity(), ByBinaryHash: p.Releases()}
}

type releasePolicyFixtureInventory []store.Release

func (r releasePolicyFixtureInventory) ListReleasesWithError() ([]store.Release, error) {
	return r, nil
}

// The resume fixtures formerly injected an immutable release snapshot directly.
// Seed it through the owner's real inventory synchronization, with no registry
// attached so setup does not invalidate the fixture's existing evidence grant.
func seedReleasePolicyForTest(t *testing.T, srv *Server, p releasePolicyObservation) {
	t.Helper()
	var rows releasePolicyFixtureInventory
	for hash, entries := range p.ByBinaryHash {
		for _, e := range entries {
			var templates []string
			for name, value := range e.TemplateHashes {
				templates = append(templates, name+"="+value)
			}
			rows = append(rows, store.Release{Version: e.Version, Platform: e.Platform, Backend: e.Backend,
				BinaryHash: hash, MetallibHash: e.MetallibHash, PythonHash: e.PythonHash, RuntimeHash: e.RuntimeHash,
				TemplateHashes: strings.Join(templates, ","), Active: true})
		}
	}
	if p.Required && len(rows) == 0 {
		rows = append(rows, store.Release{Active: false})
	}
	deps := srv.releasePolicyDependencies()
	deps.Store = func() releasepolicy.Store { return rows }
	deps.Registry = func() releasepolicy.Registry { return nil }
	_ = srv.releasePolicyOwner()
	srv.releasePolicy = releasepolicy.New(deps)
	for i := uint64(0); i < p.Generation; i++ {
		if err := srv.SyncBinaryHashes(); err != nil {
			t.Fatal(err)
		}
	}
	if got := srv.releasePolicyOwner().Snapshot(); got == nil || got.PolicyGeneration() != p.Generation || got.RequiresCodeIdentity() != p.Required {
		t.Fatalf("invalid policy fixture: %+v", got)
	}
}

func resetReleasePolicyForTest(srv *Server) {
	_ = srv.releasePolicyOwner()
	srv.releasePolicy = releasepolicy.New(srv.releasePolicyDependencies())
}
