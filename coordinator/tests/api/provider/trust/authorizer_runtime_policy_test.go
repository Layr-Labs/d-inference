package trust_test

import (
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestAppAttestAuthorizerRevalidatesMetalLibraryAndBackend(t *testing.T) {
	for _, mode := range []string{"metallib", "backend", "verification_key", "runtime"} {
		t.Run(mode, func(t *testing.T) {
			s, p, status := newAuthorizationFixture(t)
			if !s.releases.Policy().AppAttestReleaseApproved(p, status) {
				t.Fatal("initial release rejected")
			}
			row := store.Release{BinaryHash: strings.Repeat("a", 64), Version: "0.9.4", Platform: "macos-arm64", MetallibHash: strings.Repeat("b", 64)}
			switch mode {
			case "metallib":
				row.MetallibHash = strings.Repeat("c", 64)
			case "backend":
				row.Backend = "other"
			case "verification_key":
				status.AttestationPublicKey = "other"
			case "runtime":
				p.MetallibVerified = false
			}
			publishTestReleasePolicy(t, s, row)
			if s.releases.Policy().AppAttestReleaseApproved(p, status) {
				t.Fatal("stale runtime reapproved")
			}
			if _, ok := s.registry.ProviderServingAuthorization(p); ok {
				t.Fatal("old generation authorization survived")
			}
		})
	}
}
