package api

import (
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/releases"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Publish the desired inventory through the real owner instead of mutating its
// private snapshot. Tests use the resulting generation for their evidence.
func publishTestReleasePolicy(t *testing.T, s *Server, rows ...store.Release) *releases.PolicyView {
	t.Helper()
	previous, err := s.store.ListReleasesWithError()
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range previous {
		if r.Active {
			if err := s.store.DeleteRelease(r.Version, r.Platform); err != nil {
				t.Fatal(err)
			}
		}
	}
	if len(rows) == 0 && len(previous) == 0 {
		r := store.Release{Version: "0.0.0", Platform: "macos-arm64", BinaryHash: strings.Repeat("f", 64)}
		if err := s.store.SetRelease(&r); err != nil {
			t.Fatal(err)
		}
		if err := s.store.DeleteRelease(r.Version, r.Platform); err != nil {
			t.Fatal(err)
		}
	}
	for _, r := range rows {
		if err := s.store.SetRelease(&r); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.releases.SyncBinaryHashes(); err != nil {
		t.Fatal(err)
	}
	return s.releases.Policy()
}
