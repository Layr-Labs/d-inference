package service

import (
	"context"
	"strings"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func readinessTestBuild(binary string) store.AppAttestBuildQualification {
	return store.AppAttestBuildQualification{AppAttestBuildIdentity: store.AppAttestBuildIdentity{
		Release: store.Release{Version: "0.9.4", Platform: "macos-arm64", Backend: "mlx-swift", BinaryHash: binary,
			BundleHash: strings.Repeat("b", 64), MetallibHash: strings.Repeat("d", 64), URL: "https://example.com/bundle"},
		CodeDirectoryHash: strings.Repeat("c", 64), SourceCommit: strings.Repeat("f", 40), CIRunID: "123"}, Evidence: "transition tests", ApprovedBy: "operator"}
}

func TestReleaseReadyFollowsDurableQualification(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		mem := store.NewMemory(store.Config{})
		s := &Service{store: mem}
		q := readinessTestBuild(strings.Repeat("a", 64))
		if s.ReleaseReady(q.Release) {
			t.Fatal("ready before any qualification snapshot")
		}
		if _, err := mem.QualifyAppAttestBuild(context.Background(), q); err != nil {
			t.Fatal(err)
		}
		if err := s.RefreshBuildQualifications(context.Background()); err != nil {
			t.Fatal(err)
		}
		// Catalog-only fields do not change signed artifact identity.
		cached := q.Release
		cached.Changelog, cached.Active = "notes", true
		if !s.ReleaseReady(cached) {
			t.Fatal("qualified release not ready")
		}
		other := q.Release
		other.BundleHash = strings.Repeat("e", 64)
		if s.ReleaseReady(other) {
			t.Fatal("release with a different bundle accepted for the qualified binary")
		}
		time.Sleep(BuildQualificationFreshness)
		if s.ReleaseReady(q.Release) {
			t.Fatal("stale qualification snapshot accepted")
		}
		if err := s.RefreshBuildQualifications(context.Background()); err != nil {
			t.Fatal(err)
		}
		s.FenceBuild(q.Release.BinaryHash)
		if s.ReleaseReady(q.Release) {
			t.Fatal("revoked build still ready")
		}
	})
}

func TestReleaseReadyEnvironmentCompatibilityNeedsCodePair(t *testing.T) {
	binary, code := strings.Repeat("a", 64), strings.Repeat("c", 64)
	release := readinessTestBuild(binary).Release
	s := &Service{store: store.NewMemory(store.Config{})}
	if err := s.RefreshBuildQualifications(context.Background()); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name          string
		builds, codes string
		want          bool
	}{
		{"binary and code pair", binary, binary + ":" + code, true},
		{"binary without code pair", binary, strings.Repeat("9", 64) + ":" + code, false},
		{"code pair without binary", "", binary + ":" + code, false},
		{"malformed code pair", binary, binary + ":short", false},
	} {
		s.config.QualifiedBuildHashes, s.config.QualifiedCodeHashes = tc.builds, tc.codes
		if got := s.ReleaseReady(release); got != tc.want {
			t.Fatalf("%s: ready=%v", tc.name, got)
		}
	}
}
